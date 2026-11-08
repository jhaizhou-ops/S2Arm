// 首用取存储（nvn_mtl.m tex_cpu_content / cpu_unc_drop，补齐上游参考实现（MIT）37c7eaa8 + 75e5ddd8）：公开 NVN 接口 → 真实 Metal 提交 → GPU 读回。
// Switch 语义：贴图 = 那段内存。CPU 改写一块存储（不 Flush）后，游戏在上面新建一个描述完全相同的贴图对象，GPU 读到的就是 CPU 新写的字节。
//   原先：第一个对象的 GPU 贴图进了共享表（g_alias），新对象按「同存储同描述」拿回旧贴图，tex_init_fill 不再跑 → 读到旧内容
//   （上游实例：逆转裁判 BC1 法庭记录图复用同一块存储，每件证物显示上一件的图；马车世界地形块 R16 / RG8 等在 GPU 没写过的池里）。
// 期望（按上面的语义手写，不由被测实现推出）：
//   ① GPU 没写过的池、RGBA8：CPU 写 A → 建对象读到 A → 释放 → CPU 写 B → 同存储同描述再建 → 读到 B
//   ② GPU 写过的池（先清过一张别的贴图）、BC1：同上，读回的块字节是 B（压缩贴图 GPU 画不进去，存储里的就是 CPU 写的）
//   ③ GPU 没写过的池里取了存储的 RGBA8 贴图，池随后第一次被 GPU 写（清另一张）：它保住已有内容 A
//   ④ 照旧：GPU 写过的池里 GPU 清过的贴图，同存储同描述再建的对象读到清除色，不被存储里的旧字节覆盖
// 每例各占一块新存储（64 KB 对齐：建贴图会给页加写保护，CPU 后写走直连层的缺页入口，同 t_nvn_ftpoll）。
// DM_NVN_STORAGE_FIRST_USE=0 关掉这条规则：① ② 应红（负对照，手动跑，不进门禁）。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

extern void *h_nvnBootstrapLoader(const char *name);
int s2a_direct_fault(void *addr, int is_write, void *uctx);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool cmd_pool, cpu_pool, gpu_pool;   // cpu_pool：GPU 从没写过；gpu_pool：开头清过一张贴图
static NVNcommandBuffer commands;
static void *cmd_storage, *cpu_storage, *gpu_storage;
static size_t cpu_off = 0, gpu_off = 0;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { POOL_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, SIDE = 8 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void pool_init(NVNmemoryPool *p, void **storage) {
    REQUIRE(posix_memalign(storage,65536,POOL_SIZE)==0); memset(*storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,*storage,POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(p,&pb));
}
static void on_sig(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&cmd_pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
static void builder(NVNtextureBuilder *b, int format) {
    API(nvnTextureBuilderSetDefaults)(b); API(nvnTextureBuilderSetDevice)(b,&device); API(nvnTextureBuilderSetTarget)(b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(b,SIDE,SIDE); API(nvnTextureBuilderSetLevels)(b,1); API(nvnTextureBuilderSetFormat)(b,format);
}
static void make(NVNtexture *t, NVNmemoryPool *p, size_t off, int format) {
    NVNtextureBuilder b; builder(&b,format); API(nvnTextureBuilderSetStorage)(&b,p,(ptrdiff_t)off); REQUIRE(API(nvnTextureInitialize)(t,&b));
}
static size_t bytes_of(int format) { NVNtextureBuilder b; builder(&b,format); size_t n=API(nvnTextureBuilderGetStorageSize)(&b); REQUIRE(n && n<=65536); return n; }
// 每 unit 字节填同一样式（RGBA8 一个纹素 4 字节、BC1 一个块 8 字节：与块线性布局无关）
static void fill(void *storage, size_t off, size_t bytes, const uint8_t *unit, size_t un) { for (size_t i=0; i<bytes; i+=un) memcpy((uint8_t *)storage+off+i,unit,un); }
// GPU 把整张贴图拷到命令池 READ_OFFSET（贴图是源），每 un 字节（RGBA8 一个纹素 / BC1 一个块）比一次 want
static void read_check(NVNtexture *t, size_t bytes, const uint8_t *want, size_t un, const char *what) {
    memset((uint8_t *)cmd_storage+READ_OFFSET,0xA5,bytes);
    NVNcopyRegion whole={0,0,0,SIDE,SIDE,1}; NVNbufferAddress dst=API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,dst,0); submit();
    const uint8_t *p=(const uint8_t *)cmd_storage+READ_OFFSET; int bad=0, n=un==8 ? (SIDE/4)*(SIDE/4) : SIDE*SIDE;   // 读回的是紧排的纹素 / 块（存储 bytes 含对齐填充）
    for (int i=0; i<n; i++) bad+=memcmp(p+un*i,want,un)!=0;
    checks++; if (bad) { fails++; printf("FAIL %s：%s，%d/%d 单元不符（第 0 个 %02x %02x %02x %02x，期望 %02x %02x %02x %02x）\n",phase,what,bad,n,p[0],p[1],p[2],p[3],want[0],want[1],want[2],want[3]); }
    else printf("PASS %s：%s\n",phase,what);
}
static void gpu_clear(NVNtexture *t) {   // 清成 (0, 1, 0, 1)：RGBA8 字节 00 ff 00 ff
    static const float green[4]={0.f,1.f,0.f,1.f}; NVNcopyRegion whole={0,0,0,SIDE,SIDE,1};
    begin(); API(nvnCommandBufferClearTexture)(&commands,t,NULL,&whole,green,0xF); submit();
}
static const uint8_t A_rgba[4]={0x11,0x22,0x33,0x44}, B_rgba[4]={0x55,0x66,0x77,0x88}, green_rgba[4]={0x00,0xff,0x00,0xff};
static const uint8_t A_bc1[8]={0x1f,0x00,0xe0,0x07,0x00,0x55,0xaa,0xff}, B_bc1[8]={0x00,0xf8,0x1f,0x00,0xff,0xaa,0x55,0x00};
// ① / ②：CPU 写 A → 建 → 读 A → 释放 → CPU 写 B → 同存储同描述再建 → 读 B
static void rewrite(NVNmemoryPool *p, void *storage, size_t *off, int format, const uint8_t *a, const uint8_t *b, size_t un, const char *name) {
    phase=name; *off+=65536; size_t bytes=bytes_of(format); REQUIRE(*off+bytes<=POOL_SIZE);
    fill(storage,*off,bytes,a,un);
    NVNtexture t; make(&t,p,*off,format); read_check(&t,bytes,a,un,"第一个对象读到建之前 CPU 写的 A"); API(nvnTextureFinalize)(&t);
    fill(storage,*off,bytes,b,un);   // 不 Flush
    NVNtexture u; make(&u,p,*off,format); read_check(&u,bytes,b,un,"CPU 改写后同存储同描述新建的对象读到 B"); API(nvnTextureFinalize)(&u);
    cases++;
}
int main(int argc, char **argv) { @autoreleasepool {
    (void)argv; if (argc!=1) { fprintf(stderr,"用法：%s\n",argv[0]); return 2; }
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    pool_init(&cmd_pool,&cmd_storage); pool_init(&cpu_pool,&cpu_storage); pool_init(&gpu_pool,&gpu_storage);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
    size_t rgba=bytes_of(NVN_FORMAT_RGBA8);
    phase="gpu_pool 先被 GPU 写一次"; NVNtexture s; make(&s,&gpu_pool,gpu_off,NVN_FORMAT_RGBA8); gpu_clear(&s); read_check(&s,rgba,green_rgba,4,"清成绿");
    rewrite(&cpu_pool,cpu_storage,&cpu_off,NVN_FORMAT_RGBA8,A_rgba,B_rgba,4,"① GPU 没写过的池，RGBA8");
    rewrite(&gpu_pool,gpu_storage,&gpu_off,NVN_FORMAT_RGBA_DXT1,A_bc1,B_bc1,8,"② GPU 写过的池，BC1");
    {   // ③
        phase="③ 取了存储的贴图在池第一次被 GPU 写后保住内容"; cpu_off+=65536; size_t at=cpu_off; fill(cpu_storage,at,rgba,A_rgba,4);
        NVNtexture t; make(&t,&cpu_pool,at,NVN_FORMAT_RGBA8); read_check(&t,rgba,A_rgba,4,"取存储读到 A");
        cpu_off+=65536; NVNtexture o; make(&o,&cpu_pool,cpu_off,NVN_FORMAT_RGBA8); gpu_clear(&o); read_check(&o,rgba,green_rgba,4,"池里另一张清成绿");
        read_check(&t,rgba,A_rgba,4,"池被 GPU 写过之后，原贴图仍是 A");
        API(nvnTextureFinalize)(&o); API(nvnTextureFinalize)(&t); cases++;
    }
    {   // ④
        phase="④ GPU 写过的池：GPU 清过的贴图，同存储同描述再建仍是清除色"; gpu_off+=65536; fill(gpu_storage,gpu_off,rgba,A_rgba,4);
        NVNtexture t; make(&t,&gpu_pool,gpu_off,NVN_FORMAT_RGBA8); gpu_clear(&t); read_check(&t,rgba,green_rgba,4,"清成绿");
        NVNtexture u; make(&u,&gpu_pool,gpu_off,NVN_FORMAT_RGBA8); read_check(&u,rgba,green_rgba,4,"再建的对象读到清除色");
        API(nvnTextureFinalize)(&u); API(nvnTextureFinalize)(&t); cases++;
    }
    API(nvnTextureFinalize)(&s);
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&gpu_pool); API(nvnMemoryPoolFinalize)(&cpu_pool); API(nvnMemoryPoolFinalize)(&cmd_pool); API(nvnDeviceFinalize)(&device);
    if (fails) { printf("✗ t_nvn_firstuse：%u 项检查里 %u 项不符\n",checks,fails); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_firstuse：%u 例 %u 项检查全过（CPU 改写存储后同存储同描述新建的贴图读到新内容）\n",cases,checks); return 0;
}}

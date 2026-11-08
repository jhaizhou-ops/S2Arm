// 脏页轮询发布 CPU 后写的贴图（hle_nvn.c nvn_ft_poll，11-05 时之笛首屏按钮文字不显示）：公开 NVN 接口 → 真实 Metal 提交 → GPU 读回。期望值按 Switch 语义手写，不由被测实现推出：
//   Switch 上 CPU / GPU 读写同一份内存。贴图被 GPU 读过之后，CPU 不 Flush 直接往它的存储写新字节（不经缓存的池，字库缓存就是这样），GPU 再读必须是新字节；
//   GPU 自己写过贴图（清屏）、CPU 只写了同一页里别处的字节，贴图字节仍是 GPU 写的；CPU 之后又写了贴图自己的字节，GPU 再读是 CPU 新写的。
// 只验轮询这一条：不调 Flush（刷新那条见 t_nvn_poolflush），tex_dirty_upload / tex_flush_upload 照缺省开。
// 每例的存储都在建贴图之前写好：建贴图时登记的「写过没有」从这之后算，第一次读就不会走「首用前 CPU 写过」那条（nvn_ft_written），宿主建的是 GPU 侧贴图（存储内容作初值）。
// 存储整段填同一个 4 字节色值，RGBA8 每个纹素都是它，与块线性布局无关。
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
static NVNmemoryPool cmd_pool, pool;
static NVNcommandBuffer commands;
static void *cmd_storage, *pool_storage;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { POOL_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, SIDE = 8, NEIGHBOUR = 8192 };   // NEIGHBOUR：贴图后面同一页里的字节（贴图 256 字节，宿主页 4 / 16 KB）
static size_t tex_off = 1 << 20;   // 每例的贴图各占一块新存储（64 KB 对齐，同存储同描述再建会接上旧对象的 GPU 内容，见 t_nvn_initfill）
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void pool_init(NVNmemoryPool *p, void **storage) {
    REQUIRE(posix_memalign(storage,65536,POOL_SIZE)==0); memset(*storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,*storage,POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(p,&pb));
}
// 写保护缺页交给直连层的缺页入口（宿主 crash.c 的做法，同 t_nvn_pkg_sub）：CPU 写被保护的贴图页 → 放开页、记代号、重执行
static void on_sig(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }
static void setup(void) {
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    pool_init(&cmd_pool,&cmd_storage); pool_init(&pool,&pool_storage);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&cmd_pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
static size_t storage_size(void) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device); API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,SIDE,SIDE); API(nvnTextureBuilderSetLevels)(&b,1); API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8);
    return API(nvnTextureBuilderGetStorageSize)(&b);
}
static void make(NVNtexture *t) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device); API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,SIDE,SIDE); API(nvnTextureBuilderSetLevels)(&b,1); API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8);
    API(nvnTextureBuilderSetStorage)(&b,&pool,(ptrdiff_t)tex_off); REQUIRE(API(nvnTextureInitialize)(t,&b));
}
static void fill(size_t bytes, const uint8_t rgba[4]) { for (size_t i=0; i<bytes; i+=4) memcpy((uint8_t *)pool_storage+tex_off+i,rgba,4); }
// GPU 把整张贴图拷到命令池 READ_OFFSET（贴图是源，不算 GPU 写它），逐纹素比 want
static void read_check(NVNtexture *t, const uint8_t want[4], const char *what) {
    memset((uint8_t *)cmd_storage+READ_OFFSET,0xA5,SIDE*SIDE*4);
    NVNcopyRegion whole={0,0,0,SIDE,SIDE,1}; NVNbufferAddress dst=API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,dst,0); submit();
    const uint8_t *p=(const uint8_t *)cmd_storage+READ_OFFSET; int bad=0;
    for (int i=0; i<SIDE*SIDE; i++) bad+=memcmp(p+4*i,want,4)!=0;
    checks++; if (bad) { fails++; printf("FAIL %s：%s，%d/%d 纹素不符（第 0 个 %02x %02x %02x %02x，期望 %02x %02x %02x %02x）\n",phase,what,bad,SIDE*SIDE,p[0],p[1],p[2],p[3],want[0],want[1],want[2],want[3]); }
}
static void gpu_clear(NVNtexture *t) {   // GPU 写整张贴图：清成 (0, 1, 0, 1)，RGBA8 字节 00 ff 00 ff
    static const float green[4]={0.f,1.f,0.f,1.f}; NVNcopyRegion whole={0,0,0,SIDE,SIDE,1};
    begin(); API(nvnCommandBufferClearTexture)(&commands,t,NULL,&whole,green,0xF); submit();
}
static const uint8_t old_rgba[4]={0x11,0x22,0x33,0x44}, new_rgba[4]={0x55,0x66,0x77,0x88}, green_rgba[4]={0x00,0xff,0x00,0xff};
enum { CPU_ONLY, GPU_THEN_NEIGHBOUR, GPU_THEN_CPU };
static void one(int kind, const char *name) {
    phase=name; tex_off+=65536;
    size_t bytes=storage_size(); REQUIRE(bytes && bytes<NEIGHBOUR && tex_off+NEIGHBOUR+4<=READ_OFFSET);
    fill(bytes,old_rgba);   // 建贴图前写好初值
    NVNtexture t; make(&t);
    read_check(&t,old_rgba,"第一次读到建贴图前写的色");
    if (kind==CPU_ONLY) {
        fill(bytes,new_rgba);   // 不 Flush：只有写保护能看见
        read_check(&t,new_rgba,"CPU 后写的新色（没有 GPU 写过它）");
    } else {
        gpu_clear(&t); read_check(&t,green_rgba,"GPU 清成的绿");
        if (kind==GPU_THEN_NEIGHBOUR) {
            memcpy((uint8_t *)pool_storage+tex_off+NEIGHBOUR,new_rgba,4);   // 同一页里贴图之外的字节：贴图自己的字节没动
            read_check(&t,green_rgba,"CPU 只写同页别处，贴图仍是 GPU 写的绿");
        } else {
            fill(bytes,new_rgba);
            read_check(&t,new_rgba,"GPU 写过之后 CPU 又写了贴图本身，读到 CPU 新写的色");
        }
    }
    API(nvnTextureFinalize)(&t); cases++;
}
int main(int argc, char **argv) { @autoreleasepool {
    (void)argv; if (argc!=1) { fprintf(stderr,"用法：%s\n",argv[0]); return 2; }
    setup();
    one(CPU_ONLY,"GPU 读过的未压缩贴图，CPU 不 Flush 再写：轮询发布");
    one(GPU_THEN_NEIGHBOUR,"GPU 写过的贴图，CPU 只写同页别处：保留 GPU 内容");
    one(GPU_THEN_CPU,"GPU 写过的贴图，CPU 再写它自己的字节：CPU 后写的赢");
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&pool); API(nvnMemoryPoolFinalize)(&cmd_pool); API(nvnDeviceFinalize)(&device);
    if (fails) { printf("✗ t_nvn_ftpoll：%u 项检查里 %u 项不符\n",checks,fails); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_ftpoll：%u 例 %u 项检查全过（脏页轮询按 GPU 写账发布 CPU 后写的贴图）\n",cases,checks); return 0;
}}

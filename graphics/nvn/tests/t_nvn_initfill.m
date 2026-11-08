// 贴图初始内容（nvn_mtl.m tex_init_fill）：公开 NVN 接口 → 真实 Metal 提交 → GPU 读回。期望值按 Switch 语义手写，不由被测实现推出：
//   CPU 可写池里，GPU 还没写过的新贴图内容就是那块存储（游戏没 Flush 也一样，巫师3 先读文件进池再建贴图）；GPU 写过之后不能被存储里的旧字节覆盖。
// 存储整段填同一个 4 字节色值，RGBA8 每个纹素都是它，与块线性布局无关。--baseline 只跑正例（旧实现读到 0，判据不会绿着失效）。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static void *storage;
static size_t texture_offset = 2 << 20;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 1 << 20, SIDE = 8 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device);
    REQUIRE(API(nvnQueueInitialize)(&queue,&qb)); REQUIRE(posix_memalign(&storage,65536,POOL_SIZE)==0); memset(storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,storage,POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
// 下一块贴图存储的位置与大小（不建贴图）：调用方可以先往这块存储写内容，再建贴图
static void builder(NVNtextureBuilder *b, size_t *off, size_t *bytes) {
    API(nvnTextureBuilderSetDefaults)(b); API(nvnTextureBuilderSetDevice)(b,&device); API(nvnTextureBuilderSetTarget)(b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(b,SIDE,SIDE); API(nvnTextureBuilderSetLevels)(b,1); API(nvnTextureBuilderSetFormat)(b,NVN_FORMAT_RGBA8);
    size_t al=API(nvnTextureBuilderGetStorageAlignment)(b); *bytes=API(nvnTextureBuilderGetStorageSize)(b); REQUIRE(al && *bytes);
    // 每张贴图独占 64 KB：建贴图会给它的页加写保护（tex_flush_upload 缺省开，hle_nvn.c ft_add），本进程没有宿主的写保护信号处理，下一张的 CPU 写不能落在同一页
    al=al>65536?al:65536; texture_offset=(texture_offset+al-1)/al*al; *off=texture_offset; REQUIRE(*off+*bytes<=POOL_SIZE);
}
static void fill(size_t off, size_t bytes, const uint8_t rgba[4]) { for (size_t i=0; i<bytes; i+=4) memcpy((uint8_t *)storage+off+i,rgba,4); }   // 不 Flush
static void make(NVNtexture *t, NVNtextureBuilder *b, size_t off, size_t bytes, int advance) {
    API(nvnTextureBuilderSetStorage)(b,&pool,(ptrdiff_t)off); REQUIRE(API(nvnTextureInitialize)(t,b)); if (advance) texture_offset=off+bytes;
}
// GPU 把整张贴图拷到池里 READ_OFFSET（贴图在这次提交里第一次被 GPU 用，或之前已用过），逐纹素比 want
static void read_check(NVNtexture *t, const uint8_t want[4], const char *what) {
    memset((uint8_t *)storage+READ_OFFSET,0xA5,SIDE*SIDE*4);
    NVNcopyRegion whole={0,0,0,SIDE,SIDE,1}; NVNbufferAddress dst=API(nvnMemoryPoolGetBufferAddress)(&pool)+READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,dst,0); submit();
    const uint8_t *p=(const uint8_t *)storage+READ_OFFSET; int bad=0;
    for (int i=0; i<SIDE*SIDE; i++) bad+=memcmp(p+4*i,want,4)!=0;
    checks++; if (bad) { fails++; printf("FAIL %s：%s，%d/%d 纹素不符（第 0 个 %02x %02x %02x %02x，期望 %02x %02x %02x %02x）\n",phase,what,bad,SIDE*SIDE,p[0],p[1],p[2],p[3],want[0],want[1],want[2],want[3]); }
}
static const uint8_t cpu_rgba[4]={0x11,0x22,0x33,0x44}, gpu_rgba[4]={0xff,0x80,0x00,0xff};
static const float gpu_f[4]={1.0f,128.0f/255.0f,0.0f,1.0f};
static void cpu_before_init(void) {
    phase="CPU 先写池（不 Flush）再建贴图，GPU 第一次读到写进去的内容";
    NVNtextureBuilder b; size_t off,bytes; builder(&b,&off,&bytes); fill(off,bytes,cpu_rgba);
    NVNtexture t; make(&t,&b,off,bytes,1); read_check(&t,cpu_rgba,"读到 CPU 写的色"); API(nvnTextureFinalize)(&t); cases++;
}
// COMPRESSIBLE 只是压缩提示、不是数据格式（上游参考实现（MIT）733dff9d）：CPU 可写池里带它的新贴图同样读到 CPU 写的内容（旧代码一律不填 → 读到 0）
static void cpu_before_init_compressible(void) {
    phase="CPU 可写池里带 COMPRESSIBLE 的贴图：CPU 先写池再建贴图，GPU 第一次读到写进去的内容";
    NVNtextureBuilder b; size_t off,bytes; builder(&b,&off,&bytes); fill(off,bytes,cpu_rgba); API(nvnTextureBuilderSetFlags)(&b,NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    NVNtexture t; make(&t,&b,off,bytes,1); read_check(&t,cpu_rgba,"COMPRESSIBLE 贴图读到 CPU 写的色"); API(nvnTextureFinalize)(&t); cases++;
}
static void gpu_write_first(void) {
    phase="池里有旧字节，GPU 第一次用它是清成另一色：读到清除色（填充在 GPU 第一次写之前）";
    NVNtextureBuilder b; size_t off,bytes; builder(&b,&off,&bytes); fill(off,bytes,cpu_rgba);
    NVNtexture t; make(&t,&b,off,bytes,1);
    NVNcopyRegion whole={0,0,0,SIDE,SIDE,1}; begin(); API(nvnCommandBufferClearTexture)(&commands,&t,NULL,&whole,gpu_f,15); submit();
    read_check(&t,gpu_rgba,"读到 GPU 清除色");
    // 同一块存储、同描述再建一个贴图对象（游戏复用对象 / 别名）：GPU 写过的内容不能被存储里的旧字节重新填掉
    phase="GPU 写过后同存储同描述再建贴图对象：仍是 GPU 内容";
    NVNtexture u; make(&u,&b,off,bytes,0); read_check(&u,gpu_rgba,"别名读到 GPU 清除色");
    API(nvnTextureFinalize)(&u); API(nvnTextureFinalize)(&t); cases+=2;
}
// 同一块存储上只差用途 flags 的另一个贴图对象（异度神剑3：G-buffer 深度模板带 COMPRESSIBLE，材质遍从同一块存储另建一个 COMPRESSIBLE | IMAGE 的对象读模板）：
//   Switch 上是同一块内存，读到的必须是 GPU 写过的内容；原先别名键带全部 flags，第二个对象另建成新贴图，读到存储里的旧字节
static void gpu_write_alias_flags(void) {
    phase="GPU 写过后同存储、只差用途 flags（COMPRESSIBLE → COMPRESSIBLE | IMAGE）再建贴图对象：仍是 GPU 内容";
    NVNtextureBuilder b; size_t off,bytes; builder(&b,&off,&bytes); fill(off,bytes,cpu_rgba);
    API(nvnTextureBuilderSetFlags)(&b,NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    NVNtexture t; make(&t,&b,off,bytes,1);
    NVNcopyRegion whole={0,0,0,SIDE,SIDE,1}; begin(); API(nvnCommandBufferClearTexture)(&commands,&t,NULL,&whole,gpu_f,15); submit();
    read_check(&t,gpu_rgba,"读到 GPU 清除色");
    API(nvnTextureBuilderSetFlags)(&b,NVN_TEXTURE_FLAGS_COMPRESSIBLE|NVN_TEXTURE_FLAGS_IMAGE);
    NVNtexture u; make(&u,&b,off,bytes,0); read_check(&u,gpu_rgba,"只差用途 flags 的对象读到 GPU 清除色");
    API(nvnTextureFinalize)(&u); API(nvnTextureFinalize)(&t); cases+=2;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc>2 || (argc==2 && strcmp(argv[1],"--baseline"))) { fprintf(stderr,"用法：%s [--baseline]\n",argv[0]); return 2; }
    setup(); cpu_before_init();
    if (argc==1) { cpu_before_init_compressible(); gpu_write_first(); gpu_write_alias_flags(); }
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue); API(nvnMemoryPoolFinalize)(&pool); API(nvnDeviceFinalize)(&device); free(storage);
    if (fails) { printf("✗ t_nvn_initfill：%u 项检查里 %u 项不符\n",checks,fails); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_initfill：%u 例 %u 项检查全过（CPU 可写池未 Flush 的新贴图读到存储内容；GPU 写过的不被旧字节覆盖）\n",cases,checks); return 0;
}}

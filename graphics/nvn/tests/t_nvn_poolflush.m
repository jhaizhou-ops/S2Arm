// 刷新发布 CPU 写的贴图（hle_nvn.c ft_flush，缺口扫描 11-01 族 42）：公开 NVN 接口 → 真实 Metal 提交 → GPU 读回。期望值按 Switch 语义手写，不由被测实现推出：
//   贴图被 GPU 用过之后，CPU 往它的存储写新字节并 Flush（池上或盖住这段的缓冲对象上），GPU 再读必须是新字节（Switch 上 CPU / GPU 同一份内存，Flush 只是让 CPU 缓存落到内存）。
//   CPU 不经缓存（CPU_UNCACHED）的池上 Flush 在真机是空操作，内存本来就是新的：GPU 同样读到新字节。
// 只验刷新这一条：随包 game.tsv 写 tex_dirty_upload off（写保护脏页那条另有 t_dirty_*），贴图页不加写保护，本进程写贴图存储不缺页，也不会被脏页轮询顺带发布。
// 存储整段填同一个 4 字节色值，RGBA8 每个纹素都是它，与块线性布局无关。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool cmd_pool, cached, uncached;
static NVNcommandBuffer commands;
static void *cmd_storage, *cached_storage, *uncached_storage;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { POOL_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, SIDE = 8 };
static size_t tex_off = 1 << 20;   // 每例的贴图各占一块新存储（同存储同描述再建贴图会接上旧对象的 GPU 内容，见 t_nvn_initfill），64 KB 对齐
static char data_dir[256];
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void pool_init(NVNmemoryPool *p, void **storage, int flags) {
    REQUIRE(posix_memalign(storage,65536,POOL_SIZE)==0); memset(*storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,*storage,POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb,flags);
    REQUIRE(API(nvnMemoryPoolInitialize)(p,&pb));
}
static void setup(void) {
    // 随包 game.tsv：只关脏页上传，tex_flush_upload 照缺省开（宿主 host_adapt.m 起局读 $S2A_GAME_DATA/shaders/direct/game.tsv 一次）
    char *dir=data_dir; snprintf(data_dir,sizeof data_dir,"%s/t_nvn_poolflush.%d",getenv("TMPDIR")?getenv("TMPDIR"):"/tmp",(int)getpid());
    char p[512]; snprintf(p,sizeof p,"%s/shaders",dir); mkdir(dir,0700); mkdir(p,0700); snprintf(p,sizeof p,"%s/shaders/direct",dir); mkdir(p,0700);
    snprintf(p,sizeof p,"%s/shaders/direct/game.tsv",dir); FILE *f=fopen(p,"w"); REQUIRE(f!=NULL); fputs("tex_dirty_upload\toff\n",f); fclose(f);
    setenv("S2A_GAME_DATA",dir,1);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    pool_init(&cmd_pool,&cmd_storage,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    pool_init(&cached,&cached_storage,NVN_MEMORY_POOL_FLAGS_CPU_CACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    pool_init(&uncached,&uncached_storage,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&cmd_pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
// 两个池开头各清一张贴图（偏移 0，各例的贴图从 1 MB 起）：池算「GPU 写过」，池里未压缩 2D 贴图首用时不按存储取成 CPU 写过（nvn_mtl.m tex_cpu_content，
//   那条会给贴图页加写保护，本进程没有缺页处理），本单测验的仍只是 Flush 这一条发布路径
static void mark_gpu_written(NVNmemoryPool *p) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device); API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,SIDE,SIDE); API(nvnTextureBuilderSetLevels)(&b,1); API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8);
    API(nvnTextureBuilderSetStorage)(&b,p,0); NVNtexture t; REQUIRE(API(nvnTextureInitialize)(&t,&b));
    static const float zero[4]={0,0,0,0}; NVNcopyRegion whole={0,0,0,SIDE,SIDE,1};
    begin(); API(nvnCommandBufferClearTexture)(&commands,&t,NULL,&whole,zero,0xF); submit(); API(nvnTextureFinalize)(&t);
}
static size_t make(NVNtexture *t, NVNmemoryPool *p) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device); API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,SIDE,SIDE); API(nvnTextureBuilderSetLevels)(&b,1); API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8);
    size_t bytes=API(nvnTextureBuilderGetStorageSize)(&b); REQUIRE(bytes && tex_off+bytes<=READ_OFFSET);
    API(nvnTextureBuilderSetStorage)(&b,p,(ptrdiff_t)tex_off); REQUIRE(API(nvnTextureInitialize)(t,&b)); return bytes;
}
static void fill(void *storage, size_t bytes, const uint8_t rgba[4]) { for (size_t i=0; i<bytes; i+=4) memcpy((uint8_t *)storage+tex_off+i,rgba,4); }
// GPU 把整张贴图拷到命令池 READ_OFFSET，逐纹素比 want
static void read_check(NVNtexture *t, const uint8_t want[4], const char *what) {
    memset((uint8_t *)cmd_storage+READ_OFFSET,0xA5,SIDE*SIDE*4);
    NVNcopyRegion whole={0,0,0,SIDE,SIDE,1}; NVNbufferAddress dst=API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,dst,0); submit();
    const uint8_t *p=(const uint8_t *)cmd_storage+READ_OFFSET; int bad=0;
    for (int i=0; i<SIDE*SIDE; i++) bad+=memcmp(p+4*i,want,4)!=0;
    checks++; if (bad) { fails++; printf("FAIL %s：%s，%d/%d 纹素不符（第 0 个 %02x %02x %02x %02x，期望 %02x %02x %02x %02x）\n",phase,what,bad,SIDE*SIDE,p[0],p[1],p[2],p[3],want[0],want[1],want[2],want[3]); }
}
static const uint8_t old_rgba[4]={0x11,0x22,0x33,0x44}, new_rgba[4]={0x55,0x66,0x77,0x88};
enum { VIA_POOL, VIA_BUFFER };
// 贴图先被 GPU 读过一次（宿主据此建好 GPU 侧贴图），CPU 再写新字节并 Flush，GPU 第二次读
static void publish(NVNmemoryPool *p, void *storage, int via, const char *name) {
    phase=name;
    tex_off+=65536; NVNtexture t; size_t bytes=make(&t,p); fill(storage,bytes,old_rgba); read_check(&t,old_rgba,"第一次读到建贴图前写的色");
    fill(storage,bytes,new_rgba);
    if (via==VIA_POOL) API(nvnMemoryPoolFlushMappedRange)(p,(ptrdiff_t)tex_off,bytes);
    else {   // 缓冲对象从池的 64 KB 处起、盖住贴图那段（偏移相对缓冲起点）
        NVNbufferBuilder bb; NVNbuffer buf; API(nvnBufferBuilderSetDefaults)(&bb); API(nvnBufferBuilderSetDevice)(&bb,&device);
        API(nvnBufferBuilderSetStorage)(&bb,p,65536,READ_OFFSET-65536); REQUIRE(API(nvnBufferInitialize)(&buf,&bb));
        API(nvnBufferFlushMappedRange)(&buf,(ptrdiff_t)tex_off-65536,bytes); API(nvnBufferFinalize)(&buf);
    }
    read_check(&t,new_rgba,"Flush 后读到 CPU 新写的色");
    API(nvnTextureFinalize)(&t); cases++;
}
int main(int argc, char **argv) { @autoreleasepool {
    (void)argv; if (argc!=1) { fprintf(stderr,"用法：%s\n",argv[0]); return 2; }
    setup(); mark_gpu_written(&cached); mark_gpu_written(&uncached);
    publish(&cached,cached_storage,VIA_POOL,"CPU_CACHED 池上 Flush 发布 CPU 新写的贴图");
    publish(&cached,cached_storage,VIA_BUFFER,"盖住贴图的缓冲对象上 Flush 同样发布（缓冲转调池的刷新）");
    publish(&uncached,uncached_storage,VIA_POOL,"CPU_UNCACHED 池上 Flush 也发布（真机内存本来就是新的）");
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&cached); API(nvnMemoryPoolFinalize)(&uncached); API(nvnMemoryPoolFinalize)(&cmd_pool); API(nvnDeviceFinalize)(&device);
    { char p[512]; snprintf(p,sizeof p,"%s/shaders/direct/game.tsv",data_dir); unlink(p); snprintf(p,sizeof p,"%s/shaders/direct",data_dir); rmdir(p); snprintf(p,sizeof p,"%s/shaders",data_dir); rmdir(p); rmdir(data_dir); }
    if (fails) { printf("✗ t_nvn_poolflush：%u 项检查里 %u 项不符\n",checks,fails); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_poolflush：%u 例 %u 项检查全过（池 / 缓冲上的 Flush 发布 CPU 写过的贴图）\n",cases,checks); return 0;
}}

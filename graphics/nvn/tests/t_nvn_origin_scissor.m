// 公开 NVN bootstrap → 窗口原点与带裁剪的清屏（审计缺口族 35「左下角的 y」，11-01）：
// NVN 的左下角原点是 GL 约定：窗口 y 从渲染目标第 0 行（贴图坐标 y = 0）往上数，与左上角原点指向同一批内存行，只是视口内部方向相反（nvn_mtl.m g_origin_ll）。
// 所以裁剪框 (0, 0, N, N/2) 在两种原点下都盖住内存第 0..N/2-1 行；读回（CopyTextureToBuffer 按贴图行）不随原点变。
// 期望值按这条语义写死，不跑被测实现：
// A：左上角原点，整幅清蓝，再裁剪 (0, 0, N, N/2) 清红 → 前 N/2 行红、后 N/2 行蓝。
// B：左下角原点，同样操作 → 同样前 N/2 行红、后 N/2 行蓝（审计推断「裁剪没翻、会切到对面那一条」：若真要翻，红会落在后 N/2 行）。
// C：左下角原点，裁剪 (0, N/4, N, N/4) 清红 → 第 N/4..N/2-1 行红、其余蓝（非零起点也按内存行，不按 N − y 翻）。
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
static NVNmemoryPool tex_pool, cmd_pool;
static NVNcommandBuffer commands;
static void *tex_storage, *cmd_storage;
static unsigned cases, texels, checks;
static const char *phase = "初始化";
enum { TEX_POOL_SIZE = 1 << 20, CMD_POOL_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, N = 64 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void make_pool(NVNmemoryPool *p, void *s, size_t size, int flags) {
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,s,size); API(nvnMemoryPoolBuilderSetFlags)(&pb,flags); REQUIRE(API(nvnMemoryPoolInitialize)(p,&pb));
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&cmd_pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
static void done(void) { cases++; printf("PASS %s\n",phase); fflush(stdout); }
// 整幅清蓝，再按裁剪框 (0, y, N, h) 清红，读回；期望红行 [r0, r1)
static void run(NVNtexture *t, NVNwindowOriginMode origin, int y, int h, int r0, int r1) {
    API(nvnDeviceSetWindowOriginMode)(&device,origin);
    static const float blue[4]={0,0,1,1}, red[4]={1,0,0,1};
    const NVNtexture *rt[]={t};
    begin();
    API(nvnCommandBufferSetRenderTargets)(&commands,1,rt,NULL,NULL,NULL); API(nvnCommandBufferSetViewport)(&commands,0,0,N,N);
    API(nvnCommandBufferSetScissor)(&commands,0,0,N,N); API(nvnCommandBufferClearColor)(&commands,0,blue,15);
    API(nvnCommandBufferSetScissor)(&commands,0,y,N,h); API(nvnCommandBufferClearColor)(&commands,0,red,15);
    API(nvnCommandBufferSetRenderTargets)(&commands,0,NULL,NULL,NULL,NULL);
    memset((uint8_t *)cmd_storage+READ_OFFSET,0xA5,N*N*4);
    NVNcopyRegion whole={0,0,0,N,N,1};
    API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET,0);
    submit();
    static const uint8_t R[4]={0xff,0,0,0xff}, B[4]={0,0,0xff,0xff};
    const uint8_t *got=(const uint8_t *)cmd_storage+READ_OFFSET;
    for (int i=0; i<N*N; i++, texels++) {
        int row=i/N; const uint8_t *want=row>=r0 && row<r1 ? R : B;
        if (memcmp(got+i*4,want,4)) { fprintf(stderr,"FAIL [%s] texel(%d,%d) got %02x %02x %02x %02x，期望%s（红行 %d..%d）\n",phase,i%N,row,got[i*4],got[i*4+1],got[i*4+2],got[i*4+3],want==R?"红":"蓝",r0,r1-1); exit(1); }
    }
    done();
}
int main(int argc, char **argv) { @autoreleasepool {
    (void)argv; if (argc!=1) { fprintf(stderr,"用法：%s\n",argv[0]); return 2; }
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(posix_memalign(&tex_storage,65536,TEX_POOL_SIZE)==0); memset(tex_storage,0,TEX_POOL_SIZE);
    make_pool(&tex_pool,tex_storage,TEX_POOL_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(posix_memalign(&cmd_storage,65536,CMD_POOL_SIZE)==0); memset(cmd_storage,0,CMD_POOL_SIZE);
    make_pool(&cmd_pool,cmd_storage,CMD_POOL_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b,N,N); API(nvnTextureBuilderSetLevels)(&b,1);
    API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetStorage)(&b,&tex_pool,0);
    REQUIRE(API(nvnTextureBuilderGetStorageSize)(&b)<=TEX_POOL_SIZE);
    NVNtexture t; REQUIRE(API(nvnTextureInitialize)(&t,&b));
    phase="A：左上角原点，裁剪 (0,0,N,N/2) 清红 → 内存前 N/2 行红"; run(&t,NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT,0,N/2,0,N/2);
    phase="B：左下角原点，裁剪 (0,0,N,N/2) 清红 → 同样内存前 N/2 行红（窗口 y 与内存行同向，裁剪不按 N − y 翻）"; run(&t,NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT,0,N/2,0,N/2);
    phase="C：左下角原点，裁剪 (0,N/4,N,N/4) 清红 → 内存第 N/4..N/2-1 行红"; run(&t,NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT,N/4,N/4,N/4,N/2);
    API(nvnDeviceSetWindowOriginMode)(&device,NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT);
    API(nvnTextureFinalize)(&t); API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&tex_pool); API(nvnMemoryPoolFinalize)(&cmd_pool); API(nvnDeviceFinalize)(&device); free(tex_storage); free(cmd_storage);
    printf("✓ t_nvn_origin_scissor：%u 组、%u 个真实 GPU texel、%u 条公开 API / 完成状态检查\n",cases,texels,checks); return 0;
}}

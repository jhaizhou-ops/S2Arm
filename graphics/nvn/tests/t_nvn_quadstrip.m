// 四边形条带（NVN_DRAW_PRIMITIVE_QUAD_STRIP = 8；11-06 无人深空测试机1：回放报「primitive type 8 not implemented」整笔丢掉）：
//   公开 NVN 接口录 DrawArrays / DrawElements 四边形条带，提交回放、GPU 读回 8×8 目标里的红像素数。
// 期望按 GL 四边形条带定义手算，不跑被测实现推：顶点按 vertex_id 取 (-1,-1) (-1,1) (0,-1) (0,1) (1,-1) (1,1)，
//   第 i 个四边形 = 顶点 2i、2i+1、2i+3、2i+2；6 个顶点 = 两个四边形铺满全屏 = 64；4 个顶点 = 左半 x∈[-1,0) = 4 列 × 8 行 = 32；
//   3 个顶点不够一个四边形 = 0（三角形条带会画出 (-1,-1)(-1,1)(0,-1) 那个三角形，所以这一格能分出「按三角形条带硬画」）；
//   7 个顶点 = 落单的第 7 个不画 = 64，且第 7 个顶点取 (1,-1) 之外的远点也不越界（这里与 6 个同为 64，只判不崩不报错）。
//   不剔除（缺省多边形状态）。DrawArrays / DrawElements（16 位索引 0..6）各判一遍。
#ifndef NVN_WIND_SOURCE
#define NVN_WIND_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_WIND_SOURCE
#include "../gfx/nvn/nvn_protos.h"
#include <signal.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
static void *api(const char *name) { void *p = h_nvnBootstrapLoader(name); if (!p) { printf("✗ 取不到 %s\n", name); exit(1); } return p; }
#define API(name) ((NVNT_##name)api(#name))
static void on_alarm(int s) { (void)s; static const char m[] = "✗ t_nvn_quadstrip：60 秒没返回\n"; write(1, m, sizeof m - 1); _exit(1); }
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 vs(uint i [[vertex_id]]) { const float2 p[7]={float2(-1,-1),float2(-1,1),float2(0,-1),float2(0,1),float2(1,-1),float2(1,1),float2(-1,0)}; return float4(p[min(i,6u)],0,1); }\n"
"fragment float4 fs() { return float4(1,0,0,1); }\n";
enum { POOL = 16 << 20, CMD = 1 << 20, RT = 8 << 20, IB = 12 << 20, W = 8 };
static NVNdevice dev; static NVNqueue q; static NVNmemoryPool pool; static NVNcommandBuffer cmd; static uint8_t control[16384];
static NVNtexture rt; static prog_t prog;
static void make_queue(NVNwindowOriginMode at_queue) {
    API(nvnDeviceSetWindowOriginMode)(&dev, at_queue);
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &dev); API(nvnQueueInitialize)(&q, &qb);
}

static void setup(void) {
    char map[] = "/tmp/t_qstrip_map_XXXXXX", user[] = "/tmp/t_qstrip_user_XXXXXX"; int fd = mkstemp(map); close(fd); fd = mkstemp(user); close(fd);
    setenv("DM_NVN_SHMAP", map, 1); setenv("DM_PSO_USER", user, 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); if (!API(nvnDeviceInitialize)(&dev, &db)) { printf("✗ 设备\n"); exit(1); }
    make_queue(NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT); API(nvnDeviceSetWindowOriginMode)(&dev, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT); mtl_init(); g_wd = 0;
    uint8_t *mem = NULL; if (posix_memalign((void **)&mem, 65536, POOL)) exit(1); memset(mem, 0, POOL); for (int i = 0; i < 7; i++) ((uint16_t *)(mem + IB))[i] = (uint16_t)i;
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &dev);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, POOL); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolInitialize)(&pool, &pb); API(nvnCommandBufferInitialize)(&cmd, &dev); API(nvnCommandBufferAddControlMemory)(&cmd, control, sizeof control);
    NVNtextureBuilder tb; API(nvnTextureBuilderSetDefaults)(&tb); API(nvnTextureBuilderSetDevice)(&tb, &dev); API(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&tb, W, W); API(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetLevels)(&tb, 1);
    API(nvnTextureBuilderSetStorage)(&tb, &pool, RT); API(nvnTextureInitialize)(&rt, &tb);
    NSError *err = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&err]; if (!lib) { printf("✗ 着色器：%s\n", err.localizedDescription.UTF8String); exit(1); }
    NvProg *pr = [NvProg new]; NvShader *v = [NvShader new], *f = [NvShader new];
    v->stage = 0; v->fn = [lib newFunctionWithName:@"vs"]; strlcpy(v->key, "f1d0000000000000_b", sizeof v->key); v->rf.pos_attr = -1; v->rf.has_user = 1;
    f->stage = 1; f->fn = [lib newFunctionWithName:@"fs"]; strlcpy(f->key, "f1d0000000000001_b", sizeof f->key); f->rf.pos_attr = -1; f->rf.has_user = 2; f->rf.color_known = 1; f->rf.color_mask = 1;
    pr->sh[0] = v; pr->sh[1] = f; pr->smask = 3;
    prog = (prog_t){.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(prog.serial, pr);
}
// 画一遍四边形条带（indexed = 走 DrawElements，索引 0..6 放在池 IB 处），返回被画成红的像素数
static int qdraw(int indexed, int count) {
    API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, 0, CMD); API(nvnCommandBufferBeginRecording)(&cmd);
    const NVNtexture *colors[] = {&rt}; const float black[4] = {0, 0, 0, 1};
    API(nvnCommandBufferSetRenderTargets)(&cmd, 1, colors, NULL, NULL, NULL); API(nvnCommandBufferClearColor)(&cmd, 0, black, 15);
    API(nvnCommandBufferSetViewport)(&cmd, 0, 0, W, W); API(nvnCommandBufferSetScissor)(&cmd, 0, 0, W, W);
    NVNpolygonState ps; API(nvnPolygonStateSetDefaults)(&ps); API(nvnPolygonStateSetCullFace)(&ps, NVN_FACE_NONE); API(nvnCommandBufferBindPolygonState)(&cmd, &ps);
    API(nvnCommandBufferBindProgram)(&cmd, (const NVNprogram *)&prog, NVN_SHADER_STAGE_ALL_GRAPHICS_BITS);
    if (indexed) API(nvnCommandBufferDrawElements)(&cmd, NVN_DRAW_PRIMITIVE_QUAD_STRIP, NVN_INDEX_TYPE_UNSIGNED_SHORT, count, API(nvnMemoryPoolGetBufferAddress)(&pool) + IB);
    else API(nvnCommandBufferDrawArrays)(&cmd, NVN_DRAW_PRIMITIVE_QUAD_STRIP, 0, count);
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&cmd);
    API(nvnQueueSubmitCommands)(&q, 1, &h); API(nvnQueueFinish)(&q);
    if (mtl_last_commit_error()) { printf("✗ GPU 报错\n"); exit(1); }
    id<MTLTexture> t = tex_mtl((const tex_t *)&rt); id<MTLBuffer> out = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> cq = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint8_t *px = out.contents; int red = 0; for (int i = 0; i < W * W; i++) red += px[4 * i] > 200 && px[4 * i + 1] < 50;
    return red;
}

int main(void) { @autoreleasepool {
    signal(SIGALRM, on_alarm); alarm(60);
    setup();
    static const struct { int count, want; } C[] = {{6, 64}, {4, 32}, {3, 0}, {7, 64}};   // 见文件头
    int bad = 0, n = 0;
    for (int ix = 0; ix < 2; ix++) for (int k = 0; k < 4; k++) {
        int got = qdraw(ix, C[k].count), ok = got == C[k].want; n++; if (!ok) bad++;
        printf("%s %s 四边形条带 %d 个顶点：红 %d 像素（应 %d）\n", ok ? "✓" : "✗", ix ? "DrawElements" : "DrawArrays", C[k].count, got, C[k].want);
    }
    printf("%s t_nvn_quadstrip：%d 格，不符 %d（Metal %s）\n", bad ? "✗" : "✓", n, bad, g_m3 ? "3" : "4");
    return bad ? 1 : 0;
} }

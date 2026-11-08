// 正面绕序 × 窗口原点 × 建队列时机（11-05 极品飞车热力追踪重制版：直连下车身、地形全黑，通用模式正常）：
//   公开 NVN 接口录命令、提交回放、GPU 读回，判一个三角形在「剔除背面」时画没画出来。
// 期望按游戏自带驱动 + Ryujinx 的寄存器语义写死，不跑被测实现推：
//   驱动：正面寄存器 = API 值；Y_CONTROL 的 TriangleRastFlip 只在 QueueInitialize 里写一次，= 建队列那一刻设备原点不是左上角
//     （极品飞车 SDK 10 / 暗黑3 SDK 8 的 sdk 模块反汇编：QueueInitialize → 队列初值函数里 cmp [设备+0x1988], #1 ; csel 0x800004EB / 0x801004EB；SetWindowOriginMode 只存 +0x1988）。
//   通用模式真值（Ryujinx StateUpdater.UpdateFrontFace 打点）：极品飞车 先建队列后设左上（翻转开）、API 正面 CW；暗黑3 先设左上后建队列（翻转关）、API 正面 CCW——
//     两款都画得出规范化坐标逆时针的面（交给 Metal 的都是逆时针为正面）。左下角原点 + 翻转开 + API CCW 是 GL 约定：规范化坐标逆时针的面是正面。
//   这三个锚点之外的组合按「正面方向翻一次 = 画出与剔掉互换；翻转位翻一次 = 互换；原点翻一次 = 互换（同一规范化三角形在两种原点下屏幕上镜像）」推出：
//     规范化坐标逆时针的三角形 T 画得出 ⟺ (API 正面是 CCW) ⊕ (翻转开) ⊕ (原点是左下)。
//   八种组合（建队列时机 2 × API 正面 2 × 原点 2）各判一次；对照：不剔除时都画出（三角形确实落在目标里）。
// 每种组合判：8×8 目标里被画成红的像素数 > 0（画出）或 = 0（剔掉），不看落在哪几行。
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
static void on_alarm(int s) { (void)s; static const char m[] = "✗ t_nvn_winding：60 秒没返回\n"; write(1, m, sizeof m - 1); _exit(1); }
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 vs(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(1,-1),float2(-1,1)}; return float4(p[i],0,1); }\n"
"fragment float4 fs() { return float4(1,0,0,1); }\n";
enum { POOL = 16 << 20, CMD = 1 << 20, RT = 8 << 20, W = 8 };
static NVNdevice dev; static NVNqueue q; static NVNmemoryPool pool; static NVNcommandBuffer cmd; static uint8_t control[16384];
static NVNtexture rt; static prog_t prog;
// 先把设备原点设成 at_queue 再建（重建）队列：驱动在这一刻定光栅翻转
static void make_queue(NVNwindowOriginMode at_queue) {
    API(nvnDeviceSetWindowOriginMode)(&dev, at_queue);
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &dev); API(nvnQueueInitialize)(&q, &qb);
}

static void setup(void) {
    char map[] = "/tmp/t_wind_map_XXXXXX", user[] = "/tmp/t_wind_user_XXXXXX"; int fd = mkstemp(map); close(fd); fd = mkstemp(user); close(fd);
    setenv("DM_NVN_SHMAP", map, 1); setenv("DM_PSO_USER", user, 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); if (!API(nvnDeviceInitialize)(&dev, &db)) { printf("✗ 设备\n"); exit(1); }
    make_queue(NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT); mtl_init(); g_wd = 0;
    uint8_t *mem = NULL; if (posix_memalign((void **)&mem, 65536, POOL)) exit(1); memset(mem, 0, POOL);
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
// 画一遍，返回被画成红的像素数
static int wdraw(NVNwindowOriginMode at_queue, NVNwindowOriginMode origin, NVNface cull, NVNfrontFace front) {
    make_queue(at_queue); API(nvnDeviceSetWindowOriginMode)(&dev, origin);
    API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, 0, CMD); API(nvnCommandBufferBeginRecording)(&cmd);
    const NVNtexture *colors[] = {&rt}; const float black[4] = {0, 0, 0, 1};
    API(nvnCommandBufferSetRenderTargets)(&cmd, 1, colors, NULL, NULL, NULL); API(nvnCommandBufferClearColor)(&cmd, 0, black, 15);
    API(nvnCommandBufferSetViewport)(&cmd, 0, 0, W, W); API(nvnCommandBufferSetScissor)(&cmd, 0, 0, W, W);
    NVNpolygonState ps; API(nvnPolygonStateSetDefaults)(&ps); API(nvnPolygonStateSetCullFace)(&ps, cull); API(nvnPolygonStateSetFrontFace)(&ps, front);
    API(nvnCommandBufferBindPolygonState)(&cmd, &ps);
    API(nvnCommandBufferBindProgram)(&cmd, (const NVNprogram *)&prog, NVN_SHADER_STAGE_ALL_GRAPHICS_BITS);
    API(nvnCommandBufferDrawArrays)(&cmd, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3);
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
    const NVNwindowOriginMode LL = NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, UL = NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT;
    static const char *on[2] = {"左下", "左上"};
    int bad = 0, n = 0;
    for (int aq = 0; aq < 2; aq++) for (int org = 0; org < 2; org++) for (int ccw = 0; ccw < 2; ccw++) {
        NVNwindowOriginMode at_queue = aq ? UL : LL, origin = org ? UL : LL; NVNfrontFace front = ccw ? NVN_FRONT_FACE_CCW : NVN_FRONT_FACE_CW;
        int flip = at_queue != UL, want = (ccw ^ flip ^ (origin == LL)) & 1;   // 见文件头
        int none = wdraw(at_queue, origin, NVN_FACE_NONE, front), back = wdraw(at_queue, origin, NVN_FACE_BACK, front); n++;
        int ok = none > 0 && (back > 0) == want;
        if (!ok) bad++;
        printf("%s 建队列时%s（翻转%s）+ 画时%s原点 + 正面 %s + 剔背面：%s（红 %d 像素；不剔除对照 %d）%s\n", ok ? "✓" : "✗", on[aq], flip ? "开" : "关", on[org], ccw ? "CCW" : "CW",
               back > 0 ? "画出" : "剔掉", back, none, ok ? "" : (want ? "，应画出" : "，应剔掉"));
    }
    printf("%s t_nvn_winding：建队列时机 × 窗口原点 × 正面 %d 种组合，不符 %d（Metal %s）\n", bad ? "✗" : "✓", n, bad, g_m3 ? "3" : "4");
    return bad ? 1 : 0;
} }

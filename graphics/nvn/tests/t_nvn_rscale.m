// 直连内部分辨率（S2A_RES_SCALE，graphics/nvn/gfx/nvn/nvn_rscale*.inc）：公开 NVN bootstrap → 真实录制、Metal 提交、公开读回（同 t_nvn_partial_clear 的搭法）。
// 跑法：t_nvn_rscale scaled | off（native-test-nvn_rscale 各在 Metal 4 与 NXGAL_BE=mtl3 下跑一遍）。scaled 设 S2A_RES_SCALE=0.5，off 设 1。
// 期望全部手算（游戏坐标下按矩形填色，不跑被测实现），每步都带反证：
//   - 存储尺寸与缩放记录（nvn_be_tex_storage_size）：scaled 下可缩的渲染目标 64x48 → 32x24（RS_SCALED），off 下 64x48（RS_NONE）；
//   - 原样存储字节（nvn_be_tex_storage_read，不换算回游戏尺寸）：scaled 下必须是 32x24 的缩小图、且等于手算的缩小图（各矩形坐标 ÷ 2）——证明真的缩了、读回也真做了换算；
//   - 游戏坐标读回（ReadTexels / CopyTextureToBuffer）必须等于游戏尺寸的期望图。
// 易花屏的三处各一组：缩放拷贝（缩放图 ↔ 原尺寸图两个方向）、CPU 读写（缓冲写入即退回原尺寸、两条读回路径）、拉黑退回原尺寸（同遍有不可缩附件、绑定检查的待退回队列）。
// 线性滤波的两处（退回原尺寸的放大拷贝、CopyTextureToBuffer 的回读，同 Ryujinx CopyTo(linear)）在色块边缘 1 个游戏像素内允许取两色之间的值，其余逐字节相等。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
int nvn_be_tex_storage_size(const void *nvntex, int *w, int *h);
int nvn_be_tex_storage_read(const void *nvntex, uint8_t *dst, size_t row);
void nvn_be_rs_mark_bad(const void *nvntex);
enum { RS_NONE = 0, RS_SCALED = 1, RS_BLACK = 2 };   // nvn_rscale.inc

static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNcommandBuffer commands; static void *storage;
static size_t texture_offset = 4 << 20; static unsigned cases, checks; static const char *phase = "初始化"; static int scaled;
enum { POOL_SIZE = 32 << 20, COMMAND_SIZE = 1 << 20, BUF_OFFSET = 2 << 20, W = 64, H = 48 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL [%s] %s:%d: %s\n", phase, __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *e = h_nvnBootstrapLoader(name); REQUIRE(e != NULL); return e; }
#define API(name) ((NVNT_##name)load(#name))

static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(posix_memalign(&storage, 65536, POOL_SIZE) == 0); memset(storage, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
}
static void make_tex_pkg(NVNtexture *t, NVNformat fmt, int flags, const void *pkg);
static void make_tex(NVNtexture *t, NVNformat fmt, int flags) { make_tex_pkg(t, fmt, flags, NULL); }
static void make_tex_pkg(NVNtexture *t, NVNformat fmt, int flags, const void *pkg) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, W, H); API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetFormat)(&b, fmt); API(nvnTextureBuilderSetFlags)(&b, flags);
    if (pkg) API(nvnTextureBuilderSetPackagedTextureData)(&b, pkg);
    size_t al = API(nvnTextureBuilderGetStorageAlignment)(&b), sz = API(nvnTextureBuilderGetStorageSize)(&b);
    texture_offset = (texture_offset + al - 1) / al * al; REQUIRE(texture_offset + sz <= POOL_SIZE);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)texture_offset); texture_offset += sz;
    REQUIRE(API(nvnTextureInitialize)(t, &b));
}

// 游戏坐标的期望图：底色 + 依次覆盖的矩形（整数游戏像素）；也给缩小图（矩形坐标 ÷ 2，全部取偶数坐标，缩小后仍是整像素）
typedef struct { int x, y, w, h; uint8_t c[4]; } rect;
static const uint8_t RED[4] = {255, 0, 0, 255}, GREEN[4] = {0, 255, 0, 255}, BLUE[4] = {0, 0, 255, 255}, YELLOW[4] = {255, 255, 0, 255}, GREY[4] = {128, 128, 128, 255};
static void paint(uint8_t *img, int w, int h, const uint8_t base[4], const rect *r, int n, int div) {
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const uint8_t *c = base;
        for (int k = 0; k < n; k++) if (x >= r[k].x / div && x < (r[k].x + r[k].w) / div && y >= r[k].y / div && y < (r[k].y + r[k].h) / div) c = r[k].c;
        memcpy(img + 4 * (y * w + x), c, 4);
    }
}
// 落在任一矩形某条边两侧各 tol 个像素的带里（线性滤波可能混色）：竖边 x ∈ [边 − tol, 边 + tol)、y 在矩形上下各外扩 tol 的范围内；横边同理
static int near_edge(int x, int y, const rect *r, int n, int tol) {
    for (int k = 0; k < n; k++) {
        int x0 = r[k].x, x1 = r[k].x + r[k].w, y0 = r[k].y, y1 = r[k].y + r[k].h;
        int in_y = y >= y0 - tol && y < y1 + tol, in_x = x >= x0 - tol && x < x1 + tol;
        if (in_y && ((x >= x0 - tol && x < x0 + tol) || (x >= x1 - tol && x < x1 + tol))) return 1;
        if (in_x && ((y >= y0 - tol && y < y0 + tol) || (y >= y1 - tol && y < y1 + tol))) return 1;
    }
    return 0;
}
static void compare(const uint8_t *got, const uint8_t *want, int w, int h, const rect *r, int n, int tol, const char *what) {
    int exact = 0, edge = 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const uint8_t *g = got + 4 * (y * w + x), *e = want + 4 * (y * w + x);
        checks++;
        if (!memcmp(g, e, 4)) { exact++; continue; }
        if (tol && near_edge(x, y, r, n, tol)) { edge++; continue; }
        fprintf(stderr, "FAIL [%s] %s (%d,%d) 得 %d,%d,%d,%d 期望 %d,%d,%d,%d\n", phase, what, x, y, g[0], g[1], g[2], g[3], e[0], e[1], e[2], e[3]); exit(1);
    }
    REQUIRE(exact > w * h / 2);   // 绝大多数逐字节相等（边缘带只是窄窄一圈）
    printf("  %s：%d 个逐字节相等，%d 个在边缘带\n", what, exact, edge);
}
static void read_game(NVNtexture *t, uint8_t *out) { NVNcopyRegion r = {0, 0, 0, W, H, 1}; memset(out, 0xA5, W * H * 4); API(nvnTextureReadTexels)(t, NULL, &r, out); }
static void storage_is(NVNtexture *t, int want_state, int sw, int sh) {
    int w = 0, h = 0, st = nvn_be_tex_storage_size(t, &w, &h);
    printf("  存储 %dx%d 记录 %d（期望 %dx%d 记录 %d）\n", w, h, st, sw, sh, want_state);
    REQUIRE(st == want_state && w == sw && h == sh);
}
static void clear_rt(NVNtexture *t, const rect *r, int n, const uint8_t base[4]) {
    const NVNtexture *ts[1] = {t}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL);
    float f[4]; for (int i = 0; i < 4; i++) f[i] = base[i] / 255.0f;
    API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H); API(nvnCommandBufferClearColor)(&commands, 0, f, 15);
    for (int k = 0; k < n; k++) { for (int i = 0; i < 4; i++) f[i] = r[k].c[i] / 255.0f; API(nvnCommandBufferSetScissor)(&commands, r[k].x, r[k].y, r[k].w, r[k].h); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); }
}
static void done(void) { cases++; printf("PASS %s\n", phase); fflush(stdout); }

int main(int argc, char **argv) {
    @autoreleasepool {
    if (argc != 2 || (strcmp(argv[1], "scaled") && strcmp(argv[1], "off"))) { fprintf(stderr, "用法：t_nvn_rscale scaled | off\n"); return 2; }
    scaled = !strcmp(argv[1], "scaled");
    setenv("S2A_RES_SCALE", scaled ? "0.5" : "1", 1);
    setup();
    int SW = scaled ? W / 2 : W, SH = scaled ? H / 2 : H, SCALED_ST = scaled ? RS_SCALED : RS_NONE;
    static uint8_t got[W * H * 4], want[W * H * 4], raw[W * H * 4], rawwant[W * H * 4];
    NVNtexture A, B, C, D, E, Z;

    // 1. 第一次当渲染目标时缩；遍内清除（整屏 + 裁剪）按画布 → 存储换算；CPU 读回（ReadTexels，最近邻取回）是游戏尺寸
    phase = "1 渲染目标缩放 + 遍内裁剪清除 + ReadTexels";
    rect r1[] = {{16, 8, 32, 16, {0}}}; memcpy(r1[0].c, GREEN, 4);
    make_tex(&A, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    begin(); clear_rt(&A, r1, 1, RED); submit();
    storage_is(&A, SCALED_ST, SW, SH);
    nvn_be_tex_storage_read(&A, raw, (size_t)SW * 4); paint(rawwant, SW, SH, RED, r1, 1, scaled ? 2 : 1);
    compare(raw, rawwant, SW, SH, NULL, 0, 0, "原样存储 = 手算的（缩小）图");   // 反证：scaled 下存储真是 32x24 的缩小图
    paint(want, W, H, RED, r1, 1, 1); read_game(&A, got); compare(got, want, W, H, NULL, 0, 0, "ReadTexels = 游戏尺寸期望");
    done();

    // 2. 缩放拷贝：缩放图 → 原尺寸图（最近邻，逐字节），原尺寸图上 ClearTexture，再原尺寸图 → 缩放图；缩放图上 ClearTexture（复制引擎清除，区域按比例）
    phase = "2 缩放拷贝两个方向 + 复制引擎清除";
    make_tex(&B, NVN_FORMAT_RGBA8, 0);   // 不可压缩：不缩
    begin();
    { NVNcopyRegion sr = {8, 4, 0, 48, 32, 1}, dr = {0, 0, 0, 48, 32, 1}; API(nvnCommandBufferCopyTextureToTexture)(&commands, &A, NULL, &sr, &B, NULL, &dr, 0); }
    { NVNcopyRegion r = {0, 0, 0, 16, 8, 1}; float f[4] = {0, 0, 1, 1}; API(nvnCommandBufferClearTexture)(&commands, &B, NULL, &r, f, 15); }
    submit();
    storage_is(&B, RS_NONE, W, H);
    // B 期望：A 的 (8,4) 起 48x32 搬到 (0,0)：A 的绿块 (16,8,32,16) → (8,4,32,16)；再蓝块 (0,0,16,8)；其余（48 宽以外）是 0
    { rect rb[] = {{0, 0, 48, 32, {0}}, {8, 4, 32, 16, {0}}, {0, 0, 16, 8, {0}}}; memcpy(rb[0].c, RED, 4); memcpy(rb[1].c, GREEN, 4); memcpy(rb[2].c, BLUE, 4);
      const uint8_t zero[4] = {0, 0, 0, 0}; paint(want, W, H, zero, rb, 3, 1); read_game(&B, got); compare(got, want, W, H, NULL, 0, 0, "B（缩放图 → 原尺寸图）"); }
    begin();
    { NVNcopyRegion sr = {0, 0, 0, 16, 8, 1}, dr = {40, 36, 0, 16, 8, 1}; API(nvnCommandBufferCopyTextureToTexture)(&commands, &B, NULL, &sr, &A, NULL, &dr, 0); }
    { NVNcopyRegion r = {0, 40, 0, 8, 8, 1}; float f[4] = {128 / 255.0f, 128 / 255.0f, 128 / 255.0f, 1}; API(nvnCommandBufferClearTexture)(&commands, &A, NULL, &r, f, 15); }
    submit();
    storage_is(&A, SCALED_ST, SW, SH);
    rect r2[] = {{16, 8, 32, 16, {0}}, {40, 36, 16, 8, {0}}, {0, 40, 8, 8, {0}}}; memcpy(r2[0].c, GREEN, 4); memcpy(r2[1].c, BLUE, 4); memcpy(r2[2].c, GREY, 4);
    nvn_be_tex_storage_read(&A, raw, (size_t)SW * 4); paint(rawwant, SW, SH, RED, r2, 3, scaled ? 2 : 1); compare(raw, rawwant, SW, SH, NULL, 0, 0, "A 原样存储");
    paint(want, W, H, RED, r2, 3, 1); read_game(&A, got); compare(got, want, W, H, NULL, 0, 0, "A（原尺寸图 → 缩放图 + 清除）ReadTexels");
    done();

    // 3. GPU 回读到缓冲（CopyTextureToBuffer：缩放图先缩放拷贝回游戏尺寸，线性，同 Ryujinx flush）
    phase = "3 CopyTextureToBuffer 回读";
    NVNbufferAddress pa = API(nvnMemoryPoolGetBufferAddress)(&pool);
    begin(); { NVNcopyRegion r = {0, 0, 0, W, H, 1}; API(nvnCommandBufferCopyTextureToBuffer)(&commands, &A, NULL, &r, pa + BUF_OFFSET, 0); } submit();
    compare((uint8_t *)storage + BUF_OFFSET, want, W, H, r2, 3, scaled ? 1 : 0, "缓冲内容 = 游戏尺寸期望");
    done();

    // 4. CPU 写入（CopyBufferToTexture）：缩放图先退回原尺寸（Ryujinx 部分写入即拉黑），写入区逐字节，其余内容保留
    phase = "4 缓冲写入退回原尺寸";
    for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) memcpy((uint8_t *)storage + BUF_OFFSET + 4 * (y * 16 + x), YELLOW, 4);
    begin(); { NVNcopyRegion r = {24, 40, 0, 16, 8, 1}; API(nvnCommandBufferCopyBufferToTexture)(&commands, pa + BUF_OFFSET, &A, NULL, &r, 0); } submit();
    storage_is(&A, scaled ? RS_BLACK : RS_NONE, W, H);
    rect r4[] = {{16, 8, 32, 16, {0}}, {40, 36, 16, 8, {0}}, {0, 40, 8, 8, {0}}, {24, 40, 16, 8, {0}}}; memcpy(r4[0].c, GREEN, 4); memcpy(r4[1].c, BLUE, 4); memcpy(r4[2].c, GREY, 4); memcpy(r4[3].c, YELLOW, 4);
    paint(want, W, H, RED, r4, 4, 1); read_game(&A, got); compare(got, want, W, H, r4, 3, scaled ? 1 : 0, "A 写入后（黄块逐字节，其余放大拷贝带边缘）");
    { int ok = 1; for (int y = 40; y < 48; y++) for (int x = 24; x < 40; x++) ok &= !memcmp(got + 4 * (y * W + x), YELLOW, 4); REQUIRE(ok); }
    // 再当渲染目标：已拉黑，不再缩
    begin(); clear_rt(&A, r1, 1, RED); submit(); storage_is(&A, scaled ? RS_BLACK : RS_NONE, W, H);
    done();

    // 5. 绑定检查的待退回队列：标记后，下一遍开遍前换回原尺寸，内容保留（单色：放大拷贝逐字节）
    phase = "5 待退回队列（存储图像 / 计算 / 不精确着色器读到缩放图的那条路）";
    make_tex(&C, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&D, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    begin(); clear_rt(&C, NULL, 0, BLUE); submit(); storage_is(&C, SCALED_ST, SW, SH);
    nvn_be_rs_mark_bad(&C);
    begin(); clear_rt(&D, NULL, 0, RED); submit();   // 别的目标开遍：安全点
    storage_is(&C, scaled ? RS_BLACK : RS_NONE, W, H); storage_is(&D, SCALED_ST, SW, SH);
    paint(want, W, H, BLUE, NULL, 0, 1); read_game(&C, got); compare(got, want, W, H, NULL, 0, 0, "C 退回后内容");
    done();

    // 6. 同一遍有不可缩的附件（D16 深度：缩放拷贝画不了）→ 颜色目标也不缩（黑名单在目标间传播）
    phase = "6 同遍有不可缩附件";
    make_tex(&E, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE); make_tex(&Z, NVN_FORMAT_DEPTH16, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    begin(); { const NVNtexture *ts[1] = {&E}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, &Z, NULL); float f[4] = {0, 1, 0, 1};
        API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); API(nvnCommandBufferClearDepthStencil)(&commands, 1.0f, 1, 0, 0xff); } submit();
    storage_is(&E, scaled ? RS_BLACK : RS_NONE, W, H);
    paint(want, W, H, GREEN, NULL, 0, 1); read_game(&E, got); compare(got, want, W, H, NULL, 0, 0, "E 内容");
    done();

    // 7. 同一遍里有附件缩放失败 → 已缩的附件退回、同遍尺寸一致（11-09 #312 暗黑地牢2：颜色目标是打包贴图，存储建时不带渲染目标用途，缩放拷贝画不了；
    //    原先它记成不缩、同遍的深度照样缩到一半，同遍附件尺寸不一，iPhone 上闪粉色块）。修后：新存储补渲染目标用途 → 颜色也缩成；任何附件缩不成时同遍全部原尺寸
    phase = "7 打包数据的颜色目标 + 可缩深度：同遍尺寸一致";
    { static uint8_t pkgdata[1 << 20]; for (int i = 0; i < W * H; i++) memcpy(pkgdata + 4 * i, GREY, 4);   // 宿主按存储大小（块线性，大于 W×H×4）拷
      NVNtexture P, PZ; texture_offset = (texture_offset + 65535) / 65536 * 65536;   // 新起一页：前面贴图所在页已被写保护（单测桩不接缺页钩子），建时拷打包数据会 SIGBUS
      make_tex_pkg(&P, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE, pkgdata); make_tex(&PZ, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
      begin(); { const NVNtexture *ts[1] = {&P}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, &PZ, NULL); float f[4] = {0, 0, 1, 1};
          API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); API(nvnCommandBufferClearDepthStencil)(&commands, 1.0f, 1, 0, 0xff); } submit();
      int cw = 0, ch = 0, zw = 0, zh = 0, cs = nvn_be_tex_storage_size(&P, &cw, &ch), zs = nvn_be_tex_storage_size(&PZ, &zw, &zh);
      printf("  颜色存储 %dx%d 记录 %d，深度存储 %dx%d 记录 %d（期望两者相同）\n", cw, ch, cs, zw, zh, zs);
      REQUIRE(cw == zw && ch == zh);
      if (scaled) REQUIRE(cs == RS_SCALED && cw == W / 2);   // 补了渲染目标用途，颜色缩成
      paint(want, W, H, BLUE, NULL, 0, 1);   // 打包贴图的 ReadTexels 以池内存为准（读到打包原数据），GPU 内容走 CopyTextureToBuffer
      begin(); { NVNcopyRegion r = {0, 0, 0, W, H, 1}; API(nvnCommandBufferCopyTextureToBuffer)(&commands, &P, NULL, &r, pa + BUF_OFFSET, 0); } submit();
      compare((uint8_t *)storage + BUF_OFFSET, want, W, H, NULL, 0, 0, "P 内容 = 清屏蓝"); }
    done();

    printf("t_nvn_rscale %s：%u 组、%u 项全过\n", argv[1], cases, checks);
    }
    return 0;
}

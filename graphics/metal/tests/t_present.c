// 第 7 块单测：出图（无图层：定格 + 截图逐像素；窗口缩放 / 宽高比 / 过滤经 render_to 逐像素；有图层：离屏 CAMetalLayer 上屏不崩、计数闭合；满屏判据）。
// 期望值全部手算（不跑被测实现）：
//   源像素 src(x,y) = RGBA(20x+5, 40y+3, 200−x−9y, 77)；截图 = 裁切区 [L,R)×[T,B)（左右 / 上下都为 0 = 整宽 / 整高）按 FlipX / FlipY 镜像，
//   BGRA 字节序、alpha = 255：out(x,y) = src(L + (fx ? w−1−x : x), T + (fy ? h−1−y : y))。
//   窗口目标矩形照 Ryujinx Window.cs:409–422 的整数算法手算（见各用例注释）。
#include "../gal_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <objc/runtime.h>
#include <objc/message.h>
static void on_sig(int s) { void *b[32]; int n = backtrace(b, 32); backtrace_symbols_fd(b, n, 2); _exit(128 + s); }

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

enum { RGBA8 = 36, RGBA16F = 40, RGBA8_SRGB = 54, BGRA8 = 143 };
static nxgal_tex_info info2d(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }
static void src_px(int x, int y, uint8_t o[4]) { o[0] = (uint8_t)(20 * x + 5); o[1] = (uint8_t)(40 * y + 3); o[2] = (uint8_t)(200 - x - 9 * y); o[3] = 77; }
static uint32_t mk_src(int w, int h, int fmt, const int32_t swz[4]) {
    nxgal_tex_info i = info2d(w, h, fmt, 4); if (swz) memcpy(i.swz, swz, sizeof i.swz);
    uint32_t t = nxgal_tex_create(&i);
    uint8_t *d = malloc((size_t)w * h * 4);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) src_px(x, y, d + (y * w + x) * 4);
    nxgal_tex_set_data(t, 0, 0, NULL, d, (uint64_t)w * h * 4);
    free(d); return t;
}
static nxgal_crop crop(int l, int r, int t, int b, int fx, int fy) { nxgal_crop c = {l, r, t, b, fx, fy, 1, 16, 9}; return c; }

// 截图与手算比；mem_bgra = 源贴图是 BGRA8（内存字节 b0..b3 = B G R A，期望截图字节 = 原字节、alpha 255）
static void check_shot(const char *name, int TW, int TH, nxgal_crop c, int mem_bgra) {
    int x0 = 0, x1 = TW, y0 = 0, y1 = TH;
    if (c.left || c.right) { x0 = c.left; x1 = c.right; }
    if (c.top || c.bottom) { y0 = c.top; y1 = c.bottom; }
    int ew = x1 - x0, eh = y1 - y0;
    int w = -1, h = -1; int32_t need = nxgal_screenshot(NULL, 0, &w, &h);
    CHECK(w == ew && h == eh && need == ew * eh * 4, "%s：截图尺寸 期望 %dx%d（%d 字节）实得 %dx%d（%d）", name, ew, eh, ew * eh * 4, w, h, need);
    if (w != ew || h != eh) return;
    uint8_t *px = malloc(need);
    int32_t n = nxgal_screenshot(px, need, &w, &h);
    CHECK(n == need, "%s：截图返回 %d ≠ %d", name, n, need);
    int bad = 0;
    for (int y = 0; y < eh; y++) for (int x = 0; x < ew; x++) {
        int sx = x0 + (c.flip_x ? ew - 1 - x : x), sy = y0 + (c.flip_y ? eh - 1 - y : y);
        uint8_t s[4]; src_px(sx, sy, s);
        uint8_t e[4] = {s[2], s[1], s[0], 255};                // RGBA 源 → BGRA 字节
        if (mem_bgra) { e[0] = s[0]; e[1] = s[1]; e[2] = s[2]; }  // BGRA 源：内存字节原样
        uint8_t *p = px + (y * ew + x) * 4;
        if (memcmp(p, e, 4) && bad++ < 3) printf("  ✗ %s (%d,%d) 期望 %u %u %u %u 实得 %u %u %u %u\n", name, x, y, e[0], e[1], e[2], e[3], p[0], p[1], p[2], p[3]);
    }
    g_checks++; if (bad) { g_fail++; printf("  ✗ %s：共 %d / %d 像素不符\n", name, bad, ew * eh); }
    free(px);
}

// 1：无图层，各种裁切 / 翻转，截图逐像素
static void t_crop(void) {
    printf("· RGBA8 8×4：整张 / 裁切 L2 R6 T1 B3 ×（无翻转、FlipX、FlipY、双翻）/ 只裁左右 L1 R7\n");
    uint32_t t = mk_src(8, 4, RGBA8, NULL);
    struct { const char *n; nxgal_crop c; } cs[] = {
        {"整张", crop(0, 0, 0, 0, 0, 0)},
        {"裁切", crop(2, 6, 1, 3, 0, 0)},
        {"裁切+FlipX", crop(2, 6, 1, 3, 1, 0)},
        {"裁切+FlipY", crop(2, 6, 1, 3, 0, 1)},
        {"裁切+双翻", crop(2, 6, 1, 3, 1, 1)},
        {"只裁左右", crop(1, 7, 0, 0, 0, 0)},
        {"整张+双翻", crop(0, 0, 0, 0, 1, 1)},
    };
    for (unsigned i = 0; i < sizeof cs / sizeof *cs; i++) { nxgal_present(t, &cs[i].c); check_shot(cs[i].n, 8, 4, cs[i].c, 0); }
    nxgal_tex_release(t);
}

// 2：源格式：sRGB 取原始字节、非恒等分量映射被忽略（同 Vulkan 端恒等映射）、BGRA8 源、RGBA16F 源
static void t_formats(void) {
    printf("· 源格式：RGBA8 sRGB（原始字节）/ RGBA8 分量映射 BGRA（出图忽略）/ BGRA8 / RGBA16F\n");
    uint32_t t = mk_src(5, 3, RGBA8_SRGB, NULL); nxgal_crop c = crop(0, 0, 0, 0, 0, 0);
    nxgal_present(t, &c); check_shot("sRGB", 5, 3, c, 0); nxgal_tex_release(t);
    // 非恒等分量映射走视图（nxgal_tex_create 带分量映射 + 渲染目标用途会触发 Metal 校验断言，见报告：第 3 块问题）
    t = mk_src(5, 3, RGBA8, NULL);
    nxgal_tex_info vi = info2d(5, 3, RGBA8, 4); vi.swz[0] = 4; vi.swz[1] = 3; vi.swz[2] = 2; vi.swz[3] = 5;
    uint32_t v = nxgal_tex_view(t, &vi, 0, 0); CHECK(v, "建分量映射视图失败");
    if (v) { nxgal_present(v, &c); check_shot("分量映射视图", 5, 3, c, 0); nxgal_tex_release(v); }
    nxgal_tex_release(t);
    t = mk_src(5, 3, BGRA8, NULL); nxgal_present(t, &c); check_shot("BGRA8", 5, 3, c, 1); nxgal_tex_release(t);
    // RGBA16F 2×1：(0.2,0.4,0.6,0.5) (1,0,0.2,1) → BGRA8 = (153,102,51,255) (51,0,255,255)
    nxgal_tex_info i = info2d(2, 1, RGBA16F, 8); uint32_t f = nxgal_tex_create(&i);
    _Float16 hv[8] = {0.2f, 0.4f, 0.6f, 0.5f, 1.0f, 0.0f, 0.2f, 1.0f}; nxgal_tex_set_data(f, 0, 0, NULL, hv, sizeof hv);
    nxgal_present(f, &c);
    uint8_t px[8] = {0}; int w, h; int32_t n = nxgal_screenshot(px, sizeof px, &w, &h);
    uint8_t e[8] = {153, 102, 51, 255, 51, 0, 255, 255};
    CHECK(n == 8 && w == 2 && h == 1 && !memcmp(px, e, 8), "RGBA16F 期望 153 102 51 255 / 51 0 255 255 实得 %u %u %u %u / %u %u %u %u（%d 字节 %dx%d）",
          px[0], px[1], px[2], px[3], px[4], px[5], px[6], px[7], n, w, h);
    nxgal_tex_release(f);
}

// 3：命令顺序：present 取到「此前所有命令画完」的内容（含挂起的通道开头清屏、通道内局部清屏）
static void t_order(void) {
    printf("· 顺序：整清 (0.2,0.4,0.6) → present → 剪裁 (0,0,2,2) 清 (1,0,0) → present → 再整清 (0,0,1) → present\n");
    nxgal_tex_info i = info2d(4, 4, RGBA8, 4); uint32_t t = nxgal_tex_create(&i);
    nxgal_set_render_targets(&t, 1, 0);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    nxgal_crop c = crop(0, 0, 0, 0, 0, 0);
    float c0[4] = {0.2f, 0.4f, 0.6f, 1}; nxgal_clear_color(0, 0, 1, 0xf, c0);
    nxgal_present(t, &c);
    uint8_t a[64]; nxgal_screenshot(a, 64, NULL, NULL);
    CHECK(a[0] == 153 && a[1] == 102 && a[2] == 51 && a[63] == 255, "整清后 期望 BGRA 153 102 51 实得 %u %u %u", a[0], a[1], a[2]);
    nxgal_rect sc = {0, 0, 2, 2}; nxgal_set_scissors(&sc, 1);
    float c1[4] = {1, 0, 0, 1}; nxgal_clear_color(0, 0, 1, 0xf, c1);
    nxgal_present(t, &c);
    uint8_t b[64]; nxgal_screenshot(b, 64, NULL, NULL);
    CHECK(b[0] == 0 && b[1] == 0 && b[2] == 255, "局部清后 (0,0) 期望 BGRA 0 0 255 实得 %u %u %u", b[0], b[1], b[2]);
    CHECK(b[(1 * 4 + 1) * 4 + 2] == 255 && b[(2 * 4 + 2) * 4 + 2] == 51, "局部清后 (1,1) R 期望 255 实得 %u；(2,2) R 期望 51 实得 %u", b[(1 * 4 + 1) * 4 + 2], b[(2 * 4 + 2) * 4 + 2]);
    nxgal_set_scissors(&full, 1);
    float c2[4] = {0, 0, 1, 1}; nxgal_clear_color(0, 0, 1, 0xf, c2);
    nxgal_present(t, &c);
    uint8_t d[64]; nxgal_screenshot(d, 64, NULL, NULL);
    CHECK(d[0] == 255 && d[1] == 0 && d[2] == 0, "再整清后 (0,0) 期望 BGRA 255 0 0 实得 %u %u %u", d[0], d[1], d[2]);
    nxgal_set_render_targets(NULL, 0, 0);
    nxgal_tex_release(t);
}

// render_to 读回（目标 RGBA8）与期望比；exp(x,y,out) 给期望 RGBA
typedef void (*expf_t)(int x, int y, uint8_t o[4]);
static void check_rt(const char *name, int W, int H, expf_t ex, int tol) {
    nxgal_tex_info i = info2d(W, H, RGBA8, 4); uint32_t d = nxgal_tex_create(&i);
    int rc = nxgal_window_render_to(d); CHECK(rc == 0, "%s：render_to 返回 %d", name, rc);
    uint8_t *px = malloc((size_t)W * H * 4); nxgal_tex_get_data(d, 0, 0, px, (uint64_t)W * H * 4);
    int bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        uint8_t e[4]; ex(x, y, e); uint8_t *p = px + (y * W + x) * 4; int ok = 1;
        for (int k = 0; k < 4; k++) if (abs((int)p[k] - e[k]) > tol) ok = 0;
        if (!ok && bad++ < 3) printf("  ✗ %s (%d,%d) 期望 %u %u %u %u 实得 %u %u %u %u\n", name, x, y, e[0], e[1], e[2], e[3], p[0], p[1], p[2], p[3]);
    }
    g_checks++; if (bad) { g_fail++; printf("  ✗ %s：共 %d / %d 像素不符\n", name, bad, W * H); }
    free(px); nxgal_tex_release(d);
}
// 帧 = 4×2 源整张：f(x,y) = src(x,y) 的 RGB、alpha 255
static void fr(int x, int y, uint8_t o[4]) { src_px(x, y, o); o[3] = 255; }
static void ex_stretch(int x, int y, uint8_t o[4]) { fr(x / 2, y / 2, o); }   // 8×4 拉伸、最近：每源像素 2×2
// 源 2×2（裁左半）宽高比 1:1 放进 8×4：源不比参数宽，按参数 1:1：rx = min(1, 4·1/(8·1)) = 0.5 → 宽 4，ry = 1 → 高 4；左右各留 (8−4)/2 = 2 列黑，2×2 源每像素放大 2×2
static void ex_pillar(int x, int y, uint8_t o[4]) { if (x < 2 || x >= 6) { o[0] = o[1] = o[2] = 0; o[3] = 255; } else fr((x - 2) / 2, y / 2, o); }
// 宽高比 4:1 放进 8×4：rx = min(1, 4·4/8) = 1 → 宽 8；ry = min(1, 8·1/(4·4)) = 0.5 → 高 2；上下各留 1 行黑
static void ex_letter(int x, int y, uint8_t o[4]) { if (y < 1 || y >= 3) { o[0] = o[1] = o[2] = 0; o[3] = 255; } else fr(x / 2, y - 1, o); }
// 双线性 2×1 [黑, 白] → 4×1 拉伸：像素中心落在源坐标 −0.25 / 0.25 / 0.75 / 1.25（钳边）→ 0, 63.75, 191.25, 255
static void ex_bilin(int x, int y, uint8_t o[4]) { (void)y; static const uint8_t v[4] = {0, 64, 191, 255}; o[0] = o[1] = o[2] = v[x]; o[3] = 255; }

// 出图比例与屏只差小数位时铺满：1564×720 源（2.17222）放进 2868×1320 屏（2.17273），按源像素比 rx = 1320·1564 / (2868·720) = 0.999777，
// W·rx = 2867.36——截断成 2867 时右侧第 2867 列全黑；离满屏不足 1 像素应铺满，首列与末列都是源内容（白）
static void t_fill(void) {
    printf("· 铺满：1564×720 白源 → 2868×1320，比例差不足 1 像素，首末列不黑\n");
    nxgal_tex_info si = info2d(1564, 720, RGBA8, 4); uint32_t s = nxgal_tex_create(&si);
    nxgal_set_render_targets(&s, 1, 0);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    float wh[4] = {1, 1, 1, 1}; nxgal_clear_color(0, 0, 1, 0xf, wh);
    nxgal_set_render_targets(NULL, 0, 0);
    nxgal_crop c = crop(0, 0, 0, 0, 0, 0); c.stretched = 0;
    nxgal_present(s, &c);
    const int W = 2868, H = 1320;
    nxgal_tex_info di = info2d(W, H, RGBA8, 4); uint32_t d = nxgal_tex_create(&di);
    int rc = nxgal_window_render_to(d); CHECK(rc == 0, "铺满：render_to 返回 %d", rc);
    uint8_t *px = malloc((size_t)W * H * 4); nxgal_tex_get_data(d, 0, 0, px, (uint64_t)W * H * 4);
    int black_first = 0, black_last = 0;
    for (int y = 0; y < H; y++) { if (px[(y * W) * 4] < 128) black_first++; if (px[(y * W + W - 1) * 4] < 128) black_last++; }
    CHECK(black_first == 0 && black_last == 0, "铺满：首列黑 %d 行、末列黑 %d 行（期望都 0）", black_first, black_last);
    free(px); nxgal_tex_release(d); nxgal_tex_release(s);
}

// 4：窗口缩放 / 宽高比 / 过滤（render_to = 上屏同一段编码）
static void t_window(void) {
    printf("· 窗口：4×2 帧 → 8×4 拉伸最近 / 参数 1:1 但源 2:1 更宽按源铺满 / 源 2×2 参数 1:1 左右黑边 / 4:1 上下黑边；2×1 黑白 → 4×1 双线性（±1）\n");
    uint32_t t = mk_src(4, 2, RGBA8, NULL);
    nxgal_window_set_scaling(1, 0);
    nxgal_crop c = crop(0, 0, 0, 0, 0, 0); c.stretched = 1; nxgal_present(t, &c); check_rt("拉伸", 8, 4, ex_stretch, 0);
    // 源比呈现参数宽（加宽的情形）：按源像素宽高比等比铺（gal_present.m），4×2 源 2:1 正好铺满 8×4，与拉伸同像素
    c.stretched = 0; c.aspect_x = 1; c.aspect_y = 1; nxgal_present(t, &c); check_rt("参数 1:1 源 2:1", 8, 4, ex_stretch, 0);
    { nxgal_crop q = crop(0, 2, 0, 2, 0, 0); q.stretched = 0; q.aspect_x = 1; q.aspect_y = 1; nxgal_present(t, &q); check_rt("源 2×2 参数 1:1", 8, 4, ex_pillar, 0); }
    c.aspect_x = 4; c.aspect_y = 1; nxgal_present(t, &c); check_rt("4:1", 8, 4, ex_letter, 0);
    nxgal_tex_release(t);
    nxgal_tex_info i = info2d(2, 1, RGBA8, 4); uint32_t bw = nxgal_tex_create(&i);
    uint8_t d[8] = {0, 0, 0, 255, 255, 255, 255, 255}; nxgal_tex_set_data(bw, 0, 0, NULL, d, sizeof d);
    nxgal_window_set_scaling(0, 0);
    c.stretched = 1; nxgal_present(bw, &c); check_rt("双线性", 4, 1, ex_bilin, 1);
    nxgal_tex_release(bw);
}

// 5：有图层：离屏 CAMetalLayer（不挂窗口），上屏不崩、计数闭合（出图 = 上屏 + 顶掉 + 取不到），drawableSize 跟 SetSize
typedef struct { double w, h; } cgsz;
static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }
static void t_layer(void) {
    printf("· 图层：离屏 CAMetalLayer，SetSize 64×32、Unbounded，出图 6 帧 → 5 秒内计数闭合、至少上屏 1 帧、截图仍是最后一帧\n");
    id cls = (id)objc_getClass("CAMetalLayer");
    id L = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("layer"));
    ((id (*)(id, SEL))objc_msgSend)(L, sel_registerName("retain"));
    CHECK(L != NULL, "建 CAMetalLayer 失败"); if (!L) return;
    uint64_t s0[4]; nxgal_window_stats(s0);
    nxgal_window_set_size(64, 32); nxgal_window_set_vsync(1); nxgal_window_set_scaling(0, 0);
    nxgal_window_set_layer((void *)L);
    uint32_t t = mk_src(8, 4, RGBA8, NULL);
    nxgal_crop c = crop(2, 6, 1, 3, 1, 0); c.stretched = 0; c.aspect_x = 16; c.aspect_y = 9;
    for (int k = 0; k < 6; k++) nxgal_present(t, &c);
    uint64_t s[4]; double t0 = now_s();
    for (;;) {   // 等上屏收尾：墙钟上限 5 秒
        nxgal_window_stats(s);
        uint64_t done = (s[1] - s0[1]) + (s[2] - s0[2]) + (s[3] - s0[3]);
        if (done >= 6 || now_s() - t0 > 5) break;
        struct timespec ts = {0, 10000000}; nanosleep(&ts, NULL);
    }
    printf("  出图 %llu 上屏 %llu 顶掉 %llu 取不到 %llu（%.0f ms）\n", (unsigned long long)(s[0] - s0[0]), (unsigned long long)(s[1] - s0[1]),
           (unsigned long long)(s[2] - s0[2]), (unsigned long long)(s[3] - s0[3]), (now_s() - t0) * 1e3);
    CHECK(s[0] - s0[0] == 6, "出图计数 期望 6 实得 %llu", (unsigned long long)(s[0] - s0[0]));
    CHECK((s[1] - s0[1]) + (s[2] - s0[2]) + (s[3] - s0[3]) == 6, "计数未闭合：上屏 + 顶掉 + 取不到 ≠ 6");
    CHECK(s[1] - s0[1] >= 1, "一帧都没上屏");
    CHECK(s[3] - s0[3] == 0, "取不到 drawable %llu 次", (unsigned long long)(s[3] - s0[3]));
    cgsz sz = ((cgsz (*)(id, SEL))objc_msgSend)(L, sel_registerName("drawableSize"));
    CHECK(sz.w == 64 && sz.h == 32, "drawableSize 期望 64×32 实得 %g×%g", sz.w, sz.h);
    check_shot("图层模式截图", 8, 4, c, 0);
    nxgal_window_set_layer(NULL);
    nxgal_present(t, &c);   // 摘掉图层后：照常计数、不上屏
    uint64_t s2[4]; nxgal_window_stats(s2);
    CHECK(s2[0] == s[0] + 1 && s2[1] == s[1], "摘图层后 出图 +1 上屏不变：实得出图 +%llu 上屏 +%llu", (unsigned long long)(s2[0] - s[0]), (unsigned long long)(s2[1] - s[1]));
    nxgal_tex_release(t);
}

// 6：满屏判据（10-19 动森语言页）：图层 64×32（2:1）。期望值按定义手算：
//   8×4（2:1）拉伸上屏 → 铺满、比例一致，几何不报；6×4（1.5:1）拉伸 → 宽高比差 25% > 1%，几何报（画面整幅纯黑时不报：看不出变形 / 留边）；
//   内容（出图比 16:9 宽才判）：48×9 两侧 16 列黑、中间有内容 → 报；黑底只有正中 4 列（logo 页）→ 不报；8×4 最左列黑 → 不判
uint64_t gal_present_unfit(void); uint64_t gal_present_pillar_n(void);
static void drain(id L) { (void)L; double t0 = now_s(); uint64_t a[4], b[4]; nxgal_window_stats(a);
    for (;;) { struct timespec ts = {0, 5000000}; nanosleep(&ts, NULL); nxgal_window_stats(b); if (b[1] + b[2] + b[3] >= a[0] || now_s() - t0 > 3) break; } }
static void present_n(uint32_t t, nxgal_crop *c, int n) { for (int k = 0; k < n; k++) { nxgal_present(t, c); struct timespec ts = {0, 2000000}; nanosleep(&ts, NULL); } }
// 内容判据每 30 次出图钉住一张定格图、GPU 做完后在之后的出图里判，连续 2 次才计（gal_present.m）。每批 30 次出图里恰有一个钉点；
// 批后 gal_finish 等主队列做完（钉住的那张必然做完），下一批第一次出图就判掉——3 批 + 1 次出图 = 确定 3 次抽样，后 2 次必是本图
// （第 1 次钉点可能落在批首、钉到上一张图）。不靠墙钟、不随整机负载漂（10-21 多条线门禁 66/67：旧判据到点只看一眼、没做完就跳过）
void gal_finish(void);
void gal_present_fit_period(int n);
// 钉帧周期 FP（满屏判据段设短，见 gal_present.m g_fit_period）：每批 FP 次出图恰有一个钉点；FIT_N = 3·FP 次出图保证至少两个完整钉点（同旧 70 ≈ 2·30 + 余量）
enum { FP = 5, FIT_N = 3 * FP };
// 满屏判据段只等主队列做完（gal_finish），不用 drain：离屏图层不显示，drain 等「显示 / 顶掉 / 取不到」落定每次都要等满 3 秒（那段 57 秒的大头）；判据看的是钉住的定格图，GPU 做完即可
// 钉住的图交给判据队列时，队列上一张还没判完就顺延到之后的出图（gal_present.m「队列上一张还没判完就先不交」）：整机负载高时「3 批 + 1 次出图」里最后几次交接
//   被顺延，钉住的图没判到就读数（11-02 体验线报：同一二进制三遍一红「未满屏 +0 记 +0」）。改为补出图直到判定张数真涨了 3（上限 40 次防死等）
uint64_t gal_present_judged(void);
static void present_fit(uint32_t t, nxgal_crop *c) {
    uint64_t j0 = gal_present_judged();
    for (int k = 0; k < 3; k++) { present_n(t, c, FP); gal_finish(); }
    for (int k = 0; k < 40 && gal_present_judged() < j0 + 3; k++) { nxgal_present(t, c); gal_finish(); }
}
static uint32_t mk_band(int w, int h, int lo, int hi) {
    nxgal_tex_info i = info2d(w, h, RGBA8, 4); uint32_t t = nxgal_tex_create(&i); uint8_t *d = calloc((size_t)w * h, 4);
    // 蓝通道用 5x+5 不回绕：src_px 的 20x+5 在第 13 列从 245 绕回 9，48 宽图里这条整列硬边正落在 16:9 边界（16±3）上，被 fj_seam 正确判成接缝（10-29 fullbg 合入后渲染器单测 6 项假红）
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { uint8_t *q = d + (y * w + x) * 4; q[3] = 255; if (x >= lo && x < hi) { src_px(x, y, q); q[0] = (uint8_t)(5 * x + 5); } }
    nxgal_tex_set_data(t, 0, 0, NULL, d, (size_t)w * h * 4); free(d); return t;
}
// 贴边暗带用例图（48×9，灰 120 为内容；4 = 右侧 x ≥ 38 暗但有竖纹 8 / 36 交替，像贴脸的暗门柱）：kind 0 = 右侧 x ≥ 38 压暗到 20、(40,3) 一颗暗星；1 = 左侧 x < 10 压暗；2 = 从左到右渐暗 160 → 19（没有台阶）；3 = 中间 [20,28) 暗竖条（不贴边）
static uint32_t mk_dark(int kind) {
    int w = 48, h = 9; nxgal_tex_info i = info2d(w, h, RGBA8, 4); uint32_t t = nxgal_tex_create(&i); uint8_t *d = calloc((size_t)w * h, 4);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int v = kind == 0 ? (x >= 38 ? 20 : 120) : kind == 1 ? (x < 10 ? 20 : 120) : kind == 2 ? 160 - 3 * x : kind == 3 ? (x >= 20 && x < 28 ? 20 : 120) : kind == 4 ? (x >= 38 ? (x & 1 ? 8 : 36) : 120)
            : (x < 10 || x >= 38 ? 0 : 120);   // 5：居中原画、两侧纯黑（暗黑3 读盘页），右侧黑区一个小图标（下）
        if (kind == 5 && y == 4 && x >= 39 && x < 41) v = 200;
        if (kind == 0 && x == 40 && y == 3) v = 40;   // 一颗暗星（真实缺块是近黑底 + 零星暗星点；带只有 10 列宽，太亮的一颗会把带内平滑度拉过门槛）
        uint8_t *q = d + (y * w + x) * 4; q[0] = q[1] = q[2] = (uint8_t)v; q[3] = 255;
    }
    nxgal_tex_set_data(t, 0, 0, NULL, d, (size_t)w * h * 4); free(d); return t;
}
static void t_fit(void) {
    printf("· 满屏判据：图层 64×32；8×4 拉伸不报、6×4 拉伸报几何；48×9 两侧黑带报内容、logo 页不报；原比例页标记开两侧黑带不报、单侧照报、标记关照报；贴边暗带报、渐暗 / 中间暗条不报\n");
    id cls = (id)objc_getClass("CAMetalLayer");
    id L = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("layer"));
    ((id (*)(id, SEL))objc_msgSend)(L, sel_registerName("retain"));
    nxgal_window_set_size(64, 32); nxgal_window_set_layer((void *)L);
    gal_present_fit_period(FP);
    uint32_t t = mk_src(8, 4, RGBA8, NULL);
    nxgal_crop c = crop(0, 0, 0, 0, 0, 0); c.stretched = 1;
    present_n(t, &c, 4); gal_finish();
    uint64_t u0 = gal_present_unfit(); present_n(t, &c, 4); gal_finish(); uint64_t u1 = gal_present_unfit();
    CHECK(u1 == u0, "8×4 拉伸到 64×32：期望不报 实得 +%llu", (unsigned long long)(u1 - u0));
    nxgal_crop c6 = crop(0, 6, 0, 4, 0, 0); c6.stretched = 1;
    // 几何红要等钉住的定格图确认有内容（gal_present.m fit_geom）：几何没满屏后下一次出图就钉一张；每轮 2 次出图 + 出图做完 + 主队列做完，3 轮必判到
    // （挂着离屏图层出图慢——无头机 mini 取不到画布——用例只出几次图）。反例先：同样 6×4 拉伸变形但整幅纯黑（开机黑帧），屏上看不出变形 / 留边，期望不报
    uint32_t blk = mk_band(6, 4, 0, 0);
    for (int k = 0; k < 3; k++) { present_n(blk, &c6, 2); gal_finish(); gal_finish(); }
    uint64_t ub = gal_present_unfit();
    CHECK(ub == u1, "6×4 拉伸到 64×32 但整幅纯黑：期望不报几何 实得 +%llu", (unsigned long long)(ub - u1));
    for (int k = 0; k < 3; k++) { present_n(t, &c6, 2); gal_finish(); gal_finish(); }
    uint64_t u2 = gal_present_unfit();
    CHECK(u2 > ub, "6×4 拉伸到 64×32（有内容）：期望报几何 实得 +%llu", (unsigned long long)(u2 - ub));
    nxgal_tex_release(blk);
    present_n(t, &c, 4); gal_finish();   // 几何恢复
    // 内容：只在出图比 16:9 宽时判（无窗口局也判，这里摘掉图层：离屏图层不接显示，连出几百帧时出图队列等画布会把主队列拖住约 4 秒，撞上 3 秒卡死保护）。48×9：16:9 宽 16，每侧内缩 16
    nxgal_window_set_layer(NULL); nxgal_window_set_size(96, 18);
    uint32_t mid = mk_band(48, 9, 16, 32), logo = mk_band(48, 9, 22, 26), full = mk_band(48, 9, 0, 48), narrow = mk_band(8, 4, 1, 8);
    present_n(full, &c, FIT_N); gal_finish();
    uint64_t u3 = gal_present_unfit(); present_fit(mid, &c); uint64_t u4 = gal_present_unfit();
    CHECK(u4 > u3, "48×9 只画中间 16:9（两侧 16 列黑）：期望报内容 实得 +%llu", (unsigned long long)(u4 - u3));
    present_n(full, &c, FIT_N); gal_finish(); uint64_t u5 = gal_present_unfit(); present_n(logo, &c, FIT_N); gal_finish(); uint64_t u6 = gal_present_unfit();
    CHECK(u6 == u5, "48×9 黑底只有正中 4 列（logo 页）：期望不报 实得 +%llu", (unsigned long long)(u6 - u5));
    // 原比例页（10-20 jhz）：同一张 48×9 两侧黑带图，包装层标了原比例页 → 不报、记原比例；标记关掉 → 照报（期望按定义）
    present_n(full, &c, FIT_N); gal_finish(); nxgal_present_pillar(1); uint64_t p0 = gal_present_pillar_n(), q0 = gal_present_unfit();
    present_fit(mid, &c); uint64_t p1 = gal_present_pillar_n(), q1 = gal_present_unfit();
    CHECK(q1 == q0 && p1 > p0, "48×9 两侧黑带 + 包装层标原比例页：期望不报未满屏、记原比例 实得 未满屏 +%llu 原比例 +%llu", (unsigned long long)(q1 - q0), (unsigned long long)(p1 - p0));
    // 两侧是放宽内容画的黑（10-21 马车8 比赛前读盘页，包装层标 2）：同样不报未满屏、记入原比例计数
    present_n(full, &c, FIT_N); gal_finish(); nxgal_present_pillar(2); uint64_t p20 = gal_present_pillar_n(), q20 = gal_present_unfit();
    present_fit(mid, &c); uint64_t p21 = gal_present_pillar_n(), q21 = gal_present_unfit();
    CHECK(q21 == q20 && p21 > p20, "48×9 两侧黑带 + 包装层标两侧是放宽内容画的：期望不报未满屏 实得 未满屏 +%llu 记 +%llu", (unsigned long long)(q21 - q20), (unsigned long long)(p21 - p20));
    // 没有可扩视野的内容（10-22 巫师3 读盘页，包装层标 3）：两侧黑带同样不报、记入原比例计数；只左侧黑带也不报
    present_n(full, &c, FIT_N); gal_finish(); nxgal_present_pillar(3); uint64_t p40 = gal_present_pillar_n(), q40 = gal_present_unfit();
    present_fit(mid, &c); uint64_t p41 = gal_present_pillar_n(), q41 = gal_present_unfit();
    CHECK(q41 == q40 && p41 > p40, "48×9 两侧黑带 + 包装层标没有可扩视野的内容：期望不报未满屏 实得 未满屏 +%llu 记 +%llu", (unsigned long long)(q41 - q40), (unsigned long long)(p41 - p40));
    // 两侧外侧都是黑带、带内只有左内沿有内容（10-22 怪猎 logo 页，内容偏左）+ 标记开：期望不报（原比例页只看外侧黑带）；标记关：期望照报
    uint32_t lean = mk_band(48, 9, 16, 30);
    present_n(full, &c, FIT_N); gal_finish(); nxgal_present_pillar(1); uint64_t p30 = gal_present_pillar_n(), q30 = gal_present_unfit();
    present_fit(lean, &c); uint64_t p31 = gal_present_pillar_n(), q31 = gal_present_unfit();
    CHECK(q31 == q30 && p31 > p30, "48×9 两侧黑带、内容只贴左内沿 + 标原比例页：期望不报、记原比例 实得 未满屏 +%llu 原比例 +%llu", (unsigned long long)(q31 - q30), (unsigned long long)(p31 - p30));
    present_n(full, &c, FIT_N); gal_finish(); nxgal_present_pillar(0); uint64_t q32 = gal_present_unfit(); present_fit(lean, &c); uint64_t q33 = gal_present_unfit();
    CHECK(q33 > q32, "48×9 两侧黑带、内容只贴左内沿、标记关：期望照报 实得 +%llu", (unsigned long long)(q33 - q32));
    nxgal_tex_release(lean);
    nxgal_present_pillar(1);
    uint32_t left = mk_band(48, 9, 16, 48); present_n(full, &c, FIT_N); gal_finish(); uint64_t q2 = gal_present_unfit(); present_fit(left, &c); uint64_t q3 = gal_present_unfit();
    CHECK(q3 > q2, "只左侧黑带（不居中）+ 标记开：期望照报 实得 +%llu", (unsigned long long)(q3 - q2));
    // 只左侧黑带 + 标「游戏自己出宽图的纯 2D 合成」（4，10-22 塞尔达标题页）：期望不报
    nxgal_present_pillar(4); present_n(full, &c, FIT_N); gal_finish(); uint64_t qg0 = gal_present_unfit(); present_fit(left, &c); uint64_t qg1 = gal_present_unfit();
    CHECK(qg1 == qg0, "只左侧黑带 + 标纯 2D 合成：期望不报 实得 +%llu", (unsigned long long)(qg1 - qg0));
    // 只左侧黑带 + 标「没有可扩视野的内容」（3，10-22 巫师3 读盘页）：同 2 不论单侧双侧，期望不报（当成原比例页 1 会照报：1 要求两侧都是黑带）
    nxgal_present_pillar(3); present_n(full, &c, FIT_N); gal_finish(); uint64_t qn0 = gal_present_unfit(); present_fit(left, &c); uint64_t qn1 = gal_present_unfit();
    CHECK(qn1 == qn0, "只左侧黑带 + 标没有可扩视野的内容：期望不报 实得 +%llu", (unsigned long long)(qn1 - qn0));
    nxgal_present_pillar(1);
    nxgal_present_pillar(0); present_n(full, &c, FIT_N); gal_finish(); uint64_t q4 = gal_present_unfit(); present_fit(mid, &c); uint64_t q5 = gal_present_unfit();
    CHECK(q5 > q4, "48×9 两侧黑带、标记关：期望照报 实得 +%llu", (unsigned long long)(q5 - q4));
    // 贴边暗带（10-22 八方2 镇上右侧约 20% 近黑、带星点，不是纯黑）：右侧 / 左侧压暗报；渐暗（无台阶）、中间暗竖条、锯齿满图（上面的 full）不报；标两侧是游戏画的不判
    nxgal_present_pillar(0);
    for (int k = 0; k < 5; k++) {
        uint32_t dk = mk_dark(k); present_n(full, &c, FIT_N); gal_finish(); uint64_t d0 = gal_present_unfit(); present_fit(dk, &c); uint64_t d1 = gal_present_unfit();
        if (k < 2) CHECK(d1 > d0, "48×9 %s侧贴边暗带（压暗到 1/6、断口贯穿全部行）：期望报内容 实得 +%llu", k ? "左" : "右", (unsigned long long)(d1 - d0));
        else CHECK(d1 == d0, "48×9 %s：期望不报 实得 +%llu", k == 2 ? "从左到右渐暗（没有台阶）" : k == 3 ? "中间暗竖条（不贴边）" : "右侧贴边暗块但有竖纹（贴脸暗门柱，10-22 怪猎）", (unsigned long long)(d1 - d0));
        nxgal_tex_release(dk);
    }
    // 两侧纯黑的居中页、对侧黑区里一个小图标（10-22 暗黑3 读盘页每局第 810–1020 次出图误报左侧暗带）：期望不报（对侧亮的行不到一半）；旧判法对侧整段总和 ≥ 1 就算亮、照报
    { uint32_t dk = mk_dark(5); nxgal_present_pillar(0); present_n(full, &c, FIT_N); gal_finish(); uint64_t d0 = gal_present_unfit(); present_fit(dk, &c); uint64_t d1 = gal_present_unfit();
      CHECK(d1 == d0, "48×9 居中原画、两侧纯黑、右黑区一个小图标：期望不报暗带 实得 +%llu", (unsigned long long)(d1 - d0)); nxgal_tex_release(dk); }
    // 右侧贴边暗带 + 标 2（两侧被放宽内容画过）：照判（10-22 八方2 右带反证：某一遍没铺满放宽宽度，两侧仍算放宽内容画的）；标 3 / 4：不判
    { uint32_t dk = mk_dark(0); nxgal_present_pillar(2); present_n(full, &c, FIT_N); gal_finish(); uint64_t d0 = gal_present_unfit(); present_fit(dk, &c); uint64_t d1 = gal_present_unfit();
      CHECK(d1 > d0, "48×9 右侧贴边暗带 + 标两侧是放宽内容画的：期望照判 实得 +%llu", (unsigned long long)(d1 - d0));
      for (int g = 3; g <= 4; g++) { nxgal_present_pillar(g); present_n(full, &c, FIT_N); gal_finish(); uint64_t e0 = gal_present_unfit(); present_fit(dk, &c); uint64_t e1 = gal_present_unfit();
        CHECK(e1 == e0, "48×9 右侧贴边暗带 + 标 %d：期望不判 实得 +%llu", g, (unsigned long long)(e1 - e0)); }
      nxgal_present_pillar(0); nxgal_tex_release(dk); }
    nxgal_tex_release(left); present_n(full, &c, FIT_N); gal_finish(); uint64_t u6n = gal_present_unfit();
    nxgal_window_set_size(64, 32); present_n(narrow, &c, FIT_N); gal_finish(); uint64_t u7 = gal_present_unfit();
    CHECK(u7 == u6n, "8×4（不比 16:9 宽）最左一列黑：期望不判内容 实得 +%llu", (unsigned long long)(u7 - u6n));
    uint32_t bl = narrow; nxgal_tex_release(mid); nxgal_tex_release(logo); nxgal_tex_release(full);
    nxgal_window_set_layer(NULL); nxgal_tex_release(bl); nxgal_tex_release(t);
    gal_present_fit_period(30);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0); signal(SIGSEGV, on_sig); signal(SIGBUS, on_sig);
    if (nxgal_init(0)) { printf("初始化失败\n"); return 2; }
    int w, h; CHECK(nxgal_screenshot(NULL, 0, &w, &h) == 0 && w == 0 && h == 0, "还没出图时截图应返回 0");
    t_crop(); t_formats(); t_order(); t_window(); t_fill(); t_layer(); t_fit();
    uint64_t s[4]; nxgal_window_stats(s);
    printf("出图计数：出图 %llu 上屏 %llu 顶掉 %llu 取不到 %llu\n", (unsigned long long)s[0], (unsigned long long)s[1], (unsigned long long)s[2], (unsigned long long)s[3]);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}

// 第 1 块单测：建目标 → 清屏（通道开头整清 / 通道内局部清 / 整数格式 / 深度 / 数组某层）→ 读回逐字节核；贴图写读往返；同步号。
// 期望值全部手算（不跑被测实现）：unorm8 = round(x × 255)，选 0.2 / 0.4 / 0.6 / 1.0 这类整除值避开舍入歧义。
#include "../gal_abi.h"
#include "gal_abi_hash.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
static void on_sig(int s) { void *b[32]; int n = backtrace(b, 32); backtrace_symbols_fd(b, n, 2); _exit(128 + s); }

static int g_fail, g_checks;
NXGAL_API uint64_t nxgal_helper_compiles(void);   // gal_core.m（内部头声明；C 单测直接声明）
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

enum { R8Unorm = 0, R32Uint = 10, R8G8B8A8Unorm = 36, D32Float = 51 };
static nxgal_tex_info info2d(int w, int h, int fmt, int bpp, int target, int depth, int levels) {
    nxgal_tex_info i = {w, h, depth, levels, 1, 1, 1, bpp, fmt, 0, target, {2, 3, 4, 5}};
    return i;
}
static float bitsf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

// 1：RGBA8 整清（通道开头 load = Clear）+ 剪裁局部清 R|A（通道内画三角）
static void t_color(void) {
    printf("· RGBA8 64×32：整清 (0.2,0.4,0.6,1.0) → 剪裁 (8,4,16,8) 掩码 R|A 清 (1,0,0,0)\n");
    nxgal_tex_info i = info2d(64, 32, R8G8B8A8Unorm, 4, 1, 1, 1);
    uint32_t t = nxgal_tex_create(&i); CHECK(t, "建贴图失败");
    nxgal_set_render_targets(&t, 1, 0);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    float c0[4] = {0.2f, 0.4f, 0.6f, 1.0f}; nxgal_clear_color(0, 0, 1, 0xf, c0);
    nxgal_rect sc = {8, 4, 16, 8}; nxgal_set_scissors(&sc, 1);
    float c1[4] = {1, 0, 0, 0}; nxgal_clear_color(0, 0, 1, 0x9, c1);
    uint8_t px[64 * 32 * 4];
    uint64_t n = nxgal_tex_get_data(t, 0, 0, px, sizeof px); CHECK(n == sizeof px, "读回字节数 %llu ≠ %zu", (unsigned long long)n, sizeof px);
    int bad = 0;
    for (int y = 0; y < 32; y++) for (int x = 0; x < 64; x++) {
        int in = x >= 8 && x < 24 && y >= 4 && y < 12;
        uint8_t e[4] = {in ? 255 : 51, 102, 153, in ? 0 : 255};
        if (memcmp(px + (y * 64 + x) * 4, e, 4) && bad++ < 3) { uint8_t *p = px + (y * 64 + x) * 4; printf("  ✗ (%d,%d) 期望 %u %u %u %u 实得 %u %u %u %u\n", x, y, e[0], e[1], e[2], e[3], p[0], p[1], p[2], p[3]); }
    }
    g_checks++; if (bad) { g_fail++; printf("  ✗ 共 %d / 2048 像素不符\n", bad); }
    nxgal_set_scissors(&full, 1);
    nxgal_tex_release(t);
}

// 2：R32Uint 整清与局部清：浮点寄存器按位当整数
static void t_uint(void) {
    printf("· R32Uint 16×16：整清位型 0x12345678 → 剪裁 (0,0,4,4) 清位型 0xCAFEBABE\n");
    nxgal_tex_info i = info2d(16, 16, R32Uint, 4, 1, 1, 1);
    uint32_t t = nxgal_tex_create(&i);
    nxgal_set_render_targets(&t, 1, 0);
    float c0[4] = {bitsf(0x12345678), 0, 0, 0}; nxgal_clear_color(0, 0, 1, 0xf, c0);
    nxgal_rect sc = {0, 0, 4, 4}; nxgal_set_scissors(&sc, 1);
    float c1[4] = {bitsf(0xCAFEBABE), 0, 0, 0}; nxgal_clear_color(0, 0, 1, 0xf, c1);
    uint32_t px[256]; nxgal_tex_get_data(t, 0, 0, px, sizeof px);
    CHECK(px[0] == 0xCAFEBABE, "(0,0) 期望 0xCAFEBABE 实得 %#x", px[0]);
    CHECK(px[3 * 16 + 3] == 0xCAFEBABE, "(3,3) 期望 0xCAFEBABE 实得 %#x", px[3 * 16 + 3]);
    CHECK(px[4] == 0x12345678, "(4,0) 期望 0x12345678 实得 %#x", px[4]);
    CHECK(px[255] == 0x12345678, "(15,15) 期望 0x12345678 实得 %#x", px[255]);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    nxgal_tex_release(t);
}

// 3：D32Float 整清 0.5 → 局部清 0.25
static void t_depth(void) {
    printf("· D32Float 32×32：整清 0.5 → 剪裁 (16,16,16,16) 清 0.25\n");
    nxgal_tex_info i = info2d(32, 32, D32Float, 4, 1, 1, 1);
    uint32_t d = nxgal_tex_create(&i);
    nxgal_set_render_targets(NULL, 0, d);
    nxgal_clear_ds(0, 1, 0.5f, 1, 0, 0);
    nxgal_rect sc = {16, 16, 16, 16}; nxgal_set_scissors(&sc, 1);
    nxgal_clear_ds(0, 1, 0.25f, 1, 0, 0);
    float px[1024]; nxgal_tex_get_data(d, 0, 0, px, sizeof px);
    CHECK(px[0] == 0.5f, "(0,0) 期望 0.5 实得 %g", px[0]);
    CHECK(px[15 * 32 + 15] == 0.5f, "(15,15) 期望 0.5 实得 %g", px[15 * 32 + 15]);
    CHECK(px[16 * 32 + 16] == 0.25f, "(16,16) 期望 0.25 实得 %g", px[16 * 32 + 16]);
    CHECK(px[1023] == 0.25f, "(31,31) 期望 0.25 实得 %g", px[1023]);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    nxgal_tex_release(d);
}

// 4：2D 数组 3 层：整清三层 → 只清第 1 层
static void t_layers(void) {
    printf("· RGBA8 2D 数组 8×8×3：整清 (0.2,0.2,0.2,0.2) → 只清第 1 层 (0.4,0.4,0.4,0.4)\n");
    nxgal_tex_info i = info2d(8, 8, R8G8B8A8Unorm, 4, 4, 3, 1);
    uint32_t t = nxgal_tex_create(&i);
    nxgal_set_render_targets(&t, 1, 0);
    float a[4] = {0.2f, 0.2f, 0.2f, 0.2f}, b[4] = {0.4f, 0.4f, 0.4f, 0.4f};
    nxgal_clear_color(0, 0, 3, 0xf, a);
    nxgal_clear_color(0, 1, 1, 0xf, b);
    uint8_t px[8 * 8 * 4 * 3]; uint64_t n = nxgal_tex_get_data(t, -1, -1, px, sizeof px);
    CHECK(n == sizeof px, "整张读回字节数 %llu ≠ %zu", (unsigned long long)n, sizeof px);
    CHECK(px[0] == 51, "第 0 层 期望 51 实得 %u", px[0]);
    CHECK(px[256] == 102 && px[256 + 255] == 102, "第 1 层 期望 102 实得 %u / %u", px[256], px[256 + 255]);
    CHECK(px[512] == 51, "第 2 层 期望 51 实得 %u", px[512]);
    nxgal_tex_release(t);
}

// 5：写读往返：R8 5×3 两层 3 级（行跨度 4 字节对齐：宽 5 → 8，宽 2 → 4，宽 1 → 4）
static void t_roundtrip(void) {
    printf("· R8 5×3 数组 2 层 3 级：整张写入 → 整张读回、单层单级读回\n");
    nxgal_tex_info i = info2d(5, 3, R8Unorm, 1, 4, 2, 3);
    uint32_t t = nxgal_tex_create(&i);
    // 级 0：跨度 8 × 3 行 × 2 层 = 48；级 1（2×1）：4 × 1 × 2 = 8；级 2（1×1）：4 × 1 × 2 = 8；共 64
    uint8_t src[64], dst[64]; for (int k = 0; k < 64; k++) src[k] = (uint8_t)(k * 7 + 1);
    CHECK(nxgal_tex_get_data(t, -1, -1, NULL, 0) == 64, "整张大小 期望 64 实得 %llu", (unsigned long long)nxgal_tex_get_data(t, -1, -1, NULL, 0));
    nxgal_tex_set_data(t, -1, -1, NULL, src, sizeof src);
    memset(dst, 0, sizeof dst); nxgal_tex_get_data(t, -1, -1, dst, sizeof dst);
    // 只比有效字节：每行前「宽」个
    int bad = 0; uint64_t off = 0; int w = 5, h = 3;
    for (int lv = 0; lv < 3; lv++) { int stride = (w + 3) & ~3;
        for (int L = 0; L < 2; L++) for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { uint64_t o = off + (uint64_t)L * stride * h + y * stride + x; if (src[o] != dst[o] && bad++ < 3) printf("  ✗ 级 %d 层 %d (%d,%d) 期望 %u 实得 %u\n", lv, L, x, y, src[o], dst[o]); }
        off += (uint64_t)stride * h * 2; w = w > 1 ? w / 2 : 1; h = h > 1 ? h / 2 : 1; }
    g_checks++; if (bad) { g_fail++; printf("  ✗ 共 %d 字节不符\n", bad); }
    uint8_t one[24]; CHECK(nxgal_tex_get_data(t, 1, 0, one, sizeof one) == 24, "单层单级大小 期望 24");
    CHECK(one[0] == src[24] && one[8 + 4] == src[24 + 8 + 4], "第 1 层第 0 级 期望 %u/%u 实得 %u/%u", src[24], src[36], one[0], one[12]);
    // 子矩形写：第 0 层第 0 级 (1,1) 起 2×2，数据行跨度 = align(2,4) = 4
    uint8_t sub[8] = {200, 201, 0, 0, 202, 203, 0, 0}; nxgal_rect r = {1, 1, 2, 2};
    nxgal_tex_set_data(t, 0, 0, &r, sub, sizeof sub);
    uint8_t l0[24]; nxgal_tex_get_data(t, 0, 0, l0, sizeof l0);
    CHECK(l0[8 + 1] == 200 && l0[8 + 2] == 201 && l0[16 + 1] == 202 && l0[16 + 2] == 203, "子矩形写 期望 200 201 202 203 实得 %u %u %u %u", l0[9], l0[10], l0[17], l0[18]);
    CHECK(l0[8] == src[8] && l0[8 + 3] == src[11], "子矩形外不动 期望 %u %u 实得 %u %u", src[8], src[11], l0[8], l0[11]);
    nxgal_tex_release(t);
}

// 6：同步号
static void t_sync(void) {
    printf("· 同步号：建 1、2 → 等 2 → 已完成号 ≥ 2\n");
    nxgal_create_sync(1, 0); nxgal_create_sync(2, 1);
    nxgal_wait_sync(2);
    uint64_t c = nxgal_current_sync(); CHECK(c == 2, "已完成号 期望 2 实得 %llu", (unsigned long long)c);
    nxgal_wait_sync(1);   // 已被收拢的旧号：立即返回、不报红
    nxgal_create_sync(3, 0); nxgal_wait_sync(3);
    c = nxgal_current_sync(); CHECK(c == 3, "已完成号 期望 3 实得 %llu", (unsigned long long)c);
}

// 7：先留一个开着的拷贝编码器（SetData），再挂起整清 → 直接读回（galreplay 自测抓到的缺陷：清屏排到读回拷贝之后）
static void t_pending_after_blit(void) {
    printf("· SetData 留着拷贝编码器 → 整清挂起 → 读回：期望清屏色 51 102 153 255\n");
    nxgal_tex_info i = info2d(16, 16, R8G8B8A8Unorm, 4, 1, 1, 1);
    uint32_t a = nxgal_tex_create(&i), b = nxgal_tex_create(&i);
    uint8_t px[16 * 16 * 4] = {0}; nxgal_tex_set_data(b, -1, -1, NULL, px, sizeof px);
    nxgal_set_render_targets(&a, 1, 0);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    float c[4] = {0.2f, 0.4f, 0.6f, 1.0f}; nxgal_clear_color(0, 0, 1, 0xf, c);
    uint8_t o[16 * 16 * 4]; nxgal_tex_get_data(a, 0, 0, o, sizeof o);
    CHECK(o[0] == 51 && o[1] == 102 && o[2] == 153 && o[3] == 255, "期望 51 102 153 255 实得 %u %u %u %u", o[0], o[1], o[2], o[3]);
    nxgal_tex_release(a); nxgal_tex_release(b);
}

// 1b：多颜色附件时清第 1 个附件（剪裁局部清 → 通道内画三角路径）：只清它、其余附件不动
// 期望（手算）：两张 RGBA8 16×16，整清附件 0 = (1,0,0,1) 红、附件 1 = (0,1,0,1) 绿（通道开头 load = Clear）；
//   剪裁 (0,0,4,4) 清附件 1 = (0,0,1,1) 蓝 → 附件 1 的 (0,0)(3,3) 蓝、(4,0)(15,15) 绿；附件 0 全部仍红
static void t_color_mrt(void) {
    printf("· 两个颜色附件：整清 红 / 绿 → 剪裁 (0,0,4,4) 只清附件 1 为蓝\n");
    nxgal_tex_info i = info2d(16, 16, R8G8B8A8Unorm, 4, 1, 1, 1);
    uint32_t t[2] = {nxgal_tex_create(&i), nxgal_tex_create(&i)}; CHECK(t[0] && t[1], "建贴图失败");
    nxgal_set_render_targets(t, 2, 0);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1}, blue[4] = {0, 0, 1, 1};
    nxgal_clear_color(0, 0, 1, 0xf, red); nxgal_clear_color(1, 0, 1, 0xf, green);
    nxgal_rect sc = {0, 0, 4, 4}; nxgal_set_scissors(&sc, 1);
    nxgal_clear_color(1, 0, 1, 0xf, blue);
    uint8_t p0[16 * 16 * 4], p1[16 * 16 * 4];
    nxgal_tex_get_data(t[0], 0, 0, p0, sizeof p0); nxgal_tex_get_data(t[1], 0, 0, p1, sizeof p1);
    const uint8_t R[4] = {255, 0, 0, 255}, G[4] = {0, 255, 0, 255}, B[4] = {0, 0, 255, 255};
    int bad0 = 0, bad1 = 0;
    for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
        int k = (y * 16 + x) * 4, in = x < 4 && y < 4;
        if (memcmp(p0 + k, R, 4)) bad0++;
        if (memcmp(p1 + k, in ? B : G, 4)) { if (bad1++ < 3) printf("  ✗ 附件 1 (%d,%d) 期望 %s 实得 %u %u %u %u\n", x, y, in ? "蓝" : "绿", p1[k], p1[k + 1], p1[k + 2], p1[k + 3]); }
    }
    CHECK(bad0 == 0, "附件 0 期望全红，%d / 256 像素不符（(0,0) 实得 %u %u %u %u）", bad0, p0[0], p0[1], p0[2], p0[3]);
    CHECK(bad1 == 0, "附件 1 期望框内蓝框外绿，%d / 256 像素不符", bad1);
    nxgal_set_scissors(&full, 1);
    nxgal_tex_release(t[0]); nxgal_tex_release(t[1]);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0); signal(SIGSEGV, on_sig); signal(SIGBUS, on_sig);
    if (nxgal_init(0)) { printf("初始化失败\n"); return 2; }
    CHECK(nxgal_abi_hash() == NXGAL_ABI_HASH, "ABI 指纹不符");
    t_color(); t_color_mrt(); t_uint(); t_depth(); t_layers(); t_roundtrip(); t_sync(); t_pending_after_blit();
    // 内部辅助库离线化（10-23）：启动 + 清屏 / 读回全程不现编辅助库（离线库由 Makefile 编在可执行文件旁 gal_helpers/，单测目标依赖它）
    CHECK(nxgal_helper_compiles() == 0, "内部辅助库现编 %llu 次（期望 0：离线库 gal_helpers/ 没找到或源码哈希不符）", (unsigned long long)nxgal_helper_compiles());
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}

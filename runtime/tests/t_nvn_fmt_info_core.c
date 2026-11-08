// D7 B：中立格式信息表（nvn_fmt_info.h）的纯 C 用例。
// 表由 gen_nvn_fmt_info.py 从 nvn.h 的格式名生成；这里用独立规则核对：
// 每个格式的块字节必须与共享布局表 nvn_tex 的 bpb 一致，且通道 / 整型 / sRGB / 深度模板自洽。
#include "nvn_fmt_info.h"
#include "nvn_tex.h"
#include "nvn_fmt_expand.h"
#include <stdio.h>

static int fails, checks;

static void eq_i(const char *what, int got, int want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %d，期望 %d\n", what, got, want); }
}

static void want_info(const char *what, uint32_t f, int ch, int bytes, int bw, int bh, int kind, int srgb, int depth, int stencil) {
    nvn_fmt_info i;
    checks++;
    if (!nvn_fmt_info_of(f, &i)) { fails++; printf("FAIL %s：0x%02X 不在表里\n", what, f); return; }
    if (i.channels != ch || i.bytes != bytes || i.bw != bw || i.bh != bh || i.kind != kind || i.srgb != srgb || i.depth != depth || i.stencil != stencil) {
        fails++;
        printf("FAIL %s：0x%02X = {ch %u, bytes %u, block %ux%u, kind %u, srgb %u, depth %u, stencil %u}\n",
               what, f, i.channels, i.bytes, i.bw, i.bh, i.kind, i.srgb, i.depth, i.stencil);
    }
}


// 换表前的 nvn_tex.c fmt_of，原样冻结成金样：用独立旧实现核对新查表结果。
typedef struct { uint8_t bpb, bw, bh; } frozen_fmt_t;
static frozen_fmt_t frozen_fmt_of(int f) {
    static const uint8_t astc[14][2] = {{4,4},{5,4},{5,5},{6,5},{6,6},{8,5},{8,6},{8,8},{10,5},{10,6},{10,8},{10,10},{12,10},{12,12}};
    if (f >= 0x79 && f <= 0x94) { int k = (f - 0x79) % 14; return (frozen_fmt_t){16, astc[k][0], astc[k][1]}; }
    if (f >= 0x41 && f <= 0x50) {
        int b8 = (f <= 0x42) || (f == 0x45 || f == 0x46) || (f == 0x49 || f == 0x4A);
        return (frozen_fmt_t){b8 ? 8 : 16, 4, 4};
    }
    static const struct { uint8_t lo, hi, bpb; } r[] = {
        {0x01,0x04,1},{0x05,0x09,2},{0x0A,0x0C,4},{0x0D,0x10,2},{0x11,0x15,4},{0x16,0x18,8},
        {0x19,0x1C,3},{0x1D,0x21,6},{0x22,0x24,12},{0x25,0x28,4},{0x29,0x2D,8},{0x2E,0x30,16},
        {0x31,0x31,1},{0x32,0x32,2},{0x33,0x35,4},{0x36,0x36,8},{0x37,0x38,4},{0x39,0x3C,2},{0x3D,0x40,4},
        {0x51,0x52,1},{0x53,0x54,2},{0x55,0x56,4},{0x57,0x58,2},{0x59,0x5A,4},{0x5B,0x5C,8},
        {0x5D,0x5E,3},{0x5F,0x60,6},{0x61,0x62,12},{0x63,0x64,4},{0x65,0x66,8},{0x67,0x68,16},
        {0x69,0x6C,4},{0x6D,0x70,4},{0x71,0x75,8},{0x76,0x78,16},{0x95,0x98,2},{0x99,0x9C,4},
    };
    for (unsigned i = 0; i < sizeof r / sizeof *r; i++)
        if (f >= r[i].lo && f <= r[i].hi) return (frozen_fmt_t){r[i].bpb, 1, 1};
    return (frozen_fmt_t){0, 1, 1};
}

int main(void) {
    // 代表性格式（手算）
    want_info("RGBA8", 0x25, 4, 4, 1, 1, NVN_FMT_UNORM, 0, 0, 0);
    want_info("RGBA8UI", 0x27, 4, 4, 1, 1, NVN_FMT_UINT, 0, 0, 0);
    want_info("RGBA8I", 0x28, 4, 4, 1, 1, NVN_FMT_SINT, 0, 0, 0);
    want_info("RGBA8SN", 0x26, 4, 4, 1, 1, NVN_FMT_SNORM, 0, 0, 0);
    want_info("RGBA32F", 0x2E, 4, 16, 1, 1, NVN_FMT_FLOAT, 0, 0, 0);
    want_info("RGBA8_SRGB", 0x38, 4, 4, 1, 1, NVN_FMT_UNORM, 1, 0, 0);
    want_info("STENCIL8", 0x31, 1, 1, 1, 1, NVN_FMT_UNORM, 0, 0, 1);
    want_info("DEPTH24_STENCIL8", 0x35, 1, 4, 1, 1, NVN_FMT_UNORM, 0, 1, 1);
    want_info("DEPTH32F_STENCIL8", 0x36, 1, 8, 1, 1, NVN_FMT_FLOAT, 0, 1, 1);
    want_info("RGB565", 0x3C, 3, 2, 1, 1, NVN_FMT_UNORM, 0, 0, 0);
    want_info("RGB10A2", 0x3D, 4, 4, 1, 1, NVN_FMT_UNORM, 0, 0, 0);
    want_info("RGB_DXT1", 0x41, 3, 8, 4, 4, NVN_FMT_UNORM, 0, 0, 0);
    want_info("RGBA_ASTC_4x4", 0x79, 4, 16, 4, 4, NVN_FMT_UNORM, 0, 0, 0);

    // 全表：登记项自洽（非零块字节、通道、kind、块宽高）
    int n = 0;
    for (uint32_t f = 1; f <= NVN_FMT_MAX; f++) {
        nvn_fmt_info i;
        if (!nvn_fmt_info_of(f, &i)) continue;
        n++;
        checks++;
        if (i.channels < 1 || i.channels > 4 || i.bytes == 0 || i.kind > NVN_FMT_FLOAT || i.bw == 0 || i.bh == 0) {
            fails++; printf("FAIL 0x%02X 不合法：ch %u bytes %u block %ux%u kind %u\n", f, i.channels, i.bytes, i.bw, i.bh, i.kind);
        }
        if (i.srgb && i.kind != NVN_FMT_UNORM) { fails++; printf("FAIL 0x%02X sRGB 却是 kind %u\n", f, i.kind); }
        if ((i.depth || i.stencil) && i.channels != 1) { fails++; printf("FAIL 0x%02X 深度/模板却是 %u 通道\n", f, i.channels); }
    }
    eq_i("登记格式数", n, NVN_FMT_COUNT);

    // 上传展开：目标必须在表里、通道数对、不再链式展开，且共享 helper 与表一致
    int n_expand = 0;
    for (uint32_t f = 1; f <= NVN_FMT_MAX; f++) {
        nvn_fmt_info i;
        if (!nvn_fmt_info_of(f, &i) || !i.expand) continue;
        n_expand++;
        nvn_fmt_info t;
        if (!nvn_fmt_info_of(i.expand, &t)) { fails++; printf("FAIL 0x%02X 展开目标 0x%02X 不在表里\n", f, i.expand); continue; }
        int want_ch = i.channels == 3 ? 4 : i.channels;
        if (t.channels != want_ch) { fails++; printf("FAIL 0x%02X 展开目标通道 %u != %d\n", f, t.channels, want_ch); }
        if (t.expand) { fails++; printf("FAIL 0x%02X 展开目标 0x%02X 仍会再展开\n", f, i.expand); }
        int bpp = 0;
        if (nvn_fmt_expand_target(f, NULL, &bpp) != 1 || bpp != t.bytes) {
            fails++; printf("FAIL 0x%02X 共享 helper 目标字节 %d != 表 %u\n", f, bpp, t.bytes);
        }
        checks++;
    }
    eq_i("上传展开格式数", n_expand, 40);

    // 冻结旧实现 vs 新查表：0x00–0xFF 全码逐一对比，列全部不一致
    int bad = 0;
    for (uint32_t f = 0; f <= 0xFF; f++) {
        frozen_fmt_t want = frozen_fmt_of((int)f);
        int bw = 0, bh = 0;
        int bpb = nvn_fmt_bpb((int)f, &bw, &bh);
        checks++;
        if (want.bpb != bpb || want.bw != bw || want.bh != bh) {
            bad++;
            fails++;
            printf("FAIL 0x%02X：旧实现 {bpb %u, %ux%u} != 新实现 {bpb %d, %dx%d}\n",
                   f, want.bpb, want.bw, want.bh, bpb, bw, bh);
        }
    }
    eq_i("冻结旧实现 vs 新实现不一致数", bad, 0);

    // 0 与越界不在表里
    nvn_fmt_info tmp;
    eq_i("0 不在表里", nvn_fmt_info_of(0, &tmp), 0);
    eq_i("越界不在表里", nvn_fmt_info_of(NVN_FMT_MAX + 1, &tmp), 0);

    if (fails) printf("✗ t_nvn_fmt_info_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_fmt_info_core：格式信息表 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}

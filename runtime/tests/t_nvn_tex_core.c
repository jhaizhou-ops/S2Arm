// D7 第一片：nvn_tex.c（Tegra 块线性布局）是纯 C、无 Metal / Foundation 依赖，能在 Linux 上单独编译和验证。
// 期望值按独立公式手算：GOB = 64B × 8 行；块高 pick_tile(块行数×3/16)；层 = 块对齐。
#include "nvn_tex.h"
#include <stdio.h>
#include <string.h>

static int fails, checks;

static void eq_u64(const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %llu，期望 %llu\n", what, (unsigned long long)got, (unsigned long long)want); }
}

static void eq_u32(const char *what, uint32_t got, uint32_t want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %u，期望 %u\n", what, got, want); }
}

static void eq_i(const char *what, int got, int want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %d，期望 %d\n", what, got, want); }
}

static nvn_texdesc tex(int target, int format, int flags, uint32_t w, uint32_t h, uint32_t d, uint32_t levels, int samples) {
    nvn_texdesc t;
    memset(&t, 0, sizeof t);
    t.target = target; t.format = format; t.flags = flags;
    t.width = w; t.height = h; t.depth = d; t.levels = levels; t.samples = samples;
    return t;
}

int main(void) {
    // 格式：RGBA8 = 0x25（4B/1×1）；ASTC 4×4 = 0x79（16B/4×4）；未知格式 = 0
    int bw = 0, bh = 0;
    eq_i("RGBA8 bpb", nvn_fmt_bpb(0x25, &bw, &bh), 4);
    eq_i("RGBA8 块宽", bw, 1); eq_i("RGBA8 块高", bh, 1);
    eq_i("ASTC4x4 bpb", nvn_fmt_bpb(0x79, &bw, &bh), 16);
    eq_i("ASTC4x4 块宽", bw, 4); eq_i("ASTC4x4 块高", bh, 4);
    eq_i("未知格式 bpb", nvn_fmt_bpb(0, NULL, NULL), 0);

    nvn_texlayout L;
    // 2D 64×64 RGBA8：块行 64 → 块高 3；GOB 列 4、高 8 → 4×1×1×4096 = 16 KiB
    nvn_texdesc t = tex(1, 0x25, 0, 64, 64, 1, 1, 0);
    nvn_tex_layout(&t, &L);
    eq_u64("64x64 RGBA8 size", L.size, 16384);
    eq_u64("64x64 RGBA8 layer", L.layer_size, 16384);
    eq_u32("64x64 RGBA8 align", L.align, 512);
    eq_u32("64x64 RGBA8 layers", L.layers, 1);
    eq_u32("64x64 RGBA8 bpb", L.bpb, 4);
    eq_u32("64x64 RGBA8 tileH", L.tileH, 3);
    eq_u64("64x64 lvl0", nvn_tex_level_offset(&t, 0), 0);
    eq_u64("64x64 lvl1", nvn_tex_level_offset(&t, 1), 16384);

    // 128×128 RGBA8：块行 128 → 块高 4；8×1×1×8192 = 64 KiB
    t = tex(1, 0x25, 0, 128, 128, 1, 1, 0);
    nvn_tex_layout(&t, &L);
    eq_u64("128x128 RGBA8 size", L.size, 65536);
    eq_u32("128x128 RGBA8 tileH", L.tileH, 4);

    // 64×64 两级 mip：第 1 级 32×32 → 2 GOB 列 × 1 块行高(2) × 2048 = 4096；总 20480
    t = tex(1, 0x25, 0, 64, 64, 1, 2, 0);
    nvn_tex_layout(&t, &L);
    eq_u64("64x64 2 级 size", L.size, 20480);
    eq_u64("64x64 2 级 lvl1", nvn_tex_level_offset(&t, 1), 16384);

    // 线性（flags 0x10）：行距按 32 对齐 → 256B × 64 行 = 16 KiB，一级在 0
    t = tex(1, 0x25, 0x10, 64, 64, 1, 1, 0);
    nvn_tex_layout(&t, &L);
    eq_u64("linear 64x64 size", L.size, 16384);
    eq_u32("linear align", L.align, 32);
    eq_u64("linear lvl1", nvn_tex_level_offset(&t, 1), 0);

    // 缓冲纹理：100 × 4B = 400，按 4 对齐
    t = tex(10, 0x25, 0, 100, 1, 1, 1, 0);
    nvn_tex_layout(&t, &L);
    eq_u64("buffer 100 RGBA8 size", L.size, 400);
    eq_u32("buffer align", L.align, 4);

    // 立方体 16×16 RGBA8：每面 1×1×1024 = 1024，6 面共 6144
    t = tex(8, 0x25, 0, 16, 16, 1, 1, 0);
    nvn_tex_layout(&t, &L);
    eq_u64("cube 16 size", L.size, 6144);
    eq_u64("cube 16 layer", L.layer_size, 1024);
    eq_u32("cube 16 layers", L.layers, 6);

    // 2D_ARRAY 16×16 三层：1024 × 3
    t = tex(4, 0x25, 0, 16, 16, 3, 1, 0);
    nvn_tex_layout(&t, &L);
    eq_u64("array 3 size", L.size, 3072);
    eq_u32("array 3 layers", L.layers, 3);

    // ASTC 4×4 64×64：16×16 块 × 16B = 4096；块高 1
    t = tex(1, 0x79, 0, 64, 64, 1, 1, 0);
    nvn_tex_layout(&t, &L);
    eq_u64("ASTC4x4 64 size", L.size, 4096);
    eq_u32("ASTC4x4 64 bpb", L.bpb, 16);
    eq_u32("ASTC4x4 64 tileH", L.tileH, 1);

    // 稀疏查询：1024×1024 ASTC 6×6（0x7D，16B/6×6）→ 384×384 页、2 级；非稀疏返回 0
    t = tex(1, 0x7D, 0x20, 1024, 1024, 1, 5, 0);
    uint32_t tile[4];
    nvn_tex_sparse_layout(&t, tile);
    eq_u32("sparse 级数", tile[0], 2);
    eq_u32("sparse 页宽", tile[1], 384);
    eq_u32("sparse 页高", tile[2], 384);
    eq_u32("sparse 页深", tile[3], 1);
    t = tex(1, 0x7D, 0, 1024, 1024, 1, 1, 0);
    nvn_tex_sparse_layout(&t, tile);
    eq_u32("非稀疏级数", tile[0], 0);

    // 纹理缓冲包装成 2D：一行的字节数按行对齐；多行必须首尾相接
    uint32_t w = 0, h = 0, row = 0;
    eq_i("tbuf 单行", nvn_tbuf_rows(1000, 4, 256, &w, &h, &row), 1);
    eq_u32("tbuf 单行宽", w, 1000); eq_u32("tbuf 单行高", h, 1); eq_u32("tbuf 单行行距", row, 4096);
    eq_i("tbuf 多行", nvn_tbuf_rows(20000, 4, 256, &w, &h, &row), 1);   // 满行行距正好 16384×4，首尾相接
    eq_u32("tbuf 多行宽", w, 16384); eq_u32("tbuf 多行高", h, 2); eq_u32("tbuf 多行行距", row, 65536);
    eq_i("tbuf 行距不整除", nvn_tbuf_rows(20000, 3, 1000, &w, &h, &row), 0);
    eq_i("tbuf 0 元素", nvn_tbuf_rows(0, 4, 256, &w, &h, &row), 0);
    // Ampere 折行读的精确行（nvn_tbuf_rows_exact）：W × H = 元素数；多于一行时 W = 整除元素数的最大 2 的幂（≤ 16384）；放不下 / 行距不对齐 → 0
    eq_i("tbuf 精确 单行", nvn_tbuf_rows_exact(1000, 4, 256, &w, &h, &row), 1);
    eq_u32("tbuf 精确 单行宽", w, 1000); eq_u32("tbuf 精确 单行高", h, 1); eq_u32("tbuf 精确 单行行距", row, 4096);
    eq_i("tbuf 精确 20000", nvn_tbuf_rows_exact(20000, 4, 16, &w, &h, &row), 1);   // 20000 = 2^5 × 625
    eq_u32("tbuf 精确 20000 宽", w, 32); eq_u32("tbuf 精确 20000 高", h, 625); eq_u32("tbuf 精确 20000 行距", row, 128);
    eq_i("tbuf 精确 Pokopia 1016320", nvn_tbuf_rows_exact(1016320, 4, 16, &w, &h, &row), 1);   // 2^9 × 1985
    eq_u32("tbuf 精确 Pokopia 宽", w, 512); eq_u32("tbuf 精确 Pokopia 高", h, 1985); eq_u32("tbuf 精确 Pokopia 行距", row, 2048);
    eq_i("tbuf 精确 整 2 行", nvn_tbuf_rows_exact(32768, 4, 256, &w, &h, &row), 1);
    eq_u32("tbuf 精确 整 2 行宽", w, 16384); eq_u32("tbuf 精确 整 2 行高", h, 2);
    eq_i("tbuf 精确 奇数 16385（要 16385 行）", nvn_tbuf_rows_exact(16385, 4, 16, &w, &h, &row), 0);
    eq_i("tbuf 精确 行距不对齐（32 × 4 = 128 不是 256 的倍数）", nvn_tbuf_rows_exact(20000, 4, 256, &w, &h, &row), 0);
    eq_i("tbuf 精确 0 元素", nvn_tbuf_rows_exact(0, 4, 256, &w, &h, &row), 0);

    // 原生门禁按结论行判绿：成功必须 ^✓ t_，失败必须 ^✗ t_（runtime/gate.sh:36）。
    if (fails) printf("✗ t_nvn_tex_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_tex_core：纯 C 布局 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}

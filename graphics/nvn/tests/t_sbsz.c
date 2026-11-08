// 存储缓冲大小表（spvBufferSizeConstants，nvn_refl.h nvn_sbsz_fill）：绑定表照实际反射手造，期望手算，不跑被测实现。
//   11-06 鬼灭 #37：几何内核 811f026c33b55bab_bg3 的反射（直连库原样）只有几何辅助缓冲与两张长度表：
//     vb_info 几何 reg 3 参数号 0 / gp_c3 常量 参数号 1 / vertex_output 几何 reg 0 参数号 2 / geometry_vb_output 几何 reg 1 参数号 3 /
//     geometry_ib_output 几何 reg 2 参数号 4 / trb_data 几何 reg 4 参数号 5 / gal_ubo_len 参数号 6 / spvBufferSizeConstants 参数号 7。
//   内核按表的 [2] [3] [4] 夹写顶点捕获 / 几何顶点 / 几何索引；表短于 5 项时它读到表外，写入被夹掉，索引槽留残值。
//   ① 本笔临时区段长 {顶点捕获 4096, 几何顶点 3600, 几何索引 1440, 信息 32, 装配表 720} → 表长 6，[0] 32（vb_info 是 reg 3）、[1] 0（常量缓冲不进表）、
//      [2] 4096、[3] 3600、[4] 1440、[5] 720
//   ② 普通存储缓冲照旧：SBUFP 参数号 1 当前绑定 256 字节、SBUFU 参数号 3 → 表长 4：[0] 0、[1] 256、[2] 0、[3] UINT32_MAX & ~15
//   ③ 几何段超过 4 GiB → 夹成 UINT32_MAX & ~15（同 SBUFP 超长的处理）
//   ④ 没有一项进表 → 表长 1、[0] 0
#include <stdio.h>
#include <string.h>
#include "../gfx/nvn/nvn_refl.h"
static int fail, total;
#define CHECK(c, ...) do { total++; printf("%s ", (c) ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); if (!(c)) fail++; } while (0)
static uint32_t bound(void *ctx, const nvn_rbind *b) { (void)ctx; return b->reg == 5 ? 256 : 0; }   // ② 的 SBUFP 绑在存储槽 5
static nvn_rbind rb(int kind, int reg, int aid) { nvn_rbind b; memset(&b, 0, sizeof b); b.kind = (uint8_t)kind; b.reg = (uint16_t)reg; b.aid = (uint16_t)aid; return b; }
int main(void) {
    uint32_t q[NVN_REFL_MAXARG];
    {   nvn_rbind b[8] = {rb(NVN_RB_GEOMETRY, 3, 0), rb(NVN_RB_CBUF, 0, 1), rb(NVN_RB_GEOMETRY, 0, 2), rb(NVN_RB_GEOMETRY, 1, 3), rb(NVN_RB_GEOMETRY, 2, 4),
                          rb(NVN_RB_GEOMETRY, 4, 5), rb(NVN_RB_UBOLEN, 0, 6), rb(NVN_RB_SBSZ, 0, 7)};
        uint64_t geo[5] = {4096, 3600, 1440, 32, 720}; memset(q, 0xee, sizeof q);
        int n = nvn_sbsz_fill(b, 8, bound, NULL, geo, q);
        CHECK(n == 6, "① 几何内核（鬼灭 811f）：表长 %d（期望 6，内核读到 [4] 几何索引输出）", n);
        CHECK(n >= 5 && q[2] == 4096 && q[3] == 3600 && q[4] == 1440, "① [2] 顶点捕获 %u / [3] 几何顶点 %u / [4] 几何索引 %u（期望 4096 / 3600 / 1440）", q[2], q[3], q[4]);
        CHECK(n >= 6 && q[0] == 32 && q[1] == 0 && q[5] == 720, "① [0] 信息 %u / [1] 常量缓冲 %u / [5] 装配表 %u（期望 32 / 0 / 720）", q[0], q[1], q[5]); }
    {   nvn_rbind b[3] = {rb(NVN_RB_SBUFP, 5, 1), rb(NVN_RB_SBUFU, 0, 3), rb(NVN_RB_TEX, 0, 0)};
        uint64_t geo[5] = {0}; memset(q, 0xee, sizeof q);
        int n = nvn_sbsz_fill(b, 3, bound, NULL, geo, q);
        CHECK(n == 4 && q[0] == 0 && q[1] == 256 && q[2] == 0 && q[3] == (UINT32_MAX & ~15u), "② 普通存储缓冲：表长 %d，%u %u %u %#x（期望 4，0 256 0 0xfffffff0）", n, q[0], q[1], q[2], q[3]); }
    {   nvn_rbind b[1] = {rb(NVN_RB_GEOMETRY, 1, 0)};
        uint64_t geo[5] = {0, 5ull << 30, 0, 0, 0};
        int n = nvn_sbsz_fill(b, 1, bound, NULL, geo, q);
        CHECK(n == 1 && q[0] == (UINT32_MAX & ~15u), "③ 几何段 5 GiB：%#x（期望 0xfffffff0）", q[0]); }
    {   nvn_rbind b[1] = {rb(NVN_RB_TEX, 0, 0)}; uint64_t geo[5] = {0}; memset(q, 0xee, sizeof q);
        int n = nvn_sbsz_fill(b, 1, bound, NULL, geo, q);
        CHECK(n == 1 && q[0] == 0, "④ 没有一项进表：表长 %d、[0] %u（期望 1、0）", n, q[0]); }
    printf("%s t_sbsz：%d 项，失败 %d\n", fail ? "✗" : "✓", total, fail);
    return fail ? 1 : 0;
}

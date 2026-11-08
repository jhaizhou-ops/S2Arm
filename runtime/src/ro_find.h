// 找游戏 SDK 自己的 nn::ro::detail::RoModule 初始化函数（loader.c ro_handoff 用；10-31 出包线，Minecraft 首帧前 nn::ro::LookupSymbol 读空表头崩溃）。
// 模块对象（RoModule）的字段布局随 SDK 版本变（暗黑3 的 sdk 基址在 +0x20、大小在 +0xc0；Minecraft 的在 +0x28、+0xb8），
//   宿主不猜布局，只调游戏自己的初始化：多数 SDK 导出它（loader.c 按名字找），有的 SDK 不导出、只在 nn::ro::LoadModule 里调。
// 本函数从导出的 LoadModule 入口（前 4 条有无条件 b 就跟一跳进内部实现），收集实现里（到第一个 ret 为止）所有 bl 的目标，
//   目标函数里（到第一个 ret 为止）同时出现 DT_RELACOUNT（0x6ffffff9）和 DT_RELCOUNT（0x6ffffffa）两个标签常量（movz 低半 + movk 高半 0x6fff）的就是解析动态段的初始化；
//   恰好一个才算找到。这版的参数是 (对象, 基址, 大小, 动态段, 布尔, 报错回调)，前 5 个与导出版 InitializeEmmPKNS1_3Elf5Elf643DynEb 同序。
// [lo, hi) 是可读的代码范围（模块代码段），所有取指都先核在范围内。
#pragma once
#include <stddef.h>
#include <stdint.h>

#define RO_FIND_SCAN 2048u   // 每个函数最多看的指令数

static int ro_in(const uint32_t *p, const uint32_t *lo, const uint32_t *hi) { return p >= lo && p < hi; }
static const uint32_t *ro_branch(const uint32_t *p) { int32_t imm = (int32_t)(*p << 6) >> 6; return p + imm; }   // b / bl 的目标
static int ro_is_b(uint32_t w) { return (w & 0xfc000000u) == 0x14000000u; }
static int ro_is_bl(uint32_t w) { return (w & 0xfc000000u) == 0x94000000u; }
static int ro_is_ret(uint32_t w) { return w == 0xd65f03c0u; }

// 函数里是否同时有 DT_RELACOUNT / DT_RELCOUNT 两个常量（movz wN/xN #0xfff9|#0xfffa（hw 0）+ movk 同寄存器 #0x6fff, lsl #16）
static int ro_parses_dyn(const uint32_t *f, const uint32_t *lo, const uint32_t *hi) {
    uint32_t lo16[32] = {0}; int got = 0;   // 每个寄存器最近一次 movz 的低半
    for (unsigned i = 0; i < RO_FIND_SCAN && ro_in(f + i, lo, hi); i++) {
        uint32_t w = f[i], rd = w & 31, hw = w >> 21 & 3, imm = w >> 5 & 0xffff;
        if ((w & 0x7f800000u) == 0x52800000u && !hw) lo16[rd] = imm;   // movz（32 / 64 位）
        else if ((w & 0x7f800000u) == 0x72800000u && hw == 1 && imm == 0x6fff) {   // movk #0x6fff, lsl #16
            if (lo16[rd] == 0xfff9) got |= 1;
            if (lo16[rd] == 0xfffa) got |= 2;
        }
        if (got == 3) return 1;
        if (ro_is_ret(w)) break;
    }
    return 0;
}

// → 初始化函数入口；找不到或不唯一返回 NULL，*why 写原因
static const uint32_t *ro_find_init(const uint32_t *load_module, const uint32_t *lo, const uint32_t *hi, const char **why) {
    if (!ro_in(load_module, lo, hi)) { *why = "LoadModule 不在代码段"; return NULL; }
    const uint32_t *impl = load_module;   // 入口本身就是实现（多数 SDK）；入口前 4 条里有无条件 b 的（Minecraft：mov w5, wzr; b 实现）跟过去
    for (unsigned i = 0; i < 4 && ro_in(load_module + i, lo, hi); i++)
        if (ro_is_b(load_module[i])) { impl = ro_branch(load_module + i); break; }
    if (!ro_in(impl, lo, hi)) { *why = "LoadModule 跳出了代码段"; return NULL; }
    const uint32_t *hit = NULL; unsigned n = 0;
    for (unsigned i = 0; i < RO_FIND_SCAN && ro_in(impl + i, lo, hi) && !ro_is_ret(impl[i]); i++) {
        if (!ro_is_bl(impl[i])) continue;
        const uint32_t *t = ro_branch(impl + i);
        if (t == hit || !ro_in(t, lo, hi) || !ro_parses_dyn(t, lo, hi)) continue;
        hit = t; n++;
    }
    if (n != 1) { *why = n ? "LoadModule 里解析动态段的函数不止一个" : "LoadModule 里没有解析动态段的函数"; return NULL; }
    return hit;
}

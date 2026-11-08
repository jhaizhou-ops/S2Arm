// 找 SDK 自带 RoModule 初始化（ro_find.h）单测：指令字现造，期望按构造直接写出（哪一格是初始化入口），不调被测函数推。
//   ① 入口 mov w5, wzr; b 实现（Minecraft 形态）→ 实现里两个 bl：只有 movz 0xfff9 没有 movk 的辅助函数不算，
//      同时有 0x6ffffff9 / 0x6ffffffa 的那个才是 → 返回它
//   ② 入口本身就是实现（无 b）→ 同样找到
//   ③ 实现里两个不同的解析动态段函数 → 不唯一，NULL
//   ④ 初始化只在第一个 ret 之后才被 bl → 不算（实现扫到 ret 为止），NULL
//   ⑤ bl 目标跳出代码段 → 不读、NULL
#include "../src/ro_find.h"
#include <stdio.h>
#include <string.h>
static int bad, cnt;
#define EQ(name, want, got) do { long w_ = (long)(want), g_ = (long)(got); cnt++; if (w_ != g_) { bad++; printf("✗ %s：期望 %ld → 真结果 %ld\n", name, w_, g_); } } while (0)
enum { MOV_W5 = 0x2a1f03e5, RET = 0xd65f03c0, NOP = 0xd503201f };
static uint32_t b(int from, int to) { return 0x14000000u | ((uint32_t)(to - from) & 0x3ffffff); }
static uint32_t bl(int from, int to) { return 0x94000000u | ((uint32_t)(to - from) & 0x3ffffff); }
static uint32_t movz(int rd, unsigned imm) { return 0x52800000u | imm << 5 | (unsigned)rd; }
static uint32_t movk16(int rd, unsigned imm) { return 0x72a00000u | imm << 5 | (unsigned)rd; }   // movk wN, #imm, lsl #16
static uint32_t c[256];
static void parser(int at) { c[at] = movz(23, 0xfff9); c[at + 1] = movk16(23, 0x6fff); c[at + 2] = movz(24, 0xfffa); c[at + 3] = movk16(24, 0x6fff); c[at + 4] = RET; }
static long find(int entry, int hi) { const char *why = ""; const uint32_t *r = ro_find_init(c + entry, c, c + hi, &why); return r ? r - c : -1; }
static void reset(void) { for (int i = 0; i < 256; i++) c[i] = NOP; c[100] = movz(8, 0xfff9); c[101] = RET; parser(120); parser(140); }   // 100：只有 movz 的辅助；120 / 140：两个解析函数
int main(void) {
    reset(); c[0] = MOV_W5; c[1] = b(1, 10); c[10] = bl(10, 100); c[11] = bl(11, 120); c[12] = bl(12, 120); c[13] = RET;
    EQ("① 入口 b 进实现，挑出解析动态段的那个", 120, find(0, 256));
    reset(); c[10] = bl(10, 100); c[11] = bl(11, 140); c[12] = RET;
    EQ("② 入口就是实现", 140, find(10, 256));
    reset(); c[10] = bl(10, 120); c[11] = bl(11, 140); c[12] = RET;
    EQ("③ 两个解析函数 → 不唯一", -1, find(10, 256));
    reset(); c[10] = bl(10, 100); c[11] = RET; c[12] = bl(12, 120);
    EQ("④ ret 之后的 bl 不算", -1, find(10, 256));
    reset(); c[10] = bl(10, 120); c[11] = RET;
    EQ("⑤ 目标在代码段外", -1, find(10, 100));
    printf("%s t_ro_find：期望 %d 处全对 → %d 处不符\n", bad ? "✗" : "✓", cnt, bad);
    return bad != 0;
}

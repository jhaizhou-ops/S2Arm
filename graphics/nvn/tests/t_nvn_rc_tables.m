// 条件渲染的两张报告表（nvn_mtl.m rc_note / rc_value / rc_occ_add）不丢条目。
// 期望（按 NVN 语义与表的约定手写，不由被测实现推出）：
//   一次提交里先回放 N 个遮挡查询报告（各在自己的地址），再回放 1 个时间戳报告到 rec；条件读 rec 时：时间戳报告已回放、GPU 未完成 → 计数字段按 0 算（已知），
//   不管前面有多少遮挡查询。遮挡查询的地址读出来是「未知」（照画）。旧表 256 格两类混记：N ≥ 256 时时间戳被丢，读到内存里 CPU 写的 1 → 条件清除照跑（时之笛走动白帧）。
//   ① N = 600（时之笛走动一帧量级）：rc_value(rec) 已知、值 0
//   ② 遮挡查询地址：rc_value 未知（返回 0）
//   ③ N = 20000（超过旧遮挡表 4096 格）：最早那个遮挡地址仍认得出（未知），rec 仍已知为 0
//   ④ 新提交（表清空）后 rec 读内存（CPU 写的 1）
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, fails;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static uint64_t mem[40000][2];   // 每格 16 字节：报告记录（计数 64 位 + 时间 64 位）
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    uint64_t rec = (uint64_t)(uintptr_t)&mem[39999][0]; mem[39999][0] = 1;   // CPU 写的 1：这个目标需要清
    for (int round = 0; round < 2; round++) {
        int n = round ? 20000 : 600; g_rc_npend = 0;
        for (int i = 0; i < n; i++) rc_note((uint64_t)(uintptr_t)&mem[i][0], 2);
        rc_note(rec, 1);
        uint64_t v = 99; int known = rc_value(rec, &v);
        VERIFY(known == 1 && v == 0, "%s N=%d 个遮挡查询后回放的时间戳报告：已知 %d（期望 1）、值 %llu（期望 0，不是内存里的 1）", round ? "③" : "①", n, known, (unsigned long long)v);
        uint64_t w = 99; int k2 = rc_value((uint64_t)(uintptr_t)&mem[0][0], &w);
        VERIFY(k2 == 0, "%s 最早的遮挡查询地址：已知 %d（期望 0 = 未知，照画）", round ? "③" : "②", k2);
    }
    g_rc_npend = 0;   // 新提交（nvn_be_sub_begin 清空）
    uint64_t v = 99; int known = rc_value(rec, &v);
    VERIFY(known == 1 && v == 1, "④ 新提交里没回放过时间戳：读内存 已知 %d、值 %llu（期望 1 / 1）", known, (unsigned long long)v);
    printf("%s t_nvn_rc_tables：%u 项，%u 项失败（条件渲染报告表不丢条目）\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }

// 同局交替开关（runtime/src/alt.c）单测：段号奇偶按「(现在 − 起点) / 每段」手算，不跑被测实现推期望
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <signal.h>
int s2a_alt_phase_at(uint64_t t0, uint64_t now, uint64_t period);
int s2a_alt_phase(void);
void s2a_alt_mark(void);
static int count, fail;
static volatile sig_atomic_t signal_phase = -2;
static void on_signal(int number) { (void)number; signal_phase = s2a_alt_phase(); }
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); count++; if (w_ != g_) { fail++; printf("✗ %s：期望 %lld → 真结果 %lld\n", name, w_, g_); } } while (0)
int main(void) {
    EXPECT("还没 MARK（起点 0）：不交替", -1, s2a_alt_phase_at(0, 500, 100));
    EXPECT("不交替（每段 0）", -1, s2a_alt_phase_at(1000, 1500, 0));
    EXPECT("时钟早于起点：不交替", -1, s2a_alt_phase_at(1000, 999, 100));
    EXPECT("起点那一刻：第 0 段关", 0, s2a_alt_phase_at(1000, 1000, 100));
    EXPECT("第 0 段末（+99）：关", 0, s2a_alt_phase_at(1000, 1099, 100));
    EXPECT("+100：第 1 段开", 1, s2a_alt_phase_at(1000, 1100, 100));
    EXPECT("+199：第 1 段开", 1, s2a_alt_phase_at(1000, 1199, 100));
    EXPECT("+200：第 2 段关", 0, s2a_alt_phase_at(1000, 1200, 100));
    EXPECT("+750：第 7 段开", 1, s2a_alt_phase_at(1000, 1750, 100));
    // 真正的 os.c → plat_apple.c 时钟链：首次 MARK 初始化后，信号里只查询。
    EXPECT("设置真实时钟长窗口", 0, setenv("S2A_ALT", "3600", 1));
    EXPECT("首次 MARK 前不交替", -1, s2a_alt_phase());
    s2a_alt_mark();
    EXPECT("真实时钟首次 MARK 进入关段", 0, s2a_alt_phase());
    s2a_alt_mark();
    EXPECT("重复 MARK 仍处于关段", 0, s2a_alt_phase());
    struct sigaction action = {0};
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    int installed = sigaction(SIGUSR1, &action, NULL);
    EXPECT("安装相位查询信号", 0, installed);
    if (!installed) {
        EXPECT("触发相位查询信号", 0, raise(SIGUSR1));
        EXPECT("信号中真实时钟查询", 0, signal_phase);
    }
    printf("%s t_alt：%d 项，失败 %d\n", fail ? "✗" : "✓", count, fail);
    return fail != 0;
}

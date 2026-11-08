// 游戏时钟冻结（#495，runtime/src/os.c）：假壁钟驱动，期望按 Switch 语义手算——挂起时系统计数器停，唤醒后从挂起那一刻接着走；
//   按原因冻结（1 后台、2 系统键盘），全部原因解除才走；多线程读在反复冻结 / 解冻中保持单调
//   s-leeq 在 #510 的 9 项单测（未冻结跟壁钟 / 冻结停住 / 解冻不跳 / 解冻后只走解冻后的时长 / 原因叠加等）拿本实现跑 9/9 绿，语义一致；
//   ⑩ 是那一版缺的并发单调项（那一版跑出倒退 13056～32105 次）
#include "../src/native.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>

static _Atomic uint64_t g_now = 1;
static _Atomic int g_auto;   // 1 = 每次读壁钟自增 1（并发单调用例）
uint64_t plat_now_ns(void) { return atomic_load(&g_auto) ? atomic_fetch_add(&g_now, 1) : atomic_load(&g_now); }
static void at(uint64_t t) { atomic_store(&g_now, t); }
static _Atomic uint64_t g_cont;   // 假的含睡眠连续钟（覆盖 os.c 的弱定义）：宿主睡眠时 plat_now_ns 不走、它照走
uint64_t s2a_cont_ns(void) { return atomic_load(&g_cont); }
static int g_cb; static void on_catchup(void) { g_cb++; }

static int bad, n;
static void eq(const char *what, uint64_t got, uint64_t want) {
    n++;
    if (got != want) { printf("✗ %s：期望 %llu → %llu\n", what, (unsigned long long)want, (unsigned long long)got); bad++; }
}

static _Atomic int g_stop;
static void *reader(void *a) {
    uint64_t prev = 0, back = 0;
    while (!atomic_load(&g_stop)) { uint64_t v = guest_ns(); if (v < prev) back++; prev = v; }
    *(uint64_t *)a = back;
    return NULL;
}

void s2a_guest_tick_hz_set(uint64_t hz);
int main(void) {
    at(1000);  eq("① 没冻结：游戏时间 = 壁钟", guest_ns(), 1000);
    at(2000);  guest_clock_freeze_for(1, 1);
    at(5000);  eq("② 后台冻结后壁钟走 3000：游戏时间停在冻结那一刻 2000", guest_ns(), 2000);
    at(7000);  guest_clock_freeze_for(1, 0);
    eq("③ 解冻那一刻：从 2000 接着走", guest_ns(), 2000);
    at(7500);  eq("④ 解冻后壁钟走 500：2500", guest_ns(), 2500);
    at(8000);  guest_clock_freeze_for(1, 1);   // 游戏时间 3000
    at(9000);  guest_clock_freeze_for(2, 1);   // 再叠系统键盘
    at(10000); guest_clock_freeze_for(1, 0);
    eq("⑤ 两个原因只解一个：仍停在 3000", guest_ns(), 3000);
    at(12000); guest_clock_freeze_for(2, 0);
    at(12100); eq("⑥ 全部解除后走 100：3100", guest_ns(), 3100);
    at(13000); guest_clock_freeze_for(2, 0);   // 没冻着的原因解除：不该动
    eq("⑦ 解除没设的原因不改时钟：4000", guest_ns(), 4000);
    guest_clock_freeze(1); guest_clock_freeze(1);   // 同一原因冻两次、解一次就走
    at(14000); guest_clock_freeze(0);
    at(14250); eq("⑧ 同一原因重复冻结：解一次即走（4000 + 250）", guest_ns(), 4250);
    at(14250 + 625000000ull); eq("⑨ 19.2 MHz 计数：游戏时间 625000250 ns → 12000004 tick", guest_tick(), (4250 + 625000000ull) * 12 / 625);
    // ⑨b Switch 2：计数器 31.25 MHz = 每 32 ns 一个（NPDM 起局设）；设回 19.2 MHz 读数同 ⑨
    s2a_guest_tick_hz_set(31250000); eq("⑨b 31.25 MHz 计数：游戏时间 625000250 ns → 19531257 tick", guest_tick(), (4250 + 625000000ull) / 32);
    s2a_guest_tick_hz_set(19200000); eq("⑨c 设回 19.2 MHz：同 ⑨", guest_tick(), (4250 + 625000000ull) * 12 / 625);

    // ⑪⑫ 游戏计数器没看到的宿主时长（#863）：后台 1 小时、其中宿主睡了 40 分钟——单调钟只走醒着的 20 分钟，连续钟走满 60 分钟；
    //   稳态时钟要补的就是这 60 分钟（真机睡眠时系统计数器停、稳态时钟照走）。回前台后醒着走的时间计数器看得到，不再长
    {
        const uint64_t M = 60000000000ull, t0 = 20000;
        at(t0); atomic_store(&g_cont, 5 * M);
        int64_t u0 = s2a_clock_unseen_ns();
        guest_clock_freeze_for(1, 1);
        at(t0 + 20 * M); atomic_store(&g_cont, 65 * M);
        guest_clock_freeze_for(1, 0);
        eq("⑪ 后台 1 小时（其中睡 40 分钟）：没看到的时长 +60 分钟", (uint64_t)(s2a_clock_unseen_ns() - u0), 60 * M);
        at(t0 + 30 * M); atomic_store(&g_cont, 75 * M);
        eq("⑫ 回前台醒着走 10 分钟：没看到的时长不变", (uint64_t)(s2a_clock_unseen_ns() - u0), 60 * M);
    }
    // ⑬⑭ 补时回调：没登记时调用是空操作；登记后壳每调一次（回前台 / Mac 唤醒）回调一次
    s2a_clock_catchup();
    eq("⑬ 没登记回调：调用不出事、不计数", g_cb, 0);
    s2a_clock_register_catchup(on_catchup); s2a_clock_catchup(); s2a_clock_catchup();
    eq("⑭ 登记后调两次：回调两次", g_cb, 2);

    // ⑩ 并发单调：4 个读线程，主线程反复冻结 / 解冻 20000 次，壁钟每读一次加 1
    atomic_store(&g_auto, 1);
    pthread_t th[4]; uint64_t back[4] = {0};
    for (int i = 0; i < 4; i++) pthread_create(&th[i], NULL, reader, &back[i]);
    for (int i = 0; i < 20000; i++) { guest_clock_freeze_for(1 + (i & 1), 1); guest_clock_freeze_for(1 + (i & 1), 0); }
    atomic_store(&g_stop, 1);
    uint64_t total = 0; for (int i = 0; i < 4; i++) { pthread_join(th[i], NULL); total += back[i]; }
    eq("⑩ 4 线程读、反复冻结 / 解冻 20000 次：倒退次数 0", total, 0);

    if (bad) { printf("✗ t_os：%d/%d 项不符\n", bad, n); return 1; }
    printf("✓ t_os：%d 项游戏时钟冻结全符（停住、接着走、按原因叠加、19.2 MHz 计数、没看到的时长、补时回调、并发单调）\n", n);
    return 0;
}

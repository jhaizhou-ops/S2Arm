// 玩家 1 六轴来源仲裁（runtime/src/motion_pick.c）：期望按「谁在操作 + 谁有样本」手算，不复述实现。
//   输入来源用 s2a_pad_source 原值（0 触屏 / 1 NS2 Pro BLE / 2 系统手柄）；known 非 0 = 那一路这一帧有样本。
#include "motion_pick.h"
#include <stdio.h>

static int bad;
static void expect(const char *what, int got, int want) {
    if (got != want) { printf("✗ %s：期望 %d → 实际 %d\n", what, want, got); bad++; }
}
// 反向检查：返回的那一路必须真的有样本（没有就拿 NONE）
static void expect_never_missing(const char *what, int got, int ns2, int gc, int phone) {
    int ok = got == S2A_MOTION_NONE || (got == S2A_MOTION_NS2 && ns2) || (got == S2A_MOTION_GC && gc) || (got == S2A_MOTION_PHONE && phone);
    if (!ok) { printf("✗ %s：返回 %d，但那一路没有样本（ns2=%d gc=%d phone=%d）\n", what, got, ns2, gc, phone); bad++; }
}

int main(void) {
    // ① 触屏在操作：手机优先（手柄躺在包里也只报躺着不动的抖）
    expect("① 触屏 + 三路都有", s2a_motion_pick(0, 1, 1, 1), S2A_MOTION_PHONE);
    expect("① 触屏 + 手机没有 → 系统手柄", s2a_motion_pick(0, 1, 1, 0), S2A_MOTION_GC);
    expect("① 触屏 + 只剩 NS2", s2a_motion_pick(0, 1, 0, 0), S2A_MOTION_NS2);
    expect("① 触屏 + 都没有", s2a_motion_pick(0, 0, 0, 0), S2A_MOTION_NONE);
    // ② 系统手柄在驱动输入：手柄优先，没样本才退
    expect("② 系统 + 三路都有", s2a_motion_pick(2, 1, 1, 1), S2A_MOTION_GC);
    expect("② 系统手柄是 Xbox（无六轴）→ NS2", s2a_motion_pick(2, 1, 0, 1), S2A_MOTION_NS2);
    expect("② 系统手柄无六轴、没 NS2 → 手机", s2a_motion_pick(2, 0, 0, 1), S2A_MOTION_PHONE);
    expect("② 系统 + 都没有", s2a_motion_pick(2, 0, 0, 0), S2A_MOTION_NONE);
    // ③ NS2 Pro 在驱动输入：NS2 优先（两只都在线时不能读错刚体）
    expect("③ NS2 + 三路都有", s2a_motion_pick(1, 1, 1, 1), S2A_MOTION_NS2);
    expect("③ NS2 还没出样本 → 系统手柄", s2a_motion_pick(1, 0, 1, 1), S2A_MOTION_GC);
    expect("③ NS2 没有、系统手柄也没有 → 手机", s2a_motion_pick(1, 0, 0, 1), S2A_MOTION_PHONE);
    // ④ 负对照：未知输入来源当触屏处理；玩家关了手机陀螺仪（phone=0）时不许返回手机
    expect("④ 未知来源（7）当触屏", s2a_motion_pick(7, 0, 0, 1), S2A_MOTION_PHONE);
    expect("④ 手机陀螺仪关掉 → 不许返回手机", s2a_motion_pick(0, 0, 1, 0), S2A_MOTION_GC);
    // ⑤ 全表：任何组合都不许返回「没有样本」的那一路
    for (int sel = 0; sel <= 3; sel++)
        for (int ns2 = 0; ns2 <= 1; ns2++)
            for (int gc = 0; gc <= 1; gc++)
                for (int phone = 0; phone <= 1; phone++) {
                    char what[96];
                    snprintf(what, sizeof what, "⑤ 全表 sel=%d ns2=%d gc=%d phone=%d", sel, ns2, gc, phone);
                    int got = s2a_motion_pick(sel, ns2, gc, phone);
                    expect_never_missing(what, got, ns2, gc, phone);
                    if (!ns2 && !gc && !phone) expect(what, got, S2A_MOTION_NONE);
                }
    if (bad) { printf("✗ t_motion_pick：%d 处不符\n", bad); return 1; }
    printf("✓ t_motion_pick：%d 组手算 + 全表 64 组一致性全符（触屏→手机、系统手柄→GCMotion、NS2→NS2、无样本→NONE）\n", 12);
    return 0;
}

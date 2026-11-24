// Mac 手柄震动（macos/front_mac.m）：① 游戏振幅 → 播放强度的换算 s2a_hp_feel（ios/haptic_retry.h）；② 循环播放器建不了时退到普通播放器的接线。
// 现场（11-10 M1 Max / macOS 27.0.1 / DualSense / 程序号 0400486024DEC000）：createAdvancedPlayerWithPattern 报 NSCocoaErrorDomain 4097，连续 3 次后本局停用；
//   同一只手柄新引擎上 createPlayerWithPattern 能建能播。游戏振幅每秒 0.002–0.191，按原值播放没感觉。
// 期望值不跑被测实现即可算：公式 1.25·sqrt(a)·(3 − 2·a^0.15) 封顶 1，下面的数是手算 / Python 算的。
// 用法：t_mac_rumble <front_mac.m 路径>
#include "haptic_retry.h"
#include "../macos/rumble_session.h"
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static int checks, failures;
static void check(int ok, const char *what) { checks++; if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); } }
static int count_in(const char *text, const char *needle) { int n = 0; for (const char *p = text; (p = strstr(p, needle)); p += strlen(needle)) n++; return n; }
static int after(const char *text, const char *key, const char *needle) { const char *p = strstr(text, key); return p && strstr(p, needle); }
static int near(float got, float want) { return fabsf(got - want) < 0.005f; }

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "用法：t_mac_rumble <front_mac.m 路径>\n"); return 2; }
    FILE *file = fopen(argv[1], "rb");
    if (!file) { perror(argv[1]); return 2; }
    static char source[1 << 20];
    size_t size = fread(source, 1, sizeof source - 1, file);
    fclose(file);
    source[size] = 0;

    // ---- 换算 ----
    check(s2a_hp_feel(0) == 0 && s2a_hp_feel(-1) == 0 && s2a_hp_feel(NAN) == 0, "0 / 负数 / NaN → 0（不震）");
    check(near(s2a_hp_feel(0.064f), 0.530f), "现场常见振幅 0.064 → 0.53（按原值 0.064 没感觉）");
    check(near(s2a_hp_feel(0.191f), 0.785f), "现场最大振幅 0.191 → 0.79");
    check(near(s2a_hp_feel(0.002f), 0.123f), "衰减尾 0.002 → 0.12");
    check(s2a_hp_feel(0.5f) == 1 && s2a_hp_feel(1) == 1 && s2a_hp_feel(4) == 1, "0.5 / 1 / 超界 → 封顶 1");
    int monotonic = 1; for (int i = 1; i < 1000; i++) if (s2a_hp_feel(i / 1000.0f) > s2a_hp_feel((i + 1) / 1000.0f) + 1e-6f) monotonic = 0;
    check(monotonic, "(0, 1] 上单调不减（游戏给得更大，播得不会更小）");
    int raised = 1; for (int i = 1; i <= 1000; i++) if (s2a_hp_feel(i / 1000.0f) < i / 1000.0f) raised = 0;
    check(raised, "(0, 1] 上不低于原值（只抬不压）");

    // ---- 接线 ----
    check(count_in(source, "s2a_hp_feel(") == 1, "front_mac.m 只在 rumbler_play 里换算一次（#520：每只手柄一个 S2ARumbler）");
    check(after(source, "static void rumbler_play", "s2a_hp_feel(amp[k]) * rumble_scale()"), "先换算、再乘玩家的强度档倍率（左右两路各自）");
    check(count_in(source, "createAdvancedPlayerWithPattern:") == 1 && count_in(source, "createPlayerWithPattern:") == 1, "循环播放器、普通播放器各建一处");
    check(after(source, "createAdvancedPlayerWithPattern:", "r->plainOnly = YES; *again = YES; return NO;") && after(source, "static void rumbler_play", "rumbler_reset(r); if (again) rumbler_play(r, pair); return;"),
          "循环播放器建失败：记下、丢掉引擎、从头再来（失败过的引擎上再建普通播放器报 Client not registred）");
    check(after(source, "static void rumble_select", "[S2ARumbler new]"), "换手柄后重新试循环播放器（新的 S2ARumbler，plainOnly 从零开始）");
    check(after(source, "!r->loops[k] && now - r->startedNs[k] > MAC_RUMBLE_RESTART_NS", "r->playing[k] = NO;"), "普通播放器不能循环：连着震到期限就重起一轮");
    check(count_in(source, "loopEnabled = YES") == 1, "循环只对循环播放器开");
    check(after(source, "if (!r->device.haptics)", "s2a_mac_hid_pad_rumble"), "无 CoreHaptics 的第三方 Pro 走 HID 震动出口");
    check(after(source, "static void rumble_select", "s2a_mac_hid_pad_has_pro"), "第三方 Pro 有 HID 震动出口时建立反馈会话");
    check(after(source, "static uint64_t rumble_session", "s2a_mac_hid_pad_has_pro"), "HID 晚于 GameController 接入时补建反馈会话");
    check(after(source, "static uint64_t rumble_session", "if (rumble_off()) return 0"), "关闭震动时 rumble_session 直接回 0");
    check(count_in(source, "++g_rumble_counter") == 0 && count_in(source, "atomic_fetch_add_explicit(&g_rumble_counter") == 1 &&
          count_in(source, "s2a_mac_rumble_claim_epoch") == 1,
          "震动会话计数器原子递增，服务线程补建走同一原子 helper");
    check(after(source, "s2a_mac_rumble_claim_epoch", "has_pro, rumble_off())"),
          "rumble_session 调用点把关闭状态原样传给 helper，不反传");

    // ---- 补建会话的行为判据 ----
    _Atomic uint64_t epoch = 0, counter = 0;
    check(s2a_mac_rumble_claim_epoch(&epoch, &counter, 1, 1) == 0 && atomic_load(&epoch) == 0 && atomic_load(&counter) == 0,
          "关闭震动：即使有第三方 Pro 也不建会话、不递增计数器");
    check(s2a_mac_rumble_claim_epoch(&epoch, &counter, 1, 0) == 1 && atomic_load(&epoch) == 1 && atomic_load(&counter) == 1,
          "开启震动：第三方 Pro 补建会话 1");
    check(s2a_mac_rumble_claim_epoch(&epoch, &counter, 1, 0) == 1 && atomic_load(&epoch) == 1 && atomic_load(&counter) == 1,
          "已有会话：重复查询不新建、不递增计数器");

    if (failures) { fprintf(stderr, "t_mac_rumble：%d/%d 项不符\n", failures, checks); return 1; }
    printf("✓ t_mac_rumble：%d 项（振幅换算 0.064→0.53 / 0.191→0.79 / 封顶 1 / 单调；循环播放器失败退普通播放器并重起）\n", checks);
    return 0;
}

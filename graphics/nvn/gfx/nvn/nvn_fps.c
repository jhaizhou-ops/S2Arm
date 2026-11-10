#include "nvn_fps.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static int g_limit;
// 只认十进制整数（不带符号、空格或尾随字符）；越界或别的写法返回 -1
int nvn_fps_parse(const char *e) {
    if (!e || !*e) return -1;
    if (!strcmp(e, "0")) return 0;
    int v = 0;
    for (const char *p = e; *p; p++) {
        if (*p < '0' || *p > '9' || p - e >= 4) return -1;
        v = v * 10 + (*p - '0');
    }
    return v >= NVN_FPS_MIN_HZ && v <= NVN_FPS_MAX_HZ ? v : -1;
}
static void fps_init(void) {
    const char *e = getenv("S2A_FPS");
    if (!e) return;
    int v = nvn_fps_parse(e);
    if (v < 0) { fprintf(stderr, "[nvn] 【红】 S2A_FPS=%s：只接受 0（不限）或 %d–%d 的整数\n", e, NVN_FPS_MIN_HZ, NVN_FPS_MAX_HZ); abort(); }
    g_limit = v;
    if (g_limit) fprintf(stderr, "[nvn] S2A_FPS=%d：直连额外帧率上限，保留游戏交换间隔；DM_PRESENT_HZ / DM_FPS 不绕过此上限\n", g_limit);
}
int nvn_fps_limit(void) { pthread_once(&g_once, fps_init); return g_limit; }
double nvn_fps_period(double period) {
    int fps = nvn_fps_limit(); double limit = fps ? 1.0 / fps : 0;
    return period < limit ? limit : period;
}
uint64_t nvn_fps_period_ns(uint64_t period) {
    int fps = nvn_fps_limit(); uint64_t limit = fps ? (1000000000ull + fps - 1) / fps : 0;
    return period < limit ? limit : period;
}
// 用户帧率设置只加上限；不改游戏的交换间隔，也不解除游戏原有的锁帧。

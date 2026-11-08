#include "nvn_fps.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static int g_limit;
static void fps_init(void) {
    const char *e = getenv("S2A_FPS");
    if (!e || !strcmp(e, "0")) return;
    if (!strcmp(e, "30")) g_limit = 30;
    else if (!strcmp(e, "60")) g_limit = 60;
    else if (!strcmp(e, "120")) g_limit = 120;
    else { fprintf(stderr, "[nvn] 【红】 S2A_FPS=%s：只接受 0/30/60/120\n", e); abort(); }
    fprintf(stderr, "[nvn] S2A_FPS=%d：直连额外帧率上限，保留游戏交换间隔；DM_PRESENT_HZ / DM_FPS 不绕过此上限\n", g_limit);
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

// t_nvn_warmtick 的前端替身（不以 t_ 开头：runtime/gate.sh 把 graphics/nvn/tests/t_* 都当单测组）：记下 s2a_front_warm_tick 每次的参数；第 g_tick_enter_at 次周期调用（开始那次不算）返回 1 = 现在进游戏，0 = 一直等
#include <stdatomic.h>
#include <stdint.h>
_Atomic long g_tick_calls, g_tick_first_done = -1, g_tick_first_total = -1, g_tick_full; long g_tick_enter_at, g_tick_total;
int s2a_front_warm_tick(long done, long total) {
    long k = atomic_fetch_add(&g_tick_calls, 1);
    if (k == 0) { atomic_store(&g_tick_first_done, done); atomic_store(&g_tick_first_total, total); return 0; }
    if (done == total && total == g_tick_total) atomic_fetch_add(&g_tick_full, 1);
    return g_tick_enter_at && k >= g_tick_enter_at ? 1 : 0;
}
_Atomic long g_tick_released;
void s2a_front_warm_released(void) { atomic_fetch_add(&g_tick_released, 1); }   // 直连层自己放行时通知前端（G 例数次数）
// 宿主目标引用的 loadprog.c 其余入口（本单测不链 loadprog.c，见 runtime/tests/mk/nvn_warmtick.mk）：首帧到来只记不做
void s2a_load_first_frame(uint64_t now) { (void)now; }

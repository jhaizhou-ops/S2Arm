// 真机探针用的 graphics/track 桩：nvn_dirty / 宿主钩子接线只需要登记与写入口这两个符号。
#include <stdint.h>
#include <stddef.h>
static void (*g_wprep)(uint64_t, uint64_t);
void s2a_track_set_write_prep(void (*fn)(uint64_t, uint64_t)) { g_wprep = fn; }
void s2a_track_write_quiet(uint64_t a, uint64_t n) { if (g_wprep) g_wprep(a, n); }

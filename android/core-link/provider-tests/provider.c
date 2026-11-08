// Authored loader fixture, not a native-core implementation. Only the calls
// exercised by AndroidSelfTest and the three optional exports are supplied.
#include "s2a_native.h"
#include <string.h>

#ifndef PROVIDER_VALUE
#define PROVIDER_VALUE 123456789u
#endif

static char last_mark[64];

int s2a_screen_w(void) { return 2400; }
int s2a_screen_h(void) { return 1440; }
void s2a_boot_mark(const char *stage) {
  strncpy(last_mark, stage, sizeof(last_mark) - 1);
}
const char *fixture_last_mark(void) { return last_mark; }

#ifndef NO_EXTRAS
uint64_t s2a_guest_tick(void) { return PROVIDER_VALUE; }
int64_t s2a_clock_unseen_ns(void) { return 0; }                    /* 接口 v2.14 补时（11-01：与其它可选导出同一查找口径） */
void s2a_clock_register_catchup(void (*cb)(void)) { (void)cb; }
#ifndef NO_DET_MODE
int s2a_det_mode(void) { return 0; }
#endif
#ifndef NO_DET_WRITE
void s2a_det_host_write(uint64_t address, const void *data, uint64_t size) {
  memcpy((void *)(uintptr_t)address, data, (size_t)size);
}
#endif
#endif

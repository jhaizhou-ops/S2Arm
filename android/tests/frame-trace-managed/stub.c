#include <stdint.h>
static int enabled, count;
static uint64_t last;
int s2a_frame_log_on(void) { return enabled; }
void s2a_frame_log_fence_wait(uint64_t ns) { count++; last = ns; }
void test_enabled(int value) { enabled = value; }
int test_count(void) { return count; }
uint64_t test_last(void) { return last; }

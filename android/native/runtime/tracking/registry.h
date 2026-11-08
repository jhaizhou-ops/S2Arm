// tracking 内部：真实 VM 事务与 GPU 跟踪使用同一个短临界区。
#pragma once
#include <stdint.h>
int s2a_track_registry_begin(uint64_t addr, uint64_t size, uint64_t source);
void s2a_track_registry_finish(int committed);

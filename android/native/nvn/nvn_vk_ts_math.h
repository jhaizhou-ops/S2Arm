// 时间戳位宽回绕的纯数学（不依赖 Vulkan）：validBits < 64 时，两个截断值的裸差会丢符号，
// 必须先在位宽内取模差，再从第 N-1 位做符号扩展。宿主单测直接包含。
#pragma once
#include <stdint.h>

static inline uint64_t s2a_ts_valid_mask(uint32_t bits) {
    return bits >= 64 ? ~0ull : ((1ull << bits) - 1);
}

static inline int64_t s2a_ts_wrap_diff(uint64_t now, uint64_t then, uint32_t bits) {
    uint64_t mask = s2a_ts_valid_mask(bits);
    uint64_t diff = (now - then) & mask;
    if (bits < 64 && (diff & (1ull << (bits - 1)))) return (int64_t)(diff | ~mask);
    return (int64_t)diff;
}

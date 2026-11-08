// Android 兼容层：hle_nvn.c 只用 mach_absolute_time/mach_timebase_info。
#pragma once
#include <stdint.h>
#include <time.h>
typedef struct { uint32_t numer, denom; } mach_timebase_info_data_t;
static inline uint64_t mach_absolute_time(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static inline uint64_t clock_gettime_nsec_np(clockid_t id) { struct timespec t; clock_gettime(id, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
static inline int mach_timebase_info(mach_timebase_info_data_t *info) {
    info->numer = 1; info->denom = 1; return 0;
}

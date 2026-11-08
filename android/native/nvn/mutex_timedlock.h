// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 按绝对截止时刻（CLOCK_REALTIME）拿 mutex，语义同 POSIX pthread_mutex_timedlock：
//   锁空闲 → 立即成功（截止时刻已过也成功）；到截止时刻仍拿不到 → ETIMEDOUT；其他错误码原样返回。
// Linux / Android 直接用 pthread_mutex_timedlock。macOS 没有这个函数（宿主单测会编生产 mtl_vk_adapter.c）：
//   trylock + 指数退避睡眠（50 µs 起翻倍、封顶 1 ms、不睡过截止时刻），等待线程不空转占 CPU；
//   代价是锁被释放后最多晚 1 ms 才拿到。S2A_PORTABLE_TIMEDLOCK 让 Linux 也编这条，供单测双平台核同一实现。
// 已知差异：错误检查型 mutex 被本线程持有时 POSIX 回 EDEADLK，这里 trylock 回 EBUSY 会等到超时；适配层用的是递归锁，不涉及。
#ifndef S2A_MUTEX_TIMEDLOCK_H
#define S2A_MUTEX_TIMEDLOCK_H
#include <errno.h>
#include <pthread.h>
#include <time.h>

#if defined(__APPLE__) || defined(S2A_PORTABLE_TIMEDLOCK)
static inline int s2a_mutex_timedlock(pthread_mutex_t *mu, const struct timespec *deadline) {
    long long pause_ns = 50000;
    for (;;) {
        int rc = pthread_mutex_trylock(mu);
        if (rc != EBUSY) return rc;
        struct timespec now;
        if (clock_gettime(CLOCK_REALTIME, &now)) return errno;
        long long left = (long long)(deadline->tv_sec - now.tv_sec) * 1000000000LL +
                         (long long)(deadline->tv_nsec - now.tv_nsec);
        if (left <= 0) return ETIMEDOUT;
        long long nap = pause_ns < left ? pause_ns : left;
        struct timespec ts = {(time_t)(nap / 1000000000LL), (long)(nap % 1000000000LL)};
        nanosleep(&ts, NULL);   // 被信号打断（EINTR）无妨：回到循环重新判锁与截止时刻
        if (pause_ns < 1000000) pause_ns *= 2;
    }
}
#else
static inline int s2a_mutex_timedlock(pthread_mutex_t *mu, const struct timespec *deadline) {
    return pthread_mutex_timedlock(mu, deadline);
}
#endif
#endif

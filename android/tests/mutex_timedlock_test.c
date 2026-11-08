// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// mutex_timedlock.h 单测：拿到锁 / 超时两种结局 + 不空转。期望值只由用例自己的时序推出，不读被测实现。
//   ① 锁空闲、截止时刻已过 → 0（POSIX：能立即拿到就不看截止时刻）
//   ② 别的线程一直持锁、截止 +100 ms → ETIMEDOUT；返回时刻不早于截止、不晚于截止 +200 ms；
//      等待线程 CPU 时间 < 20 ms（忙等会接近 100 ms）
//   ③ 别的线程持锁 50 ms 后释放、截止 +2 s → 0；拿到时刻在释放之后、远早于截止（< 1 s）
//   ④ 递归锁本线程已持有 → 0（适配层 g_mu 的用法）
#include "mutex_timedlock.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_locked;
static long long g_hold_ms;

static long long ns_of(const struct timespec *t) { return (long long)t->tv_sec * 1000000000LL + t->tv_nsec; }
static long long now_ns(clockid_t c) { struct timespec t; clock_gettime(c, &t); return ns_of(&t); }
static struct timespec after_ms(long long ms) {
    long long v = now_ns(CLOCK_REALTIME) + ms * 1000000LL;
    struct timespec t = {(time_t)(v / 1000000000LL), (long)(v % 1000000000LL)};
    return t;
}

static void *holder(void *arg) {
    (void)arg;
    assert(pthread_mutex_lock(&g_mu) == 0);
    g_locked = 1;
    struct timespec ts = {(time_t)(g_hold_ms / 1000), (long)(g_hold_ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
    assert(pthread_mutex_unlock(&g_mu) == 0);
    return NULL;
}

static pthread_t start_holder(long long hold_ms) {
    pthread_t t;
    g_locked = 0;
    g_hold_ms = hold_ms;
    assert(pthread_create(&t, NULL, holder, NULL) == 0);
    while (!g_locked) usleep(100);
    return t;
}

int main(void) {
    // ①
    struct timespec past = after_ms(-1000);
    assert(s2a_mutex_timedlock(&g_mu, &past) == 0);
    assert(pthread_mutex_unlock(&g_mu) == 0);
    printf("① 空闲锁 + 过期截止：rc=0\n");

    // ②
    pthread_t t = start_holder(400);
    struct timespec dl = after_ms(100);
    long long cpu0 = now_ns(CLOCK_THREAD_CPUTIME_ID);
    int rc = s2a_mutex_timedlock(&g_mu, &dl);
    long long cpu = now_ns(CLOCK_THREAD_CPUTIME_ID) - cpu0, late = now_ns(CLOCK_REALTIME) - ns_of(&dl);
    printf("② 他人持锁、截止 +100 ms：rc=%d（ETIMEDOUT=%d） 超过截止 %.2f ms 等待线程 CPU %.2f ms\n",
           rc, ETIMEDOUT, late / 1e6, cpu / 1e6);
    assert(rc == ETIMEDOUT);
    assert(late >= 0 && late < 200000000LL);
    assert(cpu < 20000000LL);
    pthread_join(t, NULL);

    // ③
    long long t0 = now_ns(CLOCK_REALTIME);
    t = start_holder(50);
    dl = after_ms(2000);
    rc = s2a_mutex_timedlock(&g_mu, &dl);
    long long waited = now_ns(CLOCK_REALTIME) - t0;
    printf("③ 他人持锁 50 ms 后释放、截止 +2 s：rc=%d 拿到用时 %.2f ms\n", rc, waited / 1e6);
    assert(rc == 0);
    assert(waited >= 50000000LL && waited < 1000000000LL);
    assert(pthread_mutex_unlock(&g_mu) == 0);
    pthread_join(t, NULL);

    // ④
    pthread_mutexattr_t a;
    pthread_mutex_t rmu;
    pthread_mutexattr_init(&a);
    pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&rmu, &a);
    assert(pthread_mutex_lock(&rmu) == 0);
    dl = after_ms(10);
    rc = s2a_mutex_timedlock(&rmu, &dl);
    printf("④ 递归锁本线程已持有：rc=%d\n", rc);
    assert(rc == 0);
    pthread_mutex_unlock(&rmu);
    pthread_mutex_unlock(&rmu);
    puts("mutex_timedlock 单测通过");
    return 0;
}

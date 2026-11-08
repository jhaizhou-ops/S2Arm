// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
/* Linux pthread/futex protocol fixture. Production function bodies are included
 * verbatim by run_pause_wait_linux.py. No guest ABI, VM census, fault handler,
 * virtual-core scheduler or Android/Bionic execution is claimed here. */
#define _GNU_SOURCE
#define S2A_UNIT_TEST
#include <errno.h>
#include <linux/futex.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#define R_TIMEOUT 0xEA01u
#define R_BAD_STATE 0xFA01u
typedef struct thr {
    pthread_t pt;
    pthread_cond_t cv;
    _Atomic int pause, paused_ack, held_core, in_svc;
    _Atomic unsigned vm_ack;
    int vm_wait_safe, pmach, exited, wkind, woke;
    int64_t wres;
    uint64_t trace_pause, wseq, wait_t0, nblk;
    unsigned trace_pause_conditions;
    struct thr *next;
} thr_t;
static pthread_mutex_t G = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pause_cv = PTHREAD_COND_INITIALIZER;
static _Atomic int g_frz;
static _Atomic unsigned android_vm_epoch;
static _Atomic(thr_t *) android_vm_owner;
static pthread_once_t android_wait_pause_once = PTHREAD_ONCE_INIT;
static int android_wait_pause_enabled;
static thr_t *g_wait;
static uint64_t g_wseq, g_pd_current;
static _Atomic int checks, failures, target_acks, deadlines, notifications;
static _Thread_local thr_t *self;
static _Thread_local int have_deadline;
static _Thread_local struct timespec first_deadline;
static void check(int ok, const char *name) {
    ++checks;
    if (!ok) { ++failures; fprintf(stderr, "FAIL %s\n", name); }
}
static uint64_t now_ns(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}
static uint64_t plat_now_ns(void) { return now_ns(); }
static uint64_t thread_clock(void) { return now_ns(); }
static void glock(void) { pthread_mutex_lock(&G); }
/* Accounting-only seam; does not emulate the real virtual-core scheduler. */
static void core_release(thr_t *t) { atomic_store(&t->held_core, 0); }
static void core_acquire(thr_t *t) { atomic_store(&t->held_core, 1); }
static int wait_diag_on(void) { return 0; }
static void pause_diag_locked(thr_t *t, int a, int b, uint32_t c, uint64_t d, unsigned e, int f) {
    (void)t; (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
}
static void pause_diag_boundary_locked(thr_t *t, int event) {
    (void)event;
    check(self == t && pthread_equal(t->pt, pthread_self()), "ack belongs to target thread");
    check(!atomic_load(&t->held_core), "pause releases accounting core");
    ++target_acks;
}
static void pause_diag_condition_locked(thr_t *t, int e) { (void)t; (void)e; }
static void wait_diag_condition_locked(thr_t *t, int e) { (void)t; (void)e; }
static void wait_diag_block_locked(thr_t *t, int k, int64_t n, const struct timespec *d) {
    (void)t; (void)k; (void)n; (void)d;
}
static int observed_signal(pthread_cond_t *cv) { ++notifications; return pthread_cond_signal(cv); }
static int observed_timedwait(pthread_cond_t *cv, pthread_mutex_t *mu, const struct timespec *d) {
    if (!have_deadline) { first_deadline = *d; have_deadline = 1; }
    check(d->tv_sec == first_deadline.tv_sec && d->tv_nsec == first_deadline.tv_nsec,
          "same operation preserves absolute deadline");
    ++deadlines;
    return pthread_cond_timedwait(cv, mu, d);
}
static void sleep_wait_boundary(thr_t *);
#define pthread_cond_signal observed_signal
#define pthread_cond_timedwait observed_timedwait
#include "production.inc"
#undef pthread_cond_signal
#undef pthread_cond_timedwait

struct job { thr_t thread; _Atomic int done, ready; int sleep, masked; int64_t ns, result; uint64_t elapsed; };
static void interrupt_wait(int signal) { (void)signal; } /* real kernel EINTR, no synthetic ack */
static void *worker(void *arg) {
    struct job *j = arg; self = &j->thread; self->pt = pthread_self();
    if (j->masked) { sigset_t mask; sigemptyset(&mask); sigaddset(&mask, SIGURG); pthread_sigmask(SIG_BLOCK, &mask, NULL); }
    atomic_store(&self->in_svc, 1);
    uint64_t start = now_ns();
    if (j->sleep) { atomic_store(&j->ready, 1); sleep_ontime_until(j->ns, self); }
    else { glock(); atomic_store(&j->ready, 1); j->result = block(self, 4, j->ns); pthread_mutex_unlock(&G); }
    j->elapsed = now_ns() - start; atomic_store(&j->done, 1); return NULL;
}
static int await_state(struct job *j, int which, int want) {
    uint64_t end = now_ns() + 1000000000ull;
    do {
        glock();
        int value = which == 0 ? j->thread.vm_wait_safe : which == 1 ? (int)atomic_load(&j->thread.vm_ack)
                  : which == 2 ? atomic_load(&j->thread.paused_ack)
                  : which == 4 ? (atomic_load(&j->thread.vm_ack) == 17 && !atomic_load(&j->thread.paused_ack))
                  : atomic_load(&j->done);
        pthread_mutex_unlock(&G);
        if (value == want) return 1;
        usleep(100);
    } while (now_ns() < end);
    return 0;
}
static pthread_t start(struct job *j) {
    pthread_t p; pthread_cond_init(&j->thread.cv, NULL);
    check(!pthread_create(&p, NULL, worker, j), "worker starts");
    uint64_t end = now_ns() + 1000000000ull;
    while (!atomic_load(&j->ready) && now_ns() < end) usleep(100);
    check(atomic_load(&j->ready), "worker ready");
    if (!j->sleep) check(await_state(j, 0, 1), "real condition wait reached");
    else usleep(5000);
    return p;
}
static void produce(struct job *j) {
    glock(); wait_unlink(&j->thread); j->thread.wkind = 0;
    j->thread.wres = 0xEC01; j->thread.woke = 1;
    pthread_cond_signal(&j->thread.cv); pthread_mutex_unlock(&G);
}
static void vm_begin(void) { atomic_store(&android_vm_owner, NULL); atomic_store(&android_vm_epoch, 17); }
static void vm_end(void) {
    atomic_store(&android_vm_epoch, 0);
    syscall(SYS_futex, &android_vm_epoch, FUTEX_WAKE_PRIVATE, 0x7fffffff, NULL, NULL, 0);
}
static int pause_target(struct job *j) {
    uint64_t start = now_ns(); uint32_t result = thr_pause(&j->thread);
    printf("pause result=%#x elapsed_ns=%llu\n", result, (unsigned long long)(now_ns() - start));
    check(!result && atomic_load(&j->thread.paused_ack), "target acknowledges pause within original 2s");
    return !result;
}
static void resume_target(struct job *j) { check(!thr_unpause(&j->thread), "resume succeeds"); }
int main(int argc, char **argv) {
    alarm(15);
    struct sigaction sa = {0}; sa.sa_handler = interrupt_wait; sigemptyset(&sa.sa_mask);
    check(!sigaction(SIGURG, &sa, NULL), "signal install");
    const char *mode = argc > 1 ? argv[1] : "basic";
    int sleeping = !strncmp(mode, "sleep-", 6);
    int vm_first = strstr(mode, "vm-first") != NULL, pause_first = strstr(mode, "pause-first") != NULL;
    int timed = strstr(mode, "deadline") != NULL, expired = strstr(mode, "expired") != NULL;
    struct job j = {.sleep = sleeping, .masked = strstr(mode, "masked") != NULL,
                    .ns = sleeping || timed || expired ? 400000000 : -1};
    pthread_t p = start(&j);
    if (vm_first) {
        vm_begin();
        if (sleeping) pthread_kill(p, SIGURG); else produce(&j);
        check(await_state(&j, 1, 17), "target reaches actual futex return barrier");
    }
    if (!pause_target(&j)) return 1;
    if (pause_first) vm_begin();
    if (!sleeping && !timed && !expired && !vm_first) produce(&j);
    usleep(10000); check(!atomic_load(&j.done), "producer cannot release paused target");
    if (vm_first || pause_first) {
        for (int i = 0; i < 3; ++i) {
            resume_target(&j);
            /* pause_park legitimately retains its old ack across its internal
             * g_pause_cv barrier. The CV helper must instead clear it. */
            check(await_state(&j, sleeping ? 1 : 4, sleeping ? 17 : 1), "resumed target remains in VM epoch");
            if (!pause_target(&j)) return 1;
            check(!atomic_load(&j.done), "repeated pause never escapes VM epoch");
        }
        vm_end();
    }
    if (expired) usleep(450000); else if (timed) usleep(100000);
    uint64_t resumed = now_ns();
    resume_target(&j);
    if (timed && !sleeping) {
        for (int i = 0; i < 4; ++i) { usleep(10000); glock(); pthread_cond_signal(&j.thread.cv); pthread_mutex_unlock(&G); }
    }
    check(!pthread_join(p, NULL), "worker joins");
    if (!sleeping) check(j.result == (timed || expired ? R_TIMEOUT : 0xEC01), "original Result preserved");
    if (sleeping || timed || expired) {
        check(j.elapsed >= 380000000, "original duration not shortened");
        if (expired) check(now_ns() - resumed < 100000000, "expired deadline not restarted on resume");
        if (timed && !sleeping) check(atomic_load(&deadlines) >= 4, "same operation actually retries deadline");
    }
    if (!sleeping && !vm_first) check(atomic_load(&notifications) > 0, "pause sends real condition notification");
    check(atomic_load(&target_acks) > 0, "target boundary actually executed");
    printf("%s Linux host protocol mode=%s checks=%d failures=%d elapsed_ns=%llu\n",
           failures ? "FAIL" : "PASS", mode, checks, failures, (unsigned long long)j.elapsed);
    return failures ? 1 : 0;
}

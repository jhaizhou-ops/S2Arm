/* T70: CPU publication contract, not GPU completion or NVN lifecycle API coverage. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>

#ifdef SYNC_CONTRACT_OLD_ORDER
static void old_order_pause(void);
#endif
#include "nvn_obj.h"

/* 布局合同是 magic / fenced / fence 在 0 / 4 / 8（安卓 vk_record.c 按偏移直写游戏内存里的 NVNsync）；之后可以追加字段
   （11-01 加 ext_ev / ext_val：来自 GL 队列的栅栏），总大小不超过游戏为 NVNsync 预留的空间 */
_Static_assert(sizeof(sync_t) <= sizeof(NVNsync), "sync ABI size");
_Static_assert(offsetof(sync_t, magic) == 0, "sync ABI magic offset");
_Static_assert(offsetof(sync_t, fenced) == 4, "sync ABI fenced offset");
_Static_assert(_Alignof(sync_t) == 8, "sync ABI alignment");
_Static_assert(offsetof(sync_t, fence) == 8, "sync ABI fence offset");
#define CHECK(c, text) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", text); exit(1); } } while (0)
#define PT(call) CHECK((call) == 0, #call)

#ifndef SYNC_CONTRACT_OLD_ORDER
static const uint64_t values[] = {0, UINT64_MAX, 7, 7, 1, UINT64_C(0x1234567887654321)};
/* POSIX barriers are optional (absent on Darwin). Keep all four workers in
   the same test on every host, with a predicate loop for spurious wakeups. */
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    unsigned arrived, generation;
} start_gate;
static void gate_wait(start_gate *gate) {
    PT(pthread_mutex_lock(&gate->mutex));
    unsigned generation = gate->generation;
    if (++gate->arrived == 4) {
        gate->arrived = 0;
        ++gate->generation;
        PT(pthread_cond_broadcast(&gate->cond));
    } else {
        while (generation == gate->generation)
            PT(pthread_cond_wait(&gate->cond, &gate->mutex));
    }
    PT(pthread_mutex_unlock(&gate->mutex));
}
typedef struct { sync_t s; start_gate start; atomic_int bad; } shared;
typedef struct { shared *sh; unsigned writer; } arg;

static void *publish(void *p) {
    arg *a = p;
    gate_wait(&a->sh->start);
    for (unsigned i = 0; i < 20000; ++i)
        sync_publish(&a->sh->s, values[(i + a->writer) % 6]);
    return NULL;
}
static void *observe(void *p) {
    shared *sh = p;
    gate_wait(&sh->start);
    for (unsigned i = 0; i < 30000; ++i) {
        uint64_t f = 55;
        if (!sync_published(&sh->s, &f)) {
            if (f != 55) atomic_store(&sh->bad, 1);
            continue;
        }
        int found = 0;
        for (unsigned j = 0; j < 6; ++j) found |= f == values[j];
        if (!found) atomic_store(&sh->bad, 1);
    }
    return NULL;
}
#endif
#ifdef SYNC_CONTRACT_OLD_ORDER
/* Deliberately expose the historical flag-before-payload ordering, using atomic
   accesses and a handshake so the negative control itself has no data race. */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int paused, resume_writer;
static sync_t old_s;
static void old_order_pause(void) {
    PT(pthread_mutex_lock(&lock)); paused = 1; PT(pthread_cond_broadcast(&cv));
    while (!resume_writer) PT(pthread_cond_wait(&cv, &lock));
    PT(pthread_mutex_unlock(&lock));
}
static void *old_writer(void *unused) { (void)unused; sync_publish(&old_s, 42); return NULL; }
#endif
int main(void) {
#ifdef SYNC_CONTRACT_OLD_ORDER
    pthread_t writer; PT(pthread_create(&writer, NULL, old_writer, NULL));
    PT(pthread_mutex_lock(&lock));
    while (!paused) PT(pthread_cond_wait(&cv, &lock));
    uint64_t f = 99; int published = sync_published(&old_s, &f);
    resume_writer = 1; PT(pthread_cond_broadcast(&cv)); PT(pthread_mutex_unlock(&lock));
    PT(pthread_join(writer, NULL));
    CHECK(!published || f == 42, "first publication must not expose unwritten zero");
#else
    sync_t s = {0}; uint64_t f = 55;
    CHECK(!sync_published(&s, &f) && f == 55, "unpublished preserves output");
    CHECK(!sync_published(&s, NULL), "unpublished flag query");
    for (unsigned i = 0; i < 6; ++i) {
        sync_publish(&s, values[i]);
        CHECK(sync_published(&s, &f) && f == values[i], "serialized publication including zero and decreasing values");
        CHECK(sync_published(&s, NULL), "published flag query");
    }
    /* New object lifetimes only after every reader/writer has joined. This is
       fixture storage initialization, not a call to nvnSyncInitialize/Finalize. */
    for (unsigned epoch = 0; epoch < 12; ++epoch) {
        shared sh = {0}; atomic_init(&sh.bad, 0);
        PT(pthread_mutex_init(&sh.start.mutex, NULL));
        PT(pthread_cond_init(&sh.start.cond, NULL));
        pthread_t threads[4]; arg args[2] = {{&sh, 0}, {&sh, 1}};
        for (unsigned i = 0; i < 2; ++i) PT(pthread_create(&threads[i], NULL, publish, &args[i]));
        for (unsigned i = 2; i < 4; ++i) PT(pthread_create(&threads[i], NULL, observe, &sh));
        for (unsigned i = 0; i < 4; ++i) PT(pthread_join(threads[i], NULL));
        CHECK(!atomic_load(&sh.bad), "concurrent observations belong to publisher value set");
        sync_publish(&sh.s, 0); f = 55;
        CHECK(sync_published(&sh.s, &f) && f == 0, "post-join zero publication supersedes all writers");
        PT(pthread_cond_destroy(&sh.start.cond));
        PT(pthread_mutex_destroy(&sh.start.mutex));
    }
    puts("PASS: serial zero/repeat/nonmonotonic; 12 joined lifetimes; two publishers/two readers; ABI");
#endif
    return 0;
}

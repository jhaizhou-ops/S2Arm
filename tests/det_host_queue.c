// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Compile the actual producer/drain, intercepting only atomic scheduling points.
#define _GNU_SOURCE
#include "../runtime/src/native.h"
#include "../platform/plat.h"
#include <pthread.h>
#include <stdatomic.h>
#include <signal.h>

static void after_load(const volatile void *p);
static void after_exchange(const volatile void *p, uint64_t value);
#undef atomic_load
#define atomic_load(p) __extension__ ({ __auto_type q_ = (p); \
    __auto_type v_ = atomic_load_explicit(q_, memory_order_seq_cst); after_load(q_); v_; })
#undef atomic_exchange
#define atomic_exchange(p, value) __extension__ ({ __auto_type q_ = (p); \
    __auto_type v_ = atomic_exchange_explicit(q_, (value), memory_order_seq_cst); \
    after_exchange(q_, (uint64_t)v_); v_; })
#include "../runtime/src/det.c"
#undef atomic_load
#define atomic_load(p) atomic_load_explicit((p), memory_order_seq_cst)
#undef atomic_exchange
#define atomic_exchange(p, v) atomic_exchange_explicit((p), (v), memory_order_seq_cst)

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int full_read, resume_full, drain_paused, resume_drain, locked;
static int concurrent_fill;
static _Thread_local int pause_full;
static _Atomic int producers_done;
static uint32_t seen[HQ + 4];
static int ops[HQ + 4], count;

static void require(int ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL det_host_queue: %s\n", what); exit(1); }
}
static void wait_for(int *flag) {
    pthread_mutex_lock(&mu);
    while (!*flag) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
}
static void release_flag(int *flag) {
    pthread_mutex_lock(&mu); *flag = 1; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu);
}
static void after_load(const volatile void *p) {
    if (p != &g_hq_r || !pause_full) return;
    pause_full = 0;
    release_flag(&full_read);
    wait_for(&resume_full);
}
static void after_exchange(const volatile void *p, uint64_t value) {
    // Once both producers returned, no outstanding writer can fill an empty slot.
    for (unsigned i = 0; i < HQ; i++) {
        if (p == &g_hq[i]) {
            if (!value && atomic_load(&producers_done)) {
                fprintf(stderr, "FAIL det_host_queue: hq_drain empty slot with no writer; r=%u w=%u applied=%d expected=%d\n",
                        atomic_load(&g_hq_r), atomic_load(&g_hq_w), count, HQ + 1);
                exit(1);
            }
            return;
        }
    }
}
void s2a_det_apply_host(uint32_t id, int op) {
    require(count < HQ + 4, "too many events");
    seen[count] = id; ops[count++] = op;
    if (!concurrent_fill && count == 3) { release_flag(&drain_paused); wait_for(&resume_drain); }
}
static void *drainer(void *unused) {
    (void)unused;
    det_mutex_lock(&g_gl);
    release_flag(&locked);
    wait_for(&full_read);
    hq_drain();
    det_mutex_unlock(&g_gl);
    return NULL;
}
static void *overflow(void *result) {
    pause_full = 1;
    *(int *)result = s2a_det_host_event(HQ + 1, 0);
    return NULL;
}
static void test_watchdog(int sig) {
    (void)sig;
    const char msg[] = "FAIL det_host_queue: scheduling watchdog expired\n";
    write(STDERR_FILENO, msg, sizeof msg - 1); _exit(1);
}
enum { PRODUCERS = 8, PER_PRODUCER = HQ / PRODUCERS };
static void *fill_worker(void *arg) {
    uint32_t first = (uint32_t)(uintptr_t)arg * PER_PRODUCER + 1;
    for (uint32_t i = first; i < first + PER_PRODUCER; i++)
        require(s2a_det_host_event(i, i & 1) == 1, "concurrent fill accepts every event");
    return NULL;
}
static void check_concurrent_fill(void) {
    pthread_t workers[PRODUCERS];
    concurrent_fill = 1;
    det_mutex_lock(&g_gl);
    for (uintptr_t i = 0; i < PRODUCERS; i++)
        require(!pthread_create(&workers[i], NULL, fill_worker, (void *)i), "start fill producer");
    for (int i = 0; i < PRODUCERS; i++) require(!pthread_join(workers[i], NULL), "join fill producer");
    require(s2a_det_host_event(HQ + 1, 0) == 0, "full concurrent queue rejects overflow");
    require(atomic_load(&g_hq_drop) == 1, "overflow counted once");
    atomic_store(&producers_done, 1);
    hq_drain();
    det_mutex_unlock(&g_gl);
    require(count == HQ && g_rn == HQ, "4096 concurrent events and records");
    uint32_t next[PRODUCERS];
    for (uint32_t i = 0; i < PRODUCERS; i++) next[i] = i * PER_PRODUCER + 1;
    for (int i = 0; i < HQ; i++) {
        uint32_t id = seen[i];
        require(id >= 1 && id <= HQ, "concurrent ID range");
        require(id == next[(id - 1) / PER_PRODUCER]++, "per-producer FIFO, no duplicate or missing ID");
        require(ops[i] == (int)(id & 1) && g_rb[i].type == E_HOST &&
                g_rb[i].ord == HOST_ORD && g_rb[i].a == id && g_rb[i].v == (id & 1), "concurrent record and operation");
    }
    for (unsigned i = 0; i < HQ; i++) require(!atomic_load(&g_hq[i]), "concurrent slots reclaimed");
    require(atomic_load(&g_hq_r) == atomic_load(&g_hq_w), "concurrent queue empty");
    puts("PASS det_host_queue: 8 producers, 4096 unique FIFO events/records, 1 rejection");
}
int main(int argc, char **argv) {
    signal(SIGALRM, test_watchdog); alarm(15);
    g_det = 2; atomic_store(&g_started, 1);
    g_rb = calloc(RBUF, sizeof *g_rb); require(g_rb != NULL, "record buffer");
    if (argc > 1 && !strcmp(argv[1], "fill")) {
        check_concurrent_fill(); free(g_rb); alarm(0); return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "wrap")) {
        atomic_store(&g_hq_w, UINT32_MAX - HQ / 2);
        atomic_store(&g_hq_r, UINT32_MAX - HQ / 2);
    }
    pthread_t drain, a; int rejected = -1;
    require(!pthread_create(&drain, NULL, drainer, NULL), "start drainer");
    wait_for(&locked);
    // Original fixture: IDs 1..4096, alternating clear/signal, all queued.
    for (uint32_t i = 1; i <= HQ; i++) require(s2a_det_host_event(i, i & 1) == 1, "fill queue");
    require(!pthread_create(&a, NULL, overflow, &rejected), "start full producer A");
    wait_for(&full_read);
    wait_for(&drain_paused); // two slots reclaimed; A still holds its full snapshot
    require(s2a_det_host_event(HQ + 2, 1) == 1, "producer B uses reclaimed capacity");
    release_flag(&resume_full);
    require(!pthread_join(a, NULL), "join A");
    require(rejected == 0 && atomic_load(&g_hq_drop) == 1, "full A rejected exactly once");
    atomic_store(&producers_done, 1);
    release_flag(&resume_drain);
    require(!pthread_join(drain, NULL), "drain completes");
    require(count == HQ + 1 && g_rn == HQ + 1, "exact applied/recorded count");
    for (int i = 0; i <= HQ; i++) {
        uint32_t id = i < HQ ? (uint32_t)i + 1 : HQ + 2;
        int op = i < HQ ? (int)(id & 1) : 1;
        require(seen[i] == id && ops[i] == op, "FIFO IDs and operations");
        require(g_rb[i].type == E_HOST && g_rb[i].ord == HOST_ORD &&
                g_rb[i].a == id && g_rb[i].v == (uint64_t)op, "record FIFO and payload");
    }
    require(atomic_load(&g_hq_r) == atomic_load(&g_hq_w), "queue empty after drain");
    for (unsigned i = 0; i < HQ; i++) require(!atomic_load(&g_hq[i]), "all slots reclaimed");
    free(g_rb); alarm(0);
    puts("PASS det_host_queue: 4097 ordered events/records, 1 rejection, no orphan slot");
    return 0;
}

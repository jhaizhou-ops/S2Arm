// Exact production source + real host tracking and libmalloc notifications.
// Only read internal slot pointers/capacity; never replace an allocator or hook.
#ifndef NVN_DIRTY_GROWTH_SOURCE
#define NVN_DIRTY_GROWTH_SOURCE "../gfx/nvn/nvn_dirty.c"
#endif
#include NVN_DIRTY_GROWTH_SOURCE
#include <dlfcn.h>
#include <malloc/malloc.h>

void s2a_crash_install(void);
void s2a_crash_thread_init(void);
typedef void (*malloc_log_fn)(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);
static malloc_log_fn saved_logger;
enum { GROWTH_OBS_MAX = 4096, STEPS = 512, JUMP = 4096 };
static struct { _Atomic uintptr_t ptr; _Atomic unsigned frees; } observed[GROWTH_OBS_MAX];
static _Atomic unsigned observed_n;
static unsigned checks, failures;
#define CK(c, msg) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL %s\n", msg); } } while (0)
static void allocation_event(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t result, uint32_t skip) {
    // Same notification ABI as runtime/src/msample.c. No allocation, locks,
    // printing, stack unwinding, or TLS access from this observer.
    if ((type & 4) && (!(type & 2) || a2 != result)) {
        unsigned n = atomic_load_explicit(&observed_n, memory_order_acquire);
        for (unsigned i = 0; i < n; i++)
            if (atomic_load_explicit(&observed[i].ptr, memory_order_relaxed) == a2)
                atomic_fetch_add_explicit(&observed[i].frees, 1, memory_order_relaxed);
    }
    if (saved_logger) saved_logger(type, a1, a2, a3, result, skip);
}
static size_t note_pointer(void *p, size_t requested, size_t *allocator_bytes) {
    unsigned n = atomic_load(&observed_n);
    for (unsigned i = 0; i < n; i++) if (atomic_load(&observed[i].ptr) == (uintptr_t)p) return 0;
    if (!p || n == GROWTH_OBS_MAX) { fprintf(stderr, "invalid observation capacity\n"); exit(2); }
    size_t bytes = malloc_size(p);
    CK(bytes >= requested, "actual malloc block covers the requested array");
    *allocator_bytes += bytes;
    atomic_store(&observed[n].frees, 0);
    atomic_store(&observed[n].ptr, (uintptr_t)p);
    atomic_store_explicit(&observed_n, n + 1, memory_order_release);
    return requested;
}
static size_t note_slot(range_t *r, size_t *allocator_bytes) {
    return note_pointer((void *)r->state, r->cap * sizeof *r->state, allocator_bytes)
         + note_pointer((void *)r->gen, r->cap * sizeof *r->gen, allocator_bytes);
}
static unsigned char *map_pages(size_t n) {
    void *p = mmap(NULL, n * (size_t)getpagesize(), PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(2); }
    return p;
}
static int kernel_copy(unsigned char *p) {
    int fd[2]; if (pipe(fd)) { perror("pipe"); exit(2); }
    unsigned char v = 0x5a;
    if (write(fd[1], &v, 1) != 1) { perror("pipe write"); exit(2); }
    ssize_t n = read(fd[0], p, 1); close(fd[0]); close(fd[1]);
    return n == 1 && *p == v;
}
static void host_write(unsigned char *p) {
    uint64_t stamp = nvn_dirty_now();
    nvn_dirty_protect(p, 1);
    dm_guest_write_prepare(p, 1);
    CK(kernel_copy(p), "real host-track-NVN preparation permits a kernel write");
    CK(nvn_dirty_now() > stamp, "host write advances the protected page generation");
}
static _Atomic int signal_run, signal_ready;
static _Atomic unsigned signal_writes;
static unsigned char *signal_page;
static void *fault_writer(void *unused) {
    (void)unused;
    s2a_crash_thread_init();
    while (atomic_load(&signal_run)) {
        nvn_dirty_protect(signal_page, 1);
        *(volatile unsigned char *)signal_page = 0x33; // real fault, production on_crash -> NVN hook
        atomic_fetch_add(&signal_writes, 1);
        atomic_store(&signal_ready, 1);
    }
    return NULL;
}
// After each array replacement, wait until the writer has faulted once more (10-30, train line: growth takes a few ms; on a busy machine the writer could get no
//   slice in the whole window, writes_during_growth = 0, 13% red under 54 parallel runs). Concurrent faults during growth are now made by the test, not left to the scheduler.
static unsigned swaps, swap_waits_timed_out;
static void fault_after_swap(void) {
    unsigned w = atomic_load(&signal_writes); struct timespec t0, t; clock_gettime(CLOCK_MONOTONIC, &t0);
    while (atomic_load(&signal_writes) == w) {
        clock_gettime(CLOCK_MONOTONIC, &t);
        if (t.tv_sec - t0.tv_sec > 5) { swap_waits_timed_out++; return; }   // the writer is stuck: a failed check, not a hung test
        sched_yield();
    }
    swaps++;
}
static void session(unsigned number) {
    size_t pg = (size_t)getpagesize(), actual_bytes = 0, requested = 0;
    unsigned char *m = map_pages(JUMP + 1), *shared = map_pages(3);
    signal_page = map_pages(1);
    nvn_dirty_add_range(signal_page, pg);
    range_t *anchor = find_span((uintptr_t)signal_page, pg);
    if (!anchor) exit(2);
    note_slot(anchor, &actual_bytes);
    size_t anchor_actual = actual_bytes;
    uint64_t faults0, preps0; nvn_dirty_stats(&faults0, &preps0);
    atomic_store(&signal_run, 1); atomic_store(&signal_ready, 0); atomic_store(&signal_writes, 0);
    pthread_t th; if (pthread_create(&th, NULL, fault_writer, NULL)) exit(2);
    while (!atomic_load(&signal_ready)) sched_yield();
    unsigned writes_before_growth = atomic_load(&signal_writes);
    range_t *slot = NULL; _Atomic uint8_t *prev_state = NULL; swaps = swap_waits_timed_out = 0;
    for (size_t np = 1; np <= STEPS; np++) {
        nvn_dirty_add_range(m, np * pg);
        range_t *r = find_span((uintptr_t)m, np * pg);
        if (!r) exit(2);
        if (!slot) slot = r;
        if (r->state != prev_state) { prev_state = r->state; fault_after_swap(); }
        CK(r == slot, "increasing pool sizes reuse the same real range slot");
        CK(r->cap >= np && r->cap < 2 * np, "capacity covers pages with less than twofold slack");
        requested += note_slot(r, &actual_bytes);
        host_write(m + (np - 1) * pg);
        CK(!nvn_dirty_tracked(m + np * pg, 1), "capacity slack is outside the logical tracked range");
        nvn_dirty_protect(m + np * pg, 1);
        CK(kernel_copy(m + np * pg), "capacity slack is not write-protected");
        nvn_dirty_remove_range(m);
    }
    printf("dirty growth session %u: gradual requested=%zu malloc_size_sum=%zu final_cap=%zu\n",
           number, requested, actual_bytes - anchor_actual, slot->cap);
    CK(requested < 36 * (size_t)STEPS, "gradual growth has a linear requested-byte bound");
    nvn_dirty_add_range(m, JUMP * pg);
    requested += note_slot(slot, &actual_bytes);
    if (slot->state != prev_state) { prev_state = slot->state; fault_after_swap(); }
    CK(slot->cap >= JUMP && slot->cap < 2 * (size_t)JUMP, "large jump retains the capacity bound");
    host_write(m + (JUMP - 1) * pg);
    _Atomic uint8_t *state = slot->state; _Atomic uint64_t *gen = slot->gen;
    nvn_dirty_remove_range(m); nvn_dirty_add_range(m, JUMP * pg);
    CK(slot->state == state && slot->gen == gen, "same-sized reuse allocates no replacement arrays");
    nvn_dirty_remove_range(m); nvn_dirty_add_range(m, 3 * pg);
    CK(slot->state == state && slot->gen == gen, "smaller reuse retains existing arrays");
    host_write(m + 2 * pg);
    CK(!nvn_dirty_tracked(m + 3 * pg, 1), "shrinking a pool does not expose capacity slack");

    nvn_dirty_add_range(shared, pg / 2);
    nvn_dirty_add_range(shared + pg / 2, pg);
    range_t *left = find_span((uintptr_t)shared, 1), *right = find_span((uintptr_t)(shared + pg / 2), pg);
    if (!left || !right) exit(2);
    note_slot(left, &actual_bytes); note_slot(right, &actual_bytes);
    nvn_dirty_protect(shared, 1); nvn_dirty_protect(shared + pg / 2, pg);
    uint64_t stamp = nvn_dirty_now(); dm_guest_write_prepare(shared, 1);
    CK(kernel_copy(shared), "shared physical page accepts the real prepared host write");
    CK(nvn_dirty_since_span(left, shared, 1, stamp), "first shared range receives a generation");
    CK(nvn_dirty_since_span(right, shared + pg / 2, pg, stamp), "second shared range receives a generation");
    unsigned writes_during_growth = atomic_load(&signal_writes) - writes_before_growth;
    atomic_store(&signal_run, 0); pthread_join(th, NULL);
    uint64_t faults, preps; nvn_dirty_stats(&faults, &preps);
    CK(faults > faults0 && writes_during_growth > 0, "real production signal faults ran during slot growth");
    CK(swaps > 0 && !swap_waits_timed_out, "a real signal fault followed every array replacement");
    CK(preps > preps0, "real host pre-write unprotects were counted");
    unsigned count = atomic_load(&observed_n), early = 0;
    for (unsigned i = 0; i < count; i++) early += atomic_load(&observed[i].frees) != 0;
    CK(!early, "old and current arrays stay allocated until all signal writers are joined");
    nvn_dirty_remove_range(m); nvn_dirty_remove_range(shared); nvn_dirty_remove_range(shared + pg / 2);
    nvn_dirty_remove_range(signal_page);
    // This guest-free fixture has joined its sole fault writer before reset.
    nvn_dirty_reset_session();
    unsigned freed = 0;
    for (unsigned i = 0; i < count; i++) freed += atomic_load(&observed[i].frees) == 1;
    CK(freed == count, "drained reset really frees every observed current and retired array once");
    CK(atomic_load(&g_nr) == 0, "reset empties the actual range table");
    printf("dirty growth session %u: all requested=%zu array_malloc_size_sum=%zu frees=%u/%u faults=%llu preps=%llu concurrent_fault_writes=%u\n",
           number, requested, actual_bytes, freed, count,
           (unsigned long long)(faults - faults0), (unsigned long long)(preps - preps0), writes_during_growth);
    atomic_store_explicit(&observed_n, 0, memory_order_release);
    munmap(m, (JUMP + 1) * pg); munmap(shared, 3 * pg); munmap(signal_page, pg);
}
int main(void) {
    if (setenv("S2A_GFX", "direct", 1)) return 2;
    s2a_crash_install();
    malloc_log_fn *logger = (malloc_log_fn *)dlsym(RTLD_DEFAULT, "malloc_logger");
    if (!logger) { fprintf(stderr, "malloc_logger unavailable\n"); return 2; }
    saved_logger = *logger; *logger = allocation_event;
    session(1); session(2);
    *logger = saved_logger;
    printf("%s t_dirty_growth: %u checks, %u failures (real host, signal faults, mmap/mprotect and malloc notifications)\n",
           failures ? "✗" : "✓", checks, failures);
    return failures != 0;
}

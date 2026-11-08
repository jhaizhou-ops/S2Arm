// Real host writes must still reach newly tracked/protected pages after a miss.
#include "../gfx/nvn/nvn_dirty.h"
#include "../host/dm.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

void nvn_dirty_reset_session(void);
static int failed, checks;
#define CK(c, text) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL %s\n", text); } } while (0)

static unsigned char *map(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(2); }
    return p;
}
// A kernel copy into a read-only page returns EFAULT rather than running our
// signal hook. A successful copy after host-track-NVN preparation proves access.
static int kernel_write(unsigned char *p) {
    int fd[2]; if (pipe(fd)) { perror("pipe"); exit(2); }
    unsigned char v = 0x5a;
    if (write(fd[1], &v, 1) != 1) { perror("pipe write"); exit(2); }
    ssize_t n = read(fd[0], p, 1);
    close(fd[0]); close(fd[1]);
    return n == 1 && *p == v;
}
static void prepare_and_check(unsigned char *query, size_t len, unsigned char *dst, const char *name) {
    uint64_t before = nvn_dirty_now();
    dm_guest_write_prepare(query, len);
    CK(kernel_write(dst), name);
    CK(nvn_dirty_now() > before, "protected page received a write generation");
}

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int phase;
static unsigned char *thread_page;
static size_t page_size;
static void wait_phase(int want) {
    pthread_mutex_lock(&mu);
    while (phase != want) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
}
static void publish_phase(int next) {
    pthread_mutex_lock(&mu); phase = next; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu);
}
static void *reader(void *unused) {
    (void)unused;
    for (int i = 0; i < 1000; i++) {
        wait_phase(0);
        dm_guest_write_prepare(thread_page + 8, 1); dm_guest_write_prepare(thread_page + 8, 1);
        publish_phase(1);
        wait_phase(2);
        prepare_and_check(thread_page + 8, 1, thread_page + 8, "another thread published the previously absent range");
        publish_phase(3);
    }
    return NULL;
}
static uint64_t ns(clockid_t clock) {
    struct timespec t; if (clock_gettime(clock, &t)) abort();
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static int benchmark(void) {
    const size_t ranges = 3000, iterations = 100000;
    unsigned char *registered = map(ranges * page_size), *other = map(page_size);
    for (size_t i = 0; i < ranges; i++) nvn_dirty_add_range(registered + i * page_size, page_size);
    for (unsigned i = 0; i < 8; i++) dm_guest_write_prepare(other + i * 4, 4);
    uint64_t c = ns(CLOCK_THREAD_CPUTIME_ID), w = ns(CLOCK_MONOTONIC);
    for (size_t i = 0; i < iterations; i++) dm_guest_write_prepare(other + (i & 7) * 4, 4);
    w = ns(CLOCK_MONOTONIC) - w; c = ns(CLOCK_THREAD_CPUTIME_ID) - c;
    printf("prewrite benchmark: ranges=%zu queries=%zu thread_cpu_ns=%llu wall_ns=%llu\n",
           ranges, iterations, (unsigned long long)c, (unsigned long long)w);
    nvn_dirty_reset_session(); munmap(registered, ranges * page_size); munmap(other, page_size);
    return 0;
}
int main(int argc, char **argv) {
    if (setenv("S2A_GFX", "direct", 1)) { perror("setenv"); return 2; }
    page_size = (size_t)getpagesize();
    if (argc == 2 && !strcmp(argv[1], "--bench")) return benchmark();
    int same_session = argc == 2 && !strcmp(argv[1], "--same-session");
    unsigned char *m = map(8 * page_size), *initial = map(page_size);
    nvn_dirty_add_range(initial, page_size);
    CK(nvn_dirty_tracked(initial, page_size), "initial real memory range registered");
    dm_guest_write_prepare(m + 4, 1); dm_guest_write_prepare(m + 4, 1);
    nvn_dirty_add_range(m, page_size); nvn_dirty_protect(m, page_size);
    prepare_and_check(m + 4, 1, m + 4, "negative query invalidated by add at same address");

    dm_guest_write_prepare(m + 4, 1); // overlap exists, but its page is already writable
    nvn_dirty_protect(m, page_size);
    prepare_and_check(m + 4, 1, m + 4, "writable overlap must not become a cached miss");

    nvn_dirty_remove_range(m);
    dm_guest_write_prepare(m + 4, 1); dm_guest_write_prepare(m + 4, 1);
    nvn_dirty_add_range(m, page_size); nvn_dirty_protect(m, page_size);
    prepare_and_check(m + 4, 1, m + 4, "remove and same-slot/address reuse invalidate negative query");

    unsigned char *p = m + 3 * page_size;
    nvn_dirty_add_range(p, page_size);
    dm_guest_write_prepare(p - 1, 1); dm_guest_write_prepare(p - 1, 1);
    nvn_dirty_protect(p, page_size);
    prepare_and_check(p - 1, 65, p, "different length crossing into a live range is not a hit");
    dm_guest_write_prepare(p - 2, 1); dm_guest_write_prepare(p - 2, 1);
    nvn_dirty_protect(p, page_size);
    prepare_and_check(p + 2, 1, p + 2, "different address with same length is not a hit");

    unsigned char *shared = m + 5 * page_size;
    nvn_dirty_add_range(shared, page_size / 2);
    nvn_dirty_add_range(shared + page_size / 2, page_size);
    const void *left = nvn_dirty_span(shared, 1), *right = nvn_dirty_span(shared + page_size / 2, page_size);
    uint64_t stamp = nvn_dirty_now();
    nvn_dirty_protect(shared, 1); nvn_dirty_protect(shared + page_size / 2, page_size);
    dm_guest_write_prepare(shared + 4, 1);
    CK(kernel_write(shared + 4), "shared physical page writable");
    CK(nvn_dirty_since_span(left, shared, 1, stamp), "first overlapping range released");
    CK(nvn_dirty_since_span(right, shared + page_size / 2, page_size, stamp), "second overlapping range released");

    nvn_dirty_remove_range(m);

    thread_page = m + 7 * page_size;
    pthread_t th; if (pthread_create(&th, NULL, reader, NULL)) abort();
    for (int i = 0; i < 1000; i++) {
        wait_phase(1);
        nvn_dirty_add_range(thread_page, page_size); nvn_dirty_protect(thread_page, page_size);
        publish_phase(2); wait_phase(3);
        nvn_dirty_remove_range(thread_page); publish_phase(0);
    }
    pthread_join(th, NULL);

    // A long-lived calling thread can keep its TLS queries across sessions.
    if (!same_session) {
        dm_guest_write_prepare(m + 4, 1); dm_guest_write_prepare(m + 4, 1);
        nvn_dirty_reset_session();
        nvn_dirty_add_range(m, page_size);
        CK(nvn_dirty_tracked(m, 1), "new session still registers the real memory range");
        nvn_dirty_protect(m, page_size);
        prepare_and_check(m + 4, 1, m + 4, "session reset cannot reuse an old even epoch");
    }
    uint64_t faults, preps; nvn_dirty_stats(&faults, &preps);
    CK(faults == 0, "kernel writes needed no signal-handler fallback");
    CK(preps >= (same_session ? 1007u : 1008u), "real pre-write unprotects counted");
    nvn_dirty_reset_session(); munmap(m, 8 * page_size); munmap(initial, page_size);
    printf("%s t_dirty_prewrite: %d checks, %d failures (real mmap/mprotect/kernel copies; 1000 cross-thread publications; %s)\n",
           failed ? "✗" : "✓", checks, failed, same_session ? "same-session only" : "including session reset");
    return failed != 0;
}

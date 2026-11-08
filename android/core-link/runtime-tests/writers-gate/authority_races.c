// R7-P1-2: an attempted shell transition at the clock sampling boundary must
// serialize behind the actual production lease mutex. No Android/device code.
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
static _Atomic uint64_t now_ns;
static _Atomic int inject, requested, attempted, blocked;
static int controlled_clock(clockid_t clock, struct timespec *ts) {
    (void)clock;
    uint64_t now = atomic_load(&now_ns);
    ts->tv_sec = now / 1000000000ull; ts->tv_nsec = now % 1000000000ull;
    if (atomic_exchange(&inject, 0)) {
        atomic_store(&requested, 1);
        while (!atomic_load(&attempted)) sched_yield();
    }
    return 0;
}
#define clock_gettime controlled_clock
#ifdef __APPLE__
#define pthread_condattr_setclock(a,c) ((void)(a),(void)(c),0)
#endif
#include "../../../native/wsi_lease.c"
static s2a_wsi_lease *lease;
static void noop(void *window) { (void)window; }
static void *shell(void *unused) {
    (void)unused;
    while (!atomic_load(&requested)) sched_yield();
    int error = pthread_mutex_trylock(&lease->mutex);
    atomic_store(&blocked, error == EBUSY);
    if (!error) pthread_mutex_unlock(&lease->mutex);
    atomic_store(&attempted, 1);
    s2a_wsi_set_foreground(lease, 0);
    atomic_fetch_add(&now_ns, 35000000000ull);
    s2a_wsi_set_foreground(lease, 1);
    return NULL;
}
int main(void) {
    const struct s2a_wsi_window_ops ops = {noop, noop};
    for (int registration = 0; registration < 2; ++registration) {
        atomic_store(&now_ns, 1000000000ull);
        atomic_store(&requested, 0); atomic_store(&attempted, 0); atomic_store(&blocked, 0);
        lease = s2a_wsi_create(1, &ops); assert(lease);
        s2a_wsi_set_foreground(lease, 1);
        uint64_t owner = registration ? 0 : s2a_wsi_backing_progress(lease, 7, 0, 1);
        pthread_t worker; assert(!pthread_create(&worker, NULL, shell, NULL));
        atomic_store(&inject, 1);
        if (registration) owner = s2a_wsi_backing_progress(lease, 7, 0, 1);
        else assert(s2a_wsi_backing_decision(lease, owner) == S2A_BACKING_CONTINUE);
        assert(!pthread_join(worker, NULL));
        if (!atomic_load(&blocked)) { fputs("REGRESSION: lifecycle raced native clock outside lease mutex\n", stderr); return 1; }
        assert(lease->backing.start == atomic_load(&now_ns));
        assert(s2a_wsi_backing_decision(lease, owner) == S2A_BACKING_CONTINUE);
        atomic_fetch_add(&now_ns, 3250000000ull);
        assert(s2a_wsi_backing_decision(lease, owner) == S2A_BACKING_IDLE);
        uint64_t deadline;
        assert(s2a_wsi_backing_admission(lease, 7, &deadline));
        assert(deadline > atomic_load(&now_ns));
        s2a_wsi_destroy(lease);
    }
    puts("PASS R7 clock/lifecycle internal interleaving: read + registration, background35s, callback reset, exact idle, admission margin");
}

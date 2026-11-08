// Cross-consumer fixture: real thread.c roster/SIGURG epoch + crash/xstack/fault
// + lifecycle.c. Only game/module/TSD/tracker/managed endpoints are fixtures.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef S2A_UNIT_TEST
#define S2A_UNIT_TEST
#endif
#ifndef S2A_SHUTDOWN_THREAD_SOURCE
#define S2A_SHUTDOWN_THREAD_SOURCE "../../../../../runtime/src/thread.c"
#endif
#include S2A_SHUTDOWN_THREAD_SOURCE
#include "../lifecycle_android.h"
#include "services_abi.h"
#include <sys/mman.h>

void s2a_host_shutdown(const char *);
void s2a_crash_install(void);
void s2a_shutdown_test_begin_services(uint64_t, int);
extern void s2a_fault_test_guest_stack(void (*)(void), void *);
extern void s2a_shutdown_test_loop(void *), s2a_shutdown_test_store(void *);
extern char s2a_shutdown_test_guest_start[], s2a_shutdown_test_guest_end[];

struct job { _Atomic uint64_t count, stop; _Atomic int phase; int fault; };
static struct job spinning, touching, newborn;
static _Thread_local struct job *job;
static _Atomic int touch_active, touch_release, cancelled;
static unsigned char *page;
static size_t page_size;
static const char *mode;
static int disposed;
static uint64_t shutdown_started;
static _Atomic int serial_owner_ready;
// Vulkan phase cases (shutdown_vk.c links production direct_vk.c unchanged).
int s2a_shutdown_vk_setup(int kind);
void s2a_shutdown_vk_call(void);
int s2a_android_vk_terminal_drain(void);
extern _Atomic uint64_t s2a_shutdown_vk_start_ns;
extern _Atomic int s2a_shutdown_vk_release, s2a_shutdown_vk_entered;
static int vk_kind, vk_terminal_failed;
static thr_t *owner;
static _Atomic int epoch_result = -1;
static _Atomic int stopping;
static int touch_mode(void) {
    return strcmp(mode, "zero") && strncmp(mode, "guest-owner", 11) && strncmp(mode, "vk-", 3);
}
static void check(int yes, const char *why) {
    if (!yes) { fprintf(stderr, "FAIL shutdown consumer: %s\n", why); _exit(86); }
}
static void mark(const char *text) { if (write(STDOUT_FILENO, text, strlen(text)) < 0) _exit(87); }

// Platform fixture boundaries; no scheduling/quiescence/fault success providers.
uint64_t plat_now_ns(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec; }
uint64_t now_ns(void) { return plat_now_ns(); }
int plat_fault_install(int signal, void (*handler)(int, siginfo_t *, void *), unsigned flags) {
    struct sigaction a = {0}; a.sa_sigaction = handler;
    a.sa_flags = SA_SIGINFO | (flags & PLAT_FAULT_ONSTACK ? SA_ONSTACK : 0);
    sigemptyset(&a.sa_mask); return sigaction(signal, &a, NULL) ? errno : 0;
}
int plat_tsd_init(void) { return 0; }
int plat_tsd_offset(uint32_t key, uint64_t *offset) { *offset = (uint64_t)key * 8; return 0; }
int plat_thread_stack_bounds(uintptr_t *lo, uintptr_t *hi) {
    pthread_attr_t attr; void *p; size_t n; int e = pthread_getattr_np(pthread_self(), &attr);
    if (e) return e;
    e = pthread_attr_getstack(&attr, &p, &n); pthread_attr_destroy(&attr);
    if (!e) { *lo = (uintptr_t)p; *hi = *lo + n; } return e;
}
module_t *module_of(const void *pc) {
    static module_t m; uintptr_t p = (uintptr_t)pc;
    return p >= (uintptr_t)s2a_shutdown_test_guest_start && p < (uintptr_t)s2a_shutdown_test_guest_end ? &m : NULL;
}
int s2a_direct_fault(void *a, int w, void *c) { (void)a; (void)w; (void)c; return 0; }
int s2a_track_fault_guest(void *a, int w, uint64_t skip) { (void)w; (void)skip; return a == page ? 2 : 0; }
int s2a_track_fault(void *a, int w) { (void)a; (void)w; return 0; }
void s2a_track_touch(uint64_t address) {
    check(address == (uintptr_t)page, "actual fault address");
    atomic_store(&touch_active, 1); mark("touch-enter\n");
    if (!strcmp(mode, "self-touch")) s2a_host_shutdown("shutdown from active Touch");
    while (!atomic_load(&touch_release)) usleep(100);
    check(!mprotect(page, page_size, PROT_READ | PROT_WRITE), "real readback page released");
    atomic_store(&touch_active, 0); mark("touch-return\n");
}
static void guest_body(void) {
    if (job->fault) s2a_shutdown_test_store(page);
    s2a_shutdown_test_loop(job);
}
static thr_t *enroll(void) {
    thr_t *thread = calloc(1, sizeof *thread); check(thread != NULL, "thread allocation");
    thread->pt = pthread_self(); thread->started = 1; thread->prio = 44; thread->mask = 7;
    check(!pthread_cond_init(&thread->cv, NULL), "thread condition");
    check(!pthread_setspecific(g_keythr, thread), "real roster TLS");
    glock(); thread->all = g_all; g_all = thread; pthread_mutex_unlock(&G);
    android_vm_barrier(thread); // actual same admission boundary as thread_bind_host
    return thread;
}
static void *worker(void *arg) {
    job = arg;
    (void)enroll();
    s2a_crash_thread_init();
    sw_xstack_thread_init(((uintptr_t)__builtin_frame_address(0) - 0x400) & ~15ull, 0);
    check(!s2a_android_fault_probe(), "real thread dispatcher self-probe");
    atomic_store(&job->phase, 1);
    size_t n = 1 << 20;
    void *stack = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(stack != MAP_FAILED, "distinct guest stack");
    s2a_fault_test_guest_stack(guest_body, (char *)stack + n);
    _exit(88); // production shutdown must never resume this guest.
}
static void wait_ready(_Atomic int *value) {
    uint64_t deadline = plat_now_ns() + 3000000000ull;
    while (!atomic_load(value)) { check(plat_now_ns() < deadline, "guest ready deadline"); usleep(100); }
}
// A guest thread (or, for guest-owner, a host thread) with an in-flight
// Vulkan call that legally reverses into the guest allocator.
static void *vk_worker(void *arg) {
    if (arg) (void)enroll();
    check(!s2a_shutdown_vk_setup(vk_kind), "production direct Vulkan configured with fake driver");
    s2a_shutdown_vk_call();
    _exit(88); // an admitted call must park at its final finish, never resume the guest.
}
// A non-terminal writer epoch while the guest shutdown owner waits in phase 2.
static void *concurrent_epoch(void *unused) {
    (void)unused;
    while (!atomic_load(&s2a_shutdown_vk_start_ns) || plat_now_ns() < atomic_load(&s2a_shutdown_vk_start_ns) + 20000000ull) usleep(200);
    uint64_t begin = plat_now_ns();
    int error = s2a_android_guest_writers_begin();
    if (!error) s2a_android_guest_writers_end();
    if (!error && plat_now_ns() - begin < 500000000ull) mark("vk-concurrent-epoch-ok\n");
    atomic_store(&epoch_result, error);
    atomic_store(&s2a_shutdown_vk_release, 1);
    return NULL;
}
static void *release_later(void *unused) {
    (void)unused; usleep(60000); atomic_store(&touch_release, 1); return NULL;
}
static void *serial_owner(void *unused) {
    (void)unused;
    int gap = !strcmp(mode, "serial-gap");
    if (gap) check(!pthread_mutex_lock(&android_vm_serial), "real serial before epoch publication");
    else check(!s2a_android_guest_writers_begin(), "real concurrent writer epoch");
    atomic_store(&serial_owner_ready, 1);
    while (!atomic_load(&cancelled)) usleep(100);
    if (!strcmp(mode, "serial-hang")) for (;;) pause();
    usleep(60000);
    if (gap) android_vm_unlock_serial();
    else s2a_android_guest_writers_end();
    return NULL;
}

void s2a_track_stat_log(const char *s) { (void)s; }
uint64_t s2a_track_protected_pages(void) { return 0; }
void s2a_direct_res_report(void) {}
void s2a_svc_count_report(const char *s) { (void)s; }
void s2a_guest_va_report(const char *s) { (void)s; }
void s2a_vm_low(const char *s) { (void)s; }
void s2a_lowva_peak_report(const char *s) { (void)s; }
void S2A_CancelWaits(void) { atomic_store(&cancelled, 1); mark("cancel\n"); }
// Stateful like gate.c: stopping is published only by the terminal SVC park.
int s2a_svc_stopping(void) { return atomic_load(&stopping); }
int s2a_svc_park_all(int ms) {
    check(ms == 300 && atomic_load(&cancelled), "cancel precedes service park");
    if (owner) {
        check(atomic_load(&epoch_result) == 0, "concurrent epoch completed while owner drained");
        check(atomic_load(&owner->held_core) != 0 && !owner->vm_wait_safe, "owner restored core and revoked census-safe");
    }
    atomic_store(&stopping, 1);
    s2a_android_guest_writers_notify_stop();
    return 0;
}
void s2a_cs_shutdown(const char *why) {
    (void)why;
    check(!disposed, "single dispose");
    check(!atomic_load(&touch_active), "actual fault callback drained before Dispose");
    check(atomic_load(&android_vm_epoch) != 0, "real writer epoch held before Dispose");
    if (touch_mode()) check(plat_now_ns() - shutdown_started >= 30000000, "shutdown waited for real Touch");
    if (vk_kind) {
        // Same consumer as the managed StopGpu → s2a_android_vk_session_stop path.
        int result = s2a_android_vk_terminal_drain();
        vk_terminal_failed = result != 0;
        mark(result ? "vk-terminal-busy\n" : "vk-terminal-clean\n");
    }
    uint64_t before = atomic_load(&spinning.count);
    usleep(10000);
    check(before == atomic_load(&spinning.count), "ordinary guest writes remain stopped during Dispose");
    pthread_t child;
    check(!pthread_create(&child, NULL, worker, &newborn), "new child during Dispose");
    usleep(10000);
    check(!atomic_load(&newborn.phase), "new guest cannot escape shutdown epoch");
    disposed = 1; mark("managed-dispose-after-real-quiesce\n");
}
int s2a_android_services_status(uint64_t session, struct s2a_android_services_status *out) {
    check(disposed, "post-cleanup result ordering");
    check(session == 0x1234, "runtime retains same service session");
    *out = (struct s2a_android_services_status){sizeof *out, S2A_ANDROID_SERVICES_ABI,
        session, S2A_SERVICES_STOPPED, 0};
    if (!strcmp(mode, "cleanup-fail") || vk_terminal_failed) { out->state = S2A_SERVICES_FAILED; out->error = S2A_SERVICES_CLEANUP; }
    if (!strcmp(mode, "stop-only")) out->state = S2A_SERVICES_STOP_REQUESTED;
    if (!strcmp(mode, "wrong-session")) ++out->session_id;
    return !strcmp(mode, "query-fail") ? S2A_SERVICES_ARGUMENT : 0;
}
void s2a_widen_scan(void) { check(disposed && atomic_load(&android_vm_epoch), "epoch retained after Dispose"); }
void s2a_direct_summary(int complete) { (void)complete; }
void s2a_svc_red_summary(void) {}
void s2a_det_summary(void) {}
unsigned s2a_unresolved_count(void) { return 0; }

int main(int argc, char **argv) {
    check(argc == 2, "mode argument"); mode = argv[1];
    vk_kind = !strcmp(mode, "vk-svc") ? 1 : !strcmp(mode, "vk-core") ? 2 : !strcmp(mode, "vk-passthrough") ? 3 :
        !strncmp(mode, "guest-owner", 11) ? 4 : 0;
    check(vk_kind || touch_mode() || !strcmp(mode, "zero"), "known mode");
    setenv("S2A_CORES", vk_kind == 4 ? "1" : "0", 1);
    s2a_shutdown_test_begin_services(0x1234, strcmp(mode, "zero") != 0);
    check(!s2a_android_guest_writers_init(), "actual writers installation");
    s2a_crash_install();
    if (vk_kind == 4) {
        // Guest shutdown owner holding a virtual core, as in ExitProcess / Break.
        owner = enroll();
        core_acquire(owner);
        check(atomic_load(&owner->held_core) != 0, "owner holds a virtual core");
        pthread_t spin;
        check(!pthread_create(&spin, NULL, worker, &spinning), "ordinary writer thread");
        wait_ready(&spinning.phase);
    }
    if (vk_kind) {
        pthread_t vk, epoch;
        check(!pthread_create(&vk, NULL, vk_worker, vk_kind == 4 ? NULL : (void *)1), "Vulkan caller");
        wait_ready(&s2a_shutdown_vk_entered);
        if (vk_kind == 4) check(!pthread_create(&epoch, NULL, concurrent_epoch, NULL), "concurrent epoch owner");
    }
    if (touch_mode()) {
        page_size = (size_t)sysconf(_SC_PAGESIZE);
        page = mmap(NULL, page_size, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        check(page != MAP_FAILED, "protected guest page");
        pthread_t spin, touch, release;
        check(!pthread_create(&spin, NULL, worker, &spinning), "ordinary writer thread");
        wait_ready(&spinning.phase);
        touching.fault = 1;
        check(!pthread_create(&touch, NULL, worker, &touching), "fault writer thread");
        wait_ready(&touch_active);
        if (strcmp(mode, "touch-hang") && strcmp(mode, "self-touch"))
            check(!pthread_create(&release, NULL, release_later, NULL), "external readback completion");
    }
    if (!strcmp(mode, "self-touch")) for (;;) pause();
    if (!strncmp(mode, "serial-", 7)) {
        pthread_t owner;
        check(!pthread_create(&owner, NULL, serial_owner, NULL), "contending native owner");
        wait_ready(&serial_owner_ready);
    }
    shutdown_started = plat_now_ns();
    atomic_store(&s2a_shutdown_vk_start_ns, shutdown_started);
    if (!strcmp(mode, "guest-owner-exit") || !strcmp(mode, "guest-owner-break")) {
        static uint64_t regs[31];
        s2a_android_memory_svc_enter(!strcmp(mode, "guest-owner-exit") ? 0x07 : 0x26, regs);
    }
    s2a_host_shutdown("real guest + fault consumer");
    return 89;
}

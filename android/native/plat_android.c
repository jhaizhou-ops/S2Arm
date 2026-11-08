// Android implementation of the first plat.h batch.  The Bionic-specific parts
// reuse tsd.c / guest_signal.c; this file only supplies the plat_* contract.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "s2a_hostapi.h"
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// HostApi user table values were frozen at registration; retain its error codes.
int s2a_plat_android_system_language(const s2a_host_api_v1 *api, char *out, size_t cap) {
    if (!api || !out || !cap || api->hdr.size < sizeof(*api) ||
        api->hdr.abi_version != S2A_HOST_API_ABI_VERSION ||
        !(api->capabilities & S2A_HOST_CAP_USER) || !api->user ||
        api->user->hdr.size < sizeof(*api->user) ||
        api->user->hdr.abi_version != S2A_HOST_API_ABI_VERSION || !api->user->language)
        return S2A_HOST_E_ARGUMENT;
    return api->user->language(api->host, out, cap);
}

static int64_t plat_android_parse_statm(const char *text, long page_size) {
    if (!text || page_size <= 0 || *text < '0' || *text > '9') return -1;
    char *end;
    errno = 0;
    (void)strtoull(text, &end, 10);
    if (errno || end == text || (*end != ' ' && *end != '\t')) return -1;
    while (*end == ' ' || *end == '\t') end++;
    if (*end < '0' || *end > '9') return -1;
    const char *resident_start = end;
    errno = 0;
    unsigned long long resident = strtoull(resident_start, &end, 10);
    if (errno || end == resident_start || (*end && *end != ' ' && *end != '\t' && *end != '\n')) return -1;
    if (resident > (unsigned long long)INT64_MAX / (unsigned long long)page_size) return -1;
    return (int64_t)(resident * (unsigned long long)page_size);
}

int64_t s2a_plat_android_memory_footprint(void) {
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) return -1;
    FILE *file = fopen("/proc/self/statm", "r");
    if (!file) return -1;
    char line[256];
    char *read = fgets(line, sizeof(line), file);
    fclose(file);
    return read ? plat_android_parse_statm(line, page_size) : -1;
}

#ifdef S2A_UNIT_TEST
int64_t plat_android_test_statm(const char *text, long page_size) {
    return plat_android_parse_statm(text, page_size);
}
#endif

#ifndef S2A_HOST_FIELDS_ONLY
#include "../../platform/plat.h"

#include "direct/selection.h"

#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#if defined(__linux__) || defined(__ANDROID__)
#include <sys/syscall.h>
#endif
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#if defined(__ANDROID__) && !defined(S2A_UNIT_TEST)
#include <android/log.h>
#endif

#include "guest_signal.h"
#include "memory.h"
#include "tsd.h"

#if defined(__ANDROID__) && defined(__aarch64__)
static uint64_t g_tsd_table_off;
static int g_tsd_ready;
#endif

size_t plat_page_size(void) {
    long pg = sysconf(_SC_PAGESIZE);
    return pg > 0 ? (size_t)pg : 0;
}

uint64_t plat_now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int plat_sleep_until(uint64_t deadline_ns) {
    if (deadline_ns == 0) return EINVAL;

#if defined(__APPLE__)
    // The Android adapter is built by the macOS host gate but runs only on Android.
    return ENOTSUP;
#else
    struct timespec deadline = {
        .tv_sec = (time_t)(deadline_ns / 1000000000ull),
        .tv_nsec = (long)(deadline_ns % 1000000000ull),
    };

    for (;;) {
        int rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, NULL);
        if (rc == EINTR) continue;
        if (rc != 0) return rc;

        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return errno;
        uint64_t now_ns = (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
        if (now_ns >= deadline_ns) return 0;
    }
#endif
}

enum {
    S2A_ANDROID_QOS_BACKGROUND = 1,
    S2A_ANDROID_QOS_UTILITY = 2,
    S2A_ANDROID_QOS_DEFAULT = 3,
    S2A_ANDROID_QOS_USER_INITIATED = 4,
    S2A_ANDROID_QOS_USER_INTERACTIVE = 5,
};

static int plat_qos_nice(int cls, int *nice_value) {
    switch (cls) {
        case S2A_ANDROID_QOS_BACKGROUND: *nice_value = 10; return 0;
        case S2A_ANDROID_QOS_UTILITY: *nice_value = 2; return 0;
        case S2A_ANDROID_QOS_DEFAULT: *nice_value = 0; return 0;
        case S2A_ANDROID_QOS_USER_INITIATED: *nice_value = -2; return 0;
        case S2A_ANDROID_QOS_USER_INTERACTIVE: *nice_value = -8; return 0;
        default: return EINVAL;
    }
}

int plat_thread_qos(int cls) {
    int nice_value;
    int rc = plat_qos_nice(cls, &nice_value);
    if (rc != 0) return rc;
#if defined(SYS_gettid)
    long tid = syscall(SYS_gettid);
    if (tid <= 0) return errno ? errno : EIO;
    if (setpriority(PRIO_PROCESS, (id_t)tid, nice_value) != 0) return errno;
    return 0;
#else
    (void)nice_value;
    return ENOTSUP;
#endif
}

int plat_thread_realtime(uint64_t period_ns, uint64_t computation_ns, uint64_t constraint_ns) {
    if (period_ns == 0 || computation_ns == 0 || constraint_ns == 0 ||
        computation_ns > constraint_ns || constraint_ns > period_ns) {
        return EINVAL;
    }
    // Android applications do not have a supported, unprivileged real-time
    // scheduling contract. Do not report success for a best-effort nice value.
    return ENOTSUP;
}

// Bounded process-wide Android log queue. A producer never waits for the queue
// lock or the logd writer; contention is accounted for just like a full queue.
// The first caller initializes the semaphore and starts the detached writer.
enum { S2A_LOG_CAPACITY = 64, S2A_LOG_TEXT_BYTES = 1024 };
typedef struct { int priority; char text[S2A_LOG_TEXT_BYTES]; } s2a_log_entry;
static s2a_log_entry s2a_logs[S2A_LOG_CAPACITY];
static unsigned s2a_log_head, s2a_log_tail;
static atomic_uint s2a_log_count;
static atomic_flag s2a_log_lock = ATOMIC_FLAG_INIT;
static atomic_int s2a_log_state; // 0 = unstarted, 1 = starting, 2 = ready
static atomic_int s2a_log_exiting, s2a_log_inflight, s2a_log_notified;
static atomic_uint_fast64_t s2a_log_dropped;
static sem_t s2a_log_wake;
#ifdef S2A_UNIT_TEST
static int (*s2a_log_test_writer)(int, const char *, const char *);
static atomic_uint_fast64_t s2a_log_test_dropped;
void plat_log_test_set_writer(int (*writer)(int, const char *, const char *)) { s2a_log_test_writer = writer; }
uint64_t plat_log_test_dropped(void) { return atomic_load(&s2a_log_test_dropped); }
unsigned plat_log_test_capacity(void) { return S2A_LOG_CAPACITY; }
#endif

static int s2a_log_priority(int level) {
    switch (level) {
        case 0: case 1: return 3; // DEBUG
        case 2: case 5: case 6: case 7: case 8: return 4; // INFO
        case 3: return 5; // WARN
        case 4: return 6; // ERROR
        case 9: return 2; // VERBOSE
        default: return 4;
    }
}

static void s2a_log_emit(int priority, const char *text) {
#ifdef S2A_UNIT_TEST
    if (s2a_log_test_writer) { (void)s2a_log_test_writer(priority, "S2Arm", text); return; }
#endif
#if defined(__ANDROID__) && !defined(S2A_UNIT_TEST)
    (void)__android_log_write(priority, "S2Arm", text);
#else
    (void)priority; (void)text;
#endif
}

// Coalesce wakeups: the consumer drains the queue before waiting again, so a
// stream of empty-to-nonempty transitions must not grow the semaphore forever.
static void s2a_log_notify(void) {
    if (!atomic_exchange_explicit(&s2a_log_notified, 1, memory_order_acq_rel))
        (void)sem_post(&s2a_log_wake);
}

static void s2a_log_drop(void) {
#ifdef S2A_UNIT_TEST
    atomic_fetch_add_explicit(&s2a_log_test_dropped, 1, memory_order_relaxed);
#endif
    uint64_t previous = atomic_fetch_add_explicit(&s2a_log_dropped, 1, memory_order_relaxed);
    if (previous == 0 && atomic_load_explicit(&s2a_log_state, memory_order_acquire) == 2)
        s2a_log_notify();
}

static void *s2a_log_worker(void *unused) {
    (void)unused;
    for (;;) {
        while (sem_wait(&s2a_log_wake) != 0 && errno == EINTR) {}
        atomic_store_explicit(&s2a_log_notified, 0, memory_order_release);
        for (;;) {
            // Only the consumer waits for a producer holding the short queue lock.
            while (atomic_flag_test_and_set_explicit(&s2a_log_lock, memory_order_acquire)) {
                struct timespec pause = { .tv_nsec = 1000000 };
                nanosleep(&pause, NULL);
            }
            unsigned count = atomic_load_explicit(&s2a_log_count, memory_order_relaxed);
            s2a_log_entry entry;
            atomic_store_explicit(&s2a_log_inflight, 1, memory_order_release);
            if (count) {
                entry = s2a_logs[s2a_log_head];
                s2a_log_head = (s2a_log_head + 1) % S2A_LOG_CAPACITY;
                atomic_store_explicit(&s2a_log_count, count - 1, memory_order_release);
            }
            atomic_flag_clear_explicit(&s2a_log_lock, memory_order_release);
            uint64_t dropped = atomic_exchange_explicit(&s2a_log_dropped, 0, memory_order_acq_rel);
            if (dropped) {
                char msg[96];
                snprintf(msg, sizeof msg, "丢了 %" PRIu64 " 条日志", dropped);
                s2a_log_emit(5, msg);
            }
            if (count) {
                s2a_log_emit(entry.priority, entry.text);
            }
            atomic_store_explicit(&s2a_log_inflight, 0, memory_order_release);
            if (count) continue;
            if (atomic_load_explicit(&s2a_log_exiting, memory_order_acquire)) return NULL;
            break;
        }
    }
}

static void s2a_log_exit(void) {
    if (atomic_load_explicit(&s2a_log_state, memory_order_acquire) != 2) return;
    atomic_store_explicit(&s2a_log_exiting, 1, memory_order_release);
    s2a_log_notify();
    // Best effort only: a blocked logd must not hold process shutdown indefinitely.
    for (int i = 0; i < 20; i++) {
        if (!atomic_load_explicit(&s2a_log_count, memory_order_acquire) &&
            !atomic_load_explicit(&s2a_log_dropped, memory_order_acquire) &&
            !atomic_load_explicit(&s2a_log_inflight, memory_order_acquire)) break;
        struct timespec pause = { .tv_nsec = 1000000 };
        nanosleep(&pause, NULL);
    }
}

static int s2a_log_start(void) {
    int state = atomic_load_explicit(&s2a_log_state, memory_order_acquire);
    if (state == 2) return 1;
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&s2a_log_state, &expected, 1,
                                                 memory_order_acq_rel, memory_order_acquire)) return 0;
    if (sem_init(&s2a_log_wake, 0, 0) != 0) { atomic_store(&s2a_log_state, 0); return 0; }
    // Register before starting the worker; failed thread starts may retry safely.
    static int exit_registered;
    if (!exit_registered) {
        if (atexit(s2a_log_exit) != 0) { sem_destroy(&s2a_log_wake); atomic_store(&s2a_log_state, 0); return 0; }
        exit_registered = 1;
    }
    pthread_t worker;
    if (pthread_create(&worker, NULL, s2a_log_worker, NULL) != 0) {
        sem_destroy(&s2a_log_wake); atomic_store(&s2a_log_state, 0); return 0;
    }
    (void)pthread_detach(worker);
    atomic_store_explicit(&s2a_log_state, 2, memory_order_release);
    s2a_log_notify(); // report drops during startup, if any
    return 1;
}

void plat_log_write(int level, const char *utf8) {
    if (!utf8) return;
    if (atomic_load_explicit(&s2a_log_exiting, memory_order_acquire) || !s2a_log_start()) { s2a_log_drop(); return; }
    if (atomic_flag_test_and_set_explicit(&s2a_log_lock, memory_order_acquire)) { s2a_log_drop(); return; }
    unsigned count = atomic_load_explicit(&s2a_log_count, memory_order_relaxed);
    if (count == S2A_LOG_CAPACITY) {
        atomic_flag_clear_explicit(&s2a_log_lock, memory_order_release);
        s2a_log_drop();
        return;
    }
    s2a_log_entry *entry = &s2a_logs[s2a_log_tail];
    entry->priority = s2a_log_priority(level);
    size_t n = strnlen(utf8, S2A_LOG_TEXT_BYTES - 1);
    // If truncating, drop a partial UTF-8 code point rather than emit broken text.
    if (n == S2A_LOG_TEXT_BYTES - 1 && utf8[n])
        while (n && (((unsigned char)utf8[n] & 0xc0) == 0x80)) n--;
    memcpy(entry->text, utf8, n);
    entry->text[n] = '\0';
    s2a_log_tail = (s2a_log_tail + 1) % S2A_LOG_CAPACITY;
    atomic_store_explicit(&s2a_log_count, count + 1, memory_order_release);
    atomic_flag_clear_explicit(&s2a_log_lock, memory_order_release);
    if (count == 0) s2a_log_notify();
}

#ifdef S2A_UNIT_TEST
static int g_plat_test_protect_fail;
static int g_plat_test_restore_fail;
void plat_vm_test_set_protect_fail(int on) { g_plat_test_protect_fail = on; }
void plat_vm_test_set_restore_fail(int on) { g_plat_test_restore_fail = on; }
#endif

static int plat_restore_reserved(void *dst, size_t size) {
    // Keep dst reserved in the guest window; never hand it back to the system.
    if (!dst || !size) return EINVAL;
#ifdef S2A_UNIT_TEST
    if (g_plat_test_restore_fail) return ENOMEM;
#endif
    void *p = mmap(dst, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE, -1, 0);
    if (p == dst) return 0;
    if (p != MAP_FAILED) munmap(p, size);
    return errno ? errno : EIO;
}

static int plat_native_prot(uint32_t prot, int *out) {
    if (prot & ~(uint32_t)(PLAT_PROT_READ | PLAT_PROT_WRITE | PLAT_PROT_EXEC)) return EINVAL;
    int p = PROT_NONE;
    if (prot & PLAT_PROT_READ) p |= PROT_READ;
    if (prot & PLAT_PROT_WRITE) p |= PROT_WRITE;
    if (prot & PLAT_PROT_EXEC) p |= PROT_EXEC;
    *out = p;
    return 0;
}

int plat_vm_reserve(size_t size, size_t alignment, uint64_t limit, void **out) {
    if (!out) return EINVAL;
    void *p = NULL;
    int e = s2a_android_reserve(size, alignment, limit, &p);
    if (!e) *out = p;
    return e;
}

int plat_vm_protect(void *addr, size_t size, uint32_t prot) {
    if (!addr || !size) return EINVAL;
    size_t pg = plat_page_size();
    if (!pg || ((uintptr_t)addr & (pg - 1)) || (size % pg)) return EINVAL;
    int p;
    int e = plat_native_prot(prot, &p);
    if (e) return e;
    return mprotect(addr, size, p) ? errno : 0;
}

int plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot) {
    if (!dst || !src || !size || dst == src) return EINVAL;
    size_t pg = plat_page_size();
    if (!pg) return ENOTSUP;
    if (((uintptr_t)dst & (pg - 1)) || ((uintptr_t)src & (pg - 1)) || (size % pg)) return EINVAL;
    int p;
    int e = plat_native_prot(prot, &p);
    if (e) return e;
#if defined(MREMAP_FIXED)
    // Linux/Bionic: old_size == 0 duplicates the mapping.  FIXED requires a
    // shared-backed src and a reserved dst; both are part of the contract.
    void *r = mremap((void *)src, 0, size, MREMAP_MAYMOVE | MREMAP_FIXED, dst);
    if (r == MAP_FAILED) { e = errno; int re = plat_restore_reserved(dst, size); return re ? EIO : e; }
#ifdef S2A_UNIT_TEST
    if (g_plat_test_protect_fail) e = EACCES; else
#endif
    e = plat_vm_protect(dst, size, prot);
    if (e) { int re = plat_restore_reserved(dst, size); return re ? EIO : e; }
    // 受控别名：登记来源区间，池后备迁移前据此拒绝（maps 里判不出别名：kgsl 的 dev/inode/offset 不可用）。
    {
        extern int s2a_alias_note(uint64_t, uint64_t, uint64_t) __attribute__((weak));
        if (s2a_alias_note) (void)s2a_alias_note((uint64_t)(uintptr_t)src, (uint64_t)(uintptr_t)dst, (uint64_t)size);
    }
    return 0;
#else
    (void)p;
    return ENOTSUP;
#endif
}

// Transitional provider: Android owns the 64 GiB window and uses the proven
// legacy budget until it has a far-shadow provider. Apple stays on main's layout.
#include "../../runtime/src/native.h"
#include "runtime/platform/layout_android.inc"
int plat_layout_override(const char *npdm, uint32_t as_type, uint64_t sysres,
                         uint64_t program_id, uint64_t window_base, uint64_t window_size,
                         struct s2a_layout *out, uint64_t *need, char *detail, size_t detail_size) {
    if (!npdm || !out || !need || !detail || !detail_size) return EINVAL;
    char path[1100]; snprintf(path, sizeof path, "%s", npdm);
    char *slash = strrchr(path, '/');
    snprintf(slash ? slash + 1 : path, sizeof path - (size_t)(slash ? slash + 1 - path : 0), "addr_need.tsv");
    s2a_layout_requirements req; const char *why = NULL;
    if (s2a_android_layout_requirements_read(path, program_id, &req, &why) < 0) {
        snprintf(detail, detail_size, "%s", why ? why : "读取地址需求失败"); return EINVAL;
    }
    if (s2a_android_layout_split(&req, 0, &why, detail, detail_size) < 0) {
        snprintf(detail, detail_size, "%s", why ? why : "地址预算无效"); return EINVAL;
    }
    *need = s2a_android_layout_need(as_type, sysres, &req);
    int rc = s2a_android_layout_compute(as_type, sysres, &req, window_base, window_size, out);
    if (rc) { snprintf(detail, detail_size, "Android 地址布局失败：%d", rc); return EINVAL; }
    return 0;
}

int plat_tsd_init(void) {
#if defined(__ANDROID__) && defined(__aarch64__)
    uint64_t off = 0;
    int e = s2a_android_tsd_probe(&off);
    if (e) return e;
    g_tsd_table_off = off;
    g_tsd_ready = 1;
    return 0;
#else
    return ENOTSUP;
#endif
}

uint64_t plat_tsd_base(void) {
#if defined(__ANDROID__) && defined(__aarch64__)
    return (uint64_t)(uintptr_t)s2a_bionic_tls();
#else
    return 0;
#endif
}

int plat_tsd_offset(uint32_t key, uint64_t *out) {
    if (!out) return EINVAL;
#if defined(__ANDROID__) && defined(__aarch64__)
    if (!g_tsd_ready) return ENOTSUP;
    uint64_t off = s2a_bionic_slot_off(g_tsd_table_off, key);
    if (!off) return EINVAL;
    *out = off;
    return 0;
#else
    (void)key;
    return ENOTSUP;
#endif
}

int plat_fault_install(int sig, void (*fn)(int, siginfo_t *, void *), unsigned flags) {
    if (!fn || sig <= 0) return EINVAL;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = fn;
    // Every handler that can run on a guest thread must use its alternate
    // stack: the guest stack may be only a few KiB and may already be corrupt.
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    if (flags & PLAT_FAULT_RESTART) sa.sa_flags |= SA_RESTART;
    sigemptyset(&sa.sa_mask);
    return sigaction(sig, &sa, NULL) ? errno : 0;
}

int plat_fault_altstack_init(void) {
    return s2a_android_altstack_init();
}

void plat_fault_altstack_set_mem(void *(*alloc)(size_t), void (*release)(void *, size_t)) { (void)alloc; (void)release; }   // 安卓备用栈走 guest_signal.c，不接窗口尾部
void plat_fault_altstack_free(void) {
    s2a_android_altstack_free();
}

int plat_thread_stack_bounds(uintptr_t *low, uintptr_t *high) {
    if (!low || !high) return EINVAL;
    pthread_attr_t attr;
    int e = pthread_getattr_np(pthread_self(), &attr);
    if (e) return e;
    void *addr = NULL;
    size_t size = 0;
    e = pthread_attr_getstack(&attr, &addr, &size);
    pthread_attr_destroy(&attr);
    if (e) return e;
    if (!addr || !size) return EINVAL;
    *low = (uintptr_t)addr;
    *high = *low + size;
    return 0;
}

int plat_thread_self(plat_thread_t *out) {
    if (!out) return EINVAL;
    uintptr_t self = (uintptr_t)pthread_self();
    if (!self) return EIO;
    *out = (plat_thread_t)self;
    return 0;
}

// 游戏图形模式由 direct_session.c 在装载前冻结；诊断目标固定通用。
// 地址窗口尾部映射仍未实现，按既有路径退回普通栈/匿名映射。
#if !defined(S2A_ANDROID_GAME_RUNTIME)
int s2a_gfx_mode(void) { return 0; }  // Diagnostic only; game choice is frozen by direct_session.c.
uint64_t s2a_direct_lookup(const char *name) { (void)name; return 0; }
#endif
void *s2a_tail_map(uint64_t len, int user, int prot) { (void)len; (void)user; (void)prot; return NULL; }
void s2a_tail_unmap(void *p, uint64_t len, int user) { (void)user; if (p) munmap(p, len); }

#endif // !S2A_HOST_FIELDS_ONLY

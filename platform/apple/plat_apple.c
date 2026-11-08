// Apple implementation of the first plat.h batch.  This is the behaviour the
// current runtime/src code already relies on; it must not change during the
// extraction (only move behind plat_*).
#include "../plat.h"

#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef MAP_ANON
#define MAP_ANON MAP_ANONYMOUS
#endif
#ifndef MAP_NORESERVE
#define MAP_NORESERVE 0
#endif

#define PLAT_ALTSTACK_SIZE (256u << 10)

size_t plat_page_size(void) {
    long pg = sysconf(_SC_PAGESIZE);
    return pg > 0 ? (size_t)pg : 0;
}

static mach_timebase_info_data_t g_tb;

uint64_t plat_now_ns(void) {
    if (!g_tb.denom) {
        mach_timebase_info_data_t tb;
        if (mach_timebase_info(&tb) != 0 || !tb.denom) return 0;
        g_tb = tb;
    }
    return mach_absolute_time() * g_tb.numer / g_tb.denom;
}

int plat_thread_name(const char *name) { return name ? pthread_setname_np(name) : EINVAL; }

static int apple_restore_reserved(void *dst, size_t size) {
    // Keep dst reserved in the guest window; never hand it back to the system.
    if (!dst || !size) return EINVAL;
    void *p = mmap(dst, size, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED | MAP_NORESERVE, -1, 0);
    if (p == dst) return 0;
    int error = p == MAP_FAILED ? errno : EIO;
    if (p != MAP_FAILED) munmap(p, size);
    return error ? error : EIO;
}

static int apple_prot(uint32_t prot, int *out) {
    if (prot & ~(uint32_t)(PLAT_PROT_READ | PLAT_PROT_WRITE | PLAT_PROT_EXEC)) return EINVAL;
    int p = PROT_NONE;
    if (prot & PLAT_PROT_READ) p |= PROT_READ;
    if (prot & PLAT_PROT_WRITE) p |= PROT_WRITE;
    if (prot & PLAT_PROT_EXEC) p |= PROT_EXEC;
    *out = p;
    return 0;
}

static int apple_vm_error(kern_return_t kr) {
    switch (kr) {
    case KERN_INVALID_ADDRESS: return EFAULT;
    case KERN_PROTECTION_FAILURE: return EACCES;
    case KERN_NO_SPACE: return ENOMEM;
    default: return EIO;
    }
}

int plat_mem_read32(uint64_t addr, uint32_t *value) {
    if (!value) return EINVAL;
    uint32_t copy; vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, sizeof copy,
                                         (vm_address_t)(uintptr_t)&copy, &got);
    if (kr != KERN_SUCCESS) return apple_vm_error(kr);
    if (got != sizeof copy) return EIO;
    *value = copy;
    return 0;
}

int plat_mem_write32(uint64_t addr, uint32_t value) {
    kern_return_t kr = vm_write(mach_task_self(), (vm_address_t)addr,
                                (vm_offset_t)(uintptr_t)&value, sizeof value);
    return kr == KERN_SUCCESS ? 0 : apple_vm_error(kr);
}

uint8_t plat_guest_load8(uint64_t addr) { return __atomic_load_n((uint8_t *)(uintptr_t)addr, __ATOMIC_RELAXED); }
uint32_t plat_guest_load32(uint64_t addr) { return __atomic_load_n((uint32_t *)(uintptr_t)addr, __ATOMIC_RELAXED); }
uint64_t plat_guest_load64(uint64_t addr) { return __atomic_load_n((uint64_t *)(uintptr_t)addr, __ATOMIC_RELAXED); }
void plat_guest_store32(uint64_t addr, uint32_t value) { __atomic_store_n((uint32_t *)(uintptr_t)addr, value, __ATOMIC_RELAXED); }

int plat_vm_reserve(size_t size, size_t alignment, uint64_t limit, void **out) {
    if (!out) return EINVAL;
    size_t pg = plat_page_size();
    uint64_t lim = limit > (uint64_t)UINTPTR_MAX ? (uint64_t)UINTPTR_MAX : limit;
    if (!pg || !size || (size % pg) || alignment < pg || (alignment & (alignment - 1)) || (uint64_t)size > lim)
        return EINVAL;
    if (size > (size_t)-1 - alignment) return EINVAL;
    size_t total = size + alignment;
    int error = ENOMEM;
    for (unsigned i = 1; i <= 7; i++) {
        uint64_t hint = (lim / 8) * i;
        if (hint > UINTPTR_MAX || hint > lim - size) break;
        void *raw = mmap((void *)(uintptr_t)hint, total, PROT_NONE,
                        MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
        if (raw == MAP_FAILED) { error = errno; continue; }
        uintptr_t start = (uintptr_t)raw;
        uintptr_t aligned = (start + alignment - 1) & ~(uintptr_t)(alignment - 1);
        if (aligned < start || aligned > lim - size) { munmap(raw, total); continue; }
        size_t prefix = aligned - start, suffix = total - prefix - size;
        if (prefix && munmap(raw, prefix)) { error = errno; munmap(raw, total); return error; }
        if (suffix && munmap((void *)(aligned + size), suffix)) {
            error = errno; munmap((void *)aligned, total - prefix); return error;
        }
        *out = (void *)aligned;
        return 0;
    }
    return error;
}

int plat_vm_protect(void *addr, size_t size, uint32_t prot) {
    if (!addr || !size) return EINVAL;
    size_t pg = plat_page_size();
    if (!pg || ((uintptr_t)addr & (pg - 1)) || (size % pg)) return EINVAL;
    int p;
    int e = apple_prot(prot, &p);
    if (e) return e;
    return mprotect(addr, size, p) ? errno : 0;
}

int plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot) {
    if (!dst || !src || !size || dst == src) return EINVAL;
    size_t pg = plat_page_size();
    if (!pg) return ENOTSUP;
    if (((uintptr_t)dst & (pg - 1)) || ((uintptr_t)src & (pg - 1)) || (size % pg)) return EINVAL;
    int p;
    int e = apple_prot(prot, &p);
    if (e) return e;
    vm_address_t a = (vm_address_t)dst;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kern_return_t kr = vm_remap(mach_task_self(), &a, (vm_size_t)size, 0,
                                VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                                (vm_address_t)src, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        int re = apple_restore_reserved(dst, size);
        return re ? EIO : apple_vm_error(kr);
    }
    e = plat_vm_protect(dst, size, prot);
    if (e) { int re = apple_restore_reserved(dst, size); return re ? EIO : e; }
    return 0;
}

int plat_layout_override(const char *npdm, uint32_t as_type, uint64_t sysres,
                         uint64_t program_id, uint64_t window_base, uint64_t window_size,
                         struct s2a_layout *out, uint64_t *need, char *detail, size_t detail_size) {
    (void)npdm; (void)as_type; (void)sysres; (void)program_id; (void)window_base;
    (void)window_size; (void)out; (void)need; (void)detail; (void)detail_size;
    return ENOTSUP; // Apple uses the unchanged shared address-space algorithm.
}

int plat_tsd_init(void) {
    return 0;
}

uint64_t plat_tsd_base(void) {
#if defined(__aarch64__)
    uint64_t base;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(base));
    return base & ~7ull;
#else
    return 0;
#endif
}

int plat_tsd_offset(uint32_t key, uint64_t *out) {
    if (!out) return EINVAL;
    uint64_t off = (uint64_t)key * 8;
    if (!off) return EINVAL;
    *out = off;
    return 0;
}

int plat_fault_install(int sig, void (*fn)(int, siginfo_t *, void *), unsigned flags) {
    if (!fn || sig <= 0) return EINVAL;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = fn;
    sa.sa_flags = SA_SIGINFO;
    if (flags & PLAT_FAULT_ONSTACK) sa.sa_flags |= SA_ONSTACK;
    if (flags & PLAT_FAULT_RESTART) sa.sa_flags |= SA_RESTART;
    sigemptyset(&sa.sa_mask);
    return sigaction(sig, &sa, NULL) ? errno : 0;
}

static _Thread_local uint8_t *g_alt;
static _Thread_local size_t g_alt_len;
static void *(*g_alt_alloc)(size_t); static void (*g_alt_release)(void *, size_t);
void plat_fault_altstack_set_mem(void *(*alloc)(size_t), void (*release)(void *, size_t)) { g_alt_alloc = alloc; g_alt_release = release; }
static void alt_unmap(uint8_t *p, size_t len) { if (g_alt_release) g_alt_release(p, len); else munmap(p, len); }

int plat_fault_altstack_init(void) {
    if (g_alt) return 0;
    size_t pg = plat_page_size();
    if (!pg) return EINVAL;
    size_t len = pg + PLAT_ALTSTACK_SIZE;
    uint8_t *p = g_alt_alloc ? g_alt_alloc(len) : NULL;
    if (!p) { p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); if (p == MAP_FAILED) return errno; }
    if (mprotect(p, pg, PROT_NONE)) {
        int e = errno;
        alt_unmap(p, len);
        return e;
    }
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp = p + pg;
    ss.ss_size = PLAT_ALTSTACK_SIZE;
    ss.ss_flags = 0;
    if (sigaltstack(&ss, NULL)) {
        int e = errno;
        alt_unmap(p, len);
        return e;
    }
    g_alt = p;
    g_alt_len = len;
    return 0;
}

void plat_fault_altstack_free(void) {
    if (!g_alt) return;
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_flags = SS_DISABLE;
    sigaltstack(&ss, NULL);
    alt_unmap(g_alt, g_alt_len);
    g_alt = NULL;
    g_alt_len = 0;
}

int plat_thread_stack_bounds(uintptr_t *low, uintptr_t *high) {
    if (!low || !high) return EINVAL;
    pthread_t self = pthread_self();
    uintptr_t hi = (uintptr_t)pthread_get_stackaddr_np(self);
    size_t sz = pthread_get_stacksize_np(self);
    if (!hi || !sz) return EINVAL;
    *low = hi - sz;
    *high = hi;
    return 0;
}

int plat_thread_self(plat_thread_t *out) {
    if (!out) return EINVAL;
    mach_port_t mp = pthread_mach_thread_np(pthread_self());
    if (mp == MACH_PORT_NULL) return EIO;
    *out = (plat_thread_t)mp;
    return 0;
}

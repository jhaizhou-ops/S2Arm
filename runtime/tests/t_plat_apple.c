// Host-side smoke test for the Apple plat.h implementation.
#include "../../platform/plat.h"
#include "../include/s2a_native.h"
#include <assert.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define CHECK(cond, what) do { \
    if (!(cond)) { fprintf(stderr, "plat apple: FAILED %s (line %d)\n", what, __LINE__); return 1; } \
} while (0)

static volatile sig_atomic_t g_hit;
static volatile sig_atomic_t g_track_writes;
static void *g_track_page;
static size_t g_track_size;
static void tracked_fault(int sig, siginfo_t *si, void *ctx) {
    (void)ctx;
    if (sig != SIGBUS && sig != SIGSEGV) _exit(90);
    uintptr_t addr = (uintptr_t)si->si_addr, base = (uintptr_t)g_track_page;
    if (addr < base || addr >= base + g_track_size) _exit(91);
    g_track_writes++;
    if (mprotect(g_track_page, g_track_size, PROT_READ | PROT_WRITE)) _exit(92);
}

static void on_usr1(int sig, siginfo_t *si, void *ctx) {
    (void)sig;
    (void)si;
    (void)ctx;
    g_hit = 1;
}

static int protection(void *address) {
    mach_vm_address_t a = (mach_vm_address_t)address; mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t rc = mach_vm_region(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    assert(rc == KERN_SUCCESS && a <= (mach_vm_address_t)address && (mach_vm_address_t)address < a + size);
    return info.protection;
}
static void vm_tests(void) {
    size_t page = plat_page_size(); assert(page && !(page & (page - 1)));
    void *dst = NULL;
    assert(!plat_vm_reserve(page, page, 1ull << 39, &dst));
    assert(protection(dst) == VM_PROT_NONE);
    unsigned char *src = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    assert(src != MAP_FAILED); src[0] = 0x31;
    assert(!plat_vm_alias(dst, src, page, PLAT_PROT_READ));
    assert(protection(dst) == VM_PROT_READ && *(unsigned char *)dst == 0x31);
    src[0] = 0x72; assert(*(unsigned char *)dst == 0x72);
    assert(plat_vm_alias(dst, dst, page, PLAT_PROT_READ) == EINVAL);
    void *dead = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(dead != MAP_FAILED && !munmap(dead, page));
    assert(plat_vm_alias(dst, dead, page, PLAT_PROT_READ) != 0);
    assert(protection(dst) == VM_PROT_NONE);
    struct s2a_layout layout; uint64_t need = 0; char detail[8];
    assert(plat_layout_override("unused", 3, 0, 1, 0, 0, &layout, &need, detail, sizeof detail) == ENOTSUP);
    assert(!munmap(dst, page) && !munmap(src, page));

}

int main(void) {
    vm_tests();
    size_t pg = plat_page_size();
    CHECK(pg >= 4096 && (pg & (pg - 1)) == 0, "page size is a power of two");

    uint64_t a = plat_now_ns();
    usleep(2000);
    uint64_t b = plat_now_ns();
    CHECK(a && b && b > a, "monotonic clock advances");
    uint32_t value = 0x12345678, out = 0;
    CHECK(plat_mem_read32((uintptr_t)&value, &out) == 0 && out == value, "read32 valid");
    CHECK(plat_mem_write32((uintptr_t)&value, 0x87654321) == 0 && value == 0x87654321, "write32 valid");
    out = 0xdecafbad;
    CHECK(plat_mem_read32(1, &out) != 0 && out == 0xdecafbad, "read32 invalid leaves output unchanged");
    CHECK(plat_mem_read32((uintptr_t)&value, NULL) != 0, "read32 null output");
    CHECK(plat_mem_write32(1, 7) != 0, "write32 invalid");
    void *ro = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    CHECK(ro != MAP_FAILED && mprotect(ro, pg, PROT_READ) == 0, "read-only fixture");
    CHECK(plat_mem_write32((uintptr_t)ro, 7) != 0, "write32 read-only page");
    CHECK(munmap(ro, pg) == 0, "release read-only fixture");
    g_track_page = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    CHECK(g_track_page != MAP_FAILED, "tracked page allocation");
    g_track_size = pg;
    *(uint32_t *)g_track_page = 30;
    struct sigaction sa = {0}, old_bus, old_segv;
    sa.sa_sigaction = tracked_fault; sa.sa_flags = SA_SIGINFO; sigemptyset(&sa.sa_mask);
    CHECK(sigaction(SIGBUS, &sa, &old_bus) == 0 && sigaction(SIGSEGV, &sa, &old_segv) == 0, "install fake tracking fault");
    CHECK(mprotect(g_track_page, pg, PROT_READ) == 0, "protect tracked page");
    plat_guest_store32((uintptr_t)g_track_page, 60);
    CHECK(g_track_writes == 1 && *(uint32_t *)g_track_page == 60, "tracked guest store faults once and writes");
    CHECK(sigaction(SIGBUS, &old_bus, NULL) == 0 && sigaction(SIGSEGV, &old_segv, NULL) == 0, "restore fault handlers");
    CHECK(munmap(g_track_page, pg) == 0, "release tracked page");

    CHECK(plat_tsd_init() == 0, "tsd init");
    CHECK(plat_tsd_base() != 0, "tsd base");
    uint64_t off = 0;
    CHECK(plat_tsd_offset(1, &off) == 0 && off == 8, "tsd offset key 1");
    CHECK(plat_tsd_offset(0, &off) == EINVAL, "tsd offset key 0 rejected");

    plat_thread_t self = 0;
    CHECK(plat_thread_self(&self) == 0 && self != 0, "thread self");

    uintptr_t low = 0, high = 0;
    CHECK(plat_thread_stack_bounds(&low, &high) == 0 && low < high, "stack bounds");
    uintptr_t here = (uintptr_t)&low;
    CHECK(here > low && here < high, "current sp is inside the stack");

    CHECK(plat_fault_altstack_init() == 0, "altstack init");
    CHECK(plat_fault_altstack_init() == 0, "altstack init is idempotent");
    CHECK(plat_fault_install(SIGUSR1, on_usr1, PLAT_FAULT_ONSTACK) == 0, "install SIGUSR1");
    g_hit = 0;
    raise(SIGUSR1);
    CHECK(g_hit == 1, "SIGUSR1 handler ran");
    signal(SIGUSR1, SIG_DFL);
    plat_fault_altstack_free();
    plat_fault_altstack_free();

    puts("✓ t_plat_apple：page / clock / TSD / stack / signal / altstack 全过");
    return 0;
}

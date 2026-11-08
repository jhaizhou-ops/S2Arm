// Actual native xstack, entry.S and Bionic TSD. No replacement for stack switching.
#define _GNU_SOURCE
#include "direct_vk.h"
#include "tsd.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

extern void *sw_xstack_wrap(const char *, void *);
extern void sw_xstack_thread_init(uint64_t, uint64_t);
extern void sw_xstack_thread_fini(void);
extern void sw_call_on_stack(void (*fn)(void), uint64_t);
uint64_t gate_dispatch(uint64_t ret, uint64_t *regs) { (void)ret; (void)regs; abort(); }
void sw_thread_returned(void) { abort(); }

static uintptr_t host_low, host_high, guest_low, guest_high;
static unsigned hits;
static PFN_vkGetPhysicalDeviceProperties query;
static PFN_vkGetInstanceProcAddr gipa;

static void check(int condition) { if (!condition) { fprintf(stderr, "xstack verification failed\n"); exit(1); } }
static void VKAPI_CALL properties(VkPhysicalDevice physical, VkPhysicalDeviceProperties *out) {
    volatile unsigned local = 7;
    uintptr_t here = (uintptr_t)&local;
    check(here >= host_low && here < host_high && !(here >= guest_low && here < guest_high));
    check(physical == (VkPhysicalDevice)(uintptr_t)0x123);
    out->vendorID = 0x5143;
    hits++;
}
static PFN_vkVoidFunction symbol(const char *name) {
    if (!__builtin_strcmp(name, "vkGetPhysicalDeviceProperties")) return (PFN_vkVoidFunction)properties;
    if (!__builtin_strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)properties; // Replaced by bridge.
    return NULL;
}
static PFN_vkVoidFunction VKAPI_CALL instance_proc(VkInstance i, const char *name) { (void)i; return symbol(name); }
static PFN_vkVoidFunction VKAPI_CALL device_proc(VkDevice d, const char *name) { (void)d; return symbol(name); }
static void error(const char *name, VkResult r) { fprintf(stderr, "%s: %d\n", name, r); abort(); }
static void fatal(const char *name) { fprintf(stderr, "%s\n", name); abort(); }
static void block(void) {}
static const struct s2a_wsi_api *window(void *token) { (void)token; return NULL; }
static void guest(void) {
    volatile unsigned local = 9;
    uintptr_t here = (uintptr_t)&local;
    check(here >= guest_low && here < guest_high);
    VkPhysicalDeviceProperties out = {0};
    query((VkPhysicalDevice)(uintptr_t)0x123, &out);
    check(out.vendorID == 0x5143);
    PFN_vkGetPhysicalDeviceProperties dynamic = (PFN_vkGetPhysicalDeviceProperties)gipa((VkInstance)(uintptr_t)0x456, "vkGetPhysicalDeviceProperties");
    check(dynamic != NULL);
    out.vendorID = 0;
    dynamic((VkPhysicalDevice)(uintptr_t)0x123, &out);
    check(out.vendorID == 0x5143);
}

int main(void) {
    pthread_attr_t attr;
    check(pthread_getattr_np(pthread_self(), &attr) == 0);
    void *base; size_t size;
    check(pthread_attr_getstack(&attr, &base, &size) == 0);
    pthread_attr_destroy(&attr);
    host_low = (uintptr_t)base; host_high = host_low + size;
    size_t page = (size_t)sysconf(_SC_PAGESIZE), usable = 16 * 1024;
    void *mapping = mmap(NULL, usable + 2 * page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(mapping != MAP_FAILED);
    guest_low = (uintptr_t)mapping + page; guest_high = guest_low + usable;
    check(mprotect((void *)guest_low, usable, PROT_READ | PROT_WRITE) == 0);
    struct s2a_direct_vk_host h = {instance_proc, device_proc, symbol, sw_xstack_wrap, error, fatal, block, block, window, NULL};
    check(s2a_android_vk_configure(&h) == 0);
    query = (PFN_vkGetPhysicalDeviceProperties)s2a_vk_entry("vkGetPhysicalDeviceProperties");
    gipa = (PFN_vkGetInstanceProcAddr)s2a_vk_entry("vkGetInstanceProcAddr");
    check(query && gipa);
    uint64_t sp;
    __asm__ volatile("mov %0, sp" : "=r"(sp));
    sw_xstack_thread_init(sp - 4096, guest_high);
    for (int i = 0; i < 64; i++) sw_call_on_stack(guest, guest_high);
    sw_xstack_thread_fini();
    check(hits == 128);
    check(munmap(mapping, usable + 2 * page) == 0);
    printf("PASS actual xstack: 128 static/dynamic host calls from guarded 16 KiB guest stack\n");
    return 0;
}

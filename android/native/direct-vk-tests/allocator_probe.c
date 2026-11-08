// Production bridge + real xstack; controlled driver or actual libvulkan loader.
#define _GNU_SOURCE
#include "direct_vk.h"
#include "direct_callback.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

extern void *sw_xstack_wrap(const char *, void *);
extern void sw_xstack_thread_init(uint64_t, uint64_t);
extern void sw_xstack_thread_fini(void);
extern void sw_call_on_stack(void (*)(void), uint64_t);
uint64_t gate_dispatch(uint64_t ret, uint64_t *regs) { (void)ret; (void)regs; abort(); }
void sw_thread_returned(void) { abort(); }

static uintptr_t guest_low, guest_high, host_low, host_high;
static pthread_t caller;
static pthread_key_t test_tls;
static int user_tag, real_driver, block_open, fail_alloc;
static unsigned allocated, freed, notifications, reallocated;
static VkAllocationCallbacks stored;
static int terminal_mode;
static void *held_terminal;
static PFN_vkCreateInstance create;
static PFN_vkDestroyInstance destroy;
static PFN_vkWaitForFences wait_fences;
static void *library;
static void *(*allocate_host)(size_t, size_t);
static void (*free_host)(void *);
static void *(*reallocate_host)(void *, size_t, size_t);

static void check(int ok, const char *why) { if (!ok) { fprintf(stderr, "FAIL allocator %s\n", why); exit(1); } }
static void guest_check(void *data) {
    volatile unsigned local = 3;
    uintptr_t sp = (uintptr_t)&local;
    check(sp >= guest_low && sp < guest_high, "callback SP outside guest stack");
    check(data == &user_tag && pthread_equal(caller, pthread_self()), "callback thread/userData");
    check(pthread_getspecific(test_tls) == &user_tag && !block_open, "callback TLS/core ownership");
}
struct header { void *base; size_t size; };
__attribute__((noinline)) static void *host_alloc(size_t n, size_t alignment) {
    volatile unsigned char deep[24576];
    for (size_t j = 0; j < sizeof deep; j++) deep[j] = (unsigned char)(j ^ 0x79);
    check((uintptr_t)&deep[0] >= host_low && (uintptr_t)&deep[0] < host_high, "nested host SP");
    if (fail_alloc) return NULL;
    if (alignment < sizeof(void *)) alignment = sizeof(void *);
    check(alignment && !(alignment & (alignment - 1)), "allocation alignment");
    unsigned char *base = malloc(n + alignment + sizeof(struct header));
    if (!base) return NULL;
    uintptr_t at = ((uintptr_t)base + sizeof(struct header) + alignment - 1) & ~(alignment - 1);
    struct header h = {base, n}; memcpy((void *)(at - sizeof h), &h, sizeof h);
    for (size_t j = 0; j < sizeof deep; j++) check(deep[j] == (unsigned char)(j ^ 0x79), "nested host frame corrupted");
    return (void *)at;
}
static void host_free(void *p) {
    if (p) { struct header h; memcpy(&h, (char *)p - sizeof h, sizeof h); free(h.base); }
}
static void *host_realloc(void *p, size_t n, size_t a) {
    if (!n) { host_free(p); return NULL; }
    if (!p) return host_alloc(n, a);
    struct header h; memcpy(&h, (char *)p - sizeof h, sizeof h);
    void *next = host_alloc(n, a); if (!next) return NULL;
    memcpy(next, p, n < h.size ? n : h.size); host_free(p); return next;
}
static void *VKAPI_CALL guest_alloc(void *data, size_t n, size_t a, VkSystemAllocationScope scope) {
    guest_check(data); check(scope <= VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE, "allocation scope");
    allocated++; return allocate_host(n, a);
}
static void *VKAPI_CALL guest_realloc(void *data, void *p, size_t n, size_t a, VkSystemAllocationScope scope) {
    guest_check(data); check(scope <= VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE, "reallocation scope");
    reallocated++; return reallocate_host(p, n, a);
}
static void VKAPI_CALL guest_free(void *data, void *p) { guest_check(data); freed++; free_host(p); }
static void VKAPI_CALL guest_internal(void *data, size_t n, VkInternalAllocationType type, VkSystemAllocationScope scope) {
    guest_check(data); check(n > 0 && type == VK_INTERNAL_ALLOCATION_TYPE_EXECUTABLE && scope <= VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE, "internal notification arguments");
    if (!real_driver) check(n == 512 && scope == VK_SYSTEM_ALLOCATION_SCOPE_OBJECT, "controlled notification arguments");
    notifications++;
}
static VkAllocationCallbacks original(void) {
    VkAllocationCallbacks a = {&user_tag, guest_alloc, guest_realloc, guest_free, guest_internal, guest_internal}; return a;
}

static VKAPI_ATTR VkResult VKAPI_CALL fake_create(const VkInstanceCreateInfo *i, const VkAllocationCallbacks *a, VkInstance *out) {
    check(i && a && a->pfnAllocation && a->pUserData != &user_tag, "allocator was not adapted");
    volatile unsigned char canary[32768];
    for (size_t j = 0; j < sizeof canary; j++) canary[j] = (unsigned char)(j ^ 0x5a);
    stored = *a;
    void *p = a->pfnAllocation(a->pUserData, 64, 64, VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE);
    check(p && !((uintptr_t)p & 63), "guest allocation result"); memset(p, 0x38, 64);
    p = a->pfnReallocation(a->pUserData, p, 128, 64, VK_SYSTEM_ALLOCATION_SCOPE_OBJECT);
    check(p && !((uintptr_t)p & 63), "guest reallocation result");
    for (int j = 0; j < 64; j++) check(((unsigned char *)p)[j] == 0x38, "reallocation contents");
    fail_alloc = 1;
    check(!a->pfnReallocation(a->pUserData, p, 256, 64, VK_SYSTEM_ALLOCATION_SCOPE_OBJECT), "failed reallocation returns NULL");
    for (int j = 0; j < 64; j++) check(((unsigned char *)p)[j] == 0x38, "failed reallocation preserves original");
    fail_alloc = 0;
    void *extra = a->pfnReallocation(a->pUserData, NULL, 16, 16, VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
    check(extra != NULL, "NULL original reallocation");
    check(!a->pfnReallocation(a->pUserData, extra, 0, 16, VK_SYSTEM_ALLOCATION_SCOPE_COMMAND), "zero-size reallocation frees");
    a->pfnInternalAllocation(a->pUserData, 512, VK_INTERNAL_ALLOCATION_TYPE_EXECUTABLE, VK_SYSTEM_ALLOCATION_SCOPE_OBJECT);
    a->pfnInternalFree(a->pUserData, 512, VK_INTERNAL_ALLOCATION_TYPE_EXECUTABLE, VK_SYSTEM_ALLOCATION_SCOPE_OBJECT);
    a->pfnFree(a->pUserData, NULL); a->pfnFree(a->pUserData, p);
    for (size_t j = 0; j < sizeof canary; j++) check(canary[j] == (unsigned char)(j ^ 0x5a), "live driver frame corrupted");
    if(terminal_mode){held_terminal=a->pfnAllocation(a->pUserData,32,32,VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE);check(held_terminal!=NULL,"retained guest allocation");memset(held_terminal,0x5a,32);}
    *out = (VkInstance)(uintptr_t)0x123; return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL fake_destroy(VkInstance i, const VkAllocationCallbacks *a) {
    check(i == (VkInstance)(uintptr_t)0x123 && a && a->pUserData == stored.pUserData, "compatible allocator/lifetime");
    if(terminal_mode){
        void *p=a->pfnReallocation(a->pUserData,held_terminal,64,64,VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
        check(p && !((uintptr_t)p&63),"terminal realloc guest storage to aligned scratch");
        for(unsigned j=0;j<32;j++)check(((unsigned char*)p)[j]==0x5a,"terminal guest contents preserved");
        p=a->pfnReallocation(a->pUserData,p,128,64,VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);check(p!=NULL,"terminal scratch realloc");
        check(!a->pfnReallocation(a->pUserData,p,SIZE_MAX,64,VK_SYSTEM_ALLOCATION_SCOPE_COMMAND),"terminal failure returns NULL");
        for(unsigned j=0;j<32;j++)check(((unsigned char*)p)[j]==0x5a,"failed terminal realloc preserves original");
        a->pfnFree(a->pUserData,p);
        p=a->pfnAllocation(a->pUserData,17,128,VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
        check(p && !((uintptr_t)p&127),"terminal new allocation alignment");
        check(!a->pfnReallocation(a->pUserData,p,0,128,VK_SYSTEM_ALLOCATION_SCOPE_COMMAND),"terminal zero-size free");
        a->pfnInternalAllocation(a->pUserData,128,VK_INTERNAL_ALLOCATION_TYPE_EXECUTABLE,VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
        a->pfnInternalFree(a->pUserData,128,VK_INTERNAL_ALLOCATION_TYPE_EXECUTABLE,VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
    }
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_wait(VkDevice d, uint32_t n, const VkFence *f, VkBool32 all, uint64_t timeout) {
    (void)d; (void)n; (void)f; (void)all; (void)timeout;
    check(block_open == 1, "wait must release core");
    void *p = stored.pfnAllocation(stored.pUserData, 32, 16, VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
    if (!p) return VK_ERROR_OUT_OF_HOST_MEMORY;
    stored.pfnFree(stored.pUserData, p); return VK_SUCCESS;
}
static PFN_vkVoidFunction symbol(const char *name) {
    if (real_driver) return (PFN_vkVoidFunction)dlsym(library, name);
    if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)fake_create;
    if (!strcmp(name, "vkDestroyInstance")) return (PFN_vkVoidFunction)fake_destroy;
    if (!strcmp(name, "vkWaitForFences")) return (PFN_vkVoidFunction)fake_wait;
    return NULL;
}
static PFN_vkVoidFunction VKAPI_CALL instance_proc(VkInstance i, const char *name) { (void)i; return symbol(name); }
static PFN_vkVoidFunction VKAPI_CALL device_proc(VkDevice d, const char *name) { (void)d; return symbol(name); }
static void report(const char *name, VkResult result) { fprintf(stderr, "API result: %s %d\n", name, result); }
static void fatal(const char *why) { fprintf(stderr, "fatal: %s\n", why); abort(); }
static void begin(void) { check(!block_open, "double block begin"); block_open = 1; }
static void end(void) { check(block_open, "block end without begin"); block_open = 0; }
static const struct s2a_wsi_api *window(void *token) { (void)token; return NULL; }

static void guest_body(void) {
    VkAllocationCallbacks a = original();
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance i = VK_NULL_HANDLE;
    check(create(&ci, &a, &i) == VK_SUCCESS && i, "create instance with guest allocator");
    memset(&a, 0, sizeof a); // Driver's copied callbacks must outlive this local struct.
    if (!real_driver) {
        check(wait_fences((VkDevice)(uintptr_t)1, 0, NULL, 1, 1) == VK_SUCCESS && !block_open, "stored callback during wait");
        fail_alloc = 1;
        check(wait_fences((VkDevice)(uintptr_t)1, 0, NULL, 1, 1) == VK_ERROR_OUT_OF_HOST_MEMORY && !block_open, "NULL allocation propagates");
        fail_alloc = 0;
    }
    VkAllocationCallbacks compatible = original();
    if(!terminal_mode)destroy(i, &compatible);
}

int main(int argc, char **argv) {
    terminal_mode=argc>1&&(!strcmp(argv[1],"terminal")||!strcmp(argv[1],"terminal-controlled"));
    real_driver = (terminal_mode && strcmp(argv[1],"terminal-controlled")) || (argc > 1 && !strcmp(argv[1], "real"));
    caller = pthread_self(); check(!pthread_key_create(&test_tls, NULL), "TLS key");
    check(!pthread_setspecific(test_tls, &user_tag), "TLS value");
    pthread_attr_t attr; void *base; size_t length;
    check(!pthread_getattr_np(caller, &attr), "thread attributes");
    check(!pthread_attr_getstack(&attr, &base, &length), "host stack bounds"); pthread_attr_destroy(&attr);
    host_low = (uintptr_t)base; host_high = host_low + length;
    size_t page = (size_t)sysconf(_SC_PAGESIZE), size = 64 * 1024;
    void *mapping = mmap(NULL, size + 2 * page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(mapping != MAP_FAILED, "guest mapping"); guest_low = (uintptr_t)mapping + page; guest_high = guest_low + size;
    check(!mprotect((void *)guest_low, size, PROT_READ | PROT_WRITE), "guest stack protection");
    if (real_driver) { library = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL); check(library != NULL, "actual loader"); }
    struct s2a_direct_vk_host h = {real_driver ? (PFN_vkGetInstanceProcAddr)symbol("vkGetInstanceProcAddr") : instance_proc,
        real_driver ? (PFN_vkGetDeviceProcAddr)symbol("vkGetDeviceProcAddr") : device_proc,
        symbol, sw_xstack_wrap, report, fatal, begin, end, window, s2a_android_vk_guest_callback};
    check(!s2a_android_vk_configure(&h), "bridge configure");
    allocate_host = sw_xstack_wrap("probe_host_alloc", host_alloc);
    reallocate_host = sw_xstack_wrap("probe_host_realloc", host_realloc);
    free_host = sw_xstack_wrap("probe_host_free", host_free);
    create = (PFN_vkCreateInstance)s2a_vk_entry("vkCreateInstance"); destroy = (PFN_vkDestroyInstance)s2a_vk_entry("vkDestroyInstance");
    wait_fences = (PFN_vkWaitForFences)s2a_vk_entry("vkWaitForFences");
    check(create && destroy, "entrypoints");
    uint64_t sp; __asm__ volatile("mov %0, sp" : "=r"(sp));
    sw_xstack_thread_init(sp - 4096, guest_high);
    sw_call_on_stack(guest_body, guest_high);
    sw_xstack_thread_fini();
    if(terminal_mode){
        unsigned before=freed;
        check(s2a_android_vk_terminal_drain()==0 && s2a_android_vk_stop()==0,"terminal driver drain");
        check(freed==before,"terminal cleanup invoked a frozen guest allocator");
    }
    check(allocated && freed && !block_open, "callbacks actually executed");
    if (!real_driver) check(notifications == 2 && reallocated == 4, "all callback signatures");
    if (argc > 1 && !strcmp(argv[1], "wrong-context")) stored.pfnAllocation(stored.pUserData, 16, 16, VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
    check(!munmap(mapping, size + 2 * page), "stack unmap"); pthread_key_delete(test_tls);
    printf("PASS %s allocator: alloc=%u realloc=%u free=%u notifications=%u; actual xstack/TLS/nested host calls\n",
        real_driver ? "actual-driver" : "controlled-driver", allocated, reallocated, freed, notifications);
    return 0;
}

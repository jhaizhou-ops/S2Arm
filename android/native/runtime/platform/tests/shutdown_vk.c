// Vulkan shutdown-phase cases for the real thread/fault/lifecycle consumer.
// Production direct_vk.c is compiled unchanged with the game-runtime stop path;
// only the driver entrypoints and the guest allocator are fixtures. The guest
// allocator models a legal reverse callback that may enter an SVC.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define S2A_ANDROID_GAME_RUNTIME 1
#ifndef S2A_SHUTDOWN_VK_SOURCE
#define S2A_SHUTDOWN_VK_SOURCE "../../../direct_vk.c"
#endif
#include S2A_SHUTDOWN_VK_SOURCE

uint64_t now_ns(void);
int s2a_svc_stopping(void);
void s2a_core_block_begin(void);
void s2a_core_block_end(void);
void s2a_android_guest_park_forever(void) __attribute__((noreturn));

enum { VK_CASE_SVC = 1, VK_CASE_CORE, VK_CASE_PASSTHROUGH, VK_CASE_OWNER };
_Atomic uint64_t s2a_shutdown_vk_start_ns;
_Atomic int s2a_shutdown_vk_release, s2a_shutdown_vk_entered;
static _Atomic int vk_case, guest_callbacks;
static const VkAllocationCallbacks *stored;
static VkDevice const fake_device = (VkDevice)(uintptr_t)0x10;

static void vk_mark(const char *text) { if (write(STDOUT_FILENO, text, strlen(text)) < 0) _exit(87); }

// Guest allocator body: a lock-protected heap whose slow path is an SVC.
static void guest_svc(void) {
    if (s2a_svc_stopping()) { vk_mark("vk-callback-parked-in-svc\n"); s2a_android_guest_park_forever(); }
}
static uint64_t guest_allocate(const uint64_t *a) {
    guest_svc();
    void *p = NULL;
    if (posix_memalign(&p, a[2] < 16 ? 16 : a[2], a[1] ? a[1] : 1)) return 0;
    atomic_fetch_add(&guest_callbacks, 1);
    return (uint64_t)(uintptr_t)p;
}
static uint64_t guest_reallocate(const uint64_t *a) { guest_svc(); return (uint64_t)(uintptr_t)realloc((void *)(uintptr_t)a[1], a[2]); }
static uint64_t guest_free(const uint64_t *a) { guest_svc(); free((void *)(uintptr_t)a[1]); return 0; }
static uint64_t guest_call(void *function, const uint64_t args[6]) {
    return ((uint64_t (*)(const uint64_t *))(uintptr_t)function)(args);
}

// The driver blocks until the case's interleaving point, then legally calls the
// allocator it was given (explicitly, or as the parent allocator).
static void wait_point(void) {
    atomic_store(&s2a_shutdown_vk_entered, 1);
    for (;;) {
        int c = atomic_load(&vk_case);
        if (c == VK_CASE_PASSTHROUGH ? s2a_svc_stopping() : c == VK_CASE_OWNER ? atomic_load(&s2a_shutdown_vk_release) != 0 :
            atomic_load(&s2a_shutdown_vk_start_ns) && now_ns() >= atomic_load(&s2a_shutdown_vk_start_ns) + 50000000ull) return;
        usleep(200);
    }
}
static void reverse_callbacks(void) {
    void *p = stored->pfnAllocation(stored->pUserData, 64, 16, VK_SYSTEM_ALLOCATION_SCOPE_COMMAND);
    stored->pfnFree(stored->pUserData, p);
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_create_fence(VkDevice d, const VkFenceCreateInfo *info,
    const VkAllocationCallbacks *allocator, VkFence *out) {
    (void)d; (void)info;
    stored = allocator;
    if (atomic_load(&vk_case) == VK_CASE_SVC) wait_point();
    reverse_callbacks();
    *out = (VkFence)(uintptr_t)(0x1000 + atomic_load(&guest_callbacks));
    return VK_SUCCESS;
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_wait(VkDevice d, uint32_t n, const VkFence *f, VkBool32 all, uint64_t timeout) {
    (void)d; (void)n; (void)f; (void)all; (void)timeout;
    wait_point(); reverse_callbacks(); return VK_SUCCESS;
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_reset(VkDevice d, uint32_t n, const VkFence *f) {
    (void)d; (void)n; (void)f;
    wait_point(); reverse_callbacks(); return VK_SUCCESS;
}
static PFN_vkVoidFunction fake_symbol(const char *name) {
    if (!strcmp(name, "vkCreateFence")) return (PFN_vkVoidFunction)(uintptr_t)fake_create_fence;
    if (!strcmp(name, "vkWaitForFences")) return (PFN_vkVoidFunction)(uintptr_t)fake_wait;
    if (!strcmp(name, "vkResetFences")) return (PFN_vkVoidFunction)(uintptr_t)fake_reset;
    return NULL;
}
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL fake_instance_proc(VkInstance i, const char *name) { (void)i; (void)name; return NULL; }
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL fake_device_proc(VkDevice d, const char *name) { (void)d; (void)name; return NULL; }
static void *fake_wrap(const char *name, void *function) { (void)name; return function; }
static void fake_error(const char *operation, VkResult result) { fprintf(stderr, "[fixture] vk error %s %d\n", operation, result); }
static void fake_fatal(const char *operation) { fprintf(stderr, "[fixture] vk fatal %s\n", operation); _exit(90); }
static const struct s2a_wsi_api *fake_window(void *token) { (void)token; return NULL; }

static const VkAllocationCallbacks guest = {(void *)(uintptr_t)0x5a,
    (PFN_vkAllocationFunction)(uintptr_t)guest_allocate, (PFN_vkReallocationFunction)(uintptr_t)guest_reallocate,
    (PFN_vkFreeFunction)(uintptr_t)guest_free, NULL, NULL};

// Configures the production frontend and records the guest allocator through
// one admitted vkCreateFence, before the interleaving case is armed.
int s2a_shutdown_vk_setup(int kind) {
    struct s2a_direct_vk_host h = {fake_instance_proc, fake_device_proc, fake_symbol, fake_wrap, fake_error,
        fake_fatal, s2a_core_block_begin, s2a_core_block_end, fake_window, guest_call};
    int error = s2a_android_vk_configure(&h);
    if (error) return error;
    VkFenceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    PFN_vkCreateFence create = (PFN_vkCreateFence)(uintptr_t)s2a_vk_entry("vkCreateFence");
    if (!create || create(fake_device, &info, &guest, &fence) != VK_SUCCESS || atomic_load(&guest_callbacks) != 1) return EIO;
    atomic_store(&vk_case, kind);
    return 0;
}
// Runs the armed case's call on this thread. A token call parks at its final
// finish_call; the passthrough case parks inside its reverse callback.
void s2a_shutdown_vk_call(void) {
    VkFence fence = (VkFence)(uintptr_t)0x1001;
    VkFenceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    int c = atomic_load(&vk_case);
    if (c == VK_CASE_SVC) ((PFN_vkCreateFence)(uintptr_t)s2a_vk_entry("vkCreateFence"))(fake_device, &info, &guest, &fence);
    else if (c == VK_CASE_PASSTHROUGH) ((PFN_vkResetFences)(uintptr_t)s2a_vk_entry("vkResetFences"))(fake_device, 1, &fence);
    else ((PFN_vkWaitForFences)(uintptr_t)s2a_vk_entry("vkWaitForFences"))(fake_device, 1, &fence, VK_TRUE, UINT64_MAX);
}

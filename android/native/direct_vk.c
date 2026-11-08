// Vulkan structs use the LP64 AAPCS64 layout on Switch and Android. Allocation
// callbacks use a same-thread reverse stack bridge; other callback-bearing API
// needs explicit adaptation. All entrypoints are handed out through host.wrap.
#include "direct_vk.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static struct s2a_direct_vk_host host;
static _Atomic int configured;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static VkInstance instance;
static VkDevice device;
static int vi_enabled;
static VkSurfaceKHR surface;
static const struct s2a_wsi_api *surface_api;
static struct s2a_wsi_state surface_state;
static _Atomic uint64_t presents;
static _Thread_local unsigned blocking;
static _Atomic uint64_t allocator_calls;
static _Atomic int terminating;
// 收尾一开始就停止受理客体的 Vulkan 调用：等到托管层关显卡时才挡，
// 客体已经又交了几十帧，销毁时必然和这些调用并发。
static _Atomic int vk_quiescing;
#define VK_GUEST_STOPPED() (atomic_load_explicit(&terminating, memory_order_acquire) || \
                            atomic_load_explicit(&vk_quiescing, memory_order_acquire))
// 收尾时把调用线程停住，而不是回一个错误：总线/图形调用失败会让游戏自己走 abort 路径
// （真机上是 guest 侧 SIGABRT）。与 gate.c 停系统调用用的是同一个终局停法。
static void vk_guest_stop(void) {
#if defined(S2A_ANDROID_GAME_RUNTIME)
    void s2a_android_guest_park_forever(void) __attribute__((noreturn));
    s2a_android_guest_park_forever();
#endif
}
// 客体面向的 Vulkan 入口正在驱动里的线程数。终止清场只能在它归零后动设备：
// 客体线程仍在驱动调用里时销毁 device/命令池，真机上表现为在驱动内部卡死或直接 abort。
static _Atomic int guest_inflight;
// 在途调用按线程登记名字：收尾时只报「还有 1 个」不足以判断是卡在 acquire、等待还是提交。
struct inflight_call { _Atomic(uintptr_t) thread; _Atomic(const char *) name; };
static struct inflight_call inflight_calls[64];
static _Thread_local int inflight_slot = -1;
static _Thread_local unsigned call_depth;
static pthread_mutex_t call_gate = PTHREAD_MUTEX_INITIALIZER;
// Admission and closing share this short lock. Never hold it across a driver
// call or a reverse guest allocator callback. A nested callback belongs to its
// already admitted outer call and must unwind before that thread can park.
static int enter_call(const char *name) {
    pthread_mutex_lock(&call_gate);
    if (VK_GUEST_STOPPED() && !call_depth) {
        pthread_mutex_unlock(&call_gate);
        vk_guest_stop();
        return 0;
    }
    if (call_depth++) { pthread_mutex_unlock(&call_gate); return 1; }
    atomic_fetch_add_explicit(&guest_inflight, 1, memory_order_acq_rel);
    int slot = inflight_slot;
    if (slot < 0) {
        for (int i = 0; i < 64; i++) {
            uintptr_t empty = 0;
            if (atomic_compare_exchange_strong(&inflight_calls[i].thread, &empty, (uintptr_t)pthread_self())) { slot = i; break; }
        }
        inflight_slot = slot;
    }
    if (slot >= 0) atomic_store(&inflight_calls[slot].name, name);
    pthread_mutex_unlock(&call_gate);
    return 1;
}
static void finish_call(void) {
    pthread_mutex_lock(&call_gate);
    if (!call_depth) { pthread_mutex_unlock(&call_gate); abort(); }
    int outermost = !--call_depth;
    if (outermost) {
        if (inflight_slot >= 0) atomic_store(&inflight_calls[inflight_slot].name, (const char *)0);
        atomic_fetch_sub_explicit(&guest_inflight, 1, memory_order_acq_rel);
    }
    int stopped = outermost && VK_GUEST_STOPPED();
    pthread_mutex_unlock(&call_gate);
    // No WSI/driver/ledger lock or guest memory access may remain at this point.
    // Parking inside vi_acquire would bypass this single accounting epilogue.
    if (stopped) vk_guest_stop();
}
// Waiting releases the virtual core, but restoring it can itself wait at the
// native writer census. Finish the GPU call's token first, with all WSI locks
// released; a terminal park never needs to resume guest execution or its core.
static int enter_blocked_call(const char *name) {
    if (!enter_call(name)) return 0;
    host.block_begin();
    blocking++;
    return 1;
}
static void finish_blocked_call(void) {
    blocking--;
    finish_call();
    host.block_end();
}
// 细化到具体驱动调用：只报「停在 vkQueuePresentKHR」仍然分不清是等锁、等 GPU 还是卡在上屏。
static void note_call_stage(const char *stage) {
    if (inflight_slot >= 0) atomic_store(&inflight_calls[inflight_slot].name, stage);
}
static void report_inflight_calls(void) {
    for (int i = 0; i < 64; i++) {
        const char *name = atomic_load(&inflight_calls[i].name);
        if (name) fprintf(stderr, "[vk-direct] 终止清场：线程 %d 仍停在 %s\n", i, name);
    }
}
static _Atomic uint64_t quarantined_frees, quarantined_notifications;
static const VkAllocationCallbacks *instance_allocator, *device_allocator, *surface_allocator;
static int terminal_error;
static _Noreturn void fatal(const char *name);

struct allocator_context { VkAllocationCallbacks original, bridge; };
static struct allocator_context allocators[256];
static unsigned allocator_count;
static pthread_mutex_t allocator_lock = PTHREAD_MUTEX_INITIALIZER;
#include "direct_allocator.inc"

// Reverse callbacks live inside a driver frame. Passthrough commands take no
// token, yet a driver may still call the parent pool/device/instance allocator
// from them (Vulkan host-memory rules), so every reverse frame is counted here,
// including its virtual-core restore. A frame frozen by a terminal stop gate is
// always inside this window; terminal_drain refuses to destroy while it is open.
static _Thread_local unsigned callback_depth;
static _Atomic int callback_in_guest;
static uint64_t invoke_allocator(struct allocator_context *ctx, void *fn, const uint64_t values[5]) {
    uint64_t args[6] = {(uint64_t)(uintptr_t)ctx->original.pUserData,
        values[0], values[1], values[2], values[3], values[4]};
    callback_depth++;
    atomic_fetch_add_explicit(&callback_in_guest, 1, memory_order_acq_rel);
    // The driver may allocate while waiting. Guest SDK code needs its virtual
    // core back, then the driver resumes in the original blocked state.
    if (blocking) host.block_end();
    atomic_fetch_add_explicit(&allocator_calls, 1, memory_order_relaxed);
    uint64_t result = host.guest_call(fn, args);
    if (blocking) host.block_begin();
    atomic_fetch_sub_explicit(&callback_in_guest, 1, memory_order_acq_rel);
    callback_depth--;
    return result;
}
static void *VKAPI_CALL allocate(void *data, size_t size, size_t alignment, VkSystemAllocationScope scope) {
    if(atomic_load(&terminating))return terminal_allocate(size,alignment);
    struct allocator_context *ctx = data;
    const uint64_t args[5] = {size, alignment, (uint32_t)scope, 0, 0};
    void *p=(void *)(uintptr_t)invoke_allocator(ctx, (void *)ctx->original.pfnAllocation, args);
    allocation_remember(p,size,0);return p;
}
static void *VKAPI_CALL reallocate(void *data, void *old, size_t size, size_t alignment, VkSystemAllocationScope scope) {
    if(atomic_load(&terminating))return terminal_reallocate(old,size,alignment);
    struct allocator_context *ctx = data;
    const uint64_t args[5] = {(uint64_t)(uintptr_t)old, size, alignment, (uint32_t)scope, 0};
    void *p=(void *)(uintptr_t)invoke_allocator(ctx, (void *)ctx->original.pfnReallocation, args);
    if(p||!size){if(old)allocation_find(old,NULL,1);allocation_remember(p,size,0);}return p;
}
static void VKAPI_CALL free_allocation(void *data, void *memory) {
    if(atomic_load(&terminating)){terminal_free(memory);return;}
    struct allocator_context *ctx = data;
    const uint64_t args[5] = {(uint64_t)(uintptr_t)memory, 0, 0, 0, 0};
    (void)invoke_allocator(ctx, (void *)ctx->original.pfnFree, args);
    if(memory)allocation_find(memory,NULL,1);
}
static void VKAPI_CALL internal_allocation(void *data, size_t size, VkInternalAllocationType type, VkSystemAllocationScope scope) {
    if(atomic_load(&terminating)){atomic_fetch_add(&quarantined_notifications,1);return;}
    struct allocator_context *ctx = data;
    const uint64_t args[5] = {size, (uint32_t)type, (uint32_t)scope, 0, 0};
    (void)invoke_allocator(ctx, (void *)ctx->original.pfnInternalAllocation, args);
}
static void VKAPI_CALL internal_free(void *data, size_t size, VkInternalAllocationType type, VkSystemAllocationScope scope) {
    if(atomic_load(&terminating)){atomic_fetch_add(&quarantined_notifications,1);return;}
    struct allocator_context *ctx = data;
    const uint64_t args[5] = {size, (uint32_t)type, (uint32_t)scope, 0, 0};
    (void)invoke_allocator(ctx, (void *)ctx->original.pfnInternalFree, args);
}
static VkResult adapt_allocator(const VkAllocationCallbacks *source, const VkAllocationCallbacks **out) {
    *out = NULL;
    if (!source) return VK_SUCCESS;
    if (!host.guest_call) return VK_ERROR_FEATURE_NOT_PRESENT;
    if (!source->pfnAllocation || !source->pfnReallocation || !source->pfnFree ||
        (!!source->pfnInternalAllocation != !!source->pfnInternalFree)) return VK_ERROR_INITIALIZATION_FAILED;
    _Static_assert(sizeof(VkAllocationCallbacks) == 6 * sizeof(void *), "allocator ABI changed");
    pthread_mutex_lock(&allocator_lock);
    unsigned i = 0;
    while (i < allocator_count && memcmp(source, &allocators[i].original, sizeof *source)) i++;
    if (i == sizeof allocators / sizeof *allocators) {
        pthread_mutex_unlock(&allocator_lock); return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    if (i == allocator_count) {
        struct allocator_context *ctx = &allocators[i];
        ctx->original = *source;
        ctx->bridge = (VkAllocationCallbacks){ctx, allocate, reallocate, free_allocation,
            source->pfnInternalAllocation ? internal_allocation : NULL,
            source->pfnInternalFree ? internal_free : NULL};
        allocator_count++;
    }
    *out = &allocators[i].bridge;
    pthread_mutex_unlock(&allocator_lock);
    return VK_SUCCESS;
}

uint64_t s2a_android_vk_presents(void) { return atomic_load(&presents); }
int s2a_android_vk_stop(void) {
    pthread_mutex_lock(&lock);
    int result = terminal_error ? terminal_error : instance || device || surface ? EBUSY : 0;
    pthread_mutex_unlock(&lock);
    return result;
}

// Sticky even before configuration: configure checks the same bit under
// call_gate, so a session can never become configured after shutdown began.
int s2a_android_vk_quiesce(void) {
    pthread_mutex_lock(&call_gate);
    atomic_store_explicit(&vk_quiescing, 1, memory_order_release);
    int live = atomic_load_explicit(&configured, memory_order_acquire);
    int inflight = atomic_load_explicit(&guest_inflight, memory_order_acquire);
    pthread_mutex_unlock(&call_gate);
    return live ? inflight : -1;
}

int s2a_android_vk_configure(const struct s2a_direct_vk_host *h) {
    if (!h || !h->instance_proc || !h->device_proc || !h->symbol || !h->wrap ||
        !h->error || !h->fatal || !h->block_begin || !h->block_end || !h->window) return EINVAL;
    pthread_mutex_lock(&lock);
    pthread_mutex_lock(&call_gate);
    int result = atomic_load(&configured) ? EALREADY : atomic_load(&vk_quiescing) ? ECANCELED : 0;
    if (!result) { host = *h; atomic_store_explicit(&configured, 1, memory_order_release); }
    pthread_mutex_unlock(&call_gate);
    pthread_mutex_unlock(&lock);
    return result;
}

static VkResult error(const char *name, VkResult result) {
    host.error(name, result);
    return result;
}

static _Noreturn void fatal(const char *name) {
    host.fatal(name);
    abort(); // A returning error callback cannot turn a void failure into success.
}

static PFN_vkVoidFunction raw(const char *name) {
    PFN_vkVoidFunction p = host.symbol(name);
    // Android loaders need not export extension symbols via dlsym. The scope's
    // dispatch lookup is authoritative, including promoted KHR entrypoints.
    if (!p && device) p = host.device_proc(device, name);
    if (!p && instance) p = host.instance_proc(instance, name);
    if (!p) fatal(name);
    return p;
}

#include "direct_wsi.inc"
#include "direct_objects.inc"

static int has_instance_extension(const char *name) {
    PFN_vkEnumerateInstanceExtensionProperties enumerate=(PFN_vkEnumerateInstanceExtensionProperties)raw("vkEnumerateInstanceExtensionProperties");
    uint32_t n=0;if(enumerate(NULL,&n,NULL)!=VK_SUCCESS||n>512)return 0;
    VkExtensionProperties properties[512];if(enumerate(NULL,&n,properties)!=VK_SUCCESS)return 0;
    for(unsigned j=0;j<n;j++)if(!strcmp(properties[j].extensionName,name))return 1;
    return 0;
}
static int has_device_extension(VkPhysicalDevice p,const char *name){
    PFN_vkEnumerateDeviceExtensionProperties enumerate=(PFN_vkEnumerateDeviceExtensionProperties)raw("vkEnumerateDeviceExtensionProperties");
    uint32_t n=0;if(enumerate(p,NULL,&n,NULL)!=VK_SUCCESS||n>1024)return 0;
    VkExtensionProperties properties[1024];if(enumerate(p,NULL,&n,properties)!=VK_SUCCESS)return 0;
    for(unsigned j=0;j<n;j++)if(!strcmp(properties[j].extensionName,name))return 1;
    return 0;
}
static VKAPI_ATTR void VKAPI_CALL format_properties(VkPhysicalDevice p,VkFormat format,VkFormatProperties *out){
    // The guest's format census includes IMG formats even on devices without
    // that extension. Report unsupported features without issuing an invalid
    // host query. This does not claim any PVRTC decoding capability.
    if(format>=VK_FORMAT_PVRTC1_2BPP_UNORM_BLOCK_IMG && format<=VK_FORMAT_PVRTC2_4BPP_SRGB_BLOCK_IMG &&
        !has_device_extension(p,VK_IMG_FORMAT_PVRTC_EXTENSION_NAME)){
        memset(out,0,sizeof *out);return;
    }
    ((PFN_vkGetPhysicalDeviceFormatProperties)raw("vkGetPhysicalDeviceFormatProperties"))(p,format,out);
}

// These names take no allocation-callback argument and are exported without an
// admission token. The driver may still call a parent pool/device/instance
// allocator from them; such reverse frames are counted only by
// invoke_allocator, so shutdown cannot drain them and terminal_drain fails
// closed (EBUSY) if one was frozen. Driver availability is still checked in the
// actual global/instance/device scope.
static const char *const passthrough[] = {
    "vkAllocateCommandBuffers", "vkAllocateDescriptorSets", "vkBeginCommandBuffer",
    "vkBindBufferMemory", "vkBindBufferMemory2", "vkBindImageMemory", "vkBindImageMemory2",
    "vkBindBufferMemory2KHR", "vkBindImageMemory2KHR",
    "vkCmdBeginRenderPass", "vkCmdBindDescriptorSets", "vkCmdBindIndexBuffer", "vkCmdBindPipeline",
    "vkCmdBindVertexBuffers", "vkCmdCopyBuffer", "vkCmdCopyBufferToImage", "vkCmdDrawIndexed",
    "vkCmdEndRenderPass", "vkCmdPipelineBarrier", "vkCmdSetScissor", "vkCmdSetViewport",
    "vkEndCommandBuffer", "vkEnumerateDeviceExtensionProperties", "vkEnumerateDeviceLayerProperties",
    "vkEnumerateInstanceLayerProperties", "vkEnumeratePhysicalDevices", "vkFlushMappedMemoryRanges",
    "vkFreeCommandBuffers", "vkGetBufferMemoryRequirements", "vkGetBufferMemoryRequirements2",
    "vkGetBufferMemoryRequirements2KHR", "vkGetImageMemoryRequirements2KHR",
    "vkGetDeviceQueue", "vkGetFenceStatus", "vkGetImageMemoryRequirements",
    "vkGetImageMemoryRequirements2", "vkGetImageSparseMemoryRequirements", "vkGetPhysicalDeviceFeatures2",
    "vkGetPhysicalDeviceFormatProperties", "vkGetPhysicalDeviceImageFormatProperties",
    "vkGetPhysicalDeviceMemoryProperties", "vkGetPhysicalDeviceMemoryProperties2",
    "vkGetPhysicalDeviceProperties", "vkGetPhysicalDeviceProperties2", "vkGetPhysicalDeviceQueueFamilyProperties",
    "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", "vkGetPhysicalDeviceSurfaceFormatsKHR",
    "vkGetPhysicalDeviceSurfacePresentModesKHR", "vkGetPhysicalDeviceSurfaceSupportKHR",
    "vkGetSwapchainImagesKHR", "vkInvalidateMappedMemoryRanges", "vkMapMemory",
    "vkResetCommandPool", "vkResetFences", "vkUnmapMemory",
    "vkUpdateDescriptorSetWithTemplate", "vkUpdateDescriptorSetWithTemplateKHR",
};

static VkResult create_instance_admitted(const VkInstanceCreateInfo *info,
    const VkAllocationCallbacks *allocator, VkInstance *out) {
    if (!info || !out || info->sType != VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO ||
        (info->enabledExtensionCount && !info->ppEnabledExtensionNames))
        return error("vkCreateInstance arguments", VK_ERROR_INITIALIZATION_FAILED);
    // Debug callbacks and callbacks in pNext cannot safely cross the guest ABI yet.
    const VkAllocationCallbacks *adapted;
    VkResult adapted_result = adapt_allocator(allocator, &adapted);
    if (adapted_result != VK_SUCCESS) return error("vkCreateInstance guest allocator", adapted_result);
    if (info->pNext) {
        const VkBaseInStructure *next = info->pNext;
        fprintf(stderr, "[vk-direct] instance pNext sType=%u\n", (unsigned)next->sType);
        return error("vkCreateInstance pNext", VK_ERROR_FEATURE_NOT_PRESENT);
    }
    if (info->enabledExtensionCount > 256) return error("vkCreateInstance extensions", VK_ERROR_EXTENSION_NOT_PRESENT);
    const char *extensions[258];
    uint32_t count = 0;
    int nn = 0, has_surface = 0;
    for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
        const char *name = info->ppEnabledExtensionNames[i];
        if (!name) return error("vkCreateInstance extension name", VK_ERROR_EXTENSION_NOT_PRESENT);
        fprintf(stderr, "[vk-direct] instance扩展：%s\n", name);
        if (!strcmp(name, VK_NN_VI_SURFACE_EXTENSION_NAME)) { name = VK_KHR_ANDROID_SURFACE_EXTENSION_NAME; nn = 1; }
        if (strcmp(name, VK_KHR_SURFACE_EXTENSION_NAME) && strcmp(name, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME))
            return error("vkCreateInstance unsupported extension", VK_ERROR_EXTENSION_NOT_PRESENT);
        if (!strcmp(name, VK_KHR_SURFACE_EXTENSION_NAME)) has_surface = 1;
        uint32_t j = 0;
        while (j < count && strcmp(extensions[j], name)) j++;
        if (j == count) extensions[count++] = name;
    }
    if (nn && !has_surface) return error("VK_NN_vi_surface requires VK_KHR_surface", VK_ERROR_EXTENSION_NOT_PRESENT);
    maintenance_instance=nn && has_instance_extension(VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME) &&
        has_instance_extension(VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME);
    if(maintenance_instance){
        extensions[count++]=VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME;
        extensions[count++]=VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME;
    }
    VkInstanceCreateInfo copy = *info;
    copy.enabledExtensionCount = count;
    copy.ppEnabledExtensionNames = extensions;
    pthread_mutex_lock(&lock);
    if (instance) { pthread_mutex_unlock(&lock); return error("multiple Vulkan instances", VK_ERROR_TOO_MANY_OBJECTS); }
    VkResult result = ((PFN_vkCreateInstance)raw("vkCreateInstance"))(&copy, adapted, out);
    if (result == VK_SUCCESS) { instance = *out; vi_enabled = nn; instance_allocator=adapted; }
    pthread_mutex_unlock(&lock);
    if (result == VK_SUCCESS) fprintf(stderr, "[vk-direct] 实例已创建，allocator回调累计 %llu 次\n", (unsigned long long)atomic_load(&allocator_calls));
    return result < 0 ? error("vkCreateInstance", result) : result;
}

static void destroy_instance_admitted(VkInstance i, const VkAllocationCallbacks *allocator) {
    if (!i) return;
    const VkAllocationCallbacks *adapted;
    if (adapt_allocator(allocator, &adapted) != VK_SUCCESS) fatal("vkDestroyInstance guest allocator");
    pthread_mutex_lock(&lock);
    if (i != instance || device || surface) { pthread_mutex_unlock(&lock); fatal("vkDestroyInstance ownership/live device/surface"); }
    ((PFN_vkDestroyInstance)raw("vkDestroyInstance"))(i, adapted);
    instance = VK_NULL_HANDLE;
    vi_enabled = 0;
    pthread_mutex_unlock(&lock);
}

static VKAPI_ATTR VkResult VKAPI_CALL enumerate_extensions(const char *layer,
    uint32_t *count, VkExtensionProperties *out) {
    if (!count) return error("vkEnumerateInstanceExtensionProperties count", VK_ERROR_INITIALIZATION_FAILED);
    PFN_vkEnumerateInstanceExtensionProperties enumerate = (PFN_vkEnumerateInstanceExtensionProperties)raw("vkEnumerateInstanceExtensionProperties");
    // Layer extension lists are distinct; do not invent a driver extension in them.
    if (layer) return enumerate(layer, count, out);
    uint32_t n = 0;
    VkResult result = enumerate(NULL, &n, NULL);
    if (result != VK_SUCCESS) return result;
    if (n > 4096) return error("driver extension count", VK_ERROR_INITIALIZATION_FAILED);
    VkExtensionProperties *properties = calloc((size_t)n + 1, sizeof *properties);
    if (!properties) return VK_ERROR_OUT_OF_HOST_MEMORY;
    result = enumerate(NULL, &n, properties);
    if (result != VK_SUCCESS) { free(properties); return result; }
    uint32_t kept = 0;
    for (uint32_t j = 0; j < n; j++) {
        if (strcmp(properties[j].extensionName, VK_KHR_SURFACE_EXTENSION_NAME) &&
            strcmp(properties[j].extensionName, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME)) continue;
        if (!strcmp(properties[j].extensionName, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME)) {
            strcpy(properties[j].extensionName, VK_NN_VI_SURFACE_EXTENSION_NAME);
            properties[j].specVersion = VK_NN_VI_SURFACE_SPEC_VERSION;
        }
        properties[kept++] = properties[j];
    }
    n = kept;
    if (!out) *count = n;
    else {
        uint32_t written = *count < n ? *count : n;
        memcpy(out, properties, written * sizeof *out);
        *count = written;
        if (written < n) result = VK_INCOMPLETE;
    }
    free(properties);
    return result;
}

static void release_surface_window(void) {
    surface_api->release_window(surface_api->lease, surface_state.window);
    surface_api->released(surface_api->lease, surface_state.generation);
    surface_api = NULL;
    memset(&surface_state, 0, sizeof surface_state);
}

static VkResult create_vi_surface_admitted(VkInstance i,
    const VkViSurfaceCreateInfoNN *info, const VkAllocationCallbacks *allocator, VkSurfaceKHR *out) {
    if (!info || !out || !info->window || info->sType != VK_STRUCTURE_TYPE_VI_SURFACE_CREATE_INFO_NN)
        return error("vkCreateViSurfaceNN arguments", VK_ERROR_INITIALIZATION_FAILED);
    if (info->pNext || info->flags) return error("vkCreateViSurfaceNN unsupported flags/callbacks", VK_ERROR_FEATURE_NOT_PRESENT);
    const VkAllocationCallbacks *adapted;
    VkResult adaptation = adapt_allocator(allocator, &adapted);
    if (adaptation != VK_SUCCESS) return error("vkCreateViSurfaceNN guest allocator", adaptation);
    const struct s2a_wsi_api *api = host.window(info->window);
    if (!api || api->size < sizeof *api || api->abi_version != S2A_WSI_ABI_VERSION || !api->lease ||
        !api->take || !api->release_window || !api->released)
        return error("vkCreateViSurfaceNN unregistered vi window", VK_ERROR_SURFACE_LOST_KHR);
    pthread_mutex_lock(&lock);
    if (i != instance || !i || !vi_enabled) { pthread_mutex_unlock(&lock); return error("VK_NN_vi_surface not enabled", VK_ERROR_EXTENSION_NOT_PRESENT); }
    if (surface) { pthread_mutex_unlock(&lock); return error("multiple vi surfaces", VK_ERROR_TOO_MANY_OBJECTS); }
    struct s2a_wsi_state state = {0};
    int taken = api->take(api->lease, &state);
    if (taken || !state.window) { pthread_mutex_unlock(&lock); return error("vi window unavailable", VK_ERROR_SURFACE_LOST_KHR); }
    surface_api = api;
    surface_state = state;
    if (!state.foreground || state.stopping || state.width <= 0 || state.height <= 0) {
        release_surface_window(); pthread_mutex_unlock(&lock);
        return error("vi window not ready", VK_ERROR_SURFACE_LOST_KHR);
    }
    PFN_vkCreateAndroidSurfaceKHR create = (PFN_vkCreateAndroidSurfaceKHR)host.instance_proc(i, "vkCreateAndroidSurfaceKHR");
    if (!create) { release_surface_window(); pthread_mutex_unlock(&lock); return error("Android WSI unavailable", VK_ERROR_EXTENSION_NOT_PRESENT); }
    VkAndroidSurfaceCreateInfoKHR ci = {.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR, .window = state.window};
    VkResult result = create(i, &ci, adapted, out);
    if (result == VK_SUCCESS) {surface = *out;surface_allocator=adapted;}
    else release_surface_window();
    pthread_mutex_unlock(&lock);
    return result < 0 ? error("vkCreateAndroidSurfaceKHR", result) : result;
}

static void destroy_surface_admitted(VkInstance i, VkSurfaceKHR s, const VkAllocationCallbacks *allocator) {
    if (!s) return;
    const VkAllocationCallbacks *adapted;
    if (adapt_allocator(allocator, &adapted) != VK_SUCCESS) fatal("vkDestroySurfaceKHR guest allocator");
    pthread_mutex_lock(&lock);
    if (i != instance || s != surface || vi_live()) { pthread_mutex_unlock(&lock); fatal("vkDestroySurfaceKHR ownership/live swapchain"); }
    PFN_vkDestroySurfaceKHR destroy = (PFN_vkDestroySurfaceKHR)host.instance_proc(i, "vkDestroySurfaceKHR");
    if (!destroy) { pthread_mutex_unlock(&lock); fatal("vkDestroySurfaceKHR missing driver entry"); }
    destroy(i, s, adapted);
    surface = VK_NULL_HANDLE;
    release_surface_window(); // Acknowledge revoke only after driver surface destruction.
    pthread_mutex_unlock(&lock);
}

// Instance / surface / device lifetime calls hold `lock` across the driver and
// may run reverse guest allocator callbacks. They are admitted like every other
// callback-bearing call, so the shutdown drain also covers their driver frames.
static VKAPI_ATTR VkResult VKAPI_CALL create_instance(const VkInstanceCreateInfo *info,
    const VkAllocationCallbacks *allocator, VkInstance *out) {
    if (!enter_call("vkCreateInstance")) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create_instance_admitted(info, allocator, out);
    finish_call();
    return result;
}
static VKAPI_ATTR void VKAPI_CALL destroy_instance(VkInstance i, const VkAllocationCallbacks *allocator) {
    if (!enter_call("vkDestroyInstance")) return;
    destroy_instance_admitted(i, allocator);
    finish_call();
}
static VKAPI_ATTR VkResult VKAPI_CALL create_vi_surface(VkInstance i,
    const VkViSurfaceCreateInfoNN *info, const VkAllocationCallbacks *allocator, VkSurfaceKHR *out) {
    if (!enter_call("vkCreateViSurfaceNN")) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create_vi_surface_admitted(i, info, allocator, out);
    finish_call();
    return result;
}
static VKAPI_ATTR void VKAPI_CALL destroy_surface(VkInstance i, VkSurfaceKHR s, const VkAllocationCallbacks *allocator) {
    if (!enter_call("vkDestroySurfaceKHR")) return;
    destroy_surface_admitted(i, s, allocator);
    finish_call();
}

// Generated signature rows from Vulkan 1.1 prototypes; calls with an explicit
// pAllocator are intercepted and admitted. Implicit parent-allocator callbacks
// from passthrough commands are not (see passthrough[] below). New commands need a reviewed row, not arbitrary dlsym.
#define ALLOC_RESULT(name, declaration, arguments, kind, count, output) \
    static VKAPI_ATTR VkResult VKAPI_CALL bridge_##name declaration { \
        if (!enter_call(#name)) return VK_ERROR_INITIALIZATION_FAILED; \
        const VkAllocationCallbacks *adapted; \
        VkResult adaptation = adapt_allocator(pAllocator, &adapted); \
        VkResult result = adaptation; \
        if (adaptation == VK_SUCCESS) { \
            pAllocator = adapted; \
            for(uint32_t j=0;j<(count);j++)(output)[j]=VK_NULL_HANDLE; \
            result = ((PFN_##name)raw(#name)) arguments; \
            for(uint32_t j=0;j<(count);j++)remember_object(kind,(uint64_t)(uintptr_t)(output)[j],adapted); \
        } \
        finish_call(); \
        return result < 0 ? error(adaptation == VK_SUCCESS ? #name : #name " guest allocator", result) : result; \
    }
#define ALLOC_VOID(name, declaration, arguments, kind, object) \
    static VKAPI_ATTR void VKAPI_CALL bridge_##name declaration { \
        if (!enter_call(#name)) return; \
        const VkAllocationCallbacks *adapted; \
        if (adapt_allocator(pAllocator, &adapted) != VK_SUCCESS) { finish_call(); fatal(#name " guest allocator"); } \
        pAllocator = adapted; \
        ((PFN_##name)raw(#name)) arguments; \
        forget_object(kind,(uint64_t)(uintptr_t)(object)); \
        finish_call(); \
    }
#define BLOCK_RESULT(name, declaration, arguments) \
    static VKAPI_ATTR VkResult VKAPI_CALL bridge_##name declaration { \
        if (!enter_call(#name)) return VK_ERROR_INITIALIZATION_FAILED; \
        host.block_begin(); \
        blocking++; \
        VkResult result = ((PFN_##name)raw(#name)) arguments; \
        blocking--; \
        finish_call(); \
        host.block_end(); \
        static _Atomic unsigned trace_count; \
        if (atomic_fetch_add(&trace_count, 1) < 8) fprintf(stderr, "[vk-direct] driver %s result=%d\n", #name, result); \
        if (!strcmp(#name, "vkQueuePresentKHR") && (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR)) atomic_fetch_add(&presents, 1); \
        return result < 0 ? error(#name, result) : result; \
    }
#include "direct_vk_commands.inc"
#undef ALLOC_RESULT
#undef ALLOC_VOID
#undef BLOCK_RESULT

static VKAPI_ATTR VkResult VKAPI_CALL create_command_pool(VkDevice d, const VkCommandPoolCreateInfo *info,
    const VkAllocationCallbacks *allocator, VkCommandPool *out) {
    if(!enter_call("vkCreateCommandPool"))return VK_ERROR_INITIALIZATION_FAILED;
    VkResult r = bridge_vkCreateCommandPool(d, info, allocator, out);
    fprintf(stderr, "[vk-direct] command pool create: device=%p family=%u flags=%u result=%d pool=%llx\n",
        (void *)d, info->queueFamilyIndex, info->flags, r, r == VK_SUCCESS ? (unsigned long long)(uintptr_t)*out : 0);
    finish_call();
    return r;
}
static VKAPI_ATTR void VKAPI_CALL destroy_command_pool(VkDevice d, VkCommandPool pool, const VkAllocationCallbacks *allocator) {
    fprintf(stderr, "[vk-direct] command pool destroy: device=%p pool=%llx\n", (void *)d, (unsigned long long)(uintptr_t)pool);
    bridge_vkDestroyCommandPool(d, pool, allocator);
}
static VKAPI_ATTR VkResult VKAPI_CALL reset_command_pool(VkDevice d, VkCommandPool pool, VkCommandPoolResetFlags flags) {
    if(!enter_call("vkResetCommandPool"))return VK_ERROR_INITIALIZATION_FAILED;
    static _Atomic unsigned count;
    if (atomic_fetch_add(&count, 1) < 10) fprintf(stderr, "[vk-direct] command pool reset: device=%p pool=%llx flags=%u\n", (void *)d, (unsigned long long)(uintptr_t)pool, flags);
    VkResult result=((PFN_vkResetCommandPool)raw("vkResetCommandPool"))(d, pool, flags);
    finish_call();
    return result<0?error("vkResetCommandPool",result):result;
}
static VKAPI_ATTR VkResult VKAPI_CALL create_swapchain(VkDevice d, const VkSwapchainCreateInfoKHR *info,
    const VkAllocationCallbacks *allocator, VkSwapchainKHR *out) {
    if(!enter_call("vkCreateSwapchainKHR"))return VK_ERROR_INITIALIZATION_FAILED;
    int logical=vi_enabled;
    VkResult r;
    if(logical)r=vi_create(d,info,allocator,out);
    else{
        r=bridge_vkCreateSwapchainKHR(d,info,allocator,out);
        uint32_t n=0;
        if(r==VK_SUCCESS)(void)((PFN_vkGetSwapchainImagesKHR)raw("vkGetSwapchainImagesKHR"))(d,*out,&n,NULL);
        fprintf(stderr,"[vk-direct] swapchain create: extent=%ux%u requested=%u actual=%u result=%d\n",
            info->imageExtent.width,info->imageExtent.height,info->minImageCount,n,r);
    }
    finish_call();
    return logical && r<0?error("VI create swapchain",r):r;
}
static VKAPI_ATTR VkResult VKAPI_CALL acquire_next_image(VkDevice d, VkSwapchainKHR chain, uint64_t timeout,
    VkSemaphore semaphore, VkFence fence, uint32_t *index) {
    if(vi_enabled){
        if(!enter_blocked_call("vkAcquireNextImageKHR"))return VK_ERROR_INITIALIZATION_FAILED;
        VkResult r=vi_acquire(d,chain,timeout,semaphore,fence,index);
        finish_blocked_call();
        return r<0?error("VI acquire",r):r;
    }
    return bridge_vkAcquireNextImageKHR(d,chain,timeout,semaphore,fence,index);
}
static VKAPI_ATTR VkResult VKAPI_CALL surface_capabilities(VkPhysicalDevice p, VkSurfaceKHR s, VkSurfaceCapabilitiesKHR *out) {
    VkResult r = ((PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR)raw("vkGetPhysicalDeviceSurfaceCapabilitiesKHR"))(p, s, out);
    if (r == VK_SUCCESS) fprintf(stderr, "[vk-direct] surface caps: min=%u max=%u extent=%ux%u minExtent=%ux%u maxExtent=%ux%u\n",
        out->minImageCount, out->maxImageCount, out->currentExtent.width, out->currentExtent.height,
        out->minImageExtent.width, out->minImageExtent.height, out->maxImageExtent.width, out->maxImageExtent.height);
    if(r==VK_SUCCESS && vi_enabled){
        if(!maintenance_device)return error("VI requires swapchain maintenance1",VK_ERROR_FEATURE_NOT_PRESENT);
        VkSurfaceCapabilitiesKHR native=*out;r=s2a_vi_capabilities(&native,out);
    }
    return r;
}
static VKAPI_ATTR VkResult VKAPI_CALL surface_support(VkPhysicalDevice p,uint32_t family,VkSurfaceKHR s,VkBool32 *supported){
    VkResult r=((PFN_vkGetPhysicalDeviceSurfaceSupportKHR)raw("vkGetPhysicalDeviceSurfaceSupportKHR"))(p,family,s,supported);
    if(r!=VK_SUCCESS||!vi_enabled||!*supported)return r;
    uint32_t n=0;((PFN_vkGetPhysicalDeviceQueueFamilyProperties)raw("vkGetPhysicalDeviceQueueFamilyProperties"))(p,&n,NULL);
    if(n>64||family>=n)return error("VI queue family unavailable",VK_ERROR_INITIALIZATION_FAILED);
    VkQueueFamilyProperties properties[64];((PFN_vkGetPhysicalDeviceQueueFamilyProperties)raw("vkGetPhysicalDeviceQueueFamilyProperties"))(p,&n,properties);
    *supported=(properties[family].queueFlags&VK_QUEUE_GRAPHICS_BIT)?VK_TRUE:VK_FALSE;
    fprintf(stderr,"[vk-direct] VI present family=%u flags=%x supported=%u\n",family,properties[family].queueFlags,*supported);
    return r;
}
static VKAPI_ATTR VkResult VKAPI_CALL queue_submit(VkQueue q,uint32_t n,const VkSubmitInfo *submits,VkFence f){
    static _Atomic unsigned count;
    for(unsigned j=0;j<n;j++)if(submits[j].waitSemaphoreCount && atomic_fetch_add(&count,1)<12){
        fprintf(stderr,"[vk-direct] guest submit: queue=%p wait=%u signal=%u firstWait=%llx firstSignal=%llx\n",(void *)q,
            submits[j].waitSemaphoreCount,submits[j].signalSemaphoreCount,(unsigned long long)(uintptr_t)submits[j].pWaitSemaphores[0],
            submits[j].signalSemaphoreCount?(unsigned long long)(uintptr_t)submits[j].pSignalSemaphores[0]:0);
    }
    return bridge_vkQueueSubmit(q,n,submits,f);
}

static VKAPI_ATTR VkResult VKAPI_CALL get_swapchain_images(VkDevice d,VkSwapchainKHR chain,uint32_t *n,VkImage *images){
    return vi_enabled?vi_images(d,chain,n,images):((PFN_vkGetSwapchainImagesKHR)raw("vkGetSwapchainImagesKHR"))(d,chain,n,images);
}
static VKAPI_ATTR void VKAPI_CALL destroy_swapchain(VkDevice d,VkSwapchainKHR chain,const VkAllocationCallbacks *a){
    // 终止清场自己负责销毁交换链；此时客体再进来只会和清场抢同一份 WSI 状态。
    if(vi_enabled){
        if(!enter_blocked_call("vkDestroySwapchainKHR"))return;
        VkResult r=vi_destroy(d,chain,a);
        finish_blocked_call();
        if(r!=VK_SUCCESS)fatal("VI swapchain retirement/ownership failed");
    }else bridge_vkDestroySwapchainKHR(d,chain,a);
}
static VKAPI_ATTR VkResult VKAPI_CALL present(VkQueue q,const VkPresentInfoKHR *info){
    if(!vi_enabled)return bridge_vkQueuePresentKHR(q,info);
    if(!enter_blocked_call("vkQueuePresentKHR"))return VK_ERROR_INITIALIZATION_FAILED;
    VkResult r=vi_present(q,info);
    finish_blocked_call();
    return r<0?error("VI present",r):r;
}
static VKAPI_ATTR VkResult VKAPI_CALL create_render_pass(VkDevice d,const VkRenderPassCreateInfo *info,const VkAllocationCallbacks *a,VkRenderPass *out){
    if(!vi_enabled||!info)return bridge_vkCreateRenderPass(d,info,a,out);
    if(info->attachmentCount>64)return error("VI render pass attachment limit",VK_ERROR_TOO_MANY_OBJECTS);
    VkAttachmentDescription attachments[64];
    for(unsigned j=0;j<info->attachmentCount;j++){
        attachments[j]=info->pAttachments[j];
        attachments[j].initialLayout=s2a_vi_layout(attachments[j].initialLayout);
        attachments[j].finalLayout=s2a_vi_layout(attachments[j].finalLayout);
    }
    VkRenderPassCreateInfo copy=*info;copy.pAttachments=attachments;
    return bridge_vkCreateRenderPass(d,&copy,a,out);
}
static VKAPI_ATTR void VKAPI_CALL pipeline_barrier(VkCommandBuffer command,VkPipelineStageFlags src,VkPipelineStageFlags dst,
    VkDependencyFlags dependencies,uint32_t nm,const VkMemoryBarrier *m,uint32_t nb,const VkBufferMemoryBarrier *b,
    uint32_t ni,const VkImageMemoryBarrier *images){
    PFN_vkCmdPipelineBarrier fn=(PFN_vkCmdPipelineBarrier)raw("vkCmdPipelineBarrier");
    if(!vi_enabled||!ni){fn(command,src,dst,dependencies,nm,m,nb,b,ni,images);return;}
    if(ni>4096)fatal("VI image barrier count limit");
    VkImageMemoryBarrier stack[32],*copy=ni<=32?stack:malloc((size_t)ni*sizeof *copy);
    if(!copy)fatal("VI image barrier allocation");
    pthread_mutex_lock(&wsi_mutex);
    for(unsigned j=0;j<ni;j++){
        copy[j]=images[j];
        if(vi_image(copy[j].image)){copy[j].oldLayout=s2a_vi_layout(copy[j].oldLayout);copy[j].newLayout=s2a_vi_layout(copy[j].newLayout);}
    }
    pthread_mutex_unlock(&wsi_mutex);
    fn(command,src,dst,dependencies,nm,m,nb,b,ni,copy);if(copy!=stack)free(copy);
}

// Pure-data feature chains retain driver-native layouts and requested bits.
// Callback-bearing device chains need explicit adaptation before acceptance.
static VkResult create_device_admitted(VkPhysicalDevice p,
    const VkDeviceCreateInfo *info, const VkAllocationCallbacks *allocator, VkDevice *out) {
    if (!info || !out || info->sType != VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO)
        return error("vkCreateDevice arguments", VK_ERROR_INITIALIZATION_FAILED);
    const VkBaseInStructure *next = info->pNext;
    const VkBaseInStructure *seen[32]; unsigned seen_count = 0;
    while (next) {
        if (seen_count == 32) return error("vkCreateDevice feature chain too long", VK_ERROR_INITIALIZATION_FAILED);
        for (unsigned j = 0; j < seen_count; j++)
            if (seen[j] == next) return error("vkCreateDevice cyclic feature chain", VK_ERROR_INITIALIZATION_FAILED);
        seen[seen_count++] = next;
        fprintf(stderr, "[vk-direct] device pNext sType=%u\n", (unsigned)next->sType);
        switch (next->sType) {
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2:
            if (info->pEnabledFeatures) return error("VkPhysicalDeviceFeatures2 and pEnabledFeatures both set", VK_ERROR_INITIALIZATION_FAILED);
            break;
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES:
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_FEATURES:
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VARIABLE_POINTERS_FEATURES:
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROTECTED_MEMORY_FEATURES:
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES:
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES:
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES:
            break;
        default: return error("vkCreateDevice unsupported pNext", VK_ERROR_FEATURE_NOT_PRESENT);
        }
        next = next->pNext;
    }
    const VkAllocationCallbacks *adapted;
    VkResult adaptation = adapt_allocator(allocator, &adapted);
    if (adaptation != VK_SUCCESS) return error("vkCreateDevice guest allocator", adaptation);
    for (uint32_t i = 0; i < info->enabledExtensionCount; i++)
        fprintf(stderr, "[vk-direct] device扩展：%s\n", info->ppEnabledExtensionNames[i]);
    VkDeviceCreateInfo copy=*info;
    const char *extensions[258];
    VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT mf={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT};
    if(maintenance_instance){
        VkPhysicalDeviceFeatures2 query={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,.pNext=&mf};
        ((PFN_vkGetPhysicalDeviceFeatures2)raw("vkGetPhysicalDeviceFeatures2"))(p,&query);
        if(!mf.swapchainMaintenance1 || !info->queueCreateInfoCount || info->enabledExtensionCount>256)
            return error("VI device maintenance1/queue unavailable",VK_ERROR_FEATURE_NOT_PRESENT);
        for(unsigned j=0;j<info->enabledExtensionCount;j++)extensions[j]=info->ppEnabledExtensionNames[j];
        extensions[info->enabledExtensionCount]=VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME;
        copy.ppEnabledExtensionNames=extensions;copy.enabledExtensionCount++;
        mf.pNext=(void *)info->pNext;copy.pNext=&mf;
        wsi_physical=p;wsi_family=info->pQueueCreateInfos[0].queueFamilyIndex;
    }
    pthread_mutex_lock(&lock);
    if (!instance || device) { pthread_mutex_unlock(&lock); return error("Vulkan device ownership/count", VK_ERROR_TOO_MANY_OBJECTS); }
    VkResult result = ((PFN_vkCreateDevice)raw("vkCreateDevice"))(p, &copy, adapted, out);
    if (result == VK_SUCCESS) {device = *out;maintenance_device=maintenance_instance;device_allocator=adapted;}
    pthread_mutex_unlock(&lock);
    if (result == VK_SUCCESS) fprintf(stderr, "[vk-direct] 设备已创建\n");
    return result < 0 ? error("vkCreateDevice", result) : result;
}

static void destroy_device_admitted(VkDevice d, const VkAllocationCallbacks *allocator) {
    if (!d) return;
    const VkAllocationCallbacks *adapted;
    if (adapt_allocator(allocator, &adapted) != VK_SUCCESS) fatal("vkDestroyDevice guest allocator");
    pthread_mutex_lock(&lock);
    if (d != device || vi_live()) { pthread_mutex_unlock(&lock); fatal("vkDestroyDevice ownership/live swapchain"); }
    ((PFN_vkDestroyDevice)raw("vkDestroyDevice"))(d, adapted);
    device = VK_NULL_HANDLE;
    pthread_mutex_unlock(&lock);
}
static VKAPI_ATTR VkResult VKAPI_CALL create_device(VkPhysicalDevice p,
    const VkDeviceCreateInfo *info, const VkAllocationCallbacks *allocator, VkDevice *out) {
    if (!enter_call("vkCreateDevice")) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create_device_admitted(p, info, allocator, out);
    finish_call();
    return result;
}
static VKAPI_ATTR void VKAPI_CALL destroy_device(VkDevice d, const VkAllocationCallbacks *allocator) {
    if (!enter_call("vkDestroyDevice")) return;
    destroy_device_admitted(d, allocator);
    finish_call();
}

static PFN_vkVoidFunction VKAPI_CALL get_instance_proc(VkInstance i, const char *name);
static PFN_vkVoidFunction VKAPI_CALL get_device_proc(VkDevice d, const char *name);

static PFN_vkVoidFunction replacement(const char *name) {
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)get_instance_proc;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)get_device_proc;
    if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)create_instance;
    if (!strcmp(name, "vkDestroyInstance")) return (PFN_vkVoidFunction)destroy_instance;
    if (!strcmp(name, "vkEnumerateInstanceExtensionProperties")) return (PFN_vkVoidFunction)enumerate_extensions;
    if (!strcmp(name, "vkCreateViSurfaceNN")) return (PFN_vkVoidFunction)create_vi_surface;
    if (!strcmp(name, "vkDestroySurfaceKHR")) return (PFN_vkVoidFunction)destroy_surface;
    if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)create_device;
    if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)destroy_device;
    if (!strcmp(name, "vkCreateCommandPool")) return (PFN_vkVoidFunction)create_command_pool;
    if (!strcmp(name, "vkDestroyCommandPool")) return (PFN_vkVoidFunction)destroy_command_pool;
    if (!strcmp(name, "vkResetCommandPool")) return (PFN_vkVoidFunction)reset_command_pool;
    if (!strcmp(name, "vkCreateSwapchainKHR")) return (PFN_vkVoidFunction)create_swapchain;
    if (!strcmp(name, "vkAcquireNextImageKHR")) return (PFN_vkVoidFunction)acquire_next_image;
    if (!strcmp(name, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")) return (PFN_vkVoidFunction)surface_capabilities;
    if (!strcmp(name, "vkGetPhysicalDeviceSurfaceSupportKHR")) return (PFN_vkVoidFunction)surface_support;
    if (!strcmp(name, "vkQueueSubmit")) return (PFN_vkVoidFunction)queue_submit;
    if (!strcmp(name, "vkGetSwapchainImagesKHR")) return (PFN_vkVoidFunction)get_swapchain_images;
    if (!strcmp(name, "vkDestroySwapchainKHR")) return (PFN_vkVoidFunction)destroy_swapchain;
    if (!strcmp(name, "vkQueuePresentKHR")) return (PFN_vkVoidFunction)present;
    if (!strcmp(name, "vkCreateRenderPass")) return (PFN_vkVoidFunction)create_render_pass;
    if (!strcmp(name, "vkCmdPipelineBarrier")) return (PFN_vkVoidFunction)pipeline_barrier;
    if (!strcmp(name, "vkGetPhysicalDeviceFormatProperties")) return (PFN_vkVoidFunction)format_properties;
#define ALLOC_RESULT(n, d, a, ...) if (!strcmp(name, #n)) return (PFN_vkVoidFunction)bridge_##n;
#define ALLOC_VOID(n, d, a, ...) ALLOC_RESULT(n, d, a)
#define BLOCK_RESULT(n, d, a) ALLOC_RESULT(n, d, a)
#include "direct_vk_commands.inc"
#undef ALLOC_RESULT
#undef ALLOC_VOID
#undef BLOCK_RESULT
    return NULL;
}

static void *export_proc(const char *name, PFN_vkVoidFunction function) {
    if (!name || !function) return NULL;
    PFN_vkVoidFunction adapted = replacement(name);
    if (!adapted) {
        size_t j = 0;
        for (; j < sizeof passthrough / sizeof *passthrough; j++) if (!strcmp(name, passthrough[j])) break;
        if (j == sizeof passthrough / sizeof *passthrough) return NULL;
        adapted = function;
    }
    return host.wrap(name, (void *)adapted);
}

// Like the iOS frontend, record each runtime lookup once. This distinguishes a
// driver that lacks an optional command from an entry our reviewed table omits.
static PFN_vkVoidFunction lookup_result(const char *name, PFN_vkVoidFunction driver, void *result) {
    static char seen[512][128]; static unsigned count;
    static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mutex);
    unsigned j = 0;
    while (j < count && strcmp(seen[j], name)) j++;
    if (j == count && count < 512 && strlen(name) < sizeof seen[0]) {
        strcpy(seen[count++], name);
        fprintf(stderr, "[vk-direct] lookup %s: driver=%s bridge=%s\n", name,
            driver ? "yes" : "no", result ? "yes" : "no");
    }
    pthread_mutex_unlock(&mutex);
    return (PFN_vkVoidFunction)result;
}

static PFN_vkVoidFunction VKAPI_CALL get_instance_proc(VkInstance i, const char *name) {
    if (!name) return NULL;
    if (!strcmp(name, "vkCreateViSurfaceNN")) {
        pthread_mutex_lock(&lock);
        int enabled = i && i == instance && vi_enabled;
        pthread_mutex_unlock(&lock);
        return enabled ? (PFN_vkVoidFunction)export_proc(name, (PFN_vkVoidFunction)create_vi_surface) : NULL;
    }
    PFN_vkVoidFunction driver = host.instance_proc(i, name);
    return lookup_result(name, driver, export_proc(name, driver));
}

static PFN_vkVoidFunction VKAPI_CALL get_device_proc(VkDevice d, const char *name) {
    if (!name || !d || !strcmp(name, "vkCreateViSurfaceNN")) return NULL;
    PFN_vkVoidFunction driver = host.device_proc(d, name);
    return lookup_result(name, driver, export_proc(name, driver));
}

void *s2a_vk_entry(const char *name) {
    if (!atomic_load_explicit(&configured, memory_order_acquire) || !name) return NULL;
    if (!strcmp(name, "vkCreateViSurfaceNN")) return export_proc(name, (PFN_vkVoidFunction)create_vi_surface);
    return export_proc(name, host.symbol(name));
}

// Shutdown phase 2 (contract in direct_vk.h). Only the shutdown owner calls it,
// after s2a_android_vk_quiesce and before any terminal SVC park / writer epoch.
// It holds no call_gate / lock / wsi / owned / allocator lock while waiting, so
// admitted driver frames and their reverse allocator callbacks (which may still
// enter SVCs and restore their virtual core) can run to the outer finish_call.
// Closed admission plus zero outer tokens is stable: a nested call needs one.
#define ADMITTED_DRAIN_NS 800000000ull
int s2a_android_vk_drain_admitted(void){
    if(!atomic_load_explicit(&configured,memory_order_acquire))return 0;
    if(!atomic_load_explicit(&vk_quiescing,memory_order_acquire)){
        fprintf(stderr,"[vk-direct] 【红】收局排空：准入尚未关闭\n");return EINVAL;
    }
#if defined(S2A_ANDROID_GAME_RUNTIME)
    extern int s2a_svc_stopping(void);
    if(s2a_svc_stopping()){
        fprintf(stderr,"[vk-direct] 【红】收局排空：终局 SVC 停机门已发布，排空时机已过\n");return EINVAL;
    }
#endif
    if(call_depth||callback_depth){
        // The owner's own driver frame lies below this stack; it can never unwind first.
        report_inflight_calls();
        fprintf(stderr,"[vk-direct] 【红】收局排空：收局线程自身仍在Vulkan驱动帧里（token=%u 回调=%u）\n",call_depth,callback_depth);return EDEADLK;
    }
    const uint64_t start=wsi_now_ns(),deadline=wsi_deadline(ADMITTED_DRAIN_NS);
    int left;
    while((left=atomic_load_explicit(&guest_inflight,memory_order_acquire)) && wsi_now_ns()<deadline)usleep(1000);
    left=atomic_load_explicit(&guest_inflight,memory_order_acquire);
    if(left){
        report_inflight_calls();
        fprintf(stderr,"[vk-direct] 【红】收局排空：%d 个已受理Vulkan调用 %.0f ms 内未返回\n",left,(double)ADMITTED_DRAIN_NS/1e6);
        return EBUSY;
    }
    fprintf(stderr,"[vk-direct] 收局排空：已受理Vulkan调用全部出账，耗时 %.1f ms\n",(double)(wsi_now_ns()-start)/1e6);
    return 0;
}

int s2a_android_vk_terminal_drain(void){
    pthread_mutex_lock(&call_gate);
    int already_terminating=atomic_exchange(&terminating,1);
    pthread_mutex_unlock(&call_gate);
    if(already_terminating)return s2a_android_vk_stop();
    struct timespec drain_start; clock_gettime(CLOCK_MONOTONIC,&drain_start);
    // 先挡住客体再进驱动：仍停在驱动调用里的客体线程必须在销毁 device 之前走完，
    // 否则销毁会在驱动内部和它抢同一把锁（真机上表现为卡死或 abort）。
    for(int i=0;i<800 && atomic_load_explicit(&guest_inflight,memory_order_acquire);i++) usleep(1000);
    int leftover=atomic_load_explicit(&guest_inflight,memory_order_acquire);
    fprintf(stderr,"[vk-direct] 终止清场：客体在途Vulkan调用=%d\n",leftover);
    if(leftover){
        // 客体还停在驱动里时销毁 device / 命令池只会换来驱动内部死锁或堆报错；
        // 不做「看起来收完了」的假成功，保留资源并如实报红。
        report_inflight_calls();
        fprintf(stderr,"[vk-direct] 【红】终止清场：客体仍有 %d 个调用在驱动里，跳过设备销毁\n",leftover);
        pthread_mutex_lock(&lock);terminal_error=EBUSY;pthread_mutex_unlock(&lock);
        return EBUSY;
    }
    // After the writer census every reverse frame is either finished or frozen
    // inside its guest callback. A frozen one belongs to a live driver frame
    // (possibly an untokened passthrough command); destroying under it is unsafe.
    int frozen=atomic_load_explicit(&callback_in_guest,memory_order_acquire);
    if(frozen){
        fprintf(stderr,"[vk-direct] 【红】终止清场：%d 个allocator反向回调冻结在驱动帧里，跳过设备销毁\n",frozen);
        pthread_mutex_lock(&lock);terminal_error=EBUSY;pthread_mutex_unlock(&lock);
        return EBUSY;
    }
    allocation_prepare_terminal();
    // Each phase is recorded to distinguish driver waits from host cleanup.
    fprintf(stderr,"[vk-direct] 终止清场：等待主锁\n");
    pthread_mutex_lock(&lock);
    fprintf(stderr,"[vk-direct] 终止清场：已持主锁，等待设备空闲\n");
    VkResult r=VK_SUCCESS;
    if(device){
        r=((PFN_vkDeviceWaitIdle)raw("vkDeviceWaitIdle"))(device);
        fprintf(stderr,"[vk-direct] 终止清场：vkDeviceWaitIdle=%d\n",(int)r);
        if(r!=VK_SUCCESS){terminal_error=EIO;pthread_mutex_unlock(&lock);return EIO;}
        fprintf(stderr,"[vk-direct] 终止清场：等待 WSI 锁与 present fence\n");
        pthread_mutex_lock(&wsi_mutex);
        const uint64_t retirement_deadline=wsi_deadline(500000000ull);
        for(unsigned j=0;j<4;j++)if(vi_chains[j].live){
            r=vi_retire(&vi_chains[j],retirement_deadline,VI_WAIT_TERMINAL);
            if(r!=VK_SUCCESS)break;
        }
        fprintf(stderr,"[vk-direct] 终止清场：present fence 退休=%d\n",(int)r);
        if(r!=VK_SUCCESS){terminal_error=EIO;pthread_mutex_unlock(&wsi_mutex);pthread_mutex_unlock(&lock);return EIO;}
        pthread_mutex_lock(&owned_mutex);
        // VUID-vkDestroyDevice-device-05137: every explicit child must be freed.
        fprintf(stderr,"[vk-direct] 终止清场：逐个销毁 %zu 个客体对象\n",owned_count);
        destroy_owned_views();
        fprintf(stderr,"[vk-direct] 终止清场：销毁视图与存储完成\n");
        for(unsigned j=0;j<4;j++)if(vi_chains[j].live){
            fprintf(stderr,"[vk-direct] 终止清场：销毁交换链 %u（宿主图 %u）\n",j,vi_chains[j].host_count);
            vi_dispose(&vi_chains[j]);
            fprintf(stderr,"[vk-direct] 终止清场：交换链 %u 已销毁\n",j);
        }
        destroy_owned_storage();
        size_t remaining=owned_count;
        pthread_mutex_unlock(&owned_mutex);pthread_mutex_unlock(&wsi_mutex);
        if(remaining){terminal_error=EBUSY;pthread_mutex_unlock(&lock);return EBUSY;}
        fprintf(stderr,"[vk-direct] 终止清场：销毁设备\n");
        ((PFN_vkDestroyDevice)raw("vkDestroyDevice"))(device,device_allocator);device=VK_NULL_HANDLE;
    }
    if(surface){
        fprintf(stderr,"[vk-direct] 终止清场：销毁 surface\n");
        PFN_vkDestroySurfaceKHR destroy=(PFN_vkDestroySurfaceKHR)host.instance_proc(instance,"vkDestroySurfaceKHR");
        if(!destroy){terminal_error=ENOSYS;pthread_mutex_unlock(&lock);return ENOSYS;}
        destroy(instance,surface,surface_allocator);surface=VK_NULL_HANDLE;release_surface_window();
    }
    fprintf(stderr,"[vk-direct] 终止清场：销毁 instance\n");
    if(instance){((PFN_vkDestroyInstance)raw("vkDestroyInstance"))(instance,instance_allocator);instance=VK_NULL_HANDLE;}
    if(terminal_scratch_left()){terminal_error=EBUSY;pthread_mutex_unlock(&lock);return EBUSY;}
    pthread_mutex_unlock(&lock);
    struct timespec drain_end; clock_gettime(CLOCK_MONOTONIC,&drain_end);
    double drain_ms=(double)(drain_end.tv_sec-drain_start.tv_sec)*1e3+(double)(drain_end.tv_nsec-drain_start.tv_nsec)/1e6;
    fprintf(stderr,"[vk-direct] 终止清场完成：GPU与present fence排空，子对象全部释放后销毁设备；客体堆延迟free=%llu、通知=%llu（仅到进程退出，不再执行客体分配器）；耗时 %.1f ms\n",
        (unsigned long long)atomic_load(&quarantined_frees),(unsigned long long)atomic_load(&quarantined_notifications),drain_ms);
    return 0;
}

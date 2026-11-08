// WP17 V0 external-memory probe (issue #401): can game memory become a VkBuffer without copies?
// Each test prints one JSON line on stdout. A failure prints the step, VkResult / errno and stays
// a failure; nothing is reported as success unless the GPU really read / wrote the bytes.
// Each section runs in its own child process with its own Vulkan instance, so a driver crash or
// hang (SIGALRM) in one section is reported as such and the remaining sections still run.
#define _GNU_SOURCE
#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <android/hardware_buffer.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#ifndef PROBE_REV
#define PROBE_REV "unknown"
#endif

static const uint32_t k_xor_spv[] =
#include "xor.comp.inc"
    ;

#define KB ((uint64_t)1024)
#define MB (KB * 1024)
#define GB (MB * 1024)
static const uint64_t k_test_sizes[] = {4 * KB, 64 * KB, 2 * MB, 64 * MB};
// host_max / dmabuf_max sizes (a 1 GiB dma-buf heap allocation is verified harmless on the 9000).
static const uint64_t k_max_sizes[] = {256 * MB, 1 * GB};
// AHardwareBuffer requests are capped at 448 MiB: on the 8E (Adreno 830 / Qualcomm gralloc) a
// >= 512 MiB AHardwareBuffer_allocate aborts vendor.qti.hardware.display.allocator-service and the
// framework restarts with it (#401 V1-d). Larger sizes are refused before any allocation.
#define AHB_LIMIT_BYTES (448 * MB)
static const uint64_t k_ahb_max_sizes[] = {256 * MB};
#define NELEM(a) (sizeof(a) / sizeof((a)[0]))
#define SECTION_ALARM_S 25
#define XOR_KEY 0xA5C3F00Fu

// Probes that #include this file (v1_external_memory) override these; v0 keeps the defaults.
static const char *g_probe_tag = "v0";
static const VkPhysicalDeviceFeatures *g_ctx_features;
static VkQueueFlags g_ctx_queue_flags = VK_QUEUE_COMPUTE_BIT;

// ---------------------------------------------------------------- JSON lines

typedef struct {
    char b[16384];
    size_t n;
    int first;
} Js;

static void jraw(Js *j, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void jraw(Js *j, const char *fmt, ...) {
    if (j->n >= sizeof j->b - 1) return;
    va_list ap;
    va_start(ap, fmt);
    int w = vsnprintf(j->b + j->n, sizeof j->b - j->n, fmt, ap);
    va_end(ap);
    if (w > 0) j->n += (size_t)w;
    if (j->n >= sizeof j->b) j->n = sizeof j->b - 1;
}

static void jkey(Js *j, const char *k) {
    jraw(j, "%s\"%s\":", j->first ? "" : ",", k);
    j->first = 0;
}

static void jesc(Js *j, const char *v) {
    jraw(j, "\"");
    for (const unsigned char *p = (const unsigned char *)v; *p; p++) {
        if (*p == '"' || *p == '\\') jraw(j, "\\%c", *p);
        else if (*p < 0x20) jraw(j, "\\u%04x", *p);
        else jraw(j, "%c", *p);
    }
    jraw(j, "\"");
}

static void jstr(Js *j, const char *k, const char *v) { jkey(j, k); jesc(j, v ? v : ""); }
static void jint(Js *j, const char *k, long long v) { jkey(j, k); jraw(j, "%lld", v); }
static void juint(Js *j, const char *k, unsigned long long v) { jkey(j, k); jraw(j, "%llu", v); }
static void jhex(Js *j, const char *k, unsigned long long v) { jkey(j, k); jraw(j, "\"0x%llx\"", v); }
static void jbool(Js *j, const char *k, int v) { jkey(j, k); jraw(j, "%s", v ? "true" : "false"); }
static void jdbl(Js *j, const char *k, double v) { jkey(j, k); jraw(j, "%.1f", v); }

static void jbegin(Js *j, const char *sec) {
    j->n = 0;
    j->first = 1;
    jraw(j, "{");
    jstr(j, "probe", g_probe_tag);
    jstr(j, "sec", sec);
}

static void jend(Js *j) {
    jraw(j, "}\n");
    fwrite(j->b, 1, j->n, stdout);
    fflush(stdout);
}

static double now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

static const char *vkr(VkResult r) {
    switch (r) {
    case VK_SUCCESS: return "VK_SUCCESS";
    case VK_NOT_READY: return "VK_NOT_READY";
    case VK_TIMEOUT: return "VK_TIMEOUT";
    case VK_INCOMPLETE: return "VK_INCOMPLETE";
    case VK_ERROR_OUT_OF_HOST_MEMORY: return "VK_ERROR_OUT_OF_HOST_MEMORY";
    case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
    case VK_ERROR_INITIALIZATION_FAILED: return "VK_ERROR_INITIALIZATION_FAILED";
    case VK_ERROR_DEVICE_LOST: return "VK_ERROR_DEVICE_LOST";
    case VK_ERROR_MEMORY_MAP_FAILED: return "VK_ERROR_MEMORY_MAP_FAILED";
    case VK_ERROR_EXTENSION_NOT_PRESENT: return "VK_ERROR_EXTENSION_NOT_PRESENT";
    case VK_ERROR_FEATURE_NOT_PRESENT: return "VK_ERROR_FEATURE_NOT_PRESENT";
    case VK_ERROR_INCOMPATIBLE_DRIVER: return "VK_ERROR_INCOMPATIBLE_DRIVER";
    case VK_ERROR_TOO_MANY_OBJECTS: return "VK_ERROR_TOO_MANY_OBJECTS";
    case VK_ERROR_FORMAT_NOT_SUPPORTED: return "VK_ERROR_FORMAT_NOT_SUPPORTED";
    case VK_ERROR_INVALID_EXTERNAL_HANDLE: return "VK_ERROR_INVALID_EXTERNAL_HANDLE";
    case VK_ERROR_OUT_OF_POOL_MEMORY: return "VK_ERROR_OUT_OF_POOL_MEMORY";
    case VK_ERROR_UNKNOWN: return "VK_ERROR_UNKNOWN";
    default: return "VK_RESULT_OTHER";
    }
}

static void jvk(Js *j, const char *step, VkResult r) {
    jstr(j, "step", step);
    jstr(j, "vk", vkr(r));
    jint(j, "vk_code", r);
}

static void jerrno(Js *j, const char *step, int e) {
    jstr(j, "step", step);
    jint(j, "errno", e);
    jstr(j, "strerror", strerror(e));
}

static void jstatus(Js *j, const char *status) { jstr(j, "status", status); }

static void mem_flag_names(VkMemoryPropertyFlags f, char *out, size_t cap) {
    static const struct { VkMemoryPropertyFlags bit; const char *name; } names[] = {
        {VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, "DEVICE_LOCAL"},
        {VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, "HOST_VISIBLE"},
        {VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, "HOST_COHERENT"},
        {VK_MEMORY_PROPERTY_HOST_CACHED_BIT, "HOST_CACHED"},
        {VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT, "LAZILY_ALLOCATED"},
        {VK_MEMORY_PROPERTY_PROTECTED_BIT, "PROTECTED"},
    };
    out[0] = 0;
    size_t n = 0;
    for (size_t i = 0; i < NELEM(names); i++) {
        if (!(f & names[i].bit)) continue;
        int w = snprintf(out + n, cap - n, "%s%s", n ? "|" : "", names[i].name);
        if (w > 0 && (size_t)w < cap - n) n += (size_t)w;
    }
}

// ---------------------------------------------------------------- Vulkan context

typedef struct {
    VkInstance inst;
    VkPhysicalDevice pd;
    VkDevice dev;
    VkQueue q;
    uint32_t qf;
    VkPhysicalDeviceProperties props;
    VkPhysicalDeviceMemoryProperties memp;
    int ext_host, ext_ahb, ext_dmabuf, ext_fd, ext_foreign;
    VkDeviceSize host_align;
    long page;
    PFN_vkGetMemoryHostPointerPropertiesEXT get_host_props;
    PFN_vkGetAndroidHardwareBufferPropertiesANDROID get_ahb_props;
    PFN_vkGetMemoryFdPropertiesKHR get_fd_props;
    VkCommandPool cpool;
    VkCommandBuffer cb;
    VkFence fence;
    VkDescriptorSetLayout dsl;
    VkPipelineLayout pl;
    VkShaderModule sm;
    VkPipeline pipe;
    VkDescriptorPool dpool;
    VkDescriptorSet ds;
} Ctx;

static const char *k_want_exts[] = {
    "VK_EXT_external_memory_host",
    "VK_ANDROID_external_memory_android_hardware_buffer",
    "VK_EXT_queue_family_foreign",
    "VK_KHR_external_memory_fd",
    "VK_EXT_external_memory_dma_buf",
    "VK_KHR_external_memory",
    "VK_KHR_sampler_ycbcr_conversion",
    "VK_KHR_dedicated_allocation",
    "VK_KHR_get_memory_requirements2",
    "VK_KHR_maintenance1",
    "VK_KHR_bind_memory2",
};

static void init_fail(const char *step, VkResult r) {
    Js j;
    jbegin(&j, "init");
    jstatus(&j, "fail");
    jvk(&j, step, r);
    jend(&j);
}

static int ctx_init(Ctx *c) {
    memset(c, 0, sizeof *c);
    c->page = sysconf(_SC_PAGESIZE);
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "s2arm-v0probe",
        .apiVersion = VK_API_VERSION_1_3,
    };
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkResult r = vkCreateInstance(&ici, NULL, &c->inst);
    if (r) { init_fail("vkCreateInstance", r); return 0; }
    uint32_t n = 1;
    r = vkEnumeratePhysicalDevices(c->inst, &n, &c->pd);
    if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || !n) {
        init_fail("vkEnumeratePhysicalDevices", r ? r : VK_ERROR_INITIALIZATION_FAILED);
        return 0;
    }
    vkGetPhysicalDeviceProperties(c->pd, &c->props);
    vkGetPhysicalDeviceMemoryProperties(c->pd, &c->memp);
    if (c->props.apiVersion < VK_API_VERSION_1_1) {
        init_fail("device_api_below_1_1", VK_ERROR_INCOMPATIBLE_DRIVER);
        return 0;
    }

    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(c->pd, &qn, NULL);
    VkQueueFamilyProperties qfp[16];
    if (qn > 16) qn = 16;
    vkGetPhysicalDeviceQueueFamilyProperties(c->pd, &qn, qfp);
    c->qf = UINT32_MAX;
    for (uint32_t i = 0; i < qn; i++)
        if ((qfp[i].queueFlags & g_ctx_queue_flags) == g_ctx_queue_flags) { c->qf = i; break; }
    if (c->qf == UINT32_MAX) { init_fail("no_compute_queue", VK_ERROR_FEATURE_NOT_PRESENT); return 0; }

    uint32_t en = 0;
    vkEnumerateDeviceExtensionProperties(c->pd, NULL, &en, NULL);
    VkExtensionProperties *ep = calloc(en ? en : 1, sizeof *ep);
    if (!ep) { init_fail("calloc", VK_ERROR_OUT_OF_HOST_MEMORY); return 0; }
    vkEnumerateDeviceExtensionProperties(c->pd, NULL, &en, ep);
    const char *enable[NELEM(k_want_exts)];
    uint32_t ne = 0;
    for (size_t w = 0; w < NELEM(k_want_exts); w++)
        for (uint32_t i = 0; i < en; i++)
            if (!strcmp(ep[i].extensionName, k_want_exts[w])) { enable[ne++] = k_want_exts[w]; break; }
    free(ep);
    for (uint32_t i = 0; i < ne; i++) {
        if (!strcmp(enable[i], "VK_EXT_external_memory_host")) c->ext_host = 1;
        if (!strcmp(enable[i], "VK_ANDROID_external_memory_android_hardware_buffer")) c->ext_ahb = 1;
        if (!strcmp(enable[i], "VK_EXT_external_memory_dma_buf")) c->ext_dmabuf = 1;
        if (!strcmp(enable[i], "VK_KHR_external_memory_fd")) c->ext_fd = 1;
        if (!strcmp(enable[i], "VK_EXT_queue_family_foreign")) c->ext_foreign = 1;
    }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = c->qf, .queueCount = 1, .pQueuePriorities = &prio};
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = ne, .ppEnabledExtensionNames = enable, .pEnabledFeatures = g_ctx_features};
    r = vkCreateDevice(c->pd, &dci, NULL, &c->dev);
    if (r) { init_fail("vkCreateDevice", r); return 0; }
    vkGetDeviceQueue(c->dev, c->qf, 0, &c->q);

    if (c->ext_host) {
        c->get_host_props = (PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(c->dev, "vkGetMemoryHostPointerPropertiesEXT");
        VkPhysicalDeviceExternalMemoryHostPropertiesEXT hp = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
        VkPhysicalDeviceProperties2 p2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &hp};
        vkGetPhysicalDeviceProperties2(c->pd, &p2);
        c->host_align = hp.minImportedHostPointerAlignment;
    }
    if (c->ext_ahb)
        c->get_ahb_props = (PFN_vkGetAndroidHardwareBufferPropertiesANDROID)vkGetDeviceProcAddr(c->dev, "vkGetAndroidHardwareBufferPropertiesANDROID");
    if (c->ext_fd) c->get_fd_props = (PFN_vkGetMemoryFdPropertiesKHR)vkGetDeviceProcAddr(c->dev, "vkGetMemoryFdPropertiesKHR");

    VkCommandPoolCreateInfo cpi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = c->qf};
    if ((r = vkCreateCommandPool(c->dev, &cpi, NULL, &c->cpool))) { init_fail("vkCreateCommandPool", r); return 0; }
    VkCommandBufferAllocateInfo cai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = c->cpool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    if ((r = vkAllocateCommandBuffers(c->dev, &cai, &c->cb))) { init_fail("vkAllocateCommandBuffers", r); return 0; }
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    if ((r = vkCreateFence(c->dev, &fci, NULL, &c->fence))) { init_fail("vkCreateFence", r); return 0; }

    VkDescriptorSetLayoutBinding b[2] = {
        {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT},
        {.binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT},
    };
    VkDescriptorSetLayoutCreateInfo dli = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 2, .pBindings = b};
    if ((r = vkCreateDescriptorSetLayout(c->dev, &dli, NULL, &c->dsl))) { init_fail("vkCreateDescriptorSetLayout", r); return 0; }
    VkPushConstantRange pcr = {.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .size = 8};
    VkPipelineLayoutCreateInfo pli = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &c->dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
    if ((r = vkCreatePipelineLayout(c->dev, &pli, NULL, &c->pl))) { init_fail("vkCreatePipelineLayout", r); return 0; }
    VkShaderModuleCreateInfo smi = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof k_xor_spv, .pCode = k_xor_spv};
    if ((r = vkCreateShaderModule(c->dev, &smi, NULL, &c->sm))) { init_fail("vkCreateShaderModule", r); return 0; }
    VkComputePipelineCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = c->sm, .pName = "main"},
        .layout = c->pl};
    if ((r = vkCreateComputePipelines(c->dev, VK_NULL_HANDLE, 1, &cpci, NULL, &c->pipe))) { init_fail("vkCreateComputePipelines", r); return 0; }
    VkDescriptorPoolSize ps = {.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2};
    VkDescriptorPoolCreateInfo dpi = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps};
    if ((r = vkCreateDescriptorPool(c->dev, &dpi, NULL, &c->dpool))) { init_fail("vkCreateDescriptorPool", r); return 0; }
    VkDescriptorSetAllocateInfo dai = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = c->dpool, .descriptorSetCount = 1, .pSetLayouts = &c->dsl};
    if ((r = vkAllocateDescriptorSets(c->dev, &dai, &c->ds))) { init_fail("vkAllocateDescriptorSets", r); return 0; }
    return 1;
}

static void ctx_destroy(Ctx *c) {
    if (!c->dev) { if (c->inst) vkDestroyInstance(c->inst, NULL); return; }
    vkDeviceWaitIdle(c->dev);
    vkDestroyDescriptorPool(c->dev, c->dpool, NULL);
    vkDestroyPipeline(c->dev, c->pipe, NULL);
    vkDestroyShaderModule(c->dev, c->sm, NULL);
    vkDestroyPipelineLayout(c->dev, c->pl, NULL);
    vkDestroyDescriptorSetLayout(c->dev, c->dsl, NULL);
    vkDestroyFence(c->dev, c->fence, NULL);
    vkDestroyCommandPool(c->dev, c->cpool, NULL);
    vkDestroyDevice(c->dev, NULL);
    vkDestroyInstance(c->inst, NULL);
}

// Picks a memory type from `bits`: HOST_VISIBLE|HOST_COHERENT first, then HOST_VISIBLE, then any.
static int pick_type(const Ctx *c, uint32_t bits) {
    static const VkMemoryPropertyFlags pref[] = {
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0};
    for (size_t p = 0; p < NELEM(pref); p++)
        for (uint32_t i = 0; i < c->memp.memoryTypeCount; i++)
            if ((bits & (1u << i)) && (c->memp.memoryTypes[i].propertyFlags & pref[p]) == pref[p]) return (int)i;
    return -1;
}

static void jtype(Js *j, const Ctx *c, const char *k, int type) {
    char name[160];
    jint(j, k, type);
    if (type < 0) return;
    mem_flag_names(c->memp.memoryTypes[type].propertyFlags, name, sizeof name);
    char key[64];
    snprintf(key, sizeof key, "%s_flags", k);
    jstr(j, key, name);
}

// ---------------------------------------------------------------- buffers

typedef struct {
    VkBuffer buf;
    VkDeviceMemory mem;
    int type;
    uint32_t req_bits;
    VkDeviceSize req_size;
    int dedicated;
    VkResult vr;
    const char *step;
    double us;
} Imp;

static VkBuffer make_buffer(const Ctx *c, VkDeviceSize size, VkExternalMemoryHandleTypeFlags ht, VkResult *r) {
    VkExternalMemoryBufferCreateInfo ext = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO, .handleTypes = ht};
    VkBufferCreateInfo bi = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .pNext = ht ? &ext : NULL, .size = size,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
    VkBuffer b = VK_NULL_HANDLE;
    *r = vkCreateBuffer(c->dev, &bi, NULL, &b);
    return b;
}

// Creates an external buffer and imports memory into it. `import_info` is the handle-specific
// VkImport*Info struct (its pNext is overwritten to chain a dedicated allocation when needed).
static void import_buffer(const Ctx *c, VkExternalMemoryHandleTypeFlagBits ht, VkDeviceSize size, VkDeviceSize alloc_size,
                          uint32_t import_bits, void *import_info, Imp *o) {
    memset(o, 0, sizeof *o);
    o->type = -1;
    double t0 = now_us();
    o->buf = make_buffer(c, size, ht, &o->vr);
    if (o->vr) { o->step = "vkCreateBuffer"; o->buf = VK_NULL_HANDLE; goto done; }
    VkMemoryDedicatedRequirements dr = {.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS};
    VkMemoryRequirements2 mr = {.sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2, .pNext = &dr};
    VkBufferMemoryRequirementsInfo2 mri = {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_REQUIREMENTS_INFO_2, .buffer = o->buf};
    vkGetBufferMemoryRequirements2(c->dev, &mri, &mr);
    o->req_bits = mr.memoryRequirements.memoryTypeBits;
    o->req_size = mr.memoryRequirements.size;
    o->dedicated = dr.requiresDedicatedAllocation ? 1 : 0;
    o->type = pick_type(c, o->req_bits & import_bits);
    if (o->type < 0) { o->step = "no_common_memory_type"; o->vr = VK_ERROR_FEATURE_NOT_PRESENT; goto done; }
    VkMemoryDedicatedAllocateInfo ded = {.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .buffer = o->buf};
    ((VkBaseOutStructure *)import_info)->pNext = o->dedicated ? (VkBaseOutStructure *)&ded : NULL;
    VkMemoryAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = import_info, .allocationSize = alloc_size, .memoryTypeIndex = (uint32_t)o->type};
    o->vr = vkAllocateMemory(c->dev, &ai, NULL, &o->mem);
    if (o->vr) { o->step = "vkAllocateMemory"; o->mem = VK_NULL_HANDLE; goto done; }
    o->vr = vkBindBufferMemory(c->dev, o->buf, o->mem, 0);
    if (o->vr) { o->step = "vkBindBufferMemory"; goto done; }
    o->step = "bound";
done:
    o->us = now_us() - t0;
}

static void imp_free(const Ctx *c, Imp *o) {
    if (o->buf) vkDestroyBuffer(c->dev, o->buf, NULL);
    if (o->mem) vkFreeMemory(c->dev, o->mem, NULL);
    o->buf = VK_NULL_HANDLE;
    o->mem = VK_NULL_HANDLE;
}

static void jimp(Js *j, const Ctx *c, const Imp *o) {
    jvk(j, o->step, o->vr);
    jhex(j, "req_bits", o->req_bits);
    juint(j, "req_size", o->req_size);
    jbool(j, "dedicated", o->dedicated);
    jtype(j, c, "type", o->type);
    jdbl(j, "import_us", o->us);
}

typedef struct {
    VkBuffer buf;
    VkDeviceMemory mem;
    uint32_t *ptr;
} Plain;

// Ordinary HOST_VISIBLE|HOST_COHERENT buffer used as the other side of every GPU transfer.
static VkResult plain_alloc(const Ctx *c, VkDeviceSize size, Plain *p) {
    memset(p, 0, sizeof *p);
    VkResult r;
    p->buf = make_buffer(c, size, 0, &r);
    if (r) { p->buf = VK_NULL_HANDLE; return r; }
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(c->dev, p->buf, &mr);
    int t = -1;
    VkMemoryPropertyFlags need = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    for (uint32_t i = 0; i < c->memp.memoryTypeCount && t < 0; i++)
        if ((mr.memoryTypeBits & (1u << i)) && (c->memp.memoryTypes[i].propertyFlags & need) == need) t = (int)i;
    if (t < 0) return VK_ERROR_FEATURE_NOT_PRESENT;
    VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = (uint32_t)t};
    if ((r = vkAllocateMemory(c->dev, &ai, NULL, &p->mem))) { p->mem = VK_NULL_HANDLE; return r; }
    if ((r = vkBindBufferMemory(c->dev, p->buf, p->mem, 0))) return r;
    void *m = NULL;
    if ((r = vkMapMemory(c->dev, p->mem, 0, VK_WHOLE_SIZE, 0, &m))) return r;
    p->ptr = m;
    return VK_SUCCESS;
}

static void plain_free(const Ctx *c, Plain *p) {
    if (p->buf) vkDestroyBuffer(c->dev, p->buf, NULL);
    if (p->mem) vkFreeMemory(c->dev, p->mem, NULL);
}

// ---------------------------------------------------------------- coherency

enum { CPU_PLAIN, CPU_AHB_CYCLE, CPU_DMABUF_SYNC };

typedef struct {
    VkBuffer buf;
    VkDeviceMemory mem; // set when CPU access goes through a Vulkan mapping that needs flush/invalidate
    VkDeviceSize size;
    uint8_t *cpu;       // CPU view (for CPU_AHB_CYCLE it is refreshed by every lock)
    int mode;
    int noncoherent;
    int qfot;           // acquire from / release to the foreign queue family around the dispatch
    AHardwareBuffer *ahb;
    int fd;
    VkDeviceSize win_off; // coherency covers [win_off, win_off + win_len) of the target when win_len != 0
    VkDeviceSize win_len;
} Target;

static int cpu_begin(Target *t, int write, int *err) {
    if (t->mode == CPU_AHB_CYCLE) {
        void *p = NULL;
        uint64_t u = write ? AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN : AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN;
        int e = AHardwareBuffer_lock(t->ahb, u, -1, NULL, &p);
        if (e) { *err = e; return 0; }
        t->cpu = p;
    } else if (t->mode == CPU_DMABUF_SYNC) {
        struct dma_buf_sync s = {.flags = DMA_BUF_SYNC_START | (write ? DMA_BUF_SYNC_WRITE : DMA_BUF_SYNC_READ)};
        if (ioctl(t->fd, DMA_BUF_IOCTL_SYNC, &s)) { *err = errno; return 0; }
    }
    return 1;
}

static int cpu_end(Target *t, int write, int *err) {
    if (t->mode == CPU_AHB_CYCLE) {
        int e = AHardwareBuffer_unlock(t->ahb, NULL);
        if (e) { *err = e; return 0; }
    } else if (t->mode == CPU_DMABUF_SYNC) {
        struct dma_buf_sync s = {.flags = DMA_BUF_SYNC_END | (write ? DMA_BUF_SYNC_WRITE : DMA_BUF_SYNC_READ)};
        if (ioctl(t->fd, DMA_BUF_IOCTL_SYNC, &s)) { *err = errno; return 0; }
    }
    return 1;
}

static uint32_t pat(uint32_t i, uint32_t seed) {
    uint32_t x = i * 0x9E3779B1u + seed;
    x ^= x >> 16;
    x *= 0x85EBCA6Bu;
    x ^= x >> 13;
    return x;
}

static void fill(uint32_t *p, size_t n, uint32_t seed) {
    for (size_t i = 0; i < n; i++) p[i] = pat((uint32_t)i, seed);
}

// Bytes that differ from pat(i, seed) ^ key; *first gets the first bad word index or -1.
static uint64_t mismatch(const volatile uint32_t *p, size_t n, uint32_t seed, uint32_t key, long long *first) {
    uint64_t bad = 0;
    *first = -1;
    for (size_t i = 0; i < n; i++) {
        uint32_t d = p[i] ^ pat((uint32_t)i, seed) ^ key;
        if (!d) continue;
        if (*first < 0) *first = (long long)i;
        bad += ((d & 0xFFu) != 0) + ((d & 0xFF00u) != 0) + ((d & 0xFF0000u) != 0) + ((d & 0xFF000000u) != 0);
    }
    return bad;
}

static void buf_barrier(const Ctx *c, const Target *t, int acquire) {
    uint32_t foreign = c->ext_foreign ? VK_QUEUE_FAMILY_FOREIGN_EXT : VK_QUEUE_FAMILY_EXTERNAL;
    VkBufferMemoryBarrier b = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = acquire ? 0 : VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = acquire ? (VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT) : 0,
        .srcQueueFamilyIndex = acquire ? foreign : c->qf,
        .dstQueueFamilyIndex = acquire ? c->qf : foreign,
        .buffer = t->buf, .size = VK_WHOLE_SIZE};
    vkCmdPipelineBarrier(c->cb, acquire ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT : VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         acquire ? VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT : VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 1, &b, 0, NULL);
}

// dst[i] = src[i] ^ key on the GPU, with host-write -> shader and shader-write -> host-read barriers.
static VkResult gpu_xor(const Ctx *c, VkBuffer src, VkBuffer dst, uint32_t words, const Target *t) {
    VkDescriptorBufferInfo bi[2] = {{.buffer = src, .range = VK_WHOLE_SIZE}, {.buffer = dst, .range = VK_WHOLE_SIZE}};
    if (t->win_len) {
        VkDescriptorBufferInfo *w = src == t->buf ? &bi[0] : &bi[1];
        w->offset = t->win_off;
        w->range = t->win_len;
    }
    VkWriteDescriptorSet w[2] = {
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = c->ds, .dstBinding = 0, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi[0]},
        {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = c->ds, .dstBinding = 1, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi[1]},
    };
    vkUpdateDescriptorSets(c->dev, 2, w, 0, NULL);
    VkResult r = vkResetCommandBuffer(c->cb, 0);
    if (r) return r;
    VkCommandBufferBeginInfo cbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    if ((r = vkBeginCommandBuffer(c->cb, &cbi))) return r;
    VkMemoryBarrier pre = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT};
    vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &pre, 0, NULL, 0, NULL);
    if (t->qfot) buf_barrier(c, t, 1);
    vkCmdBindPipeline(c->cb, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipe);
    vkCmdBindDescriptorSets(c->cb, VK_PIPELINE_BIND_POINT_COMPUTE, c->pl, 0, 1, &c->ds, 0, NULL);
    uint32_t pc[2] = {words, XOR_KEY};
    vkCmdPushConstants(c->cb, c->pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, pc);
    uint32_t groups = (words + 255) / 256;
    if (groups > 4096) groups = 4096;
    vkCmdDispatch(c->cb, groups, 1, 1);
    VkMemoryBarrier post = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &post, 0, NULL, 0, NULL);
    if (t->qfot) buf_barrier(c, t, 0);
    if ((r = vkEndCommandBuffer(c->cb))) return r;
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c->cb};
    if ((r = vkQueueSubmit(c->q, 1, &si, c->fence))) return r;
    r = vkWaitForFences(c->dev, 1, &c->fence, VK_TRUE, 5000000000ull);
    VkResult rr = vkResetFences(c->dev, 1, &c->fence);
    return r ? r : rr;
}

static void prefixed(char *out, size_t cap, const char *prefix, const char *k) { snprintf(out, cap, "%s%s", prefix, k); }

// Both directions on one imported target; adds `<prefix>*` fields. Returns 1 when both directions
// ran and every byte matched.
static int coherency(const Ctx *c, Target *t, Js *j, const char *prefix) {
    char k[96];
    VkDeviceSize len = t->win_len ? t->win_len : t->size;
    size_t n = (size_t)(len / 4);
    if (len > c->props.limits.maxStorageBufferRange) {
        prefixed(k, sizeof k, prefix, "coh"); jstr(j, k, "skip_over_maxStorageBufferRange");
        return 0;
    }
    Plain aux;
    VkResult r = plain_alloc(c, len, &aux);
    if (r) {
        plain_free(c, &aux);
        prefixed(k, sizeof k, prefix, "coh"); jstr(j, k, "fail");
        prefixed(k, sizeof k, prefix, "coh_step"); jstr(j, k, "aux_alloc");
        prefixed(k, sizeof k, prefix, "coh_vk"); jstr(j, k, vkr(r));
        return 0;
    }
    int ok = 0, err = 0;
    const char *step = "";
    long long first = -1;
    uint64_t bad1 = 0, bad2 = 0;
    VkMappedMemoryRange range = {.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = t->mem, .size = VK_WHOLE_SIZE};

    // CPU writes the target -> GPU reads it and writes aux -> CPU checks aux.
    memset(aux.ptr, 0xCD, len);
    if (!cpu_begin(t, 1, &err)) { step = "c2g_cpu_begin"; goto out; }
    fill((uint32_t *)(t->cpu + t->win_off), n, 0x1111u);
    if (!cpu_end(t, 1, &err)) { step = "c2g_cpu_end"; goto out; }
    if (t->noncoherent && (r = vkFlushMappedMemoryRanges(c->dev, 1, &range))) { step = "c2g_flush"; goto out; }
    if ((r = gpu_xor(c, t->buf, aux.buf, (uint32_t)n, t))) { step = "c2g_gpu"; goto out; }
    bad1 = mismatch(aux.ptr, n, 0x1111u, XOR_KEY, &first);
    prefixed(k, sizeof k, prefix, "c2g_bad_bytes"); juint(j, k, bad1);
    prefixed(k, sizeof k, prefix, "c2g_first_bad_word"); jint(j, k, first);

    // GPU reads aux and writes the target -> CPU reads the target through its own pointer.
    if (!cpu_begin(t, 1, &err)) { step = "g2c_cpu_begin_clear"; goto out; }
    memset(t->cpu + t->win_off, 0x5A, len);
    if (!cpu_end(t, 1, &err)) { step = "g2c_cpu_end_clear"; goto out; }
    if (t->noncoherent && (r = vkFlushMappedMemoryRanges(c->dev, 1, &range))) { step = "g2c_flush"; goto out; }
    fill(aux.ptr, n, 0x2222u);
    if ((r = gpu_xor(c, aux.buf, t->buf, (uint32_t)n, t))) { step = "g2c_gpu"; goto out; }
    if (t->noncoherent && (r = vkInvalidateMappedMemoryRanges(c->dev, 1, &range))) { step = "g2c_invalidate"; goto out; }
    if (!cpu_begin(t, 0, &err)) { step = "g2c_cpu_begin"; goto out; }
    bad2 = mismatch((const uint32_t *)(t->cpu + t->win_off), n, 0x2222u, XOR_KEY, &first);
    if (!cpu_end(t, 0, &err)) { step = "g2c_cpu_end"; goto out; }
    prefixed(k, sizeof k, prefix, "g2c_bad_bytes"); juint(j, k, bad2);
    prefixed(k, sizeof k, prefix, "g2c_first_bad_word"); jint(j, k, first);
    ok = bad1 == 0 && bad2 == 0;
    step = ok ? "match" : "mismatch";
out:
    prefixed(k, sizeof k, prefix, "coh"); jstr(j, k, ok ? "ok" : "fail");
    prefixed(k, sizeof k, prefix, "coh_step"); jstr(j, k, step);
    if (r) { prefixed(k, sizeof k, prefix, "coh_vk"); jstr(j, k, vkr(r)); }
    if (err) { prefixed(k, sizeof k, prefix, "coh_err"); jint(j, k, err); }
    plain_free(c, &aux);
    return ok;
}

// ---------------------------------------------------------------- memory backings

// A PROT_NONE window aligned to `align`, standing in for S2Arm's reserved guest address space.
static uint8_t *reserve_window(size_t size, size_t align, void **raw, size_t *raw_len) {
    *raw_len = size + align;
    *raw = mmap(NULL, *raw_len, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (*raw == MAP_FAILED) { *raw = NULL; return NULL; }
    return (uint8_t *)(((uintptr_t)*raw + align - 1) & ~(uintptr_t)(align - 1));
}

enum { BACK_ANON_PRIVATE, BACK_ANON_SHARED, BACK_MEMFD_FIXED, BACK_COUNT };
static const char *k_backing_names[] = {"anon_private", "anon_shared", "memfd_fixed"};

typedef struct {
    void *raw;
    size_t raw_len;
    uint8_t *p;
    int fd;
    int err;
    const char *step;
} Backing;

// Memory the size of `size` at an `align`-aligned address. memfd_fixed is the S2Arm shape: shared
// backing placed with MAP_FIXED into a reserved window (game address = host address).
static int backing_map(int kind, size_t size, size_t align, Backing *b) {
    memset(b, 0, sizeof *b);
    b->fd = -1;
    if (kind == BACK_MEMFD_FIXED) {
        uint8_t *w = reserve_window(size, align, &b->raw, &b->raw_len);
        if (!w) { b->err = errno; b->step = "reserve"; return 0; }
        b->fd = memfd_create("v0probe", MFD_CLOEXEC);
        if (b->fd < 0) { b->err = errno; b->step = "memfd_create"; return 0; }
        if (ftruncate(b->fd, (off_t)size)) { b->err = errno; b->step = "ftruncate"; return 0; }
        void *m = mmap(w, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, b->fd, 0);
        if (m == MAP_FAILED) { b->err = errno; b->step = "mmap_fixed"; return 0; }
        if (m != w) { b->err = EFAULT; b->step = "mmap_fixed_moved"; return 0; }
        b->p = w;
        return 1;
    }
    b->raw_len = size + align;
    int fl = MAP_ANONYMOUS | (kind == BACK_ANON_SHARED ? MAP_SHARED : MAP_PRIVATE);
    b->raw = mmap(NULL, b->raw_len, PROT_READ | PROT_WRITE, fl, -1, 0);
    if (b->raw == MAP_FAILED) { b->raw = NULL; b->err = errno; b->step = "mmap"; return 0; }
    b->p = (uint8_t *)(((uintptr_t)b->raw + align - 1) & ~(uintptr_t)(align - 1));
    return 1;
}

static void backing_free(Backing *b) {
    if (b->raw) munmap(b->raw, b->raw_len);
    if (b->fd >= 0) close(b->fd);
}

// ---------------------------------------------------------------- section A: device

static void sec_device(Ctx *c, int arg) {
    (void)arg;
    Js j;
    VkPhysicalDeviceDriverProperties drv = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
    VkPhysicalDeviceMaintenance3Properties m3 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_3_PROPERTIES};
    VkPhysicalDeviceProperties2 p2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &m3};
    int has_drv = c->props.apiVersion >= VK_API_VERSION_1_2;
    if (has_drv) m3.pNext = &drv;
    vkGetPhysicalDeviceProperties2(c->pd, &p2);
    const VkPhysicalDeviceProperties *p = &c->props;
    char api[32];
    snprintf(api, sizeof api, "%u.%u.%u", VK_API_VERSION_MAJOR(p->apiVersion), VK_API_VERSION_MINOR(p->apiVersion), VK_API_VERSION_PATCH(p->apiVersion));
    jbegin(&j, "device");
    jstatus(&j, "ok");
    jstr(&j, "gpu", p->deviceName);
    jhex(&j, "vendor_id", p->vendorID);
    jhex(&j, "device_id", p->deviceID);
    jhex(&j, "driver_version", p->driverVersion);
    jstr(&j, "api_version", api);
    if (has_drv) {
        jint(&j, "driver_id", drv.driverID);
        jstr(&j, "driver_name", drv.driverName);
        jstr(&j, "driver_info", drv.driverInfo);
    }
    jint(&j, "getpagesize", getpagesize());
    jint(&j, "sysconf_pagesize", sysconf(_SC_PAGESIZE));
    jint(&j, "queue_family", c->qf);
    juint(&j, "maxStorageBufferRange", p->limits.maxStorageBufferRange);
    juint(&j, "minStorageBufferOffsetAlignment", p->limits.minStorageBufferOffsetAlignment);
    juint(&j, "nonCoherentAtomSize", p->limits.nonCoherentAtomSize);
    juint(&j, "minMemoryMapAlignment", p->limits.minMemoryMapAlignment);
    juint(&j, "maxMemoryAllocationCount", p->limits.maxMemoryAllocationCount);
    juint(&j, "maxMemoryAllocationSize", m3.maxMemoryAllocationSize);
    jend(&j);

    for (uint32_t i = 0; i < c->memp.memoryHeapCount; i++) {
        jbegin(&j, "memheap");
        jint(&j, "i", i);
        juint(&j, "size", c->memp.memoryHeaps[i].size);
        jbool(&j, "device_local", c->memp.memoryHeaps[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT);
        jend(&j);
    }
    for (uint32_t i = 0; i < c->memp.memoryTypeCount; i++) {
        char name[160];
        mem_flag_names(c->memp.memoryTypes[i].propertyFlags, name, sizeof name);
        jbegin(&j, "memtype");
        jint(&j, "i", i);
        jint(&j, "heap", c->memp.memoryTypes[i].heapIndex);
        jhex(&j, "flags", c->memp.memoryTypes[i].propertyFlags);
        jstr(&j, "names", name);
        jend(&j);
    }

    uint32_t en = 0;
    vkEnumerateDeviceExtensionProperties(c->pd, NULL, &en, NULL);
    VkExtensionProperties *ep = calloc(en ? en : 1, sizeof *ep);
    if (ep) {
        vkEnumerateDeviceExtensionProperties(c->pd, NULL, &en, ep);
        jbegin(&j, "extensions");
        jint(&j, "count", en);
        jkey(&j, "memory_related");
        jraw(&j, "[");
        int first = 1;
        for (uint32_t i = 0; i < en; i++) {
            const char *nm = ep[i].extensionName;
            if (!strstr(nm, "memory") && !strstr(nm, "external") && !strstr(nm, "foreign") && !strstr(nm, "dedicated")) continue;
            jraw(&j, "%s", first ? "" : ",");
            jesc(&j, nm);
            first = 0;
        }
        jraw(&j, "]");
        jend(&j);
        free(ep);
    }

    jbegin(&j, "host_ext");
    jstatus(&j, c->ext_host ? "ok" : "unsupported");
    jbool(&j, "VK_EXT_external_memory_host", c->ext_host);
    if (c->ext_host) juint(&j, "minImportedHostPointerAlignment", c->host_align);
    jbool(&j, "VK_ANDROID_external_memory_android_hardware_buffer", c->ext_ahb);
    jbool(&j, "VK_KHR_external_memory_fd", c->ext_fd);
    jbool(&j, "VK_EXT_external_memory_dma_buf", c->ext_dmabuf);
    jbool(&j, "VK_EXT_queue_family_foreign", c->ext_foreign);
    jend(&j);

    static const struct { VkExternalMemoryHandleTypeFlagBits ht; const char *name; int need; } hts[] = {
        {VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT, "opaque_fd", 0},
        {VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, "host_allocation", 1},
        {VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID, "android_hardware_buffer", 2},
        {VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, "dma_buf", 3},
    };
    for (size_t i = 0; i < NELEM(hts); i++) {
        int have = hts[i].need == 0 || (hts[i].need == 1 && c->ext_host) || (hts[i].need == 2 && c->ext_ahb) || (hts[i].need == 3 && c->ext_dmabuf);
        jbegin(&j, "ext_buffer_props");
        jstr(&j, "handle", hts[i].name);
        if (!have) {
            jstatus(&j, "unsupported");
            jend(&j);
            continue;
        }
        VkPhysicalDeviceExternalBufferInfo info = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO,
            .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .handleType = hts[i].ht};
        VkExternalBufferProperties out = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES};
        vkGetPhysicalDeviceExternalBufferProperties(c->pd, &info, &out);
        VkExternalMemoryFeatureFlags f = out.externalMemoryProperties.externalMemoryFeatures;
        jstatus(&j, (f & VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT) ? "ok" : "not_importable");
        jbool(&j, "importable", f & VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT);
        jbool(&j, "exportable", f & VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT);
        jbool(&j, "dedicated_only", f & VK_EXTERNAL_MEMORY_FEATURE_DEDICATED_ONLY_BIT);
        jhex(&j, "compatible", out.externalMemoryProperties.compatibleHandleTypes);
        jhex(&j, "export_from_imported", out.externalMemoryProperties.exportFromImportedHandleTypes);
        jend(&j);
    }
}

// ---------------------------------------------------------------- section B/C: host pointer

static size_t host_align(const Ctx *c) {
    size_t a = (size_t)c->host_align;
    return a > (size_t)c->page ? a : (size_t)c->page;
}

static int host_unsupported(const Ctx *c, const char *sec) {
    if (c->ext_host && c->get_host_props) return 0;
    Js j;
    jbegin(&j, sec);
    jstatus(&j, "unsupported");
    jstr(&j, "reason", "VK_EXT_external_memory_host absent");
    jend(&j);
    return 1;
}

static void host_props_line(const Ctx *c, const char *sec, const char *backing, size_t size, size_t off, void *p) {
    Js j;
    VkMemoryHostPointerPropertiesEXT hp = {.sType = VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
    double t0 = now_us();
    VkResult r = c->get_host_props(c->dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, p, &hp);
    double us = now_us() - t0;
    jbegin(&j, sec);
    jstatus(&j, r ? "fail" : "ok");
    jstr(&j, "backing", backing);
    juint(&j, "size", size);
    juint(&j, "offset", off);
    jbool(&j, "violates_alignment_vu", c->host_align && off % c->host_align);
    jvk(&j, "vkGetMemoryHostPointerPropertiesEXT", r);
    jhex(&j, "memory_type_bits", r ? 0 : hp.memoryTypeBits);
    jdbl(&j, "props_us", us);
    jend(&j);
}

static void sec_host_props(Ctx *c, int arg) {
    (void)arg;
    if (host_unsupported(c, "host_props")) return;
    size_t a = host_align(c);
    for (int k = 0; k < BACK_COUNT; k++)
        for (size_t s = 0; s < NELEM(k_test_sizes); s++) {
            Backing b;
            if (!backing_map(k, k_test_sizes[s], a, &b)) {
                Js j;
                jbegin(&j, "host_props");
                jstatus(&j, "fail");
                jstr(&j, "backing", k_backing_names[k]);
                juint(&j, "size", k_test_sizes[s]);
                jerrno(&j, b.step, b.err);
                jend(&j);
            } else {
                host_props_line(c, "host_props", k_backing_names[k], k_test_sizes[s], 0, b.p);
            }
            backing_free(&b);
        }
}

static void host_import_one(Ctx *c, int kind, size_t size, int run_coherency) {
    Js j;
    const char *sec = run_coherency ? "host_import" : "host_max";
    size_t a = host_align(c);
    jbegin(&j, sec);
    jstr(&j, "backing", k_backing_names[kind]);
    juint(&j, "size", size);
    juint(&j, "alignment_used", a);
    if (size % a) {
        jstatus(&j, "skip");
        jstr(&j, "reason", "size_not_multiple_of_alignment");
        jend(&j);
        return;
    }
    Backing b;
    if (!backing_map(kind, size, a, &b)) {
        jstatus(&j, "fail");
        jerrno(&j, b.step, b.err);
        jend(&j);
        backing_free(&b);
        return;
    }
    jhex(&j, "host_ptr_mod_64k", (uintptr_t)b.p & 0xFFFF);
    VkMemoryHostPointerPropertiesEXT hp = {.sType = VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
    double t0 = now_us();
    VkResult r = c->get_host_props(c->dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, b.p, &hp);
    jdbl(&j, "props_us", now_us() - t0);
    jstr(&j, "props_vk", vkr(r));
    jhex(&j, "memory_type_bits", r ? 0 : hp.memoryTypeBits);
    if (r) {
        jstatus(&j, "fail");
        jvk(&j, "vkGetMemoryHostPointerPropertiesEXT", r);
        jend(&j);
        backing_free(&b);
        return;
    }
    VkImportMemoryHostPointerInfoEXT imp = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, .pHostPointer = b.p};
    Imp o;
    import_buffer(c, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, size, size, hp.memoryTypeBits, &imp, &o);
    jimp(&j, c, &o);
    if (o.vr) {
        jstatus(&j, "fail");
        jend(&j);
        imp_free(c, &o);
        backing_free(&b);
        return;
    }
    VkMemoryPropertyFlags f = c->memp.memoryTypes[o.type].propertyFlags;
    Target t = {.buf = o.buf, .size = size, .cpu = b.p, .mode = CPU_PLAIN, .fd = -1};
    if (f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) {
        void *m = NULL;
        VkResult mr = vkMapMemory(c->dev, o.mem, 0, VK_WHOLE_SIZE, 0, &m);
        jstr(&j, "map_vk", vkr(mr));
        if (!mr) jbool(&j, "map_ptr_eq_host_ptr", m == (void *)b.p);
        if (!mr && !(f & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) { t.mem = o.mem; t.noncoherent = 1; }
    }
    jbool(&j, "noncoherent_flush_used", t.noncoherent);
    int ok = 1;
    if (run_coherency) ok = coherency(c, &t, &j, "");
    jstatus(&j, ok ? "ok" : "fail");
    jend(&j);
    imp_free(c, &o);
    backing_free(&b);
}

static void sec_host_import(Ctx *c, int arg) {
    (void)arg;
    if (host_unsupported(c, "host_import")) return;
    for (int k = 0; k < BACK_COUNT; k++)
        for (size_t s = 0; s < NELEM(k_test_sizes); s++) host_import_one(c, k, k_test_sizes[s], 1);
    for (size_t s = 0; s < NELEM(k_max_sizes); s++) {
        host_import_one(c, BACK_ANON_PRIVATE, k_max_sizes[s], 0);
        host_import_one(c, BACK_MEMFD_FIXED, k_max_sizes[s], 0);
    }
}

// Calls that break a Valid Usage rule when the offset / size is not aligned. Each case runs in its
// own child because a driver may crash on them; the result documents driver behaviour only.
static void sec_host_unaligned(Ctx *c, int which) {
    if (host_unsupported(c, "host_unaligned")) return;
    size_t a = host_align(c);
    Backing b;
    if (!backing_map(BACK_ANON_PRIVATE, 4 * a, a, &b)) {
        Js j;
        jbegin(&j, "host_unaligned");
        jstatus(&j, "fail");
        jerrno(&j, b.step, b.err);
        jend(&j);
        backing_free(&b);
        return;
    }
    static const struct { size_t off_kind, size_kind; int import; } cases[] = {
        {1, 0, 0}, // props at +64
        {2, 0, 0}, // props at +page/2
        {1, 1, 1}, // import at +64, size = alignment
        {0, 2, 1}, // import aligned, size = alignment + 64
        {0, 3, 1}, // import aligned, size = 4 KiB
    };
    size_t off = cases[which].off_kind == 1 ? 64 : cases[which].off_kind == 2 ? (size_t)c->page / 2 : 0;
    size_t size = cases[which].size_kind == 1 ? a : cases[which].size_kind == 2 ? a + 64 : 4 * KB;
    if (!cases[which].import) {
        host_props_line(c, "host_unaligned", "anon_private", 0, off, b.p + off);
        backing_free(&b);
        return;
    }
    Js j;
    jbegin(&j, "host_unaligned");
    jstr(&j, "backing", "anon_private");
    juint(&j, "offset", off);
    juint(&j, "size", size);
    jbool(&j, "violates_alignment_vu", c->host_align && ((off % c->host_align) || (size % c->host_align)));
    VkMemoryHostPointerPropertiesEXT hp = {.sType = VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
    VkResult r = c->get_host_props(c->dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, b.p + off, &hp);
    jstr(&j, "props_vk", vkr(r));
    uint32_t bits = r ? ~0u : hp.memoryTypeBits;
    VkImportMemoryHostPointerInfoEXT imp = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, .pHostPointer = b.p + off};
    Imp o;
    import_buffer(c, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, size, size, bits, &imp, &o);
    jimp(&j, c, &o);
    jstatus(&j, o.vr ? "rejected" : "accepted");
    jend(&j);
    imp_free(c, &o);
    backing_free(&b);
}

// ---------------------------------------------------------------- section D1: AHardwareBuffer

// Receives the native handle fds of an AHardwareBuffer (fds[0] is the gralloc dma-buf on current
// gralloc implementations; the probe only reports what it gets).
static int ahb_fds(AHardwareBuffer *h, int *fds, int cap, int *err) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sv)) { *err = errno; return -1; }
    int e = AHardwareBuffer_sendHandleToUnixSocket(h, sv[0]);
    if (e) { *err = e; close(sv[0]); close(sv[1]); return -1; }
    char data[4096];
    char ctl[CMSG_SPACE(sizeof(int) * 32)];
    struct iovec iov = {.iov_base = data, .iov_len = sizeof data};
    struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl, .msg_controllen = sizeof ctl};
    ssize_t got = recvmsg(sv[1], &m, MSG_CMSG_CLOEXEC);
    close(sv[0]);
    close(sv[1]);
    if (got < 0) { *err = errno; return -1; }
    int n = 0;
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&m); cm; cm = CMSG_NXTHDR(&m, cm)) {
        if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS) continue;
        int k = (int)((cm->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        int *src = (int *)CMSG_DATA(cm);
        for (int i = 0; i < k; i++) {
            if (n < cap) fds[n++] = src[i];
            else close(src[i]);
        }
    }
    return n;
}

enum { AHB_ALLOC_ONLY, AHB_FULL, AHB_WINDOW };
#define AHB_WINDOW_BYTES (1 * MB)

// Custom size list from argv[2] or S2A_AHB_SIZES_MIB ("384,400,512"); NULL keeps the default sizes.
static const char *g_ahb_sizes;

static void ahb_one(Ctx *c, uint64_t size, int mode) {
    const int run_coherency = mode == AHB_FULL;
    Js j;
    jbegin(&j, mode == AHB_FULL ? "ahb" : mode == AHB_WINDOW ? "ahb_size" : "ahb_max");
    juint(&j, "size", size);
    if (size > AHB_LIMIT_BYTES) {
        jstatus(&j, "refused");
        jstr(&j, "step", "size_over_ahb_limit");
        juint(&j, "limit", AHB_LIMIT_BYTES);
        jend(&j);
        return;
    }
    AHardwareBuffer_Desc d = {
        .width = (uint32_t)size, .height = 1, .layers = 1, .format = AHARDWAREBUFFER_FORMAT_BLOB,
        .usage = AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN | AHARDWAREBUFFER_USAGE_GPU_DATA_BUFFER};
    AHardwareBuffer *h = NULL;
    double t0 = now_us();
    int e = AHardwareBuffer_allocate(&d, &h);
    jdbl(&j, "ahb_alloc_us", now_us() - t0);
    if (e) {
        jstatus(&j, "fail");
        jstr(&j, "step", "AHardwareBuffer_allocate");
        jint(&j, "ahb_err", e);
        jend(&j);
        return;
    }
    AHardwareBuffer_Desc got;
    AHardwareBuffer_describe(h, &got);
    juint(&j, "desc_width", got.width);
    juint(&j, "desc_stride", got.stride);
    VkAndroidHardwareBufferPropertiesANDROID ap = {.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID};
    VkResult r = c->get_ahb_props(c->dev, h, &ap);
    jstr(&j, "props_vk", vkr(r));
    juint(&j, "props_allocation_size", r ? 0 : ap.allocationSize);
    jhex(&j, "memory_type_bits", r ? 0 : ap.memoryTypeBits);
    if (r) {
        jstatus(&j, "fail");
        jvk(&j, "vkGetAndroidHardwareBufferPropertiesANDROID", r);
        jend(&j);
        AHardwareBuffer_release(h);
        return;
    }
    VkImportAndroidHardwareBufferInfoANDROID imp = {.sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID, .buffer = h};
    Imp o;
    import_buffer(c, VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID, size, ap.allocationSize, ap.memoryTypeBits, &imp, &o);
    jimp(&j, c, &o);
    if (!o.vr && mode == AHB_WINDOW) {
        // Only the first and last 1 MiB are written / read, to keep large sizes cheap.
        Target th = {.buf = o.buf, .size = size, .mode = CPU_AHB_CYCLE, .qfot = 1, .ahb = h, .fd = -1, .win_off = 0, .win_len = AHB_WINDOW_BYTES};
        int wok = coherency(c, &th, &j, "head_");
        Target tt = th;
        tt.win_off = size - AHB_WINDOW_BYTES;
        wok &= coherency(c, &tt, &j, "tail_");
        jstatus(&j, wok ? "ok" : "fail");
        jend(&j);
        imp_free(c, &o);
        AHardwareBuffer_release(h);
        return;
    }
    if (o.vr || !run_coherency) {
        jstatus(&j, o.vr ? "fail" : "ok");
        jend(&j);
        imp_free(c, &o);
        AHardwareBuffer_release(h);
        return;
    }

    // Lock / unlock around every CPU access (the documented protocol).
    Target t = {.buf = o.buf, .size = size, .mode = CPU_AHB_CYCLE, .qfot = 1, .ahb = h, .fd = -1};
    int ok = coherency(c, &t, &j, "cycle_");

    // One lock held for the whole test: closest to how game memory would be used.
    void *p = NULL;
    e = AHardwareBuffer_lock(h, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, NULL, &p);
    if (e) {
        jint(&j, "persistent_lock_err", e);
        ok = 0;
    } else {
        jhex(&j, "lock_ptr_mod_64k", (uintptr_t)p & 0xFFFF);
        Target tp = {.buf = o.buf, .size = size, .cpu = p, .mode = CPU_PLAIN, .qfot = 1, .fd = -1};
        ok &= coherency(c, &tp, &j, "persistent_");
        void *p2 = NULL;
        AHardwareBuffer_unlock(h, NULL);
        if (!AHardwareBuffer_lock(h, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, -1, NULL, &p2)) {
            jbool(&j, "lock_ptr_stable", p2 == p);
            AHardwareBuffer_unlock(h, NULL);
        }
    }

    // CPU view placed by the caller: mmap the AHB's dma-buf fd with MAP_FIXED into a reserved window.
    int fds[32], ferr = 0;
    int nf = ahb_fds(h, fds, 32, &ferr);
    jint(&j, "native_handle_fds", nf);
    if (nf < 1) {
        jint(&j, "fixed_fd_err", ferr);
        jstr(&j, "fixed", "fail_no_fd");
    } else {
        void *raw = NULL;
        size_t raw_len = 0;
        uint8_t *w = reserve_window(size, 2 * MB, &raw, &raw_len);
        void *m = w ? mmap(w, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fds[0], 0) : MAP_FAILED;
        if (m == MAP_FAILED || m != w) {
            jint(&j, "fixed_mmap_errno", w ? errno : ENOMEM);
            jstr(&j, "fixed", "fail_mmap");
        } else {
            jstr(&j, "fixed", "mapped");
            Target tf = {.buf = o.buf, .size = size, .cpu = w, .mode = CPU_PLAIN, .qfot = 1, .fd = fds[0]};
            int fok = coherency(c, &tf, &j, "fixed_nosync_");
            tf.mode = CPU_DMABUF_SYNC;
            fok &= coherency(c, &tf, &j, "fixed_sync_");
            // Same bytes seen through the lock pointer?
            ((volatile uint32_t *)w)[0] = 0x600DF00Du;
            void *lp = NULL;
            if (!AHardwareBuffer_lock(h, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, -1, NULL, &lp)) {
                jbool(&j, "fixed_alias_lock_ptr", *(volatile uint32_t *)lp == 0x600DF00Du);
                AHardwareBuffer_unlock(h, NULL);
            }
            jbool(&j, "fixed_ok", fok);
        }
        if (raw) munmap(raw, raw_len);
        for (int i = 0; i < nf; i++) close(fds[i]);
    }
    jstatus(&j, ok ? "ok" : "fail");
    jend(&j);
    imp_free(c, &o);
    AHardwareBuffer_release(h);
}

static void sec_ahb(Ctx *c, int arg) {
    (void)arg;
    if (!c->ext_ahb || !c->get_ahb_props) {
        Js j;
        jbegin(&j, "ahb");
        jstatus(&j, "unsupported");
        jstr(&j, "reason", "VK_ANDROID_external_memory_android_hardware_buffer absent");
        jend(&j);
        return;
    }
    if (g_ahb_sizes) {
        const char *p = g_ahb_sizes;
        while (*p) {
            char *end;
            unsigned long long mib = strtoull(p, &end, 10);
            if (end == p) break;
            if (mib * MB > 2 * AHB_WINDOW_BYTES) ahb_one(c, mib * MB, AHB_WINDOW);
            p = *end == ',' ? end + 1 : end;
        }
        return;
    }
    for (size_t s = 0; s < NELEM(k_test_sizes); s++) ahb_one(c, k_test_sizes[s], AHB_FULL);
    for (size_t s = 0; s < NELEM(k_ahb_max_sizes); s++) ahb_one(c, k_ahb_max_sizes[s], AHB_ALLOC_ONLY);
}

// ---------------------------------------------------------------- section D2: dma-buf heap

static const char *k_heaps[] = {"system", "system-uncached", "qcom,system", "mtk_mm"};

static void dmabuf_one(Ctx *c, int heapfd, const char *heap, uint64_t size, int run_coherency) {
    Js j;
    jbegin(&j, run_coherency ? "dmabuf" : "dmabuf_max");
    jstr(&j, "heap", heap);
    juint(&j, "size", size);
    struct dma_heap_allocation_data ad = {.len = size, .fd_flags = O_RDWR | O_CLOEXEC};
    double t0 = now_us();
    if (ioctl(heapfd, DMA_HEAP_IOCTL_ALLOC, &ad)) {
        jstatus(&j, "fail");
        jerrno(&j, "DMA_HEAP_IOCTL_ALLOC", errno);
        jend(&j);
        return;
    }
    int fd = (int)ad.fd;
    jdbl(&j, "heap_alloc_us", now_us() - t0);
    void *raw = NULL;
    size_t raw_len = 0;
    uint8_t *w = reserve_window(size, 2 * MB, &raw, &raw_len);
    void *m = w ? mmap(w, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0) : MAP_FAILED;
    int fixed = m != MAP_FAILED && m == w;
    jbool(&j, "mmap_fixed_ok", fixed);
    if (!fixed) jint(&j, "mmap_errno", w ? errno : ENOMEM);
    VkMemoryFdPropertiesKHR fp = {.sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR};
    VkResult r = c->get_fd_props(c->dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, &fp);
    jstr(&j, "props_vk", vkr(r));
    jhex(&j, "memory_type_bits", r ? 0 : fp.memoryTypeBits);
    int ok = 0;
    Imp o = {0};
    if (r) {
        jvk(&j, "vkGetMemoryFdPropertiesKHR", r);
        goto out;
    }
    int dfd = dup(fd); // a successful import takes ownership of the fd
    VkImportMemoryFdInfoKHR imp = {.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = dfd};
    import_buffer(c, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, size, size, fp.memoryTypeBits, &imp, &o);
    if (!o.mem) close(dfd);
    jimp(&j, c, &o);
    if (o.vr) goto out;
    ok = 1;
    if (run_coherency && fixed) {
        Target t = {.buf = o.buf, .size = size, .cpu = w, .mode = CPU_DMABUF_SYNC, .qfot = 1, .fd = fd};
        ok = coherency(c, &t, &j, "sync_");
        t.mode = CPU_PLAIN;
        ok &= coherency(c, &t, &j, "nosync_");
    } else if (run_coherency) {
        ok = 0;
    }
out:
    jstatus(&j, ok ? "ok" : "fail");
    jend(&j);
    imp_free(c, &o);
    if (raw) munmap(raw, raw_len);
    close(fd);
}

static void sec_dmabuf(Ctx *c, int arg) {
    (void)arg;
    Js j;
    jbegin(&j, "dma_heaps");
    DIR *dir = opendir("/dev/dma_heap");
    if (!dir) {
        jstatus(&j, "fail");
        jerrno(&j, "opendir", errno);
    } else {
        jstatus(&j, "ok");
        jkey(&j, "names");
        jraw(&j, "[");
        int first = 1;
        for (struct dirent *de; (de = readdir(dir));) {
            if (de->d_name[0] == '.') continue;
            jraw(&j, "%s", first ? "" : ",");
            jesc(&j, de->d_name);
            first = 0;
        }
        jraw(&j, "]");
        closedir(dir);
    }
    jend(&j);
    if (!c->ext_dmabuf || !c->ext_fd || !c->get_fd_props) {
        jbegin(&j, "dmabuf");
        jstatus(&j, "unsupported");
        jstr(&j, "reason", "VK_EXT_external_memory_dma_buf or VK_KHR_external_memory_fd absent");
        jend(&j);
        return;
    }
    for (size_t h = 0; h < NELEM(k_heaps); h++) {
        char path[96];
        snprintf(path, sizeof path, "/dev/dma_heap/%s", k_heaps[h]);
        int hfd = open(path, O_RDONLY | O_CLOEXEC);
        if (hfd < 0) {
            int e = errno;
            jbegin(&j, "dmabuf");
            jstr(&j, "heap", k_heaps[h]);
            jstatus(&j, e == ENOENT ? "absent" : "fail");
            jerrno(&j, "open", e);
            jend(&j);
            continue;
        }
        for (size_t s = 0; s < NELEM(k_test_sizes); s++) dmabuf_one(c, hfd, k_heaps[h], k_test_sizes[s], 1);
        for (size_t s = 0; s < NELEM(k_max_sizes); s++) dmabuf_one(c, hfd, k_heaps[h], k_max_sizes[s], 0);
        close(hfd);
    }
}

// ---------------------------------------------------------------- driver

typedef void (*SecFn)(Ctx *c, int arg);

typedef struct {
    const char *name;
    SecFn fn;
    int arg;
} Section;

static const Section k_sections[] = {
    {"device", sec_device, 0},
    {"host_props", sec_host_props, 0},
    {"host_import", sec_host_import, 0},
    {"host_unaligned_0", sec_host_unaligned, 0},
    {"host_unaligned_1", sec_host_unaligned, 1},
    {"host_unaligned_2", sec_host_unaligned, 2},
    {"host_unaligned_3", sec_host_unaligned, 3},
    {"host_unaligned_4", sec_host_unaligned, 4},
    {"ahb", sec_ahb, 0},
    {"dmabuf", sec_dmabuf, 0},
};

#ifndef V0PROBE_NO_MAIN
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *only = argc > 1 ? argv[1] : NULL;
    g_ahb_sizes = argc > 2 ? argv[2] : getenv("S2A_AHB_SIZES_MIB");
    if (g_ahb_sizes && !*g_ahb_sizes) g_ahb_sizes = NULL;
    Js j;
    for (const char *p = g_ahb_sizes; p && *p;) {
        char *end;
        unsigned long long mib = strtoull(p, &end, 10);
        if (end == p) break;
        if (mib * MB > AHB_LIMIT_BYTES) {
            fprintf(stderr, "v0probe: AHB size %llu MiB is over the %llu MiB limit; refusing to run\n", mib, (unsigned long long)(AHB_LIMIT_BYTES / MB));
            jbegin(&j, "args");
            jstatus(&j, "refused");
            juint(&j, "ahb_size_mib", mib);
            juint(&j, "limit_mib", AHB_LIMIT_BYTES / MB);
            jend(&j);
            return 2;
        }
        p = *end == ',' ? end + 1 : end;
    }
    double t0 = now_us();
    jbegin(&j, "start");
    jstr(&j, "rev", PROBE_REV);
    jint(&j, "pid", getpid());
    jint(&j, "uid", getuid());
    jint(&j, "page", sysconf(_SC_PAGESIZE));
    jend(&j);
    int done = 0, ran = 0;
    for (size_t i = 0; i < NELEM(k_sections); i++) {
        if (only && strcmp(only, k_sections[i].name)) continue;
        ran++;
        double s0 = now_us();
        pid_t pid = fork();
        if (pid == 0) {
            alarm(SECTION_ALARM_S);
            Ctx c;
            int ok = ctx_init(&c);
            if (ok) k_sections[i].fn(&c, k_sections[i].arg);
            ctx_destroy(&c);
            fflush(stdout);
            _exit(ok ? 0 : 2);
        }
        int st = 0;
        if (pid < 0 || waitpid(pid, &st, 0) < 0) st = -1;
        jbegin(&j, "section");
        jstr(&j, "name", k_sections[i].name);
        if (st == -1) {
            jstatus(&j, "fail");
            jerrno(&j, "fork_or_wait", errno);
        } else if (WIFSIGNALED(st)) {
            jstatus(&j, WTERMSIG(st) == SIGALRM ? "timeout" : "crash");
            jint(&j, "signal", WTERMSIG(st));
        } else {
            jstatus(&j, WEXITSTATUS(st) == 0 ? "done" : "init_fail");
            jint(&j, "exit", WEXITSTATUS(st));
            done += WEXITSTATUS(st) == 0;
        }
        jdbl(&j, "ms", (now_us() - s0) / 1000.0);
        jend(&j);
    }
    jbegin(&j, "end");
    jint(&j, "sections_run", ran);
    jint(&j, "sections_done", done);
    jdbl(&j, "total_ms", (now_us() - t0) / 1000.0);
    jend(&j);
    return done == ran ? 0 : 1;
}
#endif

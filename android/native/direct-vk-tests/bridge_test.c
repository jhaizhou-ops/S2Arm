// Actual bridge + actual window lease; the Vulkan dispatch is a controlled driver.
#include "direct_vk.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define INSTANCE ((VkInstance)(uintptr_t)0x100)
#define DEVICE ((VkDevice)(uintptr_t)0x200)
#define SURFACE ((VkSurfaceKHR)(uintptr_t)0x300)
static unsigned checks, wrapped, errors, created, destroyed, begin, end, retained, released;
static VkResult create_error, instance_error, wait_result;
static int window_object, guest_token;
static VkPhysicalDevice16BitStorageFeatures storage16;
static VkPhysicalDeviceDescriptorIndexingFeatures indexing;
static VkPhysicalDeviceFeatures2 features2;
static unsigned template_calls;
static s2a_wsi_lease *lease;
static struct s2a_wsi_api api;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
#define GET(name) ((PFN_##name)s2a_vk_entry(#name))

static void retain(void *w) { CHECK(w == &window_object); retained++; }
static void release(void *w) { CHECK(w == &window_object); released++; }
static void report(const char *name, VkResult r) { CHECK(name && *name && r < 0); errors++; }
static void fatal(const char *name) { CHECK(name && *name); _Exit(72); }
static void *wrap(const char *name, void *fn) { CHECK(name && !strncmp(name, "vk", 2) && fn); wrapped++; return fn; }
static void block_begin(void) { CHECK(begin == end); begin++; }
static void block_end(void) { CHECK(begin == end + 1); end++; }
static const struct s2a_wsi_api *window(void *token) { return token == &guest_token ? &api : NULL; }
static void dummy(void) {}

static VKAPI_ATTR VkResult VKAPI_CALL fake_create(const VkInstanceCreateInfo *info,
    const VkAllocationCallbacks *allocator, VkInstance *out) {
    CHECK(!allocator && !info->pNext);
    CHECK(info->enabledExtensionCount == 2);
    CHECK(!strcmp(info->ppEnabledExtensionNames[0], VK_KHR_SURFACE_EXTENSION_NAME));
    CHECK(!strcmp(info->ppEnabledExtensionNames[1], VK_KHR_ANDROID_SURFACE_EXTENSION_NAME));
    if (instance_error) return instance_error;
    *out = INSTANCE;
    created++;
    return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL fake_destroy(VkInstance i, const VkAllocationCallbacks *a) {
    CHECK(i == INSTANCE && !a); destroyed++;
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_extensions(const char *layer, uint32_t *n, VkExtensionProperties *p) {
    if (layer) { *n = 0; return VK_SUCCESS; }
    if (!p) { *n = 3; return VK_SUCCESS; }
    CHECK(*n >= 3);
    strcpy(p[0].extensionName, VK_KHR_SURFACE_EXTENSION_NAME);
    strcpy(p[1].extensionName, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME);
    strcpy(p[2].extensionName, "VK_EXT_debug_utils"); // Unsupported callbacks must not be advertised.
    p[0].specVersion = p[1].specVersion = 1;
    *n = 3;
    return VK_SUCCESS;
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_surface(VkInstance i, const VkAndroidSurfaceCreateInfoKHR *info,
    const VkAllocationCallbacks *a, VkSurfaceKHR *s) {
    CHECK(i == INSTANCE && !a && info->window == (void *)&window_object);
    CHECK(info->sType == VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR && !info->pNext && !info->flags);
    if (create_error) return create_error;
    *s = SURFACE;
    return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL fake_surface_destroy(VkInstance i, VkSurfaceKHR s, const VkAllocationCallbacks *a) {
    CHECK(i == INSTANCE && s == SURFACE && !a);
    // The lease must still be held when the driver destroys the surface.
    CHECK(s2a_wsi_revoke(lease, 0) == ETIMEDOUT);
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_wait(VkDevice d, uint32_t n, const VkFence *f, VkBool32 all, uint64_t timeout) {
    CHECK(d == DEVICE && n == 0 && !f && all == VK_TRUE && timeout == 123);
    CHECK(begin == end + 1);
    return wait_result;
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_buffer(VkDevice d, const VkBufferCreateInfo *i,
    const VkAllocationCallbacks *a, VkBuffer *b) {
    CHECK(d == DEVICE && i && !a); *b = (VkBuffer)(uintptr_t)0x400; return VK_SUCCESS;
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_device(VkPhysicalDevice p, const VkDeviceCreateInfo *info,
    const VkAllocationCallbacks *a, VkDevice *out) {
    CHECK(p && !a && info->pNext == &features2 && !info->pEnabledFeatures);
    CHECK(features2.pNext == &storage16 && storage16.storageBuffer16BitAccess == VK_TRUE);
    CHECK(storage16.pNext == &indexing && indexing.runtimeDescriptorArray == VK_TRUE);
    CHECK(indexing.descriptorBindingPartiallyBound == VK_TRUE && !indexing.pNext);
    CHECK(features2.features.shaderInt64 == VK_TRUE);
    *out = DEVICE; return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL fake_device_destroy(VkDevice d, const VkAllocationCallbacks *a) {
    CHECK(d == DEVICE && !a);
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_template(VkDevice d, const VkDescriptorUpdateTemplateCreateInfo *info,
    const VkAllocationCallbacks *a, VkDescriptorUpdateTemplate *out) {
    CHECK(d == DEVICE && !a && info && info->sType == VK_STRUCTURE_TYPE_DESCRIPTOR_UPDATE_TEMPLATE_CREATE_INFO);
    *out = (VkDescriptorUpdateTemplate)(uintptr_t)0x600; template_calls++; return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL fake_template_destroy(VkDevice d, VkDescriptorUpdateTemplate t, const VkAllocationCallbacks *a) {
    CHECK(d == DEVICE && !a && t == (VkDescriptorUpdateTemplate)(uintptr_t)0x600); template_calls++;
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_device_extensions(VkPhysicalDevice p,const char *layer,uint32_t *n,VkExtensionProperties *out){
    CHECK(p && !layer);(void)out;*n=0;return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL fake_format_properties(VkPhysicalDevice p,VkFormat f,VkFormatProperties *out){
    CHECK(p && f==VK_FORMAT_R8G8B8A8_UNORM);memset(out,0,sizeof *out);out->optimalTilingFeatures=VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT;
}
static VKAPI_ATTR VkResult VKAPI_CALL fake_surface_support(VkPhysicalDevice p,uint32_t f,VkSurfaceKHR s,VkBool32 *out){
    CHECK(p && f<2 && s==SURFACE);*out=VK_TRUE;return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL fake_families(VkPhysicalDevice p,uint32_t *n,VkQueueFamilyProperties *out){
    CHECK(p);if(out){CHECK(*n>=2);memset(out,0,2*sizeof *out);out[0].queueFlags=VK_QUEUE_GRAPHICS_BIT;out[1].queueFlags=VK_QUEUE_SPARSE_BINDING_BIT;}*n=2;
}
static PFN_vkVoidFunction symbol(const char *name) {
    if (!strcmp(name, "vkCreateDescriptorUpdateTemplateKHR") || !strcmp(name, "vkDestroyDescriptorUpdateTemplateKHR")) return NULL;
    if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)fake_create;
    if (!strcmp(name, "vkDestroyInstance")) return (PFN_vkVoidFunction)fake_destroy;
    if (!strcmp(name, "vkEnumerateInstanceExtensionProperties")) return (PFN_vkVoidFunction)fake_extensions;
    if (!strcmp(name, "vkCreateAndroidSurfaceKHR")) return (PFN_vkVoidFunction)fake_surface;
    if (!strcmp(name, "vkDestroySurfaceKHR")) return (PFN_vkVoidFunction)fake_surface_destroy;
    if (!strcmp(name, "vkWaitForFences")) return (PFN_vkVoidFunction)fake_wait;
    if (!strcmp(name, "vkCreateBuffer")) return (PFN_vkVoidFunction)fake_buffer;
    if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)fake_device;
    if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)fake_device_destroy;
    if (!strcmp(name, "vkEnumerateDeviceExtensionProperties")) return (PFN_vkVoidFunction)fake_device_extensions;
    if (!strcmp(name, "vkGetPhysicalDeviceFormatProperties")) return (PFN_vkVoidFunction)fake_format_properties;
    if (!strcmp(name, "vkGetPhysicalDeviceSurfaceSupportKHR")) return (PFN_vkVoidFunction)fake_surface_support;
    if (!strcmp(name, "vkGetPhysicalDeviceQueueFamilyProperties")) return (PFN_vkVoidFunction)fake_families;
    if (!strcmp(name, "vkNotAvailable")) return NULL;
    return dummy;
}
static PFN_vkVoidFunction VKAPI_CALL instance_proc(VkInstance i, const char *name) {
    if (!i && strcmp(name, "vkCreateInstance") && strcmp(name, "vkGetInstanceProcAddr") &&
        strcmp(name, "vkEnumerateInstanceExtensionProperties")) return NULL;
    return symbol(name);
}
static PFN_vkVoidFunction VKAPI_CALL device_proc(VkDevice d, const char *name) {
    if (!d) return NULL;
    if (!strcmp(name, "vkCreateDescriptorUpdateTemplateKHR")) return (PFN_vkVoidFunction)fake_template;
    if (!strcmp(name, "vkDestroyDescriptorUpdateTemplateKHR")) return (PFN_vkVoidFunction)fake_template_destroy;
    return symbol(name);
}

static void offer(void) {
    int32_t insets[4] = {0};
    CHECK(s2a_wsi_offer(lease, &window_object));
    s2a_wsi_update(lease, 1280, 720, 1, insets, 60);
    s2a_wsi_set_foreground(lease, 1);
}

int main(int argc, char **argv) {
    CHECK(!s2a_vk_entry("vkCreateInstance"));
    CHECK(!s2a_vk_lib_ready("/not-a-ready-package"));
    struct s2a_direct_vk_host h = {instance_proc, device_proc, symbol, wrap, report, fatal, block_begin, block_end, window, NULL};
    CHECK(s2a_android_vk_configure(NULL) == EINVAL);
    struct s2a_direct_vk_host bad = h; bad.wrap = NULL;
    CHECK(s2a_android_vk_configure(&bad) == EINVAL);
    CHECK(s2a_android_vk_configure(&h) == 0);
    CHECK(s2a_android_vk_configure(&h) == EALREADY);
    CHECK(!s2a_vk_entry(NULL) && !s2a_vk_entry("glDrawArrays") && !s2a_vk_entry("vkNotAvailable"));
    // A driver address alone does not grant an unreviewed callback-bearing API.
    CHECK(!s2a_vk_entry("vkCreateDebugUtilsMessengerEXT"));
    PFN_vkGetInstanceProcAddr gipa = GET(vkGetInstanceProcAddr);
    PFN_vkGetDeviceProcAddr gdpa = GET(vkGetDeviceProcAddr);
    unsigned old = wrapped;
    CHECK(!gipa(VK_NULL_HANDLE, "vkCmdDrawIndexed"));
    CHECK(!gipa(VK_NULL_HANDLE, "vkCreateViSurfaceNN"));
    CHECK(!gdpa(VK_NULL_HANDLE, "vkCmdDrawIndexed"));
    CHECK(gdpa(DEVICE, "vkCmdDrawIndexed"));
    CHECK(wrapped == old + 1);
    CHECK(!gdpa(DEVICE, "vkCreateViSurfaceNN"));
    uint32_t n = 0;
    CHECK(GET(vkEnumerateInstanceExtensionProperties)(NULL, &n, NULL) == VK_SUCCESS && n == 2);
    VkExtensionProperties properties[2]; n = 1;
    CHECK(GET(vkEnumerateInstanceExtensionProperties)(NULL, &n, properties) == VK_INCOMPLETE && n == 1);
    n = 2;
    CHECK(GET(vkEnumerateInstanceExtensionProperties)(NULL, &n, properties) == VK_SUCCESS);
    CHECK(!strcmp(properties[1].extensionName, VK_NN_VI_SURFACE_EXTENSION_NAME));
    CHECK(GET(vkEnumerateInstanceExtensionProperties)("layer", &n, NULL) == VK_SUCCESS && n == 0);
    const char *extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_NN_VI_SURFACE_EXTENSION_NAME, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME};
    VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .enabledExtensionCount = 3, .ppEnabledExtensionNames = extensions};
    VkInstance i = VK_NULL_HANDLE;
    VkAllocationCallbacks allocator = {0};
    CHECK(GET(vkCreateInstance)(NULL, NULL, &i) == VK_ERROR_INITIALIZATION_FAILED);
    const char *missing_dependency[] = {VK_NN_VI_SURFACE_EXTENSION_NAME};
    VkInstanceCreateInfo missing = ci;
    missing.enabledExtensionCount = 1; missing.ppEnabledExtensionNames = missing_dependency;
    CHECK(GET(vkCreateInstance)(&missing, NULL, &i) == VK_ERROR_EXTENSION_NOT_PRESENT && !i);
    CHECK(GET(vkCreateInstance)(&ci, &allocator, &i) == VK_ERROR_FEATURE_NOT_PRESENT && !i);
    ci.pNext = &allocator;
    CHECK(GET(vkCreateInstance)(&ci, NULL, &i) == VK_ERROR_FEATURE_NOT_PRESENT && !i);
    ci.pNext = NULL;
    instance_error = VK_ERROR_INCOMPATIBLE_DRIVER;
    CHECK(GET(vkCreateInstance)(&ci, NULL, &i) == VK_ERROR_INCOMPATIBLE_DRIVER && !i);
    instance_error = VK_SUCCESS;
    CHECK(GET(vkCreateInstance)(&ci, NULL, &i) == VK_SUCCESS && i == INSTANCE && created == 1);
    CHECK(ci.enabledExtensionCount == 3 && ci.ppEnabledExtensionNames == extensions);
    CHECK(!strcmp(extensions[1], VK_NN_VI_SURFACE_EXTENSION_NAME));
    CHECK(GET(vkCreateInstance)(&ci, NULL, &i) == VK_ERROR_TOO_MANY_OBJECTS && created == 1);
    CHECK(gipa(i, "vkCreateViSurfaceNN"));
    VkFormatProperties fp;
    memset(&fp,0xff,sizeof fp);
    GET(vkGetPhysicalDeviceFormatProperties)((VkPhysicalDevice)(uintptr_t)0x500,VK_FORMAT_PVRTC1_2BPP_UNORM_BLOCK_IMG,&fp);
    CHECK(!fp.linearTilingFeatures && !fp.optimalTilingFeatures && !fp.bufferFeatures);
    GET(vkGetPhysicalDeviceFormatProperties)((VkPhysicalDevice)(uintptr_t)0x500,VK_FORMAT_R8G8B8A8_UNORM,&fp);
    CHECK(fp.optimalTilingFeatures==VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT);
    VkBool32 supported;
    CHECK(GET(vkGetPhysicalDeviceSurfaceSupportKHR)((VkPhysicalDevice)(uintptr_t)0x500,0,SURFACE,&supported)==VK_SUCCESS && supported);
    CHECK(GET(vkGetPhysicalDeviceSurfaceSupportKHR)((VkPhysicalDevice)(uintptr_t)0x500,1,SURFACE,&supported)==VK_SUCCESS && !supported);
    const char *required_aliases[] = {"vkBindBufferMemory2KHR", "vkBindImageMemory2KHR",
        "vkGetBufferMemoryRequirements2KHR", "vkGetImageMemoryRequirements2KHR",
        "vkCreateDescriptorUpdateTemplateKHR", "vkDestroyDescriptorUpdateTemplateKHR",
        "vkUpdateDescriptorSetWithTemplateKHR"};
    for (unsigned j = 0; j < sizeof required_aliases / sizeof *required_aliases; j++)
        CHECK(gdpa(DEVICE, required_aliases[j]));
    VkDeviceCreateInfo di = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &allocator};
    VkDevice d = VK_NULL_HANDLE;
    CHECK(GET(vkCreateDevice)((VkPhysicalDevice)(uintptr_t)0x500, &di, NULL, &d) == VK_ERROR_FEATURE_NOT_PRESENT);
    storage16 = (VkPhysicalDevice16BitStorageFeatures){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES, .storageBuffer16BitAccess = VK_TRUE};
    features2 = (VkPhysicalDeviceFeatures2){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &storage16};
    features2.features.shaderInt64 = VK_TRUE;
    di.pNext = &features2;
    VkPhysicalDeviceFeatures old_features = {0}; di.pEnabledFeatures = &old_features;
    CHECK(GET(vkCreateDevice)((VkPhysicalDevice)(uintptr_t)0x500, &di, NULL, &d) == VK_ERROR_INITIALIZATION_FAILED);
    di.pEnabledFeatures = NULL; storage16.pNext = &features2;
    CHECK(GET(vkCreateDevice)((VkPhysicalDevice)(uintptr_t)0x500, &di, NULL, &d) == VK_ERROR_INITIALIZATION_FAILED);
    indexing = (VkPhysicalDeviceDescriptorIndexingFeatures){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
        .runtimeDescriptorArray = VK_TRUE, .descriptorBindingPartiallyBound = VK_TRUE};
    storage16.pNext = &indexing;
    CHECK(GET(vkCreateDevice)((VkPhysicalDevice)(uintptr_t)0x500, &di, NULL, &d) == VK_SUCCESS && d == DEVICE);
    CHECK(s2a_android_vk_stop() == EBUSY);
    VkDescriptorUpdateTemplateCreateInfo ti = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_UPDATE_TEMPLATE_CREATE_INFO};
    VkDescriptorUpdateTemplate t;
    CHECK(((PFN_vkCreateDescriptorUpdateTemplateKHR)gdpa(d, "vkCreateDescriptorUpdateTemplateKHR"))(d, &ti, NULL, &t) == VK_SUCCESS);
    ((PFN_vkDestroyDescriptorUpdateTemplateKHR)gdpa(d, "vkDestroyDescriptorUpdateTemplateKHR"))(d, t, NULL);
    CHECK(template_calls == 2);
    GET(vkDestroyDevice)(d, NULL);
    VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; VkBuffer b = VK_NULL_HANDLE;
    CHECK(GET(vkCreateBuffer)(DEVICE, &bi, &allocator, &b) == VK_ERROR_FEATURE_NOT_PRESENT && !b);
    CHECK(GET(vkCreateBuffer)(DEVICE, &bi, NULL, &b) == VK_SUCCESS && b);
    wait_result = VK_TIMEOUT;
    CHECK(GET(vkWaitForFences)(DEVICE, 0, NULL, VK_TRUE, 123) == VK_TIMEOUT && begin == end);
    wait_result = VK_ERROR_DEVICE_LOST;
    CHECK(GET(vkWaitForFences)(DEVICE, 0, NULL, VK_TRUE, 123) == VK_ERROR_DEVICE_LOST && begin == end);
    struct s2a_wsi_window_ops ops = {retain, release};
    lease = s2a_wsi_create(9, &ops); CHECK(lease);
    s2a_wsi_api_fill(lease, &api); offer();
    VkViSurfaceCreateInfoNN vi = {.sType = VK_STRUCTURE_TYPE_VI_SURFACE_CREATE_INFO_NN, .window = &guest_token};
    VkSurfaceKHR s = VK_NULL_HANDLE;
    vi.window = &window_object;
    CHECK(GET(vkCreateViSurfaceNN)(i, &vi, NULL, &s) == VK_ERROR_SURFACE_LOST_KHR);
    vi.window = &guest_token;
    uint32_t api_size = api.size;
    api.size = 0;
    CHECK(GET(vkCreateViSurfaceNN)(i, &vi, NULL, &s) == VK_ERROR_SURFACE_LOST_KHR);
    api.size = api_size;
    vi.flags = 1;
    CHECK(GET(vkCreateViSurfaceNN)(i, &vi, NULL, &s) == VK_ERROR_FEATURE_NOT_PRESENT);
    vi.flags = 0;
    create_error = VK_ERROR_OUT_OF_HOST_MEMORY;
    CHECK(GET(vkCreateViSurfaceNN)(i, &vi, NULL, &s) == VK_ERROR_OUT_OF_HOST_MEMORY && !s);
    CHECK(retained == released + 1); // Only the shell owns the offered window.
    CHECK(s2a_wsi_revoke(lease, 0) == 0); offer();
    s2a_wsi_set_foreground(lease, 0);
    CHECK(GET(vkCreateViSurfaceNN)(i, &vi, NULL, &s) == VK_ERROR_SURFACE_LOST_KHR);
    CHECK(s2a_wsi_revoke(lease, 0) == 0); offer();
    create_error = VK_SUCCESS;
    CHECK(GET(vkCreateViSurfaceNN)(i, &vi, NULL, &s) == VK_SUCCESS && s == SURFACE);
    VkSurfaceKHR extra = VK_NULL_HANDLE;
    CHECK(GET(vkCreateViSurfaceNN)(i, &vi, NULL, &extra) == VK_ERROR_TOO_MANY_OBJECTS && !extra);
    CHECK(s2a_wsi_revoke(lease, 0) == ETIMEDOUT);
    if (argc > 1 && !strcmp(argv[1], "fatal-live-instance")) { GET(vkDestroyInstance)(i, NULL); return 1; }
    if (argc > 1 && !strcmp(argv[1], "fatal-allocator")) { GET(vkDestroyBuffer)(DEVICE, b, &allocator); return 1; }
    GET(vkDestroySurfaceKHR)(i, s, NULL);
    CHECK(s2a_wsi_revoke(lease, 0) == 0);
    CHECK(retained == released);
    s2a_wsi_destroy(lease);
    GET(vkDestroyInstance)(i, NULL);
    CHECK(destroyed == 1 && !gipa(i, "vkCreateViSurfaceNN"));
    CHECK(errors >= 8 && begin == 2 && end == 2);
    printf("PASS %u checks: dispatch scope/wrapping, extension translation, callback refusal, wait/error, real lease rollback/revoke\n", checks);
    return 0;
}

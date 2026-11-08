// No game assets. Uses the production frontend with real Android loader dispatch.
// Runs on an existing host pthread; xstack switching and visible WSI are separate.
#include "direct_vk.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *library;
static unsigned wrapped, begin, end;
static PFN_vkVoidFunction symbol(const char *name) { return (PFN_vkVoidFunction)dlsym(library, name); }
static void *wrap(const char *name, void *fn) { (void)name; wrapped++; return fn; }
static void report(const char *name, VkResult result) { fprintf(stderr, "%s: %d\n", name, result); }
static void fatal(const char *name) { fprintf(stderr, "fatal: %s\n", name); exit(2); }
static void block_begin(void) { begin++; }
static void block_end(void) { end++; }
static const struct s2a_wsi_api *window(void *token) { (void)token; return NULL; }
#define FN(name) ((PFN_##name)s2a_vk_entry(#name))
#define VK_OK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "FAIL line %d: %d\n", __LINE__, r_); return 1; } } while (0)
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(int argc, char **argv) {
    library = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    CHECK(library);
    struct s2a_direct_vk_host h = {(PFN_vkGetInstanceProcAddr)symbol("vkGetInstanceProcAddr"),
        (PFN_vkGetDeviceProcAddr)symbol("vkGetDeviceProcAddr"), symbol, wrap, report, fatal, block_begin, block_end, window, NULL};
    CHECK(s2a_android_vk_configure(&h) == 0);
    int terminal=argc>1&&!strcmp(argv[1],"--terminal");
    if (argc > 1 && !terminal) {
        FILE *file = fopen(argv[1], "r"); CHECK(file);
        char name[256]; unsigned total = 0, available = 0;
        while (fgets(name, sizeof name, file)) {
            name[strcspn(name, "\r\n")] = 0;
            if (!*name) continue;
            total++;
            if (s2a_vk_entry(name)) available++;
            else printf("unavailable: %s\n", name);
        }
        fclose(file);
        printf("static entry availability: %u/%u (address availability only)\n", available, total);
        CHECK(total && total == available);
    }
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "S2Arm direct Vulkan probe", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance instance = VK_NULL_HANDLE;
    VK_OK(FN(vkCreateInstance)(&ci, NULL, &instance));
    PFN_vkGetInstanceProcAddr gipa = FN(vkGetInstanceProcAddr);
    CHECK(!gipa(instance, "vkCreateViSurfaceNN")); // Extension wasn't enabled.
    uint32_t n = 0;
    VK_OK(FN(vkEnumeratePhysicalDevices)(instance, &n, NULL)); CHECK(n);
    VkPhysicalDevice *physical = calloc(n, sizeof *physical); CHECK(physical);
    VK_OK(FN(vkEnumeratePhysicalDevices)(instance, &n, physical));
    VkPhysicalDeviceProperties properties;
    FN(vkGetPhysicalDeviceProperties)(physical[0], &properties);
    printf("driver: %s api=%u.%u.%u driverVersion=%u\n", properties.deviceName,
        VK_VERSION_MAJOR(properties.apiVersion), VK_VERSION_MINOR(properties.apiVersion),
        VK_VERSION_PATCH(properties.apiVersion), properties.driverVersion);
    uint32_t count = 0;
    FN(vkGetPhysicalDeviceQueueFamilyProperties)(physical[0], &count, NULL); CHECK(count);
    VkQueueFamilyProperties *families = calloc(count, sizeof *families); CHECK(families);
    FN(vkGetPhysicalDeviceQueueFamilyProperties)(physical[0], &count, families);
    uint32_t family = 0;
    while (family < count && !(families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) family++;
    CHECK(family < count);
    float priority = 1;
    VkDeviceQueueCreateInfo qi = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority};
    VkDeviceCreateInfo di = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi};
    VkDevice device = VK_NULL_HANDLE;
    VK_OK(FN(vkCreateDevice)(physical[0], &di, NULL, &device));
    PFN_vkGetDeviceProcAddr gdpa = FN(vkGetDeviceProcAddr);
    CHECK(gdpa(device, "vkCmdCopyBuffer") && !gdpa(device, "vkCreateViSurfaceNN"));
    VkPhysicalDeviceMemoryProperties memory_properties;
    FN(vkGetPhysicalDeviceMemoryProperties)(physical[0], &memory_properties);
    VkBuffer buffers[2]; VkDeviceMemory memory[2]; void *mapped[2];
    for (unsigned i = 0; i < 2; i++) {
        VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 4096,
            .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
        VK_OK(FN(vkCreateBuffer)(device, &bi, NULL, &buffers[i]));
        VkMemoryRequirements requirements;
        FN(vkGetBufferMemoryRequirements)(device, buffers[i], &requirements);
        uint32_t type = 0;
        VkMemoryPropertyFlags need = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        while (type < memory_properties.memoryTypeCount && (!(requirements.memoryTypeBits & (1u << type)) ||
            (memory_properties.memoryTypes[type].propertyFlags & need) != need)) type++;
        CHECK(type < memory_properties.memoryTypeCount);
        VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size, .memoryTypeIndex = type};
        VK_OK(FN(vkAllocateMemory)(device, &ai, NULL, &memory[i]));
        VK_OK(FN(vkBindBufferMemory)(device, buffers[i], memory[i], 0));
        VK_OK(FN(vkMapMemory)(device, memory[i], 0, 4096, 0, &mapped[i]));
        memset(mapped[i], 0, 4096);
    }
    for (unsigned i = 0; i < 1024; i++) ((uint32_t *)mapped[0])[i] = 0x37ab0000u ^ (i * 97);
    VkCommandPoolCreateInfo pi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family};
    VkCommandPool pool;
    VK_OK(FN(vkCreateCommandPool)(device, &pi, NULL, &pool));
    VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VkCommandBuffer command;
    VK_OK(FN(vkAllocateCommandBuffers)(device, &cai, &command));
    VkCommandBufferBeginInfo cbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    VK_OK(FN(vkBeginCommandBuffer)(command, &cbi));
    VkBufferCopy copy = {.size = 4096};
    FN(vkCmdCopyBuffer)(command, buffers[0], buffers[1], 1, &copy);
    VkBufferMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffers[1], .size = 4096};
    FN(vkCmdPipelineBarrier)(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0,
        0, NULL, 1, &barrier, 0, NULL);
    VK_OK(FN(vkEndCommandBuffer)(command));
    VkQueue queue;
    FN(vkGetDeviceQueue)(device, family, 0, &queue);
    VkFenceCreateInfo fi = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence fence;
    VK_OK(FN(vkCreateFence)(device, &fi, NULL, &fence));
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command};
    VK_OK(FN(vkQueueSubmit)(queue, 1, &submit, fence));
    VK_OK(FN(vkWaitForFences)(device, 1, &fence, VK_TRUE, 5000000000ull));
    CHECK(!memcmp(mapped[0], mapped[1], 4096));
    if(terminal){
        CHECK(s2a_android_vk_stop()!=0);
        CHECK(s2a_android_vk_terminal_drain()==0);
        CHECK(s2a_android_vk_stop()==0);
        free(families);free(physical);
        puts("PASS actual driver terminal drain: live command pool/fence/buffers/memory/device/instance released");
        return 0;
    }
    FN(vkDestroyFence)(device, fence, NULL);
    FN(vkDestroyCommandPool)(device, pool, NULL);
    for (unsigned i = 0; i < 2; i++) {
        FN(vkUnmapMemory)(device, memory[i]);
        FN(vkDestroyBuffer)(device, buffers[i], NULL);
        FN(vkFreeMemory)(device, memory[i], NULL);
    }
    FN(vkDestroyDevice)(device, NULL);
    FN(vkDestroyInstance)(instance, NULL);
    CHECK(begin == end && begin == 2);
    free(families); free(physical);
    // Do not dlclose the loader: exported function pointers are process-lifetime.
    printf("PASS actual driver: 4096 bytes submitted/read back; wraps=%u block-pairs=%u\n", wrapped, begin);
    return 0;
}

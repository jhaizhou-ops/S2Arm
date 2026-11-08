// Real Vulkan entry points and GPU readback, linked with the production host.
// Deliberately leave resources live: session retirement owns their destruction.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../../graphics_session.h"

void *dm_vk_lookup(const char *);

#define APIS(X) \
    X(vkCreateInstance) X(vkEnumeratePhysicalDevices) X(vkCreateDevice) X(vkGetDeviceQueue) \
    X(vkCreateBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkBindBufferMemory) X(vkMapMemory) \
    X(vkCreateImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) \
    X(vkCreateCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
    X(vkCmdClearColorImage) X(vkCmdCopyImageToBuffer) X(vkQueueSubmit) X(vkQueueWaitIdle)
#define DECL(name) static PFN_##name name;
APIS(DECL)
#undef DECL
#define OK(call) assert((call) == VK_SUCCESS)

int s2a_test_vk_session_resources(unsigned rounds) {
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dm_vk_lookup("vkGetInstanceProcAddr");
    assert(get);
#define LOAD(name) name = (PFN_##name)get(VK_NULL_HANDLE, #name); assert(name);
    APIS(LOAD)
#undef LOAD
    for (unsigned round = 1; round <= rounds; round++) {
        assert(s2a_graphics_native_begin_session() == 0);
        VkInstance instance;
        VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        OK(vkCreateInstance(&ici, NULL, &instance));
        uint32_t count = 1; VkPhysicalDevice physical;
        OK(vkEnumeratePhysicalDevices(instance, &count, &physical)); assert(count == 1);
        float priority = 1;
        VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority};
        VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
        VkDevice device; OK(vkCreateDevice(physical, &dci, NULL, &device));
        VkQueue queue; vkGetDeviceQueue(device, 0, 0, &queue); assert(queue);
        VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 32 * 32 * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
        VkBuffer buffer; OK(vkCreateBuffer(device, &bci, NULL, &buffer));
        VkMemoryRequirements req; vkGetBufferMemoryRequirements(device, buffer, &req);
        VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = 1};
        VkDeviceMemory bmem; OK(vkAllocateMemory(device, &mai, NULL, &bmem)); OK(vkBindBufferMemory(device, buffer, bmem, 0));
        uint8_t *pixels; OK(vkMapMemory(device, bmem, 0, 32 * 32 * 4, 0, (void **)&pixels));
        memset(pixels, 0xcd, 32 * 32 * 4);
        VkImageCreateInfo imci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {32, 32, 1}, .mipLevels = 1, .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT};
        VkImage image; OK(vkCreateImage(device, &imci, NULL, &image));
        vkGetImageMemoryRequirements(device, image, &req); mai.allocationSize = req.size; mai.memoryTypeIndex = 0;
        VkDeviceMemory imem; OK(vkAllocateMemory(device, &mai, NULL, &imem)); OK(vkBindImageMemory(device, image, imem, 0));
        VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0};
        VkCommandPool pool; OK(vkCreateCommandPool(device, &pci, NULL, &pool));
        VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
        VkCommandBuffer commands; OK(vkAllocateCommandBuffers(device, &cai, &commands));
        VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        OK(vkBeginCommandBuffer(commands, &begin));
        int red = round & 1;
        VkClearColorValue clear = {.float32 = {red, 0, 1, 1}};
        VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(commands, image, VK_IMAGE_LAYOUT_GENERAL, &clear, 1, &range);
        VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {32, 32, 1}};
        vkCmdCopyImageToBuffer(commands, image, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &copy);
        OK(vkEndCommandBuffer(commands));
        VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &commands};
        OK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
        for (unsigned i = 0; i < 32 * 32 * 4; i += 4)
            assert(pixels[i] == red * 255 && !pixels[i + 1] && pixels[i + 2] == 255 && pixels[i + 3] == 255);
        assert(s2a_graphics_native_request_stop() == 0);
        assert(s2a_graphics_native_shutdown_session() == 0);
        fprintf(stderr, "[graphics-session] Vulkan %u/%u GPU clear/readback/retirement passed\n", round, rounds);
    }
    return 0;
}

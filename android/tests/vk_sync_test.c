// C4：真机 fence 完成等待；超时 fence 不得被当成已完成。
#include "../native/direct/vk_sync.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures;
static VkBuffer make_buffer(struct s2a_vk_device *d, VkDeviceMemory *memory, void **mapped) {
    VkBufferCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    info.size = 64; info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer buffer = VK_NULL_HANDLE;
    vkCreateBuffer(d->device, &info, NULL, &buffer);
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(d->device, buffer, &req);
    VkMemoryAllocateInfo alloc = {0};
    alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = s2a_vk_memory_type(d, req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
    vkAllocateMemory(d->device, &alloc, NULL, memory);
    vkBindBufferMemory(d->device, buffer, *memory, 0);
    vkMapMemory(d->device, *memory, 0, VK_WHOLE_SIZE, 0, mapped);
    return buffer;
}
static VkCommandBuffer fill_cmd(struct s2a_vk_device *d, VkBuffer buffer, uint32_t value) {
    VkCommandBufferAllocateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    info.commandPool = d->command_pool; info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; info.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    vkAllocateCommandBuffers(d->device, &info, &cmd);
    VkCommandBufferBeginInfo begin = {0};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &begin);
    vkCmdFillBuffer(cmd, buffer, 0, 64, value);
    vkEndCommandBuffer(cmd);
    return cmd;
}
int main(void) {
    struct s2a_vk_device device;
    char why[192] = "";
    if (s2a_vk_device_create(&device, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    VkDeviceMemory memory = VK_NULL_HANDLE; void *mapped = NULL;
    VkBuffer buffer = make_buffer(&device, &memory, &mapped);
    struct s2a_vk_completion completion = {0};
    VkCommandBuffer first = fill_cmd(&device, buffer, 0x11223344u);
    if (s2a_vk_completion_submit(&device, first, &completion, 1)) { printf("FAIL submit 1\n"); return 1; }
    if (s2a_vk_completion_wait(&device, &completion, UINT64_MAX)) { printf("FAIL wait 1\n"); return 1; }
    uint32_t value = 0; memcpy(&value, mapped, 4);
    if (value != 0x11223344u) { failures++; printf("FAIL first value %08x\n", value); }
    VkCommandBuffer second = fill_cmd(&device, buffer, 0x55667788u);
    if (s2a_vk_completion_submit(&device, second, &completion, 2)) { printf("FAIL submit 2\n"); return 1; }
    if (s2a_vk_completion_wait(&device, &completion, UINT64_MAX)) { printf("FAIL wait 2\n"); return 1; }
    memcpy(&value, mapped, 4);
    if (value != 0x55667788u) { failures++; printf("FAIL second value %08x\n", value); }
    VkFenceCreateInfo fi = {0};
    fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    struct s2a_vk_completion never = {0};
    vkCreateFence(device.device, &fi, NULL, &never.fence);
    never.pending = 1; never.batch = 3;
    int early = s2a_vk_completion_wait(&device, &never, 1000000ull);
    if (early != 1) { failures++; printf("FAIL unsignalled fence wait returned %d (not timeout)\n", early); }
    s2a_vk_completion_destroy(&device, &never);
    printf("INFO fence: batches 1,2 completed in order; unsignalled fence timed out\n");
    vkUnmapMemory(device.device, memory);
    vkDestroyBuffer(device.device, buffer, NULL);
    vkFreeMemory(device.device, memory, NULL);
    s2a_vk_device_destroy(&device, 0);
    if (failures) { printf("vk-sync: %d FAILURES\n", failures); return 1; }
    printf("vk-sync: ok\n");
    return 0;
}

// C4：单消费者 batch 退休顺序 + present fence 入队。
#include "../native/direct/vk_track.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures;
static uint64_t retired_order[16];
static int retired_count;

static void retire(void *user, uint64_t batch) {
    (void)user;
    if (retired_count < 16) retired_order[retired_count++] = batch;
}

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
    struct s2a_vk_track *track = NULL;
    if (s2a_vk_track_create(&device, &track)) { printf("FAIL track create\n"); return 1; }
    VkDeviceMemory memory = VK_NULL_HANDLE; void *mapped = NULL;
    VkBuffer buffer = make_buffer(&device, &memory, &mapped);
    for (uint32_t i = 1; i <= 3; i++) {
        VkCommandBuffer cmd = fill_cmd(&device, buffer, 0x10000000u + i);
        if (s2a_vk_track_submit(track, cmd, i, retire, NULL)) { failures++; printf("FAIL submit %u\n", i); }
    }
    int rc = s2a_vk_track_wait_all(track, 5000);
    if (rc) { failures++; printf("FAIL wait_all %d\n", rc); }
    if (retired_count != 3 || retired_order[0] != 1 || retired_order[1] != 2 || retired_order[2] != 3) {
        failures++; printf("FAIL retire order count=%d\n", retired_count);
    }
    uint32_t value = 0; memcpy(&value, mapped, 4);
    if (value != 0x10000003u) { failures++; printf("FAIL last fill %08x\n", value); }

    // present fence 路径：单独提交并只把 fence 入队，不重复提交命令。
    VkCommandBuffer cmd = fill_cmd(&device, buffer, 0x20000000u);
    VkFenceCreateInfo fi = {0};
    fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    VkFence fence = VK_NULL_HANDLE;
    vkCreateFence(device.device, &fi, NULL, &fence);
    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
    vkQueueSubmit(device.queue, 1, &si, fence);
    if (s2a_vk_track_present_fence(track, fence, 4, retire, NULL)) { failures++; printf("FAIL present fence enqueue\n"); }
    if (s2a_vk_track_wait_all(track, 5000)) { failures++; printf("FAIL present wait\n"); }
    memcpy(&value, mapped, 4);
    if (value != 0x20000000u || retired_count != 4 || retired_order[3] != 4) {
        failures++; printf("FAIL present fence result %08x count=%d\n", value, retired_count);
    }
    uint64_t submitted = 0, retired = 0, pending = 0, failed = 0;
    s2a_vk_track_stats(track, &submitted, &retired, &pending, &failed);
    if (submitted != 4 || retired != 4 || pending != 0 || failed != 0) {
        failures++; printf("FAIL stats %llu/%llu/%llu/%llu\n",
            (unsigned long long)submitted, (unsigned long long)retired,
            (unsigned long long)pending, (unsigned long long)failed);
    }
    printf("INFO track: submitted=%llu retired=%llu pending=%llu failed=%llu order=1,2,3,4\n",
        (unsigned long long)submitted, (unsigned long long)retired,
        (unsigned long long)pending, (unsigned long long)failed);
    if (s2a_vk_track_destroy(track)) { failures++; printf("FAIL track destroy\n"); }

    // 在途时 destroy 必须拒绝；fence 完成后才能销毁。
    struct s2a_vk_track *pending_track = NULL;
    if (s2a_vk_track_create(&device, &pending_track)) { failures++; printf("FAIL pending_track track create\n"); }
    else {
        VkCommandBuffer slow = fill_cmd(&device, buffer, 0x30000000u);
        VkFenceCreateInfo pfi = {0};
        pfi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        VkFence pfence = VK_NULL_HANDLE;
        vkCreateFence(device.device, &pfi, NULL, &pfence);
        VkSubmitInfo psi = {0};
        psi.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        psi.commandBufferCount = 1; psi.pCommandBuffers = &slow;
        vkQueueSubmit(device.queue, 1, &psi, pfence);
        if (s2a_vk_track_present_fence(pending_track, pfence, 9, retire, NULL)) { failures++; printf("FAIL pending_track enqueue\n"); }
        if (s2a_vk_track_destroy(pending_track) == 0) { failures++; printf("FAIL destroy accepted pending_track work\n"); }
        if (s2a_vk_track_wait_all(pending_track, 5000)) { failures++; printf("FAIL pending_track wait\n"); }
        if (s2a_vk_track_destroy(pending_track)) { failures++; printf("FAIL pending_track destroy after completion\n"); }
        printf("INFO track-pending: destroy refused while in flight, accepted after completion\n");
    }
    vkUnmapMemory(device.device, memory);
    vkDestroyBuffer(device.device, buffer, NULL);
    vkFreeMemory(device.device, memory, NULL);
    s2a_vk_device_destroy(&device, 0);
    if (failures) { printf("vk-track: %d FAILURES\n", failures); return 1; }
    printf("vk-track: ok\n");
    return 0;
}

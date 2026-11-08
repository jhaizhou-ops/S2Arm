#include "vk_sync.h"

#include <string.h>

int s2a_vk_completion_submit(struct s2a_vk_device *device, VkCommandBuffer command,
                             struct s2a_vk_completion *completion, uint64_t batch) {
    if (!device || !device->device || !command || !completion || completion->pending) return -1;
    VkFenceCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (vkCreateFence(device->device, &info, NULL, &completion->fence) != VK_SUCCESS) return -1;
    VkSubmitInfo submit = {0};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command;
    if (vkQueueSubmit(device->queue, 1, &submit, completion->fence) != VK_SUCCESS) {
        vkDestroyFence(device->device, completion->fence, NULL);
        memset(completion, 0, sizeof *completion);
        return -1;
    }
    completion->batch = batch;
    completion->pending = 1;
    return 0;
}

int s2a_vk_completion_wait(struct s2a_vk_device *device, struct s2a_vk_completion *completion,
                           uint64_t timeout_ns) {
    if (!device || !completion || !completion->pending || !completion->fence) return -1;
    VkResult rc = vkWaitForFences(device->device, 1, &completion->fence, VK_TRUE, timeout_ns);
    if (rc == VK_TIMEOUT) return 1;
    if (rc != VK_SUCCESS) return -1;
    vkDestroyFence(device->device, completion->fence, NULL);
    completion->fence = VK_NULL_HANDLE;
    completion->pending = 0;
    return 0;
}

void s2a_vk_completion_destroy(struct s2a_vk_device *device, struct s2a_vk_completion *completion) {
    if (!device || !completion) return;
    if (completion->fence) vkDestroyFence(device->device, completion->fence, NULL);
    memset(completion, 0, sizeof *completion);
}

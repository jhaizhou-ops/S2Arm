// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Original attachment fixtures exercise production first_draw before Vulkan allocation.
// The device identity and parser-only program must never reach a driver.
#include "nvn/mtl_vk_adapter.h"
#include "nvn/nvn_vk_first_draw.h"
#include "nvn_obj.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int nvk_draw_builder(struct s2a_vk_device *d, const struct s2a_record_draw_state *s,
                     struct s2a_record_result *r, void *o) {
    (void)d; (void)s; (void)o;
    return r->code = S2A_RECORD_UNSUPPORTED;
}

static int uncreated_resource;
static void unexpected(const char *operation, uintptr_t resource) {
    // All tested rejections precede buffer/memory creation. The owned set is empty.
    // Record identity, not a particular number of calls from indeterminate values.
    fprintf(stderr, "uncreated resource: %s handle=%#lx\n", operation, (unsigned long)resource);
    uncreated_resource = 1;
}
void vkUnmapMemory(VkDevice d, VkDeviceMemory m) {
    (void)d; unexpected("unmap", (uintptr_t)m);
}
void vkDestroyBuffer(VkDevice d, VkBuffer b, const VkAllocationCallbacks *a) {
    (void)d; (void)a; unexpected("destroy-buffer", (uintptr_t)b);
}
void vkFreeMemory(VkDevice d, VkDeviceMemory m, const VkAllocationCallbacks *a) {
    (void)d; (void)a; unexpected("free-memory", (uintptr_t)m);
}

// #1350：首个 TIMESTAMP_TOP 先于第一笔 draw 到达时，帧队列必须按需绑定设备后照常记录。
// 这里只放时间戳录制直接触达的 Vulkan 入口；其余入口仍由 trap 生成器兜住。
static int ts_cmd_writes;
VkResult vkResetCommandBuffer(VkCommandBuffer cb, VkCommandBufferResetFlags f) {
    (void)cb; (void)f;
    return VK_SUCCESS;
}
VkResult vkAllocateCommandBuffers(VkDevice d, const VkCommandBufferAllocateInfo *ai,
                                  VkCommandBuffer *out) {
    (void)d; (void)ai;
    *out = (VkCommandBuffer)(uintptr_t)0x1000;
    return VK_SUCCESS;
}
VkResult vkBeginCommandBuffer(VkCommandBuffer cb, const VkCommandBufferBeginInfo *bi) {
    (void)cb; (void)bi;
    return VK_SUCCESS;
}
VkResult vkEndCommandBuffer(VkCommandBuffer cb) {
    (void)cb;
    return VK_SUCCESS;
}
void vkCmdResetQueryPool(VkCommandBuffer cb, VkQueryPool pool, uint32_t first, uint32_t n) {
    (void)cb; (void)pool; (void)first; (void)n;
}
void vkCmdWriteTimestamp(VkCommandBuffer cb, VkPipelineStageFlagBits stage, VkQueryPool pool,
                         uint32_t query) {
    (void)cb; (void)stage; (void)pool; (void)query;
    ts_cmd_writes++;
}

// Make skipped initialization observable without depending on whatever a previous
// application call happened to leave in reusable stack storage.
__attribute__((noinline)) static void poison_stack(void) {
    volatile unsigned char bytes[65536];
    for (size_t i = 0; i < sizeof bytes; i++) bytes[i] = 0xa5;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f || fseek(f, 0, SEEK_END)) return 2;
    long n = ftell(f);
    if (n <= 0 || fseek(f, 0, SEEK_SET)) return 2;
    unsigned char *p = malloc((size_t)n);
    if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) return 2;
    fclose(f);
    // Observer negative control: a fabricated resource must be rejected.
    vkFreeMemory((VkDevice)(uintptr_t)1, (VkDeviceMemory)(uintptr_t)2, NULL);
    if (!uncreated_resource) return 2;
    char why[512] = {0};
    struct s2a_vk_device device = {0};
    device.device = (VkDevice)(uintptr_t)1;
    const char *expected[] = {"neither a colour nor a depth", "depth target is not a live",
                             "colour target slot 0 is not a live", "zero vertices"};
    int bad = 0;
    // #1350：帧队列未就绪（还没有 draw）时 timestamp-top 不得失败。首次记录必须真的写下一个
    // 时间戳命令（计数 +1），队列绑定后第二次记录也要正常。
    {
        struct s2a_vk_device tsdev = {0};
        tsdev.device = (VkDevice)(uintptr_t)1;
        tsdev.command_pool = (VkCommandPool)(uintptr_t)2;
        char twhy[512] = {0};
        ts_cmd_writes = 0;
        int rc = nvn_vk_first_draw_timestamp_top(&tsdev, (VkQueryPool)(uintptr_t)3, 0,
                                                 twhy, sizeof twhy);
        int first_ok = rc == 0 && ts_cmd_writes == 1;
        int second_ok = 0;
        if (first_ok) {
            rc = nvn_vk_first_draw_timestamp_top(&tsdev, (VkQueryPool)(uintptr_t)3, 1,
                                                 twhy, sizeof twhy);
            second_ok = rc == 0 && ts_cmd_writes == 2;
        }
        printf("timestamp-top before first draw: rc=%d writes=%d second=%d why=%s %s\n",
               rc, ts_cmd_writes, second_ok, twhy[0] ? twhy : "-",
               first_ok && second_ok ? "PASS" : "FAIL");
        bad += !(first_ok && second_ok);
    }
    for (int c = 0; c < 4; c++) {
        tex_t invalid = {0};
        struct s2a_record_draw_state s = {0};
        s.stages = 3; s.rt_count = 1; s.count = c == 3 ? 0 : 3; s.instances = 1;
        if (c == 1) { s.has_depth = 1; s.depth_key = (uintptr_t)&invalid; }
        if (c == 2) s.rt[0].key = (uintptr_t)&invalid;
        uncreated_resource = 0;
        poison_stack();
        int rc = nvn_vk_first_draw(&device, &s, p, (size_t)n, NULL, NULL, 1, 1,
                                  "original-rejection", why, sizeof why);
        int reason = strstr(why, expected[c]) != NULL;
        int ok = rc != 0 && reason && !uncreated_resource;
        printf("case%d rejected=%d expected_reason=%d uncreated_resource=%d %s\n",
               c, rc != 0, reason, uncreated_resource, ok ? "PASS" : "FAIL");
        bad += !ok;
    }
    free(p);
    return bad ? 1 : 0;
}

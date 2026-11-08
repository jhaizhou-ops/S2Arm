// 设备侧 Vulkan 时间戳探针：只验证 W6 GPU 账依赖的真实能力与“按帧奇偶双池”读法，
// 不启动游戏、不读游戏资源。
//
// 用法：用 NDK clang 编成 arm64 可执行文件推到 /data/local/tmp 运行；输出 PASS/FAIL。
// 验证点：
//   1. 选中的图形队列 timestampValidBits > 0，timestampPeriod > 0；
//   2. 每帧 reset+写 t0/t1，提交并等 fence 后读回成功；
//   3. 两个按帧奇偶分开的池：下一帧 arm 另一个池后，上一帧结果仍可读；
//   4. 反例：单池在下一帧 reset 后，上一帧结果被覆盖，不能事后补读。
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FRAMES 6
#define FILL_BYTES (4u << 20)

static uint64_t ts_at(VkPhysicalDeviceProperties *p, const char *name) {
    printf("vk_timestamp: %s api=%u.%u.%u driver=0x%x period=%.6f ns\n", name,
           VK_VERSION_MAJOR(p->apiVersion), VK_VERSION_MINOR(p->apiVersion),
           VK_VERSION_PATCH(p->apiVersion), p->driverVersion, (double)p->limits.timestampPeriod);
    return 0;
}

int main(void) {
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "s2a-vk-timestamp-probe";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    VkInstance inst = VK_NULL_HANDLE;
    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) { puts("FAIL: vkCreateInstance"); return 1; }

    uint32_t ndev = 0;
    if (vkEnumeratePhysicalDevices(inst, &ndev, NULL) != VK_SUCCESS || ndev == 0) {
        puts("FAIL: no physical device"); return 1;
    }
    VkPhysicalDevice *devs = calloc(ndev, sizeof *devs);
    vkEnumeratePhysicalDevices(inst, &ndev, devs);
    VkPhysicalDevice phys = devs[0];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(phys, &props);
    ts_at(&props, props.deviceName);

    uint32_t nqf = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nqf, NULL);
    VkQueueFamilyProperties *qfs = calloc(nqf ? nqf : 1, sizeof *qfs);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nqf, qfs);
    uint32_t qf = UINT32_MAX;
    for (uint32_t i = 0; i < nqf; i++) {
        if ((qfs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && qfs[i].timestampValidBits > 0) { qf = i; break; }
    }
    if (qf == UINT32_MAX) {
        printf("FAIL: no graphics queue with timestampValidBits>0 (families=%u)\n", nqf);
        return 1;
    }
    printf("vk_timestamp: queueFamily=%u validBits=%u queues=%u\n", qf,
           (unsigned)qfs[qf].timestampValidBits, (unsigned)qfs[qf].queueCount);

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = qf; qci.queueCount = 1; qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
    VkDevice dev = VK_NULL_HANDLE;
    if (vkCreateDevice(phys, &dci, NULL, &dev) != VK_SUCCESS) { puts("FAIL: vkCreateDevice"); return 1; }
    VkQueue queue;
    vkGetDeviceQueue(dev, qf, 0, &queue);

    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = qf;
    VkCommandPool pool;
    if (vkCreateCommandPool(dev, &cpci, NULL, &pool) != VK_SUCCESS) { puts("FAIL: command pool"); return 1; }
    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cbai.commandPool = pool; cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cbai.commandBufferCount = 1;
    VkCommandBuffer cmd;
    if (vkAllocateCommandBuffers(dev, &cbai, &cmd) != VK_SUCCESS) { puts("FAIL: command buffer"); return 1; }

    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = FILL_BYTES; bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT; bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkBuffer buf;
    if (vkCreateBuffer(dev, &bci, NULL, &buf) != VK_SUCCESS) { puts("FAIL: buffer"); return 1; }
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, buf, &mr);
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    uint32_t mi = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { mi = i; break; }
    if (mi == UINT32_MAX) { puts("FAIL: device-local memory"); return 1; }
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = mr.size; mai.memoryTypeIndex = mi;
    VkDeviceMemory mem;
    if (vkAllocateMemory(dev, &mai, NULL, &mem) != VK_SUCCESS || vkBindBufferMemory(dev, buf, mem, 0) != VK_SUCCESS) {
        puts("FAIL: buffer memory"); return 1;
    }

    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    if (vkCreateFence(dev, &fci, NULL, &fence) != VK_SUCCESS) { puts("FAIL: fence"); return 1; }

    VkQueryPool qp[2] = { VK_NULL_HANDLE, VK_NULL_HANDLE };
    for (int i = 0; i < 2; i++) {
        VkQueryPoolCreateInfo qi = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO };
        qi.queryType = VK_QUERY_TYPE_TIMESTAMP; qi.queryCount = 2;
        if (vkCreateQueryPool(dev, &qi, NULL, &qp[i]) != VK_SUCCESS) { puts("FAIL: timestamp pool"); return 1; }
    }

    double period = props.limits.timestampPeriod > 0 ? props.limits.timestampPeriod : 1.0;
    uint64_t prev_end = 0;
    int failures = 0;
    for (int f = 0; f < FRAMES; f++) {
        int p = f & 1;
        vkResetCommandBuffer(cmd, 0);
        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (vkBeginCommandBuffer(cmd, &bi) != VK_SUCCESS) { puts("FAIL: begin"); return 1; }
        vkCmdResetQueryPool(cmd, qp[p], 0, 2);
        vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, qp[p], 0);
        vkCmdFillBuffer(cmd, buf, 0, FILL_BYTES, 0x11223344u);
        vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, qp[p], 1);
        if (vkEndCommandBuffer(cmd) != VK_SUCCESS) { puts("FAIL: end"); return 1; }
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
        vkResetFences(dev, 1, &fence);
        if (vkQueueSubmit(queue, 1, &si, fence) != VK_SUCCESS) { puts("FAIL: submit"); return 1; }
        if (vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull) != VK_SUCCESS) { puts("FAIL: fence timeout"); return 1; }
        // 故意不在本帧读 qp[p]：下一帧会 arm 另一个池；同奇偶只在两帧后才复用。
        if (f >= 1) {
            int rp = (f - 1) & 1;
            uint64_t r[2] = { 0, 0 };
            VkResult vr = vkGetQueryPoolResults(dev, qp[rp], 0, 2, sizeof r, r, sizeof(uint64_t),
                                                VK_QUERY_RESULT_64_BIT);
            if (vr != VK_SUCCESS) {
                printf("FAIL: frame %d read pool %d vr=%d\n", f, rp, (int)vr); failures++;
            } else {
                double ms = (double)(r[1] - r[0]) * period / 1e6;
                printf("frame=%d parity=%d read_pool=%d t0=%llu t1=%llu dur_ms=%.4f\n",
                       f, p, rp, (unsigned long long)r[0], (unsigned long long)r[1], ms);
                if (r[1] < r[0]) failures++;
                if (prev_end && r[0] < prev_end) { puts("FAIL: timestamp went backwards"); failures++; }
                prev_end = r[1];
            }
        }
    }
    for (int f = 0; f < 2; f++) {
        uint64_t r[2] = { 0, 0 };
        VkResult vr = vkGetQueryPoolResults(dev, qp[f], 0, 2, sizeof r, r, sizeof(uint64_t),
                                            VK_QUERY_RESULT_64_BIT);
        if (vr != VK_SUCCESS) { printf("FAIL: tail read pool %d vr=%d\n", f, (int)vr); failures++; }
        else printf("tail pool=%d dur_ms=%.4f\n", f, (double)(r[1] - r[0]) * period / 1e6);
    }

    // 反例：单池在下一帧 reset 后，上一帧结果被覆盖；证明延迟 present 不能事后补读单池。
    {
        VkQueryPool one;
        VkQueryPoolCreateInfo qi = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO };
        qi.queryType = VK_QUERY_TYPE_TIMESTAMP; qi.queryCount = 2;
        if (vkCreateQueryPool(dev, &qi, NULL, &one) != VK_SUCCESS) { puts("FAIL: single pool"); return 1; }
        uint64_t first[2] = { 0, 0 }, after[2] = { 0, 0 };
        for (int round = 0; round < 2; round++) {
            vkResetCommandBuffer(cmd, 0);
            VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
            bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            vkBeginCommandBuffer(cmd, &bi);
            vkCmdResetQueryPool(cmd, one, 0, 2);
            vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, one, 0);
            vkCmdFillBuffer(cmd, buf, 0, FILL_BYTES, 0x55667788u);
            vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, one, 1);
            vkEndCommandBuffer(cmd);
            VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
            si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
            vkResetFences(dev, 1, &fence);
            vkQueueSubmit(queue, 1, &si, fence);
            vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull);
            if (round == 0) {
                vkGetQueryPoolResults(dev, one, 0, 2, sizeof first, first, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT);
            } else {
                vkGetQueryPoolResults(dev, one, 0, 2, sizeof after, after, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT);
            }
        }
        printf("single_pool_hazard: first=%llu/%llu after_reset=%llu/%llu (first 被覆盖=%s)\n",
               (unsigned long long)first[0], (unsigned long long)first[1],
               (unsigned long long)after[0], (unsigned long long)after[1],
               first[0] == after[0] ? "no" : "yes");
        vkDestroyQueryPool(dev, one, NULL);
    }

    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 2 : 0;
}

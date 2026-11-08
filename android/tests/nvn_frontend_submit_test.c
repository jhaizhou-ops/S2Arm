// C5：共享 NVN 前端录制 ClearBuffer，经 mtl_exec→Vulkan decoder 真机回写 guest 内存。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { printf("missing %s\n", n); bad++; } return p; }
#define API(name) NVNT_##name name = (NVNT_##name)api(#name)

int main(void) {
    API(nvnDeviceBuilderSetDefaults); API(nvnDeviceBuilderSetFlags); API(nvnDeviceInitialize);
    API(nvnQueueBuilderSetDefaults); API(nvnQueueBuilderSetDevice); API(nvnQueueBuilderSetQueueMemory);
    API(nvnQueueBuilderSetCommandMemorySize); API(nvnQueueBuilderSetComputeMemorySize);
    API(nvnQueueBuilderSetControlMemorySize); API(nvnQueueInitialize);
    API(nvnMemoryPoolBuilderSetDefaults); API(nvnMemoryPoolBuilderSetDevice);
    API(nvnMemoryPoolBuilderSetStorage); API(nvnMemoryPoolBuilderSetFlags); API(nvnMemoryPoolInitialize);
    API(nvnCommandBufferInitialize); API(nvnCommandBufferAddCommandMemory);
    API(nvnCommandBufferBeginRecording); API(nvnCommandBufferClearBuffer);
    API(nvnCommandBufferCopyBufferToBuffer); API(nvnCommandBufferUpdateUniformBuffer);
    API(nvnCommandBufferEndRecording); API(nvnQueueSubmitCommands);
    if (bad) return 1;

    static uint8_t storage[256 * 1024] __attribute__((aligned(4096)));
    static uint8_t queue_memory[64 * 1024] __attribute__((aligned(4096)));
    memset(storage, 0, sizeof storage); memset(queue_memory, 0, sizeof queue_memory);
    NVNdeviceBuilder db; nvnDeviceBuilderSetDefaults(&db); nvnDeviceBuilderSetFlags(&db, 0);
    NVNdevice device; CHECK(nvnDeviceInitialize(&device, &db), "device init");
    NVNqueueBuilder qb; nvnQueueBuilderSetDefaults(&qb); nvnQueueBuilderSetDevice(&qb, &device);
    nvnQueueBuilderSetQueueMemory(&qb, queue_memory, sizeof queue_memory);
    nvnQueueBuilderSetCommandMemorySize(&qb, 4096);
    nvnQueueBuilderSetComputeMemorySize(&qb, 4096);
    nvnQueueBuilderSetControlMemorySize(&qb, 4096);
    NVNqueue queue; CHECK(nvnQueueInitialize(&queue, &qb), "queue init");
    NVNmemoryPoolBuilder mb; nvnMemoryPoolBuilderSetDefaults(&mb); nvnMemoryPoolBuilderSetDevice(&mb, &device);
    nvnMemoryPoolBuilderSetStorage(&mb, storage, sizeof storage); nvnMemoryPoolBuilderSetFlags(&mb, 0);
    NVNmemoryPool pool; CHECK(nvnMemoryPoolInitialize(&pool, &mb), "pool init");
    NVNcommandBuffer command; CHECK(nvnCommandBufferInitialize(&command, &device), "command init");
    nvnCommandBufferAddCommandMemory(&command, &pool, 0, 32 * 1024);
    nvnCommandBufferBeginRecording(&command);
    uint64_t address = (uint64_t)(uintptr_t)(storage + 128 * 1024);
    uint64_t copy_dst = (uint64_t)(uintptr_t)(storage + 132 * 1024);
    uint64_t uniform_dst = (uint64_t)(uintptr_t)(storage + 136 * 1024);
    nvnCommandBufferClearBuffer(&command, address, 64, 0xA5A5A5A5u);
    nvnCommandBufferCopyBufferToBuffer(&command, address, copy_dst, 64, 0);
    const uint8_t uniform[16] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
    nvnCommandBufferUpdateUniformBuffer(&command, uniform_dst, 64, 0, sizeof uniform, uniform);
    NVNcommandHandle handle = nvnCommandBufferEndRecording(&command);
    CHECK(handle != 0, "end recording");
    nvnQueueSubmitCommands(&queue, 1, &handle);
    uint32_t value = 0; memcpy(&value, (const void *)(uintptr_t)address, 4);
    CHECK(value == 0xA5A5A5A5u, "guest clear value %08x", value);
    uint32_t copied = 0; memcpy(&copied, (const void *)(uintptr_t)copy_dst, 4);
    CHECK(copied == 0xA5A5A5A5u, "guest copy value %08x", copied);
    CHECK(!memcmp((const void *)(uintptr_t)uniform_dst, uniform, sizeof uniform), "uniform update");
    printf("INFO nvn-frontend-submit: clear=%08x copy=%08x uniform=%02x%02x\n",
        value, copied, ((const uint8_t *)(uintptr_t)uniform_dst)[0], ((const uint8_t *)(uintptr_t)uniform_dst)[15]);
    if (bad) { printf("nvn-frontend-submit: %d FAILURES\n", bad); return 1; }
    printf("nvn-frontend-submit: ok\n");
    return 0;
}

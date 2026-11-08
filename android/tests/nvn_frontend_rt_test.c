// C5：NVN 前端 SetRenderTargets+ClearColor → 适配层 VkImage → host 读回。
#include "nvn_protos.h"
#include "nvn/vk_nvn_adapter.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { printf("missing %s\n", n); bad++; } return p; }
#define API(name) NVNT_##name name = (NVNT_##name)api(#name)

int main(void) {
    API(nvnDeviceBuilderSetDefaults); API(nvnDeviceInitialize);
    API(nvnQueueBuilderSetDefaults); API(nvnQueueBuilderSetDevice); API(nvnQueueBuilderSetQueueMemory);
    API(nvnQueueBuilderSetCommandMemorySize); API(nvnQueueBuilderSetComputeMemorySize);
    API(nvnQueueBuilderSetControlMemorySize); API(nvnQueueInitialize);
    API(nvnMemoryPoolBuilderSetDefaults); API(nvnMemoryPoolBuilderSetDevice);
    API(nvnMemoryPoolBuilderSetStorage); API(nvnMemoryPoolBuilderSetFlags); API(nvnMemoryPoolInitialize);
    API(nvnTextureBuilderSetDefaults); API(nvnTextureBuilderSetDevice); API(nvnTextureBuilderSetTarget);
    API(nvnTextureBuilderSetSize2D); API(nvnTextureBuilderSetFormat); API(nvnTextureBuilderSetLevels);
    API(nvnTextureBuilderSetStorage); API(nvnTextureInitialize);
    API(nvnCommandBufferInitialize); API(nvnCommandBufferAddCommandMemory);
    API(nvnCommandBufferBeginRecording); API(nvnCommandBufferSetRenderTargets);
    API(nvnCommandBufferClearColor); API(nvnCommandBufferEndRecording); API(nvnQueueSubmitCommands);
    if (bad) return 1;

    static uint8_t storage[1024 * 1024] __attribute__((aligned(4096)));
    static uint8_t queue_memory[64 * 1024] __attribute__((aligned(4096)));
    memset(storage, 0, sizeof storage); memset(queue_memory, 0, sizeof queue_memory);
    NVNdeviceBuilder db; nvnDeviceBuilderSetDefaults(&db);
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

    NVNtextureBuilder tb; nvnTextureBuilderSetDefaults(&tb); nvnTextureBuilderSetDevice(&tb, &device);
    nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D);
    nvnTextureBuilderSetSize2D(&tb, 8, 8);
    nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    nvnTextureBuilderSetLevels(&tb, 1);
    nvnTextureBuilderSetStorage(&tb, &pool, 512 * 1024);
    NVNtexture texture; memset(&texture, 0, sizeof texture);
    CHECK(nvnTextureInitialize(&texture, &tb), "texture init");

    NVNcommandBuffer command; CHECK(nvnCommandBufferInitialize(&command, &device), "command init");
    nvnCommandBufferAddCommandMemory(&command, &pool, 0, 32 * 1024);
    nvnCommandBufferBeginRecording(&command);
    const NVNtexture *targets[1] = {&texture};
    nvnCommandBufferSetRenderTargets(&command, 1, targets, NULL, NULL, NULL);
    const float color[4] = {0.25f, 0.5f, 0.75f, 1.0f};
    nvnCommandBufferClearColor(&command, 0, color, 0xF);
    NVNcommandHandle handle = nvnCommandBufferEndRecording(&command);
    CHECK(handle != 0, "end recording");
    nvnQueueSubmitCommands(&queue, 1, &handle);
    uint8_t pixels[8 * 8 * 4];
    CHECK(s2a_nvn_adapter_read_texture((const tex_t *)&texture, pixels, sizeof pixels) == 0, "read texture");
    const uint8_t want[4] = {64, 128, 191, 255};
    CHECK(!memcmp(pixels, want, 4), "clear pixel %u,%u,%u,%u", pixels[0], pixels[1], pixels[2], pixels[3]);
    printf("INFO nvn-frontend-rt: pixel=%u,%u,%u,%u\n", pixels[0], pixels[1], pixels[2], pixels[3]);

    // 整数 RT：同一 ClearColor 记录，按 VkFormat 选择 int32 clear。
    NVNtextureBuilder ib; nvnTextureBuilderSetDefaults(&ib); nvnTextureBuilderSetDevice(&ib, &device);
    nvnTextureBuilderSetTarget(&ib, NVN_TEXTURE_TARGET_2D);
    nvnTextureBuilderSetSize2D(&ib, 8, 8);
    nvnTextureBuilderSetFormat(&ib, NVN_FORMAT_RGBA8I);
    nvnTextureBuilderSetLevels(&ib, 1);
    nvnTextureBuilderSetStorage(&ib, &pool, 768 * 1024);
    NVNtexture itexture; memset(&itexture, 0, sizeof itexture);
    CHECK(nvnTextureInitialize(&itexture, &ib), "integer texture init");
    NVNcommandBuffer icommand; CHECK(nvnCommandBufferInitialize(&icommand, &device), "integer command init");
    nvnCommandBufferAddCommandMemory(&icommand, &pool, 32 * 1024, 8 * 1024);
    nvnCommandBufferBeginRecording(&icommand);
    const NVNtexture *itargets[1] = {&itexture};
    nvnCommandBufferSetRenderTargets(&icommand, 1, itargets, NULL, NULL, NULL);
    const float icolor[4] = {-128.0f, -1.0f, 0.0f, 127.0f};
    nvnCommandBufferClearColor(&icommand, 0, icolor, 0xF);
    NVNcommandHandle ihandle = nvnCommandBufferEndRecording(&icommand);
    nvnQueueSubmitCommands(&queue, 1, &ihandle);
    uint8_t ipixels[8 * 8 * 4];
    CHECK(s2a_nvn_adapter_read_texture((const tex_t *)&itexture, ipixels, sizeof ipixels) == 0, "read integer texture");
    const int8_t iwant[4] = {-128, -1, 0, 127};
    const int8_t igot[4] = {(int8_t)ipixels[0], (int8_t)ipixels[1], (int8_t)ipixels[2], (int8_t)ipixels[3]};
    CHECK(!memcmp(igot, iwant, 4), "integer clear pixel %d,%d,%d,%d", igot[0], igot[1], igot[2], igot[3]);
    printf("INFO nvn-frontend-rt-int: pixel=%d,%d,%d,%d\n", igot[0], igot[1], igot[2], igot[3]);

    if (bad) { printf("nvn-frontend-rt: %d FAILURES\n", bad); return 1; }
    printf("nvn-frontend-rt: ok\n");
    return 0;
}

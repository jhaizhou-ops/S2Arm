// C5：NVN 前端 BindProgram+DrawArrays → 适配层 VkPipeline/draw → 读回。
// 程序/管线由测试注册（shader 来自合成 GLSL）；不证明真实游戏 program 翻译。
#include "nvn_protos.h"
#include "nvn/vk_nvn_adapter.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { printf("missing %s\n", n); bad++; } return p; }
#define API(name) NVNT_##name name = (NVNT_##name)api(#name)
static uint8_t *load(const char *path, size_t *bytes) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *data = malloc((size_t)n); if (!data || fread(data, 1, (size_t)n, f) != (size_t)n) { free(data); fclose(f); return NULL; }
    fclose(f); *bytes = (size_t)n; return data;
}
int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <shader-dir>\n", argv[0]); return 2; }
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
    API(nvnCommandBufferBindProgram); API(nvnCommandBufferDrawArrays);
    API(nvnCommandBufferEndRecording); API(nvnQueueSubmitCommands);
    if (bad) return 1;
    static uint8_t storage[1024 * 1024] __attribute__((aligned(4096)));
    static uint8_t queue_memory[64 * 1024] __attribute__((aligned(4096)));
    memset(storage, 0, sizeof storage); memset(queue_memory, 0, sizeof queue_memory);
    NVNdeviceBuilder db; nvnDeviceBuilderSetDefaults(&db); NVNdevice device; CHECK(nvnDeviceInitialize(&device, &db), "device");
    NVNqueueBuilder qb; nvnQueueBuilderSetDefaults(&qb); nvnQueueBuilderSetDevice(&qb, &device);
    nvnQueueBuilderSetQueueMemory(&qb, queue_memory, sizeof queue_memory);
    nvnQueueBuilderSetCommandMemorySize(&qb, 4096); nvnQueueBuilderSetComputeMemorySize(&qb, 4096);
    nvnQueueBuilderSetControlMemorySize(&qb, 4096); NVNqueue queue; CHECK(nvnQueueInitialize(&queue, &qb), "queue");
    NVNmemoryPoolBuilder mb; nvnMemoryPoolBuilderSetDefaults(&mb); nvnMemoryPoolBuilderSetDevice(&mb, &device);
    nvnMemoryPoolBuilderSetStorage(&mb, storage, sizeof storage); nvnMemoryPoolBuilderSetFlags(&mb, 0);
    NVNmemoryPool pool; CHECK(nvnMemoryPoolInitialize(&pool, &mb), "pool");
    NVNtextureBuilder tb; nvnTextureBuilderSetDefaults(&tb); nvnTextureBuilderSetDevice(&tb, &device);
    nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D); nvnTextureBuilderSetSize2D(&tb, 8, 8);
    nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8); nvnTextureBuilderSetLevels(&tb, 1);
    nvnTextureBuilderSetStorage(&tb, &pool, 512 * 1024);
    NVNtexture texture; memset(&texture, 0, sizeof texture); CHECK(nvnTextureInitialize(&texture, &tb), "texture");
    char vert[512], frag[512]; snprintf(vert, sizeof vert, "%s/c2vs.vs.spv", argv[1]); snprintf(frag, sizeof frag, "%s/c2vs.fs.spv", argv[1]);
    size_t vs_bytes = 0, fs_bytes = 0; uint8_t *vs = load(vert, &vs_bytes), *fs = load(frag, &fs_bytes);
    CHECK(vs && fs, "load shaders");
    NVNprogram program; memset(&program, 0, sizeof program);
    CHECK(s2a_nvn_adapter_register_program_topology((const prog_t *)&program, vs, vs_bytes, fs, fs_bytes,
          VK_FORMAT_R8G8B8A8_UNORM, 8, 8, VK_PRIMITIVE_TOPOLOGY_POINT_LIST) == 0, "register point program");
    NVNcommandBuffer command; CHECK(nvnCommandBufferInitialize(&command, &device), "command");
    nvnCommandBufferAddCommandMemory(&command, &pool, 0, 32 * 1024);
    nvnCommandBufferBeginRecording(&command);
    const NVNtexture *targets[1] = {&texture};
    nvnCommandBufferSetRenderTargets(&command, 1, targets, NULL, NULL, NULL);
    nvnCommandBufferBindProgram(&command, &program, 3);
    nvnCommandBufferDrawArrays(&command, NVN_DRAW_PRIMITIVE_POINTS, 0, 1);
    NVNcommandHandle handle = nvnCommandBufferEndRecording(&command);
    CHECK(handle != 0, "end recording");
    nvnQueueSubmitCommands(&queue, 1, &handle);
    uint8_t pixels[8 * 8 * 4];
    CHECK(s2a_nvn_adapter_read_texture((const tex_t *)&texture, pixels, sizeof pixels) == 0, "read texture");
    const uint8_t *center = pixels + (4 * 8 + 4) * 4;
    CHECK(center[0] > 200 && center[1] < 40 && center[2] < 40 && center[3] > 200,
          "C2 draw center %u,%u,%u,%u", center[0], center[1], center[2], center[3]);
    printf("INFO nvn-frontend-c2vs: center=%u,%u,%u,%u\n", center[0], center[1], center[2], center[3]);
    free(vs); free(fs);
    if (bad) { printf("nvn-frontend-c2vs: %d FAILURES\n", bad); return 1; }
    printf("nvn-frontend-c2vs: ok\n");
    return 0;
}

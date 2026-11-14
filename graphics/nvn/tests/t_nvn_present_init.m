// 首次使用就是上屏的交换链纹理也必须带入池的初始内容。
// 公开 NVN 接口 → 独立上屏线程 → 整帧 GPU 回读；均匀灰色与块线性布局无关。
#import <Foundation/Foundation.h>
#include "nvn_protos.h"
#include "host_stubs.h"
#include <dispatch/dispatch.h>
#include <unistd.h>
#include <sched.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern void mtl_grab_next_present(void (^cb)(const uint8_t *, size_t, size_t, size_t));
extern int mtl_grab_inflight(void);
extern void nvn_be_present_wait(uint64_t ticket);
#include "nvn_obj.h"

#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)load(#name))

int main(void) {
    @autoreleasepool {
        alarm(60); setvbuf(stdout, NULL, _IOLBF, 0);
        setenv("DM_PRESENT_LINK", "0", 1);
        g_layer = [CAMetalLayer layer]; g_layer.drawableSize = CGSizeMake(64, 64);
        NVNdevice dev; NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db);
        REQUIRE(API(nvnDeviceInitialize)(&dev, &db));
        NVNqueue q; NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb);
        API(nvnQueueBuilderSetDevice)(&qb, &dev); REQUIRE(API(nvnQueueInitialize)(&q, &qb));
        void *mem = NULL; REQUIRE(!posix_memalign(&mem, 65536, 4 << 20));
        memset(mem, 0, 4 << 20);
        NVNmemoryPool pool; NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb);
        API(nvnMemoryPoolBuilderSetDevice)(&pb, &dev);
        API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, 4 << 20);
        API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
        REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
        unsigned failures = 0;
        for (int mode = 0; mode < 3; mode++) {
            size_t offset = (size_t)mode << 20;
            // 首次直接上屏：灰色已有内容、全零存储；第三例先由 GPU 清成白色。
            for (size_t i = 0; i < (1 << 20) / 4; i++) ((uint32_t *)((uint8_t *)mem + offset))[i] = mode == 1 ? 0 : 0xff808080;
            NVNtexture tex; NVNtextureBuilder tb; API(nvnTextureBuilderSetDefaults)(&tb);
            API(nvnTextureBuilderSetDevice)(&tb, &dev); API(nvnTextureBuilderSetSize2D)(&tb, 64, 64);
            API(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8);
            API(nvnTextureBuilderSetStorage)(&tb, &pool, (ptrdiff_t)offset); REQUIRE(API(nvnTextureInitialize)(&tex, &tb));
            if (mode == 2) {
                NVNcommandBuffer cmd; REQUIRE(API(nvnCommandBufferInitialize)(&cmd, &dev));
                static uint8_t control[16384];
                API(nvnCommandBufferAddControlMemory)(&cmd, control, sizeof control);
                API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, 3 << 20, 1 << 20);
                API(nvnCommandBufferBeginRecording)(&cmd);
                NVNcopyRegion whole = {0, 0, 0, 64, 64, 1}; float white[4] = {1, 1, 1, 1};
                API(nvnCommandBufferClearTexture)(&cmd, &tex, NULL, &whole, white, 15);
                NVNcommandHandle handle = API(nvnCommandBufferEndRecording)(&cmd);
                API(nvnQueueSubmitCommands)(&q, 1, &handle); API(nvnQueueFinish)(&q);
            }
            unsigned want = mode == 0 ? 128 : mode == 1 ? 0 : 255;
            NVNwindow window; NVNwindowBuilder wb; API(nvnWindowBuilderSetDefaults)(&wb);
            API(nvnWindowBuilderSetDevice)(&wb, &dev); NVNtexture *textures[] = {&tex};
            API(nvnWindowBuilderSetTextures)(&wb, 1, textures); REQUIRE(API(nvnWindowInitialize)(&window, &wb));
            dispatch_semaphore_t got = dispatch_semaphore_create(0);
            __block size_t pixels = 0, bad = 0;
            mtl_grab_next_present(^(const uint8_t *b, size_t w, size_t h, size_t row) {
                if (b) for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
                    const uint8_t *v = b + row * y + x * 4;
                    pixels++; bad += v[0] != want || v[1] != want || v[2] != want;
                }
                dispatch_semaphore_signal(got);
            });
            API(nvnQueuePresentTexture)(&q, &window, 0);
            nvn_be_present_wait(((win_t *)&window)->ticket[0]);
            REQUIRE(!dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)));
            while (mtl_grab_inflight()) sched_yield();
            int pass = pixels == 64 * 64 && !bad;
            printf("%s present case %d: %zu pixels, %zu differ from RGB %u,%u,%u\n", pass ? "PASS" : "FAIL", mode, pixels, bad, want, want, want);
            failures += !pass;
        }
        return failures != 0;
    }
}

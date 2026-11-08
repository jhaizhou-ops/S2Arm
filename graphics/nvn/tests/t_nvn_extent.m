// Real public NVN recording, storage and mip-view readback at 1x. The same
// pixel oracle can also be compiled with the frozen pre-contract backend.
#ifndef NVN_EXTENT_BACKEND_SOURCE
#define NVN_EXTENT_BACKEND_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_EXTENT_BACKEND_SOURCE
#include "../gfx/nvn/nvn_protos.h"

extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static NVNtexturePool textures;
static uint8_t *memory;
static unsigned checks;
static const char *mode_name;
enum { POOL_SIZE = 64 << 20, COMMAND_SIZE = 1 << 20 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *api(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))

static void begin(void) {
    API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE);
    API(nvnCommandBufferBeginRecording)(&commands);
}
static void submit(void) {
    NVNcommandHandle handle = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle);
    API(nvnQueueSubmitCommands)(&queue, 1, &handle); API(nvnQueueFinish)(&queue);
    REQUIRE(!mtl_last_commit_error());
}
static NVNtextureView view(unsigned level, unsigned layer) {
    NVNtextureView v; API(nvnTextureViewSetDefaults)(&v);
    API(nvnTextureViewSetLevels)(&v, level, 1); API(nvnTextureViewSetLayers)(&v, layer, 1);
    API(nvnTextureViewSetTarget)(&v, NVN_TEXTURE_TARGET_2D); return v;
}
static void clear(NVNtexture *t, unsigned level, unsigned layer, const float rgba[4]) {
    NVNtextureView v = view(level, layer);
    const NVNtexture *colors[] = {t}; const NVNtextureView *views[] = {&v};
    API(nvnCommandBufferSetRenderTargets)(&commands, 1, colors, views, NULL, NULL);
    API(nvnCommandBufferClearColor)(&commands, 0, rgba, 15);
}
// Independent Metal blit reads actual storage, including the strip outside L.
// A clear of the selected mip must cover its entire physical extent; all other
// mips/layers retain the old red L rectangle and zero-initialized new capacity.
static void pixels(id<MTLTexture> t, unsigned level, unsigned layer, int w, int h, int lw, int lh, int green) {
    REQUIRE(MAX(t.width >> level, 1ul) == (NSUInteger)w && MAX(t.height >> level, 1ul) == (NSUInteger)h);
    size_t row = ((size_t)w * 4 + 255) & ~(size_t)255;
    id<MTLBuffer> out = [t.device newBufferWithLength:row * h options:MTLResourceStorageModeShared]; REQUIRE(out);
    id<MTLCommandQueue> q = [t.device newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:layer sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
             toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(!cb.error);
    const uint8_t red[] = {255, 0, 0, 255}, g[] = {0, 255, 0, 255}, zero[] = {0, 0, 0, 0};
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const uint8_t *want = green ? g : x < lw && y < lh ? red : zero;
        REQUIRE(!memcmp((const uint8_t *)out.contents + y * row + x * 4, want, 4));
    }
    const char *dump = getenv("NVN_EXTENT_PIXELS");
    if (dump && *dump) {
        char path[2048]; const char *backend = getenv("NXGAL_BE");
        int n = snprintf(path, sizeof path, "%s/%s-%s-%s-level%u-layer%u-%dx%d.rgba", dump, backend ? backend : "default", mode_name,
                         t.parentTexture ? "view" : "storage", level, layer, w, h);
        REQUIRE(n > 0 && (size_t)n < sizeof path); FILE *f = fopen(path, "wb"); REQUIRE(f);
        for (int y = 0; y < h; y++) REQUIRE(fwrite((const uint8_t *)out.contents + y * row, 4, w, f) == (size_t)w);
        REQUIRE(!fclose(f));
    }
}
int main(int argc, char **argv) { @autoreleasepool {
    REQUIRE(argc == 2);
    int tall = !strcmp(argv[1], "tall"), wide = !strcmp(argv[1], "wide");
    REQUIRE(tall || wide || !strcmp(argv[1], "plain"));
    mode_name = argv[1];
    const int lw = tall ? 1920 : wide ? 128 : 13, lh = tall ? 1080 : wide ? 72 : 9;
    const int pw = wide ? 156 : lw, ph = tall ? 1350 : lh, levels = tall ? 2 : 3;
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
    REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(!posix_memalign((void **)&memory, 65536, POOL_SIZE)); memset(memory, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
    REQUIRE(API(nvnTexturePoolInitialize)(&textures, &pool, COMMAND_SIZE, 512));
    NVNtextureBuilder tb; API(nvnTextureBuilderSetDefaults)(&tb); API(nvnTextureBuilderSetDevice)(&tb, &device);
    API(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D_ARRAY); API(nvnTextureBuilderSetSize3D)(&tb, lw, lh, 2);
    API(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetLevels)(&tb, levels);
    API(nvnTextureBuilderSetFlags)(&tb, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    REQUIRE(API(nvnTextureBuilderGetStorageSize)(&tb) < POOL_SIZE - (2 << 20));
    API(nvnTextureBuilderSetStorage)(&tb, &pool, 2 << 20);
    NVNtexture texture = {0}, alias = {0}; REQUIRE(API(nvnTextureInitialize)(&texture, &tb)); REQUIRE(API(nvnTextureInitialize)(&alias, &tb));
    const tex_t *t = (const tex_t *)&texture, *a = (const tex_t *)&alias;
    const float red[] = {1, 0, 0, 1}, green[] = {0, 1, 0, 1};
    g_wd = 0; g_wd_gen = s2a_screen_gen();
    begin(); for (int l = 0; l < levels; l++) for (int z = 0; z < 2; z++) clear(&texture, l, z, red); submit();
    id<MTLTexture> old = tex_mtl(t); REQUIRE(old == tex_mtl(a));
    NVNtextureView v = view(1, 1); API(nvnTexturePoolRegisterTexture)(&textures, 256, &alias, &v);
    // Match wd_draw -> wd_tex_scales -> tex_fast_rid's slow view path: the
    // caller already owns the widen lock before taking the registry lock.
    pthread_mutex_lock(&g_wd_mu); pthread_mutex_lock(&g_rmu);
    id<MTLTexture> old_view = tex_by_id(256);
    pthread_mutex_unlock(&g_rmu); pthread_mutex_unlock(&g_wd_mu);
    REQUIRE(old_view && old_view.width == (NSUInteger)(lw >> 1) && old_view.height == (NSUInteger)(lh >> 1));
    if (wide || tall) { g_wd = s2a_widen_init(wide ? 2346 : 1920, wide ? 1080 : 1350, S2A_WIDEN_FULL); REQUIRE(g_wd > 0); }
    g_wd_gen = s2a_screen_gen();
    begin(); clear(&texture, 1, 1, green); submit();
    id<MTLTexture> storage = tex_mtl(t); REQUIRE(storage == tex_mtl(a));
    REQUIRE(storage.width == (NSUInteger)pw && storage.height == (NSUInteger)ph && storage.mipmapLevelCount == (NSUInteger)levels);
    REQUIRE(API(nvnTextureGetWidth)(&texture) == lw && API(nvnTextureGetHeight)(&texture) == lh);
    REQUIRE(g_pass.tw == (NSUInteger)(pw >> 1) && g_pass.th == (NSUInteger)(ph >> 1));
    pthread_mutex_lock(&g_wd_mu); pthread_mutex_lock(&g_rmu);
    id<MTLTexture> selected = tex_by_id(256);
    pthread_mutex_unlock(&g_rmu); pthread_mutex_unlock(&g_wd_mu);
    REQUIRE(selected && selected.width == (NSUInteger)(pw >> 1) && selected.height == (NSUInteger)(ph >> 1));
    REQUIRE(selected.mipmapLevelCount == 1 && selected.arrayLength == 1 && selected.parentRelativeLevel == 1 && selected.parentRelativeSlice == 1);
    if (wide || tall) REQUIRE(storage != old && selected != old_view);
#ifdef NVN_TEXTURE_EXTENT_CONTRACT
    tex_extent e = tex_extent_at(t, storage, 1, 1);
    REQUIRE(e.logical_known && e.logical.width == (NSUInteger)(lw >> 1) && e.logical.height == (NSUInteger)(lh >> 1));
    REQUIRE(!e.requested_known && !e.requested.width && !e.requested.height);
    REQUIRE(e.canvas.width == selected.width && e.canvas.height == selected.height);
    REQUIRE(e.physical.width == selected.width && e.physical.height == selected.height);
    REQUIRE(e.serial_generation == g_ser_gen && e.level == 1 && e.layer == 1 && e.storage_level == 1 && e.levels == (NSUInteger)levels - 1);
    tex_extent ve = tex_extent_at(a, selected, 0, 0);
    REQUIRE(ve.storage_level == 1 && ve.logical.width == (NSUInteger)(lw >> 1) && ve.physical.width == selected.width);
    tex_extent physical_only = tex_extent_at(NULL, selected, 0, 0);
    REQUIRE(!physical_only.logical_known && !physical_only.logical.width && !physical_only.logical.height && !physical_only.requested_known);
    REQUIRE(physical_only.physical.width == selected.width && physical_only.physical.height == selected.height);
#endif
    for (int l = 0; l < levels; l++) for (int z = 0; z < 2; z++)
        pixels(storage, l, z, MAX(pw >> l, 1), MAX(ph >> l, 1), MAX(lw >> l, 1), MAX(lh >> l, 1), l == 1 && z == 1);
    pixels(selected, 0, 0, pw >> 1, ph >> 1, lw >> 1, lh >> 1, 1);
    // Returning to a smaller canvas request keeps existing storage and views.
    uint64_t generation = g_ser_gen; REQUIRE(tex_widen(t, lw, lh));
    REQUIRE(tex_mtl(t) == storage && tex_mtl(a) == storage && g_ser_gen == generation);
    // 打包贴图（CPU 写过的池，11-02 饥荒交换链）当渲染目标也能放宽：tex_widen 换 NvPkg 自己的贴图（表里存的是 NvPkg）。手算期望：128×72 → 156×72、带渲染目标用途、
    //   NvPkg 的 tex 就是新存储、贴图号代数涨了；改前 tex_widen_why 一律回 "packaged"，这里返回 0
    if (wide) {
        NVNtextureBuilder pb2; API(nvnTextureBuilderSetDefaults)(&pb2); API(nvnTextureBuilderSetDevice)(&pb2, &device);
        API(nvnTextureBuilderSetTarget)(&pb2, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&pb2, 128, 72);
        API(nvnTextureBuilderSetFormat)(&pb2, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetStorage)(&pb2, &pool, 16 << 20);
        NVNtexture pt = {0}; REQUIRE(API(nvnTextureInitialize)(&pt, &pb2)); const tex_t *ptt = (const tex_t *)&pt;
        nvn_be_tex_cpu_written(ptt); id<MTLTexture> p0 = tex_mtl(ptt); REQUIRE(p0 && p0.width == 128);
        __unsafe_unretained id po = tex_get(ptt->serial); REQUIRE([po isKindOfClass:[NvPkg class]]);
        uint64_t pg = g_ser_gen; REQUIRE(tex_widen(ptt, 156, 72));
        id<MTLTexture> p1 = tex_mtl(ptt); REQUIRE(p1 && p1 != p0 && p1.width == 156 && p1.height == 72 && (p1.usage & MTLTextureUsageRenderTarget));
        REQUIRE(((NvPkg *)tex_get(ptt->serial))->tex == p1 && g_ser_gen > pg);
    }
    printf("✓ t_nvn_extent 1x %s: L=%dx%d P=%dx%d, real mip/layer clear, alias/view storage, preserved capacity; %u checks\n", argv[1], lw, lh, pw, ph, checks);
    return 0;
} }

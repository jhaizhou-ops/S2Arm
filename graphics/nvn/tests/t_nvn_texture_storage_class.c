// Full production NVN bootstrap / registration / thunks, with real object lifetimes and memory pools.
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
static const char *phase = "准备";
static unsigned checks;
static NVNdevice device;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL [%s] %s:%d：%s\n", phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) {
    void *entry = h_nvnBootstrapLoader(name); CHECK(entry != NULL); return entry;
}
#define API(name) ((NVNT_##name)load(#name))
#define GUARD UINT64_C(0x96ec2b58130a74df)
#define GUARDED(type, name) typedef struct { uint64_t pre[2]; type object; uint64_t post[2]; } name
GUARDED(NVNtextureBuilder, guarded_builder);
GUARDED(NVNmemoryPool, guarded_pool);
GUARDED(NVNtexture, guarded_texture);
#define SET_GUARDS(box) do { (box).pre[0] = (box).pre[1] = (box).post[0] = (box).post[1] = GUARD; } while (0)
#define CHECK_GUARDS(box) do { CHECK((box).pre[0] == GUARD && (box).pre[1] == GUARD); \
    CHECK((box).post[0] == GUARD && (box).post[1] == GUARD); } while (0)
typedef struct {
    const char *name; NVNformat format; NVNtextureFlags flags; ptrdiff_t stride; uint32_t expected;
} texture_case;
// Expected classes come from the SDK branches, not another query. Linear cases use RGBA8 only.
static const texture_case cases[] = {
    {"R8", NVN_FORMAT_R8, 0, 0, 2},
    {"RGBA8", NVN_FORMAT_RGBA8, 0, 0, 2},
    {"RGBA16F", NVN_FORMAT_RGBA16F, 0, 0, 2},
    {"RGBA8 SRGB", NVN_FORMAT_RGBA8_SRGB, 0, 0, 2},
    {"DXT1", NVN_FORMAT_RGB_DXT1, 0, 0, 2},
    {"STENCIL8", NVN_FORMAT_STENCIL8, 0, 0, 3},
    {"DEPTH16", NVN_FORMAT_DEPTH16, 0, 0, 3},
    {"DEPTH24", NVN_FORMAT_DEPTH24, 0, 0, 4},
    {"DEPTH24 STENCIL8", NVN_FORMAT_DEPTH24_STENCIL8, 0, 0, 4},
    {"DEPTH32F STENCIL8", NVN_FORMAT_DEPTH32F_STENCIL8, 0, 0, 5},
    {"LINEAR RGBA8", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_LINEAR, 256, 1},
    {"LINEAR_RENDER_TARGET RGBA8", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET, 256, 1},
    {"DEPTH32F", NVN_FORMAT_DEPTH32F, 0, 0, 2},
    {"IMAGE RGBA8", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_IMAGE, 0, 2},
};
typedef struct {
    guarded_builder builder; guarded_pool pool; guarded_texture texture; void *bytes;
} fixture;
static void check_class(fixture *f, uint32_t expected) {
    guarded_builder before_builder = f->builder;
    guarded_pool before_pool = f->pool;
    guarded_texture before_texture = f->texture;
    CHECK(API(nvnTextureGetRawStorageClass)(&f->texture.object) == expected);
    CHECK(memcmp(&before_texture, &f->texture, sizeof before_texture) == 0);
    CHECK(memcmp(&before_builder, &f->builder, sizeof before_builder) == 0);
    CHECK(memcmp(&before_pool, &f->pool, sizeof before_pool) == 0);
    CHECK_GUARDS(f->texture); CHECK_GUARDS(f->builder); CHECK_GUARDS(f->pool);
}
static void create(fixture *f, const texture_case *c) {
    memset(f, 0, sizeof *f);
    SET_GUARDS(f->builder); SET_GUARDS(f->pool); SET_GUARDS(f->texture);
    memset(&f->texture.object, 0xa5, sizeof f->texture.object);
    NVNtextureBuilder *builder = &f->builder.object;
    API(nvnTextureBuilderSetDefaults)(builder);
    API(nvnTextureBuilderSetDevice)(builder, &device);
    API(nvnTextureBuilderSetTarget)(builder, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(builder, 64, 32);
    API(nvnTextureBuilderSetLevels)(builder, 1);
    API(nvnTextureBuilderSetFormat)(builder, c->format);
    API(nvnTextureBuilderSetFlags)(builder, c->flags);
    if (c->stride) API(nvnTextureBuilderSetStride)(builder, c->stride);
    CHECK(API(nvnTextureBuilderGetRawStorageClass)(builder) == c->expected);
    size_t size = API(nvnTextureBuilderGetStorageSize)(builder);
    size_t align = API(nvnTextureBuilderGetStorageAlignment)(builder), page = (size_t)getpagesize();
    CHECK(size > 0 && align > 0 && (align & (align - 1)) == 0);
    if (align < page) align = page;
    size = (size + align - 1) & ~(align - 1);
    CHECK(posix_memalign(&f->bytes, align, size) == 0); memset(f->bytes, 0, size);
    NVNmemoryPoolBuilder pool_builder = {{0}};
    API(nvnMemoryPoolBuilderSetDefaults)(&pool_builder);
    API(nvnMemoryPoolBuilderSetDevice)(&pool_builder, &device);
    API(nvnMemoryPoolBuilderSetFlags)(&pool_builder, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolBuilderSetStorage)(&pool_builder, f->bytes, size);
    CHECK(API(nvnMemoryPoolInitialize)(&f->pool.object, &pool_builder));
    API(nvnTextureBuilderSetStorage)(builder, &f->pool.object, 0);
    CHECK(API(nvnTextureInitialize)(&f->texture.object, builder));
    CHECK(API(nvnTextureGetFormat)(&f->texture.object) == c->format);
    CHECK(API(nvnTextureGetFlags)(&f->texture.object) == c->flags);
    CHECK(API(nvnTextureGetMemoryPool)(&f->texture.object) == &f->pool.object);
    check_class(f, c->expected);
}
static void change_builder(fixture *f, uint32_t old_class) {
    NVNtextureBuilder *builder = &f->builder.object;
    API(nvnTextureBuilderSetFlags)(builder, 0);
    API(nvnTextureBuilderSetStride)(builder, 0);
    API(nvnTextureBuilderSetFormat)(builder, old_class == 3 ? NVN_FORMAT_RGBA8 : NVN_FORMAT_DEPTH16);
    CHECK(API(nvnTextureBuilderGetRawStorageClass)(builder) == (old_class == 3 ? 2u : 3u));
    check_class(f, old_class);
}
static void destroy(fixture *f) {
    API(nvnTextureFinalize)(&f->texture.object);
    API(nvnMemoryPoolFinalize)(&f->pool.object);
    CHECK_GUARDS(f->texture); CHECK_GUARDS(f->builder); CHECK_GUARDS(f->pool);
    free(f->bytes);
}
int main(void) {
    NVNdeviceBuilder builder = {{0}};
    API(nvnDeviceBuilderSetDefaults)(&builder);
    CHECK(API(nvnDeviceInitialize)(&device, &builder));
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        phase = cases[i].name;
        fixture f; create(&f, &cases[i]); change_builder(&f, cases[i].expected); destroy(&f);
        printf("%s：通过\n", phase); fflush(stdout);
    }
    phase = "多对象独立、Builder 修改和 Finalize 后重新初始化";
    const texture_case colour = {"多对象 RGBA8", NVN_FORMAT_RGBA8, 0, 0, 2};
    const texture_case depth = {"多对象 DEPTH32F STENCIL8", NVN_FORMAT_DEPTH32F_STENCIL8, 0, 0, 5};
    fixture a, b; create(&a, &colour); create(&b, &depth);
    change_builder(&a, 2); change_builder(&b, 5);
    check_class(&a, 2); check_class(&b, 5);
    API(nvnTextureFinalize)(&a.texture.object);
    // RGBA8's existing allocation also holds DEPTH16 at the same dimensions and alignment.
    CHECK(API(nvnTextureBuilderGetStorageSize)(&a.builder.object) <= API(nvnMemoryPoolGetSize)(&a.pool.object));
    CHECK((uintptr_t)a.bytes % API(nvnTextureBuilderGetStorageAlignment)(&a.builder.object) == 0);
    CHECK(API(nvnTextureInitialize)(&a.texture.object, &a.builder.object));
    check_class(&a, 3); check_class(&b, 5);
    destroy(&b); check_class(&a, 3); destroy(&a);
    API(nvnDeviceFinalize)(&device);
    printf("✓ t_nvn_texture_storage_class：%u 条真实 API 断言\n", checks);
    return 0;
}

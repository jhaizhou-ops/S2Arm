// Public NVN API -> recorded commands -> production Metal GPU -> public readback.
// No internal object/opcode construction and no host replacement symbols.
#include "nvn_protos.h"
#include <limits.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *);
typedef struct { const char *name; void *fn; } Entry;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static size_t textureOffset = 1 << 20;
static unsigned cases, texels;
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 1 << 20 };
static void *load(const char *name) {
    unsigned long size = 0;
    const Entry *entries = (const Entry *)getsectiondata(&_mh_execute_header, "__DATA", "swnvn", &size);
    int found = 0;
    for (unsigned long i = 0; i < size / sizeof *entries; ++i)
        if (!strcmp(entries[i].name, name) && entries[i].fn) found++;
    if (found != 1) { fprintf(stderr, "FAIL production swnvn semantic entry %s count=%d\n", name, found); exit(1); }
    void *p = h_nvnBootstrapLoader(name);
    REQUIRE(p);
    return p;
}
#define API(name) ((NVNT_##name)load(#name))
static void setup(void) {
    // A thunk can exist for an unimplemented name; require its actual semantic entry.
    load("nvnCommandBufferClearTexturei");
    NVNdeviceBuilder db;
    API(nvnDeviceBuilderSetDefaults)(&db);
    REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    const char *names[] = {"nvnCommandBufferClearTexture", "nvnCommandBufferClearTexturei", "nvnCommandBufferClearTextureui"};
    for (unsigned i = 0; i < sizeof names / sizeof *names; ++i)
        REQUIRE((void *)API(nvnDeviceGetProcAddress)(&device, names[i]) == load(names[i]));
    NVNqueueBuilder qb;
    API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
    REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    void *storage = NULL;
    REQUIRE(posix_memalign(&storage, 65536, POOL_SIZE) == 0);
    memset(storage, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb;
    API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
    REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384];
    API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
}
static void begin(void) {
    API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE);
    API(nvnCommandBufferBeginRecording)(&commands);
}
static void submit(void) {
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands);
    REQUIRE(h);
    API(nvnQueueSubmitCommands)(&queue, 1, &h);
    API(nvnQueueFinish)(&queue);
}
static void texture(NVNtexture *t, NVNformat format, int array, int levels) {
    NVNtextureBuilder b;
    API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, array ? NVN_TEXTURE_TARGET_2D_ARRAY : NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize3D)(&b, 8, 8, array ? 3 : 1);
    API(nvnTextureBuilderSetLevels)(&b, levels); API(nvnTextureBuilderSetFormat)(&b, format);
    size_t alignment = API(nvnTextureBuilderGetStorageAlignment)(&b), size = API(nvnTextureBuilderGetStorageSize)(&b);
    REQUIRE(alignment && size);
    textureOffset = (textureOffset + alignment - 1) / alignment * alignment;
    REQUIRE(textureOffset + size <= POOL_SIZE);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)textureOffset);
    textureOffset += size;
    memset(t, 0, sizeof *t);
    REQUIRE(API(nvnTextureInitialize)(t, &b));
}
static void view(NVNtextureView *v, int level, int layer, NVNformat format) {
    API(nvnTextureViewSetDefaults)(v);
    API(nvnTextureViewSetLevels)(v, level, 1); API(nvnTextureViewSetLayers)(v, layer, 1);
    if (format) API(nvnTextureViewSetFormat)(v, format);
}
static void check(const char *name, NVNtexture *t, int level, int layer, int bytes, const void *expected) {
    NVNtextureView v; view(&v, level, layer, 0);
    int width = 8 >> level;
    NVNcopyRegion r = {0, 0, 0, width, width, 1};
    uint8_t data[8 * 8 * 16]; memset(data, 0xA5, sizeof data);
    API(nvnTextureReadTexels)(t, &v, &r, data);
    for (int p = 0; p < width * width; ++p) {
        if (memcmp(data + p * bytes, expected, (size_t)bytes)) {
            fprintf(stderr, "FAIL %s mip%d layer%d texel%d got", name, level, layer, p);
            for (int j = 0; j < bytes; ++j) fprintf(stderr, " %02x", data[p * bytes + j]);
            fprintf(stderr, " expected");
            for (int j = 0; j < bytes; ++j) fprintf(stderr, " %02x", ((const uint8_t *)expected)[j]);
            fputc('\n', stderr); exit(1);
        }
        texels++;
    }
}
static void signed_case(const char *name, NVNformat base, NVNformat as, const int values[4], int bytes, const void *expected) {
    NVNtexture t; texture(&t, base, 0, 1);
    NVNtextureView v; view(&v, 0, 0, as);
    NVNcopyRegion r = {0, 0, 0, 8, 8, 1};
    int rgba[4]; memcpy(rgba, values, sizeof rgba);
    begin(); API(nvnCommandBufferClearTexturei)(&commands, &t, &v, &r, rgba, 15);
    // The caller owns these input structs and may reuse them immediately.
    memset(rgba, 0, sizeof rgba); r.width = 1; r.height = 1;
    API(nvnTextureViewSetLevels)(&v, 7, 1); API(nvnTextureViewSetFormat)(&v, NVN_FORMAT_RGBA32F);
    submit(); check(name, &t, 0, 0, bytes, expected);
    API(nvnTextureFinalize)(&t); cases++;
    printf("PASS %s: 64 GPU texels, rgba/view/region recorded snapshot\n", name);
}
static void mip_array_case(void) {
    NVNtexture t; texture(&t, NVN_FORMAT_RGBA32I, 1, 3);
    const int sentinel[] = {1, 2, 3, 4}, value[] = {INT_MIN, INT_MAX, -16777217, 16777217};
    begin();
    for (int level = 0; level < 3; ++level) for (int layer = 0; layer < 3; ++layer) {
        NVNtextureView v; view(&v, level, layer, 0);
        NVNcopyRegion r = {0, 0, 0, 8 >> level, 8 >> level, 1};
        API(nvnCommandBufferClearTexturei)(&commands, &t, &v, &r, sentinel, 15);
    }
    NVNtextureView v; view(&v, 1, 1, NVN_FORMAT_RGBA32I);
    API(nvnTextureViewSetLayers)(&v, 1, 2);
    NVNcopyRegion r = {0, 0, 1, 4, 4, 1};
    int rgba[4]; memcpy(rgba, value, sizeof rgba);
    API(nvnCommandBufferClearTexturei)(&commands, &t, &v, &r, rgba, 15);
    memset(rgba, 0, sizeof rgba); r = (NVNcopyRegion){0, 0, 0, 1, 1, 1};
    view(&v, 0, 0, NVN_FORMAT_RGBA32UI);
    submit();
    for (int level = 0; level < 3; ++level) for (int layer = 0; layer < 3; ++layer)
        check("mip-array-snapshot", &t, level, layer, 16, level == 1 && layer == 2 ? value : sentinel);
    API(nvnTextureFinalize)(&t); cases++;
    puts("PASS mip-array-snapshot: 252 GPU texels, mip1 layer(1+z1) only, other mip/layers preserved");
}
static void regression(const char *name, NVNformat format, int isUint, const void *value, int bytes, const void *expected) {
    NVNtexture t; texture(&t, format, 0, 1);
    NVNcopyRegion r = {0, 0, 0, 8, 8, 1};
    begin();
    if (isUint) API(nvnCommandBufferClearTextureui)(&commands, &t, NULL, &r, value, 15);
    else API(nvnCommandBufferClearTexture)(&commands, &t, NULL, &r, value, 15);
    submit(); check(name, &t, 0, 0, bytes, expected);
    API(nvnTextureFinalize)(&t); cases++; printf("PASS %s: 64 GPU texels\n", name);
}
int main(void) {
    setup();
    const int signed8[] = {-128, -1, 0, 127};
    const int8_t expected8[] = {-128, -1, 0, 127};
    const int signed32[] = {INT_MIN, INT_MAX, -1, 16777217};
    signed_case("RGBA8I-negative", NVN_FORMAT_RGBA8I, 0, signed8, 4, expected8);
    signed_case("RGBA32I-INT32-exact", NVN_FORMAT_RGBA32I, 0, signed32, 16, signed32);
    signed_case("RGBA8UI-signed-format-view", NVN_FORMAT_RGBA8UI, NVN_FORMAT_RGBA8I, signed8, 4, expected8);
    signed_case("RGBA32UI-signed-format-view", NVN_FORMAT_RGBA32UI, NVN_FORMAT_RGBA32I, signed32, 16, signed32);
    mip_array_case();
    const float normalized[] = {1, 0.5f, 0.25f, 0}, floats[] = {-1, 0.5f, 16777216, 1};
    const uint8_t expectedNormalized[] = {255, 128, 64, 0}, expectedUint8[] = {0, 17, 255, 42};
    const uint32_t uint8[] = {0, 17, 255, 42}, uint32[] = {0, UINT32_MAX, 16777217, 42};
    regression("float-RGBA8", NVN_FORMAT_RGBA8, 0, normalized, 4, expectedNormalized);
    regression("float-RGBA32F", NVN_FORMAT_RGBA32F, 0, floats, 16, floats);
    regression("uint-RGBA8UI", NVN_FORMAT_RGBA8UI, 1, uint8, 4, expectedUint8);
    regression("uint-RGBA32UI", NVN_FORMAT_RGBA32UI, 1, uint32, 16, uint32);
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&pool); API(nvnDeviceFinalize)(&device);
    printf("✓ t_nvn_f：%u cases, %u real Metal GPU texels, signed/float/uint and recording snapshots\n", cases, texels);
    return 0;
}

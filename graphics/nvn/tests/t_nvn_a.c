// 通过生产 bootstrap / swnvn / 计数跳板检查 Builder 查询与 TextureView 比较；不初始化 GPU。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static const char *filter, *query, *phase;
static unsigned checks;
static NVNdevice device;
static NVNmemoryPool pool;
static unsigned char storage[256];

static void *load(const char *name) {
    void *p = h_nvnBootstrapLoader(name);
    if (!p) { fprintf(stderr, "找不到公开 API：%s\n", name); exit(1); }
    return p;
}
static int select_query(const char *name) {
    if (filter && strcmp(filter, name)) return 0;
    query = name;
    printf("%s [%s]\n", query, phase); fflush(stdout);
    return 1;
}
#define API(name) ((NVNT_##name)load(#name))
#define CASE(name) if (select_query(#name))
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL %s [%s] %s:%d：%s\n", query, phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
#define GUARD UINT64_C(0xc53a709df28b146e)
#define OBJECT(type, name) struct { uint64_t pre[2]; type obj; uint64_t post[2]; } name = \
    { { GUARD, GUARD }, { { 0 } }, { GUARD, GUARD } }
#define BOUNDARY(name) do { \
    if (name.pre[0] != GUARD || name.pre[1] != GUARD || name.post[0] != GUARD || name.post[1] != GUARD) { \
        fprintf(stderr, "FAIL 对象边界：%s [%s]\n", #name, phase); exit(1); \
    } \
} while (0)
#define VALUE(name, expected) CASE(name) { CHECK(API(name)(b) == (expected)); }
static const char *phases[] = { "默认", "Set/Get", "SetDefaults 复位" };

static void device_builder(void) {
    OBJECT(NVNdeviceBuilder, box); NVNdeviceBuilder *b = &box.obj;
    for (int p = 0; p < 3; p++) {
        phase = phases[p];
        if (p == 1) API(nvnDeviceBuilderSetFlags)(b, 0x35);
        else API(nvnDeviceBuilderSetDefaults)(b);
        VALUE(nvnDeviceBuilderGetFlags, p == 1 ? 0x35 : 0);
        BOUNDARY(box);
    }
}
static void memory_pool_builder(void) {
    OBJECT(NVNmemoryPoolBuilder, box); NVNmemoryPoolBuilder *b = &box.obj;
    API(nvnMemoryPoolBuilderSetDevice)(b, &device);
    for (int p = 0; p < 3; p++) {
        phase = phases[p];
        if (p == 1) {
            API(nvnMemoryPoolBuilderSetStorage)(b, storage, sizeof storage);
            API(nvnMemoryPoolBuilderSetFlags)(b, 0x12);
        } else API(nvnMemoryPoolBuilderSetDefaults)(b);
        VALUE(nvnMemoryPoolBuilderGetDevice, &device);
        VALUE(nvnMemoryPoolBuilderGetMemory, p == 1 ? storage : NULL);
        VALUE(nvnMemoryPoolBuilderGetSize, p == 1 ? sizeof storage : 0);
        VALUE(nvnMemoryPoolBuilderGetFlags, p == 1 ? 0x12 : 0x21);
        BOUNDARY(box);
    }
}
static void buffer_builder(void) {
    OBJECT(NVNbufferBuilder, box); NVNbufferBuilder *b = &box.obj;
    API(nvnBufferBuilderSetDevice)(b, &device);
    for (int p = 0; p < 3; p++) {
        phase = phases[p];
        if (p == 1) API(nvnBufferBuilderSetStorage)(b, &pool, 48, 192);
        else API(nvnBufferBuilderSetDefaults)(b);
        VALUE(nvnBufferBuilderGetDevice, &device);
        VALUE(nvnBufferBuilderGetMemoryPool, p == 1 ? &pool : NULL);
        VALUE(nvnBufferBuilderGetMemoryOffset, p == 1 ? 48 : 0);
        VALUE(nvnBufferBuilderGetSize, p == 1 ? 192 : 0);
        BOUNDARY(box);
    }
}
static void texture_builder(void) {
    OBJECT(NVNtextureBuilder, box); NVNtextureBuilder *b = &box.obj;
    API(nvnTextureBuilderSetDevice)(b, &device);
    const NVNpackagedTextureLayout layout = {{ 2, 7, 3, 9, 11, 13, 17, 19 }};
    for (int p = 0; p < 3; p++) {
        phase = phases[p];
        if (p == 1) {
            API(nvnTextureBuilderSetFlags)(b, 0x10);
            API(nvnTextureBuilderSetTarget)(b, NVN_TEXTURE_TARGET_2D_ARRAY);
            API(nvnTextureBuilderSetSize3D)(b, 32, 16, 4);
            API(nvnTextureBuilderSetLevels)(b, 3);
            API(nvnTextureBuilderSetFormat)(b, NVN_FORMAT_RGBA8);
            API(nvnTextureBuilderSetSamples)(b, 4);
            API(nvnTextureBuilderSetStride)(b, 256);
            API(nvnTextureBuilderSetStorage)(b, &pool, 96);
            API(nvnTextureBuilderSetPackagedTextureData)(b, storage);
            API(nvnTextureBuilderSetPackagedTextureLayout)(b, &layout);
            API(nvnTextureBuilderSetSwizzle)(b, NVN_TEXTURE_SWIZZLE_B, NVN_TEXTURE_SWIZZLE_ONE,
                                           NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_ZERO);
            API(nvnTextureBuilderSetDepthStencilMode)(b, NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL);
        } else API(nvnTextureBuilderSetDefaults)(b);
        VALUE(nvnTextureBuilderGetDevice, &device);
        VALUE(nvnTextureBuilderGetFlags, p == 1 ? 0x10 : 0);
        VALUE(nvnTextureBuilderGetTarget, p == 1 ? NVN_TEXTURE_TARGET_2D_ARRAY : NVN_TEXTURE_TARGET_2D);
        VALUE(nvnTextureBuilderGetWidth, p == 1 ? 32 : 0);
        VALUE(nvnTextureBuilderGetHeight, p == 1 ? 16 : 0);
        VALUE(nvnTextureBuilderGetDepth, p == 1 ? 4 : 0);
        VALUE(nvnTextureBuilderGetLevels, p == 1 ? 3 : 1);
        VALUE(nvnTextureBuilderGetFormat, p == 1 ? NVN_FORMAT_RGBA8 : NVN_FORMAT_NONE);
        VALUE(nvnTextureBuilderGetSamples, p == 1 ? 4 : 0);
        VALUE(nvnTextureBuilderGetStride, p == 1 ? 256 : 0);
        VALUE(nvnTextureBuilderGetMemoryPool, p == 1 ? &pool : NULL);
        VALUE(nvnTextureBuilderGetMemoryOffset, p == 1 ? 96 : 0);
        VALUE(nvnTextureBuilderGetPackagedTextureData, p == 1 ? storage : NULL);
        VALUE(nvnTextureBuilderGetDepthStencilMode, p == 1 ? NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL : NVN_TEXTURE_DEPTH_STENCIL_MODE_DEPTH);
        CASE(nvnTextureBuilderGetSwizzle) {
            NVNtextureSwizzle r, g, bl, a;
            API(nvnTextureBuilderGetSwizzle)(b, &r, &g, &bl, &a);
            CHECK(r == (p == 1 ? NVN_TEXTURE_SWIZZLE_B : NVN_TEXTURE_SWIZZLE_R));
            CHECK(g == (p == 1 ? NVN_TEXTURE_SWIZZLE_ONE : NVN_TEXTURE_SWIZZLE_G));
            CHECK(bl == (p == 1 ? NVN_TEXTURE_SWIZZLE_R : NVN_TEXTURE_SWIZZLE_B));
            CHECK(a == (p == 1 ? NVN_TEXTURE_SWIZZLE_ZERO : NVN_TEXTURE_SWIZZLE_A));
        }
        CASE(nvnTextureBuilderGetPackagedTextureLayout) {
            struct { uint64_t pre; NVNpackagedTextureLayout value; uint64_t post; } out = {GUARD, {{0}}, GUARD};
            memset(&out.value, 0xa7, sizeof out.value);
            CHECK(API(nvnTextureBuilderGetPackagedTextureLayout)(b, &out.value) == (p == 1));
            uint32_t input, output; memcpy(&input, &layout, 4); memcpy(&output, &out.value, 4);
            CHECK(output == (p == 1 ? input & 0xfffu : 0));
            for (size_t i = 4; i < sizeof out.value; i++) CHECK(((unsigned char *)&out.value)[i] == 0xa7);
            CHECK(out.pre == GUARD && out.post == GUARD);
        }
        BOUNDARY(box);
    }
    phase = "格式与线性标志";
    CASE(nvnTextureBuilderGetRawStorageClass) {
        const int formats[] = {0, 49, 50, 51, 53, 54, NVN_FORMAT_RGBA8};
        const uint32_t classes[] = {0, 3, 3, 4, 4, 5, 2};
        for (unsigned i = 0; i < sizeof formats / sizeof *formats; i++) {
            API(nvnTextureBuilderSetFlags)(b, 0);
            API(nvnTextureBuilderSetFormat)(b, (NVNformat)formats[i]);
            CHECK(API(nvnTextureBuilderGetRawStorageClass)(b) == classes[i]);
            API(nvnTextureBuilderSetFlags)(b, 0x10);
            CHECK(API(nvnTextureBuilderGetRawStorageClass)(b) == 1);
            API(nvnTextureBuilderSetFlags)(b, 0x40);
            CHECK(API(nvnTextureBuilderGetRawStorageClass)(b) == 1);
        }
    }
    BOUNDARY(box);
}
static void texture_layout_queries(void) {
    OBJECT(NVNtextureBuilder, box); NVNtextureBuilder *b = &box.obj;
    phase = "SDK 稀疏页尺寸与 mip 尾部";
    CASE(nvnTextureBuilderGetSparseTileLayout) {
        // SDK 的页为 64 KiB。以下常量由格式块大小、采样数和 mip 尺寸手算，
        // 不调用生产布局函数生成期望。
        const struct {
            NVNtextureTarget target; NVNformat format;
            int w, h, d, levels, samples, flags;
            uint32_t count, tw, th, td;
        } rows[] = {
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 256, 256, 1, 1, 0, 0x20, 1, 128, 128, 1},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 256, 256, 1, 9, 0, 0x20, 2, 128, 128, 1},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 128, 128, 1, 8, 0, 0x20, 1, 128, 128, 1},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 127, 128, 1, 8, 0, 0x20, 0, 0, 0, 0},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_ASTC_4x4, 512, 512, 1, 1, 0, 0x20, 1, 256, 256, 1},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_ASTC_6x6, 768, 768, 1, 10, 0, 0x20, 2, 384, 384, 1},
            {NVN_TEXTURE_TARGET_3D, NVN_FORMAT_RGBA8, 64, 64, 32, 4, 0, 0x20, 2, 32, 32, 16},
            {NVN_TEXTURE_TARGET_2D_MULTISAMPLE, NVN_FORMAT_RGBA8, 128, 128, 1, 1, 4, 0x20, 1, 64, 64, 1},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 256, 256, 1, 1, 0, 0, 0, 0, 0, 0},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 256, 256, 1, 1, 0, 0x30, 0, 0, 0, 0},
            {NVN_TEXTURE_TARGET_1D, NVN_FORMAT_RGBA8, 256, 1, 1, 1, 0, 0x20, 0, 0, 0, 0},
            {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGB32F, 256, 256, 1, 1, 0, 0x20, 0, 0, 0, 0},
        };
        for (unsigned i = 0; i < sizeof rows / sizeof *rows; i++) {
            printf("  稀疏布局用例 %u\n", i); fflush(stdout);
            API(nvnTextureBuilderSetDefaults)(b);
            API(nvnTextureBuilderSetTarget)(b, rows[i].target);
            API(nvnTextureBuilderSetFormat)(b, rows[i].format);
            API(nvnTextureBuilderSetSize3D)(b, rows[i].w, rows[i].h, rows[i].d);
            API(nvnTextureBuilderSetLevels)(b, rows[i].levels);
            API(nvnTextureBuilderSetSamples)(b, rows[i].samples);
            API(nvnTextureBuilderSetFlags)(b, rows[i].flags);
            struct { uint64_t pre; NVNtextureSparseTileLayout value; uint64_t post; } out;
            memset(&out, 0xa7, sizeof out); out.pre = out.post = GUARD;
            API(nvnTextureBuilderGetSparseTileLayout)(b, &out.value);
            CHECK(out.value.numTiledLevels == rows[i].count);
            CHECK(out.value.tileWidth == rows[i].tw);
            CHECK(out.value.tileHeight == rows[i].th);
            CHECK(out.value.tileDepth == rows[i].td);
            CHECK(out.pre == GUARD && out.post == GUARD);
            BOUNDARY(box);
        }
    }
    phase = "SDK view 层单位与 mip 前缀";
    CASE(nvnTextureBuilderGetViewOffset) {
        OBJECT(NVNtextureView, view_box); NVNtextureView *v = &view_box.obj;
        API(nvnTextureBuilderSetDefaults)(b);
        API(nvnTextureBuilderSetFormat)(b, NVN_FORMAT_RGBA8);
        API(nvnTextureBuilderSetSize3D)(b, 32, 32, 1);
        API(nvnTextureBuilderSetLevels)(b, 3);
        API(nvnTextureViewSetDefaults)(v);
        CHECK(API(nvnTextureBuilderGetViewOffset)(b, v) == 0);
        API(nvnTextureViewSetLevels)(v, 1, 1);
        // 32*32*4 = 4096，恰好整页，level 1 起点为 4096。
        CHECK(API(nvnTextureBuilderGetViewOffset)(b, v) == 4096);
        API(nvnTextureBuilderSetTarget)(b, NVN_TEXTURE_TARGET_2D_ARRAY);
        API(nvnTextureBuilderSetDepth)(b, 4);
        API(nvnTextureBuilderSetLevels)(b, 1);
        API(nvnTextureViewSetDefaults)(v);
        API(nvnTextureViewSetLayers)(v, 2, 1);
        // 两个完整、每层 4096 字节的二维层。
        CHECK(API(nvnTextureBuilderGetViewOffset)(b, v) == 8192);
        API(nvnTextureBuilderSetTarget)(b, NVN_TEXTURE_TARGET_CUBEMAP_ARRAY);
        API(nvnTextureBuilderSetDepth)(b, 2);
        API(nvnTextureViewSetLayers)(v, 1, 1);
        API(nvnTextureViewSetTarget)(v, NVN_TEXTURE_TARGET_CUBEMAP_ARRAY);
        // Cube-array view 的 layer 单位为六个面；2D-array view 为一个面。
        CHECK(API(nvnTextureBuilderGetViewOffset)(b, v) == 6 * 4096);
        API(nvnTextureViewSetTarget)(v, NVN_TEXTURE_TARGET_2D_ARRAY);
        CHECK(API(nvnTextureBuilderGetViewOffset)(b, v) == 4096);
        BOUNDARY(view_box); BOUNDARY(box);
    }
}
static void set_view_field(NVNtextureView *v, int field, int variant) {
    switch (field) {
    case 0: API(nvnTextureViewSetLevels)(v, variant == 1 ? 3 : 2, variant == 2 ? 4 : 3); break;
    case 1: API(nvnTextureViewSetLayers)(v, variant == 1 ? 556 : 300, variant == 2 ? 856 : 600); break;
    case 2: API(nvnTextureViewSetFormat)(v, variant ? NVN_FORMAT_RGBA16F : NVN_FORMAT_RGBA8); break;
    case 3: API(nvnTextureViewSetSwizzle)(v,
                variant == 1 ? NVN_TEXTURE_SWIZZLE_ZERO : NVN_TEXTURE_SWIZZLE_R,
                variant == 2 ? NVN_TEXTURE_SWIZZLE_ZERO : NVN_TEXTURE_SWIZZLE_G,
                variant == 3 ? NVN_TEXTURE_SWIZZLE_ZERO : NVN_TEXTURE_SWIZZLE_B,
                variant == 4 ? NVN_TEXTURE_SWIZZLE_ONE : NVN_TEXTURE_SWIZZLE_A); break;
    case 4: API(nvnTextureViewSetDepthStencilMode)(v, variant ? NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL : NVN_TEXTURE_DEPTH_STENCIL_MODE_DEPTH); break;
    case 5: API(nvnTextureViewSetTarget)(v, variant ? NVN_TEXTURE_TARGET_CUBEMAP_ARRAY : NVN_TEXTURE_TARGET_2D_ARRAY); break;
    }
}
static void compare_views(const NVNtextureView *a, const NVNtextureView *b, NVNboolean expected) {
    CHECK(API(nvnTextureViewCompare)(a, b) == expected);
    CHECK(API(nvnTextureViewCompare)(b, a) == expected);
    CHECK(API(nvnTextureViewCompare)(a, a) == 1);
    CHECK(API(nvnTextureViewCompare)(b, b) == 1);
}
static void texture_view_compare(void) {
    phase = "16 字节视图默认与自比较";
    CASE(nvnTextureViewCompare) {
        // 真实较新 SDK 只给 16 字节；不使用旧头文件的 40 字节预留区。
        typedef struct { uint64_t words[2]; } view_storage;
        _Static_assert(sizeof(view_storage) == 16, "TextureView SDK object size");
        typedef struct { uint64_t pre[2]; view_storage obj; uint64_t post[3]; } view_box;
        view_box first = {{GUARD, GUARD}, {{0}}, {GUARD, GUARD, GUARD}};
        view_box second = {{~GUARD, ~GUARD}, {{0}}, {~GUARD, ~GUARD, ~GUARD}};
        NVNtextureView *a = (NVNtextureView *)(void *)&first.obj;
        NVNtextureView *b = (NVNtextureView *)(void *)&second.obj;
#define VIEW_PAIR(expected) do { \
            view_box before_a = first, before_b = second; \
            compare_views(a, b, expected); \
            CHECK(!memcmp(&first, &before_a, sizeof first)); \
            CHECK(!memcmp(&second, &before_b, sizeof second)); \
            CHECK(first.pre[0] == GUARD && first.pre[1] == GUARD && \
                  first.post[0] == GUARD && first.post[1] == GUARD && first.post[2] == GUARD); \
            CHECK(second.pre[0] == ~GUARD && second.pre[1] == ~GUARD && \
                  second.post[0] == ~GUARD && second.post[1] == ~GUARD && second.post[2] == ~GUARD); \
        } while (0)
        API(nvnTextureViewSetDefaults)(a); API(nvnTextureViewSetDefaults)(b);
        VIEW_PAIR(1);
        const char *fields[] = { "levels", "layers", "format", "identity swizzle", "DEPTH", "target" };
        const int variants[] = {2, 2, 1, 4, 1, 1};
        for (int field = 0; field < 6; field++) {
            phase = fields[field];
            API(nvnTextureViewSetDefaults)(a); API(nvnTextureViewSetDefaults)(b);
            set_view_field(a, field, 0);
            VIEW_PAIR(0);
            set_view_field(b, field, 0);
            VIEW_PAIR(1);
            for (int variant = 1; variant <= variants[field]; variant++) {
                printf("  %s 分量 %d\n", phase, variant); fflush(stdout);
                set_view_field(b, field, variant);
                VIEW_PAIR(0);
            }
        }
        phase = "六字段设置顺序无关";
        API(nvnTextureViewSetDefaults)(a); API(nvnTextureViewSetDefaults)(b);
        for (int field = 0; field < 6; field++) set_view_field(a, field, 0);
        for (int field = 5; field >= 0; field--) set_view_field(b, field, 0);
        VIEW_PAIR(1);
        phase = "SetDefaults 清除全部显式设置";
        API(nvnTextureViewSetDefaults)(a);
        VIEW_PAIR(0);
        API(nvnTextureViewSetDefaults)(b);
        VIEW_PAIR(1);
#undef VIEW_PAIR
    }
}
static void sampler_builder(void) {
    OBJECT(NVNsamplerBuilder, box); NVNsamplerBuilder *b = &box.obj;
    API(nvnSamplerBuilderSetDevice)(b, &device);
    const float color[] = {0.25f, 0.5f, 0.75f, 1.0f};
    for (int p = 0; p < 3; p++) {
        phase = phases[p];
        if (p == 1) {
            API(nvnSamplerBuilderSetMinMagFilter)(b, NVN_MIN_FILTER_NEAREST, NVN_MAG_FILTER_NEAREST);
            API(nvnSamplerBuilderSetWrapMode)(b, NVN_WRAP_MODE_CLAMP_TO_EDGE, NVN_WRAP_MODE_MIRRORED_REPEAT, NVN_WRAP_MODE_CLAMP_TO_BORDER);
            API(nvnSamplerBuilderSetLodClamp)(b, 2.5f, 9.5f);
            API(nvnSamplerBuilderSetLodBias)(b, -1.5f);
            API(nvnSamplerBuilderSetCompare)(b, NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE, NVN_COMPARE_FUNC_GREATER);
            API(nvnSamplerBuilderSetBorderColor)(b, color);
            API(nvnSamplerBuilderSetMaxAnisotropy)(b, 8.0f);
            API(nvnSamplerBuilderSetReductionFilter)(b, NVN_SAMPLER_REDUCTION_MIN);
            API(nvnSamplerBuilderSetLodSnap)(b, 0.25f);
        } else API(nvnSamplerBuilderSetDefaults)(b);
        VALUE(nvnSamplerBuilderGetDevice, &device);
        VALUE(nvnSamplerBuilderGetLodBias, p == 1 ? -1.5f : 0.0f);
        VALUE(nvnSamplerBuilderGetMaxAnisotropy, p == 1 ? 8.0f : 1.0f);
        VALUE(nvnSamplerBuilderGetReductionFilter, p == 1 ? NVN_SAMPLER_REDUCTION_MIN : NVN_SAMPLER_REDUCTION_AVERAGE);
        VALUE(nvnSamplerBuilderGetLodSnap, p == 1 ? 0.25f : 0.0f);
        CASE(nvnSamplerBuilderGetMinMagFilter) {
            NVNminFilter mi; NVNmagFilter ma; API(nvnSamplerBuilderGetMinMagFilter)(b, &mi, &ma);
            CHECK(mi == (p == 1 ? NVN_MIN_FILTER_NEAREST : NVN_MIN_FILTER_LINEAR));
            CHECK(ma == (p == 1 ? NVN_MAG_FILTER_NEAREST : NVN_MAG_FILTER_LINEAR));
        }
        CASE(nvnSamplerBuilderGetWrapMode) {
            NVNwrapMode s, t, r; API(nvnSamplerBuilderGetWrapMode)(b, &s, &t, &r);
            CHECK(s == (p == 1 ? NVN_WRAP_MODE_CLAMP_TO_EDGE : NVN_WRAP_MODE_REPEAT));
            CHECK(t == (p == 1 ? NVN_WRAP_MODE_MIRRORED_REPEAT : NVN_WRAP_MODE_REPEAT));
            CHECK(r == (p == 1 ? NVN_WRAP_MODE_CLAMP_TO_BORDER : NVN_WRAP_MODE_REPEAT));
        }
        CASE(nvnSamplerBuilderGetLodClamp) {
            float lo, hi; API(nvnSamplerBuilderGetLodClamp)(b, &lo, &hi);
            CHECK(lo == (p == 1 ? 2.5f : 0.0f)); CHECK(hi == (p == 1 ? 9.5f : 1000.0f));
        }
        CASE(nvnSamplerBuilderGetCompare) {
            NVNcompareMode mode; NVNcompareFunc fn; API(nvnSamplerBuilderGetCompare)(b, &mode, &fn);
            CHECK(mode == (p == 1 ? NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE : NVN_COMPARE_MODE_NONE));
            CHECK(fn == (p == 1 ? NVN_COMPARE_FUNC_GREATER : NVN_COMPARE_FUNC_LESS));
        }
        CASE(nvnSamplerBuilderGetBorderColor) {
            struct { uint64_t pre; float c[4]; uint64_t post; } out = {GUARD, {0}, GUARD};
            API(nvnSamplerBuilderGetBorderColor)(b, out.c);
            for (int i = 0; i < 4; i++) CHECK(out.c[i] == (p == 1 ? color[i] : 0.0f));
            CHECK(out.pre == GUARD && out.post == GUARD);
        }
        CASE(nvnSamplerBuilderGetBorderColori) {
            struct { uint64_t pre; int c[4]; uint64_t post; } out = {GUARD, {0}, GUARD};
            const float zero[4] = {0};
            API(nvnSamplerBuilderGetBorderColori)(b, out.c);
            CHECK(!memcmp(out.c, p == 1 ? color : zero, sizeof out.c));
            CHECK(out.pre == GUARD && out.post == GUARD);
        }
        CASE(nvnSamplerBuilderGetBorderColorui) {
            struct { uint64_t pre; uint32_t c[4]; uint64_t post; } out = {GUARD, {0}, GUARD};
            const float zero[4] = {0};
            API(nvnSamplerBuilderGetBorderColorui)(b, out.c);
            CHECK(!memcmp(out.c, p == 1 ? color : zero, sizeof out.c));
            CHECK(out.pre == GUARD && out.post == GUARD);
        }
        BOUNDARY(box);
    }
    phase = "LOD snap 保留到 sampler 对象";
    CASE(nvnSamplerCompare) {
        OBJECT(NVNsampler, first); OBJECT(NVNsampler, second);
        API(nvnSamplerBuilderSetDefaults)(b);
        CHECK(API(nvnSamplerInitialize)(&first.obj, b));
        API(nvnSamplerBuilderSetLodSnap)(b, 0.25f);
        CHECK(API(nvnSamplerInitialize)(&second.obj, b));
        CHECK(!API(nvnSamplerCompare)(&first.obj, &second.obj));
        API(nvnSamplerFinalize)(&first.obj); API(nvnSamplerFinalize)(&second.obj);
        BOUNDARY(first); BOUNDARY(second);
    }
    BOUNDARY(box);
}
static void queue_builder(void) {
    OBJECT(NVNqueueBuilder, box); NVNqueueBuilder *b = &box.obj;
    API(nvnQueueBuilderSetDevice)(b, &device);
    for (int p = 0; p < 4; p++) {
        phase = p == 3 ? "显式 Set(0)" : phases[p];
        if (p == 1 || p == 3) {
            API(nvnQueueBuilderSetFlags)(b, p == 1 ? 3 : 0);
            API(nvnQueueBuilderSetCommandMemorySize)(b, p == 1 ? 4096 : 0);
            API(nvnQueueBuilderSetComputeMemorySize)(b, p == 1 ? 8192 : 0);
            API(nvnQueueBuilderSetControlMemorySize)(b, p == 1 ? 12288 : 0);
            API(nvnQueueBuilderSetCommandFlushThreshold)(b, p == 1 ? 512 : 0);
            API(nvnQueueBuilderSetQueueMemory)(b, p == 1 ? storage : NULL, p == 1 ? sizeof storage : 0);
            API(nvnQueueBuilderSetQueuePriority)(b, p == 1 ? 37 : 100);
        } else API(nvnQueueBuilderSetDefaults)(b);
        VALUE(nvnQueueBuilderGetDevice, &device);
        VALUE(nvnQueueBuilderGetFlags, p == 1 ? 3 : 0);
        VALUE(nvnQueueBuilderGetMemory, p == 1 ? storage : NULL);
        VALUE(nvnQueueBuilderGetMemorySize, p == 1 ? (int)sizeof storage : 0);
        VALUE(nvnQueueBuilderGetQueuePriority, p == 1 ? 37 : 100);
#define QUEUE_SIZE(name, value) CASE(name) { \
            struct { uint32_t pre; int value_out; uint32_t post; } out = {0xa35cd17e, -1, 0x89ba7531}; \
            CHECK(API(name)(b, &out.value_out) == (p == 1 || p == 3)); \
            CHECK(out.value_out == (p == 1 ? value : 0)); \
            CHECK(out.pre == 0xa35cd17e && out.post == 0x89ba7531); \
        }
        QUEUE_SIZE(nvnQueueBuilderGetCommandMemorySize, 4096);
        QUEUE_SIZE(nvnQueueBuilderGetComputeMemorySize, 8192);
        QUEUE_SIZE(nvnQueueBuilderGetControlMemorySize, 12288);
        QUEUE_SIZE(nvnQueueBuilderGetCommandFlushThreshold, 512);
#undef QUEUE_SIZE
        BOUNDARY(box);
    }
}
static void window_builder(void) {
    OBJECT(NVNwindowBuilder, box); NVNwindowBuilder *b = &box.obj;
    NVNtexture textures[2] = {0}; NVNtexture *ptrs[] = {&textures[0], &textures[1]};
    API(nvnWindowBuilderSetDevice)(b, &device);
    for (int p = 0; p < 3; p++) {
        phase = phases[p];
        if (p == 1) {
            API(nvnWindowBuilderSetNativeWindow)(b, storage);
            API(nvnWindowBuilderSetPresentInterval)(b, 3);
            API(nvnWindowBuilderSetTextures)(b, 2, ptrs);
            API(nvnWindowBuilderSetNumActiveTextures)(b, 1);
        } else API(nvnWindowBuilderSetDefaults)(b);
        VALUE(nvnWindowBuilderGetDevice, &device);
        VALUE(nvnWindowBuilderGetNativeWindow, p == 1 ? storage : NULL);
        VALUE(nvnWindowBuilderGetPresentInterval, p == 1 ? 3 : 1);
        VALUE(nvnWindowBuilderGetNumTextures, p == 1 ? 2 : 0);
        VALUE(nvnWindowBuilderGetNumActiveTextures, p == 1 ? 1 : 0);
        CASE(nvnWindowBuilderGetTexture) {
            if (p == 1) { CHECK(API(nvnWindowBuilderGetTexture)(b, 0) == ptrs[0]); CHECK(API(nvnWindowBuilderGetTexture)(b, 1) == ptrs[1]); }
            CHECK(API(nvnWindowBuilderGetTexture)(b, p == 1 ? 2 : 0) == NULL);
        }
        BOUNDARY(box);
    }
}
static void event_builder(void) {
    OBJECT(NVNeventBuilder, box); NVNeventBuilder *b = &box.obj;
    for (int p = 0; p < 3; p++) {
        phase = phases[p];
        if (p == 1) API(nvnEventBuilderSetStorage)(b, &pool, 128);
        else API(nvnEventBuilderSetDefaults)(b);
        VALUE(nvnEventBuilderGetMemoryPool, p == 1 ? &pool : NULL);
        VALUE(nvnEventBuilderGetMemoryOffset, p == 1 ? 128 : 0);
        CASE(nvnEventBuilderGetStorage) {
            int64_t off = -1;
            CHECK(API(nvnEventBuilderGetStorage)(b, &off) == (p == 1 ? &pool : NULL));
            CHECK(off == (p == 1 ? 128 : 0));
        }
        BOUNDARY(box);
    }
}
int main(int argc, char **argv) {
    if (argc > 2) { fprintf(stderr, "用法：%s [完整查询函数名]\n", argv[0]); return 2; }
    filter = argc == 2 ? argv[1] : NULL;
    device_builder(); memory_pool_builder(); buffer_builder(); texture_builder(); texture_layout_queries();
    texture_view_compare(); sampler_builder(); queue_builder(); window_builder(); event_builder();
    if (!checks) { fprintf(stderr, "未找到查询：%s\n", filter); return 2; }
    printf("✓ t_nvn_a：%u 个真实 API 断言\n", checks);
    return 0;
}

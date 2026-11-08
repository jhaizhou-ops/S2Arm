// 第 3 块单测（以 Objective-C 编，后端源码静态编进来以便碰内部接口）：格式全表往返 / 16 位打包格式分量 / 深度模板转换 / 视图的视图 / 交换通道贴图当渲染目标 /
// 四种拷贝 / 拷进缓冲 / 贴图缓冲 / 采样器 / 贴图数组。期望值全部手算（不跑被测实现）。
// 缓冲：第 2 块（gal_buf.m）未合入，这里自带最小 gal_buf_mtl 桩（共享内存 MTLBuffer 表，强定义取代 gal_tex.m 的弱定义）。
// 采样类核对用 Metal 4 计算探针：在后端自己的队列 / 驻留集 / 参数表模型下读 smp 视图（同绑定处的用法）。
#import "../gal_internal.h"
#include "../gal_samp_caps.h"   // s2a_lodbias_native
#include "fixture.h"   // 固定 MSL 走离线 metallib 夹具（不是被测对象，不经运行时编译服务）
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
static void on_sig(int s) { void *b[32]; int n = backtrace(b, 32); backtrace_symbols_fd(b, n, 2); _exit(128 + s); }

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// ---------- GAL 格式表（名字 / 块宽 / 块高 / 每块字节；由 Ryujinx.Graphics.GAL/Format.cs 声明顺序 + 名字推出，不取自被测实现）----------
typedef struct { const char *name; int bw, bh, bpp; } fmt_ent;
static const fmt_ent k_fmts[148] = {
    {"R8Unorm", 1, 1, 1},
    {"R8Snorm", 1, 1, 1},
    {"R8Uint", 1, 1, 1},
    {"R8Sint", 1, 1, 1},
    {"R16Float", 1, 1, 2},
    {"R16Unorm", 1, 1, 2},
    {"R16Snorm", 1, 1, 2},
    {"R16Uint", 1, 1, 2},
    {"R16Sint", 1, 1, 2},
    {"R32Float", 1, 1, 4},
    {"R32Uint", 1, 1, 4},
    {"R32Sint", 1, 1, 4},
    {"R8G8Unorm", 1, 1, 2},
    {"R8G8Snorm", 1, 1, 2},
    {"R8G8Uint", 1, 1, 2},
    {"R8G8Sint", 1, 1, 2},
    {"R16G16Float", 1, 1, 4},
    {"R16G16Unorm", 1, 1, 4},
    {"R16G16Snorm", 1, 1, 4},
    {"R16G16Uint", 1, 1, 4},
    {"R16G16Sint", 1, 1, 4},
    {"R32G32Float", 1, 1, 8},
    {"R32G32Uint", 1, 1, 8},
    {"R32G32Sint", 1, 1, 8},
    {"R8G8B8Unorm", 1, 1, 3},
    {"R8G8B8Snorm", 1, 1, 3},
    {"R8G8B8Uint", 1, 1, 3},
    {"R8G8B8Sint", 1, 1, 3},
    {"R16G16B16Float", 1, 1, 6},
    {"R16G16B16Unorm", 1, 1, 6},
    {"R16G16B16Snorm", 1, 1, 6},
    {"R16G16B16Uint", 1, 1, 6},
    {"R16G16B16Sint", 1, 1, 6},
    {"R32G32B32Float", 1, 1, 12},
    {"R32G32B32Uint", 1, 1, 12},
    {"R32G32B32Sint", 1, 1, 12},
    {"R8G8B8A8Unorm", 1, 1, 4},
    {"R8G8B8A8Snorm", 1, 1, 4},
    {"R8G8B8A8Uint", 1, 1, 4},
    {"R8G8B8A8Sint", 1, 1, 4},
    {"R16G16B16A16Float", 1, 1, 8},
    {"R16G16B16A16Unorm", 1, 1, 8},
    {"R16G16B16A16Snorm", 1, 1, 8},
    {"R16G16B16A16Uint", 1, 1, 8},
    {"R16G16B16A16Sint", 1, 1, 8},
    {"R32G32B32A32Float", 1, 1, 16},
    {"R32G32B32A32Uint", 1, 1, 16},
    {"R32G32B32A32Sint", 1, 1, 16},
    {"S8Uint", 1, 1, 1},
    {"D16Unorm", 1, 1, 2},
    {"S8UintD24Unorm", 1, 1, 4},
    {"D32Float", 1, 1, 4},
    {"D24UnormS8Uint", 1, 1, 4},
    {"D32FloatS8Uint", 1, 1, 8},
    {"R8G8B8A8Srgb", 1, 1, 4},
    {"R4G4Unorm", 1, 1, 1},
    {"R4G4B4A4Unorm", 1, 1, 2},
    {"R5G5B5X1Unorm", 1, 1, 2},
    {"R5G5B5A1Unorm", 1, 1, 2},
    {"R5G6B5Unorm", 1, 1, 2},
    {"R10G10B10A2Unorm", 1, 1, 4},
    {"R10G10B10A2Uint", 1, 1, 4},
    {"R11G11B10Float", 1, 1, 4},
    {"R9G9B9E5Float", 1, 1, 4},
    {"Bc1RgbaUnorm", 4, 4, 8},
    {"Bc2Unorm", 4, 4, 16},
    {"Bc3Unorm", 4, 4, 16},
    {"Bc1RgbaSrgb", 4, 4, 8},
    {"Bc2Srgb", 4, 4, 16},
    {"Bc3Srgb", 4, 4, 16},
    {"Bc4Unorm", 4, 4, 8},
    {"Bc4Snorm", 4, 4, 8},
    {"Bc5Unorm", 4, 4, 16},
    {"Bc5Snorm", 4, 4, 16},
    {"Bc7Unorm", 4, 4, 16},
    {"Bc7Srgb", 4, 4, 16},
    {"Bc6HSfloat", 4, 4, 16},
    {"Bc6HUfloat", 4, 4, 16},
    {"Etc2RgbUnorm", 4, 4, 8},
    {"Etc2RgbaUnorm", 4, 4, 16},
    {"Etc2RgbPtaUnorm", 4, 4, 8},
    {"Etc2RgbSrgb", 4, 4, 8},
    {"Etc2RgbaSrgb", 4, 4, 16},
    {"Etc2RgbPtaSrgb", 4, 4, 8},
    {"R8Uscaled", 1, 1, 1},
    {"R8Sscaled", 1, 1, 1},
    {"R16Uscaled", 1, 1, 2},
    {"R16Sscaled", 1, 1, 2},
    {"R32Uscaled", 1, 1, 4},
    {"R32Sscaled", 1, 1, 4},
    {"R8G8Uscaled", 1, 1, 2},
    {"R8G8Sscaled", 1, 1, 2},
    {"R16G16Uscaled", 1, 1, 4},
    {"R16G16Sscaled", 1, 1, 4},
    {"R32G32Uscaled", 1, 1, 8},
    {"R32G32Sscaled", 1, 1, 8},
    {"R8G8B8Uscaled", 1, 1, 3},
    {"R8G8B8Sscaled", 1, 1, 3},
    {"R16G16B16Uscaled", 1, 1, 6},
    {"R16G16B16Sscaled", 1, 1, 6},
    {"R32G32B32Uscaled", 1, 1, 12},
    {"R32G32B32Sscaled", 1, 1, 12},
    {"R8G8B8A8Uscaled", 1, 1, 4},
    {"R8G8B8A8Sscaled", 1, 1, 4},
    {"R16G16B16A16Uscaled", 1, 1, 8},
    {"R16G16B16A16Sscaled", 1, 1, 8},
    {"R32G32B32A32Uscaled", 1, 1, 16},
    {"R32G32B32A32Sscaled", 1, 1, 16},
    {"R10G10B10A2Snorm", 1, 1, 4},
    {"R10G10B10A2Sint", 1, 1, 4},
    {"R10G10B10A2Uscaled", 1, 1, 4},
    {"R10G10B10A2Sscaled", 1, 1, 4},
    {"Astc4x4Unorm", 4, 4, 16},
    {"Astc5x4Unorm", 5, 4, 16},
    {"Astc5x5Unorm", 5, 5, 16},
    {"Astc6x5Unorm", 6, 5, 16},
    {"Astc6x6Unorm", 6, 6, 16},
    {"Astc8x5Unorm", 8, 5, 16},
    {"Astc8x6Unorm", 8, 6, 16},
    {"Astc8x8Unorm", 8, 8, 16},
    {"Astc10x5Unorm", 10, 5, 16},
    {"Astc10x6Unorm", 10, 6, 16},
    {"Astc10x8Unorm", 10, 8, 16},
    {"Astc10x10Unorm", 10, 10, 16},
    {"Astc12x10Unorm", 12, 10, 16},
    {"Astc12x12Unorm", 12, 12, 16},
    {"Astc4x4Srgb", 4, 4, 16},
    {"Astc5x4Srgb", 5, 4, 16},
    {"Astc5x5Srgb", 5, 5, 16},
    {"Astc6x5Srgb", 6, 5, 16},
    {"Astc6x6Srgb", 6, 6, 16},
    {"Astc8x5Srgb", 8, 5, 16},
    {"Astc8x6Srgb", 8, 6, 16},
    {"Astc8x8Srgb", 8, 8, 16},
    {"Astc10x5Srgb", 10, 5, 16},
    {"Astc10x6Srgb", 10, 6, 16},
    {"Astc10x8Srgb", 10, 8, 16},
    {"Astc10x10Srgb", 10, 10, 16},
    {"Astc12x10Srgb", 12, 10, 16},
    {"Astc12x12Srgb", 12, 12, 16},
    {"B5G6R5Unorm", 1, 1, 2},
    {"B5G5R5A1Unorm", 1, 1, 2},
    {"A1B5G5R5Unorm", 1, 1, 2},
    {"B8G8R8A8Unorm", 1, 1, 4},
    {"B8G8R8A8Srgb", 1, 1, 4},
    {"B10G10R10A2Unorm", 1, 1, 4},
    {"X8UintD24Unorm", 1, 1, 4},
    {"A8B8G8R8Uint", 1, 1, 4},
};
static int fidx(const char *n) { for (int i = 0; i < 148; i++) if (!strcmp(k_fmts[i].name, n)) return i; printf("格式名 %s 不存在\n", n); exit(2); }

// ---------- 缓冲桩 ----------
// 第 2 块已合入：用真缓冲；bm() 取底层 MTLBuffer（普通缓冲偏移 0、共享内存，可直接读写内容）
static id<MTLBuffer> bm(uint32_t b) { uint64_t o; return gal_buf_mtl(b, 0, &o); }
static uint32_t buf_new(int size, uint8_t fill) {
    uint32_t b = nxgal_buf_create(size, 0); memset(bm(b).contents, fill, size); return b;
}

// ---------- 探针 ----------
static NSString *const k_probe = @
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void p_read(texture2d<float> t [[texture(0)]], device float4 *o [[buffer(0)]]) { o[0] = t.read(uint2(0, 0)); }\n"
"kernel void p_readu(texture2d<uint> t [[texture(0)]], device uint4 *o [[buffer(0)]]) { o[0] = t.read(uint2(0, 0)); }\n"
"kernel void p_sample(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float4 *o [[buffer(0)]], constant float4 &uv [[buffer(1)]]) { o[0] = t.sample(s, uv.xy, level(uv.z)); }\n"
"kernel void p_cmp(depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float4 *o [[buffer(0)]], constant float4 &uv [[buffer(1)]]) { o[0] = float4(t.sample_compare(s, uv.xy, uv.w, level(0))); }\n"
"kernel void p_tbuf(texture_buffer<uint> t [[texture(0)]], device uint4 *o [[buffer(0)]]) { for (uint i = 0; i < 4; i++) o[i] = t.read(i); }\n";
static id<MTLLibrary> g_plib; static id<MTL4ArgumentTable> g_ptab;
static void probe(NSString *fn, id<MTLTexture> t, id<MTLSamplerState> s, const float uv[4], void *out, size_t len) {
    NSError *e = nil;
    if (!g_plib) {
        g_plib = fx_lib(g_gdev, @"t_tex_probe", k_probe, &e); if (!g_plib) { printf("探针编译失败：%s\n", e.localizedDescription.UTF8String); exit(2); }
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2; ad.maxTextureBindCount = 1; ad.maxSamplerStateBindCount = 1;
        g_ptab = [g_gdev newArgumentTableWithDescriptor:ad error:&e];
    }
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = g_plib; f.name = fn; pd.computeFunctionDescriptor = f;
    id<MTLComputePipelineState> p = [g_gcomp newComputePipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&e];
    if (!p) { printf("探针管线失败：%s\n", e.localizedDescription.UTF8String); exit(2); }
    id<MTLBuffer> ob = [g_gdev newBufferWithLength:64 options:MTLResourceStorageModeShared]; memset(ob.contents, 0xcd, 64); gal_res_add(ob);
    uint64_t gpu = 0; float *u = gal_transient(16, 16, &gpu); if (uv) memcpy(u, uv, 16); else memset(u, 0, 16);
    [g_ptab setTexture:t.gpuResourceID atIndex:0]; if (s) [g_ptab setSamplerState:s.gpuResourceID atIndex:0];
    [g_ptab setAddress:ob.gpuAddress atIndex:0]; [g_ptab setAddress:gpu atIndex:1];
    id<MTL4ComputeCommandEncoder> enc = gal_blit_enc();
    [enc setArgumentTable:g_ptab]; [enc setComputePipelineState:p];
    [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    gal_finish(); memcpy(out, ob.contents, len); gal_res_remove(ob);
}
// 深度模板两平面直读（不经 GetData 的转换）：核转换语义本身
static void read_planes(uint32_t tid, int n, float *dep, uint8_t *st) {
    gal_tex *t = gal_tex_get(tid);
    id<MTLBuffer> b = [g_gdev newBufferWithLength:n * 5 + 16 options:MTLResourceStorageModeShared]; gal_res_add(b);
    MTLSize sz = MTLSizeMake(t->info.width, t->info.height, 1);
    [gal_blit_enc() copyFromTexture:t->root sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:sz toBuffer:b destinationOffset:0
            destinationBytesPerRow:t->info.width * 4 destinationBytesPerImage:n * 4 options:MTLBlitOptionDepthFromDepthStencil];
    [gal_blit_enc() copyFromTexture:t->root sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:sz toBuffer:b destinationOffset:n * 4
            destinationBytesPerRow:t->info.width destinationBytesPerImage:n options:MTLBlitOptionStencilFromDepthStencil];
    gal_finish(); memcpy(dep, b.contents, n * 4); memcpy(st, (uint8_t *)b.contents + n * 4, n); gal_res_remove(b);
}

static nxgal_tex_info tinfo(int w, int h, int depth, int levels, int samples, int fmt, int target) {
    nxgal_tex_info i = {w, h, depth, levels, samples, k_fmts[fmt].bw, k_fmts[fmt].bh, k_fmts[fmt].bpp, fmt, 0, target, {2, 3, 4, 5}};
    return i;
}
static float bitsf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static int feq(float a, float b, float tol) { return fabsf(a - b) <= tol; }

// ===== 1 格式全表：建 → SetData 已知字节 → GetData 逐字节比 =====
static void t_formats(void) {
    printf("· 格式全表：148 个 GAL 格式里有 Metal 映射的逐个建 → 写已知字节 → 读回逐字节比\n");
    int mapped = 0, ok = 0; char unmapped[2048] = "", failed[2048] = "";
    for (int f = 0; f < 148; f++) {
        const fmt_ent *e = &k_fmts[f];
        if (gal_fmt_mtl(f) == MTLPixelFormatInvalid) { strcat(unmapped, e->name); strcat(unmapped, " "); continue; }
        mapped++;
        int compressed = e->bw > 1 || e->bh > 1;
        int w = compressed ? e->bw * 2 : 4, h = compressed ? e->bh * 2 : 4;
        nxgal_tex_info i = tinfo(w, h, 1, 1, 1, f, 1);
        uint32_t t = nxgal_tex_create(&i);
        if (!t) { strcat(failed, e->name); strcat(failed, "(建不出) "); continue; }
        int stride = ((w / e->bw) * e->bpp + 3) & ~3, rows = h / e->bh, n = stride * rows;
        uint8_t src[1024], dst[1024]; int px = (w / e->bw) * rows;
        for (int k = 0; k < n; k++) src[k] = (uint8_t)(k * 37 + 11);
        // 深度格式只能放合法值：D32Float 放 [0,1]；D24S8 三种 / D32FloatS8Uint 放 d24 + 模板（X8 低 8 位只能是 0，D32FS8 模板高 24 位为 0）
        const char *nm = e->name;
        if (!strcmp(nm, "D32Float")) for (int k = 0; k < px; k++) { float v = (float)k / 16.0f; memcpy(src + k * 4, &v, 4); }
        if (!strcmp(nm, "D24UnormS8Uint") || !strcmp(nm, "S8UintD24Unorm")) for (int k = 0; k < px; k++) { uint32_t v = (uint32_t)(k * 0x0102035u + 0x77) ; memcpy(src + k * 4, &v, 4); }
        if (!strcmp(nm, "X8UintD24Unorm")) for (int k = 0; k < px; k++) { uint32_t v = ((uint32_t)(k * 0x010203u + 5) & 0xffffff) << 8; memcpy(src + k * 4, &v, 4); }
        if (!strcmp(nm, "D32FloatS8Uint")) for (int k = 0; k < px; k++) { float v = (float)k / 16.0f; uint32_t s = (uint32_t)(k * 13 + 1) & 0xff; memcpy(src + k * 8, &v, 4); memcpy(src + k * 8 + 4, &s, 4); }
        nxgal_tex_set_data(t, -1, -1, NULL, src, n);
        memset(dst, 0, sizeof dst);
        uint64_t got = nxgal_tex_get_data(t, -1, -1, dst, sizeof dst);
        int bad = -1; for (int k = 0; k < n; k++) if (src[k] != dst[k]) { bad = k; break; }
        if (got != (uint64_t)n || bad >= 0) { char tmp[128]; snprintf(tmp, sizeof tmp, "%s(字节%d 期望%u 实得%u) ", nm, bad, bad >= 0 ? src[bad] : 0, bad >= 0 ? dst[bad] : 0); strcat(failed, tmp); }
        else ok++;
        nxgal_tex_release(t);
    }
    printf("  有映射 %d 个，往返全对 %d 个\n  未映射：%s\n", mapped, ok, unmapped);
    CHECK(ok == mapped, "往返不符 / 建不出：%s", failed);
}

// ===== 2 16 位打包格式分量（按 Vulkan 后端语义手算）=====
static void t_packed(void) {
    printf("· 16 位打包格式：写一个已知 16 位值 → 采样视图读 (r,g,b,a)，与 Vulkan 后端语义比\n");
    struct { const char *f; uint16_t v; float e[4]; int swz[4]; } cs[] = {
        {"R5G6B5Unorm", 0x001F, {1, 0, 0, 1}, {2, 3, 4, 5}},   // R 在 0–4 位（Vulkan R5G6B5Pack16 + R↔B）
        {"R5G6B5Unorm", 0xF800, {0, 0, 1, 1}, {2, 3, 4, 5}},
        {"B5G6R5Unorm", 0x001F, {0, 0, 1, 1}, {2, 3, 4, 5}},   // B 在 0–4 位
        {"R5G5B5A1Unorm", 0x801F, {1, 0, 0, 1}, {2, 3, 4, 5}}, // R 0–4、A 15
        {"R5G5B5A1Unorm", 0x7C00, {0, 0, 1, 0}, {2, 3, 4, 5}},
        {"R5G5B5X1Unorm", 0x7C00, {0, 0, 1, 1}, {2, 3, 4, 5}}, // X1：alpha 恒 1
        {"B5G5R5A1Unorm", 0x001F, {0, 0, 1, 0}, {2, 3, 4, 5}},
        {"A1B5G5R5Unorm", 0x0001, {1, 0, 0, 0}, {2, 3, 4, 5}}, // Vulkan R5G5B5A1Pack16 + 旋转：r = 第 0 位
        {"A1B5G5R5Unorm", 0x003E, {0, 1, 0, 0}, {2, 3, 4, 5}},
        {"A1B5G5R5Unorm", 0xF800, {0, 0, 0, 1}, {2, 3, 4, 5}},
        {"R4G4B4A4Unorm", 0x000F, {1, 0, 0, 0}, {2, 3, 4, 5}}, // Vulkan A4B4G4R4Pack16：R 在 0–3 位
        {"R4G4B4A4Unorm", 0x00F0, {0, 1, 0, 0}, {2, 3, 4, 5}},
        {"R4G4B4A4Unorm", 0xF000, {0, 0, 0, 1}, {2, 3, 4, 5}},
        {"R5G6B5Unorm", 0x001F, {0, 1, 1, 0}, {4, 2, 1, 0}},   // 用户交换 (B,R,One,Zero) 按值映射：B=0 R=1
    };
    for (size_t k = 0; k < sizeof cs / sizeof cs[0]; k++) {
        int f = fidx(cs[k].f); nxgal_tex_info i = tinfo(4, 4, 1, 1, 1, f, 1); memcpy(i.swz, cs[k].swz, sizeof i.swz);
        uint32_t t = nxgal_tex_create(&i); CHECK(t, "%s 建不出", cs[k].f); if (!t) continue;
        uint16_t px[16]; for (int j = 0; j < 16; j++) px[j] = cs[k].v; nxgal_tex_set_data(t, -1, -1, NULL, px, sizeof px);
        float o[4]; probe(@"p_read", gal_tex_get(t)->smp, nil, NULL, o, sizeof o);
        CHECK(feq(o[0], cs[k].e[0], 1e-3f) && feq(o[1], cs[k].e[1], 1e-3f) && feq(o[2], cs[k].e[2], 1e-3f) && feq(o[3], cs[k].e[3], 1e-3f),
              "%s 0x%04x 交换 %d%d%d%d 期望 (%g,%g,%g,%g) 实得 (%g,%g,%g,%g)", cs[k].f, cs[k].v, cs[k].swz[0], cs[k].swz[1], cs[k].swz[2], cs[k].swz[3],
              cs[k].e[0], cs[k].e[1], cs[k].e[2], cs[k].e[3], o[0], o[1], o[2], o[3]);
        nxgal_tex_release(t);
    }
}

// ===== 3 深度模板转换 =====
static void t_ds(void) {
    printf("· 深度模板：D24S8 三种 / D32FloatS8Uint 写入 → 两平面直读核转换 → 读回往返；清屏后读回；模板采样视图\n");
    struct { const char *f; uint32_t w0, w1; float d0, d1; uint8_t s0, s1; } cs[] = {
        {"D24UnormS8Uint", 0xFFFFFF5Au, 0x80000001u, 1.0f, (float)(8388608.0 / 16777215.0), 0x5A, 0x01},   // v = d24<<8 | s
        {"S8UintD24Unorm", 0x5A123456u, 0x01FFFFFFu, (float)(1193046.0 / 16777215.0), 1.0f, 0x5A, 0x01},   // v = s<<24 | d24（OpenGL 后端）
        {"X8UintD24Unorm", 0x12345600u, 0x00000100u, (float)(1193046.0 / 16777215.0), (float)(1.0 / 16777215.0), 0, 0},   // v = d24<<8
    };
    for (int k = 0; k < 3; k++) {
        int f = fidx(cs[k].f); nxgal_tex_info i = tinfo(2, 1, 1, 1, 1, f, 1);
        uint32_t t = nxgal_tex_create(&i); uint32_t in[2] = {cs[k].w0, cs[k].w1}, out[2] = {0, 0};
        nxgal_tex_set_data(t, -1, -1, NULL, in, 8);
        float dep[2]; uint8_t st[2]; read_planes(t, 2, dep, st);
        CHECK(dep[0] == cs[k].d0 && dep[1] == cs[k].d1 && st[0] == cs[k].s0 && st[1] == cs[k].s1, "%s 平面 期望 d(%.9g,%.9g) s(%u,%u) 实得 d(%.9g,%.9g) s(%u,%u)",
              cs[k].f, cs[k].d0, cs[k].d1, cs[k].s0, cs[k].s1, dep[0], dep[1], st[0], st[1]);
        nxgal_tex_get_data(t, -1, -1, out, 8);
        CHECK(out[0] == in[0] && out[1] == in[1], "%s 往返 期望 %08x %08x 实得 %08x %08x", cs[k].f, in[0], in[1], out[0], out[1]);
        nxgal_tex_release(t);
    }
    {   // D32FloatS8Uint：8 字节 {float, uint32 模板}
        int f = fidx("D32FloatS8Uint"); nxgal_tex_info i = tinfo(1, 1, 1, 1, 1, f, 1);
        uint32_t t = nxgal_tex_create(&i); uint32_t in[2] = {0x3E800000u /*0.25*/, 0x77}, out[2];
        nxgal_tex_set_data(t, -1, -1, NULL, in, 8);
        float dep; uint8_t st; read_planes(t, 1, &dep, &st);
        CHECK(dep == 0.25f && st == 0x77, "D32FloatS8Uint 平面 期望 0.25 / 0x77 实得 %g / %#x", dep, st);
        nxgal_tex_get_data(t, -1, -1, out, 8); CHECK(out[0] == in[0] && out[1] == in[1], "D32FloatS8Uint 往返 实得 %08x %08x", out[0], out[1]);
        nxgal_tex_release(t);
    }
    {   // 清屏 0.5 / 0x33 后读回：d24 = round(0.5 × 16777215) = 8388608 → 0x80000033
        int f = fidx("D24UnormS8Uint"); nxgal_tex_info i = tinfo(4, 4, 1, 1, 1, f, 1);
        uint32_t t = nxgal_tex_create(&i);
        nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
        nxgal_set_render_targets(NULL, 0, t); nxgal_clear_ds(0, 1, 0.5f, 1, 0x33, 0xff); nxgal_set_render_targets(NULL, 0, 0);
        uint32_t out[16]; nxgal_tex_get_data(t, 0, 0, out, sizeof out);
        CHECK(out[0] == 0x80000033u && out[15] == 0x80000033u, "清屏后读回 期望 80000033 实得 %08x / %08x", out[0], out[15]);
        // 模板采样视图（ds_mode = 1）
        nxgal_tex_info vi = i; vi.ds_mode = 1; uint32_t v = nxgal_tex_view(t, &vi, 0, 0);
        uint32_t u[4]; probe(@"p_readu", gal_tex_get(v)->smp, nil, NULL, u, sizeof u);
        CHECK(u[0] == 0x33, "模板视图读 期望 0x33 实得 %#x", u[0]);
        nxgal_tex_release(v); nxgal_tex_release(t);
    }
}

// ===== 4 视图的视图 + 交换通道贴图当渲染目标（总指挥转来的两个缺陷）=====
static void t_views(void) {
    printf("· 视图的视图：8×8 数组 4 层 3 级 → 视图(层1 级1) → 再视图(层1 级1) = 底层 层2 级2；交换通道贴图当渲染目标\n");
    int f = fidx("R8G8B8A8Unorm"); nxgal_tex_info i = tinfo(8, 8, 4, 3, 1, f, 4);
    uint32_t t = nxgal_tex_create(&i);
    // 整张：级 0 4 层 × 256 字节，级 1 4 层 × 64，级 2 4 层 × 16；像素值 = (级, 层, x, y)
    uint8_t all[(256 + 64 + 16) * 4]; uint64_t off = 0;
    for (int l = 0; l < 3; l++) { int w = 8 >> l; for (int L = 0; L < 4; L++) for (int y = 0; y < w; y++) for (int x = 0; x < w; x++) { uint8_t *p = all + off; p[0] = l; p[1] = L; p[2] = x; p[3] = y; off += 4; } }
    nxgal_tex_set_data(t, -1, -1, NULL, all, sizeof all);
    nxgal_tex_info v1i = tinfo(4, 4, 3, 2, 1, f, 4); uint32_t v1 = nxgal_tex_view(t, &v1i, 1, 1);
    nxgal_tex_info v2i = tinfo(2, 2, 2, 1, 1, f, 4); uint32_t v2 = nxgal_tex_view(v1, &v2i, 1, 1);
    CHECK(v1 && v2, "建视图失败 %u %u", v1, v2);
    uint8_t px[16]; nxgal_tex_get_data(v2, 0, 0, px, sizeof px);
    CHECK(px[0] == 2 && px[1] == 2 && px[12] == 2 && px[13] == 2 && px[14] == 1 && px[15] == 1, "视图的视图读回 期望 (2,2,0,0)…(2,2,1,1) 实得 (%u,%u,%u,%u)…(%u,%u,%u,%u)",
          px[0], px[1], px[2], px[3], px[12], px[13], px[14], px[15]);
    float o[4]; probe(@"p_read", gal_tex_get(v2)->smp, nil, NULL, o, sizeof o);
    CHECK(feq(o[0], 2 / 255.0f, 1e-4f) && feq(o[1], 2 / 255.0f, 1e-4f), "视图的视图采样 期望 (2/255,2/255) 实得 (%g,%g)", o[0], o[1]);
    nxgal_tex_release(v2); nxgal_tex_release(v1); nxgal_tex_release(t);

    nxgal_tex_info si = tinfo(4, 4, 1, 1, 1, f, 1); int swz[4] = {4, 3, 2, 1}; memcpy(si.swz, swz, sizeof swz);   // (B,G,R,One)
    uint32_t s = nxgal_tex_create(&si); CHECK(s, "带交换通道的贴图建不出");
    nxgal_set_render_targets(&s, 1, 0);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    float c[4] = {1.0f, 0, 0, 0.6f}; nxgal_clear_color(0, 0, 1, 0xf, c);
    nxgal_set_render_targets(NULL, 0, 0);
    uint8_t raw[64]; nxgal_tex_get_data(s, 0, 0, raw, sizeof raw);
    CHECK(raw[0] == 255 && raw[1] == 0 && raw[2] == 0 && raw[3] == 153, "交换贴图当目标清屏 存储 期望 255 0 0 153 实得 %u %u %u %u", raw[0], raw[1], raw[2], raw[3]);
    probe(@"p_read", gal_tex_get(s)->smp, nil, NULL, o, sizeof o);
    CHECK(feq(o[0], 0, 1e-4f) && feq(o[2], 1, 1e-4f) && feq(o[3], 1, 1e-4f), "交换贴图采样 期望 (0,0,1,1) 实得 (%g,%g,%g,%g)", o[0], o[1], o[2], o[3]);
    nxgal_tex_release(s);
}

// ===== 5 拷贝 =====
static void fill_rgba(uint8_t *p, int w, int h, int tag) { for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { uint8_t *q = p + (y * w + x) * 4; q[0] = tag; q[1] = x; q[2] = y; q[3] = 200; } }
// 上传租约（方案 B）：同一份数据分别走旧路（nxgal_tex_set_data）与租约（nxgal_upload_rent 写入 → nxgal_tex_set_data_lease）写两张同规格贴图，
// 读回逐字节相同：整张（两层两级 RGBA8）、单层单级、子区域、深度模板（租约当数据走原路）；租约用后不可再用（重复交 / 退租无效、不崩）
static void t_lease(void) {
    printf("· 上传租约：整张 / 单层单级 / 子区域 / 深度模板，租约路与旧路读回逐字节相同；交过的租约再交报红不崩\n");
    nxgal_tex_info i = tinfo(16, 8, 2, 2, 1, fidx("R8G8B8A8Unorm"), 4 /*Texture2DArray：深度位 = 层数*/);
    uint32_t a = nxgal_tex_create(&i), b = nxgal_tex_create(&i); CHECK(a && b, "租约：贴图建不出");
    uint64_t tot = (16 * 8 + 8 * 4) * 4 * 2; uint8_t *src = malloc(tot), *ra = malloc(tot), *rb = malloc(tot);
    for (uint64_t k = 0; k < tot; k++) src[k] = (uint8_t)(k * 37 + 11);
    nxgal_tex_set_data(a, -1, -1, NULL, src, tot);
    void *cpu = NULL; uint32_t l = nxgal_upload_rent(tot, &cpu); CHECK(l && cpu, "租约：租不到");
    if (cpu) memcpy(cpu, src, tot);
    nxgal_tex_set_data_lease(b, -1, -1, NULL, l, tot);
    memset(ra, 0, tot); memset(rb, 1, tot);
    uint64_t ga = nxgal_tex_get_data(a, -1, -1, ra, tot), gb = nxgal_tex_get_data(b, -1, -1, rb, tot);
    CHECK(ga == tot && gb == tot && !memcmp(ra, rb, tot) && !memcmp(ra, src, tot), "租约整张：读回不同（%llu / %llu 字节，期望 %llu）", (unsigned long long)ga, (unsigned long long)gb, (unsigned long long)tot);
    // 单层单级：层 1 级 1（8x4）
    uint8_t one[8 * 4 * 4]; for (int k = 0; k < (int)sizeof one; k++) one[k] = (uint8_t)(k ^ 0x5a);
    nxgal_tex_set_data(a, 1, 1, NULL, one, sizeof one);
    l = nxgal_upload_rent(sizeof one, &cpu); if (cpu) memcpy(cpu, one, sizeof one);
    nxgal_tex_set_data_lease(b, 1, 1, NULL, l, sizeof one);
    uint8_t oa[sizeof one], ob[sizeof one]; nxgal_tex_get_data(a, 1, 1, oa, sizeof oa); nxgal_tex_get_data(b, 1, 1, ob, sizeof ob);
    CHECK(!memcmp(oa, ob, sizeof oa) && !memcmp(oa, one, sizeof oa), "租约单层单级：读回不同");
    // 子区域：层 0 级 0 的 (3,2) 起 5x3
    uint8_t sub[5 * 3 * 4]; for (int k = 0; k < (int)sizeof sub; k++) sub[k] = (uint8_t)(200 - k);
    nxgal_rect r = {3, 2, 5, 3};
    nxgal_tex_set_data(a, 0, 0, &r, sub, sizeof sub);
    l = nxgal_upload_rent(sizeof sub, &cpu); if (cpu) memcpy(cpu, sub, sizeof sub);
    nxgal_tex_set_data_lease(b, 0, 0, &r, l, sizeof sub);
    uint8_t fa[16 * 8 * 4], fb[16 * 8 * 4]; nxgal_tex_get_data(a, 0, 0, fa, sizeof fa); nxgal_tex_get_data(b, 0, 0, fb, sizeof fb);
    CHECK(!memcmp(fa, fb, sizeof fa), "租约子区域：读回不同");
    // 交过的租约再交：报红不崩、贴图不变
    nxgal_tex_set_data_lease(b, 0, 0, &r, l, sizeof sub); nxgal_upload_drop(l); nxgal_upload_drop(0);
    nxgal_tex_get_data(b, 0, 0, fb, sizeof fb); CHECK(!memcmp(fa, fb, sizeof fa), "租约重复交后贴图被改");
    nxgal_tex_release(a); nxgal_tex_release(b);
    // 深度模板：租约当数据走原路
    nxgal_tex_info di = tinfo(2, 1, 1, 1, 1, fidx("D24UnormS8Uint"), 1);
    uint32_t da = nxgal_tex_create(&di), db = nxgal_tex_create(&di); uint32_t din[2] = {0x12345678u, 0x9abcdef0u}, oa2[2], ob2[2];
    nxgal_tex_set_data(da, -1, -1, NULL, din, 8);
    l = nxgal_upload_rent(8, &cpu); if (cpu) memcpy(cpu, din, 8);
    nxgal_tex_set_data_lease(db, -1, -1, NULL, l, 8);
    nxgal_tex_get_data(da, -1, -1, oa2, 8); nxgal_tex_get_data(db, -1, -1, ob2, 8);
    CHECK(!memcmp(oa2, ob2, 8), "租约深度模板：读回不同 %08x %08x / %08x %08x", oa2[0], oa2[1], ob2[0], ob2[1]);
    nxgal_tex_release(da); nxgal_tex_release(db);
    free(src); free(ra); free(rb);
    // 块复用：2000 次「租 64 KB → 写贴图」，每 50 次等 GPU：共享块数有上限（不随次数涨），结束后在表未交 0、空闲块 ≤ 1（GPU 拷完才变空闲的那块要等下次交付才放）
    void gal_upload_stats(int out[3]);
    nxgal_tex_info bi = tinfo(128, 128, 1, 1, 1, fidx("R8G8B8A8Unorm"), 1);
    uint32_t bt = nxgal_tex_create(&bi); int st[3], peak = 0;
    for (int it = 0; it < 2000; it++) {
        l = nxgal_upload_rent(128 * 128 * 4, &cpu); if (cpu) memset(cpu, it & 0xff, 128 * 128 * 4);
        nxgal_tex_set_data_lease(bt, -1, -1, NULL, l, 128 * 128 * 4);
        if (it % 50 == 49) { uint8_t px[128 * 128 * 4]; nxgal_tex_get_data(bt, 0, 0, px, sizeof px);   /* 真读回：提交 + 等，块随后续提交回收 */ gal_upload_stats(st); if (st[0] > peak) peak = st[0]; }
    }
    uint8_t px2[128 * 128 * 4]; nxgal_tex_get_data(bt, 0, 0, px2, sizeof px2); gal_upload_stats(st);
    CHECK(px2[0] == (1999 & 0xff) && px2[sizeof px2 - 1] == (1999 & 0xff), "租约块复用：最后一次写入没落地（%u）", px2[0]);
    CHECK(peak <= 4, "租约块复用：共享块数峰值 %d（期望 ≤ 4，2000 次 × 64 KB 不随次数涨）", peak);
    CHECK(st[2] == 0 && st[1] <= 1, "租约块复用：结束后在表未交 %d（期望 0）、空闲块 %d（期望 ≤ 1）", st[2], st[1]);
    printf("  租约块复用：2000 次 × 64 KB，共享块峰值 %d、结束时 %d 个（空闲 %d）\n", peak, st[0], st[1]);
    nxgal_tex_release(bt);
    // 独立缓冲（> 1 MB）的租约：交给贴图、GPU 拷完就放。20 次「租 2 MB → 写贴图」、再提交几次让驻留集撤出生效后，Metal 已分配回到开始前（差 < 1 MB）；
    // 旧路（nxgal_tex_set_data，每次建暂存缓冲）同样做一遍当正对照
    nxgal_tex_info gi = tinfo(1024, 512, 1, 1, 1, fidx("R8G8B8A8Unorm"), 1);
    uint32_t gt = nxgal_tex_create(&gi); uint8_t *z = calloc(1, 1024 * 512 * 4), g1[4] = {0};
    #define SETTLE() for (int q = 0; q < 3; q++) { nxgal_rect r1 = {0, 0, 1, 1}; nxgal_tex_set_data(gt, 0, 0, &r1, g1, 4); gal_finish(); }
    SETTLE();
    int64_t o0 = (int64_t)g_gdev.currentAllocatedSize;
    for (int it = 0; it < 20; it++) nxgal_tex_set_data(gt, -1, -1, NULL, z, 1024 * 512 * 4);
    SETTLE();
    int64_t dold = (int64_t)g_gdev.currentAllocatedSize - o0, m0 = (int64_t)g_gdev.currentAllocatedSize;
    for (int it = 0; it < 20; it++) {
        l = nxgal_upload_rent(1024 * 512 * 4, &cpu); if (cpu) memset(cpu, it, 1024 * 512 * 4);
        nxgal_tex_set_data_lease(gt, -1, -1, NULL, l, 1024 * 512 * 4);
    }
    SETTLE();
    #undef SETTLE
    int64_t dm = (int64_t)g_gdev.currentAllocatedSize - m0;
    CHECK(dold < (1 << 20), "租约独立缓冲·正对照：旧路 20 × 2 MB 后 Metal 已分配多 %.1f MB（期望 < 1 MB：测法本身要能看到放掉）", dold / 1048576.0);
    CHECK(dm < (1 << 20), "租约独立缓冲：20 次 × 2 MB 交完、GPU 拷完后 Metal 已分配比开始前多 %.1f MB（期望 < 1 MB，独立缓冲没放）", dm / 1048576.0);
    printf("  租约独立缓冲：20 次 × 2 MB，交完后 Metal 已分配差 %.1f MB（旧路正对照 %.1f MB）\n", dm / 1048576.0, dold / 1048576.0);
    free(z);
    nxgal_tex_release(gt);
}

static void t_copy(void) {
    printf("· CopyTo(dst, 层, 级) / CopyTo(切片) / 兼容格式 / 压缩↔非压缩 / 每像素字节不同 / 深度→颜色 / 多重采样互拷\n");
    int rgba = fidx("R8G8B8A8Unorm");
    {   // a：src 4×4 数组 2 层 2 级 → dst 8×8 数组 4 层 3 级，偏移 层1 级1
        nxgal_tex_info si = tinfo(4, 4, 2, 2, 1, rgba, 4), di = tinfo(8, 8, 4, 3, 1, rgba, 4);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di);
        uint8_t b0[64], b1[64], b2[16], b3[16]; fill_rgba(b0, 4, 4, 10); fill_rgba(b1, 4, 4, 11); fill_rgba(b2, 2, 2, 20); fill_rgba(b3, 2, 2, 21);
        nxgal_tex_set_data(s, 0, 0, NULL, b0, 64); nxgal_tex_set_data(s, 1, 0, NULL, b1, 64); nxgal_tex_set_data(s, 0, 1, NULL, b2, 16); nxgal_tex_set_data(s, 1, 1, NULL, b3, 16);
        nxgal_tex_copy(s, d, 1, 1);
        uint8_t o[64]; nxgal_tex_get_data(d, 1, 1, o, 64); CHECK(!memcmp(o, b0, 64), "CopyTo 层1级1 ≠ 源 层0级0（首字节 %u）", o[0]);
        nxgal_tex_get_data(d, 2, 1, o, 64); CHECK(!memcmp(o, b1, 64), "CopyTo 层2级1 ≠ 源 层1级0");
        nxgal_tex_get_data(d, 1, 2, o, 16); CHECK(!memcmp(o, b2, 16), "CopyTo 层1级2 ≠ 源 层0级1");
        nxgal_tex_get_data(d, 2, 2, o, 16); CHECK(!memcmp(o, b3, 16), "CopyTo 层2级2 ≠ 源 层1级1");
        nxgal_tex_get_data(d, 0, 1, o, 64); CHECK(o[0] == 0, "CopyTo 层0 不该被写（实得 %u）", o[0]);
        // g：切片：src 层1 级0 → 新 2D 8×8 的级 1
        nxgal_tex_info ei = tinfo(8, 8, 1, 2, 1, rgba, 1); uint32_t e = nxgal_tex_create(&ei);
        nxgal_tex_copy_slice(s, e, 1, 0, 0, 1); nxgal_tex_get_data(e, 0, 1, o, 64); CHECK(!memcmp(o, b1, 64), "CopyTo 切片 ≠ 源 层1级0");
        nxgal_tex_release(e); nxgal_tex_release(s); nxgal_tex_release(d);
    }
    {   // b：R32Uint → RGBA8Unorm（同 4 字节）原始位相等
        nxgal_tex_info si = tinfo(4, 4, 1, 1, 1, fidx("R32Uint"), 1), di = tinfo(4, 4, 1, 1, 1, rgba, 1);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di); uint32_t v[16], o[16];
        for (int k = 0; k < 16; k++) v[k] = 0x11223344u * (k + 1);
        nxgal_tex_set_data(s, -1, -1, NULL, v, 64); nxgal_tex_copy(s, d, 0, 0); nxgal_tex_get_data(d, -1, -1, o, 64);
        CHECK(!memcmp(v, o, 64), "R32Uint → RGBA8 原始位不等（%08x vs %08x）", v[1], o[1]);
        nxgal_tex_release(s); nxgal_tex_release(d);
    }
    {   // c：BC1 8×8（2×2 块 × 8 字节）↔ RG32Uint 2×2
        nxgal_tex_info si = tinfo(8, 8, 1, 1, 1, fidx("Bc1RgbaUnorm"), 1), di = tinfo(2, 2, 1, 1, 1, fidx("R32G32Uint"), 1);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di), s2 = nxgal_tex_create(&si);
        uint8_t v[32], o[32]; for (int k = 0; k < 32; k++) v[k] = (uint8_t)(k * 7 + 3);
        nxgal_tex_set_data(s, -1, -1, NULL, v, 32); nxgal_tex_copy(s, d, 0, 0); nxgal_tex_get_data(d, -1, -1, o, 32);
        CHECK(!memcmp(v, o, 32), "BC1 → RG32Uint 块字节不等");
        nxgal_tex_copy(d, s2, 0, 0); memset(o, 0, 32); nxgal_tex_get_data(s2, -1, -1, o, 32);
        CHECK(!memcmp(v, o, 32), "RG32Uint → BC1 块字节不等");
        nxgal_tex_release(s); nxgal_tex_release(d); nxgal_tex_release(s2);
    }
    {   // d：每像素字节不同：R8Uint 8×2 → RGBA8Uint 2×2（行内逐字节重解释）；RGBA8Uint 2×1 → R8Uint 8×1
        nxgal_tex_info si = tinfo(8, 2, 1, 1, 1, fidx("R8Uint"), 1), di = tinfo(2, 2, 1, 1, 1, fidx("R8G8B8A8Uint"), 1);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di);
        uint8_t v[16], o[16]; for (int k = 0; k < 16; k++) v[k] = (uint8_t)(k + 100);
        nxgal_tex_set_data(s, -1, -1, NULL, v, 16); nxgal_tex_copy(s, d, 0, 0); nxgal_tex_get_data(d, -1, -1, o, 16);
        CHECK(!memcmp(v, o, 16), "R8 → RGBA8 加宽 不等（%u %u vs %u %u）", v[4], v[8], o[4], o[8]);
        nxgal_tex_info ai = tinfo(2, 1, 1, 1, 1, fidx("R8G8B8A8Uint"), 1), bi = tinfo(8, 1, 1, 1, 1, fidx("R8Uint"), 1);
        uint32_t a = nxgal_tex_create(&ai), b = nxgal_tex_create(&bi);
        nxgal_tex_set_data(a, -1, -1, NULL, v, 8); nxgal_tex_copy(a, b, 0, 0); memset(o, 0, 16); nxgal_tex_get_data(b, -1, -1, o, 8);
        CHECK(!memcmp(v, o, 8), "RGBA8 → R8 缩窄 不等");
        nxgal_tex_release(s); nxgal_tex_release(d); nxgal_tex_release(a); nxgal_tex_release(b);
    }
    {   // e：D32Float → R32Float（Vulkan CopyColor：按值）
        nxgal_tex_info si = tinfo(4, 4, 1, 1, 1, fidx("D32Float"), 1), di = tinfo(4, 4, 1, 1, 1, fidx("R32Float"), 1);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di); float v[16], o[16];
        for (int k = 0; k < 16; k++) v[k] = k / 16.0f;
        nxgal_tex_set_data(s, -1, -1, NULL, v, 64); nxgal_tex_copy(s, d, 0, 0); nxgal_tex_get_data(d, -1, -1, o, 64);
        CHECK(!memcmp(v, o, 64), "D32Float → R32Float 不等（%g vs %g）", v[5], o[5]);
        nxgal_tex_release(s); nxgal_tex_release(d);
    }
    {   // f：多重采样 4×（2×2 样本格）2×2 → 4×4：目标 (x,y) = 源像素 (x>>1, y>>1) 的第 (x&1)|((y&1)<<1) 个样本
        nxgal_tex_info mi = tinfo(2, 2, 1, 1, 4, rgba, 5), si = tinfo(4, 4, 1, 1, 1, rgba, 1);
        uint32_t m = nxgal_tex_create(&mi), s = nxgal_tex_create(&si);
        nxgal_set_render_targets(&m, 1, 0);
        nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
        float c0[4] = {0.2f, 0.4f, 0.6f, 1.0f}; nxgal_clear_color(0, 0, 1, 0xf, c0);
        nxgal_rect one = {1, 0, 1, 1}; nxgal_set_scissors(&one, 1);
        float c1[4] = {1, 0, 0, 0}; nxgal_clear_color(0, 0, 1, 0xf, c1);
        nxgal_set_scissors(&full, 1); nxgal_set_render_targets(NULL, 0, 0);
        nxgal_tex_copy(m, s, 0, 0);
        uint8_t o[64]; nxgal_tex_get_data(s, -1, -1, o, 64); int bad = 0;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) { int in = x >= 2 && y < 2; uint8_t e[4] = {in ? 255 : 51, in ? 0 : 102, in ? 0 : 153, in ? 0 : 255};
            if (memcmp(o + (y * 4 + x) * 4, e, 4) && bad++ < 2) printf("    (%d,%d) 期望 %u %u %u %u 实得 %u %u %u %u\n", x, y, e[0], e[1], e[2], e[3], o[(y*4+x)*4], o[(y*4+x)*4+1], o[(y*4+x)*4+2], o[(y*4+x)*4+3]); }
        CHECK(!bad, "多重采样 → 非多重采样 %d / 16 像素不符", bad);
        // 非多重采样 → 多重采样 → 再回来：逐字节等于原图
        uint8_t p[64], q[64]; fill_rgba(p, 4, 4, 77); nxgal_tex_set_data(s, -1, -1, NULL, p, 64);
        nxgal_tex_copy(s, m, 0, 0);
        uint32_t s2 = nxgal_tex_create(&si); nxgal_tex_copy(m, s2, 0, 0); nxgal_tex_get_data(s2, -1, -1, q, 64);
        CHECK(!memcmp(p, q, 64), "非多重采样 → 多重采样 → 回来 不等（(1,0) 期望 %u,%u,%u 实得 %u,%u,%u）", p[4], p[5], p[6], q[4], q[5], q[6]);
        nxgal_tex_release(m); nxgal_tex_release(s); nxgal_tex_release(s2);
    }
}

// ===== 6 区域拷贝（blit）=====
static void t_blit(void) {
    printf("· CopyTo(区域)：放大 2 倍最近 / 线性 / 翻转 / 整数 / 深度 / 1:1 局部 D24S8 / 多重采样解析 / D24S8 缩放\n");
    int rgba = fidx("R8G8B8A8Unorm");
    {   // a：4×4 → 8×8 最近
        nxgal_tex_info si = tinfo(4, 4, 1, 1, 1, rgba, 1), di = tinfo(8, 8, 1, 1, 1, rgba, 1);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di); uint8_t v[64], o[256]; fill_rgba(v, 4, 4, 9);
        nxgal_tex_set_data(s, -1, -1, NULL, v, 64);
        nxgal_rect a = {0, 0, 4, 4}, b = {0, 0, 8, 8}; nxgal_tex_copy_region(s, d, &a, &b, 0);
        nxgal_tex_get_data(d, -1, -1, o, 256); int bad = 0;
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) if (memcmp(o + (y * 8 + x) * 4, v + ((y / 2) * 4 + x / 2) * 4, 4)) bad++;
        CHECK(!bad, "放大最近 %d / 64 像素不符", bad);
        // c：翻转：4×1 行 → 目标 x 从 4 到 0
        nxgal_tex_info ri = tinfo(4, 1, 1, 1, 1, rgba, 1); uint32_t r = nxgal_tex_create(&ri), r2 = nxgal_tex_create(&ri);
        nxgal_tex_set_data(r, -1, -1, NULL, v, 16);
        nxgal_rect a1 = {0, 0, 4, 1}, b1 = {4, 0, -4, 1}; nxgal_tex_copy_region(r, r2, &a1, &b1, 0);
        uint8_t q[16]; nxgal_tex_get_data(r2, -1, -1, q, 16);
        CHECK(!memcmp(q, v + 12, 4) && !memcmp(q + 12, v, 4), "翻转 期望 x0=源x3 实得 x=%u / %u", q[1], q[13]);
        nxgal_tex_release(s); nxgal_tex_release(d); nxgal_tex_release(r); nxgal_tex_release(r2);
    }
    {   // b：R8Unorm [0,255] 2×1 → 4×1 线性：u = (x+0.5)/4，源坐标 = 2u−0.5 → 0, 0.25, 0.75, 1(夹) → 0, 63.75, 191.25, 255
        int r8 = fidx("R8Unorm"); nxgal_tex_info si = tinfo(2, 1, 1, 1, 1, r8, 1), di = tinfo(4, 1, 1, 1, 1, r8, 1);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di); uint8_t v[4] = {0, 255, 0, 0}, o[4];
        nxgal_tex_set_data(s, -1, -1, NULL, v, 4);
        nxgal_rect a = {0, 0, 2, 1}, b = {0, 0, 4, 1}; nxgal_tex_copy_region(s, d, &a, &b, 1); nxgal_tex_get_data(d, -1, -1, o, 4);
        CHECK(o[0] == 0 && abs(o[1] - 64) <= 1 && abs(o[2] - 191) <= 1 && o[3] == 255, "线性 期望 0 64 191 255（±1）实得 %u %u %u %u", o[0], o[1], o[2], o[3]);
        nxgal_tex_release(s); nxgal_tex_release(d);
    }
    {   // d：R32Uint 2×2 → 4×4 最近（整数走 read）
        int f = fidx("R32Uint"); nxgal_tex_info si = tinfo(2, 2, 1, 1, 1, f, 1), di = tinfo(4, 4, 1, 1, 1, f, 1);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di); uint32_t v[4] = {0xDEAD0001, 0xDEAD0002, 0xDEAD0003, 0xDEAD0004}, o[16];
        nxgal_tex_set_data(s, -1, -1, NULL, v, 16);
        nxgal_rect a = {0, 0, 2, 2}, b = {0, 0, 4, 4}; nxgal_tex_copy_region(s, d, &a, &b, 1); nxgal_tex_get_data(d, -1, -1, o, 64);
        int bad = 0; for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) if (o[y * 4 + x] != v[(y / 2) * 2 + x / 2]) bad++;
        CHECK(!bad, "整数放大 %d / 16 不符（(3,3) 实得 %08x）", bad, o[15]);
        nxgal_tex_release(s); nxgal_tex_release(d);
    }
    {   // e：D32Float 2×2 → 4×4
        int f = fidx("D32Float"); nxgal_tex_info si = tinfo(2, 2, 1, 1, 1, f, 1), di = tinfo(4, 4, 1, 1, 1, f, 1);
        uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di); float v[4] = {0.125f, 0.25f, 0.5f, 0.75f}, o[16];
        nxgal_tex_set_data(s, -1, -1, NULL, v, 16);
        nxgal_rect a = {0, 0, 2, 2}, b = {0, 0, 4, 4}; nxgal_tex_copy_region(s, d, &a, &b, 1); nxgal_tex_get_data(d, -1, -1, o, 64);
        int bad = 0; for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) if (o[y * 4 + x] != v[(y / 2) * 2 + x / 2]) bad++;
        CHECK(!bad, "深度放大 %d / 16 不符（(3,3) 实得 %g）", bad, o[15]);
        nxgal_tex_release(s); nxgal_tex_release(d);
    }
    {   // f：1:1 局部 D24UnormS8Uint：源 (1,1,2,2) → 目标 (0,0)
        int f = fidx("D24UnormS8Uint"); nxgal_tex_info i = tinfo(4, 4, 1, 1, 1, f, 1);
        uint32_t s = nxgal_tex_create(&i), d = nxgal_tex_create(&i); uint32_t v[16], z[16] = {0}, o[16];
        for (int k = 0; k < 16; k++) v[k] = ((uint32_t)(k * 0x101010 + 7) << 8) | (uint32_t)(k + 1);
        nxgal_tex_set_data(s, -1, -1, NULL, v, 64); nxgal_tex_set_data(d, -1, -1, NULL, z, 64);
        nxgal_rect a = {1, 1, 2, 2}, b = {0, 0, 2, 2}; nxgal_tex_copy_region(s, d, &a, &b, 0); nxgal_tex_get_data(d, -1, -1, o, 64);
        CHECK(o[0] == v[5] && o[1] == v[6] && o[4] == v[9] && o[5] == v[10] && o[2] == 0 && o[15] == 0, "D24S8 1:1 局部 期望 %08x %08x … 实得 %08x %08x（外 %08x）", v[5], v[6], o[0], o[1], o[2]);
        // h：D24S8 缩放 2×1 → 4×2（深度 + 模板两次绘制）
        nxgal_tex_info si = tinfo(2, 1, 1, 1, 1, f, 1), di = tinfo(4, 2, 1, 1, 1, f, 1);
        uint32_t s2 = nxgal_tex_create(&si), d2 = nxgal_tex_create(&di); uint32_t w2[2] = {0x40000011u, 0xC0000022u}, o2[8];
        nxgal_tex_set_data(s2, -1, -1, NULL, w2, 8);
        nxgal_rect a2 = {0, 0, 2, 1}, b2 = {0, 0, 4, 2}; nxgal_tex_copy_region(s2, d2, &a2, &b2, 1); nxgal_tex_get_data(d2, -1, -1, o2, 32);
        CHECK(o2[0] == w2[0] && o2[1] == w2[0] && o2[2] == w2[1] && o2[7] == w2[1], "D24S8 缩放 期望 %08x %08x %08x %08x 实得 %08x %08x %08x %08x", w2[0], w2[0], w2[1], w2[1], o2[0], o2[1], o2[2], o2[7]);
        nxgal_tex_release(s); nxgal_tex_release(d); nxgal_tex_release(s2); nxgal_tex_release(d2);
    }
    {   // g：多重采样整张同尺寸 → 解析
        nxgal_tex_info mi = tinfo(4, 4, 1, 1, 4, rgba, 5), si = tinfo(4, 4, 1, 1, 1, rgba, 1);
        uint32_t m = nxgal_tex_create(&mi), s = nxgal_tex_create(&si);
        nxgal_set_render_targets(&m, 1, 0); nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
        float c0[4] = {0.2f, 0.4f, 0.6f, 1.0f}; nxgal_clear_color(0, 0, 1, 0xf, c0); nxgal_set_render_targets(NULL, 0, 0);
        nxgal_rect a = {0, 0, 4, 4}; nxgal_tex_copy_region(m, s, &a, &a, 0);
        uint8_t o[64]; nxgal_tex_get_data(s, -1, -1, o, 64);
        CHECK(o[0] == 51 && o[1] == 102 && o[2] == 153 && o[3] == 255 && o[60] == 51, "解析 期望 51 102 153 255 实得 %u %u %u %u", o[0], o[1], o[2], o[3]);
        nxgal_tex_release(m); nxgal_tex_release(s);
    }
}

// ===== 7 拷进缓冲 =====
static void t_to_buffer(void) {
    printf("· CopyTo(BufferRange, 层, 级, 跨度)：RGBA8 层1级1 → 偏移 16 跨度 16；D24S8 / D32FS8 打包\n");
    int rgba = fidx("R8G8B8A8Unorm");
    nxgal_tex_info i = tinfo(4, 4, 2, 2, 1, rgba, 4); uint32_t t = nxgal_tex_create(&i);
    uint8_t v[16]; fill_rgba(v, 2, 2, 42); nxgal_tex_set_data(t, 1, 1, NULL, v, 16);
    uint32_t b = buf_new(64, 0xEE); nxgal_buf_range r = {b, 16, 48, 1};
    nxgal_tex_copy_to_buffer(t, &r, 1, 1, 16); gal_finish();
    uint8_t *m = bm(b).contents;
    CHECK(!memcmp(m + 16, v, 8) && !memcmp(m + 32, v + 8, 8) && m[24] == 0xEE && m[15] == 0xEE && m[40] == 0xEE, "RGBA8 拷进缓冲 行0 %u 行1 %u 空隙 %#x %#x", m[16], m[32], m[24], m[15]);
    nxgal_tex_release(t);
    int f = fidx("D24UnormS8Uint"); nxgal_tex_info di = tinfo(2, 2, 1, 1, 1, f, 1); uint32_t d = nxgal_tex_create(&di);
    uint32_t w[4] = {0x12345678u, 0xFFFFFF01u, 0x00000002u, 0x80000003u}; nxgal_tex_set_data(d, -1, -1, NULL, w, 16);
    uint32_t b2 = buf_new(64, 0); nxgal_buf_range r2 = {b2, 4, 32, 1};
    nxgal_tex_copy_to_buffer(d, &r2, 0, 0, 12); gal_finish();
    uint8_t *m2 = bm(b2).contents; uint32_t o[4]; memcpy(&o[0], m2 + 4, 4); memcpy(&o[1], m2 + 8, 4); memcpy(&o[2], m2 + 16, 4); memcpy(&o[3], m2 + 20, 4);
    CHECK(o[0] == w[0] && o[1] == w[1] && o[2] == w[2] && o[3] == w[3], "D24S8 拷进缓冲 期望 %08x %08x %08x %08x 实得 %08x %08x %08x %08x", w[0], w[1], w[2], w[3], o[0], o[1], o[2], o[3]);
    nxgal_tex_release(d);
    f = fidx("D32FloatS8Uint"); nxgal_tex_info fi = tinfo(1, 1, 1, 1, 1, f, 1); uint32_t e = nxgal_tex_create(&fi);
    uint32_t fv[2] = {0x3F400000u /*0.75*/, 0x5Cu}; nxgal_tex_set_data(e, -1, -1, NULL, fv, 8);
    uint32_t b3 = buf_new(16, 0xFF); nxgal_buf_range r3 = {b3, 0, 8, 1};
    nxgal_tex_copy_to_buffer(e, &r3, 0, 0, 0); gal_finish();
    uint32_t q[2]; memcpy(q, bm(b3).contents, 8);
    CHECK(q[0] == fv[0] && q[1] == fv[1], "D32FS8 拷进缓冲 期望 %08x %08x 实得 %08x %08x", fv[0], fv[1], q[0], q[1]);
    nxgal_tex_release(e);
}

// ===== 7b 越界防护（10-21 暗黑2 / 巫师3 Mac 开校验层两处断言：宽屏放宽贴图的尺寸与客体侧算的不一致）=====
// ① 视图登记的宽 9 大于底层贴图真实宽 8：整张拷贝按 9 宽录 → 夹到 8 宽，目标 = 源前 8 列；旧代码校验层断言（无校验层 GPU 越界写）
// ② 4×2 RGBA8 拷进 16 字节区间（要写 2 行 × 16 = 32 字节）：整次跳过，区间后面的字节保持 0xEE；旧代码照写 32 字节、越出区间 16 字节
static void t_oob_guard(void) {
    printf("· 越界防护：贴图拷贝夹到底层真实尺寸；拷进缓冲超出区间整次跳过\n");
    int rgba = fidx("R8G8B8A8Unorm");
    nxgal_tex_info pi = tinfo(8, 8, 1, 1, 1, rgba, 1), vi = tinfo(9, 8, 1, 1, 1, rgba, 1), si = tinfo(9, 8, 1, 1, 1, rgba, 1);
    uint32_t P = nxgal_tex_create(&pi), V = nxgal_tex_view(P, &vi, 0, 0), S = nxgal_tex_create(&si);
    uint8_t sv[9 * 8 * 4], z[8 * 8 * 4], o[8 * 8 * 4], want[8 * 8 * 4];
    fill_rgba(sv, 9, 8, 77); memset(z, 0, sizeof z);
    nxgal_tex_set_data(S, -1, -1, NULL, sv, sizeof sv); nxgal_tex_set_data(P, -1, -1, NULL, z, sizeof z);
    for (int y = 0; y < 8; y++) memcpy(want + y * 32, sv + y * 36, 32);
    nxgal_tex_copy(S, V, 0, 0);
    nxgal_tex_get_data(P, -1, -1, o, sizeof o);
    CHECK(V && !memcmp(o, want, sizeof o), "视图宽 9 > 底层 8 的拷贝：期望 目标 = 源前 8 列（首行末像素 x=%u），实得 x=%u", want[7 * 4 + 1], o[7 * 4 + 1]);
    nxgal_tex_release(V); nxgal_tex_release(S); nxgal_tex_release(P);
    nxgal_tex_info ti = tinfo(4, 2, 1, 1, 1, rgba, 1); uint32_t t = nxgal_tex_create(&ti);
    uint8_t tv[32]; fill_rgba(tv, 4, 2, 9); nxgal_tex_set_data(t, -1, -1, NULL, tv, 32);
    uint32_t b = buf_new(64, 0xEE); nxgal_buf_range r = {b, 0, 16, 1};
    nxgal_tex_copy_to_buffer(t, &r, 0, 0, 0); gal_finish();
    const uint8_t *m = bm(b).contents; int same = 1; for (int k = 0; k < 64; k++) same &= m[k] == 0xEE;
    CHECK(same, "4×2 拷进 16 字节区间应整次跳过：期望 64 字节全 0xEE，实得 [0] %#x [16] %#x", m[0], m[16]);
    nxgal_tex_release(t);
}

// 建缓冲失败注入（gal_newbuf_test_fail）：每像素字节不同的原始拷贝、深度模板拷进缓冲的中转缓冲建不出 → 本次拷贝跳过、目标不变、不崩；撤注入后照常。
// 旧代码反证：中转缓冲为 nil 仍录拷贝命令（Metal 收 nil 缓冲）
static void t_newbuf_fail(void) {
    printf("· 中转缓冲建不出（注入）：R8 → RGBA8 原始拷贝 / D24S8 拷进缓冲跳过、目标不变；撤注入后照常\n");
    nxgal_tex_info si = tinfo(8, 2, 1, 1, 1, fidx("R8Uint"), 1), di = tinfo(2, 2, 1, 1, 1, fidx("R8G8B8A8Uint"), 1);
    uint32_t s = nxgal_tex_create(&si), d = nxgal_tex_create(&di);
    uint8_t v[16], o[16], ab[16]; for (int k = 0; k < 16; k++) v[k] = (uint8_t)(k + 100);
    memset(ab, 0xAB, 16); nxgal_tex_set_data(s, -1, -1, NULL, v, 16); nxgal_tex_set_data(d, -1, -1, NULL, ab, 16);
    gal_newbuf_test_fail = 1; nxgal_tex_copy(s, d, 0, 0); gal_newbuf_test_fail = 0;
    nxgal_tex_get_data(d, -1, -1, o, 16); CHECK(!memcmp(o, ab, 16), "注入期间原始拷贝应跳过（目标首字节期望 0xab 实得 %#x）", o[0]);
    nxgal_tex_copy(s, d, 0, 0); nxgal_tex_get_data(d, -1, -1, o, 16); CHECK(!memcmp(o, v, 16), "撤注入后原始拷贝不等（%u vs %u）", o[4], v[4]);
    nxgal_tex_release(s); nxgal_tex_release(d);
    nxgal_tex_info zi = tinfo(2, 2, 1, 1, 1, fidx("D24UnormS8Uint"), 1); uint32_t z = nxgal_tex_create(&zi);
    uint32_t w[4] = {0x12345678u, 0xFFFFFF01u, 0x00000002u, 0x80000003u}; nxgal_tex_set_data(z, -1, -1, NULL, w, 16);
    uint32_t b = buf_new(32, 0x5A); nxgal_buf_range r = {b, 0, 16, 1};
    gal_newbuf_test_fail = 1; nxgal_tex_copy_to_buffer(z, &r, 0, 0, 8); gal_newbuf_test_fail = 0; gal_finish();
    const uint8_t *m = bm(b).contents; int same = 1; for (int k = 0; k < 32; k++) same &= m[k] == 0x5A;
    CHECK(same, "注入期间 D24S8 拷进缓冲应跳过（首字节期望 0x5a 实得 %#x）", m[0]);
    nxgal_tex_copy_to_buffer(z, &r, 0, 0, 8); gal_finish();
    uint32_t q[4]; memcpy(q, bm(b).contents, 16);
    CHECK(q[0] == w[0] && q[1] == w[1] && q[2] == w[2] && q[3] == w[3], "撤注入后 D24S8 拷进缓冲 期望 %08x %08x %08x %08x 实得 %08x %08x %08x %08x", w[0], w[1], w[2], w[3], q[0], q[1], q[2], q[3]);
    nxgal_tex_release(z);
}

// ===== 8 贴图缓冲 =====
static void t_tbuf(void) {
    printf("· 贴图缓冲：R32Uint 挂缓冲(偏移 16, 16 字节) → 着色器读；CPU 改 / GPU 填后可见；同区间不重建；未对齐拒绝；GetData 走缓冲\n");
    uint32_t b = buf_new(256, 0); uint32_t *w = bm(b).contents; for (int k = 0; k < 64; k++) w[k] = 0xA000 + k;
    nxgal_tex_info i = tinfo(4, 1, 1, 1, 1, fidx("R32Uint"), 9); uint32_t t = nxgal_tex_create(&i);
    nxgal_buf_range r = {b, 16, 16, 0}; nxgal_tex_set_storage(t, &r);
    gal_tex *tt = gal_tex_get(t); CHECK(tt->tex != nil, "SetStorage 后没有贴图"); uint32_t gen = tt->gen;
    uint32_t o[16]; probe(@"p_tbuf", tt->smp, nil, NULL, o, sizeof o);
    CHECK(o[0] == 0xA004 && o[4] == 0xA005 && o[8] == 0xA006 && o[12] == 0xA007, "贴图缓冲读 期望 A004..A007 实得 %x %x %x %x", o[0], o[4], o[8], o[12]);
    w[5] = 0xBEEF; probe(@"p_tbuf", tt->smp, nil, NULL, o, sizeof o);
    CHECK(o[4] == 0xBEEF, "CPU 改缓冲后贴图读 期望 BEEF 实得 %x", o[4]);
    [gal_blit_enc() fillBuffer:bm(b) range:NSMakeRange(24, 4) value:0x5A];   // 同一命令缓冲里 GPU 写 → 下一条读
    probe(@"p_tbuf", tt->smp, nil, NULL, o, sizeof o);
    CHECK(o[8] == 0x5A5A5A5A, "GPU 填缓冲后贴图读 期望 5A5A5A5A 实得 %x", o[8]);
    nxgal_tex_set_storage(t, &r); CHECK(gal_tex_get(t)->gen == gen, "同区间重复 SetStorage 不该重建");
    nxgal_buf_range ru = {b, 20, 16, 0}; nxgal_tex_set_storage(t, &ru); CHECK(gal_tex_get(t)->gen == gen && gal_tex_get(t)->storage.offset == 16, "偏移 20 未对齐 16 应拒绝");
    nxgal_buf_range r2 = {b, 32, 16, 0}; nxgal_tex_set_storage(t, &r2); CHECK(gal_tex_get(t)->gen == gen + 1, "换区间 gen 应 +1（实得 %u → %u）", gen, gal_tex_get(t)->gen);
    uint32_t g[4]; CHECK(nxgal_tex_get_data(t, -1, -1, NULL, 0) == 16, "贴图缓冲 GetData 大小 期望 16");
    nxgal_tex_get_data(t, -1, -1, g, 16); CHECK(g[0] == 0xA008 && g[3] == 0xA00B, "贴图缓冲 GetData 期望 A008..A00B 实得 %x..%x", g[0], g[3]);
    uint32_t s[4] = {1, 2, 3, 4}; nxgal_tex_set_data(t, -1, -1, NULL, s, 16); gal_finish();
    CHECK(w[8] == 1 && w[11] == 4, "贴图缓冲 SetData 落到缓冲 期望 1..4 实得 %u..%u", w[8], w[11]);
    nxgal_tex_release(t);
    // 回归（10-18 八方2 校验层断言 bytesPerRow 64 < 256）：交来的 info.bpp 不对（填 1），4 字节格式挂 256 字节 → 按格式算 64 个元素、行距 256，校验层下建成
    nxgal_tex_info i4 = tinfo(64, 1, 1, 1, 1, fidx("R8G8B8A8Unorm"), 9); i4.bpp = 1; uint32_t t4 = nxgal_tex_create(&i4);
    nxgal_buf_range r4 = {b, 0, 256, 0}; nxgal_tex_set_storage(t4, &r4);
    gal_tex *t4p = gal_tex_get(t4); CHECK(t4p && t4p->tex && t4p->tex.width == 64, "info.bpp 错填 1 的 RGBA8 贴图缓冲 期望建成且宽 64 实得 %lu", (unsigned long)(t4p && t4p->tex ? t4p->tex.width : 0));
    nxgal_tex_release(t4);
}

// ===== 9 采样器 =====
static void t_sampler(void) {
    printf("· 采样器：字段翻译逐项核；边框 / 比较 / LOD 夹 / LOD 偏置实采\n");
    nxgal_sampler_info si = {4, 2, 1, 0, 7, 3, 1, 0x201, {0.9f, 0.9f, 0.9f, 0.8f}, 1.0f, 0.5f, -0.5f, 7.6f};
    MTLSamplerDescriptor *d = gal_sampler_desc(&si);
    CHECK(d.minFilter == MTLSamplerMinMagFilterLinear && d.mipFilter == MTLSamplerMipFilterNearest && d.magFilter == MTLSamplerMinMagFilterLinear, "过滤 实得 min %lu mip %lu mag %lu", (unsigned long)d.minFilter, (unsigned long)d.mipFilter, (unsigned long)d.magFilter);
    CHECK(d.sAddressMode == MTLSamplerAddressModeRepeat && d.tAddressMode == MTLSamplerAddressModeMirrorClampToEdge && d.rAddressMode == MTLSamplerAddressModeClampToBorderColor, "寻址 实得 %lu %lu %lu", (unsigned long)d.sAddressMode, (unsigned long)d.tAddressMode, (unsigned long)d.rAddressMode);
    CHECK(d.compareFunction == MTLCompareFunctionLess, "比较 期望 Less 实得 %lu", (unsigned long)d.compareFunction);
    CHECK(d.borderColor == MTLSamplerBorderColorOpaqueWhite, "边框 (0.9,0.9,0.9,0.8) 期望最近 不透明白 实得 %lu", (unsigned long)d.borderColor);
    // 偏置：本机 GPU 原生生效才设在采样器上，否则由着色器加（gal_samp_caps.h / gal_border.m，端到端见 t_lodbias）
    int lbn = s2a_lodbias_native(g_gdev);
    CHECK(d.lodMinClamp == 1.0f && d.lodMaxClamp == 1.0f && d.lodBias == (lbn ? -0.5f : 0.0f) && d.maxAnisotropy == 8 && d.supportArgumentBuffers, "LOD %g %g 偏置 %g（期望 %g）各向异性 %lu 参数缓冲 %d",
          d.lodMinClamp, d.lodMaxClamp, d.lodBias, lbn ? -0.5f : 0.0f, (unsigned long)d.maxAnisotropy, d.supportArgumentBuffers);
    nxgal_sampler_info s2 = {1, 1, 1, 2, 2, 2, 0, 8, {0.2f, 0.2f, 0.2f, 1}, 0, 0, 0, 1};
    d = gal_sampler_desc(&s2);
    CHECK(d.mipFilter == MTLSamplerMipFilterNotMipmapped && d.compareFunction == MTLCompareFunctionNever && d.borderColor == MTLSamplerBorderColorOpaqueBlack && d.maxAnisotropy == 1,
          "最近无多级 / 无比较 / 边框近黑 实得 mip %lu cmp %lu 边框 %lu 各向异性 %lu", (unsigned long)d.mipFilter, (unsigned long)d.compareFunction, (unsigned long)d.borderColor, (unsigned long)d.maxAnisotropy);

    int r8 = fidx("R8Unorm");
    {   // 边框：ClampToBorder 白 → 采样 (-0.5,0.5) 得 1；透明黑 → 0
        nxgal_tex_info i = tinfo(2, 2, 1, 1, 1, r8, 1); uint32_t t = nxgal_tex_create(&i); uint8_t v[8] = {128, 128, 0, 0, 128, 128, 0, 0}; nxgal_tex_set_data(t, -1, -1, NULL, v, 8);
        nxgal_sampler_info bi = {1, 1, 1, 3, 3, 3, 0, 8, {1, 1, 1, 1}, 0, 0, 0, 1}; uint32_t s = nxgal_sampler_create(&bi);
        float uv[4] = {-0.5f, 0.5f, 0, 0}, o[4]; probe(@"p_sample", gal_tex_get(t)->smp, gal_sampler_get(s), uv, o, sizeof o);
        CHECK(feq(o[0], 1, 1e-4f) && feq(o[3], 1, 1e-4f), "边框白 期望 r=1 a=1 实得 %g %g", o[0], o[3]);
        // 透明黑用 RGBA8 核（R8 没有 alpha 分量：Metal 实测边框外 alpha 读 1，属格式缺分量的补值，不在这里断言）
        nxgal_sampler_info b0 = bi; memset(b0.border, 0, sizeof b0.border); uint32_t s0 = nxgal_sampler_create(&b0);
        nxgal_tex_info ri = tinfo(2, 2, 1, 1, 1, fidx("R8G8B8A8Unorm"), 1); uint32_t rt = nxgal_tex_create(&ri); uint8_t rv[16]; memset(rv, 200, 16); nxgal_tex_set_data(rt, -1, -1, NULL, rv, 16);
        probe(@"p_sample", gal_tex_get(rt)->smp, gal_sampler_get(s0), uv, o, sizeof o);
        CHECK(feq(o[0], 0, 1e-4f) && feq(o[3], 0, 1e-4f), "边框透明黑 期望 r=0 a=0 实得 %g %g", o[0], o[3]);
        nxgal_tex_release(rt);
        float in[4] = {0.5f, 0.5f, 0, 0}; probe(@"p_sample", gal_tex_get(t)->smp, gal_sampler_get(s), in, o, sizeof o);
        CHECK(feq(o[0], 128 / 255.0f, 1e-3f), "内部采样 期望 128/255 实得 %g", o[0]);
        nxgal_sampler_release(s); nxgal_sampler_release(s0); CHECK(gal_sampler_get(s) == nil, "释放后应取不到");
        nxgal_tex_release(t);
    }
    {   // 比较：深度 0.5，Less：参考 0.25 < 0.5 → 1，0.75 → 0
        nxgal_tex_info i = tinfo(1, 1, 1, 1, 1, fidx("D32Float"), 1); uint32_t t = nxgal_tex_create(&i); float v = 0.5f; nxgal_tex_set_data(t, -1, -1, NULL, &v, 4);
        nxgal_sampler_info ci = {1, 1, 1, 2, 2, 2, 1, 2, {0, 0, 0, 0}, 0, 0, 0, 1}; uint32_t s = nxgal_sampler_create(&ci);
        float uv[4] = {0.5f, 0.5f, 0, 0.25f}, o[4]; probe(@"p_cmp", gal_tex_get(t)->smp, gal_sampler_get(s), uv, o, sizeof o);
        CHECK(o[0] == 1, "比较 Less 参考 0.25 期望 1 实得 %g", o[0]);
        uv[3] = 0.75f; probe(@"p_cmp", gal_tex_get(t)->smp, gal_sampler_get(s), uv, o, sizeof o);
        CHECK(o[0] == 0, "比较 Less 参考 0.75 期望 0 实得 %g", o[0]);
        nxgal_sampler_release(s); nxgal_tex_release(t);
    }
    {   // LOD：级 0 = 0，级 1 = 255。最小 LOD 1 夹住 → 1.0；LOD 偏置 +1（显式 level(0)，Vulkan 语义下偏置也加在显式 LOD 上）→ 1.0
        nxgal_tex_info i = tinfo(2, 2, 1, 2, 1, r8, 1); uint32_t t = nxgal_tex_create(&i);
        uint8_t l0[8] = {0}, l1[4] = {255, 0, 0, 0}; nxgal_tex_set_data(t, 0, 0, NULL, l0, 8); nxgal_tex_set_data(t, 0, 1, NULL, l1, 4);
        nxgal_sampler_info li = {3, 1, 1, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 1.0f, 2.0f, 0, 1}; uint32_t s = nxgal_sampler_create(&li);
        float uv[4] = {0.25f, 0.25f, 0, 0}, o[4]; probe(@"p_sample", gal_tex_get(t)->smp, gal_sampler_get(s), uv, o, sizeof o);
        CHECK(feq(o[0], 1, 1e-4f), "最小 LOD 1 夹 期望 1 实得 %g", o[0]);
        nxgal_sampler_info bi = li; bi.min_lod = 0; bi.lod_bias = 1.0f; uint32_t s2 = nxgal_sampler_create(&bi);
        probe(@"p_sample", gal_tex_get(t)->smp, gal_sampler_get(s2), uv, o, sizeof o);
        // 原生：采样器自己加偏置 → 取级 1；模拟（本机原生偏置不生效）：采样器不带偏置（这支探针核不经采样辅助 → 取级 0），偏置记在表项 lb 上由改写过的着色器加（t_lodbias 端到端）
        uint64_t alt; float f[4], lb = 0; int emu_ent = gal_sampler_border(s2, &alt, f, &lb);
        if (lbn) CHECK(feq(o[0], 1, 1e-4f) && !emu_ent, "LOD 偏置 +1 原生 期望 1（取级 1）、无模拟表项 实得 %g 表项 %d", o[0], emu_ent);
        else CHECK(feq(o[0], 0, 1e-4f) && emu_ent && lb == 1.0f && !alt, "LOD 偏置 +1 模拟 期望采样器不偏（取级 0）、表项 lb 1 实得 %g 表项 %d lb %g", o[0], emu_ent, lb);
        nxgal_sampler_release(s); nxgal_sampler_release(s2); nxgal_tex_release(t);
    }
}

// ===== 10 贴图 / 图像数组 =====
static void t_arrays(void) {
    printf("· 贴图数组：建 / 写贴图与采样器 / serial 递增规则 / 越界截断 / 图像数组无采样器 / 释放\n");
    uint32_t a = nxgal_tarr_create(4, 0, 0); gal_tarr *t = gal_tarr_get(a); CHECK(t && t->size == 4 && t->smp, "建贴图数组");
    uint32_t s0 = t->serial, v[2] = {7, 8};
    nxgal_tarr_set_textures(a, 1, v, 2); t = gal_tarr_get(a);
    CHECK(t->tex[1] == 7 && t->tex[2] == 8 && t->tex[0] == 0 && t->serial > s0, "写贴图 期望 [0,7,8,0] serial 增 实得 [%u,%u,%u,%u] %u→%u", t->tex[0], t->tex[1], t->tex[2], t->tex[3], s0, t->serial);
    uint32_t s1 = t->serial; nxgal_tarr_set_textures(a, 1, v, 2); CHECK(gal_tarr_get(a)->serial == s1, "内容不变 serial 不该变");
    uint32_t sm[1] = {5}; nxgal_tarr_set_samplers(a, 0, sm, 1); CHECK(gal_tarr_get(a)->smp[0] == 5 && gal_tarr_get(a)->serial > s1, "写采样器");
    uint32_t s2 = gal_tarr_get(a)->serial; nxgal_tarr_set_textures(a, 4, v, 1); CHECK(gal_tarr_get(a)->serial == s2, "下标越界不写");
    nxgal_tarr_set_textures(a, 3, v, 2); CHECK(gal_tarr_get(a)->tex[3] == 7, "超长截断 期望 tex[3]=7");
    uint32_t im = nxgal_tarr_create(2, 0, 1); CHECK(gal_tarr_get(im)->smp == NULL && gal_tarr_get(im)->is_image, "图像数组不带采样器");
    uint32_t last = gal_tarr_get(a)->serial;
    nxgal_tarr_release(a); CHECK(gal_tarr_get(a) == NULL, "释放后应取不到");
    uint32_t b = nxgal_tarr_create(1, 1, 0); CHECK(gal_tarr_get(b)->serial > last && gal_tarr_get(b)->is_buffer, "新数组 serial 应大于旧的（编号复用不撞）");
    nxgal_tarr_release(b); nxgal_tarr_release(im);
}

// ===== 11 非录制线程读回（Ryujinx 多线程后端：客体线程直调 GetBufferData / 后台上下文读贴图，渲染线程这时可能正录到一半）=====
// 期望：另一线程读到的是已提交工作的结果；主线程在录的命令缓冲、开着的拷贝编码器都不被动（不被提交 / 结束）；只多提交一个一次性命令缓冲
typedef struct { uint32_t tex, buf; uint8_t tex_out[64], buf_out[16]; uint64_t n; } mt_arg;
static void *mt_reader(void *p) { mt_arg *a = p; a->n = nxgal_tex_get_data(a->tex, 0, 0, a->tex_out, 64); nxgal_buf_get_data(a->buf, 0, 16, a->buf_out); return NULL; }
static void t_mt_readback(void) {
    printf("· 非录制线程读回：主线程拷贝编码器开着（命令缓冲在录未提交）时另一线程读贴图 / 缓冲 → 数据对、主线程命令缓冲与编码器不动、主栅栏号不动\n");
    nxgal_tex_info i = tinfo(4, 4, 1, 1, 1, fidx("R8G8B8A8Unorm"), 1);
    uint32_t A = nxgal_tex_create(&i), C = nxgal_tex_create(&i), B = nxgal_buf_create(16, 0), B2 = nxgal_buf_create(16, 0);
    uint8_t pa[64], pb[16]; for (int k = 0; k < 64; k++) pa[k] = (uint8_t)(k * 3 + 1); for (int k = 0; k < 16; k++) pb[k] = (uint8_t)(200 - k);
    nxgal_tex_set_data(A, 0, 0, NULL, pa, 64); nxgal_buf_set_data(B, 0, pb, 16);
    nxgal_buf_copy(B, B2, 0, 0, 16);                     // 让 B 被 GPU 用过（读回走「等 GPU」那条路，不走影子）
    nxgal_create_sync(1, 0); nxgal_wait_sync(1);          // 以上全部提交并做完
    nxgal_tex_copy(A, C, 0, 0);                           // 主线程录一条拷贝：命令缓冲在录、拷贝编码器开着
    id cb0 = g_gcb; int k0; id e0 = gal_cur_enc(&k0); uint64_t f0 = gal_committed_fence();
    mt_arg a = {.tex = A, .buf = B}; pthread_t th; pthread_create(&th, NULL, mt_reader, &a); pthread_join(th, NULL);
    int k1; id e1 = gal_cur_enc(&k1);
    CHECK(a.n == 64 && !memcmp(a.tex_out, pa, 64), "另一线程读贴图内容不对（返回 %llu 字节）", (unsigned long long)a.n);
    CHECK(!memcmp(a.buf_out, pb, 16), "另一线程读缓冲内容不对");
    CHECK(cb0 != nil && g_gcb == cb0, "主线程在录的命令缓冲被换掉（被另一线程提交了）");
    CHECK(k0 == 2 && k1 == 2 && e1 == e0, "主线程开着的拷贝编码器被结束了（前 %d 后 %d）", k0, k1);
    // 一次性命令缓冲走读回自己的事件计数，不占主栅栏号（主栅栏号 + 1 是在录命令缓冲的身份，见 gal_core.m g_bgev）
    CHECK(gal_committed_fence() == f0, "主栅栏号应不动（读回用自己的事件），实际多 %llu", (unsigned long long)(gal_committed_fence() - f0));
    uint8_t oc[64] = {0}; nxgal_tex_get_data(C, 0, 0, oc, 64);
    CHECK(!memcmp(oc, pa, 64), "主线程那条拷贝之后没生效");
    nxgal_tex_release(A); nxgal_tex_release(C);
}

// ===== 12 录制中途被别的线程读回时的延后释放（10-21 暗黑2 Mac 第 110 帧 InvalidResource 复现）=====
// 场景：渲染线程在录的命令缓冲里拷了 C → D 后释放 C（宽屏层重新放宽：旧贴图拷进新贴图后 Release），这时客体线程读回 A（后台上下文 / 内存跟踪回写），然后渲染线程提交。
// 手算期望：开录时主栅栏号 G，在录命令缓冲的身份 = G + 1；读回不占主栅栏号 → 提交返回 G + 1，与身份相等；
// 延后释放按 gal_cb_id()（= 在录命令缓冲身份）挂栅栏，所以「身份在读回前后不变、提交栅栏 = 身份」即 C 挂在引用它的那次提交上。
// 旧代码反证：读回占了 G + 1，提交返回 G + 2，C 挂在 G + 1（读回那条）上，读回已等完 → 提交里的回收当场放掉 C 并移出驻留集，GPU 还没执行的拷贝引用失效资源
static void *mt_reader_tex(void *p) { mt_arg *a = p; a->n = nxgal_tex_get_data(a->tex, 0, 0, a->tex_out, 64); return NULL; }
static void t_mt_release(void) {
    printf("· 录制中途另一线程读回 + 渲染线程延后释放：在录命令缓冲身份不变、提交栅栏 = 开录身份、拷贝结果对\n");
    nxgal_tex_info i = tinfo(4, 4, 1, 1, 1, fidx("R8G8B8A8Unorm"), 1);
    uint32_t A = nxgal_tex_create(&i), C = nxgal_tex_create(&i), D = nxgal_tex_create(&i);
    uint8_t pa[64], pc[64]; for (int k = 0; k < 64; k++) { pa[k] = (uint8_t)(k * 5 + 2); pc[k] = (uint8_t)(250 - k); }
    nxgal_tex_set_data(A, 0, 0, NULL, pa, 64); nxgal_tex_set_data(C, 0, 0, NULL, pc, 64);
    nxgal_create_sync(2, 0); nxgal_wait_sync(2);
    uint64_t g0 = gal_committed_fence();
    nxgal_tex_copy(C, D, 0, 0);
    uint64_t id0 = gal_cb_id();
    nxgal_tex_release(C);
    mt_arg a = {.tex = A}; pthread_t th; pthread_create(&th, NULL, mt_reader_tex, &a); pthread_join(th, NULL);
    CHECK(a.n == 64 && !memcmp(a.tex_out, pa, 64), "另一线程读贴图内容不对（返回 %llu 字节）", (unsigned long long)a.n);
    CHECK(id0 == g0 + 1 && gal_cb_id() == id0, "在录命令缓冲身份：期望 读回前后都是 %llu，实得 前 %llu 后 %llu", (unsigned long long)(g0 + 1), (unsigned long long)id0, (unsigned long long)gal_cb_id());
    uint64_t f = gal_commit();
    CHECK(f == id0, "提交栅栏：期望 = 开录身份 %llu，实得 %llu", (unsigned long long)id0, (unsigned long long)f);
    gal_wait(f);
    uint8_t od[64] = {0}; nxgal_tex_get_data(D, 0, 0, od, 64);
    CHECK(!memcmp(od, pc, 64), "C → D 的拷贝结果不对（期望 D = C 的内容）");
    nxgal_tex_release(A); nxgal_tex_release(D);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0); signal(SIGSEGV, on_sig); signal(SIGBUS, on_sig); signal(SIGABRT, on_sig);
    if (nxgal_init(0)) { printf("初始化失败\n"); return 2; }
    @autoreleasepool {
        printf("  贴图缓冲对齐（本机）：R8 %lu RGBA8 %lu RGBA32F %lu\n", (unsigned long)[g_gdev minimumTextureBufferAlignmentForPixelFormat:MTLPixelFormatR8Unorm],
               (unsigned long)[g_gdev minimumTextureBufferAlignmentForPixelFormat:MTLPixelFormatRGBA8Unorm], (unsigned long)[g_gdev minimumTextureBufferAlignmentForPixelFormat:MTLPixelFormatRGBA32Float]);
        t_formats(); t_packed(); t_ds(); t_views(); t_lease(); t_copy(); t_blit(); t_to_buffer(); t_oob_guard(); t_newbuf_fail(); t_tbuf(); t_sampler(); t_arrays(); t_mt_readback(); t_mt_release();
    }
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END

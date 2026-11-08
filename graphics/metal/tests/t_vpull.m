// 顶点自取解码（gal_vpull.m）单测：取数辅助 MSL + 一个计算内核，逐格式喂已知字节，核对解码值。期望值全部按格式规格手算（不跑被测实现）
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_formats.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
const char *nxgal_test_vpull_msl(void);
uint32_t gal_vpull_desc(int32_t f);
void gal_vpull_entry(uint32_t *o, uint64_t addr, uint32_t stride, uint32_t desc, uint32_t step, uint32_t divisor, uint32_t len);
// 取数表每项 24 字节 = 6 个 u32（同 gal_internal.h GAL_VPULL_ENTRY；本单测不引内部头）
#define VE 6
char *gal_vpull_msl(const char *msl, const char *entry);
char gal_vpull_kind(const char *ty, const char *name);
int gal_vpull_raw_in(const char *msl, const char *entry);
// 不支持的哨兵（同 gal_internal.h GAL_VPULL_BAD；本单测不引内部头）
#define VPULL_BAD 0xffffffffu
static uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float bf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
// 原始位读（s2a_vr）用例：期望 = Maxwell 顶点取数单元的寄存器位，按格式规格手算——fl = 1：浮点类（浮点 / unorm / snorm / scaled / 打包浮点），e 是转换后的浮点值（缺分量补 0,0,0,1.0f），
//   比对时把寄存器位当 float 读、容差 1e-5（GPU 除法非正确舍入）；fl = 0：整数类（int / uint / 1010102 int），e 按整数位逐位相等（缺分量补 0,0,0,1）
typedef struct { const char *n; int fmt; uint8_t bytes[16]; int fl; float e[4]; uint32_t u[4]; } rc_t;
static int fails, total;
#define CHECK(c, ...) do { total++; if (!(c)) { fails++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
typedef struct { const char *n; int fmt; uint8_t bytes[16]; float f[4]; uint32_t u[4]; int fu; } tc;   // fu：1 = 核对整数读（s2a_vu），0 = 核对浮点读（s2a_vf）
int main(void) {
    @autoreleasepool {
        printf("· 顶点自取解码：各格式已知字节 → 手算期望值；零属性；每实例除数 / 常量步进；非 4 对齐偏移；越界读 0\n");
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
        NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\n"
            "kernel void k(constant S2AVtxAttr* t [[buffer(0)]], device float4* of [[buffer(1)]], device uint4* ou [[buffer(2)]], constant uint4& v [[buffer(3)]], device uint4* orw [[buffer(4)]], uint i [[thread_position_in_grid]]) {\n"
            "  of[i] = s2a_vf(t, i, v.x, v.y, v.z); ou[i] = s2a_vu(t, i, v.x, v.y, v.z); orw[i] = s2a_vr(t, i, v.x, v.y, v.z); }\n", [NSString stringWithUTF8String:nxgal_test_vpull_msl()]];
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
        if (!lib) { printf("  ✗ 辅助 MSL 编不过：%s\n", e.localizedDescription.UTF8String); return 1; }
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e];
        // 11_11_10：r = 1.0（指数 15、尾数 0 → 15 << 6 = 960）、g = 0.5（14 << 6 = 896）、b = 2.0（16 << 5 = 512）
        uint32_t w111110 = 960u | 896u << 11 | 512u << 22;
        // 1010102 unorm：r 1023、g 0、b 512、a 3 → (1, 0, 512/1023, 1)；snorm：r 0x200(−512 → −1)、g 511(→1)、b 0、a 01b(→1)
        uint32_t w1010u = 1023u | 0u << 10 | 512u << 20 | 3u << 30, w1010s = 0x200u | 511u << 10 | 0u << 20 | 1u << 30;
        // 9e5：r 尾数 256、g 128、b 0、指数 16 → 值 = 尾数 × 2^(16 − 15 − 9) = 尾数 / 256 → (1, 0.5, 0, 1)
        uint32_t w9e5 = 256u | 128u << 9 | 0u << 18 | 16u << 27;
        float h1 = 1.0f; (void)h1;
        tc cs[] = {
            {"R8G8B8A8Unorm", F_R8G8B8A8Unorm, {0, 255, 128, 51}, {0, 1, 128 / 255.f, 51 / 255.f}, {0}, 0},
            {"R8Snorm -127 / -128（钳到 -1）", F_R8G8Snorm, {0x81, 0x80}, {-1, -1, 0, 1}, {0}, 0},
            {"R16Float 1.0（缺分量补 0,0,1）", F_R16Float, {0x00, 0x3c}, {1, 0, 0, 1}, {0}, 0},
            {"R16G16Unorm", F_R16G16Unorm, {0xff, 0xff, 0, 0}, {1, 0, 0, 1}, {0}, 0},
            {"R32G32B32Float", F_R32G32B32Float, {0}, {1.5f, -2, 3, 1}, {0}, 0},
            {"R10G10B10A2Unorm", F_R10G10B10A2Unorm, {0}, {1, 0, 512 / 1023.f, 1}, {0}, 0},
            {"R10G10B10A2Snorm", F_R10G10B10A2Snorm, {0}, {-1, 1, 0, 1}, {0}, 0},
            {"R11G11B10Float", F_R11G11B10Float, {0}, {1, 0.5f, 2, 1}, {0}, 0},
            {"R9G9B9E5Float", F_R9G9B9E5Float, {0}, {1, 0.5f, 0, 1}, {0}, 0},
            {"B8G8R8A8Unorm（交换）", F_B8G8R8A8Unorm, {10, 20, 30, 255}, {30 / 255.f, 20 / 255.f, 10 / 255.f, 1}, {0}, 0},
            {"R8G8B8A8Uint", F_R8G8B8A8Uint, {1, 2, 3, 4}, {0}, {1, 2, 3, 4}, 1},
            {"R16Sint -2（符号扩展，缺分量补 0,0,1）", F_R16Sint, {0xfe, 0xff}, {0}, {0xfffffffeu, 0, 0, 1}, 1},
            {"R8G8Sint", F_R8G8Sint, {0xff, 0x05}, {0}, {0xffffffffu, 5, 0, 1}, 1},
            {"R32G32B32A32Uint", F_R32G32B32A32Uint, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}, {0}, {1, 256, 65536, 16777216}, 1},
            // 10_10_10_2 snorm 的 2 位 alpha：snorm 规则 max(v / (2^(2-1) - 1), -1) = max(v, -1)，补码 10b = -2 → -1、11b = -1 → -1、00b = 0 → 0（01b = 1 → 1 见上面 R10G10B10A2Snorm）
            {"R10G10B10A2Snorm a = 10b(-2 → -1)", F_R10G10B10A2Snorm, {0, 0, 0, 0x80}, {0, 0, 0, -1}, {0}, 0},
            {"R10G10B10A2Snorm a = 11b(-1 → -1)", F_R10G10B10A2Snorm, {0, 0, 0, 0xc0}, {0, 0, 0, -1}, {0}, 0},
            {"R10G10B10A2Snorm r 511 a = 00b(0)", F_R10G10B10A2Snorm, {0xff, 0x01, 0, 0}, {1, 0, 0, 0}, {0}, 0},
            // GAL 格式 0：描述按位编码恰好是 0（10-21 塞尔达，旧代码把 0 当不支持读成零）。200 / 255，缺分量补 0, 0, 1
            {"R8Unorm（GAL 格式 0）", F_R8Unorm, {200}, {200 / 255.f, 0, 0, 1}, {0}, 0},
        };
        int n = sizeof cs / sizeof *cs;
        // 不支持的格式（块压缩不能当顶点格式）给哨兵，且哨兵不是任何合法描述
        CHECK(gal_vpull_desc(F_Bc1RgbaUnorm) == VPULL_BAD && gal_vpull_desc(F_D32Float) == VPULL_BAD, "块压缩 / 深度格式应报不支持，实得 %#x %#x", gal_vpull_desc(F_Bc1RgbaUnorm), gal_vpull_desc(F_D32Float));
        memcpy(cs[4].bytes, (float[]){1.5f, -2, 3}, 12); memcpy(cs[5].bytes, &w1010u, 4); memcpy(cs[6].bytes, &w1010s, 4); memcpy(cs[7].bytes, &w111110, 4); memcpy(cs[8].bytes, &w9e5, 4);
        // 数据缓冲：每例 32 字节、起始偏移 +1（非 4 对齐，验字节读取）；另加 3 例：零属性、每实例除数 2（实例 5 基实例 1 → 元素 1 + (5−1)/2 = 3）、常量步进（元素 0）
        int extra = 6, N = n + extra;
        id<MTLBuffer> data = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; uint8_t *d = data.contents; memset(d, 0, 4096);
        id<MTLBuffer> tab = [dev newBufferWithLength:4 * VE * N options:MTLResourceStorageModeShared];
        for (int i = 0; i < n; i++) {
            memcpy(d + 1 + 32 * i, cs[i].bytes, 16);
            CHECK(gal_vpull_desc(cs[i].fmt) != VPULL_BAD, "%s：格式描述为不支持", cs[i].n);
            gal_vpull_entry((uint32_t *)tab.contents + VE * i, data.gpuAddress + 1 + 32 * i, 0, gal_vpull_desc(cs[i].fmt), 2, 0, 16);   // 常量步进：元素 0
        }
        gal_vpull_entry((uint32_t *)tab.contents + VE * n, 0, 0, gal_vpull_desc(F_R32G32B32A32Float), 0, 0, 0);   // 零属性
        // 每实例：元素 k 的 R32Uint = 100 + k，跨度 4
        for (int k = 0; k < 8; k++) { uint32_t v = 100u + (uint32_t)k; memcpy(d + 2048 + 4 * k, &v, 4); }
        gal_vpull_entry((uint32_t *)tab.contents + VE * (n + 1), data.gpuAddress + 2048, 4, gal_vpull_desc(F_R32Uint), 1, 2, 32);
        gal_vpull_entry((uint32_t *)tab.contents + VE * (n + 2), data.gpuAddress + 2048, 4, gal_vpull_desc(F_R32Uint), 2, 0, 32);
        // 越界（图形接口盘点 11）：每顶点、跨度 4、顶点 7 → 偏移 28，读 4 字节。可读 32 字节 = 末元素恰好在界内 → 107；可读 28 字节 → 越界读 0（缓冲里 2048 + 28 处是 107，不是 0）
        gal_vpull_entry((uint32_t *)tab.contents + VE * (n + 3), data.gpuAddress + 2048, 4, gal_vpull_desc(F_R32Uint), 0, 0, 32);
        gal_vpull_entry((uint32_t *)tab.contents + VE * (n + 4), data.gpuAddress + 2048, 4, gal_vpull_desc(F_R32Uint), 0, 0, 28);
        // 越界只差 1 字节：R32G32B32A32Uint 常量步进要 16 字节，可读 15 → 整个属性 0（元素前 12 字节是 100..102，不是 0）
        gal_vpull_entry((uint32_t *)tab.contents + VE * (n + 5), data.gpuAddress + 2048, 0, gal_vpull_desc(F_R32G32B32A32Uint), 2, 0, 15);
        id<MTLBuffer> of = [dev newBufferWithLength:16 * N options:MTLResourceStorageModeShared], ou = [dev newBufferWithLength:16 * N options:MTLResourceStorageModeShared];
        uint32_t v4[4] = {7, 5, 1, 0};   // 顶点 7、实例 5、基实例 1
        id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps]; [ce setBuffer:tab offset:0 atIndex:0]; [ce setBuffer:of offset:0 atIndex:1]; [ce setBuffer:ou offset:0 atIndex:2]; [ce setBytes:v4 length:16 atIndex:3];
        id<MTLBuffer> orw0 = [dev newBufferWithLength:16 * N options:MTLResourceStorageModeShared]; [ce setBuffer:orw0 offset:0 atIndex:4];
        [ce useResource:data usage:MTLResourceUsageRead];
        [ce dispatchThreads:MTLSizeMake((NSUInteger)N, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const float *F = of.contents; const uint32_t *U = ou.contents;
        for (int i = 0; i < n; i++) {
            if (cs[i].fu) { int ok = !memcmp(U + 4 * i, cs[i].u, 16); CHECK(ok, "%s：整数读 期望 %u %u %u %u 实得 %u %u %u %u", cs[i].n, cs[i].u[0], cs[i].u[1], cs[i].u[2], cs[i].u[3], U[4 * i], U[4 * i + 1], U[4 * i + 2], U[4 * i + 3]); }
            else { int ok = 1; for (int c = 0; c < 4; c++) ok &= fabsf(F[4 * i + c] - cs[i].f[c]) < 1e-5f; CHECK(ok, "%s：浮点读 期望 %g %g %g %g 实得 %g %g %g %g", cs[i].n, cs[i].f[0], cs[i].f[1], cs[i].f[2], cs[i].f[3], F[4 * i], F[4 * i + 1], F[4 * i + 2], F[4 * i + 3]); }
        }
        CHECK(F[4 * n] == 0 && F[4 * n + 1] == 0 && F[4 * n + 2] == 0 && F[4 * n + 3] == 0, "零属性应全 0，实得 %g %g %g %g", F[4 * n], F[4 * n + 1], F[4 * n + 2], F[4 * n + 3]);
        CHECK(U[4 * (n + 1)] == 103, "每实例除数 2（实例 5、基实例 1 → 元素 3）期望 103 实得 %u", U[4 * (n + 1)]);
        CHECK(U[4 * (n + 2)] == 100, "常量步进期望元素 0 = 100 实得 %u", U[4 * (n + 2)]);
        CHECK(U[4 * (n + 3)] == 107, "末元素恰在界内（偏移 28 + 4 = 可读 32）期望 107 实得 %u", U[4 * (n + 3)]);
        CHECK(U[4 * (n + 4)] == 0 && U[4 * (n + 4) + 3] == 0, "越界（偏移 28 + 4 > 可读 28）期望 0,_,_,0 实得 %u,_,_,%u", U[4 * (n + 4)], U[4 * (n + 4) + 3]);
        CHECK(!memcmp(U + 4 * (n + 5), (uint32_t[]){0, 0, 0, 0}, 16), "差 1 字节越界（要 16 可读 15）期望全 0 实得 %u %u %u %u", U[4 * (n + 5)], U[4 * (n + 5) + 1], U[4 * (n + 5) + 2], U[4 * (n + 5) + 3]);

        // ---- 原始位读（s2a_vr，Ryujinx 补丁 vattr-raw）：Maxwell 顶点取数单元产出的寄存器位，期望按格式规格手算 ----
        printf("· 原始位读：浮点 / unorm / snorm / scaled / 1010102 / 11_11_10 / 半精度 → 浮点位，int / uint → 整数位；旧口径按错类型读得错值（反证）\n");
        // 1010102 uint：r 1023、g 1、b 512、a 2；sscaled：r 0x3ff(−1)、g 5、b 0x200(−512)、a 01b(1) → (−1, 5, −512, 1)
        uint32_t w1010ui = 1023u | 1u << 10 | 512u << 20 | 2u << 30, w1010ss = 0x3ffu | 5u << 10 | 0x200u << 20 | 1u << 30;
        int32_t i4[4] = {-5, 7, INT32_MIN, 1}; float pi = 3.14159274f;
        rc_t rcs[] = {
            {"R8G8B8A8Unorm", F_R8G8B8A8Unorm, {0, 255, 128, 51}, 1, {0, 1, 128 / 255.f, 51 / 255.f}, {0}},
            {"R8G8Snorm -127 / -128（钳到 -1，缺分量 0, 1.0f）", F_R8G8Snorm, {0x81, 0x80}, 1, {-1, -1, 0, 1}, {0}},
            {"R16G16B16A16Float 1 / -2 / 0.5 / 0", F_R16G16B16A16Float, {0x00, 0x3c, 0x00, 0xc0, 0x00, 0x38, 0, 0}, 1, {1, -2, 0.5f, 0}, {0}},
            {"R32G32B32Float（缺 w 补 1.0f）", F_R32G32B32Float, {0}, 1, {1.5f, -2, 3, 1}, {0}},
            {"R10G10B10A2Unorm", F_R10G10B10A2Unorm, {0}, 1, {1, 0, 512 / 1023.f, 1}, {0}},
            {"R11G11B10Float", F_R11G11B10Float, {0}, 1, {1, 0.5f, 2, 1}, {0}},
            {"B8G8R8A8Unorm（交换）", F_B8G8R8A8Unorm, {10, 20, 30, 255}, 1, {30 / 255.f, 20 / 255.f, 10 / 255.f, 1}, {0}},
            {"R8G8B8A8Uscaled 1 / 2 / 3 / 200 → 浮点", F_R8G8B8A8Uscaled, {1, 2, 3, 200}, 1, {1, 2, 3, 200}, {0}},
            {"R16G16Sscaled -2 / 5 → 浮点（缺分量 0, 1.0f）", F_R16G16Sscaled, {0xfe, 0xff, 5, 0}, 1, {-2, 5, 0, 1}, {0}},
            {"R10G10B10A2Sscaled → 浮点", F_R10G10B10A2Sscaled, {0}, 1, {-1, 5, -512, 1}, {0}},
            {"R32Float π（位不变）", F_R32Float, {0}, 1, {pi, 0, 0, 1}, {0}},
            {"R8G8B8A8Uint", F_R8G8B8A8Uint, {1, 2, 3, 4}, 0, {0}, {1, 2, 3, 4}},
            {"R16Sint -2（符号扩展，缺分量 0, 1）", F_R16Sint, {0xfe, 0xff}, 0, {0}, {0xfffffffeu, 0, 0, 1}},
            {"R10G10B10A2Uint", F_R10G10B10A2Uint, {0}, 0, {0}, {1023, 1, 512, 2}},
            {"R32G32B32A32Sint", F_R32G32B32A32Sint, {0}, 0, {0}, {0xfffffffbu, 7, 0x80000000u, 1}},
            {"R8Unorm（GAL 格式 0）→ 浮点位", F_R8Unorm, {51}, 1, {51 / 255.f, 0, 0, 1}, {0}},
        };
        int nr = sizeof rcs / sizeof *rcs;
        memcpy(rcs[3].bytes, (float[]){1.5f, -2, 3}, 12); memcpy(rcs[4].bytes, &w1010u, 4); memcpy(rcs[5].bytes, &w111110, 4);
        memcpy(rcs[9].bytes, &w1010ss, 4); memcpy(rcs[10].bytes, &pi, 4); memcpy(rcs[13].bytes, &w1010ui, 4); memcpy(rcs[14].bytes, i4, 16);
        memset(d, 0, 4096);
        id<MTLBuffer> rtab = [dev newBufferWithLength:4 * VE * nr options:MTLResourceStorageModeShared];
        for (int i = 0; i < nr; i++) {
            memcpy(d + 1 + 32 * i, rcs[i].bytes, 16);
            CHECK(gal_vpull_desc(rcs[i].fmt) != VPULL_BAD, "%s：格式描述为不支持", rcs[i].n);
            gal_vpull_entry((uint32_t *)rtab.contents + VE * i, data.gpuAddress + 1 + 32 * i, 0, gal_vpull_desc(rcs[i].fmt), 2, 0, 16);
        }
        id<MTLBuffer> rf = [dev newBufferWithLength:16 * nr options:MTLResourceStorageModeShared], ru = [dev newBufferWithLength:16 * nr options:MTLResourceStorageModeShared], rr = [dev newBufferWithLength:16 * nr options:MTLResourceStorageModeShared];
        cb = [q commandBuffer]; ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps]; [ce setBuffer:rtab offset:0 atIndex:0]; [ce setBuffer:rf offset:0 atIndex:1]; [ce setBuffer:ru offset:0 atIndex:2]; [ce setBytes:v4 length:16 atIndex:3]; [ce setBuffer:rr offset:0 atIndex:4];
        [ce useResource:data usage:MTLResourceUsageRead];
        [ce dispatchThreads:MTLSizeMake((NSUInteger)nr, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint32_t *RR = rr.contents, *RU = ru.contents; const float *RF = rf.contents;
        int wrong_typed = 0, float_cls = 0, int_cls = 0;
        for (int i = 0; i < nr; i++) {
            const uint32_t *g = RR + 4 * i;
            if (rcs[i].fl) {
                int ok = 1; for (int c = 0; c < 4; c++) ok &= fabsf(bf(g[c]) - rcs[i].e[c]) <= 1e-5f * fmaxf(1.0f, fabsf(rcs[i].e[c]));
                CHECK(ok, "%s：原始位读 期望浮点位 %g %g %g %g 实得 %08x %08x %08x %08x（当浮点 %g %g %g %g）", rcs[i].n, rcs[i].e[0], rcs[i].e[1], rcs[i].e[2], rcs[i].e[3],
                      g[0], g[1], g[2], g[3], bf(g[0]), bf(g[1]), bf(g[2]), bf(g[3]));
                // 反证：旧口径着色器若按整数类型声明（属性类型推断成 Uint / Sint 的变体）读这个格式，拿到的不是这些寄存器位
                int same = 1; for (int c = 0; c < 4; c++) same &= fabsf(bf(RU[4 * i + c]) - rcs[i].e[c]) <= 1e-5f * fmaxf(1.0f, fabsf(rcs[i].e[c]));
                wrong_typed += !same; float_cls++;
            } else {
                CHECK(!memcmp(g, rcs[i].u, 16), "%s：原始位读 期望整数位 %08x %08x %08x %08x 实得 %08x %08x %08x %08x", rcs[i].n, rcs[i].u[0], rcs[i].u[1], rcs[i].u[2], rcs[i].u[3], g[0], g[1], g[2], g[3]);
                // 反证：按浮点类型声明的旧变体读整数格式，得到的是数值转换后的浮点位，不是整数位
                uint32_t fbits[4]; for (int c = 0; c < 4; c++) fbits[c] = fb(RF[4 * i + c]);
                wrong_typed += memcmp(fbits, rcs[i].u, 16) != 0; int_cls++;
            }
        }
        // 浮点类 12 格里 3 个浮点格式（R16G16B16A16Float / R32G32B32Float / R32Float）按整数读本来就是浮点位（as_type），其余 9 个（含 R8Unorm）按整数读都错；整数类 4 个按浮点读都错 → 13 / 16
        CHECK(wrong_typed == 13, "反证：旧口径按错类型读与 Maxwell 寄存器位不同的应是 13 / %d 格（浮点类 %d、整数类 %d），实得 %d", nr, float_cls, int_cls, wrong_typed);
        printf("  反证：旧口径按错类型读，%d / %d 格与寄存器位不同（同一客体着色器要另出整数 / 浮点变体才对）\n", wrong_typed, nr);
        // 按类型读（旧口径）缩放格式仍是整数（着色器自己补换算，等于原先 Gpu 层把缩放改成整数格式）
        CHECK(RU[4 * 7] == 1 && RU[4 * 7 + 1] == 2 && RU[4 * 7 + 2] == 3 && RU[4 * 7 + 3] == 200, "按类型读 R8G8B8A8Uscaled 期望整数 1 2 3 200 实得 %u %u %u %u", RU[28], RU[29], RU[30], RU[31]);
        CHECK(RU[4 * 8] == 0xfffffffeu && RU[4 * 8 + 1] == 5 && RU[4 * 8 + 2] == 0 && RU[4 * 8 + 3] == 1, "按类型读 R16G16Sscaled 期望整数 -2 5 0 1 实得 %08x %u %u %u", RU[32], RU[33], RU[34], RU[35]);

        // ---- MSL 改写：原始位成员（s2a_raw<位置>）→ s2a_vr；必须 uint4；输入结构识别 ----
        printf("· MSL 改写：成员 s2a_raw<位置> 用原始位读法，类型须 uint4\n");
        const char *msl =
            "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct main0_out\n{\n    float4 gl_Position [[position]];\n};\n\n"
            "struct main0_in\n{\n    uint4 s2a_raw0 [[attribute(0)]];\n    uint4 s2a_raw3 [[attribute(3)]];\n};\n\n"
            "vertex main0_out main0(main0_in in [[stage_in]])\n{\n    main0_out out = {};\n    out.gl_Position = as_type<float4>(in.s2a_raw0 + in.s2a_raw3);\n    return out;\n}\n";
        const char *msl_t =
            "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct main0_out\n{\n    float4 gl_Position [[position]];\n};\n\n"
            "struct main0_in\n{\n    float4 m_10 [[attribute(0)]];\n};\n\n"
            "vertex main0_out main0(main0_in in [[stage_in]])\n{\n    main0_out out = {};\n    out.gl_Position = in.m_10;\n    return out;\n}\n";
        char *o = gal_vpull_msl(msl, "main0");
        CHECK(o && strstr(o, "in.s2a_raw0 = s2a_vr(s2a_vt, 0, ") && strstr(o, "in.s2a_raw3 = s2a_vr(s2a_vt, 3, ") && !strstr(o, "[[attribute("), "原始位成员应改成 s2a_vr 取数、去掉 [[attribute]]");
        free(o);
        CHECK(gal_vpull_raw_in(msl, "main0") == 1 && gal_vpull_raw_in(msl_t, "main0") == 0, "输入结构识别：原始位着色器 1、按类型声明的 0");
        CHECK(gal_vpull_kind("uint4", "s2a_raw0") == 'r' && gal_vpull_kind("float4", "s2a_raw0") == 0 && gal_vpull_kind("float4", "m_10") == 'f' && gal_vpull_kind("int4", "m_2") == 'i',
              "读法：uint4 s2a_raw → r、非 uint4 的 s2a_raw → 认不出、float4 / int4 → f / i");
        { id<MTLLibrary> l2 = nil; char *o2 = gal_vpull_msl(msl, "main0");
          if (o2) { l2 = [dev newLibraryWithSource:[NSString stringWithUTF8String:o2] options:nil error:&e]; free(o2); }
          CHECK(l2 != nil, "改写后的原始位顶点着色器 MSL 应编得过：%s", l2 ? "" : e.localizedDescription.UTF8String); }
        printf("%s：%d / %d 项通过\n", fails ? "失败" : "通过", total - fails, total);
    }
    return fails ? 1 : 0;
}

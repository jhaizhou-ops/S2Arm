// Format table verification by actual creation: for every NVN format 0x01–0x9C take the mapping and actually create a 2D texture (with component remapping) on the local MTLDevice, counting how many can be created.
// Criterion: every format with a non-zero mapping is created (newTextureWithDescriptor non-nil); also verify that every NVN format with sRGB in its name lands on a Metal _sRGB format.
#import <Metal/Metal.h>
#include <stdio.h>
#include <math.h>
#include "../nvn_fmt_mtl.h"
int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device %s\n", dev.name.UTF8String);
        int mapped = 0, ok = 0, exact = 0, sub = 0, xp = 0, none = 0, bad_srgb = 0;
        static const int srgb[] = {0x37, 0x38, 0x45, 0x46, 0x47, 0x48, 0x4E, 0x9B, 0x9C};
        for (int f = 0x01; f <= 0x9C; f++) {
            uint32_t m; uint8_t s[4]; int k = nvn_fmt_to_mtl(f, &m, s);
            if (!k) { none++; continue; }
            mapped++; k == 1 ? exact++ : k == 3 ? xp++ : sub++;   // 3: expanded on upload, the texture is created in the expanded format
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)m width:120 height:120 mipmapped:NO];
            d.swizzle = MTLTextureSwizzleChannelsMake(s[0], s[1], s[2], s[3]);
            BOOL depth = m >= 250 && m <= 262;
            d.storageMode = depth ? MTLStorageModePrivate : MTLStorageModeShared;
            d.usage = MTLTextureUsageShaderRead | (depth ? MTLTextureUsageRenderTarget : 0);
            if (depth) d.swizzle = MTLTextureSwizzleChannelsDefault;     // remapping is not allowed for depth formats
            id<MTLTexture> t = [dev newTextureWithDescriptor:d];
            if (t) ok++; else printf("cannot create NVN %#x → MTL %u\n", f, m);
        }
        for (unsigned i = 0; i < sizeof srgb / sizeof *srgb; i++) {
            uint32_t m; nvn_fmt_to_mtl(srgb[i], &m, NULL);
            if (!(m == 71 || m == 81 || m == 131 || m == 133 || m == 135 || m == 153)) { printf("sRGB did not land on _sRGB: %#x → %u\n", srgb[i], m); bad_srgb++; }
        }
        for (int f = 0x87; f <= 0x94; f++) { uint32_t m; nvn_fmt_to_mtl(f, &m, NULL); if (m < 186 || m > 200) { printf("ASTC sRGB did not land on _sRGB: %#x → %u\n", f, m); bad_srgb++; } }
        printf("mapped (nonzero): %d (exact %d, substitute %d, expanded %d), no match %d, total %d; actually created %d/%d; sRGB violations %d\n", mapped, exact, sub, xp, none, 0x9C, ok, mapped, bad_srgb);
        // 16-bit packed formats' bit order (11-03): NVN names them from the lowest bits up (RGBA4 = r in bits 0–3 … a in 12–15, verified on Taiko no Tatsujin's avatar sprites read from
        //   the device; Ryujinx: Maxwell A4B4G4R4 / A1B5G5R5 / B5G6R5 carry r in the low bits, its GAL R4G4B4A4 / R5G5B5A1 / R5G6B5 the same). Expected by hand from that rule:
        //   one texel per component with that component's field all ones (the others 0) reads 1 there and 0 elsewhere; a format without alpha reads a = 1.
        //   Read on this GPU through the mapping's Metal format and swizzle (shader read). Metal's own packing measured on an M5 Max: ABGR4 r 15–12 … a 3–0, B5G6R5 r 15–11 g 10–5 b 4–0,
        //   A1BGR5 r 15–11 g 10–6 b 5–1 a 0, BGR5A1 a 15 r 14–10 g 9–5 b 4–0
        int bad4 = 0;
        {
            // per format: the four fields' masks in r, g, b, a order (0 = no such component: a reads 1)
            static const struct { int f; const char *n; uint16_t m[4]; } P[] = {
                {0x39, "RGBA4", {0x000F, 0x00F0, 0x0F00, 0xF000}}, {0x3A, "RGB5", {0x001F, 0x03E0, 0x7C00, 0}}, {0x3B, "RGB5A1", {0x001F, 0x03E0, 0x7C00, 0x8000}},
                {0x3C, "RGB565", {0x001F, 0x07E0, 0xF800, 0}}, {0x95, "BGR565", {0xF800, 0x07E0, 0x001F, 0}}, {0x96, "BGR5", {0x7C00, 0x03E0, 0x001F, 0}},
                {0x97, "BGR5A1", {0x7C00, 0x03E0, 0x001F, 0x8000}}, {0x98, "A1BGR5", {0xF800, 0x07C0, 0x003E, 0x0001}}};
            NSError *e = nil; id<MTLLibrary> l = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(texture2d<float> t [[texture(0)]], device float4 *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = t.read(uint2(i, 0)); }" options:nil error:&e];
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"k"] error:&e]; id<MTLCommandQueue> q = [dev newCommandQueue];
            for (unsigned fi = 0; fi < sizeof P / sizeof *P; fi++) {
                uint32_t m; uint8_t s[4]; nvn_fmt_to_mtl(P[fi].f, &m, s); int bad = 0;
                MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)m width:4 height:1 mipmapped:NO];
                d.swizzle = MTLTextureSwizzleChannelsMake(s[0], s[1], s[2], s[3]); d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
                id<MTLTexture> t = [dev newTextureWithDescriptor:d]; [t replaceRegion:MTLRegionMake2D(0, 0, 4, 1) mipmapLevel:0 withBytes:P[fi].m bytesPerRow:8];
                id<MTLBuffer> o = [dev newBufferWithLength:4 * 16 options:MTLResourceStorageModeShared]; id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder]; [en setComputePipelineState:ps]; [en setTexture:t atIndex:0]; [en setBuffer:o offset:0 atIndex:0];
                [en dispatchThreads:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 1, 1)]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
                const float *g = o.contents;
                for (int i = 0; i < 4; i++) for (int c = 0; c < 4; c++) {
                    float want = c == 3 && !P[fi].m[3] ? 1.0f : (c == i && P[fi].m[i]) ? 1.0f : 0.0f;
                    if (i == 3 && !P[fi].m[3]) continue;   // no alpha field: texel 3 is all zero bits, nothing to check beyond a = 1 above
                    if (fabsf(g[4 * i + c] - want) > 1e-3f) { bad++; if (bad <= 2) printf("%s texel %#06x component %d: got %.3f, want %.3f\n", P[fi].n, P[fi].m[i], c, g[4 * i + c], want); }
                }
                printf("%s (%#x) bit order: %s\n", P[fi].n, P[fi].f, bad ? "WRONG" : "ok"); bad4 += bad;
            }
        }
        return (ok == mapped && !bad_srgb && !bad4) ? 0 : 1;
    }
}

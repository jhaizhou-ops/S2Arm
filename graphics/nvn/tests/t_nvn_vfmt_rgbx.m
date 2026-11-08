// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 缺口族 43：NVN 顶点属性格式 RGBX8 … RGBX32I（0x6D–0x78）。X 是占位分量，不参与；回放把它们并到同宽同类型的 RGB（0x19–0x24）。
// 走生产代码：state_op(OP_BIND_VATTR) 收绑定 → pso_desc 出顶点描述符 → 用这份描述符在真 Metal 设备上建管线、顶点着色器把读到的属性写回缓冲。
// 期望值不跑被测实现就能算：属性字节是本测试写的，归一化 = 字节 / 255，半精度 / 单精度原值，第 4 分量按 RGB 补 1（X 的字节是 200 / NaN，读进来就错）；
//   RGBX8 后面紧挨着偏移 4 的 R32F、RGBX16I 后面紧挨偏移 40 的 R32F：X 占位字节不能让后面的属性错位；两个顶点步长 48。
// 旧代码（988cf0101）：0x6D 等没有顶点格式，属性改绑 30 号零缓冲读 (0,0,0,0)，描述符与读回都红。
#ifndef NVN_VFMT_SOURCE
#define NVN_VFMT_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_VFMT_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); } while (0)

enum { NA = 6, STRIDE = 48 };
static const struct { uint8_t fmt, ct; uint32_t off; uint8_t want_fmt; MTLVertexFormat want_vf; const char *name; } A[NA] = {
    {0x6D, NVN_CT_FLOAT, 0, 0x19, MTLVertexFormatUChar3Normalized, "RGBX8"},
    {0x0A, NVN_CT_FLOAT, 4, 0x0A, MTLVertexFormatFloat, "R32F after RGBX8"},
    {0x71, NVN_CT_FLOAT, 8, 0x1D, MTLVertexFormatHalf3, "RGBX16F"},
    {0x76, NVN_CT_FLOAT, 16, 0x22, MTLVertexFormatFloat3, "RGBX32F"},
    {0x75, NVN_CT_INT, 32, 0x21, MTLVertexFormatShort3, "RGBX16I"},
    {0x0A, NVN_CT_FLOAT, 40, 0x0A, MTLVertexFormatFloat, "R32F after RGBX16I"},
};

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VI { float4 a0 [[attribute(0)]]; float4 a1 [[attribute(1)]]; float4 a2 [[attribute(2)]]; float4 a3 [[attribute(3)]]; int4 a4 [[attribute(4)]]; float4 a5 [[attribute(5)]]; };\n"
"vertex void vtx(VI in [[stage_in]], uint vid [[vertex_id]], device float4 *o [[buffer(0)]]) {\n"
"  o[vid * 6 + 0] = in.a0; o[vid * 6 + 1] = in.a1; o[vid * 6 + 2] = in.a2; o[vid * 6 + 3] = in.a3; o[vid * 6 + 4] = float4(in.a4); o[vid * 6 + 5] = in.a5; }\n";

static void put_half(uint8_t *p, uint16_t h) { memcpy(p, &h, 2); }
static void put_f(uint8_t *p, float f) { memcpy(p, &f, 4); }
static void put_s(uint8_t *p, int16_t s) { memcpy(p, &s, 2); }

int main(void) { @autoreleasepool {
    // 1. 回放收绑定：格式并成 RGB，偏移 / 流原样；同样的绑定再来一次不置脏
    p_bind_vattr r; memset(&r, 0, sizeof r); r.first = 0; r.n = NA;
    for (int i = 0; i < NA; i++) { va_st v = {.fmt = A[i].fmt, .offset = A[i].off, .stream = 0}; memcpy(&r.st[i], &v, 4); }
    S.nattr = 0; g_pso_dirty = 0; state_op(OP_BIND_VATTR, &r, sizeof r);
    for (int i = 0; i < NA; i++)
        CHECK(S.attr[i].fmt == A[i].want_fmt && S.attr[i].offset == A[i].off && S.attr[i].stream == 0, "bind %s: format %#x -> %#x (want %#x), offset %u", A[i].name, A[i].fmt, (unsigned)S.attr[i].fmt, A[i].want_fmt, (unsigned)S.attr[i].offset);
    CHECK(S.nattr == NA && g_pso_dirty == 1, "first bind marks the pipeline dirty");
    g_pso_dirty = 0; state_op(OP_BIND_VATTR, &r, sizeof r);
    CHECK(g_pso_dirty == 0, "same RGBX binding again keeps the pipeline clean");

    // 2. 生产 pso_desc 出顶点描述符
    if (!g_dev) g_dev = MTLCreateSystemDefaultDevice();
    REQUIRE(g_dev);
    NSError *error = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    if (!lib) fprintf(stderr, "MSL %s\n", error.localizedDescription.UTF8String);
    REQUIRE(lib);
    NvShader *vs = [NvShader new]; vs->stage = 0; vs->fn = [lib newFunctionWithName:@"vtx"]; REQUIRE(vs->fn);
    strlcpy(vs->key, "aaaaaaaaaaaaaaaa_v", sizeof vs->key); vs->rf.pos_attr = -1; vs->rf.nv = NA;
    for (int i = 0; i < NA; i++) { vs->rf.v[i].loc = (uint8_t)i; vs->rf.v[i].nvn = (uint8_t)i; vs->rf.v[i].ct = A[i].ct; memset(vs->rf.v[i].sh, 0xff, 3); }
    pso_key k; memset(&k, 0, sizeof k); for (int i = 0; i < NA; i++) k.attr[i] = S.attr[i];
    k.stream[0].stride = STRIDE; k.samples = 1;
    MTLRenderPipelineDescriptor *d = pso_desc(&k, vs, nil, nil, 0); REQUIRE(d);
    MTLVertexDescriptor *vd = d.vertexDescriptor;
    for (int i = 0; i < NA; i++)
        CHECK(vd.attributes[i].format == A[i].want_vf && vd.attributes[i].offset == A[i].off && vd.attributes[i].bufferIndex == (NSUInteger)VB_SLOT(0),
              "descriptor %s: format %lu (want %lu), offset %lu, buffer %lu", A[i].name, (unsigned long)vd.attributes[i].format, (unsigned long)A[i].want_vf,
              (unsigned long)vd.attributes[i].offset, (unsigned long)vd.attributes[i].bufferIndex);
    CHECK(vd.layouts[VB_SLOT(0)].stride == STRIDE, "stream stride %lu (want %d)", (unsigned long)vd.layouts[VB_SLOT(0)].stride, STRIDE);

    // 3. 真 GPU：用这份描述符读两个顶点
    d.vertexFunction = vs->fn; d.fragmentFunction = nil; d.rasterizationEnabled = NO;
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    if (!ps) fprintf(stderr, "pipeline %s\n", error.localizedDescription.UTF8String);
    REQUIRE(ps);
    id<MTLBuffer> vb = [g_dev newBufferWithLength:2 * STRIDE options:MTLResourceStorageModeShared], out = [g_dev newBufferWithLength:2 * NA * 16 options:MTLResourceStorageModeShared],
                  zero = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    REQUIRE(vb && out && zero); memset(zero.contents, 0, 64); memset(out.contents, 0xcd, out.length);
    uint8_t *p = vb.contents; memset(p, 0, 2 * STRIDE);
    // 顶点 0
    p[0] = 255; p[1] = 51; p[2] = 0; p[3] = 200;                                                  // RGBX8，X = 200
    put_f(p + 4, 7.5f);
    put_half(p + 8, 0x3E00); put_half(p + 10, 0xC000); put_half(p + 12, 0x3400); put_half(p + 14, 0x7E00);   // 1.5, -2, 0.25, X = NaN
    put_f(p + 16, 3); put_f(p + 20, 4); put_f(p + 24, 5); put_f(p + 28, NAN);
    put_s(p + 32, -7); put_s(p + 34, 300); put_s(p + 36, -32768); put_s(p + 38, 0x7fff);           // X = 32767
    put_f(p + 40, -1.25f);
    // 顶点 1
    p += STRIDE;
    p[0] = 0; p[1] = 255; p[2] = 102; p[3] = 9;
    put_f(p + 4, 2.0f);
    put_half(p + 8, 0xB800); put_half(p + 10, 0x4400); put_half(p + 12, 0x4800); put_half(p + 14, 0x7E00);   // -0.5, 4, 8
    put_f(p + 16, -1); put_f(p + 20, 0.5f); put_f(p + 24, 2); put_f(p + 28, NAN);
    put_s(p + 32, 1); put_s(p + 34, 2); put_s(p + 36, 3); put_s(p + 38, -1);
    put_f(p + 40, 9.0f);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; rp.renderTargetWidth = 1; rp.renderTargetHeight = 1; rp.defaultRasterSampleCount = 1;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; REQUIRE(e);
    [e setRenderPipelineState:ps]; [e setVertexBuffer:vb offset:0 atIndex:VB_SLOT(0)]; [e setVertexBuffer:out offset:0 atIndex:0]; [e setVertexBuffer:zero offset:0 atIndex:30];
    [e drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:2]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    const float W[2][NA][4] = {
        {{1, 51 / 255.0f, 0, 1}, {7.5f, 0, 0, 1}, {1.5f, -2, 0.25f, 1}, {3, 4, 5, 1}, {-7, 300, -32768, 1}, {-1.25f, 0, 0, 1}},
        {{0, 1, 102 / 255.0f, 1}, {2, 0, 0, 1}, {-0.5f, 4, 8, 1}, {-1, 0.5f, 2, 1}, {1, 2, 3, 1}, {9, 0, 0, 1}},
    };
    const float *o = out.contents;
    for (int v = 0; v < 2; v++) for (int i = 0; i < NA; i++) {
        const float *g = o + (v * NA + i) * 4, *w = W[v][i]; int ok = 1;
        for (int c = 0; c < 4; c++) ok &= fabsf(g[c] - w[c]) <= 1e-3f;
        CHECK(ok, "GPU vertex %d %s: (%g, %g, %g, %g) want (%g, %g, %g, %g)", v, A[i].name, g[0], g[1], g[2], g[3], w[0], w[1], w[2], w[3]);
    }
} printf("%s t_nvn_vfmt_rgbx: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures); return failures ? 1 : 0; }

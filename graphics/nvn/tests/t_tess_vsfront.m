// S2Arm tessellation: VS 前置段单测（曲面细分 ① 段的真接口，nvn_mtl.m tess_draw ①）
// 手造一支照 main0_gs 写法的捕获顶点函数（dmsh_geometry.py capture：槽 13 = dm_geometry_capture {dst, info}，每顶点 144 字），光栅关画点 → 捕获记录；
// 再跑生产同一份搬运核 nvn_tess_gather（nvn_builtin.h）按映射表搬成 TCS 读的规范布局（gal_tessxc.m gal_tess_canon：通用位置 L 在字 4L、gl_Position 字 128、gl_PointSize 132、gl_ClipDistance 136–143）。
// A：P=4 四边形域、2 片、非索引；VS 把位置 +(10,20,0)；逐字比 8 个控制点，四边形域因子步长 12。
// B：8 位索引乱序含重复 {7,4,6,5, 5,6,7,4}；CPU 规划（nvn_tess_index_plan）去重排序后画 4 个点，第 i 个控制点在捕获里的位置 = 索引[i] − lo，TCS 按索引顺序读到对应顶点。
// 缺省走 Metal 4 接口（MTL4CommandQueue / 参数表 / MTL4RenderPassDescriptor，26 起且 Metal4 家族），NXGAL_BE=mtl3 走老接口（MTLCommandQueue / setVertexBuffer / MTLRenderPassDescriptor）：两路同一组期望
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../gfx/nvn/nvn_builtin.h"
static int fail;
#define CHECK(c, ...) do { int ok_ = (c); printf("%s ", ok_ ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); if (!ok_) fail = 1; } while (0)

// 手造顶点函数：照 dmsh_geometry.py capture 的 main0_gs（范围判定、记录地址、尾声补 0 / 1.0 都同一写法）。顶点流在槽 16（直连顶点流 16–29），槽 13 = 捕获信息块
static const char k_vs[] =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct dm_geometry_capture { device uint* dst; uint4 info; };\n"
    "vertex void t_vs(uint dm_vid [[vertex_id]], uint dm_iid [[instance_id]], const device float4* pos [[buffer(16)]], constant dm_geometry_capture& dm_gs [[buffer(13)]]) {\n"
    "    uint4 dm_ci = dm_gs.info; device uint* dm_capture = dm_gs.dst;\n"
    "    if (dm_vid - dm_ci.x >= dm_ci.y || dm_iid - dm_ci.z >= dm_ci.w) return;\n"
    "    device uint* dm_p = dm_capture + ((ulong(dm_iid - dm_ci.z) * dm_ci.y + dm_vid - dm_ci.x) * 144);\n"
    "    float4 v = pos[dm_vid]; float4 o = v + float4(10.0, 20.0, 0.0, 0.0);\n"
    "    for (uint k = 0; k < 144; ++k) dm_p[k] = 0; dm_p[3] = dm_p[4] = 0x3f800000u; for (uint k = 19; k < 144; k += 4) dm_p[k] = 0x3f800000u;\n"
    "    dm_p[0] = as_type<uint>(o.x); dm_p[1] = as_type<uint>(o.y); dm_p[2] = as_type<uint>(o.z); dm_p[3] = as_type<uint>(o.w);\n"
    "    dm_p[16] = as_type<uint>(v.x); dm_p[17] = as_type<uint>(v.y); dm_p[18] = as_type<uint>(v.z); dm_p[19] = as_type<uint>(v.w);\n"
    "    dm_p[36] = as_type<uint>(100.0 + float(dm_vid)); dm_p[37] = 0u; dm_p[38] = 0u; dm_p[39] = 0x3f800000u;\n"
    "}\n";

enum { NV = 8 };   // 顶点缓冲：顶点 j = (j, 2j, 3j, 1)
static id<MTLDevice> dev; static id<MTLRenderPipelineState> vs_pso; static id<MTLComputePipelineState> gather_pso; static int m4;
static id<MTLBuffer> mk(NSUInteger n) { return [dev newBufferWithLength:n < 16 ? 16 : n options:MTLResourceStorageModeShared]; }

// 一例：first / span 是捕获范围，idx == NULL 非索引（画 first 起 vp 个点），否则按 unique（nu 个 32 位索引）画点；map 是搬运表。返回搬运后的规范布局缓冲（vp × 576 字节）
static id<MTLBuffer> run_case(uint32_t first, uint32_t span, uint32_t vp, const uint32_t *map, const uint32_t *unique, uint32_t nu) {
    id<MTLBuffer> pos = mk(NV * 16); float *pf = pos.contents; for (int j = 0; j < NV; j++) { pf[j * 4] = j; pf[j * 4 + 1] = 2.f * j; pf[j * 4 + 2] = 3.f * j; pf[j * 4 + 3] = 1; }
    id<MTLBuffer> cap = mk(span * NVN_TESS_CP_BYTES); memset(cap.contents, 0xcd, cap.length);   // 没写到的字节留 0xcd，错位能看出
    id<MTLBuffer> mapb = mk(vp * 4); memcpy(mapb.contents, map, vp * 4);
    id<MTLBuffer> ix = mk(nu * 4); if (unique) memcpy(ix.contents, unique, nu * 4);
    id<MTLBuffer> ci = mk(32); { uint64_t c0[2] = {cap.gpuAddress, 0}; uint32_t cc[4] = {first, span, 0, 1}; memcpy(ci.contents, c0, 16); memcpy((uint8_t *)ci.contents + 16, cc, 16); }
    id<MTLBuffer> gp = mk(16); { nvn_tess_gather_p g = {vp, span, 1, 0}; memcpy(gp.contents, &g, sizeof g); }
    id<MTLBuffer> out = mk(vp * NVN_TESS_CP_BYTES); memset(out.contents, 0xab, out.length);
    NSError *e = nil; MTLSize tg = MTLSizeMake((vp + 63) / 64, 1, 1), tt = MTLSizeMake(64, 1, 1);
    if (!m4) {   // 老接口（生产 Metal 3 路）
        id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; rp.renderTargetWidth = rp.renderTargetHeight = 1; rp.defaultRasterSampleCount = 1;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:vs_pso]; [re setVertexBuffer:pos offset:0 atIndex:16]; [re setVertexBuffer:ci offset:0 atIndex:13];
        if (unique) [re drawIndexedPrimitives:MTLPrimitiveTypePoint indexCount:nu indexType:MTLIndexTypeUInt32 indexBuffer:ix indexBufferOffset:0 instanceCount:1 baseVertex:0 baseInstance:0];
        else [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:first vertexCount:vp instanceCount:1 baseInstance:0];
        [re endEncoding];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:gather_pso];
        [ce setBuffer:gp offset:0 atIndex:0]; [ce setBuffer:cap offset:0 atIndex:1]; [ce setBuffer:mapb offset:0 atIndex:2]; [ce setBuffer:out offset:0 atIndex:3];
        [ce dispatchThreadgroups:tg threadsPerThreadgroup:tt]; [ce endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "老接口命令缓冲完成（状态 %ld）", (long)cb.status);
        return out;
    }
    if (@available(macOS 26.0, *)) {   // Metal 4 接口（生产缺省路：MTL4 队列、常驻集、参数表、无附件渲染遍、编码器间全屏障）
        MTL4CommandQueueDescriptor *qd = [MTL4CommandQueueDescriptor new]; id<MTL4CommandQueue> q4 = [dev newMTL4CommandQueueWithDescriptor:qd error:&e];
        if (!q4) { CHECK(0, "MTL4CommandQueue 建不出：%s", e.localizedDescription.UTF8String); return out; }
        MTLResidencySetDescriptor *rsd = [MTLResidencySetDescriptor new]; rsd.initialCapacity = 16; id<MTLResidencySet> rs = [dev newResidencySetWithDescriptor:rsd error:&e];
        for (id<MTLBuffer> b in @[pos, cap, mapb, ix, ci, gp, out]) [rs addAllocation:b];
        [rs commit]; [q4 addResidencySet:rs];
        MTL4CommandAllocatorDescriptor *ad = [MTL4CommandAllocatorDescriptor new]; id<MTL4CommandAllocator> al = [dev newCommandAllocatorWithDescriptor:ad error:&e];
        id<MTL4CommandBuffer> cb = [dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:al];
        MTL4ArgumentTableDescriptor *td = [MTL4ArgumentTableDescriptor new]; td.maxBufferBindCount = 17; id<MTL4ArgumentTable> vt = [dev newArgumentTableWithDescriptor:td error:&e];
        [vt setAddress:pos.gpuAddress atIndex:16]; [vt setAddress:ci.gpuAddress atIndex:13];
        MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new]; rp.renderTargetWidth = rp.renderTargetHeight = rp.defaultRasterSampleCount = 1;
        id<MTL4RenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:vs_pso]; [re setArgumentTable:vt atStages:MTLRenderStageVertex];
        if (unique) [re drawIndexedPrimitives:MTLPrimitiveTypePoint indexCount:nu indexType:MTLIndexTypeUInt32 indexBuffer:ix.gpuAddress indexBufferLength:nu * 4 instanceCount:1 baseVertex:0 baseInstance:0];
        else [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:first vertexCount:vp instanceCount:1 baseInstance:0];
        [re barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [re endEncoding];
        id<MTL4ComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        MTL4ArgumentTableDescriptor *cd = [MTL4ArgumentTableDescriptor new]; cd.maxBufferBindCount = 4; id<MTL4ArgumentTable> ct = [dev newArgumentTableWithDescriptor:cd error:&e];
        [ct setAddress:gp.gpuAddress atIndex:0]; [ct setAddress:cap.gpuAddress atIndex:1]; [ct setAddress:mapb.gpuAddress atIndex:2]; [ct setAddress:out.gpuAddress atIndex:3];
        [ce setComputePipelineState:gather_pso]; [ce setArgumentTable:ct]; [ce dispatchThreadgroups:tg threadsPerThreadgroup:tt];
        [ce barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [ce endEncoding]; [cb endCommandBuffer];
        id<MTL4CommandBuffer> bufs[] = {cb}; [q4 commit:bufs count:1];
        id<MTLSharedEvent> ev = [dev newSharedEvent]; [q4 signalEvent:ev value:1];
        CHECK([ev waitUntilSignaledValue:1 timeoutMS:5000], "Metal 4 提交 5 s 内完成");
    }
    return out;
}
// 逐字比一个控制点：期望来自顶点 j（原位置 (j,2j,3j,1)、VS 平移 (10,20,0,0)、通用位置 5 = 100+j）
static int check_cp(const char *tag, id<MTLBuffer> out, uint32_t i, uint32_t j) {
    const float *w = (const float *)((const uint8_t *)out.contents + (size_t)i * NVN_TESS_CP_BYTES); const uint32_t *u = (const uint32_t *)w;
    int ok = w[128] == j + 10.f && w[129] == 2.f * j + 20.f && w[130] == 3.f * j && w[131] == 1.f;   // gl_Position（字 128–131）= 原顶点 + 平移
    ok = ok && w[0] == (float)j && w[1] == 2.f * j && w[2] == 3.f * j && w[3] == 1.f;             // 通用位置 0（字 0–3）= 原顶点
    ok = ok && w[20] == 100.f + j && w[21] == 0 && w[22] == 0 && w[23] == 1.f;                     // 通用位置 5（字 20–23）
    ok = ok && w[132] == 1.f && u[133] == 0 && u[134] == 0 && u[135] == 0;                        // gl_PointSize 1.0 与补位 0
    for (int c = 0; c < 8; c++) ok = ok && u[136 + c] == 0;                                        // gl_ClipDistance 全 0
    ok = ok && w[7] == 1.f;                                                                        // 未写的通用位置 1 的 w 补 1.0
    CHECK(ok, "%s 控制点 %u ← 顶点 %u：位置 (%g %g %g %g) 通用0 (%g %g %g %g) 通用5.x %g 点大小 %g", tag, i, j, w[128], w[129], w[130], w[131], w[0], w[1], w[2], w[3], w[20], w[132]);
    return ok;
}

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("✗ 没有 Metal 设备\n"); return 1; }
    const char *be = getenv("NXGAL_BE");
    if (!(be && !strcmp(be, "mtl3"))) { if (@available(macOS 26.0, *)) m4 = [dev supportsFamily:MTLGPUFamilyMetal4]; if (!m4) printf("  Metal 4 不可用（系统或家族），退回老接口\n"); }
    printf("  接口：%s\n", m4 ? "Metal 4（MTL4CommandQueue / 参数表）" : "Metal 3（MTLCommandQueue / setVertexBuffer）");
    NSError *e = nil;
    id<MTLLibrary> vlib = [dev newLibraryWithSource:@(k_vs) options:nil error:&e];
    if (!vlib) { printf("✗ 手造顶点函数编不过：%s\n", e.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [vlib newFunctionWithName:@"t_vs"]; pd.rasterizationEnabled = NO;
    vs_pso = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!vs_pso) { printf("✗ 捕获管线建不出：%s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLLibrary> tlib = [dev newLibraryWithSource:nvn_tess_msl() options:nil error:&e];   // 与生产 tess_init 同一份拼法（含 nvn_tess_gather）
    if (!tlib) { printf("✗ 细分核编不过：%s\n", e.localizedDescription.UTF8String); return 1; }
    gather_pso = [dev newComputePipelineStateWithFunction:[tlib newFunctionWithName:@"nvn_tess_gather"] error:&e];
    if (!gather_pso) { printf("✗ nvn_tess_gather PSO 建不出：%s\n", e.localizedDescription.UTF8String); return 1; }

    // A：P=4 四边形域、2 片、非索引：8 个顶点，first 0、span 8，映射恒等
    { uint32_t map[8]; for (uint32_t i = 0; i < 8; i++) map[i] = i;
      id<MTLBuffer> out = run_case(0, 8, 8, map, NULL, 0);
      for (uint32_t i = 0; i < 8; i++) check_cp("A", out, i, i);
      CHECK(nvn_tess_fstride(2) == 12, "A 四边形域曲面因子 stride 12（实得 %u）", nvn_tess_fstride(2));
      CHECK(nvn_tess_fstride(1) == 8, "三角域 stride 8（实得 %u）", nvn_tess_fstride(1));
      // 等值线翻译成四边形（gal_tessxc.m：unset Isolines / set Quads），TCS 按 MTLQuadTessellationFactorsHalf 12 字节一片写（审计 P0-4：原先 8，片数 ≥ 3 写出分配）
      CHECK(nvn_tess_fstride(0) == 12, "等值线域 stride 12（实得 %u）", nvn_tess_fstride(0));
      CHECK(!strcmp(nvn_tess_dom_name(2), "quads") && !strcmp(nvn_tess_dom_name(1), "triangles") && !strcmp(nvn_tess_dom_name(0), "isolines"), "域名同出库 TESS_DOM（graphics/tools/direct/dsh/Dsh.cs）"); }

    // B：8 位索引 {7,4,6,5, 5,6,7,4}（乱序、含重复）：CPU 规划 → lo 4 hi 7 span 4，unique {4,5,6,7}，map {3,0,2,1,1,2,3,0}；按 unique 画 4 个点，捕获 first 4 span 4
    { const uint8_t idx[8] = {7, 4, 6, 5, 5, 6, 7, 4}; uint32_t map[8], uniq[8], nu = 0, lo = 0, hi = 0;
      int ok = nvn_tess_index_plan(idx, 1, 8, map, uniq, &nu, &lo, &hi);
      CHECK(ok && nu == 4 && lo == 4 && hi == 7, "B 规划：nu 4 lo 4 hi 7（实得 ok %d nu %u lo %u hi %u）", ok, nu, lo, hi);
      CHECK(uniq[0] == 4 && uniq[1] == 5 && uniq[2] == 6 && uniq[3] == 7, "B unique 排序去重 {4,5,6,7}（实得 %u %u %u %u）", uniq[0], uniq[1], uniq[2], uniq[3]);
      static const uint32_t want[8] = {3, 0, 2, 1, 1, 2, 3, 0}; int mok = 1; for (int i = 0; i < 8; i++) mok = mok && map[i] == want[i];
      CHECK(mok, "B map = 索引 − lo = {3,0,2,1,1,2,3,0}（实得 %u %u %u %u %u %u %u %u）", map[0], map[1], map[2], map[3], map[4], map[5], map[6], map[7]);
      id<MTLBuffer> out = run_case(lo, hi - lo + 1, 8, map, uniq, nu);
      for (uint32_t i = 0; i < 8; i++) check_cp("B", out, i, idx[i]); }
    // 16 位索引同一规划函数（宽度分支）
    { const uint16_t idx16[4] = {300, 2, 300, 2}; uint32_t map[4], uniq[4], nu, lo, hi; nvn_tess_index_plan((const uint8_t *)idx16, 2, 4, map, uniq, &nu, &lo, &hi);
      CHECK(nu == 2 && lo == 2 && hi == 300 && map[0] == 298 && map[1] == 0 && map[2] == 298 && map[3] == 0, "16 位索引规划：nu 2 lo 2 hi 300 map {298,0,298,0}（实得 nu %u lo %u hi %u map %u %u %u %u）", nu, lo, hi, map[0], map[1], map[2], map[3]); }

    printf("%s t_tess_vsfront（%s）\n", fail ? "✗" : "✓", m4 ? "Metal 4" : "Metal 3");
    return fail;
} }

// GAL Metal 后端：第 8 块「曲面细分」——计算展开（10-21 tess）。
// 为什么不是 Metal 原生细分：Metal 4 没有固定功能曲面细分（MTL4RenderCommandEncoder 无 drawPatches / setTessellationFactorBuffer，
//   MTL4RenderPipelineDescriptor 无细分属性；10-21 M5 Max 运行时探针核过，选择子全不响应）。所以一次曲面绘制拆成：
//   ① 顶点计算核（SPIRV-Cross vertex_for_tessellation + 本文件改写：按索引 / 顶点号取属性）→ 控制点缓冲；
//   ② TCS 计算核（multi_patch_workgroup）→ 输出控制点 + 每片属性 + 细分因子（MTLQuad/TriangleTessellationFactorsHalf 布局）；
//   ③ 细分器计算核（gal_tess_d3d.h：D3D11 参照细分器，Maxwell 同一套规则）：计数 → 前缀和 → 生成域点（u, v, w, 片号）与三角形 / 线 / 点索引；
//   ④ 普通索引间接绘制：TES 改写成普通顶点函数（按顶点号从域点缓冲取 gl_TessCoord / gl_PrimitiveID），片元不变。
//   Metal 3 兼容路径同样适用（只用计算与普通绘制）；isolines 也能画（Metal 原生细分没有）。
// 阶段接口（控制点结构体）固定成规范布局（gal_internal.h GAL_TESS_LOC_*）：翻译时把 SPIRV-Cross 生成的结构体按成员的 Location 重排补位，
//   单支着色器可以单独翻、离线库按单支索引；认不出的成员判翻译失败（不静默画错）。
// 代价：每次曲面绘制要结束当前渲染通道做 ①–③（同 MoltenVK 的做法）；计数见 nxgal_tess_stats。
#import "gal_draw_internal.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include "gal_tess_msl.h"   // 构建时由 gal_tess_d3d.h 生成：k_tess_ts_src（细分器 MSL 原文）

GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）

// MSL 文本改写（翻译时）在 gal_tessxc.m

// ================= 细分器辅助库（GH_TESS，首个曲面程序建出时后台编）=================
static const char k_tess_kernels[] =
"struct S2ATessP { uint npatch, dom, part, prim, pt_cap, ix_cap, fstride, pad; };\n"
// dom：1 等值线 2 三角 3 四边形；part：1 整数 2 奇分数 3 偶分数；prim：0 点 1 线 2 顺时针三角 3 逆时针三角
"static void s2a_ts_run(thread CHWTessellator& t, constant S2ATessP& p, device const uchar* fac, uint pid) {\n"
"    PIPE_TESSELLATOR_PARTITIONING part = p.part == 2u ? PIPE_TESSELLATOR_PARTITIONING_FRACTIONAL_ODD : p.part == 3u ? PIPE_TESSELLATOR_PARTITIONING_FRACTIONAL_EVEN : PIPE_TESSELLATOR_PARTITIONING_INTEGER;\n"
"    t.Init(part, (PIPE_TESSELLATOR_OUTPUT_PRIMITIVE)p.prim);\n"
"    device const half* f = (device const half*)(fac + ulong(pid) * p.fstride);\n"
"    if (p.dom == 3u) t.TessellateQuadDomain(float(f[0]), float(f[1]), float(f[2]), float(f[3]), float(f[4]), float(f[5]));\n"
"    else if (p.dom == 2u) t.TessellateTriDomain(float(f[0]), float(f[1]), float(f[2]), float(f[3]));\n"
"    else t.TessellateIsoLineDomain(float(f[0]), float(f[1]));\n"
"}\n"
"kernel void s2a_tess_count(constant S2ATessP& p [[buffer(0)]], device const uchar* fac [[buffer(1)]], device uint2* cnt [[buffer(2)]], uint pid [[thread_position_in_grid]]) {\n"
"    if (pid >= p.npatch) return;\n"
"    CHWTessellator t; t.SetOutput(nullptr, nullptr, 0u, 0u, pid, p.dom == 2u); s2a_ts_run(t, p, fac, pid);\n"
"    cnt[pid] = uint2(uint(t.GetPointCount()), uint(t.GetIndexCount()));\n"
"}\n"
// 单线程组前缀和：每线程一段连续的片；放不下（点或索引超容量）的片及其后全部丢弃（前缀和单调，放不下的必是一段后缀），绘制数 = 第一个丢弃片的索引起点。
// 前缀和与容量比较用 64 位（审计 #854 F-tess-scan-u32）：片数可到 2^30、每片点数到 4225，uint32 会折返——等值线点图元因子 64 每片 4160 点，
//   片 1032444 的前缀 4294967040 加 4160 折成 3904，判成放得下、按越界 off 写出点 / 索引缓冲。64 位下不折返，单调成立；
//   放得下的片前缀 ≤ 容量（< 2^32），off 与绘制数截回 32 位无损；丢弃片的 off 不用（cnt 清零，emit 跳过）
"kernel void s2a_tess_scan(constant S2ATessP& p [[buffer(0)]], device uint2* cnt [[buffer(2)]], device uint2* off [[buffer(3)]], device atomic_uint* args [[buffer(4)]], device atomic_uint* stats [[buffer(7)]],\n"
"                          uint t [[thread_index_in_threadgroup]], uint nt [[threads_per_threadgroup]]) {\n"
"    threadgroup ulong2 s[1024];\n"
"    uint n = p.npatch, per = (n + nt - 1u) / nt, b = min(t * per, n), e = min(b + per, n);\n"
"    ulong2 sum = ulong2(0ul); for (uint i = b; i < e; i++) sum += ulong2(cnt[i]);\n"
"    s[t] = sum; threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"    for (uint d = 1u; d < nt; d <<= 1) { ulong2 v = t >= d ? s[t - d] : ulong2(0ul); threadgroup_barrier(mem_flags::mem_threadgroup); s[t] += v; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
"    if (t == nt - 1u) { uint total = uint(min(s[t].y, ulong(p.ix_cap)));\n"
"        atomic_store_explicit(&args[0], total, memory_order_relaxed); atomic_store_explicit(&args[1], 1u, memory_order_relaxed);\n"
"        atomic_store_explicit(&args[2], 0u, memory_order_relaxed); atomic_store_explicit(&args[3], 0u, memory_order_relaxed); atomic_store_explicit(&args[4], 0u, memory_order_relaxed);\n"
"        atomic_fetch_add_explicit(&stats[1], total, memory_order_relaxed); }\n"
"    threadgroup_barrier(mem_flags::mem_device);\n"
"    ulong2 base = s[t] - sum; uint dropped = 0u;\n"
"    for (uint i = b; i < e; i++) {\n"
"        ulong2 c = ulong2(cnt[i]); off[i] = uint2(base);\n"
"        if (base.x + c.x > ulong(p.pt_cap) || base.y + c.y > ulong(p.ix_cap)) { if (!dropped) atomic_fetch_min_explicit(&args[0], uint(min(base.y, ulong(p.ix_cap))), memory_order_relaxed); dropped++; cnt[i] = uint2(0u); }\n"
"        base += c;\n"
"    }\n"
"    if (dropped) atomic_fetch_add_explicit(&stats[0], dropped, memory_order_relaxed);\n"
"}\n"
"kernel void s2a_tess_emit(constant S2ATessP& p [[buffer(0)]], device const uchar* fac [[buffer(1)]], device const uint2* cnt [[buffer(2)]], device const uint2* off [[buffer(3)]],\n"
"                          device TS_POINT* pts [[buffer(5)]], device uint* idx [[buffer(6)]], uint pid [[thread_position_in_grid]]) {\n"
"    if (pid >= p.npatch) return;\n"
"    uint2 c = cnt[pid]; if (c.x == 0u && c.y == 0u) return;\n"
"    CHWTessellator t; t.SetOutput(pts, idx, off[pid].x, off[pid].y, pid, p.dom == 2u); s2a_ts_run(t, p, fac, pid);\n"
"}\n";
NSString *gal_tess_msl(void) {
    // 源码里有中文注释：按 UTF-8 拼（stringWithFormat 的 %s 按系统编码解释，整段丢掉）
    return [[@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:@(k_tess_ts_src)] stringByAppendingString:@(k_tess_kernels)];
}

// ================= 绘制 =================
static int ts_init(void);
void gal_warm_tess(void) { ts_init(); }
static uint64_t g_ts_draws, g_ts_patches, g_ts_splits, g_ts_skips;
static id<MTLBuffer> g_ts_stats;   // GPU 写：[0] 因超容量丢弃的曲面片数、[1] 展开出的索引数累计（共享内存，CPU 随时读）
static id<MTLComputePipelineState> g_ts_count, g_ts_scan, g_ts_emit;
NXGAL_API void nxgal_tess_stats(uint64_t out[6]) { GAL_API_LOCK();
    out[0] = g_ts_draws; out[1] = g_ts_patches; out[2] = g_ts_splits; out[3] = g_ts_skips; out[4] = g_ts_stats ? ((const uint32_t *)g_ts_stats.contents)[0] : 0; out[5] = g_ts_stats ? ((const uint32_t *)g_ts_stats.contents)[1] : 0; }
static int ts_init(void) {
    if (g_ts_emit) return 1;
    // 曲面细分器的三个辅助内核：内部预建时建（gal_warm_tess，nxgal_warm_internal 调；10-22：首次曲面绘制才建，巫师3 首局计成游戏现建）
    g_ts_count = gal_helper_pso(GH_TESS, @"s2a_tess_count"); g_ts_scan = gal_helper_pso(GH_TESS, @"s2a_tess_scan"); g_ts_emit = gal_helper_pso(GH_TESS, @"s2a_tess_emit");
    if (!g_ts_count || !g_ts_scan || !g_ts_emit) { GRED_ONCE("曲面细分器辅助着色器建不出：曲面绘制全部跳过"); g_ts_emit = nil; return 0; }
    g_ts_stats = gal_newbuf_test_fail ? nil : [g_gdev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    // 建不出：展开着色器要往它的 GPU 地址写（参数表第 7 格），不能给 0——本次曲面绘制跳过，下次重试；不往 nil.contents（NULL）写
    if (!g_ts_stats) { GRED_ONCE("曲面细分统计缓冲建不出（64 字节）：本次曲面绘制跳过、下次重试：%s", gal_mem_note()); g_ts_emit = nil; return 0; }
    memset(g_ts_stats.contents, 0, 64); gal_res_add(g_ts_stats);
    return 1;
}
// 每次绘制展开容量上限（点 / 索引）：超了的曲面片丢弃并计数（nxgal_tess_stats[4]），不画错
#define TS_PT_CAP (1u << 20)
#define TS_IX_CAP (1u << 22)
static void *ts_alloc(uint64_t bytes, uint64_t *gpu) {
    if (bytes > 0xffffffffull) { GRED_ONCE("曲面绘制：临时缓冲 %llu 字节超 4 GB", (unsigned long long)bytes); return NULL; }
    return gal_transient((uint32_t)(bytes ? bytes : 16), 16, gpu);
}
// 诊断 NXGAL_TESS_TRACE=<前几次>：打印前几次绘制的中间结果（见 gal_tess_draw 末尾）
static long ts_trace_n(void) { static long tr = -1; if (tr < 0) { const char *v = getenv("NXGAL_TESS_TRACE"); tr = v ? atol(v) : 0; } return tr; }
// 只由 GPU 读写的中间缓冲（顶点 / TCS 输出、因子、计数、偏移、间接参数、域点、索引）：走 GPU 临时池（私有存储，不占进程地址——
// 点 / 索引按上限各 16 MB，原先走共享临时池，10-21 巫师3 iPhone 低区地址被这些块吃空）。返回值只作成败标志（非 NULL = 成功），
// 不能解引用；开着诊断时退回共享池，末尾要在 CPU 上读
static void *ts_galloc(uint64_t bytes, uint64_t *gpu) {
    if (ts_trace_n()) return ts_alloc(bytes, gpu);
    if (bytes > 0xffffffffull) { GRED_ONCE("曲面绘制：临时缓冲 %llu 字节超 4 GB", (unsigned long long)bytes); return NULL; }
    *gpu = gal_transient_gpu((uint32_t)(bytes ? bytes : 16), 16);
    return *gpu ? (void *)gpu : NULL;
}
void gal_tess_draw(int indexed, uint32_t count, uint32_t inst, uint32_t first, int32_t base_vertex, uint32_t first_inst) {
    int pend = 0; const gal_prog *pg = gal_prog_get_draw(g_gs.prog, &pend);
    if (pend) { gal_first_skip_note(g_gs.prog, "曲面绘制"); return; }
    if (!pg || pg->status != 0) return;
    if (!pg->is_tess || !pg->fn[1] || !pg->fn[3]) { GRED_ONCE("曲面片拓扑但程序（%u）不是曲面程序，绘制跳过", g_gs.prog); g_ts_skips++; return; }
    if (!pg->fn[2]) { GRED_ONCE("曲面程序没有 TCS（只有 TES，用缺省细分因子）：未实现，绘制跳过（程序 %016llx）", (unsigned long long)pg->hash); g_ts_skips++; return; }
    uint32_t P = (uint32_t)g_gs.patch_vertices, N = pg->tess_ocp;
    if (P < 1 || P > 32) { GRED_ONCE("曲面绘制：每片输入控制点数 %u 不在 1..32，跳过", P); g_ts_skips++; return; }
    uint32_t ppi = count / P, Vp = ppi * P; uint64_t Pt = (uint64_t)ppi * inst;
    if (!Pt || Vp == 0) return;
    if (Pt > 0x3fffffffu) { GRED_ONCE("曲面绘制：曲面片数 %llu 过多，跳过", (unsigned long long)Pt); g_ts_skips++; return; }
    if (!ts_init()) { g_ts_skips++; return; }
    uint64_t ib = 0; uint32_t isz = 0;
    if (indexed) {
        isz = g_gs.ib_type == 0 ? 1 : g_gs.ib_type == 1 ? 2 : 4;
        ib = gal_buf_read_gpu(g_gs.ib.buf, g_gs.ib.offset, g_gs.ib.size); if (!ib) { GRED_ONCE("曲面索引绘制没有有效的索引缓冲"); g_ts_skips++; return; }
    }
    // 临时缓冲（随提交栅栏回收）
    uint32_t fstride = pg->tess_dom == GAL_TESS_TRI ? 8 : 12;
    uint64_t ptcap = Pt * 4225 < TS_PT_CAP ? Pt * 4225 : TS_PT_CAP, ixcap = Pt * 24576 < TS_IX_CAP ? Pt * 24576 : TS_IX_CAP;
    uint64_t g_vsout, g_tcs, g_patch, g_fac, g_cnt, g_off, g_args, g_pts, g_idx, g_td, g_tp, g_tsp, g_ocp;
    void *c_vsout = ts_galloc((uint64_t)Vp * inst * GAL_TESS_CP_BYTES, &g_vsout), *c_tcs = ts_galloc(Pt * N * GAL_TESS_CP_BYTES, &g_tcs), *c_patch = ts_galloc(pg->tess_patch ? Pt * GAL_TESS_PATCH_BYTES : 16, &g_patch),
         *c_fac = ts_galloc(Pt * fstride, &g_fac), *c_cnt = ts_galloc(Pt * 8, &g_cnt), *c_off = ts_galloc(Pt * 8, &g_off), *c_args = ts_galloc(32, &g_args), *c_pts = ts_galloc(ptcap * 16, &g_pts), *c_idx = ts_galloc(ixcap * 4, &g_idx);
    if (!c_vsout || !c_tcs || !c_patch || !c_fac || !c_cnt || !c_off || !c_args || !c_pts || !c_idx) { g_ts_skips++; return; }
    { // 顶点号：索引绘制 = 索引[首索引 + i] + 基顶点；非索引 = 首顶点 + i（gl_BaseVertex 按 Vulkan：索引绘制 = vertexOffset，非索引 = firstVertex）
      struct { uint64_t ib; uint32_t isz, first; int32_t bv; uint32_t bi, p0, p1; } td = {ib, isz, first, indexed ? base_vertex : (int32_t)first, first_inst, 0, 0};
      void *p = ts_alloc(sizeof td, &g_td); if (!p) { g_ts_skips++; return; } memcpy(p, &td, sizeof td); }
    { uint32_t tp[2] = {P, (uint32_t)Pt}; void *p = ts_alloc(sizeof tp, &g_tp); if (!p) { g_ts_skips++; return; } memcpy(p, tp, sizeof tp); }
    uint32_t prim = pg->tess_point ? 0 : pg->tess_dom == GAL_TESS_ISO ? 1 : pg->tess_cw ? 2 : 3;
    { uint32_t sp[8] = {(uint32_t)Pt, pg->tess_dom, pg->tess_part, prim, (uint32_t)ptcap, (uint32_t)ixcap, fstride, 0}; void *p = ts_alloc(sizeof sp, &g_tsp); if (!p) { g_ts_skips++; return; } memcpy(p, sp, sizeof sp); }
    { void *p = ts_alloc(4, &g_ocp); if (!p) { g_ts_skips++; return; } memcpy(p, &N, 4); }
    __auto_type vsp = gal_fn_compute_pso(pg->fn[1], pg->stage_hash[1]), tcp = gal_fn_compute_pso(pg->fn[2], pg->stage_hash[2]);
    if (!vsp || !tcp) { g_ts_skips++; return; }
    // ①–③ 计算（结束当前渲染通道）。每条派发前现取编码器（gal_cmp_enc 在同一编码器相邻两条之间加屏障；
    //   绑定过程中取缓冲地址可能触发镜像拷贝，先绑好再取编码器）
    gal_draw_preflush(pg);
    int k0; gal_cur_enc(&k0); if (k0 == 1) g_ts_splits++;
    id tab = gal_draw_table(2);
    if (!gal_bind_stage(pg, 1, tab)) { g_ts_skips++; return; }
    uint64_t vpt = 0; if (pg->vs_pulled) { if (!gal_vpull_fill(pg, &vpt)) { g_ts_skips++; return; } [tab setAddress:vpt atIndex:GAL_VPULL_SLOT]; }
    [tab setAddress:g_vsout atIndex:GAL_TESS_SLOT_OUT]; [tab setAddress:g_td atIndex:GAL_TESS_SLOT_POINTS];
    id ce = gal_cmp_enc(); if (!ce) { g_ts_skips++; return; }   // Metal 3 参数绑定未合入：报红跳过（gal_m3_unbound）
    [ce setComputePipelineState:vsp]; [ce setArgumentTable:tab];
    [ce dispatchThreads:MTLSizeMake(Vp, inst, 1) threadsPerThreadgroup:MTLSizeMake(Vp < 64 ? Vp : 64, 1, 1)];
    if (!gal_bind_stage(pg, 2, tab)) { g_ts_skips++; return; }
    [tab setAddress:g_vsout atIndex:GAL_TESS_SLOT_IN]; [tab setAddress:g_tcs atIndex:GAL_TESS_SLOT_OUT]; [tab setAddress:g_patch atIndex:GAL_TESS_SLOT_PATCH];
    [tab setAddress:g_fac atIndex:GAL_TESS_SLOT_FACTOR]; [tab setAddress:g_tp atIndex:GAL_TESS_SLOT_PARAMS];
    ce = gal_cmp_enc(); [ce setComputePipelineState:tcp]; [ce setArgumentTable:tab];
    // 一个线程组装整数个曲面片（TCS 里的 barrier 只在片内同步）；按线程数派发、最后一组不补满（审计 P0-5）：多片工作组的核只把输入与 gl_PrimitiveID 夹到最后一片，
    //   每片输出 / 控制点输出不夹，gl_InvocationID = gid % N 挡不住补出来的线程，补满 per × N 会写出 Pt × N 个控制点之外
    { uint32_t per = N >= 32 ? 1 : 32 / N;
      [ce dispatchThreads:MTLSizeMake(Pt * N, 1, 1) threadsPerThreadgroup:MTLSizeMake(per * N, 1, 1)]; }
    [tab setAddress:g_tsp atIndex:0]; [tab setAddress:g_fac atIndex:1]; [tab setAddress:g_cnt atIndex:2]; [tab setAddress:g_off atIndex:3];
    [tab setAddress:g_args atIndex:4]; [tab setAddress:g_pts atIndex:5]; [tab setAddress:g_idx atIndex:6]; [tab setAddress:g_ts_stats.gpuAddress atIndex:7];
    ce = gal_cmp_enc(); [ce setComputePipelineState:g_ts_count]; [ce setArgumentTable:tab]; [ce dispatchThreads:MTLSizeMake(Pt, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    ce = gal_cmp_enc(); [ce setComputePipelineState:g_ts_scan]; [ce setArgumentTable:tab];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(g_ts_scan.maxTotalThreadsPerThreadgroup < 1024 ? g_ts_scan.maxTotalThreadsPerThreadgroup : 1024, 1, 1)];
    ce = gal_cmp_enc(); [ce setComputePipelineState:g_ts_emit]; [ce setArgumentTable:tab]; [ce dispatchThreads:MTLSizeMake(Pt, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    g_gs.dirty |= GS_ARGS;
    // ④ 绘制：TES 顶点函数按顶点号取域点
    const gal_prog *pg2; id re = gal_prepare_draw(&pg2); if (!re) { g_ts_skips++; return; }
    id vt = gal_draw_table(0);
    [vt setAddress:g_tcs atIndex:GAL_TESS_SLOT_IN]; [vt setAddress:g_patch atIndex:GAL_TESS_SLOT_PATCH]; [vt setAddress:g_fac atIndex:GAL_TESS_SLOT_FACTOR];
    [vt setAddress:g_ocp atIndex:GAL_TESS_SLOT_PARAMS]; [vt setAddress:g_pts atIndex:GAL_TESS_SLOT_POINTS];
    MTLPrimitiveType pt = prim == 0 ? MTLPrimitiveTypePoint : prim == 1 ? MTLPrimitiveTypeLine : MTLPrimitiveTypeTriangle;
    [re drawIndexedPrimitives:pt indexType:MTLIndexTypeUInt32 indexBuffer:g_idx indexBufferLength:(NSUInteger)(ixcap * 4) indirectBuffer:g_args];
    g_gs.dirty |= GS_VB;   // 槽 8–13 借给了曲面：下次普通绘制重绑顶点缓冲
    g_ts_draws++; g_ts_patches += Pt;
    // 诊断 NXGAL_TESS_TRACE=<前几次>：等这次做完，打印各段中间结果（控制点位置、细分因子、计数、间接参数、首个域点）
    { long tr = ts_trace_n();
      if ((long)g_ts_draws <= tr) {
        gal_finish();
        const float *cp = c_vsout, *tc = c_tcs, *pt0 = c_pts; const __fp16 *fh = c_fac; const uint32_t *cn = c_cnt, *ar = c_args; (void)c_patch; (void)c_off; (void)c_idx;
        GLOG("曲面诊断 #%llu：P=%u N=%u 片=%llu 域 %u 分区 %u 图元 %u；顶点输出 0 位置0 (%g %g %g %g) 内建位置 (%g %g %g %g)；TCS 输出 0 位置0 (%g %g %g %g)",
             (unsigned long long)g_ts_draws, P, N, (unsigned long long)Pt, pg->tess_dom, pg->tess_part, prim, cp[0], cp[1], cp[2], cp[3], cp[128], cp[129], cp[130], cp[131], tc[0], tc[1], tc[2], tc[3]);
        GLOG("  顶点自取 %d 输入 %#x 取数表 %#llx", pg->vs_pulled, pg->vs_inputs, (unsigned long long)vpt);
        GLOG("  因子 片0 %g %g %g %g %g %g；计数 片0 点 %u 索引 %u；间接 %u %u %u %u %u；域点 0 (%g %g %g %u)", (float)fh[0], (float)fh[1], (float)fh[2], (float)fh[3], (float)fh[4], (float)fh[5],
             cn[0], cn[1], ar[0], ar[1], ar[2], ar[3], ar[4], pt0[0], pt0[1], pt0[2], ((const uint32_t *)pt0)[3]);
      } }
}
GAL_MTL4_ZONE_END

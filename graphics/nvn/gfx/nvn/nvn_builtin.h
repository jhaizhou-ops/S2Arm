// The 4 Maxwell compute shaders embedded in the main program itself (no counterpart in the PC version) -> hand-written MSL, equivalent instruction by instruction to the envydis disassembly.
// Source: control segments in the .rodata of the original main image @0x1df10e8 / 0x1df1a94 / 0x1df2440 / 0x1df2dec (envydis -m gm107).
// Common skeleton (original Maxwell):
//   id = (ctaid.x << 5) + tid.x                       // thread group 32x1x1
//   if (id >= c3[0x0]) exit                           // element count = word 0 of uniform buffer 0 (u32 compare)
//   src = ssbo0 (c0[0x310]), dst = ssbo1 (c0[0x320]), address = base + 32-bit offset
// Differences between kernels (an NVN counter report is 16 bytes = {count u64, timestamp u64}):
//   q_val0   dst[id] = *(u64*)(src + (id<<4))                         take the count
//   q_val8   dst[id] = *(u64*)(src + (id<<4) + 8)                     take the timestamp
//   q_dlt0   dst[id] = *(u64*)(src + (id<<5) + 16) - *(u64*)(src + (id<<5))        count difference between two consecutive reports
//   q_dlt8   dst[id] = *(u64*)(src + (id<<5) + 24) - *(u64*)(src + (id<<5) + 8)    timestamp difference between two consecutive reports
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static const char *const k_nvn_builtin_msl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "#define HEAD uint id = (cta.x << 5) + tid.x; if (id >= n[0]) return;\n"
    "#define LD(o) (*(device const ulong *)(src + (o)))\n"
    "#define ARGS constant uint *n [[buffer(0)]], device const uchar *src [[buffer(1)]], device uchar *dst [[buffer(2)]], "
    "uint3 cta [[threadgroup_position_in_grid]], uint3 tid [[thread_position_in_threadgroup]]\n"
    "#define ST(v) (*(device ulong *)(dst + (id << 3)) = (v))\n"
    "kernel void q_val0(ARGS) { HEAD ST(LD(id << 4)); }\n"
    "kernel void q_val8(ARGS) { HEAD ST(LD((id << 4) + 8u)); }\n"
    "kernel void q_dlt0(ARGS) { HEAD uint b = id << 5; ST(LD(b + 16u) - LD(b)); }\n"
    "kernel void q_dlt8(ARGS) { HEAD uint b = (id << 5) + 16u; ST(LD(b + 8u) - LD(b - 8u)); }\n";

// Switch control segment hash (first 16 hex digits of sha256(0x880 bytes of the control segment)) -> kernel name
static const struct { const char *ctl; const char *fn; } k_nvn_builtin_map[] = {
    {"d0f769bb916bbba9", "q_val0"},
    {"16479cc6d75c2b28", "q_val8"},
    {"0687e2ef95133577", "q_dlt0"},
    {"4df5909e6dabee05", "q_dlt8"},
};

// S2Arm tessellation: 固定曲面细分核（count / scan / emit），从 graphics/metal/gal_tess_d3d.h（D3D11参照细分器）嵌入。
// Makefile 用 tools/embed_msl.py 把 ../../../graphics/metal/gal_tess_d3d.h 编成 $(OUT)/gen/gal_tess_msl.h（C字符串常量 k_nvn_tess_core），
// 本文件 include 它，再包一层三个核函数（count/scan/emit）成 k_nvn_tess_msl。直连侧不引入 graphics/metal 头文件（避免依赖NXGAL），CHWTessellator MSL内嵌
#include "gal_tess_msl.h"
// k_nvn_tess_core 由上面 include 提供，是 gal_tess_d3d.h 的完整 CHWTessellator 实现（2342行）；下面包一层三个核函数
static const char k_nvn_tess_wrapper[] =
    // 拼在 k_nvn_tess_core（细分器自带 TS_* 宏与 TS_POINT）之后，同 graphics/metal/gal_tess.m 的 k_tess_kernels
    "struct S2ATessP { uint npatch, dom, part, prim, pt_cap, ix_cap, fstride, pad; };\n"
    "static void s2a_ts_run(thread CHWTessellator& t, constant S2ATessP& p, device const uchar* fac, uint pid) {\n"
    "    PIPE_TESSELLATOR_PARTITIONING part = p.part == 2u ? PIPE_TESSELLATOR_PARTITIONING_FRACTIONAL_ODD : p.part == 3u ? PIPE_TESSELLATOR_PARTITIONING_FRACTIONAL_EVEN : PIPE_TESSELLATOR_PARTITIONING_INTEGER;\n"
    "    t.Init(part, (PIPE_TESSELLATOR_OUTPUT_PRIMITIVE)p.prim);\n"
    "    device const half* f = (device const half*)(fac + ulong(pid) * p.fstride);\n"
    "    if (p.dom == 3u) t.TessellateQuadDomain(float(f[0]), float(f[1]), float(f[2]), float(f[3]), float(f[4]), float(f[5]));\n"
    "    else if (p.dom == 2u) t.TessellateTriDomain(float(f[0]), float(f[1]), float(f[2]), float(f[3]));\n"
    "    else t.TessellateIsoLineDomain(float(f[0]), float(f[1]));\n"
    "}\n"
    "kernel void nvn_tess_count(constant S2ATessP& p [[buffer(0)]], device const uchar* fac [[buffer(1)]], device uint2* cnt [[buffer(2)]], uint pid [[thread_position_in_grid]]) {\n"
    "    if (pid >= p.npatch) return;\n"
    "    CHWTessellator t; t.SetOutput(nullptr, nullptr, 0u, 0u, pid, p.dom == 2u); s2a_ts_run(t, p, fac, pid);\n"
    "    cnt[pid] = uint2(uint(t.GetPointCount()), uint(t.GetIndexCount()));\n"
    "}\n"
    "kernel void nvn_tess_scan(constant S2ATessP& p [[buffer(0)]], device uint2* cnt [[buffer(2)]], device uint2* off [[buffer(3)]], device atomic_uint* args [[buffer(4)]],\n"
    "                          uint t [[thread_index_in_threadgroup]], uint nt [[threads_per_threadgroup]]) {\n"
    // 前缀和与容量比较用 64 位（同 graphics/metal/gal_tess.m s2a_tess_scan，审计 P0-6）：直连片数可到约 46 万（256 MB / 576），满因子每片 24576 索引，
    //   uint32 在约 17.5 万片处折返、判成放得下、按越界 off 写出点 / 索引缓冲；放得下的片前缀 ≤ 容量，截回 32 位无损
    "    threadgroup ulong2 s[1024];\n"
    "    uint n = p.npatch, per = (n + nt - 1u) / nt, b = min(t * per, n), e = min(b + per, n);\n"
    "    ulong2 sum = ulong2(0ul); for (uint i = b; i < e; i++) sum += ulong2(cnt[i]);\n"
    "    s[t] = sum; threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    for (uint d = 1u; d < nt; d <<= 1) { ulong2 v = t >= d ? s[t - d] : ulong2(0ul); threadgroup_barrier(mem_flags::mem_threadgroup); s[t] += v; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    if (t == nt - 1u) { atomic_store_explicit(&args[0], uint(min(s[t].y, ulong(p.ix_cap))), memory_order_relaxed); atomic_store_explicit(&args[1], 1u, memory_order_relaxed);\n"
    "        atomic_store_explicit(&args[2], 0u, memory_order_relaxed); atomic_store_explicit(&args[3], 0u, memory_order_relaxed); atomic_store_explicit(&args[4], 0u, memory_order_relaxed); }\n"
    "    threadgroup_barrier(mem_flags::mem_device);\n"
    "    ulong2 base = s[t] - sum; bool dropped = false;\n"
    "    for (uint i = b; i < e; i++) {\n"
    "        ulong2 c = ulong2(cnt[i]); off[i] = uint2(base);\n"
    "        if (base.x + c.x > ulong(p.pt_cap) || base.y + c.y > ulong(p.ix_cap)) { if (!dropped) atomic_fetch_min_explicit(&args[0], uint(min(base.y, ulong(p.ix_cap))), memory_order_relaxed); dropped = true; cnt[i] = uint2(0u); }\n"
    "        base += c;\n"
    "    }\n"
    "}\n"
    "kernel void nvn_tess_emit(constant S2ATessP& p [[buffer(0)]], device const uchar* fac [[buffer(1)]], device const uint2* cnt [[buffer(2)]], device const uint2* off [[buffer(3)]],\n"
    "                          device TS_POINT* pts [[buffer(5)]], device uint* idx [[buffer(6)]], uint pid [[thread_position_in_grid]]) {\n"
    "    if (pid >= p.npatch) return;\n"
    "    uint2 c = cnt[pid]; if (c.x == 0u && c.y == 0u) return;\n"
    "    CHWTessellator t; t.SetOutput(pts, idx, off[pid].x, off[pid].y, pid, p.dom == 2u); s2a_ts_run(t, p, fac, pid);\n"
    "}\n"
    // VS 前置段的搬运核：顶点着色器的捕获入口（main0_gs，dmsh_geometry.py capture）把每顶点写成 144 字的捕获记录；TCS（gal_tessxc.m 翻的计算核）按「规范布局」
    // 读控制点（gal_tess_canon：通用位置 L 在字节 16L、gl_Position 512、gl_PointSize 528、gl_ClipDistance 544，每控制点 576 字节）。两者都是 576 字节但排布不同，
    // 且索引绘制下第 i 个控制点在捕获里的位置是 map[i] = 索引[i] − lo（照 nvn_geometry.inc geo_draw）。本核一个线程搬一个控制点：按映射取、按规范排布写。
    // 线程 t = 实例 k × vp + 控制点 i；捕获里实例 k 的记录从 k × span 起（main0_gs：(iid − first_instance) × span + vid − first）
    "struct S2ATessGatherP { uint vp, span, inst, pad; };\n"
    "kernel void nvn_tess_gather(constant S2ATessGatherP& g [[buffer(0)]], device const uint* cap [[buffer(1)]], device const uint* map [[buffer(2)]], device uint* out [[buffer(3)]],\n"
    "                            uint t [[thread_position_in_grid]]) {\n"
    "    if (t >= g.vp * g.inst) return;\n"
    "    uint i = t % g.vp, k = t / g.vp;\n"
    "    device const uint* s = cap + (ulong(k) * g.span + map[i]) * 144ul;\n"
    "    device uint* d = out + ulong(t) * 144ul;\n"
    "    for (uint w = 0u; w < 128u; w++) d[w] = s[16u + w];\n"      // 通用位置 0–31：捕获字 16+4L → 规范字 4L
    "    d[128] = s[0]; d[129] = s[1]; d[130] = s[2]; d[131] = s[3];\n"   // gl_Position
    "    d[132] = s[4]; d[133] = 0u; d[134] = 0u; d[135] = 0u;\n"         // gl_PointSize 与补位
    "    for (uint c = 0u; c < 8u; c++) d[136u + c] = s[5u + c];\n"       // gl_ClipDistance[8]
    "}\n";
// ---- VS 前置段的接口常量与纯 C 规划（nvn_mtl.m tess_draw 与 tests/t_tess_vsfront.m 共用同一份）----
#define NVN_TESS_CAP_WORDS 144u        // 捕获记录每顶点字数（dmsh_geometry.py WORDS）
#define NVN_TESS_CP_BYTES 576u         // 规范布局每控制点字节数（gal_internal.h GAL_TESS_CP_BYTES）
#define NVN_TESS_PATCH_BYTES 512u      // 规范布局每片属性字节数（gal_internal.h GAL_TESS_PATCH_BYTES）
#define NVN_TESS_FLAG_PATCH (1u << 11) // 变体 flags 位 11：TCS 写每片属性（gal_internal.h GAL_REC_PATCH）
typedef struct { uint32_t vp, span, inst, pad; } nvn_tess_gather_p;   // 同 MSL 的 S2ATessGatherP
// 域编码同离线 dmsh_build.py TESS_DOM（寄存器 TessMode 位 0–1）：0 等值线、1 三角、2 四边形；细分核读 dom+1
static inline const char *nvn_tess_dom_name(uint32_t dom) { return dom == 0 ? "isolines" : dom == 1 ? "triangles" : "quads"; }
// 曲面因子缓冲每片字节数：SPIRV-Cross 的 MTLTriangleTessellationFactorsHalf（3 外 + 1 内 half = 8）/ MTLQuadTessellationFactorsHalf（4 外 + 2 内 half = 12）。
//   等值线按四边形 12 字节（审计 P0-4）：Metal 没有等值线域，gal_tessxc.m 翻译前把 Isolines 换成 Quads，TCS 按 12 字节一片写；细分核只读前两个 half
static inline uint32_t nvn_tess_fstride(uint32_t dom) { return dom == 1 ? 8u : 12u; }
// TCS 派发（nvn_mtl.m tess_draw，同 gal_tess.m）：一个线程组装整数个片（TCS 里的 barrier 只在片内同步），每组 per = 32 / N 片、per × N 线程；
//   总线程数正好 Pt × N、按线程数派发（最后一组不补满，审计 P0-5）：多片工作组的核只把输入与 gl_PrimitiveID 夹到最后一片，补出来的线程照写控制点 / 每片输出
static inline void nvn_tess_tcs_grid(uint32_t N, uint64_t Pt, uint64_t *threads, uint32_t *group) { *group = (N >= 32 ? 1 : 32 / N) * N; *threads = Pt * N; }
// 计数 / 写出两个核的派发规划（审计 1101 18:00 P1-42，同通用层 gal_tess.m）：每片一个线程，线程数 = 片数、组宽 64，最后一组不补满（nvn_mtl.m enc_c_dispatch_threads）。
//   原先按组派发「组数 = 片数、每组 64 线程」：核里 pid ≥ npatch 直接返回，结果不变，但网格是片数的 64 倍（10 万片派 10 万组，有活的约 1600 组）
static inline void nvn_tess_patch_grid(uint64_t Pt, uint64_t *threads, uint32_t *group) { *group = 64; *threads = Pt; }
static inline int nvn_tess_cmp_u32(const void *a, const void *b) { uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b; return (x > y) - (x < y); }
// 索引绘制的控制点规划（照 nvn_geometry.inc geo_draw 150–205 行）：ib 是 CPU 可读的索引数据（count 个、每个 isz 字节，可不对齐），
//   map[i] = 索引[i] − lo（第 i 个控制点在捕获里的位置），unique 排序去重后是捕获遍要画的顶点表（*nu 个）。
// 曲面片不认图元重启（GL 4.6 §10.3.6：PATCHES 忽略重启索引），索引一律当顶点号。返回 0 = 索引宽度非法或 count 为 0
static inline int nvn_tess_index_plan(const uint8_t *ib, int isz, uint32_t count, uint32_t *map, uint32_t *unique, uint32_t *nu, uint32_t *lo, uint32_t *hi) {
    if ((isz != 1 && isz != 2 && isz != 4) || !count) return 0;
    uint32_t l = UINT32_MAX, h = 0;
    for (uint32_t i = 0; i < count; i++) { uint32_t v = 0; memcpy(&v, ib + (size_t)i * isz, isz); map[i] = v; unique[i] = v; if (v < l) l = v; if (v > h) h = v; }
    qsort(unique, count, 4, nvn_tess_cmp_u32);
    uint32_t n = 0; for (uint32_t i = 0; i < count; i++) if (!i || unique[i] != unique[i - 1]) unique[n++] = unique[i];
    for (uint32_t i = 0; i < count; i++) map[i] -= l;
    *nu = n; *lo = l; *hi = h; return 1;
}
#ifdef __OBJC__
// 细分核完整 MSL（生产 tess_init 与单测共用一份拼法，同 graphics/metal/gal_tess.m）：头 + 细分器（定义 CHWTessellator 与 TS_* 宏）+ 三个核；按 UTF-8 拼（源码有中文注释）
static inline NSString *nvn_tess_msl(void) {
    NSMutableString *msl = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"];
    [msl appendString:@(k_nvn_tess_core)]; [msl appendString:@"\n"]; [msl appendString:@(k_nvn_tess_wrapper)];
    return msl;
}
#endif

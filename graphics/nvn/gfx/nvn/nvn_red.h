// Sampler emulation in the shader (#800, audit gap family 31): what a Metal sampler cannot do for an NVN one. graphics/metal/gal_samp_caps.h tells what this GPU does natively; the shader side
//   is S2A.Dsh FsLb / FsRd (graphics/tools/direct/dsh/Dsh.cs).
//   LOD bias: every pixel / compute shader adds it itself, sample and sample_compare alike, from its argument buffer's s2a_lb table (one float per sampler member at that member's id;
//     nvn_mtl.m lb_fill writes the sampler's lod_bias where the GPU ignores a sampler's bias, 0 where the sampler applies it). Not here: the table is a plain float.
//   Everything else runs in the shader's emulation variant <key>_se (made on the device at its first such use, in the background, main0 until it is ready: nvn_mtl.m se_want / se_kick),
//     pipelines keyed apart by SE_RD (pso_key.fc), given one table entry per sampler member at the member's argument id (nvn_mtl.m se_bind; MSL struct S2ASe, 64 bytes):
//     [0] = (reduction 0 none / 1 min / 2 max, Metal address mode s, t, custom border 0 / 1), [1] = (LOD clamp min, max, filters, LOD bias s2a_rs adds), [2] = border colour,
//     then two sampler handles: the sampler with a transparent black border, the same with an opaque white one (custom border only, nvn_mtl.m samp_border_rid).
//     - min / max reduction where the GPU has none natively (not Apple10 / before 26): s2a_rs reduces the footprint itself at explicit LODs, every filter combination (filters
//       [1].z = min linear 1 + mag linear 2 + mip mode × 4 (0 none, 1 nearest, 2 linear)). Measured on an M5 Max (macOS 26.4.1, 11-01): Metal 26's native reductionMode honours
//       nearest and mixed min / mag / mip filters too (all 12 combinations equal the footprint definition below), so the native path sets it with the sampler's own filters
//     - a border colour Metal does not have (none of transparent black / opaque black / opaque white, with a clamp-to-border wrap, not a compare sampler): on every GPU. Filtering is
//       linear in the border colour (result = Σ in-range weights × texels + border weight W × colour), so s2a_bs samples twice, transparent black (W × 0) and opaque white (W × 1),
//       and mixes: a + (b − a) × colour, exact for any filter, anisotropy, LOD form (graphics/metal/gal_border.m does the same for the generic path)
// A zero entry makes the shader take its own sample, bit for bit: a sampler of the draw that needs nothing. [1].w is the sampler's bias whether or not the GPU applies it: s2a_rs reads
// texels, which no sampler bias reaches.
// No header beyond string.h / stdint.h: the unit test (graphics/nvn/tests/t_red_run.m) includes it alone
#pragma once
#include <stdint.h>
#include <string.h>

enum { SE_RD = 2 };   // pso_key.fc of a pipeline whose fragment is the emulation variant (nvn_mtl.m se_need); 0 = the library's main0
typedef struct { float q[12]; uint64_t s0, s1; } nvn_se_ent;   // = S2ASe (Dsh.cs RedHelp): float4 m, l, c; sampler s0, s1 (MTLResourceID)
_Static_assert(sizeof(nvn_se_ent) == 64, "nvn_se_ent is S2ASe: 3 float4 + 2 sampler handles");

// NVN wrap mode → MTLSamplerAddressMode value (0 clamp to edge, 1 mirror clamp to edge, 2 repeat, 3 mirror repeat, 5 clamp to border colour); the one table (nvn_mtl.m wrapm calls it).
//   4 MIRROR_CLAMP_TO_BORDER: Metal has no mirror-then-border; mirror clamp to edge keeps the mirrored half (clamp to border lost it: the whole [-1, 0] read the border colour)
//   and differs only past |1| (edge texels where the border colour belongs; audit gap family 31)
static inline int nvn_samp_wrap(int w) {
    switch (w) { case 0: case 7: return 0; case 1: return 2; case 2: case 3: case 4: return 1; case 5: return 5; case 6: return 3; }
    return 2;
}
// NVN border colour → MTLSamplerBorderColor value (0 transparent black, 1 opaque black, 2 opaque white), the only three Metal has: the one grading (the Metal sampler, samp_desc, and
//   the emulation, nvn_red_entry). *exact (may be NULL) = the colour is that one exactly (else the emulation takes it, nvn_samp_border_custom). An integer border colour
//   (SetBorderColori / ui, hle_nvn.c) is kept as floats of its values and graded the same
static inline int nvn_samp_border(const float b[4], int *exact) {
    int m = b[3] > 0.5f ? (b[0] > 0.5f ? 2 : 1) : 0;
    if (exact) { float v = m == 2 ? 1.0f : 0.0f, a = m ? 1.0f : 0.0f; *exact = b[0] == v && b[1] == v && b[2] == v && b[3] == a; }
    return m;
}
// The border colour is reached (a clamp-to-border wrap) and is none of Metal's three: the variant mixes it (s2a_bs). Compare samplers keep the graded one: a compare is not linear
//   in the border depth (the result is 0 or 1 per texel), and the graded R is already exact for a border depth of 0 or 1
static inline int nvn_samp_border_custom(int ws, int wt, int wr, int cmp_mode, const float border[4]) {
    int exact; nvn_samp_border(border, &exact);
    return (ws == 5 || wt == 5 || wr == 5) && !cmp_mode && !exact;
}
// A min / max sampler whose footprint can hold more than one texel: anything but a nearest magnification with a nearest minification that has no or a nearest mip filter
//   (NVN minf 0 / 2, magf 0: one texel, min / max of it = the plain sample, so the entry stays zero)
static inline int nvn_red_reduces(int reduction, int minf, int magf) { return (reduction == 1 || reduction == 2) && (magf || (minf != 0 && minf != 2)); }
// The variant's table entry of one sampler (the samp_par fields it reads; s0 / s1 are the host's, see nvn_mtl.m se_bind). red_native: this GPU reduces natively (the sampler carries
//   it, the entry does not reduce; a custom border is then not mixed either: min / max is not linear in the border colour, nvn_mtl.m reports it). → nonzero = the entry is not zero
static inline int nvn_red_entry(int red_native, int reduction, int minf, int magf, int ws, int wt, int wr, int cmp_mode, float lod_min, float lod_max, float lod_bias,
                                const float border[4], nvn_se_ent *e) {
    memset(e, 0, sizeof *e);
    int red = !red_native && nvn_red_reduces(reduction, minf, magf), bc = nvn_samp_border_custom(ws, wt, wr, cmp_mode, border) && !(red_native && (reduction == 1 || reduction == 2));
    if (!red && !bc) return 0;
    float *q = e->q;
    q[0] = red ? (float)reduction : 0.0f; q[1] = (float)nvn_samp_wrap(ws); q[2] = (float)nvn_samp_wrap(wt); q[3] = bc ? 1.0f : 0.0f;
    int mip = minf <= 1 ? 0 : minf <= 3 ? 1 : 2;   // NVN minf 0 nearest / 1 linear, 2 / 3 mip nearest, 4 / 5 mip linear
    q[4] = lod_min < 0 ? 0.0f : lod_min; q[5] = lod_max; q[6] = (float)((minf & 1) + (magf ? 2 : 0) + 4 * mip); q[7] = lod_bias;
    if (bc) memcpy(q + 8, border, 16);
    else { int g = nvn_samp_border(border, NULL); q[8] = q[9] = q[10] = g == 2 ? 1.0f : 0.0f; q[11] = g ? 1.0f : 0.0f; }   // the colour the Metal sampler has (a compare sampler's)
    return 1;
}

// 折行贴图（11-03 Nintendo Switch Sports：字库是 1024×32768 R8 线性 2D 贴图，CPU 写字形，高超 Metal 2D 上限 16384，1b9eeb403 起不建、菜单文字全空）：
//   宿主把 k = ⌈H / 上限⌉ 行逻辑纹素折成一行，在池缓冲上原地建 ((k − 1)·P + W) × ⌈H/k⌉ 的线性贴图（行距 = k × 原行距，零拷贝，CPU 写照样看得见；
//   P = 原行距折成纹素数，行距里有补齐时 P > W），逻辑纹素 (x, y) 落在 (x + (y % k)·P, y / k)。折后宽也要在上限内，否则返回 0（不折，照旧报超限）。k = 1：不用折
static inline int nvn_fold_k(uint32_t w, uint32_t h, uint32_t pitch, uint32_t lim) {
    if (h <= lim) return 1;
    uint32_t k = (h + lim - 1) / lim;
    return w && pitch >= w && (uint64_t)(k - 1) * pitch + w <= lim && (h + k - 1) / k <= lim ? (int)k : 0;
}
// 读折行贴图的采样器的表项（S2A.Dsh RedHelp s2a_fx / s2a_ff）：m = (0 不归约, 寻址 s, 寻址 t, P)，l = (LOD 下限, 上限, 16 + 过滤, 着色器自己要加的采样器偏置)，
//   c = (W, H, k, Metal 最近的边界色档 0 透明黑 / 1 不透明黑 / 2 不透明白)。l.z ≥ 16 是折行标记（过滤编码同 nvn_red_entry，最大 11），变体先认它、不再看 m.w。
//   bias_in_shader：采样参数里已经带了采样器偏置（本机不原生吃偏置时 FsLb 从 s2a_lb 加进去，nvn_mtl.m g_lb_emu）就填 0，免得加两遍。自定义边界色退到最近的一档
static inline void nvn_se_fold(int minf, int magf, int ws, int wt, float lod_min, float lod_max, float lod_bias, int bias_in_shader, const float border[4],
                               uint32_t w, uint32_t h, uint32_t pitch, int k, nvn_se_ent *e) {
    memset(e, 0, sizeof *e);
    float *q = e->q; int mip = minf <= 1 ? 0 : minf <= 3 ? 1 : 2;
    q[1] = (float)nvn_samp_wrap(ws); q[2] = (float)nvn_samp_wrap(wt); q[3] = (float)pitch;
    q[4] = lod_min < 0 ? 0.0f : lod_min; q[5] = lod_max; q[6] = (float)(16 + (minf & 1) + (magf ? 2 : 0) + 4 * mip); q[7] = bias_in_shader ? 0.0f : lod_bias;
    q[8] = (float)w; q[9] = (float)h; q[10] = (float)k; q[11] = (float)nvn_samp_border(border, NULL);
}

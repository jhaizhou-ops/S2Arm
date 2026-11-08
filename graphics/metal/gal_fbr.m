// GAL：片元帧缓冲读取（画面·着色器线，10-21）——翻译期证明「这张贴图的每次采样都落在当前像素」，运行时按渲染器给的映射出改读 [[color(n)]] 的变体程序。
// 渲染器侧（gal_draw.m fbfetch_variant，帧率能耗线）在 TextureBarrier 挂起、本次绘制又采样本遍颜色附件时判运行时条件，然后调 gal_prog_fbfetch；
// 拿到变体就不拆渲染通道（TBDR 上附件还在片上，原做法整张存回再读入：塞尔达每帧 4.6 次约 81 MB）。
//
// 证明（建程序时，顶点 + 片元两支 SPIR-V 同时在手，gal_fbr_prove）：
//   ① 片元：对按绑定号认出的组合贴图采样器（2D、非数组、非多重采样、非深度），所有读纹素的指令都是 ImageSampleImplicitLod（无图像操作数）
//      或 ImageSampleExplicitLod（只带 Lod 且为常量 0），坐标两个分量形如 in.locK.c ÷ in.locK.w（或 × (1 ÷ w)），可再 ÷ / × 一个缩放因子
//      S = select(位, X, 1.0)，位 = 常量缓冲某个 32 位字的第 k 位（Ryujinx 0044 补丁 s2a_flags.z「片元阶段贴图非归一化位图」）。
//      S 只在该位为 0 时等于 1：记下（常量缓冲绑定号、字节偏移、位号），运行时读常量缓冲当前内容判（读不到 / 位为 1 就不给变体）。
//      其余对这张贴图的用法只许取尺寸 / 级数 / 采样数 / 查询 LOD（不读纹素；变体里原贴图照旧绑着，这些查询语义不变）；别的用法一律证不出。
//      Ryujinx 的坐标外面还包一层 select(isnan(c), 0, c)：当前像素的坐标不会是 NaN（光栅化出的片元 w > 0），认作 c。
//      locK 输入不许 Flat / NoPerspective / Sample / Component（透视校正插值下 (a/w) 才是屏幕位置）。
//   ② 顶点：locK 输出最终写入的值为 ((x+w)·0.5, (w∓y)·0.5, *, w)，x / y / w 与 gl_Position 最终写入的 x / y / w 是同一个值（数据流追到同一 SSA）。
//      x 只认 (x+w)；y 记符号：(w−y) 只在 ydown = 0（翻转视口）时是当前像素，(w+y) 只在 ydown = 1 时是。
//   Ryujinx 的 SPIR-V 不是 SSA 形式：中间值都经函数局部变量 Store / Load。追值规则（保守）：变量只被 Load / Store / AccessChain（常量下标）用过；
//   读到的值 = 支配这次读的那条写，且其余写都严格在它之前（支配它、或同块在前），它所在块不在环上；输出的最终值 = 这样一条写且它支配所有返回块。
//   证不出就什么都不留（gal_prog.fbr = NULL）；证得出才留片元 SPIR-V 的拷贝（内存只花在这几支上）。
//
// 变体（gal_prog_fbfetch，按（程序、绑定 → 槽映射、ydown）缓存，失败也记住不重试）：
//   SPIR-V 层每个目标槽加一个 SubpassData 输入附件变量（InputAttachmentIndex = 槽号，取样类型同原贴图），对目标贴图的采样改成 OpImageRead（坐标填 0）；
//   原贴图变量保留（取尺寸等查询照旧，参数缓冲布局不变）。SPIRV-Cross 开 framebuffer_fetch_subpass 译成 [[color(n)]]（输入类型 = 原取样类型：
//   采样合法时它与附件格式的基本类型一致）。变体是独立 gal_prog（片元阶段键 = 改写后 SPIR-V 的键，管线缓存分开）。
//   异步现编（缺省）下首次只起作业、返回 NULL（这次照旧拆遍），编好后的绘制拿变体；设备不支持帧缓冲读取、多重采样附件一律 NULL。
#import "gal_internal.h"
#import "gal_draw_internal.h"
#include <stdlib.h>
#include <string.h>
#define SPV_ENABLE_UTILITY_CODE
#define inline static inline
#include "spirv.h"
#undef inline

GAL_MTL4_ZONE_BEGIN

// ---------- SPIR-V 模块索引 ----------
enum { F_FLAT = 1, F_NOPERSP = 2, F_SAMPLE = 4, F_COMP = 8, F_PATCH = 16, F_POS = 32 };
typedef struct { uint32_t off, root, np, p[4], val; int blk, dyn; } sst;
typedef struct { uint32_t s, m, kind, v; } smd;
typedef struct {
    const uint32_t *w; uint32_t n, bound, ver;
    uint32_t *def, *loc, *flag, *bind, *dset;
    smd *md; int nmd, capmd;
    uint32_t entry, model, fn0, fn1;
    int nb, capb; uint32_t *bstart, *bend; int *sbeg, *scnt, *succ, nsucc, capsucc; uint32_t *slab;
    int *idom, *rpo; int8_t *cyc; uint8_t *ret; uint32_t *lab;
    uint32_t *root; uint8_t *dirty, *stored;
    sst *st; int nst, capst;
} spm;

static void spm_free(spm *m) {
    free(m->def); free(m->loc); free(m->flag); free(m->bind); free(m->dset); free(m->md);
    free(m->bstart); free(m->bend); free(m->sbeg); free(m->scnt); free(m->succ); free(m->slab);
    free(m->idom); free(m->rpo); free(m->cyc); free(m->ret); free(m->lab); free(m->root); free(m->dirty); free(m->stored); free(m->st);
    memset(m, 0, sizeof *m);
}
static uint32_t op_at(const spm *m, uint32_t off) { return m->w[off] & 0xffff; }
static uint32_t wc_at(const spm *m, uint32_t off) { return m->w[off] >> 16; }
static uint32_t D(const spm *m, uint32_t id) { return id < m->bound ? m->def[id] : 0; }
static int is_term(uint32_t op) {
    return op == SpvOpBranch || op == SpvOpBranchConditional || op == SpvOpSwitch || op == SpvOpReturn || op == SpvOpReturnValue
        || op == SpvOpKill || op == SpvOpUnreachable || op == SpvOpTerminateInvocation;
}
// 常见指令里的字面量字（不是 id）：用法扫描跳过它们，免得字面量恰好等于某个 id 被误当成用法（误判只会偏保守，这里减少误判）
static int lit_word(uint32_t op, uint32_t k, uint32_t wc) {
    switch (op) {
    case SpvOpExtInst: return k == 4;
    case SpvOpCompositeExtract: return k >= 4;
    case SpvOpCompositeInsert: return k >= 5;
    case SpvOpVectorShuffle: return k >= 5;
    case SpvOpSelectionMerge: return k >= 2;
    case SpvOpLoopMerge: return k >= 3;
    case SpvOpSwitch: return k >= 3 && (k & 1);
    case SpvOpBranchConditional: return k >= 4;
    case SpvOpLoad: return k >= 4;
    case SpvOpStore: return k >= 3;
    case SpvOpLine: return k >= 2;
    case SpvOpImageSampleImplicitLod: case SpvOpImageSampleExplicitLod: case SpvOpImageSampleDrefImplicitLod: case SpvOpImageSampleDrefExplicitLod:
    case SpvOpImageFetch: case SpvOpImageRead: case SpvOpImageGather: case SpvOpImageDrefGather:
        return k == ((op == SpvOpImageSampleDrefImplicitLod || op == SpvOpImageSampleDrefExplicitLod || op == SpvOpImageGather || op == SpvOpImageDrefGather) ? 6u : 5u);
    default: (void)wc; return 0;
    }
}
static void add_succ(spm *m, uint32_t lab) {
    if (m->nsucc == m->capsucc) { m->capsucc = m->capsucc ? m->capsucc * 2 : 256; m->slab = realloc(m->slab, m->capsucc * sizeof *m->slab); }
    m->slab[m->nsucc++] = lab; m->scnt[m->nb - 1]++;
}

// 指针 → (根变量, 常量下标路径)；下标不是常量 → dyn
static int loc_of(const spm *m, uint32_t id, uint32_t *root, uint32_t *np, uint32_t p[4], int *dyn, int depth) {
    uint32_t d = D(m, id); if (!d || depth > 8) return 0;
    uint32_t op = op_at(m, d);
    if (op == SpvOpVariable) { *root = id; *np = 0; *dyn = 0; return 1; }
    if (op != SpvOpAccessChain && op != SpvOpInBoundsAccessChain) return 0;
    if (!loc_of(m, m->w[d + 3], root, np, p, dyn, depth + 1)) return 0;
    for (uint32_t k = d + 4; k < d + wc_at(m, d); k++) {
        uint32_t c = D(m, m->w[k]);
        if (*np == 4) return 0;
        if (c && op_at(m, c) == SpvOpConstant && wc_at(m, c) == 4) p[(*np)++] = m->w[c + 3];
        else { *dyn = 1; p[(*np)++] = 0; }
    }
    return 1;
}

static int spm_parse(spm *m, const uint32_t *w, uint32_t n) {
    memset(m, 0, sizeof *m);
    if (n < 5 || w[0] != SpvMagicNumber || w[3] > (1u << 22)) return 0;
    m->w = w; m->n = n; m->ver = w[1]; m->bound = w[3];
    uint32_t B = m->bound;
    m->def = calloc(B, 4); m->loc = calloc(B, 4); m->flag = calloc(B, 4); m->bind = calloc(B, 4); m->dset = calloc(B, 4);
    m->lab = calloc(B, 4); m->root = calloc(B, 4); m->dirty = calloc(B, 1); m->stored = calloc(B, 1);
    int nentry = 0, in_entry = 0, in_fn = 0;
    for (uint32_t i = 5; i < n; ) {
        uint32_t wc = w[i] >> 16, op = w[i] & 0xffff;
        if (!wc || i + wc > n) return 0;
        bool hr = false, ht = false; SpvHasResultAndType((SpvOp)op, &hr, &ht);
        if (hr) { uint32_t r = w[i + (ht ? 2 : 1)]; if (r >= B) return 0; m->def[r] = i; }
        if (op == SpvOpEntryPoint) { nentry++; m->model = w[i + 1]; m->entry = w[i + 2]; }
        else if (op == SpvOpDecorate && wc >= 3 && w[i + 1] < B) {
            uint32_t t = w[i + 1], dc = w[i + 2], v = wc >= 4 ? w[i + 3] : 0;
            if (dc == SpvDecorationLocation) m->loc[t] = v + 1;
            else if (dc == SpvDecorationBinding) m->bind[t] = v + 1;
            else if (dc == SpvDecorationDescriptorSet) m->dset[t] = v + 1;
            else if (dc == SpvDecorationFlat) m->flag[t] |= F_FLAT;
            else if (dc == SpvDecorationNoPerspective) m->flag[t] |= F_NOPERSP;
            else if (dc == SpvDecorationSample) m->flag[t] |= F_SAMPLE;
            else if (dc == SpvDecorationComponent) m->flag[t] |= F_COMP;
            else if (dc == SpvDecorationPatch) m->flag[t] |= F_PATCH;
            else if (dc == SpvDecorationBuiltIn && v == SpvBuiltInPosition) m->flag[t] |= F_POS;
        } else if (op == SpvOpMemberDecorate && wc >= 5) {
            if (m->nmd == m->capmd) { m->capmd = m->capmd ? m->capmd * 2 : 64; m->md = realloc(m->md, m->capmd * sizeof *m->md); }
            m->md[m->nmd++] = (smd){w[i + 1], w[i + 2], w[i + 3], w[i + 4]};
        } else if (op == SpvOpFunction) { in_fn = 1; if (w[i + 2] == m->entry) { in_entry = 1; m->fn0 = i; } }
        else if (op == SpvOpFunctionEnd) { if (in_entry) m->fn1 = i; in_entry = 0; in_fn = 0; }
        if (op == SpvOpVariable) m->root[w[i + 2]] = w[i + 2];
        else if ((op == SpvOpAccessChain || op == SpvOpInBoundsAccessChain) && w[i + 3] < B && m->root[w[i + 3]]) m->root[w[i + 2]] = m->root[w[i + 3]];
        // 指针的非常规用法（传进函数、原子、拷内存、存指针本身……）：根变量记脏，追值时不信它
        if (in_fn && op != SpvOpVariable && op != SpvOpLoad && op != SpvOpAccessChain && op != SpvOpInBoundsAccessChain && op != SpvOpFunction) {
            uint32_t k0 = op == SpvOpStore ? 2 : 1;
            for (uint32_t k = k0; k < wc; k++) if (!lit_word(op, k, wc) && w[i + k] < B && m->root[w[i + k]]) m->dirty[m->root[w[i + k]]] = 1;
        }
        if (in_entry && op == SpvOpLabel) {
            if (m->nb == m->capb) {
                m->capb = m->capb ? m->capb * 2 : 64;
                m->bstart = realloc(m->bstart, m->capb * 4); m->bend = realloc(m->bend, m->capb * 4);
                m->sbeg = realloc(m->sbeg, m->capb * sizeof(int)); m->scnt = realloc(m->scnt, m->capb * sizeof(int));
                m->ret = realloc(m->ret, m->capb);
            }
            m->bstart[m->nb] = i; m->bend[m->nb] = i; m->sbeg[m->nb] = m->nsucc; m->scnt[m->nb] = 0; m->ret[m->nb] = 0; m->nb++;
            m->lab[w[i + 1]] = (uint32_t)m->nb;
        } else if (in_entry && m->nb && is_term(op)) {
            m->bend[m->nb - 1] = i;
            if (op == SpvOpBranch) add_succ(m, w[i + 1]);
            else if (op == SpvOpBranchConditional) { add_succ(m, w[i + 2]); add_succ(m, w[i + 3]); }
            else if (op == SpvOpSwitch) { add_succ(m, w[i + 2]); for (uint32_t k = i + 4; k < i + wc; k += 2) add_succ(m, w[k]); }
            else if (op == SpvOpReturn || op == SpvOpReturnValue) m->ret[m->nb - 1] = 1;
        }
        i += wc;
    }
    if (nentry != 1 || !m->fn0 || !m->fn1 || !m->nb) return 0;
    m->succ = malloc((m->nsucc + 1) * sizeof(int));
    for (int k = 0; k < m->nsucc; k++) { uint32_t L = m->slab[k] < B ? m->lab[m->slab[k]] : 0; if (!L) return 0; m->succ[k] = (int)L - 1; }
    // 支配树（Cooper–Harvey–Kennedy；入口块 = 函数第一个块）
    int nb = m->nb; int *order = malloc(nb * sizeof(int)), *stk = malloc(nb * sizeof(int)), *it = calloc(nb, sizeof(int)); uint8_t *seen = calloc(nb, 1);
    m->rpo = malloc(nb * sizeof(int)); m->idom = malloc(nb * sizeof(int)); m->cyc = malloc(nb);
    for (int b = 0; b < nb; b++) { m->rpo[b] = -1; m->idom[b] = -1; m->cyc[b] = -1; }
    int no = 0, sp = 0; stk[sp++] = 0; seen[0] = 1;
    while (sp) {
        int b = stk[sp - 1];
        if (it[b] < m->scnt[b]) { int s = m->succ[m->sbeg[b] + it[b]++]; if (!seen[s]) { seen[s] = 1; stk[sp++] = s; } }
        else { order[no++] = b; sp--; }
    }
    for (int k = 0; k < no; k++) m->rpo[order[k]] = no - 1 - k;
    int *byr = malloc(no * sizeof(int)); for (int k = 0; k < no; k++) byr[no - 1 - k] = order[k];
    int *pc = calloc(nb, sizeof(int)), *pb = calloc(nb + 1, sizeof(int)), *pl = malloc((m->nsucc + 1) * sizeof(int));
    for (int b = 0; b < nb; b++) for (int k = 0; k < m->scnt[b]; k++) pc[m->succ[m->sbeg[b] + k]]++;
    for (int b = 0; b < nb; b++) pb[b + 1] = pb[b] + pc[b];
    memset(pc, 0, nb * sizeof(int));
    for (int b = 0; b < nb; b++) for (int k = 0; k < m->scnt[b]; k++) { int s = m->succ[m->sbeg[b] + k]; pl[pb[s] + pc[s]++] = b; }
    m->idom[0] = 0;
    for (int changed = 1; changed; ) {
        changed = 0;
        for (int r = 1; r < no; r++) {
            int b = byr[r], ni = -1;
            for (int k = pb[b]; k < pb[b + 1]; k++) {
                int p = pl[k]; if (m->idom[p] < 0) continue;
                if (ni < 0) { ni = p; continue; }
                int a = p, c = ni;
                while (a != c) { while (m->rpo[a] > m->rpo[c]) a = m->idom[a]; while (m->rpo[c] > m->rpo[a]) c = m->idom[c]; }
                ni = a;
            }
            if (ni >= 0 && m->idom[b] != ni) { m->idom[b] = ni; changed = 1; }
        }
    }
    free(order); free(stk); free(it); free(seen); free(byr); free(pc); free(pb); free(pl);
    // 写：入口函数里的按块记；别的函数里的写记块 −1（追值碰到就放弃）
    int cur = -1; in_fn = 0;
    for (uint32_t i = 5; i < n; i += w[i] >> 16) {
        uint32_t op = w[i] & 0xffff;
        if (op == SpvOpFunction) in_fn = 1;
        else if (op == SpvOpFunctionEnd) in_fn = 0;
        else if (op == SpvOpLabel) cur = i > m->fn0 && i < m->fn1 ? (int)m->lab[w[i + 1]] - 1 : -1;
        else if (op == SpvOpStore && in_fn) {
            sst s; memset(&s, 0, sizeof s); s.off = i; s.val = w[i + 2]; s.blk = cur;
            if (!loc_of(m, w[i + 1], &s.root, &s.np, s.p, &s.dyn, 0)) continue;
            if (m->nst == m->capst) { m->capst = m->capst ? m->capst * 2 : 256; m->st = realloc(m->st, m->capst * sizeof *m->st); }
            m->st[m->nst++] = s; m->stored[s.root] = 1;
        }
    }
    return 1;
}
static int blk_of(const spm *m, uint32_t off) {
    if (off <= m->fn0 || off >= m->fn1) return -1;
    int lo = 0, hi = m->nb - 1, r = -1;
    while (lo <= hi) { int mid = (lo + hi) / 2; if (m->bstart[mid] <= off) { r = mid; lo = mid + 1; } else hi = mid - 1; }
    return r >= 0 && off <= m->bend[r] ? r : -1;
}
static int dom(const spm *m, int a, int b) {
    if (a < 0 || b < 0 || m->idom[b] < 0 || m->idom[a] < 0) return 0;
    for (int x = b; ; x = m->idom[x]) { if (x == a) return 1; if (x == 0) return 0; }
}
static int in_cycle(spm *m, int b) {
    if (m->cyc[b] >= 0) return m->cyc[b];
    int nb = m->nb, *q = malloc(nb * sizeof(int)), nq = 0, hit = 0; uint8_t *s = calloc(nb, 1);
    for (int k = 0; k < m->scnt[b]; k++) { int x = m->succ[m->sbeg[b] + k]; if (!s[x]) { s[x] = 1; q[nq++] = x; } }
    for (int h = 0; h < nq && !hit; h++) {
        int x = q[h]; if (x == b) { hit = 1; break; }
        for (int k = 0; k < m->scnt[x]; k++) { int y = m->succ[m->sbeg[x] + k]; if (!s[y]) { s[y] = 1; q[nq++] = y; } }
    }
    free(q); free(s); m->cyc[b] = (int8_t)hit; return hit;
}
static uint32_t var_storage(const spm *m, uint32_t var) { uint32_t d = D(m, var); return d && op_at(m, d) == SpvOpVariable ? m->w[d + 3] : UINT32_MAX; }
static uint32_t pointee(const spm *m, uint32_t ptr_type) { uint32_t d = D(m, ptr_type); return d && op_at(m, d) == SpvOpTypePointer ? m->w[d + 3] : 0; }
static uint32_t var_type(const spm *m, uint32_t var) { uint32_t d = D(m, var); return d ? pointee(m, m->w[d + 1]) : 0; }
// 32 位浮点四分量向量
static int is_vec4f(const spm *m, uint32_t t) {
    uint32_t d = D(m, t); if (!d || op_at(m, d) != SpvOpTypeVector || m->w[d + 3] != 4) return 0;
    uint32_t e = D(m, m->w[d + 2]); return e && op_at(m, e) == SpvOpTypeFloat && m->w[e + 2] == 32;
}
static uint32_t vec_size(const spm *m, uint32_t t) { uint32_t d = D(m, t); return d && op_at(m, d) == SpvOpTypeVector ? m->w[d + 3] : 1; }

// 选出「这个位置此刻的值」由哪条写给出。use = 读指令偏移；use = 0 表示入口函数结束时（输出的最终值）
static const sst *pick_store(spm *m, uint32_t root, uint32_t np, const uint32_t *p, uint32_t use) {
    if (!root || m->dirty[root]) return NULL;
    const sst *cand[64]; int nc = 0;
    for (int i = 0; i < m->nst; i++) {
        const sst *s = &m->st[i]; if (s->root != root) continue;
        if (s->dyn) return NULL;
        uint32_t k = s->np < np ? s->np : np; int pre = 1;
        for (uint32_t j = 0; j < k; j++) if (s->p[j] != p[j]) { pre = 0; break; }
        if (!pre) continue;
        if (s->np > np) return NULL;
        if (s->blk < 0 || nc == 64) return NULL;
        // 读之后才执行的写（同块在读之后、或在读所在块支配的块里）不可能是这次读到的值——读所在块不在环上时成立（宽屏外推尾声：返回前读回 gl_Position 再整体写回）
        if (use) { int ub = blk_of(m, use); if (ub >= 0 && !in_cycle(m, ub) && (s->blk == ub ? s->off > use : dom(m, ub, s->blk))) continue; }
        cand[nc++] = s;
    }
    const sst *S = NULL;
    for (int i = 0; i < nc && !S; i++) {
        int all = 1;
        for (int j = 0; j < nc && all; j++) {
            if (j == i) continue;
            const sst *c = cand[j], *x = cand[i];
            all = c->blk == x->blk ? c->off < x->off : (dom(m, c->blk, x->blk) && c->blk != x->blk);
        }
        if (all) S = cand[i];
    }
    if (!S || in_cycle(m, S->blk)) return NULL;
    if (use) {
        int ub = blk_of(m, use); if (ub < 0) return NULL;
        if (!(S->blk == ub ? S->off < use : dom(m, S->blk, ub))) return NULL;
    } else {
        int nret = 0;
        for (int b = 0; b < m->nb; b++) if (m->ret[b]) { nret++; if (!dom(m, S->blk, b)) return NULL; }
        if (!nret) return NULL;
    }
    return S;
}

// ---------- 值：追到「同一 SSA / 同一输入位置 / 同一常量」 ----------
enum { V_FAIL, V_SSA, V_MEM, V_CONST };
typedef struct { uint32_t tag, a, np, p[4]; } val;
static int veq(val x, val y) {
    if (x.tag != y.tag || x.tag == V_FAIL || x.a != y.a || x.np != y.np) return 0;
    for (uint32_t i = 0; i < x.np; i++) if (x.p[i] != y.p[i]) return 0;
    return 1;
}
static val vfail(void) { val v; memset(&v, 0, sizeof v); return v; }
static val R(spm *m, uint32_t id, uint32_t np, const uint32_t *p, int depth);
static val R0(spm *m, uint32_t id, int depth) { return R(m, id, 0, NULL, depth); }
static val R(spm *m, uint32_t id, uint32_t np, const uint32_t *p, int depth) {
    val v = vfail(); uint32_t d = D(m, id);
    if (!d || depth > 64 || np > 4) return v;
    uint32_t op = op_at(m, d), wc = wc_at(m, d); const uint32_t *w = m->w;
    uint32_t q[8];
    switch (op) {
    case SpvOpConstant:
        if (np || wc != 4) return v;
        v.tag = V_CONST; v.a = w[d + 3]; return v;
    case SpvOpConstantNull:
        v.tag = V_CONST; v.a = 0; return v;
    case SpvOpConstantComposite:
        if (!np || 3 + p[0] >= wc) return v;
        return R(m, w[d + 3 + p[0]], np - 1, p + 1, depth + 1);
    case SpvOpCopyObject:
        return R(m, w[d + 3], np, p, depth + 1);
    case SpvOpCompositeInsert:
        // 单层下标的插入（宽屏外推尾声整 vec4 写回 gl_Position 用它）：读到插入的分量 = 被插的值，其余分量 = 原复合值
        if (!np || wc != 6) break;
        if (p[0] == w[d + 5]) return R(m, w[d + 3], np - 1, p + 1, depth + 1);
        return R(m, w[d + 4], np, p, depth + 1);
    case SpvOpCompositeExtract: {
        uint32_t k = wc - 4; if (k + np > 4) return v;
        for (uint32_t j = 0; j < k; j++) q[j] = w[d + 4 + j];
        for (uint32_t j = 0; j < np; j++) q[k + j] = p[j];
        return R(m, w[d + 3], k + np, q, depth + 1);
    }
    case SpvOpCompositeConstruct: {
        if (!np) break;
        uint32_t rt = w[d + 1], rd = D(m, rt);
        if (rd && op_at(m, rd) == SpvOpTypeVector) {
            uint32_t at = 0;
            for (uint32_t k = d + 3; k < d + wc; k++) {
                uint32_t cd = D(m, w[k]); if (!cd) return v;
                uint32_t sz = vec_size(m, w[cd + 1]);
                if (p[0] < at + sz) {
                    if (sz == 1) return R(m, w[k], np - 1, p + 1, depth + 1);
                    q[0] = p[0] - at; for (uint32_t j = 1; j < np; j++) q[j] = p[j];
                    return R(m, w[k], np, q, depth + 1);
                }
                at += sz;
            }
            return v;
        }
        if (3 + p[0] >= wc) return v;
        return R(m, w[d + 3 + p[0]], np - 1, p + 1, depth + 1);
    }
    case SpvOpVectorShuffle: {
        if (!np || 5 + p[0] >= wc) return v;
        uint32_t c = w[d + 5 + p[0]], v1 = w[d + 3], v1d = D(m, v1); if (c == 0xffffffffu || !v1d) return v;
        uint32_t n1 = vec_size(m, w[v1d + 1]);
        q[0] = c < n1 ? c : c - n1; for (uint32_t j = 1; j < np; j++) q[j] = p[j];
        return R(m, c < n1 ? v1 : w[d + 4], np, q, depth + 1);
    }
    case SpvOpSelect: {
        // Ryujinx 采样坐标的 NaN 兜底：select(isnan(c), 0, c) → c
        uint32_t cd = D(m, w[d + 3]);
        if (cd && op_at(m, cd) == SpvOpIsNan && m->w[cd + 3] == w[d + 5]) return R(m, w[d + 5], np, p, depth + 1);
        break;
    }
    case SpvOpLoad: {
        uint32_t root, lnp, lp[8]; int dyn;
        if (!loc_of(m, w[d + 3], &root, &lnp, lp, &dyn, 0) || dyn || lnp + np > 4) return v;
        for (uint32_t j = 0; j < np; j++) lp[lnp + j] = p[j];
        lnp += np;
        uint32_t sc = var_storage(m, root);
        if (sc == SpvStorageClassInput || sc == SpvStorageClassUniform || sc == SpvStorageClassUniformConstant || sc == SpvStorageClassPushConstant) {
            if (m->dirty[root] || m->stored[root]) return v;
            v.tag = V_MEM; v.a = root; v.np = lnp; memcpy(v.p, lp, lnp * 4); return v;
        }
        if (sc != SpvStorageClassFunction && sc != SpvStorageClassOutput && sc != SpvStorageClassPrivate) return v;
        const sst *S = pick_store(m, root, lnp, lp, d); if (!S) return v;
        return R(m, S->val, lnp - S->np, lp + S->np, depth + 1);
    }
    default: break;
    }
    v.tag = V_SSA; v.a = id; v.np = np; if (np) memcpy(v.p, p, np * 4);
    return v;
}
// 当前值是标量 SSA 运算时返回它的指令偏移
static uint32_t ssa_op(const spm *m, val v, uint32_t op) {
    if (v.tag != V_SSA || v.np) return 0;
    uint32_t d = D(m, v.a); return d && op_at(m, d) == op ? d : 0;
}
static int is_cf(val v, float f) { uint32_t b; memcpy(&b, &f, 4); return v.tag == V_CONST && v.a == b; }
static int is_ci(val v, uint32_t i) { return v.tag == V_CONST && v.a == i; }
static val peel(spm *m, val v, int depth) {
    for (int k = 0; k < 16; k++) { uint32_t d = ssa_op(m, v, SpvOpBitcast); if (!d) break; v = R0(m, m->w[d + 3], depth + 1); }
    return v;
}

// ---------- 片元：坐标是不是当前像素 ----------
// kind：FC_BIT = 该字第 bit 位为 0（缩放因子位）；FC_FZERO = 该字按 32 位浮点为 0（正负零都算；宽屏外推参数 s2a_widen.x / .z）
enum { FC_BIT = 0, FC_FZERO = 1 };
typedef struct { uint16_t ubo; uint32_t off; uint8_t bit, kind; } fbr_cond;
typedef struct { uint32_t var; fbr_cond cond[4]; int ncond; const char *why; } coord_ctx;
// t 是常量缓冲里 32 位整数向量成员的一个分量（V_MEM，路径 = 成员、分量）：填 c->ubo（绑定号）/ c->off（字节偏移）
static int ubo_word(spm *m, val t, fbr_cond *c, const char **why) {
    memset(c, 0, sizeof *c);
    if (t.tag != V_MEM || var_storage(m, t.a) != SpvStorageClassUniform || t.np != 2) { *why = "缩放因子的位不在常量缓冲里"; return 0; }
    uint32_t st = var_type(m, t.a), sd = D(m, st), mem = t.p[0], comp = t.p[1];
    if (!sd || op_at(m, sd) != SpvOpTypeStruct || 2 + mem >= wc_at(m, sd)) { *why = "缩放因子所在常量缓冲不是结构体"; return 0; }
    uint32_t mt = m->w[sd + 2 + mem], mtd = D(m, mt), et = mtd && op_at(m, mtd) == SpvOpTypeVector ? m->w[mtd + 2] : 0, etd = D(m, et);
    if (!etd || op_at(m, etd) != SpvOpTypeInt || m->w[etd + 2] != 32 || comp >= m->w[mtd + 3]) { *why = "缩放因子的位所在成员不是 32 位整数向量"; return 0; }
    int has_off = 0; uint32_t moff = 0;
    for (int i = 0; i < m->nmd; i++) if (m->md[i].s == st && m->md[i].m == mem && m->md[i].kind == SpvDecorationOffset) { moff = m->md[i].v; has_off = 1; }
    uint32_t b1 = m->bind[t.a];
    if (!has_off || !b1 || b1 - 1 >= GS_MAX_BUF) { *why = "缩放因子所在常量缓冲没有偏移 / 绑定号"; return 0; }
    c->ubo = (uint16_t)(b1 - 1); c->off = moff + 4 * comp;
    return 1;
}
// 常量缓冲第 off 字节的 32 位字的第 bit 位 ≠ 0
static int match_bit(spm *m, val c, coord_ctx *x) {
    c = peel(m, c, 0);
    uint32_t d = ssa_op(m, c, SpvOpINotEqual); if (!d) { x->why = "缩放因子的条件不是 ≠ 0"; return 0; }
    val a = R0(m, m->w[d + 3], 0), b = R0(m, m->w[d + 4], 0), e;
    if (is_ci(b, 0)) e = a; else if (is_ci(a, 0)) e = b; else { x->why = "缩放因子的条件不是 ≠ 0"; return 0; }
    e = peel(m, e, 0);
    d = ssa_op(m, e, SpvOpBitwiseAnd); if (!d) { x->why = "缩放因子的条件不是 & 1"; return 0; }
    a = R0(m, m->w[d + 3], 0); b = R0(m, m->w[d + 4], 0);
    val t; if (is_ci(b, 1)) t = a; else if (is_ci(a, 1)) t = b; else { x->why = "缩放因子的条件不是 & 1"; return 0; }
    t = peel(m, t, 0);
    uint32_t bit = 0;
    if ((d = ssa_op(m, t, SpvOpShiftRightLogical)) || (d = ssa_op(m, t, SpvOpShiftRightArithmetic))) {
        val k = R0(m, m->w[d + 4], 0); if (k.tag != V_CONST || k.a > 31) { x->why = "缩放因子的位号不是常量"; return 0; }
        bit = k.a; t = peel(m, R0(m, m->w[d + 3], 0), 0);
    }
    fbr_cond c1; if (!ubo_word(m, t, &c1, &x->why)) return 0;
    c1.bit = (uint8_t)bit; c1.kind = FC_BIT;
    for (int i = 0; i < x->ncond; i++) if (x->cond[i].ubo == c1.ubo && x->cond[i].off == c1.off && x->cond[i].bit == c1.bit && x->cond[i].kind == c1.kind) return 1;
    if (x->ncond == 4) { x->why = "缩放因子条件过多"; return 0; }
    x->cond[x->ncond++] = c1; return 1;
}
// S = select(位, X, 1.0)：位为 0 时 S = 1
static int match_factor(spm *m, val s, coord_ctx *x) {
    uint32_t d = ssa_op(m, s, SpvOpSelect); if (!d) return 0;
    if (!is_cf(R0(m, m->w[d + 5], 0), 1.0f)) return 0;
    return match_bit(m, R0(m, m->w[d + 3], 0), x);
}
static int is_in(spm *m, val v, uint32_t c, coord_ctx *x) {
    if (v.tag != V_MEM || v.np != 1 || v.p[0] != c || var_storage(m, v.a) != SpvStorageClassInput) return 0;
    if (x->var && x->var != v.a) return 0;
    x->var = v.a; return 1;
}
// in.c ÷ in.w，或 in.c × (1 ÷ in.w)
static int match_base(spm *m, val v, uint32_t c, coord_ctx *x) {
    uint32_t d;
    if ((d = ssa_op(m, v, SpvOpFDiv))) {
        coord_ctx y = *x;
        if (is_in(m, R0(m, m->w[d + 3], 0), c, &y) && is_in(m, R0(m, m->w[d + 4], 0), 3, &y)) { *x = y; return 1; }
        return 0;
    }
    if ((d = ssa_op(m, v, SpvOpFMul))) {
        for (int k = 0; k < 2; k++) {
            coord_ctx y = *x; val a = R0(m, m->w[d + 3 + k], 0), r = R0(m, m->w[d + 4 - k], 0); uint32_t rd = ssa_op(m, r, SpvOpFDiv);
            if (rd && is_in(m, a, c, &y) && is_cf(R0(m, m->w[rd + 3], 0), 1.0f) && is_in(m, R0(m, m->w[rd + 4], 0), 3, &y)) { *x = y; return 1; }
        }
    }
    return 0;
}
static int match_coord(spm *m, val v, uint32_t c, coord_ctx *x) {
    if (match_base(m, v, c, x)) return 1;
    uint32_t d;
    if ((d = ssa_op(m, v, SpvOpFDiv))) {
        coord_ctx y = *x;
        if (match_base(m, R0(m, m->w[d + 3], 0), c, &y) && match_factor(m, R0(m, m->w[d + 4], 0), &y)) { *x = y; return 1; }
    }
    if ((d = ssa_op(m, v, SpvOpFMul))) {
        for (int k = 0; k < 2; k++) {
            coord_ctx y = *x;
            if (match_base(m, R0(m, m->w[d + 3 + k], 0), c, &y) && match_factor(m, R0(m, m->w[d + 4 - k], 0), &y)) { *x = y; return 1; }
        }
    }
    if (!x->why) x->why = "采样坐标不是 in.locK.xy ÷ in.locK.w（可带缩放因子）";
    return 0;
}

// ---------- 顶点：locK = ((x+w)/2, (w∓y)/2, *, w)，x / y / w 同 gl_Position ----------
static val final_of(spm *m, uint32_t root, uint32_t np, const uint32_t *p) {
    const sst *S = pick_store(m, root, np, p, 0); if (!S) return vfail();
    return R(m, S->val, np - S->np, p + S->np, 0);
}
static int half_of(spm *m, val v, val *e) {
    uint32_t d;
    if ((d = ssa_op(m, v, SpvOpFMul))) {
        val a = R0(m, m->w[d + 3], 0), b = R0(m, m->w[d + 4], 0);
        if (is_cf(b, 0.5f)) { *e = a; return 1; }
        if (is_cf(a, 0.5f)) { *e = b; return 1; }
    }
    if ((d = ssa_op(m, v, SpvOpFDiv)) && is_cf(R0(m, m->w[d + 4], 0), 2.0f)) { *e = R0(m, m->w[d + 3], 0); return 1; }
    return 0;
}
// 宽屏外推尾声（graphics/widen/shader/SpirvEdgePush.cs Patch，10-22）：main 返回前读回 gl_Position v，x' = v.x·(1 − z)，t = x' / v.w，
//   x'' = x' + select(t² > 门限², select(t < 0, −d, d)·v.w, 0)，整 vec4 写回（CompositeInsert 进 x）。d = s2a_widen.x、z = s2a_widen.z（支持缓冲里的 ivec4，按浮点位 Bitcast）。
// x2 = 尾声算出的 x''（gl_Position.x 的最终值），w = gl_Position.w 的最终值。认出时 *x0 = 改写前的 x，并给出两条运行时条件「d、z 所在字按浮点为 0」：
//   z = ±0 → 1 − z = 1、x' = x 逐位不变；d = ±0 → 推量 ±0·w = ±0、x'' = x'（只可能差零的符号，不改光栅化位置）。门限² 与比较的结果不影响这一点，不认它的形状
static int match_push(spm *m, val x2, val w, val *x0, fbr_cond c[2]) {
    uint32_t d = ssa_op(m, x2, SpvOpFAdd); if (!d) return 0;
    for (int k = 0; k < 2; k++) {
        val xs = R0(m, m->w[d + 3 + k], 0), shz = R0(m, m->w[d + 4 - k], 0);
        // shz = select(…, sh, 0.0)，sh = sd · w，sd = select(…, −D, D)
        uint32_t ds = ssa_op(m, shz, SpvOpSelect); if (!ds || !is_cf(R0(m, m->w[ds + 5], 0), 0.0f)) continue;
        uint32_t dm = ssa_op(m, R0(m, m->w[ds + 4], 0), SpvOpFMul); if (!dm) continue;
        val sd = vfail(); int okw = 0;
        for (int j = 0; j < 2 && !okw; j++) if (veq(R0(m, m->w[dm + 3 + j], 0), w)) { okw = 1; sd = R0(m, m->w[dm + 4 - j], 0); }
        uint32_t dd = okw ? ssa_op(m, sd, SpvOpSelect) : 0; if (!dd) continue;
        val a = R0(m, m->w[dd + 4], 0), b = R0(m, m->w[dd + 5], 0), D1 = vfail(); uint32_t dn;
        if ((dn = ssa_op(m, a, SpvOpFNegate)) && veq(peel(m, R0(m, m->w[dn + 3], 0), 0), peel(m, b, 0))) D1 = peel(m, b, 0);
        else if ((dn = ssa_op(m, b, SpvOpFNegate)) && veq(peel(m, R0(m, m->w[dn + 3], 0), 0), peel(m, a, 0))) D1 = peel(m, a, 0);
        else continue;
        // xs = x · (1 − z)
        uint32_t dx = ssa_op(m, xs, SpvOpFMul); if (!dx) continue;
        for (int j = 0; j < 2; j++) {
            uint32_t df = ssa_op(m, R0(m, m->w[dx + 4 - j], 0), SpvOpFSub);
            if (!df || !is_cf(R0(m, m->w[df + 3], 0), 1.0f)) continue;
            val Z = peel(m, R0(m, m->w[df + 4], 0), 0); const char *why = NULL;
            if (!ubo_word(m, D1, &c[0], &why) || !ubo_word(m, Z, &c[1], &why)) return 0;
            c[0].kind = c[1].kind = FC_FZERO;
            *x0 = R0(m, m->w[dx + 3 + j], 0);
            return x0->tag != V_FAIL;
        }
    }
    return 0;
}
// 返回 1 = (w+y)、−1 = (w−y)、0 = 不认。gl_Position.x 带宽屏外推尾声时穿过它取改写前的 x，*nvc / vc 给出外推参数为 0 的两条运行时条件（没有尾声 *nvc = 0）
static int vs_sign(spm *m, uint32_t K, const char **why, fbr_cond vc[2], int *nvc) {
    *nvc = 0;
    uint32_t pos_root = 0, pos_np = 0, pos_p[2] = {0, 0}, out = 0; int nout = 0;
    for (uint32_t i = 5; i < m->n; i += m->w[i] >> 16) {
        if ((m->w[i] & 0xffff) != SpvOpVariable || m->w[i + 3] != SpvStorageClassOutput) continue;
        uint32_t v = m->w[i + 2], t = pointee(m, m->w[i + 1]);
        if (m->flag[v] & F_POS) { if (pos_root) { *why = "顶点有多个 gl_Position"; return 0; } pos_root = v; pos_np = 0; }
        uint32_t td = D(m, t);
        if (td && op_at(m, td) == SpvOpTypeStruct)
            for (int k = 0; k < m->nmd; k++) if (m->md[k].s == t && m->md[k].kind == SpvDecorationBuiltIn && m->md[k].v == SpvBuiltInPosition) {
                if (pos_root) { *why = "顶点有多个 gl_Position"; return 0; }
                pos_root = v; pos_np = 1; pos_p[0] = m->md[k].m;
            }
        if (m->loc[v] == K + 1) { nout++; out = v; if ((m->flag[v] & (F_COMP | F_PATCH)) || !is_vec4f(m, t)) { *why = "顶点 locK 输出不是整个 vec4"; return 0; } }
    }
    if (!pos_root) { *why = "顶点没写 gl_Position"; return 0; }
    if (nout != 1) { *why = "顶点 locK 输出没有或不止一个"; return 0; }
    uint32_t q[2]; val P[4], O[4];
    for (uint32_t c = 0; c < 4; c++) {
        if (c == 2) continue;
        q[0] = pos_p[0]; q[pos_np] = c; P[c] = final_of(m, pos_root, pos_np + 1, q);
        q[0] = c; O[c] = final_of(m, out, 1, q);
        if (P[c].tag == V_FAIL) { *why = "gl_Position 的最终值追不到唯一一次写"; return 0; }
        if (O[c].tag == V_FAIL) { *why = "locK 的最终值追不到唯一一次写"; return 0; }
    }
    if (!veq(O[3], P[3])) { *why = "locK.w ≠ gl_Position.w"; return 0; }
    { val x0; if (match_push(m, P[0], P[3], &x0, vc)) { P[0] = x0; *nvc = 2; } }
    val e; uint32_t d;
    if (!half_of(m, O[0], &e) || !(d = ssa_op(m, e, SpvOpFAdd))) { *why = "locK.x 不是 (x+w)·0.5"; return 0; }
    { val a = R0(m, m->w[d + 3], 0), b = R0(m, m->w[d + 4], 0);
      if (!((veq(a, P[0]) && veq(b, P[3])) || (veq(a, P[3]) && veq(b, P[0])))) { *why = "locK.x 不是 (x+w)·0.5（x / w 与 gl_Position 不是同一个值）"; return 0; } }
    if (!half_of(m, O[1], &e)) { *why = "locK.y 不是 (w±y)·0.5"; return 0; }
    if ((d = ssa_op(m, e, SpvOpFSub))) {
        if (veq(R0(m, m->w[d + 3], 0), P[3]) && veq(R0(m, m->w[d + 4], 0), P[1])) return -1;
    } else if ((d = ssa_op(m, e, SpvOpFAdd))) {
        val a = R0(m, m->w[d + 3], 0), b = R0(m, m->w[d + 4], 0);
        if ((veq(a, P[3]) && veq(b, P[1])) || (veq(a, P[1]) && veq(b, P[3]))) return 1;
        for (int k = 0; k < 2; k++) {
            val s = k ? b : a, o = k ? a : b; uint32_t nd = ssa_op(m, s, SpvOpFNegate);
            if (nd && veq(o, P[3]) && veq(R0(m, m->w[nd + 3], 0), P[1])) return -1;
        }
    }
    *why = "locK.y 不是 (w±y)·0.5（y / w 与 gl_Position 不是同一个值）";
    return 0;
}

// ---------- 证明 ----------
#define FBR_MAX_TEX 64
#define FBR_MAX_COND 16
// key：变体片元阶段键（改写后 SPIR-V 的键；FV_TAB 来自程序二进制尾段的变体表，FV_READY 为建成的变体程序片元键，0 = 还不知道）
typedef struct { uint8_t state; uint8_t n, ydown, bind[8], slot[8]; uint32_t *spv, nw; gal_prog *prog; uint64_t key; } fbr_var;
struct gal_fbr {
    uint64_t ok[2][4];
    fbr_cond cond[FBR_MAX_COND]; uint8_t cond_bind[FBR_MAX_COND]; int ncond;
    // fs = NULL：从程序二进制尾段恢复的证明（load_binary，没有 SPIR-V）——变体只能按变体表取，不能现改写
    uint32_t *fs, fsn;
    fbr_var *var; int nvar, capvar;
};
// FV_TAB：变体表里有（映射 → 变体片元键），还没建程序；首次命中时按键取函数建（gal_prog_fbr_load，不现翻）
enum { FV_PEND, FV_READY, FV_FAIL, FV_TAB };
// vc：顶点侧的运行时条件（宽屏外推参数为 0，vs_sign 给出，去重）
typedef struct { uint32_t var, binding, nsamp, locvar[8], nloc; coord_ctx cx; fbr_cond vc[4]; int nvc; int bad; const char *why; } fbr_tex;

static int fbr_why_on(void) { static int on = -1; if (on < 0) { const char *v = getenv("NXGAL_FBR_WHY"); on = v && *v == '1'; } return on; }
static int fbr_device_ok(void) { static int ok = -1; if (ok < 0) ok = g_gdev && [g_gdev supportsFamily:MTLGPUFamilyApple1]; return ok; }
static uint64_t g_fbr_stat[4];

// 片元里的组合贴图采样器：2D、非数组、非多重采样、非深度、按 32 位取样
static int tex_type_ok(const spm *m, uint32_t var) {
    uint32_t t = var_type(m, var), td = D(m, t); if (!td || op_at(m, td) != SpvOpTypeSampledImage) return 0;
    uint32_t id = D(m, m->w[td + 2]); if (!id || op_at(m, id) != SpvOpTypeImage) return 0;
    const uint32_t *w = m->w + id;
    if (w[3] != SpvDim2D || w[4] != 0 || w[5] != 0 || w[6] != 0 || w[7] != 1) return 0;
    uint32_t sd = D(m, w[2]); return sd && (op_at(m, sd) == SpvOpTypeFloat || op_at(m, sd) == SpvOpTypeInt) && m->w[sd + 2] == 32;
}
static gal_fbr *fbr_prove_core(const uint32_t *vs, uint32_t vn, const uint32_t *fs, uint32_t fn);
gal_fbr *gal_fbr_prove(const uint32_t *vs, uint32_t vn, const uint32_t *fs, uint32_t fn) {
    if (!fbr_device_ok()) return NULL;
    return fbr_prove_core(vs, vn, fs, fn);
}
// 证明本身只看 SPIR-V（不要设备）：运行时建程序（gal_fbr_prove，先判设备支持帧缓冲读取）与出包（nxgal_fbr_prove_spv，gal_xc --fbr）同一份
static gal_fbr *fbr_prove_core(const uint32_t *vs, uint32_t vn, const uint32_t *fs, uint32_t fn) {
    uint64_t log_key = fbr_why_on() ? gal_spv_hash(fs, fn * 4) : 0;
    spm F, V; memset(&V, 0, sizeof V);
    gal_fbr *out = NULL; fbr_tex tx[FBR_MAX_TEX]; int nt = 0; int v_ok = -1;
    uint32_t *tag = NULL;
    if (!spm_parse(&F, fs, fn) || F.model != SpvExecutionModelFragment) goto done;
    for (uint32_t i = 5; i < F.n && i < F.fn0; i += F.w[i] >> 16) {
        if ((F.w[i] & 0xffff) != SpvOpVariable || F.w[i + 3] != SpvStorageClassUniformConstant) continue;
        uint32_t v = F.w[i + 2]; if (!F.bind[v] || !tex_type_ok(&F, v) || nt == FBR_MAX_TEX) continue;
        memset(&tx[nt], 0, sizeof tx[nt]); tx[nt].var = v; tx[nt].binding = F.bind[v] - 1; nt++;
    }
    if (!nt) goto done;
    // 同绑定号两个变量（不同集）：都不认
    for (int a = 0; a < nt; a++) for (int b = a + 1; b < nt; b++) if (tx[a].binding == tx[b].binding) { tx[a].bad = tx[b].bad = 1; tx[a].why = tx[b].why = "同一绑定号两个贴图变量"; }
    // 用法：变量只许被 Load；Load 结果只许进采样 / OpImage / 查 LOD；OpImage 结果只许进查询。tag：var = t+1，Load 结果 = 0x10000|t+1，OpImage 结果 = 0x20000|t+1
    tag = calloc(F.bound, 4);
    for (int t = 0; t < nt; t++) tag[tx[t].var] = (uint32_t)t + 1;
    int in_fn = 0;
    for (uint32_t i = 5; i < F.n; i += F.w[i] >> 16) {
        const uint32_t *w = F.w + i; uint32_t op = w[0] & 0xffff, wc = w[0] >> 16;
        if (op == SpvOpFunction) { in_fn = 1; continue; }
        if (op == SpvOpFunctionEnd) { in_fn = 0; continue; }
        if (!in_fn) continue;
        uint32_t skip = 0, t0 = 0;
        if (op == SpvOpLoad && w[3] < F.bound && tag[w[3]] && tag[w[3]] < 0x10000) { tag[w[2]] = 0x10000 | tag[w[3]]; continue; }
        if (op == SpvOpImage && w[3] < F.bound && (tag[w[3]] >> 16) == 1) { tag[w[2]] = 0x20000 | (tag[w[3]] & 0xffff); continue; }
        if ((op == SpvOpImageSampleImplicitLod || op == SpvOpImageSampleExplicitLod) && w[3] < F.bound && (tag[w[3]] >> 16) == 1) {
            fbr_tex *T = &tx[(tag[w[3]] & 0xffff) - 1]; skip = 3; t0 = 1;
            if (!T->bad) {
                int ok = op == SpvOpImageSampleImplicitLod ? (wc == 5 || (wc == 6 && w[5] == 0))
                       : (wc == 7 && w[5] == SpvImageOperandsLodMask && (R0(&F, w[6], 0).tag == V_CONST && (R0(&F, w[6], 0).a & 0x7fffffffu) == 0));
                if (!ok) { T->bad = 1; T->why = "采样带了偏置 / 偏移 / 非 0 级等图像操作数"; }
                uint32_t cd = D(&F, w[4]);
                if (!T->bad && (!cd || vec_size(&F, F.w[cd + 1]) != 2)) { T->bad = 1; T->why = "采样坐标不是二维"; }
                if (!T->bad) {
                    coord_ctx x; memset(&x, 0, sizeof x); x.ncond = T->cx.ncond; memcpy(x.cond, T->cx.cond, sizeof x.cond);
                    uint32_t c0 = 0, c1 = 1;
                    if (!match_coord(&F, R(&F, w[4], 1, &c0, 0), 0, &x) || !match_coord(&F, R(&F, w[4], 1, &c1, 0), 1, &x)) { T->bad = 1; T->why = x.why; }
                    else {
                        uint32_t fl = F.flag[x.var], K = F.loc[x.var];
                        if (!K || (fl & (F_FLAT | F_NOPERSP | F_SAMPLE | F_COMP | F_PATCH)) || !is_vec4f(&F, var_type(&F, x.var))) { T->bad = 1; T->why = "locK 输入不是透视插值的整个 vec4"; }
                        else {
                            T->cx.ncond = x.ncond; memcpy(T->cx.cond, x.cond, sizeof x.cond);
                            int dup = 0; for (uint32_t k = 0; k < T->nloc; k++) dup |= T->locvar[k] == x.var;
                            if (!dup) { if (T->nloc == 8) { T->bad = 1; T->why = "用到的 locK 过多"; } else T->locvar[T->nloc++] = x.var; }
                            T->nsamp++;
                        }
                    }
                }
            }
        } else if (op == SpvOpImageQueryLod && w[3] < F.bound && (tag[w[3]] >> 16) == 1) skip = 3;
        else if ((op == SpvOpImageQuerySizeLod || op == SpvOpImageQuerySize || op == SpvOpImageQueryLevels || op == SpvOpImageQuerySamples
                  || op == SpvOpImageQueryFormat || op == SpvOpImageQueryOrder) && w[3] < F.bound && (tag[w[3]] >> 16) == 2) skip = 3;
        (void)t0;
        for (uint32_t k = 1; k < wc; k++) {
            if (k == skip || lit_word(op, k, wc) || w[k] >= F.bound || !tag[w[k]]) continue;
            fbr_tex *T = &tx[(tag[w[k]] & 0xffff) - 1];
            if (!T->bad) { T->bad = 1; T->why = "贴图有采样 / 查询以外的用法（取纹素、聚集、传进函数……）"; }
        }
    }
    // 顶点：每个用到的 locK 证一次符号
    int okn = 0; uint64_t ok[2][4]; memset(ok, 0, sizeof ok);
    fbr_cond cond[FBR_MAX_COND]; uint8_t cb[FBR_MAX_COND]; int nc = 0;
    for (int t = 0; t < nt; t++) {
        fbr_tex *T = &tx[t];
        if (T->bad || !T->nsamp) continue;
        if (T->binding > 255) { T->bad = 1; T->why = "绑定号 > 255"; continue; }
        if (v_ok < 0) v_ok = spm_parse(&V, vs, vn) && V.model == SpvExecutionModelVertex;
        if (!v_ok) { T->bad = 1; T->why = "顶点着色器解析失败"; continue; }
        int sg = 0;
        for (uint32_t k = 0; k < T->nloc && !T->bad; k++) {
            const char *why = NULL; fbr_cond vc[2]; int nvc = 0; int s = vs_sign(&V, F.loc[T->locvar[k]] - 1, &why, vc, &nvc);
            if (!s) { T->bad = 1; T->why = why; }
            else if (sg && s != sg) { T->bad = 1; T->why = "各次采样 y 的符号不一致"; }
            else sg = s;
            for (int j = 0; s && !T->bad && j < nvc; j++) {
                int dup = 0; for (int q = 0; q < T->nvc; q++) dup |= !memcmp(&T->vc[q], &vc[j], sizeof vc[j]);
                if (dup) continue;
                if (T->nvc == 4) { T->bad = 1; T->why = "外推参数条件过多"; break; }
                T->vc[T->nvc++] = vc[j];
            }
        }
        if (T->bad) continue;
        if (nc + T->cx.ncond + T->nvc > FBR_MAX_COND) { T->bad = 1; T->why = "缩放因子条件过多"; continue; }
        for (int k = 0; k < T->cx.ncond; k++) { cond[nc] = T->cx.cond[k]; cb[nc] = (uint8_t)T->binding; nc++; }
        for (int k = 0; k < T->nvc; k++) { cond[nc] = T->vc[k]; cb[nc] = (uint8_t)T->binding; nc++; }
        int yd = sg > 0 ? 1 : 0; ok[yd][T->binding >> 6] |= 1ull << (T->binding & 63); okn++;
    }
    if (fbr_why_on())
        for (int t = 0; t < nt; t++) {
            if (!tx[t].nsamp && !tx[t].bad) continue;
            int yd = (ok[1][tx[t].binding >> 6] >> (tx[t].binding & 63)) & 1;
            if (!tx[t].bad) GLOG("[帧缓冲读取证明] 片元 %016llx 绑定 %u：证得（%d 次采样，%s、只在 ydown = %d 时是当前像素，缩放因子条件 %d 个、外推参数条件 %d 个）",
                                 (unsigned long long)log_key, tx[t].binding, tx[t].nsamp, yd ? "(w+y)" : "(w−y)", yd, tx[t].cx.ncond, tx[t].nvc);
            else GLOG("[帧缓冲读取证明] 片元 %016llx 绑定 %u：证不出——%s", (unsigned long long)log_key, tx[t].binding, tx[t].why ? tx[t].why : "?");
        }
    if (!okn) goto done;
    out = calloc(1, sizeof *out);
    memcpy(out->ok, ok, sizeof ok); memcpy(out->cond, cond, sizeof cond); memcpy(out->cond_bind, cb, sizeof cb); out->ncond = nc;
    out->fs = malloc(fn * 4); memcpy(out->fs, fs, fn * 4); out->fsn = fn;
    g_fbr_stat[0]++;
done:
    free(tag); spm_free(&F); spm_free(&V);
    return out;
}

// ---------- 改写：目标贴图的采样 → 读输入附件 ----------
// bind / slot 已按绑定号排好；返回 malloc 的新码（*onw 字数），失败 NULL
static uint32_t *fbr_rewrite(const uint32_t *in, uint32_t n, const uint8_t *bind, const uint8_t *slot, int cnt, uint32_t *onw) {
    spm m; uint32_t *o = NULL;
    if (!spm_parse(&m, in, n)) { spm_free(&m); return NULL; }
    uint32_t B = m.bound, nb = B;
    // 每个目标绑定 → 原变量与取样类型；每个槽一个输入附件变量（同槽取样类型须同）
    uint32_t tvar[8] = {0}, stype[8] = {0}, svar[8] = {0}, simg[8] = {0}, sptr[8] = {0}, styp_of_slot[8] = {0};
    for (uint32_t i = 5; i < m.fn0; i += in[i] >> 16) {
        if ((in[i] & 0xffff) != SpvOpVariable || in[i + 3] != SpvStorageClassUniformConstant) continue;
        uint32_t v = in[i + 2];
        for (int k = 0; k < cnt; k++) if (m.bind[v] == (uint32_t)bind[k] + 1 && tex_type_ok(&m, v)) {
            if (tvar[k]) goto fail;
            tvar[k] = v; uint32_t td = D(&m, var_type(&m, v)), id = D(&m, in[td + 2]); stype[k] = in[id + 2];
        }
    }
    for (int k = 0; k < cnt; k++) {
        if (!tvar[k] || slot[k] > 7) goto fail;
        if (styp_of_slot[slot[k]] && styp_of_slot[slot[k]] != stype[k]) goto fail;
        styp_of_slot[slot[k]] = stype[k];
    }
    // 现有的 int32 / ivec2 类型、InputAttachment 能力
    uint32_t ti = 0, tv2 = 0, has_cap = 0, last_cap = 0, first_decl = 0, first_fn = 0, ep = 0;
    for (uint32_t i = 5; i < n; i += in[i] >> 16) {
        uint32_t op = in[i] & 0xffff;
        if (op == SpvOpCapability) { last_cap = i; if (in[i + 1] == SpvCapabilityInputAttachment) has_cap = 1; }
        if (op == SpvOpEntryPoint) ep = i;
        // 声明段的第一条（能力 / 扩展 / 入口 / 调试 / 装饰之后）：新装饰插在它前面
        int hdr = op == SpvOpCapability || op == SpvOpExtension || op == SpvOpExtInstImport || op == SpvOpMemoryModel || op == SpvOpEntryPoint
               || op == SpvOpExecutionMode || op == SpvOpExecutionModeId || op == SpvOpString || op == SpvOpSource || op == SpvOpSourceContinued
               || op == SpvOpSourceExtension || op == SpvOpName || op == SpvOpMemberName || op == SpvOpModuleProcessed || op == SpvOpDecorate
               || op == SpvOpMemberDecorate || op == SpvOpDecorationGroup || op == SpvOpGroupDecorate || op == SpvOpGroupMemberDecorate
               || op == SpvOpDecorateId || op == SpvOpDecorateString || op == SpvOpMemberDecorateString || op == SpvOpLine || op == SpvOpNoLine;
        if (!first_decl && !hdr) first_decl = i;
        if (!first_fn && op == SpvOpFunction) first_fn = i;
        if (op == SpvOpTypeInt && in[i + 2] == 32 && in[i + 3] == 1 && !ti) ti = in[i + 1];
    }
    if (!last_cap || !first_decl || !first_fn || !ep) goto fail;
    if (ti) for (uint32_t i = 5; i < first_fn; i += in[i] >> 16) if ((in[i] & 0xffff) == SpvOpTypeVector && in[i + 2] == ti && in[i + 3] == 2) { tv2 = in[i + 1]; break; }
    uint32_t new_ti = ti ? 0 : nb++; if (!ti) ti = new_ti;
    uint32_t new_tv2 = tv2 ? 0 : nb++; if (!tv2) tv2 = new_tv2;
    uint32_t zero = nb++;
    // 同取样类型的槽共用一对图像 / 指针类型（SPIR-V 不许重复声明非聚合类型）
    for (int s = 0; s < 8; s++) if (styp_of_slot[s]) {
        int same = -1; for (int r = 0; r < s; r++) if (styp_of_slot[r] == styp_of_slot[s]) { same = r; break; }
        if (same >= 0) { simg[s] = simg[same]; sptr[s] = sptr[same]; } else { simg[s] = nb++; sptr[s] = nb++; }
        svar[s] = nb++;
    }
    // 采样指令数（每条多一条 Load）
    uint32_t nsmp = 0;
    for (uint32_t i = first_fn; i < n; i += in[i] >> 16) {
        uint32_t op = in[i] & 0xffff;
        if (op != SpvOpImageSampleImplicitLod && op != SpvOpImageSampleExplicitLod) continue;
        uint32_t ld = D(&m, in[i + 3]); if (!ld || op_at(&m, ld) != SpvOpLoad) continue;
        for (int k = 0; k < cnt; k++) if (in[ld + 3] == tvar[k]) nsmp++;
    }
    int ver14 = in[1] >= 0x00010400;
    size_t cap = n + 64 + 4 * nsmp + 40 * 8 + (ver14 ? 8 : 0);
    o = malloc(cap * 4); uint32_t on = 0;
#define EMIT(...) do { uint32_t t_[] = {__VA_ARGS__}; memcpy(o + on, t_, sizeof t_); on += (uint32_t)(sizeof t_ / 4); } while (0)
    for (uint32_t i = 0; i < 5; i++) o[on++] = in[i];
    for (uint32_t i = 5; i < n; ) {
        uint32_t wc = in[i] >> 16, op = in[i] & 0xffff;
        if (i == first_decl) {
            // 绑定号给一个没有资源用的（0xffe0 + 槽）：SPIRV-Cross 按（集, 绑定）查显式资源映射，缺省 0 / 0 会撞上 0 号常量缓冲的映射、颜色号被改成它的 [[id]]
            for (int s = 0; s < 8; s++) if (svar[s]) {
                EMIT((4u << 16) | SpvOpDecorate, svar[s], SpvDecorationInputAttachmentIndex, (uint32_t)s);
                EMIT((4u << 16) | SpvOpDecorate, svar[s], SpvDecorationDescriptorSet, 0);
                EMIT((4u << 16) | SpvOpDecorate, svar[s], SpvDecorationBinding, 0xffe0u + (uint32_t)s);
            }
        }
        if (i == first_fn) {
            if (new_ti) EMIT((4u << 16) | SpvOpTypeInt, new_ti, 32, 1);
            if (new_tv2) EMIT((4u << 16) | SpvOpTypeVector, new_tv2, ti, 2);
            EMIT((3u << 16) | SpvOpConstantNull, tv2, zero);
            for (int s = 0; s < 8; s++) if (svar[s]) {
                int first = 1; for (int r = 0; r < s; r++) if (svar[r] && simg[r] == simg[s]) first = 0;
                if (first) {
                    EMIT((9u << 16) | SpvOpTypeImage, simg[s], styp_of_slot[s], SpvDimSubpassData, 0, 0, 0, 2, SpvImageFormatUnknown);
                    EMIT((4u << 16) | SpvOpTypePointer, sptr[s], SpvStorageClassUniformConstant, simg[s]);
                }
                EMIT((4u << 16) | SpvOpVariable, sptr[s], svar[s], SpvStorageClassUniformConstant);
            }
        }
        if (op == SpvOpEntryPoint && ver14) {
            uint32_t add = 0; for (int s = 0; s < 8; s++) add += svar[s] != 0;
            o[on++] = ((wc + add) << 16) | op; memcpy(o + on, in + i + 1, (wc - 1) * 4); on += wc - 1;
            for (int s = 0; s < 8; s++) if (svar[s]) o[on++] = svar[s];
            i += wc; continue;
        }
        if ((op == SpvOpImageSampleImplicitLod || op == SpvOpImageSampleExplicitLod) && i > first_fn) {
            uint32_t ld = D(&m, in[i + 3]); int k = -1;
            if (ld && op_at(&m, ld) == SpvOpLoad) for (int j = 0; j < cnt; j++) if (in[ld + 3] == tvar[j]) k = j;
            if (k >= 0) {
                uint32_t s = slot[k], t = nb++;
                EMIT((4u << 16) | SpvOpLoad, simg[s], t, svar[s]);
                EMIT((5u << 16) | SpvOpImageRead, in[i + 1], in[i + 2], t, zero);
                i += wc; continue;
            }
        }
        memcpy(o + on, in + i, wc * 4); on += wc;
        if (i == last_cap && !has_cap) EMIT((2u << 16) | SpvOpCapability, SpvCapabilityInputAttachment);
        i += wc;
    }
#undef EMIT
    if (on > cap) { GLOG("【红】帧缓冲读取改写越界（%u > %zu 字）", on, cap); abort(); }
    o[3] = nb; *onw = on;
    spm_free(&m); return o;
fail:
    spm_free(&m); free(o); return NULL;
}

void gal_fbr_free(gal_fbr *f) {
    if (!f) return;
    for (int i = 0; i < f->nvar; i++) {
        free(f->var[i].spv);
        gal_prog *p = f->var[i].prog;
        if (p) { for (int s = 0; s < 6; s++) { p->fn[s] = nil; } p->fn_np = nil; free(p->args); free(p); }
    }
    free(f->var); free(f->fs); free(f);
}
// 运行时条件：缩放因子的位此刻为 0 / 外推参数此刻按浮点为 0（读常量缓冲当前逻辑内容；读不到按不满足）
static int cond_zero(const fbr_cond *c) {
    const nxgal_buf_range *r = &g_gs.ubo[c->ubo];
    if (!r->buf || r->size < 0 || (int64_t)c->off + 4 > (int64_t)r->size) return 0;
    const uint8_t *p = gal_buf_cpu_view(r->buf, r->offset + (int32_t)c->off, 4); if (!p) return 0;
    uint32_t v; memcpy(&v, p, 4);
    return c->kind == FC_FZERO ? !(v & 0x7fffffffu) : !((v >> c->bit) & 1);
}
// 映射规范化（运行时取变体 / 出包改写 / 变体表同一口径）：按绑定号升序、去重；同一绑定给了两个不同槽 → -1
static int fbr_norm(const uint8_t *bind, const uint8_t *slot, int n, uint8_t *b, uint8_t *s) {
    if (n < 1 || n > 8) return -1;
    int m = 0;
    for (int i = 0; i < n; i++) {
        int dup = -1; for (int j = 0; j < m; j++) if (b[j] == bind[i]) dup = j;
        if (dup >= 0) { if (s[dup] != slot[i]) return -1; continue; }
        int j = m++; while (j > 0 && b[j - 1] > bind[i]) { b[j] = b[j - 1]; s[j] = s[j - 1]; j--; }
        b[j] = bind[i]; s[j] = slot[i];
    }
    return m;
}
static int fbr_proved(const gal_fbr *f, const uint8_t *b, int m, int ydown) {
    for (int i = 0; i < m; i++) if (!((f->ok[ydown][b[i] >> 6] >> (b[i] & 63)) & 1)) return 0;
    return 1;
}
static fbr_var *fbr_var_find(gal_fbr *f, const uint8_t *b, const uint8_t *s, int m, int ydown) {
    for (int i = 0; i < f->nvar; i++) {
        fbr_var *x = &f->var[i];
        if (x->n == m && x->ydown == ydown && !memcmp(x->bind, b, m) && !memcmp(x->slot, s, m)) return x;
    }
    return NULL;
}
static fbr_var *fbr_var_add(gal_fbr *f, const uint8_t *b, const uint8_t *s, int m, int ydown) {
    if (f->nvar == f->capvar) { f->capvar = f->capvar ? f->capvar * 2 : 2; f->var = realloc(f->var, f->capvar * sizeof *f->var); }
    fbr_var *v = &f->var[f->nvar++]; memset(v, 0, sizeof *v); v->n = (uint8_t)m; v->ydown = (uint8_t)ydown; memcpy(v->bind, b, m); memcpy(v->slot, s, m);
    return v;
}
const gal_prog *gal_prog_fbfetch(const gal_prog *pg, const uint8_t *bind, const uint8_t *slot, int n, int ydown) {
    gal_fbr *f = pg ? pg->fbr : NULL;
    if (!f || n < 1 || n > 8 || (ydown != 0 && ydown != 1) || !fbr_device_ok()) return NULL;
    uint32_t cf[8], samples = 0; gal_pass_formats(cf, &samples); if (samples > 1) return NULL;
    uint8_t b[8], s[8]; int m = fbr_norm(bind, slot, n, b, s);
    if (m < 0 || !fbr_proved(f, b, m, ydown)) return NULL;
    for (int k = 0; k < f->ncond; k++) {
        int hit = 0; for (int i = 0; i < m; i++) hit |= f->cond_bind[k] == b[i];
        if (hit && !cond_zero(&f->cond[k])) return NULL;
    }
    fbr_var *v = fbr_var_find(f, b, s, m, ydown);
    if (!v) {
        v = fbr_var_add(f, b, s, m, ydown);
        if (!f->fs) {
            // 证明是从程序二进制尾段恢复的（没有 SPIR-V）、变体表里又没有这个映射：不能现改写。记一行给出包收集
            // （graphics/tools/shbake/fbrvars.py → $S2A_SHCOLLECT/<款>/fbr_vars.tsv → gal_xc --fbr 改写 + 预编进包），这次照旧拆遍
            v->state = FV_FAIL; g_fbr_stat[3]++;
            char ms[96]; int o = 0; ms[0] = 0;
            for (int i = 0; i < m; i++) o += snprintf(ms + o, sizeof ms - (size_t)o, " %u:%u", b[i], s[i]);
            GLOG("读帧缓冲变体缺 v1 %016llx %016llx %d%s", (unsigned long long)pg->stage_hash[1], (unsigned long long)pg->stage_hash[5], ydown, ms);
            return NULL;
        }
        v->spv = fbr_rewrite(f->fs, f->fsn, b, s, m, &v->nw);
        v->state = v->spv ? FV_PEND : FV_FAIL;
        if (!v->spv) { g_fbr_stat[2]++; GLOG("【红】帧缓冲读取：程序 %016llx 证得但改写失败（绑定 %u → 槽 %u 等 %d 个）", (unsigned long long)pg->hash, b[0], s[0], m); }
    }
    if (v->state == FV_READY) return v->prog;
    if (v->state == FV_FAIL) return NULL;
    gal_prog *p = NULL; int pending = 0;
    if (v->state == FV_TAB) {
        // 变体表命中：按（顶点各阶段键 + 变体片元键）取函数建程序——内存缓存 / 离线库 / 持久缓存，同 load_binary，不现翻
        p = gal_prog_fbr_load(pg, v->key);
        if (!p) {
            v->state = FV_FAIL; g_fbr_stat[2]++;
            GLOG("【红】帧缓冲读取：程序 %016llx 变体表里的变体片元 %016llx 取不到函数（%s），照旧拆遍", (unsigned long long)pg->hash, (unsigned long long)v->key, nxgal_prog_last_error());
            return NULL;
        }
    } else p = gal_prog_fbr_build(pg, v->spv, v->nw, &pending);
    if (p) {
        v->prog = p; v->state = FV_READY; v->key = p->stage_hash[5]; free(v->spv); v->spv = NULL; g_fbr_stat[1]++;
        if (g_fbr_stat[1] <= 32 || fbr_why_on())
            GLOG("帧缓冲读取变体建成：程序 %016llx（片元 %016llx）→ 变体 %016llx（片元 %016llx，%s），%d 个绑定改读颜色附件（首个 %u → 槽 %u），ydown = %d",
                 (unsigned long long)pg->hash, (unsigned long long)pg->stage_hash[5], (unsigned long long)p->hash, (unsigned long long)p->stage_hash[5],
                 f->fs ? "现改写" : "变体表", m, b[0], s[0], ydown);
        return p;
    }
    if (pending) return NULL;
    v->state = FV_FAIL; free(v->spv); v->spv = NULL; g_fbr_stat[2]++;
    GLOG("【红】帧缓冲读取：程序 %016llx 的变体建不出（%s），照旧拆遍", (unsigned long long)pg->hash, nxgal_prog_last_error());
    return NULL;
}
void gal_fbr_stats(uint64_t out[4]) { memcpy(out, g_fbr_stat, 4 * sizeof *out); }

// ---------- 程序二进制尾段（gal_prog.m nxgal_prog_binary / load_binary；出包 gal_xc --fbr 出同一份字节，ShaderBake.cs 原样接在 GALP 后）----------
// 小端：u32 魔数「FBR2」、u64 ok[2][4]（64 字节）、u32 ncond、ncond × {u16 常量缓冲绑定, u32 字节偏移, u8 位号, u8 所属贴图绑定, u8 种类（0 位为 0 / 1 浮点为 0）, u8 0}、
//       u32 nvar、nvar × {u8 n, u8 ydown, u8 bind[8], u8 slot[8], u64 变体片元阶段键}（映射已按绑定号升序去重；只写有片元键的：建成的 / 表里来的）
// FBR2（10-22）：条件加种类字节（宽屏外推参数按浮点为 0）；FBR1 只在本分支前一提交出现过、没发出去，不读
#define FBR_MAGIC 0x32524246u
#define FBR_MAX_VAR 256
static int var_keyed(const fbr_var *v) { return (v->state == FV_READY || v->state == FV_TAB) && v->key; }
uint32_t gal_fbr_ser(const gal_fbr *f, uint8_t *out) {
    if (!f) return 0;
    int nv = 0; for (int i = 0; i < f->nvar; i++) nv += var_keyed(&f->var[i]);
    if (nv > FBR_MAX_VAR) nv = FBR_MAX_VAR;
    uint32_t len = 4 + 64 + 4 + 10u * (uint32_t)f->ncond + 4 + 26u * (uint32_t)nv;
    if (!out) return len;
    uint8_t *o = out; uint32_t u = FBR_MAGIC;
    memcpy(o, &u, 4); o += 4; memcpy(o, f->ok, 64); o += 64;
    u = (uint32_t)f->ncond; memcpy(o, &u, 4); o += 4;
    for (int k = 0; k < f->ncond; k++) { memcpy(o, &f->cond[k].ubo, 2); memcpy(o + 2, &f->cond[k].off, 4); o[6] = f->cond[k].bit; o[7] = f->cond_bind[k]; o[8] = f->cond[k].kind; o[9] = 0; o += 10; }
    u = (uint32_t)nv; memcpy(o, &u, 4); o += 4;
    for (int i = 0, w = 0; i < f->nvar && w < nv; i++) {
        const fbr_var *v = &f->var[i]; if (!var_keyed(v)) continue;
        o[0] = v->n; o[1] = v->ydown; memset(o + 2, 0, 16); memcpy(o + 2, v->bind, v->n); memcpy(o + 10, v->slot, v->n); memcpy(o + 18, &v->key, 8); o += 26; w++;
    }
    return len;
}
// 读尾段：p 起 len 字节必须正好是一个尾段；任何字段越界 / 变体映射不规整或不在证明里 → NULL（*why 写原因）
gal_fbr *gal_fbr_deser(const uint8_t *p, uint32_t len, const char **why) {
    *why = NULL; uint32_t u;
    if (len < 76) { *why = "尾段太短"; return NULL; }
    memcpy(&u, p, 4); if (u != FBR_MAGIC) { *why = "尾段魔数不是 FBR2"; return NULL; }
    gal_fbr *f = calloc(1, sizeof *f); const uint8_t *q = p + 4, *e = p + len;
    memcpy(f->ok, q, 64); q += 64;
    memcpy(&u, q, 4); q += 4;
    if (u > FBR_MAX_COND || q + 10 * u + 4 > e) { *why = "尾段缩放条件数越界"; goto bad; }
    f->ncond = (int)u;
    for (int k = 0; k < f->ncond; k++) {
        memcpy(&f->cond[k].ubo, q, 2); memcpy(&f->cond[k].off, q + 2, 4); f->cond[k].bit = q[6]; f->cond_bind[k] = q[7]; f->cond[k].kind = q[8];
        int bad_kind = q[8] > FC_FZERO || q[9] || (q[8] == FC_FZERO && q[6]); q += 10;
        if (f->cond[k].ubo >= GS_MAX_BUF || f->cond[k].bit > 31 || bad_kind) { *why = "尾段缩放条件字段越界"; goto bad; }
    }
    memcpy(&u, q, 4); q += 4;
    if (u > FBR_MAX_VAR || q + 26 * u != e) { *why = "尾段变体数与长度不符"; goto bad; }
    for (uint32_t i = 0; i < u; i++, q += 26) {
        int n = q[0], yd = q[1]; uint8_t b[8], s[8]; uint64_t key; memcpy(&key, q + 18, 8);
        if (n < 1 || n > 8 || yd > 1 || !key) { *why = "尾段变体字段越界"; goto bad; }
        if (fbr_norm(q + 2, q + 10, n, b, s) != n || memcmp(b, q + 2, n) || memcmp(s, q + 10, n)) { *why = "尾段变体映射不规整"; goto bad; }
        for (int k = 0; k < n; k++) if (s[k] > 7) { *why = "尾段变体槽号越界"; goto bad; }
        if (!fbr_proved(f, b, n, yd)) { *why = "尾段变体映射不在证明里"; goto bad; }
        if (fbr_var_find(f, b, s, n, yd)) { *why = "尾段变体重复"; goto bad; }
        fbr_var *v = fbr_var_add(f, b, s, n, yd); v->state = FV_TAB; v->key = key;
    }
    return f;
bad:
    gal_fbr_free(f); return NULL;
}
void gal_fbr_view_of(const gal_fbr *f, gal_fbr_view *v) {
    memset(v, 0, sizeof *v); if (!f) return;
    memcpy(v->ok, f->ok, sizeof v->ok); v->ncond = f->ncond;
    for (int k = 0; k < f->ncond; k++) { v->cubo[k] = f->cond[k].ubo; v->coff[k] = f->cond[k].off; v->cbit[k] = f->cond[k].bit; v->cbind[k] = f->cond_bind[k]; v->ckind[k] = f->cond[k].kind; }
    for (int i = 0; i < f->nvar; i++) v->nvar += var_keyed(&f->var[i]);
    v->has_fs = f->fs != NULL;
}

// ---------- 出包（gal_xc --fbr，graphics/metal/tools/gal_xc.c）：不要设备、不取 API 锁（只碰传入的句柄，可多线程各证各的）----------
NXGAL_API void *nxgal_fbr_prove_spv(const void *vs, uint32_t vlen, const void *fs, uint32_t flen) {
    if ((vlen & 3) || (flen & 3)) return NULL;
    return fbr_prove_core(vs, vlen / 4, fs, flen / 4);
}
NXGAL_API void *nxgal_fbr_rewrite_spv(void *h, int32_t n, int32_t ydown, const uint8_t *bind, const uint8_t *slot, uint32_t *len) {
    gal_fbr *f = h; *len = 0;
    uint8_t b[8], s[8]; int m = f && f->fs && (ydown == 0 || ydown == 1) ? fbr_norm(bind, slot, n, b, s) : -1;
    if (m < 0 || !fbr_proved(f, b, m, ydown)) return NULL;
    uint32_t nw = 0, *o = fbr_rewrite(f->fs, f->fsn, b, s, m, &nw);
    if (o) *len = nw * 4;
    return o;
}
NXGAL_API int32_t nxgal_fbr_add_variant(void *h, int32_t n, int32_t ydown, const uint8_t *bind, const uint8_t *slot, uint64_t key) {
    gal_fbr *f = h; uint8_t b[8], s[8]; int m = f && key && (ydown == 0 || ydown == 1) ? fbr_norm(bind, slot, n, b, s) : -1;
    if (m < 0 || !fbr_proved(f, b, m, ydown)) return 0;
    for (int k = 0; k < m; k++) if (s[k] > 7) return 0;
    fbr_var *v = fbr_var_find(f, b, s, m, ydown);
    if (v) return v->key == key;
    v = fbr_var_add(f, b, s, m, ydown); v->state = FV_TAB; v->key = key;
    return 1;
}
NXGAL_API int32_t nxgal_fbr_trailer(const void *h, void *out) { return (int32_t)gal_fbr_ser(h, out); }
NXGAL_API void nxgal_fbr_release(void *h) { gal_fbr_free(h); }
GAL_MTL4_ZONE_END

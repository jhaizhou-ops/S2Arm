// ABI2 host producer, shared by every encode_args entry (including geometry /
// tessellation helpers). This increment changes no allocation or widen policy.
enum { NVN_SIZE_ABI = 2, NVN_SIZE_ABI_FIELD = 12, NVN_SIZE_ABI_OFFSET = 2608,
       NVN_SIZE_ABI_COUNT = 73, NVN_SIZE_ABI_REQUIRED = 3776, NVN_SIZE_ABI_ALLOC = 4096 };
_Static_assert(NVN_SIZE_ABI_OFFSET + NVN_SIZE_ABI_COUNT * 4 * sizeof(int32_t) == NVN_SIZE_ABI_REQUIRED,
               "ABI2 size-table layout");
enum { NVN_SIZE_ABI_TABLE = NVN_SIZE_ABI_REQUIRED - NVN_SIZE_ABI_OFFSET };   // the 73 × 16-byte size table
// A draw writes only a few table entries: the target (entry 0) and the texture entries its tex_scales name. The draw keeps just those (g_size_cur);
//   the cache compares them, the submission (arenas live one submission) and the base block, and the full 4 KB copy is built only on a miss.
//   The base is immutable for its pointer: support_buf() never changes after init, and the widen / internal-resolution copies are fresh arena blocks whenever
//   their values change (wd_rscale, rs_support_cpu). 10-31 iPhone A/B: the 4 KB clear + copy + 3776-byte compare per draw of exact ABI2 shaders cost +6–11% CPU
typedef struct { int n; uint8_t idx[NVN_SIZE_ABI_COUNT]; int32_t v[NVN_SIZE_ABI_COUNT][4]; int32_t tgt[4]; const void *base; } size_cur;
static size_cur g_size_cur[6];
static struct { uint64_t sub, gpu; size_cur k; } g_size_cache[6];
static int size_cur_eq(const size_cur *a, const size_cur *b) {
    return a->base == b->base && a->n == b->n && !memcmp(a->tgt, b->tgt, sizeof a->tgt) && !memcmp(a->idx, b->idx, (size_t)a->n) && !memcmp(a->v, b->v, sizeof a->v[0] * (size_t)a->n);
}

static void size_abi_sizes(const tex_t *guest, id<MTLTexture> view, NSUInteger level,
                           id<MTLTexture> bound, NSUInteger bound_level, int32_t sizes[4]) {
    if (!guest || !guest->d.width || !guest->d.height || !view || !bound) return;
    // The original descriptor and actual view's parent mip supply L. A
    // feedback snapshot can have no parent: only its final dimensions supply P.
    tex_extent logical = tex_extent_at(guest, view, level, 0);
    tex_extent physical = tex_extent_at(NULL, bound, bound_level, 0);
    if (!logical.logical_known || logical.logical.width > INT32_MAX || logical.logical.height > INT32_MAX ||
        physical.physical.width > INT32_MAX || physical.physical.height > INT32_MAX) return;
    sizes[0] = (int32_t)logical.logical.width; sizes[1] = (int32_t)logical.logical.height;
    sizes[2] = (int32_t)physical.physical.width; sizes[3] = (int32_t)physical.physical.height;
}

static void size_abi_attachment(const tex_t *guest, MTLRenderPassAttachmentDescriptor *a, int32_t sizes[4]) {
    id<MTLTexture> view = a.texture; NSUInteger level = a.level;
    // The shared attach path may use a level-zero shadow. Its recorded source
    // retains the selected mip for either a color or depth/stencil attachment.
    for (int j = 0; j < g_nbcrt; j++) if (g_bcrt[j].shadow == a.texture) { view = g_bcrt[j].base; level = g_bcrt[j].level; break; }
    size_abi_sizes(guest, view, level, a.texture, a.level, sizes);
}

static void size_abi_target(MTLRenderPassColorAttachmentDescriptorArray *colors,
                            MTLRenderPassDepthAttachmentDescriptor *depth,
                            MTLRenderPassStencilAttachmentDescriptor *stencil, const p_set_rt *rt) {
    memset(g_size_target, 0, sizeof g_size_target);
    // First actual color attachment, else depth / stencil. A block/depth
    // shadow attaches its own level 0; its source retains the selected mip.
    for (int i = 0; i < rt->n && i < 8; i++) {
        MTLRenderPassAttachmentDescriptor *a = colors[i];
        if (!a.texture) continue;
        size_abi_attachment(rt->color[i], a, g_size_target);
        return;
    }
    MTLRenderPassAttachmentDescriptor *a = depth.texture ? depth : stencil;
    if (a.texture) size_abi_attachment(rt->depth, a, g_size_target);
    // Attachment-less passes have no descriptor-backed L: keep unknown zeros.
}

// The CPU bytes of the support buffer the binding loop binds for this stage (encode_args_ NVN_RB_SUPPORT): the internal-resolution copy, the widen copy or the static one.
//   One definition for every copy built on it (the ABI2 tables here, the #968 unnorm bits in nvn_unnorm.inc), so each is the bound buffer plus its own fields
static const uint8_t *sb_base_cpu(const NvShader *sh, int stage) {
    // F and both legacy render_scale arrays are already finalized by widen.
    // Internal resolution (S2A_RES_SCALE) on: the fragment base is the copy rs_support would bind (pass scale folded into render_scale).
    const uint8_t *rs_base = NULL; if (stage == 1 && rs_on()) rs_support_cpu(sh, &rs_base);
    return rs_base ? rs_base : stage == 1 && g_wd > 0 && g_wd_rs_data ? g_wd_rs_data : support_buf().contents;
}
static void size_abi_begin(const NvShader *sh, int stage) {
    size_cur *c = &g_size_cur[stage]; c->n = 0; memset(c->tgt, 0, sizeof c->tgt);
    c->base = sb_base_cpu(sh, stage);
    // exact=false is a legal legacy_1x program. Zero entries select its legacy
    // helpers; it is not a claim that arbitrary resolution scaling is exact.
    if (sh->size_exact && stage != 5 && g_enc) memcpy(c->tgt, g_size_target, sizeof c->tgt);
}

// Caller holds g_rmu. Capture at the binding site, after all substitutions:
// tex_fit / image-class views / feedback snapshots must be the actual P.
// Never acquire g_wd_mu or recompute a widen request from this path.
static void size_abi_texture(const NvShader *sh, int stage,
                             const nvn_rbind *b, int tid, id<MTLTexture> view, id<MTLTexture> bound) {
    if (!sh->size_abi || !sh->size_exact || !view || !bound || tid <= 0 || tid >= g_ntreg || !g_treg[tid].ok) return;
    if (b->kind != NVN_RB_TEX && b->kind != NVN_RB_IMG) return;
    int image = b->kind == NVN_RB_IMG;
    for (unsigned i = 0; i < sh->nts; i++) {
        unsigned idx = sh->ts[i].idx;
        if (idx < 1 || idx >= NVN_SIZE_ABI_COUNT || sh->ts[i].img != image || sh->ts[i].reg != b->reg) continue;
        int32_t sizes[4] = {0};
        size_abi_sizes(&g_treg[tid].t, view, 0, bound, 0, sizes);
        if (tex_fold_k(&g_treg[tid].t)) { sizes[2] = sizes[0]; sizes[3] = sizes[1]; }   // a folded linear texture (tex_linear): the shader addresses it unfolded
        size_cur *c = &g_size_cur[stage]; int k = 0;
        while (k < c->n && c->idx[k] != idx) k++;   // a later binding of the same entry overwrites it, as the table write did
        if (k == c->n) c->idx[c->n++] = (uint8_t)idx;
        memcpy(c->v[k], sizes, sizeof sizes);
    }
}

static uint64_t size_abi_support(int stage) {
    // GPU pointers are valid only in the submission that owns their arenas.
    const size_cur *c = &g_size_cur[stage];
    if (!g_size_cache[stage].gpu || g_size_cache[stage].sub != g_arena_gen || !size_cur_eq(&g_size_cache[stage].k, c)) {
        id<MTLBuffer> b; size_t off = arena_alloc(NVN_SIZE_ABI_ALLOC, &b); uint8_t *d = (uint8_t *)b.contents + off;
        // Copy only defined bytes; never interpret an arena's old/unwritten tail
        memcpy(d, c->base, NVN_SIZE_ABI_OFFSET); memset(d + NVN_SIZE_ABI_OFFSET, 0, NVN_SIZE_ABI_ALLOC - NVN_SIZE_ABI_OFFSET);
        memcpy(d + NVN_SIZE_ABI_OFFSET, c->tgt, sizeof c->tgt);
        for (int i = 0; i < c->n; i++) memcpy(d + NVN_SIZE_ABI_OFFSET + c->idx[i] * sizeof c->v[0], c->v[i], sizeof c->v[0]);
        g_size_cache[stage].sub = g_arena_gen; g_size_cache[stage].gpu = b.gpuAddress + off; g_size_cache[stage].k = *c;
    }
    return g_size_cache[stage].gpu;
}
// The table follows the pass, not the draw (#967 contract): an exact ABI2 shader without texture entries (tex_scales empty: Mario Kart 8 Deluxe 19,810 of its 29,651
//   shaders) reads only entry 0, the attachment size, which changes when a pass opens. Its support copy is the base block (as the NVN_RB_SUPPORT binding of every other
//   program: widen / internal-resolution copy or the static one) with entry 0 filled, one per stage per base and target in a submission, bound like the legacy support buffer
//   in the binding loop: no per-draw table, no deferred finalize, the argument block reuse path unchanged. Shaders with texture entries keep the per-draw table (size_abi_texture)
static struct { uint64_t sub, gpu; const void *base; int32_t tgt[4]; } g_size_pass[6];
static uint64_t size_abi_pass_support_on(int stage, const void *base) {   // base: sb_base_cpu, or the #968 unnorm copy built on it
    int32_t tgt[4] = {0}; if (stage != 5 && g_enc) memcpy(tgt, g_size_target, sizeof tgt);
    typeof(g_size_pass[0]) *c = &g_size_pass[stage];
    if (!c->gpu || c->sub != g_arena_gen || c->base != base || memcmp(c->tgt, tgt, sizeof tgt)) {
        id<MTLBuffer> b; size_t off = arena_alloc(NVN_SIZE_ABI_ALLOC, &b); uint8_t *d = (uint8_t *)b.contents + off;
        memcpy(d, base, NVN_SIZE_ABI_OFFSET); memset(d + NVN_SIZE_ABI_OFFSET, 0, NVN_SIZE_ABI_ALLOC - NVN_SIZE_ABI_OFFSET); memcpy(d + NVN_SIZE_ABI_OFFSET, tgt, sizeof tgt);
        c->sub = g_arena_gen; c->gpu = b.gpuAddress + off; c->base = base; memcpy(c->tgt, tgt, sizeof tgt);
    }
    return c->gpu;
}
static uint64_t size_abi_pass_support(const NvShader *sh, int stage) { return size_abi_pass_support_on(stage, sb_base_cpu(sh, stage)); }
static void size_abi_reset(void) {
    memset(g_size_cache, 0, sizeof g_size_cache); memset(g_size_cur, 0, sizeof g_size_cur); memset(g_size_pass, 0, sizeof g_size_pass);
    memset(g_size_target, 0, sizeof g_size_target);
}

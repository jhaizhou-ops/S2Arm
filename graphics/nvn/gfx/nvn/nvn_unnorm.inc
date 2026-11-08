// #968 step 1 (iOS host half): per-draw coordinate normalization bits in the support buffer's s2a_flags.yzw.
// Contract (issue #968, comments 6598314805 / 6598643693 / 6598775340): a texture binding's bit = 1 when the coordinates it is sampled with are
//   unnormalized, which the NVN driver decides from the effective target alone (step 0, from the game's own NVN driver in SDK 6.4 / 10.9 / 20.5):
//   effective target = the view's target when the view called nvnTextureViewSetTarget, else the texture's; RECTANGLE (7) = unnormalized, every other = normalized.
//   Taken from the intercepted Builder / View SetTarget values (hle_nvn.c), never from guest NVN object offsets (20.5 changed their layout).
// Which bit: the translator writes it per TEX binding into the reflection (json unnorm_bit = SupportBuffer.S2ATexUnnormBit(the SPIR-V binding the
//   translator's texOp.Binding is), Dsh.cs Reflect); bit p is s2a_flags word 1 + p / 32, bit p % 32 (TexturePass S2AInsertCoordNormalizationRuntime).
//   No unnorm_bit (an older library, a binding outside the bitmap, indexed / bindless / buffer textures) = no bit: those keep the normalization compiled in.
// s2a_flags.x is left as it is. With no bit set the stage binds the very buffer it bound before (byte for byte); with bits it gets its own copy:
//   vertex and fragment both number from binding 1 on iOS (dmsh_xlate Accessor), so their bits share word y and cannot share one buffer.
// Each copy is a fresh 4 KB arena block of this submission, written once and never again (a snapshot per draw); within a submission equal
//   contents reuse one block, which is the same bytes. The argument block reuse in encode_args_ keys on the submission while such a copy is bound (ab_ub).
enum { NVN_SB_S2A_FLAGS = 1392, NVN_SB_COPY = 4096 };
_Static_assert(NVN_SB_S2A_FLAGS + 16 <= NVN_SIZE_ABI_OFFSET, "s2a_flags lies in the bytes every support copy carries");

static inline int ub_eff_target(const tex_t *t, const view_t *v, int has_v) { return has_v && v->set_target ? (int)v->target : (int)t->d.target; }
// Caller holds g_rmu (encode_args_). tid: the texture ID the binding resolved to this draw; unregistered = nothing to read, no bit
static void ub_note(uint32_t w[3], int bit, int tid) {
    if (bit < 0 || bit >= 96 || tid < 0 || tid >= g_ntreg || !g_treg[tid].ok) return;
    if (ub_eff_target(&g_treg[tid].t, &g_treg[tid].v, g_treg[tid].has_v) == NVN_TEXTURE_TARGET_RECTANGLE) w[bit / 32] |= 1u << (bit % 32);
}
// The support copy with the bits: base (sb_base_cpu, the bytes the stage would bind) plus s2a_flags.yzw |= w. Returns its CPU bytes, *gpu its address
static struct { uint64_t sub, gpu; const void *base; uint32_t w[3]; const uint8_t *cpu; } g_ub_cache[6];
static const uint8_t *ub_support(int stage, const uint8_t *base, const uint32_t w[3], uint64_t *gpu) {
    typeof(g_ub_cache[0]) *c = &g_ub_cache[stage];
    if (!c->gpu || c->sub != g_arena_gen || c->base != base || memcmp(c->w, w, sizeof c->w)) {
        id<MTLBuffer> b; size_t off = arena_alloc(NVN_SB_COPY, &b); uint8_t *d = (uint8_t *)b.contents + off;
        memcpy(d, base, NVN_SB_COPY);
        for (int i = 0; i < 3; i++) { uint32_t x; memcpy(&x, d + NVN_SB_S2A_FLAGS + 4 + 4 * i, 4); x |= w[i]; memcpy(d + NVN_SB_S2A_FLAGS + 4 + 4 * i, &x, 4); }
        c->sub = g_arena_gen; c->gpu = b.gpuAddress + off; c->base = base; memcpy(c->w, w, sizeof c->w); c->cpu = d;
    }
    *gpu = c->gpu; return c->cpu;
}

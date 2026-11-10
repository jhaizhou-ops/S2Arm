// See hdr.h. Field order and checks follow docs/设计_原生VP9/design_phase2_B.md §2 (header) and §3 (slot map).
#include "hdr.h"

#include <assert.h>
#include <string.h>

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

void s2a_pic_parse(const uint8_t *b, s2a_pic *p)
{
    memset(p, 0, sizeof *p);
    p->bitstream_size = rd32(b + 48);
    for (int i = 0; i < 4; i++)
    {
        p->size_w[i] = rd16(b + 72 + 8 * i);
        p->size_h[i] = rd16(b + 74 + 8 * i);
    }
    p->flags = rd32(b + 104);
    memcpy(p->sign_bias, b + 108, 4);
    p->filter_level = b[112];
    p->sharpness = b[113];
    p->base_q = b[114];
    p->y_dc = b[115];
    p->uv_ac = b[116];
    p->uv_dc = b[117];
    p->lossless = b[118];
    p->tx_mode = b[119];
    p->allow_hp = b[120];
    p->interp = b[121];
    p->ref_mode = b[122];
    p->comp_fixed_ref = (int8_t)b[123];
    p->comp_var_ref[0] = (int8_t)b[124];
    p->comp_var_ref[1] = (int8_t)b[125];
    p->log2_tile_cols = b[126];
    p->log2_tile_rows = b[127];
    p->seg_enabled = b[128];
    p->mode_ref_delta_enabled = b[228];
    memcpy(p->ref_deltas, b + 229, 4);
    memcpy(p->mode_deltas, b + 233, 2);
    p->surface_params = rd32(b + 240);
}

int s2a_use_prev_mvs(const s2a_pic *p)
{
    uint32_t f = p->flags;
    return !(f & S2A_KEY) && !(f & S2A_ERROR_RES) && !(f & S2A_SIZE_CHANGED) && !(f & S2A_INTRA_ONLY) &&
           (f & S2A_LAST_SHOW) && !(f & S2A_LAST_KEY);
}

// ---- probability and count layouts (Ryujinx structs, sequential, no padding) ----

typedef struct {
    uint8_t kf_y_e0_7[10][10][8], kf_y_e8[10][10], pad384[3], seg_tree[7], seg_pred[3], pad391[15];
    uint8_t kf_uv_e0_7[10][8], kf_uv_e8[10], pad3fa[6], inter_mode[7][4], intra_inter[4], uv_e0_7[10][8];
    uint8_t tx8[2][1], tx16[2][2], tx32[2][3], y_e8[4], y_e0_7[4][8], kf_part[16][4], part[16][4], uv_e8[10];
    uint8_t sw_interp[4][2], comp_inter[5], skip[4], joints[3], sign[2], class0[2][1], fp[2][3], class0_hp[2], hp[2];
    uint8_t classes[2][10], class0_fp[2][2][3], bits[2][10], single_ref[5][2], comp_ref[5], pad58f[17];
    uint8_t coef[4][2][2][6][6][4];
} nvdec_probs;

typedef struct {
    uint8_t kf_y_mode[10][10][9], seg_tree[7], seg_pred[3], kf_uv_mode[10][9], y_mode[4][9], uv_mode[10][9];
    uint8_t kf_partition[16][3], partition[16][3], coef[4][2][2][6][6][3], switchable_interp[4][2], inter_mode[7][3];
    uint8_t intra_inter[4], comp_inter[5], single_ref[5][2], comp_ref[5], tx32[2][3], tx16[2][2], tx8[2][1], skip[3];
    uint8_t joints[3], sign[2], classes[2][10], class0[2][1], bits[2][10], class0_fp[2][2][3], fp[2][3], class0_hp[2],
        hp[2];
} vp9_probs;

typedef struct {
    uint32_t y_mode[4][10], uv_mode[10][10], partition[16][4], coef[4][2][2][6][6][4], eob[4][2][2][6][6];
    uint32_t sw_interp[4][3], inter_mode[7][4], intra_inter[4][2], comp_inter[5][2], single_ref[5][2][2],
        comp_ref[5][2];
    uint32_t tx32[2][4], tx16[2][3], tx8[2][2], skip[3][2], joints[4], sign[2][2], classes[2][11], class0[2][2];
    uint32_t bits[2][10][2], class0_fp[2][2][4], fp[2][4], class0_hp[2][2], hp[2][2];
} vp9_counts;

typedef struct {
    uint32_t inter_mode[7][3][2], y_mode[4][10], uv_mode[10][10], partition[16][4], sw_interp[4][3];
    uint32_t intra_inter[4][2], comp_inter[5][2], single_ref[5][2][2], comp_ref[5][2], tx32[2][4], tx16[2][3];
    uint32_t tx8[2][2], skip[3][2], joints[4], sign[2][2], classes[2][11], class0[2][2], bits[2][10][2];
    uint32_t class0_fp[2][2][4], fp[2][4], class0_hp[2][2], hp[2][2], coef[4][2][2][6][6][4], eob[4][2][2][6][6];
} nvdec_counts;

static_assert(sizeof(nvdec_probs) == S2A_NVDEC_ENTROPY_SIZE, "NVDEC EntropyProbs");
static_assert(sizeof(vp9_probs) == 3087, "Vp9EntropyProbs");
static_assert(sizeof(vp9_counts) == 13208, "Vp9BackwardUpdates");
static_assert(sizeof(nvdec_counts) == S2A_NVDEC_COUNTS_SIZE, "BackwardUpdates (guest layout)");

void s2a_entropy_convert(const uint8_t *in, uint8_t *out)
{
    nvdec_probs g;
    vp9_probs f;
    memcpy(&g, in, sizeof g);
    memset(&f, 0, sizeof f);
    for (int i = 0; i < 10; i++)
        for (int j = 0; j < 10; j++)
        {
            memcpy(f.kf_y_mode[i][j], g.kf_y_e0_7[i][j], 8);
            f.kf_y_mode[i][j][8] = g.kf_y_e8[i][j];
        }
    memcpy(f.seg_tree, g.seg_tree, 7);
    memcpy(f.seg_pred, g.seg_pred, 3);
    for (int i = 0; i < 7; i++) memcpy(f.inter_mode[i], g.inter_mode[i], 3);
    memcpy(f.intra_inter, g.intra_inter, 4);
    for (int i = 0; i < 10; i++)
    {
        memcpy(f.kf_uv_mode[i], g.kf_uv_e0_7[i], 8);
        f.kf_uv_mode[i][8] = g.kf_uv_e8[i];
        memcpy(f.uv_mode[i], g.uv_e0_7[i], 8);
        f.uv_mode[i][8] = g.uv_e8[i];
    }
    memcpy(f.tx8, g.tx8, sizeof f.tx8);
    memcpy(f.tx16, g.tx16, sizeof f.tx16);
    memcpy(f.tx32, g.tx32, sizeof f.tx32);
    for (int i = 0; i < 4; i++)
    {
        memcpy(f.y_mode[i], g.y_e0_7[i], 8);
        f.y_mode[i][8] = g.y_e8[i];
    }
    for (int i = 0; i < 16; i++)
    {
        memcpy(f.kf_partition[i], g.kf_part[i], 3);
        memcpy(f.partition[i], g.part[i], 3);
    }
    memcpy(f.switchable_interp, g.sw_interp, sizeof f.switchable_interp);
    memcpy(f.comp_inter, g.comp_inter, 5);
    memcpy(f.skip, g.skip, 3);
    memcpy(f.joints, g.joints, 3);
    memcpy(f.sign, g.sign, 2);
    memcpy(f.class0, g.class0, sizeof f.class0);
    memcpy(f.fp, g.fp, sizeof f.fp);
    memcpy(f.class0_hp, g.class0_hp, 2);
    memcpy(f.hp, g.hp, 2);
    memcpy(f.classes, g.classes, sizeof f.classes);
    memcpy(f.class0_fp, g.class0_fp, sizeof f.class0_fp);
    memcpy(f.bits, g.bits, sizeof f.bits);
    memcpy(f.single_ref, g.single_ref, sizeof f.single_ref);
    memcpy(f.comp_ref, g.comp_ref, 5);
    for (int a = 0; a < 4; a++)
        for (int b = 0; b < 2; b++)
            for (int c = 0; c < 2; c++)
                for (int d = 0; d < 6; d++)
                    for (int e = 0; e < 6; e++) memcpy(f.coef[a][b][c][d][e], g.coef[a][b][c][d][e], 3);
    memcpy(out, &f, sizeof f);
}

size_t s2a_counts_to_guest(const uint8_t *in, uint8_t *out)
{
    vp9_counts c;
    nvdec_counts g;
    memcpy(&c, in, sizeof c);
    for (int i = 0; i < 7; i++)
    {
        const uint32_t *m = c.inter_mode[i];
        g.inter_mode[i][0][0] = m[2];
        g.inter_mode[i][0][1] = m[0] + m[1] + m[3];
        g.inter_mode[i][1][0] = m[0];
        g.inter_mode[i][1][1] = m[1] + m[3];
        g.inter_mode[i][2][0] = m[1];
        g.inter_mode[i][2][1] = m[3];
    }
#define CP(x) memcpy(g.x, c.x, sizeof g.x)
    CP(y_mode); CP(uv_mode); CP(partition); CP(sw_interp); CP(intra_inter); CP(comp_inter); CP(single_ref);
    CP(comp_ref); CP(tx32); CP(tx16); CP(tx8); CP(skip); CP(joints); CP(sign); CP(classes); CP(class0); CP(bits);
    CP(class0_fp); CP(fp); CP(class0_hp); CP(hp); CP(coef); CP(eob);
#undef CP
    memcpy(out, &g, sizeof g);
    return sizeof g;
}

// ---- bit writer and header ----

typedef struct {
    uint8_t *p;
    size_t cap, bit;
} bw;

static void put(bw *w, uint32_t v, int n)
{
    for (int i = n - 1; i >= 0; i--, w->bit++)
    {
        size_t byte = w->bit >> 3;
        if (byte >= w->cap) continue;
        if ((w->bit & 7) == 0) w->p[byte] = 0;
        if ((v >> i) & 1) w->p[byte] |= (uint8_t)(0x80 >> (w->bit & 7));
    }
}

static void put_signed(bw *w, int v, int n)   // magnitude, then sign (vpx_rb_read_signed_literal)
{
    put(w, (uint32_t)(v < 0 ? -v : v), n);
    put(w, v < 0, 1);
}

static void tile_range(int width, int *min_log2, int *max_log2)
{
    const int mi_cols = (width + 7) >> 3;
    const int sb64_cols = (mi_cols + 7) >> 3;
    int mn = 0, mx = 1;
    while ((64 << mn) < sb64_cols) mn++;
    while ((sb64_cols >> mx) >= 4) mx++;
    *min_log2 = mn;
    *max_log2 = mx - 1;
}

void s2a_slots_reset(s2a_slots *slots) { memset(slots, 0, sizeof *slots); }

static int find_slot(const s2a_slots *s, uint32_t luma, uint32_t chroma, int w, int h)
{
    for (int i = 0; i < 8; i++)
        if (s->s[i].valid && s->s[i].luma == luma && s->s[i].chroma == chroma && s->s[i].w == w && s->s[i].h == h)
            return i;
    return -1;
}

const char *s2a_build_frame(const s2a_pic *p, const s2a_surfaces *sf, s2a_slots *slots, const uint8_t *tiles,
                            size_t tiles_size, uint8_t *dst, size_t cap, size_t *len, int *target)
{
    const int key = (p->flags & S2A_KEY) != 0;
    const int intra_only = !key && (p->flags & S2A_INTRA_ONLY);
    const int w = p->size_w[3], h = p->size_h[3];
    const unsigned bit_depth = (p->surface_params >> 1) & 0xf;
    int min_log2, max_log2, ref_idx[3] = { 0, 0, 0 };

    // §2 checks
    if (p->seg_enabled) return "segmentation";
    if (bit_depth != 0 && bit_depth != 8) return "bit depth";
    if (w < 1 || h < 1 || w > 8192 || h > 8192) return "frame size";
    if (p->tx_mode > 4) return "tx_mode";
    if (p->ref_mode > 2) return "reference_mode";
    if (p->interp > 4) return "interp_filter";
    if (p->filter_level > 63 || p->sharpness > 7) return "loop filter level";
    if (p->y_dc > 15 || p->uv_dc > 15 || p->uv_ac > 15) return "delta_q > 15";
    if ((p->lossless != 0) != (p->base_q == 0 && p->y_dc == 0 && p->uv_dc == 0 && p->uv_ac == 0)) return "lossless";
    for (int i = 0; i < 4; i++)
        if (p->ref_deltas[i] > 63 || p->ref_deltas[i] < -63) return "loop filter delta";
    for (int i = 0; i < 2; i++)
        if (p->mode_deltas[i] > 63 || p->mode_deltas[i] < -63) return "loop filter delta";
    for (int i = 1; i < 4; i++)
        if (p->sign_bias[i] != 0 && p->sign_bias[i] != 1) return "sign bias";
    tile_range(w, &min_log2, &max_log2);
    if (p->log2_tile_cols < min_log2 || p->log2_tile_cols > max_log2) return "tile columns";
    if (p->log2_tile_rows > 2) return "tile rows";

    // §3 slots
    slots->now++;
    int referenced[8] = { 0 };
    if (!key && !intra_only)
        for (int r = 0; r < 3; r++)
        {
            ref_idx[r] = find_slot(slots, sf->luma[r], sf->chroma[r], p->size_w[r], p->size_h[r]);
            if (ref_idx[r] < 0) return "reference not in a slot";
            referenced[ref_idx[r]] = 1;
            slots->s[ref_idx[r]].last_use = slots->now;
        }
    if (key)
        *target = -1;   // all 8
    else
    {
        // Target slot, first rule that applies: (1) a valid slot already holding the output offset and not
        // referenced; (2) an invalid slot; (3) the least recently used valid slot not referenced, lowest index on ties.
        int t = -1;
        for (int i = 0; i < 8 && t < 0; i++)
            if (slots->s[i].valid && slots->s[i].luma == sf->luma[3] && !referenced[i]) t = i;
        for (int i = 0; i < 8 && t < 0; i++)
            if (!slots->s[i].valid) t = i;
        if (t < 0)
        {
            uint64_t best = UINT64_MAX;
            for (int i = 0; i < 8; i++)
                if (slots->s[i].valid && !referenced[i] && slots->s[i].last_use < best)
                {
                    best = slots->s[i].last_use;
                    t = i;
                }
        }
        for (int r = 0; r < 3 && !intra_only; r++)
            if (sf->luma[r] == sf->luma[3]) return "decoding in place";
        if (t < 0) return "no free slot";
        *target = t;
    }

    // §2 header
    bw b = { dst, cap, 0 };
    put(&b, 2, 2);                 // frame_marker
    put(&b, 0, 2);                 // profile 0
    put(&b, 0, 1);                 // show_existing_frame
    put(&b, key ? 0 : 1, 1);       // frame_type
    put(&b, intra_only ? 0 : 1, 1); // show_frame
    put(&b, 0, 1);                 // error_resilient_mode
    if (key)
    {
        put(&b, 0x49, 8); put(&b, 0x83, 8); put(&b, 0x42, 8);
        put(&b, 0, 3);             // color_space (unknown)
        put(&b, 0, 1);             // color_range
        put(&b, (uint32_t)(w - 1), 16); put(&b, (uint32_t)(h - 1), 16);
        put(&b, 0, 1);             // render_and_frame_size_different
    }
    else
    {
        if (intra_only) put(&b, 1, 1);   // intra_only (show_frame is 0)
        put(&b, 0, 2);                   // reset_frame_context
        if (intra_only)
        {
            put(&b, 0x49, 8); put(&b, 0x83, 8); put(&b, 0x42, 8);
            put(&b, 1u << *target, 8);   // refresh_frame_flags
            put(&b, (uint32_t)(w - 1), 16); put(&b, (uint32_t)(h - 1), 16);
            put(&b, 0, 1);
        }
        else
        {
            put(&b, 1u << *target, 8);
            for (int r = 0; r < 3; r++)
            {
                put(&b, (uint32_t)ref_idx[r], 3);
                put(&b, (uint32_t)p->sign_bias[r + 1], 1);
            }
            put(&b, 0, 3);               // found_ref x3
            put(&b, (uint32_t)(w - 1), 16); put(&b, (uint32_t)(h - 1), 16);
            put(&b, 0, 1);
            put(&b, p->allow_hp != 0, 1);
            put(&b, p->interp == 4, 1);
            if (p->interp != 4) put(&b, p->interp, 2);
        }
    }
    put(&b, 0, 1);                 // refresh_frame_context
    put(&b, 0, 1);                 // frame_parallel_decoding_mode
    put(&b, 0, 2);                 // frame_context_idx
    put(&b, p->filter_level, 6);
    put(&b, p->sharpness, 3);
    put(&b, p->mode_ref_delta_enabled != 0, 1);
    if (p->mode_ref_delta_enabled)
    {
        put(&b, 1, 1);             // mode_ref_delta_update
        for (int i = 0; i < 4; i++) { put(&b, 1, 1); put_signed(&b, p->ref_deltas[i], 6); }
        for (int i = 0; i < 2; i++) { put(&b, 1, 1); put_signed(&b, p->mode_deltas[i], 6); }
    }
    put(&b, p->base_q, 8);
    const int dq[3] = { p->y_dc, p->uv_dc, p->uv_ac };
    for (int i = 0; i < 3; i++)
    {
        put(&b, dq[i] != 0, 1);
        if (dq[i]) put_signed(&b, dq[i], 4);
    }
    put(&b, 0, 1);                 // segmentation_enabled
    for (int k = min_log2; k < max_log2; k++)
    {
        put(&b, p->log2_tile_cols > k, 1);
        if (p->log2_tile_cols <= k) break;
    }
    put(&b, p->log2_tile_rows != 0, 1);
    if (p->log2_tile_rows) put(&b, p->log2_tile_rows == 2, 1);
    put(&b, 1, 16);                // header_size_in_bytes
    size_t n = (b.bit + 7) >> 3;
    if (n + 1 + tiles_size > cap) return "frame buffer too small";
    if (b.bit & 7) dst[n - 1] &= (uint8_t)(0xff << (8 - (b.bit & 7)));
    dst[n++] = 0;                  // stand-in compressed header
    memcpy(dst + n, tiles, tiles_size);
    *len = n + tiles_size;
    return NULL;
}

void s2a_slots_commit(s2a_slots *slots, const s2a_pic *p, const s2a_surfaces *sf, int target)
{
    const s2a_slot out = { sf->luma[3], sf->chroma[3], p->size_w[3], p->size_h[3], 1, slots->now };
    for (int i = 0; i < 8; i++)
    {
        if (target < 0 || i == target)
            slots->s[i] = out;
        else if (slots->s[i].luma == sf->luma[3])
            slots->s[i].valid = 0;
    }
}

// Storage size / alignment / per-level offsets of NVN textures (Tegra X1 block-linear layout).
// The algorithm is ported from deko3d source/dk_image.cpp (zlib license, Copyright (C) 2018-2020 fincs):
//   one GOB = 64 bytes × 8 rows = 512 bytes; the block height (tileH, in GOBs) is picked by 'height×1.5'; levels are accumulated with block alignment.
// The game's packaged textures (SetPackagedTextureLayout) carry 8 bytes of layout parameters: byte 0 = log2 of the block height (derived by comparing 16 cases from the real game,
// 4 of which differ from the automatic algorithm); when present it takes precedence.
#include "nvn_tex.h"
#include "nvn_fmt_info.h"

typedef struct { uint8_t bpb, bw, bh; } fmt_t;   // Bytes per block, block width, block height (for uncompressed formats block width and height = 1)

static fmt_t fmt_of(int f) {
    nvn_fmt_info i;
    if (!nvn_fmt_info_of((uint32_t)f, &i)) return (fmt_t){0, 1, 1};
    return (fmt_t){i.bytes, i.bw, i.bh};
}

int nvn_fmt_bpb(int f, int *bw, int *bh) { fmt_t t = fmt_of(f); if (bw) *bw = t.bw; if (bh) *bh = t.bh; return t.bpb; }

static uint32_t mip(uint32_t s, unsigned l) { s >>= l; return s ? s : 1; }
static uint32_t blk(uint32_t s, uint32_t b) { return (s + b - 1) / b; }
static unsigned pick_tile(uint32_t gobs) { return gobs >= 16 ? 4 : gobs >= 8 ? 3 : gobs >= 4 ? 2 : gobs >= 2 ? 1 : 0; }
// The automatic block height (no packaged layout): NVN truncates height in blocks × 1.5 / 8 before picking the power of two (found by MacNativeGames; Touchable checked
//   16 such textures of Rhythm Heaven Groove). Rounding it up, as this file did until then, gave one step more at 6–10, 17–21, 38–42 and 81–85 block rows: Rhythm Heaven
//   Groove's 672×160 and 1232×160 BC7 textures (40 block rows) need 4 GOBs, not 8 (the calibration screen's beat numbers came out torn); its 112×112, 288×208 and 880×432 agree
static unsigned adj_tile(unsigned shift, uint32_t unit, uint32_t dim) {
    if (!shift) return 0;
    uint32_t x = unit << (shift - 1);
    if (x >= dim) while (--shift) { x >>= 1; if (x < dim) break; }
    return shift;
}

// target: NVNtextureTarget; the number of dims and whether it is layered are determined by target
static void shape(const nvn_texdesc *d, unsigned *dpl, int *layered, uint32_t *w, uint32_t *h, uint32_t *z) {
    *w = d->width; *h = d->height; *z = d->depth; *layered = 0;
    switch (d->target) {
        case 0: *dpl = 1; *h = 1; *z = 1; break;                       // 1D
        case 3: *dpl = 1; *z = d->height; *h = 1; *layered = 1; break; // 1D_ARRAY (layer count is in height)
        case 2: *dpl = 3; break;                                        // 3D
        case 4: case 6: *dpl = 2; *layered = 1; break;                  // 2D_ARRAY / MS_ARRAY
        case 8: *dpl = 2; *z = 6; *layered = 1; break;                  // CUBEMAP
        case 9: *dpl = 2; *layered = 1; break;                          // CUBEMAP_ARRAY: the depth counts layer-faces, as in OpenGL (DRAGON QUEST XI S: 510 for 85 cubes)
        default: *dpl = 2; *z = 1; break;                               // 2D / MS / RECTANGLE
    }
    if (*z == 0) *z = 1;
}

static void samples_xy(int s, uint32_t *sx, uint32_t *sy) {
    *sx = *sy = 1;
    if (s == 2) *sx = 2; else if (s == 4) *sx = *sy = 2; else if (s == 8) { *sx = 4; *sy = 2; }
}

// Sparse textures (flag SPARSE, block-linear) are mapped in 64 KB tiles: one row of blocks, 128 GOBs / (block height × block depth) wide. A level at least one tile wide, high and deep
// is laid out with its width padded to whole tiles, so it fills whole tiles; the levels from the first smaller one on form the mip tail, packed as usual from there, and the
// storage is whole tiles, 64 KB aligned. Monster Hunter Rise's streamed textures come pre-swizzled that way in its files and are placed at the level offsets the host reports: laid out unpadded,
// its 1024×1024 ASTC 6×6 textures (48 GOBs wide instead of 43, level 1 at 0x90000 instead of 0x81000) read 2,183 all-zero blocks in level 0 and 3,043 in level 1, which ASTC
// decodes as its error colour (magenta clothes)
enum { SPARSE_TILE = 0x10000 };
static int sparse_of(const nvn_texdesc *d) { return (d->flags & 0x20) && !(d->flags & (0x10 | 0x40)) && d->target != 10; }
// The shape of a sparse texture's 64 KB page, chosen by texel size (log2: GOB columns *x, block height *y in GOBs, block depth *z); 0 when the texture has no sparse pages.
// A sparse texture without a packaged layout is laid out with this block height / depth, not the automatic one: Samurai Shodown's 512×512 ASTC 6×6 sparse textures
//   (86 block rows) come with level 0 pre-swizzled as 2×2 pages = 0x40000 bytes (16 GOBs × 8 GOBs a page); with the automatic 16-GOB block height level 0 was not
//   page-aligned, came out 0x2c000, and the game's upload of the 0x40000 bytes overran the staging buffer it sized from our level offsets (crash at frame ~1990).
//   Monster Hunter Rise's packaged block height for the same kind of texture is the same 8 GOBs.
static int sparse_page(const nvn_texdesc *d, fmt_t t, unsigned *x, unsigned *y, unsigned *z) {
    if (!t.bpb || t.bpb == 12 || (d->flags & 0x32) != 0x20 || d->target == 0 || d->target == 3 || d->target == 10) return 0;
    if (d->target == 2) {
        if (t.bpb == 4) { *x = 1; *y = 2; *z = 4; }
        else if (t.bpb == 8 || t.bpb == 16) { *x = 2; *y = 1; *z = 4; }
        else { *x = 0; *y = 2; *z = 5; }
    } else {
        if (t.bpb == 2 || t.bpb == 4) { *x = 3; *y = 4; *z = 0; }
        else if (t.bpb == 8 || t.bpb == 16) { *x = 4; *y = 3; *z = 0; }
        else { *x = 2; *y = 5; *z = 0; }
    }
    return 1;
}
// A sparse texture with no level at least one page wide, high and deep (NVN's sparse query reports 0 tiled levels) is all mip tail: it is laid out as a plain texture, with the
//   automatic block height. Samurai Shodown's 700×200 ASTC 6×6 sparse menu labels (34 block rows, page 384×384) come with the automatic 4-GOB block height; with the page's
//   8 GOBs, block columns 60 on read as all-zero blocks, which ASTC decodes as its error colour (magenta blocks over the main menu labels, 10-27)
static int sparse_levels(const nvn_texdesc *d) { uint32_t tl[4]; nvn_tex_sparse_layout(d, tl); return tl[0] != 0; }
// Offset of level `level` from the start of its layer, and the GOB columns it is laid out with (*gobs, may be NULL)
static uint64_t level_walk(const nvn_texdesc *d, unsigned level, unsigned dpl, uint32_t w, uint32_t h, uint32_t z,
                           unsigned tileH, unsigned tileD, fmt_t t, uint32_t *gobs) {
    uint32_t sx, sy; samples_xy(d->samples, &sx, &sy);
    uint32_t tw = 128u >> (tileH + tileD); if (!tw) tw = 1;   // GOB columns of a 64 KB tile
    int tiled = sparse_of(d) && sparse_levels(d);   // still in a sparse texture's tiled levels
    uint64_t off = 0;
    for (unsigned i = 0;; i++) {
        uint32_t lw = blk(mip(w * sx, i), t.bw);
        uint32_t lh = dpl >= 2 ? blk(mip(h * sy, i), t.bh) : 1;
        uint32_t ld = dpl >= 3 ? mip(z, i) : 1;
        uint32_t lwb = lw * t.bpb;
        unsigned th = adj_tile(tileH, 8, lh), td = adj_tile(tileD, 1, ld);
        uint32_t wg = (lwb + 63) / 64, hg = (lh + 7) / 8;
        tiled = tiled && lwb >= tw * 64 && lh >= 8u << tileH && ld >= 1u << tileD;
        if (tiled) wg = (wg + tw - 1) / tw * tw;
        if (i == level) { if (gobs) *gobs = wg; return off; }
        uint32_t ht = (hg + (1u << th) - 1) >> th, dt = (ld + (1u << td) - 1) >> td;
        off += (uint64_t)wg * ht * dt << (9 + th + td);
    }
}
static uint64_t level_offset(const nvn_texdesc *d, unsigned level, unsigned dpl, uint32_t w, uint32_t h, uint32_t z, unsigned tileH, unsigned tileD, fmt_t t) {
    return level_walk(d, level, dpl, w, h, z, tileH, tileD, t, 0);
}

void nvn_tex_layout(const nvn_texdesc *d, nvn_texlayout *o) {
    fmt_t t = fmt_of(d->format);
    unsigned dpl; int layered; uint32_t w, h, z;
    shape(d, &dpl, &layered, &w, &h, &z);
    uint32_t sx, sy; samples_xy(d->samples, &sx, &sy);
    o->bpb = t.bpb; o->tileH = o->tileD = 0; o->layers = layered ? z : 1;
    if (!t.bpb) { o->size = 0; o->align = 512; o->layer_size = 0; return; }
    if (d->target == 10) {                                            // BUFFER
        o->layer_size = o->size = (uint64_t)t.bpb * d->width;
        o->align = t.bpb == 12 ? 4 : t.bpb; return;
    }
    if (d->flags & (0x10 | 0x40)) {                                   // LINEAR / LINEAR_RENDER_TARGET: row pitch = stride or aligned to 32 (128 for render targets);
                                                                      //   0x40 alone is linear too (10-29 1-2-Switch video frames: stride set, uploaded by row memcpy, heap sized for linear)
        o->align = (d->flags & 0x40) ? 128 : 32;
        uint32_t stride = d->stride ? d->stride : (t.bpb * blk(w, t.bw) + o->align - 1) & ~(o->align - 1);
        o->layer_size = o->size = (uint64_t)stride * blk(h, t.bh);
        return;
    }
    unsigned tileH = 0, tileD = 0;
    unsigned px, py, pz;
    if (dpl == 2) { uint32_t ah = blk(h * sy, t.bh); tileH = d->pkg_block_h ? (unsigned)d->pkg_block_h - 1 : sparse_page(d, t, &px, &py, &pz) && sparse_levels(d) ? py : pick_tile(ah * 3 / 16); }
    else if (dpl == 3) { if (sparse_page(d, t, &px, &py, &pz)) { tileH = py; tileD = pz; } else tileD = pick_tile(z + z / 2); }
    o->tileH = tileH; o->tileD = tileD;
    unsigned levels = d->levels ? d->levels : 1;
    uint64_t ls = level_offset(d, levels, dpl, w, h, z, tileH, tileD, t);
    if (sparse_of(d)) ls = (ls + SPARSE_TILE - 1) & ~(uint64_t)(SPARSE_TILE - 1);
    if (layered) {                                                    // Layer size is aligned to the block
        uint32_t hh = blk(h, t.bh); unsigned th = tileH, td = tileD;
        while (th && hh <= (8u << (th - 1))) th--;
        while (td && z <= (1u << (td - 1))) td--;
        unsigned sh = th + td + 9; uint64_t g = ls >> sh;
        if (ls != g << sh) ls = (g + 1) << sh;
    }
    o->layer_size = ls;
    o->size = layered ? ls * z : ls;
    o->align = sparse_of(d) ? SPARSE_TILE : 512;
}

uint64_t nvn_tex_level_offset(const nvn_texdesc *d, unsigned level) {
    fmt_t t = fmt_of(d->format);
    unsigned dpl; int layered; uint32_t w, h, z;
    shape(d, &dpl, &layered, &w, &h, &z);
    if (!t.bpb || (d->flags & (0x10 | 0x40)) || d->target == 10) return 0;   // linear (LINEAR / LINEAR_RENDER_TARGET, as nvn_tex_layout): one level at 0
    nvn_texlayout L; nvn_tex_layout(d, &L);
    return level_offset(d, level, dpl, w, h, z, L.tileH, L.tileD, t);
}

uint32_t nvn_tex_level_gobs(const nvn_texdesc *d, unsigned level) {
    fmt_t t = fmt_of(d->format);
    unsigned dpl; int layered; uint32_t w, h, z, g = 0;
    shape(d, &dpl, &layered, &w, &h, &z);
    if (!t.bpb || (d->flags & (0x10 | 0x40)) || d->target == 10) return 0;   // linear (LINEAR / LINEAR_RENDER_TARGET, as nvn_tex_layout): one level at 0
    nvn_texlayout L; nvn_tex_layout(d, &L);
    level_walk(d, level, dpl, w, h, z, L.tileH, L.tileD, t, &g);
    return g;
}

void nvn_tex_level_tiles(const nvn_texdesc *d, unsigned level, unsigned *tileH, unsigned *tileD) {
    fmt_t t = fmt_of(d->format);
    unsigned dpl; int layered; uint32_t w, h, z;
    shape(d, &dpl, &layered, &w, &h, &z);
    uint32_t sx, sy; samples_xy(d->samples, &sx, &sy);
    nvn_texlayout L; nvn_tex_layout(d, &L);
    uint32_t lh = dpl >= 2 ? blk(mip(h * sy, level), t.bh) : 1;
    uint32_t ld = dpl >= 3 ? mip(z, level) : 1;
    *tileH = adj_tile(L.tileH, 8, lh);
    *tileD = adj_tile(L.tileD, 1, ld);
}

void nvn_tex_sparse_layout(const nvn_texdesc *d, uint32_t tile[4]) {
    tile[0] = tile[1] = tile[2] = tile[3] = 0;
    fmt_t t = fmt_of(d->format);
    unsigned x, y, z;   // NVN's sparse query chooses a 64 KiB page shape by texel size (sparse_page)
    if (!sparse_page(d, t, &x, &y, &z)) return;
    uint32_t tw = (64 / t.bpb) << x, th = 8u << y, td = 1u << z;
    uint32_t sx, sy; samples_xy(d->samples, &sx, &sy);
    if (d->samples == 16) sx = sy = 4;
    tw /= sx; th /= sy;
    if (t.bw >= 2) { tw *= t.bw; th *= t.bh; }
    uint32_t w = d->width, h = d->height, depth = d->target == 8 ? 6 : d->depth;
    unsigned levels = 0;
    while (levels < d->levels && w >= tw && h >= th && depth >= td) {
        levels++; w >>= 1; h >>= 1; if (d->target == 2) depth >>= 1;
    }
    if (levels) { tile[0] = levels; tile[1] = tw; tile[2] = th; tile[3] = td; }
}

int nvn_tbuf_rows_exact(uint64_t n, uint32_t bpb, uint32_t align, uint32_t *w, uint32_t *h, uint32_t *row) {
    if (!n || !bpb) return 0;
    if (!align) align = 1;
    if (n <= NVN_TBUF_ROW) { *w = (uint32_t)n; *h = 1; *row = (uint32_t)(((uint64_t)n * bpb + align - 1) / align * align); return 1; }
    uint64_t lb = n & (~n + 1), W = lb < NVN_TBUF_ROW ? lb : NVN_TBUF_ROW;   // the largest power of two dividing n, at most one row
    if (n / W > NVN_TBUF_ROW || (W * bpb) % align) return 0;   // more rows than a 2D texture holds, or rows that cannot lie back to back
    *w = (uint32_t)W; *h = (uint32_t)(n / W); *row = (uint32_t)(W * bpb);
    return 1;
}
int nvn_tbuf_rows(uint64_t n, uint32_t bpb, uint32_t align, uint32_t *w, uint32_t *h, uint32_t *row) {
    if (!n || !bpb) return 0;
    if (!align) align = 1;
    *w = n < NVN_TBUF_ROW ? (uint32_t)n : NVN_TBUF_ROW;
    *h = (uint32_t)((n + NVN_TBUF_ROW - 1) / NVN_TBUF_ROW);
    uint64_t r = (uint64_t)*w * bpb; r = (r + align - 1) / align * align;
    *row = (uint32_t)r;
    return *h == 1 || r == (uint64_t)NVN_TBUF_ROW * bpb;   // several rows must lie back to back, as the wrapped address assumes
}

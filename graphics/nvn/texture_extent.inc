// NVN texture dimensions at the 1x storage boundary. The guest descriptor (L)
// and the widen core's request (C_req) never come from a resized Metal texture.
// C_req is passed to the allocation plan explicitly. A storage/view query does
// not acquire the widen lock or invent a request when the caller has none.
// The live storage is the authority for canvas capacity and physical size:
// C_alloc == P, except for a storage the internal resolution scaled (S2A_RES_SCALE,
// nvn_rscale.inc): there P = ceil(C * s) and C is recorded on the storage (rs_canvas).
// Production call sites in this increment do not read logical, requested,
// canvas, serial_generation, or *_known from the returned snapshot.
#define NVN_TEXTURE_EXTENT_CONTRACT 1
typedef struct { NSUInteger width, height; } tex_size;
typedef struct {
    tex_size logical, requested, canvas, physical;
    NSUInteger level, storage_level, layer, levels;
    uint64_t serial_generation;   // existing view-cache invalidation token
    uint8_t logical_known, requested_known;
} tex_extent;

static NSUInteger mip_extent(NSUInteger size, NSUInteger level) {
    return level < sizeof(size) * 8 ? MAX(size >> level, 1) : 1;
}
static tex_size tex_size_mip(tex_size size, NSUInteger level) {
    return (tex_size){mip_extent(size.width, level), mip_extent(size.height, level)};
}
// A transient snapshot of this storage generation, not a second serial table.
// t is the original NVN descriptor: tex_snap and nvn_be_reg_tex copy it intact
// and carry view_t separately. Only the Metal view chain supplies extra levels.
// Callers without t get physical dimensions, never a guessed logical size.
// level/layer remain relative to the actual Metal object.
static tex_extent tex_extent_at(const tex_t *t, id<MTLTexture> storage, NSUInteger level, NSUInteger layer) {
    tex_extent e = {.level = level, .storage_level = level, .layer = layer, .serial_generation = g_ser_gen};
    id<MTLTexture> root = storage;
    while (root.parentTexture) { e.storage_level += root.parentRelativeLevel; root = root.parentTexture; }
    if (t) {
        e.logical = tex_size_mip((tex_size){t->d.width, t->d.height}, e.storage_level);
        e.logical_known = 1;
    }
    e.physical = storage ? tex_size_mip((tex_size){storage.width, storage.height}, level) : e.logical;
    e.canvas = e.physical;
    if (storage && rs_state(storage) == RS_SCALED) rs_canvas(storage, level, &e.canvas.width, &e.canvas.height);   // S2Arm internal resolution: the canvas the scaled storage stands for
    NSUInteger count = storage ? storage.mipmapLevelCount : t && t->d.levels ? t->d.levels : 1;
    e.levels = level < count ? count - level : 0;
    return e;
}
// Preserve the existing capacity policy: zero means keep this axis, and a
// smaller request does not shrink it. Allocation consumes this one plan; the
// eligibility checks and storage/alias replacement remain with tex_widen.
static tex_extent tex_extent_grow(const tex_t *t, id<MTLTexture> storage, NSUInteger w, NSUInteger h) {
    tex_extent e = tex_extent_at(t, storage, 0, 0);
    e.requested = (tex_size){w ? w : e.canvas.width, h ? h : e.canvas.height};
    e.requested_known = 1;
    e.canvas = (tex_size){MAX(e.canvas.width, e.requested.width), MAX(e.canvas.height, e.requested.height)};
    e.physical = e.canvas;
    if (storage && rs_state(storage) == RS_SCALED) e.physical = (tex_size){rs_up(e.canvas.width, g_rs), rs_up(e.canvas.height, g_rs)};   // S2Arm internal resolution: a scaled storage grows scaled
    return e;
}

// OP_COPY_T2T 的回放计划，见 t2t_plan.h。只用中立格式表（nvn_fmt_info，Metal/Vulkan 共用），
// 不碰 Vulkan 句柄——执行侧拿到 plan 后照参数发 vkCmdCopyImage / vkCmdBlitImage。
#include "t2t_plan.h"
#include "nvn_fmt_info.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define NVN_COPY_LINEAR    0x1u
#define NVN_COPY_ENGINE_2D 0x2u
#define NVN_COPY_MIRROR_X  0x4u
#define NVN_COPY_MIRROR_Y  0x8u
#define NVN_COPY_MIRROR_Z  0x10u
#define DM_COPY_RESOLVE    0x40000000u   // nvn_obj.h：Downsample/TiledDownsample 记录成的拷贝
#define T2T_KNOWN_FLAGS    (NVN_COPY_LINEAR | NVN_COPY_ENGINE_2D | NVN_COPY_MIRROR_X | \
                            NVN_COPY_MIRROR_Y | NVN_COPY_MIRROR_Z | DM_COPY_RESOLVE)
#define NVN_TARGET_3D      2
#define NVN_TARGET_BUFFER  0xA

static int fail(char *why, size_t n, const char *fmt, ...) {
    if (why && n) {
        va_list a; va_start(a, fmt); vsnprintf(why, n, fmt, a); va_end(a);
    }
    return -1;
}

static uint32_t mipdim(uint32_t s, uint32_t l) { s >>= l; return s ? s : 1; }

struct side {
    uint32_t level, base_layer;
    uint32_t w, h, d;        // 所选 level 的像素尺寸（3D 的 d 是深度，否则 1）
    nvn_fmt_info fmt;        // 视图生效格式（字节/块宽/类别）
    int fmt_known;
    int ds;                  // 深度/模板面
    uint32_t aspect;
};

// 视图 → 子资源与生效格式；tex 是已解析图像的事实（见头注释）。
static int side_resolve(const struct s2a_t2t_tex *t, const struct s2a_t2t_view *v, const char *tag,
                        struct side *o, char *why, size_t why_n) {
    uint32_t levels = t->levels ? t->levels : 1, layers = t->layers ? t->layers : 1;
    memset(o, 0, sizeof *o);
    o->level = v && v->has ? (uint32_t)v->base_level : 0;
    o->base_layer = v && v->has ? (uint32_t)v->min_layer : 0;
    if (o->level >= levels)
        return fail(why, why_n, "%s view selects mip %u but texture has %u levels", tag, o->level, levels);
    if (t->is_3d) {
        if (o->base_layer) return fail(why, why_n, "%s view selects a layer on a 3D texture", tag);
    } else if (o->base_layer >= layers)
        return fail(why, why_n, "%s view selects layer %u but texture has %u layers", tag, o->base_layer, layers);
    if (v && v->has_target && t->target >= 0 && (int)v->target != t->target)
        return fail(why, why_n, "%s view retypes target %u -> %u (dimensionality-changing view not wired)",
                    tag, t->target, v->target);
    uint32_t eff = v && v->has_format ? v->nvn_format : t->nvn_format;
    if (eff) {
        if (!nvn_fmt_info_of(eff, &o->fmt))
            return fail(why, why_n, "%s effective NVN format 0x%x is not in the format table", tag, eff);
        o->fmt_known = 1;
        if (v && v->has_format && t->nvn_format) {
            nvn_fmt_info base;
            if (!nvn_fmt_info_of(t->nvn_format, &base))
                return fail(why, why_n, "%s texture NVN format 0x%x is not in the format table", tag, t->nvn_format);
            // 覆盖格式必须同字节/同块，不然像素网格都对不上（对齐 Metal 的同兼容类限制）。
            if (o->fmt.bytes != base.bytes || o->fmt.bw != base.bw || o->fmt.bh != base.bh)
                return fail(why, why_n,
                            "%s view format 0x%x reinterprets texture format 0x%x across size classes", tag,
                            eff, t->nvn_format);
        }
        o->ds = o->fmt.depth || o->fmt.stencil;
        // 面选择：视图 dsmode 显式给出以视图为准（选了哪个面就只碰哪个面）；
        // 没给时按纹理自身的 stencil 模式；都没选就是整个深度-模板缓冲（两面一起）。
        if (o->ds) {
            int stencil_sel = v && v->has_dsmode ? v->dsmode_stencil : t->stencil_mode;
            if (stencil_sel)
                o->aspect = S2A_T2T_ASPECT_STENCIL;
            else if (v && v->has_dsmode)
                o->aspect = o->fmt.depth ? S2A_T2T_ASPECT_DEPTH : S2A_T2T_ASPECT_STENCIL;
            else
                o->aspect = (o->fmt.depth ? S2A_T2T_ASPECT_DEPTH : 0u) |
                            (o->fmt.stencil ? S2A_T2T_ASPECT_STENCIL : 0u);
        }
        else
            o->aspect = S2A_T2T_ASPECT_COLOR;
    } else {
        o->aspect = S2A_T2T_ASPECT_COLOR;   // 未知格式：沿用历史行为按颜色面处理
    }
    o->w = mipdim(t->width, o->level);
    o->h = mipdim(t->height, o->level);
    o->d = t->is_3d ? mipdim(t->depth, o->level) : 1;
    return 0;
}

static int same_pixels(const struct side *s, const struct side *d) {
    return s->fmt.bytes == d->fmt.bytes && s->fmt.bw == d->fmt.bw && s->fmt.bh == d->fmt.bh;
}

// 压缩格式：偏移必须整块，extent 要么整块要么正好吃到 level 边缘（Vulkan 同规则）。
static int block_ok(const struct side *s, const struct s2a_t2t_region *r) {
    if (s->fmt.bw <= 1 && s->fmt.bh <= 1) return 1;
    if (r->x % s->fmt.bw || r->y % s->fmt.bh) return 0;
    if (r->w % s->fmt.bw && (uint32_t)(r->x + r->w) != s->w) return 0;
    if (r->h % s->fmt.bh && (uint32_t)(r->y + r->h) != s->h) return 0;
    return 1;
}

int s2a_t2t_plan(const struct s2a_t2t_tex *src, const struct s2a_t2t_view *sv, const struct s2a_t2t_region *sr,
                 const struct s2a_t2t_tex *dst, const struct s2a_t2t_view *dv, const struct s2a_t2t_region *dr,
                 uint32_t flags, struct s2a_t2t_plan *out, char *why, size_t why_size) {
    if (!src || !dst || !sr || !dr || !out)
        return fail(why, why_size, "texture copy: missing inputs");
    if (flags & ~T2T_KNOWN_FLAGS)
        return fail(why, why_size, "texture copy: unknown flag bits 0x%x", flags & ~T2T_KNOWN_FLAGS);
    if (flags & NVN_COPY_MIRROR_Z)
        return fail(why, why_size, "texture copy: MIRROR_Z is not wired (Metal path does not implement it either)");
    int resolve_req = (flags & DM_COPY_RESOLVE) != 0;
    // MS 存储只有一条路：DM_COPY_RESOLVE 且 MS->1（vkCmdResolveImage）；解析进 MS / MS->MS /
    // 普通拷贝碰 MS 都没有对应语义，明确报红。
    if ((src->ms || dst->ms) && !(resolve_req && src->ms && !dst->ms))
        return fail(why, why_size, "texture copy: multisample texture %d->%d samples is not bridged "
                    "(only MS->1 resolve)", src->ms, dst->ms);
    if (src->target == NVN_TARGET_BUFFER || dst->target == NVN_TARGET_BUFFER)
        return fail(why, why_size, "texture copy: texture-buffer targets are not textures to copy between");
    if (src->is_3d != dst->is_3d)
        return fail(why, why_size, "texture copy: 3D <-> 2D/array copies are not wired");
    if (resolve_req &&
        (src->nvn_format != dst->nvn_format || !src->nvn_format || src->width != dst->width || src->height != dst->height))
        return fail(why, why_size,
                    "downsample/resolve needs same format and size (src 0x%x %ux%u, dst 0x%x %ux%u)",
                    src->nvn_format, src->width, src->height, dst->nvn_format, dst->width, dst->height);
    if (resolve_req && (flags & ~DM_COPY_RESOLVE))
        return fail(why, why_size, "texture copy: resolve flag combined with 0x%x is not wired",
                    flags & ~DM_COPY_RESOLVE);

    struct side s, d;
    if (side_resolve(src, sv, "src", &s, why, why_size)) return -1;
    if (side_resolve(dst, dv, "dst", &d, why, why_size)) return -1;

    // 区域：w/h 必须正；depth<=0 按 Metal 口径当 1（数组层数 / 3D 深度片）。
    if (sr->w <= 0 || sr->h <= 0 || dr->w <= 0 || dr->h <= 0)
        return fail(why, why_size, "texture copy: empty region src %dx%d dst %dx%d", sr->w, sr->h, dr->w, dr->h);
    int32_t sd = sr->d > 0 ? sr->d : 1, dd = dr->d > 0 ? dr->d : 1;
    if (sd != dd)
        return fail(why, why_size, "texture copy: layer/depth count mismatch %d -> %d", sd, dd);
    if (sr->x < 0 || sr->y < 0 || (uint32_t)(sr->x + sr->w) > s.w || (uint32_t)(sr->y + sr->h) > s.h)
        return fail(why, why_size, "texture copy: src region %d,%d %dx%d outside level %ux%u",
                    sr->x, sr->y, sr->w, sr->h, s.w, s.h);
    if (dr->x < 0 || dr->y < 0 || (uint32_t)(dr->x + dr->w) > d.w || (uint32_t)(dr->y + dr->h) > d.h)
        return fail(why, why_size, "texture copy: dst region %d,%d %dx%d outside level %ux%u",
                    dr->x, dr->y, dr->w, dr->h, d.w, d.h);
    if (src->is_3d) {
        if (sr->z < 0 || (uint32_t)(sr->z + sd) > s.d || dr->z < 0 || (uint32_t)(dr->z + dd) > d.d)
            return fail(why, why_size, "texture copy: z range %d+%d / %d+%d outside 3D depth %u/%u",
                        sr->z, sd, dr->z, dd, s.d, d.d);
    } else {
        if (sr->z < 0 || dr->z < 0 ||
            (uint32_t)(s.base_layer + sr->z + sd) > (src->layers ? src->layers : 1) ||
            (uint32_t)(d.base_layer + dr->z + dd) > (dst->layers ? dst->layers : 1))
            return fail(why, why_size, "texture copy: layer range %u+%d+%d / %u+%d+%d outside %u/%u layers",
                        s.base_layer, sr->z, sd, d.base_layer, dr->z, dd,
                        src->layers ? src->layers : 1, dst->layers ? dst->layers : 1);
    }
    if (s.fmt_known && d.fmt_known && !same_pixels(&s, &d))
        return fail(why, why_size,
                    "texture copy: effective formats 0x%x -> 0x%x differ in size class "
                    "(cross-class conversion is not wired)",
                    sv && sv->has_format ? sv->nvn_format : src->nvn_format,
                    dv && dv->has_format ? dv->nvn_format : dst->nvn_format);
    if ((!s.fmt_known || !d.fmt_known) && src->vk_format && dst->vk_format && src->vk_format != dst->vk_format)
        return fail(why, why_size, "texture copy: formats unknown to the NVN table and VkFormats differ "
                    "(%u -> %u); conversion path is not wired", src->vk_format, dst->vk_format);
    if (s.aspect != d.aspect)
        return fail(why, why_size, "texture copy: aspect mismatch 0x%x -> 0x%x (stencil/depth mixing is not wired)",
                    s.aspect, d.aspect);

    int mirror = flags & (NVN_COPY_MIRROR_X | NVN_COPY_MIRROR_Y);
    int scaled = sr->w != dr->w || sr->h != dr->h;
    memset(out, 0, sizeof *out);
    out->src_aspect = s.aspect; out->dst_aspect = d.aspect;
    out->src_level = s.level;   out->dst_level = d.level;

    if (src->ms) {
        // MS->1 resolve：1:1 纹素映射、只认颜色面（深度/模板解析要 KHR_depth_stencil_resolve）。
        if (scaled)
            return fail(why, why_size, "resolve cannot scale (%dx%d -> %dx%d)", sr->w, sr->h, dr->w, dr->h);
        if (s.aspect != S2A_T2T_ASPECT_COLOR)
            return fail(why, why_size, "resolve of a depth/stencil plane is not wired");
        out->op = S2A_T2T_RESOLVE;
        out->extent[0] = (uint32_t)sr->w; out->extent[1] = (uint32_t)sr->h; out->extent[2] = (uint32_t)sd;
        if (src->is_3d) {
            out->src_offset[0] = sr->x; out->src_offset[1] = sr->y; out->src_offset[2] = sr->z;
            out->dst_offset[0] = dr->x; out->dst_offset[1] = dr->y; out->dst_offset[2] = dr->z;
            out->layer_count = 1;
        } else {
            out->src_offset[0] = sr->x; out->src_offset[1] = sr->y; out->src_offset[2] = 0;
            out->dst_offset[0] = dr->x; out->dst_offset[1] = dr->y; out->dst_offset[2] = 0;
            out->src_base_layer = s.base_layer + (uint32_t)sr->z;
            out->dst_base_layer = d.base_layer + (uint32_t)dr->z;
            out->layer_count = (uint32_t)sd;
        }
        return 0;
    }

    if (!scaled && !mirror) {
        // 同尺寸、同字节类：vkCmdCopyImage（DS 面 / 压缩 / 跨 mip 都是它的地盘）。
        if (!block_ok(&s, sr) || !block_ok(&d, dr))
            return fail(why, why_size, "texture copy: compressed-format region is not block-aligned");
        out->op = S2A_T2T_COPY;
        out->extent[0] = (uint32_t)sr->w; out->extent[1] = (uint32_t)sr->h; out->extent[2] = (uint32_t)sd;
        if (src->is_3d) {
            out->src_offset[0] = sr->x; out->src_offset[1] = sr->y; out->src_offset[2] = sr->z;
            out->dst_offset[0] = dr->x; out->dst_offset[1] = dr->y; out->dst_offset[2] = dr->z;
            out->layer_count = 1;
        } else {
            out->src_offset[0] = sr->x; out->src_offset[1] = sr->y; out->src_offset[2] = 0;
            out->dst_offset[0] = dr->x; out->dst_offset[1] = dr->y; out->dst_offset[2] = 0;
            out->src_base_layer = s.base_layer + (uint32_t)sr->z;
            out->dst_base_layer = d.base_layer + (uint32_t)dr->z;
            out->layer_count = (uint32_t)sd;
        }
        return 0;
    }

    // 缩放 / 镜像 / 需要转换的拷贝：Vulkan blit（Metal 路径用 draw；语义相同——线性采样只对缩放有意义，
    // 镜像 = dstOffsets 反向）。DS 面与压缩格式走不进 blit，按 Metal 的「只直拷」口径报红。
    if (s.ds || d.ds)
        return fail(why, why_size, "texture copy: scaling/mirroring/converting a depth-stencil plane is not wired");
    if (s.fmt_known && (s.fmt.bw > 1 || s.fmt.bh > 1))
        return fail(why, why_size, "texture copy: blit of a compressed source format is not wired");
    if (d.fmt_known && (d.fmt.bw > 1 || d.fmt.bh > 1))
        return fail(why, why_size, "texture copy: blit into a compressed destination format is not wired");
    int linear = (flags & NVN_COPY_LINEAR) != 0;
    if (linear) {
        int sint = s.fmt_known && (s.fmt.kind == NVN_FMT_UINT || s.fmt.kind == NVN_FMT_SINT);
        int dint = d.fmt_known && (d.fmt.kind == NVN_FMT_UINT || d.fmt.kind == NVN_FMT_SINT);
        if (sint || dint)
            return fail(why, why_size, "texture copy: LINEAR_FILTER on an integer format is not wired");
        if (!s.fmt_known || !d.fmt_known)
            return fail(why, why_size, "texture copy: LINEAR_FILTER with an unmapped format is not wired "
                        "(filterability unknown)");
    }
    out->op = linear ? S2A_T2T_BLIT_LINEAR : S2A_T2T_BLIT_NEAREST;
    out->src_box[0][0] = sr->x; out->src_box[0][1] = sr->y; out->src_box[0][2] = src->is_3d ? sr->z : 0;
    out->src_box[1][0] = sr->x + sr->w; out->src_box[1][1] = sr->y + sr->h;
    out->src_box[1][2] = src->is_3d ? sr->z + sd : 1;
    out->dst_box[0][0] = dr->x; out->dst_box[0][1] = dr->y; out->dst_box[0][2] = src->is_3d ? dr->z : 0;
    out->dst_box[1][0] = dr->x + dr->w; out->dst_box[1][1] = dr->y + dr->h;
    out->dst_box[1][2] = src->is_3d ? dr->z + dd : 1;
    if (flags & NVN_COPY_MIRROR_X) { int32_t t = out->dst_box[0][0]; out->dst_box[0][0] = out->dst_box[1][0]; out->dst_box[1][0] = t; }
    if (flags & NVN_COPY_MIRROR_Y) { int32_t t = out->dst_box[0][1]; out->dst_box[0][1] = out->dst_box[1][1]; out->dst_box[1][1] = t; }
    if (src->is_3d) {
        out->layer_count = 1;
    } else {
        out->src_base_layer = s.base_layer + (uint32_t)sr->z;
        out->dst_base_layer = d.base_layer + (uint32_t)dr->z;
        out->layer_count = (uint32_t)sd;
    }
    (void)NVN_COPY_ENGINE_2D;   // 引擎选择只是提示：Metal 同样忽略
    return 0;
}

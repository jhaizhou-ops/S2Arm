// NVN ReadTexels 的纯几何/打包换算（无 Vulkan / NVN / 宿主依赖，宿主单测直接编本文件）。
#include "nvn_vk_readback_plan.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static void rb_why(char *why, size_t why_size, const char *fmt, ...) {
    if (!why || !why_size) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(why, why_size, fmt, ap);
    va_end(ap);
}

// 该 target 参与布局的维数（与 nvn_tex.c 的 shape() 同口径）：
// 1D / 1D_ARRAY 只有宽，3D 三维，其余（2D / RECT / 数组 / 立方体 / MS）两维。
static int target_dims(int32_t target) {
    switch (target) {
    case 0:  // NVN_TEXTURE_TARGET_1D
    case 3:  // NVN_TEXTURE_TARGET_1D_ARRAY
        return 1;
    case 2:  // NVN_TEXTURE_TARGET_3D
        return 3;
    default:
        return 2;
    }
}

static uint32_t mip_dim(uint32_t s, unsigned level) {
    uint32_t v = level >= 32 ? 1u : s >> level;
    return v ? v : 1u;
}

static uint32_t ceil_div(uint32_t a, uint32_t b) { return (a + b - 1u) / b; }

static int mul_size(size_t a, size_t b, size_t *out) {
    if (a && b > SIZE_MAX / a) return -1;
    *out = a * b;
    return 0;
}

int nvn_vk_readback_plan(const struct nvn_vk_rb_desc *d, unsigned level, unsigned layer0,
                         const struct nvn_vk_rb_region *r, size_t row, size_t img,
                         struct nvn_vk_rb_plan *out, char *why, size_t why_size) {
    if (why && why_size) why[0] = 0;
    if (!d || !r || !out) { rb_why(why, why_size, "readback plan: null descriptor/region/output"); return -1; }
    memset(out, 0, sizeof *out);
    if (d->bpb <= 0 || d->bw <= 0 || d->bh <= 0) {
        rb_why(why, why_size,
               "readback plan: format 0x%x has no byte/block size (bpb=%d bw=%d bh=%d); refusing to guess "
               "the packed layout", d->nvn_format, d->bpb, d->bw, d->bh);
        return -1;
    }
    const uint32_t bw = (uint32_t)d->bw, bh = (uint32_t)d->bh;
    const uint32_t levels = d->levels ? d->levels : 1u;
    if (level >= levels) {
        rb_why(why, why_size, "readback plan: level %u is outside the texture's %u level(s) (format 0x%x %ux%ux%u)",
               level, levels, d->nvn_format, d->width, d->height, d->depth);
        return -1;
    }
    const int dims = target_dims(d->target);
    const int is3d = d->target == 2;
    const uint32_t lw = mip_dim(d->width, level);
    const uint32_t lh = dims >= 2 ? mip_dim(d->height, level) : 1u;
    const uint32_t ld = dims >= 3 ? mip_dim(d->depth, level) : 1u;
    const uint32_t layers = d->layers ? d->layers : 1u;

    if (r->x < 0 || r->y < 0 || r->z < 0) {
        rb_why(why, why_size, "readback plan: negative copy region origin x=%d y=%d z=%d (level %u %ux%ux%u)",
               r->x, r->y, r->z, level, lw, lh, ld);
        return -1;
    }
    if (r->width <= 0 || r->height <= 0 || r->depth < 0) {
        rb_why(why, why_size,
               "readback plan: invalid copy region size %dx%dx%d (level %u is %ux%ux%u, format 0x%x)",
               r->width, r->height, r->depth, level, lw, lh, ld, d->nvn_format);
        return -1;
    }
    const uint32_t w = (uint32_t)r->width, h = (uint32_t)r->height;
    const uint32_t nz = r->depth ? (uint32_t)r->depth : 1u;
    const uint32_t x = (uint32_t)r->x, y = (uint32_t)r->y, z = (uint32_t)r->z;
    if (x > lw || w > lw - x || y > lh || h > lh - y) {
        rb_why(why, why_size,
               "readback plan: copy region %d,%d %dx%d exceeds level %u extent %ux%u (format 0x%x)",
               r->x, r->y, r->width, r->height, level, lw, lh, d->nvn_format);
        return -1;
    }
    if (is3d) {
        if (z > ld || nz > ld - z) {
            rb_why(why, why_size,
                   "readback plan: 3D copy region z=%u depth=%u exceeds level %u depth %u (format 0x%x)",
                   z, nz, level, ld, d->nvn_format);
            return -1;
        }
    } else if (layer0 > layers || z > layers - layer0 || nz > layers - layer0 - z) {
        rb_why(why, why_size,
               "readback plan: layer range %u+%u..+%u exceeds texture's %u layer(s) (target %d format 0x%x)",
               layer0, z, nz, layers, d->target, d->nvn_format);
        return -1;
    }

    // 块压缩格式的偏移/边界必须按块对齐（Vulkan 的 VkBufferImageCopy 与 NVN 的块布局都要求）。
    // 右/下边界允许不是整块：那一段按“取到该 level 边界”的整块处理（块行字节数向上取整）。
    if ((bw > 1 || bh > 1) && (x % bw || y % bh)) {
        rb_why(why, why_size,
               "readback plan: block-compressed region origin %u,%u is not aligned to the %ux%u block "
               "(format 0x%x); NVN compressed copies must start on a block boundary",
               x, y, bw, bh, d->nvn_format);
        return -1;
    }
    if ((bw > 1 && x + w != lw && w % bw) || (bh > 1 && y + h != lh && h % bh)) {
        rb_why(why, why_size,
               "readback plan: block-compressed region %ux%u at %u,%u is not a whole number of %ux%u blocks "
               "and does not end at the level edge (format 0x%x)",
               w, h, x, y, bw, bh, d->nvn_format);
        return -1;
    }

    const uint32_t block_cols = ceil_div(w, bw);
    const uint32_t block_rows = ceil_div(h, bh);
    size_t copy_row_bytes = 0, copy_bytes = 0;
    if (mul_size(block_cols, (size_t)d->bpb, &copy_row_bytes) ||
        mul_size(copy_row_bytes, block_rows, &copy_bytes)) {
        rb_why(why, why_size, "readback plan: region %ux%u x %d B/block overflows size_t (format 0x%x)",
               w, h, d->bpb, d->nvn_format);
        return -1;
    }

    // NVN 的 row / img：0 = 紧排。非 0 时必须容得下紧排内容；否则 dst 行/层会互相覆盖。
    size_t tight_img = 0;
    if (mul_size(copy_row_bytes, block_rows, &tight_img)) {
        rb_why(why, why_size, "readback plan: row*rows overflows size_t (format 0x%x)", d->nvn_format);
        return -1;
    }
    if (!row) row = copy_row_bytes;
    if (!img) {
        if (mul_size(row, block_rows, &img)) {
            rb_why(why, why_size, "readback plan: default image stride overflows size_t (row %zu x %u rows)", row, block_rows);
            return -1;
        }
    }
    if (row < copy_row_bytes) {
        rb_why(why, why_size,
               "readback plan: row stride %zu B is smaller than the packed row %zu B (%u blocks x %d B, "
               "format 0x%x region %ux%u)", row, copy_row_bytes, block_cols, d->bpb, d->nvn_format, w, h);
        return -1;
    }
    // img 只在多于一个层/切片时被用到（dst_offset = z*img）；单层读回时 NVN 不消费它，
    // 不允许它把合法请求挡在门外（Metal 后端同样只用 z*img）。
    if (nz > 1 && img < tight_img) {
        rb_why(why, why_size,
               "readback plan: image stride %zu B is smaller than the packed image %zu B (row %zu x %u rows, "
               "%u layers, format 0x%x region %ux%u)", img, tight_img, row, block_rows, nz,
               d->nvn_format, w, h);
        return -1;
    }

    const uint32_t staging_stride = (uint32_t)((copy_bytes + 15u) & ~(size_t)15u);
    size_t staging_bytes = 0;
    if (mul_size(staging_stride, nz, &staging_bytes)) {
        rb_why(why, why_size, "readback plan: staging size overflows size_t (%u slices x %u B)",
               nz, staging_stride);
        return -1;
    }

    out->level = level;
    out->layer0 = layer0;
    out->is3d = is3d;
    out->bpb = d->bpb; out->bw = d->bw; out->bh = d->bh;
    out->level_w = lw; out->level_h = lh; out->level_d = ld;
    out->x = x; out->y = y; out->z = z;
    out->w = w; out->h = h;
    out->nz = nz;
    out->dst_row = row;
    out->dst_img = img;
    out->block_cols = block_cols;
    out->block_rows = block_rows;
    out->copy_row_bytes = (uint32_t)copy_row_bytes;
    out->copy_bytes = copy_bytes;
    out->staging_stride = staging_stride;
    out->staging_bytes = staging_bytes;
    return 0;
}

void nvn_vk_readback_slice(const struct nvn_vk_rb_plan *p, unsigned z, struct nvn_vk_rb_slice *out) {
    if (!p || !out) return;
    if (z >= p->nz) z = p->nz ? p->nz - 1u : 0u;
    // 3D：层号恒 0，深度切片走 imageOffset.z；2D 数组/立方体：切片号就是 (layer0 + zoffset + z)。
    out->image_layer = p->is3d ? 0u : p->layer0 + p->z + z;
    out->image_z = p->is3d ? p->z + z : 0u;
    out->dst_offset = (size_t)z * p->dst_img;
    out->staging_offset = (size_t)z * p->staging_stride;
}

size_t nvn_vk_readback_dst_extent(const struct nvn_vk_rb_plan *p) {
    if (!p) return 0;
    if (!p->nz || !p->block_rows) return p->copy_bytes;
    return (size_t)(p->nz - 1) * p->dst_img + (size_t)(p->block_rows - 1) * p->dst_row + p->copy_row_bytes;
}

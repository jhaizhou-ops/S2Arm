// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "buffer_texture_plan.h"
#include "nvn_vk_format.h"
#include "nvn_fmt_info.h"
#include "include/nvn.h"
#include <limits.h>
#include <stdio.h>
#include <string.h>

static int fail(int code, char *why, size_t n, const char *message) {
    if (why && n) snprintf(why, n, "%s", message);
    return code;
}
static int boolean(int v) { return v == 0 || v == 1; }
static struct s2a_bt_dependency dependency(int direction, int after) {
    struct s2a_bt_dependency d = {0};
    uint32_t transfer = direction == S2A_BT_TO_BUFFER ? VK_ACCESS_TRANSFER_READ_BIT : VK_ACCESS_TRANSFER_WRITE_BIT;
    d.src_stage = after ? VK_PIPELINE_STAGE_TRANSFER_BIT : VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    d.dst_stage = after ? VK_PIPELINE_STAGE_ALL_COMMANDS_BIT : VK_PIPELINE_STAGE_TRANSFER_BIT;
    d.src_access = after ? transfer : VK_ACCESS_MEMORY_WRITE_BIT;
    d.dst_access = after ? VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT : transfer;
    d.old_layout = d.new_layout = VK_IMAGE_LAYOUT_GENERAL;
    d.aspect = VK_IMAGE_ASPECT_COLOR_BIT;
    d.layer_count = 1;
    return d;
}

int s2a_buffer_texture_plan(const struct s2a_bt_input *in, struct s2a_bt_plan *out, char *why, size_t n) {
    if (out) memset(out, 0, sizeof *out);
    if (why && n) why[0] = 0;
    if (!in || !out) return fail(S2A_BT_INVALID, why, n, "missing planner input/output");
    if (in->direction != S2A_BT_TO_TEXTURE && in->direction != S2A_BT_TO_BUFFER)
        return fail(S2A_BT_INVALID, why, n, "invalid copy direction");
    const struct s2a_bt_texture *t = &in->texture;
    const struct s2a_bt_view *v = &in->view;
    const struct s2a_bt_region *r = &in->region;
    if (!t->width || !t->height || t->width > INT32_MAX || t->height > INT32_MAX || !t->levels || !t->layers)
        return fail(S2A_BT_INVALID, why, n, "missing or invalid image dimensions/subresources");
    if (t->target != NVN_TEXTURE_TARGET_2D || t->depth != 1 || t->layers != 1 || t->samples > 1)
        return fail(S2A_BT_UNSUPPORTED, why, n, "only single-sample non-array 2D images are covered");
    if (in->flags) return fail(S2A_BT_UNSUPPORTED, why, n, "copy flags are not covered");
    nvn_fmt_info fmt;
    if (!nvn_fmt_info_of(t->nvn_format, &fmt) || fmt.depth || fmt.stencil || fmt.bw != 1 || fmt.bh != 1 || fmt.expand)
        return fail(S2A_BT_UNSUPPORTED, why, n, "unknown/compressed/depth/stencil/converted format is not covered");
    VkFormat expected = nvn_vk_format(t->nvn_format);
    if (expected == VK_FORMAT_UNDEFINED || (uint32_t)expected != t->vk_format)
        return fail(S2A_BT_UNSUPPORTED, why, n, "guest format does not match actual image storage");
    if (!boolean(v->has)) return fail(S2A_BT_INVALID, why, n, "invalid view presence");
    if (v->has) {
        if (!boolean(v->set_format) || !boolean(v->set_levels) || !boolean(v->set_layers) ||
            !boolean(v->set_target) || !boolean(v->set_swizzle) || !boolean(v->set_dsmode))
            return fail(S2A_BT_INVALID, why, n, "invalid view field presence");
        if ((v->set_format && v->format != t->nvn_format) ||
            (v->set_target && v->target != NVN_TEXTURE_TARGET_2D) || v->set_swizzle || v->set_dsmode)
            return fail(S2A_BT_UNSUPPORTED, why, n, "non-default view interpretation is not covered");
        if (v->set_levels && (v->base_level != 0 || v->nlevels <= 0 || (uint32_t)v->nlevels != t->levels))
            return fail(S2A_BT_UNSUPPORTED, why, n, "only default full mip range is covered");
        if (v->set_layers && (v->min_layer != 0 || v->nlayers != 1))
            return fail(S2A_BT_UNSUPPORTED, why, n, "only default single layer is covered");
    }
    if (r->x < 0 || r->y < 0 || r->width <= 0 || r->height <= 0)
        return fail(S2A_BT_INVALID, why, n, "invalid xy region");
    if (r->z != 0 || (r->depth != 0 && r->depth != 1))
        return fail(S2A_BT_UNSUPPORTED, why, n, "only one slice at z zero is covered");
    if ((uint32_t)r->x > t->width || (uint32_t)r->width > t->width - (uint32_t)r->x ||
        (uint32_t)r->y > t->height || (uint32_t)r->height > t->height - (uint32_t)r->y)
        return fail(S2A_BT_INVALID, why, n, "region is outside image");
    // A single row fits uint64_t. Check the row-pitch product before forming
    // the full span/staging size (INT32_MAX squared times 16 can overflow).
    uint64_t bpp = fmt.bytes;
    uint64_t row_bytes = (uint64_t)(uint32_t)r->width * bpp;
    uint64_t pitch = in->row_stride ? in->row_stride : row_bytes;
    if (pitch < row_bytes) return fail(S2A_BT_INVALID, why, n, "row stride is shorter than a row");
    uint64_t rows = (uint32_t)r->height;
    if (pitch > UINT64_MAX / rows) return fail(S2A_BT_INVALID, why, n, "image pitch overflows");
    uint64_t span = (rows - 1) * pitch + row_bytes;
    uint64_t image_stride = in->image_stride ? in->image_stride : pitch * rows;
    if (image_stride < span) return fail(S2A_BT_INVALID, why, n, "image stride is shorter than touched bytes");
    if (in->guest_address > UINT64_MAX - span)
        return fail(S2A_BT_INVALID, why, n, "guest address extent overflows");
    uint64_t staging = row_bytes * rows;
    if (!in->max_staging_bytes || !in->max_guest_span)
        return fail(S2A_BT_INVALID, why, n, "missing explicit planner budgets");
    if (staging > in->max_staging_bytes || staging > SIZE_MAX || span > in->max_guest_span)
        return fail(S2A_BT_LIMIT, why, n, "copy exceeds staging or guest span budget");
    struct s2a_bt_plan p = {0};
    p.direction = in->direction;
    p.x = (uint32_t)r->x; p.y = (uint32_t)r->y;
    p.width = (uint32_t)r->width; p.height = (uint32_t)r->height;
    p.bytes_per_texel = (uint32_t)bpp;
    p.row_bytes = row_bytes; p.guest_row_pitch = pitch; p.image_stride = image_stride;
    p.guest_address = in->guest_address; p.guest_span = span; p.staging_bytes = staging;
    p.image_before = dependency(in->direction, 0);
    p.image_after = dependency(in->direction, 1);
    *out = p;
    return S2A_BT_OK;
}

int s2a_buffer_texture_row(const struct s2a_bt_plan *p, uint32_t row, struct s2a_bt_span *out) {
    if (out) memset(out, 0, sizeof *out);
    if (!p || !out || row >= p->height) return S2A_BT_INVALID;
    out->guest_address = p->guest_address + (uint64_t)row * p->guest_row_pitch;
    out->staging_offset = (uint64_t)row * p->row_bytes;
    out->bytes = p->row_bytes;
    return S2A_BT_OK;
}

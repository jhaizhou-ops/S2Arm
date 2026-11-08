// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Pure plan for already decoded NVN B2T/T2B records. No handles, allocation,
// guest access or Vulkan calls. This module is not wired into record replay yet.
#pragma once
#include <stddef.h>
#include <stdint.h>

enum s2a_bt_direction { S2A_BT_TO_TEXTURE = 0, S2A_BT_TO_BUFFER = 1 };
enum s2a_bt_result { S2A_BT_OK = 0, S2A_BT_INVALID = -1, S2A_BT_UNSUPPORTED = -2, S2A_BT_LIMIT = -3 };
struct s2a_bt_texture {
    uint32_t nvn_format, vk_format; // actual guest format and resolved image format, not a guessed override
    uint32_t width, height, depth, levels, layers;
    uint32_t samples; // NVN convention: 0 or 1 means single-sample, not VkSampleCount=0
    int32_t target;
};
struct s2a_bt_view {
    int has, set_format, set_levels, set_layers, set_target, set_swizzle, set_dsmode;
    uint32_t format;
    int32_t base_level, nlevels, min_layer, nlayers, target;
};
struct s2a_bt_region { int32_t x, y, z, width, height, depth; };
struct s2a_bt_input {
    struct s2a_bt_texture texture;
    struct s2a_bt_view view;
    struct s2a_bt_region region;
    int direction;
    uint32_t flags, row_stride, image_stride;
    uint64_t guest_address;
    // Explicit caller budgets. Zero is invalid; this planner never chooses an
    // unbounded staging allocation. Guest span is an extent, not a bulk read.
    uint64_t max_staging_bytes, max_guest_span;
};
struct s2a_bt_dependency {
    uint32_t src_stage, dst_stage, src_access, dst_access;
    uint32_t old_layout, new_layout, aspect, mip, base_layer, layer_count;
};
struct s2a_bt_plan {
    int direction;
    uint32_t x, y, width, height, bytes_per_texel;
    uint64_t row_bytes, guest_row_pitch, image_stride, guest_address, guest_span, staging_bytes;
    // Each row packs into tight staging. Neither direction reads/writes guest
    // row padding or image tail. Vulkan bufferOffset is zero, not guest_address;
    // bufferRowLength/imageHeight are zero (tight), image mip/layer are zero.
    struct s2a_bt_dependency image_before, image_after;
};
struct s2a_bt_span { uint64_t guest_address, staging_offset, bytes; };

// Only single-sample 2D color, identical runtime/storage format, flags=0,
// default or explicitly equivalent view, mip0/layer0 and xy regions. Depth=0
// follows NVN/Metal's single-slice convention. Unsupported is not fake success.
// Failure clears output; inputs stay unchanged. why is optional.
int s2a_buffer_texture_plan(const struct s2a_bt_input *input, struct s2a_bt_plan *out,
                           char *why, size_t why_size);
// Plan must be an unmodified successful output from the function above.
int s2a_buffer_texture_row(const struct s2a_bt_plan *plan, uint32_t row, struct s2a_bt_span *out);

// Future executor obligations (NOT proved by a plan): pin resources and verify
// live image facts/capabilities and current GENERAL layout; handle queue
// ownership before using these same-owner GENERAL-to-GENERAL dependencies
// (they do not transition from UNDEFINED/attachment layouts); resolve GPU-written
// source buffers coherently;
// copy only these spans; flush/invalidate staging as needed; emit both image
// dependencies and the host-buffer dependencies; submit in owner order; only
// unpack/free after proven completion, retain resources if completion is unknown.

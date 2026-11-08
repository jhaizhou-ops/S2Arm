// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include "direct/compile_request.h"
#include "direct/control.h"
#include "direct/input_identity.h"
#include "direct/source_store.h"
#include "direct/vk_record.h"

#ifdef __cplusplus
extern "C" {
#endif

/* One immutable source pin backs both REQUEST and identity. Release only after the
 * consumer has copied C1 / finished using source pointers. No device operations. */
/* Extracted from the exact provider profile bytes embedded in REQUEST. */
struct nvk_compute_profile_facts {
    uint32_t storage_alignment;
    char hash[72];
};
/* Same strict provider-profile parser used by REQUEST and the pre-identity bridge. */
int nvk_compute_profile_parse(const struct s2a_direct_compile_context *context,
    struct nvk_compute_profile_facts *out, char *why, size_t why_bytes);
struct nvk_compute_request {
    struct nvk_compute_profile_facts profile;
    struct s2a_source_entry_view source;
    struct s2a_cs_facts cs;
    uint32_t local_memory_bytes;
    uint64_t session, generation;
    char *json;
    size_t json_bytes;
    uint8_t canonical[S2A_INPUT_IDENTITY_MAX], identity[32];
    size_t canonical_bytes;
};

/* Facts must describe the CS stage, not graphics state inherited from a draw.
 * complete means the caller has proved the required texture queries; false is
 * unknown, not an empty set. Empty proven facts are valid for texture-free CS. */
struct nvk_compute_texture_facts {
    const struct s2a_compile_texture_src *items;
    int count;
    int complete;
};

/* out must be fresh or released; on failure it is empty. Profiles are the provider
 * byte representation; the same bytes are hashed and embedded without reformatting.
 * Alignment is explicit: has_unaligned_ssbo must be 1 and unaligned_ssbo 0/1;
 * unknown is rejected, never silently treated as aligned.
 * This builds input only: unsupported compiler queries still fail in the compiler. */
int nvk_compute_request_prepare(const struct s2a_record_dispatch_state *state,
    const struct s2a_direct_compile_context *context,
    const struct nvk_compute_texture_facts *textures,
    int has_unaligned_ssbo, int unaligned_ssbo, const char *request_id, struct nvk_compute_request *out,
    char *why, size_t why_bytes);
void nvk_compute_request_release(struct nvk_compute_request *request);

#ifdef __cplusplus
}
#endif

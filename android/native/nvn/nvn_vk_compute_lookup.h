// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include "nvn_vk_compute_request.h"
#ifdef __cplusplus
extern "C" {
#endif
/* No new cache or default dispatch hook. Caller supplies a proven immutable
 * request and provider context, and holds its source pin through this call.
 * Roots are trusted application paths; NULL disables that cache source.
 * pause/resume must use the execution owner's established suspension contract. */
struct nvk_compute_lookup_options {
    const char *revision_root, *private_cache_root;
    int (*pause)(void *);
    void (*resume)(void *);
    void *pause_context;
    /* Explicit test policy; zero preserves normal live fallback. Property
     * readers must enforce the shared debug-build/debug_env contract. */
    int no_live_compile;
    /* 结果封套落盘门：与请求侧 diag_save 同一调试门合同（#968 定案：正式包
     * 缺省不导出）。0 = 门关，封套不持久化；调用方传 s2a_debug_entries_open
     * 的判定结果。 */
    int diag_open;
};
enum nvk_compute_program_origin { NVK_COMPUTE_OFFLINE = 1, NVK_COMPUTE_PRIVATE = 2, NVK_COMPUTE_COMPILED = 3 };
struct nvk_compute_lookup_result {
    struct nvk_compute_profile_facts profile; /* same prepared profile as accepted identity */
    uint8_t *bytes; /* malloc ownership transfers only on success; release with free. */
    size_t length;
    /* Borrowed view of the request source's c1 constant segment (carved from the
     * code image per the control segment's declared range). Identity matching
     * proves the accepted program shares this source, so the same bytes apply to
     * offline/private/live origins. Not owned; valid while the caller's request
     * holds its source pin. NULL = no c1 was captured for this source. */
    const uint8_t *c1;
    uint32_t c1_bytes;
    enum nvk_compute_program_origin origin;
    char offline_reason[192], private_reason[192];
    int cache_store_failed; /* diagnostic only, never hides a usable compiled result */
};
int nvk_compute_lookup(const struct nvk_compute_request *request,
    const struct s2a_direct_compile_context *context,
    const struct nvk_compute_lookup_options *options,
    struct nvk_compute_lookup_result *out, char *why, size_t why_size);
#ifdef __cplusplus
}
#endif

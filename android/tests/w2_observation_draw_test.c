// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Compile the complete, unchanged draw implementation in this TU. Only external
// compiler, provider, storage and GPU-consumer boundaries are controlled. The
// source store, facts, identity, request and result parser are production code.
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "direct/s2a_direct.h"
#ifndef W2_DRAW_SOURCE
#define W2_DRAW_SOURCE "nvn/nvn_vk_draw.c"
#endif
#include W2_DRAW_SOURCE
#ifdef W2_HAVE_OBSERVER
#include "direct/w2_observation.inc"
#endif

static unsigned case_id, provider_calls, offline_calls, private_calls, compile_calls,
    gpu_calls, store_calls, validation_calls;
static unsigned char journal[131072];
static size_t journal_size;
static struct s2a_direct_compile_context context;
static uint8_t lookup_identity[32], guest[64];
static const char program_json[] =
    "{\"schema\":\"s2a-direct-program-v1\",\"content\":{\"stages\":["
    "{\"stage\":\"vs\",\"spirv\":\"AwIjBwABAwAAAAAAAQAAAAAAAAA=\"},"
    "{\"stage\":\"fs\",\"spirv\":\"AwIjBwABAwAAAAAAAQAAAAAAAAA=\"}],\"bindings\":[]}}";
static void note(const void *p, size_t n) {
    assert(n <= sizeof journal - journal_size);
    memcpy(journal + journal_size, p, n); journal_size += n;
}
static void number(uint64_t n) { note(&n, sizeof n); }
static void string(const char *s) { number(strlen(s)); note(s, strlen(s)); }
static void copy_program(uint8_t **bytes, size_t *len, uint8_t sha[32]) {
    *len = sizeof program_json - 1; *bytes = malloc(*len); assert(*bytes);
    memcpy(*bytes, program_json, *len); nvk_sha256_bytes(*bytes, *len, sha);
}
int __system_property_get(const char *name, char *value) { (void)name; value[0] = 0; return 0; }
int __android_log_print(int level, const char *tag, const char *fmt, ...) {
    (void)level; (void)tag; (void)fmt; return 0;
}
int __android_log_vprint(int level, const char *tag, const char *fmt, va_list ap) {
    (void)level; (void)tag; (void)fmt; (void)ap; return 0;
}
void s2a_source_log_line(const char *line) { (void)line; }
int s2a_nvn_depth_mode = 1, s2a_nvn_window_origin_mode = 1;
uint64_t s2a_vk_adapter_registry_generation(void) { return 7; }
int s2a_direct_provider_compile_context(struct s2a_direct_compile_context *out) {
    provider_calls++; number(1); *out = context; return case_id == 13 ? -1 : 0;
}
int s2a_offline_library_fetch(const char *root, const struct s2a_offline_request *q,
    struct s2a_offline_program *out, char *why, size_t cap) {
    offline_calls++; number(2); string(root); number(q->direct_abi);
    string(q->profile_hash); number((unsigned)q->profile_declared); note(q->identity, 32);
    assert(!strcmp(root, "/synthetic-revision") && q->profile_declared);
    memcpy(lookup_identity, q->identity, 32);
    if (case_id == 1 || case_id == 14) {
        copy_program(&out->bytes, &out->len, out->result_sha);
        if (case_id == 14) out->bytes[0] = '!';
        return S2A_OFFLINE_HIT;
    }
    snprintf(why, cap, "synthetic offline miss"); return S2A_OFFLINE_MISS;
}
int s2a_program_cache_load(const char *root, const uint8_t identity[32],
    uint8_t **bytes, size_t *len, uint8_t sha[32], char *why, size_t cap) {
    private_calls++; number(3); string(root); note(identity, 32);
    assert(!strcmp(root, "/synthetic-private") && !memcmp(identity, lookup_identity, 32));
    if (case_id == 2) { copy_program(bytes, len, sha); return 0; }
    snprintf(why, cap, "synthetic private miss"); return -1;
}
int s2a_program_cache_store_async(const char *root, const uint8_t id[32],
    const uint8_t *bytes, size_t len) {
    store_calls++; number(4); string(root); note(id, 32); number(len); note(bytes, len); return 0;
}
uint64_t s2a_program_cache_stores(void) { return store_calls; }
uint64_t s2a_program_cache_failures(void) { return 0; }
int s2a_direct_diag_write(const char *root, const char *name, const void *bytes,
    size_t len, char *why, size_t cap) {
    (void)root; (void)name; (void)bytes; (void)len; (void)why; (void)cap;
    assert(!"diagnostic IO must remain disabled"); return -1;
}
static int32_t compile_boundary(uint64_t session, uint64_t generation,
    s2a_direct_bytes request, s2a_direct_emit_fn emit, void *sink) {
    compile_calls++; number(5); number(session); number(generation);
    number(request.bytes); note(request.data, (size_t)request.bytes);
    assert(session == 11 && generation == 22);
    assert(strstr((const char *)request.data, "\"stage\":\"vs\""));
    assert(strstr((const char *)request.data, "\"stage\":\"fs\""));
    if (case_id == 6 || case_id == 7) return -27;
    s2a_direct_bytes result = {(const uint8_t *)program_json, sizeof program_json - 1};
    return emit(sink, result);
}
s2a_direct_compile_fn s2a_direct_bound_compile_any(void) { return compile_boundary; }
int s2a_compile_worker_active(void) { return 0; }
int s2a_compile_worker_run(uint64_t session, uint64_t generation, const char *json, size_t len,
    const uint8_t sha[32], int deadline, int (*pause)(void *), void (*resume)(void *), void *ctx,
    uint8_t **bytes, size_t *bytes_len, char *why, size_t cap) {
    (void)session; (void)generation; (void)json; (void)len; (void)sha; (void)deadline;
    (void)pause; (void)resume; (void)ctx; (void)bytes; (void)bytes_len; (void)why; (void)cap;
    assert(!"synchronous compiler fixture unexpectedly used worker"); return -1;
}
void s2a_compile_worker_stats(struct s2a_compile_worker_stats *out) { memset(out, 0, sizeof *out); }
void nvk_pipeline_long_stats(uint64_t *n, uint64_t *fail, uint64_t *ns, uint64_t *max) {
    *n = *fail = *ns = *max = 0;
}
// The generated helper supplies the exact production program_valid wrapper,
// linked to the real graphics parser, not a success-returning parser substitute.
int w2_real_program_valid(const uint8_t *, size_t, char *, size_t);
int nvn_vk_first_draw_program_valid(const uint8_t *p, size_t n, char *why, size_t cap) {
    validation_calls++; number(6); number(n); note(p, n);
    return w2_real_program_valid(p, n, why, cap);
}
int nvn_vk_first_draw(struct s2a_vk_device *device, const struct s2a_record_draw_state *state,
    const uint8_t *program, size_t len, const uint8_t sha[32], const uint8_t identity[32],
    uint64_t session, uint64_t generation, const char *request_id, char *why, size_t cap) {
    gpu_calls++; number(7); number(session); number(generation); string(request_id);
    number(len); note(program, len); note(sha, 32); note(identity, 32);
    number(device->core_features.vertexPipelineStoresAndAtomics);
    assert(session == 11 && generation == 22);
    assert(state->c1_ok[0] && state->c1_ok[1]);
    assert(!memcmp(program, program_json, len) && len == sizeof program_json - 1);
    uint8_t digest[32]; nvk_sha256_bytes(program, len, digest); assert(!memcmp(digest, sha, 32));
    assert(!memcmp(identity, lookup_identity, 32));
    // Controlled downstream memory effects are independently checked and copied
    // into the binary oracle. No GPU or rendering result is claimed.
    for (unsigned i = 0; i < sizeof guest; ++i) guest[i] ^= (uint8_t)(state->count + i);
    snprintf(why, cap, case_id == 12 ? "synthetic device failure" : "synthetic device accepted");
    return case_id == 12 ? -1 : 0;
}
static void source(struct s2a_record_draw_state *state, unsigned slot) {
    uint8_t code[512], control[S2A_SOURCE_CONTROL_BYTES];
    for (unsigned i = 0; i < sizeof code; i++) code[i] = (uint8_t)(3 * i + slot + 1);
    memset(control, 0, sizeof control);
    uint32_t begin = 256, end = 512;
    memcpy(control + 0x700, &begin, 4); memcpy(control + 0x704, &end, 4);
    s2a_sha256 sha; uint8_t digest[32]; s2a_sha256_init(&sha);
    s2a_sha256_update(&sha, control, sizeof control); s2a_sha256_update(&sha, code, sizeof code);
    s2a_sha256_final(&sha, digest); memcpy(state->keys[slot], digest, 8);
    assert(!s2a_source_keep(state->keys[slot], slot, code, sizeof code, control, sizeof control));
}
static int draw(struct s2a_vk_device *device, struct s2a_record_draw_state *state,
    struct s2a_record_result *out) {
    memset(out, 0xa5, sizeof *out);
    return nvk_draw_builder(case_id == 8 ? NULL : device, state, out,
        case_id == 11 ? "" : "/synthetic-shaders");
}
#ifdef W2_HAVE_OBSERVER
static int write_receipt(void *opaque, const char *bytes, size_t n) {
    FILE *f = opaque; return fwrite(bytes, 1, n, f) == n && !fflush(f) ? 0 : -1;
}
#endif
int main(int argc, char **argv) {
    assert(argc == 5); case_id = (unsigned)atoi(argv[1]); int enabled = atoi(argv[2]);
    assert(case_id < 16);
    setenv("S2A_SHADER_REVISION_ROOT", "/synthetic-revision", 1);
    setenv("S2A_DIRECT_CACHE_DIR", "/synthetic-private", 1);
    unsetenv("S2A_DIRECT_DIAG_DIR");
    const char *hash = "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *profile = "{\"profileHash\":\"sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}";
    memset(&context, 0, sizeof context);
    context.session = 11; context.generation = 22; context.direct_abi = 1;
    context.translator_closure = "synthetic-closure"; context.profile_hash = hash;
    context.profile_json = profile; context.profile_bytes = strlen(profile);
    context.offline_profile_available = 1; context.shader_draw_parameters = 1;
    context.storage_buffer_offset_alignment = 16;
    if (case_id == 15) { context.profile_json = NULL; context.profile_bytes = 0; }
    struct s2a_record_draw_state state; memset(&state, 0, sizeof state);
    prog_t prog; memset(&prog, 0, sizeof prog); prog.serial = 123; prog.nstage = 2;
    state.program = case_id == 9 ? NULL : &prog;
    state.stages = case_id == 10 ? 0 : 3; state.prim = 4; state.rt_count = 1;
    state.rt[0].key = 0x1000; state.rt[0].format = VK_FORMAT_R8G8B8A8_UNORM;
    state.rt[0].nvn_format = 0x25; state.rt[0].obj_magic = 0x00584554u;
    state.tex_pool_n = 8; state.samp_pool_n = 8; state.state_seen = 0x3f;
    state.count = 3; state.instances = 1; state.ubo_use[0] = state.ubo_use[1] = 1;
    source(&state, 0); source(&state, 1);
    if (case_id == 5) s2a_source_clear();
    struct s2a_vk_device device; memset(&device, 0, sizeof device);
    device.core_features.vertexPipelineStoresAndAtomics = 1;
    memset(guest, 0x5a, sizeof guest);
    struct s2a_record_result result;
    int warmed = case_id == 3 || case_id == 4 || case_id == 7;
    if (warmed) {
        int warm_rc = draw(&device, &state, &result); assert((warm_rc == 0) == (case_id != 7));
        assert(g_program_slots && g_programs[0].users == 0);
        if (case_id == 4) memset(g_idmemo, 0, sizeof *g_idmemo * NVK_IDMEMO);
        memset(state.c1, 0, sizeof state.c1); memset(state.c1_ok, 0, sizeof state.c1_ok);
        memset(guest, 0x5a, sizeof guest);
    }
    journal_size = 0; provider_calls = offline_calls = private_calls = compile_calls = 0;
    gpu_calls = store_calls = validation_calls = 0;
#ifdef W2_HAVE_OBSERVER
    struct s2a_w2_window *window = s2a_w2_start(enabled, &context);
    assert((window != NULL) == (enabled != 0));
    struct s2a_w2_scope scope; s2a_w2_scope_enter(&scope); s2a_w2_scope_expect_shader(&scope);
#else
    assert(!enabled);
#endif
    errno = EDOM;
    int rc = draw(&device, &state, &result);
    int draw_errno = errno;
#ifdef W2_HAVE_OBSERVER
    s2a_w2_scope_leave(&scope, rc == 0);
#endif
    int success = case_id <= 4 || case_id == 14;
    assert((rc == 0) == success && result.code == rc);
    assert(result.opcode == UINT32_C(0xa5a5a5a5) && result.executed == UINT64_C(0xa5a5a5a5a5a5a5a5));
    assert(gpu_calls == (unsigned)(success || case_id == 12));
    if (warmed) assert(!compile_calls && !offline_calls && !private_calls);
    else if (case_id == 1) assert(offline_calls == 1 && !private_calls && !compile_calls && validation_calls == 1);
    else if (case_id == 2) assert(offline_calls == 1 && private_calls == 1 && !compile_calls);
    else if (success || case_id == 6 || case_id == 12)
        assert(offline_calls == 1 && private_calls == 1 && compile_calls == 1);
    else assert(!offline_calls && !private_calls && !compile_calls);
    if (case_id >= 8 && case_id <= 11) assert(!provider_calls);
    else assert(provider_calls == 1);
    for (unsigned i = 0; i < g_program_slots; i++) assert(g_programs[i].users == 0);
    for (unsigned i = 0; i < sizeof guest; i++)
        assert(guest[i] == (gpu_calls ? (uint8_t)(0x5a ^ (state.count + i)) : 0x5a));
    // Stable production cache state, excluding addresses and wall-clock timings.
    number(8); number(g_program_slots); number(g_program_bytes);
    number(g_program_lookups); number(g_program_hits); number(g_program_misses);
    number(g_program_compile_attempts); number(g_program_compile_success); number(g_program_compile_failures);
    number(g_program_disk_hits); number(g_program_offline_hits);
    for (unsigned i = 0; i < g_program_slots; i++) if (g_programs[i].key[0]) {
        const struct nvk_cached_program *e = &g_programs[i];
        number(i); string(e->key); note(e->input_sha, 32); number(e->input_len);
        if (e->input_len) note(e->input, e->input_len);
        number(e->len); if (e->len) note(e->bytes, e->len);
        string(e->request_id); note(e->request_sha, 32); note(e->result_sha, 32);
        number(e->session); number(e->generation); number(e->serial); number(e->users);
        number((unsigned)e->from_disk); number((unsigned)e->failed); string(e->why);
        number(e->c1_ok); note(e->c1, sizeof e->c1);
    }
    // Both complete result bytes and initialized state bytes are compared. Remove
    // the sole host pointer; all remaining fields/padding were initialized above.
    state.program = NULL;
    FILE *f = fopen(argv[3], "wb"); assert(f);
#define PUT(x) assert(fwrite(&(x), 1, sizeof(x), f) == sizeof(x))
    PUT(rc); PUT(draw_errno); PUT(result); PUT(state); PUT(guest);
    PUT(provider_calls); PUT(offline_calls); PUT(private_calls); PUT(compile_calls);
    PUT(gpu_calls); PUT(store_calls); PUT(validation_calls); PUT(journal_size);
    assert(fwrite(journal, 1, journal_size, f) == journal_size); assert(!fclose(f));
#ifdef W2_HAVE_OBSERVER
    if (enabled) {
        s2a_w2_close(window); assert(!s2a_w2_seal(window, 1, 1));
        struct s2a_w2_snapshot snap; assert(!s2a_w2_snapshot(window, &snap));
        // This is the original-source red: the frozen draw still performs the
        // same real work, but has no shader begin/lookup/end instrumentation.
        if (snap.shaders != 1 || snap.finished_shaders != 1)
            fprintf(stderr, "functional receipt mismatch: shaders=%llu finished=%llu expected=1/1\n",
                (unsigned long long)snap.shaders, (unsigned long long)snap.finished_shaders);
        assert(snap.shaders == 1 && snap.finished_shaders == 1);
        assert(snap.scopes == 1 && !snap.inflight_scopes && !snap.inflight_shaders);
        assert(!snap.window_complete && snap.accepted_builds == (unsigned)success);
        assert(snap.build_failures == (unsigned)!success);
        assert(snap.rejects == 2u * (unsigned)!success);
        int had_identity = success || case_id == 6 || case_id == 7 || case_id == 12;
        assert(snap.missing_identity == (unsigned)!had_identity);
        assert(!snap.request_set_proven && !snap.strict_proven && !snap.gpu_proven && !snap.w2_acceptance_proven);
        assert(snap.metadata_complete == success);
        if (success || case_id == 6 || case_id == 7 || case_id == 12) {
            static const unsigned expected[] = {4,2,3,0,1};
            unsigned src = case_id < 5 ? expected[case_id] : case_id == 7 ? 0 : 4;
            assert(snap.observations == 1 && snap.entry_count == 1);
            assert(snap.entries[0].kind == S2A_W2_GRAPHICS);
            assert(!memcmp(snap.entries[0].identity, lookup_identity, 32));
            for (unsigned i = 0; i < S2A_W2_SOURCE_COUNT; i++) {
                int rejected = case_id == 6 || case_id == 7;
                assert(snap.entries[0].source_counts[i] == (unsigned)(i == src && !rejected));
                assert(snap.entries[0].rejected_source_counts[i] == (unsigned)(i == src && rejected));
            }
            assert(!snap.entries[0].unknown_rejects);
        } else assert(snap.gaps || snap.rejects || snap.build_failures);
        f = fopen(argv[4], "wb"); assert(f);
        int exported = s2a_w2_export(window, write_receipt, f); assert(!fclose(f));
        assert((exported == 0) == success);
        assert(!s2a_w2_snapshot(window, &snap)); assert(snap.window_complete == success);
    }
    s2a_w2_release(window);
#endif
    s2a_source_clear();
    uint32_t entries, held, dropped; s2a_source_stats(&entries, &held, &dropped); assert(!held);
    printf("draw case=%u enabled=%d rc=%d calls=%u/%u/%u/%u binary=%s\n",
        case_id, enabled, rc, offline_calls, private_calls, compile_calls, gpu_calls, argv[3]);
    return 0;
}

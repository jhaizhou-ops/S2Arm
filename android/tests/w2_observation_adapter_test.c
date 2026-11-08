// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Host-only adapter seam. Production function bodies, observer and execution
// owner are real; record/device boundaries use synthetic, explicitly fixed data.
#define _POSIX_C_SOURCE 200809L
#define S2A_ANDROID_VK_ENGINE 1
#define S2A_ANDROID_VK_BACKEND_NVN_VK 1
#define S2A_ANDROID_DEBUG_ENV 1
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "w2_adapter_types.h"
#include "w2_observation.inc"
#include "nvn/nvn_vk_exec_owner.h"

#define CHECK(c) do { if (!(c)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #c); exit(1); \
} } while (0)

// The two extracted functions only forward this opaque device to record.
struct s2a_vk_device { uintptr_t sentinel; };
struct nvn_vk_session { struct s2a_vk_device device; };
struct s2a_replay_texture;
struct s2a_record_draw_state;
static struct nvn_vk_session g_session;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_exec_cv = PTHREAD_COND_INITIALIZER;
static struct nvk_exec_owner g_exec;
static int g_ready, g_cancel;
static char g_shader_dir[512];
static _Atomic unsigned g_exec_waiters, g_reg_gen;
static _Atomic int g_exec_busy_mirror;
static _Atomic uint64_t g_exec_lock_wait_ns, g_exec_lock_calls;
static _Thread_local unsigned tls_reg_gen;

static const char profile[] = "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
static struct s2a_direct_compile_context context = {
    .session = 17, .generation = 9, .direct_abi = 4,
    .translator_closure = "adapter-synthetic-closure", .profile_hash = profile
};
static const uint8_t identity[32] = {1, 3, 5, 7, 9, 11, 13, 15};
static const uint8_t changed_bytes[16] = {
    0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
    0xf0, 0xde, 0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12
};
static unsigned case_count;
static int record_rc, record_shader = 1, record_calls;
static int read_calls, write_calls, resolver_calls, builder_calls;
static unsigned char guest_bytes[64];
static uint64_t seen_expected, seen_scopes, seen_inflight;
static int block_record, record_at_gate, release_record, waiter_at_gate;
static int pause_after_unlock, unlock_at_gate, release_unlock;
static pthread_mutex_t gate_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cv = PTHREAD_COND_INITIALIZER;

static void wait_flag(int *flag) {
    CHECK(pthread_mutex_lock(&gate_mu) == 0);
    while (!*flag) CHECK(pthread_cond_wait(&gate_cv, &gate_mu) == 0);
    CHECK(pthread_mutex_unlock(&gate_mu) == 0);
}
static void set_flag(int *flag) {
    CHECK(pthread_mutex_lock(&gate_mu) == 0);
    *flag = 1;
    CHECK(pthread_cond_broadcast(&gate_cv) == 0);
    CHECK(pthread_mutex_unlock(&gate_mu) == 0);
}

// Observe the real adapter wait without changing its control flow. This is
// called with g_mu held; main takes g_mu after this notification to establish
// that the guest has reached the actual pthread_cond_wait release point.
static int observed_cond_wait(pthread_cond_t *cv, pthread_mutex_t *mu) {
    CHECK(cv == &g_exec_cv && mu == &g_mu);
    set_flag(&waiter_at_gate);
    return pthread_cond_wait(cv, mu);
}
static int observed_mutex_unlock(pthread_mutex_t *mu) {
    int rc = pthread_mutex_unlock(mu);
    if (mu == &g_mu && pause_after_unlock) {
        // Exactly the real guest impl -> wrapper seam: ownership and mutex are
        // released, but the wrapper's observer lease has not left yet.
        set_flag(&unlock_at_gate); wait_flag(&release_unlock);
    }
    return rc;
}
static int adapter_cmd_stats(void) { return 0; }
static int record_resolve_tex(void *opaque, const void *key,
                              struct s2a_replay_texture *out) {
    (void)opaque; (void)key; (void)out; return 0;
}
static int nvk_draw_builder(struct s2a_vk_device *device,
                            const struct s2a_record_draw_state *state,
                            struct s2a_record_result *result, void *opaque) {
    (void)device; (void)state; (void)result; (void)opaque; return 0;
}
static void s2a_record_set_tex_resolver(
    int (*resolve)(void *, const void *, struct s2a_replay_texture *), void *opaque) {
    CHECK(resolve == record_resolve_tex && opaque == &g_session); ++resolver_calls;
}
static void s2a_record_set_draw_builder(
    int (*draw)(struct s2a_vk_device *, const struct s2a_record_draw_state *,
                struct s2a_record_result *, void *), void *opaque) {
    CHECK(draw == nvk_draw_builder && opaque == g_shader_dir); ++builder_calls;
}
static int memory_read(void *opaque, uint64_t address, void *out, size_t bytes) {
    CHECK(opaque == guest_bytes && address == (uint64_t)(uintptr_t)guest_bytes);
    CHECK(bytes == 8); ++read_calls; memcpy(out, guest_bytes, bytes); return 0;
}
static int memory_write(void *opaque, uint64_t address, const void *data, size_t bytes) {
    CHECK(opaque == guest_bytes && address == (uint64_t)(uintptr_t)(guest_bytes + 16));
    CHECK(bytes == sizeof changed_bytes); ++write_calls;
    memcpy(guest_bytes + 16, data, bytes); return 0;
}
static const struct s2a_record_memory memory = { guest_bytes, memory_read, memory_write };

static int shader_opcode(uint32_t op) {
    return op == OP_DRAW || op == OP_DRAW_IDX || op == OP_DISPATCH;
}
static void emit_shader(enum s2a_w2_kind kind) {
    struct s2a_w2_shader shader;
    s2a_w2_shader_begin(&shader, kind);
    s2a_w2_shader_lookup(&context, identity, S2A_W2_LIVE, 1);
    s2a_w2_shader_end(&shader, 1);
}
static int s2a_record_exec_one(struct s2a_vk_device *device, const uint8_t *packet,
                                size_t len, const struct s2a_record_memory *m,
                                struct s2a_record_result *result) {
    CHECK(device == &g_session.device);
    ++record_calls;
    seen_expected = w2_scope ? w2_scope->expected_shaders : 0;
    seen_scopes = w2_scope && w2_scope->window ? w2_scope->window->data.scopes : 0;
    seen_inflight = w2_scope && w2_scope->window ? w2_scope->window->data.inflight_scopes : 0;
    op_hdr h = {0};
    int rc = record_rc;
    if (packet && len >= sizeof h) memcpy(&h, packet, sizeof h);
    else rc = S2A_RECORD_INVALID;
    if (record_shader && !rc && shader_opcode(h.op))
        emit_shader(h.op == OP_DISPATCH ? S2A_W2_COMPUTE : S2A_W2_GRAPHICS);
    if (m && packet && len >= sizeof h) {
        uint8_t before[8];
        CHECK(m->read(m->opaque, (uint64_t)(uintptr_t)guest_bytes, before, sizeof before) == 0);
        for (size_t i = 0; i < sizeof before; ++i) CHECK(before[i] == (uint8_t)(0xa0 + i));
        CHECK(m->write(m->opaque, (uint64_t)(uintptr_t)(guest_bytes + 16),
                       changed_bytes, sizeof changed_bytes) == 0);
    }
    if (result) {
        // Preserve bytes outside these fields, just as an ordinary boundary may.
        result->code = rc; result->opcode = h.op; result->executed = 23;
        memcpy(result->why, "synthetic record boundary", 26);
    }
    if (block_record) { set_flag(&record_at_gate); wait_flag(&release_record); }
    return rc;
}

// 事件完成门的宿主边界桩。生产 adapter_event_completion_gate（mtl_vk_adapter.c:911）
// 在回放 GPU 侧事件写前调用 nvn_vk_first_draw_pass_break(1) 要“关 open pass + 提交 + 等
// fence”的完成证明（nvn_vk_first_draw.c:3125），失败时用 first_error 的原因写 result。
// 本夹具不接真帧队列，改由测试逐个驱动这两种返回：0 = 有证明（正常回放），非 0 =
// 拿不到证明（必须 fail-closed，guest 值一个字节都不写）。闸门逻辑本身仍是生产原文。
static int event_proof_rc;
static const char *event_proof_error = "";
int nvn_vk_first_draw_pass_break(int sync) { CHECK(sync == 1); return event_proof_rc; }
const char *nvn_vk_first_draw_first_error(void) { return event_proof_error; }

// Generated by the Python driver, byte-for-byte production functions. Only the
// pthread wait symbol is interposed for the deterministic scheduling handshake.
#define pthread_cond_wait observed_cond_wait
#define pthread_mutex_unlock observed_mutex_unlock
#include "w2_adapter_bodies.h"
#undef pthread_mutex_unlock
#undef pthread_cond_wait

static void reset_runtime(void) {
    CHECK(!w2_scope && !w2_shader && !w2_current);
    g_ready = 1; g_cancel = 0;
    nvk_exec_owner_init(&g_exec, 9);
    atomic_store(&g_exec_waiters, 0); atomic_store(&g_exec_busy_mirror, 0);
    atomic_store(&g_reg_gen, 1); tls_reg_gen = 0;
    record_rc = 0; record_shader = 1; record_calls = 0;
    read_calls = write_calls = resolver_calls = builder_calls = 0;
    seen_expected = seen_scopes = seen_inflight = 0;
    block_record = record_at_gate = release_record = waiter_at_gate = 0;
    pause_after_unlock = unlock_at_gate = release_unlock = 0;
    for (size_t i = 0; i < sizeof guest_bytes; ++i) guest_bytes[i] = (uint8_t)(0xa0 + i);
}
static int invoke(int guest, const uint8_t *packet, size_t len, struct s2a_record_result *r) {
    return guest ? s2a_vk_adapter_exec_guest(packet, len, r)
                 : s2a_vk_adapter_exec(packet, len, &memory, r);
}
static int invoke_op(int guest, uint32_t op, struct s2a_record_result *r) {
    op_hdr h = {op, sizeof h};
    return invoke(guest, (const uint8_t *)&h, sizeof h, r);
}
static struct s2a_w2_window *open_window(void) {
    struct s2a_w2_window *w = s2a_w2_start(1, &context); CHECK(w); return w;
}
static struct s2a_w2_snapshot snapshot(struct s2a_w2_window *w) {
    struct s2a_w2_snapshot d;
    CHECK(s2a_w2_snapshot(w, &d) == 0);
    CHECK(!d.request_set_proven && !d.strict_proven && !d.gpu_proven && !d.w2_acceptance_proven);
    return d;
}
static struct s2a_w2_snapshot finish(struct s2a_w2_window *w) {
    s2a_w2_close(w);
    CHECK(s2a_w2_seal(w, 1, 1) == 0);
    struct s2a_w2_snapshot d = snapshot(w);
    CHECK(d.state == S2A_W2_SEALED);
    return d;
}
static void test_complete(void) {
    for (int guest = 0; guest != 2; ++guest) {
        reset_runtime(); struct s2a_w2_window *w = open_window();
        struct s2a_record_result r; memset(&r, 0x5a, sizeof r);
        CHECK(invoke_op(guest, OP_DRAW, &r) == 0);
        CHECK(seen_scopes == 1 && seen_inflight == 1);
        CHECK(seen_expected == 1);
        CHECK(!w2_scope && !w2_shader);
        struct s2a_w2_snapshot d = snapshot(w);
        CHECK(d.scopes == 1 && d.inflight_scopes == 0);
        CHECK(d.shaders == 1 && d.finished_shaders == 1 && d.observations == 1);
        d = finish(w);
        CHECK(d.metadata_complete && !d.window_complete && !d.gaps);
        CHECK(s2a_w2_ack(w, &d, 1) == 0);
        CHECK(snapshot(w).window_complete);
        s2a_w2_release(w); ++case_count;
    }
}
static void test_expected_shader(void) {
    const uint32_t ops[] = {OP_DRAW, OP_DRAW_IDX, OP_DISPATCH, OP_UPDATE_UB};
    for (int guest = 0; guest != 2; ++guest) for (size_t i = 0; i < 4; ++i) {
        reset_runtime(); struct s2a_w2_window *w = open_window();
        CHECK(invoke_op(guest, OP_DRAW, NULL) == 0);
        record_shader = 0;
        // Real record can reject these shader opcodes before calling a builder.
        // This seam injects that rejection, not an invented successful shader.
        record_rc = shader_opcode(ops[i]) ? S2A_RECORD_INVALID : S2A_RECORD_OK;
        CHECK(invoke_op(guest, ops[i], NULL) == record_rc);
        CHECK(seen_expected == (uint64_t)shader_opcode(ops[i]));
        struct s2a_w2_snapshot d = finish(w);
        CHECK(d.scopes == 2 && d.shaders == 1 && d.observations == 1);
        CHECK(d.metadata_complete == !shader_opcode(ops[i]));
        CHECK((d.gaps > 0) == shader_opcode(ops[i]));
        CHECK((d.rejects > 0) == shader_opcode(ops[i]));
        s2a_w2_release(w); ++case_count;
    }
}
static void test_safe_header(void) {
    for (int guest = 0; guest != 2; ++guest) {
        for (size_t len = 0; len < sizeof(op_hdr); ++len) {
            reset_runtime(); struct s2a_w2_window *w = open_window();
            uint8_t *short_header = malloc(len ? len : 1); CHECK(short_header);
            memset(short_header, OP_DRAW, len);
            const uint8_t *packet = len ? short_header : (const uint8_t *)(uintptr_t)1;
            CHECK(invoke(guest, packet, len, NULL) == S2A_RECORD_INVALID);
            CHECK(seen_expected == 0);
            CHECK(finish(w).shaders == 0);
            s2a_w2_release(w); free(short_header); ++case_count;
        }
        reset_runtime(); struct s2a_w2_window *w = open_window();
        CHECK(invoke(guest, NULL, sizeof(op_hdr), NULL) == S2A_RECORD_INVALID);
        CHECK(seen_expected == 0); (void)finish(w); s2a_w2_release(w); ++case_count;
        reset_runtime(); w = open_window();
        uint8_t unaligned[sizeof(op_hdr) + 1]; op_hdr h = {OP_DISPATCH, sizeof h};
        memcpy(unaligned + 1, &h, sizeof h);
        CHECK(invoke(guest, unaligned + 1, sizeof h, NULL) == 0);
        CHECK(seen_expected == 1 && finish(w).metadata_complete);
        s2a_w2_release(w); ++case_count;
    }
}
static void expected_not_ready(struct s2a_record_result *r, int guest) {
    r->code = S2A_RECORD_ARGUMENT;
    snprintf(r->why, sizeof r->why, "%s", guest ? "adapter not initialized or stopping" : "adapter not initialized");
}
static void test_not_ready(void) {
    for (int guest = 0; guest != 2; ++guest) for (int enabled = 0; enabled != 2; ++enabled) {
        reset_runtime(); g_ready = 0;
        struct s2a_w2_window *w = enabled ? open_window() : NULL;
        struct s2a_record_result r, expected;
        memset(&r, 0x5a, sizeof r); expected = r; expected_not_ready(&expected, guest);
        const uint8_t *invalid = (const uint8_t *)(uintptr_t)1;
        CHECK(invoke(guest, invalid, sizeof(op_hdr), &r) == S2A_RECORD_ARGUMENT);
        CHECK(memcmp(&r, &expected, sizeof r) == 0 && !record_calls);
        CHECK(invoke(guest, invalid, sizeof(op_hdr), NULL) == S2A_RECORD_ARGUMENT);
        CHECK(!record_calls && !g_exec.busy && !atomic_load(&g_exec_busy_mirror));
        CHECK(!w2_scope && !w2_shader);
        if (w) {
            struct s2a_w2_snapshot d = finish(w);
            CHECK(d.scopes == 2 && !d.inflight_scopes && !d.shaders && !d.metadata_complete);
            s2a_w2_release(w);
        }
        ++case_count;
    }
}

struct call { int guest, rc; struct s2a_record_result result; };
static void *run_adapter(void *opaque) {
    struct call *c = opaque;
    memset(&c->result, 0x5a, sizeof c->result);
    c->rc = invoke_op(c->guest, OP_DRAW, &c->result);
    CHECK(!w2_scope && !w2_shader); return NULL;
}
static void test_inflight_close(void) {
    for (int guest = 0; guest != 2; ++guest) {
        reset_runtime(); struct s2a_w2_window *w = open_window();
        block_record = 1; struct call c = {.guest = guest}; pthread_t thread;
        CHECK(pthread_create(&thread, NULL, run_adapter, &c) == 0); wait_flag(&record_at_gate);
        struct s2a_w2_snapshot d = snapshot(w);
        CHECK(d.inflight_scopes == 1 && d.shaders == 1 && d.inflight_shaders == 0);
        s2a_w2_close(w);
        CHECK(s2a_w2_seal(w, 1, 1) == -1);
        d = snapshot(w); CHECK(d.state == S2A_W2_CLOSING && !d.gaps);
        set_flag(&release_record); CHECK(pthread_join(thread, NULL) == 0);
        CHECK(c.rc == 0 && c.result.code == 0);
        d = finish(w); CHECK(d.metadata_complete && !d.inflight_scopes);
        s2a_w2_release(w); ++case_count;
    }
}
static void test_guest_wait_lease(void) {
    reset_runtime(); struct s2a_w2_window *w = open_window();
    CHECK(invoke_op(0, OP_DRAW, NULL) == 0); // One accepted observation before Stop.
    CHECK(pthread_mutex_lock(&g_mu) == 0);
    CHECK(nvk_exec_owner_enter(&g_exec, 123) == NVK_EXEC_ENTER_READY);
    atomic_store(&g_exec_busy_mirror, 1);
    CHECK(pthread_mutex_unlock(&g_mu) == 0);
    struct call c = {.guest = 1}; pthread_t thread;
    CHECK(pthread_create(&thread, NULL, run_adapter, &c) == 0); wait_flag(&waiter_at_gate);
    CHECK(pthread_mutex_lock(&g_mu) == 0); // Guest now in the real cond wait.
    CHECK(atomic_load(&g_exec_waiters) == 1 && g_exec.stats.wait_enters >= 1);
    struct s2a_w2_snapshot d = snapshot(w);
    CHECK(d.scopes == 2 && d.inflight_scopes == 1 && d.inflight_shaders == 0);
    s2a_w2_close(w); g_cancel = 1; nvk_exec_owner_request_stop(&g_exec);
    // Simulate the original owner/worker finishing, but do not wake the queued
    // guest yet. A zero busy mirror is NOT proof that its observer lease left.
    CHECK(nvk_exec_owner_leave(&g_exec, 123) == 0);
    atomic_store(&g_exec_busy_mirror, 0);
    CHECK(!nvk_exec_owner_busy(&g_exec));
    CHECK(s2a_w2_seal(w, 1, 1) == -1);
    d = snapshot(w); CHECK(d.state == S2A_W2_CLOSING && d.inflight_scopes == 1 && !d.gaps);
    CHECK(pthread_cond_broadcast(&g_exec_cv) == 0);
    CHECK(pthread_mutex_unlock(&g_mu) == 0);
    CHECK(pthread_join(thread, NULL) == 0);
    struct s2a_record_result expected; memset(&expected, 0x5a, sizeof expected);
    expected_not_ready(&expected, 1);
    CHECK(c.rc == S2A_RECORD_ARGUMENT && memcmp(&c.result, &expected, sizeof expected) == 0);
    CHECK(record_calls == 1 && !atomic_load(&g_exec_waiters) && !atomic_load(&g_exec_busy_mirror));
    d = finish(w); CHECK(d.inflight_scopes == 0 && d.gaps == 1 && d.rejects == 1);
    CHECK(!d.metadata_complete && d.shaders == 1 && d.observations == 1);
    s2a_w2_release(w); ++case_count;
}
struct export_race {
    pthread_t thread;
    int release_in_writer, writes;
    char text[65536];
};
static int race_writer(void *opaque, const char *text, size_t bytes) {
    struct export_race *r = opaque;
    CHECK(bytes < sizeof r->text);
    memcpy(r->text, text, bytes); r->text[bytes] = 0; ++r->writes;
    if (r->release_in_writer) {
        // This advances revision strictly after export captured its incomplete
        // snapshot and before its write-success acknowledgement.
        set_flag(&release_unlock); CHECK(pthread_join(r->thread, NULL) == 0);
        r->release_in_writer = 0;
    }
    return 0;
}
static void test_guest_unlock_export_race(void) {
    reset_runtime(); struct s2a_w2_window *w = open_window();
    pause_after_unlock = 1; struct call c = {.guest = 1};
    struct export_race sink = {.release_in_writer = 1};
    CHECK(pthread_create(&sink.thread, NULL, run_adapter, &c) == 0); wait_flag(&unlock_at_gate);
    CHECK(!atomic_load(&g_exec_busy_mirror));
    CHECK(pthread_mutex_lock(&g_mu) == 0);
    CHECK(!nvk_exec_owner_busy(&g_exec));
    CHECK(pthread_mutex_unlock(&g_mu) == 0);
    struct s2a_w2_snapshot before = snapshot(w);
    CHECK(before.inflight_scopes == 1 && before.inflight_shaders == 0 && before.shaders == 1);
    s2a_w2_close(w);
    CHECK(s2a_w2_seal(w, 1, 1) == -1);
    CHECK(s2a_w2_export(w, race_writer, &sink) == -1);
    CHECK(c.rc == 0 && c.result.code == 0 && sink.writes == 1);
    CHECK(strstr(sink.text, "\"metadata_eligible\":false"));
    struct s2a_w2_snapshot after = snapshot(w);
    printf("unlock/export: busy=0, leases=1->%llu, first_seal=-1, first_export=-1, output_failures=%llu, gaps=%llu\n",
           (unsigned long long)after.inflight_scopes,
           (unsigned long long)after.output_failures, (unsigned long long)after.gaps);
    CHECK(after.revision > before.revision && after.inflight_scopes == 0);
    CHECK(after.output_failures == 0 && after.gaps == 0 && !after.window_complete);
    after = finish(w); CHECK(after.metadata_complete && !after.window_complete);
    CHECK(s2a_w2_export(w, race_writer, &sink) == 0 && sink.writes == 2);
    CHECK(strstr(sink.text, "\"metadata_eligible\":true"));
    CHECK(snapshot(w).window_complete);
    s2a_w2_release(w); ++case_count;
}
static void *unbound_shader_thread(void *opaque) {
    (void)opaque; CHECK(!w2_scope && !w2_shader); emit_shader(S2A_W2_COMPUTE);
    CHECK(!w2_scope && !w2_shader); return NULL;
}
static void test_tls_isolation(void) {
    for (int guest = 0; guest != 2; ++guest) {
        reset_runtime(); struct s2a_w2_window *w = open_window();
        CHECK(invoke_op(guest, OP_DRAW, NULL) == 0);
        CHECK(!w2_scope && !w2_shader); emit_shader(S2A_W2_GRAPHICS);
        struct s2a_w2_snapshot d = finish(w);
        CHECK(d.scopes == 1 && d.unbound == 1 && d.accepted_builds == 1 && !d.metadata_complete);
        s2a_w2_release(w); ++case_count;

        reset_runtime(); w = open_window(); block_record = 1;
        struct call c = {.guest = guest}; pthread_t adapter, foreign;
        CHECK(pthread_create(&adapter, NULL, run_adapter, &c) == 0); wait_flag(&record_at_gate);
        CHECK(pthread_create(&foreign, NULL, unbound_shader_thread, NULL) == 0);
        CHECK(pthread_join(foreign, NULL) == 0);
        d = snapshot(w); CHECK(d.inflight_scopes == 1 && d.unbound == 1 && d.accepted_builds == 1);
        set_flag(&release_record); CHECK(pthread_join(adapter, NULL) == 0);
        CHECK(c.rc == 0); d = finish(w); CHECK(!d.metadata_complete && d.scopes == 1);
        s2a_w2_release(w); ++case_count;
    }
}
static void test_late_scope(void) {
    for (int guest = 0; guest != 2; ++guest) {
        reset_runtime(); struct s2a_w2_window *w = open_window();
        CHECK(invoke_op(guest, OP_DRAW, NULL) == 0);
        s2a_w2_close(w);
        CHECK(invoke_op(guest, OP_DISPATCH, NULL) == 0); // Instrumentation does not change record success.
        struct s2a_w2_snapshot d = finish(w);
        CHECK(d.scopes == 2 && d.accepted_builds == 1 && d.protocol_errors > 0 && !d.metadata_complete);
        CHECK(!w2_scope && !w2_shader); s2a_w2_release(w); ++case_count;
    }
}

// 事件完成门（本支新增生产路径，mtl_vk_adapter.c:911-929 / :1012-1020）：
// GPU 侧事件写（OP_SIGNAL_EVENT 且不带 NVN_EV_WAIT 位）在回放前必须有前序 GPU 工作完成
// 证明；拿不到就返回 S2A_RECORD_GPU 且不写 guest 值（fail-closed）。带 WAIT 位的是“等事件”
// 不是信号事件，不要求证明（:920-928）。三种路径都走生产抽取的闸门代码。
static void event_packet(uint8_t packet[24], uint32_t mode) {
    memset(packet, 0, 24);
    op_hdr h = {OP_SIGNAL_EVENT, 24};
    memcpy(packet, &h, sizeof h);
    memcpy(packet + sizeof h + 8, &mode, 4);   // 生产在 payload+8 读事件模式（nvn_mtl.h NVN_EV_WAIT）
}
static void test_event_completion_gate(void) {
    uint8_t packet[24];
    for (int guest = 0; guest != 2; ++guest) {
        // 负：没有完成证明 → 不回调 record、guest 值不写，结果指向事件信号与现场原因。
        reset_runtime(); event_proof_rc = -1; event_proof_error = "frame queue has no completion proof";
        event_packet(packet, 0);
        struct s2a_record_result r; memset(&r, 0x5a, sizeof r);
        CHECK(invoke(guest, packet, sizeof packet, &r) == S2A_RECORD_GPU);
        CHECK(r.code == S2A_RECORD_GPU && r.opcode == OP_SIGNAL_EVENT);
        CHECK(strstr(r.why, "no completion proof") && strstr(r.why, "frame queue has no completion proof"));
        CHECK(record_calls == 0 && read_calls == 0 && write_calls == 0);
        for (size_t i = 0; i < sizeof guest_bytes; ++i) CHECK(guest_bytes[i] == (uint8_t)(0xa0 + i));
        CHECK(!g_exec.busy && !atomic_load(&g_exec_busy_mirror));
        ++case_count;
        // 正：有完成证明 → 正常回放（record 被调用，guest 值被这次回放写入）。
        reset_runtime(); event_proof_rc = 0;
        memset(&r, 0x5a, sizeof r);
        CHECK(invoke(guest, packet, sizeof packet, &r) == 0);
        // guest 路径的读/写走生产 guest_rd/guest_wr（直接读写宿主地址），不经过夹具计数；
        // 两条路径都直接验 guest 值确实被这次回放写入。
        CHECK(r.code == 0 && record_calls == 1);
        CHECK(memcmp(guest_bytes + 16, changed_bytes, sizeof changed_bytes) == 0);
        CHECK(!g_exec.busy && !atomic_load(&g_exec_busy_mirror));
        ++case_count;
        // 等待位（NVN_EV_WAIT）：不是信号事件，不要求完成证明。
        reset_runtime(); event_proof_rc = -1;
        event_packet(packet, 0x80000000u);
        memset(&r, 0x5a, sizeof r);
        CHECK(invoke(guest, packet, sizeof packet, &r) == 0);
        CHECK(r.code == 0 && record_calls == 1);
        CHECK(memcmp(guest_bytes + 16, changed_bytes, sizeof changed_bytes) == 0);
        CHECK(!g_exec.busy && !atomic_load(&g_exec_busy_mirror));
        ++case_count;
    }
}
static void write_bytes(FILE *out, const void *data, size_t size) {
    CHECK(fwrite(data, 1, size, out) == size);
}
static void behavior_bytes(int enabled, const char *path) {
    FILE *out = fopen(path, "wb"); CHECK(out); unsigned rows = 0;
    // For each real entry: all eight record codes, missing result, and the
    // not-ready early return with an unreadable packet. Compare the entire
    // result object and guest buffer, not a hash or selected result fields.
    for (int guest = 0; guest != 2; ++guest) for (int mode = 0; mode < 10; ++mode) {
        reset_runtime(); struct s2a_w2_window *w = enabled ? open_window() : NULL;
        struct s2a_record_result r; memset(&r, 0x5a, sizeof r);
        op_hdr h = {mode == 0 ? OP_UPDATE_UB : OP_DRAW, sizeof h};
        record_rc = mode < 8 ? -mode : 0;
        const uint8_t *packet = (const uint8_t *)&h;
        if (mode == 9) { g_ready = 0; packet = (const uint8_t *)(uintptr_t)1; }
        int rc = invoke(guest, packet, sizeof h, mode == 8 ? NULL : &r);
        CHECK(rc == (mode == 9 ? S2A_RECORD_ARGUMENT : record_rc));
        unsigned char expected_guest[64];
        for (size_t i = 0; i < sizeof expected_guest; ++i) expected_guest[i] = (uint8_t)(0xa0 + i);
        if (mode != 9) memcpy(expected_guest + 16, changed_bytes, sizeof changed_bytes);
        CHECK(memcmp(guest_bytes, expected_guest, sizeof guest_bytes) == 0);
        CHECK(!g_exec.busy && !atomic_load(&g_exec_busy_mirror));
        write_bytes(out, &rc, sizeof rc); write_bytes(out, &r, sizeof r);
        write_bytes(out, guest_bytes, sizeof guest_bytes);
        int counts[] = {record_calls, read_calls, write_calls, resolver_calls, builder_calls};
        write_bytes(out, counts, sizeof counts);
        write_bytes(out, &g_exec.stats, sizeof g_exec.stats);
        if (w) { s2a_w2_close(w); CHECK(s2a_w2_seal(w, 1, 1) == 0); s2a_w2_release(w); }
        ++rows;
    }
    CHECK(fclose(out) == 0);
    printf("PASS behavior: %u rows, observer=%d, full result/guest/callback/owner bytes\n", rows, enabled);
}
int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "bytes")) { behavior_bytes(atoi(argv[2]), argv[3]); return 0; }
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "complete")) test_complete();
    else if (!strcmp(argv[1], "expected")) test_expected_shader();
    else if (!strcmp(argv[1], "safe-header")) test_safe_header();
    else if (!strcmp(argv[1], "not-ready")) test_not_ready();
    else if (!strcmp(argv[1], "inflight")) test_inflight_close();
    else if (!strcmp(argv[1], "guest-wait")) test_guest_wait_lease();
    else if (!strcmp(argv[1], "unlock-export")) test_guest_unlock_export_race();
    else if (!strcmp(argv[1], "event-gate")) test_event_completion_gate();
    else if (!strcmp(argv[1], "tls")) test_tls_isolation();
    else if (!strcmp(argv[1], "late")) test_late_scope();
    else return 2;
    printf("PASS %s: %u cases\n", argv[1], case_count); return 0;
}

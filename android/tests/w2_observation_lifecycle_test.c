// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Production provider lifecycle bodies, controlled device retirement and sink IO.
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "direct/s2a_direct.h"
#include "debug_gate.h"
#include "direct/w2_observation.inc"
#define TAG "test"
#define ANDROID_LOG_ERROR 6
#define ANDROID_LOG_INFO 4
#define ANDROID_LOG_WARN 5
struct s2a_vk_device { int value; };
#include "provider_context.h"
static struct provider_context *g_active_context, *g_retained_context;
static pthread_mutex_t g_window_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int g_stop_published, g_session_active;
static _Atomic unsigned long long g_owner_slices, g_owner_suspended_slices, g_owner_window_actions, g_owner_stop_seen;
static int shutdown_error, device_error, shutdown_calls, device_calls, releases, frees, writes, write_error;
static const char *debug_gate = "1", *observer_gate = "1";
static char output[65536], first_stop_output[65536];
static struct s2a_w2_window *observed_window;
static struct s2a_w2_snapshot sink_snapshot;
static int __android_log_print(int level, const char *tag, const char *fmt, ...) { (void)level; (void)tag; (void)fmt; return 0; }
int __system_property_get(const char *key, char *out) {
    const char *value = !strcmp(key, "debug.s2a.debug_env") ? debug_gate :
        !strcmp(key, "debug.s2a.w2_observation") ? observer_gate : "";
    strcpy(out, value); return (int)strlen(value);
}
int s2a_direct_provider_compile_context(struct s2a_direct_compile_context *out) {
    assert(g_active_context);
    *out = (struct s2a_direct_compile_context){.session=g_active_context->session,
        .generation=g_active_context->generation, .direct_abi=g_active_context->direct_abi,
        .translator_closure=g_active_context->closure, .profile_hash=g_active_context->profile_hash};
    return 0;
}
static int s2a_direct_diag_write(const char *dir, const char *name, const void *data, size_t size, char *why, size_t cap) {
    assert(!strcmp(dir, "/private/attempt/direct-diagnostics"));
    assert(!strcmp(name, "w2-observation-11-22.json"));
    // Export owns a live reference and releases its mutex before this actual sink.
    assert(s2a_w2_snapshot(observed_window, &sink_snapshot)==0);
    assert(size < sizeof output); memcpy(output, data, size); output[size] = 0; writes++;
    if (write_error) { snprintf(why, cap, "controlled write failure"); return -1; }
    return 0;
}
static void diag_log_manifest(const char *a, const char *b) { (void)a; (void)b; }
int32_t s2a_direct_unbind_compiler_v1(void *p) { (void)p; return 0; }
static void ctl_wake(void) {}
static int s2a_vk_adapter_shutdown(void) { shutdown_calls++; return shutdown_error; }
static void release_lease_window(struct provider_context *p) { (void)p; releases++; }
static void set_window_error(struct provider_context *p, const char *s) { snprintf(p->window_error, sizeof p->window_error, "%s", s); }
static int s2a_vk_device_destroy(struct s2a_vk_device *d, int stop) { (void)d; (void)stop; device_calls++; return device_error; }
static void observed_free(void *p) { frees++; free(p); }
#define free observed_free
#include "provider_bodies.h"
#undef free

static struct provider_context *context(void) {
    struct provider_context *c = calloc(1, sizeof *c); assert(c);
    c->session=11; c->generation=22; c->direct_abi=1;
    strcpy(c->closure, "synthetic-closure");
    strcpy(c->profile_hash, "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    strcpy(c->diag_dir, "/private/attempt/direct-diagnostics");
    c->state=S2A_DIRECT_ACTIVE; c->engine_ok=1; c->device_ok=1;
    g_active_context=c;
    return c;
}
static void shader_event(int kind) {
    struct s2a_direct_compile_context pc; s2a_direct_provider_compile_context(&pc);
    struct s2a_w2_scope scope={0}; struct s2a_w2_shader shader={0};
    uint8_t identity[32]={1}; identity[31]=(uint8_t)kind;
    s2a_w2_scope_enter(&scope); s2a_w2_scope_expect_shader(&scope);
    s2a_w2_shader_begin(&shader, (enum s2a_w2_kind)kind);
    s2a_w2_shader_lookup(&pc, identity, S2A_W2_OFFLINE, 1);
    s2a_w2_shader_end(&shader, 1); s2a_w2_scope_leave(&scope, 1);
}
int main(int argc, char **argv) {
    assert(argc==2); int mode=atoi(argv[1]);
    if (mode==1) observer_gate="0";
    if (mode==2) debug_gate="0";
    if (mode==3) observer_gate="01";
    if (mode==4) debug_gate="01";
    struct provider_context *c=context();
    errno=EDOM; provider_w2_begin(c); assert(errno==EDOM);
    int enabled=W2_EXPECT_DEBUG && mode!=1 && mode!=2 && mode!=3 && mode!=4;
    assert((c->observation!=NULL)==enabled);
    struct s2a_w2_window *window=c->observation; observed_window=window;
    if (mode!=5) { shader_event(S2A_W2_GRAPHICS); shader_event(S2A_W2_COMPUTE); }
    if (mode==6) shutdown_error=-1;
    if (mode==7) write_error=1;
    struct s2a_w2_scope inflight={0};
    if (mode==8) s2a_w2_scope_enter(&inflight);
    errno=ERANGE; int rc=request_stop(c); assert(errno==ERANGE);
    assert(rc==(mode==6 ? S2A_DIRECT_RES_RETIREMENT : S2A_DIRECT_RES_OK));
    assert(shutdown_calls==1 && c->engine_ok==(mode==6));
    assert(c->state==(mode==6 ? S2A_DIRECT_FAILED : S2A_DIRECT_STOPPED));
    assert(releases==(mode==6 ? 0 : 1));
    if (enabled) {
        struct s2a_w2_snapshot snapshot;
        assert(writes==1 && strstr(output, "\"window_complete\":false"));
        assert(s2a_w2_snapshot(window, &snapshot)==0);
        int complete=mode!=5 && mode!=6 && mode!=7 && mode!=8;
        assert(snapshot.metadata_complete==complete && snapshot.window_complete==complete);
        if (mode==8) { assert(snapshot.inflight_scopes==1); s2a_w2_scope_leave(&inflight, 1); }
        if (mode==9) {
            shader_event(S2A_W2_GRAPHICS);
            assert(s2a_w2_snapshot(window, &snapshot)==0 && !snapshot.window_complete && snapshot.late);
        }
    } else assert(writes==0);
    if (enabled) strcpy(first_stop_output, output);
    if (mode==6) {
        int first=destroy(c); assert(first==S2A_DIRECT_RES_RETIREMENT && !frees && g_retained_context==c);
        shutdown_error=0; assert(request_stop(c)==0);
    }
    if (mode==10) {
        device_error=-1; assert(destroy(c)==S2A_DIRECT_RES_RETIREMENT && !frees);
        device_error=0;
    }
    struct s2a_w2_snapshot before_destroy = {0};
    int before_writes = writes;
    if (enabled) {
        assert(s2a_w2_snapshot(window, &before_destroy)==0);
        if (mode==6 || mode==10) {
            assert(before_destroy.stop_failures && before_destroy.drain_failures && before_destroy.gaps);
            assert(!before_destroy.metadata_complete && !before_destroy.window_complete);
        }
    }
    assert(destroy(c)==S2A_DIRECT_RES_OK && frees==1 && !g_active_context && !g_retained_context);
    // Do not read window after successful destroy: inspect only the sink's retained value copy.
    if (enabled) {
        assert(writes==before_writes+1 && sink_snapshot.instance==before_destroy.instance);
        if (mode!=8) { // Mode 8 first drains its old lease after Stop; destroy may seal it for the first time.
            assert(sink_snapshot.revision==before_destroy.revision);
            assert(sink_snapshot.metadata_complete==before_destroy.metadata_complete);
            assert(sink_snapshot.window_complete==before_destroy.window_complete);
        } else {
            assert(sink_snapshot.state==S2A_W2_SEALED && sink_snapshot.metadata_complete);
            assert(!sink_snapshot.window_complete); // The first eligible export is not acknowledged yet.
        }
        assert(sink_snapshot.stop_failures==before_destroy.stop_failures);
        assert(sink_snapshot.drain_failures==before_destroy.drain_failures);
        assert(sink_snapshot.gaps==before_destroy.gaps);
        assert(sink_snapshot.observations==before_destroy.observations);
        assert(sink_snapshot.accepted_builds==before_destroy.accepted_builds);
        assert(strstr(output, "\"window_complete\":false"));
        if (mode==0) assert(!strcmp(output, first_stop_output));
    } else assert(writes==0);
    printf("provider lifecycle debug=%d mode=%d PASS\n", W2_EXPECT_DEBUG, mode);
    return 0;
}

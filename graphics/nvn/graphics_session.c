// Production lifecycle is a separate static-archive member: frontend-only
// tools do not call it, while the host and session probe link real tracking.
#include "graphics_session.h"
#include "../track/s2a_track.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>

int dm_vk_restart_check(void);
int dm_vk_request_stop(void);
int dm_gl_request_stop(void);
int dm_nvn_request_stop(void);
void dm_nvn_begin_session(void);
int dm_gfx_retire_frontends(void);
void dm_gfx_retire_host_state(void);
void dm_gfx_begin_host_state(void);

static _Atomic int g_graphics_process_exit;
static pthread_mutex_t g_graphics_session_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_graphics_may_begin = 1;

void s2a_graphics_native_seal_process_exit(void) {
    pthread_mutex_lock(&g_graphics_session_mu);
    atomic_store(&g_graphics_process_exit, 1);
    pthread_mutex_unlock(&g_graphics_session_mu);
}

int s2a_graphics_native_restart_check(void) {
    return atomic_load(&g_graphics_process_exit) ? -ESHUTDOWN : dm_vk_restart_check();
}

static int graphics_native_request_stop(void) {
    int e = dm_nvn_request_stop(); if (e) return e;
    e = dm_vk_request_stop(); if (e) return e;
    return dm_gl_request_stop();
}

int s2a_graphics_native_request_stop(void) {
    pthread_mutex_lock(&g_graphics_session_mu);
    g_graphics_may_begin = 0;
    int error = graphics_native_request_stop();
    pthread_mutex_unlock(&g_graphics_session_mu);
    return error;
}

// Caller has joined every guest and completed managed GPU/service disposal.
// Keep this order: shared present/frontends, real tracking, host diagnostics.
static int graphics_native_retire(void) {
    if (atomic_load(&g_graphics_process_exit)) return -ESHUTDOWN;
    int error = dm_gfx_retire_frontends(); if (error) return error;
    error = s2a_track_reset_session(); if (error) return error < 0 ? error : -error;
    dm_gfx_retire_host_state();
    return 0;
}

int s2a_graphics_native_shutdown_session(void) {
    pthread_mutex_lock(&g_graphics_session_mu);
    int error = graphics_native_retire();
    if (!error) g_graphics_may_begin = 1;
    pthread_mutex_unlock(&g_graphics_session_mu);
    return error;
}

int s2a_graphics_native_begin_session(void) {
    pthread_mutex_lock(&g_graphics_session_mu);
    int error = atomic_load(&g_graphics_process_exit) ? -ESHUTDOWN : !g_graphics_may_begin ? -EBUSY : 0;
    if (!error) { s2a_track_bind_host(); dm_nvn_begin_session(); dm_gfx_begin_host_state(); g_graphics_may_begin = 0; }
    pthread_mutex_unlock(&g_graphics_session_mu);
    return error;
}

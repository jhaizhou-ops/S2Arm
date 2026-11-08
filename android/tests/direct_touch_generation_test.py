#!/usr/bin/env python3
"""Exercise production provider/adapter handoff with a real WSI lease and a fake GPU."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
def function(path, signature):
    source = (root / path).read_text()
    start = source.index(signature)
    brace = source.index('{', start)
    depth, pos = 1, brace + 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}')
        pos += 1
    return source[start:pos]

adapter = function('android/native/nvn/mtl_vk_adapter.c', 'int s2a_vk_adapter_attach_window_budget(')
provider = function('android/native/direct/provider_vk.c', 'static int take_and_attach_window_locked(')
preamble = r'''
#include "wsi_lease.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
typedef void ANativeWindow;
#define ANDROID_LOG_WARN 1
#define ANDROID_LOG_ERROR 2
#define ANDROID_LOG_INFO 3
#define TAG "test"
struct provider_context { int revoking, has_window; void *lease_window; uint64_t lease_generation; char window_error[192]; };
static struct { const void *lease_api; } g_context;
static struct { struct { uint64_t touch_generation; } swapchain; } g_session;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_ready = 1, attach_rc, lock_busy;
static int s2a_vk_adapter_ready(void) { return g_ready; }
static int adapter_lock_budget(int64_t budget) { (void)budget; if (lock_busy) return 1; return pthread_mutex_lock(&g_mu); }
static int nvn_vk_session_attach_window(void *session, ANativeWindow *window, char *why, size_t size) {
    (void)session; (void)window; (void)why; (void)size; return attach_rc;
}
static void set_window_error(struct provider_context *c, const char *s) { snprintf(c->window_error, sizeof c->window_error, "%s", s); }
static void clear_window_error(struct provider_context *c) { c->window_error[0] = 0; }
static int __android_log_print(int p, const char *tag, const char *fmt, ...) { (void)p; (void)tag; (void)fmt; return 0; }
'''
main = r'''
static int refs;
static void retain(void *w) { (void)w; refs++; }
static void release(void *w) { (void)w; refs--; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); return 1; } } while (0)
int main(void) {
    struct s2a_wsi_window_ops ops = { retain, release };
    s2a_wsi_lease *lease = s2a_wsi_create(91, &ops);
    struct s2a_wsi_api api; struct provider_context ctx = {0}; int w;
    CHECK(lease != NULL);
    s2a_wsi_api_fill(lease, &api); g_context.lease_api = &api;
    CHECK(s2a_wsi_offer(lease, &w) == 1);
    CHECK(s2a_wsi_offer(lease, &w) == 2);
    lock_busy = 1;
    CHECK(take_and_attach_window_locked(&ctx, 100) == 1);
    CHECK(!ctx.has_window && !g_session.swapchain.touch_generation && refs == 1);
    lock_busy = 0; attach_rc = -1;
    CHECK(take_and_attach_window_locked(&ctx, 100) == -1);
    CHECK(!ctx.has_window && !g_session.swapchain.touch_generation && refs == 1);
    attach_rc = 0;
    CHECK(take_and_attach_window_locked(&ctx, 100) == 0);
    CHECK(ctx.has_window && ctx.lease_generation == 2 && g_session.swapchain.touch_generation == 2 && refs == 2);
    api.release_window(lease, ctx.lease_window); api.released(lease, ctx.lease_generation);
    CHECK(s2a_wsi_revoke(lease, 10) == 0);
    s2a_wsi_destroy(lease); CHECK(refs == 0);
    puts("provider-to-adapter WSI generation handoff passed"); return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='direct-touch-generation-') as directory:
    d = Path(directory)
    (d / 'test.c').write_text(preamble + adapter + '\n' + provider + main)
    # Apple libc lacks this optional POSIX clock selector. This test never waits.
    (d / 'compat.h').write_text('#include <pthread.h>\n#ifdef __APPLE__\n#define pthread_condattr_setclock(a,b) (0)\n#endif\n')
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_POSIX_C_SOURCE=200809L',
                    '-include', str(d / 'compat.h'), '-I', str(root / 'android/native'),
                    str(d / 'test.c'), str(root / 'android/native/wsi_lease.c'),
                    '-pthread', '-o', str(d / 'test')], check=True)
    subprocess.run([str(d / 'test')], check=True)

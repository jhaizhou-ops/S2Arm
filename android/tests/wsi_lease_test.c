#include "wsi_lease.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static atomic_int retains, releases;
static void retain(void *w) { (void)w; atomic_fetch_add(&retains, 1); }
static void release(void *w) { (void)w; atomic_fetch_add(&releases, 1); }
static const struct s2a_wsi_window_ops ops = {retain, release};

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

struct revoke_call { s2a_wsi_lease *lease; int timeout_ms, rc; long long ms; };
static void *revoke_thread(void *p) {
    struct revoke_call *c = p;
    long long start = now_ms();
    c->rc = s2a_wsi_revoke(c->lease, c->timeout_ms);
    c->ms = now_ms() - start;
    return NULL;
}

// Stress: the UI thread offers / updates / revokes; the render thread follows like a presenter.
struct render { s2a_wsi_lease *lease; int frames, held; };
static void *render_thread(void *p) {
    struct render *r = p;
    struct s2a_wsi_state seen = {0}, cur;
    uint64_t holding = 0;
    void *window = NULL;
    for (;;) {
        s2a_wsi_wait(r->lease, &seen, 50);
        int busy = s2a_wsi_take(r->lease, &cur) == EBUSY;
        if (window && (busy || !cur.window || cur.generation != holding)) {   // drop the old generation first
            s2a_wsi_release_window(r->lease, window);
            window = NULL;
            s2a_wsi_released(r->lease, holding);
            holding = 0;
        }
        if (busy) s2a_wsi_take(r->lease, &cur);
        if (cur.window && !window) { window = cur.window; holding = cur.generation; r->held++; }
        else if (cur.window) s2a_wsi_release_window(r->lease, cur.window);   // same generation, new revision: keep one reference
        seen = cur;
        r->frames++;
        if (cur.stopping) break;
    }
    if (window) { s2a_wsi_release_window(r->lease, window); s2a_wsi_released(r->lease, holding); }
    return NULL;
}

int main(void) {
    int w1, w2;
    const int32_t insets[4] = {0, 80, 0, 40};
    s2a_wsi_lease *l = s2a_wsi_create(7, &ops);
    struct s2a_wsi_state s, seen;

    CHECK(s2a_wsi_refresh_hz(l) == 0);
    // Generation per window, revision per change of that window.
    CHECK(s2a_wsi_offer(l, &w1) == 1);
    CHECK(s2a_wsi_refresh_hz(l) == 0);
    s2a_wsi_take(l, &s);
    CHECK(s.window == &w1 && s.generation == 1 && s.revision == 0 && s.session == 7);
    s2a_wsi_update(l, 2400, 1080, 2, insets, 120.0f);
    CHECK(s2a_wsi_refresh_hz(l) == 120.0f);
    seen = s;
    CHECK(s2a_wsi_wait(l, &seen, 0) == 1);
    s2a_wsi_take(l, &s);
    CHECK(s.generation == 1 && s.revision == 1 && s.width == 2400 && s.transform == 2 && s.insets[1] == 80 && s.refresh_hz == 120.0f);
    s2a_wsi_release_window(l, s.window);   // the taker's second reference

    // Revoke waits for the render thread's release acknowledgement.
    struct revoke_call c = {l, 1000, -1, 0};
    pthread_t t;
    pthread_create(&t, NULL, revoke_thread, &c);
    usleep(60 * 1000);
    s2a_wsi_take(l, &s);
    CHECK(s.window == NULL && s.generation == 1);   // revoked: nothing more is handed out
    CHECK(s2a_wsi_refresh_hz(l) == 0);
    s2a_wsi_release_window(l, &w1);   // the render thread drops its first reference ...
    s2a_wsi_released(l, 1);   // ... and acknowledges
    pthread_join(t, NULL);
    CHECK(c.rc == 0 && c.ms >= 50 && c.ms < 1000);

    // A revoked generation stays revoked; the same pointer offered again is a new generation.
    s2a_wsi_update(l, 1080, 2400, 0, insets, 60.0f);
    s2a_wsi_take(l, &s);
    CHECK(s.window == NULL && s.width == 2400);
    CHECK(s2a_wsi_offer(l, &w1) == 2);
    s2a_wsi_take(l, &s);
    CHECK(s.window == &w1 && s.generation == 2 && s.width == 0);
    s2a_wsi_release_window(l, s.window);
    s2a_wsi_released(l, 2);

    // Revoking a generation the render thread never took returns at once.
    CHECK(s2a_wsi_offer(l, &w2) == 3);
    long long start = now_ms();
    CHECK(s2a_wsi_revoke(l, 1000) == 0 && now_ms() - start < 50);

    // A render thread that does not let go: the revoke times out (never reported as released).
    CHECK(s2a_wsi_offer(l, &w2) == 4);
    s2a_wsi_take(l, &s);
    start = now_ms();
    CHECK(s2a_wsi_revoke(l, 100) == ETIMEDOUT && now_ms() - start >= 90);
    s2a_wsi_release_window(l, s.window);
    s2a_wsi_released(l, 4);
    CHECK(s2a_wsi_revoke(l, 100) == 0);

    // Wait: timeout when nothing changed; foreground, wake and stop each wake it, also when they
    // happened between take and wait.
    s2a_wsi_take(l, &seen);
    start = now_ms();
    CHECK(s2a_wsi_wait(l, &seen, 50) == 0 && now_ms() - start >= 40);
    s2a_wsi_set_foreground(l, 1);
    CHECK(s2a_wsi_wait(l, &seen, 1000) == 1);
    s2a_wsi_take(l, &seen);
    s2a_wsi_wake(l);
    CHECK(s2a_wsi_wait(l, &seen, 1000) == 1);
    s2a_wsi_take(l, &seen);
    s2a_wsi_stop(l);
    CHECK(s2a_wsi_wait(l, &seen, -1) == 1);

    // Release before take: a newer window while the old one is held is EBUSY (no window handed
    // out) until the old generation is released; a revoke also waits for an older held one.
    CHECK(s2a_wsi_offer(l, &w1) == 5);
    CHECK(s2a_wsi_take(l, &s) == 0 && s.window == &w1);
    void *old = s.window;
    CHECK(s2a_wsi_offer(l, &w2) == 6);   // the shell skipped a revoke
    CHECK(s2a_wsi_take(l, &s) == EBUSY && s.window == NULL && s.generation == 6);
    start = now_ms();
    CHECK(s2a_wsi_revoke(l, 100) == ETIMEDOUT && now_ms() - start >= 90);   // generation 5 is still held
    s2a_wsi_release_window(l, old);
    s2a_wsi_released(l, 5);
    CHECK(s2a_wsi_take(l, &s) == 0 && s.window == NULL);   // 6 was revoked meanwhile
    CHECK(s2a_wsi_offer(l, &w2) == 7);
    CHECK(s2a_wsi_take(l, &s) == 0 && s.window == &w2);
    s2a_wsi_release_window(l, s.window);
    s2a_wsi_released(l, 7);

    // Contract edges and the binding surface.
    CHECK(s2a_wsi_revoke(l, -1) == EINVAL);
    CHECK(s2a_wsi_wait(l, NULL, 0) == -1);
    CHECK(s2a_wsi_create(1, NULL) == NULL);
    const struct s2a_wsi_window_ops half = {retain, NULL};
    CHECK(s2a_wsi_create(1, &half) == NULL);
    CHECK(s2a_wsi_abi_version() == S2A_WSI_ABI_VERSION);
    struct s2a_wsi_api api;
    s2a_wsi_api_fill(l, &api);
    CHECK(api.size == sizeof api && api.abi_version == S2A_WSI_ABI_VERSION && api.lease == l && api.take == s2a_wsi_take
          && api.wait == s2a_wsi_wait && api.released == s2a_wsi_released && api.release_window == s2a_wsi_release_window
          && api.wake == s2a_wsi_wake);
    s2a_wsi_destroy(l);
    CHECK(atomic_load(&retains) == atomic_load(&releases));

    // Peek (HostApi display): a copy without the window, holding nothing; the size outlives a revoke.
    l = s2a_wsi_create(9, &ops);
    s2a_wsi_peek(l, &s);
    CHECK(s.generation == 0 && s.window == NULL && s.width == 0);
    s2a_wsi_offer(l, &w1);
    s2a_wsi_update(l, 2712, 1220, 8, insets, 120.0f);
    int before = atomic_load(&retains);
    s2a_wsi_peek(l, &s);
    CHECK(s.window == NULL && s.generation == 1 && s.revision == 1 && s.width == 2712 && s.transform == 8);
    CHECK(atomic_load(&retains) == before);
    long long t0 = now_ms();
    CHECK(s2a_wsi_revoke(l, 1000) == 0 && now_ms() - t0 < 100);   // nothing held: no wait
    s2a_wsi_peek(l, &s);
    CHECK(s.window == NULL && s.width == 2712 && s.height == 1220 && s.refresh_hz == 120.0f);
    s2a_wsi_destroy(l);
    CHECK(atomic_load(&retains) == atomic_load(&releases));

    // Lifecycle as the shell set it, readable from any thread without the render thread polling
    // (the threaded renderer's stall clock): only real transitions count.
    l = s2a_wsi_create(9, &ops);
    uint64_t changes = 99;
    CHECK(s2a_wsi_lifecycle(l, &changes) == 0 && changes == 0);
    s2a_wsi_set_foreground(l, 1);
    CHECK(s2a_wsi_lifecycle(l, &changes) == 1 && changes == 1);
    s2a_wsi_set_foreground(l, 1);
    CHECK(s2a_wsi_lifecycle(l, &changes) == 1 && changes == 1);
    s2a_wsi_set_foreground(l, 0);
    s2a_wsi_set_foreground(l, 1);
    CHECK(s2a_wsi_lifecycle(l, &changes) == 1 && changes == 3);
    s2a_wsi_stop(l);
    s2a_wsi_stop(l);
    CHECK(s2a_wsi_lifecycle(l, &changes) == 0 && changes == 4 && s2a_wsi_lifecycle(l, NULL) == 0);
    s2a_wsi_destroy(l);

    // Stress: 300 surfaces offered, resized and destroyed while a render thread follows.
    l = s2a_wsi_create(8, &ops);
    struct render r = {l, 0, 0};
    pthread_create(&t, NULL, render_thread, &r);
    int late = 0;
    for (int i = 0; i < 300; i++) {
        s2a_wsi_offer(l, (i & 1) ? (void *)&w1 : (void *)&w2);   // addresses reused on purpose
        s2a_wsi_set_foreground(l, 1);
        for (int k = 0; k < 3; k++) s2a_wsi_update(l, 1000 + k, 500, 0, insets, 60.0f);
        usleep(1000);   // usually long enough for the render thread to hold the window when it is revoked
        if (s2a_wsi_revoke(l, 1000)) late++;
        s2a_wsi_set_foreground(l, 0);
    }
    s2a_wsi_stop(l);
    pthread_join(t, NULL);
    s2a_wsi_destroy(l);
    CHECK(late == 0 && r.held > 150);   // most revokes had to wait for a real release
    CHECK(atomic_load(&retains) == atomic_load(&releases));
    printf("wsi lease: %d retains / %d releases; stress: %d of 300 windows held by the render thread when revoked or replaced, "
           "%d render wakeups, %d late revokes\n", atomic_load(&retains), atomic_load(&releases), r.held, r.frames, late);
    return failures ? 1 : 0;
}

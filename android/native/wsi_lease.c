#include "wsi_lease.h"
#include "backing_wait.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct s2a_wsi_lease {
    pthread_mutex_t mutex;
    pthread_cond_t changed;    // the render thread waits here
    pthread_cond_t released;   // s2a_wsi_revoke waits here
    struct s2a_wsi_window_ops ops;
    struct s2a_wsi_state state;   // state.window is the lease's own reference
    uint64_t held;                // generation the render thread holds (0: none)
    s2a_backing_wait backing;     // sole backing deadline authority, protected by mutex
    uint64_t lifecycle_changes;   // foreground / stopping transitions (s2a_wsi_lifecycle)
};

static void deadline(struct timespec *ts, int ms) {
    clock_gettime(CLOCK_MONOTONIC, ts);
    ts->tv_sec += ms / 1000;
    ts->tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) { ts->tv_sec++; ts->tv_nsec -= 1000000000L; }
}

uint32_t s2a_wsi_abi_version(void) { return S2A_WSI_ABI_VERSION; }

s2a_wsi_lease *s2a_wsi_create(uint64_t session, const struct s2a_wsi_window_ops *ops) {
    if (!ops || !ops->retain || !ops->release) return NULL;
    s2a_wsi_lease *l = calloc(1, sizeof *l);
    if (!l) return NULL;
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);   // deadlines immune to wall-clock changes
    pthread_mutex_init(&l->mutex, NULL);
    pthread_cond_init(&l->changed, &attr);
    pthread_cond_init(&l->released, &attr);
    pthread_condattr_destroy(&attr);
    l->ops = *ops;
    l->state.session = session;
    return l;
}

void s2a_wsi_destroy(s2a_wsi_lease *l) {
    if (!l) return;
    if (l->state.window) l->ops.release(l->state.window);
    pthread_cond_destroy(&l->released);
    pthread_cond_destroy(&l->changed);
    pthread_mutex_destroy(&l->mutex);
    free(l);
}

uint64_t s2a_wsi_offer(s2a_wsi_lease *l, void *window) {
    if (window) l->ops.retain(window);
    pthread_mutex_lock(&l->mutex);
    void *old = l->state.window;   // only when the shell skipped a revoke
    struct s2a_wsi_state *s = &l->state;
    s->window = window;
    s->generation++;
    s->revision = 0;
    s->width = s->height = 0;
    s->transform = 0;
    memset(s->insets, 0, sizeof s->insets);
    s->refresh_hz = 0;
    uint64_t generation = s->generation;
    pthread_cond_broadcast(&l->changed);
    pthread_mutex_unlock(&l->mutex);
    if (old) l->ops.release(old);
    return generation;
}

void s2a_wsi_update(s2a_wsi_lease *l, int32_t width, int32_t height, uint32_t transform,
                    const int32_t insets[4], float refresh_hz) {
    pthread_mutex_lock(&l->mutex);
    struct s2a_wsi_state *s = &l->state;
    if (s->window) {   // a revoked generation stays revoked
        s->width = width;
        s->height = height;
        s->transform = transform;
        if (insets) memcpy(s->insets, insets, sizeof s->insets);
        s->refresh_hz = refresh_hz;
        s->revision++;
        pthread_cond_broadcast(&l->changed);
    }
    pthread_mutex_unlock(&l->mutex);
}

void s2a_wsi_set_foreground(s2a_wsi_lease *l, int foreground) {
    pthread_mutex_lock(&l->mutex);
    if (l->state.foreground != !!foreground) {
        if (foreground && !l->state.stopping) s2a_backing_resumed(&l->backing);
        l->state.foreground = !!foreground;
        l->lifecycle_changes++;
        pthread_cond_broadcast(&l->changed);
    }
    pthread_mutex_unlock(&l->mutex);
}

int s2a_wsi_revoke(s2a_wsi_lease *l, int timeout_ms) {
    if (timeout_ms < 0) return EINVAL;
    struct timespec until;
    deadline(&until, timeout_ms);
    pthread_mutex_lock(&l->mutex);
    uint64_t generation = l->state.generation;
    void *old = l->state.window;
    l->state.window = NULL;   // take() hands out nothing more of this generation
    if (old) {
        l->state.revision++;   // the render thread sees the window gone
        pthread_cond_broadcast(&l->changed);
    }
    int rc = 0;
    // Also an older generation still held (the shell offered again without revoking).
    while (l->held && l->held <= generation)
        if (pthread_cond_timedwait(&l->released, &l->mutex, &until) == ETIMEDOUT) {
            rc = l->held && l->held <= generation ? ETIMEDOUT : 0;
            break;
        }
    pthread_mutex_unlock(&l->mutex);
    if (old) l->ops.release(old);
    return rc;
}

void s2a_wsi_stop(s2a_wsi_lease *l) {
    pthread_mutex_lock(&l->mutex);
    if (!l->state.stopping) l->lifecycle_changes++;
    l->state.stopping = 1;
    pthread_cond_broadcast(&l->changed);
    pthread_mutex_unlock(&l->mutex);
}

static int same(const struct s2a_wsi_state *a, const struct s2a_wsi_state *b) {
    return a->generation == b->generation && a->revision == b->revision && a->foreground == b->foreground
        && a->stopping == b->stopping && a->wake_seq == b->wake_seq;
}

int s2a_wsi_wait(s2a_wsi_lease *l, const struct s2a_wsi_state *seen, int timeout_ms) {
    if (!seen) return -1;
    struct timespec until;
    if (timeout_ms >= 0) deadline(&until, timeout_ms);
    pthread_mutex_lock(&l->mutex);
    int woke = 1;
    while (same(&l->state, seen)) {
        if (timeout_ms < 0) pthread_cond_wait(&l->changed, &l->mutex);
        else if (pthread_cond_timedwait(&l->changed, &l->mutex, &until) == ETIMEDOUT) {
            woke = !same(&l->state, seen);
            break;
        }
    }
    pthread_mutex_unlock(&l->mutex);
    return woke;
}

int s2a_wsi_take(s2a_wsi_lease *l, struct s2a_wsi_state *out) {
    int rc = 0;
    pthread_mutex_lock(&l->mutex);
    *out = l->state;
    if (out->window && l->held && l->held != out->generation) {
        out->window = NULL;   // release the older generation first
        rc = EBUSY;
    } else if (out->window) {
        l->ops.retain(out->window);
        l->held = out->generation;
    }
    pthread_mutex_unlock(&l->mutex);
    return rc;
}

float s2a_wsi_refresh_hz(s2a_wsi_lease *l) {
    if (!l) return 0;
    pthread_mutex_lock(&l->mutex);
    float hz = l->state.window && !l->state.stopping ? l->state.refresh_hz : 0;
    pthread_mutex_unlock(&l->mutex);
    return hz > 0 ? hz : 0;
}

void s2a_wsi_peek(s2a_wsi_lease *l, struct s2a_wsi_state *out) {
    pthread_mutex_lock(&l->mutex);
    *out = l->state;
    pthread_mutex_unlock(&l->mutex);
    out->window = NULL;
}

int s2a_wsi_lifecycle(s2a_wsi_lease *l, uint64_t *changes) {
    pthread_mutex_lock(&l->mutex);
    int foreground = l->state.foreground && !l->state.stopping;
    if (changes) *changes = l->lifecycle_changes;
    pthread_mutex_unlock(&l->mutex);
    return foreground;
}

void s2a_wsi_release_window(s2a_wsi_lease *l, void *window) {
    if (window) l->ops.release(window);
}

void s2a_wsi_released(s2a_wsi_lease *l, uint64_t generation) {
    pthread_mutex_lock(&l->mutex);
    if (l->held == generation) l->held = 0;
    pthread_cond_broadcast(&l->released);
    pthread_mutex_unlock(&l->mutex);
}

void s2a_wsi_wake(s2a_wsi_lease *l) {
    pthread_mutex_lock(&l->mutex);
    l->state.wake_seq++;
    pthread_cond_broadcast(&l->changed);
    pthread_mutex_unlock(&l->mutex);
}

void s2a_wsi_api_fill(s2a_wsi_lease *l, struct s2a_wsi_api *out) {
    out->size = sizeof *out;
    out->abi_version = S2A_WSI_ABI_VERSION;
    out->lease = l;
    out->wait = s2a_wsi_wait;
    out->take = s2a_wsi_take;
    out->release_window = s2a_wsi_release_window;
    out->released = s2a_wsi_released;
    out->wake = s2a_wsi_wake;
}

// Host adapters hold the lease lifetime lock before entering these short sections.
uint64_t s2a_wsi_backing_progress(s2a_wsi_lease *l, unsigned writer, uint64_t owner, int advance) {
    pthread_mutex_lock(&l->mutex);
    uint64_t result = s2a_backing_publish(&l->backing, writer, owner, advance, l->state.foreground && !l->state.stopping);
    pthread_mutex_unlock(&l->mutex);
    return result;
}
int s2a_wsi_backing_decision(s2a_wsi_lease *l, uint64_t owner) {
    pthread_mutex_lock(&l->mutex);
    int result = s2a_backing_decision(&l->backing, owner, l->state.foreground && !l->state.stopping);
    pthread_mutex_unlock(&l->mutex);
    return result;
}
int s2a_wsi_backing_admission(s2a_wsi_lease *l, unsigned writer, uint64_t *deadline) {
    pthread_mutex_lock(&l->mutex);
    int found = writer && writer == l->backing.writer && l->backing.owner;
    if (found) *deadline = s2a_backing_deadline(&l->backing, l->state.foreground && !l->state.stopping, S2A_BACKING_ADMISSION_MARGIN_MS);
    pthread_mutex_unlock(&l->mutex);
    return found;
}

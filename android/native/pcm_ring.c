#include "pcm_ring.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

int s2a_pcm_ring_init(struct s2a_pcm_ring *r, int format, uint32_t channels, uint32_t capacity_frames) {
    memset(r, 0, sizeof *r);
    uint32_t sample = format == S2A_PCM_I16 ? 2 : format == S2A_PCM_F32 ? 4 : 0;
    if (!sample || !channels || channels > 8 || !capacity_frames || capacity_frames > (1u << 24)) return EINVAL;
    uint64_t want = (uint64_t)capacity_frames * sample * channels, cap = 64;
    while (cap < want) cap <<= 1;
    r->data = calloc(1, (size_t)cap);
    if (!r->data) return ENOMEM;
    r->capacity = (uint32_t)cap;
    r->frame_bytes = sample * channels;
    r->format = format;
    s2a_pcm_ring_set_volume(r, 1.0f);
    return 0;
}

void s2a_pcm_ring_free(struct s2a_pcm_ring *r) {
    free(r->data);
    r->data = NULL;
}

uint32_t s2a_pcm_ring_space(const struct s2a_pcm_ring *r) {
    uint64_t used = atomic_load_explicit(&r->written, memory_order_relaxed)
        - atomic_load_explicit(&r->read, memory_order_acquire);
    uint32_t space = r->capacity - (uint32_t)used;
    return space / r->frame_bytes * r->frame_bytes;
}

uint32_t s2a_pcm_ring_write(struct s2a_pcm_ring *r, const void *src, uint32_t bytes) {
    uint32_t n = bytes / r->frame_bytes * r->frame_bytes, space = s2a_pcm_ring_space(r);
    if (n > space) n = space;
    uint64_t w = atomic_load_explicit(&r->written, memory_order_relaxed);
    uint32_t at = (uint32_t)(w & (r->capacity - 1)), first = r->capacity - at < n ? r->capacity - at : n;
    memcpy(r->data + at, src, first);
    memcpy(r->data, (const uint8_t *)src + first, n - first);
    atomic_store_explicit(&r->written, w + n, memory_order_release);
    return n;
}

void s2a_pcm_ring_set_volume(struct s2a_pcm_ring *r, float volume) {
    if (!(volume >= 0)) volume = 0;   // also NaN
    if (volume > 1) volume = 1;
    uint32_t bits;
    memcpy(&bits, &volume, sizeof bits);
    atomic_store_explicit(&r->volume_bits, bits, memory_order_relaxed);
}

static void scale(int format, uint8_t *p, uint32_t bytes, float volume) {
    if (volume >= 0.999f) return;
    if (format == S2A_PCM_I16) {
        int16_t *s = (int16_t *)p;
        for (uint32_t i = 0; i < bytes / 2; i++) s[i] = (int16_t)(s[i] * volume);
    } else {
        float *f = (float *)p;
        for (uint32_t i = 0; i < bytes / 4; i++) f[i] *= volume;
    }
}

void s2a_pcm_ring_read(struct s2a_pcm_ring *r, void *dst, uint32_t frames) {
    uint8_t *out = dst;
    uint32_t want = frames * r->frame_bytes;
    uint64_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
    uint64_t avail = atomic_load_explicit(&r->written, memory_order_acquire) - rd;
    uint32_t n = avail < want ? (uint32_t)avail : want;
    uint32_t at = (uint32_t)(rd & (r->capacity - 1)), first = r->capacity - at < n ? r->capacity - at : n;
    memcpy(out, r->data + at, first);
    memcpy(out + first, r->data, n - first);
    atomic_store_explicit(&r->read, rd + n, memory_order_release);
    uint32_t bits = atomic_load_explicit(&r->volume_bits, memory_order_relaxed);
    float volume;
    memcpy(&volume, &bits, sizeof volume);
    scale(r->format, out, n, volume);
    memset(out + n, 0, want - n);   // zero bytes are silence for both formats
    atomic_fetch_add_explicit(&r->frames_out, n / r->frame_bytes, memory_order_relaxed);
    if (n < want) atomic_fetch_add_explicit(&r->frames_padded, (want - n) / r->frame_bytes, memory_order_relaxed);
}

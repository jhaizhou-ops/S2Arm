#pragma once
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Single-producer / single-consumer PCM byte ring between the C# audio session (writer,
// a managed thread that GC can stall) and the AAudio data callback (reader, a real-time
// thread that must never wait or run managed code). The reader copies whole frames,
// applies the volume and pads with silence only when the ring is empty.

enum s2a_pcm_format { S2A_PCM_I16 = 1, S2A_PCM_F32 = 2 };

struct s2a_pcm_ring {
    uint8_t *data;
    uint32_t capacity;                 // bytes, a power of two
    uint32_t frame_bytes;
    int format;
    _Atomic uint64_t written, read;    // byte positions, only ever growing
    _Atomic uint64_t frames_out;       // frames taken from the ring (queued samples, not padding)
    _Atomic uint64_t frames_padded;    // silent frames the reader had to make up
    _Atomic uint32_t volume_bits;      // float, 1.0 = unchanged
};

// capacity_frames is rounded up so the byte size is a power of two. Returns 0 or errno.
int s2a_pcm_ring_init(struct s2a_pcm_ring *r, int format, uint32_t channels, uint32_t capacity_frames);
void s2a_pcm_ring_free(struct s2a_pcm_ring *r);

// Writer side. Bytes of whole frames that fit now, and a copy of up to that many.
uint32_t s2a_pcm_ring_space(const struct s2a_pcm_ring *r);
uint32_t s2a_pcm_ring_write(struct s2a_pcm_ring *r, const void *src, uint32_t bytes);
void s2a_pcm_ring_set_volume(struct s2a_pcm_ring *r, float volume);

// Reader side: fills exactly `frames` frames into dst.
void s2a_pcm_ring_read(struct s2a_pcm_ring *r, void *dst, uint32_t frames);

#ifdef __cplusplus
}
#endif

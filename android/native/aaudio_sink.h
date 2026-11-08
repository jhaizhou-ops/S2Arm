#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// AAudio output for the C# audio backend (cs/audio). The data callback runs in C on
// AAudio's real-time thread and only reads the PCM ring (pcm_ring.h); the C# session
// writes the ring from a managed thread, so a GC pause delays bookkeeping, not playback.
// All functions except the callback are for that one managed thread, except
// s2a_aaudio_wake, which any thread may call. The managed thread sleeps in
// s2a_aaudio_wait and is woken only when there is work: the callback reached the frame
// position armed with s2a_aaudio_notify_at (a queued buffer finished playing), the
// stream disconnected, or s2a_aaudio_wake. Nothing armed (paused, nothing queued) means
// no wakeups beyond the caller's timeout.

typedef struct s2a_aaudio s2a_aaudio;

struct s2a_aaudio_stats {
    uint64_t frames_out;      // queued frames handed to AAudio
    uint64_t frames_padded;   // silent frames made up while the ring was empty
    uint32_t xruns;           // AAudio's own underrun count
    int32_t burst_frames, buffer_frames, sample_rate;
    int32_t sharing;          // AAUDIO_SHARING_MODE_* in use
    uint32_t reopens;         // after a disconnect (route change, headset)
};

// format: S2A_PCM_I16 or S2A_PCM_F32 (pcm_ring.h). Returns 0 or an AAudio error (< 0).
int s2a_aaudio_open(int format, int sample_rate, int channels, int ring_ms, s2a_aaudio **out);
int s2a_aaudio_start(s2a_aaudio *a);
int s2a_aaudio_pause(s2a_aaudio *a);
// Reopens a disconnected stream (keeping the ring) and restarts it if it was running.
void s2a_aaudio_service(s2a_aaudio *a);
// Wake the waiter once frames_out reaches `frames` (UINT64_MAX disarms).
void s2a_aaudio_notify_at(s2a_aaudio *a, uint64_t frames);
// Sleep until woken (returns 1) or timeout_ms passes (returns 0).
int s2a_aaudio_wait(s2a_aaudio *a, int timeout_ms);
void s2a_aaudio_wake(s2a_aaudio *a);
uint32_t s2a_aaudio_space(s2a_aaudio *a);
uint32_t s2a_aaudio_write(s2a_aaudio *a, const void *pcm, uint32_t bytes);
void s2a_aaudio_set_volume(s2a_aaudio *a, float volume);
void s2a_aaudio_stats(s2a_aaudio *a, struct s2a_aaudio_stats *out);
void s2a_aaudio_close(s2a_aaudio *a);

#ifdef __cplusplus
}
#endif

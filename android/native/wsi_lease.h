#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Window lease between the platform shell (SurfaceHolder callbacks, Activity lifecycle) and the
// one render thread that owns the WSI objects (implementation plan §7.3). The shell offers,
// updates and revokes; the render thread takes the latest state and acknowledges each release.
//
// Identity is {session, generation}: every new native window is a new generation, and a size,
// transform, inset or refresh change of that window is a new revision of the same generation.
// Window pointers are never compared: Android may hand back a new ANativeWindow at the address
// of a freed one. A revoked generation stays dead; a late update cannot bring it back.
//
// Shell calls never wait for the render thread, except s2a_wsi_revoke, which waits for the
// release acknowledgement with a deadline (surfaceDestroyed must not return while the window is
// in use). Missing the deadline is reported, never treated as released: the caller ends the
// process (§7.3 DetachTimeout). Plain C and pthreads, so it is shared by the diagnostic
// presenter and, through the same calls, the C# Vulkan backend.

// Bumped when a function or struct below changes in a way a binding (the C# backend) would see.
#define S2A_WSI_ABI_VERSION 1

typedef struct s2a_wsi_lease s2a_wsi_lease;

// How the lease keeps a native window alive (ANativeWindow_acquire / _release on Android).
struct s2a_wsi_window_ops {
    void (*retain)(void *window);
    void (*release)(void *window);
};

struct s2a_wsi_state {
    uint64_t session;
    uint64_t generation;     // 0: no window offered yet
    uint64_t revision;       // changes of this generation (0 = as offered)
    void *window;            // retained for the caller of s2a_wsi_take; NULL when none or revoked
    int32_t width, height;   // buffer size in pixels (0 until the first update)
    uint32_t transform;      // current display transform (VkSurfaceTransformFlagBitsKHR)
    int32_t insets[4];       // left, top, right, bottom, in pixels
    float refresh_hz;
    int foreground;          // 0: stop acquiring / presenting (§7.3 Foreground false)
    int stopping;            // the render thread should tear down and exit
    uint32_t wake_seq;       // counts s2a_wsi_wake, so a wake between take and wait is not lost
};
// Fixed layout for bindings (C# [StructLayout(Sequential)] mirrors it): checked here for LP64.
#if UINTPTR_MAX == UINT64_MAX
#ifdef __cplusplus
#define S2A_WSI_ASSERT static_assert
#else
#define S2A_WSI_ASSERT _Static_assert
#endif
S2A_WSI_ASSERT(offsetof(struct s2a_wsi_state, window) == 24 && offsetof(struct s2a_wsi_state, insets) == 44
               && offsetof(struct s2a_wsi_state, wake_seq) == 72 && sizeof(struct s2a_wsi_state) == 80,
               "s2a_wsi_state layout changed: bump S2A_WSI_ABI_VERSION and the bindings");
#undef S2A_WSI_ASSERT
#endif

uint32_t s2a_wsi_abi_version(void);

// NULL when ops or either callback is missing (or out of memory).
s2a_wsi_lease *s2a_wsi_create(uint64_t session, const struct s2a_wsi_window_ops *ops);
// After the render thread has exited. Releases the window the lease still holds.
void s2a_wsi_destroy(s2a_wsi_lease *lease);

// --- Shell side (UI thread) ---

// surfaceCreated: a new generation for this window (retained by the lease). Returns it.
uint64_t s2a_wsi_offer(s2a_wsi_lease *lease, void *window);
// surfaceChanged / configuration: a new revision of the current generation; ignored when
// there is none (never offered, or revoked).
void s2a_wsi_update(s2a_wsi_lease *lease, int32_t width, int32_t height, uint32_t transform,
                    const int32_t insets[4], float refresh_hz);
void s2a_wsi_set_foreground(s2a_wsi_lease *lease, int foreground);
// surfaceDestroyed: the current generation ends now. Returns 0 once the render thread holds no
// generation up to it (at once if it never took one), or ETIMEDOUT after timeout_ms, when it
// still may. timeout_ms < 0 is EINVAL and revokes nothing: a revoke always has a deadline.
int s2a_wsi_revoke(s2a_wsi_lease *lease, int timeout_ms);
// Tells the render thread to tear down and exit (it sees stopping); does not wait.
void s2a_wsi_stop(s2a_wsi_lease *lease);
// A copy of the current state for readers that do not render (the HostApi display table):
// out->window is always NULL, nothing is retained and no generation becomes held, so it never
// delays a revoke. After a revoke the last size, transform and refresh rate stay readable.
void s2a_wsi_peek(s2a_wsi_lease *lease, struct s2a_wsi_state *out);
// Current published display rate; zero without a live window or a known rate.
float s2a_wsi_refresh_hz(s2a_wsi_lease *lease);
// The shell's lifecycle as the shell set it, for any thread (it does not depend on the render
// thread polling): 1 while foreground and not stopping, else 0. *changes (when non-NULL) counts
// foreground / stopping transitions, so a reader can tell that the lifecycle moved in between.
int s2a_wsi_lifecycle(s2a_wsi_lease *lease, uint64_t *changes);

// Native backing authority; no time or lifecycle state is exported to managed code.
// A closed publication remains available to same-epoch admission until a new owner.
uint64_t s2a_wsi_backing_progress(s2a_wsi_lease *, unsigned writer, uint64_t owner, int advance);
int s2a_wsi_backing_decision(s2a_wsi_lease *, uint64_t owner);
int s2a_wsi_backing_admission(s2a_wsi_lease *, unsigned writer, uint64_t *deadline);

// --- Render thread side ---

// Sleeps until the state differs from `seen` (generation, revision, foreground, stopping or
// wake_seq, as returned by the last s2a_wsi_take) or timeout_ms passes (< 0: no limit).
// Returns 1 when something changed, 0 on timeout, -1 when seen is NULL.
int s2a_wsi_wait(s2a_wsi_lease *lease, const struct s2a_wsi_state *seen, int timeout_ms);
// The current state. A non-NULL window is retained for the caller (release it with
// s2a_wsi_release_window), who now holds this generation until s2a_wsi_released. Returns 0, or
// EBUSY while the caller still holds an older generation: then out->window is NULL and the
// caller releases that generation (s2a_wsi_released) before taking again.
int s2a_wsi_take(s2a_wsi_lease *lease, struct s2a_wsi_state *out);
// Drops one window reference returned by s2a_wsi_take (through the lease's ops).
void s2a_wsi_release_window(s2a_wsi_lease *lease, void *window);
// The render thread no longer uses anything of `generation` (swapchain, surface, window ref).
void s2a_wsi_released(s2a_wsi_lease *lease, uint64_t generation);
// Wakes s2a_wsi_wait without a state change (the backend's own control requests).
void s2a_wsi_wake(s2a_wsi_lease *lease);

// The render-thread side as a function table, for a backend that must not link platform
// symbols (the C# Vulkan backend gets it from the host): any platform can fill it with its own
// implementation. Check size and abi_version before use.
struct s2a_wsi_api {
    uint32_t size;          // sizeof(struct s2a_wsi_api)
    uint32_t abi_version;   // S2A_WSI_ABI_VERSION
    s2a_wsi_lease *lease;
    int (*wait)(s2a_wsi_lease *, const struct s2a_wsi_state *, int);
    int (*take)(s2a_wsi_lease *, struct s2a_wsi_state *);
    void (*release_window)(s2a_wsi_lease *, void *);
    void (*released)(s2a_wsi_lease *, uint64_t);
    void (*wake)(s2a_wsi_lease *);
};
void s2a_wsi_api_fill(s2a_wsi_lease *lease, struct s2a_wsi_api *out);

#ifdef __cplusplus
}
#endif

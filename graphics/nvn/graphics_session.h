#pragma once

// Process-local graphics lifecycle. Returns 0 or negative errno.
// These APIs do not prove guest quiescence: the session coordinator owns that
// proof and must select one shutdown path before calling them.
#ifdef __cplusplus
extern "C" {
#endif

// Preflight before stopping guest code (guest allocation callbacks still work).
int s2a_graphics_native_restart_check(void);

// Stop accepting work and wake frontend/presentation waits. Retains resources
// and guest-address references; this is safe before guest threads have joined.
int s2a_graphics_native_request_stop(void);

// Destructive retirement. Caller must have joined EVERY guest thread, stopped
// service/CPU producers, and completed managed GPU/GAL disposal if present.
// RequestStop alone, SVC park, freeze and an empty managed Host are insufficient.
// Drains native GPU/compiler/present/archive work before clearing owners and
// tracking tables. Failure preserves a stopped session and forbids resuming it.
int s2a_graphics_native_shutdown_session(void);

// First boot or after successful complete retirement; never after ordinary exit.
int s2a_graphics_native_begin_session(void);

// Ordinary process-exit path: keep reachable owners until the process ends.
// Irreversible in this process; subsequent retirement/begin/preflight fail.
void s2a_graphics_native_seal_process_exit(void);

#ifdef __cplusplus
}
#endif

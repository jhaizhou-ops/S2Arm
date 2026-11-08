#pragma once
#include <signal.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Signals on guest threads. Rewritten blocks stash registers below sp (down to
// sp - 112), relying on Apple's 128-byte arm64 red zone; Linux has none, so a
// signal frame built on the guest stack overwrites them. Every handler that can
// run on a guest thread must use SA_ONSTACK, and every guest thread needs its own
// alternate stack (runtime/src/crash.c already does both on Apple: 256 KiB).

#define S2A_ALTSTACK_SIZE (256u << 10)

// Guest thread entry: installs a 256 KiB alternate stack with a guard page below
// it, replacing bionic's small per-thread one. Idempotent. Not for ART threads.
int s2a_android_altstack_init(void);
// Guest thread exit: disables and frees the stack installed above.
void s2a_android_altstack_free(void);

// sigaction with SA_SIGINFO | SA_ONSTACK always set.
int s2a_android_sigaction(int sig, void (*fn)(int, siginfo_t *, void *), struct sigaction *old);

// Guest thread entry, after the alternate stack: asks to block every signal
// whose installed handler lacks SA_ONSTACK, so process-directed ones go to
// another thread. Never asks for fault signals (their handlers must use
// SA_ONSTACK instead) or bionic signals whose sender waits for every thread.
// Bionic refuses to block any of its reserved RT signals __SIGRTMIN + 1..8
// (filter_reserved_signals in sigprocmask64), so on Android the handlers found
// without SA_ONSTACK (34, 36, 38 on Android 15) stay deliverable: this cannot
// cover them. Reads the mask back; returns how many are really blocked (or an
// errno < 0) and lists in `kept` the requested ones libc left unblocked.
int s2a_android_guest_sigmask(char *kept, size_t n);

// Call before a runtime that installs its own handlers first runs. .NET NativeAOT
// hijacks threads for GC with SIGRTMIN (41 on Android 15), installed with
// SA_RESTART | SA_SIGINFO and SA_ONSTACK only if the previous handler had it
// (dotnet/runtime release/10.0 nativeaot/Runtime/unix/UnixSignals.cpp). Installs an
// async-signal-safe no-op with SA_ONSTACK there if nothing is installed, so the
// runtime inherits the flag; .NET chains to it after its own work. Returns 0 or errno.
int s2a_android_runtime_signals_prepare(void);

// Writes signal numbers whose installed handler lacks SA_ONSTACK ("none" if all
// have it); returns their count.
int s2a_android_signal_audit(char *out, size_t n);

// Every signal with a handler, for platform/plat.h (#37): which signals the process's
// runtimes (ART's sigchain, bionic, .NET) already hold. Two views per signal: the kernel's
// installed handler (raw rt_sigaction, past sigchain's interposed sigaction) and what
// libc's sigaction reports to the app; each named by its library (dladdr), plus SA_ONSTACK.
// Returns the number of signals listed.
int s2a_android_signal_census(char *out, size_t n);

#if defined(__aarch64__)
// Whether a fault handler can tell a write from a read: one write and one read fault on a
// protected page, ESR taken from the signal frame's esr_context (arm64 Linux), WnR = bit 6.
// Returns 0 when both frames carried an ESR and WnR was 1 for the write and 0 for the read.
int s2a_android_fault_esr_probe(char *report, size_t n);
#endif

#if defined(__ANDROID__) && defined(__aarch64__)
// On a fresh thread: fills the 112 bytes below sp, takes a signal and counts the
// 14 words that survive, (a) without SA_ONSTACK, (b) with SA_ONSTACK and the
// guest alternate stack, (c) a write-protect fault forwarded by ART's sigchain.
// Returns 0 when (b) and (c) keep all words and their handlers ran on the stack.
int s2a_android_redzone_check(char *report, size_t n);
#endif

#ifdef __cplusplus
}
#endif

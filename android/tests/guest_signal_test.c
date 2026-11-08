#include "guest_signal.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static volatile uintptr_t handler_sp;
static void on_usr2(int sig, siginfo_t *si, void *uc) {
    (void)sig; (void)si; (void)uc;
    volatile int here = 0;
    handler_sp = (uintptr_t)&here;
}

int main(void) {
    stack_t cur;
    CHECK(s2a_android_altstack_init() == 0 && s2a_android_altstack_init() == 0);
    CHECK(sigaltstack(NULL, &cur) == 0 && !(cur.ss_flags & SS_DISABLE) && cur.ss_size == S2A_ALTSTACK_SIZE);

    // A handler installed through the helper runs on the guest alternate stack.
    struct sigaction old;
    CHECK(s2a_android_sigaction(SIGUSR2, on_usr2, &old) == 0);
    raise(SIGUSR2);
    CHECK(handler_sp >= (uintptr_t)cur.ss_sp && handler_sp < (uintptr_t)cur.ss_sp + cur.ss_size);

    // The audit names a handler without SA_ONSTACK and stops naming it once fixed.
    char list[256], want[16];
    struct sigaction plain;
    memset(&plain, 0, sizeof plain);
    plain.sa_sigaction = on_usr2; plain.sa_flags = SA_SIGINFO; sigemptyset(&plain.sa_mask);
    CHECK(sigaction(SIGUSR1, &plain, NULL) == 0);
    snprintf(want, sizeof want, "%d", SIGUSR1);
    CHECK(s2a_android_signal_audit(list, sizeof list) >= 1 && strstr(list, want));
    CHECK(s2a_android_sigaction(SIGUSR1, on_usr2, NULL) == 0);
    s2a_android_signal_audit(list, sizeof list);
    CHECK(!strstr(list, want));

    // The census lists both handlers with their owner (this test binary) and SA_ONSTACK; signals
    // nobody holds (SIGURG here) are not listed.
    char census[2048];
    CHECK(s2a_android_signal_census(census, sizeof census) >= 2);
    CHECK(strstr(census, "12 USR2 guest_signal_test onstack") && strstr(census, "10 USR1 guest_signal_test onstack"));
    CHECK(!strstr(census, "23 URG"));

    // Guest entry blocks handlers without SA_ONSTACK, but never a fault signal.
    struct sigaction old_segv;
    struct sigaction old_rt8;
    CHECK(sigaction(SIGUSR1, &plain, NULL) == 0 && sigaction(SIGSEGV, &plain, &old_segv) == 0);
    CHECK(sigaction(32 + 8, &plain, &old_rt8) == 0);   // bionic run-on-all-threads number
    char kept[64];
    CHECK(s2a_android_guest_sigmask(kept, sizeof kept) >= 1 && !strstr(kept, want));   // glibc blocks what is asked
    sigset_t mask;
    CHECK(pthread_sigmask(SIG_BLOCK, NULL, &mask) == 0);
    CHECK(sigismember(&mask, SIGUSR1) == 1 && sigismember(&mask, SIGUSR2) == 0 && sigismember(&mask, SIGSEGV) == 0);
    CHECK(sigismember(&mask, 32 + 8) == 0);
    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(32 + 8, &old_rt8, NULL);
    sigprocmask(SIG_UNBLOCK, &mask, NULL);

    // Without SA_ONSTACK the handler runs on the thread's own stack (the hazard).
    CHECK(sigaction(SIGUSR2, &plain, NULL) == 0);
    handler_sp = 0;
    raise(SIGUSR2);
    CHECK(handler_sp && !(handler_sp >= (uintptr_t)cur.ss_sp && handler_sp < (uintptr_t)cur.ss_sp + cur.ss_size));

    // A runtime that copies SA_ONSTACK from the previous handler (as .NET's
    // AddSignalHandler does) keeps it once the host prepared SIGRTMIN first.
    // exec preserves ignored dispositions: a test runner/container may inherit
    // SIG_IGN here. Establish this case's default-handler precondition explicitly.
    struct sigaction inherited_rt, default_rt, prev, mine, rt;
    CHECK(sigaction(SIGRTMIN, NULL, &inherited_rt) == 0);
    memset(&default_rt, 0, sizeof default_rt);
    default_rt.sa_handler = SIG_DFL;
    sigemptyset(&default_rt.sa_mask);
    CHECK(sigaction(SIGRTMIN, &default_rt, NULL) == 0);
    CHECK(s2a_android_runtime_signals_prepare() == 0 && sigaction(SIGRTMIN, NULL, &prev) == 0 && (prev.sa_flags & SA_ONSTACK));
    memset(&mine, 0, sizeof mine);
    mine.sa_sigaction = on_usr2; mine.sa_flags = SA_RESTART | SA_SIGINFO; sigemptyset(&mine.sa_mask);
    if (prev.sa_flags & SA_ONSTACK) { mine.sa_flags |= SA_ONSTACK; mine.sa_mask = prev.sa_mask; }
    CHECK(sigaction(SIGRTMIN, &mine, NULL) == 0 && sigaction(SIGRTMIN, NULL, &rt) == 0 && (rt.sa_flags & SA_ONSTACK));
    handler_sp = 0;
    raise(SIGRTMIN);
    CHECK(handler_sp >= (uintptr_t)cur.ss_sp && handler_sp < (uintptr_t)cur.ss_sp + cur.ss_size);
    CHECK(s2a_android_runtime_signals_prepare() == 0);   // something installed: left alone
    CHECK(sigaction(SIGRTMIN, NULL, &rt) == 0 && rt.sa_sigaction == on_usr2);

    // An explicitly ignored signal is also an existing disposition, not an
    // invitation to install our handler. Preserve that policy and the caller's state.
    struct sigaction ignored_rt = default_rt;
    ignored_rt.sa_handler = SIG_IGN;
    CHECK(sigaction(SIGRTMIN, &ignored_rt, NULL) == 0);
    CHECK(s2a_android_runtime_signals_prepare() == 0);
    CHECK(sigaction(SIGRTMIN, NULL, &rt) == 0 && rt.sa_handler == SIG_IGN);
    CHECK(sigaction(SIGRTMIN, &inherited_rt, NULL) == 0);

    s2a_android_altstack_free();
    CHECK(sigaltstack(NULL, &cur) == 0 && (cur.ss_flags & SS_DISABLE));
    sigaction(SIGUSR2, &old, NULL);
    if (failures) return 1;
    puts("guest signal stack: ok");
    return 0;
}

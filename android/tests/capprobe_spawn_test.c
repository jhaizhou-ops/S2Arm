/* capprobe_spawn_test.c — host regression for the capprobe arm runner's
 * process model (#1456 owner review). The probe used to fork() the ART
 * process and run Vulkan in the child; a forked child keeps only the
 * calling thread, so locks held by the other threads (malloc arena,
 * dynamic loader, ART internals) stay held forever and the child wedges
 * into a silent timeout that reads as inconclusive twice -> unsupported.
 *
 * This test recreates that lock scenario: a sibling thread holds a lock
 * continuously for the whole probe window (standing in for a thread
 * parked inside malloc with the arena lock held). With the
 * posix_spawn'd helper the run still completes inside its timeout. A
 * negative control proves the scenario actually bites: a child forked
 * under the same held lock can never produce a contract line — this is
 * the red half of the red/green pair; s2a_capprobe_run is the green.
 *
 * The runner does not exec the helper directly: it posix_spawns the
 * system dynamic linker with the helper's in-APK spec — {linker64,
 * "<apk>!/lib/<abi>/libs2a_capprobe.so", arm, <name>} — which is the only
 * exec shape the owner accepted for the packaged probe (#1482). This
 * test spawns through a fake linker (capprobe_fake_linker): it logs the
 * argv it was launched with so the launch contract is asserted verbatim
 * (exec target = linker, argv[1] = the "!/" spec), then resolves the
 * spec under a directory standing in for the APK and execs the fake
 * helper — every contract/stderr/exit case still runs through the real
 * spawn path.
 *
 * Build (see android/test.sh / native/capprobe/run_host_tests.sh):
 *   cc -std=gnu11 -Wall -Wextra -Werror -I native/capprobe \
 *      tests/capprobe_spawn_test.c native/capprobe/capprobe_host.c -lpthread
 * CAPPROBE_FAKE_APK must point at a directory holding
 * lib/arm64-v8a/libs2a_capprobe.so (the compiled capprobe_fake_helper),
 * CAPPROBE_FAKE_LINKER at the compiled capprobe_fake_linker. */
#include "capprobe.h"

#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>

static int failures;

static void check(int cond, const char *what) {
    if (!cond) {
        failures++;
        printf("FAIL %s\n", what);
    }
}

static long long mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

/* The lock standing in for a heap/loader lock a forked child would
 * inherit in the held state. The holder thread keeps it locked for the
 * entire probe window while doing allocator work — it never releases
 * until told to stop. */
static pthread_mutex_t g_alloc_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_holder_stop = 0;

static void *alloc_holder(void *arg) {
    (void)arg;
    pthread_mutex_lock(&g_alloc_lock);
    while (!g_holder_stop) {
        void *p = malloc(64);
        free(p);
        struct timespec nap = {0, 1000000};   /* still holding the lock */
        nanosleep(&nap, NULL);
    }
    pthread_mutex_unlock(&g_alloc_lock);
    return NULL;
}

/* What the old implementation effectively did: fork and produce the
 * contract line in the child. Under the held-lock scenario the child
 * wedges before it can write — the probe can only return timeout. */
static int fork_child_wedges(void) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        /* Any lock the vanished sibling held at fork() — malloc arena,
         * loader, ART — is modeled by g_alloc_lock: the child blocks here
         * forever on Linux (futex owner gone) or errors out, either way
         * it can never emit a contract line. */
        if (pthread_mutex_lock(&g_alloc_lock) != 0) _exit(3);
        (void)write(fds[1], "{", 1);
        _exit(0);
    }
    close(fds[1]);
    struct pollfd pfd = { .fd = fds[0], .events = POLLIN };
    int pr = poll(&pfd, 1, 2000);
    close(fds[0]);
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) { }
    return pr == 0;     /* no contract line within the window */
}

int main(void) {
    const char *apk = getenv("CAPPROBE_FAKE_APK");
    const char *linker = getenv("CAPPROBE_FAKE_LINKER");
    check(apk && *apk, "CAPPROBE_FAKE_APK set");
    check(linker && *linker, "CAPPROBE_FAKE_LINKER set");
    if (!apk || !*apk || !linker || !*linker) return 1;

    /* 1. helper unset -> synthesized error line, direction safe. */
    unsetenv("S2A_CAPPROBE_HELPER");
    char *line = s2a_capprobe_run("occ", 1000);
    check(line && strstr(line, "helper-unset"), "helper-unset error line");
    free(line);

    /* The runner spawns the linker with the helper's in-APK spec —
     * <apk dir>!/lib/arm64-v8a/libs2a_capprobe.so here. */
    char spec[4096];
    snprintf(spec, sizeof spec, "%s!/lib/arm64-v8a/libs2a_capprobe.so", apk);
    setenv("S2A_CAPPROBE_HELPER", spec, 1);
    setenv("S2A_CAPPROBE_LINKER", linker, 1);
    char logpath[] = "/tmp/capprobe-linker-argv.XXXXXX";
    int logfd = mkstemp(logpath);
    check(logfd >= 0, "linker argv log path created");
    if (logfd >= 0) close(logfd);
    setenv("CAPPROBE_LINKER_LOG", logpath, 1);

    /* 2. sibling thread holds the lock through the whole probe window;
     *    the posix_spawn'd helper is a separate process with its own
     *    address space and must still return within its timeout. */
    pthread_t holder;
    check(pthread_create(&holder, NULL, alloc_holder, NULL) == 0,
          "holder thread started");
    struct timespec settle = {0, 50000000};
    nanosleep(&settle, NULL);

    long long t0 = mono_ms();
    line = s2a_capprobe_run("occ", 5000);
    long long elapsed = mono_ms() - t0;
    check(line && strstr(line, "\"outcome\":\"ok\""),
          "spawned helper completes while sibling holds the lock");
    check(elapsed < 4000, "probe returned promptly under held lock");

    /* Launch contract (#1482 owner): the exec'd file is the linker and
     * its first argument is the helper's "<apk>!/<entry>" spec — the
     * helper never leaves the package layout. */
    FILE *lf = fopen(logpath, "r");
    check(lf != NULL, "linker argv log readable");
    if (lf) {
        char logged[4096] = {0};
        size_t n = fread(logged, 1, sizeof logged - 1, lf);
        logged[n] = 0;
        fclose(lf);
        const char *lname = strrchr(linker, '/');
        lname = lname ? lname + 1 : linker;
        char want0[512];
        snprintf(want0, sizeof want0, "argv[0]=%s", lname);
        check(strstr(logged, want0) != NULL,
              "spawned executable is the linker");
        char want1[4400];
        snprintf(want1, sizeof want1, "argv[1]=%s", spec);
        check(strstr(logged, want1) != NULL,
              "argv[1] is the in-APK !/ spec");
        check(strstr(logged, "argv[2]=arm") != NULL,
              "argv[2] selects the arm mode");
        check(strstr(logged, "argv[3]=occ") != NULL,
              "argv[3] is the arm name");
    }

    /* 3. negative control: the same held lock wedges a forked child —
     *    this is the failure the owner review reported. If anyone
     *    reverts s2a_capprobe_run to fork+in-process execution this
     *    scenario goes red. */
    check(fork_child_wedges() == 1,
          "negative control: forked child cannot answer under held lock");

    /* 4. wedged helper -> timeout contract line, not a hang. */
    t0 = mono_ms();
    line = s2a_capprobe_run("hang", 800);
    elapsed = mono_ms() - t0;
    check(line && strstr(line, "\"outcome\":\"timeout\""),
          "wedged helper -> timeout line");
    check(elapsed < 5000, "timeout path did not wait for the wedged child");
    free(line);

    /* 5. fingerprint path goes through the same spawn. */
    line = s2a_capprobe_run("fingerprint", 3000);
    check(line && strstr(line, "\"type\":\"fingerprint\""),
          "fingerprint contract line");
    free(line);

    /* 6. helper's own fingerprint failure line passes through unchanged,
     *    and diag reports the nonzero exit plus the stderr tail — the
     *    combination "fingerprint unavailable" was missing (#1482). */
    setenv("CAPPROBE_FAKE_FP_ERROR", "1", 1);
    line = s2a_capprobe_run("fingerprint", 3000);
    check(line && strstr(line, "\"error\":\"vkCreateInstance=-3\""),
          "fingerprint failure line passes through");
    const char *diag = s2a_capprobe_last_diag();
    check(diag && strstr(diag, "exit:2"), "diag reports child exit code");
    check(diag && strstr(diag, "vkCreateInstance returned -3"),
          "diag holds helper stderr");
    unsetenv("CAPPROBE_FAKE_FP_ERROR");
    free(line);

    /* 7. nonzero exit without any stdout -> empty-output carrying the
     *    exit code and stderr tail in detail. */
    line = s2a_capprobe_run("silentfail", 3000);
    check(line && strstr(line, "empty-output") && strstr(line, "exit:2"),
          "silent nonzero exit -> empty-output + exit detail");
    check(line && strstr(line, "dying without a contract line"),
          "empty-output detail carries stderr tail");
    free(line);

    /* 8. signaled helper -> crashed line naming the signal. */
    line = s2a_capprobe_run("sig", 3000);
    check(line && strstr(line, "\"outcome\":\"crashed\""),
          "signaled helper -> crashed line");
    check(line && strstr(line, "signal:11"),
          "crashed line detail names the signal");
    diag = s2a_capprobe_last_diag();
    check(diag && strstr(diag, "signal:11"), "diag reports child signal");
    free(line);

    /* 9. stderr stays bounded: a noisy helper still returns its contract
     *    line, diag keeps the tail (not the head) within the cap. */
    line = s2a_capprobe_run("noisy", 3000);
    check(line && strstr(line, "\"outcome\":\"ok\""),
          "noisy helper still answers on stdout");
    diag = s2a_capprobe_last_diag();
    check(diag && strstr(diag, "stderr-marker-tail"),
          "diag keeps stderr tail");
    check(diag && strlen(diag) < 4096, "stderr capture bounded");
    check(diag && !strstr(diag, "noise-00"),
          "stderr buffer holds the tail, not the head");
    free(line);

    /* 10. helper's own arm error line passes through unchanged even on a
     *     nonzero exit; the exit code still lands in diag. */
    line = s2a_capprobe_run("fail", 3000);
    check(line && strstr(line, "\"reason\":\"fake-init\""),
          "helper arm error line unchanged");
    diag = s2a_capprobe_last_diag();
    check(diag && strstr(diag, "exit:2"),
          "diag reports helper exit code");
    free(line);

    g_holder_stop = 1;
    pthread_join(holder, NULL);
    unlink(logpath);

    if (failures) {
        printf("capprobe_spawn_test: %d failures\n", failures);
        return 1;
    }
    printf("capprobe_spawn_test: passed\n");
    return 0;
}

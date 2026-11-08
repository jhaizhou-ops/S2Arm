// 用可控 now_ns 输入验证真实 alt.c 的纳秒边界，不替换相位实现。
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int s2a_alt_phase(void);
void s2a_alt_mark(void);

#ifndef REAL_PLATFORM_CLOCK
static uint64_t now = 5000000000ull;
uint64_t now_ns(void) { return now; }
#endif

static unsigned checks, failures;
static volatile sig_atomic_t signal_phase = -2;

static void expect(const char *name, int want, int actual) {
    checks++;
    if (want != actual) {
        failures++;
        fprintf(stderr, "%s: expected %d, got %d\n", name, want, actual);
    }
}

static void on_signal(int number) {
    (void)number;
    signal_phase = s2a_alt_phase();
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    expect("before MARK", -1, s2a_alt_phase());
    if (strcmp(argv[1], "disabled") == 0) {
        s2a_alt_mark();
        expect("disabled after MARK", -1, s2a_alt_phase());
        s2a_alt_mark();
        expect("disabled repeated MARK", -1, s2a_alt_phase());
    } else if (strcmp(argv[1], "enabled") == 0) {
        s2a_alt_mark();
        expect("first MARK starts off segment", 0, s2a_alt_phase());
#ifndef REAL_PLATFORM_CLOCK
        now = 6999999999ull;
        expect("last ns of off segment", 0, s2a_alt_phase());
        now = 7000000000ull;
        expect("on boundary", 1, s2a_alt_phase());
        s2a_alt_mark();
        expect("repeated MARK preserves first origin", 1, s2a_alt_phase());
        now = 8999999999ull;
        expect("last ns of on segment", 1, s2a_alt_phase());
        now = 9000000000ull;
        expect("next off boundary", 0, s2a_alt_phase());
        now = 4999999999ull;
        expect("clock before origin", -1, s2a_alt_phase());
        now = 7000000000ull;
#endif
        struct sigaction action = {0};
        action.sa_handler = on_signal;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGUSR1, &action, NULL) != 0 || raise(SIGUSR1) != 0) return 2;
#ifdef REAL_PLATFORM_CLOCK
        expect("real clock query in signal handler", 0, signal_phase);
#else
        expect("phase query in signal handler", 1, signal_phase);
#endif
    } else {
        return 2;
    }
    printf("%s phase owner: %u checks, %u failures\n", failures ? "FAIL" : "PASS", checks, failures);
    return failures != 0;
}

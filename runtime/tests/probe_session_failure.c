// Real native session contract; no replacement service/renderer exports.
// This calls the notification ABI, not an actual Horizon exception.
#include "../include/s2a_session.h"
#include <stdio.h>
#include <string.h>

int s2a_session_stop_requested(void);
void s2a_session_timer_run(unsigned, void (*)(void));
void s2a_session_park_guest_end(const char *);
int s2a_gate_session_reset(void), s2a_svc_park_all(int);
static int timer_fired;
static void timer(void) { timer_fired++; }

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "capability")) {
        // No guest has registered yet: the real xstack constructor is loaded,
        // but prepare and the first thread_keys_init have not run.
        int first = s2a_session_rebuild_supported();
        int repeat = s2a_session_rebuild_supported();
        int prepare = s2a_session_prepare();
        int after = s2a_session_rebuild_supported();
        printf("capability before=%d repeat=%d prepare=%d after=%d\n", first, repeat, prepare, after);
        return first != 1 || repeat != 1 || prepare != 0 || after != 1;
    }
    if (argc != 2 || s2a_session_prepare()) return 2;
    unsigned generation = s2a_session_generation();
    if (!strcmp(argv[1], "running")) {
        if (s2a_session_running(generation) ||
            s2a_session_service_failed(generation) != 1 ||
            s2a_host_session_state() != S2A_SESSION_RUNNING ||
            s2a_session_stop_requested() ||
            s2a_host_restart(NULL, NULL) != -1) return 3;
        s2a_session_timer_run(generation, timer);
        if (timer_fired != 1) return 4;
        // Before the fix this path either fails the state assertion or parks
        // forever instead of reaching ordinary host shutdown.
        s2a_session_park_guest_end("native contract probe");
        if (s2a_session_service_failed(generation) != 1) return 5;
        puts("PASS normal service notification preserves RUNNING, timer and terminal path; restart rejected");
    } else if (!strcmp(argv[1], "starting")) {
        if (s2a_session_service_failed(generation) ||
            s2a_host_session_state() != S2A_SESSION_FAILED ||
            !s2a_session_stop_requested() ||
            s2a_session_running(generation) != -1 ||
            s2a_session_guest_begin(generation) != -1 ||
            s2a_host_restart(NULL, NULL) != -1 ||
            s2a_session_prepare() != -1) return 6;   // 审计 #1534 P1-4 契约：初启失败 = 本进程终局，同进程不能再 prepare / 重启
        puts("PASS initial failure blocks late startup/admission, re-prepare and restart; no retirement claimed");
    } else return 2;
    s2a_session_process_exit(0);
    if (s2a_session_service_failed(generation) != -1 ||
        s2a_gate_session_reset() != -1) return 7;
    s2a_svc_park_all(0);
    if (s2a_gate_session_reset() != -1) return 8;
    puts("PASS native owner-independent exit permanently seals gate reset");
    return 0;
}

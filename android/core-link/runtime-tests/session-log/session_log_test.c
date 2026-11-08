#include "../oodle_fixture.h"
// 真实 runtime + os.c 的描述符/文件路径；其余 core 端点复用明确合成的顺序夹具。
#define main sequence_main
#define s2a_window_ok sequence_window
#include "../runtime_test.c"
#undef s2a_window_ok
#undef main
#include "native.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>

static int dup_calls, fail_dup;
int log_test_dup2(int oldfd, int newfd) {
    if (++dup_calls == fail_dup) { errno = EMFILE; return -1; }
    return dup2(oldfd, newfd);
}
uint64_t plat_now_ns(void) { return 0; } // 非本夹具的时钟范围。
int s2a_window_ok(void) { record("window"); LOG("FIRST_CORE_WINDOW"); return 0; }
static void on_signal(int sig) {
    (void)sig;
    static const char line[] = "SIGNAL_RAW_WRITE\n";
    ssize_t n = write(g_s2a_logfd, line, sizeof line - 1); (void)n;
}
static int count_fds(void) {
    int n = 0;
    for (int fd = 0; fd < 1024; fd++) if (fcntl(fd, F_GETFD) >= 0) n++;
    return n;
}
static int same_file(int fd, const struct stat *old) {
    struct stat now; assert(!fstat(fd, &now));
    return now.st_dev == old->st_dev && now.st_ino == old->st_ino;
}
int main(int argc, char **argv) {
    assert(argc == 3); mode = "window";
    const char *test = argv[1];
    const char *names[] = {"main", "sdk"};
    struct s2a_android_runtime_request r = {
        .services = {sizeof r.services, 1, session, (void *)0x123, &host, "/frozen/game", argv[2], (void *)0x456, 1, 0},
        .module_dir = "/frozen/modules", .module_names = names, .module_count = 2, .program_id = pid};
    int native_fd = g_s2a_logfd;
    struct stat old[3]; int targets[] = {1, 2, native_fd};
    for (int i = 0; i < 3; i++) assert(!fstat(targets[i], &old[i]));
    int fd_count = count_fds();
    if (!strcmp(test, "partial-bind")) fail_dup = 2;
    if (!strcmp(test, "invalid")) r.module_count = 0;
    int result = s2a_android_runtime_run(&r);
    assert(g_s2a_logfd == native_fd && count_fds() == fd_count);
    if (!strcmp(test, "success")) {
        assert(result == S2A_RUNTIME_WINDOW && !strcmp(trace, "window "));
        struct stat file; assert(!fstat(native_fd, &file) && S_ISREG(file.st_mode) && (file.st_mode & 0777) == 0600);
        assert(same_file(1, &file) && same_file(2, &file));
        assert(fcntl(native_fd, F_GETFL) & O_APPEND);
        LOG("NATIVE_LOG"); fprintf(stderr, "C_STDERR\n"); printf("C_STDOUT\n"); fflush(stdout);
        struct sigaction action = {.sa_handler = on_signal}; sigemptyset(&action.sa_mask);
        assert(!sigaction(SIGUSR1, &action, NULL)); assert(!raise(SIGUSR1));
        // 模拟 StdErrAdapter 替换 fd2；旧 native 编号仍须指向会话文件，不进入此 pipe。
        int pipefd[2]; assert(!pipe(pipefd) && dup2(pipefd[1], 2) == 2); close(pipefd[1]);
        LOG("NATIVE_AFTER_STDERR_REPLACED");
        assert(write(2, "pipe\n", 5) == 5); char b[8]; assert(read(pipefd[0], b, sizeof b) == 5); close(pipefd[0]);
        assert(s2a_android_runtime_run(&r) == S2A_RUNTIME_ALREADY_USED);
    } else {
        assert(result == (!strcmp(test, "invalid") ? S2A_RUNTIME_ARGUMENT : S2A_RUNTIME_LOG));
        assert(!*trace && !service_calls && !guest_calls);
        assert(stop_calls == (strcmp(test, "invalid") != 0));
        for (int i = 0; i < 3; i++) assert(same_file(targets[i], &old[i]));
    }
    return 0;
}

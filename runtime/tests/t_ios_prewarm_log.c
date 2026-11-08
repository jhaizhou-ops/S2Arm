// 真正执行 os.c 的 iOS 构造函数；仅把 HOME 查询指向独立测试容器、记录控制台线程入口。
#define S2A_LOGCON_IMPL
#include "../src/native.h"
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <dirent.h>

#define CHECK(x) do { if (!(x)) { fprintf(stdout, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static int console_starts;
static int fault_hit;
const char *s2a_log_test_getenv(const char *name) {
    if (!strcmp(name, "HOME")) {
        const char *failure = getenv("S2A_TEST_LOG_FAIL");
        if (failure && !strcmp(failure, "home")) { fault_hit = 1; return NULL; }
        return getenv("S2A_TEST_APP_HOME");
    }
    return getenv(name);
}
static int trip(const char *op, int err) {
    const char *failure = getenv("S2A_TEST_LOG_FAIL");
    if (!fault_hit && failure && !strcmp(failure, op)) { fault_hit = 1; errno = err; return 1; }
    return 0;
}
int s2a_log_test_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    return trip("open", ENOSPC) ? -1 : open(path, flags, mode);
}
int s2a_log_test_rename(const char *from, const char *to) {
    const char *name = strrchr(from, '/'); name = name ? name + 1 : from;
    if (!strcmp(name, "host.log") && trip("rename-host", EACCES)) return -1;
    return rename(from, to);
}
int s2a_log_test_dup(int fd) { return trip("dup-backup", EMFILE) ? -1 : dup(fd); }
int s2a_log_test_dup2(int from, int to) {
    if (trip(to == 2 ? "dup-stderr" : "dup-native", EBADF)) return -1;
    return dup2(from, to);
}
int s2a_process_prewarmed(void) { const char *e = getenv("ActivePrewarm"); return e && !strcmp(e, "1"); }
uint64_t plat_now_ns(void) { return 0; }
int s2a_logcon_start(int fd) { console_starts++; close(fd); return 0; }
void s2a_logcon_push(const char *p, size_t n) { (void)p; (void)n; }
void s2a_logcon_flush(void) {}
static void contents(const char *name, char *out, size_t cap) {
    char path[2048]; snprintf(path, sizeof path, "%s/Documents/%s", getenv("S2A_TEST_APP_HOME"), name);
    FILE *f = fopen(path, "rb"); CHECK(f != NULL);
    size_t n = fread(out, 1, cap - 1, f); CHECK(!ferror(f)); out[n] = 0; fclose(f);
}
static int cmpname(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
// 归档 Documents/logs/host-*.log 份数；k ≥ 1 时把新起第 k 份（按文件名，带会话起始时刻）的内容读进 out
static int archived(int k, char *out, size_t cap) {
    char dir[2048]; snprintf(dir, sizeof dir, "%s/Documents/logs", getenv("S2A_TEST_APP_HOME"));
    DIR *d = opendir(dir); if (!d) return 0;
    char *names[512]; int n = 0; struct dirent *e;
    while (n < 512 && (e = readdir(d))) if (!strncmp(e->d_name, "host-", 5)) names[n++] = strdup(e->d_name);
    closedir(d); qsort(names, (size_t)n, sizeof *names, cmpname);
    if (k >= 1 && k <= n) { char rel[2100]; snprintf(rel, sizeof rel, "logs/%s", names[n - k]); contents(rel, out, cap); }
    for (int i = 0; i < n; i++) free(names[i]);
    return n;
}
static const char *original(void) { return !strcmp(getenv("S2A_TEST_SESSION"), "crash") ? "original session\n【红】CRASH\n" : "original session\n优雅退出完成\n"; }
static int fault_case(int argc, char **argv) {
    CHECK(argc == 4); char text[4096], path[2048];
    int activate = !strcmp(argv[2], "activate");
    const char *destination = activate ? "host.prewarm.log" : "fallback-stderr.log";
    if (activate) { CHECK(!fault_hit); setenv("S2A_TEST_LOG_FAIL", argv[3], 1); s2a_log_session_start(); }
    CHECK(fault_hit);
    snprintf(path, sizeof path, "%s/Documents/%s", getenv("S2A_TEST_APP_HOME"), destination);
    int expected = open(path, O_RDONLY); CHECK(expected >= 0);
    struct stat a, b, c; CHECK(!fstat(expected, &a) && !fstat(2, &b) && !fstat(g_s2a_logfd, &c));
    CHECK(a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_dev == c.st_dev && a.st_ino == c.st_ino); close(expected);
    LOG("fault native continues"); CHECK(write(2, "fault stderr continues\n", 23) == 23);
    contents(destination, text, sizeof text);
    CHECK(strstr(text, "【红】日志") && strstr(text, "fault native continues") && strstr(text, "fault stderr continues"));
    printf("PASS 日志 %s / %s 失败：进程继续，stderr / 原生 fd 保持原输出\n", argv[2], argv[3]);
    return 0;
}
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "fault")) return fault_case(argc, argv);
    if (argc == 2 && !strcmp(argv[1], "start")) return 0;   // 只走构造函数的普通启动（壳脚本连续起局用）
    CHECK(argc == 2); char text[4096];
    if (s2a_process_prewarmed()) {
        CHECK(console_starts == 0);
        contents("host.log", text, sizeof text); CHECK(!strcmp(text, original()));
        contents("host.prev.log", text, sizeof text); CHECK(!strcmp(text, "older session\n"));
        contents("host.prev2.log", text, sizeof text); CHECK(!strcmp(text, "oldest session\n"));
        CHECK(archived(0, NULL, 0) == 0);
        LOG("预热启动：等待前台"); CHECK(write(2, "prewarm stderr\n", 15) == 15);
        contents("host.prewarm.log", text, sizeof text); CHECK(strstr(text, "预热启动：等待前台") && strstr(text, "prewarm stderr"));
        if (!strcmp(argv[1], "discard")) return 0;
        CHECK(!strcmp(argv[1], "activate"));
        s2a_log_session_start();
    } else CHECK(!strcmp(argv[1], "normal"));
    CHECK(console_starts == 1);
    LOG("activated native logger"); CHECK(write(2, "activated stderr\n", 17) == 17);
    CHECK(archived(1, text, sizeof text) == 3 && !strcmp(text, original()));
    archived(2, text, sizeof text); CHECK(!strcmp(text, "older session\n"));
    archived(3, text, sizeof text); CHECK(!strcmp(text, "oldest session\n"));
    { char a[2048], b[2048]; snprintf(a, sizeof a, "%s/Documents/host.prev.log", getenv("S2A_TEST_APP_HOME")); snprintf(b, sizeof b, "%s/Documents/host.prev2.log", getenv("S2A_TEST_APP_HOME"));
      CHECK(access(a, F_OK) && access(b, F_OK)); }
    contents("host.log", text, sizeof text); CHECK(strstr(text, "activated native logger") && strstr(text, "activated stderr") && !strstr(text, "prewarm"));
    s2a_log_session_start(); LOG("second activation");
    CHECK(console_starts == 1);
    CHECK(archived(1, text, sizeof text) == 3 && !strcmp(text, original()));
    contents("host.log", text, sizeof text); CHECK(strstr(text, "activated native logger") && strstr(text, "second activation"));
    return 0;
}

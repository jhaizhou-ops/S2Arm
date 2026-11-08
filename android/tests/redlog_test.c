// 红日志落盘路径（#1357）：目录由 Java 侧注入（getExternalFilesDir() / getFilesDir()），native
// 只拼 red.log。用例走真实 red()：子进程 abort，父进程核 <dir>/red.log 与宿主日志 fd 都有该行。
#include "redlog.h"
#include "native.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static int fails;
static void ck(int ok, const char *what) {
    if (ok) printf("✓ %s\n", what);
    else { printf("✗ %s\n", what); fails++; }
}

static size_t slurp(const char *path, char *out, size_t cap) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { out[0] = 0; return 0; }
    ssize_t n = read(fd, out, cap - 1);
    close(fd);
    if (n < 0) n = 0;
    out[n] = 0;
    return (size_t)n;
}

int main(void) {
    struct rlimit no_core = {0, 0};
    setrlimit(RLIMIT_CORE, &no_core);   // 子进程故意 abort，不落 core

    char dir[] = "/tmp/t_redlog_XXXXXX";
    if (!mkdtemp(dir)) { printf("【红】mkdtemp 失败 errno=%d\n", errno); return 99; }
    char red[512], host[512];
    snprintf(red, sizeof red, "%s/red.log", dir);
    snprintf(host, sizeof host, "%s/host.log", dir);
    int hfd = open(host, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (hfd < 0) { printf("【红】宿主日志打不开 errno=%d\n", errno); return 99; }
    g_s2a_logfd = hfd;

    ck(s2a_android_redlog_set_dir(NULL) == EINVAL, "空目录被拒绝");
    ck(s2a_android_redlog_set_dir("relative/dir") == EINVAL, "相对路径被拒绝");
    ck(s2a_android_redlog_set_dir(dir) == 0, "注入目录后预打开成功");

    fflush(stdout);   // 子进程 abort 会 flush 继承的 stdio 缓冲，不重复打印父进程的结果
    pid_t pid = fork();
    if (pid < 0) { printf("【红】fork 失败 errno=%d\n", errno); return 99; }
    if (pid == 0) {
        s2a_android_red("fatal %d", 42);   // 不返回
        _exit(99);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) { printf("【红】waitpid 失败\n"); return 99; }
    ck(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT, "red() 在写盘后 abort");

    char buf[4096];
    slurp(red, buf, sizeof buf);
    ck(strstr(buf, "RED fatal 42\n") != NULL, "red.log 有该行且落在注入目录");
    ck(strstr(buf, "/sdcard/") == NULL, "red.log 不含写死的旧路径");
    slurp(host, buf, sizeof buf);
    ck(strstr(buf, "RED fatal 42\n") != NULL, "宿主日志 fd 有同一行");

    unlink(red);
    unlink(host);
    rmdir(dir);
    close(hfd);
    if (fails) printf("【红】redlog：%d 项失败\n", fails);
    else puts("redlog：全部用例通过");
    return fails ? 1 : 0;
}

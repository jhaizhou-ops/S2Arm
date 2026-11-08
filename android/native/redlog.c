// 红日志落盘（#1357）：脚本层不写死游戏包名。Java 侧把当前应用的私有目录传进来
// （getExternalFilesDir()，取不到退 getFilesDir()），这里只拼文件名。red() 与 guest signal
// 的致命路径都走同一份实现：同时写 red.log 与宿主日志 fd g_s2a_logfd，并在 abort / _exit 前
// fsync，保证进程没机会刷 logcat 时原因仍在盘上。
#include "redlog.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../../runtime/src/native.h"   // g_s2a_logfd（各编译单元一份弱定义，链接后同一个）

#define S2A_REDLOG_NAME "red.log"

static char g_redlog_path[PATH_MAX];
static volatile sig_atomic_t g_redlog_fd = -1;

// 只用 open：本函数也会在信号处理器里被调用（构造期没开成功时重试一次）。
static int redlog_open(void) {
    int fd = (int)g_redlog_fd;
    if (fd >= 0) return fd;
    if (!g_redlog_path[0]) return -1;
    fd = open(g_redlog_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd >= 0) g_redlog_fd = fd;
    return fd;
}

int s2a_android_redlog_set_dir(const char *dir) {
    if (!dir || dir[0] != '/') return EINVAL;
    size_t len = strlen(dir);
    if (len + sizeof("/" S2A_REDLOG_NAME) > sizeof g_redlog_path) return ENAMETOOLONG;
    if (g_redlog_fd >= 0) {
        close((int)g_redlog_fd);
        g_redlog_fd = -1;
    }
    snprintf(g_redlog_path, sizeof g_redlog_path, "%s/%s", dir, S2A_REDLOG_NAME);
    return redlog_open() >= 0 ? 0 : errno;   // 外部目录不可写时由 Java 侧退到内部目录
}

void s2a_android_redlog_write(const char *line, size_t n) {
    if (!line || !n) return;
    int fd = redlog_open();
    if (fd >= 0) {
        ssize_t w = write(fd, line, n);
        (void)w;
        (void)fsync(fd);
    }
    int host = g_s2a_logfd;
    if (host >= 0) {
        ssize_t w = write(host, line, n);
        (void)w;
        (void)fsync(host);
    }
}

void s2a_android_red_v(const char *fmt, va_list ap) {
    char buf[1024];
    size_t k = 0;
    memcpy(buf, "RED ", 4);
    k = 4;
    int n = vsnprintf(buf + k, sizeof buf - k - 1, fmt, ap);
    if (n > 0) {
        size_t used = (size_t)n < sizeof buf - k - 1 ? (size_t)n : sizeof buf - k - 1;
        k += used;
    }
    if (k > sizeof buf - 2) k = sizeof buf - 2;   // 截断时仍是完整一行
    buf[k++] = '\n';
    s2a_android_redlog_write(buf, k);
    abort();
}

void s2a_android_red(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    s2a_android_red_v(fmt, ap);
}

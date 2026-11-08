// /proc 的 starttime 与 CLOCK_BOOTTIME 同一开机时基；不把 ELF 装载时刻冒充进程创建。
#include "native.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>

static pthread_once_t g_start_once = PTHREAD_ONCE_INIT;
static uint64_t g_start_ns;
static int g_start_error;
static _Atomic uint64_t g_last;

static uint64_t boot_now(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_BOOTTIME, &now)) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static void read_start(void) {
    int fd = open("/proc/self/stat", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { g_start_error = errno; return; }
    char stat[4096];
    ssize_t n;
    do { n = read(fd, stat, sizeof stat - 1); } while (n < 0 && errno == EINTR);
    int saved_errno = errno;
    close(fd);
    if (n <= 0 || (size_t)n == sizeof stat - 1) { g_start_error = n < 0 ? saved_errno : EIO; return; }
    stat[n] = 0;
    // comm（字段 2）可含空格和 ')'，后续字段均为数字 / 状态，因此取最后的 ')'。
    char *p = strrchr(stat, ')');
    if (!p || p[1] != ' ') { g_start_error = EIO; return; }
    p += 2;
    for (int field = 3; field < 22; field++) {
        p = strchr(p, ' ');
        if (!p) { g_start_error = EIO; return; }
        while (*p == ' ') p++;
    }
    char *end;
    errno = 0;
    unsigned long long ticks = strtoull(p, &end, 10);
    long hz = sysconf(_SC_CLK_TCK);
    if (errno || end == p || *end != ' ' || hz <= 0 || !ticks || ticks / (uint64_t)hz > UINT64_MAX / 1000000000ull) {
        g_start_error = EIO; return;
    }
    g_start_ns = ticks / (uint64_t)hz * 1000000000ull + ticks % (uint64_t)hz * 1000000000ull / (uint64_t)hz;
}

void s2a_boot_mark(const char *stage) {
    uint64_t now = boot_now();
    pthread_once(&g_start_once, read_start);
    if (!now || !g_start_ns || now < g_start_ns) {
        s2a_log_line("[起局] %s Android 进程起点不可用 errno=%d", stage, g_start_error);
        return;
    }
    uint64_t last = atomic_exchange(&g_last, now);
    if (!last) last = g_start_ns;
    // 并发打点先取钟再排原子序，出现倒序时本段只记 0，不作无符号减法下溢。
    uint64_t delta = now >= last ? now - last : 0;
    s2a_log_line("[起局] %s +%.1f ms（本段 %.1f ms，Android CLOCK_BOOTTIME）",
        stage, (now - g_start_ns) / 1e6, delta / 1e6);
}

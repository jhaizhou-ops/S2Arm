#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "lifecycle_android.h"
#include "native.h"
#if !defined(S2A_UNIT_TEST) && __has_include(<android/log.h>)
#define S2A_LIFECYCLE_LOGCAT 1
#include <android/log.h>
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

void s2a_host_shutdown(const char *why);

// 宿主（host_android.c）记的拆线程开关；单测不链宿主时弱引用为空 = 单线程
__attribute__((weak)) int s2a_android_host_threaded(void);
int s2a_android_shutdown_threaded(void) { return s2a_android_host_threaded && s2a_android_host_threaded(); }

static struct timespec g_shutdown_deadline;
// 兜底结束进程前打一行明确标识（局后判读据此区分「收完退出」与「被原生兜底结束」，9000 真机两种模式都看不出来）。
// 普通 host 日志文件即使 O_NONBLOCK 也可能阻塞。此函数只由独立诊断线程调用；最终 watchdog 不等它，
// 包括 open / close / logcat 的初始化或写入都不能挡住 _exit。标识是尽力写，缺行不能当作收局成功。
static void watchdog_mark(void) {
    static const char line[] = "[s2a] 【红】原生兜底：收局 1500 ms 没完成，结束进程（_exit 124）\n";
    char path[48];
    snprintf(path, sizeof path, "/proc/self/fd/%d", g_s2a_logfd);
    int fd = open(path, O_WRONLY | O_APPEND | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t written = write(fd, line, sizeof line - 1);
        (void)written;
        close(fd);
    }
#if defined(S2A_LIFECYCLE_LOGCAT)
    __android_log_write(ANDROID_LOG_ERROR, "S2Arm", line);
#endif
}

static void wait_shutdown_deadline(void) {
    int error;
    do { error = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &g_shutdown_deadline, NULL); }
    while (error == EINTR);
}

static void *shutdown_watchdog_mark(void *arg) {
    (void)arg;
    wait_shutdown_deadline();
    watchdog_mark();
    return NULL;
}

static void *shutdown_watchdog(void *arg) {
    (void)arg;
    wait_shutdown_deadline();
    // 只给独立诊断线程一次固定的调度机会，不等日志结果、锁、线程结束或任何文件 I/O。
    struct timespec scheduling = {0, 1000000};
    while (nanosleep(&scheduling, &scheduling) && errno == EINTR) {}
    _exit(124);
    return NULL;
}

// 收局进度（诊断，缺省开）：收局开始后每 250 ms 一行，直到进程结束（兜底 1.5 s，最多约 6 行）：收局线程与 S2A.GPU* 线程的内核态
// （R 在跑 / S 睡 / D 不可中断，多半在等内核锁；当前系统调用，read / write 带 fd 指向的文件；wchan），以及正在进行的 writer epoch 里
// 还没停稳的 guest 线程（真机 9000 拆线程两局 Stop 一直没到、进程在 +1.9 s 被兜底结束，日志分不出是卡在哪一步还是只是慢）。
// 独立线程，只读 /proc 与名册快照；写日志可能被满管道卡住，卡住的只是它自己，兜底线程照常结束进程。不改收局语义。
enum { SHUTDOWN_PROGRESS_MS = 250 };
static struct timespec g_shutdown_started;
static pid_t g_shutdown_tid;

static void read_small(const char *path, char *out, size_t cap) {
    out[0] = 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t n = read(fd, out, cap - 1);
    close(fd);
    out[n > 0 ? n : 0] = 0;
    char *newline = strchr(out, '\n');
    if (newline) *newline = 0;
}

static const char *syscall_name(long nr) {
    switch (nr) {
    case 22: return "epoll_pwait";
    case 29: return "ioctl";
    case 56: return "openat";
    case 57: return "close";
    case 63: return "read";
    case 64: return "write";
    case 73: return "ppoll";
    case 98: return "futex";
    case 101: return "nanosleep";
    case 115: return "clock_nanosleep";
    case 124: return "sched_yield";
    case 215: return "munmap";
    case 222: return "mmap";
    case 226: return "mprotect";
    default: return "";
    }
}

// 上一拍各线程的 CPU 时钟滴答（utime + stime），算「这 250 ms 用了多少 CPU」：R 态时区分在跑（自旋 / 长循环）还是等着被调度
enum { PROGRESS_TASKS = 8 };
static struct { pid_t tid; unsigned long long ticks; } g_task_cpu[PROGRESS_TASKS];

static long long task_cpu_delta_ms(pid_t tid, unsigned long long ticks) {
    long hz = sysconf(_SC_CLK_TCK);
    for (int i = 0; i < PROGRESS_TASKS; ++i) {
        if (g_task_cpu[i].tid == tid) {
            unsigned long long before = g_task_cpu[i].ticks;
            g_task_cpu[i].ticks = ticks;
            return hz > 0 ? (long long)((ticks - before) * 1000ull / (unsigned long long)hz) : -1;
        }
        if (!g_task_cpu[i].tid) { g_task_cpu[i].tid = tid; g_task_cpu[i].ticks = ticks; return -1; }
    }
    return -1;
}

// 内核栈前两帧（/proc/<tid>/stack 一般要 root，读不到就不写）
static void task_stack(pid_t tid, char *out, size_t cap) {
    char path[64], text[512];
    out[0] = 0;
    snprintf(path, sizeof path, "/proc/self/task/%d/stack", (int)tid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t n = read(fd, text, sizeof text - 1);
    close(fd);
    if (n <= 0) return;
    text[n] = 0;
    size_t used = 0;
    char *line = text;
    for (int frame = 0; frame < 2 && line && *line; ++frame) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        char *name = strchr(line, ']');
        name = name ? name + 1 : line;
        while (*name == ' ') ++name;
        char *plus = strchr(name, '+');
        if (plus) *plus = 0;
        int k = snprintf(out + used, cap - used, "%s%s", frame ? " < " : "", name);
        if (k <= 0 || (size_t)k >= cap - used) break;
        used += (size_t)k;
        line = next;
    }
}

// 一条线程的内核态，追加到 out[*used]
static void describe_task(char *out, size_t cap, size_t *used, pid_t tid, const char *label) {
    char path[64], stat[512], call[192], wchan[64], target[96] = "", stack[160];
    snprintf(path, sizeof path, "/proc/self/task/%d/stat", (int)tid);
    read_small(path, stat, sizeof stat);
    const char *paren = strrchr(stat, ')');
    char state = paren && paren[1] == ' ' && paren[2] ? paren[2] : '?';
    // stat 在 ")" 之后：state(3) ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime(14) stime(15)
    unsigned long long utime = 0, stime = 0;
    long long cpu = -1;
    if (paren && sscanf(paren + 2, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu", &utime, &stime) == 2)
        cpu = task_cpu_delta_ms(tid, utime + stime);
    task_stack(tid, stack, sizeof stack);
    snprintf(path, sizeof path, "/proc/self/task/%d/syscall", (int)tid);
    read_small(path, call, sizeof call);
    snprintf(path, sizeof path, "/proc/self/task/%d/wchan", (int)tid);
    read_small(path, wchan, sizeof wchan);
    long nr = -1;
    if (call[0] >= '0' && call[0] <= '9') {
        char *end;
        nr = strtol(call, &end, 10);
        unsigned long long fd = strtoull(end, NULL, 16);
        if ((nr == 63 || nr == 64) && fd < 65536) {
            char link[64];
            snprintf(link, sizeof link, "/proc/self/fd/%llu", fd);
            ssize_t n = readlink(link, target, sizeof target - 1);
            target[n > 0 ? n : 0] = 0;
        }
    }
    if (*used + 1 >= cap) return;
    char what[160];
    if (nr >= 0) snprintf(what, sizeof what, "系统调用 %ld %s%s%s", nr, syscall_name(nr), target[0] ? " " : "", target);
    else snprintf(what, sizeof what, "%s", !call[0] ? "系统调用读不到" : strncmp(call, "running", 7) ? "不在系统调用里" : "在跑");
    char extra[220] = "";
    int e = cpu >= 0 ? snprintf(extra, sizeof extra, "，上一拍 CPU %lld ms", cpu) : 0;
    if (stack[0] && e >= 0 && (size_t)e < sizeof extra) snprintf(extra + e, sizeof extra - (size_t)e, "，栈 %s", stack);
    int n = snprintf(out + *used, cap - *used, "；%s tid %d %c %s wchan %s%s", label, (int)tid, state, what, wchan[0] ? wchan : "?", extra);
    if (n > 0) *used += (size_t)n < cap - *used ? (size_t)n : cap - *used - 1;
}

// 收局线程与 S2A.GPU* 线程各描述一段，追加到 line（同时更新各线程的 CPU 基线）
static void describe_tasks(char *line, size_t cap, size_t *used) {
    describe_task(line, cap, used, g_shutdown_tid, "收局线程");
    DIR *tasks = opendir("/proc/self/task");
    if (!tasks) return;
    struct dirent *entry;
    while ((entry = readdir(tasks))) {
        pid_t tid = (pid_t)atoi(entry->d_name);
        if (tid <= 0 || tid == g_shutdown_tid) continue;
        char path[64], comm[32];
        snprintf(path, sizeof path, "/proc/self/task/%d/comm", (int)tid);
        read_small(path, comm, sizeof comm);
        if (!strncmp(comm, "S2A.GPU", 7)) describe_task(line, cap, used, tid, comm);
    }
    closedir(tasks);
}

static void *shutdown_progress(void *arg) {
    (void)arg;
    char line[1536];
    size_t used = 0;
    describe_tasks(line, sizeof line, &used);   // CPU 基线：第一拍就有「上一拍 CPU」
    for (unsigned tick = 1; tick <= 40; ++tick) {
        struct timespec at = g_shutdown_started;
        uint64_t ns = (uint64_t)at.tv_nsec + (uint64_t)tick * SHUTDOWN_PROGRESS_MS * 1000000ull;
        at.tv_sec += (time_t)(ns / 1000000000ull);
        at.tv_nsec = (long)(ns % 1000000000ull);
        while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &at, NULL) == EINTR) {}
        used = 0;
        line[0] = 0;
        describe_tasks(line, sizeof line, &used);
        char writers[512];
        s2a_android_guest_writers_describe(writers, sizeof writers);
        LOG("收局进度 +%u ms（原生）%s；guest 写者：%s", tick * SHUTDOWN_PROGRESS_MS, line, writers);
    }
    return NULL;
}

// 收局地址余量：有界执行。真机 9000 拆线程三局：收局线程读 /proc/self/maps 时 D 态 __down_read_killable（mmap_lock 读锁被写跟踪 mprotect / mmap 挤占），
// 一局读了 862 ms（单线程同一步 298 ms），两局读不完、1.5 s 被兜底结束。诊断不得阻塞收尾：独立线程读，最多等 SHUTDOWN_VM_LOW_MS；
// 超时打一行黄后继续收局，读线程读完会自己补打那一行（进程还在的话）。
enum { SHUTDOWN_VM_LOW_MS = 150 };
void s2a_vm_low(const char *when);
static pthread_mutex_t g_vm_low_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_vm_low_cond = PTHREAD_COND_INITIALIZER;
static int g_vm_low_done;

static void *shutdown_vm_low(void *arg) {
    (void)arg;
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    s2a_vm_low("收局");
    clock_gettime(CLOCK_MONOTONIC, &end);
    LOG("地址余量 [收局] 读 maps 用时 %.1f ms（拆线程：StopGpu 之后读）",
        (double)(end.tv_sec - start.tv_sec) * 1e3 + (double)(end.tv_nsec - start.tv_nsec) / 1e6);
    pthread_mutex_lock(&g_vm_low_lock);
    g_vm_low_done = 1;
    pthread_cond_signal(&g_vm_low_cond);
    pthread_mutex_unlock(&g_vm_low_lock);
    return NULL;
}

// 只由收局线程调一次（lifecycle.c 的 once 之内）
void s2a_android_shutdown_vm_low(void) {
    pthread_t thread;
    int error = pthread_create(&thread, NULL, shutdown_vm_low, NULL);
    if (error) { LOG("【黄】地址余量 [收局]：诊断线程起不来 errno=%d，跳过（不影响收局）", error); return; }
    pthread_detach(thread);
    struct timespec deadline;   // pthread_cond_timedwait 缺省按 CLOCK_REALTIME
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += SHUTDOWN_VM_LOW_MS * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&g_vm_low_lock);
    int timed_out = 0;
    while (!g_vm_low_done && !timed_out) timed_out = pthread_cond_timedwait(&g_vm_low_cond, &g_vm_low_lock, &deadline) == ETIMEDOUT;
    int done = g_vm_low_done;
    pthread_mutex_unlock(&g_vm_low_lock);
    if (!done) LOG("【黄】地址余量 [收局]：读 /proc/self/maps 超过 %d ms 没读完（mmap_lock 竞争），不等、收局继续", SHUTDOWN_VM_LOW_MS);
}

int s2a_android_shutdown_watchdog_start(void) {
    // 共享 lifecycle.c 的 once 保证唯一调用；返回前 deadline 已经发布给新线程。
    if (clock_gettime(CLOCK_MONOTONIC, &g_shutdown_deadline)) return errno;
    g_shutdown_started = g_shutdown_deadline;
    g_shutdown_tid = (pid_t)syscall(SYS_gettid);
    g_shutdown_deadline.tv_sec++;
    g_shutdown_deadline.tv_nsec += 500000000;
    if (g_shutdown_deadline.tv_nsec >= 1000000000) {
        g_shutdown_deadline.tv_sec++;
        g_shutdown_deadline.tv_nsec -= 1000000000;
    }
    pthread_t thread;
    int error = pthread_create(&thread, NULL, shutdown_watchdog, NULL);
    if (error) return error;
    error = pthread_detach(thread);
    if (error) return error;
    pthread_t marker;
    if (!pthread_create(&marker, NULL, shutdown_watchdog_mark, NULL)) pthread_detach(marker);
    // 进度线程是诊断，只在拆线程时起（单线程保持基线日志）：起不来不影响收局（兜底已在），只记一行
    if (!s2a_android_shutdown_threaded()) return 0;
    pthread_t progress;
    int progress_error = pthread_create(&progress, NULL, shutdown_progress, NULL);
    if (progress_error) LOG("收局进度线程没起来 errno=%d（只少了进度行，收局照常）", progress_error);
    else pthread_detach(progress);
    return 0;
}

static int g_term_fd[2] = {-1, -1};
static int g_term_error;
static pthread_once_t g_term_once = PTHREAD_ONCE_INIT;

static void term_signal(int sig) {
    (void)sig;
    int saved_errno = errno;
    const unsigned char byte = 1;
    ssize_t result;
    do { result = write(g_term_fd[1], &byte, 1); } while (result < 0 && errno == EINTR);
    // EAGAIN 表示已有通知待处理；处理器不调用 logger、托管代码或 pthread 锁。
    if (result < 0 && errno != EAGAIN) _exit(125);
    errno = saved_errno;
}

static void *term_worker(void *arg) {
    (void)arg;
    struct pollfd p = {g_term_fd[0], POLLIN, 0};
    for (;;) {
        int n = poll(&p, 1, -1);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0 || !(p.revents & POLLIN)) {
            _exit(125);
        }
        unsigned char bytes[64];
        ssize_t read_n = read(g_term_fd[0], bytes, sizeof bytes);
        if (read_n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (read_n <= 0) _exit(125);
        s2a_host_shutdown("SIGTERM");
        // 另一线程已经接管退出时 shutdown 返回；watchdog 仍属于该唯一 owner。
    }
    return NULL;
}

static void term_install_once(void) {
    if (pipe2(g_term_fd, O_CLOEXEC | O_NONBLOCK)) { g_term_error = errno; return; }
    struct sigaction action = {0}, previous;
    action.sa_handler = term_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART | SA_ONSTACK;
    if (sigaction(SIGTERM, &action, &previous)) {
        g_term_error = errno;
        close(g_term_fd[0]); close(g_term_fd[1]);
        return;
    }
    pthread_t thread;
    g_term_error = pthread_create(&thread, NULL, term_worker, NULL);
    if (g_term_error) {
        sigaction(SIGTERM, &previous, NULL);
        close(g_term_fd[0]); close(g_term_fd[1]);
        return;
    }
    g_term_error = pthread_detach(thread);
}

int s2a_android_term_install(void) {
    int error = pthread_once(&g_term_once, term_install_once);
    return error ? error : g_term_error;
}

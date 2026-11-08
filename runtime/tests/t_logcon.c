// 控制台副本单测（logcon.c）：期望值按构造手算。
// ① 一行日志：副本与主日志各收到同一整行。
// ② 执行器不读（管道写满、写线程阻塞）时调用方 4000 行 × 512 字节（2 MB > 1 MB 环）照样 5 秒内打完；之后开始读：
//    收到的整行数 + 「环满丢 N 行」的 N = 4000，且每行完整（511 个 x + 换行，无粘行 / 截断），丢行通知恰好出现。
// ③ 执行器断开（读端关）后写线程关副本：g_s2a_confd 回 -1，调用方照常打主日志。
// ④ 进程退出前最后打的行（收局「优雅退出完成」）也写出：子进程打 2000 行 × 约 200 字节（400 KB：超管道 64 KB、不超环 1 MB，退出时写线程必有积压）后照 lifecycle.c 收局写法 s2a_logcon_flush() + _exit(0)（_exit 不跑 atexit），父进程读到 2000 行、末行在。
#include "../src/native.h"
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/time.h>
static uint64_t ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000; }
extern void (*s2a_logcon_test_inlock)(void);
static void reenter(void) { s2a_log_line("重入的一行"); }
int main(void) {
    int bad = 0, c[2], l[2];
    if (pipe(c) || pipe(l)) { printf("✗ t_logcon：建管道失败\n"); return 1; }
    fcntl(l[0], F_SETFL, O_NONBLOCK); g_s2a_logfd = l[1];
    if (s2a_logcon_start(c[1])) { printf("✗ t_logcon：起写线程失败\n"); return 1; }
    s2a_log_line("控制台副本 %d", 7);
    char x[64] = {0}, y[64] = {0}; ssize_t a = read(c[0], x, sizeof x - 1), d = read(l[0], y, sizeof y - 1); (void)a; (void)d;
    if (strcmp(x, "控制台副本 7\n") || strcmp(y, "控制台副本 7\n")) { printf("✗ ① 副本与主日志都应收到同一行：副本「%s」主「%s」\n", x, y); bad++; }
    char big[512]; memset(big, 'x', sizeof big - 1); big[sizeof big - 1] = 0;
    uint64_t t0 = ms(); char z[65536];
    for (int i = 0; i < 4000; i++) { s2a_log_line("%s", big); while (read(l[0], z, sizeof z) > 0) {} }
    if (ms() - t0 > 5000) { printf("✗ ② 副本没人读时调用方被卡（%llu ms）\n", (unsigned long long)(ms() - t0)); bad++; }
    // 读到 1 秒没新数据为止
    static char all[4 << 20]; size_t n = 0; struct pollfd pf = { c[0], POLLIN, 0 };
    while (poll(&pf, 1, 1000) > 0) { ssize_t k = read(c[0], all + n, sizeof all - 1 - n); if (k <= 0) break; n += (size_t)k; }
    all[n] = 0; unsigned long got = 0, drop = 0, broken = 0, notes = 0;
    for (char *s = all, *e; *s; s = e + 1) {
        if (!(e = strchr(s, '\n'))) { broken++; break; }
        size_t len = (size_t)(e - s);
        unsigned long v; const char *q = strstr(s, "[控制台] 环满丢 ");
        if (q && q < e && sscanf(q, "[控制台] 环满丢 %lu 行", &v) == 1) { drop += v; notes++; }
        else if (len == sizeof big - 1 && s[0] == 'x' && s[len - 1] == 'x' && !memchr(s, '[', len)) got++;
        else broken++;
    }
    if (got + drop != 4000 || broken || !notes || !drop)
        { printf("✗ ② 期望 整行数 + 丢行数 = 4000、坏行 0、丢行通知 ≥1 → 真结果 整行 %lu、丢 %lu、坏行 %lu、通知 %lu\n", got, drop, broken, notes); bad++; }
    close(c[0]); s2a_log_line("断开后 %d", 1);
    for (int i = 0; i < 100 && g_s2a_confd >= 0; i++) { struct timespec ts = { 0, 10000000 }; nanosleep(&ts, 0); s2a_log_line("断开后 %d", 2); }
    if (g_s2a_confd >= 0) { printf("✗ ③ 读端关后 1 秒副本 fd 仍是 %d（期望 -1）\n", g_s2a_confd); bad++; }
    { int q[2]; if (!pipe(q)) { pid_t pid = fork();
        if (pid == 0) { close(q[0]); int nul = open("/dev/null", O_WRONLY); g_s2a_logfd = nul; g_s2a_confd = -1; s2a_logcon_start(q[1]); char pad[200]; memset(pad, 'y', sizeof pad - 1); pad[sizeof pad - 1] = 0; for (int i = 0; i < 2000; i++) s2a_log_line("%s 退出前 %d", pad, i); s2a_logcon_flush(); _exit(0); }
        close(q[1]); { struct timespec ts = { 0, 200000000 }; nanosleep(&ts, 0); }   /* 晚 200 毫秒才读：管道先写满，子进程 exit 时环里还压着约 340 KB */
        static char r[1 << 20]; size_t m = 0; ssize_t k; while ((k = read(q[0], r + m, sizeof r - 1 - m)) > 0) m += (size_t)k; r[m] = 0; close(q[0]); waitpid(pid, 0, 0);
        int nl = 0; for (size_t i = 0; i < m; i++) nl += r[i] == '\n';
        if (nl != 2000 || !strstr(r, "退出前 1999\n")) { printf("✗ ④ 退出前最后的行应写出：期望 2000 行、末行「退出前 1999」→ 真结果 %d 行\n", nl); bad++; } } }
    // ⑤ 信号处理里打日志、恰好打断本线程 push 的临界区（同线程重入非递归锁 = 自锁死；macOS 实测同线程二次加锁挂住）：
    //    单测钩子在持锁时回调一次、回调里再打一行（= 信号处理里打日志）。子进程 5 秒内正常退出、丢行通知记 1 行才算过；旧版阻塞加锁会挂死，父进程到点杀掉判不通
    { int q[2]; if (!pipe(q)) { pid_t pid = fork();
        if (pid == 0) { close(q[0]); int nul = open("/dev/null", O_WRONLY); g_s2a_logfd = nul; g_s2a_confd = -1; s2a_logcon_start(q[1]);
            s2a_logcon_test_inlock = reenter; s2a_log_line("外层一行"); s2a_log_line("之后一行"); s2a_logcon_flush(); _exit(0); }
        close(q[1]); int st = -1; uint64_t t0 = ms(); static char r[65536]; size_t m = 0; ssize_t k;
        fcntl(q[0], F_SETFL, O_NONBLOCK);
        while (ms() - t0 < 5000) { while ((k = read(q[0], r + m, sizeof r - 1 - m)) > 0) m += (size_t)k; if (waitpid(pid, &st, WNOHANG) == pid) break; struct timespec ts = { 0, 10000000 }; nanosleep(&ts, 0); }
        while ((k = read(q[0], r + m, sizeof r - 1 - m)) > 0) m += (size_t)k; r[m] = 0;
        if (st == -1) { kill(pid, SIGKILL); waitpid(pid, &st, 0); printf("✗ ⑤ 持锁时同线程再打日志：子进程 5 秒没退出（自锁死）\n"); bad++; }
        else if (!strstr(r, "外层一行\n") || !strstr(r, "之后一行\n") || !strstr(r, "环满丢 1 行")) { printf("✗ ⑤ 期望 外层 / 之后两行在、丢行通知 1 行 → 真结果「%.200s」\n", r); bad++; }
        close(q[0]); } }
    printf("%s t_logcon：%d 处不符（② 整行 %lu、环满丢 %lu、通知 %lu 次）\n", bad ? "✗" : "✓", bad, got, drop, notes); return bad;
}

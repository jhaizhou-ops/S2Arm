// GPU 挂死看门狗单测（gal_gpuwd.m / gal_gpuwd.h，T10 #635）。缺省关的模块，全部用例都不碰 GPU：
// 要造「提交后永不完成」只用「登记了栅栏但从不推进完成号」，进程侧用无超时的阻塞调用（read 空管道）冒充
// waitUntilCompleted —— 这正是本模块要覆盖的场景，且不会让本机 GPU 真挂（本机 10-28 已因 GPU 挂死复现局死机两次，不许再跑真挂死）。
//
// 每个场景都是自己 posix_spawn 自己（同 t_buf.c 的 t_exit86）：环境变量只读一次、看门狗线程只起一次，
// 同一个进程里换环境变量验不了第二遍。
#include "../gal_gpuwd.h"
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static double mono(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec + (double)t.tv_nsec / 1e9; }
static void setms(const char *k, const char *v) { if (v) setenv(k, v, 1); else unsetenv(k); }

// ---------- 子进程侧 ----------
static int child_decide(void) {
    // 先把配置读进来（第一次登记触发；阈值放大到不会真触发），再逐行对判据
    setms("NXGAL_GPU_WD_MS", "100000"); setms("NXGAL_GPU_WD_SLOW_MS", "40000"); setms("NXGAL_GPU_WD_STALL_MS", "2000");
    gal_gpuwd_on_commit(1, NULL);
    gal_gpuwd_test_reset();   // 清登记，保留配置与已起的线程（阈值 100 秒，线程不会动）
    struct { uint64_t age, late; int want; } t[] = {
        {0, 0, 0}, {39999, 0, 0}, {40000, 0, 1}, {99999, 0, 1},
        {100000, 0, 2}, {500000, 0, 2},
        {500000, 2001, 0},   // 看门狗自己晚到 > 容忍量 = 整机被饿着，不判 GPU 挂死
        {500000, 2000, 2},   // 等于容忍量还不算晚到
    };
    int bad = 0;
    for (unsigned i = 0; i < sizeof t / sizeof *t; i++) {
        int got = gal_gpuwd_test_decide(t[i].age, t[i].late);
        if (got != t[i].want) { printf("  ✗ 判据 age=%llu late=%llu 期望 %d 实得 %d\n",
            (unsigned long long)t[i].age, (unsigned long long)t[i].late, t[i].want, got); bad++; }
    }
    return bad ? 1 : 0;
}

// 主线程堵在无超时的阻塞调用里（冒充 waitUntilCompleted），看门狗必须照样把进程退掉
static void block_forever(void) {
    int p[2]; if (pipe(p)) _exit(3);
    char c; ssize_t r = read(p[0], &c, 1); (void)r;   // 没人写：永不返回
    _exit(4);
}
static int child_fire(void) {
    setms("NXGAL_GPU_WD_MS", "150");
    gal_gpuwd_on_commit(1, &(gal_gpuwd_scene){.draws = 1234, .encs = 7});   // 登记栅栏 1，永不推进完成号 = 命令缓冲永不完成
    block_forever();
    return 5;
}
static int child_hook(void) {
    setms("NXGAL_GPU_WD_MS", "120");
    gal_gpuwd_test_set_exit(NULL);   // 复位（同进程复用时不残留）
    extern void hook_exit(int);
    gal_gpuwd_test_set_exit(hook_exit);
    gal_gpuwd_on_commit(1, NULL);
    block_forever();
    return 5;
}
static int child_log(void) {
    setms("NXGAL_GPU_WD_MS", "120"); setms("NXGAL_GPU_WD_MODE", "log");
    gal_gpuwd_on_commit(1, NULL);
    usleep(400000);   // 只记不退：400 ms 后自己走，退出码 7（不是 86）
    return 7;
}
static int child_done(void) {
    setms("NXGAL_GPU_WD_MS", "150");
    for (uint64_t f = 1; f <= 20; f++) { gal_gpuwd_on_commit(f, &(gal_gpuwd_scene){.draws = 10, .encs = 1}); usleep(5000); gal_gpuwd_on_done(f); }
    return 0;
}
// 现场 = 提交时登记的数（审计 #772 F-gpuwd-scene-live）。g_live_* 冒充宿主全局：提交之后会被改掉
//   （Metal 4 登记前把在录通道绘制数清零、种类改成 2，帧号也会再往前走）。修前看门狗判死时回调宿主现读，
//   读到的是 0 / 2 / 43，还会碰 Metal（g_gev.signaledValue）；修后接口里已没有回调宿主的口子，
//   判死路径零次 Metal 由父进程对本可执行文件（含 gal_gpuwd.m 全部代码）做 nm -u 证明
static uint32_t g_live_draws, g_live_kind; static uint64_t g_live_frame;
static int child_scene(void) {
    setms("NXGAL_GPU_WD_MS", "150");
    g_live_frame = 42; g_live_draws = 55; g_live_kind = 1;
    gal_gpuwd_on_commit(1, &(gal_gpuwd_scene){1234, 7, g_live_frame, 1280, 720, 37, g_live_draws, g_live_kind});
    g_live_draws = 0; g_live_kind = 2; g_live_frame = 43;   // 提交之后宿主现值变了（同 gal_commit 的清零与帧号前进）
    block_forever();
    return 5;
}
static int child_off(void) {
    setms("NXGAL_GPU_WD_MS", NULL);
    if (gal_gpuwd_on()) return 1;
    gal_gpuwd_on_commit(1, NULL);      // 关着：不登记、不起线程
    usleep(400000);
    if (gal_gpuwd_test_inflight() != 0) return 2;
    return 0;
}

// ---------- 父进程侧 ----------
static char g_argv0[1024];
static void self_path(void) { uint32_t n = sizeof g_argv0; if (_NSGetExecutablePath(g_argv0, &n)) g_argv0[0] = 0; }

// 起一个自己（带 mode 参数），等它退出；返回退出码，*sec = 用时，*log = stderr 内容（给了 logpath 才收）
static int run_child(const char *mode, double limit, double *sec, char *logbuf, size_t logn) {
    char lp[] = "/tmp/t_gpuwd_XXXXXX"; int lfd = -1;
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    if (logbuf) { lfd = mkstemp(lp); if (lfd >= 0) posix_spawn_file_actions_adddup2(&fa, lfd, 2); }
    pid_t pid; char *av[] = {g_argv0, (char *)mode, NULL}; extern char **environ;
    double t0 = mono();
    int rc = posix_spawn(&pid, g_argv0, &fa, NULL, av, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc) { if (lfd >= 0) { close(lfd); unlink(lp); } return -1; }
    // 有上限地等：超时就杀掉，免得单测自己挂死
    int st = 0; double deadline = t0 + limit;
    for (;;) {
        pid_t w = waitpid(pid, &st, WNOHANG);
        if (w == pid) break;
        if (mono() > deadline) { kill(pid, SIGKILL); waitpid(pid, &st, 0); break; }
        usleep(5000);
    }
    if (sec) *sec = mono() - t0;
    if (logbuf) {
        logbuf[0] = 0;
        if (lfd >= 0) {
            close(lfd);
            FILE *f = fopen(lp, "r");
            if (f) { size_t k = fread(logbuf, 1, logn - 1, f); logbuf[k] = 0; fclose(f); }
            unlink(lp);
        }
    }
    return WIFEXITED(st) ? WEXITSTATUS(st) : -WTERMSIG(st);
}

void hook_exit(int code) { _exit(code == 86 ? 9 : code); }   // 单测：换掉 _exit(86)，证明确实走到退出路径

int main(int argc, char **argv) {
    if (argc > 1) {   // 子进程模式
        if (!strcmp(argv[1], "--off")) return child_off();
        if (!strcmp(argv[1], "--decide")) return child_decide();
        if (!strcmp(argv[1], "--fire")) return child_fire();
        if (!strcmp(argv[1], "--hook")) return child_hook();
        if (!strcmp(argv[1], "--log")) return child_log();
        if (!strcmp(argv[1], "--done")) return child_done();
        if (!strcmp(argv[1], "--scene")) return child_scene();
        return 90;
    }
    self_path();
    CHECK(g_argv0[0], "取不到自己的可执行路径，子进程用例跑不了");
    if (!g_argv0[0]) { printf("t_gpuwd：0 / %d 通过\n", g_checks); return 1; }
    double sec = 0; char log[8192];

    // 1：缺省关 —— 不设环境变量时 gal_gpuwd_on() 假、不登记、不误退
    printf("· 缺省关：不设 NXGAL_GPU_WD_MS → 期望 gal_gpuwd_on()=0、登记后 0.4 秒仍活、退出码 0\n");
    int rc = run_child("--off", 5.0, &sec, NULL, 0);
    CHECK(rc == 0, "缺省关 退出码 期望 0 实得 %d（1=on() 非 0，2=关着还登记了在途）", rc);

    // 2：判据表（含「看门狗自己晚到 = 整机被饿着，不判」）
    printf("· 判据：8 行年龄 / 晚到量 → 期望逐行 0 / 1 / 2 与手算一致\n");
    rc = run_child("--decide", 5.0, &sec, NULL, 0);
    CHECK(rc == 0, "判据表 退出码 期望 0 实得 %d", rc);

    // 3：核心用例 —— 主线程堵在无超时阻塞调用里，独立线程照样判、照样退 86
    printf("· 独立线程退出：主线程 read 空管道（冒充 waitUntilCompleted）→ 期望 ≤ 3 秒退出码 86\n");
    rc = run_child("--fire", 3.0, &sec, NULL, 0);
    CHECK(rc == 86, "独立线程退出 退出码 期望 86 实得 %d（-9 = 3 秒没退，被父进程杀掉）", rc);
    CHECK(sec <= 3.0, "独立线程退出 用时 期望 ≤ 3.0 秒 实得 %.2f 秒", sec);
    CHECK(sec >= 0.15, "独立线程退出 用时下限（阈值 150 ms，不许提前判）期望 ≥ 0.15 秒 实得 %.2f 秒", sec);

    // 4：正常完成不误杀 —— 每条命令缓冲 5 ms 就完成，阈值 150 ms
    printf("· 不误杀：20 条命令缓冲各 5 ms 完成（阈值 150 ms）→ 期望退出码 0\n");
    rc = run_child("--done", 5.0, &sec, NULL, 0);
    CHECK(rc == 0, "不误杀 退出码 期望 0 实得 %d（86 = 正常完成被误判成挂死）", rc);

    // 5：MODE=log 只记不退
    printf("· 只记不退：NXGAL_GPU_WD_MODE=log → 期望退出码 7、stderr 有「GPU 挂死看门狗」\n");
    rc = run_child("--log", 5.0, &sec, log, sizeof log);
    CHECK(rc == 7, "只记不退 退出码 期望 7 实得 %d（86 = log 模式还是退了）", rc);
    CHECK(strstr(log, "GPU 挂死看门狗") != NULL, "只记不退 stderr 期望含「GPU 挂死看门狗」 实得：%.200s", log);

    // 6：退出路径可换（单测用），换掉后走的是 hook 而不是 _exit(86)
    printf("· 退出钩子：gal_gpuwd_test_set_exit 换成 _exit(9) → 期望退出码 9\n");
    rc = run_child("--hook", 3.0, &sec, NULL, 0);
    CHECK(rc == 9, "退出钩子 退出码 期望 9 实得 %d", rc);

    // 7：现场 = 提交时登记的数，判死路径不读宿主现值 / Metal（审计 #772 F-gpuwd-scene-live）
    //   期望值全由 child_scene 登记时传入的常量给出：栅栏 1、本批绘制 + 派发 1234、编码器 7、帧 42、最后在录通道 1280x720 格式 37 绘制 55 类 1；
    //   提交之后改成的 0 / 2 / 43 一个都不许出现
    printf("· 现场取登记值：登记绘制 1234 / 编码器 7 / 帧 42 / 通道绘制 55 类 1，之后宿主现值改成 0 / 2 / 43 → 期望退出码 86、现场行是登记值、导入表零个 ObjC / Metal 符号\n");
    rc = run_child("--scene", 3.0, &sec, log, sizeof log);
    CHECK(rc == 86, "现场取登记值 退出码 期望 86 实得 %d", rc);
    CHECK(strstr(log, "本批绘制 + 派发 1234、编码器 7") != NULL, "现场取登记值 期望含「本批绘制 + 派发 1234、编码器 7」 实得：%.400s", log);
    CHECK(strstr(log, "帧 42，") != NULL && strstr(log, "帧 43") == NULL, "现场取登记值 帧号 期望 42（登记时）不是 43（现值） 实得：%.400s", log);
    CHECK(strstr(log, "最后在录通道 1280x720 格式 37 绘制 55 类 1") != NULL, "现场取登记值 通道 期望「绘制 55 类 1」（登记时）不是「绘制 0 类 2」（清零后） 实得：%.400s", log);
    // 判死路径零次 Metal：本可执行文件只链 gal_gpuwd.m + 本单测，导入表里不许有 ObjC 消息发送 / Metal 符号
    //   （Metal 对象的任何属性读取都要走 objc_msgSend；导入表里没有它 = 看门狗模块在任何路径上都发不出 Metal 调用）
    { char cmd[1200]; snprintf(cmd, sizeof cmd, "nm -u '%s'", g_argv0);
      FILE *p = popen(cmd, "r"); int lines = 0, bad = 0; char ln[256];
      if (p) { while (fgets(ln, sizeof ln, p)) { lines++; if (strstr(ln, "objc_msgSend") || strstr(ln, "_MTL") || strstr(ln, "OBJC_CLASS")) { bad++; printf("    导入：%s", ln); } } pclose(p); }
      CHECK(lines > 0, "零次 Metal nm -u 期望读到导入表 实得 0 行（nm 没跑起来）");
      CHECK(bad == 0, "零次 Metal 导入表里 ObjC 消息 / Metal 符号 期望 0 个 实得 %d 个（共扫 %d 行）", bad, lines); }

    printf("t_gpuwd：%d / %d 通过\n", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}

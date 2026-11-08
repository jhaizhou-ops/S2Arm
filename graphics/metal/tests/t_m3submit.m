// 单测 t_m3submit：Metal 3 / Metal 4 提交路径的 CPU 开销（卡 M3-5 / #112）。
// 同一台 Mac、两支各起一个子进程（nxgal_init 是单例）：1000 次「gal_cb_begin + gal_commit」计时，提交后等这次栅栏做完再进下一次，
// 这样每支量到的都是纯 CPU 的「建命令缓冲 + 提交」，不含等 GPU；Metal 4 的 8 个分配器也不会因排队反压而混进计时。
// 同时核：栅栏值严格递增、每次都能等到（两条路同一套 g_gev 栅栏）。
#include "../gal_abi.h"
#include "../gal_be.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>

static int cmp_u64(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : (x > y); }

static int run_child(const char *expect) {
    int rc = nxgal_init(0);
    if (rc) { printf("初始化失败 %d\n", rc); return 2; }
    int want3 = !strcmp(expect, "mtl3");
    if (gal_be_kind() != (want3 ? GAL_BE_MTL3 : GAL_BE_MTL4)) { printf("后端 %d 与期望 %d 不符\n", gal_be_kind(), want3 ? GAL_BE_MTL3 : GAL_BE_MTL4); return 2; }
    enum { N = 1000, WARM = 50 };
    static uint64_t ns[N];
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    uint64_t prev = 0;
    for (int i = 0; i < WARM + N; i++) {
        uint64_t t0 = mach_absolute_time();
        gal_cb_begin(); uint64_t f = gal_commit();
        uint64_t t1 = mach_absolute_time();
        if (i >= WARM) ns[i - WARM] = (t1 - t0) * tb.numer / tb.denom;
        if (f <= prev) { printf("栅栏没递增：%llu ≤ %llu\n", (unsigned long long)f, (unsigned long long)prev); return 2; }
        prev = f;
        gal_wait(f);
    }
    qsort(ns, N, sizeof ns[0], cmp_u64);
    uint64_t sum = 0; for (int i = 0; i < N; i++) sum += ns[i];
    printf("  · 后端 %d：建缓冲 + 提交 CPU 中位 %.2f µs，p90 %.2f µs，均值 %.2f µs（%d 次）\n",
           gal_be_kind(), ns[N / 2] / 1e3, ns[N * 9 / 10] / 1e3, sum / (double)N / 1e3, (int)N);
    const char *out = getenv("T_M3SUBMIT_OUT");
    if (out) { FILE *o = fopen(out, "w"); if (o) { fprintf(o, "%d %.1f\n", gal_be_kind(), ns[N / 2] / 1e3); fclose(o); } }
    return 0;
}

// 父进程：起一个子进程跑一支，日志照抄，中位数从子进程写的文件读回来
static double run_case(const char *title, const char *be, const char *expect, int idx) {
    printf("· %s\n", title);
    char self[4096]; uint32_t sz = sizeof self;
    if (_NSGetExecutablePath(self, &sz)) { printf("  ✗ 取本可执行文件路径失败\n"); return 0; }
    char log[4096], out[4096];
    snprintf(log, sizeof log, "%s/t_m3submit_%d.log", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", idx);
    snprintf(out, sizeof out, "%s/t_m3submit_%d.out", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", idx);
    unlink(out);
    int fd = open(log, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd < 0) { printf("  ✗ 建日志失败\n"); return 0; }
    pid_t pid = fork();
    if (pid == 0) {
        dup2(fd, 1); dup2(fd, 2); close(fd);
        if (be) setenv("NXGAL_BE", be, 1); else unsetenv("NXGAL_BE");
        setenv("T_M3SUBMIT_OUT", out, 1);
        execl(self, self, "--child", expect, (char *)NULL);
        _exit(127);
    }
    close(fd);
    int st = 0; waitpid(pid, &st, 0);
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
    char all[8192] = {0}; size_t tot = 0; FILE *f = fopen(log, "r");
    if (f) { size_t n; while ((n = fread(all + tot, 1, sizeof all - 1 - tot, f)) > 0) tot += n; all[tot] = 0; fclose(f); }
    unlink(log);
    { char *p = all, *q; while (p && *p) { if ((q = strchr(p, (int)(char)10))) *q = 0; printf("    %s\n", p); p = q ? q + 1 : NULL; } }
    if (code) { printf("  ✗ 子进程退出码 %d\n", code); return 0; }
    double med = 0; int be_kind = 0;
    f = fopen(out, "r"); if (f) { if (fscanf(f, "%d %lf", &be_kind, &med) != 2) med = 0; fclose(f); }
    unlink(out);
    return med;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc >= 3 && !strcmp(argv[1], "--child")) return run_child(argv[2]);
    double m4 = run_case("不设 NXGAL_BE：Metal 4 主路径", NULL, "mtl4", 1);
    double m3 = run_case("NXGAL_BE=mtl3：Metal 3 兼容路径", "mtl3", "mtl3", 2);
    int fail = (m4 <= 0) || (m3 <= 0);
    if (!fail) printf("· 中位数：Metal 3 %.2f µs / Metal 4 %.2f µs（比值 %.2f×，同一台 Mac 同一口径）\n", m3, m4, m4 > 0 ? m3 / m4 : 0.0);
    printf("%s：%d / %d 项通过\n", fail ? "失败" : "通过", fail ? 0 : 3, 3);
    return fail ? 1 : 0;
}

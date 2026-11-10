// 帧率上限取值（graphics/nvn/gfx/nvn/nvn_fps.c，直连三后端与浮层共用的口径）。期望值全部手算。
//   ① 纯函数 nvn_fps_parse：0、24–1000 的十进制整数认；其它（空、负号、空格、尾随字符、越界、前导 + 号）不认
//   ② 起局读环境一次：每个取值单独起一个子进程，坏值必须退出（abort），好值的周期 = max(原周期, 1/上限)
//   负对照：把 nvn_fps_parse 改回只认 0/30/60/120，① 的 144 / 165 / 240 / 24 / 1000 与 ② 的 144 起局都应红
#include "../gfx/nvn/nvn_fps.h"
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int g_bad, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_bad++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static char g_exe[4096];

static int env_self(const char *v) {
    if (v) setenv("S2A_FPS", v, 1); else unsetenv("S2A_FPS");
    printf("limit=%d p0=%.9f p60=%.9f\n", nvn_fps_limit(), nvn_fps_period(0), nvn_fps_period(1.0 / 60));
    return 0;
}
static int env_probe(const char *v, int *limit, double *p0, double *p60) {
    int fd[2]; if (pipe(fd)) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        close(fd[0]); dup2(fd[1], STDOUT_FILENO); close(fd[1]);
        int null = open("/dev/null", O_WRONLY); if (null >= 0) dup2(null, STDERR_FILENO);
        char *a[4] = {"t_nvn_fps", "--env", (char *)v, NULL};
        execv(g_exe, a); _exit(97);
    }
    close(fd[1]); char buf[256] = {0}; ssize_t n = read(fd[0], buf, sizeof buf - 1); close(fd[0]);
    int st = 0; waitpid(pid, &st, 0);
    if (n <= 0 || !WIFEXITED(st) || WEXITSTATUS(st)) return -1;
    return sscanf(buf, "limit=%d p0=%lf p60=%lf", limit, p0, p60) == 3 ? 0 : -1;
}
static void env_ok(const char *v, int el, double ep0, double ep60) {
    int l = -9; double p0 = -9, p60 = -9; int rc = env_probe(v, &l, &p0, &p60);
    CHECK(rc == 0 && l == el && fabs(p0 - ep0) < 1e-9 && fabs(p60 - ep60) < 1e-9,
          "起局 S2A_FPS=%s：期望 上限%d 周期(0)=%.6f 周期(1/60)=%.6f；实得 返回%d 上限%d %.6f %.6f", v ? v : "（未设）", el, ep0, ep60, rc, l, p0, p60);
}
static void env_dies(const char *v) {
    int l; double a, b;
    CHECK(env_probe(v, &l, &a, &b) == -1, "起局 S2A_FPS=%s：坏值必须退出", v);
}

int main(int argc, char **argv) {
    if (!realpath(argv[0], g_exe)) snprintf(g_exe, sizeof g_exe, "%s", argv[0]);
    if (argc >= 2 && !strcmp(argv[1], "--env")) return env_self(argc >= 3 ? argv[2] : NULL);

    // ①
    static const struct { const char *v; int e; } P[] = {
        {"0", 0}, {"30", 30}, {"60", 60}, {"120", 120}, {"24", 24}, {"144", 144}, {"165", 165}, {"240", 240}, {"1000", 1000}, {"075", 75},
        {"", -1}, {"23", -1}, {"1001", -1}, {"-1", -1}, {"+60", -1}, {" 60", -1}, {"60 ", -1}, {"30abc", -1}, {"display", -1}, {"00000060", -1}, {"9999", -1},
    };
    for (size_t i = 0; i < sizeof P / sizeof *P; i++) {
        int got = nvn_fps_parse(P[i].v);
        CHECK(got == P[i].e, "nvn_fps_parse(\"%s\")：期望 %d，实得 %d", P[i].v, P[i].e, got);
    }
    CHECK(nvn_fps_parse(NULL) == -1, "nvn_fps_parse(NULL)：期望 -1");

    // ② 周期：上限只把周期拉长；60 帧的周期在 ≥ 60 的上限下原样
    env_ok(NULL, 0, 0, 1.0 / 60);
    env_ok("0", 0, 0, 1.0 / 60);
    env_ok("30", 30, 1.0 / 30, 1.0 / 30);
    env_ok("120", 120, 1.0 / 120, 1.0 / 60);
    env_ok("144", 144, 1.0 / 144, 1.0 / 60);
    env_ok("24", 24, 1.0 / 24, 1.0 / 24);
    env_ok("1000", 1000, 1.0 / 1000, 1.0 / 60);
    env_dies("12");
    env_dies("30abc");
    env_dies("1001");

    printf("%s t_nvn_fps：帧率上限取值 %d 项 → %s\n", g_bad ? "✗" : "✓", g_n, g_bad ? "有不符合项" : "全过");
    return g_bad != 0;
}

// 单测 t_m3be：选路径与初始化（卡 M3-4 / #111；gal_be.h 表中「选路径」「驻留」两行）。
// 一个进程只初始化一次（nxgal_init 是单例），所以三种情形各起一个子进程（自己 exec 自己，期望由命令参数给）：
//   ① 不设 NXGAL_BE：GAL_BE_MTL4 + Metal 4 主队列 + 驻留集 + Metal 4 编译器，日志里不该出现「后端：Metal 3」；
//   ② NXGAL_BE=mtl3：GAL_BE_MTL3 + 普通 MTLCommandQueue + 同一个驻留集挂上去，不建 Metal 4 主队列与编译器，日志有「后端：Metal 3（强制）」；
//   ③ NXGAL_BE=mtl4（非 mtl3 的取值）：与 ① 相同（只有 mtl3 才强制）。
// 另核 nxgal_init 可重复调用（第二次仍返回 0）。
#include "../gal_abi.h"
#include "../gal_be.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

void nxgal_test_be(int32_t out[5]);   // gal_core.m 单测钩子：这次初始化选的后端与建出来的对象

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// 子进程：真初始化一次，按期望核后端与对象形态
static int run_child(const char *expect) {
    int32_t s[5] = {0};
    int want3 = !strcmp(expect, "mtl3");
    int r = nxgal_init(0);
    CHECK(r == 0, "nxgal_init 返回 %d（期望 0）", r);
    if (r) return 1;
    nxgal_test_be(s);
    CHECK(s[0] == (want3 ? GAL_BE_MTL3 : GAL_BE_MTL4), "后端 %d ≠ 期望 %d", s[0], want3 ? GAL_BE_MTL3 : GAL_BE_MTL4);
    CHECK(s[1] == (want3 ? 1 : 0), "Metal 3 主队列 建/未建 = %d（期望 %d）", s[1], want3 ? 1 : 0);
    CHECK(s[2] == (want3 ? 0 : 1), "Metal 4 主队列 建/未建 = %d（期望 %d）", s[2], want3 ? 0 : 1);
    CHECK(s[3] == 1, "驻留集未建（两边都要有）");
    CHECK(s[4] == (want3 ? 0 : 1), "Metal 4 编译器 建/未建 = %d（期望 %d）", s[4], want3 ? 0 : 1);
    CHECK(nxgal_init(0) == 0, "重复调用 nxgal_init 不返回 0");
    printf("  · 后端 %d；Metal 3 队列 %d；Metal 4 队列 %d；驻留集 %d；编译器 %d\n", s[0], s[1], s[2], s[3], s[4]);
    return g_fail ? 1 : 0;
}

// 父进程：起一个子进程跑一遍初始化，把它的日志原样打出来并按期望核
static void run_case(const char *title, const char *be, const char *expect, int discrete) {
    printf("· %s\n", title);
    char self[4096]; uint32_t sz = sizeof self;
    if (_NSGetExecutablePath(self, &sz)) { g_checks++; g_fail++; printf("  ✗ 取本可执行文件路径失败\n"); return; }
    char log[4096]; snprintf(log, sizeof log, "%s/t_m3be_%d.log", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", discrete);
    int fd = open(log, O_CREAT | O_TRUNC | O_WRONLY, 0644); if (fd < 0) { g_checks++; g_fail++; printf("  ✗ 建日志失败：%s\n", log); return; }
    pid_t pid = fork();
    if (pid == 0) {
        dup2(fd, 1); dup2(fd, 2); close(fd);
        if (be) setenv("NXGAL_BE", be, 1); else unsetenv("NXGAL_BE");
        execl(self, self, "--child", expect, (char *)NULL);
        _exit(127);
    }
    close(fd);
    int st = 0; waitpid(pid, &st, 0);
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
    // 子进程日志照抄（带缩进），父进程的判据行跟在后面
    char all[8192] = {0}; size_t tot = 0;
    FILE *f = fopen(log, "r");
    if (f) { size_t n; while ((n = fread(all + tot, 1, sizeof all - 1 - tot, f)) > 0) tot += n; all[tot] = 0; fclose(f); }
    unlink(log);
    { char *p = all, *q; while (p && *p) { if ((q = strchr(p, '\n'))) *q = 0; printf("    %s\n", p); p = q ? q + 1 : NULL; } }
    CHECK(code == 0, "子进程退出码 %d（期望 0）：初始化或对象形态不符", code);
    // 强制开关的日志行只在真强制时出现（26 上 NXGAL_BE=mtl3）；缺省两支不该出现「后端：Metal 3」
    if (be && !strcmp(be, "mtl3")) CHECK(strstr(all, "后端：Metal 3（强制）") != NULL, "日志缺「后端：Metal 3（强制）」一行");
    else CHECK(strstr(all, "后端：Metal 3") == NULL, "缺省路径的日志不该出现「后端：Metal 3」");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc >= 3 && !strcmp(argv[1], "--child")) return run_child(argv[2]);
    run_case("不设 NXGAL_BE（26 起缺省）：Metal 4 主路径", NULL, "mtl4", 1);
    run_case("NXGAL_BE=mtl3（26 上强制）：Metal 3 兼容路径", "mtl3", "mtl3", 2);
    run_case("NXGAL_BE=mtl4（非 mtl3 的取值）：仍走缺省 Metal 4", "mtl4", "mtl4", 3);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}

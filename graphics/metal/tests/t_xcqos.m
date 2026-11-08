// 首遇现编作业的线程 QoS（gal_prog.m xc_init，10-28 喷3 冷局第 42 帧「停帧」根因）：渲染线程（UI）在 SetProgram / 首用处阻塞等现编作业，
//   作业原先跑在 UTILITY = 优先级反转，宿主一忙就被饿住（Air 陪跑同场冷局单支最长 13 秒、加载帧 22–26 秒；Mac 负载 16 时加载帧超 60 秒被自动玩家判停帧）。
// 走产品的 xjob_start（去重 / 槽 / 工作队列，gal_xc_bench_start / collect），读作业实际跑在的线程的 qos_class_self()。
// 期望（按 <sys/qos.h> 常量，不跑被测实现即可写出）：
//   缺省（不设 NXGAL_XC_QOS）→ QOS_CLASS_USER_INITIATED = 0x19，编译成功；
//   子进程 NXGAL_XC_QOS=utility → QOS_CLASS_UTILITY = 0x11（显式回旧档仍有效）。
// 反证（旧缺省 UTILITY）：第一项实得 0x11。
#import <Foundation/Foundation.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/qos.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
GAL_MTL4_ZONE_BEGIN
void *gal_xc_bench_start(const void *spv, uint32_t len);
int gal_xc_bench_collect(void *job, double *xc_ms, double *mtl_ms, int *from_disk, uint32_t *qos, uint32_t *active, char *why);
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// 起一支现编作业，回显作业线程的 QoS；编译失败回 0
static uint32_t job_qos(const char *exe) {
    char p[1200]; snprintf(p, sizeof p, "%s/t_fbr_in/vs.spv", dirname((char *)exe));
    NSData *d = [NSData dataWithContentsOfFile:@(p)]; if (!d) { printf("读不了 %s\n", p); exit(2); }
    void *j = gal_xc_bench_start(d.bytes, (uint32_t)d.length);
    double xc, mt; int disk; uint32_t qos = 0, act; char why[256] = "";
    int ok = gal_xc_bench_collect(j, &xc, &mt, &disk, &qos, &act, why);
    if (!ok) printf("  现编失败：%s\n", why);
    return ok ? qos : 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]);
    char cd[] = "/tmp/t_xcqos.XXXXXX"; if (!mkdtemp(cd)) return 2; setenv("NXGAL_SHADER_CACHE_DIR", cd, 1);   // 新空缓存：必须现编
    if (nxgal_init(0)) return 2;
    char rm[256]; snprintf(rm, sizeof rm, "rm -rf '%s'", cd);
    if (argc > 1 && !strcmp(argv[1], "--child")) { uint32_t q = job_qos(exe); nxgal_shutdown(); system(rm); printf("  子进程作业线程 QoS 0x%x\n", q); return q == QOS_CLASS_UTILITY ? 0 : 1; }

    printf("· 缺省（不设 NXGAL_XC_QOS）：作业线程 QoS 期望 USER_INITIATED 0x%x\n", QOS_CLASS_USER_INITIATED);
    unsetenv("NXGAL_XC_QOS");
    uint32_t q = job_qos(exe);
    CHECK(q == QOS_CLASS_USER_INITIATED, "缺省作业线程 QoS 期望 0x%x，实得 0x%x（0x%x = 旧缺省 UTILITY，渲染线程等它时优先级反转；0 = 现编失败）",
          QOS_CLASS_USER_INITIATED, q, QOS_CLASS_UTILITY);
    nxgal_shutdown();

    printf("· 子进程 NXGAL_XC_QOS=utility：作业线程 QoS 期望 UTILITY 0x%x\n", QOS_CLASS_UTILITY);
    setenv("NXGAL_XC_QOS", "utility", 1);
    char *cargv[] = {exe, "--child", NULL}; pid_t pid; int st = -1;
    int rc = posix_spawn(&pid, exe, NULL, NULL, cargv, environ);
    if (!rc) waitpid(pid, &st, 0);
    CHECK(!rc && WIFEXITED(st) && WEXITSTATUS(st) == 0, "显式 utility 期望作业线程 0x%x，子进程退出 %d（spawn %d）", QOS_CLASS_UTILITY, WIFEXITED(st) ? WEXITSTATUS(st) : -1, rc);

    system(rm);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END

// 提交线程的调度档（11-06 Switch2 线 71）：提交线程是一帧的关键路径，不管它在游戏里是主线程还是别的线程。
//   iPhone（性能核 2 个）上 runtime/src/thread.c 给游戏主线程以外的线程 USER_INITIATED；游戏从这种线程提交、内核又撤了取图线程的实时声明时，
//   翻译 + 编码整段落到能效核（时之笛 Duo 11-06：上屏线程 QoS 0x19、实时策略不在、进程 CPU 0% 在性能核、平均主频 1.49 GHz、提交 CPU 13.8 ms/帧）。
// 期望值按规则写死（不跑被测实现推）：
//   ① USER_INITIATED 的线程提交一次 → 读回 USER_INTERACTIVE
//   ② UTILITY 的线程提交一次 → 读回 USER_INTERACTIVE
//   ③ USER_INTERACTIVE 的线程提交 → 仍 USER_INTERACTIVE
//   ④ 已有实时策略的线程提交 → 实时策略仍在（不被提档弄掉）
//   ⑤ 负对照（开关）：DM_NVN_RENDER_QOS=0 重起本程序，USER_INITIATED 的线程提交后仍 USER_INITIATED
//   ⑥ 全进程一张表（runtime/include/s2a_qos.h）按取值原则：一帧关键路径（提交 / 编码 / 影子拷贝 / 上屏 / 完成回调 / 游戏主线程）USER_INTERACTIVE；
//      预取 / 预热不落 UTILITY（能效核上慢约 4 倍，卡顿线实测）；其余游戏线程性能核 ≥ 4 时 USER_INTERACTIVE、否则 USER_INITIATED
#include "nvn_protos.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include "s2a_qos.h"

extern void *h_nvnBootstrapLoader(const char *name);
static void *load(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { printf("找不到公开 API：%s\n", n); exit(1); } return p; }
#define API(name) ((NVNT_##name)load(#name))
static NVNdevice g_dev; static NVNqueue g_q;
static int bad, checks;

static int rt_live(void) {
    thread_time_constraint_policy_data_t tp; mach_msg_type_number_t c = THREAD_TIME_CONSTRAINT_POLICY_COUNT; boolean_t d = 0;
    return thread_policy_get(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&tp, &c, &d) == KERN_SUCCESS && !d;
}
typedef struct { qos_class_t start; int rt; qos_class_t got; int rt_after; } job;
static void *body(void *a) {
    job *j = a;
    if (j->rt) {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb); uint32_t per = (uint32_t)(16666667ull * tb.denom / tb.numer);
        thread_time_constraint_policy_data_t p = {per, per / 2, per, 1};
        thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    } else pthread_set_qos_class_self_np(j->start, 0);
    API(nvnQueueSubmitCommands)(&g_q, 0, NULL);
    int rp = 0; pthread_get_qos_class_np(pthread_self(), &j->got, &rp); j->rt_after = rt_live();
    return NULL;
}
static job run(qos_class_t q, int rt) { job j = {q, rt, QOS_CLASS_UNSPECIFIED, 0}; pthread_t t; pthread_create(&t, NULL, body, &j); pthread_join(t, NULL); return j; }
static void want(const char *step, int ok, const job *j) { checks++; if (!ok) { bad++; printf("✗ %s：读回 QoS %#x、实时 %d\n", step, (unsigned)j->got, j->rt_after); } }

int main(int argc, char **argv) {
    int off = argc > 1 && !strcmp(argv[1], "--off");
    int fd = open("/dev/null", 1); int saved = dup(2); dup2(fd, 2); close(fd);   // 后端日志不进单测输出
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); API(nvnDeviceInitialize)(&g_dev, &db);
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &g_dev);
    if (!API(nvnQueueInitialize)(&g_q, &qb)) { dprintf(saved, "QueueInitialize 失败\n"); return 1; }
    if (off) {   // ⑤ 子进程：开关关
        job j = run(QOS_CLASS_USER_INITIATED, 0);
        dup2(saved, 2); printf("%s\n", j.got == QOS_CLASS_USER_INITIATED ? "OFF_KEPT" : "OFF_RAISED"); return 0;
    }
    job j;
    j = run(QOS_CLASS_USER_INITIATED, 0); want("① USER_INITIATED 线程提交后提到 USER_INTERACTIVE", j.got == QOS_CLASS_USER_INTERACTIVE, &j);
    j = run(QOS_CLASS_UTILITY, 0);        want("② UTILITY 线程提交后提到 USER_INTERACTIVE", j.got == QOS_CLASS_USER_INTERACTIVE, &j);
    j = run(QOS_CLASS_USER_INTERACTIVE, 0); want("③ USER_INTERACTIVE 线程提交后不变", j.got == QOS_CLASS_USER_INTERACTIVE, &j);
    j = run(QOS_CLASS_UNSPECIFIED, 1);    want("④ 实时线程提交后实时策略仍在", j.rt_after == 1, &j);
    {   // ⑥
        static const s2a_qos_role crit[] = {S2A_QOS_SUBMIT, S2A_QOS_ENCODE, S2A_QOS_UB_COPY, S2A_QOS_PRESENT, S2A_QOS_MTL_FEEDBACK, S2A_QOS_GAME_MAIN};
        for (size_t i = 0; i < sizeof crit / sizeof *crit; i++) { checks++; if (s2a_qos(crit[i]) != QOS_CLASS_USER_INTERACTIVE) { bad++; printf("✗ ⑥ 关键路径角色 %d 不是 USER_INTERACTIVE（%#x）\n", (int)crit[i], (unsigned)s2a_qos(crit[i])); } }
        static const s2a_qos_role bg[] = {S2A_QOS_SHADER_PREFETCH};   // 后台预热工人的档在 nvn_mtl.m WARM_BG_QOS（卡顿线），不在本表
        for (size_t i = 0; i < sizeof bg / sizeof *bg; i++) { checks++; if (s2a_qos(bg[i]) == QOS_CLASS_UTILITY || s2a_qos(bg[i]) == QOS_CLASS_BACKGROUND) { bad++; printf("✗ ⑥ 预取 / 预热角色 %d 落在 UTILITY 以下\n", (int)bg[i]); } }
        int pc = 0; size_t sz = sizeof pc; if (sysctlbyname("hw.perflevel0.physicalcpu", &pc, &sz, NULL, 0) || pc <= 0) { sz = sizeof pc; sysctlbyname("hw.physicalcpu", &pc, &sz, NULL, 0); }
        checks++; if (s2a_qos(S2A_QOS_GAME_OTHER) != (pc >= 4 ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_USER_INITIATED)) { bad++; printf("✗ ⑥ 其余游戏线程档与性能核 %d 个不符\n", pc); }
    }
    dup2(saved, 2);
    {   // ⑤ 开关负对照：DM_NVN_RENDER_QOS=0 起子进程
        char cmd[2048]; snprintf(cmd, sizeof cmd, "DM_NVN_RENDER_QOS=0 '%s' --off", argv[0]);
        FILE *p = popen(cmd, "r"); char line[64] = ""; if (p) { if (!fgets(line, sizeof line, p)) line[0] = 0; pclose(p); }
        checks++; if (strncmp(line, "OFF_KEPT", 8)) { bad++; printf("✗ ⑤ DM_NVN_RENDER_QOS=0 时 USER_INITIATED 线程应不变，子进程报「%.*s」\n", (int)strcspn(line, "\n"), line); }
    }
    printf("%s t_nvn_render_qos：提交线程提到 USER_INTERACTIVE、实时线程不动、开关可关、全进程调度档表合原则（%d 项）→ %s\n", bad ? "✗" : "✓", checks, bad ? "有不符合项" : "通过");
    return bad ? 1 : 0;
}

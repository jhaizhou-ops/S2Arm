// 队列内存记账（#270 N12 Queue 组）：nvnQueueGetTotal{Command,Control,Compute}MemoryUsed 报的是
// 「这个队列当前被游戏放进来的内存」——来源是 builder 上的 SetQueueMemory / SetControlMemorySize / SetComputeMemorySize，
// ResetMemoryUsageCounts 之后从 0 重新累计。本测走生产 bootstrap 拿真函数指针（不初始化 GPU）：
//   · 未设置控制 / 计算内存时 getter 报 0；
//   · 给过就按字节原样报；
//   · Reset 之后三项都回 0，队列对象仍可用（Finalize 正常）。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;

static void *api(const char *n) {
    void *p = h_nvnBootstrapLoader(n);
    if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; }
    return p;
}
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)

#define API(type, var, name) type var = (type)api(#name)

int main(void) {
    API(NVNT_nvnQueueBuilderSetDefaults, setDefaults, nvnQueueBuilderSetDefaults);
    API(NVNT_nvnQueueBuilderSetQueueMemory, setMem, nvnQueueBuilderSetQueueMemory);
    API(NVNT_nvnQueueBuilderSetControlMemorySize, setCtl, nvnQueueBuilderSetControlMemorySize);
    API(NVNT_nvnQueueBuilderSetComputeMemorySize, setComp, nvnQueueBuilderSetComputeMemorySize);
    API(NVNT_nvnQueueInitialize, init, nvnQueueInitialize);
    API(NVNT_nvnQueueGetTotalCommandMemoryUsed, cmd, nvnQueueGetTotalCommandMemoryUsed);
    API(NVNT_nvnQueueGetTotalControlMemoryUsed, ctl, nvnQueueGetTotalControlMemoryUsed);
    API(NVNT_nvnQueueGetTotalComputeMemoryUsed, comp, nvnQueueGetTotalComputeMemoryUsed);
    API(NVNT_nvnQueueResetMemoryUsageCounts, reset, nvnQueueResetMemoryUsageCounts);
    API(NVNT_nvnQueueFinalize, fini, nvnQueueFinalize);
    if (bad) return 1;

    union { NVNqueueBuilder b; char raw[256]; } builder;
    NVNqueue queue;
    memset(&builder, 0, sizeof builder);
    memset(&queue, 0, sizeof queue);

    // ① 什么都不设：三项都应为 0
    setDefaults(&builder.b);
    CHECK(init(&queue, &builder.b), "QueueInitialize 返回假");
    CHECK(cmd(&queue) == 0, "未设置命令内存时 GetTotalCommandMemoryUsed=%zu（应 0）", cmd(&queue));
    CHECK(ctl(&queue) == 0, "未设置控制内存时 GetTotalControlMemoryUsed=%zu（应 0）", ctl(&queue));
    CHECK(comp(&queue) == 0, "未设置计算内存时 GetTotalComputeMemoryUsed=%zu（应 0）", comp(&queue));
    fini(&queue);

    // ② 三项都给：getter 按字节原样报（命令内存来自 SetQueueMemory 的内存块大小）
    static char qmem[0x3000];
    memset(&queue, 0, sizeof queue);
    setDefaults(&builder.b);
    setMem(&builder.b, qmem, sizeof qmem);
    setCtl(&builder.b, 0x400);
    setComp(&builder.b, 0x800);
    CHECK(init(&queue, &builder.b), "QueueInitialize 返回假");
    CHECK(cmd(&queue) == sizeof qmem, "GetTotalCommandMemoryUsed=%zu（应为 %zu）", cmd(&queue), sizeof qmem);
    CHECK(ctl(&queue) == 0x400, "GetTotalControlMemoryUsed=%zu（应为 0x400）", ctl(&queue));
    CHECK(comp(&queue) == 0x800, "GetTotalComputeMemoryUsed=%zu（应为 0x800）", comp(&queue));

    // ③ Reset：三项归零，队列仍可用
    reset(&queue);
    CHECK(cmd(&queue) == 0 && ctl(&queue) == 0 && comp(&queue) == 0,
          "Reset 后应为 0/0/0，实得 %zu/%zu/%zu", cmd(&queue), ctl(&queue), comp(&queue));
    fini(&queue);

    printf("%s t_nvn_queue：命令/控制/计算三项记账与 Reset → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}

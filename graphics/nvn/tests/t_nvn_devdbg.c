// Device 调试接口组（#270 N12）：只保状态与查询，不改渲染行为。
//   · GenerateDebugDomainId：单调唯一（两次不同且递增）；
//   · IsExternalDebuggerAttached：本层没有 attach 通道 → 恒 0；
//   · SetDebugLabel：设备 magic 正确时记住指针、读回一致；magic 不对时不写（不碰别人的内存）；
//   · WalkDebugDatabase：本层没有对象注册表 → 一次都不回调；
//   · ApplyDeferredFinalizes + 6 个检查点开关：可调用、不崩（空实现，各自点名一次）。
#include "../gfx/nvn/nvn_obj.h"
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad, walked;
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; } return p; }
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
static void walk_cb(void *ud, void *obj) { (void)ud; (void)obj; walked++; }

int main(void) {
    NVNT_nvnDeviceGenerateDebugDomainId id = (NVNT_nvnDeviceGenerateDebugDomainId)api("nvnDeviceGenerateDebugDomainId");
    NVNT_nvnDeviceIsExternalDebuggerAttached ext = (NVNT_nvnDeviceIsExternalDebuggerAttached)api("nvnDeviceIsExternalDebuggerAttached");
    NVNT_nvnDeviceSetDebugLabel label = (NVNT_nvnDeviceSetDebugLabel)api("nvnDeviceSetDebugLabel");
    NVNT_nvnDeviceWalkDebugDatabase walk = (NVNT_nvnDeviceWalkDebugDatabase)api("nvnDeviceWalkDebugDatabase");
    NVNT_nvnDeviceApplyDeferredFinalizes apply = (NVNT_nvnDeviceApplyDeferredFinalizes)api("nvnDeviceApplyDeferredFinalizes");
    if (bad) return 1;

    union { NVNdevice d; char raw[0x3000]; } dev;
    memset(&dev, 0, sizeof dev);

    // ① 域号：两次不同、第二次更大
    NVNdebugDomainId a = id(&dev.d, "domainA"), b = id(&dev.d, "domainB");
    CHECK(a != b && b > a, "GenerateDebugDomainId 不单调唯一：%d vs %d", a, b);

    // ② 外部调试器：恒 0
    CHECK(ext(&dev.d) == 0, "IsExternalDebuggerAttached 应为 0");

    // ③ 标签：magic 不对时不写（避免写坏别人的内存）
    dev_t_ *o = (dev_t_ *)&dev.d;
    label(&dev.d, "before-magic");
    CHECK(o->dbg_label == NULL, "magic 未设时不该写 dbg_label（实得 %p）", (void *)o->dbg_label);
    // magic 正确时记住并可读回
    o->magic = MAGIC('D', 'E', 'V', 0);
    label(&dev.d, "after-magic");
    CHECK(o->dbg_label && !strcmp(o->dbg_label, "after-magic"), "SetDebugLabel 后读回不一致：%s", o->dbg_label ? o->dbg_label : "(null)");

    // ④ 调试库遍历：一次都不回调
    walked = 0;
    walk(&dev.d, 0, walk_cb, NULL);
    CHECK(walked == 0, "WalkDebugDatabase 回调了 %d 次（本层没有对象库，应为 0）", walked);

    // ⑤ 延迟 finalize + 6 个检查点开关：可调用、不崩
    apply(&dev.d, 2);
    void (*ck[6])(NVNdevice *, int) = {
        (void (*)(NVNdevice *, int))api("nvnDeviceSetAutomaticCheckpointsEnable"),
        (void (*)(NVNdevice *, int))api("nvnDeviceSetAutomaticCheckpointsSamplingInterval"),
        (void (*)(NVNdevice *, int))api("nvnDeviceSetAutomaticCheckpointsByDebugGroup"),
        (void (*)(NVNdevice *, int))api("nvnDeviceSetCheckpointCallStacksEnable"),
        (void (*)(NVNdevice *, int))api("nvnDeviceSetCheckpointMaxCallStacksDepth"),
    };
    for (int i = 0; i < 5; i++) CHECK(ck[i] != NULL, "检查点开关 %d 没有实现", i);
    void (*mask)(NVNdevice *, uint64_t) = (void (*)(NVNdevice *, uint64_t))api("nvnDeviceSetAutomaticCheckpointsMask");
    CHECK(mask != NULL, "SetAutomaticCheckpointsMask 没有实现");
    for (int i = 0; i < 5; i++) ck[i](&dev.d, 1);
    mask(&dev.d, 0xF);

    printf("%s t_nvn_devdbg：域号单调唯一、外部调试器恒 0、标签写入受 magic 保护、遍历零回调、检查点开关可调用 → %s\n",
           bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}

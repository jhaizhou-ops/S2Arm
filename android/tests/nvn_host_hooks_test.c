// 宿主钩子接线（真机自测）：dm_* 三个入口必须接到真实 dispatcher，而不是弱空函数。
// 依赖：nvn_host_hooks.c + runtime/src/direct_host.c + 本测试里的 track 桩。
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "s2a_direct_host.h"
#include "graphics/nvn/host/dm.h"
// 缺页派发入口（crash.c 的信号处理里也是这样本地声明的）
extern int s2a_direct_fault(void *addr, int is_write, void *uctx);

// ---- graphics/track 桩：只记录登记与写入口调用，模拟真实模块的唯一 prep 回调 ----
static void (*g_wprep)(uint64_t, uint64_t);
static int g_quiet_calls; static uint64_t g_quiet_addr, g_quiet_len;
void s2a_track_set_write_prep(void (*fn)(uint64_t, uint64_t)) { g_wprep = fn; }
void s2a_track_write_quiet(uint64_t addr, uint64_t size) { g_quiet_calls++; g_quiet_addr = addr; g_quiet_len = size; }

static int g_fault_calls, g_fault_write; static void *g_fault_addr;
static int on_fault(void *addr, int is_write, void *uctx) { (void)uctx; g_fault_calls++; g_fault_addr = addr; g_fault_write = is_write; return 1; }
static int g_prep_calls; static void *g_prep_addr; static size_t g_prep_len;
static void on_prep(void *addr, size_t len) { g_prep_calls++; g_prep_addr = addr; g_prep_len = len; }

int main(void) {
    int ok = 1;
    char page[4096] __attribute__((aligned(4096)));
    memset(page, 0, sizeof page);

    // 1) 缺页钩子：dm 登记 → s2a_direct_fault 派发到同一个回调
    dm_fault_hook_register(on_fault);
    ok &= s2a_direct_fault(page, 1, NULL) == 1;
    ok &= (g_fault_calls == 1) && (g_fault_addr == page) && (g_fault_write == 1);

    // 2) 写前通知：dm 登记 → track 的唯一 prep 回调 → 桥接 → dm 回调（签名与范围不丢）
    dm_guest_write_prep_register(on_prep);
    ok &= (g_wprep != NULL);
    if (g_wprep) g_wprep((uint64_t)(uintptr_t)page + 8, 24);
    ok &= (g_prep_calls == 1) && (g_prep_addr == page + 8) && (g_prep_len == 24);

    // 3) 宿主写 guest 内存前：dm_guest_write_prepare 必须走真实写入口
    dm_guest_write_prepare(page + 16, 32);
    ok &= (g_quiet_calls == 1) && (g_quiet_addr == (uint64_t)(uintptr_t)(page + 16)) && (g_quiet_len == 32);

    // 4) 空回调/空范围不得误调用
    dm_guest_write_prepare(NULL, 8);
    dm_guest_write_prepare(page, 0);
    ok &= (g_quiet_calls == 1);

    printf("hooks: fault=%d prep=%d quiet=%d\n", g_fault_calls, g_prep_calls, g_quiet_calls);
    printf("nvn-host-hooks: %s\n", ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
}

// Android 生产目标：把共享前端/直连层用到的宿主名字（dm_*，graphics/nvn/host/dm.h）接到本线的真实 dispatcher。
// 之前生产链接里只有 vk_engine_host_shim.c 的弱空实现，nvn_dirty 的缺页钩子和写前通知都落空。
// 这里只登记，不安装任何信号处理器：缺页仍由 crash.c 的 on_crash 先问 s2a_direct_fault；
// 写前通知挂在 graphics/track 的唯一 prep 回调上（s2a_guest_write_prep_register 已转发给 track）。
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>
#include "s2a_direct_host.h"
#include "s2a_track.h"
#include "graphics/nvn/host/dm.h"

// dm 侧回调签名 (void *, size_t)，direct 侧登记的是 (uint64_t, uint64_t)：桥接保持两侧 ABI 不变。
static _Atomic(void (*)(void *, size_t)) g_dm_prep;

static void prep_bridge(uint64_t addr, uint64_t len) {
    void (*fn)(void *, size_t) = atomic_load_explicit(&g_dm_prep, memory_order_acquire);
    if (fn) fn((void *)(uintptr_t)addr, (size_t)len);
}

void dm_fault_hook_register(int (*fn)(void *addr, int is_write, void *uctx)) {
    s2a_fault_hook_register(fn);
}

void dm_guest_write_prep_register(void (*fn)(void *addr, size_t len)) {
    if (!fn) return;
    atomic_store_explicit(&g_dm_prep, fn, memory_order_release);
    s2a_guest_write_prep_register(prep_bridge);
}

void dm_guest_write_prepare(void *addr, size_t len) {
    if (!addr || !len) return;
    s2a_track_write_quiet((uint64_t)(uintptr_t)addr, (uint64_t)len);
}

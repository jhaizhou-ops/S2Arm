#include "runtime.h"
#include "registry.h"
#include "../../../../graphics/track/s2a_track.h"
#include "../../../../platform/plat.h"
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

// 缺真实provider时保留可诊断的未就绪；不得仅为通过符号门禁定义返回1的函数。
extern int s2a_android_fault_dispatch_ready(void) __attribute__((weak));
extern int s2a_android_fault_dispatch_installed(void) __attribute__((weak));
extern int s2a_android_tracking_vm_ready(void) __attribute__((weak));
static _Atomic int prepared;
static _Atomic int backing_busy;   // 在途替页：begin→end 整窗（checked store 提交按它返回 -EAGAIN）
static s2a_track_backing_before_fn backing_before;
static s2a_track_backing_after_fn backing_after;
static _Thread_local struct { uint64_t addr, size, source; int active, reset; } backing;

int s2a_track_backing_busy(void) { return atomic_load_explicit(&backing_busy, memory_order_acquire); }
static void backing_fatal(const char *reason) {
    fprintf(stderr, "[track] 【红】backing 生命周期违约：%s\n", reason);
    abort();
}
void s2a_track_set_backing_callbacks(s2a_track_backing_before_fn before, s2a_track_backing_after_fn after) {
    if (!before || !after) backing_fatal("回调缺失");
    if (atomic_exchange_explicit(&backing_busy, 1, memory_order_acquire)) backing_fatal("替页期间注册");
    if (backing_before || backing_after) backing_fatal("重复注册");
    backing_before = before; backing_after = after;
    atomic_store_explicit(&backing_busy, 0, memory_order_release);
}
int s2a_track_backing_begin(uint64_t addr, uint64_t size, uint64_t source) {
    size_t page = plat_page_size();
    if (!page || !size || addr % page || size % page || size > UINT64_MAX - addr
        || (source && (source % page || size > UINT64_MAX - source))) return EINVAL;
    if (atomic_exchange_explicit(&backing_busy, 1, memory_order_acquire)) return EBUSY;
    int error = s2a_track_registry_begin(addr, size, source);
    if (error) { atomic_store_explicit(&backing_busy, 0, memory_order_release); return error; }
    backing.addr = addr; backing.size = size; backing.source = source; backing.active = 1; backing.reset = 0;
    // 此事务标记只防并发替页，不是 VM/tracker 锁；回调可重入正常 write/reprotect。
    if (backing_before) backing_before(addr, size, source);
    return 0;
}
void s2a_track_backing_reset_before_publish(uint64_t addr, uint64_t size) {
    if (!backing.active || backing.addr != addr || backing.size != size) backing_fatal("reset 不匹配 begin");
    if (backing.reset) backing_fatal("重复 reset 后发布");
    // 在 mirror_end 翻回偶数之前把 tracker 记账清到新世代：翻偶数后 ESTALE 重试的写者拿到的别名
    // 已经是新页，此时若 lastp/act 还是旧值，前提复核会通过、旧 GPU 数据写进新换入的页（#1184 D1）。
    s2a_track_backing_reset(addr, size);
    backing.reset = 1;
}
void s2a_track_backing_end(uint64_t addr, uint64_t size, int mapped, int committed) {
    if (!backing.active || backing.addr != addr || backing.size != size || (mapped != 0 && mapped != 1) || (committed != 0 && committed != 1))
        backing_fatal("end 不匹配 begin");
    if (committed && backing.source && !mapped) backing_fatal("alias 提交没有真实映射");
    if (!backing.reset) s2a_track_backing_reset(addr, size);
    // 回滚保留旧关系；成功发布实际新关系。发布后after可在新单映射上建立GPU跟踪。
    s2a_track_registry_finish(committed);
    if (backing_after) backing_after(addr, size, mapped);
    backing.active = 0;
    atomic_store_explicit(&backing_busy, 0, memory_order_release);
}

int s2a_track_runtime_prepare(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&prepared, &expected, -1)) return EALREADY;
    s2a_track_prepare();
    // 当前Android fault adapter仅支持回写改道，尚未接入读/写指令模拟。
    // 先保证GPU脏数据的CPU读写都触发真实读回，不能借优化默认值读到旧数据。
    s2a_track_set_readflush(1);
    s2a_track_set_walias(1);
    s2a_track_set_emul(0);
    s2a_track_set_emul_store(0);
    atomic_store_explicit(&prepared, 1, memory_order_release);
    return 0;
}
int s2a_track_runtime_prepared(void) {
    if (atomic_load_explicit(&prepared, memory_order_acquire) != 1
        || !s2a_android_fault_dispatch_installed || !s2a_android_tracking_vm_ready) return 0;
    return s2a_android_fault_dispatch_installed() == 1 && s2a_android_tracking_vm_ready() == 1;
}
int s2a_track_runtime_ready(void) {
    return s2a_track_runtime_prepared() && s2a_android_fault_dispatch_ready && s2a_android_fault_dispatch_ready() == 1;
}

// Linux host: real svc_mem logical map, tracker, Linux shared alias and page
// protections. No Android guest threads or GPU execution is claimed.
#include "../../runtime/src/native.h"
#include "../../graphics/track/s2a_track.h"
#include "../../graphics/track/track_platform.h"
#include "../../platform/plat.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>

static uint8_t *source;
static uint64_t logical_size = 0x4000;
static void *code_object;
S2A_TEST_MOD_TABLE(64); int g_nmod;
// 验收口径：10k 并发里信号为 0。命中计一次并照旧致命退出（不吞掉真崩溃）。
static _Atomic int g_sig_seen;
static void sig_count(int s) { atomic_fetch_add(&g_sig_seen, 1); _exit(128 + s); }
#include "../core-link/runtime-tests/vm/core_endpoints.inc"
void s2a_mem_test_setup(uint64_t, uint64_t, uint64_t, uint64_t, void *, uint64_t);
void s2a_mem_test_map(uint64_t, uint64_t);
void s2a_mem_test_map_perm(int, uint32_t);
void s2a_mem_test_sysres(uint64_t, uint64_t);
int s2a_mem_write32_checked(uint64_t, uint32_t);
int svc_mem(int, uint64_t *, uint64_t);
static _Thread_local int writer_active;
int s2a_android_vm_writer_held(void) { return writer_active; }
// 替身：svc_mem.c 的 GetInfo 读硬件核数与计数器换算（真实现在 thread.c / os.c，本单测不链）；取 Switch 1 口径
int s2a_thread_hw_cores(void) { return 4; }
uint64_t s2a_ns_to_tick(uint64_t ns) { return (uint64_t)((unsigned __int128)ns * 19200000u / 1000000000u); }
int s2a_android_guest_writers_begin(void) { assert(!writer_active); writer_active = 1; return 0; }
int s2a_android_guest_writers_begin_serial(void) { return s2a_android_guest_writers_begin(); }
int s2a_android_guest_writers_quiesce(void) { assert(writer_active); return 0; }
void s2a_android_guest_writers_end(void) { assert(writer_active); writer_active = 0; }
// 撤销状态由真实 VM 组合层提供；这两个目标只链 svc_mem.c 的映射逻辑，事务永不撤销。
int s2a_android_guest_writers_revoked(void) { return 0; }
int s2a_android_guest_writers_ready(void) { return 0; }
unsigned s2a_android_guest_writers_epoch(void) { return 0; }   // 夹具内没有写者 epoch；替页窗口由真实 backing_busy 覆盖
void s2a_thread_dump(void) { abort(); }

static _Atomic int mapping_done;
static _Atomic int drain_done;
static uint8_t *race_page;
static size_t race_page_size;
static void *cycle_mapping(void *unused) {
    (void)unused;
    for (int i = 0; i < 10000; ++i) {
        uint64_t regs[32] = {(uintptr_t)race_page, race_page_size};
        assert(svc_mem(0x2c, regs, 0) && regs[0] == 0);
        regs[0] = (uintptr_t)race_page; regs[1] = race_page_size;
        assert(svc_mem(0x2d, regs, 0) && regs[0] == 0);
    }
    atomic_store(&mapping_done, 1);
    return NULL;
}
static void *cycle_drain(void *unused) {
    (void)unused;
    do {
        s2a_track_batch batch;
        s2a_track_drain(&batch);
        s2a_track_drain_done();
    } while (!atomic_load(&drain_done));
    return NULL;
}

static void *map_at(void *address, size_t page, int flags) {
    void *p = mmap(address, page, PROT_READ | PROT_WRITE,
                   flags | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    assert(p == address);
    return p;
}

int main(void) {
    struct sigaction sa = {0}; sa.sa_handler = sig_count; sigemptyset(&sa.sa_mask);
    assert(sigaction(SIGSEGV, &sa, NULL) == 0 && sigaction(SIGBUS, &sa, NULL) == 0);
    size_t page = plat_page_size();
    assert(page >= 4096 && !(page & (page - 1)));
    assert(page <= 0x4000);
    uint8_t *window = NULL;
    assert(plat_vm_reserve(0x20000, 0x4000, 1ull << 39, (void **)&window) == 0);
    uint32_t *readonly = map_at(window, page, MAP_SHARED);
    uint32_t *tracked = map_at(window + page, page, MAP_SHARED);
    uint32_t *private = map_at(window + 2 * page, page, MAP_PRIVATE);
    *readonly = *tracked = *private = 42;
    race_page = window + 0x10000; race_page_size = page;
    s2a_mem_test_setup((uintptr_t)race_page, 0x4000, (uintptr_t)window, 0x20000, NULL, 0);
    s2a_mem_test_sysres(1, 0);
    s2a_mem_test_map((uintptr_t)readonly, page);
    s2a_mem_test_map_perm(0, 1);
    s2a_mem_test_map((uintptr_t)tracked, page);
    s2a_mem_test_map((uintptr_t)private, page);
    assert(mprotect(readonly, page, PROT_READ) == 0);
    s2a_track_prepare();
    s2a_track_reprotect((uintptr_t)tracked, 4096, S2A_TRACK_READ);
    assert(s2a_track_platform_protection((uintptr_t)tracked) == PROT_READ);

    assert(s2a_mem_write32_checked((uintptr_t)readonly, 99) == -EACCES);
    assert(*readonly == 42 && s2a_track_platform_protection((uintptr_t)readonly) == PROT_READ);
    assert(s2a_mem_write32_checked((uintptr_t)tracked, 99) == 0);
    assert(*tracked == 99 && s2a_track_platform_protection((uintptr_t)tracked) == PROT_READ);
    s2a_track_batch batch;
    s2a_track_drain(&batch);
    assert(batch.nranges == 1 && batch.ranges[0].addr == (uintptr_t)tracked && batch.ranges[0].size == 4096);
    // 确定性的 drain 门竞争：排空窗口内提交必须 -EAGAIN、值不变；同一窗口连续两次提交都 -EAGAIN（拿不到门不得替排空线程放门）；放行后重试成功并记一次脏
    assert(s2a_mem_write32_checked((uintptr_t)tracked, 77) == -EAGAIN && *tracked == 99);
    assert(s2a_mem_write32_checked((uintptr_t)tracked, 78) == -EAGAIN && *tracked == 99);
    s2a_track_drain_done();
    assert(s2a_mem_write32_checked((uintptr_t)tracked, 77) == 0 && *tracked == 77);
    s2a_track_drain(&batch);
    assert(batch.nranges == 1 && batch.ranges[0].addr == (uintptr_t)tracked && batch.ranges[0].size == 4096);
    s2a_track_drain_done();

    assert(s2a_mem_write32_checked((uintptr_t)private, 99) == -EOPNOTSUPP && *private == 42);
    assert(s2a_mem_write32_checked((uintptr_t)window + 3 * page, 99) == -EFAULT);
    assert(s2a_track_platform_protection((uintptr_t)window + 3 * page) == PROT_NONE);
    assert(s2a_mem_write32_checked((uintptr_t)tracked + 1, 99) == -EFAULT);
    assert(s2a_mem_write32_checked(UINT64_MAX - 3, 99) == -EFAULT);
    alarm(120); // A deadlock must fail the host test rather than hang the gate.
    pthread_t mapper;
    assert(pthread_create(&mapper, NULL, cycle_mapping, NULL) == 0);
    uint64_t writes = 0, succeeded = 0, unmapped = 0, conflicted = 0;
    do {
        int result = s2a_mem_write32_checked((uintptr_t)race_page, 99);
        assert(result == 0 || result == -EFAULT || result == -EAGAIN);
        succeeded += result == 0;
        unmapped += result == -EFAULT;
        conflicted += result == -EAGAIN;
        ++writes;
    } while (!atomic_load(&mapping_done) || writes < 10000);
    assert(pthread_join(mapper, NULL) == 0);
    assert(s2a_mem_write32_checked((uintptr_t)race_page, 99) == -EFAULT);
    assert(s2a_track_platform_protection((uintptr_t)race_page) == PROT_NONE);
    pthread_t drainer;
    assert(pthread_create(&drainer, NULL, cycle_drain, NULL) == 0);
    unsigned completed = 0, drain_eagain = 0;
    for (uint32_t i = 0; i < 2000; ++i) {
        int result = s2a_mem_write32_checked((uintptr_t)tracked, i);
        assert(result == 0 || result == -EAGAIN);
        if (!result) assert(*(volatile uint32_t *)tracked == i);   // 报成功必须写到了本页（混页 0）
        completed += result == 0;
        drain_eagain += result == -EAGAIN;
        s2a_track_reprotect((uintptr_t)tracked, 4096, S2A_TRACK_READ);
    }
    atomic_store(&drain_done, 1);
    assert(pthread_join(drainer, NULL) == 0 && completed > 0);
    // 无竞争对照组：独占提交 10k 次不允许任何 -EAGAIN（竞争组才允许；反向用例）
    s2a_track_reprotect((uintptr_t)tracked, page, S2A_TRACK_READ);
    unsigned solo = 0, solo_eagain = 0;
    for (uint32_t i = 0; i < 10000; ++i) {
        int result = s2a_mem_write32_checked((uintptr_t)tracked, i);
        assert(result == 0 || result == -EAGAIN);
        solo += result == 0;
        solo_eagain += result == -EAGAIN;
    }
    assert(solo == 10000 && solo_eagain == 0);
    alarm(0);
    assert(atomic_load(&g_sig_seen) == 0);
    printf("map/unmap 10000 cycles; checked writes %llu: success %llu, EFAULT %llu, EAGAIN %llu (%.1f%%)\n",
           (unsigned long long)writes, (unsigned long long)succeeded,
           (unsigned long long)unmapped, (unsigned long long)conflicted,
           writes ? 100.0 * conflicted / writes : 0.0);
    printf("concurrent drain: %u writes committed, %u EAGAIN (%.1f%%); uncontended 10k: success %u, EAGAIN %u\n",
           completed, drain_eagain, 100.0 * drain_eagain / 2000, solo, solo_eagain);
    puts("fps checked write: logical permission, tracker and alias contract passed");
    return 0;
}

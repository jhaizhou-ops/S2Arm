// Linux 主机：真 mprotect / SIGSEGV / 共享别名驱动生产 tracker；不冒充 Android 设备。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../../../../../graphics/track/s2a_track.h"
#include "../../../../../graphics/track/track_platform.h"
#include "../runtime.h"
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <ucontext.h>
#include <unistd.h>
#if defined(__aarch64__)
#include <asm/sigcontext.h>
#endif

static unsigned checks, failures;
#define CHECK(label, condition) do { ++checks; if (!(condition)) { ++failures; fprintf(stderr, "FAIL %s line %d\n", label, __LINE__); } } while (0)
static size_t host_page;
static volatile sig_atomic_t in_signal, pending, faults, signal_open_calls;
int __real_open(const char *path, int flags, ...);
int __wrap_open(const char *path, int flags, ...) {
    if (in_signal) ++signal_open_calls;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); int mode = va_arg(ap, int); va_end(ap);
        return __real_open(path, flags, mode);
    }
    return __real_open(path, flags);
}
static sigjmp_buf resume;
static uint64_t pending_address;
static uint8_t *guest;
static unsigned callbacks;
static uint8_t gpu[4096];
static unsigned before_calls, after_calls;
static uint8_t before_value = 0x19, after_value = 0x28;
static int after_mapped = 1;
static uint64_t expected_source;
static void backing_before_test(uint64_t address, uint64_t size, uint64_t source) {
    CHECK("before保留精确alias源", source == expected_source);
    uint8_t old = 0;
    s2a_track_read_untracked(address + 19, &old, 1);
    CHECK("before旧页仍有效", address == (uintptr_t)guest && size == host_page && old == before_value);
    ++before_calls;
}
static void backing_after_test(uint64_t address, uint64_t size, int mapped) {
    CHECK("after先清旧世代", !s2a_track_sub_state(address) && !s2a_track_gpu_modified(address, size));
    CHECK("after真实映射状态", mapped == after_mapped && (mapped ? guest[19] == after_value : s2a_track_platform_protection(address) < 0));
    ++after_calls;
}


// 仅 16 KiB 算法覆盖构建替换 getpagesize；内核仍是当前 Linux 主机。
int s2a_track_test_pagesize(void) { return (int)host_page; }

static void fault_handler(int sig, siginfo_t *info, void *context) {
    in_signal = 1; ++faults;
#if defined(__x86_64__)
    int write = (((ucontext_t *)context)->uc_mcontext.gregs[REG_ERR] & 2) != 0;
#elif defined(__aarch64__)
    ucontext_t *uc = context;
    unsigned char *p = uc->uc_mcontext.__reserved, *end = p + sizeof uc->uc_mcontext.__reserved;
    int write = -1;
    while ((size_t)(end - p) >= sizeof(struct _aarch64_ctx)) {
        struct _aarch64_ctx *record = (struct _aarch64_ctx *)p;
        if (record->size < sizeof *record || record->size > (size_t)(end - p)) break;
        if (record->magic == ESR_MAGIC && record->size >= sizeof(struct esr_context)) {
            write = (int)(((struct esr_context *)p)->esr >> 6) & 1;
            break;
        }
        p += record->size;
    }
    if (write < 0) _exit(125);
#else
#error "此主机测试需要 x86_64 或 arm64 缺页上下文"
#endif
    int handled = s2a_track_fault_guest(info->si_addr, write, 0);
    in_signal = 0;
    if (handled == 1) return;
    if (handled == 2) {
        pending_address = (uintptr_t)info->si_addr;
        pending = 1;
        siglongjmp(resume, 1);
    }
    _exit(128 + sig);
}
static void touch(uint64_t address, uint64_t size, int write) {
    CHECK("回写不在信号上下文", !in_signal);
    CHECK("按4K子页回写", size == 4096);
    ++callbacks;
    s2a_track_write_untracked(address, gpu, size, 1);
    s2a_track_reprotect(address, size, write ? S2A_TRACK_RW : S2A_TRACK_READ);
}
static int has_range(const s2a_track_batch *batch, uint64_t address) {
    for (unsigned i = 0; i < batch->nranges; ++i)
        if (batch->ranges[i].addr <= address && address < batch->ranges[i].addr + batch->ranges[i].size) return 1;
    return 0;
}
static uint64_t range_len(const s2a_track_batch *batch, uint64_t address) {
    for (unsigned i = 0; i < batch->nranges; ++i)
        if (batch->ranges[i].addr <= address && address < batch->ranges[i].addr + batch->ranges[i].size) return batch->ranges[i].size;
    return 0;
}
static void drain(s2a_track_batch *batch) { s2a_track_drain(batch); CHECK("排空不溢出", !batch->overflow); s2a_track_drain_done(); }

int main(int argc, char **argv) {
    host_page = argc == 2 ? strtoul(argv[1], NULL, 10) : (size_t)sysconf(_SC_PAGESIZE);
    if ((host_page != 4096 && host_page != 16384) || host_page < (size_t)sysconf(_SC_PAGESIZE)) return 2;
    CHECK("未prepare不就绪", !s2a_track_runtime_ready());
    CHECK("真实预分配", !s2a_track_runtime_prepare());
    CHECK("缺全局fault和VM provider仍不就绪", !s2a_track_runtime_ready());
    CHECK("prepare不可重置运行态", s2a_track_runtime_prepare() == EALREADY);
    int fd = memfd_create("s2a-track-test", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)(host_page * 4))) return 2;
    // 给16K算法显式对齐；MAP_FIXED只覆盖本测试刚预留的私有区间。
    void *reserved = mmap(NULL, host_page * 5, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reserved == MAP_FAILED) return 2;
    uintptr_t aligned = ((uintptr_t)reserved + host_page - 1) & ~(host_page - 1);
    guest = mmap((void *)aligned, host_page * 4, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    if (guest == MAP_FAILED) return 2;
    struct sigaction action = {.sa_sigaction = fault_handler, .sa_flags = SA_SIGINFO};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGSEGV, &action, NULL)) return 2;
    s2a_track_reprotect((uintptr_t)guest, 4096, S2A_TRACK_READ);
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_RW);
    // Own a tracker RW state, then simulate an unreported stale OS protection.
    // The actual signal handler must retry the write without opening procfs.
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_READ);
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_RW);
    pid_t stale_child = fork();
    if (!stale_child) {
        if (mprotect(guest, host_page, PROT_READ)) _exit(120);
        signal_open_calls = 0; faults = 0;
        *(volatile uint8_t *)(guest + 7) = 0x52;
        _exit(faults && !signal_open_calls && guest[7] == 0x52 ? 0 : 121);
    }
    int stale_status = 0;
    CHECK("PG_RW可恢复缺页且信号不打开文件", stale_child > 0 && waitpid(stale_child, &stale_status, 0) == stale_child &&
          WIFEXITED(stale_status) && WEXITSTATUS(stale_status) == 0);
    // An explicitly changed external read-only page is not ours to promote.
    pid_t readonly_child = fork();
    if (!readonly_child) {
        if (mprotect(guest, host_page, PROT_READ)) _exit(120);
        s2a_track_prot_changed((uintptr_t)guest, host_page);
        *(volatile uint8_t *)(guest + 8) = 0x53;
        _exit(0);
    }
    int readonly_status = 0;
    CHECK("外部明确只读页不可升写", readonly_child > 0 && waitpid(readonly_child, &readonly_status, 0) == readonly_child &&
          WIFEXITED(readonly_status) && WEXITSTATUS(readonly_status) == 128 + SIGSEGV);
    s2a_track_batch initial_batch; s2a_track_drain(&initial_batch); s2a_track_drain_done();
    s2a_track_batch batch;

    // ㉓ Android 版：lastp=RW 的过期缺页。写发生时页还只读，处理函数跑到时别的线程已合法
    // 把页设成可写（reprotect RW / 并发缺页解开）。第一次只按竞争处理（不 mprotect、不报脏）；
    // 同一页连续第二次才自愈。旧代码（本 PR 前一版）第一次就自愈，会把正常竞争误报成整页脏。
    uint8_t *stale = guest + host_page * 3;
    s2a_track_reprotect((uintptr_t)stale, host_page, S2A_TRACK_READ);
    s2a_track_reprotect((uintptr_t)stale, host_page, S2A_TRACK_RW);
    drain(&batch);
    s2a_track_stat s0, s1;
    s2a_track_stats(&s0);
    int stale_rc = s2a_track_fault(stale + 0x10, 1);
    s2a_track_stats(&s1); drain(&batch);
    CHECK("㉓ 过期缺页：处理晚到只重执行", stale_rc == 1);
    CHECK("㉓ 过期缺页：不自愈", s1.heals == s0.heals);
    CHECK("㉓ 过期缺页：算竞争", s1.races == s0.races + 1);
    CHECK("㉓ 过期缺页：不报脏", !has_range(&batch, (uintptr_t)stale));
    CHECK("㉓ 过期缺页后页仍可读写", s2a_track_platform_protection((uintptr_t)stale) == (PROT_READ | PROT_WRITE));

    // ㉓ 正对照：外部没报 prot_changed 把页改成只读。第一次仍按竞争；连续第二次才自愈，
    // 整宿主页（16K 模型 4 个 4K 子页）报脏。
    s2a_track_reprotect((uintptr_t)stale, host_page, S2A_TRACK_READ);
    s2a_track_reprotect((uintptr_t)stale, host_page, S2A_TRACK_RW);
    drain(&batch);
    if (mprotect(stale, host_page, PROT_READ)) return 2;
    s2a_track_stats(&s0);
    int first_rc = s2a_track_fault(stale + 0x20, 1);
    s2a_track_stats(&s1); drain(&batch);
    CHECK("㉓ 正对照：首次按竞争不自愈", first_rc == 1 && s1.heals == s0.heals && s1.races == s0.races + 1 && !has_range(&batch, (uintptr_t)stale));
    s2a_track_stats(&s0);
    int second_rc = s2a_track_fault(stale + 0x20, 1);
    s2a_track_stats(&s1); drain(&batch);
    int whole = 1;
    for (size_t off = 0; off < host_page; off += 4096) if (!has_range(&batch, (uintptr_t)stale + off)) whole = 0;
    CHECK("㉓ 正对照：连续第二次自愈", second_rc == 1 && s1.heals == s0.heals + 1);
    CHECK("㉓ 正对照：页恢复可读写", s2a_track_platform_protection((uintptr_t)stale) == (PROT_READ | PROT_WRITE));
    CHECK("㉓ 正对照：整宿主页报脏", whole && range_len(&batch, (uintptr_t)stale) == host_page);

    // 0xfe 过期缺页 → backing_reset → 再过期缺页：backing_reset 必须清 reject，
    // 否则第二次直接 return 0（安卓 on_crash 会 _exit）。两次都应返回 1（各给一次重执行）。
    s2a_track_prot_changed((uintptr_t)stale, host_page);
    if (mprotect(stale, host_page, PROT_READ)) return 2;
    int ext1 = s2a_track_fault(stale + 0x30, 1);
    s2a_track_backing_reset((uintptr_t)stale, host_page);
    int ext2 = s2a_track_fault(stale + 0x30, 1);
    CHECK("0xfe 过期缺页两次都给重执行（backing_reset 清 reject）", ext1 == 1 && ext2 == 1);

    CHECK("查询RW映射", s2a_track_platform_protection((uintptr_t)guest) == (PROT_READ | PROT_WRITE));
    errno = EDOM;
    CHECK("查询保留errno", s2a_track_platform_protection((uintptr_t)guest) >= 0 && errno == EDOM);

    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_READ);
    CHECK("保护真实落地", s2a_track_platform_protection((uintptr_t)guest) == PROT_READ);
    *(volatile uint8_t *)(guest + 31) = 0x44;
    CHECK("CPU写确实触发缺页", faults > 0);
    drain(&batch);
    CHECK("CPU写触发4K GPU缓存失效", has_range(&batch, (uintptr_t)guest + 31));
    if (host_page == 16384) CHECK("未写邻居不报脏", !has_range(&batch, (uintptr_t)guest + 4096));
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_RW);
    drain(&batch);

    // 先GPU修改，再CPU同值写：必须先回写，不能靠内容diff丢掉同值写。
    memset(guest, 0, host_page); memset(gpu, 0xa5, sizeof gpu);
    s2a_track_set_touch(touch);
    s2a_track_reprotect((uintptr_t)guest, 4096, S2A_TRACK_NONE);
    // 原常量0哨兵意为“不跳就是失败”；在跳转汇合后判，不能在故障访问后计数。
    volatile sig_atomic_t did_jump = 0;
    pending = 0;
    if (!sigsetjmp(resume, 1)) { *(volatile uint8_t *)(guest + 7) = 0; }
    else {
        did_jump = 1;
        CHECK("信号只返回改道请求", pending && !callbacks);
        s2a_track_touch(pending_address);
        *(volatile uint8_t *)(guest + 7) = 0;
    }
    CHECK("GPU脏页写应改道", did_jump && pending);
    CHECK("CPU同值写保留", guest[7] == 0);
    CHECK("邻字节来自GPU", guest[8] == 0xa5);
    CHECK("仅一次回写", callbacks == 1);
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_RW);
    drain(&batch);

    callbacks = 0; memset(gpu, 0xb6, sizeof gpu);
    s2a_track_reprotect((uintptr_t)guest, 4096, S2A_TRACK_NONE);
    pending = 0; did_jump = 0;
    if (!sigsetjmp(resume, 1)) { volatile uint8_t old = guest[8]; (void)old; }
    else {
        did_jump = 1;
        CHECK("读fault不直接回调", pending && !callbacks);
        s2a_track_touch(pending_address);
    }
    CHECK("GPU脏页读应改道", did_jump && pending);
    CHECK("CPU读拿到GPU新值", *(volatile uint8_t *)(guest + 8) == 0xb6);
    CHECK("读仅一次回写", callbacks == 1);
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_RW);
    drain(&batch);

    // 受保护源与可写别名共享同一backing，别名不打开原映射。
    s2a_track_reprotect((uintptr_t)guest, 4096, S2A_TRACK_NONE);
    s2a_track_mark_readflush((uintptr_t)guest, 4096);
    CHECK("GPU读回页真实不可读", s2a_track_platform_protection((uintptr_t)guest) == PROT_NONE);
    uint8_t copied = 0;
    CHECK("不可读页经真别名读取", s2a_track_read_untracked((uintptr_t)guest + 8, &copied, 1) == 1 && copied == 0xb6);
    CHECK("读别名不解开原页", s2a_track_platform_protection((uintptr_t)guest) == PROT_NONE);
    s2a_track_set_walias(1);
    uint8_t value = 0x73;
    s2a_track_write_untracked((uintptr_t)guest + 8, &value, 1, 1);
    CHECK("GPU回写别名不解开原页", s2a_track_platform_protection((uintptr_t)guest) == PROT_NONE);
    s2a_track_read_untracked((uintptr_t)guest + 8, &copied, 1);
    CHECK("GPU回写改变同一物理页", copied == value);
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_RW);
    drain(&batch);

    // The Android managed precise consumer needs to copy a snapshot after
    // drain re-arms READFLUSH. Exercise the actual Linux shared-alias path:
    // it must read the snapshot without opening the guest's protected page.
    uintptr_t precise_addr = (uintptr_t)guest + (host_page == 16384 ? 4096 : 0);
    s2a_track_set_touch(NULL);
    s2a_track_reprotect(precise_addr, 4096, S2A_TRACK_NONE);
    s2a_track_write_quiet(precise_addr + 0x10, 1);
    *(volatile uint8_t *)(precise_addr + 0x10) = 0x5a;
    s2a_track_drain(&batch);
    int precise_index = -1;
    for (unsigned i = 0; i < batch.nprecise; ++i)
        if (batch.precise[i].addr == precise_addr) precise_index = (int)i;
    CHECK("精确快照已实际产生", precise_index >= 0);
    CHECK("快照页维持不可读", s2a_track_platform_protection((uintptr_t)guest) == PROT_NONE);
    if (precise_index >= 0) {
        uint8_t precise_copy[4096];
        CHECK("精确快照通过真实共享别名读取", s2a_track_copy_precise(batch.precise[precise_index].addr, precise_copy, sizeof precise_copy) == 1 && precise_copy[0x10] == 0x5a);
        CHECK("快照读取期间 guest 页仍不可读", s2a_track_platform_protection((uintptr_t)guest) == PROT_NONE);
    }
    s2a_track_drain_done();
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_RW);
    s2a_track_set_touch(touch);
    drain(&batch);
    uint8_t readable_copy = 0;
    CHECK("可读页精确快照也总走真实别名", s2a_track_copy_precise(precise_addr + 0x10, &readable_copy, 1) == 1 && readable_copy == 0x5a);
    CHECK("别名读取不改变可读页保护", s2a_track_platform_protection((uintptr_t)guest) == (PROT_READ | PROT_WRITE));

    // 两阶段替页：初始无GPU可映射，激活后旧数据仍在时before，替页后清旧跟踪。
    CHECK("初始映射无GPU事务", !s2a_track_backing_begin((uintptr_t)guest, host_page, expected_source));
    s2a_track_backing_end((uintptr_t)guest, host_page, 1, 1);
    s2a_track_set_backing_callbacks(backing_before_test, backing_after_test);
    guest[19] = 0x19;
    s2a_track_reprotect((uintptr_t)guest, 4096, S2A_TRACK_NONE);
    CHECK("有GPU时开始事务", !s2a_track_backing_begin((uintptr_t)guest, host_page, expected_source));
    CHECK("拒绝嵌套替页", s2a_track_backing_begin((uintptr_t)guest, host_page, expected_source) == EBUSY);
    CHECK("before已执行after未执行", before_calls == 1 && after_calls == 0);
    CHECK("真实新backing替换", mmap(guest, host_page, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, (off_t)host_page) == guest);
    guest[19] = 0x28;
    s2a_track_backing_end((uintptr_t)guest, host_page, 1, 1);
    CHECK("after恰执行一次", after_calls == 1);
    drain(&batch);
    CHECK("旧世代不污染新映射", !batch.nprecise && !batch.nranges);
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_READ);
    *(volatile uint8_t *)(guest + 29) = 0x77;
    drain(&batch);
    CHECK("新世代继续跟踪CPU写", has_range(&batch, (uintptr_t)guest + 29));
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_RW);
    drain(&batch);
    before_value = guest[19]; after_value = 0x39;
    uint8_t *source = guest + host_page * 2;
    source[19] = after_value; expected_source = (uintptr_t)source;
    s2a_track_reprotect((uintptr_t)source, host_page, S2A_TRACK_NONE);
    CHECK("alias源目标同一次事务", !s2a_track_backing_begin((uintptr_t)guest, host_page, expected_source));
    CHECK("真实不相邻backing别名", mmap(guest, host_page, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, (off_t)(host_page * 2)) == guest);
    s2a_track_backing_end((uintptr_t)guest, host_page, 1, 1);
    CHECK("reset只清目标不抹源状态", s2a_track_gpu_modified((uintptr_t)source, host_page));
    s2a_track_reprotect((uintptr_t)source, host_page, S2A_TRACK_RW);
    source[17] = 0x71;
    CHECK("alias共享真实物理数据", guest[17] == 0x71);
    expected_source = 0;
    before_value = after_value = guest[19];
    s2a_track_reprotect((uintptr_t)guest, host_page, S2A_TRACK_READ);
    CHECK("失败替页开始", !s2a_track_backing_begin((uintptr_t)guest, host_page, expected_source));
    CHECK("无效offset内核拒绝替页", mmap(guest, host_page, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, -1) == MAP_FAILED);
    CHECK("回滚恢复guest实际权限", !mprotect(guest, host_page, PROT_READ | PROT_WRITE));
    s2a_track_backing_end((uintptr_t)guest, host_page, 1, 0);
    CHECK("失败保留旧映射完成after", after_calls == 3 && guest[19] == before_value);
    CHECK("解除映射开始", !s2a_track_backing_begin((uintptr_t)guest, host_page, expected_source));
    CHECK("真实解除映射", !munmap(guest, host_page));
    after_mapped = 0;
    s2a_track_backing_end((uintptr_t)guest, host_page, 0, 1);
    CHECK("解除映射完成after", after_calls == 4);
    CHECK("拒绝溢出替页", s2a_track_backing_begin(UINT64_MAX - host_page + 1, host_page, 0) == EINVAL);

    void *private_page = mmap(NULL, host_page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (private_page == MAP_FAILED) return 2;
    void *alias = (void *)1;
    CHECK("私有backing拒绝假别名", s2a_track_platform_alias((uintptr_t)private_page, host_page, PROT_READ, &alias) != 0 && !alias);
    CHECK("拒绝后原映射仍可写", s2a_track_platform_protection((uintptr_t)private_page) == (PROT_READ | PROT_WRITE));
    CHECK("越界别名拒绝", s2a_track_platform_alias(UINTPTR_MAX - host_page + 1, host_page, PROT_READ, &alias) == EINVAL && !alias);
    munmap(private_page, host_page);
    CHECK("释放后查询不伪报权限", s2a_track_platform_protection((uintptr_t)private_page) < 0);
    // 保护失败不得继续发布成功状态；子进程只使用自己刚释放的测试映射。
    pid_t child = fork();
    if (child == 0) { s2a_track_reprotect((uintptr_t)private_page, host_page, S2A_TRACK_READ); _exit(0); }
    int status = 0;
    CHECK("保护失败终止而非伪成功", child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 125);
    if (host_page == 16384) {
        // A CPU write opens the host page and leaves the other subpages in
        // watch. A protected-alias restore must update that watch baseline.
        uint8_t *watched = guest + host_page; // First page was unmapped above.
        s2a_track_set_readflush(0); s2a_track_set_touch(NULL);
        s2a_track_reprotect((uintptr_t)watched, host_page, S2A_TRACK_RW);
        drain(&batch);
        s2a_track_reprotect((uintptr_t)watched, host_page, S2A_TRACK_READ);
        s2a_track_write_quiet((uintptr_t)watched + 4096 + 16, 1);
        watched[4096 + 16] = 0x44;
        uint8_t restored = 0x55;
        s2a_track_restore_precise((uintptr_t)watched + 8192 + 16, &restored, 1);
        drain(&batch);
        CHECK("普通 CPU 写仍报脏", has_range(&batch, (uintptr_t)watched + 4096 + 16));
        CHECK("精确恢复不伪报观察子页", !has_range(&batch, (uintptr_t)watched + 8192 + 16));
    }
    munmap(reserved, host_page * 5); close(fd);
    printf("%s Linux tracking %zu-byte model: %u checks, %u failures\n", failures ? "FAIL" : "PASS", host_page, checks, failures);
    return failures != 0;
}

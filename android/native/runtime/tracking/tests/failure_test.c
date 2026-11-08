// Android 正确性边界：旧skip、无进展读回、快照耗尽不能继续读取/覆盖旧数据。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../../../../../graphics/track/s2a_track.h"
#include "../runtime.h"
#include "../../../../../graphics/track/track_platform.h"
#include <pthread.h>
#include <stdatomic.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned checks, failures, touches;
static size_t page;
static uint8_t value;
static int redirty;
// 只验证门的组合逻辑，不冒充真实信号安装/VM provider验证。
static int installed, vm_installed, probed;
int s2a_android_fault_dispatch_installed(void) { return installed; }
int s2a_android_tracking_vm_ready(void) { return vm_installed; }
int s2a_android_fault_dispatch_ready(void) { return probed; }
#define CHECK(label, condition) do { ++checks; if (!(condition)) { ++failures; fprintf(stderr, "FAIL %s line %d\n", label, __LINE__); } } while (0)
void s2a_track_test_snap_chunks(int count);
extern void (*s2a_track_test_heal_claim)(uintptr_t pn);
extern void (*s2a_track_test_prot_wait)(uintptr_t pn);
static atomic_int heal_paused, heal_resume, prot_waiting;
static int prot_error;
static void pause_heal(uintptr_t pn) {
    (void)pn; atomic_store(&heal_paused, 1);
    while (!atomic_load(&heal_resume)) { }
}
static void note_prot_wait(uintptr_t pn) {
    (void)pn; atomic_store(&prot_waiting, 1);
}
static void *run_heal(void *memory) {
    s2a_track_fault(memory, 1);   // 第一次：lastp=RW 的过期缺页按竞争（g_races++）
    s2a_track_fault(memory, 1);   // 第二次：同一页连续第二次，自愈（hook 在这里暂停）
    return NULL;
}
static void *run_external_ro(void *memory) {
    prot_error = s2a_track_set_guest_protection((uintptr_t)memory, page, PROT_READ);
    return NULL;
}
static void touch(uint64_t address, uint64_t size, int write) {
    (void)write;
    ++touches;
    s2a_track_write_untracked(address, &value, 1, 1);
    s2a_track_reprotect(address, size, S2A_TRACK_READ);
    if (redirty) { redirty = 0; s2a_track_reprotect(address, size, S2A_TRACK_NONE); }
}
static void no_progress(uint64_t address, uint64_t size, int write) { (void)address; (void)size; (void)write; }
int main(void) {
    page = (size_t)sysconf(_SC_PAGESIZE);
    int fd = memfd_create("s2a-tracker-failure", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)page)) return 2;
    uint8_t *memory = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (memory == MAP_FAILED || s2a_track_runtime_prepare()) return 2;
    CHECK("符号存在不等于已安装", !s2a_track_runtime_prepared() && !s2a_track_runtime_ready());
    installed = 1;
    CHECK("缺完整VM不能prepared", !s2a_track_runtime_prepared());
    vm_installed = 1;
    CHECK("真实安装态允许准备但未放行", s2a_track_runtime_prepared() && !s2a_track_runtime_ready());
    probed = 1;
    CHECK("安装与最终probe齐才放行", s2a_track_runtime_ready());
    installed = 0;
    CHECK("安装态丢失不能沿用probe", !s2a_track_runtime_ready());
    vm_installed = probed = 0;
    s2a_track_set_touch(touch);
    s2a_track_reprotect((uintptr_t)memory, page, S2A_TRACK_NONE);
    CHECK("首次GPU脏态要求读回", s2a_track_fault_guest(memory, 0, 0) == 2);
    value = 0x35; s2a_track_touch((uintptr_t)memory);
    CHECK("首次真实读回", memory[0] == 0x35 && touches == 1);
    s2a_track_reprotect((uintptr_t)memory, page, S2A_TRACK_NONE);
    CHECK("旧地址skip不能跳过新GPU写", s2a_track_fault_guest(memory, 0, (uintptr_t)memory) == 2);
    value = 0x57; s2a_track_touch((uintptr_t)memory);
    CHECK("第二代真实GPU数据", memory[0] == 0x57 && touches == 2);
    s2a_track_reprotect((uintptr_t)memory, page, S2A_TRACK_NONE);
    redirty = 1; value = 0x68; s2a_track_touch((uintptr_t)memory);
    CHECK("读回同期新generation不误杀", s2a_track_fault_guest(memory, 0, (uintptr_t)memory) == 2);
    value = 0x79; s2a_track_touch((uintptr_t)memory);
    CHECK("同期新GPU写再次读回", memory[0] == 0x79 && touches == 4);

    // 可控竞态：自愈先占页（BUSY），客人 SetMemoryPermission(RO) 在另一线程同时进来。
    // run_heal 第一次 fault 按竞争返回（lastp=RW 的首次），第二次才进自愈并在 hook 暂停。
    // 外部改保护必须先占同一页，只能等自愈落地后改回只读；旧调用序列（先 mprotect 再
    // prot_changed）会被随后落地的自愈覆盖成可写（a656-race-legacy-probe.log）。
    s2a_track_set_touch(NULL);
    s2a_track_reprotect((uintptr_t)memory, page, S2A_TRACK_READ);
    s2a_track_reprotect((uintptr_t)memory, page, S2A_TRACK_RW);
    CHECK("竞态前页收成只读", mprotect(memory, page, PROT_READ) == 0);
    s2a_track_test_heal_claim = pause_heal;
    s2a_track_test_prot_wait = note_prot_wait;
    pthread_t healing, external;
    CHECK("启动真实缺页处理", !pthread_create(&healing, NULL, run_heal, memory));
    while (!atomic_load(&heal_paused)) { }
    CHECK("启动外部改保护", !pthread_create(&external, NULL, run_external_ro, memory));
    while (!atomic_load(&prot_waiting)) { }
    atomic_store(&heal_resume, 1);
    pthread_join(healing, NULL);
    pthread_join(external, NULL);
    s2a_track_test_heal_claim = NULL;
    s2a_track_test_prot_wait = NULL;
    CHECK("外部改保护成功", prot_error == 0);
    CHECK("后完成的外部只读不得被自愈覆盖", s2a_track_platform_protection((uintptr_t)memory) == PROT_READ);
    if (mprotect(memory, page, PROT_READ | PROT_WRITE)) return 2;
    s2a_track_prot_changed((uintptr_t)memory, page);

    int diagnostic[2];
    if (pipe(diagnostic)) return 2;
    pid_t child = fork();
    if (!child) {
        close(diagnostic[0]);
        if (dup2(diagnostic[1], STDERR_FILENO) < 0) _exit(2);
        close(diagnostic[1]);
        s2a_track_set_touch(no_progress);
        s2a_track_reprotect((uintptr_t)memory, page, S2A_TRACK_NONE);
        s2a_track_touch((uintptr_t)memory);
        _exit(0);
    }
    close(diagnostic[1]);
    int status = 0;
    CHECK("无进展callback同步终止", child > 0 && waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    char detail[2048] = {0};
    ssize_t detail_size = read(diagnostic[0], detail, sizeof detail - 1);
    close(diagnostic[0]);
    CHECK("失败证据保留页与世代边界", detail_size > 0 && strstr(detail, "addr=") && strstr(detail, "generation=")
        && strstr(detail, "requested=") && strstr(detail, "unresolved=") && strstr(detail, "reprotected="));

    child = fork();
    if (!child) {
        // 仅将真实分配池容量限制为一块；不替换slot算法或保护实现。
        s2a_track_test_snap_chunks(1);
        s2a_track_set_touch(NULL); s2a_track_set_readflush(0);
        size_t size = ((8193 * 4096 + page - 1) / page) * page;
        void *large = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (large == MAP_FAILED) _exit(2);
        s2a_track_reprotect((uintptr_t)large, size, S2A_TRACK_NONE);
        s2a_track_write((uintptr_t)large, size);
        _exit(0);
    }
    CHECK("快照真耗尽不覆盖CPU写", child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 125);
    munmap(memory, page); close(fd);
    printf("%s Linux tracking failures: %u checks, %u failures\n", failures ? "FAIL" : "PASS", checks, failures);
    return failures != 0;
}

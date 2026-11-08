// NVN 非命令录制实现的「大宿主栈」契约验证（#1218 直连起局链）：
// 客机线程只拿到小栈（Horizon 语义下主栈 1MB、工作者线程可只有十几 KiB），
// 宿主侧 submit/present/对象创建等深 Vulkan 驱动调用若直接跑在客机栈上会把栈底
// 保护页/未提交页压穿（8E 实测 SIGSEGV，pc 在宿主 .so）。修复 = 客机拿到的实现
// 入口一律是 sw_xstack_wrap 生成的 xs 桩：sp 不在宿主栈时先切到本线程 pthread 栈
// 再调实现（hle_nvn.c 注册点；对齐 Apple nvn_big_entry → dm_bigstack_enter）。
// 红：裸实现跑在 16 KiB 客机栈上压穿保护页 → 子进程 SIGSEGV。
// 绿：同一实现经 xs 桩后切到宿主栈 → 正常返回。
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern void *sw_xstack_wrap(const char *name, void *fn);
extern void sw_xstack_thread_init(uint64_t, uint64_t);
extern void sw_xstack_thread_fini(void);
extern void sw_call_on_stack(void (*fn)(void), uint64_t);
uint64_t gate_dispatch(uint64_t ret, uint64_t *regs) { (void)ret; (void)regs; abort(); }
void sw_thread_returned(void) { abort(); }
int g_lazy_core;                            // 关：xs_entry 钩子恒走直通路径
void s2a_guest_return(void) {}              // lazy 关闭时不可达

static void check(int ok) {
    if (!ok) { perror("check"); exit(1); }
}

static volatile char sink;
static int hits;
static volatile uint64_t last_sp;
static uint64_t host_lo, host_hi;

static int on_host_stack(uint64_t sp) { return sp >= host_lo && sp < host_hi; }

// 模拟宿主侧深栈帧实现：48 KiB 局部帧逐页落写——16 KiB 客机栈必穿，宿主 pthread 栈放得下。
// 两处防折叠：volatile 写每页（死存消除只留一格的坑，复测实证）；地址传进 noinline touch——
// 指针不逃逸时 clang -O2 会把整个数组缩成只够被写单元的小帧（NDK clang 实证缩到 64 B）。
static __attribute__((noinline)) void touch(volatile char *p, size_t n) { sink = p[n - 1]; }
static __attribute__((noinline)) void deep_impl(void) {
    volatile char big[48 * 1024];
    __asm__ volatile("mov %0, sp" : "=r"(last_sp));
    for (size_t i = 0; i < sizeof big; i += 4096) big[i] = 1;
    touch(big, sizeof big);
    hits++;
}
// 浅实现：只记录 sp，用于「判定器本身能识别客机栈」的负对照。
static __attribute__((noinline)) void shallow_impl(void) {
    __asm__ volatile("mov %0, sp" : "=r"(last_sp));
    hits++;
}

static void (*g_wrapped)(void);
static uint64_t guest_low, guest_high;

static void guest_raw(void) { deep_impl(); }
static void guest_wrapped(void) { g_wrapped(); }
static void guest_shallow(void) { shallow_impl(); }

int main(void) {
    uint64_t sp;
    __asm__ volatile("mov %0, sp" : "=r"(sp));
    const size_t page = (size_t)sysconf(_SC_PAGESIZE), usable = 16 * 1024;
    void *mapping = mmap(NULL, usable + 2 * page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(mapping != MAP_FAILED);
    guest_low = (uintptr_t)mapping + page; guest_high = guest_low + usable;
    check(mprotect((void *)guest_low, usable, PROT_READ | PROT_WRITE) == 0);

    // 宿主栈区间：本线程 pthread 栈（xs 桩切栈目的地），用于断言实现跑在宿主栈上。
    pthread_attr_t pattr;
    void *sbase = NULL; size_t ssz = 0;
    check(pthread_getattr_np(pthread_self(), &pattr) == 0);
    check(pthread_attr_getstack(&pattr, &sbase, &ssz) == 0);
    host_lo = (uint64_t)sbase; host_hi = host_lo + ssz;

    // 负对照：浅实现裸跑在客机栈上——last_sp 落 guest 区间，证明 on_host_stack 能识别非宿主栈。
    sw_xstack_thread_init(sp - 4096, guest_high);
    sw_call_on_stack(guest_shallow, guest_high);
    check(hits == 1 && last_sp >= guest_low && last_sp < guest_high && !on_host_stack(last_sp));
    printf("control: shallow impl on guest stack correctly flagged (sp=0x%llx not in host [0x%llx,0x%llx))\n",
           (unsigned long long)last_sp, (unsigned long long)host_lo, (unsigned long long)host_hi);

    // 红：裸调用——子进程内复现「宿主实现压穿客机栈底保护页」的确定性 SIGSEGV。
    pid_t child = fork();
    check(child >= 0);
    if (child == 0) {
        sw_call_on_stack(guest_raw, guest_high);
        _exit(0);                       // 裸调用幸存 = 语义破坏，按失败出
    }
    int status = 0;
    check(waitpid(child, &status, 0) == child);
    check(WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV);
    printf("red: raw impl on 16 KiB guest stack -> SIGSEGV at guard page (status=%d)\n", status);

    // 绿：同一实现经 xs 桩——切到宿主 pthread 栈后 48 KiB 帧正常放下，
    //   且断言实现真跑在宿主栈区间（验收点：不只是幸存，是落在宿主栈上）。
    g_wrapped = (void (*)(void))sw_xstack_wrap("deep_impl", (void *)deep_impl);
    check(g_wrapped && g_wrapped != (void (*)(void))deep_impl);
    for (int i = 0; i < 16; i++) {
        sw_call_on_stack(guest_wrapped, guest_high);
        check(on_host_stack(last_sp));
    }
    check(hits == 17);
    sw_xstack_thread_fini();
    check(munmap(mapping, usable + 2 * page) == 0);
    printf("PASS nvn bigstack: 16 wrapped host calls with 48 KiB frames, sp verified on host stack [0x%llx,0x%llx)\n",
           (unsigned long long)host_lo, (unsigned long long)host_hi);
    return 0;
}

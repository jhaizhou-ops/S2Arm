// 宿主页只读别名（10-23 帧率能耗线「缺页处模拟读」用）：游戏读到被保护的页（GPU 改过、没回写），碰的子页又不是 GPU 改过的，
//   就在信号处理里模拟那条读——数要从同一物理页的一份可读别名取，页本身保持保护（别的线程照样陷入，不会读到没回写的子页）。
// 做法：每条游戏线程预留一个 16 KB 槽；要读时 vm_remap(copy = FALSE) 把那一宿主页共享映射进本线程的槽、改成只读。
//   不整窗做别名：iPhone 上 0x7000000000 是 2^39 以下唯一的 64 GB 空洞，没有第二块放整窗别名；客体 RAM 也不是共享内存对象。
//   不缓存「槽里是哪一页」：每次都重映射（Mac 实测 vm_remap 0.78 µs），客体映射怎么变（解映射 / 换对象）别名都不会过期。
//   共享不是拷贝：别名建好之后源页再被写，读别名看到新值（单测 ②）。源页是 PROT_NONE 也能建（共享对象的最大权限含读）。
// 只在本线程用、信号处理里可调（vm_remap / mprotect 都是陷入内核，不加锁、不分配）；返回的指针在本线程下次调用前有效。
#include "native.h"
#include <mach/mach.h>
#include <pthread.h>
#include <sys/mman.h>
#include <stdatomic.h>

#define ALIAS_PG 16384ull
static pthread_key_t g_akey;
static pthread_once_t g_aonce = PTHREAD_ONCE_INIT;
static _Atomic int g_akey_ok;   // 键建好前 g_akey = 0，pthread_getspecific(0) 会读到别的槽位（可能被当成槽覆盖映射）：没就绪一律返回 NULL
static void alias_free(void *p) { if (p) munmap(p, ALIAS_PG); }
static void akey_init(void) { if (pthread_key_create(&g_akey, alias_free)) die("别名：pthread_key_create 失败"); atomic_store(&g_akey_ok, 1); }

static _Atomic int g_alias_bad;   // 起局自检没过（别名建不出，或建出来不是共享）：之后一律 NULL，调用方走老路——不能拿拷贝当别名读到旧值

const uint8_t *s2a_alias_page(uint64_t host_page) {
    if (host_page & (ALIAS_PG - 1) || atomic_load(&g_alias_bad)) return NULL;
    if (!atomic_load(&g_akey_ok)) return NULL;
    uint8_t *slot = pthread_getspecific(g_akey);
    if (!slot) return NULL;
    vm_address_t a = (vm_address_t)slot; vm_prot_t cur, max;
    if (vm_remap(mach_task_self(), &a, ALIAS_PG, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)host_page, FALSE, &cur, &max, VM_INHERIT_NONE) != KERN_SUCCESS
        || a != (vm_address_t)slot || !(max & VM_PROT_READ)) return NULL;
    if (vm_protect(mach_task_self(), a, ALIAS_PG, FALSE, VM_PROT_READ) != KERN_SUCCESS) return NULL;
    return slot;
}

// 可写别名（帧率能耗线 10-24「拦写模拟」，docs/研究/拦写模拟.md）：同一槽、同一做法，只是设成可读写——缺页处替游戏把这条写写进同一物理页，
// 源页保持保护（别的线程照样陷入）。源页的最大权限没有写（只读映射的代码页等）就返回 NULL。与只读版共用本线程的槽：调用一次换一次映射，下次调用前有效
static _Atomic int g_alias_rw_bad;   // 起局自检：经可写别名写、源页读到才算可用
uint8_t *s2a_alias_page_rw(uint64_t host_page) {
    if (host_page & (ALIAS_PG - 1) || atomic_load(&g_alias_bad) || atomic_load(&g_alias_rw_bad)) return NULL;
    if (!atomic_load(&g_akey_ok)) return NULL;
    uint8_t *slot = pthread_getspecific(g_akey);
    if (!slot) return NULL;
    vm_address_t a = (vm_address_t)slot; vm_prot_t cur, max;
    if (vm_remap(mach_task_self(), &a, ALIAS_PG, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)host_page, FALSE, &cur, &max, VM_INHERIT_NONE) != KERN_SUCCESS
        || a != (vm_address_t)slot || (max & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) return NULL;
    if (vm_protect(mach_task_self(), a, ALIAS_PG, FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) return NULL;
    return slot;
}

// 起局自检一次：建页 → 写 → 收成不可读 → 别名读到原值 → 源页再写 → 别名读到新值。iPhone 上能不能这样自映射匿名页以这一行为准
static void alias_selfcheck(void) {
    uint8_t *p = mmap(NULL, ALIAS_PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    // 建不出测试页 = 两版都没验过：都判坏（原先只 return，可写版标志还是 0，会在没自检的情况下放行——原生层线 10-24 审出）
    if (p == MAP_FAILED) { atomic_store(&g_alias_bad, 1); atomic_store(&g_alias_rw_bad, 1); LOG("【红】别名自检：建测试页失败——缺页处模拟读 / 拦写模拟都退回老路"); return; }
    p[5] = 0x5a; mprotect(p, ALIAS_PG, PROT_NONE);
    const uint8_t *a = s2a_alias_page((uint64_t)p);
    int v1 = a ? a[5] : -1;
    mprotect(p, ALIAS_PG, PROT_READ | PROT_WRITE); p[5] = 0xa5; mprotect(p, ALIAS_PG, PROT_NONE);
    int v2 = a ? a[5] : -1;
    munmap(p, ALIAS_PG);
    if (v1 == 0x5a && v2 == 0xa5) LOG("别名自检：宿主页只读共享别名可用（源页不可读时读到原值、源页改写后别名同步）");
    else { atomic_store(&g_alias_bad, 1); LOG("【红】别名自检：不可用（别名%s，读到 %#x / %#x，应为 0x5a / 0xa5）——缺页处模拟读退回老路", a ? "建成" : "没建成", v1, v2); }
    // 可写别名：源页不可读写时经别名写，源页放开后读到写入值
    uint8_t *q = mmap(NULL, ALIAS_PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (q == MAP_FAILED) { atomic_store(&g_alias_rw_bad, 1); LOG("【红】可写别名自检：建测试页失败——拦写模拟退回老路"); return; }
    q[9] = 0x11; mprotect(q, ALIAS_PG, PROT_NONE);
    uint8_t *w = s2a_alias_page_rw((uint64_t)q);
    if (w) w[9] = 0x6c;
    mprotect(q, ALIAS_PG, PROT_READ | PROT_WRITE); int v3 = q[9];
    munmap(q, ALIAS_PG);
    if (w && v3 == 0x6c) LOG("别名自检：宿主页可写共享别名可用（源页不可读写时经别名写、源页读到写入值）");
    else { atomic_store(&g_alias_rw_bad, 1); LOG("【红】可写别名自检：不可用（别名%s，源页读到 %#x，应为 0x6c）——拦写模拟退回老路", w ? "建成" : "没建成", v3); }
}

// 拦写模拟自测（crash.c 有正式实现；只链本文件的单测用这个空的）
__attribute__((weak)) void s2a_emul_store_bench(void) {}
void s2a_alias_thread_init(void) {
    pthread_once(&g_aonce, akey_init);
    if (pthread_getspecific(g_akey)) return;
    uint8_t *slot = mmap(NULL, ALIAS_PG, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (slot == MAP_FAILED) { LOG("【红】别名：本线程槽申请失败，本线程缺页处模拟读退回老路"); return; }
    pthread_setspecific(g_akey, slot);
    static _Atomic int checked;
    if (!atomic_exchange(&checked, 1)) { alias_selfcheck(); s2a_emul_store_bench(); }
}
#ifdef S2A_UNIT_TEST
void s2a_alias_test_mark_bad(void) { atomic_store(&g_alias_bad, 1); }   // 单测：模拟自检没过
#endif

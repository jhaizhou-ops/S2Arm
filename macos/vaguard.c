// 地址窗口护栏（Mac 专用动态库 libs2a_vaguard.dylib，宿主弱链接；10-24 issue #100 D01）。
// macOS 27 起 libmalloc 的新分配器（xzm）在 libSystem 初始化里用固定地址映射（mach_vm_map，标志 0）一次保留 24 GB，
//   地址自己在 [0x70_0000_0000, 0x80_0000_0000) 里随机挑——共享缓存长到 51 GB、[64 GB, 448 GB) 是 GPU 保留区之后，2^39 以下只剩这一块（mini 实测）。
//   这比任何用户构造函数都早（vawin.c 的构造函数 101 也晚），整块 64 GB 窗口因此永远占不到。
// 做法：只拦「我们占窗口之前、不带覆盖标志、落进窗口的固定地址映射」，回 KERN_NO_SPACE。xzm 拿到失败不重试、改走不带大块保留的路径，进程照常（mini 实测）。
//   不覆盖任何人的映射：被拒的那块从没建成。窗口占完（vawin.c 调 s2a_vaguard_open）之后一律放行。
// 必须是单独的动态库：dyld 只认动态库里的 __interpose 段（写在主程序里不生效，mini 实测）；拦截在任何初始化之前就绑好。
#include <stdatomic.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
// S2A_VA_IOS26=1（模拟 iOS 26 大地址档，vawin.c）：另拦 iOS 26 大空洞那一段（Mac 上 [0x3_0000_0000, 0xF_C000_0000)），
//   xzm 的 24 GB 保留就不会落进来、把这段切碎（本机构造函数时刻实测：落在 0x826000000 起 24 GB）
#define IOS26_LO 0x300000000ull
#define IOS26_HI 0xFC0000000ull
static int ios26(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_VA_IOS26"); v = e && *e == '1'; } return v; }

#define WIN_LO 0x7000000000ull
#define WIN_HI 0x8000000000ull
static _Atomic int g_open;
static _Atomic unsigned g_refused;
static _Atomic unsigned long long g_refused_bytes;

void s2a_vaguard_open(void) { atomic_store(&g_open, 1); }
unsigned s2a_vaguard_refused(unsigned long long *bytes) { if (bytes) *bytes = atomic_load(&g_refused_bytes); return atomic_load(&g_refused); }

static kern_return_t guard_map(vm_map_t t, mach_vm_address_t *a, mach_vm_size_t s, mach_vm_offset_t m, int fl, mem_entry_name_port_t o,
                               memory_object_offset_t off, boolean_t c, vm_prot_t cp, vm_prot_t mp, vm_inherit_t in) {
    // 模拟 iOS 26 时 xzm 的保留落进那段：拒了它会断点退出（macOS 26 实测），改映射到 0x70 那块空洞（模拟时不用、远端伸出段到不了），回填实际地址
    if (!atomic_load(&g_open) && t == mach_task_self() && a && !(fl & (VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE)) && ios26() && *a < IOS26_HI && *a + s > IOS26_LO) {
        mach_vm_address_t alt = WIN_LO + (*a & 0x3FFFFFFFull & ~(mach_vm_address_t)0x3FFF);
        kern_return_t kr = mach_vm_map(t, &alt, s, m, fl, o, off, c, cp, mp, in);
        if (kr == KERN_SUCCESS) { atomic_fetch_add(&g_refused, 1); atomic_fetch_add(&g_refused_bytes, s); *a = alt; return kr; }
    }
    if (!atomic_load(&g_open) && t == mach_task_self() && a && !(fl & (VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE))
        && ((*a < WIN_HI && *a + s > WIN_LO) || (ios26() && *a < IOS26_HI && *a + s > IOS26_LO))) {
        atomic_fetch_add(&g_refused, 1); atomic_fetch_add(&g_refused_bytes, s);
        return KERN_NO_SPACE;
    }
    return mach_vm_map(t, a, s, m, fl, o, off, c, cp, mp, in);
}
__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } g_interpose[] = {
    {(const void *)guard_map, (const void *)mach_vm_map},
};

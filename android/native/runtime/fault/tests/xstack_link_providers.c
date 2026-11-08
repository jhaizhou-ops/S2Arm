// Link-only providers for the xstack PIC regression. Never executed and never
// included in the runtime target. Real entry.S/xstack.c/elf_host.c are linked.
#include "../../../../../runtime/src/native.h"
#include "../../../../../platform/plat.h"
#include <errno.h>

// entry.S（60bedc8de 惰性取核）直接 adrp/add 引用 g_lazy_core，并 bl s2a_guest_return；
// 生产定义在 thread.c，这里只补链接期符号。g_lazy_core 必须和生产一样 hidden：
// 默认可见时 ld.lld 会拒绝 ADRP 重定位（relocation ... cannot be used against symbol）。
#if defined(__ANDROID__)
#define S2A_ASM_INTERNAL __attribute__((visibility("hidden")))
#else
#define S2A_ASM_INTERNAL
#endif
S2A_ASM_INTERNAL int g_lazy_core = -1;

uint64_t gate_dispatch(uint64_t ret_addr, uint64_t *regs) {
    (void)ret_addr; (void)regs; abort();
}
void sw_thread_returned(void) { abort(); }
void s2a_guest_return(void) { abort(); }
int plat_tsd_init(void) { return ENOSYS; }
int plat_tsd_offset(uint32_t key, uint64_t *out) {
    (void)key; (void)out; return ENOSYS;
}
int plat_thread_stack_bounds(uintptr_t *low, uintptr_t *high) {
    (void)low; (void)high; return ENOSYS;
}

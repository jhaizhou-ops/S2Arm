// t_vaguard 用：模拟 macOS 27 libmalloc 在初始化里往窗口固定映射一大块（标志 0、不带覆盖），比主程序的构造函数早
#include <mach/mach.h>
#include <mach/mach_vm.h>
int g_fake_xzm_rc = -1;
__attribute__((constructor)) static void fake_xzm(void) {
    mach_vm_address_t a = 0x7400000000ull;
    g_fake_xzm_rc = mach_vm_map(mach_task_self(), &a, 12ull << 30, 0, 0, MEMORY_OBJECT_NULL, 0, FALSE, VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_DEFAULT);
}

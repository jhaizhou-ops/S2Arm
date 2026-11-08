// 仅本机 ARM64 .NET 消费者夹具：真实 Mach 别名。Android provider 算法仍是生产 readonly_copy.c。
// 不把本适配器当成 Linux mremap 验收；Linux 用独立 ARM64 native fixture。
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <errno.h>
size_t plat_page_size(void) { return (size_t)getpagesize(); }
int s2a_track_platform_protection(uintptr_t address) {
    mach_vm_address_t a=address;mach_vm_size_t n=0;vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t object=MACH_PORT_NULL;
    kern_return_t e=mach_vm_region(mach_task_self(),&a,&n,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if(object)mach_port_deallocate(mach_task_self(),object);
    return e!=KERN_SUCCESS || a>address ? -EFAULT : info.protection;
}
int s2a_track_platform_alias(uintptr_t address,size_t size,int protection,void **out) {
    vm_address_t a=0;vm_prot_t cur,max;*out=NULL;
    kern_return_t e=vm_remap(mach_task_self(),&a,size,0,VM_FLAGS_ANYWHERE,mach_task_self(),address,FALSE,&cur,&max,VM_INHERIT_NONE);
    if(e!=KERN_SUCCESS)return EFAULT;
    if(mprotect((void*)a,size,protection)){int saved=errno;vm_deallocate(mach_task_self(),a,size);return saved;}
    *out=(void*)a;return 0;
}
int s2a_track_platform_unalias(void *address,size_t size) { return vm_deallocate(mach_task_self(),(uintptr_t)address,size)==KERN_SUCCESS?0:EIO; }

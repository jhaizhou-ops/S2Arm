#pragma once
#include <stdint.h>
typedef uint64_t vm_address_t;
typedef uint64_t vm_size_t;
typedef int vm_prot_t;
typedef int kern_return_t;
typedef int boolean_t;
#define KERN_SUCCESS 0
#define TRUE 1
#define FALSE 0
#define VM_PROT_NONE 0
#define VM_PROT_READ 1
#define VM_PROT_WRITE 2
#define VM_PROT_EXECUTE 4
#define VM_FLAGS_FIXED 0
#define VM_FLAGS_OVERWRITE 0
#define VM_INHERIT_SHARE 0
#define mach_task_self() 0
static inline kern_return_t vm_remap(int a, vm_address_t *b, vm_size_t c, int d, int e, int f, vm_address_t g, boolean_t h, vm_prot_t *i, vm_prot_t *j, int k) {
    (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h; (void)i; (void)j; (void)k; return 0;
}
static inline kern_return_t vm_protect(int a, vm_address_t b, vm_size_t c, boolean_t d, vm_prot_t e) {
    (void)a; (void)b; (void)c; (void)d; (void)e; return 0;
}

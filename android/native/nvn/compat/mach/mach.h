// Android 兼容层：只覆盖 hle_nvn.c 的线程 CPU 时间统计；Android 返回 0，不伪造读数。
#pragma once
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
typedef uint32_t mach_port_t;
typedef int kern_return_t;
typedef int mach_msg_type_number_t;
typedef void *thread_info_t;
#ifndef S2A_THREAD_POLICY_T
#define S2A_THREAD_POLICY_T
typedef void *thread_policy_t;
#endif
typedef struct { int64_t seconds; int32_t microseconds; } time_value_t;
typedef struct { time_value_t system_time, user_time; } thread_basic_info_data_t;
#define KERN_SUCCESS 0
#define THREAD_BASIC_INFO 4
#define THREAD_BASIC_INFO_COUNT ((mach_msg_type_number_t)(sizeof(thread_basic_info_data_t) / sizeof(int)))
static inline mach_port_t mach_thread_self(void) { return 0; }
static inline mach_port_t mach_task_self(void) { return 0; }
static inline int thread_info(mach_port_t thread, int flavor, thread_info_t info, mach_msg_type_number_t *count) {
    (void)thread; (void)flavor; (void)info; (void)count; return -1;
}
static inline int mach_port_deallocate(mach_port_t task, mach_port_t port) { (void)task; (void)port; return 0; }
typedef struct { uint64_t phys_footprint; } task_vm_info_data_t;
typedef void *task_info_t;
#define TASK_VM_INFO 5
#define TASK_VM_INFO_COUNT ((mach_msg_type_number_t)(sizeof(task_vm_info_data_t) / sizeof(int)))
typedef struct { uint64_t total_user, total_system, task_interrupt_wakeups, task_platform_idle_wakeups; } task_cpu_energy_t;
typedef struct { uint64_t task_gpu_utilisation; } task_gpu_energy_t;
typedef struct { task_cpu_energy_t cpu_energy; uint64_t task_ptime, task_energy; task_gpu_energy_t gpu_energy; } task_power_info_v2_data_t;
#define TASK_POWER_INFO_V2 22
#define TASK_POWER_INFO_V2_COUNT ((mach_msg_type_number_t)(sizeof(task_power_info_v2_data_t) / sizeof(int)))
static inline int task_info(mach_port_t task, int flavor, task_info_t info, mach_msg_type_number_t *count) {
    (void)task; (void)flavor; (void)info; (void)count; return -1;
}
typedef uintptr_t vm_address_t;
typedef int vm_prot_t;
typedef int vm_inherit_t;
typedef int boolean_t;
#define FALSE 0
#define VM_FLAGS_FIXED 0
#define VM_FLAGS_OVERWRITE 0
#define VM_INHERIT_NONE 0
static inline int vm_remap(mach_port_t target, vm_address_t *to, uint64_t size, uint64_t mask, int flags,
                           mach_port_t source, vm_address_t from, int copy, vm_prot_t *cur, vm_prot_t *max,
                           vm_inherit_t inherit) {
    (void)target; (void)mask; (void)flags; (void)source; (void)inherit;
    if (!to || !size) return -1;
    // Linux 等价物（与 plat_vm_alias 同一内核机制）：mremap old_size=0 把共享页别名到固定 VA；
    // 源须共享背书（客机提交页恒 MAP_SHARED|ANON），私源如实失败。copy=TRUE 的 COW 快照无等价物，如实拒绝。
    if (copy) return -1;
    void *dst = (void *)*to;
    void *r = mremap((void *)from, 0, size, MREMAP_MAYMOVE | MREMAP_FIXED, dst);
    if (r == MAP_FAILED) {
        int e = errno ? errno : -1;
        // FIXED 失败可能已拆掉 dst 的预留：补回 PROT_NONE，目标仍不可访问（同 plat_vm_alias 失败恢复）。
        mmap(dst, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        return e;
    }
    if (r != dst) { munmap(r, size); mmap(dst, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0); return -1; }
    if (cur) *cur = PROT_READ | PROT_WRITE;
    if (max) *max = PROT_READ | PROT_WRITE;
    return KERN_SUCCESS;
}
static inline uint64_t mach_absolute_time_ticks(void) { return 0; }
typedef struct { uint32_t period, computation, constraint, preemptible; } thread_time_constraint_policy_data_t;
#define THREAD_TIME_CONSTRAINT_POLICY 8
#define THREAD_TIME_CONSTRAINT_POLICY_COUNT ((mach_msg_type_number_t)(sizeof(thread_time_constraint_policy_data_t) / sizeof(int)))
typedef struct { int pth_curpri, pth_priority, pth_policy; } thread_extended_info_data_t;
#define THREAD_EXTENDED_INFO 7
#define THREAD_EXTENDED_INFO_COUNT ((mach_msg_type_number_t)(sizeof(thread_extended_info_data_t) / sizeof(int)))
static inline int thread_policy_get(mach_port_t thread, int flavor, thread_policy_t policy, mach_msg_type_number_t *count, boolean_t *def) {
    (void)thread; (void)flavor; (void)policy; (void)count;
    if (def) *def = 1;
    return -1;   // 无实时策略
}
static inline mach_port_t pthread_mach_thread_np(pthread_t thread) { (void)thread; return 0; }
static inline int mach_wait_until(uint64_t deadline) {
    struct timespec t = {(time_t)(deadline / 1000000000ull), (long)(deadline % 1000000000ull)};
    return clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL);
}

typedef size_t vm_size_t;
static inline int vm_read_overwrite(mach_port_t task, vm_address_t address, vm_size_t size,
                                    vm_address_t data, vm_size_t *out) {
    (void)task;
    memcpy((void *)data, (const void *)address, size);
    if (out) *out = size;
    return KERN_SUCCESS;
}

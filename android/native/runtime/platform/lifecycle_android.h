#pragma once
#include <stddef.h>

// 单进程生命周期。成功表示真实收尾线程 / watchdog 已建立，不表示 guest 已停止。
int s2a_android_term_install(void);
int s2a_android_shutdown_watchdog_start(void);

// 同一 DSO 内的真实 NativeAOT / thread providers；不得由可选 dlsym 或成功空壳替代。
void S2A_CancelWaits(void);
int s2a_android_guest_writers_begin(void);
void s2a_android_guest_host_wait_begin(void);
void s2a_android_guest_host_wait_end(void);
int s2a_android_runtime_shutdown_result(void);
// 拆线程开着（托管运行时经 s2a_android_host_set_threaded 设）：收局诊断按拆线程的位置 / 限时走；单线程保持基线
int s2a_android_shutdown_threaded(void);
// 收局地址余量（s2a_vm_low("收局")）放到独立线程里有界地跑：等 SHUTDOWN_VM_LOW_MS，超时只打一行黄、不等（读 /proc/self/maps 可能被 mmap_lock 卡住）
void s2a_android_shutdown_vm_low(void);
// 诊断：正在进行的 writer epoch 里还没停稳的 guest 线程（一行文本，只 trylock 名册锁）；收局进度线程每 250 ms 调
void s2a_android_guest_writers_describe(char *out, size_t cap);

// Terminal-only writer acquisition; requires the SVC stop gate already closed.
int s2a_android_guest_shutdown_writers_begin(void);

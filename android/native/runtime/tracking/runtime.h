// Android tracking 的启动合同；不安装或替代进程的信号处理器。
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// 启动线程、guest尚未放行时调用一次：实际预分配tracker资源、选择完整读回语义。
// 不注册C# callback；NxTrack.Init在native readiness之后完成这一步。
int s2a_track_runtime_prepare(void);
// 托管初始化准备门：资源、真实已安装dispatcher、完整VM provider；不代表self-probe通过。
// GPU可在此门后注册回调/初始化；guest仍不能进入SDK。
int s2a_track_runtime_prepared(void);
// 以下任一缺失/未安装都返回0：资源、全局fault dispatcher、VM替页合同。
// 线程altstack分配成功不能替代全局SIGSEGV/SIGBUS/SIGTRAP安装证明。
int s2a_track_runtime_ready(void);

// MemoryTracking 两个真实 BeginTracking 入口调用：原子检查 alias / 替页意图并登记 GPU 范围。
// 0=已准入；EOPNOTSUPP=长期共享 alias；EBUSY=在途替页；其它 errno=输入/分配失败。
// 当前能力边界保留登记到进程结束（包括构造失败或 handle Dispose），后续 alias 可被保守拒绝。
int s2a_track_gpu_reserve(uint64_t addr, uint64_t size);

// GPU 启动线程一次注册，生命周期与进程相同；不可卸载/替换或只注册一半。
// before 同步暂停 GPU 队列、在旧映射有效时回写并失效旧资源；after 重建跟踪并恢复队列。
// 回调失败必须同步终止，不能仅请求异步 stop 后正常返回。
typedef void (*s2a_track_backing_before_fn)(uint64_t addr, uint64_t size, uint64_t source);
typedef void (*s2a_track_backing_after_fn)(uint64_t addr, uint64_t size, int mapped);
void s2a_track_set_backing_callbacks(s2a_track_backing_before_fn before, s2a_track_backing_after_fn after);

// VM writer：正常上下文、已停 guest writers、不持 VM/tracker 锁，旧页仍有效时 begin。
// 地址/长度须宿主页对齐；返回 errno（零=成功），失败不能修改映射。
// begin/end 串行、同线程同范围严格配对；到 end 结束前不得放行 guest。
// GPU 激活前的 loader 映射允许无回调；注册后绝不退回这种模式。
// source=0 普通替页；非零是同 size 的真实 alias 源，before 回写源但不解除源的跟踪。
int s2a_track_backing_begin(uint64_t addr, uint64_t size, uint64_t source);
// 安卓：mirror_end 翻回偶数、发布新页之前调用，把 tracker 记账清到新世代；仍在外层事务临界区。
// 必须在同一 begin/end 之间调用一次；end 检测到已 reset 就不再重复清。
void s2a_track_backing_reset_before_publish(uint64_t addr, uint64_t size);
// 内核映射成功或完整回滚后调用；mapped=1 包括失败但旧映射保留，0 仅用于已解除映射。
// 无法恢复合法映射应终止。先清旧 tracker 世代，再调用 managed after，不改新映射权限。
// committed=1 仅在内核与VM元数据实际提交成功；失败完整回滚用0，不能仅从mapped推断。
// 无论成功失败，mapped都描述end时真实可用映射；managed after仍只接收mapped。
void s2a_track_backing_end(uint64_t addr, uint64_t size, int mapped, int committed);
// 在途替页探测（checked store 提交用）：非 0 = begin→end 窗口开着，含 GPU before/after 与内核改映射窗口。只读、无锁。
int s2a_track_backing_busy(void);

// 由各真实owner实现，tracking不提供返回true的替身：
// fault owner确认生产dispatcher已接fault_guest/touch改道/restore，并确认信号链仍有效。
int s2a_android_fault_dispatch_ready(void);
// 实际安装的中间状态，不能以线程altstack或helper可链接代替。
int s2a_android_fault_dispatch_installed(void);
// VM owner确认prot_changed/host_write已接通，替换backing前排空/失效旧GPU资源、
// 替换后清理跟踪和重建资源；只有after-only backing_changed不满足此合同。
int s2a_android_tracking_vm_ready(void);

#ifdef __cplusplus
}
#endif

# Android native memory tracking

复用 `graphics/track/track.c` 的 4 KiB 子页状态、精确脏位和 GPU 回写合并算法。此目录只实现 Linux 平台操作和启动/替页合同，不维护第二套 tracker。

## 生产接线

- 编译共享 `graphics/track/track.c`、本目录 `platform.c`、`registry.c` 与 `runtime.c`，链接真实 `plat_android.c` 及其 memory/signal/TSD 依赖。不能用 Mach 兼容空函数或成功 stub。
- guest 尚未放行时调用一次 `s2a_track_runtime_prepare()`。Android 当前采用完整 CPU 读回、真实共享写别名；未接入指令模拟的读/写优化关闭。16 KiB 页的邻居可能一同读回，属于已知性能代价，不丢失 4 KiB 子页语义。
- `s2a_track_runtime_prepared()` 要求基础资源、真实已安装的 dispatcher 和完整 VM provider。GPU 在此准备门后初始化，由 `NxTrack.Init` 注册 touch 与替页回调。随后在真实 guest 线程完成 NativeAOT 初始化后的 fault 自检；最终 `s2a_track_runtime_ready()` 还要求该自检通过，才允许进入 SDK。两个门不改义，避免初始化循环。缺符号或 provider 未就绪都拒绝；线程 altstack、回调注册或单个测试不能替代生产条件。
- 回调与原生表的生命周期均为整个进程，不能在仍可能缺页时卸载 DSO。

## 缺页与别名

实际 dispatcher 先核 guest PC 和异常读写方向，再调用 `s2a_track_fault_guest`。返回 2 时在同一 guest 线程保存完整寄存器/浮点/TLS 上下文，离开信号上下文后调用 `s2a_track_touch`，恢复并重试；不能在信号中调用托管代码。Android 不复用仅按地址判断的旧 skip；每轮 GPU 脏化有新 generation，回调未解除同一轮脏态会同步终止，同期新 GPU 写则再次读回。快照真实耗尽也终止，不退化为会覆盖 CPU 新写的普通脏页。`fault/` 提供该跳板，安装和链路确认归 dispatcher owner。

共享别名复用 `plat_vm_alias` 的 Linux `mremap(old_size=0)`，源必须是真正支持别名的共享 backing。临时读/写别名不会打开原映射权限。私有 backing、不支持的内核或 SELinux 拒绝都失败，不能用 `memcpy` 或暂时解除原页保护替代。Linux 保护失败终止；外部权限或未知映射不由 tracker 擅自提升为可写。

## 两阶段替页

VM writer 必须先让所有 guest 写线程停稳，然后在旧页有效且不持 VM/tracker 锁时调用 `s2a_track_backing_begin`。GPU before 回调同步等待队列、回写旧数据并失效旧资源；其返回后才允许内核替页。

替页成功或完整回滚后，VM writer 恢复真实 guest 权限，再同线程调用 `s2a_track_backing_end`。`mapped=1` 也包括失败但旧映射有效；`mapped=0` 仅用于确已解除映射。第四参 `committed` 仅在内核与 VM 元数据实际提交时为 1，失败完整回滚为 0；不能从 mapped 推断成功。end 清除旧 tracker 世代，然后 GPU after 建立新跟踪并恢复队列，最后 VM writer 才恢复 guest。无法恢复映射或回调失败必须同步终止。仅置 freeze 标志不足以满足此合同。

注册回调前的 loader 初始映射允许没有 GPU owner；注册只允许一次，之后不能卸载。目标是一个连续范围；alias 的第三参 source 指定同长度的真实源，GPU before 在同一暂停期回写源，但只解除目标的跟踪。不能用包络区间让中间映射失效。registry 保存真实 alias 的 object/offset 与区间拆分，删除链中的中介映射后仍保留其余映射的物理关系；元数据只在 committed 时发布，失败回滚不误登记。

当前明确只支持 CPU-only alias。两个真实 MemoryTracking BeginTracking 入口调用 `s2a_track_gpu_reserve`，与 VM begin 共用短临界区：已有 alias 拒绝 GPU；已有 GPU 登记拒绝后来把源或目标建成 alias；在途替页的源/目标暂拒新 GPU 登记。不修改中间无关映射，不锁住 VM/GPU 队列等待。

GPU 登记目前保留到进程退出，包括 handle 构造失败与 Dispose，可能保守拒绝后来对已不使用范围建立 alias。这是已声明能力边界。不能把本 registry 当作 GPU alias coherency：它没有解决两个 GPU cache 的写入顺序；真实游戏需要 GPU 可见 alias 时必须另做完整实现，不能去掉准入检查。

## 验证与边界

Linux 原生主机运行：

```sh
python3 android/native/runtime/tracking/tests/run.py --out /tmp/s2a-tracking-tests
```

测试编译真实 tracker、adapter 和 platform VM，验证真实 `mprotect`/SIGSEGV、CPU 写失效、GPU 脏读写回写、同值写、共享别名、替页/失败保留/解除映射、旧世代清理与失败拒绝。测试用 `siglongjmp` 返回正常上下文，不冒充生产跳板。4 KiB 内核上的 16 KiB 运行仅为分组算法覆盖，不证明 Android 16 KiB 内核。macOS 的 amd64 Rosetta 不支持 `mremap(old_size=0)`，不能用该环境证明 alias 失败或成功。

Apple 原有 `gfx-test-track` 独立覆盖共享算法回归。NDK 单对象编译只证明 Bionic/API 兼容，Android 真实 fault 链、guest-writer quiesce、VM hooks、Vulkan 回写、SELinux/shared backing 和实际游戏仍须另行验收。

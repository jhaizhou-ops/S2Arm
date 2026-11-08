# Android Vulkan 游戏运行时

> 合流说明（2026-10-28）：本页说明与验证记录取 main；本线只有同一段落的旧版描述，已被 main 取代。本目录源码冲突已解；G1 的树侧适配见 [合并分析 §13.23](../../../android/docs/direct-main-merge-analysis-20261028.md)。原验证记录不代表本次候选重新通过。

`AndroidVulkanRuntime` 供 Android services 的 `AndroidGameRuntime` 直接调用；它创建一个
真实 Ryujinx `VulkanRenderer`，用同一 instance/device/queue 执行 GPU FIFO 和最终游戏纹理
合成。没有独立 diagnostic renderer。按实际设备能力与已启用特性准入；版本号本身不证明全部所需特性可用。

调用顺序与所有权：

1. 构造传入 native session 的非零 ID、现有 56 字节 lease 函数表，以及非阻塞失败回调。
   lease 状态仍是已有 80 字节 ABI。host 必须保持表、lease 和 DSO 有效直到 `Stop` 成功。
2. `CreateRenderer` 仅调用一次。services 用它建立 HLE；单线程时不套 `ThreadedRenderer`（拆线程开或 auto 选中时例外，见「拆线程」一节）。
   native backing callbacks 在这里登记，之后不可卸载。回调登记前的初始 loader 映射由
   native owner 根据尚无 GPU 资源的真实状态处理。
3. `Start(Switch, MemoryTracking)` 在 Application 完成注册后调用。它要求真实 native
   `s2a_track_runtime_prepared` 为 1：tracker 资源已分配、fault dispatcher 已实际安装、
   VM provider 完整接通。随后安装 NxTrack，等待 GPU owner 实际完成 renderer、shader
   cache 初始化。最终 fault-chain self-probe 要在 managed 初始化之后执行；native 在进入
   SDK 前仍须检查独立的 `s2a_track_runtime_ready`，prepared 不能代替 guest-entry ready。
   MME 使用现有解释器/AOT 表，shader 使用托管 SPIR-V
   producer。host 编译不证明 NativeAOT 动态代码检查或 Android 入口已经通过。
4. guest producers 必须先停止，然后调用 `Stop`。worker 排空已接受的 FIFO，等真实提交
   fence 和 WSI 退休后才 `DisposeGpu`。services 再释放 InputPump/HLE。
   启动只完成一部分、GPU 卡死、present 退休未证明等失败会抛错，**不能发布 quiesced**；
   host 保留对象、代码映射和 lease 至进程终止。

`fatal(Exception)` 只能请求 native 停止 guest，不能同步 join GPU worker。tracking 的
void 回调如读回失败，会先请求停止，再 `Environment.FailFast`：它不能返回 native 并让
原访问继续解保护/重试。Apple 默认 NxTrack 回调仍走原路径。

## backing 替换

Android 实例暂不启用 host-pointer import；硬件 capability facts 不变。
`PrepareHostMapping` 返回 false、host-pointer `CreateBuffer` 返回空句柄，真实上游消费者
使用普通 texture readback / buffer upload。额外复制成本留待后续优化，不能在未建立
imported allocation 范围撤销合同前重新开启。

private native ABI 为 `s2a_track_set_backing_callbacks(before, after)`：

- `before(dst, size, source)`：source 为 0 或同样大小的真实别名源范围。只在正常线程调用，
  不得持 VM/tracker 锁等待 GPU。native 串行化替页；source/dst 不需要相邻。
- GPU 尚未初始化时，没有 GPU 缓存需要回写。已经初始化时，GPU owner 先 drain，调用
  `GpuContext.PrepareBackingChange` 发布 Force/Strict/Syncpoint 动作，等待同队列有界
  fence。然后查询旧 VM 范围，对已映射的 source/dst 发真实非 precise write 事件，回写并
  标脏，再用 fence 证明完成，只对 dst 发 `MemoryTracking.Unmap`。
- `before` 返回到 `after` 期间 GPU owner 暂停。native 完成替页、更新 VM 元数据和 tracker
  reset 后，在同一线程调用 `after(dst, size, mapped)`。失败但保留/恢复原映射也传 1；
  实际解除映射传 0。无法恢复的内核失败必须终止。
- `after` 的 Map 后必须重新发 write 事件，因为 Unmap 会清 dirty 标记。返回后才恢复 GPU。
  范围不匹配、嵌套、超时或未成对的旧 after-only callback 均拒绝继续。

这套合同仍需要 native VM writer 的实际 begin/end 接线及 guest writer 协调。
持久 source/dst alias 采用明确的最小能力边界：CPU-only alias 正常运行；GPU 创建真实
tracking handle 时，通过该 `MemoryTracking` 实例的 `BeforeTracking` 调 native
`s2a_track_gpu_reserve`，原子拒绝真实 alias 或重叠的在途 backing 事务。native 创建 alias
也必须在同一 registry 同步域原子拒绝已被 GPU reserve 的 source 或 destination。
不能先 query 再创建，留下 TOCTOU。普通与 bitmap tracking 两个实际入口均覆盖。

reservation 保留到进程结束，包括 handle 构造失败、已经 Dispose 的情况；因此曾被 GPU
使用后释放的范围仍可能保守拒绝后来的 alias。完整别名物理身份与精确 live lease 是后续
兼容性工作，不能把该保守准入称为持续 GPU alias 支持。native registry 必须依据实际成功
的映射/回滚结果登记 backing 关系；`after(mapped=1)` 本身无法区分二者。native VM 接线与
并发反证需联合验收，host tracking 测试不证明这部分已经在 Android 生效。

## WSI 行为

`AndroidVulkanSurface` / `AndroidWindow` 编入原 Vulkan 程序集，以访问其真实 pool、queue
lock、helper shader 和 TextureView。使用 FIFO、真实源纹理 crop/aspect/insets，采用
identity preTransform 让 Android compositor 处理 rotation。baseline 只支持 nearest /
bilinear，不启用 AA；不修改 guest 渲染质量。

当 instance 依赖、device advertise 和 feature query 都成立时，实际启用
`VK_EXT_swapchain_maintenance1` 并给每次真实 present 加 fence。只观察实际成功的 submit /
present fence，再按现有 RetirementLedger 销毁资源和 ACK。普通设备用同 image reacquire
证明先前 present 完成；最终 detach 无足够证明时保留 lease，1.5 秒后失败，由 host 终止。
不把 QueuePresent 返回、等待一段时间或 QueueWaitIdle 当成 present 完成证明。

## 失败上下文

backing 事务使用 session 内的单调 ID，维护最后尝试的阶段，分别标识 old-backing flush 前后两个队列 marker。阶段不是完成、准许替页或致错提交的证明。失败时 Runtime 只向原异常的 `Data` 附加事务快照；Surface 的原 wait 非 Success 时附加原始 VkResult、实际等待耗时以及现成 queue/CB/fence 身份。managed thread ID 不冒充 native TID，等待耗时不包含前面的 flush/submit。

这两个位置不执行日志 I/O，不新增等待或 Vulkan 查询，不改变原超时、引用、保护、事件或失败退出。AndroidGameRuntime 复用既有 Fatal 的一次输出显示附加字段；该既有同步日志出口的阻塞风险没有在本项修复。正常事务不拼接诊断字符串或输出日志。`FenceHelper.AnySignaled/AllSignaled` 将负 VkResult 经现有 VulkanException 传播，Success 返回 true、Timeout 返回 false；不再把设备丢失当作超时继续。SyncManager 的“1000ms”文案仍不能当作实际耗时；marker 报 DeviceLost 只说明在此发现设备丢失，不能据此认定本次换页引起故障。纯 CPU 返回值回归见 [fence-tests](../core/fence-tests/README.md)，不代替实际 GPU 或游戏验收。

依据：[Khronos maintenance1 依赖与 present fence](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_swapchain_maintenance1.html)、
[Android surface rotation 示例](https://docs.vulkan.org/samples/latest/samples/performance/surface_rotation/README.html)。
这些规范来源不证明某台设备实际支持该能力。

## 拆线程（ThreadedRenderer；外壳缺省关，`auto` / `true` 显式开）

```sh
adb shell am start -S -n <application-id>/org.s2arm.android.MainActivity --ez s2arm.threaded_renderer true    # 开
adb shell am start -S -n <application-id>/org.s2arm.android.MainActivity --ez s2arm.threaded_renderer false   # 关 = 单线程基线
adb shell am start -S -n <application-id>/org.s2arm.android.MainActivity --es s2arm.threaded_renderer auto    # 按本游戏上局记录
```

外壳每次游戏启动都在宿主创建前经 JNI 显式设 `S2A_ANDROID_THREADED_RENDERER`（`0` | `1` | `auto`）：带 extra 取 extra（`--ez` 布尔，或 `--es`
`true|false|auto`，别的类型 / 取值直接报错），不带取 `MainActivity.THREADED_RENDERER_DEFAULT`（`"0"`，单线程基线）。运行时未设 = 0，不认的值 `CreateRenderer`
抛错，不按关处理；`auto` 要宿主传游戏状态目录（`AndroidGameRuntime` 传 `state`），没有就抛错。`0` / `1` 是显式覆盖：不读也不写 auto 记录。

**关（0）= 单线程基线**：`_threaded` / `_render` 都为空，`Run` / `DrainAndPoll` / `WaitPump` / `CopyGuestMemory` 与 integration 逐字相同；
共用方法只多一层「单线程即原调用」：`ExportProfileIfRequested` / `MountShaderPack` 读 `VulkanBackend`（关时就是 `_renderer`）、
换页 marker 调 `CompletePendingCommands()`（关时就是原来的 `_surface.CompletePendingCommands(1000)`）、`BeginBackingChange` / `Stop`
多一个 `_render != null` 判断；`S2AReportLoop` 每 5 s 把窗口交给 `RecordAutoWindow`、`Fail` 在 fatal 之后多一个 `_auto` 判断
（只有 `auto` 时才有记录对象，`0` 时立即返回）。
`auto` 选了单线程也走同一个 `Run`。GAL 层的新入口只有宿主调 `S2AConfigureBounds` / `S2ARunBackend` 才生效，单线程和 Apple 都不调。

**开（1）**：`CreateRenderer` 把同一个 `VulkanRenderer` 套进 Ryujinx `ThreadedRenderer`（补丁 0283），HLE 拿到的是套层：

| 线程 | 做什么 |
|---|---|
| S2A.GPU（GPU 模拟，`RunThreaded`） | GPFIFO 解码 / DeviceState / UpdateState / BufferCache 读 guest 内存 / 写跟踪排空 / 着色器缓存；换页事务所有者；GAL 调用只入队 |
| S2A.GPU.Vk（渲染，`RenderMain`） | 下层 Vulkan 初始化（所以 WSI 租约 owner、窗口 / swapchain、主命令池都归它）、全部 GAL 命令执行（录制 / 提交 / 出图）、WSI 轮询与退休、出图计数与 `FramePresented` |

### 接点

1. **出图身份（stamp）**：渲染线程执行出图命令时取（`AndroidWindow.Present` 原样），等价于单线程把 Present 推迟至多一帧：
   旧代窗口上 `MayPresent` 照样拒绝；`SignalFrame`（GAL 节流，命令开头）/ `ReleaseCallback`（模拟线程，入队后）/ `swapBuffersCallback`（Android 为空）各一次。
   出图领先最多 1 帧的约束不变：`ThreadedWindow.Present` 入队前等上一条出图命令开始执行。
2. **WSI 归渲染线程**：模拟线程不碰 surface（`DrainThreaded` 不轮询，主循环不 Poll、不读出图计数）；渲染线程空等 8 ms 超时、批末、
   批内每 64 条命令按时（≥ 8 ms）回调 `RenderPoll`，持渲染线程锁执行；驱动等待泵 `RenderWaitPump` 只在渲染线程上轮询 WSI。
   `NativeLease` 的 owner 线程检查会直接拒绝模拟线程误碰。
3. **换页前排空 GAL 队列**：`PrepareBackingChange` 的两个 marker 改成 `OnRenderThread`：一条同步命令让渲染线程先执行完已入队命令，
   再 flush + 有界 fence；返回时队列为空，模拟线程是唯一生产者且停在事务里，`before`→`after` 之间没有新 GAL 命令。
   旧 backing 回写的读回经同步命令走。反证断言：渲染线程发起换页、渲染线程读 guest 内存都直接抛错。
4. **停止 / 失败顺序**：模拟线程排空 FIFO → `Gpu.PrepareBackingChange` → 渲染线程上 marker → 渲染线程上打收局累计行、`Surface.Stop`
   + 有界退休证明 → 模拟线程 `DisposeGpu`（`ThreadedRenderer` 收局：同步命令在渲染线程上释放 Vulkan，再放倒并有界地等渲染线程退出，不 Join 自己）。
   租约 Stopping 时模拟线程自己退出主循环，走同一顺序。渲染线程命令抛错：失败闩先发布原异常（先到为准），再放开所有等待方，
   等待方按原异常重抛（不返回空结果）；`Fail` 首个异常锁存，`Stop` 返回该异常，对象保留到进程结束（同单线程）。
5. **出图计数归渲染线程**：渲染线程每条出图命令执行完调 `RenderAfterPresent`，成功排队数增加才回调 `FramePresented`，单写者。
6. **上传**：评估过给 Vulkan 补上传租约（`S2ATryRentUpload`），没做：Vulkan 的 `SetData` 有三条路（宿主可见且不在用的缓冲直接写映射、
   镜像、`StagingBuffer.PushData` 环），暂存环只在渲染线程上按命令缓冲 fence 回收；租约要新做一个跨线程可租、按 fence 回收的暂存分配器，
   并且直接写映射那条路上租约反而多一次拷贝。保留 `SetBufferData` 拷进 8 MiB 环形池的那一次拷贝，计数进读数（9000 Wonder 0.64–0.65 MB/帧，见限制）。
7. **读回**：保持排空语义（每次同步命令都是整条流水排空），按类型计数（读回 缓冲 / 贴图、动作、程序、其他）与等待时长进读数。

### 上限与依据

| 上限 | 值 | 依据 |
|---|---|---|
| 已入队未执行条数 | 9999（命令环全部可用槽） | 命令环 10000 槽构造时预分配（启动行打印 KiB），条数不是内存口径；出图节流已把队列限制在约两帧命令以内，9000 Wonder 全窗口峰 4050–6514 条（65 %）。压低只会在重帧上让模拟线程提前等渲染线程、改变已测配置，不省内存 |
| 在途载荷字节 | 64 MiB | 贴图 `SetData` 数据与环形池放不下的新分配：单线程时当场消费，拆线程后排队期间仍持有，不设上限时只受条数约束（9999 条 × 每条可到几十 MB）。64 MiB = 拆线程比单线程额外驻留的上限（另加至多一块超大载荷）；9000 Wonder 环形池放不下 0 次，贴图上传量 P0 未计数，本版起进读数 |
| 渲染线程卡住 | 前台连续 2000 ms 不前进 + 宽限 250 ms | 「前进」= 执行完一条命令、轮询一次宿主、处理一次中断、宿主报活（编译通道等有期限的泵、WSI 退休等待）。2000 > 渲染线程上有期限但不泵的单步（marker fence 1000 ms、acquire 1000 ms）；2000 + 250 + 50（分片）< 换页回调前台 3000 ms 预算，换页时渲染线程卡住先报出这里的精确诊断。更紧的是原生 writer 准入等待的 2 s（另一条游戏线程进内存 SVC），拆线程下按换页推进续期（见下两行），推进停了还有 4 s |

| 换页回调等 GPU（guest 侧，拆线程） | 前台渲染侧连续 3000 ms 没干活才超时，一直在干活续期，总上限 30 000 ms | 换页 marker 要先排空整条 GAL 队列，单线程时控制轮询在命令缓冲之间，只等当前命令缓冲；拆线程时等的是整条积压（加载期首遇现编可以连续数秒）。「没干活」= `S2AWorkProgress` 不动（没执行命令、也没泵编译通道；空等轮询不算），与单线程 3 s 同口径；30 s 与 GPU 启动期限同量级。夹具：100 × 50 ms 的积压让 prepare 晚到约 5 s 而不超时 |
| 别的游戏线程等换页 SVC 放开 writer serial（原生，拆线程续期） | 原 2 s；拆线程换页等待在推进时续期到「最近推进 + 3000 + 1000 ms」，总上限「host共同起点 + 30 000 + 1000 ms」 | 换页 SVC 持 writer epoch 等 GPU 排空期间，另一条游戏线程进内存 SVC 要等 serial，原生原来固定 2 s 后 `die`（复审第 2 轮 P1-A：续期把超过 2 s 的排空变成合法路径）。托管侧每看到渲染侧前进一次就把推进与本表上一行的两个上限发布给原生（`s2a_android_host_backing_progress`），原生准入等待按同一组上限各加 1 s 续期，托管侧先给出精确诊断。原生直接读同一租约生产方的前后台与生命周期代次，后台不累计，代次变化由首个观察者重置host共同total起点，idle按观察重置；发布绑定writer epoch与整个事务的owner token；请求对GPU可见前登记，阶段只增不减，End确认Finished后关闭，旧等待不另领或撤销。原生缓存同时识别事务owner，同epoch下一分段重新计算预算。撤销不算工作推进；已接受的当前 epoch 预算仍在后台暂停、恢复或代次变化时重置，后台失效期限为无限，100ms只作为futex轮询片；新epoch清缓存，曾扩展的等待取得serial后进入自己的2s停稳预算，false维持原始2s。排空期间渲染线程真卡住时推进停止，原生要再等 4 s，卡住判据（2250 ms）先报。单线程不发布推进，原生保持 2 s。原生用例：writers-gate `progress-published`（3 s 推进中的 epoch，第二条线程不 die）、`progress-stall-published`（推进 0.5 s 后停，按无干活上限 + 1 s 超时）、负控去掉续期 → 红 |

超上限时模拟线程背压等（`Thread.Sleep(1)` 轮询，次数与时长进读数），不是无界增长。载荷背压只等「已发布、渲染线程能执行掉」的在途载荷：
已发布的清零后一律放行，所以单块比上限大、或同一条命令的第二块都不会永远等。

### 有界等待与失败路径

`S2AConfigureBounds` 后，等渲染线程的各处都分片（50 ms）等并查：同步命令、出图节流、条数 / 载荷背压、中断（`WaitSync` 经 `SyncManager`
中断提交）、同步号登记、`FlushThreadedCommands`、收局等渲染线程退出，以及非 GPU 线程等缓冲 / 贴图 / 计数事件在渲染线程上建好、等渲染线程锁；
Vulkan 计数队列 `FlushTo`（计数事件 Flush 等计数结果，结果所在命令缓冲要靠渲染线程提交）每 1 ms 醒来经 `S2AWaitCheck` → `S2AWaitTick` 同样有界（复审 P1-5）。
例外：计数消费线程在 GPU 不写结果时仍按上游自旋（`BufferedQuery.AwaitResult`），它不是等渲染线程的一方；非 GPU 线程持渲染线程锁做的读回在驱动 fence 上等 GPU。
只在前台计时，前后台读外壳写进租约生产方的生命周期（`s2a_android_host_lifecycle` → `s2a_wsi_lifecycle`：onResume / onPause 设的前后台与转换次数，任意线程可读），不靠渲染线程自己 Poll 出来的 `_surface.Foreground`——渲染线程卡在长命令里时它不 Poll，旧值会一直停在前台（复审 P1-2）。后台 Android 可能冻结整个进程；转换次数变了（中间切过后台）就重新计时，判卡住前再宽限 250 ms
（刚解冻的渲染线程要先跑起来）。判为卡住：置失败闩（放开其他等待方）→ 调宿主 `Fail`（首个异常锁存、fatal 回调请求停 guest，不阻塞）→ 当前线程抛
`TimeoutException`（文案带【红】、等的是什么、已入队条数、渲染线程正在执行的命令类型、在途载荷），之后与渲染线程抛错同一条路；写跟踪回调里遇到则照旧
`FailTracking` → `FailFast`。不改成功语义：不返回空结果、不跳过命令。

### 等待图（箭头 = 等）

- guest 线程（换页 before / after）→ S2A.GPU：前台按渲染侧干活续期（3 s 无干活 / 30 s 总上限），后台无界（同单线程）。
- S2A.GPU → S2A.GPU.Vk：上面列的各处，全部有界。等待时它前面的命令都已发布（单生产者；背压在取槽 / 分配之前），渲染线程总能执行掉。
- 非 GPU 线程（写跟踪回调、计数线程等）→ S2A.GPU.Vk：等对象建好、等渲染线程锁，有界。
- S2A.GPU.Vk → 驱动 / GPU：marker fence 1000 ms、acquire 1000 ms、编译通道 120 s（泵着、报活）、WSI 退休 1500 ms（报活）、读回 fence。
- S2A.GPU.Vk → 非 GPU 线程：只经渲染线程锁；持锁方在一次下层直调里，不等 S2A.GPU / guest。
- S2A.GPU.Vk 不等 S2A.GPU、不等 guest，不拿 `_backingGate`、写跟踪锁或 GPU 层锁，不读也不写 guest 内存：
  - 读：渲染线程读 guest 内存直接抛错（`CopyGuestMemoryOffRenderThread`），发起换页直接抛错。
  - 写（复审 P1-4）：GPU 层唯一会从 GPU 线程排到渲染线程的动作是 `TextureGroup` 回写（`BackgroundContextAction`，非 alwaysBackground），
    原版会把它排成 ActionCommand 在渲染线程上执行：`SignalModifiedDirty`、`lock (handle.Overlaps)`、`FlushSliceRange` → `PhysicalMemory.WriteUntracked`
    → 原生写跟踪。补丁 0283 在宿主自起线程模式下让这类动作在 GPU 模拟线程上就地执行（Vulkan 没有 GL 的上下文线程绑定，单线程时它本来就在这条线程上；
    动作里的读回照常排成同步命令），宿主自己要在渲染线程上执行的工作改走 `S2AOnRenderThread`。所以「渲染线程 → GPU 层锁 / 写跟踪」这条边不存在
    （`BackgroundActionOnEmulationThread` 用例与负控）。`Buffer` 回写本来就是 alwaysBackground（调用线程上执行）。

没有回到 S2A.GPU 或 guest 的边，图无环。受控夹具见 `control-tests/ThreadedChecks.cs`（夹具未执行真实 GPU/Android）。

### 收局

- 宿主收局顺序：外壳 onPause / Surface detached → 原生收局线程起 1.5 s 兜底（`s2a_android_shutdown_watchdog_start`，最终线程不做文件/Android logger I/O，期限到 `_exit(124)`）→ 一串收局诊断
  （写跟踪 / 调度 / 系统调用计数、游戏地址用量，只读内部账）→ `S2A_CancelWaits`（`S2AShutdown.Request`）→ 停游戏线程系统调用（≤ 300 ms）/ writer epoch
  → 服务层 Cleanup → `StopGpu` → `Stop` → Android：「地址余量 [收局]」（`s2a_vm_low` 读两遍 `/proc/self/maps`）放到这里，独立线程跑、最多等 150 ms，超时只打一行黄。
  读 maps 要 mmap_lock 读锁：收局前段游戏 / GPU 线程还在 mprotect / mmap，拆线程下真机 9000 读了 862 ms（D 态 `__down_read_killable`）或读不完卡到兜底，收局请求发不出去。
- 拆线程时运行时登记 `S2AShutdown.OnRequest`：请求一到（早于 Stop）就停用卡住判据（之后只受宿主期限约束，复审 P1-6）、auto 不再评估 / 固定、把一次驱动管线缓存落盘排到编译通道
  （与管线创建串行；释放时先有界等提前落盘的后台写，再存一次，但提前落盘之后没有新管线就不重存；两次写盘按快照版本串行，旧快照不覆盖新快照）。没经宿主请求就停（租约 Stopping、直接 Stop）时，模拟线程退出主循环后同样停用判据、结束 auto 评估。
- 宿主收局（Stop / 收局请求到了，进程马上 `_exit`）时拆线程不逐个释放下层：排空 FIFO、排空 GAL 队列、渲染线程上退休 WSI 之后，GPU 层照常释放自己的账
  （写跟踪句柄等，之后服务层还会动 guest 内存），但 `ThreadedRenderer.S2ADiscardFrees` 让缓冲 / 贴图 / 程序 / 采样器 / 数组 / 计数事件的下层释放命令不再入队，
  `S2AExitRelease` 在渲染线程上代替下层 Dispose：只把提前落盘之后新建的管线补存一次（编译通道，最多等 300 ms），不停编译通道、不销毁 Vulkan 设备与对象（随进程回收）。
  在 GPU tracking 释放前，先关闭 counter 的 guest 回调，总计最多 100 ms 尝试停止/Join 消费线程；已经执行的回调拿不到闸门就抛 TimeoutException、保留 GPU/tracking。
  正在取结果的消费线程可以保留，但晚到结果不能再回调 guest，查询与事件均留到进程退出，不重新引入逐对象 Dispose。只在 Android 拆线程启用 callback gate；其他平台原样。
  完成行带各步用时（排空 FIFO / GAL 队列 / WSI 退休 / GPU 层释放 / 其中渲染线程上的下层收尾）。租约 Stopping（进程不退出）照原样全量释放。
  依据：9000 `01a3af10` true 3 局「释放 GPU」一段逐个释放走 GAL 队列（渲染线程在 ProgramDispose / BufferDispose），到 +1.0–1.2 s 才进到下层 Dispose 的管线缓存那一步，
  之后的下层销毁还没完就被兜底结束，完成行一局都没打出来。单线程不变（同包 false 也没打出「优雅退出完成」，同样在 1.5 s 兜底前没收完，见坑记录）。
- 原生兜底标识由独立线程写普通 host 文件与 logcat；最终 watchdog 不执行这些 I/O、不等日志线程，仅给固定 1 ms 调度机会后 `_exit(124)`。
  普通文件的 `O_NONBLOCK` 无效，不能作为退出保证；阻塞标识写入的注入下，true/false 与 b114df2f 均约 1.5 s / 124。
  标识为尽力写，缺行不能当作优雅成功。完整成功仍须原生「优雅退出完成」。
- Android 服务收尾在关闭驱动前显式清理登记的 AudioManagers，先唤醒 pause event，停止并 Join 独立音频 worker，再由 Switch.Dispose 关闭驱动事件。
  原生 park Horizon 服务线程后，AudioUserIpcServer.Shutdown 无法执行；formal4/6 共 7 个 GPU 拆线程完成局均在后续 AudioProcessor.Signal 上 ObjectDisposedException/SIGABRT。
  b2 12 局无同异常，但只有 2 局优雅完成；单线程臂 8 局仅 1 局完成，其他删失不能证明音频安全。主机已复现同栈并先红后绿；修复后的设备收尾证据见下方 formal7/9/10。
- 收局诊断（缺省开，量小，不改语义）：
  - 托管（拆线程）：请求后每 250 ms 一行「拆线程收局 N ms」：Stop 是否已到；模拟线程在哪一步、主循环第几轮、多久没转；渲染线程正在执行什么命令、多久没执行完新命令；
    此刻在等渲染线程且已等满 50 ms 的每个线程（S2A.GPU、guest 写跟踪回调线程、计数线程……）等什么、已等多久（GAL 8 格登记，每片 50 ms 醒来更新一次，不到一片的等待不碰）；
    换页事务；缓存落盘状态。1200 ms 起这一行标【黄】（原生兜底 1500 ms；成败交给兜底与局后判读，收得慢但成功的局不出红）。收完打「拆线程收局完成：宿主收局请求后 N ms」（≥ 1200 ms 标黄）。
    收局请求回调跑在原生收局线程的 `S2A_CancelWaits` 里，它的日志交线程池写（stderr 管道满时不卡收局第一步）。
  - 原生（只在拆线程起进度线程，单线程保持基线）：收局线程起兜底后再起一条进度线程，每 250 ms 一行「收局进度 +N ms（原生）」：收局线程与 `S2A.GPU*` 线程的内核态
    （`/proc/self/task/<tid>/stat` 状态、`syscall` 当前系统调用——read / write 带 fd 指向的文件、`wchan`），以及正在进行的 writer epoch 里还没停稳的 guest 线程
    （句柄、在系统调用里 / 在宿主侧回调里 / 在游戏代码里还没响应停车信号，只 trylock 名册锁）。这条线程写日志被满管道卡住只卡它自己，兜底照常。
  - 「地址余量 [收局]」行带读 maps 用了多少 ms。
- 真机读数见 `docs/坑记录.md`「Android 收局只有 1.5 s」与「收局诊断读 /proc/self/maps 卡住收尾」。
- 原生进度行另带每条线程「上一拍 CPU N ms」（R 态时区分自旋 / 长循环与等调度）与内核栈前两帧（`/proc/<tid>/stack`，一般要 root，读不到就不写）。

### 读数

渲染线程上每 60 帧一行（第一次出图只当起点），收局一行累计（在渲染线程上、WSI 停止之前打，截至最后一个整窗口）：

```text
[s2a] 拆线程开（S2A_ANDROID_THREADED_RENDERER=1）：…；上限：已入队 9999 条、在途载荷 64 MiB，预分配 命令环 <KiB> + 环形池 8 MiB；渲染线程前台连续 2000 ms（宽限 250 ms）不前进按失败处理
[s2a] 拆线程 60 帧：呈现 <帧/s>；模拟线程 CPU <ms/帧>（FIFO 空等 <ms>、出图节流等 <ms/帧>）；渲染线程 CPU <ms/帧>（空等 <ms/帧>，醒 <n> 次）；
  同步命令 <n> 次、等 <ms/帧>（单次 max <ms>；读回 缓冲 <n> / 贴图 <n>，动作 <n>，程序 <n>，其他 <n>）；同步号等 <n> 次 <ms/帧>；
  队列深度 出图时均 <n> / 峰 <n>；上传多一次拷贝 <MB/帧>（环形池放不下 <n> 次 <MB>）；非 GPU 线程直调 <n> 次；
  背压 条数 <n> 次 <ms/帧>、载荷 <n> 次 <ms/帧>；在途载荷 <MB/帧>（峰 <MB>）
[s2a] 拆线程收局（截至最后一个整窗口）：<n> 帧、<s>（<帧/s>）；…；队列深度峰 <n> 条；背压 条数 <n> 次、载荷 <n> 次（共 <ms>）；在途载荷共 <MB>（峰 <MB>）
```

（60 帧行实际是一行，新字段都加在 P0 字段之后。）CPU 用各线程自己的 `pthread_getcpuclockid` 时钟；`GPU 循环 5s` 行在拆线程时只记模拟线程，
其中 present 段含出图节流等待。

### 缺省策略：缺省关；auto（按实测负载，下局生效）显式开

同一个 P0 包（APK SHA-256 `1facc141…6d31`）、Wonder 固定路线、D/T 各 3 局：

| 设备 | 单线程 D | 拆线程 T | 结论 |
|---|---|---|---|
| 天玑 9000 / Mali-G710 | 37.25 Hz，S2A.GPU 忙 0.98 | 52.13 Hz（+39.9 %） | S2A.GPU 饱和、低于请求，拆线程有效 |
| 8E / Adreno 830（HA2642NT） | 59.64 Hz，忙 0.63，GPU 循环 10.4–10.8 ms/呈现 | 59.76 Hz（+0.2 %），两线程 CPU 合计约 21.5 ms/帧（12.5–12.9 + 8.8）；游戏速度 t(x=760) 晚约 2 s（原因没查） | 已达请求，拆线程没收益、CPU 约翻倍（能耗风险） |

所以不能一刀切开，也不能按设备 / GPU 写死（通用层零专用配置）。按维护方规矩（底层性能改动缺省关合入，真机同包 A/B 达标后再翻缺省；
快速测试与精修流程 3.6，协作循环 §4 同口径），本 PR 外壳缺省 `0`（单线程基线），`auto` / `true` 经 `s2arm.threaded_renderer` 显式开。
翻缺省到 `auto` 另起 PR，条件：9000 正式版 A/B 达标 + 8E auto 留单线程 + 至少再 1 款游戏冷启 / 稳定性通过。

`auto`（显式开）：每款游戏在本机各留一份记录
（游戏状态目录 `threaded-renderer.auto`），按上局实测决定本局，本局测完写记录、下局生效：

- 窗口 = S2A.GPU 主循环的 5 s 报告窗：忙 = 该线程 CPU 时间 / 墙钟（等驱动 fence、acquire 时线程阻塞，不算忙；拆线程时是模拟线程），
  呈现 = 本窗出图次数 / 墙钟，请求 = `ObserveFrameInterval` 收到过的最小交换间隔（最高速率，与局后判读 score.py 同口径；自适应的游戏跟不上时临时退到间隔 2，9000 Wonder 间隔 1 / 2 交替，要的仍是 60）；没收到按 60 Hz，交换间隔 0 = 不限。
  呈现 < 10 Hz 的窗（加载无出图）不计并打断连续计数。饱和窗 = 忙 ≥ 0.85 且呈现 < 0.95 × 请求；饱和段 = 连续 6 个饱和窗（30 s）。
- **评估覆盖整局**（9000 真机复测：fc7cb6e6 版前 12 个有效窗全在标题 / 菜单——忙 0.83、44.1 Hz——就记了单线程，进关后 37.7 Hz、忙约 0.98 却没机会改）：
  - 单线程一局：任何时刻出现饱和段 → 记「拆线程」（本局结论定）；累计 36 个有效窗（180 s）仍没有饱和段 → 记「单线程」并继续评估，之后再出现饱和段就改写为「拆线程」；
    不到 36 个有效窗就结束 / 被杀 → 不写，记录保持上局（没完成的评估不当结论）。
  - 拆线程一局：只比同类窗——本局「连续 6 个有效窗呈现 < 0.95 × 请求」段（不再要求模拟线程忙：拆线程后瓶颈可能移到渲染线程 / GPU，
    模拟线程在出图节流 / 背压 / 同步命令上阻塞而不忙，复审第 2 轮 P1-B）的呈现中位 vs 单线程饱和段中位：≥ 1.05 × → 保持；否则「没收益」计一次，
    连续 2 局没收益才固定单线程（第 1 次只记单线程，下局重新测）；36 个有效窗都没有低于请求的段（重场景也够得着请求）→ 保持。够得着请求的菜单窗不进比较。
- **固定单线程** = 之后 10 局 auto 都单线程、不评估，用完自动重新评估。只有拆线程自身的卡住判定（渲染线程不前进）会固定；DeviceLost、写跟踪失败、
  启动取消等与模式无关的失败不写记录；收局阶段（宿主收局请求到达或模拟线程退出主循环之后，先到为准）不评估、不固定。`--ez s2arm.threaded_renderer true|false` 随时显式覆盖。
- 记录 v2（`key=value`）：数值必须有限且在范围内（请求可为不限）、`no_gain` / `pinned_left` 在范围内、`reason` ≤ 300 字；读不了 / 不合法报【红】按无记录单线程重新测并改写；
  v1 旧记录按无记录重测。写盘在线程池上做（不在 GPU 主循环、不在 `Fail` 路径上同步写），按决定顺序最后一份为准；写不了报【红】，只丢这份结论。
- 每次启动打一行 `[s2a] 拆线程 auto：本局<拆线程|单线程>（<依据>；记录 <路径>）`，有结论时打 `[s2a] 拆线程 auto：下局…（<依据>）`。

按上表：9000 第一局单线程，进关后 30 s 记「拆线程」，第二局起拆线程（饱和段 52 Hz ≥ 1.05 × 37.7 → 保持）；8E 忙 0.63，180 s 后记「单线程」，不付 CPU 翻倍的代价。
30 帧的游戏跑满自己请求的 30 帧时不切（不管多忙）；请求不限帧时只看忙。

**为什么不在运行中切换**：评估过，不可行——HLE / `GpuContext` 拿到的渲染器对象在构造时定死，GPU 层所有活资源（缓冲句柄、贴图、程序、采样器、
计数事件）按当时的渲染器类型建：单线程是 Vulkan 原对象，拆线程是 `Threaded*` 句柄 + 句柄映射表，中途换要把全部活资源重新包装 / 重映射，没有安全点；
WSI 租约 owner 是做 Vulkan 初始化的线程（`NativeLease` 构造时记线程、每次 Poll 查），单线程时是 S2A.GPU，拆线程要求是 S2A.GPU.Vk，换 owner 等于退休
swapchain 与租约重建；合批语义（`SetInterruptAction`）只在构造期装；换页 / 停止合同两套等待路径之间的过渡也要另证。下局生效的代价：每款游戏在
每台设备上第一局总是单线程；不到 180 s 的单线程短局没有结论；场景差异（同一款游戏不同关卡负载不同）仍可能让结论在局间翻转，连续 2 次没收益才固定、固定 10 局后重评；清游戏数据就重来。

### 正式包最新读数（历史包，不代表本轮修复后真机验证）

9000/Mali-G710，Wonder Handheld 1x，formal4 源码 `19eb4aac`、APK SHA `bbeb85056c85969bfa488183973df5f622b876d317889ceda239f1dcc7cc7127`：
原三对 ABABAB 观察窗 SF 中位 36.19→46.48 Hz（+28.4%）；统一 16.667 ms 目标槽后，1 槽占比 36.95%→72.79%。
完整局有效仅 false=1 / true=3，c4-F 补局仍收尾失败；观察窗中位不能当三对完整有效验收。
PSS T−F 在 birth+60/+290s 为 +75.8/+102.6 MB，Graphics +17.9/+52.1 MB。未观察到此前冷启首帧延迟。
formal6 源码 `44878c8d`、APK SHA `5b022c2bffa94d85e5441191e6bda586e1f040dbd701f7c38d04ca2202b3e302`：
true GPU 阶段 1104/984/684 ms，3/3<1500ms，但随后 3/3 音频异常/SIGABRT；不能称全进程优雅退出通过。
上述是 formal4/formal6 的历史状态；其后各协议版本的收尾与 8E auto 证据如下，不混记版本。

### 后续正式包收尾证据（合并 #479 前）

- formal7（`d2dc343a`，APK `8aea00ebce36…6359a`）：9000 true 3/3，GPU 924/1176/1148 ms、优雅退出 1.318/1.399/1.349 s；8E auto 实际单线程2/2、优雅退出0.406/0.432 s。无兜底/音频同栈/Unhandled/fatal。
- formal8（`bd6e1b4b`，APK `4c4713d83a8a…19eba`）：8E auto-1优雅退出0.408 s（更正0.406）；auto-2虽仍选单线程，但press_failed/guard_ended、clean=false，不能计完整通过。
- formal9（`ccc98e5a`，APK `fc340a94e559…082c5`）：9000 true 3/3，GPU732/964/1156 ms、优雅退出0.915/1.172/1.406 s；8E true 1/1，GPU176 ms、优雅退出0.248 s。四局无兜底/音频异常/Unhandled/fatal。9000 false未进关且原生兜底124、无优雅退出，旧runner的clean=True不能代替阶段证据。
- formal10（`f6d14ac7`，APK SHA-256 `971dbb0a83d70ad7f587783c72059740b8397668278a68e4676af53ad3d00ef7`）：9000 true 2/2、8E true1/1，收尾1108/644/148 ms，缓存提前保存、优雅退出1.332/0.833/0.203 s，均无兜底/音频异常/Unhandled/fatal；8E清记录auto1/1实际单线程，36个有效窗忙0.56、呈现/请求60.0/60.0 Hz，记录下局单线程，优雅退出0.404 s。9000 false1局仍兜底124、缓存未落盘、clean=false。

设备仍为9000/Mali-G710与8E/Adreno830、Wonder；上面是分版本的退出证据，不是合并 #479 后新HEAD整包或全交错验收。formal10无可分析视频；SF无>100ms间隔与日志无WSI重建不能证明无闪白，闪白仍未核，能耗未测。formal4首遇日志每5秒清零，应求已报窗口和而非max；无行不能当0，首遇未达0。报告/逐局原始证据位于外部 `/tmp/sgm-s2arm-games/perf-g710/threaded-formal{7,8,9,10}*`，本次未改写原局产物。

### 混杂变量与限制

- **合批语义**：套 `ThreadedRenderer` 后 Vulkan 渲染器拿到中断入口（`SetInterruptAction`），`SyncManager.Create` 的非严格同步不再立刻
  `FlushAllCommands` 提交，等有人等这个同步号时才中断渲染线程提交；单线程没有中断入口，每个同步号都立刻提交。9000 A/B 的收益里有多少来自更少的提交没有拆开。
- **上传多一次拷贝**：`SetBufferData` 先拷进环形池（模拟线程上），9000 Wonder 0.64–0.65 MB/帧；与收益方向相反。
- stamp 在渲染线程执行时取，不做入队时旧代校验（同 P0，真机 6 局 + 冒烟切后台无 WSI 问题）。
- 前台渲染线程单步不泵超过 2 s（GPU 卡死时的读回 fence、驱动调用卡死、收局时 Vulkan 释放）现在判失败；单线程时 S2A.GPU 会一直卡到宿主停机期限。
- 判卡住可能发生在 guest 线程（`WaitSync`、写跟踪回调等对象建好）：该线程抛 `TimeoutException`，会话已经按失败处理。
- 中断的 CAS 自旋（上一个中断动作还没被取走）仍是上游的忙等，只查失败闩。
- 失败闩与异常：判卡住的等待方和渲染线程自己的失败可能同时到，先 CAS 进闩的那个成为会话失败，另一个被丢弃（只留首个诊断）；多个等待方被闩放开时重抛的是同一个异常对象，
  并发 rethrow 会改写它的栈信息（诊断文案不变）。
- 收局：Dispose 里释放的事件与正在 `WaitSync` 的 guest 线程之间没有额外同步，收局后醒来的等待方可能看到 `ObjectDisposedException`（原样，宿主已在停机）；
  Stop 晚到的 maps 诊断已挪后并限时；formal6 GPU 完成后音频异常已修 owner 顺序；对应后续包完整收尾见 formal7/9/10，9000 false 仍收尾失败。
- 出图口径：auto 的「呈现」按模拟线程入队的出图计（不是渲染线程执行完的 `QueuedGamePresents`），出图节流（≤ 1 帧领先）保证两者最多差一帧；
  请求频率取游戏的出图间隔（`FrameIntervalChanged`），120 Hz 屏上游戏按 60 请求时按 60 判，没在 120 Hz 请求的游戏上量过。
- 冷启首帧晚（9000 fc7cb6e6：true 11.61–11.99 s vs false 10.81–10.84 s，首 10–20 s 呈现少 8–15 %）：来源在换页事务。首帧前的两个 5 s 窗口，
  mem-c1-F 换页 297 + 1144 次、prepare 共 499 + 1510 ms，mem-c1-T 291 + 897 次、673 + 1847 ms；第二窗按次平均 F / T：第一条 marker 0.23 / 0.91 ms、
  第二条 0.10 / 0.49 ms、整次 1.64 / 2.57 ms。拆线程的 marker 是一条同步命令：要等渲染线程先执行完已入队的 GAL 命令（单线程时它们早已直接执行）、
  再在渲染线程上 flush + fence，再把模拟线程叫醒，两次线程交接。已改：旧 backing 没有回写源（Source == 0）且队列已空时省掉第二条 marker
  （backing 行带「拆线程省掉第二条 marker N 次」）；第一条 marker 是事务语义（prepare 前排空 GAL 队列）要的，没省。formal4 未观察到旧版首帧延迟：perf F/T 中位 10.52/10.57 s，专用 cold 10.95/10.80 s；不声称统计显著改善。
- 没做「拆线程 + 严格同步（每个同步号立即提交）」的对照组，合批语义与拆线程本身的收益没拆开（见上「合批语义」）。
- 已有行为（两种模式相同，本改动未动）：租约 Stopping 让 GPU 自己退休后，宿主再调 `Stop` 会向已释放的 GPFIFO 事件 `SignalNewEntries`，抛 `ObjectDisposedException`。
- auto 只用 Wonder 两台设备的 P0 读数定了阈值（0.85 / 0.95 / 1.05 / 6 窗 / 36 窗 / 2 次 / 10 局），别的游戏、场景依赖与判偏的比例没量；
  formal6 的 9000 两局采用流程已核，请求 60.0 Hz；8E auto 在 formal7 的2局与 formal10 的1局均实际留单线程，formal8 第二局收尾无效。
- 内存（9000 fc7cb6e6，`dumpsys meminfo`，F 2 局 / T 2–3 局，不足 3 局只作量级）：PSS T 比 F 多约 +82 MB（60 s）、+100–120 MB（300 s），其中 Graphics +38–42 MB（60 s）、
  +44–57 MB（300 s）。已知来源：
  - 托管堆：会话日志「[S2A 内存]」已提交 F 228–230 / 278–279 MB，T 253–270 / 304–318 MB（60 / 300 s），多 +23–42 MB。其中预分配约 8.8 MiB
    （命令环 781 KiB + 环形池 8 MiB，启动行打印）；其余是在途载荷（贴图 SetData 数据、环形池放不下的新分配数组，在途峰 42.5 MB、上限 64 MiB）消费后留在 GC 堆里的部分。
  - 上传多一次拷贝进的是预分配的环形池（0.64 MB/帧），不另增驻留。
  - Graphics（驱动 / Vulkan 映射内存）+40–55 MB 与 PSS 里其余约 +15–25 MB（渲染线程栈、原生堆等）：来源没拆，**待真机读数**（Vulkan 分配器按模式的设备内存合计、`showmap`）。
- 同步命令单次最大等待（9000 正式版报「58.7 / 80.6 ms，P0 1.1–1.5 ms」）：两个数口径不同。P0 的 1.1–1.5 ms 是 observe 窗口（关卡内）每 60 帧行「单次 max」的中位；
  同一口径正式版 1.09–1.30 ms（mem-c1-T / c3-T），observe 窗内最大 P0 5.7–14.6 ms、正式版 11.4–13.3 ms；整局最大 P0 也是 42.1–69.2 ms（4 局 T）、正式版 58.7–80.6 ms。
  整局的大值都出在菜单 / 世界地图 / 加载窗：那些窗口「动作」类同步命令 500–900 次 / 60 帧（GPU 层后台动作在 fc7cb6e6 及以前排到渲染线程、每次排空整条队列），
  observe 窗内动作 0 次、全是缓冲读回。bd149671 起后台动作在模拟线程就地执行（读回仍走同步命令），这类窗口的同步次数与最大值待真机读数。
  夹具 `SyncWakeLatency`：渲染线程空闲时 300 次同步读回 p50 0.013 / p99 0.049 / max 2.5 ms，按完成事件唤醒，不按 50 ms 一片超时醒（负控：改成按片轮询 → p50 52 ms，红）。
- auto 只有拆线程卡住判定才固定单线程：拆线程一局因渲染线程异常（不是卡住）失败时不写记录，若是拆线程自身的问题会每局重现（复审第 2 轮 P2-F，未处理）。
- 夹具 `CounterWaitTick` 直接调 `S2AWaitTick`，没走 `ComposeThreaded` 里 `VulkanRenderer.S2AWaitCheck` → `CounterQueue.FlushTo` 的接线（复审第 2 轮 P2-H，测试缺口，只有负控兜着）。
- mmap_lock 争用（后续，未在本 PR 处理）：写跟踪每次保护 / 解保护都是一次 `mprotect`（拿 mmap_lock 写锁），游戏线程缺页与驱动 `mmap` 也要这把锁。
  9000 会话累计（「写跟踪计数 [收局]」÷ 局时长）：false 213 721 次 / 约 175 s ≈ 1 220 次/s（36.5 Hz，约 33 次/帧）；true 三局 259 416–434 119 次 / 185–210 s ≈ 1 400–2 070 次/s
  （49–52 Hz，约 27–42 次/帧）——按帧同量级，按秒随帧率涨。拆线程下锁的持有方更多（模拟线程、渲染线程里的驱动分配、guest 线程缺页并发），
  收局复现里抓到过 S2A.GPU 在 `mmap` 上 D 态 `rwsem_down_write_slowpath`。运行时等这把锁的时长没量（要内核调度统计或 simpleperf 锁事件）。
  可降的方向：相邻页的重保护合并成一次 `mprotect`、按更大粒度保护以少拆 VMA（VMA 少，每次持锁与读 maps 都短）、内核支持时改用 userfaultfd 写保护（不拿写锁）；
  先加「mprotect 次数 / 总耗时 / 最大耗时」读数再定。运行中没有周期性读 maps 的路径（Android 不起 30 s 地址巡检；读 maps 只在起局、建线程失败、崩溃 / OOM 与收局）。
- 能耗、热时间线、其他游戏 / 设备 / 模式都没测（8E 拆线程两线程 CPU 合计约翻倍是 CPU 时间，不是能耗读数）。

## 验证与来源

显式准备依赖后运行（不自动下载）：

```sh
dotnet run --project graphics/vulkan/runtime/tests/Runtime.Tests.csproj --no-restore
```

测试执行生产 `CreateDeviceWithSurfaceMaintenance` 的 controlled dispatch，覆盖 advertise /
instance dependency / feature 的组合及创建失败；执行生产 runtime 的初始 backing 事务与
真实 MemoryTracking，检查重映射必须重新 dirty、解除映射、不匹配、嵌套以及禁 import。
它们不执行真实 Android VM、GPU flush/present 或游戏。已有 core 与 WSI tests 仍独立运行。
真实 services 编译、Android NativeAOT 链接、fault/VM 闭包和首游戏画面应分别记录证据。

GPU 顺序复用 `graphics/loop/RenderLoop.cs` 和 OHOS PR1 `OhosGfx.cs`
（`73b0cee62ea0ea8da91888c3a51d0cfd76742dc7`）。TextureView 与 blit 构造来自锁版
Ryujinx `Window.cs`，MIT 原文在 `../wsi/LICENSE.Ryujinx.txt`。shared Ryujinx 改动由统一
集成者导出 patchseries，不能只提交 tree 差异而遗漏补丁登记。

第4轮主机回归：control-tests 的 `BackingPublicationHandoff` 强制实际 Begin/Process/End 的 Prepared→Replaced→Finished 交接，旧 finally 晚于新发布；设置 `S2A_NATIVE_WRITERS` 时同时执行真实 native 准入，后台 4.2 s、恢复后没有新渲染工作、350 ms 后才放 writer。writers-gate 的 `publication_revoke.py <binary> <输出目录>` 另保留“持续发布”对照并覆盖恢复前撤销；d2dc343a 在撤销臂提前失效，新逻辑两臂通过。旧 owner 撤销、撤销后跳过生命周期的私有负控均须由具体断言拒绝。以上只替换 host 发布/生命周期边界，不执行 Android、Vulkan 或游戏。

换页续期协议的状态、事件、所有权和期限统一见[换页等待状态机](../../../docs/换页等待状态机.md)。发布由整个事务持有，阶段只增不减；后台无限失效预算与100ms轮询片分离，serial交接后预算独立重算。第5轮旧Prepared迟到首次发布与后台交接350ms G锁争用均保留回归。


第6轮：host 在登记时建立唯一 `CLOCK_MONOTONIC` 总起点，`backing_age` 与 `backing_clock` 分别供托管/native读取；生命周期变化由首个观察者在同一mutex内重置一次，阶段交接/迟到首次读取不重开30s。progress ABI不变，但新增clock导出必须同版构建。`PublicationClockOrigin` 固定2.5s首次读取延迟与31.5s持续渲染队列，旧Runtime红、新Runtime须由共同总预算先超时；可设置 `S2A_NATIVE_WRITERS` 联合真实native gate。`PublicationFailureBoundary` 保留失败owner，真实Fail/Stop+后台4.2s+恢复超时关闭的联合用例明确区分失败请求与事务完成。完整状态、事件与边界见[状态机](../../../docs/换页等待状态机.md)。

发布模型11事件/深6，1,771,561路径/10,629,366步；原生16事件/深6，276,563状态/752,272转换，含首次读迟到、共同起点观察顺序、30/31s边界及epoch=0。`renew_model.py --negative-cap --out <目录>` 在默认深度拒绝去掉31s cap的副本。Stop/Fail运行路径由真实联合用例覆盖，不冒充renew提取模型的事件。

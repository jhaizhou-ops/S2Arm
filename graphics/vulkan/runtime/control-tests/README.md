# Android backing control regression

> 合流说明（2026-10-28）：本页说明与验证记录取 main；本线只有同一段落的旧版描述，已被 main 取代。本目录源码冲突已解；G1 的树侧适配见 [合并分析 §13.23](../../../../android/docs/direct-main-merge-analysis-20261028.md)。原验证记录不代表本次候选重新通过。

此夹具编译实际 `Ryujinx.Graphics.Gpu` 全部源码与实际 `AndroidVulkanRuntime.cs`。它调用真实 `Runtime.Run`、`Switch.ProcessFrame`、FIFO dispatcher、Maxwell `SetReference` 解码器和 `MemoryTracking`；只替换 Vulkan dispatch / surface、native tracker、MemQuery 和 GAL 硬件边界。没有 GPU、Android 页保护或 native writers quiescence，因此通过不代表游戏或真机修复。

`run.py` 要求一个独立且尚不存在的输出目录，离线构建，不在源目录写 bin/obj，不下载包。`--dependencies` 指向已经离线构建的依赖 DLL 目录（需含 `Ryujinx.Graphics.Vulkan.dll` 与受管 `Silk.NET.*` —— 运行时现在会读设备翻译 profile / 离线包）；明确排除旧 GPU DLL，重新编译受测生产 GPU。`--gpu-source` 指向完整 `Ryujinx.Graphics.Gpu` 源目录。`--fifo-source` 和 `--runtime-source` 可选择冻结前/后源以复现红绿。每次输出完整输入 SHA、构建和测试日志。

```sh
python3 run.py --dotnet /path/to/dotnet --dependencies /path/to/host/dependencies \
  --gpu-source /path/to/ryujinx/tree/src/Ryujinx.Graphics.Gpu --output /tmp/backing-control-green
```

断言覆盖：64 条预先排队的真实命令，第 1 条内发布控制、没有新 push，第 2 条前必须处理；entry 内不重入控制；信号合并且回调中发布的新信号保留；空队列事件等待被唤醒；旧 source/destination flush 与 fence 顺序；Prepared→Replaced 期间不得处理下一 entry；Finished 清槽、重映射并置脏；连续替页；已接受请求与退出取消并发；Stop 后拒绝新事务。

3 秒生产超时不变。夹具用事件决定先后，协调超时只防测试挂住。单个不可分割的超长 command entry 仍不会被抢占；不在持有 guest span 的 draw/纹理转换内部做替页。

失败观测回归直接调用生产 `Fail`，fatal 使用捕获回调；分别设置会抛错及会阻塞的 Console sink，要求在调用 fatal 前完全不触碰 sink。另检查同一原异常、消息和 inner、事务字段、首次失败锁存，以及 Prepared/Replaced/Finished 都未被诊断误置位；元数据字典本身抛错也不能替换原故障。旧的提前写日志候选会在 sink 入口断言报红。它不测试 AndroidGameRuntime 既有 Fatal 日志出口，也不验证真实 Vulkan marker wait；不能据此宣称 DeviceLost 已修复。

`--admission-probe` 只在独立输出的 Runtime 副本中，向 `BeginBackingChange` 检查通过后、发布前插入一行受控调度回调；冻结生产文件不含此探针。该用例在真实 gate 内暂停已接受的请求，然后执行真实 Stop，要求 GPU 不得提前退休；释放后原请求必须完成两阶段握手。输出的输入 SHA 包含这行探针，普通模式仍编译完全未插桩的生产源。

## 拆线程（`ThreadedChecks.cs`）

同一个夹具再跑生产 `RunThreaded` / `RenderMain`：真实 `ThreadedRenderer`（补丁 0283）套 `NullRenderer`，真实 `GpuContext` / GPFIFO / `MemoryTracking`，
surface 仍是受控替身（外壳生命周期 `SetProducerForeground` / `StoppingValue` 可由用例切换；surface 的 `Foreground` 只在渲染线程 Poll 时从外壳生命周期抄过去，同 NativeLease）。
套层走生产 `ComposeThreaded`（与 `CreateRenderer` 拆线程分支同一处接线：套层、上限与判据、收局请求登记、渲染线程等待泵），每个会话都检查 HLE 拿到的是套层、等待泵是 `RenderWaitPump`。
缺省用生产上限；背压用例只把条数或载荷上限换小，渲染线程卡住判据仍取生产常量。单线程 `RuntimeChecks` 的检查数随 VM 查询次数在 289–290 之间浮动（用例未改）。依赖目录里的 `Ryujinx.Graphics.GAL.dll` 必须来自含 0271 的树。`S2A_THREADED_CHECK=<用例名>` 只跑一个用例（负控定位用）。

- 开关：未设 / 0 = 单线程基线，1 = 拆线程，auto 没有状态目录抛错、没有记录先单线程，0 / 1 不读写 auto 记录，其他值抛错；
  卡住判据 2000 ms > 不泵的有期限单步 1000 ms，2000 + 250 + 50 ≤ 2500 ms（换页 3 s 预算留 ≥ 500 ms）。
- auto 判据（`ThreadedAuto`，临时状态目录）：前 70 s 菜单（忙 0.83、44.1 Hz）不出结论、之后连续 6 窗饱和（忙 0.98、37.7 Hz）记「拆线程」，加载窗（2 Hz）打断连续；
  菜单 200 s 先记「单线程」、之后出现饱和段改写为「拆线程」；全程菜单 100 s 的短局不写记录。拆线程一局 14 个菜单窗后饱和段 52.1 Hz 保持（菜单不拉偏）；
  饱和段 38 Hz（< 1.05 × 37.7）第 1 次只记单线程、下局重测，连续 2 次才固定，固定后 10 局各用掉一局、不评估，用完重新评估；拆线程 180 s 都够得着请求保持；
  8E 形（忙 0.63、59.6 Hz）35 窗不写、36 窗记单线程；30 帧请求跑满 29.9 Hz 不切；请求不限 6 窗饱和即切；卡住判定固定且同局不被覆盖，单线程一局不固定；
  收局开始后不评估不固定；版本 7 / NaN / no_gain 越界 / reason 400 字 / 固定的拆线程记录按无记录重测，v1 记录重测并换成 v2。
- auto 运行时接线：生产 `S2AReportLoop` 7 个窗（首窗只当起点，线程 CPU 4.9 s / 墙钟 5 s，FIFO 空等 0，185 帧）+ `ObserveFrameInterval(1/60)` 写出忙 0.98 / 37 Hz / 请求 60 的「拆线程」；
  与拆线程无关的 `Fail` 不动记录，`ThreadedStalled` 写「单线程（固定）」。
- 换页：8 条事务前已解码的 GAL 命令卡在渲染线程第 1 条上时，`before` 不得完成（模拟线程停在第一个 marker）；放开后第一个 marker 排在这 8 条之后、在渲染线程上执行；
  旧 alias 回写与 VM 查询在模拟线程、其后还有第二个 marker；prepare 完成时队列为空；`before`→`after` 之间新推入的条目不被解码、渲染线程没有新命令；
  完成后的命令看到重映射与置脏。渲染线程发起换页、渲染线程读 guest 内存都被拒绝。
- 换页遇条数背压（上限 4）：模拟线程卡在上限时换页请求不完成；放开后 marker 排空背压期间排进的全部命令，事务期间没有命令，不死锁。
- 条数背压（上限 16、40 条）：渲染线程卡住 300 ms 期间深度停在 16、不判失败；放开后 40 条全部执行，背压次数 / 时长进读数，峰值 ≤ 16。
- 载荷背压（上限 4 MiB）：9 MiB 上传（超环形池，走新分配）在没有已发布在途时放行；第二块 9 MiB 等第一块被渲染线程消费；贴图 `SetData` 数据同样计入；
  在途峰 = 9 MiB、全部消费后归零、计入字节 = 2×9 MiB + 3 MiB，两块上传在渲染线程上原样到达下层。
- 出图：真实 `ThreadedWindow.Present` 入队 130 帧，`FramePresented` 在渲染线程按序各一次，计数不变的出图不回调；两个 60 帧读数窗口结算。
- 换页时渲染线程卡住：fatal 收到 `TimeoutException`（文案含「拆线程」「同步命令」与正在执行的命令类型），距请求 2000–2600 ms（< 3000 ms 预算）；`Stop` 在 3 s 内返回同一个异常；
  guest 自己的 3 s 换页等待随后到期，不替换首个失败；对象保留，放开后渲染线程退出。
- 出图节流里渲染线程卡住：第二帧 `Present` 在 2000–2600 ms 抛带「出图节流」的 `TimeoutException`，同一个异常进 fatal、`Stop` 返回它。
- 后台：渲染线程卡住、节流在等，`ForegroundValue = false` 的 3 s 内不判失败；回前台后重新计时，≥ 2000 ms 才判失败。
- 租约停止（不经 `Stop`）：模拟线程自己退出主循环，事件顺序严格为 已入队命令 → marker → WSI 停止 → 下层释放，全在渲染线程。
- 慢排空换页（P1-1）：100 条 × 50 ms 的积压让 prepare 晚到约 5 s，guest 换页等待按渲染侧干活续期、不超时，模拟线程不判卡住。
- 解冻（P1-2）：渲染线程卡在长命令里时外壳切后台 3 s、回前台 100 ms 后放开：不判卡住；后台不计时用例同样由外壳切后台（surface 的 Foreground 停在前台）。
- 后台动作（P1-4）：模拟线程上发起的 `BackgroundContextAction` 在 S2A.GPU 上执行，动作里的读回经渲染线程，收局 marker 仍在渲染线程。
- 计数等待（P1-5）：渲染线程卡住时按 1 ms 节奏调 `S2AWaitTick`（Vulkan `FlushTo` 的宿主检查）2000–2700 ms 内判失败、同一异常进 fatal、之后按失败闩重抛。
- 同步唤醒：渲染线程空闲时模拟线程上 300 次缓冲读回，p50 < 2 ms、max < 25 ms（按完成事件唤醒，不按 50 ms 一片醒）。
- 无回写源的换页：拆线程只发第一条 marker（排空 + fence），第二条省掉并计数；映射照常接管与置脏。
- 非 GPU 线程等待（测试缺口 1）：等缓冲建好、等贴图视图建好、等渲染线程锁、中断、同步号登记，各自单独等时都自己判失败（3.5 s 内返回、异常即 fatal）。
- 收局（P1-6 与真机收局缺陷）：2400 ms 的释放不判卡住、3 s 内收完、auto 记录不固定；onPause 先到、宿主收局请求回调不阻塞原生线程，每 250 ms 一行进度
  （点名 S2A.GPU 在等同步命令、guest 线程在等渲染线程锁、渲染线程正在执行的命令与多久没执行完新命令），1500 ms 的释放从 1200 ms 起报红并带「Stop 已到」与阶段，
  快收不报红，收完打用时。
- 失败：渲染线程在模拟线程正等同步命令时抛错，`Stop` 须在放开后 1 s 内（< 2 s 卡住判据，确认是失败闩当场唤醒而不是判据兜底）返回同一个原异常、
  fatal 收到同一个异常、渲染线程退出、GPU 对象保留。

负控（私有副本，不回写生产源；GAL 负控另编 `Ryujinx.Graphics.GAL.dll` 放进依赖副本，运行时负控走 `--runtime-source`），每项都报红：

| 改坏 | 报红 |
|---|---|
| GAL：条数上限不生效 | 「queue depth 40 exceeded the configured cap 16」 |
| GAL：载荷不背压 | 「a payload over the in-flight cap was queued without backpressure」 |
| GAL：贴图载荷不计 | 「admitted payload bytes … do not match the uploads」 |
| GAL：同步命令无界等 | 「stall during a backing change was not diagnosed within the 3 s foreground budget」 |
| GAL：后台也计时 | 「watchdog fired while the session was in the background」 |
| GAL：去掉失败闩 | 「did not promptly release the waiting GPU emulation thread (failure latch)」 |
| 运行时：marker 在模拟线程直调（不排空） | 「prepare finished while earlier GAL commands were still unexecuted」 |
| 运行时：模拟线程排空写跟踪时轮询 WSI | 「WSI poll ran off the render thread」 |
| 运行时：卡住判据 2900 ms（超出换页预算） | 「not diagnosed within the 3 s foreground budget」 |
| 运行时：判卡住不交宿主 `Fail` | 「the stall must reach the host failure entry」 |
| 运行时：未设开关按开处理 | 「an unset switch must keep the single-thread baseline」 |
| 运行时：auto 没记录就拆线程 | 「the first auto launch must run the single-thread baseline」 |
| 运行时：auto 恢复旧的「前 12 个有效窗定结论」 | 「70 s of title/menu windows must not settle a verdict」 |
| 运行时：auto 饱和不看游戏请求 | 「a game meeting its own 30 fps request must not switch to threaded however busy」 |
| 运行时：加载窗不打断连续计数 | 「a loading window must break the saturated streak」 |
| 运行时：1 次没收益就固定 | 「one session without gain must not pin single」 |
| 运行时：记录不校验数值 | 「an invalid record (NaN rate) must fall back」 |
| 运行时：卡住判定不写记录 | 「a render-thread stall in an auto-threaded session must pin single」 |
| 运行时：任何失败都固定 | 「a failure not caused by threading must not pin single」 |
| 运行时：拆线程换页等待仍用固定 3 s | 「a slow but progressing drain must not time out the guest backing wait」 |
| 运行时：卡住判据读渲染线程 Poll 出来的 Foreground | 「watchdog fired while the session was in the background」/「long command across a background/foreground cycle」 |
| GAL：后台动作仍排到渲染线程 | 「a GPU-layer background action must run on the GPU emulation thread, not S2A.GPU.Vk」 |
| GAL：S2AWaitTick 不查卡住 | 「a counter wait inside the backend must be bounded」 |
| GAL：等缓冲建好无界 / 等渲染线程锁无界 | 「the non-GPU wait in MapBufferBlocking / S2AEnterBase is unbounded」 |
| GAL：收局不停用判据 / 运行时收局不调 S2AShutdownBegun | 「a slow backend release during shutdown must not be judged a render-thread stall」 |
| 运行时：收局报红阈值放到 60 s | 「a shutdown still running at 1200 ms must be reported red」 |
| GAL：有界等待按 50 ms 一片轮询（不靠事件唤醒） | 「a sync command on an idle render thread must be woken by its completion event」 |
| 运行时：无回写源的换页仍发第二条 marker | 「a source-less backing change must send only the first marker」 |
| 运行时：收局进度 600 ms 一行 | 「shutdown progress must be logged every 250 ms from the request」 |
| GAL：不登记等渲染线程的线程 | 「progress lines must name what the emulation thread, the render thread and waiting guest threads are doing」 |
| 运行时：0 / 1 也要出图间隔回调 | 「an explicit 0/1 must not ask for the frame-interval hook」 |

这仍是 CPU 合同证据，不运行 Vulkan、Android 租约或游戏。


计数回调另见`../counter-tests/run.py --out <仓库外目录>`；音频收尾另见`android/core-runtime/audio-lifetime-tests/run.py --out <仓库外目录>`。两者先执行旧收尾顺序并核具体异常/晚回调，再执行修复路径。counter链接实际CounterQueue/CounterQueueEvent，只替换驱动查询；音频使用实际AudioManagers/AudioRendererManager/AudioProcessor与Dummy驱动，只替换Horizon内核事件，不证明实际AAudio设备或完整游戏退出。

单权威版本：完整协议和验收边界见 [换页等待状态机](../../../../docs/换页等待状态机.md)。托管只报告推进与读取原生裁决；原生 WSI 租约 mutex 同时保护外壳前后台写入与 CLOCK_MONOTONIC 取时，恢复回调当场重置。

`renew_model.py --out <目录>` 执行完整生产 WSI 与 gate 适配器，20事件深6；`--negative-cap` 和 `--negative pause|resume|observation-reset|stale-clock|owner|epoch|withdrawal` 只改隔离编译副本，必须以 `REGRESSION events=` 报红。`authority_races.c` 覆盖时钟采样内部外壳回调竞争。托管发布模型只枚举阶段/关闭/不透明裁决；不再重复建模时钟。

control-tests 的 run.py 额外编译生产 WSI 的 native 测试绑定；独立重跑 DLL 时将输出 `runtime/` 加入 LD_LIBRARY_PATH（macOS用DYLD_LIBRARY_PATH）。Mac测试不会调用租约条件等待，测试翻译单元只对该未使用的条件时钟设置作显式shim；Linux用实际实现。可设 `S2A_NATIVE_WRITERS=<真实ARM64 gate二进制>` 联合 `BackingNativeLifecycle`、`BackingPublicationHandoff`、`PublicationClockOrigin`、`PublicationFailureBoundary` 与 `DelayedResumeObservation`，共享256字节测试页，仅host边界使用进程共享锁，期限函数仍为原生生产代码。没有Android/Vulkan/游戏执行。

# Android queued-present 诊断测试

> 合流说明（2026-10-28）：本页合并双方已有说明与原验证记录；相关源码冲突尚待解决，原记录不代表本次候选重新通过。进度见 [合并分析 §13](../../docs/direct-main-merge-analysis-20261028.md)。

生产写出器、runtime 接线和 CLI 复用 PR209（wdjwxh，`3cf0a48ef6f04f74db629255a3494700281da194`）。本切片保留 `metrics.enable` 显式启用、下一成功帧 MARK、session/PID 绑定；不引入 Android 专用评分包装、能耗采集或新的帧计数器。CLI 的 `ls -1` 同样采用该作者后续指出的多列目录输出修法。

`frames.tsv` 是成功 QueuePresent 后整个 PresentFrame 返回时的 CPU 端节拍。不是屏幕扫描率、去重画面帧率、guest 生成率或 GPU 执行时间。首帧 `wall_us=0` 表示没有前一间隔，不能计成一张无限快帧。中间等待计入下一成功帧的间隔。

元数据的 `startBootUs` 是 recorder 创建时刻；`lastFrameBootUs` 保留最后成功采样（无帧为 -1）；`endBootUs` 是 GPU 已停止后排空在途节拍回调后 Dispose 关闭点的真实 CLOCK_BOOTTIME 微秒，采于控制线程 join / 文件 flush 前（capturing 时为 -1）。结束与最后帧的差保留终末停顿，包括停止流程尾段；不能用最后帧替代观察窗口结束。`completed` 仅说明采集完成，不代表游戏、渲染、帧率或设备验收。崩溃、GPU 未停稳、写出失败的局不能当完整采集。

逐帧 `RandomAccess.Write` 同步发生在 GPU 线程，另有 GC 计数查询和一个 250 ms MARK 控制线程；有诊断开销。真机需由设备 owner 用同包开/关对照测量，不能声称零开销。

```sh
python3 android/core-runtime/metrics-tests/run.py --dotnet /path/to/dotnet --output /tmp/new-metrics-output
python3 android/core-runtime/metrics-tests/cli_test.py
```

`run.py` 使用现有 .NET 10 SDK，清空 NuGet 源，不下载；所有源码快照、生成输入、bin/obj、日志、SHA 和结果都写入一个必须不存在的输出目录。两类检查：

- 真实 `AndroidRunMetrics` 写出器使用注入时钟，核 MARK、原始列、结束尾段、无帧窗口与不覆盖旧局。
- 从实际 `AndroidWindow` 提取准入和 QueuePresent 结果分支，直接编译其真实 `RetirementLedger`；从 `AndroidVulkanSurface` 提取原计数透传、runtime 提取原回调语句、AndroidGameRuntime 提取原绑定和完整 Cleanup。仅驱动/租约观测、外层 GPU 循环及宿主停止边界受控；没有维护一份接受/计数算法。成功与 Suboptimal、空窗口/退休/后台、两级失败、等待、关闭观察者、真实 GPU 停止失败均覆盖。接缝变化时抽取失败，不能猜选代码。

六个私有源负控分别恢复结束钟在锁外采样的旧并发顺序、删除 runtime 回调、放宽 WSI 成功条件、把结束钟截成最后帧、删除 composition 绑定、跳过 GPU 停止边界，必须触发对应断言；它们不回写生产源。CLI 测试只替换 ADB subprocess 边界，验证原始三文件、`ls -1`、session/PID 一致性和未完成/歧义拒绝。

这些是 host 合同证据，不运行真实 Vulkan、NativeAOT、Android、游戏或 ADB，不产出可用于游戏 FPS 验收的合成读数。

关闭还必须与在途 SurfaceFlinger 节拍回调线性化：Dispose 在同一 `_intervalLock` 内检查/发布关闭、采结束钟、结算 interval，锁外再 join/刷盘。确定性回归让真实 FrameInterval 持锁进入注入 clock，Dispose 线程进入并等锁后才放行，确认旧区间和新区间各100µs、没有负值、晚到回调不再采钟。旧锁外顺序会把新 interval 结算为 -100µs。这是注入时钟的并发合同证据，不是设备时延测量。

收尾接缝还检查实际Cleanup在驱动释放前调用音频owner停止，并在GPU停不稳时保留音频与驱动。删除音频停止接线的私有负控须被明确顺序断言拒绝；独立真实音频管理器/处理器测试位于相邻audio-lifetime-tests。

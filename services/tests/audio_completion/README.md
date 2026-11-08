# Apple AudioQueue 完成计数回归

使用公开 `AppleHardwareDeviceDriver`/session API 和自有低幅 PCM16 双声道、48 kHz 数据。先排4096帧并自然排空，20 ms后追加1024帧；补垫开启、关闭分别启动独立进程。没有 mock、反射、伪回调或手动 `Returned`。

仅构建（不打开音频设备，正常使用官方 .NET，包必须已缓存）：

```sh
python3 services/tests/audio_completion/test.py build --out build/audio-completion/new
python3 services/tests/audio_completion/test.py build --source-root /absolute/old/source/tree --out build/audio-completion/old
```

两个构建使用同一正式夹具及不同真实依赖源码；各自独立 artifacts/空 NuGet feed、最多两个 MSBuild任务、禁共享编译服务器。`identity.json`保存实际源码根、HEAD、前后源码哈希、夹具哈希、命令与实际依赖 DLL 哈希；`source.diff`保存源码相对 HEAD 的差异。源树在构建中变化会失败。

协调音频设备空闲后才执行，不与游戏或其他音频测试并行：

```sh
python3 services/tests/audio_completion/test.py run --build build/audio-completion/old --out build/audio-completion/old-run
python3 services/tests/audio_completion/test.py run --build build/audio-completion/new --out build/audio-completion/new-run
```

运行保留生产 `queue.0.tsv`、自有 PCM WAV、每条真实公开读取的 `events.jsonl`、完整进程日志和分析结果。输出目录必须全新。`S2A_AUDIO_TEST_*`生产测试钩子会被拒绝。

分析把生产 q/c 按时间排序，不能按文件行序（生产写线程分开排出两种事件）。探针同时记录原始 Stopwatch ticks、安全微秒和与生产相同的 unchecked 溢出微秒；分析只在同一个有界时段对齐，跨溢出边界不判通过。公开 API 读取并非原子快照，因此比较整个读取区间，留2 µs转换余量。

通过必须有正面观测：补垫 c 后、真实目标 c 前完整读取仍为4096/未完成，真实目标 c 后完整读取为5120/已完成。关闭补垫的控制要求目标 q 与 c 之间实际读取到pending，以及c后completed。任何提前完成返回1；没有足够窗口、缺失原生事件等返回2（不完整），不能以“未发现提前完成”判绿。分析可单独重跑：`python3 services/tests/audio_completion/analyze.py RUN/on`。

这里只验证 AudioQueue 交还缓冲时的完成记账，不是声卡实际播完时刻、听感、#423 audren BGM根因、能耗、iOS或游戏验收。`ReclaimAll`恢复/系统打断路径未被本夹具覆盖，不用伪系统通知代替。

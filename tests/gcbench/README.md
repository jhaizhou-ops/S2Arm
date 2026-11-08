# K02：NativeAOT GC 合成扫描

对应 [#195](https://github.com/jhaizhou-ops/S2Arm/issues/195)。只在 Apple Silicon Mac 上运行，要求 .NET 10 SDK 和 Xcode 命令行工具；不需要游戏、手机或服务层构建。不会改产品 GC 设置，也不接入门禁／游戏启动路径。

## 复现

首次**显式准备依赖**（此步会访问 NuGet；不能放进离线门禁）：

```sh
bash tests/gcbench/build.sh --restore
```

随后可以离线运行。每组设置用新进程，按轮交错、串行执行，不复用 GC 状态；输出目录必须不存在。完整默认扫描约需 20–30 分钟，另加首次 AOT 编译时间：

```sh
bash tests/gcbench/run.sh --out build/gcbench-288 --hard-limit-mib 288
```

默认每组 3 次、每次 6000 帧、种子 1、帧间 sleep 请求 1000 µs。它是加速的分配轨迹，不是真实 60 帧负载。正常帧率确认及不设堆上限的对照：

```sh
bash tests/gcbench/run.sh --out build/gcbench-paced \
  --cases seg32,seg32_conserve7,seg32_conserve9 \
  --frames 3000 --frame-us 16667 --repeats 3 --hard-limit-mib 288
bash tests/gcbench/run.sh --out build/gcbench-unbounded --hard-limit-mib 0
```

`S2A_GCBENCH_LATENCY=sustained` 仅在实验程序内通过公开 API 设置并回读 `SustainedLowLatency`。扫描器为子进程显式设置该值并清除继承值，产品代码不读取它。

只复核证据统计与观测能力（不联网、不用游戏）：

```sh
bash tests/gcbench/test.sh
```

可用 `S2A_DOTNET` 指定 SDK 的 `dotnet` 可执行文件，`S2A_DEVELOPER_DIR` 指定 Xcode，`S2A_GCBENCH_BUILD` 指定编译目录。默认产物都在仓库 `build/195-gcbench/aot/`，不污染源码目录。`scan.py --help` 列出扫描选项；具体设置及十六进制值见 `CASES`。`complete` 是数据完整性，不是性能达标。

## 负载与观测

- 150 MiB 左右长期存活的 96 B 小对象（预算含 24 B 对象头，但引用数组另占内存），64 MiB 长寿大数组（缺省阈值下进 LOH），14 MiB POH，24 MiB 中寿小对象环。另有 128 个固定 SOH 对象的句柄，种子和置换次序固定。
- 每帧 16 KiB 小对象分配，另替换一个中寿对象；每 30 帧一笔 0.5–7 MiB 的一次性 LOH 分配，每 120 帧替换一个 1 MiB 长寿 LOH 对象。触及所有分配的页面，短寿对象逃逸到 sink，防止 AOT 消除。
- 启动期显式做一次 gen2 晋升，**它在测量窗口外**。自然扫描的测量窗口不调用 `GC.Collect`。`--forced-control` 是独立正控制，测量期每 1000 帧显式压缩一次，不能用它声称自然复现。
- 循环读取 `CollectionCount`；计数前进后，分别读取 `Ephemeral`、`FullBlocking`、`Background`，跨类别按全局 `Index` 去重。后台完成可滞后，保留轮询，末尾另留 1 秒排空窗口。三代精确计数和采到的 Index 数必须对上；漏任何 GC、记录溢出、OOM、超时、异常退出或帧数不足，都标为 `complete:false`，不能凭较小的已观测最大值报通过。
- 本机观测到 Background 查询与 FullBlocking 共享 Index、Background 带启动期或空元数据的情况。原始记录全部保留；只有同 Index 下恰有一份完整阻塞 gen2、其余为后台／空占位时，统计才选完整阻塞记录，并重新核对三代计数。其他冲突拒绝，不把缓存快照算成额外 GC。
- `max_pause_ms` 是各次 `PauseDurations` 中的**最长单段暂停**；两次暂停之和另记 `max_gc_pause_sum_ms`，累计时间用 `GC.GetTotalPauseDuration`。不把两个不连续停顿的和当一次停顿。后台快照可能尚未带齐第二段；累计停顿超过快照总和的残差单列，`max_pause_upper_ms` 保守取观测最大值加正残差，判 <10 ms 时用此上界。快照总和显著超过累计值也不能通过。
- `near_unchanged_compactions` = gen2、非并发、压缩且 `堆 after / before >= 0.95` 的次数，包含堆增大的情况。每代 before/after、碎片、提交、晋升、固定数、系统负载和高负载阈值都写入原始 JSON。
- `GetGCMemoryInfo` 在此版本会分配，故不按固定高频率无条件调用。其分配量单独记录；JSON、字符串输出都在测量后生成，记录缓冲预先分配。后台待完成查询仍有额外分配，报告必须同时给出观测开销。
- 用 Darwin `proc_pidinfo(PROC_PIDTASKINFO)` 每帧取进程 VM / RSS；每 64 帧及 LOH 突发后枚举 `PROC_PIDREGIONINFO`，统计 private / empty 且 tag=0 的地址总量（包含未提交映射）。后者包含 GC 预留，也包含其他未标记预留，**不是 GC 专属地址量**。两者均为采样峰值，可能漏掉一次 GC 内建立又释放的瞬时映射；不代表 iPhone 低区的空洞或可用连续地址。

## 配置与判读边界

GC 环境变量数值按十六进制传入。扫描器清除继承的 `DOTNET_GC*` / `COMPlus_GC*`，为每个子进程单独设置，保存请求值和 `GC.GetConfigurationVariables()` 的运行时上报值；不把请求值直接当生效值。该 API 也可能列出编译时禁用功能的参数（例如本机区域配置非零，仍未启用区域 GC），须结合源码和 `IsServerGC` 等实际能力判读。输出包含运行时版本、OS、NativeAOT 证明、负载参数、源码／可执行文件 SHA256，便于复核。

.NET 10.0.9 的 macOS 构建在 `gcpriv.h` 的 `USE_REGIONS` 条件中排除了 `__APPLE__`，所以区域行是能力反证，不能宣称已切为区域模式。`GCHeapHardLimit` 是提交预算近似，**不模拟真实低区地址碎片和系统 80% 内存负载**。此外 `gc.cpp` 在段模式 + hard limit 下将 SOH 段大小取 `max(按 limit/heap 数推导的大小, GCSegmentSize)`；受限组的 32/64/128 MiB 请求可能被同一更大下限覆盖。必须同时跑无 hard limit 对照，才能讨论原产品小段设置的作用。

Mac 合成扫描得到的是候选设置和失败边界。若某组所有重复均完整、自然扫描且最长暂停 <10 ms，再比较同一负载下的地址采样峰值；不能只看进程总 VM 的百分比（系统 guard／共享预留可能占数百 GiB），也不能把成功的宽松预算组替代失败的紧预算组。最终是否采用仍由维护方做真机同包 A/B。

原始数据是合成程序输出，可在本机保留完整 JSON；提交研究报告时只取必要汇总，不把其他项目／游戏的日志混入。

## 来源

- [.NET GC 配置](https://learn.microsoft.com/en-us/dotnet/core/runtime-config/garbage-collector)：初始化时读取、环境数值格式和设置含义。
- [.NET 10.0.9 gcpriv.h](https://github.com/dotnet/runtime/blob/v10.0.9/src/coreclr/gc/gcpriv.h#L143-L149)：macOS 不启用区域。
- [.NET 10.0.9 gc.cpp](https://github.com/dotnet/runtime/blob/v10.0.9/src/coreclr/gc/gc.cpp#L53791-L53817)：hard limit 与段大小关系。
- [.NET 10.0.9 GC.NativeAot.cs](https://github.com/dotnet/runtime/blob/v10.0.9/src/coreclr/nativeaot/System.Private.CoreLib/src/System/GC.NativeAot.cs#L786-L791)：MemoryInfo 查询本身分配。

## Server GC 发布对照

NativeAOT 的该项需发布时选择；workstation 二进制里只设 `DOTNET_gcServer=1` 没有改变实际 GC。独立构建目录避免覆盖工作站版本：

```sh
S2A_GCBENCH_SERVER=1 S2A_GCBENCH_BUILD="$PWD/build/gcbench-server" \
  bash tests/gcbench/build.sh --restore
S2A_GCBENCH_SERVER=1 S2A_GCBENCH_BUILD="$PWD/build/gcbench-server" \
  bash tests/gcbench/run.sh --out build/gcbench-server-scan \
  --cases compiled_server4_seg16,compiled_server4_seg16_loh8 \
  --frames 30000 --repeats 1 --hard-limit-mib 0
```

`compiled_server*` 组必须显式选择，默认扫描不跑；实际 `IsServerGC` 不为 true 时不能通过。它只证明 Mac 发布的行为，不证明 iOS 支持或游戏收益。

本轮完整结果和未达标边界见 [研究报告](../../docs/研究/CSharp_GC阻塞压缩_K02_20261024.md)。

## 草稿审核补充实验

`review_scan.py` 使用同一个工作站 NativeAOT 二进制，清除继承的 GC 设置，串行运行独立进程；原始数据、请求参数和源码／程序哈希逐组保留。所有自然组不设 hard limit；默认 3 次交错重复，输出目录不得存在。

```sh
bash tests/gcbench/build.sh
python3 tests/gcbench/review_scan.py --exe build/195-gcbench/aot/publish/GcBench \
  --out build/gcbench-review-large --phase large
python3 tests/gcbench/review_scan.py --exe build/195-gcbench/aot/publish/GcBench \
  --out build/gcbench-review-refs --phase refs --repeats 2
python3 tests/gcbench/review_scan.py --exe build/195-gcbench/aot/publish/GcBench \
  --out build/gcbench-review-budgets --phase budgets --repeats 2
```

- `large`：30000 帧同轨迹，原 32 MiB 段 + 缺省 LOH 阈值。`managed` 是原负载；`transient-native` 仅搬走一次性大块，64 MiB 长寿大数组仍托管；`all-native` 再搬走长期／替换大数组。14 MiB POH 和 128 个 SOH pin 均保留。原生块也触页、相同大小／随机次序，显式释放，不调用 `GC.AddMemoryPressure`，模拟不向 GC 登记压力的原生缓冲。不是零物理内存分配。另有不指定段 + LOH8 对照。
- `refs`：**强制 gen1 控制，不是自然性能验收**。约 128 B 的长期节点把指针分散到旧对象图；年轻池根引用保持所有目标可达，独立改变旧节点数、年轻池大小、跨代引用数。每个 trial 先清空边并完整回收，再分配目标、显式 gen0 晋升、显式 gen1 测量。实际检查每个目标在 gen1、准备期无额外 GC、收集没有升级 gen2，否则整组不可用。该控制为留足准备空间使用 256 MiB 段和 64 MiB gen0 请求；不能把它称为原 32 MiB 的运行结果。原 32 MiB 试验中自动升级的失败 pilot 原位保留。
- `budgets`：原 32 MiB 段、同一旧对象图，120 轮 × 16 MiB 年轻池，逐分配采样；改变跨代边数和 gen0／gen1 设置，测量期零强制回收。这里是高分配的读盘形态，不是低分配稳态帧；每轮开始撤销旧边、再分配新池，边数独立于池存活字节。`GCgen1size` 是有意加入的未支持负对照；另试源码存在的 `GCGen1MaxBudget`，它是上限，不是提高 gen1 最小预算的旋钮。运行时公开配置未列出某个私有字段时，不把仅传环境变量当作生效证据。
- `paced` 与 `large` 相同，通过 `--frames 1200 --frame-us 16667` 显式选择近似正常帧率短窗口；不能替代长轨迹。

地址新增绝对采样峰值：进程 VM、private/empty tag0 映射（可访问／PROT_NONE 分列）、GC `TotalCommittedBytes`、RSS、原生存活字节。PROT_NONE 是不可访问地址预留，不是物理提交；可访问映射也不能直接叫物理提交。GC 提交峰值采自收集快照和窗口边界，可能漏掉收集前峰值。tag0 包含 GC 及其他未标记映射，**无法作为 GC 专属保留量或 iPhone 低区占用**；报告给绝对值和同包对照，避免把增量 246 MiB 当成总保留量。

配置语义核对：[.NET 10.0.9 gcconfig.h](https://github.com/dotnet/runtime/blob/v10.0.9/src/coreclr/gc/gcconfig.h) 没有 `GCgen1size`；[set_static_data](https://github.com/dotnet/runtime/blob/v10.0.9/src/coreclr/gc/gc.cpp) 中 `GCGen1MaxBudget` 取上限与默认预算的较小值，后台工作站默认约 6 MiB，故设 8/32 MiB 不能据此声称扩大 gen1。

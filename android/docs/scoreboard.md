# Android 生产采集与局目录导出（L06 / #208）

本片把 #209（wdjwxh）的产物契约、导出与电池采样净增量接到 main。只交生产者产物到局目录的链路，不增加 Android 私有评分器，不修改 `tools/score_cells.py` / `tools/frame_gate.py` 或共享预算。完整六格接入及共享读取器的缺测 P2 仍是 #208 后续，不据本片关闭整卡。

## 六格输入及验证边界

| 格 | 共享工具消费的输入 | Android 现有来源及缺口 |
|---|---|---|
| 能玩 | `host.log` 中 MARK、崩溃、红行、声音峰值 | 实际操作后请求 MARK；缺失的声音测量不补造 |
| 画面 | 满屏判据与 `truth.tsv` 检查点 | 截图或隐藏系统栏不等于画幅真值；本片不采集或判画面 |
| 帧率 | 游戏请求节拍、MARK 后有效窗口、`frames.tsv` | 只记录成功 QueuePresent 返回后的 CPU 提交节拍，不是 GPU 耗时或屏幕扫描 FPS |
| 能耗 | 共享工具要求的正式整机功耗证据 | 本片只保存电池诊断，不能用于 iOS 整机功耗判格 |
| 首局 | MARK、我方归因大帧、管线/着色器首次构建指标 | 未采到的 `gpu_us` / `pso_n` / `shader_miss` 等不生成、不补零 |
| 分配 | 分配/GC/读回及有效窗口 | 已采 `alloc_b` / `gc0` / `gc1` / `gc2` / `gc_pause_us`；未采指标保持缺测。后续共享接入必须保留已测超标为红、无已知失败时缺测为未测的口径 |

阈值以当前共享实现为准，不在这里保存第二套数值。本片不对六格出分，也不把旧 #209 的评分结果改记到新树。

## 生产合同

显式启用的会话在真实 StateDirectory 下写 `metrics-<session>-<pid>-<random>` 目录。`frames.tsv` 的必需列：

| 列 | 单位与定义 |
|---|---|
| `frame` | 从 0 连续编号；只在现有成功呈现计数增加后写一行 |
| `wall_us` | 相邻成功呈现回调的 CLOCK_BOOTTIME 微秒差，首行 0 |
| `boot_us` | 同一回调内的 CLOCK_BOOTTIME 微秒 |
| `alloc_b` | 相邻回调间进程托管分配字节增量 |
| `gc0` / `gc1` / `gc2` | 进程累计 GC 次数 |
| `gc_pause_us` | 相邻回调间进程累计 GC 暂停时间增量，微秒 |

不填没有测量的 `disp_us` / `gpu_us` / `rb_us` / `draw_n` 等列。逐帧同步写盘有开销，本片没有采集开关 A/B 或游戏性能结论。

`runtime-metrics.json` 保存采集 ID、状态、来源、时钟、帧数、MARK、起止钟及独立的 `lastFrameBootUs`。结束没有新帧的尾段仍计入真实 `endBootUs`，不得把末帧当收局。只接受 `completed`，拒绝截断行、非 ASCII 整数、重复列、错帧号/间隔/时钟、错帧数、错 MARK 或错采集 ID，不补零或静默丢行。

ADB 导出沿用 main 的 session/PID 唯一日志绑定、`runtime-library.json` 核对、旧包兼容及开发库拒绝。`--allow-dev-run` 仅允许导出原始开发证据，仍保存 `NOT-A-READING.txt`。本地再次导出生产目录也保留运行库身份和该标记。没有完整 A0/调度证据时，不能称为正式验收；自带清单不授予认证。

## 使用

以下命令由有设备权限的测试者显式执行。工具不安装、启动或停止游戏；`<state>` 是 BootSpec 中真实 StateDirectory 对应的 App 私有 `files/...` 相对路径。

```sh
python3 android/metrics.py enable --serial <设备> --package <包名> --state-dir <state>
# 到达实际可操作场景后请求 MARK。
python3 android/metrics.py mark --serial <设备> --package <包名> --state-dir <state>
# 正常收局后；输出目录必须不存在。
python3 android/metrics.py export --serial <设备> --package <包名> --state-dir <state> --output <私有局目录>
python3 android/metrics.py disable --serial <设备> --package <包名> --state-dir <state>
```

全部命令经不分配 PTY 的 `shell -T`，保留 stdout 原始字节并检查远端退出码。`exec-out` 不带远端命令的失败退出码，不能用来识别可选文件缺失；不支持 shell v2 的旧设备会明确报错，不能当旧包缺记录静默放行。导出先在临时目录校验完整产物，再同文件系统改名发布；复制、校验或写入失败不留下半成品目标目录，已有目标不覆盖。`ls -1` 只允许唯一同 session/PID 日志，不按时间猜最近文件。

需要电池采样时，在另一个终端提前运行以下命令，使窗口覆盖 MARK 到实际收局：

```sh
python3 tools/android_power.py --serial <设备> --seconds 120 --output <私有目录>/battery.tsv
```

导出可额外给 `--power-samples <私有目录>/battery.tsv`，同时带入 `.source.json`，并核对同一 ADB transport。同一 serial 不能证明同次设备启动或同一局：重启前后的 uptime 可以重叠，旧样本仍可能通过这个来源检查。因此只携带未经会话绑定的原始诊断，使用者须保留真实采样上下文，不能据此认证或自动判分。`--run-manifest <既有清单>` 仅原样携带清单，不生成或补写身份字段。

已在本地的生产目录可用 `collect_run.py --metrics-directory <目录> --host-log <同局host.log> --output <新目录>` 再次收集；保留其中的运行库身份与开发局标记。局文件保持原样、未做隐私脱敏，只能保存在私有位置，不直接上传到 Issue/PR。

## 电池诊断

优先只读 power_supply sysfs；电流或电压不可读时后备到 `cmd battery get -f current_now`（µA）和 `dumpsys battery` 当前 `voltage`（mV 转 µV）。不使用历史广播电压或 `current_average` 代填值。每行保存来源、状态、充电来源、温度与采样末端设备 uptime。电流和电压是顺序读取，非同时快照；拒绝权限和缺值保留空字段。BatteryService 的 `UPDATES STOPPED` 表示状态被模拟/冻结，数值仅保留作原始诊断，来源标 `battery-service-frozen`、状态 Unknown，不用于积分；实际可读 sysfs 优先，不受未使用的后备服务状态影响。

`android_power.battery_window` 使用显式核实的放电符号，对 **MARK→真实 endBootUs** 完整窗口做梯形积分。未知符号、缺值、充电/未知状态、时间倒退或重复、超过 3 秒空洞、窗口不完整均返回未知，不自动绝对值或补零。输出始终 `scope=battery`、`comparableToIosWholeSystem=false`，不写共享能耗格。这里的合成数学测试不证明任何设备的精度、热状态、游戏能耗或正式整机达标。

## 验证和来源

```sh
bash tests/android_metrics_test.sh
bash tests/android_power_test.sh
```

第一条运行生产 CLI 边界、契约/失败原子性、当前真实 C# `AndroidRunMetrics` 及既有采样接缝正反例，再把该生产者的 1904 行合成时钟输出经过契约、导出与电池窗口函数。输入全部原创合成，不使用游戏资源。

来源：[#209 原实现与历史证据](https://github.com/jhaizhou-ops/S2Arm/pull/209)、[复审与缺口](https://github.com/jhaizhou-ops/S2Arm/pull/209#issuecomment-6414626234)、[#208 当前分片批准](https://github.com/jhaizhou-ops/S2Arm/issues/208#issuecomment-6629204997)。旧设备报告归其原 commit/APK；本片仅声称实际运行的宿主机制测试，不声称新包、真机或完整六格验收。

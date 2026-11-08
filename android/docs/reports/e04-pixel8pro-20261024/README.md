# E04-Pixel8Pro 两轮诊断报告

2026-10-24，Asia/Shanghai。提交者：YTwsy。
关联 [#58 的 E04-Pixel8Pro 认领](https://github.com/jhaizhou-ops/S2Arm/issues/58#issuecomment-6384943461)。

**这一台 Pixel 8 Pro 的 E04 当前阶段诊断交付完成：同一冻结包的两轮六组检查各 6/6 通过，脚本清理各 3/3 通过，待维护者复核验收。**
本样本补充 Mali-G715；#58 当前要求的六类证据如下。

| E04 要求 | 本次交付 |
|---|---|
| 页大小 | 真机 getconf 与应用探针均为 4096 B |
| 地址窗口 | 共享内存别名、39-bit 内 64 GiB 虚拟地址预留，两轮通过 |
| TSD | Bionic key table offset 0x0、线程隔离，6 类改写 × 2 guest 线程，两轮通过 |
| 输入 | 两轮分别完成 12 个虚拟按键、双摇杆右上拖动及释放归零 |
| WSI | 两轮 Vulkan 诊断呈现、正反横屏、方向标记截图核对通过 |
| 生命周期 | 两轮 HOME 输入清零与恢复、Activity 关闭重开、旧渲染线程退出通过 |

本报告完成 #58 所列“当前可跑探针/诊断”的单设备贡献。正式游戏验收按总表后续 A-W13 链路推进，本 PR 不关闭整个 #58。

## 冻结包与设备

| 项目 | 实测值 / 来源 |
|---|---|
| 实现源码与报告分支起点 | `android/integration@d663483350c40c1f6894afd5735f1fd16cd4fc8f` |
| 模式 | `nativeMode=diagnostic`、`CS_SERVICES=0`、实验触控关闭；无商业游戏资源 |
| APK | `org.s2arm.android` debug，3,284,326 B，仅含 ARM64 的 libs2arm_android.so |
| APK SHA-256 | `3be424e8e408fee91a23a6e583adabe998a3d31a4d5fe53911f19bb049b6d447`；手机单 base.apk 哈希一致，无 split |
| 构建主机与工具 | Apple Silicon / macOS 14.8.5；Temurin JDK 17.0.21+9、Gradle 9.8.1、AGP 9.4.1、SDK/build-tools 36、NDK 29.0.14206865、CMake 3.31.6 |
| 合成输入工具 | Python 3.12.10、capstone 5.0.7（模块与发行包一致）、lz4 4.4.5 |
| UI 自动化 | Python 3.12.10、uiautomator2 3.7.1 |
| 设备 | Google Pixel 8 Pro，husky，`ro.soc.model=Tensor G3`，arm64-v8a |
| 系统 | Android 16 / API 36；安全补丁字段 2025-11-05，按原值记录 |
| 页与内存 | 4096 B；MemTotal 11,827,196 KiB，这是系统总量 |
| 存储 | 前置读取 /data 可用 25,663,764 KiB，约 24.5 GiB |
| 显示 | 物理竖屏 1344×2992；横屏整屏与 Surface 均 2992×1344；内容原点 (0,0)；物理 density 480，原有 override 544 保留 |
| 应用实际 GPU | Mali-G715，应用输出 Vulkan 1.4 |
| 系统侧驱动 | cmd gpu vkjson：Mali-G715，Vulkan 1.4.303；driverVersion 原值 226492416；driverInfo 为 v1.r54p0-00eac0.2eb223a75a2b3d1d3ecd5a6eb1b0b63d |

[device.json](device.json) 分别记录应用输出与 shell 系统查询来源，未把系统驱动字段写成应用逐字段回报。
包身份与安装校验见 [package-identity.json](package-identity.json)、[installed-package.json](installed-package.json)。64 GiB 探针仅预留虚拟地址，不分配 64 GiB 手机内存或存储。

## 两轮结果与射程

两轮独立重启诊断进程，包、合成输入、设置和脚本一致；没有重新构建或更换 APK。

| 检查 | round-1 | round-2 |
|---|---|---|
| 应用 PID | 12475 | 12892 |
| 六组 / 清理 | 6/6；3/3 | 6/6；3/3 |
| 原生探针、6 类改写 × 2 guest 线程 | 通过 | 通过 |
| 12 键 bit 0～11，逐键按下后释放归零 | 通过 | 通过 |
| 左右摇杆分别右上拖动，正 X / 正 Y 后释放归零 | 通过 | 通过 |
| rotation 1→3→1，同 PID，transform 0x2→0x8→0x2 | 通过 | 通过 |
| 按住 A 后 HOME，归零、Surface 脱离、同 PID 恢复呈现 | generation 1 在 4 ms 脱离，generation 2 恢复 | generation 1 在 1 ms 脱离，generation 2 恢复 |
| Activity finish / 重开，旧渲染线程的 /proc 项消失 | TID 12506 退出，新 TID 12752 呈现；PID 保持 | TID 12919 退出，新 TID 13190 呈现；PID 保持 |
| finish 对应 generation 2 脱离 | 2 ms | 3 ms |
| 当前进程精选日志首末跨度 | 22.306 s | 21.245 s |
| 原渲染线程最大已报告 present 计数 | 2117 | 2040 |
| 重开后线程最大已报告 present 计数 | 244 | 244 |

present 计数按渲染线程分别登记，是诊断呈现计数；不相加当作真实上屏总数，也不用于游戏帧率结论。外层执行时长为 26.89 s / 26.18 s，包含准备与清理，见 [round-execution.json](round-execution.json)。

两轮信号探针均记录 SA_ONSTACK 与 sigchain 写缺页 14/14 字保留；无备用栈对照 12/14，丢 sp-8 / sp-16；写 ESR 0x92000047、读 ESR 0x92000007。

结构化结果见 [第一轮](round-1-results.json)、[第二轮](round-2-results.json)；[case-evidence.json](case-evidence.json) 关联 PID、TID、各组断言、精选日志与私有截图标签。
两轮的正反横屏、HOME 恢复、诊断面板重开共 8 份截图均已核对，红块在左上、绿色长条在右上。状态栏与面板重叠按原图保留，只记录本轮方向和生命周期结果。

## 执行方法与证据过滤

- 合成 NSO 来自冻结源码的 selftest_nso.py，经同一源码的 patch_nso.py、S2A_TARGET=android 改写。三文件通过 run-as 导入，使用 10 秒上限、0.2 秒间隔的完整 SHA 复核，全部匹配后才启动；patched.bin 与 fixups.tsv 在第 2 次复核匹配，gates.tsv 首次匹配，各次观察均保留，见 [fixture-import.json](fixture-import.json)。
- 复用原 android/tools/device_round.py。本次私有副本只把预期尺寸从 2400×1080 改为实测 2992×1344；按键、摇杆坐标仍取实时 touchpad layout，旋转 transform、输入释放、前台可见、同 PID 与旧线程退出等断言均未修改。
- [pixel8pro-runner.diff](pixel8pro-runner.diff) 是零上下文补丁；[runner-identity.json](runner-identity.json) 记录原/适配脚本 SHA。复现时取冻结提交的原脚本，在私有目录执行 `patch device_round.py < pixel8pro-runner.diff` 并核对前后 SHA；显式传设备 serial、冻结 APK、runtime-commit 和新的私有输出目录。
- 设备脚本本来就只接受当前 PID 的完整应用日志行。整理第一轮原始日志时，发现 logcat -T 1 带入了探索进程 PID 12166 的 1 行旧 present 计数；该行位于新进程启动之前，公开精选日志按本轮 PID 12475 排除。第二轮无异 PID 前缀。原始文件保持不变，避免将旧进程帧数、探针或输入记到新轮次。
- 精选文件分别是 [第一轮应用日志](round-1-selected-logcat.txt) 和 [第二轮应用日志](round-2-selected-logcat.txt)，只保留当前进程的探针、GPU、输入、Surface 与呈现行；完整 HostApi 用户区域字段、导入路径和其它原始行不公开。

## 准备阶段的中断与恢复

[preparation-attempts.json](preparation-attempts.json) 单独记录准备过程；这些不是执行失败后被删掉的设备轮次。

1. Mac USB 列表识别到设备，ADB 初始无枚举；重连后先 offline、再 unauthorized。设备持有人在手机端允许 USB 调试后，才采集真机信息。
2. 安装 APK 并完成包/输入哈希校验后，首次 UI 探索前置检查发现熄屏，未启动诊断 Activity。唤亮后只读确认仍有凭据锁，由持有人解锁；临时亮屏设置供后续使用，结束后恢复为 0。
3. 完成探索后，两轮六组均首次通过；没有失败轮次剔除或放宽断言。

本次记录的显示适配与 PID 过滤经验同时追加到 [性能与开发测试经验](../../../../docs/性能与开发测试经验.md)，不修改公共运行时或测试入口。

## 构建、自检与清理

- 冻结源码离线 assembleDebug / lintDebug 通过，Lint 0 error / 4 warning，均为 SetTextI18n。
- verify-apk.py 的 ARM64、16 KB ELF 段与 APK ZIP 对齐通过；apksigner verify 通过。设备实际页长仍是 4 KiB。
- 报告提交后的 tools/contrib_check.sh 按 android/integration 基线路由运行；摘要原样放在 PR 正文。Android 主机门禁在这次贡献自检中执行，不另外重复整套门禁。Linux-only 原生 CTest 与正式游戏二级验收未执行。
- 最终回读 6 项原设置全部一致：亮屏 0、user_rotation 0、自动旋转 0、超时 120000、1344×2992、density 480 / 原 override 544。
- 诊断 App、UI 自动化服务、本任务独立 ADB 已停止；其它 ADB 服务未动。测试窗口 crash-buffer 无新增行，见 [cleanup-verification.json](cleanup-verification.json)。

保留安装的诊断 APK 与合成输入供复验；App 的 files 目录为 87 KiB，不含 APK、Android 管理数据或自动化辅助 JAR。

## 公开材料与后续阶段

[private-evidence-sha256.json](private-evidence-sha256.json) 只列选定私有原件的相对标签、大小与 SHA。原始截图、UI 层级、完整日志、系统 Vulkan 查询和 APK 均不上传；序列号文件及其哈希不登记，个人路径、游戏文件、密钥和存档不进入 PR。索引对应私有原件，公开整理副本可能不同。

当前页大小、地址窗口、TSD、诊断输入、WSI 和生命周期六类交付已完成。后续正式游戏 NativeAOT/S2A_Init、Vulkan/GAL、声画与存档、真实 guest HID 按 A-W13 链路验收；实体手柄、全部摇杆方向、多指并行、16 KiB 页真机、功耗/帧率及长期压力不在本轮内。本报告没有把诊断 clear/present 计数当作这些后续项目通过。

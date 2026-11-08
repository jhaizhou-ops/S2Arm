# E04-Pixel10ProXL 首轮诊断

2026-10-24，Asia/Shanghai。提交者：YTwsy。
关联 [#58 认领记录](https://github.com/jhaizhou-ops/S2Arm/issues/58#issuecomment-6379538468)。

**无商业游戏资源的原生诊断六组检查 6/6 通过，三项脚本清理 3/3 通过；等待维护者复核。**
本报告只交付这一台设备的有限原生诊断样本，等待维护者复核；不标记整个 E04 或 Android 游戏可玩完成。

## 测试身份与环境

| 项目 | 实测值 / 来源 |
|---|---|
| 源码 | `android/integration@cc16b5fef4f699d043d95e65d8270ef00df89e2a`，从 Git archive 建立独立副本 |
| 包 | `org.s2arm.android`，debug，`CS_SERVICES=0`；无 NativeAOT、OpenSSL、编解码库或游戏资源 |
| APK | 3,252,766 B，约 3.25 MB；仅含 ARM64 原生库 |
| APK SHA-256 | `ce73f6791197ca1eb4f3742c28c2ac7921c5c0f3169dd3cbb4e1fe54b7d7be3f`；安装后 base.apk 哈希一致，无 split |
| 报告 PR 基线 | `android/integration@5770a23abdc1c18bdaa7f87a3aec8102fe4d5c6b`；没有把该提交当作已测 APK 的源码身份 |
| 构建主机 | Apple Silicon / arm64，macOS 14.8.5 |
| 构建链 | JDK 23.0.2、Gradle 9.8.1、AGP 9.4.1、SDK/build-tools 36、NDK 29.0.14206865、CMake 3.31.6 |
| 门禁链 | 校验官方包 SHA-256 后使用 Temurin JDK 17.0.21+9 跑仓库 Android gate；构建与门禁 JDK 分开记录 |
| 设备 | Google Pixel 10 Pro XL，设备代号 mustang；`ro.soc.model=Tensor G5` |
| 系统 | Android 16 / API 36；设备安全补丁字段为 2025-11-05，按原值记录 |
| 页与内存 | 页长 4096 B；MemTotal 15,917,432 KiB，约 15.18 GiB；不代表应用可用内存上限 |
| 存储 | 前置读取 `/data` 可用 74,987,964 KiB，约 71.5 GiB |
| 显示 | 物理 1344×2992；横屏截图 2992×1344；HostApi 120 Hz；物理 density 480、原有 override 544，均保留 |
| 应用实际 GPU | `PowerVR D-Series DXT-48-1536 MC1`；应用诊断列 Vulkan 1.3 |
| 系统侧 Vulkan 补充 | `cmd gpu vkjson` 同名 GPU，API 1.3.288；driverVersion 原值 6660496，driverInfo `24.3@6660496`，driverName `PowerVR D-Series Vulkan Driver`。这是 shell 查询来源，不能声称是应用逐字段回报 |

详见 [device.json](device.json)、[package-identity.json](package-identity.json) 和 [installed-package.json](installed-package.json)。

64 GiB 探针仅验证虚拟地址预留，不是物理内存或手机存储分配。

## 六组实测

正式轮次为同一应用 PID 32369，约 28 秒；结果见 [results.json](results.json)。

| 检查组 | 观测与边界 |
|---|---|
| 原生能力、合成 guest | 4 KiB 页、共享内存别名、39-bit 内 64 GiB 地址窗口、Bionic TSD offset 0x0 和线程隔离通过；6 类改写 × 2 guest 线程实际执行通过 |
| 信号与缺页（纳入上组） | SA_ONSTACK 与 sigchain 写缺页均保留 14/14 字；无备用栈对照 12/14，丢 sp-8/sp-16；写 ESR 0x92000047、读 ESR 0x92000007 |
| 12 个虚拟按键 | A/B/X/Y/LS/RS/L/R/ZL/ZR/+/− 逐个出现预期 bit，之后释放归零；这是诊断输入出站链，不证明真实游戏 HID 消费 |
| 左右摇杆 | 分别右上拖动产生正 X / 正 Y，释放归零；未测其余方向、边缘、多指同时输入 |
| 正反横屏 | rotation 1→3→1，同 PID；swapchain pre-transform 0x2 / 0x8；原图已人工核对红块左上、绿色长条右上。保留系统状态栏，不把该画面当游戏渲染验收 |
| HOME 与恢复 | 按住 A 后 HOME，输入清零；generation 1 在 1 ms 脱离；同 PID 恢复，generation 2 实际呈现 |
| Activity finish / 重开 | generation 2 在 3 ms 脱离；脚本检查旧渲染线程 32411 的 `/proc` 项消失，再重开出现新线程 737；进程 PID 不变 |

精选原始应用行见 [selected-logcat.txt](selected-logcat.txt)。截图均为私有原图，只有哈希进入可分享索引。
`reopened-diagnostics.png` 中诊断文字和触屏层按测试 intent 同时显示，不据此声称正式产品布局或安全区验收通过。

## 执行方法与可追溯性

- 使用仓库 `android/tools/selftest_nso.py` 生成合成 NSO，再以当前冻结源码的 `runtime/rewriter/patch_nso.py`、`S2A_TARGET=android` 改写；未用游戏模块。
- 本轮 Python 3.12.10；capstone 模块自报 5.0.7（安装发行包元数据为 5.0.9），lz4 4.4.5，uiautomator2 3.7.1。PR 整理时另用仓库固定的 capstone 5.0.7 发行包与 lz4 4.4.5，从同一冻结源码重新生成三文件，SHA-256 均与实际导入并运行的输入一致；见 [fixture-equivalence.json](fixture-equivalence.json)。该对照只覆盖本次合成输入。
- 三个合成文件通过 `run-as org.s2arm.android` 导入，并逐文件比对完整 SHA-256 后才启动应用。记录见 [selftest-import.json](selftest-import.json)。
- 六组复用 #72 的 `android/tools/device_round.py`。私有适配只把预期显示尺寸从 2400×1080 改成设备实测的 2992×1344；按键坐标仍读当前进程布局日志，没有硬编码 Pixel 按键坐标。
- [pixel-runner.diff](pixel-runner.diff) 和 [runner-identity.json](runner-identity.json) 保存本轮适配与工具哈希。重现时取上述冻结源码的原 `device_round.py`，对副本执行 `patch device_round.py < pixel-runner.diff`，并按记录核对改前/改后 SHA-256；不复制第二套公共工具。没有修改诊断 APK 或项目运行时代码。
- 设备选择与 APK 路径必须显式传入；输出选新的私有目录，手机须解锁。该适配只覆盖本轮已探索的 Pixel 路径，不是通用设备自动门禁。

## 前置失败与恢复

1. 系统 USB 列表已见手机，但原 ADB 服务未枚举到设备；启动本次独立端口的 ADB 服务后连通。没有重启或终止原服务；本次服务最后已停止。
2. 首次离线构建缺 `org.jetbrains:annotations:13.0` 的 JAR 缓存。联网补齐依赖后，原源码的 assembleDebug 与 lintDebug 通过；依赖下载不混作设备测试。
3. Mac 缺少脚本使用的 `sha256sum`；仅在本次主机 PATH 提供委托给 `/usr/bin/shasum -a 256` 的兼容入口。
4. 现有导入脚本紧接 `adb exec-in` 做的即时哈希校验曾读到空文件或部分内容，因此保留失败并停止该次准备。独立复核观察到约 0.6 秒内内容达到预期；后续导入改为有 10 秒上限、0.2 秒间隔的完整哈希复核，三文件均匹配后才运行。没有跳过完整性检查，也没有把该现象归因为游戏或手机原生执行缺陷；具体传输/校验时序原因尚未定位。

## 构建与门禁

- `assembleDebug` / `lintDebug`：通过；lint 0 error、3 warning（工具版本提示、两条 SetTextI18n）。
- `verify-apk.py`：arm64-v8a、16 KB ELF 段与 APK ZIP 对齐通过；`apksigner verify` 通过。
- JDK 17.0.21+9 下 `bash android/gate.sh`：退出 0；Java 测试、App 纯 Java 编译、schema/跨文件约束和 Python 14/7/8 项通过。见 [android-gate-jdk17.txt](android-gate-jdk17.txt)。
- 原 E04 工具 8 项离线负例：通过。
- 上述设备测试时未执行 Linux-only 原生 CTest、完整仓库 `tools/gate.sh` 或合入列车。本次报告 PR 的贡献自检以 PR 正文原样附上的 `tools/contrib_check.sh` 摘要为准，不与冻结包的历史门禁混用。

## 清理与证据

脚本释放触点、停止诊断 App、恢复保持亮屏三项均通过；另行回读：保持亮屏 0、user_rotation 0、自动旋转 0、原有分辨率与 density override 一致。
诊断 App PID 为空，UI 自动化服务进程已停止；本轮没有新增 crash-buffer 行。约 28 秒观察不构成长期稳定性证明。

保留安装的诊断 App 和合成模块以便后续复验；App 私有目录 `du -sk` 为 97 KiB，这不包括 APK、Android 管理的安装数据或 UI 自动化辅助 JAR，未量完整安装占用。

[cleanup-verification.json](cleanup-verification.json) 保存回读结果。
[private-evidence-sha256.json](private-evidence-sha256.json) 只保存选定私有文件的相对名称、大小与 SHA-256，不提供原件下载链接，也不登记序列号文件的哈希。序列号、原始日志、截图、系统 Vulkan 原始查询和本地 APK 继续保留在测试者本机，没有加入本 PR。公开精选日志只含本次诊断进程的探针、输入与 WSI 行。索引的哈希对应私有原件；公开整理副本可能不同，不能用副本回算原件哈希。

## 未测范围

完整 NativeAOT / S2A_Init、真实游戏启动与正式 Vulkan/GAL 渲染、声画与存档、真实 guest HID、实体手柄、全部摇杆方向、多指并行、16 KiB 宿主页、性能/功耗/温控及长期压力均未测。
本包日志中的 `C# NativeAOT: not loaded` 与 CS_SERVICES=0 的构建范围一致，不能记为该能力已通过。

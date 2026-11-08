# E04-Xiaomi13 首轮诊断

2026-10-23，Asia/Shanghai。关联 [#58 认领记录](https://github.com/jhaizhou-ops/S2Arm/issues/58#issuecomment-6363321526)
与[首轮结果评论](https://github.com/jhaizhou-ops/S2Arm/issues/58#issuecomment-6364111403)。
提交者：realskyrin。总 Issue 保持开放，等待维护者验收。

**无游戏资源的原生诊断 APK 完成 6 组检查。** 另经人工核对稳定的正反横屏画面、
反向横屏 A 键按下/释放。该结论不代表完整游戏、正式 Vulkan 游戏渲染或长期稳定性通过。

## 测试身份与环境

| 项目 | 实测值 |
|---|---|
| 源码 | `android/integration@ce9db716c393d6a78ea0f6925415d7637dadc9d5` 的独立快照 |
| 包 | `org.s2arm.android`；debug；versionCode 1；versionName 0.1.0-dev |
| APK SHA-256 | `1978aeb6a6380ed15fa899ea43510a6a5f5389a293088f27524b1c603be10873` |
| 证书 SHA-256 | `d81651ac84f1c4724b4c7e33b2d6fe86a1238ed6d210871e695899fdb2b6eb9f` |
| 主机 | MacBook Air M5 / 32 GB / macOS 27.0.1 |
| 构建链 | JDK 21.0.10 / Gradle 9.8.1 / AGP 9.4.1 / SDK、build-tools 36 / NDK 29.0.14206865 / CMake 3.31.6 |
| 设备 | Xiaomi 13；2211133C / fuxi / SM8550 |
| 系统 | Android 16 / API 36 / OS3.0.309.0.WMCCNXM；安全补丁 2026-08-01 |
| 内存、页 | MemTotal 7,373,212 KiB，约 7.03 GiB；页大小 4096 B |
| 显示 | 1080×2400 / 440 dpi；应用横屏 2400×1080 / 120 Hz |
| GPU | Adreno 740；Vulkan 1.3.128；driverVersion `0x802a4001`；build `bad34dcf83` / `I1064ae0a1f` |
| 条件 | 设备报告 AC 充电；未测功耗、温控或游戏性能 |

本包未包含 NativeAOT、OpenSSL、AAudio、编解码依赖或游戏资源。
64 GiB 探针只验证虚拟地址预留，MemTotal 也不表示游戏可用内存上限。

## 构建与首轮结果

本机 `assembleDebug`、`lintDebug`、`verify-apk.py` 和 apksigner v2 校验通过，
覆盖 ARM64 ABI、16 KB ELF 段和 ZIP native-library 对齐。lint 为 0 error、3 warning
（工具版本提示与两条 SetTextI18n）。Java/契约测试以
`S2A_TEST_NO_NATIVE=1 bash android/test.sh` 通过，使用 JDK 21；
没有将这次结果称为要求 JDK 17 的 `gate.sh` 通过。
首次构建发生于 NDK 尚未安装完成时，失败日志保留；安装完成后的构建才作为通过证据。

| 检查组 | 观测 |
|---|---|
| 原生能力、合成 guest | 共享内存别名、39-bit 内 64 GiB 窗口、TSD offset 0x0 / 线程隔离通过；6 类改写 × 2 guest 线程通过，偏移来自 plat_tsd_offset |
| 信号与缺页（纳入上组） | SA_ONSTACK 与 sigchain 写缺页均保留 14/14 字；无备用栈对照为 12/14，丢失 sp-8/sp-16；读 ESR 0x92000007、写 ESR 0x92000047 |
| 12 个虚拟按键 | A/B/X/Y/LS/RS/L/R/ZL/ZR/+/− 各自出现预期 Npad bit，释放归零 |
| 左右摇杆 | 分别右上拖动产生正 X / 正 Y，释放归零；未覆盖全部方向、边界或多指并行 |
| 正反横屏 | rotation 1→3→1，进程不变；pre-transform 0x2 / 0x8；稳定画面中红标记在左上、绿条在右上；另验反向横屏 A 键 |
| HOME 与 Surface | 按住 A 后 HOME，输入归零；generation 1 在 11 ms 内 detached，恢复时 generation 2 offer/present，进程不变 |
| Activity finish / 重开 | generation 2 在 2 ms 内 detached；旧渲染线程退出，新线程恢复呈现；进程不变 |

首轮保存的 crash-buffer 记录为空，只说明该轮未观察到崩溃。约 8.25 ms 的清屏呈现间隔不作为游戏帧率或能耗成绩。

## 失败过程与证据边界

1. 初次安装报 `INSTALL_FAILED_USER_RESTRICTED`，解锁后安装成功。
2. ARTEMIS 首次定位的 A 点击未获应用日志确认，任务取消。后来用实际布局确认按下与释放。
3. 早期自动矩阵出现 A 等待超时。期间 ARTEMIS 层级确认了凭据锁屏，
   但 ADB 截图仍可返回应用图像；截图、PID 和 dumpsys 单项均不能证明可交互。
4. 解锁后仍有部分 UIAutomator 注入返回 false。最终联合检查原始注入返回值与输入日志，
   不将全部早期失败归因于锁屏，也没有证据认定为 S2Arm 输入缺陷。
5. 初批旋转图捕获过渡动画；等待目标 rotation/size 后再稳定 1.2 秒采集，
   视觉结论仅使用后一次稳定图。自动截图本身不作像素正确性的判定。
6. 临时充电保持亮屏设置已恢复原值 2，应用已停止。没有修改锁屏凭据、安全策略或运行时。

原始失败、恢复和通过记录分别保留在本机，未被通过结果覆盖。
公开文件不含设备序列号、个人路径、凭据、通知、APK 或游戏数据。
原始截图和完整转储不公开；[私有证据哈希](private-evidence-sha256.json)仅用于本地追溯，
不能代替他人独立复验。

[results.json](results.json)是首轮多个阶段的合并记录，并非下述整理后脚本的一次输出，
也不定义新的 run-manifest 协议。[精选日志](selected-logcat.txt)按原始行摘录，
只保留诊断探针、输入、swapchain 和生命周期相关行，不冒充完整日志。

## 手动复验

脚本：[device_round.py](../../../tools/device_round.py)。这是针对已探索的 E04 设备路径的
手动工具，要求横屏 2400×1080、rotation 1/3；其他设备需先探索，不自动宣称支持。
不注册自动门禁，不替代 A-W10 或 R01，也不安装 APK、下载依赖、生成或导入 guest。

先自行构建诊断 APK，确认与测试源码对应，安装并用现有
`android/tools/device_selftest.sh` 导入合成模块。确保手机已解锁且设备空闲，
使用已有含 `uiautomator2` 的 Python 运行（本轮使用 ARTEMIS 环境）：

```sh
python3 android/tools/device_round.py \
  --serial "$ANDROID_SERIAL" --apk "$DIAGNOSTIC_APK" \
  --runtime-commit ce9db716c393d6a78ea0f6925415d7637dadc9d5 \
  --out "$PRIVATE_EVIDENCE_DIR" --keep-awake
```

输出目录必须不存在；输出是**私有原始证据**，上传前仍需人工检查脱敏。
`--runtime-commit` 是调用方记录的源码身份，脚本不从 APK 反推源码；它会核对
本地 APK 和设备安装包的 SHA-256，拒绝不一致或 split APK。
只用显式序列号访问设备，不清 logcat，只终止自己创建的 logcat 子进程。

Canvas 无可用资源 ID，定位优先读取当前进程最新 `touchpad layout`；
只有显式提供 `--fallback-layout` 才允许已验证坐标兜底，格式为 JSON：
`display: [2400,1080]`、`rotation: 1`、`controls: {名称: [x,y,radius]}`，
必须包含全部 12 键及 LSTICK/RSTICK，且匹配当前尺寸/方向。
动作以当前进程的新日志确认；轮询默认 15 秒上限，单次 ADB 命令 30 秒上限，
UIAutomator 调用仍受其传输超时限制，不是硬实时测试。

失败即停止后续组并标记 not_run，返回非零；finally 尝试释放触点、停止诊断包、恢复并回读亮屏设置。
SIGINT/SIGTERM 进入清理，拔线或 SIGKILL 无法保证清理，需重新连接后手动核查设置。
`--keep-awake` 仅临时阻止充电时休眠，不能解锁凭据。脚本不声称覆盖旋转视觉核对和反向 A 键的人工补充检查。

离线负例检查，不连接 ADB：

```sh
python3 android/tests/device_round_test.py
```

## 本 PR 工具验证

整理后的脚本在同一 Xiaomi 13、同一 APK 上独立复跑，6 组全部通过；
见 [rerun-results.json](rerun-results.json)，其中记录脚本 SHA-256，
与首轮合并结果分别保存。清理 3 项通过，ADB 另行回读亮屏设置为 2，
诊断包 PID 为空。复跑时间窗口内 crash buffer 无新记录；
设备全量 crash 历史中其他进程的旧记录不算作本轮应用故障，也没有清除。

8 项无设备负例测试通过，覆盖进程/完整日志过滤、释放顺序、过期或越界布局、
兜底方向/尺寸不匹配、凭据锁屏、清理某一步失败后继续恢复、preflight 失败的跳过状态，
以及设置恢复回读失败。Ruff 0.17.1 检查与格式检查通过，`git diff --check` 通过。
首轮本分支 Java/契约测试（JDK 21，跳过 native）再次通过；当时因本机缺少 JDK 17，
尚未运行 Android `gate.sh`。后续补验见下节。

## 2026-10-24：JDK 17 与 Android 门禁补验

已安装 Homebrew OpenJDK 17.0.21（build 17.0.21+0）。在 PR #72 的
`57cc1825219c1f45e28552828f3c49da8549a906` 上运行仓库原有入口：

```sh
bash android/gate.sh
```

门禁自动选中 Homebrew 的 `javac 17.0.21`，退出码 **0**。Java 测试、纯 Java 类编译、
schema 样例/跨文件约束及 Python 14/7/8 项全部通过；另行运行 E04 的 8 项离线负例也通过。
见[版本与门禁输出](android-gate-20261024.txt)。没有修改门禁、测试或运行时代码，
本次后续提交仅更新报告与验证证据，没有重建 APK 或重跑真机用例。

这次覆盖 `android/gate.sh` 定义的 macOS 无设备 CPU 门禁；
该入口按现有设计设置 `S2A_TEST_NO_NATIVE=1`，不运行 Linux-only 原生 CTest。
仓库整套 `tools/gate.sh`、合入列车及完整游戏验收仍未执行，#58 总 Issue 保持开放。

## 2026-10-24：连接真机后的独立复跑

用户重新连接 Xiaomi 13 后，通过真实 ARTEMIS MCP 调用完成环境自诊断和 UI 层级观察，
环境为 ready，设备探针通过，无活动或排队的 ARTEMIS 任务。
使用 PR 代码 `539b9a07199d7568c30312c4535596eb6f70b4c4` 中的重跑脚本，
在已安装的同一诊断 APK 上执行完整轮次，退出码 **0**。
APK 的 SHA-256 与本地文件及首轮身份一致，原生运行时仍是上文的 `ce9db716` 基线，
没有将该结果当作更新后的集成分支运行时验证。

原生探针、12 键及释放、左右摇杆及释放、正反横屏、按住 A 后 HOME 重建、
Activity finish/reopen **6/6 通过**，清理 **3/3 通过**。
系统仍为 Android 16 / API 36 / OS3.0.309.0.WMCCNXM。
另行回读亮屏设置为原值 2、应用 PID 为空，本轮时间窗口内 crash buffer 无新记录。
人工核对本轮正反横屏稳定图，红标记在左上、绿条在右上；本次没有重复首轮反向 A 键的额外检查。

见[本轮结果、脚本身份与私有证据哈希](device-rerun-20261024.json)及
[本轮精选原始日志](device-rerun-20261024.log)。本轮没有检查失败，也没有修改重跑脚本或运行时；
只提交脱敏结果和验证记录。完整日志、UI 层级与带状态栏的截图保留在本机，未公开。

## 未测项目

16 KB 页真机、Mali、其他系统/驱动、实体手柄、震动/体感、多指并行、完整 D-pad 矩阵；
NativeAOT/OpenSSL/AAudio/Opus/VP8、正式游戏渲染、真实游戏/存档、性能/能耗/热稳定性；
Linux 原生 CTest、Windows/WSL 出口、完整集成门禁与长时间压力测试。
本轮没有 titleId/artifact/profile，不生成虚假的游戏 run manifest。

# E04-vivoXFold 内外屏诊断报告

2026-10-24，Asia/Shanghai。提交者：YTwsy。
关联 [#58 认领记录](https://github.com/jhaizhou-ops/S2Arm/issues/58#issuecomment-6380399779)。

**这一台 vivo X Fold 的 E04 当前阶段诊断已完成：外屏 6/6、内屏 6/6，两轮脚本清理各 3/3 通过，交维护者复核验收。**
另附真实展开、合回外屏的窗口变化记录，以及合回后 A 键按下/释放通过的证据。

## 对照 #58 的交付要求

| E04 当前要求 | 本次交付 |
|---|---|
| 页大小 | 真机读取及应用探针均为 4096 B |
| 地址窗口 | 共享内存别名、39-bit 内 64 GiB 虚拟地址预留通过 |
| TSD | Bionic key table offset 0x0、线程隔离；6 类改写 × 2 guest 线程实际执行通过 |
| 输入 | 两块屏分别完成 12 个虚拟按键、双摇杆右上拖动及释放归零；合回外屏后另测 A 键 |
| WSI | 两块屏分别完成 Vulkan 诊断呈现、正反横屏、方向标记截图核对；记录各自 Surface 和 transform |
| 生命周期 | 两块屏分别完成 HOME 输入清零/恢复、Activity 关闭重开、旧渲染线程退出；附物理折叠观察 |

以上已满足 #58 写明的“当前可跑探针/诊断”设备样本交付范围。总表把正式游戏验收安排在 A-W13 链路完成后；后续游戏验收由该阶段继续推进。本 PR 只提交这一台设备的报告，不关闭整个 #58。

## 测试身份与环境

| 项目 | 实测值 / 来源 |
|---|---|
| 源码与报告分支起点 | `android/integration@137fa0917902cf80ea125cde7a4f2872b9a7ff53` |
| 包 | `org.s2arm.android`，debug，`CS_SERVICES=0`，只有 ARM64 原生诊断库及合成输入 |
| APK | 3,252,766 B；SHA-256 `d0b37fa1263bca9443b1ae9d9b11bb5189f67fc0b9526b0f37034c00de2a7bb7` |
| 安装身份 | 单 base.apk，无 split；安装后 SHA 与本地冻结 APK 一致 |
| 构建主机 | Apple Silicon / arm64，macOS 14.8.5 |
| 构建链 | Temurin JDK 17.0.21+9、Gradle 9.8.1、AGP 9.4.1、SDK/build-tools 36、NDK 29.0.14206865、CMake 3.31.6 |
| 合成输入生成 | Python 3.12.10，固定 capstone 5.0.7（模块与发行包一致）、lz4 4.4.5 |
| UI 驱动 | Python 3.12.10、uiautomator2 3.7.1；只操作本诊断 APK |
| 设备 | vivo X Fold，V2178A / PD2178；`ro.soc.model=SM8450` |
| 系统 | Android 13 / API 33，安全补丁字段 2023-10-01；按真机值记录 |
| 页、内存、存储 | 4096 B；MemTotal 11,608,620 KiB；前置可用存储 303,911,392 KiB。MemTotal 是系统总量 |
| 应用实际 GPU | `Adreno (TM) 730`，应用诊断列 Vulkan 1.1 |
| 系统侧 Vulkan | `cmd gpu vkjson`：同名 GPU，API 1.1.128；driverVersion 原值 2150002688，Qualcomm Adreno Vulkan Driver，驱动构建信息见 device.json |

系统侧驱动字段与应用实际输出分别登记在 [device.json](device.json)。
[package-identity.json](package-identity.json)、[installed-package.json](installed-package.json) 记录包身份。
64 GiB 探针是虚拟地址预留，手机不需要准备 64 GiB 实体内存或存储。

## 两块屏的六组实测

| 检查组 | 外屏 outer-4（PID 14564） | 内屏 inner-1（PID 17425） |
|---|---|---|
| 原生探针与合成改写 | 通过 | 通过 |
| A/B/X/Y/LS/RS/L/R/ZL/ZR/+/− 12 键及释放 | 通过 | 通过 |
| 左右摇杆分别右上拖动，正 X/正 Y 后释放归零 | 通过 | 通过 |
| rotation 1→3→1，同进程，匹配 transform | 0x2→0x8→0x2，通过 | 0x1→0x4→0x1，通过 |
| 按住 A 后 HOME，输入清零、Surface 脱离、同 PID 恢复呈现 | generation 1 在 0 ms 脱离，generation 2 恢复 | generation 1 在 0 ms 脱离，generation 2 恢复 |
| Activity finish，旧渲染线程退出，再开同 PID 呈现 | 旧 TID 14604 的 /proc 项消失，新 TID 15104 呈现 | 旧 TID 17464 的 /proc 项消失，新 TID 18012 呈现 |

两轮的信号探针均记录 SA_ONSTACK 与 sigchain 写缺页 14/14 字保留，无备用栈对照 12/14（丢 sp-8/sp-16）；写 ESR 0x92000047、读 ESR 0x92000007。

外屏精选应用日志跨度约 19.66 秒，内屏约 22.35 秒；这是日志首末时间差，并非长期稳定性测试时长。
结构化结果见 [outer-results.json](outer-results.json)、[inner-results.json](inner-results.json)，对应 [外屏精选日志](outer-selected-logcat.txt)、[内屏精选日志](inner-selected-logcat.txt)。
两轮正反横屏、HOME 恢复、重开截图已核对：诊断 Surface 的红块在左上、绿色长条在右上。状态栏和诊断面板按原样保留在私有原图中。

## Surface、触控坐标与脚本适配

| 项目 | 外屏 CLOSED / state 0 | 内屏 state 1 |
|---|---|---|
| 物理竖屏 | 1080×2520 | 1916×2160 |
| 横屏整屏截图 | 2520×1080 | 2160×1916 |
| 稳定横屏 Surface | 2423×981 | 2072×1817 |
| rotation 1 内容原点 | (97,99) | (88,99) |
| 正/反横屏稳定 transform | 0x2 / 0x8 | 0x1 / 0x4 |

系统栏、挖孔区域使整屏与应用 Surface 尺寸不同；触控日志坐标属于应用内容窗口。
复用冻结源码的 `android/tools/device_round.py`，只对本地私有副本做三类适配：

1. 分别校验整屏截图尺寸、HostApi Surface 尺寸；从当前 `android:id/content` 边界读取原点，将实时布局坐标平移到屏幕坐标，并验证窗口尺寸与控制点范围。
2. 内屏按事前探索日志登记 transform 0x1 / 0x4；仍检查 rotation 1 / 3、同 PID、交换链呈现，并人工核对标记方向。没有强套外屏或小米的 transform。
3. 将原先一次性的前台可见检查改为使用原 15 秒上限等待；遇不可见仍失败，并私下保存最后一次层级。没有跳过可见、释放、线程退出或 Surface 断言。

[outer-runner.diff](outer-runner.diff)、[inner-runner.diff](inner-runner.diff) 是零上下文补丁；对应 identity JSON 给出原脚本与适配后 SHA。
复现时从上述冻结提交取原脚本，在私有目录复制后执行 `patch device_round.py < outer-runner.diff`（内屏换对应补丁），核对前后 SHA，再按原工具显式指定 serial、冻结 APK、runtime-commit 和新的私有输出目录。
工具适配只用于本设备已探索的两种状态；本 PR 没有修改项目运行时或增加第二套公共诊断入口。

三份合成文件来自冻结源码的 `selftest_nso.py` 与 `patch_nso.py`（`S2A_TARGET=android`），通过 run-as 导入。
每份文件均在 10 秒上限、0.2 秒间隔内复核完整 SHA，三份匹配后才启动；实际观察值见 [fixture-import.json](fixture-import.json)。

## 实际展开与合回观察

由设备持有人真实操作铰链，未用 device_state override 模拟。

- 外→内：PID 15381 保持不变，generation 2 从 2423×981 更新到 2072×1817。期间发生熄屏/Surface 脱离；点亮后同 PID 的内屏图像和正反横屏日志已采集。首次状态轮询触发后立即快照仍读到 state 0，该过渡快照未用作内屏结论；后续按稳定物理分辨率确认 state 1。
- 内→外：另一次观察 PID 18368 保持不变，2072×1817 更新为 2423×981，generation 1 在 0 ms 脱离后 generation 2 恢复呈现，稳定 transform 回到 0x2。外屏恢复后 A 键产生 0x0001，随后归零，通过。

原图方向已核对。见 [fold-observations.json](fold-observations.json) 和 [折叠精选日志](fold-selected-logcat.txt)。这两次记录交付窗口变化与恢复证据，未测折叠全程连续上屏、切换时延或反复折叠耐久。

## 失败与恢复记录

失败轮次均保留，详见 [attempts.json](attempts.json) 及私有证据哈希索引。

1. T7 上的 Gradle 缓存尝试在 jars-9 目录创建处失败；随后从同一冻结源码的独立工作树构建，复用已有内部缓存，离线 assembleDebug/lintDebug 成功。APK、合成输入和原始证据保存在外置盘。尚未确定外部缓存目录错误的根因。
2. APK 安装首次等待 120 秒超时；vivo 安装确认页尚未确认。继续本次诊断包安装后核对 base.apk SHA 一致，再开始设备测试。
3. outer-1：原生探针先通过，等待误设为整屏尺寸的 HostApi Surface 超时，后五组未跑。
4. outer-2：熄屏、Surface 脱离，没有取得横屏断言，后五组未跑；设备持有人重新解锁后继续。
5. outer-3：前五组通过；第六组开始前一次性前台可见检查失败，当时私有截图中有系统通知覆盖，具体因果未确定。
6. outer-4：按实际窗口适配并使用有上限的可见等待，全部六组及清理通过；inner-1 全部六组及清理通过。

## 构建、门禁与清理

- assembleDebug / lintDebug 通过，Lint 0 error / 2 warning（均为 SetTextI18n）。
- verify-apk.py 的 ARM64 ABI、16 KB ELF 段 / ZIP 对齐、apksigner verify 通过。设备实际为 4 KiB 页。
- JDK 17 Android gate 通过：Java 单测、App 纯 Java 编译、schema / 跨文件约束、Python 14/7/8 项；见 [android-gate-jdk17.txt](android-gate-jdk17.txt)。原 device_round 的 8 项离线测试通过。
- 报告提交对应的贡献自检摘要原样附在 PR 正文；上述主机门禁没有运行 Linux-only 原生 CTest 或完整维护者第二层测试。
- 两轮脚本的释放触点、停止诊断 App、恢复亮屏设置各 3/3 通过。最终回读七项原设置一致：亮屏 0、user_rotation 0、自动旋转 0、超时 120000、外屏物理分辨率、density 480、折叠状态 0。
- 诊断 App、UI 自动化服务和本任务的独立 ADB 服务已停止；原 ADB 服务未动。测试窗口 crash-buffer 无新增行。

[cleanup-verification.json](cleanup-verification.json) 保存清理回读；保留诊断 APK 和合成输入便于复验。App 的 files 目录为 87 KiB，不含 APK、Android 管理数据或自动化辅助文件。

## 公开证据与后续范围

本目录只含脱敏报告、结构化结果、允许字段的当前诊断进程日志、工具补丁和哈希索引。
[private-evidence-sha256.json](private-evidence-sha256.json) 只列选定原件的相对标签、大小和 SHA；原始截图、UI 层级、完整日志、系统 Vulkan 查询、APK 均保持私有。序列号文件及其哈希不登记，游戏文件、密钥、存档、个人路径不进入提交。公开整理副本与私有原件可不同，索引哈希以私有原件为准。

后续待 A-W13 的正式游戏链路验收：完整 NativeAOT/S2A_Init、游戏 Vulkan/GAL、声画与存档、真实 guest HID。实体手柄、全部摇杆方向、多指并行、16 KiB 页真机、功耗/性能/长期压力也不在这轮诊断内。当前页大小、地址窗口、TSD、诊断输入、WSI 和生命周期六类交付已完成。

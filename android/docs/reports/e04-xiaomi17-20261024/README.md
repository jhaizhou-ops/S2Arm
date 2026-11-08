# E04-Xiaomi17 首轮原生诊断报告

2026-10-24，Asia/Shanghai。提交者：fengbird。

关联 [#58 认领](https://github.com/jhaizhou-ops/S2Arm/issues/58#issuecomment-6379330261)、
[维护者提交建议](https://github.com/jhaizhou-ops/S2Arm/issues/58#issuecomment-6379379324)。
目标分支为 `android/integration`。本轮 **6/6 组本地诊断通过，待维护者复核**，
不关闭 #58，不代表整个 E04 完成、Android 游戏可玩或长期稳定性通过。

## 1. 实现、报告与包身份分开记录

| 项目 | 本轮事实 |
|---|---|
| 实际实现 / APK 构建 commit | `f0ab33d1e2bad4cdb8332b5bc73c33eb06159a47`，`android/integration` 的独立干净工作树 |
| 本报告分支基线 | `cc16b5fef4f699d043d95e65d8270ef00df89e2a`；不是本 APK 的构建身份 |
| APK SHA-256 | `c3b71254eeb11181dcaa4ceb82bfd37c327dd7a59a6932e4227e3fd444f4bebe` |
| 安装后 base.apk SHA-256 | `c3b71254eeb11181dcaa4ceb82bfd37c327dd7a59a6932e4227e3fd444f4bebe`，从手机读回，与本地包一致 |
| 包名 / 版本 | `org.s2arm.android`，debug，versionCode 1，versionName 0.1.0-dev |
| 模式 | `S2ARM_ANDROID_CS_SERVICES=0`，无商业游戏资源的原生诊断包 |
| 签名证书 SHA-256 | `2a2bbf93dcfd4053b6246cdfa01ef23bf40d673162aa36879c103d7923f1d03f`，v2 验签通过 |
| 主机 / 工具链 | Mac14,9 / 16 GiB / macOS 26.2；JDK 17.0.6、Gradle 9.8.1、AGP 9.4.1、SDK/build-tools 36、NDK 29.0.14206865、CMake 3.31.6 |
| 改写器依赖 | 隔离 Python 环境：capstone 5.0.7、lz4 4.4.5 |

已核对 `f0ab33d1..cc16b5fe`：变化为 #128 的构建闭包工具、相应测试及文档，
没有 Android 运行时代码变化。因此保留已冻结的实现 commit、APK 与原始测试窗口，
**没有为了最新报告基线或格式一致而重构建 APK、重跑六组操作**。

## 2. 设备与驱动：只填实际读数

| 项目 | 实测 / 已知信息 |
|---|---|
| 商品名 / 型号 | 小米17（商品名由用户提供）；设备返回 Xiaomi / 25113PN0EC / pudding |
| SoC / ABI | SM8850 / arm64-v8a |
| Android / API | Android 16 / API 36 |
| 宿主页大小 | **4096 B（4KB）**；APK 16KB 对齐不等于 16KB 页真机通过 |
| 系统 MemTotal | 15,373,316 kB；系统可见总内存，不是游戏可用上限 |
| 实际 Vulkan GPU 名称 | 应用日志报告 `Adreno (TM) 840` |
| Vulkan API | 应用日志报告 1.4 |
| 实际 Vulkan 驱动版本 / build | **原11:23轮次未采集**；后续系统侧补采见§8，不追溯改写原轮次，也不把API1.4或GPU名称当驱动版本 |
| 横屏截图尺寸 | 2656×1220；未改系统分辨率，方向仅通过诊断 Activity 的 intent 设置 |

## 3. 六组操作及证据对应

通过轮次为 **2026-10-24 11:23:05–11:23:28 +08:00**。
应用 PID **29051** 全程不变；初始渲染线程 TID **30120**，finish/reopen 后为 **30783**。
这些是本轮进程标识，不是设备序列号。脱敏选段中 `P1` 对应该 PID；
完整匿名线程映射、每组原始日志行号区间及截图哈希见 [results.json](results.json)。

| 检查组 | 本轮结果 / 验证边界 | PID / 原始日志证据 | 私有截图对应 |
|---|---|---|---|
| 原生探针 / 合成 guest | 共享别名、39-bit 内64GiB虚拟窗口、TSD offset 0x0 / 线程隔离；6类改写×2线程实际执行；SA_ONSTACK及sigchain写缺页14/14，读写ESR可区分 | PID 29051；`device-round-03/app-logcat.txt` 的原生探针行及 `device-selftest-01.log` | `reopened-diagnostics.png`：重开后的同项诊断面板，不是冷启动帧 |
| 12个虚拟按键 | A/B/X/Y/LS/RS/L/R/ZL/ZR/+/−分别出现目标bit后归零；不外推真实guest HID消费 | PID 29051；原始应用日志中12组按下/释放对 | `landscape.png` 仅作布局参考；**无专门动作截图**，动作证据是日志与采集器断言 |
| 左右摇杆 | 两摇杆分别右上拖动，正X/正Y并释放归零；未覆盖所有方向、边界或多指 | PID 29051；原始应用日志左右轴序列及归零 | 同上，仅布局参考；**无专门动作截图** |
| 正反横屏 | rotation 1→3→1，同PID；稳定图红标记左上、绿标记右上 | PID 29051 / 渲染TID 30120；rotation与swapchain transform 0x2/0x8/0x2行 | `reverse-landscape.png`、`landscape.png` |
| 持有A时HOME / 恢复 | HOME后按键归零，旧Surface在2ms内detached；恢复时generation2实际呈现，同PID | PID 29051 / TID 30120；A按下、归零、generation1 detached、generation2 offer/present | `home-restored.png` |
| finish / 重开 | generation2在8ms内detached；旧渲染线程退出，重开新线程呈现，PID不变 | PID 29051；旧TID 30120、新TID 30783；原始日志及采集器结果 | `reopened-diagnostics.png` |

旧渲染线程退出是采集器在重开前用 `run-as` 检查 `/proc/<pid>/task/<tid>` 不存在后的断言结果；
命令和组结果保留在私有 `results.json`，**没有独立保留该条命令的stdout**。
原始应用日志能独立显示重开后的新渲染线程，但不把报告补写成App输出。
`landscape.png` 在转回正向横屏时再次采集，保留的是回转后的图片，不冒充首次启动或按键动作截图。
诊断面板开启时文字与控件存在覆盖，保留为调试视图事实，不作为游戏UI质量结论。

## 4. 公开选段与私有证据保全

- [selected-logcat.txt](selected-logcat.txt)：通过轮次的82条精选应用原文，改为相对时间和匿名进程/线程前缀；保留消息正文、按键bit、ESR、Bionic槽偏移与Vulkan transform。
- [results.json](results.json)：按实际既有结果整理的结构化摘要，含六组操作、真实PID对应、原始日志行号、截图SHA、未测项和采集器断言边界。**不是新运行的App协议或伪造的原始输出**。
- [private-evidence-sha256.json](private-evidence-sha256.json)：原始日志、截图、安装失败/恢复、两轮采集失败及对照诊断、构建日志等52份私有文件的SHA和字节数；没有这些文件的原始内容或个人绝对路径。
- [build-validation.txt](build-validation.txt)：冻结实现上的既有构建、离线检查与验签输出；个人主机路径改为占位符、规范化行尾空白，不把本次文档提交身份冒充APK身份。
- [SHA256SUMS.txt](SHA256SUMS.txt)：本报告公开文件的校验值。

全部六组共享的原始应用日志SHA：
`b5b518c814d77193f10b2d465cb5f6d53e90836bccbd26431d4a29281538714a`。
每张原始PNG的SHA与字节数均在私有证据清单，按维护者要求**只公开摘要和SHA，不上传原图**。
按键/摇杆缺少专门动作截图是现有证据的限制；不为补齐格式重拍，也不把共享截图说成独立动作证据。

## 5. 失败、重试与清理

1. 初始锁屏、手机拒绝USB安装均保留。用户解锁、开启USB安装后，第二次安装成功且安装后SHA一致；没有通过卸载或清数据绕过。
2. `device-round-01`：本地采集器从 `dumpsys window windows` 子段查焦点，该系统子段没有焦点行；完整window/activity记录确认App已聚焦。只修正本地读取方式。
3. `device-round-02`：分离的adb `motionevent DOWN/UP`返回0，但没有期望的A输入日志，随后组未执行，不把此轮记为通过。
4. 对照诊断在同一PID、同一坐标分别记录DOWN、UP和定点swipe；只有定点swipe产生按下/释放对。改用已观测有效的注入方式后，`device-round-03`六组通过。

未修改App、运行时、验收阈值或全局分辨率。本地USB采集器在仓库外，
复用 #72 的日志与布局解析函数；采集器源文件SHA已保全，不另建A-W10门禁或R01报告系统。
原工具 `device_round.py` 的2400×1080限制没有被当成小米17已支持的结论；本轮按实际布局与2656×1220截图验证。

结束后App已force-stop，回读PID为空；APK保留安装、不清数据。
保持亮屏设置没有修改，前后读数均15。仅本轮窗口、对应测试PID的crash-buffer记录为0，不能外推长期无崩溃。

## 6. 已有验证与未测项

冻结实现上已通过：Java/契约自测与纯Java编译；Python14/7/8项；E04工具8项离线负例；
assembleDebug、lintDebug、ARM64 ABI、16KB ELF/ZIP对齐与v2验签。lint保留两条SetTextI18n提示。
macOS自测使用仓库既有 `S2A_TEST_NO_NATIVE=1` 路径，不宣称Linux原生CTest通过。
本次报告提交的贡献者自检摘要另外原样贴在PR正文，不重复这轮手机操作。

原轮次未测：实际Vulkan驱动版本、16KB页/Mali、全部摇杆方向/边界、多指、实体手柄、震动/体感、
完整NativeAOT/OpenSSL/AAudio/编解码、真实guest HID、正式游戏画面/声画/存档、功耗/性能/温控/长期压力、Windows/WSL出口及完整集成门禁。
`CS_SERVICES=0` 下日志中的NativeAOT未加载是范围限制，不将其抹掉或写成完整服务层通过。
不以诊断清屏的呈现间隔冒充游戏FPS，不上传APK、序列号、游戏资源、密钥、存档或原始系统窗口转储。

本次只交现有原生诊断证据供审，不请求维护者重复功耗/性能测试，不改其他设备认领或W10/W13实现。

## 7. 本次报告提交自检与补验

运行了仓库原有 `tools/contrib_check.sh --base cc16b5fe`：脚本退出0，摘要显示“绿”，但第一层为0/0步。
独立运行同一改动集的 `GATE_LIST=1` 后，`tools/gate.sh` 在列清单前因本机缺少
`/Applications/Xcode-27.1.app/Contents/Developer` 退出2。doctor同时报告.NET 10 SDK未安装。
因此**不把该0/0绿摘要视作完整贡献者门禁已通过**，最初以草稿提交供审；没有修改门禁或降低阈值。
PR正文原样附自检摘要并注明这项限制。报告JSON、原文选段对应、52份私有证据SHA、公开文件SHA及`git diff --check`另行核验通过。
该限制属于本次报告提交环境，不改变冻结实现上已经保存的构建、自检及六组真机结果。

随后核对 `tools/toolchain.sh` 已有的 `S2A_DEVELOPER_DIR` 入口，指向本机
`/Applications/Xcode.app/Contents/Developer`（Xcode26.3），重新运行相同贡献者自检。
本次实际跑了3/3步：语法检查、shared_path_test、Android Java/契约门禁，全通过，退出0；
没有重跑手机六组操作、功耗或性能测试，也没有修改统一工具链文件、全局xcode-select或验收阈值。
PR正文附最新提交对应的原样摘要。doctor仍按统一配置提示Xcode27.1和.NET10缺失，
但本次选中的3项检查不依赖它们，iOS全量编译未被路由选中。
这只证明本报告改动的适用检查在已记录的本机环境下通过，**不代表Xcode27.1苹果构建、NativeAOT或游戏运行已验证**。

## 8. 后续补采：系统驱动及摇杆方向边界

本节是2026-10-24后续新增证据，**不是原11:23六组轮次的补猜或重跑**。
仍使用实现 `f0ab33d1` 和完全相同的已安装APK（SHA再次核对一致），不重构建、不安装新包、不改App或全局显示设置。
原 `results.json`、原日志和52份私有证据清单保留不变。

### 8.1 系统侧Vulkan驱动信息

12:37通过 `adb shell cmd gpu vkjson` 读取；来源是系统物理设备查询，不冒充原App日志或实际启用能力清单。
补测应用PID30754的映射另观察到 `/system/lib64/libvulkan.so` 与 `/vendor/lib64/hw/vulkan.adreno.so`。

| 字段 | 原值 / 含义 |
|---|---|
| GPU | `Adreno (TM) 840` |
| driverName | `Qualcomm Technologies Inc. Adreno Vulkan Driver` |
| driverVersion | 十进制 `2150932524`，十六进制 `0x8034a02c`；厂商定义编码，不用通用Vulkan版本宏推成驱动点分版本 |
| driverInfo | `Driver Build: c68cddd35e, I5623c5269d, 1785403797`；`Date: 07/30/26`；`Compiler Version: E031.50.19.29` |
| 物理设备apiVersion | 原值 `4210983`，按标准API字段解码为 `1.4.295`；不是驱动版本 |

完整允许公开字段及来源见 [driver-supplement-20261024.json](driver-supplement-20261024.json)。
不公开设备/驱动/cache UUID、原始vkjson或带地址的maps，只在补充私有证据清单中给SHA。

### 8.2 两摇杆四方向、钳制与释放

补测窗口：12:43:20–12:46:35 +08:00；输入进程PID **30754**，与原轮次PID29051分开。
本轮只做输入补测，未重复旋转、HOME、finish/reopen等原六组流程。

| 检查 | 主轴实际达到 | 正交轴保留读数 | 释放 |
|---|---:|---:|---|
| 左摇杆右 / 左 | 32767 / -32767 | Y=18 / 17 | 均归零 |
| 左摇杆上 / 下 | 32767 / -32767 | X=49 / 48 | 均归零 |
| 右摇杆右 / 左 | 32767 / -32767 | Y=105 / 107 | 均归零 |
| 右摇杆上 / 下 | 32767 / -32767 | X=-100 / -102 | 均归零 |

8/8自动检查通过。手势从实时布局中心拖至1.35倍半径；保留整个范围检查，采样值未越过±32767。
布局日志由现有MainActivity以`%.0f`输出浮点中心/半径，因此整数注入中心最多有0.5像素量化误差。
正交轴观测界按 `ceil(32767×0.5/(日志半径−0.5)+0.5)` 推导（左112、右136），保留真实小读数，不改程序deadzone或轴范围，也不把该界当游戏性能判据。

### 8.3 首次人工窗口未完成，保留partial历史

人工窗口要求“A+B同时按住后释放”和“左摇杆偏移+A后释放”。180秒有界窗口内未观测到对应组合，
两项均记为 `not_observed`，**不能写成多指通过或App多指失败**。
采集器因此非零退出，补测整体状态为 `partial`；不能用8项自动通过覆盖这项未完成。
后续独立人工窗口已完成，见§9；本节原窗口结果不追溯改为通过。

首次补采输入注入后未见非零日志，作为采集失败保留；对照中后续斜向/横向手势可观测，首手势未响应的原因未确证，不归因于App。
横向对照另显示正交轴微小非零，源码确认布局输出有上述整数化，因此在第二次采集器中明确量化观测界。
第二次有界输入就绪检查为首次未观测、第二次观测成功，随后8项完成；失败、对照与重试均有独立SHA保全。

结果见 [input-supplement-20261024.json](input-supplement-20261024.json)，原文选段见
[input-supplement-logcat.txt](input-supplement-logcat.txt)，22份新增私有证据的摘要校验见
[supplement-private-evidence-sha256.json](supplement-private-evidence-sha256.json)。新截图只作布局上下文，不冒充逐动作帧，也不上传原图。
结束后App已停止，保持亮屏读数前后相同；不清日志或应用数据。范围仍为`CS_SERVICES=0`诊断，不外推guest HID、真实游戏或长期稳定性。

## 9. 独立人工多指补测：2/2通过

2026-10-24 **12:56:31–12:58:40 +08:00**，新会话 **P3 / PID5085**。
用户实际触屏操作；采集器仅启动、记录和清理，**不注入任何触摸**。
实现仍为`f0ab33d1`，安装后APK SHA再次读回与§1冻结值一致。
没有重构建、重装，也没有重复原六组或§8.2的8项自动动作。

| 检查 | 同时输入的实际日志 | 随后全部释放 | 原始日志行 |
|---|---|---|---|
| A+B | `buttons=0x0003 L=(0,0) R=(0,0)` | `buttons=0x0000 L=(0,0) R=(0,0)` | 1041→1043 |
| 左摇杆+A | `buttons=0x0001 L=(-31981,7133) R=(0,0)` | `buttons=0x0000 L=(0,0) R=(0,0)` | 289→945 |

两组都实际观测到组合输入及其后的全零释放，人工采集器退出0。**不宣称按住满1秒或长按验证**：
A+B组合到全零日志间隔仅73ms；左摇杆+A的首个匹配到后续全零间隔5326ms，中间有轴/按键变化，
不是连续不变持有时长。这是原生触屏状态合并验证，不等于真实guest HID或游戏输入通过。

结构化结果见 [manual-input-20261024.json](manual-input-20261024.json)，
带原始行号的脱敏原文见 [manual-input-logcat.txt](manual-input-logcat.txt)，
8份本次私有证据的SHA及字节数见 [manual-private-evidence-sha256.json](manual-private-evidence-sha256.json)。
两张私有截图只对应就绪布局和操作结束，不冒充两指按住瞬间；动作结论来自同PID日志。
原六组、§8自动补测及先前`not_observed`记录均保留不变。

结束后诊断App已停止，PID回读为空；保持亮屏设置前后均15，未清日志或应用数据。
原始日志、截图及本地采集器只公开摘要/SHA，不上传原件或设备序列号。仍待维护者复核，不扩展整个E04验收范围。

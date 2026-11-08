# Android 开发总览（接管基线）

> 合流状态（2026-10-28）：本页下方为原分支历史快照，不能当作候选验收。来源为开发线 `785a9b1a8` 与 main `75653d533`；main 原页的 `2026-10-24 / main@8a9f2578 / android/integration@11d22458` 也仅为历史基线。当前工作与证据见[统一方案](fast-generic-v3.md)，本次合流状态见[合并分析 §13](direct-main-merge-analysis-20261028.md#13-从当前开发线实际合并最新-main2026-10-28)。


历史页更新：2026-10-25；当时代码基线：`main@8a9f2578`；集成分支：`android/integration@11d22458`（当时 #54/#59 已合；behind main 0 为当时读数）。
维护规则：本文只给当前状态、证据入口、开放工作和关键路径；实现细节以代码与
[统一方案验收章节](fast-generic-v3.md#7-当前事实c0c8-验收与偏航纠正)及代码证据为准。目标与实现顺序统一见[快速通用模式方案](fast-generic-v3.md)；ChangeLog 只记里程碑达成、回滚或验收结论变化，普通状态更新不追加。

## 0. 直连专项状态入口

2026-10-26 的源码核对点、已有新后端日志和待证实问题统一见[方案 §7.4](fast-generic-v3.md#74-当前接线与待证实问题2026-10-26)；实施数据流见 §5.5、下一交付见 §8。以下表格保留2026-10-25的历史证据，不据此断言当前 provider/窗口尚未接线，也不代表新后端已经完成游戏绘制。重复临时交接文档已删除。

现行要求：[方案 §3.1](fast-generic-v3.md#31-xgs-退出-android-的范围与完成标准)规定本轮移除 Android XGS 生成/加载及诊断兼容入口，不新增 S2AP，统一接 `s2a-direct-program-v1`。下表的 XGS/旧引擎/语义剥离字样只记历史，不是当前实现指令或正式正确性证据。

2026-10-30：旧 d2r 引擎副本 `graphics/third_party/d2r_vulkan_engine`、直接依赖它的专属探针与 CMake `engine` 后端分支已删除；`S2ARM_ANDROID_VK_BACKEND` 只接受 `nvn_vk`。下表「引擎已进 APK / 引擎七帧 / 引擎加载 `.xgs`」等条目是当时的历史证据，不能再用当前树复现，也不再作为验收依据。

### 2026-10-25–27 历史证据（各条按原日期）

原开发工作树：`android/direct-mode-d2r`。本节只记直连专项；A0–A8 历史基线仍见下文，不能替代这里的 C0–C7 证据。

| 项 | 状态 | 当前证据 | 仍缺 |
|---|---|---|---|
| C0 ABI/启动事务 | 通过（ELF 前端实调除外） | services v1/v2、runtime v2、direct table、attempt 故障锁；ARM64 真机探针 | 真实 ELF 前端调用链 |
| C1 选择/装配 | 部分 | 选择事务、attempt、v2 request、探针；生产 provider 上真机：`graphics selection: direct (direct committed before relocation), devices=1 queues=1`。**合成内容上 direct 会话已整局跑通**（2026-10-25）：`StartV2` 的 direct 分支 bind compiler（`s2a_direct_bind_compiler_v1` 实装）+ `activate`（引擎真机初始化）→ `direct session active / status: state=1 blockers=0` → `direct composition: managed GPU disabled` → HLE 起全（`DirectRenderer`、时区系统数据、LibHac NPDM 通过、存档、HID）→ `Android services start: v2=1 rc=0 state=2` → `nnosInitialize/nnMain` → `nnMain 返回` → `direct session closed: stop=0 destroy=0`。**attempt 锁已真机复验（2026-10-25，合成包）**：正常收局打印 `finish held=1 normal=1` → `lock cleared`，紧接着两局 AUTO 都是 `graphics selection: direct`（两个根因：键缓冲 64→65、Android 在 guest 线程 `_exit` 前清锁） | **没有 direct 出图**；present/WSI 未接、多 profile 选优、设备装配包 |
| C2 统一翻译 | 大部分完成 | 119 checks；离线 CLI/设备 AOT 同 26087 B/SHA（**2026-10-25 新包复测逐字节一致**）；CubeArray、Vulkan1.1 draw parameters；C2 VS/FS/TEX/双纹理/UBO 合成程序；**通用 XGS 打包器 `DirectBundle`（编译输出 + control → 引擎 `.xgs`，离线/现编共用；FS 与 `direct_c2_xgs.py` 逐字节一致，顶点输入位置按真实 SPIR-V 取）** | 真实游戏 `prog_t` 状态/C1/真实纹理池；三角/四边形仍是合成顶点 |
| C3 GPU 执行 | 部分 | RT clear/draw/dispatch/T2T/buffer/T2B/B2T/stride、局部区域/通道掩码/有符号精度；2026-10-25 macOS 宿主+NDK r29 复跑 `vk-micro/vk-record: ok`（executed=9） | 程序/资源/描述符仍测试注册；视图/mip/数组层/间接/双池 |
| C4 同步/WSI | 部分 | 真机 present fence 退休；旋转两代 swapchain 各 3 帧 | 游戏窗口/lease、backing、首次呈现 |
| C5 HLE/引擎 | 部分 | **direct 组合（2026-10-25）**：`core-runtime/DirectRenderer.cs` 让 HLE 在没有托管 GPU 的情况下起全（要 GPU 资源的成员一律带名抛 `NotSupportedException`，`RunLoop` 不跑 GPU 模拟循环）；`tools/synthetic_systemdata.py` 从宿主 IANA 库给合成包补时区系统数据；`tools/synthetic_npdm.py` 改用 Ryujinx `Homebrew.npdm` 模板（LibHac `GetNpdmFromBuffer` = Success）；`tools/selftest_nso.py --sdk-entries` 导出运行时要求的 7 个 SDK 入口。 | **引擎已进 APK：设备内 init/关闭 + 第一帧 + 上屏**（`S2A_ANDROID_VK_ENGINE=1`：合成 C2 程序 `.xgs` 回放读回 `center=255,0,0,255`；`present` 回调 blit 到本进程 swapchain，**连推 10 帧、present fence 全部经 `vk_track` 退休**（`submitted=10 retired=10 pending=0 failed=0 drain=0`），截图中心是最后一帧颜色 `0,0,255`；**旋转换代先 drain 旧代际再建新 swapchain**，两代截图都是最后一帧颜色，退出 `end generations=2 drain=0 submitted=20 retired=20`）；d2r 引擎真机初始化/关闭；C2→`.xgs`→共享 `prog_t`→引擎七帧（红/红/绿/TEX slot1 绿/双纹理槽2+3→黄/**guest c[0] UBO→黄、清 0→黑**）；槽位由反射 `HandleIndex` 决定；UBO binding 进 `.xgs` 并由前端 `BindUniformBuffer` 供数；**第二块内存池的纹理池按全局 id 上界判空（修复后第八帧读回绿）** | 真实游戏资源/loader/池淘汰重用与图像池/变址与 B64 加载/视频/音频；**引擎+共享前端已编进 per-game APK（同 DSO）**；**运行时补编已通**：SetShaders 现场译 `.xgs`、引擎加载、Float64 能力已裁；**新 Vulkan 后端（`nvn_vk_*`，产品方向）**：格式/采样器/采样器缓存/纹理缓存（身份+generation）/tex_t（线性+块线性+mip+3D）/C2→pipeline→draw 六项真机自测全 ok；**管线缓存**（C2 blob→modules/4 set/pipeline layout/render pass/descriptor sets，draw 读回红）与**真实 Surface draw present**（acquire→record→PRESENT_SRC→present→fence，`nvn-vk draw present: rc=0`）也已真机验证。**引擎降为脚手架**，未接 provider/前端对象/游戏 present |
| C6 系统输入法 | 部分（preview 已合） | 中文 Gboard 组字→候选→确认 `ok, chars=2, utf8=6`（2026-10-25 复跑）；取消 `cancel`；Stop waiter `rc=-4`；broker host 199 断言、keyboard producer PASS、ui-session ok；`assembleDebug` 成功 | direct/generic 游戏内文本、单虚拟核 Stop、候选自动点选、extract/横屏 |
| C7 首款游戏 | 部分（direct 进入暗黑3世界并可操作；约 18–20 fps，60 fps 未达） | **2026-10-27 真游戏 direct**：标题/过场/菜单/难度/玩家选择/读盘/世界画面均由新 Vulkan 后端真实绘制并接受输入；世界约 485 draw/帧、3530 条命令/帧，帧时 50–57 ms（过场 60 fps）；纹理 pin 修复彩色噪声，open pass 合并 + 提前提交 + `-O2` 把世界从 2–3 fps 提到 18–20 fps。详见[方案 §8.3](fast-generic-v3.md#83-2026-10-27-直连首次进入暗黑3世界当前事实与读数)。 | 60 fps（CPU 录制 37–41 ms）、精确遮挡查询、菜单 3D 背景 viewport、视频/音频/存档长跑、正常退出/重启 |

**历史直连真游戏进展（2026-10-25，早于 10-27 出图证据）**：Diablo III `01001B300B9BE000` 在 directed APK + direct 资源包下跑到
`nnMain` 并把真实 NVN 命令发到 native 引擎；会话在第一个 shader bundle 缺失处 fatal。`s2a_direct_lookup`
旧桩（direct 下对所有未定义导入 abort，真机被链接器符号 `__rel_dyn_end` 撞死）已修成只接管
`nvnBootstrapLoader`。详见 CHANGELOG `ANDROID-DIRECT-C7-REAL-GAME-SESSION-001`。仍**没有 direct 帧**。

C6 旁路已按独立 commit 合入主链：`87447084`（HostKeyboard/IME 可服务、mode5 候选、selftest 参数）、`3ceb033f`（中文确认/取消/Stop 证据与脚本）。没有整支 merge；旁路代码未改主链 C5 文件。C6 仍不替代 C7 游戏验收。

**宿主更换（2026-10-25）**：执行机从 Linux 换到 macOS arm64。本机装了 NDK r29 darwin、cmdline-tools、platform 36、build-tools 36.0.0、cmake 3.31.6、JDK 17，`S2ARM_ANDROID_CS_SERVICES=static bash android/host/build.sh` 可在本机出 APK（AOT 静态库需用 NDK `llvm-ar` 重归档，见 CHANGELOG `ANDROID-DIRECT-BUILD-MACOS-001`）。设备 `4c6229ab`（Redmi 22081212C / Android 16 / Adreno 730）上新包（48,862,027 B / sha256 `5053b685…`）已复跑：C2 设备 AOT 逐字节一致（26087 B）、C6 中文 IME 确认/取消/Stop、C4 WSI 两代 swapchain 全过；C0/C1/C3/C5 的探针证据见 `ANDROID-DIRECT-NDK-HOST-001`。`android/test.sh` 在 macOS 上受 `runtime/memory.c` 的 Linux 专有 `mremap` 限制，该 native 子集仍以 Linux 为准。

## 1. 历史接管结论

**直连专项补充（2026-10-25）**：目标与实现方案已统一到[快速通用模式方案](fast-generic-v3.md)，ABI 细节见[实施契约](direct-mode-contracts.md)，源码复用依据见[D2R 审计](direct-mode-d2r-study.md)。当前已打通的探针与真实启动证据见上方 §0；真实游戏仍无 direct 帧，首遇编译和游戏 WSI 尚未闭合。上述“无 direct 帧”仅指 10-25 当时；10-27 证据见 §0。下面 A0–A8 保留历史接管基线，不代表当前状态，也不作为另一路产品计划。

**A0 已完成；A1 第一批 `plat.h` + 调用点迁移已合入 main（#54），v2 内存/别名组在 #59 复查；A2 的宿主/服务接线已大部分完成但真实原生核心仍是 stub；A3 只有诊断 Presenter 和窗口租约，共用 Vulkan 后端未落地；A4 已打通导入/安装/每游戏 APK/apk-asset，inspect/resolve/job engine 还没接完；A5 已落 S1a/S1b 代码闭环与 S2 出包/装包端（宿主验证，未接真机）；A6–A8 未开始。**
按里程碑：**AN0 达成，AN1 进行中，AN2 及以后未到。**

## 2. A0–A8 历史状态

| 项 | 状态 | 已有 | 仍缺 / 下一步 |
|---|---|---|---|
| **A0 契约与安装** | ✅ 完成 | 四份 v1 schema + run manifest（#26/#32）；`current.json`/revision/安装事务（#27）；对象库符号链接；HostApi 外壳 user/meminfo/input/display（#41）与 stop（#43）；每游戏 APK（#24）；apk-asset `map_mem`（#29）；横屏启动（#33） | 保持契约演进；新字段按 append-only / version 规则 |
| **A1 平台与改写** | 🟡 第一批已合入，v2 复查中 | `android-sp-safe-v1` 改写（#26）；信号/ESR 探针（#39/#53）；`plat.h` 10 个原语 + Apple/Android 实现（#52）；`entry.S` / `xstack` 平台化；#54 调用点迁移已合 main（`879096d`），真实 D2R 三模块装载 + TSD 键页逐槽通过，真实产物 iOS 包逐字节一致；窗口段预占 #105 实验，d2r 到 SDK 初始化 + DT_INIT；v2 `vm_reserve`/`vm_alias`/`vm_protect` 已进 integration（#59）；#105 已关闭（护栏取代）；其余候选：`code_map`/`thread_suspend`/`vm_query`/`fault_write` 等；`platforms/linux` 延后 |
| **A2 服务与宿主接线** | 🟡 外围完成，核心未接 | NativeAOT（#8）、OpenSSL（#9）、静态单库（#10）、AAudio（#11）、Opus/VP8（#21）、HostApi 外壳（#41/#43）、BootSpec 外壳（#31） | 真实原生核心替换 `android/native/s2a_native_stub.c`；`S2A_Init` 完整执行；语言/时区/输入/UI 收口 |
| **A3 Vulkan / WSI** | 🟡 诊断路径完成，W5 核心首批进 integration | 诊断 Presenter、旋转、surface 释放/拆除期限（#13/#15/#19）；窗口租约 generation/revision/撤销回执（#28）；HostApi display 接租约；A-W5 #65 设备/能力核心首批已合 integration | `graphics/vulkan` 共用组合入口、单 device/swapchain、Raw→Plan→Enabled→Effective、呈现资源退休、设备缓存；与窗口租约接游戏渲染 |
| **A4 导入与 Android 包** | 🟡 安装链完成，inspect/job 未接 | LibHac 导入（#17）；每游戏 APK（#24）；A0 安装事务（#27）；apk-asset（#29）；job 协议 v1 契约（`a4/job-contract`，已进 integration） | `sources.inspect`/`games.resolve` 的 Android 生产者；`GameInputManifest` 实际生成；CLI 接 job engine；system-data lock |
| **A5 设备准备/缓存** | 🟡 S1 代码闭环 + S2 出包端 | VKPB 程序记录读写、单编译 lane/窗口 pump、驱动 pipeline cache、宿主缓存 profile 判别；设备导出 Vulkan 翻译 profile，离线端按同一身份出 VKPB 宿主记录与包 manifest（`spirv-val` 自证）；运行时在 `InitializeShaderCache` 前校验并暂存导入离线包（内容根取自已安装 revision）；Apple 预读未改 | 真机 GPU/像素/停止并发；设备出包 + 装包后跨进程命中；S3 配方预热/成品池、D0 身份与事实变体 |
| **A6 第一款完整可玩** | ❌ 未开始 | — | A1–A5 接真实游戏，含 UI/声音/视频/输入/存档闭环 |
| **A7 通用能力/九款** | ❌ 未开始 | — | NRO、Applet、复杂解码、多输入、九款矩阵 |
| **A8 性能/首局优化** | ❌ 未开始 | — | 复制/分配/切遍、预编、帧节拍、驱动 tuning，A/B 与功耗 |

状态口径：

- ✅ 完成 = 契约/实现/消费者或生产者/测试已进 main，且有明确验证边界。
- 🟡 部分 = 主路径可用，但关键接缝仍缺或只在诊断/合成输入上验证。
- ❌ 未开始 = 没有可依赖的生产者/消费者。

## 3. 原阶段真机与测试证据

已在 Redmi K50 Ultra（Android 15，Adreno 730）和 OnePlus 13（Android 17，Adreno 830）
上跑过接缝验证：

- 诊断 APK：Vulkan 清屏/角标、横竖屏、HOME/恢复、surface 释放与拆除期限；A1 改写自测 6 种块 × 2 条客体线程。
- 每游戏 APK：独立 applicationId、模块随 APK、apk-asset 从 assets 原地读并映射、ReadyToPlay、横屏。
- 安装：A0 布局、`current.json` 原子切换、对象库符号链接、旧版本保留、同内容新 artifact 刷新。
- 输入：实体手柄、触屏虚拟手柄、横屏/反向横屏坐标。
- 服务：NativeAOT、OpenSSL、AAudio、Opus/VP8 解码。

原阶段设备-free 门禁（`android/test.sh`）记录：

- 13/14 CTest（memory/input/tsd/module/guest_signal/hostapi/host_android/plat/pcm_ring/wsi_lease + core-link）；`android_nativeaot_startup_roots` 在本机因 `/usr/bin/ld` BFD 2.47 assertion fail，`origin/main` 10/10，属集成新增 #86 测试的工具链问题
- Gamepad / BootContract / BootSpec / GamePack / GameInstall / App Java 编译
- 7 份契约样例 + 14 项 contract 负例 + 7 项 run manifest 负例
- `qa.sh` 自测 36 项（skip 语义、报告字段、退出码、preflight 拒绝路径、全量与失败优先）

一条命令出报告：`bash android/tests/qa.sh`（`test.sh` → APK 构建 → APK 静态校验，
报告在 `build/qa/`）。复现步骤与已知坑见 [reproduce-windows.md](reproduce-windows.md)。

真机矩阵（安装/升级/资源包激活拒绝/设备身份/输入）见 [device-matrix.md](device-matrix.md)：
Redmi K40（alioth，Android 16，4 KB 页）11 项通过，手柄与真实游戏未做。

**原接管阶段尚无证据**（不覆盖上方后续 direct 出图记录）：完整游戏启动、真实 Vulkan 游戏渲染、Mac/iOS 全量构建（A1 #52 由原生层线在 Mac 跑过门禁/冒烟，但不在本仓库当前环境）、A5 的真机 GPU/像素/停止并发、A6。A5 目前只有宿主构建与 CPU 回归：S1a/S1b 的 codec/lane/driver cache、S2 的 profile/manifest/装包器均有宿主测试，但没有设备出包、装包或跨进程命中。

## 4. 原阶段开放工作

### 4.1 集成分支

`android/integration` 当时基线（#54 修复合流点 `937d3ae5`，合到 `main@d672e1d5`；文档提交会继续前进），已合并：

- `android/status`：本文与 §2.1 状态更新；
- `a4/job-contract`：job-request / job-event v1 契约与负例；
- `runtime/plat-h-callsites`：#54 的第一批 plat 调用点迁移（已合 main `879096d`；integration 已吸收）；
- `android/plat-batch2`：#59 的 `plat.h` v2 内存/别名组（已进 integration）。
- `backends/vulkan-core`：#65 A-W5 设备/能力核心首批（integration 已吸收；Vulkan 补丁重编为 0200–0202）。

验证：`android/test.sh` 10/10 CTest + Java/契约测试全过；#54 的 Mac gate 18/18（`vawin` 因 macOS 27 窗口保留除外）、`tools/gate_ios.sh` 通过；integration 本体的 Mac gate 未单独跑。该分支在当时是**Android 开发的统一基线**：新工作从它开 feature 分支，集成分支只做合流和冲突解决；#54 等同包冒烟后走 main PR。


| 工作 | 分支/PR | 状态 | 归属/说明 |
|---|---|---|---|
| `plat.h` 第一批调用点迁移 | #54 `runtime/plat-h-callsites` | MERGED main `879096d` | Mac gate 18/18（vawin 环境项除外）、iOS 构建过；真实模块证据见 CHANGELOG |
| `plat.h` v2 内存/别名组 | #59 `android/plat-batch2` | 已进 integration | `vm_reserve`/`vm_alias`/`vm_protect`；head `96d4359f`，Android 10/10、Mac 19/19 |
| A-W5 Vulkan 设备/能力核心 | #65 `backends/vulkan-core` | 已进 integration | 设备快照/能力准入首批；后续 subgroup stage/operation 等仍在做 |
| Mac 窗口段预占 | #105 `runtime/winseg` | CLOSED，被 main 的 `libs2a_vaguard.dylib` 取代 | 段方案保留备用；护栏合并点 `f644d2a1` / 边界修补 `d638be22`；不再作为当前路线 |
| A4 job 协议 v1 契约 | `a4/job-contract@adc11266` | 已进 integration | 已做 schema/样例/负例；下一步 inspect/resolve 生产者 |
| 平台层其余原语 | 未开 | — | 第二批再开，不一次冻结 30 个候选 |
| A4 inspect/resolve/job engine | 未开 | — | 优先接 `pack/nx_unpack --inspect` 和 `GameInputManifest` |
| A5 S1a/S1b + S2 出包/装包端 | `android/shader-cache` | 已实现，宿主验证 | VKPB、单编译 lane、驱动 pipeline cache；Vulkan profile 契约、离线 manifest、ShBake VKPB 出包与运行时暂存导入；未接真机 GPU/A3 游戏渲染，S3 未开 |

已合入且不再单独跟踪：A0 #26/#32/#27/#29/#41/#43、#24、#33、#28、#39/#53、#52、#54 等。
`#1` 是 OHOS，不归 Android 主线。

## 5. 原阶段关键路径

```text
A1 #54（plat 调用点迁移）
  → A2 真实原生核心替换 stub
  → A3 graphics/vulkan 正式游戏渲染 + 窗口租约接游戏
  → A4 inspect/resolve/job engine + GameInputManifest
  → A5 shader/profile/cache
  → A6 第一款完整可玩
```

A4 的安装/APK 链已经先跑通，但 inspect/job 不能替代 A1/A2 的核心启动；A5 也不能在 A3 之前做。

## 6. 原阶段工作规则与当前维护入口

- 原接管阶段要求所有 Android 工作以 `android/integration` 为统一基线；功能分支从它开，集成分支只做合流/冲突，不把多个未合 PR 串成一条长链。
- 共享目录边界：`platforms/linux` / `graphics/vulkan` / `platforms/apple` 仍按原维护线协作；Android 侧改动不绕过它们的接口。
- 每次改 Android 代码：至少跑 `android/test.sh`；改 app/native 再跑 Docker `assembleDebug`/`verify-apk.py`。
  在 WSL / Linux 上可直接 `bash android/tests/qa.sh`，覆盖测试、构建和 APK 静态校验并留下报告；本次候选尚未执行。
- 当前可依赖事实变化时更新统一方案的验收章节，本文仅摘要引用；只有里程碑达成、回滚或验收结论变化才更新 CHANGELOG，普通提交、探针和文档整理不追加。
- 不把“合成模块映射成功”“清屏 60/120 Hz”当成游戏兼容证据。

## 7. 证据入口

- 契约与样例：[contracts/README.md](../contracts/README.md)
- 历史进展：[CHANGELOG.md](CHANGELOG.md)
- 方案与验收：[implementation-plan.md](implementation-plan.md)
- Android 构建/设备说明：[README.md](../README.md)

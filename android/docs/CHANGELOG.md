# Android 里程碑 ChangeLog

## 2026-10-30 拆线程默认开启候选（尚未验收）

- Android 游戏冷启动未带 `s2arm.threaded_renderer` 时向 JNI 传 `1`；`--ez s2arm.threaded_renderer false` 或 `--es s2arm.threaded_renderer 0` 显式关闭，`auto` 仍可显式选择。日志记录取值及 default / extra 来源。
- 依据是旧 debuggable APK `ab16651e85a9f3d3d7eae40b53c59475702848d874b622532c59ae35d8f3eb21`、单游戏 handheld、显式开关测量，不是本候选包验收。9000 热缓存 ABABAB（各 3 局）SurfaceFlinger present 中位 34.810→47.543 Hz，间隔 >16.7 ms 为 71.552%→29.744%，>100 ms 次数中位 0→3；8E ABAB（各 2 局）为 56.311→58.770 Hz、7.342%→2.936%，各局 >100 ms 均为 0。
- 两设备各有一局开启 10 分钟，PSS 采样非单调、目标日志未见 DeviceLost / ANR / fatal，9000 另有两次后台恢复；均无关闭模式长跑对照。9000 自身预热两局 >100 ms 为 3→0，不能单凭该对照判定原因。热状态、充电状态、系统缓存及采样开销有混杂；8E 温度读数恒定，trace tokenizer errors / sched skipped 非零。当前候选尚无正式 APK、完整 Android gate 或本头设备结果，不作为里程碑通过。

历史条目记录当时路线；其中 XGS/旧引擎实验不作为当前实现要求。本次合流候选尚未完成代码冲突与回归，当前事实以统一方案为准。

目标与实现方案：[Android 快速通用模式](fast-generic-v3.md)。本文件只记录已验证的里程碑及其回滚或验收结论变化，不作为开发流水账。

## 2026-10-26 拆线程 formal10 冒烟证据归档

- f6d14ac7正式APK SHA-256 `971dbb0a83d70ad7f587783c72059740b8397668278a68e4676af53ad3d00ef7`，9000 true2/2、8E true1/1完整收尾1108/644/148ms，优雅退出1.332/0.833/0.203s，无原生兜底/音频异常/Unhandled/fatal；8E清记录auto1/1留单线程并记下局单线程，优雅退出0.404s。
- 9000 false1局仍在1500ms兜底124，缓存未落盘、clean=false。闪白无视频仍未核；能耗未测、首遇未达0。该包先于本次 #479 合并，不能作为新合并HEAD设备证明。完整版本边界/历史formal7/8/9见运行时README；下方各轮条目保留各自当时状态。

## 2026-10-26 拆线程与 #479 集成合流

- 普通 merge 保留 `android/integration@39684d54` 的 SleepThread 绝对截止时刻与正常上下文 pause poll，以及拆线程的原生 WSI 期限单一权威；`MainActivity`、`AndroidVulkanRuntime` 无语义冲突。睡眠安全点的 VM ack/pause 使用原有 G/CV 合同，信号 handler 的 poll 仍为 NULL；writer 准入继续只从 WSI 读取期限，后台无限、恢复由生命周期回调重置，取得 serial 后使用自身 roster 预算。
- 合并真实 ARM64 gate 的睡眠/暂停正例与五项负控，同时保留准入续期、WSI 模型、取时锁与 Runtime 联合回归；测试入口/说明冲突均取并集，不删除双方断言。拆线程补丁从 0271 续号至 0283，以 `patch_new.sh` 重生并登记 series/改动清单；默认仍关闭。

主文档：[Android 端实施方案](implementation-plan.md)。本文件按时间追加记录 Android 的有意义进展（实现、集成、验证、回归，或方案/契约调整）。

## 维护规则

1. **只在里程碑变化时更新**：一条完整能力链达到约定验收标准、已交付能力发生回滚，或已有里程碑验收结论被新证据推翻。首款真实 direct 可玩、真实缺项补编与次局复用、整局兜底通过、未见游戏零配置通过等才是里程碑。
2. **不记零散工作**：单个函数/文件/格式补丁、普通 bug 修复、编译或探针通过、重复测试、换宿主/设备、过程排查、方案讨论和文档整理均不单独追加。细节留在提交、PR、测试报告；需要时更新 STATUS 或统一方案验收章节的当前事实。
3. 同一里程碑的相关提交合并为一条，写明结果、固定提交、实际验收及限制；未完成工作不能包装成里程碑。性能里程碑须有同口径有效测量，不能只写优化意图。
4. 历史记录保留，不补写本次清理记录。今后只有里程碑结论需要纠正时才追加更正并引用原条目，普通过程纠错不新增条目。

## 记录

### 2026-10-27 / ANDROID-Q19-LINK-GATE / 共用 C# 绑定入口的单库链接门禁

- 关联：#530、#58 Q19。共用 C# 层每新绑一个 `s2a_native` 入口，Android 单库都可能静默链不过；此前门禁不编 APK、不链单库，5 天内漏了两次（#38、#530）。
- 变更：新增 `core-link/link_symbols.py`，从 Android NativeAOT 工程的 MSBuild 闭包收集 `DllImport`/`LibraryImport`（含 `EntryPoint` 与 `const` 库名），对照 `core-link/LinkSources.cmake` 的实际原生源清单（诊断桩 + 真实 provider，含条件编译）；缺失逐条【红】点名符号与引用处并退出非零。`android/CMakeLists.txt` 改用同一份源清单，避免核对名单与构建漂移。有 NDK 29 时追加真实 `libs2arm_android.so` 探针链接（`ld.lld -z defs` 为判据），无 NDK 明确只报符号核对。
- 验证：当前 #551 头诊断/游戏两模式全绿；回放 #530 `main@9dc44df5`（旧源清单）只报 `s2a_alt_phase`、`s2a_gfx_mode` 两条；删 `s2a_handle_new` 桩、共用 C# 新绑 `s2a_q19_fake_probe` 均单条红；`tests/t_link_symbols.py` 13 项通过，`tools/test_wired_lint.py` 未接线 0。探针链接不等于完整 APK/真机，codec 第三方符号仍只在正式链接覆盖。
- 限制：平台专用 C# 按 `[SupportedOSPlatform]` 做源码级裁剪近似；不是 NativeAOT trimmer 证明。

### 2026-10-27 / ANDROID-T02-MAIN-SYMBOLS / 单库符号提供者合流

- 关联：#529、#493 T02。#529 的诊断桩与 integration 的真实 `alt.c` 和 `plat_android.c` 同时成为诊断单库输入，两个强定义冲突；合流时由真实实现提供 `s2a_alt_phase` 和 `s2a_gfx_mode`，其余诊断桩保留。
- 验证：NDK 29 ARM64 编译三个真实源文件并做 `ld.lld -r`，合流前两个符号重复报错；移除两个桩后成功，`llvm-nm` 显示各有一个强定义。此检查不等于完整单库/APK 构建；未做真机。

### 2026-10-26 / ANDROID-THREADED-AUTHORITY / 原生单一换页期限权威

- WSI租约mutex同时保护外壳生命周期回调与全部换页期限；恢复当场重置CLOCK_MONOTONIC起点，观察不重置。host只转发新progress(owner,advance)/decision(owner)，必须同版构建。
- 托管不再保存idle/start/age或重复生命周期判断；native gate删除同类缓存，读取原生期限。后台无限、前台3s+250ms/总30s+250ms、准入多1s及原false 2s语义保留；GAL看门狗仍2s+250ms。
- 完整WSI模型、R7两条旧码红/新码绿、真实ARM64 gate与Runtime联合回归；均为主机证据，未上本次真机，闪白未核实。普通merge c50ae96f保留双方文档与MainActivity接线，0271不变。
模板

```text
### YYYY-MM-DD / ANDROID-<里程碑ID> / <已达成或已撤回的能力>
- 里程碑：约定的完成标准；达成 / 回滚 / 验收结论更正
- 结果：完整链路已可依赖的行为，或被撤回的原结论
- 提交：固定 commit/PR（同一里程碑的提交合并列出）
- 验收：实际环境、命令、结果与证据入口
- 限制：未覆盖范围；不外推其他游戏、设备或前端
```

## 记录

### 2026-10-25 / ANDROID-DIRECT-VKBE-001 / 新 Vulkan 后端第一片：C2 输出 → pipeline → draw → 读回（真机）

- 新增 `android/tests/nvn_vk_be_probe.c` 与 `tools/nvn_vk_be_probe.sh`：读 C2 的
  program blob（SPIR-V + 绑定），建 4 set layout / pipeline layout / render pass / graphics
  pipeline；全屏三角形绘制后读回。**不经过 `graphics/third_party/d2r_vulkan_engine`，不读 `.xgs`**。
- 真机（Redmi 22081212C / Adreno 730）：`pipeline: created (stages=2, bindings=1)`，
  读回 `center=255,0,0,255`、4096/4096 像素非黑，`nvn-vk-be: ok`。
- 边界：这是合成程序的后端微例，不是游戏帧；尚未接 `provider_vk.c`、真实 NVN 资源和 present。
  目标链“未命中 shader → 真实事实请求 → 内存编译 → 真实绑定 → Surface 上屏”仍未闭合。

### 2026-10-25 / ANDROID-DIRECT-C5-RUNTIME-BUNDLE-001 / 真机首次运行时补编：SetShaders 现场出 `.xgs`，引擎读到并进入能力校验

- 变更：前端 `nvnProgramSetShaders` 加通用弱钩子 `dm_shader_survey`；Android 侧
  `native/nvn/shader_survey.c` 在 `debug.s2a.compile_shaders=1` 时逐阶段调 AOT
  `s2a_direct_bundle_v1`；AOT 用 `DshVk`（dmsh_xlate 翻译 + XGS 打包）写
  `<control 键>.xgs` 到引擎 shader 目录；provider 设 `S2A_SHADER_DIR`。
- 真机（暗黑 3，新 APK，显式 direct）：到 `nnMain`，survey 对单阶段程序产出多份
  `rc=0` 的 bundled（code 2560/2816/5632 等），随后引擎加载 stage 5 并
  `FATAL: Shader stage 5 requires disabled capability 10`（Float64；本局 capability
  报告 `float64=0`）。部分 compute 程序翻译抛 `NullReferenceException`。
- 结论：“缺 shader → 现场补编 → 落盘 → 引擎读取”已通；卡在 Float64（设备不支持）
  与部分 cs 翻译，未到 draw/present。

### 2026-10-25 / ANDROID-DIRECT-C2-BUNDLE-001 / 通用 XGS 打包器：编译输出 + control → 引擎 `.xgs`（离线出库与运行时现编共用）

- 关联：C2（统一翻译）、C5（引擎）、C7（真游戏）。目标仍是**通用启动器**：这条链不读游戏文件、
  不写逐款规则，任何 NVN 游戏的 code/control 都走同一份打包器。
- 变更：新增 `graphics/tools/direct/compiler/DirectBundle.cs`；编译器 CLI 增加
  `bundle --request <request.json> --out <new-dir>`。输出即 d2r 引擎的 XGS1：
  头 / 每阶段 binding 表 / 顶点输入位置 / c1 / SPIR-V。单 set 绑定映射沿用
  `direct_c2_xgs.py` 已与引擎对拍过的方案；顶点输入位置改为从 SPIR-V 的
  `Input + Location` 装饰读取（Python 参考写死 `[0]`，真实游戏 VS 会错）。
- 验证（宿主）：拿 `direct-compile-request.json` 的合成 VS/FS（control 补到 0x880）：
  - FS `.xgs` 与 `direct_c2_xgs.py` 逐字节一致；
  - VS 仅 `input_count` 不同（该 SPIR-V 没有 Input 变量，Python 的 `[0]` 是占位），其余字段一致；
  - `dotnet run -c Release`（`graphics/tools/direct/tests/compiler`）→ `direct-compiler: ok (119 checks)`。
- 限制：运行时还没把 NVN 的 `graphicsState`/`textureFacts` 接进编译请求，所以还不能在设备上
  对真游戏现编；这是下一步（运行时安全网），不是本条的完成声明。

### 2026-10-25 / ANDROID-DIRECT-C1-ATTEMPT-CLEAR-004 / 真机连续两局 direct：锁清不掉还有第二个原因——正常收局在 guest 线程里 `_exit`，join 之后的清理到不了

- 关联：C1-ATTEMPT-CLEAR-002（只移了调用位置）、003（键缓冲 64→65）。
- 根因（003 之外）：Android 的 `s2a_host_shutdown` 在 **guest 线程**里执行（`guest_main.c` 的
  `nnMain 返回` 处），末尾 `s2a_logcon_flush(); _exit(0);`。`pthread_join` 永远不返回，
  `runtime.c` 里 join 之后的 `s2a_direct_finish` 在 Android 上根本不会执行。真机现象：一局正常
  收局后锁仍在，下一局 AUTO 回落 generic。
- 变更：
  1. `runtime/src/guest_main.c` 在 `nnMain 返回`、`s2a_host_shutdown` 之前调
     `s2a_direct_finish(1)`（weak 声明：非直连 / 非 Android 构建没有这个符号）。
  2. `selection.c` 的 `s2a_direct_finish` 加一行 `held/normal/key` 诊断；`g_lock_key[65]`（003）。
- 真机证据（合成包 `0100000000ABCDEF`，APK 含 003+004；按交接 §3 先 uninstall 清掉 Mac 旧签名
  和旧锁，fresh install；`import` 目录本身也要 `chmod 0777`，否则 `readable=false`）：
  ```
  # 手动 direct 一局，正常收局：
  [s2a] direct attempt finish: held=1 normal=1 key=8ec9c8dc12f473972a637c1536c45955...
  [s2a] direct attempt lock cleared (session ended normally)
  # 紧接着两局 AUTO（不带 extra）：
  第 2 局 live:  direct provider prepared / direct activate
  第 3 局 prev:  graphics selection: direct (direct committed before relocation)
                 direct attempt finish: held=1 normal=1 → direct attempt lock cleared
  第 3 局 live:  direct provider prepared / direct activate
  ```
  即**连续两局 AUTO 都是 direct**（交接 §3 的判定条件）。真游戏（Diablo III）会在首个 shader
  bundle 处 fatal、走不到正常收局，锁按设计保留；真游戏两局要等 shader 现编接上后再验。
- 限制：用户停止 / `ExitProcess` 路径的清锁没有单独验证；SIGKILL 保留锁仍是设计。
  合成包证据不能当游戏证据。

### 2026-10-25 / ANDROID-DIRECT-C7-REAL-GAME-SESSION-001 / 真游戏（Diablo III）direct 会话跑到 nnMain 并发 NVN 命令；卡在首个 shader bundle

- 关联：C1（选择/装配）、C5（引擎/NVN 前端）、C7（真游戏）。
- 变更（本轮唯一代码改动）：`android/native/plat_android.c` 的 `s2a_direct_lookup`
  原来在 direct 模式下对**每个**未定义导入都 `abort()`（"NVN frontend lookup '%s' has no implementation"）。
  真游戏重定位时第一个撞上的是链接器符号 `__rel_dyn_end`，不是 NVN 入口，会话在 load_modules 阶段
  `fatal signal 06`。现在改为与 `runtime/src/gfxmode.c` 同语义：只有 `nvnBootstrapLoader` 接管到
  共享 NVN 前端的 `h_nvnBootstrapLoader`（weak；没编进前端才硬失败），其余名字一律回 0，
  让 loader 走正常解析（全局符号 / libc / NRO 延迟）。
- 真机证据（`192.168.31.91:5555`，Redmi 22081212C / Android 16 / Adreno 730 /
  Vulkan 1.1.128 / driver 2150002783；APK `d08ff4b4…`，真游戏 direct 包 646 文件 /
  17,187,193,745 B，资源 revision `sha256-9fca2734…`）：
  ```
  graphics selection: direct (direct committed before relocation), devices=1 queues=1 workers=0 consumers=0
  direct provider prepared: driver=Qualcomm Technologies Inc. Adreno Vulkan Driver api=1.1.128
  direct activate: engine initialized, shaders=<revision>/shaders/vulkan/direct hz=60
  direct session active: compiler bound, engine activated
  direct session status: state=1 blockers=0 error=0
  direct composition: managed GPU disabled, guest graphics go through the native direct table
  [起局] 渲染器建 → 时区/字体/系统数据 → Switch 建 → npdm/NACP → RomFS → 存档 → 输入泵
  Android services start: v2=1 rc=0 state=2 error=0
  [s2a] >>> nnMain
  direct engine: NVN clear-value attachment input=0 nvn=0x29 view=0x29 vk=97 ...
  direct engine: FATAL: Missing genuine shader bundle
    …/revisions/sha256-9fca2734…/shaders/vulkan/direct/7670c089f9511a4f.xgs
  ```
  即：**真游戏在 direct 下选上、引擎激活、HLE 起全、服务 READY、跑到 nnMain，并把真实 NVN
  命令发到 native 引擎**；第一个缺失的着色器 bundle 键是 `7670c089f9511a4f`。
- 资源包安装：设备上已有旧 revision（`sha256-bed062a9…`），新包安装时
  `stored 0.0 MiB, shared 16350.6 MiB with installed versions`（同内容对象共享），旧版本保留。
  另外验证了 APK 升级的 `refreshArtifact` 快路径：内容根不变、只换 APK 时，import 只需要
  manifest.json / index.tsv / game-build-artifact.json / ctl/control.nacp 四个小文件，
  不需要重推 16 GB；本次 APK 重建后就是这样刷新的。
- 限制：**没有一帧画面**；present 仍是 `present_without_wsi`（明确返回 -1）。
  下一步是设备上的着色器现编（`dm_shader_miss`/程序级 bundle 生成）：引擎要求
  `<control-sha256 前 16 位>.xgs`，当前只有合成 C2 程序会生成；真实游戏的
  code/control → C2 → `.xgs` 还没有接。attempt 锁的根因修复（上一条）已由宿主回归证明，
  真机连续两局仍需在能正常收局的会话上复验。

### 2026-10-25 / ANDROID-DIRECT-C1-ATTEMPT-CLEAR-003 / attempt 锁清不掉的根因：键缓冲少 1 字节（63 字符被 hex_lower_64 直接拒）

- 关联：C1-ATTEMPT-CLEAR-002（上一轮只把调用移到 `pthread_join` 之后，没有解决）。
- 根因：commit 尾部 `snprintf(g_lock_key, sizeof g_lock_key, "%s", key)`；`key` 是 65 字节
  （64 hex + NUL），`g_lock_key` 只有 64 → 截成 63 字符。`s2a_direct_attempt_clear` 第一步
  `hex_lower_64(implementation_key)` 就拒绝（`S2A_ATTEMPT_ARGUMENT`），于是 attempt 文件
  （写在完整 64 hex 键的目录下）永远留着；下一局 AUTO 读到遗留锁 → `generic (previous direct attempt
  did not end normally)`。这就是"连跑两局第二局必回落"的真正原因，不是调用位置。
- 变更：`g_lock_key[65]`；`tests/direct_selection_test.c` 增加回归：commit 后
  `s2a_direct_finish(1)` 必须清掉 pending，重复调用 / 未持锁调用都是 no-op。
- 验证（Linux 宿主）：
  - `cmake --build build/android-host-tests --target direct_selection_test && ./build/android-host-tests/direct_selection_test`
    → `[s2a] direct attempt lock cleared (session ended normally)` / `direct-selection: ok`。
  - A/B：把缓冲改回 64 并关闭 `-Werror=format-truncation` 重编运行 →
    `FAIL finish clears attempt lock: rc=-1 want=0`、`FAIL finish twice is a no-op`、`2 FAILURES`，
    证明用例确实抓得住这个 bug（不是只在修好后才通过）。
  - `python3 android/tests/direct_pack_test.py` 6/6；`filecopy_test.py` ok。
- 限制：真机连续两局尚未复验（16 GB 资源包推送中）；`android/test.sh` 的 native 子集仍在
  `runtime/wsi_probe.cpp` 的 `android/log.h` 处失败（宿主 CMake 缺 NDK include，交接 §7 已记），与本次改动无关。

### 2026-10-25 / ANDROID-DIRECT-PACK-COW-001 / 出包链路在 CoW 文件系统上共享数据块：17 GB 真游戏包不再复制第二份

- 关联：C7 出包/资源包工具链。
- 变更：
  1. 新增 `tools/filecopy.py`：复制前先试 Linux `FICLONE`（btrfs/XFS；APFS/不支持的文件系统自动回退
     `shutil.copy2`）。`make_pack.write_pack` 在克隆成功时只读源算哈希（内容与普通复制一致），
     `game_apk.py --resources` 同样用 `copy_file`。
  2. `native/direct/json.c` 的 `number/is_unsigned/uvalue` 显式初始化。`parse_number` 成功时三项都写，
     这里只是消除 GCC 15 `-O1 -Werror=maybe-uninitialized` 的误报；调用方仍然只在返回 0 后读。
- 提交：本条。
- 验证（Linux btrfs，`cp --reflink=always` 可用）：
  - `python3 android/tools/make_pack.py … --root <暗黑3 解包根>` 产出 646 文件 / 17,187,193,745 B，
    构建前后 `df /home` 可用空间 9.8 GB → 9.7 GB（只多了元数据），说明没有复制第二份 ROM。
  - `game_apk.py --resources` 产出的 639 文件资源包同样不增数据块。
  - `python3 android/tests/direct_pack_test.py` 6/6 OK；`filecopy_test.py` ok（tmpfs 上
    `cow=False`，走回退路径也通过）；`direct_c2_xgs_test.py` ok。
- 限制：只有源/目标在同一支持 CoW 的文件系统时才共享数据块；跨盘、tmpfs、网络盘仍按普通复制，
  行为与旧版一致。本机 `/tmp` 是 tmpfs，测试里看到的是回退路径。

### 2026-10-25 / ANDROID-DIRECT-C1-ATTEMPT-CLEAR-002 / attempt 锁改成在 guest 线程 join 之后、shutdown 日志之前清（未实机复验）

- 关联：上一条 C1-DIRECT-SESSION-FULL 的"未证实：attempt 锁清理"。
- 变更：`s2a_direct_finish(...)` 的调用从 `run_v2` 的返回处**移到 `run_common` 里 `pthread_join` 之后、
  `failed(...)` 之前**。原因：原来那个位置在会话 shutdown 日志收尾之后，行可能根本没进会话日志，
  也就无法从日志判断清理是否发生；现在它在收尾之前，正常返回/用户停止与异常在这里已经分得清。
- 判定标准（下一轮在 Linux 上先跑这个）：连续两局都应是
  `graphics selection: direct (direct committed before relocation)`；
  若第二局仍是 `generic (previous direct attempt did not end normally)`，说明清锁没生效，
  直接查 `selection.c` 的 `g_lock_held` 是否被 commit 尾部置位、以及 `s2a_direct_attempt_clear` 的返回码。
- 本轮状态：改动已编译通过（`BUILD SUCCESSFUL`），**尚未在设备上复验**（真机测试在收尾前中断）。

### 2026-10-25 / ANDROID-DIRECT-C1-DIRECT-SESSION-FULL-001 / direct 会话第一次完整跑完一局：services READY（v2 rc=0 state=2）+ nnMain 返回 + 干净收尾

- 关联：C1（启动事务）、C5（direct 组合）。本轮把"合成包跑不起来"的两个内容级障碍清掉了。
- 变更：
  1. `tools/synthetic_npdm.py` 改成**以 Ryujinx 自带的 `compat/tree/src/Ryujinx.HLE/Homebrew.npdm`
     为模板**（真实合法 NPDM：META+ACID+ACI0 齐全），只改三处：META 地址空间类型位（+0x0C = 6，64-bit）、
     ACI0 程序号（+0x10）、ACID 的 ProgramIdMin/Max。之前手工拼的 NPDM 被 LibHac 判
     `ResultLoaderInvalidMeta (2009-0004)`。
  2. `native/direct/selection.c` 新增 `s2a_direct_finish(int normal)`：commit 后记住 (state_dir, key)，
     会话正常收尾（guest 返回 / 用户停止）时清 attempt 锁，崩溃/被杀保留锁。`runtime.c` 的
     `s2a_android_runtime_run_v2` 在 `run_common` 返回后调用它。
- 真机证据（4c6229ab / 22081212C / Android 16，per-game APK + 合成 direct 包）：
  ```
  graphics selection: direct (direct committed before relocation), devices=1 queues=1
  direct session active: compiler bound, engine activated
  direct session status: state=1 blockers=0 error=0
  direct composition: managed GPU disabled, guest graphics go through the native direct table
  [起局] 服务：渲染器建 → 时区/字体/系统数据 → Switch 建 → npdm/NACP 读（LibHac 通过）→ 存档 → HID
  Android services start: v2=1 rc=0 state=2 error=0
  >>> nnosInitialize / nninitInitializeSdkModule / nninitStartup / nnMain
  nnMain 返回 → 收到 nnMain 返回：优雅退出 → direct session closed: stop=0 destroy=0
  句柄表峰值 39 格、未解析导入 0、系统调用 0
  ```
  即：**direct 会话在没有任何托管 GPU 的情况下，把 HLE 起全、服务置 READY、跑到 guest 的 nnMain 返回、
  再干净收尾**。这是"合成内容上的完整 direct 一局"，不是游戏、也没有出图。
- 未证实：attempt 锁清理。上一版实现后紧接着的一局仍落到 generic（"previous direct attempt did not end
  normally"），要么 `s2a_direct_finish` 没被走到（`g_lock_held` 为 0），要么清锁没生效；下一轮先查这一条，
  它决定 direct 能不能连续多局。

### 2026-10-25 / ANDROID-DIRECT-C5-DIRECT-RENDERER-001 / 托管侧 direct 渲染器 + 时区系统数据：会话在**没有 generic GPU** 的情况下推进到 LibHac 校验 NPDM

- 关联：C5（direct 组合）、C1（会话生命周期）。
- 变更：
  - `core-runtime/DirectRenderer.cs`（新）：`IRenderer` 的 direct 实现。能正确"什么都不做"的成员
    （`Dispose`/`Initialize`/`PreFrame`/`UpdateCounters`/`WaitSync`/`CreateSync`/`ResetCounter`/
    `Screenshot`/`SetInterruptAction`/`BackgroundContextAction`）明确空实现；真正要 GPU 资源或出图的
    （`Pipeline`/`Window`/`CreateBuffer`/`CreateProgram`/`CreateTexture`/`GetCapabilities`…）一律
    `NotSupportedException` 并带成员名；`RunLoop` 明确不跑 Ryujinx 的 GPU 模拟循环（guest 图形归 native）。
  - `AndroidGameRuntime`：direct 分支的 `RendererFactory` 换成这个渲染器（不再"一调就抛"）。
  - `tools/synthetic_systemdata.py`（新）：按 `Host.cs` 的 `GenerateTimeZoneData` 口径，从宿主 IANA 库
    给合成包补 `systemdata/010000000000080E/`（598 个区；zoneinfo 文件取 TZif 第二段）。
- 真机证据（4c6229ab / 22081212C / Android 16，合成 direct 包）：
  ```
  direct activate: engine initialized, shaders=…/shaders/vulkan/direct hz=60
  [s2a] direct composition: managed GPU disabled, guest graphics go through the native direct table
  [起局] 服务：渲染器建 +1098.7 ms、时区 / 字体 / 系统数据 +1099.2 ms
  Android services start failed (stage=Initialize, error=-6):
      LibHac.Common.HorizonResultException: ResultLoaderInvalidMeta (2009-0004)
  [s2a] direct session closed: stop=0 destroy=0
  ```
  即：direct 会话在**没有任何托管 GPU** 的情况下走过了渲染器构造、时区/字体/系统数据，最后卡在
  **LibHac 自己校验合成 NPDM 的 meta**（内容问题，不是 direct 问题）。
- 顺带修的真坑（已记 `docs/坑记录.md`）：删掉 `build/android-cs` 会同时删掉 `jniLibs/arm64-v8a/libssl.so`，
  而 `openssl/build.sh` 才负责把它从缓存拷回来；少了它 .NET 的 crypto 在第一次用到时
  `abort()`（日志是 `No usable version of libssl was found` + `Android fatal signal 06`）。
- 限制：仍然没有 direct 出图；合成 NSO 一返回就会收局。下一步要么把合成 NPDM 做到 LibHac 认可，
  要么等真游戏 dump（真 NPDM 天然合法）。

### 2026-10-25 / ANDROID-DIRECT-C1-DIRECT-COMPOSE-001 / direct composition 分支接进 StartCore：managed GPU 关掉，但 HLE 初始化要求渲染器

- 关联：C1/C5（direct 会话要能"不建 generic GPU"跑 HLE）。
- 变更（`core-runtime/AndroidGameRuntime.cs`）：
  - `StartCore(request, result, DirectSession direct = null)`：direct 非空时**不创建 `AndroidVulkanRuntime`**，
    `Exports.RendererFactory` 换成"直接抛异常并写明原因"的桩（不让 HLE 拿到 null 后空指针）；
    `AfterBoot`/`ThrowIfFailed` 全部对 `_gpu` 做空安全；`StopGpu()` 里按契约
    `RequestStop` → `Destroy` 关掉 native direct 会话（引擎在 destroy 里关）。
  - `StartV2` 的 direct 分支：bind → activate → 直接进 `StartCore(..., session)`（不再"激活完就收掉"）。
  - `V1Request()` 抽出：direct/generic 用同一份字段构造 v1 请求，避免两处漂移。
- 真机证据（4c6229ab / 22081212C / Android 16）：
  ```
  direct engine: NVN caps api=1.1.128 driver=2150002783 …
  direct activate: engine initialized, shaders=…/shaders/vulkan/direct hz=60
  [s2a] direct composition: managed GPU disabled, guest graphics go through the native direct table
  Android services start failed (stage=Initialize, error=-6):
      System.InvalidOperationException: direct mode: the managed renderer factory must not be used
      (one graphics backend per session)
  [s2a] direct session closed: stop=0 destroy=0
  ```
- 结论（下一步的硬约束）：`services/S2A.Services/Exports.cs` 在 `Initialize` 时**要求渲染器工厂非空**
  （`if (RendererFactory == null …) throw "Game renderer, worker, stop and audio callbacks are required"`），
  而 Ryujinx 树上只有 `VulkanRenderer` 与包装它的 `ThreadedRenderer`，没有 null/stub 后端。
  第一版试过"给服务层加 `RequireRenderer=false` 跳过这条要求"，真机上**没用**：HLE 在 `Initialize` 里
  就**真的调用了工厂**（不是只做非空检查），仍然抛 "the managed renderer factory must not be used"；
  该开关已回滚（不留未验证的旁路）。所以 direct 会话要留在 ACTIVE 继续跑 HLE 只有一条路：
  **实现一个 direct 渲染器**（`IRenderer` 的直连实现：不建第二套 GPU，把真正要出图的调用交给 native 表）。
- 限制：direct 会话在真机上仍然只到"引擎激活 → 关不掉的渲染器要求 → 干净收尾"，**没有一帧 direct 画面**。

### 2026-10-25 / ANDROID-DIRECT-C1-DIRECT-ACTIVATE-001 / direct 会话在真机上真的激活了引擎：bind compiler → activate → status(ACTIVE) → 干净收尾

- 关联：C1（provider 生命周期）、C2（编译 provider 绑定）。这是 activate 第一次被**真正的调用者**执行。
- 变更：
  - `native/direct/compiler_bind.c`（新）+ `s2a_direct.h` 的 `s2a_direct_bound_compile()`：实现
    `s2a_direct_bind_compiler_v1(context, compile)` —— 最多 4 个 context 登记，重复绑定覆盖同一个 context，
    表满返回 `INTERNAL`（不覆盖别人的会话）；native 侧以后要"现场编一条 guest 着色器"就取这个指针。
  - `core-runtime/AndroidGameRuntime.cs` 的 direct 分支：表校验 → `DirectSession` → `BindCompiler`
    （AOT 的 `s2a_direct_compile_v1` 指针）→ `Activate` → 打状态；因为"不建 generic GPU 也能跑 HLE"
    这一组合还没实现，随后 `RequestStop`+`Destroy` **把引擎干净收掉**，再明确返回
    `ServiceError.Provider`（不静默降级、不泄漏 owner）。
- 真机证据（4c6229ab / 22081212C / Android 16，per-game APK + 合成 direct 包）：
  ```
  direct provider prepared: driver=Qualcomm Technologies Inc. Adreno Vulkan Driver api=1.1.128
  direct engine: NVN caps api=1.1.128 driver=2150002783 maxUBdyn=32 … maxBoundSets=7
  direct activate: engine initialized, shaders=…/revisions/sha256-4e355f8b…/shaders/vulkan/direct hz=60
  prev| [s2a] direct session active: compiler bound, engine activated
  prev| [s2a] direct session status: state=1 blockers=0 error=0
  prev| [s2a] direct composition not implemented in this build: bind=ok activate=ok stop=0 destroy=0
  prev| [s2a] Android services start: v2=1 rc=-4 state=0 error=0
  ```
  （`state=1` = 契约的 ACTIVE；`stop=0 destroy=0` = 两步都成功。）
- 顺带修的两个构建坑（已记进坑记录）：
  1. 删 `build/android-cs` 会让 CMake 配置阶段找不到 `static/link.txt` 而失败 —— 先跑
     `android/cs/build.sh` 再构建；
  2. 缓存里的 dotnet 可能是 Linux ELF（"cannot execute binary file"），macOS 上要
     `S2A_ANDROID_DOTNET=$(which dotnet)`。
- 限制：**仍然没有 direct 出图**。下一步就是"direct 模式下不创建 generic GPU 也能跑 HLE"，
  以及把 present 接到游戏窗口 lease。

### 2026-10-25 / ANDROID-DIRECT-C1-SYNTH-SDK-001 / 合成模块导出 7 个 SDK 入口：会话第一次走到 managed `StartV2`，direct 被明确拒绝

- 关联：C1（direct 启动事务）；上一条 -106 的直接修复。
- 变更：
  - `tools/selftest_nso.py` 新增 `--sdk-entries`：在同一个合成模块里加 `.dynsym`/`.dynstr`（MOD0 的
    dynamic 表放 `ro+0x300`，符号表 `0x340`、字符串表 `0x400`，避开基类模块已经写好的 eh_frame_hdr
    `0x100` 与 FDE `0x200`——它们是相对编码，不能搬），导出运行时要求的 7 个入口
    （`_init_libc0`/`nnosInitialize`/`_init_libc1`/`nninitInitializeSdkModule`/`nninitStartup`/`_init_libc2`
    各一条 `ret`，`nnMain` 用 `mov w0,#0; ret`）。默认输出与原来逐字节一致（自测不受影响）。
  - `tools/make_pack.py`：`S2A_SYNTHETIC_SDK=1` 时给 `selftest_nso.py` 传 `--sdk-entries`。
  - `runtime.c`：`g_services_attempted` 改成**只有服务真的 Ready 之后**才置位 —— 被拒的起局没有 owner，
    不该在收局时报"清理未完成"。
- 真机（4c6229ab / 22081212C / Android 16，per-game APK + 合成 direct 包 + 合法 NPDM）：
  - `graphics selection: direct (direct committed before relocation), devices=1 queues=1`
  - `direct services rejected: native Vulkan direct composition is not implemented in this build`
  - `Android services start: v2=1 rc=-4 state=0 error=0` → `Game runtime returned: -105`
  - 收局不再报"清理未完成"（因为服务没 Ready）。
- 顺带发现：同一份合成包走 **generic** 时，managed 侧会失败在
  `Session time zone is absent from game system data: Asia/Shanghai`（合成包没有 systemdata/timezone），
  与 direct 无关；direct 分支在它之前就被闸门拒绝了。
- 限制：仍然没有 direct 出图。下一步是把这个闸门换成真实实现：`DirectSession`（bind compiler → activate）
  再在没有 generic GPU 的前提下跑 HLE 的 CPU 部分。

### 2026-10-25 / ANDROID-DIRECT-C1-SDK-ENTRY-001 / 合成会话被 -106（缺 SDK 入口）挡住：direct 已 commit，但 managed 侧仍启动不了

- 关联：C1（direct 启动事务）；上一条补了 NPDM 之后的下一步。
- 现象（真机，4c6229ab / 22081212C / Android 16，per-game APK + 合成 direct 资源包）：
  `graphics selection: direct (direct committed before relocation), devices=1 queues=1` 之后立刻
  `Game runtime returned: -106; ending this process`，会话日志写的是
  `Android services尚未调用Start，无managed cleanup待验` —— 也就是从没走到 `services start`。
- 根因：`-106 = S2A_RUNTIME_SDK`。runtime 在执行任何 SDK 指令前要求 7 个入口都存在：
  `_init_libc0`、`nnosInitialize`、`_init_libc1`、`nninitInitializeSdkModule`、`nninitStartup`、
  `_init_libc2`、`nnMain`（`runtime.c` 的 sdk[] 循环）。`tools/selftest_nso.py` 造的合成 NSO
  只有 MOD0/eh_frame，**没有任何导出符号**，所以第一个 `_init_libc0` 就查不到。
- 变更：`runtime.c` 在调用 `s2a_android_services_start(_v2)` 之后打一行
  `Android services start: v2=%d rc=%d state=%u error=%d` —— 以后再出问题能直接看出是"没调到"还是"调了失败"。
- 下一步（明确）：给合成 NSO 加导出表（`.dynsym`/`.dynstr`/`.hash` + MOD0 指向它），把这 7 个入口都导出
  （各自 `ret` 的桩 + 一个返回 0 的 `nnMain`）。这样会话才会走到 `services start` →
  managed `StartV2` → 当前的 direct 闸门（`ServiceError.Provider`），之后才是接 `DirectSession`。
- 限制：本轮没有再新增"通过"的东西；direct 仍然没有出图。

### 2026-10-25 / ANDROID-DIRECT-C1-SYNTH-NPDM-001 / 合成包补合法 NPDM：会话跑到"优雅退出"，managed 侧仍没被调用

- 关联：让 direct 链路探针的会话能越过 NPDM 解析（此前合成包没有 ACI0，一开局就 FATAL）。
- 变更：新增 `android/tools/synthetic_npdm.py`（合成包专用，不是游戏数据）：
  `META`（+0x0C 地址空间类型 3、+0x0E 优先级、+0x1C 主线程栈、+0x70/+0x74 ACI0 偏移/大小）+
  `ACI0`（+0x10 程序号取自 control.nacp、+0x30/+0x34 内核能力、能力里一项 **ThreadInfo**：
  低 3 位 `0b111`，位 4–9 最高优先级、10–15 最低、16–23 最小核、24–31 最大核），
  改完重写 index.tsv / manifest.json / game-build-artifact.json。
- 真机（4c6229ab / 22081212C / Android 16，per-game APK + 合成 direct 资源包）逐级现象：
  1. 无 ACI0 → `FATAL NPDM 里没有 ACI0 程序号`；
  2. 有 ACI0、无 ThreadInfo → `FATAL NPDM 内核能力里没有 ThreadInfo 项（核 / 优先级掩码）`；
  3. 两项都补 → 模块加载/重定位正常、`未解析导入：0 个`、`系统调用计数：0 种`、
     `收到 game runtime returned：优雅退出`、`优雅退出完成（0.049 秒）`。
- 但同一份日志末尾是 `Android services尚未调用Start，无managed cleanup待验`：合成 NSO 直接返回，
  **managed 运行时没有被启动**，所以 `StartV2`/`activate` 仍没有被执行到 —— activate 依然没有设备证据。
- 下一步：让合成 NSO 真的走 `nnosInitialize`/`nninitStartup`（汇编级活，才能让 managed 侧启动），
  或等玩家 dump 出真游戏的 direct 包。
- 旁证：真游戏 `org.s2arm.game.t01001b300b9be000`（Diablo III）仍在 generic 下正常跑
  （`Game startup accepted: 01001B300B9BE000 … consoleMode docked`，帧间隔 600 帧 avg 16.67–21.53 ms）。

### 2026-10-25 / ANDROID-DIRECT-C1-MANAGED-SESSION-001 / managed 侧 direct 会话生命周期 + 真机 generic 基线（真游戏在跑）

- 关联：C1（provider 生命周期）。**更正上一条的错误结论**：`core-runtime` 里其实**有** DirectAbi 消费者
  （`android/core-runtime/DirectAbi.cs` + `AndroidGameRuntime.StartV2`），上一轮 grep 用错了路径。
  真实情况是：`StartV2` 对 direct 表做完整校验后**明确拒绝**并返回 `ServiceError.Provider`
  （"native Vulkan direct composition is not implemented in this build"），从来不调 `activate`。
- 变更：
  - 新增 `android/core-runtime/DirectSession.cs`：managed 侧 direct 会话生命周期，顺序固定
    bind compiler → activate → query → request_stop → destroy；`activate` 之前没 bind、重复 activate、
    destroy 之后再动 → 一律参数/停止错误；负码不当成功；destroy 幂等；编译入口由调用方传入
    （生产是 AOT 的 `s2a_direct_compile_v1` 指针，测试可注入假 binder），因此这个类只依赖 DirectAbi。
  - `direct-abi-tests` 覆盖会话生命周期：用假 native 表（`[UnmanagedCallersOnly]` 假函数指针）验证
    顺序、重复调用、activate 失败（-7 驱动错误）不当成功、destroy 幂等。
- 真机基线（2026-10-25 17:47，设备 4c6229ab / 22081212C / Android 16）：
  - 装上并跑着的真实游戏 `org.s2arm.game.t01001b300b9be000`（Diablo III）：
    `Game startup accepted: 01001B300B9BE000 session … consoleMode docked`，前台窗口是它，
    截图非黑（53/64 采样点有内容），`帧间隔 600 帧：avg 20.30 ms、p50 16.87、p95 32.56、p99 36.41`，
    `GPU 循环 5s：… present 547（300）`。这是 **generic** 路径的基线，不是 direct。
  - 该游戏的资源包在 App 私有目录，本机 adb `run-as` 被 SELinux 拒（targetSdk 36），**宿主读不到**；
    要给它做 direct 产物，需要玩家自己的 dump 重新出包（本机目前没有）。
- 限制：DirectSession 只是 managed 侧的胶水，还没接进 `StartV2`；真游戏仍然只能 generic。

### 2026-10-25 / ANDROID-DIRECT-C1-PROVIDER-ACTIVATE-001 / provider 的 activate 接了引擎（同一个 device/queue），但还没被真机走到

- 关联：C1（provider 生命周期）、C5（引擎会话）。
- 状态：**代码完成，设备未验证，而且现在还没有调用者**。activate 现在真的用候选 device/queue 初始化
  d2r 引擎；但两条调用路径都不通：
  ① 会话走不到 managed 侧——合成包的 `main.npdm` 没有 ACI0，在模块加载那步就 FATAL；
  ② managed 侧的 `StartV2` 对 direct 表校验后**明确拒绝**（`ServiceError.Provider`：
  "native Vulkan direct composition is not implemented in this build"），不调 activate。
  （更正：`core-runtime` 里有 DirectAbi 消费者，见下一条 C1-MANAGED-SESSION-001。）
- 变更：
  - `native/direct/provider_vk.h`（新）：`s2a_direct_vk_context {game_data_dir, state_dir, display_hz, lease_api}`
    + 弱符号 `s2a_direct_provider_vk_configure()`。
  - `native/runtime/runtime.c`：选择前把 revision 根/状态目录/lease_api 交给 provider（display_hz 记 0，
    外壳还没把刷新率带进来）。
  - `native/direct/provider_vk.c`：`activate()` 用候选 device/queue 调 `dm_vk_initialize`，
    着色器目录取 `<revision>/shaders/vulkan/direct`；`request_stop()`/`destroy()` 先 `xbg_game_shutdown()`
    再销毁 device；present 回调在窗口 lease 没接过来时**明确失败并写原因**（引擎会因此 fatal，不静默丢帧）。
- 验证：`-Ps2arm.nativeMode=game` + 引擎开关构建通过；设备上 direct 仍能 commit
  （`graphics selection: direct (direct committed before relocation), devices=1 queues=1`），
  但会话日志里没有 `direct activate:` —— 被 NPDM 的 ACI0 缺失挡在 managed 侧之前。
- 下一步（明确）：
  1. `core-runtime` 补 DirectAbi 消费者：启动时按 `services.graphics` 调 `activate`、收局前 `request_stop`/`destroy`，
     并把 `s2a_direct_bind_compiler_v1` 接上（否则 direct 会话里的着色器编译没有落点）；
  2. 合成包补一个带 ACI0 的 NPDM（`META` +0x0C 地址空间类型、+0x70 ACI0 偏移、ACI0 +0x10 程序号），
     让会话能走到 managed 侧；
  3. 有这两条之后才能在真机上验 activate/引擎初始化，再谈 present/WSI。

### 2026-10-25 / ANDROID-DIRECT-C1-PROVIDER-COMMIT-001 / 生产 provider 上真机：direct 真的 commit（写 attempt 锁），下一局回 generic

- 关联：C1（模式选择事务 + 故障锁）、C7（启动事务）。
- 状态：部分完成。**commit 与"故障下局 generic"已在真机跑通**；activate（把引擎接到游戏 WSI/present）
  仍是明确 UNSUPPORTED，所以还没有 direct 出图。
- 变更：
  - 新增 `native/direct/provider_vk.c`（只在引擎开关构建设里编）：`available()`=1（本文件参与编译即代表
    引擎+前端+Vulkan owner 都在）、`prepare()` 用 `s2a_vk_device_create` 真建 device/queue 并填表
    （activate/request_stop/query/poll/destroy，计数 devices=1 queues=1）、`activate()` 因为还没有
    "游戏 WSI/present 归属"**明确返回 `S2A_DIRECT_RES_UNSUPPORTED` 并写明原因**（不静默成功）、
    `destroy()` 释放 device；并补齐 runtime 的弱符号 `s2a_direct_frontend_ready()`
    （只有共享前端真的链接进来才为真——用 `h_nvnBootstrapLoader("nvnDeviceGetInteger")` 实测）。
  - `native/direct/attempt.c`：**真 bug 修复**。原来 `ensure_dir` 从 `/` 逐级 `lstat`，
    Android 上 `/data/user/0` 这类系统前缀对 App 是链接/受保护视图，被判成"不是目录" →
    `mkdir` 前就返回 `S2A_ATTEMPT_IO (errno=20 ENOTDIR)`，于是 `attempt` 锁永远写不下去、
    AUTO 永远退回 generic。改成 `stat`（跟随链接，只拒绝"存在但不是目录"），并加
    `s2a_direct_attempt_last_errno()` 与失败路径打印（只在失败时输出）。
  - `native/direct/selection.c`：锁写失败的原因里带上错误码与 errno；`runtime.c` 在选择前打印
    state dir（定位路径问题用）。
  - 新增 `tools/direct_provider_commit_probe.sh`：全新安装 per-game APK（清锁）→ 装资源包 →
    两局 A/B：第一局断言 `graphics selection: direct (direct committed before relocation), devices=1 queues=1`，
    第二局断言 `generic (previous direct attempt did not end normally)`。
- 真机证据（设备 `4c6229ab` / 22081212C / Android 16，per-game APK + 合成 direct 资源包）：
  - `direct provider prepared: driver=Qualcomm Technologies Inc. Adreno Vulkan Driver api=1.1.128 profile=sha256-cccc…`
  - `prev| [s2a] graphics selection: direct (direct committed before relocation), devices=1 queues=1 workers=0 consumers=0`
  - `prev| [s2a] graphics selection: generic (previous direct attempt did not end normally), devices=0 queues=0 workers=0 consumers=0`
  - → `C1 direct commit + attempt lock recovery: ok (22081212C)`
- 限制：
  - **没有出图**：activate 未接游戏 WSI/present，调用即 UNSUPPORTED；direct 会话在 commit 后仍会因为
    合成包的 `main.npdm` 没有 ACI0 而 FATAL（不是 direct 的问题，但也不能当游戏证据）。
  - provider 取 descriptor 的**第一个 profile** 作为 effective profile hash，多 profile 选优未做。
  - 锁只能靠"正常收局"清除；合成包永远不会正常收局，所以探针靠全新安装（清数据）复位。

### 2026-10-25 / ANDROID-DIRECT-C5-GAME-ENGINE-001 / d2r 引擎 + 共享 NVN 前端编进 per-game APK，设备内 init/shutdown 通过

- 关联：C5（引擎路径），也是 C1 "真实 Vulkan provider" 的前置（引擎必须先在游戏运行时里可用）。
- 状态：部分完成。引擎与共享前端已经和**游戏运行时**同编一个 DSO 并在设备上初始化成功；
  **还没有 provider**（`s2a_direct_provider_default` 仍是空），所以 direct 仍然选不上。
- 变更：
  - `native/nvn/vk_engine_host_shim.c` 全部宿主桩改成 `__attribute__((weak))`：与游戏运行时同编时，
    运行时自己的强定义（`module_of`、`s2a_core_block_begin/end` 等）优先；诊断包仍用这些桩。
    加引擎开关 + game 模式前，链接报的重复符号正好是这三个（`module_of`/`s2a_core_block_begin`/
    `s2a_core_block_end`），改弱之后一次链接通过。
  - `tools/ndk_toolchain.sh`：`s2a_ndk_host_bin()` 之前返回 `$ndk/prebuilt/<tag>/bin`（不存在），
    改成 `$ndk/toolchains/llvm/prebuilt/<tag>/bin`；新增脚本第一次用到它就暴露了。
  - 新增 `tools/direct_vk_engine_game_probe.sh`：`S2A_GAME_DIR=<game_apk.py 输出>` 构建
    （`S2ARM_ANDROID_VK_ENGINE=1` + `-Ps2arm.nativeMode=game`）→ 断言 APK 的 `.so` 里同时有引擎
    （`dm_vk_initialize`）与共享前端（`hvnDeviceGetInteger`/`h_nvnBootstrapLoader`）符号 →
    装机跑 `--ez s2arm.engine_probe true` → 断言 `init rc=0`/`shutdown rc=0`/`result=ok`。
- 验证（设备 `4c6229ab` / 22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - `engine+frontend symbols: ok`（52,252,549 B 的 per-game APK，含游戏运行时 + 引擎 + 前端）
  - `engine: NVN caps api=1.1.128 driver=2150002783 maxUBdyn=32 …`
  - `engine apk probe: init rc=0 why= shutdown rc=0 refresh=120.000 shaders=/data/user/0/org.s2arm.game.t0100000000abcdef/files/engine-shaders`
  - `engine apk probe: result=ok` → `C5 engine in per-game APK: ok (22081212C)`
- 限制：
  - 只证明"同编 + 能初始化/关闭"；没有任何 NVN 对象、draw、present 走游戏运行时的路径，
    也没有 provider（`s2a_direct_provider_default()` 仍是空实现），direct 仍选不上。
  - 共享前端的宿主桩是弱符号：真跑游戏时，若运行时缺少某个钩子（如 `dm_shader_miss`），会**静默退化成桩**
    而不是报红——接 provider 前要逐个核对（已列为下一步）。
  - per-game APK 因此从 48.8 MB 涨到 52.3 MB（引擎/前端/引擎资源）。

### 2026-10-25 / ANDROID-DIRECT-C7-LAUNCH-001 / direct 产物真机启动事务：AUTO→generic（原因可查）、手动 direct 不降级

- 关联：C1（relocation 前唯一一次图形模式选择）与 C7（首装后启动）。
- 状态：部分完成。**启动事务的两种模式都在真机上验证**；direct 运行时仍不存在，所以没有任何
  direct 出图/首用编译/缓存/游戏证据，C1/C7 都不算通过。
- 做法（`tools/direct_pack_launch_probe.sh`，配 `S2A_PACK`/`S2A_APK`）：
  1. `game_apk.py --resources` 从**当前已安装的** per-game APK 重新生成资源包（artifact.apk.sha256
     绑定已安装 APK，任何重建都必须重新生成，否则启动时报 `this installed APK does not match
     artifact.apk.sha256`）；
  2. push 到 `Android/data/<pkg>/files/import/` 并 `chmod -R 0777`（scoped storage 下 adb 建的子目录
     对 App 不可读：`manifest=false listable=false`，见坑记录）；
  3. 不带 extra 启动（AUTO）→ 断言 `Game startup accepted`；再启动一次读上一局会话日志，
     断言 `[s2a] graphics selection: generic (direct backend not available), devices=0 queues=0 workers=0 consumers=0`；
  4. 带 `--es s2arm.graphics_mode direct` 启动 → 断言 `Game runtime returned: -114` 与
     `HostApi stop requested: unrecoverable error (direct requested but backend is not available)`
     （手动 direct 报红退出，不悄悄改 generic）。
- 真机证据（设备 `4c6229ab` / 22081212C / Android 16）：per-game APK `org.s2arm.game.t0100000000abcdef`
  （`-Ps2arm.nativeMode=game` 构建，89,144,870 B）+ 合成 direct 资源包
  `sha256-ae1e63ee67ac…`（1 module，apk-asset）：
  - `Game startup accepted: 0100000000ABCDEF session … consoleMode handheld`
  - `prev| [s2a] graphics selection: generic (direct backend not available), devices=0 queues=0 workers=0 consumers=0`
  - 手动 direct：`Game runtime returned: -114; ending this process` +
    `direct requested but backend is not available`
- 顺带修的诊断：`GameLibrary.scanImports` 现在会打 `import scan: dir=… readable=… entries=…` 与每个候选的
  `import candidate <name> manifest=<bool> listable=<bool>`（就是靠它定位到 scoped storage 问题）。
- 限制：合成包的 `main.npdm` 没有 ACI0，会话在模块加载后就 `FATAL`（`NPDM 里没有 ACI0 程序号`），
  这是合成包的限制，不是 direct 运行时问题；direct provider 未编入，`available()` 返回 0。

### 2026-10-25 / ANDROID-DIRECT-C7-PACK-INSTALL-001 / direct 产物 v1 真机装包事务：装成功 / 篡改被拒 / 缺描述被拒 / 回退 generic

- 关联：C7（"direct 真实包"的装包阶段）；上一条是出包侧。
- 状态：部分完成。**装包阶段**（设备端 BootContract 消费 requiredFeatures + graphics.v1.json）有真机 A/B/C/D
  四条证据；**首装后启动、缺 shader 首用编译、次局缓存、完整游戏**仍未做，不能算 C7 通过。
- 新增 `android/tools/direct_pack_install_probe.sh`（S2A_PY 需 lz4+capstone，建 venv 装）：
  用 `make_pack.py --synthetic` 造合成包（无游戏数据），push 到
  `/sdcard/Android/data/org.s2arm.android/files/import/`，重启 App 让 `GameLibrary.scanImports` 装，
  四条判据：
  - **A**：带 `requiredFeatures:["org.s2arm.graphics.v1"]` + descriptor 的包 → `Game installed: … ->
    sha256-964974008c98`（设备端校验 extension 的 manifest/sha256/bytes 后才落盘）；
  - **B**：只把 extension 的 sha256 改成 `ff…`（文件与 index 不变）→
    `refused: …extensions.org.s2arm.graphics.v1.sha256 does not match shaders/vulkan/direct/graphics.v1.json`；
  - **D**：删掉包里 descriptor 文件与它的 index 行（新 contentRoot），requiredFeatures 保留 →
    `refused: graphics manifest is missing: shaders/vulkan/direct/graphics.v1.json`；
  - **C**：同一游戏、不带图形能力的普通包 → `Game installed: … -> sha256-d52808a25e51; previous
    sha256-964974008c98 kept`（direct 与 generic 成为同一游戏的两个 revision，generic 为当前）。
- 顺带确认：**contentRoot 相同的包走 `alreadyInstalled` 短路，不再逐文件复验**（内容寻址的设计），
  所以"只删文件、不改 index"的包本来就不会被发现——D 必须先改 index 造出新 contentRoot 才有意义。
- 限制：
  - 合成包不是游戏；direct 运行时不存在，**没有任何启动/出图/首用编译/缓存/完整游戏证据**。
  - 探针依赖 `S2A_PY` 有 lz4+capstone（`make_pack` 的 rewrite 需要）；没有就用不了。
  - 本机 `adb shell run-as org.s2arm.android` 在 Android 16 / targetSdk 36 上被 SELinux 拒
    （`couldn't set SELinux security context 'default:targetSdkVersion=36:fromRunAs'`），所以设备端文件
    不能直接翻；判据全部走日志与装包结果。

### 2026-10-25 / ANDROID-DIRECT-C7-PACK-DIRECT-001 / 出包侧直连产物 v1：requiredFeatures + graphics.v1.json 严格校验

- 关联：C7（“direct 真实包”的生产侧）；消费侧（native `s2a_graphics_descriptor_parse`、Java
  `BootContract`）此前已实现，缺的是**出包端**。
- 状态：部分完成。现在能生成"声明 org.s2arm.graphics.v1 + 带严格校验过的 descriptor"的包；
  运行时装包/首装/完整游戏仍然没做，所以 C7 不算通过。
- 变更（`android/tools/make_pack.py`）：
  - 新增 `--direct-graphics <graphics.v1.json>`：把 descriptor 打进
    `shaders/vulkan/direct/graphics.v1.json`（**进 index.tsv**，安装器按 index 校验），artifact 写
    `requiredFeatures: ["org.s2arm.graphics.v1"]` 与
    `extensions["org.s2arm.graphics.v1"] = {manifest, sha256, bytes}`（字段与 BootContract 要求逐字对齐）。
  - `load_graphics()` 按 native 消费端口径校验：schema `s2a-graphics-v1`、titleId 16 hex、
    gameContentRoot/moduleSetDigest 为 `sha256-<64 小写 hex>`、frontend `nvn`、backend `vulkan-direct`、
    directABI=1、translatorClosure 字符集、sourceParserVersion≥1、runtimeCompilerABI
    `s2a-direct-compile-v1`、profiles 1..8 且每项有 profileHash、files 为数组；descriptor 1..1 MiB。
  - 三重一致性检查：descriptor 的 titleId 必须等于包内 control.nacp 的程序号；打包后的文件字节/sha
    必须与输入一致；产品根里已经有同名 descriptor 时直接报错（一个来源，不合并）。
  - 校验失败一律 `sys.exit`，且 `manifest.json` 不写 → 包不会被误认为完整（有测试断言）。
- 测试：新增 `android/tests/direct_pack_test.py`（6 条，已进 `tools/test.sh` 列表）：
  generic 包不带 requiredFeatures/extensions；direct 包 extension 的 manifest/sha256/bytes 与
  index.tsv 行、打包文件三者一致；titleId 不匹配 → 拒绝且不出 manifest.json；13 组非法字段逐条拒绝；
  CLI 在产品根已有 descriptor 时 `parser.error`；
  **生产端→消费端对拍**：用 cc 编 `tests/direct_graphics_test.c`，把**包里那份** descriptor 交给 native
  `s2a_graphics_descriptor_parse`，断言 `direct graphics file: ok title=0100000000ABCDEF abi=1`
  （该 C 测试本轮新增单文件模式；无 cc 时明确 skip 而不是假装通过）。
  在 macOS 主机跑：`contracts/validate.py` / `contract_validation_test.py` / `sysdata_pack_test.py` /
  `direct_pack_test.py`（6 条）全 ok。
- 限制：**没有在设备上装过 direct 包**（direct 运行时装包/首装/缓存/故障下局仍未做）；descriptor 的
  profileHash/gameContentRoot 由直连流水线决定，出包器只校验形状与程序号绑定，不核对游戏内容；
  Java `BootContract` 对"出包器产出的 artifact"还没有端到端对拍（只有 native 消费端对拍）。

### 2026-10-25 / ANDROID-DIRECT-C4-APK-GENERATIONS-001 / 引擎一个会话跨两代窗口：旋转换代先 drain 旧代际，再建新 swapchain

- 关联：C4（窗口代际 + present fence 退休）；上一轮的多帧 present。
- 状态：部分完成。窗口代际（旋转/尺寸变化）与换代前的退休已验证；仍没有游戏窗口 lease/backing 事务。
- 变更：
  - `runtime/vk_engine_present_probe.cpp` 改成**一个引擎会话 + 多窗口代际**的三个入口：
    `enginePresentBegin(Surface, dir, hz, maxFrames)` / `enginePresentFrames(Surface, frames, w, h)` /
    `enginePresentEnd()`。换代判据是 **native window 变了，或 Activity 报的窗口尺寸与当前 swapchain 不一致**；
    换代顺序固定为 `s2a_vk_track_wait_all` → 打 `retire-before-rebuild` 日志 → 销毁旧 swapchain/surface →
    建新代际。旋转后 `caps.currentExtent` 常常还是旧值，所以换代时以 Activity 报的尺寸为准。
  - `EnginePresentActivity`：`surfaceCreated` 建会话并推一轮；`surfaceChanged`（旋转/尺寸）在同一个会话里
    换代再推一轮；`surfaceDestroyed` 不结束会话（旋转时 Surface 会 destroy+create），`onDestroy` 才 `end()`。
    manifest 加 `configChanges`，旋转不重建 Activity。
  - 记录到的坑：`dm_vk_initialize` 有 `g_ready` 守卫，**同一进程只能初始化一次**（第二次报
    "Vulkan adapter already initialized"），所以每代重建引擎的路走不通，必须"一个会话换 swapchain"。
  - `tools/direct_vk_engine_apk_present.sh`：旋转到横屏 → 判据四条（两代日志/换代 drain/两代截图/退出 end 干净），
    跑完恢复原旋转设置。
- 验证（设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - `apk engine present: generation=1 size=1220x2712 ... frames=10 presents=10 failures=0`
  - `apk engine present: retire-before-rebuild generation=1 drain=0 submitted=10 retired=10 pending=0 failed=0`
  - `apk engine present: generation=2 size=2712x1220 ... frames=10 presents=10 failures=0`
  - `gen1 screen=1220x2712 0,0,255` / `gen2 screen=2712x1220 0,0,255`
  - `apk engine present: end generations=2 drain=0 submitted=20 retired=20 pending=0 failed=0`
    → `C5 engine present in APK: ok (10 frames x 2 generations)`
- 限制：还是探针式上屏（独立 Activity），没有窗口 lease/backing 事务，也不跟游戏渲染线程共用会话；
  `mtl_present(..., 0.0, NULL)` 无帧节奏；内容仍是纯色清屏（合成）；只在 `S2ARM_ANDROID_VK_ENGINE=1` 的包里存在。

### 2026-10-25 / ANDROID-DIRECT-C4-APK-PRESENT-FRAMES-001 / APK 内引擎连推 10 帧，present fence 进 vk_track 全部退休

- 关联：C4（present fence 退休/背压）与 C5（引擎出图路径）；上一轮的单帧同步 present。
- 状态：部分完成。多帧 present + fence 退休 + 截图对帧；还没有窗口代际/旋转/lease 与帧节奏（period=0）。
- 变更：
  - `runtime/vk_engine_present_probe.cpp`：改成**多帧非阻塞** present。每帧 present 回调里
    acquire → blit → 提交（带 fence）→ `vkQueuePresentKHR`，present fence 走
    `VkSwapchainPresentFenceInfoEXT` 链交给 `s2a_vk_track_present_fence`（fence 在 present 真正完成
    后才 signal），不再在回调里 `vkWaitForFences` 死等；命令缓冲按帧预分配，drain 之后统一释放。
    帧颜色交替绿/红，**最后一帧固定蓝**，这样截图能判断"屏幕上是最新一帧"。
  - `EnginePresentActivity`：帧数由 `s2arm.engine_frames` 传（默认 10，1..64）。
  - `MainActivity` 里上一轮那个"在主界面 SurfaceView 上跑 present"的死代码删掉（那个 native window
    归预览 presenter，必然 `VK_ERROR_NATIVE_WINDOW_IN_USE_KHR`），只保留注释指向独立 Activity。
  - `tools/direct_vk_engine_apk_present.sh` 判据升级：帧数 + `failures=0` + `drain=0` +
    `pending=0` + `failed=0` + `result=ok` + 截图中心 `0,0,255`。
- 验证（设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - `apk engine present: presents=10 failures=0 size=1220x2712 format=37 drain=0 submitted=10 retired=10 pending=0 failed=0`
  - `engine present probe: generation=1 frames=10 result=ok`
  - `screen center=0,0,255`（最后一帧颜色）→ `C5 engine present in APK: ok (10 frames, 22081212C)`
- 限制：swapchain 仍是一次性（探针结束销毁），没有窗口代际/旋转/backing 事务/lease；`mtl_present(..., 0.0, NULL)`
  没有帧节奏；present fence 只在本探针的 track 里退休，还没并进游戏窗口的 lease 生命周期；
  内容仍是纯色清屏（合成），不是游戏画面。

### 2026-10-25 / ANDROID-DIRECT-C5-APK-PRESENT-001 / APK 内引擎上屏：present 回调 blit 到 swapchain，截图中心 0,255,0

- 关联：C5/C4（“引擎进 APK”第三步：出图到 App 的 Surface）；P1 第 4 项。
- 状态：部分完成。一帧纯色清屏成功上屏并有截图证据；没有窗口代际/旋转/lease、没有游戏节奏和内容。
- 变更：
  - 新增 `runtime/vk_engine_present_probe.cpp`（JNI `enginePresentProbe(Surface, shaderDir, refreshHz)`）：
    同一个 `s2a_vk_device_create` 设备上建 `VkSurfaceKHR` 与 swapchain（优先 B8G8R8A8、FIFO、
    `TRANSFER_DST` 用途），引擎 `present` 回调里 acquire → `vkCmdBlitImage`（带 crop，缺省整图）→
    barrier 到 `PRESENT_SRC_KHR` → `vkQueuePresentKHR` → 等 present fence；清一帧纯绿
    （8×8 RGBA8 NVN 纹理）后 `mtl_present`。
  - 新增 `EnginePresentActivity`（独立 SurfaceView；**主界面的预览 presenter 已经占用了它自己的
    native window**，在 MainActivity 上直接建 swapchain 会得到 `VK_ERROR_NATIVE_WINDOW_IN_USE_KHR`
    ——第一次尝试就是撞这个错误，已记在这里）+ manifest 注册；`NativeBridge.copyEngineShaders()`
    抽出给两个 Activity 共用。
  - 新增 `tools/direct_vk_engine_apk_present.sh`：日志三条判据（`presents=1`/`failures=0`/
    `result=ok`）+ `adb exec-out screencap` 截图中心像素必须等于引擎清屏色 `0,255,0`。
- 验证（设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - `apk engine present: presents=1 failures=0 index=0 size=1220x2712 format=37 fence=1`
  - `apk engine present: done failures=0 shutdown=0`
  - `engine present probe: generation=1 result=ok`
  - `screen center=0,255,0` → `C5 engine present in APK: ok (22081212C)`
- 限制：
  - 单帧、纯色清屏、`mtl_present(..., 0.0, NULL)`（无帧节奏）；swapchain 一次用完即销毁，
    没有窗口代际/旋转/backing 事务/lease，也没有 present fence 交给 `vk_track` 长期退休。
  - 仍是合成内容（不是游戏画面），也没有输入/音频/存档。
  - 只在 `S2ARM_ANDROID_VK_ENGINE=1` 的包里存在。

### 2026-10-25 / ANDROID-DIRECT-C5-APK-DRAW-001 / APK 内第一帧：共享前端 draw → 引擎 .xgs → 读回 255,0,0,255

- 关联：C5（“引擎路径进 APK”第二步）；P1 第 4 项。
- 状态：部分完成。合成 C2 程序在 App 进程内录命令、经引擎回放、读回像素；还没有游戏 prog_t/资源/上屏。
- 变更：
  - `assets/engine-shaders/` 新增两个 `.xgs`（`c48907a70ab6182f` 1116 B、`f30687c581c65302` 8228 B）：
    合成 C2 程序（VS `Ald4`+`Ast4Pos` 位置、FS 红）经统一编译器 + `.xgs`，control key 1/2。
    由新脚本 `tools/direct_engine_assets.sh` 可重生成（提交产物，SHA 记在本条）；不是游戏着色器。
  - 新增 `runtime/vk_engine_draw_probe.cpp`（JNI `engineDrawProbe(shaderDir, refreshHz)`）：
    `s2a_vk_device_create` → `dm_vk_initialize`（shader 目录=App 私有目录）→ 用共享 NVN 前端建
    memory pool/8×8 RGBA8 纹理/program/命令缓冲，录 `DrawArrays(3)` → `nvnQueueSubmitCommands` →
    `mtl_last_fence`/`mtl_wait` → `mtl_read_texels` 读中心像素 → `xbg_game_shutdown`。
    NVN/适配层头按 C 语义包在 `extern "C"` 里（否则 C++ 改名导致 `mtl_*` 未定义）。
  - `MainActivity`：`s2arm.engine_draw` extra 触发；新增 `engineShaderDir()`（把
    `assets/engine-shaders/*.xgs` 复制到私有目录）与 `displayRefreshHz()`（API 29 回退）复用；
    `NativeBridge.engineDrawProbe` 声明。
  - 新增 `tools/direct_vk_engine_apk_draw.sh`：构造命令、抓 logcat，要求
    `center=255,0,0,255` + `failures=0` + `result=ok` 三条同时成立。
- 验证（设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - `engine: NVN shader f30687c581c65302 stage=0 loaded words=2040` / `c48907a70ab6182f stage=4 loaded words=263`
    （引擎从 App 私有目录读到两个 .xgs）
  - `apk engine draw: center=255,0,0,255 fence=1`
  - `apk engine draw: failures=0 shutdown=0 shaders=/data/user/0/org.s2arm.android/files/engine-shaders`
  - `engine draw probe: result=ok` → `C5 engine draw in APK: ok (22081212C)`
- 限制：
  - 只画 1 帧、1 个合成程序；没有游戏 `prog_t`/资源/纹理池/UBO/顶点索引，也没有上屏与窗口。
  - 顶点数据仍是测试用的全屏三角形；`.xgs` 是随包提交的合成产物，换编译器后要用
    `direct_engine_assets.sh` 重生成（否则 control key 对不上，引擎会报缺 shader）。
  - 只在 `S2ARM_ANDROID_VK_ENGINE=1` 的包里存在；默认包没有这个 native 入口（Java 侧调用会抛
    UnsatisfiedLinkError 被 catch 并记录，不影响正常启动）。

### 2026-10-25 / ANDROID-DIRECT-C5-APK-ENGINE-001 / d2r 引擎进 APK：设备内初始化/关闭通过

- 关联：C5（“引擎路径进 APK”第一步）；P1 第 4 项。
- 状态：部分完成。引擎能进包、能用 App 自己的 VkDevice 初始化并干净关闭；还没有 NVN 对象、`.xgs`、draw、present。
- 变更：
  - CMake 新增 `S2A_ANDROID_VK_ENGINE`（默认 OFF；Gradle 由 `S2ARM_ANDROID_VK_ENGINE=1` 转发）。开启时把
    `graphics/third_party/d2r_vulkan_engine` 的 21 个源文件、共享前端 `hle_nvn.c`/`portable.c`/
    `nvn_tex.c`/`nvn_deswizzle.c`/`nvn_dirty.c`/`nvn_names_android.c` 与探针宿主 shim 编进
    `libs2arm_android.so`。导入代码与共享前端不跟本仓 `-Werror`（只降级为警告），
    `xbg_texture.c` 仍是 `-fsigned-char`、C++ 侧 `-fno-strict-aliasing`。
  - 新增 `native/nvn/vk_engine_host_shim.c`：与测试用 `frontend_test_host.c` 同源，但去掉 App 已经
    提供的 `now_ns`/`guest_ns`/`module_of`（直接编会 duplicate symbol）；`front_display_refresh`
    改由 Java 传进来的 `Display.getRefreshRate()`（不写死 60），`module_of` 如实返回 NULL，
    未实现入口/直连失败打到 logcat。
  - 新增 `runtime/vk_engine_probe.cpp`（JNI `engineProbe(shaderDir, refreshHz)`）：
    `s2a_vk_device_create` → `dm_vk_initialize` → `xbg_game_shutdown` → `s2a_vk_device_destroy`,
    日志打 rc/why/refresh/shader 目录；`NativeBridge.engineProbe` + `MainActivity` 的
    `s2arm.engine_probe` extra 触发（后台线程）。
  - 新增 `tools/direct_vk_engine_apk_probe.sh`：构造命令、抓 logcat、要求 `init rc=0` +
    `shutdown rc=0` + `result=ok` 三件事都成立才报 ok。
- 验证（设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / driver `2150002783`；
  包 `S2ARM_ANDROID_CS_SERVICES=static S2ARM_ANDROID_VK_ENGINE=1` 构建，91,718,751 B，
  sha256 `14e6c22e…`）：
  - `engine apk probe: device Qualcomm Technologies Inc. Adreno Vulkan Driver api=1.1.128`
  - `engine: NVN caps api=1.1.128 driver=2150002783 maxUBdyn=32 maxPerStageUB=524288 minUBAlign=64 maxBoundSets=7`
  - `engine apk probe: init rc=0 why= shutdown rc=0 refresh=120.000 shaders=/data/user/0/org.s2arm.android/files/engine-shaders`
  - `engine apk probe: result=ok` → `C5 engine in APK: ok (22081212C)`
- 顺带修：探针取刷新率时用了 `Context#getDisplay()`（API 30），minSdk 是 29，lint `NewApi` 报错；
  改成 API 30 起用 `getDisplay()`、更低版本用 `getWindowManager().getDefaultDisplay()`。
  默认（引擎 OFF）包重新出包并过 lint/verify-apk：88,674,935 B，sha256 `61867619…`。
- 限制：默认 OFF（体积 +43 MB）；探针只 init/shutdown，没有 NVN 对象/`.xgs`/draw/present/上屏，
  宿主 shim 是**诊断桩**不是正式 HLE 服务层；引擎与 App 的 WSI/window lease 尚未共用；
  `S2A_ANDROID_VK_ENGINE=1` 的包没有跑 lint/verify-apk 之外的回归（C2 AOT/C6 用默认包验的）。

### 2026-10-25 / ANDROID-DIRECT-BUILD-MACOS-001 / macOS 本机重编 APK，C2 设备 AOT 恢复逐字节一致

- 关联：C2/C4/C6（设备证据的构建前提）；换机后本机无 SDK/Docker，APK 无法重编。
- 状态：打通本机构建；C2 设备 AOT、C6 中文 IME、C4 WSI 用新包复跑通过。
- 变更：
  - 本机装 cmdline-tools（build 16111833，SHA-1 校验）+ platform 36 + build-tools 36.0.0 +
    cmake 3.31.6 + JDK 17；NDK 用早前装的 r29（darwin-x86_64，Rosetta）。
  - `cs/build.sh`：NDK prebuilt 目录改由 `tools/ndk_toolchain.sh` 解析；非 Linux 宿主把 ILC 的
    编译/链接切到 NDK clang、关掉 strip。
  - **静态库重归档**：macOS 上 ILC 用宿主 `ar`/`ranlib` 归档 ELF 对象，`ranlib` 只认 Mach-O
    （`archive member 'libs2a_cs.o' not a mach-o file`），产出的 `libs2a_cs.a` 只剩空 SYMDEF，
    Gradle 链接报 `__start___modules`/`__stop___unbox`/`g_requiredCpuFeatures` 未定义。
    改为用 NDK `llvm-ar` 重新归档 `cs/aot/obj/<cfg>/<rid>/native/libs2a_cs.o`。
  - `codecs/build.sh`、`openssl/build.sh`：NDK llvm/host prebuilt 同源解析、`nproc`→`s2a_jobs`、
    `sha256sum` 缺失时用 `shasum -a 256`。
  - `direct_c2_aot_probe.sh`：BSD `wc -c` 带前导空格、macOS 无 `sha256sum`，会假报差异；已修。
  - `MainActivity`：direct 自测用 `InputStream.readAllBytes()`（API 33），minSdk 是 29 ——
    lint `NewApi` 直接报错（`host/build.sh` 因此失败）、API 29–32 上会 NoSuchMethodError；改为
    自写 `readAll()`。
- 验证（macOS arm64；NDK r29 darwin + JDK 17.0.21 + .NET 10.0.401；设备 `4c6229ab` /
  22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - `S2ARM_ANDROID_CS_SERVICES=static bash android/host/build.sh` →
    `BUILD SUCCESSFUL`（assembleDebug + lintDebug），`verify-apk`（arm64-v8a、16 KB 段与对齐）
    与 `apksigner verify` 通过。**APK 48,862,027 B，sha256 `5053b685…722fcb`**，含
    `libs2arm_android.so`（静态 AOT）+ `libssl.so`/`libcrypto.so` 与
    `s2a_direct_compile_v1`。
  - C2 设备 AOT：`device: 26087 B sha256=88480637…b8905` 与离线 CLI 完全一致，
    `direct AOT compile: byte-identical (26087 B)`。（旧包在同一 selftest 下 SIGABRT，是旧产物/
    旧签名包的问题，不是当前源码。）
  - C6：`direct_c6_ime_zh.sh confirm|cancel|stop` 全过（`ok, chars=2, utf8=6` / `cancel` /
    `rc=-4`）。
  - C4 WSI：两代 swapchain 各 3 帧、present fence 全部经 track 退休（`submitted=3 retired=3
    pending=0 failed=0`），旋转后 2712×1220。
- 限制：
  - 新包与本机 debug keystore 一致，但与旧经 Linux 构建的包签名不同，必须卸载重装（preview 包里
    没有已导入游戏，未丢游戏数据；旧包 82,623,561 B / SHA-256 `70323314…6cd0e4b` 已备份到
    `/tmp/s2a-installed.apk`，不入仓）。
  - `android/test.sh` 在本机需要 `cmake` 在 PATH（可用 `$ANDROID_HOME/cmake/3.31.6/bin`），
    且会在 `native/memory.c` 的 Linux 专有 `mremap` 处失败（`plat_test` 也引用同一文件）——
    Linux 宿主仍是该 native 主机测试子集的权威门禁；macOS 上改跑 C2/C5/C6 的主机套件。
  - 只在 macOS 宿主出包；Linux/Docker 路径未重跑；direct/game 的 APK 集成仍未开始。

### 2026-10-25 / ANDROID-DIRECT-C5-MULTIPOOL-001 / 第二块内存池的纹理池不再被判成 null（全局 id 上界）

- 关联：C5；P1“多纹理池/池边界”（#291 空池、池基址）。
- 状态：修复；真机 A/B 有证据。池淘汰/重用、跨池句柄、图像池仍未做。
- 根因：S2Arm 共享 NVN 前端把纹理/采样器 id 编成**全局号**（`hle_nvn.c` 的 `dpool_add`：每块内存池的基址相隔 256 的整数倍，真机日志 `pool #2 (texture, 8 entries): numbered from 256`），而引擎（d2r `xbg_game.cpp`）按池结构里的 `n`（本池条目数）判上界 `id>=n`。第二块内存池之后的所有纹理都被当成 null（`NVN defined null sampled resource`），整帧黑。
- 变更：
  - `graphics/third_party/d2r_vulkan_engine/xbg_game.cpp`/`xbg_game_internal.h`：新增 `xbg_legacy_tex_pool_bound` 与 `tex_pool_exceeds(id, local_n)`，判据改成“前端报来的全局上界优先、未报时退回池内 `n`”；三处判据（描述符缓存命中、描述符写入、计算阶段图像查找）统一走它。
  - `nvn_vk.c`：`mtl_set_tex_pool_n`（前端每次纹理池初始化都会调）从空实现改为把全局上界交给引擎。
  - 引擎测试新增第八帧：纹理池与命令内存都在**第二块内存池**里，用 C2 单纹理程序读回绿。
  - 测试自身修正：第八帧曾把纹理数据与命令内存都放在池内偏移 0，swizzle 覆盖命令记录导致全 0；纹理改到 0x10000，并把原因写进注释。
  - `README.s2a.md` 记录该引擎改动（第三方导入必须留痕）。
- 验证（macOS 宿主 + NDK r29 darwin；设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - A/B（只差 `mtl_set_tex_pool_n` 一处）：**未接上界**时第八帧 `NVN defined null sampled resource` + `center8=0,0,0,0`；**接上界**后 `center8=0,255,0,255`。
  - 全量：`vk-engine-draw: ok`，八帧 `center2=255,0,0,255 / center3=0,255,0,255 / center4=0,255,0,255 / center5=255,255,0,255 / center6=255,255,0,255 / center7=0,0,0,255 / center8=0,255,0,255`；`C5 engine draw: ok`。
  - 构建：`d2r Vulkan engine: 21 objects compiled`、`engine+adapter link: ok`、`dm_vk_initialize rc=0` / `xbg_game_shutdown ok`。
- 限制：只覆盖“同一块内存池内的纹理池 + 第二块内存池”这一种布局；池淘汰/重用（#291）、跨池句柄、图像池（BindImages）、sampler 池基址仍未验；引擎改动需与上游 d2r 同步时复查。

### 2026-10-25 / ANDROID-DIRECT-C5-UBO-001 / C5 guest 常量缓冲进 C2/.xgs/引擎，同程序换 UBO 内容黄→黑

- 关联：C5/C2；P1“UBO/C1：C2 请求带真实 UBO 使用、共享前端绑定、引擎 descriptor、读回验证”。
- 状态：部分完成。c[0] 的 B32 常量加载贯通到真机读回；变址加载、B64/B128、多 cbuf、dynamic offset、真实 `prog_t` 状态未做。
- 变更：
  - C2 合成程序新增 `c2ubo`：FS 用 `LDC Rd, c[0][off]`（LsSize=B32，SrcA=RZ）读 `0x00`/`0x04` 两个字当 R/G，`constantBufferUse=1`；编译器把 guest UBO 落在 set0 binding1（support 之后），`DirectBinding.slot` 记录 guest 常量缓冲号，结果 JSON 里 `bindings[].slot`/`source=guestUBO[0]` 可复核。
  - `.xgs` 现在携带 uniform binding：`VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER(6)` + `XBG_SOURCE_UNIFORM(2)`，`slot`=guest cbuf 号，`bytes=0` 让引擎按 SPIR-V 实际访问范围裁剪、再取 NVN 缓冲真实大小；binding 号改成**跨 stage 统一编号**（support 固定 0，uniform/纹理共用同一编号空间），SPIR-V 仍按 `(set,binding)` 映射重写；storage/image 仍明确报红，不静默丢。
  - 引擎测试新增两帧（第六/第七）：同一 UBO 程序，`BindUniformBuffer` 绑 (1.0f,1.0f) 读回黄，改成 (0,0) 读回 (0,0,0,255)。
- 验证（macOS 宿主 + NDK r29 darwin；设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - 主机：`direct-compiler: ok (119 checks)`（新增 5 项：唯一 uniform binding、set0 binding1、slot/source、`constantBufferUse=1`、反射 cbuf slot 0）；`direct c2 xgs: ok`（新增 UBO binding 八字段 `(1,6,1,0,2,0,0,0)`、与纹理共用编号空间；storage 仍报红）。
  - 真机：`vk-engine-draw: ok`，`frames=6 fence6=6 center6=255,255,0,255`、`frames=7 fence7=7 center7=0,0,0,255`（alpha 仍 255，说明 FS 真的执行了、颜色随缓冲内容变化，不是常量兜底）；1–5 帧与 `C5 engine draw: ok` 不变。
  - 回归：C5 前端 `submit/rt/draw/tex/c2draw/c2vs/c2tri` 七例全 ok；设备请求经离线 CLI 仍 `26087 B / sha256 88480637…b8905`（UBO 改动不影响无 UBO 请求）。
- 限制：
  - 只覆盖 `c[0]` 的 B32 常量：`LDC` 变址（AddressMode Is/Isl）、B64/B128、VS 与 FS 用同一 cbuf 的分配、UBO 越界/短缓冲、dynamic offset 未验。
  - C1（shader literal 段）仍在编译期折叠，不是运行时绑定；真实游戏 `prog_t` 的 cbuf 状态/绑定未接。
  - storage/image 描述符仍未进 `.xgs`（明确报错）。

### 2026-10-25 / ANDROID-DIRECT-C5-MULTITEX-001 / C5 两张池纹理同时绑定（槽位取自反射，真机读回黄）

- 关联：C5/C2；P1“多纹理同时绑定/池边界”的第一项。
- 状态：部分完成。双纹理同帧绑定成立；多内存池/池边界、cbuf 句柄、separate 采样器、数组/mip/view 未做。
- 变更：
  - **槽位改为按反射决定**：翻译器先 `CreateTextureBinding`、后 `RegisterTexture`（`ResourceManager.cs:257/340`），旧代码按“当前句柄/第一条 fact”猜槽位，两张纹理都会落到第一张的槽位。现在编译结束按 `TextureDescriptor.HandleIndex` 回填 `DirectBinding.Slot`；`CbufSlot >= 0` 与 separate 采样器没有实现路径，明确 `UNSUPPORTED_PROGRAM`，不写占位 0。
  - `.xgs` 描述符改写从“按装饰出现顺序重编号”改成按 `(set, binding) → 引擎 binding` 映射重写；只写本 stage 的描述符（VS 不再携带 FS 的纹理 binding，否则另一阶段要求根本没绑的槽位）；非 support/texture 的 binding 明确报红，不静默丢。
  - C2 新合成程序 `c2tex2`：FS 先 `TEX 2`（红）再 `TEX 3`（绿），`FADD` 合成 (1,1,0,1) 黄；引擎第五帧在同一纹理池注册 2/3 号槽并一次 `BindTextures(first=2, count=2)`。
- 验证（macOS 宿主 + NDK r29 darwin；设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / driver `2150002783`）：
  - 主机：`direct-compiler: ok (114 checks)`（新增 6 项：两条 texture binding、slot 2/3、binding 号不同、FS 反射两个纹理、handleIndex 2/3）；`direct c2 xgs: ok`（新增双纹理 binding 号/槽位、VS 只留 support、uniform binding 报红）。
  - 真机：`vk-engine-draw: ok`，`frames=5 fence5=5 center5=255,255,0,255`（槽 2 红 + 槽 3 绿）；前四帧不变（`center3/center4=0,255,0,255`）；`C5 engine draw: ok`。
  - 回归：C3 `vk-record: ok`、C5 前端 `nvn-frontend-submit/rt/draw/tex/c2draw/c2vs/c2tri` 全 ok。
  - 设备请求经离线 CLI 仍 `26087 B / sha256 88480637…b8905`：槽位改动对无纹理程序零影响。
- 限制：
  - 槽位语义是 **shader 纹理单元号**（TEX tid），不是池 id；`BindTextures` 的 `first` 必须与之一致。
  - 引擎把纹理 id 0 当 null（`xbg_game.cpp:2647`），且 NVN 前端按**内存池**分配全局 id 基址（`dpool_add`，第二块内存池从 256 起）、引擎按 `id >= 池 n` 判空 —— 因此多内存池场景仍未验证，测试只能用同一内存池的 2/3 号槽（池大小 8）。池边界/空池（#291）仍是缺口。
  - 未接：cbufSlot 纹理句柄、separate 采样器、纹理数组/mip/视图、池淘汰重用。

### 2026-10-25 / ANDROID-DIRECT-NDK-HOST-001 / 直连探针按宿主解析 NDK，macOS 主机复跑 C0/C1/C3/C4/C5/C6

- 关联：C0/C1/C3/C4/C5/C6；换机（Linux→macOS）后真机探针无法复现。
- 状态：工具链修复 + 真机复跑通过；C2 设备 AOT 本轮未通过（见限制），不沿用旧结论。
- 变更：
  - 新增 `android/tools/ndk_toolchain.sh`：按 `toolchains/llvm/prebuilt/{darwin-arm64,darwin-x86_64,linux-x86_64}` 与 `shader-tools/<tag>/glslc` 选宿主工具链，找不到就报红退出；10 个直连探针脚本不再写死 `linux-x86_64`。
  - `direct_vk_engine_check.sh` 补 `graphics/nvn/host` 与 `-I $repo` 头路径（否则适配层 `nvn_vk.c` 找不到 `dm.h`，脚本直接失败）；对象数 20→21（引擎 20 + 适配层 1），并点名核对 `xbg_game.o/nvn_vk.o/xbg_clear.o/xbg_draw_plan.o`，不只数数量。
  - `direct_nvn_port_check.sh`：`stat -c%s` → `wc -c`（BSD/macOS 的 stat 没有 `-c`）。
- 提交：本分支。
- 验证（macOS arm64 宿主；NDK r29 `29.0.14206865` darwin-x86_64，经 Rosetta 运行；设备 `4c6229ab` Redmi 22081212C / Android 16 / Adreno 730 / Vulkan 1.1.128 / driver `2150002783`）：
  - 主机：`direct-compiler: ok (108 checks)`；`direct c2 xgs: ok`；`direct control parser vs merge_extract.cs_facts: 51 cases, 0 mismatches`；设备请求经离线 CLI 复算 `26087 B / sha256 88480637…b8905`。
  - ARM64：`direct-abi compare: ok (arm64, c, cs; 6 sizes, 22 offsets)`；`direct C1 ARM64 probe: ok`（11 个 v2 用例）；`NVN frontend Android compile: ok (344040 B object)`；`d2r Vulkan engine: 21 objects compiled (ARM64/API29), aggregate=6001f6b7…`；`engine+adapter link: ok`。
  - 真机 GPU（C3）：`vk-micro: ok`（RGBA8 清 64/128/191/255、SINT8 -128,-1,0,127、三角形中心 129,129,0,255、compute `3i+1`、buffer copy）；`vk-record: ok`（replay executed=9、CLEAR_TEX/T2T/T2B/B2T/带 stride 逐行、局部清除、通道掩码、RGBA32I 精度、未实现 opcode 显式 op=19）。
  - 真机同步（C4）：`vk-sync: ok`（两批 fence 顺序完成、未信号 fence 超时）；`vk-track: ok`（submitted=4 retired=4 pending=0 failed=0，在途 fence 时销毁被拒、完成后放行）。
  - 真机前端/引擎（C5）：`nvn-frontend-submit/rt/draw/tex/c2draw/c2vs/c2tri` 全 ok（`nvn-frontend-c2tri: center=255,0,0,255`）；`dm_vk_initialize rc=0`、`xbg_game_shutdown ok`；引擎四帧 ok（fence 1→4、`center3=0,255,0,255`、`center4=0,255,0,255`）。
  - 真机输入法（C6）：`direct_c6_ime_zh.sh confirm` → `ok, chars=2, utf8=6`；`cancel` → `cancel, result=0`；`stop` → `rc=-4` + `HostApi stop requested`。
- 限制：
  - 本机没有 Android SDK/gradle/Docker（amd64 构建镜像在 arm64 上也不实用），**不能重编 APK**；设备侧 C2 AOT 只能在已装 APK 上跑。
  - 设备上现装 APK（2026-10-25 14:55）执行 `s2arm.direct_compile_selftest` 时线程 `direct-compile-selftest` 在 3 ms 内 SIGABRT（`Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE)`，logcat 中线程名被截断成 `direct-compile-`）；logcat 无 abort message，`dumpsys dropbox` 最新 tombstone 停在 14:36 且 crash_dump 被 SELinux 拒写，拿不到 backtrace。同一请求离线 CLI 仍是 26087 B/同一 SHA，说明请求与编译器实现未变，问题在 APK 内 AOT 产物/装配，需重编 APK 后复测；本轮**没有**新的设备 AOT 证据。
  - 只在这台设备与 macOS 宿主上复跑，Linux 宿主与其他设备未重跑；以上全是探针与合成程序证据，不是游戏。

### 2026-10-25 / ANDROID-DIRECT-C6-MERGE / C6 中文 IME 旁路合入主链

- 关联：C6；来源 `android/direct-c6-ime`（vickwv）。
- 合并：只 cherry-pick 两个独立提交 `87447084`、`3ceb033f`，未整支 merge；冲突仅 CHANGELOG，保留主链记录。
- 验证：`assembleDebug` 成功；`keyboard_owner_test`（keyboard producer PASS）、`host_ui_test`（199 断言）、`ui_session_test`（ok）；真机中文确认/取消/Stop 证据见 `docs/c6-ime-device-validation.md` 与 `docs/validation/c6-ime-20261025/`。
- 限制：preview 外壳；direct/generic 游戏内文本、单虚拟核 Stop、候选自动点选、extract/横屏未验。C6 仍为部分，不替代 C7。
### 2026-10-25 / ANDROID-DIRECT-C2-TEX-SLOT1 / 非零纹理槽采样

- 关联：C5 纹理槽/池；C2 texture fact handle1。
- 变更：C2 `c2tex1` 使用 TEX TidB=1、texture fact handle1；结果 slot1；`.xgs` binding slot1；前端 BindTextures first=1。
- 验证：真机 `frames=4 center4=0,255,0,255`、`vk-engine-draw: ok`；C2 108 checks。
- 限制：单纹理非零槽；多纹理同时绑定/池顺序未验。
### 2026-10-25 / ANDROID-DIRECT-C2-TEX-SLOT / C2 纹理槽位进入结果/.xgs

- 关联：C5 纹理池/多槽；当前合成单纹理。
- 变更：`DirectBinding` 增加 texture `slot`（来自 `RegisterTexture`/texture fact）；C2 结果写出 `slot`；`.xgs` texture binding 使用该 slot。
- 验证：C2 108 checks；`c2tex` binding 含 `slot:0`；`.xgs` 自检；引擎四帧仍 `center4=0,255,0,255`。
- 限制：多纹理绑定顺序/槽位尚未设备验证；slot 回退仅按同 stage 首个 fact，不能当多纹理完成。
### 2026-10-25 / ANDROID-DIRECT-C2-TEX-COORD / TEX 采样坐标/数据验证

- 关联：C5 纹理采样；强化第四帧。
- 变更：纹理改为仅 texel(0,0) 绿、其余红；C2 TEX 读回仍绿，证明不是常量清屏或全绿纹理假象。
- 验证：真机 `frames=4 center4=0,255,0,255`、`vk-engine-draw: ok`。
- 限制：合成纹理/采样器；无 mip/数组/视图/格式/游戏资源。
### 2026-10-25 / ANDROID-DIRECT-C2-TEX-SAMPLE / C2 TEX 真机采样读回

- 关联：C5 纹理路径；C2 TEX 片元 + 共享前端 texture/sampler + d2r 引擎 descriptor。
- 变更：`vk_engine_draw_test` 第四帧创建 8×8 绿纹理、texture/sampler pool（各 2 项，id1）、绑定 handle，C2 TEX 采样后读回。
- 关键修复：pool 大小必须覆盖 id1，否则引擎把 id1 当池外 null texture；C2 `.xgs` 单 set 重写 + texture binding 1。
- 验证：真机 `frames=4 fence4=4 center4=0,255,0,255`、`vk-engine-draw: ok`；前三帧红/红/绿仍过。
- 限制：合成程序/纹理/采样器；无真实游戏纹理池/视图/格式；不证明游戏资源路径。
### 2026-10-25 / ANDROID-DIRECT-C2-XGS-ONESET / .xgs 单 descriptor set 重写

- 关联：C5 纹理桥接；引擎只创建一个 descriptor set。
- 变更：`direct_c2_xgs.py` 把 C2 的 set2 texture binding 改写到 set0，并分配唯一 binding；`.xgs` texture binding 从 0 改为 1，避免与 support 冲突。
- 验证：`direct c2 xgs: ok`；引擎红/绿三帧仍 `255,0,0,255`/`0,255,0,255`；C2 108 checks。
- 尝试：C2 TEX 第四帧已能创建管线，但采样读回黑；已回退该测试，不登记纹理采样通过。
- 限制：纹理 descriptor/sampler 绑定未验证；不声称采样。
### 2026-10-25 / ANDROID-DIRECT-C2-TEX-REQUEST / C2 TEX 合成请求进入引擎 probe

- 关联：C5 纹理路径桥接；仍未采样。
- 变更：C2 测试生成 `c2tex.json`（TEX 2D、坐标 R2/R3、handle0）；引擎 probe 生成 `c2tex` 的 `.xgs`（support+texture binding），当前引擎测试只使用红/绿程序，尚未绑定 texture/sampler。
- 验证：`C5 engine draw: ok`、`direct c2 xgs: ok`；C2 108 checks。
- 限制：TEX 片元未在设备执行，未读回纹理；引擎 descriptor/采样未接。
### 2026-10-25 / ANDROID-DIRECT-C2-TEX-XGS / C2 纹理绑定写入 .xgs

- 关联：C5 纹理路径；尚未设备采样。
- 变更：C2 测试加入 TEX 2D 合成片元（`c2tex.json`）；`.xgs` 转换器把 C2 `kind=texture` binding 写成 `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER` + `XBG_SOURCE_TEXTURE`。
- 验证：`direct c2 xgs: ok`；C2 108 checks 仍过；`c2tex` 生成 fs binding（support+texture）。
- 限制：引擎 draw 尚未绑定 NVN texture/sampler，也未读回采样；不是纹理采样通过。
### 2026-10-25 / ANDROID-DIRECT-VK-ENGINE-GREEN / 第二 C2 程序/管线切换

- 关联：C5；引擎程序/管线缓存与 C2 多程序。
- 变更：C2 测试生成 `c2green.json`（同 VS、绿 FS）；`.xgs` 增加绿 FS；引擎测试第三帧绑定第二 `prog_t`，读回绿。
- 验证：真机 `frames=3 fence3=3 center3=0,255,0,255`、`vk-engine-draw: ok`；C2 108 checks 仍过。
- 限制：合成程序/顶点；无纹理/UBO/真实游戏资源。
### 2026-10-25 / ANDROID-DIRECT-VK-ENGINE-2F / d2r 引擎两帧/真实 fence

- 关联：C5/C4；引擎重复回放与完成同步。
- 变更：`vk_engine_draw_test` 第二帧重新录制同一 program/texture，等待 `mtl_last_fence` 的真实 fence，再读回。
- 验证：真机 `frames=2 fence1=1 fence2=2 center2=255,0,0,255`、`vk-engine-draw: ok`。
- 限制：合成程序/顶点；无窗口/present；不证明游戏资源或长时稳定。
### 2026-10-25 / ANDROID-DIRECT-VK-ADAPTER-EXTRAS / 适配层额外入口收敛 + .xgs 自检

- 关联：C5；去掉引擎 draw 测试对适配层行为的 shim 依赖。
- 变更：`nvn_vk.c` 实现 `mtl_tex_init`/`mtl_tex_cpu_written`/`mtl_tex_gpu_owned`/`mtl_alias_drop_pool`/`mtl_set_depth_zero`/`mtl_set_origin_lower_left`/`mtl_bad_draw_feat`；测试 shim 只剩宿主 `front_display_refresh`。
- 新增 `direct_c2_xgs_test.py`：校验 `.xgs` header、stage（VS0/FS4）、support binding、VS input0、control key、重复 key 拒绝。
- 验证：`direct c2 xgs: ok`；`C5 engine draw: ok`、`vk-engine-draw: center=255,0,0,255` 仍过。
- 限制：这些适配入口仍是 Vulkan 引擎语义的显式最小实现；不证明纹理池/UBO/真实游戏资源。
### 2026-10-25 / ANDROID-DIRECT-VK-ENGINE-DRAW / C2 → .xgs → 共享前端 prog_t → d2r 引擎出红

- 关联：C2/C5；d2r-mobile Vulkan 引擎（MIT）。
- 变更：
  - `direct_c2_xgs.py`：C2 program.json 的 SPIR-V + support binding + VS input0 写成 `.xgs`；control 由调用方提供，key=SHA-256(control)[:16]，重复 key 拒绝。
  - `xbg_game.cpp`：`OP_DRAW`/`OP_DRAW_IDX` 用 `draw_rec`/`draw_idx_rec` 接受 S2Arm 的紧凑记录，不再要求完整 48B payload。
  - `vk_device.c`：按实际支持启用 C2 模块声明的 image gather/extended formats/read-write without format/int16/clip-cull/sampleRate；`core_features` 供引擎配置。
  - 新增 `vk_engine_draw_test.c` + `direct_vk_engine_draw_probe.sh`：合成 C2 VS/FS、共享 NVN 前端 prog_t、d2r 引擎、Vulkan draw/读回。
- 验证：真机 `INFO vk-engine-draw: center=255,0,0,255`、`vk-engine-draw: ok`、`C5 engine draw: ok`。
- 限制：合成顶点/着色器；测试 shim 提供 `mtl_tex_init` 等 S2Arm 适配层额外入口与 `front_display_refresh`，生产需真实实现；未进 APK、无游戏资源/loader/完整游戏。
### 2026-10-25 / ANDROID-DIRECT-VK-ENGINE-INIT / d2r 引擎真机初始化/关闭

- 关联：C5 后端复用；d2r-mobile MIT。
- 变更：新增 `vk_engine_init_test.c` 与 `direct_vk_engine_init_probe.sh`；用 S2Arm 直连 Vulkan 设备初始化 d2r 引擎，再 `xbg_game_shutdown`。
- 验证：真机 Adreno 730 `INFO dm_vk_initialize rc=0`、`INFO xbg_game_shutdown ok`、`C5 engine init/shutdown: ok`；引擎枚举 NVN 格式/扩展后正常退出。
- 限制：不创建 NVN 对象、不加载 `.xgs`、不绘制、不呈现；未进 APK；不是 C5 出图或游戏证据。
### 2026-10-25 / ANDROID-DIRECT-C6-ZH-IME / 真机中文组字/候选/确认与取消

- 关联：C6；系统 IME、HostApi UI broker/JNI/Activity。
- 状态：部分完成（preview）。
- 变更：
  - `HostKeyboard` 清除 `FLAG_ALT_FOCUSABLE_IM`（它让窗口不被 IME 服务，`showSoftInput()` 被忽略）；`mode=5` 不再加 `NO_SUGGESTIONS`，保留中文候选；完成日志只加 `chars/utf8` 长度，不记录文字。
  - 预览 `uiSelftest(mode,min,max)` 可由 intent 指定模式/长度，native 侧启动 waiter 并记录终态/字节数；新增 `tools/direct_c6_ime_zh.sh confirm|cancel|stop` 与 `docs/c6-ime-device-validation.md`。
- 验证：Redmi 22081212C / Android 16 / Gboard 18.4.1（简体中文 9 键），`mode=5` 下 `input text nihao` 组字、空格选首候选“你好”、确定；`Keyboard request completed: ok, chars=2, utf8=6, result=0`，waiter `rc=0 status=ok`；取消 `cancel, result=0`；组字中 Stop wake waiter `rc=-4`、`HostApi stop requested`、无 FATAL/ANR。broker host 199/会话/owner 断言通过。原始日志见 `docs/validation/c6-ime-20261025/`。
- 限制：仍是 preview；generic/direct 游戏内文本、单虚拟核（`S2A_CORES=1`）Stop、候选条自动点选与 extract/横屏路径未验；不改验收表，C6 未完成。

### 2026-10-25 / ANDROID-DIRECT-VK-ENGINE-LINK / d2r 引擎+适配层 ARM64 链接

- 关联：C5 后端复用；d2r-mobile MIT。
- 变更：导入 `nvn_vk.c/.h` 并适配 S2Arm `nvn_mtl.h`/`nvn_obj.h`；新增链接检查，把引擎、适配层、共享 NVN 纹理/测试宿主与两个测试 shim 链接成 `libdm_vk_check.so`。
- 验证：`d2r Vulkan engine+adapter link: ok (ARM64/API29), sha256=09cb1108...`，`--no-undefined` 通过。
- 限制：只链接，未初始化 Vulkan/未跑设备/未进 APK；`.xgs` 仍是离线包，C2 尚未生成；两个 shim 仅链接检查。
### 2026-10-25 / ANDROID-DIRECT-INTEGRATION-BASE / 集成本地读回与 Vulkan 同步基础修复

- 关联：android/integration 56d42633 增量；不是整支合并。
- 已集成：`8c951b8c` fence 错误/等待数组释放、`21dfe689` 顶点索引访问、`fa23f28d` compute 索引转换屏障、`9ee0cd84` 读回动作/原生代次原子发布、PR341 `7a9bd598` CubeArray 能力、`fb865d39` Vulkan1.1 draw parameters。
- 验证：
  - `DeviceFeatures.Tests`：107 断言、51 组 promoted chains 1,653 检查、0 失败（CPU dispatch）。
  - `readback-registration-tests/Host.csproj`：35 checks、0 failed（真实 MemoryTracking/RegionHandle/VirtualRegion，原生端点计数）。
  - `Ryujinx.Graphics.Vulkan` 构建通过；C2 108 checks 仍过。
- 限制：这些是通用轨/主机合同；不替代直连 C4 的 WSI/backing/代际验收，也不证明游戏长时稳定。
### 2026-10-25 / ANDROID-DIRECT-C3-PARTIAL-CLEAR / 局部区域与通道掩码清除

- 关联：C3、PR345/PR370 语义；不是 Metal 实现复制。
- 变更：
  - 全通道局部区域：临时图像 `vkCmdClearColorImage` + `vkCmdCopyImage` 区域拷贝，保留区域外像素（真实 GPU）。
  - 通道掩码（mask != 0xF）：GPU 读回 → 按 mask/region 更新 → GPU 写回；有 fence 完成，不是伪造。
  - 支持 RGBA8/RGBA8I/RGBA8UI/RGBA32F/RGBA32I/RGBA32UI；其他格式/视图/mip/layer 继续明确拒绝。
- 验证：真机 `clear-partial: in=-128,-1,0,127 out=0,0,0,0`、`clear-mask: 255,255,0,255`、`clear-partial-int32: in=INT_MIN,INT_MAX,16777217,-16777217 out=1,2,3,4`；C3 全部 ok。
- 限制：通道掩码走 CPU 更新（非 GPU shader）；RGBA32 区域清除走临时图像拷贝；格式视图/mip/数组层/录制后改输入未验。
### 2026-10-25 / ANDROID-DIRECT-VK11-DRAWP / 直连设备启用 shaderDrawParameters

- 关联：C2/C3/C5；C2 顶点 SPIR-V 声明 `DrawParameters`。
- 变更：`s2a_vk_device_create` 用独立 `VkPhysicalDeviceShaderDrawParametersFeatures` 查询/启用；缺失时 create 前报 `required feature missing: shaderDrawParameters`，不再依赖驱动隐式支持。
- 验证：真机 Adreno 730 `INFO device: shaderDrawParameters=1 maintenance1=1 timeline=1`；C3 `vk-record: ok`、C4 present/代际、C5 C2 三角形仍过。
- 限制：只覆盖直连设备；通用 Ryujinx 的 0270/0271 是独立合同，不能互相替代。
### 2026-10-25 / ANDROID-DIRECT-VK-ENGINE-IMPORT / 导入 d2r-mobile Vulkan NVN 回放引擎（仅编译检查）

- 关联：C3/C5 后端复用；上级目录 `d2r-mobile`（MIT，jhaizhou）。
- 变更：
  - `graphics/third_party/d2r_vulkan_engine/` 导入 `dm/gfx/vulkan/engine` 20 个源文件、bcdec、测试与 `SOURCE.json`；附 `LICENSE`、`README.s2a.md` 记录来源提交 `e3756f8` 与改动。
  - 为 C++ 编译修正 `nvn_obj.h` 中 `bind_rec/draw_rec/draw_idx_rec` 的 `void*` 隐式转换（C 语义不变）。
  - 引擎适配 S2Arm 共享前端：`p_clear_tex.value_type`、copy-pitch/xtrace 同目录 include、移除旧 `OP_COPY_STRIDE` 分支（S2Arm 的 `p_copy_b2t` 自带 stride，回放尚未接线）。
  - 新增 `direct_vk_engine_check.sh`：NDK29/ARM64 API29 编译全部 20 个对象。
- 验证：`d2r Vulkan engine: 20 objects compiled (ARM64/API29), aggregate=6af3c8ff...`。
- 限制：只编译，不链接、不进 APK、无设备/着色器/游戏证据；引擎仍读离线 `.xgs`，C2 统一翻译尚未生成 bundle；`nvn_vk.c` 适配层未导入。
### 2026-10-25 / ANDROID-DIRECT-C3-STRIDE / T2B/B2T 行 stride 拷贝

- 关联：C3；`OP_COPY_T2B`/`OP_COPY_B2T` 的 row/image stride。
- 变更：tight 时单 region；带 stride 时逐行 `VkBufferImageCopy`（bufferOffset=y*row_stride，imageExtent 宽×1），避免驱动对 `bufferRowLength` 填充行的限制。
- 验证：真机 `copy-t2b-stride: pixel=255,0,0,255 pad=0`；tight T2B/B2T 仍过；C3 全部 ok。
- 限制：仅 RGBA8/4bpp、整图、无 view/offset；压缩/格式转换/局部/mip/layer 未接。
### 2026-10-25 / ANDROID-DIRECT-C4-WSI-GEN / 窗口代际 swapchain 重建

- 关联：C4；窗口代际/尺寸变化。
- 状态：部分完成。真机 WsiProbeActivity 首代 2712×1220，旋转后第二代 1220×2712；两代各 present 3 帧、present fence 全部经 track 退休（drain=0/retired=3），累计 callbacks=6。
- 变更：Activity 在 surfaceCreated/surfaceChanged 每次新代际发起 probe；manifest 接管 configChanges；脚本自动转屏并在退出时恢复原 rotation。
- 验证：`C4 WSI present fence + window generation: ok`。
- 限制：独立诊断 SurfaceView，不是游戏窗口/lease；无 backing 事务、无游戏首帧/呈现；旧 swapchain 资源在 probe 结束后销毁，未验证游戏级延迟退休。
### 2026-10-25 / ANDROID-DIRECT-C3-BT / 纹理↔buffer 记录拷贝

- 关联：C3；`OP_COPY_T2B`/`OP_COPY_B2T`。
- 状态：部分完成。真机 8×8 RGBA8 纹理清红→T2B guest 读回红；guest 改绿→B2T 纹理读回 `0,255,0,255`。
- 变更：`copy_image_buffer`（row/image stride、guest read/write、vkCmdCopyImageToBuffer/BufferToImage）；记录校验 view/flags/offset/部分区域拒绝。
- 验证：`copy-b2t: pixel=0,255,0,255`；C3 其余例仍过；未实现 opcode（BindUBO）显式 op=19。
- 限制：RGBA8/4bpp、整图、无 view；压缩/格式转换/局部/多 mip/layer 未接。
### 2026-10-25 / ANDROID-DIRECT-C2-TRIANGLE / C2 VS+FS 顶点输入三角形

- 关联：C2/C5；真实 Maxwell `Ald`（4 分量输入）+ `Ast`（位置 offset 0x70）→ C2 SPIR-V → 前端顶点缓冲/管线/draw。
- 状态：部分完成。真机 8×8 RT 上全屏三角形中心 `255,0,0,255`；C2 两个阶段都参与。
- 变更：
  - C2 测试加入 `Ald4`/`Ast4Pos` 与 `c2vspos.json`；C5 脚本提取 vs/fs。
  - 适配层新增 vertex buffer 管线（stride 16、location0 vec4）与 `register_program_vertex`；decoder draw 前绑定顶点缓冲。
  - support `s2a_point.x=3` 保留给点例。
- 验证：`nvn-frontend-c2tri: center=255,0,0,255`、ok；C2 point/fragment/tex/RT 例仍过。
- 限制：合成顶点属性/三角形，未接真实 `prog_t` 状态、UBO、纹理池、loader/HLE/game。
### 2026-10-25 / ANDROID-DIRECT-C2-VS-POINT / C2 VS+FS 在 Vulkan 点绘制

- 关联：C2/C5；真实 Maxwell VS/FS 都来自 C2。
- 状态：部分完成。C2 翻译的无属性 VS（gl_Position 常量 0,0,0,1、PointSize 取 support `s2a_point.x`）与常量红 FS，经前端 point 管线绘制，8×8 RT 中心 `255,0,0,255`。
- 变更：
  - 适配层 `register_program_topology`（POINT_LIST）；support UBO `s2a_point.x` 写 3.0。
  - C2 测试生成 `c2vs.json`（空 VS + FADD32I 红 FS）；C5 脚本提取 vs/fs 并跑 point draw。
- 验证：`nvn-frontend-c2vs: center=255,0,0,255`、ok；C2 fragment draw/tex/RT 例仍过。
- 限制：点在 NDC 中心、非逐顶点位置；真实 VS 顶点属性/三角形/UBO/loader/game 未接。
### 2026-10-25 / ANDROID-DIRECT-C5-C2DRAW / C2 翻译的 NVN 片元在 Vulkan draw 出红

- 关联：C2/C5；真实 Maxwell 片元指令 → 统一编译器 SPIR-V → 前端 draw。
- 变更：
  - C2 测试加入 `FADD32I Rd,RZ,imm` 合成片元（dest0..3=1/0/0/1，pred=PT），生成 `c2draw.json`。
  - 适配层非纹理程序补 set0/binding0 support UBO descriptor（C2 程序固定保留），draw 前绑定。
  - C5 脚本用 C2 CLI 编译 `c2draw.json`，提取 fs SPIR-V，交给前端 draw 测试；期望红。
- 验证：真机 `nvn-frontend-c2draw: center=255,0,0,255`、ok；RT/draw/tex 例仍过。
- 限制：VS 仍是 glslc 合成；C2 的 VS/UBO/顶点/真实游戏程序/loader/HLE 未接。
### 2026-10-25 / ANDROID-DIRECT-C5-TEX / 前端 ClearTexture + 采样 draw

- 关联：C3/C5；纹理/采样器/描述符。
- 状态：部分完成。真机前端 `ClearTexture` 清绿 2×2 纹理，8×8 RT 上采样 draw，中心 `0,255,0,255`。
- 变更：
  - 适配层 `register_program_textured`：combined image sampler set0/binding0、VkSampler、descriptor set；draw 前绑定。
  - `s2a_replay_draw` 增加 layout/descriptor；decoder 在 draw 前 bind。
  - `nvn_frontend_tex_test.c` + `tex.frag`；C5 脚本加纹理例。
- 验证：`nvn-frontend-tex: center=0,255,0,255`、ok；RT/draw 例仍过。
- 限制：程序/描述符仍由测试注册，非 `prog_t`/NVN 池真实绑定；无 UBO/顶点/index/loader/game。
### 2026-10-25 / ANDROID-DIRECT-C6-CANCEL / 真机软键盘取消路径

- 关联：C6；取消与确认分开。
- 验证：`direct_c6_ime_cancel.sh` 弹框后点“取消”，broker 回复 `Keyboard request completed: cancel, result=0`。
- 限制：仍只有 ASCII/确认/取消；中文组字、direct 游戏内文本、两轨未验。
### 2026-10-25 / ANDROID-DIRECT-C4-WSI / 真机 swapchain present fence 退休

- 关联：C4；真实 Android WSI。
- 状态：部分完成。独立 `WsiProbeActivity` 的 SurfaceView 上创建 native VkSwapchain（B8G8R8A8，1220×2712，6 图），present 3 帧；每帧 present fence 入 `vk_track` 单消费者，drain=0、submitted=3/retired=3/pending=0/failed=0、回调 3 次。
- 变更：`runtime/wsi_probe.cpp`（surface/swapchain/render pass/fence）、`WsiProbeActivity`、JNI `wsiProbe`、manifest、CMake；`tools/direct_c4_wsi_probe.sh`。
- 限制：独立诊断 Surface，不是游戏窗口/lease；窗口世代、backing 事务、首次呈现（#298）、direct 会话 WSI 未接。
### 2026-10-25 / ANDROID-DIRECT-C6-IME-DEVICE / 真机软键盘输入+确认通过

- 关联：C6；Android UI/IME。
- 状态：部分完成（generic preview）。真机 `S2Arm IME selftest` 对话框弹出，`adb input text abc` 写入，点“确定”后 broker 回复 `Keyboard request completed: ok, result=0`。
- 根因/修复：AlertDialog 窗口此前未取焦，`adb input` 不进入 EditText；`HostKeyboard` 显式 `clearFlags(FLAG_NOT_FOCUSABLE)` + `addFlags(FLAG_ALT_FOCUSABLE_IM)` 后文本可输入、按钮 enabled。
- 复现：`bash android/tools/direct_c6_ime_probe.sh`。
- 限制：仅 ASCII/确认；中文候选组字/候选选定、取消、direct 游戏内文本框、两轨与 Stop 单虚拟核未验。
### 2026-10-25 / ANDROID-DIRECT-C6-FOCUS / 输入框显式取焦与 IME show

- 关联：C6；设备诊断弹框。
- 变更：`HostKeyboard` 在 onShow 后 post 一次 requestFocus + `InputMethodManager.showSoftInput`，并记录 `Keyboard focus/ime`。
- 真机：`Keyboard focus=true ime=false`；`adb input text` 仍未写入文本，确定按钮 disabled，未完成回复。
- 结论：不改变 C6 未通过状态；焦点≠输入法可用。
### 2026-10-25 / ANDROID-DIRECT-C6-UI-SELFTEST / 设备软件键盘弹框诊断

- 关联：C6；UI broker/Activity/HostKeyboard。
- 状态：部分。真机 preview 包在 `s2arm.keyboard_selftest` extra 下，native broker 生成请求，HostKeyboard 弹出 `S2Arm IME selftest` 对话框（uiautomator 可见标题/副标题/EditText/取消/确定）；日志 `Keyboard request shown`。
- 未通过：`adb input text`/keyevent 未能让 EditText 取得文本（确定按钮仍 disabled），没有完成回复；不能算 IME 确认/取消通过。
- 变更：`s2a_android_ui_selftest` + JNI `uiSelftest` + MainActivity debug extra；仅诊断，不影响正常启动。
- 限制：自动化焦点/输入未解决；direct 游戏内文本框未触发；中文候选组字未验。
### 2026-10-25 / ANDROID-DIRECT-C5-DRAW / NVN 前端 draw 到 Vulkan

- 关联：C3/C5；`BindProgram`+`DrawArrays`。
- 状态：部分完成。真机用 NVN 公开 API 录 SetRT+BindProgram+DrawArrays，适配层预扫描建 render pass/framebuffer、测试注册管线并 draw，读回中心 `143,143,0,255`。
- 变更：
  - 适配层程序 registry（测试注册 VS/FS SPIR-V、render pass、pipeline）；`prescan_draws` 解析记录并建 view/framebuffer。
  - decoder 接受前端紧凑 `p_draw`（非间接只录到 `ind` 前），不再要求完整 56 B。
  - `nvn_frontend_draw_test.c`，C5 脚本加 glslc 合成 shader 与 draw 例。
- 验证：真机 `nvn-frontend-draw: center=143,143,0,255`、ok；C3 `vk-record: ok` 回归。
- 限制：program/管线由测试注册，不是 `prog_t` 真实 shader 翻译；纹理采样/UBO/顶点/显示/loader/game 未接。
### 2026-10-25 / ANDROID-DIRECT-C5-RT-INT / 整数渲染目标 clear 语义

- 关联：C3/C5；`OP_CLEAR_COLOR` 在整数附件上的类型转换。
- 变更：`gpu_clear_image_color` 按 VkFormat 选择 float/int32/uint32；SINT 用 lrintf、UINT 钳 0 后 llrintf；不再把浮点位直接写给整数附件。
- 验证：真机同一前端流程，RGBA8 `64,128,191,255`；RGBA8I `-128,-1,0,127`。
- 限制：仍只有 RT clear，无采样/程序/draw/present/loader/game。
### 2026-10-25 / ANDROID-DIRECT-C5-RT / NVN 前端 RT clear 到 Vulkan 并读回

- 关联：C3/C5；前端 `SetRenderTargets`+`ClearColor`。
- 状态：部分完成。真机 NVN 公开 API 建 8×8 RGBA8 纹理并设为 RT，清除后经适配层 VkImage 读回 `64,128,191,255`。
- 变更：
  - `vk_nvn_adapter.c`：纹理 registry（NVN format→VkFormat、device-local VkImage）、`mtl_tex_init/release`、`s2a_nvn_adapter_read_texture`、记录回放传纹理表。
  - `s2a_replay_texture` 增加 `serial`；记录里的 snapshot 指针与注册对象按 serial 匹配，不依赖副本地址。
  - `nvn_frontend_rt_test.c`，C5 脚本同时跑 CPU/提交/RT 三例。
- 验证：真机 `nvn-frontend-rt: pixel=64,128,191,255`、`ok`；C3 `vk-record: ok` 回归。
- 限制：只有 RT clear；纹理采样/程序/管线/draw/present/loader/游戏未接；`read_texture` 是测试/诊断接口。
### 2026-10-25 / ANDROID-DIRECT-C2-AOT-DEVICE / 设备 NativeAOT 编译与离线逐字节一致

- 关联：C2/C7；`s2a_direct_compile_v1` 设备调用。
- 状态：完成 C2 的设备调用证据。
- 变更：
  - `bridge.cpp` 新增 JNI `directCompile(byte[])`，同步调用 NativeAOT `s2a_direct_compile_v1`，emit 复制到 native vector；失败返回 null。
  - `MainActivity` 在 `s2arm.direct_compile_selftest` extra 下读 asset `direct-compile-request.json`，后台调用并记录字节数/SHA-256；`NativeBridge` 声明。
  - `tools/direct_c2_aot_probe.sh`：真机跑 selftest，与离线 CLI 结果比对。
- 验证：真机 `direct compile: rc=0 bytes=26087`，`sha256=8848...`；离线 CLI 同 26087 B / 同 SHA；`direct AOT compile: byte-identical (26087 B)`。
- 限制：合成请求只含 VS/FS 与 support layout；真实资源型 shader/真实 NVN 控制段尚未进请求。
### 2026-10-25 / ANDROID-DIRECT-C5-SUBMIT2 / 前端 buffer copy/update 也走 Vulkan

- 关联：C3/C5；`CopyBufferToBuffer`、`UpdateUniformBuffer` 记录。
- 验证：真机同一提交内 ClearBuffer→CopyBufferToBuffer→UpdateUniformBuffer，回读 `clear=a5a5a5a5 copy=a5a5a5a5 uniform=0110`，`nvn-frontend-submit: ok`。
- 限制：仍只有 buffer 记录；RT/draw/texture/present/loader/游戏未接。
### 2026-10-25 / ANDROID-DIRECT-C5-SUBMIT / NVN 前端录制 → Vulkan 执行 → guest 回读

- 关联：C3/C5；共享前端 `QueueSubmitCommands`。
- 状态：部分完成。真机用 NVN 公开 API 初始化设备/队列/内存池/命令缓冲，录制 `ClearBuffer`，`QueueSubmitCommands` 经 `mtl_exec` 走 Vulkan decoder（`vkCmdFillBuffer`）回写 guest 内存并核对 `0xA5A5A5A5`。
- 变更：
  - Android 跳过 Apple big-stack/prof 包装，`nvn_lookup` 直返强类型实现。
  - `vk_nvn_adapter.c`：内存池登记、guest read/write 回调；`mtl_exec` 用命令句柄所在池范围调用 `s2a_record_replay`，失败明确报错，不猜范围。
  - `nvn_frontend_submit_test.c` + `direct_c5_nvn_test.sh` 同时跑 `t_nvn_fill` 与提交回读。
- 验证：真机 `t_nvn_fill ... 通过`；`nvn-frontend-submit: clear value=a5a5a5a5`，`ok`。
- 限制：只覆盖 buffer clear；RT/draw/texture/present/loader/服务/游戏未接；不能报 C5 完成。
### 2026-10-25 / ANDROID-DIRECT-C5-NVN-RUN / 共享 NVN 前端在 Android 真机运行 CPU 测试

- 关联：C5/C7；共享前端 `hle_nvn.c`。
- 状态：部分完成。前端 536 名、530 实现（509 语义 + 21 空操作）在 Android 真机初始化，`t_nvn_fill` CPU 侧语义通过；**记录→Vulkan 回放/呈现/loader/游戏未接**。
- 变更：
  - Android `nvn_lookup` 直接返回强类型实现（不走 Apple 汇编 thunk）；跳过 Apple big-stack/prof 包装器。
  - `nvn_names_android.c` 由 `names.txt` 生成 536 名表；`vk_nvn_adapter.c` 提供 `nvn_mtl` 接口与内存池登记，`mtl_exec` 明确失败（不猜测命令流范围）；`frontend_test_host.c` 是测试宿主桩。
  - `tools/direct_c5_nvn_test.sh`：NDK 编译并推送 `t_nvn_fill` 到真机。
- 验证：真机 `t_nvn_fill ... 通过`；设备 Redmi 22081212C/Adreno 730。
- 限制：仅是 CPU 接口/对象语义；GPU 执行仍走独立 C3 记录用例，尚未由前端提交驱动；direct 游戏链路未接。
### 2026-10-25 / ANDROID-DIRECT-C4-PENDING / 在途退休拒绝

- 关联：C4/#291；`vk_track` 生命周期。
- 变更/验证：真机 `vk-track` 先登记未完成 present fence，`destroy` 被拒绝；fence 完成、`wait_all` 后再 destroy 成功；输出 `track-pending: destroy refused while in flight, accepted after completion`。
- 限制：仍不是真实 swapchain present fence；只证明账本不提前销毁。
### 2026-10-25 / ANDROID-DIRECT-C5-FRONTEND-PORT / 共享 NVN 前端 Android 编译层

- 关联：C5/C7 前置；共享前端 `graphics/nvn/gfx/nvn/hle_nvn.c`。
- 状态：仅编译通过（ARM64 对象 344,968 B）。未链接 `nvn_mtl` 替代层、未运行、未接 loader/窗口/服务；不能声称 direct 可启动。
- 变更：
  - `hle_nvn.c`：`NVN`/`NVN_NOPROTO` 的注册段在 Android 改成 ELF `swnvn`；Apple 仍为 `__DATA,swnvn`。
  - Android 不接 Apple 的线程 QoS/CPU 指令/功耗采样：`thr_instr`/`thr_counts`/`thr_sys_ns` 返回 0，`tsummary`/`power_line` 直接返回，不输出伪造读数。
  - `android/native/nvn/compat/`：Mach time/VM/thread 类型、CommonCrypto（接项目 SHA-256）、CFDictionary 指针表、`getsectiondata` 走 `__start/__stop_swnvn`。
  - `portable.c`：SHA-256 与 CFDictionary 实现；`vm_remap` 明确返回失败（Android alias 映射未实现，不伪造成共享页）。
  - `tools/direct_nvn_port_check.sh`：NDK 编译前端与 portable 对象。
- 验证：`NVN frontend Android compile: ok`；覆盖表仍 536 名/48 opcode。
- 限制：这只是可编译性，不是 C5 通过；无 `nvn_mtl` Vulkan 适配、无 loader/服务/窗口接入、无游戏运行。
### 2026-10-25 / ANDROID-DIRECT-C7-GENERIC2 / 通用模式实际进局

- 关联：C7 回归前置；不是 direct。
- 状态：generic 可玩回归加深。
- 真机：新 APK（含 UI session/span、C3/C4 代码）启动 Diablo III，片头后按 A 进入已存档角色，画面出现“悬赏任务：被缚的萨满 / 找到通往杀戮广场的传送门”，HUD/技能/摇杆正常；进程无 FATAL/AndroidRuntime。
- 限制：仍是 Ryujinx GPU generic；没有 direct 包、NVN→Vulkan 游戏执行、首装/缓存/故障下局验收。不得据此报首版闭环。
### 2026-10-25 / ANDROID-DIRECT-C2-CONTROL / 编译入口消费控制段 compute 元数据

- 关联：C2/#247/#198；控制段 +0x748/+0x754。
- 状态：完成一小项。compute 请求的 `computeState` 必须与控制段一致；缺字段/零线程组/超 1024/超 64 KiB/不一致均拒绝，不回填 1×1×1。
- 变更：`DirectShaderCompiler.ValidateComputeControl`，与 `native/direct/control.c`、`merge_extract.py:cs_facts` 同口径；测试生成真实控制段并覆盖 mismatch/zero 负例。
- 验证：`direct-compiler: ok (108 checks)`；CLI 字节一致与 spirv-val 仍过。
- 限制：只校验，不用它单独驱动翻译；graphics 控制段/C1 仍未进请求。
### 2026-10-25 / ANDROID-DIRECT-C6-SPAN / 输入框组字结束刷新提交状态

- 关联：C6；D2R 经验中的 composing span 选定不触发 TextWatcher。
- 状态：部分完成。代码与 APK 编译通过；真机中文候选组字/选定未验。
- 变更：`HostKeyboard` 给 EditText 加 `TextWatcher` 与 `SpanWatcher`，只刷新确定按钮 enabled，不改正在组字的文本；提交时仍用 `valid(text,min,max,mode)` 复核。
- 验证：Gradle `:app:assembleDebug` 成功；新 APK generic 冷启动无 FATAL。
- 限制：未在真机用中文 IME 选择候选验证；direct 路径文本框未触发。
### 2026-10-25 / ANDROID-DIRECT-C3-COPY / 记录驱动纹理拷贝

- 关联：C3；`OP_COPY_T2T`。
- 状态：部分完成。整图、无 view、无 flags 的 T2T 真机通过；带 view/局部/flag 明确拒绝；B2T/T2B 未接。
- 变更：`gpu_copy_image`（GENERAL layout 转换 + `vkCmdCopyImage` + 完成屏障）；`OP_COPY_T2T` 校验源/目标注册、尺寸与区域；测试用 CLEAR_TEX 写红再拷贝读回。
- 验证：真机 `copy-t2t: pixel=255,0,0,255`，`vk-record: ok`；未实现 opcode（CopyB2T）显式 `UNSUPPORTED op=31`。
- 限制：无 view/mip/layer、格式转换、stride、压缩格式；不是完整 NVN copy 语义。
### 2026-10-25 / ANDROID-DIRECT-C3-DISPATCH / 记录驱动 compute

- 关联：C3；`OP_BIND_PROGRAM` + `OP_DISPATCH`。
- 状态：部分完成。真机记录驱动 compute SSBO 通过；program 资源/描述符仍由测试注册，未解析 NVN program/pool。
- 变更：`s2a_replay_dispatch`（program_key→VkPipeline/VkPipelineLayout/VkDescriptorSet）；`OP_DISPATCH` 校验 group 计数、拒绝 indirect、绑定已注册管线并 `vkCmdDispatch`；未注册/无 program 明确拒绝。
- 验证：真机 `vk-record: ok`，`dispatch-record: first=1 last=190 bad=0`；draw/RT/clear 各例仍过；未实现 opcode（CopyT2T）显式 `UNSUPPORTED op=35`。
- 限制：compute 描述符是测试手工绑定；NVN 资源/池/描述符解析与真实游戏 dispatch 未接。
### 2026-10-25 / ANDROID-DIRECT-C6-SESSION / UI broker 绑定真实 runtime session

- 关联：C6；替代固定 `s2a_ui_broker_create(1)`。
- 状态：部分完成。broker 可在 HLE 启动前绑定真实 session；有在途请求时拒绝换绑；旧 broker 销毁后按新 session 重建。direct 游戏内弹框/composing watcher 未验。
- 变更：
  - `host_ui_android.c`：`s2a_android_ui_bind_session(session)`；默认仍为 1 供旧测试；`attach` 懒创建；`take/complete/stop/detach` 全部用绑定值。
  - `host_ui.c/h`：新增 `s2a_ui_broker_pending`（只看 QUEUED/DELIVERED），换绑只被真实在途请求阻止，不被“UI 已可用”阻止。
  - `runtime.c`：启动时以弱符号调用 bind，避免宿主 runtime 单测依赖 Android UI。
  - `tests/ui_session_test.c`：绑定→attach→请求→在途换绑拒绝→取消→换绑→取/完成→stop 负例。
- 验证：`android_ui_session` CTest 通过；新 APK 安装后 generic Diablo III 冷启动无 FATAL，GPU 循环恢复。
- 限制：未在 direct 模式触发真实软件键盘；composing span watcher、两轨输入、Stop 单虚拟核仍未做。
### 2026-10-25 / ANDROID-DIRECT-C4-TRACK / 单消费者退休账本

- 关联：C4；batch 退休与 present fence 入口。
- 状态：部分完成。单消费者线程按提交顺序等待 fence、回调并销毁；present fence 可入同一队列；真实 swapchain/present 仍未接。
- 变更：`vk_track.{h,c}`：有界队列 1024、唯一消费者、`submit` 持有 fence、`present_fence` 接管已提交 fence、`wait_all`/`stats`/`destroy`（有在途则拒绝销毁）；回调在消费者线程执行，禁止重入 track。
- 验证：真机 `vk_track: ok`，4 个 batch 顺序 1,2,3,4 退休，最后 fill 值正确，submitted=4/retired=4/pending=0/failed=0。
- 限制：present fence 用例是手工提交的 fence，不是真实 `vkQueuePresentKHR`；WSI/窗口世代/backing 仍未接。
### 2026-10-25 / ANDROID-DIRECT-C3-DRAW / 记录驱动 render target clear 与 draw

- 关联：C3；共享记录 `OP_SET_RT`/`OP_CLEAR_COLOR`/`OP_BIND_PROGRAM`/`OP_DRAW`。
- 状态：部分完成。整 RT/全通道 clear 与合成管线 draw 真机通过；program 资源/状态/顶点/UBO/纹理仍未解析。
- 变更：
  - `vk_record.c`：`OP_SET_RT` 保存当前颜色目标（无 view 的整目标）；`OP_CLEAR_COLOR` 按当前目标调 `vkCmdClearColorImage`，部分 mask/带 view 明确拒绝；`OP_BIND_PROGRAM` 选已注册管线；`OP_DRAW` 用当前 RT 的 render pass/framebuffer + `vkCmdDraw`，间接/多重绘制明确拒绝。
  - `s2a_replay_draw`：program_key + rt_key → VkPipeline/VkRenderPass/VkFramebuffer；测试用真实 nvn_obj.h 记录驱动。
  - `vk_record_test.c`：新增 8×8 RT clear（rt0=26,51,77,255；rt1=102,128,153,255）与 draw（中心 143,143,0,255，8×8 像素中心 uv=0.5625 手算）。
- 验证：真机 `direct_c3_vk_probe.sh` 全部 `vk-record: ok`；未实现 opcode（Dispatch）显式 `UNSUPPORTED op=27`。
- 限制：draw 的 program 来自测试注册管线，尚未解析 `prog_t`/绑定状态/顶点/纹理；没有真实 NVN 程序，不证明游戏出图。
### 2026-10-25 / ANDROID-DIRECT-C7-GENERIC / 新 APK 通用模式回归

- 关联：C7 回归前置；不是 direct 通过。
- 状态：通用模式回归通过；direct 仍未可玩。
- 构建：Docker `s2arm-android-build:1`，`S2ARM_ANDROID_CS_SERVICES=static`；Gradle 离线（隔离缓存、清理锁文件）`BUILD SUCCESSFUL`，产出 `android/app/build/outputs/apk/debug/app-debug.apk`（48,641,702 B）。设备上原包签名与宿主 `~/.android/debug.keystore` 一致，用 apksigner 重签后 `adb install -r` 成功。
- 真机：Redmi 22081212C / Android 16 / Adreno 730；启动 `org.s2arm.game.t01001b300b9be000/org.s2arm.android.MainActivity`，Diablo III 2.7.7.92380 片头 “PRESS ANY BUTTON” 出图，无 FATAL/AndroidRuntime 崩溃。
- 日志：`[s2a] GPU 循环 5s：... frame 3658、present 212（119）`、随后 `frame 3801、present 320（255）`；首段约 20 s 内进入片头（此前通用模式记录为约 22 s 首帧）。
- 限制：
  - 这是 generic（Ryujinx GPU）路径，不证明 direct/NVN→Vulkan。
  - 未做完整游戏进局、存档、视频、音频、IME、正常停止与下次 direct 失败回 generic；不能报“首版完整可玩”。
  - APK 仅用于本机回归，不入库。

### 2026-10-25 / ANDROID-DIRECT-C4-FENCE / fence 完成与 batch 退休

- 关联：C4；单队列完成证据。
- 状态：部分完成。fence 提交/等待/超时与 batch 退休 API 已实现并编译；真机执行待设备恢复；present fence/WSI 退休、backing、窗口世代未接。
- 变更：`runtime/direct/vk_sync.{h,c}` 提供 `s2a_vk_completion_submit/wait/destroy`；wait 成功才销毁 fence 并清 pending，超时保持 pending；未提交/重复提交明确失败。`tests/vk_sync_test.c` 验证两批 GPU fill 完成顺序与未信号 fence 超时。
- 验证：设备恢复后真机执行 `vk-sync: ok`：两批 fill 按 1→2 完成，未信号 fence 1 ms 超时为 pending；NDK 编译通过。
- 限制：fence 完成不等于 scanout 完成；present fence 要等真实 swapchain/window owner。

### 2026-10-25 / ANDROID-DIRECT-C3-RECORD / NVN 记录→Vulkan 回放首片

- 关联：C3；共享记录 `nvn_obj.h`（含 nvn/fill-all 的 BIND_BUF_DEFER / CLEAR_TEX 三态）。
- 状态：部分完成。控制流、CLEAR_BUF、COPY_B2B、UPDATE_UB 已在真机执行并回读；CLEAR_TEX 解码已写、真机执行待设备恢复；draw/dispatch/资源对象仍未接。
- 变更：
  - `runtime/direct/vk_record.{h,c}`：按真实 `op_hdr`/payload 走记录，支持 END/JUMP/CALL（深度 8、目标范围检查）、CLEAR_BUF（vkCmdFillBuffer+回写）、COPY_B2B（staging copy+回写）、UPDATE_UB（CPU 写 guest）、CLEAR_TEX（整 mip/全通道，按 CLEAR_TEX_FLOAT/UINT/INT 选 VkClearColorValue 成员，局部/部分通道明确拒绝）。
  - 未实现 opcode 返回 `S2A_RECORD_UNSUPPORTED` 并带 opcode，不跳过、不伪造成功。
  - `tests/vk_record_test.c`：用 nvn_obj.h 构造命令流，验证 CALL 返回/JUMP 跳过、guest buffer 内容、unsupported 负例；CLEAR_TEX 的 float/signed 两态与读回比较。
  - `direct_c3_vk_probe.sh` 同时构建/推送/执行 `vk_micro` 与 `vk_record`。
- 验证：
  - 真机（设备在线时）：`vk_record` 输出 `executed=9 (ok)`、`unsupported op=14`、`vk-record: ok`；`vk_micro` 五项全过（见上一条）。
  - 设备恢复（新 IP `192.168.31.91:5555`，同机）后真机执行：`clear-texture: unorm=64,128,191,255`、`sint=-128,-1,0,127`，`vk-record: ok`。
- 限制：
  - CLEAR_TEX 依赖调用方注册 `const tex_t*→VkImage`；尚未解析 tex_t/pool/view，局部区域与通道 mask 明确不支持。
  - 记录中的 draw/dispatch/RT/pipeline 等未接；不能把 buffer 回放当作游戏出图。

### 2026-10-25 / ANDROID-DIRECT-UPSTREAM-REUSE / 复用清单、控制段 parser 与 C3 GPU 微例

- 关联：C2/C3/C4/C7；上游复用报告 2026-10-25。
- 状态：部分完成。复用项已并入验收表；控制段 parser 与真机 GPU 原语通过；NVN 记录→Vulkan decoder 仍未实现。
- 上游核对：候选 `2d9c7704` 非 main/integration 祖先；报告固定 main `59b5784e`，本轮 fetch 到 `777962e5`；只 cherry-pick 需要的提交并保留作者：
  - `a887b6aa`（原作者姜海舟，#247/#198 控制段 +0x748/+0x754）；
  - `200c7ed8`、`5ddc49d1`（原作者 Yuehao Wang，#281/PR334 rt_recover）。
- 变更：
  - 新增 `runtime/direct/control.{h,c}`：compute 控制段 local/shared 解析，16 字节对齐、1024 调用/64 KiB 上限、缺失不填默认；与 `merge_extract.cs_facts` 逐例对拍 51 例。
  - 新增 `runtime/direct/vk_device.{h,c}` 与 `tests/vk_micro_test.c`：真机 Vulkan 设备 owner + clear/signed clear/draw/compute/copy/readback 微例；`tools/direct_c3_vk_probe.sh` 一键编译/推送/执行。
  - 新增 `docs/direct-mode-acceptance.md`：C0–C7、固定身份、复用项、负例与复现命令；上游 #273/#287/#281/#172/#208/#274/#291 等按“采用/不采用/未验证”登记。
- 验证：
  - `t_merge_extract.py`：18/18；`t_rt_recover.py`：25/25。
  - `direct_c2_control_check.sh`：51 例 0 不一致。
  - 真机 Redmi 22081212C / Adreno 730 / Vulkan 1.1.128：`direct_c3_vk_probe.sh` 输出 clear-rgba8 `64,128,191,255`、clear-sint8 `-128,-1,0,127`、draw-gradient center `129,129,0,255`、compute-ssbo `bad=0`、buffer-copy `bad=0`；device maintenance1=1。
- 限制：
  - 这些是执行原语，不是 NVN 记录回放；C3 的 decoder、对象生命周期（#291）、首次呈现（#298）、双池/同址重建未做。
  - present fence/WSI 只验证设备能力与 device 创建，未验证真实 present 完成；C4 未开始。
  - AOT 仅在静态库符号层验证 `s2a_direct_compile_v1`，设备上未调用。
  - Gradle 联网解析 Maven 依赖在本机失败；改用隔离的 Gradle 缓存离线构建成功（`app-debug.apk` 48.6 MB，含静态 AOT/OpenSSL），并用宿主 debug key 重签安装（设备上原包同 key）。静态 AOT 归档中 `s2a_direct_compile_v1` 存在；最终 `libs2arm_android.so` 因尚无 native 调用点未从归档拉入该成员，等 provider 接线后再验。

### 2026-10-25 / ANDROID-DIRECT-NVN-SYNC / 共享 NVN 前端候选基线 nvn/fill-all 合入核对

- 关联：C0/C3 前置；共享 NVN 前端、记录布局与入口覆盖。
- 状态：候选基线已本地合入；不是合入 main/integration 的官方基线。
- 核对：
  - `2d9c7704` 不是 `origin/main`、也不是 `origin/android/integration` 的祖先；
  - 本机 `tools/train.sh` 状态目录为空（无该分支队列记录），GitHub API 本轮不可达，不能声称已进列车或已合入；
  - 按候选基线用合并提交同步（`28dedd68`），保留原作者提交与署名；唯一冲突 `docs/性能与开发测试经验.md` 保留 #270 整段。
- 变更：
  - 带入 `nvn_obj.h` / `hle_nvn.c` / `nvn_mtl.m` 的批量补齐、GL/Vulkan 头与 NVN 覆盖对账工具；
  - Android C0/C1/C2 代码未改写；覆盖表重新生成。
- 验证：
  - `compat/verify.sh`：上游 + 253 个补丁 = 树内源码，一致。
  - `tools/nvn_cover_table.py --check`：536 名；入口分类 **498 已实现 / 11 部分 / 21 空操作 / 6 未实现**（与上游 `nvn_func_table.classes()` 一致）；48 个记录 opcode 都有 Metal case。
  - 新增 `tools/nvn_record_consistency.py`：12 项源码一致性检查通过（BIND_BUF_DEFER 录制/回放、CLEAR_TEX_FLOAT/UINT/INT 三态、旧 is_uint 已移除、opcode 覆盖）。
- 限制：
  - 这只证明共享记录与 **Metal** 回放一致；`nvn-vulkan-semantics-v1.json` 当前为空（Vulkan executed 0），不能把入口分类或 Metal 单测当作 Android Vulkan 通过。
  - 498/11/21/6 是入口形态分类，逐项 Vulkan 语义仍须在 C3 用真实 GPU 用例登记。

### 2026-10-25 / ANDROID-DIRECT-C2 / 统一直连着色器编译器（离线 CLI 与 NativeAOT 同一份）

- 关联：C2 / DV2；实施契约 §4.1–§4.3。
- 状态：部分完成。统一翻译器、严格协议、静态 accessor、四 set 分配、SPIR-V 反射核对、CLI 与 AOT 导出已实现并过主机检查；真实 NVN 控制段解析、资源型真实 shader、设备上 AOT 调用与 C3 GPU 语义未完成。
- 变更：
  - 新增 `graphics/tools/direct/compiler/` 类库 `S2A.DirectCompiler`：严格 JSON（重复键/未知字段/限额拒绝）、`DirectProfile`（EffectiveProfile 全字段，无默认）、`DirectGpuAccessor`（显式实现 IGpuAccessor 全部 57 个方法 + ILogger，缺失即 MissingFact，记录 method/args/value/source）、`DirectShaderCompiler`（VS/FS/CS，锁版本 Ryujinx translator，SPIR-V 1.3/入口/descriptor 集合与绑定来源核对，支持缓冲布局从 `SupportBuffer` 计算并哈希）。
  - 四 set 分配器：set0/binding0 固定 SupportBuffer（`ResourceReservationCounts(false,false)` 保留 1），其余 UBO/SSBO/texture/image 按翻译调用顺序在各自 reserved 后连续分配；`CreateExtraSet=-1`；按 stage 与类别核对上限。
  - 结果 `s2a-direct-program-v1`：transport/session/generation/requestId 与 content 分离；content 含 identity、SPIR-V、反射、绑定、support layout、查询依赖与 state read；`contentHash` 只覆盖 content，同一快照跨传输身份逐字节一致。
  - 离线 CLI `compile --request --output`：成功才 rename 发布，失败不留目录。
  - NativeAOT：`android/core-runtime/DirectCompileNative.cs` 导出 `s2a_direct_compile_v1`（同步 emit、异常转返回码、不跨边界抛异常）；AOT 工程引用同一编译器工程并 root；`s2a_direct.h` 增加该 provider 原型。
  - Ryujinx 补丁 `0259-direct-compiler-internals`：向 `S2A.DirectCompiler` 与 `libs2a_cs` 开放锁版本 ShaderCache/特化状态内部类型；仍为编译期静态类型，无 DispatchProxy/反射造类型。
- 验证：
  - `bash graphics/tools/direct/compiler/check.sh`：106 项主机断言通过；合成 VS/FS 与 CS 走真实 translator；同一请求两次 CLI 输出逐字节相同（26087 B）；坏请求无输出；`spirv-val --target-env vulkan1.1` 对 vs/fs 干净；support layout 2608 B、依赖 62 条；附件类型变体改变 contentHash；GetCode/CB1 越界与未知纹理事实均为 MissingFact；四 set 分配与上限负例通过；NativeAOT C ABI shim 与命令内编译结果逐字节一致。
  - NativeAOT 静态库（Docker `S2ARM_ANDROID_CS_SERVICES=static`）生成后 `llvm-nm` 可见 `s2a_direct_compile_v1` 与 `s2a_android_services_start_v2`（证据在构建产物，不入库）。
- 限制：
  - 合成 shader 只用于测试；真实 NVN 控制段还没有 C 解析器，控制段的 C1 之外字段未消费（C3）。
  - 资源型 shader（真实 UBO/纹理/SSBO 翻译）尚无 fixture；当前只用 accessor 直接验证纹理事实与分配器。
  - AOT 只在链路/符号层验证，尚未在设备上从 native 调用 `s2a_direct_compile_v1`；因此不能报“NativeAOT 设备调用”通过。

### 2026-10-25 / ANDROID-DIRECT-C1 / relocation 前模式选择、attempt 故障锁与 v2 启动

- 关联：C1 / DV1；实施契约 §2.1、§2.2、§8。分支 `android/direct-mode-d2r`。
- 状态：部分完成。选择事务、故障锁、v2 请求/服务入口、artifact graphics feature 已实现并过主机与 ARM64 合成验证；真实 Vulkan provider、NativeAOT direct 合成与真机包路径未接，不能报 C1 全绿。
- 变更：
  - 新增 `native/direct/{json,graphics,sha256,attempt,selection}.c`：
    - 严格 JSON（UTF-8/代理对/重复顶层键/数值/1 MiB/深度/尾随字节负例）；
    - `graphics.v1.json` 只接受 `s2a-graphics-v1` / `nvn` / `vulkan-direct` / directABI=1 / `s2a-direct-compile-v1`，校验 titleId、`sha256-…` 身份与 1..8 个 profileHash；
    - attempt/failure 固定写入 `<state>/graphics/direct/<implementationKey>/`，temp→fsync(file)→rename→fsync(parent)，测试注入每个落盘步骤失败；
    - 选择器：手动 generic 优先；AUTO 在无描述/无 provider/遗留 attempt/Prepare 失败/attempt 写失败时 commit 前 generic；手动 direct 失败不偷偷降级；commit 后失败保留 attempt 并结束本进程；device/queue/worker/consumer 计数随 selection 发布。
  - runtime v2：`s2a_android_runtime_run_v2` 在 `load_modules*` 前解析描述、拒绝外壳夹带 graphics table/mode、按 titleId=program_id 校验、发布唯一 selection；direct 无 NVN 前端时硬失败。v1 入口继续只接受 version=1。
  - services v2：托管 `s2a_android_services_start_v2` 校验 80 字节布局/表/身份；generic 完整复用 v1 组合；direct 在当前构建明确 `Provider` 失败，不建立第二套 generic GPU。
  - 外壳：`BootContract` 接受 `requiredFeatures=["org.s2arm.graphics.v1"]` + 同 extension（固定 manifest 路径、SHA-256、长度），校验并读出描述；旧 artifact 不变。GameSession/MainActivity/JNI 传 `modePreference` 与描述字节；`s2arm.graphics_mode` 仅冷启动生效。
  - `plat_android.c`：`s2a_gfx_mode`/`s2a_direct_lookup` 读冻结 selection；direct 已提交却没有前端时直接终止，避免落回 SDK nvn。
- 提交：本次提交（未推送）。
- 验证：
  - 主机 CTest：`android_direct_{abi,json,graphics,attempt,selection}`、`android_plat`、`android_memory` 全过。
  - `core-link/runtime-tests/run.py`：25 项既有 v1 用例 + 11 项 v2/故障用例全过；负控（删掉 Ready 检查）被拒绝。
  - ARM64 真机 22081212C / Android 16：`tools/direct_c1_probe.sh` 跑 JSON/graphics/attempt/selection + 11 个 runtime v2 用例，全部通过；attempt 在 /data 上真实 fsync/rename。
  - `dotnet build android/cs/aot/S2A.Android.Aot.csproj` 0 error；`S2A_TEST_NO_NATIVE=1 bash android/test.sh` Java/契约全过。
  - 既有 `android/test.sh` 仍是 16/17 CTest（`android_nativeaot_startup_roots` 为 binutils 2.47 BFD 既有问题），本轮未把它算绿。
- 限制：
  - 测试 provider 不建 Vulkan device；真实设备 Prepare/queue/worker 计数在 C3 交付。“不支持→generic”目前证明的是事务与代码路径，不是某款游戏的 GPU 兼容结论。
  - 未产出带 graphics feature 的真实包；BootContract 新分支只有合成包测试，未装机。
  - direct services 仍是明确失败；NativeAOT 编译器登记、跟踪 adapter、Activate 在后续合同项实现。
  - v2 描述里的 profiles 只做非空/身份校验，profile 与真实设备能力的匹配在 C2/C3。

### 2026-10-25 / ANDROID-DIRECT-C0 / 直连 ABI v1 双端布局、校验与 ARM64 真机实调

- 关联：C0 / DV0；实施契约 §2.1、§2.3、§3。分支 `android/direct-mode-d2r`。
- 状态：部分完成。ABI/布局/校验/调用约定与 API、记录覆盖表已实现并验证；共享 NVN 前端的 ELF 编译与真机实调未做，不能把本节当作 C0 全绿。
- 变更：
  - 新增 `android/native/direct/s2a_direct.h`：table 64 / status 24 / 返回码 / blockers / 编译与 profile/video 导出原型，全部 offset 静态断言；新增 `s2a_direct_abi.c` 的唯一校验实现（多端共用，禁止各写宽松版）。
  - `services_abi.h` 增加 80 字节 v2 request（v1 前缀 version=2，graphics 偏移 64 / mode 72 / flags 76）与 `s2a_android_services_start_v2` 声明；`runtime.h` 增加 160 字节 runtime v2（含 v2 services、模块来源、graphics descriptor、modePreference）与静态断言。v1 入口与 generic 行为未改。
  - 托管镜像 `core-runtime/DirectAbi.cs` 与同规则校验；`direct-abi-tests` 输出与 C 端同 schema 的布局 JSON。
  - 覆盖表工具 `tools/nvn_cover_table.py` 从 `names.txt` / `hle_nvn.c` / `nvn_obj.h` / `nvn_mtl.m` 生成 `contracts/direct/nvn-cover-v1.json`；源码变化未同步即失败。
  - 检查入口 `tools/direct_abi_check.sh`（主机 C、托管 C#、NDK ARM64、有设备则真机执行、逐字段对拍）与 CTest `android_direct_abi`。
- 提交：本次提交（未推送）。
- 验证：
  - `bash android/tools/direct_abi_check.sh`：主机 C、托管 C#、ARM64（NDK 30.0.16248370）三份布局完全一致；`direct-abi compare: ok (c, cs, arm64; 6 sizes, 22 offsets)`；真机 22081212C / Android 16 执行窄整数、uint32 低 8 位、float/double、四 float HFA、12 参数栈传递、回调与 NVN 风格 draw，手算值全等。
  - `ctest -R android_direct_abi`：通过。
  - `python3 tools/nvn_cover_table.py --check contracts/direct/nvn-cover-v1.json`：536 个名字（452 个有实现 / 84 个未实现），48 个记录 opcode 全部有 Metal 回放分支；无重复实现、无表外名字。
  - 整仓 `android/test.sh` 基线：15/16 CTest，`android_nativeaot_startup_roots` 仍是本机 binutils 2.47 BFD 断言失败（既有工具链问题，非本改动）。
- 限制：
  - 覆盖表只做静态清点，“有实现/有 Metal 分支”不等于 Android Vulkan 语义已实现，也没有把函数分成只读/无副作用/未支持四类；那是后续 NVN adapter 的验收内容。
  - ARM64 探针证明的是 AAPCS64 调用约定与头文件布局，不是 `graphics/nvn/hle_nvn.c` 以 ELF 编入并走现有 xstack；Mach 依赖替换和 ELF thunk 未开始。
  - v2 入口目前只有声明与布局；native/runtime 与托管 Start 尚未消费，error 路径与重复 start 负例在 C1 补。
### 2026-10-26 / ANDROID-THREADED-R3 / 最终兜底独立、续期跨生命周期、音频和计数回调收尾

- 状态：本地实现，未 push、未上真机；普通 merge 合入 integration f95446f2，保留开发替换库与拆线程接线，补丁仍0271。
- watchdog：标识的普通文件/logcat I/O 只在独立线程；最终线程不等它，仅固定1ms调度机会后退出124。普通文件阻塞注入下 true/false 均恢复约1.5s/124，与 b114df2f 同期限。标识尽力写，不能以缺行判成功。
- 原生writer续期直接读租约生命周期，后台暂停，代次变化重置idle/total；发布绑定writer epoch并在托管等待finally撤销，原生各加1s，单线程仍2s。真实native准入和生产托管等待的32s后台/冻结、恢复推进通过；去掉后台/代次处理均被同用例拒绝。
- 进程快退先关闭counter guest回调、总计100ms有界尝试Join；已有回调不结束就拒绝释放GPU，晚结果不再写guest。查询/事件与Vulkan对象留至进程退出，不逐个销毁。独立租约Stopping仍全量释放。
- 音频根因：原生park Horizon服务线程后，AudioUserIpcServer.Shutdown走不到；独立AudioRendererManager.Worker继续用已被Switch.Dispose关闭的pause event。Android显式登记AudioManagers，在驱动事件关闭前唤醒/停止/Join，重复Shutdown幂等；Apple hook未安装。真实处理器同栈夹具先红后绿，完整真机收尾待验。
- 逐局：formal4/6 共7个GPU拆线程完成局7/7同音频异常/SIGABRT（含formal4 bg-T/cold-T，非始于快退）；单线程臂8局仅1局优雅完成，b2的12局仅2局优雅完成，其余删失，不能据无异常作安全或因果频率判断。
- formal4最终读数：9000/Mali-G710，源码19eb4aac，APK bbeb8505…，观察窗36.19→46.48Hz（+28.4%）；统一16.667ms槽，1槽36.95%→72.79%；PSS +75.8/+102.6MB（60/290s）；首帧F/T中位10.52/10.57s，未观察到旧延迟。完整有效臂仅A=1/B=3，c4-F仍收尾无效。
- formal6（44878c8d，APK 5b022c2b…）GPU阶段1104/984/684ms，3/3<1500ms，随后3/3音频异常，非全进程成功。9000 auto请求60.0、首局→下局采用已核；8E auto留单线程待验；能耗、逐帧画面、其他游戏未完整验收。
- 验证：本轮主机全量结果见PR草稿及t11 evidence；contrib_check按实际工具链状态记录。下方原条目为历次实现和检查记录，新状态以上述R3为准。


### 2026-10-26 / ANDROID-THREADED-RENDERER / 拆线程正式改造（GPU 模拟 / Vulkan 录制提交分两条线程，有界；外壳缺省关，auto（按上局实测负载下局生效）/ true 显式开）

- 关联：性能（Wonder / 天玑 9000：S2A.GPU 单线程每帧 CPU 约 25.7 ms、忙约 98%）；接续拆线程 P0 量测包（`078f009f`，未合入）。
- 状态：已实现；真机矩阵待测（9000 长时间 / 内存 / 切后台 / 热 / auto 两局流程，8E 不回退）。
- 变更：`s2arm.threaded_renderer` = `true|false`（`--ez`，或 `--es`）/ `auto`（`--es`）→ JNI → `S2A_ANDROID_THREADED_RENDERER`（`0|1|auto`，外壳每次显式设，不带 extra 取 `THREADED_RENDERER_DEFAULT = "0"`：底层性能改动缺省关合入，翻缺省到 `auto` 另起 PR，条件：9000 正式版 A/B 达标 + 8E auto 留单线程 + 至少再 1 款游戏冷启 / 稳定性通过）；`false` = 单线程基线（`Run` 逐字未改）。开时 GAL 套 Ryujinx `ThreadedRenderer`（补丁 0283）：S2A.GPU = GPU 模拟与换页事务所有者，S2A.GPU.Vk = Vulkan 初始化 / 全部 GAL 命令 / WSI / 出图计数；stamp 执行时取、WSI 只归渲染线程、换页前排空 GAL 队列、停止 / 失败顺序、出图计数五个接点同 P0。新增：① 有界队列：已入队条数上限 9999（命令环全部槽，预分配）、在途载荷上限 64 MiB（贴图 SetData 数据 + 环形池放不下的新分配），超限模拟线程背压等；② 有界等待：同步命令 / 出图节流 / 背压 / 中断 / 同步号 / 排空 / 收局 / 非 GPU 线程等对象建好与等锁，前台渲染线程连续 2000 ms（+250 ms 宽限）不前进 → 失败闩 + `Fail` + `TimeoutException`（【红】诊断），换页回调前台 3 s 预算内留约 700 ms；③ auto：每款游戏在游戏状态目录留 `threaded-renderer.auto`（v2），无记录先单线程测；整局评估（呈现 < 10 Hz 的加载 / 菜单窗不计、打断饱和段），任一连续 6 个有效 5 s 窗（30 s）S2A.GPU 忙（CPU 时间 / 墙钟，不含 fence / acquire 等待）≥ 0.85 且呈现 < 0.95 × 游戏请求 → 下局拆线程，满 36 个有效窗（180 s）没有饱和段才记单线程，短局 / 被杀不写；拆线程的局用同口径饱和段比较，< 1.05 × 单线程饱和段连续 2 局才固定单线程 10 局，只有渲染线程卡住判定固定，别的失败与收局慢不写；不在运行中切换（渲染器对象 / 资源句柄 / WSI 租约 owner 构造时定型）；`AndroidGameRuntime` 传状态目录，只有 auto 时才把出图间隔回调给运行时（0 / 1 接线同基线），收局先解挂；④ 收局累计行改在渲染线程上 WSI 停止前打；⑤ 60 帧行加背压与在途载荷；⑥ 复审 P1：换页等待按渲染侧干活续期（3 s 无干活 / 30 s 总上限），卡住判据与换页等待的前后台读外壳生命周期（`s2a_android_host_lifecycle`，不靠渲染线程 Poll），GPU 层后台动作在模拟线程就地执行（渲染线程不进 GPU 层 / 写跟踪），Vulkan 计数队列 `FlushTo` 纳入有界等待与失败闩；⑦ 收局：宿主收局请求（`S2AShutdown.Request`，早于 Stop）一到就停用卡住判据、结束 auto 评估、把驱动管线缓存落盘提前排到编译通道（释放时没有新管线就不重存），每 250 ms 打进度（两条线程在哪一步 / 等什么 / 已等多久、等渲染线程的 guest 线程）、1200 ms 起标黄（原生收尾兜底 1.5 s `_exit`）；原生收局另起进度线程每 250 ms 打收局线程与 S2A.GPU* 的内核态和 writer epoch 未停稳的 guest 线程，「地址余量 [收局]」带读 maps 用时；⑧ 换页：无回写源且第一条 marker 之后没有新入队（生产侧序号）时省掉第二条 marker（冷启首帧晚的来源是每次换页多约 0.9 ms 的 marker 往返）；⑨ 复审第 2 轮：换页排空期间另一条游戏线程进内存 SVC 时，原生 writer 准入等待按托管发布的换页推进续期（同一组 3 s / 30 s 上限各加 1 s，原来固定 2 s 后 die）；拆线程收局诊断（读 maps 挪到 StopGpu 之后、限 150 ms、原生进度线程）只在拆线程时生效，单线程收局日志与基线逐行一致；auto 拆线程局按「呈现低于请求」比较；收局请求回调日志交线程池写；驱动管线缓存两次落盘按版本串行、旧不覆盖新；慢但成功的收局标黄不标红；⑩ 进程收局（Stop / 收局请求）时拆线程下层对象不逐个释放、设备不销毁，渲染线程上只补存驱动管线缓存，完成行带分步用时；原生兜底结束进程前打「原生兜底」标识行（两种模式，只在兜底时出现）。线程放置 / ADPF 实验（`1d6e1e8b`）未带入。说明、依据、等待图与 auto 判据见 `graphics/vulkan/runtime/README.md`「拆线程」。
- 验证（`cc893bba` 代码）：`compat/verify.sh --rev HEAD` 一致（上游 + 265 补丁）；`dotnet build` Android AOT 工程 0 错误；control-tests 单线程 290 项（探针 316 项）、拆线程 + auto 468 项（25 个用例）连跑 10 次通过；39 个负控（私有副本）全部报红；runtime BackingChecks 16 项、metrics-tests 8 例、`run_profile_consumers.py --negative-controls`、`gate.sh`（Java 单测 / python 契约）通过；Java 外壳 android-36 编译 + 模式映射 10 项、JNI 设置函数 host 执行（游戏 6 项 / 诊断 ENOSYS）；NDK `-fsyntax-only`（API 29 / 35）bridge.cpp 游戏 / 诊断与改动的 C 文件通过；docker 原生 wsi_lease / host_android / run_lifecycle（单线程日志与 b114df2f 逐行一致、拆线程收局进度与有界读 maps、原生兜底标识行）/ run_thread（4099 项）/ writers-gate（换页推进续期与停止、负控）通过；macOS t_lifecycle 通过；run_shutdown_consumer 在本机镜像上 HEAD 与基线同样构建失败未跑成；contrib_check 第一层「不完整」（本机无统一工具链）。未构建 APK；`8e785909` 起的修复未上真机（`01a3af10` 的真机读数维护方在取）。
- 限制：没有上传租约（`SetBufferData` 多一次环形池拷贝，9000 Wonder 0.64–0.65 MB/帧）；9000 A/B 的收益里混着合批语义（套层后 `SyncManager` 非严格同步不立即提交）与上传拷贝两个变量；auto 阈值只来自 Wonder 两台设备，整局评估版没上真机；fc7cb6e6 版拆线程收局在 9000 上三局都没落盘驱动管线缓存，其中两局原生收局停在读 /proc/self/maps 之前（证据指向读 maps 争 mmap_lock：一局直接抓到 D 态，另两局 R 态未直接证实），拆线程已挪后并限时，真机复测待做；内存 9000 PSS T 比 F 多 +82 MB（60 s）/ +100–120 MB（300 s），托管堆 +23–42 MB 已知（含预分配约 8.8 MiB），Graphics +40–55 MB 来源待真机读数；同步命令整局最大 58.7–80.6 ms 与 P0 整局 42.1–69.2 ms 同量级（P0 报的 1.1–1.5 ms 是关卡内中位）；能耗未测。
### 2026-10-26 / ANDROID-GAMEPAD-MAPPING / 可选面键标签映射与持久化

- 关联：#156、原作者 #219、维护侧承接 #488；Android 外接手柄输入。
- 状态：已实现；主机测试与诊断 APK 软件输入通过，需用户实体手柄验收。
- 变更：首次缺省仍为 `position`，显式 `s2arm.gamemap=label` 交换 Android A/B/X/Y 到 Switch 同名面键；合法选择保存到应用私有 SharedPreferences，重启及 Activity 重建恢复。非法字符串、非字符串值明确拒绝且不覆盖已存选择。保留原始位置状态，切换后的释放不会留下旧映射；`onPause` 清键。`gamemap` 登记为运行中控制参数，避免结束开发替换库会话。未添加游戏、GPU 或手柄型号专用配置。
- 提交：#488 保留 #219 的 `25be41fc`、`e328dff9`、`12d615d4` 三个原始提交与署名；运行时补充修复 `236a204f`，最终测试 `ba256745`。
- 验证：既有记录为 Android 16 / SDK 36 的联想 TB322FC（8E / Adreno 830）和 OPD2201（9000 / Mali-G710），诊断主 APK SHA-256 `6aa5090e1478e8c6595e3daae4ea578dadf0b7f8dd1381c217e51c5a6c1eb61b`；两模式 A/B/X/Y 软件输入及无参数冷启恢复通过，9000 最终 Activity instrumentation 62 项通过。复审本轮不碰设备，只复核原始日志与源码并运行相关主机测试。
- 限制：需用户实体手柄验收；软件注入不证明蓝牙、印刷标签或真实游戏内 Npad。未验证苹果路径、16 KiB 真实设备或游戏玩法；#156 保持未关闭。详细读数见 [设备矩阵](device-matrix.md)「手柄输入」及「10-26 维护侧软件输入复验」。

### 2026-10-26 / ANDROID-DEV-RUNTIME-REVIEW2 / 开发替换库第 2 轮复审修复

- 关联：ANDROID-DEV-RUNTIME-REVIEW；复审第 2 轮 N1–N8。
- 状态：已实现；主机测试通过，未做真机。
- 变更：
  - N1：同一进程里同一选择会复用已加载的库，不再重新复制，也就不会删掉正在映射的副本；同一进程里换选择要冷启动，被拒时也不动已映射的副本。
  - N2：副本按 `<sha16>-<pid>-` 命名；起局时（包括 APK 起局）只清理其他进程的副本。README 写明推送目录是 0555，要先 `chmod -R u+w` 才能删。
  - N3：metrics.py 对更早的包（BootSpec 没有 runtimeLibrary 字段）按正式局处理（apk-legacy）；只有新 BootSpec 却缺记录时才拒绝；记录不是对象或 JSON 坏了，给出明确错误而不是 traceback。
  - N4：尚未检查标记的读数入口列入限制。
  - N5：区分起局 intent 与控制 intent。只含 `CONTROL_EXTRAS` 的控制 intent 不会结束开发局；只有起局 intent 要求库选择一致。结构测试核对 `CONTROL_EXTRAS` 恰好等于 onNewIntent 各处理函数读取的 extra。
  - N6：JNI ABI 头改为构建期输出（add_custom_command 加独立的 custom target，依赖两份 Java 源和生成脚本；不作为 target source，因为 core-link 审计会读源码清单；实测改一条 native 声明后头文件重新生成，bridge.cpp 重编，审计通过）；`verify-apk.py` 比对 APK 内库嵌的 hash 与源码算出的值，不一致就构建失败。`jni_abi.py` 支持任意修饰符顺序、非 static、可变参数和 C 风格数组；native 修饰符个数与解析出的声明数不一致、或遇到泛型时直接报错。
  - 推送工具和清单生成器迁入仓库 `tools/dev_runtime.py`（manifest / push，不含本机路径），配假 adb 的离线测试；本机的开发构建脚本改为调用它。
- 验证：
  - `test.sh` 绿：RuntimeLibraryTest、Activity 结构测试 7 项、jni_abi 4 项、dev_runtime 4 项、metrics CLI 7 项；
  - `verify-apk.py`：当前包通过（JNI ABI 4a3778c7…）；不含 jniAbi 的旧包（threaded-formal fc7c 正式包）被拒，因为库里没有这个 hash。
- 限制：
  - 未做真机；
  - 读数入口 `tools/ab.sh`、`health_table`、`alt_report`、`beta_intake` 尚未检查开发局标记；
  - Native→Java 回调不在 ABI hash 里；
  - 校验仍在主线程。

### 2026-10-26 / ANDROID-DEV-RUNTIME-REVIEW / 开发替换库复审修复（纠正 ANDROID-DEV-RUNTIME）

- 关联：ANDROID-DEV-RUNTIME；复审 1 P0、5 P1、7 P2。
- 状态：已实现；主机测试通过，未做真机。
- 变更：
  - **P0 拒绝路径会崩溃，改为红字面板**：被拒时不注册 Surface 回调，触屏隐藏，生命周期入口都加守卫；新增 Activity 层源码结构负控。
  - **P1 符号链接绕过**：先判链接再规范化；`files/dev-runtime` 本身、`<sha>/`、库、清单都不得是链接。目录、库、清单都不得有写位，改用 POSIX 位判断，root 下也成立。
  - **P1 singleTop 静默沿用**：`onNewIntent` 的库选择必须与进程已加载的一致，否则报红并结束会话；单纯的 finish 请求不受此限。
  - **P1 机器侧贯通**：BootSpec `diagnostics.runtimeLibrary` 改为封闭结构（`kind` 等字段），并带负控。外壳写 `<state>/runtime-library.json`，按 PID 绑定。`metrics.py export` 拒收开发局和缺这份记录的局。
  - **P1 JNI/Java 一致性**：`native/jni_abi.py` 在 CMake 时从 Java native 声明算出 hash 并嵌进库，加载后与反射算出的 hash 比对，APK 内的库同样受检。
  - **P1 正式路径不变**：APK 内的库照旧按 soname 取 `native_owner`，只有替换库按 dladdr 路径取。
  - **P2**：
    - 加载的是在 code_cache 里用 NOFOLLOW 打开、边复制边哈希的只读副本，防 TOCTOU；
    - 检查 `DT_SONAME`，保证诊断自测按名字打开时命中替换库；
    - `sourceDir`、`nativeLibraryDir` 规范化后比较，并接受 split APK；
    - 主线程上的检查耗时写日志；
    - README 写明威胁模型。
- 验证：
  - `test.sh`（无 native）：RuntimeLibraryTest 46 项，Activity 结构负控 6 项（含 9000 真机崩溃栈 TouchPadView.onSizeChanged→relayout→touchViewportRevoke），contract 15 项，metrics CLI 7 项，全绿；
  - 变异检查：逐一删掉十项核对（链接、目录写位、soname、非 debuggable、基包、进程绑定、旧副本清理、回调守卫、onResume 守卫、触屏隐藏），对应测试都转红。
- 限制：
  - 未做真机：`System.load` 能否加载 code_cache 副本、APK 路径下的 dladdr、JNI ABI 比对、Posix 属性在 Android 上是否可用，都待核；
  - Native→Java 回调不在 ABI hash 里；
  - 检查仍在主线程。

### 2026-10-26 / ANDROID-DEV-RUNTIME / 可调试包的开发替换库通道

- 关联：开发循环（不改正式出包）；外壳加载入口，BootSpec `diagnostics.runtimeLibrary`。
- 状态：已实现；主机测试通过，未做真机。
- 变更：
  - 起局显式带 `--es s2arm.dev_runtime <sha256>` 时，可调试包加载 `files/dev-runtime/<sha256>/libs2arm_android.so`。
  - 加载前核六项：可调试、只读、非链接、SHA 与 extra 一致、绑定的已装 base APK SHA 一致、16 KB LOAD 段对齐。任一不符即起局失败报红，不退回 APK 里的库。
  - `NativeBridge.load` 是唯一加载入口，在 `GameLibrary` 之前调用；去掉 `TouchInputBridge` 的第二处 `loadLibrary`。
  - 加载后用 `dladdr` 核实 JNI 绑定的确实是选中的文件。
  - `bridge.cpp` 改为按 `dladdr` 路径取自身句柄（`RTLD_NOLOAD`），不再按 soname。
  - `runtime-library:` 行同时写入 logcat、状态面板和 BootSpec。开发局不作性能读数。
  - 已装 APK 的 SHA 每个进程只算一次，`GameLibrary` 的 artifact 绑定共用这次结果。
- 提交：`codex/android-dev-runtime`。
- 验证：
  - `test.sh` 新增 `RuntimeLibraryTest` 35 项，含非可调试、SHA 不符、基包不符、未对齐、可写、链接、清单不符等负控；逐一删掉五项核对，测试都转红。BootSpec 新增 3 项，schema 通过。
  - dev 容器出的 debug APK 编译通过、`verify-apk.py` 通过。lint 新增 1 条 `UnsafeDynamicallyLoadedCode` 警告，这正是本功能有意为之的 `System.load`。
  - 未做真机。
- 限制（待真机核）：
  - 8E 与 G710 各要实测一次 `System.load` 私有目录库（命名空间 / SELinux）；
  - `dladdr` 路径加 `RTLD_NOLOAD` 拿到的句柄要能让 `startGame` 返回 0；
  - APK 内库的 `dli_fname` 前缀要等于 `sourceDir!/`；
  - 诊断自测 `AndroidSelfTest.cs` 仍按名字打开本库。

### 2026-10-26 / ANDROID-A2-CONTROLLER-APPLET / 手柄设置小程序零配置应答，不再整局被杀

- 关联：A2 HostUi；Ryujinx ControllerApplet（ShowControllerSupport）。
- 状态：已实现；主机单测通过；9000 真机两局通过（报红回 false 路径与无回归），改配回 true 主路径未上真机。
- 现象：Wonder 局 wonder-20261026-101118-r1-rgfi（integration b114df2f）首帧后约 4759 帧进手柄相关页，`AndroidHostUi.DisplayMessageDialog(ControllerAppletUIArgs)` 走 `Unsupported` → `_fatal` 整局停止。
- 变更：新增 `android/core-runtime/AndroidControllerApplet.cs`，满足口径复刻 Apple `HostUi` 的手柄设置应答（Apple `Host.cs` 不改、不接线；共用层只新增 HID 读写接缝 `services/S2A.Services/PrimaryController.cs`，因 HID 共享内存仅对 S2A.Services 可见）。只在小程序重验不过时进入：唯一虚拟手柄按游戏允许的样式改配（外接手柄优先 Pro / 双 Joy-Con；掌机模式且收 Handheld 则留 Handheld；否则首个非掌机号 + Pro），等 HID 共享内存 StyleSet 生效后回 true；要求至少 2 人、没有可配号 / 样式、已配好仍连 3 次不过、改配后 200 ms 内共享内存未生效、收尾时 HLE 设备已不在，一律报红回 false，小程序按当前配置回包，不杀局。回 false 时卡住计数清零。Android 上 `InputPump.ExternalController` 恒为假（只在 iOS 置位），手柄样式由主机模式决定：掌机 Handheld、主机 Player1 Pro。
- 验证：`android/core-runtime/tests` 新增 `ControllerAppletTests`（264 项断言全过，含主机模式只收 Handheld、只给 Handheld 号、收尾 HLE 不在、卡住计数清零）；负控：恢复 throw 版本该用例抛 NotSupportedException 退出 134。真机 9000（RGFIF6ZLBYUKCELN），包 wonder-ctrlapplet-debug.apk SHA 69d521b5…（源码 05146bc6），`--from-save w1-entrance --until ready+180`：局 wonder-20261026-105755-r1-rgfi 选 4 人 → 期望报红回 false、会话继续 → 真结果 1 行 `【红】手柄设置小程序：一个手柄满足不了游戏要求（第 1 次）：人数 4–4 …`，`host UI is not connected` 0 次，会话未停，进入角色页（4 槽仅第 1 个 Mario、其余“?”，可操作），4482 帧，teardown clean；局 wonder-20261026-110012-r1-rgfi 选 1 人 → 期望无小程序、无回归 → 真结果 宏 6 步全过到世界地图，2898 帧，无手柄小程序行、无新增红类。
- 限制：改配后回 true 的主路径与生产 `InputPumpController`（真实 HID StyleSet 读写）没有真机覆盖，需 Pro-only 游戏或掌机 / 主机模式切换后进小程序的局补测。回 false 时 Ryujinx 给游戏回 Result=0（成功）且 PlayerCount=当前配置数（1）；真机上不会出现“要 4 人却成功回 1 人”（只能补齐或取消），Wonder 能容忍，其他游戏可能断言失败或卡住；改成取消语义需改 Ryujinx 回包。`S2A_STRICT=1` 下首次报红即中止进程，“报红回 false 不杀局”不成立。满足规则是 Apple `Host.cs` 的复制，两份会各自演变，建议后续在 main 侧统一。其余小程序（消息框、错误小程序、选用户、amiibo、内联键盘、截图、启动其他程序）仍直接 fatal。

### 2026-10-25 / ANDROID-A5-STARTUP-BATCH / 宽高比、完整缓存导出与写队列

- 关联：A5 着色器缓存 S1/S2；A2 HostApi display。
- 状态：已实现；宽高比与导出有真机日志，写队列修复待真机复测。
- 变更：① core-runtime 从 HostApi display 的 Surface 宽高比写 `S2ADisplay.Aspect`（显示高度仍随主机模式）；② 外壳在下一局启动时导出上一局完整缓存（`shader-previous-*`），退出时仍尽力导出（`shader-session-*`）；③ Ryujinx `ShaderCache.ProcessShaderCacheQueue` 不再因队首 Incomplete 停写，未完成的移到队尾。
- 提交：`android/shader-cache`；Ryujinx 补丁 `0243-shader-cache-queue.patch`。
- 验证：`compat/verify.sh` 一致；真机 `Surface 2712x1220 → 2.2230`、docked；写队列修复前同一 profile 跑十分钟导出仍为 19/544 条宿主记录，修复后待复测。Diablo III 不查询 VI 分辨率，宽高比对其画面无影响（16:9 居中）。
- 限制：离线包仍只覆盖 60 个可配对程序（44 支 SPIR-V 校验红）；首装全量现翻的根因未消除；宽屏投影未实现。

### 2026-10-25 / ANDROID-W6-SURFACE-RESUME / 表面撤销后的已获取帧释放与后台冻结握手

- 关联：W6 / 实施计划 §7.3；A5 单编译 lane 的等待路径。
- 状态：已实现；宿主测试 + 真机部分验证。
- 变更：`AndroidWindow.Present` 在 acquire 之后发现租约换代/撤销时不再抛 `Android lease changed after acquire` 终止会话；新增 `RetirementLedger.AbandonAcquire`，不提交、不 present，acquire semaphore 随 swapchain 销毁，旧链可立即退休并在 1000 ms 内 ACK。撤销发生在命令录制之后时仍按“租约仍持有窗口”完成本次 submit/present，让退休账本拿到真实完成证据。- 提交：`android/shader-cache`（本文件同批提交）。
- 验证：WSI 托管测试 84 断言、真实 C lease 104 断言通过；真机 Redmi 22081212C（Adreno 730 / Android 16）HOME 切后台 surface detach 32 ms、返回后 generation 2 重新 offer，进程存活，无会话失败。未覆盖慢编译期间 detach 与真实 present 竞态。
- 限制：STOP 后 acquired image 的 drain/release 仍未实现；不确定 acquire/submit 错误继续保留债务。

### 2026-10-25 / ANDROID-A5-BACKING-FREEZE / 后台冻结期间的 GPU backing 握手不再按墙钟判死

- 关联：A5 单编译 lane / GPU 透明内存换代。
- 状态：已实现；代码审查与构建通过，未复现原冻结场景。
- 变更：`AndroidVulkanRuntime.BeginBackingChange` / `EndBackingChange` / `ProcessBackingChange` 的 3 s 等待改为 `WaitForGpuStep`：前台仍有 3 s 有界等待，后台/租约撤销/停止中不设墙钟期限（宿主停止期限仍负责真实挂死）。`NativeLease` 在 owner 的 `Poll` 中发布 volatile `Foreground`，非 owner 等待者不读可变租约结构。
- 提交：`android/shader-cache`（本文件同批提交）。
- 验证：真机切后台后返回进程存活；原 23:45:43 `TimeoutException: GPU did not prepare old backing within three seconds` 路径未再触发。未在强制冻结（cgroup freezer）下做 A/B。
- 限制：后台无限等待依赖宿主停止策略；若 GPU owner 真死锁，guest 线程会保持阻塞直到宿主终止。

### 2026-10-25 / ANDROID-A5-CONSOLE-MODE / BootSpec 主机/掌机模式可持久选择

- 关联：A2 BootSpec v1 `consoleMode`；A5 1080p 级渲染。
- 状态：已实现；真机部分验证。
- 变更：外壳不再把 `consoleMode` 固定为 `handheld`。`am start ... --es s2arm.console docked|handheld` 写入应用私有设置，后续启动沿用；只改变模拟主机状态（docked 时 VI 报 1080 高）与 HostApi display，不改物理显示尺寸/密度。无效值记错误并保持原值。
- 提交：`android/shader-cache`（本文件同批提交）。
- 验证：真机日志 `Console mode: docked`、HostApi display 行为 `docked`、swapchain 2712x1220、游戏启动并播放片头；未验证游戏内部实际渲染分辨率与 60 fps。
- 限制：尚无图形界面开关；改变只在下一局生效（BootSpec 已冻结）。

### 2026-10-24 / ANDROID-A5-S1-001 / Vulkan 程序记录、单编译 lane 与驱动管线缓存

- 关联：A5 / 着色器方案 S1a、S1b；基线 `android/integration@c6cfcc04`。
- 状态：已实现，宿主 CPU 验证；未做真机 GPU/像素/APK 验收。
- 变更：VKPB v1 接入 `ShaderCollection.GetBinary` / `VulkanRenderer.LoadProgramBinary`，保存完整 SPIR-V、资源布局、可选管线状态与 specialization；渲染器设单编译 lane，模块/管线创建串行，owner 等待时 pump WSI 租约；驱动 `VkPipelineCache` 以身份+长度+摘要封套原子读写；宿主缓存文件按 Vulkan 翻译 profile 判别，Vulkan 旧“载入再释放”预读关闭，Apple 路径不实现该策略、行为不变。
- 提交：`android/shader-cache`；Ryujinx 补丁 `0240-shader-vkpb-s1.patch`。
- 验证：Vulkan/GPU/Android AOT Release 构建通过；`graphics/vulkan/cache/tests` 124/124 通过（含 29 项 metadata 边界和新增 profile/compile lane/driver cache 负例）；`cache-tests` 全绿（新增拒绝记录实化）；backing control 299 条断言通过；`android/test.sh` 13/14 CTest（`android_nativeaot_startup_roots` 仍是本机 binutils 2.47 BFD 断言红的已知工具链项）；`compat/verify.sh` 一致。未建 VkDevice、未跑游戏。
- 限制：宿主程序首次载入失败时现有 lazy loader 仍可能先掉一帧再翻译；驱动缓存只在退出时快照且写盘最多等 1 s；旧 profile 的宿主文件不主动清理；S2 离线包、S3 配方预热/成品池、D0 身份与事实变体未实现。

### 2026-10-24 / ANDROID-MGT-011 / integration 同步 main@8a9f2578

- 关联：W11；集成分支。
- 状态：集成分支更新。
- 变更：`android/integration` 合入 `main@8a9f2578`；W5 的 Vulkan 补丁再次与 main 新补丁冲突，已重编为 0213–0216；integration 现 behind main 0、ahead 93。
- 提交：integration `11d22458`。
- 验证：`android/test.sh` 13/14；`android_nativeaot_startup_roots` 因本机 `/usr/bin/ld` BFD 2.47 assertion fail，`origin/main` 10/10，属 #86 新增测试的工具链问题，已记录给 W3。
- 限制：该 CTest 未绿；其余 13 项通过。A-W2 后续接口仍未做。

### 2026-10-24 / ANDROID-MGT-010 / integration 吸收 #59 W2

- 关联：W2/W11；A1。
- 状态：集成分支更新。
- 变更：`android/integration` 合入 #59 `android/plat-batch2`（`plat.h` v2：`vm_reserve` / `vm_alias` / `vm_protect`，Android + Apple 实现与失败路径测试）。
- 提交：#59 `96d4359f`；integration 本次 merge。
- 验证：`android/test.sh` 10/10；#59 Mac `GATE_SKIP=vawin` 19/19、n06ody 复核通过。
- 限制：#59 只是 W2 首批切片，`vm_query`/`code_map`/`fault_write` 仍未做；进 integration ≠ 进 main。

### 2026-10-24 / ANDROID-MGT-009 / #105 段预占被窗口护栏取代

- 关联：W1/A1；Mac 地址窗口。
- 状态：已关闭（不合并）。
- 变更：main 用弱链接 `libs2a_vaguard.dylib` 在占窗口前拒掉落进窗口的固定地址映射（`f644d2a1` / `d638be22`），M5 Pro / macOS 27 复测通过；段预占 #105 关闭，保留为以后系统版本拦不住时的备用方案。
- 提交：#105 closed；main `f644d2a1`、`d638be22`。
- 验证：main 护栏在 macOS 27 复测；#59 的 Mac 自测 19/19。
- 限制：段预占未合入，不再作为当前实现。

### 2026-10-23 / ANDROID-MGT-008 / integration 吸收 A-W5 #65

- 关联：W5/W11；A3。
- 状态：集成分支更新。
- 变更：`android/integration` 合入 A-W5 #65（设备快照/能力准入首批）；与已有音频/零拷贝补丁的编号冲突已把 Vulkan 补丁重编为 0200–0202，series 与改动清单同步。
- 提交：#65；integration `ece6e174`。
- 验证：`android/test.sh` 10/10。
- 限制：W5 后续能力查询、W6 真实 renderer/present 仍未接；#59 仍 draft。

### 2026-10-23 / ANDROID-MGT-007 / integration 吸收已合入 main 的 #54

- 关联：W1/W11；A1。
- 状态：集成分支更新；#54 已合 main。
- 变更：`android/integration` 合到 `main@79b55997`，吸收 #54 的 `runtime/plat-h-callsites`（merge `879096d`）；STATUS 把 A1 第一批标为已合入、W2 #59 仍是复查项。
- 提交：#54 `f339e03e` / merge `879096d`；integration 本次 merge。
- 验证：`android/test.sh` 10/10 CTest + Java/契约测试全过。
- 限制：#59 仍 draft；#105 段预占仍是实验；A2–A5 未接。

### 2026-10-23 / ANDROID-MGT-006 / W1 窗口段预占 spike

- 关联：W1/A1；Mac 地址窗口。
- 状态：spike，未入库；不构成同包冒烟。
- 变更：用 `LC_SEGMENT_64` 在 exec 时预占 `[0x7000000000, +64 GiB)`，抢在 AGX carveout 前；carveout 退到 3 TB。d2r 从“地址窗口不足”推进到 SDK 初始化 + DT_INIT（~1.8 s）。spike 约 62 行：`vawin.c` 覆盖遍历/补底部洞 + 提前返回，构建加 `-headerpad`，段注入器单独脚本。
- 提交：临时工作树，未入库。
- 验证：单台 macOS 27；窗口整块/别名/布局/装载/C# S2A_Init 通过。
- 限制：游戏初始化仍不稳（`main+0x1694c3c` 空指针，或卡在主线程前）；`S2A_IPHONE_VA` 与段预占抢低区；需 macOS 26 同产物对照后再正式化。

### 2026-10-23 / ANDROID-MGT-005 / W1 真实 D2R 模块装载证据

- 关联：W1/A1；`plat.h` 第一批、`entry.S`/`xstack`、iOS 出包。
- 状态：真实模块验证；同包冒烟仍缺。
- 变更：D2R（`0100726014352000` + 1.0.34.0 + DLC1）base/update 解包、改写、装载全通；main/sdk/subsdk0 改写缺口 0。三模块过 `loader.c` + 真实 `plat_apple.c`，键页 K18=2088 / KTLS=2096 / KTLR=2104 / KGATE=2112 与 `plat_tsd_offset` 逐槽一致，`tsd_check` 通过，text 只读，未解析符号 0；`tools/gate_ios.sh` 通过，内嵌三段与源 `patched.bin` 逐字节相同；`rewrite_target_test.sh` 6/6。
- 提交：#54 `f339e03e`（真实模块探针不留在仓库）。
- 验证：上述为 Mac 侧一次性探针 + 真产物；`android/test.sh` 10/10。
- 限制：同包 Mac 游戏局 / iOS 真机因 macOS 27 `[0x70,0x80)` carveout 未做，需另一台 Mac 或 waiver；探针未入库，不能当常驻门禁。

### 2026-10-23 / ANDROID-MGT-004 / integration 吸收 #54 修复与 W2 v2 复查

- 关联：W1/W2/W11；A1。
- 状态：集成分支更新；#54 Ready、#59 Draft。
- 变更：`android/integration` 合入 `runtime/plat-h-callsites` 的 `thread_plat` 构建修复，head `937d3ae5`（合到 `main@d672e1d5`）；STATUS 更新 A1/开放工作/基线，W2 的 `plat.h` v2 内存/别名组记入复查。
- 提交：#54 `f339e03e`；integration `937d3ae5`。
- 验证：`android/test.sh` 10/10 CTest + Java/契约测试全过；#54 Mac gate 18/18（`vawin` 环境项除外）、`tools/gate_ios.sh` 通过；integration 本体未单独跑 Mac gate。
- 限制：#54 同包冒烟未做；#59 的 Apple v2 需 Mac/真机；A2–A5 仍未接。

### 2026-10-23 / ANDROID-A1-004 / plat.h v2 内存/别名组（W2）

- 关联：A1；W2；`plat.h` v2。
- 状态：Android 实现 + 主机测试；未真机。
- 变更：新增 `PLAT_PROT_*`、`plat_vm_reserve`、`plat_vm_alias`、`plat_vm_protect`。Android 用 `s2a_android_reserve` 做受控低地址预留；`mremap(old_size=0, MREMAP_FIXED)` 做共享映射别名；`mprotect` 做保护位。`plat_vm_alias` 只接受页对齐、已预留的 `dst` 和 shared-backed `src`，失败返回 errno / ENOTSUP。
- 提交：本 PR（`android/plat-batch2`）。
- 验证：`android/test.sh` 10/10 CTest；`android_plat` 覆盖预留失败不变更出参、保护位未知位/错位、共享内存别名双向可见、别名未知位/错位；NDK aarch64 `plat_android.c` / `memory.c` / `plat_test.c` 语法通过。
- 限制：Apple 实现仍待 W1；Android 真机未跑，`mremap(MREMAP_FIXED)` 的设备权限/内核行为待验证；v2 尚未接 `runtime/src` 调用点。

### 2026-10-23 / ANDROID-A1-005 / A1-004 纠正：恢复失败合同与标准门禁

- 关联：A1；A1-004。
- 状态：纠正（追加，不改原记录）。
- 变更：`plat_vm_alias` 的恢复失败不再吞掉，返回 `EIO`，调用方必须把 dst 视为污染；Apple 补 v2 实现并去掉 iOS SDK 不认的 `<mach/mach_vm.h>`。恢复成功/失败两条故障注入进入 `plat_test`，测试 target 单独定义 `S2A_UNIT_TEST`，不打开生产库钩子。
- 提交：本 PR（`android/plat-batch2`）。
- 验证：`android/test.sh` 10/10；`android_plat` 通过 `/proc/self/maps` 观察恢复后的实际权限，覆盖“恢复成功保持 PROT_NONE”和“跳过恢复负控不是 PROT_NONE”；NDK aarch64 / Apple Mach 桩语法通过。
- 限制：`EIO` 后的窗口停用仍由未来真实调用方落实；Android 真机 `mremap(MREMAP_FIXED)` 未跑。

### 2026-10-22 / ANDROID-DOC-001 / 文档统一与实施基线

- 关联：后续实施的代码基线；A0 设计输入。
- 状态：文档整理与基线同步；功能未实施。
- 变更：基线同步到 `android/bootstrap@ec14eaa4`（含 `main@f0a0621b`）；实施方案/GPU 说明/进度记录统一到 `android/docs/` 英文文件名，由 Android README 提供入口。
- 提交：`81d02f70`、`5d8509ac`。
- 验证：文档链接与 `git diff --check` 通过，doc 档门禁 0 步；未构建、未真机。
- 限制：不表示 A1–A8 或任何游戏/设备兼容验收完成。

### 2026-10-22 / ANDROID-A0-001 / A0 契约 v1 与 Boot 消费端骨架

- 关联：A0；BootSpec / GameInputManifest / GameBuildArtifact / current.json。
- 状态：已实现契约与消费端骨架；未接真实导入/装载器。
- 变更：新增 `android/contracts/` 四份 JSON Schema、合成样例和 stdlib 校验器；新增 `BootContract`，按 `current.json → revisions/<contentRoot> → game-build-artifact.json` 校验路径、artifact SHA-256、title/contentRoot 一致、`rewriteAbi`、模块 fixups 的 `# TARGET android`，并通过 `ModuleMapper` 钩子接模块映射；`BootContractTest` 覆盖坏 hash、旧 ABI、路径穿越、缺模块和 JSON 损坏。
- 提交：`0e744176`、`b8a1781e`、`c29c6ec5`。
- 验证：`bash android/test.sh` 全过（6 个 CTest、Gamepad、BootContract、4 个契约样例）；未真机。
- 限制：尚未接 Android 面板/真实 `current.json` 生产者；`ReadyToPlay` 只到模块映射，不执行 guest。

### 2026-10-22 / ANDROID-A1-001 / Android 改写块不再使用 sp 下方暂存

- 关联：A1；`platform/plat.h` 之前的 Linux 改写 ABI（§5.2）。
- 状态：已实现；合成模块验证通过，未跑真实游戏模块。
- 变更：`S2A_TARGET=android` 的改写块改为 `[sp, #-16]!` / `[sp], #16` 保存恢复；用到 sp 的原指令按 `sp_frame` 调整偏移，动态改 sp、跳转表、独占窗口等站点各有独立栈帧；`.fixups.tsv` 写 `# REWRITE_ABI`，仍有 sp 下方访问时写 `android-below-sp-v1` 供装载器拒绝。Apple 产物不变。
- 提交：`e9a10c24`。
- 验证：`tests/rewrite_target_test.sh` 全过；Apple 产物与旧改写器逐字节相同；合成 Android 产物 below-sp 扫描为 0。
- 限制：未在真实 NSO / 真机上跑；`sp_frame` 编不出的站点会保留旧排法并标 `android-below-sp-v1`。

### 2026-10-22 / ANDROID-A0-002 / A0 消费端接线与 stage_a0 开发桥

- 关联：A0；BootContract / GameLibrary / stage_a0。
- 状态：已实现并接入游戏列表（A0 布局存在时优先）；未接正式导入。
- 变更：`BootContract` 区分 `Validated` / `ReadyToPlay`，校验游戏目录名 = titleId、`index.tsv`、`artifact` 与模块 `# REWRITE_ABI`；`GameLibrary.describe()` 在 `current.json` 存在时走 A0 校验 + `NativeBridge.checkModules`，否则保留 #17 探针布局的旧路径。新增 `tools/stage_a0.py` 开发桥：把 `make_pack.py` 的包复制进 `revisions/<contentRoot>/`，写 artifact 与 `current.json`。新增 `tests/stage_a0_test.sh` 合成包端到端。
- 提交：`add08940` 及后续。
- 验证：`bash android/test.sh` 全过；`tests/stage_a0_test.sh` 合成包 → rewriter → stage → schema → BootContract 全过；App Java 用镜像内 `android-36/android.jar` 编译通过（`MainActivity` 仅缺生成的 R，临时 R stub 下全过）。
- 限制：App 未整包 assemble/lint；`stage_a0.py` 是开发桥，不是正式安装事务。

### 2026-10-22 / ANDROID-A0-003 / A0 v1 增加模块来源与 APK 身份

- 关联：A0；`GameBuildArtifact` 正式每游戏 APK 形态。
- 状态：已实现契约与消费端；正式 APK 安装/资产提取仍待 A4/loader。
- 变更：`modules[]` 增加 `source`（`apk-asset` / `revision`）；`apk-asset` 时 artifact 必须带 `apk`（packageName、versionCode、APK SHA-256、签名证书 SHA-256、assetRoot）。`BootContract` 对 revision 模块继续查文件与 `# REWRITE_ABI`，对 apk-asset 只查字段与来源，APK 哈希/签名由外壳/loader 验；`GameLibrary` 对 apk-asset 先显示 Validated，不假装已映射。`stage_a0` 写 `source: revision`。
- 提交：本次提交。
- 验证：`android/test.sh`、`stage_a0_test.sh`、App Java `javac`（android-36 jar + R stub）全过；APK-asset 合成用例在 `BootContractTest`。
- 限制：没有真实 APK 资产提取/映射；`contentRoot` 仍是 package index hash。

### 2026-10-22 / ANDROID-A0-004 / 评审反例修正

- 关联：A0/A1；评审 1–7 条。
- 状态：已修正并加回归用例；未真机。
- 变更：
  - P1 `site_br_tab` 落地垫步长按平台取 8/12 字节（原先固定 12），并加每条垫长度断言。
  - P1 `BootContract` 把已校验模块的完整路径交给 loader：新增 `NativeBridge.checkModulePaths`、`s2a_module_map_path`；`GameLibrary` 不再扫描固定 `modules/` 目录，额外模块不会被加载。
  - P2 `GameLibrary` 先读 `current.json`，再从选中 revision 读 NACP；新增纯 Java `GameMetadata`，正式布局根目录没有 manifest/index/ctl 也能显示。
  - P2 artifact 增加可选 `input`（manifest/hash/contentRoot/titleId），`validate.py` 校验输入 manifest 的 title、buildId 与 artifact 一致；输入身份改动会拒绝。
  - P2 `BootSpec` 增加 `consoleMode`（handheld/docked）、`network`（offline/online）。
  - P2 `.fixups.tsv` 表头按行解析，`# REWRITE_ABI` 精确比较，重复/冲突表头拒绝；不再用 `contains()`。
  - P2 `stage_a0` 改为独立复制，不再硬链接；源文件修改不影响已激活 revision。
- 提交：本次提交。
- 验证：`android/test.sh`、`stage_a0_test.sh`（含正式布局、输入身份、immutability）、`tests/rewrite_target_test.sh`、App Java `javac`、`bridge.cpp` NDK clang 语法检查全过。
- 限制：`site_br_tab` 多目标修复没有独立三目标夹具，靠代码步长断言 + 评审复现；未真机。

### 2026-10-22 / ANDROID-A0-005 / 复审缺口与受控扩展

- 关联：A0；模块路径、输入绑定、schema 兼容。
- 状态：已实现并通过宿主与合成包验证；未真机。
- 变更：模块 image/fixups/gates 强制同目录同名，避免 Java 校验与 native 推导的配套文件不同；输入与 artifact 的静态模块集合、buildId 严格对应，重复模块拒绝；样例入口也校验输入 manifest 绑定，新增 14 项回归并接入常规 test.sh。
- 扩展：四份 schema 增加可选的命名空间 extensions 与 requiredFeatures；Python 与 Java 接受未知可选元数据，拒绝未知必需能力，核心字段和版本保持严格约束。README 明确字段、枚举与语义变更的升级规则。
- 验证：Android 宿主测试、契约负例与 stage_a0 合成包端到端通过；未构建 APK、未做真机。

### 2026-10-22 / ANDROID-A0-006 / 对齐安卓外壳侧 review（#24 包名 / assetRoot / APK 校验策略 / BootSpec）

- 关联：A0；安卓外壳侧 review 1–5。
- 状态：契约与消费端已改；未真机。
- 变更：`apk.packageName` 收紧为 `org.s2arm.game.t<titleId 小写>`，`BootContract` 同时核它等于 `t + titleId`；样例 `assetRoot` 改 `game/modules`；README 明确启动只核 packageName/versionCode/签名证书，`apk.sha256` 留给 A4 部署事务/导出审计，artifact 放 revision 不放进被哈希的 APK；BootSpec 补安卓注入说明：`cacheRoot` 只给根、`region` 可缺省、timezone 需规范化为 IANA、screen 是会话 Surface 实际像素、consoleMode/network 默认值。
- 验证：`validate.py`、`contract_validation_test.py`（14 项）、`BootContractTest`、`stage_a0_test.sh`、App Java `javac` 全过。
- 限制：apk-asset 实际映射等 #24 合入后复用其 `map_modules`；安装事务归 yyan160；未开 PR、未真机。

### 2026-10-22 / ANDROID-A0-007 / 安装前 revision 校验接口

- 关联：A0；安装事务写入侧（yyan160）第 3 条接口。
- 状态：已实现并加 staging 回归；未真机。
- 变更：`BootContract` 拆出 `readCurrent(File)` 与 `validateRevision(File, revisionDir, contentRoot, artifactRel, artifactSha)`。安装器可在 rename 前直接校验 `revisions/<contentRoot>.staging`，不依赖 `current.json`；运行时 `open()` 仍走 `readCurrent → validateRevision`，行为不变。
- 验证：`BootContractTest` 新增 staging 校验、staging 内 artifact title 变更拒绝；`stage_a0_test.sh`、`contract_validation_test.py`、App Java `javac` 全过。
- 限制：安装事务本身仍归 yyan160；未开 PR、未真机。

以下 #8–#19 各条在 ANDROID-DOC-001 之后补记（#18 约定），日期为合入 main 的日期；提交为 GitHub 记录的合入提交。真机均为 Redmi K50 Ultra（Android 15，Adreno 730，4 KB 页），另注明者除外。

### 2026-10-22 / ANDROID-AOT-001 / NativeAOT（linux-bionic-arm64）可行性

- 关联：A2；服务层运行时。
- 状态：已验证（可行性）。
- 变更：.NET 10.0.9 NativeAOT 运行时包 + SDK 10.0.301，NDK clang 链接；`cs/probe` 探针与 `cs/aot` 服务层组合（S2A.Services + Ryujinx HLE + Vulkan 后端）。查明三处阻碍：.NET 加密在 bionic 上没有 libssl 会 `abort()`；`GetMainProgramHandle()` 看不到 App 库的导出；.NET 的 GC 劫持信号要先由 `s2a_android_runtime_signals_prepare` 预装才带 `SA_ONSTACK`。
- 提交：PR #8（`628285177`）。
- 验证：探针运行时载入并跑完 39 ms，压缩 GC、带栈异常、空引用（经 ART sigchain）、线程 / 线程池 / 计时器均通过；服务层库 0 错误、36.6 MB。
- 限制：服务层未真正启动游戏；`s2a_native` 当时尚未绑定。

### 2026-10-22 / ANDROID-AOT-002 / App 自带 OpenSSL 3.5.9

- 关联：A2；.NET 加密。
- 状态：已验证（过渡做法：原生层线的方向是托管实现，见 PR #9 讨论）。
- 变更：`openssl/build.sh` 用 NDK 编 OpenSSL 3.5.9（源码 sha256 固定），`libssl.so` / `libcrypto.so` 随 APK。
- 提交：PR #9（`ebc70d484`）。
- 验证：真机随机数、SHA-256、AES 均与已知答案一致；不带时 .NET 加密直接终止进程。
- 限制：约 6 MB；托管加密落地后可去掉。

### 2026-10-22 / ANDROID-AOT-003 / 服务层静态链进宿主单库

- 关联：A2；HostApi 绑定。
- 状态：已集成（链接期绑定）。
- 变更：`S2ARM_ANDROID_CS_SERVICES=static`：NativeAOT 静态库 + SDK 列出的运行时件链进 `libs2arm_android.so`，`DirectPInvoke s2a_native / s2arm_android`；运行时自带的 libunwind 89 个符号改名，与 NDK 的 C++ 展开器各用各的。
- 提交：PR #10（`fc8e8645d`）。
- 验证：载入 2–3 ms，运行时启动 + 首次调用 11 ms（RSS +14 MiB）；C#→C 传值、传串正确；.NET 异常（带栈）、空引用、压缩 GC 与 C++ 异常都正常。
- 限制：原生核心未接，`native/s2a_native_stub.c` 代替 20 个导入函数。

### 2026-10-22 / ANDROID-AUD-001 / Ryujinx 音频驱动接 AAudio

- 关联：A2；§6.2 音频。
- 状态：已集成（短音自测）。
- 变更：`cs/audio` 实现 Ryujinx `IHardwareDeviceDriver`，组合入口装为 `Exports.AudioFactory`；AAudio 实时回调在 C 里只读无锁环（`native/aaudio_sink.c`、`native/pcm_ring.c`），C# 会话记账同苹果；喂数线程按缓冲播完事件唤醒，暂停或无数据时不醒。
- 提交：PR #11（`50b4b97c5`）。
- 验证：经 Ryujinx 会话接口放 0.4 s 音调，19200/19200 帧、479 ms、更新事件已置、0 xrun；共享模式，burst 192 帧，设备缓冲 384 帧；喂数唤醒播放中 3 次、暂停 300 ms 内 0 次。
- 限制：未测游戏 audren 负载、焦点 / 路由切换、功耗。

### 2026-10-22 / ANDROID-GFX-001 / 诊断 Presenter：渲染线程、Surface 生命周期、预旋转

- 关联：A3；§7.1 诊断模式、§7.3。
- 状态：已验证（诊断 Presenter，不是游戏呈现路径）。
- 变更：渲染线程独占 device / swapchain，主线程只交接状态；预旋转按 `currentTransform`，交换链取自然朝向尺寸，`Presenter::to_image` 把用户所见矩形映射进预旋转图像。
- 提交：PR #13（`35b13d41a`）。
- 验证：Redmi 1220×2712、4 张图、约 8.2 ms / 帧（120 Hz）；横屏（ROTATE_90）与反向横屏（ROTATE_270）截图中角标朝向正确。OnePlus 13（Android 17，Adreno 830）约 16.6 ms / 帧（60 Hz），横屏角标正确，BACK 拆除干净。
- 限制：共用渲染器接入时须对其输出做同一变换。

### 2026-10-22 / ANDROID-LIC-001 / 第三方许可随 APK

- 关联：A4 打包；发布合规。
- 状态：已集成。
- 变更：README 第三方依赖表（OpenSSL Apache-2.0、.NET 运行时 MIT）；OpenSSL `LICENSE.txt` 与 .NET 运行时 `LICENSE` / `THIRD-PARTY-NOTICES` 进 `assets/licenses/`，`verify-apk.py` 缺许可即失败。
- 提交：PR #12（`29047e373`）、PR #15（`d6f7f2b3d`）。
- 验证：Docker 构建 + `verify-apk.py`；未真机（不涉及运行）。

### 2026-10-22 / ANDROID-GFX-002 / surfaceDestroyed 等待计时

- 关联：A3；§7.3 Release ACK。
- 状态：已集成；其中「超时后继续是安全的」一说已由 ANDROID-GFX-003 纠正。
- 变更：`surfaceDestroyed` 有界等待（1 s）记耗时，超时计数。
- 提交：PR #15（`d6f7f2b3d`）。
- 验证：OnePlus 13：Surface detached in 0 ms。

### 2026-10-22 / ANDROID-INP-001 / 触屏虚拟手柄

- 关联：A2；§6.4 输入。
- 状态：已验证（注入触摸）。
- 变更：屏上 Switch 手柄（两摇杆、十字键、16 键），按 Npad 位与摇杆量程输出，与实体手柄状态合并；失焦 / 暂停清零。
- 提交：PR #16（`f96b48730`）。
- 验证：Redmi 注入多点触摸，按下 / 按住 / 松开、摇杆方向、十字键均正确，触摸只进本 App；`TouchPadTest` 主机单测。
- 限制：手柄热插拔、反向横屏下的触摸坐标未专门真机核对；原生触摸服务另计（§6.4）。

### 2026-10-22 / ANDROID-IMP-001 / Android 游戏包开发导入

- 关联：A4；§6.5、§8.2。
- 状态：已验证（开发导入，探针 APK 的独立模式，§2.3）。
- 变更：`tools/make_pack.py` 出资源包 v2 + `modules/`（`S2A_TARGET=android` 改写产物）；`GamePack` 按 `index.tsv` 逐文件核大小与 SHA-256、拒不安全路径 / 多余文件 / 非 Android 改写产物；`GameLibrary` 经 adb `import/` 或系统文件选择器导入，核对后装入，再做模块装载检查（匿名内存，封 R|X）。`make_pack.py` 只替换资源包目录。
- 提交：PR #17（`77a007431`）。
- 验证：Redmi adb 导入合成包成功、模块映射 R|X；篡改的包被拒；`GamePackTest` 主机单测。
- 限制：系统文件选择器路径未真机跑；存储仍是外部私有目录 `games/<titleId>/`，§6.5 布局等 A0 的 `current.json` schema。

### 2026-10-22 / ANDROID-GFX-003 / Surface 释放 / 拆除超期即终止进程

- 关联：A3 / §7.3，§4.2；纠正 ANDROID-GFX-002。
- 状态：已验证。
- 变更：释放与拆除各 1 s 期限，超期设 abort message 并 `abort()`，不再返回（持有 ANativeWindow 引用不延长 Surface 有效期）；调试 extra `s2arm.release_stall_ms`。
- 提交：PR #19（`528072b25`）。
- 验证：Redmi 按 HOME：等 500 ms 时 502 ms 正常放手；等 1500 ms 时 1000 ms 到期 FATAL + SIGABRT，tombstone 的 abort message 为原因；abort 开始后渲染线程还打了一行，正是期限要拦的旧 Surface 访问。
- 限制：拆除期限（`onDestroy`）未在真机专门触发。

### 2026-10-22 / ANDROID-A0-008 / HostApi v1 与 run manifest v1 契约

- 关联：A0；A2 宿主能力、§9.1 运行证据。
- 状态：契约与宿主 ABI 测试已实现；未接 Android 外壳、未真机。
- 变更：新增 `runtime/include/s2a_hostapi.h`（四终端共用，不叫 Android；用户/内存信息 meminfo/输入/显示/UI/解码/停止七张表，均有 `size`/`abi_version`，`s2a_host_register` 校验并发布）；`android/native/hostapi.c` + `hostapi_test` 覆盖注册、版本、能力位、表缺失和表尾扩展（`size` 增大按前缀读）。表头写清 stop↔shutdown、meminfo↔`s2a_mem_query`、input↔vpad/set、consoleMode↔`S2A_DOCKED` 的单一路径；UI 改为 begin/wait/cancel 异步，删除 `timezone_offset`，user 值冻结为 BootSpec，`g_api` 用 C11 原子读写。新增 `run-manifest.v1.schema.json` + 合成样例，绑定 app/artifact/input/module/device/driver/profile/session 与证据文件；`validate.py` 与样本 run 交叉核对，`run_manifest_test.py` 覆盖缺字段、坏 buildId、路径穿越、重复模块、未知 requiredFeatures。
- 验证：`android/test.sh`（8 CTest，含 hostapi/wsi_lease）、`validate.py`（5 份样例）、`run_manifest_test.py` 全过。
- 限制：HostApi 尚未由 Android shell 注册；run manifest 尚未由测试 harness 生成；未真机。

### 2026-10-22 / ANDROID-A0-009 / 允许 revision 符号链接到内容寻址对象库

- 关联：A0；安装事务写入侧（yyan160）真机结果。
- 状态：已实现并加宿主回归；未真机。
- 变更：`BootContract.under()` 解析符号链接后，允许 canonical target 落在同一个 game root 的 `objects/<aa>/<sha256>`；其他目标仍按 `escapes` 拒绝。支持 `npdm` / `control` / `romfs` / 模块 image+sidecar 的链接，安装器可用相对符号链接去重。
- 验证：`BootContractTest` 新增对象库链接通过、非对象库链接拒绝、越界链接拒绝；`android/test.sh`、`stage_a0_test.sh`、App Java `javac` 全过；A1 `device_selftest.sh` 由 yyan160 真机通过（6 种改写块 × 2 条客体线程）。
- 限制：安装事务本身仍归 yyan160；未在设备上跑本轮 `under()` 改动。

### 2026-10-22 / ANDROID-COD-001 / 单库构建链入 Opus / VP8 解码

- 关联：A2；§6.2 / §6.3 解码依赖。
- 状态：已验证（编解码自测；服务层真正调用要等原生核心在安卓上运行）。
- 变更：`codecs/build.sh` 用 NDK 编 libopus 1.6.1 与只含 VP8 解码器的 libvpx 1.15.0，版本、源码 sha256、configure 选项都取自 `services/opus|vpx/build.sh`；垫片与库合成归档，`DirectPInvoke s2a_opus / s2a_vpx` 链进单库。`verify-apk.py` 按库内容的标记串要求许可文件（顺带补上单库里 .NET 运行时的许可）。诊断报告按行写 logcat（`__android_log_print` 一条最长 1023 字节）。
- 提交：PR #21（`186b702bb`）。
- 验证：Redmi K50 Ultra（Android 15）：Opus 单流 / 多流解码，延迟 312 样本，信噪比 40.6 / 44.6 dB；VP8 关键帧与帧间帧和主机纯 C 参考解码器逐像素一致；坏帧被拒。
- 限制：FFmpeg（H.264，LGPL）链接方式待定，未做。

### 2026-10-22 / ANDROID-PKG-001 / 每游戏 APK 第一步：模块随 APK、按 title ID 生成应用身份

- 关联：A4 `pack/android`；§2.3 / §8.2。
- 状态：已验证（装载检查；不执行）。
- 变更：`tools/game_apk.py` 从游戏包取 `modules/`（逐文件按 index 核），Gradle 用 `S2ARM_ANDROID_GAME_DIR` 出 `org.s2arm.game.t<titleId>`、游戏名为启动器名；模块镜像不压缩，运行时 `AAsset_getBuffer` 原地读，经新拆出的 `s2a_module_map_mem` 拷进匿名内存封 R|X，不先写存储。
- 提交：PR #24（`72da7ab34`）。
- 验证：Redmi：每游戏 App 与诊断 App 并存，`modules main map R|X (TARGET android, 80 KiB); images read in place from the APK: 1/1`；测完卸载。
- 限制：资源包与 APK 身份的 A0 绑定见后续（#29）。

### 2026-10-22 / ANDROID-GFX-004 / 拆除期限真机触发

- 关联：A3；§7.3、§4.2；补 ANDROID-GFX-003 的未覆盖项。
- 状态：已验证。
- 变更：调试 extra `s2arm.stop_stall_ms`（拆除前延迟）与 `s2arm.finish`（Android 12+ 上 BACK 不走 onDestroy）。
- 提交：PR #25（`2073c6f44`）。
- 验证：Redmi：500 ms 时拆除在期限内完成、进程继续；1500 ms 时 1000 ms 到期 FATAL「Vulkan presenter did not stop within 1000 ms」+ SIGABRT，tombstone abort message 为该行。

### 2026-10-22 / ANDROID-A1-002 / android-sp-safe-v1 改写真机自测

- 关联：A1；补 ANDROID-A1-001 的真机项。
- 状态：已验证（合成模块）。
- 变更：无代码变更；用 #26 头 `aecf7a8f` 构建的 APK 在真机跑 `tools/device_selftest.sh`（脚本与改写器同 PR 逐字节一致）。
- 提交：PR #26 评论（2026-10-22）。
- 验证：Redmi K50 Ultra（Android 15，Adreno 730）：`Rewrite self-test (S2A_TARGET=android): 6 rewrite kinds x 2 guest threads ok`。
- 限制：该自测不在补丁块执行中途打信号，「信号帧不再覆盖暂存」靠改写块不写 `sp` 下方保证；真实游戏模块未在真机执行。

### 2026-10-22 / ANDROID-GFX-005 / §7.3 窗口租约，诊断 Presenter 改由它驱动

- 关联：A3 WSI 外壳；§7.3 Offer / Update / Revoke / Release ACK。
- 状态：已验证（外壳一侧；C# 后端的接法等 biglawine 在 #18 确认）。
- 变更：`runtime/wsi_lease.{h,c}`（纯 C + pthread）：身份 `{session, generation}`，同一窗口的尺寸 / 旋转 / insets / 刷新率变化是 revision，不比较窗口指针；revoke 有界等待释放回执，超期返回 ETIMEDOUT（外壳终止进程）；take 遇到未放掉的旧代返回 EBUSY；ABI 版本、LP64 布局静态断言、给后端用的 `s2a_wsi_api` 函数表。诊断 Presenter 改由租约驱动：surfaceCreated / Changed / Destroyed 分开，去掉用指针相等判断「改尺寸」。
- 提交：PR #28（`9bcf053fc`）。
- 验证：主机 `wsi_lease_test`（含 300 个窗口的并发压力测试，0 次超期，retain / release 相等）与 ThreadSanitizer 无报告；Redmi：旋转只产生 revision（transform 0x2 / 0x8 / 0x1），HOME 撤销用 2–6 ms，同进程重开交出第 2 代，release / teardown 期限 500 ms 等完、1500 ms 终止；系统旋转设置测后不变。
- 限制：旋转时 swapchain 会建两次（SUBOPTIMAL 早于 revision 到达），结果正确；后端侧的 DeviceLost、present-wait 退休不在此。

### 2026-10-23 / ANDROID-INP-002 / 触屏手柄横屏 / 反向横屏真机核对

- 关联：A2；§6.4；补 ANDROID-INP-001 的「反向横屏触摸坐标未核对」。
- 状态：已验证（无代码变更）。
- 变更：无；用现有调试 extra（`s2arm.touchpad on`、`s2arm.touchlog on`、`s2arm.orientation`）在 Redmi 上按日志里的控件中心注入点按与滑动。
- 提交：—（在 #33 构建的诊断 APK 上运行，触屏代码与 main 相同）。
- 验证：Redmi K50 Ultra（Android 15），横屏（ROTATION_90）与反向横屏（ROTATION_270）各一遍：A = 0x0001、B = 0x0002、十字键上 = 0x2000，左摇杆向右滑到 +32767（Y≈0），松开归零；反向横屏下布局随刘海 / 导航栏 inset 平移 25 px。系统旋转设置测后不变。
- 限制：手柄热插拔仍未真机核对（需要实体手柄）。

### 2026-10-23 / ANDROID-A2-001 / Android 外壳注册 HostApi：user / meminfo / input / display

- 关联：A2 宿主接线；ANDROID-A0-008（HostApi v1 契约）、ANDROID-GFX-005（窗口租约）。
- 变更：
  - 新增 `runtime/host_android.{h,c}`，按 `s2a_hostapi.h` 填四张表并注册，每个进程一次：
    - user：会话起局时 BootSpec 的语言 / 地区 / 时区，注册时冻结；`BootSpecSource.user` 与 BootSpec 共用同一套规则。
    - meminfo：`/proc/meminfo` 的 MemTotal / MemAvailable，加 `/proc/self/statm` 的常驻内存。guest / GPU 字节暂报 0（未知）。
    - input：`input.c` 的最新状态，带写入时间。
    - display：当前窗口租约修订（新增 `s2a_wsi_peek`，不持代、不拖慢撤销），给出 Surface 像素、由 transform 还原的 `Surface.ROTATION_*`、刷新率，加 DisplayMetrics xdpi / ydpi；consoleMode 初值取 BootSpec，之后只由 `set_console_mode` 改。
  - UI / decode / stop 本次不注册（不置能力位）。
  - 输出结构按前缀规则：调用方填 size，宿主写 v1 前缀并回填 size / abi_version。
  - MainActivity 在宿主创建后调 `NativeBridge.registerHost`；诊断信息与每次 surface 修订都附一行经 `s2a_host_get()` 读回的结果。
- 验证：
  - 主机：CTest 9/9（新增 `host_android_test`；`wsi_lease_test` 加 peek 用例）；test.sh 的 Java / 契约部分全过；APK 构建并校验通过。
  - 真机：Redmi K50 Ultra（Android 15）。
    - 读回：capabilities 0xf；user en-US / US / Pacific/Auckland；memory 11159 MiB total、4957 MiB available、172 MiB resident（应用进程能读 `/proc/meminfo`）。
    - display：surface 出现前为 0x0；之后随租约变化：1220x2712 rotation 0 → 反向横屏 2712x1220 rotation 3 → 横屏 rotation 1，均为 120 Hz、446x446 dpi、handheld。
- 限制：
  - 还没有核心消费者（`s2a_vpad_read` 仍是 InputPump 的旧入口）。
  - UI 异步请求、解码、stop 待后续 PR。

### 2026-10-23 / ANDROID-A2-002 / HostApi stop 表：核心请求结束本局，外壳收尾

- 关联：A2 宿主接线；ANDROID-A2-001；方向按 #41 维护方答复（外壳实现 `request_stop`，核心调用）。
- 变更：
  - `host_android` 注册 stop 表，能力位改为 0x4f。
  - `request_stop` 可在任意核心线程调用，不阻塞：只锁存本局第一次请求（原因 + 详情，按 UTF-8 边界截断），再写 eventfd；之后的请求忽略。
  - 主线程 ALooper 监听这个 fd，取出请求后交给 `NativeBridge.onStopRequested`（详情以字节传过去，在 Java 里按 UTF-8 解码）。
  - MainActivity 提示原因并 finish，收尾仍走 onDestroy。没有 Activity 时请求先挂着，下一个 Activity 起来时再交付。
  - 调试入口：`--ei s2arm.request_stop <reason>` 从后台线程发起请求，跟核心调用一样。
- 验证：
  - 主机：CTest 9/9（`host_android_test` 加 stop：后台线程请求唤醒 fd、只取一次、后续请求忽略、UTF-8 截断），TSan 无报告。
  - 真机：Redmi K50 Ultra（Android 15）。capabilities 0x4f；`s2arm.request_stop 2` 在主线程收到「GPU device lost (debug intent)」，Activity 结束，回到桌面。
- 限制：外壳还没有起停 guest 的路径，所以收尾只覆盖 Activity / 渲染线程；游戏模式下的提示界面待做。

### 2026-10-22 / ANDROID-IMP-002 / 安装事务写入侧与版本间共享存储

- 关联：A4 部署事务（§6.5）；ANDROID-A0-007 / A0-009（`validateRevision`、`under()` 允许对象库链接）。
- 状态：已验证。
- 变更：
  - `GameInstall`：逐文件核对后写 `revisions/<root>.staging`，`validateRevision` 通过后 rename；`current.json` 先写临时文件（fsync，记 `previousContentRoot`），再 rename。任何一步失败或进程被杀，旧版本保持激活；启动时清掉残留的 `.staging`。只保留当前版和上一版。
  - 内容寻址对象库：`objects/<aa>/<sha256>` 只读、每份内容只存一次；revision 里是相对符号链接（SELinux 拒绝应用建硬链接）。更新只多存改动的文件；不能建链接时直接复制，且不建对象库。
  - 内容根相同、artifact 不同时，只刷新 artifact。
  - `make_pack.py` 写 `game-build-artifact.json`。游戏改装到内部私有目录。
- 提交：#27（与 #33 同批合入 26d472c16）。
- 验证：主机 `GameInstallTest`（首装、升级、回滚、裁剪、三种拒绝、启动清扫）。真机 Redmi K50 Ultra（Android 15）：v1 → v2 → v3 依次导入，v3 被拒、v2 保持激活；两版共占 155 KiB 对象 + 70 KiB 目录 / 链接，两份完整副本约 312 KiB。
- 限制：新版成功启动后再删上一版，要等启动路径；系统文件选择器入口未在真机上点过。

### 2026-10-23 / ANDROID-PKG-002 / 每游戏 App 横屏启动

- 关联：§7.4；ANDROID-PKG-001。
- 状态：已验证。
- 变更：manifest 占位符 `screenOrientation`：每游戏构建为 `sensorLandscape`，诊断 App 仍是 `unspecified`。
- 提交：#33（26d472c16）。
- 验证：`aapt2` 读合并后的 manifest，两个变体分别是 6 和 -1。真机 Redmi（Android 15）竖放：每游戏 App 以 `ROTATION_90` 打开，Surface 2712 × 1220；退出后系统旋转设置不变。
- 限制：Android 16 起大屏会忽略固定方向，竖屏画幅等共用渲染器接入后再做。

### 2026-10-23 / ANDROID-A2-003 / BootSpec 外壳侧

- 关联：A2；§4.1、§8.2；ANDROID-A0-001（boot-spec schema）。
- 状态：已实现/待集成（还没有消费者）。
- 变更：
  - `BootSpec` / `BootSpecSource` 按 #18 的注入规则填 Android 那部分：
    - 路径取自 `Context`；
    - 语言取第一个系统 locale 的 BCP 47 标签，地区只在 locale 有时写；
    - 时区先取 ICU 规范 ID，`GMT±hh:00` 转 `Etc/GMT∓h`，其余转 `UTC` 并记诊断；
    - 屏幕暂取默认显示的横屏全尺寸。
  - 每个 ReadyToPlay 游戏记日志，并把预览写到 `cache/boot-spec-<title id>.json`。
  - ANDROID-A2-001 的 HostApi user 表用同一套规则（`BootSpecSource.user`）。
- 提交：#31（b4d998fb）。
- 验证：`BootSpecTest` 覆盖上述规则，`test.sh` 用 schema 检查它的输出。真机 Redmi：`language en-US, region US, time zone Pacific/Auckland, screen 2712x1220 480 dpi 120 Hz, mode diagnostic`，从设备拉回的预览通过 schema。
- 限制：会话起局时用已准备好的 surface 冻结屏幕尺寸，要等启动路径。

### 2026-10-23 / ANDROID-A1-003 / 信号占用普查与缺页读/写位探针（#37 证据）

- 关联：A1 `plat.h` v1（#37）。
- 状态：已验证（只加诊断）。
- 变更：
  - `s2a_android_signal_census`：按内核视角（裸 `rt_sigaction`）和 libc 视角列出每个已装处理函数的信号，标出所属库和 SA_ONSTACK。
  - `s2a_android_fault_esr_probe`：读信号帧里的 `esr_context`，看 WnR 位。
- 提交：#39（008c4caec，列车 c8dbc3040）。
- 验证：真机 Redmi（Android 15，ART + .NET 已起）：
  - 17 个信号有处理函数；10 USR1、12 USR2、23 URG 没人占；
  - 写缺页 ESR 0x92000047（WnR 1），读缺页 0x92000007（WnR 0）。
  - 结论见 #37 里的回复。
- 限制：Android 16 和 16 KB 页设备未测。

### 2026-10-23 / ANDROID-TST-001 / main 上 test.sh 与 App 编译回归修复

- 关联：维护规则 3（纠正回归）。
- 状态：回归/纠正。
- 变更：
  - 合入后出现两处回归：
    - `test.sh` 后续几步 javac 缺 `-cp`，找不到前面已编好的类；
    - 列车合的是 #31 改基前的版本，`GameLibrary` 缺两个 import，main 上 App 编不过。
  - 修复：`-cp` 由 #35 和维护方的 005074cc 补上（#36 因此关闭）；import 由 #38 补上。
  - 门禁现在会跑 `test.sh`；维护方在评估把 App 编译也接进门禁。
- 提交：#35（121d0c85）、#38（8dc327d26）、维护方 005074cc。
- 验证：main 上 `test.sh` 的 Java / 契约部分通过，Docker 构建 App 通过。

### 2026-10-23 / ANDROID-MGT-001 / 接管 Android 全量开发并建立统一状态页

- 关联：A0–A8、AN0–AN4；跨线整合。
- 状态：文档/管理基线；不改变运行代码。
- 变更：新增 `android/docs/STATUS.md`，以 `main@9fc2f569` 为基线整合 A0–A8、AN 里程碑、真机证据、开放工作、关键路径和接管规则；`implementation-plan.md` §2.1 改成当前摘要并链接该页；README 增加入口。
- 验证：基于当前 main 的 `android/test.sh`（10/10 CTest + Java/契约测试）与已合 PR/真机记录；未新增运行代码或真机测试。
- 限制：A1 #54、A4 job/inspect 仍未完成；状态页随进展更新。

### 2026-10-23 / ANDROID-A4-001 / 本地 job 协议 v1 契约

- 关联：A4；inspect/resolve/job engine 的机器可读入口。
- 状态：协议 schema + 样例 + 回归已实现；未接 Android 前端。
- 变更：新增 `job-request.v1.schema.json` / `job-event.v1.schema.json`，覆盖现有 `pack/jobs/main.py` 的核心字段（schema、taskId/jobId、operation、privateRoot、seq、timestamp、type、state），允许 operation/type 专属字段；`validate.py` 对样本做请求/事件跨文件核对，`job_contract_test.py` 覆盖缺/未知 operation、相对 privateRoot、未知事件类型、坏 seq、坏时间戳。
- 验证：`validate.py` 7 份样例、`job_contract_test.py` 8 项、`android/test.sh` 全过。
- 限制：只是协议契约，Android inspect/resolve 生产者和前端调用还没接；未真机。

### 2026-10-23 / ANDROID-MGT-002 / Android 集成分支

- 关联：跨 A0–A4；接管后的集成快照。
- 状态：集成分支，不替代各 PR 的门禁。
- 变更：从 `main@9eb8a8ec` 开 `android/integration`，合并 `android/status`、`a4/job-contract`、`runtime/plat-h-callsites`（#54 draft）；STATUS/§2.1 更新基线。
- 验证：`android/test.sh` 10/10 CTest、Java/契约测试全过；`runtime/gate.sh` 在 Linux 因 Apple 头文件失败，需 Mac 补跑。
- 限制：集成分支不是 main；#54、A4 inspect、A3 backend、A5 仍未完成。

### 2026-10-23 / ANDROID-MGT-003 / android/integration 成为统一开发基线

- 关联：跨 A0–A4；接管后的集成基线。
- 状态：集成分支；不替代各 feature 的正式 PR/门禁。
- 变更：`android/integration` 合入最新 `main@b3e5acff`，并保留 `android/status`、`a4/job-contract`、`runtime/plat-h-callsites`（#54 draft）；STATUS/§2.1 更新基线，明确后续所有 Android feature 分支从该分支开、集成分支只做合流。
- 验证：`android/test.sh` 10/10 CTest + Java/契约测试全过；`runtime/gate.sh` 在 Linux 因 Apple 头文件失败，需 Mac。
- 限制：#54 仍需 Mac gate；A4 inspect、A3 backend、A5 仍未完成。

### 2026-10-23 / ANDROID-A5-W9-001 / profile 草案与确定性输入身份

- 关联：#58 / A-W9；从 `android/integration@ce9db716` 开发。
- 状态：第一批工具已实现、合成验证通过；公共契约与真实翻译待对接。
- 变更：新增 `tools/shader` 的本地 draft1 profile / EffectiveCaps 输入投影 / shader-input schema、严格校验 CLI、profileHash / inputKey / translationKey、规范化 golden vectors；读取实际文件内容，坏 profile、能力未知/不足、同长内容变化、越界路径均不产生假命中。只新增本线文件及本条记录，未改现有 Apple 烘焙器或公共 contracts。
- 提交：本地 `codex/tools-shader-profile`；环境准备提交 `bb597839`，未推送。
- 验证：macOS ARM64 / Python 3.13.9，31 项 Python 测试；.NET 10.0.401 独立 C# 消费两份 golden vector，与 Python 哈希一致；SPIRV-Tools v2026.4 有效 compute 模块通过、截断模块拒绝；JDK 17.0.21 下 Android `gate.sh` 的 Java/契约部分通过；既有 `graphics/tools/shbake/tests/t_unpack_generic.py` 通过。Linux native 门禁本条时尚未执行；未做真机。
- 限制：schema 是供 W5/W12/W11 评审的本地草案，仅覆盖首批字段，不是完整 GAL 能力模型。输出是输入身份，不是已翻译 shader；真实提取/翻译接入、程序 recipe 与 W12 runtime/cache 消费仍待实施，不声明 A5 完成或游戏兼容。

### 2026-10-23 / ANDROID-A5-W9-002 / Linux 门禁与跨平台身份验证

- 关联：A-W9；补充 `ANDROID-A5-W9-001` 的 Linux 未测项。
- 状态：第一批工具跨平台验证通过，真实翻译/运行时集成仍待对接。
- 变更：固定 CPU-only Linux 测试镜像与 SHA-256，补齐 Linux ARM64 的 Python 开发依赖；新增实际验证记录。修正一个缺字段测试，使其独立于前一个错误类型用例。
- 提交：功能基于 `aa22da17`；本条随本地验证提交，未推送。
- 验证：Ubuntu 26.04.1 ARM64 / kernel 7.0.0-34 / GCC 15.2.0 / CMake 4.2.3 / JDK 17.0.20.1，`android/test.sh` 10/10 native CTest + Java/契约全过；Python 3.14.4 / jsonschema 4.26.0，W9 31 项测试及 pip check 通过，golden vectors 与 macOS 一致。VM 大文件迁至外置存储，停机复制 SHA-256 对比、迁移后重启/环境检查通过。
- 限制：这是 Linux 主机与合成输入验证，不是 Android 真机、完整游戏、APK 或正式 Vulkan shader 翻译验收；详细范围见 `tools/shader/VALIDATION.md`。

### 2026-10-23 / ANDROID-A5-W9-003 / 提取适配与真实源码指纹

- 关联：#58 / A-W9，Draft PR #66；只新增本线工具并追加本记录。
- 变更：复用现有 `nxsh_extract.py` CLI 的资源与 NSO 入口，记录内容摘要、来源、诊断和可校验产物；解析失败、部分提取失败、空结果或输入变化不发布成功产物。源码指纹递归收集提取器辅助文件，并复用 MSBuild 闭包读取实际翻译源码字节。
- 验证：macOS 合成 gzip 资源/NSO 真实提取、跨路径与不同并发数一致、混合损坏输入拒绝、内容篡改拒绝；W9 48 项测试通过。现有翻译工程 MSBuild 闭包求值成功（1,592 个输入）。
- 限制：源码指纹不等于编译器二进制闭包；未封装完整 native/runtime 依赖，自动缓存复用关闭；提取覆盖标记 unverified。真实翻译、正式 state/profile 映射与 W12 消费仍待对接。

### 2026-10-23 / ANDROID-A5-W9-004 / 输入包与 W5/W12 对口材料

- 关联：#58 / A-W9、Draft PR #66、n06ody 的 W5/W12 对口回复。
- 变更：显式 per-key state-map、translation-input 包与文件/身份重算校验；复用真实 MSBuild 源码闭包生成 translator 来源。梳理 6 个源码文件的 43 个 capability 读点，提供候选字段、合成 JSON/预期 hash、负例矩阵与未决项。未修改公共 schema、共享 baker 或运行时。
- 验证：macOS 与 Ubuntu 各 60 项 W9 测试通过；实际 extract→prepare→verify CLI 使用真实 1,592 文件闭包成功。Linux 依赖检查通过，修正 /tmp venv 重启失效问题。
- 限制：包为输入材料而非 SPIR-V/运行时程序；正式格式用途要求、state/变体/配方与 translator 身份进入哪一层 hash 尚待对齐。公共契约未冻结，W12 程序重建/driver cache/布局职责不变。

### 2026-10-23 / ANDROID-A5-W9-005 / 共享 shader 键组件

- 关联：#58 / Draft #66，按 owner 与 W5/W12 的共享键收口意见实施。
- 变更：新增共享 keys.py，出包及 W9 复用脚本 key_norm、游戏内容哈希、MSBuild 闭包 + SDK 摘要；两个生产入口均使用实际工作区输入。显式升级源码 producer/提取 recipe/出包组合版本，原 profile golden 不变；补齐已确认的 hash 分层及格式负例对口记录。
- 验证：原 key_norm 6 项通过；实际 1,592 文件闭包经 W9 与 csproj_closure --key 摘要一致。68/68 Python 测试（含实际 MSBuild）通过，覆盖同长同 mtime 改写、两入口一致性及失败无成功键。ShBake 原工程 Release 基线构建成功。
- 边界：共享组件改动尚未验证真实游戏整包性能、Apple GPU 产物或完整 build producer；没有发布公共 EffectiveCaps/schema。

### 2026-10-23 / ANDROID-A5-W9-006 / 显式 profile 的最小 compute 真翻译

- 关联：#58 / Draft #66，落实 n06ody 的最小 compute 与显式 profile 接缝建议。
- 变更：现有 ShBake 增加 compute-smoke --profile，复用原 Ryujinx 与 DiskCacheGpuAccessor；增加显式 Capabilities 上下文重载，原 Apple bake 路径保持原入口。限定 smoke rule/fixture ABI、空用户资源状态；增加实际构建闭包/dotnet runtime 指纹、SPIR-V 校验与有限诊断、结果校验 CLI。修复闭包求值文件句柄告警。
- 验证：macOS 完整 74/74（含真实翻译及 MSBuild）；Linux 68 通过、6 个工具链依赖测试跳过；Apple 路径 CPU selftest-vtg 21/21。真实合成提取→准备→翻译→spirv-val→verify CLI 成功。
- 边界：无条件发射的 subgroup/image 能力仍需 W5 准入对齐；synthetic ABI 仅有本切片布局证据，不是完整游戏 profile。系统依赖未封装、自动缓存复用关闭；未做 W12 运行时加载、GPU、游戏或 Apple 整包验收。

### 2026-10-23 / ANDROID-A5-W9-007 / 结果读取器独立验证

- 关联：Draft #66 的 result verifier P2。
- 变更：私有结果结构校验，非空/唯一 shader、完整引用闭包、固定诊断状态、metadata 与实际 SPIR-V 一致性及输入 identity 结构检查；没有新增公共 schema。
- 验证：9 项结果回归通过，涵盖重算 hash 后的空集/重复/缺引用/额外文件/伪造状态/坏 identity；已生成的合法真实 compute 产物经 spirv-val 与新 verify 通过。

### 2026-10-23 / ANDROID-A5-W9-008 / dotnet host 明确识别

- 关联：Draft #66 的 Homebrew wrapper P2。
- 变更：仅支持真实原生 host 或其符号链接，先校验完整 fxr/Core runtime，再求值 MSBuild；wrapper/缺失 runtime 返回可操作的 ENVIRONMENT_ERROR。host、fxr、Core 内容仍全部进入指纹。
- 验证：5 项 host 回归覆盖真实 host/符号链接、带 libexec 的 wrapper、缺失组件、逐组件身份变化及 MSBuild 前拒绝。

### 2026-10-23 / ANDROID-A5-W9-009 / 真实 GAL metadata 与 W12 宿主对拍

- 关联：Draft #66 审查与 W12 #83（固定 c06092fc）。
- 变更：同一 ShaderProgram 经 BuildForCompute 取得完整 GAL 对象；独立探针引用已验证 producer DLL 和外部锁定 codec 源码，显式传入 options/specialization 并检验往返。结果包升级私有 draft2，新增真实 SPIR-V/GAL 驱动的 W5 准入请求；没有新增 selector/key 或公共 schema。
- 验证：macOS 93/93（包括 W12 方法内 17 项断言）；Linux 86 通过、7 跳过；Apple CPU selftest-vtg 21/21。实际四组 descriptor 数 19/16/128/32，usage 数 1/0/0/0，经 codec 完整保留。
- 边界：W5 统一设备准入、公共版本、W12 loader/device generation 仍待对口接线；unverified/runtimeProgram=false。pack 顶层 profileHash、Apple 整包与设备验证继续跟踪，缓存优化独立评估。

### 2026-10-23 / ANDROID-A5-W9-010 / smoke profile 资格校验

- 关联：Draft #66 新 P2，完整重封装能让未注册 rule@2/subgroup64 被 verify 接受。
- 变更：翻译、结果读取与准入请求生成复用私有 smoke 资格门，对齐 ComputeBake.Caps 的规则/ABI/版本/subgroup/feature/transforms/requirements；通用 profile 规范化不变，不引入设备选择器。
- 回归：24 个通用格式合法的 profile 变体（5 个支持、19 个不支持）；完整重封装同步更新 profileHash、identity/translationKey、metadata、request、文件清单与 artifactHash。移除资格门的负控仍能通过其它检查；真实 C# producer 和完整 verify CLI 对拍覆盖同一集合。
- 边界：资格检查不认证来源、不授予设备准入；仍固定 unverified/runtimeProgram=false，W5 的权威准入口继续由该线推进。

### 2026-10-23 / ANDROID-TOUCH-TRANSPORT / 独立通用触点实验
- 关联：#58 / A-W4，与 n06ody 对齐的独立触点切片。
- 变更：独立 JNI、UI 所有权分流、预分配触点状态、64 帧非消费历史及取消/溢出重同步；默认关闭，编入后可同 APK 切换。
- 验证：新增 C 机制测试和 Java 状态测试，纳入 test.sh；实际构建/运行结果见 PR。
- 限制：视口接口为候选，无正式生产者或 HID/手势消费者；没有游戏/真机/核心指标验收。公共 HostApi、托管输入、core/GPU 不在此切片。

### 2026-10-23 / ANDROID-TOUCH-REVIEW-001 / 修复实验分流缩小控件命中区
- 关联：A-W4 触点协作 / PR #68 的 P2 审查。
- 状态：已实现，待评审/集成。
- 变更：控件与分流共用 Control.hit；View 使用可主机测试的 TouchRouting，保留 DOWN 归属及隐藏控件行为。补充 Switch 触屏有效矩形、主机模式和 Surface 代次的接缝约束，未提前实现 W6。
- 验证：边缘/开关/视口/隐藏/多指回归及旧规则失败负控；LF 快照 test.sh 11/11 native + Java/契约通过；API34 App Java 编译、ARM64 ON/OFF 构建通过。
- 限制：未执行真实 MotionEvent→View→JNI/HID、未重新安装修复 APK、未做真机或游戏验收；旧 APK 记录不代表本修复。

### 2026-10-23 / ANDROID-TEST-RTMIN-001 / 信号准备测试隔离继承的忽略状态

- 关联：#58；Android host microtests 的确定性。
- 状态：测试修正；生产信号处理代码不变。
- 变更：`guest_signal_test` 显式建立默认 SIGRTMIN 前置状态并在测试后恢复；另验证已有 SIG_IGN 不被 runtime preparation 改写。此前当前 Linux 容器进程继承 SIG_IGN，旧测试误以为默认处理，集成基线 `ce9db716` 与 W5 候选均同样失败。
- 验证：Debian 12 / Linux ARM64 容器断网执行 `android/test.sh`，10/10 CTest、Java/BootSpec/安装/契约及 14+7+8 Python 用例全部通过；未做真机。
- 限制：Linux host 测试，不替代 Android bionic/设备信号与 guest 执行验收。

### 2026-10-23 / ANDROID-A-W5-001 / Vulkan 已创建设备能力首批修复

- 关联：#58 / A-W5；基线 `android/integration@ce9db716`。
- 状态：首批代码与 host 回归完成，完整 W5 与 Android 驱动验收待完成。
- 变更：沿用既有 Ryujinx Vulkan 单 runtime，从实际成功的 device request 复制 feature/extension 快照，迁移相应能力判断；补查可选 feature、显式启用受支持的压缩/条件渲染/Layer/Viewport 输出；当前 combined SPIR-V 输出能力要求两位同时启用。D2R fit/gap 后只采用能力区分机制，不移植 NVN engine/资源模型。
- 提交：`da1e25fe`、`0870160b`；Ryujinx 补丁 0191/0192 与清单一致。
- 验证：37 项 CPU 断言通过；恢复基线 GAL 判断、将双位 AND 改为 OR 的负控均失败，恢复候选后通过；`compat/verify.sh` 通过。结合 ANDROID-TEST-RTMIN-001，完整 `android/test.sh` 在 Linux ARM64 断网通过（10/10 CTest、Java/契约）。
- 限制：未构建本批 Android APK、未做真实驱动/像素/游戏/生命周期或 Apple 运行回归。版本分流、完整能力规则/profile、格式/限额、rollback/stop/device-lost 及 W6 接口未完成；只支持单个输出位且无 GS 的组合未验收。跨目录 Ryujinx 接缝仍需对应 owner 审核。

### 2026-10-23 / ANDROID-A-W5-002 / 宿主缓存能力准入与索引修复

- 关联：#65 review；#71 的复现与验收已合并回 #65，不另开修复 PR。
- 变更：现有 API/vendor 宿主文件名加入版本化有效能力身份；失效保留 guest/shared，lazy、warm 预读和批量写入使用同一身份。宿主 TOC 按 shared programIndex 写入，空 binary 或清 host 后留下空槽而不移动后续程序。保留句柄重复检查 header/代际；截断、非法压缩及声明输出长度不符及时拒绝。
- 验证：root 独立执行缓存 116 项、设备能力 37 项、ShBake VTG 21 项、特化读取 42 项及现有宽屏单测通过；空 TOC 有限退出。187 个 Ryujinx 补丁重建与源码一致；新增 0193 随源代码、series 和改动清单提交。修复前真实缓存路径已有 9 个失败断言；声明输出 256→255 的负控也已复现。
- Apple 影响：ShBake/运行时继续共用 NxCaps；新 seed 复制、追加与重启命中已做宿主测试。旧无能力身份的 host seed 被拒绝，guest/shared 保留；需要重烘 seed 才能保持离线命中，不能把拒绝旧缓存等同于维持首局性能。
- 限制：renderer 边界使用记录器，未执行真实 Vulkan binary loader、Apple GPU 或 Android 游戏；未新增不可信缓存内存配额，代际时间 token 不提供绝对唯一性。不更改 W9 公共键或开启尚未实现的 Vulkan 二进制加载器。

### 2026-10-23 / ANDROID-A-W5-003 / PR65 跟进新集成基线并重验

- 关联：#65 / A-W5；同步 `android/integration@937d3ae5`。
- 状态：分支合流完成、宿主回归通过；等待 owner 合并 PR。
- 变更：冲突仅在补丁 series 与登记清单；保留上游 0191–0195，将本 PR 三份补丁顺延为 0196–0198，补丁字节和 16 个本任务源码/fixture 文件均未改变。旧条目的编号保留为历史记录。
- 验证：192 个补丁重建一致；合流后重新离线构建并通过缓存 116、能力 37、VTG 21、特化 42、更新后 widen 427 项；完整 Linux ARM64 Android test.sh 的 10/10 CTest、Java/契约及 Python 14+7+8 通过。
- 限制：未做 APK / 真机；integration 到 main 仍由 owner 重烘马车8并验热命中 N 不变、首遇现编 0，宿主验证不替代此门。

## ANDROID-ENV-107-001 — Android APK 只读环境 doctor

- 增加 doctor.sh / doctor 模块：从 Dockerfile、Gradle、gate、NativeAOT/编解码脚本读取和交叉校验版本正本，输出文本/JSON与仅打印的准备计划。
- 支持显式复用工具/缓存目录；检查 SDK 载荷/包标识、精确 AOT 还原/运行包/编译器、OpenSSL、Opus/VP8 含许可与 shim key；缺项、架构不支持及离线闭包未证实不报绿。
- 不下载/安装/启动服务/执行构建；Apple Silicon 仿真容器未实证，完整环境与 APK/签名验收待补齐。现有构建、共用 tools/doctor 与运行时代码未改。

### ANDROID-ENV-107-002 — 保存复用路径与严格离线模式

- 新增 version=1 严格 JSON 配置；CLI > 配置 > 环境 > 默认值，路径相对配置文件解析，无第二份版本 pin。
- --offline 不连接 Docker daemon；损坏 JAR/POM、archive 成员截断和宿主 ISA 混入不再被非空文件检查放行。
- 保持只读、零安装/下载/构建/设备操作，完整 APK 验收状态不提升。

### 2026-10-23 / ANDROID-A5-W9-011 / 同步 integration 与资格修复复验

- 关联：#66 新 profile 资格 P2、owner 的基线同步要求。
- 提交：`42ab0cf1` 修复；`957fdc41` 合入 `android/integration@3d1db8ff`，保留双方 CHANGELOG 及共享 MakeContext/key 接缝。
- 验证：合流后 W9 macOS 97/97（含 24 组 producer 资格对拍、19 组完整重封装负例及 W12 17 项断言）；Linux W9 88 通过、9 跳过。W5 cache 116、feature 37、Apple CPU VTG 21、key_norm 6 通过；Linux Android CTest 10/10、Java/契约及 Python 14+7+8 通过；192 个 Ryujinx 补丁核对一致。
- 产物：新 1595 文件闭包 producer 完成真实提取/翻译/codec 流程，SPIR-V/profile golden 保持；本次构建身份详见 tools/shader/VALIDATION.md。
- 边界：仍为 Draft；W5 统一设备准入、W12 Vulkan loader、pack profileHash 与整包/真机验证另行推进。

### 2026-10-23 / ANDROID-A4-W7-001 / inspect/resolve 生产者与冻结输入清单

- 关联：#58 / A-W7；A4、GameInputManifest v1。
- 状态：已实现／待评审集成；未做真机。
- 变更：`nx_unpack <keys> sources.inspect <containers...>` 与 `games.resolve <request.json>`，显式选择 base/update/DLC，复核内容 ID／CNMT hash／大小与源身份；生成现有 v1 manifest 和命名空间内的逐文件／系统数据锁。缺失、未知、损坏与 license-only 分开，旧 `--inspect` 保持原协议。
- 提交：分支 `a4/inspect`；CLI、成功／失败 JSON fixture 及测试入口见 `pack/nx_unpack/README.md`。
- 验证：Server macOS arm64、.NET 10；人工容器／BKTR 基础+更新对照、NSO/NRO、加密 NCA／rights ticket、缺票据／错误密钥／冲突票据、系统数据及失败 JSON：65 项断言、5 份 manifest 契约通过；旧入口两份只读样本输出逐字节一致。
- 限制：未接 W8 job 层、未做源码到 APK／真机／商业游戏可玩验收；源文件由 hash 绑定，快照与构建消费者仍须复核，不把清单当文件锁。

### 2026-10-23 / ANDROID-A-W4-001 / 有界 HostApi UI 请求生命周期

- 关联：#58 / A-W4；既有 `s2a_host_ui_v1` 的独立 native broker 切片。
- 变更：请求和应答拥有自己的有界副本，进程内不复用 ID；producer take/complete 校验 session，RANGE 保留答案，cancel/stop 唤醒等待。超时后持锁重查真实谓词，避免丢失同时到达的回答或取消。默认 unavailable，不注册 UI capability，不修改正式请求 schema 或触点路径。
- 接入：现有 Android native CMake 目标加入 broker；host fixture 加入原 CTest/test.sh，不引入第二套 runtime 或公开 HostApi ABI。
- 验证：root 独立 macOS ASan/UBSan/Werror 199 项通过；Debian 12 ARM64 断网完整 host test.sh 11/11 CTest、Java/契约、Python 14+7+8 项通过。测试父进程建立基线信号 fixture 所需的 SIGRTMIN 默认前提；生产信号代码未改。
- 限制：未构建 APK/Android bionic 运行，未接真实 UI/JNI/C# applet。W11 需确认请求/应答 schema 和 RANGE/取消解释，W3/W4 后续完成正式 producer 与生命周期接线；本切片不代表完整 W4 验收。
### 2026-10-23 / ANDROID-A-W6-001 / 窗口 lease 与呈现退休账本首批实现

- 关联：#58 / A-W6；既有 lease v1 的 managed consumer 与 submit/present 独立退休。
- 状态：已实现、宿主验证通过；待生产接线。
- 变更：消费现有 80 B state / 56 B 函数表，按 session/generation/swapchain/image 保留窗口与 GPU 使用债务；没有完成证据不发 ACK。测试 runner 使用独立 attempt 和原子 RUNNING/PASS/FAIL，失败不沿用旧成功。
- 提交：实现 `542495c4`；本条与独立验证说明随同一功能分支交付。
- 验证：68 项 managed 检查、Linux ARM64 原 C lease 联合 88 项通过；两份坏账本及实际编译失败、prebuilt 身份失败负控符合预期。未做真机。
- 限制：未接 Vulkan WSI、GAL worker、ANativeWindow 或游戏；仍需 W5 device/queue 生命周期及跨 owner 视口合同，#65 能力修复不代表这些依赖已完成。
### 2026-10-23 / ANDROID-A-W12-001 / GAL 与 SPIR-V 程序配方 codec 首批实现

- 关联：#58 / A-W12；普通 compute、VS+FS 程序配方的有界持久化表示。
- 状态：已实现、宿主验证通过；待生产接线。
- 变更：直接使用真实 GAL metadata，保存 SPIR-V、资源布局、管线状态及 specialization；W9 identity 仅作 opaque 引用。拒绝损坏/未知数据及不支持的 VTG/TF/helper；校验活动顶点 buffer span、descriptor/usage 容量，区分标量 extent 与记录分配预算。
- 提交：实现 `d93399e0`；本条与独立验证说明随同一功能分支交付。
- 验证：干净树独立 97/97 host、29/29 metadata 边界、3 个 SPIR-V validator 通过；512 次变异中 227 次无损接受、285 次类型化拒绝。Release 零 warning/error，36 项输入摘要一致；未做真机。
- 限制：未接 `GetBinary/LoadProgramBinary`、真实 Vulkan pipeline 或游戏；依赖 W9 产物身份、W5 能力与设备生命周期、W6 屏幕生命周期，不表示 W12 全部完成或已有性能收益。
### 2026-10-23 / ANDROID-A2-W3-001 / 诊断目标链接准入与真实 ELF 审计

- 关联：#58 / A-W3 首批；Android NativeAOT archive、provider 与启动节边界。
- 状态：已实现诊断链接检查，宿主验证通过；真实核心仍未接入。
- 变更：诊断默认不变，game/未知模式配置失败；从实际 archive/link inputs 核 provider、ELF 符号拼写及启动节精确地址/归属，保存输入身份，失败清除旧 PASS。文案不再把发现 S2A_Init 导出当作已执行。
- 提交：实现 `fe375c90`，跨 linker fixture 根修 `8b3471dd`；本分支同步 `android/integration@937d3ae5`。
- 验证：13 项 host、真实 GNU/LLD AArch64 ELF 正反例通过，旧审计四项缺陷仍被同一 fixture 捕获；Linux完整 test.sh 的12/12 CTest、Java/契约及 Python14+7+8通过。GNU与LLD自然GC行为不同，稳定坏ELF由显式DISCARD构造并检查实际缺节/未定义根，未跳过负控。
- 限制：没有执行 Android S2A_Init/guest，也未完成 APK/真机验收；节非空及根边界正确不证明全部module记录齐全。真实W3仍需W1/W2前置和实际初始化/IPC/线程/svc证据。

### 2026-10-23 / ANDROID-A2-W3-002 / 托管可选接口绑定实际 provider

- 关联：#58 / A-W3、PR #86；在原诊断链接审计上补真实托管消费者接线。
- 变更：`Native.UseLinked(owner)` 只从 composition 保活的实际原生库解析 clock/det；完整候选校验后再发布基础槽与 extras，det 半组失败不留半表。相同 owner 重复调用幂等，拒绝热换；Apple 无参入口保留原可选语义。AndroidSelfTest 使用进程期 Lazy 句柄，报告 availability 与 `game_ready=false`。
- 验证：实际 macOS loader + 原生产 AndroidSelfTest/NativeTickSource，11 个独立进程、156 项断言通过，root 独立复跑一致；原消费者实际 runtime 红例已保存。Spec/Standards 独立审查无阻断。
- 限制：host 夹具只实现实际测试调用，不是原生核心；未验证 Android linker namespace、NativeAOT 静态产品链接、全部原生实现或 S2A_Init/游戏。21 项 DirectPInvoke 声明保持不变；原 #86 链接闭包与启动节审计保留，完整 W3 仍未完成。
### 2026-10-24 / ANDROID-A2-W3-003 / 共用相位与纳秒时钟真实链接

- 关联：#58 / A-W3、PR #160。
- 变更：Android 链接真实 `alt.c` 与 `os.c`；按共享层 review，Apple/Android 相位统一经 `now_ns()` → `plat_now_ns()`，起点与 period 均为纳秒，删除 alt 内平台分叉。Apple 日志初始化行为保持，只有 Apple 头按平台限定。
- 验证：旧分支在可控纳秒边界负控 9 项中 5 项失败；修复后边界和禁用共 21 项通过。Apple 真实时钟及信号查询、MARK consumer、原生 alt/ap_host 两组门禁通过；macOS/Linux 链接审计各 14 项通过。root 以源码 `66de9555` 完成离线 Android 静态 NativeAOT APK assemble/lint、ELF/ZIP 对齐和签名校验。
- 限制：完整 contrib 六步四绿两红（既有 vawin 四项失败、缺 iOS 改写输入）；本轮修复未上真机。诊断 APK 不执行真实 S2A_Init/guest，诊断目标无游戏 MARK 调用链，不宣称游戏或同局 A/B 可用。

## ANDROID-W5-002 — 保留实际 subgroup 查询事实（2026-10-23）

- 问题：既有 VulkanRenderer properties2 查询已获得 subgroup size/stages/operations，但 HardwareCapabilities 仅保留 size，后续无法核对实际阶段与操作集合。
- 改动：沿同次查询按值保存三项及查询状态；已查询零 mask 与未查询默认态分开。只提取原属性查询/发布接缝，不新增 device/renderer、公开 schema、cache key 或 shader 准入规则，不改变既有 GAL 策略。
- 验证：受控 Vulkan dispatch 驱动真实查询→HardwareCapabilities→原 GAL size 消费，原 size-only 保存负控失败；最终 79 项 CPU 断言通过（原 37 + 新 42），root 独立复跑通过；193 个 Ryujinx 补丁重放一致。
- 边界：无 Android APK、实际 Vulkan/MoltenVK、像素或游戏验收；此状态不代表 created-device generation 或模块/layout 已准入。Metal/GAL 代码未改，Apple 实际 GPU 行为未重新验证。

### 2026-10-23 / ANDROID-W9-012 / 编译闭包判键求值调度优化

- 关联：#58 / A-W9，接续 #66；从 `android/integration@3d1db8ff` 独立开发，W5 唯一设备准入口仍待后续。
- 变更：MSBuild 编译项查询与预处理分开调度，合计最多 8 个进程；引用就绪即继续，失败不返回部分清单。修正含空格路径的 props/targets 导入漏项。每次仍完整求值，未引入 stat-only 命中或新身份算法。
- 验证：macOS 12/12（含真实 MSBuild 和固定 #66 共享键兼容）；旧调度的父预处理/慢兄弟阻塞两项反证失败。Linux 调度 6 通过、工具链依赖 6 跳过；Android 10/10 CTest、Java/契约及 Python 14+7+8 全过。
- 测量：同一工作区三轮交替比较，1,594 项输入/12,584,795 字节一致；closure 求值中位数 5.469→3.892 秒，约减少 28.8%。仅本机求值耗时，不代表整包/游戏提速；复现与范围见 `tools/tests/README.md`。
- 合流：与 #66 有两处源码文本冲突，须保留本批调度/空格匹配和 #66 的工作区内容键；CHANGELOG 追加记录双方均保留。独立组合文件的 W9 内容身份与 main --key 已对拍，最终合流门禁仍由维护者执行。
- 限制：未完成持久结构缓存、脚本闭包噪声治理、W5 设备准入或 GPU/整包/真机验收。

### 2026-10-23 / ANDROID-W9-013 / 判键优化同步最新集成基线并复验

- 基线：`android/integration@d7c8dd5e`，合流 `953ac9b3`；本批三个 Python 文件字节不变，双方 CHANGELOG 历史有序保留。
- 复验：macOS 12/12；Linux 调度 6 通过、工具链 6 跳过；Android 10/10 CTest、Java/契约和 Python 14+7+8 通过。
- 一级自检过渡：当前仍无 contrib_check.sh，执行 gate.sh 原语法步骤及本批相关测试。Linux 147 个脚本可解析；macOS Bash 3.2 对基线原有 dev_run.sh/gc_test.sh 报语法错，两份文件均与新基线字节相同且基线也复现。保持 Draft，未宣称全量门禁通过。
- 性能读数继续绑定 ANDROID-W9-012 的合流前工作区；未重新标为新基线测量。


### 2026-10-24 / ANDROID-A5-W9-014 / 新 integration 金样迁移与测试依赖修复

- 关联：PR #66 的两项集成反馈；同步 `android/integration@cc16b5fe`（含 #128），合流 `3ffd8c51`。
- 合流：保留 tool_keys 的 CS/XC 调用、有界 MSBuild 调度与空格导入处理，以及 W9 共享内容键接线；双方历史记录保留。
- 修复：真实 producer 重生成 SupportBuffer 尾增 render_scale_y 后的 772 B SPIR-V；同步 hash、4218 B recipe 断言与当前文档，旧验证历史保留。闭包 shell fixture 补齐真实 keys.py/key_norm.py，生产代码与原断言不变。
- 验证：macOS W9 97/97（含 W12 方法内 17 项检查）、#128 真实调度/共享键 12/12；wrapper 修前红、修后六项绿；Apple CPU VTG 28/28、key_norm 6/6。Linux W9 88 通过/9 跳过、调度 6 通过/6 跳过；Android 主机 CTest 14/14、Java/契约与 Python 14+7+8 通过。
- 限制：不改变 Caps/profile 或运行时准入状态；未做 Vulkan 创建、dispatch/readback、Apple 游戏整包及 Android 真机。贡献者入口结果另见 PR 摘要，最终集成门禁和合并交 Android 维护者。


### 2026-10-24 / ANDROID-A5-W9-015 / 补齐出包键测试 fixture

- 关联：#66 同步后的贡献者自检；唯一实际红项为 prebuilt_tools_test 的临时 repo 缺 keys.py。
- 修复：临时 repo 同时复制真实 keys.py/key_norm.py；保留工具二进制、程序集、SDK/Metal 变化与目录迁移/缺失拒绝断言。
- 验证：原自检该项红，补齐后独立脚本通过；生产实现未变，最终贡献者自检摘要见 PR。
- 环境限制：本机缺 Xcode 27.1 / iOS SDK，iOS 全量编译和 native 钩子仍由有完整工具链的维护者补验。

### 2026-10-23 / ANDROID-A4-W7-002 / 零售摘要修正与门禁路由收尾

- 关联：#129 / A-W7，接续 ANDROID-A4-W7-001。
- 变更：CNMT 尾部开发身份不再错误等同零售字节 SHA256；精确布局与 Meta/FS、来源和内容身份校验保留。登记 nx_unpack、manifest schema/validator、vendored LibHac 的门禁依赖，补源码/测试/依赖必触发及文档/Android 外壳/调度/改写器不触发的回归；未改路由器 fail-safe 或放宽旧断言。全局未分类构建文件继续走原全钩子规则。
- 同步：合入 android/integration@cc16b5fe；仅 CHANGELOG 冲突，保留双方全部历史。
- 验证：Server macOS arm64/.NET 10 离线输入解析 75 断言、6 份 manifest schema 通过；gate_route、shared_path、shell_lint 通过。撤销本次路由登记的负控退出 1。维护者另在 9819312f 复验零售 3 候选/空 diagnostics、旧解包 2126 文件及 nacp-only 3 文件一致、密钥 0/222 泄露。
- 限制：成功 JSON 仅本地私有 IPC，上传诊断前复用共享脱敏；本轮未新跑真实游戏、APK、Linux native、Xcode/iOS 或设备门禁。Server 缺完整一级门禁工具，不将专项通过记为全量验收；仍由安卓维护者复审合入。

### ANDROID-ENV-107-003 — 精确范围、NDK 消费方与工具宿主验证

- 合法 NuGet [v]、[v,v]、[v, v] 正确解析；拒绝非精确范围，保留矛盾编译器来源未验证状态。
- NDK 逐项校验实际赋值与路径；重复或未知表达式失败，不以子串证明版本。
- 工具要求执行权限及匹配宿主 ELF/Mach-O；脚本与普通数据分开，未知格式 unverified。测试根规范化修正路径别名误报。
- 仅检查器与其回归/文档；完整平台、离线闭包及 APK 验收不提升。
### 2026-10-24 / ANDROID-W5-003 / Vulkan 1.1 设备支持

- 关联：#199（AT01 跨设备回归、AR 系列）、#200 首游戏运行；A3 / W5 后端。维护者直接合入 `android/integration`（不走 PR）。
- 状态：已实现，作者真机验证通过；不代表稳定可玩。
- 变更：1.2 核心特性结构只在 1.2+ 设备的查询/创建链里挂载；1.1 设备改挂并用对应扩展启用等价特性（`VK_EXT_descriptor_indexing`、`VK_KHR_uniform_buffer_standard_layout`、`VK_KHR_8bit_storage`、`VK_KHR_shader_float16_int8`），`DeviceFeatureSnapshot` 把它们映射回同一 Vulkan12 视图，消费方不新增分支。GLSL 按设备实际版本编译：1.1 用 `SPIR-V 1.3 / TargetEnv Vulkan 1.1`，1.2+ 维持 `SPIR-V 1.5 / Vulkan 1.2`。Android 游戏的硬门槛从 Vulkan 1.2 降为 1.1。
- 提交：`compat/patches/0218-android-vulkan11.patch`（3 个文件）+ `graphics/vulkan/core/DeviceFeatureSnapshot.cs`。
- 验证：Redmi 22081212C（Adreno 730，Vulkan 1.1.128，Android 16，4 KiB 页）跑 Diablo III: Eternal Collection 2.7.7.92380（资源包 `sha256-042eb2a459f6`）：GPU 初始化、着色器缓存、标题画面、开场 CG、Autosave 载入、主菜单 3D 背景均正常出画；同一份代码在 1.2 门槛下会在 `VulkanRenderer.SetupContext` 直接拒绝。`compat/verify.sh` 通过（上游 + 212 补丁 = 树内源码）；`graphics/vulkan/core/tests` 新增 1.1 场景（不挂 1.2 结构、不发布 1.2 能力位、不启用未宣告扩展），82 项断言通过；`android/gate.sh` 通过。
- 限制：只验证了 Adreno 730 的 1.1 驱动，Mali 未测；1.1 下 descriptor indexing 等仍以扩展形式提供，能力集与 1.2+ 不同。间歇 `2162-0001`、退出时 WSI 退休超时、着色器缓存批量作废仍开放（#199 AR01/AR03、W12），本条目不把它们算作已修。

### 2026-10-24 / ANDROID-W6-001 / Android 窗口退休不再终止会话

- 关联：#199 AR03、W6 / WSI、A3；接 `ANDROID-W5-003` 的 1.1 真机验证。
- 状态：已修复，真机验证通过；`SUBOPTIMAL` 呈现与 Reacquire 模式仍开放。
- 变更：`AndroidWindow.Poll` 不再在 1.5 秒拿不到呈现退休证明时抛异常终止会话——退休链保留、按 2 秒周期上报 blockers（acquires/submits/presents/uncertain/deviceLost），会话与 lease 继续存活。旧链存续期间不创建新交换链（Android 对同一 native window 的第二个交换链返回 `VK_ERROR_NATIVE_WINDOW_IN_USE_KHR`），证明完成后先销毁再按当前 stamp 重建。`QueuePresent` 返回 `SUBOPTIMAL_KHR` 时先比较实际 surface extent：仅 extent 真变化才退休重建，纯粹 suboptimal 保留现有链（每 2 秒一条日志），避免 insets/系统栏变化引起每帧换链。新增 `[wsi]` 观测：gen/rev/extent/insets/mode、retire 原因、退休 blockers、销毁。
- 提交：`graphics/vulkan/wsi/AndroidWindow.cs`、`graphics/vulkan/wsi/tests/Program.cs`。
- 验证：WSI 主机测试 93 断言 + 真实 C lease 通过（新增“旧 revision 退休但保留 / 新 revision 独立呈现 / 退休链停止 acquire”用例）；真机 Redmi 22081212C（Adreno 730 / Vulkan 1.1.128 / Android 16）：展开再收起通知栏（insets 变化）后进程存活，整局只创建 1 个交换链、0 次销毁，present 持续 `SUBOPTIMAL` 但画面正常（标题/菜单/开场 CG 均出画）；修复前同场景 1.5 秒后抛 `TimeoutException` 并终止进程。
- 限制：`SUBOPTIMAL_KHR` 在 insets 变化后持续存在，根因未定（当前保留链继续呈现，不重建）；Reacquire 模式（无 present fence）退休后缺少再取图证明，仍只能保留不能销毁；最终停机若始终无证明，runtime 仍按 fail-closed 终止进程（有意保留）。

### 2026-10-24 / ANDROID-A5-S2-001 / Vulkan 离线出包端：设备 profile、VKPB 宿主记录与包 manifest

- 关联：A5 / 着色器方案 S2 出包端（Producer）；接 `ANDROID-A5-S1-001`。
- 状态：已实现，宿主 CPU 验证；未做设备出包、Android 装包、真机 GPU/像素验收。
- 变更：新增显式 Vulkan 翻译 profile 契约（`VulkanProfile`）：规范化 capabilities 与身份同源，解析时重算 `ProgramBinaryProfile.Create` 并拒绝身份不符；设备侧 `VulkanRenderer.S2ASerializeProgramProfile()` 在 `S2A_SHADER_PROFILE_OUT` 下导出真实 profile（失败只报红、不改游戏路径）。ShBake 新增 `--vulkan-profile/--content-root/--spirv-val` 分支：按 profile 能力翻译（不继承 Apple `NxCaps`），用同一 VKPB codec/身份写宿主记录，逐支 SPIR-V 过 `spirv-val --target-env`，产出 `vulkan/generic/<profileKey>/{profile.json, manifest.json, shcache/<titleId>/}`；`GpuContext.S2AHostProgramCacheDiscriminator` 让离线宿主文件名与设备读取名一致。新增 `ShaderPackManifest` 作为两端共用校验器（schema/模式/后端、标题号、A0 内容根、VKPB 身份、翻译器程序集、逐文件长度与 SHA-256、精确文件集）。VTG/TF/补出的几何直通阶段不在 VKPB v1：计 `unsupported`、报 🔴、设备按需翻译；编码/metadata 失败计 `failed` 并让出包退出 1。Apple 默认 `--xc` 路径与 `NxCaps` 判据未改。
- 提交：`android/shader-cache`；Ryujinx 补丁 `0241-shader-vkpb-s2.patch`；`graphics/tools/shbake`、`graphics/vulkan/cache`、`graphics/vulkan/runtime`。
- 验证：Vulkan/GPU/Android AOT Release 构建通过；宿主 codec 套件 153/153（新增 29 项 profile/pack 检查，含身份重算、能力载荷调包、版本/字段/截断、内容根/翻译器/文件摘要/未列文件/路径穿越/符号链接负例）；`compat/verify.sh` 一致（上游 + 226 补丁 = 树内源码）。未建 VkDevice、未跑游戏、未用真实游戏或设备 profile 跑 ShBake。
- 限制：Android 装包端（mount/导入、包指纹、运行时内容根来源）未实现；离线包不含 driver cache 数据与 S3 配方；ShBake 的 Vulkan 分支只在宿主编译，未用真实抽取集执行；S1 真机 GPU/像素验收仍缺。

### 2026-10-24 / ANDROID-MGT-012 / 本机构建（无 Docker）与 JDK 17 探测

- 关联：W11；出包与门禁可用性，用户直派。
- 状态：已实现，作者 Linux 环境验证通过。
- 变更：新增 `android/host/build.sh`，按 `docker/build.sh` 同序跑 `cs/build.sh`、`openssl/build.sh`、`assembleDebug` / `lintDebug`、`verify-apk.py`、`apksigner verify`；缺 SDK 包给出确切 `sdkmanager` 命令，缺 JDK / .NET 直接报红，不自动安装。`cs/build.sh`、`openssl/build.sh`、`codecs/build.sh` 的 `/cache` 改为 `S2A_BUILD_CACHE`（缺省仍 `/cache`，Docker 行为不变），`cs/build.sh` 支持 `S2A_ANDROID_DOTNET` 直接使用宿主 SDK。JDK 17 候选表抽到 `android/tools/jdk17.sh`，新增 `$JAVA_HOME` 与发行版 `/usr/lib/jvm/*17*` 候选并逐个验版本（`JAVA_HOME` 指着 21 会继续往下找），`gate.sh` 共用该脚本。`gradlew` 补可执行位。
- 提交：本分支。
- 验证：Arch Linux（JDK 17.0.21、.NET 10.0.113、SDK 36 / NDK 29.0.14206865 / CMake 3.31.6）`host/build.sh` 首次全绿，产出 10.6 MB APK，`verify-apk.py` 与 `apksigner` 通过；同包装机（小米 22081212C / Android 16 / Adreno 730）冷启 671 ms，NativeAOT probe、OpenSSL、Vulkan 1.1 surface 与 120 Hz present 日志正常；`gate.sh` 不带 `S2A_JAVAC` 直接找到 `/usr/lib/jvm/java-17-openjdk/bin/javac` 并通过。
- 限制：只覆盖 Linux 宿主，macOS 仍走 Docker 或 Android Studio；`host/build.sh` 不装 SDK 包、不跑 adb，真机专项验证仍由 `tools/device_selftest.sh` 等单独做（本机 HyperOS 的 `run-as` 被 SELinux 拦，rewrite 自测未做）。

### 2026-10-24 / ANDROID-A5-S2-002 / Vulkan 离线包装包端：内容根准入、暂存导入与包指纹

- 关联：A5 / 着色器方案 S2 装包端（Consumer）；接 `ANDROID-A5-S2-001`。
- 状态：已实现，宿主 CPU 验证；未做设备出包、真机装包与跨进程命中。
- 变更：新增 `ShaderPackLayout`（游戏数据目录 → 内容根、包目录、缓存目录）与 `ShaderPackInstaller`：在 GPU 线程 `Initialize` 之后、`InitializeShaderCache` 之前，按设备真实 profile 选中 `shaders/vulkan/generic/<profileKey>`，核对 title/contentRoot/VKPB 身份/翻译器程序集/精确文件集/链接；逐文件边复制边 SHA-256，先落同盘暂存目录，完整匹配后才整体改名替换缓存；同包（指纹 + 文件长度一致）不再覆盖，保留本局学习结果；换包整份替换并把新增程序留给按需学习。失败一律 🔴 并按需翻译，不伪装命中。内容根取自已安装 revision（`<game>/revisions/<contentRoot>`），不依赖 A4 未完成的 BootSpec 字段。另把 profile 导出移到 `Initialize` 之后（S2a 放在 `Start` 时设备尚未建立）。
- 提交：`android/shader-cache`；`graphics/vulkan/cache/ShaderPack*.cs`、`graphics/vulkan/runtime/AndroidVulkanRuntime.cs`、`android/core-runtime/AndroidGameRuntime.cs`。
- 验证：Vulkan/GPU/Android AOT Release 构建通过；宿主 codec 套件 168/168（新增 15 项 layout/installer 检查：首次种入、同包保留学习、缺文件重种、manifest 后篡改字节拒绝且不留缓存、导入期符号链接拒绝、崩溃遗留暂存目录清理）；backing control 299 断言通过（夹具补上真实 Vulkan 程序集与 Silk.NET 依赖，装包点在无游戏目录时不再动作）；`compat/verify.sh` 一致。未建 VkDevice、未跑游戏。
- 限制：只有 Android 真机（A2/A3 游戏路径 + 出包流程）才能验证实际装包与命中；包内不含 driver cache 与 S3 配方；替换整份缓存会丢掉上一包 runtime 学到的条目（可重建）；`S2A_SHADER_PROFILE_OUT` 出包要求与 APK 同一 SDK/工具链构建（manifest 钉程序集 id）。

### 2026-10-24 / ANDROID-A5-S2-003 / 装包端可上真机：资产包通道、内容身份与 logcat 诊断

- 关联：A5 / 着色器方案 S2；接 `ANDROID-A5-S2-002`。
- 状态：已实现，宿主验证；真机出包/装包验证进行中。
- 变更：离线包可随 per-game APK 以 `assets/game/shaders.zip` 分发（`ShaderPackArchive` 有界解压、拒绝绝对/父目录/盘符条目，缺资产不算错误、坏资产报红）；包的内容身份改为「已安装 revision 的 `index.tsv` 去掉 `shaders/` 行」，包随游戏包分发不改变它、游戏内容更新会改变它（`ShaderPackLayout.GameContentRoot`）；设备侧 native 增加 `s2a_android_copy_asset`。Android 会话日志增加 logcat 转发（只转 `[s2a]`/`[vkpb]`/`[vkpipe]`/`【红】` 行），无 run-as/root 也能取 S1/S2 证据。VKPB 程序记录载入计数进日志。
- 提交：`android/shader-cache`；Ryujinx 补丁 `0242-shader-vkpb-diag.patch`。
- 验证：宿主 codec 176/176（新增 8 项 archive/content-root 检查）；backing control 299 断言；Vulkan/GPU/Android AOT 构建通过；真实游戏（Diablo III 2.7.7.92380）已用本分支 APK 覆盖安装，待装包后验证。
- 限制：真机装包与跨进程命中尚未给出；包内仍不含 driver cache 与 S3 配方。

### 2026-10-24 / ANDROID-A5-S2-004 / Adreno 730 真机：S1 跨进程命中成立，装包链路打通，离线包产出待参考缓存

- 关联：A5 / 着色器方案 S1 + S2；接 `ANDROID-A5-S2-003`。
- 状态：真机验证（Redmi 22081212C，Adreno 730，Android 16，无线 adb）。S1 通过；S2 装包路径到"无包"分支为止，离线包产出未完成。
- 装机：Diablo III 2.7.7.92380（`01001B300B9BE000`）换成本分支 APK（versionCode 1，同一 debug 证书），A0 资源包 22.75 GB 经无线 adb 17.8 MB/s 推送，本地复制 52 s 进 import；安装 0 MiB 新增、21700.5 MiB 与旧版本共享，revision `sha256-bed062a9...`（656 文件，含 systemdata）。
- S1 证据：第 1 局 `[vkpipe] 驱动管线缓存未导入：MISS: no application pipeline cache` → `已保存 32 字节`；第 2 局 `[vkpipe] 导入驱动管线缓存 32 字节`（跨进程命中）。同一 profile 的 VKPB 身份稳定：`profileKey 602a5173...`、`translationKey 83b53767...`、closure `d9d416e2...:4a785c15...`（Adreno 730）。
- S2 证据：装包端按设备 profile 查 `<revision>/shaders/vulkan/generic/602a5173.../`，无包时按预期打印内容根 `sha256-bed062a9...` 并回落首遇现翻，没有返回成功兜底。
- 真机暴露的问题：① 单独重跑 `cs/build.sh` 会清空 `build/android-cs/jniLibs`，必须再跑 `openssl/build.sh` 才能出带 `libssl.so/libcrypto.so` 的 APK，否则 .NET 报 `No usable version of libssl was found` 后 SIGABRT；② 合并后的 HostConfiguration 时区校验要求游戏数据带 `systemdata/010000000000080E`，本仓库重打的 A0 包默认没有，补上后才过 Host.Boot；③ `shbake bake` 仅凭抽出目录产出离线包会报红 `pack has no shader cache for the title`（抽出只有阶段键、没有程序配对），必须先有参考缓存（真机或桌面 Ryujinx 跑一局）才能生成程序记录。
- 临时排查手段：游戏 APK 启动时把上一局私有会话日志的尾部转发到 logcat（`prev| ...`），无 run-as/root 也能取到原生 abort/异常原因；仅游戏 APK、debug 行为。

### 2026-10-24 / ANDROID-A5-S2-005 / 真机软键盘、整屏沉浸与着色器缓存导出

- 关联：A5 / 着色器方案 S1 + S2 真机联调；接 `ANDROID-A5-S2-004`。
- 状态：已实现并在 Adreno 730 真机验证（Diablo III 进入实际画面）。
- 变更：
  - Android host UI 接上软件键盘（svc 0x21 / swkbd）：guest 线程阻塞，主线程弹 AlertDialog + EditText，确认返回文本、取消返回 false；没有前台输入框时按取消并报红，不伪造输入。native 走 `s2a_android_text_input`（JavaVM + NativeBridge.requestText），Java 侧在 `MainActivity.requestText`。
  - 游戏 APK 整屏沉浸：主题 `windowFullscreen` + 刘海短边，运行时 `WindowInsetsController` 隐藏系统栏（划出后自动再隐藏）。
  - 着色器缓存导出工具：启动带 `--ez exportShaderCache true` 时，会话结束把私有 `games/<title>/cache/shader`（guest/shared + VKPB host 文件）整目录复制到外部私有目录，供 `shbake bake --ref` 配对后出离线包。无 run-as/root 设备靠它取真机缓存。
- 真机证据：Diablo III 标题、英雄创建与实战画面都能渲染；软件键盘不再触发 Break；导出缓存 1,127,269 字节（含 `shared.toc`、`guest.toc`、两个 VKPB host 文件）。

### 2026-10-24 / ANDROID-WONDER-215-002 / 旋转等待一致窗口与实际呈现采集

- 关联：#215、#199；接续内存 SVC、线程生命周期和上传读源修复批次。
- 状态：源码及主机合同通过；基于 `android/integration@8591773c` 的 r19b NativeAOT/APK、lint、16 KiB 对齐与签名通过，9000/8E 真机复验另报。
- 变更：合法但短暂不一致的窗口尺寸等待收敛后创建 chain，同 revision 有界重查，新 revision 立即重试。复用 #209 `3cf0a48e` 的显式开启呈现采集，绑定 session/PID、CLOCK_BOOTTIME 与 MARK；只记录成功游戏 present，保留异常未完成状态。关闭采集与在途节拍回调共享锁，防止负时长。
- 验证：实际 WSI 方法 13 场景 / 113 断言；写出器 24 项、实际呈现接缝 10 项、CLI 6 项及定向负控通过；独立审查发现的关闭竞争已以原生产源红、候选绿验证。原生读回失败测试 14 项通过，另 76+77+56 项通过；该处仅增加地址/页/generation/权限诊断，未放宽 guard。
- 限制：尚无本轮真机帧率或旋转恢复结论。采集是有诊断开销的成功 QueuePresent 返回节拍，不是 GPU 时间或显示扫描输出。既有读回 generation 协议仍在调查，不声明已修复，也未以取消保护或跳过绘制绕过。

### 2026-10-24 / ANDROID-WONDER-WSI-003 / Android窗口尺寸与已获取图像的正常退休

- 关联：#199；接续已合流#215/#233，基线`android/integration@d6634833`。
- 变更：Identity预旋转按实际Android窗口逻辑尺寸选择swapchain extent，保留insets与#233最终blit触点合同；SUBOPTIMAL使用相同判据。成功acquire后遇正常窗口撤销，真实等待acquire并仅提交退休所需工作，完成fence后清理，不伪造present完成，不吞掉真实device/submit错误。
- 证据：r19b9000实际操作60秒38.35次成功present/秒；旋转有72.617秒真实present断档，finish以125失败。此后修复的主机合同和源码审查见PR验证记录；新包真机复验单独报告。
- 限制：不包含既有读回generation协议修复，不声明8E读回失败已解决；9000当前性能目标为稳定30FPS，保持原画质。


### 2026-10-24 / ANDROID-A5-SHADER-001 / 对照 iOS、D2R 的着色器与双轨实施设计

- 关联：A5/A8；实施方案 §8.3；用户要求研究可实施方案并写入安卓文档。
- 状态：方案与源码核对完成；功能待实现。
- 变更：新增 `shader-plan.md`，明确 Vulkan 程序序列化缺口、profile 与 driver cache 分域、ShBake 显式能力入口、完整配方预热、后台任务与 device 生命周期；按 S0–S4 分段验收。对照 D2R 固定提交的 SPIR-V/绑定打包、driver cache、预热种子和历史实测，标出单款假设与不能直接移植的部分。
- 双轨：记录用户给定的 iOS 分层与 Android 的建议映射（通用 Ryujinx GPU→Vulkan / 直连 NVN→Vulkan），一次运行选择一套；共用抽取/事实、分离程序与管线域，离线本机补齐、准入与重启切换按 D0–D3 独立验证。
- 基线：S2Arm `9858d51b54316f17ab394f02690e5400e23c4165`；D2R Mobile `e3756f8942b40eba6c851e881828a5b1bda17fd6`。本条为文档变更，不代表代码或 A5/A8 已完成。
- 验证：源码及 Khronos 官方接口核对；实际文档检查与贡献者自检见交付说明。未构建 APK、未做新 GPU/真机实验；历史 D2R 数字不作为本项目性能结果。

### 2026-10-24 / ANDROID-A5-SHADER-002 / 补齐着色器方案审查缺口

- 关联：ANDROID-A5-SHADER-001；用户要求补齐方案 review 的三项问题。
- 变更：S1 起采用单编译 worker 与 owner 控制事件等待，明确 cache gate/快照不阻塞 Surface 回收；旧 warm 入口改为可取消、可等待的数据预读，后台创建统一调度；S3 用设备级成品池将管线交给实际 ShaderCollection，并定义引用计数和 Stop 顺序。
- 双轨：D0 增加真实控制段/代码/Cb1 身份映射、查询上下文与事实变体、歧义/冲突/缺事实处理；明确 D2 ready 的前置条件与直连运行时变体选择。
- 验收补充：2 秒慢创建/快照与 1 秒 detach ACK、退休证明缺失负例、跨程序实例成品命中及释放、相同代码不同控制段/绑定状态等负例；本条列的是待实现的验收要求。
- 状态：仅修改设计文档；文档检查及贡献者自检见本次交付，未改运行时代码、未新做 GPU/真机验证。

### 2026-10-25 / ANDROID-DIRECT-D2R-001 / D2R 直连经验审计与 native Vulkan 实施设计

- 关联：快速通用模式 v3 WP17；用户直接要求系统研究 d2r-mobile 并设计可实施的 Android 直连方案。
- 状态：设计与源码审计工具已实现；native direct 执行层未实现。ANDROID-A5-SHADER-001/002 的“先收集/发布 ready/重启切直连”已由 v3 流程取代，历史记录保留。
- 变更：新增 `direct-mode-d2r-study.md` 的 28 项采用清单及边界、`direct-mode-design.md` 的 NVN 共享前端/native Vulkan 执行、shader 离线与 draw-time 现场查询、资源跟踪/WSI、DV0–DV7 任务与验收；同步实施方案、v3 调整与 README。指出 Android 的 loader 重定位先于服务/GPU 创建，mode 必须提前冻结；D2R 固定事实表、对象布局、present 回收/信号链不能直接照搬。
- 工具：`android/tools/d2r_direct_audit.py` 编译真实两仓头文件并比较 enum/sizeof/offsetof，输出源码摘要；本机 LP64 抽查 30 项差异、10 个 S2Arm 独有枚举、2 个 D2R 独有枚举，明确禁止原记录强转。
- 基线：S2Arm `android/integration@979226fe`，D2R `e3756f8942b40eba6c851e881828a5b1bda17fd6`；独立分支 `android/direct-mode-d2r`。
- 验证：D2R 选定测试 4 次 C++ 编译 + 7 个测试进程，11/11 退出成功；NVN 真实头文件比较、同源重复与缺输入拒绝通过；文档本地链接/差异检查通过。Android CTest 14/15，`android_nativeaot_startup_roots` 仍为本机 GNU ld/BFD 2.47 assertion fail（-11），后续 Java/契约步骤未跑；贡献者检查见本分支交付。memo helper 通过不代表 D2R 实际 draw 已使用该 helper，设计明确要求接入路径验证。
- 限制：本轮不改游戏运行时，不启用 direct；没有新 Vulkan GPU/Android ARM64/游戏真机或 Apple 构建证据，不据此报告帧率/功耗。无游戏文件、shader 字节或存档入仓。

### 2026-10-25 / ANDROID-DIRECT-IME-002 / 系统输入法加入两轨共用基座及完整性复核

- 关联：ANDROID-DIRECT-D2R-001；用户要求确认方案完整性、补入 D2R 调起系统输入法的经验。
- 状态：设计补充；未修改输入/图形运行时代码。新增经验 E29，方案增列 DV-UI，modal IME 为 DV5 首款可玩的前置，inline 单独子任务。
- 变更：新增 `system-ime-plan.md`，明确 Ryujinx applet→HostApi broker→宿主 pthread/JNI→Activity/EditText/系统 IME 的两轨共用接线；补中文 composing span、UTF-8/UTF-16、session/request/Activity 身份、once 回复、HOME/销毁/停止取消及 UI 不等 GPU。当前 S2Arm 已有基础弹框；未把新请求链或 inline 标成已实现。
- 完整性复核：直连设计 §10 列出 8 项冻结前未闭环契约/探针；不再将范围覆盖称作全部实现规格已冻结。确定首版 native 呈现账本策略，并将“先取消 UI 再等 guest 退出”加入 Stop 顺序。
- 验证：固定 D2R 源码逐项核对；Java 17 目标编译与 `TextInputRulesTest` 12 用例、POSIX `lifecycle_dispatch_test` 编译执行通过；本地文档链接/格式及贡献者检查见本次交付。
- 限制：未新跑 Android 系统 IME、composing watcher、direct 游戏局或 inline 真机；参考主机测试不代替 S2Arm 实机。无玩家文本、游戏数据或存档入仓。

### 2026-10-25 / ANDROID-DIRECT-CLOSURE-003 / 合并 integration 后校正方案闭环状态

- 关联：ANDROID-DIRECT-D2R-001/IME-002；按用户要求复核方案是否闭环，基线为合并提交 `50725333`，包含本地 integration `cbacdf8b`。
- 变更：直连设计、系统 IME、状态和 runtime README 对齐实际源码。modal typed v1 broker/JNI byte[]/Activity/停止撤销已经接线，沿用 Java UI 主线程取请求，不再规划平行 `swkbd.dialog` 或额外 JNI worker；旧临时桥不作为正式 handler 路径。
- 剩余：实际 runtime session/Java 身份绑定、中文 composing、后台竞态/单虚拟核与 inline；direct 的启动 ABI、shader 查询、执行/WSI/内存、出包兜底和完整真机验收仍未闭环。设计 §10 明确交付顺序及退出条件，未启用 direct。
- 实际验证：生产键盘 codec/HostApi 测试 69 项断言通过；真实 native producer 编译运行通过，覆盖 UTF-8、容量、ownership、迟到回复、detach/Stop 唤醒和终态；文档链接/差异检查通过，贡献者自检见本次交付。
- 限制：本轮只修改 Android 文档，未重做设备测试；引用 integration 的 generic 确认/取消/停止为既有记录，不算 direct 或游戏完整通过。无游戏数据、玩家文本或存档入仓。

### 2026-10-25 / ANDROID-DIRECT-CONTRACT-004 / 对照iOS闭环首版直连方案

- 关联：ANDROID-DIRECT-D2R-001/IME-002/CLOSURE-003；用户要求先闭环方案，并以iOS实际实现补齐依据。
- 设计交付：新增 `direct-mode-contracts.md`，原八类待定项逐一确定：services v2 request80/table64/status24及所有权、relocation前事务、ELF/NVN适配、主仓静态accessor/driver表/literal C1/四set与SupportBuffer、统一离线/现场编译和完成先于写盘、HLE/视频、单跟踪器与backing事务、WSI与Stop、IME、typed出包与持久故障锁。
- iOS对照：核对当前gfxmode/Compose/SetShaders/Dsh/driver常量表/放核/宽屏接口；采用已证明的机制，不把Metal链接桩、单款facts、未知C0字段填0或Apple对象直接搬入Android。C1明确为shader literal段，非NVN uniform slot1；保留VertexA/B的真实翻译关系。
- 首版范围：NVN VS/FS/CS；单device/queue owner、单可见layer；实际启用EXT present fence及依赖的设备准入，缺项commit前generic。高级stage、inline、不受控长期虚拟alias和未知driver字段准确Unsupported；后续扩能力单独验证。
- 版本/更新：旧services start v1继续generic，status合同仍v1；graphics requiredFeature两端同批，shader及manifest进入最终index生成新revision，gameContentRoot独立；attempt放持久stateDir，SIGKILL/未正常结束下局generic，不随清cache丢锁。
- 验证：文档C接口抽出后以C11/C++17编译，LP64 request80/table64/status24及关键offset断言通过；本地Markdown路径/锚点与diff检查通过。贡献者doc自检见本次交付。
- 进度：**方案决策已闭环，实施/验收未完成**。C0–C8给出交付依赖与独立输出判据，C0–C7通过后才正式启用direct；本轮仅改Android文档，没有新增ARM64/GPU/设备/游戏或Apple构建证据，没有游戏资源/玩家文本/存档入仓。

## main 来源补充记录（75653d533）

以下条目原文来自 main；保留原日期、提交和验证边界，不代表本次合流重新验收。
`ANDROID-A1-004` 在两条分支中曾被用于不同事项：开发线为 2026-10-23 的 W2 内存/别名组，main 为 2026-10-27 的 plat/ESR 设备复核。两条均保留原 ID，以日期、标题与来源区分，引用时须同时给出事项。

### 2026-10-24 / ANDROID-ENV-107-004 / #176 合流后的 doctor 组合兼容

- 关联：#107 / #176，接 ANDROID-ENV-107-003；只修 doctor 与回归，不接管宿主构建器。
- 状态：已实现，待 integration 复核。
- 变更：从实际赋值解析旧 /cache 与 S2A_BUILD_CACHE 默认根、已知版本引用；gate 支持旧 case / 当前 JDK helper 并记录来源哈希。混合布局可解析，未知、重复、矛盾或越级路径明确失败；精确 SDK / NuGet 与载荷权限/架构检查保留。
- 提交：1398a5dc23c99036e3c075ebdb30da368cd80338。
- 验证：Server M4/macOS，65 项纯标准库回归通过；同新增 12 方法对旧实现 18 失败断言 / 0 异常。真实离线 CLI exit2 / incomplete、stderr 0 字节；AST、diff-check、shared_path 通过。
- 限制：只读源码/库存兼容，不代表 Linux NativeAOT 闭包、最终 ILCompiler、APK/签名/真机或游戏验收；未做真机。


### 2026-10-26 / ANDROID-A5-W9-017 / 可执行翻译规则来源与显式冻结候选

- 关联：#431；基线 `android/integration@f038d477`，目标仍为 `android/integration`。
- 问题：旧 profile 导出与首次缓存的程序身份分开计算，GPU options 另读全局语言输入；这构成不同来源接缝，未将其宣称为已观测到的线上漂移。
- 变更：缺省关的 `s2arm.diag_profile_freeze` → JNI host 创建前 setter → `S2A_W9_PROFILE_FREEZE` → renderer 配置；实际初始化（含 SSBO recorder）后、缓存消费前一次冻结。四项固定表达式同时用于规则产物和语言/compute flags/SSBO 窗口与记录选择；Raw/Enabled/Effective 分开。身份、导出、GPU accessor、metadata 资源布局、host 文件名与 ShBake provider 共用所选事实，旧代际显式拒绝；内存容量独立读取。
- 身份：显式 v2 profile，保留 v1 规范字节/算法、原 W9 hash/codec pin。新 `computeProfile.executionRulesHash` 仅定位本片普通 compute 规则产物，不冒充 W9 rulesHash 或正式 A0 rulesVersion；GPU/GAL/Shader/Vulkan 实现身份与规则语义分开。ShBake 核实际 GPU/GAL/Shader producer；未知规则即使重新计算规则/VKPB 身份仍拒绝。保留 #427 两个 SSBO 能力位及 optional-byte 语义。
- 兼容：默认 v1/Apple 入口保留，ShBake 精确单参入口保留；图形离线宿主预种继续，coverage 明标 `legacy-capability-only`，共用语言也冻结，不宣称完整图形/格式/VTG/TF 覆盖。
- 验证：macOS arm64/.NET 10 CPU host 299 检查通过；真实 ShBake/GPU 消费 14、renderer profile 提交/身份/导出 14、原生 JNI setter 6 项、静态初始化顺序 4 项通过；原 Apple CPU VTG 28/28，两个输出模块过 `spirv-val vulkan1.1`；Android36/JDK17 真实 Java/资源编译通过。仓外副本回退动态语言与可变 context 两种旧行为，分别在目标消费者断言失败。详见 `graphics/vulkan/cache/tests/run_profile_consumers.py`。
- 额外回归：既有 W5 设备请求/有效能力 CPU 测试 107 项通过。既有 `core/cache-tests` 构建在 Program.cs:102、464–465 共 5 处旧 API 错误，未得到该套件结果；测试文件和 `S2ALazyProgram.cs`（含 `S2AStageIndices` 定义）与基线 `f038d477` 逐字节相同，未扩大范围修写。基线构建未另跑，不把源码对照称作基线重编通过。
- 限制：未创建真实 VkDevice/执行 GPU，没有完整 Android APK/设备 A/B、同 session/PID 导出、Apple GPU/游戏及功耗性能结果；正式运行身份采集与更广映射不在本片，开关保持缺省关。

### 2026-10-23 / ANDROID-QA-001 / 一条命令的 QA 门禁与可追溯报告

- 关联：#57 / W10；门禁 `android/test.sh`、Docker APK 构建、`verify-apk.py`。
- 状态：已实现；Windows + WSL2 全链路已验证；真机矩阵未做。
- 变更：
  - 新增 `tests/qa.sh`：把 test.sh → APK 构建（assembleDebug + lintDebug）→ APK 静态校验
    （verify-apk + apksigner）串成一条命令，产出 `build/qa/report.{json,md}`，带 git SHA、
    镜像 ID、每步耗时、失败日志尾部；步骤间不中断，一次看全。
  - preflight 拒绝五类会让后续步骤以无关错误失败的环境：Windows 原生 shell（MSYS 改写容器路径、
    UNC 挂载为空目录）、CRLF 脚本、缺 git、Docker daemon 未起、缺镜像（只报出构建命令，不自动联网）。
  - 新增 `tests/qa_self_test.sh`：26 项 fixture，用 docker / git / uname 三个 shim 覆盖 skip 语义、
    报告字段、退出码与全部 preflight 拒绝路径；docker shim 按容器语义解析 `-w`，路径约定写错会红。
    已接进 `test.sh`。
  - 新增 `docs/reproduce-windows.md`：干净 Windows + WSL2 的复现步骤与 8 条已知坑。
- 提交：`97a51c04`、`911f11e0`、`988011ae`、本条目所在提交。
- 验证：Windows + WSL2 Ubuntu + Docker Desktop 29.9.1，镜像 `s2arm-android-build:1`
  （`sha256:d8180629a3fb…`）：test.sh 8s、APK 构建 23s（缓存命中）、静态校验 1s，全绿；
  APK 10,578,758 字节；`qa_self_test.sh` 26/26。未做真机。
- 限制：真机矩阵（安装/升级、资源包激活、设备身份、手柄输入）未做；报告未接 CI。

### 2026-10-24 / ANDROID-QA-002 / 门禁退出码对齐「跳过不是绿」（#126 review）

- 关联：ANDROID-QA-001；#126 review 意见；`tools/contrib_check.sh` 的 0/1/2 口径。
- 状态：已实现；容器内自测 36/36。
- 变更：
  - 退出码改为 0 = 全绿**且没有跳过**、1 = 有步骤失败、2 = 环境不满足**或有步骤被跳过**。
    原来 `--skip-apk` / `--skip-build` 会把缺跑的步骤记 `-skip` 后仍退 0、报告写「全绿」，
    违反 contrib_check 的 0 定义（全绿且没有缺跑）。
  - `report.json` 增 `complete` / `skipped[]` / `steps_ran` / `steps_total`；`report.md` 首段增
    「步数：跑了 N 步 / 应跑 M 步」，不完整时首行写「🟡 不完整：跳过 …」。
  - 末行固定打「门禁 <绿|红|不完整>：跑了 N 步 / 应跑 M 步」，对齐 `tools/gate.sh` 的射程口径。
  - 步骤名收敛到 `apk_build_name` / `apk_check_name` 两个变量：跑过、跳过、失败三种行同名，
    不再出现「APK 构建」与「APK 构建（assembleDebug + …）」两个名字。
  - `qa_self_test.sh` 由 26 项增到 36 项：新增「三步全跑 → 退 0 且 complete」用例，
    跳过类用例改为断言退 2 + `complete: false` + `skipped` 名单，并覆盖「失败优先于不完整」。
- 提交：本条目所在提交（#126）。
- 验证：容器内 `test.sh` 全过（10/10 CTest + Java/契约 + qa_self_test 36/36）。未做真机。

### 2026-10-24 / ANDROID-QA-003 / 真机矩阵首轮（Redmi K40 / alioth）

- 关联：ANDROID-QA-001 / 002；#57 的 W10 真机部分。
- 状态：部分完成——11 项通过，手柄输入与真实游戏未做。
- 变更：新增 `docs/device-matrix.md`，记录设备身份、用例矩阵、复现命令与未覆盖项；
  每条证据都指向 logcat 原文 / `current.json` / 目录结构。
- 验证（Redmi K40 / M2012K11AC / alioth，LineageOS 23.2，Android 16，SDK 36.1，
  build `BP4A.251205.006`，4 KB 页，Adreno 650）：
  - APK 安装启动、`libs2arm_android.so` 4 ms 加载、0 FATAL/ANR；
  - Vulkan 诊断呈现 1080×2400 FIFO 4 images，`interval avg 16.53 ms`、0 acquire timeouts；
  - 旋转 90°：surface 重建为 2400×1080、`transform 0x2`、7 次 build、无崩溃；
  - 合成包安装 / 升级（旧 revision 保留、`shared 0.1 MiB`）/ 重复导入幂等 / 缺文件拒绝
    （`refused: package has no romfs/missing.bin`，`current.json` 不变）；
  - 真机改写自测 `6 rewrite kinds x 2 guest threads ok`，key table 0，libc 34/36/38 未阻塞；
  - 平台探针：4 KB 页、共享内存别名可用、39-bit 64 GiB 窗口可用、NativeAOT ok 56 ms、HostApi v1 0x4f。
- 限制：手柄输入需实体手柄；16 KB 页设备未测；真实游戏的图形/音频/输入/存档属 W13。

### 2026-10-24 / ANDROID-QA-004 / 真机手柄矩阵（GameSir Nova 2 Lite）

- 关联：ANDROID-QA-003；W10 真机部分的输入项。
- 状态：已完成（合成输入，不含真实游戏内的按键功能验证）。
- 变更：`docs/device-matrix.md` 增手柄章节——设备身份、17 个按键 / 4 轴逐项实测值、
  以及「Xbox 布局手柄 A/B、X/Y 与标签互换」这一已知行为的说明。
- 验证（Redmi K40，LineageOS 23.2）：`am start --es s2arm.touchlog on` 打开输入日志，
  逐键实测——面键 `0x0002/0x0001/0x0004/0x0008`、肩键 `0x0040/0x0080`、
  扳机 `0x0100/0x0200`、START `0x0400`、十字 `0x2000/0x8000/0x1000/0x4000`、
  L3/R3 `0x0010/0x0020`、双摇杆 `L/R=(±32767)` 全部与 `dispatchKeyEvent` 的位表一致；
  `getevent` 抓到的 36 个按键事件里无非标准键码，背键在该模式下不上报。
- 限制：未观测到 `BTN_SELECT`（View 键未按下）；HOME 未映射、交系统；真实游戏内的按键功能属 W13。

### 2026-10-24 / ANDROID-W13-001 / 第一款真实游戏：链路打通，客体执行未接

- 关联：A6（第一款完整闭环）；W13。前置：ANDROID-QA-001..004（W10 门禁与真机矩阵）。
- 状态：**部分完成**——正版 dump 到 `ReadyToPlay` 全通，A6 未达成（客体执行未接）。
- 变更：新增 `docs/w13-first-game.md`，记录素材、Android 侧三步链路、真机日志原文、卡点定位到代码、复现命令与环境坑。
- 验证（Redmi K40 / alioth，Android 16，4 KB 页，Adreno 650；DARK SOULS™: REMASTERED 1.0.0，
  `01004AB00A260000`，本体 + v1.0.3 更新，玩家自备正版 dump 与 prod.keys，只在本地按路径使用）：
  - `nx_unpack --inspect` 判定 `guestIsa aarch64`；解包 romfs 18 文件 3915 MB；
  - `make_pack.py --root` 出 30 文件 4.2 GB 资源包，`contentRoot sha256-58b1a05a`；
  - 诊断应用：A0 安装事务通过（`stored 3820.9 MiB, shared 198.7 MiB`），`BootSpec ... mode diagnostic`；
  - 每游戏 APK（`org.s2arm.game.t01004ab00a260000`）：模块 `main,sdk,subsdk0` **从 APK 就地映射 3/3**
    （107008 KiB，`TARGET android`），`BootSpec ... mode game`，`ReadyToPlay ... from apk-asset`。
- 限制：**客体执行未接**。逐层核对（文档 §4.1）：APK 里只有 `libs2arm_android.so`（601 KB 宿主层）
  与 `libs2a_cs_probe.so`（1.2 MB 运行时探针），**没有 `libs2a_cs.so`**——`docker/build.sh` 默认
  `S2ARM_ANDROID_CS_SERVICES=0`，服务层（`S2A.Services` + Ryujinx HLE）根本没进包；原生核心侧
  `android/CMakeLists.txt:37` 只链 `native/s2a_native_stub.c`（59 行，除 `s2a_screen_w` /
  `s2a_boot_mark` 外全是 `unbacked()`），`../runtime/src` 只加 include 路径；启动入口
  `Exports.cs:26` 的 `S2A_Init` 在 Android 侧没有任何调用者。应用界面自述
  `Game execution is not connected yet`。该项取决于 A2 的真实原生核心与 A1/A3 接线（文档 §4.2 列了
  接上要做的四件事），不是换游戏或调包能解决的。
- 探针实测（§4.3，只在临时导出里改）：服务层 `libs2a_cs.so`（35.6 MB，S2A.Services + Ryujinx HLE + Vulkan）
  在 bionic arm64 上能加载并跑起来（运行时起 + 首次托管调用 15 ms，RSS +13 MiB），`S2A_Init` 走完正常返回，
  全程只撞到 `s2a_event_create` 一个桩。但这是"半初始化"——真实顺序是 `load_modules` → `s2a_mem_init` →
  `S2A_Init` → 起 guest 线程（`runtime/src/host_main.c:main()`），探针跳过了前两步。缺的是把 `main()` 抽成
  `s2a_host_run(root)` 并把 `runtime/src` 编成 arm64 目标，不是服务层本身。
- 编译审计（§4.6）：新增只读工具 `android/tools/core_syntax_audit.sh`
  （`--shim` / `--tsv` / `--strict`）。NDK 29 对 `runtime/src` 27 个 `.c`（4798 行）跑 `-fsyntax-only`：
  裸跑 OK 5 / 缺头 18 / 形状 4；加 6 行 `TargetConditionals.h` 垫片后 OK 8 / 缺头 15 / 形状 4。
  15 个缺头都有 Linux 对应；4 个是 API 形状不同（`mcontext_t` / `_STRUCT_ARM_THREAD_STATE64` /
  `F_SETNOSIGPIPE` / `PTHREAD_RECURSIVE_MUTEX_INITIALIZER`）。三个大头：`thread.c` 1168、
  `svc_mem.c` 459、`det.c` 414 行。`-fsyntax-only` 只证明头/类型能过，不证明能链接或能跑。
- 环境：Windows 上 `nx_unpack` 需把并行度降到 1（并发打开同一个 3 GB 文件会 `ACCESS_DENIED`）；
  `docker/build.sh` 的 `--user $(id -u)` 在 Git Bash 下是 `197609`，需 shim 成 1000 才能写 `/cache`。
### 2026-10-27 / ANDROID-TST-002 / 纠正 TST-001：门禁已编 App 的纯 Java 类

- 关联：ANDROID-TST-001；维护规则 3。
- 状态：回归/纠正。
- 变更：TST-001 写的「维护方在评估把 App 编译也接进门禁」不准确（维护方在 #44 指出）。实际情况：
  - 不依赖 Android SDK 的纯 Java 类（TouchPad / GameMetadata / GamepadState / Json / BootContract / BootSpec / GamePack / GameInstall）已随 005074cc 接进 `test.sh`，门禁会编；
  - 依赖 SDK 的类（GameLibrary / MainActivity / NativeBridge / BootSpecSource / TouchPadView）要带 SDK 的 Gradle，门禁还不编。#38 修的 GameLibrary 漏 import 属于这一类，门禁仍抓不到。
- 提交：本条。
- 验证：对照 main 上 `android/test.sh` 的 App 编译清单；只改文档，未构建、未真机。


### 2026-10-27 / ANDROID-TST-003 / main 上 APK 链接失败：单库缺两个链接桩

- 关联：ANDROID-AOT-003（服务层静态链进单库）；ANDROID-TST-002。
- 状态：回归/纠正。
- 变更：
  - 10-24 起 C# 层新绑了 `s2a_alt_phase`（Ryujinx 贴图 / 图像数组复用补丁）和 `s2a_gfx_mode`（S2A.Services Imports）。单库靠 `s2a_native_stub.c` 顶原生核心的符号，这两个没补，`libs2arm_android.so` 链接报 undefined symbol，main 上 APK 编不出来。门禁不编 APK，所以没看出来。
  - `s2a_native_stub.c` 补两个桩，都按「关」回：`s2a_alt_phase` 回 -1（没在交替，同 graphics/metal 的弱定义）；`s2a_gfx_mode` 回 `S2A_GFX_GENERIC`（main 上 Android 没有直连层）。
- 提交：本 PR。
- 验证：基于 `main@9dc44df5`，Docker 构建 APK 通过并校验（arm64-v8a、16 KB 段对齐）；真机见 ANDROID-A1-004。


### 2026-10-27 / ANDROID-A1-004 / plat.h 第一批与 ESR 探针真机复核（#52 / #53）

- 关联：A1；#37 / ANDROID-A1-003。
- 状态：已验证。
- 变更：无代码变更。用 main（`9dc44df5` + ANDROID-TST-003 的链接桩）编的诊断 APK 在真机上复核两个已合入的 PR：#52 合入时维护方注明安卓目标的汇编 / 链接不在门禁里、没验证；#53 改过的 ESR 探针，维护方合入时说真机核对留给有 Redmi 的时段。
- 提交：无（复核）。
- 验证：Redmi K50 Ultra（Android 15，Adreno 730），诊断 APK 启动一次：
  - 改写自检 `6 rewrite kinds x 2 guest threads ok, key offsets via plat_tsd_offset`：`plat_tsd_init` / `plat_tsd_offset` / `plat_fault_altstack_init` / `plat_fault_altstack_free` 在真机走通；
  - ESR：`write ESR 0x92000047 (EC 0x24, WnR 1), read ESR 0x92000007 (EC 0x24, WnR 0)`，读写可分。探针之后 App 照常往下跑（HostApi、Vulkan 呈现 487 帧），没有崩溃；
  - 和 A1-003 一致：17 个信号有处理函数，10 USR1 / 12 USR2 / 23 URG 仍没人占，ESR 读回的值也相同；
  - 其余自检（C# 单库、AAudio、Opus / VP8、HostApi 0x4f）全过。
- 限制：探针期间别处来的缺页（#53 的转交路径）真机上没有触发，只有维护方在 arm64 Linux 容器里验过。

### 2026-10-29 / ANDROID-TST-004 / 改共用 C# 也核对单库链接符号（#530 第一层）

- 关联：#530；ANDROID-TST-003；`core-link/link_symbols.py`（Q19，#907 启用）。
- 状态：门禁补漏。
- 变更：
  - 安卓门禁只由 `android/` 等路径触发。改 `services/`、`compat/tree/src/` 的共用 C# 时它不跑：TST-003 的两个缺口、10-28 `76d5c31de` 的 6 个缺口都是这样漏的。新钩子 `android/core-link/gate.sh` 由这两处和 `graphics/metal/cs/`（`NxTrack.cs` 带 `s2a_native` 导入、编进单库）触发，只跑 `link_symbols.py --no-link`（源码级，诊断 + 游戏两种目标）。`t_link_symbols.py` 新增用例：安卓编译闭包里每个 C# 输入改了都要跑到安卓钩子，闭包以后多出新目录也会报出来。
  - `link_symbols.py` 按维护方在 #530 定的方案 (a)，不再按平台排除 C#。苹果音频后端随共用 C# 编进单库，它导入的 `s2a_dump_threads` / `s2a_hud_audio` 由新增的 `runtime/apple_audio_stub.c` 以关闭态定义，两种目标都编入（`LinkSources.cmake`）。按「未实现一律报红」，`s2a_dump_threads` 首次被调用时打一行【红】（安卓没有宿主线程栈导出，未打栈），之后静默回 0。
  - 去掉平台排除后，只对含导入 / 导出属性的文件剥注释：`--no-link` 从 17 秒降到约 3 秒。
- 提交：本 PR。
- 验证：Linux 容器（WSL x86_64，无 Mac）：
  - `link_symbols.py --no-link` 两种目标缺失 0、重复 0（17.1 → 2.6 秒）；新钩子 3.2 秒。
  - 在 `services/` 加一个没有定义的 `DllImport`，或删一个苹果音频桩：钩子都红，并点名符号与 C# 位置。
  - `t_link_symbols.py` 25 项、`tests/gate_route_test.sh` 等路由 / 接线单测全过。
  - Docker 单库 APK：诊断、游戏两种目标都编进 `apple_audio_stub.c`，链接通过，`verify-apk.py` 通过。

### 2026-10-30 / ANDROID-TST-005 / 改共用原生源也跑单库链接核对（#530 后续，定义侧）

- 关联：#530；ANDROID-TST-004（#941 复审记下的后续项）。
- 状态：门禁补漏。
- 变更：
  - `core-link/LinkSources.cmake` 两种目标的源清单里，有 27 个文件不在 `android/` 下：`runtime/src/` 25 个，`graphics/nvn/gfx/nvn/nvn_tex.c`、`graphics/nvn/gfx/tex/nvn_deswizzle.c` 各 1 个。改它们原先不触发任何安卓钩子，比如把 C# 绑定的 `s2a_alt_phase` 从 `runtime/src/alt.c` 改名，门禁看不出来。
  - `tools/gate_route.tsv` 中 `core-link/gate.sh` 那一行补 `runtime/src/` 和这两个文件，只增不减。
  - `t_link_symbols.py` 新增用例：两种目标原生源清单里的每个文件改了都要跑到安卓钩子；C# 侧与原生侧共用同一判定。`tests/gate_route_test.sh` 补 `runtime/src/alt.c` 的断言。
- 提交：本 PR。
- 验证：Linux 容器（无 Mac）：
  - `t_link_symbols.py` 27 项全过：两个路由用例当前树 0 漏；负控去掉 `runtime/src/` 后点名 `alt.c`。
  - `tests/gate_route_test.sh` 全过，含列车线要求的负对照：临时克隆去掉登记后，改 `runtime/src/alt.c` 不再选中 core-link 钩子。`test_wired_lint` 没接线 0。
- 限制：只补「C# 绑定的原生定义被删或改名」这一类。改 `runtime/src/` 时，共用原生代码在安卓上编不过、原生函数新调用安卓单库里没有的符号，这两类仍然漏：要真实 NDK 编译 / 链接才看得出来（安卓门禁的 `test_game_core_closure.py` 与链接探针、apk 子项），而改 `runtime/src/` 不触发安卓门禁。

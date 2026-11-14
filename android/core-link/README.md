# Android 原生核心链接审计（A-W3-0）

> 合流说明（2026-10-28）：本页合并双方已有说明与原验证记录；相关源码冲突尚待解决，原记录不代表本次候选重新通过。进度见 合并分析 §13。

当前 Android `s2arm_android` 是诊断宿主。`S2A_CS_SERVICES=static` 把 NativeAOT
服务组成链接进同一库；基础服务导入仍由 `native/s2a_native_stub.c` 接住，
纹理数组复用诊断所需的 `s2a_alt_phase` 则来自共享 `runtime/src/alt.c` 的真实实现。
模块映射检查、C# 运行时自测、存在 `S2A_Init` 导出均不表示 `S2A_Init` 执行成功，
更不表示可以执行 guest。

## 门禁：C# 绑定入口 vs 单库链接定义（Q19/#530）

`android/gate.sh` 先跑 `core-link/link_symbols.py`（也可单独执行，只用
Python 标准库）：

```sh
python3 android/core-link/link_symbols.py [--mode diagnostic|game|all] \
  [--report build/android-link-symbols.json]
```

- C# 输入按 `android/cs/aot/S2A.Android.Aot.csproj` 的 MSBuild 项与
  `ProjectReference` 闭包实际收集（含 `Compile Include/Remove`、glob、条件；
  `ReferenceOutputAssembly=false` / `OutputItemType=Analyzer` 的生成器工程不参与运行
  产物），不维护手写文件名单。`DllImport` / `LibraryImport` 的库名支持字面量和本文
  件 `const string`，符号名支持 `EntryPoint` 重命名。
- 原生定义按 `core-link/LinkSources.cmake` 的实际源清单收集；该文件同时被
  `android/CMakeLists.txt` 使用，诊断/游戏 provider、静态桩与
  `S2A_ANDROID_EXPERIMENTAL_TOUCH` 条件不会和构建漂移。C/C++ 定义扫描会按 Android
  预定义宏处理 `#if`/`#ifdef`，并展开仓库内 `.inc`（如 `boot_android.inc`）。
- 缺一个入口就逐条打【红】点名符号和 C# 引用处（文件:行），退出非零；同一符号多个
  强定义也报红。`s2a_opus` / `s2a_vpx` 的第三方 `opus_*` / `vpx_*` 入口来自
  `codecs/build.sh` 抓取的归档，静态检查只核对本仓库 shim 的 `s2a_*` 包装。
  `NativeLibrary.GetExport/TryGetExport` 是运行时查找，不是静态链接判据，报告里只计数。
- 有 NDK 29 + CMake 时，再生成一个只含引用（和 C# 导出占位）的探针 C 文件，把
  生产原生源清单链成 `libs2arm_android.so`，用 `ld.lld -z defs` 的 undefined symbol
  作为最终判据；无 NDK 时明确打印“仅符号核对：未找到 Android NDK…”，不冒充已经
  链过或出过 APK。对于 `s2arm_android` 的 libavc 入口，探针同时链接
  `codecs/build.sh --avc-only` 从固定离线源码生成的真实归档；可设
  `S2A_Q19_AVC_ARCHIVE` 指定已有归档，否则按 `S2A_BUILD_CACHE` / `S2A_AVC_ARCHIVE`
  寻找本地固定源码并离线构建；缓存默认为 `$HOME/.cache/s2arm-build`，显式
  `S2A_BUILD_CACHE` 优先，缺 HOME 且无覆盖时报红。缺少源码或归档时明确报红，不下载、不造桩。
  其他第三方 codec 入口仍由正式归档链接审计覆盖；探针不等于完整 APK/真机。

编进单库的 C# 导入一律算链接需求，不按平台排除（#530 维护方定的方案 (a)）：规则只有一条、
不猜可达性，排除名单会悄悄变长、检查就会绿着失效。Android 不再链接 Apple 音频后端及其诊断桩。

回归：`python3 android/core-link/tests/t_link_symbols.py`（fixture 覆盖
#530 两个旧事故、删桩必红、共用 C# 新绑假函数必红、EntryPoint/LibraryImport、
条件编译、平台专用 C# 照样算需求、重复强定义、工程引用闭包，以及当前树两模式正例）。

## 构建和报告

现有构建默认保持 `S2A_ANDROID_NATIVE_MODE=diagnostic`。显式选择 `game` 时，
CMake 在编译前拒绝并说明真实 provider 尚未接入。此开关描述原生实现角色，
与 APK 包名、是否内置某个游戏的模块、BootSpec 请求的 mode 相互独立。
本改动没有新增可运行的 game target。

Static NativeAOT 构建在最终库链接后自动执行 `audit.py`，生成构建目录中的
`core-link-<配置>.json`：

- 从实际 `libs2a_cs.a` 的未定义 `s2a_*` 符号导出需求，扣除 archive 自己定义的符号；
  不维护一份手写静态导入表。范围包括当前 audio/codec 的 `s2a_*` 导入。
- 检查最终 ELF64/AArch64 `.so` 的符号表是否有本库定义，且没有同名未解决引用。
  `--exclude-libs` 隐藏的内部定义可满足静态调用，但不被当成动态导出。
  二进制符号名逐字比较，不把 ELF 的 `_s2a_*` 改成 `s2a_*`；Mach-O host fixture
  也保留实际 C ABI 下划线，仅源码运行时查找清单按已识别的 Mach-O 格式映射名称。
- 同库服务出口的弱引用（#961）：从 CMake 实际 target 源码里找只声明、带 `weak` 的托管服务
  出口（`S2A_` 驼峰名，例如 `direct_prompt.c` 的 `S2A_SaveAtomicState`、`hle_nvn.c` 的
  `S2A_NvMapFromGuest`），要求 NativeAOT 归档里有全局代码定义（nm `T`），且最终未剥离库的
  符号表里有代码定义（`T` / `t`）。弱引用缺定义照样链接成功、运行时是 NULL，归档从没提供
  这条导出时「归档定义 ∩ 库内未解析」为空，所以单列。弱定义、数据 / 绝对符号、库里仍是
  `w`、库被剥离都报红；报告在 `weak_service_exports`。目标里没有这类弱引用时不要求。
- 从实际 `link.txt` 中的 runtime 对象/库提取 `__start_*` / `__stop_*` 需求，
  检查最终定义、对应可装载节及非空 `__modules`，并核对根地址等于该节的起止地址。
  根必须属于该节，或是边界值准确的 linker-script ABS 定义；仅名字相同不能满足。
  记录每个链接输入的 SHA-256。
  这用于暴露 NativeAOT 启动表被 section GC 丢弃的问题，不等于运行时已启动。
- 另列 `services/S2A.Services` 中字面量 `GetExport/TryGetExport` 的位置及 ELF
  dynsym 是否可见；非字面量调用列为 unchecked。它不是 C# 可达性分析，不能替代
  Android `GetMainProgramHandle` 查找范围、组合 feature 语义和真实调用验收。
- 记录 archive、最终库、CMake 实际 target source 列表及所选源码、consumer 源码的
  SHA-256。源码列表证明构建选择，符号表证明定义存在；二者不证明每个函数的运行语义。
- 报告始终包含 `scope=diagnostic-link-only` 和 `game_ready=false`。
  缺少必需静态定义、工具失败、输入错误均失败；不会留下上一份 PASS 报告。

动态符号缺失会记录，不阻断已有诊断构建。例如 `s2a_guest_tick` 的真实实现未链接时，
不能据此接受游戏时钟正确；正式 game provider 必须另行关闭此缺口。Diagnostic 的
`screen_w` / `boot_mark` 自测也不能替代 handles/events/shared-memory 的真实 provider。

独立执行入口（产物必须来自同一次构建）：

```sh
python3 android/core-link/audit.py \
  --archive build/android-cs/static/libs2a_cs.a \
  --library <CMake构建目录>/libs2arm_android.so \
  --source-list <CMake构建目录>/core-link-Release.sources \
  --source-root android \
  --consumer-root services/S2A.Services \
  --nm <NDK>/toolchains/llvm/prebuilt/<host>/bin/llvm-nm \
  --readelf <NDK>/toolchains/llvm/prebuilt/<host>/bin/llvm-readelf \
  --link-input-list build/android-cs/static/link.txt \
  --android-elf --report build/android-core-link.json
```

## 验证和后续依赖

```sh
python3 android/core-link/test_audit.py
python3 android/core-link/alt-tests/run.py --out <隔离输出目录>
```

测试实际编译 host archive/library，经真实 `nm` 和 CLI 验证：新增导入自动进入需求、
缺 provider 失败、archive 内定义扣除、诊断源码身份、无效输入清除旧报告，以及
CMake 拒绝 game / 未知模式。Linux CTest 另运行 `test_startup_roots.py`，记录自然 section GC
的实际结果，并用显式丢弃 `__modules` 的真实 ELF 稳定验证缺节/未解决 roots 红例；GNU ld
可能保留首个输入节，不能把 `-z start-stop-gc` 当成整节必然消失。可以显式传入
编译器/链接器/nm/readelf，在 Mac 上
用支持 ELF 的 LLVM 交叉工具复跑。此 fixture 没有执行 Android NativeAOT。Host fixture 只验证审计机制，不能冒充 Android 链接或游戏。
Android APK 构建仍须由正式构建环境执行；真机执行另验。

符号/边界回归也使用真实 ELF：保留非空 `__modules`，分别给出零、反向和少 1 字节的根，
以及只含错误 `_s2a_handle_new` 拼写的库；CLI 必须因对应缺口拒绝。正确 linker 生成根和
准确 ABS 根均保留正控。独立 CLI 的输入仍须来自同一次构建；源码 SHA 只证明所选输入，
不证明函数实现语义或任意外部输入之间的构建关联；节边界正确且非空也不证明所有
预期模块条目完整保留。

后续 W3 应复用既有 `runtime/src` provider，经 W1/W2 平台能力、实际 core 初始化结果、
W5/W6 renderer 和 HostApi 生命周期闭合后再新增 game target；不能用第二套 kernel、
空成功函数或 Apple 替身头绕过缺口。W1/W2 某一个 PR 合并只触发重新审计，不自动
代表整个核心可运行。

## 同局交替诊断 provider

共享 GAL 的 `S2ATexArrReuse.On` 在设了 `S2A_ALT` 时查询原生相位；NativeAOT
对整个 `s2a_native` 使用 DirectPInvoke，所以未设置该环境变量也必须能静态解析
`s2a_alt_phase`。运行时捕获缺库异常不能解决静态链接缺符号。

Android 诊断目标直接编译原 `runtime/src/alt.c` 和时钟 owner `runtime/src/os.c`；
游戏目标继续由 `Runtime.cmake` 提供同一实现，与 Apple
共用 `now_ns()` → `plat_now_ns()`。起点、查询和 period 统一用纳秒，平台时间单位
转换只由既有 `plat_now_ns()` 实现。
没有复制返回常量的 provider，也没有改变默认纹理数组池复用行为。相位查询只读
原子状态和单调时钟；`s2a_alt_mark()` 的环境变量读取和日志不在信号处理中调用。

诊断目标没有 MARK → `s2a_alt_mark()` 的游戏生产调用链。未 MARK 的 `-1` 仅表示
真实状态机尚未启动；不能据此宣称 Android 同局 A/B 或游戏已运行。实际游戏目标及
其生命周期已经独立接入，这里的诊断验收不替代游戏验收。设置 `S2A_ALT`
且未强制 `S2A_TEXARR_REUSE=0/1` 时，现有 GAL 策略在 MARK 前关闭复用，语义不变。

`alt-tests/run.py` 编译生产 alt.c/os.c，只由 host fixture 提供平台时钟输入，验证未 MARK、
0/1 段边界、重复 MARK、未启用及信号中的查询；删掉 owner 的真实链接必须失败。
Mac 另链真实 Apple 平台时钟，并跑已有 MARK consumer。它不使用 Apple 替身头，不证明
Bionic/Android 运行。`test_audit.py` 用真实 alt.c、实际 archive/library 核实新增导入；
只有源码清单声称包含 owner 而库没有定义仍失败。最终 APK 必须另核完整静态链接、
符号来源和真实设备加载。

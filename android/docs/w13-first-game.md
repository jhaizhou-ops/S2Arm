# W13 第一款完整可玩：链路打通与卡点定位

记录第一次用**真实游戏**跑 Android 链路的全过程。结论先给：**从正版 dump 到 `ReadyToPlay` 全通，
但"执行客体"这一步还没接**——应用自己在界面上写着 `Game execution is not connected yet`。

## 1. 素材与设备

| 项 | 值 |
|---|---|
| 游戏 | DARK SOULS™: REMASTERED，`01004AB00A260000`，本体 1.0.0 + 更新 v1.0.3 |
| 来源 | 玩家自备正版 dump + `prod.keys`，**只在本地按路径交给 `nx_unpack`**，不进仓库、不打印 |
| 设备 | Redmi K40（alioth），Android 16，4 KB 页，Adreno 650 |

`nx_unpack --inspect` 判定的客体 ISA 是 `aarch64`，符合 S2Arm 只跑 64 位的要求。

## 2. 链路（Android，不需要 iOS 段）

`pack/oneclick/oneclick.sh` 的第 ④ 步是 `ipa.sh`（要 macOS），Android 用不到。实际只三步：

```sh
# 1) 解包（base + update 合并）
nx_unpack <prod.keys> <extract> --aoc-index --title-id=01004AB00A260000 <base.nsp> <update.nsp>

# 2) 转 Android 包（资源包 v2 + S2A_TARGET=android 改写模块）
python3 android/tools/make_pack.py <pack> --root <extract>

# 3a) 诊断应用：推到 import/ 走 A0 安装事务
# 3b) 每游戏 APK：game_apk.py → docker build → game_apk.py --resources
```

依据：`make_pack.py:entries_from_root` 只要求 root 里有 `exefs/main.npdm`、`romfs/`、`ctl/control.nacp`，
改写由它自己调 `runtime/rewriter/patch_nso.py` 完成，所以 `refresh.sh` / `seed_root.sh` / `ipa.sh` 都不必跑。

## 3. 实测结果

### 3.1 诊断应用（A0 安装事务）

```
Game installed: DARK SOULS™: REMASTERED 1.0.0 [01004AB00A260000] -> sha256-58b1a05a0995;
                stored 3820.9 MiB, shared 198.7 MiB with installed versions from import/darksouls
modules .../main.patched.bin map R|X (TARGET android, 80 KiB)
BootSpec 01004AB00A260000: language en-US, region US, time zone Asia/Shanghai,
                          screen 2400x1080 440 dpi 60 Hz, mode diagnostic
```

### 3.2 每游戏 APK（计划 §2.3 的交付形态）

```
Game in this APK: 01004AB00A260000 (org.s2arm.game.t01004ab00a260000)
modules main,sdk,subsdk0 map R|X (TARGET android, 107008 KiB); images read in place from the APK: 3/3
BootSpec 01004AB00A260000: ... screen 2400x1080 440 dpi 60 Hz, mode game
Game installed: ... -> sha256-9d96dbf34cde; stored 3716.4 MiB, shared 198.7 MiB
DARK SOULS™: REMASTERED: 20 files, 3915.1 MiB; ReadyToPlay ... 3 module(s) from apk-asset,
                android-sp-safe-v1, vulkan
```

APK 只装模块（107 MB），资源包 3.9 GB 单独导入——与计划的"一个运行时一款游戏一个 APK，资源包另发"一致。
`mode game` 与 `mode diagnostic` 是 BootSpec 的两种模式，前者来自每游戏 APK。

## 4. 卡点：客体执行未接

界面原文（`S2Arm Android preview` 的副标题）：

> **Android host bring-up. Game execution is not connected yet.**

代码侧对应：

- `NativeBridge` 暴露的原生入口只有 `create / describe / registerHost / offerSurface / updateSurface /
  releaseSurface / setForeground / input / checkModules / checkModulePaths / checkAssetModules / destroy`
  ——**没有 boot / run / execute 之类的入口**。
- 原生层是 `android/native/s2a_native_stub.c`，只有 `s2a_screen_w` 与 `s2a_boot_mark` 有实现。
- `AndroidManifest.xml` 只有一个 `MainActivity`，没有游戏 Activity。

也就是说：安装、校验、模块 R\|X 映射、BootSpec、Vulkan surface、虚拟手柄 UI 都已就绪，
**缺的是把客体 `main` 跑起来的执行核心**（A2 的"真实原生核心替换 stub"）与 A1/A3 的运行时接线。

### 4.1 逐层证据（为什么点开只有一行状态文字）

| 层 | 检查 | 结果 |
|---|---|---|
| 桌面入口 | `cmd package query-activities -a MAIN -c LAUNCHER` | ✅ `org.s2arm.game.t01004ab00a260000/org.s2arm.android.MainActivity`，标签 `DARK SOULS™: REMASTERED`（`res/values/game_name.xml`） |
| Activity | `MainActivity.onCreate` | 只做 `create → describe → registerHost → checkAssetModules → 写状态文字`，之后没有任何启动调用 |
| JNI | `bridge.cpp` 的 16 个 `Java_..._NativeBridge_*` | 无 boot / run / start |
| APK 内容 | `unzip -l app-debug.apk` | 只有 `libs2arm_android.so`（601 KB，宿主层）、`libs2a_cs_probe.so`（1.2 MB，运行时探针）、`libcrypto/libssl`、`assets/game/modules`（90.5 MB）——**没有 `libs2a_cs.so`** |
| 构建默认 | `android/docker/build.sh:18` | `S2ARM_ANDROID_CS_SERVICES=${S2ARM_ANDROID_CS_SERVICES:-0}`，默认只出 probe；服务层（`S2A.Services` + Ryujinx HLE）要用 `1` 或 `static` 才编 |
| 原生核心 | `android/CMakeLists.txt:37` | `S2A_CS_SERVICES=static` 时链 `native/s2a_native_stub.c`，注释写明 "until the native core runs here"；`../runtime/src` 只加 include 路径，**一个 `.c` 都没编** |
| stub | `s2a_native_stub.c`（59 行） | 除 `s2a_screen_w` / `s2a_boot_mark` 外全部 `unbacked()`，首次调用打 `link stub, the native core does not run on Android yet` |
| 启动入口 | `services/S2A.Services/Exports.cs:26` | `[UnmanagedCallersOnly(EntryPoint = "S2A_Init")]` → `Host.Boot(renderer, audio, baseDir)`；**Android 侧没有任何代码调用它** |

真机日志印证：`ReadyToPlay` 之后 S2Arm 再没有新行，**连 stub 的 `unbacked` 警告都没出现**——
不是"核心跑了但失败"，而是**根本没有发出启动请求**。

安装后的目录正好是 `S2A_Init` 要的形状（真机实测）：

```
files/games/01004AB00A260000/revisions/sha256-9d96dbf3.../
  ctl/  exefs/  romfs/  index.tsv  manifest.json  game-build-artifact.json
```

### 4.2 接上要做的四件事（按依赖顺序）

1. **把真实核心编进 Android 库**：`android/CMakeLists.txt` 目前只
   `target_include_directories(... ../../runtime/include)`；需要把 `../runtime/src/*.c`
   （`boot.c` / `host_main.c` / `thread.c` / `mem.c` …）纳入 `s2arm_android`，并去掉 `s2a_native_stub.c`。
   `host_main.c` 是独立 `main()`，要把它抽成可调用的 `s2a_host_run(const char *root)`（§4.3 已实测验证顺序）。
2. **把服务层打进 APK**：`S2ARM_ANDROID_CS_SERVICES=static`（与宿主同库）或 `1`（独立 `libs2a_cs.so`）；
   当前默认 `0` 只有运行时探针，Ryujinx HLE 根本没进包。
3. **加一个 JNI 启动入口**：`NativeBridge.boot()` → `S2A_Init()`。`S2A_Init` 在
   `Exports.RendererFactory == null` 时退到 `StubRenderer` 并报红（不出图），
   所以还要登记一个接到 `presenter.cpp` / `wsi_lease.c` 的 Vulkan `IRenderer`。
4. **给游戏数据目录**：`S2A_Init` 读环境变量 `S2A_GAME_DATA`（解包布局：`exefs/main.npdm`、`romfs/`、
   `ctl/control.nacp`），没给就报红 "fs / am 拿不到游戏的 RomFS 与 NACP"。用上面那条 revision 路径，
   在 JNI 里 `setenv` 后再调；`S2A_RYU_DATA` 指到 `files/ryujinx` 一类可写目录。

这四件都在 A2 / A1 / A3 的范围内，不在 W13。

### 4.3 探针实测：服务层能在 Android 上跑起来，缺的是客体执行

光看代码只能推断，所以做了一次探针构建（**只在临时导出里改，没进仓库**）：
把 stub 单独编成 `libs2a_native.so`、加一个 `NativeBridge.boot()` 调 `S2A_Init`、
用 `S2ARM_ANDROID_CS_SERVICES=1` 把服务层打进 APK，再用 `--ez s2arm.boot true` 触发。

结果（Redmi K40 真机日志原文）：

```
C# services NativeAOT (S2A.Services + Ryujinx HLE + Vulkan): loaded in 0 ms,
        runtime started + first call in 15 ms, RSS +13 MiB
W S2Arm: s2a_event_create: link stub, the native core does not run on Android yet
I S2Arm: boot: S2A_Init returned (game data .../revisions/sha256-9d96dbf3...)
```

**这证明了三件事：**

1. 服务层（`S2A.Services` + Ryujinx HLE + Vulkan，35.6 MB）在 bionic arm64 上**能加载、能跑**，
   运行时起 + 首次托管调用 15 ms，没有缺符号、没有 ABI 问题、没有崩溃。
2. `Native.UseLinked()` 能绑到 stub 上，整条 `S2A_Init` 走完并**正常返回**。
3. 全程只撞到一个桩：`s2a_event_create`。

**但它是个"半初始化"，不能当成功看。** 真实起局顺序在 `runtime/src/host_main.c:main()`：

```c
load_modules(dir, names, n);          // 装载 / 重定位 / 门表
s2a_widen_start();
g_main_stack_top = s2a_mem_init(npdm);   // 客体内存布局
if (S2A_Init) S2A_Init();                // ← C# 服务层在这里才起
...
pthread_create(&th, &at, guest_main, NULL);   // 游戏主线程
pthread_join(th, NULL);
```

探针是**跳过前两步直接调 `S2A_Init`**，所以 HLE 起来时客体内存是空的、模块也没装载——
`S2A_Init` 返回只说明"服务层自身能起"，不代表游戏能跑。这一点对 A2 是关键：
**顺序不能反，`S2A_Init` 必须在 `load_modules` + `s2a_mem_init` 之后调。**

**真正缺的那一块**：`runtime/src/host_main.c` 是个**独立 `main()`**（吃 `argc/argv`、末尾
`s2a_front_run` 占主线程、`pthread_create(guest_main)` 再 join），而 `runtime/src/*`（29 个文件：
装载器、内存、门表、线程、信号…）**一个都没编进 Android 库**。

Android 需要的不是 `main()`，是一个可调用入口，等价于 `main()` 去掉 argv 解析后的那段：

```c
void s2a_host_run(const char *root);   // load_modules → widen → mem_init → S2A_Init → 起 guest 线程
```

这就是 A2 在 Android 上的最小切口：把 `runtime/src` 编成 arm64 目标、把 `main()` 的身子抽成
`s2a_host_run()`，再由 JNI 调一次。

**探针构建需要的三处改动**（给做 A2 的人省时间，都在临时导出里验证过）：

| 改动 | 位置 | 原因 |
|---|---|---|
| `targets 's2arm_android', 's2a_native'` | `app/build.gradle` | Gradle 只编声明过的 target，不加不会产出 `libs2a_native.so` |
| `add_library(s2a_native SHARED native/s2a_native_stub.c)` + `target_link_libraries(... log)` | `android/CMakeLists.txt` | 让 `DllImport("s2a_native")` 能解析；stub 用了 `__android_log_print`，要链 `log` |
| `libs2a_native.so` 加进白名单 | `verify-apk.py` | 否则 `APK verification failed` |

另外 `dlopen` 顺序有讲究：先 `libs2a_native.so`（`RTLD_GLOBAL`）再 `libs2a_cs.so`，
否则服务库的未定义 `s2a_*` 会让 `dlopen` 直接失败。

### 4.4 安卓侧同类案例：打包成功过很多次，跑起游戏的一次都没有

查了仓库全部 192 个 issue / PR，安卓「打包」这条链上的成功案例是有的，而且都过了真机：

| PR | 做到了什么 | 状态 |
|---|---|---|
| #5 | 外壳 + 改写器 `S2A_TARGET=android`（苹果产物逐字节不变） | 已合 |
| #10 | 单库构建：服务层 NativeAOT 静态链进宿主 `.so`，真机 C#→C 直调 | 已合 |
| #11 | AAudio 音频后端（真机 19200/19200 帧、0 xrun） | 已合 |
| #17 | 资源包 v2 + 改写模块 → 游戏包，导入成功 / 坏包被拒 | 已合 |
| #24 | 每游戏 APK 第一步：模块随 APK 走、按 title ID 生成应用身份 | 已合 |
| #27 | 安装事务 A0（v1→v2→v3 拒绝、旧版本保留） | 已合 |
| #29 | apk-asset 模块 `map_mem` → `ReadyToPlay`（真机 1/1 映射） | 已合 |
| #33 | 每游戏 App 横屏（`sensorLandscape`） | 已合 |
| #86 | 诊断核心链接审计 + 托管接口绑到实际 provider（static APK 装机 8 Elite / 天玑 9000） | 已合 |

用的方法就是本 PR §2 那条链，没有第二种：

```
make_pack.py --root  →  game_apk.py  →  docker/build.sh  →  adb install + push import/
（资源包 v2 + 改写模块）  （每游戏 APK，模块进 assets）  （S2ARM_ANDROID_CS_SERVICES=0|1|static）
```

**但没有一个案例跑起过游戏。** 这是仓库自己写的，不是我的判断：

- #57：真机证据覆盖「诊断 APK、窗口租约/期限、每游戏 APK、apk-asset ReadyToPlay、安装/升级、手柄/触屏、
  NativeAOT/OpenSSL/AAudio/Opus/VP8」——**"没有完整游戏启动 / 正式 Vulkan 游戏渲染的证据"**。
- #160（open）：**"Android 生产 MARK、真实 S2A_Init/guest 生命周期尚未接通，当前仍是诊断 APK"**。

也就是说：**打包成功 ≠ 能玩**。这条链走到 `ReadyToPlay` 就断了，断点就是 §4.1 里那三层。

### 4.5 这块在路线图里是谁的

`#58` 的安卓任务表里，A2 的状态是 **「🟡 外围完成，核心未接」**，待办写得很直白：
"真实原生核心替换 `s2a_native_stub.c`；完整 S2A_Init"。

对应的工作项是 **A-W3「A2 原生核心接入」**：

| 项 | 值 |
|---|---|
| 认领人 | n06ody（#58 标注「已认领」） |
| 分支 | `android/core-link` |
| 任务 | 先做 CMake / 符号审计 / `s2a_native_stub` 替换清单 |
| 验收 | **`S2A_Init` 真实执行；合成 guest IPC / 线程 / svc 通过；无 Apple 调用** |
| 明确禁止 | "不能以模块映射成功作为核心启动完成" |

本 PR 的探针（§4.3）刚好把验收里「`S2A_Init` 真实执行」推进了一步：
服务层在真机上确实起来了、`S2A_Init` 确实返回了。但缺 `runtime/src`，到不了「合成 guest IPC」那一步。

所以 W13 卡在 A-W3 的交付上，不是卡在打包或调参。

### 4.6 把 `runtime/src` 编到 Android：一次真实的编译审计

A-W3 的第一步是「CMake / 符号审计 / `s2a_native_stub` 替换清单」。这里先把**编译**这一层做了，
并固化成只读工具，省得接手的人再摸一遍：

```sh
bash android/tools/core_syntax_audit.sh          # 人读报告
bash android/tools/core_syntax_audit.sh --shim   # 加 TargetConditionals 垫片再跑
bash android/tools/core_syntax_audit.sh --tsv    # 存基线，之后 diff 看回归
```

方法：NDK 29 的 clang，`-fsyntax-only --target=aarch64-none-linux-android29`，逐个跑
`runtime/src/*.c`（**27 个文件，4798 行**；`entry.S` 251 行是汇编，不在语法审计范围）。

两次结果（同一批文件，差别只在有没有垫片）：

| | OK | 缺头 | 形状不同 |
|---|---|---|---|
| 裸跑 | **5** | 18 | 4 |
| 加 6 行 `TargetConditionals.h` 垫片 | **8** | 15 | 4 |

`TargetConditionals.h` 是苹果 SDK 独有的宏头，值全 0 就走非苹果分支。6 行垫片直接救回
`pack_apply` `selfcheck` `widen` 三个文件——这是整件事里最便宜的一步。

**缺头（15 个），都有 Linux 对应：**

| 苹果头 | 文件 | Linux 侧 |
|---|---|---|
| `mach/mach.h` | `alias` `energy` `svc_mem` `vawin`；`diag_brk` `loader` `tdump`（垫片后也卡这里） | `vm_remap`→`mremap`；`task_threads`/`thread_suspend`/`thread_get_state`→`/proc` + `ptrace` |
| `mach/mach_time.h` | `touch`；`os`（垫片后） | `clock_gettime(CLOCK_MONOTONIC)` |
| `os/lock.h` | `det` | `pthread_mutex_t` |
| `dispatch/dispatch.h` | `lifecycle` | `pthread` |
| `sys/sysctl.h` | `boot` `thread` | `sysinfo` / `/proc` |
| `mach-o/dyld.h` | `host_main`（垫片后） | 无对应：Android 由 JNI 传模块目录（`load_modules` 已收路径） |
| `mach-o/getsect.h` | `xstack` | 无对应：段信息从 NPDM / ELF 读 |

**形状不同（4 个，加头解决不了）：**

| 文件 | 错误 | 要做的事 |
|---|---|---|
| `crash.c` | `mcontext_t` 不是指针（Linux 是 `struct sigcontext`） | 按平台取 `ucontext_t` 里的 `mcontext` 字段 |
| `emul_ld.c` | `_STRUCT_ARM_THREAD_STATE64` 未定义 | 用 Linux 的 `struct user_pt_regs` / `ptrace` 结构 |
| `logcon.c` | `F_SETNOSIGPIPE` 不存在 | 改 `MSG_NOSIGNAL` 或忽略 `SIGPIPE` |
| `lowva.c` | `PTHREAD_RECURSIVE_MUTEX_INITIALIZER` 不存在 | 用 `_NP` 版本 |

**规模提示**：三个大头是 `thread.c`（1168 行）、`svc_mem.c`（459 行）、`det.c`（414 行），
其余都在 300 行以内。这不是"编不过"，是三件有边界的事：

1. 一个 6 行的 `TargetConditionals.h` 垫片（立刻救回 3 个文件）；
2. 一组苹果 API 的 Linux 映射（`mach_time`→`clock_gettime`、`vm_remap`→`mremap`、
   `task_threads`/`thread_suspend`→`/proc` + `ptrace`、`os_unfair_lock`→`pthread_mutex`）；
3. 4 处 API 形状适配（上面那张表）。

再加上 §4.3 说的入口改造（`main()` → `s2a_host_run(root)`），就是 A-W3 的全部工作量，
**不涉及 Ryujinx 与服务层**——那部分已经证明能在 Android 上跑。

注意：`-fsyntax-only` 只证明头与类型这一层能过，**不证明能链接，更不证明能跑**。

## 5. 判定

| 项 | 结论 |
|---|---|
| 正版 dump → Android 包 | ✅ 打通（4.2 GB，30 文件） |
| 每游戏 APK | ✅ 打通（APK 120 MB，模块 3/3 从 APK 就地映射） |
| A0 安装事务 / BootSpec / ReadyToPlay | ✅ 真机通过 |
| **A6 第一款完整可玩** | ❌ 未达成——客体执行未接，属 A1–A5 未完成项 |

这不是"跑不起来"，是**链路已经到位、执行核心还没写**。W13 的后续工作取决于 A2 的真实核心与 A1/A3 的接线，
在此之前再换游戏或再调包也不会有画面。

## 6. 复现

```sh
# 前提：本地有正版 dump 与 prod.keys（只按路径使用，不进仓库）
nx_unpack <prod.keys> build/ds-extract --aoc-index --title-id=01004AB00A260000 <base.nsp> <update.nsp>
python3 android/tools/make_pack.py build/ds-pack --root build/ds-extract

# 每游戏 APK
python3 android/tools/game_apk.py build/ds-pack --version-code 1
S2ARM_ANDROID_GAME_DIR=build/android-game/01004AB00A260000 bash android/docker/build.sh
python3 android/tools/game_apk.py --resources build/ds-pack \
  android/app/build/outputs/apk/debug/app-debug.apk build/ds-res

adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb push build/ds-res/. /storage/emulated/0/Android/data/org.s2arm.game.t01004ab00a260000/files/import/ds/
adb shell am start -S -W -n org.s2arm.game.t01004ab00a260000/org.s2arm.android.LibraryActivity --es org.s2arm.android.IMPORT_STAGING /storage/emulated/0/Android/data/org.s2arm.game.t01004ab00a260000/files/import/ds
adb logcat -d -s S2Arm:*
```

## 7. 环境坑（Windows 侧）

- `nx_unpack` 的 `MaxDegreeOfParallelism` 在 Windows 上要降到 1：并发打开同一个 3 GB 的
  `dvdbnd0.bdt` 会偶发 `UnauthorizedAccessException`（`Program.cs:166`）。
- `docker/build.sh` 用 `--user $(id -u)`；Git Bash 下 `id -u` 是 `197609`，容器写不了属主为 1000 的
  `/cache`，会报 `NuGet.Config ... access denied`。用 `id` shim 返回 1000 即可。
- `adb` 在 MSYS 下要 `MSYS_NO_PATHCONV=1`，且源路径要写 Windows 形式（`C:/...`）。

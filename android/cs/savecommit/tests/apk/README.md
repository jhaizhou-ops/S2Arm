# Savecommit 原语：无 UI APP 域测试壳

仅用于原有 `../native_host_test.c`、`../open_read_host_test.c` 原样测试；直接链接
`android/native/s2a_savecommit.c`，不复制实现、不放宽任何断言。
两个 Instrumentation 都只 target 本包 `org.s2arm.probe.savecommit.moongrant`，不创建
Activity/窗口；只在自己的 `filesDir` 新建原创合成夹具。零权限声明，不调用 UiAutomation、
权限身份切换、root、重启、磁盘填满或游戏接口。**不接设备门禁**。

## 构建（工具须预先安装、协议已接受）

需要官方 NDK **29.0.14206865**、JDK **17**、Android SDK API **36** 和
build-tools **36.0.0**，以及 bash、git、Python 3、宿主的基本工具。
不使用 Gradle/Maven，不隐式下载或接受协议。Linux 和 macOS 使用对应 NDK host 包。

```sh
export ANDROID_NDK_HOME=/absolute/android-ndk-r29
export ANDROID_SDK_ROOT=/absolute/android-sdk
export JAVA_HOME=/absolute/jdk-17
export BUILD_DIR=/absolute/scratch/savecommit-apk  # 必须在仓库之外；只供本壳使用
bash android/cs/savecommit/tests/apk/build.sh
```

输出 `savecommit-tests.apk`、`build-evidence.json`（源码身份/逐文件 SHA/产物 SHA/工具）及签名验证。
源有相关未提交修改时标 `+dirty`，不能冒称干净提交构建。`private/debug.jks` 在构建目录首次生成、
以后复用；**不提交或上传 APK、密钥、构建目录**。调试口令是公开惯例，不是生产签名。
同包已装另一测试签名时升级会拒绝；脚本不会卸载或清数据，需操作者另行决定。

默认 `FD_DIAGNOSTICS=0`。定位 FD 变化时可显式 `FD_DIAGNOSTICS=1`：只包装本 DSO 的
`opendir/readdir/closedir`，借原 `/proc/self/fd` 扫描的 dirfd 做 `readlinkat`，写已打开 stderr，
不增加观察 FD。原 FD 相等断言仍执行；**日志改变时序，快照并非原子，诊断版变绿不证明此前变化
已修复或不存在泄漏**。不同开关的产物和设备读数必须分开记录。

## 安装与单次运行（显式授权设备）

构建和运行脚本分离，不自动安装。确认设备和 APK SHA 后，由操作者安装：

```sh
export ADB=/absolute/android-sdk/platform-tools/adb
export ANDROID_SERIAL=YOUR_AUTHORIZED_SERIAL
"$ADB" -s "$ANDROID_SERIAL" install -r "$BUILD_DIR/savecommit-tests.apk"
export EXPECTED_SOURCE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_identity"])' "$BUILD_DIR/build-evidence.json")
export RUN_DIR=/absolute/scratch/savecommit-device-evidence-NEW  # 必须尚不存在
bash android/cs/savecommit/tests/apk/run.sh all
```

也可将 `all` 换为 `native` 或 `openread`，一次只运行指定套件。脚本固定本包、显式设备，
不清数据/强停/重试/改权限；Instrumentation 管理**自身目标包**进程生命周期，运行时该包不能
另有活跃测试。设备正常应用进程仍可能有框架线程，不能假定 FD 集天然稳定。
`run-as` 只读刚生成、严格格式匹配的本包私有目录；不读取其他应用或游戏。返回目录还必须匹配当前套件前缀；同包其他套件的目录也不读取。
`EXPECTED_SOURCE_ID` 必须是拟验产物 `build-evidence.json` 中的完整提交号（可带 `+dirty`），
原生 status 的 `source_commit` 必须精确相等；旧安装包或不匹配来源保留日志并失败，不能冒充当前源码验收。
源码 ID 并非 APK 内容证明：仍须记录拟安装 APK SHA 与实际安装动作，尤其不要混用不同 dirty 构建。

期望有 `state=RETURNED`、`suite_return_code=0`、实际 UID 和 `selinux=...untrusted_app...`，
stdout 为原套件 `... checks, 0 failures`。还必须有唯一且一致的最终 Java `JNI_RETURNED`、
`wrapper_return_code=0` 和 `INSTRUMENTATION_CODE: -1`，且没有 EXCEPTION / FAILED / ABORTED。
原生返回成功后，Java 写证据仍可能失败；因此原生 status 不能单独证明整个测试壳成功。不能把
`am instrument` 退出 0 或 Java `JNI_RETURNED` 当通过。包装器失败、崩溃、环境不支持、
`CLEANUP_ERROR`、FD 相等断言失败均保留原日志，不筛 FD、不重复到绿。提前退出也要释放本次
取得的 FD/UTF、恢复已完成的重定向；恢复失败明确标错。

这是 APP 域合成原语测试，不是 shell 域、游戏存档、杀进程恢复、掉电持久性或第二设备验收。
旧临时壳的真机证据绑定其旧产物 SHA；此仓内壳须记录自己的源码、APK SHA、实际命令和读数。

官方生命周期参考：[Instrumentation](https://developer.android.com/reference/android/app/Instrumentation)、
[manifest instrumentation](https://developer.android.com/guide/topics/manifest/instrumentation-element)。

## 手动宿主清理回归（不登记设备门禁）

```sh
CC=cc bash android/cs/savecommit/tests/apk/unit/run.sh
```

16 个场景覆盖 JNI 失败、路径/status 失败、两次 dup/open/dup2 的失败、部分重定向、
环境拒绝、正常 0 和套件非零返回。使用明确的 fake JNI/UID/SELinux/owner 依赖替身使宿主可达
APP 检查后路径，真实宿主文件描述符验证数量和 stdout/stderr 身份恢复；**不是 Android 运行**。
负控只恢复原路径溢出提前返回，必须以 UTF 未释放失败。原生产测试不参与这条壳单测，未被改写。

## 可选：APP 域的托管 adapter / NativeAOT 检查

默认构建和 `run.sh all` 仍只包含 / 运行原先两套原语。可显式增加第三套 `Managed`：

```sh
export DOTNET=/absolute/official-dotnet-10/dotnet
# 与后续外层构建使用同一个 BUILD_DIR；这是唯一显式联网依赖准备阶段。
bash android/cs/savecommit/tests/apk/managed/build-library.sh --prepare
INCLUDE_MANAGED=1 bash android/cs/savecommit/tests/apk/build.sh
# 完成独立安装授权及实际安装后，记录新 APK SHA 与 build-evidence.json：
bash android/cs/savecommit/tests/apk/run.sh managed
```

准备只从官方 NuGet 源解析当前 SDK 精确版本，构建使用 `--no-restore`，不隐式下载。
`Managed` 使用相同本包无 UI Instrumentation 与目录身份 / APP 域校验，加载一个独立 JNI 桥，
调用单一 NativeAOT 共享库；生产 C 原语静态链接进该库。直接编译真实接口、Android adapter
和实际模块登记，不在测试里替换登记。APK 同时包含实际目标 runtime 的许可证与第三方通知。
无 SHA256 / OpenSSL 调用、无 Process.Start、无游戏数据、无额外权限。

期望 `savecommit managed: 21 checks, 0 failures`，并同时满足上面的 status / APP 域 / 源码身份检查。
覆盖 7 个接口、令牌边界、完整目录交换及重新打开读回、句柄释放、拒绝链接 / 目录 / 非法路径。
失败目录与日志保留；每次运行必须创建新的父目录，不复用失败目录重复到绿。

**这不是完整存档事务验收：** 它不执行 `S2ASaveTransaction`、Host.Boot、游戏、杀进程恢复
或掉电测试。只有实际设备运行后才可报告 APP 域托管通过；构建成功本身仅证明目标编链。
.NET 的 Bionic NativeAOT 是有限支持，需要手写 JNI；配置依据
[官方 Android Bionic 文档](https://github.com/dotnet/runtime/blob/v10.0.0/src/coreclr/nativeaot/docs/android-bionic.md)。

读回脚本另有离线 fake-adb 回归：

```sh
python3 android/cs/savecommit/tests/apk/unit/run_script_test.py
```

16 个场景验证正确结果、错误包/套件/路径、错源码、非 APP 域、清理错误、Managed 检查数不足，
以及 Java 异常、缺最终状态、取消、wrapper 非零、框架失败/中止和重复终态。
移除检查数判据的单变量负控会错误接受 20/21，测试据此证明该判据有效；另一条单变量负控移除最终 Java/框架校验，会错误接受
原生成功但 Java EXCEPTION 的结果。两条负控均应复现假绿；不连接任何设备。

构建在打包前用 NDK `llvm-readelf` 检查两个库的 `DT_SONAME`、托管库版本定义 BASE、
JNI 桥的 `DT_NEEDED` / verneed File 与所需版本，保存 `managed/elf-contract.txt`。
缺失或不匹配即停止，避免产出能安装但无法加载托管套件的 APK。
这只是 ELF 静态加载合同，不证明 NativeAOT 执行或设备上的 21 项通过。

可单独使用仓库规定的已安装 NDK r29 复现链接合同回归：

```sh
ANDROID_NDK_HOME=/absolute/android-ndk-r29 \
  python3 android/cs/savecommit/tests/apk/unit/managed_elf_test.py
```

它编译原创的带版本 Android arm64 ELF，不使用伪造 readelf 文本。7 项断言覆盖原缺失 SONAME、
实际 csproj 链接参数、仅撤回修复的负控、错误 SONAME、桥缺失 SONAME、缺少版本引用、
提供库版本被替换；不调用 NativeAOT、不连接设备；同一测试接入现有 `android/test.sh`，沿用平台 NDK 发现规则。

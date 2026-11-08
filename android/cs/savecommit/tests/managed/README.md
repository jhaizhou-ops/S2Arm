# Android 存档 adapter 托管互操作

从仓库根运行（Linux，已安装的 .NET 10 SDK 和 C 编译器）：

```sh
DOTNET=/absolute/dotnet CC=cc bash android/cs/savecommit/tests/run-managed-host.sh
```

按接口属主确认，只通过测试文件头的 `门禁手动` 声明登记现有 manual 清单，
不接 `android/test.sh`，不新增 Linux 或设备门禁。

无 NuGet 源、无下载。项目直接编译 main 的 `S2AHostFileSystem.cs`、生产 Android adapter
及实际 `aot/AndroidSaveCommit.cs` 模块初始化器，不提供替身接口，不在测试里登记 adapter。
脚本分别构建、运行正向与“移除初始化器”的负向产物，保留原错误输出，最后清理本次独有临时目录。

- 64 项真实 Linux 原生互操作：生产 C 原语经 LibraryImport 调用，探测清理、克隆逐文件哈希、
  交换、令牌长短/缺失/溢出、目录同步、拒绝链接/FIFO/目录、FileStream 所有权及有效 fd=0。
- 43 项输入/缺绑定检查：不让无效 UTF-16、NUL、相对路径、过长令牌进入原生边界；缺库明确失败。
- 有效负控：只省掉生产 ModuleInitializer，必须以“未登记 adapter”失败。没有给测试另装一个实现。

动态 `NativeLibrary` resolver 仅在这个测试进程中用于选中本次编出的本机 `.so`；生产 adapter
不动态发现库或导出，不含反射，Android 静态 NativeAOT 继续由现有 DirectPInvoke(s2a_native) 绑定。

**射程：** Linux CPU / 实际接口与原语的托管互操作，以及登记代码执行。不是完整 Host.Boot、
Android NativeAOT 链接、APP 域托管运行、游戏存档恢复、掉电或第二设备验收。
Native / OpenRead 原语套件与 `../apk` 的 APP 域壳继续单独报告，原测试断言没有改动。

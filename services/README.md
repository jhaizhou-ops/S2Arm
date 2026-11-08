# services/：Ryujinx 系统服务接入（服务接入线归属）

游戏的服务请求经原生层 svc 跳板进 C# 单一入口（`docs/接口_原生层.md` §3），**在发起请求的游戏线程上同步直调** Ryujinx 服务，不经 Ryujinx 的服务线程与内核 IPC。

| 文件 | 内容 |
|---|---|
| `S2A.Services/Exports.cs` | NativeAOT 导出 `S2A_Init`；向原生层登记 `svc / handle_closed / thread_exit / shutdown` |
| `S2A.Services/Dispatcher.cs` | 单一入口：0x1F 连 `sm:`、0x21 / 0x22 发请求；会话表（cookie）；**代行内核 IPC 的句柄拷贝**：请求里的游戏句柄 → 影子句柄表对象，应答里的影子句柄 → 游戏句柄（事件走原生事件、共享内存走 `s2a_shmem_wrap`、子会话走 cookie） |
| `S2A.Services/HleTarget.cs` | Ryujinx 旧 HLE 框架服务（IpcService）的会话：ServerBase.Process 的同线程版；同一 ServerBase 上的请求按上游语义串行 |
| `S2A.Services/SmDirect.cs` | `sm:` 直调版：服务名表与上游同一份 `[Service]` 标注；Horizon 新框架服务由工厂登记 |
| `S2A.Services/GuestMemory.cs` | 游戏内存的 Ryujinx 视图：游戏地址 = 宿主地址，原地读写（远端开着时入口按原生层目录 s2a_far_desc_get 换成影子地址，跨块不连续给副本 / 分段写）；写跟踪结构用 Ryujinx MemoryTracking，页保护动作挂帧率能耗线的 16 KB 精确跟踪（`ReprotectHook`） |
| `S2A.Services/Host.cs` | 起 Ryujinx Switch 侧（不建 Ryujinx 游戏进程）；宿主界面未接项一律报红 |
| `S2A.Services/Red.cs` | 报红：未实现服务 / 命令记名与号，绝不回成功；退出汇总「【红】未实现服务：…」 |
| `S2A.Services.Tests/` | 单测：托管假原生层 + 桩渲染器，经生产同一入口发手工拼的 IPC 消息 |
| `test.sh` | 编译 + 跑单测，输出「期望 → 真结果」表，退出码 0 = 全过 |

Ryujinx 侧所需改动见 `compat/改动清单.md`（0002 内部可见、0003 直调挂钩）。

## 现状（10-19 晚）
- 已通（单测 26/26，假原生层 + 生产同一入口）：sm（CMIF / TIPC）、nvdrv（Initialize / Open / Ioctl）、hid（子会话、共享内存）、
  Horizon 新框架 14 个服务（audren 全链路：注册、受理、子对象、事件、未知命令报红后会话可用）、游戏登记（npdm / NACP / RomFS → fs 读通）、未实现服务 / 命令报红。
- 零分配（逐命令每请求 / 整进程每 5 ms，判据 0 B）：nvdrv Ioctl、fs 读、Horizon 命令、空闲底噪、声音渲染全部 0 B（补丁 0015–0023）。
  未覆盖：vi TransactParcel、audren RequestUpdate（有活动声部）、nvdrv SubmitGpfifo（显卡核心段归帧率能耗线）、hid 宿主侧更新。
- 链进宿主：S2A_CS=1 make host（services/build.mk + nxaot.sh），s2a_* 缺口 0；渲染器库 libnxgal 待帧率能耗线挂 HOST_LIBS。
- 待定：Ryujinx GPU 渲染循环（Switch.ProcessFrame / PresentFrame）由谁驱动（已问帧率能耗线）；M0 动森 Mac 局等原生层用新 main 重跑出报红清单。
- 后续项：RomFS 目录表出包预生成（动森 10.3 万文件现建 0.9 秒）；不启动 Ryujinx 旧服务线程（直调下闲置）；按服务类缓存反射表。

## 正常关闭的资源所有权

关闭入口先停止内存诊断与 Horizon 服务线程，再释放 Switch。输入泵、声音峰值工作线程、内核计时与抢占线程均等待实际退出；统计计时器排空在途回调。Horizon 退出时释放线程事件、堆块和 TLS。共享存档挂载在 LibHac 客户端、服务器和固定缓冲之前关闭，不代替游戏提交。这里仅修复正常关闭，不提供进程内重启入口或静态业务状态重建。

内存诊断的真实线程回归见 [MemDiag.Lifecycle.Tests](MemDiag.Lifecycle.Tests/README.md)。

## Apple 音频会话重复释放回归

`AppleAudio.Lifecycle.Tests` 直接编译实际 Apple 后端及相同依赖，复用 `S2A.Services.Tests/AppleAudioDispose.cs`。测试要求 NativeAOT：真实创建、关闭 AudioQueue 后，只通过正常 `AutoResetEvent(true)` 构造复用原回调 GCHandle 槽，再重复释放会话和驱动，检查事件初始信号、自动复位及 GC 后的行为。缺音频后端、未命中实际槽复用或任一检查失败均退出非零；不使用 FakeNative、游戏或用户数据。

从仓库根运行（macOS arm64，使用与宿主构建相同的 .NET；链接器需要已安装的 OpenSSL / Brotli）：

```bash
S2A_DOTNET=${DOTNET:-$HOME/.dotnet/dotnet}
[ -x "$S2A_DOTNET" ] || S2A_DOTNET=$(command -v dotnet)
export LIBRARY_PATH="$(brew --prefix openssl@3)/lib:$(brew --prefix brotli)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
"$S2A_DOTNET" publish services/AppleAudio.Lifecycle.Tests/AppleAudio.Lifecycle.Tests.csproj \
  -c Release -r osx-arm64 --artifacts-path build/apple-audio-check/artifacts \
  -o build/apple-audio-check/publish
timeout 60 build/apple-audio-check/publish/Ryujinx.Audio.Backends.Apple
```

已发布为 NativeAOT 的完整 `S2A.Services.Tests` 也可直接传 `--apple-audio-dispose`，入口位于 `FakeNative.Install` 之前。JIT 运行此项会明确失败。

修复前反证可用原源码快照指定 `-p:BackendSource=<绝对目录>`；该目录应包含完整 `Ryujinx.Audio.Backends.Apple` 源码。`826a9d71` 的该目录与本轮保留基线逐文件一致，可用 `git archive 826a9d71 compat/tree/src/Ryujinx.Audio.Backends.Apple` 解到独立目录，再以另一套 `--artifacts-path`、输出目录发布，不能覆盖当前源码或修复版产物。

## LibHac 文件系统固定缓冲区回收回归

`FileSystem.Lifecycle.Tests` 复用正式 `FileSystemRestart.cs`，在独立临时根内实际初始化 LibHac 客户端、服务器、ARP/BCAT，挂载 SD 卡并验证前一轮文件读回。每轮关闭客户端和服务器，重复释放 VFS，待独立函数返回后完整 GC，检查旧对象及**实际 14 MiB 缓冲数组**的弱引用，并同时打印 POH 总量、碎片和存活字节。测试先创建目录并断言 `AppDataManager.BaseDirPath`，不允许回退到用户默认目录；结束只删除本轮随机临时根。

生产 VFS 对固定 `Ryujinx.LibHac 0.21.0-alpha.133` 使用精确私有字段链 `FileSystemServer.Globals → FileSystemProxyImpl → SaveDataFileSystemServiceImpl._config.BufferManager`，补上库自身遗漏的 `FileSystemBufferManager.Dispose()`；仅在客户端和服务器已关闭后执行。相关元数据明确保留给 NativeAOT，字段缺失或类型改变直接失败。升级 LibHac 必须同步核对该私有接口并重跑以下 JIT / NativeAOT 两条路径；只检查父对象回收不能检出遗留的 pin handle。

```bash
S2A_DOTNET=${DOTNET:-$HOME/.dotnet/dotnet}
[ -x "$S2A_DOTNET" ] || S2A_DOTNET=$(command -v dotnet)
mkdir -p build/file-system-check/tmp
"$S2A_DOTNET" build services/FileSystem.Lifecycle.Tests/FileSystem.Lifecycle.Tests.csproj \
  -c Release --artifacts-path build/file-system-check/jit-artifacts \
  -o build/file-system-check/jit
TMPDIR="$PWD/build/file-system-check/tmp/" \
  "$S2A_DOTNET" build/file-system-check/jit/FileSystem.Lifecycle.Tests.dll
export LIBRARY_PATH="$(brew --prefix openssl@3)/lib:$(brew --prefix brotli)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
"$S2A_DOTNET" publish services/FileSystem.Lifecycle.Tests/FileSystem.Lifecycle.Tests.csproj \
  -c Release -r osx-arm64 -p:S2AFsAot=1 \
  --artifacts-path build/file-system-check/aot-artifacts -o build/file-system-check/aot
TMPDIR="$PWD/build/file-system-check/tmp/" timeout 60 build/file-system-check/aot/FileSystem.Lifecycle.Tests
```

完整服务测试程序也可使用 `--filesystem-restart`，位于 `FakeNative.Install` 之前。这是实际文件系统生命周期验证，不代表实际游戏或 iOS 设备重启验收。

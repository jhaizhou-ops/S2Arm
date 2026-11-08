# 读回回调登记与原生代次合同

当Signal正在执行旧PreAction时会释放TrackingLock。旧动作撤销后、新动作登记抢先
完成，VirtualRegion缓存权限可能一直是None；原生层就收不到新的None通知，
仍把新动作当成旧generation未完成。仅强制通知也不够：动作指针若先于TrackingLock
发布，Signal还可以在代次通知之前观察到新动作。因此动作发布和通知必须在同一锁内。

`MemoryTracking.ReprotectOnActionRegistration`默认false，保持其他宿主行为；Android
在guest执行前打开。它仅使新激活的读动作重新通知guest域None权限，不在普通Signal/
Reprotect时制造代次，不改原生无进展保护，不放行旧数据。已待处理动作的替换保持原语义。

## 主机回归

```sh
dotnet run --project graphics/vulkan/runtime/readback-registration-tests/Host.csproj \
  -c Release --artifacts-path /absolute/new-host-output
```

先单独准备依赖，实际测试不联网。使用真实MemoryTracking/RegionHandle/VirtualRegion，
仅原生保护端点为guest域计数器。35项涵盖默认/开启、新回调抢先登记、发布原子性、
重复待处理动作不制造epoch、null登记、重叠句柄及下次读回。发布测试持有TrackingLock，
等发布线程实际阻塞后检查动作是否提前可见，不靠固定sleep猜顺序。
`-p:RepoRoot=/absolute/old-source/`可复跑旧源码；新选项用反射探测，旧源仍能编译，
然后在实际合同断言失败。原有TrackingTests/MultiRegionTrackingTests另外79项通过。

## Android runtime/managed联合夹具

`native_fixture.c`直接编入生产track.c、Android tracking/platform.c和plat_android.c；
只导出测试用薄包装。memfd提供真实共享backing，mprotect、mremap别名、权限查询、
原生generation保护均为真实生产路径。逻辑映射范围使用已有MockVirtualMemoryManager，
guest保护通知直达生产native；并非Vulkan/GPU游戏测试，也没有安装游戏的动作。

使用NDK clang编译native_fixture.c为libepoch_native.so（PIC、隐藏默认符号、函数/数据
分段及gc-sections，导出ep_*），runner.c为runner。Native.csproj用现有linux-bionic-arm64
NativeAOT工具链发布Shared库libepoch_managed.so；所有命令、输出和源hash应保存。
设备测试只能在授权设备的独立测试进程执行，库路径经LD_LIBRARY_PATH提供：

```text
runner /absolute/libepoch_managed.so 3
runner /absolute/libepoch_managed.so 4
runner /absolute/libepoch_managed.so 1
runner /absolute/libepoch_managed.so 0
runner /absolute/libepoch_managed.so 2
```

3=正常完成（3项）、4=部分页/邻页保护与实际字节（5项）、1=新回调重登记（9项），
均应退出0。0关闭新合同，复现旧路径；2是真正无进展的旧回调，必须仍触发保护。
后两项应SIGABRT/退出134并保留原日志，不能将意外崩溃一概算成预期失败。

小米17/API36/4KiB/Bionic上，三个正例合计17项通过、退出0；两个负例均命中
`generation=1/1 requested=1 unresolved=1 reprotected=0`并退出134。正例证明新动作
仍保持NONE/dirty，第二次真实读回后原映射得到最新字节。第一轮夹具曾重复Dispose，
虽先打印PASS仍退出1，不计绿；修正夹具后完整重跑以上五项，原始失败记录保留。
这套证据证明具体竞态机制和保护保留，不替代原游戏长时间回归。

本机重建可使用`build-native.py --dotnet <dotnet> --toolchain <NDK-bin> --out <新目录>`。
它记录源/产物hash及实际退出码，不连接设备、不安装APK。`Native.cs`与已跑通过的
联合夹具相同，native包装的生产include路径改为仓库相对路径。

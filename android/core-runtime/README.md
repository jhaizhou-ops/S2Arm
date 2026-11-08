# Android 游戏服务组合

> 合流说明（2026-10-28）：本页合并双方已有说明与原验证记录；相关源码冲突尚待解决，原记录不代表本次候选重新通过。进度见 [合并分析 §13](../docs/direct-main-merge-analysis-20261028.md)。

`AndroidGameRuntime` 是 `libs2a_cs` 内的实际游戏组合入口，不是 diagnostic self-test。
原生 composition 在窗口、模块重定位和客体内存初始化完成后同步调用它；只有
`start == 0`、同一 session、`state == Ready` 且 `error == 0` 只是服务组合的必要条件。
每个实际游戏 pthread（main 与 child）还必须附着托管运行时，然后在同线程完成原生
fault / xstack 探针与最终准入，才能放行 SDK / `nnMain`。
这些检查不代表已经执行游戏、产生画面或通过性能验收。

## 生产调用与所有权

唯一 C 布局是 `android/native/runtime/services_abi.h`；本目录 C# 请求 / 状态
逐偏移对应它。版本 1 为 LP64 的 64 字节请求和 24 字节状态。入口为
`s2a_android_services_start`、`s2a_android_services_status`、
`s2a_android_services_request_stop`、`s2a_android_services_attach_thread`，状态输出由调用者先设置 `size` / `version`。
请求及其 HostApi、leaseApi、UTF-8 路径、native owner 均由原生 composition 保活到进程退出。
同一进程只接受一个非零 session；失败或停止后不允许重新启动。

真实链路为：

1. 校验 HostApi v1 用户 / 输入 / 显示 / 停止表，读取冻结 locale / region / timezone，
   设置 BootSpec 的 console mode，并读取第一份实际输入快照。
2. `Native.UseLinked(native_owner)`；游戏必需的 guest clock 与 deterministic memory
   导出必须完整。`Native.Ready` 只表示函数槽已绑定，不能单独作为游戏准入。
3. 组装 `AndroidVulkanRuntime` 和真实 AAudio，设置输入消费者与 shutdown owner。
4. 调用会传播异常的 `Exports.Initialize(HostConfiguration)`：实际 Native 自检、
   `Host.Boot`、应用 NPDM / NACP / RomFS 注册、program ID 一致性、原生 CsApi 注册、
   输入泵及 GPU `AfterBoot`。GPU Start 必须同步证明其线程 / tracking / renderer 就绪。
5. GPU 无失败且状态仍为 Starting 才发布 Ready。UI / 输入 / GPU 的迟发错误撤销 Ready，
   通过 HostApi stop 通知原生 owner；不能只写日志。
6. 原生层在每个实际 guest pthread 的 xstack 建好后，直接调用
   `attach_thread(session, status*)`。该 reverse P/Invoke 真实访问当前 ManagedThread、
   检查托管执行栈，并建立线程本地 session 绑定；调用前后均检查同 session / Ready。
   非 Ready、已停止/失败、错误 session 或真实附着异常均返回失败。这个返回值不能替代
   同线程随后的原生 fault 探针；也不能用另一启动线程调用它来替 guest 附着。

`request_stop` 只发停止请求，不证明 guest 已退出。`Stopped = 5` 仅由真实 shutdown owner
在 `Cleanup` 全部完成后发布，既有 24 字节状态布局不变；原生层必须检查同 session、
Stopped 和 error0，不能因 void shutdown 返回或 StopRequested 就按成功退出。
Start 失败中的部分清理不会发布 Stopped；Failed 保留最初根因，重复 stop 不回退 Stopped。
真实 native shutdown 回调和初始化失败共用一次清理：停输入，等 GPU owner 退休，再释放
HLE / audio / 文件系统。GPU Stop 抛错时不释放其依赖的 HLE，也不卸载 owner。
若 renderer 已创建但 GPU worker 尚未接管，或者退出时无法证明 WSI / GPU 静止，
保留整个部分组合至进程终止。当前原生 / HLE 单例不支持进程内重试。
Android `S2A_CancelWaits` 通过同一个受控取消 owner 执行；实际 wake 回调异常变为
Failed/Cleanup 并只发一次 HostApi stop，不穿越 UCO。Apple 未安装该 owner 时保持原路径。

## BootSpec 路径和配置

Java 原合同：`userRoot = files/user/0`，`saveRoot = userRoot/saves/<titleId>`。
`game_data_dir` 是受验证的不可变游戏资源根，包含 `exefs/main.npdm`、完整的
`ctl/control.nacp`（0x4000 字节）、`romfs/` 和可选 `systemdata/`。

`state_dir` 是原生组合明确提供的 Ryujinx 数据根，直接传给 AppDataManager。
总装应把它映射到独立的 `saveRoot/ryujinx-android`；其中账户、`bis/user/save` 等仍由
现有 Ryujinx 目录逻辑创建。原生侧负责规范化路径、拒绝符号链接 / 既存布局冲突，
不做静默迁移，也不把游戏资源目录当可写状态。托管入口额外拒绝 state 与 game 同根
或位于 game 内部。本模块不删除 / 清空任何持久路径。`HostConfiguration.SaveDirectory` 当前指向这个实际
持久数据根（存档位于其 `bis/user/save` 下），不是 seed 源；`SystemLanguageTag` 返回 Boot
时经 `s2a_plat_android_system_language` 从 HostApi 读到并冻结的 BCP 47，`MemoryFootprint`
经 `s2a_plat_android_memory_footprint` 返回 `/proc/self/statm` 常驻页 × 页大小的字节数，失败为 -1。
共享消费者尚未使用新增三个字段：当前存档仍由 StateDirectory 定位，MemDiag 仍不读取该委托。

Android typed 配置不使用 `S2A_GAME_DATA`、`S2A_RYU_DATA`、`S2A_SYSTEM_LANGUAGE`、
`S2A_REGION`、`S2A_TIMEZONE`、`S2A_DOCKED` 或 `S2A_SAVE_DIR` 覆盖冻结值。
尤其 `Saves.Dir()` 在 typed 模式关闭 Apple seed 导入路径，绝不把 saveRoot 当 seed
清空再复制。Apple 不传 typed 配置，既有 seed 与无参 `S2A_Init` ABI 保留。
非 UTC 时区需要游戏 systemdata 中的实际时区数据；缺失会明确失败，不能伪装为 UTC。

共享 ARP 注册存在实际顺序缺陷：在 updater 绑定 pid 之前按 pid 查 instance，会得到
InvalidPid 和默认的 0，忽略该错误仅使首个 slot 偶然工作。本改动修复真实
Writer / Registrar.Issue，统一通过 registrar 返回其实际分配的 slot，再绑定 pid，
并逐步检查 ARP Result。这影响 Apple 共享注册行为，不能声称 Apple 完全不变；
需要其服务 / 游戏回归。Android 额外要求 EnsureSaveData 的真实返回值成功，失败不清理存档。

宿主界面直接登记共用 `HostUi`（services/S2A.Services/Host.cs）：与 iOS 同一套策略，
错误提示 / 选用户 / 手柄设置 / 软键盘四个小程序零配置自动应答（手柄设置含多人——
`InputPump.SetPads` 开第二个虚拟手柄），其余未接界面报红一次后按契约回包、不停局。
平台只注册软键盘：`AndroidHostUi → AndroidKeyboard → AndroidHostApi` 的有界 UI broker，
使用内部 `version:1/type:software-keyboard` 协议；broker 异常报红并按「取消」回包。
Activity 主线程的 HostKeyboard
经 JNI byte[] 非阻塞取请求、显示原生 EditText/系统 IME，并按 request ID/Activity
代际回复；detach/stop 撤销会唤醒等待者。旧临时 JNI 输入桥不是当前 handler 的调用路径。
实际 runtime session 绑定、中文 composing watcher 与完整生命周期回归仍待补。
不伪造用户名或把缺少实际用户当作成功。两轨共用设计和明确支持范围见
[系统输入法方案](../docs/system-ime-plan.md)，generic 局部真机证据见
[键盘记录](../docs/keyboard-proposal.md)，不能据此声明 direct/inline 已通过。

## Android 总装源码条目

在现有 `android/cs/aot/S2A.Android.Aot.csproj` 中由总装加入：

```xml
<Compile Include="$(RepoRoot)android/core-runtime/*.cs" />
<Compile Include="$(RepoRoot)graphics/vulkan/runtime/AndroidVulkanRuntime.cs" />
<Compile Include="$(RepoRoot)graphics/metal/cs/NxTrack.cs" />
```

沿用现有 S2A.Services / Vulkan / AAudio 引用。Vulkan 必须是包含真实 Android WSI
adapter 的版本，不能用缺功能替身。新入口在 `libs2a_cs` 内；原生消费方对唯一 ABI 头
强引用 start/status/request_stop。GPU 的 tracking readiness / VM hooks 也是实际强依赖。

## 主机验证

`tests/AndroidServices.Tests.csproj` 引用真实 S2A.Services，并编译 HostApi、状态及 UI
生产源码，验证 ABI / 生命周期竞争、回调上下文和输入范围、失败自检、真实 CsApi 注册
错误传播、typed locale 和禁用破坏性 seed。宿主界面用例（`HostUiTests`）对生产装配
断言：错误小程序 / 消息框 / 截图不停局、按共用实现报红、返回值与 iOS 共用 `HostUi`
一致；前台软键盘挂点经 `HostFixture(ui: true)` 的 broker 回调走通
`AndroidKeyboard → ExchangeUi` 全程（确认 / 取消 / 撤销 / 异常四结局），
`hostui-nohook` 参数作撤挂点负控（必红）。手柄设置 / 选用户要活会话，由共用侧
`--hostui-applets` 与 `TwoPadsTest` 覆盖。

`tests/AndroidRuntime.Tests.csproj` 额外编译实际 AndroidGameRuntime、GPU runtime 和
NxTrack。必须显式给出已构建生产依赖：`ServicesDirectory`（含依赖 DLL）、
`AudioAssembly`、`VulkanAssembly`、`GpuAssembly`、`MemoryAssembly`、`GpuSourceRoot`。GPU / Memory 必须来自同一冻结组，不能混入服务项目带出的旧 DLL。没有可用依赖会失败；不生成假后端。
它的 `arguments`、`host`、`provider`、`cancel`、`path`、`cancel-waker` 参数分别在新进程调用真实 unmanaged
入口；只测试失败 / 取消，不启动 Vulkan，也不冒充真实 Android 服务 Ready。

两个工程的 `arp` 参数直接使用真实 Writer / Registrar / Reader / Updater 和共享
Application 注册方法，验证 slot、过期 owner、并发容量及每步实际 Result 失败传播。
夹具只绕过不相关的 kernel-event 构造，保留真实 instance 存储；不声称初始化了内核服务。
`arp-issue` 可对照修复前程序集，确认旧 Issue 确实抛 NotImplementedException。

`horizon-*` 参数运行真实 HorizonHost 线程、TLS 和 ServiceEntry 入口，复验服务异常的
原始对象/栈传播、首个失败、启动取消、30 秒生产等待上限（测试用更短期限）、
就绪与失败/取消竞争、就绪后的异步故障，以及 Apple 默认无参等待路径。
测试只绕过与抛错无关的 Dispatcher 内核对象构造；不把它当成完整 HLE 初始化。
Runtime 工程还将真实 Horizon failure callback 接入 Android 状态与 HostApi，检查
Starting/Ready 被撤销，失败、清理和重复 stop 合计只通知原生 owner 一次。
Android checked 启动通过 ServiceFailure 订阅异常；Apple 未设置订阅时仍使用原路径。

`shutdown-new-thread-parked` 从无 Horizon 线程上下文的新线程走真实 Android 导出及 Cleanup，
检查 Stopped、音频 owner 收尾和不调用 HorizonHost.Stop。park 边界使用受控阻塞线程，
不证明原生 park、Android NativeAOT 或设备收局；由拆线程主机套件构建生产程序集后执行。

`attach-ready`、`attach-stop`、`attach-failed`、`attach-foreign` 使用外部编译的
`AttachThreadFixture.c` 动态库，每例真正创建并 join 8 个原生 pthread。每线程第一个
托管调用就是实际 attach 导出，之后才检查线程本地 session / ManagedThreadId；
重复调用和非 Ready 状态均验证。C 夹具引用唯一生产 `services_abi.h`，不另造布局。
`attach-owner-failure` 在托管线程注入旧线程 owner，验证实际抛错→Failed→一次 stop。
测试 Ready 是显式状态夹具，不宣称已经 Initialize HLE；CoreCLR 主机附着也不能证明
Android NativeAOT 的 signal / altstack 行为。最终仍需同 guest pthread 原生探针验收。

构建使用离线 NuGet 缓存与外部 `--artifacts-path`；macOS `/tmp` 与 `/private/tmp`
应统一使用规范路径，避免 MSBuild 对外部项目传递引用产生错误相对路径。
以上都不能替代 Android NativeAOT 链接、设备初始化、实际输入、画面、声音和退出验收。

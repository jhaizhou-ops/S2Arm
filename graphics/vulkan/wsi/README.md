# W6：窗口 lease 适配与退休账本（第一切片）

更新：生产 Android 适配器已新增在 `AndroidVulkanSurface.cs` / `AndroidWindow.cs`，
由 [AndroidVulkanRuntime](../runtime/README.md) 消费原 Ryujinx renderer、device、queue。
以下是第一切片的冻结设计与测试记录；其中“尚无 renderer / Vulkan 调用”的描述只适用于
原 `NativeLease` / `RetirementLedger` 切片。实际新增路径、所有权和未验证边界以 runtime
说明为准，不能把旧账本测试当作真实 submit/present 或首游戏证据。

基线 `ce9db716c393d6a78ea0f6925415d7637dadc9d5`。本目录目前**没有接入游戏
renderer，也没有 Vulkan 调用**。它消费已经存在的 Android lease v1 函数表，并约束
W6 调用者何时可复用 acquire semaphore、销毁 swapchain、释放 window 和发送 ACK。
W5 的 enabled-feature 快照工作不等于 device/queue 生命周期接口已经交付。

本切片新增本目录并追加 Android CHANGELOG，不改 Ryujinx、GAL、Android JNI/native lease 或正式 contracts。
所有 C# 类型暂为 `internal`；下面的跨 owner 接口需求是提案，尚未冻结公共类型或 ABI。

## 已实现的合同

- `NativeLease` 按实际 `android/native/wsi_lease.h` 绑定 LP64 v1：state 80B，
  函数表 56B。先验证 prefix 的 size/version，再复制和验证函数指针。host 拥有 lease
  及代码映射，必须活到 consumer 退出后。adapter 不创建第二个 device/runtime。
- 每次 `take` 的 native 引用有去向：保留一份 held window，同代 metadata 更新的额外
  take 引用立即释放；替代窗口的 EBUSY 先退休旧代。身份来自 session/generation，
  不比较 pointer 来判断新旧。revision 只更新本代 metadata，不能当作新 generation。
- `Poll` 可由控制事件调用而不需要 frame；`Wake` 使用已有函数表，`WaitForChange`
  仅接受有限超时。**这不等于已经唤醒真实 GAL worker**，其调用点仍需 shared owner。
- `WindowStamp` 保留 frame 入队时的 session/generation/revision；`MayPresent` 拒绝
  旧代、旧 revision、后台、零尺寸、stop/lost。它不是正式 viewport/触控坐标合同。
- 每个 swapchain 有独立 serial：同代同 revision 的重建也不能让迟到完成事件命中新对象。
  `BeginAcquire` 的 semaphore ID 必须代表具体 live semaphore，不是 frame slot。
- TIMEOUT/NOT_READY 没有 image、不能 submit，可重试已知未 signal 的 acquire semaphore。
  已观察到的其他未取得 image 的失败（例如 OUT_OF_DATE）通过 `FailedWithoutImage`
  退休该 swapchain，同步对象仍不受影响；不能给它提交一帧。没有确定调用结果才进入
  `UncertainFailure` 并保留 semaphore。device lost 另走 `LoseDevice`，不混入可重试分支。
  SUCCESS/SUBOPTIMAL 都拥有实际 acquired image。
- submit completion 仅证明该 submit 内的 source texture use 和 acquire wait 完成。
  它**不证明本次 present 完成**。再次获取同 swapchain 的同 image，且消费其 acquire
  的 submit 已完成，才可退休该 image 的**上一次** present。
- `EnabledPresentFence` 必须来自实际已启用能力；对应 present fence 的成功观察是独立
  证据。raw advertise、QueuePresent 返回、submit fence、Queue/DeviceWaitIdle、固定
  帧数或等待一段时间均没有退休入口。无 fence 路径按 acquired image 跟踪。
- present 错误仍保留 signal/wait、image 和资源所有权；调用者须同时检查 QueuePresent
  返回值与 per-swapchain result。只有真实后续证据可解除不确定性。device lost 禁止
  新工作，不制造完成；stop 允许已提交工作的真实完成事件推进退休，不自动取消债务。
- 先检查 `CanDestroySwapchain`，再实际销毁 views/semaphores/swapchain，最后调用
  `ConfirmSwapchainDestroyed`。本代全部 swapchain 已销毁，`TryReleaseRetired` 才执行
  同步 surface destructor、释放 held window、调用 native `released(generation)`。
  destructor 抛错不会发 ACK。没有 finalizer/隐式 Dispose 来假装 GPU 已结束。

账本不持有 Vulkan handles，不调用或锁定队列；completion 方法必须由实际观察驱动。
除 `NativeLease.Wake` 外均由同一个 backend owner thread 调用。

## 必须先协调的生产接点

| Producer / owner 范围 | 交给 W6 的最小内容与消费点 | 当前实际阻塞 |
|---|---|---|
| W5 + Ryujinx Vulkan owner：`VulkanRenderer.SetupContext`、`VulkanInitialization` | 借用现有 instance/physical device/device、session/deviceGeneration、同一队列及 family、真实 enabled present-fence 能力、停止/丢失通知；W6不得销毁 device | `VulkanRenderer.cs:502–534` 在创建资源后直接 `new Window`，没有 WindowFactory/借用 context；queue/QueueLock 为 internal |
| 同 owner：`WindowBase` / `Window` / `CommandBufferPool` | 受控最终 GAL texture 合成，保持既有 `IAuto` 资源引用；提交的实际成功结果和最后 source-use 对应的 fence token | `Window.cs:347,460` 已用同一 pool；`CommandBufferScoped.GetFence/AddDependant`、`CommandBufferPool.Return` 可复用，不需要第二套 recorder，但错误结果、token/ref 生命周期需要薄接点 |
| 同 owner：现有 `QueueLock` / 受控提交入口 | 每个真实 VkQueue 的所有 submit/present 使用同一个外部同步合同；短调用串行化，不持有它等待 lease、fence 或 worker 退出 | `CommandBufferPool.cs:312–315` 已锁 `_queueLock`；不能让新 W6 独自新建一把锁然后宣称外部同步成立 |
| shared GAL owner：`ThreadedWindow.Present`、`WindowPresentCommand`、`ThreadedRenderer` | 入队时携 frame stamp；非阻塞控制 mailbox/wake；无帧及长命令批间执行 Poll/retirement safe point | `ThreadedWindow.cs:20–26` 与 `WindowPresentCommand.cs:7–26` 没有 stamp；当前同步 `Interrupt` 会等待，不可从 UI revoke 直接替代 |
| Android W3/W4 owner：`window/bridge/host_android` | 在 host lifetime 内交付现有 `s2a_wsi_api_fill` 表；game/diagnostic presenter 互斥；控制事件进入上面的 mailbox | `window.cpp:77–90,101–114` 自动启动独立 diagnostic Presenter；`host_android.c` 的 peek 只供 display 读，不能借它获得 render ownership |
| W4/W11 / shared owner | 最终 viewport 与 frame 同 generation/revision 的正式合同，stale frame 的反馈、触控匹配 | 本目录的 stamp 仅是局部身份，未接 producer、未定义裁切/rotation/input 坐标规则 |

跨层回调不可混同：`WindowPresentCommand.Run:23` 的 `SignalFrame` 是 GAL 限流；
`Graphics.Gpu/Window.cs:279` 的 `ReleaseCallback` 是 guest frame 生命周期；
`swapBuffersCallback` 是第三个合同。丢弃旧 stamp 也必须按原合同各处理一次，不能让 W6
自行补调用任意 callback。当前切片没有更改这三者。

## 明确未完成的安全路径

1. 本地类型不传输 W5 公开 context，不运行真实 submit/present；没有 shared 接点时不能
   宣称此代码修复了现有 `Window.cs` 或 diagnostic Presenter 的退休方式。
2. 无 maintenance1 时，本切片只实现同 swapchain/image 的再 acquire 证明。旧 swapchain
   到新 swapchain 的延迟退休链**未实现**；hard detach 的末次 present 如无独立证据则保持
   未退休，不能 ACK。host 的有期限失败/进程终止政策由平台 owner 保留。
3. acquire 成功后 surface 被撤销（锁屏、切后台、resize 换代）时，`AbandonAcquire` 释放
   该 acquire：不提交、不 present，acquire semaphore 随 swapchain 一起销毁，退休账本
   立即允许销毁旧 swapchain 并 ACK。这只表示“没有这次的 present”，不是完成观测；
   帧属于已经消失的窗口，没有可显示内容被丢弃。真机上 surfaceDestroyed 1000 ms 内
   ACK 由这条路径保证。不确定的 acquire/submit 错误仍保守保留债务；retired 后的
   acquired image 回收与 STOP 后 drain 尚未实现。
4. device lost 不等于 presentation engine 已不再使用 window。此切片没有“强制清空”
   入口；失败上报、进程结束/卸载策略仍要接实际 host。
5. 未实现 format/usage 选择、裁切/pre-rotation、合成 shader、surface support 重查、
   多队列 ownership transfer、软重建、真实 present fence 创建/回收；它们依赖上述单一
   renderer/context，不以新建通用 wrapper 或第二 driver 补齐。

参考 D2R `e3756f8942b40eba6c851e881828a5b1bda17fd6` 的
`dm/android/vulkan_present.cpp:230–268` 有限 acquire、实际 image 索引思路，以及
S2Arm 自有 `presenter.cpp:390–458` 的对应逻辑；**未复制其代码**。没有导入 NVN/.xgs、
游戏配置、shader facts 或第二 device。D2R 的 idle 销毁和当前 diagnostic presenter 的
DeviceWaitIdle 均未当作完整 presentation 退休证明。

同步规则核对自 Khronos [WSI 规范](https://docs.vulkan.org/spec/latest/chapters/VK_KHR_surface/wsi.html)：
未成功 acquire 不改变同步对象；present 的 OUT_OF_DATE/SURFACE_LOST 仍会排入 semaphore wait，
不能把这些错误当成“没有 GPU 使用”。同 image 的再次 acquire 及等待证明见
[Swapchain Semaphore Reuse](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)。
本切片的 present 错误统一保留退休义务；尚未实现 OOM 未排队情况下的 drain/release 补偿。

## 本地 host 运行与证据

需要 .NET SDK 10、C compiler、Python 3；无 NuGet 依赖，显式清空包源，测试不联网。
从仓库根执行：

```sh
python3 graphics/vulkan/wsi/tests/run.py --negative-controls
```

每次运行输出到本目录忽略的 `build/<host>/attempts/<UTC-唯一ID>/`；也可用
`--output-root <私有目录>` 改变根。开始任何编译/身份校验前，根目录 `result.json`
原子替换为本次 `RUNNING`；成功写 `PASS`，异常写 `FAIL` 并非零退出。每个 attempt 自己
保留 result、真实命令、独立 stdout/stderr 与 failure traceback，旧 attempt 不覆盖。
旧格式的根 result 首次迁移时另存 `legacy-result-<SHA>.json`，原日志仍保留。强制杀进程
最多留下本次 RUNNING，不能沿用旧 PASS；证据发布本身失败则本次命令失败，不得只读旧索引
判断成功。并发显式运行的较早完成不能覆盖较晚启动的 current 索引；设备仍只有一个 owner。
此发布锁使用 Unix flock，当前 host gate 范围为 macOS/Linux。

attempt `result.json` 保存源文件、实际 C lease/header、
AnyCPU assembly 和日志 SHA。两项负控分别编译真实账本的私有坏副本：把本次 submit 当作
本次 present 完成，以及把 image 关系错连到 image 0；必须 exit 1，正常源必须 exit 0。

macOS 执行 managed 账本/脚本函数表 consumer 测试，同时编译**真实 C header** 得到 ABI
布局与 managed 布局比较。脚本函数表仅给定状态和统计调用，不另写 pthread producer。
原版 C lease 用 `pthread_condattr_setclock`，macOS 不提供；该门明确记 `NOT RUN`，不改
时钟、不借兼容 stub 冒充真实 C lease 已通过。

Linux 下直接编译未改的 `android/native/wsi_lease.c` 加薄 ref-counter 测试端，
真实 `api_fill/take/wait/revoke/released` 与相同 C# consumer 联合测试：重复 take、无帧
revoke、pending submit/present 不 ACK、同 pointer 新代、真实 EBUSY、stop、最终 ref 平衡。
GPU completion 仍为脚本观察，**不是 GPU proof**。Linux 必须 .NET 10 runtime；可以使用
已编译 AnyCPU 文件，无需 SDK，复制同目录的 dll、deps、runtimeconfig 和 wsi-source.json：

```sh
python3 graphics/vulkan/wsi/tests/run.py --require-native \
  --prebuilt <已冻结attempt目录>/dotnet/bin/WsiTests/release/WsiTests.dll
```

prebuilt 模式校验 assembly 与当前 managed 源身份，禁止拿旧 binary 给新源码盖 PASS。
fixture 的 native window 仅两个不解引用的 synthetic identity，retain/release 用计数；
因此它证明 ABI/lease 所有权合同，未覆盖 ANativeWindow、GAL 调度、实际 Vulkan validation、
Android Surface 生命周期时限、GPU 像素或游戏。真实线程调度、GPU 和产品验收必须另外完成。


### Runner 失败收据回归

```sh
python3 graphics/vulkan/wsi/tests/test_runner.py --out <新的绝对私有测试目录>
```

这会执行真实 runner 三次：首次正常 host PASS；随后实际编译器收到故意非法选项而失败，
测试在它执行中核 current 已从旧 PASS 切成 RUNNING；最后拿首轮真实 AnyCPU assembly
副本配错 source identity，核失败且不执行该 assembly。两次失败都须非零退出、current 与
attempt 均为 FAIL，并保留首轮 receipt/log SHA。没有 mock runner helper，没有修改账本、
lease 或 native producer。macOS 的真实 pthread lease 仍明确 NOT RUN，Linux 才加该门；
这项只验证 runner 的证据/退出机制，不是设备、GPU或完整产品验证。

### 冻结实现的独立复验

实现 `542495c43bf3cec2ee21218e9f48c20db0e99278` 的 10 项源码摘要与冻结 AnyCPU
产物重新核对一致。Linux ARM64 的断网容器实际编译原 C lease，并由同一 managed
consumer 调用，联合 **88 项检查通过**（68 managed + 20 native）；独立 managed
执行也通过 68 项。正常 attempt receipt SHA-256：
`f6815508fa5685e285f4625b0c8c9c0f4b3d080aeec72c2cae6263ee182da1f0`。

随后故意触发真实编译器错误及 prebuilt 身份错误，验证 PASS → 新 RUNNING → FAIL，
两次失败均非零退出，原 PASS attempt 与日志摘要保持不变。因此最后的 current 为
负控 FAIL，正常通过证据在独立 PASS attempt；不改回 PASS 掩盖负控。
这些结果不扩大上面的 GPU、Android Surface 或游戏验收范围。


### Android 最终呈现坐标回归

`tests/present_coordinates.py` 提取并编译当前 AndroidWindow、上游 Window 及 HelperShader 的实际坐标/UV 代码，核对 FlipX/FlipY、裁切、insets 和宽高比。提供已有 SDK 与 Ryujinx.Common 程序集路径；不联网、不安装工具。

```sh
python3 graphics/vulkan/wsi/tests/present_coordinates.py \
  --android-window graphics/vulkan/wsi/AndroidWindow.cs \
  --reference-root . --common-assembly "$RYUJINX_COMMON_DLL" \
  --dotnet "$DOTNET" --output "$OUT"
```

这是 CPU 坐标合同检查，不能替代 Android swapchain 像素、旋转或游戏验收。最终 blit 保留上游的 Y1/Y0 参数顺序，前面的 Y 端点公式须配套，不能另加整幅翻转。

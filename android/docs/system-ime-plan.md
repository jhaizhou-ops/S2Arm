# Android 系统输入法：通用与直连共用方案

日期：2026-10-25。状态：**modal 基础链已实现，完整 IME 与两轨验收未闭环**。原设计基线为 S2Arm `979226fe`；本次按合并提交 `50725333`（包含本地 `android/integration@cbacdf8b`）校正状态。D2R Mobile 参考固定于 `e3756f8942b40eba6c851e881828a5b1bda17fd6`。关联[统一方案的服务与窗口要求](fast-generic-v3.md#6-执行服务和窗口按语义复用-d2r)及 DV-UI；系统输入法必须进入 DV5 首款完整可玩的验收。

## 1. 功能目标与接入位置

玩家在游戏内触发命名、聊天或其他正式软件键盘请求后，App 显示 Android 原生输入框，并唤起玩家当前选用的系统输入法；可用中文候选、英文、删除、光标与选区，确认后将真实文字交回游戏，取消则按 applet 协议返回取消。通用与直连使用**同一套** UI/文本处理，图形模式不决定能否使用系统输入法。

```text
游戏正式 applet 请求
  → Ryujinx SoftwareKeyboardApplet
  → AndroidHostUi.DisplayInputDialog（inline handler 尚未支持）
  → AndroidKeyboard / AndroidHostApi：有界 JSON 请求与等待
  → native HostApi UI broker（request ID；实际 session 绑定待补）
  ← Activity 主线程 HostKeyboard 每 100 ms 非阻塞取请求（JNI byte[]）
  → 原生 EditText + 当前系统 IME
  → 带 request ID / Activity generation 的 JNI 回复
  → Ryujinx 校验与 UTF-8/UTF-16 applet 输出 → 游戏
```

不接管游戏 `nn::swkbd::ShowKeyboard` 等 SDK 函数来绕过系统层。D2R 的原生输入框/JNI/IME 机制可参考，其角色名规则、随机名、数字框单款上限和游戏 ASCII 过滤绕过不进入 S2Arm 通用实现。

## 2. 当前源码已经有什么，仍缺什么

合并后的正式 producer 已是 `AndroidHostUi.DisplayInputDialog → AndroidKeyboard.Show → AndroidHostApi.ExchangeUi → host_ui_android → HostKeyboard`。Java 在 Android 主线程通过 JNI 取请求/回结果，这条键盘路径不从 guest 直接调用 JNI。原 `bridge.cpp:s2a_android_text_input / MainActivity.requestText` 临时桥仍留在源码，但已不是该 handler 的正式调用路径，不再以它定义新架构。

| 已有实现 / 证据 | 尚缺的闭环 |
|---|---|
| typed v1 请求与回复，header/subtitle/guide/submit/initial/mode/min/max；有界 broker；标准 UTF-8 JSON 通过 JNI byte[] 传输 | 明确 unsupported mode、长度及编码边界的支持范围；不能将协议测试算成所有 IME/语言通过 |
| Activity generation、request ID、detach/stop 唤醒和迟到回复拒绝；stop 先撤销 UI 等待 | native 当前 `s2a_ui_broker_create(1)` 为进程内固定会话；需与实际 runtime session / Java UUID 明确绑定并补跨身份负例 |
| Java 主线程非阻塞轮询 broker；JNI 不运行在请求 applet 的 guest/xstack 上 | 保持这一路径，不额外引入第二套 JNI 派发线程；补后台/Activity 快速替换及单虚拟核回归 |
| AlertDialog/EditText、焦点与系统 IME 显示、min/max/mode 校验；拒绝 NUL/不完整代理对；确认与取消分开 | 没有 composing span watcher；组字结束、候选提交、光标/选区、emoji 边界仍需实现或设备验证；强化一次完成与失败回复处理 |
| [integration 记录](keyboard-proposal.md)已有 generic 真机实际弹 IME、确认、BACK 取消；输入中 Stop 唤醒并退出 | 是合并分支的既有证据，本轮没有重做真机；当时确认/取消后因缺 NgWord 系统数据停止，不能算游戏完整通过 |
| `CreateDynamicTextInputHandler` 仍明确 Unsupported | inline 持续文本/选区协议尚未实现；direct 后端也未实现，两轨验收不能报通过 |

这次校正不修改运行时代码。已存在的 broker/消费者不再作为全新任务重复建设；剩余工作按下文 UI0–UI4 收口。

## 3. 从 D2R 采用的经验

- `text_input_jni.c` 把 JNI 放在保留原始 pthread 栈的专用线程；请求自己持有字符串副本，不借用 guest 栈。调 Java 时不持 native input 锁，否则“无 Activity 立即回调取消”会重入死锁。
- D2R 回调核对 request ID，过期回复不能写进新请求；只记录请求状态和长度，不记录玩家文字。S2Arm 已接 Activity 代际与 HostApi broker；实际 session 绑定仍要补，不另起一套相互未知的文本队列。
- `DmActivity.openInput` 在显示后请求输入焦点并要求系统软键盘可见；只有有效前台 Activity 才能展示，重复弹框不叠加。
- 中文候选选定有时只移除 composing span、不改变文字，TextWatcher 收不到；D2R 用 SpanWatcher 重新检查，避免“候选已选但确定按钮一直灰”。处理期间不要 setText/裁剪正在组字的内容。
- Activity pause/destroy 会 dismiss dialog，确认和 dismiss 共用 once 标记，只完成一次；生命周期工作在宿主线程串行执行，UI 回调不等待 GPU。
- 长度截断不拆开 UTF-16 代理对；UTF-8 字节容量与 HLE 字符长度分开校验。D2R 的 15 字节角色名限制/允许字符属于单款规则，不能直接照搬。

D2R 的派发线程在本基线是 detached 的进程级循环，不能原样作为 S2Arm 的 Stop 完成证明。S2Arm 采用 Android UI 主线程取请求，满足 JNI 使用宿主栈的要求，无需另建该 worker；broker 保活到进程退出，停止与代际检查拒绝迟到请求。

首版会话绑定、composing watcher、一次完成、输入隔离与inline范围的具体实现决定已在[实施契约§7.2](direct-mode-contracts.md#72-统一-stop-与系统输入法)确定；下文未闭环指代码与验收进度，不表示还要重新选择架构。

## 4. 请求与结果契约

沿用已实现的内部协议 `version: 1, type: "software-keyboard"`，不另建此前拟议的 `swkbd.dialog` 平行协议。当前不是新的公共 HostApi ABI；native broker 仍传输不透明 JSON，由生产 C#/Java codec 校验。只有 producer ready 才发布 UI 能力，不能用 `S2A_HOST_CAP_UI` 掩盖 inline 尚未实现。

请求已包含 mode/min/max/header/subtitle/guide/initial/submit；request ID 与 Activity generation 在 transport 传递。真实 runtime session / Java UUID 绑定是待交付项，不将固定 session 1 描述为已经完成。若演进 envelope/版本，两端和负例须同批更新。密码、无效字符、扩展模式等若接口未携带，要演进正式 HLE UI 接口，不在 Android 侧按游戏名补规则。

当前请求上限 4096 字节、回复上限 8192 字节、HLE 长度上限 1024 个 UTF-16 code unit；超界明确失败，不截断 JSON。回复 `status: "ok"` 才携带有效文字，`"cancel"` 是玩家取消；transport 撤销映射为 HostRevoked，其他失败状态明确抛错。合法空字符串仅在 min 允许时接受，不与取消混淆。

JNI 交换带长度的 byte[]，由 JSON codec 按标准 UTF-8 编解码，不以 NewStringUTF 的 modified UTF-8 代替。已实现结果 NUL/代理对检查；请求侧、恶意编码和全量边界仍按生产 codec 测试补证。回复必须只属于原 request/Activity，重复或迟到完成被拒绝；实际 session 隔离补齐前不声称跨会话契约已冻结。guest UTF-8/UTF-16 输出及 applet 结果仍由 Ryujinx 负责，不编造默认名或自动确认。

## 5. 线程、生命周期与图形的关系

请求状态为 queued → shown → accepted/cancelled/failed → consumed；取消可以从 queued/shown 进入终态，终态只发布一次。用户等待输入时，最多阻塞请求它的普通 applet/guest 工作线程；单虚拟核下等待与虚拟核让出仍需实际验证。不能阻塞 UI 或 Vulkan owner，也不能让全部 guest 线程停在持锁状态。

| 事件 | 必须行为 |
|---|---|
| 弹出输入框 | 清除触屏/手柄按住状态，隔离虚拟手柄输入；只在有效前台 Activity 上 show，焦点给 EditText |
| 中文组字/候选选定 | 保留 composing 内容与选区；组字结束即重新判断，不等额外键入一个字才更新按钮 |
| 确认 | 先完成候选输入，再按真实 min/max/mode 检查；一次性回复，dismiss 不再次回取消 |
| Back、取消、dismiss | 仅收到实际取消/dismiss 时完成取消；仅隐藏 IME、编辑框仍显示时不凭空结束请求 |
| HOME/onPause/onDestroy | 主线程取消并关闭当前框，broker 等待者及时被唤醒；Activity 重建不携带旧 request；不在 UI 线程 join GPU/worker |
| session stop / direct 初始化或运行失败 | **先取消 UI 请求，再等待 guest/worker 退出**；迟到 Java 回调不写旧 native 指针，不能等输入超时才完成 Stop |
| 恢复/下次请求 | 最新前台状态重新准入；无粘住按键、旧 dialog、错误光标或旧文本泄漏；恢复沉浸式布局 |
| IME 引起 focus/insets/窗口尺寸变化 | 只按真实窗口事实更新 ScreenConfig/租约；单纯焦点转到 dialog 不是 GPU 丢失，也不是直连失败；不无条件停 device/重建 swapchain |

“玩家取消输入”和“Activity 暂时不可用”不直接标记 shader/direct 失败。UI 实现真实异常按 UI/session 错误报告；是否结束当前游戏依 HLE 和宿主既有规则，不吞成 accepted。正常 IME 弹出/关闭不得触发错误的下次 generic 锁。

## 6. 实施任务与验收

DV-UI 与 DV1–DV4 并行，是两轨共同基座，**modal 系统键盘通过是 DV5 首款可玩的前置**。它不等待直连 Vulkan 后端建完才开始。

| 子任务 | 改动落点 | 退出条件 |
|---|---|---|
| UI0 契约与 native broker（部分实现） | 复用已接 typed v1 与 broker，补实际 session 绑定与边界 | producer/consumer 同版本、accepted/cancel/error 区分；长度/Unicode/旧请求/Stop 唤醒负例通过 |
| UI1 JNI 与 Activity（部分实现） | 复用 UI 主线程轮询、`host_ui_jni/NativeBridge/HostKeyboard`，补生命周期竞态 | 真实宿主栈 JNI、单活动框、session/Activity/request 校验、once 完成；可取消退出，不持锁调 Java |
| UI2 中文 IME 与样式（部分实现） | 原生 EditText/系统 IME、通用文本校验 | 组字 span 结束而文本不变仍可确定；初始文字/光标/选区/min/max/数字模式正确，不套 D2R 单款规则 |
| UI3 inline（未实现） | `IDynamicTextInputHandler` 与 Ryujinx inline applet 的正式适配，Android InputConnection | 持续文本/选区更新、事件顺序、SetText 回环抑制和 Dispose/取消通过；完成前明确 Unsupported |
| UI4 两轨真机回归（generic 局部、direct 未测） | Android runtime/外壳测试与文档 | generic 与 direct 同样能调系统 IME、确认/取消、HOME/恢复/旋转/Stop；存档与正常返回不受影响，未就绪 direct 标未测 |

主机测试：codec/schema、标准 UTF-8↔UTF-16 的中文/补充平面字符/边界长度、exactly-once 结果、旧 callback/换 session/队列满/取消、停止唤醒与锁重入；测试真实生产 broker 和转换函数，不能只测一份镜像模型。

设备测试：实际唤起当前系统 IME；中文拼音选择候选（尤其“文字不变、只结束组字”）、英文、删改/选区/初始文本、合法空值、HLE 长度边界与 emoji；确认、Back/取消；输入中 HOME、Activity 重建、旋转、退出游戏和立即再次请求；核对 UI/GPU 无阻塞、键盘不压住手柄输入、没有错误 generic 回退。记录设备/OS/IME 实际版本和模式，文本内容只作私有验证，不进日志/PR。

原设计的参考验证：D2R `TextInputRulesTest` 的 **12 个主机用例**与 POSIX `lifecycle_dispatch_test` 编译/执行通过。它们只证明参考实现的部分文本/调度逻辑，不能证明 S2Arm 的新输入链、中文 composing watcher 或系统 IME 已在手机上通过。此次合并后状态校正也未修改输入运行时代码。

合并后本轮验证：生产 `AndroidKeyboard.cs / AndroidHostApi.cs` 的 `Keyboard.Tests.csproj` **69 项断言通过**；`keyboard_owner_test.c` 与生产 `host_ui.c / host_ui_android.c` 编译执行通过，覆盖 UTF-8、容量不足、Activity ownership、迟到回复、detach、Stop 和终态。没有重跑 APK/系统 IME，也不把这些主机检查当作 composing 或 direct 验收。

## 7. 固定参考源码

- [D2R JNI 请求派发与 Unicode 转换](https://github.com/jhaizhou-ops/d2r-mobile/blob/e3756f8942b40eba6c851e881828a5b1bda17fd6/dm/android/text_input_jni.c)。
- [D2R 原生输入框、composing watcher 与 Activity 取消](https://github.com/jhaizhou-ops/d2r-mobile/blob/e3756f8942b40eba6c851e881828a5b1bda17fd6/dm/android/app/src/main/java/com/xiaoboluo/d2r/DmActivity.java)。
- [D2R 文本规则与代理对边界](https://github.com/jhaizhou-ops/d2r-mobile/blob/e3756f8942b40eba6c851e881828a5b1bda17fd6/dm/android/app/src/main/java/com/xiaoboluo/d2r/TextInputRules.java)（其中角色名/数量规则不直接采用）。
- S2Arm：[AndroidHostUi](../core-runtime/AndroidHostUi.cs)、[typed codec](../core-runtime/AndroidKeyboard.cs)、[JNI byte[] 桥](../native/host_ui_jni.cpp)、[Activity 输入框](../app/src/main/java/org/s2arm/android/HostKeyboard.java)、[有界 UI broker](../native/host_ui.h)、[既有验证记录](keyboard-proposal.md)、[HLE 输入参数](../../compat/tree/src/Ryujinx.HLE/HOS/Applets/SoftwareKeyboard/SoftwareKeyboardUIArgs.cs)。

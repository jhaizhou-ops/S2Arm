# C6 Android 系统输入法：中文与两轨负控记录

日期：2026-10-25。分支：`android/direct-c6-ime`。本记录**不修改验收表**，也不宣称 C6 完成；C6 仍是“部分”。

## 1. 固定环境

| 项 | 值 |
|---|---|
| 设备 | Redmi 22081212C（`diting`），Android 16 / SDK 36，1220×2712，480 dpi |
| GPU / 驱动 | Adreno 730，Vulkan 1.1.128 |
| 系统输入法 | Gboard `18.4.1.985164140-release-arm64-v8a`，包名 `com.google.android.inputmethod.latin`，子类型“简体中文 / 9 键”（subtype index 144） |
| APK | 诊断包 `org.s2arm.android`，静态 NativeAOT 服务层，`sha256=70323314bad5e2a93b7543bcaa3dde4d5ab3e24e8342521dd395c37695cd0e4b` |
| 模式 | 诊断 preview 外壳 + 真实系统 IME；`mode=5`、`min=1`、`max=16`；竖屏仅用于让候选/按钮可见 |
| 采集 | `adb logcat -s S2Arm:I` 原始输出见同目录 `confirm.log`、`cancel.log`、`stop.log`；设备信息见 `environment.txt` |

文本是固定测试串“你好”。S2Arm 只记录状态与长度，不记录回复文字；日志中没有玩家文本、存档或游戏资源。

## 2. 本轮代码改动

- `HostKeyboard`
  - 去掉 `FLAG_ALT_FOCUSABLE_IM`。这个标志让窗口“不被 IME 服务”，`showSoftInput()` 被系统忽略；只清 `FLAG_NOT_FOCUSABLE` 或只加 `ALT_FOCUSABLE_IM` 都不够。现在对话框可聚焦且可被 IME 服务。
  - `mode=5` 不再加 `TYPE_TEXT_FLAG_NO_SUGGESTIONS`，让中文候选条出现；其他文本模式仍保持无词典建议。
  - 完成日志增加 `chars=` / `utf8=`（不打印文字），便于核对中文与 UTF-8 字节数。
  - 保留 `TextWatcher` + `SpanWatcher`，候选只移除 composing span 时仍刷新“确定”状态。
- 预览 selftest
  - `uiSelftest(mode,min,max)` 可由 intent 传入模式与长度；`host_ui_android.c` 生成请求并启动一个**只记录状态/字节数**的 waiter。
  - waiter 在 Stop 时被 broker 唤醒（`rc=-4`），用于证明“先唤醒等待者再退出”的负控；生产 applet 的 waiter 仍是 C# `AndroidHostUi`。
- 复现脚本：`android/tools/direct_c6_ime_zh.sh confirm|cancel|stop`。脚本不安装/不替换 APK，不改 Gboard 配置，结束后恢复旋转并停止诊断包。

## 3. 真机原始日志

### 3.1 拼音组字 → 候选 → 确认

实际步骤：`mode=5` 请求唤起 Gboard 简体中文；`adb shell input text nihao` 进入 Gboard 组字，候选条出现“你好 / 内耗 / 你 …”；点空格选定高亮首候选；`uiautomator` 读回 EditText 文本为 `你好`、`确定` 为 enabled；点确定。

```text
14:56:00.946  Keyboard selftest request: id=1 mode=5 min=1 max=16
14:56:00.969  Keyboard request shown: mode=5, min=1, max=16
14:56:09.797  Keyboard request completed: ok, chars=2, utf8=6, result=0
14:56:09.798  Keyboard selftest reply: rc=0 status=ok bytes=70 (text not logged)
```

`chars=2, utf8=6` 是“你好”的 UTF-16/UTF-8 长度；broker 返回 `result=0`。原始日志：[confirm.log](validation/c6-ime-20261025/confirm.log)。

注：日志中的 `Keyboard focus=true ime=false` 是 `show()` 后立即打印的时序值；随后 `dumpsys input_method` 显示 `mInputShown=true` 且 served view 为对话框 EditText。

### 3.2 取消

```text
14:56:15.368  Keyboard selftest request: id=1 mode=5 min=1 max=16
14:56:15.401  Keyboard request shown: mode=5, min=1, max=16
14:56:19.138  Keyboard selftest reply: rc=0 status=cancel bytes=58 (text not logged)
14:56:19.138  Keyboard request completed: cancel, result=0
```

取消不产生文本，`status=cancel` 与 `ok` 分开。原始日志：[cancel.log](validation/c6-ime-20261025/cancel.log)。

### 3.3 输入中 Stop（preview 负控）

输入框处于拼音组字时，通过 `--ei s2arm.request_stop 0` 向 HostApi stop 表请求停止：

```text
14:56:24.518  Keyboard selftest request: id=1 mode=5 min=1 max=16
14:56:24.548  Keyboard request shown: mode=5, min=1, max=16
14:56:29.306  Keyboard selftest reply: rc=-4 status=none bytes=0 (text not logged)
14:56:29.332  HostApi stop requested: exit requested (debug intent)
```

`rc=-4`（`S2A_HOST_E_UNSUPPORTED`）是 Stop 撤销/唤醒等待者的结果，不是崩溃；同一日志里无 `FATAL EXCEPTION`/`ANR in org.s2arm.android`，Activity 结束。原始日志：[stop.log](validation/c6-ime-20261025/stop.log)。

## 4. 两轨与单虚拟核：证据、负控和未完成项

### 已做

- **preview（非游戏、非 direct）**：上面的中文确认/取消/Stop 都是这条链，证明 `HostKeyboard → JNI → host_ui_android → broker` 在真实系统 IME 下可用。
- **broker 共用/session 绑定（主机）**：同目录 `broker-host-tests.txt`：
  - `ui-session: ok`（绑定真实 session、在途请求拒绝换绑、取消后可换、stop 后拒绝绑定）；
  - `PASS keyboard producer: UTF-8, RANGE, ownership, late reply, detach, stop, terminal state`；
  - `UI broker: 199 host assertions passed`。

  这些是生产 `host_ui.c` / `host_ui_android.c` 的 host 断言，不是设备 IME，也不替代 direct 游戏内文本。

### 未做 / 限制

- **direct 轨未跑**：C5 直连前端/游戏文本尚未接通，无法在 direct 包内触发真实软件键盘；本记录不把 preview 或 broker 主机测试算作 direct 通过。
- **generic 游戏内文本未跑**：诊断 preview 不是 Ryujinx applet；没有在真实 generic 游戏的命名/聊天框复验。用户手动在 preview 软键盘输入两个字并点确定（人工观察），未作为正式游戏证据。
- **单虚拟核（`S2A_CORES=1` / 受限核掩码）+ Stop 未跑**：第 3.3 节只是 preview 的 waiter 唤醒；没有 guest 线程持核/放核、没有真实 applet 等待者，也没有 direct/单核进程收局。不能据此报“Stop 单虚拟核不崩溃”。
- **候选条点选未自动复现**：本机竖屏 `ADJUST_RESIZE` 下 Gboard 候选条位于 IME window 的 touchable region 上方（`touchable region=(0,1704,1220,2712)`，候选条在 y≈1620–1700），`input tap` 点候选会落到应用窗口；脚本用空格提交高亮首候选。真实玩家用软键盘点候选/空格都可以，但“点候选条”的自动证据仍缺。
- 横向（游戏常用）下 Gboard 会进入全屏 extract 编辑，候选/确认交互与竖屏不同；本记录未把 extract 路径算通过。
- HOME/Activity 重建/旋转/emoji/长度边界/初始文本/选区仍未系统跑；不改验收表，C6 不宣称完成。

## 5. 复现

```sh
# 设备已装诊断包，Gboard 为默认输入法且启用“简体中文 / 9 键”
bash android/tools/direct_c6_ime_zh.sh confirm
bash android/tools/direct_c6_ime_zh.sh cancel
bash android/tools/direct_c6_ime_zh.sh stop
```

输出默认在 `build/c6-ime/`；可用 `S2A_C6_OUT` 改目录。脚本默认假设 1220×2712、Gboard 9 键；其他分辨率/布局需先改按键坐标（空格、EditText、按钮位置从 `uiautomator dump` 读取）。APK 构建（仅诊断包）：

```sh
S2ARM_ANDROID_CS_SERVICES=static bash android/host/build.sh :app:assembleDebug
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

## 6. 主链接入步骤（后续，不在本分支做）

1. 保留 preview selftest 只作调试入口；正式游戏路径继续走 `AndroidHostUi.DisplayInputDialog → AndroidKeyboard → AndroidHostApi.ExchangeUi → host_ui_android → HostKeyboard`，不要从游戏代码调 `uiSelftest`。
2. 游戏包用 `S2ARM_ANDROID_CS_SERVICES=static` 构建，启动后确认 `HostApi v1` 的 capabilities 含 UI；`runtime.c` 在 HLE 前已把 broker 绑定到本局真实 session，不能在游戏启动后再换绑。
3. generic：在同包同存档路线进到真实命名/聊天框，重跑 confirm/cancel；记录设备、游戏版本、输入法版本和 `result=0`，不要用 preview 代替。
4. direct：等 C5/C7 的 direct 前端与游戏文本接通后，用 `--es s2arm.graphics_mode direct` 启动；同一 broker/JNI/Activity，不另建 UI 队列。再跑 confirm/cancel，并用 `S2A_CORES=1`（或单核掩码）在输入中 Stop，核对等待者被唤醒、无崩溃、无按键粘连。
5. 上述 direct + 单虚拟核证据齐了，才按实际证据更新[统一方案的 C6 验收状态](fast-generic-v3.md#72-当前验收状态)；preview 结果不报 C6 完成。

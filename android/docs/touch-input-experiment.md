# Android 通用触点传输实验

关联 #58 / A-W4。初始切片基于 ce9db716；当前本地候选已迁到 android/integration@c6cfcc04，接通最终视口、Ryujinx TouchScreen 与可选 Gesture 共享内存；菜单点击仍待新包真机复验，不承诺完整游戏运行。

## 范围与接缝

- GameTouch：预分配完整触点集合，以稳定 pointer ID 管理触点，坐标相对正式呈现端提供的 Switch 触屏有效矩形归一化为 0..65535；该矩形不是整幅宽屏画面。
- TouchPadView：DOWN 时分配虚拟控件/游戏触点所有权；MOVE 不跨区域迁移所有权；处理 MotionEvent 历史集合及源事件时间。失焦/暂停、窗口或布局变化取消已有触点。传输失败或超限明确记录错误并关闭实验。
- TouchInputBridge / touch_jni.cpp：独立 JNI，不修改 W3 bridge.cpp 或现有 NativeBridge。未编入实验时启用返回 Unsupported。
- touch_input.c：默认关闭、互斥保护的 64 帧历史，读者自持游标，重复读取不消费。开启后若曾有输入，先发布新序号 CANCEL，避免采样间关/开把两个手势连接起来。
- touch_contract.h：Android 实验内的候选结构，暂不加入公共 HostApi。点为 5 个 u32，帧为 352 B；最多 16 个触点，拒绝超限和重复 ID，不静默截断。字段定义仍需 n06ody/vickwv 对齐正式 HID/HostApi。

正常空集合是 release；CANCEL 不是 Tap。历史溢出返回 Range 和空 CANCEL；消费者先取消 held contacts，再按返回序号重同步。只有 HID 提交成功后才能推进游标。关闭返回 Unsupported，消费者必须取消 held contacts。时间为 MotionEvent uptime 毫秒转换为纳秒，不冒充纳秒精度；原生生命周期取消使用 CLOCK_MONOTONIC。

## 开关

默认 CMake `S2A_ANDROID_EXPERIMENTAL_TOUCH=OFF`；Gradle `-Ps2arm.experimentalTouch=true` 可编入实验。即使编入，运行时仍默认关闭。

同一 APK 可用下列 Intent 切换（设备号须本次 adb 查询，不硬编码旧端口）：

```sh
adb -s <device> shell am start -n org.s2arm.android/.MainActivity --ez s2arm.experimental_touch true
adb -s <device> shell am start -n org.s2arm.android/.MainActivity --ez s2arm.experimental_touch false
```

外壳开启后等待最终游戏视口；关闭在 Activity 销毁时执行。编入及开启实验不代表真机触屏已验收。

## 当前本地接线与边界

`AndroidWindow.Present` 在现有最终 blit 处发布实际 Switch 16:9 目标矩形、buffer 尺寸；纹理翻转不翻转显示空间的触点；不改 WSI fence/ledger/退休算法。非 16:9 扩展投影暂不发布触屏区域，禁止把整幅宽屏压成 1280×720。`TouchPadView` 按事件读取几何，仅接受与自身像素尺寸一致的视口，未 ready 时拒绝游戏 DOWN。虚拟控件继续独占 DOWN 命中的手指。

`game_touch.c` 在同一锁下校验发布帧对应的窗口代次及几何修订，修订竞态丢弃旧坐标并发布 CANCEL。尺寸/布局撤销后须有新的 compositor 修订；Surface 销毁独立终止旧代次，迟到的旧代次发布不能复活它。取消和 overflow 不生成 Tap。

`AndroidTouchInput` 通过 InputPump 的可选 TouchHook 在同一个 HID owner 线程采样，缺省关闭时不写 TouchScreen；Apple 不安装该 hook。掌机模式转换到 Switch 1280×720，主机模式取消触点。每次读取最旧未提交帧，仅在实际 `Touchscreen.UpdateWithIds` 返回后推进游标。稳定 host ID 不因其他手指抬起而重新编号；Start、End 和 held 使用已有 Ryujinx TouchDevice，16 槽装不下新旧交替时先提交 End，再重试原帧。CANCEL/历史溢出直接清空，不合成 End/Tap。静态数组复用，没有每次采样分配。

没有修改公共 HostApi 布局。显式开启 Android 触屏后，首次触点才创建 Gesture 生产者；默认 SharedMemory.Create 不初始化或写 Gesture 区域。使用现有 RingLifo/AtomicStorage，在 0x3BA00 写 0x60 状态及持久历史；重复来宾读取不消费事件。TouchGestureState 仅识别单指 Touch/Tap/Press/Pan/Complete/Cancel，使用源单调时间；Gesture 游标不越过已提交的原始触屏游标。多指手势明确取消并报告不支持；DoubleTap/Swipe/Pinch/Rotate 未实现，继承的 ActivateGesture stub 警告保留。主机 ABI/历史回归不能替代游戏响应、完整 HID 服务语义或核心指标验收。

游戏窗口使用 Android 沉浸系统栏 API，前台可见的游戏 Surface 请求保持亮屏；停止游戏即释放请求。保留实际画面比例，不拉伸裁切，也不改系统全局息屏时间。诊断应用沿用原窗口行为。

## 验证

`android/test.sh` 包含 C 历史缓冲测试和 Java GameTouch 状态测试。覆盖采样间短按、重复游标、CANCEL、溢出、开关重开屏障、非法/重复触点、结构尾部保护、10000 次并发快照，以及坐标归一化、稳定 ID、视口变化/撤销和传输失败。

验证结果以 PR 所附实际运行记录为准。主机测试不覆盖真实 MotionEvent 注入到 HID 的全链，Android 构建/诊断启动不替代真机、完整列车或 Apple 回归。游戏兼容性、性能、功耗及核心指标均未验收。全部实现无游戏地址、名称分支、SDK/NVN 拦截或专用补丁。

### 本切片验证记录（2026-10-23）

- 独立分支 LF 源码运行完整 test.sh：CTest 11/11，Java/契约及负例通过。Windows javac 17 编译，WSL OpenJDK 21 运行。
- NDK r28b / API29 / ARM64：默认 OFF 和显式 ON 原生库构建通过；没有借用包含其他本地 core/NativeAOT 修改的库。
- API34 手工诊断 APK：aapt2/javac/d8/zipalign/apksigner，仓库 verify-apk.py 验证 ARM64 与 16 KB ELF/ZIP 对齐通过。不是 Gradle assemble/lint 或正式出包验收。
- taikou-package-test（API34 x86_64，ARM64 翻译）：本切片 APK 冷启动成功，同 APK 开启/关闭均到达独立 JNI；开启明确报告缺视口/HID，最后保持关闭。APK SHA-256：5f3161ef09efa5b36c4d2f9f17432bab22d98b786d8d933135045a7bf9dbc38c。
- 未做真机、多指 MotionEvent→JNI→HID 全链、游戏、性能或完整列车验收。取消屏障序列的证据来自 C 机制回归，不由 APK 启动成功推导。

### PR #68 命中区域修复

分流与虚拟按键统一调用 `TouchPad.Control.hit`，保留摇杆 1.25、按钮 1.15、方向键 1.2 倍半径的原有命中区。`TouchPadView` 的 DOWN/MOVE/UP 调用 `TouchRouting`；主机回归执行这套实际分流函数，覆盖扩展边缘、实验开/关、有/无视口、隐藏控件、跨区移动和多指释放，并检查控件触点未进入发布帧。

这些回归不构造 Android MotionEvent，不替代 View 事件分发、历史事件、JNI/HID 或真机端到端验收。

本次修复验证：Windows JDK17 的 TouchPad/TouchRouting 回归通过；把分流换回旧 1.0 倍规则的隔离负控在 dpad edge 断言失败。当前代码的独立 LF 快照完整 test.sh 通过（CTest 11/11、Java 与契约负例）；直接使用 CRLF 检出时样例文件哈希不匹配，未修改样例或判据。API34 全部 App Java 编译通过（使用既有资源生成的 R.java）；NDK r28b ARM64 ON/OFF 构建通过。本次未重新打包/安装 APK、未执行 MotionEvent 注入或真机验证，前述旧 APK 哈希不代表此修复。

### 本地接线候选（2026-10-24）

- 新增 native 实际 viewport→transport 测试：修订竞态取消、翻转、撤销、旧窗口终止与默认关闭。
- 托管 TouchHidState 实际状态机测试：稳定 ID、像素端点、Start/End/held、取消、16 槽完整替换、非法/重复输入。首次容器 SDK 因缺 ICU 失败；采用构建脚本既有 invariant 设置后通过，不作为机制失败或设备通过。
- 完整 NativeAOT/APK 构建、真机直接点击和全屏结果待本轮实际记录；不把状态机测试计作 MotionEvent→JNI→HID 端到端通过。

### Gesture 候选与实测边界（2026-10-24）

- 旧基线 9858d51b 的 554507b3eb6f 实验包在 2605EPN8EC 真机实际主菜单点击：TouchScreen Start/End 坐标 204,191 与显示区域换算一致，菜单未响应。这证明原始触屏写入，不证明 Gesture 消费。标题的 PRESS ANY BUTTON 不能作为菜单触摸测试。
- Gesture 主机测试执行实际 Ryujinx 写入器及共享内存：验证结构/偏移、Tap 历史、重复读取、源时间、长按/拖动、取消、多指明确不支持、相邻区域不变、默认 Gesture 区域不写。预热识别器加真实 ring 的 1024 次移动为 0 托管分配，仅属主机机制读数，不是 NativeAOT 真机读数。
- 9858d51b 候选 2b2e181806da 已完成 NativeAOT、assembleDebug、lintDebug、APK 和签名检查并安装；因手机锁屏及随后无线调试离线，尚未获得菜单点击结果。迁到 c6cfcc04 后保留上游 WSI 退休算法，重新构建和设备验证分别记录。
- 沉浸显示在前一候选真机截图中已隐藏系统栏、保留 16:9 及柱状留边；不代表通用宽屏、画面格或帧率验收。游戏 MARK、固定路线、帧率、功耗、GC、首局和 iPhone 指标仍未知。

- c6cfcc04 新基线候选 2f3540b1040d：离线容器 NativeAOT、assembleDebug、lintDebug、verify-apk 和签名检查通过（164.3 秒）。同基线实际 Gesture/HID 回归通过；原生视口/历史测试通过，默认关闭实现编译通过。Ryujinx 官方补丁入口生成 0231/0232/0233，树核对一致（227 个补丁）。手机旧端口拒绝连接，新包尚未部署或完成菜单响应复验，结果仍未知。

### 最新候选真机菜单响应（2026-10-24）

2605EPN8EC，c6cfcc04 加本地实验，APK 2f3540b1040d：同 APK 先用虚拟 A 进入实际菜单，再开启触屏并隐藏虚拟控件。直接点击 650,320，在真实 HID 写出 204,191 的 Touch→Tap→Complete，画面进入 1560 剧本选择；另一次 875,320 按住 180ms 后松开，写出 339,191 的 Touch→Tap→Complete，进入剧本说明页。40 条位置重复帧未丢失按下/松开边界。正常收局，日志记录优雅退出 0.127 秒，ADB 确认进程退出。上述结果更新前面的“待复验”；只证明这两处菜单输入，不代表玩法 MARK、所有手势或核心指标。私有局日志和截图不上传。已在 #199 评论6383877418 回报边界。

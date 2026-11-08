# Android 触屏与 Gesture 机制回归

在仓库要求的 .NET 10 SDK 环境中执行：

```sh
dotnet run --project android/core-link/runtime-tests/touch/Touch.Tests.csproj -c Release
```

使用生产 TouchHidState、TouchGestureState 和真实 Ryujinx GestureDevice、RingLifo、AtomicStorage；共享内存使用与运行时相同的字节 backing，不能创建超大 SharedMemory 值类型数组。

覆盖稳定手指 ID、触点边界、Start/End/held、取消、16 槽替换，以及 Gesture ABI 大小/偏移、持久 Tap 历史、重复读取不消费、源时间、Press/Pan、多指明确取消、相邻区域不变和默认 Gesture 区域不写。预热分配检查只衡量主机机制，不能替代 NativeAOT 真机稳态指标。

此测试不构造 Android MotionEvent，不验证 JNI、真实服务激活语义或游戏菜单响应，不计作游戏运行、帧率、功耗或完整列车验收。DoubleTap、Swipe、Pinch、Rotate 识别尚未实现。

# Game shell 窗口边界测试

需 Linux host、C/C++ 编译器、pthread 和 Vulkan-Headers（只读头文件，无需驱动）：

```sh
python3 android/core-link/runtime-tests/game-shell/run.py \
  --vulkan-include <包含vulkan/vulkan.h的目录> --out <仓库外输出目录>
```

直接编译生产 `window.cpp` 与 `wsi_lease.c`，验证 game 模式的 foreground/offer/update/take/release/revoke、引用归还以及诊断 Vulkan instance / Presenter 不被创建。另行进入 diagnostic 模式，确认测试 provider 能观测到 Vulkan 创建调用，防止“计数器从未接线”的假绿。

`fakes/android/` 只定义本测试需要的 ANativeWindow 引用/尺寸与日志接口；测试 cpp 提供 Vulkan instance 和 Presenter 边界。它不链接真实 Vulkan 驱动、不跑 Presenter/GPU/Android Surface，也不证明真实 GPU release ack。完整 WSI 并发/超时仍由现有 `wsi_lease_test` 及设备测试覆盖。

同一改动的 `android/tests/GameSessionTest.java` 已接入现有 `android/test.sh`，要求 JDK 17。它覆盖一次准入、前台/尺寸、准确 APK 字节哈希、持久目录和旧存档拒绝覆盖；只创建并清理测试自己拥有的合成临时目录。Mac 可沿用 `S2A_TEST_NO_NATIVE=1` 跑既有 Java/契约门禁，不能把该标志的结果当 native 测试已运行。

生产 lease 使用 Linux 的 `pthread_condattr_setclock`；runner 显式启用 POSIX 2008 声明，不用时钟 stub 代替同步机制。可以用 NDK sysroot 的 Vulkan 头文件，但 runner 只暴露 `vulkan/` 和可选的 `vk_video/`，不会用 NDK libc 头覆盖 host libc。

# APK 内存装载器测试

在 macOS ARM64 上执行：

```sh
python3 android/core-link/runtime-tests/apk-loader/run.py --out <仓库外输出目录>
```

直接编译当前生产 `loader.c`、Android `module.c` 与 `gate.c`。5 个成功/计红案例和 16 个拒绝案例，共 21 个独立进程，验证 authored 模块的 RELA/RELR、跨模块导入、弱导入、强导入缺失计红、门表、TARGET/ABI、输入租约归还后毒化/释放以及重复装载拒绝。所有模块字节由 fixture 构造，不含游戏代码，不执行客体指令。

macOS 上 `loader.c` 按 Android 分支编译，但编译器仍定义 `__APPLE__`；`host_android_compat.h` 补上 Apple 专用会话重置引用的桌面窗口游标占位（Android 路径不读），图形模式夹具按通用返回。

TSD 使用实际 Apple 平台实现；libc lookup、可选 widen 与不可到达的切栈端点是显式测试提供者。测试不证明 Bionic TSD、JNI 资产读取/签名、Android 真机运行或 GPU 正确。runner 强制当前 Mac ARM64 条件；不把换个平台编译成功当成 Android 通过。

日志、命令和输入 SHA 写到 `--out`，输出必须在仓库外。断言始终启用；生产拒绝分支必须实际 abort 并包含 FATAL，不能由 fixture 自报成功。

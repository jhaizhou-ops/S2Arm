# Android 原生会话日志

生产 `runtime_run` 一次准入后、首个 window/selfcheck/loader 调用前，调用同一 DSO 内 `os.c` 的 hidden 接缝。可信 `state_dir` 由实际 GameSession 创建；新局创建 `host-<session>-<pid>-XXXXXX.log`（0600、追加），保留旧局文件。绑定 stdout、stderr 和 constructor 保留的原生 fd；不改变原生 fd 编号，后续 StdErrAdapter 接管 stderr 不影响原生 LOG。部分描述符接线失败会恢复旧描述符并拒绝启动，文件创建失败也不会继续 loader。

```sh
python3 android/core-link/runtime-tests/session-log/run.py --out <独立输出目录>
```

真实 `runtime.c`、`os.c` 与共享 guest 入口参与编译；其余 core/服务端点复用顺序测试的合成夹具。四例：成功、目录不存在、第二次 dup2 失败回滚、非法请求无副作用。检查首个 core 消费点已可写日志、C stdout/stderr、直接 signal-safe write、stderr 被替换后 native LOG 仍可写、旧局不变、无 fd 泄漏。删除生产 sink 调用的变异必须失败。Linux GCC 对仓库既有 constructor(100) 发保留优先级警告，可显式传 `--cflag=-Wno-error=prio-ctor-dtor`；NDK/Clang 无需此项。

边界：不捕获绑定之前的 DSO constructor 日志；文件写入沿用已有同步 write，不声称整套 LOG formatter 信号安全。这里不是 Android 真机或 NativeAOT 验收。**已初始化的 .NET Console.Out/Error 会保留旧 fd 副本**，服务启动接点还必须重新打开并发布两个 managed writer；仅 native dup2 不能证明 managed 日志已接入。实际 Console 红例保存在本轮验收证据目录，不能以 C stderr 测试冒充。

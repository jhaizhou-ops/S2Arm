# 内存诊断线程生命周期

本测试直接编入生产 `MemDiag`、`S2AShutdown` 和 `S2AThreadAlloc`，使用实际线程、取消事件、GC 统计和 macOS `proc_pid_rusage`，不替换原生接口。每轮连续启动两次，确认旧线程真实退出；再请求关停并调用 `Stop`，确认 30 秒等待被唤醒、所有先前线程均已退出。连续执行 20 轮。

在仓库根目录使用官方 .NET SDK：

```sh
~/.dotnet/dotnet publish services/MemDiag.Lifecycle.Tests/MemDiag.Lifecycle.Tests.csproj \
  -c Release -r osx-arm64 -o build/memdiag-lifecycle
build/memdiag-lifecycle/MemDiag.Lifecycle.Tests
```

这是 NativeAOT 线程关停回归，不启动游戏，不验证 LibHac 缓存或 Metal 资源是否回收，也不触发强制 GC。

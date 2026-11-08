# Vulkan fence 返回值回归（纯 CPU）

直接编译生产 `FenceHelper.cs` 和 `VulkanException.cs`，经 Silk.NET 真实 dispatch 调用受控
`vkWaitForFences`。不加载 Vulkan 驱动，不创建 GPU、命令缓冲、内存跟踪或资源生命周期 fixture。
需要 .NET 10 SDK 和已缓存的 Silk.NET.Vulkan 2.23.0；缺依赖时报错，不联网下载。

```sh
dotnet restore graphics/vulkan/core/fence-tests/Fence.Results.Tests.csproj \
  --configfile graphics/vulkan/core/fence-tests/NuGet.Config
dotnet run --project graphics/vulkan/core/fence-tests/Fence.Results.Tests.csproj --no-restore
```

47 项检查覆盖 Any/All 的 Success、Timeout、正非成功码、三个负错误，原始 device/fence/count/
waitAll/timeout 转发、默认零超时，以及现有无限等待循环的 Timeout→Success / Timeout→DeviceLost。
旧生产源对 Any/All 的三个负错误各失败一次（共 6 失败）；修复后 47 项通过。

这只证明错误传播和调用参数合同。不能证明 GPU 完成、资源生命周期正确、实际驱动错误原因或游戏通过。
`WaitForAndFlushRanges` 的 CPU 写锁与池数组异常安全单独审查；此入口不测试该资源路径。

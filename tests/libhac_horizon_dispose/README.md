# LibHac Horizon 部分释放回归（P2-30）

运行：`bash tests/libhac_horizon_dispose_test.sh`。需要现有 .NET 10 SDK；NuGet 源为空，不下载依赖，构建产物在独立临时目录。

测试工程直接编入 `compat/tree/src/Ryujinx.HLE/HOS/LibHacHorizonManager.cs`，不复制 Dispose 算法。HostStubs 仅提供受控 LibHac/服务依赖，记录每个 Dispose / UnregisterService / SharedRef.Destroy 的调用并在指定步骤抛出同一个异常。期望顺序独立列在 Program.cs。

20 项场景：正常且重复释放；10 个实际释放步骤分别抛异常；5 个服务注销返回失败；两个释放步骤同时失败；仅初始化核心客户端时注销失败；警告日志关闭时注销失败；清理中重入 Dispose。断言剩余清理均尝试、调用顺序、字段所有权移出、后续 Dispose 不重放、注销结果失败仅记录服务名/数值结果且不抛；实际清理异常保留原异常与堆栈或按顺序聚合。

撤修负控：从基线导出原生产文件，给同一测试工程传 `-p:HorizonManagerSource=<原文件绝对路径>`，以独立 `--artifacts-path` restore/run。`f138104f2` 原实现 1/20 通过，修复后 20/20，恢复原源码仍 1/20。测试失败来自真实生产控制流，不是编译失败。

范围：Linux 宿主、真实生产类加受控依赖，不等于完整 LibHac/HLE 集成、Apple、设备、游戏或并发 Dispose 验收。Dispose 仍遵循单所有者生命周期；本片保证异常后的重复/同线程重入不重放已移出的所有权，不新增跨线程同步或初始化后再使用的契约。

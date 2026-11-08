# Buffer scratch CPU 回归（T117 / #894 分片）

从仓库根目录运行，无参数、无需预编 `Dependencies` DLL：

```sh
bash android/core-link/runtime-tests/buffer-scratch/run.sh
```

需要 .NET 10 SDK；通过 `DOTNET` 或 `PATH` 选择。入口使用清空源的临时
NuGet 配置和独立临时构建目录，不联网取包，失败非零退出。`android/test.sh`
直接调用此入口；不受 `S2A_TEST_NO_NATIVE` 跳过开关影响。

工程直接编译仓内生产 `S2ABufferReadScratch.cs` 和完整 `MemoryOwner.cs`，
不复制算法、不用替身池。`S2A_BUFFER_READ_SCRATCH=0/1` 各在新进程运行一次；
原有断言保持不变，覆盖嵌套租借隔离、陈旧/重复释放、池耗尽回退、超大请求、
异常后复用、零/负长度、跨线程拒绝及预热后 100000 次租借分配为零。
这里验证开关实际读值及同一池类的边界，不证明 GPU 消费者实际选用了该池。

本测试明确设置 `S2A_MO_NATIVE=0`、`S2A_ALLOC_TRACE=0`，验证生产的托管回退，
不依赖进程导出的 `s2a_tail_map` / `s2a_tail_unmap`，不模拟这些原生入口。
原生尾部映射、GPU/游戏正确性、NativeAOT、真机性能不在此 CPU 分片结论内。
编译可报告生产 MemoryManager finalizer 的 CA2015 警告；不压掉或当作已修复。

## 验证与负控

Linux x86_64 / .NET 10：原工程无外传 DLL 时编译报 CS0234 / CS0246，退出 1；
修后两种开关各通过，热租借分配各 0 B。保持生产代码不变，分别临时改坏
Program.cs 中嵌套数据、陈旧释放、负长度、线程拒绝、分配字节的一个断言，
实际 `android/test.sh` 五次均在对应断言退出 134；恢复后该分片通过。
这些负控仅为本一个工程的五处断言，不冒充本卡五个不同工程的修复。

macOS 应运行上面相同命令并贴读数，目前作者没有 Mac，尚未验证。
整卡要求的 Mac 和完整平台门禁不因本分片 Linux 通过而豁免。

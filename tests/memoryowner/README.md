# MemoryOwner 复用回归

使用 .NET 10 在仓库根运行全部回归（构建一次，每个用例在独立进程中运行）：

```sh
bash tests/memoryowner/test.sh
```

产物默认进入 `build/memoryowner`，可将其他产物目录作为脚本第一个参数传入。也可单独运行：

```sh
dotnet run --project tests/memoryowner/MemoryOwner.csproj -c Release
dotnet run --project tests/memoryowner/MemoryOwner.csproj -c Release -- bounds-byte
dotnet run --project tests/memoryowner/MemoryOwner.csproj -c Release -- bounds-ushort
dotnet run --project tests/memoryowner/MemoryOwner.csproj -c Release -- oversize
dotnet run --project tests/memoryowner/MemoryOwner.csproj -c Release -- accounting
dotnet run --project tests/memoryowner/MemoryOwner.csproj -c Release -- skip-accounting
```

测试直接编译树内的 `MemoryOwner.cs`，验证等长多块归还、跨线程归还、混合尺寸和跨尺寸复用、数据独立性、清零、复制、幂等释放及释放后访问。预热后的重复租借必须不再分配大数组；100 批固定负载检查实际存活堆和归还数组容量是否平台化。

各个带参数的用例应独立运行，避免同一个泛型池的历史内容影响边界断言。测试直接通过租借返回的 Memory 取得真实后备数组，用弱引用和完整 GC 观察归还后存活量，不反射池内部字段：

- `bounds-byte`：同时持有 200 块 1 MiB，再全部归还；存活后备不超过 64 MiB，同一精确长度不超过 32 份，并确认预算内的 32 份可保留。
- `bounds-ushort`：200 块、四种相邻长度，每块约 1 MiB；按实际 `array.Length × sizeof(ushort)` 计算，验证 64 MiB 上限没有误按元素数记账。
- `oversize`：byte 与 ushort 超过 64 MiB 的单块数组均可正常租借，两轮归还后都不被池保留。
- `accounting`：UInt32 的 16 块后备数组正好占满 64 MiB，反复租还 50 轮，检查 Get 扣账后仍可复用全部原数组，没有预算错账导致的大数组重分配。
- `skip-accounting`：真实租还使旧数组积累 SkipCount，再触发原淘汰；用释放后的余量补满 64 MiB，并确认额外新数组无法再进入池。

完整 GC 仅在独立测试进程中用于观察存活数组。缓存上限按每个 `T` 分别计算，只覆盖未租出后备数组的元素存储，不包含在用租借、数组头、Holder/List 元数据及引用元素指向的对象。每个精确数组长度最多保留 32 份，以覆盖已验证的 24 块同时在用负载；跨长度 1–4 倍搜索和原 SkipCount 淘汰保持不变。

可通过 `-p:MemoryOwnerSource=/绝对路径/MemoryOwner.cs` 对实际旧源码运行同一回归；未修复等长归还的版本应在默认用例的二次租借处失败，没有缓存上限的版本应在 `bounds-byte` / `bounds-ushort` 处失败。

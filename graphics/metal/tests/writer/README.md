# 图形关闭的缓存写盘排空回归

输入必须是真实、当前翻译器版本的缓存私有副本，含 `guest.*`、`shared.*` 和同源 `*_bin.*`。测试只读输入，输出目录必须不存在。按照生产 shbake 的方式读取真实客体代码、特化状态及宿主元数据，经正式 `BackgroundDiskCacheWriter` 将 16 条记录循环排入 2048 项工作；不编造缓存字段，不使用 mock。

```sh
~/.dotnet/dotnet build graphics/metal/tests/writer/Writer.csproj -c Release \
  --artifacts-path "$PWD/build/graphics-writer/art" \
  -p:OutDir="$PWD/build/graphics-writer/bin/"
~/.dotnet/dotnet build/graphics-writer/bin/S2A.GraphicsWriterTest.dll \
  '<真实缓存私有副本>' '<宿主文件前缀，例如 vulkan_nxgal_bin>' \
  "$PWD/build/graphics-writer/new-run"
```

CPU 模式执行合法的 shared/guest 写入路径，与生产离线烘焙一样不创建宿主程序。初始目标目录必须为 0 条记录、0 个文件；关闭前检查并打印真实待执行任务数，若已是空队列则本次失败。关闭返回后要求新目录恰有 2048 条记录，最后追加项的客体代码、常量段和特化状态逐字节等于输入记录，并验证文件可独占打开。另用真实文件共享冲突，检查生产 `NoAccess` 异常在工作线程退出后以 `IOException` 传播。

追加 `--with-host-binary` 会初始化真实 `NxRenderer` 和 `GpuContext`，把输入中的真实宿主二进制一起写盘并逐字节读回末项。此模式需要 Metal GPU；`NXGAL_LIB` 必须指向当前生产库，缓存/归档输出应指向本次隔离目录。该模式验证文件序列化与关闭排空，不验证宿主二进制能否在当前设备绘制，也不加载游戏或执行进程内重启。

2026-10-28，Apple M5 Pro / macOS 27.0（26A428），源码 `6b4c7f474`：真实 7360 运行时缓存私有副本的 CPU 模式一轮，初始 0 条记录、0 文件，关闭前待执行 2045 项，返回后 2048 条新记录，末项客体/常量段/特化字节一致；宿主二进制模式一轮待执行 2047 项，新增 2048 条，最后追加的真实宿主二进制与元数据也完整读回。两种模式的真实文件共享冲突均以生产 `NoAccess` → `IOException` 异常链传播。

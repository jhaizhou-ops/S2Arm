# 受保护纹理正常读取回归

> 合流说明（2026-10-28）：本页合并双方已有说明与原验证记录；相关源码冲突尚待解决，原记录不代表本次候选重新通过。进度见 [合并分析 §13](../../../docs/direct-main-merge-analysis-20261028.md)。

默认 Android 主机门禁从 `android/test.sh` 调用以下入口；它离线构建真实
GPU 程序集与生产 tracker/readonly_copy，输出全部放在仓库外。需要已缓存的 NuGet
依赖、.NET 10 和 C 编译器，支持 macOS（Mach alias 适配）与 Linux（生产 VM 适配）。

```sh
python3 android/core-link/runtime-tests/readonly-copy/texture_read_test.py
```

`neighbor/direct/partial` 必须经过实际完整/部分纹理消费者；只调用复制 helper 不能
发现消费者仍然裸读的问题。`lifecycle` 先完成可读源的稳态上传，再执行三轮后台/恢复
保护页消费者回放，每个阶段分别核完整与部分同步、源保护、邻居 dirty 和字节一致。
这是 CPU 读取轨迹，不模拟 Android Activity、真实 present、WSI 或资源退休。
`red/lifecycle-red` 撤掉平台提供者后必须在真实 LayoutConverter 源读取处产生 AV；
编译失败或缺 native 库不算负控通过。`borrowed-multi` 守住未配置平台的暂存池和空洞语义。

## 有界读权限检查

Android只读复制先调用 `s2a_mem_readable`，仅检查请求覆盖的范围，保留QueryMemory的
读权限判据；不改guest QueryMemory返回的完整连续区间，不使用仅判mapped的接口替代读权限。
`make native-test-svc_mem`覆盖权限0–7、堆尾、映射尾、模块RX/RO/RW与补丁Free段、TLR、
空洞/溢出、20000个随机读权限区间对拍，并要求64MiB内查8字节最多2次位图探测。
此测试的完整逻辑VM是生产svc_mem.c；本目录复制夹具的VM只描述它自己的测试映射。

冷启动 `--ez s2arm.bounded_readonly_check false` 使用旧完整QueryMemory检查；true（缺省）
使用有界检查。同APK对照之外不改变alias复制、页保护、dirty和GPU同步；第一次复制后
配置冻结，改值返回EBUSY。native_test的neighbor/legacy两模式核对相同字节、跨页、
空洞、溢出、重叠和源保护，private拒绝无共享backing；两模式均检查冻结合同。

直接编译生产 GPU 程序集，并链接生产 GuestMemory/Native/Red 源。唯一 renderer 是最终接收转换结果的记录器；不伪造 Texture、PhysicalMemory 或 LayoutConverter。使用生产程序集已有的 S2A.SpecTest friend，不改产品可见性。

本机 ARM64 .NET 夹具以真实 Mach VM 适配运行生产 readonly_copy.c；旧未注入路径在实际 Texture.SynchronizeFull→LayoutConverter 读保护页时 AV，新路径字节与普通可读参考完全相同。覆盖普通/直接上传、实际 TextureGroup 部分同步、多段/PTE空洞、错误GPU线程、溢出和查询失败，保持源权限、邻居dirty、无写回。fixture用独立内存和测试元数据，不包含游戏代码/资源。

真实 Linux ARM64 测试运行同一生产 readonly_copy.c + track.c + tracking/platform.c + plat_android.c，4 KiB 页、跨页读取和私有 backing 拒绝。逻辑 VM 查询是只描述夹具映射的明确端点，不冒充实际 guest 核心生命周期。该测试不能替代Android NativeAOT、真正GPU读回与游戏验收。

## 命令

```sh
dotnet build android/core-link/runtime-tests/readonly-copy/ReadonlyCopy.Tests.csproj --artifacts-path "$OUT/build" -p:RestoreConfigFile="$OFFLINE_NUGET_CONFIG"
clang -std=gnu11 -O2 -fPIC -dynamiclib -pthread -Iruntime/include android/core-link/runtime-tests/readonly-copy/native_fixture.c android/core-link/runtime-tests/readonly-copy/mac_vm_adapter.c android/native/runtime/tracking/readonly_copy.c graphics/track/track.c -o "$OUT/libreadonly_fixture.dylib"
python3 android/core-link/runtime-tests/readonly-copy/run-macos.py --out "$OUT"
```

run-macos.py 从 PATH 查找 dotnet，也可通过 --dotnet /path/to/dotnet 或 DOTNET 指定已安装 SDK，不安装环境。Linux ARM64 在只读源和独立输出目录执行：

```sh
python3 android/core-link/runtime-tests/readonly-copy/run-native.py --out /out/native-arm64
```

镜像 sha256:508ac584bc7a957c015935135f54af655da4aa47079521c961928d79a4aa0c38，使用 --platform linux/arm64 --pull never --network none。具体已执行命令、输出和SHA由任务证据目录保存。Linux-x64/Rosetta尝试在真正copy前就出现runtime AV，不能当alias结果，本入口不继续使用它。


## DMA 目标旧数据保留（默认启用）

DMA 布局转换前读取目标旧数据时，默认使用 `S2ACopyUntrackedForDma`，优先调用
平台 readonly-copy 提供者；没有平台提供者时使用 tracker 的 `S2AReadUntracked`。
两者均不可用、映射洞、错误线程或溢出时明确失败，不使用借用 span 伪成功。
仅主机诊断负控可设置 `S2A_DMA_BORROWED_READ=1` 选择旧借用读路径；该路径在
跟踪器保护页上可崩溃，不用于正常运行。

旧 Android 冷启动 Boolean extra `s2arm.experimental_dma_preserve_read=true` 保留为
对默认行为的确认；显式 false 不受支持并报错，运行中请求需冷启动。旧环境变量
`S2A_DMA_PRESERVE_READ` 已不再控制 DMA 路径。SME 信号实验是独立选项。

新增回归实际调用 `DmaClass.Write → LaunchDma → DmaCopy`；只记录最终写回输出，
不伪造 DMA、GPU VA 翻译或布局拷贝。旧路径必须在受保护旧数据源读发生 AV，
新路径必须保留 stride padding、按请求复制像素，且源权限和邻居 dirty 不变。
另覆盖未映射后缀（复制前拒绝）、地址溢出、错误 owner、缺提供者、空读和不连续映射。

合成 arena 改用 non-fixed mmap hint 并检查最终地址在生产 39-bit 契约内，
使 Linux/x64 的该数据拷贝夹具也可执行；它不代表 ARM64 信号、Android GPU 或 Apple 验收。
现有历史 ARM64/Mach 证据与上面记录的旧 Linux/x64 尝试保留原边界。

已单独完成 restore 与 build、并准备对应系统的 native fixture 后运行（不联网）：

```sh
python3 android/core-link/runtime-tests/readonly-copy/run-dma.py --dotnet "$DOTNET" --app "$OUT/build/bin/ReadonlyCopy.Tests/debug/S2A.SpecTest.dll" --library-dir "$OUT" --out "$OUT/dma-results"
```

## GPU 回写旧字节的安全读

`Texture` / `TextureGroup` 回写先把目标段旧字节拷进可写副本。目标页可能被写跟踪
设成 `PROT_NONE`（定向读时回写、GPU 改过），借页直读会缺页；多段回写原先把每一段
`GetSpan().CopyTo`，单段池在无读钩子时也直接 `CopyTo`。`writable-*` 用真实
`PROT_NONE` 页调用生产 `PhysicalMemory.GetWritableRegion`：

- `writable-copy` / `writable-single-copy`：只装平台只读拷贝提供者（Android），
  每段读一次提供者，旧字节与写回编辑逐字节核对。
- `writable-alias` / `writable-single-alias`：只装跟踪器无跟踪读（Apple / Android
  `NxTrack` 同一条），每段走共享只读别名，源页保持不可读。
- `writable-missing` / `writable-single-missing`：模拟安卓（`S2AWritebackRequireProvider`），
  两级提供者都没有时必须 `NotSupportedException`，不读、不借页、不写回。
- `writable-fallback` / `writable-single-fallback`：模拟其余平台（默认），两级提供者
  都没有时保留借页直读，只打印一次 `【红】GPU 回写没有无跟踪读提供者`，不改变苹果既有行为。
- `writable-red` / `writable-single-red`：`S2A_WRITEBACK_BORROWED_READ=1` 只供负控，
  强制旧借页直读；旧代码必须在 `PhysicalMemory.GetWritableRegion` 的 `CopyTo` 处 AV。

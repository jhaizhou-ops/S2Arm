# Rebind 宿主真实源码回归

离线编译完整 `Ryujinx.Graphics.Vulkan` 生产 C# 源与同程序集夹具，直接调用内部真实 `DescriptorSetUpdater.Rebind`，不复制被测算法，不创建 Vk、设备或 GPU 资源。`--vulkan-source` 指向包含原 `Ryujinx.Graphics.Vulkan.csproj` 的完整生产目录；该工程显式链接的 DeviceFeatureSnapshot / WSI 源也必须保留原相对布局，不能只拷两个待改文件。

夹具只在准备阶段跳过 updater / ShaderCollection 的 Vulkan 构造并用反射填真实字段；Auto、BitMap、BitMapStruct、Rebind 均用本轮生产实现。它验证消费已有有效绑定状态的语义和宿主 JIT 分配，不验证构造、引用计数/释放、线程并发、Vulkan 提交或画面。NativeAOT、Android、真实游戏、FPS、功耗分别验收；本入口不做 AOT 适配，不需要游戏、密钥、存档或设备。

## 运行

需要 Python 3.10+、已经安装的 .NET 10 SDK，以及现有离线依赖 DLL 目录。依赖目录应包含 Common、GAL、Shader、Spv.Generator、Silk.NET Core/Shaderc/Vulkan/EXT/KHR 和 Gommon 及其传递 DLL。这些依赖使用提供的冻结 DLL，不冒称本轮重编。旧 `Ryujinx.Graphics.Vulkan.dll` 明确排除，不作为受测实现。

```sh
python3 graphics/vulkan/runtime/rebind-tests/run.py \
  --dotnet /path/to/dotnet \
  --dependencies /path/to/existing/dependencies \
  --vulkan-source /path/to/repo/ryujinx/tree/src/Ryujinx.Graphics.Vulkan \
  --output /path/to/new/rebind-green
```

输出目录必须尚不存在，并与源码、夹具和依赖树分离；所有复制、变异、bin/obj 和日志只写该新目录。NuGet 源清空，无 PackageReference、restore/build 不下载依赖；缺 SDK 或 DLL 直接失败，不安装。每条 SDK/build/test 命令有默认 120 秒上限，可用 `--timeout-seconds` 调整。

Release / Optimize=true / DOTNET_TieredCompilation=0。同一 1468 项语义断言先通过，再分别暖身 30000 次、测量 100000 次：program 存在且空位图、uniform+storage 的 bit64 mirrored 重叠、program=null。三个路径都必须为 0 B 才退出 0；计量循环没有反射、测试对象或委托创建。mirrored 位保持，暖身清 set 后仍执行真实匹配与失效逻辑。

语义断言包括 set/mirrored 并集与重复位、两绑定表、0/1/63/64/各表末位、同/异 buffer、重叠与两侧相邻端点、dirty 分类、uniform PD 清零及 storage 不改 PD、null program、真实 Union 快照顺序 0/63/64/127 和回调清原位图后的继续遍历。

## 旧源反证与负控

`--legacy-listener` 只切换夹具调用旧 Action 签名的方式；传入保留完整布局的旧生产源码，生产源完全不改写。1468 断言、暖身及测量不变，三个路径都必须实测到正分配；预期测试与运行器均退出 **1**。具体字节数由 SDK/JIT 决定，不写死先前某台主机的 168/40 B。

```sh
python3 graphics/vulkan/runtime/rebind-tests/run.py \
  --dotnet /path/to/dotnet --dependencies /path/to/existing/dependencies \
  --vulkan-source /path/to/old-repo/ryujinx/tree/src/Ryujinx.Graphics.Vulkan \
  --output /path/to/new/rebind-legacy-red --legacy-listener
```

`--negative-control` 与 legacy 模式互斥，只改输出目录里的候选源码副本；每次选择一个并使用新输出目录，预期测试与运行器均退出 **2**：

| 选项 | 变异 | 必须击中的断言 |
|---|---|---|
| `first-word` | SignalSet 只扫首 word | set/overlap semantics |
| `inclusive-endpoint` | 把相交端点改为包含 | set/overlap semantics |
| `omit-union` | uniform 仅扫 mirrored | set/overlap semantics |
| `clear-mirror` | uniform 额外清 mirrored | mirrored bitmap must not be cleared |

负控在真实源码边界变化时拒绝替换；编译失败、超时、准备错误或未命中指定断言时运行器退出 **3**，不能冒充预期语义红。`results.json.expectation_matched` 单列是否命中预期，命令原始 rc 另存；运行器保留预期红的 1/2 退出码，不把负控红当产品绿。

## 证据

- `input-sha256.json`：全部真实源、工程、夹具/运行器、dotnet 与冻结依赖身份；`compiled-source-sha256.json`：实际编译副本（含显式变异）身份。
- `results.json`：完整命令、各阶段真实 rc/超时、三个分配结果、断言数、runtime/架构、预期与命中情况；SDK/build/test 的 stdout/stderr 分开保留。
- `output-sha256.json`：本轮所有输出的 SHA（自身除外），包括受测程序集、日志和结果。不会序列化继承环境中的凭据。

这些文件记录一次宿主运行的实际结果；新增或调整入口后必须重新执行，不能把旧私有证明视作本入口已验证。

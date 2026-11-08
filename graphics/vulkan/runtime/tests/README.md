# Vulkan CPU 宿主回归（T116）

在仓库根运行 `bash tests/vulkan_backend_test.sh`：11 个工程，任一失败则入口失败。
要求已安装微软 .NET 10 SDK、C 编译器、SPIRV-Tools（`spirv-as` / `spirv-val`），并事先还原真实生产项目的锁定 NuGet 依赖。入口清空包源，不下载依赖；缺项报错而不是跳过。使用 `TMPDIR` 指定有足够空间的临时产物目录；同次构建共用依赖输出，结束删除自己的临时目录。

新增的五工程都可直接 `dotnet run -c Release --project <工程路径>`，无应用参数：

- `cache/tests/CodecTests.csproj`：构建时组装并校验同目录原创 SPIR-V 文本夹具；无参数读取输出目录内夹具。保留显式夹具目录及 metadata-only 调用。真实 codec、GAL 定义与独立 metadata 边界断言不变。
- `runtime/control-tests/Control.Tests.csproj`：默认 ProjectReference 构建真实 GPU、Vulkan 与 Services；保留旧 `GpuAssembly` / `Dependencies` / `RuntimeSource` 隔离复现入口。构建本目录现有 `backing_test.c`；生产运行循环、FIFO、内存跟踪真实执行，外壳 / GPU dispatch / VM 查询仍是原有受控边界，不是真机证据。Darwin 条件时钟 shim 的限制见原有 README。
- `runtime/varying-tests/Varying.Tests.csproj`：无快照时直接关联当前生产翻译器及现行 profile 类型、真实 Common / SPIR-V generator；旧 `run.py` 冻结源码模式仍保留。无参数使用一次性结果目录并清理；显式路径保留输出。
- `runtime/tests/Runtime.Tests.csproj`：真实设备 feature 请求及 shader-pack 挂载 / 翻译器。旧 rc=134 来自 `ShaderPackFallbackChecks` 的“缺资产不能报红”断言：宿主没有 Android native 库，实际得到 DllNotFound 红行，并非 ENOENT。新增原创 `asset_fixture.c` **只控制 Android asset API 边界**，依次返回 -2、-5、0，分别要求缺包 fallback、原始错误报红、空包报红；不降低生产异常等级，不声称运行 Android asset manager。现行 decoder/translator 仍实际生成 SPIR-V。
- `wsi/tests/WsiTests.csproj`：构建现有 `lease_fixture.c` 的 LAYOUT_ONLY 分支取得真实 C 头 ABI，默认无参数对拍受管布局并执行 ledger / function-table 用例。无参数明确输出 real-native-lease NOT RUN。Linux pthread 原生产实现另用 `python3 graphics/vulkan/wsi/tests/run.py --require-native`；原显式 ABI / native library 参数入口保留。

这些结果均为 **CPU 宿主单测**，不是 Vulkan 驱动、GPU 出图、安装、Android/iPhone、游戏、性能或 macOS 实测。设备 / GPU 入口保持在各模块既有 README 和显式运行器中，没有伪造宿主能力。macOS 验收须在最终同一提交补跑上述 11 工程命令。

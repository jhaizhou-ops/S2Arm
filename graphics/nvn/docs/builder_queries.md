# NVN Builder 查询（#270 A 组）

基线 `5847b57b`。本次补充 45 个 Builder 查询，涵盖 Device、MemoryPool、Buffer、Event、Queue、Window、Sampler、Texture。A 组原有 47 个缺入口；两个整数边框色 setter 仍未实现，不能把本次查询补全写成 A 组全部完成。

## 契约依据

本地 `include/nvn.h` 来自 Darksiders II 的 DWARF 重建，部分声明不完整或错误。以下差异另外核对了自有游戏的真实 SDK 函数表及实现；没有执行 SDK 或上传游戏文件。

| 样本 | SDK SHA-256 | 核对内容 |
|---|---|---|
| 怪物猎人：崛起 16.0.2 | `1c9f198a91c0bcfee5cf8f5b53fb941895e91334dfb766ce79fc68576797f017` | 默认值、字段查询、输出指针、稀疏页形状 |
| 超级马力欧兄弟 惊奇 1.2.1 | `73bec5989030d4d9f056503066180a6100bb7937370a4d818c8ba53960dfa2f3` | 较新的 `TextureBuilderGetViewOffset` |

关键差异：

- `MemoryPoolBuilderGetMemory` 返回指针，`BufferBuilderGetMemoryPool` 和 `TextureBuilderGetMemoryPool` 返回池指针。原头文件分别误声明为 `void` 和结构体按值返回。修正源头后使用既有 `gen_protos.py` 重生签名检查表。
- Queue 的四个 `Get*MemorySize` / `GetCommandFlushThreshold` 入口是 `NVNboolean(builder, int *out)`。无显式设置时也写出 0 并返回 false；显式设置为 0 时返回 true。与计算宿主分配需求的 `GetQueueMemorySize` 不同。SDK 入口分别为 `0x471590`、`0x4715a0`、`0x4715b0`、`0x4715c0`。
- `QueueBuilderGetMemorySize` 返回 32 位值；`GetMemory` 返回指针。Queue 的内部容量字段按 SDK 的 32 位存储记录，四个显式设置标志单独保留。
- `EventBuilderGetStorage` 还会向第二参数写出 64 位 offset，然后返回池指针（`0x46bd90`）。
- `TextureBuilderGetPackagedTextureLayout` 只写输出首 4 字节，返回是否设置过布局；有效数据为三个低半字节，后 4 字节是保留空间，不覆盖（`0x4754c0`）。
- `NVNtextureSparseTileLayout` 实际为 4 个 32 位字段，原头文件的 `dummy[1]` 不足以容纳输出。顺序为平铺 mip 数、页宽、页高、页深。
- 三种 `GetBorderColor` 都原样复制同一组 16 字节，不做整数与浮点数值转换。`GetLodSnap` 读回此前设置的浮点值，不做量化。

## 缺省值与状态

所有带 Device 的 Builder 调用 `SetDefaults` 均保留此前的 Device。修正 Pool 清除 Device 的行为，并按 SDK 修正这些缺省值：

| Builder | 缺省状态 |
|---|---|
| MemoryPool | memory=NULL、size=0、flags=`CPU_NO_ACCESS \| GPU_CACHED`（0x21） |
| Texture | target=2D、width/height/depth=0、levels=1、RGBA 恒等 swizzle |
| Sampler | min/mag=LINEAR、wrap=REPEAT、LOD=[0,1000]、compare=NONE/LESS、anisotropy=1，其余为 0 |
| Queue | 四个容量/阈值为 0 且未显式设置、memory=NULL、flags=0、priority=100 |
| Window | texture count=0、active texture count=0、native=NULL、present interval=1 |

已有 `SetQueuePriority`、`SetNumActiveTextures` 和 `SetLodSnap` 补充记录状态，查询返回记录值。此处不改变宿主队列调度、交换链轮转或 Metal 的 LOD 优化。`SamplerCompare` 同步比较 LOD snap，避免把不同状态视为相同对象。

## 纹理计算查询

`GetRawStorageClass` 由 flags 和 format 决定。线性标志 0x50 任一位有效时为 1；否则 NONE 为 0，STENCIL8/DEPTH16 为 3，DEPTH24/DEPTH24_STENCIL8 为 4，DEPTH32F_STENCIL8 为 5，其余为 2。依据 `0x4757c0` 及其格式分支表，不返回固定 class。

`GetSparseTileLayout` 的 64 KiB 页形状按像素块大小、维数、采样数计算，再转换为 texel 数。从 mip 0 开始比较各维度，首个不足一页的 mip 进入尾部；若没有可平铺 mip，四个字段全为 0。1D、1D_ARRAY、BUFFER、12 字节像素块和不符合稀疏标志的状态同样返回全 0。依据布局构造 `0x45b380` 与查询算法 `0x45b5b8`。该 API 查询不改变已有纹理存储布局算法。

`GetViewOffset(builder, view)` 复用 `nvn_tex_layout`，计算层前缀和 mip 前缀的存储大小。数组层和 cubemap-array 视图的层单位按 SDK 分支处理，已计入层前缀时再把 mip 前缀转换为单层。依据惊奇 SDK `0x45bb40`；默认 view 返回 0。GL 互操作仍属于 H 组，GL setter 未实现。纹理存储大小的正确性继续依赖现有布局算法，本次没有重新证明所有格式的 GPU 字节布局。

## 验证与剩余项

`graphics/nvn/tests/t_nvn_a.c` 经生产 `h_nvnBootstrapLoader`、`swnvn` 注册表和计数跳板调用真实 API，覆盖默认值、Set/Get 往返、SetDefaults 复位、Device 保留、输出宽度和对象边界。期望值由上述 SDK 契约与页尺寸手算，不由被测布局函数生成。测试链接真实 NVN、原生宿主和 Widen NativeAOT 库，没有测试替身。

Apple Silicon Mac 实跑 58 个查询及 SamplerCompare，共 360 条断言通过。45 个新增查询各有反证：临时把标量/指针查询改成返回 0/NULL，把多输出查询改成写 0（Compare 改成 NONE/NEVER），逐函数过滤运行；45/45 均由该函数的断言报错、退出 1。测试输入、生产注册、签名检查和依赖链接不变，反证完成后恢复生产实现并重跑全组。

运行：

```sh
make native-test-nvn_a
make native-test-nvn_a NVN_A_TEST_QUERY=nvnQueueBuilderGetCommandMemorySize
```

测试依赖 Apple Silicon Mac、Xcode 和 .NET NativeAOT 本机链接依赖；工具链覆盖沿用 `S2A_DEVELOPER_DIR`，本机库搜索沿用 `LIBRARY_PATH`。

### Mac 直连运行记录（2026-10-25）

宿主提交 `fbb9b7a2`，Apple M5 Pro / 48 GiB / macOS 27.0（26A428）。自有《节奏天国》1.0.0，程序号 `0100D9F01D474000`，main BUILD_ID `03ff4a3bec96bde3a2e37ce3aa4caa0c`。直连库按本分支工具链重建，链号 `c407c4b309b7`，35/35 成功、缺失 0；未复用旧链库。

两局均经 `runtime/run_mac.sh rhythm <私有局目录> 280` 启动，`S2A_CS=1 S2A_DUAL=1 S2A_GFX=direct S2A_AUTOPLAY=1 S2A_AP_NAVSHOT=1`。游戏原件只读，Ryujinx 数据、文档、现编及 PSO 输出均指定到各局私有目录；离线库与完整游戏数据分开存放。两局日志均明确为直连，未见退回通用；这是本分支显式直连的开发验证，未验证 main 缺省一键出包。

| 局 | 初始数据 | 首帧总耗时 | 上屏帧数 | 人工核对的画面 | 收局结果 |
|---|---|---:|---:|---|---|
| `rhythm-run-1` | 新用户；调用方误设不存在的 `S2A_SAVE_DIR` | 3074.8 ms | 16697 | 中文初次说明、朗读设置、开始菜单 | 到时正常退出 0；显示服务 2103 共 8 次、存档目录错误 1 次 |
| `rhythm-run-2` | 真实 iPad 备份的完整 Ryujinx 根，克隆后逐文件一致；不设 `S2A_SAVE_DIR` | 1434.5 ms | 16716 | 节奏演示、结算文本、咖啡店所在的选项页 | 到时正常退出 0；显示服务 2103 共 13 次；无存档目录错误 |

两局直连现编汇总均为成功 0、失败 0、跳过 0、复用上局 0；日志未见 NVN `[RED]`、未实现函数或 `CRASH`。服务层仍报告 `IApplicationDisplayService` 命令 2103 未实现及原有占位服务，不能写成零红。没有同条件旧提交对照，不能把该服务缺口归因于本 PR。

两局均无 `S2A 标记 MARK`。自动玩家的视觉否决步骤因本地服务凭据缺失而失败；第二局的另一视觉导航步骤曾成功给出按键，之后又超时。人工查看截图只能确认这些页面确实渲染，不能替代完整玩法、声音、九款金样或与通用模式同场景对照。两局初始存档不同且开启截图，不作为性能 A/B；首帧差异不表示优化收益。这份运行记录也不能证明 45 个新增查询都被游戏调用，其契约证据仍来自前述真实 API 断言。

原始证据保留在本地 `build/nvn-runtime/rhythm-run-{1,2}/`，包括 `host.log`、`frames.tsv`、`shots/`、`vision/`；游戏、存档和二进制不入仓库。`host.log` 的 SHA-256 分别为 `b96a5e7310918827927d2131a61d3e181d1faeff2cf77f9b2262dd5e4847db1a`、`b4bdaa2205fbad7921f5a023d1a72f6592f09b52875bbaa471c7b4e7e8d12c7c`。

未完成项：

- `SamplerBuilderSetBorderColori/ui` 仍走未实现失败路径。真实 SDK 三种 setter 不记录数值类型；现有 Metal 路径按 float 阈值选择三种固定边框色，把整数 1 的位模式误作接近 0 的 float。仅存入整数或增加“最后一个 setter 类型”都不能证明采样正确，需连同纹理类型和边框采样语义实现。
- 已有上述两局 Mac 运行记录，但尚无完整玩法或真机验证；九款金样、默认值修正的同场景画面回归、稀疏布局与视图的 GPU 行为尚未验证。
- 稀疏查询和已有存储布局不是同一算法。例如 ASTC 6×6、768² 的 SDK 查询页形状为 384×384 texel，而已有存储布局可能按自动 block height 使用 192×768 的块形状。本轮只验证查询输出；两者在上传、去平铺与稀疏映射中的兼容性仍需真实纹理和游戏验证。

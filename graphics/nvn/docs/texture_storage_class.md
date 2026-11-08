# Texture 原始存储类别查询（#270 B 组纠错）

基线为 #299 `7e2f2a841`。`nvnTextureGetRawStorageClass` 已有生产入口，但使用无签名检查的 `NVN_NOPROTO`，固定返回 1；它不是新增函数。线性纹理的类别才是 1，普通块线性纹理和深度 / 模板纹理须按对象保存的格式区分。

## 静态契约

两份自有 SDK 的函数表、真实指令及格式分支表通过既有 `audit_nvn_sdk.py`、`nso_syms`、`loader_census` 和 Capstone 只读核对，没有执行 SDK 或上传二进制：

| 样本 | SDK SHA-256 | getter | 格式分支表 / 跳转基址 |
|---|---|---|---|
| 怪猎崛起 16.0.2 | `1c9f198a91c0bcfee5cf8f5b53fb941895e91334dfb766ce79fc68576797f017` | `0x477590` | `0xabf113` / `0x4775cc` |
| 超级马力欧兄弟 惊奇 1.2.1 | `73bec5989030d4d9f056503066180a6100bb7937370a4d818c8ba53960dfa2f3` | `0x45df50` | `0xb421c5` / `0x45df94` |

怪猎从对象 `+0x20` 读取 flags、`+0x38` 读取 format；惊奇从 `+0x28` / `+0x2c` 的打包字段提取这两个值。二者都先检查 flags 的 `0x50` 位，否则按 format 分支，以 `w0` 返回 32 位标量。只有一个对象指针参数，无输出参数。存储偏移只作为静态契约依据，生产实现使用自己的 `tex_t.d`，不依赖 SDK 布局。

| 保存的状态 | 类别 |
|---|---|
| `LINEAR`（0x10）或 `LINEAR_RENDER_TARGET`（0x40） | 1 |
| `NONE` | 0 |
| `STENCIL8`、`DEPTH16` | 3 |
| `DEPTH24`、`DEPTH24_STENCIL8` | 4 |
| `DEPTH32F_STENCIL8` | 5 |
| 其余格式，包括 `DEPTH32F` | 2 |

这是原始存储类别，不是 `nvnTextureGetStorageClass`。保留已有 Builder 查询的算法，抽成共用的 `texture_raw_storage_class(const nvn_texdesc *)`，对象查询读取 `TextureInitialize` 从 Builder 复制的完整描述符。后续修改 Builder 不改变已初始化对象。查询不改变布局、对象或 GPU 状态。

补入源头 `uint32_t (*PFNNVNTEXTUREGETRAWSTORAGECLASSPROC)(const NVNtexture*)`，再用现有 `translator/gen_protos.py` 生成签名表，结果为 504 个原型 / 536 个名字、32 个缺原型、签名红项 0；跳板及名字表内容不变。两种入口都使用正式 `NVN`，沿用完整生产 bootstrap、注册节和计数跳板。

## 实际验证

Apple M5 Pro / macOS 27.0，Xcode 27.1、官方 .NET 10.0.402。运行 `make native-test-nvn_a native-test-nvn_texture_storage_class`，共用 #299 的宿主对象、NVN 静态库和 Widen NativeAOT；成功日志中 NVN 子构建、`dotnet publish` 各调用一次。

- A 组既有 360 条真实 API 断言通过；新组 1077 条通过，测试进程均退出 0。
- 新组真实创建 Device / MemoryPool / Texture，池使用实际分配并按公开存储大小、对齐要求准备的内存。完整生命周期包含 Finalize、重建、多对象交错；检查查询前后 Builder / Pool / Texture 完整内容不变及外围哨兵。
- 块线性矩阵为 R8、RGBA8、RGBA16F、RGBA8_SRGB、DXT1、STENCIL8、DEPTH16、DEPTH24、DEPTH24_STENCIL8、DEPTH32F_STENCIL8、DEPTH32F，另有 RGBA8 + IMAGE。LINEAR / LINEAR_RENDER_TARGET 两例仅使用合法的 64×32、单层级 2D RGBA8、stride=256；没有把深度 / 模板格式与线性标志作笛卡尔积。
- 期望类别直接按上表手写；Builder 查询只作补充检查。每个已初始化对象在 Builder 改为另一合法格式后仍返回原类别；重新初始化才读取新状态。NONE 由既有 A 组 Builder 用例覆盖，没有创建 NONE Texture 来扩充断言。
- 将生产 `hle_nvn.c` 完整恢复为 `7e2f2a841` 的字节内容，再重编、链接同一真实测试：在第一项 R8 对象查询得到旧常量 1、期望 2，测试进程实际退出 1。随后恢复本实现，重新构建 A + 新组并通过上述完整矩阵。反证没有替换 bootstrap、对象、内存池或被测函数的依赖。

已同步主线 `b475a624` 正式分类器，文件逐字节相同。维护方命令 `python3 graphics/nvn/tools/nvn_func_table.py | awk -F'\t' '{c[$2]++} END{for(k in c) print k,c[k]}'` 实测已实现441 / 部分3 / 空操作14 / 未实现78，`--md`输出保存在 `build/storage-class/coverage-official.md`。同一正式分类函数直接读取干净 `7e2f2a84` 工作树的源码，也为441/3/14/78。原旧工具434/3/14/85 → 435/3/14/84只是漏计宏的差别。生产注册前后均为444个语义入口+14个空操作，其余78项仍走报红，没有新增入口；正式工具为主线原版，没有另写分类规则。

本地证据在 `build/storage-class/`：`sdk-audit.{json,log}`、`generator.log`、`baseline-source.sha256`、`baseline-artifacts.sha256`、`baseline-{build,test}.log`、`final-joint.log`。定向联合构建时的源码 / 产物快照为 `final-artifacts.sha256`；完整自检会重链测试程序和 Widen，其后产物另记 `contrib-artifacts.sha256`，不混用两次二进制哈希。

完整自检对应代码提交 `dd667a51a`、基线 `7e2f2a841`，实际 5/5 绿、63 秒；原生层 38/38 组、iOS 全量编译与链接通过，输入为既有真实惊奇改写产物的私有克隆。摘要为 `build/contrib_check/summary.md`，原始记录 `build/storage-class/contrib.log`；之后仅补本文的签名和证据说明，源码 / 测试未变。环境体检记录为 `doctor.log`。

测试初始化了真实 Metal 设备和池，没有提交渲染或拷贝命令、启动游戏或安装设备。原有无 main.npdm、未预留游戏窗口、程序号 0 无逐款参数表的宿主诊断保留。没有九款金样、游戏调用、画面或性能的新证据；旧注释中未知款的 main 地址不作为本次调用依据。

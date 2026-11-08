# 直连（NVN→Vulkan）能力矩阵与补齐计划

**宗旨：发现靠撞（省时间）、修复按族（省迭代）、排序按“离进世界还有多远”（省力气）。**

## 0. 阅读口径与基线（2026-11-06）

本次源码基线为 `android/direct-totk-world@c23b7beba`，包含 `a5b22baa1` 合入的
`main@54bd6e129`。本表维护能力、证据范围和真实缺口；**当前游戏进度、阻塞与下一交付只在
[统一方案 §11.0](fast-generic-v3.md#android-totk-current)维护**，交接给 dsh 时两处一起读。
下文旧批次记录保留当时的包号和读数，不作为当前排期。

状态含义：**✅ 指定范围通过；部分 = 已接生产但仍有组合缺失或正确性待验；⬜ 未实现；➖ 不适用**。
L/S/A/X 见 §4；代码存在、某条红消失、出现 draw/present 日志、看到画面分别记证据，不能互相代替。
“TOTK 未命中”仅指已有观察窗没见到，不能推出游戏后续不用；静态函数读取点也不等于实际执行。
本轮真实样本是《王国之泪》；其它塞尔达游戏的 iOS 坑用于提示相同契约的风险，不记作 Android 已验。

已提交能力的来源索引：

| 来源 | 可复用成果 | 仍须保留的边界 |
|---|---|---|
| `300a806c0` | CPU 声明写范围决定内容归属；哈希只减少上传 | 局部更新的格式/资源范围、在途版本化仍有限制 |
| `2ba323720` | 3D 切片、2D 数组层、mip≠0 的单子资源反馈快照 | 多层/cube/完整 3D 反馈与多 mip LOD 未闭环 |
| `373336884` | 压缩块与等字节数像素影子之间经 buffer 往返 | 仅覆盖匹配的块编码视图；不是任意压缩附件支持 |
| `72aac1147`、`990daa950` | 图形可写 SSBO、驱动 c0、零附件绘制、绑定上限及测试入口 | 影子回写顺序、混合重叠、零附件完整状态组合待验 |
| `810f70a2b` | compute c0/c1、UBO 表别名、零长度范围查询、条件渲染回放 | 未知读集填充、截断及未知条件处理仍是待验范围 |
| main `87f493a40`、`7afe4bfa1`，经 `a5b22baa1` 合入 | c0 分析按 set/binding 区分；UBO_ADDRESS 裸指针解析 | 1 MiB 限长不等于真实分配长度；生产链回归须跟随实现 |
| `1dd14e746` | 同一 dispatch 的无界 storage 共享并集影子 | 不覆盖所有有界/无界别名、跨 dispatch/draw/CPU 一致性 |

### 0.0 从游戏撞点提炼能力族

| 已遇现象 | 应修的通用能力族 | 同一族一并覆盖的相邻变体 |
|---|---|---|
| Deferred 句柄读错、常量掩码截断、指令流偏移错 | 命令录制 → 消费点快照 → 编译事实 → 绑定的一致性 | 即时/延迟绑定、解绑、同址重建、程序代际、高位 cbuf、缺事实反例 |
| `layer 1 outside 0..0` | 纹理子资源与视图寻址 | 已支持类型内的 mip、数组层、3D 深度切片、边界；cube/多层整视图另记未实现 |
| BC4 LUT 不能直接当颜色附件 | 格式重解释与块数据搬运 | 8/16 字节块、边缘 mip、选定切片、往返字节、格式不兼容拒绝 |
| 可写 SSBO/c0/零附件/第 17 条绑定依次被拒 | 带 shader 副作用的绘制与真实资源布局 | 无颜色但有深度、无全部附件、scissor/query、只读别名、超限拒绝 |
| storage 有地址但 `size=0`，多个窗口重叠 | 缓冲地址来源、范围、别名与 CPU/GPU 内容归属 | NVN/UBO_PTR/UBO_ADDRESS、边界/截断、包含与部分重叠、GPU 后续读、CPU 并发写 |
| 条件清屏未生效 | 条件渲染与报告的可见顺序 | 已知真/假、时间戳/遮挡报告、未完成/跨提交报告、draw/clear 的条件范围 |
| barrier 前 batch-fence 表满、随后 guest SIGABRT | 提交/完成/退休；崩溃所属模块与调用链 | 完成前保留、完成后回收、预算耗尽、Stop；先用证据区分图形与原生运行时根因 |

### 0.1 每轮交付：撞到一处，补齐一个有边界的族

1. 用真实游戏固定触发点：APK/资源身份、实际诊断开关、PID、第一条失败或首个错值、截图/操作步骤。
   无红的黑屏、错图、卡住、异常退出也算撞点；不只查 `red.log`。
2. 沿 producer → 快照 → 编译器 → Vulkan → 完成回写找第一处偏离，先查 main 是否已有同语义实现。
   游戏提供触发样本，修复落在通用契约；不加入标题判断、游戏地址或单款成功答案。
3. 先钉住独立期望，再修同一寻址/所有权/状态算法下的相邻变体与失败路径。一个族以能独立验收的
   合同为界；为修 3D 切片而实现 MSAA、为修缓冲而铺开 storage image 都不算本轮必要范围。
4. 给出修前红 → 修后绿 → 撤关键修复再红；分别登记 L/S/A 覆盖，缺的等级如实留空。
   解析器接受 175 项输入不证明 GPU 地址解析、同步与回写正确。
5. 复跑同一路线到下一检查点，把新撞点交回统一方案排序。约 15 分钟作一次排查复盘，
   **观察窗必须覆盖触发点**；110 秒未运行到 compute 的实验不能排除 compute 问题。

出包沿用干净提交和独立构建目录、同签名覆盖与资源增量刷新；保留导入数据和存档。
`compute_skip` / `compute_no_writeback` / 关闭条件渲染等开关只作单变量归属实验，不能计正常通过。
设备/出包按既有队列协调；当前活动工作树与文件归属以现场状态为准，不固定旧角色分工。

<details>
<summary>2026-11-06 各族的历史实现与阶段证据（旧“下一步”已由统一方案 §11.0 取代）</summary>

### 阶段记录（第一优先，2026-11-06）：内容归属正确性（批 A'）

**当时为什么排第一**：内容归属已出现两个错图反例，先修这两个已证缺陷；反例与读数见下。

**已做的第一步（修前先红）**：在 lavapipe 上用**修前生产代码**复现两个反例，⑨ 与 ⑩ 均按预期失败
（`⑨draw: first mismatch at (0,0) got=255,0,0,255 want=0,0,0,255`；
`⑩draw: first mismatch at (32,32) got=0,0,0,255 want=255,0,0,255`），计数探针显示 ⑨ 一次同步都没发生
（patches=full=0）、⑩ 走了一次整 GOB 合并。

**修法（语义结构，不是调参）**：
- **把「哈希 = 变化提示」与「内容归属」彻底分开**。CPU 写相同数值也算写：声明写范围覆盖的字节一律以 guest 为准。
- **GOB 只是上传粒度，不是覆盖粒度**。合并按 16 B piece 精确到纹素矩形，未声明字节保持图像内容。
- **写入范围进账本**：`nvnMemoryPoolFlushMappedRange`（地址+长度）与 `WriteTexels`（level/layer/区域）是生产调用点，
  范围经 Android 弱钩子进 `nvn_vk_texcache`；无范围的写通知（脏页轮询/外部写）降级为 hint，**解释不了且图像含 GPU 内容时 fail-closed**。

**验收**：反例⑨⑩修前红 → 修后绿；派生⑪（相邻局部写）⑫（多级 mip 局部合并）⑬（同值不同传）
⑭（无范围 hint + GPU 内容 fail-closed）⑮（GPU 写晚于已发布 CPU 写 → GPU 胜出）⑯（在途局部写 fail-closed）
⑰（未按块对齐的声明范围 fail-closed）全绿；5 项变异各自变红（M1→⑨，M2→⑩⑪⑫，M3→⑮，M4→⑫，M5→⑭⑦）。证据：lavapipe S 级 + Adreno 730 A 级。

### 阶段记录（第一优先，2026-11-06）：反馈采样快照（批 A''）

**为什么排第二**：TOTK 进世界卡在 `feedback snapshot: layer 1 outside 0..0`——3D 纹理的 cview 层号是**深度切片**，
旧计划按 arrayLayers（3D 恒为 1）判越界，把合法切片视图当错。

**已修（语义与 Metal 参考对齐）**：
- 源子资源计划接受 3D 深度切片（越界原因点名 depth slice，不再说 layer）；
- 拷贝区域由生产 helper 生成：3D 用 `srcOffset.z` 选切片、`layerCount=1`（Vulkan 3D 子资源不能按 array layer 选）；
  2D/数组用 `baseArrayLayer`；extent 取 pass 与快照的交集；
- 绑定替换改为纯决策：**只有“采样视图正好是附件那个子资源、且是单级单层 2D”才换快照**；
  同图其它 mip/层/切片不是反馈（不换、不报）；默认 3D 视图 / 多层视图 / 带格式·通道·深度模板重写
  保持原绑定并记一次原因（与 `nvn_mtl.m` ④「3D 报告一次、保持原样」同口径，不静默换错）。

**验收**：L 级计划/拷贝/绑定判定表 + S 级真 Vulkan（lavapipe：3D 切片、3D+mip≠0、2D 数组层、交集）
+ A 级 Adreno 730 同源探针；5 项变异各自变红（见 §3 批 A'' 记录）。

**本族未做/边界**：
- 多层视图 / cube 整视图的“整视图快照”（Metal ④ 的 copy-whole-view）未接；默认 3D 视图采样仍读活附件（有一次性日志）。
- MSAA 附件在存储层就未接通（更早 fail-closed），不在本族能修的范围。
- 默认视图多 mip 的 LOD 语义仍是单级快照近似（历史行为，本族未扩大）。

**当前下一族**：以统一方案 §11.0 的真实撞点排序，不沿用当时的纹理视图优先级。

### 阶段记录：压缩纹理作渲染目标（块=像素影子，2026-11-06）

**为什么排到这里**：反馈采样快照修好后，TOTK 卡在 `format 139 has no colour attachment feature`——它把
32x32x32 的 RGTC1(BC4) 3D LUT 每个深度切片当渲染目标，附件视图用 RGBA16UI 覆盖（一个像素 = 一个 8 字节块）。
**Vulkan 事实**（不是照搬别的后端）：BC 格式没有 `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT`；不能建压缩↔无压缩
视图；`vkCmdCopyImage` 要求格式兼容，压缩与无压缩不兼容。因此唯一通路是：渲染到等尺寸无压缩影子
（`bw×bh` 块像素、视图格式），pass 前后用 `vkCmdCopyImageToBuffer` / `vkCmdCopyBufferToImage` 往返搬块
（`VkBufferImageCopy` 的块寻址：`bufferRowLength=0` 紧打包、3D 用 `imageOffset.z` 选切片、非 4 倍数 mip 贴边合法）。

**实现**：`nvn_vk_mrt` 新增 `nvn_vk_bcrt_plan_make`（格式/字节数/块尺寸判定）、`nvn_vk_bcrt_img_to_buf` /
`buf_to_shadow` / `shadow_to_buf` / `buf_to_img`（拷贝区域构造，宿主可直接测）；`first_draw` 加影子池
（按格式+块尺寸复用，所属帧完成前不回收，按字节预算 fail-closed）、影子视图当附件、按块尺寸建
framebuffer/renderArea（NVN 视口本身在视图/块像素空间）、每笔 bcrt pass 独占（不能与前后笔合并），
启动期每 32 笔一次等待式 flush（避免一个帧堆几百个命令缓冲撞帧队列完成证明表），拷回后把底图该子资源
标 GPU 写（`nvn_vk_texcache_mark_gpu_written_subres`，CPU 镜像不再可信）。

**验收**：L（`direct_nvn_mrt_test` 的计划/拷贝区域 + `nvn_vk_format_test` 的新映射）、S（`nvn_vk_bcrt_test.sh`，
lavapipe 244 项：3D 切片/2D 数组 mip 层/影子直写/取整/拒绝）、A（`nvn_vk_bcrt_probe.sh`，Adreno 730 同源用例）。
**变异**：M6 去掉“视图每字节 == 块字节”校验 → `✗ [A2b]/[C1d] 期望拒绝，真结果接受`；M7 3D 写回不选切片
→ `✗ [A6b] imageOffset.z 期望 2 真结果 0`、`✗ [B7] plane2 字节不符`。
**真机迭代读数**（同一台 Redmi 22081212C / Adreno 730）：修前半路 `Fatal signal 11 (SEGV, fault 0x128)`
在 BeginRenderPass 之后；查出两处根因——① framebuffer/renderArea 用了纹素尺寸（附件视图是块尺寸，非法 framebuffer）；
② 非合并路径命令缓冲句柄复用导致 `g_cmd_state` 误判、跳过 `vkCmdBindPipeline`（未绑管线录 draw → SIGSEGV）。
两处修后 BC4 逐切片绘制全部完成，红点推进到下一个能力缺口（可写 storage buffer）。

**边界**：只支持“视图每像素字节数 == 压缩块字节数”的块编码覆盖（BC1/BC4=8、BC2/3/5/6/7=16）；
其它压缩附件仍准确报红。视口按“视图像素=块”的 NVN 语义使用，不做纹素→块的额外缩放（TOTK 的 64x64
BC4 用 16x16 视口，正好是块尺寸）；子矩形 scissor 若按纹素给，语义会偏小，尚未遇到。

### 阶段记录：可写 graphics storage buffer / 驱动 c0 / 零附件 draw（2026-11-06，bcrt 之后）

**为什么排到这里**：bcrt 修好后 TOTK 的下一处红点是 `writable graphics storage buffer is not implemented`——它的“编码” pass 往 storage buffer 写数据。补上后又依次暴露三格：编译请求缺 `fragmentOutputTypes`（`rt_count==0` 的图形程序）、`uniform cbuf slot 0 is not a user UBO`（驱动 c0）、`first draw has no render target`（零附件 pass），最后撞上 `program declares 17 bindings, cap is 16`。

**做法（语义结构，不是调参）**：
- **可写 storage buffer**：Vulkan 没有“GPU 写直接映射回 guest”的借用语义 → host-visible coherent arena 影子；同帧按 `(guest,size)` 精确匹配复用（后一笔要看到前一笔的 GPU 写）；帧 fence 全部等到后（`fd_slot_retire` 的完成证明在手）按字节 `memcpy` 回 guest；draw 后对可写绑定发 buffer 屏障发布 shader 写。基址必须按 `minStorageBufferOffsetAlignment` 对齐（不对齐准确报红，不做错误对齐）；同帧区间重叠、每帧影子数超 16、arena 分配失败都准确报红。
- **驱动 c0 合成**：图形 shader 从 c0 读存储缓冲描述符表，内容由驱动生成、guest 里没有。按已测量布局合成：vs/fs/gs/tcs/tes 表基址 0x110/0x510/0x410/0x210/0x310，每槽 16 B `{u64 addr,u32 size,u32 pad}`（只用已绑定槽）；0x610 = float 2047.0f 最大点径；0x644 = base instance；其它位置保持 0（没测量结论的不猜）。未知阶段准确报红。
- **零附件 draw**：`rt_count==0` 是合法的“只写 storage 的编码 pass”。Vulkan 允许 0 附件 render pass + 0 附件 framebuffer，光栅化仍执行 FS 写 SSBO；renderArea 取视口并夹到设备 `maxFramebufferWidth/Height`；没有共享附件，逐笔独占（不与前后笔合并）。`rt_count==0` 且绑了深度附件的走 depth-only pass（后续改动，见 §7）。
- **编译请求与绑定上限**：编译器（`DirectProgram.cs`）对图形程序恒要求 8 项 `fragmentOutputTypes`（`rt_count==0` 也要中性 Float），请求侧改为恒输出；压缩附件按 bcrt 视图格式取颜色类型。`FD_MAX_BINDINGS` 16→64 先承接 TOTK request `3a9da3a0c1359d54aae2bf9971e5aded` 实测的 17 条；随后恢复主线按 producer 合同推导的上限——每阶段至多 18 uniform + 16 storage + 64 texture + 16 image，图形程序固定 vs+fs 两阶段再加 1 条全程序共享 support：1 + 2×(18+16+64+16) = 229（compute 只 cs 一阶段，1+18+16=35，被同一上限覆盖）。超出推导上限仍准确拒绝、不静默丢绑定；设备能力另由 `maxDescriptorSet*` / `maxPerStageDescriptor*` 校验把关，不靠这个数组容量。

**验收（只到 A 级单机，L/S 未跑）**：Redmi 22081212C / Adreno 730，APK versionCode 1793958300（21:13:18 安装）：`writable storage buffer` 7 次、`synthesized driver c0` 1 次、零附件 draw 252 笔，红点推进到 `program declares 17 bindings, cap is 16`（21:13:50.738）；versionCode 1793958200 的上一跑里 `synthesized driver c0` 1 次后红点推进到 `first draw has no render target`（21:08:26.635）。versionCode 1793958400（21:18:14 安装）：该 request 作为 disk hit 出现（21:18:49.156），不再报 17 条超限，新红点为 `storage buffer overlaps another live shadow in this frame`（21:18:49.419，设计内准确报红）。宿主用例已加（`direct_nvn_mrt_test` 的 c0 布局/格式层、`direct_compile_request_test` 的 `rt_count==0`、`direct_nvn_compile_facts_test` 的压缩附件视图格式），**本轮无执行记录（未验证）**。

**本族未做/边界**（cap64 跑时点）：同帧 storage buffer 子区间重叠一律准确报红；随后工作树加入 contained 子区间复用改动（未提交、未验证，不在本记录射程）；每帧可写影子上限 16、arena 预算超限报红；c0 只接图形、compute 侧未接，未测量字段一律 0；零附件 pass 的 scissor/query 语义未单独验（`rt_count==0` 且绑深度已在后续改动改为 depth-only，见 §7）；绑定上限是静态 64，未验证 compute 侧 >16 条程序；未跑整局到世界（缺导入数据）。

**cap64 跑后的下一处红点**：同帧 storage buffer 影子区间重叠（21:18:49.419：只读子区间 0x1f7e7ab1c0/32640 落在同帧可写影子 0x1f7e7ab000/131584 内）；随后工作树的 contained 复用改动未提交、未验证。

### 阶段记录：compute 路径打通（c0/support 未知读集、UBO 表别名、size=0 绑定）+ 条件渲染（2026-11-06，真机验证）

**为什么排到这里**：图形启动链（可写 SSBO/c0/零附件/绑定上限）跑通后，TOTK 的第一笔 compute dispatch
在资源绑定处连撞三处：`supportReads/c0Reads = null`（编译器分析不出读集）、storage 描述符来自
c0 0x210 UBO 表（`uboPtr` 别名）、storage 绑定 `size=0`（长度未声明）。修完后加载期又撞
`frame queue batch-fence table is full`（OP_BARRIER 前 pass break 等待完成证明失败）。

**候选实现（下列未知读集/条件/截断处理仍须独立语义验证，不能由过红点推定正确）**：
- `supportReads/c0Reads = null`：按“读集未知”接受，运行时用**已知布局**填满——compute c0 = dispatch
  size(0x200) + UBO 表(0x210) + storage 表(0x310)，值全部来自本次 dispatch 状态；SupportBuffer 全填
  恒等值（render scale=1、flags 位=0）。不是数组也不是 null 仍拒绝。
- compute storage 描述符来源 `NVK_STORAGE_UBO_PTR`（c0 0x210+16r）：c0 该表项就是槽 r 的用户 UBO
  描述符，因此这条 storage 绑定别名“槽 r 的 UBO 本体”，按 `ubo[r]` 的地址/长度解析。
- storage 绑定 `size=0`（NVN 未声明长度；Vulkan 必须给真实窗口）：**先查前端登记的活动 nvnBuffer**
  （`BufferInitialize` 登记 CPU 地址+长度、`Finalize` 注销，hle_nvn.c 的 `nvn_buf_extent`），命中即用
  精确长度（可写绑定只接受精确长度，否则整段回写会盖相邻分配）；查不到再退回“池尾 − 地址”近似
  （单点 `nvn_gva_pool_of`，不用有 cap 截断的快照），近似窗口只给只读绑定且夹 64 KiB。
- 条件渲染（NVN SetRenderEnable / SetRenderEnableConditional）：安卓回放侧真求值——OP_RENDER_COND
  记录 mode/addr；报告表跟踪本次提交已回放的报告（时间戳类 counter 域已知 0、samples-passed 未知），
  条件已知且为假时**丢弃整块内的 draw 和 clear**；未知时当前实现照常绘制。此退路对条件清屏等副作用尚未证明等价。
  安卓 profile（`s2a_nvn_prof` 强定义）按 NVN 缺省给 `render_cond=1`，`debug.s2a.render_cond=0` 可关。
- 帧队列已提交前缀完成证明表 136 → 512（加载期一帧内 barrier/报告把 pass 切出成百上千批）。

**验收（A 级）**：Redmi 22081212C / Adreno 730，APK versionCode 1793959800/1793959900：
`render_cond: drop clear` 逐帧出现（说明前端录制 + 回放门控生效）、`size=0: using exact buffer extent`
在 compute dispatch 出现，红点从 compute 资源绑定推进到加载期 `OP_BARRIER` 的完成证明表容量（已修）。

**边界/未验证**：条件渲染对 `Dispatch` 不门控（NVN 条件语义按“渲染命令”理解，只覆盖 draw/clear）；
条件未知时按“照常绘制”；`size=0` 若无活动缓冲登记（虚构池/未初始化缓冲）退回池尾近似，只读、夹 64 KiB；
精确长度被 4 MiB 截断时超出部分行为未验证；batch-fence 表仍固定为 512；增容只缓解容量，完成项及时退休与背压尚须验证。

**后续修正（同日真机撞到后）**：TOTK 的 size=0 storage 不止一条，冻结缓冲的精确长度 4 MiB、地址只差 0x200，
两条可写窗口必然重叠。若各建一份影子，GPU 写会分叉、回写互相覆盖——不能警告后放行。改成
**dispatch 级并集影子**：把所有无界 storage 绑定的区间并成一份 host-visible 影子（起点按 64 字节对齐），
每条绑定按 `guest − win_base` 作描述符 offset 绑进同一份字节，帧尾只回写一次；有界/无界混合可写重叠
仍准确失败（两条口径不同，会分叉）。真机日志 `compute unbounded storage: 8 binding(s) share one window
[0x1f2d182a40,+4198912) writable=1`，op=27 的资源拒绝消失。诊断 A/B 门：`debug.s2a.compute_skip=1`
（整笔 dispatch 不执行）、`debug.s2a.compute_no_writeback=1`（跳过并集影子回写），默认都关，仅用于定位。

</details>

## 1. 三层模型：什么一次修好、什么必须分厂商验

| 层 | 由谁决定 | 处理方式 |
|---|---|---|
| **NVN 契约层** | 同一套 Switch NVN（c0/c1/c2/c3+ 常量槽语义、纹理句柄编码、SubmitCopy 方向、资源生命周期） | 同一契约的实现由所有游戏复用；按实际覆盖范围验收。Metal 后端 `graphics/nvn/gfx/nvn/nvn_mtl.m` 是参考，接口含义仍须独立核对 |
| **Vulkan 驱动层** | Adreno / Mali / Immortalis / PowerVR 的驱动行为与限额 | **必须按 `vendorID` + 能力查询**（`vkGetPhysicalDevice*Properties/FormatProperties/External*`），**不许按 SoC 商标硬编码**。参数（提交批大小、对齐、tile 行为）不许跨 GPU 复用 |
| **游戏使用层** | 每个游戏用了哪些组合 | 游戏提供真实撞点与组合验证；把观察到的问题还原成通用契约，再做驱动验证 |

<a id="direct-capability-gaps"></a>

## 2. 能力矩阵与实际缺口

以下按 `1dd14e746` 源码核对；§3/§4 说明证据与验收。**有布局声明不等于有资源消费路径**。

| 能力 | draw | dispatch | 已有范围与证据 | 实际缺失 / 待验 |
|---|---|---|---|---|
| 组合纹理、视图与采样器 | 部分 | 部分 | 生产已接；compute 有宿主 GPU 白/黑字节对照 | main 直绑与本线消费点快照不同；合流后其它游戏、重绑/Finalize/同址重建待回归 |
| 用户 UBO（cbuf 3..18） | ✅ 指定范围 | ✅ 指定范围 | 掩码扩宽与按需 identity v4；缺事实拒绝 | 与 GPU 写依赖、跨阶段/代际组合随缓冲族验证 |
| c1 常量段 | 部分 | 部分 | 均从消费点源快照取数据；compute 当前绑定 0x100 B | 完整长度/BRX 控制流需求与真实程序输出待验；不能再记“compute 未接” |
| c0 / support 内建常量 | 部分 | 部分 | 图形布局合成；compute 已接；main 的 set/binding 分析修复已纳入 | 读集为 null 时填满布局/Support 恒等值的语义未完全证明；未观测字段不能算正确值 |
| c2 作为普通 UBO | 未闭环 | ⬜ 显式拒绝 | 组合句柄表用于纹理绑定已接 | shader 直接把 c2 当 uniform 读取的完整内容/寿命未实现；见 compute result parser |
| 可写 SSBO / 别名 | 部分 | 部分 | 图形帧内包含区间复用；compute 无界区间共享并集影子，A 路径已命中 | 图形部分重叠、compute 有界/无界混合重叠、跨操作共享、CPU 并发写与整段回写未闭环 |
| storage 地址来源 | 部分 | 部分 | compute NVN/UBO_PTR/UBO_ADDRESS 已接 | 图形间接 UBO 指针仍拒；size=0 无登记只读近似、4 MiB/1 MiB 限长与对象别名寿命待验 |
| 零附件 / 仅深度绘制 | 部分 | ➖ | A 指定程序跑通；零颜色且有深度走 depth-only | 未设置视口退回 1×1；scissor/query/多个状态组合与输出字节待验 |
| 单程序绑定上限 | 部分（229） | 部分（229） | 共用 `FD_MAX_BINDINGS` = 1 + 2×(18+16+64+16) = 229（producer 合同推导；compute 单 stage 1+18+16=35 也覆盖）；图形第 17 条程序 A 跑通 | 设备能力限额另由 `maxDescriptorSet*` / `maxPerStageDescriptor*` 校验，不混进推导上限；compute 大绑定集、超限完整拒绝须回归；不是 descriptor 数组支持 |
| **storage image（GPU 可写图像）** | **⬜** | **⬜** | 图形虽有 kind/layout 枚举，实际绑定仍走未实现拒绝；compute 解析时拒 kind=image | 图像句柄快照、STORAGE usage/格式能力、视图、访问屏障、GPU 写登记/后续读取均缺 |
| **独立纹理/采样器绑定** | **⬜** | **⬜** | `DirectShaderCompiler` 对 `resolved.Separate` 明确拒绝 | 分离身份、独立重绑/保活、描述符与实际采样的全链路未实现 |
| **纹理/描述符数组** | **⬜** | **⬜** | 两路 layout 固定 `descriptorCount=1`；compute 对 count≠1 拒绝 | 图形 parser 尚未核 count，存在静默当单项的缺口；完整索引、部分绑定、寿命/越界语义未实现 |
| **间接 / multi-draw / TF** | **⬜** | **⬜ 间接 dispatch** | 生产 draw 对 ind/mdi/tfc 拒绝；dispatch 对间接 group counts 拒绝 | GPU 产参数 → 参数可见 → 实际执行；TF 还缺输出缓冲、计数与生命周期 |
| **部分/带视图纹理拷贝** | ➖ | ➖ | 普通整幅 copy 已接；ReadTexels 有区域计划；bcrt 用自己的搬运 helper | 通用 B2T/T2B 的 flags/view/offset/partial、T2T 的 view/partial/mismatch 仍拒；局部读回不等于局部拷贝已接 |
| 反馈采样 | 部分 | ➖ | 单级单层 2D 快照；源支持 mip≠0、数组层、3D 切片，L/S/A | **多层/cube 整视图、完整 3D、多 mip LOD** 未闭环；部分不支持组合仍保持活附件并记录原因，有错图风险 |
| 压缩格式作为渲染目标 | 部分 | ➖ | 等块字节数的无压缩影子 + buffer 往返，L/S/A | 非匹配格式、cube/多层附件、部分 scissor 组合未实现/未验；不是所有 BC 格式均已逐项真机验证 |
| **MSAA / resolve** | **⬜** | **⬜ 多采样资源** | texcache 对 target 5/6 或 samples>1 拒绝 | 多采样存储/视图、管线 sample count、resolve、拷贝/反馈/读回均缺 |
| **DrawTexture** | **⬜** | ➖ | OP_DRAW_TEX 字段完整报错 | 内置 quad 绘制、目的/源区域、状态与采样语义未实现；保留需求，待实际命中再排 |
| **原始全局地址的池表路径** | **⬜** | **⬜** | main 的 Metal 已建 gmem_map/gmem_log；Android `nvn_be_pool_addressed` 为空桩 | 原始池表/写记录的反射、运行时绑定、驻留与回写缺失；UBO_ADDRESS 单缓冲解析不等于此能力 |
| 条件渲染与计数报告 | 部分 | ➖ 当前不门控 dispatch | 已知条件门控 draw/clear；A 有 drop clear 日志；samples-passed 有真实查询 | 未知条件 fail-open、跨提交报告/读回时序、条件命令范围的独立期望未齐 |

### 2.1 资源内容与完成语义（能力已接后仍会导致错图/崩溃）

| 缺口 | 已有机制 | 还缺什么 | 生产落点 |
|---|---|---|---|
| CPU/GPU 缓冲交接 | 图形帧内影子、compute dispatch 内并集、完成后回写 | draw↔dispatch/dispatch↔dispatch/CPU 之间的别名一致性；不能用整段旧快照盖 CPU 新写 | `nvn_vk_compute.c:finish`、`nvn_vk_first_draw.c:fd_ssbo_wb_writeback`、`hle_nvn.c:nvn_buf_extent` |
| CPU 直接读 GPU 写过的纹理 | ReadTexels 显式回读 | **CPU 直接 load 的读拦截/依赖与回写未接**；高度图/游戏逻辑可能无红地读旧值 | `nvn_vk_readback.c`、共享 track/guest 内存接缝 |
| 纹理局部内容归属 | 声明范围账本、2D/mip 局部合并已有 S+A | 深度/模板、3D、BC 解码图、线性纹理局部合并；在途新版本局部合并；更细 GPU 写区域 | `nvn_vk_texcache.c:nvk_apply_pending` / `nvk_sync_hint` |
| 预算背压 | 有预算与完成队列 | **dirty_defer 仍返回旧纹理**；查询重试上抛 red、保留表上限/Stop 结算尚未统一 | `nvn_vk_texcache.c` 的 dirty_defer、query、first_draw 的退休路径 |
| 事件/屏障/退休 | SignalEvent 写值前要求完成证明；有批次 fence | **WaitEvent 高位仍直接 break**；固定 512 项表没有替代及时退休/背压；未知完成的 owner 结算须逐入口核对 | `vk_record.c:OP_SIGNAL_EVENT`、`nvn_vk_first_draw.c`、`nvn_vk_query.c` |

**已知缺口不等于已证根因**：上表可作为下一撞点的核查清单。当前是否实施、先实施哪项，
由统一方案 §11.0 的真实阻塞与触发证据决定；不把所有风险同时展开。

### 2.2 给 dsh 的缺口定位与触发后验收表

**读法**：“未见命中”来自现有日志普查，不是承诺后续不用；“族已命中”也不表示该行全部变体已执行。
下列是本次源码可确认的缺口，未声称完成全量 NVN 规范审计。

| 实际缺失项 | 代码依据 / 当前行为 | TOTK 命中证据 | 命中后补齐这一族的边界 |
|---|---|---|---|
| storage image（draw 与 compute 都未实现） | [program result](../native/nvn/nvn_vk_program_result.c) 的 compute kind=image 拒绝；[first_draw](../native/nvn/nvn_vk_first_draw.c) 实际资源循环未实现 kind=3，只有 layout/pool 声明 | 现有普查未见 kind=3 命中 | image 句柄快照、usage/格式能力、mip/层/访问类型、写屏障与内容登记；compute 写→draw 采样→读回逐字节验证 |
| 独立纹理/采样器绑定 | [DirectShaderCompiler](../../graphics/tools/direct/compiler/DirectShaderCompiler.cs) 对 `resolved.Separate` 抛 UNSUPPORTED_PROGRAM | 现有观察以组合句柄为主，未见分离绑定命中 | 纹理/采样器各自身份、重绑/保活、同纹理换采样器与同采样器换纹理、实际采样字节 |
| 纹理/描述符数组 | [program result](../native/nvn/nvn_vk_program_result.c) compute count≠1 拒；图形未读取 count；两路 layout 的 descriptorCount=1 | 已见图形反射 count=1；未见多项数组 | 先补图形准确拒绝；实现时覆盖实际数组长度、索引来源、未绑定/越界语义、更新与 Finalize 的寿命，不能只把 descriptorCount 改大 |
| 间接 draw / multi-draw / TF / 间接 dispatch | [vk_record](../native/direct/vk_record.c) 在生产入口拒绝 ind/mdi/tfc 与间接 group counts；TF state 的记录不等于输出执行 | 现有普查未见这些执行路径命中 | GPU 产参数的依赖、count/stride/offset、零笔/越界、TF 输出与计数，真实 GPU 执行后检查结果 |
| 通用部分/带视图纹理拷贝 | [vk_record](../native/direct/vk_record.c) 的 COPY_B2T/T2B 对 flags/view/offset/partial 等组合拒绝；COPY_T2T 使用计划器处理部分、视图及已支持的 flags，其余组合仍明确拒绝 | 有 ReadTexels 和专用 bcrt 往返；通用 partial/view copy 未见命中 | 方向、buffer 偏移/行距、视图 mip/层/3D 切片、区域边界、压缩块边缘与 GPU 写归属；ReadTexels 成功不作为此项完成 |
| 多层/cube/完整 3D/多 mip 反馈 | [mrt](../native/nvn/nvn_vk_mrt.c) 的 feedback 源计划只接单切片，绑定替换只接单级单层 2D；其它部分组合保留活附件 | 单子资源 mip/数组层/3D 切片已命中；剩余整视图组合未验 | 快照覆盖真实采样视图的全部子资源与 LOD/类型；同图其它子资源保持原绑定；保留活附件不算等价实现 |
| MSAA 与 resolve | [texcache](../native/nvn/nvn_vk_texcache.c) 对 target 5/6 或 samples>1 明确拒绝 | 现有观察为单采样；未见多采样命中 | sample count/格式能力、存储与视图、管线/附件、resolve、copy/反馈/读回完整链路 |
| DrawTexture | [vk_record](../native/direct/vk_record.c) 的 OP_DRAW_TEX 直接拒绝并给字段 why | 现有普查未见执行命中 | 源/目的矩形、采样、混合/通道 mask、深度状态、状态隔离、实际 quad 输出；此前“不做”是当时排期，不是永久删除需求 |
| 原始全局地址池表 | [nvn_be_android](../native/nvn/nvn_be_android.c) 的 `nvn_be_pool_addressed` 为空桩；Metal gmem_map/gmem_log 无 Android 对等消费 | 未有该哨兵槽/池表路径的 TOTK Android 命中证据 | 反射、表/写记录绑定、地址换算、池代际/驻留、真实读写与完成回写；区别于 UBO_ADDRESS 的单缓冲映射 |
| c2 普通 UBO、图形间接 storage 地址 | [program result](../native/nvn/nvn_vk_program_result.c) 拒 compute cbuf=2；[first_draw](../native/nvn/nvn_vk_first_draw.c) 对 storage_kind=3 拒绝 extent unavailable | compute 的 c0/UBO/SSBO 族已命中；这两个具体缺口未证命中 | 从真实源快照/绑定取内容与长度，核地址单位/槽位/代际；不能照抄临近槽或把池长当 buffer 长 |
| 跨操作缓冲与 CPU/GPU 交接 | [compute](../native/nvn/nvn_vk_compute.c) 的 dispatch 影子与 [first_draw](../native/nvn/nvn_vk_first_draw.c) 的帧内影子分立，完成后整段回写 | size=0、8 绑定重叠已命中；guest SIGABRT 已定位为 svc 0x2d writer 协调超时（errno=110）后的 die/abort，与本族无因果（`f31728606` 修，vc1793960500 多局 >10 min 无 SIGABRT） | 包含/部分重叠、同址别名、跨 dispatch/draw、CPU 同区间新写、前序 GPU 内容与回写时点一起验，避免新旧影子各自成功但内容分叉 |
| CPU 直接读取 GPU 纹理 | [readback](../native/nvn/nvn_vk_readback.c) 覆盖显式 ReadTexels；CPU 直接 load 没有相应读拦截/回写 | 来自 iOS 高度图坑提示；TOTK Android 尚无直接命中证据 | 先取得具体 CPU 读点与 GPU 写代际，再验证依赖和读到的实际字节；不能预先认定它就是崩溃根因 |
| WAIT / 旧纹理背压 / 完成项退休 | [vk_record](../native/direct/vk_record.c) 的 WAIT 高位 break；[texcache](../native/nvn/nvn_vk_texcache.c) dirty_defer 返回旧图；帧队列固定 512 项 fence 表 | fence 表满已命中；WAIT/dirty_defer 与当前退出的关联未证 | 信号/等待的位置、未完成不发布/释放、完成后回收、预算耗尽不交旧内容、超时与 Stop 保留 owner 的生产路径 |

## 2.5 已具备、应复用的基础（源码基线 1dd14e746）

| 项 | 事实 |
|---|---|
| compute 组合纹理采样 | 已接真实纹理、视图、采样器；Intel Arc B580 上白纹理输出 1.0f、黑纹理 0.0f |
| compute 消费点快照 | 编译事实与运行时绑定使用同一份保活快照 |
| compute 常量缓冲 | 用户槽对应 cbuf 3..18 已扩宽，身份按需 v4 |
| ReadTexels | CPU 路径已在 TOTK 启动段真机验证；GPU 路径有宿主 Vulkan 验证 |
| 图形程序与管线缓存 | 程序身份校验、ProgramRef、driver cache、配方清单与预热齐全 |
| 查询退休 | 按批次归属、完成后退休、范围 reset |
| AHB/VMA | 分块跟踪、映射代际、预算与保活 |

注意：以上是分项证据；TOTK 可见画面/世界与稳定性分别记录在统一方案 §11.0，不以整局推进反推每格全部通过。

## 2.6 历史 P0 反例的当前归档

| 问题 | 当前代码事实 | 保留的工作 |
|---|---|---|
| base_instance 丢失、间接入口漏拒绝 | firstInstance 已接；生产入口已对无法表达的 ind/mdi/tfc 拒绝 | 间接执行能力仍未实现；回归拒绝发生在真实 builder 前 |
| 图形常量掩码截断 | 完整 cbuf 3..18 与 identity 分叉已接 | 持续保留高位槽、解绑/重绑反例，不再从零补一遍 |
| 非等价采样器替换 | 已分精确/经验证等价/准确拒绝 | 新参数组合按真实输出校验，未验证不扩大支持 |
| SignalEvent 提前可见 | 信号写值前已加完成证明 | WaitEvent 静默跳过仍开；信号与等待必须一起验证 |
| dirty_defer 旧纹理 | 仍能返回旧版本 | 命中该分支时修背压族；不得通过返回旧图让当前 draw 成功 |
| 描述符数组 | compute count≠1 拒；图形 count 校验仍缺 | 先消除图形静默按单项消费，再在命中数组时补完整执行 |

## 2.7 main 合流后的生产者—消费者核对

本基线已合 `main@54bd6e129`；共享编译器保留 main 的 c0 set/binding 修复，compute 回填 UBO_ADDRESS，图形/回放保留本线能力。合流后仍有两侧实现差异，不能把所有 main 能力算作 Android 已完成。

**合流不能只解冲突**：每处记录格式/字段来源/寿命变化都要同时核对 Android 侧的拍平、快照与回放消费者。为此固定一张**生产者—消费者表**：

```
NVN 调用 → 产生什么记录与字段 → Android 快照保留了什么
        → 编译器读取了什么 → Vulkan 实际执行了什么 → 完成后谁结账
```

这张表能直接暴露「原始 Draw 有字段、快照没有」与「前端能产生记录、后端没有分支」两类问题。

**表已落盘**：[direct-producer-consumer.md](direct-producer-consumer.md)。行号基线 `ce8bfc23d`
（合流前 HEAD），覆盖 Draw 家族、状态与绑定、事件与同步、复制与清除、compute 五批；文末另列
「记录有、快照丢」与「前端有记录、后端无分支」两份历史清单。该旧基线尚不能代替本次合流后的逐项核对。
合流后任何一行的记录格式/字段来源/寿命发生变化，都要回到该表重核第 3–6 列。

## 2.8 不照抄 iOS 的部分

- AHB 替页、VMA 预算、Metal no-copy 的实现形状可以不同
- Vulkan 描述符与 Metal argument table 可以不同
- 查询池与 visibility buffer 可以不同，只要计数/顺序/退休结果一致
- **iOS 自身仍有近似采样、缺项继续绘制、压缩展开后读回零值等限制——不能作为 Android 的追齐目标**
- Android 已有的完整身份检查、准确失败、下一进程 AUTO 兜底，按自己的合同验收

## 3. 按族交付的最小回归范围

**本表给验收边界，执行顺序只看统一方案 §11.0。** 同一轮选择一个有触发证据的族，
优先复用已有测试；同文件的修改串行集成，互不依赖的只读核对/独立夹具才适合并行。

| 族 | 生产落点 | 本族必须验证的反例 / 相邻变体 | 已有入口 / 还需补的覆盖 |
|---|---|---|---|
| 缓冲范围与共享内容 | `nvn_vk_compute.c`、`nvn_vk_first_draw.c`、`hle_nvn.c` 的登记/查询 | 三地址来源、零长度/限长、包含/部分重叠、只读与可写别名、相邻分配哨兵、CPU 写后回写、Finalize/同址重建 | `direct_nvn_compute_storage_test.c` 仅证明解析；`w2_compute_pipeline_test.py` 核生产链；`nvn_vk_ssbo_guest_test.sh` 核图形指定子集；补真实 GPU 的共享/跨操作/CPU 字节对照 |
| 编译事实与驱动段 | source_store、compile request、共享 compiler、program result | 同 binding 不同 set、高 cbuf、c1 长度、null/空/未绑定区别、错误种类/阶段、缓存身份失效 | 保留 main 编译器反例和既有 request/identity 用例；未知读集的完整语义须独立验证 |
| 视图/反馈/块格式 | mrt、texcache、first_draw | mip/层/3D 切片、块边缘、格式/字节不兼容、实际绑定视图；未实现的整视图组合准确标缺 | `nvn_vk_feedback_snapshot_test.sh`、`nvn_vk_bcrt_test.sh` 与同源真机 probe |
| 内容归属与背压 | texcache、readback、完成队列 | 同值 CPU 重写、同 GOB 局部写、GPU 新写、预算满/在途旧图、无范围 hint、各资源类型 | `nvn_vk_texcache_content_test.sh`；补预算故障注入与同源真机回归 |
| 条件/事件/完成与退休 | vk_record、query、first_draw、owner | 已知真/假/未知条件，待写报告，GPU 未完成时事件不可见，等待先后，表满/超时/后获证明/Stop | 复用 record/query/retirement 用例；撤等待或提前 free 必须让功能断言失败 |
| 尚未命中的功能族 | storage image、分离采样器、数组、间接/TF、局部拷贝、完整反馈、MSAA、DrawTexture、原始池表 | 先保留真实缺口与准确拒绝；发生真实命中后核完整 producer→consumer 合同并制作对应字节/图像反例 | 不预先承诺一整排能力；§2 的同名行就是当前缺口清单 |

下面批 A 及其后续批次是**历史实验记录**，其中“未提交/在改/下一步”只对应当时。
当前范围看 §2，当前排期看统一方案 §11.0。

### 批 A 交付记录（内容版本与 CPU/GPU 交接，2026-11-06）

- 实现：`nvn_vk_texcache.c`（子资源三态版本 + guest 内容账本 + 局部合并 + 读回选路查询）、`nvn_vk_readback.c`（按子资源选 guest/图像）、`nvn_vk_texcache.h`（只做加法）。
- 测试入口：`android/tools/nvn_vk_texcache_content_test.sh`（真 Vulkan / lavapipe，已登记进 `android/test.sh`）。
- 修前失败（变异 1：恢复“整图 `gpu_written` 挡住一切复查”）：反例① `① Draw 必须看到蓝（CPU 整图覆盖）`、反例② `② Draw 必须是蓝块 + 红底（GPU 内容保留）`、反例③ `③drawA: first mismatch at (0,0) got=255,0,0,255 want=7,7,7,255` 全红。
- 修后通过：同一用例集 0 处不符；再撤局部合并分支（变异 2）→ `② Draw 必须是蓝块 + 红底` 与 `没有出现过局部合并（patches=0）` 重新变红。
- 覆盖：2D 块线性 RGBA8、单级单层（128×128）；读回两条路径；失败路径（提交失败注入、账本不可用）；1 MiB 保护块恰好只有“诱饵字节”被写时不触发内容同步；全 CPU 内容在途 + 局部写时走“退役+新建”而不是 fail-closed。

| 资源 × 操作 | CPU 整覆盖 | CPU 局部更新 | GPU 清/写后读 | ReadTexels |
|---|---|---|---|---|
| 2D 块线性（RGBA8，单级单层） | ✅ S | ✅ S | ✅ S | ✅ S |
| 2D 多级 / 2D 数组 / 立方体 | ⬜ 未跑本批用例（版本表按 mip/层建立，逻辑同路径） | ⬜ | ⬜ | ⬜ |
| 3D / 深度+模板 / BC 解码 / 线性纹理 | 整块覆盖可用；**局部合并显式 fail-closed**（原因随失败返回） | ➖ 拒绝 | ⬜ | ⬜ |
| AHB 池内同 1 MiB 块双纹理 | ✅ S（不误判为被改写） | — | — | — |

批 A' 覆盖（同一用例的 S 与 A 两跑均全绿）：

| 资源 × 操作 | 声明整幅 | 声明局部 | 无声明 hint + GPU 内容 | GPU 写新于 CPU 发布 |
|---|---|---|---|---|
| 2D 块线性（RGBA8，单级单层） | ✅ S+A | ✅ S+A | ✅ fail-closed S+A | ✅ S+A |
| 2D 多级 mip 局部 | ✅ S+A（⑫） | ✅ S+A（⑫） | — | — |
| 3D / 深度+模板 / BC 解码 / 线性 | 整级整块可用 | ⬜ fail-closed（未跑本批用例） | ⬜ | ⬜ |

### 批 A' 交付记录（内容归属账本：CPU 声明写范围，2026-11-06）

- 实现：
  - `nvn_vk_texcache.c/.h`：新增 `pend[]`（CPU 声明写范围，待落地）/ `sync_r[]`（当前 GPU 代际内“图像==guest”范围）两份账本；
    哈希账本降级为“变化检测 + 只在 sync 范围内证明未变以少传”；`mark_written` 新代际清空两份账本（GPU 写晚于已发布 CPU 写，旧范围作废）；
    `nvk_bytes_rects` 从“整 GOB 矩形”改为“16 B piece → 精确纹素矩形”；新增 `nvk_apply_pending` / `nvk_sync_hint` / `nvk_guest_whole`。
  - `nvn_vk_session.c/.h`、`mtl_vk_adapter.c/.h`：`pool_written` 精确范围转给纹理缓存；新增 `tex_written_rect` 转入口。
  - `graphics/nvn/gfx/nvn/hle_nvn.c`：`nvnTextureWriteTexels` 在 Android 下经弱钩子 `s2a_vk_adapter_tex_written_rect` 交出精确区域
    （与已有的 `s2a_vk_adapter_pool_written` 同一个 `#if defined(__ANDROID__)` 模式；苹果宿主不受影响）。
- 测试入口：同一份 `android/tests/nvn_vk_texcache_content_test.c`，宿主 `tools/nvn_vk_texcache_content_test.sh`（S，lavapipe）
  与设备 `tools/nvn_vk_texcache_content_probe.sh`（A，Adreno 730）共用；用例⑨–⑰为本次新增。
- 修前失败（S 级，修前生产代码）：`⑨ Draw 必须看到黑（CPU 整图重写与旧 guest 同值也算写）`、
  `⑨ ReadTexels 必须读到黑`、`⑩ Draw 必须是蓝像素 + 其余红（未写像素保持 GPU 内容）`、
  `⑩ ReadTexels 必须是蓝像素 + 其余红`；计数探针：⑨ `patches=full=0`（一次同步都没发生），⑩ `patches=1`（一次整 GOB 合并）。
- 修后通过：⑨⑩⑪⑫⑬⑭⑮⑯⑰ + 既有①–⑧ 全绿；宿主 S 与 Adreno A 一致。
- 变异控制（撤掉关键修复 → 报用例名）：
  - M1「哈希相同即跳过同步」→ `⑨ Draw 必须看到黑…`
  - M2「合并按整 GOB 矩形（16×8）」→ `⑩ Draw 必须是蓝像素 + 其余红…`（并连带 ⑪⑫）
  - M3「`mark_written` 不清 pending」→ `⑮ GPU 写晚于已发布 CPU 写时必须保持 GPU 内容…`
  - M4「pending 不按子资源切分」→ `⑫ mip1 Draw 必须是蓝块 + 红底…`
  - M5「hint 在 GPU 内容上继续猜」→ `⑭ 无声明范围 + GPU 内容时必须 fail-closed…`（并连带 ⑦）
- 覆盖：2D 块线性 RGBA8；单级/多级 mip；整幅/局部/单像素/相邻像素；同值重写/同值发布；
  读回两条路径；失败注入（提交失败、无账本、无声明范围、在途局部）；GPU 写新于 CPU 发布的顺序。
- 未覆盖：3D / 深度+模板 / BC 解码 / 线性纹理的**局部**声明范围（仍 fail-closed）；区域级 GPU 写登记（仍整图）；
  真机上 `FlushMappedRange` 大流量路径（探针不经过 `hle_nvn`）；整局到世界（需导入数据）。

### 批 A'' 交付记录（反馈采样快照子资源：3D 切片 / 数组层 / mip≠0，2026-11-06）

- 实现：
  - `nvn_vk_mrt.c/.h`：`nvn_vk_feedback_src_plan` 增 target/depth，3D 的视图层号按深度切片校验；
    新增 `nvn_vk_feedback_copy_make`（3D 用 `srcOffset.z`、2D 用 baseArrayLayer、extent 取交集）与
    `nvn_vk_feedback_bind_plan`（NONE/SUBSTITUTE/LEAVE 纯判定）。
  - `nvn_vk_first_draw.c`：快照计划接 `rt->nvn_target/rt->depth`；预拷改用生产 helper；绑定替换按判定表执行
    （同图其它子资源不替换；表达不了的保持原绑定并记一次原因）。
- 测试入口：L `tests/direct_nvn_mrt_test.c`（计划/拷贝/绑定判定）；S `tools/nvn_vk_feedback_snapshot_test.sh`
  （lavapipe，真 Vulkan 字节）；A `tools/nvn_vk_feedback_snapshot_probe.sh`（Adreno 730，同一份用例源码）。
  S 用例已登记进 `android/test.sh`。
- 修前失败（S 级，旧实现语义）：3D 计划直接报错（TOTK `feedback snapshot: layer 1 outside 0..0`）；
  把 3D 切片当 array layer 选时 ① 读不到切片 1、② 读不到 mip1 切片 1。
- 修后通过：3D 切片 / 3D+mip≠0 / 2D 数组层 / 交集 全绿；L 判定表全绿。
- 变异控制（撤掉关键实现 → 报用例名）：
  - M1「3D 按 arrayLayers 判越界（旧规则）」→ `FAIL: 3D RT depth-slice view accepted`
  - M2「3D 切片塞 baseArrayLayer」→ `✗ ① 必须读到深度切片 1（蓝）`、`✗ ② 必须读到 mip1 的深度切片 1`
  - M3「3D 默认视图也硬换 2D 快照」→ `FAIL: 3D default view is left as is`
  - M4「不比较层/切片，同图就替换」→ `FAIL: other depth slice is not feedback`
  - M5「允许多层视图」→ `FAIL: layered view rejected`
- 未覆盖：多层/cube 整视图快照、默认多 mip 的 LOD 语义、MSAA 附件（上游未接通）、真机整局到世界。

### 批 A''' 交付记录（压缩纹理作渲染目标：块=像素影子，2026-11-06）

- 实现：
  - `nvn_vk_mrt.c/.h`：`nvn_vk_bcrt_plan_make`（压缩格式/视图字节数/块尺寸判定、取整到块）与
    `nvn_vk_bcrt_img_to_buf` / `buf_to_shadow` / `shadow_to_buf` / `buf_to_img`（buffer 往返拷贝区域；
    3D 用 `imageOffset.z` 选切片、2D 数组用 `baseArrayLayer`、`bufferRowLength=0` 紧打包）。
  - `nvn_vk_format.c`：补 RGB10A2 SNORM/SINT、RGBX8/16/32 族、BGR565/BGRX8/BGRA8(±SRGB) 映射
    （顶点属性常用；X 通道落同宽 RGBA、BGR 按“低位往上 r,g,b,a”对齐 Vulkan 打包顺序）。
  - `nvn_vk_first_draw.c`：影子池（按格式+块尺寸、帧完成前不回收、字节预算 fail-closed）、块尺寸
    framebuffer/renderArea、每笔 bcrt pass 独占、启动期每 32 笔等待式 flush；两处真机崩溃修复——
    framebuffer 用纹素尺寸（附件是块尺寸，非法 framebuffer）、非合并路径命令缓冲句柄复用导致
    `g_cmd_state` 误判并跳过 `vkCmdBindPipeline`（未绑管线录 draw → SIGSEGV）。
  - `nvn_vk_texcache.c/.h` + `nvn_vk_session.c/.h` + `mtl_vk_adapter.c/.h`：拷回后把底图子资源标 GPU 写
    （`nvn_vk_texcache_mark_gpu_written_subres`），CPU 镜像不再可信、不按 hash 重传。
- 测试入口：L `tests/direct_nvn_mrt_test.c`（计划/拷贝区域）、`tests/nvn_vk_format_test.c`（新映射）；
  S `tools/nvn_vk_bcrt_test.sh`（lavapipe，244 项，3D 切片/2D 数组 mip 层/影子直写/取整/拒绝）；
  A `tools/nvn_vk_bcrt_probe.sh`（Adreno 730，同一份用例源码）。S 用例已登记 `android/test.sh`。
- 变异控制（撤掉关键实现 → 报用例名）：
  - M6「不校验视图每像素字节 == 压缩块字节」→ `✗ [A2b] BC4+RGBA32UI 判定：期望拒绝，真结果接受`、
    `✗ [C1d] BC7+RGBA16UI 判定：期望拒绝，真结果接受`
  - M7「3D 写回不选深度切片」→ `✗ [A6b] buf_to_img imageOffset.z：期望 2，真结果 0`、
    `✗ [B7] 底图 plane2 往返后字节：期望 512 字节逐字节一致，真结果首差 @0…`
- 真机迭代读数（Redmi 22081212C / Adreno 730，同一 APK 链路）：修前 `Fatal signal 11 (SEGV, fault 0x128)`
  在 BeginRenderPass 之后（20:24:04.417，APK versionCode 1793957300）；块尺寸修正后 223 笔 bcrt pass
  走完，第 224 笔仍在 `bcrt: render pass begun` 后崩（20:32:27.552 / 20:34:42.124），20:34 那笔
  `render pass begun` 之后缺 `bcrt: bind pipeline`（前 223 笔都有）——命令缓冲句柄复用后误判状态已绑；
  begin 后作废绑定状态后 pass 连续完成（20:36:32.384 起），红点推进到 `writable graphics storage
  buffer is not implemented`（20:39:44.943，下一族）。
- 未覆盖：无格式覆盖/字节数不匹配/多层/cube 的压缩附件仍准确报红；子矩形 scissor 的纹素→块语义未接。

### 批 A'''' 交付记录（bcrt 之后四块：可写 storage buffer / 驱动 c0 / 零附件 draw / 编译请求与绑定上限，2026-11-06）

- 实现：
  - `nvn_vk_first_draw.c`：可写 graphics storage buffer 的帧内影子（`struct fd_ssbo_wb`，每帧最多 16 个）
    ——host-visible coherent arena；同帧按 `(guest,size)` 精确复用，不同区间重叠返回哨兵并准确报红；
    基址未按 `minStorageBufferOffsetAlignment` 对齐准确报红（不做错误对齐）；影子分配/预算失败报红；
    draw 后对可写绑定发 `VkBufferMemoryBarrier` 发布 shader 写；`fd_slot_retire` 在 fence 全部等到后
    `fd_ssbo_wb_writeback` 按字节回写 guest。只读绑定遇到同帧已有影子也复用（否则会拿 guest 旧字节新建）。
  - `nvn_vk_mrt.c/.h`：`nvn_vk_driver_c0_base` / `nvn_vk_driver_c0_fill_graphics`——图形驱动常量段 c0
    的测量布局（表基址 0x110/0x510/0x410/0x210/0x310、每槽 16 B `{u64 addr,u32 size,u32 pad}`、
    0x610 max point 2047.0f、0x644 base instance，其余 0；`NVN_VK_DRIVER_C0_BYTES`=0xA00）；
    新增格式层判定 `nvn_vk_bcrt_view_format`（编译事实与附件计划共用同一判据）。
  - `nvn_vk_first_draw.c`：零附件 draw（`rt_count==0`）——`mrt_plan` 零附件、尺寸取视口（四舍五入）并
    夹到 `maxFramebufferWidth/Height`、`merge_draw=0` 逐笔独占；去掉“no render target”拒绝。
  - `direct/compile_request.c`：`fragmentOutputTypes` 恒 8 项（`rt_count==0` 也输出中性 Float）；
    `nvn_vk_compile_facts.c`：压缩附件按 bcrt 视图格式取颜色类型。
  - `nvn_vk_program_result.h`：`FD_MAX_BINDINGS` 16→64 先承接 TOTK 第 17 条（原注释记“第 17 条起不解析
    不报错”的静默截断）；随后恢复按 producer 合同推导的 229（每阶段 18+16+64+16，图形 vs+fs 两阶段
    再加 1 条 support：1 + 2×(18+16+64+16) = 229）。超限准确报红、不丢绑定；设备能力另由
    `maxDescriptorSet*` / `maxPerStageDescriptor*` 校验。
- 测试入口：L `tests/direct_nvn_mrt_test.c`（新增 `test_driver_c0`、`nvn_vk_bcrt_view_format` 正负例）、
  `tests/direct_compile_request_test.c`（`rt_count=0` 仍输出 8 个 Float、无 gap）、
  `tests/direct_nvn_compile_facts_test.c`（bcrt 附件按视图格式给类型）；`CMakeLists.txt` 与
  `tools/direct_c1_probe.sh` 把 `nvn_vk_mrt.c` 链进 compile facts 用例。**本轮无宿主执行记录（未验证）**。
- 真机读数（Redmi 22081212C / Adreno 730）：
  - APK versionCode 1793958300（21:13:18 安装）：`writable storage buffer` 7 次（21:13:50.244–21:13:50.727，
    含 reused；guest 0x1f7e3eb000/23232 B、0x1f7e7ab000/131584 B）、`synthesized driver c0 (2560 B)` 1 次
    （21:13:50.294）、零附件 draw 252 笔（21:13:50.305–21:13:50.727，framebuffer 512x512 / 256x256 / 1x1）；
    随后红 `program declares 17 bindings, cap is 16`（21:13:50.738，request `3a9da3a0c1359d54aae2bf9971e5aded`）。
  - APK versionCode 1793958200（21:07:52 安装）：`synthesized driver c0 (2560 B)` 1 次（21:08:26.618）后
    通过，红点推进到 `first draw has no render target`（21:08:26.635）。
  - APK versionCode 1793958400（21:18:14 安装）：同一 request 作为 disk hit 出现
    （21:18:49.156 `key=v3a9da3a0c1359d54aae2bf9971e5aded identity=26defbc2`），不再报 17 条超限；
    新红点为 `storage buffer overlaps another live shadow in this frame`（21:18:49.419；只读子区间
    0x1f7e7ab1c0/32640 落在同帧可写影子 0x1f7e7ab000/131584 内，准确报红）。
- 未覆盖：宿主 L/S 本轮未跑；跨帧/未完成证明的 storage 写未做；同帧子区间重叠在 cap64 跑时按准确报红处理（随后 contained 复用改动未提交、未验证）；
  c0 只接图形（compute 未接）、未测量字段保持 0；零附件 pass 的 scissor/query 语义未单独验（`rt_count==0` 且绑深度已在后续改动改为 depth-only，见 §7）；
  绑定上限仍是静态 64；整局到世界未跑。

## 4. 证据等级（批 A 起逐格标注）

| 代号 | 含义 |
|---|---|
| L | 纯逻辑 / 宿主确定性单测（不碰真实 Vulkan） |
| S | 宿主 Vulkan 字节级（lavapipe；不代替真机） |
| A | Adreno 真机（Redmi 22081212C，Adreno 730） |
| X | 跨厂商（Mali / Immortalis 等） |

**S ≠ A**：S 只证明字节/布局/状态机对；驱动行为、时序、真机内存压力必须 A 级另证。未做的等级在格子里写 ⬜，不许拿 S 当 A。

## 5. 每笔交付的验收规矩（缺一不算过）

1. **修前失败、修后通过、撤掉关键修复后重新失败**（变异控制，必须给出变异后变红的那条用例名）。
2. **宿主测试**覆盖状态与失败路径；**真实 Vulkan 测试**（lavapipe 或本机 GPU）覆盖字节/格式/布局/同步。
3. **真机**覆盖实际 Adreno 路径；跨厂商（Mali/Immortalis）在拿到设备后补，未做要写成明确限制。
4. 报告必须给**覆盖矩阵**：哪些资源类型 × 哪些操作组合已验证，哪些还没做。**不许只写"全绿"**。
5. 失败一律 fail-closed，**不许**绑默认值/返回旧内容/吞掉 red 来"过局"。
6. 驱动相关实现必须走能力查询，**不许按厂商/SoC 硬编码**。
7. 性能参数（提交批大小、对齐、并发度）不许跨 GPU 复用，换 GPU 必须重测。

## 6. 跨操作主链（待补齐的集成验收，不作为已通过声明）

```
CPU 写入 → B2T → compute 读取纹理并写出 → Draw 消费 → T2T → ReadTexels 校验
→ Finalize / 同址重建 → 再执行一次
```

另加 draw→dispatch、dispatch→dispatch、GPU 写→CPU 直接读/写→后续 GPU 读、未完成时 Stop。
期望字节由原创输入独立计算；同一区间的别名必须共享 GPU 写；相邻分配哨兵和 CPU 新写不得被回写破坏。

## 6.5 iOS 塞尔达/TOTK 坑 ↔ 安卓直连状态（2026-11-06，预防性对照）

**来源与口径**：iOS 坑来自 `docs/坑记录.md`、`docs/研究/NVN覆盖普查_DanielZhangyc.md`
与 `docs/研究/直连性能手段对照.md`；Android 源码基线为 `1dd14e746`，运行进度见统一方案 §11.0。
本表用于解释风险和复用机制；iOS 读数、静态读取点、同名 API 都不作为 Android 已命中的证明。
表内旧行号仅用于定位历史记录，读码时以函数/符号为准。

| iOS 坑（日期 + 一句现象） | 安卓直连现状 | 撞到时怎么查 |
|---|---|---|
| 10-21 出图停在某帧：渲染线程在计数结果回调里等写跟踪锁，持锁的游戏线程在等渲染线程（botw 6 局 / mk8d 5 局） | **已规避（架构不同）**：Android 直连没有 iOS 的 CPU 写跟踪互斥锁；samples-passed 报告在帧完成点由 present retire 调 `nvn_vk_query_resolve` 写回（`nvn_vk_first_draw.c:1263`），默认非阻塞（`nvn_vk_query.h:1-16`，`debug.s2a.query_wait=1` 才切阻塞 A/B；`vk_record.c:2527` 记「游戏从不在帧完成前读计数器」的 d2r-mobile 实测）。整局多线程未验证 | `nvn_vk_query_stats`；`debug.s2a.query_wait=1` A/B；卡死现场收 tombstone / ANR 线程栈，看向谁等谁 |
| 10-21 「不支持」用 0 当哨兵：塞尔达 R8Unorm 顶点属性读成零 | **已规避**：NVN 枚举 `NVN_FORMAT_NONE=0x0`、`NVN_FORMAT_R8=0x1`（`include/nvn.h:399-401`），0 不是合法顶点格式；映射失败哨兵是 `VK_FORMAT_UNDEFINED`（`nvn_vk_format.c:14-18`），未知格式在 `first_draw.c:5940-5949` 准确报红，不按零值画 | 日志 `vertex attribute format 0x%x ... is not supported`；查 `nvn_vk_format.c` 的映射，不从报红字面猜枚举 |
| 10-21 无附件渲染通道宽高按 1：只靠副作用的绘制只跑 1 个片元 | **已实现**：`no_attach = rt_count==0 && depth_tex==NULL`（`first_draw.c:5369`），宽高取视口四舍五入并夹 `maxFramebufferWidth/Height`（`:5561-5590`），逐笔独占（`:5749`）；真机 vc1793958300 零附件 252 笔（512x512 / 256x256 / 1x1），后续跑共 275 笔；视口从未设置时回退 1x1 并记事实行（`:5583-5588`） | 日志 grep `zero-attachment draw`，看 `viewport=unset->fallback`；`debug.s2a.draw_log=1` 打开逐笔 |
| 10-23 写跟踪只拦写不拦读：塞尔达读 16 位高度图类渲染目标拿到旧字节 | **已知缺口**：Android 直连没有 CPU 读拦截，CPU 直接读 guest 内存不经同步；共享跟踪层自己写明「只拦写、CPU 读不拦」（`graphics/track/s2a_track.h:35`），且直连局不保护任何页（`:87`）；GPU→CPU 回写只有显式两路：ReadTexels（`nvn_vk_readback.c`）与可写 SSBO 的帧退休回写（`fd_ssbo_wb_writeback`，`first_draw.c:1247 / 3367`），都不拦 CPU 直接读；缺页钩子只处理写（`nvn_dirty.c:236`）。撞到表现为 CPU 读旧值/零、无红 | 画面/物理错但无红先查是否 CPU 直读渲染目标；grep 日志 `readback` 只应来自 ReadTexels；对同一块 guest 字节与 GPU 图像做内容对比 |
| 10-22 读回阻塞 17–18 s / 60 s：后端读回等全部已提交、2D 引擎 CPU 直拷撞 GPU 刚画的贴图 | **已知缺口 / 未验证**：GPU 内容 ReadTexels 先 `nvn_vk_first_draw_pass_break(1)` 等此前全部已提交工作完成（`nvn_vk_readback.c:208-215`），没有 iOS 的「只等自己的写 / 后台读回队列」；CPU 内容直接读 guest、不等待（`:199-204`）。TOTK 启动期 nx-120 的 BC4 读回走 guest 路径已通过（`:5-6`）；整局读回耗时未测 | 日志 `readback` 两路（`guest-memory` / `gpu-image`）；量 `pass_break` 等待与慢帧占比，与 iOS 同口径 |
| 10-23 缺页处理对同一共享状态读两次，跨线程翻转后两条分支都接不住 | **已规避 / 不适用直连**：Android 直连的缺页钩子是 `nvn_dirty.c` 的 `on_fault`（只处理写缺页，单次 `atomic_load` 判页状态 + mprotect，`:234-241`）；iOS 的 `s2a_track_fault` 两分支逻辑不在直连 guest 路径（直连局不保护页，`s2a_track.h:87`） | 直连看 tombstone + `nvn_dirty_stats`；服务层走共享 `graphics/track/track.c`（同一修复） |
| 10-23 零拷贝缓冲建在受保护页上：只读页 GPU 写无声丢失 | **机制不同 / 未验证**：Android 池零拷贝走 AHB 窗口化迁移（安全点换映射、`s2a_track_backing_begin/end`、迁移后重新登记脏页，`nvn_vk_poolahb.c:1-10 / 398-410`）；GPU 用 AHB 别名，不建在受 CPU 只读保护的映射上。页保护影响的是 VMA 粒度（`poolahb.c:272-275`；分块 1 MiB 由 `first_draw.c:493-502` 设置）。TOTK 真机 AHB 命中率与渲染目标交叉未验证 | 迁移失败日志 `poolahb:`；`debug.s2a.pool_no_dirty=1` 隔离；`/proc/self/maps` VMA 数与预算 |
| 10-23 零拷贝缓冲白屏：预回写把同步点快照写回游戏内存 | **暂不适用**：Android 直连没有 Ryujinx 的 BufferPreFlush / 预回写路径；同类「旧快照覆盖新内容」风险由内容归属账本防（GPU 写 → `mark_written` 新代际清 pending，`nvn_vk_texcache.h:100/242`，批 A' 反例⑮） | 查 `mark_written` / `pending` 语义；跑 `nvn_vk_texcache_content_test.sh` 反例⑮；关 AHB 零拷贝 A/B |
| 10-25 Metal TBDR 优化后每帧遍数变化 | **机制未移植、Android 未测**：没有同一套 Metal 遍控制/惰性清除开关；Android 的 pass 合并按附件及状态延续。不能仅凭 Vulkan API 判定硬件渲染架构，也不能套用 iOS 的遍数与能耗收益 | 用 pass_close_reason 和 GPU/提交全账找真实切 pass 原因；性能排在当前正确性阻塞之后 |
| 直连性能手段：TOTK 用条件渲染 | **已接生产、部分待验**：`mtl_vk_adapter.c:s2a_nvn_prof` 强定义缺省开启；`vk_record.c:OP_RENDER_COND` 求值并门控 draw/clear，已有 A 级 drop clear 日志；未知条件目前继续执行，尚未证明对条件清屏等副作用等价；不门控 dispatch | 对照已知真/假/未知条件与待写报告；记录实际开关；不能只以 draw 数减少判正确 |

### 6.5.1 王泪静态用到的「未实现」NVN 名称 ↔ 安卓直连现状

王泪 main 静态 3939 读取点中，覆盖普查工具归类「未实现」的 7 项（8 个函数名，ColorReduction / Window 两族各合并一行，见 `docs/研究/NVN覆盖普查_DanielZhangyc.md:42、54-66、77`；工具会把已注册的 `NVN_NOPROTO` 误计，人工核验见 `:93-119`，且部分实现已随代码前进）。逐项对到当前共享前端与 Android 回放：

| NVN 函数（王泪静态读取点） | 安卓直连现状 | 撞到时怎么查 |
|---|---|---|
| `nvnCommandBufferBindTexturesDeferred`（30） | **已实现**：记录游戏句柄地址，回放执行到该命令时读内存并按录制时池基址平移（`vk_record.c:2243-2271`）；S 级探针 `android/tools/vk_record_deferred_bind_test.sh` | grep 日志 `deferred`；跑该探针；纹理全黑先查句柄是否执行时读 |
| `SetColorReductionEnable`（2）/ `SetColorReductionThresholds`（2） | **空操作**：共享前端空函数体（`hle_nvn.c:4505-4506`），颜色压缩提示不改变输出；带宽影响未验证 | 输出无变化可对照；怀疑带宽时量附件读写；不按画错处理 |
| `SetCommandMemoryCallbackEnabled`（10） | **未实现（忽略）**：空函数体（`hle_nvn.c:3983`）；配套 `GetCommandMemoryUsed` 已按 AddCommandMemory 起点计（同文件 `:1434-1454` 注释，Fire Emblem 一类命令环回收坑已有语义） | 查 `GetCommandMemoryUsed` / `AddCommandMemory`（`DM_NVN_CBLOG`）；命令环不回收先查这里 |
| `nvnCommandBufferWaitEvent`（1，工具归空操作） | **已知缺口**：共享前端录成 `OP_SIGNAL_EVENT + NVN_EV_WAIT`（`hle_nvn.c:1799-1803`），回放 `vk_record.c:2503-2505` 遇高位 WAIT 静默跳过（不等、也不当信号写值）；Metal 侧 `nvn_mtl.m` 有 `ev_wait`。矩阵 §0.0 第 2 项 | grep `OP_SIGNAL_EVENT` / WAIT 位；同步类卡住先查此静默跳过 |
| `nvnProgramSetShadersExt`（1） | **已转换**：按 control 段转普通 `SetShaders`，非零扩展字段只记一次日志（`hle_nvn.c:3985-3998`）；Android 用转换后的程序 | 出现 `ProgramSetShadersExt extension field nonzero` 说明字段未用；stage 数越界有红字 |
| `Window/Builder SetNumActiveTextures`（2 / 1） | **已实现**：共享前端存 `nactive` 并夹到纹理数，`WindowAcquireTexture` 按 nactive 轮换（`hle_nvn.c:2789-2793、3957-3961`）；Android 同入口。真机 TOTK 是否依赖未验证 | 日志 `WindowSetNumActiveTextures` / acquire；画面轮换错先查 nactive |

**未验证边界**：上表「已实现 / 已规避」都来自代码与既有真机日志（`writable storage buffer`、`zero-attachment draw`、`depth-only pass` 等），不是 TOTK 逐项在安卓触达的证明；「王泪 7 名称」里除 Deferred 绑定外，其余没有 TOTK 安卓真机撞到的日志。iOS 侧读数来自 `docs/坑记录.md` 对应日期的 Mac/iPhone 局与 `docs/研究/直连性能手段对照.md`，不能直接当安卓读数。

## 7. 已知限制与未完成能力（不得用出画面覆盖这些缺口）

- **执行队列与当前阻塞**：只在统一方案 §11.0 更新。本表 §2 给实际缺失范围；world 目视记录不等于稳定运行、正确画面或所有能力已验证。
- **缓冲一致性**：compute 并集只覆盖同一次 dispatch 的无界绑定，有界/无界混合重叠仍拒；图形只复用包含区间，部分重叠仍拒。draw/dispatch/CPU 的跨操作共享尚未统一；整段影子回写可能覆盖 GPU 期间 CPU 新写，根因归属仍须实测。
- **长度与寿命**：NVN size=0 的等价范围仍需独立语义证据；活动 nvnBuffer 登记的别名/Finalize/同址重建、超池边界须验证。无登记时只读池尾近似为 64 KiB；命中 buffer 仍限 4 MiB；UBO_ADDRESS 限 1 MiB并有诊断。池内已映射不等于绑定合法范围，截断日志也不等于截断语义正确。
- **驱动常量**：c0/c1 已接；c0/support 读集未知时用完整布局/恒等值填充、c1 当前 0x100 B 的适用范围未完全验证；c2 作为普通 UBO 未闭环。main 的 set/binding 修复不自动证明未知读集退路正确。
- **条件渲染**：已知条件门控 draw/clear；未知时继续执行、跨提交报告与命令范围仍待验。避免把条件渲染笼统当成只影响性能。
- **CPU 直读 GPU 数据**：显式 ReadTexels 已有路径，CPU 直接 load 的读拦截/依赖回写仍缺；高度图/逻辑错值可能没有 red。
- **纹理内容归属**：2D RGBA8 单/多 mip 的声明范围用例有 S+A；深度/模板、3D、BC 解码图、线性纹理局部更新与在途局部版本化未闭环。无范围 hint 不能替代真实 CPU 写范围；同 GOB 未声明同值字节仍不可观测。
- **GPU 写登记**：多数调用只给图像；bcrt 有子资源登记，区域级登记尚不完整。VIC/NvRmSurface 外部写仍缺精确范围通道。每纹理范围账本上限 64 段，溢出策略须保留准确失败或已证等价路径。
- **预算与同步**：dirty_defer 返回旧纹理、WaitEvent 高位 break 均仍存在；查询的模块级可重试不能等同生产自动恢复。固定 512 项 batch-fence 表只缓解启动容量；完成后退休、背压、未知完成 owner/Stop 结算仍须按入口验证。
- **反馈/附件**：单子资源反馈和块编码附件已有分项证据；完整 3D、多层/cube 整视图、多 mip LOD、某些格式覆盖与 scissor/query 组合缺失。当前部分反馈组合保持活附件继续执行，尚有正确性风险。
- **明确未实现**：draw/compute storage image、独立采样器、描述符数组、间接 draw/dispatch 与 TF、通用部分/视图拷贝、MSAA/resolve、DrawTexture、Android 原始全局地址池表；详见 §2 的拒绝/漏校验位置。未命中时保留清单，命中后再按离世界检查点的距离排序。
- **合流回归**：main 的 compute 纹理直绑与本线消费点快照不同；UBO_ADDRESS 的生产执行/截断反例及其它测试族尚未逐项核齐。全量 CTest 的 GNU ld 环境失败单列，不能写全绿；修前/后使用同树 compiler/closure 与资源身份。
- **设备与产品范围**：真机证据目前来自 Redmi 22081212C / Adreno 730；Mali/Immortalis 等未验。暗黑3 设备级回归、另一引擎游戏、正常 Stop/重进/存档、长局与性能/能耗分别验收；不为回归删除导入数据或存档。

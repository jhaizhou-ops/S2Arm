# 直连生产者—消费者表（共享 NVN 前端 → Android Vulkan 后端）

本文固定 [direct-capability-matrix.md](direct-capability-matrix.md) §2.7 的生产者—消费者表：
每个 NVN 调用/opcode 一行，六列，回答「前端录了什么 → Android 快照留了什么 → 编译器读了什么 →
Vulkan 实际做了什么 → 完成后谁结账」。用途是**合流前缺口盘点**：合入本地 iOS 主线
`origin/main@5561bd022` 的共享前端时，任何一行的「记录/字段来源/寿命」变化都必须回到这张表重核。

## 0. 读法与基线

**行号基线**：本分支合流前 HEAD `ce8bfc23d`（行号全部用 `git show ce8bfc23d:<path>` 取，不取工作树
实时内容）。检索时优先按符号名（`rec_draw`、`OP_BIND_TEX1`、`s2a_record_draw_state`）定位；
合流后行号会整体偏移。主线侧引用写成 `5561bd022:<file>:<line>`。

**代码简写**（单元格里只写简名，路径见下）：

| 简名 | 路径 |
|---|---|
| `hle_nvn.c` | `graphics/nvn/gfx/nvn/hle_nvn.c`（共享前端 = 生产者；分支侧行号 = ce8bfc23d） |
| `nvn_obj.h` | `graphics/nvn/gfx/nvn/nvn_obj.h`（记录载荷格式，前后端共用） |
| `vk_record.c` / `vk_record.h` | `android/native/direct/`（Android 回放/快照） |
| `first_draw.c` | `android/native/nvn/nvn_vk_first_draw.c`（Vulkan 图形录制） |
| `nvn_vk_draw.c` | `android/native/nvn/nvn_vk_draw.c`（程序查找/编译请求/draw builder） |
| `compile_facts.c` | `android/native/nvn/nvn_vk_compile_facts.c`（编译事实） |
| `input_identity.c` | `android/native/direct/input_identity.c`（规范身份编码） |
| `vk_clear.c` | `android/native/direct/vk_clear.c`（clear 队列化/同步路径） |
| `compute*.c` | `android/native/nvn/nvn_vk_compute.c` / `_bridge.c` / `_request.c` / `_texture.c` |
| `sampler.c` | `android/native/nvn/nvn_vk_sampler.c` |
| `texcache.c` | `android/native/nvn/nvn_vk_texcache.c` |
| `shim.c` | `android/native/nvn/mtl_vk_shim.c`（拍平 + 逐记录派发 + guest fence） |

**状态标记**（放在第一列）：

- ✅ 记录、快照、执行、结账四层都对得上；
- ⚠️ 链路存在但有损/有近似（注明是哪一段）；
- ❌ 记录里有、快照/执行丢了语义，且**不报错**；
- ⬜ 有记录但后端没有对应分支（或有意空实现），失败时准确报错或不影响画面；
- ➖ 该 NVN 调用在 Android 上无消费者（不适用）。

**读表约定**：「快照」指 Android 在回放期真正能拿到的字段（记录字节 + 自己的 `s2a_record_draw_state`
/ `S->st` / 纹理快照），不是「记录里有什么」。第 3 列与第 2 列的差值就是「记录有、快照丢」。

---

## 1. Draw 家族

> 生产者总入口：`rec_draw`（`hle_nvn.c:1620`）、`rec_draw_idx`（`hle_nvn.c:1621`）；载荷
> `p_draw`（`nvn_obj.h:260`）、`p_draw_idx`（`nvn_obj.h:261`）、`p_draw_idx_single`（`:262`）、
> `p_draw_tex`（`:281`）。短记录/隐含实例参数由 `draw_rec` / `draw_idx_rec` 还原（`nvn_obj.h:272-278`）。
> Android 侧统一在 `vk_record.c:1564`（builder 路径）与 `vk_record.c:1782`（未注册 builder 的回退路径）处理。

| NVN 调用 | 产生的记录与字段 | Android 快照保留了什么 | 编译器读取了什么 | Vulkan 实际执行了什么 | 完成后谁结账 |
|---|---|---|---|---|---|
| **DrawArrays**（非索引）✅ | `hle_nvn.c:1834` → `p_draw{prim, first, count, instances=1, base_instance=0}`；记录停在 `ind` 前（`hle_nvn.c:1620`），载荷 `nvn_obj.h:260` | `vk_record.c:1672-1676` 取 `prim/count/first/instances`；`s2a_record_draw_state` 字段见 `vk_record.h:86-96` | 只读拓扑（`compile_facts.c:233` `topology=nvk_input_topology(prim)`）；**不读** count/first/instances（身份编码 `input_identity.c:85-125` 无这些字段） | `first_draw.c:6426-6427` `vkCmdDraw(count, instances?:1, first+vertex_offset, 0)`；merge 模式并入 open pass（`int merge_draw = !fd_probe_enabled()`，`first_draw.c:4838`） | 帧队列批次 fence（`first_draw.c:1576`）→ slot retire 等 fence 后回收 arena（`first_draw.c:1214`、`:1268`）；程序结果 pin：`nvn_vk_draw.c:1559`（失败路径 `:1542`）；guest fence：`shim.c:280` 推回放上界、`shim.c:471/617` 在 present/flush 认完成 |
| **DrawArraysInstanced** ❌ | `hle_nvn.c:4065-4067` → `p_draw{pr, first, n, instances=inst, base_instance=bi}`（`nvn_obj.h:260` 有 `base_instance`） | `vk_record.c:1672-1676` **只赋 prim/count/first/instances**；`s2a_record_draw_state`（`vk_record.h:86`）**没有 base_instance 字段** | 不读（绘制参数不进编译身份） | `first_draw.c:6426-6427` `vkCmdDraw(..., firstInstance=0)` 硬编码 0 → **baseInstance 丢失，实例化的顶点起点错** | 同 DrawArrays（无额外结账） |
| **DrawElements / DrawElementsBaseVertex** ✅ | `hle_nvn.c:4063-4064` 委托 Instanced（`base_instance=0`、`instances=1`）→ `hle_nvn.c:1843-1846`；`p_draw_idx_single` 由 `draw_idx_rec` 补隐含 1/0（`nvn_obj.h:274-278`） | `vk_record.c:1665-1671`：`count`、`first=base_vertex`、`instances`、`base_vertex`、`index_address`、`index_type` | 不读 | `first_draw.c:6424` `vkCmdDrawIndexed(count, instances?:1, firstVertex=0, vertexOffset, firstInstance=0)`；`base_vertex` 经索引区间扫描变成 `vertex_offset`（`first_draw.c:6042-6066`） | 同 DrawArrays |
| **DrawElementsInstanced** ❌ | `hle_nvn.c:1843-1846` → `p_draw_idx{pr, itype, count, base_vertex, base_instance, instances, ibuf, ind...}`（`nvn_obj.h:261`） | `vk_record.c:1665-1671` 取到 `count/base_vertex/instances`；**`base_instance` 有字段可读却未拷贝**，`ds` 也无处存 | 不读 | `first_draw.c:6424` `firstInstance=0`；`index_type` → `VK_INDEX_TYPE_UINT8/16/32`（`first_draw.c:6094-6100`），索引宽度本身正确 | 同 DrawArrays |
| **DrawArraysIndirect** ❌ | `hle_nvn.c:1842` → `p_draw{prim, 0,0, instances=1, base_instance=0, ind=GA(ind)}`；参数由 GPU 从 `ind` 读（`nvn_obj.h:260` 注释） | **builder 路径（生产）全程没有检查 `ind`**（`vk_record.c:1564-1780` 无该判定）；只有未注册 builder 的回退路径会拒绝（`vk_record.c:1782-1785`） | 不读 | `first_draw.c:6427` 用记录里的 `count=0` → `vkCmdDraw(0,1,first,0)`：**静默空画**，不报错 | 命令照常提交/结账（语义已丢） |
| **DrawElementsIndirect** ❌ | `hle_nvn.c:4136-4137` → `p_draw_idx{..., count=0, base_vertex=0, instances=1, ind=GA(ind)}` | 同上一行：`vk_record.c:1564-1780` 无 `ind` 判定 | 不读 | `first_draw.c:6424` `count=0` → **静默空画** | 同上一行 |
| **MultiDrawArraysIndirectCount / MultiDrawElementsIndirectCount** ❌ | `hle_nvn.c:4073-4076`（indexed）/ `:4077-4080`（arrays）：每个 `mdi_i` 一条记录，`ind=ind+i*stride`、`mdi_cnt=GA(cnt)`、`mdi_i=i`；上限 `MDI_MAX=1024`（`hle_nvn.c:4072`） | 同间接绘制：`ind/mdi_cnt/mdi_i` 不进 `ds`；builder 路径无判定（`vk_record.c:1564-1780`），回退路径拒绝（`vk_record.c:1782-1785`） | 不读 | `first_draw.c:6424/6427` 全部按 `count=0` 空画 → **整片 GPU 驱动场景不绘制** | 同间接绘制 |
| **DrawTransformFeedback** ❌ | `hle_nvn.c:3636` → `p_draw{.prim, .count=1, .instances=1, .tfc=addr}` | `vk_record.c:1672-1676` 取 `count=1`、无 `tfc` 字段（`vk_record.h:85-87`） | 不读 | `first_draw.c:6427` 用 `count=1` 画 1 个顶点（**不是拒绝**） | 同 DrawArrays |
| **DrawTexture** ⬜ | `hle_nvn.c:1836-1839` → `OP_DRAW_TEX` + `p_draw_tex{handle, dst[4], src[4]}`（`nvn_obj.h:281`） | `vk_record.c` 的 switch **没有 `OP_DRAW_TEX` 分支** → `vk_record.c:2565` default | 不读 | 无（准确失败：`opcode has no Android Vulkan decoder yet`） | 无（失败即返回 `S2A_RECORD_UNSUPPORTED`，上层 `shim.c:429` 红再 abort） |
| **绘制参数（横切补充）** ❌ | 记录里都有：`base_instance`（`nvn_obj.h:260-261`）、间接地址 `ind`、multi-draw `mdi_cnt/mdi_i`、`tfc` | `s2a_record_draw_state`（`vk_record.h:81-147`，绘制参数在 `:85-87`）只有 `count/first/instances/base_vertex/index_address/index_type` | 不读（§8.5.10「绘制参数不进键」；`input_identity.c` 全文无绘制参数） | `first_draw.c:6424-6427`：`firstInstance` 恒 0；间接/multi-draw/tfc 全部按记录里的 0/1 执行 | 同上 |

**这批的结论**：`DrawArraysInstanced` 的 `baseInstance` 与所有间接/multi-draw 路径都是
「记录有、快照丢」，其中间接与 multi-draw 在**生产 builder 路径上连拒绝都没有**（`vk_record.c:1782-1785`
的拒绝只覆盖未注册 builder 的回退路径）。这与 `direct-capability-matrix.md` §2.6 P0#1 一致，但现象比
P0#1 写的更重：不是「拒绝在生产 builder 之后」，而是生产路径根本没有拒绝分支。
生产环境一定走 builder 路径：adapter 在该线程首次执行时注册 `s2a_record_set_draw_builder(nvk_draw_builder, ...)`
（`5561bd022` 与分支同一位置，分支侧 `mtl_vk_adapter.c:902`），所以 `vk_record.c:1704-1712` 那段拒绝
在真机上不可达。

---

## 2. 状态与绑定

| NVN 调用 | 产生的记录与字段 | Android 快照保留了什么 | 编译器读取了什么 | Vulkan 实际执行了什么 | 完成后谁结账 |
|---|---|---|---|---|---|
| **SetRenderTargets** ✅ | `hle_nvn.c:1652-1662`：紧凑头 `p_set_rt_c` + 每槽 `tex_t` 快照 + `view_t`（`nvn_obj.h:156-188`）；`n>8` 被夹到 8（`hle_nvn.c:1653`） | `vk_record.c:1291-1378`：`set_rt_rec` 还原，再**二次拷贝对象头** `S->rt_snap`（`vk_record.c:1370-1375`）与 view；draw 时装入 `ds.rt[]`（`vk_record.c:1582-1603`）、深度进 `ds.depth_key/has_depth/dview`（`:1604-1640`） | `rt_count`（`compile_facts.c:233`）、颜色槽格式→`fragmentOutputTypes`（`compile_facts.c:278-293`）、`has_depth/depth_only` 与 `transform_feedback` 进请求（`nvn_vk_draw.c:729-732`） | pass 复用判定 `fd_pass_continues`（`first_draw.c:2120`）、rp 缓存/新建、fb 取得（`first_draw.c:2171`）、`fd_pass_begin`（`:2890`）、反馈采样快照（`:4537`） | pass 归 rp 缓存或帧队列（`first_draw.c:5298/5307`）；fb 归 fb 缓存/帧队列；附件纹理 pin 到本帧（`first_draw.c:4935/5036`）→ present 解除（`first_draw.c:1720`、`nvn_vk_first_draw_present_done` 在 `:3735`） |
| **BindTexture（单条组合句柄）** ⚠️ | `hle_nvn.c:4025-4028`：`p_bind_tex1{stage, slot, h, tbase, sbase}`，`offsetof(h)==8` 静态断言（`hle_nvn.c:4029`）——句柄落在记录 +16B，正是硬件命令里游戏原位改写的位置；`bind_rec` 折成 `p_bind_handles`（`nvn_obj.h:249-255`） | `vk_record.c:2163-2175`：`bind_rec` 后写 `S->st.tex_handle[stage][slot]`（组合句柄，低 20 位纹理、高 20 位采样器）；`slot>=32` 直接丢弃（`vk_record.c:2188`） | 纹理事实：`nvn_vk_draw.c:1104`（`nvk_fill_textures`）→ 请求 `textures[]`（`nvn_vk_draw.c:782-783`）；句柄只作事实来源，不进程序键 | 逐 binding 解析：`tex_by_id`→texcache→视图覆盖→采样器→`fd_pin_tex`（`first_draw.c:5906-6006`）；描述符每笔 `vkUpdateDescriptorSets`（`first_draw.c:6228`） | 纹理 pin 到本帧（`first_draw.c:1694`、`:5036`），present 统一解除；描述符 set 归帧池（`first_draw.c:3300`），帧 flush 后释放 |
| **BindTextures（数组 / 一次 n 条）** ✅ | `hle_nvn.c:4029` → `bind_handles`（`hle_nvn.c:1800-1813`）→ `p_bind_handles{stage, first, n, defer=0, h[n]}`（`nvn_obj.h:241`）；按实际 `n` 分配（`hle_nvn.c:1626-1629` `RECN`） | `vk_record.c:2176-2205` 逐条写 `tex_handle[stage][first+i]`；`slot>=32` 丢弃（`vk_record.c:2188`） | 同上一行 | 同上一行；**shader 侧描述符数组未实现**：布局恒 `descriptorCount=1`（`first_draw.c:798`），反射数组绑定只能退化成逐槽单个 | 同上 |
| **BindTexturesDeferred / BindImagesDeferred / BindSeparate\*Deferred** ❌ | `hle_nvn.c:4033-4036`（纹理）、`:4043-4057`（image / 独立纹理 / 独立采样器）→ `p_bind_handles{defer=1, src=游戏句柄数组地址, h[] 全 0}`（`nvn_obj.h:241`） | `vk_record.c:2163-2205` **只调 `bind_rec`，不读 `defer`/`src`** → `h[]` 全 0 → 绑定到 **texture id 0**。对照：Deferred 的 UBO/SSBO 有分支（`vk_record.c:2132-2141` 回放时读 `NVNbufferRange`） | 用 id 0 的纹理事实（静默错） | 采样 id 0 的纹理（静默错） | 不报错、不失败，pin 的是错误纹理 |
| **BindSampler（组合句柄里的采样器 id）** ⚠️ | 无独立 NVN 入口；采样器 id 是 `BindTexture` 句柄的高 20 位（`nvn_obj.h:251-255` `bind_rec` 拆位），编号基址 `samp_base` 在录制时加上（`hle_nvn.c:1800-1813`） | `vk_record.c:2194-2197` 存整体组合句柄；draw 时拆出 `sid`（`first_draw.c:5913`） | 采样器描述进纹理事实（`nvn_vk_draw.c:640-700` 的 `nvk_fill_textures`）；只影响采样兼容性判断，不影响产物字节 | `samp_by_id`→`nvn_vk_sampler_cache_get_for_view`（`first_draw.c:5932-5941`）→`nvn_vk_sampler_from`（`sampler.c:52`）。**近似**：MirrorClamp/MirrorClampToEdge→MIRRORED_REPEAT（`sampler.c:6`）、自定义 border 色→不透明黑（`sampler.c:74-77`）、reduction 未落创建参数 | 采样器对象归采样器缓存（`first_draw.c:657` `fd_samp_cache`），无逐笔结账；设备销毁时随缓存释放 |
| **BindSeparateTexture(s)（独立纹理）** ⬜ | `hle_nvn.c:1818-1820`（复数）/ `:1821`（单条）→ `OP_BIND_TEX` 且 `first=NVN_SEPTEX_SLOT0(128)+i`（`hle_nvn.c:1818`）；deferred 版 `:4053-4055` | `vk_record.c:2188` `slot>=32` → **静默丢弃**（快照数组只有 32 槽，`vk_record.h:125`） | 反射解析把 128+ 槽映射后直接置 -1（`nvn_vk_program_result.c:283-288`），不参与事实 | draw 时重新算出 128+ 槽并**准确失败**：`first_draw.c:5899-5905` "not a supported combined slot" | 失败返回 `S2A_RECORD_UNSUPPORTED`，`shim.c:429` 红 |
| **BindSeparateSampler(s)** ⚠️ | `hle_nvn.c:1822-1826` → `OP_BIND_SAMP`，`first` 原样（**不加 128**，与独立纹理不同） | `vk_record.c:2194-2197` 存进与组合采样器相同的 `samp_handle[stage][slot]`；无独立表 | 同组合采样器 | 同组合采样器 | 同组合采样器。**风险**：两类绑定共用槽位号，同一 slot 后绑者覆盖先绑者（生产侧与消费侧一致，但与硬件两张表不同，未见负例） |
| **BindImage（storage image）** ⬜ | `hle_nvn.c:1806-1809`（单条）/ `:1814`（数组）→ `OP_BIND_IMG`；deferred `:4050-4052` | `vk_record.c:2191-2193` **只对 `stage==5`（compute）** 存 `cs_image_handle`；图形阶段没有存储分支 | compute：image 句柄进请求/反射校验（`compute.c:187-196`） | compute：descriptor kind 3（`compute.c`）；图形：无消费者 | compute 走 `nvn_vk_compute_build` 的 descriptor set/帧池；图形无结账 |
| **UpdateUniformBuffer** ✅ | `hle_nvn.c:1600-1605`：**录制时把数据拷进命令记录**（NVN 语义：录制后游戏可改原缓冲）；载荷 `OP_UPDATE_UB{addr,size,data}` | `vk_record.c:1993-2001`：回放到这里立即 `memory->write` 到 guest 内存；`last_ub_*` 只在 `debug.s2a.ub_diag=1` 时记 | 不读内容；只读 `ubo_use` 掩码（`vk_record.c:1645`，注意仍按 `(bound<<3)&0x1f` 截断，见 §2.6 P0#2） | draw 时把 guest 内存里该 UBO 范围拷进 arena（`first_draw.c:5750-5752`），再写描述符 | arena 切片按提交封存（`first_draw.c:3286` `fd_arena_seal_submit`），提交完成、slot 退休后整块回收（`first_draw.c:1268`/`:3164`） |
| **BindUniformBuffer(s) / BindStorageBuffer(s)（含 Deferred）** ✅ | 非 deferred：`hle_nvn.c:1780-1791` → `p_bind_buf{stage, index, addr, size}`（`nvn_obj.h:238`）；deferred：`hle_nvn.c:1794-1799` → `stage|BIND_BUF_DEFER`、`addr = 游戏 NVNbufferRange 地址`（`nvn_obj.h:237`） | `vk_record.c:2118-2161` 两条都接：deferred 在回放时读 `NVNbufferRange` 并用 `nvn_ga2ca` 换地址（`vk_record.c:2132-2141`）；逐槽置/清 `ubo_bound/ssbo_bound` | `ubo_use[stage]` 掩码 + SSBO 对齐（`compile_facts.c:258-259`）；SSBO 地址/大小不进键 | draw 时逐 binding 取地址、拷进 arena（UBO `first_draw.c:5750-5752`，SSBO `first_draw.c:5789-5880`） | 同 UpdateUniformBuffer（arena 按提交回收） |

**其它同链状态记录**（不在五批清单里，但同一条记录流必须一起核，合流时容易漏）：

| 记录 | 生产 | Android 消费 | 结论 |
|---|---|---|---|
| `OP_VIEWPORTS`（多视口） | `hle_nvn.c:1677-1681`（按实际 n 录，最多 16，`RECN`） | 快照只留 `vp[0]`（`vk_record.c:1630-1634`），`vkCmdSetViewport(0,1,...)` 只设 index 0（`first_draw.c:6377`） | ⚠️ 多视口丢；单视口正确 |
| `OP_SCISSOR`（单条） | `hle_nvn.c:1683`；`SetScissors` 多值只取 index 0 并打一行日志（`hle_nvn.c:4142-4145`） | `vk_record.c:2036-2043` 存单值；`vkCmdSetScissor(0,1,...)`（`first_draw.c:6381`） | ⚠️ 多 scissor 丢（生产侧已提示） |
| `OP_DEPTH_RANGE` | `hle_nvn.c:1684`（多值版 `SetDepthRanges` 只取 index 0，`hle_nvn.c:4146-4149`） | `vk_record.c:2044-2050` 存 `dr_n/dr_f`，进 `vp_near/vp_far`（`vk_record.c:1624`）→ 视口深度范围 | ✅ |
| `OP_STENCIL`（SetStencilRef/Mask/ValueMask） | `hle_nvn.c:1828-1830` | `vk_record.c:2246-2253` 只存 `S->st.stencil_*`，**first_draw 从不消费**（grep 0 命中） | ⬜ 有分支、空实现；stencil 实际来自 `BindState` 状态对象（`first_draw.c:4706`） |
| `OP_POLY_OFFSET` | `hle_nvn.c:1831-1833` | `vk_record.c:2239-2245` 只存 `poly_factor/units/clamp`，**first_draw 不消费** | ⬜ 空实现；poly 来自 `state_obj[4]`（`first_draw.c:4673`） |
| `OP_DEPTH_CLAMP` | `hle_nvn.c:4180`（`SetDepthClamp`） | `vk_record.c:2267-2272` 存 `depth_clamp_on`，**first_draw 不消费**（`rs.depthClampEnable` 未设置） | ⬜ 空实现 |
| `OP_PRIM_RESTART` | 生产 `hle_nvn.c` | `vk_record.c:2260-2266` 存字段，first_draw 不消费 | ⬜ 空实现 |
| `OP_VP_SWIZZLE` | `hle_nvn.c:4174-4177`（`first`,`n` + 异或掉恒等值，见 `nvn_obj.h`） | `vk_record.c:2254-2259` memcpy 后丢弃 | ⬜ 空实现 |
| `OP_RENDER_COND` | 只在 `DM_GAME_RENDER_COND` 下录（`hle_nvn.c:4167-4174`，`SetRenderEnable`/`SetRenderEnableConditional`），否则只打红一次 | `vk_record.c:2273-2278` 存 `render_cond_mode`，draw 不消费 | ⬜ 空实现 |
| `OP_RAST_DISCARD` | 生产 `hle_nvn.c` | `vk_record.c:2388-2393` memcpy 丢弃 | ⬜ 空实现 |
| `OP_TF_BIND` / `OP_TF_STATE` | `hle_nvn.c`（BindTransformFeedbackBuffer / Begin/End） | `vk_record.c:2371-2387`：`TF_BIND` 丢弃，`TF_STATE` 只置 `tf_enabled`（进编译事实 `nvn_vk_draw.c:731`），**无 TF 输出落地** | ⬜ TF 只影响编译开关，缓冲区绑定不落地 |

---

## 3. 事件与同步

| NVN 调用 | 产生的记录与字段 | Android 快照保留了什么 | 编译器读取了什么 | Vulkan 实际执行了什么 | 完成后谁结账 |
|---|---|---|---|---|---|
| **SignalEvent** ❌/⚠️ | `hle_nvn.c:1577-1583` → `OP_SIGNAL_EVENT{事件值地址, 方式, 值}`；**`loc`（SignalLocation）与 `flags` 被丢弃**（`:1578` `(void)loc; (void)flags;`） | `vk_record.c:2410-2420`：先按 `op_breaks_pass` 关当前 pass（`vk_record.c:1221-1245`；`sync` 列表在 `vk_record.c:1235-1237`，`OP_SIGNAL_EVENT` 不在其中，只关**不 flush 不等**），再直接读改写 guest 事件值 | 不读 | 无 GPU 指令；只有 guest 内存写 | 无完成证明：写值时前序 draw 只在帧队列里排队，GPU 可能还没执行（§2.6 P0#4） |
| **WaitEvent** ⬜（分支侧未录） | `hle_nvn.c:1574-1576`：**不录记录**，首次调用打一条红日志（`not a recorded, the GPU does not wait`） | 无记录可消费 | — | 无 | — |
| **WaitEvent**（主线段 `5561bd022`）❌ 合流风险 | `5561bd022:hle_nvn.c:1685-1690`：录成 `OP_SIGNAL_EVENT`，`mode |= NVN_EV_WAIT(0x80000000)`（`5561bd022:nvn_mtl.h:37`） | Android 的 `OP_SIGNAL_EVENT` 分支只按 `mode ? cur+value : value` 处理（`vk_record.c:2414-2418`）→ **把 WAIT 当成信号累加，写坏事件计数器**，不会等待 | 不读 | 无（且 fprintf 之外无报错） | 无 |
| **Barrier** ⬜ | `hle_nvn.c:1855` → `OP_BARRIER{bits}`（8 字节载荷） | `vk_record.c:2394-2396`：**空实现**，注释理由是「同步后端每条记录都已等过 GPU」 | 不读 | **不发 `vkCmdPipelineBarrier`**；顺序靠 pass close 的附件 barrier（`first_draw.c:1989` 起的 close 路径）+ 同队列串行 | — |
| **FenceSync** ✅ | `hle_nvn.c:1584-1588` → `OP_FENCE_SYNC{NVNsync 地址}`；`cond`/`flags` 丢弃（`:1585`） | `vk_record.c:2397-2409`：在 `OP_FENCE_SYNC` 的 pass_break（**sync=1**，`vk_record.c:1235-1237` 的列表含它）之后，往 guest `sync_t` 写 `fenced=1, fence=0` | 不读 | 无 GPU 指令；写入前已 flush+等完成 | 完成证明 = `nvn_vk_first_draw_flush()`（`first_draw.c:3700`）在写之前返回 0 |
| **WaitSync**（命令缓冲内 GPU 等待）⚠️ | `hle_nvn.c:1568-1572` → `OP_WAIT_SYNC{NVNsync 地址}` | `vk_record.c:2539-2569`：读 guest `fenced` 位，最多轮询 1000×1 ms | 不读 | 无 GPU 等待对象：本队列的栅栏在回放到这里时已成立（FenceSync 已置位）；跨队列则 1 s 后**准确失败** | 无（失败即 `S2A_RECORD_UNSUPPORTED`） |
| **ReportCounter / ResetCounter**（邻近，供上下文）✅/⬜ | `hle_nvn.c:1588-1594`；`ReportCounter` 24B、`ResetCounter` 16B | `vk_record.c:2421-2522`（report）/ `:2512-2538`（reset）：samples-passed 走真实 query，timestamp-top 走队列化时间戳；**其它 counter type 准确失败** | 不读 | `nvn_vk_query_*`（report 默认只入队，帧完成点写回；`debug.s2a.query_wait=1` 回同步） | query 按提交批次归属（`nvn_vk_query_batch_submitted`，`first_draw.c:1620` 附近），完成后退休 |

---

## 4. 复制与清除

| NVN 调用 | 产生的记录与字段 | Android 快照保留了什么 | 编译器读取了什么 | Vulkan 实际执行了什么 | 完成后谁结账 |
|---|---|---|---|---|---|
| **CopyBufferToTexture（B2T 上传）** ⚠️ | `hle_nvn.c:1859-1862` → `OP_COPY_B2T` + `p_copy_b2t{src, tex 快照, view, has_view, r, flags, row_stride, image_stride}`（`nvn_obj.h:284`）；stride 来自录制时的 `copy_row/image_stride`（`hle_nvn.c:1885-1889`） | `vk_record.c:1776-1799` 全字段读入；**`flags`/`has_view`/`xoffset/yoffset/zoffset` 任一项非零即准确拒绝**（`:1783-1786`），部分尺寸也拒绝（`:1788-1790`） | 不读 | `copy_image_buffer`：host-visible staging + `vkCmdCopyBufferToImage` + submit **等 fence** + 释放（`vk_record.c:1059-1119`）；B2T 后 `mark_written`（`:1796-1798`，实写在 `:1797`） | staging/内存进保留账本（`rec_keep` 结构 `vk_record.c:448-460`；`submit()` 等 fence 失败时 `rec_retain`，`vk_record.c:623-625`）；正常完成则立即销毁，`REC_SUBMIT_INCOMPLETE` 时保留到设备销毁 |
| **CopyTextureToBuffer（T2B 读回）** ⚠️ | `hle_nvn.c:1864-1867` → `OP_COPY_T2B` + 同一 `p_copy_b2t`（`src` 存目标 buffer 地址） | 同 B2T 的整幅/无 flags/无 view/无 offset 限制（`vk_record.c:1783-1790`） | 不读 | 同上 + 完成后 `mem->write` 回 guest（`vk_record.c:1116-1117`）；T2B 不登记 `mark_written`（只读图像） | 同 B2T |
| **CopyTextureToTexture（T2T）** ⚠️ | `hle_nvn.c:1879-1883` → `p_copy_t2t{src 快照, dst 快照, sv/dv + has_sv/has_dv, sr, dr, flags}`（`nvn_obj.h:287`） | `vk_record.c:1810-1848`：`flags`/`has_sv`/`has_dv` 或任何 offset、宽高深不一致 → 准确拒绝（`:1815-1822`） | 不读 | `gpu_copy_image`：`vkCmdCopyImage` + barrier + submit 等 fence（`vk_record.c:1024-1057`）；`mark_written(dst)`（`:1833-1836`） | 同 B2T（无 staging，`rec_keep` 不挂） |
| **CopyBufferToBuffer（B2B）** ✅ | `hle_nvn.c:1594-1598` → `OP_COPY_B2B{src, dst, n}`；`flags` 丢弃（`:1595`） | `vk_record.c:1283-1290`：读 src/dst/bytes | 不读 | `gpu_copy`：两块 staging + `vkCmdCopyBuffer` + submit 等 fence + `mem->write` 回 guest（`vk_record.c:1121-1150`） | 同 B2T（两块 staging 进 `rec_keep`） |
| **ClearColor / ClearColori / ClearColorui** ✅/⚠️ | `hle_nvn.c:1663-1673` → `p_clear_color{index, mask, rgba[4]}`（`nvn_obj.h:190`）。**整数变体统一按 float 记录**（`:1668-1673`）：2^24 内精确，`0xffffffff` 四舍五入到 2^32（注释自述） | `vk_record.c:1383-1518`：按当前颜色目标快照、视图覆盖（mip/层/格式）与 mask 分路；整幅+mask 0xF 走 `s2a_vk_clear_color_queued`（`:1464-1467`），否则 `pass_break(1)` 后同步清（`:1470-1488`） | 不读 | 队列化：`vk_clear.c:614-671` 建 pass/fb/view + 录制整幅 clear + `nvn_vk_first_draw_clear_enqueue`（`first_draw.c:2075`）；退回同步：`s2a_vk_clear_color`（`vk_clear.c:745` 起，内部 `clr_submit` 在 `:385-440` 提交并等 fence） | queued 归帧队列命令缓冲；fb/view 归 clear 自身的 `clr_fv` 缓存（`vk_clear.c:600-612`）；同步路径由 `rec_keep` 结算 |
| **ClearDepthStencil** ✅ | `hle_nvn.c:1674-1675` → `p_clear_ds{depth, depth_mask, stencil, stencil_mask}`；`depth_mask` 经 `B(x)=x&0xff`（`hle_nvn.c:141`）保留低 8 位 | `vk_record.c:2269-2370`：按命令位置立即执行；深度掩码非 0 即整面清、stencil 掩码按位（`vk_record.c:2283-2302`）；部分 stencil 走「清除绘制」表达，不降级 | 不读 | 队列化 `s2a_vk_clear_ds_queued`（同 ClearColor）；表达不了退回 `pass_break(1)` + `s2a_vk_clear_ds`（`vk_record.c:2327-2336`） | 同 ClearColor |
| **ClearTexture（float/int/uint）** ⚠️ | `hle_nvn.c:1870/1873/1876`（float/int/uint 三个入口）→ `p_clear_tex{tex 快照, view, has_view, value_type, r, mask, 值}`（`nvn_obj.h:289`） | `vk_record.c:1983-1992` 读入；**`view`/`has_view` 被忽略**：`gpu_clear_texture`（`vk_record.c:1001-1022`）只看 `r` 与 `mask` → **mip/层/格式覆盖丢失** | 不读 | 三路：mask≠0xF → CPU 侧部分清（`clear_image_partial_cpu`）；区域 ≠ 整幅 → `clear_image_region_copy`；整幅 → `gpu_clear_image`（`vk_record.c:1008-1021`） | `gpu_clear_image` submit 等 fence；部分清走 CPU→上传，由纹理缓存/`mark_written` 记录 |
| **ClearBuffer** ✅ | `hle_nvn.c:4158` → `p_clear_buf{addr, size, value}`（`nvn_obj.h:290`）；`size % 4` 与 `MAX_COPY` 在消费端校验 | `vk_record.c:1274-1282` | 不读 | `gpu_fill`：staging + `vkCmdFillBuffer` + submit 等 fence + `mem->write` 回 guest（`vk_record.c:654-684`） | 同 B2B（`rec_keep` 保留账本） |

---

## 5. compute

| NVN 调用 | 产生的记录与字段 | Android 快照保留了什么 | 编译器读取了什么 | Vulkan 实际执行了什么 | 完成后谁结账 |
|---|---|---|---|---|---|
| **DispatchCompute** ✅ | `hle_nvn.c:1848-1852` → `OP_DISPATCH` + `p_dispatch{x,y,z,caller}`（`nvn_obj.h:279`）；`caller` 是游戏调用点返回地址 | `vk_record.c:1859-1931`：`s2a_record_dispatch_state`（`vk_record.h:155-176`）从 `S->st` 的 stage 5 取：keys/serial、groups、pool 容量与 seen、ubo/ssbo/tex/samp/image 快照 | 源快照（code/control/c1）+ profile + `localMemoryBytes` + `hasUnalignedStorageBuffer` + 纹理事实；请求体 `compute_request.c:304-340`（JSON 组装），身份编码 `:290-299` | `nvn_vk_compute_build`（`compute_bridge.c:31` 起）→ `vkCmdBindPipeline` + `vkCmdBindDescriptorSets` + `vkCmdDispatch` + SHADER_WRITE→HOST barrier + submit（`vk_record.c:1932-1948`） | `rec_keep.compute_owner/finish`（`vk_record.c:1944-1948`）；finish 在 fence 完成后做 copyback；`REC_SUBMIT_INCOMPLETE` 时整组保留到设备销毁（`vk_record.c:1865-1871` 先查保留账本容量） |
| **DispatchComputeIndirect** ⬜ | `hle_nvn.c:1854-1857` → `p_dispatch{x=0,y=0,z=0,caller, ind=GA(ind)}` | `vk_record.c:1856-1860`：**`dispatch.ind` 即准确拒绝**（`indirect dispatch needs GPU-written group counts (not wired yet)`） | 不读 | 无 | 无 |

---

## 6. 汇总一：「记录有、快照丢」清单

按「记录里确实有字段（生产者写了）→ Android 快照/执行没有对应」判：

1. **`base_instance`（实例化起点）**：`hle_nvn.c:4065-4067`（DrawArraysInstanced 写 `instances=inst, base_instance=bi`）、
   `hle_nvn.c:1843-1846`（DrawElementsInstanced 写 `base_instance=bi`）；载荷 `nvn_obj.h:260-261` 都有；
   `vk_record.c:1665-1676` 未拷贝，`vk_record.h:86` 无字段；`first_draw.c:6424/6427` 硬编码 `firstInstance=0`。❌
2. **间接绘制参数地址 `ind`**：`hle_nvn.c:1842`（arrays）/`:4136-4137`（indexed）；载荷 `nvn_obj.h:260-261`；
   生产 builder 路径 `vk_record.c:1564-1780` 无判定，回退路径 `vk_record.c:1782-1785` 才拒绝。❌
3. **multi-draw `mdi_cnt`/`mdi_i`**：`hle_nvn.c:4073-4080`；载荷同上；同样只在回退路径被拒（`vk_record.c:1782-1785`）。❌
4. **`tfc`（DrawTransformFeedback 的计数地址）**：`hle_nvn.c:3636`；`nvn_obj.h:260`；`vk_record.c:1672-1676` 只取 `count=1`，
   `first_draw.c:6427` 当成 1 个顶点。❌
5. **`p_bind_handles.defer` / `src`（Deferred 绑定）**：`hle_nvn.c:1794-1799`（buffer 版有消费者）、
   `:4033-4036` / `:4043-4057`（句柄版）；`vk_record.c:2163-2205` 不读这两个字段 → 句柄全 0，绑到 id 0。❌
6. **`p_clear_tex.view` / `has_view`**：`hle_nvn.c:1870/1873/1876` 记录 view；`vk_record.c:1001-1022` 的
   `gpu_clear_texture` 只用 `r`+`mask` → ClearTexture 的 mip/层/格式覆盖丢失。⚠️（不报错）
7. **多视口 / 多 scissor**：`hle_nvn.c:1677-1681` 录 `first..n`；`vk_record.c:1630-1634` 只留 `vp[0]`；
   `first_draw.c:6377/6381` 只设 index 0。scissor 的多值入口已在生产侧提示（`hle_nvn.c:4142-4145`）。⚠️
8. **`p_clear_color` 的整数精度**：`hle_nvn.c:1668-1673` 把 int/uint 统一存 float（2^24 以上有舍入），
   不是丢字段但属有损记录。⚠️（注释已自述）
9. **`p_set_rt.n > 8`**：生产侧夹到 8（`hle_nvn.c:1653`），记录层丢，但 NVN 契约本身就是 8 槽。➖
10. **`SignalEvent` 的 `loc`/`flags`**：`hle_nvn.c:1578` 直接丢弃；记录里没有「信号发生在 draw 前/后」的语义。❌
11. **`FenceSync` 的 `cond`/`flags`**：`hle_nvn.c:1585` 丢弃。⚠️（当前消费者只置 fenced）
12. **`CopyBufferToBuffer` 的 `flags`**：`hle_nvn.c:1595` 丢弃。⚠️（未见游戏用非零）

> 另：`BindTexture` 的单条句柄不是「丢字段」而是「读的来源不同」——分支在**拍平时**拷字节
> （`hle_nvn.c:4025-4029` 把句柄写进记录 +16B），主线 `5561bd022:hle_nvn.c:1652-1655`
> 改为记录**游戏内存里的地址**（`BIND_TEX1_AT`），回放时再读（`5561bd022:nvn_obj.h:253-260`）。
> 见 §8 ②。

## 7. 汇总二：「前端有记录、后端无分支」清单

1. **`OP_DRAW_TEX`**（`hle_nvn.c:1836-1839`）：`vk_record.c` 无 case → `:2565` default 准确拒绝。⬜
2. **`OP_BIND_TEX`/`OP_BIND_SAMP`/`OP_BIND_IMG` 的 deferred 形态**（`hle_nvn.c:4033-4057`）：无 `defer/src`
   分支（`vk_record.c:2163-2205`）。对照 `OP_BIND_UBO/SSBO` 有（`vk_record.c:2132-2141`）。❌（静默错）
3. **独立纹理槽 128+**（`hle_nvn.c:1818-1821`）：快照 `slot>=32` 丢弃（`vk_record.c:2188`），draw 时准确失败
   （`first_draw.c:5899-5905`）。⬜（结果是拒绝，不是渲染）
4. **图形阶段 `OP_BIND_IMG`**（`hle_nvn.c:1806-1814`）：只有 compute（stage 5）存快照（`vk_record.c:2191-2193`），
   图形 stage 的分支不存在。⬜（图形 storage image 未实现，见能力矩阵 §2）
5. **`OP_WAIT_EVENT`**：分支侧前端就不录（`hle_nvn.c:1574-1576` 只打红）→ 后端无从接。⬜
   **合流后**：主线把它录成 `OP_SIGNAL_EVENT + NVN_EV_WAIT`，Android 现有分支会当成信号累加（`vk_record.c:2414-2418`）。❌
6. **`OP_BARRIER` 空实现**（`vk_record.c:2394-2396`）：有分支、不发 Vulkan barrier，理由是同队列串行 +
   pass close barrier。⬜（有意，但注释里的「同步后端已等过」在 merge/pass 合批后不再字面成立，见 §8）
7. **`OP_STENCIL` / `OP_POLY_OFFSET` / `OP_DEPTH_CLAMP` / `OP_PRIM_RESTART` / `OP_VP_SWIZZLE` /
   `OP_RENDER_COND` / `OP_RAST_DISCARD`**：都有 case（`vk_record.c:2236-2268`、`:2388-2393`），
   但 first_draw 全不消费（grep 0 命中）；管线状态来自 `BindState` 状态对象（`first_draw.c:4673-4714`）。⬜
8. **`OP_TF_BIND`**（`vk_record.c:2371-2376`）：memcpy 后丢弃；`OP_TF_STATE` 只影响编译事实。⬜
9. **shader 侧描述符数组**：布局恒 `descriptorCount=1`（`first_draw.c:798`）；NVN 数组式 `BindTextures`
   能逐槽存（§2），但反射成数组的 binding 无法表达。⬜（能力矩阵 §2「纹理/描述符数组」）
10. **`VK_EXT_custom_border_color` / sampler reduction**：`sampler.c:74-77` 只映射黑白透三色，
    reduction 未落到创建参数。⬜（能力矩阵 P0#3）
11. **`report-counter` 的 `type` 其它值**（`vk_record.c:2512-2538` reset / `:2421-2522` report）：
    samples-passed 与 timestamp-top 之外一律准确失败。⬜（有意拒绝）

## 8. 合流必查项（主线 `5561bd022` 的四类变化 → 受影响的行）

| 主线变化 | 代码证据 | 受影响的行 / 合流时要做的事 |
|---|---|---|
| **① 命令存储改用宿主块**（记录写进宿主块，设备游标模拟 AddCommandMemory） | `5561bd022:nvn_obj.h:101-121`（`cmd_t` 新增 `struct srec *rec`、`gstart/gcur/gend/vanc/hint/gvirt`）；`5561bd022:hle_nvn.c:1326`、`:1651-1656` | 全部行：记录的**地址来源**变了。Android 的 `clone_chain`（`shim.c:246-273`）按记录里的绝对指针跟进 `CALL/JUMP`，要确认宿主块里的 `OP_CALL/OP_JUMP` 目标仍可解析（宿主块用偏移还是宿主地址）。**必须先跑一拍含 CALL/JUMP 的真实链**，否则拍平会失败/截断 |
| **② 游戏修改已录制 BindTexture 时句柄读取来源变化** | 分支：`hle_nvn.c:4025-4029`（句柄写进记录 +16B，靠拍平拷最新字节）；主线：`5561bd022:hle_nvn.c:1652-1655` + `BIND_TEX1_AT`（记录游戏内存地址，回放时读） | **BindTexture（单条）** 行：合流后 `p_bind_tex1` 载荷多 8 字节地址（`5561bd022:nvn_obj.h:253-260`），`bind_rec` 会在回放时读 guest 内存。Android 侧 `vk_record.c:2163-2175` 走 `bind_rec` 即可自动跟随，但要确认：`p_bind_tex1` 尺寸校验（`vk_record.c:2171` 用 `sizeof(p_bind_tex1)`）与 `slot` 的 `BIND_TEX1_AT` 位（0x10000）不会把 slot 算错，且回放时读 guest 内存失败要准确报错 |
| **③ GPU 事件等待的录制与执行** | `5561bd022:hle_nvn.c:1685-1690`（WaitEvent → `OP_SIGNAL_EVENT + NVN_EV_WAIT`）；`5561bd022:nvn_mtl.h:35-37`（`NVN_EV_WAIT=0x80000000`）；`5561bd022:nvn_mtl.m:1693`（`ev_wait`） | **WaitEvent / SignalEvent** 行：Android 的 `OP_SIGNAL_EVENT` 分支（`vk_record.c:2410-2420`）必须先判 `NVN_EV_WAIT`，否则把等待记录当信号累加（写坏事件值）。Vulkan 侧没有跨队列事件等待原语，若真要等需要 CPU 侧有界等待 + 准确失败（可参照 `OP_WAIT_SYNC` 的 `vk_record.c:2539-2569` 做法），不能假装等到 |
| **④ CPU/GPU 混合纹理内容修正** | `5561bd022` 的 `b7a8c0980`（脏页轮询按「写过的页是否全在 GPU 写段内」判归属，`hle_nvn.c` +7/-2、`nvn_mtl.m` +20）、`e795549bd`（GPU 贴图级保留） | **BindTextures / Copy\* / Clear\*** 行：这类改动影响「谁的内容是当前版本」。Android 的对应账是 `mark_written`（`mtl_vk_adapter.c:481`，调用点 `vk_record.c:1484/1491/1509/1796/1835/2344/2350/2367`、`first_draw.c:6552-6553`）与 texcache 的内容检查。合流后要核：新增/改变的「GPU 写过」判定有没有对应到 `mark_written`；`p_copy_t2t` 的 dst、`p_clear_tex` 的 tex、`p_copy_b2t` 的 tex 是否都被登记（T2B 只读不登记） |

> **2026-11-06 补记（批 A'）**：Android 侧已有「CPU 精确写范围」通道，合流时第 5 列的内容归属要按它核对：
> `nvnMemoryPoolFlushMappedRange`（`hle_nvn.c:353`）经既有 Android 弱钩子 `s2a_vk_adapter_pool_written`（`mtl_vk_adapter.c`）
> 把地址+长度送进纹理缓存；`nvnTextureWriteTexels`（`hle_nvn.c:4551` 起）经新增 Android 弱钩子
> `s2a_vk_adapter_tex_written_rect` 送精确区域。若主线改动这两个 NVN 入口的调用点/参数，
> 必须同步核范围来源；没有范围的 CPU 写通知只算 hint（图像含 GPU 内容时 fail-closed）。

**合流验收建议**：对每一行做「记录字节不变性」检查——同一游戏同一帧，合流前后把
`graphics/nvn/gfx/nvn/nvn_obj.h` 里载荷的 `sizeof`/字段 offset 与 `hle_nvn.c` 的记录写入点逐项比对；
任何一行第 2 列变化，就必须重跑第 3–6 列的最小反例（P0 级别的行：间接/multi-draw、Deferred 绑定、
WaitEvent、ClearTexture 视图）。

## 9. 已知限制

- 本表只做**静态证据盘点**：没有运行游戏、没有真机、没有构造记录流反例；「❌ 静默空画」等结论来自
  「生产路径无该判定」的源码事实，实际触发条件（有游戏用间接/multi-draw 且走 builder 路径）仍需用
  真实命令流确认。
- 行号基线是 `ce8bfc23d`；合流后行号会变，尤其 `vk_record.c` 与 `hle_nvn.c`。
- 第 4 列「编译器读取了什么」只覆盖 Android 现用的 direct 编译请求（`s2a-direct-compile-v1`）；
  iOS 侧 Metal 的编译身份不在本表范围。
- 主线侧四类变化只按 `5561bd022` 的提交内容归纳；没有逐行执行合流后的联调。

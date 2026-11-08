# 直连层「完成证明」接口清单（批 B 用）

基线：`d63078ffd`（批 A 交付 `eb3e8a63a` + 诊断 `d63078ffd`）。**只读盘点**：本文不改代码、不判定设计，供批 B（提交与退休合同 + 预算背压）直接照做。行号以该基线为准，改动后自行复核。

口径（证据等级见 `android/docs/direct-capability-matrix.md` §4）：本文全部为 L（读代码），没有 S/A 级新证据。

## 1. 现有完成证明接口面（公共头 `nvn_vk_first_draw.h`，实现在 `nvn_vk_first_draw.c`）

| 接口 | 语义 | 返回 |
|---|---|---|
| `nvn_vk_first_draw_flush()`（`:3700`） | 提交积压命令并等完成（含延迟 present 收口）；`fd_fq_flush_impl(-1, 1, 0, 0)`，内部 5 s 上限，超时即终态 | 0 = 已完成；非 0 = 终态，命令缓冲与在途资源全保留 |
| `nvn_vk_first_draw_flush_ready(int64_t budget_ns)`（`:3705`） | **唯一带预算的证明面**；`budget_ns==0` = 纯状态探测（不关 pass、不提交，只查已提交 fence；有 open pass / 未封口批次 / 任一 fence 未 signal 都返回 1） | 0 = 已提交部分全部完成；1 = 已提交但仍有批次未完成（不是失败，资源/fence/命令保留）；-1 = 终态 |
| `nvn_vk_first_draw_pass_break(int sync)`（`:3088`） | 关当前 open pass；`sync!=0` 时把已录制前缀按队列顺序提交并等完成——**后续 GPU 操作的顺序保证全靠它** | 0 = 边界已落地（sync 时含完成证明）；非 0 = 无证明，帧队列进终态并保留在途资源 |
| `nvn_vk_first_draw_first_error()`（`:3738` 附近） | 帧队列首错原文（不覆盖、不丢首错） | 常量串，无失败为空串 |
| `nvn_vk_first_draw_present_done()`（`:3734`） | present fence 退休后解本帧纹理 pin 与逐帧查找缓存（不放 flush 里：同帧多次 flush 会提前 unpin） | — |
| `nvn_vk_first_draw_finish()`（`:3740`） | QueueFinish：提交积压 + 等完成，不销毁会话/设备；已终态返回 -2 不重试 | 0 = 已完成；非 0 = 提交/等待失败且资源保留 |
| `nvn_vk_first_draw_release_device(d)` | 真正销毁设备前丢旧设备的 fence/描述符池/管线缓存/arena 记账 | — |
| `nvn_vk_first_draw_present_deferred()` / `_deferred_retired()` | 延迟 present 模式 / 延迟槽已取得证明并回收的帧数（W6 资源退休账） | — |

内部状态机与保留表（`nvn_vk_first_draw.c`）：

- 状态：`FD_FQ_IDLE/RECORDED/SUBMITTED/COMPLETED/FAILED/TIMEOUT`（`:1088`）；`fd_fq_poisoned() = FAILED|TIMEOUT`（`:1351`），poisoned 后不再提交、不再释放（资源可能在 GPU 上）。
- 核心：`fd_fq_flush_impl(budget_ns, terminal_timeout, defer, frame_end)`（`:3344`），顺序必须是「关查询段与 render pass（`fd_pass_close`）→ 封口批次（`vkEndCommandBuffer`）→ 提交/等待」。
- 完成证明本体：`g_fq.fence`（后缀 fence）+ `batch_fence[FD_FRAME_BATCH_FENCES]`（`:1073`，早批次）+ `batch_seq[]`（arena 提交号）+ `batch_qid[]`（查询批次号）。
- 证明到手后统一释放：`fd_fq_reset()`（`:3382` 无在途早退、`:3467` 等完后、`:3694`）。
- 挂在帧队列上的保留表（`:1020-1078`，证明到手才释放；表满是 `fd_fq_fail` 终态）：`cmds[1024]`、`bufs[8192]`、`samps[2048]`、`pools[2048]`、`fbs[2048]`、`fbimg[2048]`（反馈快照）、`passes[2048]`、`pend` 管线[2048]、每笔 draw 的 `pbuf/pmem[1024]`。

调用点（批 B 的接缝）：

| 调用方 | 位置 | 用途 |
|---|---|---|
| 适配层 | `mtl_vk_adapter.c:366` | `flush()`：guest fence 的完成证明 |
| 适配层 | `mtl_vk_adapter.c:401` | `flush_ready(left)`：exec-owner suspend/stop 的预算等待（拿不到锁返回 2 = 没证明，不是设备错误） |
| 适配层 | `mtl_vk_adapter.c:317/357` | `finish()`（QueueFinish / stop） |
| 适配层 | `mtl_vk_adapter.c:539` | `present_done()` |
| 录制 | `vk_record.c:1231/1248` | 按 `op_breaks_pass()` 调 `pass_break(sync)` |
| 录制 | `vk_record.c:1480/2391/2501` | clear/copy 等 GPU 操作前 `pass_break(1)`，失败读 `first_error` |
| 查询 | `nvn_vk_query.c:242/271/279` | 页全在途时调**无预算** `flush()` 回收页（见 §4 疑点 3） |
| 上屏 | `nvn_vk_swapchain.c:571/596/812/85` | `flush_defer` / `present_done` / `deferred_retired` |
| 读回 | `nvn_vk_readback.c`（批 A） | 读 GPU 图像前 `pass_break(1)` |

## 2. 资源 owner × 现有完成证明

| owner | 现在靠什么 | 缺口（批 B 要统一的点） |
|---|---|---|
| 帧队列自身（cmd/buf/samp/pool/fb/pass/反馈快照/pend 管线/每笔 draw buffer） | fence ring + 保留表 + `FD_FQ` 终态；`fd_fq_reset` 统一释放 | 五状态只覆盖本帧；没有 per-resource Interface；`fd_fq_keep_*` 表满直接 `fd_fq_fail` 终态（无退化策略） |
| 纹理上传 staging/CB/fence（`nvn_vk_texcache.c:443`、局部合并 `:1460`） | 自有 fence，5 s 等；未知 → `tex_retained` 保留账本、条目 `upload_incomplete` 不可命中 | 5 s 与帧队列预算不同源；保留账本 `TEX_RETAINED_MAX=32`（`:30`）溢出只计数并返回 NULL（见 §4 疑点 1） |
| 纹理视图/底图 pin（`nvn_vk_texcache.c` 的 `pins` / `views[].pins`） | 证明来自帧队列：`present_done` / flush 后 unpin | pin 与证明之间没有显式合同（靠调用点约定）；`retired_release_if_idle` 只看引用归零，不看 GPU 证明 |
| 纹理版本化预算（批 A 的 `dirty_defer`，`nvn_vk_texcache.c` get_tex 的 pinned 分支） | `outstanding>=8 或 retired_bytes+vbytes>64 MB` 背压；defer 返回旧内容 | 用「数量/字节」代替真证明；批 B 换成「在途版本的提交 seq 有证明」，defer 时挂重试回调 |
| ReadTexels GPU 路径（`nvn_vk_readback_gpu.c:226`） | 自有 fence 5 s，poisoned 后拒用 | 同上，5 s 与统一预算不接 |
| 遮挡查询页（`nvn_vk_query.c`） | 页状态机 0 空闲/1 录制中/2 已提交未完成 + 批次号；flush 完成/批次退休后回收；`nvn_vk_query_batch_abandoned` 处理丢命令缓冲；页全在途 → 无预算 `flush()`（`:271-280`，`qp_in_flush` 递归保护） | 状态机私有；`flush()` 是 5 s 终态语义，不是可复用预算（见 §4 疑点 3） |
| compute（`nvn_vk_compute.c:66 finish(d, owner, completion)`） | 调用方给 completion：-2 = 无证明→保留全部句柄；-1 = 失败销毁；0 = 回写 | completion 由 bridge 传，不是从统一证明面取 |
| AHB 迁移（`nvn_vk_poolahb.c:614-619`） | 只在「本帧 fence 已全部等到」的完成点服务 + owner 窗口（`s2a_poolahb_owner_note_writers_stopped`） | 服务点是硬编码完成点，不是 Interface |
| present（`nvn_vk_swapchain.c:105 present_retain`、`:330` present fence 预算 `NVK_PRESENT_RETIRE_BUDGET_NS`、`swapchain.h:14 NVK_SC_RETAINED=8`） | present fence 证明 + 保留账 + `present_pending[]` 队列（`nvn_vk_swapchain_retire_present`） | 与帧队列不同源；`present_retain` 溢出静默丢账（见 §4 疑点 2） |
| 每线程缓冲 `nvn_vk_threadbuf` / 采样器 / 管线缓存 / 格式表 | CPU 侧对象 | ➖ 无需 GPU 证明 |

## 3. 统一 Interface 提案（形状，不预设实现）

- 提交面：`uint64_t seq = nvk_done_register(kind, handle)`——owner 提交时登记，内部挂到本次提交的 `batch_fence`/后缀 fence 的 seq。
- 查询面：`nvk_done_query(seq)` → 0 完成 / 1 未完成 / -1 终态（终态永不改判）；`nvk_done_budget_wait(seq, budget_ns)`；`nvk_done_terminal()`；`nvk_done_first_error()`。
- owner 回调：`on_complete(ctx)`（释放/回写）、`on_terminal(ctx)`（保留句柄、标记不可用）、`on_timeout(ctx)`（保留 + 报红计数）。
- 统一记账：把现散落的 `tex_retained[32]`、`sc->retained[8]`、query 页、`fd_fq_keep_*` 表都挂到同一张 owner 表；**有界 + 溢出即终态**，不许静默丢句柄。
- 预算背压落点（`dirty_defer`）：`nvn_vk_texcache.c` get_tex 的 pinned 分支把「数量/字节」换成「在途版本 seq 全部有证明」；defer 时把重试挂 owner 回调，证明到手后下一次 `get_tex` 重试。批 A 已把判定顺序调成「先定位变更 → 整覆盖/合并 → 版本化/预算」，批 B 只动预算分支即可，`nvk_sync_changed` 与 guest 账本不需跟着改。

## 4. 只读发现的句柄泄漏/误终态（批 B 第一批交付，Lead 已升 P0-leak）

1. **纹理上传保留账本满 → 句柄无人持有**（`nvn_vk_texcache.c:126-131`，`TEX_RETAINED_MAX=32`）：`tex_retain_slot()` 返回 NULL 后，`upload()` 的 fence/CB/staging（`upload_incomplete` 时还有 image/memory/view）既不销毁也不进账；调用方只记 `g_tex_retained_overflow++` 并返回 -2，会话继续跑 → 每溢出一组句柄泄到进程退出。`nvn_vk_texcache_release_retained()` 只结算表内的条目。
2. **present 保留表满 → 句柄丢账**（`nvn_vk_swapchain.c:105-116`，`NVK_SC_RETAINED=8`）：表满只打错误日志 return，fence/cmd 不进 `sc->retained[]`；`nvn_vk_swapchain_retire_present()` 只遍历 `sc->present_pending[]`（present fence 队列），`sc->retained[]` 的渲染 fence/cmd 由 `detach`/`Stop` 结算 → 溢出后这些对象无人再观察/释放。**注**：溢出发生在 `present_fail_state()` 之前（调用方随后把 swapchain 置终态、要求换窗口），所以不是静默继续跑，但句柄泄漏成立。
3. **查询页耗尽 → 无预算 `flush()` 可能把帧队列打成终态**（`nvn_vk_query.c:271-280`）：`nvn_vk_first_draw_flush()` = `fd_fq_flush_impl(-1, 1, 0, 0)`，`terminal_timeout=1`，5 s 内没等到就 `FD_FQ_TIMEOUT` 终态；一次页耗尽遇到慢/卡住的 GPU（或长于 5 s 的批次）就会把整个会话判死，而这里本来只是「页要回收」。批 B 应改成有界等待 + 挂回调（或调用 `flush_ready(budget)` 并接受返回 1 表示未完成）。

## 5. 与批 A 的边界

- 批 A（`eb3e8a63a`）只改内容版本与交接：`nvn_vk_texcache.c` 的子资源三态、guest 内容账本、局部合并、读回选路，以及 `nvn_vk_readback.c` 的选路；**没动**预算段（`dirty_defer` 仍是「返回旧内容」的原语义）、没动 `vk_record.c` / compute / `first_draw.c`。
- 批 A 新增的自有 fence（上传、局部合并矩形拷贝）与现有上传路径同口径（5 s + `tex_retained`），因此 §4 疑点 1 对它们同样成立。
- 批 A 的 `dirty_defer` 语义仍是矩阵 §2 的 ❌ 那格；批 B 改它时只需替换预算判据，不需要碰账本/合并逻辑。

// 遮挡查询（NVN_COUNTER_TYPE_SAMPLES_PASSED）在 Android 直连 Vulkan 后端的真实实现。
// 语义按共享 NVN 前端：Reset 清零；之后的绘制累加；Report 把“当时”的累计值写回 guest，
// Report 本身不清零（Reset → 绘制 → Report=累计 → 继续绘制 → 下一个 Report 更大）。
// Vulkan 的 occlusion query 只覆盖一个 render pass 内连续的绘制，所以按 render pass、Report、
// Reset 切段；Report 汇总“自上次 Reset 以来”的全部段。结果只在拿到完成证明（fence 已等到）后
// 读取并写回：读不到就准确失败，不写“全部可见”上界、不把未完成当 0。
// 线程：只由 s2a_vk_adapter 的 g_mu 保护的 exec/flush/present 路径调用。
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#include "vk_device.h"
#include "vk_record.h"

#ifdef __cplusplus
extern "C" {
#endif

// 返回码：0 = 成功；1 = 需要新建 pass（第一次 Reset 时当前命令缓冲还没有整池 reset）；
// 负值 = 准确失败（-1 = 设备/能力不支持；-2 = 资源/顺序/写入失败），why 里是原文。
enum { NVN_VK_QUERY_OK = 0, NVN_VK_QUERY_NEED_PASS = 1,
       NVN_VK_QUERY_UNSUPPORTED = -1, NVN_VK_QUERY_FAILED = -2 };

// 统计（诊断/验收用）。fails 是准确失败次数；samples 是已写回的真实样本数之和。
struct nvn_vk_query_stats {
    uint64_t resets, reports, segments, slots, samples, zero_reports, before_reset_reports, fails;
};
void nvn_vk_query_stats(struct nvn_vk_query_stats *out);

// OP_RESET_COUNTER(SAMPLES_PASSED)：结束当前段并把计数清零（开始新一轮）。
int nvn_vk_query_reset_run(struct s2a_vk_device *d, char *why, size_t why_size);
// OP_REPORT_COUNTER(SAMPLES_PASSED)：结束当前段并把本轮快照成待写回。
// 真正写 guest 发生在完成证明之后（nvn_vk_query_resolve），所以调用方必须先等 fence。
int nvn_vk_query_report(struct s2a_vk_device *d, const struct s2a_record_memory *memory,
                        uint64_t addr, char *why, size_t why_size);
// 完成证明已拿到后调用：读取所有未读槽并写回待写报告。失败不写任何报告（首错保留）。
// 成功后可整池 reset（下一命令缓冲开头 nvn_vk_query_cb_begin 记录 vkCmdResetQueryPool）。
// 非阻塞：只写已经可用的报告前缀（帧完成点调用），绝不等待 GPU。
int nvn_vk_query_resolve(struct s2a_vk_device *d, char *why, size_t why_size);
// 阻塞：等到结果可用并全部写回（队列完成 / 设备释放 / 强制 A/B）。
int nvn_vk_query_resolve_blocking(struct s2a_vk_device *d, char *why, size_t why_size);
// 每个命令缓冲开头调用（render pass 之外）：池需要重置时在这里记录一次整池 reset。
int nvn_vk_query_cb_begin(struct s2a_vk_device *d, VkCommandBuffer cmd, char *why, size_t why_size);
// 在取得/开始录制命令缓冲之前调用：页选择与页耗尽回收（可能 flush 帧队列）。
int nvn_vk_query_prepare(struct s2a_vk_device *d, char *why, size_t why_size);
// vkCmdBeginRenderPass 之后 / 每笔 draw 之前：正在计数时开一段 query（同一段内多笔 draw 只开一次）。
int nvn_vk_query_draw_begin(struct s2a_vk_device *d, VkCommandBuffer cmd, char *why, size_t why_size);
// vkCmdEndRenderPass 之前：结束当前段并记入本轮。
void nvn_vk_query_pass_end(void);
// 查询是否已经进入真实计数（第一次 Reset 之后）。false 时绘制不需要开 query。
int nvn_vk_query_counting(void);
// 1 = 旧行为（报告前 flush+等、立即写回）；0 = 延迟写回（默认）。debug.s2a.query_wait 控制。
int nvn_vk_query_immediate_mode(void);
// OP_REPORT_COUNTER(TIMESTAMP_TOP 0x10) 的两种记录方式（写回统一走 nvn_vk_ts_top_resolve）：
// 1) 帧队列路径：把 reset + TOP_OF_PIPE 时间戳录进当前帧的命令缓冲（不 submit、不等 fence），
//    地址进待写队列，帧完成点按帧序号 FIFO 统一读回。
int nvn_vk_ts_top_enqueue(struct s2a_vk_device *d, const struct s2a_record_memory *memory,
                          uint64_t addr, char *why, size_t why_size);
// 2) 同步后端路径（没有帧队列的微例 / debug.s2a.query_wait=1 的 A/B）：调用方提交 cmd 并拿到
//    完成证明后，用 nvn_vk_ts_top_resolve(blocking=1) 读回。
int nvn_vk_ts_top_record(struct s2a_vk_device *d, VkCommandBuffer cmd,
                         const struct s2a_record_memory *memory, uint64_t addr,
                         char *why, size_t why_size);
// 完成证明后读回并写回 guest（counter +0 = 0，timestamp +8 = 游戏时钟 19.2 MHz 刻度）。
// completed_frame_id = 已拿到完成证明的最大帧序号；只结算属于该帧及更早的待写项。
// blocking=1 时带 VK_QUERY_RESULT_WAIT_BIT；blocking=0 时只写就绪前缀。
// 时间戳按 GPU 域与 CLOCK_MONOTONIC 的校准偏移换算（每批 resolve 调一次校准），再按
// guest_ns()-now_ns() 平移到游戏时钟；设备没有校准扩展时写回本批结算时刻的 guest_tick()
// （与 Metal 兜底同一口径；延迟 present 下是下一帧 present 退休该帧的时刻，比 GPU 完成晚约一帧）。
int nvn_vk_ts_top_resolve(struct s2a_vk_device *d, uint64_t completed_frame_id, int blocking,
                          char *why, size_t why_size);
// 诊断：当前段的命令缓冲/池/槽位，定位“结束段时命令缓冲已失效”一类问题。
void nvn_vk_query_debug(char *out, size_t n);
// 提交成功（vkQueueSubmit 返回成功）后调用：把本批录制的查询页归属到该提交批次号。
void nvn_vk_query_batch_submitted(uint64_t seq);
// 本批不会提交了（提交失败 / 命令缓冲被丢弃 / 帧队列进终态）：把本批录制中的页整页作废，
// 保证“录了查询的命令缓冲要么随本批提交、要么连页一起作废”这条不变式（否则 WAIT 读会挂住渲染线程）。
void nvn_vk_query_batch_abandoned(void);
// 该批次的完成证明已拿到（fence 已过）后调用：取走结果进 CPU 段日志，页随即回收复用。
// 取不到结果就是准确失败（红），绝不写 0。
int nvn_vk_query_batch_completed(uint64_t seq, char *why, size_t why_size);
// 一次完整 flush 成功后调用：所有已提交页都有完成证明，读结果并回收（不依赖具体 fence 归属钩子）。
int nvn_vk_query_reclaim_all(char *why, size_t why_size);
// 非变更检查：仅在没有活动、未完成、未写回或失败的查询时返回 1。调用方须与查询操作串行。
int nvn_vk_query_terminal_ready(void);
// 设备销毁前调用：终局未就绪时保留全部句柄和写回账本，且调用方不得销毁设备。
void nvn_vk_query_release_device(void);

#ifdef __cplusplus
}
#endif

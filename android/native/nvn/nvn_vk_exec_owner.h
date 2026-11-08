// 执行包 owner 控制（F4.4）：单执行包、可挂起/恢复、Stop 发行与代际的纯状态机。
//
// 背景（统一方案 §5.5.2/§8.0.3、实施契约 §4.3）：需求编译不可中断；draw 等待 compile worker 时
// 必须把执行包明确挂起（现阶段=交还 adapter 锁、保留唯一执行包身份），让 owner 控制轮询继续处理
// Stop/窗口事件；同一 NVN queue 的后续工作不能越过这个挂起的 draw。恢复只能发生一次，且必须来自
// 同一个执行包线程、同一个挂起令牌、同一个会话/设备代际。Stop 发布后不得再恢复旧包。
//
// 本模块只做状态判决，不碰锁、不等待、不调 Vulkan——adapter 在 g_mu 下调用它，owner poll 只读
// 它发布出来的原子镜像。宿主回归与生产走同一份实现，规则不另写。
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// enter 的结果。
enum nvk_exec_enter_result {
    NVK_EXEC_ENTER_READY = 0,    // 执行包取得独占，可以开始回放
    NVK_EXEC_ENTER_WAIT = 1,     // 已有执行包（可能在挂起等待编译）：调用方不得越过，应等待唤醒
    NVK_EXEC_ENTER_STOPPED = 2,  // 已发布 Stop：调用方必须准确失败，不能开始新工作
};

// resume 的结果。
enum nvk_exec_resume_result {
    NVK_EXEC_RESUME_OK = 0,
    NVK_EXEC_RESUME_NOT_OWNER = -1,     // 不是当前执行包线程
    NVK_EXEC_RESUME_NOT_SUSPENDED = -2, // 当前没有挂起（重复恢复/没有挂起就恢复）
    NVK_EXEC_RESUME_STALE = -3,         // 令牌/代际已过期（Stop、换代或恢复过一次）
    NVK_EXEC_RESUME_STOPPED = -4,       // Stop 已发布：挂起包按失败收尾，不得继续回放
};

struct nvk_exec_owner_stats {
    uint32_t enters;              // 成功取得执行包次数
    uint32_t wait_enters;         // 因已有执行包被要求等待的次数
    uint32_t suspends;            // 成功挂起次数
    uint32_t resumes;             // 成功恢复次数
    uint32_t refused_foreign;     // 非执行包线程尝试挂起/恢复
    uint32_t refused_double_suspend;
    uint32_t refused_double_resume;
    uint32_t refused_stale;
    uint32_t refused_after_stop;
    uint32_t stop_during_suspend; // Stop 发布时执行包正挂起（owner 必须处理到的事件）
    uint32_t leaves_while_suspended; // 协议错误：挂起中直接退出执行包
};

struct nvk_exec_owner {
    uint64_t generation;       // 会话/设备代际；换代后旧挂起令牌一律失效
    uint64_t owner_thread;      // 当前执行包线程令牌（0 = 没有执行包）
    uint64_t suspend_token;     // 当前挂起令牌（0 = 未挂起）
    uint64_t next_token;
    int busy;
    int suspended;
    int stop_requested;
    struct nvk_exec_owner_stats stats;
};

// 单线程使用（adapter 持 g_mu）；generation 由创建方给（本局唯一非零值）。
void nvk_exec_owner_init(struct nvk_exec_owner *o, uint64_t generation);
// 换一代（新会话/设备重建）：清掉可能残留的执行包/挂起状态，旧令牌全部失效。
void nvk_exec_owner_set_generation(struct nvk_exec_owner *o, uint64_t generation);
void nvk_exec_owner_request_stop(struct nvk_exec_owner *o);

// 取得执行包独占。返回 NVK_EXEC_ENTER_*；READY 时 owner_thread 记为本线程。
int nvk_exec_owner_enter(struct nvk_exec_owner *o, uint64_t thread);
// 释放执行包。返回 0 = 正常释放；-1 = 不是当前执行包线程；-2 = 没有执行包。
// 挂起中直接释放按协议错误记数并清掉挂起（不把“没恢复就退出”伪装成正常）。
int nvk_exec_owner_leave(struct nvk_exec_owner *o, uint64_t thread);

// 挂起当前执行包：返回 >0 的挂起令牌；0 = 被拒绝（不是 owner、已挂起、或 Stop 已发布）。
uint64_t nvk_exec_owner_suspend(struct nvk_exec_owner *o, uint64_t thread);
// 恢复：只有同一执行包线程、同一令牌、同一代际且未 Stop 才成功。
int nvk_exec_owner_resume(struct nvk_exec_owner *o, uint64_t thread, uint64_t token);

// 只读判决。这些字段可能被 owner poll 并发读取（adapter 另有原子镜像），本模块本身不加锁。
int nvk_exec_owner_busy(const struct nvk_exec_owner *o);
int nvk_exec_owner_suspended(const struct nvk_exec_owner *o);
int nvk_exec_owner_stop_requested(const struct nvk_exec_owner *o);
uint64_t nvk_exec_owner_suspend_token(const struct nvk_exec_owner *o);
uint64_t nvk_exec_owner_generation(const struct nvk_exec_owner *o);
void nvk_exec_owner_get_stats(const struct nvk_exec_owner *o, struct nvk_exec_owner_stats *out);

#ifdef __cplusplus
}
#endif

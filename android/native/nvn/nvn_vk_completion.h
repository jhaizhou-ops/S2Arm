// 提交完成事实与批次资源持有（批次 1 的 D 接口）：纯状态机，不提交、不等待、不碰 Vulkan、不加锁。
//
// 背景（统一方案 #totk-chain-design ④模块 D 与 ⑥批次 1 的 D 接口约定）：记录回放链上，资源何时可以
// 退休不能由每个消费者各自猜。本模块只固定两件事：一个提交批次的**完成事实词表**，以及批次对资源
// 引用的**持有/放行**。真实完成证明仍归现有 owner：帧队列 fence / 事件完成证明
// （`nvn_vk_first_draw_flush_ready` 那条链）、执行包 owner（`nvk_exec_owner_*`）；它们拿到判决后调用
// 本模块的 mark_* 登记事实。本模块不另建队列、不另等 fence、不新造第二份完成账本。
//
// 事实词表固定 5 态（单调推进；“未知完成或失败”是终态）：
//   NVK_COMPLETE_UNSUBMITTED       未提交
//   NVK_COMPLETE_IN_FLIGHT         在途
//   NVK_COMPLETE_GPU_DONE          GPU 已完成
//   NVK_COMPLETE_CPU_HANDOFF_DONE  必需 CPU 交接已完成（不需要交接的批次在 GPU 完成时直接到达）
//   NVK_COMPLETE_UNKNOWN           未知完成或失败（device-lost / timeout / Stop / 换代 / API 失败）
//
// 对 A/B/C 的约定（本模块是唯一语义，禁止另立第二份）：
//   - A 的延迟项只能活到“GPU 已完成”：登记为 NVK_GATE_GPU 持有，GPU 完成事实到手后即可放行；
//   - 需要 CPU 可见副作用（事件值、读回等）的批次在 begin 时声明 needs_cpu_handoff：此类批次的
//     NVK_GATE_CPU_HANDOFF 引用只有在“必需 CPU 交接已完成”事实到手后才能放行；
//   - C 的图像/视图退休、B 的缓冲交接复用同一份令牌与事实；
//   - “未知完成”不是完成：不回调、不推进、不放行；引用必须保留并计入统计，由进程退出/会话收尾保留。
//
// 线程与回调：单线程使用（调用方在 adapter 的 g_mu 下调用），本模块不碰锁；GPU 完成回调同步执行，
// 按注册序恰好一次。回调里只允许查询与放行引用；再推进事实/换代/关闭令牌会被拒绝并计 refused_reentrant。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 完成事实。数值有序：GPU 完成之后的都 >= NVK_COMPLETE_GPU_DONE；未知是 -1，不满足任何完成判定。
enum nvk_completion_fact {
    NVK_COMPLETE_UNKNOWN = -1,
    NVK_COMPLETE_UNSUBMITTED = 0,
    NVK_COMPLETE_IN_FLIGHT = 1,
    NVK_COMPLETE_GPU_DONE = 2,
    NVK_COMPLETE_CPU_HANDOFF_DONE = 3,
};

// 引用放行闸：GPU 完成即可放行 / 必须等“必需 CPU 交接已完成”。取值与事实同号，便于按事实比较。
enum nvk_completion_gate {
    NVK_GATE_GPU = NVK_COMPLETE_GPU_DONE,
    NVK_GATE_CPU_HANDOFF = NVK_COMPLETE_CPU_HANDOFF_DONE,
};

// 未知完成的来源（失败/Stop 保留引用时必须能说清是哪一类）。
enum nvk_completion_unknown_cause {
    NVK_COMPLETION_CAUSE_DEVICE_LOST = 1,
    NVK_COMPLETION_CAUSE_TIMEOUT = 2,
    NVK_COMPLETION_CAUSE_STOP = 3,
    NVK_COMPLETION_CAUSE_GENERATION = 4,     // 换代：旧代无法再证明完成
    NVK_COMPLETION_CAUSE_SUBMIT_FAILED = 5,  // 提交/API 失败
};

// 接口返回值。ALREADY 与负值都表示“这次调用没有改变事实”，调用方不得按成功推进。
enum nvk_completion_result {
    NVK_COMPLETION_OK = 0,
    NVK_COMPLETION_ALREADY = 1,       // 事实/状态已经是目标：幂等重放，不算新进展
    NVK_COMPLETION_REFUSED = -1,      // 合同不允许（乱序推进/注册过晚/表满/无引用可放）
    NVK_COMPLETION_STALE = -2,        // 令牌不存在或已随换代失效
    NVK_COMPLETION_UNKNOWN = -3,      // 批次完成事实未知：必须保留引用，不复用不放行
    NVK_COMPLETION_STOPPED = -4,      // Stop 已发布：拒绝新工作
    NVK_COMPLETION_RETAINED = -5,     // 仍有引用/事实未知：不能回收令牌槽
};

#ifndef NVK_COMPLETION_MAX_BATCHES
#define NVK_COMPLETION_MAX_BATCHES 32
#endif
#ifndef NVK_COMPLETION_MAX_CALLBACKS
#define NVK_COMPLETION_MAX_CALLBACKS 8
#endif

struct nvk_completion_ledger;

// GPU 完成后按注册序同步调用的退休回调；opaque 由注册方解释。token 对回调期间仍有效。
typedef void (*nvk_completion_callback)(struct nvk_completion_ledger *ledger, uint64_t token, void *opaque);

struct nvk_completion_cb {
    nvk_completion_callback fn;
    void *opaque;
};

// 一个提交批次。token 是对外身份（单调分配，不复用）；generation 是建立时的会话/设备代际。
struct nvk_completion_batch {
    uint64_t token;       // 0 = 空槽
    uint64_t generation;
    uint64_t submit_seq;  // 调用方给的提交序号（查询/诊断用，不要求连续）
    int32_t fact;         // enum nvk_completion_fact
    int32_t unknown_cause;
    uint32_t needs_cpu_handoff;
    uint32_t n_callbacks;
    uint32_t callbacks_run;
    uint32_t gpu_refs;      // NVK_GATE_GPU 侧未放行引用数（A 的延迟项）
    uint32_t handoff_refs;  // NVK_GATE_CPU_HANDOFF 侧未放行引用数（CPU 交接/读回）
    struct nvk_completion_cb callbacks[NVK_COMPLETION_MAX_CALLBACKS];
};

struct nvk_completion_stats {
    uint64_t begins;
    uint64_t submitted;
    uint64_t gpu_done;            // 进入 GPU 完成事实的批次数
    uint64_t cpu_handoff_done;    // 进入必需 CPU 交接完成的批次数
    uint64_t unknown;             // 转入未知完成事实的批次数
    uint64_t callbacks_run;       // 实际执行的回调次数（每批按注册序恰好一次）
    uint64_t holds;
    uint64_t releases;
    uint64_t retired_slots;       // 成功回收的令牌槽
    uint64_t generation_changes;
    uint64_t abandoned_batches;         // 换代时未完成的旧代批次（事实未知，引用必须保留）
    uint64_t abandoned_gpu_refs;        // 上述批次上未放行的 GPU 侧引用
    uint64_t abandoned_handoff_refs;    // 上述批次上未放行的 CPU 交接侧引用
    uint64_t complete_unreleased_refs;  // 换代时已完成但调用方未放行的引用（安全，令牌已失效）
    uint64_t unknown_retained_gpu_refs;     // 当前未知批次上仍保留的 GPU 侧引用
    uint64_t unknown_retained_handoff_refs; // 当前未知批次上仍保留的 CPU 交接侧引用
    uint64_t refused_stale;
    uint64_t refused_out_of_order;  // 乱序推进/过早放行/无引用可放
    uint64_t refused_unknown;       // 在未知批次上推进/放行/回收/新增持有
    uint64_t refused_stop;
    uint64_t refused_full;
    uint64_t refused_reentrant;     // 回调内试图改变事实/换代/关闭令牌
};

struct nvk_completion_ledger {
    uint64_t generation;
    uint64_t next_token;   // 0 保留为“没有令牌”
    int stop_requested;    // Stop 不因换代撤销；新会话用 init 重建
    int firing;            // 正在按注册序执行回调
    struct nvk_completion_stats stats;
    struct nvk_completion_batch batches[NVK_COMPLETION_MAX_BATCHES];
};

// 查询快照。query 返回 OK 才有效。
struct nvk_completion_info {
    uint64_t token;
    uint64_t generation;
    uint64_t submit_seq;
    int32_t fact;
    int32_t unknown_cause;
    int needs_cpu_handoff;
    uint32_t gpu_refs;
    uint32_t handoff_refs;
    uint32_t callbacks;
    uint32_t callbacks_run;
};

// 首次使用前零初始化也可直接调用（generation 由创建方给，本局唯一非零值）。
void nvk_completion_init(struct nvk_completion_ledger *l, uint64_t generation);
// 换代（新会话/设备重建）：旧代令牌全部失效，旧代回调一律不触发；未完成批次按“未知完成”记账后
// 回收槽位，它们持有的引用必须由调用方保留（计入 abandoned_*）。Stop 标记不因换代撤销。
void nvk_completion_set_generation(struct nvk_completion_ledger *l, uint64_t generation);
// 发布 Stop：拒绝新的 begin/hold/注册/提交；已提交批次仍可由真实完成源推进到已证明的事实。
// 无法证明完成的批次由调用方用 nvk_completion_mark_unknown(cause=STOP) 转未知并保留引用。
void nvk_completion_request_stop(struct nvk_completion_ledger *l);

// 开始一个提交批次并取得令牌（未提交事实）。needs_cpu_handoff = 该批是否有 CPU 可见副作用必须等到
// “必需 CPU 交接已完成”。成功返回 OK 并写 *out_token；STOPPED/REFUSED 时 *out_token = 0。
int nvk_completion_begin(struct nvk_completion_ledger *l, int needs_cpu_handoff, uint64_t submit_seq,
                         uint64_t *out_token);
// 登记一个批次引用（hold）或放行（release）。gate = NVK_GATE_GPU / NVK_GATE_CPU_HANDOFF。
//   hold：未提交/在途/GPU 完成且未未知时允许；未知/Stop 后拒绝。
//   release：该闸对应的事实已到（GPU 完成 / 必需 CPU 交接完成）才允许；未知完成一律拒绝（保留引用）。
int nvk_completion_hold(struct nvk_completion_ledger *l, uint64_t token, int gate);
int nvk_completion_release(struct nvk_completion_ledger *l, uint64_t token, int gate);
// 注册“GPU 完成后退休”回调：只允许在未提交/在途时注册；GPU 完成时按注册序恰好一次；注册满/过晚拒绝。
int nvk_completion_on_gpu_done(struct nvk_completion_ledger *l, uint64_t token, nvk_completion_callback fn,
                               void *opaque);

// 真实完成源（帧队列 fence/完成回调）拿到判决后登记事实；宿主合同用假完成源直接驱动。
// 未提交→在途、在途→GPU 完成（触发回调）、GPU 完成→必需 CPU 交接完成；乱序/非法转移准确拒绝。
int nvk_completion_mark_submitted(struct nvk_completion_ledger *l, uint64_t token);
int nvk_completion_mark_gpu_done(struct nvk_completion_ledger *l, uint64_t token);
int nvk_completion_mark_cpu_handoff_done(struct nvk_completion_ledger *l, uint64_t token);
// device-lost / 超时 / Stop / 换代 / API 失败：任何未完成事实转“未知完成或失败”（终态）。
// 已完成的批次不能回退成未知（REFUSED）；未知批次必须保留引用，不回调、不放行。
int nvk_completion_mark_unknown(struct nvk_completion_ledger *l, uint64_t token, int cause);

// 查询当前完成事实（按批次令牌；submit_seq 在返回的 info 里）。返回 OK / STALE。
int nvk_completion_query(const struct nvk_completion_ledger *l, uint64_t token, struct nvk_completion_info *out);
// 按提交序号查当前令牌（submit_seq 由调用方在 begin 时给，同一账本内需唯一）。返回 OK / STALE。
int nvk_completion_find(const struct nvk_completion_ledger *l, uint64_t submit_seq, uint64_t *out_token);
// 该闸现在是否可以放行（1/0）。只做判决，不改变事实；未知/未到达/坏令牌都返回 0。
int nvk_completion_may_release(const struct nvk_completion_ledger *l, uint64_t token, int gate);
// 回收令牌槽：事实已到 CPU 交接完成且两侧引用清零才允许。未知完成返回 RETAINED（令牌保留）。
int nvk_completion_close(struct nvk_completion_ledger *l, uint64_t token);

int nvk_completion_stop_requested(const struct nvk_completion_ledger *l);
uint64_t nvk_completion_generation(const struct nvk_completion_ledger *l);
// 当前未知完成仍须保留的引用（会话收尾用；这些引用不得被当成可放行）。
void nvk_completion_unknown_retained(const struct nvk_completion_ledger *l, uint64_t *gpu_refs,
                                     uint64_t *handoff_refs);
void nvk_completion_get_stats(const struct nvk_completion_ledger *l, struct nvk_completion_stats *out);

// 词表名（诊断/测试输出；未知值返回 "?"）。
const char *nvk_completion_fact_name(int fact);
const char *nvk_completion_cause_name(int cause);
const char *nvk_completion_result_name(int result);

#ifdef __cplusplus
}
#endif

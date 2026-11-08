// F4.4：有界需求编译 worker。只有一个编译槽；同一内容身份（sha256）的并发需求合并成一次编译，
// 不同需求排队。调用方在等待结果时可以交出外部锁（pause/resume），让 owner 继续处理 Stop/窗口；
// Stop 会唤醒等待者并取消在途任务，worker 完成后丢弃迟到结果；正常退出 join 线程。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 真正的编译执行（由调用方提供；返回 0 并交出 bytes，-1 失败写 why）。
typedef int (*s2a_compile_worker_fn)(void *ctx, uint64_t session, uint64_t generation,
                                     const char *json, size_t len,
                                     uint8_t **bytes, size_t *bytes_len,
                                     char *why, size_t why_size);

// 幂等启动；失败时 run 会明确报错（调用方可退回同步编译）。
int s2a_compile_worker_start(s2a_compile_worker_fn fn, void *ctx, char *why, size_t why_size);
int s2a_compile_worker_active(void);
// 取消在途/等待中的任务并 join。可重复调用；之后可再次 start（测试用）。无预算上限，
// 收尾路径必须用有界版本，不能把“编译卡住”变成无界 join。
void s2a_compile_worker_stop(void);
// 有界收尾：最多等 budget_ms。返回 0 = worker 已退出并回收；1 = 仍在编译（迟到结果会被丢弃，
// 编译入口/上下文保留到真正退出，下一次 start/stop 先回收）。可重复调用。
int s2a_compile_worker_stop_bounded(uint32_t budget_ms, char *why, size_t why_size);
// W2.6 计数：runs 是 run() 进入次数，compiles 是真正调用编译函数的次数（去重/排队不增加），
// dedup 是附着到同 sha 在途 job 的次数，busy_timeouts 是等槽位超时，failures 是失败返回，
// late_discarded 是 Stop/放弃后丢弃的迟到结果。容量只有 1，这些数直接说明背压与合并。
struct s2a_compile_worker_stats {
    uint64_t runs, compiles, dedup, busy_timeouts, failures, late_discarded;
};
void s2a_compile_worker_stats(struct s2a_compile_worker_stats *out);

// owner 控制片：在本任务空闲前最多等一个 10 ms 片。返回 1 = 仍有在途需求；0 = 空闲；
// -1 = worker 未运行。只用于 owner 推进窗口/停止，不代表 draw 已经等到结果。
int s2a_compile_worker_pump(uint32_t budget_ms);

// 提交并同步等待。sha 是内容身份；deadline_ms<=0 用默认值。
// pause/resume 必须同时为 NULL（无外部锁）或同时非 NULL；半对回调明确拒绝。
// 在发布/附着 job 或等槽位前调用 pause（不持 worker 锁）：0 成功；非 0 失败。
// pause 失败时不发起/附着/等待任务，bytes=NULL、长度=0，不调用 resume；外部锁仍由
// 调用方按其错误返回路径处理。pause 成功后所有退出均恰好 resume 一次（不持 worker 锁）。
// pause 期间 Stop 或重新 start 会拒绝这次旧请求，不把它交给新 worker。
// 返回 0 成功（bytes 由调用方 free）、-1 失败/停止/超时（why 写明）。
// Optional W2 diagnostics retain an exact build-allocation attempt per caller
// and per job. Dedup/timeout/Stop revoke diagnostics without changing compile
// behavior. Only this invocation's accepted failure is handed back to caller
// TLS after resume; producer cleanup never runs under the worker mutex.
int s2a_compile_worker_run(uint64_t session, uint64_t generation, const char *json, size_t len,
                           const uint8_t sha[32], int deadline_ms,
                           int (*pause)(void *), void (*resume)(void *), void *pause_ctx,
                           uint8_t **bytes, size_t *bytes_len, char *why, size_t why_size);

#ifdef __cplusplus
}
#endif

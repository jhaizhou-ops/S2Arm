// C1：relocation 前的唯一图形模式选择事务。
// 规则（契约 §2.2 / §8）：
//   - mode 在 loader 重定位前固定一次；进程内不允许第二套后端。
//   - AUTO：结构条件不满足/上次未正常结束/故障锁写失败 → generic（commit 前）。
//   - 手动 generic 优先；手动 direct 仍须过同一准备与锁准入，失败不悄悄改 generic。
//   - Prepare 成功后原子写 attempt；commit 后任何失败都保留 attempt 并结束本进程。
// provider 是唯一创建 device/queue/worker 的地方；选择器只记账并调用它。
#pragma once
#include "attempt.h"
#include "graphics.h"
#include "s2a_direct.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 会话结束时调用：normal != 0（guest 正常返回 / 用户主动停止）才清掉 attempt 锁；
// 崩溃或被杀保留锁，下一次 AUTO 自动回 generic。C++ 宿主也要按 C 链接调用
// （AOT/共享 shutdown 在 bridge.cpp 里直接清锁）。
int32_t s2a_direct_finish(int normal);

enum s2a_direct_decision {
    S2A_DIRECT_DECISION_PENDING = 0,
    S2A_DIRECT_DECISION_GENERIC = 1,
    S2A_DIRECT_DECISION_DIRECT = 2,
};

struct s2a_direct_counts {
    uint32_t devices, queues, workers, consumers;
};

struct s2a_direct_provider {
    const char *name;
    // 1 = 本构建/本设备具备尝试 direct 的基础能力；不得为判断它创建 VkDevice。
    int (*available)(void);
    // 建候选 device/queue/worker 与 table。失败时必须自己回收已创建资源并返回准确错误；
    // effective_profile_hash 为 "sha256-"+64 小写 hex 或 64 hex。
    int32_t (*prepare)(const struct s2a_graphics_descriptor_v1 *descriptor, uint64_t session,
                       const char *state_dir, void *user, struct s2a_direct_api_v1 *table,
                       char effective_profile_hash[72], struct s2a_direct_counts *counts,
                       char *why, size_t why_size);
    void *user;
};

struct s2a_direct_selection {
    uint32_t decision;        // s2a_direct_decision
    uint32_t mode;            // 0 generic / 1 direct
    uint64_t session;
    struct s2a_direct_api_v1 table;
    uint32_t direct_abi;
    char implementation_key[65];
    char effective_profile_hash[72];
    struct s2a_direct_counts counts;
    char reason[192];
};

// 返回 S2A_DIRECT_RES_*；只有 decision=DIRECT 时 table 可用。
// 成功选 generic 也返回 OK（reason 说明原因）；手动 direct 的失败返回负码。
int32_t s2a_direct_select(const struct s2a_graphics_descriptor_v1 *descriptor,
                          uint32_t mode_preference, uint64_t session, const char *state_dir,
                          const struct s2a_direct_provider *provider,
                          struct s2a_direct_selection *out, char *why, size_t why_size);

// 进程级冻结：只允许发布一次；发布后 current 只读。失败返回负码。
int32_t s2a_direct_selection_publish(const struct s2a_direct_selection *selection);
const struct s2a_direct_selection *s2a_direct_selection_current(void);

// 生产 provider 由 native Vulkan 后端提供；未编入时为空（AUTO 走 generic）。
const struct s2a_direct_provider *s2a_direct_provider_default(void);

#ifdef __cplusplus
}
#endif

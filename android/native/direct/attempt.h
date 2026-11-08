// C1：direct attempt / failure 持久锁。
// 路径固定在持久 stateDir（不是 cacheRoot）：<state>/graphics/direct/<implementationKey>/
//   attempt.json  —— 进入 commit 前写入；正常收局才清除。任何遗留（含 SIGKILL）都让下一局自动 generic。
//   failure.json  —— 失败摘要（阶段/错误码/原因），保留到正常收局或玩家受控重试。
// 写入顺序固定：temp -> write -> fsync(file) -> rename -> fsync(parent)。失败不发布半成品。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S2A_ATTEMPT_SCHEMA "s2a-direct-attempt-v1"
#define S2A_FAILURE_SCHEMA "s2a-direct-failure-v1"
#define S2A_ATTEMPT_DIR_MAX 2048

enum s2a_attempt_phase {
    S2A_ATTEMPT_PREPARED = 0,
    S2A_ATTEMPT_COMMITTED = 1,
    S2A_ATTEMPT_ACTIVE = 2,
    S2A_ATTEMPT_STOPPING = 3,
};

enum s2a_attempt_result {
    S2A_ATTEMPT_OK = 0,
    S2A_ATTEMPT_NOT_FOUND = 1,
    S2A_ATTEMPT_ARGUMENT = -1,
    S2A_ATTEMPT_IO = -2,
    S2A_ATTEMPT_CORRUPT = -3,
    S2A_ATTEMPT_LIMIT = -4,
};

struct s2a_direct_attempt_v1 {
    char attempt_id[33];          // 32 小写 hex
    char implementation_key[65];  // 64 小写 hex
    uint64_t session;
    uint32_t phase;
    char reason[128];             // ASCII/UTF-8，无控制字符
};

struct s2a_direct_failure_v1 {
    char attempt_id[33];
    char implementation_key[65];
    uint64_t session;
    uint32_t phase;
    int32_t error;
    char reason[160];
};

// 纯路径拼接（不含 I/O）：<state>/graphics/direct/<key>/<name>；key 必须是 64 小写 hex。
int s2a_direct_attempt_path(const char *state_dir, const char *implementation_key,
                            const char *name, char *out, size_t capacity);
// 读 attempt；不存在返回 S2A_ATTEMPT_NOT_FOUND，JSON/身份不符返回 CORRUPT。
int s2a_direct_attempt_read(const char *state_dir, const char *implementation_key,
                            struct s2a_direct_attempt_v1 *out);
int s2a_direct_attempt_write(const char *state_dir, const struct s2a_direct_attempt_v1 *attempt);
// 最近一次 S2A_ATTEMPT_IO 的 errno（0=无）；只用于诊断，不改变返回码语义。
int s2a_direct_attempt_last_errno(void);
int s2a_direct_failure_write(const char *state_dir, const struct s2a_direct_failure_v1 *failure);
// 正常收局：先清 failure 再清 attempt（attempt 是崩溃锁，最后消失）。目录保留为空也无害。
int s2a_direct_attempt_clear(const char *state_dir, const char *implementation_key);

// 只检查“这个 implementationKey 是否有遗留 attempt / failure”，不解析业务（C1 选择用）。
int s2a_direct_attempt_pending(const char *state_dir, const char *implementation_key);

#ifdef __cplusplus
}
#endif

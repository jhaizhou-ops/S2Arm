// C1 选择事务实现，见 selection.h。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "selection.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <unistd.h>

#if defined(__ANDROID__)
#include <android/log.h>
#define SEL_LOG(...) __android_log_print(ANDROID_LOG_INFO, "S2Arm", __VA_ARGS__)
#else
#define SEL_LOG(...) ((void)0)
#endif

#ifdef S2A_DIRECT_TEST_FAULTS
static int g_selection_fault = -1;
void s2a_direct_selection_fault(int point) { g_selection_fault = point; }
#define SEL_FAULT(point) (g_selection_fault == (point))
#else
#define SEL_FAULT(point) 0
#endif

// C1：commit 之后要记住锁的位置，会话"正常收尾"时才能清掉它。
// 不清的后果（真机实测）：direct 只可能跑一局，之后每次都是 generic
// "previous direct attempt did not end normally"。
static char g_lock_state_dir[1024];
static char g_lock_key[65];   // 64 小写 hex + NUL；曾经是 64，snprintf 截成 63 字符后 clear 被 hex_lower_64 拒绝，锁永远清不掉
static int g_lock_held;
// 一次 commit 会在多个 implementationKey 下落锁：
//   * descriptor 声明的 profile 键（AUTO 在创建设备**之前**能算出来，用于预检）；
//   * 本机合成 profile 的键（commit 的真实身份，预检时还没合成）。
// 正常收局必须把这一组全部清掉；只清一把会让另一把永久留下，AUTO 从此回不到 direct（真机复现）。
#define SEL_LOCK_KEYS 8
static char g_lock_keys[SEL_LOCK_KEYS][65];
static uint32_t g_lock_key_count;

static void lock_keys_reset(void) { g_lock_key_count = 0; }
static void lock_keys_remember(const char *key) {
    if (!key || !key[0]) return;
    for (uint32_t i = 0; i < g_lock_key_count; i++)
        if (!strcmp(g_lock_keys[i], key)) return;
    if (g_lock_key_count < SEL_LOCK_KEYS)
        snprintf(g_lock_keys[g_lock_key_count++], sizeof g_lock_keys[0], "%s", key);
    else
        SEL_LOG("direct attempt: lock key set full (%u), not remembering %.64s", (unsigned)g_lock_key_count, key);
}

// attempt 写入：先写 descriptor 别名的每一把，再写 live 键。任何一把失败都返回错误，
// commit 前失败会回滚；commit 后失败保留 attempt，调用方必须结束进程。
static int32_t attempt_write_all(const char *state_dir, const struct s2a_direct_attempt_v1 *attempt,
                                 const char *live_key) {
    for (uint32_t i = 0; i < g_lock_key_count; i++) {
        if (!strcmp(g_lock_keys[i], live_key)) continue;
        struct s2a_direct_attempt_v1 copy = *attempt;
        snprintf(copy.implementation_key, sizeof copy.implementation_key, "%.64s", g_lock_keys[i]);
        int32_t rc = s2a_direct_attempt_write(state_dir, &copy);
        if (rc != S2A_ATTEMPT_OK) return rc;
    }
    return s2a_direct_attempt_write(state_dir, attempt);
}

int32_t s2a_direct_finish(int normal) {
    fprintf(stderr, "[s2a] direct attempt finish: held=%d normal=%d key=%.64s\n", g_lock_held, normal, g_lock_key);
    if (!g_lock_held) return S2A_DIRECT_RES_OK;
    if (!normal) {
        fprintf(stderr, "[s2a] direct attempt lock kept (session did not end normally)\n");
        return S2A_DIRECT_RES_OK;
    }
    int32_t first_error = S2A_ATTEMPT_OK;
    for (uint32_t i = 0; i < g_lock_key_count; i++) {
        int32_t rc = s2a_direct_attempt_clear(g_lock_state_dir, g_lock_keys[i]);
        if (rc != S2A_ATTEMPT_OK) {
            fprintf(stderr, "[s2a] direct attempt lock clear failed for %.64s (%d)\n", g_lock_keys[i], (int)rc);
            if (first_error == S2A_ATTEMPT_OK) first_error = rc;
        } else {
            SEL_LOG("direct attempt: cleared key=%.64s dir=%s", g_lock_keys[i], g_lock_state_dir);
        }
    }
    if (first_error != S2A_ATTEMPT_OK) return first_error;
    g_lock_held = 0;
    fprintf(stderr, "[s2a] direct attempt lock cleared (session ended normally)\n");
    return S2A_DIRECT_RES_OK;
}

static int set_reason(char *why, size_t cap, const char *text) {
    if (why && cap) snprintf(why, cap, "%s", text);
    return 0;
}

static void set_decision(struct s2a_direct_selection *out, uint32_t mode, const char *reason) {
    out->decision = mode == 1 ? S2A_DIRECT_DECISION_DIRECT : S2A_DIRECT_DECISION_GENERIC;
    out->mode = mode;
    snprintf(out->reason, sizeof out->reason, "%s", reason);
}

static int random_attempt_id(char out[33]) {
    uint8_t bytes[16];
    ssize_t got = 0;
    while (got < (ssize_t)sizeof bytes) {
        ssize_t n = getrandom(bytes + got, sizeof bytes - (size_t)got, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        got += n;
    }
    if (got != (ssize_t)sizeof bytes) {
        int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) return -1;
        got = 0;
        while (got < (ssize_t)sizeof bytes) {
            ssize_t n = read(fd, bytes + got, sizeof bytes - (size_t)got);
            if (n <= 0) { close(fd); return -1; }
            got += n;
        }
        close(fd);
    }
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        out[i * 2] = hex[bytes[i] >> 4];
        out[i * 2 + 1] = hex[bytes[i] & 15];
    }
    out[32] = 0;
    return 0;
}

// 遗留 attempt/failure：按 descriptor 列出的每个 profileHash 计算 implementationKey 检查。
// 返回 1 = 有遗留，0 = 无，负 = 身份/文件系统错误。
static int pending_previous(const struct s2a_graphics_descriptor_v1 *descriptor,
                            const char *state_dir, char *why, size_t why_size) {
    for (uint32_t i = 0; i < descriptor->profile_count; i++) {
        char key[65], error[96];
        if (s2a_direct_implementation_key(descriptor, descriptor->profile_hashes[i], key,
                                          error, sizeof error))
            return S2A_DIRECT_RES_IDENTITY;
        int pending = s2a_direct_attempt_pending(state_dir, key);
        SEL_LOG("direct attempt: pending check key=%.64s state_dir=%s -> %d", key, state_dir, pending);
        if (pending) {
            set_reason(why, why_size, "previous direct attempt did not end normally");
            return 1;
        }
    }
    return 0;
}

static int32_t rollback(const struct s2a_direct_api_v1 *table) {
    if (!table || !table->destroy || !table->context) return S2A_DIRECT_RES_OK;
    return table->destroy(table->context);
}

int32_t s2a_direct_select(const struct s2a_graphics_descriptor_v1 *descriptor,
                          uint32_t mode_preference, uint64_t session, const char *state_dir,
                          const struct s2a_direct_provider *provider,
                          struct s2a_direct_selection *out, char *why, size_t why_size) {
    if (!out || !session || !state_dir || state_dir[0] != '/' ||
        mode_preference > S2A_DIRECT_MODE_DIRECT)
        return S2A_DIRECT_RES_ARGUMENT;
    memset(out, 0, sizeof *out);
    out->session = session;
    out->decision = S2A_DIRECT_DECISION_PENDING;

    // 手动 generic 优先：不创建 device、不读故障锁。
    if (mode_preference == S2A_DIRECT_MODE_GENERIC) {
        set_decision(out, 0, "player selected generic");
        return S2A_DIRECT_RES_OK;
    }
    if (!descriptor) {
        if (mode_preference == S2A_DIRECT_MODE_DIRECT) {
            set_reason(why, why_size, "direct requested but package has no graphics descriptor");
            return S2A_DIRECT_RES_UNSUPPORTED;
        }
        set_decision(out, 0, "no graphics descriptor");
        return S2A_DIRECT_RES_OK;
    }
    if (!provider || !provider->prepare || !provider->available || !provider->available()) {
        if (mode_preference == S2A_DIRECT_MODE_DIRECT) {
            set_reason(why, why_size, "direct requested but backend is not available");
            return S2A_DIRECT_RES_UNSUPPORTED;
        }
        set_decision(out, 0, "direct backend not available");
        return S2A_DIRECT_RES_OK;
    }

    lock_keys_reset();
    for (uint32_t i = 0; i < descriptor->profile_count; i++) {
        char alias[65], error[96];
        if (s2a_direct_implementation_key(descriptor, descriptor->profile_hashes[i], alias,
                                          error, sizeof error))
            return S2A_DIRECT_RES_IDENTITY;
        lock_keys_remember(alias);
    }
    int previous = pending_previous(descriptor, state_dir, why, why_size);
    if (previous < 0) return S2A_DIRECT_RES_IDENTITY;
    if (previous) {
        if (mode_preference != S2A_DIRECT_MODE_DIRECT) {
            set_decision(out, 0, "previous direct attempt did not end normally");
            return S2A_DIRECT_RES_OK;
        }
        set_reason(why, why_size, "manual direct retry after previous attempt");
    }

    struct s2a_direct_api_v1 table;
    memset(&table, 0, sizeof table);
    char profile[72] = "";
    // 身份不匹配要带上两边的 closure（各 71 字节）+ 错误码/文案：128 字节会把原因截成半句。
    char prepare_why[480] = "";
    struct s2a_direct_counts counts;
    memset(&counts, 0, sizeof counts);
    int32_t rc = provider->prepare(descriptor, session, state_dir, provider->user, &table,
                                   profile, &counts, prepare_why, sizeof prepare_why);
    if (rc != S2A_DIRECT_RES_OK) {
        int32_t cleanup = rollback(&table);
        if (cleanup != S2A_DIRECT_RES_OK) {
            set_reason(why, why_size, "candidate cleanup failed after prepare error");
            return S2A_DIRECT_RES_RETIREMENT;
        }
        if (mode_preference == S2A_DIRECT_MODE_DIRECT) {
            set_reason(why, why_size, prepare_why[0] ? prepare_why : "direct prepare failed");
            return rc < 0 ? rc : S2A_DIRECT_RES_INTERNAL;
        }
        set_decision(out, 0, prepare_why[0] ? prepare_why : "direct prepare failed before commit");
        return S2A_DIRECT_RES_OK;
    }
    rc = s2a_direct_table_check(&table);
    if (rc != S2A_DIRECT_RES_OK || table.session != session) {
        int32_t cleanup = rollback(&table);
        if (cleanup != S2A_DIRECT_RES_OK) return S2A_DIRECT_RES_RETIREMENT;
        if (mode_preference == S2A_DIRECT_MODE_DIRECT) return S2A_DIRECT_RES_IDENTITY;
        set_decision(out, 0, "direct prepare returned an invalid table");
        return S2A_DIRECT_RES_OK;
    }
    char key[65], error[96];
    if (s2a_direct_implementation_key(descriptor, profile, key, error, sizeof error)) {
        int32_t cleanup = rollback(&table);
        if (cleanup != S2A_DIRECT_RES_OK) return S2A_DIRECT_RES_RETIREMENT;
        if (mode_preference == S2A_DIRECT_MODE_DIRECT) return S2A_DIRECT_RES_IDENTITY;
        set_decision(out, 0, "direct prepare returned an invalid profile identity");
        return S2A_DIRECT_RES_OK;
    }

    // descriptor 预检只能覆盖离线 profile 键；本机合成 profile 的键现在才知道。
    // AUTO 必须在这里也检查：上一次 direct 若在 commit 之后异常结束，live 键会留下；
    // 不查就会把“崩溃后自动重试”当成首次启动。
    if (mode_preference != S2A_DIRECT_MODE_DIRECT && s2a_direct_attempt_pending(state_dir, key)) {
        int32_t cleanup = rollback(&table);
        if (cleanup != S2A_DIRECT_RES_OK) return S2A_DIRECT_RES_RETIREMENT;
        set_decision(out, 0, "previous direct attempt did not end normally");
        return S2A_DIRECT_RES_OK;
    }

    struct s2a_direct_attempt_v1 attempt;
    memset(&attempt, 0, sizeof attempt);
    if (random_attempt_id(attempt.attempt_id)) {
        int32_t cleanup = rollback(&table);
        if (cleanup != S2A_DIRECT_RES_OK) return S2A_DIRECT_RES_RETIREMENT;
        if (mode_preference == S2A_DIRECT_MODE_DIRECT) return S2A_DIRECT_RES_INTERNAL;
        set_decision(out, 0, "random attempt id unavailable");
        return S2A_DIRECT_RES_OK;
    }
    snprintf(attempt.implementation_key, sizeof attempt.implementation_key, "%s", key);
    attempt.session = session;
    attempt.phase = S2A_ATTEMPT_PREPARED;
    set_reason(attempt.reason, sizeof attempt.reason, "direct prepared before relocation");
    lock_keys_remember(key);
    int32_t lock_rc = attempt_write_all(state_dir, &attempt, key);
    if (lock_rc != S2A_ATTEMPT_OK) {
        int32_t cleanup = rollback(&table);
        if (cleanup != S2A_DIRECT_RES_OK) return S2A_DIRECT_RES_RETIREMENT;
        if (mode_preference == S2A_DIRECT_MODE_DIRECT) return S2A_DIRECT_RES_INTERNAL;
        // 带上具体错误码：只写"锁不可用"无法定位是目录/权限还是内容校验。
        char reason[96];
        snprintf(reason, sizeof reason, "attempt lock unavailable before commit (%d errno=%d)",
                 (int)lock_rc, lock_rc == S2A_ATTEMPT_IO ? s2a_direct_attempt_last_errno() : 0);
        set_decision(out, 0, reason);
        return S2A_DIRECT_RES_OK;
    }

    // commit：先填满 selection 再写 committed 阶段；写失败留在 prepared，调用方必须结束进程。
    out->decision = S2A_DIRECT_DECISION_DIRECT;
    out->mode = 1;
    out->table = table;
    out->direct_abi = descriptor->direct_abi;
    memcpy(out->implementation_key, key, sizeof key);
    memcpy(out->effective_profile_hash, profile, sizeof profile);
    out->counts = counts;
    set_reason(out->reason, sizeof out->reason, "direct committed before relocation");
    attempt.phase = S2A_ATTEMPT_COMMITTED;
    set_reason(attempt.reason, sizeof attempt.reason, "direct committed");
    if (SEL_FAULT(1) || attempt_write_all(state_dir, &attempt, key) != S2A_ATTEMPT_OK) {
        out->decision = S2A_DIRECT_DECISION_PENDING;
        set_reason(why, why_size, "attempt commit update failed after commit");
        return S2A_DIRECT_RES_INTERNAL;
    }
    snprintf(g_lock_state_dir, sizeof g_lock_state_dir, "%s", state_dir);
    snprintf(g_lock_key, sizeof g_lock_key, "%s", key);
    g_lock_held = 1;
    return S2A_DIRECT_RES_OK;
}

static struct s2a_direct_selection g_selection;
static int g_published;

int32_t s2a_direct_selection_publish(const struct s2a_direct_selection *selection) {
    if (!selection || selection->decision == S2A_DIRECT_DECISION_PENDING ||
        selection->decision > S2A_DIRECT_DECISION_DIRECT) return S2A_DIRECT_RES_ARGUMENT;
    if (g_published) return S2A_DIRECT_RES_ARGUMENT;
    g_selection = *selection;
    __atomic_store_n(&g_published, 1, __ATOMIC_RELEASE);
    return S2A_DIRECT_RES_OK;
}

// 生产后端未编入时为空：AUTO 据此在 commit 前选 generic。
__attribute__((weak)) const struct s2a_direct_provider *s2a_direct_provider_default(void) {
    return NULL;
}

const struct s2a_direct_selection *s2a_direct_selection_current(void) {
    if (!__atomic_load_n(&g_published, __ATOMIC_ACQUIRE)) return NULL;
    return &g_selection;
}

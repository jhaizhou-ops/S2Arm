// C1：attempt/failure 持久锁的原子写、身份校验、故障注入与清理。
// 使用临时目录；不含游戏数据。S2A_DIRECT_TEST_FAULTS 只在测试目标定义。
#define _GNU_SOURCE
#include "../native/direct/attempt.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void s2a_direct_attempt_fault(int point);   // 测试编译才有定义

static int g_failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); g_failures++; } } while (0)
#define CHECK_RC(expr, want, what) do { int _r = (expr); if (_r != (want)) { printf("FAIL %s: rc=%d want=%d\n", what, _r, (int)(want)); g_failures++; } } while (0)

static char state[600];
static const char *key_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
static const char *key_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

static void attempt(struct s2a_direct_attempt_v1 *a, const char *key, uint32_t phase, const char *reason) {
    memset(a, 0, sizeof *a);
    memcpy(a->attempt_id, "0123456789abcdef0123456789abcdef", 32);
    memcpy(a->implementation_key, key, 64);
    a->session = 0x1122334455667788ull;
    a->phase = phase;
    snprintf(a->reason, sizeof a->reason, "%s", reason);
}

int main(void) {
    const char *tmp = getenv("S2A_TEST_TMP");
    if (!tmp || !*tmp) tmp = getenv("TMPDIR");
    char template[512];
    snprintf(template, sizeof template, "%s/s2a-direct-attempt-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    CHECK(mkdtemp(template) != NULL, "mkdtemp");
    snprintf(state, sizeof state, "%s/state", template);

    struct s2a_direct_attempt_v1 a, got;
    attempt(&a, key_a, S2A_ATTEMPT_PREPARED, "first direct attempt");
    CHECK_RC(s2a_direct_attempt_read(state, key_a, &got), S2A_ATTEMPT_NOT_FOUND, "absent before write");
    CHECK_RC(s2a_direct_attempt_write(state, &a), S2A_ATTEMPT_OK, "write attempt");
    CHECK_RC(s2a_direct_attempt_read(state, key_a, &got), S2A_ATTEMPT_OK, "read attempt");
    CHECK(!strcmp(got.attempt_id, a.attempt_id) && !strcmp(got.reason, a.reason) &&
          got.session == a.session && got.phase == a.phase, "roundtrip");
    CHECK(s2a_direct_attempt_pending(state, key_a) == 1, "pending after write");
    CHECK(s2a_direct_attempt_pending(state, key_b) == 0, "other key not pending");

    struct stat st;
    char path[700];
    CHECK_RC(s2a_direct_attempt_path(state, key_a, "attempt.json", path, sizeof path), S2A_ATTEMPT_OK, "path");
    CHECK(!stat(path, &st) && S_ISREG(st.st_mode) && (st.st_mode & 0777) == 0600, "attempt file mode");
    char dir[700];
    snprintf(dir, sizeof dir, "%s/graphics/direct/%s", state, key_a);
    CHECK(!stat(dir, &st) && (st.st_mode & 0777) == 0700, "state dir mode");

    // 非正常结束：失败摘要保留 attempt；下一次仍 pending。
    struct s2a_direct_failure_v1 f;
    memset(&f, 0, sizeof f);
    memcpy(f.attempt_id, a.attempt_id, 32);
    memcpy(f.implementation_key, key_a, 64);
    f.session = a.session;
    f.phase = S2A_ATTEMPT_ACTIVE;
    f.error = -7;
    snprintf(f.reason, sizeof f.reason, "driver lost while compiling");
    CHECK_RC(s2a_direct_failure_write(state, &f), S2A_ATTEMPT_OK, "failure write");
    CHECK(s2a_direct_attempt_pending(state, key_a) == 1, "pending with failure");

    // 正常收局：先 failure 后 attempt 都消失。
    CHECK_RC(s2a_direct_attempt_clear(state, key_a), S2A_ATTEMPT_OK, "clear");
    CHECK(s2a_direct_attempt_pending(state, key_a) == 0, "not pending after clear");
    CHECK_RC(s2a_direct_attempt_read(state, key_a, &got), S2A_ATTEMPT_NOT_FOUND, "absent after clear");

    // 参数/身份负例。
    CHECK_RC(s2a_direct_attempt_write(NULL, &a), S2A_ATTEMPT_ARGUMENT, "null state");
    CHECK_RC(s2a_direct_attempt_write(state, NULL), S2A_ATTEMPT_ARGUMENT, "null attempt");
    a.session = 0; CHECK_RC(s2a_direct_attempt_write(state, &a), S2A_ATTEMPT_ARGUMENT, "zero session"); a.session = 1;
    a.phase = 9; CHECK_RC(s2a_direct_attempt_write(state, &a), S2A_ATTEMPT_ARGUMENT, "bad phase"); a.phase = S2A_ATTEMPT_PREPARED;
    memcpy(a.attempt_id, "0123456789ABCDEF0123456789ABCDEF", 32);
    CHECK_RC(s2a_direct_attempt_write(state, &a), S2A_ATTEMPT_ARGUMENT, "uppercase attempt id");
    memcpy(a.attempt_id, "0123456789abcdef0123456789abcdef", 32);
    snprintf(a.reason, sizeof a.reason, "bad\"quote");
    CHECK_RC(s2a_direct_attempt_write(state, &a), S2A_ATTEMPT_ARGUMENT, "quote rejected");
    snprintf(a.reason, sizeof a.reason, "ok");
    CHECK_RC(s2a_direct_attempt_write(state, &a), S2A_ATTEMPT_OK, "write for corruption test");

    // 手写坏 JSON / 身份不符 -> CORRUPT，不覆盖成“完成”。
    FILE *file = fopen(path, "w");
    CHECK(file != NULL, "open corrupt");
    if (file) { fputs("{\"schema\":\"s2a-direct-attempt-v1\"", file); fclose(file); }
    CHECK_RC(s2a_direct_attempt_read(state, key_a, &got), S2A_ATTEMPT_CORRUPT, "truncated attempt corrupt");
    file = fopen(path, "w");
    if (file) { fputs("{\"schema\":\"s2a-direct-attempt-v1\",\"schema\":\"x\"}", file); fclose(file); }
    CHECK_RC(s2a_direct_attempt_read(state, key_a, &got), S2A_ATTEMPT_CORRUPT, "duplicate key corrupt");

    // 故障注入：每个落盘步骤都必须返回失败，不能静默发布。
    const int faults[] = { 1, 2, 3, 4, 5 };
    const char *names[] = { "write", "fsync file", "rename", "fsync dir", "mkdir" };
    for (unsigned i = 0; i < sizeof faults / sizeof *faults; i++) {
        char key[65];
        memset(key, 'a' + (char)i, 64); key[64] = 0;
        attempt(&a, key, S2A_ATTEMPT_PREPARED, names[i]);
        s2a_direct_attempt_fault(faults[i]);
        int rc = s2a_direct_attempt_write(state, &a);
        s2a_direct_attempt_fault(0);
        if (rc != S2A_ATTEMPT_IO) { printf("FAIL fault %s: rc=%d\n", names[i], rc); g_failures++; }
        if (faults[i] != 4) {
            struct s2a_direct_attempt_v1 tmp;
            int read_rc = s2a_direct_attempt_read(state, key, &tmp);
            if (read_rc == S2A_ATTEMPT_OK) { printf("FAIL fault %s left a visible attempt\n", names[i]); g_failures++; }
        }
    }

    // P2-60：到 fsync_path 内才注入同步结果，旧的故障 4 会提前短路，抓不到 EINVAL 被吞。
    // rename/unlink 已经发生：只能判不能报告持久化成功，不宣称文件从未可见或回滚。
    for (int fault = 6; fault <= 7; fault++) {
        const char *error = fault == 6 ? "EINVAL" : "EIO";
        CHECK_RC(s2a_direct_attempt_clear(state, key_a), S2A_ATTEMPT_OK, "clear before fsync fault");
        attempt(&a, key_a, S2A_ATTEMPT_COMMITTED, error);
        s2a_direct_attempt_fault(fault);
        CHECK_RC(s2a_direct_attempt_write(state, &a), S2A_ATTEMPT_IO,
                 fault == 6 ? "attempt fsync EINVAL" : "attempt fsync EIO");
        CHECK_RC(s2a_direct_attempt_read(state, key_a, &got), S2A_ATTEMPT_OK, "renamed attempt remains readable");
        CHECK(got.phase == S2A_ATTEMPT_COMMITTED && !strcmp(got.reason, error), "renamed attempt is complete");
        CHECK_RC(s2a_direct_failure_write(state, &f), S2A_ATTEMPT_IO,
                 fault == 6 ? "failure fsync EINVAL" : "failure fsync EIO");
        char failure_path[700];
        CHECK_RC(s2a_direct_attempt_path(state, key_a, "failure.json", failure_path, sizeof failure_path),
                 S2A_ATTEMPT_OK, "failure path after fsync fault");
        CHECK(!stat(failure_path, &st) && S_ISREG(st.st_mode), "renamed failure remains visible");
        CHECK_RC(s2a_direct_attempt_clear(state, key_a), S2A_ATTEMPT_IO,
                 fault == 6 ? "clear fsync EINVAL" : "clear fsync EIO");
        CHECK(s2a_direct_attempt_pending(state, key_a) == 0, "unlink precedes failed directory sync");
        s2a_direct_attempt_fault(0);
        CHECK_RC(s2a_direct_attempt_write(state, &a), S2A_ATTEMPT_OK, "write after disabling fsync fault");
        CHECK_RC(s2a_direct_attempt_clear(state, key_a), S2A_ATTEMPT_OK, "clear after disabling fsync fault");
    }

    // 路径越界：key 非小写 hex、name 带路径分隔符。
    CHECK_RC(s2a_direct_attempt_path(state, "ABCDEF", "attempt.json", path, sizeof path), S2A_ATTEMPT_ARGUMENT, "short key");
    CHECK_RC(s2a_direct_attempt_path(state, key_a, "../x", path, sizeof path), S2A_ATTEMPT_ARGUMENT, "traversal name");

    if (g_failures) { printf("direct-attempt: %d FAILURES\n", g_failures); return 1; }
    printf("direct-attempt: ok\n");
    return 0;
}

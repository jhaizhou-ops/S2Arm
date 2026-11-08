// C1：relocation 前选择事务的故障注入与计数。
// fake provider 只验选择器行为，不冒充 Vulkan；真实 device 的 C3 证据另列。
#define _GNU_SOURCE
#include "../native/direct/selection.h"
#include "../native/direct/attempt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

void s2a_direct_selection_fault(int point);
void s2a_direct_attempt_fault(int point);

static int g_failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); g_failures++; } } while (0)
#define CHECK_RC(expr, want, what) do { int32_t _r = (int32_t)(expr); if (_r != (int32_t)(want)) { printf("FAIL %s: rc=%d want=%d\n", what, _r, (int32_t)(want)); g_failures++; } } while (0)

static const char *profile_hash =
    "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
// 真机上 descriptor 的离线 profile 与本机合成（live）profile 不是同一把：
// 预检只能算离线键，commit 的真实身份是 live 键。两者必须同时落锁、同时清。
static const char *live_profile_hash =
    "sha256-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
static const char *provider_profile = NULL;   // NULL = 与离线 profile 相同

static int available = 1, prepare_calls, destroy_calls, prepare_rc, destroy_ok = 1;
static int table_on_failure = 1, owner;

static int fake_available(void) { return available; }
static int32_t fake_activate(void *ctx) { (void)ctx; return 0; }
static int32_t fake_stop(void *ctx) { (void)ctx; return 0; }
static int32_t fake_query(void *ctx, s2a_direct_status_v1 *out) {
    (void)ctx; return s2a_direct_status_init(out);
}
static int32_t fake_poll(void *ctx, uint32_t budget) { (void)ctx; return budget <= 10 ? 0 : -1; }
static int32_t fake_destroy(void *ctx) { (void)ctx; destroy_calls++; return destroy_ok ? 0 : -8; }

static void fill_table(struct s2a_direct_api_v1 *table) {
    table->size = S2A_DIRECT_TABLE_SIZE;
    table->version = S2A_DIRECT_ABI;
    table->session = 0;   // 由 prepare 填
    table->context = &owner;
    table->activate = fake_activate;
    table->request_stop = fake_stop;
    table->query = fake_query;
    table->poll = fake_poll;
    table->destroy = fake_destroy;
}

static int32_t fake_prepare(const struct s2a_graphics_descriptor_v1 *descriptor, uint64_t session,
                            const char *state_dir, void *user, struct s2a_direct_api_v1 *table,
                            char effective_profile_hash[72], struct s2a_direct_counts *counts,
                            char *why, size_t why_size) {
    (void)descriptor; (void)state_dir; (void)user;
    prepare_calls++;
    if (prepare_rc) {
        if (table_on_failure) { fill_table(table); table->session = session; }
        snprintf(why, why_size, "fake prepare failure");
        return prepare_rc;
    }
    fill_table(table);
    table->session = session;
    snprintf(effective_profile_hash, 72, "%s", provider_profile ? provider_profile : profile_hash);
    counts->devices = 1; counts->queues = 1; counts->workers = 1; counts->consumers = 1;
    return 0;
}

static struct s2a_direct_provider provider = { "fake", fake_available, fake_prepare, NULL };

static char json[2048];
static struct s2a_graphics_descriptor_v1 descriptor;

static void build_descriptor(void) {
    char hash[65];
    memset(hash, 'a', 64); hash[64] = 0;
    snprintf(json, sizeof json,
        "{\"schema\":\"s2a-graphics-v1\",\"titleId\":\"01001B300B9BE000\","
        "\"gameContentRoot\":\"sha256-%s\",\"moduleSetDigest\":\"sha256-%s\","
        "\"frontend\":\"nvn\",\"backend\":\"vulkan-direct\",\"directABI\":1,"
        "\"translatorClosure\":\"ryujinx-2026.10-dsh1\",\"sourceParserVersion\":1,"
        "\"profiles\":[{\"profileHash\":\"%s\"}],"
        "\"files\":[{\"path\":\"shaders/vulkan/direct/1/%s/file.program\",\"size\":1,\"sha256\":\"%s\"}],"
        "\"runtimeCompilerABI\":\"s2a-direct-compile-v1\"}", hash, hash, profile_hash, profile_hash, hash);
    char why[128];
    if (s2a_graphics_descriptor_parse((const uint8_t *)json, strlen(json), &descriptor, why, sizeof why)) {
        printf("FAIL descriptor: %s\n", why); g_failures++;
    }
}

static void reset(void) {
    available = 1; prepare_calls = destroy_calls = 0; prepare_rc = 0; destroy_ok = 1;
    table_on_failure = 1;
    s2a_direct_attempt_fault(0);
    s2a_direct_selection_fault(0);
}

static char state[600];
static uint64_t session = 0xfeedfacecafebeefull;

int main(void) {
    const char *tmp = getenv("S2A_TEST_TMP");
    if (!tmp || !*tmp) tmp = getenv("TMPDIR");
    char template[512];
    snprintf(template, sizeof template, "%s/s2a-direct-select-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    CHECK(mkdtemp(template) != NULL, "mkdtemp");
    snprintf(state, sizeof state, "%s/state", template);
    build_descriptor();
    struct s2a_direct_selection s;
    char why[128];

    // 空库用真实 live profile 建锁。模拟 commit 后进程被强杀，下一次 AUTO 必须
    // 检查 live 键并清退候选，而不是因为 profiles=[] 就忘记上一次故障。
    {
        struct s2a_graphics_descriptor_v1 empty;
        char hash[65], empty_json[1024], parse_why[128];
        memset(hash, 'a', 64); hash[64] = 0;
        snprintf(empty_json, sizeof empty_json,
            "{\"schema\":\"s2a-graphics-v1\",\"titleId\":\"01001B300B9BE000\","
            "\"gameContentRoot\":\"sha256-%s\",\"moduleSetDigest\":\"sha256-%s\","
            "\"frontend\":\"nvn\",\"backend\":\"vulkan-direct\",\"directABI\":1,"
            "\"translatorClosure\":\"ryujinx-2026.10-dsh1\",\"sourceParserVersion\":1,"
            "\"profiles\":[],\"files\":[],\"runtimeCompilerABI\":\"s2a-direct-compile-v1\"}", hash, hash);
        int parsed = s2a_graphics_descriptor_parse((const uint8_t *)empty_json, strlen(empty_json),
                                                   &empty, parse_why, sizeof parse_why);
        CHECK(parsed == 0, "empty selection descriptor parses");
        if (parsed == 0) {
        char empty_state[700], live_key[65], err[96];
        snprintf(empty_state, sizeof empty_state, "%s/empty-profile", state);
        int pipes[2]; CHECK(pipe(pipes) == 0, "empty force-stop pipe");
        pid_t pid = fork();
        if (pid == 0) {
            close(pipes[0]); reset();
            struct s2a_direct_selection child; char message[128];
            int rc = s2a_direct_select(&empty, S2A_DIRECT_MODE_AUTO, session + 200,
                                       empty_state, &provider, &child, message, sizeof message);
            char ok = rc == 0 && child.decision == S2A_DIRECT_DECISION_DIRECT ? '1' : '0';
            if (write(pipes[1], &ok, 1) != 1) _exit(2);
            for (;;) pause();
        }
        close(pipes[1]); char ok = 0;
        CHECK(pid > 0 && read(pipes[0], &ok, 1) == 1 && ok == '1', "empty auto commits direct");
        close(pipes[0]);
        if (pid > 0) { kill(pid, SIGKILL); int status = 0; waitpid(pid, &status, 0);
            CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL, "empty committed process force-stopped"); }
        reset();
        CHECK_RC(s2a_direct_select(&empty, S2A_DIRECT_MODE_AUTO, session + 201, empty_state,
                                   &provider, &s, why, sizeof why), 0, "empty auto after force-stop");
        CHECK(s.decision == S2A_DIRECT_DECISION_GENERIC && prepare_calls == 1 && destroy_calls == 1,
              "empty force-stop falls back after live identity check");
        CHECK_RC(s2a_direct_implementation_key(&empty, profile_hash, live_key, err, sizeof err), 0, "empty live key");
        CHECK_RC(s2a_direct_attempt_clear(empty_state, live_key), 0, "empty force-stop cleanup");
        }
    }

    // 手动 generic 优先，不碰 provider。
    reset();
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_GENERIC, session, state, &provider, &s, why, sizeof why), 0, "generic preference");
    CHECK(s.decision == S2A_DIRECT_DECISION_GENERIC && s.mode == 0 && prepare_calls == 0, "generic no device");

    // AUTO 无 descriptor -> generic。
    reset();
    CHECK_RC(s2a_direct_select(NULL, S2A_DIRECT_MODE_AUTO, session, state, &provider, &s, why, sizeof why), 0, "auto no descriptor");
    CHECK(s.decision == S2A_DIRECT_DECISION_GENERIC && prepare_calls == 0, "auto no descriptor generic");
    // 手动 direct 无 descriptor -> 明确失败，不改 generic。
    reset();
    CHECK(s2a_direct_select(NULL, S2A_DIRECT_MODE_DIRECT, session, state, &provider, &s, why, sizeof why) < 0,
          "manual direct no descriptor fails");
    CHECK(s.decision == S2A_DIRECT_DECISION_PENDING, "manual failure not generic");

    // AUTO provider 不可用 -> generic。
    reset(); available = 0;
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session, state, &provider, &s, why, sizeof why), 0, "auto unavailable");
    CHECK(s.decision == S2A_DIRECT_DECISION_GENERIC && prepare_calls == 0, "unavailable generic");

    // AUTO 成功：只有一个 device/queue/worker，写 attempt 并 commit。
    reset();
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session, state, &provider, &s, why, sizeof why), 0, "auto direct");
    CHECK(s.decision == S2A_DIRECT_DECISION_DIRECT && s.mode == 1, "auto direct decision");
    CHECK(s.counts.devices == 1 && s.counts.queues == 1 && s.counts.workers == 1 && s.counts.consumers == 1,
          "one backend");
    CHECK(prepare_calls == 1 && destroy_calls == 0, "prepare once, no rollback");
    CHECK(strlen(s.implementation_key) == 64, "implementation key");
    struct s2a_direct_attempt_v1 attempt;
    CHECK_RC(s2a_direct_attempt_read(state, s.implementation_key, &attempt), S2A_ATTEMPT_OK, "attempt written");
    CHECK(attempt.phase == S2A_ATTEMPT_COMMITTED && attempt.session == session, "attempt committed");
    CHECK(s2a_direct_attempt_pending(state, s.implementation_key) == 1, "lock pending after commit");

    // 遗留 attempt：AUTO -> generic（不创建候选），手动 direct -> 受控重试一次。
    reset();
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session + 1, state, &provider, &s, why, sizeof why), 0, "auto leftover");
    CHECK(s.decision == S2A_DIRECT_DECISION_GENERIC && prepare_calls == 0, "leftover blocks auto");
    reset();
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_DIRECT, session + 2, state, &provider, &s, why, sizeof why), 0, "manual retry");
    CHECK(s.decision == S2A_DIRECT_DECISION_DIRECT && prepare_calls == 1, "manual retry prepares");
    CHECK_RC(s2a_direct_attempt_clear(state, s.implementation_key), 0, "clear after retry test");

    // 正常收尾：s2a_direct_finish 必须用完整的 64 hex 键清掉 commit 写的 attempt。
    // 回归：g_lock_key 曾经是 64 字节（键实际 65），截断后 clear 被 hex_lower_64 拒，
    // 真机上表现为第二局直接回落 generic "previous direct attempt did not end normally"。
    CHECK_RC(s2a_direct_finish(1), S2A_DIRECT_RES_OK, "finish clears attempt lock");
    CHECK(!s2a_direct_attempt_pending(state, s.implementation_key), "finish cleared pending attempt");
    CHECK_RC(s2a_direct_finish(1), S2A_DIRECT_RES_OK, "finish twice is a no-op");
    CHECK_RC(s2a_direct_finish(0), S2A_DIRECT_RES_OK, "finish without a held lock is a no-op");

    // 设备上 descriptor 声明的 profile（离线）与本机合成的 effective profile（live）不同：
    // 仅变这一项，预检键与 commit 键就会分叉。回归（真机 10-28）：正常收局只清了 live 键，
    // 离线键永久留下，AUTO 下次启动直接回 generic，且正常收尾再也清不掉。
    {
        char state2[700], why2[128];
        struct s2a_direct_selection s2;
        char live_key[65], offline_key[65], err[96];
        snprintf(state2, sizeof state2, "%s/profile-mismatch", state);
        provider_profile = live_profile_hash;
        reset();
        CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session + 100, state2, &provider, &s2, why2, sizeof why2), 0, "mismatch auto");
        CHECK(s2.decision == S2A_DIRECT_DECISION_DIRECT, "mismatch direct");
        CHECK_RC(s2a_direct_implementation_key(&descriptor, live_profile_hash, live_key, err, sizeof err), 0, "mismatch live key");
        CHECK_RC(s2a_direct_implementation_key(&descriptor, profile_hash, offline_key, err, sizeof err), 0, "mismatch offline key");
        CHECK(strcmp(live_key, offline_key) != 0, "live and offline keys differ");
        CHECK(s2a_direct_attempt_pending(state2, live_key) == 1, "mismatch live lock");
        CHECK(s2a_direct_attempt_pending(state2, offline_key) == 1, "mismatch offline alias lock");
        // 异常结束（不调用 finish）：AUTO 预检必须看到离线别名并直接 generic，不创建设备。
        reset();
        CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session + 101, state2, &provider, &s2, why2, sizeof why2), 0, "mismatch leftover");
        CHECK(s2.decision == S2A_DIRECT_DECISION_GENERIC && prepare_calls == 0, "mismatch alias blocks auto before device");
        // 手动 direct 重试 + 正常收尾：两把键都要清掉；AUTO 之后回到 direct。
        reset();
        CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_DIRECT, session + 102, state2, &provider, &s2, why2, sizeof why2), 0, "mismatch manual retry");
        CHECK_RC(s2a_direct_finish(1), S2A_DIRECT_RES_OK, "mismatch finish");
        CHECK(!s2a_direct_attempt_pending(state2, live_key), "mismatch live key cleared");
        CHECK(!s2a_direct_attempt_pending(state2, offline_key), "mismatch offline alias cleared");
        reset();
        CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session + 103, state2, &provider, &s2, why2, sizeof why2), 0, "mismatch auto after finish");
        CHECK(s2.decision == S2A_DIRECT_DECISION_DIRECT && prepare_calls == 1, "mismatch auto direct after clear");
        CHECK_RC(s2a_direct_finish(1), S2A_DIRECT_RES_OK, "mismatch cleanup");
        // 只有 live 键（别名已被删/不可见）：AUTO 在 prepare 之后也要发现并回滚，
        // 不能把“commit 后崩溃”的重启当成首次启动。
        struct s2a_direct_attempt_v1 only;
        memset(&only, 0, sizeof only);
        snprintf(only.attempt_id, sizeof only.attempt_id, "%s", "0123456789abcdef0123456789abcdef");
        snprintf(only.implementation_key, sizeof only.implementation_key, "%s", live_key);
        only.session = session + 104;
        only.phase = S2A_ATTEMPT_COMMITTED;
        CHECK_RC(s2a_direct_attempt_write(state2, &only), S2A_ATTEMPT_OK, "write live-only attempt");
        reset();
        CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session + 105, state2, &provider, &s2, why2, sizeof why2), 0, "live-only pending auto");
        CHECK(s2.decision == S2A_DIRECT_DECISION_GENERIC && prepare_calls == 1 && destroy_calls == 1,
              "live key checked after prepare and rolled back");
        CHECK_RC(s2a_direct_attempt_clear(state2, live_key), 0, "clear live-only attempt");
        provider_profile = NULL;
    }

    // Prepare 结构性失败：回滚候选并 generic；回滚失败则致命。
    reset(); prepare_rc = S2A_DIRECT_RES_UNSUPPORTED;
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session, state, &provider, &s, why, sizeof why), 0, "auto prepare fail");
    CHECK(s.decision == S2A_DIRECT_DECISION_GENERIC && prepare_calls == 1 && destroy_calls == 1, "prepare fail rollback");
    CHECK(!s2a_direct_attempt_pending(state, s.implementation_key), "no attempt after prepare fail");
    reset(); prepare_rc = S2A_DIRECT_RES_UNSUPPORTED; destroy_ok = 0;
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session, state, &provider, &s, why, sizeof why), S2A_DIRECT_RES_RETIREMENT, "rollback failure fatal");
    CHECK(s.decision == S2A_DIRECT_DECISION_PENDING, "rollback failure no decision");
    reset(); prepare_rc = S2A_DIRECT_RES_UNSUPPORTED;
    CHECK(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_DIRECT, session, state, &provider, &s, why, sizeof why) == S2A_DIRECT_RES_UNSUPPORTED,
          "manual prepare fail surfaces error");

    // attempt 写失败（commit 前）-> generic + 回滚；手动 direct 失败。
    reset(); s2a_direct_attempt_fault(1);
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session, state, &provider, &s, why, sizeof why), 0, "attempt write fail auto");
    CHECK(s.decision == S2A_DIRECT_DECISION_GENERIC && destroy_calls == 1, "attempt fail rollback to generic");
    reset(); s2a_direct_attempt_fault(1);
    CHECK(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_DIRECT, session, state, &provider, &s, why, sizeof why) < 0,
          "attempt fail manual direct errors");
    s2a_direct_attempt_fault(0);

    // commit 后更新失败：不发布 direct、保留 attempt、返回致命错误。
    reset(); s2a_direct_selection_fault(1);
    CHECK_RC(s2a_direct_select(&descriptor, S2A_DIRECT_MODE_AUTO, session, state, &provider, &s, why, sizeof why), S2A_DIRECT_RES_INTERNAL,
          "post-commit failure fatal");
    CHECK(s.decision == S2A_DIRECT_DECISION_PENDING, "post-commit not published");
    char key[65];
    char err[96];
    CHECK_RC(s2a_direct_implementation_key(&descriptor, profile_hash, key, err, sizeof err), 0, "key for post commit");
    CHECK(s2a_direct_attempt_pending(state, key) == 1, "attempt retained after post-commit failure");
    CHECK_RC(s2a_direct_attempt_clear(state, key), 0, "clear post commit");
    s2a_direct_selection_fault(0);

    // 参数负例
    CHECK(s2a_direct_select(&descriptor, 3, session, state, &provider, &s, why, sizeof why) < 0, "bad preference");
    CHECK(s2a_direct_select(&descriptor, 0, 0, state, &provider, &s, why, sizeof why) < 0, "zero session");
    CHECK(s2a_direct_select(&descriptor, 0, session, "relative", &provider, &s, why, sizeof why) < 0, "relative state");

    // 发布只能一次，且发布后 generic 不提供 direct table。
    struct s2a_direct_selection g = s;
    memset(&g, 0, sizeof g);
    g.decision = S2A_DIRECT_DECISION_GENERIC;
    g.mode = 0;
    CHECK_RC(s2a_direct_selection_publish(&g), 0, "publish generic");
    const struct s2a_direct_selection *current = s2a_direct_selection_current();
    CHECK(current && current->decision == S2A_DIRECT_DECISION_GENERIC, "current generic");
    CHECK(s2a_direct_selection_publish(&g) < 0, "second publish rejected");

    if (g_failures) { printf("direct-selection: %d FAILURES\n", g_failures); return 1; }
    printf("direct-selection: ok\n");
    return 0;
}

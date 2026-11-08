// #274：direct-vulkan.txt 只有一份解析（direct_choice.c）。同一份描述，s2a_vk_descriptor_read、
// 就绪判定 s2a_vk_lib_ready、AUTO 判定 s2a_vk_auto_resolve 给同一结论；AUTO 回通用的原因点名读到的文件；
// attempt 标记原子写、正常结束删；fail 只在手动直连正常结束时清（s2a_vk_session_end）。手动直连的会话侧（session_prepare 对坏描述返回错误）由
// native/direct-vk-tests/session_test.c 证，这里另查 direct_session.c 里没有第二份解析。
// 使用临时目录；不含游戏数据。用法：direct_choice_test <android/native/direct_session.c>
#define _GNU_SOURCE
#include "../native/direct_choice.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); g_failures++; } } while (0)
#define CHECK_RC(expr, want, what) do { int _r = (expr); if (_r != (want)) { printf("FAIL %s: rc=%d want=%d\n", what, _r, (int)(want)); g_failures++; } } while (0)

static char game[600], state[600], descriptor[700], fail[700], attempt[700];

static void write_file(const char *path, const char *text, size_t n) {
    FILE *f = fopen(path, "wb");
    CHECK(f != NULL, path);
    if (!f) return;
    CHECK(fwrite(text, 1, n, f) == n, path);
    CHECK(fclose(f) == 0, path);
}
static void write_text(const char *path, const char *text) { write_file(path, text, strlen(text)); }
static int exists(const char *path) { struct stat st; return stat(path, &st) == 0; }

// 描述矩阵：每一例三处入口同一结论；无效时 AUTO 原因点名描述文件
struct row { const char *name; const char *text; int bytes; int want; unsigned mask; };
static const struct row rows[] = {
    {"header only", "S2ARM_VULKAN_DIRECT_V1\n", -1, 0, 0},
    {"two modules", "S2ARM_VULKAN_DIRECT_V1\nsubsdk0\nsubsdk1\n", -1, 0, 0x3},
    {"all ten modules", "S2ARM_VULKAN_DIRECT_V1\nsubsdk9\nsubsdk0\nsubsdk1\nsubsdk2\nsubsdk3\nsubsdk4\nsubsdk5\nsubsdk6\nsubsdk7\nsubsdk8\n", -1, 0, 0x3ff},
    {"empty file", "", -1, EINVAL, 0},
    {"header without newline", "S2ARM_VULKAN_DIRECT_V1", -1, EINVAL, 0},
    {"wrong header", "S2ARM_VULKAN_DIRECT_V2\nsubsdk0\n", -1, EINVAL, 0},
    {"crlf header", "S2ARM_VULKAN_DIRECT_V1\r\nsubsdk0\r\n", -1, EINVAL, 0},
    {"main module", "S2ARM_VULKAN_DIRECT_V1\nmain\n", -1, EINVAL, 0},
    {"duplicate module", "S2ARM_VULKAN_DIRECT_V1\nsubsdk0\nsubsdk0\n", -1, EINVAL, 0},
    {"two-digit module", "S2ARM_VULKAN_DIRECT_V1\nsubsdk10\n", -1, EINVAL, 0},
    {"module without newline", "S2ARM_VULKAN_DIRECT_V1\nsubsdk0", -1, EINVAL, 0},
    {"blank line", "S2ARM_VULKAN_DIRECT_V1\nsubsdk0\n\n", -1, EINVAL, 0},
    {"trailing space", "S2ARM_VULKAN_DIRECT_V1\nsubsdk0 \n", -1, EINVAL, 0},
    {"embedded nul", "S2ARM_VULKAN_DIRECT_V1\nsub\0dk0\n", 31, EINVAL, 0},
    {"overlong line", "S2ARM_VULKAN_DIRECT_V1\nsubsdk0xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", -1, EINVAL, 0},
};

static void same_verdict(const char *what, int want, unsigned want_mask) {
    unsigned mask = 0xdead;
    char why[2048] = "";
    int rc = s2a_vk_descriptor_read(game, &mask);
    CHECK_RC(rc, want, what);
    if (!want) CHECK(mask == want_mask, what);
    else CHECK(mask == 0xdead, what);   // 无效时不改调用方的位图
    CHECK(s2a_vk_lib_ready(game) == (rc == 0), what);
    CHECK(s2a_vk_auto_resolve(game, state, why, sizeof why) == (rc == 0), what);
    CHECK(strstr(why, descriptor) != NULL, what);
    if (rc) CHECK(strstr(why, "本包没有有效的") != NULL, what);
}

int main(int argc, char **argv) {
    const char *tmp = getenv("S2A_TEST_TMP");
    if (!tmp || !*tmp) tmp = getenv("TMPDIR");
    char root[512];
    snprintf(root, sizeof root, "%s/s2a-direct-choice-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    CHECK(mkdtemp(root) != NULL, "mkdtemp");
    snprintf(game, sizeof game, "%s/game", root);
    snprintf(state, sizeof state, "%s/state", root);
    snprintf(descriptor, sizeof descriptor, "%s/direct-vulkan.txt", game);
    snprintf(fail, sizeof fail, "%s/vulkan-direct.fail", state);
    snprintf(attempt, sizeof attempt, "%s/vulkan-direct.attempt", state);
    CHECK(mkdir(game, 0700) == 0 && mkdir(state, 0700) == 0, "mkdir");

    same_verdict("missing descriptor", ENOENT, 0);
    for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        size_t n = rows[i].bytes < 0 ? strlen(rows[i].text) : (size_t)rows[i].bytes;
        write_file(descriptor, rows[i].text, n);
        same_verdict(rows[i].name, rows[i].want, rows[i].mask);
    }
    // 描述路径是个目录：打得开、读不了 → EIO，三处同样不就绪
    CHECK(unlink(descriptor) == 0 && mkdir(descriptor, 0700) == 0, "descriptor as directory");
    same_verdict("descriptor is a directory", EIO, 0);
    CHECK(rmdir(descriptor) == 0, "rmdir descriptor");

    // 参数：空目录名、路径太长
    CHECK_RC(s2a_vk_descriptor_read(NULL, NULL), EINVAL, "null game dir");
    CHECK_RC(s2a_vk_descriptor_read("", NULL), EINVAL, "empty game dir");
    CHECK(!s2a_vk_lib_ready(NULL), "lib_ready null");
    static char long_dir[5000];
    memset(long_dir, 'x', sizeof long_dir - 1);
    long_dir[0] = '/';
    CHECK_RC(s2a_vk_descriptor_read(long_dir, NULL), ENAMETOOLONG, "long game dir");
    CHECK(!s2a_vk_lib_ready(long_dir), "lib_ready long dir");
    char why[2048];
    CHECK(!s2a_vk_auto_resolve(NULL, state, why, sizeof why) && strstr(why, "没有游戏目录或状态目录"), "auto without game dir");
    CHECK(!s2a_vk_auto_resolve(game, "", why, sizeof why) && strstr(why, "没有游戏目录或状态目录"), "auto without state dir");

    // 有效描述 + 上局标记：fail 先于 attempt，原因点名文件；fail 带首行，空文件写“空”
    write_text(descriptor, "S2ARM_VULKAN_DIRECT_V1\nsubsdk0\n");
    CHECK(s2a_vk_auto_resolve(game, state, why, sizeof why) == 1 && strstr(why, "就绪："), "ready without markers");
    write_text(fail, "device lost\nsecond line\n");
    CHECK(!s2a_vk_auto_resolve(game, state, why, sizeof why), "fail marker → generic");
    CHECK(strstr(why, fail) && strstr(why, "上局直连失败") && strstr(why, "（device lost）") && !strstr(why, "second"), "fail reason names file and first line");
    CHECK(s2a_vk_lib_ready(game), "fail marker does not change package readiness");
    write_text(fail, "");
    CHECK(!s2a_vk_auto_resolve(game, state, why, sizeof why) && strstr(why, "（空）"), "empty fail marker");
    CHECK_RC(s2a_vk_attempt_begin(state), 0, "begin with fail marker present");
    CHECK(!s2a_vk_auto_resolve(game, state, why, sizeof why) && strstr(why, fail), "fail reported before attempt");
    CHECK(unlink(fail) == 0, "remove fail");
    CHECK(!s2a_vk_auto_resolve(game, state, why, sizeof why), "attempt marker → generic");
    CHECK(strstr(why, attempt) && strstr(why, "上局直连没有正常结束"), "attempt reason names file");

    // attempt：原子写（没有 .tmp 残留）、内容完整；end 删掉，重复 end 也是 0
    char tmpfile[800];
    snprintf(tmpfile, sizeof tmpfile, "%s.tmp", attempt);
    struct stat st;
    CHECK(!stat(attempt, &st) && S_ISREG(st.st_mode) && (st.st_mode & 0777) == 0600 && !exists(tmpfile), "attempt file");
    FILE *f = fopen(attempt, "r");
    char line[64] = "";
    CHECK(f && fgets(line, sizeof line, f) && !strcmp(line, "vulkan-direct attempt\n"), "attempt content");
    if (f) fclose(f);
    CHECK_RC(s2a_vk_attempt_begin(state), 0, "begin again overwrites");
    CHECK_RC(s2a_vk_attempt_end(state), 0, "end");
    CHECK(!exists(attempt), "attempt removed");
    CHECK_RC(s2a_vk_attempt_end(state), 0, "end when absent");
    CHECK(s2a_vk_auto_resolve(game, state, why, sizeof why) == 1, "ready again after end");
    char missing[700];
    snprintf(missing, sizeof missing, "%s/no-such-dir", root);
    CHECK_RC(s2a_vk_attempt_begin(missing), ENOENT, "begin in missing dir");
    CHECK_RC(s2a_vk_attempt_begin(""), EINVAL, "begin empty dir");
    CHECK_RC(s2a_vk_attempt_end(NULL), EINVAL, "end null dir");
    CHECK_RC(s2a_vk_attempt_begin(long_dir), ENAMETOOLONG, "begin long dir");

    // 会话结束（维护方定，同 NVN 直连 s2a_direct_finish）：
    // ① 上局失败留下 fail → 手动直连重试且正常结束 → fail 与 attempt 都清 → AUTO 恢复走直连
    write_text(fail, "device lost\n");
    CHECK(!s2a_vk_auto_resolve(game, state, why, sizeof why), "fail before manual retry");
    CHECK_RC(s2a_vk_attempt_begin(state), 0, "manual retry begins");
    CHECK_RC(s2a_vk_session_end(state, S2A_VK_CHOICE_DIRECT, 1, 0), 0, "manual normal end");
    CHECK(!exists(fail) && !exists(attempt), "manual normal end clears fail and attempt");
    CHECK(s2a_vk_auto_resolve(game, state, why, sizeof why) == 1, "AUTO goes direct again after manual normal end");
    // ② 手动直连再次异常结束（被杀 / 停不干净 = normal 0）→ fail、attempt 都留着 → AUTO 仍回通用
    write_text(fail, "device lost\n");
    CHECK_RC(s2a_vk_attempt_begin(state), 0, "manual retry begins again");
    CHECK_RC(s2a_vk_session_end(state, S2A_VK_CHOICE_DIRECT, 0, 0), 0, "manual abnormal end");
    CHECK(exists(fail) && exists(attempt), "manual abnormal end keeps fail and attempt");
    CHECK(!s2a_vk_auto_resolve(game, state, why, sizeof why) && strstr(why, fail), "AUTO still generic after manual abnormal end");
    // ③ 手动直连本局又写了 fail（设备丢失后照常停下）→ 正常停止只清 attempt，fail 留着
    CHECK_RC(s2a_vk_session_end(state, S2A_VK_CHOICE_DIRECT, 1, 1), 0, "manual end after failing this session");
    CHECK(exists(fail) && !exists(attempt), "fail written this session is kept");
    CHECK(!s2a_vk_auto_resolve(game, state, why, sizeof why) && strstr(why, fail), "AUTO generic after this session's failure");
    // ④ AUTO 正常结束不清 fail（只清 attempt）；通用什么都不碰；参数不对 EINVAL
    CHECK_RC(s2a_vk_attempt_begin(state), 0, "auto session begins");
    CHECK_RC(s2a_vk_session_end(state, S2A_VK_CHOICE_AUTO, 1, 0), 0, "auto normal end");
    CHECK(exists(fail) && !exists(attempt), "AUTO normal end keeps fail");
    CHECK_RC(s2a_vk_attempt_begin(state), 0, "attempt for generic check");
    CHECK_RC(s2a_vk_session_end(state, S2A_VK_CHOICE_GENERIC, 1, 0), 0, "generic end");
    CHECK(exists(fail) && exists(attempt), "generic end touches nothing");
    CHECK_RC(s2a_vk_session_end(NULL, S2A_VK_CHOICE_DIRECT, 1, 0), EINVAL, "session_end null dir");
    CHECK(unlink(fail) == 0 && s2a_vk_attempt_end(state) == 0, "reset markers");

    // 原因缓冲：可传 NULL；很小也只截断不越界
    CHECK(s2a_vk_auto_resolve(game, state, NULL, 0) == 1, "null why");
    char small[8];
    memset(small, '#', sizeof small);
    CHECK(s2a_vk_auto_resolve(game, state, small, 4) == 1 && small[3] == 0 && small[4] == '#', "small why truncates in bounds");

    // 唯一解析：direct_session.c 不再有自己的 direct-vulkan.txt 解析，只经 s2a_vk_descriptor_read
    if (argc == 2) {
        FILE *s = fopen(argv[1], "r");
        static char source[1 << 17];
        size_t n = s ? fread(source, 1, sizeof source - 1, s) : 0;
        if (s) fclose(s);
        source[n] = 0;
        CHECK(n > 0 && strstr(source, "s2a_vk_descriptor_read(game_dir, &mask)") != NULL, "session uses the shared parser");
        CHECK(strstr(source, "S2ARM_VULKAN_DIRECT_V1") == NULL, "session has no second parser");
        // 会话停止经 s2a_vk_session_end 清标记（attempt / fail 同一处），不在别处另删
        CHECK(strstr(source, "s2a_vk_session_end(attempt_dir, session_choice, !result, atomic_load(&failed_now))") != NULL, "stop uses session_end");
        CHECK(strstr(source, "unlink(") == NULL, "session deletes no marker itself");
    } else CHECK(0, "usage: direct_choice_test <direct_session.c>");

    unlink(descriptor);
    rmdir(game);
    rmdir(state);
    rmdir(root);
    if (g_failures) { printf("direct_choice: %d failure(s)\n", g_failures); return 1; }
    printf("direct_choice: ok\n");
    return 0;
}

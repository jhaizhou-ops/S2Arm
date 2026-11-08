#define _GNU_SOURCE 1   // mkdtemp on glibc hosts
// F4.1 宿主回归：编译诊断只能写本局私有目录；安装 revision 在补编前后逐文件不变。
// 用真实 diag.c（与设备同源）：目录派生、文件名校验、写失败、清单摘要。
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "direct/diag.h"

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

static int write_file(const char *path, const void *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t n = len ? fwrite(data, 1, len, f) : 0;
    return fclose(f) == 0 && n == len ? 0 : -1;
}

static int mkdir_p(const char *path) {
    char part[700];
    size_t len = strlen(path);
    if (!len || len >= sizeof part) return -1;
    memcpy(part, path, len + 1);
    for (size_t i = 1; i < len; i++) {
        if (part[i] != '/') continue;
        part[i] = 0;
        if (mkdir(part, 0700) != 0 && errno != EEXIST) return -1;
        part[i] = '/';
    }
    return mkdir(part, 0700) == 0 || errno == EEXIST ? 0 : -1;
}

static int path_join(char *out, size_t n, const char *dir, const char *name) {
    size_t len = dir ? strlen(dir) : 0;
    int r = snprintf(out, n, "%s%s%s", dir ? dir : "", len && dir[len - 1] == '/' ? "" : "/", name);
    return r > 0 && (size_t)r < n ? 0 : -1;
}

int main(void) {
    char root[300];
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof root, "%s/s2a-diag-test-XXXXXX", tmp && tmp[0] ? tmp : "/tmp");
    if (!mkdtemp(root)) { printf("FAIL: mkdtemp\n"); return 1; }

    char revision[400], shader_dir[500], state[400];
    char repo_file_a[700], repo_file_b[700], nested[700], blocked[500];
    CHECK(!path_join(revision, sizeof revision, root, "revision"), "join revision");
    CHECK(!path_join(shader_dir, sizeof shader_dir, revision, "shaders/vulkan/direct"), "join shader dir");
    CHECK(!path_join(state, sizeof state, root, "state"), "join state");
    CHECK(!path_join(repo_file_a, sizeof repo_file_a, shader_dir, "a.program.json"), "join revision file a");
    CHECK(!path_join(repo_file_b, sizeof repo_file_b, shader_dir, "b.program.json"), "join revision file b");
    CHECK(!path_join(nested, sizeof nested, shader_dir, "nested"), "join nested dir");
    CHECK(!path_join(blocked, sizeof blocked, state, "blocked"), "join blocked path");
    CHECK(!mkdir_p(shader_dir), "mkdir revision shader dir");
    CHECK(!mkdir_p(state), "mkdir state");
    CHECK(!mkdir_p(nested), "mkdir nested (manifest ignores non-files)");
    const char rev_a[] = "revision-a";
    const char rev_b[] = "revision-b-longer";
    CHECK(!write_file(repo_file_a, rev_a, sizeof rev_a), "write revision file a");
    CHECK(!write_file(repo_file_b, rev_b, sizeof rev_b), "write revision file b");

    char why[192] = "";
    char diag[500] = "";
    CHECK(!s2a_direct_diag_dir(state, diag, sizeof diag, why, sizeof why), "derive diagnostics dir");
    char want[500];
    CHECK(!path_join(want, sizeof want, state, "direct-diagnostics"), "join expected diag dir");
    CHECK(!strcmp(diag, want), "diagnostics dir is <state>/direct-diagnostics");
    CHECK(strncmp(diag, revision, strlen(revision)) != 0, "diagnostics dir is outside the installation revision");

    // 空 state / 相对路径 / 过小缓冲：准确失败，不回落 revision（用单独缓冲区，不污染上面的 diag）。
    char bad[500] = "unset";
    CHECK(s2a_direct_diag_dir("", bad, sizeof bad, why, sizeof why) != 0 && bad[0] == 0, "empty state dir rejected");
    CHECK(s2a_direct_diag_dir("relative/state", bad, sizeof bad, why, sizeof why) != 0 && bad[0] == 0,
          "relative state dir rejected");
    char tiny[8] = "x";
    CHECK(s2a_direct_diag_dir(state, tiny, sizeof tiny, why, sizeof why) != 0 && tiny[0] == 0,
          "small output buffer rejected and left empty");

    // revision 清单（文件名、长度、逐文件 SHA-256）在诊断写入前后不变。
    char digest_before[65] = "", digest_after[65] = "", digest_changed[65] = "", digest_restored[65] = "";
    uint32_t files_before = 0, files_after = 0;
    uint64_t bytes_before = 0, bytes_after = 0;
    CHECK(!s2a_direct_diag_manifest(shader_dir, digest_before, sizeof digest_before, &files_before, &bytes_before,
                                    why, sizeof why), "manifest before");
    CHECK(files_before == 2, "manifest counts the two revision files (nested dir is not a file)");
    CHECK(bytes_before == sizeof rev_a + sizeof rev_b, "manifest counts revision bytes");

    const char request[] = "{\"request\":\"compile\",\"stages\":[\"vs\",\"fs\"]}";
    CHECK(!s2a_direct_diag_write(diag, "deadbeefdeadbeef.compile-request.json", request, sizeof request - 1,
                                 why, sizeof why), "write compile-request diagnostic");
    CHECK(!s2a_direct_diag_manifest(shader_dir, digest_after, sizeof digest_after, &files_after, &bytes_after,
                                    why, sizeof why), "manifest after");
    CHECK(!strcmp(digest_before, digest_after) && files_before == files_after && bytes_before == bytes_after,
          "revision unchanged after writing a diagnostic");

    char diag_path[700], back[256] = "";
    CHECK(!path_join(diag_path, sizeof diag_path, diag, "deadbeefdeadbeef.compile-request.json"), "join diag file");
    FILE *f = fopen(diag_path, "rb");
    size_t got = f ? fread(back, 1, sizeof back - 1, f) : 0;
    if (f) fclose(f);
    CHECK(got == sizeof request - 1 && !memcmp(back, request, got), "diagnostic file content matches");
    CHECK(!write_file(diag_path, "overwritten", 11), "overwrite diagnostic");
    CHECK(!s2a_direct_diag_manifest(shader_dir, digest_after, sizeof digest_after, &files_after, &bytes_after,
                                    why, sizeof why), "manifest after overwrite");
    CHECK(!strcmp(digest_before, digest_after), "revision unchanged after overwriting a diagnostic");

    // 诊断目录不可用（这里用同名普通文件占位，不依赖运行用户权限）：
    // 写失败要返回错误，revision 仍然不变，且不产生回落到 revision 的文件。
    CHECK(!write_file(blocked, "x", 1), "occupy the diagnostics path with a file");
    CHECK(s2a_direct_diag_write(blocked, "x.compile-request.json", request, sizeof request - 1, why, sizeof why) != 0,
          "unusable diagnostics dir fails");
    CHECK(!s2a_direct_diag_manifest(shader_dir, digest_after, sizeof digest_after, NULL, NULL, why, sizeof why),
          "manifest after failed diagnostic");
    CHECK(!strcmp(digest_before, digest_after), "revision unchanged after a failed diagnostic");

    // 不安全文件名不能逃出诊断目录。
    CHECK(s2a_direct_diag_write(diag, "../escape", request, sizeof request - 1, why, sizeof why) != 0, "reject ../");
    CHECK(s2a_direct_diag_write(diag, "a/b", request, sizeof request - 1, why, sizeof why) != 0, "reject slash");
    CHECK(s2a_direct_diag_write(diag, "", request, sizeof request - 1, why, sizeof why) != 0, "reject empty name");
    CHECK(s2a_direct_diag_write(diag, "..", request, sizeof request - 1, why, sizeof why) != 0, "reject ..");
    char longname[260];
    memset(longname, 'a', sizeof longname - 1);
    longname[sizeof longname - 1] = 0;
    CHECK(s2a_direct_diag_write(diag, longname, request, sizeof request - 1, why, sizeof why) != 0, "reject long name");

    // 清单能检出真实变化（否则“revision 未变”的结论没有判别力）。
    CHECK(!write_file(repo_file_a, "revision-a-changed", 18), "change a revision file");
    CHECK(!s2a_direct_diag_manifest(shader_dir, digest_changed, sizeof digest_changed, NULL, NULL, why, sizeof why),
          "manifest after revision change");
    CHECK(strcmp(digest_before, digest_changed) != 0, "manifest detects changed content");
    CHECK(!write_file(repo_file_a, rev_a, sizeof rev_a), "restore a revision file");
    CHECK(!s2a_direct_diag_manifest(shader_dir, digest_restored, sizeof digest_restored, NULL, NULL, why, sizeof why),
          "manifest after restore");
    CHECK(!strcmp(digest_before, digest_restored), "manifest is deterministic for identical content");
    char extra[700];
    CHECK(!path_join(extra, sizeof extra, shader_dir, "c.extra"), "join extra file");
    CHECK(!write_file(extra, "x", 1), "add a revision file");
    CHECK(!s2a_direct_diag_manifest(shader_dir, digest_restored, sizeof digest_restored, NULL, NULL, why, sizeof why),
          "manifest after extra file");
    CHECK(strcmp(digest_before, digest_restored) != 0, "manifest detects an added file");
    CHECK(unlink(extra) == 0, "remove extra file");

    // 目录末尾带 '/' 时不会产生双斜杠。
    char state_slash[400];
    CHECK(!path_join(state_slash, sizeof state_slash, state, ""), "join state with trailing slash");
    char diag2[500] = "";
    CHECK(!s2a_direct_diag_dir(state_slash, diag2, sizeof diag2, why, sizeof why), "derive with trailing slash");
    CHECK(!strcmp(diag2, want), "trailing slash is normalized");

    // 外部私有根目录覆盖（JNI 注入面）：非绝对/空/NULL 准确失败；设上后
    // s2a_direct_diag_dir 忽略 state_dir——连空 state 也照出覆盖根。
    CHECK(s2a_direct_diag_set_dir("relative/diag") == EINVAL, "override rejects relative root");
    CHECK(s2a_direct_diag_set_dir("") == EINVAL, "override rejects empty root");
    CHECK(s2a_direct_diag_set_dir(NULL) == EINVAL, "override rejects NULL root");
    char ext[700], ext_want[700], diag3[500] = "";
    CHECK(!path_join(ext, sizeof ext, root, "external"), "join external root");
    CHECK(s2a_direct_diag_set_dir(ext) == 0, "accept absolute external root");
    CHECK(!s2a_direct_diag_dir(state, diag3, sizeof diag3, why, sizeof why), "derive under override");
    CHECK(!path_join(ext_want, sizeof ext_want, ext, "direct-diagnostics"), "join override want");
    CHECK(!strcmp(diag3, ext_want), "override root wins over session state dir");
    memset(diag3, 0, sizeof diag3);
    CHECK(!s2a_direct_diag_dir("", diag3, sizeof diag3, why, sizeof why) && !strcmp(diag3, ext_want),
          "override supplies the root even when session state is absent");

    // 清理。
    char cleanup[400];
    CHECK(!path_join(cleanup, sizeof cleanup, root, ""), "join cleanup");
    size_t clen = strlen(cleanup);
    if (clen && cleanup[clen - 1] == '/') cleanup[clen - 1] = 0;
    char cmd[460];
    snprintf(cmd, sizeof cmd, "rm -rf %s", cleanup);
    if (system(cmd) != 0) printf("WARN: cleanup failed\n");

    if (fails) { printf("direct-diag: %d FAILURES\n", fails); return 1; }
    printf("direct-diag: ok (revision manifest unchanged; diagnostics confined to the private state dir)\n");
    return 0;
}

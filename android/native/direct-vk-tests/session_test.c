// Cold-start selection and descriptor framing; no game execution or HLE stand-in.
// AUTO（#274）：本包或上局状态不满足时回通用，stderr 恰一行点名读到的文件；手动直连照旧返回错误（runtime 据此报红）。
#include "direct_session.h"
#include "direct_choice.h"
int s2a_svc_stopping(void) { return 0; }
#include "s2a_hostapi.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int s2a_gfx_mode(void);
uint64_t s2a_direct_lookup(const char *);
const s2a_host_api_v1 *s2a_host_get(void) { return NULL; } // Not consumed by this fixture.
void *sw_xstack_wrap(const char *n, void *f) { (void)n; return f; }
uint64_t s2a_android_vk_guest_callback(void *fn, const uint64_t args[6]) { (void)fn; (void)args; abort(); }
void s2a_core_block_begin(void) { abort(); }
void s2a_core_block_end(void) { abort(); }
// 终局停住由真实 VM 提供；这个夹具不跑客体，走到这里就是夹具自己的错。
void s2a_android_guest_park_forever(void) { abort(); }
int s2a_mem_readable(uint64_t a, uint64_t s) { (void)a; (void)s; abort(); }
static int64_t query(void) { return 1; }
static void never_window(void *p) { (void)p; abort(); }
static void write_text(const char *path, const char *text) { FILE *f = fopen(path, "w"); assert(f); fputs(text, f); assert(!fclose(f)); }
static int exists(const char *path) { struct stat st; return stat(path, &st) == 0; }

// 抓 prepare 打到 stderr 的内容：AUTO 回通用必须恰好一行，且点名 expect 这个文件
static int prepare_logged(const struct s2a_wsi_api *api, const char *root, const char *log, const char *expect) {
    fflush(stderr);
    int saved = dup(2); assert(saved >= 0);
    int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0600); assert(fd >= 0);
    assert(dup2(fd, 2) == 2); close(fd);
    int result = s2a_android_vk_session_prepare(api, root, root);
    fflush(stderr); assert(dup2(saved, 2) == 2); close(saved);
    char text[8192]; FILE *f = fopen(log, "r"); assert(f);
    size_t n = fread(text, 1, sizeof text - 1, f); fclose(f); text[n] = 0;
    fputs(text, stderr);   // 原样转回，回执里看得到
    int lines = 0;
    for (size_t i = 0; i < n; i++) lines += text[i] == '\n';
    assert(lines == 1 && strstr(text, "[vk-direct] AUTO → 通用：") && strstr(text, expect));
    return result;
}

int main(int argc, char **argv) {
    assert(argc == 3);
    const char *mode = argv[1], *root = argv[2];
    int automatic = !strncmp(mode, "auto", 4);
    int manual_direct = !strcmp(mode, "direct") || !strcmp(mode, "direct-clears-fail");
    assert(s2a_gfx_mode() == 0 && s2a_direct_lookup("vkCreateInstance") == 0);
    assert(s2a_android_vk_nvn_guest() == 0);   // 还没问过 NVN 入口：客体事实为空
    assert(s2a_android_vk_select(3) == EINVAL && s2a_android_vk_select(-1) == EINVAL);   // 只有通用 0 / 直连 1 / AUTO 2
    if (!strcmp(mode, "generic")) {
        assert(s2a_android_vk_session_prepare(NULL, NULL, NULL) == 0);
        assert(s2a_android_vk_select(1) == EBUSY);
        assert(s2a_gfx_mode() == 0 && s2a_android_vk_skip_module("subsdk0") == 0);
        assert(s2a_android_vk_session_stop() == 0);
        puts("PASS generic default freezes without Vulkan setup"); return 0;
    }
    assert(s2a_android_vk_select(automatic ? 2 : 1) == 0);
    char dir[4096], file[4096], fail[4096], attempt[4096], log[4096];
    assert(snprintf(dir, sizeof dir, "%s/modules", root) < (int)sizeof dir);
    assert(mkdir(root, 0700) == 0 || errno == EEXIST);
    assert(mkdir(dir, 0700) == 0 || errno == EEXIST);
    assert(snprintf(file, sizeof file, "%s/direct-vulkan.txt", root) < (int)sizeof file);
    assert(snprintf(fail, sizeof fail, "%s/vulkan-direct.fail", root) < (int)sizeof fail);
    assert(snprintf(attempt, sizeof attempt, "%s/vulkan-direct.attempt", root) < (int)sizeof attempt);
    assert(snprintf(log, sizeof log, "%s/prepare.log", root) < (int)sizeof log);
    unlink(file); unlink(fail); unlink(attempt);   // 上一轮留下的不算
    if (!strcmp(mode, "malformed") || !strcmp(mode, "auto-malformed")) write_text(file, "S2ARM_VULKAN_DIRECT_V1\nmain\n");
    else if (!strcmp(mode, "duplicate")) write_text(file, "S2ARM_VULKAN_DIRECT_V1\nsubsdk0\nsubsdk0\n");
    else if (strcmp(mode, "missing") && strcmp(mode, "auto-missing")) write_text(file, "S2ARM_VULKAN_DIRECT_V1\nsubsdk0\nsubsdk1\n");
    if (!strcmp(mode, "auto-fail") || !strcmp(mode, "direct-clears-fail")) write_text(fail, "device lost\n");
    if (!strcmp(mode, "auto-attempt")) write_text(attempt, "vulkan-direct attempt\n");
    // A real WSI table is only needed when a surface is created; prepare validates
    // the exact ABI prefix. This test never creates/takes a native window.
    struct s2a_wsi_window_ops ops = {never_window, never_window};
    s2a_wsi_lease *lease = s2a_wsi_create(1, &ops); assert(lease);
    struct s2a_wsi_api api; s2a_wsi_api_fill(lease, &api);
    if (automatic && strcmp(mode, "auto")) {
        const char *expect = !strcmp(mode, "auto-fail") ? fail : !strcmp(mode, "auto-attempt") ? attempt : file;
        assert(prepare_logged(&api, root, log, expect) == 0 && s2a_gfx_mode() == 0);
        assert(!s2a_android_vk_skip_module("subsdk0") && !s2a_direct_lookup("vkCreateInstance"));
        assert(s2a_android_vk_select(1) == EBUSY && s2a_android_vk_select(2) == 0);   // 冻结的是 AUTO 这个选择
        // 回通用不新写 attempt，也不清上局留下的标记；停止也不碰它们
        assert(exists(attempt) == !strcmp(mode, "auto-attempt") && exists(fail) == !strcmp(mode, "auto-fail"));
        assert(s2a_android_vk_session_stop() == 0);
        assert(exists(attempt) == !strcmp(mode, "auto-attempt") && exists(fail) == !strcmp(mode, "auto-fail"));
        s2a_wsi_destroy(lease);
        puts("PASS AUTO falls back to generic with one line naming the file"); return 0;
    }
    int result = s2a_android_vk_session_prepare(&api, root, root);
    if (!manual_direct && strcmp(mode, "auto")) {
        // 手动直连：描述没有 / 不对 → 返回错误，runtime 据此报红停在报红页，不悄悄改通用；没留 attempt
        assert(result == (!strcmp(mode, "missing") ? ENOENT : EINVAL) && s2a_gfx_mode() == 0 && !exists(attempt));
        s2a_wsi_destroy(lease);
        puts("PASS malformed descriptor never publishes direct mode"); return 0;
    }
    assert(result == 0 && s2a_gfx_mode() == 1);
    assert(exists(attempt));   // 直连期间留着 attempt：被杀则下次 AUTO 回通用
    assert(s2a_android_vk_select(0) == EBUSY);
    assert(s2a_android_vk_select(automatic ? 2 : 1) == 0);
    assert(s2a_android_vk_session_prepare(&api, root, root) == EALREADY);
    assert(s2a_android_vk_skip_module("subsdk0") && s2a_android_vk_skip_module("subsdk1"));
    assert(!s2a_android_vk_skip_module("sdk") && !s2a_android_vk_skip_module("main") && !s2a_android_vk_skip_module("subsdk10"));
    assert(s2a_direct_lookup("vkCreateInstance") && !s2a_direct_lookup("nvnBootstrapLoader"));
    // 客体问过 NVN 入口 → 客体事实置位；runtime 用它与 vk-direct 实验开关对账（这个夹具里
    // 选择器没有提交 NVN 直连表，所以正是必须报红的那个组合）。
    assert(s2a_android_vk_nvn_guest() == 1);
    assert(s2a_android_vk_set_layer_query(query) == 0);
    assert(s2a_android_vk_set_layer_query(query) == EALREADY);
    assert(s2a_android_vk_present_count() == 0 && s2a_android_vk_session_stop() == 0);
    assert(!exists(attempt));   // 正常停止清掉 attempt
    // direct-clears-fail：上局留下的 fail 在手动直连正常结束后清掉，AUTO 恢复走直连（维护方定，同 NVN 直连）
    if (!strcmp(mode, "direct-clears-fail")) {
        char why[512];
        assert(!exists(fail) && s2a_vk_auto_resolve(root, root, why, sizeof why) == 1);
    }
    s2a_wsi_destroy(lease);
    puts("PASS direct choice/module closure frozen before loader; layer callback single owner");
    return 0;
}

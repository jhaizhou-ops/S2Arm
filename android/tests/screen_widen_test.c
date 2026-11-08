// Host fixture: the production Android widen provider reads the real HostApi
// display contract; a fake display supplies controlled surface revisions.
// F1 #1574：安卓走与苹果同一份名单门——设置缺省开（撤 opt-in）、真屏宽过 widen_gate，
//   名单外一律 16:9；宽屏点表经 bridge/GameSession 收进包（本夹具不覆盖打包侧）。
#include "s2a_native.h"
#include "s2a_hostapi.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned width, height;
static char module_dir[] = "/tmp/s2a-widen-screen-XXXXXX";
static int display_info(void *host, s2a_host_display_info *out) {
    (void)host;
    *out = (s2a_host_display_info){.size = sizeof *out, .abi_version = S2A_HOST_API_ABI_VERSION,
                                  .width = width, .height = height};
    return S2A_HOST_E_OK;
}
static const s2a_host_display_v1 display = {.info = display_info};
static const s2a_host_api_v1 api = {.capabilities = S2A_HOST_CAP_DISPLAY, .display = &display};
const s2a_host_api_v1 *s2a_host_get(void) { return &api; }
const char *s2a_module_dir(void) { return module_dir; }
const char *s2a_main_build_id(void) { return ""; }   // loader.c 的桩：补丁按构建号对号（patch.c / widen.c patch_enable）

static int run_case(int which) {
    unsetenv("S2A_SCREEN_W"); unsetenv("S2A_SCREEN_H"); unsetenv("S2A_WIDESCREEN"); unsetenv("S2A_WIDEN_CAPS");
    if (which < 5) setenv("S2A_WIDEN_VERIFIED", "1", 1);
    else {
        unsetenv("S2A_WIDEN_VERIFIED");
        if (which != 7 && which != 10) {   // 7 名单外 / 10 清单开：都不给标记文件
            if (!mkdtemp(module_dir)) return 2;
            char path[128]; snprintf(path, sizeof path, "%s/widen_verified.tsv", module_dir);
            FILE *f = fopen(path, "w"); if (!f) return 2; fclose(f);
        }
        if (which == 6 || which == 8) setenv("S2A_WIDESCREEN", "1", 1);   // 显式开（F1 后与缺省同义）
        if (which == 9) setenv("S2A_WIDESCREEN", "0", 1);                 // 名单内但玩家设置关 → 名单开不了
        if (which == 10) setenv("S2A_WIDEN_CAPS", "1", 1);                // 包内能力清单开（安卓行 → widen 1；F7 发布缺省关在名单内也开）
    }
    if (which == 0) {
        if (s2a_screen_w() != 0 || s2a_screen_h() != 0) return 1;
        width = 1200; height = 900;
        return s2a_screen_w() != 1920 || s2a_screen_h() != 1440;
    }
    if (which == 1) { width = 1200; height = 900; }
    if (which == 2) { width = 2400; height = 1080; }
    if (which == 3) { width = 1920; height = 1080; }
    if (which == 4) { width = 2034; height = 1398; }
    if (which == 5 || which == 6) { width = 1200; height = 900; }
    if (which >= 7) { width = 2400; height = 1080; }   // 宽屏表面：名单门决定 2400 还是压回 1920
    int w = s2a_screen_w();
    width = 1200; height = 900; // surface changes between the two consumer calls
    int h = s2a_screen_h();
    const int wanted_w[] = {0, 1920, 2400, 1920, 1920, 1920, 1920, 1920, 2400, 1920, 2400};
    const int wanted_h[] = {0, 1440, 1080, 1080, 1318, 1440, 1440, 1080, 1080, 1080, 1080};
    const int wanted_full[] = {-1, -1, -1, -1, -1, 1, 1, 0, 1, 0, 1};
    if (which >= 5) {
        int full = s2a_widen_full();
        if (full != wanted_full[which]) { fprintf(stderr, "case %d: widen full=%d\n", which, full); return 1; }
    }
    if (w != wanted_w[which] || h != wanted_h[which]) {
        fprintf(stderr, "case %d: actual %d x %d, expected %d x %d\n", which, w, h, wanted_w[which], wanted_h[which]);
        return 1;
    }
    width = 1200; height = 900; // startup snapshot stays coherent for this game
    int coherent = s2a_screen_w() == w && s2a_screen_h() == h;
    if (which >= 5 && which != 7 && which != 10) {   // 宽屏例的重读要走名单门：清标记挪到全部读数之后
        char path[128]; snprintf(path, sizeof path, "%s/widen_verified.tsv", module_dir); unlink(path); rmdir(module_dir);
    }
    return !coherent;
}
int main(void) {
    int bad = 0;
    for (int i = 0; i < 11; ++i) {
        pid_t p = fork(); if (p == 0) _exit(run_case(i));
        int st = 0;
        if (p < 0 || waitpid(p, &st, 0) != p || !WIFEXITED(st) || WEXITSTATUS(st)) {
            fprintf(stderr, "screen widen fixture case %d failed (status %d)\n", i, st); ++bad;
        }
    }
    if (bad) return 1;
    puts("Android HostApi surface metrics: absent, 4:3, wide, 16:9, Duo, verified default-on/explicit, "
         "unlisted 16:9, listed wide, setting-off, caps-on PASS");
    return 0;
}

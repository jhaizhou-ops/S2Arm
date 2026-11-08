// t_widen_ios_screen：屏幕宽在「窗口场景还没连上」时只读、不缓存，与屏幕高同一做法。
//   ios/app.m 的 s2a_ios_screen_known() 为 0 = 窗口场景没连上（装载期、主线程），这时只能拿主屏原生尺寸：Duo 上一直是外屏。
//   所以这次读数只用于本次返回，不进 g_sw / g_sh：场景连上后按实际所在的屏重新定。
//   屏幕高 s2a_screen_h 有这道 known 保护，屏幕宽 s2a_screen_w 漏了：首次读到的 2340（Duo 外屏 2340 × 1080，比例 2.1667）被缓存 → widen_gate 判成要放宽 → 整局拉伸。
// 期望（不跑被测实现手算）：unknown 时读 2340 → 返回 2340 但不缓存；窗口连上后读 1920 → 返回 1920。修前第二次仍是缓存里的 2340。
//   本单测用假 TargetConditionals.h（runtime/tests/support/ios_prewarm）在 Mac 上执行真实 iOS 分支，s2a_ios_screen_* 由本文件给桩。
//   屏幕宽 / 高的定值是进程级缓存（g_sw / g_sh），各场景一律在子进程里判，互不串。
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include "../src/native.h"
S2A_TEST_MOD_TABLE(64); int g_nmod;
static char g_tmd[600];   // 模块目录（loader.c s2a_module_dir 的桩）：宽屏已验证名单的标记 widen_verified.tsv 在这里找
const char *s2a_module_dir(void) { return g_tmd; }
const char *s2a_main_build_id(void) { return ""; }   // loader.c 的桩：补丁按构建号对号（patch.c / widen.c patch_enable）
module_t *module_of(const void *p) { (void)p; return &g_mod[0]; }
void s2a_host_write_hook(uint64_t a, uint64_t n) { (void)a; (void)n; }
static int g_known, g_ios_w = 1920, g_ios_h = 1080;   // s2a_ios_screen_*（ios/app.m）的桩
int s2a_ios_screen_known(void) { return g_known; }
int s2a_ios_screen_w(void) { return g_ios_w; }
int s2a_ios_screen_h(void) { return g_ios_h; }
int s2a_screen_w(void);
int s2a_screen_h(void);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } } while (0)
static int run_child(void (*fn)(void)) { pid_t c = fork(); if (c == 0) { fn(); _exit(0); } int st = 0; waitpid(c, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : -1; }
// ① 首次（窗口没连上）读 2340 → 只返回、不缓存；连上后读 1920 → 1920。修前第二次得缓存里的 2340
static void c1(void) { g_known = 0; g_ios_w = 2340; int a = s2a_screen_w(); g_known = 1; g_ios_w = 1920; int b = s2a_screen_w(); _exit((a == 2340 ? 0 : 1) | (b == 1920 ? 0 : 2)); }
// ② 已知时缓存照旧生效：先 2340 再 1920，期望仍是 2340（修复不许把缓存整个关掉）
static void c2(void) { g_known = 1; g_ios_w = 2340; int a = s2a_screen_w(); g_ios_w = 1920; int b = s2a_screen_w(); _exit(a == 2340 && b == 2340 ? 0 : 1); }
// ③ 对称性：unknown 时连不超 1920 的值也不缓存（屏幕高对 known == 0 一律不缓存，与本次读数是否超标无关）
static void c3(void) { g_known = 0; g_ios_w = 1920; int a = s2a_screen_w(); g_known = 1; g_ios_w = 2340; int b = s2a_screen_w(); _exit((a == 1920 ? 0 : 1) | (b == 2340 ? 0 : 2)); }
// ④ 屏幕高：比 16:9 窄的真屏（Duo 1350）照真屏加高，unknown 时只返回不缓存、连上后 1350（11-02 撤压回 1080 的上限：竖向一族修完、Duo 外屏验收过）；
//    S2A_SCREEN_H 给定（Mac 模拟窄屏）照旧按给定值（⑤）
static void c4(void) { g_known = 0; g_ios_w = 1920; g_ios_h = 1350; int a = s2a_screen_h(); g_known = 1; int b = s2a_screen_h(); _exit((a == 1350 ? 0 : 1) | (b == 1350 ? 0 : 2)); }
static void c5(void) { setenv("S2A_SCREEN_H", "1318", 1); g_known = 1; g_ios_h = 1350; int a = s2a_screen_h(); _exit(a == 1318 ? 0 : 1); }
// ⑥⑦ 运行中退回原生 16:9（11-02 体验线「满屏异常问玩家是否退回」）：真屏 2346×1080（iPhone 宽屏）已定 → 钉 16:9 返回 1、屏宽 1920、换屏代数加一；
//   之后 App 壳布局回调（s2a_screen_reaspect）按真屏重算不许改回（返回 0、仍 1920）；再钉一次没变化（0）。撤钉 → 按真屏换回 2346（1）
int s2a_widen_force_native(int on); int s2a_screen_reaspect(void); unsigned s2a_screen_gen(void);
static void c6(void) { g_known = 1; g_ios_w = 2346; g_ios_h = 1080; int w0 = s2a_screen_w(); (void)s2a_screen_h(); unsigned g0 = s2a_screen_gen();
    int r = s2a_widen_force_native(1), w1 = s2a_screen_w(); unsigned g1 = s2a_screen_gen(); int re = s2a_screen_reaspect(), w2 = s2a_screen_w(), again = s2a_widen_force_native(1);
    _exit((w0 == 2346 ? 0 : 1) | (r == 1 && w1 == 1920 && g1 == g0 + 1 ? 0 : 2) | (re == 0 && w2 == 1920 ? 0 : 4) | (again == 0 ? 0 : 8)); }
static void c7(void) { g_known = 1; g_ios_w = 2346; g_ios_h = 1080; (void)s2a_screen_w(); (void)s2a_screen_h(); s2a_widen_force_native(1);
    int r = s2a_widen_force_native(0), w = s2a_screen_w(), r2 = s2a_widen_force_native(0); _exit((r == 1 && w == 2346 ? 0 : 1) | (r2 == 0 ? 0 : 2)); }
// ⑧ 预热期（模块目录还空）先读屏幕宽 → 名单门不知道、按 1920 不缓存；随后 App 设置转成 S2A_WIDESCREEN=0、模块装载 → 期望 1920（设置关生效）。
//   11-02 jhz 饥荒「切原比例后歪」：修前预热那次把「设置开」缓存住，装载后有名单标记就放开成 2346
static void c8(void) { char d[600]; snprintf(d, sizeof d, "%s", g_tmd); g_tmd[0] = 0; g_known = 1; g_ios_w = 2346; g_ios_h = 1080;
    int a = s2a_screen_w(); setenv("S2A_WIDESCREEN", "0", 1); snprintf(g_tmd, sizeof g_tmd, "%s", d); int b = s2a_screen_w(); _exit((a == 1920 ? 0 : 1) | (b == 1920 ? 0 : 2)); }
// ⑨⑩ 按窗口像素跟屏（审计 P1-83，Mac 壳窗口拉宽 / 全屏）：已定 1920×1080 后，3200×1080 像素窗口 → 宽 1080 × 3200 / 1080 = 3200、高 1080，返回 1；
//   2880×1800（16:10，比 16:9 窄）→ 宽 1920、高 1920 ÷ 1.6 = 1200；同尺寸再来无变化（0）。⑩ 钉了原生 16:9 后跟屏不动（0、仍 1920）；S2A_SCREEN_W 给定时不跟（0）
int s2a_screen_fit(int pw, int ph);
static void c9(void) { g_known = 1; g_ios_w = 1920; g_ios_h = 1080; (void)s2a_screen_w(); (void)s2a_screen_h();
    int a = s2a_screen_fit(3200, 1080), wa = s2a_screen_w(), ha = s2a_screen_h(), b = s2a_screen_fit(2880, 1800), wb = s2a_screen_w(), hb = s2a_screen_h(), c = s2a_screen_fit(2880, 1800);
    _exit((a == 1 && wa == 3200 && ha == 1080 ? 0 : 1) | (b == 1 && wb == 1920 && hb == 1200 ? 0 : 2) | (c == 0 ? 0 : 4)); }
static void c10(void) { g_known = 1; g_ios_w = 2346; g_ios_h = 1080; (void)s2a_screen_w(); (void)s2a_screen_h(); s2a_widen_force_native(1);
    int a = s2a_screen_fit(3200, 1080), wa = s2a_screen_w(); s2a_widen_force_native(0); setenv("S2A_SCREEN_W", "2346", 1); int b = s2a_screen_fit(3200, 1080);
    _exit((a == 0 && wa == 1920 ? 0 : 1) | (b == 0 ? 0 : 2)); }
// ⑪ 装载后的屏幕宽（11-07 多款容器：游戏库停留期 / 单款加载页期触屏手柄就算画面矩形）：模块目录空 → s2a_screen_w_after_load 回 0 且不过名单门
//   （不打「装载前就读了屏幕宽」红行、不设窄屏标记 S2A_WIDEN_NARROW）；装载后（模块目录有名单标记）→ 2346，同 s2a_screen_w
int s2a_screen_w_after_load(void);
// ⑫ 装载前问游戏画布 / 出不出宽图（触屏手柄挂上时就问，ios/vpad.m）：期望 1280×720、不出宽图，且日志里没有「装载前就读了」红行、不设窄屏标记。
//   装载后的真值不变由 t_widen 各项覆盖（只调换了求值顺序）
void s2a_game_canvas(int *w, int *h); int s2a_widen_game(void);
static void c12(void) { char path[] = "/tmp/s2a_t_wis_log_XXXXXX"; int fd = mkstemp(path); if (fd < 0) _exit(8); g_s2a_logfd = fd;
    g_tmd[0] = 0; g_known = 1; g_ios_w = 2346; g_ios_h = 1080; unsetenv("S2A_WIDEN_NARROW");
    int w = 0, h = 0; s2a_game_canvas(&w, &h); int game = s2a_widen_game(); int narrow = getenv("S2A_WIDEN_NARROW") != NULL;
    char buf[4096] = {0}; lseek(fd, 0, SEEK_SET); ssize_t n = read(fd, buf, sizeof buf - 1); (void)n; close(fd); unlink(path);
    _exit((w == 1280 && h == 720 && !game ? 0 : 1) | (!strstr(buf, "装载前就读了") && !narrow ? 0 : 2)); }
static void c11(void) { char d[600]; snprintf(d, sizeof d, "%s", g_tmd); g_tmd[0] = 0; g_known = 1; g_ios_w = 2346; g_ios_h = 1080; unsetenv("S2A_WIDEN_NARROW");
    int a = s2a_screen_w_after_load(); int narrow = getenv("S2A_WIDEN_NARROW") != NULL; snprintf(g_tmd, sizeof g_tmd, "%s", d); int b = s2a_screen_w_after_load(), c = s2a_screen_w();
    _exit((a == 0 && !narrow ? 0 : 1) | (b == 2346 && c == 2346 ? 0 : 2)); }
int main(void) {
    char T[] = "/tmp/s2a_t_widen_ios_screen_XXXXXX"; if (!mkdtemp(T)) return 1;
    snprintf(g_tmd, sizeof g_tmd, "%s", T);
    { char p[620]; snprintf(p, sizeof p, "%s/widen_verified.tsv", T); FILE *f = fopen(p, "w"); if (!f) return 1;   // 名单门放行（widen_verified 只看文件在不在）
      fprintf(f, "0100000000000000\tabc\n"); fclose(f); }
    unsetenv("S2A_SCREEN_W"); unsetenv("S2A_SCREEN_H"); unsetenv("S2A_WIDEN_CAPS"); unsetenv("S2A_WIDESCREEN");
    unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
    int e = run_child(c1);
    CHECK(!(e & 1), "① 窗口没连上时读 2340：期望返回这次读数 2340（退出 %d）", e);
    CHECK(!(e & 2), "① 窗口连上后读 1920：期望 1920（修前缓存了 2340，退出 %d）", e);
    e = run_child(c2); CHECK(e == 0, "② 已知时照旧缓存：先 2340 再 1920，期望仍是 2340（退出 %d）", e);
    e = run_child(c3);
    CHECK(!(e & 1), "③ unknown 时读 1920：期望返回这次读数 1920（退出 %d）", e);
    CHECK(!(e & 2), "③ 随后读 2340：期望 2340（修前缓存了 1920，退出 %d）", e);
    e = run_child(c4);
    CHECK(!(e & 1), "④ 窄屏 unknown 时读 1350：期望照真屏 1350（退出 %d）", e);
    CHECK(!(e & 2), "④ 窄屏连上后读 1350：期望 1350（退出 %d）", e);
    e = run_child(c5); CHECK(e == 0, "⑤ S2A_SCREEN_H=1318 给定（Mac 模拟窄屏）：期望照旧 1318（退出 %d）", e);
    e = run_child(c6); CHECK(e == 0, "⑥ 钉原生 16:9：期望钉前 2346、钉后 1920 且代数加一、布局回调改不回、再钉无变化（退出位 %d：1 钉前 / 2 钉 / 4 回调改回 / 8 再钉）", e);
    e = run_child(c7); CHECK(e == 0, "⑦ 撤钉：期望按真屏换回 2346、再撤无变化（退出位 %d）", e);
    e = run_child(c9); CHECK(e == 0, "⑨ 按窗口像素跟屏：期望 3200×1080 窗口 → 3200×1080、2880×1800 → 1920×1200、同尺寸再来无变化（退出位 %d：1 宽窗 / 2 窄窗 / 4 再来）", e);
    e = run_child(c10); CHECK(e == 0, "⑩ 钉了原生 16:9 / S2A_SCREEN_W 给定时不跟窗口（退出位 %d：1 钉住 / 2 环境变量）", e);
    e = run_child(c8); CHECK(e == 0, "⑧ 预热期先读屏幕宽、之后设置关才进环境：期望预热 1920、装载后仍 1920（修前 2346；退出位 %d：1 预热 / 2 装载后）", e);
    e = run_child(c12); CHECK(e == 0, "⑫ 装载前问游戏画布：期望 1280×720、不出宽图、不打装载前红行（退出位 %d：1 取值 / 2 读了屏幕）", e);
    e = run_child(c11); CHECK(e == 0, "⑪ 装载后的屏幕宽：期望装载前 0 且不过名单门、装载后 2346（退出位 %d：1 装载前 / 2 装载后）", e);
    char c[700]; snprintf(c, sizeof c, "rm -rf %s", T); (void)!system(c);
    if (bad) { printf("✗ t_widen_ios_screen：%d 项红\n", bad); return 1; }
    printf("✓ t_widen_ios_screen：15 条断言全过——装载前问画布不读屏幕 1 条（⑫）+ 装载后的屏幕宽装载前不读 1 条（⑪）+ 按窗口像素跟屏 2 条（⑨⑩）+ 预热期读屏幕宽不吞设置关 1 条（⑧）+ 运行中退回原生 16:9 钉住与撤钉 2 条（⑥⑦）+ 屏幕宽 unknown 时只读不缓存 3 条（首次 2340 照常返回、连上后 1920、unknown 时读 1920 随后仍得 2340）+ 已知时照旧缓存 1 条 + 窄屏暂不加高 2 条 + 模拟窄屏照旧加高 1 条\n");
    return 0;
}

// 宽屏启用表按档位单测（10-21）：装载器只读当前档位（S2A_DOCKED）的 widen_enable.<档位>.tsv，不读别的档位、也不读旧合并表 widen_enable.tsv。
// 造一个只有一个 movz 点（movz w0, #1280，掌机档宽）的模块：掌机表启用、主机表不启用、旧合并表启用。
// 期望（不跑被测实现手算）：屏幕宽 2346 时启用 = 1280 × 2346 ÷ 1920 = 1564；不启用 = 原立即数 1280。
//   ① 缺省（掌机）→ 1564；② S2A_DOCKED=1 → 1280；③ 只剩旧合并表 widen_enable.tsv（启用）→ 1280（没有这一档位的表 = 不加宽）；
//   ④ S2A_WIDEN_SITES 整表覆盖照旧优先。旧代码只读合并表 widen_enable.tsv：② ③ 都得 1564，两项红（实测）。
// 值槽（10-21 mh2）：跳板用 LDR Wd 读值槽低 32 位、写 Wd 清 Xd 高 32 位，所以「未启用 = 原指令结果」就是值槽 = 原指令写进寄存器的值。
//   ⑤ asp MOVZ w8,#0x8e3b + MOVK #0x3fe3 未启用 → 0x3fe38e3b（旧代码写死 0x3fe38e39，红）；⑥ asp #0x8e39 未启用 → 0x3fe38e39；
//   ⑦ f2w MOVZ x8,#0x44a0,LSL#16（1280.0f）未启用 → 0x44a00000（原值）；⑧ 同一条启用、屏宽 2346 → 1564.0f 的位 0x44c38000（低 16 位 0x8000，
//   一条 MOVZ 写不出，故读整槽）；⑨ f2w 1920.0f 启用 → 2346.0f = 0x4512a000。旧代码不认 f2w 种类、装载时 die（红）。
// 宿主门 lytsz / capsz（10-21）：LDP Sa,Sb,[Xn,#imm] 照读两个浮点，启用且是 16:9 档宽高对 → 宽 = 档宽 × 屏宽 ÷ 1920，高不动；结果进 qa / qb（高位清零）。
//   ⑩ lytsz ldp s2,s4,[x9,#0x28]（0x2d451122）启用、[x9+0x28] = (1280, 720) → q2 = 1564.0、q4 = 720.0、两寄存器其余位 0；
//   ⑪ capsz ldp s8,s9,[x0,#0x50]（0x2d4a2408）未启用、(1280, 720) → q8 = 1280.0、q9 = 720.0；⑫ lytsz 启用但 (1000, 720) 不是 16:9 档 → 原样 1000.0；
//   ⑬ 负偏移 ldp s0,s1,[x3,#-8]（0x2d7f0460）启用、[x3−8] = (1920, 1080) → q0 = 2346.0。旧代码门里不认种类 7 / 8：装载即 die（红）。
#include <sys/wait.h>
#include <unistd.h>
#include "../src/native.h"
#include "../include/patch.h"
#include <sys/mman.h>
#if defined(__ANDROID__)
#include "s2a_hostapi.h"
const s2a_host_api_v1 *s2a_host_get(void) { return NULL; }
#endif
S2A_TEST_MOD_TABLE(64); int g_nmod;
static char g_tmd[600];   // 模块目录（loader.c s2a_module_dir 的桩）：宽屏已验证名单的标记 widen_verified.tsv 在这里找
const char *s2a_module_dir(void) { return g_tmd; }
static char g_bid[40];   // 本包主程序构建号（loader.c s2a_main_build_id 的桩）：补丁按构建号走快路径 / 特征定位
const char *s2a_main_build_id(void) { return g_bid; }
static module_t *g_cur;   // 门测试：门按返回地址找模块，这里直接给当前测试模块
module_t *module_of(const void *p) { (void)p; return g_cur; }
void s2a_widen_gate(int idx, uint64_t *regs, uint64_t orig);
void s2a_host_write_hook(uint64_t a, uint64_t n) { (void)a; (void)n; }
void s2a_widen_load(module_t *m, const char *dir);
int s2a_widen_game(void);
void s2a_game_canvas(int *w, int *h);
int s2a_widen_layout(void);
int s2a_widen_full(void);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } } while (0)
#define WSLOT 16
#define W_ASP_B 0x5291c768u
#define W_ASP_9 0x5291c728u
#define W_F2W_1280 0xd2a89408u
#define W_F2W_1920 0xd2a89e08u
static void put(const char *dir, const char *name, int on) {
    char p[600]; snprintf(p, sizeof p, "%s/%s", dir, name); FILE *f = fopen(p, "w");
    fprintf(f, "模块\t偏移\t种类\t启用\nmain\t0x10\tmovz\t%d\n", on); fclose(f);
}
// 装第 i 个模块（各用一张独立键页），返回 movz 值槽
static uint64_t load(int i, const char *dir) {
    module_t *m = &g_mod[i]; snprintf(m->name, sizeof m->name, "main");
    m->key_page_size = 16384; m->key_page_off = 0;
    m->base = (uint8_t *)mmap(NULL, 16384, PROT_READ, MAP_ANON | MAP_PRIVATE, -1, 0);
    s2a_widen_load(m, dir);
    return ((uint64_t *)m->base)[WSLOT];
}
int main(void) {
    char T[] = "/tmp/s2a_t_widen_XXXXXX"; if (!mkdtemp(T)) return 1;
    snprintf(g_tmd, sizeof g_tmd, "%s", T);
#if defined(__ANDROID__)
    // Real Android loader path（F1 #1574：安卓撤 opt-in 缺省关、走苹果同一份名单门）：
    // 有 widen_verified.tsv 标记 → 缺省开与显式开等价，2400 屏 1280 × 2400 ÷ 1920 = 1600。
    { char p[600]; snprintf(p, sizeof p, "%s/widen_verified.tsv", T); FILE *f = fopen(p, "w"); if (!f) return 1; fclose(f);
      snprintf(p, sizeof p, "%s/main.widen.tsv", T); f = fopen(p, "w"); if (!f) return 1;
      fprintf(f, "0\t0x10\tmovz\t%x\n", 0x52800000u | (1280u << 5)); fclose(f);
      put(T, "widen_enable.handheld.tsv", 1);
      for (int on = 0; on < 2; ++on) { pid_t c = fork();
        if (c == 0) { setenv("S2A_SCREEN_W", "2400", 1); unsetenv("S2A_WIDEN_VERIFIED");
          if (on) setenv("S2A_WIDESCREEN", "1", 1); else unsetenv("S2A_WIDESCREEN");
          uint64_t v = load(0, T); _exit(v == 1600u ? 0 : 1); }
        int st = 0; waitpid(c, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "Android widen %s must initialize the correct key slot", on ? "explicit on" : "default on"); }
      snprintf(p, sizeof p, "%s/widen_verified.tsv", T); unlink(p); }
#endif
    setenv("S2A_WIDEN_VERIFIED", "1", 1);   // 以下各项按「已验证」跑；名单门本身在 ⓥ 里判
    // ⓪（10-26）只启用改宽高比的点（aspdiv：马车8 main 0x3cd314 那种）不算「游戏自己出宽图」：s2a_widen_game 期望 0（游戏照旧按 16:9 尺寸建目标，靠第三层放宽存储）；
    //   改前按「启用了任何点」判，得 1（核心进只管界面层、不放宽存储，画面被压窄）。计数是进程级的，在子进程里判、不碰后面各项
    { pid_t c = fork();
      if (c == 0) {
          char q[600]; setenv("S2A_SCREEN_W", "2346", 1); unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
          snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "0\t0x10\taspdiv\t%x\n", 0x1e201820u); fclose(g);
          snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w"); fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x10\taspdiv\t1\n"); fclose(g);
          load(0, T); _exit(s2a_widen_game() == 0 ? 0 : 1); }
      int st = 0; waitpid(c, &st, 0); CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⓪ 只启用 aspdiv（改宽高比、不改渲染尺寸）：s2a_widen_game 期望 0");
      // ⓪b 同上、但这一档第三层表写了「0」（S2A_WIDEN_FULL=0 同效）：不能落到 16:9 原比例居中（投影已是屏幕比，画面会横向压扁）→ 仍算出宽图，s2a_widen_game 期望 1
      c = fork();
      if (c == 0) { setenv("S2A_SCREEN_W", "2346", 1); setenv("S2A_WIDEN_FULL", "0", 1); unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED"); load(0, T); _exit(s2a_widen_game() == 1 ? 0 : 1); }
      waitpid(c, &st, 0); CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⓪b 只启用 aspdiv 且第三层表为 0：s2a_widen_game 期望 1（不落原比例居中压扁）");
      char q[600]; snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); unlink(q); }
    char p[600]; snprintf(p, sizeof p, "%s/main.widen.tsv", T); FILE *f = fopen(p, "w");
    fprintf(f, "0\t0x10\tmovz\t%x\n", 0x52800000u | (1280u << 5)); fclose(f);
    setenv("S2A_SCREEN_W", "2346", 1); unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
    put(T, "widen_enable.handheld.tsv", 1); put(T, "widen_enable.docked.tsv", 0); put(T, "widen_enable.tsv", 1);
    { char q[600]; snprintf(q, sizeof q, "%s/widen_full.handheld.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "整套放宽\n1\n"); fclose(g); }
    // ⓥ（10-26 jhz：没验证过宽屏的游戏一律 16:9）宽屏已验证名单门：屏幕宽 2346、movz 1280 点掌机档启用。期望（手算）：
    //   ⓥ1 没有标记 widen_verified.tsv、没给 S2A_WIDEN_VERIFIED → 屏幕宽按 1920、点值 1280 × 1920 ÷ 1920 = 1280；
    //   ⓥ2 有标记 → 2346、1564；ⓥ3 有标记但 S2A_WIDEN_VERIFIED=0 → 1920、1280。屏幕宽按进程缓存，各在子进程里判。旧代码没有门：ⓥ1 ⓥ3 得 2346 / 1564（红）
    //   ⓥ4（10-27 宽屏设置开关）有标记、不给 S2A_WIDEN_VERIFIED、S2A_WIDESCREEN=0 → 1920、1280；ⓥ5 同上但 S2A_WIDESCREEN=1 → 2346、1564。旧代码不认这个变量：ⓥ4 得 2346 / 1564（红）
    //   包内能力清单 S2A_WIDEN_CAPS（审计 #854 F-caps-beats-settings：排在用户设置之后、名单之前）：ⓥ6 无标记、清单 1 → 2346、1564；
    //   ⓥ7 无标记、清单 1、设置关（S2A_WIDESCREEN=0）→ 1920、1280（旧代码清单借 S2A_WIDEN_VERIFIED=1，压过设置得 2346）；ⓥ8 有标记、清单 0（发布包未验）→ 1920、1280
    { char mk[620]; snprintf(mk, sizeof mk, "%s/widen_verified.tsv", T);
      for (int k = 1; k <= 8; k++) {
          pid_t c = fork();
          if (c == 0) { unsetenv("S2A_WIDEN_CAPS"); unsetenv("S2A_WIDESCREEN");
                        if (k == 1 || k == 6 || k == 7) unsetenv("S2A_WIDEN_VERIFIED"); else { FILE *g = fopen(mk, "w"); fprintf(g, "0100000000000000\tabc\n"); fclose(g);
                            if (k == 3) setenv("S2A_WIDEN_VERIFIED", "0", 1); else unsetenv("S2A_WIDEN_VERIFIED");
                            if (k == 4 || k == 5) setenv("S2A_WIDESCREEN", k == 4 ? "0" : "1", 1); }
                        if (k >= 6) setenv("S2A_WIDEN_CAPS", k == 8 ? "0" : "1", 1);
                        if (k == 7) setenv("S2A_WIDESCREEN", "0", 1);
                        uint64_t x = load(0, T); int sw = s2a_screen_w(); unlink(mk);
                        // F1 #1574：安卓与苹果同一份名单门（撤 opt-in 缺省关、真屏宽与能力清单都过 widen_gate）——期望不再有平台分支
                        _exit(k == 2 || k == 5 || k == 6 ? !(sw == 2346 && x == 1564) : !(sw == 1920 && x == 1280));
          }
          int st = 0; waitpid(c, &st, 0);
          static const char *nm[] = {"", "不在名单", "在名单（有标记）", "有标记但 S2A_WIDEN_VERIFIED=0", "有标记、设置关（S2A_WIDESCREEN=0）", "有标记、设置开（S2A_WIDESCREEN=1）",
                                     "无标记、能力清单开", "无标记、能力清单开、设置关", "有标记、能力清单关（发布包未验）"};
          int on = k == 2 || k == 5 || k == 6;
          CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "ⓥ%d %s：期望屏幕宽 %d、点值 %d", k, nm[k], on ? 2346 : 1920, on ? 1564 : 1280);
      } }
    uint64_t v = load(0, T); CHECK(v == 1564, "① 掌机档（缺省）期望 1564 → %llu", (unsigned long long)v);
    CHECK(s2a_widen_game() == 1, "① 掌机档启用 1 点，s2a_widen_game 期望 1");
    CHECK(s2a_widen_layout() == 0, "① 启用的是 movz、没有界面布局尺寸点（lytsz）：s2a_widen_layout 期望 0");
    // ⑤a / ⑤b（10-26 A：没有表 = 放宽，一行 0 才关）：结果按进程缓存，各在子进程里判；模块目录已由上面 load 记下
    for (int k = 0; k < 2; k++) {
        char q[600]; snprintf(q, sizeof q, "%s/widen_full.handheld.tsv", T); pid_t c = fork();
        if (c == 0) { if (k == 0) { FILE *g = fopen(q, "w"); fprintf(g, "整套放宽\n0\n"); fclose(g); } else unlink(q); _exit(s2a_widen_full() == k ? 0 : 1); }
        int st = 0; waitpid(c, &st, 0); CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⑤%c %s：s2a_widen_full 期望 %d", k ? 'b' : 'a', k ? "掌机档没有 widen_full 表" : "widen_full.handheld.tsv 有一行 0", k);
        FILE *g = fopen(q, "w"); fprintf(g, "整套放宽\n1\n"); fclose(g);
    }
    CHECK(s2a_widen_full() == 1, "⑤ 掌机档 widen_full.handheld.tsv 有一行 1：s2a_widen_full 期望 1（模块目录在首个带候选表的模块装载时记下）");
    setenv("S2A_DOCKED", "1", 1);
    v = load(1, T); CHECK(v == 1280, "② 主机档（表里不启用）期望 1280 → %llu", (unsigned long long)v);
    unsetenv("S2A_DOCKED"); snprintf(p, sizeof p, "%s/widen_enable.handheld.tsv", T); unlink(p);
    v = load(2, T); CHECK(v == 1280, "③ 只剩旧合并表期望 1280（不加宽）→ %llu", (unsigned long long)v);
    setenv("S2A_WIDEN_SITES", "main:0x10", 1); setenv("S2A_DOCKED", "1", 1);
    v = load(3, T); CHECK(v == 1564, "④ S2A_WIDEN_SITES 覆盖期望 1564 → %llu", (unsigned long long)v);
    // ⑤–⑨：值槽 = 原指令结果 / 加宽值（掌机表启用 0x40 / 0x50）
    unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
    snprintf(p, sizeof p, "%s/main.widen.tsv", T); f = fopen(p, "w");
    fprintf(f, "0\t0x10\tasp\t%x\n1\t0x20\tasp\t%x\n2\t0x30\tf2w\t%x\n3\t0x40\tf2w\t%x\n4\t0x50\tf2w\t%x\n"
               "5\t0x58\taspcap\t52838e48\n6\t0x5c\taspcaps\t52838e49\n7\t0x60\taspcap\t528aaaaa\n",
            W_ASP_B, W_ASP_9, W_F2W_1280, W_F2W_1280, W_F2W_1920); fclose(f);
    snprintf(p, sizeof p, "%s/widen_enable.handheld.tsv", T); f = fopen(p, "w");
    fprintf(f, "模块\t偏移\t种类\t启用\nmain\t0x10\tasp\t0\nmain\t0x20\tasp\t0\nmain\t0x30\tf2w\t0\nmain\t0x40\tf2w\t1\nmain\t0x50\tf2w\t1\n"); fclose(f);
    load(4, T); uint64_t *sl = (uint64_t *)g_mod[4].base + WSLOT;
    CHECK(sl[0] == 0x3fe38e3bu, "⑤ asp #0x8e3b 未启用期望 0x3fe38e3b → %#llx", (unsigned long long)sl[0]);
    CHECK(sl[1] == 0x3fe38e39u, "⑥ asp #0x8e39 未启用期望 0x3fe38e39 → %#llx", (unsigned long long)sl[1]);
    CHECK(sl[2] == 0x44a00000u, "⑦ f2w 1280.0f 未启用期望 0x44a00000 → %#llx", (unsigned long long)sl[2]);
    CHECK(sl[3] == 0x44c38000u, "⑧ f2w 1280.0f 启用期望 1564.0f = 0x44c38000 → %#llx", (unsigned long long)sl[3]);
    CHECK(sl[4] == 0x4512a000u, "⑨ f2w 1920.0f 启用期望 2346.0f = 0x4512a000 → %#llx", (unsigned long long)sl[4]);
    // ⑨b–d 宽高比上限（10-26 暗黑2）：启用表里没有这三行也照开（自带守卫，名单门管开关）。屏宽 2346：屏幕比 2346 / 1080 = 2.172222 > 19:9 = 2.111111
    //   ⑨b aspcap 19:9 → 屏幕比；⑨c aspcaps 19:9 → 屏幕比 + 0.15 = 2.322222；⑨d aspcap 21:9（0x40155555 = 2.333333）比屏幕宽 → 原值不动。旧代码不认种类 aspcap，装载即 die（红）
    { float a = 2346.0f / 1080.0f, b = a + 0.15f; uint32_t ab, bb; memcpy(&ab, &a, 4); memcpy(&bb, &b, 4);
      CHECK(sl[5] == ab, "⑨b aspcap 19:9 期望屏幕比 %#x → %#llx", ab, (unsigned long long)sl[5]);
      CHECK(sl[6] == bb, "⑨c aspcaps 19:9 期望屏幕比 + 0.15 = %#x → %#llx", bb, (unsigned long long)sl[6]);
      CHECK(sl[7] == 0x40155555u, "⑨d aspcap 21:9 比屏幕宽期望原值 0x40155555 → %#llx", (unsigned long long)sl[7]); }
    // ⑨e / ⑨f 宽高比点启用的值 = 屏宽 ÷ 屏高（11-02 jhz Duo 手测：窄屏原先仍给 1.778、竖向没扩）。期望（手算）：⑨e 宽屏 2346 × 1080 → 2346 / 1080 = 2.172222；
    //   ⑨f 窄屏 1920 × 1350（Duo 内屏 1.42 的 Vert+ 高）→ 1920 / 1350 = 1.422222。旧代码 ÷ 1080：⑨f 得 1.777778（红）
#if !defined(__ANDROID__)   // 安卓屏幕宽高按安卓窗口尺寸取（screen_metrics），运行中换屏入口不走这条；安卓满屏另由 tests/android_screen_host_test.sh 覆盖
    for (int k = 0; k < 2; k++) {
        fflush(stdout); pid_t c = fork();
        if (c == 0) {
            char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "0\t0x10\tasp\t%x\n", W_ASP_9); fclose(g);
            snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w"); fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x10\tasp\t1\n"); fclose(g);
            unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED"); int s2a_screen_switch(int, int); s2a_screen_w(); s2a_screen_h(); s2a_screen_switch(k ? 1920 : 2346, k ? 1350 : 1080);   // 父进程已缓存屏幕宽高：按运行中换屏入口切到目标屏
            float want = k ? 1920.0f / 1350.0f : 2346.0f / 1080.0f; uint32_t wb; memcpy(&wb, &want, 4);
            uint64_t v = load(5, T); printf("⑨%c asp 启用（屏 %s）期望 %#x → 真结果 %#llx\n", k ? 'f' : 'e', k ? "1920×1350" : "2346×1080", wb, (unsigned long long)v); fflush(stdout);
            _exit(v == wb ? 0 : 1); }
        int st = 0; waitpid(c, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⑨%c asp 启用值 = 屏宽 ÷ 屏高", k ? 'f' : 'e');
    }
#endif
#if !defined(__ANDROID__)
    // ⑨g / ⑨h movzh 显示高度（11-02 窄屏加高）：MOVZ w8,#720（0x52805a08）。期望（手算）：窄屏 1920×1350 启用 → 720 × 1350 ÷ 1080 = 900，s2a_widen_game = 1（游戏自出图）；
    //   ⑨h 同屏不启用 → 原值 720、s2a_widen_game = 0。旧代码不认种类 movzh，装载即 die（红）
    for (int k = 0; k < 2; k++) {
        fflush(stdout); pid_t c = fork();
        if (c == 0) {
            char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "0\t0x10\tmovzh\t52805a08\n"); fclose(g);
            snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w"); fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x10\tmovzh\t%d\n", k ? 0 : 1); fclose(g);
            unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
            int s2a_screen_switch(int, int); s2a_screen_w(); s2a_screen_h(); s2a_screen_switch(1920, 1350);
            uint64_t v = load(6, T); int gw = s2a_widen_game(); int cw = 0, ch = 0; s2a_game_canvas(&cw, &ch);
            printf("⑨%c movzh %s（屏 1920×1350）期望 %u / 游戏出图 %d / 触点画布 %s → 真结果 %llu / %d / %dx%d\n", k ? 'h' : 'g', k ? "不启用" : "启用", k ? 720u : 900u, k ? 0 : 1,
                   k ? "1280x720" : "1280x900", (unsigned long long)v, gw, cw, ch); fflush(stdout);   // 触点画布（审计 P1-92）：启用 → 720 × 1350 ÷ 1080 = 900 高；不启用 → 1280×720
            _exit(v == (k ? 720u : 900u) && gw == (k ? 0 : 1) && cw == 1280 && ch == (k ? 720 : 900) ? 0 : 1); }
        int st = 0; waitpid(c, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⑨%c movzh 窄屏高度点", k ? 'h' : 'g');
    }
#endif
#if !defined(__ANDROID__)
    // ⑨i / ⑨j movz / movzh 浮点写法（11-03 Pokopia 主场景视口 = 缩放比 × 1920.0）：MOVZ w8,#0x44f0,LSL#16（1920.0f 的高 16 位，0x52a89e08）/
    //   MOVZ w10,#0x4487,LSL#16（1080.0f，0x52a890ea）。期望（手算）：⑨i 屏 2346×1080 启用 → 2346.0f = 0x4512a000；⑨j 屏 1920×1350 启用 → 1350.0f = 0x44a8c000。
    //   旧代码把 hw = 1 当「不是 16:9 档」按原值：⑨i 得 0x44f00000、⑨j 得 0x44870000（红）
    for (int k = 0; k < 2; k++) {
        fflush(stdout); pid_t c = fork();
        if (c == 0) {
            char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "0\t0x10\t%s\t%s\n", k ? "movzh" : "movz", k ? "52a890ea" : "52a89e08"); fclose(g);
            snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w"); fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x10\t%s\t1\n", k ? "movzh" : "movz"); fclose(g);
            unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
            int s2a_screen_switch(int, int); s2a_screen_w(); s2a_screen_h(); s2a_screen_switch(k ? 1920 : 2346, k ? 1350 : 1080);
            uint64_t v = load(10 + k, T), want = k ? 0x44a8c000u : 0x4512a000u;
            printf("⑨%c %s 浮点启用（屏 %s）期望 %#llx → 真结果 %#llx\n", k ? 'j' : 'i', k ? "movzh 1080.0f" : "movz 1920.0f", k ? "1920×1350" : "2346×1080", (unsigned long long)want, (unsigned long long)v); fflush(stdout);
            _exit(v == want ? 0 : 1); }
        int st = 0; waitpid(c, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⑨%c movz 装浮点按屏填浮点位", k ? 'j' : 'i');
    }
    // ⑨k / ⑨l restab 档位表（11-03 Pokopia main 0x2756530）：可写模块代码段末 0x4000，0x4010 起 4 档宽 960,1280,1600,1920 紧跟 4 档高 540,720,900,1080，启用。
    //   期望（手算，宽 x × W ÷ 1920、高 x × H ÷ 1080 四舍五入）：⑨k 屏 2346×1080 → 宽 1173,1564,1955,2346、高不变、s2a_widen_game = 1；
    //   ⑨l 屏 1920×1350 → 宽不变、高 675,900,1125,1350。旧代码不认种类 restab，装载即 die（红）
    for (int k = 0; k < 2; k++) {
        fflush(stdout); pid_t c = fork();
        if (c == 0) {
            module_t *m = &g_mod[12 + k]; snprintf(m->name, sizeof m->name, "main"); m->key_page_size = 16384; m->key_page_off = 0;
            m->base = (uint8_t *)mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            m->text_end = 0x4000; m->patch_off = -1; m->file_image_len = 0x8000;
            uint32_t t[8] = {960, 1280, 1600, 1920, 540, 720, 900, 1080}; memcpy(m->base + 0x4010, t, 32);
            char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "0\t0x4010\trestab\t3c0\n"); fclose(g);
            snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w"); fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x4010\trestab\t1\n"); fclose(g);
            unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
            int s2a_screen_switch(int, int); s2a_screen_w(); s2a_screen_h(); s2a_screen_switch(k ? 1920 : 2346, k ? 1350 : 1080);
            s2a_widen_load(m, T);
            uint32_t a[8], wk[8] = {1173, 1564, 1955, 2346, 540, 720, 900, 1080}, wl[8] = {960, 1280, 1600, 1920, 675, 900, 1125, 1350}; memcpy(a, m->base + 0x4010, 32);
            printf("⑨%c restab（屏 %s）真结果 %u,%u,%u,%u / %u,%u,%u,%u，游戏出图 %d\n", k ? 'l' : 'k', k ? "1920×1350" : "2346×1080", a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], s2a_widen_game()); fflush(stdout);
            _exit((memcmp(a, k ? wl : wk, 32) ? 1 : 0) | (s2a_widen_game() == 1 ? 0 : 2)); }
        int st = 0; waitpid(c, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⑨%c restab 档位表按屏幕改、游戏出图（退出 %d）", k ? 'l' : 'k', WIFEXITED(st) ? WEXITSTATUS(st) : -1);
    }
    // ⑨m / ⑨n f2h（11-04 满屏补丁线，智慧的再现高屏：场景视口 = MOVZ x8,#0x44a0,LSL#16 + MOVK x8,#0x4434,LSL#48 拼的 (1280.0, 720.0)，f2w 只换宽）：
    //   点 0：f2w 0x10（1280.0f，启用）；点 1：f2h 0x18（MOVK x8,#0x4434,LSL#48 = 0xf2e88688，启用，搭档 = 点 0）；
    //   点 2：f2h 0x28（无搭档行，模块代码 0x20 处放原样 MOVZ x8,#0x44f0,LSL#16 = 1920.0f；MOVK x8,#0x4487,LSL#48 = 0xf2e890e8 = 1080.0f，不启用）。
    //   期望（手算，值槽 = 低 32 位宽 | 高 32 位高）：⑨m 屏 1920×1350 → 点 1 = 900.0f(0x44610000) << 32 | 1280.0f(0x44a00000)；点 2 不启用 = 原两条指令拼出的
    //   0x4487000044f00000；s2a_widen_game = 1（高度点启用 = 游戏自出加高图）。⑨n 屏 2346×1080 → 点 1 = 720.0f << 32 | 1564.0f(0x44c38000)。
    //   旧代码不认种类 f2h，装载即 die（红）
    for (int k = 0; k < 2; k++) {
        fflush(stdout); pid_t c = fork();
        if (c == 0) {
            module_t *m = &g_mod[14 + k]; snprintf(m->name, sizeof m->name, "main"); m->key_page_size = 16384; m->key_page_off = 0;
            m->base = (uint8_t *)mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            m->text_end = 0x4000; m->patch_off = -1; m->file_image_len = 0x8000;
            uint32_t mz = 0xd2a89e08u; memcpy(m->base + 0x20, &mz, 4);
            char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w");
            fprintf(g, "0\t0x10\tf2w\t%x\n1\t0x18\tf2h\tf2e88688\n2\t0x28\tf2h\tf2e890e8\n", W_F2W_1280); fclose(g);
            snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w");
            fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x10\tf2w\t1\nmain\t0x18\tf2h\t1\nmain\t0x28\tf2h\t0\n"); fclose(g);
            unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
            int s2a_screen_switch(int, int); s2a_screen_w(); s2a_screen_h(); s2a_screen_switch(k ? 2346 : 1920, k ? 1080 : 1350);
            s2a_widen_load(m, T); uint64_t *sl = (uint64_t *)m->base + WSLOT;
            uint64_t w1 = k ? 0x4434000044c38000ull : 0x4461000044a00000ull, w2 = 0x4487000044f00000ull;
            printf("⑨%c f2h（屏 %s）点 1 期望 %#llx → %#llx；点 2 期望 %#llx → %#llx；游戏出图 %d\n", k ? 'n' : 'm', k ? "2346×1080" : "1920×1350",
                   (unsigned long long)w1, (unsigned long long)sl[1], (unsigned long long)w2, (unsigned long long)sl[2], s2a_widen_game()); fflush(stdout);
            _exit((sl[1] == w1 ? 0 : 1) | (sl[2] == w2 ? 0 : 2) | (s2a_widen_game() == 1 ? 0 : 4)); }
        int st = 0; waitpid(c, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⑨%c f2h 打包浮点宽高的高半按屏高、低半随搭档 f2w（退出 %d）", k ? 'n' : 'm', WIFEXITED(st) ? WEXITSTATUS(st) : -1);
    }
    // ⑨o / ⑨p i2h（11-04 智慧的再现：渲染配置开头 = MOVZ x8,#1280 + MOVK x8,#720,LSL#32 打包的一对整数）：点 0 movz 0x10（MOVZ x8,#1280 = 0xd280a008，启用）；
    //   点 1 i2h 0x18（MOVK x8,#720,LSL#32 = 0xf2c05a08，启用）；点 2 i2h 0x28（无搭档行，代码 0x20 放 MOVZ x8,#1920 = 0xd280f008；MOVK x8,#1080,LSL#32 = 0xf2c08708，不启用）。
    //   期望（手算）：⑨o 屏 1920×1350 → 点 1 = 900 << 32 | 1280 = 0x0000038400000500；点 2 = 1080 << 32 | 1920 = 0x0000043800000780；游戏出图 1。
    //   ⑨p 屏 2346×1080 → 点 1 = 720 << 32 | 1564 = 0x000002d00000061c。旧代码不认种类 i2h，装载即 die（红）
    for (int k = 0; k < 2; k++) {
        fflush(stdout); pid_t c = fork();
        if (c == 0) {
            module_t *m = &g_mod[16 + k]; snprintf(m->name, sizeof m->name, "main"); m->key_page_size = 16384; m->key_page_off = 0;
            m->base = (uint8_t *)mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            m->text_end = 0x4000; m->patch_off = -1; m->file_image_len = 0x8000;
            uint32_t mz = 0xd280f008u; memcpy(m->base + 0x20, &mz, 4);
            char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w");
            fprintf(g, "0\t0x10\tmovz\td280a008\n1\t0x18\ti2h\tf2c05a08\n2\t0x28\ti2h\tf2c08708\n"); fclose(g);
            snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w");
            fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x10\tmovz\t1\nmain\t0x18\ti2h\t1\nmain\t0x28\ti2h\t0\n"); fclose(g);
            unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
            int s2a_screen_switch(int, int); s2a_screen_w(); s2a_screen_h(); s2a_screen_switch(k ? 2346 : 1920, k ? 1080 : 1350);
            s2a_widen_load(m, T); uint64_t *sl = (uint64_t *)m->base + WSLOT;
            uint64_t w1 = k ? 0x000002d00000061cull : 0x0000038400000500ull, w2 = 0x0000043800000780ull;
            printf("⑨%c i2h（屏 %s）点 1 期望 %#llx → %#llx；点 2 期望 %#llx → %#llx；游戏出图 %d\n", k ? 'p' : 'o', k ? "2346×1080" : "1920×1350",
                   (unsigned long long)w1, (unsigned long long)sl[1], (unsigned long long)w2, (unsigned long long)sl[2], s2a_widen_game()); fflush(stdout);
            _exit((sl[1] == w1 ? 0 : 1) | (sl[2] == w2 ? 0 : 2) | (s2a_widen_game() == 1 ? 0 : 4)); }
        int st = 0; waitpid(c, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⑨%c i2h 打包整数宽高的高半按屏高、低半随搭档 movz（退出 %d）", k ? 'p' : 'o', WIFEXITED(st) ? WEXITSTATUS(st) : -1);
    }
#endif
    // ⑩–⑬：宿主门 lytsz / capsz
    snprintf(p, sizeof p, "%s/main.widen.tsv", T); f = fopen(p, "w");
    fprintf(f, "0\t0x60\tlytsz\t2d451122\n1\t0x70\tcapsz\t2d4a2408\n2\t0x80\tlytsz\t2d451122\n3\t0x90\tlytsz\t2d7f0460\n"); fclose(f);
    snprintf(p, sizeof p, "%s/widen_enable.handheld.tsv", T); f = fopen(p, "w");
    fprintf(f, "模块\t偏移\t种类\t启用\nmain\t0x60\tlytsz\t1\nmain\t0x70\tcapsz\t0\nmain\t0x80\tlytsz\t1\nmain\t0x90\tlytsz\t1\n"); fclose(f);
    load(5, T); g_cur = &g_mod[5];
    static uint64_t fr[128]; float lay[16] = {0}, pane[24] = {0}, odd[16] = {0}, neg[4] = {1920, 1080, 0, 0};
    lay[10] = 1280; lay[11] = 720; pane[20] = 1280; pane[21] = 720; odd[10] = 1000; odd[11] = 720;
    uint8_t *q = (uint8_t *)fr + 256; float r[4];
    #define QF(i) (memcpy(r, q + 16 * (i), 16), r)
    memset(fr, 0xff, sizeof fr); fr[100] = (uint64_t)(uintptr_t)&fr[110]; fr[9] = (uint64_t)(uintptr_t)lay;
    s2a_widen_gate(0, fr, (uint64_t)(uintptr_t)g_mod[5].base + 0x60);
    { float a0 = QF(2)[0]; int z = r[1] == 0 && r[2] == 0 && r[3] == 0; float b0 = QF(4)[0]; int z2 = r[1] == 0 && r[2] == 0 && r[3] == 0;
      CHECK(a0 == 1564.0f && b0 == 720.0f && z && z2, "⑩ lytsz 启用 (1280,720) 期望 q2 = 1564、q4 = 720、高位 0 → %g / %g（高位清零 %d %d）", (double)a0, (double)b0, z, z2); }
    fr[0] = (uint64_t)(uintptr_t)pane; s2a_widen_gate(1, fr, (uint64_t)(uintptr_t)g_mod[5].base + 0x70);
    { float a0 = QF(8)[0], b0 = QF(9)[0]; CHECK(a0 == 1280.0f && b0 == 720.0f, "⑪ capsz 未启用期望 1280 / 720 → %g / %g", (double)a0, (double)b0); }
    CHECK(s2a_widen_layout() == 1, "⑭ 启用了 lytsz：s2a_widen_layout 期望 1（游戏界面布局也是宽的）");
    fr[9] = (uint64_t)(uintptr_t)odd; s2a_widen_gate(2, fr, (uint64_t)(uintptr_t)g_mod[5].base + 0x80);
    { float a0 = QF(2)[0]; CHECK(a0 == 1000.0f, "⑫ lytsz (1000,720) 不是 16:9 档期望原样 1000 → %g", (double)a0); }
    fr[3] = (uint64_t)(uintptr_t)&neg[2]; s2a_widen_gate(3, fr, (uint64_t)(uintptr_t)g_mod[5].base + 0x90);
    { float a0 = QF(0)[0], b0 = QF(1)[0]; CHECK(a0 == 2346.0f && b0 == 1080.0f, "⑬ 负偏移 #-8 (1920,1080) 期望 2346 / 1080 → %g / %g", (double)a0, (double)b0); }
    // ㉒–㉕ 宿主门 seadasp（10-30，sead 透视投影读宽高比，参考 SavageWind persp_matrix）：照原指令读，启用且约 16:9 → 屏幕比 2346 ÷ 1080，别的原样（期望手算）
    //   ㉒ ldp s2,s3,[x0,#0xac]（0x2d558c02）启用、[x0+0xac] = (0.5, 16/9) → q2 = 0.5、q3 = 2346/1080；㉓ ldr s1,[x0,#0xb0]（0xbd40b001）启用、16/9 → q1 = 2346/1080；
    //   ㉔ 同 ㉓ 启用但读到 4/3 → 原样 4/3；㉕ 同 ㉓ 未启用、16/9 → 原样 16/9。旧代码不认种类 seadasp：装载即 die（红）
    snprintf(p, sizeof p, "%s/main.widen.tsv", T); f = fopen(p, "w");
    fprintf(f, "0\t0x60\tseadasp\t2d558c02\n1\t0x70\tseadasp\tbd40b001\n2\t0x80\tseadasp\tbd40b001\n3\t0x90\tseadasp\tbd40b001\n"); fclose(f);
    snprintf(p, sizeof p, "%s/widen_enable.handheld.tsv", T); f = fopen(p, "w");
    fprintf(f, "模块\t偏移\t种类\t启用\nmain\t0x60\tseadasp\t1\nmain\t0x70\tseadasp\t1\nmain\t0x80\tseadasp\t1\nmain\t0x90\tseadasp\t0\n"); fclose(f);
    load(9, T); g_cur = &g_mod[9];
    { static float proj[64]; const float k169 = 16.0f / 9.0f, scr = 2346.0f / 1080.0f;
      proj[0xac / 4] = 0.5f; proj[0xb0 / 4] = k169;
      memset(fr, 0xff, sizeof fr); fr[100] = (uint64_t)(uintptr_t)&fr[110]; fr[0] = (uint64_t)(uintptr_t)proj;
      s2a_widen_gate(0, fr, (uint64_t)(uintptr_t)g_mod[9].base + 0x60);
      { float a0 = QF(2)[0], b0 = QF(3)[0]; CHECK(a0 == 0.5f && b0 == scr, "㉒ seadasp LDP 启用 (0.5, 16/9) 期望 q2 = 0.5、q3 = %g → %g / %g", (double)scr, (double)a0, (double)b0); }
      s2a_widen_gate(1, fr, (uint64_t)(uintptr_t)g_mod[9].base + 0x70);
      { float a0 = QF(1)[0]; CHECK(a0 == scr, "㉓ seadasp LDR 启用 16/9 期望 %g → %g", (double)scr, (double)a0); }
      proj[0xb0 / 4] = 4.0f / 3.0f; s2a_widen_gate(2, fr, (uint64_t)(uintptr_t)g_mod[9].base + 0x80);
      { float a0 = QF(1)[0]; CHECK(a0 == 4.0f / 3.0f, "㉔ seadasp 启用但读到 4/3 期望原样 → %g", (double)a0); }
      proj[0xb0 / 4] = k169; s2a_widen_gate(3, fr, (uint64_t)(uintptr_t)g_mod[9].base + 0x90);
      { float a0 = QF(1)[0]; CHECK(a0 == k169, "㉕ seadasp 未启用期望原样 16/9 → %g", (double)a0); } }
    #undef QF
    // ⑮⑯ aspf（10-26）：单独的 16:9 浮点常量，数据点，装载时改。可写模块：代码段末 0x4000（可写范围从 0x4000 起），常量放 0x4010 / 0x4020。
    //   期望（手算）：启用的 0x4010 → 屏幕宽 2346 ÷ 1080 = 2.1722222 的浮点位；未启用的 0x4020 → 原值 0x3fe38e39。旧代码不认种类 aspf：装载即 die（红）
    { pid_t c2 = fork();
      if (c2 == 0) {
          module_t *m = &g_mod[6]; snprintf(m->name, sizeof m->name, "main"); m->key_page_size = 16384; m->key_page_off = 0;
          m->base = (uint8_t *)mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
          m->text_end = 0x4000; m->patch_off = -1; m->file_image_len = 0x8000;
          uint32_t v = 0x3fe38e39u; memcpy(m->base + 0x4010, &v, 4); memcpy(m->base + 0x4020, &v, 4);
          char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "0\t0x4010\taspf\t3fe38e39\n1\t0x4020\taspf\t3fe38e39\n"); fclose(g);
          snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w"); fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x4010\taspf\t1\nmain\t0x4020\taspf\t0\n"); fclose(g);
          s2a_widen_load(m, T);
          float want = 2346.0f / 1080.0f, a; uint32_t b; memcpy(&a, m->base + 0x4010, 4); memcpy(&b, m->base + 0x4020, 4);
          _exit((a == want ? 0 : 1) | (b == 0x3fe38e39u ? 0 : 2)); }
      int st = 0; waitpid(c2, &st, 0);
      CHECK(WIFEXITED(st) && !(WEXITSTATUS(st) & 1), "⑮ aspf 启用：0x4010 期望改成 2346 ÷ 1080（退出 %d）", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
      CHECK(WIFEXITED(st) && !(WEXITSTATUS(st) & 2), "⑯ aspf 未启用：0x4020 期望原值 0x3fe38e39（退出 %d）", WIFEXITED(st) ? WEXITSTATUS(st) : -1); }
    // ⑰⑱⑲ i32（10-26）：整数分辨率表（丝之歌 SwitchPlatform 记录），数据点，装载时整表宽放大。可写模块同上：0x4010 = 1280,720,1920,1080（启用）、0x4030 = 1024,576,1280,720（未启用）。
    //   期望（手算，x × 2346 ÷ 1920 四舍五入）：0x4010 → 1564,720,2346,1080；0x4030 原样；只启用 i32 也是改渲染尺寸的点 → s2a_widen_game 期望 1。旧代码不认种类 i32：装载即 die（红）
    { pid_t c3 = fork();
      if (c3 == 0) {
          module_t *m = &g_mod[7]; snprintf(m->name, sizeof m->name, "main"); m->key_page_size = 16384; m->key_page_off = 0;
          m->base = (uint8_t *)mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
          m->text_end = 0x4000; m->patch_off = -1; m->file_image_len = 0x8000;
          uint32_t t0[4] = {1280, 720, 1920, 1080}, t1[4] = {1024, 576, 1280, 720}; memcpy(m->base + 0x4010, t0, 16); memcpy(m->base + 0x4030, t1, 16);
          char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "0\t0x4010\ti32\t500\n1\t0x4030\ti32\t400\n"); fclose(g);
          snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w"); fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x4010\ti32\t1\nmain\t0x4030\ti32\t0\n"); fclose(g);
          setenv("S2A_SCREEN_W", "2346", 1); unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
          s2a_widen_load(m, T);
          uint32_t a[4], b[4], wa[4] = {1564, 720, 2346, 1080}; memcpy(a, m->base + 0x4010, 16); memcpy(b, m->base + 0x4030, 16);
          _exit((memcmp(a, wa, 16) ? 1 : 0) | (memcmp(b, t1, 16) ? 2 : 0) | (s2a_widen_game() == 1 ? 0 : 4)); }
      int st = 0; waitpid(c3, &st, 0);
      CHECK(WIFEXITED(st) && !(WEXITSTATUS(st) & 1), "⑰ i32 启用：0x4010 期望 1564,720,2346,1080（退出 %d）", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
      CHECK(WIFEXITED(st) && !(WEXITSTATUS(st) & 2), "⑱ i32 未启用：0x4030 期望原样 1024,576,1280,720（退出 %d）", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
      CHECK(WIFEXITED(st) && !(WEXITSTATUS(st) & 4), "⑲ 只启用 i32：s2a_widen_game 期望 1（游戏自己出宽图）（退出 %d）", WIFEXITED(st) ? WEXITSTATUS(st) : -1); }
    // ⑳㉑ f32（审计 #829 F-scan-f32-text）：锚点 (1920,1080) 只认代码段末页之后的可写范围，同 aspf / i32。可写模块代码段末 0x4000：
    //   0x200（代码段里）放 (1920,1080),(1280,720) 并启用 → 期望原样不动；0x4010（代码段后）放同样两对并启用 → 期望 2346,1080,1564,720（x × 2346 ÷ 1920 四舍五入）。
    //   旧代码：0x200 的表照样按屏幕宽放大（锚点只用 lo 往前找表头），⑳ 红
    { pid_t c4 = fork();
      if (c4 == 0) {
          module_t *m = &g_mod[8]; snprintf(m->name, sizeof m->name, "main"); m->key_page_size = 16384; m->key_page_off = 0;
          m->base = (uint8_t *)mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
          m->text_end = 0x4000; m->patch_off = -1; m->file_image_len = 0x8000;
          float t0[4] = {1920.0f, 1080.0f, 1280.0f, 720.0f}; memcpy(m->base + 0x200, t0, 16); memcpy(m->base + 0x4010, t0, 16);
          char q[600]; snprintf(q, sizeof q, "%s/main.widen.tsv", T); FILE *g = fopen(q, "w"); fprintf(g, "0\t0x200\tf32\t1920.0,1080.0\n1\t0x4010\tf32\t1920.0,1080.0\n"); fclose(g);
          snprintf(q, sizeof q, "%s/widen_enable.handheld.tsv", T); g = fopen(q, "w"); fprintf(g, "模块\t偏移\t种类\t启用\nmain\t0x200\tf32\t1\nmain\t0x4010\tf32\t1\n"); fclose(g);
          setenv("S2A_SCREEN_W", "2346", 1); unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
          s2a_widen_load(m, T);
          float a[4], b[4], wb[4] = {2346.0f, 1080.0f, 1564.0f, 720.0f}; memcpy(a, m->base + 0x200, 16); memcpy(b, m->base + 0x4010, 16);
          _exit((memcmp(a, t0, 16) ? 1 : 0) | (memcmp(b, wb, 16) ? 2 : 0)); }
      int st = 0; waitpid(c4, &st, 0);
      CHECK(WIFEXITED(st) && !(WEXITSTATUS(st) & 1), "⑳ f32 锚点在代码段里（0x200）：期望原样 1920,1080,1280,720 不写（退出 %d）", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
      CHECK(WIFEXITED(st) && !(WEXITSTATUS(st) & 2), "㉑ f32 锚点在代码段后（0x4010）：期望 2346,1080,1564,720（退出 %d）", WIFEXITED(st) ? WEXITSTATUS(st) : -1); }
    // 补丁启用行（补丁包 v1，patch.c + widen.c patch_enable）：movz 1280 点在 main+0x10（原字 0x5280a000），屏宽 2346、掌机档。期望（手算）：启用 = 1280 × 2346 ÷ 1920 = 1564，不启用 = 1280。
    //   ㉒ 同构建、补丁开、包内表关 → 1564；㉓ 同构建、补丁关、包内表开 → 1280（补丁有本档段 = 整表取补丁）；㉔ 同构建、orig 对不上 → 跳过 → 1280；
    //   ㉕ 换构建、偏移写成 0x99、orig 对、特征前后 4 字节 0 对得上 → 定位到 0x10 → 1564，.applied 记 sig_hit 1；㉖ 换构建、特征前 1 字节不对 → 1280；
    //   ㉗ 换构建、没写 orig → 1280；㉘ 补丁只有主机段、掌机局 → 走包内表（开）→ 1564；㉙ 补丁程序号不是本款 → 整份不用 → 包内表 → 1564。
    { const char *pb = "0123456789abcdef0123456789abcdef";
      struct { const char *bid, *row, *sec, *prog; int table_on; uint32_t want; const char *what; } C[] = {
        {pb, "main\t0x10\tmovz\t1\torig=5280a000", "widen.enable.handheld", NULL, 0, 1564, "㉒ 同构建补丁开、包内表关"},
        {pb, "main\t0x10\tmovz\t0", "widen.enable.handheld", NULL, 1, 1280, "㉓ 同构建补丁关、包内表开"},
        {pb, "main\t0x10\tmovz\t1\torig=deadbeef", "widen.enable.handheld", NULL, 1, 1280, "㉔ 同构建原字对不上"},
        {"ffffffffffffffffffffffffffffffff", "main\t0x99\tmovz\t1\torig=5280a000\tsig=00000000|00000000", "widen.enable.handheld", NULL, 0, 1564, "㉕ 换构建按特征定位"},
        {"ffffffffffffffffffffffffffffffff", "main\t0x99\tmovz\t1\torig=5280a000\tsig=11000000|00000000", "widen.enable.handheld", NULL, 1, 1280, "㉖ 换构建特征不对"},
        {"ffffffffffffffffffffffffffffffff", "main\t0x10\tmovz\t1", "widen.enable.handheld", NULL, 0, 1280, "㉗ 换构建没写 orig"},
        {pb, "main\t0x10\tmovz\t0", "widen.enable.docked", NULL, 1, 1564, "㉘ 只有主机段、掌机局"},
        {pb, "main\t0x10\tmovz\t0", "widen.enable.handheld", "0100000000000099", 1, 1564, "㉙ 程序号不对"},
      };
      for (unsigned k = 0; k < sizeof C / sizeof C[0]; k++) {
          fflush(stdout); pid_t c = fork();
          if (c == 0) {
              char q[700]; FILE *g; unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED"); unsetenv("S2A_WIDEN_FULL"); setenv("S2A_SCREEN_W", "2346", 1);
              snprintf(q, sizeof q, "%s/main.widen.tsv", T); g = fopen(q, "w"); fprintf(g, "0\t0x10\tmovz\t%x\n", 0x52800000u | (1280u << 5)); fclose(g);
              put(T, "widen_enable.handheld.tsv", C[k].table_on);
              uint8_t npdm[0x98] = {0}; memcpy(npdm, "META", 4); uint32_t ao = 0x80; memcpy(npdm + 0x70, &ao, 4); memcpy(npdm + 0x80, "ACI0", 4);
              uint64_t pid = 0x0100000000000042ull; memcpy(npdm + 0x90, &pid, 8);
              snprintf(q, sizeof q, "%s/main.npdm", T); g = fopen(q, "wb"); fwrite(npdm, 1, sizeof npdm, g); fclose(g);
              snprintf(q, sizeof q, "%s/patches/0100000000000042", T); char mk[760]; snprintf(mk, sizeof mk, "mkdir -p %s", q); (void)!system(mk);
              snprintf(q, sizeof q, "%s/patches/0100000000000042/patch.tsv", T); g = fopen(q, "w");
              fprintf(g, "# S2Arm 补丁包 v1\nschema\t1\nprogram\t%s\nbuild\t%s\n[%s]\n%s\n[fps]\nw\t1\n", C[k].prog ? C[k].prog : "0100000000000042", pb, C[k].sec, C[k].row); fclose(g);
              snprintf(q, sizeof q, "%s/patches", T); setenv("S2A_PATCH_DIR", q, 1);
              snprintf(g_bid, sizeof g_bid, "%s", C[k].bid);
              s2a_patch_open(T);
              module_t *m = &g_mod[40 + k]; snprintf(m->name, sizeof m->name, "main"); m->key_page_size = 16384; m->key_page_off = 0; m->size = 16384;
              m->base = (uint8_t *)mmap(NULL, 16384, PROT_READ, MAP_ANON | MAP_PRIVATE, -1, 0);
              s2a_widen_load(m, T); s2a_patch_finish(g_bid);
              uint32_t v = (uint32_t)((uint64_t *)m->base)[WSLOT];
              int applied_ok = 1;
              if (k == 3) { snprintf(q, sizeof q, "%s/patches/0100000000000042/.applied", T); g = fopen(q, "r"); char b[2048] = ""; if (g) { (void)!fread(b, 1, sizeof b - 1, g); fclose(g); } applied_ok = strstr(b, "sig_hit\t1\n") != NULL; }
              printf("%s 期望 %u → 真结果 %u%s\n", C[k].what, C[k].want, v, applied_ok ? "" : "（.applied 没记 sig_hit 1）");
              fflush(stdout); _exit(v == C[k].want && applied_ok ? 0 : 1); }
          int st = 0; waitpid(c, &st, 0);
          CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "%s 不对", C[k].what);
      }
      char q[700]; snprintf(q, sizeof q, "rm -rf %s/patches %s/main.npdm", T, T); (void)!system(q); unsetenv("S2A_PATCH_DIR"); }
    char c[700]; snprintf(c, sizeof c, "rm -rf %s", T); (void)!system(c);
    if (bad) { printf("✗ t_widen：%d 项红\n", bad); return 1; }
    printf("✓ t_widen：启用表按档位读 4 项（掌机 1564 / 主机 1280 / 只有旧合并表 1280 / 环境变量覆盖 1564）+ 值槽 8 项（asp 原值 2 / f2w 原值 1 / f2w 加宽 2 / 宽高比上限 3）+ 第三层表 3 项（一行 1 / 一行 0 / 没有表）+ 宿主门 lytsz / capsz 4 项 + 界面布局宽 2 项 + f32 代码段内外 2 项 + 补丁启用行 8 项（同构建开 / 关 / 原字不对、换构建特征定位 / 特征不对 / 没 orig、只有主机段、程序号不对）\n"); return 0;
}

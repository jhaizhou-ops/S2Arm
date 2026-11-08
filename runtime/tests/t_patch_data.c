// 补丁包 [data] 段单测（runtime/src/patch_data.c 经 cpatch.c 的数据写入；设计稿 12.12，一次成功线 11-03）。期望全部手算，不跑被测实现推：
//   造模块：映像 0xc000，代码段末 0x1000（可写范围从 0x4000 起、到键页 0x8000 前，键页 16 KB），只读数据里放两份缓存配置串
//     0x5000 = 「15360/20480/-1」，前 4 字节 AAAA；0x6000 = 同一串，前 4 字节 BBBB；0x5800 = 16:9 浮点 0x3fe38e39（满屏 aspf 点）
//   新串「03584/08192/-1」同长 14 字节（游戏 %ld 读，前导 0 仍按十进制 3584 / 8192）
//   ① 同构建号、偏移 5000、原字节对 → 写入；.applied fast 1、note「按偏移（快路径）写入 14 字节」
//   ② 同构建号、偏移 5001、原字节不符 → 不写、0x5000 仍是原串；.applied skipped 1、note 带【黄】
//   ③ 构建号不同、偏移写错成 7777、sig 前 AAAA → 唯一命中 0x5000 写入、0x6000 不动；sig_hit 1、note「按特征定位到 +0x5000」
//   ④ 构建号不同、sig 只给后 1 字节 00（两份都命中）→ 命中 2 处跳过、两份都不动；note「命中 2 处」
//   ⑤ 写只读数据段后游戏读到新值：写完把 [0x4000, 0x8000) 封只读，按游戏的读法 sscanf("%ld/%ld/%d") 得 3584 / 8192 / -1
//   ⑥ 无条件生效：S2A_FPS60=0、S2A_WIDEN_CAPS=0、S2A_WIDESCREEN=0 照样写入（同 ①）
//   ⑦ 与满屏数据点重叠：[data] 写 0x5800 四字节 3fe38e39 → 0000c03f（1.5f），同时满屏 aspf 点 0x5800 启用、屏幕宽 2346
//      → 以 [data] 为准：0x5800 = 0x3fc00000（不是 2346 ÷ 1080），.applied note「aspf 与补丁 [data] 重叠，以 [data] 为准」
//   ⑧ 补丁随包（部署方案 v2，满屏补丁线 11-04）：补丁根没有本款目录、游戏数据目录（资源包根）有 patch.tsv → 读随包那份、写入；.applied 写进新建的补丁根 <程序号>/
//      iOS 形态（审计 P1-106）：模块目录 = App 包、没有 patch.tsv，资源包根是另一个目录（S2A_GAME_DATA）→ 仍读到随包那份。旧实现只开模块目录：红
//   ⑧b Mac 形态：没设 S2A_GAME_DATA、随包那份在模块目录 → 读到
//   ⑨ 补丁根与随包都有 → 只取补丁根那份（补丁根行偏移 5001 原字节不符 → 不写、skipped 1；随包那份偏移 5000 能写也不用）
//   ⑩ 两处都没有 → 不写、不建 .applied
#include <sys/wait.h>
#include <unistd.h>
#include "../src/native.h"
#include "../include/patch.h"
#include <sys/mman.h>
#include <sys/stat.h>
S2A_TEST_MOD_TABLE(64); int g_nmod;
static char g_tmd[600];
const char *s2a_module_dir(void) { return g_tmd; }
static char g_bid[40];
const char *s2a_main_build_id(void) { return g_bid; }
module_t *module_of(const void *p) { (void)p; return &g_mod[0]; }
void s2a_host_write_hook(uint64_t a, uint64_t n) { (void)a; (void)n; }
void s2a_patch_data_apply(module_t *m);
void s2a_widen_load(module_t *m, const char *dir);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } else { printf("✓ " __VA_ARGS__); printf("\n"); } } while (0)
#define BUILD "11223344556677889900aabbccddeeff"
#define PID "0100000000ABC000"
static const char *OLD = "15360/20480/-1", *NEW = "03584/08192/-1";
static void hex(char *o, const void *p, int n) { for (int i = 0; i < n; i++) sprintf(o + 2 * i, "%02x", ((const uint8_t *)p)[i]); }
static char T[64];
static const char *g_packrows; static int g_noroot; static char g_gd[700];   // g_gd：资源包根（非空 = iOS 形态，设 S2A_GAME_DATA）   // ⑧–⑩：随包补丁行（写游戏数据目录 patch.tsv）/ 补丁根不放本款
static void write_patch(const char *build, const char *rows) {
    char p[700]; snprintf(p, sizeof p, "%s/patches/%s", T, PID); mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/patches/%s/patch.tsv", T, PID); FILE *f = fopen(p, "w");
    fprintf(f, "schema\t1\nprogram\t%s\nbuild\t%s\nclass\tcorrectness\n%s", PID, build, rows); fclose(f);
    snprintf(p, sizeof p, "%s/patches/%s/.applied", T, PID); unlink(p);
}
static module_t *mk(void) {
    module_t *m = &g_mod[0]; memset(m, 0, sizeof *m); snprintf(m->name, sizeof m->name, "main"); g_nmod = 1;
    m->size = 0xc000; m->base = mmap(NULL, m->size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    m->text_end = 0x1000; m->key_page_off = 0x8000; m->key_page_size = 0x4000; m->patch_off = -1; m->file_image_len = 0x8000;
    memcpy(m->base + 0x4ffc, "AAAA", 4); memcpy(m->base + 0x5000, OLD, 15);
    memcpy(m->base + 0x5ffc, "BBBB", 4); memcpy(m->base + 0x6000, OLD, 15);
    uint32_t v = 0x3fe38e39u; memcpy(m->base + 0x5800, &v, 4);
    return m;
}
static void applied(char *buf, size_t n) {
    char p[700]; snprintf(p, sizeof p, "%s/patches/%s/.applied", T, PID); FILE *f = fopen(p, "r"); buf[0] = 0;
    if (f) { size_t k = fread(buf, 1, n - 1, f); buf[k] = 0; fclose(f); }
}
// 子进程跑一例：返回 0x5000 / 0x6000 处是否为新串（位 1 / 位 2）、0x5800 是否 1.5f（位 4）、游戏读法读到 3584/8192（位 8）；.applied 写到文件，父进程读
static int run(const char *bid, const char *rows, int widen) {
    fflush(stdout); pid_t c = fork();
    if (c == 0) {
        snprintf(g_bid, sizeof g_bid, "%s", bid);
        write_patch(BUILD, rows);
        char q[700]; snprintf(q, sizeof q, "%s/patch.tsv", g_tmd); unlink(q);
        if (g_gd[0]) { setenv("S2A_GAME_DATA", g_gd, 1); snprintf(q, sizeof q, "%s/patch.tsv", g_gd); unlink(q); } else unsetenv("S2A_GAME_DATA");
        if (g_packrows) { FILE *pf = fopen(q, "w"); fprintf(pf, "schema\t1\nprogram\t%s\nbuild\t%s\n%s", PID, BUILD, g_packrows); fclose(pf); }
        if (g_noroot) { snprintf(q, sizeof q, "%s/patches/%s/patch.tsv", T, PID); unlink(q); snprintf(q, sizeof q, "%s/patches/%s", T, PID); rmdir(q); }
        module_t *m = mk();
        s2a_patch_open(g_tmd);
        s2a_patch_data_apply(m);
        if (widen) s2a_widen_load(m, g_tmd);
        s2a_patch_finish(g_bid);
        mprotect(m->base + 0x4000, 0x4000, PROT_READ);   // ⑤ 装载器封只读之后，游戏照读
        long lo = 0, hi = 0; int z = 0; sscanf((const char *)m->base + 0x5000, "%ld/%ld/%d", &lo, &hi, &z);
        uint32_t w; memcpy(&w, m->base + 0x5800, 4);
        _exit((!memcmp(m->base + 0x5000, NEW, 14) ? 1 : 0) | (!memcmp(m->base + 0x6000, NEW, 14) ? 2 : 0) | (w == 0x3fc00000u ? 4 : 0) | (lo == 3584 && hi == 8192 && z == -1 ? 8 : 0));
    }
    int st = 0; waitpid(c, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
int main(void) {
    snprintf(T, sizeof T, "/tmp/s2a_t_patch_data_XXXXXX"); if (!mkdtemp(T)) return 1;
    snprintf(g_tmd, sizeof g_tmd, "%s/mod", T); mkdir(g_tmd, 0755);
    char p[700]; snprintf(p, sizeof p, "%s/patches", T); mkdir(p, 0755); setenv("S2A_PATCH_DIR", p, 1);
    { uint8_t npdm[0x100] = {0}; memcpy(npdm, "META", 4); uint32_t off = 0x80; memcpy(npdm + 0x70, &off, 4); memcpy(npdm + 0x80, "ACI0", 4);
      uint64_t pid = 0x0100000000ABC000ull; memcpy(npdm + 0x90, &pid, 8);
      snprintf(p, sizeof p, "%s/main.npdm", g_tmd); FILE *f = fopen(p, "wb"); fwrite(npdm, 1, sizeof npdm, f); fclose(f); }
    char o[40], n[40], a[8192], row[600]; hex(o, OLD, 14); hex(n, NEW, 14);
    unsetenv("S2A_FPS60"); unsetenv("S2A_WIDEN_CAPS");
    snprintf(row, sizeof row, "[data]\nmain\t5000\torig=%s\tnew=%s\t# 缓存配置串\n", o, n);
    int r = run(BUILD, row, 0); applied(a, sizeof a);
    CHECK(r == (1 | 8) && strstr(a, "fast\t1") && strstr(a, "按偏移（快路径）写入 14 字节"), "① 同构建号按偏移写入（退出 %d）", r);
    CHECK(r & 8, "⑤ 写只读数据段后游戏读到 3584 / 8192 / -1（退出 %d）", r);
    snprintf(row, sizeof row, "[data]\nmain\t5001\torig=%s\tnew=%s\n", o, n);
    r = run(BUILD, row, 0); applied(a, sizeof a);
    CHECK(r == 0 && strstr(a, "skipped\t1") && strstr(a, "【黄】"), "② 原字节不符跳过、记黄（退出 %d）", r);
    snprintf(row, sizeof row, "[data]\nmain\t7777\torig=%s\tnew=%s\tsig=41414141|\n", o, n);
    r = run("00000000000000000000000000000000", row, 0); applied(a, sizeof a);
    CHECK(r == (1 | 8) && strstr(a, "sig_hit\t1") && strstr(a, "按特征定位到 +0x5000"), "③ 构建号不同、特征唯一命中 0x5000（退出 %d）", r);
    snprintf(row, sizeof row, "[data]\nmain\t5000\torig=%s\tnew=%s\tsig=|00\n", o, n);
    r = run("00000000000000000000000000000000", row, 0); applied(a, sizeof a);
    CHECK(r == 0 && strstr(a, "命中 2 处"), "④ 特征命中 2 处跳过、两份都不动（退出 %d）", r);
    setenv("S2A_FPS60", "0", 1); setenv("S2A_WIDEN_CAPS", "0", 1); setenv("S2A_WIDESCREEN", "0", 1);
    snprintf(row, sizeof row, "[data]\nmain\t5000\torig=%s\tnew=%s\n", o, n);
    r = run(BUILD, row, 0);
    CHECK(r == (1 | 8), "⑥ 60 帧关、满屏关照样写入（退出 %d）", r);
    unsetenv("S2A_FPS60"); unsetenv("S2A_WIDEN_CAPS"); unsetenv("S2A_WIDESCREEN");
    setenv("S2A_WIDEN_VERIFIED", "1", 1); setenv("S2A_SCREEN_W", "2346", 1); unsetenv("S2A_WIDEN_SITES"); unsetenv("S2A_DOCKED");
    snprintf(p, sizeof p, "%s/main.widen.tsv", g_tmd); FILE *f = fopen(p, "w"); fprintf(f, "0\t0x5800\taspf\t3fe38e39\n"); fclose(f);
    snprintf(p, sizeof p, "%s/widen_enable.handheld.tsv", g_tmd); f = fopen(p, "w"); fprintf(f, "模块\t偏移\t种类\t启用\nmain\t0x5800\taspf\t1\n"); fclose(f);
    snprintf(row, sizeof row, "[data]\nmain\t5800\torig=398ee33f\tnew=0000c03f\n");
    r = run(BUILD, row, 1); applied(a, sizeof a);
    CHECK((r & 4) && strstr(a, "aspf 与补丁 [data] 重叠，以 [data] 为准"), "⑦ 与满屏 aspf 重叠：以 [data] 为准、满屏那点跳过并记一行（退出 %d）", r);
    char good[600], skip[600]; snprintf(good, sizeof good, "[data]\nmain\t5000\torig=%s\tnew=%s\n", o, n); snprintf(skip, sizeof skip, "[data]\nmain\t5001\torig=%s\tnew=%s\n", o, n);
    snprintf(g_gd, sizeof g_gd, "%s/资源包", T); mkdir(g_gd, 0755);
    g_noroot = 1; g_packrows = good; r = run(BUILD, "", 0); applied(a, sizeof a);
    CHECK(r == (1 | 8) && strstr(a, "fast\t1"), "⑧ iOS 形态：补丁根没有、随包那份在资源包根（≠ 模块目录）→ 读到写入，.applied 写进新建的补丁根目录（退出 %d）", r);
    g_gd[0] = 0; r = run(BUILD, "", 0); applied(a, sizeof a);
    CHECK(r == (1 | 8) && strstr(a, "fast\t1"), "⑧b Mac 形态：没设 S2A_GAME_DATA、随包那份在模块目录 → 读到写入（退出 %d）", r);
    snprintf(g_gd, sizeof g_gd, "%s/资源包", T);
    g_noroot = 0; g_packrows = good; r = run(BUILD, skip, 0); applied(a, sizeof a);
    CHECK(r == 0 && strstr(a, "skipped\t1"), "⑨ 补丁根与随包都有 → 只取补丁根那份（退出 %d）", r);
    g_noroot = 1; g_packrows = NULL; r = run(BUILD, "", 0); applied(a, sizeof a);
    CHECK(r == 0 && !a[0], "⑩ 两处都没有 → 不写、不建 .applied（退出 %d）", r);
    if (bad) printf("补丁 [data] 单测：%d 项不过\n", bad);
    else printf("✓ t_patch_data：11 项（随包补丁回落 iOS / Mac 两形态 / 补丁根优先 / 两处都没有 + 同构建号按偏移 / 原字节不符跳过记黄 / 构建号不同特征唯一命中 / 命中 2 处跳过 / 写只读数据段读到新值 / 60 帧与满屏关照样写 / 与满屏 aspf 重叠以 [data] 为准）\n");
    return bad ? 1 : 0;
}

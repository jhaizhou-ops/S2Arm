// 管线预取单测（gal_state.m 管线预取，10-22 换场景首帧建管线：马车8 进赛道那帧 145 条全是归档命中，开片 + 取全在渲染线程）。三个进程（本程序自己起自己），管线来源用设备归档（NXGAL_PSO_DEV=1）：
//   ① 新目录：只有顶点阶段的程序（tests/t_fbr_vsp）画进 RG16F、写掩码只 R → 基础管线现编、特化各 1，后台收进设备归档；日志里「管线首用」行 2 条（b 基础 + f 完整）
//      父进程拿 ① 的日志跑真收集器 graphics/tools/shbake/psouse.py 出用表，放进包目录 pso_use.tsv，并追加一行坏格式、一行别的程序（哈希不同）的
//      期望（手算）：现编 1、特化 1、预取取用 0（没表）；用表 2 条（b、f 各 1）
//   ② 带表新进程，先登记归档、后建程序（首遇现编收尾时排）：用表 3 条、坏行 1；已排 2（别的程序那条不排）、后台取到 2、归档没有 0；
//      画：现编 0、特化 0、预取取用 2、渲染线程上设备归档直接取 0（全从池里来）；出图与 ① 逐字节相同
//   ③ 先载 ① 存的程序二进制、后登记归档（补排已建成的程序）：已排 2、取到 2、预取取用 2、现编 0
//   反证：旧代码没有预取，② ③ 预取取用 0、渲染线程从设备归档直接取 1
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <libgen.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <execinfo.h>
#include <signal.h>
static void segv(int sig) { void *b[40]; int n = backtrace(b, 40); backtrace_symbols_fd(b, n, 2); _exit(139); }
#include "../gal_formats.h"

GAL_MTL4_ZONE_BEGIN
extern char **environ;
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
static uint8_t *load(const char *path, uint32_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) { printf("读不了 %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)l); if (fread(b, 1, (size_t)l, f) != (size_t)l) exit(2);
    fclose(f); *len = (uint32_t)l; return b;
}
static uint8_t g_rb[32 * 32 * 4];
static void draw_rg16f_r(uint32_t prog) {
    nxgal_tex_info ci = {32, 32, 1, 1, 1, 1, 1, 4, F_R16G16Float, 0, 1, {2, 3, 4, 5}}; uint32_t A = nxgal_tex_create(&ci);
    nxgal_set_render_targets(&A, 1, 0);
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1); nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {1, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    float c[4] = {1, 1, 1, 1}; uint32_t u = nxgal_buf_create(16, 0); nxgal_buf_set_data(u, 0, c, 16); nxgal_buf_assign a0 = {0, {u, 0, 16, 0}}; nxgal_set_uniform_buffers(&a0, 1);
    float v[12] = {-1, -1, 0.5f, 1, -1, 0.5f, 1, 1, 0.5f, -1, 1, 0.5f}; uint32_t vb = nxgal_buf_create(48, 0); nxgal_buf_set_data(vb, 0, v, 48);
    nxgal_vbuf vbd = {{vb, 0, 48, 0}, 12, 0}; nxgal_set_vertex_buffers(&vbd, 1); nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7);
    nxgal_set_program(prog); nxgal_draw(4, 1, 0, 0);
    nxgal_tex_get_data(A, 0, 0, g_rb, sizeof g_rb); nxgal_tex_release(A);
}
static void pf_wait(uint64_t s[7]) { for (int i = 0; i < 1000; i++) { gal_pso_pf_stats(s); if (s[0] && s[1] + s[2] >= s[0]) return; usleep(10000); } }
// 一个进程的一轮：读数打成一行 RES 供父进程比
static int run_phase(const char *exe, const char *pkdir, int phase) {
    char dir[1100], bin[1200]; snprintf(dir, sizeof dir, "%s/t_fbr_in/vsp.spv", dirname((char *)exe)); snprintf(bin, sizeof bin, "%s/prog.bin", pkdir);
    if (nxgal_init(0)) return 2;
    if (!gal_pso_can_specialize()) { printf("RES skip\n"); nxgal_shutdown(); return 0; }
    uint32_t P = 0, vl; uint64_t s[7] = {0};
    if (phase == 3) {
        uint8_t *b = load(bin, &vl); P = nxgal_prog_load_binary(b, (int32_t)vl, 0); free(b);
        nxgal_pso_archive_open_dir(pkdir);
    } else {
        nxgal_pso_archive_open_dir(pkdir);
        uint8_t *v = load(dir, &vl); nxgal_shader sh[1] = {{v, vl, 1}};
        P = nxgal_prog_create(sh, 1, NULL, 0, 0xff); free(v);
        for (int i = 0; i < 500 && P && nxgal_prog_status(P, 0) == 2; i++) usleep(10000);
    }
    if (phase != 1) pf_wait(s);
    uint64_t ps0[4]; nxgal_pso_cache_stats(ps0);
    uint64_t s0 = gal_pso_spec_count(), dh0 = gal_spec_dev_hits(); draw_rg16f_r(P); uint64_t s1 = gal_pso_spec_count();
    uint64_t ps[4]; nxgal_pso_cache_stats(ps); gal_pso_pf_stats(s);
    if (phase == 1) {
        int32_t n = nxgal_prog_binary(P, NULL, 0); uint8_t *b = malloc((size_t)n);
        if (n > 0 && nxgal_prog_binary(P, b, n) == n) { FILE *f = fopen(bin, "wb"); fwrite(b, 1, (size_t)n, f); fclose(f); }
        free(b);
        uint64_t d[6]; for (int i = 0; i < 1000; i++) { gal_pso_dev_stats(d); if (d[4] + d[5] >= d[3]) break; usleep(10000); }
        gal_pso_dev_flush("单测");
    }
    nxgal_shutdown();
    char out[1200]; snprintf(out, sizeof out, "%s/rb.%d", pkdir, phase); FILE *f = fopen(out, "wb"); if (f) { fwrite(g_rb, 1, sizeof g_rb, f); fclose(f); }
    printf("RES 现编 %llu 特化 %llu 设备直接取 %llu 表 %llu 坏 %llu 排 %llu 取到 %llu 没有 %llu 取用 %llu\n", (unsigned long long)(ps[1] - ps0[1]), (unsigned long long)(s1 - s0),
           (unsigned long long)(gal_spec_dev_hits() - dh0), (unsigned long long)s[5], (unsigned long long)s[6], (unsigned long long)s[0], (unsigned long long)s[1], (unsigned long long)s[2], (unsigned long long)s[3]);
    return 0;
}
static int child(const char *exe, const char *pk, int phase, unsigned long long r[9]) {
    char ph[8], lg[1200]; snprintf(ph, sizeof ph, "%d", phase); snprintf(lg, sizeof lg, "%s/log.%d", pk, phase); char *args[] = {(char *)exe, "--phase", ph, (char *)pk, NULL};
    int fds[2]; pipe(fds); posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa); posix_spawn_file_actions_adddup2(&fa, fds[1], 1); posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addopen(&fa, 2, lg, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    pid_t pid; if (posix_spawn(&pid, exe, &fa, NULL, args, environ)) return -1; close(fds[1]);
    FILE *f = fdopen(fds[0], "r"); char line[512]; int got = 0;
    while (fgets(line, sizeof line, f)) { if (!strncmp(line, "RES skip", 8)) got = 2;
        else if (sscanf(line, "RES 现编 %llu 特化 %llu 设备直接取 %llu 表 %llu 坏 %llu 排 %llu 取到 %llu 没有 %llu 取用 %llu", &r[0], &r[1], &r[2], &r[3], &r[4], &r[5], &r[6], &r[7], &r[8]) == 9) { got = 1; printf("  %d：%s", phase, line + 4); } }
    fclose(f); int st; waitpid(pid, &st, 0); return WIFEXITED(st) && !WEXITSTATUS(st) ? got : -1;
}
static int same_rb(const char *pk, int a, int b) {
    char p1[1200], p2[1200]; snprintf(p1, sizeof p1, "%s/rb.%d", pk, a); snprintf(p2, sizeof p2, "%s/rb.%d", pk, b);
    FILE *x = fopen(p1, "rb"), *y = fopen(p2, "rb"); static uint8_t u[sizeof g_rb], w[sizeof g_rb];
    size_t nu = x ? fread(u, 1, sizeof u, x) : 0, nw = y ? fread(w, 1, sizeof w, y) : 0; if (x) fclose(x); if (y) fclose(y);
    return nu == sizeof u && nw == sizeof w && !memcmp(u, w, sizeof u);
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGSEGV, segv); signal(SIGBUS, segv);
    if (argc == 4 && !strcmp(argv[1], "--phase")) return run_phase(argv[0], argv[3], atoi(argv[2]));
    char root[] = "/tmp/t_psopf_XXXXXX"; if (!mkdtemp(root)) return 2;
    char pk[1100], devd[1100], shc[1100]; snprintf(pk, sizeof pk, "%s/pkg", root); snprintf(devd, sizeof devd, "%s/dev", root); snprintf(shc, sizeof shc, "%s/shc", root); mkdir(pk, 0755); mkdir(shc, 0755);
    char kp[1200]; snprintf(kp, sizeof kp, "%s/shader_pack.key", pk); FILE *f = fopen(kp, "w"); fputs("t1\n", f); fclose(f);
    setenv("NXGAL_PSO_DEV", "1", 1); setenv("NXGAL_PSO_DEV_DIR", devd, 1); setenv("NXGAL_SHADER_CACHE_DIR", shc, 1);
    unsigned long long a[9] = {0}, b[9] = {0}, c[9] = {0};
    printf("· ① 新目录：现编、特化，记管线首用行\n");
    int ga = child(argv[0], pk, 1, a); if (ga == 2) { printf("跳过：本机后端没有管线特化（Metal 3）\n"); return 0; }
    CHECK(ga == 1 && a[0] == 1 && a[1] == 1 && a[8] == 0, "期望 现编 1、特化 1、预取取用 0，实得 现编 %llu 特化 %llu 取用 %llu（子进程 %d）", a[0], a[1], a[8], ga);
    // 真收集器出用表（仓库根 = 可执行文件所在 build/gal 的上两级）
    char rr[1100]; snprintf(rr, sizeof rr, "%s", argv[0]); char *bd = dirname(rr); char cmd[4000], ut[1200];
    snprintf(cmd, sizeof cmd, "S2A_SHCOLLECT='%s/col' python3 '%s/../../graphics/tools/shbake/psouse.py' t '%s/log.1' > /dev/null && cp '%s/col/t/pso_use.tsv' '%s/pso_use.tsv'", root, bd, pk, root, pk);
    int rc = system(cmd); snprintf(ut, sizeof ut, "%s/pso_use.tsv", pk);
    int nb = 0, nf = 0; char ln[2048], pn[64] = ""; f = fopen(ut, "r");
    while (f && fgets(ln, sizeof ln, f)) { char *t1 = strchr(ln, '\t'); if (ln[0] == '#' || !t1) continue; if (t1[1] == 'b') nb++; else if (t1[1] == 'f') nf++; if (!pn[0]) sscanf(t1 + 3, "%63[^\t]", pn); }
    if (f) fclose(f);
    CHECK(rc == 0 && nb == 1 && nf == 1, "期望收集器出用表 b 1 条、f 1 条，实得 rc %d、b %d、f %d", rc, nb, nf);
    // 坏行 + 别的程序（键里程序哈希全改成 0x11…）各一行
    f = fopen(ut, "a"); fprintf(f, "0\tb\t%s\tzz\n0\tb\t%s\t1111111111111111-ff-ff-9a\n", pn, pn); fclose(f);
    printf("· ② 带表新进程：程序建成后后台预取，画时全从池里取\n");
    int gb = child(argv[0], pk, 2, b);
    CHECK(gb == 1 && b[3] == 3 && b[4] == 1 && b[5] == 2 && b[6] == 2 && b[7] == 0, "期望 用表 3、坏行 1、已排 2、取到 2、没有 0，实得 表 %llu 坏 %llu 排 %llu 取到 %llu 没有 %llu", b[3], b[4], b[5], b[6], b[7]);
    CHECK(gb == 1 && b[0] == 0 && b[1] == 0 && b[8] == 2 && b[2] == 0, "期望 现编 0、特化 0、预取取用 2、渲染线程设备直接取 0，实得 现编 %llu 特化 %llu 取用 %llu 设备直接取 %llu", b[0], b[1], b[8], b[2]);
    CHECK(same_rb(pk, 1, 2), "② 出图期望与 ① 逐字节相同");
    printf("· ③ 先载程序二进制、后登记归档：补排已建成的程序\n");
    int gc = child(argv[0], pk, 3, c);
    CHECK(gc == 1 && c[5] == 2 && c[6] == 2 && c[8] == 2 && c[0] == 0, "期望 已排 2、取到 2、预取取用 2、现编 0，实得 排 %llu 取到 %llu 取用 %llu 现编 %llu", c[5], c[6], c[8], c[0]);
    CHECK(same_rb(pk, 1, 3), "③ 出图期望与 ① 逐字节相同");
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", root); system(cmd);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END

// 设备归档单测（gal_core.m 设备归档，10-22 总指挥：设备上现编的完整版与特化结果进 App 自己的持久归档，下次启动先读它）。三个进程（本程序自己起自己）：
//   ① 新目录：只有顶点阶段的程序（tests/t_fbr_vsp）画进 RG16F、写掩码只 R → 基础管线现编（被收）、特化后按完整描述后台编一条（被收）→ 写盘
//      期望（手算）：现编 1、特化 1、写盘 2 条 ≥ 1 个文件。主编译器现编，基础管线与特化结果各后台补录 1 条，共 2 条（顶点自取与否相同）。
//      画完立刻写一次盘（后台还在编）再等编完写一次：写盘与后台编译撞车不崩（10-22 测试机1 设备归档 10 秒写盘处段错误的反证）
//   ② 同包键、新进程：同样画 → 基础管线与完整版都从设备归档取：现编 0、特化 0、特化直接取 1、出图与 ① 逐字节相同
//   ③ 换包键（shader_pack.key 改）：新目录 → 设备归档命中 0、现编 1（旧条目自然不用）
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <libgen.h>
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
static uint8_t *load(const char *dir, const char *name, uint32_t *len) {
    char p[1200]; snprintf(p, sizeof p, "%s/%s.spv", dir, name);
    FILE *f = fopen(p, "rb"); if (!f) { printf("读不了 %s\n", p); exit(2); }
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
// 一个进程的一轮：返回 0；读数打成一行 RES 供父进程比
static int run_phase(const char *exe, const char *pkdir, int phase) {
    char dir[1100]; snprintf(dir, sizeof dir, "%s/t_fbr_in", dirname((char *)exe));
    if (nxgal_init(0)) return 2;
    if (!gal_pso_can_specialize()) { printf("RES skip\n"); nxgal_shutdown(); return 0; }
    nxgal_pso_archive_open_dir(pkdir);
    uint32_t vl; uint8_t *v = load(dir, "vsp", &vl); nxgal_shader sh[1] = {{v, vl, 1}};
    uint32_t P = nxgal_prog_create(sh, 1, NULL, 0, 0xff); free(v);
    for (int i = 0; i < 500 && P && nxgal_prog_status(P, 0) == 2; i++) usleep(10000);
    uint64_t s0 = gal_pso_spec_count(); draw_rg16f_r(P); uint64_t s1 = gal_pso_spec_count();
    gal_pso_dev_flush("单测·后台还在编");
    uint64_t d[6]; for (int i = 0; i < 1000; i++) { gal_pso_dev_stats(d); if (d[4] + d[5] >= d[3]) break; usleep(10000); }
    uint64_t ps[4]; nxgal_pso_cache_stats(ps);
    gal_pso_dev_flush("单测");
    nxgal_shutdown();
    uint64_t e[6]; gal_pso_dev_stats(e);
    char out[1200]; snprintf(out, sizeof out, "%s/rb.%d", pkdir, phase); FILE *f = fopen(out, "wb"); if (f) { fwrite(g_rb, 1, sizeof g_rb, f); fclose(f); }
    printf("RES 现编 %llu 特化 %llu 特化直接取 %llu 命中 %llu 收 %llu 写 %llu 文件 %llu\n", (unsigned long long)ps[1], (unsigned long long)(s1 - s0), (unsigned long long)gal_spec_dev_hits(),
           (unsigned long long)e[0], (unsigned long long)e[4], (unsigned long long)e[1], (unsigned long long)e[2]);
    return 0;
}
static int child(const char *exe, const char *pk, int phase, unsigned long long r[7]) {
    char ph[8]; snprintf(ph, sizeof ph, "%d", phase); char *args[] = {(char *)exe, "--phase", ph, (char *)pk, NULL};
    int fds[2]; pipe(fds); posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa); posix_spawn_file_actions_adddup2(&fa, fds[1], 1); posix_spawn_file_actions_addclose(&fa, fds[0]);
    pid_t pid; if (posix_spawn(&pid, exe, &fa, NULL, args, environ)) return -1; close(fds[1]);
    FILE *f = fdopen(fds[0], "r"); char line[512]; int got = 0;
    while (fgets(line, sizeof line, f)) { if (!strncmp(line, "RES skip", 8)) got = 2;
        else if (sscanf(line, "RES 现编 %llu 特化 %llu 特化直接取 %llu 命中 %llu 收 %llu 写 %llu 文件 %llu", &r[0], &r[1], &r[2], &r[3], &r[4], &r[5], &r[6]) == 7) { got = 1; printf("  %d：%s", phase, line + 4); } }
    fclose(f); int st; waitpid(pid, &st, 0); return WIFEXITED(st) && !WEXITSTATUS(st) ? got : -1;
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGSEGV, segv); signal(SIGBUS, segv);
    if (argc == 4 && !strcmp(argv[1], "--phase")) return run_phase(argv[0], argv[3], atoi(argv[2]));
    char root[] = "/tmp/t_psodev_XXXXXX"; if (!mkdtemp(root)) return 2;
    char pk[1100], devd[1100]; snprintf(pk, sizeof pk, "%s/pkg", root); snprintf(devd, sizeof devd, "%s/dev", root); mkdir(pk, 0755);
    char kp[1200]; snprintf(kp, sizeof kp, "%s/shader_pack.key", pk); FILE *f = fopen(kp, "w"); fputs("t1\n", f); fclose(f);
    setenv("NXGAL_PSO_DEV", "1", 1); setenv("NXGAL_PSO_DEV_DIR", devd, 1);
    const unsigned long long captures = 2;
    unsigned long long a[7] = {0}, b[7] = {0}, c[7] = {0};
    printf("· ① 新目录：现编、特化、后台收完整版、写盘\n");
    int ga = child(argv[0], pk, 1, a); if (ga == 2) { printf("跳过：本机后端没有管线特化（Metal 3）\n"); return 0; }
    CHECK(ga == 1 && a[0] == 1 && a[1] == 1 && a[4] == captures && a[5] >= 2 && a[6] >= 1, "期望 现编 1、特化 1、补录 %llu、写 ≥2 条 ≥1 个文件，实得 现编 %llu 特化 %llu 补录 %llu 写 %llu 文件 %llu（子进程 %d）", captures, a[0], a[1], a[4], a[5], a[6], ga);
    printf("· ② 同包键新进程：全从设备归档取\n");
    int gb = child(argv[0], pk, 2, b);
    CHECK(gb == 1 && b[0] == 0 && b[1] == 0 && b[2] == 1 && b[3] >= 2, "期望 现编 0、特化 0、特化直接取 1、命中 ≥2，实得 现编 %llu 特化 %llu 直接取 %llu 命中 %llu", b[0], b[1], b[2], b[3]);
    { char p1[1200], p2[1200]; snprintf(p1, sizeof p1, "%s/rb.1", pk); snprintf(p2, sizeof p2, "%s/rb.2", pk);
      FILE *x = fopen(p1, "rb"), *y = fopen(p2, "rb"); static uint8_t u[sizeof g_rb], w[sizeof g_rb]; size_t nu = x ? fread(u, 1, sizeof u, x) : 0, nw = y ? fread(w, 1, sizeof w, y) : 0; if (x) fclose(x); if (y) fclose(y);
      CHECK(nu == sizeof u && nw == sizeof w && !memcmp(u, w, sizeof u), "② 出图期望与 ① 逐字节相同（读到 %zu / %zu 字节）", nu, nw); }
    printf("· ③ 换包键：旧条目不用\n");
    f = fopen(kp, "w"); fputs("t2\n", f); fclose(f);
    int gc = child(argv[0], pk, 3, c);
    CHECK(gc == 1 && c[3] == 0 && c[0] == 1, "期望 命中 0、现编 1，实得 命中 %llu 现编 %llu", c[3], c[0]);
    char cmd[1200]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", root); system(cmd);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END

// 写持久缓存卡住时首用不停（gal_prog.m cache_write，10-24 出图停 60 秒以上：现编线程卡在写缓存的 rename()，作业「完成」在写缓存之后，
//   渲染线程等这支作业就跟着停；就地编时写盘还落在等待线程上。原生层线 xc3 / 怪猎 / 巫师3 / 马车8 九局同形）。
// 确定性：新的空着色器持久缓存目录（必须现编）+ nxgal_test_cache_write_hold(1) 让写缓存一直卡着（模拟 rename 不回来）。
// 期望（手算）：
//   B 首用就地编：占住现编槽位（作业排不上后台），阻塞查询把作业拿到本线程就地编，10 秒内返回 0——写盘不留在等待线程上；
//   A 后台线程编：建程序后非阻塞轮询，10 秒内状态 = 0（编好）——写缓存还卡着也算完成；
//   放开写缓存后：两个程序 4 支着色器（vs / fs / vsp / pat 各不同）的 .rec 都写出来，共 4 个——写盘只是挪后、不丢。
// 反证（旧写法：写缓存在置完成之前、就地编时写盘在等待线程上）：B 的阻塞查询不返回、A 一直是 2。本单测用超时判，不会卡死门禁。
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <dirent.h>
#include <libgen.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

GAL_MTL4_ZONE_BEGIN
NXGAL_API void nxgal_test_xc_hold_slots(int on);
NXGAL_API void nxgal_test_cache_write_hold(int on);
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
static char g_dir[1024];
static uint8_t *load(const char *name, uint32_t *len) {
    char p[1200]; snprintf(p, sizeof p, "%s/%s.spv", g_dir, name);
    FILE *f = fopen(p, "rb"); if (!f) { printf("读不了 %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)l); if (fread(b, 1, (size_t)l, f) != (size_t)l) exit(2);
    fclose(f); *len = (uint32_t)l; return b;
}
static uint32_t mk(const char *vs, const char *fs) {
    uint32_t vl, fl; uint8_t *v = load(vs, &vl), *f = load(fs, &fl);
    nxgal_shader sh[2] = {{v, vl, 1}, {f, fl, 5}};
    uint32_t P = nxgal_prog_create(sh, 2, NULL, 0, 0xff); free(v); free(f); return P;
}
static int count_rec(const char *d) {
    DIR *dp = opendir(d); if (!dp) return -1; int n = 0; struct dirent *e;
    while ((e = readdir(dp))) { size_t l = strlen(e->d_name); n += l > 4 && !strcmp(e->d_name + l - 4, ".rec"); }
    closedir(dp); return n;
}
static uint32_t g_bp; static _Atomic int g_bst = -1;
static void *blocking_status(void *a) { (void)a; g_bst = nxgal_prog_status(g_bp, 1); return NULL; }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc; char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_fbr_in", dirname(exe));
    char cd[] = "/tmp/t_xcstall.XXXXXX"; if (!mkdtemp(cd)) return 2; setenv("NXGAL_SHADER_CACHE_DIR", cd, 1);   // 新空缓存：必须现编、要写缓存
    setenv("NXGAL_BOUNDS_COUNT", "0", 1); setenv("NXGAL_FIRST_BOOST", "0", 1);
    if (nxgal_init(0)) return 2;
    nxgal_test_cache_write_hold(1);

    printf("· B 写缓存卡住、首用就地编（占住后台槽位）：阻塞查询 10 秒内期望返回 0\n");
    nxgal_test_xc_hold_slots(1);
    g_bp = mk("vs", "fs");
    pthread_t th; pthread_create(&th, NULL, blocking_status, NULL); pthread_detach(th);
    for (int i = 0; i < 1000 && g_bst < 0; i++) usleep(10000);
    CHECK(g_bp && g_bst == 0, "B 阻塞查询期望 10 秒内返回 0，实得 %d（-1 = 没返回：写盘留在了等待线程上）", (int)g_bst);

    nxgal_test_xc_hold_slots(0);   // 放开槽位，A 走后台线程编

    printf("· A 写缓存卡住、后台线程编：10 秒内状态期望 0\n");
    uint32_t A = mk("vsp", "pat");
    int st = 2; for (int i = 0; i < 1000 && (st = nxgal_prog_status(A, 0)) == 2; i++) usleep(10000);
    CHECK(A && st == 0, "A 期望 10 秒内编好（状态 0），实得 %d（2 = 作业没置完成：写缓存挡住了完成）", st);

    // 放开：卡着的写缓存与排着的作业都走完再关
    nxgal_test_cache_write_hold(0);
    for (int i = 0; i < 1000 && g_bst < 0; i++) usleep(10000);
    int nrec = 0;
    for (int i = 0; i < 500 && (nrec = count_rec(cd)) < 4; i++) usleep(10000);
    usleep(100000); nrec = count_rec(cd);
    CHECK(nrec == 4, "放开后 .rec 期望 4 个（写盘挪后不丢），实得 %d", nrec);
    nxgal_shutdown();
    char rm[256]; snprintf(rm, sizeof rm, "rm -rf '%s'", cd); system(rm);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END

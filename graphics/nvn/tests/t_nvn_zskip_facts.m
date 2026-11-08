// 零源跳过事实载入（zskip_facts_load）：随包 game.tsv 的 zero_skip 键 → 事实表，直接包含生产 nvn_mtl.m 调 zskip_fact_for。期望值按键的写法手写：
//   ① 只有 game.tsv：2bcd0a940ff3f011:4:1:0 → 常量缓冲 4 向量 1 分量 0；0123456789abcdef:-1:-1:-1 → 无系数（-1）；看不懂的一项（junk）报一次红、不进表；表外的键查不到
//   ② DM_NVN_ZSKIP_FACTS=0 盖掉档里的：一个也不载
//   ③ DM_NVN_ZSKIP_FACTS=<另一份>：只载环境变量那份
//   每段在 fork 出的子进程里跑（载入一次就缓存）。反证：改前的 nvn_mtl.m 没有载入（事实表恒空），① 的查表全 FAIL
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static int phase(int n) {
    zskip_fact f;
    if (n == 1) {
        VERIFY(zskip_fact_for("2bcd0a940ff3f011_b", &f) && f.ubo_slot == 4 && f.vec == 1 && f.comp == 0, "① 档里的暗黑2 outline_blur：常量缓冲 4 向量 1 分量 0");
        VERIFY(zskip_fact_for("0123456789abcdef_b", &f) && f.ubo_slot == -1, "① 无系数项：常量缓冲 -1");
        VERIFY(!zskip_fact_for("fedcba9876543210_b", &f), "① 表外的键查不到");
        VERIFY(g_zskip_nf == 2 && g_red_once[49] == 1, "① 共载 2 项、看不懂的一项报红一次（实得 %d 项、红 %d 次）", g_zskip_nf, g_red_once[49]);
    } else if (n == 2) {
        VERIFY(!zskip_fact_for("2bcd0a940ff3f011_b", &f) && g_zskip_nf == 0, "② DM_NVN_ZSKIP_FACTS=0：档里的也不载（实得 %d 项）", g_zskip_nf);
    } else {
        VERIFY(zskip_fact_for("aaaaaaaaaaaaaaaa_b", &f) && f.ubo_slot == 2 && f.vec == 3 && f.comp == 1 && !zskip_fact_for("2bcd0a940ff3f011_b", &f),
               "③ 环境变量那份替换档里的：只有 aaaaaaaaaaaaaaaa（常量缓冲 2 向量 3 分量 1）");
    }
    return failures ? 1 : 0;
}

int main(void) {
    char dir[] = "/tmp/t_zskip_XXXXXX", p[300];
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 2; }
    snprintf(p, sizeof p, "%s/shaders", dir); mkdir(p, 0755); snprintf(p, sizeof p, "%s/shaders/direct", dir); mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/shaders/direct/game.tsv", dir);
    FILE *fp = fopen(p, "w"); if (!fp) { perror(p); return 2; }
    fputs("# 测试档\nzero_skip\t2bcd0a940ff3f011:4:1:0\tjunk\t0123456789abcdef:-1:-1:-1\n", fp); fclose(fp);
    setenv("S2A_GAME_DATA", dir, 1);
    const char *env[] = {NULL, NULL, "0", "aaaaaaaaaaaaaaaa:2:3:1"};
    int bad = 0;
    for (int n = 1; n <= 3; n++) {
        pid_t c = fork();
        if (c == 0) { if (env[n]) setenv("DM_NVN_ZSKIP_FACTS", env[n], 1); else unsetenv("DM_NVN_ZSKIP_FACTS"); @autoreleasepool { _exit(phase(n)); } }
        int st = 0; waitpid(c, &st, 0); if (!WIFEXITED(st) || WEXITSTATUS(st)) bad++;
    }
    snprintf(p, sizeof p, "rm -rf '%s'", dir); system(p);
    if (bad) { printf("✗ t_nvn_zskip_facts：%d 段不过\n", bad); return 1; }
    printf("✓ t_nvn_zskip_facts：3 段全过（档里的 zero_skip 载入、环境变量关 / 替换）\n");
    return 0;
}

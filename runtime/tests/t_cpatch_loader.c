// 自有 NSO → 出包 C 改写器 → 生产 load_modules → fps_start / 热切。
// 模块中 64 个真实可执行双路点均返回 30 / 60；数据原字节均为 11。
// 不构造 module_t，不替换装载、键页、TSD、重定位、改写或 follow 函数。
#include "../src/native.h"
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>

int s2a_cpatch_fps_count(void);
unsigned s2a_unresolved_count(void);
void s2a_fps_start(const char *dir);
void s2a_fps_set_enabled(int on);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { bad++; printf("✗ "); printf(__VA_ARGS__); putchar('\n'); } } while (0)

static uint64_t mask(int mod) { return ((uint64_t *)(g_mod[mod].base + g_mod[mod].key_page_off))[2046]; }
static int probe(int mod, int bit) { return ((int (*)(void))(g_mod[mod].base + 0x100 + bit * 8))(); }
static void state(const char *stage, int test, int on) {
    uint64_t want0 = test == 3 ? (on ? UINT64_MAX : 0) : test == 2 ? 0 : on == 2 ? 1 : (on ? 3 : 0);
    uint64_t want1 = test == 3 && on ? 2 : 0;
    CHECK(mask(0) == want0 && mask(1) == want1, "%s case%d mask=%llx/%llx want=%llx/%llx", stage, test,
          mask(0), mask(1), want0, want1);
    for (int i = 0; i < 64; i++) {
        CHECK(probe(0, i) == ((want0 >> i & 1) ? 60 : 30), "%s case%d main probe%d", stage, test, i);
        CHECK(probe(1, i) == ((want1 >> i & 1) ? 60 : 30), "%s case%d subsdk0 probe%d", stage, test, i);
    }
    for (int i = 0; i < 256; i++) {
        int want = test == 3 && i < 64 && on ? 0x22 :
                   test < 2 && i < 2 && on && (on == 1 || i == 0) ? (i ? 0x33 : 0x22) : 0x11;
        CHECK(g_mod[0].base[0x8000 + i] == want, "%s case%d main data%d=%02x want=%02x", stage, test, i,
              g_mod[0].base[0x8000 + i], want);
        CHECK(g_mod[1].base[0x8000 + i] == 0x11, "%s case%d subsdk0 data%d changed", stage, test, i);
    }
    printf("STATE case%d %s mask=%llx/%llx admitted=%d failures=%d\n", test, stage, mask(0), mask(1), s2a_cpatch_fps_count(), bad);
}
static void row(FILE *f, const char *id, const char *module, const char *bit, const char *data, int on) {
    fprintf(f, "%s\t%s\t%s\t60fps\tself-owned fixture\t0BSD\tmodule.S\t%s\t%d\n", id, module, bit, data, on);
}
static void table(const char *dir, int test) {
    char p[1200]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "w"); if (!f) die("test table fopen");
    fputs("id\tmodule\tbit\tcategory\tname\tlicense\tsource\tdata\tdefault\n", f);
    if (test < 2) {
        row(f, "fps:good-on", "main", "0", "8000:11:22", 1);
        row(f, "fps:good-off", "main", "1", "8001:11:33", 0);
        row(f, "fps:bad-on", "main", "2", "8002:77:44", 1);
        row(f, "fps:bad-off", "main", "3", "8003:77:55", 0);
        row(f, "fps:late-bad", "main", "4", "8004:11:66 8005:77:88", 0);
    } else if (test == 2) {
        row(f, "fps:negative-bit", "main", "-1", "8000:11:22", 1);
        row(f, "fps:high-bit", "main", "64", "8001:11:22", 1);
        row(f, "fps:text-bit", "main", "no", "8002:11:22", 1);
        row(f, "fps:suffix-bit", "main", "3x", "8003:11:22", 0);
        row(f, "fps:bad-hex", "main", "4", "8004:11:1z", 0);
        row(f, "fps:odd-hex", "main", "5", "8005:111:22", 0);
        row(f, "fps:bad-offset", "main", "6", "8006x:11:22", 0);
        row(f, "fps:late-syntax", "main", "7", "8007:11:22 8008:11:2", 0);
        row(f, "fps:bit-overflow", "main", "18446744073709551616", "8009:11:22", 1);
        row(f, "fps:bit-underflow", "main", "-18446744073709551616", "800a:11:22", 1);
    } else {
        for (int i = 0; i < 64; i++) {
            char id[32], bit[16], data[48]; snprintf(id, sizeof id, "fps:capacity%d", i);
            snprintf(bit, sizeof bit, "%d", i); snprintf(data, sizeof data, "%x:11:22", 0x8000 + i);
            row(f, id, "main", bit, data, 0);
        }
        row(f, "fps:overflow", "subsdk0", "0", "8000:11:33", 1);
        row(f, "fps:code-only", "subsdk0", "1", "", 0);
    }
    if (fclose(f)) die("test table fclose");
}
static int run(const char *dir, int test) {
    unsetenv("S2A_FPS"); unsetenv("S2A_FPS_TABLE");
    setenv("S2A_FPS60", test == 1 ? "1" : "0", 1);
    if (test == 1) setenv("S2A_CPATCH_ON", "none", 1); else unsetenv("S2A_CPATCH_ON");
    const char *names[] = {"main", "subsdk0"}; load_modules(dir, names, 2);
    CHECK(g_nmod == 2 && s2a_unresolved_count() == 0, "case%d real module load / relocations", test);
    CHECK(module_sym(&g_mod[0], "fps_probe") == g_mod[0].base + 0x100 &&
          module_sym(&g_mod[0], "patch_data") == g_mod[0].base + 0x8000, "case%d ELF symbols", test);
    state("load", test, test == 0 ? 2 : 0); // 2：只有缺省开项已写入，其余仍保持原值。
    CHECK(s2a_cpatch_fps_count() == (test == 3 ? 65 : test == 2 ? 0 : 2), "case%d admitted count=%d", test, s2a_cpatch_fps_count());
    s2a_fps_start(dir); state(test == 1 ? "start-on" : "start-off", test, test == 1);
    s2a_fps_set_enabled(0); state("off-before-roundtrip", test, 0);
    for (int i = 0; i < 3; i++) {
        s2a_fps_set_enabled(1); state("on", test, 1);
        s2a_fps_set_enabled(0); state("off", test, 0);
    }
    return bad ? 1 : 0;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    for (int test = 0; test < 4; test++) {
        table(argv[1], test); fflush(NULL); pid_t child = fork(); if (child < 0) return 2;
        if (!child) { bad = 0; exit(run(argv[1], test)); }
        int status; if (waitpid(child, &status, 0) != child) return 2;
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "t_cpatch_loader case%d status=%d", test, status);
    }
    // 审计 P2-7：直连模式读 gpu_drivers.tsv（pack/stage_rewrite.sh 每款必写，可为空）。期望按语义手写：
    //   g0 可读、只有注释 → 两个模块都装、退出 0（正对照）；g1 不在 / g2 打不开（自环软链 ELOOP，root 下也打不开）/ g3 读不了（目录，fopen 成功、读 EISDIR）
    //   → 起局中止、退出非 0、标准错误点名 gpu_drivers.tsv。旧代码打不开当「没有驱动模块」照装、退出 0
    table(argv[1], 0);
    char gp[1200], lp[1200], cmd[2600]; snprintf(gp, sizeof gp, "%s/gpu_drivers.tsv", argv[1]); snprintf(lp, sizeof lp, "%s/gpu_drivers.err", argv[1]);
    for (int g = 0; g < 4; g++) {
        snprintf(cmd, sizeof cmd, "rm -rf '%s'", gp); if (system(cmd)) return 2;
        if (g == 0) { FILE *f = fopen(gp, "w"); if (!f || fputs("# 无 GPU 驱动模块\n", f) < 0 || fclose(f)) return 2; }
        if (g == 2 && symlink("gpu_drivers.tsv", gp)) return 2;
        if (g == 3 && mkdir(gp, 0755)) return 2;
        fflush(NULL); pid_t child = fork(); if (child < 0) return 2;
        if (!child) {
            int lf = open(lp, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (lf < 0 || dup2(lf, g_s2a_logfd) < 0 || dup2(lf, 2) < 0) _exit(3);   // 日志 fd 是 os.c 构造时 dup 出的，单换 stderr 不够
            setenv("S2A_GFX", "direct", 1); unsetenv("S2A_FPS60"); unsetenv("S2A_CPATCH_ON");
            const char *names[] = {"main", "subsdk0"}; load_modules(argv[1], names, 2);
            _exit(g_nmod == 2 ? 0 : 4);
        }
        int status; if (waitpid(child, &status, 0) != child) return 2;
        snprintf(cmd, sizeof cmd, "grep -aq 'gpu_drivers.tsv' '%s'", lp); int named = !system(cmd);
        if (g == 0) CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "gpu_drivers g0 可读：期望装两个模块、退出 0 → status=%d", status);
        else CHECK(!(WIFEXITED(status) && WEXITSTATUS(status) == 0) && named, "gpu_drivers g%d（%s）：期望中止、点名 gpu_drivers.tsv → status=%d 点名=%d", g,
                   g == 1 ? "不在" : g == 2 ? "打不开" : "读不了", status, named);
    }
    snprintf(cmd, sizeof cmd, "rm -rf '%s' '%s'", gp, lp); if (system(cmd)) return 2;
    if (bad) { printf("✗ t_cpatch_loader：%d 处不符\n", bad); return 1; }
    puts("✓ t_cpatch_loader：4 场景（自有真实模块装载、128 双路点、拒绝项/缺省关/非法项/64 数据项容量、启动与三次热切）+ 直连 gpu_drivers.tsv 4 场景（可读 / 不在 / 打不开 / 读不了）");
    return 0;
}

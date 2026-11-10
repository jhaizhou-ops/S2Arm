// 审计 P1-139：构造期（占窗口、判客体内存文件后备开不开）要按本款程序号读实测峰值，那时图形模式还没落定。
//   原先 mem_peak_path 经 s2a_npdm_program_id → s2a_gfx_mode 取号：iOS 未放行恒 0、Mac 把模式和号 0 落定 → 峰值 / 死亡标记都读不到。
// 期望（手写，不跑被测实现）：子进程按 Mac 宿主的样子起（argv[1] = 模块目录，里面 main.npdm 的程序号由本测的 s2a_npdm_pid 给 0400486024DEC000），
//   <S2A_DOCS>/wire/0400486024DEC000/mem_peak 写 1234 MB → 构造期文件后备那行报「本机本款实测峰值 1234 MB」；
//   构造期一次也不调 s2a_npdm_program_id（main 之前调用计数 0）。反证：同一子进程里 main.npdm 改成别的号 → 峰值 0（没读到别款的）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
static int g_in_main, g_pid_calls_before_main;
// 被 vawin.c 按名字取（dlsym）的几个：只给本测要的答案
uint64_t s2a_npdm_program_id(void) { if (!g_in_main) g_pid_calls_before_main++; return 0; }
uint64_t s2a_npdm_pid(const char *npdm) { const char *w = getenv("T_PID"); (void)npdm; return w ? strtoull(w, NULL, 16) : 0; }
uint64_t s2a_npdm_window_need(const char *npdm) { (void)npdm; return 63488ull << 20; }
uint64_t s2a_app_pool(void) { return 0x240000000ull; }   // Switch 2 池 9 GiB
static int child(const char *pidhex, const char *log, const char *docs, const char *dir) {
    pid_t p = fork();
    if (!p) { setenv("T_PID", pidhex, 1); setenv("S2A_DOCS", docs, 1); setenv("S2A_IPHONE_VA", "0", 1); unsetenv("S2A_GUEST_FILE"); unsetenv("S2A_WIN_NEED_MB"); unsetenv("S2A_GUEST_MEM_PEAK");
        freopen(log, "w", stderr); freopen(log, "a", stdout); char self[1024]; snprintf(self, sizeof self, "%s", getenv("T_SELF")); execl(self, self, dir, (char *)NULL); _exit(127); }
    int st = 0; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
static int has(const char *log, const char *s) { FILE *f = fopen(log, "r"); if (!f) return 0; char b[4096]; int ok = 0; while (fgets(b, sizeof b, f)) if (strstr(b, s)) ok = 1; fclose(f); return ok; }
int main(int argc, char **argv) {
    g_in_main = 1;
    if (argc >= 2) { printf("before-main program_id calls %d\n", g_pid_calls_before_main); return 0; }   // 子进程：构造函数已跑完，报计数
    int bad = 0; char t[] = "/tmp/t_gfpid.XXXXXX"; if (!mkdtemp(t)) return 1;
    char docs[256], dir[256], peak[400], log1[300], log2[300], self[1024];
    snprintf(docs, sizeof docs, "%s/docs", t); snprintf(dir, sizeof dir, "%s/mod", t); mkdir(docs, 0755); mkdir(dir, 0755);
    snprintf(peak, sizeof peak, "%s/wire", docs); mkdir(peak, 0755); snprintf(peak, sizeof peak, "%s/wire/0400486024DEC000", docs); mkdir(peak, 0755);
    strcat(peak, "/mem_peak"); FILE *f = fopen(peak, "w"); fprintf(f, "%llu\n", 1234ull << 20); fclose(f);
    if (argv[0][0] == '/') snprintf(self, sizeof self, "%s", argv[0]); else { char cwd[512]; getcwd(cwd, sizeof cwd); snprintf(self, sizeof self, "%s/%s", cwd, argv[0]); }
    setenv("T_SELF", self, 1);
    snprintf(log1, sizeof log1, "%s/a.log", t); snprintf(log2, sizeof log2, "%s/b.log", t);
    int r1 = child("0400486024DEC000", log1, docs, dir), r2 = child("0100000000010000", log2, docs, dir);
#define CHECK(c, m) do { if (c) printf("✓ %s\n", m); else { printf("✗ %s\n", m); bad++; } } while (0)
    CHECK(r1 == 0 && r2 == 0, "两个子进程正常退出");
    CHECK(has(log1, "本机本款实测峰值 1234 MB"), "构造期按 main.npdm 的程序号读到本款实测峰值 1234 MB");
    CHECK(has(log1, "before-main program_id calls 0"), "构造期没调 s2a_npdm_program_id（不经 s2a_gfx_mode 落定模式）");
    CHECK(has(log2, "本机本款实测峰值 0 MB"), "反证：程序号换成别款 → 没读到这份峰值（0）");
    if (bad) { printf("--- a.log\n"); char c[600]; snprintf(c, sizeof c, "grep -a '文件后备\\|before-main' %s %s", log1, log2); system(c); }
    printf("%s t_guest_file_pid：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}

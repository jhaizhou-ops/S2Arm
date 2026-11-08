// t_nrodefer：romfs NRO 导出表（nrodefer.c）——表里的符号判「延迟到 nn::ro 装载」，表外的照旧报红（反例），没有表时全部照旧。期望手写
#include "../src/native.h"
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
void s2a_nro_table_load(const char *dir); const char *s2a_nro_defer_lookup(const char *name);
// 分配失败注入（审计 #814 F-nro-oom-null）：本可执行文件自带 strdup，nrodefer.c 的调用解析到这里；g_fail_at > 0 时第 g_fail_at 次回 NULL
static int g_dup_n, g_fail_at;
char *strdup(const char *s) {
    if (g_fail_at && ++g_dup_n == g_fail_at) return NULL;
    size_t n = strlen(s) + 1; char *d = malloc(n); if (d) memcpy(d, s, n); return d;
}
// 子进程里装表：回「信号 N」或「退出 N」，日志收进 out
static void load_child(const char *dir, int fail_at, char *res, size_t rn, char *out, size_t on) {
    int pp[2]; pipe(pp); fflush(stdout); pid_t c = fork();
    if (c == 0) { dup2(pp[1], 2); dup2(pp[1], 1); close(pp[0]); g_dup_n = 0; g_fail_at = fail_at; s2a_nro_table_load(dir); _exit(0); }
    close(pp[1]); size_t n = 0; ssize_t r; while (n < on - 1 && (r = read(pp[0], out + n, on - 1 - n)) > 0) n += (size_t)r; out[n] = 0; close(pp[0]);
    int st; waitpid(c, &st, 0);
    if (WIFSIGNALED(st)) snprintf(res, rn, "信号 %d", WTERMSIG(st)); else snprintf(res, rn, "退出 %d", WEXITSTATUS(st));
}
int main(void) {
    int bad = 0;
    if (s2a_nro_defer_lookup("EOS_Platform_Create")) { printf("✗ 还没读表就命中\n"); bad++; }
    char d[] = "/tmp/t_nrodefer_XXXXXX"; if (!mkdtemp(d)) { printf("✗ mkdtemp\n"); return 1; }
    s2a_nro_table_load(d);   // 目录里没有表：照旧
    if (s2a_nro_defer_lookup("EOS_Platform_Create")) { printf("✗ 没有表时不应命中\n"); bad++; }
    char p[256]; snprintf(p, sizeof p, "%s/nro_exports.tsv", d); FILE *f = fopen(p, "w");
    fprintf(f, "# 注释行\nEOS_Platform_Create\tEOSSDK-Switch-Shipping.nro\nEOS_Shutdown\tEOSSDK-Switch-Shipping.nro\nfoo_bar\tother.nro\n"); fclose(f);
    s2a_nro_table_load(d);
    const char *a = s2a_nro_defer_lookup("EOS_Platform_Create"), *b = s2a_nro_defer_lookup("foo_bar");
    if (!a || strcmp(a, "EOSSDK-Switch-Shipping.nro")) { printf("✗ EOS_Platform_Create 应命中 EOSSDK-Switch-Shipping.nro，得 %s\n", a ? a : "NULL"); bad++; }
    if (!b || strcmp(b, "other.nro")) { printf("✗ foo_bar 应命中 other.nro，得 %s\n", b ? b : "NULL"); bad++; }
    if (s2a_nro_defer_lookup("EOS_NotInTable")) { printf("✗ 反例：表外的 EOS_NotInTable 不应命中（应照旧报红）\n"); bad++; }
    if (s2a_nro_defer_lookup("EOS_Platform")) { printf("✗ 反例：前缀相同的 EOS_Platform 不应命中\n"); bad++; }
    if (s2a_nro_defer_lookup("# 注释行")) { printf("✗ 注释行不应进表\n"); bad++; }
    // 复制名字 / 文件名失败（第 1 次 = 首行名字、第 4 次 = 第二行文件名）：期望 die（中止、打 FATAL），不排序空名字、不报「N 个符号」
    for (int k = 1; k <= 4; k += 3) {
        char res[32], out[4096]; load_child(d, k, res, sizeof res, out, sizeof out);
        int ok = !strcmp(res, "信号 6") && strstr(out, "FATAL") && !strstr(out, "个符号（");
        if (!ok) { printf("✗ 第 %d 次复制失败：期望 信号 6（abort）、打 FATAL、不报「导出表：N 个符号」→ 实得 %s、%s、%s\n", k, res, strstr(out, "FATAL") ? "有 FATAL" : "没有 FATAL", strstr(out, "个符号（") ? "报了导出表" : "没报导出表"); bad++; }
    }
    unlink(p); rmdir(d);
    printf("%s t_nrodefer：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}

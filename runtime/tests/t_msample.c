// t_msample：malloc 按调用点采样（msample.c，S2A_MALLOC_SAMPLE=1）——在用估值对 / 释放后归零 / realloc 按新大小 / 大块按跨格数加权
//   期望值手算：每 64 KB 抽一次，4000 × 16 KB 留着 = 62.5 MB；同样 4000 × 16 KB 申请即释放 = 0；1 MB realloc 到 8 MB 留着 = 8 MB
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
void s2a_msample_note(const char *when);
__attribute__((constructor(101))) static void on(void) { setenv("S2A_MALLOC_SAMPLE", "1", 1); }   // 先于 msample.c 的构造函数（200）
__attribute__((noinline)) static void *hot(size_t n) { void *p = malloc(n); __asm__ volatile("" ::: "memory"); return p; }
__attribute__((noinline)) static void *cold(size_t n) { void *p = malloc(n); __asm__ volatile("" ::: "memory"); return p; }
int main(void) {
    static void *keep[4000]; for (int i = 0; i < 4000; i++) keep[i] = hot(16384);
    for (int i = 0; i < 4000; i++) free(cold(16384));
    void *r = realloc(hot(1 << 20), 8 << 20);
    char path[] = "/tmp/t_msample_XXXXXX"; int fd = mkstemp(path); fflush(stderr); int sv = dup(2); dup2(fd, 2);
    s2a_msample_note("单测"); fflush(stderr); dup2(sv, 2); close(sv);
    FILE *f = fopen(path, "r"); char line[2048], all[16384] = ""; while (f && fgets(line, sizeof line, f)) strncat(all, line, sizeof all - strlen(all) - 1); if (f) fclose(f); unlink(path);
    fputs(all, stdout);
    int bad = 0; const char *p = strstr(all, "估在用 ");
    double tot = p ? atof(p + strlen("估在用 ")) : -1;
    if (tot < 70.4 || tot > 70.6) { printf("✗ 估在用合计应 70.5 MB（62.5 留着 + 0 已释放 + 8 realloc），得 %.1f\n", tot); bad++; }
    if (!strstr(all, "估在用 62.5 MB")) { printf("✗ 留着的调用点应估 62.5 MB\n"); bad++; }
    if (!strstr(all, "估在用 8.0 MB（抽中 1 次，其中 ≥128 KB 1 次）")) { printf("✗ realloc 到 8 MB 应按新大小加权 8.0 MB\n"); bad++; }
    (void)keep; (void)r;
    printf("%s t_msample：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}

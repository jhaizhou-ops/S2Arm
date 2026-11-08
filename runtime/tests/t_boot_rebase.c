// t_boot_rebase：起局计时起点改到「点 Play」（11-07 启动器线：多款容器停在游戏库的时间不算起局，runtime/src/boot.c s2a_boot_rebase）。
// 期望（不跑被测实现手算）：进程起来后先睡 300 ms 再打一个点 → 「+」≥ 300；改起点后立刻打点 → 「+」与「本段」都 < 100（改起点那刻到这里只隔一次函数调用）；
//   改起点那行自己报「距进程创建」≥ 300。单款包不调 s2a_boot_rebase：未改起点前的打点照旧从进程创建算（第一项）。
#include "../src/native.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
void s2a_boot_mark(const char *stage);
void s2a_boot_rebase(const char *why);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } } while (0)
static double num_after(const char *s, const char *key) { const char *p = strstr(s, key); return p ? atof(p + strlen(key)) : -1; }
int main(void) {
    char path[] = "/tmp/s2a_t_boot_rebase_XXXXXX"; int fd = mkstemp(path); if (fd < 0) return 1;
    int keep = g_s2a_logfd; g_s2a_logfd = fd;
    usleep(300000);
    s2a_boot_mark("改起点前");
    s2a_boot_rebase("点 Play");
    s2a_boot_mark("改起点后");
    g_s2a_logfd = keep;
    char buf[4096] = {0}; lseek(fd, 0, SEEK_SET); ssize_t n = read(fd, buf, sizeof buf - 1); close(fd); unlink(path); if (n <= 0) return 1;
    char *l1 = buf, *l2 = strchr(l1, '\n'); if (!l2) return 1; *l2++ = 0; char *l3 = strchr(l2, '\n'); if (!l3) return 1; *l3++ = 0;
    double a = num_after(l1, "改起点前 +"), r = num_after(l2, "距进程创建 "), b = num_after(l3, "改起点后 +"), bs = num_after(l3, "本段 ");
    CHECK(a >= 300, "改起点前从进程创建算：期望 ≥ 300 ms，得 %.1f（%s）", a, l1);
    CHECK(strstr(l2, "计时起点改为点 Play") && r >= 300, "改起点那行：期望写明点 Play、距进程创建 ≥ 300 ms，得 %.1f（%s）", r, l2);
    CHECK(b >= 0 && b < 100 && bs >= 0 && bs < 100, "改起点后：期望「+」与本段都 < 100 ms，得 +%.1f 本段 %.1f（%s）", b, bs, l3);
    if (bad) { printf("✗ t_boot_rebase：%d 项红\n", bad); return 1; }
    printf("✓ t_boot_rebase：3 条断言全过——改起点前照旧从进程创建算、改起点那行写明点 Play 与库界面停留、改起点后各段从点 Play 算\n");
    return 0;
}

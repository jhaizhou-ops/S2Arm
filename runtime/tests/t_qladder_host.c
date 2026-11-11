// 档位梯子起局单测（#352，runtime/src/qladder_host.c s2a_ql_boot）：玩家选的运行模式（起局时环境里的 S2A_DOCKED）是上限。
//   期望手算：上限掌机 → 一律掌机；上限主机 → 没记过 / 记的是主机档 = 主机，记的是掌机档 = 掌机；没设（Mac 没选过）= 按主机。
//   原先首次一律从主机起，iPhone 缺省掌机被盖成主机（宽屏按主机表装，三个模块启用 0 个点）。
#include "native.h"
#include "s2a_qladder.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
int s2a_fps_real_source(void) { return 0; } int s2a_fps_enabled(void) { return 0; } void s2a_fps_hold(int hold) { (void)hold; }
int s2a_widen_game(void) { return 1; } void s2a_console_mode_set(int docked) { (void)docked; } int s2a_console_mode(void) { return -1; }
void s2a_ios_fps_capped(int reason) { (void)reason; }
void s2a_ql_boot(void); void s2a_ql_host_frame(uint64_t now, int game, uint64_t dt, int game_itv);
static int bad;
// 一种情况一个子进程（梯子开关、记下的档都是进程内静态）：env 里 S2A_DOCKED（NULL = 没设）、ladder.txt 内容（NULL = 没有）→ 起局后的 S2A_DOCKED 与第一帧的档
static void one(const char *why, const char *env, const char *ladder, const char *want, int want_tier) {
    char dir[] = "/tmp/t_qladder_host.XXXXXX"; if (!mkdtemp(dir)) { printf("✗ 建临时目录失败\n"); bad++; return; }
    char p[600]; snprintf(p, sizeof p, "%s/ladder.txt", dir);
    if (ladder) { FILE *f = fopen(p, "w"); fputs(ladder, f); fclose(f); } else unlink(p);
    int fd[2]; if (pipe(fd)) { bad++; return; }
    pid_t pid = fork();
    if (!pid) { close(fd[0]); setenv("S2A_DOCS", dir, 1); unsetenv("S2A_AUTOPLAY"); unsetenv("S2A_LADDER");
        if (env) setenv("S2A_DOCKED", env, 1); else unsetenv("S2A_DOCKED");
        s2a_ql_boot(); s2a_ql_host_frame(1000000000ull, 0, 16666667ull, 1);
        const char *d = getenv("S2A_DOCKED"); char out[16]; snprintf(out, sizeof out, "%s %d", d ? d : "-", s2a_ql_tier());
        write(fd[1], out, strlen(out)); _exit(0); }
    close(fd[1]); char got[16] = {0}; read(fd[0], got, sizeof got - 1); close(fd[0]); waitpid(pid, 0, 0);
    unlink(p); rmdir(dir);
    char exp[16]; snprintf(exp, sizeof exp, "%s %d", want, want_tier);
    int ok = !strcmp(got, exp); bad += !ok;
    printf("%s %s：期望 S2A_DOCKED 档位 %s → 实 %s\n", ok ? "✓" : "✗", why, exp, got);
}
int main(void) {
    one("iPhone 首次（设置缺省掌机）", "0", NULL, "0", 1);
    one("玩家开了主机、首次", "1", NULL, "1", 0);
    one("Mac 没选过（不设）、首次", NULL, NULL, "1", 0);
    one("上限主机、记下的是掌机档", "1", "kind=2 tier=1\n", "0", 1);
    one("上限掌机、旧版记下的是主机档（#352 受影响的机器）", "0", "kind=2 tier=0\n", "0", 1);
    printf("%s t_qladder_host：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}

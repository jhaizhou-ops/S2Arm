// 宿主自拿 Mac 局槽单测（mac_slot_hold.c + 真 tools/mac_slot.sh hold 模式，临时槽目录，不碰运行区；约 5 秒）。
// 期望（按规则手写，不看实现）：
//   ① 调用方已拿着槽（S2A_MAC_SLOT_HELD=1）→ 不调仲裁脚本（假脚本被调会留标记）
//   ② 不是我方机器（运行区没有 s2arm/env/layout.env、没给 S2A_MAC_SLOT_BIN）→ 不拿槽，照常往下
//   ③ 有空槽 → 拿到 0 号，holder 记的是宿主自己的 pid 和「s2arm-host <名>」；宿主正常退出后槽目录没了
//   ④ 唯一的槽被活进程占着、排队上限 1 秒 → 宿主退 75、不往下走；别人的槽原样不动
//   ⑤ 唯一的槽的持有者已死 → 收回，宿主拿到
#include "../src/native.h"
#include <TargetConditionals.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
void s2a_mac_slot_hold(const char *what);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } else { printf("✓ " __VA_ARGS__); printf("\n"); } } while (0)
static char T[512], SLOT[600], MS[1024];
static int slurp(const char *p, char *b, size_t n) { FILE *f = fopen(p, "r"); if (!f) return -1; size_t k = fread(b, 1, n - 1, f); b[k] = 0; fclose(f); return (int)k; }
// 子进程：设好环境 → s2a_mac_slot_hold → 写「过了」标记（带自己的 pid 和当时 holder 内容）→ 正常退出（atexit 放槽）
static int child(const char *held, int ours, const char *wait_s, pid_t *cpid) {
    pid_t c = fork();
    if (!c) {
        setenv("S2A_MAC_SLOT_DIR", SLOT, 1); setenv("S2A_MAC_SLOTS", "1", 1); setenv("S2A_MAC_SLOT_SIMS", "0", 1); setenv("S2A_MAC_SLOT_POLL_S", "0.1", 1);
        setenv("S2A_MAC_SLOT_WAIT_S", wait_s, 1); setenv("S2A_MAC_CEN_YIELD_S", "0", 1);
        if (held) setenv("S2A_MAC_SLOT_HELD", held, 1); else unsetenv("S2A_MAC_SLOT_HELD");
        char rr[600]; snprintf(rr, sizeof rr, "%s/run", T); setenv("S2A_RUN_ROOT", rr, 1);
        if (ours) setenv("S2A_MAC_SLOT_BIN", MS, 1); else unsetenv("S2A_MAC_SLOT_BIN");
        s2a_mac_slot_hold("单测款");
        char p[700], h[800] = ""; snprintf(p, sizeof p, "%s/0/holder", SLOT); slurp(p, h, sizeof h);
        snprintf(p, sizeof p, "%s/passed", T); FILE *f = fopen(p, "w"); if (f) { fprintf(f, "%d|%s", (int)getpid(), h); fclose(f); }
        exit(0);
    }
    *cpid = c; int st = 0; waitpid(c, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);   // fork 前不留缓冲，免得子进程再打一遍
#if TARGET_OS_OSX
    snprintf(T, sizeof T, "/tmp/t_mac_slot_hold.%d", (int)getpid()); mkdir(T, 0755);
    snprintf(SLOT, sizeof SLOT, "%s/slot", T); char cwd[512]; if (!getcwd(cwd, sizeof cwd)) return 1;
    snprintf(MS, sizeof MS, "%s/tools/mac_slot.sh", cwd);
    char p[800], b[1200]; pid_t c; int rc;
    // ① 已拿着槽：仲裁换成假脚本，被调就留标记
    char fake[700]; snprintf(fake, sizeof fake, "%s/fake.sh", T); FILE *f = fopen(fake, "w"); fprintf(f, "touch %s/fake_called; echo /x\n", T); fclose(f);
    { char ms_keep[1024]; strcpy(ms_keep, MS); strcpy(MS, fake);
      rc = child("1", 1, "1", &c); snprintf(p, sizeof p, "%s/fake_called", T);
      CHECK(rc == 0 && access(p, F_OK) != 0, "① S2A_MAC_SLOT_HELD=1：照常往下（rc=%d）、没调仲裁脚本", rc); strcpy(MS, ms_keep); }
    // ② 不是我方机器：运行区没有 layout.env、没给 S2A_MAC_SLOT_BIN
    snprintf(p, sizeof p, "%s/passed", T); unlink(p);
    rc = child(NULL, 0, "1", &c); b[0] = 0; slurp(p, b, sizeof b);
    snprintf(p, sizeof p, "%s/0", SLOT);
    CHECK(rc == 0 && b[0] && access(p, F_OK) != 0, "② 单机：照常往下（rc=%d）、没建槽", rc);
    // ③ 有空槽
    snprintf(p, sizeof p, "%s/passed", T); unlink(p);
    rc = child(NULL, 1, "5", &c); b[0] = 0; slurp(p, b, sizeof b);
    char want[200]; snprintf(want, sizeof want, "%d|%d s2arm-host 单测款 ", (int)c, (int)c);
    snprintf(p, sizeof p, "%s/0", SLOT);
    CHECK(rc == 0 && !strncmp(b, want, strlen(want)) && access(p, F_OK) != 0, "③ 拿到 0 号、holder 记宿主 pid 和名字（实得「%s」）、退出后槽没了（rc=%d）", b, rc);
    // ④ 槽被活进程（本测试进程）占着、排队上限 1 秒
    mkdir(SLOT, 0755); mkdir(p, 0755); snprintf(p, sizeof p, "%s/0/holder", SLOT); f = fopen(p, "w"); fprintf(f, "%d 别人的局 11-07 00:00:00\n", (int)getpid()); fclose(f);
    snprintf(p, sizeof p, "%s/passed", T); unlink(p);
    rc = child(NULL, 1, "1", &c);
    snprintf(p, sizeof p, "%s/0/holder", SLOT); b[0] = 0; slurp(p, b, sizeof b); char p2[700]; snprintf(p2, sizeof p2, "%s/passed", T);
    CHECK(rc == 75 && access(p2, F_OK) != 0 && strstr(b, "别人的局"), "④ 满了排到上限：退 %d（75）、没往下走、别人的槽原样", rc);
    // ⑤ 持有者已死
    f = fopen(p, "w"); fprintf(f, "999999 死局 11-07 00:00:00\n"); fclose(f);
    rc = child(NULL, 1, "5", &c); b[0] = 0; slurp(p2, b, sizeof b); snprintf(want, sizeof want, "%d|%d s2arm-host", (int)c, (int)c);
    CHECK(rc == 0 && !strncmp(b, want, strlen(want)), "⑤ 死持有者的槽被收回、宿主拿到（实得「%s」）", b);
    char cmd[700]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", T); if (system(cmd)) {}
#else
    printf("✓ 非 macOS：宿主不拿 Mac 局槽，跳过\n");
#endif
    if (bad) printf("✗ t_mac_slot_hold：%d 处不符\n", bad); else printf("✓ t_mac_slot_hold：0 处不符（共 5 项）\n");   // runtime/gate.sh 按「✓ / ✗ t_」行判组
    return bad ? 1 : 0;
}

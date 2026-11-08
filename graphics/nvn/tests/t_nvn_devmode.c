// 窗口原点 / 深度模式是每个 NVN 设备自己的状态（11-03 弹丸论破V3 界面层上下颠倒）：
//   主设备设左上 + near=0 之后，游戏又初始化第二个设备（只带 NVN 缺省：左下、near=-w，不设模式）。旧代码 DeviceInitialize 直接改后端全局，
//   主设备此后的绘制按左下翻视口、上屏再翻 → 渲染目标当纹理再合成的界面层颠倒。
// 期望值只按 NVN 语义写死（模式属于设备；后端跟提交 / 上屏的队列所属设备），不跑被测实现：
//   ① 初始化 A → 后端 左下 / near=-w（第一个设备，NVN 缺省）
//   ② A 设左上、near=0 → 后端 左上 / near=0
//   ③ 初始化 B（不设模式）→ 后端仍 左上 / near=0（旧代码：左下 / near=-w）
//   ④ A 的队列提交 → 左上 / near=0（旧代码：左下）
//   ⑤ B 的队列提交 → 左下 / near=-w（B 自己的缺省）
//   ⑥ A 的队列再提交 → 左上 / near=0（旧代码：左下）
//   ⑦ A 当前时 B 设左上 → 后端不变（仍是 A 的），B 读回左上；B 提交 → 左上 / near=-w
//   ⑧ 结束 A、B，再初始化 C → C 成为当前：左下 / near=-w
// 后端状态的读法：nvn_mtl.m 每次真变化打一行「[nvn-mtl] window origin: …」/「depth mode: …」（g_origin_ll / g_depth_zero 交换时），取最后一行即后端当前值；
//   另核安卓直连读的 s2a_nvn_window_origin_mode / s2a_nvn_depth_mode 与之一致。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int s2a_nvn_window_origin_mode, s2a_nvn_depth_mode;
static int bad, checks;
static char logpath[] = "/tmp/t_nvn_devmode.XXXXXX";
static int saved_err = -1;
static void *load(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stdout, "找不到公开 API：%s\n", n); exit(1); } return p; }
#define API(name) ((NVNT_##name)load(#name))

// 后端日志里最后一行的取值：1 = 左下 / near=-w，0 = 左上 / near=0；没打过 = 后端初值（nvn_mtl.m 的 g_origin_ll = 0 左上、g_depth_zero = 0 即 near=-w，只在变化时打行）
static void backend_state(int *ll, int *gl) {
    fflush(stderr);
    FILE *f = fopen(logpath, "r"); char line[512]; *ll = 0; *gl = 1;
    while (f && fgets(line, sizeof line, f)) {
        const char *p;
        if ((p = strstr(line, "[nvn-mtl] window origin: "))) *ll = !strncmp(p + 25, "lower left", 10);
        if ((p = strstr(line, "[nvn-mtl] depth mode: "))) *gl = !strncmp(p + 22, "near=-w", 7);
    }
    if (f) fclose(f);
}
static void expect(const char *step, int want_ll, int want_gl) {
    int ll, gl; backend_state(&ll, &gl); checks++;
    int ok = ll == want_ll && gl == want_gl && s2a_nvn_window_origin_mode == (want_ll ? 0 : 1) && s2a_nvn_depth_mode == (want_gl ? 0 : 1);
    if (!ok) { bad++; dprintf(saved_err, "✗ %s：期望 %s / %s，后端 %s / %s，s2a_nvn origin=%d depth=%d\n", step, want_ll ? "左下" : "左上", want_gl ? "near=-w" : "near=0",
                              ll ? "左下" : "左上", gl ? "near=-w" : "near=0", s2a_nvn_window_origin_mode, s2a_nvn_depth_mode); }
}

static void make_queue(NVNqueue *q, NVNdevice *d) {
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, d);
    if (!API(nvnQueueInitialize)(q, &qb)) { dprintf(saved_err, "QueueInitialize 失败\n"); exit(1); }
}
static void submit(NVNqueue *q) { API(nvnQueueSubmitCommands)(q, 0, NULL); }

int main(void) {
    int fd = mkstemp(logpath); if (fd < 0) { perror("mkstemp"); return 1; }
    saved_err = dup(2); dup2(fd, 2); close(fd);

    static NVNdevice a, b, c; static NVNqueue qa, qb;
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db);

    API(nvnDeviceInitialize)(&a, &db);                      expect("① 初始化 A", 1, 1);
    API(nvnDeviceSetWindowOriginMode)(&a, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT);
    API(nvnDeviceSetDepthMode)(&a, NVN_DEPTH_MODE_NEAR_IS_ZERO); expect("② A 设左上 / near=0", 0, 0);
    make_queue(&qa, &a);
    API(nvnDeviceInitialize)(&b, &db);                      expect("③ 初始化第二个设备 B", 0, 0);
    make_queue(&qb, &b);
    submit(&qa);                                            expect("④ A 的队列提交", 0, 0);
    submit(&qb);                                            expect("⑤ B 的队列提交", 1, 1);
    submit(&qa);                                            expect("⑥ A 的队列再提交", 0, 0);
    API(nvnDeviceSetWindowOriginMode)(&b, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT); expect("⑦ A 当前时 B 设左上", 0, 0);
    checks++; if (API(nvnDeviceGetWindowOriginMode)(&b) != NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT) { bad++; dprintf(saved_err, "✗ ⑦ B 读回不是左上\n"); }
    submit(&qb);                                            expect("⑦ B 提交（左上 / near=-w）", 0, 1);
    API(nvnDeviceFinalize)(&a); API(nvnDeviceFinalize)(&b);
    API(nvnDeviceInitialize)(&c, &db);                      expect("⑧ 结束 A、B 后初始化 C", 1, 1);

    fflush(stderr); dup2(saved_err, 2); unlink(logpath);
    printf("%s t_nvn_devmode：窗口原点 / 深度模式按设备、后端跟提交队列的设备（%d 项）→ %s\n", bad ? "✗" : "✓", checks, bad ? "有不符合项" : "通过");
    return bad ? 1 : 0;
}

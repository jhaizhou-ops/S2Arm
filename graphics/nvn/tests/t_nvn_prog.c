// Program 三项不建模特性的对外行为（#270 N12）：不支持就明说，不返回成功兜底。
//   · SetSubroutineLinkage → 返回 0（失败）并点名一次，不假装链接成功；
//   · SetSampleShading → 可调用、不崩（只记一行，行为仍按每像素一次）；
//   · GetSubtileSize → 报 0（本层不用 tiled 存储）。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; } return p; }
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)

int main(void) {
    NVNT_nvnProgramSetSubroutineLinkage link = (NVNT_nvnProgramSetSubroutineLinkage)api("nvnProgramSetSubroutineLinkage");
    void (*samp)(NVNprogram *, float) = (void (*)(NVNprogram *, float))api("nvnProgramSetSampleShading");
    int (*subtile)(const NVNprogram *) = (int (*)(const NVNprogram *))api("nvnProgramGetSubtileSize");
    if (bad) return 1;

    union { NVNprogram p; char raw[256]; } prog;
    memset(&prog, 0, sizeof prog);

    // ① 子程序链接：必须显式失败（0），不能返回成功
    CHECK(link(&prog.p, 0, NULL) == 0, "SetSubroutineLinkage 应返回 0（不支持），实得非 0");

    // ② 逐样本着色：可调用、不崩
    samp(&prog.p, 4.0f);
    samp(&prog.p, 8.0f);

    // ③ 子块尺寸：本层不用 tiled 存储 → 0
    CHECK(subtile(&prog.p) == 0, "GetSubtileSize 应报 0，实得 %d", subtile(&prog.p));

    printf("%s t_nvn_prog：子程序链接显式失败、逐样本着色不崩、子块尺寸报 0 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}

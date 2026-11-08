// 窗口纹理计数（#270 N12 Window 组）：nvnWindowGetNumTextures / GetNumActiveTextures
// NVN 语义：前者 = SetTextures 给的个数；后者 = SetNumActiveTextures 生效后被轮换的个数，没设过就等于前者，
// 且被夹到 [0, 纹理数]（多出来的没有交换链映像）。本测走生产 bootstrap、不初始化 GPU（纹理数用 0 与 builder 上的值验证边界）。
// ② 取纹理按活跃张数轮换（审计 #1534 P1-24，超级马力欧兄弟 惊奇 设 2 of 3）：3 张纹理（全零的 NVNtexture，只当交换链身份）、活跃 2 → 连取 4 次下标手算 0 1 0 1；
//   不设活跃数 → 0 1 2 0；SetNumActiveTextures(0) → 回 NATIVE_ERROR（1），不交纹理。旧实现按 3 张取模：第三次取到 2，红。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;
static void *api(const char *n) { void *p = h_nvnBootstrapLoader(n); if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; } return p; }
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
#define API(type, var, name) type var = (type)api(#name)

int main(void) {
    API(NVNT_nvnWindowBuilderSetDefaults, setDef, nvnWindowBuilderSetDefaults);
    API(NVNT_nvnWindowBuilderSetTextures, setTex, nvnWindowBuilderSetTextures);
    API(NVNT_nvnWindowInitialize, init, nvnWindowInitialize);
    API(NVNT_nvnWindowBuilderSetNumActiveTextures, setActB, nvnWindowBuilderSetNumActiveTextures);
    API(NVNT_nvnWindowAcquireTexture, acquire, nvnWindowAcquireTexture);
    void (*setAct)(NVNwindow *, int) = (void (*)(NVNwindow *, int))api("nvnWindowSetNumActiveTextures");
    int (*ntex_of)(const NVNwindow *) = (int (*)(const NVNwindow *))api("nvnWindowGetNumTextures");
    int (*nact_of)(const NVNwindow *) = (int (*)(const NVNwindow *))api("nvnWindowGetNumActiveTextures");
    if (bad) return 1;

    union { NVNwindowBuilder b; char raw[256]; } builder;
    NVNwindow win;

    // ① 0 张纹理：两个查询都应为 0
    memset(&builder, 0, sizeof builder);
    memset(&win, 0, sizeof win);
    setDef(&builder.b);
    setTex(&builder.b, 0, NULL);
    CHECK(init(&win, &builder.b), "WindowInitialize 返回假");
    CHECK(ntex_of(&win) == 0, "GetNumTextures=%d（应 0）", ntex_of(&win));
    CHECK(nact_of(&win) == 0, "GetNumActiveTextures=%d（应 0）", nact_of(&win));

    // ② 取纹理按活跃张数轮换
    static NVNtexture tex[3]; NVNtexture *tp[3] = {&tex[0], &tex[1], &tex[2]};
    int idx, want3[4] = {0, 1, 2, 0}, want2[4] = {0, 1, 0, 1};
    memset(&builder, 0, sizeof builder); memset(&win, 0, sizeof win);
    setDef(&builder.b); setTex(&builder.b, 3, tp);
    CHECK(init(&win, &builder.b), "WindowInitialize（3 张）返回假");
    for (int i = 0; i < 4; i++) { CHECK(acquire(&win, NULL, &idx) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && idx == want3[i], "未设活跃数第 %d 次取到 %d（应 %d）", i + 1, idx, want3[i]); }
    memset(&win, 0, sizeof win); CHECK(init(&win, &builder.b), "WindowInitialize（3 张）返回假");
    setAct(&win, 2); CHECK(nact_of(&win) == 2, "SetNumActiveTextures(2) 后 GetNumActiveTextures=%d（应 2）", nact_of(&win));
    for (int i = 0; i < 4; i++) { CHECK(acquire(&win, NULL, &idx) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && idx == want2[i], "活跃 2 of 3 第 %d 次取到 %d（应 %d）", i + 1, idx, want2[i]); }
    memset(&win, 0, sizeof win); setActB(&builder.b, 2); CHECK(init(&win, &builder.b), "WindowInitialize（构建器活跃 2）返回假");
    for (int i = 0; i < 4; i++) { CHECK(acquire(&win, NULL, &idx) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS && idx == want2[i], "构建器活跃 2 of 3 第 %d 次取到 %d（应 %d）", i + 1, idx, want2[i]); }
    setAct(&win, 0); CHECK(acquire(&win, NULL, &idx) == NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_NATIVE_ERROR, "活跃 0 时取纹理没回 NATIVE_ERROR");
    printf("%s t_nvn_win：窗口纹理数 / 活跃纹理数查询、按活跃张数取纹理 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}

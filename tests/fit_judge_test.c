// 宿主上屏满屏判据（graphics/metal/fit_judge.h）的取数无关单测驱动：tests/fit_judge_test.py 编它、喂图、对期望。
// 用法：fit_judge_test <图.raw>:<原比例种类 g>[:<几何已判没满屏 geo>] …   图.raw = 一行「宽 高\n」+ 宽×高×4 字节 BGRA（tests/fit_judge_test.py 从 PNG 转）
// 每张图用一份新状态连判两次（内容判据要连续 2 次没铺满才记红），打一行：<图> 未满屏 <次数> 原比例 <次数> 种类 <最近一次判定种类> 判定 <次数> 末行「<最后一条判据日志>」
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static char g_last[512];
#define FJ_LOG(...) snprintf(g_last, sizeof g_last, __VA_ARGS__)
#include "../graphics/metal/fit_judge.h"

typedef struct { int w, h; uint8_t *px; } img;
static void col(void *ctx, int x, uint8_t *buf) { const img *m = ctx; for (int y = 0; y < m->h; y++) memcpy(buf + 4 * y, m->px + ((size_t)y * m->w + x) * 4, 4); }
static void row(void *ctx, int y, uint8_t *px) { const img *m = ctx; memcpy(px, m->px + (size_t)y * m->w * 4, (size_t)m->w * 4); }

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        char path[1024]; snprintf(path, sizeof path, "%s", argv[i]);
        char *c = strrchr(path, ':'); if (!c) { fprintf(stderr, "参数要 <图.raw>:<g>：%s\n", argv[i]); return 2; }
        *c = 0; int g = atoi(c + 1), geo = 0;
        { char *c2 = strrchr(path, ':'); if (c2 && c2[1] >= '0' && c2[1] <= '9' && !strchr(c2 + 1, '.')) { geo = g; g = atoi(c2 + 1); *c2 = 0; } }   // <图>:<g>:<geo>
        FILE *f = fopen(path, "rb"); if (!f) { fprintf(stderr, "打不开 %s\n", path); return 2; }
        img m = {0}; if (fscanf(f, "%d %d", &m.w, &m.h) != 2 || fgetc(f) != '\n' || m.w <= 0 || m.h <= 0) { fprintf(stderr, "头不对 %s\n", path); return 2; }
        size_t n = (size_t)m.w * m.h * 4; m.px = malloc(n);
        if (!m.px || fread(m.px, 1, n, f) != n) { fprintf(stderr, "像素不够 %s\n", path); return 2; }
        fclose(f);
        fj_src s = {m.w, m.h, &m, col, row};
        fj_state st; memset(&st, 0, sizeof st); g_last[0] = 0;
        fj_judge(&st, &s, geo, "几何没满屏", g, 1); fj_judge(&st, &s, geo, "几何没满屏", g, 2);
        printf("%s 未满屏 %llu 原比例 %llu 种类 %d 判定 %llu 末行「%s」\n", path, (unsigned long long)atomic_load(&st.n_unfit), (unsigned long long)atomic_load(&st.n_pillar),
               atomic_load(&st.last_kind), (unsigned long long)atomic_load(&st.last_seq), g_last);
        free(m.px); free(st.buf); free(st.rbuf);
    }
    return 0;
}

// 直连画面检查（graphics/nvn/host/pic_watch.inc）的判据单测：期望按「最近 10 秒坏秒 ≥ 8 秒」手算，重点在别误退（黑屏加载、一秒尖峰、隔秒交替、样本太小）。
#include <stdio.h>
#include <string.h>
#include "../host/pic_watch.inc"
typedef struct { uint64_t d, f, e; } sec;
// 逐秒喂 → 第一次判异常的秒（从 0 数），-1 = 没判
static int run(const sec *s, int n, char *why, size_t wn) {
    pw_state w; memset(&w, 0, sizeof w);
    for (int i = 0; i < n; i++) if (pw_push(&w, s[i].d, s[i].f, s[i].e, why, wn)) return i;
    return -1;
}
int main(void) {
    static sec s[60]; char why[256]; int bad = 0, n = 0;
    #define CASE(name, fill, want) do { memset(s, 0, sizeof s); for (int i = 0; i < 60; i++) { fill; } int got = run(s, 60, why, sizeof why); n++; \
        int ok = got == (want); printf("%s %s：期望 %d → 真结果 %d\n", ok ? "✓" : "✗", name, want, got); bad += !ok; } while (0)
    CASE("60 秒黑屏加载、没有绘制", (void)i, -1);
    CASE("正常每秒画 1000", s[i].d = 1000, -1);
    CASE("缺功能丢弃只持续 7 秒", { s[i].d = 900; s[i].f = i < 7; }, -1);
    CASE("每秒都有缺功能丢弃", { s[i].d = 900; s[i].f = 1; }, 7);
    CASE("出错丢弃正好 20%", { s[i].d = 800; s[i].e = 200; }, 7);
    CASE("出错丢弃 15%", { s[i].d = 850; s[i].e = 150; }, -1);
    CASE("出错丢弃一半但每秒样本只有 40", { s[i].d = 20; s[i].e = 20; }, -1);
    CASE("一秒尖峰：第 0 秒出错丢弃 5000，之后正常", { s[i].d = 1000; s[i].e = i == 0 ? 5000 : 0; }, -1);
    CASE("隔秒交替坏", { s[i].d = 900; s[i].f = i % 2; }, -1);
    CASE("10 秒里坏 8 秒（第 2、6 秒好）", { s[i].d = 900; s[i].f = i != 2 && i != 6; }, 9);
    // 原因行：每秒都有缺功能丢弃（1 个）、画 900 → 第 7 秒判，窗口 8 秒
    memset(s, 0, sizeof s); for (int i = 0; i < 60; i++) { s[i].d = 900; s[i].f = 1; }
    run(s, 60, why, sizeof why); n++;
    const char *want = "画面异常：最近 8 秒里 8 秒丢了游戏的绘制（缺功能丢弃 8、出错丢弃 0，同期画了 7200）";
    int ok = !strcmp(why, want); printf("%s 原因行：期望「%s」→ 真结果「%s」\n", ok ? "✓" : "✗", want, why); bad += !ok;
    printf("%s t_pic_watch：%d 例，%d 处不符\n", bad ? "✗" : "✓", n, bad);
    return bad != 0;
}

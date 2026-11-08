// 直连画面检查（docs/设计_双轨.md §11.3 第五个入口；10-25 总指挥：除了崩溃，直连画面异常也整局退回通用）。由 host_adapt.m 包含，纯 C 便于单测（graphics/nvn/tests/t_pic_watch.c）。
// 不按像素判：加载、淡入淡出、过场都会长时间黑屏，按亮度判必误退。判的是「游戏下发的绘制被宿主丢掉了多少」（nvn_mtl.m mtl_bad_draws）：
//   缺功能丢弃 feat：宿主缺这个功能、明知把游戏要画的东西扔了（几何截取的限制、截不了的变换反馈、DrawTransformFeedback）；
//   出错丢弃 err：建不成管线、渲染 pass 起不来、没绑程序。正常的跳过（光栅丢弃、两面剔除、空裁剪）不计。
// 坏秒 = 这一秒有缺功能丢弃，或出错丢弃占这一秒（绘制 + 出错丢弃）≥ 20% 且样本 ≥ 50；最近 10 秒里坏秒 ≥ 8 秒判异常。
//   一秒的尖峰（换场景时一批管线建不成）不退；没有绘制的黑屏加载不算坏秒；后台与起局首帧前不取样（调用方管）
#include <stdint.h>
#include <stdio.h>
enum { PW_WIN = 10, PW_BAD = 8, PW_MIN = 50 };
typedef struct { uint64_t draws[PW_WIN], feat[PW_WIN], err[PW_WIN]; int n, at; } pw_state;   // 最近 PW_WIN 秒的增量
// 加一秒的增量 → 1 = 判异常（why 填原因），0 = 照常
static int pw_push(pw_state *w, uint64_t draws, uint64_t feat, uint64_t err, char *why, size_t n) {
    w->draws[w->at] = draws; w->feat[w->at] = feat; w->err[w->at] = err; w->at = (w->at + 1) % PW_WIN; if (w->n < PW_WIN) w->n++;
    int k = 0; uint64_t d = 0, f = 0, e = 0;
    for (int i = 0; i < w->n; i++) {
        uint64_t all = w->draws[i] + w->err[i];
        k += w->feat[i] > 0 || (all >= PW_MIN && w->err[i] * 5 >= all);
        d += w->draws[i]; f += w->feat[i]; e += w->err[i];
    }
    if (k < PW_BAD) return 0;
    snprintf(why, n, "画面异常：最近 %d 秒里 %d 秒丢了游戏的绘制（缺功能丢弃 %llu、出错丢弃 %llu，同期画了 %llu）", w->n, k,
             (unsigned long long)f, (unsigned long long)e, (unsigned long long)d);
    return 1;
}

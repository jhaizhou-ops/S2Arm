// 视频按片源帧率出图（10-30 帧率能耗线，对照 SavageWindRecomp movie.c）：游戏放预渲染视频时，宿主视频解码器（Ryujinx Nvdec，每解一帧报一次 s2a_video_frame）
//   按片源帧率出帧；片源不超过 30 帧时出图封顶 30（显示链接降到 30 Hz），游戏这段 CPU / GPU 工作减半，画面没有损失（片源本身就只有这么多帧）。
// 判定（纯函数，graphics/nvn/tests/t_vpace.c 测）：
//   进入：最近 1 秒解了 VP_ON_MIN–VP_ON_MAX 帧（24 / 25 / 30 帧片源都在里面），这些帧最早一帧在 VP_SPAN 之前（真按这个速度放了约 1 秒：起播时解码器先灌缓冲的突发
//         不算，等它平稳），且最后一帧在 VP_GAP 内；
//   保持：最后一帧在 VP_GAP 内且最近 1 秒不超过 VP_KEEP_MAX 帧（60 帧片源退出，不封顶）；
//   退出：VP_GAP 内没有新帧（视频放完 / 暂停）。
//   只在「这段主要在放视频」时封顶（nvn_vpace_cap）：游戏每帧绘制数 ≤ VP_DRAW_MAX。11-02 奥德赛局内一直在解 480×272 的小视频（画面里的一块），
//   原先只看解码帧率就把整局压到 30 帧（jhz 实玩：菜单 60、进游戏 30）；全屏过场视频每帧只画视频面片 + 字幕 / 跳过提示，局内照常渲染场景每帧几千个。
#pragma once
#include <stdint.h>

#define VP_N 64                         // 记最近这么多帧的解码时刻（1 秒内最多看这么多）
#define VP_WIN 1000000000ull            // 数帧的窗口：1 秒
#define VP_GAP 500000000ull             // 最后一帧距今超过 0.5 秒 = 没在放
#define VP_ON_MIN 12                    // 进入：1 秒内至少这么多帧（零星几帧的缩略图 / 单帧解码不算放视频）
#define VP_ON_MAX 32                    // 进入：1 秒内至多这么多帧（≤ 30 帧片源，留 2 帧抖动）
#define VP_KEEP_MAX 40                  // 保持：超过这么多帧（片源 ≥ 50 帧）退出
#define VP_SPAN 900000000ull            // 进入：1 秒窗口内最早一帧至少这么久以前
#define VP_DRAW_MAX 200                 // 封顶要求每帧绘制数不超过这么多（纯放视频远低于此；奥德赛局内约 4000）

typedef struct { uint64_t t[VP_N]; int n, i, on; } nvn_vpace;

static inline void nvn_vpace_frame(nvn_vpace *v, uint64_t now) {
    v->t[v->i] = now; v->i = (v->i + 1) % VP_N;
    if (v->n < VP_N) v->n++;
}

// 返回 1 = 正在放 ≤ 30 帧的视频，出图封顶 30
static inline int nvn_vpace_on(nvn_vpace *v, uint64_t now) {
    if (!v->n) return v->on = 0;
    uint64_t last = v->t[(v->i + VP_N - 1) % VP_N];
    if (now < last || now - last > VP_GAP) return v->on = 0;
    int c = 0; uint64_t oldest = now;
    for (int k = 0; k < v->n; k++) { uint64_t t = v->t[k]; if (t <= now && now - t <= VP_WIN) { c++; if (t < oldest) oldest = t; } }
    if (v->on) return v->on = c <= VP_KEEP_MAX;
    return v->on = c >= VP_ON_MIN && c <= VP_ON_MAX && now - oldest >= VP_SPAN;
}
// 返回 1 = 出图封顶 30：在放 ≤ 30 帧的视频，且游戏这段每帧绘制数 ≤ VP_DRAW_MAX（draws_per_frame 由调用方按最近一段的绘制数 ÷ 出图数算；< 0 = 还没量出，按不封顶）
static inline int nvn_vpace_cap(nvn_vpace *v, uint64_t now, double draws_per_frame) {
    return nvn_vpace_on(v, now) && draws_per_frame >= 0 && draws_per_frame <= VP_DRAW_MAX;
}

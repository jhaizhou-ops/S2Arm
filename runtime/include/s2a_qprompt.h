// 撑不住就问玩家（runtime/src/qprompt.c）：帧率 30 秒 / 满屏 20 秒判定。直连上屏每帧调 s2a_qp_present，返回本帧要弹的提示
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { S2A_QP_FPS = 1, S2A_QP_FIT = 2 };   // 帧率维持不住 60 / 局内满屏有问题
void s2a_qp_config(int ask_fps, int ask_fit);   // 哪种提示还可以问（玩家问过的关掉）
void s2a_qp_reset(void);                        // 换局清零（保留 config）
// 满屏判据此刻值不值得采样一帧：上一帧是游戏画面、画面真放宽着、本局满屏提示还能问（没问过、App 没记过）。玩家包的采样线程（qprompt_host.c）只在为真时请求整帧离屏取图
int s2a_qp_fit_wanted(void);
int s2a_qp_game(void);                          // 上一帧（最近一次 s2a_qp_present）是不是局内游戏画面：档位梯子（runtime/src/qladder_host.c）与本文件同一判定
uint32_t s2a_qp_base(void);                     // 开局基线（绘制数中位），0 = 还在采
int s2a_qp_secs(void);                          // 最近一次触发的「过去 XX 秒」（帧率 = 连续游戏画面秒数，满屏 = 没铺满累计秒数）
// now 纳秒、本帧绘制数、在放视频、过场标记、满屏判据（内容）当前报没铺满、60 帧此刻真在生效、画面此刻真放宽了、游戏自己设的交换间隔；
//   返回 0 / S2A_QP_FPS / S2A_QP_FIT（每种一局最多一次）
int s2a_qp_present(uint64_t now, uint32_t draws, int video, int cutscene, int unfit, int fps_live, int fit_live, int game_itv);
// 本款是不是原生 60 帧：游戏画面帧里游戏自己设的交换间隔（game_itv）累计 30 秒都是 1、从没出现 ≥ 2 → 1；出现过 ≥ 2 → 0；还没攒够 → -1
int s2a_qp_native60(void);
// 这一次取样算不算「满屏画面不可靠」（11-05）：判据结论是扩展区异常（1 黑带 / 2 接缝 / 3 暗带），或宽屏核心的导出入口异常计数比上次取样涨了
//   （核心一异常，那一笔就按「不放宽」退回——同帧有的放宽有的没放宽，画面必然对不齐；11-04 巫师3 测试机1 一局 31715 次、判据从没报红、玩家看到头发发白跳动）。
//   kind = 判据最近一次种类（没有新判定传 -1：只看异常）；*last = 上次读到的异常计数（调用方保存，首次传入当前值前先置 -1 表示还没读过）
int s2a_qp_unfit_sample(int kind, int64_t errors_now, int64_t *last);
#ifdef __cplusplus
}
#endif

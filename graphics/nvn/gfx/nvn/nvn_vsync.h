// 显示节拍源：平台接口（W1 D0 v2 定稿 #9；设计文档 docs/设计_回放核心共用.md §4）。
// 节拍源不是图形 API（Apple：QuartzCore 的 CAMetalDisplayLink；安卓：NDK 的 AChoreographer），所以不在 nvn_backend.h 里；由平台层实现，核心消费。
// 选哪一帧、按住几拍（interval / hold）、虚拟拍、卡死兜底都是核心的策略（现 nvn_mtl.m NvMetalDisplayLinkDelegate @10995–11042 那段抽到核心）。
// 没有节拍源的平台：nvn_vsync_start 返回 -1，核心改用 nvn_pace.h 计时。
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 每个显示刷新调一次。target_at：这一拍的目标呈现时刻（主机单调秒）；tick_n：累计拍数（从 1 起）；
// frame：平台的帧对象（Apple：CAMetalDisplayLinkUpdate，drawable 只从它来，交给 nvn_gpu_drawable_acquire 的 plat_frame；安卓：NULL），只在本次回调期间有效。
// 线程：平台的节拍线程（= nvn_backend.h 的 [上屏]）；回调里可以 acquire / present，不许等栅栏。
typedef void (*nvn_vsync_fn)(void *user, double target_at, uint64_t tick_n, void *frame);
// 开始节拍。hz：期望频率提示（30 / 60 / 120，0 = 屏幕原生）；平台不保证恰好这个频率，核心按 target_at 自己数拍。
// 返回 0 = 已开始；-1 = 本平台 / 当前窗口没有节拍源（why 写原因，≤ why_size 字节，以 0 结尾）。线程：[上屏]。重复调用先停旧的。
int nvn_vsync_start(uint32_t hz, nvn_vsync_fn fn, void *user, char *why, size_t why_size);
// 停止。返回时保证 fn 不再被调用。线程：[任意]，不许在 fn 里调。没开始时无操作。
void nvn_vsync_stop(void);

#ifdef __cplusplus
}
#endif

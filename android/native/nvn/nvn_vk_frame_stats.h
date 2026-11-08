// 帧时统计与 longframe 归因（Vulkan 侧模块）。
//
// 职责边界：这里只做"每帧量到的数 → 窗口统计 / 归因 / 日志"，不碰命令流、资源或设备状态。
// mtl_vk_shim.c 只把本帧的 (frame, now, exec, present, commands) 交进来一次，不持有窗口状态。
// 以后接 D0 时换数据来源（编译/管线计数改从 D0 接口读），调用点不变。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// frame：present 序号（从 1 起）；now_s：CLOCK_MONOTONIC 秒；
// exec_ms / present_ms / commands：本帧量到的录制执行、上屏与命令条数。
// 同一帧号重复调用是调用方的错误，这里不拦（只统计）。
// other 的实测拆分（秒，单调时钟）。exec_begin 在每帧第一条命令时调用；
// exec_end 在本帧命令录制完时调用；present_span 在上屏调用前后各取一次时间。
// 时间线打点（frame_id 必须真实；kind 取 S2A_TL_*）。finish 在 present 返回后调用。
void nvn_vk_frame_stats_tl_mark(uint64_t frame_id, int kind, double now_s);
void nvn_vk_frame_stats_tl_finish(uint64_t frame_id);
void nvn_vk_frame_stats_exec_begin(double now_s);
void nvn_vk_frame_stats_exec_end(double now_s);
void nvn_vk_frame_stats_present_span(double begin_s, double end_s);
void nvn_vk_frame_stats_present(uint64_t frame, double now_s, double exec_ms, double present_ms,
                                uint64_t commands);

#ifdef __cplusplus
}
#endif

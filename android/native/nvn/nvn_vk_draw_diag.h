// 首 8 笔绘制诊断（自 nvn_vk_first_draw.c 内联 diag_done 段抽出，#1229 P0-9）。
// 本模块只做两处客机内存边界修正：
//   - 顶点属性串拼接写得下才前进 off，写不下即停；
//   - 索引缓冲没有记录长度就不读；顶点缓冲按 vbuf_size 盖住最远一次读取才读。
// 开关通道（debug.s2a.draw_log / s2arm.draw_log）不在本模块，是否调用由调用方决定。
#pragma once
#include <stdint.h>

// 诊断单行日志容量。生产出口 fd_diag_log 按此开栈缓冲；最长的
// "diag request=..." 一行是固定段 + 后缀属性串 + request id（当前实测约 358 B），
// 取 1024 留足余量，避免更长 request id / 以后加字段时截掉属性串尾部。
// 夹具用同一常量核对最坏一行不被截断，并校验下限。
#define S2A_FIRST_DRAW_DIAG_MSG_CAP 1024

struct s2a_record_draw_state;

#ifdef __cplusplus
extern "C" {
#endif

void s2a_first_draw_diag(const struct s2a_record_draw_state *state,
                         uint32_t attr_mask, const char *request_id,
                         void (*log)(const char *fmt, ...));

#ifdef __cplusplus
}
#endif

// 帧时间线：按 frame ID 配对事件，每段都带有效样本数；缺样本输出"未测"，绝不写 0。
//
// 为什么需要它：旧读数把 other 当成 gap-exec-present 的残差，又把"首笔 draw→present blit 末尾"的
// 跨度当成 GPU 忙碌，都是推断而不是测量。这里改成事件配对：
//   首条 replay 命令 → 首笔 draw → 本帧录制结束 → present 调用开始/返回 → 下一帧首条命令
// 每次 mark 带 frame id：同段重复上报算 dup、旧帧上报算 cross，都不参与统计；
// 段只在两端都测到时才计入样本，否则该段保持"未测"。
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum s2a_tl_kind {
    S2A_TL_FIRST_CMD = 0,   // 本帧第一条 replay 命令开始
    S2A_TL_FIRST_DRAW,      // 本帧第一笔 draw 开始
    S2A_TL_EXEC_END,        // 本帧命令全部执行完（进入提交/上屏前）
    S2A_TL_PRESENT_BEGIN,   // 上屏调用开始
    S2A_TL_PRESENT_END,     // 上屏调用返回
    S2A_TL_KIND_MAX
};

enum s2a_tl_seg {
    S2A_TL_SEG_CMD_TO_DRAW = 0,   // 首条命令→首笔 draw（clear/copy/状态处理等前置工作）
    S2A_TL_SEG_DRAW_TO_END,       // 首笔 draw→录制结束（draw 之后到本帧命令结束）
    S2A_TL_SEG_END_TO_PRESENT,    // 录制结束→上屏开始（我们自己的提交收尾）
    S2A_TL_SEG_PRESENT,           // 上屏调用本身
    S2A_TL_SEG_PRESENT_TO_NEXT,   // 上屏返回→下一帧首条命令（guest 侧/节拍/调度）
    S2A_TL_SEG_MAX
};

struct s2a_tl_stat { uint64_t n; double sum_ms, max_ms; };

struct s2a_tl_frame {
    uint64_t id;
    double t[S2A_TL_KIND_MAX];
    uint32_t have;      // 位图
    int finished;
};

struct s2a_timeline {
    struct s2a_tl_frame cur, prev;      // prev = 最近完成的帧（用于跨帧段）
    struct s2a_tl_stat seg[S2A_TL_SEG_MAX];
    uint64_t dup, cross, unpaired;      // dup=同段重复上报 cross=旧帧上报 unpaired=因缺样本丢弃
};

void s2a_tl_reset(struct s2a_timeline *tl);

// 返回 0=记录成功，1=重复（忽略），2=跨帧/旧帧（忽略）。
int s2a_tl_mark(struct s2a_timeline *tl, uint64_t frame_id, int kind, double t);

// 本帧结束（present 返回后调用）：把可配对的段计入统计。
void s2a_tl_finish(struct s2a_timeline *tl, uint64_t frame_id);

// 下一帧首条命令到达时调用：用上一帧的 present_end 计算跨帧段（每帧只消费一次）。
void s2a_tl_note_next_first_cmd(struct s2a_timeline *tl, double t);

// 取窗口统计后清零（打印用）。name 返回段名；返回 1 表示该段有样本，0 表示"未测"。
int s2a_tl_take(struct s2a_timeline *tl, int seg, struct s2a_tl_stat *out);
const char *s2a_tl_seg_name(int seg);
const char *s2a_tl_kind_name(int kind);

#ifdef __cplusplus
}
#endif

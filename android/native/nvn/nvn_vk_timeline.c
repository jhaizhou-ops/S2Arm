#include "nvn_vk_timeline.h"

#include <string.h>

static const char *const k_kind_names[S2A_TL_KIND_MAX] = {
    "first_cmd", "first_draw", "exec_end", "present_begin", "present_end"
};
static const char *const k_seg_names[S2A_TL_SEG_MAX] = {
    "命令→首笔draw", "draw→录制结束", "录制结束→上屏", "上屏调用", "上屏→下帧首命令"
};

const char *s2a_tl_seg_name(int seg) {
    return (seg >= 0 && seg < S2A_TL_SEG_MAX) ? k_seg_names[seg] : "?";
}
const char *s2a_tl_kind_name(int kind) {
    return (kind >= 0 && kind < S2A_TL_KIND_MAX) ? k_kind_names[kind] : "?";
}

void s2a_tl_reset(struct s2a_timeline *tl) {
    if (!tl) return;
    memset(tl, 0, sizeof *tl);
}

static void seg_add(struct s2a_tl_stat *s, double ms) {
    if (ms < 0) return;
    s->n++;
    s->sum_ms += ms;
    if (ms > s->max_ms) s->max_ms = ms;
}

// 约定：所有 t 都是**秒**（CLOCK_MONOTONIC 的 double），统计里统一存毫秒。
int s2a_tl_mark(struct s2a_timeline *tl, uint64_t frame_id, int kind, double t) {
    if (!tl || kind < 0 || kind >= S2A_TL_KIND_MAX || frame_id == 0) return 2;
    struct s2a_tl_frame *f = &tl->cur;
    if (f->id != frame_id) {
        if (f->id == 0) {
            f->id = frame_id;
            f->have = 0;
            f->finished = 0;
        } else {
            // 上一帧还没 finish 就又来新帧：把旧帧标记为未完成（缺样本），不参与统计。
            tl->unpaired++;
            f->id = frame_id;
            f->have = 0;
            f->finished = 0;
        }
    }
    uint32_t bit = 1u << kind;
    if (f->have & bit) { tl->dup++; return 1; }     // 同段重复：忽略，不累计
    f->have |= bit;
    f->t[kind] = t;
    return 0;
}

static double delta(const struct s2a_tl_frame *f, int a, int b) {
    if (!(f->have & (1u << a)) || !(f->have & (1u << b))) return -1.0;
    return f->t[b] - f->t[a];
}

void s2a_tl_finish(struct s2a_timeline *tl, uint64_t frame_id) {
    if (!tl || frame_id == 0) return;
    struct s2a_tl_frame *f = &tl->cur;
    if (f->id != frame_id) return;                  // 不是当前帧的结束：不伪造
    f->finished = 1;

    double d;
    d = delta(f, S2A_TL_FIRST_CMD, S2A_TL_FIRST_DRAW);
    if (d >= 0) seg_add(&tl->seg[S2A_TL_SEG_CMD_TO_DRAW], d * 1000.0); else tl->unpaired++;
    d = delta(f, S2A_TL_FIRST_DRAW, S2A_TL_EXEC_END);
    if (d >= 0) seg_add(&tl->seg[S2A_TL_SEG_DRAW_TO_END], d * 1000.0); else tl->unpaired++;
    d = delta(f, S2A_TL_EXEC_END, S2A_TL_PRESENT_BEGIN);
    if (d >= 0) seg_add(&tl->seg[S2A_TL_SEG_END_TO_PRESENT], d * 1000.0); else tl->unpaired++;
    d = delta(f, S2A_TL_PRESENT_BEGIN, S2A_TL_PRESENT_END);
    if (d >= 0) seg_add(&tl->seg[S2A_TL_SEG_PRESENT], d * 1000.0); else tl->unpaired++;

    tl->prev = *f;                                  // 跨帧段等下一帧首条命令到达时再算
    f->id = 0;
    f->have = 0;
    f->finished = 0;
}

// 新帧首条命令到达：用上一帧的 present_end 算跨帧段。
void s2a_tl_note_next_first_cmd(struct s2a_timeline *tl, double t) {
    if (!tl) return;
    struct s2a_tl_frame *p = &tl->prev;
    if (!p->id || !p->finished) return;
    if (!(p->have & (1u << S2A_TL_PRESENT_END))) { tl->unpaired++; return; }
    double d = t - p->t[S2A_TL_PRESENT_END];
    if (d < 0) { tl->unpaired++; return; }
    seg_add(&tl->seg[S2A_TL_SEG_PRESENT_TO_NEXT], d * 1000.0);
    p->id = 0;   // 消费掉，避免重复计入
}

int s2a_tl_take(struct s2a_timeline *tl, int seg, struct s2a_tl_stat *out) {
    if (!tl || !out || seg < 0 || seg >= S2A_TL_SEG_MAX) return 0;
    *out = tl->seg[seg];
    int has = tl->seg[seg].n > 0;
    memset(&tl->seg[seg], 0, sizeof tl->seg[seg]);
    return has;
}

// 帧时间线事件配对（宿主）：重复、跨帧、缺样本必须被识别，不能把缺失当 0。
#include <stdio.h>
#include <string.h>

#include "nvn/nvn_vk_timeline.h"

static int g_fail, g_checks;
#define CHECK(c) do { g_checks++; if (!(c)) { g_fail++; printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static double seg_avg(struct s2a_timeline *tl, int seg) {
    struct s2a_tl_stat st;
    int has = s2a_tl_take(tl, seg, &st);
    return has ? st.sum_ms / (double)st.n : -1.0;
}

int main(void) {
    struct s2a_timeline tl;

    printf("  case %-32s", "full_frame_segments");
    s2a_tl_reset(&tl);
    CHECK(s2a_tl_mark(&tl, 10, S2A_TL_FIRST_CMD, 1.000) == 0);
    CHECK(s2a_tl_mark(&tl, 10, S2A_TL_FIRST_DRAW, 1.001) == 0);
    CHECK(s2a_tl_mark(&tl, 10, S2A_TL_EXEC_END, 1.012) == 0);
    CHECK(s2a_tl_mark(&tl, 10, S2A_TL_PRESENT_BEGIN, 1.0125) == 0);
    CHECK(s2a_tl_mark(&tl, 10, S2A_TL_PRESENT_END, 1.0135) == 0);
    s2a_tl_finish(&tl, 10);
    CHECK(seg_avg(&tl, S2A_TL_SEG_CMD_TO_DRAW) > 0.9 && seg_avg(&tl, S2A_TL_SEG_CMD_TO_DRAW) < 1.1);
    CHECK(seg_avg(&tl, S2A_TL_SEG_DRAW_TO_END) > 10.9 && seg_avg(&tl, S2A_TL_SEG_DRAW_TO_END) < 11.1);
    CHECK(seg_avg(&tl, S2A_TL_SEG_END_TO_PRESENT) > 0.4 && seg_avg(&tl, S2A_TL_SEG_END_TO_PRESENT) < 0.6);
    CHECK(seg_avg(&tl, S2A_TL_SEG_PRESENT) > 0.9 && seg_avg(&tl, S2A_TL_SEG_PRESENT) < 1.1);
    CHECK(seg_avg(&tl, S2A_TL_SEG_PRESENT_TO_NEXT) < 0);   // 还没有下一帧：未测
    printf("ok\n");

    printf("  case %-32s", "cross_frame_segment");
    s2a_tl_reset(&tl);
    s2a_tl_mark(&tl, 10, S2A_TL_FIRST_CMD, 1.000);
    s2a_tl_mark(&tl, 10, S2A_TL_FIRST_DRAW, 1.001);
    s2a_tl_mark(&tl, 10, S2A_TL_EXEC_END, 1.012);
    s2a_tl_mark(&tl, 10, S2A_TL_PRESENT_BEGIN, 1.0125);
    s2a_tl_mark(&tl, 10, S2A_TL_PRESENT_END, 1.0135);
    s2a_tl_finish(&tl, 10);
    s2a_tl_note_next_first_cmd(&tl, 1.0205);               // 上屏后 7 ms 才来下一帧
    CHECK(seg_avg(&tl, S2A_TL_SEG_PRESENT_TO_NEXT) > 6.9 && seg_avg(&tl, S2A_TL_SEG_PRESENT_TO_NEXT) < 7.1);
    s2a_tl_note_next_first_cmd(&tl, 1.0305);               // 重复消费：不能再加一次
    CHECK(seg_avg(&tl, S2A_TL_SEG_PRESENT_TO_NEXT) < 0);
    printf("ok\n");

    printf("  case %-32s", "duplicate_begin_ignored");
    s2a_tl_reset(&tl);
    s2a_tl_mark(&tl, 20, S2A_TL_FIRST_CMD, 2.000);
    s2a_tl_mark(&tl, 20, S2A_TL_FIRST_DRAW, 2.002);
    s2a_tl_mark(&tl, 20, S2A_TL_EXEC_END, 2.008);
    s2a_tl_mark(&tl, 20, S2A_TL_PRESENT_BEGIN, 2.0085);
    s2a_tl_mark(&tl, 20, S2A_TL_PRESENT_END, 2.0095);
    CHECK(s2a_tl_mark(&tl, 20, S2A_TL_FIRST_CMD, 2.005) == 1);   // 同帧第二次 begin：dup
    CHECK(s2a_tl_mark(&tl, 20, S2A_TL_PRESENT_BEGIN, 2.020) == 1);
    CHECK(tl.dup == 2);
    s2a_tl_finish(&tl, 20);
    s2a_tl_note_next_first_cmd(&tl, 2.0165);
    CHECK(seg_avg(&tl, S2A_TL_SEG_PRESENT_TO_NEXT) > 6.9 && seg_avg(&tl, S2A_TL_SEG_PRESENT_TO_NEXT) < 7.1);
    printf("ok\n");

    printf("  case %-32s", "missing_end_is_not_zero");
    s2a_tl_reset(&tl);
    s2a_tl_mark(&tl, 30, S2A_TL_FIRST_CMD, 3.000);
    s2a_tl_mark(&tl, 30, S2A_TL_FIRST_DRAW, 3.001);
    s2a_tl_mark(&tl, 30, S2A_TL_PRESENT_BEGIN, 3.012);
    s2a_tl_mark(&tl, 30, S2A_TL_PRESENT_END, 3.013);
    s2a_tl_finish(&tl, 30);                                 // 没有 exec_end
    CHECK(seg_avg(&tl, S2A_TL_SEG_END_TO_PRESENT) < 0);      // 未测，不是 0
    CHECK(seg_avg(&tl, S2A_TL_SEG_DRAW_TO_END) < 0);
    CHECK(tl.unpaired > 0);
    printf("ok\n");

    printf("  case %-32s", "stale_frame_ignored");
    s2a_tl_reset(&tl);
    s2a_tl_mark(&tl, 40, S2A_TL_FIRST_CMD, 4.000);
    s2a_tl_mark(&tl, 40, S2A_TL_FIRST_DRAW, 4.001);
    s2a_tl_finish(&tl, 41);                                  // 不是当前帧：不伪造
    CHECK(seg_avg(&tl, S2A_TL_SEG_CMD_TO_DRAW) < 0);
    printf("ok\n");

    printf("nvn-vk-timeline: 检查 %d 项，失败 %d 项 → %s\n", g_checks, g_fail, g_fail ? "红" : "通过");
    return g_fail ? 1 : 0;
}

// 首 8 笔绘制诊断（#1229 P0-9，自 nvn_vk_first_draw.c 内联段抽出）。
// 两处修法都在客机内存边界上：
//   1. 顶点属性拼接只在写得下时前进 off，写不下即停——snprintf 返回的是本应
//      写入长度，直接 += 会让 sizeof a - off 无符号回绕、写穿 192 字节栈缓冲；
//   2. 索引缓冲没有记录长度 → 不读索引字节；vbuf_size 盖不住最远一次
//      memcpy（3 * stride + 16）就不读顶点缓冲。客机内存只按记录的范围读。
#include "nvn_vk_draw_diag.h"
#include <stdio.h>
#include <string.h>
#include "vk_record.h"
#include "nvn_obj.h"   // ds_st：state_obj[5] 的深度/模板状态原文布局

void s2a_first_draw_diag(const struct s2a_record_draw_state *state,
                         uint32_t attr_mask, const char *request_id,
                         void (*log)(const char *fmt, ...)) {
    if (!state || !log) return;
    static int diag_done[8];
    int diag_slot = -1;
    for (int i = 0; i < 8; i++) if (!diag_done[i]) { diag_slot = i; break; }
    if (diag_slot < 0 || diag_slot >= 8) return;
    diag_done[diag_slot] = 1;

    char a[192] = "";
    int off = 0;
    for (int loc = 0; loc < 32; loc++) {
        if (!(attr_mask & (1u << loc))) continue;
        int n = snprintf(a + off, sizeof a - (size_t)off, "loc%d=f%d@%u/s%u ", loc,
                         state->vattr[loc].format, state->vattr[loc].offset,
                         state->vattr[loc].stream);
        if (n < 0 || (size_t)off + (size_t)n >= sizeof a) break;
        off += n;
    }
    // 绘制状态只记了索引缓冲地址，没有记长度：不读索引字节，报告成未知。
    // 将来若补了长度，读取范围须限制在 min(count, 8) * index_size 且不超过该长度。
    float v0[4] = {0}, v1[4] = {0}, v2[4] = {0};
    int16_t s0[4] = {0}, s1[4] = {0}, s2[4] = {0}, s3[4] = {0};
    uint32_t stride0 = state->vstream_stride[0];
    if (state->vbuf_addr[0] && stride0 &&
        state->vbuf_size[0] >= (uint64_t)3 * stride0 + 16) {
        memcpy(v0, (const void *)(uintptr_t)state->vbuf_addr[0], 16);
        memcpy(v1, (const void *)(uintptr_t)(state->vbuf_addr[0] + stride0), 16);
        memcpy(v2, (const void *)(uintptr_t)(state->vbuf_addr[0] + 2 * stride0), 16);
        memcpy(s0, (const void *)(uintptr_t)state->vbuf_addr[0], 8);
        memcpy(s1, (const void *)(uintptr_t)(state->vbuf_addr[0] + stride0), 8);
        memcpy(s2, (const void *)(uintptr_t)(state->vbuf_addr[0] + 2 * stride0), 8);
        memcpy(s3, (const void *)(uintptr_t)(state->vbuf_addr[0] + 3 * stride0), 8);
    }
    int nz = 0;
    if (state->vbuf_addr[0] && state->vbuf_size[0] && state->vbuf_size[0] <= 4096) {
        const uint8_t *b = (const uint8_t *)(uintptr_t)state->vbuf_addr[0];
        for (uint64_t i = 0; i < state->vbuf_size[0]; i++) if (b[i]) nz++;
    }
    for (int st = 0; st < 2; st++) {
        for (int us = 0; us < 4; us++) {
            uint64_t ub_addr = state->ubo[st][us].addr, ub_size = state->ubo[st][us].size;
            if (!ub_addr) continue;
            float m5[4] = {0}, m118[4] = {0}, head[4] = {0};
            if (ub_size >= 6 * 16) memcpy(m5, (const void *)(uintptr_t)(ub_addr + 5 * 16), sizeof m5);
            // FS 用 fp_c3[118].w：成员 118 起点 offset 118*16，.w 在 +12。越界就不读。
            if (ub_size >= 118 * 16 + 16) memcpy(m118, (const void *)(uintptr_t)(ub_addr + 118 * 16), sizeof m118);
            if (ub_size >= 16) memcpy(head, (const void *)(uintptr_t)ub_addr, sizeof head);
            log("diag stage=%s nvn_ubo_slot=%d addr=%llx size=%llu m118=(%.4f,%.4f,%.4f,%.4f) m118.w=%.4f m5=(%.3f,%.3f,%.3f,%.3f) f0..f3=(%.3f,%.3f,%.3f,%.3f)",
                st == 0 ? "vs" : "fs", us, (unsigned long long)ub_addr, (unsigned long long)ub_size,
                m118[0], m118[1], m118[2], m118[3], m118[3], m5[0], m5[1], m5[2], m5[3],
                head[0], head[1], head[2], head[3]);
        }
    }
    log("diag pos16 v0=(%d,%d,%d,%d) v1=(%d,%d,%d,%d) v2=(%d,%d,%d,%d) v3=(%d,%d,%d,%d)",
        s0[0],s0[1],s0[2],s0[3], s1[0],s1[1],s1[2],s1[3],
        s2[0],s2[1],s2[2],s2[3], s3[0],s3[1],s3[2],s3[3]);
    log("diag vp=(%.0f,%.0f %.0fx%.0f) sc=(%d,%d %dx%d) rt=%ux%u",
        state->vp_x, state->vp_y, state->vp_w, state->vp_h,
        state->sc_x, state->sc_y, state->sc_w, state->sc_h, state->rt[0].width, state->rt[0].height);
    log("diag request=%s count=%u base=%u idx=? vt=%d stride0=%u vbuf=%llx+%llu nz=%d/%llu v0=(%.1f,%.1f,%.1f,%.1f) v1=(%.1f,%.1f,%.1f,%.1f) dt=%d dw=%d df=%d st=%d cleared=%d attr[%s]",
        request_id ? request_id : "?", state->count, state->base_vertex,
        state->index_type,
        state->vstream_stride[0],
        (unsigned long long)state->vbuf_addr[0], (unsigned long long)state->vbuf_size[0],
        nz, (unsigned long long)state->vbuf_size[0],
        v0[0], v0[1], v0[2], v0[3], v1[0], v1[1], v1[2], v1[3],
        (state->state_seen & (1u << 5)) ? ((const ds_st *)state->state_obj[5])->dt : -1,
        (state->state_seen & (1u << 5)) ? ((const ds_st *)state->state_obj[5])->dw : -1,
        (state->state_seen & (1u << 5)) ? ((const ds_st *)state->state_obj[5])->df : -1,
        (state->state_seen & (1u << 5)) ? ((const ds_st *)state->state_obj[5])->st : -1,
        state->depth_cleared, a);
}

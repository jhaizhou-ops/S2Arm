// S2Arm 首遇现建读数（10-29 删直连链接版后的剩余风险监控）：提交线程上同步现建的完整管线，按两个口径累计、打两行固定格式。
//   ① MARK 后（自动玩家打「S2A 标记 MARK」之后，runtime/src/ap_host.c s2a_ap_marked）：「首遇现建：MARK 后提交线程现建管线 N 条，最长 x ms，合计 y ms」
//   ② 开局预热撞上限（DM_PSO_PREPARE_MAX_MS）转后台的那段：从首帧到后台预热编完，「预热转后台：M 条，后台编完用时 t ms，期间提交线程现建 K 条（最长 z ms）」；
//      没撞上限 M = 0、照打这一行；后台还没编完时「用时」= 到打印时刻为止
//   计的是 nvn_mtl.m 里缓存没命中、提交线程拿完整管线的那一步（建 / 等后台编完；与长帧行「new pipelines」同一处计数），预热线程自己建的不算。
//   调用方持锁（nvn_mtl.m g_fe_mu）；本头文件只有纯计算与格式化，单测 graphics/nvn/tests/t_nvn_pairguard.m 按手算值核
#ifndef S2A_FE_STAT_H
#define S2A_FE_STAT_H
#include <stdint.h>
#include <stdio.h>
typedef struct { uint64_t n, max_ns, sum_ns; } fe_acc;
typedef struct {
    fe_acc mark, bg;          // mark：MARK 后；bg：预热转后台期间
    uint64_t bg_m, bg_t0, bg_t1;   // 转后台的行数、首帧时刻、后台编完时刻（纳秒，同一时钟）
    int bg_on;                // 0 没转后台 / 1 后台在编 / 2 后台编完
} fe_stat;
static inline void fe_acc_add(fe_acc *a, uint64_t ns) { a->n++; a->sum_ns += ns; if (ns > a->max_ns) a->max_ns = ns; }
// 一次提交线程同步现建，耗时 ns；marked = 已过 MARK
static inline void fe_note(fe_stat *s, uint64_t ns, int marked) { if (marked) fe_acc_add(&s->mark, ns); if (s->bg_on == 1) fe_acc_add(&s->bg, ns); }
static inline void fe_bg_begin(fe_stat *s, uint64_t m, uint64_t now) { s->bg_m = m; s->bg_t0 = now; s->bg_on = 1; }
static inline void fe_bg_end(fe_stat *s, uint64_t now) { if (s->bg_on == 1) { s->bg_t1 = now; s->bg_on = 2; } }
static inline int fe_line_mark(char *b, size_t n, const fe_stat *s) {
    return snprintf(b, n, "首遇现建：MARK 后提交线程现建管线 %llu 条，最长 %.1f ms，合计 %.1f ms",
                    (unsigned long long)s->mark.n, s->mark.max_ns / 1e6, s->mark.sum_ns / 1e6);
}
static inline int fe_line_bg(char *b, size_t n, const fe_stat *s, uint64_t now) {
    uint64_t t = s->bg_on == 2 ? s->bg_t1 - s->bg_t0 : s->bg_on == 1 && now > s->bg_t0 ? now - s->bg_t0 : 0;
    return snprintf(b, n, "预热转后台：%llu 条，后台编完用时 %.1f ms，期间提交线程现建 %llu 条（最长 %.1f ms）",
                    (unsigned long long)s->bg_m, t / 1e6, (unsigned long long)s->bg.n, s->bg.max_ns / 1e6);
}
#endif

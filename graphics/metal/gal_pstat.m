// 遍序列与 GPFIFO 统计（诊断，帧率能耗线 10-21）：NXGAL_PSTAT=1 开，缺省关（各记录点先判一个全局整数，零开销）。只统计、不改行为，稳态零分配（全部固定表）。
// 给 jhz 定下一招突破先做哪个的两个数：
// ① 中间图能不能不出芯片：渲染线程每帧把遍序列（附件 + 读入动作清 / 读、采样 / 其他读）记进固定环，上屏时回看本帧算账（gal_pstat_analyze）：
//    存回后、下一次被读之前就被清 / 本帧之后再也不读的附件存回（可省存回 MB），相邻两遍续用同一附件（遍合一可省存回 + 读入），
//    「本遍写、下一遍采样同一附件」的相邻遍对数（两遍合一 / 片上合并的潜力）。字节口径同 NXGAL_PERF_PASSCOMMIT 的读入 / 存回（通道尺寸 × 层 × 采样 × 每像素字节）。
// ② 命令没变就重放：游戏每次提交 GPFIFO（Ryujinx GPFifoDevice.PushEntries，补丁 S2A 挂钩）的命令段（客体地址 + 长度）落在多少「上次提交以来没变」的 4 KB 页上。
//    写跟踪（graphics/track）只对 Ryujinx 要求保护的子页（贴图 / 缓冲 / 池的跟踪句柄）有信息，命令段内存 Ryujinx 不建跟踪句柄（GPFifo 直接 GetSpan 读），
//    问写跟踪答不了「这页写没写过」——所以按页内容哈希判「与上次提交时相同」（同值写算没变，对重放正是要的口径）；写跟踪覆盖到的字节比例单列（s2a_track_sub_state 只读查询）。
//    另给与地址无关的口径：段内容（哈希）与前 2 帧内某段相同的比例（命令内存若是轮换的几块，按页看总是新写的，按内容看才知道命令本身变没变）。
// 每 300 帧（NXGAL_PSTAT_EVERY 可改）打一行汇总到 stderr。
#include "gal_pstat.h"
#include "gal_abi.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <os/lock.h>
#include <execinfo.h>
#include <dlfcn.h>

// ---------- 纯逻辑：一帧算账 ----------
void gal_pstat_analyze(const ps_ev *ev, int n, uint32_t nroot, uint32_t *scratch, ps_res *r) {
    // a1 / a0：最近两次当附件的遍号（1 起，0 = 没当过）；nx：下一个事件（遍号 << 2 | 1 清开遍附件 2 读入附件 3 读）；nb：下一个附件事件的字节
    uint32_t *a1 = scratch, *a0 = scratch + nroot, *nx = scratch + 2 * nroot, *nb = scratch + 3 * nroot, *nv = scratch + 4 * nroot;
    memset(scratch, 0, (size_t)nroot * 5 * sizeof *scratch);
    // 正向：相邻遍对「本遍写 → 下一遍采样」
    uint32_t p = 0, lastq = 0;
    for (int i = 0; i < n; i++) {
        const ps_ev *e = &ev[i];
        if (e->kind == PS_PASS) { p++; continue; }
        if (e->root >= nroot) continue;
        if (e->kind == PS_ATT) { if (a1[e->root] != p) { a0[e->root] = a1[e->root]; a1[e->root] = p; } continue; }
        if (e->kind == PS_SAMPLE && !e->cs) {
            uint32_t q = e->inpass ? p : p + 1;
            if (q >= 2 && q != lastq && (a1[e->root] == q - 1 || (a1[e->root] == q && a0[e->root] == q - 1))) { r->pairs++; lastq = q; }
        }
    }
    r->passes += p;
    // 反向：每个附件存回之后它的下一个事件
    for (int i = n - 1; i >= 0; i--) {
        const ps_ev *e = &ev[i];
        if (e->kind == PS_PASS) { p--; continue; }
        if (e->root >= nroot) continue;
        uint32_t x = e->root;
        if (e->kind != PS_ATT) { nx[x] = 3; continue; }
        r->st_n++; r->st_bytes += e->bytes;
        if (!e->clear) { r->ld_n++; r->ld_bytes += e->bytes; }
        uint32_t k = nx[x] & 3, np = nx[x] >> 2;
        if (!nx[x]) { r->dead_n++; r->dead_bytes += e->bytes; }
        else if (k == 1) { r->clr_n++; r->clr_bytes += e->bytes; }
        else if (k == 2 && np == p + 1) { r->adj_n++; r->adj_st_bytes += e->bytes; r->adj_ld_bytes += nb[x];
            if (e->view && e->view == nv[x]) { r->adj_same_n++; r->adj_same_st_bytes += e->bytes; } }
        nx[x] = p << 2 | (e->clear ? 1u : 2u);
        nb[x] = e->bytes > UINT32_MAX ? UINT32_MAX : (uint32_t)e->bytes;
        nv[x] = e->view;
    }
}

// ---------- 开关 ----------
int g_pstat = -1;
// 事件流导出（诊断）：NXGAL_PSTAT_DUMP=<文件> 把第 a..b 帧（NXGAL_PSTAT_DUMP_FRAMES=a-b，缺省 1-1000000）的遍序列逐行写出，
// 另记渲染编码器结束 / 开拷贝计算编码器的调用栈（离线 atos 符号化，文件头给 libnxgal 装载地址）
static FILE *g_dump; static uint64_t g_dump_lo = 1, g_dump_hi = 1000000;
// 汇总行间隔帧数（NXGAL_PSTAT_EVERY，缺省 300；录像回放只有几十帧时调小）
static uint64_t g_every = 300;
int gal_pstat_init(void) {
    const char *v = getenv("NXGAL_PSTAT"); g_pstat = v && *v == '1';
    if (g_pstat) fprintf(stderr, "[gal] 遍统计开（NXGAL_PSTAT=1）：只统计不改行为，每 300 帧（NXGAL_PSTAT_EVERY）一行「遍统计」\n");
    const char *ev = getenv("NXGAL_PSTAT_EVERY"); if (ev && atoi(ev) > 0) g_every = (uint64_t)atoi(ev);
    const char *dp = getenv("NXGAL_PSTAT_DUMP");
    if (g_pstat && dp && *dp) {
        g_dump = fopen(dp, "w");
        const char *fr = getenv("NXGAL_PSTAT_DUMP_FRAMES");
        if (fr && *fr) { g_dump_lo = strtoull(fr, NULL, 10); const char *m = strchr(fr, '-'); g_dump_hi = m ? strtoull(m + 1, NULL, 10) : g_dump_lo; }
        Dl_info di; if (g_dump && dladdr((const void *)gal_pstat_init, &di)) fprintf(g_dump, "L %p %s\n", di.dli_fbase, di.dli_fname);
    }
    return g_pstat;
}

// ---------- ① 渲染线程记录（GAL 入口锁内，单线程）----------
#define PS_MAXEV 65536
#define PS_NROOT 2048
#define PS_HSLOT 4096
static ps_ev g_ev[PS_MAXEV]; static int g_nev, g_trunc;
static struct { const void *p; uint32_t gen, id, tag; } g_rh[PS_HSLOT];
static uint32_t g_rgen = 1, g_nroot, g_rpass;
static uint32_t g_scratch[PS_NROOT * 5];
static ps_res g_acc; static uint64_t g_frames, g_tframes, g_frame_total;
// 帧号（上屏次数），GPFIFO 统计按它分帧
static _Atomic uint32_t g_gen;

// root → 本帧编号（开放寻址、按帧代数作废，不清表）；返回槽下标，满了返回 -1（本帧截断）
static int root_slot(const void *p) {
    uint32_t h = (uint32_t)(((uintptr_t)p >> 4) * 0x9E3779B1u) & (PS_HSLOT - 1);
    for (int k = 0; k < PS_HSLOT; k++, h = (h + 1) & (PS_HSLOT - 1)) {
        if (g_rh[h].gen != g_rgen) {
            if (g_nroot >= PS_NROOT) return -1;
            g_rh[h].p = p; g_rh[h].gen = g_rgen; g_rh[h].id = g_nroot++; g_rh[h].tag = 0; return (int)h;
        }
        if (g_rh[h].p == p) return (int)h;
    }
    return -1;
}
// 导出里每个遍结束行带本遍绘制数 / 清屏辅助绘制数（单测不链渲染器：弱符号）
__attribute__((weak)) uint64_t gal_draw_count(void) { return 0; }
uint64_t g_pstat_clears;
static uint64_t g_mark_draws, g_mark_clears;
#define PS_NPC 16384
#define PS_DEPTH 7
static void *g_evpc[PS_NPC][PS_DEPTH]; static uint64_t g_evpc_n[PS_NPC][2]; static int g_npcs;
static ps_ev *ev_push(void) { if (g_nev >= PS_MAXEV) { g_trunc = 1; return NULL; } return &g_ev[g_nev++]; }
// ---------- 帧级调度测算（见 gal_pstat.h）----------
int g_sw_why, g_sw_dep = 4, g_sw_on = -1;   // 没登记的入口：原因「其他」、依赖 4 = 未登记（算账按真依赖）
static uint32_t g_sw_pass; static int g_sw_open;   // 渲染遍序号（单调，开遍 +1）；遍开着（开遍置 1，收遍置 0）
#define SW_SLOT 8192
static struct { const void *k; uint32_t rd, wr; } g_swt[SW_SLOT];
int gal_sw_init(void) { const char *v = getenv("NXGAL_PSTAT_DUMP"); g_sw_on = v && *v; return g_sw_on; }
static int sw_slot(const void *k, int add) {
    uint32_t h = (uint32_t)(((uintptr_t)k >> 1) * 0x9E3779B1u) & (SW_SLOT - 1);
    for (int n = 0; n < SW_SLOT; n++, h = (h + 1) & (SW_SLOT - 1)) {
        if (g_swt[h].k == k) return (int)h;
        if (!g_swt[h].k) { if (!add) return -1; g_swt[h].k = k; g_swt[h].rd = g_swt[h].wr = 0; return (int)h; }
    }
    return -1;
}
int gal_sw_pass_open(void) { return g_sw_open; }
void gal_sw_note(const void *key, int write) { if (!SW_ON() || !key) return; int s = sw_slot(key, 1); if (s < 0) return; if (write) g_swt[s].wr = g_sw_pass; else g_swt[s].rd = g_sw_pass; }
int gal_sw_hit(const void *key, int write) {
    if (!key || !g_sw_pass) return 0;
    if (!g_sw_open) return 0;
    int s = sw_slot(key, 0); return s >= 0 && (write ? g_swt[s].wr : g_swt[s].rd) == g_sw_pass;
}
void gal_pstat_pass(void) { g_sw_pass++; g_sw_open = 1; if (g_dump) { g_mark_draws = gal_draw_count(); g_mark_clears = g_pstat_clears; } ps_ev *e = ev_push(); if (e) { memset(e, 0, sizeof *e); e->kind = PS_PASS; } g_rpass++; }
void gal_pstat_att(const void *root, int clear, uint64_t bytes, int slot, uint32_t view) {
    if (!root) return;
    int s = root_slot(root); if (s < 0) { g_trunc = 1; return; }
    g_rh[s].tag = 0;
    ps_ev *e = ev_push(); if (!e) return;
    *e = (ps_ev){PS_ATT, (uint8_t)(clear != 0), (uint8_t)slot, 0, g_rh[s].id, bytes, view};
}
// 采样 / 其他读：同一 root 连续同类同遍的只记一次（每次绘制都会报一遍绑定的贴图）
void gal_pstat_use(const void *root, int kind, int inpass, int cs) {
    if (!root) return;
    int s = root_slot(root); if (s < 0) { g_trunc = 1; return; }
    uint32_t q = inpass ? g_rpass : g_rpass + 1, tag = q << 4 | (uint32_t)kind << 1 | (cs != 0) | 0x80000000u;
    if (g_rh[s].tag == tag) return;
    g_rh[s].tag = tag;
    ps_ev *e = ev_push(); if (!e) return;
    *e = (ps_ev){(uint8_t)kind, 0, (uint8_t)(inpass != 0), (uint8_t)(cs != 0), g_rh[s].id, 0};
}

void gal_pstat_mark(int kind) {
    if (kind == PS_END) g_sw_open = 0;
    if (!g_dump || g_npcs >= PS_NPC) return;
    if (kind == PS_END) { uint64_t d = gal_draw_count(); g_evpc_n[g_npcs][0] = d - g_mark_draws; g_evpc_n[g_npcs][1] = g_pstat_clears - g_mark_clears; g_mark_draws = d; g_mark_clears = g_pstat_clears; }
    void *bt[PS_DEPTH + 1]; int n = backtrace(bt, PS_DEPTH + 1);
    ps_ev *e = ev_push(); if (!e) return;
    memset(g_evpc[g_npcs], 0, sizeof g_evpc[0]); for (int i = 1; i < n; i++) g_evpc[g_npcs][i - 1] = bt[i];
    *e = (ps_ev){(uint8_t)kind, (uint8_t)(kind == PS_END ? g_sw_why : 0), (uint8_t)(kind == PS_END ? g_sw_dep : 0), 0, UINT32_MAX, (uint64_t)g_npcs++};
}
static void dump_frame(uint64_t fr) {
    fprintf(g_dump, "F %llu\n", (unsigned long long)fr);
    for (int i = 0; i < g_nev; i++) {
        const ps_ev *e = &g_ev[i];
        switch (e->kind) {
        case PS_PASS: fputs("P\n", g_dump); break;
        case PS_ATT: fprintf(g_dump, "A %u %u %llu %u %08x\n", e->root, e->clear, (unsigned long long)e->bytes, e->inpass, e->view); break;
        case PS_SAMPLE: fprintf(g_dump, "S %u %u %u\n", e->root, e->inpass, e->cs); break;
        case PS_READ: fprintf(g_dump, "R %u\n", e->root); break;
        default:
            // E 本遍绘制数 清屏辅助绘制数 切遍原因 依赖（见 gal_pstat.h SW_*）调用栈…
            if (e->kind == PS_END) fprintf(g_dump, "E %llu %llu %u %u", (unsigned long long)g_evpc_n[e->bytes][0], (unsigned long long)g_evpc_n[e->bytes][1], e->clear, e->inpass); else fputs("C", g_dump);
            for (int k = 0; k < PS_DEPTH && g_evpc[e->bytes][k]; k++) fprintf(g_dump, " %p", g_evpc[e->bytes][k]);
            fputc('\n', g_dump);
        }
    }
    fflush(g_dump);
}

// ---------- ② GPFIFO 命令段（服务线程提交时调，自带锁）----------
#define PG_SLOT (1u << 16)
#define SEG_SLOT (1u << 14)
static os_unfair_lock g_glock = OS_UNFAIR_LOCK_INIT;
static struct { uint64_t pg, hash; uint32_t gen; uint8_t used, same; } g_pg[PG_SLOT];
static struct { uint64_t hash; uint32_t glast, gprev; uint8_t used; } g_seg[SEG_SLOT];
static uint32_t g_npg, g_nseg;
static struct { uint64_t seg, bytes, seg_same, bytes_same, seg_csame, bytes_csame, bytes_tracked, seg_skip, bytes_skip, pg_full; int track_unknown; } g_gf;

__attribute__((weak)) int s2a_track_sub_state(uint64_t addr) { (void)addr; return -1; }

static uint64_t mix(uint64_t h, uint64_t v) { return (h ^ v) * 0x100000001b3ull; }
static uint64_t hash_bytes(uint64_t h, const uint8_t *p, uint64_t n) {
    uint64_t i = 0;
    for (; i + 8 <= n; i += 8) { uint64_t v; memcpy(&v, p + i, 8); h = mix(h, v); }
    for (; i < n; i++) h = mix(h, p[i]);
    return h;
}
// 这页（4 KB）内容与它上次被提交时相同？本帧已判过的沿用本帧结论；第一次见到的算变了
static int page_same(uint64_t pg, uint32_t gen) {
    uint32_t h = (uint32_t)(pg * 0x9E3779B97F4A7C15ull >> 40) & (PG_SLOT - 1);
    for (uint32_t k = 0; k < PG_SLOT; k++, h = (h + 1) & (PG_SLOT - 1)) {
        if (!g_pg[h].used) {
            if (g_npg >= PG_SLOT / 4 * 3) { g_gf.pg_full++; return 0; }
            g_npg++; g_pg[h].used = 1; g_pg[h].pg = pg; g_pg[h].gen = gen; g_pg[h].same = 0;
            g_pg[h].hash = hash_bytes(0xcbf29ce484222325ull, (const uint8_t *)(uintptr_t)(pg << 12), 4096);
            return 0;
        }
        if (g_pg[h].pg != pg) continue;
        if (g_pg[h].gen == gen) return g_pg[h].same;
        uint64_t x = hash_bytes(0xcbf29ce484222325ull, (const uint8_t *)(uintptr_t)(pg << 12), 4096);
        g_pg[h].same = x == g_pg[h].hash; g_pg[h].hash = x; g_pg[h].gen = gen;
        return g_pg[h].same;
    }
    return 0;
}
// 段内容在前 2 帧内出现过？（与地址无关）
static int seg_seen(uint64_t hash, uint32_t gen) {
    uint32_t h = (uint32_t)(hash >> 40) & (SEG_SLOT - 1);
    for (uint32_t k = 0; k < SEG_SLOT; k++, h = (h + 1) & (SEG_SLOT - 1)) {
        if (!g_seg[h].used) {
            if (g_nseg >= SEG_SLOT / 4 * 3) return 0;
            g_nseg++; g_seg[h].used = 1; g_seg[h].hash = hash; g_seg[h].glast = gen; g_seg[h].gprev = 0; return 0;
        }
        if (g_seg[h].hash != hash) continue;
        if (g_seg[h].glast != gen) { g_seg[h].gprev = g_seg[h].glast; g_seg[h].glast = gen; }
        uint32_t before = g_seg[h].gprev;
        return before && before < gen && gen - before <= 2;
    }
    return 0;
}
// ranges：n 对（CPU 地址, 长度），段在 CPU 侧的连续片（C# 侧按 GPU 页翻译、合并）；n < 0 = 段没法统计（有未映射页 / 片太多），只计入「未统计」
NXGAL_API void nxgal_pstat_seg(const uint64_t *ranges, int32_t n, uint64_t total) {
    if (!PSTAT_ON()) return;
    os_unfair_lock_lock(&g_glock);
    uint32_t gen = atomic_load(&g_gen) + 1;
    if (n < 0) { g_gf.seg_skip++; g_gf.bytes_skip += total; os_unfair_lock_unlock(&g_glock); return; }
    uint64_t same_b = 0, trk_b = 0, h = 0xcbf29ce484222325ull;
    int all = 1;
    for (int32_t i = 0; i < n; i++) {
        uint64_t a = ranges[2 * i], len = ranges[2 * i + 1], end = a + len;
        h = hash_bytes(h, (const uint8_t *)(uintptr_t)a, len);
        for (uint64_t pg = a >> 12; pg <= (end - 1) >> 12 && len; pg++) {
            uint64_t lo = pg << 12 > a ? pg << 12 : a, hi = (pg + 1) << 12 < end ? (pg + 1) << 12 : end, ob = hi - lo;
            if (page_same(pg, gen)) same_b += ob; else all = 0;
            int ts = s2a_track_sub_state(pg << 12);
            if (ts < 0) g_gf.track_unknown = 1; else if (ts) trk_b += ob;
        }
    }
    g_gf.seg++; g_gf.bytes += total; g_gf.bytes_same += same_b; g_gf.bytes_tracked += trk_b;
    if (all) g_gf.seg_same++;
    if (seg_seen(h, gen)) { g_gf.seg_csame++; g_gf.bytes_csame += total; }
    os_unfair_lock_unlock(&g_glock);
}

// ---------- 帧界（出图时，渲染线程）----------
// 两遍合一次数（gal_pass.m，NXGAL_PASS_MERGE）；单测不链渲染器：弱符号
__attribute__((weak)) uint64_t g_pass_merged;
static uint64_t g_merged_last;
static double pct(uint64_t a, uint64_t b) { return b ? 100.0 * (double)a / (double)b : 0; }
void gal_pstat_frame(void) {
    g_frame_total++;
    if (g_trunc) g_tframes++;
    else { gal_pstat_analyze(g_ev, g_nev, g_nroot, g_scratch, &g_acc); g_frames++; }
    if (g_dump && g_frame_total >= g_dump_lo && g_frame_total <= g_dump_hi) dump_frame(g_frame_total);
    g_npcs = 0;
    g_nev = 0; g_trunc = 0; g_nroot = 0; g_rpass = 0; g_rgen++;
    atomic_fetch_add(&g_gen, 1);
    if (g_frame_total % g_every) return;
    os_unfair_lock_lock(&g_glock);
    __typeof__(g_gf) gf = g_gf; memset(&g_gf, 0, sizeof g_gf);
    os_unfair_lock_unlock(&g_glock);
    const ps_res *a = &g_acc; double F = g_frames ? (double)g_frames : 1, M = 1048576.0, G = (double)g_every;
    fprintf(stderr, "[gal] 遍统计（NXGAL_PSTAT）到第 %llu 帧：近 %llu 帧算账 %llu 帧、截断 %llu 帧｜每帧 遍 %.1f、附件存回 %.1f 次 %.2f MB、读入 %.1f 次 %.2f MB"
        "｜可省存回：先被清 %.1f 次 %.2f MB、本帧后不再读 %.1f 次 %.2f MB（合计 %.1f / %.1f 次）｜相邻遍续用同一附件 %.1f 次（存回 %.2f MB + 读入 %.2f MB；其中同视图 %.1f 次 存回 %.2f MB，其余为同贴图不同 mip / 层）"
        "｜写→下一遍采样 相邻遍对 %.1f / 遍 %.1f｜两遍合一 %.2f 次"
        "｜GPFIFO 每帧 %.1f 段 %.1f KB：页未变 字节 %.1f%% 段 %.1f%%；段内容同前 2 帧 字节 %.1f%% 段 %.1f%%；写跟踪覆盖字节 %s%.1f%%；未统计 %llu 段 %llu KB%s\n",
        (unsigned long long)g_frame_total, (unsigned long long)g_every, (unsigned long long)g_frames, (unsigned long long)g_tframes,
        a->passes / F, a->st_n / F, a->st_bytes / F / M, a->ld_n / F, a->ld_bytes / F / M,
        a->clr_n / F, a->clr_bytes / F / M, a->dead_n / F, a->dead_bytes / F / M, (a->clr_n + a->dead_n) / F, a->st_n / F,
        a->adj_n / F, a->adj_st_bytes / F / M, a->adj_ld_bytes / F / M, a->adj_same_n / F, a->adj_same_st_bytes / F / M,
        a->pairs / F, a->passes / F, (double)(g_pass_merged - g_merged_last) / G,
        gf.seg / G, gf.bytes / G / 1024.0, pct(gf.bytes_same, gf.bytes), pct(gf.seg_same, gf.seg), pct(gf.bytes_csame, gf.bytes), pct(gf.seg_csame, gf.seg),
        gf.track_unknown ? "（查询不可用）" : "", pct(gf.bytes_tracked, gf.bytes), (unsigned long long)gf.seg_skip, (unsigned long long)(gf.bytes_skip / 1024),
        gf.pg_full ? "；【红】页表满，部分页按变了算" : "");
    memset(&g_acc, 0, sizeof g_acc); g_frames = 0; g_tframes = 0; g_merged_last = g_pass_merged;
}

// GAL Metal 后端：渲染目标、渲染通道开合、清屏（第 5 块的通道部分；管线状态另在 gal_state.m）。
// 通道：SetRenderTargets 只记目标；第一次绘制 / 清屏时按需开通道（附件 load = Load、store = Store）。
// 清屏（语义同 Ryujinx Vulkan 后端：受剪裁框 0、写掩码、层范围约束）：
//   ① 通道还没开、清整个附件（剪裁框盖满、掩码全开、层全清）→ 挂成该附件的 load = Clear，开通道时落实（最省带宽，TBDR 上不读旧内容）；
//   ② 其他情况 → 通道内画全屏三角（辅助着色器），剪裁 / 写掩码 / 模板写掩码进状态，层用实例号写 render_target_array_index。
// 整数格式的清屏颜色：GAL 给的是浮点寄存器值，按位当整数用（同 Vulkan 后端 ClearColorValue 的联合体语义）。
#import "gal_draw_internal.h"
#include "gal_pstat.h"
#include <limits.h>
#include <math.h>
#include <string.h>

GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
uint32_t g_genc_serial;
static struct {
    uint32_t color[8]; int ncolor; uint32_t depth;
    int open;                        // 通道开着（当前渲染编码器属于这组目标）
    int w, h, layers;                // 通道尺寸（附件最小值）
} g_rt;
// 挂起的整附件清屏（10-19 起挂在贴图上，不挂在当前目标组上）：换目标组不再立刻开空通道落实，等这张贴图下次当附件时用 load = Clear 吃掉；
// 在那之前被别的方式用到才单独开一遍落实，且只落实被用到的那张（按底层 root 匹配，视图共享存储也算）：绘制 / 派发要采样或当图像用（开编码器前）、
// 贴图读回 / 写入 / 拷贝 / 换存储 / 释放（gal_tex.m 入口）、出图源（gal_present.m）。换目标组、开拷贝编码器、提交都不落实——挂起可以跨命令缓冲、跨帧。真机岛上重场景每帧约 11 个空清屏遍，
// 每个存回整张、回来再读整张（主颜色目标 2346×1080×8 字节 = 19.8 MB 一次），约 57 MB / 帧
typedef struct { uint32_t tid; void *root; int color; double rgba[4]; int d, s; double depth; uint32_t stencil; } pclr;
static pclr g_pc[32]; static int g_npc;
static int pc_find(uint32_t tid) { for (int i = 0; i < g_npc; i++) if (g_pc[i].tid == tid) return i; return -1; }
static pclr *pc_get(uint32_t tid, gal_tex *t) {
    int k = pc_find(tid); if (k >= 0) return &g_pc[k];
    if (g_npc == 32) return NULL;
    g_pc[g_npc] = (pclr){tid, (__bridge void *)t->root}; return &g_pc[g_npc++];
}
static void pc_drop(int k) { g_pc[k] = g_pc[--g_npc]; }
nxgal_rect g_scissors[16] = {{0, 0, 0xffff, 0xffff}}; int g_nscissors = 1; uint32_t g_scissor_serial;
#define g_scissor0 g_scissors[0]

static int g_texbar;   // TextureBarrier 挂起（见 gal_core.m nxgal_barrier）
// 深度模板「内存那份 = 片上那份」：开遍时深度（与模板）都从内存载入（不是以清开遍），且本遍还没有绘制 / 遍内清屏写过深度模板。
// 此时 TextureBarrier 之后采样深度附件读到的就是最新值，不必收遍（gal_draw.m texbar_ds_inplace；怪猎村子每帧 97 次软粒子采样深度，99% 属此类）
static int g_ds_mem;
// 内存屏障挂起（Barrier / CommandBufferBarrier 落在开着的遍里，见 gal_core.m nxgal_barrier）与本遍已有存储写（存储缓冲可写 / 图像）：通道结束即清
static int g_membar, g_pass_swr;
// 两遍合一（缺省开，NXGAL_PASS_MERGE=0 关；帧率能耗线 10-21：九款录像合并关 / 开画面差都在回放噪声内，暗黑3 每帧省 2 遍、丝之歌 3 遍）：换目标组时，新组能在开着的这一遍里接着画就不收遍——
// 省掉两遍之间续用附件的整张存回 + 读入（iPhone 上是片外带宽）。现做的一类（最稳、不改着色器）：深度模板附件不变（都有且同一张，或都没有）、
// 新组的每个颜色槽要么与开遍时同一张贴图、要么空（暗黑3 每帧 2 次「颜色 + 深度 → 只剩深度」；塞尔达每帧上百次换组里过半是无深度的后处理遍）。
// 开遍时的附件（物理组）记在 g_ph；逻辑组（游戏当前设的）仍在 g_rt。物理组里逻辑组没有的颜色附件 = 隐藏附件：还在片上、没存回，
// 本遍里的绘制要采样它就先收遍（gal_pass_hidden_hit），拷贝 / 读回 / 派发本来就收遍。比较用 MTLTexture 指针（同号换对象不会误判同一张）
static int g_merge = -1;
// 隐藏槽在管线里仍按物理格式出现、写掩码为 0、不混合（gal_pass_formats / gal_pass_hidden_mask → gal_state.m 管线键；清屏管线同），管线与遍的附件格式逐槽一致
static struct { const void *color[8], *root[8], *depth; MTLPixelFormat fmt[8]; uint32_t hidden; } g_ph;
uint64_t g_pass_merged;
static int merge_on(void) { if (g_merge < 0) { const char *v = getenv("NXGAL_PASS_MERGE"); g_merge = !(v && *v == '0'); } return g_merge; }
// 续用判定（按遍汇总诊断 pass_agg，gal_core.m）：本遍与上一遍的附件根（颜色 8 槽 + 深度），1 = 完全相同，2 = 部分共用，0 = 无关
static const void *g_sig_cur[9], *g_sig_prev[9];
int g_pass_cont;
static void on_enc_end_sig(void) { memcpy(g_sig_prev, g_sig_cur, sizeof g_sig_prev); memset(g_sig_cur, 0, sizeof g_sig_cur); }
static void on_enc_end(void) { on_enc_end_sig(); g_rt.open = 0; g_texbar = 0; g_membar = 0; g_pass_swr = 0; g_ds_mem = 0; memset(&g_ph, 0, sizeof g_ph); }
void gal_pass_ds_written(void) { g_ds_mem = 0; }
int gal_pass_ds_mem(void) { return g_ds_mem && g_rt.open; }
// root 是当前目标组的某个颜色附件（不含深度模板）
int gal_pass_is_color_attachment(id<MTLTexture> root) {
    if (!root) return 0;
    for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); if (t && t->root == root) return 1; }
    return 0;
}
void gal_pass_texbar_arm(void) { g_texbar = 1; }
void gal_pass_membar_arm(void) { g_membar = 1; }
// 挂起的内存屏障要不要在这次绘制前拆遍：屏障前本遍有存储写（写后读 / 写后写），或这次绘制有存储写（屏障前的读 → 之后的写）。
// 两边都没有：屏障两侧没有遍内的存储访问冲突，遍外的写已由编码器之间的全序屏障保证——不拆
int gal_pass_membar_split(int draw_swr) { return g_membar && g_rt.open && (g_pass_swr || draw_swr); }
void gal_pass_note_swr(void) { g_pass_swr = 1; }
int gal_pass_swr(void) { return g_rt.open && g_pass_swr; }
int gal_pass_texbar_armed(void) { return g_texbar && g_rt.open; }
// 当前目标组颜色槽 slot 的附件视图（没有 = nil）：帧缓冲读取判整张视图 / 格式用（gal_draw.m）
id<MTLTexture> gal_pass_color_tex(int slot) {
    if (slot < 0 || slot >= g_rt.ncolor) return nil;
    gal_tex *t = gal_tex_get(g_rt.color[slot]); return t ? t->tex : nil;
}
// root 是当前目标组的第几个颜色附件（0–7）/ 深度模板（8）/ 不是（-1）：诊断用（gal_draw.m NXGAL_TEXBAR_WHY）
int gal_pass_attachment_slot(id<MTLTexture> root) {
    if (!root) return -1;
    for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); if (t && t->root == root) return i; }
    gal_tex *d = gal_tex_get(g_rt.depth); return d && d->root == root ? 8 : -1;
}
int gal_pass_is_attachment(id<MTLTexture> root) {
    if (!root) return 0;
    for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); if (t && t->root == root) return 1; }
    gal_tex *d = gal_tex_get(g_rt.depth); return d && d->root == root;
}
int gal_pass_hidden_any(void) { return g_ph.hidden != 0; }
uint32_t gal_pass_hidden_mask(void) { return g_ph.hidden; }
int gal_pass_hidden_hit(id<MTLTexture> root) {
    if (!g_ph.hidden || !root) return 0;
    for (int i = 0; i < 8; i++) if ((g_ph.hidden >> i & 1) && g_ph.root[i] == (__bridge const void *)root) return 1;
    return 0;
}
// 3D 目标的层数 = 深度（同 Ryujinx Vulkan 后端：3D 渲染目标按 2D 数组视图挂、帧缓冲层数 = 深度；顶点着色器写层号选深度切片）。
// 原先 3D 恒按 1 层：层号被忽略，各切片全画到第 0 片（10-18 八方2 设定页：虚幻 4 的 32³ 调色查找表 32 片叠进第 0 片，背景整页发亮）
static int tex_layer_count(gal_tex *t) { return t->tex.textureType == MTLTextureType3D ? (int)t->tex.depth : (int)t->tex.arrayLength * (t->info.target == 7 || t->info.target == 8 ? 6 : 1); }

// 通道尺寸缓存：只在目标组变（rt_apply）或贴图建 / 放 / 换存储（同号可能换成别的尺寸）时重算。原先每次绘制都遍历附件取贴图重算
// （10-19 真机热机渲染线程 gal_pass_info 3.6% + rt_size 3.5%，含子调用）
static int g_rt_dirty = 1, g_rt_hd, g_rt_hs;
uint64_t g_pass_targetless;   // 无附件开遍次数（单测 / 诊断读）
static void rt_size(void);
void gal_pass_rt_dirty(void) { g_rt_dirty = 1; }
// 无附件渲染（只写缓冲 / 只靠副作用的绘制）：Metal 用 renderTargetWidth / Height 定光栅范围（MTLRenderPassDescriptor 无附件渲染）。
//   宽高 = 各视口覆盖的范围（右下角取整，至少 1、至多 16384），同 Ryujinx Metal 后端 targetless（按视口）与 MoltenVK（按渲染区）；
//   旧做法宽高按 1，剪裁被钳成 1×1，绘制只出 1 个像素的片元（怪猎 mhrise_1021215739_2）。
//   视口在通道开着时变大 → gal_pass_targetless_fit 收遍、按新视口重开（只增不减：开着的通道够大就续用）
static int g_rt_tl;   // 当前目标组无任何附件
static void tl_extent(int *w, int *h) {
    double x1 = 1, y1 = 1;
    for (int i = 0; i < g_gs.nvp && i < 16; i++) {
        const nxgal_viewport *v = &g_gs.vp[i];
        double a = v->x + (v->w > 0 ? v->w : 0), b = v->y + (v->h > 0 ? v->h : 0);   // 负宽高（翻转视口）覆盖 [x + w, x]：右下角仍是 x
        if (a > x1) x1 = a; if (b > y1) y1 = b;
    }
    *w = x1 > 16384 ? 16384 : (int)ceil(x1); *h = y1 > 16384 ? 16384 : (int)ceil(y1);
}
int gal_pass_targetless_fit(void) {
    rt_size(); if (!g_rt_tl) return 0;
    int w, h; tl_extent(&w, &h);
    if (w <= g_rt.w && h <= g_rt.h) return 0;
    if (g_rt.open) { int kind; gal_cur_enc(&kind); if (kind == 1) gal_enc_end(); g_rt.open = 0; }
    g_rt_dirty = 1; rt_size();
    return 1;
}
static void rt_size(void) {
    if (!g_rt_dirty) return;
    g_rt_dirty = 0;
    { gal_tex *d = gal_tex_get(g_rt.depth); int ds = d ? gal_fmt_is_ds(d->info.format) : 0; g_rt_hd = (ds & 1) != 0; g_rt_hs = (ds & 2) != 0; }
    int w = 1 << 30, h = 1 << 30, L = 1 << 30, any = 0;
    for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); if (!t) continue; any = 1;
        if ((int)t->tex.width < w) w = (int)t->tex.width; if ((int)t->tex.height < h) h = (int)t->tex.height; int l = tex_layer_count(t); if (l < L) L = l; }
    gal_tex *d = gal_tex_get(g_rt.depth);
    if (d) { any = 1; if ((int)d->tex.width < w) w = (int)d->tex.width; if ((int)d->tex.height < h) h = (int)d->tex.height; int l = tex_layer_count(d); if (l < L) L = l; }
    g_rt_tl = !any;
    if (!any) { tl_extent(&w, &h); L = 1; }
    g_rt.w = w; g_rt.h = h; g_rt.layers = L;
}

// ---------- 本遍贴图用法戳（帧级调度：落实挂起清屏能否挪到遍前段）----------
// 写参数时（gal_draw.m tex_value，参数集复用限同一遍，每遍第一次绘制都会写）给贴图底层存储打本遍序号；2048 桶 × 4 路，旧遍的条目直接覆盖。
// 本遍一个桶 4 路都占满 = 溢出：本遍剩下的查询一律按「用过」（保守，只是少挪）
#define TU_B 2048
static struct { const void *k[4]; uint64_t s[4]; uint8_t wr[4]; } g_tu[TU_B];   // wr：本遍当图像绑过（按写算）
static uint64_t g_tu_over;   // 溢出的那一遍的序号
static uint32_t tu_hash(const void *k) { return (uint32_t)(((uintptr_t)k >> 4) * 0x9E3779B1u) & (TU_B - 1); }
void gal_pass_tex_note(id<MTLTexture> root, int write) {
    if (!root) return;
    uint64_t ps = gal_pass_serial(); const void *k = (__bridge const void *)root; uint32_t h = tu_hash(k); int free_ = -1;
    for (int w = 0; w < 4; w++) { if (g_tu[h].k[w] == k && g_tu[h].s[w] == ps) { g_tu[h].wr[w] |= (uint8_t)(write != 0); return; } if (g_tu[h].s[w] != ps && free_ < 0) free_ = w; }
    if (free_ < 0) { g_tu_over = ps; return; }
    g_tu[h].k[free_] = k; g_tu[h].s[free_] = ps; g_tu[h].wr[free_] = (uint8_t)(write != 0);
}
int gal_pass_tex_used(id<MTLTexture> root) {
    if (!root) return 0;
    uint64_t ps = gal_pass_serial(); if (g_tu_over == ps || gal_pass_is_attachment(root)) return 1;
    const void *k = (__bridge const void *)root; uint32_t h = tu_hash(k);
    for (int w = 0; w < 4; w++) if (g_tu[h].k[w] == k && g_tu[h].s[w] == ps) return 1;
    return 0;
}
int gal_pass_tex_written(id<MTLTexture> root) {
    if (!root) return 0;
    uint64_t ps = gal_pass_serial(); if (g_tu_over == ps || gal_pass_is_attachment(root)) return 1;
    const void *k = (__bridge const void *)root; uint32_t h = tu_hash(k);
    for (int w = 0; w < 4; w++) if (g_tu[h].k[w] == k && g_tu[h].s[w] == ps) return g_tu[h].wr[w];
    return 0;
}
// 清屏遍挪到遍前段的次数（单测 / 诊断）；没挪的原因 [0] 没开渲染遍 [1] 被清的贴图本遍用过 [2] 遍前段没开
uint64_t g_pclr_pre, g_pclr_why[3];
static void pc_materialize(int k) {
    pclr c = g_pc[k]; pc_drop(k);
    gal_tex *t = gal_tex_get(c.tid); if (!t) return;
    // 帧级调度（帧率能耗线 10-21；NXGAL_PREPASS_OFF=1 退回）：渲染遍开着、被清的贴图本遍没用过（不是本遍附件、本遍没采样 / 当图像），
    // 清屏挪到本遍之前（遍前段里单独一遍），本遍不收。遍前段没开就记「想要」，这次照旧收遍
    int kind; gal_cur_enc(&kind);
    int pre = kind == 1 && !gal_pass_tex_used(t->root);
    if (pre) gal_prepass_want(); else g_pclr_why[kind == 1]++;
    MTL4RenderPassDescriptor *d = gal_be_pass_desc();
    if (c.color) { MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[0]; a.texture = t->tex; a.loadAction = MTLLoadActionClear; a.storeAction = MTLStoreActionStore;
        a.clearColor = MTLClearColorMake(c.rgba[0], c.rgba[1], c.rgba[2], c.rgba[3]); }
    else { int ds = gal_fmt_is_ds(t->info.format);
        if (ds & 1) { d.depthAttachment.texture = t->tex; d.depthAttachment.storeAction = MTLStoreActionStore; d.depthAttachment.loadAction = c.d ? MTLLoadActionClear : MTLLoadActionLoad; d.depthAttachment.clearDepth = c.depth; }
        if (ds & 2) { d.stencilAttachment.texture = t->tex; d.stencilAttachment.storeAction = MTLStoreActionStore; d.stencilAttachment.loadAction = c.s ? MTLLoadActionClear : MTLLoadActionLoad; d.stencilAttachment.clearStencil = c.stencil; } }
    d.renderTargetWidth = t->tex.width; d.renderTargetHeight = t->tex.height;
    int L = tex_layer_count(t); if (L > 1) d.renderTargetArrayLength = L;
    if (pre) {
        id e = gal_prepass_render(d);
        if (e) { [e endEncoding]; g_pclr_pre++; return; }   // 只清不画：不记遍统计（它不在本遍序列里）、不挂可见性计数
        g_pclr_why[2]++;
    }
    if (kind) gal_enc_end();   // 当前编码器（可能是开着的别的通道）先收
    gal_cnt_on_pass_begin(d);
    gal_render_begin_desc(d);
    { extern uint32_t g_pass_w, g_pass_h, g_pass_fmt, g_pass_kind; extern uint64_t g_pass_st; g_pass_w = (uint32_t)t->tex.width; g_pass_h = (uint32_t)t->tex.height;
      g_pass_fmt = (uint32_t)t->info.format; g_pass_kind = 1; g_pass_st += (uint64_t)t->tex.width * t->tex.height * L * t->info.bpp; }
    // 遍统计（NXGAL_PSTAT）：落实清屏的空遍 = 以清开遍、存回整张。深度模板只清了一个面时按读入算
    if (PSTAT_ON()) { gal_pstat_pass(); gal_pstat_att((__bridge void *)t->root, c.color || ((!(gal_fmt_is_ds(t->info.format) & 1) || c.d) && (!(gal_fmt_is_ds(t->info.format) & 2) || c.s)),
        (uint64_t)t->tex.width * t->tex.height * L * t->info.bpp, c.color ? 0 : 8, gal_pstat_view((__bridge void *)t->tex, 0, 0)); }
    { SW_SCOPE(SW_CLEAR, 2); gal_enc_end(); }   // 调度测算：独立的清屏遍收尾 = 遍边界，不是切开别的遍
    g_genc_serial++;
}
// 绘制 / 派发要采样或当图像用 root 这张贴图（开编码器之前调）：它有挂起清屏就先落实
void gal_pass_clears_touch(id<MTLTexture> root) {
    if (!g_npc || !root) return;
    for (int k = g_npc - 1; k >= 0; k--) if (g_pc[k].root == (__bridge void *)root) pc_materialize(k);
}
int gal_pass_clears_any(void) { return g_npc; }

// 挂起清屏与本组附件同一底层存储但不是同一个视图（帧率能耗线 10-21；NXGAL_PCLR_SPLIT=1 退回旧做法：一律单独一遍落实）：
//   ① 本组里有同号附件、另有同底层的别的视图（马车8：同一张数组贴图的第 0 / 1 层视图分别挂颜色槽 0 / 1）——原先后者把匹配盖成「别的视图」去单独落实；
//      改为同号的那个槽照常以清开遍，前提是同底层的其他附件视图与它不重叠（不同级、或层区间不相交）；
//   ② 本组里没有同号附件，挂起清屏的视图（单层）落在某个附件视图（整个数组）的层区间里（马车8：阴影深度数组按层清、按整组画；
//      后处理颜色数组同理）——开遍照常读入，遍内第一条命令按层画清屏三角（同 nxgal_clear_color 的遍内清屏），不再单独开一遍清屏 + 存回整层。
//      条件：同级、同像素格式、该附件视图尺寸 = 通道尺寸（清满整层），且同底层的其他附件不碰这些层。
//   同底层另有重叠视图的挂起清屏时照旧单独落实（谁先谁后表里没有）。
// 返回：-2 不是本组附件；≥ 0 / 8 以清开遍的槽；-1 单独落实；≤ -10 遍内补画（槽 = -10 - 返回值，*layer0 = 在附件视图里的起始层）
static int pclr_split(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_PCLR_SPLIT"); v = e && *e == '1'; } return v; }
static int views_overlap(const gal_tex *a, const gal_tex *b) {
    if (a->base_level != b->base_level) return 0;
    int la = tex_layer_count((gal_tex *)a), lb = tex_layer_count((gal_tex *)b);
    return a->base_layer < b->base_layer + lb && b->base_layer < a->base_layer + la;
}
static int pc_resolve(int k, int *layer0) {
    gal_tex *pt = gal_tex_get(g_pc[k].tid);
    int exact = -1, cover = -1, others = 0, any = 0;
    // 同底层另有重叠的挂起清屏：先后次序不在表里（pc_drop 换位），并入会改变谁盖谁——照旧单独落实
    for (int j = 0; j < g_npc; j++) { gal_tex *o = j != k && g_pc[j].root == g_pc[k].root ? gal_tex_get(g_pc[j].tid) : NULL; if (o && (!pt || views_overlap(o, pt))) others++; }
    for (int i = 0; i <= 8; i++) {
        uint32_t id = i < 8 ? (i < g_rt.ncolor ? g_rt.color[i] : 0) : g_rt.depth;
        gal_tex *t = id ? gal_tex_get(id) : NULL;
        if (!t || (__bridge void *)t->root != g_pc[k].root) continue;
        any = 1;
        if (id == g_pc[k].tid) { exact = i; continue; }
        if (!pt || !views_overlap(t, pt)) continue;
        if (cover < 0 && t->base_level == pt->base_level && t->tex.pixelFormat == pt->tex.pixelFormat && (i == 8) == !g_pc[k].color
            && t->base_layer <= pt->base_layer && pt->base_layer + tex_layer_count(pt) <= t->base_layer + tex_layer_count(t)
            && (int)t->tex.width == g_rt.w && (int)t->tex.height == g_rt.h) cover = i;
        else others++;
    }
    if (!any) return -2;
    if (exact >= 0) return others || cover >= 0 ? -1 : exact;
    if (cover >= 0 && !others) { *layer0 = pt->base_layer - gal_tex_get(cover < 8 ? g_rt.color[cover] : g_rt.depth)->base_layer; return -10 - cover; }
    return -1;
}
int g_icnt_hook;   // 下一次开遍是真正的绘制遍（不是出图 / 贴图清除等内部遍）：开遍时做间接计数预整理（gal_icnt_prebegin）
static void pc_inpass(const pclr *c, int slot, int layer0, int layers);
id<MTL4RenderCommandEncoder> gal_render_enc(void) {
    int kind; id e = gal_cur_enc(&kind);
    if (g_rt.open && kind == 1) return e;
    gal_on_enc_end = on_enc_end;
    rt_size();
    int eat[9]; for (int i = 0; i < 9; i++) eat[i] = -1;   // 0–7 颜色槽、8 深度模板：要吃掉的挂起清屏下标
    int ninp = 0; struct { pclr c; int slot, layer0, layers; } inp[8];   // 开遍后在遍内补画的挂起清屏（见 pc_resolve）
    if (g_npc) {
        for (int k = g_npc - 1; k >= 0; k--) {
            int slot = -2, layer0 = 0;
            if (pclr_split()) {
                for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); if (t && (__bridge void *)t->root == g_pc[k].root) slot = g_rt.color[i] == g_pc[k].tid ? i : -1; }
                gal_tex *dt0 = gal_tex_get(g_rt.depth); if (dt0 && (__bridge void *)dt0->root == g_pc[k].root) slot = g_rt.depth == g_pc[k].tid ? 8 : -1;
            } else slot = pc_resolve(k, &layer0);
            if (slot == -2) continue;                                            // 不是本组附件
            if (slot <= -10 && ninp < 8) { inp[ninp].c = g_pc[k]; inp[ninp].slot = -10 - slot; inp[ninp].layer0 = layer0; inp[ninp].layers = tex_layer_count(gal_tex_get(g_pc[k].tid)); ninp++; pc_drop(k); continue; }
            gal_tex *t = gal_tex_get(g_pc[k].tid);
            int fits = slot >= 0 && t && (int)t->tex.width == g_rt.w && (int)t->tex.height == g_rt.h && tex_layer_count(t) == g_rt.layers;
            if (!fits) pc_materialize(k);                                       // 别的视图 / 尺寸不同：单独一遍落实
        }
        for (int k = 0; k < g_npc; k++) {
            for (int i = 0; i < g_rt.ncolor; i++) if (g_rt.color[i] == g_pc[k].tid) eat[i] = k;
            if (g_rt.depth == g_pc[k].tid) eat[8] = k;
        }
    }
    MTL4RenderPassDescriptor *d = gal_be_pass_desc();
    int any = 0;
    for (int i = 0; i < g_rt.ncolor; i++) {
        gal_tex *t = gal_tex_get(g_rt.color[i]); if (!t) continue; any = 1;
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[i];
        a.texture = t->tex; a.storeAction = MTLStoreActionStore;
        if (eat[i] >= 0 && g_pc[eat[i]].color) { const double *c = g_pc[eat[i]].rgba; a.loadAction = MTLLoadActionClear; a.clearColor = MTLClearColorMake(c[0], c[1], c[2], c[3]); }
        else a.loadAction = MTLLoadActionLoad;
    }
    gal_tex *dt = gal_tex_get(g_rt.depth);
    if (dt) {
        any = 1;
        int ds = gal_fmt_is_ds(dt->info.format);
        const pclr *pc = eat[8] >= 0 && !g_pc[eat[8]].color ? &g_pc[eat[8]] : NULL;
        if (ds & 1) { d.depthAttachment.texture = dt->tex; d.depthAttachment.storeAction = MTLStoreActionStore;
            if (pc && pc->d) { d.depthAttachment.loadAction = MTLLoadActionClear; d.depthAttachment.clearDepth = pc->depth; } else d.depthAttachment.loadAction = MTLLoadActionLoad; }
        if (ds & 2) { d.stencilAttachment.texture = dt->tex; d.stencilAttachment.storeAction = MTLStoreActionStore;
            if (pc && pc->s) { d.stencilAttachment.loadAction = MTLLoadActionClear; d.stencilAttachment.clearStencil = pc->stencil; } else d.stencilAttachment.loadAction = MTLLoadActionLoad; }
        g_ds_mem = (ds & 1) && d.depthAttachment.loadAction == MTLLoadActionLoad && (!(ds & 2) || d.stencilAttachment.loadAction == MTLLoadActionLoad);
    }
    for (int k = g_npc - 1; k >= 0; k--) for (int i = 0; i < 9; i++) if (eat[i] == k) { pc_drop(k); break; }   // 已吃掉的删掉（倒序删，下标不乱）
    d.renderTargetWidth = g_rt.w; d.renderTargetHeight = g_rt.h;
    if (g_rt.layers > 1) d.renderTargetArrayLength = g_rt.layers;
    if (!any) { d.defaultRasterSampleCount = 1; g_pass_targetless++; }   // 无附件渲染：宽高按视口（rt_size / tl_extent）
    gal_cnt_on_pass_begin(d);
    g_icnt_hook = 1;
    e = gal_render_begin_desc(d);
    g_rt.open = 1; g_genc_serial++;
    {   int same = 1, share = 0, any = 0;
        for (int i = 0; i < 8; i++) { gal_tex *t = i < g_rt.ncolor && d.colorAttachments[i].texture ? gal_tex_get(g_rt.color[i]) : NULL; g_sig_cur[i] = t ? (__bridge const void *)t->root : NULL; }
        g_sig_cur[8] = dt ? (__bridge const void *)dt->root : NULL;
        for (int i = 0; i < 9; i++) { if (g_sig_cur[i]) any = 1; if (g_sig_cur[i] != g_sig_prev[i]) same = 0;
            for (int j = 0; j < 9 && g_sig_cur[i]; j++) if (g_sig_cur[i] == g_sig_prev[j]) share = 1; }
        g_pass_cont = any && same ? 1 : share ? 2 : 0; }
    // 两遍合一：记下开遍时的物理组（on_enc_end 已清）
    if (merge_on()) {
        for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); if (t && d.colorAttachments[i].texture) { g_ph.color[i] = (__bridge const void *)t->tex; g_ph.root[i] = (__bridge const void *)t->root; g_ph.fmt[i] = t->tex.pixelFormat; } }
        if (dt) g_ph.depth = (__bridge const void *)dt->tex;
    }
    { extern uint32_t g_pass_w, g_pass_h, g_pass_fmt, g_pass_kind; extern uint64_t g_pass_ld, g_pass_st; g_pass_w = (uint32_t)g_rt.w; g_pass_h = (uint32_t)g_rt.h; g_pass_kind = 1;
      gal_tex *t0 = gal_tex_get(g_rt.color[0]); g_pass_fmt = t0 ? (uint32_t)t0->info.format : 0xffff;
      // 附件读入 / 存回字节（TBDR 每遍边界的带宽账）：按通道尺寸 × 层 × 采样 × 每像素字节
      uint64_t px = (uint64_t)g_rt.w * g_rt.h * g_rt.layers;
      for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[i]; if (!t || !a.texture) continue;
          uint64_t b = px * t->info.bpp * (t->tex.sampleCount ? t->tex.sampleCount : 1); if (a.loadAction == MTLLoadActionLoad) g_pass_ld += b; if (a.storeAction != MTLStoreActionDontCare) g_pass_st += b; }
      if (dt) { uint64_t b = px * dt->info.bpp * (dt->tex.sampleCount ? dt->tex.sampleCount : 1);
          if (d.depthAttachment.texture ? d.depthAttachment.loadAction == MTLLoadActionLoad : d.stencilAttachment.loadAction == MTLLoadActionLoad) g_pass_ld += b; g_pass_st += b; } }
    // 遍统计（NXGAL_PSTAT）：本遍各附件（底层存储、读入动作、字节，口径同上）。深度模板两个面都是清才算清
    if (PSTAT_ON()) {
        gal_pstat_pass();
        uint64_t px = (uint64_t)g_rt.w * g_rt.h * g_rt.layers;
        for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[i]; if (!t || !a.texture) continue;
            gal_pstat_att((__bridge void *)t->root, a.loadAction == MTLLoadActionClear, px * t->info.bpp * (t->tex.sampleCount ? t->tex.sampleCount : 1), i,
                gal_pstat_view((__bridge void *)a.texture, (uint32_t)a.level, (uint32_t)a.slice)); }
        if (dt) {
            int ds = gal_fmt_is_ds(dt->info.format);
            int clr = (!(ds & 1) || d.depthAttachment.loadAction == MTLLoadActionClear) && (!(ds & 2) || d.stencilAttachment.loadAction == MTLLoadActionClear);
            MTLRenderPassAttachmentDescriptor *da = d.depthAttachment.texture ? (MTLRenderPassAttachmentDescriptor *)d.depthAttachment : (MTLRenderPassAttachmentDescriptor *)d.stencilAttachment;
            gal_pstat_att((__bridge void *)dt->root, clr, px * dt->info.bpp * (dt->tex.sampleCount ? dt->tex.sampleCount : 1), 8,
                gal_pstat_view((__bridge void *)da.texture, (uint32_t)da.level, (uint32_t)da.slice));
        }
    }
    for (int i = 0; i < ninp; i++) pc_inpass(&inp[i].c, inp[i].slot, inp[i].layer0, inp[i].layers);
    return e;
}


void gal_pass_close(void) { int kind; gal_cur_enc(&kind); if (kind == 1) gal_enc_end(); g_rt.open = 0; }


// 同一张贴图绑在多个颜色槽：TBDR 上每个附件是各自的片上副本，存回时互相覆盖（10-18 塞尔达神庙 G 缓冲槽 1 / 2 同为一张、槽 2 写掩码 0，
// 存回把槽 1 写的内容盖成旧值）。照 Ryujinx Vulkan 后端 PipelineBase.CreateFramebuffer（IsTBDR 时 filterWriteMasked）：重复的两槽里去掉写掩码为 0 的那个；
// 写掩码变了按原始请求重新生效（_framebufferUsingColorWriteMask）
static uint32_t g_rt_req[8]; static int32_t g_rt_nreq; static uint32_t g_rt_dreq; static int g_rt_dup;
// 两遍合一：新组（颜色 eff[0..n)、深度 dreq）能否在开着的遍里接着画（见 g_ph 注释）。
// 要求：深度模板附件是开遍时那一张（开遍时没有深度则新组也没有）；每个非空颜色槽与开遍时同槽同一张；通道尺寸 / 层数不变（通道尺寸 = 附件最小值，现在的 g_rt.w/h 就是开遍时的）；
// 新组附件没有挂起清屏（开遍时以清读入才能吃掉，接着画吃不掉）
// 诊断 NXGAL_MERGE_WHY=1（缺省关）：换目标组没合成时按原因计数，每 60 帧打一行（定下一类该做哪种合并用）
// 原因 0 开关关 1 遍没开 2 开遍无深度、新组有 3 不是渲染编码器 4 开遍有深度、新组无 5 深度换了 6 颜色槽换了 7 尺寸 / 层数变 8 挂起清屏
static int merge_why(void) { static int w = -1; if (w < 0) { const char *v = getenv("NXGAL_MERGE_WHY"); w = v && *v == '1'; } return w; }
static uint64_t g_mw[9], g_mw_frame, g_mw_tot, g_mws[9], g_mws_tot;
static int g_mw_shared;   // 本次换组的新组与开着的遍共用至少一张附件（合不成就是一次「续用同一附件」的存回 + 读入）
static int merge_fail(int r) {
    if (merge_why()) {
        g_mw[r]++; g_mw_tot++; if (g_mw_shared) { g_mws[r]++; g_mws_tot++; }
        if (g_gp_frame >= g_mw_frame + 60) {
            g_mw_frame = g_gp_frame;
            GLOG("[合并原因] 到第 %llu 帧累计没合成 %llu 次：开关关 %llu／遍没开 %llu／开遍无深度新组有 %llu／非渲染编码器 %llu／开遍有深度新组无 %llu／深度换了 %llu／颜色槽换了 %llu／尺寸层数变 %llu／挂起清屏 %llu",
                 (unsigned long long)g_gp_frame, (unsigned long long)g_mw_tot, (unsigned long long)g_mw[0], (unsigned long long)g_mw[1], (unsigned long long)g_mw[2], (unsigned long long)g_mw[3],
                 (unsigned long long)g_mw[4], (unsigned long long)g_mw[5], (unsigned long long)g_mw[6], (unsigned long long)g_mw[7], (unsigned long long)g_mw[8]);
            GLOG("[合并原因·共用附件] 其中新组与开遍共用附件 %llu 次：遍没开 %llu／开遍无深度新组有 %llu／非渲染编码器 %llu／开遍有深度新组无 %llu／深度换了 %llu／颜色槽换了 %llu／尺寸层数变 %llu／挂起清屏 %llu",
                 (unsigned long long)g_mws_tot, (unsigned long long)g_mws[1], (unsigned long long)g_mws[2], (unsigned long long)g_mws[3], (unsigned long long)g_mws[4],
                 (unsigned long long)g_mws[5], (unsigned long long)g_mws[6], (unsigned long long)g_mws[7], (unsigned long long)g_mws[8]);
        }
    }
    return 0;
}
static int merge_ok(const uint32_t *eff, int n, uint32_t dreq) {
    if (merge_why()) {
        g_mw_shared = 0;
        gal_tex *sd = gal_tex_get(dreq);
        if (g_rt.open && sd && (__bridge const void *)sd->tex == g_ph.depth) g_mw_shared = 1;
        for (int i = 0; g_rt.open && i < n; i++) { gal_tex *t = eff[i] ? gal_tex_get(eff[i]) : NULL; if (!t) continue; for (int j = 0; j < 8; j++) if (g_ph.color[j] && (__bridge const void *)t->tex == g_ph.color[j]) g_mw_shared = 1; }
    }
    if (!merge_on()) return merge_fail(0);
    if (!g_rt.open) return merge_fail(1);
    { int kind; gal_cur_enc(&kind); if (kind != 1) return merge_fail(3); }
    gal_tex *d = gal_tex_get(dreq);
    if (!d != !g_ph.depth) return merge_fail(d ? 2 : 4);
    if (d && (__bridge const void *)d->tex != g_ph.depth) return merge_fail(5);
    // 无深度：尺寸只由颜色槽定；新组一个颜色都没有时 w 留 INT_MAX，下面按尺寸变不合
    int w = d ? (int)d->tex.width : INT_MAX, h = d ? (int)d->tex.height : INT_MAX, L = d ? tex_layer_count(d) : INT_MAX;
    for (int i = 0; i < n; i++) {
        if (!eff[i]) continue;
        gal_tex *t = gal_tex_get(eff[i]);
        if (!t || (__bridge const void *)t->tex != g_ph.color[i]) return merge_fail(6);
        if ((int)t->tex.width < w) w = (int)t->tex.width;
        if ((int)t->tex.height < h) h = (int)t->tex.height;
        int l = tex_layer_count(t); if (l < L) L = l;
    }
    if (w != g_rt.w || h != g_rt.h || L != g_rt.layers) return merge_fail(7);
    for (int k = 0; k < g_npc; k++) {
        if (d && g_pc[k].root == (__bridge void *)d->root) return merge_fail(8);
        for (int i = 0; i < n; i++) { gal_tex *t = eff[i] ? gal_tex_get(eff[i]) : NULL; if (t && g_pc[k].root == (__bridge void *)t->root) return merge_fail(8); }
    }
    return 1;
}
// 换目标组计数（含两遍合一）：开遍预整理间接计数按「本帧第几个目标组」认遍（gal_core.m g_cur_grp）。切遍后接着画的那一段不换目标组、序号不变
uint32_t g_rt_group_seq;
static void rt_apply(int force) {
    uint32_t eff[8] = {0}; memcpy(eff, g_rt_req, g_rt_nreq * sizeof *eff); g_rt_dup = 0;
    for (int i = 0; i < g_rt_nreq; i++) {
        if (!eff[i]) continue;
        for (int j = 0; j < i; j++) if (g_rt_req[i] == g_rt_req[j] && g_rt_req[i]) {
            g_rt_dup = 1;
            if (!gal_state_color_mask(i)) eff[i] = 0;
            else if (!gal_state_color_mask(j)) eff[j] = 0;
        }
    }
    int same = g_rt_nreq == g_rt.ncolor && g_rt_dreq == g_rt.depth && !memcmp(eff, g_rt.color, g_rt_nreq * sizeof *eff);
    if (same && !force) return;
    if (same) return;
    g_rt_group_seq++;
    // 两遍合一：不收遍，只换逻辑组；物理组里逻辑组没有的颜色槽记成隐藏。g_genc_serial 变 → 绘制模块按新组重取管线 / 动态状态
    if (merge_ok(eff, g_rt_nreq, g_rt_dreq)) {
        memset(g_rt.color, 0, sizeof g_rt.color); memcpy(g_rt.color, eff, g_rt_nreq * sizeof *eff);
        g_rt.ncolor = g_rt_nreq; g_rt.depth = g_rt_dreq;
        g_rt_dirty = 1; rt_size();
        g_ph.hidden = 0;
        for (int i = 0; i < 8; i++) if (g_ph.color[i] && (i >= g_rt_nreq || !eff[i])) g_ph.hidden |= 1u << i;
        g_genc_serial++; g_pass_merged++;
        return;
    }
    { int kind; gal_cur_enc(&kind); if (kind == 1) gal_enc_end(); g_rt.open = 0; }   // 换目标组只收通道；挂起清屏留在贴图上（见 g_pc）
    memset(g_rt.color, 0, sizeof g_rt.color); memcpy(g_rt.color, eff, g_rt_nreq * sizeof *eff);
    g_rt.ncolor = g_rt_nreq; g_rt.depth = g_rt_dreq;
    g_rt_dirty = 1; rt_size();
}
void gal_pass_masks_changed(void) { if (g_rt_dup) { SW_SCOPE(SW_RT, 2); rt_apply(0); } }
// 诊断 NXGAL_RT_DIMS=1（帧率能耗线 10-23，动态分辨率是否在动）：每帧记用到的颜色目标尺寸集合（宽 ≥ 256 的，去重排序，最多 16 种），
// 与上一帧集合不同就打一行（[分辨率] 帧 N 目标尺寸 W×H …）。塞尔达场景缓冲按动态分辨率每帧定尺寸，缩放时集合里会出现新尺寸
#define RTD_MAX 16
static int g_rtd_on = -1; static uint32_t g_rtd[RTD_MAX], g_rtd_prev[RTD_MAX]; static int g_rtd_n, g_rtd_pn; static uint64_t g_rtd_frame;
static void rtd_note(uint32_t tid) {
    gal_tex *t = tid ? gal_tex_get(tid) : NULL; if (!t || t->info.width < 256) return;
    uint32_t k = (uint32_t)t->info.width << 16 | (uint32_t)(t->info.height & 0xffff);
    int i = 0; while (i < g_rtd_n && g_rtd[i] < k) i++;
    if (i < g_rtd_n && g_rtd[i] == k) return;
    if (g_rtd_n == RTD_MAX) return;
    memmove(g_rtd + i + 1, g_rtd + i, (size_t)(g_rtd_n - i) * sizeof *g_rtd); g_rtd[i] = k; g_rtd_n++;
}
void gal_rtd_frame_end(void) {
    if (g_rtd_on < 0) { const char *v = getenv("NXGAL_RT_DIMS"); g_rtd_on = v && v[0] == '1'; }
    if (!g_rtd_on) return;
    g_rtd_frame++;
    if (g_rtd_n != g_rtd_pn || memcmp(g_rtd, g_rtd_prev, (size_t)g_rtd_n * sizeof *g_rtd)) {
        char b[512]; int o = 0;
        for (int i = 0; i < g_rtd_n && o < (int)sizeof b - 24; i++) o += snprintf(b + o, sizeof b - (size_t)o, " %u×%u", g_rtd[i] >> 16, g_rtd[i] & 0xffff);
        GLOG("[分辨率] 帧 %llu 目标尺寸%s", (unsigned long long)g_rtd_frame, o ? b : " （无）");
    }
    memcpy(g_rtd_prev, g_rtd, sizeof g_rtd); g_rtd_pn = g_rtd_n; g_rtd_n = 0;
}

NXGAL_API void nxgal_set_render_targets(const uint32_t *colors, int32_t n, uint32_t depth) { GAL_API_LOCK(); if (g_uw_on) { for (int32_t k = 0; k < n; k++) gal_uw_write(colors[k]); gal_uw_write(depth); }
    SW_SCOPE(SW_RT, 2);   // 调度测算：换目标组 = 遍边界（同组遍跨遍合并离线另算）
    if (n > 8) n = 8;
    memset(g_rt_req, 0, sizeof g_rt_req); memcpy(g_rt_req, colors, n * sizeof *colors); g_rt_nreq = n; g_rt_dreq = depth;
    if (g_rtd_on) for (int32_t k = 0; k < n; k++) rtd_note(colors[k]);
    rt_apply(1);
}

NXGAL_API void nxgal_set_scissors(const nxgal_rect *rects, int32_t n) { GAL_API_LOCK();
    if (n > 16) n = 16;
    if (n > 0) { memcpy(g_scissors, rects, n * sizeof *rects); g_nscissors = n; g_scissor_serial++; }   // 绘制模块按 g_scissor_serial 变化重设剪裁
}

// 剪裁框 0 与通道尺寸求交；返回 0 = 交为空
static int clear_rect(MTLScissorRect *r) {
    int x0 = g_scissor0.x < 0 ? 0 : g_scissor0.x, y0 = g_scissor0.y < 0 ? 0 : g_scissor0.y;
    long x1 = (long)g_scissor0.x + g_scissor0.w, y1 = (long)g_scissor0.y + g_scissor0.h;
    if (x1 > g_rt.w) x1 = g_rt.w; if (y1 > g_rt.h) y1 = g_rt.h;
    if (x1 <= x0 || y1 <= y0) return 0;
    *r = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
    return 1;
}
static int covers_all(const MTLScissorRect *r) { return r->x == 0 && r->y == 0 && (int)r->width == g_rt.w && (int)r->height == g_rt.h; }

// ---------- 辅助着色器：全屏三角 + 按实例号选层 ----------
NSString *const k_clear_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct V { float4 pos [[position]]; uint layer [[render_target_array_index]]; };\n"
"struct P { float4 rgba; float depth; uint layer0; };\n"
"vertex V clr_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant P &p [[buffer(0)]]) {\n"
"  float2 uv = float2((vid << 1) & 2, vid & 2);\n"
"  V o; o.pos = float4(uv * 2.0 - 1.0, p.depth, 1.0); o.layer = p.layer0 + iid; return o; }\n"
// 片元按被清附件序号各一个（clr_fs_<f|u|i><0–7>，输出到 [[color(序号)]]）：10-21 前只有返回 color(0) 的一支，清第 1–7 个附件时写掩码开在那个附件、
//   着色器却不往它写，多颜色附件的局部清屏全部不生效（t_core「两个颜色附件」实测：附件 1 框内仍是旧色）
"#define CLR(T, S, I, E) struct O_##S##I { T c [[color(I)]]; }; fragment O_##S##I clr_fs_##S##I(V in [[stage_in]], constant P &p [[buffer(0)]]) { O_##S##I o; o.c = E; return o; }\n"
"#define CLR8(T, S, E) CLR(T, S, 0, E) CLR(T, S, 1, E) CLR(T, S, 2, E) CLR(T, S, 3, E) CLR(T, S, 4, E) CLR(T, S, 5, E) CLR(T, S, 6, E) CLR(T, S, 7, E)\n"
"CLR8(float4, f, p.rgba) CLR8(uint4, u, as_type<uint4>(p.rgba)) CLR8(int4, i, as_type<int4>(p.rgba))\n";
typedef struct { float rgba[4]; float depth; uint32_t layer0; uint32_t pad[2]; } clr_params;

static id<MTLLibrary> g_clr_lib;
static id<MTL4ArgumentTable> g_clr_vt, g_clr_ft;
// 管线缓存：键 = 各附件格式 + 采样数 + 被写附件 + 写掩码 + 分量类型（深度模板清屏 index = -1）
typedef struct { MTLPixelFormat cf[8]; MTLPixelFormat df, sf; NSUInteger samples; int index; uint32_t mask; int ctype; } clr_key;
typedef struct { clr_key k; id<MTLRenderPipelineState> p; } clr_ent;
static clr_ent *g_clr_cache; static int g_nclr;

static int clr_init(void) {
    if (g_clr_lib) return 1;
    NSError *e = nil;
    g_clr_lib = gal_helper_lib(GH_CLEAR, &e);
    if (!g_clr_lib) { GLOG("【红】清屏辅助着色器编译失败：%s", e.localizedDescription.UTF8String); return 0; }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 1;
    g_clr_vt = [g_gdev newArgumentTableWithDescriptor:ad error:&e]; g_clr_ft = [g_gdev newArgumentTableWithDescriptor:ad error:&e];
    return g_clr_vt && g_clr_ft;
}
static id fn_in(id<MTLLibrary> lib, NSString *name) { __auto_type f = [MTL4LibraryFunctionDescriptor new]; f.library = lib; f.name = name; return f; }
static id fn(NSString *name) { return fn_in(g_clr_lib, name); }

// 两级建（10-21 首遇零延迟：马车8 首局 16 条现建里 12 条是清屏、每条约 2 ms）：基础管线 = 清屏片元（变体 × 附件序号）+ 采样数、8 个颜色附件全留空，
//   按本次各附件格式 / 写掩码特化（gal_core.m gal_specialize_render_pso，中位 0 ms）。只清深度 / 模板的（附件 -1，没有片元）同样两级（片元为空的基础管线能特化，10-21 探针）。
//   nxgal_warm_internal 预建全部基础管线（gal_warm_clear：附件 -1 与 0–7 × 三种分量类型 × 采样 1 / 4）：10-22 九款首局「现建管线」里都有清屏（深度清屏九款都有、
//   八方2 / 马车8 还有第 1–5 号附件），动森 M2 只差这一条
typedef struct { int index, ctype; NSUInteger samples; id<MTLRenderPipelineState> p; } clr_base_ent;
static clr_base_ent *g_clr_base; static int g_nclr_base;
static MTL4RenderPipelineDescriptor *clr_desc(int index, int ctype, NSUInteger samples) {
    __auto_type d = [MTL4RenderPipelineDescriptor new];
    d.vertexFunctionDescriptor = fn(@"clr_vs");
    d.fragmentFunctionDescriptor = index < 0 ? nil : fn([NSString stringWithFormat:@"clr_fs_%c%d", ctype == 1 ? 'u' : ctype == 2 ? 'i' : 'f', index]);
    d.rasterSampleCount = samples;
    d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    return d;
}
static id<MTLRenderPipelineState> clr_base(int index, int ctype, NSUInteger samples) {
    for (int i = 0; i < g_nclr_base; i++) if (g_clr_base[i].index == index && g_clr_base[i].ctype == ctype && g_clr_base[i].samples == samples) return g_clr_base[i].p;
    __auto_type d = clr_desc(index, ctype, samples);
    for (int i = 0; i < 8; i++) gal_pso_unspecialize_color(d, i);
    NSError *e = nil; id<MTLRenderPipelineState> p = gal_new_render_pso(d, &e);
    if (!p) { GLOG("【红】清屏基础管线编译失败（附件 %d 类型 %d 采样 %lu）：%s", index, ctype, (unsigned long)samples, e.localizedDescription.UTF8String); return nil; }
    clr_base_ent *nb = gal_grow(g_clr_base, (size_t)g_nclr_base + 1, sizeof *g_clr_base, "清屏基础管线表"); if (!nb) return p;   // 审计 P1-67：表扩不动（报红、留原表）就这次不缓存，管线照用
    g_clr_base = nb; memset((void *)&g_clr_base[g_nclr_base], 0, sizeof *g_clr_base);
    g_clr_base[g_nclr_base] = (clr_base_ent){index, ctype, samples, p}; g_nclr_base++;
    return p;
}
double gal_specialize_probe(id d, id<MTLRenderPipelineState> base);
// 通用特化预热（gal_state.m）：附件 0 的清屏片元当基础管线（单采样，渲染线程上取）；同函数、颜色留空待填的特化描述（纯函数，后台线程可调）
id gal_clr_spec_base(int ctype) { return clr_init() ? clr_base(0, ctype, 1) : nil; }
id gal_clr_spec_desc(int ctype) { return clr_desc(0, ctype, 1); }
// 前提探针（10-22 总指挥：特化代价是否只看「格式 × 写掩码」组合、与程序无关、跨进程 / 跨 App 保留——成立就用一张通用组合表首次启动预热）：
//   NXGAL_SPEC_PROBE2=1 时启动量一次。两支现编的最小片元函数 A、B（都写颜色 0、内容不同 = 两个不同程序）各建一份颜色留空的基础管线，
//   8 组游戏不常用的「格式 × 部分写掩码」组合（选不常用的，免得系统里早有）每组按 A → B → A 再一次的顺序特化计时：
//   A 慢、B 快 = 与程序无关；A 慢、B 也慢 = 按程序记；A 再一次快 = 本进程记得。同一 App 再起一局看 A 快不快 = 跨进程；换 App 起 = 跨 App
static void spec_probe2(void) {
    const char *v = getenv("NXGAL_SPEC_PROBE2"); if (!v || *v != '1') return;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct PO { float4 c [[color(0)]]; };\n"
        "fragment PO s2a_probe_fs_a() { PO o; o.c = float4(1.0, 0.5, 0.25, 1.0); return o; }\n"
        "fragment PO s2a_probe_fs_b(float4 p [[position]]) { PO o; o.c = float4(p.x * 0.001, 0.75, sin(p.y), 1.0); return o; }\n";
    NSError *e = nil; id<MTLLibrary> lib = [g_gdev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { GLOG("【红】前提探针：探针着色器编不过：%s", e.localizedDescription.UTF8String); return; }
    id<MTLRenderPipelineState> base[2]; const char *nm[2] = {"s2a_probe_fs_a", "s2a_probe_fs_b"};
    for (int k = 0; k < 2; k++) {
        __auto_type d = clr_desc(0, 0, 1); d.fragmentFunctionDescriptor = fn_in(lib, @(nm[k]));
        for (int i = 0; i < 8; i++) gal_pso_unspecialize_color(d, i);
        base[k] = gal_new_render_pso(d, &e); if (!base[k]) { GLOG("【红】前提探针：基础管线 %s 建不出：%s", nm[k], e.localizedDescription.UTF8String); return; }
    }
    struct { const char *what; MTLPixelFormat f; MTLColorWriteMask m; } cs[8] = {
        {"RG16F 只 G", MTLPixelFormatRG16Float, MTLColorWriteMaskGreen},
        {"RG32F 只 R", MTLPixelFormatRG32Float, MTLColorWriteMaskRed},
        {"RG8 只 G", MTLPixelFormatRG8Unorm, MTLColorWriteMaskGreen},
        {"RGBA32F 只 B|A", MTLPixelFormatRGBA32Float, MTLColorWriteMaskBlue | MTLColorWriteMaskAlpha},
        {"RGB10A2 只 R|G", MTLPixelFormatRGB10A2Unorm, MTLColorWriteMaskRed | MTLColorWriteMaskGreen},
        {"RG11B10F 只 B", MTLPixelFormatRG11B10Float, MTLColorWriteMaskBlue},
        {"RGBA16 只 G|B", MTLPixelFormatRGBA16Unorm, MTLColorWriteMaskGreen | MTLColorWriteMaskBlue},
        {"RG16 只 R", MTLPixelFormatRG16Unorm, MTLColorWriteMaskRed}};
    char out[2048]; int w = 0;
    for (int i = 0; i < 8; i++) {
        double t[3];
        for (int r = 0; r < 3; r++) {
            int k = r == 1;
            __auto_type d = clr_desc(0, 0, 1); d.fragmentFunctionDescriptor = fn_in(lib, @(nm[k]));
            d.colorAttachments[0].pixelFormat = cs[i].f; d.colorAttachments[0].writeMask = cs[i].m;
            t[r] = gal_specialize_probe(d, base[k]);
        }
        w += snprintf(out + w, sizeof out - (size_t)w, "%s%s A %.2f B %.2f A再 %.2f", i ? "；" : "", cs[i].what, t[0], t[1], t[2]);
    }
    GLOG("前提探针（ms，A / B 两个不同程序、同一组合）：%s", out);
}
void gal_warm_clear(void) {
    if (!clr_init() || !gal_pso_can_specialize()) return;
    static const NSUInteger smp[2] = {1, 4};
    for (int si = 0; si < 2; si++) { clr_base(-1, 0, smp[si]); for (int i = 0; i < 8; i++) for (int c = 0; c < 3; c++) clr_base(i, c, smp[si]); }
    // iPhone 上核「特化头一次是否真编译、是否跨进程被系统缓存记住」（10-21 Mac 实测：部分写掩码 / 混合 × 新格式头一次 1.3–12.5 ms、同组合再来 0.01 ms、
    //   换进程 0.01–0.05 ms）：每次启动按 4 组组合各特化一次计时进 host.log——新装包后头一次慢、之后的进程快 = 系统缓存记住；每次都慢 = 记不住，要启动预热
    id<MTLRenderPipelineState> b = clr_base(0, 0, 1); if (!b) return;
    // 只用部分写掩码组合（Mac 上混合与部分掩码同一机制：按「组合 × 格式」头一次真编译）；不开混合免得为探针再加 MTL4 常量（门禁棘轮）
    struct { const char *what; MTLPixelFormat f; MTLColorWriteMask m; } cs[4] = {
        {"RGBA8 掩码 R|A", MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskRed | MTLColorWriteMaskAlpha},
        {"RGBA16F 掩码 R|A", MTLPixelFormatRGBA16Float, MTLColorWriteMaskRed | MTLColorWriteMaskAlpha},
        {"BGRA8 掩码 G", MTLPixelFormatBGRA8Unorm, MTLColorWriteMaskGreen},
        {"RGBA16F 掩码 R|G|B", MTLPixelFormatRGBA16Float, MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue}};
    double ms[4];
    for (int i = 0; i < 4; i++) {
        __auto_type d = clr_desc(0, 0, 1);
        d.colorAttachments[0].pixelFormat = cs[i].f; d.colorAttachments[0].writeMask = cs[i].m;
        ms[i] = gal_specialize_probe(d, b);
    }
    GLOG("特化探针（每次启动量，判系统是否跨进程记住特化）：%s %.2f ms、%s %.2f ms、%s %.2f ms、%s %.2f ms", cs[0].what, ms[0], cs[1].what, ms[1], cs[2].what, ms[2], cs[3].what, ms[3]);
    spec_probe2();
}
static id<MTLRenderPipelineState> clr_pipeline(int index, uint32_t mask, int ctype) {
    // Metal 3 参数绑定（M3-7）未合入：遍内清屏画不了，先报红跳过，不去编管线（不然每次清屏都编一次、失败一次刷屏；塞尔达 120 秒 4 万行）
    if (gal_m3_unbound(2)) return nil;
    clr_key k; memset(&k, 0, sizeof k);
    NSUInteger samples = 1;
    for (int i = 0; i < g_rt.ncolor; i++) { gal_tex *t = gal_tex_get(g_rt.color[i]); if (t) { k.cf[i] = t->tex.pixelFormat; samples = t->tex.sampleCount; } }
    for (int i = 0; i < 8; i++) if (g_ph.hidden >> i & 1) k.cf[i] = g_ph.fmt[i];
    gal_tex *dt = gal_tex_get(g_rt.depth);
    if (dt) { int ds = gal_fmt_is_ds(dt->info.format); if (ds & 1) k.df = dt->tex.pixelFormat; if (ds & 2) k.sf = dt->tex.pixelFormat; samples = dt->tex.sampleCount; }
    k.samples = samples; k.index = index; k.mask = mask; k.ctype = ctype;
    for (int i = 0; i < g_nclr; i++) if (!memcmp(&g_clr_cache[i].k, &k, sizeof k)) return g_clr_cache[i].p;
    __auto_type d = clr_desc(index, ctype, samples);
    for (int i = 0; i < 8; i++) if (k.cf[i]) {
        d.colorAttachments[i].pixelFormat = k.cf[i];
        // 只写被清的附件；GAL 掩码位 0–3 = R G B A，Metal 写掩码位 3–0 = R G B A
        d.colorAttachments[i].writeMask = i == index ? ((mask & 1 ? MTLColorWriteMaskRed : 0) | (mask & 2 ? MTLColorWriteMaskGreen : 0) | (mask & 4 ? MTLColorWriteMaskBlue : 0) | (mask & 8 ? MTLColorWriteMaskAlpha : 0)) : MTLColorWriteMaskNone;
    }
    NSError *e = nil; id<MTLRenderPipelineState> p = nil;
    // 两级（含只清深度 / 模板、没有片元的：附件 -1、分量类型按 0 记）；特化不可用或失败退回整条建
    if (gal_pso_can_specialize()) { id<MTLRenderPipelineState> b = clr_base(index, index < 0 ? 0 : ctype, samples); if (b) p = gal_specialize_render_pso(d, b, &e); }
    if (!p) p = gal_new_render_pso(d, &e);
    if (!p) { GLOG("【红】清屏管线编译失败：%s", e.localizedDescription.UTF8String); return nil; }
    // 深度 / 模板格式不进 MTL4 管线描述（Metal 4 由通道决定），键里保留它们只为区分缓存
    g_clr_cache = realloc(g_clr_cache, (g_nclr + 1) * sizeof *g_clr_cache);
    memset((void *)&g_clr_cache[g_nclr], 0, sizeof *g_clr_cache);
    g_clr_cache[g_nclr].k = k; g_clr_cache[g_nclr].p = p; g_nclr++;
    return p;
}

// 深度模板状态：键 = (写深度, 模板写掩码)
static id<MTLDepthStencilState> clr_dss(int depth_write, int stencil_mask) {
    static id<MTLDepthStencilState> cache[2][257];
    int si = stencil_mask < 0 ? 256 : (stencil_mask & 0xff);
    __strong id<MTLDepthStencilState> *slot = &cache[depth_write ? 1 : 0][si];
    if (*slot) return *slot;
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = MTLCompareFunctionAlways; d.depthWriteEnabled = depth_write != 0;
    if (stencil_mask >= 0) {
        MTLStencilDescriptor *s = [MTLStencilDescriptor new];
        s.stencilCompareFunction = MTLCompareFunctionAlways; s.depthStencilPassOperation = MTLStencilOperationReplace;
        s.stencilFailureOperation = MTLStencilOperationReplace; s.depthFailureOperation = MTLStencilOperationReplace;
        s.readMask = 0xff; s.writeMask = (uint32_t)stencil_mask;
        d.frontFaceStencil = s; d.backFaceStencil = s;
    }
    return *slot = [g_gdev newDepthStencilStateWithDescriptor:d];
}

static void clr_draw(id<MTLRenderPipelineState> p, id<MTLDepthStencilState> dss, const MTLScissorRect *r, const clr_params *prm, int layer_count, uint32_t stencil_ref) {
    // 计数区间在本编码器里被辅助绘制切的段数到上限：先结束通道，让可见性槽链不再变长（gal_cnt.m VIS_SEG_MAX）
    if (gal_cnt_aux_wants_break()) gal_pass_close();
    id<MTL4RenderCommandEncoder> e = gal_render_enc();
    // 临时内存取不到（gal_transient 已报红）：本次清屏跳过，不往 NULL 写（10-20 丝之歌测试机2 第 24 帧 SIGSEGV）
    uint64_t gpu; clr_params *cp = gal_transient(sizeof *cp, 16, &gpu); if (!cp) return;
    *cp = *prm;
    [g_clr_vt setAddress:gpu atIndex:0]; [g_clr_ft setAddress:gpu atIndex:0];
    [e setArgumentTable:g_clr_vt atStages:MTLRenderStageVertex]; [e setArgumentTable:g_clr_ft atStages:MTLRenderStageFragment];
    [e setRenderPipelineState:p]; [e setDepthStencilState:dss]; [e setStencilReferenceValue:stencil_ref];
    [e setViewport:(MTLViewport){0, 0, g_rt.w, g_rt.h, 0, 1}]; [e setScissorRect:*r];
    [e setCullMode:MTLCullModeNone]; [e setTriangleFillMode:MTLTriangleFillModeFill]; [e setDepthBias:0 slopeScale:0 clamp:0];
    [e setDepthClipMode:MTLDepthClipModeClip];
    gal_cnt_on_aux_draw(e);
    gal_pass_ds_written();   // 遍内清屏（颜色或深度模板）：保守按写过深度模板算，之后的深度采样照旧收遍
    { extern uint64_t g_pstat_clears; g_pstat_clears++; }
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:layer_count baseInstance:0];
    g_genc_serial++;   // 绘制模块的管线 / 视口 / 剪裁 / 深度模板 / 参数表都被改了
}

// 挂起清屏在遍内补画（pc_resolve ②）：开遍后、本遍第一条绘制之前，按附件槽画满整个通道的清屏三角，层 = [layer0, layer0 + layers)。
// 挂起清屏存的颜色：浮点格式是值、整数格式是位模式的整数值（见 nxgal_clear_color），清屏着色器要的是位模式
static void pc_inpass(const pclr *c, int slot, int layer0, int layers) {
    if (!clr_init()) return;
    MTLScissorRect r = {0, 0, (NSUInteger)g_rt.w, (NSUInteger)g_rt.h};
    if (c->color) {
        gal_tex *t = gal_tex_get(g_rt.color[slot]); if (!t) return;
        int ctype = gal_fmt_ctype(t->info.format);
        clr_params prm = {{0, 0, 0, 0}, 0, (uint32_t)layer0, {0}};
        for (int i = 0; i < 4; i++) {
            if (ctype == 1) { uint32_t u = (uint32_t)c->rgba[i]; memcpy(&prm.rgba[i], &u, 4); }
            else if (ctype == 2) { int32_t v = (int32_t)c->rgba[i]; memcpy(&prm.rgba[i], &v, 4); }
            else prm.rgba[i] = (float)c->rgba[i];
        }
        id<MTLRenderPipelineState> p = clr_pipeline(slot, 0xf, ctype); if (!p) return;
        clr_draw(p, clr_dss(0, -1), &r, &prm, layers, 0);
    } else {
        gal_tex *t = gal_tex_get(g_rt.depth); if (!t) return;
        int ds = gal_fmt_is_ds(t->info.format);
        clr_params prm = {{0, 0, 0, 0}, (float)c->depth, (uint32_t)layer0, {0}};
        id<MTLRenderPipelineState> p = clr_pipeline(-1, 0, 0); if (!p) return;
        clr_draw(p, clr_dss((ds & 1) && c->d, (ds & 2) ? (c->s ? 0xff : 0) : -1), &r, &prm, layers, c->stencil);
    }
}

NXGAL_API void nxgal_clear_color(int32_t index, int32_t layer, int32_t layer_count, uint32_t mask, const float rgba[4]) { GAL_API_LOCK();
    GP_SCOPE(GP_CLEAR);
    if (index < 0 || index >= g_rt.ncolor) return;
    gal_tex *t = gal_tex_get(g_rt.color[index]); if (!t || !(mask & 0xf)) return;
    rt_size();
    MTLScissorRect r; if (!clear_rect(&r)) return;
    int ctype = gal_fmt_ctype(t->info.format);
    int whole = !g_rt.open && covers_all(&r) && (mask & 0xf) == 0xf && layer == 0 && layer_count >= tex_layer_count(t);
    whole = whole && (int)t->tex.width == g_rt.w && (int)t->tex.height == g_rt.h;   // 挂到贴图上的清屏要盖满整张（以后可能在尺寸不同的组里落实）
    pclr *pc = whole ? pc_get(g_rt.color[index], t) : NULL;
    if (pc) {
        pc->color = 1;
        for (int c = 0; c < 4; c++) {
            uint32_t bits; memcpy(&bits, &rgba[c], 4);
            pc->rgba[c] = ctype == 1 ? (double)bits : ctype == 2 ? (double)(int32_t)bits : rgba[c];
        }
        return;
    }
    if (!clr_init()) return;
    id<MTLRenderPipelineState> p = clr_pipeline(index, mask & 0xf, ctype); if (!p) return;
    clr_params prm = {{rgba[0], rgba[1], rgba[2], rgba[3]}, 0, (uint32_t)layer, {0}};
    if (layer_count > g_rt.layers - layer) layer_count = g_rt.layers - layer;
    clr_draw(p, clr_dss(0, -1), &r, &prm, layer_count < 1 ? 1 : layer_count, 0);
}

NXGAL_API void nxgal_clear_ds(int32_t layer, int32_t layer_count, float depth, int32_t depth_mask, int32_t stencil, int32_t stencil_mask) { GAL_API_LOCK();
    GP_SCOPE(GP_CLEAR);
    gal_tex *t = gal_tex_get(g_rt.depth); if (!t) return;
    int ds = gal_fmt_is_ds(t->info.format);
    int dw = depth_mask && (ds & 1), sm = (ds & 2) ? (stencil_mask & 0xff) : 0;
    if (!dw && !sm) return;
    rt_size();
    MTLScissorRect r; if (!clear_rect(&r)) return;
    int whole = !g_rt.open && covers_all(&r) && layer == 0 && layer_count >= tex_layer_count(t) && (!(ds & 2) || !sm || sm == 0xff);
    whole = whole && (int)t->tex.width == g_rt.w && (int)t->tex.height == g_rt.h;
    pclr *pc = whole ? pc_get(g_rt.depth, t) : NULL;
    if (pc) {
        pc->color = 0;
        if (dw) { pc->d = 1; pc->depth = depth; }
        if (sm) { pc->s = 1; pc->stencil = (uint32_t)stencil & 0xff; }
        return;
    }
    if (!clr_init()) return;
    id<MTLRenderPipelineState> p = clr_pipeline(-1, 0, 0); if (!p) return;
    clr_params prm = {{0, 0, 0, 0}, depth, (uint32_t)layer, {0}};
    if (layer_count > g_rt.layers - layer) layer_count = g_rt.layers - layer;
    clr_draw(p, clr_dss(dw, (ds & 2) ? sm : -1), &r, &prm, layer_count < 1 ? 1 : layer_count, (uint32_t)stencil & 0xff);
}

// ---------- 给管线状态 / 绘制模块的查询 ----------
// Metal 3 完整管线描述必须与实际挂上的深度 / 模板纹理格式一致。
void gal_pass_ds_formats(uint32_t *df, uint32_t *sf) {
    *df = *sf = 0; gal_tex *t = gal_tex_get(g_rt.depth); if (!t) return;
    int ds = gal_fmt_is_ds(t->info.format);
    if (ds & 1) *df = (uint32_t)t->tex.pixelFormat;
    if (ds & 2) *sf = (uint32_t)t->tex.pixelFormat;
}
void gal_pass_formats(uint32_t cf[8], uint32_t *samples) {
    NSUInteger sc = 1;
    for (int i = 0; i < 8; i++) { gal_tex *t = i < g_rt.ncolor ? gal_tex_get(g_rt.color[i]) : NULL; cf[i] = t ? (uint32_t)t->tex.pixelFormat : 0; if (t) sc = t->tex.sampleCount; }
    gal_tex *d = gal_tex_get(g_rt.depth); if (d) sc = d->tex.sampleCount;
    *samples = (uint32_t)sc;
    for (int i = 0; i < 8; i++) if (g_ph.hidden >> i & 1) cf[i] = (uint32_t)g_ph.fmt[i];
}
void gal_pass_info(int *w, int *h, int *has_depth, int *has_stencil) {
    rt_size(); *w = g_rt.w; *h = g_rt.h; *has_depth = g_rt_hd; *has_stencil = g_rt_hs;
}
void gal_pass_reset_session(void) {
    // These are non-owning attachment/texture identities; GPU work is drained.
    memset(&g_rt, 0, sizeof g_rt); memset(g_pc, 0, sizeof g_pc); g_npc = 0;
    memset(&g_ph, 0, sizeof g_ph); memset(g_sig_cur, 0, sizeof g_sig_cur); memset(g_sig_prev, 0, sizeof g_sig_prev);
    memset(g_tu, 0, sizeof g_tu); memset(g_rt_req, 0, sizeof g_rt_req);
    g_rt_nreq = 0; g_rt_dreq = 0; g_rt_dup = 0; g_rt_dirty = 1;
    g_rt_hd = g_rt_hs = g_rt_tl = g_texbar = g_membar = g_pass_swr = g_ds_mem = 0;
    g_rtd_n = g_rtd_pn = 0;
}
GAL_MTL4_ZONE_END

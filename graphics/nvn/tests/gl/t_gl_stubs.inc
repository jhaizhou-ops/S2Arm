// t_gl_min / t_gl_api 共用：公共后端与宽屏核心的替身（不链宿主 / libnvn / 宽屏库；GL 层单测只测 GL 前端语义）
// ---- 公共后端的替身：本单测只测 GL 前端语义（方向、uniform、剔除、命令顺序），上屏 / 回放层 / 宽屏各有各的测试，不链宿主 ----
void *mtl_device(void) { static id<MTLDevice> d; if (!d) d = MTLCreateSystemDefaultDevice(); return (__bridge void *)d; }
uint64_t mtl_ext_tex(void *t) { (void)t; static uint64_t n; return ++n; }
int mtl_gpu_go(void) { return 1; } int mtl_gpu_cb_error(NSError *e, const char *where, uint64_t seq) { (void)e; (void)where; (void)seq; return 0; }   // GPU 安全停（nvn_mtl.m）：GL 单测不停
static uint64_t g_presents;
static int g_crop[4], g_cropped;   // 最近一次上屏的裁切框（g_cropped = 0：不裁）
uint64_t mtl_present_ext(uint64_t s, double p, void *ev, uint64_t v, const int crop[4]) { (void)s; (void)p; (void)ev; (void)v; g_cropped = crop != NULL; if (crop) memcpy(g_crop, crop, sizeof g_crop); return ++g_presents; }
static int g_fit_k = -1;   // 最近一次上屏前交的满屏判据免判种类（-1 = 没交过）
void mtl_fit_pillar(int k) { g_fit_k = k; }
static uint64_t mtl_present_count(void) { return g_presents; }
static void mtl_present_flush(void) {}
void nvn_be_present_wait(uint64_t t) { (void)t; }
static int g_ll;
void nvn_be_set_origin_lower_left(int on) { g_ll = on; }
int nvn_be_fps_target(void) { return 60; }
static int g_link, g_ticks, g_tick_vs;   // 显示链接替身：g_link = 有链接；nvn_be_link_wait_tick 记次数与最近一次的拍数，不真等
int nvn_be_link_active(void) { return g_link; }
int nvn_be_link_wait_tick(int vsyncs, uint64_t timeout_ns) { (void)timeout_ns; g_ticks++; g_tick_vs = vsyncs; return 1; }
void s2a_sleep_ns(int64_t ns) { if (ns > 0) { struct timespec t = {ns / 1000000000, ns % 1000000000}; nanosleep(&t, NULL); } }   // 真宿主是 runtime/src/thread.c 的按时睡（无链接时的交换节拍）
int dm_opmode(void) { return 0; }
void dm_gfx_enter(void) {} void dm_gfx_leave(void) {} void dm_guest_frame_tick(void) {}
double nvn_be_presented_time(uint64_t n) { (void)n; return 0; } void dm_perf_present(double iv) { (void)iv; }
void *sw_xstack_wrap(const char *name, void *fn) { (void)name; return fn; }
void s2a_direct_gpu_error(const char *d) { printf("✗ GPU 报错：%s\n", d); exit(1); }

// ---- 宽屏核心的替身（gl_widen.inc 链接要；只在 S2A_WIDEN_DIRECT=1 的那一遍被调到）：按「整套放宽、屏宽 2346」给确定的回答，
//   本单测只验 GL 层有没有照核心的决定做（附件换影子、视口 / 裁剪 / 上屏按放宽换算、采样换影子），核心自己的判断由 graphics/widen 的单测管 ----
#include "../../../widen/export/s2a_widen.h"
static const double WK = 2346.0 / 1920.0;
static int wk(int x) { return (int)(x * WK + 0.5); }
static uint32_t g_wd_tc, g_wd_td; static int g_wd_rel;
static s2a_widen_tex g_wd_tex[16]; static uint32_t g_wd_ntex;
int s2a_screen_w(void) { return 2346; } int s2a_screen_h(void) { return 1080; } int s2a_widen_game(void) { return 0; } int s2a_widen_layout(void) { return 0; } int s2a_widen_full(void) { return 1; }
int s2a_widen_init(int w, int h, uint32_t f) { (void)w; (void)h; return f & S2A_WIDEN_FULL ? 2 : S2A_WIDEN_OFF; }
float s2a_widen_k(void) { return (float)WK; }
int32_t s2a_widen_shader(int st, const char *u, uint32_t f) { (void)st; (void)u; (void)f; return 1; }
int s2a_widen_texture(uint32_t id, int w, int h, float rs, uint32_t use) { (void)id; (void)h; (void)rs; return use & S2A_WIDEN_USE_RT ? wk(w) : w; }
int s2a_widen_view(uint32_t id, uint32_t parent, int level, int w0) { (void)id; (void)parent; (void)level; return w0; }
void s2a_widen_release(uint32_t id) { (void)id; g_wd_rel++; }
int s2a_widen_map_x(uint32_t tex, int x) { (void)tex; return wk(x); }
void s2a_widen_targets(uint32_t c0, uint32_t d0) { g_wd_tc = c0; g_wd_td = d0; }
int s2a_widen_viewport(float x, float w, float h, float rs) { (void)x; (void)w; (void)h; (void)rs; return 1; }
void s2a_widen_cbuf_bind(int st, int sl, const void *cpu, uint32_t len) { (void)st; (void)sl; (void)cpu; (void)len; }
int s2a_widen_draw(const s2a_widen_draw_in *in, s2a_widen_draw_out *out) { g_wd_ntex = MIN(in->ntex, 16u); if (g_wd_ntex) memcpy(g_wd_tex, in->tex, g_wd_ntex * sizeof *g_wd_tex); memset(out, 0, sizeof *out); out->frag_scale_x = 1; out->flags = S2A_WIDEN_OUT_NO_EMIT; return 2; }
void s2a_widen_map_viewport(int mode, float *x, float *w) { (void)mode; *x *= (float)WK; *w *= (float)WK; }
void s2a_widen_map_scissor(int mode, int32_t *x, int32_t *w) { (void)mode; int x1 = wk(*x + *w); *x = wk(*x); *w = x1 - *x; }
// 窄屏加高（fix/gl-widen-tall：GL 胶水纵向换算与存储加高）：这套桩只模拟横向放宽，纵向原样、高不加（同只放宽的屏）
int s2a_widen_tex_h(uint32_t id, int h) { (void)id; return h; }
void s2a_widen_map_viewport_y(int mode, float *y, float *h) { (void)mode; (void)y; (void)h; }
void s2a_widen_map_scissor_y(int mode, int32_t *y, int32_t *h) { (void)mode; (void)y; (void)h; }
uint32_t s2a_widen_cbuf_emit(int st, int sl, void *scr, uint32_t cap) { (void)st; (void)sl; (void)scr; (void)cap; return 0; }
int s2a_widen_present(uint32_t tex, s2a_widen_crop *c) { (void)tex; c->left = wk(c->left); c->right = wk(c->right); return 1; }
int s2a_widen_page_sides(int32_t cols[4]) { (void)cols; return 0; }   // 替身 draw 不出 PAGE_SIDES，不起原比例页
int s2a_widen_report(char *buf, int cap) { if (cap > 0) buf[0] = 0; return 0; }
// 原比例回退（widen_fallback.inc）：替身答「纯 2D 帧」、客体宽 = 放宽前的 1920，记下 GL 层交来的两侧覆盖样本
int s2a_widen_pure2d(void) { return 1; }
int s2a_widen_tex_guest_w(uint32_t id, int w) { (void)id; return w == 2346 ? 1920 : w; }
static int g_cov_n, g_cov[4];   // 样本次数、最近一次的左画到 / 右画到（有内容）/ 左没画到 / 右没画到
void s2a_widen_side_coverage(int l, int r, int ul, int ur, uint32_t sig) { (void)sig; g_cov_n++; g_cov[0] = l; g_cov[1] = r; g_cov[2] = ul; g_cov[3] = ur; }

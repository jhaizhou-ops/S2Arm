// MelonX 虚拟手柄移植的宿主兼容层（新增文件）。
// 源项目 DmGamepad.m 依赖的 front / mtl / hle 一组符号，在 S2Arm 里换成本文件里的实现：
//   - 画面矩形：优先直连出图层的真实层框，其次通用出图层的最近目标矩形，再退回屏幕比例推算；
//   - 帧率：30 帧用直连显示链路 pin + 通用层最小间隔，60 帧用 runtime/src/fps.c 的 60 帧补丁开关，120 按 60 上限；
//   - 画面填充 / 画面自定义：同时写直连层（graphics/nvn/host_adapt.m）与通用层（graphics/metal/gal_present.m）；
//   - 触摸直通：本阶段虚拟手柄只发按键，不做触屏直通；
//   - 金手指：引擎在 ios/dmpad_cheats.m，页面在 ios/DmCheats.m。
#import <UIKit/UIKit.h>
#include <stdint.h>
#import "DmCheats.h"
#include "dm_input.h"
#include "dm.h"
#include "front.h"
#include "hle.h"
#include "s2a_pad.h"
#include "native.h"

// 弱链接[ios]：nxgal_present_frame（graphics/metal/gal_present.m：最近一帧的真实出图尺寸；直连模式不链通用出图层）
// 弱链接[ios]：s2a_game_canvas（runtime/src/widen.c：游戏画布）
// 弱链接[ios]：s2a_screen_w_after_load（runtime/src/widen.c：装载后的屏幕宽，装载前回 0）
// 弱链接[ios]：s2a_direct_out_aspect（graphics/nvn/host_adapt.m：直连出图层当前的出图宽高比）
int nxgal_present_frame(int32_t *w, int32_t *h, float *ax, float *ay, int32_t *stretched) __attribute__((weak_import));
void s2a_game_canvas(int *w, int *h) __attribute__((weak_import));
int s2a_screen_w_after_load(void) __attribute__((weak_import));
double s2a_direct_out_aspect(void) __attribute__((weak_import));
// 通用出图层（直连模式不建，可能整组符号不在；弱链接调用前都判空）
void nxgal_window_set_present_fill(int32_t mode) __attribute__((weak_import));
void nxgal_window_set_picture(float scale, float sx, float sy, float dx, float dy) __attribute__((weak_import));
int nxgal_present_target(int32_t *x, int32_t *y, int32_t *w, int32_t *h, int32_t *dw, int32_t *dh) __attribute__((weak_import));
void nxgal_window_set_min_interval(float seconds) __attribute__((weak_import));
// 直连出图层（graphics/nvn/host_adapt.m，iOS 游戏主路径）
void s2a_direct_set_picture(int fill, float scale, float sx, float sy, float dx, float dy, double top) __attribute__((weak_import));
int s2a_direct_picture_rect(double *x, double *y, double *w, double *h) __attribute__((weak_import));
void s2a_direct_relayout(void) __attribute__((weak_import));
void s2a_direct_set_fps(int fps) __attribute__((weak_import));
// runtime/src/lifecycle.c：正常收尾（存档服务 / GPU / 诊断）后退出进程
void s2a_host_shutdown(const char *why);
// runtime/src/fps.c：60 帧补丁开关（没有对外头文件，这里就地声明）
void s2a_fps_set_enabled(int on);
uint64_t s2a_ap_frames(void);   // runtime/src/ap_host.c：上屏帧数
// ios/dmpad.m：当前方向那套画面配置（画面编辑写，本文件读）
void front_pic_state(CGFloat *scale, CGFloat *sx, CGFloat *sy, CGFloat *dx, CGFloat *dy, int *editing);
int dm_pad_fill(void);

// ---- 按游戏隔离的 UserDefaults ----
static NSString *DmCfgScope(void) {
    static NSString *scope;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 多款容器：S2A_DOCS 指向当前游戏的 Documents（Documents/games/<gid>），末级目录就是游戏号
        const char *docs = getenv("S2A_DOCS");
        if (docs && *docs) {
            NSString *last = [NSString stringWithUTF8String:docs].lastPathComponent;
            scope = last.length ? last : @"default";
        } else {
            scope = @"default";   // 单款包：没有 S2A_DOCS
        }
    });
    return scope;
}
NSUserDefaults *DmCfgDefaults(void) {
    static NSUserDefaults *ud;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *suite = [@"S2ArmDmPad." stringByAppendingString:DmCfgScope()];
        ud = [[NSUserDefaults alloc] initWithSuiteName:suite];
        if (!ud) ud = NSUserDefaults.standardUserDefaults;   // suite 建不起来时退回标准域（至少可用）
    });
    return ud;
}

// ---- 屏幕 / 画面矩形 ----
static UIWindow *dm_key_window(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}
// 与 ios/vpad.m -gameRect 同一套换算，输出相对整屏的归一化比例（x/y 是原点，w/h 是宽高）
void dm_pad_screen_rect(double *x, double *y, double *w, double *h) {
    if (x) *x = 0; if (y) *y = 0; if (w) *w = 1; if (h) *h = 1;
    UIWindow *win = dm_key_window();
    CGRect b = win ? win.bounds : UIScreen.mainScreen.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;
    int32_t iw = 0, ih = 0; float ax = 0, ay = 0; int32_t st = 0;
    BOOL have = nxgal_present_frame && nxgal_present_frame(&iw, &ih, &ax, &ay, &st);
    if (!have && s2a_direct_out_aspect && s2a_direct_out_aspect() > 0) { ax = (float)s2a_direct_out_aspect(); ay = 1; st = 0; have = YES; }
    if (!have) { int sw = s2a_screen_w_after_load ? s2a_screen_w_after_load() : 0; if (sw > 0) { ax = (float)sw; ay = 1080; st = 0; have = YES; } }
    BOOL stretched = !have || st || !(ax > 0) || !(ay > 0);
    CGFloat s = win.windowScene.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    if (s <= 0) s = 1;
    CGFloat W = MAX(1, round(b.size.width * s)), H = MAX(1, round(b.size.height * s));
    CGFloat rx = stretched ? 1.0 : MIN(1.0, H * ax / (W * ay));
    CGFloat ry = stretched ? 1.0 : MIN(1.0, W * ay / (H * ax));
    CGFloat dw = W * rx, dh = H * ry;
    if (W - dw < 1.0) dw = W;
    if (H - dh < 1.0) dh = H;
    dw = MAX(trunc(dw), 1), dh = MAX(trunc(dh), 1);
    CGFloat ox = trunc((W - dw) / 2), oy = trunc((H - dh) / 2);
    if (x) *x = ox / W; if (y) *y = oy / H;
    if (w) *w = dw / W; if (h) *h = dh / H;
}
// 屏幕上真正的画面（窗口坐标），画面编辑浮层的虚线框与四边箭头对齐到它
CGRect front_pic_rect(void) {
    UIWindow *win = dm_key_window();
    CGRect b = win ? win.bounds : UIScreen.mainScreen.bounds;
    CGFloat ns = (win.windowScene.screen.nativeScale ?: UIScreen.mainScreen.nativeScale);
    if (ns <= 0) ns = 1;
    double x = 0, y = 0, w = 0, h = 0;
    if (s2a_direct_picture_rect && s2a_direct_picture_rect(&x, &y, &w, &h) && w > 0 && h > 0)
        return CGRectMake(b.origin.x + x, b.origin.y + y, w, h);   // 直连层框就是视图点
    int32_t tx = 0, ty = 0, tw = 0, th = 0, dw = 0, dh = 0;
    if (nxgal_present_target && nxgal_present_target(&tx, &ty, &tw, &th, &dw, &dh) && dw > 0 && dh > 0)
        return CGRectMake(b.origin.x + tx / ns, b.origin.y + ty / ns, tw / ns, th / ns);   // 通用层目标是像素
    double nx = 0, ny = 0, nw = 1, nh = 1;
    dm_pad_screen_rect(&nx, &ny, &nw, &nh);
    return CGRectMake(b.origin.x + nx * b.size.width, b.origin.y + ny * b.size.height,
                      nw * b.size.width, nh * b.size.height);
}
void mtl_present_src_size(unsigned *w, unsigned *h) {   // 最近一次出图的源尺寸；取不到按 1280x720
    int32_t iw = 0, ih = 0; float ax = 0, ay = 0; int32_t st = 0;
    if (nxgal_present_frame && nxgal_present_frame(&iw, &ih, &ax, &ay, &st) && iw > 0 && ih > 0) {
        if (w) *w = (unsigned)iw; if (h) *h = (unsigned)ih; return;
    }
    int cw = 1280, ch = 720;
    if (s2a_game_canvas) s2a_game_canvas(&cw, &ch);
    if (w) *w = (unsigned)cw; if (h) *h = (unsigned)ch;
}

// ---- 出图层：画面填充 / 画面自定义（直连层 + 通用层同时写） ----
static void dm_apply_picture(void) {
    CGFloat sc = 1, sx = 1, sy = 1, dx = 0, dy = 0; int editing = 0;
    front_pic_state(&sc, &sx, &sy, &dx, &dy, &editing);
    int fill = dm_pad_fill();   // 0 保持比例 / 1 拉伸铺满 / 2 裁切铺满
    UIWindow *win = dm_key_window();
    double top = 0;
    if (win && win.bounds.size.height > win.bounds.size.width) top = MAX(100.0, win.safeAreaInsets.top + 12.0);   // 竖屏缺省贴顶
    if (nxgal_window_set_present_fill) nxgal_window_set_present_fill(fill);
    if (nxgal_window_set_picture) nxgal_window_set_picture(sc, sx, sy, dx, dy);
    if (s2a_direct_set_picture) s2a_direct_set_picture(fill, sc, sx, sy, dx, dy, top);
    else if (s2a_direct_relayout) s2a_direct_relayout();
}
void mtl_present_fill(int mode) { (void)mode; dm_apply_picture(); }
void front_game_frame_apply(void) { dm_apply_picture(); }   // 画面自定义（拖动 / 双指缩放）立即重摆
static int g_fps_logged;
void mtl_fps_override(int fps) {
    // 30：直连显示链路 pin 到 30 + 通用层最小间隔 1/30 + 关 60 帧补丁；60：开 60 帧补丁；120：按 60 上限
    if (nxgal_window_set_min_interval) nxgal_window_set_min_interval(fps == 30 ? 1.0f / 30.0f : 0);
    if (s2a_direct_set_fps) s2a_direct_set_fps(fps == 30 ? 30 : 0);
    if (fps == 30) { s2a_fps_set_enabled(0); return; }
    if (fps == 60) { s2a_fps_set_enabled(1); return; }
    if (fps == 120) { s2a_fps_set_enabled(1); if (!g_fps_logged++) LOG("dmpad：120 帧档按 60 帧上限执行（Switch 游戏上限 60）"); return; }
    // 0 跟随配置：最小间隔已清掉，60 帧表保持启动时的设置
}
int mtl_display_hz(void) {
    NSUInteger hz = UIScreen.mainScreen.maximumFramesPerSecond;
    return hz ? (int)hz : 60;
}
// 缺失着色器抓取：S2Arm 没有这套机制，且源文件里没有调用点，只保留符号
void mtl_shdump_set(int on) { (void)on; }
int mtl_shdump_enabled(void) { return 0; }
int mtl_shdump_count(void) { return 0; }
const char *mtl_shdump_path(void) { return ""; }

// ---- 触摸直通：本阶段不做（只发按键） ----
void dm_touch_set_from(const dm_touch *t, int n, int source) { (void)t; (void)n; (void)source; }
void dm_touch_cancel_from(int source) { (void)source; }

// ---- 退出：走宿主的正常收尾（存档服务 / GPU / 诊断写完再 _exit） ----
void dm_host_shutdown(const char *why) { LOG("dmpad：退出游戏（%s）", why ? why : "玩家菜单"); s2a_host_shutdown(why ? why : "玩家菜单退出"); }

// ---- 上屏帧数（性能叠层的 FPS 差值） ----
uint64_t dm_guest_frame(void) { return s2a_ap_frames(); }

// 触屏虚拟手柄（基础版，设计稿参考分支 touch/design 的 docs/原生触摸方案设计.md §6.1）：完整 Switch 按键 + 左右摇杆，掌机模式下经 InputPump.InputHook 喂给 Ryujinx HID。
//   左半屏空白处按下 = 浮动左摇杆（按下点为中心，拖 60 pt 推满，松手消失）；右半屏空白处按下 = 浮动右摇杆（同上，转镜头）；
//   双击左 / 右半屏（第二下按住）= LS / RS 按下。ABXY 右下按 Switch 原位（A 右、B 下、X 上、Y 左）；十字键左上；ZL L / R ZR 上缘两侧；－ ＋ 顶部中间。
//   空闲 30% 透明，3 秒无触摸淡出到全隐藏（热区照常有效，碰屏即回）。
// 线程：UIKit 主线程写，InputPump 的 HID 线程约 60 Hz 读 s2a_vpad_read（原子量，读到的是最近一次完整状态）。
// 后续（不在这一笔）：编辑模式 / 磁力吸附 / 方案文件、接手柄自动隐藏。
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sys/stat.h>
#include "native.h"
uint64_t s2a_ap_frames(void);                                   // ap_host.c：上屏帧数
int s2a_autoplay_on(void) __attribute__((weak_import));         // tests/autoplay：自动玩家在跑时不录
void s2a_ap_snapshot(const char *path) __attribute__((weak_import));

// ---- 录手柄（10-21 jhz 拍板：录 jhz 实机玩的虚拟手柄按键，正式局 MARK 后回放）----
// 人玩时缺省就录：按键 / 摇杆状态每变一次写一行「上屏帧号 \t 按键位 \t 左 x \t 左 y \t 右 x \t 右 y \t 录制起毫秒」到 Documents/padrec/<款>_<时刻>.tsv；
// 游戏每次存档提交（C# IFileSystem.Commit → s2a_padrec_mark）写一行「帧号 \t 存档 \t 第 N 次 \t 毫秒」、截 <同名>.save<N>.png，
// 返回 <同名>.save<N> 给 C# 把当时的存档整份拷进这个目录（services Saves.Snapshot）。每个存档点各留一份：退出时的自动存档不再盖掉玩家要的那次，
// 选哪个存档点回放由 tools/padrec_cut.py 定（之后有 ≥60 秒输入的最后一个）。自动玩家在跑时不录
static pthread_mutex_t g_rmu = PTHREAD_MUTEX_INITIALIZER; static FILE *g_rec; static char g_rpath[1024]; static int g_roff;
static uint32_t g_rb = ~0u; static uint64_t g_rs, g_rflush, g_rt0; static int g_nsave; static char g_rsave[1100];
static uint64_t rec_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000; }
static int rec_open(void) {   // 持 g_rmu
    if (g_rec || g_roff) return g_rec != NULL;
    if (s2a_autoplay_on && s2a_autoplay_on()) { g_roff = 1; return 0; }
    const char *h = getenv("HOME"); NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"s2arm"; NSString *g = [bid componentsSeparatedByString:@"."].lastObject;
    char dir[900]; snprintf(dir, sizeof dir, "%s/Documents/padrec", h ? h : "."); mkdir(dir, 0755);
    time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm); char ts[32]; strftime(ts, sizeof ts, "%m%d_%H%M%S", &tm);
    snprintf(g_rpath, sizeof g_rpath, "%s/%s_%s.tsv", dir, g.UTF8String, ts);
    g_rec = fopen(g_rpath, "w"); if (!g_rec) { g_roff = 1; LOG("【红】录手柄：建 %s 失败", g_rpath); return 0; }
    g_rt0 = rec_ms();
    fprintf(g_rec, "# 构建号 %s\n", s2a_main_build_id());   // 主程序构建号（exefs/main 0x40 起 16 字节）：执行器按它定 saves/<款>_<构建号>/
    fprintf(g_rec, "# 录手柄 款 %s：帧号（上屏）\t按键位\t左x\t左y\t右x\t右y\t毫秒；「帧号\t存档\tN\t毫秒」= 游戏第 N 次存档提交（存档副本 <同名>.saveN/、截图 <同名>.saveN.png）\n", g.UTF8String); fflush(g_rec);
    LOG("录手柄：写 %s", g_rpath); return 1;
}
static void rec_note(uint32_t b, uint64_t s) {   // HID 线程，约 60 Hz
    if (b == g_rb && s == g_rs) return;
    pthread_mutex_lock(&g_rmu);
    if (rec_open()) {
        g_rb = b; g_rs = s; uint64_t f = s2a_ap_frames();
        fprintf(g_rec, "%llu\t%#x\t%d\t%d\t%d\t%d\t%llu\n", (unsigned long long)f, b, (int16_t)(uint16_t)s, (int16_t)(uint16_t)(s >> 16), (int16_t)(uint16_t)(s >> 32), (int16_t)(uint16_t)(s >> 48), (unsigned long long)(rec_ms() - g_rt0));
        if (f >= g_rflush + 30) { fflush(g_rec); g_rflush = f; }
    }
    pthread_mutex_unlock(&g_rmu);
}
// C# 存档提交时调（services InputPump 按符号查，Mac 宿主没有这个导出）：返回本存档点的副本目录 <同名>.save<N>（C# 拷存档进去），不录时返回 NULL。
//   返回的缓冲在下一次调用前有效（调用方是 FS 服务线程，Commit 串行）
__attribute__((visibility("default"), used)) const char *s2a_padrec_mark(void) {
    const char *ret = NULL;
    pthread_mutex_lock(&g_rmu);
    if (rec_open()) {
        uint64_t f = s2a_ap_frames(); int n = ++g_nsave;
        fprintf(g_rec, "%llu\t存档\t%d\t%llu\n", (unsigned long long)f, n, (unsigned long long)(rec_ms() - g_rt0)); fflush(g_rec);
        snprintf(g_rsave, sizeof g_rsave, "%.*s.save%d", (int)strlen(g_rpath) - 4, g_rpath, n);
        char png[1200]; snprintf(png, sizeof png, "%s.png", g_rsave);
        if (s2a_ap_snapshot) s2a_ap_snapshot(png);
        LOG("录手柄：第 %d 次存档提交（帧 %llu），截图 %s", n, (unsigned long long)f, png); ret = g_rsave;
    }
    pthread_mutex_unlock(&g_rmu);
    return ret;
}

// 按键位 = HidNpadButton 位序（Ryujinx ControllerKeys 同序）
enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN };
static _Atomic uint32_t g_btn, g_latch;   // g_latch：按下沿锁存——点按的按下与抬起落在两次取之间时，保证 HID 线程至少取到一次
static _Atomic uint64_t g_sticks;   // lx | ly << 16 | rx << 32 | ry << 48（各 int16）
static _Atomic int g_reads;

// C# InputPump 查这个导出接到 InputHook：返回按键位，sticks[4] = 左 x / y、右 x / y（±32767，上为正）
__attribute__((visibility("default"), used)) uint32_t s2a_vpad_read(int32_t *sticks) {
    uint64_t s = atomic_load_explicit(&g_sticks, memory_order_acquire);
    for (int i = 0; i < 4; i++) sticks[i] = (int16_t)(uint16_t)(s >> (16 * i));
    if (atomic_fetch_add(&g_reads, 1) == 0) LOG("虚拟手柄：HID 线程开始取触屏虚拟手柄输入");
    uint32_t b = atomic_load_explicit(&g_btn, memory_order_acquire) | atomic_exchange_explicit(&g_latch, 0, memory_order_acq_rel);
    rec_note(b, s);
    return b;
}

@interface S2AVPadView : UIView @end
@implementation S2AVPadView {
    NSArray<UILabel *> *_keys;                         // 可见按键（tag = 位号）
    NSMapTable<UITouch *, NSNumber *> *_held;          // 触点 → 位号（按键）/ -1 左摇杆 / -2 右摇杆
    CGPoint _c[2]; UITouch *_stick[2]; UIView *_ring[2], *_knob[2];
    int16_t _ax[4]; uint32_t _stickPress;              // 摇杆量；双击按下的 LS / RS 位
    NSTimeInterval _lastUp[2]; CGPoint _lastUpAt[2];
    NSTimer *_fade;
}
static const CGFloat kStickR = 60, kFace = 27, kHit = 10;
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.multipleTouchEnabled = YES; self.backgroundColor = UIColor.clearColor; self.layer.zPosition = 1000;   // 盖在渲染器后挂的 Metal 层之上
    _held = [NSMapTable strongToStrongObjectsMapTable];
    NSArray *spec = @[@[@"A", @(B_A)], @[@"B", @(B_B)], @[@"X", @(B_X)], @[@"Y", @(B_Y)], @[@"ZL", @(B_ZL)], @[@"L", @(B_L)], @[@"R", @(B_R)], @[@"ZR", @(B_ZR)],
                      @[@"－", @(B_MINUS)], @[@"＋", @(B_PLUS)], @[@"▲", @(B_UP)], @[@"▼", @(B_DOWN)], @[@"◀︎", @(B_LEFT)], @[@"▶︎", @(B_RIGHT)]];
    NSMutableArray *ks = [NSMutableArray array];
    for (NSArray *s in spec) { UILabel *l = [UILabel new]; l.text = s[0]; l.tag = [s[1] integerValue]; l.textAlignment = NSTextAlignmentCenter;
        l.textColor = [UIColor colorWithWhite:1 alpha:0.9]; l.font = [UIFont boldSystemFontOfSize:l.tag >= B_LEFT ? 13 : 17];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35]; l.layer.borderWidth = 1.5; l.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor; l.layer.masksToBounds = YES;
        [self addSubview:l]; [ks addObject:l]; }
    _keys = ks;
    for (int i = 0; i < 2; i++) {
        _ring[i] = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 2 * kStickR + 4, 2 * kStickR + 4)]; _ring[i].layer.cornerRadius = kStickR + 2;
        _ring[i].layer.borderWidth = 2; _ring[i].layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor; _ring[i].backgroundColor = [UIColor colorWithWhite:0 alpha:0.2];
        _knob[i] = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 52, 52)]; _knob[i].layer.cornerRadius = 26; _knob[i].backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        _ring[i].hidden = _knob[i].hidden = YES; _ring[i].userInteractionEnabled = _knob[i].userInteractionEnabled = NO; [self addSubview:_ring[i]]; [self addSubview:_knob[i]];
    }
    [self wake];
    return self;
}
// 布局（pt，横屏，避开安全区）：数值同设计稿 §6.1
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height; UIEdgeInsets in = self.safeAreaInsets;
    CGFloat sl = MAX(in.left, 16), sr = MAX(in.right, 16), sb = MAX(in.bottom, 8);
    CGFloat fx = W - sr - 92, fy = H - sb - 112, sp = 50, dx = sl + 66, dy = 128, ds = 26;
    for (UILabel *l in _keys) {
        CGPoint c; CGSize z; CGFloat rad;
        switch (l.tag) {
            case B_A: c = CGPointMake(fx + sp, fy); break; case B_B: c = CGPointMake(fx, fy + sp); break;
            case B_X: c = CGPointMake(fx, fy - sp); break; case B_Y: c = CGPointMake(fx - sp, fy); break;
            case B_ZL: c = CGPointMake(sl + 96, 30); break; case B_L: c = CGPointMake(sl + 162, 30); break;
            case B_R: c = CGPointMake(W - sr - 162, 30); break; case B_ZR: c = CGPointMake(W - sr - 96, 30); break;
            case B_MINUS: c = CGPointMake(W / 2 - 46, 26); break; case B_PLUS: c = CGPointMake(W / 2 + 46, 26); break;
            case B_UP: c = CGPointMake(dx, dy - ds); break; case B_DOWN: c = CGPointMake(dx, dy + ds); break;
            case B_LEFT: c = CGPointMake(dx - ds, dy); break; default: c = CGPointMake(dx + ds, dy); break;
        }
        if (l.tag <= B_Y) { z = CGSizeMake(2 * kFace, 2 * kFace); rad = kFace; }
        else if (l.tag == B_L || l.tag == B_R || l.tag == B_ZL || l.tag == B_ZR) { z = CGSizeMake(56, 30); rad = 15; }
        else if (l.tag == B_PLUS || l.tag == B_MINUS) { z = CGSizeMake(32, 32); rad = 16; }
        else { z = CGSizeMake(30, 30); rad = 6; }
        l.bounds = CGRectMake(0, 0, z.width, z.height); l.center = c; l.layer.cornerRadius = rad;
    }
}
- (int)keyAt:(CGPoint)p { for (UILabel *l in _keys) if (CGRectContainsPoint(CGRectInset(l.frame, -kHit, -kHit), p)) return (int)l.tag; return -1; }
- (void)publish {
    uint32_t b = _stickPress; for (NSNumber *n in _held.objectEnumerator) if (n.intValue >= 0) b |= 1u << n.intValue;
    atomic_store_explicit(&g_sticks, (uint64_t)(uint16_t)_ax[0] | (uint64_t)(uint16_t)_ax[1] << 16 | (uint64_t)(uint16_t)_ax[2] << 32 | (uint64_t)(uint16_t)_ax[3] << 48, memory_order_release);
    uint32_t old = atomic_exchange_explicit(&g_btn, b, memory_order_acq_rel); atomic_fetch_or_explicit(&g_latch, b & ~old, memory_order_acq_rel);
    for (UILabel *l in _keys) l.backgroundColor = [UIColor colorWithWhite:(b >> l.tag & 1) ? 1 : 0 alpha:(b >> l.tag & 1) ? 0.45 : 0.35];
}
// 显示：碰屏即显示（按键 75% 不透明度，叠上底色 / 描边的半透明后整体约 30% 遮挡），3 秒无触摸淡出到全隐藏；热区一直有效
- (void)wake {
    [_fade invalidate]; for (UILabel *l in _keys) l.alpha = 0.75;
    _fade = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) { (void)t;
        if (self->_held.count) { [self wake]; return; }
        [UIView animateWithDuration:0.4 animations:^{ for (UILabel *l in self->_keys) l.alpha = 0; }]; }];
}
- (void)moveStick:(int)k to:(CGPoint)p {
    CGFloat dx = (p.x - _c[k].x) / kStickR, dy = (p.y - _c[k].y) / kStickR, m = hypot(dx, dy); if (m > 1) { dx /= m; dy /= m; }
    _ax[2 * k] = (int16_t)lround(dx * 32767); _ax[2 * k + 1] = (int16_t)lround(-dy * 32767);
    _knob[k].center = CGPointMake(_c[k].x + dx * kStickR, _c[k].y + dy * kStickR);
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    [self wake];
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self]; int k = [self keyAt:p];
        if (k >= 0) { [_held setObject:@(k) forKey:t]; continue; }
        int side = p.x < self.bounds.size.width / 2 ? 0 : 1; if (_stick[side]) continue;
        _stick[side] = t; _c[side] = p; [_held setObject:@(-1 - side) forKey:t];
        if (t.timestamp - _lastUp[side] < 0.3 && hypot(p.x - _lastUpAt[side].x, p.y - _lastUpAt[side].y) < 40) _stickPress |= 1u << (side ? B_RS : B_LS);   // 双击：第二下按住 = 摇杆按下
        _ring[side].center = p; _knob[side].center = p; _ring[side].hidden = _knob[side].hidden = NO;
        [self moveStick:side to:p];
    }
    [self publish];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        NSNumber *n = [_held objectForKey:t]; if (!n) continue; CGPoint p = [t locationInView:self];
        if (n.intValue < 0) { [self moveStick:-1 - n.intValue to:p]; continue; }
        if (n.intValue >= B_LEFT) { int k = [self keyAt:p]; if (k >= B_LEFT) [_held setObject:@(k) forKey:t]; }   // 十字键可以滑着换方向
    }
    [self publish];
}
- (void)end:(NSSet<UITouch *> *)ts {
    for (UITouch *t in ts) {
        NSNumber *n = [_held objectForKey:t]; if (!n) continue; [_held removeObjectForKey:t];
        if (n.intValue < 0) { int side = -1 - n.intValue; _stick[side] = nil; _ax[2 * side] = _ax[2 * side + 1] = 0; _stickPress &= ~(1u << (side ? B_RS : B_LS));
            _ring[side].hidden = _knob[side].hidden = YES; _lastUp[side] = t.timestamp; _lastUpAt[side] = [t locationInView:self]; }
    }
    [self publish]; [self wake];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self end:ts]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self end:ts]; }
@end

void s2a_vpad_attach(UIView *root) {
    S2AVPadView *v = [[S2AVPadView alloc] initWithFrame:root.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [root addSubview:v];
    LOG("虚拟手柄：已挂到根视图（基础版：完整 Switch 按键 + 左右浮动摇杆）");
}

// iOS virtual gamepad, in the look and behaviour of the MelonX (MeloNX) on-screen controller.
//   Every control is edited on its own (A / B / X / Y, the four D-pad arrows, ZL / L / ZR / R, L3 / R3, - / +, the two sticks); the old 2D / 3D presets are gone and every control is on screen by default.
//   Appearance comes from MelonX: an SF Symbol icon, a halo shape behind it at 1.25x the icon size, the 45 / 35 / 70x40 point sizes, and the 11 colour themes with their exact values.
//   Positions stay ours (the arrangement the player already knows) and are stored per screen orientation, so portrait and landscape are laid out and edited separately.
//   The gear at 10,10 from the screen edge opens the in-game menu (edit the buttons, screen orientation, button theme, performance overlay, exit); it wakes on touch and fades to alpha 0.05 after 3 s, as MelonX does.
//   Sticks have MelonX's two modes. Fixed: tap-to-move or drag, tap force, dead zone, sensitivity, spring return to centre. Floating: spawned where the finger lands, over the whole half of the screen or inside a region that can be dragged and resized.
//   The performance overlay (FPS + frame time, RAM) sits at the top right by default and diffs the host's presented-frame counter.
//   The layout editor is a transparent overlay: tap a control to select it, drag to move, two fingers to resize, hold to reset; the Chinese property card edits size, opacity, hiding, toggle mode and the stick options.
//   Nothing sends a key while the editor is open (the overlay owns the touches and the pad releases every key first) and the game runs behind a dim layer.
//   One control per NSUserDefaults entry, in u units measured from its home edge (u = 1 at a 430 point landscape short side and a 932 point portrait long side), so a layout scales with the screen; each game is its own app, so a layout is per game.
//   A foldable iPhone moves the same scene between an outer and an inner panel: the scale follows the panel and every frame is laid out from the current bounds, so one saved layout serves both panels (no fold state is stored).
//   The controls stand down while a physical controller is connected (the gear and the overlay stay); physical controllers keep every button and map by position: bottom = B, right = A, left = Y, top = X.
//   S2Arm 移植（ios/dmpad.m）：按键出口改成 s2a_pad_update(S2A_PAD_TOUCH, …)；实体手柄交给 ios/controller.m（这里只判断 s2a_pad_has_controller()）；
//   设置按游戏隔离（DmCfgDefaults()，见 ios/dmpad_compat.m）；朝向由齿轮菜单的竖屏 / 横屏切换（Info.plist 已声明横竖屏）；画面填充 / 画面自定义 / 金手指 / 退出已接通。
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <mach/mach.h>
#include <math.h>
#include "dm_input.h"
#include "game_profile.h"
#include "dmpad_compat.h"
#include "dmpad.h"
#include <UniformTypeIdentifiers/UniformTypeIdentifiers.h>   // 「导入金手指 txt」的选择器要 UTType
#if __has_include(<os/proc.h>)
#include <os/proc.h>   // os_proc_available_memory()：离被 jetsam 杀掉还有多少（性能叠层的内存行 + 每 5 秒的日志）
#endif
#import "DmCheats.h"
#import "DmSettings.h"                   // 与启动器共用的一份设置（UserDefaults: DmPadPref）
#import "app_settings.h"                 // s2a_settings_present()：菜单里的「打开 S2Arm 设置」
#include "hle.h"
#include "front.h"   // dm_touch / DM_CONTACT_IOS：把没被控件接住的触摸交给游戏的触摸屏      // dm_guest_frame(): the presented-frame counter the FPS readout diffs
#include "dm.h"       // dm_host_shutdown(): the menu's exit entry
#include "s2a_pad.h"  // s2a_pad_update(S2A_PAD_TOUCH, …) / s2a_pad_has_controller()

// The front end's hooks (front_ios.m) and the orientation helpers; all four are defined at the end of this file
UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
unsigned dm_pad_supported_orientations(void);
void dm_pad_rotate_to(int portrait);
void mtl_fps_override(int fps);   // nvn_mtl.m: 0 = the game profile's pace, 30 / 60 / 120 = the gear menu / launcher choice
int mtl_display_hz(void);         // nvn_mtl.m: the panel's maximum refresh rate (60 on a 15 Plus, 120 on a ProMotion Pro), 0 without a window
void front_game_frame_apply(void);   // front_ios.m: re-lay the game view with the current 画面缩放 / 移动 (weak: the Mac host has no game view)
void front_pic_state(CGFloat *scale, CGFloat *sx, CGFloat *sy, CGFloat *dx, CGFloat *dy, int *editing);   // DmGamepad.m: the current orientation's picture scale / stretch / offset, and whether the overlay is armed
CGRect front_pic_rect(void);   // front_ios.m: the game's picture on screen in window coordinates — the dashed frame and its handles sit on this
int dm_pad_fill(void);         // DmGamepad.m: the 画面填充 mode (front_ios.m 算虚线框大小时要区分黑边还是铺满)
void mtl_shdump_set(int on); int mtl_shdump_enabled(void); int mtl_shdump_count(void); const char *mtl_shdump_path(void);   // nvn_mtl.m: the missing-shader capture (人物没画出来时抓运行期编译的着色器)
void mtl_present_fill(int mode);
void mtl_present_src_size(unsigned *w, unsigned *h);   // nvn_mtl.m：最近一次出图的源尺寸（解锁 / 锁定时算画面框的宽高比）
void dm_pad_screen_rect(double *x, double *y, double *w, double *h);   // front_ios.m：画面矩形（present 与触摸共用一份）
void dm_touch_set_from(const dm_touch *t, int n, int source);   // hle_touch.c
void dm_touch_cancel_from(int source);
enum { O_GAME = 5 };   // 没落到任何控件上的触摸：交给游戏的触摸屏  // nvn_mtl.m: 0 = keep the game's aspect (black bars), 1 = stretch to fill, 2 = crop to fill

// ---- nn::hid button bits (the dm_input.h order) ----
enum { H_A = 0, H_B, H_X, H_Y, H_LS, H_RS, H_L, H_R, H_ZL, H_ZR, H_PLUS, H_MINUS, H_LEFT, H_UP, H_RIGHT, H_DOWN, H_N };

// ---- The controls, one entry per control ----
enum { CT_A, CT_B, CT_X, CT_Y, CT_UP, CT_DOWN, CT_LEFT, CT_RIGHT, CT_L3, CT_R3,
       CT_L, CT_R, CT_ZL, CT_ZR, CT_MINUS, CT_PLUS, CT_LSTICK, CT_RSTICK, CT_C1, CT_C2, CT_C3, CT_C4, CT_C5, CT_C6, CT_N };   // combos are appended: the stored indices of the existing controls must not move
enum { K_FACE, K_DPAD, K_CLICK, K_TRIG, K_SYS, K_STICK, K_COMBO };   // how a control is drawn and grabbed
enum { OR_L = 0, OR_P = 1 };                               // the two stored layouts

// anchor: 0 = dx from the left edge, 1 = from the right edge, 2 = signed from the midline
// side:   0 = dy below the top edge, 1 = dy above the bottom edge
// corner: 1 = the bottom-corner rectangle (the control may reach halfway into the side safe-area inset)
// w / h:  the MelonX icon size in points (45, 35 for - / +, 70x40 for the triggers); the halo and the touch area are 1.25x that
typedef struct {
    const char *name; int kind, hid, anchor, side, corner; CGFloat w, h;
    const char *sym, *fb;               // SF Symbol name, and the glyph drawn when the system has no such symbol
    CGFloat dxL, dyL, dxP, dyP;         // default position in u, landscape / portrait
    unsigned char hidP;                 // hidden by default in portrait (where there is no room for it)
} DmCtlDef;
static const DmCtlDef k_def[CT_N] = {
    [CT_A]     = {"A", K_FACE, H_A, 1, 1, 1, 45, 45, "a.circle.fill", "A", 49, 89, 35, 261, 0},
    [CT_B]     = {"B", K_FACE, H_B, 1, 1, 1, 45, 45, "b.circle.fill", "B", 101, 37, 85, 206, 0},
    [CT_X]     = {"X", K_FACE, H_X, 1, 1, 1, 45, 45, "x.circle.fill", "X", 101, 144, 85, 326, 0},
    [CT_Y]     = {"Y", K_FACE, H_Y, 1, 1, 1, 45, 45, "y.circle.fill", "Y", 154, 89, 132, 261, 0},
    [CT_UP]    = {"方向键 上", K_DPAD, H_UP, 0, 1, 1, 45, 45, "arrowtriangle.up.circle.fill", "▲", 264, 104, 95, 156, 0},
    [CT_DOWN]  = {"方向键 下", K_DPAD, H_DOWN, 0, 1, 1, 45, 45, "arrowtriangle.down.circle.fill", "▼", 264, 34, 95, 86, 0},
    [CT_LEFT]  = {"方向键 左", K_DPAD, H_LEFT, 0, 1, 1, 45, 45, "arrowtriangle.left.circle.fill", "◀", 229, 69, 60, 121, 0},
    [CT_RIGHT] = {"方向键 右", K_DPAD, H_RIGHT, 0, 1, 1, 45, 45, "arrowtriangle.right.circle.fill", "▶", 299, 69, 130, 121, 0},
    [CT_L3]    = {"L3 按下", K_CLICK, H_LS, 0, 0, 0, 45, 45, "l.joystick.press.down.fill", "L3", 352, 372, 44, 36, 0},
    [CT_R3]    = {"R3 按下", K_CLICK, H_RS, 1, 0, 0, 45, 45, "r.joystick.press.down.fill", "R3", 339, 372, 44, 36, 0},
    [CT_L]     = {"L 肩键", K_TRIG, H_L, 0, 0, 0, 70, 40, "l.rectangle.roundedbottom.fill", "L", 34, 102, 41, 396, 0},
    [CT_R]     = {"R 肩键", K_TRIG, H_R, 1, 0, 0, 70, 40, "r.rectangle.roundedbottom.fill", "R", 33, 187, 44, 396, 0},
    [CT_ZL]    = {"ZL 扳机", K_TRIG, H_ZL, 0, 0, 0, 70, 40, "zl.rectangle.roundedtop.fill", "ZL", 34, 52, 41, 468, 0},
    [CT_ZR]    = {"ZR 扳机", K_TRIG, H_ZR, 1, 0, 0, 70, 40, "zr.rectangle.roundedtop.fill", "ZR", 33, 119, 44, 468, 0},
    [CT_MINUS] = {"- 选择", K_SYS, H_MINUS, 2, 0, 0, 35, 35, "minus.circle.fill", "−", -29, 372, -33, 63, 0},
    [CT_PLUS]  = {"+ 开始", K_SYS, H_PLUS, 2, 0, 0, 35, 35, "plus.circle.fill", "+", 41, 372, 25, 63, 0},
    [CT_LSTICK] = {"左摇杆", K_STICK, -1, 0, 1, 1, 32, 32, NULL, NULL, 122, 101, 110, 261, 0},
    [CT_RSTICK] = {"右摇杆", K_STICK, -1, 1, 1, 1, 32, 32, NULL, NULL, 254, 71, 107, 123, 0},
    // Combo keys: hidden until added from the gear menu; each plays an ordered sequence. The circled numbers keep the slots apart.
    [CT_C1]    = {"组合 1", K_COMBO, -1, 0, 0, 0, 45, 45, "1.circle.fill", "1", 100, 60, 100, 60, 1},
    [CT_C2]    = {"组合 2", K_COMBO, -1, 0, 0, 0, 45, 45, "2.circle.fill", "2", 170, 60, 170, 60, 1},
    [CT_C3]    = {"组合 3", K_COMBO, -1, 0, 0, 0, 45, 45, "3.circle.fill", "3", 240, 60, 240, 60, 1},
    [CT_C4]    = {"组合 4", K_COMBO, -1, 0, 0, 0, 45, 45, "4.circle.fill", "4", 100, 130, 100, 130, 1},
    [CT_C5]    = {"组合 5", K_COMBO, -1, 0, 0, 0, 45, 45, "5.circle.fill", "5", 170, 130, 170, 130, 1},
    [CT_C6]    = {"组合 6", K_COMBO, -1, 0, 0, 0, 45, 45, "6.circle.fill", "6", 240, 130, 240, 130, 1},
};
static inline int ori_of(CGSize sz) { return sz.height > sz.width ? OR_P : OR_L; }
// The D-pad's four keys sit close together, so their default icon is a touch smaller than the rest (the user can still scale each one in the editor).
static inline CGFloat def_size(int k) { return k_def[k].kind == K_DPAD ? .8 : 1; }

// ---- MelonX's constants ----
static const CGFloat
    K_CORNER_IN = 0.5,      // how far the bottom-corner controls reach toward the side edges (half the padding)
    K_PAD = 16,             // MelonX lays the controller over the whole screen with a uniform .padding(); the control positions are measured from the bounds inset by this, not from the device safe area
    K_HALO = 1.25,          // the halo and the touch area are this times the icon size (ButtonView.swift)
    K_DRAG_D = 160,         // fixed stick drag diameter (Joystick.swift)
    K_BASE_K = 1.25,        // the stick base disc is 1.25x the knob (32 -> 40)
    K_FLOAT_D = 140,        // floating stick base diameter (FloatingJoystickOverlay.swift)
    K_FLOAT_NUB = 0.25,     // the floating nub is 25% of the base
    K_DRAG_MIN = 8,         // a fixed stick without tap-to-move wakes after this much movement
    K_GEAR = 44, K_GEAR_EDGE = 10;   // the settings gear: 44 pt at 10,10 from the screen edge

// ---- What the player changed ----
typedef struct { CGFloat dx, dy, size, alpha; unsigned char hidden, toggle; } DmCtlVal;
typedef struct { CGFloat x, y, w, h; } DmRectN;    // a floating-region rectangle, normalized to the screen
static DmCtlVal g_val[2][CT_N];
static DmRectN g_reg[2][2];                         // [orientation][side]
// MelonX keeps these app-wide in its settings; the same here, in one dictionary
static NSString *const k_ctl_key = @"DmPadCtl";     // { "<ori>": { "<ctl>": [dx,dy,size,alpha,hidden,toggle] }, "r<ori><side>": [x,y,w,h] }
static NSString *const k_pref_key = @"DmPadPref";   // theme, overall scale and opacity, the stick options, the overlay switches, rotation lock
static NSString *const k_ver_key = @"DmPadModelVer";   // bumped when the default layout's coordinate model changes, so stale per-control stores are dropped once
static NSString *g_theme = @"classic";
static CGFloat g_scale = 1;    // MelonX "On-ScreenControllerScale"
static CGFloat g_dim = 1;      // MelonX "On-ScreenControllerOpacity"
static int g_slide = 1;        // MelonX "buttonSlide": a finger may slide from one key to the next
static int g_dpadStick = 0;    // MelonX "joystickDpad": the D-pad drives the left stick axes instead of the keys
static int g_jmode[2], g_jarea[2], g_jbg[2], g_tapMove[2];   // fixed / floating, region or whole half, always show the base, tap to move
static CGFloat g_jdead[2], g_jtap[2];                        // dead zone and tap force per stick
static CGFloat g_sens = 1.2, g_fsize = 1, g_fop = 1, g_fdead = 0.08;   // the sensitivity is shared by both stick modes, as in MelonX
// Combo keys: each slot is an ordered sequence of buttons (max 8), played one after another; global, not per orientation.
#define COMBO_MAX 8
#define COMBO_SLOTS 6
static uint8_t g_seq[COMBO_SLOTS][COMBO_MAX];
static int g_seq_n[COMBO_SLOTS];
static float g_seq_gap[COMBO_SLOTS];    // ms between one key's release and the next key's press (the combo card's 间隔)
static uint8_t g_seq_hold[COMBO_SLOTS]; // 1 = hold: the checked keys go down together while the combo is held
static uint8_t g_seq_holdlast[COMBO_SLOTS]; // 1 = sequence mode: keep the last key down while the finger stays (the combo card's 按住最后一个按键)
static float g_seq_holdms[COMBO_SLOTS];    // 每个键按住的毫秒数（组合键卡片的「每键时长」，原来固定 80 ms）
static uint8_t g_seq_keep[COMBO_SLOTS];    // 1 = 顺序按住：按键按顺序落下并且都保持到手指抬起（先 ZL 瞄准 → 再 ZR 开火）
static const char *k_btnName[16] = {"A", "B", "X", "Y", "L3", "R3", "L", "R", "ZL", "ZR", "+", "-", "←", "↑", "→", "↓"};
static NSString *seq_summary(int slot) {
    if (slot < 0 || slot >= COMBO_SLOTS || g_seq_n[slot] <= 0) return @"空";
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < g_seq_n[slot]; i++) [a addObject:@(k_btnName[g_seq[slot][i]])];
    return [a componentsJoinedByString:@" → "];
}
static uint32_t combo_mask(int slot) {   // every checked key of the slot, as one bit mask
    uint32_t m = 0; if (slot < 0 || slot >= COMBO_SLOTS) return 0;
    for (int i = 0; i < g_seq_n[slot]; i++) m |= 1u << g_seq[slot][i];
    return m;
}
static int g_fps = 1, g_ram = 1, g_hudPos = 0, g_rotLock = 1, g_rotTo = 0, g_rumble = 1, g_rumbleLv = 1, g_btnHap = 1, g_fpsmode = 0, g_fill = 0, g_fillUser = 0, g_hideAll = 0;   // overlay rows / position / rotation lock / the orientation to keep / HD-style haptics / its strength 0-4 / the virtual pad's press tick / 0 = profile pace, else 60 / 120 / present fill mode / hide every pad control
// ---- 画面自定义（缩放 / 拉伸 / 移动），横屏竖屏各存一份 ----
// The game's 16:9 picture is drawn into a fitted rectangle; scale stretches it evenly about its centre, sx / sy stretch X and Y separately (「不限制比例」,
// off by default so the picture stays in proportion), dx / dy slide it. The player edits them by dragging / pinching the screen in 「编辑画面位置大小」 mode.
// The fill mode above still decides what happens inside that rectangle.
typedef struct { CGFloat scale, sx, sy, dx, dy; } DmPic;
static DmPic g_pic[2];   // [OR_L] / [OR_P]
static int g_picFree[2];  // 每个方向自己一份：1 = 已解锁比例（可单独改宽 / 高），0 = 锁定。横屏解锁不影响竖屏
static void fill_apply(int ori);   // 下面定义：解锁比例时把生效的画面填充强制成拉伸铺满，否则拖边只改黑边
static int g_picOri;               // 当前方向（cfg_read 时手柄还没建，靠它拿到正确的初始填充）
static int g_picEdit;    // the picture drag / pinch overlay is on, so no key and no touch reaches the game while it is
static int g_picCfgRead;   // cfg_read() applies the saved picture once; a later read (asked before the pad exists) must not undo a live edit
static void fill_apply(int ori) {   // 生效的画面填充：解锁比例时拉伸铺满，否则用菜单里选的档位。保持比例时 16:9 画面永远按比例塞在层里，拖宽 / 高只改黑边，看起来就是"改不动 / 另一边跟着动"
    int e = g_picFree[ori] ? 1 : g_fillUser;
    if (e != g_fill) { g_fill = e; mtl_present_fill(e); }
}
static int g_cfg_read;   // the front end asks for the orientation mask before the pad view exists, so the file may still be unread
static const DmRectN k_regDef[2][2] = {   // the default float areas, each centered on its stick's nominal position (see k_def) so the region box overlaps the stick instead of dropping to the bottom edge
    {{0.01, 0.51, 0.26, 0.44}, {0.59, 0.58, 0.26, 0.44}},   // landscape: left stick (0.14,0.73), right stick (0.72,0.80)
    {{0.07, 0.58, 0.40, 0.25}, {0.53, 0.73, 0.40, 0.25}},   // portrait: left stick (0.27,0.70), right stick (0.73,0.85)
};
static void cfg_defaults(void) {
    g_theme = @"classic"; g_scale = 1; g_dim = 1; g_slide = 1; g_dpadStick = 0;
    g_sens = 1.2; g_fsize = 1; g_fop = 1; g_fdead = 0.08;
    g_fps = 0; g_ram = 0; g_hudPos = 0; g_rotLock = 1; g_rotTo = 0; g_rumble = 1; g_rumbleLv = 1; g_btnHap = 1; g_fpsmode = 0; g_fill = 0; g_fillUser = 0; g_hideAll = 0;   // 帧率 / 内存叠层默认关闭（启动器与齿轮菜单里可打开）
    for (int i = 0; i < 2; i++) { g_pic[i] = (DmPic){1, 1, 1, 0, 0}; g_picFree[i] = 0; }   // 画面自定义：横竖屏各一份，默认居中 1:1、锁定比例
    for (int i = 0; i < 2; i++) { g_jmode[i] = 0; g_jarea[i] = 0; g_jbg[i] = 0; g_tapMove[i] = 1; g_jdead[i] = 0.08; g_jtap[i] = 0.7; }
    for (int o = 0; o < 2; o++) {
        for (int k = 0; k < CT_N; k++) {
            const DmCtlDef *d = &k_def[k];
            g_val[o][k] = (DmCtlVal){o == OR_P ? d->dxP : d->dxL, o == OR_P ? d->dyP : d->dyL, def_size(k), 1, (unsigned char)(o == OR_P ? d->hidP : 0), 0};
        }
        for (int i = 0; i < 2; i++) g_reg[o][i] = k_regDef[o][i];
        for (int k = CT_C1; k <= CT_C6; k++) g_val[o][k].hidden = 1;   // a combo slot is off until the gear menu adds it
    }
    for (int i = 0; i < COMBO_SLOTS; i++) { g_seq_n[i] = 0; g_seq_gap[i] = 40; g_seq_holdms[i] = 80; g_seq_hold[i] = 1; g_seq_holdlast[i] = 0; g_seq_keep[i] = 0; }   // new combo: empty, 40 ms apart, 80 ms per key, hold all（三种按住方式互斥）
}
static CGFloat clampv(id v, CGFloat lo, CGFloat hi, CGFloat dflt) {
    if (![v isKindOfClass:NSNumber.class]) return dflt;
    return fmax(lo, fmin(hi, [v doubleValue]));
}
static NSInteger ivalue(id v, NSInteger dflt) { return [v isKindOfClass:NSNumber.class] ? [v integerValue] : dflt; }
static void cfg_read(void) {
    cfg_defaults();
    NSUserDefaults *ud = DmCfgDefaults();
    if (ivalue([ud objectForKey:k_ver_key], 0) < 4) { [ud removeObjectForKey:k_ctl_key]; [ud setObject:@4 forKey:k_ver_key]; }   // the bounds-based model retires the old safe-area coordinates
    NSDictionary *st = [ud dictionaryForKey:k_ctl_key];
    for (int o = 0; o < 2; o++) {
        NSDictionary *d = [st[@(o).stringValue] isKindOfClass:NSDictionary.class] ? st[@(o).stringValue] : nil;
        for (int k = 0; k < CT_N; k++) {
            NSArray *a = [d[@(k).stringValue] isKindOfClass:NSArray.class] ? d[@(k).stringValue] : nil;
            if (a.count >= 6) g_val[o][k] = (DmCtlVal){[a[0] doubleValue], [a[1] doubleValue], clampv(a[2], .5, 5, 1), clampv(a[3], .05, 1, 1),
                                                       (unsigned char)[a[4] boolValue], (unsigned char)[a[5] boolValue]};
        }
        for (int i = 0; i < 2; i++) {
            NSArray *a = [st[[NSString stringWithFormat:@"r%d%d", o, i]] isKindOfClass:NSArray.class] ? st[[NSString stringWithFormat:@"r%d%d", o, i]] : nil;
            if (a.count >= 4) g_reg[o][i] = (DmRectN){[a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue]};
        }
    }
    NSDictionary *p = [DmCfgDefaults() dictionaryForKey:k_pref_key];
    if (![p isKindOfClass:NSDictionary.class]) { dm_haptics_set_enabled(g_rumble); dm_haptics_set_strength(g_rumbleLv); dm_haptics_set_buttons(g_btnHap); mtl_present_fill(g_fill); s2a_rumble_set_enabled(g_rumble); s2a_rumble_set_level(g_rumbleLv); return; }
    if ([p[@"theme"] isKindOfClass:NSString.class]) g_theme = p[@"theme"];
    g_scale = clampv(p[@"scale"], .5, 5, 1); g_dim = clampv(p[@"dim"], .05, 1, 1); g_sens = clampv(p[@"sens"], 1, 3, 1.2);
    g_fsize = clampv(p[@"fsize"], .5, 2, 1); g_fop = clampv(p[@"fop"], .05, 1, 1); g_fdead = clampv(p[@"fdead"], 0, .5, .08);
    g_slide = ivalue(p[@"slide"], 1); g_dpadStick = ivalue(p[@"dpadStick"], 0);
    g_fps = ivalue(p[@"fps"], 0); g_ram = ivalue(p[@"ram"], 0); g_hudPos = ivalue(p[@"hud"], 0); g_rotLock = ivalue(p[@"lock"], 1);
    g_rotTo = ivalue(p[@"rotTo"], 0) ? 1 : 0;   // the locked orientation survives a relaunch; without it a portrait-locked app opened in landscape again
    g_rumble = ivalue(p[@"rumble"], 1);
    g_rumbleLv = (int)ivalue(p[@"rumblelv"], 1); if (g_rumbleLv < 0 || g_rumbleLv > 4) g_rumbleLv = 1;   // 弱 / 标准 / 强 / 更强 / 最强 (DmHaptics.m's 4x … 12x gain)
    g_btnHap = ivalue(p[@"btnhap"], 1) != 0;   // the virtual pad's own press tick
    g_fill = (int)ivalue(p[@"fill"], 0); if (g_fill < 0 || g_fill > 2) g_fill = 0;   // 0 keep aspect, 1 stretch, 2 crop (nvn_mtl.m)
    int freeOld = ivalue(p[@"picfree"], 0) != 0;   // 旧存档的全局解锁开关，读到就当作两个方向的初值
    for (int o = 0; o < 2; o++) {
        g_picFree[o] = freeOld;   // 下面有6 个值时按方向前第 6 个覆盖
        // the picture's own scale, stretch and place, per orientation (3 numbers = a saved 按比例 setup)
        NSArray *a = [p[[NSString stringWithFormat:@"pic%d", o]] isKindOfClass:NSArray.class] ? p[[NSString stringWithFormat:@"pic%d", o]] : nil;
        if (a.count >= 5) g_pic[o] = (DmPic){clampv(a[0], .3, 3, 1), clampv(a[3], .2, 8, 1), clampv(a[4], .2, 8, 1), clampv(a[1], -1, 1, 0), clampv(a[2], -1, 1, 0)};
        if (a.count >= 6) g_picFree[o] = [a[5] integerValue] != 0;
    }
    g_hideAll = ivalue(p[@"hideall"], 0) != 0;   // hide every pad control, leaving the gear and the overlay
    { int cv = (int)ivalue(p[@"combover"], 0);   // bumped when a new combo should start empty; older saved defaults are ignored once
      if (cv >= 2) {
          NSArray *ca = [p[@"comboseq"] isKindOfClass:NSArray.class] ? p[@"comboseq"] : nil;
          for (int i = 0; i < COMBO_SLOTS && i < (int)ca.count; i++) {
              NSArray *s = [ca[i] isKindOfClass:NSArray.class] ? ca[i] : nil; int n = 0;
              for (int j = 0; j < (int)s.count && n < COMBO_MAX; j++) { int b = (int)[s[j] integerValue]; if (b >= 0 && b < 16) g_seq[i][n++] = (uint8_t)b; }
              g_seq_n[i] = n;
          }
          NSArray *ga = [p[@"combogap"] isKindOfClass:NSArray.class] ? p[@"combogap"] : nil;
          for (int i = 0; i < COMBO_SLOTS && i < (int)ga.count; i++) g_seq_gap[i] = fmaxf(0, fminf(200, [ga[i] doubleValue]));
          NSArray *ha = [p[@"combohold"] isKindOfClass:NSArray.class] ? p[@"combohold"] : nil;
          for (int i = 0; i < COMBO_SLOTS && i < (int)ha.count; i++) g_seq_hold[i] = [ha[i] boolValue] ? 1 : 0;
          NSArray *la = [p[@"comboholdlast"] isKindOfClass:NSArray.class] ? p[@"comboholdlast"] : nil;
          for (int i = 0; i < COMBO_SLOTS && i < (int)la.count; i++) g_seq_holdlast[i] = [la[i] boolValue] ? 1 : 0;
          NSArray *sa = [p[@"combostep"] isKindOfClass:NSArray.class] ? p[@"combostep"] : nil;
          for (int i = 0; i < COMBO_SLOTS && i < (int)sa.count; i++) g_seq_holdms[i] = fmaxf(40, fminf(2000, [sa[i] doubleValue]));
          NSArray *ka = [p[@"combokeep"] isKindOfClass:NSArray.class] ? p[@"combokeep"] : nil;
          for (int i = 0; i < COMBO_SLOTS && i < (int)ka.count; i++) g_seq_keep[i] = [ka[i] boolValue] ? 1 : 0;
          for (int i = 0; i < COMBO_SLOTS; i++) { if (g_seq_hold[i]) { g_seq_holdlast[i] = 0; g_seq_keep[i] = 0; } else if (g_seq_holdlast[i]) g_seq_keep[i] = 0; }   // 互斥：按住全部优先，其次按住最后一个
      } }
    g_fpsmode = (int)ivalue(p[@"fpsmode"], 0); if (g_fpsmode != 60 && g_fpsmode != 120) g_fpsmode = 0;
    dm_haptics_set_enabled(g_rumble);
    dm_haptics_set_strength(g_rumbleLv);
    dm_haptics_set_buttons(g_btnHap);
    s2a_rumble_set_enabled(g_rumble);   // 游戏本体震动（存档里的开关与档位）
    s2a_rumble_set_level(g_rumbleLv);
    if (!g_picCfgRead) { g_picCfgRead = 1; front_game_frame_apply(); }   // 存档里的画面位置大小在第一次布局前落位
    fill_apply(g_picOri);
    mtl_fps_override(g_fpsmode);
    for (int i = 0; i < 2; i++) {
        NSString *k = @(i).stringValue;
        g_jmode[i] = ivalue(p[@"jm"][k], 0); g_jarea[i] = ivalue(p[@"ja"][k], 0); g_jbg[i] = ivalue(p[@"jb"][k], 0);
        g_tapMove[i] = ivalue(p[@"jt"][k], 1);
        g_jdead[i] = clampv(p[@"jd"][k], 0, .5, .08); g_jtap[i] = clampv(p[@"jf"][k], .1, 1, .7);
    }
    static int done; if (done) return; done = 1;
    g_cfg_read = 1;
    [DmCfgDefaults() removeObjectForKey:@"DmPadLayout"];   // the retired 2D / 3D model
    [DmCfgDefaults() removeObjectForKey:@"DmPadNodes"];
    [DmCfgDefaults() removeObjectForKey:@"DmPadDim"];
}
static BOOL differs(int o, int k) {
    DmCtlVal v = g_val[o][k]; const DmCtlDef *d = &k_def[k];
    CGFloat dx = o == OR_P ? d->dxP : d->dxL, dy = o == OR_P ? d->dyP : d->dyL;
    unsigned char hid = (unsigned char)((k_def[k].kind == K_COMBO) ? 1 : (o == OR_P ? d->hidP : 0));   // combos are off by default in both orientations
    return fabs(v.dx - dx) > .01 || fabs(v.dy - dy) > .01 || fabs(v.size - def_size(k)) > .001 || fabs(v.alpha - 1) > .001 || v.hidden != hid || v.toggle;
}
static void cfg_write(void) {
    NSMutableDictionary *st = [NSMutableDictionary dictionary];
    for (int o = 0; o < 2; o++) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (int k = 0; k < CT_N; k++) if (differs(o, k))
            d[@(k).stringValue] = @[@(g_val[o][k].dx), @(g_val[o][k].dy), @(g_val[o][k].size), @(g_val[o][k].alpha), @(g_val[o][k].hidden), @(g_val[o][k].toggle)];
        if (d.count) st[@(o).stringValue] = d;
        for (int i = 0; i < 2; i++) {
            DmRectN r = g_reg[o][i], q = k_regDef[o][i];
            if (fabs(r.x - q.x) > .002 || fabs(r.y - q.y) > .002 || fabs(r.w - q.w) > .002 || fabs(r.h - q.h) > .002)
                st[[NSString stringWithFormat:@"r%d%d", o, i]] = @[@(r.x), @(r.y), @(r.w), @(r.h)];
        }
    }
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"theme"] = g_theme; p[@"scale"] = @(g_scale); p[@"dim"] = @(g_dim); p[@"sens"] = @(g_sens);
    p[@"fsize"] = @(g_fsize); p[@"fop"] = @(g_fop); p[@"fdead"] = @(g_fdead);
    p[@"slide"] = @(g_slide); p[@"dpadStick"] = @(g_dpadStick);
    p[@"fps"] = @(g_fps); p[@"ram"] = @(g_ram); p[@"hud"] = @(g_hudPos); p[@"lock"] = @(g_rotLock); p[@"rotTo"] = @(g_rotTo); p[@"rumble"] = @(g_rumble); p[@"rumblelv"] = @(g_rumbleLv); p[@"btnhap"] = @(g_btnHap); p[@"fill"] = @(g_fillUser); p[@"fpsmode"] = @(g_fpsmode); p[@"hideall"] = @(g_hideAll);
    for (int o = 0; o < 2; o++) if (fabs(g_pic[o].scale - 1) > .002 || fabs(g_pic[o].sx - 1) > .002 || fabs(g_pic[o].sy - 1) > .002 || fabs(g_pic[o].dx) > .002 || fabs(g_pic[o].dy) > .002 || g_picFree[o])
            p[[NSString stringWithFormat:@"pic%d", o]] = @[@(g_pic[o].scale), @(g_pic[o].dx), @(g_pic[o].dy), @(g_pic[o].sx), @(g_pic[o].sy), @(g_picFree[o])];   // 画面自定义：缩放 / 位移 / 横纵拉伸 / 是否解锁，横竖屏各一条，互相独立
    NSMutableArray *seqs = [NSMutableArray array];
    for (int i = 0; i < COMBO_SLOTS; i++) { NSMutableArray *s = [NSMutableArray array]; for (int j = 0; j < g_seq_n[i]; j++) [s addObject:@(g_seq[i][j])]; [seqs addObject:s]; }
    p[@"comboseq"] = seqs;
    p[@"combover"] = @2;
    NSMutableArray *gaps = [NSMutableArray array], *holds = [NSMutableArray array], *lasts = [NSMutableArray array];
    NSMutableArray *steps = [NSMutableArray array], *keeps = [NSMutableArray array];
    for (int i = 0; i < COMBO_SLOTS; i++) { [gaps addObject:@(g_seq_gap[i])]; [holds addObject:@(g_seq_hold[i])]; [lasts addObject:@(g_seq_holdlast[i])]; [steps addObject:@(g_seq_holdms[i])]; [keeps addObject:@(g_seq_keep[i])]; }
    p[@"combostep"] = steps; p[@"combokeep"] = keeps;
    p[@"combogap"] = gaps; p[@"combohold"] = holds; p[@"comboholdlast"] = lasts;
    NSMutableDictionary *jm = [NSMutableDictionary dictionary], *ja = [NSMutableDictionary dictionary], *jb = [NSMutableDictionary dictionary],
                         *jt = [NSMutableDictionary dictionary], *jd = [NSMutableDictionary dictionary], *jf = [NSMutableDictionary dictionary];
    for (int i = 0; i < 2; i++) {
        NSString *k = @(i).stringValue;
        jm[k] = @(g_jmode[i]); ja[k] = @(g_jarea[i]); jb[k] = @(g_jbg[i]); jt[k] = @(g_tapMove[i]);
        jd[k] = @(g_jdead[i]); jf[k] = @(g_jtap[i]);
    }
    p[@"jm"] = jm; p[@"ja"] = ja; p[@"jb"] = jb; p[@"jt"] = jt; p[@"jd"] = jd; p[@"jf"] = jf;
    NSUserDefaults *ud = DmCfgDefaults();
    if (st.count) [ud setObject:st forKey:k_ctl_key]; else [ud removeObjectForKey:k_ctl_key];
    [ud setObject:p forKey:k_pref_key];
}

// ---- MelonX's 11 colour themes (ControllerTheme.swift; only colours change, never the geometry) ----
enum { TH_FILL, TH_FILL_ON, TH_BORDER, TH_BORDER_ON, TH_ICON, TH_ICON_ON, TH_JACTIVE, TH_JBASE, TH_JHANDLE, TH_N };
static const struct { const char *id, *name; CGFloat bw; CGFloat c[TH_N][4]; } k_th[] = {
    {"classic",  "经典",   2,   {{.5,.5,.5,.4},{.5,.5,.5,.4},{0,0,0,0},{0,0,0,0},{1,1,1,.8},{1,1,1,.6},{.5,.5,.5,.4},{.5,.5,.5,.3},{.5,.5,.5,.5}}},
    {"gold",     "琥珀",   2,   {{.851,.651,.2,.16},{.851,.651,.2,.28},{.851,.651,.2,.55},{1,.8,.3,.9},{.902,.749,.349,.9},{1,.851,.4,1},{.851,.651,.2,.12},{.851,.651,.2,.3},{.902,.702,.251,.6}}},
    {"stealth",  "隐形",   1.5, {{1,1,1,.07},{1,1,1,.12},{1,1,1,.28},{1,1,1,.5},{1,1,1,.55},{1,1,1,.75},{1,1,1,.08},{1,1,1,.15},{1,1,1,.35}}},
    {"sakura",   "樱花",   2,   {{1,.451,.651,.16},{1,.451,.651,.28},{1,.451,.651,.55},{1,.549,.749,.9},{1,.6,.749,.9},{1,.702,.82,1},{1,.451,.651,.12},{1,.451,.651,.3},{1,.502,.678,.6}}},
    {"ocean",    "海洋",   2,   {{.149,.549,.949,.16},{.149,.549,.949,.28},{.149,.549,.949,.55},{.302,.702,1,.9},{.4,.702,1,.9},{.549,.8,1,1},{.149,.549,.949,.12},{.149,.549,.949,.3},{.2,.549,.949,.6}}},
    {"forest",   "森林",   2,   {{.251,.8,.451,.16},{.251,.8,.451,.28},{.251,.8,.451,.55},{.4,.949,.6,.9},{.451,.902,.6,.9},{.6,1,.702,1},{.251,.8,.451,.12},{.251,.8,.451,.3},{.251,.8,.451,.6}}},
    {"lavender", "薰衣草", 2,   {{.651,.502,.949,.16},{.651,.502,.949,.28},{.651,.502,.949,.55},{.749,.6,1,.9},{.749,.6,1,.9},{.839,.749,1,1},{.651,.502,.949,.12},{.651,.502,.949,.3},{.702,.549,.969,.6}}},
    {"sunset",   "日落",   2,   {{1,.502,.2,.16},{1,.502,.2,.28},{1,.502,.2,.55},{1,.6,.3,.9},{1,.6,.3,.9},{1,.749,.502,1},{1,.502,.2,.12},{1,.502,.2,.3},{1,.549,.251,.6}}},
    {"neon",     "霓虹",   2.5, {{0,.851,1,.12},{0,.851,1,.2},{0,.851,1,.7},{0,1,1,1},{0,.902,1,.9},{0,1,1,1},{0,.851,1,.1},{0,.851,1,.3},{0,.902,1,.6}}},
    {"minimal",  "极简",   0,   {{1,1,1,.12},{1,1,1,.16},{0,0,0,0},{0,0,0,0},{1,1,1,.7},{1,1,1,.92},{1,1,1,.06},{1,1,1,.15},{1,1,1,.3}}},
    {"glass",    "玻璃",   3,   {{1,1,1,.12},{1,1,1,.22},{1,1,1,.75},{1,1,1,.95},{1,1,1,.95},{1,1,1,1},{1,1,1,.12},{1,1,1,.3},{1,1,1,.6}}},
};
NSArray<NSString *> *dm_pad_theme_names(void) { NSMutableArray *a = [NSMutableArray array]; for (unsigned i = 0; i < sizeof k_th / sizeof k_th[0]; i++) [a addObject:[NSString stringWithUTF8String:k_th[i].name]]; return a; }
NSArray<NSString *> *dm_pad_theme_ids(void) { NSMutableArray *a = [NSMutableArray array]; for (unsigned i = 0; i < sizeof k_th / sizeof k_th[0]; i++) [a addObject:[NSString stringWithUTF8String:k_th[i].id]]; return a; }
#define K_TH_N ((int)(sizeof k_th / sizeof *k_th))
static int th_idx(void) { const char *w = g_theme.UTF8String; for (int i = 0; i < K_TH_N; i++) if (!strcmp(k_th[i].id, w)) return i; return 0; }
static UIColor *th_col(int which, CGFloat mul) {
    const CGFloat *c = k_th[th_idx()].c[which];
    return [UIColor colorWithRed:c[0] green:c[1] blue:c[2] alpha:fmax(0, fmin(1, c[3] * mul))];
}

// ---- 玻璃主题：iOS 26 的 Liquid Glass 观感（半透明 + 顶部反光 + 亮边），用静态 CALayer 拼出来 ----
// 原来每个按钮 / 摇杆各挂一个 UIVisualEffectView：二十多层模糊要在游戏画面上每秒重采一次背景，帧率被直接拖垮，
// 而且系统玻璃只认自己的圆角，按钮符号的外形根本套不上。这里改成不采样的静态层（合成代价接近 0），
// 形状只由 cornerRadius / 胶囊决定，所以按钮、扳机、摇杆各自都是自己的外形。
@interface DmGlassView : UIView
- (void)setHot:(BOOL)hot;   // 按下：更亮、边更白
@end
@implementation DmGlassView {
    CAGradientLayer *_fill, *_spek;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.userInteractionEnabled = NO; self.backgroundColor = UIColor.clearColor;
        self.layer.masksToBounds = YES; self.layer.cornerCurve = kCACornerCurveContinuous;
        _fill = [CAGradientLayer layer];
        _fill.colors = @[(id)[UIColor colorWithWhite:1 alpha:.30].CGColor, (id)[UIColor colorWithWhite:1 alpha:.09].CGColor, (id)[UIColor colorWithWhite:1 alpha:.22].CGColor];
        _fill.locations = @[@0, @.58, @1];
        _fill.startPoint = CGPointMake(.12, 0); _fill.endPoint = CGPointMake(.88, 1);
        [self.layer addSublayer:_fill];
        _spek = [CAGradientLayer layer];   // 上半部的反光：玻璃「有厚度」全靠这一层
        _spek.colors = @[(id)[UIColor colorWithWhite:1 alpha:.52].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
        _spek.startPoint = CGPointMake(.5, 0); _spek.endPoint = CGPointMake(.5, 1);
        [self.layer addSublayer:_spek];
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:.38].CGColor;
        self.layer.borderWidth = .7;
    }
    return self;
}
- (void)setHot:(BOOL)hot {
    _fill.colors = hot ? @[(id)[UIColor colorWithWhite:1 alpha:.52].CGColor, (id)[UIColor colorWithWhite:1 alpha:.16].CGColor, (id)[UIColor colorWithWhite:1 alpha:.34].CGColor]
                       : @[(id)[UIColor colorWithWhite:1 alpha:.30].CGColor, (id)[UIColor colorWithWhite:1 alpha:.09].CGColor, (id)[UIColor colorWithWhite:1 alpha:.22].CGColor];
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:(hot ? .72 : .38)].CGColor;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _fill.frame = self.bounds;
    _spek.frame = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height * .5);
    [CATransaction commit];
}
@end
static DmGlassView *glass_view(void) { return [[DmGlassView alloc] initWithFrame:CGRectZero]; }
static BOOL th_is_glass(void) { return !strcmp(k_th[th_idx()].id, "glass"); }

// ---- Touch -> input state ----
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_pad_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry, g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry;
static int tilted(int32_t x, int32_t y) { return (int64_t)x * x + (int64_t)y * y > (int64_t)4000 * 4000; }
// 已经结束 / 取消的 touch 立刻停止驱动摇杆：不等 sweep（半秒心跳）来收，否则角色还会朝最后一帧的方向多走半步
static BOOL touch_live(UITouch *t) {
    if (!t) return NO;
    UITouchPhase p = t.phase;
    return p != UITouchPhaseEnded && p != UITouchPhaseCancelled;
}
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    int32_t lx = g_touch_lx, ly = g_touch_ly, rx = g_touch_rx, ry = g_touch_ry;
    if (tilted(g_pad_lx, g_pad_ly)) { lx = g_pad_lx; ly = g_pad_ly; }   // a tilted physical stick wins
    if (tilted(g_pad_rx, g_pad_ry)) { rx = g_pad_rx; ry = g_pad_ry; }
    uint32_t btn = (uint32_t)(g_touch_btn | g_pad_btn);
    pthread_mutex_unlock(&g_mu);
    // S2Arm 的触屏输入出口：位序与 dm_input.h 一致（A=bit0 … DOWN=bit15）；axes = 左x/左y/右x/右y，±32767，上为正
    int32_t axes[4] = {lx, ly, rx, ry};
    s2a_pad_update(S2A_PAD_TOUCH, 1, btn, axes);
}
// 金手指的按键触发（ios/dmpad_cheats.m 的 dm_input_held）：位序与 dm_input.h 的 H_* 一致（A=bit0 … DOWN=bit15）
uint64_t dm_input_held(void) {
    pthread_mutex_lock(&g_mu);
    uint64_t v = g_touch_btn | g_pad_btn;
    pthread_mutex_unlock(&g_mu);
    return v;
}

// ---- Icons: the system symbol when it exists, a drawn glyph when it does not ----
static UIImage *symbol_img(NSString *name) {
    if (!name) return nil;
    static NSCache *cache; if (!cache) cache = [NSCache new];
    id hit = [cache objectForKey:name];
    if (hit) return hit == (id)[NSNull null] ? nil : hit;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:60 weight:UIImageSymbolWeightRegular];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    img = img ? [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
    [cache setObject:img ?: (id)[NSNull null] forKey:name];
    return img;
}
static UIImage *fallback_img(const DmCtlDef *d, CGFloat w, CGFloat h) {   // template image: only its alpha is used, so it takes any tint
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0);
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
    if (d->kind == K_TRIG) {   // the same rounded bar the trigger symbol has, with its letter knocked out
        UIRectCorner corn = d->sym[0] == 'z' ? UIRectCornerTopLeft | UIRectCornerTopRight : UIRectCornerBottomLeft | UIRectCornerBottomRight;
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h) byRoundingCorners:corn cornerRadii:CGSizeMake(h * .45, h * .45)];
        [UIColor.blackColor setFill]; [p fill];
        [@(d->fb) drawInRect:CGRectMake(0, h * .18, w, h * .7) withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:h * .5 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: ps}];
    } else {   // an outlined circle with the glyph inside (a filled circle cannot knock a letter out of a template image)
        CGFloat r = MIN(w, h) / 2, cx = w / 2, cy = h / 2;
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - r * .9, cy - r * .9, r * 1.8, r * 1.8)];
        ring.lineWidth = r * .16; [UIColor.blackColor setStroke]; [ring stroke];
        if (d->kind == K_DPAD) {   // a solid triangle pointing the way the key goes
            CGFloat k = r * .5; CGPoint a, b, c;
            if (d->hid == H_UP) { a = CGPointMake(cx, cy - k); b = CGPointMake(cx - k, cy + k * .8); c = CGPointMake(cx + k, cy + k * .8); }
            else if (d->hid == H_DOWN) { a = CGPointMake(cx, cy + k); b = CGPointMake(cx - k, cy - k * .8); c = CGPointMake(cx + k, cy - k * .8); }
            else if (d->hid == H_LEFT) { a = CGPointMake(cx - k, cy); b = CGPointMake(cx + k * .8, cy - k); c = CGPointMake(cx + k * .8, cy + k); }
            else { a = CGPointMake(cx + k, cy); b = CGPointMake(cx - k * .8, cy - k); c = CGPointMake(cx - k * .8, cy + k); }
            UIBezierPath *t = [UIBezierPath bezierPath]; [t moveToPoint:a]; [t addLineToPoint:b]; [t addLineToPoint:c]; [t closePath];
            [UIColor.blackColor setFill]; [t fill];
        } else {
            [@(d->fb) drawInRect:CGRectMake(cx - r, cy - r * .6, 2 * r, r * 1.2)
                  withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:r * .95 weight:UIFontWeightBold],
                                   NSForegroundColorAttributeName: UIColor.blackColor, NSParagraphStyleAttributeName: ps}];
        }
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
static UIImage *ctl_icon_img(int k, CGFloat w, CGFloat h) {
    UIImage *img = k_def[k].sym ? symbol_img(@(k_def[k].sym)) : nil;
    return img ?: fallback_img(&k_def[k], w, h);
}
// 玻璃主题：按钮里的白底（a.circle.fill 那个实心白盘 / 扳机的白色长条）不画，只留字形，
// 圆盘与胶囊由玻璃层自己画 —— 这就是「按钮里面的白色也变成玻璃」
static UIImage *glass_glyph_img(int k, CGFloat w, CGFloat h) {
    const DmCtlDef *d = &k_def[k];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0);
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
    if (d->kind == K_DPAD) {   // 方向键：只有三角形，没有外圈
        CGFloat r = MIN(w, h) / 2, cx = w / 2, cy = h / 2, t = r * .60; CGPoint a, b, c;
        if (d->hid == H_UP) { a = CGPointMake(cx, cy - t); b = CGPointMake(cx - t, cy + t * .8); c = CGPointMake(cx + t, cy + t * .8); }
        else if (d->hid == H_DOWN) { a = CGPointMake(cx, cy + t); b = CGPointMake(cx - t, cy - t * .8); c = CGPointMake(cx + t, cy - t * .8); }
        else if (d->hid == H_LEFT) { a = CGPointMake(cx - t, cy); b = CGPointMake(cx + t * .8, cy - t); c = CGPointMake(cx + t * .8, cy + t); }
        else { a = CGPointMake(cx + t, cy); b = CGPointMake(cx - t * .8, cy - t); c = CGPointMake(cx - t * .8, cy + t); }
        UIBezierPath *p = [UIBezierPath bezierPath]; [p moveToPoint:a]; [p addLineToPoint:b]; [p addLineToPoint:c]; [p closePath];
        [UIColor.blackColor setFill]; [p fill];
    } else {
        CGFloat fs = d->kind == K_TRIG ? h * .5 : MIN(w, h) * .56;
        [@(d->fb) drawInRect:CGRectMake(0, (h - fs * 1.25) / 2, w, fs * 1.25)
              withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:fs weight:UIFontWeightSemibold],
                               NSForegroundColorAttributeName: UIColor.blackColor, NSParagraphStyleAttributeName: ps}];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
// MelonX's ButtonView.buttonBackground: a trigger's backing is the "button.*.horizontal.fill" symbol (the bar's own silhouette), a stick click's is its joystick symbol; both tinted with the plain fill colour.
static NSString *bg_sym(int k) {
    switch (k) {
        case CT_ZL: case CT_ZR: return @"button.roundedtop.horizontal.fill";
        case CT_L: case CT_R: return @"button.roundedbottom.horizontal.fill";
        default: return @(k_def[k].sym);   // L3 / R3 keep their own l./r.joystick.press.down.fill shape
    }
}

// ---- The fields the editor's rows read and write ----
enum { F_SIZE, F_ALPHA, F_HIDE, F_TOGGLE, F_DPADSTICK, F_SCALE, F_DIM, F_SLIDE, F_FPS, F_RAM, F_HUDPOS,
       F_JMODE, F_JAREA, F_JBG, F_TAPMOVE, F_TAPFORCE, F_DEAD, F_SENS, F_FSIZE, F_FOP, F_FDEAD, F_ROTLOCK, F_CSTEP, F_HIDEALL, F_CGAP, F_CHOLD, F_CHLAST, F_CHOLDMS, F_CKEEP };   // F_LOCK is taken by <unistd.h>

@interface DmGamepad : UIView <UIGestureRecognizerDelegate, UIDocumentPickerDelegate>
// what the layout editor reads and changes
- (CGFloat)u;
- (int)ori;
- (NSString *)ctlName:(int)k;
- (BOOL)ctlHidden:(int)k;
- (BOOL)ctlLive:(int)k;                       // on screen with the current layout and mode
- (int)ctlAt:(CGPoint)p;                       // the control under a point, or -1
- (void)reset;                                // let go of every key and stick
- (CGPoint)ctlCenter:(int)k;
- (CGRect)ctlHalo:(int)k;                     // the visible shape, which is also the touch area
- (CGFloat)field:(int)f ofCtl:(int)k side:(int)i;
- (void)setField:(int)f ofCtl:(int)k side:(int)i to:(CGFloat)v;
- (void)moveCtl:(int)k to:(CGPoint)p;
- (void)resetCtl:(int)k;
- (void)resetAll;
- (CGRect)regionRect:(int)i;
- (void)setRegion:(int)i to:(CGRect)r;
- (void)centerRegionOnStick:(int)i;   // keep the float area centered on the stick when either one is dragged (MelonX)
- (void)applyPrefs;                           // theme, sizes and visibility after a bulk change
- (void)openEditor;
- (void)closeEditor;
- (void)picEditToggle;                      // 画面自定义：开 / 关拖动手势
- (void)picOverlayRefresh;                  // 提示条与虚线框的显隐
- (void)picHintLayout;                      // 提示条随屏幕形态重排
- (void)picBegin; - (void)picMove:(CGPoint)d; - (void)picEnd;   // 一次拖动 / 缩放的起止
- (void)picDragged:(UIPanGestureRecognizer *)pan;
- (void)picPinched:(UIPinchGestureRecognizer *)pinch;
- (void)guardPicTouches:(NSSet<UITouch *> *)ts;   // 编辑时不往按键 / 游戏触摸屏发事件
- (void)sweepDeadTouches:(UIEvent *)e;            // 已经没有手指的 touch 不再举着键 / 摇杆（UIKit 不保证每根手指都送 touchesEnded）
- (void)releaseTouch:(UITouch *)t;                  // 一根触摸彻底放手：键、摇杆、游戏触摸槽一起清
- (void)springStick:(int)i;                         // 摇杆归位动画
- (void)openCheats;                               // 金手指页（hle_cheats.c 的分节开关）
- (void)cheatAddCustom;                            // 「添加自定义」：把一条数值金手指写进 Documents/cheats/custom.txt 并重读
- (void)cheatImportTxt;                            // 「导入txt」：从「文件」App 选一个金手指 txt，拷进 Documents/cheats/ 并重读
- (void)cheatsReload;                              // 关掉已生效的 → 重读包内 + 玩家目录 → 恢复上次的开关 → 重建页面
- (void)closeCheats;
@end

@interface DmCheatPanel : UIView
- (instancetype)initWithPad:(DmGamepad *)pad;
@end

@interface DmPadEditor : UIView
- (instancetype)initWithPad:(DmGamepad *)pad;
- (void)selectCtl:(int)k;                   // rebuild the card for this control (the gear menu's combo entries)
- (void)selectionChanged;
- (void)refreshOverlay;                     // only the moving parts (the selection ring, the region boxes): the card stays put so a drag does not jiggle it
- (void)rebuild;
@end

static __weak DmGamepad *g_view;
static __weak DmCheatPanel *g_cheatPanel;
static __weak DmPadEditor *g_editor;

// MelonX's TouchTargetButton: a hit area larger than the icon
@interface DmGearButton : UIButton
@end
@implementation DmGearButton
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return CGRectContainsPoint(CGRectInset(self.bounds, -20, -20), p); }
@end

@implementation DmGamepad {
    UIView *_ctl[CT_N]; UIImageView *_icon[CT_N];            // one container per control: the container is the halo, the icon sits on top
    UIImageView *_bg[CT_N];                                 // ZL / L / ZR / R / L3 / R3: MelonX draws their translucent backing as the button-shaped SF Symbol itself, not a filled disc
    UIView *_jring[2], *_jbase[2], *_jknob[2];              // fixed stick: the circle that appears while held, the base disc, the knob
    DmGlassView *_gbox[CT_N];                               // 玻璃主题：按钮底下那层玻璃（形状跟着按钮：圆盘 / 胶囊）
    DmGlassView *_jbG[2], *_jkG[2], *_fbG[2], *_fnG[2];     // 玻璃主题：摇杆底座 / 摇杆帽 / 浮动摇杆的底座与帽
    UIView *_fbase[2], *_fnub[2];                           // floating stick: spawned where the finger lands
    CAShapeLayer *_scrim;                                   // dims the game while the editor is open
    DmGearButton *_gear; NSTimer *_dimTimer;                // the 10,10 settings entry
    UILabel *_hud; dispatch_source_t _hudTimer; uint64_t _hudFrame; CFAbsoluteTime _hudTime;
    NSMapTable<UITouch *, NSNumber *> *_owner;              // touch -> the key bits its control owns, or a stick marker
    NSMapTable<UITouch *, NSNumber *> *_mask;               // touch -> the key bits it covers right now
    UITouch *_stick[2]; CGPoint _stickAt[2], _stickFrom[2]; BOOL _stickLive[2], _stickEdge[2];
    UITouch *_float[2]; CGPoint _floatAt[2], _floatFrom[2];
    UITouch *_game[16];   // 游戏触摸屏的手指槽（按 id 上报给 guest）
    uint64_t _bits, _latched;                               // keys held now, and the keys a toggle key has latched on
    uint64_t _seqBits; unsigned _seqGen; int _seqSlot;       // combo sequence: keys pressed right now, a generation to cancel stale steps, and the slot being played (for the highlight)
    BOOL _seqHeld, _seqHolding;                              // a finger is still on the combo / the sequence has finished and is holding its last key
    BOOL _padOn;                                            // a physical controller is connected, so the controls stand down
    int _ori; BOOL _large;                                   // the current orientation and whether a large panel (unfolded inner / iPad) is in use (for the one-shot log)
    UIImpactFeedbackGenerator *_hapt, *_edge;
    UIView *_picHint;                                      // the 「编辑画面」 hint bar, only on screen while the picture overlay is armed
    CGPoint _picAt[2]; CGFloat _picScale0, _picSx0, _picSy0, _picDx0, _picDy0;   // where the picture drag / pinch started, and the values at that moment
    UIButton *_picLock, *_picQuit, *_picE[4]; CGRect _picRect0; int _picEdge;   // 画面编辑的浮层：框上方「比例锁定 / 退出编辑」两个按钮 + 四边箭头（tag 0右 1左 2下 3上）；_picEdge = 当前拖的是哪条边，-1 = 移动
    UIPanGestureRecognizer *_picPanG; UIPinchGestureRecognizer *_picPinchG;   // 屏幕上的那两个手势，手指落在按钮上时要让位
}

enum { O_KEY = 1, O_STICK = 2, O_FLOAT = 3, O_COMBO = 4 };               // what a touch holds (the index is in the high byte)

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _mask = [NSMapTable strongToStrongObjectsMapTable];
        _hapt = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
        _edge = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [_hapt prepare]; [_edge prepare];
        cfg_read();
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cfgChanged:) name:DmCfgChanged object:nil];
        _ori = ori_of(f.size);
        g_picOri = _ori;   // 画面自定义按方向各存一份，起屏就要对齐到当前方向
        for (int k = 0; k < CT_N; k++) {
            UIView *v = [UIView new]; v.userInteractionEnabled = NO; [self addSubview:v]; _ctl[k] = v;
            if (k_def[k].kind == K_STICK) continue;
            _gbox[k] = glass_view();   // 最底下一层：只有「玻璃」主题才显出来
            _gbox[k].hidden = YES; [v addSubview:_gbox[k]];
            _icon[k] = [UIImageView new]; _icon[k].userInteractionEnabled = NO; _icon[k].contentMode = UIViewContentModeScaleAspectFit;
            if (k_def[k].kind == K_TRIG || k_def[k].kind == K_CLICK) {   // the button-shaped backing goes in first, so the icon draws on top of it
                _bg[k] = [UIImageView new]; _bg[k].userInteractionEnabled = NO; _bg[k].contentMode = UIViewContentModeScaleAspectFit;
                _bg[k].image = symbol_img(bg_sym(k)); [v addSubview:_bg[k]];   // a template image, so refreshState can tint it to the theme fill
            }
            [v addSubview:_icon[k]];
        }
        for (int i = 0; i < 2; i++) {   // the fixed stick, then the floating one it turns into
            UIView *v = _ctl[CT_LSTICK + i];
            _jring[i] = [UIView new]; _jring[i].alpha = 0; [v addSubview:_jring[i]];
            _jbase[i] = [UIView new]; [v addSubview:_jbase[i]];
            _jbG[i] = glass_view(); _jbG[i].hidden = YES; _jbG[i].autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [_jbase[i] addSubview:_jbG[i]];   // 玻璃：摇杆底座（挂在底座里，跟随缩放）
            _jknob[i] = [UIView new];
            _jkG[i] = glass_view(); _jkG[i].hidden = YES; _jkG[i].autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [_jknob[i] addSubview:_jkG[i]];   // 玻璃：摇杆帽
            _jknob[i].layer.shadowColor = UIColor.blackColor.CGColor; _jknob[i].layer.shadowOpacity = 0.18;
            _jknob[i].layer.shadowOffset = CGSizeMake(0, 2); _jknob[i].layer.shadowRadius = 4;
            [v addSubview:_jknob[i]];
            _fbase[i] = [UIView new]; _fbase[i].userInteractionEnabled = NO; _fbase[i].hidden = YES; [self addSubview:_fbase[i]];
            _fbase[i].clipsToBounds = NO;
            _fbG[i] = glass_view(); _fbG[i].hidden = YES; _fbG[i].autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [_fbase[i] addSubview:_fbG[i]];
            _fnub[i] = [UIView new]; _fnub[i].userInteractionEnabled = NO; _fnub[i].hidden = YES; [self addSubview:_fnub[i]];
            _fnG[i] = glass_view(); _fnG[i].hidden = YES; _fnG[i].autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [_fnub[i] addSubview:_fnG[i]];
            _fnub[i].layer.shadowColor = UIColor.blackColor.CGColor; _fnub[i].layer.shadowOpacity = 0.18;
            _fnub[i].layer.shadowOffset = CGSizeMake(0, 2); _fnub[i].layer.shadowRadius = 4;
        }
        [self buildGear];
        [self buildHud];
        [self applyPrefs];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(rotated) name:UIDeviceOrientationDidChangeNotification object:nil];
        // 切后台 / 来电时放开按住的一切（源项目由宿主调 dm_gamepad_reset；S2Arm 这边自己听通知）
        [nc addObserver:self selector:@selector(appResigned) name:UIApplicationWillResignActiveNotification object:nil];
        [self padsChanged];   // 实体手柄状态由 S2Arm 的 controller.m 维护，这里只跟随它收起 / 恢复虚拟按键
        // 画面编辑的手势：只在 g_picEdit 时动作，所以平时它们全部 pass through（delegate 在下面）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(picDragged:)];
        pan.delegate = self; pan.cancelsTouchesInView = NO; pan.delaysTouchesEnded = NO; pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:pan]; _picPanG = pan;
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(picPinched:)];
        pinch.delegate = self; pinch.cancelsTouchesInView = NO; pinch.delaysTouchesEnded = NO;   // 两个键同时按下正好凑够 pinch 的手指数：它一旦把 touchesEnded 扣到自己判定结束，按键就迟一拍甚至漏掉释放
        [self addGestureRecognizer:pinch]; _picPinchG = pinch;
        dm_cheats_ensure(); cheat_restore();   // 金手指：上次开着的那几项在第一次 present 时重新写入（main 此时还没映射，hle_cheats.c 的 tick 会补上）
    }
    return self;
}
- (void)cfgChanged:(NSNotification *)n {   // 启动器那一页改了同一批键：立刻重读并生效（帧率上限 / 填充 / 震动在 cfg_read 里已经打到运行时）
    if (g_editor) return;   // 编辑虚拟按钮时不要被打断
    cfg_read();
    [self applyPrefs]; [self hudNow]; [self setNeedsLayout]; [self updateGearMenu];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_hudTimer) dispatch_source_cancel(_hudTimer);
    [_dimTimer invalidate];
}

// ---- What is on screen, and in which colours ----
- (int)ori { return _ori; }
- (NSString *)ctlName:(int)k { return @(k_def[k].name); }
- (BOOL)ctlHidden:(int)k { return g_val[_ori][k].hidden; }
- (BOOL)ctlLive:(int)k {
    if (g_editor) return k_def[k].kind == K_COMBO ? g_val[_ori][k].hidden == 0 : YES;   // a combo slot shows in the editor only after the menu added it
    if (g_hideAll) return NO;   // 「隐藏全部虚拟按钮」: only the gear and the overlay stay
    if (_padOn || g_val[_ori][k].hidden) return NO;
    if (k_def[k].kind == K_STICK && g_jmode[k - CT_LSTICK]) return NO;   // a floating stick has no place on screen until it is touched
    return YES;
}
- (void)applyPrefs {
    int t = th_idx();
    BOOL gl = th_is_glass();   // 「玻璃」主题：按钮 / 摇杆底座 / 摇杆帽都叠一层系统玻璃（iOS 26 = Liquid Glass）
    for (int k = 0; k < CT_N; k++) {
        _ctl[k].hidden = ![self ctlLive:k];
        if (k_def[k].kind == K_STICK) continue;
        _icon[k].image = gl ? glass_glyph_img(k, k_def[k].w, k_def[k].h) : ctl_icon_img(k, k_def[k].w, k_def[k].h);   // 玻璃：只留字形，白底交给玻璃层
        _icon[k].accessibilityLabel = @(k_def[k].name);
        _ctl[k].layer.borderWidth = gl ? 0 : ((k_def[k].kind == K_TRIG || k_def[k].kind == K_CLICK) ? 0 : k_th[t].bw);   // 玻璃：边由玻璃层自己给，不再叠第二圈描线
        _gbox[k].hidden = !gl;
        if (_bg[k]) _bg[k].hidden = gl;   // 玻璃时底面就是玻璃层，不再画 MelonX 的半透明形状
    }
    for (int i = 0; i < 2; i++) {
        _jring[i].backgroundColor = th_col(TH_JACTIVE, 1);
        _jbase[i].backgroundColor = gl ? UIColor.clearColor : th_col(TH_JBASE, 1);
        _jknob[i].backgroundColor = gl ? UIColor.clearColor : th_col(TH_JHANDLE, 1);
        _jring[i].alpha = g_jbg[i] ? 1 : 0;   // "Always Show Background" keeps the active circle on screen
        _fbase[i].backgroundColor = gl ? UIColor.clearColor : [UIColor colorWithWhite:.35 alpha:.35 * g_fop];
        _fnub[i].backgroundColor = gl ? UIColor.clearColor : [UIColor colorWithWhite:1 alpha:.5 * g_fop];
        for (DmGlassView *gv in @[_jbG[i], _jkG[i], _fbG[i], _fnG[i]]) gv.hidden = !gl;
        _fbG[i].alpha = g_fop; _fnG[i].alpha = g_fop;   // 浮动摇杆的透明度跟着它的设置走
        _ctl[CT_LSTICK + i].hidden = ![self ctlLive:CT_LSTICK + i];
    }
    [self setNeedsLayout];
    [self refreshState];
}
- (void)refreshState {   // a press swaps the fill, the border and the icon colour, as MelonX's ButtonView does
    int t = th_idx();
    BOOL gl = th_is_glass();
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int k = 0; k < CT_N; k++) {
        if (k_def[k].kind == K_STICK) continue;
        if (k_def[k].kind == K_COMBO) {   // sequence: lit while it plays; hold / toggle: lit while its keys are down
            int slot = k - CT_C1; uint32_t cm = combo_mask(slot);
            BOOL on = _seqSlot == k || (cm && ((_bits & cm) == cm));
            UIView *v = _ctl[k];
            v.layer.backgroundColor = (gl ? UIColor.clearColor : th_col(on ? TH_FILL_ON : TH_FILL, 1)).CGColor;
            v.layer.borderColor = gl ? UIColor.clearColor.CGColor : th_col(on ? TH_BORDER_ON : TH_BORDER, 1).CGColor;
            v.layer.borderWidth = gl ? 0 : k_th[t].bw;
            _icon[k].tintColor = th_col(on ? TH_ICON_ON : TH_ICON, 1);
            [_gbox[k] setHot:on];
            continue;
        }
        int h = k_def[k].hid; BOOL on = h >= 0 && ((_bits >> h) & 1);
        UIView *v = _ctl[k];
        int special = k_def[k].kind == K_TRIG || k_def[k].kind == K_CLICK;   // these two kinds carry their fill in the button-shaped backing image, not in a disc
        if (special) {
            v.layer.backgroundColor = UIColor.clearColor.CGColor;
            _bg[k].tintColor = th_col(on ? TH_FILL_ON : TH_FILL, 1);
        } else {
            v.layer.backgroundColor = (gl ? UIColor.clearColor : th_col(on ? TH_FILL_ON : TH_FILL, 1)).CGColor;   // 玻璃主题：底色交给玻璃层
        }
        v.layer.borderColor = (special || gl) ? UIColor.clearColor.CGColor : th_col(on ? TH_BORDER_ON : TH_BORDER, 1).CGColor;
        v.layer.borderWidth = (special || gl) ? 0 : k_th[t].bw;   // 玻璃：不加额外的圆圈描线，形状完全由玻璃层给
        _icon[k].tintColor = th_col(on ? TH_ICON_ON : TH_ICON, 1);
        [_gbox[k] setHot:on];
    }
    [CATransaction commit];
}

// ---- Geometry ----
// A foldable iPhone keeps one scene while its panel changes, so the layout is a pure function of the current bounds and reflows on the
// next pass without a stored fold state. The scale follows the panel's height rather than its short side: the portrait layouts are tuned
// along the long side (932 pt on the reference phone) and the landscape ones along the short side (430 pt), so a 4:3 inner panel does not
// push the portrait controls off the top.
- (BOOL)largePanel { CGSize z = self.bounds.size; return fmin(z.width, z.height) >= 500; }   // a foldable's outer panel stays under ~440 pt on the short side; the unfolded inner panel and iPads are wider
- (CGRect)safe { return CGRectInset(self.bounds, K_PAD, K_PAD); }   // the whole screen with MelonX's uniform padding, so edge controls sit where the reference layout puts them (the tuned layouts already clear the island in the pillarbox bars)
- (CGRect)corner { return CGRectInset(self.bounds, K_PAD * K_CORNER_IN, K_PAD); }   // the bottom-corner controls reach a little closer to the side edges
- (CGFloat)u {
    CGSize z = self.bounds.size; CGFloat h = _ori == OR_P ? fmax(z.width, z.height) : fmin(z.width, z.height);
    return h > 0 ? fmin(h / (_ori == OR_P ? 932.0 : 430.0), [self largePanel] ? 1.75 : 1.3) : 1;   // a large panel lifts the phone's 1.3 cap, so its controls keep the same share of the screen
}
- (CGRect)rectOfCtl:(int)k { return k_def[k].corner ? self.corner : self.safe; }
- (int)vside:(int)k {   // in portrait the game is pinned to the top, so the shoulders, triggers, L3 / R3 and -/+ join the rest of the controls in the free lower half and measure up from the bottom edge
    if (_ori == OR_P && (k_def[k].kind == K_TRIG || k_def[k].kind == K_CLICK || k_def[k].kind == K_SYS)) return 1;
    return k_def[k].side;
}
- (CGPoint)ctlCenter:(int)k {
    DmCtlVal v = g_val[_ori][k]; CGRect s = [self rectOfCtl:k]; CGFloat u = self.u, x, y;
    switch (k_def[k].anchor) { case 0: x = CGRectGetMinX(s) + v.dx * u; break; case 1: x = CGRectGetMaxX(s) - v.dx * u; break; default: x = CGRectGetMidX(s) + v.dx * u; }
    y = [self vside:k] ? CGRectGetMaxY(s) - v.dy * u : CGRectGetMinY(s) + v.dy * u;
    return CGPointMake(x, y);
}
- (CGFloat)iconW:(int)k { return k_def[k].w * self.u * g_scale * g_val[_ori][k].size; }
- (CGFloat)iconH:(int)k { return k_def[k].h * self.u * g_scale * g_val[_ori][k].size; }
- (CGFloat)dragR:(int)i { return K_DRAG_D / 2 * self.u * g_scale * g_val[_ori][CT_LSTICK + i].size; }   // MelonX's extendedRadius
- (CGFloat)knobR:(int)i { return k_def[CT_LSTICK].w / 2 * self.u * g_scale * g_val[_ori][CT_LSTICK + i].size; }
- (CGFloat)floatBase:(int)i { return K_FLOAT_D * self.u * g_fsize; }
- (CGFloat)floatNub:(int)i { return K_FLOAT_D * K_FLOAT_NUB * self.u * g_fsize; }
- (CGRect)ctlHalo:(int)k {
    if (k_def[k].kind == K_STICK) { CGFloat R = [self dragR:k - CT_LSTICK], x = [self ctlCenter:k].x, y = [self ctlCenter:k].y;
        return CGRectMake(x - R, y - R, 2 * R, 2 * R); }
    CGFloat w = [self iconW:k] * K_HALO, h = [self iconH:k] * K_HALO; CGPoint c = [self ctlCenter:k];
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
}
- (CGRect)regionRect:(int)i {
    DmRectN r = g_reg[_ori][i]; CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    return CGRectMake(r.x * W, r.y * H, r.w * W, r.h * H);
}
- (CGFloat)grabR:(int)k {   // a touch has to land inside this to take the control
    return k_def[k].kind == K_STICK ? [self dragR:k - CT_LSTICK] : [self iconW:k] * K_HALO / 2;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    int o = ori_of(self.bounds.size);
    if (o != _ori) { _ori = o; g_picOri = o; fill_apply(o); [self applyPrefs]; [self updateGearMenu]; [g_editor selectionChanged]; if (g_picEdit) [self picOverlayRefresh]; front_game_frame_apply(); }   // 方向换了：按新方向那套配置重算画面框（父视图可能已经用旧方向排过一遍），否则画面停在旧尺寸 / 位置
    BOOL large = [self largePanel];
    if (large != _large) { _large = large; LOG("屏幕形态：%s（%.0fx%.0f，缩放 %.2f）", large ? "大屏" : "小屏", self.bounds.size.width, self.bounds.size.height, [self u]); }   // a fold/unfold is a size change, not a rotation, so the orientation callback never fires for it
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _scrim.frame = self.bounds;
    for (int k = 0; k < CT_N; k++) {
        UIView *v = _ctl[k]; CGRect halo = [self ctlHalo:k];
        v.frame = halo; v.alpha = g_dim * g_val[_ori][k].alpha * (g_editor && g_val[_ori][k].hidden ? .3 : 1);
        if (k_def[k].kind == K_STICK) {
            int i = k - CT_LSTICK; CGFloat R = [self dragR:i], kr = [self knobR:i], b = kr * K_BASE_K;
            _jring[i].frame = CGRectMake(0, 0, 2 * R, 2 * R); _jring[i].layer.cornerRadius = R;
            _jbase[i].bounds = CGRectMake(0, 0, b, b); _jbase[i].center = CGPointMake(R, R); _jbase[i].layer.cornerRadius = b / 2;
            _jknob[i].bounds = CGRectMake(0, 0, 2 * kr, 2 * kr); _jknob[i].layer.cornerRadius = kr;
            _jbG[i].frame = _jbase[i].bounds; _jbG[i].layer.cornerRadius = b / 2;   // 玻璃：底座（圆盘）
            _jkG[i].frame = _jknob[i].bounds; _jkG[i].layer.cornerRadius = kr;     // 玻璃：摇杆帽（圆）
            CGPoint off = [self knobOffset:i];
            _jknob[i].transform = _stickLive[i] ? CGAffineTransformMakeScale(1.12, 1.12) : CGAffineTransformIdentity;
            _jbase[i].transform = _stickLive[i] ? CGAffineTransformMakeScale(1.08, 1.08) : CGAffineTransformIdentity;
            _jknob[i].center = CGPointMake(R + off.x, R + off.y);
            _jbase[i].center = _stickLive[i] ? CGPointMake(R + off.x, R + off.y) : CGPointMake(R, R);
            continue;
        }
        CGFloat w = [self iconW:k], h = [self iconH:k];
        CGRect ic = CGRectMake((halo.size.width - w) / 2, (halo.size.height - h) / 2, w, h);   // 按钮真正的外形（图标尺寸），不是 1.25 倍的触摸区
        if (k_def[k].kind == K_TRIG || k_def[k].kind == K_CLICK) {
            if (_bg[k]) _bg[k].frame = v.bounds;   // the backing fills the halo (icon × 1.25), exactly MelonX's frame; the icon stays at its own w×h on top
            _gbox[k].frame = ic;
            _gbox[k].layer.cornerRadius = k_def[k].kind == K_TRIG ? h * .45 : h / 2;   // 扳机 = 胶囊；L3 / R3 = 圆
        } else {
            v.layer.cornerRadius = halo.size.width / 2;   // every other control's halo is a disc
            _gbox[k].frame = ic; _gbox[k].layer.cornerRadius = w / 2;   // 玻璃：跟 a.circle.fill 一样大的圆盘
        }
        _icon[k].frame = ic;
    }
    [self placeGear];
    [self placeHud];
    [self picHintLayout];
    [self picControlsLayout];
    [CATransaction commit];
    [self refreshState];
    [g_editor refreshOverlay];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)rotated { [self setNeedsLayout]; [self updateGearMenu]; }
- (void)appResigned { [self reset]; [self closeEditor]; }   // 后台 / 来电：放开按键与摇杆，收起编辑浮层

// ---- Sticks: the MelonX maths ----
- (CGPoint)knobOffset:(int)i {   // processOffset: the finger's distance from the base centre, clamped to the drag radius
    if (!touch_live(_stick[i])) return CGPointZero;
    CGPoint c = [self ctlCenter:CT_LSTICK + i];
    CGFloat dx = _stickAt[i].x - c.x, dy = _stickAt[i].y - c.y, R = [self dragR:i], d = hypot(dx, dy);
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}
- (CGPoint)stickNorm:(int)i {   // normalizedPosition: dead zone, then the tap-to-move or the drag curve
    CGFloat R = [self dragR:i]; if (R <= 0) return CGPointZero;
    CGPoint o = [self knobOffset:i];
    CGFloat rx = o.x / R, ry = o.y / R, mag = hypot(rx, ry), dz = g_jdead[i];
    if (mag <= dz || !_stickLive[i]) return CGPointZero;
    if (g_tapMove[i]) {   // a tapped direction is never weaker than the tap force, so a tap always walks
        CGFloat om = fmin(1, fmax(mag * g_sens, g_jtap[i]));
        return CGPointMake(rx / mag * om, ry / mag * om);
    }
    CGFloat sc = (mag - dz) / fmax(1 - dz, .001) / mag;
    return CGPointMake(fmax(-1, fmin(1, rx * sc * g_sens)), fmax(-1, fmin(1, ry * sc * g_sens)));
}
- (CGPoint)floatNorm:(int)i {   // FloatingJoystickOverlay: the same curve, measured from where the finger came down
    CGFloat maxR = [self floatBase:i] / 2 - [self floatNub:i] / 2;
    if (maxR <= 0) return CGPointZero;
    CGFloat deadR = g_fdead * maxR;
    CGFloat dx = _floatAt[i].x - _floatFrom[i].x, dy = _floatAt[i].y - _floatFrom[i].y, d = hypot(dx, dy);
    if (d <= deadR) return CGPointZero;
    CGFloat cd = fmin(d, maxR);
    CGFloat om = fmin(1, fmax(0, (cd - deadR) / fmax(maxR - deadR, 1)) * g_sens);
    return CGPointMake(dx / d * om, dy / d * om);
}
static int32_t axis16(CGFloat v) { return (int32_t)lrint(fmax(-1, fmin(1, v)) * 32767); }
// MARK: - below: the gear, the overlay, the touches, the physical pad, the editor

// ---- The settings gear: MelonX's SettingsMenuButton (44 pt at 10,10, wakes on touch, fades to 0.05 after 3 s) ----
static UIImage *menu_img(NSString *n) { return n ? [UIImage systemImageNamed:n] : nil; }
static UIViewController *front_vc(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class])
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) { UIViewController *v = w.rootViewController; while (v.presentedViewController) v = v.presentedViewController; return v; }
    return nil;
}
- (void)buildGear {
    _gear = [[DmGearButton alloc] initWithFrame:CGRectMake(K_GEAR_EDGE, K_GEAR_EDGE, K_GEAR, K_GEAR)];
    _gear.tintColor = UIColor.whiteColor;
    _gear.backgroundColor = [UIColor colorWithWhite:0 alpha:.6];
    _gear.layer.cornerRadius = K_GEAR / 2; _gear.clipsToBounds = YES;
    UIImage *g = [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19]];   // MelonX's 19 pt glyph in the 44 pt disc
    if (!g) g = symbol_img(@"gearshape.fill");
    if (g) [_gear setImage:[g imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    else { [_gear setTitle:@"⚙" forState:UIControlStateNormal]; _gear.titleLabel.font = [UIFont systemFontOfSize:22]; }
    _gear.showsMenuAsPrimaryAction = YES;
    [_gear addTarget:self action:@selector(restoreOpacity) forControlEvents:UIControlEventTouchDown];
    _gear.accessibilityLabel = @"设置";
    [self addSubview:_gear];
    [self updateGearMenu];
    [self restoreOpacity];
}
- (void)placeGear {
    CGFloat x = K_GEAR_EDGE, y = K_GEAR_EDGE - (_ori == OR_L ? 10 : 0);   // landscape: the gear sits 10 pt higher, flush with the top edge
    if ([self largePanel]) {   // only the unfolded inner panel: its display corner is rounder than any inset reports, so keep the gear clear of it
        UIEdgeInsets si = self.safeAreaInsets;
        x = fmax(20, si.left) + K_GEAR_EDGE;
        y = fmax(20, si.top) + K_GEAR_EDGE - (_ori == OR_L ? 10 : 0);
    }
    _gear.frame = CGRectMake(x, fmax(0, y), K_GEAR, K_GEAR);
}
- (void)restoreOpacity {   // full opacity, then a slow fade almost out of sight
    [_dimTimer invalidate];
    _gear.alpha = 1;
    _dimTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(dimGear) userInfo:nil repeats:NO];
}
- (void)dimGear { [UIView animateWithDuration:.8 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{ _gear.alpha = .05; } completion:nil]; }   // almost out of sight, but still tappable

- (UIAction *)act:(NSString *)t image:(NSString *)img on:(BOOL)on kill:(BOOL)kill run:(void (^)(void))run {
    UIAction *a = [UIAction actionWithTitle:t image:menu_img(img) identifier:nil handler:^(__unused UIAction *x) { run(); }];
    a.attributes = kill ? UIMenuElementAttributesDestructive : 0;
    a.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;   // the check mark MelonX shows next to the active theme
    return a;
}
- (void)updateGearMenu {   // the same entries as MelonX's in-game menu, in Chinese
    if (!_gear) return;
    __weak DmGamepad *ws = self;   // the menu lives on the gear, so a strong self here would keep the whole pad alive
    BOOL portrait = _ori == OR_P;
    NSMutableArray *els = [NSMutableArray array];
    [els addObject:[self act:@"编辑虚拟按钮" image:@"gamecontroller" on:NO kill:NO run:^{ [ws gearEdit]; }]];
    {   // 竖屏 / 横屏：写存档并请求转向（根控制器按 dm_pad_supported_orientations 重新审阅方向）
        [els addObject:[self act:(portrait ? @"切换到横屏" : @"切换到竖屏") image:@"rotate.right" on:NO kill:NO run:^{ [ws flipOrientation]; }]];
    }
    NSMutableArray *themes = [NSMutableArray array];
    for (int i = 0; i < K_TH_N; i++) {
        NSString *nm = @(k_th[i].name); int idx = i;
        [themes addObject:[self act:nm image:nil on:!strcmp(k_th[idx].id, g_theme.UTF8String) kill:NO run:^{ [ws setThemeIdx:idx]; }]];
    }
    [els addObject:[UIMenu menuWithTitle:@"按钮主题" image:menu_img(@"paintpalette") identifier:nil options:0 children:themes]];
    NSMutableArray *perf = [NSMutableArray array];
    [perf addObject:[self act:@"显示 FPS" image:nil on:g_fps != 0 kill:NO run:^{ g_fps = !g_fps; cfg_write(); [ws hudNow]; [ws updateGearMenu]; }]];
    [perf addObject:[self act:@"显示 RAM" image:nil on:g_ram != 0 kill:NO run:^{ g_ram = !g_ram; cfg_write(); [ws hudNow]; [ws updateGearMenu]; }]];
    const char *pos[4] = {"右上角", "左上角", "右下角", "左下角"};
    NSMutableArray *where = [NSMutableArray array];
    for (int p = 0; p < 4; p++) { int q = p;
        [where addObject:[self act:@(pos[q]) image:nil on:g_hudPos == q kill:NO run:^{ g_hudPos = q; cfg_write(); [ws setNeedsLayout]; [ws updateGearMenu]; }]];
    }
    [perf addObject:[UIMenu menuWithTitle:@"位置" image:nil identifier:nil options:0 children:where]];
    [els addObject:[UIMenu menuWithTitle:@"性能叠层" image:menu_img(@"speedometer") identifier:nil options:0 children:perf]];   // MelonX has no rotation lock, so neither do we; the switch above is the only orientation control
    {   // frame pace: the profile asks for 120; dropping to 60 keeps the game playable if a scene cannot hold 120
        int hz = mtl_display_hz(); if (hz <= 0) hz = 60;   // the panel's own ceiling, shown so a 60 Hz phone does not look broken
        NSMutableArray *pace = [NSMutableArray array];
        NSString *names[4] = {@"跟随配置", @"30 帧", @"60 帧", @"120 帧"}; int vals[4] = {0, 30, 60, 120};
        for (int i = 0; i < 4; i++) { int q = vals[i];
            UIAction *a = [self act:names[i] image:nil on:g_fpsmode == q kill:NO run:^{ g_fpsmode = q; cfg_write(); mtl_fps_override(g_fpsmode); [ws updateGearMenu]; }];
            if (q > hz) a.attributes |= UIMenuElementAttributesDisabled;   // this panel cannot show more than its ceiling
            [pace addObject:a]; }
        NSString *title = [NSString stringWithFormat:@"帧率（本机屏幕上限 %dHz）", hz];
        [els addObject:[UIMenu menuWithTitle:title image:menu_img(@"gauge.with.dots.needle.67percent") identifier:nil options:0 children:pace]];
    }
    {   // vibration: one entry, with the pad's own tick and the HD rumble (on/off and strength) inside (the same hierarchy as Hades II)
        NSMutableArray *vib = [NSMutableArray array];
        NSMutableArray *btn = [NSMutableArray array];
        [btn addObject:[self act:@"打开" image:nil on:g_btnHap != 0 kill:NO run:^{ g_btnHap = 1; cfg_write(); dm_haptics_set_buttons(1); [ws updateGearMenu]; }]];
        [btn addObject:[self act:@"关闭" image:nil on:g_btnHap == 0 kill:NO run:^{ g_btnHap = 0; cfg_write(); dm_haptics_set_buttons(0); [ws updateGearMenu]; }]];
        [vib addObject:[UIMenu menuWithTitle:@"虚拟按键震动" image:menu_img(@"hand.tap") identifier:nil options:0 children:btn]];
        NSMutableArray *hd = [NSMutableArray array];
        [hd addObject:[self act:@"打开" image:nil on:g_rumble != 0 kill:NO run:^{ g_rumble = 1; cfg_write(); dm_haptics_set_enabled(1); s2a_rumble_set_enabled(1); [ws updateGearMenu]; }]];
        [hd addObject:[self act:@"关闭" image:nil on:g_rumble == 0 kill:NO run:^{ g_rumble = 0; cfg_write(); dm_haptics_set_enabled(0); s2a_rumble_set_enabled(0); [ws updateGearMenu]; }]];
        NSMutableArray *rum = [NSMutableArray array];
        NSString *rn[5] = {@"弱", @"标准", @"强", @"更强", @"最强"};   // DmHaptics.m 的 4x … 12x 档位；手机 / 手柄的游戏震动按同一档缩放（ios/controller.m）
        for (int i = 0; i < 5; i++) { int q = i;
            [rum addObject:[self act:rn[i] image:nil on:g_rumbleLv == q kill:NO run:^{
                g_rumbleLv = q; cfg_write(); dm_haptics_set_strength(q); s2a_rumble_set_level(q); [ws updateGearMenu];
            }]];
        }
        [hd addObject:[UIMenu menuWithTitle:@"震动强度" image:menu_img(@"waveform.path") identifier:nil options:0 children:rum]];
        [vib addObject:[UIMenu menuWithTitle:@"HD 震动" image:menu_img(@"waveform") identifier:nil options:0 children:hd]];
        [els addObject:[UIMenu menuWithTitle:@"震动" image:menu_img(@"iphone.radiowaves.left.and.right") identifier:nil options:0 children:vib]];
    }
    {   // 画面填充：保持比例 / 拉伸铺满 / 裁切铺满（直连与通用出图层都按它上屏）
        NSMutableArray *fm = [NSMutableArray array];
        NSString *fn[3] = {@"保持比例（黑边）", @"拉伸铺满", @"裁切铺满"};
        for (int i = 0; i < 3; i++) { int q = i;
            [fm addObject:[self act:fn[i] image:nil on:g_fillUser == q kill:NO run:^{
                g_fillUser = q; cfg_write(); mtl_present_fill(q); front_game_frame_apply(); [ws updateGearMenu];
            }]];
        }
        [els addObject:[UIMenu menuWithTitle:@"画面填充" image:menu_img(@"arrow.up.left.and.arrow.down.right") identifier:nil options:0 children:fm]];
    }
    {   // 画面自定义：进入透明浮层，拖动移动、双指缩放、四边箭头拉伸；再点一次退出
        [els addObject:[self act:(g_picEdit ? @"画面自定义（退出编辑）" : @"画面自定义") image:@"rectangle.on.rectangle.angled" on:g_picEdit kill:NO run:^{ [ws picEditToggle]; }]];
    }
    {   // 金手指：分节开关，文件在 Documents/cheats/*.txt
        [els addObject:[self act:@"金手指" image:@"wand.and.stars" on:NO kill:NO run:^{ [ws openCheats]; }]];
    }
    [els addObject:[self act:@"添加组合按键" image:@"square.on.square" on:NO kill:NO run:^{ [ws addCombo]; }]];
    [els addObject:[self act:@"打开 S2Arm 设置" image:@"gearshape.2" on:NO kill:NO run:^{
        UIViewController *vc = front_vc(); if (!vc) return;
        [ws reset];   // 先把按住的虚拟键 / 摇杆放开，避免设置页盖上来后按键卡在按下状态
        s2a_settings_present(vc);
    }]];
    {   // 退出游戏：确认后走宿主的正常收尾（存档服务 / GPU / 诊断写完再退进程）
        UIAction *a = [self act:@"退出游戏" image:@"x.circle" on:NO kill:NO run:^{
            [ws reset];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIViewController *vc = front_vc(); if (!vc) { dm_host_shutdown("玩家菜单退出"); return; }
                UIAlertController *al = [UIAlertController alertControllerWithTitle:@"退出游戏" message:@"未保存的游戏进度会丢失，请先在游戏内存档。" preferredStyle:UIAlertControllerStyleAlert];
                [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [al addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { dm_host_shutdown("玩家菜单退出"); }]];
                [vc presentViewController:al animated:YES completion:nil];
            });
        }];
        [els addObject:a];
    }
    _gear.menu = [UIMenu menuWithTitle:@"游戏设置" image:nil identifier:nil options:0 children:els];
}
- (void)flipOrientation { dm_pad_rotate_to(_ori == OR_L); }
- (void)gearEdit {   // the UIMenu popup is still tearing down; opening in the same frame gets swallowed (MelonX waits too)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self openEditor]; });
}
- (void)gearEditCombo:(int)i {   // open the editor with that combo selected, so a slot hidden under the card can still be edited
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self openEditor];
        if (g_editor) [g_editor selectCtl:CT_C1 + i];
    });
}
- (void)addCombo {   // the gear menu's single entry: add the next free slot, then open it for editing
    int slot = -1; for (int i = 0; i < COMBO_SLOTS; i++) if (g_val[_ori][CT_C1 + i].hidden) { slot = i; break; }
    if (slot < 0) {
        UIViewController *vc = front_vc();
        if (vc) { UIAlertController *a = [UIAlertController alertControllerWithTitle:@"组合按键已满" message:@"最多 6 个；可在编辑页把不用的组合“隐藏按钮”后再添加。" preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [vc presentViewController:a animated:YES completion:nil]; }
        return;
    }
    g_val[_ori][CT_C1 + slot].hidden = 0; cfg_write(); [self applyPrefs];
    [self gearEditCombo:slot];
}
- (void)setThemeIdx:(int)i { g_theme = @(k_th[i].id); cfg_write(); [self applyPrefs]; [self updateGearMenu]; }   // the check mark moves to the new theme
- (void)quit { dm_host_shutdown("menu"); }

// ---- The performance overlay (MelonX's PerformanceOverlay: 13 pt monospaced white text with a shadow, no panel) ----
static double ram_bytes(void) {
    task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) != KERN_SUCCESS) return 0;
    return (double)vi.phys_footprint;
}
- (void)buildHud {
    _hud = [UILabel new]; _hud.userInteractionEnabled = NO; _hud.numberOfLines = 0; _hud.textAlignment = NSTextAlignmentRight;
    _hud.textColor = UIColor.whiteColor; _hud.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _hud.layer.shadowColor = UIColor.blackColor.CGColor; _hud.layer.shadowOpacity = .85; _hud.layer.shadowRadius = 1.5;
    _hud.layer.shadowOffset = CGSizeMake(0, 1);
    [self addSubview:_hud];
    _hudTime = CFAbsoluteTimeGetCurrent(); _hudFrame = dm_guest_frame();
    _hudTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_hudTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC / 2, NSEC_PER_MSEC * 50);
    __weak DmGamepad *ws = self;
    dispatch_source_set_event_handler(_hudTimer, ^{ [ws hudNow]; });
    dispatch_resume(_hudTimer);
}
- (void)hudNow {
    if (!_hud) return;
    [self padsChanged];   // 半秒心跳里跟随实体手柄状态（控制器接入 / 断开由 controller.m 通知它自己的界面）
    [self sweepDeadTouches:nil];   // 这个 2 Hz 心跳同时是漏掉 touchesEnded 的兜底：卡住的键 / 摇杆最迟半秒放开（叠层关掉时定时器照跑）
    uint64_t f = dm_guest_frame(); CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    double dt = t - _hudTime; if (dt <= 0) return;
    double fps = (double)(f - _hudFrame) / dt; _hudFrame = f; _hudTime = t;
    {   static int mt;   // 每 5 秒一行内存：真机被系统 SIGKILL（内存不足）时日志里没有崩溃栈，只有这行能看到倒下前占了多少
        if (++mt % 10 == 0) {
            size_t avail = 0;
#if __has_include(<os/proc.h>)
            avail = os_proc_available_memory();
#endif
            LOG("[内存] 占用 %.2f GB、系统还能给 %.2f GB、帧 %llu", ram_bytes() / 1e9, (double)avail / 1e9, (unsigned long long)f);
        }
    }
    NSMutableString *s = [NSMutableString string];
    if (g_fps) [s appendFormat:@"FPS %.0f", fps];   // MelonX's readout is the rate alone; the frame-time parentheses were dropped
    if (g_ram) { if (s.length) [s appendString:@"\n"]; [s appendFormat:@"RAM %.2fG", ram_bytes() / 1e9]; }   // one line, "RAM 1.74G" (no trailing B)
    _hud.hidden = s.length == 0; _hud.text = s;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [_hud sizeToFit]; [self placeHud];
    [CATransaction commit];
}
- (void)placeHud {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, m = 10, sz_w = _hud.frame.size.width, sz_h = _hud.frame.size.height;
    CGFloat x = W - sz_w - m - 10, y = m;   // the top-right row sits 10 pt further in: the notch / dynamic island clips the very edge
    switch (g_hudPos) { case 1: x = m + 10; break; case 2: x = W - sz_w - m - 10; y = H - sz_h - m; break; case 3: x = m; y = H - sz_h - m; break; default: break; }   // top-left steps 10 right, clear of the settings gear
    _hud.frame = CGRectMake(floor(x), floor(y), sz_w, sz_h);
}

// ---- Hit testing ----
- (BOOL)point:(CGPoint)p onCtl:(int)k {
    CGRect r = [self ctlHalo:k]; CGPoint c = [self ctlCenter:k];
    if (k_def[k].kind == K_TRIG) return CGRectContainsPoint(r, p);
    CGFloat nx = (p.x - c.x) / fmax(r.size.width / 2, .1), ny = (p.y - c.y) / fmax(r.size.height / 2, .1);
    return nx * nx + ny * ny <= 1;
}
- (int)ctlAt:(CGPoint)p {   // keys win over the sticks they sit on (MelonX draws the buttons above the stick area), then the nearest key
    int best = -1; CGFloat bestr = 1.0001;
    for (int k = 0; k < CT_N; k++) {
        if (k_def[k].kind == K_STICK || ![self ctlLive:k]) continue;
        if (![self point:p onCtl:k]) continue;
        CGFloat d = hypot(p.x - [self ctlCenter:k].x, p.y - [self ctlCenter:k].y) / fmax([self grabR:k], .1);
        if (d < bestr) { best = k; bestr = d; }
    }
    if (best >= 0) return best;
    for (int k = 0; k < CT_N; k++) {
        if (k_def[k].kind != K_STICK || ![self ctlLive:k]) continue;
        CGFloat d = hypot(p.x - [self ctlCenter:k].x, p.y - [self ctlCenter:k].y) / fmax([self grabR:k], .1);
        if (d <= 1 && d < bestr) { best = k; bestr = d; }
    }
    return best;
}
- (uint64_t)keyMaskAt:(CGPoint)p {   // two halos overlap a little, so a finger put exactly between two keys takes both (the diagonals)
    uint64_t m = 0;
    for (int k = 0; k < CT_N; k++) {
        if (k_def[k].kind == K_STICK || g_val[_ori][k].toggle || ![self ctlLive:k]) continue;
        if (k_def[k].kind == K_COMBO) continue;   // a combo fires a sequence, it never holds bits itself
        if ([self point:p onCtl:k]) m |= 1ull << k_def[k].hid;
    }
    return m;
}
- (int)toggleKeyAt:(CGPoint)p {
    for (int k = 0; k < CT_N; k++) if (k_def[k].kind != K_STICK && k_def[k].kind != K_COMBO && g_val[_ori][k].toggle && [self ctlLive:k] && [self point:p onCtl:k]) return k;
    return -1;
}

// ---- The touch -> input pipeline ----
static int pad_touch_log(void);   // 定义在 touchesBegan 之前：键位变化的现场记录开关（DM_PAD_TOUCH）
- (void)recompute {
    uint64_t bits = _latched | _seqBits;
    // 每根手指只为自己落点上的那个键负责：keyMaskAt 的重叠容差（两键光晕相接处按下去会同时吃到两个键）只在那个键没有别的手指占着时才生效。
    // 少了这条，两根手指分别按相邻的两个键时，先抬起那根的位会被另一根继续举着，按几次之后就是一个键看着按下实则没松（「两个按键同时按会失效」的根因）。
    uint64_t claimed = 0;
    for (UITouch *t in _owner) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff) == O_KEY) claimed |= 1ull << k_def[(int)(v >> 8)].hid;
    }
    for (UITouch *t in _owner) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff) != O_KEY) continue;
        uint64_t own = 1ull << k_def[(int)(v >> 8)].hid;
        bits |= [_mask objectForKey:t].unsignedLongLongValue & ~(claimed & ~own);
    }
    [self drawSticks];
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        // 已经结束 / 取消的 touch 立即当 0（不等 sweep）：死 touch 挂在 _stick / _float 上时方向会固化在最后一帧
        CGPoint n = g_jmode[i] ? (touch_live(_float[i]) ? [self floatNorm:i] : CGPointZero)
                               : (touch_live(_stick[i]) ? [self stickNorm:i] : CGPointZero);
        ax[i * 2] = axis16(n.x); ax[i * 2 + 1] = axis16(-n.y);   // the host reads up as positive
    }
    if (pad_touch_log()) {   // 摇杆值的变化现场记录：卡住时日志里能看出值是不是停在最后一帧
        static int last[4];
        for (int i = 0; i < 2; i++) {
            int a = ax[i * 2], b = ax[i * 2 + 1];
            if (abs(a - last[i * 2]) > 4000 || abs(b - last[i * 2 + 1]) > 4000 || (!a && !b && (last[i * 2] || last[i * 2 + 1]))) {
                LOG("pad: 摇杆%d = %d,%d（%s）", i, a, b, g_jmode[i] ? "浮动" : "固定");
                last[i * 2] = a; last[i * 2 + 1] = b;
            }
        }
    }
    if (g_dpadStick) {   // the D-pad as a stick: the keys themselves go away, the direction goes to the left axes
        uint64_t dm = (1ull << H_LEFT) | (1ull << H_RIGHT) | (1ull << H_UP) | (1ull << H_DOWN);
        if (bits & dm) {
            CGFloat dx = (CGFloat)((bits >> H_RIGHT) & 1) - (CGFloat)((bits >> H_LEFT) & 1);
            CGFloat dy = (CGFloat)((bits >> H_DOWN) & 1) - (CGFloat)((bits >> H_UP) & 1);
            if (!ax[0] && !ax[1]) { CGFloat m = hypot(dx, dy); ax[0] = axis16(dx / m); ax[1] = axis16(-dy / m); }
            bits &= ~dm;
        }
    }
    BOOL changed = bits != _bits;
    uint64_t was = _bits;
    uint64_t pressed = bits & ~_bits;   // before _bits moves: the tick below looks at what went down in this pass
    _bits = bits;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = bits; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    if (changed) {
        if (pad_touch_log()) LOG("pad: keys %#llx (+%#llx -%#llx), %u finger(s), latched %#llx", bits, pressed, was & ~bits, (unsigned int)_owner.count, _latched);
        if (g_btnHap && pressed) [_hapt impactOccurred]; [self refreshState];   // only a press ticks (a release must not), and only while 虚拟按键震动 is on
    }
}
- (void)drawSticks {   // move what the player sees; the values were published by recompute
    for (int i = 0; i < 2; i++) {
        CGFloat R = [self dragR:i];
        CGPoint off = [self knobOffset:i];
        _jknob[i].transform = _stickLive[i] ? CGAffineTransformMakeScale(1.12, 1.12) : CGAffineTransformIdentity;
        _jbase[i].transform = _stickLive[i] ? CGAffineTransformMakeScale(1.08, 1.08) : CGAffineTransformIdentity;
        _jknob[i].center = CGPointMake(R + off.x, R + off.y);
        _jbase[i].center = _stickLive[i] ? _jknob[i].center : CGPointMake(R, R);
        if (!touch_live(_float[i])) continue;
        CGFloat base = [self floatBase:i], nub = [self floatNub:i], maxR = base / 2 - nub / 2;
        CGFloat dx = _floatAt[i].x - _floatFrom[i].x, dy = _floatAt[i].y - _floatFrom[i].y, d = hypot(dx, dy);
        CGFloat cl = d > maxR && d > 0 ? maxR / d : 1;
        _fnub[i].center = CGPointMake(_floatFrom[i].x + dx * cl, _floatFrom[i].y + dy * cl);
    }
}
- (void)showFloat:(int)i at:(CGPoint)p {
    CGFloat base = [self floatBase:i], nub = [self floatNub:i];
    _fbase[i].bounds = CGRectMake(0, 0, base, base); _fbase[i].layer.cornerRadius = base / 2;
    _fbase[i].center = p; _fbase[i].hidden = NO;
    _fnub[i].bounds = CGRectMake(0, 0, nub, nub); _fnub[i].layer.cornerRadius = nub / 2;
    _fnub[i].center = p; _fnub[i].hidden = NO;
    _fbG[i].frame = _fbase[i].bounds; _fbG[i].layer.cornerRadius = base / 2;   // 玻璃跟着底座走，否则它就是一块方块
    _fnG[i].frame = _fnub[i].bounds; _fnG[i].layer.cornerRadius = nub / 2;     // 玻璃帽同理
}
// 没被控件接住的触摸交给游戏的触摸屏（暗黑地牢那类靠点着走的游戏；哈迪斯1这类只用手柄的游戏不受影响）
- (void)pushGame {
    CGRect b = self.bounds; if (b.size.width <= 0 || b.size.height <= 0) return;
    double fx, fy, fw, fh; dm_pad_screen_rect(&fx, &fy, &fw, &fh);
    CGFloat x0 = b.size.width * (CGFloat)fx, y0 = b.size.height * (CGFloat)fy;
    CGFloat pw = b.size.width * (CGFloat)fw, ph = b.size.height * (CGFloat)fh;
    if (pw <= 1 || ph <= 1) { x0 = 0; y0 = 0; pw = b.size.width; ph = b.size.height; }
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) {
        if (_game[i] && !touch_live(_game[i])) _game[i] = nil;   // 漏掉结束事件的手指不能继续占着游戏触摸槽
        if (!_game[i]) continue;
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / pw, 0), 0.999), (float)fmin(fmax((p.y - y0) / ph, 0), 0.999)};
    }
    dm_touch_set_from(t, n, DM_CONTACT_IOS);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@((uint64_t)O_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
// ---- 画面自定义：拖 / 掉指直接改画面位置与大小 ----
// 当前方向：直接按手柄视图现在的尺寸算，不用可能还没更新的 _ori（转屏时父视图往往比手柄先布局，
// 用旧方向的值就会把另一套配置的画面上漏过来）
static int cur_ori(void) { return g_view ? ori_of([g_view bounds].size) : OR_L; }

void front_pic_state(CGFloat *scale, CGFloat *sx, CGFloat *sy, CGFloat *dx, CGFloat *dy, int *editing) {   // front_ios.m lays the game view out from this
    DmPic p = g_pic[cur_ori()];
    if (scale) *scale = p.scale; if (sx) *sx = p.sx; if (sy) *sy = p.sy; if (dx) *dx = p.dx; if (dy) *dy = p.dy;
    if (editing) *editing = g_picEdit;
}
- (void)picEditToggle {
    g_picEdit = !g_picEdit;
    if (g_picEdit) [self reset];   // let go of every key before the screen belongs to the picture
    [self picOverlayRefresh];
    front_game_frame_apply();      // re-lay out now: the dashed frame is drawn (or cleared) by front_ios.m's layout, which this asks for
    [self updateGearMenu];
    LOG("前端：画面编辑模式 %s（拖动移动、双指缩放，再点齿轮退出）", g_picEdit ? "开启" : "关闭");
}
- (void)picOverlayRefresh {   // the hint bar and the dimming: the picture itself gets its dashed frame from front_ios.m
    if (!_picHint) {
        _picHint = [UIView new]; _picHint.hidden = YES; _picHint.userInteractionEnabled = NO;   // 提示条不能吃掉手指：它和画面下边缘重合时，拖下边要仍能拖
        _picHint.backgroundColor = [UIColor colorWithWhite:0 alpha:.55];
        _picHint.layer.cornerRadius = 16; _picHint.clipsToBounds = YES;
        UILabel *l = [UILabel new]; l.numberOfLines = 0; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:14];
        l.textAlignment = NSTextAlignmentCenter; l.tag = 1;
        [_picHint addSubview:l];
        [self addSubview:_picHint];
    }
    UILabel *hint = [_picHint viewWithTag:1];
    hint.text = g_picFree[_ori] ? @"拖左右边只改宽 · 拖上下边只改高 · 中间拖动移动 · 双指缩放" : @"拖动画面移动 · 双指缩放 · 点「解锁比例」后可拖边";
    // 框上的控件：正上方「比例锁定 / 退出编辑」两个按钮，四条边各一个箭头（箭头只在解锁后出现）
    if (!_picLock) {
        _picLock = [self picPill:@"lock.fill" action:@selector(picLockTap)];
        _picQuit = [self picPill:@"xmark" action:@selector(picEditToggle)];
        [_picQuit setTitle:@"退出编辑" forState:UIControlStateNormal];
        _picE[0] = [self picHandle:@"arrow.left.and.right" tag:0];   // 右边：拖宽（左边不动）
        _picE[1] = [self picHandle:@"arrow.left.and.right" tag:1];   // 左边：拖宽（右边不动）
        _picE[2] = [self picHandle:@"arrow.up.and.down" tag:2];      // 下边：拖高（上边不动）
        _picE[3] = [self picHandle:@"arrow.up.and.down" tag:3];      // 上边：拖高（下边不动）
    }
    _picLock.hidden = _picQuit.hidden = !g_picEdit;
    for (int i = 0; i < 4; i++) _picE[i].hidden = !g_picEdit || !g_picFree[_ori];
    [_picLock setTitle:g_picFree[_ori] ? @"已解锁" : @"解锁比例" forState:UIControlStateNormal];
    [_picLock setImage:[UIImage systemImageNamed:g_picFree[_ori] ? @"lock.open.fill" : @"lock.fill"] forState:UIControlStateNormal];
    [self setNeedsLayout];
    [self picHintLayout];
    [self picControlsLayout];
}
- (UIButton *)picPill:(NSString *)symbol action:(SEL)act {   // 框上方的胶囊按钮
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:.66]; b.layer.cornerRadius = 15; b.clipsToBounds = YES;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    [b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}
- (UIButton *)picHandle:(NSString *)symbol tag:(int)tag {   // 圆形的边拖手：拖它改画面的宽 / 高
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag; b.backgroundColor = [UIColor colorWithWhite:1 alpha:.26]; b.layer.cornerRadius = 21; b.clipsToBounds = YES;
    b.tintColor = UIColor.whiteColor;
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    UIPanGestureRecognizer *pg = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(picEdgeDragged:)];
    pg.cancelsTouchesInView = NO; [b addGestureRecognizer:pg];
    [self addSubview:b];
    return b;
}
- (void)picControlsLayout {   // 把控件对齐到 front_pic_rect()（屏幕上真正的画面）
    if (!_picLock || _picLock.hidden) return;
    CGRect r = [self convertRect:front_pic_rect() fromView:nil];
    if (r.size.width < 40 || r.size.height < 40) r = CGRectInset(self.bounds, 24, 24);   // 布局还没跑（新方向 / 首次）也要有可拖的东西，不会看不到
    CGFloat lh = 30, w1 = 110, w2 = 100, gap = 8;   // 「解锁比例」+「退出编辑」作为一组，居中放在框上方
    CGFloat gx = floor(CGRectGetMidX(r) - (w1 + w2 + gap) / 2);
    CGFloat gy = r.origin.y - lh - 8;
    if (gy < 6) gy = r.origin.y + 6;   // 画面顶到屏顶（满屏放大）时把按钮放进框里
    gx = fmax(6, fmin(gx, fmax(6, self.bounds.size.width - (w1 + w2 + gap) - 6)));
    _picLock.frame = CGRectMake(gx, floor(gy), w1, lh);
    _picQuit.frame = CGRectMake(floor(gx + w1 + gap), floor(gy), w2, lh);
    _picE[0].frame = CGRectMake(floor(r.origin.x + r.size.width - 21), floor(CGRectGetMidY(r) - 21), 42, 42);
    _picE[1].frame = CGRectMake(floor(r.origin.x - 21), floor(CGRectGetMidY(r) - 21), 42, 42);
    _picE[2].frame = CGRectMake(floor(CGRectGetMidX(r) - 21), floor(r.origin.y + r.size.height - 21), 42, 42);
    _picE[3].frame = CGRectMake(floor(CGRectGetMidX(r) - 21), floor(r.origin.y - 21), 42, 42);
    NSMutableArray<UIView *> *front = [NSMutableArray array];
    if (_picLock.superview == self) [front addObject:_picLock];
    if (_picQuit.superview == self) [front addObject:_picQuit];
    for (int i = 0; i < 4; i++) if (_picE[i].superview == self) [front addObject:_picE[i]];
    for (UIView *v in front) [self bringSubviewToFront:v];   // 不要被按键光晕 / 提示条遮住
}
- (void)picLockTap {
    // 解锁 / 重新锁定都不改变画面现在的大小：先记下屏幕上的画面框，换完填充模式再反推 scale / sx / sy，
    // 让换完以后画面落在同一个框里（之后由玩家自己拖四条边改）。
    CGRect P = [self convertRect:front_pic_rect() fromView:nil];
    CGFloat W = fmax(self.bounds.size.width, 1), H = fmax(self.bounds.size.height, 1);
    BOOL unlock = !g_picFree[_ori];   // 只影响当前方向：横屏解锁了，竖屏仍然锁定，两套配置互不干扰
    g_picFree[_ori] = unlock ? 1 : 0;
    if (P.size.width >= 20 && P.size.height >= 20) {
        DmPic *p = &g_pic[_ori];
        unsigned sw = 0, sh = 0; mtl_present_src_size(&sw, &sh);
        CGFloat ar = (sw >= 2 && sh >= 2) ? (CGFloat)sw / (CGFloat)sh : 16.0 / 9.0;
        CGFloat lw = P.size.width, lh = P.size.height;
        int eff = unlock ? 1 : g_fillUser;   // 换完之后生效的填充（解锁 = 拉伸；重新锁定 = 菜单里选的那一档）
        if (eff == 0) { if (lw / lh > ar) lh = lw / ar; else lw = lh * ar; }   // 保持比例：把层框做成与画面同宽高比，比例填充后刚好还是这么大
        CGFloat baseW = W * p->scale, baseH = H * p->scale;
        p->sx = fmax(.05, fmin(8, lw / fmax(baseW, 1)));
        p->sy = fmax(.05, fmin(8, lh / fmax(baseH, 1)));
        p->dx = fmax(-1, fmin(1, (CGRectGetMidX(P) - W / 2) / W));
        p->dy = fmax(-1, fmin(1, (CGRectGetMidY(P) - H / 2) / H));
    }
    fill_apply(_ori);                      // 只换生效填充（拉伸 / 保持比例），尺寸已经反推好了，点下去不会跳
    cfg_write(); [self picOverlayRefresh]; [self picControlsLayout]; front_game_frame_apply(); [self updateGearMenu];
    LOG("前端：%s画面比例 %s（生效填充 %d：%s）", _ori == OR_P ? "竖屏" : "横屏", g_picFree[_ori] ? "已解锁" : "锁定", g_fill,
        g_fill == 1 ? "拉伸铺满：拖左右边只改宽、拖上下边只改高" : g_fill == 2 ? "裁切铺满" : "保持比例（只能等比缩放）");
}
- (void)picAxis:(CGPoint)t edge:(int)edge {   // edge 0右 1左 2下 3上 = 只改那一个轴（对侧边钉在原地）；-1 = 整体移动
    DmPic *p = &g_pic[_ori];
    CGFloat W = fmax(self.bounds.size.width, 1), H = fmax(self.bounds.size.height, 1);
    if (edge < 0) {
        p->dx = fmax(-1, fmin(1, _picDx0 + t.x / W)); p->dy = fmax(-1, fmin(1, _picDy0 + t.y / H));
    } else {
        CGFloat w0 = fmax(40., _picRect0.size.width), h0 = fmax(40., _picRect0.size.height);   // 乘法回推，不受黑边影响
        if (edge <= 1) {
            p->sx = fmax(.05, fmin(8, _picSx0 * (w0 + (edge == 0 ? t.x : -t.x)) / w0));
            p->dx = fmax(-1, fmin(1, _picDx0 + t.x / 2 / W));   // 中心走一半，对侧边就不动
        } else {
            p->sy = fmax(.05, fmin(8, _picSy0 * (h0 + (edge == 2 ? t.y : -t.y)) / h0));
            p->dy = fmax(-1, fmin(1, _picDy0 + t.y / 2 / H));
        }
    }
    front_game_frame_apply(); [self picControlsLayout];
}
- (void)picEdgeDragged:(UIPanGestureRecognizer *)rec {   // 拖四条边的箭头：只改那一个轴，对侧边钉在原地不动
    if (rec.state == UIGestureRecognizerStateBegan) {
        _picRect0 = [self convertRect:front_pic_rect() fromView:nil]; [self picBegin]; _picEdge = (int)rec.view.tag; return;
    }
    if (rec.state != UIGestureRecognizerStateChanged) { [self picEnd]; return; }
    [self picAxis:[rec translationInView:self] edge:_picEdge];
}
- (void)picHintLayout {   // bottom-centred, clear of the sticks
    if (_picHint.hidden) return;
    CGRect b = self.bounds; CGFloat w = fmin(420, b.size.width * .8), h = 40;
    CGFloat y = b.size.height - (_ori == OR_P ? 150 : 60);
    _picHint.frame = CGRectMake(floor((b.size.width - w) / 2), floor(y - h / 2), w, h);
}
- (void)picDragged:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    if (pan.state == UIGestureRecognizerStateBegan) {
        _picRect0 = [self convertRect:front_pic_rect() fromView:nil];
        [self picBegin];
        // 解锁后直接拖画面的四条边就行（箭头只是标识）：落点在哪条边附近就只改那个轴
        _picEdge = -1;
        if (g_picFree[_ori] && _picRect0.size.width >= 40 && _picRect0.size.height >= 40) {
            CGPoint q = [pan locationInView:self]; CGFloat th = 34;
            BOOL inY = q.y > _picRect0.origin.y - th && q.y < CGRectGetMaxY(_picRect0) + th;
            BOOL inX = q.x > _picRect0.origin.x - th && q.x < CGRectGetMaxX(_picRect0) + th;
            if (fabs(q.x - _picRect0.origin.x) <= th && inY) _picEdge = 1;               // 左边
            else if (fabs(q.x - CGRectGetMaxX(_picRect0)) <= th && inY) _picEdge = 0;    // 右边
            else if (fabs(q.y - _picRect0.origin.y) <= th && inX) _picEdge = 3;          // 上边
            else if (fabs(q.y - CGRectGetMaxY(_picRect0)) <= th && inX) _picEdge = 2;    // 下边
        }
        UILabel *hint = [_picHint viewWithTag:1];
        if (_picHint && !_picHint.hidden && hint && _picEdge >= 0) hint.text = _picEdge <= 1 ? @"拖左右边：只改宽度" : @"拖上下边：只改高度";
        return;
    }
    if (pan.state == UIGestureRecognizerStateChanged) { [self picMove:[pan translationInView:v]]; return; }   // cumulative since the touch came down, added to the values picBegin took
    [self picEnd];
}
- (void)picPinched:(UIPinchGestureRecognizer *)pinch {
    UIView *v = pinch.view;
    if (pinch.numberOfTouches < 2) { if (pinch.state != UIGestureRecognizerStatePossible) [self picEnd]; return; }
    CGPoint a = [pinch locationOfTouch:0 inView:v], b = [pinch locationOfTouch:1 inView:v];
    CGPoint c = CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2);   // the two fingers' midpoint: what the picture follows (UIPinchGestureRecognizer has no translation)
    if (pinch.state == UIGestureRecognizerStateBegan) { _picAt[0] = c; [self picBegin]; return; }
    if (pinch.state == UIGestureRecognizerStateChanged) {
        [self picMove:CGPointMake(c.x - _picAt[0].x, c.y - _picAt[0].y)];
        DmPic *p = &g_pic[_ori];
        p->scale = fmax(.3, fmin(3, _picScale0 * pinch.scale));   // 锁定和解锁都是等比缩放；改宽 / 高靠框上的箭头
        front_game_frame_apply(); [self picControlsLayout];
    } else [self picEnd];
}
- (void)picBegin { DmPic p = g_pic[_ori]; _picScale0 = p.scale; _picSx0 = p.sx; _picSy0 = p.sy; _picDx0 = p.dx; _picDy0 = p.dy; _picEdge = -1; }   // 默认是移动；拖到边上时 picDragged 会改成那条边
- (void)picMove:(CGPoint)t { [self picAxis:t edge:_picEdge]; }   // t 是从手指落下起的累计位移：一屏宽 / 高 = ±1 范
- (void)picEnd {
    cfg_write(); [self picHintLayout]; [self picControlsLayout];
    DmPic p = g_pic[_ori];
    UILabel *hint = [_picHint viewWithTag:1];   // 拖完把当前三个数报一下，不退出编辑也能看到
    if (_picHint && !_picHint.hidden && hint) hint.text = [NSString stringWithFormat:@"缩放 %.0f%% · 横 %.0f%% · 纵 %.0f%%", p.scale * 100, p.sx * 100, p.sy * 100];
    [self updateGearMenu];   // the menu title shows the new percentage
}
- (void)guardPicTouches:(NSSet<UITouch *> *)ts {   // 画面编辑开着：不把手指当成按键，也不传给游戏的触摸屏
    if (!g_picEdit) return;
    for (UITouch *t in ts) [self releaseTouch:t];   // 同上：不能只删 owner，摇杆 / 游戏触摸槽也得一起放
    _bits = _latched;   // a toggle key the player latched stays down; everything else is let go of before the mode takes the screen
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!g_picEdit || g_editor || _padOn) return NO;   // the pad's own keys keep priority; the gear is a UIButton, which wins over the view's recognisers
    if (g == (UIGestureRecognizer *)_picPanG || g == (UIGestureRecognizer *)_picPinchG) {   // 手指落在框上的锁定按钮 / 箭头时，屏幕的拖动缩放不要抢走
        CGPoint q = [g locationInView:self];
        if (_picLock && !_picLock.hidden && CGRectContainsPoint(CGRectInset(_picLock.frame, -8, -8), q)) return NO;
        if (_picQuit && !_picQuit.hidden && CGRectContainsPoint(CGRectInset(_picQuit.frame, -8, -8), q)) return NO;
        for (int i = 0; i < 4; i++)   // 箭头比看上去小，外扩 14pt 好按
            if (_picE[i] && !_picE[i].hidden && CGRectContainsPoint(CGRectInset(_picE[i].frame, -14, -14), q)) return NO;
    }
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other { return g_picEdit; }   // pan + pinch together: drag with one finger while zooming with two

int dm_pad_fill(void) { return g_picFree[cur_ori()] ? 1 : g_fillUser; }   // front_ios.m: 按当前方向那套配置回答（转屏瞬间也不会用到旧方向的值）

// ---- 金手指 ----
static NSString *const k_cheat_key = @"DmCheatsOn";
static void cheat_save(void) { [DmCheats saveStates]; }      // 记忆与恢复都在 DmCheats 里，启动器那一页拨的开关这边同样认
static void cheat_restore(void) { [DmCheats applySaved]; }
- (void)openCheats {

    if (g_cheatPanel) return;
    dm_cheats_ensure();
    [self reset];
    DmCheatPanel *p = [[DmCheatPanel alloc] initWithPad:self];
    p.frame = self.bounds; p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:p]; g_cheatPanel = p;
    _gear.hidden = YES;
}
- (void)closeCheats { [g_cheatPanel removeFromSuperview]; g_cheatPanel = nil; _gear.hidden = NO; [self updateGearMenu]; }

- (void)cheatToast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"金手指" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self.window.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)cheatsReload {   // 重读包内 + Documents/cheats 并恢复选态，然后重建这一页
    [DmCheats reload];
    [g_cheatPanel removeFromSuperview]; g_cheatPanel = nil;
    [self openCheats]; [self updateGearMenu];
}
- (void)cheatAddCustom {   // 一条数值金手指：名字 + 地址 + 值 + 宽度，写进 Documents/cheats/custom.txt（「文件」App 里也能直接改）
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"添加自定义金手指"
        message:@"地址：main+偏移（十六进制，如 001A2B3C）；以 @ 或 ! 开头则当作绝对地址（如 @6000abcd0）。\n值：十六进制。宽度：1 / 2 / 4 / 8 字节。\n只有可写内存能改（存档数值、已烘焙金手指的开关槽）；游戏代码页改不了。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"名称，如：金钱最大"; f.text = @"我的金手指"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"地址（十六进制，@ 开头=绝对）"; f.keyboardType = UIKeyboardTypeASCIICapable; f.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"值（十六进制，如 000F423F）"; f.keyboardType = UIKeyboardTypeASCIICapable; f.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"宽度 1 / 2 / 4 / 8"; f.text = @"4"; f.keyboardType = UIKeyboardTypeNumberPad; }];
    DmGamepad *ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        int bytes = (int)[a.textFields[3].text integerValue];
        NSString *err = [DmCheats addCustomWithName:a.textFields[0].text address:a.textFields[1].text value:a.textFields[2].text
                                              width:(bytes == 1 || bytes == 2 || bytes == 8) ? bytes : 4];
        [ws cheatToast:err ?: [NSString stringWithFormat:@"已添加：%@\n（在「文件」App → 此 App → cheats/custom.txt，可继续改）", a.textFields[0].text]];
        if (!err) [ws cheatsReload];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self.window.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)cheatImportTxt {   // 从「文件」App 选一个金手指 txt（Atmosphere / EdiZon 格式），拷进 Documents/cheats/ 后合并进列表
    UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.plain-text"] ?: [UTType typeWithIdentifier:@"public.item"]] asCopy:YES];
    dp.allowsMultipleSelection = NO; dp.delegate = self;
    [self.window.rootViewController presentViewController:dp animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *err = [DmCheats importFileAtURL:urls.firstObject];
    [self cheatToast:err ?: [NSString stringWithFormat:@"已导入，共 %d 项金手指。", dm_cheats_count()]];
    if (!err) [self cheatsReload];
}

// DM_PAD_TOUCH=1（Documents/env.txt）：把每一次键位变化记进 log.txt。现场「按了没反应 / 键卡住」只有这份记录能分清是 UIKit 没送结束事件，还是宿主没收到那个位。
static int pad_touch_log(void) {
    static int on = -1;
    if (on < 0) { const char *e = getenv("DM_PAD_TOUCH"); on = e && atoi(e) != 0; }
    return on;
}
// 已经没有手指的 touch 不能继续举着键或摇杆：UIKit 不一定为每根手指都送 touchesEnded（转屏、手势接管、切前后台都会漏）。
// 判定死靠三个信号：phase 已经 Ended/Cancelled；不在当前 UIEvent 的 allTouches 里（UIKit 已经把它丢了）；换了窗口。
// 光看 phase 不够 —— 被系统悄悄丢掉的手指 phase 会停在 Stationary，摇杆就这么卡在最后一个方向。
static BOOL touch_dead(UITouch *t, UIEvent *e, UIWindow *win) {
    UITouchPhase ph = t.phase;
    if (ph == UITouchPhaseEnded || ph == UITouchPhaseCancelled) return YES;
    if (e.allTouches.count && ![e.allTouches containsObject:t]) return YES;
    if (win && t.window && t.window != win) return YES;
    return NO;
}
- (void)sweepDeadTouches:(UIEvent *)e {
    NSMutableArray<UITouch *> *dead = nil;
    for (UITouch *t in _owner) {
        if (!touch_dead(t, e, self.window)) continue;
        if (!dead) dead = [NSMutableArray array];
        [dead addObject:t];
    }
    for (int i = 0; i < 2; i++) {   // 孤儿：状态里还挂着一根 _owner 已经不认识的 touch（记录被别的路径删过）
        UITouch *t = _stick[i]; if (t && ![_owner objectForKey:t]) { if (!dead) dead = [NSMutableArray array]; [dead addObject:t]; }
        t = _float[i];       if (t && ![_owner objectForKey:t]) { if (!dead) dead = [NSMutableArray array]; [dead addObject:t]; }
    }
    if (!dead.count) return;
    for (UITouch *t in dead) {
        NSNumber *own = [_owner objectForKey:t];
        if (pad_touch_log()) LOG("pad: sweep released touch %p owner %#llx", (__bridge void *)t, own ? own.unsignedLongLongValue : 0ull);
        [self releaseTouch:t];   // 键 / 摇杆 / 浮动摇杆 / 游戏触摸槽一起放，不能只删 owner 记录
    }
    [self pushGame];
    [self recompute];
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    [self sweepDeadTouches:e];   // 新手指落下时用本次事件的 allTouches 校对：不在里面的旧 touch 一定是被 UIKit 丢掉了
    [self guardPicTouches:ts]; if (g_picEdit) return;   // 画面编辑开着：手指都归浮层，不给按键也不给游戏的触摸屏
    if (g_editor) return;
    if (_padOn || g_hideAll) {   // 接了实体手柄、或把虚拟按钮全隐藏：触摸仍然进游戏
        BOOL g = NO; for (UITouch *t in ts) g |= [self gameBegin:t]; if (g) [self pushGame]; return;
    }
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        int tk = [self toggleKeyAt:p];
        if (tk >= 0) {   // Toggle Instead of Hold: one tap latches the key, the next lets it go
            uint64_t bit = 1ull << k_def[tk].hid;
            _latched = (_latched & bit) ? _latched & ~bit : _latched | bit;
            [_owner setObject:@((uint64_t)O_KEY | (uint64_t)tk << 8) forKey:t];
            [_mask setObject:@(0) forKey:t];
            if (g_btnHap) [_hapt impactOccurred];
            continue;
        }
        int k = [self ctlAt:p];
        if (k >= 0 && k_def[k].kind == K_COMBO) {
            int slot = k - CT_C1;
            if (g_val[_ori][k].toggle) {   // toggle, like any other button: one tap latches every checked key, the next lets go
                uint64_t cm = combo_mask(slot);
                _latched = (_latched & cm) ? _latched & ~cm : _latched | cm;
                if (g_btnHap) [_hapt impactOccurred];
            } else if (g_seq_hold[slot]) {   // hold mode: every checked key goes down with the finger
                [_owner setObject:@((uint64_t)O_KEY | (uint64_t)k << 8) forKey:t];
                [_mask setObject:@(combo_mask(slot)) forKey:t];
            } else {
                if (g_seq_holdlast[slot] || g_seq_keep[slot]) {   // own the touch so a release can let the held keys go
                    [_owner setObject:@((uint64_t)O_COMBO | (uint64_t)slot << 8) forKey:t];
                    [_mask setObject:@(0) forKey:t];
                }
                [self playCombo:k];   // one press plays the ordered sequence
            }
            continue;
        }
        if (k >= 0 && k_def[k].kind != K_STICK) {
            [_owner setObject:@((uint64_t)O_KEY | (uint64_t)k << 8) forKey:t];
            [_mask setObject:@([self keyMaskAt:p]) forKey:t];
            continue;
        }
        if (k >= 0) {   // a fixed stick
            int i = k - CT_LSTICK;
            // 上一根手指没送结束事件时，这里直接抢过来：摇杆指针不能因为一根死 touch 而永久失效
            if (_float[i] && _float[i] != t) [self releaseTouch:_float[i]];
            if (_stick[i] && _stick[i] != t) [self releaseTouch:_stick[i]];
            _stick[i] = t; _stickAt[i] = _stickFrom[i] = p; _stickLive[i] = g_tapMove[i]; _stickEdge[i] = NO;
            [_owner setObject:@((uint64_t)O_STICK | (uint64_t)i << 8) forKey:t];
            [UIView animateWithDuration:.15 animations:^{ _jring[i].alpha = 1; }];   // the circle the knob travels in
            continue;
        }
        for (int i = 0; i < 2; i++) {   // nothing under the finger: a floating stick may be born here, in its own half or its own region
            if (!g_jmode[i] || g_val[_ori][CT_LSTICK + i].hidden) continue;
            CGFloat mid = self.bounds.size.width / 2;
            if (i == 0 ? p.x >= mid : p.x <= mid) continue;
            if (g_jarea[i] && !CGRectContainsPoint([self regionRect:i], p)) continue;
            // 旧的浮动摇杆若挂在一根已经丢掉的手指上，这里必须接管：以前 `if (_float[i]) continue;` 会让这根摇杆从此再也建不出来
            if (_float[i] && _float[i] != t) [self releaseTouch:_float[i]];
            if (_stick[i] && _stick[i] != t) [self releaseTouch:_stick[i]];
            _float[i] = t; _floatFrom[i] = _floatAt[i] = p;
            [_owner setObject:@((uint64_t)O_FLOAT | (uint64_t)i << 8) forKey:t];
            [self showFloat:i at:p];
            break;
        }
        if (![_owner objectForKey:t]) [self gameBegin:t];   // 空白处：交给游戏的触摸屏
    }
    [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (g_editor) return;
    for (UITouch *t in ts) {
        NSNumber *own = [_owner objectForKey:t]; if (!own) continue;
        uint64_t v = own.unsignedLongLongValue; int kind = (int)(v & 0xff), idx = (int)(v >> 8);
        CGPoint p = [t locationInView:self];
        if (kind == O_KEY && g_slide && !g_val[_ori][idx].toggle && k_def[idx].kind != K_COMBO) [_mask setObject:@([self keyMaskAt:p]) forKey:t];   // slide between keys, as MelonX's buttonSlide — but never a hold-mode combo: keyMaskAt skips combos, so the first finger drift would drop every held key (按住断触)
        else if (kind == O_STICK) {
            // 摇杆可能被另一根手指抢走过（或那个指针已被 sweep 清掉）。这根手指还按着，就把它夺回来，
            // 否则它会拖着一根不归它管的摇杆改 _stickAt，方向跟着乱跳；但另一根活着的手指正握着摇杆时不掺和。
            if (_stick[idx] != t) {
                if (touch_live(_stick[idx])) continue;
                UITouch *other = _float[idx];
                if (other && other != t) [self releaseTouch:other];
                _stick[idx] = t; _stickFrom[idx] = p; _stickLive[idx] = YES; _stickEdge[idx] = NO;
            }
            _stickAt[idx] = p;
            if (!_stickLive[idx] && hypot(p.x - _stickFrom[idx].x, p.y - _stickFrom[idx].y) >= K_DRAG_MIN * self.u) _stickLive[idx] = YES;
            CGFloat R = [self dragR:idx], d = hypot(p.x - [self ctlCenter:CT_LSTICK + idx].x, p.y - [self ctlCenter:CT_LSTICK + idx].y);
            if (d >= R && !_stickEdge[idx]) { if (g_btnHap) [_edge impactOccurredWithIntensity:.55]; _stickEdge[idx] = YES; }   // the knob hit the boundary (the same 虚拟按键震动 switch)
            else if (d < R) _stickEdge[idx] = NO;
        } else if (kind == O_FLOAT) {
            if (_float[idx] != t) {   // 同上：浮动摇杆也要能被原来的手指夺回
                if (touch_live(_float[idx])) continue;
                UITouch *other = _stick[idx];
                if (other && other != t) [self releaseTouch:other];
                _float[idx] = t; _floatFrom[idx] = p; [self showFloat:idx at:p];
            }
            _floatAt[idx] = p;
        }
        else if (kind == O_GAME) _game[idx] = t;
    }
    [self pushGame];
    [self recompute];
}
- (void)springStick:(int)i {   // release: transforms back, then the spring to the centre
    if (i < 0 || i > 1) return;
    CGFloat R = [self dragR:i];
    [UIView animateWithDuration:.15 animations:^{ _jring[i].alpha = g_jbg[i] ? 1 : 0; }];
    UISpringTimingParameters *tp = [[UISpringTimingParameters alloc] initWithMass:0.6 stiffness:280 damping:18 initialVelocity:CGVectorMake(0, 0)];
    UIViewPropertyAnimator *an = [[UIViewPropertyAnimator alloc] initWithDuration:0 timingParameters:tp];
    CGPoint c = CGPointMake(R, R);
    [an addAnimations:^{ _jknob[i].center = c; _jbase[i].center = c; _jknob[i].transform = CGAffineTransformIdentity; _jbase[i].transform = CGAffineTransformIdentity; }];
    [an startAnimation];
}
// 一根触摸彻底放手。所有被它举着的状态必须一起清 —— 只删 _owner 记录、把 _stick[i] / _float[i] 留在死 touch 上，
// knobOffset 就会按最后一帧的落点一直算方向：角色自己往一个方向走、玩家怎么拖摇杆都拉不回来（「摇杆卡住，控制不了角色」）。
- (void)releaseTouch:(UITouch *)t {
    NSNumber *own = [_owner objectForKey:t];
    uint64_t v = own ? own.unsignedLongLongValue : 0;
    int kind = (int)(v & 0xff);
    for (int i = 0; i < 2; i++) {   // 不依赖 owner 记录：状态里还挂着这根 touch 就一起放掉
        if (_stick[i] == t) {
            _stick[i] = nil; _stickLive[i] = NO; _stickEdge[i] = NO;
            if (pad_touch_log()) LOG("pad: 摇杆%d 放手（%s）", i, own ? "结束事件" : "孤儿清理");
            [self springStick:i];
        }
        if (_float[i] == t) {
            _float[i] = nil; _floatFrom[i] = _floatAt[i] = CGPointZero;
            _fbase[i].hidden = _fnub[i].hidden = YES;
            if (pad_touch_log()) LOG("pad: 浮动摇杆%d 放手（%s）", i, own ? "结束事件" : "孤儿清理");
        }
    }
    for (int i = 0; i < 16; i++) if (_game[i] == t) _game[i] = nil;   // 手指离开游戏的触摸屏（不再上报这个槽位的坐标）
    if (kind == O_COMBO) {   // a sequence that is holding its last key lets it go
        _seqHeld = NO;
        if (_seqHolding) { _seqHolding = NO; _seqBits = 0; _seqSlot = -1; }
    }
    [_owner removeObjectForKey:t]; [_mask removeObjectForKey:t];
}
- (void)endTouches:(NSSet<UITouch *> *)ts {
    for (UITouch *t in ts) [self releaseTouch:t];
    [self pushGame];
    [self recompute];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts]; }
- (void)reset {
    _seqGen++; _seqBits = 0; _seqSlot = -1; _seqHeld = NO; _seqHolding = NO;   // cancel a combo sequence that is still playing
    [_owner removeAllObjects]; [_mask removeAllObjects];
    for (int i = 0; i < 2; i++) {
        _stick[i] = nil; _stickLive[i] = NO; _float[i] = nil;
        _fbase[i].hidden = _fnub[i].hidden = YES;
        _jring[i].alpha = g_jbg[i] ? 1 : 0;
        _jknob[i].transform = _jbase[i].transform = CGAffineTransformIdentity;
    }
    _latched = 0;
    [self recompute];
}
// ---- Combo sequences ----
- (void)playCombo:(int)k {   // one press: press each key in the order the player added it; step 80 ms, gap 40 ms
    int slot = k - CT_C1; if (slot < 0 || slot >= COMBO_SLOTS || g_seq_n[slot] <= 0) return;
    unsigned gen = ++_seqGen; _seqSlot = k; _seqHolding = NO; _seqHeld = (g_seq_holdlast[slot] || g_seq_keep[slot]) ? YES : NO;
    [self refreshState];
    [self seqStep:slot at:0 gen:gen];
}
- (void)seqStep:(int)slot at:(int)i gen:(unsigned)g {
    if (g != _seqGen) return;
    if (i >= g_seq_n[slot]) { _seqBits = 0; _seqSlot = -1; _seqHolding = NO; [self recompute]; return; }
    uint64_t bit = 1ull << g_seq[slot][i];
    _seqBits = g_seq_keep[slot] ? (_seqBits | bit) : bit;   // 顺序按住会累积（ZL 还按着时再按 ZR）；点按模式一次只有一个键
    [self recompute];
    double gap = fmax(0, fmin(2000, g_seq_gap[slot])), step = fmax(40, fmin(2000, g_seq_holdms[slot]));
    BOOL last = (i == g_seq_n[slot] - 1);
    __weak DmGamepad *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(step * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        DmGamepad *s = ws; if (!s || g != s->_seqGen) return;
        if (last && (g_seq_holdlast[slot] || g_seq_keep[slot]) && s->_seqHeld) {   // 最后一键：按住不放，松手才松开
            s->_seqHolding = YES;
            return;
        }
        if (g_seq_keep[slot]) { s->_seqBits |= bit; } else { s->_seqBits = 0; }   // 顺序按住不松键，点按模式先松开
        [s recompute];
        if (last) { s->_seqSlot = -1; s->_seqHolding = NO; return; }   // a quick tap ends the whole sequence here
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            DmGamepad *s2 = ws; if (s2) [s2 seqStep:slot at:i + 1 gen:g];
        });
    });
}

// ---- 实体手柄：按键 / 摇杆采集交给 S2Arm 的 ios/controller.m（避免两套 GameController 逻辑打架），
//      这里只按 s2a_pad_has_controller() 收起 / 恢复虚拟按键（齿轮与性能叠层保持） ----
- (void)padsChanged {
    BOOL any = s2a_pad_has_controller() != 0;
    if (any == _padOn) return;
    _padOn = any;
    if (any) { [self closeEditor]; [self reset]; }
    [self applyPrefs];
}

// ---- What the editor changes ----
- (CGFloat)field:(int)f ofCtl:(int)k side:(int)i {
    switch (f) {
        case F_SIZE: return k >= 0 ? g_val[_ori][k].size : 1;
        case F_ALPHA: return k >= 0 ? g_val[_ori][k].alpha : 1;
        case F_HIDE: return k >= 0 && g_val[_ori][k].hidden;
        case F_TOGGLE: return k >= 0 && g_val[_ori][k].toggle;
        case F_DPADSTICK: return g_dpadStick;
        case F_SCALE: return g_scale;
        case F_DIM: return g_dim;
        case F_SLIDE: return g_slide;
        case F_FPS: return g_fps;
        case F_RAM: return g_ram;
        case F_HUDPOS: return g_hudPos;
        case F_CSTEP: if (k >= CT_C1 && k <= CT_C6 && i >= 0 && i < 16) { int slot = k - CT_C1; for (int j = 0; j < g_seq_n[slot]; j++) if (g_seq[slot][j] == i) return 1; } return 0;
        case F_HIDEALL: return g_hideAll;
        case F_CGAP: return (k >= CT_C1 && k <= CT_C6) ? g_seq_gap[k - CT_C1] : 40;
        case F_CHOLD: return (k >= CT_C1 && k <= CT_C6) ? g_seq_hold[k - CT_C1] : 0;
        case F_CHLAST: return (k >= CT_C1 && k <= CT_C6) ? g_seq_holdlast[k - CT_C1] : 1;
        case F_CHOLDMS: return (k >= CT_C1 && k <= CT_C6) ? g_seq_holdms[k - CT_C1] : 80;
        case F_CKEEP: return (k >= CT_C1 && k <= CT_C6) ? g_seq_keep[k - CT_C1] : 0;
        case F_ROTLOCK: return g_rotLock;
        case F_JMODE: return g_jmode[i];
        case F_JAREA: return g_jarea[i];
        case F_JBG: return g_jbg[i];
        case F_TAPMOVE: return g_tapMove[i];
        case F_TAPFORCE: return g_jtap[i];
        case F_DEAD: return g_jdead[i];
        case F_SENS: return g_sens;
        case F_FSIZE: return g_fsize;
        case F_FOP: return g_fop;
        case F_FDEAD: return g_fdead;
        default: return 0;
    }
}
- (void)setField:(int)f ofCtl:(int)k side:(int)i to:(CGFloat)v {
    switch (f) {
        case F_SIZE: if (k >= 0) g_val[_ori][k].size = fmax(.5, fmin(5, v)); break;
        case F_ALPHA: if (k >= 0) g_val[_ori][k].alpha = fmax(.05, fmin(1, v)); break;
        case F_HIDE: if (k >= 0) g_val[_ori][k].hidden = v != 0; break;
        case F_TOGGLE: if (k >= 0) { g_val[_ori][k].toggle = v != 0; if (!g_val[_ori][k].toggle) { if (k_def[k].kind == K_COMBO) _latched &= ~(uint64_t)combo_mask(k - CT_C1); else _latched &= ~(1ull << k_def[k].hid); } } break;
        case F_DPADSTICK: g_dpadStick = v != 0; break;
        case F_SCALE: g_scale = fmax(.5, fmin(5, v)); break;
        case F_DIM: g_dim = fmax(.05, fmin(1, v)); break;
        case F_SLIDE: g_slide = v != 0; break;
        case F_FPS: g_fps = v != 0; break;
        case F_RAM: g_ram = v != 0; break;
        case F_HUDPOS: g_hudPos = (int)v; break;
        case F_CSTEP: if (k >= CT_C1 && k <= CT_C6 && i >= 0 && i < 16) { int slot = k - CT_C1, at = -1;   // on appends (the addition order is the play order), off removes
            for (int j = 0; j < g_seq_n[slot]; j++) if (g_seq[slot][j] == i) { at = j; break; }
            if (v && at < 0 && g_seq_n[slot] < COMBO_MAX) g_seq[slot][g_seq_n[slot]++] = (uint8_t)i;
            else if (!v && at >= 0) { for (int j = at; j + 1 < g_seq_n[slot]; j++) g_seq[slot][j] = g_seq[slot][j + 1]; g_seq_n[slot]--; } } break;
        case F_HIDEALL: g_hideAll = v != 0; break;
        case F_CGAP: if (k >= CT_C1 && k <= CT_C6) g_seq_gap[k - CT_C1] = fmaxf(0, fminf(200, (float)v)); break;
        case F_CHOLD: if (k >= CT_C1 && k <= CT_C6) { g_seq_hold[k - CT_C1] = v != 0; if (v) { g_seq_holdlast[k - CT_C1] = 0; g_seq_keep[k - CT_C1] = 0; } } break;   // 三种按住方式互斥
        case F_CHLAST: if (k >= CT_C1 && k <= CT_C6) { g_seq_holdlast[k - CT_C1] = v != 0; if (v) { g_seq_hold[k - CT_C1] = 0; g_seq_keep[k - CT_C1] = 0; } } break;
        case F_CHOLDMS: if (k >= CT_C1 && k <= CT_C6) g_seq_holdms[k - CT_C1] = fmaxf(40, fminf(2000, (float)v)); break;
        case F_CKEEP: if (k >= CT_C1 && k <= CT_C6) { g_seq_keep[k - CT_C1] = v != 0; if (v) { g_seq_hold[k - CT_C1] = 0; g_seq_holdlast[k - CT_C1] = 0; } } break;
        case F_ROTLOCK: g_rotLock = v != 0; break;
        case F_JMODE: g_jmode[i] = (int)v; break;
        case F_JAREA: g_jarea[i] = (int)v; break;
        case F_JBG: g_jbg[i] = (int)v; break;
        case F_TAPMOVE: g_tapMove[i] = (int)v; break;
        case F_TAPFORCE: g_jtap[i] = fmax(.1, fmin(1, v)); break;
        case F_DEAD: g_jdead[i] = fmax(0, fmin(.5, v)); break;
        case F_SENS: g_sens = fmax(1, fmin(3, v)); break;
        case F_FSIZE: g_fsize = fmax(.5, fmin(2, v)); break;
        case F_FOP: g_fop = fmax(.05, fmin(1, v)); break;
        case F_FDEAD: g_fdead = fmax(0, fmin(.5, v)); break;
        default: break;
    }
    cfg_write();
    [self applyPrefs];
}
- (void)moveCtl:(int)k to:(CGPoint)p {
    CGRect s = [self rectOfCtl:k]; CGFloat u = fmax(self.u, .2), m = 8;
    p.x = fmax(CGRectGetMinX(self.bounds) + m, fmin(CGRectGetMaxX(self.bounds) - m, p.x));
    p.y = fmax(CGRectGetMinY(self.bounds) + m, fmin(CGRectGetMaxY(self.bounds) - m, p.y));
    DmCtlVal *v = &g_val[_ori][k];
    switch (k_def[k].anchor) { case 0: v->dx = (p.x - CGRectGetMinX(s)) / u; break; case 1: v->dx = (CGRectGetMaxX(s) - p.x) / u; break; default: v->dx = (p.x - CGRectGetMidX(s)) / u; }
    v->dy = ([self vside:k] ? CGRectGetMaxY(s) - p.y : p.y - CGRectGetMinY(s)) / u;
    [self setNeedsLayout];
}
- (void)resetCtl:(int)k {
    const DmCtlDef *d = &k_def[k];
    unsigned char h = (unsigned char)(_ori == OR_P ? d->hidP : 0); if (k_def[k].kind == K_COMBO) h = 1;   // combos go back to "not added"
    g_val[_ori][k] = (DmCtlVal){_ori == OR_P ? d->dxP : d->dxL, _ori == OR_P ? d->dyP : d->dyL, def_size(k), 1, h, 0};
    cfg_write(); [self applyPrefs];
}
- (void)resetAll {
    for (int k = 0; k < CT_N; k++) [self resetCtl:k];
    for (int i = 0; i < 2; i++) g_reg[_ori][i] = k_regDef[_ori][i];
    for (int i = 0; i < COMBO_SLOTS; i++) { g_seq_n[i] = 0; g_seq_gap[i] = 40; g_seq_holdms[i] = 80; g_seq_hold[i] = 1; g_seq_holdlast[i] = 0; g_seq_keep[i] = 0; }   // combos go back to empty, 40 ms apart, 80 ms per key, hold all
    cfg_write(); [self applyPrefs];
}
- (void)setRegion:(int)i to:(CGRect)r {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat w = fmax(.15, fmin(.5, r.size.width / W)), h = fmax(.15, fmin(1, r.size.height / H));
    CGFloat x = r.origin.x / W;
    x = i == 0 ? fmin(x, .5 - w) : fmax(x, .5);
    g_reg[_ori][i] = (DmRectN){fmax(0, x), fmax(0, r.origin.y / H), w, h};
    cfg_write(); [self setNeedsLayout]; [g_editor rebuild];
}
- (void)centerRegionOnStick:(int)i {   // the float area is defined around the stick, so moving either one keeps the two stacked (MelonX's region editor)
    DmRectN r = g_reg[_ori][i], old = r;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W <= 0 || H <= 0) return;
    CGPoint c = [self ctlCenter:CT_LSTICK + i];
    CGFloat x = c.x / W - r.w / 2, y = c.y / H - r.h / 2;
    x = fmax(0, fmin(1 - r.w, x)); y = fmax(0, fmin(1 - r.h, y));
    x = i == 0 ? fmin(x, .5 - r.w) : fmax(x, .5);
    r.x = x; r.y = y; g_reg[_ori][i] = r;
    if (fabs(r.x - old.x) > 1e-6 || fabs(r.y - old.y) > 1e-6) [self setNeedsLayout];   // only when it actually moved, so calling this from the layout itself converges
}

// ---- Opening and closing the editor ----
- (void)openEditor {
    if (g_editor) return;
    [self reset];
    _scrim = [CAShapeLayer layer]; _scrim.fillColor = [UIColor colorWithWhite:0 alpha:.45].CGColor;
    _scrim.path = CGPathCreateWithRect(self.bounds, NULL);
    [self.layer insertSublayer:_scrim atIndex:0];
    DmPadEditor *e = [[DmPadEditor alloc] initWithPad:self];
    e.frame = self.bounds; e.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:e]; g_editor = e;
    _gear.hidden = YES;   // MelonX takes the gear out of the hierarchy while the editor is open
    [self applyPrefs];   // every control shows again, the ones with a physical pad connected included
}
- (void)closeEditor {
    if (!g_editor) return;
    [g_editor removeFromSuperview]; g_editor = nil;
    [_scrim removeFromSuperlayer]; _scrim = nil;
    cfg_write();
    _gear.hidden = NO; [self restoreOpacity];
    [self applyPrefs];
}
@end

// ---- The layout editor: a transparent overlay above the controls ----
//   The tool row at the top and the property card under it are MelonX's LayoutEditorView, in Chinese: the card shows a row per setting,
//   a slider for the sizes and the opacity, a switch for the on / off options and a segmented control for the modes.
//   Drag a control to move it, two fingers to resize it, hold it to put it back; the floating stick's region box can be dragged and resized too.
@interface DmRow : NSObject
@property (nonatomic) int f, k, i;                       // which field of which control or stick this row edits
@property (nonatomic) CGFloat mn, mx, st;
@property (nonatomic) NSString *fmt;
@property (nonatomic) UILabel *tl, *vl, *sub;             // title, the value on the right, the small explanation under the title
@property (nonatomic) UISlider *sl;
@property (nonatomic) UISwitch *sw;
@property (nonatomic) UISegmentedControl *seg;
@property (nonatomic) CGFloat tall;
@end
@implementation DmRow
@end

@implementation DmPadEditor {
    __weak DmGamepad *_pad;
    int _k;                                              // the selected control, -1 = the whole controller
    UIView *_bar, *_card; UIVisualEffectView *_barFx, *_cardFx; UIScrollView *_scroll; UIView *_content;
    UIButton *_bPanel, *_bReset, *_bDone, *_bOri[2], *_bName;
    NSMutableArray *_rows;
    UILabel *_comboNote;                                 // the combo card's order line (updated without rebuilding the card)
    CAShapeLayer *_sel;
    UIView *_regv[2]; CAShapeLayer *_regl[2]; UIButton *_regh[2]; UILabel *_regtag[2];
    CGFloat _pinch0;
    CGPoint _last;                                       // the previous point of a region drag
    BOOL _dragged, _panelHidden;
    int _regMode;                                        // 0 none, 1 move the region box, 2 resize it
    int _regSide;
}
- (instancetype)initWithPad:(DmGamepad *)pad {
    if ((self = [super initWithFrame:pad.bounds])) {
        _pad = pad; _k = -1; _rows = [NSMutableArray array];
        self.opaque = NO; self.backgroundColor = UIColor.clearColor; self.multipleTouchEnabled = YES;
        _sel = [CAShapeLayer layer]; _sel.fillColor = nil; _sel.lineWidth = 2.5;
        _sel.strokeColor = UIColor.systemBlueColor.CGColor; _sel.hidden = YES; [self.layer addSublayer:_sel];
        for (int i = 0; i < 2; i++) {   // the floating region: a green dashed box with a handle in its lower right corner
            _regv[i] = [UIView new]; _regv[i].hidden = YES; _regv[i].userInteractionEnabled = NO; [self addSubview:_regv[i]];
            _regl[i] = [CAShapeLayer layer]; _regl[i].fillColor = [UIColor colorWithRed:0 green:.8 blue:.3 alpha:.10].CGColor;
            _regl[i].strokeColor = [UIColor colorWithRed:0 green:.8 blue:.3 alpha:.85].CGColor;
            _regl[i].lineWidth = 2; _regl[i].lineDashPattern = @[@9, @6]; [_regv[i].layer addSublayer:_regl[i]];
            UILabel *tag = [UILabel new]; tag.text = i ? @"右浮动区域" : @"左浮动区域";
            tag.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]; tag.textColor = UIColor.whiteColor;
            tag.backgroundColor = [UIColor colorWithRed:0 green:.8 blue:.3 alpha:.8]; tag.layer.cornerRadius = 5;
            tag.clipsToBounds = YES; tag.textAlignment = NSTextAlignmentCenter; [tag sizeToFit];
            _regtag[i] = tag; [_regv[i] addSubview:tag];   // laid out with the box in layoutAll
            _regh[i] = [UIButton new]; _regh[i].hidden = YES; [_regv[i] addSubview:_regh[i]];
            UIImage *h = symbol_img(@"arrow.up.left.and.arrow.down.right");
            if (h) [_regh[i] setImage:h forState:UIControlStateNormal]; else [_regh[i] setTitle:@"⤡" forState:UIControlStateNormal];
            _regh[i].tintColor = [UIColor colorWithRed:0 green:.7 blue:.25 alpha:1];
            _regh[i].backgroundColor = UIColor.whiteColor; _regh[i].layer.cornerRadius = 6; _regh[i].layer.borderWidth = 1.5;
            _regh[i].layer.borderColor = [UIColor colorWithRed:0 green:.8 blue:.3 alpha:.85].CGColor;
        }
        [self buildBar]; [self buildCard]; [self pickCtl:-1];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        pan.maximumNumberOfTouches = 1;   // a second finger means the pinch is resizing, not a drag
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onHold:)];
        hold.minimumPressDuration = 0.45;
        for (UIGestureRecognizer *g in @[pan, tap, pinch, hold]) { g.delegate = (id<UIGestureRecognizerDelegate>)self; [self addGestureRecognizer:g]; }
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [super touchesBegan:ts withEvent:e]; _dragged = NO; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {   // the editor's own panels must not drag a control
    for (UIView *v = t.view; v; v = v.superview) if (v == _card || v == _bar) return NO;
    return YES;
}

// ---- The tool row ----
- (UIButton *)barBtn:(NSString *)t action:(SEL)a color:(UIColor *)c {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal]; [b setTitleColor:c ?: UIColor.whiteColor forState:UIControlStateNormal];
    NSString *sn = [self iconFor:t];
    if (sn) {   // a 14 pt glyph beside the text: the shared 60 pt symbol was far too tall and sizeToFit blew the button up (that pushed 完成 off the bar)
        UIImage *img = [[UIImage systemImageNamed:sn withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if (img) [b setImage:img forState:UIControlStateNormal];
    }
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; b.tintColor = c ?: UIColor.whiteColor;
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside]; [_bar addSubview:b];
    return b;
}
- (NSString *)iconFor:(NSString *)t {
    if ([t isEqualToString:@"面板"]) return @"eye.slash";
    if ([t isEqualToString:@"全部重置"]) return @"arrow.counterclockwise";
    if ([t isEqualToString:@"完成"]) return @"checkmark";
    return nil;
}
- (void)buildBar {
    _bar = [UIView new]; [self addSubview:_bar];
    _barFx = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    _barFx.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [_bar addSubview:_barFx];
    _barFx.layer.cornerRadius = 18; _barFx.layer.cornerCurve = kCACornerCurveContinuous; _barFx.clipsToBounds = YES;
    _bPanel = [self barBtn:@"面板" action:@selector(onPanel) color:nil];
    _bReset = [self barBtn:@"全部重置" action:@selector(onResetAll) color:UIColor.systemOrangeColor];
    _bName = [self barBtn:@(DM_GAME_NAME) action:@selector(onTapName) color:UIColor.systemGrayColor];
    _bName.userInteractionEnabled = NO;
    _bOri[0] = [self barBtn:@"竖屏" action:@selector(onOriP) color:nil];
    _bOri[1] = [self barBtn:@"横屏" action:@selector(onOriL) color:nil];
    _bDone = [self barBtn:@"完成" action:@selector(onDone) color:UIColor.systemBlueColor];
}
// ---- The property card ----
- (void)buildCard {
    _card = [UIView new]; [_card addSubview:[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]]];
    ((UIVisualEffectView *)_card.subviews.firstObject).autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _cardFx = (UIVisualEffectView *)_card.subviews.firstObject;
    _cardFx.layer.cornerRadius = 16; _cardFx.layer.cornerCurve = kCACornerCurveContinuous; _cardFx.clipsToBounds = YES;
    _scroll = [UIScrollView new]; _scroll.showsVerticalScrollIndicator = YES;
    _scroll.delaysContentTouches = NO; _scroll.canCancelContentTouches = YES;   // the scroll may cancel a switch drag (the combo page needs to scroll) but still starts sliders immediately
    [_card addSubview:_scroll];
    _content = [UIView new]; [_scroll addSubview:_content];
    [self addSubview:_card];
}
- (DmRow *)addRow:(int)f k:(int)k i:(int)i title:(NSString *)t {
    DmRow *r = [DmRow new]; r.f = f; r.k = k; r.i = i;
    r.tl = [UILabel new]; r.tl.text = t; r.tl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    r.tl.textColor = [UIColor colorWithWhite:1 alpha:.85]; [_content addSubview:r.tl];
    r.tall = 34; [_rows addObject:r];
    return r;
}
- (DmRow *)addNote:(NSString *)t {
    DmRow *r = [DmRow new]; r.f = -1;
    r.tl = [UILabel new]; r.tl.text = t; r.tl.numberOfLines = 0; r.tl.font = [UIFont systemFontOfSize:11];
    r.tl.textColor = [UIColor colorWithWhite:1 alpha:.6]; [r.tl sizeToFit];
    r.tall = fmax(30, ceil(r.tl.frame.size.height) + 4);
    [_content addSubview:r.tl]; [_rows addObject:r];
    return r;
}
- (void)addSlider:(DmRow *)r mn:(CGFloat)mn mx:(CGFloat)mx st:(CGFloat)st fmt:(NSString *)fmt {
    r.mn = mn; r.mx = mx; r.st = st; r.fmt = fmt;
    r.sl = [UISlider new]; r.sl.minimumValue = mn; r.sl.maximumValue = mx;   // without these the slider stays 0..1, so every range above 1 was unreachable (size stuck at 1x, sensitivity frozen at its floor)
    [r.sl addTarget:self action:@selector(onSlider:) forControlEvents:UIControlEventValueChanged];
    [_content addSubview:r.sl];
    r.vl = [UILabel new]; r.vl.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    r.vl.textColor = UIColor.whiteColor; r.vl.textAlignment = NSTextAlignmentRight; [_content addSubview:r.vl];
    r.tall = 40; r.vl.text = [NSString stringWithFormat:fmt, [self valueOf:r]];
}
- (void)addSwitch:(DmRow *)r sub:(NSString *)sub {
    r.sw = [UISwitch new]; [r.sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
    [_content addSubview:r.sw];
    if (sub.length) {   // the explanation takes the width under the title, so this row is taller
        r.sub = [UILabel new]; r.sub.text = sub; r.sub.font = [UIFont systemFontOfSize:11];
        r.sub.textColor = [UIColor colorWithWhite:1 alpha:.55]; [_content addSubview:r.sub];
        r.tall = 48;
    } else r.tall = 40;
}
- (void)addSeg:(DmRow *)r items:(NSArray<NSString *> *)items {
    r.seg = [UISegmentedControl new]; [r.seg removeAllSegments];
    for (NSUInteger j = 0; j < items.count; j++) [r.seg insertSegmentWithTitle:items[j] atIndex:j animated:NO];
    r.seg.selectedSegmentIndex = 0; [r.seg addTarget:self action:@selector(onSeg:) forControlEvents:UIControlEventValueChanged];
    [_content addSubview:r.seg]; r.tall = 40;
}
- (CGFloat)valueOf:(DmRow *)r { return r.f >= 0 ? [_pad field:r.f ofCtl:r.k side:r.i] : 0; }
- (void)readRows {
    for (DmRow *r in _rows) {
        CGFloat v = [self valueOf:r];
        if (r.sl) { r.sl.value = v; r.vl.text = [NSString stringWithFormat:r.fmt, v]; }
        if (r.sw) r.sw.on = v != 0;
        if (r.seg) r.seg.selectedSegmentIndex = (NSInteger)v;
    }
}
- (void)pickCtl:(int)k {   // rebuild the card for the new selection (MelonX animates the change with a spring)
    DmGamepad *pad = _pad; if (!pad) return;
    _k = k;
    _comboNote = nil;
    if (k >= CT_LSTICK && k <= CT_RSTICK) {   // a floating region always sits centered on its stick, so selecting one re-centers a box left behind by an older build
        int si = k - CT_LSTICK;
        if ([pad field:F_JMODE ofCtl:k side:si] && [pad field:F_JAREA ofCtl:k side:si]) [pad centerRegionOnStick:si];
    }
    [_rows removeAllObjects]; [_content.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    if (k < 0) {
        [self addNote:@"点按一个按钮或摇杆进行编辑，拖动可以移动它。"];
        [self addSlider:[self addRow:F_DIM k:-1 i:0 title:@"整体不透明度"] mn:.05 mx:1 st:.05 fmt:@"%.2f"];
        [self addSlider:[self addRow:F_SCALE k:-1 i:0 title:@"整体大小"] mn:.5 mx:5 st:.1 fmt:@"%.1f×"];
        [self addSlider:[self addRow:F_SENS k:-1 i:0 title:@"摇杆灵敏度"] mn:1 mx:3 st:.1 fmt:@"%.1f"];   // the sensitivity is shared by both sticks, so it also lives in the short panel where nothing scrolls
        [self addSwitch:[self addRow:F_SLIDE k:-1 i:0 title:@"滑动切换按键"] sub:@"手指在按键之间滑过就换键"];
        [self addSwitch:[self addRow:F_HIDEALL k:-1 i:0 title:@"隐藏全部虚拟按钮"] sub:@"只保留设置齿轮和性能叠层"];
    } else if (k_def[k].kind == K_STICK) {
        int i = k - CT_LSTICK;
        [self addNote:[NSString stringWithFormat:@"%@（摇杆）", [pad ctlName:k]]];
        [self addSlider:[self addRow:F_SIZE k:k i:i title:@"大小"] mn:.5 mx:5 st:.1 fmt:@"%.1f×"];
        [self addSlider:[self addRow:F_ALPHA k:k i:i title:@"不透明度"] mn:.05 mx:1 st:.05 fmt:@"%.2f"];
        [self addSlider:[self addRow:F_SENS k:k i:i title:@"灵敏度"] mn:1 mx:3 st:.1 fmt:@"%.1f"];   // kept near the top so it is always on screen; buried under the mode rows in landscape it looked frozen
        [self addSwitch:[self addRow:F_HIDE k:k i:i title:@"隐藏摇杆"] sub:nil];
        [self addSeg:[self addRow:F_JMODE k:k i:i title:@"模式"] items:@[@"固定", @"浮动"]];
        if (![pad field:F_JMODE ofCtl:k side:i]) [self addSwitch:[self addRow:F_JBG k:k i:i title:@"始终显示底盘"] sub:nil];
        if ([pad field:F_JMODE ofCtl:k side:i]) {
            [self addSeg:[self addRow:F_JAREA k:k i:i title:@"浮动范围"] items:@[@"全屏", @"区域"]];
            [self addSlider:[self addRow:F_FSIZE k:k i:i title:@"浮动大小"] mn:.5 mx:2 st:.05 fmt:@"%.2f×"];
            [self addSlider:[self addRow:F_FOP k:k i:i title:@"浮动不透明度"] mn:.05 mx:1 st:.05 fmt:@"%.2f"];
            [self addSlider:[self addRow:F_FDEAD k:k i:i title:@"浮动死区"] mn:0 mx:.5 st:.01 fmt:@"%.2f"];
            if ([pad field:F_JAREA ofCtl:k side:i]) [self addNote:@"拖动绿色虚线框移动区域，右下角手柄调整大小。"];
        } else {
            [self addSwitch:[self addRow:F_TAPMOVE k:k i:i title:@"点击即动"] sub:@"手指按下就朝那个方向走"];
            if ([pad field:F_TAPMOVE ofCtl:k side:i]) [self addSlider:[self addRow:F_TAPFORCE k:k i:i title:@"点击力度"] mn:.1 mx:1 st:.1 fmt:@"%.1f"];
            [self addSlider:[self addRow:F_DEAD k:k i:i title:@"死区"] mn:0 mx:.5 st:.01 fmt:@"%.2f"];
        }
    } else if (k_def[k].kind == K_COMBO) {   // a combo: an ordered sequence, edited like a button
        DmRow *nr = [self addNote:[NSString stringWithFormat:@"顺序：%@（点键加入/移除，按添加顺序执行）", seq_summary(k - CT_C1)]];
        nr.tall = 48; _comboNote = nr.tl;   // two lines: the order can hold eight steps
        [self addSlider:[self addRow:F_SIZE k:k i:0 title:@"大小"] mn:.5 mx:5 st:.1 fmt:@"%.1f×"];
        [self addSlider:[self addRow:F_ALPHA k:k i:0 title:@"不透明度"] mn:.05 mx:1 st:.05 fmt:@"%.2f"];
        [self addSwitch:[self addRow:F_HIDE k:k i:0 title:@"隐藏按钮（即移除组合）"] sub:nil];
        [self addSlider:[self addRow:F_CGAP k:k i:0 title:@"间隔"] mn:0 mx:200 st:10 fmt:@"%.0f ms"];
        [self addSwitch:[self addRow:F_CHOLD k:k i:0 title:@"按住"] sub:@"关闭 = 按顺序连招，打开 = 按住时这些键同时按下"];
        [self addSwitch:[self addRow:F_CHLAST k:k i:0 title:@"按住最后一个按键"] sub:@"与按住全部互斥，松手才松开"];
        [self addSwitch:[self addRow:F_CKEEP k:k i:0 title:@"顺序按住不放"] sub:@"按键按顺序落下并全部保持，直到手指抬起（先瞄准再开火）；与上面两种互斥"];
        [self addSlider:[self addRow:F_CHOLDMS k:k i:0 title:@"每键时长"] mn:40 mx:600 st:20 fmt:@"%.0f ms"];
        [self addSwitch:[self addRow:F_TOGGLE k:k i:0 title:@"点按切换"] sub:@"再点一次才松开，不用一直按住"];
        for (int b = 0; b < 16; b++) [self addSwitch:[self addRow:F_CSTEP k:k i:b title:@(k_btnName[b])] sub:nil];
    } else {
        [self addNote:[NSString stringWithFormat:@"%@（按钮）", [pad ctlName:k]]];
        [self addSlider:[self addRow:F_SIZE k:k i:0 title:@"大小"] mn:.5 mx:5 st:.1 fmt:@"%.1f×"];
        [self addSlider:[self addRow:F_ALPHA k:k i:0 title:@"不透明度"] mn:.05 mx:1 st:.05 fmt:@"%.2f"];
        [self addSwitch:[self addRow:F_HIDE k:k i:0 title:@"隐藏按钮"] sub:nil];
        [self addSwitch:[self addRow:F_TOGGLE k:k i:0 title:@"点按切换"] sub:@"再点一次才松开，不用一直按住"];
        if (k_def[k].kind == K_DPAD) [self addSwitch:[self addRow:F_DPADSTICK k:k i:0 title:@"十字键当摇杆"] sub:@"用左摇杆输出方向"];
    }
    [self addNote:@"拖动移动 · 双指缩放 · 长按复位"];
    [self readRows];
    [self layoutAll];   // lay the fresh rows out immediately; animating them from (0,0) made the card text fly in from the top-left each time a drag re-selected
    [self showSel];
}
- (void)layoutRegions {   // a floating region is only shown while its own stick is selected in region mode
    DmGamepad *pad = _pad; if (!pad) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    for (int i = 0; i < 2; i++) {
        int sk = CT_LSTICK + i;
        BOOL on = _k == sk && [pad field:F_JMODE ofCtl:sk side:i] && [pad field:F_JAREA ofCtl:sk side:i];
        _regv[i].hidden = !on;
        if (!on) continue;
        [pad centerRegionOnStick:i];   // the box is defined around the stick: derive its position every layout so it can never drift off-center
        CGRect r = [pad regionRect:i];
        _regv[i].frame = CGRectMake(0, 0, W, H);
        _regl[i].frame = CGRectMake(0, 0, W, H);   // the path below is in absolute editor coordinates; setting the layer's frame to r as well would draw the box at 2x its origin (the tag and hit-test use 1x, which is why the box looked detached and low)
        _regl[i].path = CGPathCreateWithRoundedRect(r, 18, 18, NULL);
        _regtag[i].frame = CGRectMake(r.origin.x + 6, r.origin.y + 6, 78, 18);
        _regh[i].hidden = NO; _regh[i].frame = CGRectMake(CGRectGetMaxX(r) - 28, CGRectGetMaxY(r) - 28, 28, 28);
    }
}
- (void)layoutAll {   // the tool row, the card and its rows, the region boxes and the selection ring
    DmGamepad *pad = _pad; if (!pad) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    UIEdgeInsets si = pad.safeAreaInsets;
    CGFloat x0 = 12 + fmax(0, si.left - 12), x1 = W - 12 - fmax(0, si.right - 12);
    CGFloat top = 12 + fmax(0, si.top - 12), bh = 36, bw = fmax(240, x1 - x0), by = (bh - 28) / 2;
    _bar.frame = CGRectMake(x0, top, bw, bh);
    // left: the panel switch and the reset; centre: the game's name; right: the two orientations and done
    UIButton *lft[2] = {_bPanel, _bReset}, *rgt[3] = {_bOri[0], _bOri[1], _bDone};
    CGFloat bx = 8, panelRight = 0;
    for (int j = 0; j < 2; j++) {
        [lft[j] sizeToFit]; CGFloat w = fmax(42, lft[j].frame.size.width + 16);
        lft[j].frame = CGRectMake(bx, by, w, 28);
        if (j == 0) panelRight = CGRectGetMaxX(lft[j].frame);
        bx += w + 4; lft[j].hidden = _panelHidden && j != 0;
    }
    CGFloat rw = 0;
    for (int j = 0; j < 3; j++) { [rgt[j] sizeToFit]; CGFloat w = fmax(42, rgt[j].frame.size.width + 16); rgt[j].frame = CGRectMake(0, by, w, 28); rw += w + 4; }
    CGFloat rx = fmax(bx, bw - 8 - rw);
    for (int j = 0; j < 3; j++) { CGFloat w = rgt[j].frame.size.width; rgt[j].frame = CGRectMake(rx, by, w, 28); rx += w + 4; rgt[j].hidden = _panelHidden; }
    [_bName sizeToFit]; CGFloat nw = fmax(42, _bName.frame.size.width);
    _bName.frame = CGRectMake(fmax(bx + 4, fmin(rx - nw - 4, (bw - nw) / 2)), by, nw, 28); _bName.hidden = _panelHidden;
    _bar.hidden = NO;
    if (_panelHidden) _bar.frame = CGRectMake(x0, top, panelRight + 8, bh);
    CGFloat cw = fmin(360, x1 - x0);
    CGFloat total = 24;
    for (DmRow *r in _rows) total += r.tall + 6;
    BOOL has = _k >= 0;
    CGFloat ch = fmin(total + 8, H * (has ? .82 : .80));
    _card.frame = CGRectMake(floor((W - cw) / 2), top + bh + 10, cw, _panelHidden ? 0 : ch);
    _card.hidden = _panelHidden;
    _scroll.frame = _card.bounds; _content.frame = CGRectMake(0, 0, cw, total);
    CGFloat lx = 120, vw = 52, y = 8;
    for (DmRow *r in _rows) {
        if (r.f < 0) r.tl.frame = CGRectMake(16, y, cw - 32, r.tall - 6);   // a note spans the card
        else {
            CGFloat tmax = (r.sl || r.seg) ? lx - 20 : cw - 16 - 60;   // a slider or a segment control starts at lx, a switch at the right edge
            r.tl.frame = CGRectMake(16, y + (r.sub ? 2 : (r.tall - 18) / 2), tmax, 18);
            if (r.sub) r.sub.frame = CGRectMake(16, y + 21, tmax, 14);
        }
        if (r.sl) { r.vl.frame = CGRectMake(cw - 16 - vw, y + (r.tall - 20) / 2, vw, 20); r.sl.frame = CGRectMake(lx, y + (r.tall - 22) / 2, cw - 16 - vw - 8 - lx, 22); }
        if (r.sw) r.sw.frame = CGRectMake(cw - 16 - 51, y + (r.tall - 31) / 2, 51, 31);
        if (r.seg) r.seg.frame = CGRectMake(lx, y + 4, cw - 16 - lx, r.tall - 12);
        y += r.tall + 6;
    }
    _scroll.contentSize = CGSizeMake(cw, total);
    [self layoutRegions];
    [self showSel];
}
- (void)rebuild { [self layoutAll]; }
- (void)refreshOverlay { [self layoutRegions]; [self showSel]; }   // called from the pad's layout on every drag frame: light, and it never touches the card
- (void)layoutSubviews { [super layoutSubviews]; [self layoutAll]; }
- (void)selectionChanged { [self readRows]; [self layoutAll]; [self showSel]; }   // the pad switched orientation: the rows show the other layout's numbers
- (void)selectCtl:(int)k { [self pickCtl:k]; }
- (void)showSel {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _sel.hidden = _k < 0 || !_pad;
    if (_k >= 0 && _pad) _sel.path = CGPathCreateWithRoundedRect(CGRectInset([_pad ctlHalo:_k], -7, -7), 12, 12, NULL);
    [CATransaction commit];
}

// ---- gestures ----
- (int)nodeAt:(CGPoint)p { return _pad ? [_pad ctlAt:p] : -1; }
- (void)onPan:(UIPanGestureRecognizer *)g {
    DmGamepad *pad = _pad; if (!pad) return;
    CGPoint p = [g locationInView:self];
    if (g.state == UIGestureRecognizerStateBegan) {
        _regMode = 0; _regSide = -1;
        for (int i = 0; i < 2 && _regMode == 0; i++) {
            if (_regv[i].hidden) continue;
            if (CGRectContainsPoint(_regh[i].frame, p)) { _regMode = 2; _regSide = i; }
            else {
                CGRect r = [pad regionRect:i], band = CGRectInset(r, -14, -14);
                if (CGRectContainsPoint(band, p) && !CGRectContainsPoint(CGRectInset(r, 14, 14), p)) { _regMode = 1; _regSide = i; }
            }
        }
        if (_regMode) { _last = p; return; }
        int nk = [self nodeAt:p]; if (nk != _k) { _k = nk; [self pickCtl:_k]; }   // only rebuild the card when the selection changes, not on every grab of the already-selected control
        return;
    }
    if (g.state != UIGestureRecognizerStateChanged || !pad) return;
    _dragged = YES;
    if (_regMode && _regSide >= 0) {
        CGFloat dx = p.x - _last.x, dy = p.y - _last.y;
        if (_regMode == 1) {   // the box has no position of its own: moving it moves the stick, and the box re-centers on it in the next layout
            CGPoint c = [pad ctlCenter:CT_LSTICK + _regSide];
            [pad moveCtl:CT_LSTICK + _regSide to:CGPointMake(c.x + dx, c.y + dy)];
        } else {                // resizing grows around the centered stick, so the two never come apart
            CGRect r = [pad regionRect:_regSide];
            CGPoint c = [pad ctlCenter:CT_LSTICK + _regSide];
            CGFloat nw = fmax(60, r.size.width + dx), nh = fmax(60, r.size.height + dy);
            [pad setRegion:_regSide to:CGRectMake(c.x - nw / 2, c.y - nh / 2, nw, nh)];
        }
        _last = p; return;   // setRegion / the pad's layout redraws the box through the editor
    }
    // a floating stick has no fixed place at runtime, but the editor moves its home position and drags the float area along (MelonX)
    if (_k >= 0) {
        [pad moveCtl:_k to:p]; [self showSel];
        if (_k >= CT_LSTICK && _k <= CT_RSTICK) {
            int si = _k - CT_LSTICK;
            if ([pad field:F_JMODE ofCtl:_k side:si]) [pad centerRegionOnStick:si];
        }
    }
}
- (void)onPinch:(UIPinchGestureRecognizer *)g {
    DmGamepad *pad = _pad; if (!pad) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        CGPoint a = [g locationOfTouch:0 inView:self], b = [g locationOfTouch:1 inView:self];
        int k = [self nodeAt:CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2)]; if (k < 0) k = _k;
        if (k != _k) { _k = k; [self pickCtl:k]; }
        _pinch0 = k >= 0 ? [pad field:F_SIZE ofCtl:k side:0] : 1;
    } else if ((g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateEnded) && _k >= 0) {
        [pad setField:F_SIZE ofCtl:_k side:0 to:_pinch0 * g.scale]; [self readRows]; [self showSel];
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) cfg_write();
}
- (void)onHold:(UILongPressGestureRecognizer *)g {   // hold without moving: put the control back where the built-in layout has it
    if (g.state != UIGestureRecognizerStateBegan || _dragged || g.numberOfTouches != 1) return;
    int k = [self nodeAt:[g locationInView:self]]; if (k < 0) return;
    [_pad resetCtl:k]; [self pickCtl:k];
}
- (void)onTap:(UITapGestureRecognizer *)g {
    int k = [self nodeAt:[g locationInView:self]];
    if (k != _k) { _k = k; [self pickCtl:k]; }
}
// ---- the card's controls ----
- (void)setVal:(DmRow *)r to:(CGFloat)v {
    CGFloat q = r.st > 0 ? round(v / r.st) * r.st : v;
    q = fmax(r.mn, fmin(r.mx, q));
    r.sl.value = q; r.vl.text = [NSString stringWithFormat:r.fmt, q];
    [_pad setField:r.f ofCtl:r.k side:r.i to:q];
}
- (void)onSlider:(UISlider *)s { for (DmRow *r in _rows) if (r.sl == s) { [self setVal:r to:s.value]; break; } }
- (void)onSwitch:(UISwitch *)s { for (DmRow *r in _rows) if (r.sw == s) { [_pad setField:r.f ofCtl:r.k side:r.i to:s.on];
        if (r.f == F_CSTEP) { [self readRows]; if (_comboNote && _k >= CT_C1 && _k <= CT_C6) _comboNote.text = [NSString stringWithFormat:@"顺序：%@（点键加入/移除，按添加顺序执行）", seq_summary(_k - CT_C1)]; }
        else [self pickCtl:_k]; return; } }   // a combo's key switches must not rebuild the card: the scroll position would jump on every toggle
- (void)onSeg:(UISegmentedControl *)c { for (DmRow *r in _rows) if (r.seg == c) { [_pad setField:r.f ofCtl:r.k side:r.i to:c.selectedSegmentIndex]; [self pickCtl:_k]; return; } }
- (void)onPanel { _panelHidden = !_panelHidden; [_bPanel setTitle:_panelHidden ? @"显示面板" : @"隐藏面板" forState:UIControlStateNormal]; [self layoutAll]; }   // the label names what the tap does, so the bar reads its own state
- (void)onTapName { }
- (void)onOriP { dm_pad_rotate_to(OR_P); }
- (void)onOriL { dm_pad_rotate_to(OR_L); }
- (void)onDone { [_pad closeEditor]; }
- (void)onResetAll {
    UIViewController *vc = front_vc(); if (!vc) { [_pad resetAll]; return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"重置当前布局？"
        message:@"这个方向上每个按钮和摇杆都会回到默认位置、大小和设置。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) { [_pad resetAll]; [self pickCtl:-1]; }]];
    [vc presentViewController:a animated:YES completion:nil];
}
@end

// ---- The front end's entry points ----
UIView *dm_gamepad_view(CGRect frame) {
    DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v;
}
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; [g_view closeEditor]; });
    pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish();
}
unsigned dm_pad_supported_orientations(void) {
    // 锁定时只收菜单选中的方向（缺省横屏，与旧行为一致）；未锁时横竖都收（设备转动跟手）。
    // 根控制器（ios/app.m 的 S2AGameVC）每次方向变化都会重新问这里；齿轮菜单的「竖屏 / 横屏」走 dm_pad_rotate_to。
    if (g_rotLock) return g_rotTo ? UIInterfaceOrientationMaskPortrait
                                 : (UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight);
    return UIInterfaceOrientationMaskAllButUpsideDown;
}
void dm_pad_rotate_to(int portrait) {
    portrait = portrait ? 1 : 0;
    g_rotTo = portrait; cfg_write();
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = front_vc();
        if (!vc) { LOG("dmpad：转向请求 %s 没有根控制器，忽略", portrait ? "竖屏" : "横屏"); return; }
        [vc setNeedsUpdateOfSupportedInterfaceOrientations];   // 掩码变了：让 UIKit 重新审阅（当前方向不再支持时会自己转）
        UIWindowScene *ws = vc.view.window.windowScene;
        if (!ws) { LOG("dmpad：转向请求 %s 没有窗口场景，忽略", portrait ? "竖屏" : "横屏"); return; }
        UIWindowSceneGeometryPreferencesIOS *prefs =
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:(portrait ? UIInterfaceOrientationMaskPortrait
                                                                                                     : (UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight))];
        [ws requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
            LOG("dmpad：转向请求 %s 未生效：%s", portrait ? "竖屏" : "横屏", error.localizedDescription.UTF8String);
        }];
        LOG("dmpad：请求转向 %s", portrait ? "竖屏" : "横屏");
    });
}

// ---- MelonX 风格虚拟手柄的挂载入口（ios/app.m 调用；旧 vpad 不再 attach） ----
void dm_pad_attach(UIView *root) {
    if (!root) return;
    [DmCheats reload];   // 起局：读包内与 Documents/cheats 的金手指，并把上次拨开的开关恢复（引擎在主线程映射后应用）
    if (g_view) {   // 同一进程重复挂载（重开局）时先摘掉旧的
        [g_view removeFromSuperview];
        g_view = nil;
    }
    UIView *v = dm_gamepad_view(root.bounds);
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:v];
    // 存档里是竖屏：挂载完成、场景稳定后补一次转向（起局掩码先按横屏给，转屏走同一条 dm_pad_rotate_to）
    if (g_cfg_read && g_rotTo) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ dm_pad_rotate_to(g_rotTo); });
    LOG("dmpad：MelonX 虚拟手柄已挂载，%.0fx%.0f（存档按游戏隔离）", root.bounds.size.width, root.bounds.size.height);
}

// ---- 金手指页：一张卡片，每节一个开关，顶部可全部开 / 全部关 ----
@implementation DmCheatPanel {
    __weak DmGamepad *_pad;
    UIScrollView *_scroll;
    UILabel *_title, *_sub;
    NSMutableArray<UISwitch *> *_sws;
    NSMutableArray<NSNumber *> *_idx;
}
- (UIButton *)btn:(NSString *)t action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:.14];
    b.layer.cornerRadius = 9; b.clipsToBounds = YES;
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (instancetype)initWithPad:(DmGamepad *)pad {
    if ((self = [super initWithFrame:CGRectZero])) {
        _pad = pad;
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:.6];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIView *card = [UIView new]; card.tag = 7;
        card.backgroundColor = [UIColor colorWithWhite:.11 alpha:.99];
        card.layer.cornerRadius = 18; card.clipsToBounds = YES;
        [self addSubview:card];
        _title = [UILabel new]; _title.text = @"金手指"; _title.textColor = UIColor.whiteColor; _title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
        _sub = [UILabel new]; _sub.textColor = [UIColor colorWithWhite:1 alpha:.55]; _sub.font = [UIFont systemFontOfSize:11];
        int sw = 0, st = 0;
        for (int i = 0; i < dm_cheats_count(); i++) {
            if (dm_cheats_is_master(i)) continue;
            if (dm_cheats_unswitchable(i) || dm_cheats_stores(i) == 0) st++; else sw++;
        }
        _sub.text = dm_cheats_count() ? [NSString stringWithFormat:@"%d 项可开关 · %d 项代码补丁 · 文件 %@", sw, st, [@(dm_cheats_source()) lastPathComponent]]
                                      : @"没有金手指文件：可用下面的「自定义+」添加，或把 txt 放进「文件」App → 此 App → cheats";
        card.tag = 7;
        [card addSubview:_title]; [card addSubview:_sub];
        // 五个按钮：添加自定义 / 导入txt / 全部开启 / 全部关闭 / 完成
        UIButton *ba = [self btn:@"自定义+" action:@selector(addCustom)], *bb = [self btn:@"导入txt" action:@selector(importTxt)];
        UIButton *a1 = [self btn:@"全部开启" action:@selector(allOn)], *a2 = [self btn:@"全部关闭" action:@selector(allOff)], *a3 = [self btn:@"完成" action:@selector(done)];
        ba.tag = 74; bb.tag = 75; a1.tag = 71; a2.tag = 72; a3.tag = 73;
        for (UIButton *b in @[ba, bb, a1, a2, a3]) [card addSubview:b];
        _scroll = [UIScrollView new]; _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite; [card addSubview:_scroll];
        _sws = [NSMutableArray array]; _idx = [NSMutableArray array];
        for (int i = 0; i < dm_cheats_count(); i++) {
            if (dm_cheats_is_master(i)) continue;   // the master code is applied with the first switch, no row of its own
            int alw = dm_cheats_unswitchable(i) || dm_cheats_stores(i) == 0;   // 原文件里这一节只改游戏代码、没有开关变量：列出来但不能开关
            int nb = alw ? 0 : dm_cheats_needs_bake(i);      // 1 = 改的是游戏代码页（iOS 上签名只读），运行期开不了
            UILabel *l = [UILabel new];
            l.text = nb == 1 ? [@(dm_cheats_name(i)) stringByAppendingString:@"　（本包未烘金手指）"] : @(dm_cheats_name(i));   // 不可切换的那节，警告文字放在开关旁边（⚠︎ 标签）
            l.textColor = (alw || nb == 1) ? [UIColor colorWithWhite:1 alpha:.4] : UIColor.whiteColor;
            l.font = [UIFont systemFontOfSize:13]; l.numberOfLines = 2; l.tag = 1000 + i;
            unsigned hk = dm_cheats_hotkey(i);
            if (alw || hk) {   // 开关旁的提示：代码补丁类不能运行期切换；快捷键类是按住才生效
                UILabel *w = [UILabel new]; w.tag = 3000 + i;
                w.text = alw ? @"⚠︎ 运行期不能开关" : [NSString stringWithFormat:@"或按住 %@", [DmCheats hotkeyName:hk]];
                w.textColor = [UIColor colorWithWhite:1 alpha:.7]; w.font = [UIFont systemFontOfSize:11];
                [_scroll addSubview:w];
            }
            UISwitch *s = [UISwitch new]; s.on = alw ? NO : dm_cheats_on(i) != 0; s.tag = i; s.enabled = !alw && nb != 1;   // 快捷键类：开关 = 启用这个快捷键
            [s addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
            [_scroll addSubview:l]; [_scroll addSubview:s];
            [_sws addObject:s]; [_idx addObject:@(i)];
        }
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    UIView *card = [self viewWithTag:7];
    CGFloat w = fmin(480, b.size.width - 28);
    int rows = (int)_sws.count;
    CGFloat h = fmin(b.size.height - 28, 112 + rows * 42 + 10);
    card.frame = CGRectMake(floor((b.size.width - w) / 2), floor((b.size.height - h) / 2), w, h);
    _title.frame = CGRectMake(18, 12, w - 36, 24);
    _sub.frame = CGRectMake(18, 36, w - 36, 14);
    CGFloat bw = (w - 36 - 4 * 8) / 5;
    UIButton *a1 = [card viewWithTag:71], *a2 = [card viewWithTag:72], *a3 = [card viewWithTag:73];
    UIButton *ba = [card viewWithTag:74], *bb = [card viewWithTag:75];
    CGFloat y = 56;
    ba.frame = CGRectMake(18, y, bw, 30); bb.frame = CGRectMake(18 + (bw + 8), y, bw, 30);
    a1.frame = CGRectMake(18 + 2 * (bw + 8), y, bw, 30); a2.frame = CGRectMake(18 + 3 * (bw + 8), y, bw, 30); a3.frame = CGRectMake(18 + 4 * (bw + 8), y, bw, 30);
    _scroll.frame = CGRectMake(6, y + 38, w - 12, h - (y + 38) - 8);
    CGFloat ry = 0;
    for (NSUInteger k = 0; k < _sws.count; k++) {
        int i = _idx[k].intValue;
        UILabel *l = [card viewWithTag:1000 + i];
        UILabel *wn = [card viewWithTag:3000 + i];
        CGFloat ww = wn ? 152 : 0;
        l.frame = CGRectMake(12, ry + 4, _scroll.bounds.size.width - 24 - 64 - ww, 34);
        if (wn) wn.frame = CGRectMake(_scroll.bounds.size.width - 12 - 51 - ww, ry + 9, ww, 22);
        _sws[k].frame = CGRectMake(_scroll.bounds.size.width - 12 - 51, ry + 7, 51, 31);
        ry += 42;
    }
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, ry + 4);
}
- (void)toggled:(UISwitch *)s {
    dm_cheats_set(s.tag, s.isOn ? 1 : 0);
    cheat_save();
}
- (void)addCustom { [_pad cheatAddCustom]; }
- (void)importTxt { [_pad cheatImportTxt]; }
- (void)allOn {
    dm_cheats_set_all(1); cheat_save();
    for (NSUInteger k = 0; k < _sws.count; k++) {   // 代码补丁类的行拨不动，保持关
        int i = _idx[k].intValue; _sws[k].on = (dm_cheats_unswitchable(i) || dm_cheats_stores(i) == 0) ? NO : dm_cheats_on(i) != 0;
    }
}
- (void)allOff { dm_cheats_set_all(0); cheat_save(); for (NSUInteger k = 0; k < _sws.count; k++) _sws[k].on = NO; }
- (void)done { [_pad closeCheats]; }
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {   // a tap outside the card closes the page
    for (UITouch *t in ts) if (!CGRectContainsPoint([self viewWithTag:7].frame, [t locationInView:self])) { [_pad closeCheats]; return; }
}
@end

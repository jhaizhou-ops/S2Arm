// 见 DmSettings.h：齿轮菜单与启动器共用的一份设置。
// 存档就在 DmPadPref 这个字典里（齿轮菜单的 cfg_write 写的也是它），所以两边永远不会出现两套值；
// 改完发 DmCfgChanged，活着的齿轮菜单会重读并立刻生效。
#import "DmSettings.h"
#include <stdlib.h>
#include <string.h>
#include "dm_input.h"   // dm_haptics_set_enabled / _strength / _buttons（ios/dmpad_haptics.m 实现）
#import "dmpad_compat.h"   // DmCfgDefaults()：按游戏隔离的 UserDefaults（移植改动）

// nvn_mtl.m 的运行时开关，和 DmGamepad.m 里一样就地声明
void mtl_fps_override(int fps);   // 0 = 跟随游戏配置，30 / 60 / 120 = 玩家选的上限
void mtl_present_fill(int mode);  // 0 保持比例 / 1 拉伸 / 2 裁切
extern void front_game_frame_apply(void);   // front_ios.m：按当前「画面自定义」重算画面框

NSString *const DmCfgChanged = @"DmCfgChanged";

static NSString *const kPref = @"DmPadPref";   // 与 DmGamepad.m 的 k_pref_key 同名同义

static NSMutableDictionary *pref_mut(void) {
    NSMutableDictionary *p = [[DmCfgDefaults() dictionaryForKey:kPref] mutableCopy];
    return p ?: [NSMutableDictionary dictionary];
}

static id pref_get(NSString *key) {
    NSDictionary *p = [DmCfgDefaults() dictionaryForKey:kPref];
    return [p isKindOfClass:NSDictionary.class] ? p[key] : nil;
}

static void pref_put(NSString *key, id value) {
    NSMutableDictionary *p = pref_mut();
    if (value) p[key] = value; else [p removeObjectForKey:key];
    [DmCfgDefaults() setObject:p forKey:kPref];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:DmCfgChanged object:key]; });
}

int DmCfgGetInt(NSString *key, int dflt) {
    id v = pref_get(key);
    return [v isKindOfClass:NSNumber.class] ? (int)[v integerValue] : dflt;
}
void DmCfgSetInt(NSString *key, int value) { pref_put(key, @(value)); }

BOOL DmCfgGetBool(NSString *key, BOOL dflt) {
    id v = pref_get(key);
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : dflt;
}
void DmCfgSetBool(NSString *key, BOOL value) { pref_put(key, @(value ? 1 : 0)); }

NSString *DmCfgGetString(NSString *key, NSString *dflt) {
    id v = pref_get(key);
    return [v isKindOfClass:NSString.class] ? v : dflt;
}
void DmCfgSetString(NSString *key, NSString *value) { pref_put(key, value); }

NSInteger DmCfgFpsCap(void) {
    int v = DmCfgGetInt(@"fpsmode", 0);
    return (v == 30 || v == 60 || v == 120) ? v : 0;
}
void DmCfgSetFpsCap(NSInteger fps) {
    if (fps != 30 && fps != 60 && fps != 120) fps = 0;
    DmCfgSetInt(@"fpsmode", (int)fps);
    mtl_fps_override((int)fps);   // 0 = 跟随游戏配置
}

BOOL DmCfgShowFps(void) { return DmCfgGetBool(@"fps", NO); }   // 默认关闭（齿轮菜单仍可选开）
void DmCfgSetShowFps(BOOL on) { DmCfgSetBool(@"fps", on); }

NSInteger DmCfgFill(void) {
    int v = DmCfgGetInt(@"fill", 0);
    return (v >= 0 && v <= 2) ? v : 0;
}
void DmCfgSetFill(NSInteger fill) {
    if (fill < 0 || fill > 2) fill = 0;
    DmCfgSetInt(@"fill", (int)fill);
    mtl_present_fill((int)fill);   // 手柄还在时它会在 DmCfgChanged 里按方向重算（解锁比例时强制拉伸）
    front_game_frame_apply();
}

NSString *DmCfgTheme(void) { return DmCfgGetString(@"theme", @"classic"); }
void DmCfgSetTheme(NSString *theme) { DmCfgSetString(@"theme", theme); }

NSInteger DmCfgRumbleLevel(void) {
    int v = DmCfgGetInt(@"rumblelv", 1);
    return (v >= 0 && v <= 4) ? v : 1;
}
void DmCfgSetRumbleLevel(NSInteger lv) {
    if (lv < 0 || lv > 4) lv = 1;
    DmCfgSetInt(@"rumblelv", (int)lv);
    dm_haptics_set_strength((int)lv);
    s2a_rumble_set_level((int)lv);   // 游戏本体震动（实体手柄 / 手机马达 / NS2 Pro）按同一档位缩放
    if (lv > 0 && !DmCfgRumbleOn()) DmCfgSetRumbleOn(YES);
}

BOOL DmCfgRumbleOn(void) { return DmCfgGetBool(@"rumble", YES); }
void DmCfgSetRumbleOn(BOOL on) {
    DmCfgSetBool(@"rumble", on);
    dm_haptics_set_enabled(on ? 1 : 0);
    s2a_rumble_set_enabled(on ? 1 : 0);
}

BOOL DmCfgButtonHaptics(void) { return DmCfgGetBool(@"btnhap", YES); }
void DmCfgSetButtonHaptics(BOOL on) { DmCfgSetBool(@"btnhap", on); dm_haptics_set_buttons(on ? 1 : 0); }

NSInteger DmCfgOverlay(void) { return DmCfgGetBool(@"fps", NO) ? (DmCfgGetBool(@"ram", NO) ? 1 : 0) : 2; }
void DmCfgSetOverlay(NSInteger ov) {
    switch (ov) {
        case 0: DmCfgSetBool(@"fps", YES); DmCfgSetBool(@"ram", NO); break;    // 只显示 FPS
        case 1: DmCfgSetBool(@"fps", YES); DmCfgSetBool(@"ram", YES); break;   // FPS + RAM
        default: DmCfgSetBool(@"fps", NO); DmCfgSetBool(@"ram", NO); break;    // 关闭
    }
}

// 简体中文优先：这是移植壳，玩家要的就是游戏里那份中文（Hades 的 NACP 支持 zh-Hans/zh-CN）。
// hle_oe.c / dm_i18n.c 认 DM_LANG，游戏启动时读一次，所以改完要下一次进游戏才全生效。
static const struct { const char *tag, *name; } k_langs[] = {
    {"zh-Hans", "简体中文"}, {"zh-Hant", "繁体中文"}, {"en-US", "英语"}, {"ja", "日语"},
    {"fr", "法语"}, {"de", "德语"}, {"it", "意大利语"}, {"es", "西班牙语"},
    {"pt-BR", "葡萄牙语(巴西)"}, {"ru", "俄语"}, {"ko", "韩语"}, {"nl", "荷兰语"}, {"ar", "阿拉伯语"},
};
NSArray<NSString *> *DmCfgLanguageTags(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (unsigned i = 0; i < sizeof k_langs / sizeof k_langs[0]; i++) [a addObject:[NSString stringWithUTF8String:k_langs[i].tag]];
    return a;
}
NSArray<NSString *> *DmCfgLanguageNames(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (unsigned i = 0; i < sizeof k_langs / sizeof k_langs[0]; i++) [a addObject:[NSString stringWithUTF8String:k_langs[i].name]];
    return a;
}
NSString *DmCfgLanguage(void) {
    NSString *t = DmCfgGetString(@"lang", nil);
    if (t.length) return t;
    return @"zh-Hans";   // 默认简体中文
}
void DmCfgSetLanguage(NSString *tag) {
    DmCfgSetString(@"lang", tag);
    DmCfgApplyLanguageEnv();
    [DmCfgDefaults() setObject:tag forKey:@"launcher.DM_LANG"];   // 启动页那份也改成同一个值：下次进来它显示、应用的就是这里选的
}
void DmCfgApplyLanguageEnv(void) {
    NSString *tag = DmCfgLanguage();
    // 玩家在启动器里选过就覆盖一切；没选过时只在环境里没有 DM_LANG（env.txt / 出包注入）时补上默认中文
    int forced = DmCfgGetString(@"lang", nil) != nil;
    if (!forced && getenv("DM_LANG")) return;
    setenv("DM_LANG", tag.UTF8String, 1);
}

BOOL DmCfgShowLauncher(void) { return DmCfgGetBool(@"showLauncher", YES); }
void DmCfgSetShowLauncher(BOOL on) { DmCfgSetBool(@"showLauncher", on); }

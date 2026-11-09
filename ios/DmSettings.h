// 设置的单一真值层：UserDefaults 里的两份存档（手柄布局 DmPadCtl / 开关偏好 DmPadPref）
// 齿轮菜单与启动器读写的都是同一批键，谁改完都会发 DmCfgChanged 通知，另一侧立即重读，
// 因此「启动器里选的帧率」和「游戏里齿轮菜单里的帧率」永远是同一个值。
// 环境变量（DM_LANG 等）只在启动时按存档写一次，运行期不再当第二份真值。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 任意一侧改过设置后发出；在主的 run loop 上投递。
extern NSString *const DmCfgChanged;

/// 通用读写（int / bool / string），键名与齿轮菜单的存档一致。
int         DmCfgGetInt(NSString *key, int dflt);
void        DmCfgSetInt(NSString *key, int value);
BOOL        DmCfgGetBool(NSString *key, BOOL dflt);
void        DmCfgSetBool(NSString *key, BOOL value);
NSString   *DmCfgGetString(NSString *key, NSString *dflt);
void        DmCfgSetString(NSString *key, NSString *value);

/// 立即生效的封装：写存档 + 调运行时 setter + 广播。
NSInteger   DmCfgFpsCap(void);                 // 0 跟随配置 / 30 / 60 / 120
void        DmCfgSetFpsCap(NSInteger fps);
BOOL        DmCfgShowFps(void);                // 左上角 FPS 叠层，默认关闭
void        DmCfgSetShowFps(BOOL on);
NSInteger   DmCfgFill(void);                   // 0 保持比例 / 1 拉伸 / 2 裁切
void        DmCfgSetFill(NSInteger fill);
NSString   *DmCfgTheme(void);
void        DmCfgSetTheme(NSString *theme);
NSInteger   DmCfgRumbleLevel(void);            // 0 关 ~ 4 最强
void        DmCfgSetRumbleLevel(NSInteger lv);
BOOL        DmCfgRumbleOn(void);
void        DmCfgSetRumbleOn(BOOL on);
BOOL        DmCfgButtonHaptics(void);
void        DmCfgSetButtonHaptics(BOOL on);
NSInteger   DmCfgOverlay(void);                // 性能叠层：0 FPS / 1 FPS+RAM / 2 关（沿用齿轮菜单的取值）
void        DmCfgSetOverlay(NSInteger ov);

/// 游戏语言：存档键 lang，缺省简体中文；同时写回 DM_LANG 供宿主读取。
NSString   *DmCfgLanguage(void);
void        DmCfgSetLanguage(NSString *tag);   // 例：zh-Hans / zh-Hant / en-US / ja
NSArray<NSString *> *DmCfgLanguageTags(void);  // 与 DmCfgLanguageNames() 一一对应
NSArray<NSString *> *DmCfgLanguageNames(void); // 中文名，给启动器列表用

/// 启动时是否先显示启动器（默认显示；关掉后直接进游戏，齿轮菜单仍可随时打开）。
BOOL        DmCfgShowLauncher(void);
void        DmCfgSetShowLauncher(BOOL on);

/// 启动器/齿轮菜单之外的人在改设置前调用：把存档里的语言落进环境变量。
void        DmCfgApplyLanguageEnv(void);

NS_ASSUME_NONNULL_END

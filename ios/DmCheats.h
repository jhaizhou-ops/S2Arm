// The 金手指 list the launcher's page and the in-game gear page share (the host's engine in dm/host/hle_cheats.c does the actual memory writes).
// Everything is by section name, so a saved choice survives a changed cheat file; the switchable ones are applied the moment the game can take the write
// (dm_cheats_set records the intent even before main is mapped — the host applies it at its first present).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DmCheatItem : NSObject
@property (nonatomic) NSInteger index;         // the engine's index, what setEnabled takes
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL on;
@property (nonatomic) BOOL master;             // {主代码} block: applied with any switch, never shown as a switch of its own
@property (nonatomic) BOOL switchable;
@property (nonatomic) unsigned key;        // 原文件里的按键触发掩码（DM_BTN_* 位序），0 = 常态开关
@property (nonatomic, copy) NSString *hint;   // 给人看的说明：「按住 L3+R3 生效」/「代码补丁类 · 运行期不能开关」         // NO = the section only patches game code: iOS cannot write the guest's signed code pages, so it cannot be switched at run time
@end

@interface DmCheats : NSObject
+ (void)reload;                                 // re-read the built-in file and Documents/cheats/*.txt
+ (NSArray<DmCheatItem *> *)items;
+ (void)applySaved;                             // turn on what the player switched on earlier (the launcher's choices land here)
+ (void)saveStates;                             // 把当前的开态按分节名记进 UserDefaults（两个页面共用一份）
+ (void)setEnabled:(NSInteger)index on:(BOOL)on;
// A single number cheat: name + address + value + width (1 / 2 / 4 / 8 bytes). An address that starts with @ or ! is an absolute guest address,
// otherwise it is main + offset (the Atmosphere codes the cheat sites publish). Returns nil on success, the reason to show otherwise.
+ (nullable NSString *)addCustomWithName:(NSString *)name address:(NSString *)address value:(NSString *)value width:(NSInteger)bytes;
+ (nullable NSString *)importFileAtURL:(NSURL *)url;   // copy a cheat .txt into Documents/cheats and merge it in
+ (NSString *)userDirectory;
+ (NSString *)hotkeyName:(unsigned)mask;               // 掩码 → 中文按键名（L3+R3 等）                    // Documents/cheats, also reachable from the Files app
@end

NS_ASSUME_NONNULL_END

// 见 DmCheats.h：齿轮菜单的金手指页与引擎状态都在这里（引擎在 ios/dmpad_cheats.m）。
// 玩家拨过的开关按「分节名」记进 UserDefaults，金手指文件增删分节后仍然认得。
#import "DmCheats.h"
#include "hle.h"
#include <stdlib.h>
#include <string.h>

static NSString *const kCheatsOnKey = @"DmCheatsOn";

@implementation DmCheatItem
@end

@implementation DmCheats
+ (NSString *)userDirectory {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *d = [doc stringByAppendingPathComponent:@"cheats"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
+ (void)ensureEnv {   // 包内金手指与玩家的 Documents/cheats 一并交给引擎
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!getenv("DM_CHEATS_DIR")) {
        NSString *res = [[NSBundle mainBundle] resourcePath];
        for (NSString *sub in @[@"dm/cheats", @"cheats"]) {
            NSString *b = [res stringByAppendingPathComponent:sub];
            if ([fm fileExistsAtPath:b]) { setenv("DM_CHEATS_DIR", b.fileSystemRepresentation, 1); break; }
        }
    }
    if (!getenv("DM_CHEATS_USER")) setenv("DM_CHEATS_USER", [self userDirectory].fileSystemRepresentation, 1);
}
static const struct { unsigned bit; const char *name; } kKeys[] = {
    {1u << 0, "B"}, {1u << 1, "A"}, {1u << 2, "X"}, {1u << 3, "Y"},
    {1u << 4, "L3"}, {1u << 5, "R3"}, {1u << 6, "L"}, {1u << 7, "R"},
    {1u << 8, "ZL"}, {1u << 9, "ZR"}, {1u << 10, "+"}, {1u << 11, "−"},
    {1u << 12, "方向←"}, {1u << 13, "方向↑"}, {1u << 14, "方向→"}, {1u << 15, "方向↓"},
};
+ (NSString *)hotkeyName:(unsigned)m {
    if (!m) return @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (unsigned i = 0; i < sizeof kKeys / sizeof kKeys[0]; i++) if (m & kKeys[i].bit) [parts addObject:@(kKeys[i].name)];
    return parts.count ? [parts componentsJoinedByString:@"+"] : [NSString stringWithFormat:@"0x%x", m];
}
+ (void)reload {
    [self ensureEnv];
    dm_cheats_reload();
    [self applySaved];   // 重读会丢掉内存里的状态，把玩家先前选开的重新写回去
}
+ (NSArray<DmCheatItem *> *)items {
    [self ensureEnv];
    if (dm_cheats_count() == 0) dm_cheats_reload();
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < dm_cheats_count(); i++) {
        DmCheatItem *it = [DmCheatItem new];
        it.index = i; it.name = @(dm_cheats_name(i)); it.on = dm_cheats_on(i) != 0;
        it.master = dm_cheats_is_master(i) != 0;
        it.switchable = !dm_cheats_unswitchable(i) && dm_cheats_stores(i) > 0;
        it.key = dm_cheats_hotkey(i);
        it.hint = it.key ? @"按键条件节 · 打开即生效（本引擎按开关常开）"
                         : (it.switchable ? @"" : @"代码补丁类 · 运行期不能开关");
        [out addObject:it];
    }
    return out;
}
+ (NSArray<NSString *> *)savedNames {
    NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:kCheatsOnKey];
    return [a isKindOfClass:NSArray.class] ? a : @[];
}
+ (void)saveStates {
    NSMutableArray *on = [NSMutableArray array];
    for (int i = 0; i < dm_cheats_count(); i++)
        if (!dm_cheats_is_master(i) && dm_cheats_on(i) && !dm_cheats_unswitchable(i) && dm_cheats_stores(i) > 0) [on addObject:@(dm_cheats_name(i))];
    [NSUserDefaults.standardUserDefaults setObject:on forKey:kCheatsOnKey];
}
+ (void)applySaved {   // 按分节名恢复：金手指文件在两次运行之间可能增删分节
    NSSet *saved = [NSSet setWithArray:[self savedNames]];
    for (int i = 0; i < dm_cheats_count(); i++) {
        if (dm_cheats_is_master(i) || dm_cheats_unswitchable(i) || dm_cheats_stores(i) == 0) continue;
        if ([saved containsObject:@(dm_cheats_name(i))]) dm_cheats_set(i, 1);
    }
}
+ (void)setEnabled:(NSInteger)i on:(BOOL)on {
    if (i < 0 || i >= dm_cheats_count()) return;
    dm_cheats_set((int)i, on ? 1 : 0);
    [self saveStates];
}
+ (NSString *)addCustomWithName:(NSString *)name address:(NSString *)address value:(NSString *)value width:(NSInteger)bytes {
    NSString *nm = name.length ? name : @"我的金手指";
    NSString *ad = [address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *vv = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (bytes != 1 && bytes != 2 && bytes != 4 && bytes != 8) bytes = 4;
    if (!ad.length || !vv.length) return @"地址和值都要填（十六进制）。";
    BOOL abs = [ad hasPrefix:@"@"] || [ad hasPrefix:@"!"] || [ad hasPrefix:@"＊"] || [ad hasPrefix:@"*"];
    if (abs) ad = [ad substringFromIndex:1];
    ad = [ad stringByReplacingOccurrencesOfString:@"0x" withString:@""];
    unsigned long long a = strtoull(ad.UTF8String, NULL, 16), v = strtoull(vv.UTF8String, NULL, 16);
    if (a == 0) return @"地址没解析出十六进制数字。";
    // Atmosphere 的布局：第 3 个十六进制位是地址类型（0 配 E = main+偏移，1 = 绝对地址），第 2 位是宽度
    NSString *op = [NSString stringWithFormat:@"0%ld%c%c0000", (long)bytes, abs ? '1' : '0', abs ? '0' : 'E'];
    NSString *body = bytes == 8
        ? [NSString stringWithFormat:@"%@ %016llx %08x %08x\n", op, a, (unsigned)(v >> 32), (unsigned)(v & 0xFFFFFFFF)]
        : [NSString stringWithFormat:@"%@ %016llx %08x\n", op, a, (unsigned)(v & 0xFFFFFFFF)];
    NSString *path = [[self userDirectory] stringByAppendingPathComponent:@"custom.txt"];
    NSString *block = [NSString stringWithFormat:@"\n[%@]\n%@", nm, body];
    NSData *dat = [block dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (h) { @try { [h seekToEndOfFile]; [h writeData:dat]; } @finally { [h closeFile]; } }
    else if (![dat writeToFile:path atomically:YES]) return @"写不进 Documents/cheats/custom.txt。";
    [self reload];
    return nil;
}
+ (NSString *)importFileAtURL:(NSURL *)u {
    if (!u) return @"没选文件。";
    BOOL scoped = [u startAccessingSecurityScopedResource];
    NSString *dir = [self userDirectory];
    NSString *base = u.lastPathComponent.length ? u.lastPathComponent : @"imported.txt";
    NSString *dst = [dir stringByAppendingPathComponent:base];
    int n = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:dst])
        dst = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d.txt", base.stringByDeletingPathExtension, n++]];
    NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:&err];
    if (scoped) [u stopAccessingSecurityScopedResource];
    if (!ok) return err.localizedDescription ?: @"复制失败。";
    [self reload];
    return nil;
}
@end

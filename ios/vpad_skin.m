#import "vpad_skin.h"
#import "vpad_data.h"

static BOOL skin_id_ok(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > 64) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789._-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

@implementation S2AVPadSkin {
    NSDictionary *_buttons;   // 清单 buttons 原样：{键 id: {"normal": 文件名, "pressed": 文件名?}}
    NSDictionary *_stick;     // 清单 stick 原样（可 nil）
}
+ (NSArray<S2AVPadSkin *> *)skinsForGame:(NSString *)titleID {
    NSURL *root = [S2AVPadData urlForRelativePath:@"skins"];
    if (!root || !titleID.length) return @[];
    NSArray<NSURL *> *dirs = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil];
    NSMutableArray<S2AVPadSkin *> *result = [NSMutableArray array];
    for (NSURL *dir in dirs) {
        NSData *data = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"skin.json"]];
        id doc = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![doc isKindOfClass:NSDictionary.class]) continue;
        if (![doc[@"schemaVersion"] isKindOfClass:NSNumber.class] || [doc[@"schemaVersion"] intValue] != 1) continue;
        if (!skin_id_ok(doc[@"id"]) || ![doc[@"name"] isKindOfClass:NSString.class] || ![doc[@"name"] length]) continue;
        if (![doc[@"games"] isKindOfClass:NSArray.class] || ![doc[@"games"] containsObject:titleID]) continue;
        if (![doc[@"buttons"] isKindOfClass:NSDictionary.class]) continue;
        S2AVPadSkin *skin = [self new];
        skin->_identifier = [doc[@"id"] copy]; skin->_name = [doc[@"name"] copy];
        skin->_games = [doc[@"games"] copy]; skin->_directory = dir; skin->_manifest = [doc copy];
        skin->_buttons = doc[@"buttons"]; skin->_stick = [doc[@"stick"] isKindOfClass:NSDictionary.class] ? doc[@"stick"] : nil;
        [result addObject:skin];
    }
    [result sortUsingComparator:^NSComparisonResult(S2AVPadSkin *a, S2AVPadSkin *b) { return [a.identifier compare:b.identifier]; }];
    return result;
}
- (NSURL *)fileURL:(id)name {
    if (![name isKindOfClass:NSString.class] || ![name length] || [name containsString:@"/"]) return nil;
    NSURL *url = [_directory URLByAppendingPathComponent:name];
    return [NSFileManager.defaultManager fileExistsAtPath:url.path] ? url : nil;
}
- (NSURL *)imageURLForButton:(NSString *)buttonID pressed:(BOOL)pressed {
    NSDictionary *entry = [_buttons[buttonID] isKindOfClass:NSDictionary.class] ? _buttons[buttonID] : nil;
    return [self fileURL:entry[pressed ? @"pressed" : @"normal"]];
}
- (NSURL *)stickBaseURL { return [self fileURL:_stick[@"base"]]; }
- (NSURL *)stickKnobURL { return [self fileURL:_stick[@"knob"]]; }
+ (NSUserDefaults *)defaultsForGame:(NSString *)titleID {
    return titleID.length ? [[NSUserDefaults alloc] initWithSuiteName:[@"S2AGame." stringByAppendingString:titleID]] : nil;
}
+ (NSString *)selectedSkinIDForGame:(NSString *)titleID {
    NSString *value = [[self defaultsForGame:titleID] stringForKey:@"S2AVPadSkin"];
    if (!value.length) return nil;
    for (S2AVPadSkin *skin in [self skinsForGame:titleID]) if ([skin.identifier isEqualToString:value]) return value;
    return nil;   // 选过的包不在了（数据包更新删了它）：回内置描线，不留悬空选择
}
+ (void)selectSkinID:(NSString *)skinID forGame:(NSString *)titleID {
    NSUserDefaults *defaults = [self defaultsForGame:titleID];
    if (skinID.length) [defaults setObject:skinID forKey:@"S2AVPadSkin"];
    else [defaults removeObjectForKey:@"S2AVPadSkin"];
}
@end

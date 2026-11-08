#import "cpatch_model.h"

NSString *const S2ACPatchDefaultsKey = @"S2ACommunityPatches";
NSString *const S2ACPatchNotice = @"宽屏和 60 帧会提高系统负载和耗电，换取更好的游玩体验，低配设备请谨慎选择";

@implementation S2ACPatchItem
- (BOOL)followsFps60 { return [self.ident hasPrefix:@"fps:"]; }
@end
@implementation S2ACPatchGroup
@end

static BOOL has(NSString *s, NSString *re) { return [s rangeOfString:re options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound; }
static NSString *cap(NSString *s, NSString *re, NSUInteger i) {
    NSTextCheckingResult *m = [[NSRegularExpression regularExpressionWithPattern:re options:NSRegularExpressionCaseInsensitive error:nil] firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m && [m rangeAtIndex:i].location != NSNotFound ? [s substringWithRange:[m rangeAtIndex:i]] : nil;
}

NSString *S2ACPatchClassify(NSString *name, NSString *category, NSString *ident) {
    if (has(name, @"\\d+\\s*fps|\\bfps\\b|frame\\s*rate|present interval|swap interval")) return @"fps";
    if (has(name, @"ultra\\s*wide|widescreen|aspect|\\b(21|32):9\\b|16:10|\\b\\d{3,4}\\s*x\\s*\\d{3,4}\\b|docked")) return @"widescreen";
    if (has(name, @"depth of field|\\bdof\\b|resolution|\\blod|blur|\\baa\\b|anti-?alias|shadow|outline|bloom|effect|graphic|texture|\\bfog\\b")) return @"gfx";
    if (has(category, @"ultra\\s*wide|widescreen")) return @"widescreen";
    if (has(category, @"fps")) return @"fps";
    if (category.length) return @"gfx";
    return [ident hasPrefix:@"widescreen:"] ? @"widescreen" : [ident hasPrefix:@"fps:"] ? @"fps" : @"gfx";
}

NSString *S2ACPatchTitle(NSString *name, NSString *group) {
    NSString *fps = cap(name, @"(\\d+)\\s*fps", 1);
    if (has(name, @"split\\s*screen") && fps) return [NSString stringWithFormat:@"强制 %@ 帧（分屏）", fps];
    if (has(name, @"present interval|swap interval")) return [NSString stringWithFormat:@"%@ 帧（交换间隔 2→1）", cap(name, @"->\\s*(\\d+)\\s*fps", 1) ?: @"60"];
    if (has(name, @"enabler") && fps) return [NSString stringWithFormat:@"%@ 帧（启用钩子）", fps];
    if (has(name, @"\\d+\\s*fps in game") && has(name, @"cutscene")) return [NSString stringWithFormat:@"游戏中 %@ 帧（过场 %@ 帧）", fps, cap(name, @"(\\d+)\\s*fps\\s*cutscene", 1) ?: @"30"];
    if (fps) return [NSString stringWithFormat:@"%@ 帧", fps];
    NSString *w = cap(name, @"\\b(\\d{3,4})\\s*x\\s*(\\d{3,4})\\b", 1), *h = cap(name, @"\\b(\\d{3,4})\\s*x\\s*(\\d{3,4})\\b", 2);
    if (w) return [NSString stringWithFormat:@"分辨率 %@×%@%@", w, h, has(name, @"docked") ? @"（主机模式）" : has(name, @"handheld") ? @"（掌机模式）" : @""];
    if (has(name, @"depth of field|\\bdof\\b")) return has(name, @"remov|disabl") ? @"去景深" : has(name, @"improv") ? @"改进景深" : @"景深调整";
    if (has(name, @"dynamic resolution") && has(name, @"disabl|remov")) return @"关动态分辨率";
    if (has(name, @"resolution scaling") && has(name, @"disabl|remov")) return @"关分辨率缩放（固定分辨率）";
    if (has(name, @"lod\\s*bias")) return @"改进 LOD 偏移";
    if (has(name, @"motion blur") && has(name, @"remov|disabl")) return @"去动态模糊";
    if (has(name, @"outline") && has(name, @"remov|disabl")) return @"去角色描边";
    if (has(name, @"shadow resolution") && has(name, @"increas|improv")) return @"提高阴影分辨率";
    if (has(name, @"cutscene") && has(name, @"effect") && has(name, @"remov|disabl")) return @"去过场特效";
    NSString *ratio = cap(name, @"\\b(21:9|32:9|16:10)\\b", 1);
    if (ratio) return [@"宽屏 " stringByAppendingString:ratio];
    if (has(name, @"ultra\\s*wide|widescreen|aspect")) return @"超宽屏";
    if (has(name, @"\\bgraphics?\\b")) return @"画面增强";
    return [group isEqual:@"widescreen"] ? @"宽屏补丁" : [group isEqual:@"fps"] ? @"帧率补丁" : @"画面补丁";
}

NSArray<S2ACPatchGroup *> *S2ACPatchGroupsFromTSV(NSString *text) {
    static NSString *const kinds[] = {@"widescreen", @"fps", @"gfx"}, *const titles[] = {@"宽屏", @"60 帧", @"画面"};
    NSMutableArray<S2ACPatchItem *> *byKind[3] = {[NSMutableArray new], [NSMutableArray new], [NSMutableArray new]};
    NSMutableDictionary<NSString *, S2ACPatchItem *> *seen = [NSMutableDictionary new];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSUInteger i = 1; i < lines.count; i++) {   // 第一行表头：编号 / 模块 / 位 / 类别 / 段名 / 许可 / 来源 / 数据写入 / 缺省开
        NSArray<NSString *> *c = [lines[i] componentsSeparatedByString:@"\t"];
        if (c.count < 9 || !c[0].length) continue;
        S2ACPatchItem *it = seen[c[0]];
        if (it) { it.defaultOn |= [c[8] isEqual:@"1"]; continue; }
        it = [S2ACPatchItem new];
        it.ident = c[0]; it.name = c[4].length ? c[4] : c[0]; it.license = c[5]; it.defaultOn = [c[8] isEqual:@"1"];
        it.group = S2ACPatchClassify(it.name, c[3], c[0]); it.title = S2ACPatchTitle(it.name, it.group);
        seen[c[0]] = it;
        int k = [it.group isEqual:@"widescreen"] ? 0 : [it.group isEqual:@"fps"] ? 1 : 2;
        [byKind[k] addObject:it];
    }
    NSMutableArray<S2ACPatchGroup *> *groups = [NSMutableArray new];
    for (int k = 0; k < 3; k++) {
        if (!byKind[k].count) continue;
        S2ACPatchGroup *g = [S2ACPatchGroup new];
        g.kind = kinds[k]; g.title = titles[k]; g.items = byKind[k];
        [groups addObject:g];
    }
    return groups;
}

NSSet<NSString *> *S2ACPatchEnabled(NSArray<S2ACPatchGroup *> *groups, NSUserDefaults *defaults) {
    id v = [defaults objectForKey:S2ACPatchDefaultsKey];
    NSSet<NSString *> *listed = nil;   // nil = 没设过（按表缺省开）
    if ([v isKindOfClass:NSArray.class]) listed = [NSSet setWithArray:v];
    else if ([v isKindOfClass:NSString.class]) listed = [v isEqual:@"none"] ? [NSSet set] : [NSSet setWithArray:[v componentsSeparatedByString:@","]];
    NSMutableSet<NSString *> *on = [NSMutableSet new];
    for (S2ACPatchGroup *g in groups)
        for (S2ACPatchItem *it in g.items)
            if (!it.followsFps60 && (listed ? [listed containsObject:it.ident] : it.defaultOn)) [on addObject:it.ident];
    return on;
}

void S2ACPatchSetEnabled(NSArray<S2ACPatchGroup *> *groups, NSUserDefaults *defaults, NSString *ident, BOOL on) {
    if ([ident hasPrefix:@"fps:"]) return;
    NSMutableSet<NSString *> *set = [S2ACPatchEnabled(groups, defaults) mutableCopy];
    if (on) [set addObject:ident]; else [set removeObject:ident];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (S2ACPatchGroup *g in groups)
        for (S2ACPatchItem *it in g.items)
            if ([set containsObject:it.ident]) [out addObject:it.ident];
    [defaults setObject:out forKey:S2ACPatchDefaultsKey];
}

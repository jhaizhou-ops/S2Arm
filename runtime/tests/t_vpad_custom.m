// 按游戏自定义按键位置（11-07 jhz：拖动编辑、按游戏单独记住、不套用到其他游戏、可恢复默认）
// 跑：make native-test-vpad_custom。期望值手算，不跑被测实现推导：
//   ① 布局 / 选择记录写进游戏目录 A，闲置透明度写进 App 设置目录 S（A 里没有 .visibility.json）
//   ② 两款游戏 A、B 共用 S：A 存了「我的布局」并选中，B 里没有布局文件、仍是默认；B 读到 A 设的透明度 0.40
//   ③ layoutWithButtonCenters：安全区 (47, 0, 750×369)，A 键中心挪到 (422, 184.5) → x = (422 − 47) / 750 = 0.5、y = 184.5 / 369 = 0.5；
//      越界的 B 键 (10, 500) → 钳到 x 0、y 1；没给中心的 X 键照旧
//   ④ replaceLayout 第二次覆盖成功、读回的是第二次的位置；内置 id 拒绝；saveLayout（导入）对已存在的 mine 仍拒绝
//   ⑤ 重开 A：选中 mine，A 键 x 0.25（第二次覆盖：中心 47 + 0.25 × 750）
#import <Foundation/Foundation.h>
#import "../../ios/vpad_layout.h"
static int bad;
#define CK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); printf("\n"); } while (0)
static NSDictionary *btn(S2AVPadLayout *l, NSString *i) { for (NSDictionary *b in l.buttons) if ([b[@"id"] isEqualToString:i]) return b; return nil; }
static BOOL near(double a, double b) { return fabs(a - b) < 1e-9; }
int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"vpad_custom_" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSURL *A = [root URLByAppendingPathComponent:@"games/gA/VPadLayouts"], *B = [root URLByAppendingPathComponent:@"games/gB/VPadLayouts"], *S = [root URLByAppendingPathComponent:@"VPadLayouts"];
        CGRect safe = CGRectMake(47, 0, 750, 369); NSError *e;
        S2AVPadLayoutStore *sa = [[S2AVPadLayoutStore alloc] initWithDirectory:A settingsDirectory:S];
        S2AVPadLayout *d = [S2AVPadLayout defaultForSafeRect:safe];
        S2AVPadLayout *m = [d layoutWithButtonCenters:@{@"A": @[@422, @184.5], @"B": @[@10, @500]} safeRect:safe identifier:S2AVPadLayoutMineIdentifier name:@"我的布局" error:&e];
        CK(m && near([btn(m, @"A")[@"x"] doubleValue], 0.5) && near([btn(m, @"A")[@"y"] doubleValue], 0.5), "③ A 键挪到 (422,184.5) → x 0.5、y 0.5（实得 %s）", m ? [[btn(m, @"A") description] UTF8String] : e.localizedDescription.UTF8String);
        CK(m && near([btn(m, @"B")[@"x"] doubleValue], 0) && near([btn(m, @"B")[@"y"] doubleValue], 1), "③ 越界的 B 键钳到 x 0、y 1");
        CK(m && [btn(m, @"X")[@"x"] isEqual:btn(d, @"X")[@"x"]] && [btn(m, @"X")[@"y"] isEqual:btn(d, @"X")[@"y"]], "③ 没给中心的 X 键照旧");
        BOOL ok = [sa replaceLayout:m error:&e] && [sa selectIdentifier:S2AVPadLayoutMineIdentifier error:&e] && [sa setIdleKeyOpacity:0.4 error:&e];
        CK(ok, "① 存「我的布局」、选中、设透明度都成功（%s）", ok ? "" : e.localizedDescription.UTF8String);
        CK([fm fileExistsAtPath:[A URLByAppendingPathComponent:@"mine.json"].path] && [fm fileExistsAtPath:[A URLByAppendingPathComponent:@".selection.json"].path], "① mine.json、.selection.json 在游戏目录 A");
        CK([fm fileExistsAtPath:[S URLByAppendingPathComponent:@".visibility.json"].path] && ![fm fileExistsAtPath:[A URLByAppendingPathComponent:@".visibility.json"].path], "① .visibility.json 在 App 设置目录 S、不在 A");
        S2AVPadLayoutStore *sb = [[S2AVPadLayoutStore alloc] initWithDirectory:B settingsDirectory:S];
        CK(sb.layouts.count == 0 && [sb.selectedIdentifier isEqualToString:S2AVPadLayoutDefaultIdentifier], "② 游戏 B 没有布局文件、仍是默认（实得 %lu 个、选 %s）", (unsigned long)sb.layouts.count, sb.selectedIdentifier.UTF8String);
        CK(near(sb.idleKeyOpacity, 0.4), "② 游戏 B 读到共用透明度 0.40（实得 %.2f）", sb.idleKeyOpacity);
        S2AVPadLayout *m2 = [d layoutWithButtonCenters:@{@"A": @[@(47 + 0.25 * 750), @184.5]} safeRect:safe identifier:S2AVPadLayoutMineIdentifier name:@"我的布局" error:&e];
        CK([sa replaceLayout:m2 error:&e], "④ 第二次覆盖成功");
        S2AVPadLayout *bad1 = [d layoutWithButtonCenters:@{} safeRect:safe identifier:@"default" name:@"x" error:&e];
        CK(bad1 && ![sa replaceLayout:bad1 error:&e], "④ 内置 id default 拒绝覆盖");
        CK(![sa saveLayout:m2 error:&e], "④ 导入（saveLayout）对已存在的 mine 仍拒绝");
        S2AVPadLayoutStore *ra = [[S2AVPadLayoutStore alloc] initWithDirectory:A settingsDirectory:S];
        S2AVPadLayout *sel = [ra selectedLayout:&e];
        CK(sel && [sel.identifier isEqualToString:S2AVPadLayoutMineIdentifier] && near([btn(sel, @"A")[@"x"] doubleValue], 0.25), "⑤ 重开 A：选中 mine、A 键 x 0.25（第二次的位置）（实得 %s）", sel ? [[btn(sel, @"A")[@"x"] description] UTF8String] : "无");
        [fm removeItemAtURL:root error:nil];
    }
    if (bad) printf("✗ t_vpad_custom：%d 项不通\n", bad); else printf("✓ t_vpad_custom：全部通过\n");
    return bad ? 1 : 0;
}

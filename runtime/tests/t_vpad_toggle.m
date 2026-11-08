// 「键 / 触」一键切换（ios/vpad_layout.m -[S2AVPadLayoutStore setTouchOnly:error:]；11-04 总指挥：脑锻炼标题页只认触屏，
//   缺省按键方案点不了「开始」，要四指长按 1.5 秒进设置才能切 → 屏角切换钮 + 提示条「切到触屏」一点就切）。临时目录，期望手写：
//   ① 缺省（default）→ 切触：返回 1，选中 touch，.last_keys.json 记 default
//   ② 已是 touch 再切触：返回 0，不写盘（.selection.json 修改时间不变）
//   ③ 切回键：返回 1，选中 default
//   ④ 自定义方案 mine → 切触 → 切回：回到 mine
//   ⑤ 切触后删掉 mine.json → 切回：回 default（记下的方案失效不卡死）
//   ⑥ .last_keys.json 写成乱码 → 切回：回 default
//   ⑦ 重新打开同一目录（模拟下次启动）：切换结果持久化（选中仍是上次切到的）
//   ⑧ 新目录 manualChosen = NO；markManual 后 YES，重开同一目录仍 YES（「玩家手动选过」持久化，自动切见到就不切）
//   旧实现没有 setTouchOnly:error:：编不过（红）
#import <Foundation/Foundation.h>
#import "../../ios/vpad_layout.h"
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
static NSString *last_keys(NSURL *d) {
    NSData *x = [NSData dataWithContentsOfURL:[d URLByAppendingPathComponent:@".last_keys.json"]];
    return x ? [NSJSONSerialization JSONObjectWithData:x options:0 error:nil][@"id"] : nil;
}
int main(void) { @autoreleasepool {
    NSURL *d = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    S2AVPadLayoutStore *s = [[S2AVPadLayoutStore alloc] initWithDirectory:d]; NSError *e;
    int r = [s setTouchOnly:YES error:&e];
    CK(r == 1 && [s.selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier] && [last_keys(d) isEqualToString:S2AVPadLayoutDefaultIdentifier], "① 缺省 → 切触：1、选中 touch、记下 default（实得 %d %s %s）", r, s.selectedIdentifier.UTF8String, last_keys(d).UTF8String);
    NSURL *sel = [d URLByAppendingPathComponent:@".selection.json"];
    NSDate *m0 = [NSFileManager.defaultManager attributesOfItemAtPath:sel.path error:nil].fileModificationDate; [NSThread sleepForTimeInterval:0.02];
    r = [s setTouchOnly:YES error:&e]; NSDate *m1 = [NSFileManager.defaultManager attributesOfItemAtPath:sel.path error:nil].fileModificationDate;
    CK(r == 0 && [m0 isEqualToDate:m1], "② 已是 touch 再切触：0、不写盘（实得 %d）", r);
    r = [s setTouchOnly:NO error:&e];
    CK(r == 1 && [s.selectedIdentifier isEqualToString:S2AVPadLayoutDefaultIdentifier], "③ 切回键：1、选中 default（实得 %d %s）", r, s.selectedIdentifier.UTF8String);
    NSMutableDictionary *doc = [[S2AVPadLayout defaultForSafeRect:CGRectMake(0, 0, 844, 390)].document mutableCopy]; doc[@"id"] = @"mine"; doc[@"name"] = @"我的";
    S2AVPadLayout *mine = [S2AVPadLayout readData:[NSJSONSerialization dataWithJSONObject:doc options:0 error:nil] error:&e];
    BOOL saved = mine && [s saveLayout:mine error:&e] && [s selectIdentifier:@"mine" error:&e];
    int a = [s setTouchOnly:YES error:&e], b = [s setTouchOnly:NO error:&e];
    CK(saved && a == 1 && b == 1 && [s.selectedIdentifier isEqualToString:@"mine"], "④ mine → 切触 → 切回：回到 mine（实得 存 %d %d %d %s；%s）", saved, a, b, s.selectedIdentifier.UTF8String, e.localizedDescription.UTF8String ?: "");
    [s setTouchOnly:YES error:&e]; [NSFileManager.defaultManager removeItemAtURL:[d URLByAppendingPathComponent:@"mine.json"] error:nil];
    r = [s setTouchOnly:NO error:&e];
    CK(r == 1 && [s.selectedIdentifier isEqualToString:S2AVPadLayoutDefaultIdentifier], "⑤ 记下的 mine 已删 → 切回 default（实得 %d %s）", r, s.selectedIdentifier.UTF8String);
    [s setTouchOnly:YES error:&e]; [@"{乱码" writeToURL:[d URLByAppendingPathComponent:@".last_keys.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    r = [s setTouchOnly:NO error:&e];
    CK(r == 1 && [s.selectedIdentifier isEqualToString:S2AVPadLayoutDefaultIdentifier], "⑥ .last_keys.json 乱码 → 切回 default（实得 %d %s）", r, s.selectedIdentifier.UTF8String);
    [s setTouchOnly:YES error:&e];
    S2AVPadLayoutStore *s2 = [[S2AVPadLayoutStore alloc] initWithDirectory:d];
    CK([s2.selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier], "⑦ 重开同一目录：仍是 touch（实得 %s）", s2.selectedIdentifier.UTF8String);
    NSURL *d2 = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    S2AVPadLayoutStore *f = [[S2AVPadLayoutStore alloc] initWithDirectory:d2]; BOOL mc0 = f.manualChosen, ok = [f markManual:&e];
    S2AVPadLayoutStore *f2 = [[S2AVPadLayoutStore alloc] initWithDirectory:d2];
    CK(!mc0 && ok && f.manualChosen && f2.manualChosen, "⑧ manualChosen：新目录 NO → markManual YES → 重开仍 YES（实得 %d %d %d %d）", mc0, ok, f.manualChosen, f2.manualChosen);
    [NSFileManager.defaultManager removeItemAtURL:d error:nil]; [NSFileManager.defaultManager removeItemAtURL:d2 error:nil];
    if (bad) printf("t_vpad_toggle：%d 项不过\n", bad); else printf("✓ t_vpad_toggle：8 项（切触 / 不重复写 / 切回 / 回自定义 / 失效回缺省 / 乱码回缺省 / 持久化 / 手动选过标记）\n");
    return bad ? 1 : 0;
} }

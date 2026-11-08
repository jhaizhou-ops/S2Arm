// 虚拟手柄摇杆按下（LS = Npad 位 4、RS = 位 5；11-06 jhz：七龙珠Z 卡卡洛特协议确认页要按，旧版只有隐藏的双击手势、等于没有）。
//   被测：ios/vpad_layout.m 默认布局（defaultForSafeRect）、按点取键（buttonAt:，vpad.m keyAt 用它）、浮动摇杆点按判定（S2AVPadStickTapIsPress）。
//   期望值手算（不调被测算式）：iPhone 14 横屏 844×390，安全区 = 左右各让 47 点刘海、底让 21 点 → (47, 0, 750, 369)。
//     默认布局各键中心（相对安全区原点，见 defaultForSafeRect 的点几何）：十字键中心 (66, 128)、「上」(66, 102)；ABXY 中心 fx = 750 − 92 = 658、fy = 369 − 112 = 257，
//     Y (608, 257)、B (658, 307)。新键：LS 在十字键上方 (66, 66)（上缘一行下沿 45 与「上」上沿 87 正中）、RS 在 Y / B 左下 (600, 319)，都是 28 点见方。换成屏幕绝对坐标 x + 47。
//   ① 默认布局有 16 个键、含 LS / RS；整份经 readData 校验通过（存成自定义方案也合法）
//   ② 点 LS 中心 (201, 180) → "LS" → 位 4；③ 点 RS 中心 (643, 180) → "RS" → 位 5（11-07 新默认布局：L3 / R3 在两根摇杆上方，按安全区比例 0.205 / 0.795 宽、0.489 高）
//   ④ 旧键不受影响：「上」(223, 263) → UP；Y (679, 231) → Y；B (726, 278) → B
//   ⑤ LS 与 L 的外扩热区重叠处 (181, 157)（L 外扩到 x 187 / y 158、LS 外扩从 x 176 / y 155 起）→ 归先列出的 L
//   ⑥ 左半屏空地 (300, 250) → 无键（浮动摇杆仍能从这里起）
//   ⑦ 四种屏（iPhone 14 / SE / 15 Pro Max / iPad 11 寸横屏）：LS / RS 可见框与任何其它键的可见框不相交，LS 在安全区左半、RS 在右半
//   ⑧ 点按判定：0.10 秒 3 点 → 按；0.25 秒 10 点（边界）→ 按；0.30 秒 0 点 → 不按（按住推杆）；0.10 秒 15 点 → 不按（拖了）
//   旧实现没有 buttonAt: / S2AVPadStickTapIsPress：编不过（红）；只撤 LS / RS 两个默认键（负对照）：①②③⑦ 红
#import <Foundation/Foundation.h>
#import "../../ios/vpad_layout.h"
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
static int bit_of(NSString *identifier) {   // HidNpadButton 位序（Ryujinx ControllerKeys 同序），手写
    NSDictionary *bits = @{@"A": @0, @"B": @1, @"X": @2, @"Y": @3, @"LS": @4, @"RS": @5, @"L": @6, @"R": @7, @"ZL": @8, @"ZR": @9,
                           @"PLUS": @10, @"MINUS": @11, @"LEFT": @12, @"UP": @13, @"RIGHT": @14, @"DOWN": @15};
    NSNumber *b = identifier ? bits[identifier] : nil; return b ? b.intValue : -1;
}
static NSDictionary *find(S2AVPadLayout *l, NSString *identifier) {
    for (NSDictionary *b in l.buttons) if ([b[@"id"] isEqualToString:identifier]) return b;
    return nil;
}
static const char *s(NSString *x) { return x ? x.UTF8String : "无"; }
int main(void) { @autoreleasepool {
    CGRect safe = CGRectMake(47, 0, 750, 369);
    S2AVPadLayout *l = [S2AVPadLayout defaultForSafeRect:safe]; NSError *e;
    S2AVPadLayout *back = [S2AVPadLayout readData:[NSJSONSerialization dataWithJSONObject:l.document options:0 error:nil] error:&e];
    CK(l.buttons.count == 16 && find(l, @"LS") && find(l, @"RS") && back, "① 默认布局 16 键含 LS / RS，readData 校验过（实得 %lu 键 LS %d RS %d 校验 %s）",
       (unsigned long)l.buttons.count, find(l, @"LS") != nil, find(l, @"RS") != nil, back ? "过" : s(e.localizedDescription));
    NSString *k = [l buttonAt:CGPointMake(201, 180) safeRect:safe slop:10];
    CK(bit_of(k) == 4, "② 点 (201,180) → LS 位 4（实得 %s 位 %d）", s(k), bit_of(k));
    k = [l buttonAt:CGPointMake(643, 180) safeRect:safe slop:10];
    CK(bit_of(k) == 5, "③ 点 (643,180) → RS 位 5（实得 %s 位 %d）", s(k), bit_of(k));
    NSString *up = [l buttonAt:CGPointMake(223, 263) safeRect:safe slop:10], *y = [l buttonAt:CGPointMake(679, 231) safeRect:safe slop:10],
             *b = [l buttonAt:CGPointMake(726, 278) safeRect:safe slop:10];
    CK([up isEqualToString:@"UP"] && [y isEqualToString:@"Y"] && [b isEqualToString:@"B"], "④ 旧键照旧：上 / Y / B（实得 %s / %s / %s）", s(up), s(y), s(b));
    k = [l buttonAt:CGPointMake(181, 157) safeRect:safe slop:10];
    CK([k isEqualToString:@"L"], "⑤ LS 与 L 热区重叠处 (181,157) → L（实得 %s）", s(k));
    k = [l buttonAt:CGPointMake(300, 250) safeRect:safe slop:10];
    CK(k == nil, "⑥ 左半屏空地 (300,250) → 无键（实得 %s）", s(k));
    CGRect screens[] = {safe, CGRectMake(16, 0, 635, 367), CGRectMake(59, 0, 814, 409), CGRectMake(16, 24, 1162, 790)};
    const char *names[] = {"iPhone 14", "SE", "15 Pro Max", "iPad 11 寸"};
    for (int i = 0; i < 4; i++) {
        S2AVPadLayout *d = [S2AVPadLayout defaultForSafeRect:screens[i]]; CGRect r = screens[i];
        NSDictionary *ls = find(d, @"LS"), *rs = find(d, @"RS"); NSString *hit = nil;
        CGRect fl = ls ? [d frameForButton:ls safeRect:r] : CGRectNull, fr = rs ? [d frameForButton:rs safeRect:r] : CGRectNull;
        for (NSDictionary *o in d.buttons) {
            if (o == ls || o == rs) continue; CGRect f = [d frameForButton:o safeRect:r];
            if ((ls && CGRectIntersectsRect(f, fl)) || (rs && CGRectIntersectsRect(f, fr))) hit = o[@"id"];
        }
        BOOL sides = ls && rs && CGRectGetMaxX(fl) < CGRectGetMidX(r) && CGRectGetMinX(fr) > CGRectGetMidX(r);
        CK(ls && rs && !hit && sides, "⑦ %s：LS (%.0f,%.0f) RS (%.0f,%.0f) 不压别的键、各在左右半（压到 %s）", names[i],
           CGRectGetMidX(fl), CGRectGetMidY(fl), CGRectGetMidX(fr), CGRectGetMidY(fr), s(hit));
    }
    CK(S2AVPadStickTapIsPress(0.10, 3) && S2AVPadStickTapIsPress(0.25, 10) && !S2AVPadStickTapIsPress(0.30, 0) && !S2AVPadStickTapIsPress(0.10, 15),
       "⑧ 点按判定：0.10s/3 按、0.25s/10 按、0.30s/0 不按、0.10s/15 不按");
    printf(bad ? "✗ t_vpad_stick_press：%d 项不通\n" : "✓ t_vpad_stick_press：全部通过\n", bad);
    return bad != 0;
} }

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 手算的开关 / 区域 / 目标比例；无 UIKit、无商业资源。make native-test-play_layout
#import "../../ios/play_layout.h"
#include <math.h>
#include <stdio.h>
static int bad, checks;
#define CK(c, msg) do { checks++; if (!(c)) { bad++; printf("✗ %s\n", msg); } } while (0)
static BOOL rect(CGRect a, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    return fabs(a.origin.x-x)<.001 && fabs(a.origin.y-y)<.001 && fabs(a.size.width-w)<.001 && fabs(a.size.height-h)<.001;
}
int main(void) { @autoreleasepool {
    CGRect b=CGRectMake(0,0,669,951), safe=CGRectMake(0,62,669,855), fold=CGRectMake(0,455.5,669,40);
    for (int half=0;half<2;half++) {
        CK(S2APlaySplitEnabled(S2APlaySplitAuto,half)==half,"自动只在半折开启");
        CK(S2APlaySplitEnabled(S2APlaySplitOn,half),"开启不受姿态限制");
        CK(!S2APlaySplitEnabled(S2APlaySplitOff,half),"关闭不受姿态限制");
    }
    S2APlayLayout l=S2APlayLayoutMake(b,safe,S2APlaySplitAuto,NO,fold);
    CK(!l.split && CGRectEqualToRect(l.game,b),"竖屏和折痕区域本身都不触发自动分屏");
    l=S2APlayLayoutMake(b,safe,S2APlaySplitAuto,YES,fold);
    CK(l.split && rect(l.game,0,62,669,393.5),"半折上区扣除顶部安全区及折痕");
    CK(rect(l.controls,0,495.5,669,421.5),"半折下区扣除折痕及底部安全区");
    l=S2APlayLayoutMake(CGRectMake(0,0,600,800),CGRectMake(0,20,600,760),S2APlaySplitOn,NO,CGRectNull);
    CK(l.split && rect(l.game,0,20,600,380) && rect(l.controls,0,400,600,380),"手动开启没有折痕时在视口中点分屏");
    l=S2APlayLayoutMake(CGRectMake(10,30,800,400),CGRectMake(30,40,760,360),S2APlaySplitOn,NO,CGRectNull);
    CK(l.split && rect(l.game,30,40,760,190) && rect(l.controls,30,230,760,170),"横屏及非零原点也始终上下分屏");
    l=S2APlayLayoutMake(b,safe,S2APlaySplitAuto,YES,CGRectMake(320,0,29,951));
    CK(l.split && rect(l.game,0,62,669,413.5),"竖向折痕仍符合自动半折条件，按中点上下分屏");
    l=S2APlayLayoutMake(b,safe,S2APlaySplitOn,NO,CGRectMake(NAN,0,10,20));
    CK(l.split && isfinite(l.game.size.height),"无效折痕不能污染区域或关闭强制分屏");
    CK(S2APlayPortrait(S2APlayOrientationAuto,YES) && !S2APlayPortrait(S2APlayOrientationAuto,NO),"自动方向随分屏切换");
    CK(!S2APlayPortrait(S2APlayOrientationLandscape,YES) && S2APlayPortrait(S2APlayOrientationPortrait,NO),"手动方向独立于分屏");
    CGSize t=S2APlayTargetSize(CGSizeMake(600,400));
    CK(t.width==1920 && t.height==1280,"上区 3:2 对应 1920×1280，不能交换宽高");
    t=S2APlayTargetSize(CGSizeMake(800,300));
    CK(t.width==2880 && t.height==1080,"上区 8:3 对应 2880×1080");
    t=S2APlayTargetSize(CGSizeZero);
    CK(t.width==1920 && t.height==1080,"空区域使用原始比例");
    NSString *suite=[@"play_layout_" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *d=[[NSUserDefaults alloc] initWithSuiteName:suite];
    CK(S2APlayReadSplit(d)==S2APlaySplitAuto && S2APlayReadOrientation(d)==S2APlayOrientationAuto,"缺省两项均自动");
    [d setObject:@"on" forKey:S2APlaySplitKey]; [d setObject:@"portrait" forKey:S2APlayOrientationKey];
    CK(S2APlayReadSplit(d)==S2APlaySplitOn && S2APlayReadOrientation(d)==S2APlayOrientationPortrait,"读取已保存选择");
    [d setObject:@42 forKey:S2APlaySplitKey]; [d setObject:@[] forKey:S2APlayOrientationKey];
    CK(S2APlayReadSplit(d)==S2APlaySplitAuto && S2APlayReadOrientation(d)==S2APlayOrientationAuto,"错误类型按默认处理");
    [d removePersistentDomainForName:suite];
    printf("%s t_play_layout：%d/%d 项符合（开关、区域、方向、上区宽屏比例）\n",bad?"✗":"✓",checks-bad,checks);
    return bad?1:0;
} }

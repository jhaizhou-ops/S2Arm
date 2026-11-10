// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "play_layout.h"
#include <math.h>
#include <stdatomic.h>

NSString *const S2APlaySplitKey=@"S2ASplitScreen", *const S2APlayOrientationKey=@"S2AScreenOrientation", *const S2APlayLayoutChanged=@"S2APlayLayoutChanged";
S2APlaySplitMode S2APlayReadSplit(NSUserDefaults *d) {
    id v=[d objectForKey:S2APlaySplitKey];
    return [v isEqual:@"on"] ? S2APlaySplitOn : [v isEqual:@"off"] ? S2APlaySplitOff : S2APlaySplitAuto;
}
S2APlayOrientation S2APlayReadOrientation(NSUserDefaults *d) {
    id v=[d objectForKey:S2APlayOrientationKey];
    return [v isEqual:@"portrait"] ? S2APlayOrientationPortrait : [v isEqual:@"landscape"] ? S2APlayOrientationLandscape : S2APlayOrientationAuto;
}
BOOL S2APlaySplitEnabled(S2APlaySplitMode mode, BOOL partiallyOpen) { return mode==S2APlaySplitOn || (mode==S2APlaySplitAuto && partiallyOpen); }
BOOL S2APlayPortrait(S2APlayOrientation orientation, BOOL split) { return orientation==S2APlayOrientationPortrait || (orientation==S2APlayOrientationAuto && split); }
static BOOL finite_rect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height) && r.size.width>=0 && r.size.height>=0;
}
S2APlayLayout S2APlayLayoutMake(CGRect b, CGRect safe, S2APlaySplitMode mode, BOOL half, CGRect division) {
    BOOL split=S2APlaySplitEnabled(mode,half);
    S2APlayLayout l={b,CGRectIntersection(b,safe),CGRectNull,split};
    if (!finite_rect(b) || CGRectIsEmpty(b)) return (S2APlayLayout){CGRectZero,CGRectZero,CGRectNull,split};
    if (!finite_rect(division)) division=CGRectNull;
    if (!CGRectIsNull(division)) l.division=CGRectIntersection(b,division);
    if (!split) return l;
    CGFloat top=CGRectGetMidY(b), bottom=top;
    if (!CGRectIsNull(l.division) && division.size.width>division.size.height &&
        l.division.size.width>=b.size.width*.9 && CGRectGetMinY(division)>CGRectGetMinY(b) && CGRectGetMaxY(division)<CGRectGetMaxY(b)) {
        top=CGRectGetMinY(division); bottom=CGRectGetMaxY(division);
    }
    l.game=CGRectIntersection(safe,CGRectMake(b.origin.x,b.origin.y,b.size.width,top-b.origin.y));
    l.controls=CGRectIntersection(safe,CGRectMake(b.origin.x,bottom,b.size.width,CGRectGetMaxY(b)-bottom));
    if (CGRectIsNull(l.game)) l.game=CGRectZero;
    if (CGRectIsNull(l.controls)) l.controls=CGRectZero;
    return l;
}
CGSize S2APlayTargetSize(CGSize a) {
    if (!(a.width>0 && a.height>0) || !isfinite(a.width) || !isfinite(a.height)) return CGSizeMake(1920,1080);
    double r=a.width/a.height;
    // 与 runtime/src/widen.c 的范围一致：只扩展一边，保持偶数像素。
    return r>=16.0/9 ? CGSizeMake(((int)fmin(8192,1080*r))&~1,1080) : CGSizeMake(1920,((int)fmin(8192,1920/r))&~1);
}
CGRect S2APlayControlsRect(S2APlayLayout l, CGRect b) {
    CGRect margin=CGRectMake(b.origin.x+16,b.origin.y,MAX(0,b.size.width-32),MAX(0,b.size.height-8));
    CGRect r=CGRectIntersection(l.controls,margin);
    return CGRectIsNull(r) ? CGRectZero : r;
}

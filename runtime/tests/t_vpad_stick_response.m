// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "../../ios/vpad_layout.h"
#include <math.h>
static unsigned checks, bad;
#define CK(c) do { checks++; if (!(c)) { bad++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)
static void point(double x, double y, double d, double s, double e, double wantX, double wantY) {
    CGPoint p = S2AVPadStickResponse(CGPointMake(x,y),d,s,e);
    if (fabs(p.x-wantX)>=1e-6 || fabs(p.y-wantY)>=1e-6) printf("input %.3f,%.3f d=%.2f s=%.2f e=%.2f got %.6f,%.6f want %.6f,%.6f\n",x,y,d,s,e,p.x,p.y,wantX,wantY);
    CK(fabs(p.x-wantX)<1e-6 && fabs(p.y-wantY)<1e-6);
}
int main(void) { @autoreleasepool {
    // 独立手算：(.54-.08)/.92 = .5；二次曲线 .25，平方根曲线 sqrt(.5)。
    point(0,0,.08,1,1,0,0); point(.04,.04,.08,1,1,0,0);
    point(.08,0,.08,1,1,0,0); point(.54,0,.08,1,1,.5,0);
    point(-.54,0,.08,1,2,-.25,0); point(0,-.54,.08,1,.5,0,-.7071067811865476);
    // 3:4:5 方向，r=.54 → .5，保持方向 → (.3,.4)。
    point(.324,.432,.08,1,1,.3,.4);
    point(.44,0,.08,.8,1,.5,0); point(.8,0,.08,.8,1,1,0);
    point(3,4,.08,1,1,.6,.8); point(0,1,.08,1,3,0,1);
    point(.5,0,0,1,1,.5,0);
    point(NAN,0,.08,1,1,0,0); point(INFINITY,0,.08,1,1,0,0);
    point(.5,0,NAN,1,1,0,0); point(.5,0,.08,0,1,0,0);
    point(.5,0,.08,1,INFINITY,0,0);
    NSURL *dir=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    S2AVPadLayoutStore *store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir];
    CK(store.stickDeadzone==.08 && store.stickSaturation==1 && store.stickExponent==1);
    CK(![NSFileManager.defaultManager fileExistsAtPath:dir.path]);
    NSError *err=nil;
    CK([store setStickDeadzone:.2 saturation:.8 exponent:2 error:&err]);
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir];
    CK(store.stickDeadzone==.2 && store.stickSaturation==.8 && store.stickExponent==2);
    CK([store.selectedIdentifier isEqualToString:S2AVPadLayoutDefaultIdentifier] && !store.manualChosen);
    [store layouts]; CK(store.diagnostics.count==0);
    CK(![store setStickDeadzone:.5 saturation:.8 exponent:2 error:&err]);
    CK(![store setStickDeadzone:0 saturation:.49 exponent:1 error:&err]);
    CK(![store setStickDeadzone:0 saturation:1 exponent:NAN error:&err]);
    CK(store.stickDeadzone==.2 && store.stickExponent==2);
    CK([store selectIdentifier:S2AVPadLayoutTouchIdentifier error:&err]);
    CK([store setStickDeadzone:0 saturation:.5 exponent:.5 error:&err]);
    CK([store.selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier] && !store.manualChosen);
    // 旧 schemaVersion=1 的五字段布局无需增加手感字段。
    S2AVPadLayout *layout=[S2AVPadLayout defaultForSafeRect:CGRectMake(0,0,844,390)];
    CK([S2AVPadLayout readData:[layout JSONData:&err] error:&err]!=nil && layout.document.count==5);
    NSURL *file=[dir URLByAppendingPathComponent:@".stick.json"];
    NSArray *invalid=@[@"{}",@"{\"schemaVersion\":1,\"deadzone\":true,\"saturation\":1,\"exponent\":1}",
        @"{\"schemaVersion\":1,\"deadzone\":0.08,\"saturation\":1,\"exponent\":\"1\"}",
        @"{\"schemaVersion\":2,\"deadzone\":0.08,\"saturation\":1,\"exponent\":1}"];
    for(NSString *text in invalid) {
        NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding]; [data writeToURL:file atomically:YES];
        store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir]; [store layouts];
        CK(store.stickDeadzone==.08 && store.stickSaturation==1 && store.stickExponent==1 && store.diagnostics.count==1);
        CK([[NSData dataWithContentsOfURL:file] isEqual:data]);
    }
    // 写失败不更新内存值；以普通文件冒充目录，不依赖测试账户的权限。
    NSURL *blocked=[dir URLByAppendingPathComponent:@"blocked"]; [NSData.data writeToURL:blocked atomically:YES];
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:blocked];
    CK(![store setStickDeadzone:.1 saturation:.9 exponent:2 error:&err] && store.stickDeadzone==.08);
    // 大文件 / 目录不是手感配置；修复记录后应清除诊断，不能改触屏选择。
    [[NSMutableData dataWithLength:4097] writeToURL:file atomically:YES];
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir]; [store layouts];
    CK(store.stickDeadzone==.08 && store.diagnostics.count==1);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    [NSFileManager.defaultManager createDirectoryAtURL:file withIntermediateDirectories:NO attributes:nil error:nil];
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir]; [store layouts];
    CK(store.stickDeadzone==.08 && store.diagnostics.count==1);
    CK(![store setStickDeadzone:.1 saturation:.9 exponent:2 error:&err] && store.stickDeadzone==.08);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    CK([store setStickDeadzone:.4 saturation:.5 exponent:3 error:&err]);
    [store layouts]; CK(store.diagnostics.count==0 && [store.selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier]);
    // 边界和不合法参数不会产生 NaN / 越界输出。
    point(.45,0,.4,.5,1,.5,0); point(.5,0,.4,.5,3,1,0);
    point(.5,0,-.01,1,1,0,0); point(.5,0,.41,1,1,0,0);
    point(.5,0,0,1.01,1,0,0); point(.5,0,0,1,.49,0,0);
    point(.5,0,0,1,3.01,0,0);
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    printf("%s t_vpad_stick_response: %u checks, %u failures\n",bad?"✗":"✓",checks,bad);
    return bad!=0;
} }

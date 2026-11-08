// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "../../ios/vpad_layout.h"
static unsigned checks, bad;
#define CK(c) do { checks++; if (!(c)) { bad++; printf("FAIL line %d: %s\n",__LINE__,#c); } } while (0)
int main(void) { @autoreleasepool {
    S2AVPadHapticState state={0};
    CK(!S2AVPadHapticStep(&state,0,0,0,YES));
    CK(S2AVPadHapticStep(&state,1,0,0,YES)); // A 新按下
    for (int i=0;i<100;i++) CK(!S2AVPadHapticStep(&state,1,0,0,YES));
    CK(S2AVPadHapticStep(&state,3,0,0,YES)); // 按着 A 再按 B
    CK(!S2AVPadHapticStep(&state,2,0,0,YES)); // 松开不震
    CK(!S2AVPadHapticStep(&state,0,0,0,YES));
    CK(S2AVPadHapticStep(&state,1,0,0,YES)); // 再次按 A
    CK(!S2AVPadHapticStep(&state,0,1,0,YES)); // 左摇杆中心
    CK(S2AVPadHapticStep(&state,0,1,1,YES)); // 首次到边
    CK(!S2AVPadHapticStep(&state,0,1,0,YES)); // 回中心
    CK(!S2AVPadHapticStep(&state,0,1,1,YES)); // 同一手指回边也不重复
    CK(S2AVPadHapticStep(&state,0,3,3,YES)); // 右杆独立首次到边
    CK(!S2AVPadHapticStep(&state,0,0,0,YES)); // 双杆释放
    CK(S2AVPadHapticStep(&state,0,1,1,YES)); // 新手势重置到边反馈
    CK(!S2AVPadHapticStep(&state,2,1,1,NO));
    CK(!S2AVPadHapticStep(&state,2,1,1,YES)); // 关闭期间也更新状态，重新开启不补震
    CK(!S2AVPadHapticStep(&state,0,0,3,YES)); // 无活跃触点的边界位无效
    state=(S2AVPadHapticState){0}; // cancel / 失焦 / 切布局清空
    CK(S2AVPadHapticStep(&state,1,3,3,YES)); // 同一事件多条件合并成一次 bool
    NSURL *dir=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    S2AVPadLayoutStore *store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir]; NSError *error=nil;
    CK(store.hapticFeedbackEnabled && ![NSFileManager.defaultManager fileExistsAtPath:dir.path]);
    CK([store selectIdentifier:S2AVPadLayoutTouchIdentifier error:&error]);
    CK([store setHapticFeedbackEnabled:NO error:&error]);
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir]; [store layouts];
    CK(!store.hapticFeedbackEnabled && !store.manualChosen && [store.selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier]);
    CK(store.diagnostics.count==0 && store.idleKeyOpacity==.25);
    CK([store setIdleKeyOpacity:.4 error:&error]);
    CK([store setHapticFeedbackEnabled:YES error:&error]);
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir];
    CK(store.hapticFeedbackEnabled && store.idleKeyOpacity==.4);
    S2AVPadLayout *layout=[S2AVPadLayout defaultForSafeRect:CGRectMake(0,0,844,390)];
    CK(layout.document.count==5 && [S2AVPadLayout readData:[layout JSONData:&error] error:&error]!=nil);
    NSURL *file=[dir URLByAppendingPathComponent:@".haptics.json"];
    for (NSString *text in @[@"{}",@"{\"schemaVersion\":1,\"enabled\":1}",@"{\"schemaVersion\":2,\"enabled\":false}",@"{\"schemaVersion\":1,\"enabled\":\"false\"}"]) {
        NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding]; [data writeToURL:file atomically:YES];
        store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir]; [store layouts];
        CK(store.hapticFeedbackEnabled && store.diagnostics.count==1 && [[NSData dataWithContentsOfURL:file] isEqual:data]);
    }
    [[NSMutableData dataWithLength:4097] writeToURL:file atomically:YES];
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir]; [store layouts];
    CK(store.hapticFeedbackEnabled && store.diagnostics.count==1);
    CK([store setHapticFeedbackEnabled:NO error:&error]); [store layouts];
    CK(!store.hapticFeedbackEnabled && store.diagnostics.count==0);
    NSURL *blocked=[dir URLByAppendingPathComponent:@"blocked"]; [NSData.data writeToURL:blocked atomically:YES];
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:blocked];
    CK(![store setHapticFeedbackEnabled:NO error:&error] && store.hapticFeedbackEnabled);
    // 已合入 C01-2 后，触感 / 透明度 / 摇杆偏好仍各自独立。
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir];
    CK([store setStickDeadzone:.2 saturation:.8 exponent:2 error:&error]);
    CK([store setHapticFeedbackEnabled:NO error:&error]);
    store=[[S2AVPadLayoutStore alloc] initWithDirectory:dir];
    CK(!store.hapticFeedbackEnabled && store.stickDeadzone==.2 && store.stickSaturation==.8 && store.stickExponent==2);
    CK(store.idleKeyOpacity==.4 && [store.selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier] && !store.manualChosen);
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    printf("%s t_vpad_haptics: %u checks, %u failures\n",bad?"✗":"✓",checks,bad);
    return bad!=0;
} }

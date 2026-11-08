// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Production visibility targets and per-app preferences; Foundation-only on Mac.
#import <Foundation/Foundation.h>
#import "../../ios/vpad_layout.h"
#include <math.h>

static unsigned checks, bad;
#define CK(c, ...) do { checks++; if (!(c)) { bad++; printf("FAIL "); } else printf("PASS "); printf(__VA_ARGS__); putchar('\n'); } while (0)
static BOOL same(double a, double b) { return fabs(a - b) < 1e-6; }
static NSURL *temporary(void) {
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
}
int main(void) { @autoreleasepool {
    NSURL *dir = temporary();
    S2AVPadLayoutStore *store = [[S2AVPadLayoutStore alloc] initWithDirectory:dir];
    CK(same(store.idleKeyOpacity, 0.25), "missing preference defaults to 25 percent");
    CK(![NSFileManager.defaultManager fileExistsAtPath:dir.path], "reading defaults does not write files");
    S2AVPadLayout *legacy = [S2AVPadLayout defaultForSafeRect:CGRectMake(0,0,844,390)];
    NSError *error = nil;
    CK([S2AVPadLayout readData:[legacy JSONData:&error] error:&error] != nil, "existing schema 1 layout still loads without visibility fields");
    CK([store selectIdentifier:S2AVPadLayoutTouchIdentifier error:&error], "select touch mode before editing appearance");
    NSData *selection = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@".selection.json"]];
    for (NSNumber *value in @[@0, @0.25, @0.5, @1]) {
        double expected = value.doubleValue;
        CK([store setIdleKeyOpacity:expected error:&error], "save opacity %.2f", expected);
        S2AVPadLayoutStore *reopened = [[S2AVPadLayoutStore alloc] initWithDirectory:dir];
        CK(same(reopened.idleKeyOpacity, expected), "reopen retains opacity %.2f", expected);
        CK(same(S2AVPadKeyOpacity(reopened.idleKeyOpacity, NO), expected), "idle target equals setting %.2f", expected);
        double active = expected > 0.75 ? expected : 0.75;
        CK(same(S2AVPadKeyOpacity(reopened.idleKeyOpacity, YES), active), "active target %.2f never dims below idle", active);
        CK([reopened.selectedIdentifier isEqualToString:S2AVPadLayoutTouchIdentifier] &&
           [selection isEqual:[NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@".selection.json"]]],
           "appearance change preserves selected input mode and selection file");
    }
    for (NSNumber *value in @[@(-0.01), @1.01, @(NAN), @(INFINITY)]) {
        NSData *before = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@".visibility.json"]];
        CK(![store setIdleKeyOpacity:value.doubleValue error:&error] && same(store.idleKeyOpacity, 1) &&
           [before isEqual:[NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@".visibility.json"]]],
           "invalid setter value rejected without changing state or disk");
    }
    NSArray *invalid = @[@"{}", @"{broken", @"{\"schemaVersion\":2,\"idleKeyOpacity\":0.5}",
        @"{\"schemaVersion\":1,\"idleKeyOpacity\":true}", @"{\"schemaVersion\":1,\"idleKeyOpacity\":\"0.5\"}",
        @"{\"schemaVersion\":1,\"idleKeyOpacity\":-0.1}", @"{\"schemaVersion\":1,\"idleKeyOpacity\":1.1}",
        @"{\"schemaVersion\":1,\"idleKeyOpacity\":0.5,\"extra\":1}"];
    NSURL *pref = [dir URLByAppendingPathComponent:@".visibility.json"];
    for (NSString *text in invalid) {
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding]; [data writeToURL:pref atomically:YES];
        S2AVPadLayoutStore *broken = [[S2AVPadLayoutStore alloc] initWithDirectory:dir]; [broken layouts];
        CK(same(broken.idleKeyOpacity, 0.25) && broken.diagnostics.count > 0 &&
           [data isEqual:[NSData dataWithContentsOfURL:pref]], "bad preference defaults visibly and preserves original file");
        CK([broken setIdleKeyOpacity:0.4 error:&error], "explicit adjustment repairs preference");
        [broken layouts]; CK(!broken.diagnostics.count && same(broken.idleKeyOpacity, 0.4), "successful repair clears diagnostic");
    }
    NSURL *blocked = temporary();
    S2AVPadLayoutStore *unsaved = [[S2AVPadLayoutStore alloc] initWithDirectory:blocked];
    [NSFileManager.defaultManager createDirectoryAtURL:[blocked URLByAppendingPathComponent:@".visibility.json"] withIntermediateDirectories:YES attributes:nil error:nil];
    CK(![unsaved setIdleKeyOpacity:0.6 error:&error] && same(unsaved.idleKeyOpacity, 0.25), "write failure preserves last effective setting");
    [NSFileManager.defaultManager removeItemAtURL:blocked error:nil];
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    printf("%s t_vpad_visibility: %u checks, %u failures\n", bad ? "✗" : "✓", checks, bad);
    return bad ? 1 : 0;
} }

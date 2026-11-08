#!/bin/bash
# 门禁覆盖：ios/diagredact.* ios/diag.m tools/redact.py tests/fixtures/redact_cases.tsv
# 与生产同源：用 Foundation / clang 在 Mac 核三端共用 TSV（全部合成输入）。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/main.m" <<'M'
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include "diagredact.h"
static BOOL check(NSString *input, NSString *expected) {
    char *out = s2a_diag_redact(input.UTF8String);
    BOOL ok = out && strcmp(out, expected.UTF8String) == 0;
    free(out);
    return ok;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    NSError *error = nil;
    NSString *table = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    if (!table || error) { fprintf(stderr, "样本表读失败\n"); return 1; }
    NSArray *rows = [table componentsSeparatedByString:@"\n"];
    if (![rows[0] isEqualToString:@"category\tinput\texpected"]) return 1;
    NSArray *categories = @[@"email", @"team", @"bundle", @"udid", @"udid_legacy", @"device_name"];
    NSMutableDictionary *positive = [NSMutableDictionary dictionary], *negative = [NSMutableDictionary dictionary];
    int count = 0, failed = 0;
    for (NSUInteger i = 1; i < rows.count; i++) {
        NSString *row = rows[i];
        if (!row.length || [row hasPrefix:@"#"]) continue;
        NSArray *cells = [row componentsSeparatedByString:@"\t"];
        if (cells.count != 3 || ![categories containsObject:cells[0]]) { fprintf(stderr, "样本表第%lu行格式错误\n", (unsigned long)i + 1); return 1; }
        NSMutableDictionary *counts = [cells[1] isEqualToString:cells[2]] ? negative : positive;
        counts[cells[0]] = @([counts[cells[0]] intValue] + 1);
        BOOL ok = check(cells[1], cells[2]);
        printf("%s 样本第%lu行\n", ok ? "✓" : "✗", (unsigned long)i + 1);
        count++; if (!ok) failed++;
    }
    for (NSString *category in categories)
        if ([positive[category] intValue] < 1 || [negative[category] intValue] < 1) failed++;
    if (!check(@"", @"") || s2a_diag_redact(NULL) != NULL) failed++;
    const char bad[] = { (char)0xff, 0 };
    char *invalid = s2a_diag_redact(bad); if (invalid) { failed++; free(invalid); }
    // 既有容器脱敏仍有效；旧式设备上下文不跨物理行泄到 git SHA。
    if (!check(@"/private/var/mobile/Containers/Data/Application/00000000-1111-2222-3333-444444444444/log", @"<APP>/log")) failed++;
    if (!check(@"/private/var/containers/Bundle/Application/00000000-1111-2222-3333-444444444444/app", @"<BUNDLE>/app")) failed++;
    if (!check(@"device\ncommit 0123456789abcdef0123456789abcdef01234567", @"device\ncommit 0123456789abcdef0123456789abcdef01234567")) failed++;
    if (!check(@"device\rcommit 0123456789abcdef0123456789abcdef01234567", @"device\rcommit 0123456789abcdef0123456789abcdef01234567")) failed++;
    if (!check(@"device\r\ncommit 0123456789abcdef0123456789abcdef01234567", @"device\r\ncommit 0123456789abcdef0123456789abcdef01234567")) failed++;
    if (!check(@"\"udid\":\"0000abcd-0123456789abcdef\"", @"\"udid\":\"[REDACTED]\"")) failed++;
    if (!check(@"serial='0123456789abcdef0123456789abcdef01234567'", @"serial='[REDACTED]'")) failed++;
    // 生产 manifest 使用同一入口，团队段脱敏且程序号保留。
    if (!check(@"s2arm.abcde12345.0100aabbccdd0000", @"s2arm.[TEAM_ID].0100aabbccdd0000")) failed++;
    printf("diagredact：%d 个共用样本，失败 %d\n", count, failed);
    return failed ? 1 : 0;
} }
M
clang -fobjc-arc -Wall -Wextra -Werror -O1 -I"$H/ios" -o "$T/redact" "$T/main.m" "$H/ios/diagredact.m" -framework Foundation
"$T/redact" "$H/tests/fixtures/redact_cases.tsv"

// 单测夹具缓存（tests/fixture.h）单测：首次生成、同指纹复用不再生成、指纹变（工具链 / 输入 / GPU 架构）自动重生、
//   残目录（没有 .done）重生、生成失败不落位、并发首跑只落一份。期望按规则手写，不跑 Metal。约 0.1 秒，退出 0 = 全过
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdio.h>
#include "fixture.h"

static int g_fail, g_n;
static void ck(BOOL ok, NSString *what) { g_n++; if (!ok) g_fail++; printf("%s %s\n", ok ? "✓" : "✗", what.UTF8String); }

int main(void) {
    @autoreleasepool {
        char t[] = "/tmp/t_fixture_XXXXXX"; if (!mkdtemp(t)) return 2;
        setenv("S2A_TEST_FIXTURES", t, 1);
        NSFileManager *fm = NSFileManager.defaultManager;
        __block _Atomic int calls = 0;
        BOOL (^gen)(NSString *) = ^BOOL(NSString *dir) { calls++; return [@"x" writeToFile:[dir stringByAppendingPathComponent:@"a.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil]; };
        NSString *fp1 = fx_fingerprint(@"t v1|lib-aaaa", @"applegpu_g17s"); int g = -1;
        NSString *d1 = fx_dir(@"t", fp1, gen, &g);
        ck(d1 && g == 1 && calls == 1 && [fm fileExistsAtPath:[d1 stringByAppendingPathComponent:@"a.bin"]] && [fm fileExistsAtPath:[d1 stringByAppendingPathComponent:@".done"]], @"首次：生成一次、文件与 .done 都在");
        NSString *d1b = fx_dir(@"t", fp1, gen, &g);
        ck([d1b isEqualToString:d1] && g == 0 && calls == 1, @"同指纹：复用、不再调生成");
        ck([fx_fingerprint(@"t v1|lib-aaaa", @"applegpu_g17s") isEqualToString:fp1], @"同输入同架构：指纹相同");
        NSString *fp2 = fx_fingerprint(@"t v1|lib-bbbb", @"applegpu_g17s"), *fp3 = fx_fingerprint(@"t v1|lib-aaaa", @"applegpu_g16s"), *fp4 = fx_fingerprint(@"t v2|lib-aaaa", @"applegpu_g17s");
        ck(![fp2 isEqualToString:fp1] && ![fp3 isEqualToString:fp1] && ![fp4 isEqualToString:fp1], @"metallib 变 / GPU 架构变 / 夹具版本变：指纹都变");
        NSString *d2 = fx_dir(@"t", fp2, gen, &g);
        ck(d2 && ![d2 isEqualToString:d1] && g == 1 && calls == 2, @"工具链变（指纹变）：自动重生到新目录");
        // 残目录：有目录没有 .done（生成到一半进程被杀）→ 当没有、重生
        NSString *fp5 = fx_fingerprint(@"t v1|lib-cccc", @"applegpu_g17s"), *d5 = [[@(t) stringByAppendingPathComponent:@"t"] stringByAppendingPathComponent:fp5];
        [fm createDirectoryAtPath:d5 withIntermediateDirectories:YES attributes:nil error:nil];
        [@"half" writeToFile:[d5 stringByAppendingPathComponent:@"a.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *d5b = fx_dir(@"t", fp5, gen, &g);
        ck([d5b isEqualToString:d5] && g == 1 && calls == 3 && [[NSString stringWithContentsOfFile:[d5 stringByAppendingPathComponent:@"a.bin"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"x"], @"残目录（没有 .done）：重生、内容换成新生成的");
        // 生成失败：返回空、不落位
        NSString *fp6 = fx_fingerprint(@"t v1|lib-dddd", @"applegpu_g17s");
        NSString *d6 = fx_dir(@"t", fp6, ^BOOL(NSString *dir) { return NO; }, &g);
        ck(d6 == nil && ![fm fileExistsAtPath:[[@(t) stringByAppendingPathComponent:@"t"] stringByAppendingPathComponent:fp6]], @"生成失败：返回空、不落位");
        // 并发首跑：8 个线程同时要同一个新指纹 → 都拿到同一个带 .done 的目录，只落一份、临时目录不留
        NSString *fp7 = fx_fingerprint(@"t v1|lib-eeee", @"applegpu_g17s");
        __block NSMutableArray *got = [NSMutableArray array]; NSLock *lk = [NSLock new];
        dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            NSString *d = fx_dir(@"t", fp7, gen, NULL); [lk lock]; [got addObject:d ?: @""]; [lk unlock]; });
        NSSet *uniq = [NSSet setWithArray:got];
        NSArray *left = [[fm contentsOfDirectoryAtPath:[@(t) stringByAppendingPathComponent:@"t"] error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS '.tmp.'"]];
        ck(uniq.count == 1 && [[uniq anyObject] length] > 0 && [fm fileExistsAtPath:[[uniq anyObject] stringByAppendingPathComponent:@".done"]] && left.count == 0, @"并发首跑：8 个线程拿到同一个落位目录、不留临时目录");
        [fm removeItemAtPath:@(t) error:nil];
        printf("t_fixture：%d 项，失败 %d\n", g_n, g_fail);
    }
    return g_fail ? 1 : 0;
}

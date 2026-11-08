// S2A.Dsh 产物的 Metal 校验器（t_dsh.sh 第 2 步）：清单每行「.metal 路径<TAB>入口,入口,…」（dsh_cmp --mtl-list 写），
// 逐份 MTLDevice newLibraryWithSource（preserveInvariance = YES，同离线链 -fpreserve-invariance、同 json chain_metal 记的编法）建库，再按名取 json 列的每个入口函数。
// 用法：dsh_mtlcheck <清单> [并发，缺省 6]。输出「建库 成功/总数、入口 取到/总数」，失败逐条列前 12 条；全过退出 0。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "用法：dsh_mtlcheck <清单> [并发]\n"); return 2; }
        int nj = argc > 2 ? atoi(argv[2]) : 6; if (nj < 1) nj = 1;
        NSString *list = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        if (!list) { fprintf(stderr, "【红】读不了清单 %s\n", argv[1]); return 2; }
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSString *l in [list componentsSeparatedByString:@"\n"]) if (l.length) [lines addObject:l];
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "【红】没有 Metal 设备\n"); return 2; }
        MTLCompileOptions *opt = [MTLCompileOptions new];
        opt.preserveInvariance = YES;
        __block atomic_int libs_ok = 0, fn_ok = 0, fn_all = 0;
        NSMutableArray<NSString *> *bad = [NSMutableArray array];
        dispatch_semaphore_t sem = dispatch_semaphore_create(nj);
        dispatch_group_t grp = dispatch_group_create();
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        for (NSString *l in lines) {
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            dispatch_group_async(grp, q, ^{
                @autoreleasepool {
                    NSArray<NSString *> *c = [l componentsSeparatedByString:@"\t"];
                    NSArray<NSString *> *ents = c.count > 1 ? [c[1] componentsSeparatedByString:@","] : @[];
                    NSString *src = [NSString stringWithContentsOfFile:c[0] encoding:NSUTF8StringEncoding error:nil];
                    NSError *e = nil;
                    id<MTLLibrary> lib = src ? [dev newLibraryWithSource:src options:opt error:&e] : nil;
                    atomic_fetch_add(&fn_all, (int)ents.count);
                    if (!lib) {
                        NSString *why = src ? (e.localizedDescription ?: @"?") : @"读不了 .metal";
                        @synchronized (bad) { [bad addObject:[NSString stringWithFormat:@"%@：建库失败：%@", c[0].lastPathComponent, [why substringToIndex:MIN(why.length, (NSUInteger)200)]]]; }
                    } else {
                        atomic_fetch_add(&libs_ok, 1);
                        for (NSString *n in ents) {
                            if ([lib newFunctionWithName:n]) atomic_fetch_add(&fn_ok, 1);
                            else @synchronized (bad) { [bad addObject:[NSString stringWithFormat:@"%@：没有入口 %@", c[0].lastPathComponent, n]]; }
                        }
                    }
                }
                dispatch_semaphore_signal(sem);
            });
        }
        dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
        printf("Metal 校验（%s）：建库 %d/%lu、入口 %d/%d\n", dev.name.UTF8String, atomic_load(&libs_ok), (unsigned long)lines.count, atomic_load(&fn_ok), atomic_load(&fn_all));
        NSArray *sorted = [bad sortedArrayUsingSelector:@selector(compare:)];
        for (NSUInteger i = 0; i < sorted.count && i < 12; i++) printf("  %s\n", [sorted[i] UTF8String]);
        return (bad.count == 0 && lines.count > 0) ? 0 : 1;
    }
}

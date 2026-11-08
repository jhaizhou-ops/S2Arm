// 预热插队（nvn_mtl.m warm_urgent_index / warm_bump / warm_pick，11-06 卡顿线异度3 冷装读档：场景管线排在清单末尾、第一帧干等 2714 ms）：直接包含生产 nvn_mtl.m。
// 清单 6 条 R 行（顶点|片元）：0 a|x、1 b|y、2 c|z、3 c|z、4 d|w、5 e|v。期望按规则手写：
//   ① 什么都不插：按清单顺序 0 1 2 3 4 5，之后 -1
//   ② 先插 c|z → 先领 2 3，再顺序 0；此时再插 c|z 不重复入队（已领）；插 e|v → 下一个领 5；之后顺序 1 4，顺序路走到 5 时跳过（已领），然后 -1
//   ③ 插一对清单里没有的、或片元为空的 → 不改顺序；收尾（warm_urgent_end）后再插 → 不入队
#include "../gfx/nvn/nvn_mtl.m"
static int bad;
static void ck(int ok, const char *what) { printf("%s %s\n", ok ? "  ✓" : "  ✗", what); if (!ok) bad++; }
static NSArray<WarmTask *> *mk(void) {
    const char *p[6][2] = {{"a", "x"}, {"b", "y"}, {"c", "z"}, {"c", "z"}, {"d", "w"}, {"e", "v"}};
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < 6; i++) { WarmTask *t = [WarmTask new]; t->kind = 1; t->vkey = @(p[i][0]); t->fkey = @(p[i][1]); [a addObject:t]; }
    return a;
}
static NSString *seq(_Atomic long *next, int k) { NSMutableArray *o = [NSMutableArray array]; for (int i = 0; i < k; i++) [o addObject:@(warm_pick(next, 6))]; return [o componentsJoinedByString:@" "]; }
int main(void) {
    @autoreleasepool {
        _Atomic long next = 0; warm_urgent_index(mk());
        ck([seq(&next, 7) isEqualToString:@"0 1 2 3 4 5 -1"], "① 不插队：按清单顺序，领完回 -1");

        next = 0; warm_urgent_index(mk());
        warm_bump("c", "z");
        NSString *s1 = seq(&next, 3);
        warm_bump("c", "z");   // 2 3 已领：不重复入队
        warm_bump("e", "v");
        NSString *s2 = seq(&next, 4);
        printf("    ② 实际：%s | %s\n", s1.UTF8String, s2.UTF8String);
        ck([s1 isEqualToString:@"2 3 0"], "② 插 c|z：先领 2 3，再顺序 0");
        ck([s2 isEqualToString:@"5 1 4 -1"], "② 再插 c|z 不重复；插 e|v 先领 5；顺序路跳过已领的 5，领完回 -1");
        ck(atomic_load(&g_wu_bumped) == 3 && atomic_load(&g_wu_taken) == 3, "② 计数：插队 3 行、由急件领走 3 行");

        next = 0; warm_urgent_index(mk());
        warm_bump("q", "q"); warm_bump("a", NULL);
        ck([seq(&next, 2) isEqualToString:@"0 1"], "③ 清单里没有的对、片元为空的对：不改顺序");
        warm_urgent_end(); warm_bump("e", "v");
        ck([seq(&next, 1) isEqualToString:@"2"], "③ 收尾后再插不入队");

        // ④ 首遇让路：提交线程在等首遇管线（g_fu_waiting）时工人不领新行，等完放行；计一次让路
        next = 0; warm_urgent_index(mk());
        atomic_store(&g_fu_waiting, 1);
        __block _Atomic long got = -9; dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ atomic_store(&got, warm_pick(&next, 6)); dispatch_semaphore_signal(done); });
        usleep(100000);
        ck(atomic_load(&got) == -9, "④ 首遇在等：工人 100 ms 内没领新行");
        atomic_store(&g_fu_waiting, 0);
        ck(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 1000000000ll)) && atomic_load(&got) == 0, "④ 首遇等完：工人放行，领第 0 行");
        ck(atomic_load(&g_fu_yield_n) == 1 && atomic_load(&g_fu_yield_ns) >= 90000000ull, "④ 计数：让路 1 次、累计 ≥90 ms");
    }
    printf(bad ? "✗ t_nvn_warmbump：%d 项不通\n" : "✓ t_nvn_warmbump：9 项全过\n", bad);
    return bad ? 1 : 0;
}

// 管线在途去重（pso_archive.h par_fl_enter / par_fl_leave）：直接包含生产 nvn_mtl.m，在真 Metal 设备上编计算管线。期望按「同一归档键同时只编一次」手写：
//   ① 一个线程已登记为某键的编者（par_fl_enter 返回 0），另一线程对同键 par_compute → 编者没交差前不返回（300 ms 内不完成）；编者交出管线 X 后它返回的就是 X（同一对象），去重计数 +1
//   ② 编者交差但结果是 nil（编失败）→ 等的线程自己再编，拿到非空管线
//   ③ 不同键不互等：有人在编 k1 时请求 k2，1 秒内返回
//   ④ 反证（负对照用）：没有在途记录时同键两次请求各编各的——去重计数不变
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static id ask(id<MTLFunction> fn, NSString *key, dispatch_semaphore_t done) {   // 另起一线程请求，返回 __block 结果的盒子
    NSMutableArray *box = [NSMutableArray array];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ NSError *e = nil; id ps = par_compute(fn, key, &e); @synchronized (box) { [box addObject:ps ?: NSNull.null]; } dispatch_semaphore_signal(done); });
    return box;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i; }\n" options:nil error:&e];
    REQUIRE(lib); id<MTLFunction> fn = [lib newFunctionWithName:@"k"]; REQUIRE(fn);
    id<MTLComputePipelineState> X = par_compute_(fn, nil, &e); REQUIRE(X);
    // ①
    id got; ParFlight *mine; uint64_t d0 = atomic_load(&g_par_dedup);
    REQUIRE(!par_fl_enter(@"t-k1", &got, &mine) && mine);
    dispatch_semaphore_t done = dispatch_semaphore_create(0); NSMutableArray *box = ask(fn, @"t-k1", done);
    long early = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC));
    par_fl_leave(@"t-k1", mine, X);
    long late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    VERIFY(early != 0 && late == 0 && box.count == 1 && box[0] == X && atomic_load(&g_par_dedup) == d0 + 1,
           "① 同键在编：300 ms 内没返回（%s）、编者交差后返回同一对象（%s）、去重 +%llu", early ? "是" : "否", box.count && box[0] == X ? "是" : "否", (unsigned long long)(atomic_load(&g_par_dedup) - d0));
    // ②
    d0 = atomic_load(&g_par_dedup); REQUIRE(!par_fl_enter(@"t-k2", &got, &mine) && mine);
    done = dispatch_semaphore_create(0); box = ask(fn, @"t-k2", done);
    usleep(100000); par_fl_leave(@"t-k2", mine, nil);
    late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    VERIFY(late == 0 && box.count == 1 && box[0] != NSNull.null && box[0] != X && atomic_load(&g_par_dedup) == d0 + 1, "② 编者失败：等的线程自己编出非空管线（%s）", late == 0 && box.count && box[0] != NSNull.null ? "是" : "否");
    // ③
    REQUIRE(!par_fl_enter(@"t-k3", &got, &mine) && mine);
    done = dispatch_semaphore_create(0); box = ask(fn, @"t-k4", done);
    late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
    par_fl_leave(@"t-k3", mine, X);
    VERIFY(late == 0 && box.count == 1 && box[0] != NSNull.null, "③ 不同键不互等：1 秒内返回（%s）", late == 0 ? "是" : "否");
    // ④
    d0 = atomic_load(&g_par_dedup); id a = par_compute(fn, @"t-k5", &e), b = par_compute(fn, @"t-k5", &e);
    VERIFY(a && b && atomic_load(&g_par_dedup) == d0, "④ 先后两次（无在途）不计去重：各自返回非空（%s），去重 +%llu", a && b ? "是" : "否", (unsigned long long)(atomic_load(&g_par_dedup) - d0));
  }
    if (failures) { printf("✗ t_nvn_pso_inflight：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_pso_inflight：%u 项全过（同一归档键同时只编一次：后到的等先到的、拿同一对象；先到的失败自己编；不同键不互等）\n", checks); return 0;
}

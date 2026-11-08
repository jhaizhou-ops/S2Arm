// 地址预算探针（总指挥 10-19 拍板第 2 条）：Metal Private 缓冲 / 贴图是否占进程虚拟地址空间。前台 App，跑完 exit(0)
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
typedef struct { uint64_t total, win, low, maxgap_win; } vas;
static vas scan(void) {
    vas v = {0}; vm_address_t a = 0; uint64_t prev_end = 0x7000000000ull;
    for (;;) {
        vm_size_t s = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o;
        if (vm_region_64(mach_task_self(), &a, &s, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &c, &o) != KERN_SUCCESS) break;
        uint64_t e = a + s; v.total += s;
        if (a < 0x7000000000ull) v.low += (e < 0x7000000000ull ? e : 0x7000000000ull) - a;
        if (e > 0x7000000000ull && a < 0x8000000000ull) {
            uint64_t x0 = a > 0x7000000000ull ? a : 0x7000000000ull, x1 = e < 0x8000000000ull ? e : 0x8000000000ull; v.win += x1 - x0;
            if (x0 > prev_end && x0 - prev_end > v.maxgap_win) v.maxgap_win = x0 - prev_end; if (x1 > prev_end) prev_end = x1;
        }
        a = e;
    }
    if (0x8000000000ull > prev_end && 0x8000000000ull - prev_end > v.maxgap_win) v.maxgap_win = 0x8000000000ull - prev_end;
    return v;
}
#define GB (1ull << 30)
#define MB (1ull << 20)
static void pr(const char *what, vas b, vas a, int ok, uint64_t gpu) {
    printf("%-34s %s 进程虚拟总量 %+.3f GB（低区 %+.3f，窗口 %+.3f），窗口最大空洞 %.2f GB，gpuAddress %#llx\n", what, ok ? "成功" : "失败",
        ((double)a.total - b.total) / GB, ((double)a.low - b.low) / GB, ((double)a.win - b.win) / GB, (double)a.maxgap_win / GB, (unsigned long long)gpu);
}
static void run(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    vas z = scan(); printf("基线：进程虚拟总量 %.3f GB，低区 %.3f GB，窗口内已占 %.3f GB，窗口最大空洞 %.2f GB；设备 %s，建议工作集 %.2f GB，单缓冲上限 %.2f GB\n",
        (double)z.total / GB, (double)z.low / GB, (double)z.win / GB, (double)z.maxgap_win / GB, d.name.UTF8String, (double)d.recommendedMaxWorkingSetSize / GB, (double)d.maxBufferLength / GB);
    @autoreleasepool { vas b = scan(); id<MTLBuffer> x = [d newBufferWithLength:256 * MB options:MTLResourceStorageModeShared]; vas a = scan(); pr("对照 Shared 缓冲 256 MB", b, a, x != nil, x.gpuAddress); x = nil; }
    uint64_t sz[] = {1 * GB, 4 * GB, 8 * GB};
    for (int i = 0; i < 3; i++) @autoreleasepool {
        vas b = scan(); id<MTLBuffer> x = [d newBufferWithLength:sz[i] options:MTLResourceStorageModePrivate]; vas a = scan();
        char w[64]; snprintf(w, sizeof w, "Private 缓冲 %llu GB", sz[i] / GB); pr(w, b, a, x != nil, x ? x.gpuAddress : 0); x = nil;
    }
    // GPU 真写过（blit 填满 1 GB Private 缓冲并等完成）后再扫：驻留 / 首次触碰是否才映射进 CPU 地址空间
    @autoreleasepool {
        id<MTLCommandQueue> q = [d newCommandQueue]; vas b = scan();
        id<MTLBuffer> x = [d newBufferWithLength:1 * GB options:MTLResourceStorageModePrivate];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be fillBuffer:x range:NSMakeRange(0, 1 * GB) value:0x5a]; [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
        vas a = scan(); printf("（GPU 已填满，命令缓冲状态 %ld %s）", (long)cb.status, cb.error ? cb.error.localizedDescription.UTF8String : "无错");
        pr("Private 缓冲 1 GB · GPU 写满后", b, a, x != nil, x.gpuAddress); x = nil;
    }
    // 贴图：RGBA32Float 2D，边长按目标字节算（1 GB = 8192²×16，4 GB = 16384²×16，8 GB = 16384²×16×2 层数组）
    struct { int w, layers; const char *n; } tx[] = {{8192, 1, "Private 贴图 1 GB"}, {16384, 1, "Private 贴图 4 GB"}, {16384, 2, "Private 贴图 8 GB（2 层数组）"}};
    for (int i = 0; i < 3; i++) @autoreleasepool {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:tx[i].w height:tx[i].w mipmapped:NO];
        if (tx[i].layers > 1) { td.textureType = MTLTextureType2DArray; td.arrayLength = tx[i].layers; }
        td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        vas b = scan(); id<MTLTexture> t = [d newTextureWithDescriptor:td]; vas a = scan(); pr(tx[i].n, b, a, t != nil, 0); t = nil;
    }
    vas e = scan(); printf("收尾：进程虚拟总量 %.3f GB（相对基线 %+.3f）\n##### 全部完成\n", (double)e.total / GB, ((double)e.total - z.total) / GB);
    exit(0);
}
@interface SD : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SD
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene]; self.window.rootViewController = [UIViewController new]; [self.window makeKeyAndVisible];
}
- (void)sceneDidBecomeActive:(UIScene *)scene { static int once; if (!once++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ run(); }); }
@end
@interface AD : UIResponder <UIApplicationDelegate>
@end
@implementation AD
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role]; c.delegateClass = [SD class]; return c;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AD class])); } }

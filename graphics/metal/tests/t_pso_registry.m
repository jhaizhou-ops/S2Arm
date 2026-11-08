// 真实 Metal 归档：并发首开、包 / 设备共用槽、重复登记与稀疏片号；读回验证管线对应的颜色。
#import "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <mach-o/dyld.h>
#include "fixture.h"

GAL_MTL4_ZONE_BEGIN
static void require(BOOL ok, NSString *operation, NSError *error) {
    if (!ok) { fprintf(stderr, "FAIL %s: %s\n", operation.UTF8String, error ? error.localizedDescription.UTF8String : "condition failed"); exit(1); }
}
static NSString *g_gate_path;
static dispatch_semaphore_t g_entered, g_release, g_waiting;
static _Atomic int g_claims;
// 强定义只控制真实开片的时序，不替换低区账本、归档或 Metal 返回值。
void gal_pso_test_open_hook(const char *path, int waiting) {
    if (!g_gate_path || strcmp(path, g_gate_path.UTF8String)) return;
    if (waiting) { dispatch_semaphore_signal(g_waiting); return; }
    g_claims++; dispatch_semaphore_signal(g_entered);
    dispatch_semaphore_wait(g_release, DISPATCH_TIME_FOREVER);
}
static void completed(dispatch_semaphore_t semaphore, NSString *operation) {
    require(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, operation, nil);
}
static void arm(NSString *path) {
    g_gate_path = path; g_claims = 0;
    g_entered = dispatch_semaphore_create(0); g_release = dispatch_semaphore_create(0); g_waiting = dispatch_semaphore_create(0);
}
static dispatch_group_t blocked_queries(id d, BOOL success) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { require((gal_pso_dev_lookup(d) != nil) == success, @"gated real archive opener result", nil); }
    });
    completed(g_entered, @"cold archive must reach the open gate");
    for (int i = 0; i < 8; i++) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { require((gal_pso_dev_lookup(d) != nil) == success, @"same-slot waiter result", nil); }
    });
    for (int i = 0; i < 8; i++) completed(g_waiting, @"same-slot query must wait for its opener");
    return group;
}
static void release_queries(dispatch_group_t group) {
    dispatch_semaphore_signal(g_release);
    require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, @"all same-slot waiters must wake", nil);
    require(g_claims == 1, @"one real open attempt for the gated slot", nil);
    g_gate_path = nil;
}
static MTL4RenderPipelineDescriptor *descriptor(id lib, NSString *fragment) {
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    d.vertexFunctionDescriptor = gal_be_fn_desc(lib, @"registry_vertex"); d.fragmentFunctionDescriptor = gal_be_fn_desc(lib, fragment);
    d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle; d.rasterSampleCount = 1;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; return d;
}
static uint64_t key(id d) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (const unsigned char *c = (const unsigned char *)gal_pso_pname(d).UTF8String; *c; c++) h = (h ^ *c) * 0x100000001b3ull;
    return h;
}
static void archive(NSString *path, id d) {
    NSError *error = nil; id serializer = nil, compiler = gal_be_capture_compiler(g_gdev, &serializer, &error);
    require(compiler != nil, @"create real capture compiler", error);
    require([compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&error] != nil, @"compile actual archived pipeline", error);
    require([serializer serializeAsArchiveAndFlushToURL:[NSURL fileURLWithPath:path] error:&error], @"serialize actual archive", error);
}
// 夹具（tests/fixture.h）：本单测用的六份单管线归档；首次（或工具链 / metallib 变了）用真编译器生成，之后直接拷贝
static NSString *g_fx;
static void put(NSString *name, NSString *path) {
    NSError *error = nil; [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    require([NSFileManager.defaultManager copyItemAtPath:[g_fx stringByAppendingPathComponent:name] toPath:path error:&error], [NSString stringWithFormat:@"copy fixture %@", name], error);
}
static void package(NSString *path, NSString *fixture, id d, uint32_t shard) {
    NSError *error = nil;
    require([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error], @"create package directory", error);
    NSString *name = [NSString stringWithFormat:@"gal_pso.%@.macos%ld.%u.bin", g_gdev.architecture.name, (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion, shard];
    put(fixture, [path stringByAppendingPathComponent:name]);
    uint32_t header[] = {0x49535047, 1, 1, 0}, tail[] = {shard, 0}; uint64_t hash = key(d);
    NSMutableData *index = [NSMutableData dataWithBytes:header length:sizeof header];
    [index appendBytes:&hash length:sizeof hash]; [index appendBytes:tail length:sizeof tail];
    require([index writeToFile:[path stringByAppendingPathComponent:@"gal_pso.idx"] options:0 error:&error], @"write actual package pipeline index", error);
    require([@"registry-test" writeToFile:[path stringByAppendingPathComponent:@"shader_pack.key"] atomically:NO encoding:NSUTF8StringEncoding error:&error], @"write package key", error);
}
static void pixel(id<MTLRenderPipelineState> pipeline, int channel) {
    require(pipeline != nil, @"retrieve archived pipeline", nil);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [g_gdev newTextureWithDescriptor:td]; require(target != nil, @"create real render target", nil);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandQueue> queue = [g_gdev newCommandQueue]; id<MTLCommandBuffer> buffer = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline]; [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [encoder endEncoding];
    [buffer commit]; [buffer waitUntilCompleted]; require(buffer.status == MTLCommandBufferStatusCompleted, @"execute actual archived pipeline", buffer.error);
    uint8_t rgba[4]; [target getBytes:rgba bytesPerRow:sizeof rgba fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    for (int i = 0; i < 4; i++) require(rgba[i] == (i == channel || i == 3 ? 255 : 0), @"archived pipeline must render its own color", nil);
}
int main(void) {
    @autoreleasepool {
        unsetenv("NXGAL_PSO_ARCHIVE"); unsetenv("NXGAL_PSO_ARCHIVE_OUT"); unsetenv("NXGAL_PSO_SCRIPT");
        char temporary[] = "/tmp/t_pso_registry_XXXXXX"; require(mkdtemp(temporary) != NULL, @"create isolated test directory", nil);
        NSString *root = @(temporary); setenv("NXGAL_PSO_DEV", "1", 1); setenv("NXGAL_PSO_DEV_DIR", [root stringByAppendingPathComponent:@"device"].fileSystemRepresentation, 1);
        require(nxgal_init(0) == 0, @"initialize real Metal backend", nil);
        NSError *error = nil;
        // 着色器离线编好随单测发布（Makefile：t_pso_registry_in/registry.metallib），不现场编 MSL
        char exe[4096]; uint32_t exn = sizeof exe; require(_NSGetExecutablePath(exe, &exn) == 0, @"locate test executable", nil);
        NSString *libPath = [[@(exe) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"t_pso_registry_in/registry.metallib"];
        id lib = [g_gdev newLibraryWithURL:[NSURL fileURLWithPath:libPath] error:&error]; require(lib != nil, @"load offline regression shaders", error);
        NSData *libBytes = [NSData dataWithContentsOfFile:libPath]; require(libBytes != nil, @"read offline regression shaders", nil);
        id red = descriptor(lib, @"registry_red"), green = descriptor(lib, @"registry_green"), blue = descriptor(lib, @"registry_blue");
        id slow = descriptor(lib, @"registry_slow"), other = descriptor(lib, @"registry_other"), missing = descriptor(lib, @"registry_missing");
        // 夹具版本号：改了生成方式（归档内容 / 文件名）就加一
        NSString *fp = fx_fingerprint([NSString stringWithFormat:@"t_pso_registry v1|%@", fx_sha(libBytes)], g_gdev.architecture.name); int gen = 0;
        g_fx = fx_dir(@"t_pso_registry", fp, ^BOOL(NSString *dir) {
            NSDictionary *all = @{@"red.bin": red, @"green.bin": green, @"blue.bin": blue, @"slow.bin": slow, @"other.bin": other, @"missing.bin": missing};
            for (NSString *n in all) archive([dir stringByAppendingPathComponent:n], all[n]);
            return YES; }, &gen);
        require(g_fx != nil, @"prepare archive fixtures", nil);
        fprintf(stderr, "夹具 %s：%s\n", gen ? "生成" : "复用", g_fx.fileSystemRepresentation);
        NSString *first = [root stringByAppendingPathComponent:@"first"], *second = [root stringByAppendingPathComponent:@"second"];
        package(first, @"red.bin", red, 7); package(second, @"green.bin", green, 11);
        require(nxgal_pso_archive_open_dir(first.fileSystemRepresentation) == 0, @"register sparse first package", nil);
        NSString *device = gal_pso_dev_dir(); require(device != nil, @"open actual device archive directory", nil);
        put(@"blue.bin", [device stringByAppendingPathComponent:@"blue.bin"]);
        NSString *line = [NSString stringWithFormat:@"%016llx\tblue.bin\n", (unsigned long long)key(blue)];
        require([line writeToFile:[device stringByAppendingPathComponent:@"dev.idx"] atomically:NO encoding:NSUTF8StringEncoding error:&error], @"index actual device pipeline", error);
        require(nxgal_pso_archive_open_dir(first.fileSystemRepresentation) == 0, @"register actual device archive", nil);
        dispatch_group_t group = dispatch_group_create();
        for (int i = 0; i < 32; i++) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { require(gal_pso_arch_lookup(red) != nil, @"32 concurrent cold archive queries", nil); }
        });
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        pixel(gal_pso_arch_lookup(red), 0); pixel(gal_pso_dev_lookup(blue), 2);
        uint64_t before[5], after[5]; gal_pso_arch_stats(before);
        require(before[0] == 2 && before[4] > 0, @"one package and one device archive must be open", nil);
        require(nxgal_pso_archive_open_dir(first.fileSystemRepresentation) == 0, @"repeat package registration", nil);
        gal_pso_arch_stats(after); require(after[4] == before[4], @"repeat registration must preserve already mapped bytes", nil);
        pixel(gal_pso_arch_lookup(red), 0); pixel(gal_pso_dev_lookup(blue), 2); gal_pso_arch_stats(after);
        require(after[0] == before[0] && after[4] == before[4], @"repeat queries must reuse existing package and device archives", nil);
        require(nxgal_pso_archive_open_dir(second.fileSystemRepresentation) == 0, @"register different sparse package with existing device slots", nil);
        pixel(gal_pso_arch_lookup(green), 1); pixel(gal_pso_dev_lookup(blue), 2); gal_pso_arch_stats(after);
        require(after[0] == before[0] + 1 && after[4] > before[4], @"new package must append one stable archive slot", nil);
        memcpy(before, after, sizeof before);
        require(nxgal_pso_archive_open_dir(first.fileSystemRepresentation) == 0, @"restore original package index", nil);
        pixel(gal_pso_arch_lookup(red), 0); pixel(gal_pso_dev_lookup(blue), 2); gal_pso_arch_stats(after);
        require(after[0] == before[0] && after[4] == before[4], @"restoring a package must reuse its stable slot and device index", nil);
        put(@"slow.bin", [device stringByAppendingPathComponent:@"slow.bin"]);
        put(@"other.bin", [device stringByAppendingPathComponent:@"other.bin"]);
        NSString *missingPath = [device stringByAppendingPathComponent:@"missing.bin"];
        put(@"missing.bin", missingPath); put(@"green.bin", [device stringByAppendingPathComponent:@"grow.bin"]);
        NSMutableString *lines = [line mutableCopy];
        [lines appendFormat:@"%016llx\tslow.bin\n%016llx\tother.bin\n%016llx\tmissing.bin\n", (unsigned long long)key(slow), (unsigned long long)key(other), (unsigned long long)key(missing)];
        NSString *deviceIndex = [device stringByAppendingPathComponent:@"dev.idx"];
        require([lines writeToFile:deviceIndex atomically:NO encoding:NSUTF8StringEncoding error:&error], @"index real cold device archives", error);
        require(nxgal_pso_archive_open_dir(first.fileSystemRepresentation) == 0, @"register cold device slots", nil);
        arm([device stringByAppendingPathComponent:@"slow.bin"]);
        dispatch_group_t gated = blocked_queries(slow, YES);
        // 闸门仍关闭；登记新槽强制数组增长，等待中的线程只能保留槽号。
        [lines appendFormat:@"%016llx\tgrow.bin\n", (unsigned long long)key(green)];
        require([lines writeToFile:deviceIndex atomically:NO encoding:NSUTF8StringEncoding error:&error], @"append another actual archive index row", error);
        require(nxgal_pso_archive_open_dir(first.fileSystemRepresentation) == 0, @"grow slot arrays while another archive is opening", nil);
        dispatch_semaphore_t hotDone = dispatch_semaphore_create(0), coldDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { pixel(gal_pso_arch_lookup(red), 0); dispatch_semaphore_signal(hotDone); }
        });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { pixel(gal_pso_dev_lookup(other), 1); dispatch_semaphore_signal(coldDone); }
        });
        completed(hotDone, @"already-open archive must render while another slot is blocked");
        completed(coldDone, @"different cold archive must open and render before the gate releases");
        release_queries(gated); pixel(gal_pso_dev_lookup(slow), 2);
        // 文件登记时是真归档，随后实际删除：Metal 必须真实报开片失败，所有同片等待者都返回。
        require([NSFileManager.defaultManager removeItemAtPath:missingPath error:&error], @"remove registered real archive to exercise open failure", error);
        gal_pso_arch_stats(before); arm(missingPath); gated = blocked_queries(missing, NO);
        release_queries(gated); gal_pso_arch_stats(after);
        require(after[3] == before[3] + 1 && after[4] == before[4], @"one failed real open must not add mapped bytes", nil);
        require(gal_pso_dev_lookup(missing) == nil, @"failed archive slot stays invalid without another open attempt", nil);
        gal_pso_arch_stats(before); require(before[3] == after[3], @"invalid slot must not retry a missing file", nil);
        nxgal_shutdown();
        require([NSFileManager.defaultManager removeItemAtPath:root error:&error], @"remove test-owned archives", error);
        puts("PASS real Metal archive registry: 32 concurrent queries, stable slots, RGB readback, independent hot/cold queries, array growth and failure wakeups");
    }
    return 0;
}
GAL_MTL4_ZONE_END

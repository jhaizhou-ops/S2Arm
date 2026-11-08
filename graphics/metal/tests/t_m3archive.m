// #116：真实生产入口，包归档及跨进程设备归档。无游戏资料或替身。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../gal_internal.h"
#include "fixture.h"
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

GAL_MTL4_ZONE_BEGIN
extern char **environ;
static int failures;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)
static MTLRenderPipelineDescriptor *render_desc(id<MTLLibrary> lib, NSString *vs, NSString *fs, MTLPixelFormat pf) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:vs]; d.fragmentFunction = [lib newFunctionWithName:fs];
    d.colorAttachments[0].pixelFormat = pf;
    return d;
}
static void draw(id<MTLRenderPipelineState> p, MTLPixelFormat pf, uint8_t out[4]) {
    CHECK(p != nil, "render pipeline missing"); if (!p) return;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:4 height:4 mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> t = [g_gdev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLCommandQueue> q = [g_gdev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:p]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status == MTLCommandBufferStatusCompleted, "draw: %s", cb.error.description.UTF8String);
    [t getBytes:out bytesPerRow:4 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    if (pf == MTLPixelFormatBGRA8Unorm) { uint8_t tmp = out[0]; out[0] = out[2]; out[2] = tmp; }
}
static int color_kind(const uint8_t v[4]) {
    const int colors[2][4] = {{255, 64, 128, 255}, {64, 128, 255, 255}};
    for (int j = 0; j < 2; j++) { int ok = 1; for (int k = 0; k < 4; k++) if (abs(v[k] - colors[j][k]) > 1) ok = 0; if (ok) return j; }
    return -1;
}
static int pack_test(NSString *pack, NSString *manifest) {
    setenv("NXGAL_BE", "mtl3", 1); setenv("NXGAL_M3_ARCHIVE", "1", 1); setenv("NXGAL_PSO_DEV", "0", 1);
    CHECK(nxgal_init(0) == 0, "init"); if (!g_gdev) return 1;
    CHECK(nxgal_pso_archive_open_dir(pack.fileSystemRepresentation) == 0, "open real offline archive");
    NSError *err = nil; NSString *text = [NSString stringWithContentsOfFile:manifest encoding:NSUTF8StringEncoding error:&err];
    CHECK(text != nil, "manifest: %s", err.description.UTF8String); int rows = 0, kinds = 0;
    uint64_t start[4], now[4]; nxgal_pso_cache_stats(start);
    NSMutableArray<MTLRenderPipelineDescriptor *> *descriptors = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length) continue; NSArray *a = [line componentsSeparatedByString:@"\t"];
        CHECK(a.count == 3, "manifest fields"); if (a.count != 3) continue; rows++;
        id<MTLLibrary> lib = [g_gdev newLibraryWithURL:[NSURL fileURLWithPath:a[0]] error:&err];
        CHECK(lib != nil, "manifest library: %s", err.description.UTF8String);
        int row_kind = -1;
        for (int i = 0; i < 2; i++) {
            MTLPixelFormat pf = i ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm;
            MTLRenderPipelineDescriptor *d = render_desc(lib, a[1], a[2], pf); [descriptors addObject:d];
            id<MTLRenderPipelineState> p = gal_new_render_pso((id)d, &err); uint8_t pixel[4] = {0}; draw(p, pf, pixel);
            int kind = color_kind(pixel); CHECK(kind >= 0, "pack pixel %u,%u,%u,%u", pixel[0], pixel[1], pixel[2], pixel[3]);
            if (i == 0) row_kind = kind; else CHECK(kind == row_kind, "RGBA8/BGRA8 must preserve this program's color");
            if (kind >= 0) kinds |= 1 << kind;
        }
    }
    nxgal_pso_cache_stats(now);
    uint64_t exact_hit = now[0] - start[0], exact_miss = now[1] - start[1];
    CHECK(rows == 2 && kinds == 3, "two actual programs/colors, rows=%d kinds=%d", rows, kinds);
    CHECK(now[0] - start[0] == 4 && now[1] == start[1], "pack exact descriptors hit=%llu miss=%llu", now[0]-start[0], now[1]-start[1]);
    for (NSUInteger i = 0; i < descriptors.count; i += 2) {
        MTLRenderPipelineDescriptor *d = [descriptors[i] copy]; d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].writeMask = MTLColorWriteMaskRed;
        id<MTLRenderPipelineState> p = gal_new_render_pso((id)d, &err); uint8_t pixel[4] = {0}; draw(p, MTLPixelFormatRGBA8Unorm, pixel);
        CHECK(pixel[0] >= 63 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 0, "miss descriptor respects red-only mask");
    }
    nxgal_pso_cache_stats(now); CHECK(now[0] - start[0] == 4 && now[1] - start[1] == 2, "changed descriptors must really miss: hit=%llu miss=%llu", now[0]-start[0], now[1]-start[1]);
    nxgal_shutdown();
    printf("m3archive pack: %s hit=%llu miss=%llu changed-hit=%llu changed-miss=%llu\n", failures ? "FAIL" : "PASS",
           exact_hit, exact_miss, now[0] - start[0] - exact_hit, now[1] - start[1] - exact_miss);
    return failures != 0;
}
static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 archive_vs(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\nfragment float4 archive_fs() { return float4(1,.25,.5,1); }\nkernel void archive_cs(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i]=i*7+3; }\n";
static int phase(NSString *root, NSString *mode) {
    int fault_reload = [mode isEqualToString:@"fault-reload"];
    int gateoff = [mode isEqualToString:@"gateoff"], reload = [mode isEqualToString:@"reload"] || fault_reload, fault = [mode isEqualToString:@"fault"];
    setenv("NXGAL_BE", "mtl3", 1); setenv("NXGAL_M3_ARCHIVE", gateoff ? "0" : "1", 1);
    setenv("NXGAL_PSO_DEV", "1", 1); setenv("NXGAL_PSO_DEV_DIR", [root stringByAppendingPathComponent:(fault || fault_reload) ? @"fault-device" : @"device"].fileSystemRepresentation, 1);
    CHECK(nxgal_init(0) == 0, "init phase"); if (!g_gdev) return 1;
    CHECK(nxgal_pso_archive_open_dir([root stringByAppendingPathComponent:@"pack"].fileSystemRepresentation) == 1, "device-only input must have no package archive");
    NSError *err = nil; id<MTLLibrary> lib = fx_lib(g_gdev, @"m3archive-real-v1", source, &err);
    CHECK(lib != nil, "offline MSL: %s", err.description.UTF8String); if (!lib) { nxgal_shutdown(); return 1; }
    NSString *index = [gal_pso_dev_dir() stringByAppendingPathComponent:@"dev.idx"];
    CHECK(gateoff ? gal_pso_dev_dir() == nil : [gal_pso_dev_dir() hasSuffix:@".mtl3"], "Metal 3 archive gate and backend directory isolation");
    if (fault) {
        CHECK([NSFileManager.defaultManager createFileAtPath:index contents:NSData.data attributes:nil], "create empty real index");
        // Reading the index and writing its sibling temporary file remain possible;
        // replacing this immutable destination fails after archive serialization.
        CHECK(chflags(index.fileSystemRepresentation, UF_IMMUTABLE) == 0, "make real index immutable: %s", strerror(errno));
    }
    uint64_t before[4], after[4]; nxgal_pso_cache_stats(before);
    MTLRenderPipelineDescriptor *d = render_desc(lib, @"archive_vs", @"archive_fs", MTLPixelFormatRGBA8Unorm);
    id<MTLRenderPipelineState> p = gal_new_render_pso((id)d, &err); uint8_t pixel[4] = {0}; draw(p, MTLPixelFormatRGBA8Unorm, pixel);
    CHECK(color_kind(pixel) == 0, "sync render pixels");
    MTLRenderPipelineDescriptor *ad = render_desc(lib, @"archive_vs", @"archive_fs", MTLPixelFormatBGRA8Unorm);
    id<MTLRenderPipelineState> hit = nil; gal_pso_job *job = gal_new_render_pso_async(ad, &hit);
    // Flush must include completion capture even before the caller consumes the job.
    gal_pso_dev_flush("m3archive async before wait");
    p = hit ?: (job ? gal_pso_job_wait(job) : nil); draw(p, MTLPixelFormatBGRA8Unorm, pixel); CHECK(color_kind(pixel) == 0, "async render pixels");
    MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new]; cd.computeFunction = [lib newFunctionWithName:@"archive_cs"];
    id<MTLComputePipelineState> cp = gal_new_compute_pso((id)cd, &err); CHECK(cp != nil, "compute pipeline: %s", err.description.UTF8String);
    if (cp) {
        id<MTLBuffer> b = [g_gdev newBufferWithLength:16*sizeof(uint32_t) options:MTLResourceStorageModeShared];
        memset(b.contents, 0, b.length); id<MTLCommandQueue> q = [g_gdev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:cp]; [ce setBuffer:b offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(16,1,1) threadsPerThreadgroup:MTLSizeMake(16,1,1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "compute dispatch"); for (int i=0;i<16;i++) CHECK(((uint32_t *)b.contents)[i] == (uint32_t)(i*7+3), "compute value %d", i);
    }
    gal_pso_dev_flush("m3archive final"); uint64_t stats[6]; gal_pso_dev_stats(stats); nxgal_pso_cache_stats(after);
    if (fault) {
        CHECK(stats[1] == 0 && stats[2] == 0, "failed index must not count committed writes");
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:gal_pso_dev_dir() error:&err];
        for (NSString *f in files) CHECK(![f hasSuffix:@".bin"] && ![f hasSuffix:@".tmp"], "failed commit orphan: %s", f.UTF8String);
        CHECK(chflags(index.fileSystemRepresentation, 0) == 0, "clear own immutable index flag: %s", strerror(errno));
        gal_pso_dev_flush("m3archive retry"); gal_pso_dev_stats(stats);
        CHECK(stats[1] == 3 && stats[2] >= 1, "retry must retain all three pending captures");
    } else if (reload) {
        CHECK(after[0]-before[0] == 3 && after[1] == before[1] && stats[0] == 3, "new process must hit actual device archive: hit=%llu miss=%llu dev=%llu", after[0]-before[0], after[1]-before[1], stats[0]);
    } else {
        CHECK(after[0] == before[0] && after[1]-before[1] == 3 && stats[0] == 0, "capture/gateoff must miss: hit=%llu miss=%llu", after[0]-before[0], after[1]-before[1]);
        if (!gateoff) CHECK(stats[1] == 3 && stats[2] >= 1 && stats[4] == 3 && stats[5] == 0, "three real captures committed: wrote=%llu files=%llu captured=%llu failed=%llu", stats[1],stats[2],stats[4],stats[5]);
    }
    printf("phase=%s hit=%llu miss=%llu devicehit=%llu wrote=%llu files=%llu captures=%llu failed=%llu\n", mode.UTF8String, after[0]-before[0], after[1]-before[1],stats[0],stats[1],stats[2],stats[4],stats[5]);
    nxgal_shutdown(); return failures != 0;
}
static void child(const char *exe, NSString *root, const char *mode) {
    char *args[] = {(char *)exe, "--phase", (char *)mode, (char *)root.fileSystemRepresentation, NULL}; pid_t pid;
    int result = posix_spawn(&pid, exe, NULL, NULL, args, environ); CHECK(result == 0, "spawn %s: %s", mode, strerror(result)); if (result) return;
    int status = 0; CHECK(waitpid(pid, &status, 0) == pid, "wait %s", mode); CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "child %s status=%d", mode, status);
}
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 4 && !strcmp(argv[1], "--pack")) return pack_test(@(argv[2]), @(argv[3]));
    if (argc == 4 && !strcmp(argv[1], "--phase")) return phase(@(argv[3]), @(argv[2]));
    if (argc != 1) { fprintf(stderr,"usage: %s [--pack directory manifest]\n",argv[0]); return 2; }
    char path[] = "/tmp/t_m3archive.XXXXXX"; if (!mkdtemp(path)) return 2; NSString *root = @(path); NSError *err = nil;
    NSString *pack = [root stringByAppendingPathComponent:@"pack"];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:pack withIntermediateDirectories:NO attributes:nil error:&err], "private pack directory");
    CHECK([@"authored-m3archive-v1\n" writeToFile:[pack stringByAppendingPathComponent:@"shader_pack.key"] atomically:YES encoding:NSUTF8StringEncoding error:&err], "explicit test input identity");
    char exe[PATH_MAX]; if (!realpath(argv[0], exe)) return 2;
    child(exe, root, "capture"); child(exe, root, "reload"); child(exe, root, "gateoff"); child(exe, root, "fault"); child(exe, root, "fault-reload");
    CHECK([NSFileManager.defaultManager removeItemAtPath:root error:&err], "remove private test directory");
    printf("m3archive: %s\n", failures ? "FAIL" : "PASS"); return failures != 0;
} }
GAL_MTL4_ZONE_END

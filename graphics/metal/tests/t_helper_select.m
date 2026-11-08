// #117：通过生产辅助库加载入口核对目录选择，使用真实 Metal 库和计算读回。
// 每个用例在独立临时目录 exec 自身，隔离目录缓存、辅助库缓存和默认搜索路径。
// Metal 4 用例仅核旧版根目录选择，不执行 Metal 4 编码器，macOS 15 也能验证。
#import <Metal/Metal.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include "../gal_internal.h"

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; printf("✗ " __VA_ARGS__); putchar('\n'); } } while (0)

static int child(const char *backend, int expected, int compiles) {
    g_gdev = MTLCreateSystemDefaultDevice();
    CHECK(g_gdev != nil, "没有 Metal 设备");
    if (!g_gdev) return 1;
    g_gal_be = !strcmp(backend, "m3") ? GAL_BE_MTL3 : GAL_BE_MTL4;
    gal_helper_kick(0);
    NSError *error = nil;
    id<MTLLibrary> library = gal_helper_lib(0, &error);
    CHECK(library != nil && error == nil, "辅助库载入失败：%s", error.localizedDescription.UTF8String);
    CHECK(nxgal_helper_compiles() == (uint64_t)compiles, "现编数 %llu，期望 %d", (unsigned long long)nxgal_helper_compiles(), compiles);
    if (!library) return 1;
    if (compiles) {
        CHECK([library newFunctionWithName:@"restride"] != nil, "缺少兼容库时应现编真实重排辅助库");
        CHECK([library newFunctionWithName:@"selected"] == nil, "不得退回根目录的另一后端夹具");
    } else {
        id<MTLFunction> function = [library newFunctionWithName:@"selected"];
        CHECK(function != nil, "未载入目录选择夹具");
        if (!function) return 1;
        id<MTLComputePipelineState> pipeline = [g_gdev newComputePipelineStateWithFunction:function error:&error];
        CHECK(pipeline != nil, "夹具管线建立失败：%s", error.localizedDescription.UTF8String);
        if (!pipeline) return 1;
        id<MTLBuffer> output = [g_gdev newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [g_gdev newCommandQueue];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        CHECK(output && queue && command, "无法建立计算读回资源");
        if (!output || !queue || !command) return 1;
        *(uint32_t *)output.contents = 0;
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        CHECK(encoder != nil, "无法建立计算编码器");
        if (!encoder) return 1;
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:output offset:0 atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        CHECK(command.status == MTLCommandBufferStatusCompleted && command.error == nil, "计算命令未完成");
        CHECK(*(uint32_t *)output.contents == (uint32_t)expected, "目录读回 %u，期望 %d", *(uint32_t *)output.contents, expected);
    }
    printf("%s：%d/%d；后端 %s；现编 %llu\n", failures ? "失败" : "通过", checks - failures, checks, backend, (unsigned long long)nxgal_helper_compiles());
    return failures != 0;
}

static BOOL compile_fixture(NSString *root, int value, NSString *output) {
    NSString *source = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"select_%d.metal", value]];
    NSString *msl = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void selected(device uint *p [[buffer(0)]]) { p[0] = %du; }\n", value];
    if (![msl writeToFile:source atomically:NO encoding:NSUTF8StringEncoding error:nil]) return NO;
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"--sdk", @"macosx", @"metal", @"-std=metal3.2", @"-mmacosx-version-min=15.0", @"-o", output, source];
    if (![task launchAndReturnError:nil]) return NO;
    [task waitUntilExit]; return task.terminationStatus == 0;
}

int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 5 && !strcmp(argv[1], "--child")) return child(argv[2], atoi(argv[3]), atoi(argv[4]));
    CHECK(argc == 1, "无效参数"); if (failures) return 1;
    char temporary[] = "/tmp/s2arm-helper-select.XXXXXX";
    CHECK(mkdtemp(temporary) != NULL, "不能建立临时目录"); if (failures) return 1;
    NSString *root = @(temporary), *red = [root stringByAppendingPathComponent:@"root.metallib"], *blue = [root stringByAppendingPathComponent:@"m3.metallib"];
    CHECK(compile_fixture(root, 117, red), "根目录夹具编译失败");
    CHECK(compile_fixture(root, 231, blue), "Metal 3 夹具编译失败");
    char self[4096]; uint32_t size = sizeof self;
    CHECK(_NSGetExecutablePath(self, &size) == 0, "不能取得测试程序路径");
    if (failures) { printf("证据保留：%s\n", temporary); return 1; }
    const char *base = NULL; nxgal_helper_src(0, &base);
    CHECK(base != NULL, "不能取得生产辅助库基名"); if (!base) return 1;
    NSString *filename = [@(base) stringByAppendingString:@".metallib"];
    struct { const char *name, *backend; int layout, override, expected, compiles; } cases[] = {
        {"M3 默认目录", "m3", 0, 0, 231, 0},
        {"M4 保留根目录", "m4", 0, 0, 117, 0},
        {"M3 显式目录原样优先", "m3", 0, 1, 117, 0},
        {"M3 已指定 m3 子目录", "m3", 0, 2, 231, 0},
        {"M3 显式任意平铺目录", "m3", 0, 3, 231, 0},
        {"M3 库缺失，不串用根目录", "m3", 1, 0, 0, 1},
        {"M3 库损坏，报红后现编", "m3", 2, 0, 0, 1},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        NSString *bin = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"case%zu/bin", i]];
        NSString *helpers = [bin stringByAppendingPathComponent:@"gal_helpers"], *m3 = [helpers stringByAppendingPathComponent:@"m3"];
        NSFileManager *fm = NSFileManager.defaultManager;
        CHECK([fm createDirectoryAtPath:m3 withIntermediateDirectories:YES attributes:nil error:nil], "创建夹具目录失败");
        NSString *runner = [bin stringByAppendingPathComponent:@"runner"];
        CHECK([fm copyItemAtPath:@(self) toPath:runner error:nil], "复制测试程序失败");
        CHECK([fm copyItemAtPath:red toPath:[helpers stringByAppendingPathComponent:filename] error:nil], "复制根目录夹具失败");
        if (cases[i].layout == 0) CHECK([fm copyItemAtPath:blue toPath:[m3 stringByAppendingPathComponent:filename] error:nil], "复制 M3 夹具失败");
        if (cases[i].layout == 2) CHECK([@"invalid metallib" writeToFile:[m3 stringByAppendingPathComponent:filename] atomically:NO encoding:NSUTF8StringEncoding error:nil], "写损坏库失败");
        NSString *custom = [bin stringByAppendingPathComponent:@"custom-helpers"];
        if (cases[i].override == 3) {
            CHECK([fm createDirectoryAtPath:custom withIntermediateDirectories:YES attributes:nil error:nil], "创建显式平铺目录失败");
            CHECK([fm copyItemAtPath:blue toPath:[custom stringByAppendingPathComponent:filename] error:nil], "复制显式平铺夹具失败");
        }
        NSString *log = [bin stringByAppendingPathComponent:@"result.log"];
        int fd = open(log.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
        CHECK(fd >= 0, "打开子进程日志失败"); if (fd < 0) continue;
        pid_t pid = fork();
        if (!pid) {
            dup2(fd, 1); dup2(fd, 2); close(fd);
            if (cases[i].override) setenv("NXGAL_HELPER_DIR", (cases[i].override == 3 ? custom : cases[i].override == 2 ? m3 : helpers).fileSystemRepresentation, 1);
            else unsetenv("NXGAL_HELPER_DIR");
            char expected[16], compiles[16]; snprintf(expected, sizeof expected, "%d", cases[i].expected); snprintf(compiles, sizeof compiles, "%d", cases[i].compiles);
            execl(runner.fileSystemRepresentation, runner.fileSystemRepresentation, "--child", cases[i].backend, expected, compiles, (char *)NULL); _exit(127);
        }
        close(fd); CHECK(pid > 0, "不能创建子进程"); if (pid < 0) continue;
        int status = 0; pid_t waited; do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
        NSString *output = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil];
        printf("== %s\n%s", cases[i].name, output.UTF8String ?: "（无输出）\n");
        CHECK(waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0, "%s 子进程失败（status=%d）", cases[i].name, status);
        if (cases[i].layout == 2) CHECK([output containsString:@"【红】内部辅助库"], "损坏的 M3 库必须报告加载失败");
        else CHECK(output && ![output containsString:@"【红】"], "%s 不应有加载错误", cases[i].name);
    }
    if (!failures) [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    else printf("失败证据保留：%s\n", temporary);
    printf("%s：helper directory selection %d/%d\n", failures ? "失败" : "通过", checks - failures, checks);
    return failures != 0;
} }

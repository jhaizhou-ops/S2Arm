// 单测夹具缓存（10-23 画面·着色器线，总指挥定）：单测要测的是登记 / 开片 / 取用逻辑，不是 Metal 编译器；
//   准备阶段每次现场经系统编译服务建归档 / 编库，会把编译器耗时（系统级函数编译缓存的文件锁，跟整机负载走）带进判据——
//   负载 18 下 t_pso_registry 1200 次 p99 2.9 s、最长 6.8 s，631/753 个采样停在 MTLCompilerFSCache::openSync → fopen。
// 做法：夹具按「指纹」放进机器级缓存目录，首次生成、之后直接用；指纹含 GPU 架构、系统版本号（含 Build，Metal 运行时编译器随它变）
//   与调用方给的输入（metallib 内容哈希、夹具版本号），工具链一变指纹就变、自动重生。
// 目录：$S2A_TEST_FIXTURES（缺省 ~/Library/Caches/s2arm/test_fixtures）/<名>/<指纹>/，生成完写 .done 再整目录改名落位：
//   并发首跑各自生成到临时目录，先改名的落位，后到的丢掉自己那份、用落位的；没有 .done 的残目录当没有、重生。
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <unistd.h>

// 字符串 → 十六进制 sha256 前 16 字节
static inline NSString *fx_sha(NSData *d) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString string]; for (int i = 0; i < 16; i++) [s appendFormat:@"%02x", h[i]]; return s;
}
// 指纹：调用方的输入串 + GPU 架构 + 系统版本（含 Build 号）
static inline NSString *fx_fingerprint(NSString *inputs, NSString *gpuArch) {
    NSString *all = [NSString stringWithFormat:@"%@|%@|%@", inputs, gpuArch ?: @"-", NSProcessInfo.processInfo.operatingSystemVersionString];
    return fx_sha([all dataUsingEncoding:NSUTF8StringEncoding]);
}
static inline NSString *fx_root(void) {
    const char *e = getenv("S2A_TEST_FIXTURES");
    return e && *e ? @(e) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/s2arm/test_fixtures"];
}
// 取夹具目录：<根>/<名>/<指纹>/ 有 .done 直接返回；否则在同级临时目录调 generate 生成，写 .done 后改名落位。
//   *generated（可空）= 1 表示本次生成了。失败返回 nil
static inline NSString *fx_dir(NSString *name, NSString *fp, BOOL (^generate)(NSString *dir), int *generated) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *parent = [fx_root() stringByAppendingPathComponent:name], *dir = [parent stringByAppendingPathComponent:fp];
    NSString *done = [dir stringByAppendingPathComponent:@".done"];
    if (generated) *generated = 0;
    if ([fm fileExistsAtPath:done]) return dir;
    if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSString *tmpl = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.tmp.XXXXXX", fp]];
    char *t = strdup(tmpl.fileSystemRepresentation); if (!mkdtemp(t)) { free(t); return nil; }
    NSString *tmp = @(t); free(t);
    if (!generate(tmp) || ![@"" writeToFile:[tmp stringByAppendingPathComponent:@".done"] atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        [fm removeItemAtPath:tmp error:nil]; return nil; }
    if ([fm fileExistsAtPath:dir] && ![fm fileExistsAtPath:done]) [fm removeItemAtPath:dir error:nil];   // 没写完的残目录：清掉再落位
    if (rename(tmp.fileSystemRepresentation, dir.fileSystemRepresentation) != 0) {   // 别的进程先落位了：用它的
        [fm removeItemAtPath:tmp error:nil];
        return [fm fileExistsAtPath:done] ? dir : nil;
    }
    if (generated) *generated = 1;
    return dir;
}

// 固定 MSL 源码的库夹具：首次用命令行 xcrun metal 离线编成 metallib 放进夹具缓存，之后 newLibraryWithURL 载入，不经运行时编译服务
//   （运行时 newLibraryWithSource 走系统级函数编译缓存，负载下文件锁长尾）。指纹 = 源码哈希 + 工具链（DEVELOPER_DIR，Makefile 导出）+ 系统版本 + GPU 架构。
//   只给「编译不是被测对象」的单测用：被测代码生成的 MSL（翻译器 / 改写器产物）仍须现场编。
static inline id<MTLLibrary> fx_lib(id<MTLDevice> dev, NSString *name, NSString *source, NSError **error) {
    const char *dd = getenv("DEVELOPER_DIR");
    NSString *fp = fx_fingerprint([NSString stringWithFormat:@"lib v1|%@|%s", fx_sha([source dataUsingEncoding:NSUTF8StringEncoding]), dd ? dd : "-"], dev.architecture.name);
    NSString *dir = fx_dir(name, fp, ^BOOL(NSString *d) {
        NSString *src = [d stringByAppendingPathComponent:@"lib.metal"], *out = [d stringByAppendingPathComponent:@"lib.metallib"];
        if (![source writeToFile:src atomically:NO encoding:NSUTF8StringEncoding error:nil]) return NO;
        NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
        t.arguments = @[@"-sdk", @"macosx", @"metal", @"-o", out, src];
        if (![t launchAndReturnError:nil]) return NO;
        [t waitUntilExit]; return t.terminationStatus == 0 && [NSFileManager.defaultManager fileExistsAtPath:out];
    }, NULL);
    if (!dir) { if (error) *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"离线编 %@ 失败（xcrun metal）", name]}]; return nil; }
    return [dev newLibraryWithURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"lib.metallib"]] error:error];
}

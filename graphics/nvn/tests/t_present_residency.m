// #298：真实 Mac 前端、宿主和直连库；外部纹理登记后不经主提交直接上屏。
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "../gfx/nvn/nvn_mtl.h"
#include "s2a_gfx_mode.h"

void s2a_front_run(void (*guest_main)(void));
void *s2a_mac_front_layer(void);
void *front_metal_layer(void);
double nvn_be_presented_time(uint64_t ticket);
uint64_t mtl_present_count(void);

static int failed, checked;
#define CHECK(ok, ...) do { \
    checked++; int pass = !!(ok); failed += !pass; \
    printf("%s ", pass ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); \
} while (0)

static void run(void) {
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)mtl_device();
        CHECK(dev != nil, "真实 Metal 设备：%s", dev.name.UTF8String);
        if (!dev) exit(1);
        id<MTLSharedEvent> event = [dev newSharedEvent];
        CHECK(event != nil, "创建外部生产者事件");
        if (!event) exit(1);
        for (uint64_t frame = 1; frame <= 3; frame++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:64 height:64 mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            CHECK(tex != nil, "创建第 %llu 张外部纹理", (unsigned long long)frame);
            if (!tex) exit(1);
            uint32_t pixels[64 * 64];
            for (int i = 0; i < 64 * 64; i++) pixels[i] = 0xff000000u | (0x55u << (8 * (frame - 1)));
            [tex replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:pixels bytesPerRow:64 * 4];
            uint64_t serial = mtl_ext_tex((__bridge void *)tex);
            // 每张新纹理都在登记后立即上屏；不能插入空的 nvn_be_sub_commit 掩盖驻留缺口。
            int shown = 0;
            for (int repeat = 0; repeat < 3; repeat++) {
                CFTimeInterval begin = CACurrentMediaTime();
                uint64_t ticket = mtl_present_ext(serial, 0, (__bridge void *)event, frame, NULL);
                if (!repeat) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                    dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ event.signaledValue = frame; });
                nvn_be_present_wait(ticket);
                double ms = (CACurrentMediaTime() - begin) * 1000;
                CHECK(ticket == 3 * frame - 2 + repeat, "上屏票号 %llu", (unsigned long long)ticket);
                CHECK(event.signaledValue >= frame && (repeat || ms >= 280),
                    "票号 %llu 等生产者事件完成，等待 %.1f ms", (unsigned long long)ticket, ms);
                // 等待接口也会在 GPU 错误后返回，必须再验真实呈现回调；runner 同时拒绝 GPU 错误日志。
                double presented = 0, deadline = CACurrentMediaTime() + 3;
                do {
                    presented = nvn_be_presented_time(ticket);
                    if (presented != 0) break;
                    struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL);
                } while (CACurrentMediaTime() < deadline);
                CHECK(presented != 0, "票号 %llu 呈现回调 %.6f（-1 为系统丢弃）", (unsigned long long)ticket, presented);
                shown += presented > 0;
                struct timespec pacing = {0, 50000000}; nanosleep(&pacing, NULL);
            }
            // 窗口初次显示可丢弃 drawable；每张纹理仍须有真正显示的帧，不能只凭提交回调判绿。
            CHECK(shown > 0, "第 %llu 张纹理实际呈现 %d/3 次", (unsigned long long)frame, shown);
        }
        CHECK(nvn_be_last_fence() == 0, "测试期间没有主提交");
        CHECK(mtl_present_count() == 9, "提交九次上屏");
        nvn_be_drain();
        printf("present residency: %d/%d passed\n", checked - failed, checked); fflush(stdout);
        exit(failed ? 1 : 0);
    }
}

int main(void) {
    alarm(30);
    if (setenv("S2A_GFX", "direct", 1)) return 1;
    if (s2a_gfx_mode() != S2A_GFX_DIRECT) return 1;
    // 在主队列调用生产适配器设置层设备，再让 Core Animation 发布这次窗口事务。
    // 不提交 GPU 命令；首次层设备变更期间被系统丢弃的 drawable 不属于本测试的纹理驻留验收。
    dispatch_async(dispatch_get_main_queue(), ^{
        CHECK(s2a_mac_front_layer() != NULL, "生产 Mac 窗口已发布出图层");
        if (!s2a_mac_front_layer()) exit(1);
        if (front_metal_layer() != s2a_mac_front_layer()) exit(1);
        [CATransaction flush];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSWindow *window = nil;
            for (NSWindow *candidate in NSApp.windows)
                if ((__bridge void *)candidate.contentView.layer == s2a_mac_front_layer()) { window = candidate; break; }
            // keyWindow 表示键盘焦点；上屏验收必须检查持有生产 CAMetalLayer 的窗口。
            BOOL visible = window && (window.occlusionState & NSWindowOcclusionStateVisible);
            CHECK(visible, "生产 Mac 窗口可见（layer window=%ld，key window=%ld）", (long)window.windowNumber, (long)NSApp.keyWindow.windowNumber);
            if (!visible) exit(1);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ run(); });
        });
    });
    s2a_front_run(NULL);
    return 1;
}

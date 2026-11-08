// 几何着色器变换反馈三个核（graphics/nvn/gfx/nvn/nvn_geometry.h k_nvn_geo_tf_msl）：手造输出记录 / 压缩后的点列表 / 计数，期望手算，不跑被测实现。
//   记录 6 字一个顶点（字 w = 100·顶点号 + w）；缓冲 0 两条：记录字 2 取 1 个分量、字 4 取 2 个分量（步长 12 字节）；压缩列表 3 个点：顶点 5、2、7
//   ① 起点 8 字节（CPU 已知）、容量 40 字节 → 放得下 (40 − 8) / 12 = 2 个整点：写 [502, 504, 505, 202, 204, 205]，计数 8 + 24 = 32
//   ② 再来一次、按 GPU 计数（32）续写：剩 (40 − 32) / 12 = 0 个点，不写、计数不动
//   ③ tf_draw_args：计数 32、步长 12 → 顶点数 2；tf_snap：4 个计数原样拷
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include "../gfx/nvn/nvn_geometry.h"
static int fail;
#define CHECK(c, ...) do { printf("%s ", (c) ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); if (!(c)) fail = 1; } while (0)
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) { printf("✗ 没有 Metal 设备\n"); return 1; }
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_nvn_geo_tf_msl) options:nil error:&e];
    if (!lib) { printf("✗ 编不过：%s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> ps[4]; const char *nm[4] = {"geo_tf_write", "geo_tf_count", "tf_draw_args", "tf_snap"};
    for (int i = 0; i < 4; i++) ps[i] = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(nm[i])] error:&e];
    id<MTLBuffer> rec = [dev newBufferWithLength:6 * 8 * 4 options:0], idx = [dev newBufferWithLength:16 options:0], args = [dev newBufferWithLength:32 options:0],
                  cnt = [dev newBufferWithLength:16 options:0], dst = [dev newBufferWithLength:64 options:0], job = [dev newBufferWithLength:sizeof(nvn_geo_tf) options:0];
    uint32_t *r = rec.contents; for (int v = 0; v < 8; v++) for (int w = 0; w < 6; w++) r[v * 6 + w] = 100 * v + w;
    uint32_t ix[3] = {5, 2, 7}; memcpy(idx.contents, ix, 12); ((uint32_t *)args.contents)[0] = 3; memset(dst.contents, 0xee, 64); memset(cnt.contents, 0, 16);
    nvn_geo_tf j = {.rec = rec.gpuAddress, .idx = idx.gpuAddress, .args = args.gpuAddress, .cnt = cnt.gpuAddress, .rec_words = 6, .per_prim = 1};
    j.dst[0] = dst.gpuAddress; j.size[0] = 40; j.stride[0] = 12; j.start[0] = 8; j.ne[0] = 2; j.off[0][0] = 2; j.comp[0][0] = 1; j.off[0][1] = 4; j.comp[0][1] = 2;
    void (^run)(id<MTLComputePipelineState>, id<MTLBuffer>, NSUInteger) = ^(id<MTLComputePipelineState> p, id<MTLBuffer> b, NSUInteger n) {
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:p]; [ce setBuffer:b offset:0 atIndex:0];
        for (id<MTLBuffer> u in @[rec, idx, args, cnt, dst]) [ce useResource:u usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        [ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted]; };
    memcpy(job.contents, &j, sizeof j); run(ps[0], job, 64); run(ps[1], job, 1);
    uint32_t *d = dst.contents; uint32_t want[6] = {502, 504, 505, 202, 204, 205};
    CHECK(!memcmp(d + 2, want, 24) && d[0] == 0xeeeeeeee && d[1] == 0xeeeeeeee && d[8] == 0xeeeeeeee, "① 起点 8 字节写两个整点 [%u %u %u %u %u %u]，起点前与第三个点不写", d[2], d[3], d[4], d[5], d[6], d[7]);
    CHECK(((uint32_t *)cnt.contents)[0] == 32, "① 计数 8 + 2×12 = 32（实得 %u）", ((uint32_t *)cnt.contents)[0]);
    j.use_cnt = 1; memcpy(job.contents, &j, sizeof j); memset(d + 8, 0xee, 32); run(ps[0], job, 64); run(ps[1], job, 1);
    CHECK(((uint32_t *)cnt.contents)[0] == 32 && d[8] == 0xeeeeeeee, "② 按 GPU 计数续写：放不下整点，不写、计数仍 32（实得 %u）", ((uint32_t *)cnt.contents)[0]);
    id<MTLBuffer> a2 = [dev newBufferWithLength:16 options:0], snap = [dev newBufferWithLength:16 options:0], jb = [dev newBufferWithLength:sizeof(nvn_tf_args) options:0];
    nvn_tf_args t = {.cnt = cnt.gpuAddress, .args = a2.gpuAddress, .b = 0, .stride = 12}; memcpy(jb.contents, &t, sizeof t);
    void (^run2)(id<MTLComputePipelineState>) = ^(id<MTLComputePipelineState> p) {
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:p]; [ce setBuffer:jb offset:0 atIndex:0]; for (id<MTLBuffer> u in @[cnt, a2, snap]) [ce useResource:u usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted]; };
    run2(ps[2]); uint32_t *ga = a2.contents;
    CHECK(ga[0] == 2 && ga[1] == 1 && !ga[2] && !ga[3], "③ 间接参数 {32/12 = 2, 1, 0, 0}（实得 %u %u %u %u）", ga[0], ga[1], ga[2], ga[3]);
    ((uint32_t *)cnt.contents)[1] = 7; ((uint32_t *)cnt.contents)[2] = 9; ((uint32_t *)cnt.contents)[3] = 11; t.args = snap.gpuAddress; memcpy(jb.contents, &t, sizeof t); run2(ps[3]);
    uint32_t *sp = snap.contents; CHECK(sp[0] == 32 && sp[1] == 7 && sp[2] == 9 && sp[3] == 11, "③ 留存 4 个计数（实得 %u %u %u %u）", sp[0], sp[1], sp[2], sp[3]);
    // ④ 带索引绘制的变换反馈收集（k_tf_gather_msl，nvn_mtl.m tf_draw）：暂存 4 条记录、每条 2 字（字 w = 10·记录号 + w），顺序表 [2, 0, 2, 3, 1]
    //   → 目标依次是记录 2、0、2、3、1：[20 21 0 1 20 21 30 31 10 11]，第 6 条之后不写（仍是 0xeeeeeeee）。手算，不跑被测实现
    { id<MTLLibrary> gl = [dev newLibraryWithSource:@(k_tf_gather_msl) options:nil error:&e];
      id<MTLComputePipelineState> gp = gl ? [dev newComputePipelineStateWithFunction:[gl newFunctionWithName:@"tf_gather"] error:&e] : nil;
      CHECK(gp != nil, "④ 收集核编得过%s", gp ? "" : e.localizedDescription.UTF8String);
      if (gp) { id<MTLBuffer> src = [dev newBufferWithLength:32 options:0], gd = [dev newBufferWithLength:64 options:0], mp = [dev newBufferWithLength:20 options:0], gj = [dev newBufferWithLength:sizeof(nvn_tf_gather) options:0];
          uint32_t *sr = src.contents; for (int k = 0; k < 4; k++) for (int w = 0; w < 2; w++) sr[k * 2 + w] = 10 * k + w;
          uint32_t m[5] = {2, 0, 2, 3, 1}; memcpy(mp.contents, m, 20); memset(gd.contents, 0xee, 64);
          nvn_tf_gather g = {src.gpuAddress, gd.gpuAddress, mp.gpuAddress, 2, 5}; memcpy(gj.contents, &g, sizeof g);
          id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
          [ce setComputePipelineState:gp]; [ce setBuffer:gj offset:0 atIndex:0]; for (id<MTLBuffer> u in @[src, gd, mp]) [ce useResource:u usage:MTLResourceUsageRead | MTLResourceUsageWrite];
          [ce dispatchThreads:MTLSizeMake(8, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
          uint32_t *o = gd.contents, w4[11] = {20, 21, 0, 1, 20, 21, 30, 31, 10, 11, 0xeeeeeeeeu}; int ok = !memcmp(o, w4, sizeof w4);
          CHECK(ok, "④ 收集按顺序表排记录（实得 %u %u %u %u %u %u %u %u %u %u %#x）", o[0], o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10]); } }
    printf("%s t_geo_tf\n", fail ? "✗" : "✓"); return fail;
} }

// S2Arm tessellation: 最小三角patch单测（Metal 4 与 Metal 3 两路）
// 一个三角patch（P=3控制点），已知曲面因子 → 验证点数/索引数，Metal 4 与 NXGAL_BE=mtl3 两路
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include "../gfx/nvn/nvn_builtin.h"
static int fail;
#define CHECK(c, ...) do { printf("%s ", (c) ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); if (!(c)) fail = 1; } while (0)

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("✗ 没有 Metal 设备\n"); return 1; }

    // 编译固定细分核（count / scan / emit）
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:nvn_tess_msl() options:nil error:&e];   // 与生产 tess_init 同一份拼法
    if (!lib) { printf("✗ 细分核编不过：%s\n", e.localizedDescription.UTF8String); return 1; }

    id<MTLComputePipelineState> count_pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nvn_tess_count"] error:&e];
    id<MTLComputePipelineState> scan_pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nvn_tess_scan"] error:&e];
    id<MTLComputePipelineState> emit_pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nvn_tess_emit"] error:&e];
    if (!count_pso || !scan_pso || !emit_pso) {
        printf("✗ PSO 创建失败：%s\n", e.localizedDescription.UTF8String); return 1;
    }

    // 用例：三角域（dom=0+1=1→三角，dm编码从1起）、整数分区（part=0+1=1）、逆时针三角（prim=3）、三个外因子=[4,4,4]、内因子=2
    // 期望（D3D11 三角域整数分区，手算）：外环每边 4 段 → 边界点 3×4 = 12；内部因子 2 → 只有一层，内环收成 1 个中心点 → 点数 13；
    //   外环 12 段各与中心点成三角 → 12 个三角形 → 索引数 36
    uint32_t dom = 2, part = 1, prim = 3;   // 三角、整数、逆时针
    __fp16 factors[4] = {4.0, 4.0, 4.0, 2.0};   // 外3+内1
    uint32_t fstride = 8;   // 三角8字节（4×half）
    uint32_t pt_cap = 1u << 20, ix_cap = 1u << 22;

    // 参数
    struct { uint32_t npatch, dom, part, prim, pt_cap, ix_cap, fstride, pad; } params = {1, dom, part, prim, pt_cap, ix_cap, fstride, 0};
    id<MTLBuffer> params_buf = [dev newBufferWithLength:sizeof(params) options:0];
    memcpy(params_buf.contents, &params, sizeof(params));

    id<MTLBuffer> factors_buf = [dev newBufferWithLength:8 options:0];
    memcpy(factors_buf.contents, factors, 8);

    id<MTLBuffer> cnt_buf = [dev newBufferWithLength:8 options:0];
    id<MTLBuffer> off_buf = [dev newBufferWithLength:8 options:0];
    id<MTLBuffer> args_buf = [dev newBufferWithLength:32 options:0];
    id<MTLBuffer> pts_buf = [dev newBufferWithLength:16 * 64 options:0];   // 容量64点
    id<MTLBuffer> idx_buf = [dev newBufferWithLength:4 * 256 options:0];   // 容量256索引

    memset(cnt_buf.contents, 0, 8);
    memset(args_buf.contents, 0, 32);

    // Metal 4 路径
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];

    // count核
    [ce setComputePipelineState:count_pso];
    [ce setBuffer:params_buf offset:0 atIndex:0];
    [ce setBuffer:factors_buf offset:0 atIndex:1];
    [ce setBuffer:cnt_buf offset:0 atIndex:2];
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];

    // scan核
    [ce setComputePipelineState:scan_pso];
    [ce setBuffer:params_buf offset:0 atIndex:0];
    [ce setBuffer:cnt_buf offset:0 atIndex:2];
    [ce setBuffer:off_buf offset:0 atIndex:3];
    [ce setBuffer:args_buf offset:0 atIndex:4];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1024, 1, 1)];

    // emit核
    [ce setComputePipelineState:emit_pso];
    [ce setBuffer:params_buf offset:0 atIndex:0];
    [ce setBuffer:factors_buf offset:0 atIndex:1];
    [ce setBuffer:cnt_buf offset:0 atIndex:2];
    [ce setBuffer:off_buf offset:0 atIndex:3];
    [ce setBuffer:pts_buf offset:0 atIndex:5];
    [ce setBuffer:idx_buf offset:0 atIndex:6];
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];

    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    // 验证
    uint32_t *cnt = cnt_buf.contents;
    uint32_t *args = args_buf.contents;

    // 三角整数细分 outer=4 inner=2：外边每边5点（4段+1），三角形顶点共用 → 总点数 = 3×5 - 3 + 内层点数
    // 内部因子 2：内环退化为中心点（见上） → 13 点、12 三角、36 索引
    CHECK(cnt[0] == 13, "Metal 4: 点数应为13（实得 %u）", cnt[0]);
    CHECK(cnt[1] == 36, "Metal 4: 索引数应为36（实得 %u）", cnt[1]);
    CHECK(args[0] == 36, "Metal 4: 间接参数 indexCount 应为36（实得 %u）", args[0]);
    CHECK(args[1] == 1, "Metal 4: instanceCount 应为1（实得 %u）", args[1]);

    // 验证首个域点（u,v,w其中之一应为0或接近1，三角重心坐标 u+v+w=1）
    float *pt0 = pts_buf.contents;
    float sum = pt0[0] + pt0[1] + pt0[2];
    CHECK(sum > 0.99f && sum < 1.01f, "Metal 4: 首点重心和应为1（u=%g v=%g w=%g 和=%g）", pt0[0], pt0[1], pt0[2], sum);

    printf("%s t_tess_triangle\n", fail ? "✗" : "✓");
    return fail;
} }

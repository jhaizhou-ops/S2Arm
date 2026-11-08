// t_push.py 的 GPU 执行器：编给定 MSL 里的计算核 k，按例跑一遍（每例一行「位置 4 个 + s2a_push 4 个」），每例输出外推后的位置一行（%.9g）
// 用法：t_push_run <核 MSL> <例文件>
#import <Metal/Metal.h>
#include <stdio.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "用法：t_push_run <核 MSL> <例文件>\n"); return 2; }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *e = nil;
        NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&e];
        id<MTLLibrary> lib = src ? [dev newLibraryWithSource:src options:nil error:&e] : nil;
        id<MTLFunction> fn = [lib newFunctionWithName:@"k"];
        id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&e] : nil;
        if (!ps) { fprintf(stderr, "【红】编核失败：%s\n", e.localizedDescription.UTF8String); return 1; }
        FILE *f = fopen(argv[2], "r"); if (!f) { fprintf(stderr, "【红】读不到例文件\n"); return 1; }
        float p[256][4], q[256][4]; int n = 0;
        while (n < 256 && fscanf(f, "%f %f %f %f %f %f %f %f", &p[n][0], &p[n][1], &p[n][2], &p[n][3], &q[n][0], &q[n][1], &q[n][2], &q[n][3]) == 8) n++;
        fclose(f);
        id<MTLBuffer> bp = [dev newBufferWithBytes:p length:sizeof(float) * 4 * n options:MTLResourceStorageModeShared];
        id<MTLBuffer> bq = [dev newBufferWithBytes:q length:sizeof(float) * 4 * n options:MTLResourceStorageModeShared];
        id<MTLBuffer> bo = [dev newBufferWithLength:sizeof(float) * 4 * n options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> cq = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps]; [ce setBuffer:bp offset:0 atIndex:0]; [ce setBuffer:bq offset:0 atIndex:1]; [ce setBuffer:bo offset:0 atIndex:2];
        [ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const float *o = bo.contents;
        for (int i = 0; i < n; i++) printf("%.9g %.9g %.9g %.9g\n", o[4 * i], o[4 * i + 1], o[4 * i + 2], o[4 * i + 3]);
    }
    return 0;
}

// 单测 t_m3pso：Metal 3 管线编译（卡 M3-8 / #115；gal_be.h 表中「管线与归档」「管线特化」两行）。
// 同一台 Mac 上按后端各起子进程（nxgal_init 是单例），期望全部手算：
//   ① NXGAL_BE=mtl3：pso_desc 出 MTLRenderPipelineDescriptor，颜色 / 采样 / 拓扑 / a2c / a2one / 顶点描述符逐项与状态对应；
//      gal_pso_can_specialize() 为假；5 个只差写掩码的管线键全建成，「管线现建」正好 5 行（每条 1 行，不静默）；
//      反证：库里没有的片元函数 → 描述建不出；没有顶点函数的描述 → gal_new_render_pso 返回空且带错误（断言不是摆设）。
//   ② NXGAL_BE=mtl3 的异步口径：gal_new_render_pso_async 走老 completionHandler，取用时照记「管线现建」（1 行，带「异步」）。
//   ③ 不设 NXGAL_BE：pso_desc 出 Metal 4 描述（respondsToSelector 区分），特化计数增加 —— Metal 4 主路径没被改坏。
#import "../gal_internal.h"
#import "../gal_draw_internal.h"
#include "../gal_formats.h"
#include "fixture.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>

GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）：程序里的函数描述是 Metal 4 形态

// gal_state.m 单测钩子：按当前 GAL 状态 + 程序出管线描述（不建管线）
id nxgal_test_pso_desc(const gal_prog *pg, int32_t unspec);

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// 顶点 / 片元：顶点读两个 stage_in 属性（属性 0/1 → 缓冲槽 GAL_VB_BASE），片元原样输出
static const char *k_msl =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VIn { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };\n"
"struct VOut { float4 pos [[position]]; float2 uv; };\n"
"vertex VOut vs_main(VIn in [[stage_in]]) { VOut o; o.pos = float4(in.pos, 0.0, 1.0); o.uv = in.uv; return o; }\n"
"fragment float4 fs_main(VOut in [[stage_in]]) { return float4(in.uv, 0.0, 1.0); }\n"
"kernel void cs_main(device uint *o [[buffer(0)]], uint gid [[thread_position_in_grid]]) { o[gid] = gid; }\n";

// 造一条「程序」：函数描述（库 + 名）+ 两个顶点输入属性 + 一张 RGBA8 渲染目标；成功返回 1
static int pso_fixture(gal_prog *pg, uint32_t *rt) {
    memset((void *)pg, 0, sizeof *pg);
    NSError *e = nil;
    id<MTLLibrary> lib = fx_lib(g_gdev, @"m3pso", @(k_msl), &e);
    if (!lib) { printf("  ✗ 建着色器库失败：%s\n", e.localizedDescription.UTF8String); return 0; }
    pg->hash = 0x0000011500000001ull;
    pg->fn[1] = gal_be_fn_desc(lib, @"vs_main");
    pg->fn[5] = gal_be_fn_desc(lib, @"fs_main");
    pg->vs_inputs = 0x3;   // 属性 0、1
    pg->fs_outputs = 1;
    pg->live = 1;
    nxgal_tex_info ri = {64, 64, 1, 1, 1, 1, 1, 4, 36, 0, 1, {2, 3, 4, 5}};   // 36 = GAL RGBA8
    *rt = nxgal_tex_create(&ri);
    if (!*rt) { printf("  ✗ 建渲染目标失败\n"); return 0; }
    nxgal_set_render_targets(rt, 1, 0);
    nxgal_vattr a[2] = {{0, 0, 0, F_R32G32Float}, {0, 8, 0, F_R32G32Float}};
    nxgal_set_vertex_attribs(a, 2);
    nxgal_vbuf vb; memset(&vb, 0, sizeof vb); vb.stride = 16;
    nxgal_set_vertex_buffers(&vb, 1);
    return 1;
}

static int run_m3(void) {
    CHECK(gal_be_kind() == GAL_BE_MTL3, "后端 %d ≠ Metal 3", gal_be_kind());
    CHECK(gal_pso_can_specialize() == 0, "Metal 3 下 gal_pso_can_specialize 应为假，实得 %d", gal_pso_can_specialize());
    gal_prog pg; uint32_t rt = 0;
    if (!pso_fixture(&pg, &rt)) return 2;
    // 状态：三角形、混合开（Add / One / Zero）、写掩码 RGB、a2c + a2one 开
    nxgal_set_topology(4);
    nxgal_blend b; memset(&b, 0, sizeof b); b.enable = 1; b.color_op = b.alpha_op = 1; b.color_src = b.alpha_src = 2; b.color_dst = b.alpha_dst = 1;
    nxgal_set_blend(0, &b);
    uint32_t mask = 0x7;
    nxgal_set_color_masks(&mask, 1);
    nxgal_set_multisample(1, 0, 1);
    id d = nxgal_test_pso_desc(&pg, 0);
    CHECK(d != nil, "Metal 3：pso_desc 返回空");
    CHECK([d isKindOfClass:[MTLRenderPipelineDescriptor class]], "Metal 3：描述类 %s 不是 MTLRenderPipelineDescriptor", d ? class_getName([d class]) : "空");
    CHECK([d respondsToSelector:@selector(vertexFunction)], "Metal 3：描述没有 vertexFunction（函数没按名取）");
    if (d) {
        MTLRenderPipelineDescriptor *r = d;
        CHECK(r.rasterizationEnabled, "Metal 3：rasterizationEnabled 应为 YES");
        CHECK(r.rasterSampleCount == 1, "Metal 3：rasterSampleCount %lu ≠ 1", (unsigned long)r.rasterSampleCount);
        CHECK(r.inputPrimitiveTopology == MTLPrimitiveTopologyClassTriangle, "Metal 3：拓扑类 %lu ≠ 三角形", (unsigned long)r.inputPrimitiveTopology);
        CHECK(r.alphaToCoverageEnabled, "Metal 3：alphaToCoverageEnabled 应为 YES");
        CHECK(r.alphaToOneEnabled, "Metal 3：alphaToOneEnabled 应为 YES");
        MTLRenderPipelineColorAttachmentDescriptor *c = r.colorAttachments[0];
        CHECK(c.pixelFormat == MTLPixelFormatRGBA8Unorm, "Metal 3：颜色 0 格式 %lu ≠ RGBA8", (unsigned long)c.pixelFormat);
        CHECK(c.writeMask == (MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue), "Metal 3：写掩码 %lx ≠ RGB", (unsigned long)c.writeMask);
        CHECK(c.blendingEnabled, "Metal 3：混合没开");
        CHECK(c.rgbBlendOperation == MTLBlendOperationAdd && c.sourceRGBBlendFactor == MTLBlendFactorOne && c.destinationRGBBlendFactor == MTLBlendFactorZero,
              "Metal 3：混合参数（Add/One/Zero）不符");
        MTLVertexDescriptor *vd = r.vertexDescriptor;
        CHECK(vd != nil, "Metal 3：顶点描述符为空");
        if (vd) {
            CHECK(vd.attributes[0].format == MTLVertexFormatFloat2 && vd.attributes[0].offset == 0 && vd.attributes[0].bufferIndex == GAL_VB_BASE,
                  "Metal 3：属性 0（格式 %lu 偏移 %lu 槽 %lu）不符", (unsigned long)vd.attributes[0].format, (unsigned long)vd.attributes[0].offset, (unsigned long)vd.attributes[0].bufferIndex);
            CHECK(vd.attributes[1].format == MTLVertexFormatFloat2 && vd.attributes[1].offset == 8 && vd.attributes[1].bufferIndex == GAL_VB_BASE,
                  "Metal 3：属性 1（格式 %lu 偏移 %lu 槽 %lu）不符", (unsigned long)vd.attributes[1].format, (unsigned long)vd.attributes[1].offset, (unsigned long)vd.attributes[1].bufferIndex);
            CHECK(vd.layouts[GAL_VB_BASE].stepFunction == MTLVertexStepFunctionPerVertex && vd.layouts[GAL_VB_BASE].stepRate == 1,
                  "Metal 3：槽 %d 步进（%lu / %lu）≠ 每顶点 / 1", GAL_VB_BASE, (unsigned long)vd.layouts[GAL_VB_BASE].stepFunction, (unsigned long)vd.layouts[GAL_VB_BASE].stepRate);
        }
        CHECK(nxgal_test_pso_desc(&pg, 1) == nil, "Metal 3：unspec（基础管线）请求应返回空（没有特化层）");
    }
    // 5 个只差写掩码的键：全建成，且「管线现建」每条 1 行（父进程数行）
    nxgal_set_multisample(0, 0, 0);
    const uint32_t masks[5] = {0xf, 0x7, 0x3, 0x1, 0xe};
    for (int i = 0; i < 5; i++) {
        nxgal_set_color_masks(&masks[i], 1);
        id<MTLRenderPipelineState> p = gal_pso_get(&pg, NULL, NULL);
        CHECK(p != nil, "Metal 3：第 %d 条管线（写掩码 %#x）建不出", i, masks[i]);
    }
    CHECK(gal_pso_count() == 5, "Metal 3：管线表 %d 条 ≠ 5", gal_pso_count());
    // 反证 1：库里没有的片元函数 → 描述建不出（不是静默给一条空片元管线）
    gal_prog bad = pg; bad.fn[5] = gal_be_fn_desc(pg.fn[5].library, @"fs_missing");
    CHECK(nxgal_test_pso_desc(&bad, 0) == nil, "Metal 3：缺片元函数时描述应返回空");
    // 反证 2：没有顶点函数的描述 → gal_new_render_pso 返回空并带错误
    NSError *e = nil; id<MTLRenderPipelineState> nilp = gal_new_render_pso((id)[MTLRenderPipelineDescriptor new], &e);
    CHECK(nilp == nil && e != nil, "Metal 3：空描述应建失败（有管线 %d，有错误 %d）", nilp != nil, e != nil);
    // 计算：gal_be_compute_desc 出的 Metal 4 形态描述，Metal 3 要转成 MTLFunction + MTLComputePipelineDescriptor 再建（照记「管线现建：计算」）
    NSError *ce = nil;
    id<MTLComputePipelineState> cp = gal_new_compute_pso((id)gal_be_compute_desc(gal_be_fn_desc(pg.fn[1].library, @"cs_main"), nil), &ce);
    CHECK(cp != nil, "Metal 3：计算管线建不出（%s）", ce.localizedDescription.UTF8String);
    // 反证 3：库里没有的计算函数 → 空，不静默建一条
    NSError *ce2 = nil;
    CHECK(gal_new_compute_pso((id)gal_be_compute_desc(gal_be_fn_desc(pg.fn[1].library, @"cs_missing"), nil), &ce2) == nil && ce2 != nil,
          "Metal 3：缺计算函数应建失败");
    printf("  · 后端 %d；可特化 %d；管线表 %d 条\n", gal_be_kind(), gal_pso_can_specialize(), gal_pso_count());
    return g_fail ? 1 : 0;
}

// 真 GPU 编码：同一颜色 / 程序依次切换无附件、深度、模板、深度模板；每种格式必须独立建管线。
static int run_m3_ds(void) {
    gal_prog pg; uint32_t rt = 0;
    if (!pso_fixture(&pg, &rt)) return 2;
    nxgal_set_topology(4);
    const int fmts[] = {F_D32Float, F_S8Uint, F_D32FloatS8Uint};
    const MTLPixelFormat wantd[] = {MTLPixelFormatDepth32Float, MTLPixelFormatInvalid, MTLPixelFormatDepth32Float_Stencil8};
    const MTLPixelFormat wants[] = {MTLPixelFormatInvalid, MTLPixelFormatStencil8, MTLPixelFormatDepth32Float_Stencil8};
    id<MTLRenderPipelineState> first = gal_pso_get(&pg, NULL, NULL);
    CHECK(first != nil, "无深度模板管线建成");
    id<MTLCommandQueue> q = [g_gdev newCommandQueue];
    id<MTLBuffer> vb = [g_gdev newBufferWithLength:48 options:MTLResourceStorageModeShared];
    const float verts[] = {-1,-1,1,0, 3,-1,1,0, -1,3,1,0};
    memcpy(vb.contents, verts, sizeof verts);
    for (int i = 0; i < 3; i++) {
        nxgal_tex_info di = {64,64,1,1,1,1,1,8,fmts[i],0,1,{2,3,4,5}};
        uint32_t ds = nxgal_tex_create(&di);
        CHECK(ds != 0, "附件 %d 创建成功", i);
        if (!ds) continue;
        nxgal_set_render_targets(&rt, 1, ds);
        MTLRenderPipelineDescriptor *d = nxgal_test_pso_desc(&pg, 0);
        CHECK(d.depthAttachmentPixelFormat == wantd[i], "附件 %d 深度格式 %lu ≠ %lu", i, (unsigned long)d.depthAttachmentPixelFormat, (unsigned long)wantd[i]);
        CHECK(d.stencilAttachmentPixelFormat == wants[i], "附件 %d 模板格式 %lu ≠ %lu", i, (unsigned long)d.stencilAttachmentPixelFormat, (unsigned long)wants[i]);
        id<MTLRenderPipelineState> p = gal_pso_get(&pg, NULL, NULL);
        CHECK(p != nil && p != first, "附件 %d 必须使用不同于无附件的管线", i);
        CHECK(gal_pso_get(&pg, NULL, NULL) == p, "附件 %d 相同键命中原管线", i);
        if (!p) continue;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = gal_tex_get(rt)->tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (wantd[i]) { rp.depthAttachment.texture = gal_tex_get(ds)->tex; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare; }
        if (wants[i]) { rp.stencilAttachment.texture = gal_tex_get(ds)->tex; rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.storeAction = MTLStoreActionDontCare; }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:p];
        [enc setVertexBuffer:vb offset:0 attributeStride:16 atIndex:GAL_VB_BASE];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        id<MTLBuffer> read = [g_gdev newBufferWithLength:64*64*4 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:gal_tex_get(rt)->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,64,1) toBuffer:read destinationOffset:0 destinationBytesPerRow:64*4 destinationBytesPerImage:64*64*4];
        [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted && cb.error == nil, "附件 %d GPU 提交成功：%s", i, cb.error.localizedDescription.UTF8String);
        const uint8_t *pixels = read.contents;
        CHECK(pixels[(32*64+32)*4] == 255, "附件 %d 中心像素红值 %u ≠ 255", i, pixels[(32*64+32)*4]);
    }
    nxgal_set_render_targets(&rt, 1, 0);
    CHECK(gal_pso_get(&pg, NULL, NULL) == first, "去掉附件后恢复原无附件管线");
    CHECK(gal_pso_count() == 4, "4 类附件键应有 4 条管线，实得 %d", gal_pso_count());
    return g_fail ? 1 : 0;
}

static int run_m3_async(void) {
    CHECK(gal_be_kind() == GAL_BE_MTL3, "后端 %d ≠ Metal 3", gal_be_kind());
    gal_prog pg; uint32_t rt = 0;
    if (!pso_fixture(&pg, &rt)) return 2;
    nxgal_set_topology(4);
    uint32_t mask = 0xf; nxgal_set_color_masks(&mask, 1);
    id d = nxgal_test_pso_desc(&pg, 0);
    CHECK(d != nil, "Metal 3 异步：描述为空");
    id<MTLRenderPipelineState> hit = nil;
    gal_pso_job *j = gal_new_render_pso_async(d, &hit);
    CHECK(j != NULL && hit == nil, "Metal 3 异步：应立即给作业（有作业 %d，有命中 %d）", j != NULL, hit != nil);
    if (!j) return 1;
    id<MTLRenderPipelineState> p = gal_pso_job_wait(j);
    CHECK(p != nil, "Metal 3 异步：等取管线为空");
    return g_fail ? 1 : 0;
}

static int run_m4(void) {
    CHECK(gal_be_kind() == GAL_BE_MTL4, "后端 %d ≠ Metal 4", gal_be_kind());
    CHECK(gal_pso_can_specialize() == 1, "Metal 4 下 gal_pso_can_specialize 应为真，实得 %d", gal_pso_can_specialize());
    gal_prog pg; uint32_t rt = 0;
    if (!pso_fixture(&pg, &rt)) return 2;
    nxgal_set_topology(4);
    uint32_t mask = 0xf; nxgal_set_color_masks(&mask, 1);
    nxgal_blend off; memset(&off, 0, sizeof off); off.color_op = off.alpha_op = 1; off.color_src = off.alpha_src = 2; off.color_dst = off.alpha_dst = 1;
    nxgal_set_blend(0, &off);
    id d = nxgal_test_pso_desc(&pg, 0);
    CHECK(d != nil, "Metal 4：pso_desc 返回空");
    CHECK(d && ![d isKindOfClass:[MTLRenderPipelineDescriptor class]], "Metal 4：描述不该是 Metal 3 的 MTLRenderPipelineDescriptor");
    CHECK(d && [d respondsToSelector:@selector(vertexFunctionDescriptor)], "Metal 4：描述没有 vertexFunctionDescriptor");
    uint64_t s0 = gal_pso_spec_count();
    id<MTLRenderPipelineState> p = gal_pso_get(&pg, NULL, NULL);
    CHECK(p != nil, "Metal 4：基础管线 + 特化建不出");
    CHECK(gal_pso_spec_count() > s0, "Metal 4：没有走特化（计数 %llu → %llu）", (unsigned long long)s0, (unsigned long long)gal_pso_spec_count());
    printf("  · 后端 %d；可特化 %d；特化计数 %llu\n", gal_be_kind(), gal_pso_can_specialize(), (unsigned long long)gal_pso_spec_count());
    return g_fail ? 1 : 0;
}

static int run_child(const char *mode) {
    if (nxgal_init(0)) { printf("初始化失败\n"); return 3; }
    int rc;
    @autoreleasepool {
        if (!strcmp(mode, "m3")) rc = run_m3();
        else if (!strcmp(mode, "m3async")) rc = run_m3_async();
        else if (!strcmp(mode, "m3ds")) rc = run_m3_ds();
        else rc = run_m4();
    }
    printf("%s：%d / %d 项通过\n", rc ? "失败" : "通过", g_checks - g_fail, g_checks);
    return rc;
}

// ---------- 父进程：起子进程、原样抄日志、按期望核后端 / 行数 ----------
static int count_sub(const char *s, const char *sub) {
    int n = 0; size_t l = strlen(sub);
    for (const char *p = s; (p = strstr(p, sub)); p += l) n++;
    return n;
}

static void run_case(const char *title, const char *be, const char *mode, int idx, int want_builds, int want_compute, int want_async) {
    printf("· %s\n", title);
    char self[4096]; uint32_t sz = sizeof self;
    if (_NSGetExecutablePath(self, &sz)) { g_checks++; g_fail++; printf("  ✗ 取本可执行文件路径失败\n"); return; }
    char log[4096]; snprintf(log, sizeof log, "%s/t_m3pso_%d.log", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", idx);
    int fd = open(log, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd < 0) { g_checks++; g_fail++; printf("  ✗ 建日志失败：%s\n", log); return; }
    pid_t pid = fork();
    if (pid == 0) {
        dup2(fd, 1); dup2(fd, 2); close(fd);
        if (be) setenv("NXGAL_BE", be, 1); else unsetenv("NXGAL_BE");
        unsetenv("NXGAL_PSO_ASYNC"); unsetenv("NXGAL_PSO_SPECIALIZE");
        execl(self, self, "--child", mode, (char *)NULL);
        _exit(127);
    }
    close(fd);
    int st = 0; waitpid(pid, &st, 0);
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
    char all[65536] = {0}; size_t tot = 0; FILE *f = fopen(log, "r");
    if (f) { size_t n; while ((n = fread(all + tot, 1, sizeof all - 1 - tot, f)) > 0) tot += n; all[tot] = 0; fclose(f); }
    unlink(log);
    int nb = count_sub(all, "管线现建：顶点");
    int nc = count_sub(all, "管线现建：计算");
    int has_async = strstr(all, "异步）") != NULL;
    { char *p = all, *q; while (p && *p) { if ((q = strchr(p, '\n'))) *q = 0; printf("    %s\n", p); p = q ? q + 1 : NULL; } }
    CHECK(code == 0, "子进程退出码 %d（期望 0）", code);
    if (be && !strcmp(be, "mtl3")) CHECK(strstr(all, "后端：Metal 3（强制）") != NULL, "日志缺「后端：Metal 3（强制）」一行");
    CHECK(nb == want_builds, "「管线现建：顶点」%d 行 ≠ 手算 %d 行", nb, want_builds);
    CHECK(nc == want_compute, "「管线现建：计算」%d 行 ≠ 手算 %d 行", nc, want_compute);
    if (want_async) CHECK(has_async, "异步现建的行没有「异步」标注");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc >= 3 && !strcmp(argv[1], "--child")) return run_child(argv[2]);
    // 强制 Metal 3：5 条同步现建各 1 行；异步：1 行；Metal 4：基础管线 1 行（特化不计现建）
    run_case("NXGAL_BE=mtl3：完整描述、无特化、5 条管线键", "mtl3", "m3", 1, 5, 1, 0);
    run_case("NXGAL_BE=mtl3：异步现建（老 completionHandler）", "mtl3", "m3async", 2, 1, 0, 1);
    run_case("NXGAL_BE=mtl3：深度 / 模板附件与 GPU 绘制", "mtl3", "m3ds", 4, 4, 0, 0);
    run_case("不设 NXGAL_BE：Metal 4 主路径（基础管线 + 特化）", NULL, "m4", 3, 1, 0, 0);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}

GAL_MTL4_ZONE_END

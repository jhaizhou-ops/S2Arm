// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 分离的贴图 / 采样器句柄在两个统一缓冲里：11-06 文明6（010044500C182000）开场动画与菜单整屏黑。
//   游戏用 nvnDeviceGetSeparateTextureHandle / SamplerHandle，贴图号放统一缓冲槽 13、采样器句柄（号 << 20）放槽 12；着色器 OR 两个字，
//   Ryujinx 把它记成名字 fp_t_cb1114127_10010000：slots 0x11000F → 纹理缓冲 c15（槽 12）、采样器缓冲 c16（槽 13）；句柄 0x10010000 → 类型 1、
//   纹理字 o0 = 0（字节 0）、采样器字 o1 = 4（字节 16）。Ryujinx ReadPackedId 两个字都读、OR 起来再取低 20 位当贴图号，哪个字放贴图号无所谓；
//   宿主原先只读「纹理半边」（槽 12 字节 0 = 0x10200000），低 20 位 0 → 贴图号 0 → 空描述 → 全读 0。
// 期望（按 Ryujinx TextureHandle / ReadPackedId 手算，与被测实现无关）：
//   ① 反射：tex_ubo{槽 12, 偏移 0} 的另一半 = 槽 13 字节 16；samp_ubo{槽 13, 偏移 16} 的另一半 = 槽 12 字节 0
//   ② 槽 12 字节 0 = 0x10200000、槽 13 字节 16 = 9（A：4×4 全 7.0）：读 A(0,0) → 7.0（旧代码：贴图号 0，读 0.0）
//   ③ 同一句柄的采样器号 = (9 | 0x10200000) >> 20 = 0x102（旧代码：只读槽 13 的 9 → 0）
//   ④ 缓冲纹理（tbuf_ubo，同名同布局）：槽 13 字节 16 = 11（B：元素 i = 2i）→ read(2) = 4.0（旧代码：贴图号 0，读 0.0）
//   ⑤ 对照：组合句柄名 fp_t_cb15_0（类型 0，一个字）→ 不配另一半；槽 12 字节 0 = 9 | 0x102 << 20 → 读 A = 7.0（新旧都对）
// 反证：把 ubo_packed 里 OR 另一半那行删掉 → ② ③ ④ 红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { MEM = 1 << 20, U12 = 0x40000, U13 = 0x41000, OUT_OFF = 0x50000, TBUF_OFF = 0x60000 };
static uint8_t *memory, *tmem; static pool_t *pool, *tpool;

// mode 0：texture2d + Smplr（名 nm）；mode 1：texture_buffer（名 nm）。反射 + 派发一次，回读 out[0].x；rb：反射出的绑定
static float run(int mode, NSString *nm, int soff, nvn_rbind *rb, int *nb) {
    NSError *e = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion2_3;
    NSString *src = mode == 0
        ? [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct Args { texture2d<float> %@ [[id(0)]]; sampler %@Smplr [[id(1)]]; device float4 *fp_s0 [[id(2)]]; };\n"
            "kernel void rd(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.fp_s0[0] = a.%@.read(uint2(0, 0)); }\n", nm, nm, nm]
        : [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct Args { texture_buffer<float> %@ [[id(0)]]; device float4 *fp_s0 [[id(1)]]; };\n"
            "kernel void rd(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.fp_s0[0] = a.%@.read(2u); }\n", nm, nm];
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:o error:&e]; if (!lib) fprintf(stderr, "MSL: %s\n", e.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"rd"]; REQUIRE(cs->fn);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
    NSDictionary *out_b = @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @2, @"rw": @YES, @"msl_name": @"fp_s0", @"msl_type": @"device float4*" };
    NSArray *binds = mode == 0
        ? @[ @{ @"kind": @"tex_ubo", @"reg": @12, @"off": @0, @"arg_id": @0, @"msl_name": nm, @"msl_type": @"texture2d<float>" },
             @{ @"kind": @"samp_ubo", @"reg": @(soff < 0 ? 12 : 13), @"off": @(soff < 0 ? 0 : soff), @"arg_id": @1, @"msl_name": [nm stringByAppendingString:@"Smplr"], @"msl_type": @"sampler" }, out_b ]
        : @[ @{ @"kind": @"tbuf_ubo", @"reg": @12, @"off": @0, @"arg_id": @0, @"msl_name": nm, @"msl_type": @"texture_buffer<float>" },
             @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @1, @"rw": @YES, @"msl_name": @"fp_s0", @"msl_type": @"device float4*" } ];
    NSDictionary *refl = @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": binds };
    char err[512] = ""; int rc = nvn_refl_from_json(refl, &cs->rf, err, sizeof err);
    if (rc) { fprintf(stderr, "refl: %s\n", err); REQUIRE(!rc); }
    *nb = cs->rf.nb; for (int i = 0; i < cs->rf.nb && i < 3; i++) rb[i] = cs->rf.b[i];
    prog_t pg; memset(&pg, 0, sizeof pg); pg.magic = MAGIC('P', 'R', 'O', 'G'); pg.serial = nvn_new_serial();
    NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(pg.serial, np);
    float *out = (float *)(memory + OUT_OFF); for (int i = 0; i < 4; i++) out[i] = -1;
    nvn_be_sub_begin();
    S.tex_base = 0; S.samp_base = 0;
    S.ubo[5][12] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(memory + U12), .size = 256};
    S.ubo[5][13] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(memory + U13), .size = 256};
    S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)out, .size = 16};
    S.cprog = &pg; args_dirty_all();
    p_dispatch d = {.x = 1, .y = 1, .z = 1}; dispatch(&d);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    return out[0];
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mtl_init();
    REQUIRE(!posix_memalign((void **)&memory, 65536, MEM)); memset(memory, 0, MEM);
    REQUIRE(!posix_memalign((void **)&tmem, 65536, MEM)); memset(tmem, 0, MEM);
    pool = calloc(1, sizeof *pool); tpool = calloc(1, sizeof *tpool); REQUIRE(pool && tpool);   // 活到进程结束：生产池是不拷贝的 MTLBuffer
    *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = MEM};
    *tpool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = tmem, .size = MEM};
    nvn_be_pool_add(memory, MEM); nvn_be_pool_add(tmem, MEM);
    // 贴图 A：4×4 RGBA32F，经 Metal 填 7.0（不碰客体内存，免得被当 CPU 写过的贴图重传），登记成贴图号 9
    static tex_t A, B; memset(&A, 0, sizeof A); A.magic = MAGIC('T', 'E', 'X', 0); A.serial = nvn_new_serial();
    A.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA32F, .width = 4, .height = 4, .depth = 1, .levels = 1};
    A.pool = tpool; A.off = 0; A.mem = tmem; nvn_tex_layout(&A.d, &A.L); nvn_be_tex_init(&A);
    id<MTLTexture> am = tex_mtl(&A); REQUIRE(am);
    { id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; float *f = b.contents; for (int i = 0; i < 64; i++) f[i] = 7.0f;
      id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> en = [cb blitCommandEncoder];
      [en copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:64 sourceBytesPerImage:256 sourceSize:MTLSizeMake(4, 4, 1) toTexture:am destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
      [en endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted); }
    nvn_be_reg_tex(9, &A, NULL);
    // 缓冲纹理 B：16 个 R32F，元素 i = 2i，登记成贴图号 11
    { float *v = (float *)(memory + TBUF_OFF); for (int i = 0; i < 16; i++) v[i] = 2.0f * i;
      memset(&B, 0, sizeof B); B.magic = MAGIC('T', 'E', 'X', 0); B.serial = nvn_new_serial();
      B.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = 16, .height = 1, .depth = 1, .levels = 1};
      B.pool = pool; B.off = TBUF_OFF; B.mem = pool->mem + TBUF_OFF; nvn_tex_layout(&B.d, &B.L); nvn_be_tex_init(&B); nvn_be_reg_tex(11, &B, NULL); }
    uint32_t *u12 = (uint32_t *)(memory + U12), *u13 = (uint32_t *)(memory + U13);
    nvn_rbind rb[3]; int nb = 0;
    NSString *SEP = @"fp_t_cb1114127_10010000";

    // 分离句柄：槽 12 字节 0 = 采样器句柄 0x102 << 20，槽 13 字节 16 = 贴图号 9
    u12[0] = 0x102u << 20; u13[4] = 9;
    float v = run(0, SEP, 16, rb, &nb);
    VERIFY(nb == 3 && rb[0].kind == NVN_RB_TEXU && rb[0].pair && rb[0].pair_reg == 13 && rb[0].pair_off == 16 && rb[1].kind == NVN_RB_SAMPU && rb[1].pair && rb[1].pair_reg == 12 && rb[1].pair_off == 0,
           "① 反射另一半：贴图项 pair %u 槽 %u 字节 %u（期望 1 / 13 / 16），采样器项 pair %u 槽 %u 字节 %u（期望 1 / 12 / 0）",
           rb[0].pair, rb[0].pair_reg, rb[0].pair_off, rb[1].pair, rb[1].pair_reg, rb[1].pair_off);
    VERIFY(v == 7.0f, "② 贴图号在槽 13、采样器句柄在槽 12 → 读到 A = %.1f（期望 7.0；只读槽 12 是贴图号 0、读 0.0）", v);
    pthread_mutex_lock(&g_rmu); int sid = bind_sid(&rb[1], 5); pthread_mutex_unlock(&g_rmu);
    VERIFY(sid == 0x102, "③ 同一句柄的采样器号 = %#x（期望 0x102 = (9 | 0x10200000) >> 20；只读槽 13 是 0）", sid);

    // 缓冲纹理，同名同布局：槽 13 字节 16 = 贴图号 11
    u13[4] = 11;
    v = run(1, SEP, 0, rb, &nb);
    VERIFY(rb[0].kind == NVN_RB_TBUFU && rb[0].pair && v == 4.0f, "④ 缓冲纹理（tbuf_ubo）：pair %u，读到 B[2] = %.1f（期望 1 / 4.0；只读槽 12 是贴图号 0、读 0.0）", rb[0].pair, v);

    // 对照：组合句柄（类型 0）一个字、没有另一半
    memset(memory + U12, 0, 256); memset(memory + U13, 0, 256); u12[0] = 9u | 0x102u << 20;
    v = run(0, @"fp_t_cb15_0", -1, rb, &nb);
    VERIFY(!rb[0].pair && !rb[1].pair && v == 7.0f, "⑤ 对照：组合句柄 fp_t_cb15_0（9 | 0x102 << 20 在槽 12）→ pair %u / %u（期望 0 / 0），读到 %.1f（期望 7.0）", rb[0].pair, rb[1].pair, v);
    printf("%s t_nvn_sep_handle：%u 项，%u 项失败（分离贴图 / 采样器句柄按 Ryujinx ReadPackedId 两个字 OR 起来取号）\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }

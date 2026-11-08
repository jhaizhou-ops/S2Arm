// 句柄在统一缓冲里的存储图像（反射种类 img_ubo → NVN_RB_IMGU）：11-05 普查 c1105_mac2 无人深空（0100853015E86000）124 支计算 / 片元着色器
//   cp_i_cb3_260_ 等（texture2d<float, access::write>）出库时没有槽号，宿主「B binding … has no resolved slot number」整支拒载、没进局。
//   名字按 Ryujinx TextureHandle 拆：slots 3 → 句柄在 c3（NVN 统一缓冲槽 0）、没有采样器缓冲；句柄 0x260 → 类型 0、纹理字 o0 = 0x260（字节 0x980）。
//   Ryujinx 照 ReadPackedId 取那个字的低 20 位当纹理号、按图像绑那张纹理。
// 期望（按上面的语义手写，与被测实现无关）：
//   ① 反射 {kind img_ubo, reg 0, off 0, texture2d<float, access::write>} 转换成功：种类 IMGU、槽 0、偏移 0、可写、记成无绑定（bindless）
//   ② 真走编码路径（生产 nvn_mtl.m dispatch + 真 Metal 设备）：统一缓冲槽 0 字节 0 = 纹理号 9（A）| 高位残留 0x77 << 20；图像槽 0 放另一张 B（号 3）。
//      着色器往 (0, 0) 写 7.0 → 之后按普通纹理读回：A(0,0) = 7.0、B(0,0) 仍是初值 2.0（写进 B 说明按槽取了；都不变说明写进了占位图）
//   ③ 偏移生效：反射 off 16、统一缓冲字节 16 = 纹理号 5（C）→ C(0,0) = 7.0
// 反证（修前）：同一单测编改前的 nvn_refl.m / nvn_mtl.m → ① 报「B binding kind img_ubo not implemented」，②③ 跑不起来
// 11-07 无人深空人物白色光晕：聚光灯光源表 / 深度重投影三支片元着色器在这种图像上做原生贴图原子（Dsh.cs Reflect 标 atomic）。期望（按语义手写）：
//   ④ 反射 {kind img_ubo, reg 0, off 0, atomic, texture2d<uint, access::read_write>} 转换成功：IMGU、atomic_image 1、has_atomic_image 1
//   ⑤ 真走 dispatch：统一缓冲字节 32 = 纹理号 11（D，R32UI 全 100），图像槽 0 = 号 13（E，R32UI 全 200）；8 个线程各对 (0,0) atomic_fetch_add 1
//      → D(0,0) = 108、D(1,0) = 100、E(0,0) = 200；D 的底层存储带原子用法（img_atomic_prepare 按 img_tid 取到 D 并升级）
// 反证（11-07 修前）：④ 报「image atomics with the handle in a uniform buffer are not implemented」、⑤ 跑不起来；只撤 img_atomic_prepare 的 IMGU 分支 → ⑤ 底层原子用法 0
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { MEM = 1 << 20, UBO_OFF = 0x40000, OUT_OFF = 0x50000 };
static uint8_t *memory; static pool_t *pool;

static void image_texture(tex_t *t, int id, size_t off, float v) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_R32F, .width = 4, .height = 4, .depth = 1, .levels = 1, .flags = NVN_TEXTURE_FLAGS_IMAGE};
    t->pool = pool; t->off = off; t->mem = pool->mem + off; nvn_tex_layout(&t->d, &t->L); REQUIRE(t->L.size && off + t->L.size <= MEM);
    float *p = (float *)(memory + off); for (size_t i = 0; i < t->L.size / 4; i++) p[i] = v;   // R32F 每个字节组合都是同一个值：块线性排布不影响
    nvn_be_tex_init(t); nvn_be_reg_tex(id, t, NULL);
}
static void uint_texture(tex_t *t, int id, size_t off, uint32_t v) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_R32UI, .width = 4, .height = 4, .depth = 1, .levels = 1, .flags = NVN_TEXTURE_FLAGS_IMAGE};
    t->pool = pool; t->off = off; t->mem = pool->mem + off; nvn_tex_layout(&t->d, &t->L); REQUIRE(t->L.size && off + t->L.size <= MEM);
    uint32_t *p = (uint32_t *)(memory + off); for (size_t i = 0; i < t->L.size / 4; i++) p[i] = v;   // 每个字同一个值：块线性排布不影响
    nvn_be_tex_init(t); nvn_be_reg_tex(id, t, NULL);
}
static NvShader *shader(NSString *src, NSString *fn, NSDictionary *refl, int *rc, char *err, int errlen) {
    NSError *e = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion3_1;   // 3.1：贴图原生原子（④ ⑤）要它
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:[@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:src] options:o error:&e];
    REQUIRE(lib);
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:fn]; REQUIRE(cs->fn);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
    *rc = nvn_refl_from_json(refl, &cs->rf, err, errlen);
    return cs;
}
static void run_cs(NvShader *cs) {
    static prog_t pg; memset(&pg, 0, sizeof pg); pg.magic = MAGIC('P', 'R', 'O', 'G'); pg.serial = nvn_new_serial();
    NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(pg.serial, np);
    nvn_be_sub_begin();
    S.cprog = &pg; args_dirty_all();
    p_dispatch d = {.x = 1, .y = 1, .z = 1}; dispatch(&d);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
}
// 按普通纹理槽读回两张图的 (0, 0)：槽 0 = 号 a、槽 1 = 号 b
static void read_back(int a, int b, float out2[2]) {
    char err[256] = ""; int rc = 0;
    NvShader *rd = shader(@"struct Args { texture2d<float> fp_t_cb2_8 [[id(0)]]; texture2d<float> fp_t_cb2_A [[id(1)]]; device float4 *fp_s0 [[id(2)]]; };\n"
        "kernel void rd(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.fp_s0[0] = float4(a.fp_t_cb2_8.read(uint2(0)).x, a.fp_t_cb2_A.read(uint2(0)).x, 0, 0); }\n", @"rd",
        @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
            @{ @"kind": @"tex", @"reg": @0, @"arg_id": @0, @"msl_name": @"fp_t_cb2_8", @"msl_type": @"texture2d<float>" },
            @{ @"kind": @"tex", @"reg": @1, @"arg_id": @1, @"msl_name": @"fp_t_cb2_A", @"msl_type": @"texture2d<float>" },
            @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @2, @"rw": @YES, @"msl_name": @"fp_s0", @"msl_type": @"device float4*" } ] }, &rc, err, sizeof err);
    REQUIRE(rc == 0);
    float *out = (float *)(memory + OUT_OFF); for (int i = 0; i < 4; i++) out[i] = -1;
    S.tex[5][0] = (uint32_t)a; S.tex[5][1] = (uint32_t)b;
    S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)out, .size = 16};
    run_cs(rd);
    out2[0] = out[0]; out2[1] = out[1];
}
// 反射 off 不同的同一支写图着色器 → 派发一次；rc 非 0 = 反射没转成
static int write_img(int off, char *err, int errlen, int check_refl) {
    int rc = 0;
    NvShader *cs = shader(@"struct Args { texture2d<float, access::write> cp_i_cb3_260_ [[id(0)]]; };\n"
        "kernel void wr(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.cp_i_cb3_260_.write(float4(7.0), uint2(0)); }\n", @"wr",
        @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
            @{ @"kind": @"img_ubo", @"reg": @0, @"off": @(off), @"arg_id": @0, @"msl_name": @"cp_i_cb3_260_", @"msl_type": @"texture2d<float, access::write>" } ] }, &rc, err, errlen);
    if (rc) return rc;
    if (check_refl) VERIFY(cs->rf.nb == 1 && cs->rf.b[0].kind == NVN_RB_IMGU && cs->rf.b[0].reg == 0 && cs->rf.b[0].off == 0 && cs->rf.b[0].rw && cs->rf.bindless,
                           "① img_ubo 反射：种类 %u（期望 IMGU %u）、槽 %u（期望 0）、偏移 %u（期望 0）、可写 %u（期望 1）、bindless %u（期望 1）",
                           cs->rf.b[0].kind, (unsigned)NVN_RB_IMGU, cs->rf.b[0].reg, cs->rf.b[0].off, cs->rf.b[0].rw, cs->rf.bindless);
    S.tex_base = 0; S.img[5][0] = 3;   // 图像槽 0 放 B：按槽取（旧 IMG 路线）会写进它
    S.ubo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(memory + UBO_OFF), .size = 256};
    run_cs(cs);
    return 0;
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mtl_init();
    REQUIRE(!posix_memalign((void **)&memory, 65536, MEM)); memset(memory, 0, MEM);
    pool = calloc(1, sizeof *pool); REQUIRE(pool);   // 活到进程结束：生产池是不拷贝的 MTLBuffer
    *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = MEM};
    nvn_be_pool_add(memory, MEM);
    static tex_t a, b, c;
    image_texture(&a, 9, 0x10000, 1.0f); image_texture(&b, 3, 0x20000, 2.0f); image_texture(&c, 5, 0x30000, 3.0f);
    uint32_t *ubo = (uint32_t *)(memory + UBO_OFF);
    ubo[0] = 9u | 0x77u << 20;   // 纹理号 9（A），高 12 位残留：图像不用采样器
    ubo[4] = 5u;                 // 字节 16：纹理号 5（C）
    char err[512] = ""; float v[2];
    int rc = write_img(0, err, sizeof err, 1);
    VERIFY(rc == 0, "① img_ubo 反射转换成功（rc %d%s%s）", rc, err[0] ? "：" : "", err);
    if (!rc) { read_back(9, 3, v);
        VERIFY(fabsf(v[0] - 7.0f) < 1e-6f && fabsf(v[1] - 2.0f) < 1e-6f, "② 统一缓冲槽 0 字节 0 的句柄 → A(0,0) = %.1f（期望 7.0）、图像槽 0 的 B(0,0) = %.1f（期望仍是 2.0）", v[0], v[1]); }
    err[0] = 0; rc = write_img(16, err, sizeof err, 0);
    if (!rc) read_back(5, 3, v);
    VERIFY(rc == 0 && fabsf(v[0] - 7.0f) < 1e-6f, "③ 偏移 16 的句柄 → C(0,0) = %.1f（期望 7.0；rc %d %s）", rc ? -1.0f : v[0], rc, err);
    // ④ ⑤ 原生图像原子（句柄在统一缓冲里）
    static tex_t d, e; uint_texture(&d, 11, 0x60000, 100u); uint_texture(&e, 13, 0x70000, 200u);
    ubo[8] = 11u;   // 字节 32：纹理号 11（D）
    err[0] = 0; rc = 0;
    NvShader *at = shader(@"struct Args { texture2d<uint, access::read_write> cp_i_cb3_8_r32ui [[id(0)]]; };\n"
        "kernel void at(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { a.cp_i_cb3_8_r32ui.atomic_fetch_add(uint2(0), 1u); }\n", @"at",
        @{ @"route": @"B", @"threadgroup_size": @[@8, @1, @1], @"bindings": @[
            @{ @"kind": @"img_ubo", @"reg": @0, @"off": @32, @"atomic": @YES, @"arg_id": @0, @"msl_name": @"cp_i_cb3_8_r32ui", @"msl_type": @"texture2d<uint, access::read_write>" } ] }, &rc, err, sizeof err);
    VERIFY(rc == 0 && at->rf.nb == 1 && at->rf.b[0].kind == NVN_RB_IMGU && at->rf.b[0].atomic_image && at->rf.has_atomic_image,
           "④ img_ubo 原子反射：rc %d%s%s、种类 %u（期望 IMGU %u）、atomic_image %u（期望 1）、has_atomic_image %u（期望 1）", rc, err[0] ? "：" : "", err,
           at->rf.nb ? at->rf.b[0].kind : 0, (unsigned)NVN_RB_IMGU, at->rf.nb ? at->rf.b[0].atomic_image : 0, at->rf.has_atomic_image);   // 反射没转成时 b 为空
    if (!rc) {
        S.tex_base = 0; S.img[5][0] = 13;   // 图像槽 0 放 E：按槽取会加到它身上
        S.ubo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(memory + UBO_OFF), .size = 256};
        run_cs(at);
        id<MTLTexture> dt = tex_mtl(&d), root = dt; while (root.parentTexture) root = root.parentTexture;
        NvShader *rd = shader(@"struct Args { texture2d<uint> fp_t_cb2_8 [[id(0)]]; texture2d<uint> fp_t_cb2_A [[id(1)]]; device uint4 *fp_s0 [[id(2)]]; };\n"
            "kernel void ru(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.fp_s0[0] = uint4(a.fp_t_cb2_8.read(uint2(0)).x, a.fp_t_cb2_8.read(uint2(1, 0)).x, a.fp_t_cb2_A.read(uint2(0)).x, 0); }\n", @"ru",
            @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
                @{ @"kind": @"tex", @"reg": @0, @"arg_id": @0, @"msl_name": @"fp_t_cb2_8", @"msl_type": @"texture2d<uint>" },
                @{ @"kind": @"tex", @"reg": @1, @"arg_id": @1, @"msl_name": @"fp_t_cb2_A", @"msl_type": @"texture2d<uint>" },
                @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @2, @"rw": @YES, @"msl_name": @"fp_s0", @"msl_type": @"device uint4*" } ] }, &rc, err, sizeof err);
        REQUIRE(rc == 0);
        uint32_t *out = (uint32_t *)(memory + OUT_OFF); for (int i = 0; i < 4; i++) out[i] = 0xffffffffu;
        S.tex[5][0] = 11u; S.tex[5][1] = 13u; S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)out, .size = 16};
        run_cs(rd);
        VERIFY(out[0] == 108u && out[1] == 100u && out[2] == 200u && tex_atomic_usage(root),
               "⑤ 8 线程对统一缓冲句柄所指 D(0,0) 各加 1：D(0,0) = %u（期望 108）、D(1,0) = %u（期望 100）、图像槽 0 的 E(0,0) = %u（期望 200）、D 底层原子用法 %d（期望 1）",
               out[0], out[1], out[2], tex_atomic_usage(root));
    }
    printf("%s t_nvn_img_ubo：%u 项，%u 项失败（句柄在统一缓冲里的存储图像按 Ryujinx ReadPackedId 取纹理号绑定）\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }

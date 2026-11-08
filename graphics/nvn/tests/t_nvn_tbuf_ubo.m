// 句柄在统一缓冲里的缓冲纹理（反射种类 tbuf_ubo → NVN_RB_TBUFU）：11-05 普查 c1105_ty8 文明6（010044500C182000）两支着色器
//   fp_t_cb1114127_10010000 / vp_t_cb1114127_10030000（texture_buffer）出库时反射种类是「?」，宿主「B binding kind ? not implemented」整支拒载，
//   最近 10 秒 8 秒丢了游戏的绘制。名字按 Ryujinx TextureHandle 拆：slots 1114127 = 0x11000F → 纹理缓冲 c15（NVN 统一缓冲槽 12）、采样器缓冲 c16；
//   句柄 0x10010000 → 类型 1（独立采样器句柄）、纹理字 o0 = 0、采样器字 o1 = 4。Ryujinx 照 ReadPackedId 取 c15 字 0 的低 20 位当纹理号，
//   缓冲纹理不用采样器（TextureBindingsManager.CommitTextureBindings 的 Target.TextureBuffer 分支）。
// 期望（按上面的语义手写，与被测实现无关）：
//   ① 反射 {kind tbuf_ubo, reg 12, off 0, texture_buffer<float>} 转换成功：种类 TBUFU、槽 12、偏移 0、记成无绑定（bindless）
//   ② 真走编码路径（生产 nvn_mtl.m encode_args + 真 Metal 设备）：统一缓冲槽 12 字节 0 = 纹理号 9 | 采样器字 0x77 << 20；纹理槽 12 放另一张缓冲纹理 B（号 3）。
//      计算着色器 read(2) → 读到 A 的第 2 个元素 = 2 × 1.5 = 3.0（读到 B 是 102、占位是 0）
//   ③ 偏移生效：同样的着色器反射 off 16、统一缓冲字节 16 = 纹理号 5（C）→ 读到 C[2] = 202
// 反证（修前）：同一单测编改前的 nvn_refl.m / nvn_mtl.m → ① 报「B binding kind tbuf_ubo not implemented」，②③ 跑不起来
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { MEM = 1 << 20, UBO_OFF = 0x40000, OUT_OFF = 0x50000 };
static uint8_t *memory; static pool_t *pool;

static void buffer_texture(tex_t *t, int id, size_t off, float base, float step) {
    float *v = (float *)(memory + off); for (int i = 0; i < 16; i++) v[i] = base + step * i;
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = 16, .height = 1, .depth = 1, .levels = 1};
    t->pool = pool; t->off = off; t->mem = pool->mem + off; nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
    nvn_be_reg_tex(id, t, NULL);
}
// 反射 off 不同的同一支着色器 → 派发一次，回读 out[0].x（-1 = 跑不起来）
static float run(int off, int *rc_out, char *err, int errlen) {
    NSError *e = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args { texture_buffer<float> fp_t_cb1114127_10010000 [[id(0)]]; device float4 *fp_s0 [[id(1)]]; };\n"
        "kernel void rd(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.fp_s0[0] = a.fp_t_cb1114127_10010000.read(2u); }\n" options:o error:&e];
    REQUIRE(lib);
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"rd"]; REQUIRE(cs->fn);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
    NSDictionary *refl = @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
        @{ @"kind": @"tbuf_ubo", @"reg": @12, @"off": @(off), @"arg_id": @0, @"msl_name": @"fp_t_cb1114127_10010000", @"msl_type": @"texture_buffer<float>" },
        @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @1, @"rw": @YES, @"msl_name": @"fp_s0", @"msl_type": @"device float4*" } ] };
    *rc_out = nvn_refl_from_json(refl, &cs->rf, err, errlen);
    if (*rc_out) return -1;
    if (off == 0) VERIFY(cs->rf.nb == 2 && cs->rf.b[0].kind == NVN_RB_TBUFU && cs->rf.b[0].reg == 12 && cs->rf.b[0].off == 0 && cs->rf.b[0].aid == 0 && cs->rf.bindless,
                         "① tbuf_ubo 反射：种类 %u（期望 TBUFU %u）、槽 %u（期望 12）、偏移 %u（期望 0）、bindless %u（期望 1）",
                         cs->rf.b[0].kind, (unsigned)NVN_RB_TBUFU, cs->rf.b[0].reg, cs->rf.b[0].off, cs->rf.bindless);
    prog_t pg; memset(&pg, 0, sizeof pg); pg.magic = MAGIC('P', 'R', 'O', 'G'); pg.serial = nvn_new_serial();
    NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(pg.serial, np);
    float *out = (float *)(memory + OUT_OFF); for (int i = 0; i < 4; i++) out[i] = -1;
    nvn_be_sub_begin();
    S.tex_base = 0; S.tex[5][12] = 3;   // 纹理槽 12 放 B：按槽取（旧 TBUF 路线）会读到它
    S.ubo[5][12] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(memory + UBO_OFF), .size = 256};
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
    pool = calloc(1, sizeof *pool); REQUIRE(pool);   // 活到进程结束：生产池是不拷贝的 MTLBuffer
    *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = MEM};
    nvn_be_pool_add(memory, MEM);
    static tex_t a, b, c;
    buffer_texture(&a, 9, 0x10000, 0, 1.5f); buffer_texture(&b, 3, 0x20000, 100, 1); buffer_texture(&c, 5, 0x30000, 200, 1);
    uint32_t *ubo = (uint32_t *)(memory + UBO_OFF);
    ubo[0] = 9u | 0x77u << 20;   // 纹理号 9（A），高 12 位是采样器字的残留：缓冲纹理不用
    ubo[4] = 5u;                 // 字节 16：纹理号 5（C）
    char err[512] = ""; int rc = 0;
    float v = run(0, &rc, err, sizeof err);
    VERIFY(rc == 0, "① tbuf_ubo 反射转换成功（rc %d%s%s）", rc, err[0] ? "：" : "", err);
    VERIFY(fabsf(v - 3.0f) < 1e-6f, "② 统一缓冲槽 12 字节 0 的句柄 → 读到 A[2] = %.1f（期望 3.0；纹理槽 12 的 B 是 102、占位 0）", v);
    err[0] = 0; v = run(16, &rc, err, sizeof err);
    VERIFY(rc == 0 && fabsf(v - 202.0f) < 1e-6f, "③ 偏移 16 的句柄 → 读到 C[2] = %.1f（期望 202.0；rc %d %s）", v, rc, err);
    printf("%s t_nvn_tbuf_ubo：%u 项，%u 项失败（句柄在统一缓冲里的缓冲纹理按 Ryujinx ReadPackedId 取纹理号绑定）\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }

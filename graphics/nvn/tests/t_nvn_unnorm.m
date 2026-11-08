// #968 step 1 (iOS host half): per-draw coordinate normalization bits in support_buffer.s2a_flags.yzw (nvn_unnorm.inc).
// Production nvn_mtl.m (included), production reflection parsing (nvn_refl_from_json in libnvn), real Metal draws; the shaders copy s2a_flags
//   (support buffer byte 1392 = uint4 index 87) of the support buffer actually bound to them into a storage buffer, read back on the CPU.
// Expectations, by hand from the contract (no call into the code under test):
//   bit of a binding = SupportBuffer.S2ATexUnnormBit(binding) = group * 32 + index for binding = group * 128 + index (index < 32), so
//   binding 0 → 0, binding 3 → 3, binding 5 → 5, binding 130 → 34; bit p sits in s2a_flags word 1 + p / 32 at bit p % 32.
//   value = 1 when the effective target (the view's SetTarget, else the texture's) is RECTANGLE (7), else 0.
//   ① vertex: RECTANGLE at bit 0                                  → s2a_flags = (X, 1, 0, 0)
//   ② fragment: RECTANGLE at bit 3, 2D at bit 5, 2D viewed as RECTANGLE at bit 34 → (X, 8, 4, 0)   (1, 0, 1)
//      X = the sentinel put into the static buffer's s2a_flags.x: the copies keep x as it is
//   ③ the vertex and fragment copies are distinct buffers (both number from binding 1 on iOS: a shared one would mix y)
//   ④ no RECTANGLE bound: both stages bind the static support buffer itself (support_gpu()), s2a_flags = (X, 0, 0, 0): as before the change
//   ⑤ a library without unnorm_bit (before #968's translator half): RECTANGLE bound, still the static buffer and (X, 0, 0, 0); the reflection carries no bit
//   ⑥ unnorm_bit −1 (outside the bitmap) is counted, not a bit; a value outside −1..95 refuses the reflection
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok = !!(c); failures += !ok; printf("%s ", ok ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VA { texture2d<float> r [[id(0)]]; constant uint4 *sb [[id(1)]]; device uint4 *out [[id(2)]]; };\n"
"vertex float4 vmain(uint i [[vertex_id]], constant VA &a [[buffer(0)]]) { a.out[0] = a.sb[87]; const float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"struct FA { texture2d<float> r [[id(0)]]; texture2d<float> d [[id(1)]]; texture2d<float> v [[id(2)]]; constant uint4 *sb [[id(3)]]; device uint4 *out [[id(4)]]; };\n"
"fragment float4 fmain(constant FA &a [[buffer(0)]]) { a.out[1] = a.sb[87]; return float4(1); }\n";

// unnorm_bit per texture binding (nil = an older library without the field)
static NvShader *shader(id<MTLLibrary> library, int stage, NSArray *bits) {
    NvShader *s = [NvShader new]; s->stage = stage;
    s->fn = [library newFunctionWithName:stage ? @"fmain" : @"vmain"]; REQUIRE(s->fn);
    strlcpy(s->key, stage ? "bbbbbbbbbbbbbbbb_b" : "aaaaaaaaaaaaaaaa_b", sizeof s->key);
    NSMutableArray *b = [NSMutableArray array]; int n = stage ? 3 : 1;
    for (int i = 0; i < n; i++) {
        NSMutableDictionary *t = [@{ @"kind": @"tex", @"reg": @(i), @"arg_id": @(i), @"msl_name": [NSString stringWithFormat:@"t%d", i], @"msl_type": @"texture2d<float>" } mutableCopy];
        if (bits) t[@"unnorm_bit"] = bits[i];
        [b addObject:t];
    }
    [b addObject:@{ @"kind": @"support", @"arg_id": @(n), @"msl_name": @"support_buffer", @"msl_type": @"constant uint4*" }];
    [b addObject:@{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @(n + 1), @"msl_name": @"out", @"msl_type": @"device uint4*", @"rw": @YES }];
    char err[256]; int rc = nvn_refl_from_json(@{ @"route": @"B", @"bindings": b }, &s->rf, err, sizeof err);
    if (rc) fprintf(stderr, "refl: %s\n", err); REQUIRE(!rc);
    s->rf.has_user = stage ? 2 : 1;
    if (stage) { s->rf.color_known = 1; s->rf.color_mask = 1; }
    s->ae = [s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae); s->arg_len = s->ae.encodedLength;
    return s;
}
static void make_texture(tex_t *t, pool_t *pool, size_t offset, int target) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T','E','X',0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target=target, .format=NVN_FORMAT_RGBA8, .flags=NVN_TEXTURE_FLAGS_IMAGE, .width=4, .height=4, .depth=1, .levels=1};
    t->pool=pool; t->off=offset; t->mem=pool->mem+offset;
    nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t); REQUIRE(tex_mtl(t));
}
static void finish(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error()); }
static uint64_t support_slot(NvShader *s) { int n = s->stage ? 3 : 1; return ((const uint64_t *)((const uint8_t *)s->ab_buf.contents + s->ab_off))[n]; }
static int eq4(const uint32_t *g, uint32_t x, uint32_t y, uint32_t z, uint32_t w) { return g[0] == x && g[1] == y && g[2] == z && g[3] == w; }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    char map[] = "/tmp/t_unnorm_map_XXXXXX"; int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd);
    char user[] = "/tmp/t_unnorm_user_XXXXXX"; fd = mkstemp(user); REQUIRE(fd >= 0); close(fd);
    setenv("DM_NVN_SHMAP", map, 1); setenv("DM_PSO_USER", user, 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    mtl_init(); printf("BACKEND %s\n", g_m3 ? "Metal3" : "Metal4");
    const op_hdr empty = {OP_END, sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *error = nil; id<MTLLibrary> library = [g_dev newLibraryWithSource:source options:nil error:&error];
    if (!library) fprintf(stderr, "MSL: %s\n", error.localizedDescription.UTF8String); REQUIRE(library);

    // ⑥ reflection: −1 counted, out of range refused, absent = no bit
    {   nvn_refl r; char err[256];
        NSDictionary *t = @{ @"kind": @"tex", @"reg": @0, @"arg_id": @0, @"msl_name": @"t", @"msl_type": @"texture2d<float>", @"unnorm_bit": @(-1) };
        REQUIRE(!nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[t] }, &r, err, sizeof err));
        CHECK(r.unb_uncov == 1 && r.b[0].unb == 0 && !r.has_unb, "⑥ unnorm_bit −1: counted outside the bitmap (uncov %u), no bit (unb %u)", (unsigned)r.unb_uncov, (unsigned)r.b[0].unb);
        free(r.b); free(r.c1);
        NSMutableDictionary *bad = [t mutableCopy]; bad[@"unnorm_bit"] = @96;
        CHECK(nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[bad] }, &r, err, sizeof err) != 0, "⑥ unnorm_bit 96: reflection refused (%s)", err);
        bad[@"unnorm_bit"] = @95; REQUIRE(!nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[bad] }, &r, err, sizeof err));
        CHECK(r.b[0].unb == 96 && r.has_unb, "⑥ unnorm_bit 95 (the last): kept as 1 + 95 = %u", (unsigned)r.b[0].unb); free(r.b); free(r.c1); }

    NvProg *cur = [NvProg new];   // bits: vertex binding 0 → bit 0; fragment bindings 3, 5, 130 → bits 3, 5, 34
    cur->sh[0] = shader(library, 0, @[@0]); cur->sh[1] = shader(library, 1, @[@3, @5, @34]);
    NvProg *old = [NvProg new]; old->sh[0] = shader(library, 0, nil); old->sh[1] = shader(library, 1, nil);
    CHECK(!old->sh[1]->rf.has_unb && !old->sh[1]->rf.unb_uncov && !old->sh[1]->rf.b[0].unb && !old->sh[1]->rf.b[2].unb, "⑤ library without unnorm_bit: no bit on any binding");
    prog_t pc = {.magic=MAGIC('P','R','O','G'), .serial=nvn_new_serial()}; serial_put(pc.serial, cur);
    prog_t po = {.magic=MAGIC('P','R','O','G'), .serial=nvn_new_serial()}; serial_put(po.serial, old);

    uint8_t *memory = NULL; REQUIRE(!posix_memalign((void **)&memory, 65536, 1 << 20)); memset(memory, 0, 1 << 20);
    pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);
    *pool = (pool_t){.magic=MAGIC('P','O','O','L'), .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem=memory, .size=1<<20};
    nvn_be_pool_add(memory, 1 << 20);
    tex_t rect, flat, viewed, rt; make_texture(&rect, pool, 0, NVN_TEXTURE_TARGET_RECTANGLE); make_texture(&flat, pool, 65536, NVN_TEXTURE_TARGET_2D);
    make_texture(&viewed, pool, 131072, NVN_TEXTURE_TARGET_2D); make_texture(&rt, pool, 196608, NVN_TEXTURE_TARGET_2D);
    view_t as_rect = {.set_target=1, .target=NVN_TEXTURE_TARGET_RECTANGLE};
    nvn_be_reg_tex(1, &rect, NULL); nvn_be_reg_tex(2, &flat, NULL); nvn_be_reg_tex(3, &viewed, &as_rect); nvn_be_reg_tex(4, &viewed, NULL);
    uint32_t *out = (uint32_t *)(memory + (512 << 10));
    const uint32_t X = 0x5a5a0003u; uint8_t *sb = (uint8_t *)support_buf().contents; memcpy(sb + 1392, &X, 4);   // sentinel in s2a_flags.x
    p_draw triangle = {.prim=NVN_DRAW_PRIMITIVE_TRIANGLES, .count=3, .instances=1};
    struct { const char *name; prog_t *p; int vt, f0, f1, f2; } runs[] = {
        { "①②③ RECTANGLE / 2D / 2D viewed as RECTANGLE", &pc, 1, 1, 2, 3 },
        { "④ no RECTANGLE bound", &pc, 2, 2, 2, 4 },
        { "⑤ library without unnorm_bit, RECTANGLE bound", &po, 1, 1, 2, 3 },
    };
    for (int k = 0; k < 3; k++) {
        memset(out, 0xee, 32);
        nvn_be_sub_begin(); state_reset(); S.prog = runs[k].p;
        S.tex[0][0] = (uint64_t)runs[k].vt; S.tex[1][0] = (uint64_t)runs[k].f0; S.tex[1][1] = (uint64_t)runs[k].f1; S.tex[1][2] = (uint64_t)runs[k].f2;
        S.ssbo[0][0] = S.ssbo[1][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)out, .size = 32};
        rp_flush(); memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &rt; R.has_rt = 1; g_pso_dirty = 1; args_dirty_all();
        draw(&triangle, NULL);
        NvProg *np = runs[k].p == &pc ? cur : old; uint64_t vs = support_slot(np->sh[0]), fs = support_slot(np->sh[1]);
        finish();
        printf("  %s: vertex s2a_flags (%#x, %#x, %#x, %#x) fragment (%#x, %#x, %#x, %#x); support vertex %s fragment %s\n", runs[k].name,
               out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7], vs == support_gpu() ? "static" : "copy", fs == support_gpu() ? "static" : "copy");
        if (k == 0) {
            CHECK(eq4(out, X, 1, 0, 0), "① vertex RECTANGLE at bit 0: s2a_flags = (X, 1, 0, 0)");
            CHECK(eq4(out + 4, X, 8, 4, 0), "② fragment RECTANGLE bit 3 = 1, 2D bit 5 = 0, viewed RECTANGLE bit 34 = 1: s2a_flags = (X, 8, 4, 0)");
            CHECK(vs != fs && vs != support_gpu() && fs != support_gpu(), "③ vertex and fragment each bind their own copy (%#llx / %#llx, static %#llx)",
                  (unsigned long long)vs, (unsigned long long)fs, (unsigned long long)support_gpu());
        } else {
            CHECK(eq4(out, X, 0, 0, 0) && eq4(out + 4, X, 0, 0, 0), "%s: both stages read (X, 0, 0, 0)", k == 1 ? "④" : "⑤");
            CHECK(vs == support_gpu() && fs == support_gpu(), "%s: both stages bind the static support buffer itself, as before the change", k == 1 ? "④" : "⑤");
        }
    }
    memset(sb + 1392, 0, 4);
    unlink(map); unlink(user);
}
    printf("%s t_nvn_unnorm: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
}

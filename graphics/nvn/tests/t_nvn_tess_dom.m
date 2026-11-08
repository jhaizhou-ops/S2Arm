// 曲面绘制的 hull 核按域载入（审计 #814 F-tess-dom-first）：直接包含生产 nvn_mtl.m，经 tess_draw 走曲面绘制。着色器是现编的真 Metal 函数，hull 的变体表是手写夹具。
// 依据（出库 tess_finish，S2A.Dsh graphics/tools/direct/dsh/Dsh.cs）：hull 着色器按域各翻一份，只有域改变翻译（曲面因子的布局与含义），首个域进 <key>_b（宿主载入的 hs->fn），其余域进 <key>_b_t<域>（另一份库，
//   函数名 main0）；分区与绕序由域着色器在运行时给固定核，不进 hull 的翻译。所以 hull 按域各一份计算管线，组合只看 hull × 域；没有该域的核时没有一份能证明等价的替代。
// 期望按规则手写，不由被测实现推出：
//   ① 请求四边形、变体只有三角（库就是 hs 自己）：本笔跳过并计数，报红 1 行（点名 hull 键与 quads），任何域的 hull 管线都不建
//   ② 同一组合再来一笔：仍跳过并计数，不再报红（每组合一次）
//   ③ 四边形的变体库 <key>_b_t2 载不进来（库目录里没有）：跳过、报红 1 行点名该库、四边形管线不建
//   ④ 同一 hull 换一个没有变体的域（等值线）：新组合，再报红 1 行
//   ⑤ 请求三角、变体库就是 hs 自己：不报 hull 红，三角那份管线用 hs->fn 建出
//   ⑥ 寄存器域值 3（没有定义）：不按三角画，报红 1 行、跳过、记在「未定义域」的跳过数里
//   ⑦ 真画（8×8 RGBA8，先清黑）：hull 的等值线核是 hs->fn（因子写 0 → 片被剔、画不出东西），三角核在库目录的 <key>_b_t1.metallib（因子全写 1 → 每片 1 个三角形）。
//      域着色器把域点 (u, v) 放到 NDC (1.9u − 1, 1.9v − 1)，片元写白。像素中心 NDC x = (i + 0.5) / 4 − 1，覆盖 ⇔ (i + 0.5) / 7.6 + (j + 0.5) / 7.6 ≤ 1 ⇔ i + j ≤ 6.6，
//      没有像素中心落在边上 → 白像素 = #{(i, j) ∈ [0, 7]² : i + j ≤ 6} = 1 + 2 + … + 7 = 28；用错核（等值线核）或跳过都是 0。三角域画出数 +1、跳过数不变、不报红、等值线那份管线不建
//   ⑧ 统计行（tess_stat_line）：打出画出 / 跳过的总数与分域数
//   反证：改前代码 ① 拿 allValues.firstObject 的 flags 与 hs->fn 继续画；只跳过不载入的版本 ⑦ 跳过（0 个白像素）；两版 ⑥ 都按三角画、不报红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

// h_iso 是 hs->fn（等值线核）：因子全写 0；三角核（h_tri）在 t_nvn_tess_dom_t1.metal，由 mk 编进库目录。接口槽同生产（TESS_BASE 20 起：+3 FACTOR、+4 PARAMS {P, Pt}）
static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex void v_cap(uint i [[vertex_id]]) { }\n"
"kernel void h_iso(device half *tl [[buffer(23)]], constant uint2 &pp [[buffer(24)]], uint g [[thread_position_in_grid]]) { if (g < pp.y) for (uint k = 0; k < 4; k++) tl[g * 4 + k] = half(0); }\n"
"struct DO { float4 p [[position]]; };\n"
"vertex DO d0(uint i [[vertex_id]], const device float4 *pts [[buffer(25)]]) { DO o; float2 uv = pts[i].xy; o.p = float4(uv * 1.9 - 1.0, 0, 1); return o; }\n"
"fragment float4 f0() { return float4(1); }\n";

static id<MTLLibrary> lib;
static NvShader *shader(NSString *fn, const char *key, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = [lib newFunctionWithName:fn]; REQUIRE(s->fn); strlcpy(s->key, key, sizeof s->key); s->ventry = @"main0";
    return s;
}
static NSDictionary *var(const char *library) { return @{@"library": @(library), @"flags": @0u, @"output_control_points": @1u}; }
static NvShader *hull(const char *key, NSDictionary *variants) { NvShader *h = shader(@"h_iso", key, 3); h->tess_ocp = 1; h->tess_variants = variants; return h; }
static int no_pso(NvShader *h) { return !h->tess_pso[0] && !h->tess_pso[1] && !h->tess_pso[2]; }

// 跑一笔曲面绘制（非索引、3 个控制点一片），返回这一笔打到 stderr 的全部行
static NSString *capture(void (^f)(void)) {
    char path[] = "/tmp/t_nvn_tess_dom_XXXXXX"; int fd = mkstemp(path); REQUIRE(fd >= 0);
    fflush(stderr); int saved = dup(2); REQUIRE(saved >= 0); dup2(fd, 2); close(fd);
    f();
    fflush(stderr); dup2(saved, 2); close(saved);
    NSString *out = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil] ?: @"";
    unlink(path); return out;
}
static NSString *one_draw(NvProg *pr, uint8_t dom) {
    pr->tess_dom = dom; pr->tess_part = 0; pr->tess_cw = 0; pr->tess_point = 0; S.patch_size = 3;
    return capture(^{ p_draw dw = {.count = 3, .instances = 1}; tess_draw(pr, &dw, NULL); });
}
static int count_lines(NSString *text, NSArray<NSString *> *needles) {
    int n = 0;
    for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
        if (![l containsString:@"【红】"]) continue;
        BOOL all = YES; for (NSString *s in needles) if (![l containsString:s]) { all = NO; break; }
        n += all;
    }
    return n;
}

int main(void) {
    @autoreleasepool {
        const char *libdir = getenv("T_TESS_DOM_LIB"); REQUIRE(libdir);   // mk 编好的 <key>_b_t1.metallib 所在目录
        setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);   // 编码线程由 mk 两种各跑一遍（iOS 缺省开、Mac 缺省关；11-01 TCS 的 dispatchThreads 没替身只在开的那路崩）
        mtl_init(); g_msl_dir = @(libdir);   // 没有容器（lib.idx）：lib_from_pack 读 <库目录>/<名>.metallib
        NSError *e = nil; lib = [g_dev newLibraryWithSource:source options:nil error:&e]; REQUIRE(lib);
        nvn_be_set_frame(1); nvn_be_sub_begin(); state_reset();
        NvShader *vs = shader(@"v_cap", "aaaaaaaaaaaaaaaa_b", 0); vs->geo_fn = vs->fn;
        NvShader *ds = shader(@"d0", "dddddddddddddddd_b", 4), *fs = shader(@"f0", "ffffffffffffffff_b", 1);
        NvShader *h1 = hull("1111111111111111_b", @{@"triangles": var("1111111111111111_b")});
        NvShader *h2 = hull("2222222222222222_b", @{@"triangles": var("2222222222222222_b"), @"quads": var("2222222222222222_b_t2")});
        NvShader *h3 = hull("3333333333333333_b", @{@"triangles": var("3333333333333333_b")});
        NvShader *h4 = hull("4444444444444444_b", @{@"isolines": var("4444444444444444_b"), @"triangles": var("4444444444444444_b_t1")});
        NvProg *pr = [NvProg new]; pr->sh[0] = vs; pr->sh[1] = fs; pr->sh[4] = ds;
        REQUIRE(tess_init());

        pr->sh[3] = h1; uint64_t s0 = g_tess_skips, d0 = g_tess_draws;
        NSString *o = one_draw(pr, 2);
        int red = count_lines(o, @[@"1111111111111111_b", @"quads"]);
        VERIFY(red == 1, "① 请求四边形、变体只有三角：报红 1 行，点名 hull 键与 quads（实得 %d 行；本笔 stderr：%s）", red, o.UTF8String);
        VERIFY(g_tess_skips == s0 + 1 && g_tess_draws == d0 && g_tess_dom_skips[2] == 1, "① 本笔跳过并计数（跳过 %llu → %llu，四边形跳过 %llu，绘制 %llu → %llu）",
               (unsigned long long)s0, (unsigned long long)g_tess_skips, (unsigned long long)g_tess_dom_skips[2], (unsigned long long)d0, (unsigned long long)g_tess_draws);
        VERIFY(no_pso(h1), "① hull 计算管线一份都没建：不拿三角那份核画四边形");

        s0 = g_tess_skips; o = one_draw(pr, 2);
        VERIFY(count_lines(o, @[@"1111111111111111_b"]) == 0 && g_tess_skips == s0 + 1 && no_pso(h1), "② 同组合再来一笔：仍跳过并计数，不再报红（本笔 stderr：%s）", o.UTF8String);

        pr->sh[3] = h2; s0 = g_tess_skips; o = one_draw(pr, 2);
        red = count_lines(o, @[@"2222222222222222_b", @"quads", @"2222222222222222_b_t2"]);
        VERIFY(red == 1 && g_tess_skips == s0 + 1 && !h2->tess_pso[2], "③ 四边形的变体库 _b_t2 载不进来：跳过、报红 1 行点名该库、四边形管线不建（红 %d 行；本笔 stderr：%s）", red, o.UTF8String);

        s0 = g_tess_skips; o = one_draw(pr, 0);
        red = count_lines(o, @[@"2222222222222222_b", @"isolines"]);
        VERIFY(red == 1 && g_tess_skips == s0 + 1 && !h2->tess_pso[0], "④ 同一 hull 换等值线（无变体）：新组合，再报红 1 行（实得 %d 行；本笔 stderr：%s）", red, o.UTF8String);

        pr->sh[3] = h3; o = one_draw(pr, 1);
        VERIFY(count_lines(o, @[@"3333333333333333_b"]) == 0 && h3->tess_pso[1] && !h3->tess_pso[0] && !h3->tess_pso[2], "⑤ 请求三角、变体库就是 hs 自己：不报 hull 红，三角那份管线建出（本笔 stderr：%s）", o.UTF8String);

        pr->sh[3] = h1; s0 = g_tess_skips; d0 = g_tess_draws; o = one_draw(pr, 3);
        red = count_lines(o, @[@"1111111111111111_b", @"3"]);
        VERIFY(red == 1 && g_tess_skips == s0 + 1 && g_tess_draws == d0 && g_tess_dom_skips[3] == 1 && no_pso(h1), "⑥ 域值 3（没有定义）：不按三角画，报红 1 行、跳过、记在未定义域（红 %d 行，未定义域跳过 %llu；本笔 stderr：%s）",
               red, (unsigned long long)g_tess_dom_skips[3], o.UTF8String);
        rp_flush();
        uint64_t fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull));   // ①–⑥ 编进去的 GPU 活先交掉（⑤ 的 hull 派发等）

        // ⑦ 真画：8×8 RGBA8 目标，先清黑，再画一片三角曲面
        tex_t rt; memset(&rt, 0, sizeof rt); rt.magic = MAGIC('T', 'E', 'X', 0); rt.serial = nvn_new_serial();
        rt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 8, .depth = 1, .levels = 1};
        nvn_tex_layout(&rt.d, &rt.L); nvn_be_tex_init(&rt); REQUIRE(tex_mtl(&rt));
        nvn_be_set_frame(2); nvn_be_sub_begin(); state_reset();
        { const struct { op_hdr set; p_set_rt_c rt; const tex_t *color0; uint8_t snap[sizeof(tex_t)]; op_hdr clear; p_clear_color color; op_hdr end; } c = {   // 紧凑 SET_RT：头 + 1 个颜色指针 + 1 份快照区（nvn_obj.h p_set_rt_c）
              .set = {OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt_c) + 8 + sizeof(tex_t)}, .rt = {.n = 1, .cmask = 1}, .color0 = &rt,
              .clear = {OP_CLEAR_COLOR, sizeof(op_hdr) + sizeof(p_clear_color)}, .color = {.index = 0, .mask = 15, .rgba = {0, 0, 0, 1}}, .end = {OP_END, sizeof(op_hdr)} };
          nvn_be_exec((const uint8_t *)&c); rp_flush(); }
        pr->sh[3] = h4; s0 = g_tess_skips; d0 = g_tess_draws; uint64_t t0 = g_tess_dom_draws[1];
        o = one_draw(pr, 1);
        rp_flush(); fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
        id<MTLTexture> image = tex_mtl(&rt);
        id<MTLBuffer> rb = [g_dev newBufferWithLength:8 * 8 * 4 options:MTLResourceStorageModeShared]; REQUIRE(rb);
        id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
        int white = 0, other = 0; const uint8_t *px = rb.contents;
        for (int i = 0; i < 64; i++) { const uint8_t *p = px + 4 * i; if (p[0] == 255 && p[1] == 255 && p[2] == 255) white++; else if (p[0] || p[1] || p[2]) other++; }
        VERIFY(white == 28 && other == 0, "⑦ 三角域请求、核在 _b_t1：画出 28 个白像素、其余全黑（实得白 %d、杂色 %d）", white, other);
        VERIFY(g_tess_draws == d0 + 1 && g_tess_dom_draws[1] == t0 + 1 && g_tess_skips == s0 && count_lines(o, @[]) == 0, "⑦ 三角域画出数 +1、跳过数不变、不报红（本笔 stderr：%s）", o.UTF8String);
        VERIFY(h4->tess_pso[1] && !h4->tess_pso[0], "⑦ 三角那份管线建出，等值线那份（hs->fn）没建");

        o = capture(^{ tess_stat_line(2); });
        NSString *want = [NSString stringWithFormat:@"drawn %llu (isolines %llu / triangles %llu / quads %llu", (unsigned long long)g_tess_draws,
                          (unsigned long long)g_tess_dom_draws[0], (unsigned long long)g_tess_dom_draws[1], (unsigned long long)g_tess_dom_draws[2]];
        NSString *skipped = [NSString stringWithFormat:@"skipped %llu", (unsigned long long)g_tess_skips];
        VERIFY([o containsString:want] && [o containsString:skipped] && [o containsString:@"undefined domain 1"],
               "⑧ 统计行打出画出 / 跳过总数与分域数（实得：%s）", o.UTF8String);

        // ⑨⑩ 带索引的曲面绘制何时让 CPU 等 GPU（mdi_wait，每等一次 g_mdi_v +1）：索引在 CPU 上读，只在 GPU 可能写过且没完成时才等（同 geo_draw 判据）。
        //   期望按判据手写：索引区本提交没有排队的写、没有存储写、前一提交已完成 → 不等（0 次）；本提交给索引区排一笔拷贝写（pend_add）→ 等 1 次。
        //   改前（di0 一律等，11-05 巫师3 每帧 2 次白等）⑨ 红
        static uint16_t ixmem[8192] __attribute__((aligned(16384))); ixmem[0] = 0; ixmem[1] = 1; ixmem[2] = 2;
        nvn_be_pool_add(ixmem, sizeof ixmem);
        nvn_be_set_frame(3); nvn_be_sub_begin(); state_reset();
        { const struct { op_hdr set; p_set_rt_c rt; const tex_t *color0; uint8_t snap[sizeof(tex_t)]; op_hdr end; } c = {
              .set = {OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt_c) + 8 + sizeof(tex_t)}, .rt = {.n = 1, .cmask = 1}, .color0 = &rt, .end = {OP_END, sizeof(op_hdr)} };
          nvn_be_exec((const uint8_t *)&c); }
        pr->sh[3] = h4; pr->tess_dom = 1; pr->tess_part = 0; pr->tess_cw = 0; pr->tess_point = 0; S.patch_size = 3;
        p_draw_idx dix = {.itype = 1, .count = 3, .instances = 1, .ibuf = (uint64_t)(uintptr_t)ixmem};
        uint64_t w0 = g_mdi_v, dr0 = g_tess_draws;
        o = capture(^{ tess_draw(pr, NULL, &dix); });
        VERIFY(g_mdi_v == w0 && g_tess_draws == dr0 + 1, "⑨ 带索引、索引区干净：CPU 不等 GPU（等待 %llu 次，期望 0）、照常画出（画出 +%llu；本笔 stderr：%s）",
               (unsigned long long)(g_mdi_v - w0), (unsigned long long)(g_tess_draws - dr0), o.UTF8String);
        pend_add((uint64_t)(uintptr_t)ixmem, 6, 2);   // 本提交里一笔拷贝写到索引区
        w0 = g_mdi_v; dr0 = g_tess_draws;
        o = capture(^{ tess_draw(pr, NULL, &dix); });
        VERIFY(g_mdi_v == w0 + 1 && g_tess_draws == dr0 + 1, "⑩ 反证 索引区有本提交排队的写：等 GPU 1 次（实得 %llu 次）再画（画出 +%llu；本笔 stderr：%s）",
               (unsigned long long)(g_mdi_v - w0), (unsigned long long)(g_tess_draws - dr0), o.UTF8String);
        rp_flush(); fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    }
    if (failures) { printf("✗ t_nvn_tess_dom：%u 项里 %u 项不符\n", checks, failures); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_tess_dom：%u 项全过（hull 核按域载入：有该域的核就用那份画、真画出 28 像素；没有的组合跳过、计数、每组合报红一次；域值 3 报红；带索引只在索引区可能被 GPU 写时才等）\n", checks); return 0;
}

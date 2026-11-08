// 首遇管线并行预编（pso_predict_rest）与后台表满时的回收（pso_pend_kick）：直接包含生产 nvn_mtl.m 调 pso_get_，着色器是现编的真 Metal 函数。期望按规则手写，不由被测实现推出：
//   ① 一次提交里第一次缺管线：先把本提交后面的绘制要的管线踢到后台（并行编），再等手头这条 → 手头这条拿到时，后面那条 B 已在后台表里（排着或编完）；
//   ② 同一提交里画到 B：从后台取（拿到计数 +1），不在提交线程现建；同一提交第二次缺管线不再往前看（踢出计数只 +1 = B 自己那次已在表里，不重复踢）；
//   ③ 后台表满、其中有编完没人取的 → 腾出一格给新踢的（回收计数 +1）；全在编 → 拒（新管线不进表，调用方照旧现建），回收计数不变；
//   ④ 后台已有 PSO_AHEAD（8）条在编 → 往前看不再踢，只踢手头这条（踢出计数 +1、后面那笔状态 0）。
//   反证（11-02 实跑）：pso_get_vs 换回改前顺序（手头这条先等、取到就返回，往前看从没跑；马力欧派对普查 11-02 整局 0 行「parallel precompile」、第 30722 帧 61 条串行 1796 ms）
//   → ① 两项红（B 状态 0、踢出 1 条），② ③ 照过；③ 的反证按代码：改前表满一律拒，新管线不进表
//   ⑤（审计 #1565 P1-101）往前看解析后面换画布的贴图只取格式 / 采样数：图像对象（IMAGE）落在没写权限的共享贴图上时，前瞻不升级（升级经 blit() 结束手头开着的渲染遍，
//   并把升级拷贝提前到这一遍剩下的绘制之前），后面那条管线照样按 RGBA8 踢出；真正解析这个对象时才升级一次。
//   反证（11-05 手工）：去掉 tex_mtl_ 里 g_tex_peek 那一行早返 → ⑤ 前两项红（前瞻里升级 +1、对象已登记）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VO { float4 p [[position]]; float4 a [[user(locn0)]]; };\n"
"vertex VO v0(uint i [[vertex_id]]) { VO o; o.p = float4(float(i & 1), float(i >> 1), 0, 1); o.a = float4(1); return o; }\n"
"struct F0 { float4 a [[user(locn0)]]; };\n"
"fragment float4 fa(F0 i [[stage_in]]) { return i.a; }\n"
"fragment float4 fb(F0 i [[stage_in]]) { return i.a.wzyx * 0.5; }\n";

static NvShader *shader(id<MTLLibrary> lib, NSString *fn, const char *key, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = [lib newFunctionWithName:fn]; REQUIRE(s->fn); strlcpy(s->key, key, sizeof s->key);
    s->rf.has_user = stage == 0 ? 1 : 2; if (stage == 0) s->rf.user_out = 1u; else s->rf.user_in = 1u;
    return s;
}

int main(void) {
    @autoreleasepool {
        char user[] = "/tmp/t_pso_lookahead_XXXXXX"; int fd = mkstemp(user); REQUIRE(fd >= 0); close(fd); setenv("DM_PSO_USER", user, 1);
        char map[] = "/tmp/t_pso_lookahead_map_XXXXXX"; fd = mkstemp(map); REQUIRE(fd >= 0); close(fd); setenv("DM_NVN_SHMAP", map, 1);
        setenv("DM_NVN_PSO_FRAME_MS", "0", 1);   // 不让每帧等待预算掺进来：只看先后
        mtl_init();
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&e]; REQUIRE(lib);
        NvShader *vs = shader(lib, @"v0", "aaaaaaaaaaaaaaaa_b", 0), *fa = shader(lib, @"fa", "cccccccccccccccc_b", 1), *fb = shader(lib, @"fb", "dddddddddddddddd_b", 1);
        memset(&g_pass, 0, sizeof g_pass); g_pass.cfmt[0] = (uint32_t)MTLPixelFormatRGBA8Unorm; g_pass.samples = 1;
        NvProg *pa = [NvProg new]; pa->sh[0] = vs; pa->sh[1] = fa;
        NvProg *pb = [NvProg new]; pb->sh[0] = vs; pb->sh[1] = fb;

        // 本提交余下的命令：一笔绘制（程序 = pb，经序号表取）、然后结束
        static prog_t gp_b; gp_b.serial = 0x7700beefull; serial_put(gp_b.serial, pb); S.prog = &gp_b;
        static uint8_t cmds[256]; op_hdr h = {OP_DRAW, (uint32_t)(sizeof h + sizeof(p_draw))}; memcpy(cmds, &h, sizeof h);
        op_hdr end = {OP_END, (uint32_t)sizeof end}; REQUIRE(h.size + sizeof end <= sizeof cmds); memcpy(cmds + h.size, &end, sizeof end);
        g_exec_next = cmds; g_nrest = 0; g_hoist_n = 0;
        pso_key kb; pso_key_fill(&kb, vs, fb, g_pass.cfmt, 0, 0, 1, 0);

        g_sub_serial++;   // 新的一次提交
        uint64_t kick0 = g_pp_kicked, take0 = g_pp_taken;
        id ps = pso_get_(pa, nil);
        int st_b = pso_pend_state(&kb);
        VERIFY(ps && st_b != 0, "① 第一次缺管线拿到 A 时，后面那笔绘制的 B 已在后台表里（状态 %d：1 在编 / 2 编完；0 = 没往前看）", st_b);
        VERIFY(g_pp_kicked - kick0 == 2, "① 踢出 2 条：手头的 A + 往前看到的 B（实得 %llu）", (unsigned long long)(g_pp_kicked - kick0));

        S.prog = NULL; g_exec_next = NULL;   // 画到 B 那笔：往前已无命令
        uint64_t n0 = g_bp_pso_n; ps = pso_get_(pb, nil);
        VERIFY(ps && g_pp_taken - take0 == 2 && g_bp_pso_n == n0 + 1, "② B 从后台取（拿到计数 A、B 共 +%llu），建管线计数 +%llu（计的是这次取用的等待，不是现建）",
               (unsigned long long)(g_pp_taken - take0), (unsigned long long)(g_bp_pso_n - n0));
        VERIFY(g_pp_kicked - kick0 == 2, "② 同一提交第二次缺管线不再往前看、B 不重复踢（踢出计数仍 2，实得 %llu）", (unsigned long long)(g_pp_kicked - kick0));

        // ④ 后台已有 PSO_AHEAD 条在编：往前看不再踢（只踢手头这条），后面那笔留到它自己画时再踢
        pthread_mutex_lock(&g_pp_mu);
        for (int i = 0; i < PSO_AHEAD; i++) { int s_ = PSO_PEND_MAX - 1 - i; memset(&g_pp[s_].k, 0, sizeof g_pp[s_].k); memcpy(&g_pp[s_].k, &s_, sizeof s_); g_pp[s_].ps = nil; g_pp[s_].done = 0; g_pp[s_].late = 0; g_pp[s_].stuck = 0; g_pp[s_].used = 1; }
        pthread_mutex_unlock(&g_pp_mu);
        NvShader *fx = shader(lib, @"fa", "1111111111111111_b", 1), *fy = shader(lib, @"fb", "2222222222222222_b", 1);
        NvProg *px = [NvProg new]; px->sh[0] = vs; px->sh[1] = fx; NvProg *py = [NvProg new]; py->sh[0] = vs; py->sh[1] = fy;
        static prog_t gp_y; gp_y.serial = 0x7700cafeull; serial_put(gp_y.serial, py); S.prog = &gp_y; g_exec_next = cmds;
        pso_key ky; pso_key_fill(&ky, vs, fy, g_pass.cfmt, 0, 0, 1, 0);
        g_sub_serial++; kick0 = g_pp_kicked; ps = pso_get_(px, nil);
        VERIFY(ps && pso_pend_state(&ky) == 0 && g_pp_kicked - kick0 == 1, "④ 已有 %d 条在编：只踢手头这条（踢出 %llu）、后面那笔不踢（状态 %d）", PSO_AHEAD, (unsigned long long)(g_pp_kicked - kick0), pso_pend_state(&ky));
        S.prog = NULL; g_exec_next = NULL;
        pthread_mutex_lock(&g_pp_mu); for (int i = 0; i < PSO_PEND_MAX; i++) g_pp[i].used = 0; pthread_mutex_unlock(&g_pp_mu);

        // ③ 表满：全是编完没人取的 → 回收一格
        pthread_mutex_lock(&g_pp_mu);
        for (int i = 0; i < PSO_PEND_MAX; i++) { memset(&g_pp[i].k, 0, sizeof g_pp[i].k); memcpy(&g_pp[i].k, &i, sizeof i); g_pp[i].ps = nil; g_pp[i].done = 1; g_pp[i].late = 0; g_pp[i].stuck = 0; g_pp[i].used = 1; }
        pthread_mutex_unlock(&g_pp_mu);
        NvShader *fc = shader(lib, @"fb", "eeeeeeeeeeeeeeee_b", 1); pso_key kc; pso_key_fill(&kc, vs, fc, g_pass.cfmt, 0, 0, 1, 0);
        uint64_t d0 = g_pp_dropped; pso_pend_kick(&kc, vs, fc);
        VERIFY(pso_pend_state(&kc) != 0 && g_pp_dropped == d0 + 1, "③ 表满、都编完没人取：腾出一格给新管线（回收 +%llu，新管线状态 %d）", (unsigned long long)(g_pp_dropped - d0), pso_pend_state(&kc));
        { int t = 0; id got = pso_pend_take(&kc, &t, 0); VERIFY(got && !t, "③ 新管线编完能取到"); }
        pthread_mutex_lock(&g_pp_mu); for (int i = 0; i < PSO_PEND_MAX; i++) { g_pp[i].done = 0; g_pp[i].used = 1; } pthread_mutex_unlock(&g_pp_mu);
        NvShader *fd2 = shader(lib, @"fa", "ffffffffffffffff_b", 1); pso_key kd; pso_key_fill(&kd, vs, fd2, g_pass.cfmt, 0, 0, 1, 0);
        d0 = g_pp_dropped; pso_pend_kick(&kd, vs, fd2);
        VERIFY(pso_pend_state(&kd) == 0 && g_pp_dropped == d0, "③ 表满、全在编：拒（新管线不进表，调用方现建），不回收在编的");
        pthread_mutex_lock(&g_pp_mu); for (int i = 0; i < PSO_PEND_MAX; i++) g_pp[i].used = 0; pthread_mutex_unlock(&g_pp_mu);

        {   // ⑤ 前瞻不升级共享贴图
            static uint8_t *mem; REQUIRE(!posix_memalign((void **)&mem, 65536, 1 << 20)); memset(mem, 0, 1 << 20);
            static pool_t pool; pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = 1 << 20};
            nvn_be_pool_add(mem, 1 << 20);
            nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 16, .height = 16, .depth = 1, .levels = 1};
            static tex_t t0, t1;   // 同一存储：t0 普通贴图（建出共享贴图，无写权限），t1 同描述 + IMAGE（别名键去掉 IMAGE，解析到同一张共享贴图）
            memset(&t0, 0, sizeof t0); t0.magic = MAGIC('T', 'E', 'X', 0); t0.serial = nvn_new_serial(); t0.d = d; t0.pool = &pool; t0.off = 0; t0.mem = mem; nvn_tex_layout(&t0.d, &t0.L); nvn_be_tex_init(&t0);
            t1 = t0; t1.serial = nvn_new_serial(); t1.d.flags |= NVN_TEXTURE_FLAGS_IMAGE; nvn_be_tex_init(&t1);
            nvn_be_sub_begin();
            id<MTLTexture> sh0 = tex_mtl(&t0); REQUIRE(sh0 && !(sh0.usage & MTLTextureUsageShaderWrite) && sh0.pixelFormat == MTLPixelFormatRGBA8Unorm);
            // 本提交余下的命令：换画布到 t1 → 一笔绘制（程序 pz）→ 结束
            static p_set_rt rt; memset(&rt, 0, sizeof rt); rt.n = 1; rt.color[0] = &t1;
            static uint8_t c5[1024]; size_t pl = set_rt_size(&rt); op_hdr hs = {OP_SET_RT, (uint32_t)(sizeof hs + pl)}; REQUIRE(hs.size + h.size + sizeof end <= sizeof c5);
            memcpy(c5, &hs, sizeof hs); set_rt_put(c5 + sizeof hs, &rt); memcpy(c5 + hs.size, &h, sizeof h); memcpy(c5 + hs.size + h.size, &end, sizeof end);
            NvShader *fw = shader(lib, @"fa", "3333333333333333_b", 1), *fz = shader(lib, @"fb", "4444444444444444_b", 1);
            NvProg *pw = [NvProg new]; pw->sh[0] = vs; pw->sh[1] = fw; NvProg *pz = [NvProg new]; pz->sh[0] = vs; pz->sh[1] = fz;
            static prog_t gp_z; gp_z.serial = 0x7700f00dull; serial_put(gp_z.serial, pz); S.prog = &gp_z; g_exec_next = c5; R.has_rt = 0;
            uint32_t cf5[8] = {(uint32_t)MTLPixelFormatRGBA8Unorm}; pso_key kz; pso_key_fill(&kz, vs, fz, cf5, 0, 0, 1, 0);
            uint64_t up0 = g_pfv_upgrades;
            ps = pso_get_(pw, nil);
            VERIFY(ps && g_pfv_upgrades == up0, "⑤ 前瞻解析换画布的图像对象：不升级共享贴图（升级 +%llu，期望 0）", (unsigned long long)(g_pfv_upgrades - up0));
            VERIFY(tex_get(t1.serial) == nil, "⑤ 前瞻不替图像对象登记贴图（留给真正换画布时解析）");
            VERIFY(pso_pend_state(&kz) != 0, "⑤ 后面那笔的管线照样按 RGBA8 画布踢到后台（状态 %d）", pso_pend_state(&kz));
            S.prog = NULL; g_exec_next = NULL;
            id<MTLTexture> t1m = tex_mtl(&t1);
            VERIFY(t1m && (t1m.usage & MTLTextureUsageShaderWrite) && g_pfv_upgrades == up0 + 1, "⑤ 真正解析图像对象时才升级（写权限 %d，升级 +%llu，期望 1）",
                   t1m ? !!(t1m.usage & MTLTextureUsageShaderWrite) : -1, (unsigned long long)(g_pfv_upgrades - up0));
            uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
            pthread_mutex_lock(&g_pp_mu); for (int i = 0; i < PSO_PEND_MAX; i++) g_pp[i].used = 0; pthread_mutex_unlock(&g_pp_mu);
        }

        unlink(user); unlink(map);
    }
    if (failures) { printf("✗ t_nvn_pso_lookahead：%u 项里 %u 项不符\n", checks, failures); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_pso_lookahead：%u 项全过（第一次缺管线先往前看、后面的从后台取；在编满 8 条不再往前踢；表满回收编完没人取的；前瞻不升级共享贴图）\n", checks); return 0;
}

// 张量核网络顶替（nvn_tensor.inc tensor_standin）的输出图每帧被「升级成可当渲染目标」（11-05 时之笛 Switch 2 版第二十版测试机2：
//   ser=4149（1920x1080 R11G11B10F）每帧一行 texture upgraded to allow render-target use，累计 upgrades=4354，每次新建一张、整张拷贝）。
// 根因：输出图按贴图编号取的是采样用的视图（tex_fast_rid → tex_by_id）。登记带通道重排（R11G11B10F 没有 alpha，a 取 1；或游戏自设重排）时那是重排视图，
//   Metal 给重排视图的用途只有 ShaderRead（本机实测：底图 0x7，同格式不重排视图 0x7，重排视图 0x1）。dlss_usage 见缺渲染目标用途就 tex_upgrade：
//   新建一张、拷贝、换进序号表；下一次 tex_by_id 在新底图上又建重排视图，用途又只有 ShaderRead → 每帧再升级一次。
// 做法：生产 dispatch → tensor_standin 真跑 MetalFX；输出图按 RGBA8 + 图像用途建（tex_desc：ShaderRead | RenderTarget | ShaderWrite），登记时带 (R, G, B, 1) 重排视图；
//   同一对贴图连派发 3 轮。
// 期望（不跑被测实现就能定）：底图建时已带渲染目标与写用途；写目标应是同一份存储的不重排视图（同 Ryujinx：存储图像用恒等通道视图），用途随底图。
//   所以第 2、3 轮升级 0 次，3 轮合计 ≤ 1 次（MetalFX 若要底图没有的用途，只在第 1 轮升级一次）；第 2→3 轮序号表里的底图是同一个对象。
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static void make_texture(tex_t *t, pool_t *pool, size_t off, uint32_t w, uint32_t h, int image) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .flags = image ? NVN_TEXTURE_FLAGS_IMAGE : 0, .width = w, .height = h, .depth = 1, .levels = 1};
    t->pool = pool; t->off = off; t->mem = pool->mem + off; nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
    REQUIRE(t->L.size && off + t->L.size <= pool->size);
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        enum { POOL = 4 << 20, ROUNDS = 3, W = 64, H = 36 };
        uint8_t *memory = NULL; REQUIRE(!posix_memalign((void **)&memory, 65536, POOL)); memset(memory, 0, POOL);
        pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);
        *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = POOL};
        nvn_be_pool_add(memory, POOL);
        NvShader *cs = [NvShader new]; cs->stage = 5; cs->tensor = 1; strlcpy(cs->key, "t_tensor_upgrade_once_b", sizeof cs->key);
        cs->rf.nb = 2; cs->rf.b = calloc(2, sizeof *cs->rf.b); REQUIRE(cs->rf.b);
        cs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .rw = 1}; cs->rf.b[1] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 1};
        prog_t prog; memset(&prog, 0, sizeof prog); prog.magic = MAGIC('P', 'R', 'O', 'G'); prog.serial = nvn_new_serial();
        NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(prog.serial, np);
        static tex_t in, out;
        make_texture(&in, pool, 0, W, H, 0);
        make_texture(&out, pool, (in.L.size + 65535) & ~(size_t)65535, 2 * W, 2 * H, 1);
        view_t rgb1; memset(&rgb1, 0, sizeof rgb1); rgb1.set_swizzle = 1;   // (R, G, B, 1)：NVN 通道枚举 2 R 3 G 4 B 1 one
        rgb1.swz[0] = 2; rgb1.swz[1] = 3; rgb1.swz[2] = 4; rgb1.swz[3] = 1;
        uint64_t total0 = g_pfv_upgrades, per[ROUNDS]; __unsafe_unretained id<MTLTexture> base[ROUNDS];
        for (int r = 0; r < ROUNDS; r++) {
            nvn_be_sub_begin();
            nvn_be_reg_tex(1, &in, NULL); nvn_be_reg_tex(2, &out, &rgb1);
            S.tex[5][0] = 1; S.img[5][0] = 2; args_dirty_all();
            uint64_t up0 = g_tensor_up, u0 = g_pfv_upgrades;
            p_dispatch dp = {.x = 1, .y = 1, .z = 1}; S.cprog = &prog; dispatch(&dp);
            uint64_t fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
            per[r] = g_pfv_upgrades - u0; base[r] = tex_mtl(&out);
            CHECK(g_tensor_up == up0 + 1, "round %d: stood in by the MetalFX spatial scaler (g_tensor_up %llu → %llu)", r, (unsigned long long)up0, (unsigned long long)g_tensor_up);
            CHECK(base[r] && (base[r].usage & MTLTextureUsageRenderTarget), "round %d: output storage ser=%llu usage %#lx has render-target use", r, (unsigned long long)out.serial, base[r] ? (unsigned long)base[r].usage : 0ul);
            printf("ROUND %d texture upgrades this round %llu\n", r, (unsigned long long)per[r]);
        }
        for (int r = 1; r < ROUNDS; r++) CHECK(per[r] == 0, "round %d: no texture upgrade once the output has been resolved (got %llu)", r, (unsigned long long)per[r]);
        CHECK(g_pfv_upgrades - total0 <= 1, "upgrades over %d rounds of the same output: expected ≤ 1, got %llu", ROUNDS, (unsigned long long)(g_pfv_upgrades - total0));
        CHECK(base[1] == base[2], "output storage object unchanged from round 1 to round 2 (%p → %p)", (__bridge void *)base[1], (__bridge void *)base[2]);
        nvn_be_drain();
        printf("%s t_nvn_tensor_upgrade_once: %u checks %u failures; %d rounds, backend Metal%d\n", failures ? "✗" : "✓", checks, failures, ROUNDS, g_m3 ? 3 : 4);
        return failures != 0;
    }
}

// 张量核网络顶替（nvn_tensor.inc tensor_standin）与贴图编号登记表扩表并发（11-05 时之笛 Switch 2 版第十八版测试机2 崩溃：
//   信号 11 读 0x70120610b8，pc tex_upgrade+0x4d4 = `tex_get(t->serial)`，t 是 tensor_standin 在 g_rmu 里取的 &g_treg[otid].t，
//   出锁后别的线程登记新编号把 g_treg realloc 走了，旧表被释放，t 悬空）。
// 做法：生产 dispatch → tensor_standin 真跑 MetalFX 空间放大；另一线程像 nvn_be_reg_tex 扩表那样在 g_rmu 里 GROW(g_treg)（同一个宏、同一把锁）。
//   ASan 编译：realloc 每次换新块、旧块进隔离区并下毒，出锁后再读旧表的槽 = heap-use-after-free 中止（单测红）。
//   每轮输入 / 输出尺寸都不同，放大器缓存不命中、每轮现建 MetalFX 放大器（毫秒级），出锁到读槽之间的窗口里扩表线程必然转过几圈。
// 期望（不跑被测实现就能定）：每轮都走到放大（g_tensor_up 每轮 +1）、输出图的序号表里换成带渲染目标用途的贴图，全程 ASan 0 报告。
#include "../gfx/nvn/nvn_mtl.m"
#include <pthread.h>

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static _Atomic int done;
static _Atomic uint64_t grows;
static void *grower(void *arg) {   // 登记新编号时的扩表：nvn_be_reg_tex 在 g_rmu 里 GROW(g_treg)；这里同尺寸重分配，表不涨、地址照样换（ASan 的 realloc 总是新块）
    (void)arg;
    while (!atomic_load(&done)) {
        pthread_mutex_lock(&g_rmu);
        REQUIRE(GROW(g_treg, (size_t)g_ntreg * sizeof *g_treg, "texture registration table"));
        pthread_mutex_unlock(&g_rmu);
        atomic_fetch_add(&grows, 1);
        sched_yield();
    }
    return NULL;
}

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
        enum { POOL = 8 << 20, ROUNDS = 4 };
        uint8_t *memory = NULL; REQUIRE(!posix_memalign((void **)&memory, 65536, POOL)); memset(memory, 0, POOL);
        pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);   // 活到进程结束：生产的池是不拷贝的 MTLBuffer
        *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = POOL};
        nvn_be_pool_add(memory, POOL);
        // 网络出口：一个可写图槽（输出）+ 一个贴图槽（它读的低分辨率画面）
        NvShader *cs = [NvShader new]; cs->stage = 5; cs->tensor = 1; strlcpy(cs->key, "t_tensor_treg_b", sizeof cs->key);
        cs->rf.nb = 2; cs->rf.b = calloc(2, sizeof *cs->rf.b); REQUIRE(cs->rf.b);
        cs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .rw = 1}; cs->rf.b[1] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 1};
        prog_t prog; memset(&prog, 0, sizeof prog); prog.magic = MAGIC('P', 'R', 'O', 'G'); prog.serial = nvn_new_serial();
        NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(prog.serial, np);
        pthread_t th; REQUIRE(!pthread_create(&th, NULL, grower, NULL));
        static tex_t in[ROUNDS], out[ROUNDS]; size_t off = 0;
        for (int r = 0; r < ROUNDS; r++) {
            uint32_t w = 64 + 32 * (uint32_t)r, h = w * 9 / 16;   // 16:9，每轮尺寸不同：放大器缓存不命中
            make_texture(&in[r], pool, off, w, h, 0); off += (in[r].L.size + 65535) & ~(size_t)65535;
            make_texture(&out[r], pool, off, 2 * w, 2 * h, 1); off += (out[r].L.size + 65535) & ~(size_t)65535;
            nvn_be_sub_begin();
            nvn_be_reg_tex(1, &in[r], NULL); nvn_be_reg_tex(2, &out[r], NULL);
            S.tex[5][0] = 1; S.img[5][0] = 2; args_dirty_all();
            uint64_t up0 = g_tensor_up, g0 = atomic_load(&grows);
            p_dispatch dp = {.x = 1, .y = 1, .z = 1}; S.cprog = &prog; dispatch(&dp);
            uint64_t fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
            id<MTLTexture> o = tex_mtl(&out[r]);
            CHECK(g_tensor_up == up0 + 1, "round %d %ux%u → %ux%u: stood in by the MetalFX spatial scaler (g_tensor_up %llu → %llu)", r, w, h, 2 * w, 2 * h,
                  (unsigned long long)up0, (unsigned long long)g_tensor_up);
            CHECK(o && (o.usage & MTLTextureUsageRenderTarget), "round %d output ser=%llu usage %#lx has render-target use", r, (unsigned long long)out[r].serial, (unsigned long)o.usage);
            printf("ROUND %d registration-table moves during this dispatch: %llu\n", r, (unsigned long long)(atomic_load(&grows) - g0));
        }
        atomic_store(&done, 1); pthread_join(th, NULL);
        CHECK(atomic_load(&grows) > 0, "registration table moved %llu times while the stand-in ran", (unsigned long long)atomic_load(&grows));
        nvn_be_drain();
        printf("%s t_nvn_tensor_treg: %u checks %u failures; %d rounds, %llu table moves, backend Metal%d\n", failures ? "✗" : "✓", checks, failures, ROUNDS,
               (unsigned long long)atomic_load(&grows), g_m3 ? 3 : 4);
        return failures != 0;
    }
}

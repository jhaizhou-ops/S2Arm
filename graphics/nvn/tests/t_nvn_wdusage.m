// 直连宽屏登记渲染目标：存储放不宽的（这里是 CPU 可见池里的线性渲染目标，存储建在池缓冲上）只有放宽后画的这块装得进存储才按可放宽（S2A_WIDEN_USE_RT）登记给核心，
//   装不下的不带（核心约定：游戏内存的存储不放宽），核心按原宽给；普通渲染目标照旧拿放宽宽度。公开 NVN 接口建贴图 → 生产胶水 wd_tex（包含 nvn_mtl.m）→ 真宽屏核心。
//   旧实现一律带 USE_RT：核心给 1280 宽的线性目标 1564，把它的绘制起成右移 142 的原比例页，存储装不下（10-26 巫师3 直连标志视频：左侧 11.1% 品红）；
//   只按「放不放得宽」一刀切又会把马车8 1920 宽、只画 1280 的交换链当成不放宽（1564 本来装得下）。
// 期望（手算，与被测实现无关）：屏宽 2346、整套放宽，k = 2346 / 1920。720 高普通目标放宽宽 = 1280 × k = 1564；1280 宽线性目标画满 1280 → 1564 装不下 → 原宽 1280；
//   1920 宽线性目标只画 1280 → 1564 ≤ 1920 装得下 → 按放宽登记，核心给 1920 × k = 2346。
// 窄屏加高同理（11-05 旷野之息 Duo 底部 180 行黑）：换到 1920×1350，k = 1、ky = 1350 / 1080 = 1.25。普通目标 720 → 900；1280×720 线性目标画满 720 → 900 装不下 → 原高 720
//   （旧实现只核宽：1280 × 1 装得下就按可加高登记，核心给 900，存储只有 720）；1920×1080 线性目标只画 720 → 900 ≤ 1080 装得下 → 核心给 1080 × 1.25 = 1350。
//   稀疏池（虚拟池）里的 1280×720 渲染目标（随包贴图、没有层级视图）可以换存储：开遍登记拿到 1280×900，tex_widen 后存储 1280×900、带渲染目标用途
//   （旧实现 tex_widen_why 对稀疏池一律回「放不宽」：开遍不登记、高仍 720，tex_widen 返回 0）。
#include "../gfx/nvn/nvn_mtl.m"
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static void *storage;
static unsigned checks, fails;
enum { U_POOL_SIZE = 16 << 20, U_W = 1280, U_H = 720, U_WIDE = 1564, U_LINEAR_OFFSET = 8 << 20, U_BIG_OFFSET = 12 << 20, U_BIG_W = 1920, U_BIG_H = 1080, U_BIG_WIDE = 2346 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))

static void make_rt(NVNtexture *t, NVNformat fmt, int flags, ptrdiff_t off, int w, int h) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device); API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, w, h); API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, fmt); API(nvnTextureBuilderSetFlags)(&b, flags);
    REQUIRE(API(nvnTextureBuilderGetStorageSize)(&b) <= (size_t)(U_POOL_SIZE - off));
    API(nvnTextureBuilderSetStorage)(&b, &pool, off); REQUIRE(API(nvnTextureInitialize)(t, &b));
}
static void expect(const char *what, uint32_t got, uint32_t want) {
    checks++; if (got != want) { fails++; printf("FAIL %s：期望 %u → 真结果 %u\n", what, want, got); }
}

int main(void) {
    @autoreleasepool {
        NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
        NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
        REQUIRE(API(nvnQueueInitialize)(&queue, &qb)); mtl_init(); REQUIRE(posix_memalign(&storage, 65536, U_POOL_SIZE) == 0); memset(storage, 0, U_POOL_SIZE);
        NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
        API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, U_POOL_SIZE);
        API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
        REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
        // 宽屏核心：屏宽 2346、整套放宽（直连第三层没有表时的缺省；同 wd_on 里 s2a_widen_init 的调用）
        g_wd = s2a_widen_init(2346, 1080, S2A_WIDEN_FULL); REQUIRE(g_wd == S2A_WIDEN_ALL);
        NVNtexture rt, lin, big;
        make_rt(&rt, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE, 0, U_W, U_H);
        make_rt(&lin, NVN_FORMAT_R8, NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET, U_LINEAR_OFFSET, U_W, U_H);
        make_rt(&big, NVN_FORMAT_R8, NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET, U_BIG_OFFSET, U_BIG_W, U_BIG_H);
        REQUIRE(tex_mtl((const tex_t *)&lin).buffer != nil && tex_mtl((const tex_t *)&big).buffer != nil);   // 前提：线性目标的存储确实建在池缓冲上（不然测不到要测的情形）
        pthread_mutex_lock(&g_wd_mu);
        uint32_t w_rt0 = wd_tex((const tex_t *)&rt, 0, 0), w_lin0 = wd_tex((const tex_t *)&lin, 0, 0);   // 开遍时（还不知道视口）
        uint32_t w_lin = wd_tex((const tex_t *)&lin, U_W, U_H), w_big = wd_tex((const tex_t *)&big, U_W, U_H);   // 第一笔绘制：视口 0..1280 × 0..720
        pthread_mutex_unlock(&g_wd_mu);
        expect("普通渲染目标（GPU 私有存储），开遍时", w_rt0, U_WIDE);
        expect("1280 宽线性渲染目标，开遍时（等第一笔绘制，不登记）", w_lin0, U_W);
        expect("1280 宽线性渲染目标画满 1280（放宽 1564 装不下）", w_lin, U_W);
        expect("1920 宽线性渲染目标只画 1280（放宽 1564 装得下）", w_big, U_BIG_WIDE);
        // 带剪裁的清屏（wd_clear_x，10-26 盘点第 13 项）：放宽目标上游戏横坐标按放宽比换算（640 × 1564 / 1280 = 782，1280 → 1564）；没放宽的线性目标原样
        { long x0 = 640, x1 = 1280; wd_clear_x((const tex_t *)&rt, 0, &x0, &x1); expect("清屏剪裁：放宽目标左边 640", (uint32_t)x0, 782); expect("清屏剪裁：放宽目标右边 1280", (uint32_t)x1, U_WIDE);
          long y0 = 640, y1 = 1280; wd_clear_x((const tex_t *)&lin, 0, &y0, &y1); expect("清屏剪裁：没放宽的线性目标左边", (uint32_t)y0, 640); expect("清屏剪裁：没放宽的线性目标右边", (uint32_t)y1, U_W); }
        // 窄屏加高：换屏到 1920×1350（同 Duo 内屏；同 wd_reaspect：核心换比例、清登记表）
        pthread_mutex_lock(&g_wd_mu); g_wd = s2a_widen_reaspect(1920, 1350); memset(g_wd_t, 0, sizeof g_wd_t); g_wd_nt = 0; pthread_mutex_unlock(&g_wd_mu);
        REQUIRE(g_wd == S2A_WIDEN_ALL && fabsf(s2a_widen_ky() - 1.25f) < 1e-4f && fabsf(s2a_widen_k() - 1.0f) < 1e-4f);
        NVNmemoryPool vp; memset(&vp, 0, sizeof vp);
        NVNmemoryPoolBuilder vb; API(nvnMemoryPoolBuilderSetDefaults)(&vb); API(nvnMemoryPoolBuilderSetDevice)(&vb, &device); API(nvnMemoryPoolBuilderSetStorage)(&vb, NULL, U_POOL_SIZE);
        API(nvnMemoryPoolBuilderSetFlags)(&vb, NVN_MEMORY_POOL_FLAGS_VIRTUAL | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS);
        REQUIRE(API(nvnMemoryPoolInitialize)(&vp, &vb));
        NVNtexture sp; NVNtextureBuilder sb; API(nvnTextureBuilderSetDefaults)(&sb); API(nvnTextureBuilderSetDevice)(&sb, &device); API(nvnTextureBuilderSetTarget)(&sb, NVN_TEXTURE_TARGET_2D);
        API(nvnTextureBuilderSetSize2D)(&sb, U_W, U_H); API(nvnTextureBuilderSetLevels)(&sb, 1); API(nvnTextureBuilderSetFormat)(&sb, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetStorage)(&sb, &vp, 0);
        REQUIRE(API(nvnTextureInitialize)(&sp, &sb)); const tex_t *spt = (const tex_t *)&sp;
        REQUIRE(nvn_sparse_pool(spt->pool) && tex_mtl(spt) != nil && [tex_get(spt->serial) isKindOfClass:[NvPkg class]] && ((NvPkg *)tex_get(spt->serial))->sparse);   // 前提：确实是稀疏池随包贴图
        pthread_mutex_lock(&g_wd_mu);
        wd_tex((const tex_t *)&rt, 0, 0); uint32_t h_rt = wd_tex_h((const tex_t *)&rt);
        wd_tex((const tex_t *)&lin, U_W, U_H); uint32_t h_lin = wd_tex_h((const tex_t *)&lin);
        wd_tex((const tex_t *)&big, U_W, U_H); uint32_t h_big = wd_tex_h((const tex_t *)&big);
        uint32_t w_sp = wd_tex(spt, 0, 0), h_sp = wd_tex_h(spt);   // 开遍时（同 wd_widen_rts）
        pthread_mutex_unlock(&g_wd_mu);
        expect("窄屏：普通渲染目标加高", h_rt, 900);
        expect("窄屏：1280×720 线性目标画满 720（加高 900 装不下）", h_lin, U_H);
        expect("窄屏：1920×1080 线性目标只画 720（加高 900 装得下）", h_big, 1350);
        expect("窄屏：稀疏池渲染目标开遍登记的高", h_sp, 900);
        int sw = tex_widen(spt, w_sp, h_sp); id<MTLTexture> sm = tex_mtl(spt);
        expect("窄屏：稀疏池渲染目标换存储", (uint32_t)sw, 1);
        expect("窄屏：稀疏池渲染目标存储高", sm ? (uint32_t)sm.height : 0, 900);
        expect("窄屏：稀疏池渲染目标存储宽", sm ? (uint32_t)sm.width : 0, U_W);
        expect("窄屏：稀疏池渲染目标新存储带渲染目标用途", sm ? (uint32_t)!!(sm.usage & MTLTextureUsageRenderTarget) : 0, 1);
        // 已释放的渲染目标照登记（11-05 旷野之息 Duo：游戏 Finalize 了场景目标对象、录好的命令每帧照样往里画）：快照一份对象再 Finalize，
        //   期望（手算）：登记拿到加高 720 → 900；排进待生效释放；释放生效后登记数回到登记前。旧实现：不登记 → 720
        NVNtexture dr; make_rt(&dr, NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE, 4 << 20, U_W, U_H);
        NVNtexture snap = dr; uint64_t dser = ((const tex_t *)&dr)->serial; API(nvnTextureFinalize)(&dr);
        REQUIRE(dser && !nvn_be_tex_is_live(dser));   // 前提：对象确实已释放
        pthread_mutex_lock(&g_wd_mu);
        wd_pr_apply(g_wd_npr); REQUIRE(!wd_pr_has(dser));   // Finalize 排的释放先生效（真实局：提交做完才生效，录好的命令下一帧再画进来）
        int nt0 = g_wd_nt; wd_tex((const tex_t *)&snap, U_W, U_H); uint32_t h_dead = wd_tex_h((const tex_t *)&snap); int queued = wd_pr_has(dser), nt1 = g_wd_nt;
        wd_pr_apply(g_wd_npr); int nt2 = g_wd_nt;
        pthread_mutex_unlock(&g_wd_mu);
        expect("窄屏：已释放的渲染目标照登记、拿到加高", h_dead, 900);
        expect("窄屏：已释放的渲染目标排进待生效释放", (uint32_t)queued, 1);
        expect("窄屏：登记后表里多一项", (uint32_t)(nt1 - nt0), 1);
        expect("窄屏：释放生效后登记数回到登记前", (uint32_t)(nt2 - nt0), 0);
        printf("%s t_nvn_wdusage：放不宽的存储不按放宽 / 加高登记给宽屏核心、稀疏池渲染目标能换存储（%u 条检查，%u 条不符）\n", fails ? "✗" : "✓", checks, fails);
        return fails != 0;
    }
}

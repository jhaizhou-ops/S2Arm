// 直连宽屏补齐通用模式的两样口径（10-26 总指挥：直连相对通用缺的每着色器常量读法、TILE_U 一次补齐）。包含 nvn_mtl.m 测生产胶水，链真宽屏核心。
//   ① 每着色器常量读法：直连库带 cbuf_use（dmsh_xlate CbufUseText）的着色器各自登记一个核心句柄（wd_sh），同一个着色器只登记一次；没读法的（旧库）用共用句柄，
//      顶点着色器带外推尾段的用可外推共用句柄。旧实现所有着色器一律共用句柄：核心按整个绑定区间判「读了被改写的矩阵」。
//   ② TILE_U：片元采样的合并句柄（贴图号 | 采样器号 << 20）的采样器横向重复寻址（NVN 1 重复 / 6 镜像重复）→ S2A_WIDEN_TEX_TILE_U，其余寻址 / 采样器号 0 /
//      没登记的采样器号 → 0。旧实现标志恒 0：平铺的地面纹理恰好 16:9 也被核心当页面源。
// 期望（手写，与被测实现无关）：见各条 REQUIRE / expect。旧代码反证：旧 widen_glue.inc 没有 wd_sh / wd_tex_flags，本单测编不过（红）。
#include "../gfx/nvn/nvn_mtl.m"
#include <stdio.h>
#include <stdlib.h>

static unsigned checks, fails;
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static void expect(const char *what, long got, long want) { checks++; if (got != want) { fails++; printf("FAIL %s：实得 %ld，期望 %ld\n", what, got, want); } }
static void reg_samp(int sid, int ws) { samp_par p = {0}; p.ws = (uint8_t)ws; p.lod_max = 1000; nvn_be_reg_samp(sid, &p); }

int main(void) {
    @autoreleasepool {
        mtl_init();
        // ② 平铺：采样器 5 重复、6 镜像重复、7 夹边（0）、8 夹边（7）；9 不登记
        reg_samp(5, 1); reg_samp(6, 6); reg_samp(7, 0); reg_samp(8, 7);
        pthread_mutex_lock(&g_rmu);
        expect("采样器重复寻址 → TILE_U", wd_tex_flags(3 | 5ull << 20), S2A_WIDEN_TEX_TILE_U);
        expect("采样器镜像重复 → TILE_U", wd_tex_flags(3 | 6ull << 20), S2A_WIDEN_TEX_TILE_U);
        expect("采样器夹边（0）→ 0", wd_tex_flags(3 | 7ull << 20), 0);
        expect("采样器夹边（7）→ 0", wd_tex_flags(3 | 8ull << 20), 0);
        expect("句柄里没有采样器号 → 0", wd_tex_flags(3), 0);
        expect("采样器号没登记 → 0", wd_tex_flags(3 | 9ull << 20), 0);
        pthread_mutex_unlock(&g_rmu);
        // ① 每着色器句柄：同 wd_on 起会话与共用句柄
        g_wd = s2a_widen_init(2346, 1080, S2A_WIDEN_FULL); REQUIRE(g_wd == S2A_WIDEN_ALL);
        g_wd_sh = s2a_widen_shader(0, NULL, 0); g_wd_sh_push = s2a_widen_shader(0, NULL, S2A_WIDEN_SH_PUSH); REQUIRE(g_wd_sh > 0 && g_wd_sh_push > 0 && g_wd_sh != g_wd_sh_push);
        NvShader *a = [NvShader new], *b = [NvShader new], *c = [NvShader new], *d = [NvShader new];
        a->cbu = @"0:0,1,2,3;2:*"; c->push = 1; d->cbu = @"1:20"; d->push = 1;
        int32_t ha = wd_sh(0, a), hd = wd_sh(0, d);
        checks++; if (!(ha > 0 && ha != g_wd_sh && ha != g_wd_sh_push)) { fails++; printf("FAIL 带读法的着色器拿到自己的句柄：实得 %d（共用 %d / 可外推 %d）\n", ha, g_wd_sh, g_wd_sh_push); }
        checks++; if (!(hd > 0 && hd != ha && hd != g_wd_sh && hd != g_wd_sh_push)) { fails++; printf("FAIL 带读法、带外推的顶点着色器拿到自己的句柄：实得 %d（a %d）\n", hd, ha); }
        expect("同一个着色器再取：同一个句柄（只登记一次）", wd_sh(0, a), ha);
        expect("没读法的着色器：共用句柄", wd_sh(1, b), g_wd_sh);
        expect("没读法、带外推的顶点着色器：可外推共用句柄", wd_sh(0, c), g_wd_sh_push);
        expect("带外推标志的着色器放在片元阶段：不按外推（共用句柄）", wd_sh(1, c), g_wd_sh);
        printf("%s t_nvn_wdshader：直连宽屏按着色器登记常量读法、平铺采样带 TILE_U（%u 条检查，%u 条不符）\n", fails ? "✗" : "✓", checks, fails);
        return fails != 0;
    }
}

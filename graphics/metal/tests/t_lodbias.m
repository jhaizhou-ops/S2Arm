// 采样器 LOD 偏置（#800）通用路径端到端单测：手写 SPIR-V（tests/t_lodbias_*.spvasm）→ 运行时现翻（gal_border.m 采样改写）→ 画 8×8 浮点目标 → 读回比手算期望。
// 两个子进程：缺省（本机 GPU 实测偏置生效就用 Metal 采样器原生 lodBias，gal_samp_caps.h s2a_lodbias_native）与 S2A_SAMP_EMU=1（强制着色器模拟：采样器不带偏置，
//   偏置经边框表 S2ABorder.lb 由采样辅助加到每次采样的 LOD 上）。两路都逐位等于手算期望。
// 期望（手算，不跑被测实现）：贴图 R32Float 8×8、4 级，第 L 级全部纹素 = L；采样器最近点缩放 + mip 线性 → 读数 = 夹到 [0, 3] 的实际 LOD（相邻两级按小数部分线性插值，
//   偏置取 0.25 的整倍数，插值结果可精确表示）。实际 LOD = 基础 LOD + 采样器偏置 b（+ 着色器偏置），Metal 26 原生语义（10-28 M5 Max 探针：隐式 / level / gradient / bias 四种都加）：
//   o0 = (隐式 0 + b, 隐式 + bias(0.5), level(1) + b, gradient 对应 LOD 1 + b)；o1 = (顶点 level(0) + b, 隐式带偏移 + b, 数组隐式 + b, 数组 bias(0.5) + b)
//   逐位相等，唯一容差：模拟一路的 gradient 形态 ±2/256 级（偏置只能乘进导数，硬件 log2 量化，见下）
// 反证：模拟子进程里核对采样器描述确实不带偏置（d.lodBias == 0）——没有模拟时这一项红，期望值仍对只可能是着色器加的
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_formats.h"
#include "../gal_internal.h"
#include "../gal_samp_caps.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
static void *slurp(const char *path, uint32_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL; fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    void *p = malloc((size_t)n); if (fread(p, 1, (size_t)n, f) != (size_t)n) { free(p); fclose(f); return NULL; } fclose(f); *len = (uint32_t)n; return p;
}
static uint32_t buf_of(const void *p, int n) { uint32_t b = nxgal_buf_create(n, 0); nxgal_buf_set_data(b, 0, p, n); return b; }
static float clampl(float x) { return x < 0 ? 0 : x > 3 ? 3 : x; }

static int child(const char *dir, int emu) {
    if (nxgal_init(0)) return 2;
    char p[1100]; uint32_t lv = 0, lf = 0;
    snprintf(p, sizeof p, "%s/t_lodbias_in/vs.spv", dir); void *vs = slurp(p, &lv);
    snprintf(p, sizeof p, "%s/t_lodbias_in/fs.spv", dir); void *fs = slurp(p, &lf);
    if (!vs || !fs) { printf("  ✗ 读不到 %s/t_lodbias_in/*.spv（make -C graphics/metal 生成）\n", dir); return 1; }
    int native = s2a_lodbias_native(MTLCreateSystemDefaultDevice());
    printf("· %s：本机判定 LOD 偏置%s\n", emu ? "S2A_SAMP_EMU=1" : "缺省", native ? "原生（采样器 lodBias）" : "着色器模拟");
    CHECK(!emu || !native, "S2A_SAMP_EMU=1 时应判为不原生");
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    nxgal_res_desc d[4] = {{0, 19, 1, 0, 34}, {2, 128, 1, 4, 32}, {2, 129, 1, 4, 2}, {2, 130, 1, 4, 32}};
    uint32_t prog = nxgal_prog_create(sh, 2, d, 4, 0xf);
    int st = nxgal_prog_status(prog, 1);
    CHECK(st == 0, "建程序失败（状态 %d）：%s", st, nxgal_prog_last_error());
    if (st) return 1;
    // 贴图：2D 与 2D 数组（2 层），8×8、4 级，第 L 级全部纹素 = L
    nxgal_tex_info t2 = {8, 8, 1, 4, 1, 1, 1, 4, F_R32Float, 0, 1, {2, 3, 4, 5}}, ta = t2; ta.depth = 2; ta.target = 4;   // target：1 二维 4 二维数组
    uint32_t tex = nxgal_tex_create(&t2), texa = nxgal_tex_create(&ta);
    for (int l = 0; l < 4; l++) { int w = 8 >> l; float px[128]; for (int i = 0; i < 2 * w * w; i++) px[i] = (float)l;
        nxgal_tex_set_data(tex, 0, l, NULL, px, w * w * 4); nxgal_tex_set_data(texa, 0, l, NULL, px, w * w * 4); nxgal_tex_set_data(texa, 1, l, NULL, px, w * w * 4); }
    nxgal_tex_info rt = {8, 8, 1, 1, 1, 1, 1, 16, F_R32G32B32A32Float, 0, 1, {2, 3, 4, 5}}; uint32_t rts[2] = {nxgal_tex_create(&rt), nxgal_tex_create(&rt)};
    static const float tri[9] = {-1, -1, 0, 3, -1, 0, -1, 3, 0};
    uint32_t vb = buf_of(tri, sizeof tri);
    float ub[16] = {0}; uint32_t cb = buf_of(ub, sizeof ub);   // d[0].y = 0：顶点 level(0)
    static const float B[] = {0, 1, -0.5f, 1.25f, 2.5f, -1, 0.75f};
    for (unsigned k = 0; k < sizeof B / sizeof *B; k++) {
        nxgal_sampler_info si = {5, 1, 1, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 0, 1000, B[k], 1};   // 缩小 5 = 最近点 + mip 线性，放大最近点，钳边
        MTLSamplerDescriptor *sd = gal_sampler_desc(&si);
        CHECK(sd.lodBias == (native ? B[k] : 0.0f), "偏置 %g：采样器描述 lodBias 期望 %g（%s）实得 %g", B[k], native ? B[k] : 0.0f, native ? "原生" : "模拟：偏置由着色器加", sd.lodBias);
        uint32_t smp = nxgal_sampler_create(&si);
        nxgal_set_render_targets(rts, 2, 0);
        nxgal_blend bl = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &bl);
        nxgal_depth_test dt = {0, 0, 8}; nxgal_set_depth_test(&dt);
        nxgal_stencil ss; memset(&ss, 0, sizeof ss); nxgal_set_stencil_test(&ss);
        nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
        nxgal_viewport vp = {0, 0, 8, 8, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
        nxgal_rect sc = {0, 0, 8, 8}; nxgal_set_scissors(&sc, 1);
        uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
        nxgal_set_program(prog);
        nxgal_buf_assign ua = {19, {cb, 0, (int32_t)sizeof ub, 0}}; nxgal_set_uniform_buffers(&ua, 1);
        nxgal_set_texture_sampler(5, 128, tex, smp); nxgal_set_texture_sampler(1, 129, tex, smp); nxgal_set_texture_sampler(5, 130, texa, smp);
        nxgal_vbuf v = {{vb, 0, (int32_t)sizeof tri, 0}, 12, 0}; nxgal_set_vertex_buffers(&v, 1);
        nxgal_vattr at = {0, 0, 0, F_R32G32B32Float}; nxgal_set_vertex_attribs(&at, 1);
        nxgal_set_topology(4);
        nxgal_draw(3, 1, 0, 0);
        static float o[2][256]; int rd = nxgal_tex_get_data(rts[0], 0, 0, o[0], sizeof o[0]) == (int)sizeof o[0] && nxgal_tex_get_data(rts[1], 0, 0, o[1], sizeof o[1]) == (int)sizeof o[1];
        const float b = B[k], e[2][4] = {{clampl(b), clampl(0.5f + b), clampl(1 + b), clampl(1 + b)}, {clampl(b), clampl(b), clampl(b), clampl(0.5f + b)}};
        static const char *nm[2][4] = {{"隐式", "bias(0.5)", "level(1)", "gradient(LOD 1)"}, {"顶点 level(0)", "隐式 + 偏移", "数组隐式", "数组 bias(0.5)"}};
        for (int a = 0; a < 2; a++) for (int c = 0; c < 4; c++) {
            // 容差：只有模拟一路的 gradient 形态放 2/256 级（偏置只能乘进导数 × 2^k，硬件由导数算 LOD 的 log2 按 1/256 级量化、近似；10-28 M5 实测非整数偏置低 1–2 档，
            //   整数偏置逐位），其余逐位
            float tol = !native && a == 0 && c == 3 ? 2.0f / 256 : 0; int eq = 0;
            for (int i = 0; i < 64; i++) eq += rd && fabsf(o[a][4 * i + c] - e[a][c]) <= tol;
            CHECK(eq == 64, "偏置 %g %s：期望 %g%s，相等 %d / 64 像素（像素 0 实得 %.9g）", b, nm[a][c], e[a][c], tol ? "（容差 2/256 级）" : "（逐位）", eq, o[a][c]);
        }
        nxgal_sampler_release(smp);
    }
    printf("%s %s：%d / %d 项通过\n", g_fail ? "✗" : "✓", emu ? "S2A_SAMP_EMU=1" : "缺省", g_checks - g_fail, g_checks);
    return g_fail != 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    char dir[1024]; snprintf(dir, sizeof dir, "%s", argv[0]); char *sl = strrchr(dir, '/'); if (sl) *sl = 0; else strcpy(dir, ".");
    if (argc == 3 && !strcmp(argv[1], "--child")) return child(dir, atoi(argv[2]));
    if (@available(macOS 26.0, *)) {} else { printf("· 跳过：系统早于 macOS 26（没有采样器 LOD 偏置属性，两路都是模拟，另由 S2A_SAMP_EMU 一路覆盖）\n"); }
    int bad = 0;
    for (int emu = 0; emu < 2; emu++) {
        fflush(NULL); pid_t pid = fork(); if (pid < 0) return 2;
        if (!pid) { if (emu) setenv("S2A_SAMP_EMU", "1", 1); else unsetenv("S2A_SAMP_EMU"); execl(argv[0], argv[0], "--child", emu ? "1" : "0", (char *)NULL); _exit(127); }
        int st = 0; waitpid(pid, &st, 0); int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0; bad += !ok;
    }
    printf("%s t_lodbias：缺省 / S2A_SAMP_EMU=1 两路子进程%s\n", bad ? "✗" : "✓", bad ? "有不过" : "全过");
    return bad != 0;
}

// 遍中操作不切遍（帧率能耗线 10-21）单测：走 nxgal_* 全路径画到离屏目标，读回比手算期望；渲染编码器数（g_gp_n[GP_RENC]）核「确实没切遍」。
// 期望值都按 GAL / Vulkan 语义手算（命令顺序：之前的绘制读旧数据、之后的读新数据），不跑被测实现。
// 用法：t_nobreak（新做法）；t_nobreak --old（各类开关退回旧做法：画面期望不变、编码器数按「切遍」核，用来反证计数判据）
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
static int g_test_alt = -1;
int s2a_alt_phase(void) { return g_test_alt; }   // 同局交替相位桩（盖掉 gal_core.m 的弱定义）
uint64_t gal_committed_fence(void);
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

GAL_MTL4_ZONE_BEGIN
extern uint64_t g_icnt_pre, g_icnt_pb, g_icnt_batch_n[2];
extern uint64_t g_restride_n[2], g_icnt_n[2], g_disp_n[2], g_pclr_pre, g_sync_lazy, g_texup_n[2], g_bufw_pre, g_seg_n[2], g_texcp_n[2];
extern int gal_prepass_test_any;
void gal_ca_test_reset(void);
// 假低区账本（渲染器 dlsym 取 s2a_lowva，布局同 runtime/include/s2a_lowva.h 版本 1）：fl_deny 时可选申请一律不给；note 累计账面
typedef struct { uint32_t size, version; int (*user)(const char *, void *, void *); int (*acquire)(int, uint64_t, uint64_t, int, const char *);
                 void (*note)(int, int64_t); void (*fail)(int, uint64_t, const char *); void (*snapshot)(uint64_t *, uint64_t *, uint64_t *, uint64_t *, uint64_t *); } fake_lv;
static int fl_deny, fl_users, fl_acq; static int64_t fl_held;
static int fl_user(const char *n, void *e, void *c) { (void)n; (void)e; (void)c; return ++fl_users; }
static int fl_acquire(int u, uint64_t b, uint64_t c, int opt, const char *w) { (void)u; (void)b; (void)c; (void)opt; (void)w; fl_acq++; return fl_deny ? -1 : 0; }
static void fl_note(int u, int64_t d) { (void)u; fl_held += d; }
static void fl_fail(int u, uint64_t b, const char *w) { (void)u; (void)b; (void)w; }
static void fl_snap(uint64_t *t, uint64_t *b, uint64_t *r, uint64_t *u, uint64_t *a) { *t = *b = *r = *u = *a = 0; }
static const fake_lv k_fl = { sizeof(fake_lv), 1, fl_user, fl_acquire, fl_note, fl_fail, fl_snap };
__attribute__((visibility("default"))) const void *s2a_lowva(void) { return &k_fl; }
static _Atomic int g_waited;
static void *wait_th(void *a) { nxgal_wait_sync((uint64_t)(uintptr_t)a); g_waited = 1; return NULL; }
const char *nxgal_test_vpull_msl(void);
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// vs：位置直取属性（顶点描述符）；vsp：顶点自取（取数表 [[buffer(26)]]，gal_vpull.m 的解码辅助）；fs：常量色
static NSString *const k_msl = @
"struct VIn { float4 pos [[attribute(0)]]; };\n"
"struct VOut { float4 pos [[position]]; };\n"
"struct Set0 { constant float4 *ubo [[id(0)]]; };\n"
"vertex VOut vs(VIn in [[stage_in]]) { VOut o; o.pos = float4(in.pos.xyz, 1.0); return o; }\n"
"vertex VOut vsp(constant S2AVtxAttr* t [[buffer(26)]], uint vid [[vertex_id]], uint iid [[instance_id]], uint bi [[base_instance]]) {\n"
"  VOut o; o.pos = float4(s2a_vf(t, 0u, vid, iid, bi).xyz, 1.0); return o; }\n"
"fragment float4 fs(VOut in [[stage_in]], constant Set0 &s0 [[buffer(0)]]) { return s0.ubo[0]; }\n"
"struct Set1 { device uint *s [[id(0)]]; };\n"
"fragment float4 fsw(VOut in [[stage_in]], constant Set0 &s0 [[buffer(0)]], constant Set1 &s1 [[buffer(1)]]) { s1.s[0] = 7u; return s0.ubo[0]; }\n"
// 派发用例：cs9 往存储缓冲写 9；fsr 读它，是 9 画绿、否则画红
"kernel void cs9(constant Set1 &s1 [[buffer(1)]], uint g [[thread_position_in_grid]]) { if (g == 0) s1.s[0] = 9u; }\n"
"fragment float4 fsr(VOut in [[stage_in]], constant Set0 &s0 [[buffer(0)]], constant Set1 &s1 [[buffer(1)]]) { return s1.s[0] == 9u ? float4(0, 1, 0, 1) : float4(1, 0, 0, 1); }\n"
// fst：采样集 2 的贴图中心（贴图整张同色时 = 同一像素读）
"struct Set2 { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
"fragment float4 fst(VOut in [[stage_in]], constant Set0 &s0 [[buffer(0)]], constant Set2 &s2 [[buffer(2)]]) { return s2.t.sample(s2.s, float2(0.5)); }\n"
// csw：计算核往集 1 的二维图像写绿（每线程一像素）
"struct SetW { texture2d<float, access::write> t [[id(0)]]; };\n"
"kernel void csw(constant SetW &s1 [[buffer(1)]], uint2 g [[thread_position_in_grid]]) { s1.t.write(float4(0, 1, 0, 1), g); }\n"
// fsv：把读到的值编进红通道（值 / 255），区分 0 与 5
"fragment float4 fsv(VOut in [[stage_in]], constant Set0 &s0 [[buffer(0)]], constant Set1 &s1 [[buffer(1)]]) { return float4(float(s1.s[0]) / 255.0, 0, 0, 1); }\n";

static MTL4LibraryFunctionDescriptor *fn(id<MTLLibrary> l, NSString *n) { MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = l; f.name = n; return f; }
static gal_arg g_args[2] = {{GAL_ARG_UBO, 0, 0, 0, 1, 1u << 5}, {GAL_ARG_SSBO, 1, 0, 0, 1, 1u << 5}};
enum { RGBA8 = 36, F_RGB32F = 33, D32F = 51 };
static nxgal_tex_info ti(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }

static void set_color(float r, float g, float b, float a) {
    float c[4] = {r, g, b, a}; uint32_t u = nxgal_buf_create(16, 0); nxgal_buf_set_data(u, 0, c, 16);
    nxgal_buf_assign a0 = {0, {u, 0, 16, 0}}; nxgal_set_uniform_buffers(&a0, 1);
}
// 四边形 [x0,x1]×[y0,y1]（裁剪空间，z = 0）按跨度 stride 打包进 buf 的字节（每顶点前 12 字节 float3，其余填 0xEE）
static void quad_bytes(uint8_t *o, int stride, float x0, float x1, float y0, float y1) {
    float v[12] = {x0, y0, 0, x1, y0, 0, x1, y1, 0, x0, y1, 0};
    memset(o, 0xEE, (size_t)stride * 4);
    for (int k = 0; k < 4; k++) memcpy(o + stride * k, v + 3 * k, 12);
}
static uint32_t quad_buf(int stride, float x0, float x1, float y0, float y1) {
    uint8_t q[64]; quad_bytes(q, stride, x0, x1, y0, y1);
    uint32_t b = nxgal_buf_create(stride * 4, 0); nxgal_buf_set_data(b, 0, q, stride * 4); return b;
}
static void use_vb(uint32_t b, int stride) {
    nxgal_vbuf vb = {{b, 0, stride * 4, 0}, stride, 0}; nxgal_set_vertex_buffers(&vb, 1);
    nxgal_vattr at = {0, 0, 0, F_RGB32F}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7 /* Quads */);
}
static void base_state(uint32_t prog) {
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_stencil s; memset(&s, 0, sizeof s); nxgal_set_stencil_test(&s);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
    nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
    nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    nxgal_set_program(prog);
}
// 读回 32×32 RGBA8；数某块（列 [cx0,cx1)、行 [cy0,cy1)）里等于 e 的像素
static uint8_t g_px[32 * 32 * 4];
static int readback(uint32_t tex) { return nxgal_tex_get_data(tex, 0, 0, g_px, sizeof g_px) == sizeof g_px; }
static int count_in(int cx0, int cx1, int cy0, int cy1, const uint8_t e[4]) {
    int n = 0; for (int y = cy0; y < cy1; y++) for (int x = cx0; x < cx1; x++) n += !memcmp(g_px + (y * 32 + x) * 4, e, 4); return n;
}
static void bind_ubo(uint32_t b, int off, int size) { nxgal_buf_assign a0 = {0, {b, off, size, 0}}; nxgal_set_uniform_buffers(&a0, 1); }
static uint32_t color_buf(int bytes, const float *c) { uint32_t b = nxgal_buf_create(bytes, 0); nxgal_buf_set_data(b, 0, c, bytes); return b; }
static void clear_depth(float v) { nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_ds(0, 1, v, 1, 0, 0); nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1); }
// 32×32 数组贴图（2 层）与单层视图
static nxgal_tex_info arr_info(int fmt) { nxgal_tex_info i = ti(32, 32, fmt, 4); i.depth = 2; i.target = 4; return i; }
static uint32_t layer_view(uint32_t arr, int fmt, int layer) { nxgal_tex_info i = ti(32, 32, fmt, 4); return nxgal_tex_view(arr, &i, layer, 0); }
static int count_layer(uint32_t tex, int layer, const uint8_t e[4]) {
    if (nxgal_tex_get_data(tex, layer, 0, g_px, sizeof g_px) != sizeof g_px) return -1; return count_in(0, 32, 0, 32, e);
}
static void clear_full(int idx, float r, float g, float b, float a) { float c[4] = {r, g, b, a}; nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_color(idx, 0, 1, 0xf, c); nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1); }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int old = argc > 1 && !strcmp(argv[1], "--old");
    if (!old) setenv("NXGAL_TEXCOPY_PRE", "1", 1);   // 遍内贴图拷贝挪遍前段（缺省关的新做法；--old 不开）
    if (old) { setenv("NXGAL_RESTRIDE_INPASS", "1", 1); setenv("NXGAL_PCLR_SPLIT", "1", 1); setenv("NXGAL_NO_UPPATCH", "1", 1); setenv("NXGAL_BARRIER_SPLIT", "1", 1); setenv("NXGAL_PREPASS_OFF", "1", 1); setenv("NXGAL_ICNT_INPASS", "1", 1); }
    // 「已完成」值落后 1000 个命令缓冲（gal_buf.m up_done）：有过 GPU 写的缓冲一律建不了影子，模拟真机 GPU 落后（马车8 遍内上传的成因）
    setenv("NXGAL_TEST_UPLAG", "1000", 1);
    if (nxgal_init(0)) return 2;
    // 用例 1–15 测挪动本身：最近有过挪动就每遍分段（不靠帧结构）；用例 16 关掉它测按遍序号预测
    gal_prepass_test_any = 1;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\n%@", [NSString stringWithUTF8String:nxgal_test_vpull_msl()], k_msl];
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("MSL 编译失败：%s\n", err.localizedDescription.UTF8String); return 2; }
    static gal_prog P, PP;
    P.live = 1; P.fn[1] = fn(lib, @"vs"); P.fn[5] = fn(lib, @"fs"); P.set_size[0] = 8; P.set_stages[0] = 1u << 5;
    P.args = g_args; P.nargs = 1; P.stage_set_size[5][0] = 8; P.vs_inputs = 1; P.fs_outputs = 1; P.hash = 0x5111;
    for (int i = 0; i < 6; i++) P.size_buf_index[i] = -1;
    PP = P; PP.fn[1] = fn(lib, @"vsp"); PP.vs_pulled = 1; PP.hash = 0x5222;
    // PW：片元写存储缓冲（集 1 绑定 0）
    static gal_prog PW; PW = P; PW.fn[5] = fn(lib, @"fsw"); PW.nargs = 2; PW.set_size[1] = 8; PW.set_stages[1] = 1u << 5; PW.stage_set_size[5][1] = 8; PW.hash = 0x5333;
    uint32_t prog = gal_prog_register_builtin(&P), progp = gal_prog_register_builtin(&PP), progw = gal_prog_register_builtin(&PW);
    // PR：片元读存储缓冲（集 1 绑定 0，只读绑定）；C9：计算核写存储缓冲（集 1 绑定 0）
    static gal_prog PR, C9; PR = PW; PR.fn[5] = fn(lib, @"fsr"); PR.hash = 0x5444;
    static gal_arg cargs[1] = {{GAL_ARG_SSBO, 1, 0, 0, 1, 1u << 0}};
    C9.live = 1; C9.is_compute = 1; C9.fn[0] = fn(lib, @"cs9"); C9.set_size[1] = 8; C9.set_stages[1] = 1u << 0; C9.args = cargs; C9.nargs = 1; C9.stage_set_size[0][1] = 8;
    C9.threadgroup = MTLSizeMake(32, 1, 1); C9.hash = 0x5555; for (int i = 0; i < 6; i++) C9.size_buf_index[i] = -1;
    static gal_prog PV; PV = PW; PV.fn[5] = fn(lib, @"fsv"); PV.hash = 0x5666;
    uint32_t progr = gal_prog_register_builtin(&PR), progc = gal_prog_register_builtin(&C9), progv = gal_prog_register_builtin(&PV);
    // PT：片元采样集 2 的贴图（集 0 常量缓冲照留）
    static gal_arg targs[3] = {{GAL_ARG_UBO, 0, 0, 0, 1, 1u << 5}, {GAL_ARG_TEX, 2, 0, 0, 1, 1u << 5}, {GAL_ARG_SMP, 2, 0, 8, 1, 1u << 5}};
    static gal_prog PT; PT = P; PT.fn[5] = fn(lib, @"fst"); PT.args = targs; PT.nargs = 3; PT.set_size[2] = 16; PT.set_stages[2] = 1u << 5; PT.stage_set_size[5][2] = 16; PT.hash = 0x5777;
    uint32_t progt = gal_prog_register_builtin(&PT);
    nxgal_sampler_info si = {1, 1, 1, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 0, 1000, 0, 1}; uint32_t smp = nxgal_sampler_create(&si);
    // CW：计算核写图像（集 1 绑定 0）
    static gal_arg wargs[1] = {{GAL_ARG_IMG, 1, 0, 0, 1, 1u << 0}};
    static gal_prog CW; CW = C9; CW.fn[0] = fn(lib, @"csw"); CW.args = wargs; CW.threadgroup = MTLSizeMake(8, 8, 1); CW.hash = 0x5888;
    uint32_t progcw = gal_prog_register_builtin(&CW);
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4);
    const uint8_t red[4] = {255, 0, 0, 255}, green[4] = {0, 255, 0, 255}, blue[4] = {0, 0, 255, 255}, yellow[4] = {255, 255, 0, 255};

    // 用例 1：顶点跨度 13（不是 4 的倍数）在开着的遍里第一次用到 → 重排派发。
    // ① 跨度 12 左半四边形画红（开遍）；② 跨度 13 右半四边形画绿（新重排）；
    // ③ 把这个跨度 13 缓冲改写成左上四分之一四边形（它这次提交已被用到 → 走镜像）再画蓝（重排缓存作废、新重排读镜像）。
    // 期望（命令顺序）：左上 16×16 蓝、左下 16×16 红、右半 16×32 绿。新做法：重排挪进预载，渲染编码器 1 个、预载重排 2 次；--old：每次重排切遍，3 个、在录流重排 2 次
    printf("· 遍中顶点重排（跨度 13）：左上蓝 / 左下红 / 右半绿；新做法 1 个渲染编码器、重排 2 次进预载（--old：3 个、2 次在录流）\n");
    {
        uint32_t A = nxgal_tex_create(&ci);
        nxgal_set_render_targets(&A, 1, 0); base_state(prog); clear_full(0, 0, 0, 0, 0);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), R = quad_buf(13, 0, 1, -1, 1);
        uint64_t e0 = g_gp_n[GP_RENC], r0 = g_restride_n[0], r1 = g_restride_n[1];
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        use_vb(R, 13); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint8_t q[52]; quad_bytes(q, 13, -1, 0, -1, 0); nxgal_buf_set_data(R, 0, q, 52);
        use_vb(R, 13); set_color(0, 0, 1, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, n0 = g_restride_n[0] - r0, n1 = g_restride_n[1] - r1;
        CHECK(readback(A), "读回失败");
        // GAL 视口按 Vulkan 约定：裁剪 y = -1 在第 0 行，y ∈ [-1,0] 是上半（行 0..15）
        int nb = count_in(0, 16, 0, 16, blue), nr = count_in(0, 16, 16, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nb == 256, "左上 16×16 期望蓝（裁剪 y∈[-1,0]，改写后的数据），实得 %d", nb);
        CHECK(nr == 256, "左下 16×16 期望红，实得 %d", nr);
        CHECK(ng == 512, "右半 16×32 期望绿（第②次绘制读改写前的数据），实得 %d", ng);
        CHECK(enc == (old ? 3u : 1u), "渲染编码器期望 %d 个，实得 %llu", old ? 3 : 1, (unsigned long long)enc);
        CHECK(n0 == (old ? 2u : 0u) && n1 == (old ? 0u : 2u), "重排派发期望 在录流 %d / 预载 %d，实得 %llu / %llu", old ? 2 : 0, old ? 0 : 2, (unsigned long long)n0, (unsigned long long)n1);
        nxgal_tex_release(A);
    }

    // 用例 2：源在本次提交的在录流里被 GPU 写过（拷贝进它）→ 不能挪进预载（预载读不到这次写），照旧在录流里重排。
    // ① 跨度 13 缓冲 V（屏幕外四边形 x∈[2,3]）先画一次（什么也不画，V 这段记已用）；② 在录流拷贝把右半四边形数据拷进 V（目标已用 → 不能进预载）；
    // ③ 画 V 黄色：重排必须读到拷贝后的数据 → 右半 512 像素黄（挪进预载会读到屏幕外的旧数据 → 0 像素）
    printf("· 源有在录流 GPU 写：重排照旧在录流里做，右半黄 512 像素\n");
    {
        uint32_t A = nxgal_tex_create(&ci);
        nxgal_set_render_targets(&A, 1, 0); base_state(prog); clear_full(0, 0, 0, 0, 0);
        uint32_t V = quad_buf(13, 2, 3, -1, 1), Q = quad_buf(13, 0, 1, -1, 1);
        uint64_t r0 = g_restride_n[0];
        use_vb(V, 13); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_buf_copy(Q, V, 0, 0, 52);
        use_vb(V, 13); set_color(1, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        CHECK(readback(A), "读回失败");
        int ny = count_in(16, 32, 0, 32, yellow), nr = count_in(0, 32, 0, 32, red);
        CHECK(ny == 512 && nr == 0, "期望右半 512 黄、0 红，实得 %d / %d", ny, nr);
        CHECK(g_restride_n[0] - r0 >= 1, "第③次重排期望在录流里做，实得在录流 %llu 次", (unsigned long long)(g_restride_n[0] - r0));
        nxgal_tex_release(A);
    }

    // 用例 3：顶点自取的程序（步长任意，按字节读）不重排：跨度 13 右半四边形画绿 → 右半 512 绿；新做法重排 0 次、渲染编码器 1 个（先画的跨度 12 左半红开遍）
    printf("· 顶点自取 + 跨度 13：右半绿、左半红；新做法不重排、1 个渲染编码器（--old：重排 1 次、2 个）\n");
    {
        uint32_t A = nxgal_tex_create(&ci);
        nxgal_set_render_targets(&A, 1, 0); base_state(progp); clear_full(0, 0, 0, 0, 0);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), R = quad_buf(13, 0, 1, -1, 1);
        uint64_t e0 = g_gp_n[GP_RENC], r0 = g_restride_n[0] + g_restride_n[1];
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        use_vb(R, 13); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, nr = g_restride_n[0] + g_restride_n[1] - r0;
        CHECK(readback(A), "读回失败");
        int ng = count_in(16, 32, 0, 32, green), nred = count_in(0, 16, 0, 32, red);
        CHECK(ng == 512 && nred == 512, "期望右半 512 绿、左半 512 红，实得 %d / %d", ng, nred);
        CHECK(enc == (old ? 2u : 1u) && nr == (old ? 1u : 0u), "期望渲染编码器 %d 个 / 重排 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 1 : 0, (unsigned long long)enc, (unsigned long long)nr);
        nxgal_tex_release(A);
    }

    // 用例 4：挂起清屏的视图与同底层别的视图同组（马车8：数组贴图第 0 / 1 层视图挂颜色槽 0 / 1）。
    // 数组 T 两层先填灰；[V0] 清红（挂起）→ [V0, V1] 开遍（只画屏幕外）→ V0 全红、V1 全灰。新做法 V0 以清开遍、1 个渲染编码器；--old：单独落实 + 开遍 2 个
    printf("· 挂起清屏 + 同底层另一层视图同组：第 0 层红、第 1 层灰；新做法 1 个渲染编码器（--old：2 个）\n");
    {
        nxgal_tex_info ai = arr_info(RGBA8); uint32_t T = nxgal_tex_create(&ai);
        uint8_t g[32 * 32 * 4]; memset(g, 64, sizeof g); nxgal_tex_set_data(T, 0, 0, NULL, g, sizeof g); nxgal_tex_set_data(T, 1, 0, NULL, g, sizeof g);
        uint32_t V0 = layer_view(T, RGBA8, 0), V1 = layer_view(T, RGBA8, 1);
        nxgal_set_render_targets(&V0, 1, 0); base_state(prog); clear_full(0, 1, 0, 0, 1);
        uint32_t two[2] = {V0, V1}; nxgal_set_render_targets(two, 2, 0);
        uint32_t off = quad_buf(12, 2, 3, -1, 1);
        uint64_t e0 = g_gp_n[GP_RENC];
        use_vb(off, 12); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0;
        const uint8_t gray[4] = {64, 64, 64, 64};
        int n0 = count_layer(T, 0, red), n1 = count_layer(T, 1, gray);
        CHECK(n0 == 1024 && n1 == 1024, "期望第 0 层 1024 红、第 1 层 1024 灰，实得 %d / %d", n0, n1);
        CHECK(enc == (old ? 2u : 1u), "渲染编码器期望 %d 个，实得 %llu", old ? 2 : 1, (unsigned long long)enc);
        nxgal_tex_release(V0); nxgal_tex_release(V1); nxgal_tex_release(T);
    }

    // 用例 5：挂起清屏的视图（单层）落在附件视图（整个数组）里：开遍读入、遍内按层补画清屏，之后的绘制画在上面。
    // 颜色：数组 T 两层先填灰；[V1] 清蓝（挂起）→ [T] 开遍，画左半红（不写层号 → 第 0 层）→ 第 0 层左半红右半灰、第 1 层全蓝。
    // 深度：数组 D 两层；[L0] 清 0.75 并开遍落实；[L1] 清 0.25（挂起）→ [T] + [D] 同上绘制（深度测试关）→ D 第 0 层全 0.75、第 1 层全 0.25。
    // 新做法 1 个渲染编码器（--old：两个挂起清屏各单独落实，3 个）
    printf("· 挂起清屏落在整组附件的某层里：第 0 层左红右灰、第 1 层全蓝；深度第 0 层 0.75、第 1 层 0.25；新做法 1 个渲染编码器（--old：3 个）\n");
    {
        nxgal_tex_info ai = arr_info(RGBA8), di = arr_info(D32F); uint32_t T = nxgal_tex_create(&ai), D = nxgal_tex_create(&di);
        uint8_t g[32 * 32 * 4]; memset(g, 64, sizeof g); nxgal_tex_set_data(T, 0, 0, NULL, g, sizeof g); nxgal_tex_set_data(T, 1, 0, NULL, g, sizeof g);
        uint32_t V1 = layer_view(T, RGBA8, 1), L0 = layer_view(D, D32F, 0), L1 = layer_view(D, D32F, 1);
        uint32_t none = 0;
        nxgal_set_render_targets(&none, 1, L0); base_state(prog); clear_depth(0.75f);
        uint32_t off = quad_buf(12, 2, 3, -1, 1), L = quad_buf(12, -1, 0, -1, 1);
        use_vb(off, 12); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_render_targets(&V1, 1, 0); clear_full(0, 0, 0, 1, 1);
        nxgal_set_render_targets(&none, 1, L1); clear_depth(0.25f);
        nxgal_set_render_targets(&T, 1, D);
        uint64_t e0 = g_gp_n[GP_RENC];
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0;
        const uint8_t gray[4] = {64, 64, 64, 64};
        CHECK(nxgal_tex_get_data(T, 0, 0, g_px, sizeof g_px) == sizeof g_px, "读回失败");
        int nl = count_in(0, 16, 0, 32, red), nrg = count_in(16, 32, 0, 32, gray), n1 = count_layer(T, 1, blue);
        CHECK(nl == 512 && nrg == 512, "第 0 层期望左半 512 红、右半 512 灰，实得 %d / %d", nl, nrg);
        CHECK(n1 == 1024, "第 1 层期望 1024 蓝，实得 %d", n1);
        float dp[1024]; int d0 = 0, d1 = 0;
        nxgal_tex_get_data(D, 0, 0, dp, sizeof dp); for (int i = 0; i < 1024; i++) d0 += dp[i] == 0.75f;
        nxgal_tex_get_data(D, 1, 0, dp, sizeof dp); for (int i = 0; i < 1024; i++) d1 += dp[i] == 0.25f;
        CHECK(d0 == 1024 && d1 == 1024, "深度期望第 0 层 1024 个 0.75、第 1 层 1024 个 0.25，实得 %d / %d（[0] = %g）", d0, d1, dp[0]);
        CHECK(enc == (old ? 3u : 1u), "渲染编码器期望 %d 个，实得 %llu", old ? 3 : 1, (unsigned long long)enc);
        nxgal_tex_release(V1); nxgal_tex_release(L0); nxgal_tex_release(L1); nxgal_tex_release(T); nxgal_tex_release(D);
    }

    // 用例 6：遍内上传，缓冲有 GPU 写在途、建不了影子（马车8：256 KB 存储缓冲，上一帧绑过可写）→ 暂存补丁，不切遍。
    // U（16 字节颜色）由拷贝写成红（GPU 写）后提交；新提交里 ① 左半画 U（红）② 写 U = 绿（命中已用区间）③ 右半画 U（绿）；
    // ④ 写 U = 蓝（补丁）→ 在录流拷贝把黄拷进 U（非镜像用法：补丁先拷回，再拷黄）→ ⑤ 上四分之一画 U（黄）。
    // 期望：左下四分之一红、右下绿、上半黄（⑤ 盖掉 ① ③ 的上半）；读回 U = 黄。新做法 ①–③ 1 个渲染编码器（--old：上传切遍 2 个）
    printf("· 遍内上传（GPU 写在途、无影子）：左下红 / 右下绿 / 上半黄，读回黄；新做法 ①–③ 1 个渲染编码器（--old：2 个）\n");
    {
        uint32_t A = nxgal_tex_create(&ci);
        const float cr[4] = {1, 0, 0, 1}, cg[4] = {0, 1, 0, 1}, cb[4] = {0, 0, 1, 1}, cy[4] = {1, 1, 0, 1};
        uint32_t R0 = color_buf(16, cr), Y = color_buf(16, cy), U = nxgal_buf_create(16, 0);
        nxgal_buf_copy(R0, U, 0, 0, 16); nxgal_flush();
        nxgal_set_render_targets(&A, 1, 0); base_state(prog); clear_full(0, 0, 0, 0, 0);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1), T = quad_buf(12, -1, 1, -1, 0);
        uint64_t e0 = g_gp_n[GP_RENC];
        use_vb(L, 12); bind_ubo(U, 0, 16); nxgal_draw(4, 1, 0, 0);
        nxgal_buf_set_data(U, 0, cg, 16);
        use_vb(Rq, 12); bind_ubo(U, 0, 16); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0;
        nxgal_buf_set_data(U, 0, cb, 16);
        nxgal_buf_copy(Y, U, 0, 0, 16);
        use_vb(T, 12); bind_ubo(U, 0, 16); nxgal_draw(4, 1, 0, 0);
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 16, 32, red), ng = count_in(16, 32, 16, 32, green), ny = count_in(0, 32, 0, 16, yellow);
        CHECK(nr == 256 && ng == 256 && ny == 512, "期望左下 256 红、右下 256 绿、上半 512 黄，实得 %d / %d / %d", nr, ng, ny);
        CHECK(enc == (old ? 2u : 1u), "①–③ 渲染编码器期望 %d 个，实得 %llu", old ? 2 : 1, (unsigned long long)enc);
        float u[4] = {0}; nxgal_buf_get_data(U, 0, 16, u);
        CHECK(!memcmp(u, cy, 16), "读回 U 期望黄 (1,1,0,1)，实得 (%g,%g,%g,%g)", u[0], u[1], u[2], u[3]);
        nxgal_tex_release(A);
    }

    // 用例 7：补丁之后写它没用到的那半（相交的写要接着走补丁、按序）：U2 32 字节 = [红, 红]，GPU 写在途；
    // ① 画 U2[0,16)（红，左半）② 写 U2 整段 = [绿, 绿]（命中 → 补丁）③ 写 U2[16,32) = 蓝（这半没被读过；若进预载会被 ② 的补丁在提交时盖成绿）
    // ④ 右半画 U2[16,32) → 蓝；提交后读回 U2 = [绿, 蓝]
    printf("· 补丁之后写同缓冲没读过的那半：右半蓝、左半红，读回 [绿, 蓝]\n");
    {
        uint32_t A = nxgal_tex_create(&ci);
        const float rr[8] = {1, 0, 0, 1, 1, 0, 0, 1}, gg[8] = {0, 1, 0, 1, 0, 1, 0, 1}, cb[4] = {0, 0, 1, 1};
        uint32_t R0 = color_buf(32, rr), U2 = nxgal_buf_create(32, 0);
        nxgal_buf_copy(R0, U2, 0, 0, 32); nxgal_flush();
        nxgal_set_render_targets(&A, 1, 0); base_state(prog); clear_full(0, 0, 0, 0, 0);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        use_vb(L, 12); bind_ubo(U2, 0, 16); nxgal_draw(4, 1, 0, 0);
        nxgal_buf_set_data(U2, 0, gg, 32);
        nxgal_buf_set_data(U2, 16, cb, 16);
        use_vb(Rq, 12); bind_ubo(U2, 16, 16); nxgal_draw(4, 1, 0, 0);
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), nb = count_in(16, 32, 0, 32, blue);
        CHECK(nr == 512 && nb == 512, "期望左半 512 红、右半 512 蓝，实得 %d / %d", nr, nb);
        float u[8] = {0}; nxgal_buf_get_data(U2, 0, 32, u);
        CHECK(!memcmp(u, gg, 16) && !memcmp(u + 4, cb, 16), "读回 U2 期望 [绿, 蓝]，实得 [(%g,%g,%g,%g), (%g,%g,%g,%g)]", u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7]);
        nxgal_tex_release(A);
    }

    // 用例 8：遍内内存屏障（Barrier）。① 左半画红 → 屏障 → ② 右半画绿：两边都没有存储写，新做法不拆遍（1 个渲染编码器，--old 2 个）；
    // ③ 左半用写存储缓冲的程序画（屏障前有存储写）→ 屏障 → ④ 右半画：拆遍；⑤ 屏障 → ⑥ 写存储缓冲的程序画（屏障后的写）：拆遍。
    // 期望：画面 ①② 左红右绿、③④ 左蓝右黄；存储缓冲 [0] = 7；③–⑥ 两种做法都 3 个渲染编码器
    printf("· 遍内内存屏障：两侧都没有存储写不拆遍（新做法 1 个渲染编码器，--old 2 个）；有存储写照拆（3 个），存储缓冲 = 7\n");
    {
        uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        uint32_t SB = nxgal_buf_create(16, 0); uint32_t z[4] = {0}; nxgal_buf_set_data(SB, 0, z, 16);
        nxgal_buf_assign sa = {0, {SB, 0, 16, 1}}; nxgal_set_storage_buffers(&sa, 1);
        nxgal_set_render_targets(&A, 1, 0); base_state(prog); clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC];
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_barrier(0);
        use_vb(Rq, 12); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc1 = g_gp_n[GP_RENC] - e0;
        nxgal_set_render_targets(&B, 1, 0); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC];
        nxgal_set_program(progw); use_vb(L, 12); set_color(0, 0, 1, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_barrier(0);
        nxgal_set_program(prog); use_vb(Rq, 12); set_color(1, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_barrier(1);
        nxgal_set_program(progw); use_vb(L, 12); set_color(0, 0, 1, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc2 = g_gp_n[GP_RENC] - e0;
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "A 期望左 512 红、右 512 绿，实得 %d / %d", nr, ng);
        CHECK(readback(B), "读回失败");
        int nb = count_in(0, 16, 0, 32, blue), ny = count_in(16, 32, 0, 32, yellow);
        CHECK(nb == 512 && ny == 512, "B 期望左 512 蓝、右 512 黄，实得 %d / %d", nb, ny);
        uint32_t sv[4] = {0}; nxgal_buf_get_data(SB, 0, 16, sv);
        CHECK(sv[0] == 7, "存储缓冲 [0] 期望 7，实得 %u", sv[0]);
        CHECK(enc1 == (old ? 2u : 1u), "①② 渲染编码器期望 %d 个，实得 %llu", old ? 2 : 1, (unsigned long long)enc1);
        CHECK(enc2 == 3u, "③–⑥ 渲染编码器期望 3 个，实得 %llu", (unsigned long long)enc2);
        nxgal_tex_release(A); nxgal_tex_release(B);
    }

    // 用例 9：间接计数绘制（怪猎村子每帧上千次，原先每次整理参数都切遍）。参数缓冲 2 条（步长 32 字节，非索引 4 字）：
    // 第 0 条 {4,1,0,0} 画顶点 0–3 = 右半四边形（三角带），第 1 条 {4,1,4,0} 画顶点 4–7 = 整屏；计数 = 1 → 只画第 0 条。
    // ① 先画一次让「最近用过间接计数」成立（之后开遍分段）；② 新遍：左半画红 → 间接计数画绿 → 期望左红右绿（第 1 条画了就全绿）。
    // 新做法 ② 1 个渲染编码器、整理进预载 1 次（参数 / 计数本命令缓冲里没被写过，预载里读到的与此刻相同）；--old 2 个、在录流 1 次
    // ③ 同一遍里先有存储写（写存储缓冲的程序画左半）→ 间接计数：参数没被写过，照样进预载、不切遍（改前遍前段读不到遍里的写、只能切遍）
    // ④ 计数改了要按序：新遍里间接计数画（计数 = 0，什么都不画）→ 在录流拷贝把计数改成 1（计数缓冲本提交已用 → 不进预载，收遍）→ 画左半红开新遍 → 再间接计数画 → 期望右半绿
    //   （遍前段若排到拷贝之前，读到计数 0，右半不画）
    printf("· 间接计数绘制：只画计数内的条目、左红右绿；新做法不切遍（1 个渲染编码器，--old 2 个）；遍里有存储写照切；计数在遍间改按序生效\n");
    {
        nxgal_set_topology(5 /* TriangleStrip */);
        uint8_t vb[12 * 8]; float v[24] = {0, -1, 0, 1, -1, 0, 0, 1, 0, 1, 1, 0, -1, -1, 0, 1, -1, 0, -1, 1, 0, 1, 1, 0}; memcpy(vb, v, sizeof v);
        uint32_t V = nxgal_buf_create(sizeof vb, 0); nxgal_buf_set_data(V, 0, vb, sizeof vb);
        uint32_t args[16] = {4, 1, 0, 0, 0, 0, 0, 0, 4, 1, 4, 0, 0, 0, 0, 0};
        uint32_t AR = nxgal_buf_create(64, 0); nxgal_buf_set_data(AR, 0, args, 64);
        uint32_t one = 1, zero = 0;
        uint32_t C1 = nxgal_buf_create(16, 0); nxgal_buf_set_data(C1, 0, &one, 4);
        uint32_t C0 = nxgal_buf_create(16, 0); nxgal_buf_set_data(C0, 0, &zero, 4);
        uint32_t ONE = nxgal_buf_create(16, 0); nxgal_buf_set_data(ONE, 0, &one, 4);
        nxgal_buf_range ar = {AR, 0, 64, 0}, c1 = {C1, 0, 16, 0}, c0 = {C0, 0, 16, 0};
        uint32_t L = quad_buf(12, -1, 0, -1, 1);
        uint32_t A = nxgal_tex_create(&ci);
        // ①
        nxgal_set_render_targets(&A, 1, 0); base_state(prog); clear_full(0, 0, 0, 0, 0);
        nxgal_vbuf vv = {{V, 0, (int32_t)sizeof vb, 0}, 12, 0}; nxgal_vattr at = {0, 0, 0, F_RGB32F};
        nxgal_set_vertex_buffers(&vv, 1); nxgal_set_vertex_attribs(&at, 1); set_color(0, 1, 0, 1);
        nxgal_draw_indirect_count(&ar, &c1, 2, 32, 0); nxgal_flush();
        // ②
        clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], i0 = g_icnt_n[0], i1 = g_icnt_pre;
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0); nxgal_set_topology(5);
        nxgal_set_vertex_buffers(&vv, 1); set_color(0, 1, 0, 1); nxgal_draw_indirect_count(&ar, &c1, 2, 32, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, n0 = g_icnt_n[0] - i0, n1 = g_icnt_pre - i1;
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "② 期望左 512 红、右 512 绿（第 1 条不画），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && n0 == (old ? 1u : 0u) && n1 == (old ? 0u : 1u), "② 期望渲染编码器 %d 个、整理 在录流 %d / 预载 %d，实得 %llu、%llu / %llu",
              old ? 2 : 1, old ? 1 : 0, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)n0, (unsigned long long)n1);
        // ②b 合批（NXGAL_ICNT_BATCH，缺省开）：同一提交里进预载的 3 次整理（计数 1 / 1 / 0）提交时一个派发做完，画面同 ②
        clear_full(0, 0, 0, 0, 0);
        uint64_t b0 = g_icnt_batch_n[0], b1 = g_icnt_batch_n[1];
        const char *bo = getenv("NXGAL_ICNT_BATCH"); int batch = !old && !(bo && *bo == '0');
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0); nxgal_set_topology(5);
        nxgal_set_vertex_buffers(&vv, 1); set_color(0, 1, 0, 1);
        nxgal_draw_indirect_count(&ar, &c1, 2, 32, 0); nxgal_draw_indirect_count(&ar, &c0, 2, 32, 0); nxgal_draw_indirect_count(&ar, &c1, 2, 32, 0);
        CHECK(readback(A), "读回失败");
        nr = count_in(0, 16, 0, 32, red); ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "②b 期望左 512 红、右 512 绿，实得 %d / %d", nr, ng);
        CHECK(g_icnt_batch_n[0] - b0 == (batch ? 1u : 0u) && g_icnt_batch_n[1] - b1 == (batch ? 3u : 0u), "②b 合批%s：期望派发 %d 次、合进 %d 条，实得 %llu / %llu", batch ? "开" : "关",
              batch ? 1 : 0, batch ? 3 : 0, (unsigned long long)(g_icnt_batch_n[0] - b0), (unsigned long long)(g_icnt_batch_n[1] - b1));
        // ③
        uint32_t SB = nxgal_buf_create(16, 0); nxgal_buf_assign sa = {0, {SB, 0, 16, 1}}; nxgal_set_storage_buffers(&sa, 1);
        clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC]; i0 = g_icnt_n[0]; i1 = g_icnt_pre;
        nxgal_set_program(progw); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0); nxgal_set_topology(5);
        nxgal_set_program(prog); nxgal_set_vertex_buffers(&vv, 1); set_color(0, 1, 0, 1); nxgal_draw_indirect_count(&ar, &c1, 2, 32, 0);
        enc = g_gp_n[GP_RENC] - e0; n0 = g_icnt_n[0] - i0; n1 = g_icnt_pre - i1;
        CHECK(readback(A), "读回失败");
        nr = count_in(0, 16, 0, 32, red); ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512 && enc == (old ? 2u : 1u) && n0 == (old ? 1u : 0u) && n1 == (old ? 0u : 1u), "③ 期望左红右绿、渲染编码器 %d 个、在录流 %d / 预载 %d，实得 %d / %d、%llu、%llu / %llu",
              old ? 2 : 1, old ? 1 : 0, old ? 0 : 1, nr, ng, (unsigned long long)enc, (unsigned long long)n0, (unsigned long long)n1);
        // ④
        clear_full(0, 0, 0, 0, 0);
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0); nxgal_set_topology(5);
        nxgal_set_vertex_buffers(&vv, 1); set_color(0, 1, 0, 1); nxgal_draw_indirect_count(&ar, &c0, 2, 32, 0);
        nxgal_buf_copy(ONE, C0, 0, 0, 4);
        // 拷贝收了遍：先画一次开新遍，间接计数整理才落进新遍的遍前段（必须排在拷贝之后）
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0); nxgal_set_topology(5);
        nxgal_set_vertex_buffers(&vv, 1); set_color(0, 1, 0, 1);
        i1 = g_icnt_pre;
        nxgal_draw_indirect_count(&ar, &c0, 2, 32, 0);
        // 计数缓冲本命令缓冲里被在录流拷贝改过：第二次整理绝不能进预载（预载排在拷贝之前，读到计数 0、右半不画）
        CHECK(g_icnt_pre - i1 == 0u, "④ 第二次整理期望不进预载，实得进了 %llu 次", (unsigned long long)(g_icnt_pre - i1));
        CHECK(readback(A), "读回失败");
        nr = count_in(0, 16, 0, 32, red); ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "④ 期望左 512 红、右 512 绿（计数改成 1 后的那次画了），实得 %d / %d", nr, ng);
        nxgal_set_topology(7);
        nxgal_tex_release(A);
    }

    // 用例 10：遍内派发挪到遍前段（帧级调度）。cs9 往存储缓冲写 9，fsr 读它：是 9 画绿、否则红。期望按命令顺序：派发之前的绘制读旧值 0、之后的读 9。
    // ① 本帧第一次遍内派发（遍前段还没开）：照旧切遍，记「想要」——之后开的遍分段
    // ② 新遍：左半画红 → 派发写新缓冲 S2（本次提交没人用过）→ 右半 fsr 读 S2 画绿。新做法 1 个渲染编码器、派发进遍前段 1 次；--old 2 个、在录流 1 次
    // ③ 遍里先有存储写（PW 写 SB）→ 派发：照旧切遍（遍前段读不到遍里的写），2 个渲染编码器
    // ④ 派发要写的缓冲本遍里更早已被读过：右半 fsr 读 S3（0 → 红）→ 派发写 S3 → 左半 fsr 读 S3（9 → 绿）：照旧切遍（2 个），右红左绿
    // ⑤ 要写的缓冲只在更早的遍里被读过：P1 右半 fsr 读 S4（0 → 红）→ 换遍 P2：派发写 S4 → 左半 fsr 读 S4（9 → 绿）。遍前段排在 P1 之后、P2 之前：
    //   P1 仍读到旧值（右红）、P2 读到新值（左绿）；新做法 P2 1 个渲染编码器、派发进遍前段（--old 2 个）
    // ⑥ 派发要写的缓冲有待拷回镜像、待拷回的区间本遍没人用过：P1 右半 fsr 读 U（0 → 红）→ 换遍 P2：上传 U = 5（U 本提交已用 → 走镜像）→ 派发写 U = 9 → 左半 fsr 读 U（9 → 绿）。
    //   拷回与派发一并进遍前段、按序（先拷回 5 再写 9）：右红左绿；新做法 P2 1 个渲染编码器（--old 2 个）
    // ⑧ 只差待拷回这一条：U3 32 字节，P 里右半 fsv 读 U3[0..16)（0 → 红通道 0）→ 上传 U3[0..16) = 5（镜像）→ 派发写 U3[16..32) = 9（本遍没人用过）→ 左半 fsr 读 U3[16..32)（9 → 绿）。
    //   派发要先拷回 U3 的待拷回区间 [0,16)，它本遍已被右半读过 → 不能提前，照切（2 个）；右半红通道必须是 0（提前拷回会读到 5）
    // ⑦ 待拷回的区间本遍已被读过：P3 右半 fsr 读 U2（0 → 红）→ 上传 U2 = 5（镜像）→ 派发写 U2 = 9 → 左半 fsr 读 U2（9 → 绿）：拷回提前会被右半读到，照切（2 个），右红左绿
    printf("· 遍内派发：之前的绘制读旧值、之后的读新值；新做法派发挪到遍前段不切遍（1 个渲染编码器，--old 2 个）；遍里有存储写、或要写的缓冲本遍已被读过照切\n");
    {
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        uint32_t z[4] = {0};
        // 每段前先换到 D 再换回 A：结束上一段留着的渲染遍，本段第一次绘制才开遍（编码器数从这里数）
#define FRESH() do { nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); } while (0)
        uint32_t S1 = nxgal_buf_create(16, 0), S2 = nxgal_buf_create(16, 0), S3 = nxgal_buf_create(16, 0), S4 = nxgal_buf_create(16, 0), SB = nxgal_buf_create(16, 0);
        nxgal_buf_set_data(S1, 0, z, 16); nxgal_buf_set_data(S2, 0, z, 16); nxgal_buf_set_data(S3, 0, z, 16); nxgal_buf_set_data(S4, 0, z, 16); nxgal_buf_set_data(SB, 0, z, 16);
        nxgal_buf_assign w4 = {0, {S4, 0, 16, 1}}, r4 = {0, {S4, 0, 16, 0}};
        uint32_t U = nxgal_buf_create(16, 0), U2 = nxgal_buf_create(16, 0); nxgal_buf_set_data(U, 0, z, 16); nxgal_buf_set_data(U2, 0, z, 16);
        nxgal_buf_assign wu = {0, {U, 0, 16, 1}}, ru = {0, {U, 0, 16, 0}}, wu2 = {0, {U2, 0, 16, 1}}, ru2 = {0, {U2, 0, 16, 0}};
        uint32_t five[4] = {5, 0, 0, 0};
        nxgal_buf_assign w1 = {0, {S1, 0, 16, 1}}, w2 = {0, {S2, 0, 16, 1}}, w3 = {0, {S3, 0, 16, 1}}, r2 = {0, {S2, 0, 16, 0}}, r3 = {0, {S3, 0, 16, 0}}, wb = {0, {SB, 0, 16, 1}};
        // ①
        nxgal_set_render_targets(&A, 1, 0); base_state(prog); clear_full(0, 0, 0, 0, 0);
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_storage_buffers(&w1, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
        // ②
        FRESH(); nxgal_set_program(prog); clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], d0 = g_disp_n[0], d1 = g_disp_n[1];
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_storage_buffers(&w2, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
        nxgal_set_storage_buffers(&r2, 1); nxgal_set_program(progr); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, n0 = g_disp_n[0] - d0, n1 = g_disp_n[1] - d1;
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "② 期望左 512 红、右 512 绿（右半读到派发写的 9），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && n1 == (old ? 0u : 1u) && n0 == (old ? 1u : 0u), "② 期望渲染编码器 %d 个、派发在录流 %d / 遍前段 %d，实得 %llu / %llu / %llu",
              old ? 2 : 1, old ? 1 : 0, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)n0, (unsigned long long)n1);
        // ③
        FRESH(); nxgal_set_program(prog); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC]; d0 = g_disp_n[0];
        nxgal_set_storage_buffers(&wb, 1); nxgal_set_program(progw); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_storage_buffers(&w1, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
        nxgal_set_program(prog); use_vb(Rq, 12); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0; n0 = g_disp_n[0] - d0;
        CHECK(enc == 2 && n0 == 1, "③ 遍里有存储写：期望渲染编码器 2 个、派发在录流 1 次，实得 %llu / %llu", (unsigned long long)enc, (unsigned long long)n0);
        // ④
        FRESH(); nxgal_set_program(prog); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC];
        nxgal_set_storage_buffers(&r3, 1); nxgal_set_program(progr); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_set_storage_buffers(&w3, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
        nxgal_set_storage_buffers(&r3, 1); nxgal_set_program(progr); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0;
        CHECK(readback(A), "读回失败");
        nr = count_in(16, 32, 0, 32, red); ng = count_in(0, 16, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "④ 期望右 512 红（派发前读旧值）、左 512 绿，实得 %d / %d", nr, ng);
        CHECK(enc == 2, "④ 要写的缓冲本遍已被读过：期望渲染编码器 2 个，实得 %llu", (unsigned long long)enc);
        // ⑤
        FRESH(); nxgal_set_program(prog); clear_full(0, 0, 0, 0, 0);
        nxgal_set_storage_buffers(&r4, 1); nxgal_set_program(progr); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        FRESH();
        e0 = g_gp_n[GP_RENC]; d1 = g_disp_n[1];
        nxgal_set_program(prog); use_vb(L, 12); set_color(0, 0, 1, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_storage_buffers(&w4, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
        nxgal_set_storage_buffers(&r4, 1); nxgal_set_program(progr); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0; n1 = g_disp_n[1] - d1;
        CHECK(readback(A), "读回失败");
        nr = count_in(16, 32, 0, 32, red); ng = count_in(0, 16, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "⑤ 期望右 512 红（P1 读旧值）、左 512 绿（P2 派发后读新值），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && n1 == (old ? 0u : 1u), "⑤ 期望 P2 渲染编码器 %d 个、派发进遍前段 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)n1);
        // ⑥
        FRESH(); nxgal_set_program(prog); clear_full(0, 0, 0, 0, 0);
        nxgal_set_storage_buffers(&ru, 1); nxgal_set_program(progr); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        FRESH();
        e0 = g_gp_n[GP_RENC]; d1 = g_disp_n[1];
        nxgal_set_program(prog); use_vb(L, 12); set_color(0, 0, 1, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_buf_set_data(U, 0, five, 16);
        nxgal_set_storage_buffers(&wu, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
        nxgal_set_storage_buffers(&ru, 1); nxgal_set_program(progr); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0; n1 = g_disp_n[1] - d1;
        CHECK(readback(A), "读回失败");
        nr = count_in(16, 32, 0, 32, red); ng = count_in(0, 16, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "⑥ 期望右 512 红（P1 读旧值 0）、左 512 绿（拷回 5 之后派发写 9），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && n1 == (old ? 0u : 1u), "⑥ 期望 P2 渲染编码器 %d 个、派发进遍前段 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)n1);
        uint32_t uv[4] = {0}; nxgal_buf_get_data(U, 0, 16, uv);
        CHECK(uv[0] == 9, "⑥ U[0] 期望 9（派发在拷回之后），实得 %u", uv[0]);
        // ⑦
        FRESH(); nxgal_set_program(prog); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC];
        nxgal_set_storage_buffers(&ru2, 1); nxgal_set_program(progr); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_buf_set_data(U2, 0, five, 16);
        nxgal_set_storage_buffers(&wu2, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
        nxgal_set_storage_buffers(&ru2, 1); nxgal_set_program(progr); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0;
        CHECK(readback(A), "读回失败");
        nr = count_in(16, 32, 0, 32, red); ng = count_in(0, 16, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "⑦ 期望右 512 红（拷回没提前到这次读之前）、左 512 绿，实得 %d / %d", nr, ng);
        CHECK(enc == 2, "⑦ 待拷回区间本遍已读过：期望渲染编码器 2 个，实得 %llu", (unsigned long long)enc);
        // ⑧
        {
            uint32_t U3 = nxgal_buf_create(32, 0); uint32_t z8[8] = {0}; nxgal_buf_set_data(U3, 0, z8, 32);
            nxgal_buf_assign rlo = {0, {U3, 0, 16, 0}}, whi = {0, {U3, 16, 16, 1}}, rhi = {0, {U3, 16, 16, 0}};
            FRESH(); nxgal_set_program(prog); clear_full(0, 0, 0, 0, 0);
            e0 = g_gp_n[GP_RENC];
            nxgal_set_storage_buffers(&rlo, 1); nxgal_set_program(progv); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
            nxgal_buf_set_data(U3, 0, five, 16);
            nxgal_set_storage_buffers(&whi, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
            nxgal_set_storage_buffers(&rhi, 1); nxgal_set_program(progr); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
            enc = g_gp_n[GP_RENC] - e0;
            CHECK(readback(A), "读回失败");
            const uint8_t black[4] = {0, 0, 0, 255};
            int nk = count_in(16, 32, 0, 32, black); ng = count_in(0, 16, 0, 32, green);
            CHECK(nk == 512 && ng == 512, "⑧ 期望右 512 黑（读到写前的 0，没被提前的拷回改成 5）、左 512 绿，实得 %d / %d", nk, ng);
            CHECK(enc == 2, "⑧ 待拷回区间本遍已读过：期望渲染编码器 2 个，实得 %llu", (unsigned long long)enc);
        }
        nxgal_set_program(prog);
#undef FRESH
        nxgal_tex_release(A); nxgal_tex_release(D);
    }

    // 用例 11：遍内采样有挂起清屏的贴图（落实清屏挪到遍前段）。X 挂起清屏成绿（以 X 为目标清、没画就换走）→ A 上开遍：左半画红 → 右半 fst 采样 X。
    // 期望：左红右绿（右半读到清成的绿）；新做法 A 1 个渲染编码器、清屏进遍前段 1 次；--old 收遍 → 清屏遍 → 重开 A：3 个、0 次
    printf("· 遍内采样有挂起清屏的贴图：左红右绿；新做法清屏挪到遍前段不切遍（1 个渲染编码器，--old 3 个）\n");
    {
        uint32_t A = nxgal_tex_create(&ci), X = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        nxgal_set_program(prog);
        // 本帧先要一次遍前段（派发挪不挪都会记「想要」）：保证下面 A 开遍时分段
        { uint32_t S = nxgal_buf_create(16, 0); uint32_t z[4] = {0}; nxgal_buf_set_data(S, 0, z, 16); nxgal_buf_assign w = {0, {S, 0, 16, 1}};
          nxgal_set_render_targets(&D, 1, 0); clear_full(0, 0, 0, 0, 0); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
          nxgal_set_storage_buffers(&w, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1); nxgal_set_program(prog); }
        nxgal_set_render_targets(&X, 1, 0); clear_full(0, 0, 1, 0, 1);
        nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], p0 = g_pclr_pre;
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, X, smp); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, np = g_pclr_pre - p0;
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "期望左 512 红、右 512 绿（采到清成的绿），实得 %d / %d", nr, ng);
        // 新做法：A 开遍 1 个 + 遍前段里的清屏遍 1 个（也计渲染编码器）= 2；--old：A 1 + 清屏遍 1 + 重开 A 1 = 3
        CHECK(enc == (old ? 3u : 2u) && np == (old ? 0u : 1u), "期望渲染编码器 %d 个（含清屏遍）、清屏进遍前段 %d 次，实得 %llu / %llu", old ? 3 : 2, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)np);
        nxgal_set_program(prog);
        nxgal_tex_release(A); nxgal_tex_release(X); nxgal_tex_release(D);
    }

    // 用例 12：懒同步（遍开着时建的同步号挂起，遍自然收尾时提交；有人等就当场提交）。
    // ① 左半画红 → create_sync(10) → 右半画绿：新做法 1 个渲染编码器、挂起 +1，提交前 current_sync < 10；wait_sync(10) 返回后左红右绿、current_sync ≥ 10。--old 2 个
    // ② create_sync(11) → 换目标组（遍收尾）→ 遍外 create_sync(12)（当场提交）→ wait_sync(12)：current_sync ≥ 12（11 随遍收尾已提交，回填了栅栏）
    // ③ create_sync(13)（挂起）→ 另一个线程 wait_sync(13)，本线程不进任何入口：5 秒内返回（等的人当场提交，不死锁）
    printf("· 懒同步：遍内建同步号不切遍（新做法 1 个渲染编码器，--old 2 个）；遍收尾提交回填；别的线程等挂起的同步号当场提交、不死锁\n");
    {
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        nxgal_set_program(prog);
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], l0 = g_sync_lazy;
        use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_create_sync(10, 0);
        uint64_t cur0 = nxgal_current_sync();
        use_vb(Rq, 12); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, nl = g_sync_lazy - l0;
        CHECK(enc == (old ? 2u : 1u) && nl == (old ? 0u : 1u), "① 期望渲染编码器 %d 个、挂起 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)nl);
        if (!old) CHECK(cur0 < 10, "① 提交前 current_sync 期望 < 10，实得 %llu", (unsigned long long)cur0);
        nxgal_wait_sync(10);
        CHECK(nxgal_current_sync() >= 10, "① wait_sync(10) 后 current_sync 期望 ≥ 10，实得 %llu", (unsigned long long)nxgal_current_sync());
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "① 期望左 512 红、右 512 绿，实得 %d / %d", nr, ng);
        // ②
        nxgal_set_render_targets(&A, 1, 0); use_vb(L, 12); set_color(0, 0, 1, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_create_sync(11, 0);
        nxgal_set_render_targets(&D, 1, 0);
        nxgal_create_sync(12, 1); nxgal_wait_sync(12);
        CHECK(nxgal_current_sync() >= 12, "② current_sync 期望 ≥ 12（11 随遍收尾提交），实得 %llu", (unsigned long long)nxgal_current_sync());
        // ③
        nxgal_set_render_targets(&A, 1, 0); use_vb(Rq, 12); set_color(1, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_create_sync(13, 0);
        g_waited = 0; pthread_t th; pthread_create(&th, NULL, wait_th, (void *)(uintptr_t)13);
        for (int i = 0; i < 500 && !g_waited; i++) usleep(10000);
        CHECK(g_waited, "③ 别的线程等挂起的同步号 13：5 秒内期望返回（当场提交），实得没返回");
        if (g_waited) pthread_join(th, NULL);
        CHECK(nxgal_current_sync() >= 13, "③ current_sync 期望 ≥ 13，实得 %llu", (unsigned long long)nxgal_current_sync());
        CHECK(readback(A), "读回失败");
        int ny = count_in(16, 32, 0, 32, yellow);
        CHECK(ny == 512, "③ 右半期望 512 黄，实得 %d", ny);
        // ④ S2A_SYNCPT_HOSTSYNC 开时严格的遍内建同步号当场提交（照上游 strict = FlushAllCommands）：不挂起，下一条绘制新开渲染编码器
        extern int g_sync_strict_commit; int sc0 = g_sync_strict_commit; g_sync_strict_commit = 1;
        nxgal_set_render_targets(&A, 1, 0); use_vb(L, 12); set_color(0, 0, 1, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t l1 = g_sync_lazy;
        nxgal_create_sync(14, 1);
        uint64_t e1 = g_gp_n[GP_RENC];
        use_vb(Rq, 12); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        CHECK(g_sync_lazy == l1 && g_gp_n[GP_RENC] - e1 == 1, "④ 严格同步号期望不挂起、之后新开 1 个渲染编码器，实得挂起 %llu 次、新开 %llu 个", (unsigned long long)(g_sync_lazy - l1), (unsigned long long)(g_gp_n[GP_RENC] - e1));
        nxgal_wait_sync(14);
        CHECK(nxgal_current_sync() >= 14, "④ current_sync 期望 ≥ 14，实得 %llu", (unsigned long long)nxgal_current_sync());
        g_sync_strict_commit = sc0;
        // ⑤ NXGAL_SYNC_LAZY_ALL=1 接同局交替：遍外（计算编码器在录）建非严格同步号——开段（相位 1）与不交替（-1）挂起、不提交；关段（0）照缺省当场提交
        { extern int g_sync_lazy_all; int la0 = g_sync_lazy_all; g_sync_lazy_all = 1;
          uint32_t S = nxgal_buf_create(16, 0); uint32_t z[4] = {0}; nxgal_buf_set_data(S, 0, z, 16); nxgal_buf_assign w = {0, {S, 0, 16, 1}};
          const int ph[3] = {1, -1, 0}; const uint64_t id[3] = {15, 16, 17};
          for (int i = 0; i < 3; i++) {
              g_test_alt = ph[i]; nxgal_set_storage_buffers(&w, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1);
              uint64_t f0 = gal_committed_fence(), l2 = g_sync_lazy;
              nxgal_create_sync(id[i], 0);
              int lazy = g_sync_lazy - l2 == 1 && gal_committed_fence() == f0, now = g_sync_lazy == l2 && gal_committed_fence() > f0;
              CHECK(ph[i] ? lazy : now, "⑤ 相位 %d：期望%s，实得挂起 %llu 次、提交栅栏 +%llu", ph[i], ph[i] ? "挂起不提交" : "当场提交",
                    (unsigned long long)(g_sync_lazy - l2), (unsigned long long)(gal_committed_fence() - f0));
              nxgal_wait_sync(id[i]);
              CHECK(nxgal_current_sync() >= id[i], "⑤ current_sync 期望 ≥ %llu，实得 %llu", (unsigned long long)id[i], (unsigned long long)nxgal_current_sync());
          }
          g_test_alt = -1; g_sync_lazy_all = la0; nxgal_buf_delete(S); }
        nxgal_set_program(prog);
        nxgal_tex_release(A); nxgal_tex_release(D);
    }

    // 用例 13：遍内贴图上传挪到遍前段。① A 上左半画红 → 上传 X 整张绿（X 本遍没用过）→ 右半 fst 采样 X：左红右绿；新做法 1 个渲染编码器、上传进遍前段 1 次（--old 2 个、0 次）
    // ② 右半 fst 先采样 Y（蓝）→ 上传 Y 整张绿 → 左半 fst 采样 Y：Y 本遍已用过，照切（2 个）；右蓝左绿
    printf("· 遍内贴图上传：目标本遍没用过挪到遍前段不切遍（1 个渲染编码器，--old 2 个）；本遍已采样过的照切、之前的绘制读旧内容\n");
    {
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci), X = nxgal_tex_create(&ci), Y = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        static uint8_t gpx[32 * 32 * 4], bpx[32 * 32 * 4];
        for (int i = 0; i < 32 * 32; i++) { memcpy(gpx + i * 4, green, 4); memcpy(bpx + i * 4, blue, 4); }
        nxgal_tex_set_data(X, 0, 0, NULL, bpx, sizeof bpx); nxgal_tex_set_data(Y, 0, 0, NULL, bpx, sizeof bpx);
        // 本帧先要一次遍前段（保证下面开遍分段）
        { uint32_t S = nxgal_buf_create(16, 0); uint32_t z[4] = {0}; nxgal_buf_set_data(S, 0, z, 16); nxgal_buf_assign w = {0, {S, 0, 16, 1}};
          nxgal_set_render_targets(&D, 1, 0); clear_full(0, 0, 0, 0, 0); nxgal_set_program(prog); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
          nxgal_set_storage_buffers(&w, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1); }
        // ①
        nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], u0 = g_texup_n[1];
        nxgal_set_program(prog); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_tex_set_data(X, 0, 0, NULL, gpx, sizeof gpx);
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, X, smp); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, nu = g_texup_n[1] - u0;
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "① 期望左 512 红、右 512 绿（采到上传后的内容），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && nu == (old ? 0u : 1u), "① 期望渲染编码器 %d 个、上传进遍前段 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)nu);
        // ②
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC];
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, Y, smp); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_tex_set_data(Y, 0, 0, NULL, gpx, sizeof gpx);
        use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0;
        CHECK(readback(A), "读回失败");
        int nb = count_in(16, 32, 0, 32, blue); ng = count_in(0, 16, 0, 32, green);
        CHECK(nb == 512 && ng == 512, "② 期望右 512 蓝（上传前采样读旧内容）、左 512 绿，实得 %d / %d", nb, ng);
        CHECK(enc == 2, "② Y 本遍已采样过：期望渲染编码器 2 个，实得 %llu", (unsigned long long)enc);
        nxgal_set_program(prog);
        nxgal_tex_release(A); nxgal_tex_release(D); nxgal_tex_release(X); nxgal_tex_release(Y);
    }

    // 用例 13b：遍内贴图拷贝挪到遍前段（NXGAL_TEXCOPY_PRE=1）。① A 上左半画红 → 拷 G（整张绿）→ X（X、G 本遍没用过）→ 右半 fst 采样 X：左红右绿；
    // 新做法 1 个渲染编码器、拷贝进遍前段 1 次（--old 2 个、0 次）。② 右半 fst 先采样 Y（蓝）→ 拷 G → Y → 左半 fst 采样 Y：Y 本遍已用过，照切（2 个）；右蓝左绿
    printf("· 遍内贴图拷贝：源和目标本遍都没用过挪到遍前段不切遍（1 个渲染编码器，--old 2 个）；目标本遍已采样过的照切、之前的绘制读旧内容\n");
    {
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci), G = nxgal_tex_create(&ci), X = nxgal_tex_create(&ci), Y = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        static uint8_t gpx[32 * 32 * 4], bpx[32 * 32 * 4];
        for (int i = 0; i < 32 * 32; i++) { memcpy(gpx + i * 4, green, 4); memcpy(bpx + i * 4, blue, 4); }
        nxgal_tex_set_data(G, 0, 0, NULL, gpx, sizeof gpx); nxgal_tex_set_data(X, 0, 0, NULL, bpx, sizeof bpx); nxgal_tex_set_data(Y, 0, 0, NULL, bpx, sizeof bpx);
        // 本帧先要一次遍前段（保证下面开遍分段），同用例 13
        { uint32_t S = nxgal_buf_create(16, 0); uint32_t z[4] = {0}; nxgal_buf_set_data(S, 0, z, 16); nxgal_buf_assign w = {0, {S, 0, 16, 1}};
          nxgal_set_render_targets(&D, 1, 0); clear_full(0, 0, 0, 0, 0); nxgal_set_program(prog); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
          nxgal_set_storage_buffers(&w, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1); }
        // ①
        nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], c0 = g_texcp_n[1];
        nxgal_set_program(prog); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_tex_copy(G, X, 0, 0);
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, X, smp); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, nc = g_texcp_n[1] - c0;
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "13b① 期望左 512 红、右 512 绿（采到拷贝后的内容），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && nc == (old ? 0u : 1u), "13b① 期望渲染编码器 %d 个、拷贝进遍前段 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)nc);
        // ②
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC];
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, Y, smp); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_tex_copy(G, Y, 0, 0);
        use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0;
        CHECK(readback(A), "读回失败");
        int nb = count_in(16, 32, 0, 32, blue); ng = count_in(0, 16, 0, 32, green);
        CHECK(nb == 512 && ng == 512, "13b② 期望右 512 蓝（拷贝前采样读旧内容）、左 512 绿，实得 %d / %d", nb, ng);
        CHECK(enc == 2, "13b② Y 本遍已采样过：期望渲染编码器 2 个，实得 %llu", (unsigned long long)enc);
        // ③ 源本遍只被采样：左半 fst 采样 G（绿）→ 拷 G → Z（Z 蓝、本遍没用过）→ 右半 fst 采样 Z：两半都绿；源没写过，照样挪（1 个，--old 2 个）
        uint32_t Z = nxgal_tex_create(&ci); nxgal_tex_set_data(Z, 0, 0, NULL, bpx, sizeof bpx);
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC]; c0 = g_texcp_n[1];
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, G, smp); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_tex_copy(G, Z, 0, 0);
        nxgal_set_texture_sampler(5, 0, Z, smp); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0; nc = g_texcp_n[1] - c0;
        CHECK(readback(A), "读回失败");
        ng = count_in(0, 32, 0, 32, green);
        CHECK(ng == 1024, "13b③ 期望整张 1024 绿，实得 %d", ng);
        CHECK(enc == (old ? 2u : 1u) && nc == (old ? 0u : 1u), "13b③ 源只被采样：期望渲染编码器 %d 个、进遍前段 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)nc);
        // ④ 源是当前附件（本遍写过）：拷 A → W 照切（2 个）、不进遍前段
        uint32_t W = nxgal_tex_create(&ci);
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC]; c0 = g_texcp_n[1];
        nxgal_set_program(prog); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_tex_copy(A, W, 0, 0);
        use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0; nc = g_texcp_n[1] - c0;
        CHECK(readback(W), "读回失败");
        nr = count_in(0, 16, 0, 32, red);
        CHECK(nr == 512 && enc == 2 && nc == 0, "13b④ 源是本遍附件：期望 W 左 512 红、渲染编码器 2 个、进遍前段 0 次，实得 %d / %llu / %llu", nr, (unsigned long long)enc, (unsigned long long)nc);
        nxgal_set_program(prog);
        nxgal_tex_release(A); nxgal_tex_release(D); nxgal_tex_release(G); nxgal_tex_release(X); nxgal_tex_release(Y); nxgal_tex_release(Z); nxgal_tex_release(W);
    }

    // 用例 14：遍内派发写图像。① A 上左半画红 → 派发写 X 整张绿（X 本遍没用过）→ 右半 fst 采样 X：左红右绿；新做法 1 个渲染编码器、派发进遍前段（--old 2 个）
    // ② 右半 fst 先采样 X2（蓝）→ 派发写 X2 绿 → 左半 fst 采样 X2：X2 本遍已用过，照切（2 个）；右蓝左绿
    printf("· 遍内派发写图像：图像本遍没用过挪到遍前段不切遍（1 个渲染编码器，--old 2 个）；本遍已采样过的照切\n");
    {
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci), X = nxgal_tex_create(&ci), X2 = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        static uint8_t bpx2[32 * 32 * 4]; for (int i = 0; i < 32 * 32; i++) memcpy(bpx2 + i * 4, blue, 4);
        nxgal_tex_set_data(X, 0, 0, NULL, bpx2, sizeof bpx2); nxgal_tex_set_data(X2, 0, 0, NULL, bpx2, sizeof bpx2);
        { uint32_t S = nxgal_buf_create(16, 0); uint32_t z[4] = {0}; nxgal_buf_set_data(S, 0, z, 16); nxgal_buf_assign w = {0, {S, 0, 16, 1}};
          nxgal_set_render_targets(&D, 1, 0); clear_full(0, 0, 0, 0, 0); nxgal_set_program(prog); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
          nxgal_set_storage_buffers(&w, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1); }
        // ①
        nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], d1 = g_disp_n[1];
        nxgal_set_program(prog); use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_image(0, 0, X); nxgal_set_program(progcw); nxgal_dispatch(4, 4, 1);
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, X, smp); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, n1 = g_disp_n[1] - d1;
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ng = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "① 期望左 512 红、右 512 绿（采到派发写的绿），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && n1 == (old ? 0u : 1u), "① 期望渲染编码器 %d 个、派发进遍前段 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)n1);
        // ②
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        e0 = g_gp_n[GP_RENC];
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, X2, smp); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_set_image(0, 0, X2); nxgal_set_program(progcw); nxgal_dispatch(4, 4, 1);
        nxgal_set_program(progt); nxgal_set_texture_sampler(5, 0, X2, smp); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0;
        CHECK(readback(A), "读回失败");
        int nb = count_in(16, 32, 0, 32, blue); ng = count_in(0, 16, 0, 32, green);
        CHECK(nb == 512 && ng == 512, "② 期望右 512 蓝（派发前采样读旧内容）、左 512 绿，实得 %d / %d", nb, ng);
        CHECK(enc == 2, "② X2 本遍已采样过：期望渲染编码器 2 个，实得 %llu", (unsigned long long)enc);
        nxgal_set_image(0, 0, 0); nxgal_set_program(prog);
        nxgal_tex_release(A); nxgal_tex_release(D); nxgal_tex_release(X); nxgal_tex_release(X2);
    }

    // 用例 15：遍内写缓冲 / 填缓冲（区间本遍没用过）挪到遍前段。
    // ① S 8 MB（大于影子上限，原先只能录进在录流）：P1 右半 fsr 读 S[0..16)（0 → 红）→ 换遍 P2：上传 S[0..16) = 9 → 左半 fsr 读（9 → 绿）。右红左绿；新做法 P2 1 个渲染编码器（--old 2 个）
    // ② 填充：P1 右半 fsr 读 F（0 → 红）→ 换遍 P2：填 F = 9 → 左半 fsr 读 F（9 → 绿）。右红左绿；新做法 P2 1 个（--old 2 个）
    printf("· 遍内写缓冲 / 填缓冲（区间本遍没用过）：挪到遍前段不切遍（1 个渲染编码器，--old 2 个），更早的遍读旧值\n");
    {
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), Rq = quad_buf(12, 0, 1, -1, 1);
        uint32_t S = nxgal_buf_create(8 << 20, 0), F = nxgal_buf_create(16, 0); uint32_t z[4] = {0}, nine[4] = {9, 0, 0, 0};
        nxgal_buf_set_data(S, 0, z, 16); nxgal_buf_set_data(F, 0, z, 16);
        nxgal_buf_assign rs = {0, {S, 0, 16, 0}}, rf = {0, {F, 0, 16, 0}};
        // ①
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        nxgal_set_storage_buffers(&rs, 1); nxgal_set_program(progr); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0);
        uint64_t e0 = g_gp_n[GP_RENC], w0 = g_bufw_pre;
        nxgal_set_program(prog); set_color(0, 0, 1, 1); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_buf_set_data(S, 0, nine, 16);
        nxgal_set_storage_buffers(&rs, 1); nxgal_set_program(progr); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, nw = g_bufw_pre - w0;
        CHECK(readback(A), "读回失败");
        int nr = count_in(16, 32, 0, 32, red), ng = count_in(0, 16, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "① 期望右 512 红（P1 读旧值 0）、左 512 绿（上传 9 之后），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && nw == (old ? 0u : 1u), "① 期望 P2 渲染编码器 %d 个、写缓冲进遍前段 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)nw);
        // ②
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0);
        nxgal_set_storage_buffers(&rf, 1); nxgal_set_program(progr); use_vb(Rq, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_set_render_targets(&D, 1, 0); nxgal_set_render_targets(&A, 1, 0);
        e0 = g_gp_n[GP_RENC]; w0 = g_bufw_pre;
        nxgal_set_program(prog); set_color(0, 0, 1, 1); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        nxgal_buf_clear(F, 0, 16, 9);
        nxgal_set_storage_buffers(&rf, 1); nxgal_set_program(progr); use_vb(L, 12); nxgal_draw(4, 1, 0, 0);
        enc = g_gp_n[GP_RENC] - e0; nw = g_bufw_pre - w0;
        CHECK(readback(A), "读回失败");
        nr = count_in(16, 32, 0, 32, red); ng = count_in(0, 16, 0, 32, green);
        CHECK(nr == 512 && ng == 512, "② 期望右 512 红、左 512 绿（填 9 之后），实得 %d / %d", nr, ng);
        CHECK(enc == (old ? 2u : 1u) && nw == (old ? 0u : 1u), "② 期望 P2 渲染编码器 %d 个、填缓冲进遍前段 %d 次，实得 %llu / %llu", old ? 2 : 1, old ? 0 : 1, (unsigned long long)enc, (unsigned long long)nw);
        nxgal_set_program(prog);
        nxgal_tex_release(A); nxgal_tex_release(D);
    }

    // 用例 16：只给「前 2 帧同序号的遍里想挪过」的遍分段（每个命令缓冲固定占分配器一块，暗黑3 每遍都分段时 8 个主分配器 344–417 MB）；
    // 分配器要超过历史高水位多托命令缓冲时先向低区账本申请，不给就不分段、照旧切遍。帧 = 出图提交（g_gp_commit_present）。
    // 每帧 3 遍：A 画 → D 画 + 填 F（F 本遍没用过，想挪到遍前）→ A 画。期望（手算）：学习帧不分段、挪不了（切遍）；
    // 下一帧只第 2 遍分段、填缓冲进遍前段；之后两帧没有挪动，第 2 遍仍按前 2 帧分段；再下一帧不分段。
    // ⑤ 每帧 5 遍、第 2 / 4 遍都想挪；清掉高水位后账本不给：两遍都不分段、照旧切遍（填缓冲不进遍前段）。
    if (!old) {
        printf("· 遍前分段按遍序号预测：只给前 2 帧同序号想挪过的遍分段；分配器超高水位要账本给，不给照旧切遍\n");
        gal_prepass_test_any = 0;
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci);
        uint32_t L = quad_buf(12, -1, 0, -1, 1), F = nxgal_buf_create(16, 0);
        nxgal_set_program(prog); set_color(0, 0, 1, 1);
#define PASS(t, hoist) do { nxgal_set_render_targets(&(t), 1, 0); use_vb(L, 12); nxgal_draw(4, 1, 0, 0); if (hoist) nxgal_buf_clear(F, 0, 16, 9); } while (0)
#define FRAME3(h) do { PASS(A, 0); PASS(D, h); PASS(A, 0); g_gp_commit_present = 1; nxgal_flush(); } while (0)
        FRAME3(0); FRAME3(0);   // 清掉前面用例在第 1 帧留下的「想挪」记录
        const char *nm[5] = {"学习帧（有挪动）", "第 2 帧（有挪动）", "第 3 帧（无挪动）", "第 4 帧（无挪动）", "第 5 帧（无挪动）"};
        int hz[5] = {1, 1, 0, 0, 0}; uint64_t es[5] = {0, 1, 1, 1, 0}, ew[5] = {0, 1, 0, 0, 0};
        for (int i = 0; i < 5; i++) {
            uint64_t s0 = g_seg_n[0], w0 = g_bufw_pre;
            FRAME3(hz[i]);
            uint64_t ds = g_seg_n[0] - s0, dw = g_bufw_pre - w0;
            CHECK(ds == es[i] && dw == ew[i], "%s：期望分段 %llu、填缓冲进遍前段 %llu，实得 %llu / %llu", nm[i], (unsigned long long)es[i], (unsigned long long)ew[i], (unsigned long long)ds, (unsigned long long)dw);
        }
        CHECK(fl_users >= 1 && fl_held > 0, "期望命令分配器登记进账本、账面 > 0，实得使用者 %d、账面 %lld", fl_users, (long long)fl_held);
        // ⑤
#define FRAME5(h) do { PASS(A, 0); PASS(D, h); PASS(A, 0); PASS(D, h); PASS(A, 0); g_gp_commit_present = 1; nxgal_flush(); } while (0)
        FRAME5(0); FRAME5(0); FRAME5(1);
        gal_ca_test_reset();   // 高水位清零：本帧第一次分段起就要向账本申请
        fl_deny = 1;
        uint64_t s0 = g_seg_n[0], n0 = g_seg_n[1], w0 = g_bufw_pre;
        FRAME5(1);
        fl_deny = 0;
        uint64_t ds = g_seg_n[0] - s0, dn = g_seg_n[1] - n0, dw = g_bufw_pre - w0;
        CHECK(ds == 0 && dn == 2 && dw == 0, "⑤ 账本不给：期望分段 0、被拒 2、进遍前段 0，实得分段 %llu、被拒 %llu、进遍前段 %llu", (unsigned long long)ds, (unsigned long long)dn, (unsigned long long)dw);
        // ⑥ 分段多出命令缓冲的总额度（NXGAL_CA_EXTRA_MAX）：额度 1、高水位清零 → 本帧两遍想挪，只第一遍分段（多托 1 个），第二遍超额度照旧切遍；
        //    不限额度（对照）→ 两遍都分段
        { extern int g_ca_extra_max; extern uint64_t g_ca_cap_refuse;
          for (int lim = 1; lim >= -1; lim -= 2) {
            FRAME5(1); gal_ca_test_reset(); g_ca_extra_max = lim;
            uint64_t a0 = g_seg_n[0], r0 = g_ca_cap_refuse; FRAME5(1);
            uint64_t da = g_seg_n[0] - a0, dr = g_ca_cap_refuse - r0;
            if (lim == 1) CHECK(da == 1 && dr == 1, "⑥ 额度 1：期望分段 1、因额度不分段 1，实得 %llu / %llu", (unsigned long long)da, (unsigned long long)dr);
            else CHECK(da == 2 && dr == 0, "⑥ 不限额度（对照）：期望分段 2、因额度不分段 0，实得 %llu / %llu", (unsigned long long)da, (unsigned long long)dr);
          }
          g_ca_extra_max = -1; }
        // ⑦ 闲置放掉（NXGAL_CA_TRIM）：先占住前 i 个分配器的栅栏逼每帧挑第 i 个，让 8 个都托过带分段的帧；再放开、闲置 2 帧就放
        //    → 稳态只轮转的那个留着，其余 7 个（都托过 > 一个命令缓冲的量）放掉，账面减掉放掉的量；放过之后照常出帧
        //    账面只比放掉这一动作本身记的增减（g_ca_trim_noted）：h0 与终值之间跨 4 个 FRAME5，别的命令缓冲 / 分配器照常记账，总额比较随 GPU 完成时机偶发红（11-05 mini 守望 9ba62eeb6：19347880 → 21239024）
        { extern uint64_t g_galloc_fence[8], g_ca_trim_n, g_ca_trim_bytes; extern int64_t g_ca_trim_noted; extern int g_ca_trim;
          for (int i = 0; i < 8; i++) { uint64_t keep[8]; memcpy(keep, g_galloc_fence, sizeof keep); for (int j = 0; j < i; j++) g_galloc_fence[j] = UINT64_MAX; FRAME5(1); for (int j = 0; j < i; j++) g_galloc_fence[j] = keep[j]; }
          { extern void gal_finish(void); gal_finish(); }
          uint64_t n0 = g_ca_trim_n, b0 = g_ca_trim_bytes; int64_t l0 = g_ca_trim_noted;
          g_ca_trim = 2; for (int k = 0; k < 4; k++) FRAME5(0);
          uint64_t dn = g_ca_trim_n - n0, db = g_ca_trim_bytes - b0; int64_t dl = g_ca_trim_noted - l0;
          CHECK(dn >= 6 && db > 0 && dl < 0, "⑦ 闲置放掉：期望放掉 ≥ 6 组、字节 > 0、放掉记进账面的增减 < 0，实得 %llu 组 %llu B、账面增减 %lld", (unsigned long long)dn, (unsigned long long)db, (long long)dl);
          uint64_t s0 = g_seg_n[0]; FRAME5(1); FRAME5(1);
          CHECK(g_seg_n[0] > s0, "⑦ 放掉之后照常分段出帧：期望分段 > 0，实得 %llu", (unsigned long long)(g_seg_n[0] - s0));
          g_ca_trim = 0;
          // ⑦b 低区吃紧时放得更勤：阈值 120（缺省）下闲置 4 帧的不放（对照）；低区账本刚拒过申请（g_lv_press_frame = 当前帧）→ 阈值降到 2，同样闲置 4 帧就放
          extern uint64_t g_lv_press_frame; uint64_t dn2[2];
          for (int press = 0; press < 2; press++) {
              for (int i = 0; i < 8; i++) { uint64_t keep[8]; memcpy(keep, g_galloc_fence, sizeof keep); for (int j = 0; j < i; j++) g_galloc_fence[j] = UINT64_MAX; FRAME5(1); for (int j = 0; j < i; j++) g_galloc_fence[j] = keep[j]; }
              { extern void gal_finish(void); gal_finish(); }
              g_ca_trim = 120; g_lv_press_frame = press ? g_gp_frame : UINT64_MAX; uint64_t n1 = g_ca_trim_n;
              for (int k = 0; k < 4; k++) FRAME5(0);
              dn2[press] = g_ca_trim_n - n1;
          }
          g_ca_trim = 0; g_lv_press_frame = UINT64_MAX;
          CHECK(dn2[0] == 0 && dn2[1] >= 6, "⑦b 期望低区不吃紧时闲置 4 帧放 0 组、吃紧时放 ≥ 6 组，实得 %llu / %llu", (unsigned long long)dn2[0], (unsigned long long)dn2[1]); }
#undef FRAME5
#undef FRAME3
#undef PASS
        nxgal_tex_release(A); nxgal_tex_release(D);
    }

    // 用例 18：开遍预整理间接计数。每帧：D 上画一下 → 遍外派发 cs9 把计数缓冲写成 9（本命令缓冲 GPU 写过，预载读不到）→ A 上开遍：左半画红 → 间接计数
    //（参数 2 条：第 0 条右半、第 1 条左半，计数 min(9, 2) = 2 → 两半都绿）。手算期望：学习帧照旧切遍（2 个编码器）；下一帧开遍时按上一帧同一目标组的参数位置预整理，
    // 遍里直接取用（稳态 A 不再被切开、也不分段，取用 1 次），整屏 1024 绿（不预整理时稳态靠遍前分段，每帧为这遍多一个命令缓冲）。② 安全：开遍预整理之后、遍里把计数写成 0（命中已用区间，走镜像 / 暂存补丁、不切遍）→ 间接计数必须按 0 画：
    // 左 512 红、右 0 绿（开遍后写参数缓冲在现有写路径上都会切开本遍，预整理随遍序号作废；写序号核对是第二道防线）
    if (!old) {
        printf("· 开遍预整理间接计数：参数是本帧 GPU 写的也不切遍；预整理后参数被改就不用旧结果\n");
        gal_prepass_test_any = 0;
        nxgal_set_topology(5 /* TriangleStrip */);
        // 顶点 0–3 = 右半，4–7 = 左半
        float vv8[24] = {0, -1, 0, 1, -1, 0, 0, 1, 0, 1, 1, 0, -1, -1, 0, 0, -1, 0, -1, 1, 0, 0, 1, 0};
        uint32_t V = nxgal_buf_create(sizeof vv8, 0); nxgal_buf_set_data(V, 0, vv8, sizeof vv8);
        uint32_t args[16] = {4, 1, 0, 0, 0, 0, 0, 0, 4, 1, 4, 0, 0, 0, 0, 0};
        uint32_t AR = nxgal_buf_create(64, 0); nxgal_buf_set_data(AR, 0, args, 64);
        uint32_t CN = nxgal_buf_create(16, 0); uint32_t z4[4] = {0}; nxgal_buf_set_data(CN, 0, z4, 16);
        nxgal_buf_range ar = {AR, 0, 64, 0}, cn = {CN, 0, 16, 0};
        nxgal_buf_assign wc = {0, {CN, 0, 16, 1}};
        uint32_t L = quad_buf(12, -1, 0, -1, 1);
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci);
        nxgal_vbuf vb8 = {{V, 0, (int32_t)sizeof vv8, 0}, 12, 0}; nxgal_vattr at = {0, 0, 0, F_RGB32F};
#define FRAME18(zero_mid) do { \
            nxgal_set_render_targets(&D, 1, 0); base_state(prog); nxgal_set_topology(5); use_vb(L, 12); nxgal_draw(4, 1, 0, 0); \
            nxgal_set_render_targets(&D, 1, 0); { uint32_t none = 0; nxgal_set_render_targets(&none, 0, 0); } \
            nxgal_set_storage_buffers(&wc, 1); nxgal_set_program(progc); nxgal_dispatch(1, 1, 1); nxgal_set_program(prog); \
            nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0); \
            use_vb(L, 12); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0); \
            if (zero_mid) nxgal_buf_set_data(CN, 0, z4, 16); \
            nxgal_set_topology(5); nxgal_set_vertex_buffers(&vb8, 1); nxgal_set_vertex_attribs(&at, 1); set_color(0, 1, 0, 1); nxgal_draw_indirect_count(&ar, &cn, 2, 32, 0); \
        } while (0)
#define ENDF18() do { g_gp_commit_present = 1; nxgal_flush(); } while (0)
        // 先空跑两帧：清掉前面用例在最近 2 帧留下的「想挪到遍前」标记（否则 A 被预测分段，学习帧的整理进遍前段、不切遍）
        for (int i = 0; i < 2; i++) { nxgal_set_render_targets(&D, 1, 0); base_state(prog); use_vb(L, 12); nxgal_draw(4, 1, 0, 0); ENDF18(); }
        uint64_t el0 = g_gp_n[GP_RENC];
        FRAME18(0);   // 学习帧：上一帧没有记录，A 里的间接计数照旧切遍
        uint64_t encl = g_gp_n[GP_RENC] - el0;
        ENDF18(); FRAME18(0); ENDF18(); FRAME18(0); ENDF18();
        // 稳态（学习帧后第 3 帧：学习帧回退路径留下的「想挪」标记只管之后 2 帧）
        uint64_t e0 = g_gp_n[GP_RENC], p0 = g_icnt_pb, sg0 = g_seg_n[0];
        FRAME18(0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, np = g_icnt_pb - p0, nsg = g_seg_n[0] - sg0;
        CHECK(readback(A), "读回失败");
        int ng = count_in(0, 32, 0, 32, green);
        CHECK(ng == 1024 && np == 1, "① 期望整屏 1024 绿、遍里取用预整理 1 次，实得 %d / %llu（本帧渲染编码器 %llu 个）", ng, (unsigned long long)np, (unsigned long long)enc);
        CHECK(encl == 3u && enc == 2u && nsg == 0, "① 期望渲染编码器 学习帧 3 个（A 被间接计数切成两段）→ 稳态 2 个、遍前分段 0（不切遍也不为它单开命令缓冲），实得 %llu → %llu、分段 %llu",
              (unsigned long long)encl, (unsigned long long)enc, (unsigned long long)nsg);
        ENDF18();
        // ②
        p0 = g_icnt_pb;
        FRAME18(1);
        np = g_icnt_pb - p0;
        CHECK(readback(A), "读回失败");
        int nr = count_in(0, 16, 0, 32, red), ngr = count_in(16, 32, 0, 32, green);
        CHECK(nr == 512 && ngr == 0 && np == 0, "② 期望左 512 红、右 0 绿、不取预整理，实得 %d / %d / %llu", nr, ngr, (unsigned long long)np);
        ENDF18();
#undef FRAME18
#undef ENDF18
        nxgal_set_topology(7);
        nxgal_tex_release(A); nxgal_tex_release(D);
    }

    nxgal_shutdown();
    // 用例 19：一帧上千遍、每遍一条绘制（怪猎一帧 700–1047 遍，按绘制数切不动；一个命令缓冲托上千编码器，命令分配器 540–738 MB 后驱动中止）。
    //   2560 遍在 A / D 间交替（换目标必开新渲染编码器），A 上第 i 遍画第 i % 32 列、颜色 r = (i / 64) / 255：最后一轮写到哪列由绘制顺序唯一决定。
    //   对照（旧做法）：编码器数 / 字节两项都关、绘制数切分也关 → 整帧一个命令缓冲；新做法：每 64 个编码器切一次。
    //   手算期望：两种做法 A 逐像素相同（第 c 列 = 最后一轮 r = 39 / 255）；新做法单个主分配器高水位明显小于对照、切分提交 ≥ 2560 / 64 − 1 次
    if (!old) {
        printf("· 一帧 2560 遍：按编码器数切分后主分配器有界、画面与整帧一个命令缓冲逐像素相同（对照：不切时一个分配器托全部编码器）\n");
        extern int gal_cb_split_encs_test, gal_cb_split_bytes_test, gal_cb_split_draws_test; extern uint64_t g_cb_cap_commits;
        void gal_ca_test_fresh(void); uint64_t gal_ca_max_bytes(void); void gal_finish(void);
        nxgal_set_topology(5 /* TriangleStrip */); nxgal_set_program(prog);
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&ci), Q[32];
        for (int c = 0; c < 32; c++) Q[c] = quad_buf(12, -1 + c / 16.0f, -1 + (c + 1) / 16.0f, -1, 1);
        static uint8_t img[2][32 * 32 * 4]; uint64_t peak[2], ncap[2];
        for (int m = 0; m < 2; m++) {
            gal_cb_split_draws_test = 0; gal_cb_split_bytes_test = 0; gal_cb_split_encs_test = m ? 64 : 0;
            nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0); g_gp_commit_present = 1; nxgal_flush(); gal_finish();
            gal_ca_test_fresh(); uint64_t c0 = g_cb_cap_commits;
            for (int i = 0; i < 2560; i++) {
                if (i & 1) { nxgal_set_render_targets(&D, 1, 0); set_color(0, 0, 1, 1); use_vb(Q[0], 12); nxgal_draw(4, 1, 0, 0); }
                else { nxgal_set_render_targets(&A, 1, 0); set_color((i / 64) / 255.0f, 0, 0, 1); use_vb(Q[(i / 2) % 32], 12); nxgal_draw(4, 1, 0, 0); }
            }
            g_gp_commit_present = 1; nxgal_flush(); gal_finish();
            peak[m] = gal_ca_max_bytes(); ncap[m] = g_cb_cap_commits - c0;
            CHECK(readback(A), "读回失败"); memcpy(img[m], g_px, sizeof g_px);
        }
        gal_cb_split_draws_test = gal_cb_split_bytes_test = gal_cb_split_encs_test = -1;
        uint8_t e[4] = {39, 0, 0, 255}; memcpy(g_px, img[1], sizeof g_px); int n39 = count_in(0, 32, 0, 32, e);
        printf("  对照主分配器高水位 %.1f MB、切分 0 次期望 / 实得 %llu；新做法 %.1f MB、切分 %llu 次\n", peak[0] / 1048576.0, (unsigned long long)ncap[0], peak[1] / 1048576.0, (unsigned long long)ncap[1]);
        CHECK(!memcmp(img[0], img[1], sizeof img[0]) && n39 == 1024, "⑲ 期望两种做法逐像素相同、整幅 1024 像素都是最后一轮 r=39，实得%s相同、r=39 像素 %d", memcmp(img[0], img[1], sizeof img[0]) ? "不" : "", n39);
        CHECK(ncap[0] == 0 && ncap[1] >= 2560 / 64 - 1, "⑲ 期望对照切分 0 次、新做法 ≥ 39 次，实得 %llu / %llu", (unsigned long long)ncap[0], (unsigned long long)ncap[1]);
        CHECK(peak[1] * 4 <= peak[0], "⑲ 期望新做法单个主分配器高水位 ≤ 对照的 1/4，实得 %.1f / %.1f MB", peak[1] / 1048576.0, peak[0] / 1048576.0);
        nxgal_tex_release(A); nxgal_tex_release(D);
    }

    // 用例 20：分配器跨提交共用（NXGAL_CA_SHARE）。64 次提交、每次在 A 上画一列（第 i 次画第 i % 32 列、颜色 r = i / 32 + 1）。
    //   手算期望：不共用每次提交换一次分配器（64 次）；共用时按「16 次提交或主分配器到 16 MB」一换——每个命令缓冲固定占分配器一块（Mac 约 2 MB），
    //   约 7 次提交就到 16 MB，故换 ≤ 16 次；两种 A 逐像素相同（每列 = 第二轮 r = 2）
    if (!old) {
        printf("· 分配器跨提交共用：64 次提交，共用时换分配器次数降到 ≤ 16、画面与每次换逐像素相同\n");
        extern int gal_ca_share_test; extern uint64_t g_ca_switch, g_ca_reuse; void gal_finish(void); void gal_ca_test_fresh(void);
        nxgal_set_topology(5); nxgal_set_program(prog);
        uint32_t A = nxgal_tex_create(&ci), Q[32];
        for (int c = 0; c < 32; c++) Q[c] = quad_buf(12, -1 + c / 16.0f, -1 + (c + 1) / 16.0f, -1, 1);
        static uint8_t im[2][32 * 32 * 4]; uint64_t sw[2], ru[2];
        for (int m = 0; m < 2; m++) {
            gal_ca_share_test = m ? 16 : 0;
            nxgal_set_render_targets(&A, 1, 0); clear_full(0, 0, 0, 0, 0); nxgal_flush(); gal_finish(); gal_ca_test_fresh();   // 前面用例把分配器撑到 76 MB，超过共用上限 16 MB
            uint64_t s0 = g_ca_switch, r0 = g_ca_reuse;
            for (int i = 0; i < 64; i++) { nxgal_set_render_targets(&A, 1, 0); set_color((i / 32 + 1) / 255.0f, 0, 0, 1); use_vb(Q[i % 32], 12); nxgal_draw(4, 1, 0, 0); nxgal_flush(); }
            gal_finish(); sw[m] = g_ca_switch - s0; ru[m] = g_ca_reuse - r0;
            CHECK(readback(A), "读回失败"); memcpy(im[m], g_px, sizeof g_px);
        }
        gal_ca_share_test = -1;
        uint8_t e2[4] = {2, 0, 0, 255}; memcpy(g_px, im[1], sizeof g_px); int n2 = count_in(0, 32, 0, 32, e2);
        CHECK(!memcmp(im[0], im[1], sizeof im[0]) && n2 == 1024, "⑳ 期望两种做法逐像素相同、1024 像素都是 r=2，实得%s相同、r=2 像素 %d", memcmp(im[0], im[1], sizeof im[0]) ? "不" : "", n2);
        CHECK(sw[0] == 64 && ru[0] == 0 && sw[1] <= 16 && ru[1] >= 48, "⑳ 期望不共用换 64 次、共用 0 次；共用 16 时换 ≤ 16 次、共用 ≥ 48 次，实得 %llu/%llu、%llu/%llu",
              (unsigned long long)sw[0], (unsigned long long)ru[0], (unsigned long long)sw[1], (unsigned long long)ru[1]);
        nxgal_tex_release(A);
    }

    printf("%s：%d / %d 项通过（%s）\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks, old ? "旧做法" : "新做法");
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END

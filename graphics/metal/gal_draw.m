// GAL Metal 后端：第 6 块「绘制与派发」——资源参数缓冲填写、顶点 / 索引缓冲、拓扑转换、绘制 / 间接绘制 / 计算派发。
// 参数缓冲：每个描述符集一块（gal_transient，按提交栅栏回收），按 gal_prog.args 的偏移写 64 位值（缓冲 GPU 地址 / 贴图 / 采样器 MTLResourceID），
//   挂到该集被引用阶段的参数表 [[buffer(set)]]。参数表在每次绘制时被编码器快照，所以同一张表可以连续改写。
// 拓扑转换（同 Ryujinx Vulkan 后端 IndexBufferPattern / ConvertIndexBuffer）：Quads / TriangleFan / Polygon → 三角形列表；8 位索引 → 32 位。
//   非索引绘制在 CPU 生成模式索引；索引绘制用计算着色器在 GPU 上转（读的是 GPU 时间线上的索引数据），这会切开渲染通道。
#import "gal_draw_internal.h"
#include "gal_pstat.h"
#include <string.h>
#include <math.h>
#include <stdlib.h>

GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
uint64_t gal_rebind_n;   // 绑定阶段中途切遍后换编码器重绑的次数（prepare_draw；单测 t_draw 读）
__attribute__((weak)) void gal_cnt_on_draw(id<MTL4RenderCommandEncoder> e) { (void)e; }

static id<MTL4ArgumentTable> g_vt, g_ft, g_ct;
static id<MTLBuffer> g_zero;                 // 零属性常量缓冲（64 字节全 0）
static id<MTLBuffer> g_color_round_table;    // 常驻不可变表：第 i 项为 i，供片元入口读取附件掩码
static uint32_t g_color_round_mask = ~0u;
static uint32_t g_applied_serial = ~0u;      // 上次在渲染编码器上应用全部状态时的编码器代数
static id<MTLRenderPipelineState> g_cur_pso; static id g_cur_pso_enc;
static uint64_t g_stat_draws, g_stat_skips;
uint64_t gal_draw_count(void) { return g_stat_draws; }
static int g_in_bind;
int gal_in_bind(void) { return g_in_bind; }
void gal_draw_rebind_buffers(void) { g_gs.dirty |= GS_VB | GS_ARGS; }
// 绑定号 b 上该种类参数绑的贴图（贴图缓冲 / 图像缓冲读另一张表，见 nxgal_set_texture_sampler）
static uint32_t bound_tex(int kind, uint32_t b) {
    switch (kind) {
        case GAL_ARG_TEX: return b < GS_MAX_TEX ? g_gs.tex[b] : 0;
        case GAL_ARG_BUFTEX: return b < GS_MAX_TEX ? g_gs.buftex[b] : 0;
        case GAL_ARG_IMG: return b < GS_MAX_IMG ? g_gs.img[b] : 0;
        case GAL_ARG_BUFIMG: return b < GS_MAX_IMG ? g_gs.bufimg[b] : 0;
    }
    return 0;
}
// 开编码器前：本程序非镜像用到的缓冲（存储缓冲、贴图缓冲 / 图像缓冲挂的缓冲）先拷回镜像数据（会切通道，必须在开渲染 / 计算编码器之前）
// 本次绘制 / 派发可能写的缓冲（可写存储缓冲、图像缓冲挂的缓冲）同时作废其上相交的重排缓存（同 Vulkan 后端 SignalWrite → ClearRange）：
// 参数集照用时不再经 gal_buf_gpu_range 取址，原先那里的作废走不到，同一次提交里后续绘制读到写前的重排结果（t_draw「重排缓存随存储缓冲写作废」）。
// 返回本程序有没有存储写（可写存储缓冲 / 图像 / 图像缓冲；挂起内存屏障的判断用）
static int preflush_nonmirror(const gal_prog *pg) {
    int swr = 0;
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i];
        if (a->kind == GAL_ARG_IMG || a->kind == GAL_ARG_BUFIMG) swr = 1;
        for (uint32_t j = 0; j < a->count; j++) {
            uint32_t b = a->binding + j;
            if (a->kind == GAL_ARG_SSBO) {
                const nxgal_buf_range *r = b < GS_MAX_BUF ? &g_gs.ssbo[b] : NULL;
                // 只读存储缓冲同常量缓冲（见 write_arg）
                if (r && r->buf && r->write) { gal_buf_gpu_write(r->buf, r->offset, r->size); gal_buf_restride_drop(r->buf, r->offset, r->size); swr = 1; }
            }
            else if (a->kind == GAL_ARG_BUFTEX || a->kind == GAL_ARG_BUFIMG) {
                uint32_t tid = bound_tex(a->kind, b);
                gal_tex *t = gal_tex_get(tid);
                if (t && t->storage.buf && a->kind == GAL_ARG_BUFIMG) { gal_buf_gpu_write(t->storage.buf, t->storage.offset, t->storage.size); gal_buf_restride_drop(t->storage.buf, t->storage.offset, t->storage.size); }
                else if (t && t->storage.buf) gal_buf_preflush(t->storage.buf);
                if (t && t->storage.buf) gal_buf_note_use(t->storage.buf, t->storage.offset, t->storage.size);
            }
        }
    }
    return swr;
}

static int draw_init(void) {
    // 以最后建的零缓冲为「已初始化」：任一步失败下次重来（原先判 g_vt，零缓冲建不出时下次直接当成功、绑地址 0）
    if (g_zero) return 1;
    NSError *e = nil;
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = GAL_TABLE_SLOTS; d.supportAttributeStrides = YES;
    g_vt = [g_gdev newArgumentTableWithDescriptor:d error:&e];
    d.supportAttributeStrides = NO;
    g_ft = [g_gdev newArgumentTableWithDescriptor:d error:&e];
    g_ct = [g_gdev newArgumentTableWithDescriptor:d error:&e];
    if (!g_vt || !g_ft || !g_ct) { GLOG("【红】建参数表失败：%s", e.localizedDescription.UTF8String); return 0; }
    g_color_round_mask = ~0u;
    if (!g_color_round_table) {
        uint32_t masks[256]; for (uint32_t i = 0; i < 256; i++) masks[i] = i;
        g_color_round_table = [g_gdev newBufferWithBytes:masks length:sizeof masks options:MTLResourceStorageModeShared];
        if (!g_color_round_table) { GLOG("【红】建 half 颜色掩码表失败：%s", gal_mem_note()); return 0; }
        gal_res_add(g_color_round_table);
    }
    g_zero = gal_newbuf_test_fail ? nil : [g_gdev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    if (!g_zero) { GLOG("【红】建 64 字节零缓冲失败（本次绘制 / 派发跳过，下次重试）：%s", gal_mem_note()); return 0; }
    memset(g_zero.contents, 0, 64); gal_res_add(g_zero);
    [g_vt setAddress:g_zero.gpuAddress attributeStride:16 atIndex:GAL_ZERO_VB];
    return 1;
}

// ---------- 参数缓冲 ----------
static id<MTLTexture> g_dummy_tex[16]; static id<MTLSamplerState> g_dummy_smp;
static uint64_t res_id(id<MTLTexture> t) { MTLResourceID r = t.gpuResourceID; uint64_t v; memcpy(&v, &r, 8); return v; }
static uint64_t smp_id(id<MTLSamplerState> s) { MTLResourceID r = s.gpuResourceID; uint64_t v; memcpy(&v, &r, 8); return v; }
static uint64_t default_smp(void) {
    if (!g_dummy_smp) { MTLSamplerDescriptor *d = [MTLSamplerDescriptor new]; d.supportArgumentBuffers = YES;   // 同 Vulkan 后端 _dummySampler：最近邻、重复寻址
        d.sAddressMode = d.tAddressMode = d.rAddressMode = MTLSamplerAddressModeRepeat; g_dummy_smp = [g_gdev newSamplerStateWithDescriptor:d]; }
    return smp_id(g_dummy_smp);
}
// 采样贴图用采样视图（第 3 块：带 GAL 交换通道 / 分量修正 / 深度模板平面选择）；图像用存储贴图本身
static char g_miss_what[160], g_miss_where[96];
// 空绑定（同 Ryujinx Vulkan 后端 DescriptorSetUpdater._dummyTexture）：1×1 RGBA8Unorm 二维贴图、内容全 0，不论着色器声明的贴图类型
static id<MTLTexture> g_dummy2d;
int gal_dummy_test_fail;   // 单测故障注入（tests/t_draw.m）：非 0 时占位贴图当作建不出
static int g_dummy_fail;   // 本次 dummy_tex 建不出占位贴图：write_arg 据此让本次绘制 / 派发跳过（不往参数表填空资源号）
static uint64_t dummy_tex(void) {
    if (!g_dummy2d) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; d.storageMode = MTLStorageModeShared;
        g_dummy2d = gal_dummy_test_fail ? nil : [g_gdev newTextureWithDescriptor:d]; uint32_t z = 0;
        // 建不出：本次绘制 / 派发跳过（g_dummy_fail），下次重试；不把 nil 加进驻留集
        if (!g_dummy2d) { GRED_ONCE("占位贴图建不出（1x1）：缺贴图的绘制跳过、下次重试：%s", gal_mem_note()); g_dummy_fail = 1; return 0; }
        [g_dummy2d replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&z bytesPerRow:4]; gal_res_add(g_dummy2d);
    }
    return res_id(g_dummy2d);
}
static uint64_t tex_value(uint32_t tid, int image, int *missing) {
    gal_tex *t = gal_tex_get(tid);
    // 存储图像要贴图带着色器写用途（10-24 图形接口盘点静默 22；同 Vulkan 存储图像描述符要求 STORAGE 用途）：多采样 / 深度模板 / 压缩贴图建时没有，
    //   原先照绑、Metal 行为未定义且不报。改成报红、绑占位图像
    if (image && t && t->root && !(t->root.usage & MTLTextureUsageShaderWrite)) {
        GRED_ONCE("贴图 %u（格式 %d、采样 %d）没有着色器写用途（多采样 / 深度模板 / 压缩），不能当存储图像绑，改绑占位", tid, t->info.format, t->info.samples);
        if (!(*missing)++) snprintf(g_miss_what, sizeof g_miss_what, "图像 编号 %u（没有着色器写用途）", tid);
        return dummy_tex();
    }
    if (t && !g_buf_prepass_bind) gal_pass_tex_note(t->root, image);   // 本遍用法戳（挪到遍前段的派发不算本遍）
    // 资源号缓存（gal_tex_rid）：命中直接返回；没刷到（0）而对象在时退回现取，不会绑错
    if (t && gal_draw_fixed()) { uint64_t r = image ? t->rid_tex : (t->rid_smp ? t->rid_smp : t->rid_tex); if (r) return r; }
    id<MTLTexture> m = t ? (image ? t->tex : (t->smp ? t->smp : t->tex)) : nil;
    if (m) return res_id(m);
    if (!(*missing)++) snprintf(g_miss_what, sizeof g_miss_what, "%s 编号 %u%s", image ? "图像" : "贴图", tid, tid ? (t ? "（对象在但无 Metal 贴图）" : "（编号无效 / 已释放）") : "（未绑定）");
    return dummy_tex();
}
static uint32_t arr_tex(int binding, int set, int j, int is_smp) {
    gal_tarr *a = NULL;
    if (set >= 4) a = gal_tarr_get(g_gs.arr_set[set]);
    if (!a && (unsigned)binding < GS_MAX_ARR) a = gal_tarr_get(g_gs.arr[binding]);
    if (!a || j >= a->size) return 0;
    return is_smp ? (a->smp ? a->smp[j] : 0) : a->tex[j];
}
// 写「某阶段某集」的参数缓冲（第 4 块约定：每阶段每集各一块，gal_arg.offset 是该阶段该集缓冲里的偏移）；返回 GPU 地址，*sizes_gpu = 该集缓冲长度表地址（无则 0）
static int write_arg(const gal_prog *pg, const gal_arg *a, int st, int set, uint64_t *slot, int *missing);
// 整块写进 p（调用方的 CPU 影子，可读可写的普通内存；size 字节已清零）。返回 0 = 临时内存取不到（gal_transient 已报红），本次绘制 / 派发要跳过
static int write_set(const gal_prog *pg, int st, int set, int *missing, uint64_t *sizes_gpu, uint8_t *p) {
    *sizes_gpu = 0;
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->set != set || !(a->stages >> st & 1)) continue;
        uint64_t *slot = (uint64_t *)(p + a->offset);
        if (a->kind == GAL_ARG_SIZES) {   // 缓冲长度表：数组[存储缓冲的 slot] = 绑定字节数
            uint32_t n = 0; for (int k = 0; k < pg->nargs; k++) { const gal_arg *b = &pg->args[k]; if (b->set == set && b->kind == GAL_ARG_SSBO && (b->stages >> st & 1) && b->slot + b->count > n) n = b->slot + b->count; }
            uint64_t tg; uint32_t *tab = gal_transient((n ? n : 1) * 4, 16, &tg); if (!tab) return 0;
            memset(tab, 0, (n ? n : 1) * 4);
            for (int k = 0; k < pg->nargs; k++) { const gal_arg *b = &pg->args[k]; if (b->set != set || b->kind != GAL_ARG_SSBO || !(b->stages >> st & 1)) continue;
                for (uint32_t j = 0; j < b->count; j++) tab[b->slot + j] = (uint32_t)g_gs.ssbo[(b->binding + j) % GS_MAX_BUF].size; }
            slot[0] = tg; *sizes_gpu = tg; continue;
        }
        if (!write_arg(pg, a, st, set, slot, missing)) return 0;
    }
    return 1;
}
// 常量缓冲长度表（GAL_ARG_UBOLEN，gal_spvx.m）：表[常量缓冲绑定号] = 绑定的 vec4 个数（封顶 4096；未绑定 0）。着色器按它判界内：越界读回 0、地址钳到末元素。
// 返回 0 = 临时内存取不到
static uint64_t ubolen_table(const gal_arg *a) {
    uint32_t n = a->slot ? a->slot : 1; uint64_t tg; uint32_t *tab = gal_transient(n * 4, 16, &tg); if (!tab) return 0;
    for (uint32_t b = 0; b < n; b++) {
        const nxgal_buf_range *r = &g_gs.ubo[b % GS_MAX_BUF]; uint64_t sz = r->buf && r->size > 0 ? (uint64_t)r->size : 0;   // 未绑定 = 零缓冲（64 字节）、个数 0：全部读回 0
        uint64_t v = (sz + 15) / 16; tab[b] = (uint32_t)(v > 4096 ? 4096 : v);
    }
    return tg;
}
// 越界 / 循环到上限计数格（gal_internal.h GAL_ARG_OOBCNT）：每支着色器（按键）一个 16 字节格，共享内存，CPU 直接读。计数关着时一律指向零缓冲（着色器里计数代码已被特化删掉，不写）。
// 报数（nxgal_bounds_report，每 600 次出图、卡死现场与关停时）：GPU 上是 32 位回绕计数，CPU 按两次报数之差累计成 64 位（两次之间不超过 2^32 次调用即准）
#define OOB_CELLS 65536
static id<MTLBuffer> g_oob_buf; static uint64_t g_oob_key[OOB_CELLS]; static uint32_t g_oob_n;
static uint32_t g_oob_prev[OOB_CELLS][2]; static uint64_t g_oob_tot[OOB_CELLS][2], g_oob_said[OOB_CELLS][2];
uint64_t gal_oob_cell(uint64_t h) {
    if (!gal_spvx_counting()) return g_zero.gpuAddress;
    if (!g_oob_buf) { g_oob_buf = gal_newbuf_test_fail ? nil : [g_gdev newBufferWithLength:OOB_CELLS * 16 options:MTLResourceStorageModeShared];
        // 建不出（main 93b98b9 判空口径）：返回 0，write_arg 据此让本次绘制 / 派发跳过（计数开着时着色器会往这个地址写），下次重试
        if (!g_oob_buf) { GRED_ONCE("越界计数格缓冲建不出（%d 字节）：带计数的绘制跳过：%s", OOB_CELLS * 16, gal_mem_note()); return 0; }
        memset(g_oob_buf.contents, 0, OOB_CELLS * 16); gal_res_add(g_oob_buf);
        GLOG("越界 / 循环到上限计数开着（NXGAL_BOUNDS_COUNT=1）：每支着色器一个计数格，>0 报【红】（每 600 次出图与关停时）；本局画面不代表 iPhone，不比像素"); }
    uint32_t i = (uint32_t)(h * 0x9e3779b97f4a7c15ull >> 48) & (OOB_CELLS - 1);
    for (uint32_t k = 0; k < OOB_CELLS; k++, i = (i + 1) & (OOB_CELLS - 1)) {
        if (g_oob_key[i] == h) return g_oob_buf.gpuAddress + i * 16;
        if (!g_oob_key[i]) { g_oob_key[i] = h; g_oob_n++; return g_oob_buf.gpuAddress + i * 16; }
    }
    GRED_ONCE("越界计数格满（%d 支着色器）", OOB_CELLS); return g_zero.gpuAddress;
}
// 单测读：格的原始 4 个字（[0] 越界调用数 [1] 类别位 [2] 到上限调用数）；没有这支返回 0
int gal_oob_read(uint64_t h, uint32_t out[4]) { memset(out, 0, 16); if (!g_oob_buf) return 0; for (uint32_t i = 0; i < OOB_CELLS; i++) if (g_oob_key[i] == h) { memcpy(out, (const uint32_t *)g_oob_buf.contents + 4 * i, 16); return 1; } return 0; }
static void oob_classes(uint32_t m, char *b, size_t n) {
    static const char *nm[GAL_OOB_NVAR] = {"常量缓冲", "存储缓冲", "共享内存", "局部内存", "向量 / 矩阵分量", "循环"};
    b[0] = 0; for (int k = 0; k < GAL_OOB_LOOP; k++) if (m >> k & 1) snprintf(b + strlen(b), n - strlen(b), "%s%s", b[0] ? "、" : "", nm[k]);
}
// 有计数（越界或到上限）> 0 的着色器报【红】：中途只报次数有增长的（最多 32 行），收尾 / 卡死报全部有计数的（最多 64 行，按次数降序）。返回有计数的着色器数
static int32_t bounds_report(int final) {
    if (!g_oob_buf) return 0;
    const uint32_t *c = g_oob_buf.contents; static uint32_t idx[OOB_CELLS]; int n = 0, hit_o = 0, hit_l = 0, hit = 0; uint64_t tot_o = 0, tot_l = 0;
    for (uint32_t i = 0; i < OOB_CELLS; i++) {
        if (!g_oob_key[i]) continue;
        for (int k = 0; k < 2; k++) { uint32_t v = c[4 * i + (k ? 2 : 0)]; g_oob_tot[i][k] += (uint32_t)(v - g_oob_prev[i][k]); g_oob_prev[i][k] = v; }
        if (g_oob_tot[i][0] && (c[4 * i + 1] & ~((1u << GAL_OOB_UBO) | (1u << GAL_OOB_SSBO) | (1u << GAL_OOB_LOOP)))) { hit_o++; tot_o += g_oob_tot[i][0]; }
        if (g_oob_tot[i][1]) { hit_l++; tot_l += g_oob_tot[i][1]; }
        if (g_oob_tot[i][0] || g_oob_tot[i][1]) hit++;
        if ((g_oob_tot[i][0] || g_oob_tot[i][1]) && (final || g_oob_tot[i][0] != g_oob_said[i][0] || g_oob_tot[i][1] != g_oob_said[i][1])) idx[n++] = i;
    }
    for (int a = 1; a < n; a++) { uint32_t t = idx[a]; uint64_t tv = g_oob_tot[t][0] + g_oob_tot[t][1]; int b = a; while (b > 0 && g_oob_tot[idx[b - 1]][0] + g_oob_tot[idx[b - 1]][1] < tv) { idx[b] = idx[b - 1]; b--; } idx[b] = t; }
    int lim = final ? 64 : 32;
    for (int a = 0; a < n && a < lim; a++) {
        uint32_t i = idx[a]; char cl[128]; oob_classes(c[4 * i + 1], cl, sizeof cl);
        // 只有常量 / 存储缓冲越界：读回 0 与真值（Maxwell 常量缓冲）/ 参照（Ryujinx Vulkan robustBufferAccess）同义，游戏自身行为（10-21 怪猎脸部计算着色器空闲线程照读不用），记一行不报红；
        // 共享 / 局部内存与向量分量越界在 Switch 上是硬件异常、正常游戏不发生，出现即我方问题，报红
        uint32_t cm = c[4 * i + 1]; int ours = (cm & ~((1u << GAL_OOB_UBO) | (1u << GAL_OOB_SSBO) | (1u << GAL_OOB_LOOP))) != 0;
        if (g_oob_tot[i][0]) GLOG("%s着色器越界：程序 %016llx 次数 %llu（%s；次数 = 有越界访问的调用数%s）", ours ? "【红】" : "", (unsigned long long)g_oob_key[i], (unsigned long long)g_oob_tot[i][0], cl,
                                  ours ? "" : "；只有缓冲越界读回 0，与真值同义，不报红");
        if (g_oob_tot[i][1]) GLOG("【红】循环到上限：程序 %016llx 次数 %llu（次数 = 到过上限的调用数；上限按工作量：片元 / 顶点 2^18、计算单线程 2^22 条指令并按整次派发缩小，gal_spvx.m）", (unsigned long long)g_oob_key[i], (unsigned long long)g_oob_tot[i][1]);
        g_oob_said[i][0] = g_oob_tot[i][0]; g_oob_said[i][1] = g_oob_tot[i][1];
    }
    if (n > lim) GLOG("  （另有 %d 支有计数的着色器没列出）", n - lim);
    if (final || n) GLOG("%s着色器越界计数%s：越界 %d 支 合计 %llu 次；循环到上限 %d 支 合计 %llu 次（%u 支着色器在计）", hit_o || hit_l ? "【红】" : "", final ? "（收尾）" : "",
                         hit_o, (unsigned long long)tot_o, hit_l, (unsigned long long)tot_l, g_oob_n);
    return hit;
}
NXGAL_API int32_t nxgal_bounds_report(void) { return bounds_report(1); }
int32_t gal_bounds_report_delta(void) { return bounds_report(0); }
static uint32_t ubolen_gen(const gal_arg *a) { uint32_t g = 0; for (uint32_t b = 0; b < a->slot && b < GS_MAX_BUF; b++) if (g_gs.ubo_gen[b] > g) g = g_gs.ubo_gen[b]; return g; }
// 写一个参数（数组逐元素）：write_set 整块写与增量写共用
// 返回 0 = 临时内存取不到（长度表）
static int write_arg(const gal_prog *pg, const gal_arg *a, int st, int set, uint64_t *slot, int *missing) {
    if (a->kind == GAL_ARG_UBOLEN) { slot[0] = ubolen_table(a); return slot[0] != 0; }
    if (a->kind == GAL_ARG_OOBCNT) { gal_prog *w = (gal_prog *)pg; if (!w->oob_cell[st]) w->oob_cell[st] = gal_oob_cell(pg->stage_hash[st]); slot[0] = w->oob_cell[st]; return slot[0] != 0; }   // 0 = 计数格缓冲建不出：本次绘制跳过
    {
        int array = a->count > 1 || set >= 4;
        for (uint32_t j = 0; j < a->count; j++) {
            uint32_t b = a->binding + (array ? 0 : j);
            switch (a->kind) {
                case GAL_ARG_UBO: case GAL_ARG_SSBO: {
                    const nxgal_buf_range *r = a->kind == GAL_ARG_UBO ? &g_gs.ubo[(a->binding + j) % GS_MAX_BUF] : &g_gs.ssbo[(a->binding + j) % GS_MAX_BUF];
                    // 存储缓冲按 Ryujinx 给的写标志（着色器反射 BufferUsageFlags.Write，同上游 Vulkan 后端只对只读绑定用镜像）：着色器不写的按只读绑定，
                    // 可用镜像、不丢影子。原先一律按读写——10-19 暗黑2（Mac 模拟真机 GPU 落后）「GPU 自写」标记 346 万次全出自这里，真机每帧切通道上传 617 次
                    slot[j] = !r->buf ? 0 : a->kind == GAL_ARG_UBO || !r->write ? gal_buf_read_gpu(r->buf, r->offset, r->size) : gal_buf_gpu_range(r->buf, r->offset, r->size);
                    if (!slot[j]) slot[j] = g_zero.gpuAddress;   // 未绑定：指向零缓冲，避免空指针读（常量读 0）
                    break;
                }
                case GAL_ARG_TEX: case GAL_ARG_BUFTEX: {   // 位置只在首次缺失时记（原先每个贴图都 snprintf 一次，10-19 采样占渲染线程 2%）
                    int m0 = *missing;
                    slot[j] = tex_value(array ? arr_tex(a->binding, set, j, 0) : bound_tex(a->kind, b), 0, missing);
                    if (g_dummy_fail) { g_dummy_fail = 0; return 0; }
                    if (!m0 && *missing) snprintf(g_miss_where, sizeof g_miss_where, "阶段 %d 集 %d 绑定 %u 元素 %u 类 %u", st, set, a->binding, j, a->kind);
                    break;
                }
                case GAL_ARG_SMP: {
                    uint32_t sm = array ? arr_tex(a->binding, set, j, 1) : (b < GS_MAX_TEX ? g_gs.smp[b] : 0);
                    id<MTLSamplerState> ss = sm ? gal_sampler_get(sm) : nil;
                    slot[j] = ss ? smp_id(ss) : default_smp(); break;
                }
                case GAL_ARG_IMG: case GAL_ARG_BUFIMG: {
                    int m0 = *missing;
                    slot[j] = tex_value(array ? arr_tex(a->binding, set, j, 0) : bound_tex(a->kind, b), 1, missing);
                    if (g_dummy_fail) { g_dummy_fail = 0; return 0; }
                    if (!m0 && *missing) snprintf(g_miss_where, sizeof g_miss_where, "阶段 %d 集 %d 绑定 %u 元素 %u 类 %u", st, set, a->binding, j, a->kind);
                    break;
                }
            }
        }
    }
    return 1;
}
// 按集复用：同一程序、同一次提交（参数缓冲在临时内存里，按提交回收）、期间没删建对象、集里引用的绑定都没改值 → 上次写的参数缓冲照用。
// 贴图数组集（数组元素 / 第 4 集起）不复用（数组内容改动另有序号，不进绑定代数）
// sh：上次写的内容的 CPU 影子（普通内存）。临时内存是写合并的，CPU 读极慢，增量只能从影子复制（10-19 先从临时内存读回，回放每帧 CPU 反而 6.5 → 10.5 ms）
typedef struct { const gal_prog *pg; uint64_t cb, pass; uint32_t gen, obj; uint64_t gpu, sizes; uint8_t *sh; uint32_t shcap, shlen; } set_cache;
static set_cache g_setc[6][GAL_MAX_SETS];
// 返回 2 = 整块照用；1 = 可增量（只有绑定值变了：复制上次那块、只重写变了的参数，见 bind_sets）；0 = 整块重写。
// 增量的前提与照用相同（同程序、同提交——上次那块临时内存还在、同遍、同对象代数——没有删建 / 改指镜像），另要求集里没有缓冲长度表
// 程序 pg 阶段 st 集 set 用到的参数：位图可用时只迭代这些下标，否则（参数多于 64）全扫、按集与阶段过滤
static uint32_t arg_gen(const gal_arg *a);
static void ssa_init(const gal_prog *pg) {
    gal_prog *w = (gal_prog *)pg; memset(w->ssa_mask, 0, sizeof w->ssa_mask);
    if (pg->nargs > 64) { w->ssa_ok = 2; return; }
    for (int i = 0; i < pg->nargs; i++) { const gal_arg *a = &pg->args[i]; if (a->set >= GAL_MAX_SETS) continue; for (int st = 0; st < 6; st++) if (a->stages >> st & 1) w->ssa_mask[st][a->set] |= 1ull << i; }
    w->ssa_ok = 1;
}
#define SSA_FOR(P_, ST_, SET_, I_) for (uint64_t m_ = (P_)->ssa_ok == 1 ? (P_)->ssa_mask[ST_][SET_] : ~0ull; m_; m_ &= m_ - 1) \
    for (int I_ = __builtin_ctzll(m_), d_ = 1; d_ && I_ < (P_)->nargs; d_ = 0) \
        if ((P_)->ssa_ok == 1 || ((P_)->args[I_].set == (SET_) && ((P_)->args[I_].stages >> (ST_) & 1)))
static int g_bind_skip = -1;   // NXGAL_BIND_SKIP=0：退回逐参数全扫 + 每次都设地址（A/B 用）
static int set_reusable(const gal_prog *pg, int st, int set, const set_cache *c) {
    // 同一遍：照用不再取址，本遍的缓冲已用区间（gal_buf.m puse，判能否挪到遍前段）靠每遍第一次写参数时登记
    if (c->pg != pg || c->cb != gal_cb_id() || c->pass != gal_pass_serial() || c->obj != g_obj_gen || set >= 4 || c->shlen != pg->stage_set_size[st][set]) return 0;
    int changed = 0;
    if (!g_bind_skip) goto full;
    SSA_FOR(pg, st, set, i) {
        const gal_arg *a = &pg->args[i];
        if (a->count > 1) return 0;
        uint32_t g = arg_gen(a); if (a->kind == GAL_ARG_SIZES) return 0;
        if (g > c->gen) changed = 1;
    }
    return changed ? 1 : 2;
full:
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->set != set || !(a->stages >> st & 1)) continue;
        if (a->count > 1) return 0;
        uint32_t b = a->binding, g = 0;
        switch (a->kind) {
            case GAL_ARG_UBO: g = b < GS_MAX_BUF ? g_gs.ubo_gen[b] : 0; break;
            case GAL_ARG_UBOLEN: g = ubolen_gen(a); break;
            case GAL_ARG_SSBO: case GAL_ARG_SIZES: g = b < GS_MAX_BUF ? g_gs.ssbo_gen[b] : 0; if (a->kind == GAL_ARG_SIZES) return 0; break;
            case GAL_ARG_TEX: case GAL_ARG_SMP: g = b < GS_MAX_TEX ? g_gs.tex_gen[b] : 0; break;
            case GAL_ARG_BUFTEX: g = b < GS_MAX_TEX ? g_gs.buftex_gen[b] : 0; break;
            case GAL_ARG_IMG: g = b < GS_MAX_IMG ? g_gs.img_gen[b] : 0; break;
            case GAL_ARG_BUFIMG: g = b < GS_MAX_IMG ? g_gs.bufimg_gen[b] : 0; break;
        }
        if (g > c->gen) changed = 1;
    }
    return changed ? 1 : 2;
}
static uint32_t arg_gen(const gal_arg *a) {
    uint32_t b = a->binding;
    switch (a->kind) {
        case GAL_ARG_UBO: return b < GS_MAX_BUF ? g_gs.ubo_gen[b] : 0;
        case GAL_ARG_UBOLEN: return ubolen_gen(a);
        case GAL_ARG_SSBO: return b < GS_MAX_BUF ? g_gs.ssbo_gen[b] : 0;
        case GAL_ARG_TEX: case GAL_ARG_SMP: return b < GS_MAX_TEX ? g_gs.tex_gen[b] : 0;
        case GAL_ARG_BUFTEX: return b < GS_MAX_TEX ? g_gs.buftex_gen[b] : 0;
        case GAL_ARG_IMG: return b < GS_MAX_IMG ? g_gs.img_gen[b] : 0;
        case GAL_ARG_BUFIMG: return b < GS_MAX_IMG ? g_gs.bufimg_gen[b] : 0;
    }
    return 0;
}
// 返回 0 = 临时内存取不到（gal_transient 已报红）：参数没写全，调用方跳过本次绘制 / 派发
// 一个阶段的各集参数缓冲写进参数表 tab（曲面细分的顶点 / TCS 计算核也走这里，gal_tess.m）
// 绘制参数表（g_vt / g_ft）各槽上次设的地址：没变就不再 setAddress（Metal 4 参数表在编码绘制时取当时的值，表对象常驻）。
//   只有 bind_stage 写这两张表的集槽（0–7）与长度表槽；别的槽（顶点缓冲 8–23、25–29 专用槽）不经这里，也不进缓存。
//   计算表 g_ct 不缓存：曲面细分（gal_tess.m）直接写它的 0–7 号槽
static uint64_t g_tab_addr[2][32];
static inline void tab_set(__typeof__(g_vt) tab, uint64_t a, int idx) {   // 类型同 g_vt（不新增 Metal 4 专有接口字样，gal_be.h 棘轮）
    int t = !g_bind_skip ? -1 : tab == g_vt ? 0 : tab == g_ft ? 1 : -1;
    if (t >= 0 && (unsigned)idx < 32) { if (g_tab_addr[t][idx] == a) return; g_tab_addr[t][idx] = a; }
    [tab setAddress:a atIndex:idx];
}
static int bind_stage(const gal_prog *pg, int st, id<MTL4ArgumentTable> tab, int *missing_out) {
    int missing = 0;
    static int noreuse = -1; if (noreuse < 0) { const char *v = getenv("NXGAL_NO_SET_REUSE"); noreuse = v && *v == '1'; }
    if (g_bind_skip < 0) { const char *v = getenv("NXGAL_BIND_SKIP"); g_bind_skip = !(v && *v == '0'); }
    if (!pg->ssa_ok) ssa_init(pg);
    {
        uint64_t sizes = 0;
        for (int s = 0; s < GAL_MAX_SETS; s++) {
            if (!pg->stage_set_size[st][s]) continue;   // 本阶段不用此集：不查复用、不写（原先 8 集 × 2 阶段每集都扫一遍全部参数）
            set_cache *c = &g_setc[st][s];
            uint64_t sg = 0, gpu;
            int r = noreuse ? 0 : set_reusable(pg, st, s, c);
            { extern uint64_t g_set_kind[3]; g_set_kind[r]++; }   // 参数集 0 整块重写 / 1 增量 / 2 照用（NXGAL_PERF_TIME 拆账行）
            if (r == 2) { gpu = c->gpu; sg = c->sizes; g_gp_n[GP_SETREUSE]++; }
            else {
                uint32_t gen = g_bind_gen, size = pg->stage_set_size[st][s];
                if (c->shcap < size) { c->sh = realloc(c->sh, size); c->shcap = size; }
                if (r == 1) {   // 增量：影子里只重写绑定值变了的参数（每帧集 0 常量缓冲约 5700 次重写，大多只有一两个常量缓冲换了偏移）
                    int ok = 1;
                    if (g_bind_skip) { SSA_FOR(pg, st, s, i) { const gal_arg *a = &pg->args[i]; if (ok && arg_gen(a) > c->gen) ok = write_arg(pg, a, st, s, (uint64_t *)(c->sh + a->offset), &missing); } }
                    else for (int i = 0; i < pg->nargs && ok; i++) { const gal_arg *a = &pg->args[i]; if (a->set == s && (a->stages >> st & 1) && arg_gen(a) > c->gen) ok = write_arg(pg, a, st, s, (uint64_t *)(c->sh + a->offset), &missing); }
                    // 影子已半改：作废本集缓存，下次整块重写
                    if (!ok) { c->pg = NULL; return 0; }
                    sg = c->sizes; g_gp_n[GP_SETREUSE]++;
                } else { memset(c->sh, 0, size); if (!write_set(pg, st, s, &missing, &sg, c->sh)) { c->pg = NULL; return 0; } }
                uint8_t *p = gal_transient(size, 16, &gpu); if (!p) { c->pg = NULL; return 0; }
                memcpy(p, c->sh, size);   // 只写不读：写合并内存上快
                c->pg = pg; c->cb = gal_cb_id(); c->pass = gal_pass_serial(); c->gen = gen; c->obj = g_obj_gen; c->gpu = gpu; c->sizes = sg; c->shlen = size;
            }
            if (gpu) tab_set(tab, gpu, s);
            if (sg) sizes = sg;
        }
        if (pg->size_buf_index[st] >= 0) tab_set(tab, sizes ? sizes : g_zero.gpuAddress, pg->size_buf_index[st]);
    }
    *missing_out += missing;
    return 1;
}
static int bind_sets(const gal_prog *pg, int compute) {
    GP_SCOPE(GP_BIND);
    int missing = 0;
    // 图形：顶点阶段（曲面程序是 TES 改写的顶点函数）+ 片元
    if (compute) { if (!bind_stage(pg, 0, g_ct, &missing)) return 0; }
    else if (!bind_stage(pg, pg->is_tess ? 3 : 1, g_vt, &missing) || !bind_stage(pg, 5, g_ft, &missing)) return 0;
    // 空绑定按参照语义换成空贴图（不是错误）；编号非 0 却无效才是我们这边的问题，报红
    if (missing) { g_stat_skips++; static int n, nb; int bad = strstr(g_miss_what, "未绑定") == NULL;
        if (bad ? nb++ < 8 : n++ < 1) GLOG("%s绘制引用了%s贴图（按 Vulkan 后端换成 1×1 空贴图）：程序 %016llx，%s：%s（本次共 %d 处）", bad ? "【红】" : "", bad ? "无效的" : "未绑定的", (unsigned long long)pg->hash, g_miss_where, g_miss_what, missing); }
    return 1;
}
// 顶点缓冲重排（同 Ryujinx Vulkan 后端 VertexBufferState / HelperShader.ChangeStride）：Metal 顶点读取要求跨度是 4 的倍数，
// 被着色器用到的缓冲跨度不齐时，绘制前用计算着色器按元素复制到临时缓冲（新跨度 = 向上取整到 4，元素数 = 大小 / 跨度），绑定改用它
static uint64_t g_vb_over[16]; static int32_t g_vb_over_stride[16];
NSString *const k_restride_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct P { ulong src; ulong dst; uint stride; uint nstride; uint elems; uint pad; };\n"
"kernel void restride(constant P &p [[buffer(0)]], uint e [[thread_position_in_grid]]) {\n"
"  if (e >= p.elems) return;\n"
"  device const uchar *s = (device const uchar *)p.src + e * p.stride; device uchar *d = (device uchar *)p.dst + e * p.nstride;\n"
"  for (uint b = 0; b < p.stride; b++) d[b] = s[b]; }\n";
static id<MTLComputePipelineState> g_restride_pso; static id<MTL4ArgumentTable> g_restride_tab;
// 顶点重排计算管线（运行时编辅助 MSL）：首次用到或 nxgal_warm_internal 预建
int gal_warm_restride(void) {
    if (g_restride_pso) return 1;
    NSError *e = nil; id<MTLLibrary> lib = gal_helper_lib(GH_RESTRIDE, &e);
    MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new]; MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new];
    f.library = lib; f.name = @"restride"; d.computeFunctionDescriptor = f;
    g_restride_pso = lib ? gal_new_compute_pso(d, &e) : nil;
    if (!g_restride_pso) { GLOG("【红】顶点重排着色器编译失败：%s", e.localizedDescription.UTF8String); return 0; }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 1;
    g_restride_tab = [g_gdev newArgumentTableWithDescriptor:ad error:&e];
    return 1;
}
// 不切遍（帧率能耗线 10-21，NXGAL_RESTRIDE_INPASS=1 退回旧做法）：
//   ① 顶点自取的程序（gal_vpull.m 按字节读、步长任意）不需要重排——跨度 4 倍数只是 Metal 顶点描述符的要求，直接绑原缓冲原跨度；
//   ② 其余程序的重排派发挪进预载命令缓冲（排在在录命令缓冲之前，同缓冲拷贝挪进预载）：条件 = 源这段此刻的内容与预载时读到的相同（gal_buf_preload_readable），
//      目标是刚建的重排缓存、本次提交里没人用过。条件不满足才照旧在录流里派发（切开渲染通道）。
//   动森岛 / 帐篷、马车8 每帧 0.7–3.3 次遍中重排，每次切开的遍续用附件存回 + 读入 16–95 MB / 帧
static int restride_inpass(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_RESTRIDE_INPASS"); v = e && *e == '1'; } return v; }
// 重排派发次数：[0] 在录流里（切遍）[1] 挪进预载（单测 / 诊断读）
uint64_t g_restride_n[2];
// 返回 0 = 临时内存取不到（gal_transient 已报红）：需要重排的缓冲没重排，调用方跳过本次绘制
static int restride_vertex_buffers(const gal_prog *pg) {
    uint32_t used = 0;
    // 顶点自取：不重排（used 留 0，下面把旧的重排覆盖全部撤掉）
    if (!pg->vs_pulled || restride_inpass())
        for (int i = 0; i < g_gs.nattr && i < 32; i++) if ((pg->vs_inputs >> i & 1) && !g_gs.attr[i].is_zero && (unsigned)g_gs.attr[i].buffer < 16) used |= 1u << g_gs.attr[i].buffer;
    for (int b = 0; b < 16; b++) {
        const nxgal_vbuf *v = &g_gs.vb[b];
        int need = (used >> b & 1) && v->stride > 0 && (v->stride & 3) && v->r.buf && v->r.size >= v->stride;
        if (!need) { if (g_vb_over[b]) { g_vb_over[b] = 0; g_gs.dirty |= GS_VB; } continue; }
        if (!g_restride_pso && !gal_warm_restride()) return 1;
        uint32_t elems = (uint32_t)(v->r.size / v->stride), ns = (uint32_t)((v->stride + 3) & ~3);
        // 取不到重排缓存（建缓冲失败，已报红）：跳过本次绘制，不按未重排的跨度读顶点
        int fresh; uint64_t dst = gal_buf_restride(v->r.buf, v->r.offset, v->r.size, v->stride, elems * ns, &fresh); if (!dst) return 0;
        if (!fresh) { if (g_vb_over[b] != dst || g_vb_over_stride[b] != (int32_t)ns) { g_vb_over[b] = dst; g_vb_over_stride[b] = (int32_t)ns; g_gs.dirty |= GS_VB; } continue; }
        uint64_t src = gal_buf_read_gpu(v->r.buf, v->r.offset, v->r.size);
        // 源取不到（镜像要临时内存）：刚建的重排缓存没写内容，作废后跳过本次绘制
        if (!src) { gal_buf_restride_drop(v->r.buf, v->r.offset, v->r.size); return 0; }
        struct { uint64_t src, dst; uint32_t stride, nstride, elems, pad; } prm = {src, dst, (uint32_t)v->stride, ns, elems, 0};
        uint64_t pg_; void *pp = gal_transient(sizeof prm, 16, &pg_); if (!pp) { gal_buf_restride_drop(v->r.buf, v->r.offset, v->r.size); return 0; }
        memcpy(pp, &prm, sizeof prm);
        // 源这段的读法（镜像 / 真缓冲）上面 gal_buf_read_gpu 已定，挪不挪按同一读法判
        int pre = !restride_inpass() && gal_buf_preload_readable(v->r.buf, v->r.offset, v->r.size);
        g_restride_n[pre]++;
        // 挪不了：在录流里派发，切开渲染通道（同 Vulkan 后端：重排在通道外做）
        id<MTL4ComputeCommandEncoder> e = pre ? gal_preload_cmp_enc() : gal_cmp_enc();
        if (!e) { gal_buf_restride_drop(v->r.buf, v->r.offset, v->r.size); return 0; }
        [e setComputePipelineState:g_restride_pso]; [g_restride_tab setAddress:pg_ atIndex:0]; [e setArgumentTable:g_restride_tab];
        [e dispatchThreads:MTLSizeMake(elems, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        g_vb_over[b] = dst; g_vb_over_stride[b] = (int32_t)ns; g_gs.dirty |= GS_VB;
    }
    return 1;
}
static void bind_vertex_buffers(void) {
    for (int i = 0; i < 16; i++) {
        const nxgal_vbuf *v = &g_gs.vb[i];
        uint64_t a = g_vb_over[i] ? g_vb_over[i] : v->r.buf ? gal_buf_read_gpu(v->r.buf, v->r.offset, v->r.size) : 0;
        int32_t stride = g_vb_over[i] ? g_vb_over_stride[i] : v->stride;
        if (!a) a = g_zero.gpuAddress;
        [g_vt setAddress:a attributeStride:(NSUInteger)(stride > 0 ? (stride + 3) & ~3 : 4) atIndex:GAL_VB_BASE + i];
    }
}

// 顶点自取（gal_vpull.m）：按程序读的属性位置填取数表（每位置 GAL_VPULL_ENTRY 字节，到最高用到的位置为止），绑参数表 GAL_VPULL_SLOT。地址 / 跨度同 bind_vertex_buffers（含重排覆盖）
// 返回 0 = 临时内存取不到（gal_transient 已报红）
int gal_vpull_fill(const gal_prog *pg, uint64_t *gpu_out) {
    if (!pg->vs_inputs) { *gpu_out = g_zero.gpuAddress; return 1; }
    int hi = 32 - __builtin_clz(pg->vs_inputs); uint64_t gpu; uint32_t *t = gal_transient((uint32_t)hi * GAL_VPULL_ENTRY, 16, &gpu); if (!t) return 0;
    for (int i = 0; i < hi; i++) {
        uint32_t *o = t + GAL_VPULL_ENTRY / 4 * i;
        const nxgal_vattr *a = i < g_gs.nattr ? &g_gs.attr[i] : NULL;
        uint32_t d = a ? gal_vpull_desc(a->format) : GAL_VPULL_BAD;
        if (!(pg->vs_inputs >> i & 1) || !a || a->is_zero || (unsigned)a->buffer >= 16 || d == GAL_VPULL_BAD) {   // 零属性（同 Vulkan 后端：读 0）
            if (a && !a->is_zero && d == GAL_VPULL_BAD && (pg->vs_inputs >> i & 1)) GRED_ONCE("顶点属性 %d 格式 %d 顶点自取不支持，按零值", i, a->format);
            gal_vpull_entry(o, 0, 0, 0, 0, 0, 0); continue;
        }
        int b = a->buffer; const nxgal_vbuf *v = &g_gs.vb[b];
        uint64_t base = g_vb_over[b] ? g_vb_over[b] : v->r.buf ? gal_buf_read_gpu(v->r.buf, v->r.offset, v->r.size) : 0;
        int32_t stride = g_vb_over[b] ? g_vb_over_stride[b] : v->stride;
        if (!base) { gal_vpull_entry(o, 0, 0, 0, 0, 0, 0); continue; }
        // 可读字节数：缓冲段长（重排覆盖是重排后的长度）减属性偏移；偏移超出段长 = 全部越界、读 0
        int64_t span = v->r.size < 0 ? INT64_MAX : g_vb_over[b] ? (int64_t)(v->r.size / v->stride) * g_vb_over_stride[b] : v->r.size, rest = span - (int64_t)(uint32_t)a->offset;
        uint32_t len = rest <= 0 ? 0 : rest > UINT32_MAX ? UINT32_MAX : (uint32_t)rest;
        gal_vpull_entry(o, base + (uint64_t)a->offset, (uint32_t)stride, d, v->divisor ? 1 : stride ? 0 : 2, (uint32_t)v->divisor, len);   // 步进：0 每顶点 1 每实例 2 常量
    }
    *gpu_out = gpu;
    return 1;
}
static int vpull_bind(const gal_prog *pg) {
    uint64_t gpu; if (!gal_vpull_fill(pg, &gpu)) return 0;
    [g_vt setAddress:gpu atIndex:GAL_VPULL_SLOT];
    return 1;
}

// 自定义边框色 / LOD 偏置模拟（gal_border.m）：改写过采样的阶段读边框表 s2a_bt[采样器绑定号]（32 字节：副份采样器 gpuResourceID、on、着色器加的 LOD 偏置 lb、混合系数 float4）。
//   本程序绑的采样器都不用模拟 → 绑全零表（on = 0、lb = 0，着色器原样采一次）；有 → 临时内存填一张。返回 0 = 临时内存取不到（已报红）
//   未改写的阶段（曲面各段 / 入口外采样 / 采样器数组）绑了要模拟的采样器：自定义色照主份近似、偏置丢掉，首例报红
static id<MTLBuffer> g_bzero;   // 全零边框表（GS_MAX_TEX 项）
uint64_t g_border_tables;       // 填过的边框表张数（单测 / 诊断读）
int gal_border_table(gal_prog *pg, uint64_t *gpu_out) {
    if (!pg->border_n) { int m = 0; for (int i = 0; i < pg->nargs; i++) { const gal_arg *a = &pg->args[i]; if (a->kind == GAL_ARG_SMP && a->count == 1 && a->set < 4 && a->binding + 1 > m) m = a->binding + 1; }
        pg->border_n = (uint16_t)(m + 1); }
    int n = pg->border_n - 1;
    if (!g_bzero) { g_bzero = [g_gdev newBufferWithLength:GS_MAX_TEX * 32 options:MTLResourceStorageModeShared]; if (!g_bzero) { GRED_ONCE("边框零表建不出：%s", gal_mem_note()); return 0; } memset(g_bzero.contents, 0, GS_MAX_TEX * 32); gal_res_add(g_bzero); }
    *gpu_out = g_bzero.gpuAddress;
    if (!g_smp_custom || n <= 0 || n > GS_MAX_TEX) return 1;
    uint8_t *t = NULL;
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->kind != GAL_ARG_SMP || a->count != 1 || a->set >= 4 || a->binding >= GS_MAX_TEX) continue;
        uint64_t alt; float f[4], lb; if (!gal_sampler_border(g_gs.smp[a->binding], &alt, f, &lb)) continue;
        if (!(a->stages & pg->border_stages)) continue;   // 只给改写过的阶段用（未改写的由 border_unrewritten 报）
        if (!t) { uint64_t g; t = gal_transient((uint32_t)n * 32, 16, &g); if (!t) return 0; memset(t, 0, (size_t)n * 32); *gpu_out = g; g_border_tables++; }
        uint8_t *e = t + 32 * a->binding; uint32_t on = alt != 0; memcpy(e, &alt, 8); memcpy(e + 8, &on, 4); memcpy(e + 12, &lb, 4); memcpy(e + 16, f, 16);
    }
    return 1;
}
// 程序里没改写的阶段绑了自定义色采样器（只报，不填表）
static void border_unrewritten(const gal_prog *pg) {
    if (!g_smp_custom) return;
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->kind != GAL_ARG_SMP || (a->stages & pg->border_stages) == a->stages) continue;
        uint64_t alt; float f[4], lb;
        if (a->count == 1 && a->set < 4 && a->binding < GS_MAX_TEX && gal_sampler_border(g_gs.smp[a->binding], &alt, f, &lb)) { GRED_ONCE("要着色器模拟的采样器（绑定 %u，自定义边框色 %s、LOD 偏置 %g）绑在未改写采样的阶段（%#x，曲面 / 入口外采样）：边框色按主份近似、偏置丢掉", a->binding, alt ? "有" : "无", lb, a->stages); return; }
    }
}

// ---------- 诊断：NXGAL_TRACE_DRAW=<第几次绘制（从 1 起）> 打印该次绘制的全部状态 ----------
static void trace_draw(const gal_prog *pg, int w, int h, int hd, int hs) {
    fprintf(stderr, "[gal] ===== 第 %llu 次绘制状态 =====\n", (unsigned long long)g_stat_draws + 1);
    fprintf(stderr, "  程序 %u 哈希 %016llx 阶段键 vs %016llx fs %016llx；vs 输入 %#x 写点大小 %d；fs 输出 %#x（类型 %u %u %u %u）\n", g_gs.prog, (unsigned long long)pg->hash,
            (unsigned long long)pg->stage_hash[1], (unsigned long long)pg->stage_hash[5], pg->vs_inputs, pg->vs_point_size, pg->fs_outputs, pg->fs_output_ctype[0], pg->fs_output_ctype[1], pg->fs_output_ctype[2], pg->fs_output_ctype[3]);
    uint32_t cf[8], sc; gal_pass_formats(cf, &sc);
    fprintf(stderr, "  目标 %d×%d 采样 %u 颜色格式 %u %u %u %u 深度 %d 模板 %d；写掩码 %x %x %x %x\n", w, h, sc, cf[0], cf[1], cf[2], cf[3], hd, hs, g_gs.mask[0], g_gs.mask[1], g_gs.mask[2], g_gs.mask[3]);
    for (int i = 0; i < g_gs.nvp && i < 2; i++) fprintf(stderr, "  视口 %d：(%g,%g) %g×%g 深度 %g..%g\n", i, g_gs.vp[i].x, g_gs.vp[i].y, g_gs.vp[i].w, g_gs.vp[i].h, g_gs.vp[i].znear, g_gs.vp[i].zfar);
    for (int i = 0; i < g_nscissors && i < 2; i++) fprintf(stderr, "  剪裁 %d：(%d,%d) %d×%d\n", i, g_scissors[i].x, g_scissors[i].y, g_scissors[i].w, g_scissors[i].h);
    fprintf(stderr, "  拓扑 %d 剔除 %d 面 %#x 正面 %#x 填充 %#x 丢弃 %d 深度测试 %d 写 %d 函数 %d 夹紧 %d 模板 %d a2c %d\n", g_gs.topology, g_gs.cull_en, g_gs.cull_face, g_gs.front_face, g_gs.poly, g_gs.discard,
            g_gs.depth.test, g_gs.depth.write, g_gs.depth.func, g_gs.depth_clamp, g_gs.stencil.enable, g_gs.a2c);
    for (int i = 0; i < 2; i++) { const nxgal_blend *b = &g_gs.blend[i]; fprintf(stderr, "  混合 %d：开 %d 色 %d(%#x,%#x) α %d(%#x,%#x)\n", i, b->enable, b->color_op, b->color_src, b->color_dst, b->alpha_op, b->alpha_src, b->alpha_dst); }
    fprintf(stderr, "  索引 缓冲 %u 偏移 %d 长 %d 类型 %d；顶点属性 %d 个：", g_gs.ib.buf, g_gs.ib.offset, g_gs.ib.size, g_gs.ib_type, g_gs.nattr);
    for (int i = 0; i < g_gs.nattr && i < 16; i++) fprintf(stderr, "[%d 缓冲 %d 偏移 %d 零 %d 格式 %d] ", i, g_gs.attr[i].buffer, g_gs.attr[i].offset, g_gs.attr[i].is_zero, g_gs.attr[i].format);
    fprintf(stderr, "\n  顶点缓冲：");
    for (int i = 0; i < 8; i++) fprintf(stderr, "[%d 缓冲 %u 偏移 %d 长 %d 跨度 %d 除数 %d] ", i, g_gs.vb[i].r.buf, g_gs.vb[i].r.offset, g_gs.vb[i].r.size, g_gs.vb[i].stride, g_gs.vb[i].divisor);
    // 输入数据（共享内存直读：调用方须先 gal_finish；这里只作诊断）
    gal_finish();
    { uint64_t o; id<MTLBuffer> ib = gal_buf_mtl(g_gs.ib.buf, g_gs.ib.offset, &o);
      if (ib) { const uint16_t *ix = (const uint16_t *)((const uint8_t *)ib.contents + o); fprintf(stderr, "\n  索引前 6：%u %u %u %u %u %u", ix[0], ix[1], ix[2], ix[3], ix[4], ix[5]); }
      id<MTLBuffer> vb = gal_buf_mtl(g_gs.vb[0].r.buf, g_gs.vb[0].r.offset, &o);
      if (vb) { const float *v = (const float *)((const uint8_t *)vb.contents + o); fprintf(stderr, "\n  顶点 0–3（float3，跨度 %d）：", g_gs.vb[0].stride);
        for (int k = 0; k < 4; k++) { const float *q = (const float *)((const uint8_t *)v + k * g_gs.vb[0].stride); fprintf(stderr, "(%g %g %g) ", q[0], q[1], q[2]); } }
      for (int u = 0; u < 8; u++) if (g_gs.ubo[u].buf) { id<MTLBuffer> ub = gal_buf_mtl(g_gs.ubo[u].buf, g_gs.ubo[u].offset, &o);
        if (ub) { const float *c = (const float *)((const uint8_t *)ub.contents + o); fprintf(stderr, "\n  常量绑定 %d（缓冲 %u 偏移 %d 长 %d）float4[1..4]：", u, g_gs.ubo[u].buf, g_gs.ubo[u].offset, g_gs.ubo[u].size);
          for (int r = 1; r <= 4; r++) fprintf(stderr, "[%g %g %g %g] ", c[r * 4], c[r * 4 + 1], c[r * 4 + 2], c[r * 4 + 3]); } } }
    fprintf(stderr, "\n  资源：");
    for (int i = 0; i < pg->nargs; i++) { const gal_arg *a = &pg->args[i]; fprintf(stderr, "[集 %u 绑 %u 类 %u 阶段 %#x 偏移 %u] ", a->set, a->binding, a->kind, a->stages, a->offset);
        if (a->kind == GAL_ARG_TEX && a->binding < GS_MAX_TEX) { gal_tex *t = gal_tex_get(g_gs.tex[a->binding]);
            if (t) fprintf(stderr, "{贴图 %u 格式 %d 目标 %d %d×%d 交换 %d%d%d%d 采样视图 %s mtl 格式 %lu 交换 %d%d%d%d} ", g_gs.tex[a->binding], t->info.format, t->info.target, t->info.width, t->info.height,
                t->info.swz[0], t->info.swz[1], t->info.swz[2], t->info.swz[3], t->smp ? "有" : "无", (unsigned long)(t->smp ? t->smp : t->tex).pixelFormat,
                (t->smp ? t->smp : t->tex).swizzle.red, (t->smp ? t->smp : t->tex).swizzle.green, (t->smp ? t->smp : t->tex).swizzle.blue, (t->smp ? t->smp : t->tex).swizzle.alpha); } }
    fprintf(stderr, "\n");
}

// ---------- 渲染编码器准备：开通道、管线、动态状态、参数 ----------
// TextureBarrier 挂起时（gal_core.m nxgal_barrier）：本次绘制采样 / 绑图像的贴图里有当前通道附件的底层存储 → 拆通道（附件存回后才能采样）；
// 没有就不拆，等通道结束自然清掉。贴图缓冲的底层是缓冲，不可能是附件，不查
// 本次绘制 / 派发要采样或当图像用的贴图里有挂起清屏的：开编码器之前落实（gal_pass.m g_pc）
static void clears_touch(const gal_prog *pg) {
    if (!gal_pass_clears_any()) return;
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->kind != GAL_ARG_TEX && a->kind != GAL_ARG_IMG) continue;
        int array = a->count > 1 || a->set >= 4;
        for (uint32_t j = 0; j < a->count; j++) {
            uint32_t b = a->binding + (array ? 0 : j);
            uint32_t tid = array ? arr_tex(a->binding, a->set, j, 0) : bound_tex(a->kind, b);
            gal_tex *t = tid ? gal_tex_get(tid) : NULL;
            if (t) gal_pass_clears_touch(t->root);
        }
    }
}
// 遍统计（NXGAL_PSTAT）：本次绘制 / 派发采样或当图像用的贴图（底层存储）记进遍序列。绘制在开好渲染编码器之后调（归当前遍），派发标 cs
static void pstat_samples(const gal_prog *pg, int cs) {
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->kind != GAL_ARG_TEX && a->kind != GAL_ARG_IMG) continue;
        int array = a->count > 1 || a->set >= 4;
        for (uint32_t j = 0; j < a->count; j++) {
            uint32_t b = a->binding + (array ? 0 : j);
            uint32_t tid = array ? arr_tex(a->binding, a->set, j, 0) : bound_tex(a->kind, b);
            gal_tex *t = tid ? gal_tex_get(tid) : NULL;
            if (t) gal_pstat_use((__bridge void *)t->root, PS_SAMPLE, !cs, cs);
        }
    }
}
// 本次绘制采样 / 绑图像的贴图里有没有 hit(root) 为真的（TextureBarrier 查当前附件、两遍合一查隐藏附件）
static int tex_hit(const gal_prog *pg, int (*hit)(id<MTLTexture>)) {
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->kind != GAL_ARG_TEX && a->kind != GAL_ARG_IMG) continue;
        int array = a->count > 1 || a->set >= 4;
        for (uint32_t j = 0; j < a->count; j++) {
            uint32_t b = a->binding + (array ? 0 : j);
            uint32_t tid = array ? arr_tex(a->binding, a->set, j, 0) : bound_tex(a->kind, b);
            gal_tex *t = tid ? gal_tex_get(tid) : NULL;
            if (t && hit(t->root)) return 1;
        }
    }
    return 0;
}
// 诊断 NXGAL_TEXBAR_WHY=1（缺省关）：TextureBarrier 后采样本遍附件而拆遍时，按（程序、绑定）记一行：片元阶段键、绑定号、
// 命中的是第几个颜色附件 / 深度、附件尺寸与格式（查哪些可改成片元帧缓冲读取），按（程序、绑定、槽）前 64 种组合各打一次
int gal_pass_attachment_slot(id<MTLTexture> root);
static void texbar_why(const gal_prog *pg) {
    static int on = -1; if (on < 0) { const char *v = getenv("NXGAL_TEXBAR_WHY"); on = v && *v == '1'; }
    if (!on) return;
    static uint64_t seen[64]; static int nseen;
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->kind != GAL_ARG_TEX && a->kind != GAL_ARG_IMG) continue;
        int array = a->count > 1 || a->set >= 4;
        for (uint32_t j = 0; j < a->count; j++) {
            uint32_t b = a->binding + (array ? 0 : j);
            uint32_t tid = array ? arr_tex(a->binding, a->set, j, 0) : bound_tex(a->kind, b);
            gal_tex *t = tid ? gal_tex_get(tid) : NULL; if (!t) continue;
            int slot = gal_pass_attachment_slot(t->root); if (slot < 0) continue;
            uint64_t k = pg->hash ^ ((uint64_t)b << 56) ^ ((uint64_t)a->kind << 48) ^ ((uint64_t)slot << 40);   // 同一绑定换了槽也单独记（核映射是否固定）
            int dup = 0; for (int q = 0; q < nseen; q++) dup |= seen[q] == k;
            if (dup || nseen >= 64) continue;
            seen[nseen++] = k;
            GLOG("[本遍采样拆遍] 程序 %016llx 顶点阶段键 %016llx 片元阶段键 %016llx：%s 绑定 %u（集 %u）命中%s%s，附件 %ux%u 格式 %u、采样视图 %ux%u 层 %u 级 %u；视口 x %g y %g 宽 %g 高 %g 重排 %d%d%d%d",
                 (unsigned long long)pg->hash, (unsigned long long)pg->stage_hash[1], (unsigned long long)pg->stage_hash[5], a->kind == GAL_ARG_TEX ? "采样" : "图像", b, a->set,
                 slot == 8 ? "深度模板附件" : "颜色附件 ", slot == 8 ? "" : (const char *[]){"0", "1", "2", "3", "4", "5", "6", "7"}[slot],
                 (unsigned)t->root.width, (unsigned)t->root.height, (unsigned)t->info.format, (unsigned)t->tex.width, (unsigned)t->tex.height, (unsigned)t->tex.parentRelativeSlice, (unsigned)t->tex.parentRelativeLevel,
                 g_gs.vp[0].x, g_gs.vp[0].y, g_gs.vp[0].w, g_gs.vp[0].h, g_gs.vp[0].swz[0], g_gs.vp[0].swz[1], g_gs.vp[0].swz[2], g_gs.vp[0].swz[3]);
        }
    }
}
// ---------- 片元帧缓冲读取（帧率能耗线 + 画面·着色器线，10-21）----------
// TextureBarrier 之后，本次绘制在本遍采样自己的颜色附件：TBDR 上附件还在片上，原做法收遍（整张存回再读入；塞尔达每帧 4.6 次约 81 MB）。
// 片元采样坐标若就是当前像素（翻译期对「顶点 + 片元」证明），把这些采样改读 [[color(n)]] 即等价，不必收遍。
// 分工：翻译器侧（gal_prog_fbfetch 强符号，画面·着色器线）证坐标、出变体；这里判运行时条件：
//   采样的是颜色槽 n 的整张单采样视图（层 0 级 0、尺寸与格式同附件）、视口铺满附件、视口重排（swizzle）为恒等；深度 / 图像 / 数组贴图命中一律不改。
//   实际采样的视图（t->smp，通道重排视图）重排须恒等；视图不止 1 级 mip 时采样器最小 LOD 须为 0、LOD 偏移须为 0（否则采到的不是 0 级）——画面·着色器线 10-21 指出
// ydown：视口朝向——1 = 正向（高为正，NDC y = −1 在顶行，GAL / Vulkan 缺省），0 = 翻转（原点在左下，高为负）。
//   顶点里屏幕坐标的 y 写成 (w+y)/2 还是 (w−y)/2，只有和朝向配对才是当前像素（塞尔达是 (w−y)/2 配翻转视口）；翻译器按证得的符号只在配对时给变体
// 缺省（弱符号）恒返回 NULL：照旧收遍
__attribute__((weak)) const gal_prog *gal_prog_fbfetch(const gal_prog *pg, const uint8_t *bind, const uint8_t *slot, int n, int ydown) { (void)pg; (void)bind; (void)slot; (void)n; (void)ydown; return NULL; }
id<MTLTexture> gal_pass_color_tex(int slot);
static int fb_full_view(id<MTLTexture> t, id<MTLTexture> root) {
    return t.textureType == MTLTextureType2D && t.sampleCount <= 1 && t.width == root.width && t.height == root.height
        && (!t.parentTexture || (t.parentRelativeLevel == 0 && t.parentRelativeSlice == 0));
}
// 运行时条件判定：通过返回映射组数 n（bind / slot 填好、*ydown = 视口朝向），不通过返回 0
static int fbfetch_map(const gal_prog *pg, uint8_t *bind, uint8_t *slot, int *ydown) {
    int n = 0;
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; if (a->kind != GAL_ARG_TEX && a->kind != GAL_ARG_IMG) continue;
        int array = a->count > 1 || a->set >= 4;
        for (uint32_t j = 0; j < a->count; j++) {
            uint32_t b = a->binding + (array ? 0 : j);
            uint32_t tid = array ? arr_tex(a->binding, a->set, j, 0) : bound_tex(a->kind, b);
            gal_tex *t = tid ? gal_tex_get(tid) : NULL; if (!t) continue;
            int s = gal_pass_attachment_slot(t->root); if (s < 0) continue;
            if (s == 8 || array || a->kind != GAL_ARG_TEX || b > 255) return 0;
            id<MTLTexture> at = gal_pass_color_tex(s);
            if (!at || !fb_full_view(t->tex, t->root) || !fb_full_view(at, t->root) || t->tex.pixelFormat != at.pixelFormat) return 0;
            if (t->smp) { MTLTextureSwizzleChannels w = t->smp.swizzle;
                if (w.red != MTLTextureSwizzleRed || w.green != MTLTextureSwizzleGreen || w.blue != MTLTextureSwizzleBlue || w.alpha != MTLTextureSwizzleAlpha) return 0; }
            if (t->tex.mipmapLevelCount > 1) { float ml = 0, lb = 0; uint32_t sm = b < GS_MAX_TEX ? g_gs.smp[b] : 0;
                if (!sm || !gal_sampler_lod(sm, &ml, &lb) || ml > 0 || lb != 0) return 0; }
            int dup = 0; for (int q = 0; q < n; q++) dup |= bind[q] == b;
            if (dup) continue;
            if (n == 8) return 0;
            bind[n] = (uint8_t)b; slot[n] = (uint8_t)s; n++;
        }
    }
    if (!n || g_gs.nvp < 1) return 0;
    id<MTLTexture> at = gal_pass_color_tex(slot[0]); float W = (float)at.width, H = (float)at.height; const nxgal_viewport *v = &g_gs.vp[0];
    if (!(v->x == 0 && v->w == W && ((v->y == 0 && v->h == H) || (v->y == H && v->h == -H)))) return 0;
    if (v->swz[0] != 0 || v->swz[1] != 2 || v->swz[2] != 4 || v->swz[3] != 6) return 0;   // 重排恒等（PositiveX / Y / Z / W）
    *ydown = v->h > 0;
    return n;
}
static const gal_prog *fbfetch_variant(const gal_prog *pg) {
    uint8_t bind[8], slot[8]; int ydown = 0, n = fbfetch_map(pg, bind, slot, &ydown);
    return n ? gal_prog_fbfetch(pg, bind, slot, n, ydown) : NULL;
}
// ---------- 帧级调度测算（gal_pstat.h SW_*，只在 NXGAL_PSTAT_DUMP 时）----------
// 贴图本遍被写过（当前附件算写）/ 被读或写过；缓冲本遍被 GPU 写过
static int sw_root_wr(id<MTLTexture> r) { return r && ((gal_sw_pass_open() && gal_pass_is_attachment(r)) || gal_sw_hit((__bridge const void *)r, 1)); }
static int sw_root_rw(id<MTLTexture> r) { return r && (sw_root_wr(r) || gal_sw_hit((__bridge const void *)r, 0)); }
// 遍历程序引用的贴图 / 图像 / 存储缓冲：fn(种类, 贴图底层存储, 缓冲编号, 缓冲可写)
static void sw_each(const gal_prog *pg, void (^fn)(int kind, id<MTLTexture> root, uint32_t buf, int bw)) {
    for (int i = 0; i < pg->nargs; i++) {
        const gal_arg *a = &pg->args[i]; int array = a->count > 1 || a->set >= 4;
        for (uint32_t j = 0; j < a->count; j++) {
            uint32_t b = a->binding + (array ? 0 : j);
            if (a->kind == GAL_ARG_TEX || a->kind == GAL_ARG_IMG || a->kind == GAL_ARG_BUFTEX || a->kind == GAL_ARG_BUFIMG) {
                uint32_t tid = array ? arr_tex(a->binding, a->set, j, 0) : bound_tex(a->kind, b);
                gal_tex *t = tid ? gal_tex_get(tid) : NULL; if (!t) continue;
                if (t->storage.buf) fn(a->kind, nil, t->storage.buf, a->kind == GAL_ARG_BUFIMG); else fn(a->kind, t->root, 0, 0);
            } else if (a->kind == GAL_ARG_SSBO) {
                const nxgal_buf_range *r = b < GS_MAX_BUF ? &g_gs.ssbo[b] : NULL;
                if (r && r->buf) fn(a->kind, nil, r->buf, r->write != 0);
            }
        }
    }
}
// 绘制开遍后登记本遍用法：采样贴图记读，图像记读写，可写存储缓冲 / 图像缓冲记写
static void sw_note_draw(const gal_prog *pg) {
    sw_each(pg, ^(int kind, id<MTLTexture> root, uint32_t buf, int bw) {
        if (root) { gal_sw_note((__bridge const void *)root, 0); if (kind == GAL_ARG_IMG) gal_sw_note((__bridge const void *)root, 1); }
        else if (bw) gal_sw_note(SW_BUFKEY(buf), 1);
    });
}
// 遍中派发是否真依赖：读到本遍写的（附件 / 图像 / 存储缓冲），或写到本遍用过的图像（贴图不换块）；写缓冲换新块不算
static int sw_dispatch_dep(const gal_prog *pg) {
    __block int dep = 0;
    sw_each(pg, ^(int kind, id<MTLTexture> root, uint32_t buf, int bw) {
        (void)bw;
        if (root) dep |= kind == GAL_ARG_IMG ? sw_root_rw(root) : sw_root_wr(root);
        else dep |= gal_sw_hit(SW_BUFKEY(buf), 1);
    });
    return dep;
}
// 遍中落实延后清屏（clears_touch）：被清的贴图本遍用过才是真依赖；保守取本次绘制采样的贴图里有无本遍用过的
static int sw_clear_dep(const gal_prog *pg) {
    __block int dep = 0;
    sw_each(pg, ^(int kind, id<MTLTexture> root, uint32_t buf, int bw) { (void)kind; (void)buf; (void)bw; if (root) dep |= sw_root_rw(root); });
    return dep;
}
// ---------- 屏障后采样深度附件、不收遍（原生层线 10-23）----------
// TextureBarrier 之后本次绘制只采样本遍的深度模板附件（不碰颜色附件），且深度模板自开遍载入后本遍没写过（gal_pass_ds_mem）、本次绘制也不写：
// 内存里那份就是最新值，就地采样即等价，不收遍。软粒子 / 贴花典型：先画不透明写深度（收一次遍、深度存回），之后几十次「屏障 + 采样深度、不写深度」。
// 怪猎村子录像：每帧 97.6 次屏障拆遍全是采样深度，其中 99% 属此类，约 870 MB / 帧存回 + 读入。NXGAL_TEXBAR_DS_INPLACE=0 退回一律收遍
uint64_t g_texbar_ds_inplace;   // 就地采样、没收遍的次数（单测 / 诊断读）
static int draw_writes_ds(void) { return (g_gs.depth.test && g_gs.depth.write) || g_gs.stencil.enable; }   // 模板开着按会写算（保守）
static int texbar_ds_inplace(const gal_prog *pg) {
    static int on = -1; if (on < 0) { const char *v = getenv("NXGAL_TEXBAR_DS_INPLACE"); on = !(v && *v == '0'); }
    return on && gal_pass_ds_mem() && !draw_writes_ds() && !tex_hit(pg, gal_pass_is_color_attachment);
}
static const gal_prog *g_draw_pg;
uint64_t g_fbfetch_draws;   // 改读帧缓冲、没收遍的绘制数（单测 / 诊断读）   // 上次绘制实际用的程序（帧缓冲读取变体与原程序来回换时要重取管线 / 重绑参数）
// 诊断（原生层线 10-23 塞尔达主几何遍按程序拆 GPU 时间，缺省关、关时只读一个整数）：
//   NXGAL_SKIP_PROG=<键>[,<键>…]（16 位十六进制，至多 8 个）：顶点或片元着色器键命中的绘制直接跳过（回放 / 真机诊断局各剔一个程序，量遍 GPU 时间降多少）
//   NXGAL_PROG_COUNT=<键>：首条绘制顶点着色器键为它的遍里，按「顶点键 / 片元键」计绘制数，退出时打前 20（排序用）
static int g_skp = -1, g_skn; static uint64_t g_skk[8], g_pck;
static struct { uint64_t a, b, n; } g_pc[256]; static int g_pcn;
static void pc_dump(void) {
    for (int i = 0; i < g_pcn; i++) for (int j = i + 1; j < g_pcn; j++) if (g_pc[j].n > g_pc[i].n) { __typeof__(g_pc[0]) t = g_pc[i]; g_pc[i] = g_pc[j]; g_pc[j] = t; }
    uint64_t tot = 0; for (int i = 0; i < g_pcn; i++) tot += g_pc[i].n;
    fprintf(stderr, "[gal] 按程序计数（NXGAL_PROG_COUNT=%016llx 的遍）：共 %llu 次绘制、%d 个程序（表满 256 时其余不计）\n", (unsigned long long)g_pck, (unsigned long long)tot, g_pcn);
    for (int i = 0; i < g_pcn && i < 20; i++) fprintf(stderr, "[gal] 按程序计数   %llu 次 %.1f%%：顶点 %016llx 片元 %016llx\n", (unsigned long long)g_pc[i].n, tot ? 100.0 * g_pc[i].n / tot : 0.0, (unsigned long long)g_pc[i].a, (unsigned long long)g_pc[i].b);
}
static void skp_init(void) {
    g_skp = 0; const char *v = getenv("NXGAL_SKIP_PROG");
    while (v && *v && g_skn < 8) { char *e; uint64_t k = strtoull(v, &e, 16); if (e == v) break; g_skk[g_skn++] = k; v = *e == ',' ? e + 1 : e; }
    const char *c = getenv("NXGAL_PROG_COUNT"); if (c && *c) { g_pck = strtoull(c, NULL, 16); atexit(pc_dump); }
    if (g_skn || g_pck) { g_skp = 1; fprintf(stderr, "[gal] 诊断：按程序跳过 %d 个键、按程序计数 %s\n", g_skn, g_pck ? "开" : "关"); }
}
static int skp_hit(const gal_prog *pg) {
    if (gal_diag_alt_off()) return 0;
    for (int i = 0; i < g_skn; i++) if (pg->stage_hash[1] == g_skk[i] || pg->stage_hash[5] == g_skk[i]) return 1;
    return 0;
}
static void pc_note(const gal_prog *pg) {
    extern uint64_t gal_pass_first_vs(void);
    if (!g_pck || gal_pass_first_vs() != g_pck) return;
    for (int i = 0; i < g_pcn; i++) if (g_pc[i].a == pg->stage_hash[1] && g_pc[i].b == pg->stage_hash[5]) { g_pc[i].n++; return; }
    if (g_pcn < 256) g_pc[g_pcn++] = (__typeof__(g_pc[0])){pg->stage_hash[1], pg->stage_hash[5], 1};
}
static id<MTL4RenderCommandEncoder> prepare_draw(const gal_prog **out_pg) {
    if (gal_m3_unbound(0) || !draw_init()) return nil;
    int pend = 0; const gal_prog *pg = gal_prog_get_draw(g_gs.prog, &pend);
    if (pend) { gal_first_skip_note(g_gs.prog, "绘制"); return nil; }
    if (!pg || pg->is_compute || !pg->fn[1]) { GRED_ONCE("绘制时没有有效的图形程序（程序 %u）", g_gs.prog); return nil; }
    if (pg->status != 0) return nil;
    if (g_skp && (g_skp < 0 ? (skp_init(), g_skp) : 1) && skp_hit(pg)) return nil;
    if (gal_state_cull_all()) return nil;   // 正反面都剔除：什么都不画
    if (!pg->is_tess && !restride_vertex_buffers(pg)) return nil;   // 可能切开渲染通道，必须在 gal_render_enc 之前（曲面程序的顶点在计算核里，gal_tess.m 先做过）
    int swr = preflush_nonmirror(pg);       // 同上
    if (gal_pass_texbar_armed() && tex_hit(pg, gal_pass_is_attachment)) {   // 同上；能改读帧缓冲就换变体、不收遍
        const gal_prog *v = fbfetch_variant(pg);
        uint8_t mb[8], ms[8]; int my;
        SW_SCOPE(SW_TEXBAR, !fbfetch_map(pg, mb, ms, &my));   // 调度测算：满足帧缓冲读取的运行时条件就不算真依赖
        if (v) { pg = v; g_fbfetch_draws++; }
        else if (texbar_ds_inplace(pg)) g_texbar_ds_inplace++;
        else { texbar_why(pg); gal_enc_end(); }
    }
    if (pg != g_draw_pg) { g_draw_pg = pg; g_gs.dirty |= GS_PSO | GS_ARGS; }
    // 挂起的内存屏障：屏障前本遍有存储写或这次绘制有存储写才拆遍（gal_pass.m gal_pass_membar_split）
    if (gal_pass_membar_split(swr)) { SW_SCOPE(SW_MEMBAR, 1); gal_enc_end(); }
    // 两遍合一：要采样被换组藏起来的颜色附件（还在片上）→ 收遍，下面按逻辑组重开
    if (gal_pass_hidden_any() && tex_hit(pg, gal_pass_hidden_hit)) { SW_SCOPE(SW_HIDDEN, 1); gal_enc_end(); }
    { SW_SCOPE(SW_CLEAR, sw_clear_dep(pg)); clears_touch(pg); }   // 同上（落实会结束当前通道，下面 gal_render_enc 重开）
    gal_pass_targetless_fit();   // 无附件绘制：视口变大就按新视口重开通道（gal_pass.m tl_extent）
    int rebind = 0;
again:;
    id<MTL4RenderCommandEncoder> e; { SW_SCOPE(SW_CLEAR, 1); e = gal_render_enc(); }   // 开遍时落实吃不掉的挂起清屏（单独一遍）：保守按真依赖
    if (SW_ON()) sw_note_draw(pg);
    if (swr) gal_pass_note_swr();
    if (PSTAT_ON()) pstat_samples(pg, 0);
    g_in_bind = 1;
    int w, h, hd, hs; gal_pass_info(&w, &h, &hd, &hs);
    if ((hd && g_gs.depth.test && g_gs.depth.write) || (hs && g_gs.stencil.enable)) gal_pass_ds_written();   // 屏障后就地采样深度的前提（texbar_ds_inplace）
    int fresh = g_applied_serial != g_genc_serial;
    if (fresh) {
        [e setArgumentTable:g_vt atStages:MTLRenderStageVertex];
        [e setArgumentTable:g_ft atStages:MTLRenderStageFragment];
        g_cur_pso = nil; g_gs.dirty |= GS_PSO | GS_DSS | GS_DYN | GS_VB | GS_ARGS;
    }
    if (g_gs.dirty & GS_PSO || g_cur_pso_enc != e) {
        uint8_t color_round_mask; uint64_t lop_addr = 0;
        id<MTLRenderPipelineState> p = gal_pso_get(pg, &color_round_mask, &lop_addr);
        if (!p) { if (gal_pso_pending()) gal_first_skip_note(g_gs.prog, "绘制（管线异步现建中）"); g_in_bind = 0; return nil; }
        // 逻辑运算入口管线（gal_logicop.m）：片元 GAL_LOP_SLOT 绑本次（运算号, 颜色格式）的 S2ALop 常驻表项（gal_state.m）；不用 _lo 的管线不读这个槽
        if (lop_addr) [g_ft setAddress:lop_addr atIndex:GAL_LOP_SLOT];
        if (g_color_round_mask != color_round_mask) {
            [g_ft setAddress:g_color_round_table.gpuAddress + color_round_mask * sizeof(uint32_t) atIndex:GAL_COLOR_ROUND_SLOT];
            g_color_round_mask = color_round_mask;
        }
        if (p != g_cur_pso || g_cur_pso_enc != e) { [e setRenderPipelineState:p]; g_cur_pso = p; g_cur_pso_enc = e; }
    }
    if (g_gs.dirty & (GS_DYN | GS_DSS)) gal_state_apply_dynamic(e, w, h, hd, hs);
    if ((g_gs.dirty & GS_VB) && !pg->is_tess) bind_vertex_buffers();
    // 临时内存取不到（已报红）：本次绘制跳过；dirty 不清，下次绘制全部重填
    if (pg->vs_pulled && !pg->is_tess && (g_gs.dirty & (GS_VB | GS_PSO)) && !vpull_bind(pg)) { g_in_bind = 0; return nil; }
    if (pg->border_stages & ((1u << 1) | (1u << 5))) {
        uint64_t bt; if (!gal_border_table((gal_prog *)pg, &bt)) { g_in_bind = 0; return nil; }
        if (pg->border_stages & (1u << 1)) [g_vt setAddress:bt atIndex:GAL_BORDER_SLOT];
        if (pg->border_stages & (1u << 5)) [g_ft setAddress:bt atIndex:GAL_BORDER_SLOT];
    }
    border_unrewritten(pg);
    if (pg->drawid) [g_vt setAddress:g_zero.gpuAddress atIndex:GAL_DRAWID_SLOT];   // 普通绘制绘制号 0（同 Vulkan 非多绘制）；间接计数绘制逐条改指向（nxgal_draw_indirect_count）
    if (!bind_sets(pg, 0)) { g_in_bind = 0; return nil; }
    // 绑定阶段中途切了遍（gal_buf.m gal_buf_read_gpu：只读绑定同时读到待拷回段与 GPU 写在途段，退影子时拷回录在在录流里、结束了当前渲染编码器）：
    //   e 已结束，在它上面续录会崩（10-25 动森 3.0.3 宽屏闭环 4 局都崩在 gal_cnt_on_draw 的 setVisibilityResultMode，信号 11）。换当前编码器从头再绑一次；
    //   退过影子的缓冲第二次不会再退，再变就是别的原因，报红跳过这次绘制（不在已结束的编码器上录）
    if (gal_cur_enc(NULL) != e) { g_in_bind = 0; gal_rebind_n++; if (rebind++) { GRED_ONCE("绑定阶段两次都切了遍，本次绘制跳过"); return nil; } goto again; }
    // 参数缓冲每次绘制都重写：绑定的缓冲内容 / 贴图对象可能被同号替换，快照语义下重写最简单也最正确（性能阶段再按代数省）
    gal_cnt_on_draw(e);
    { static long trace_at = -2; if (trace_at == -2) { const char *v = getenv("NXGAL_TRACE_DRAW"); trace_at = v ? atol(v) : -1; }
      if (trace_at >= 0 && (long)g_stat_draws + 1 == trace_at) trace_draw(pg, w, h, hd, hs); }
    g_gs.dirty = pg->is_tess ? GS_VB : 0; g_applied_serial = g_genc_serial; g_in_bind = 0;   // 曲面：顶点缓冲槽借给曲面，下次普通绘制重绑
    *out_pg = pg; g_stat_draws++; { extern uint32_t g_pass_draws; g_pass_draws++; }
    gal_hang_note(1, pg, 0);
    if (g_skp > 0) pc_note(pg);
    return e;
}

// ---------- 拓扑 / 索引转换 ----------
static int topo_needs_conv(int t) { return t == 6 || t == 7 || t == 9; }   // TriangleFan / Quads / Polygon
// 转换后索引数
static uint32_t conv_count(int t, uint32_t n) { if (t == 7) return n / 4 * 6; return n >= 3 ? (n - 2) * 3 : 0; }
static void gen_pattern(int t, uint32_t n, uint32_t *out) {
    uint32_t k = 0;
    if (t == 7) for (uint32_t q = 0; q + 3 < n; q += 4) { out[k++] = q; out[k++] = q + 1; out[k++] = q + 2; out[k++] = q; out[k++] = q + 2; out[k++] = q + 3; }
    else for (uint32_t i = 1; i + 1 < n; i++) { out[k++] = 0; out[k++] = i; out[k++] = i + 1; }
}
NSString *const k_idx_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct P { ulong src; uint count; uint type; uint mode; uint restart; };\n"
// restart：条带拓扑里窄索引的全 1（8 位 0xFF / 16 位 0xFFFF）是图元重启标记，扩成 32 位要变 0xFFFFFFFF（Metal 条带对 32 位只认它），不能零扩成普通顶点号
"static uint rd(constant P &p, uint i) {\n"
"  uint v;\n"
"  if (p.type == 0) v = ((device const uchar *)p.src)[i];\n"
"  else if (p.type == 1) v = ((device const ushort *)p.src)[i];\n"
"  else return ((device const uint *)p.src)[i];\n"
"  return p.restart != 0 && v == (p.type == 0 ? 0xFFu : 0xFFFFu) ? 0xFFFFFFFFu : v; }\n"
// mode 0：原样扩成 32 位；1：四边形 → 三角形；2：扇形 / 多边形 → 三角形
"kernel void idx_conv(constant P &p [[buffer(0)]], device uint *dst [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
"  if (p.mode == 0) { if (t < p.count) dst[t] = rd(p, t); return; }\n"
"  if (p.mode == 1) { uint q = t * 4; if (q + 3 >= p.count) return; uint o = t * 6;\n"
"    dst[o] = rd(p, q); dst[o+1] = rd(p, q+1); dst[o+2] = rd(p, q+2); dst[o+3] = rd(p, q); dst[o+4] = rd(p, q+2); dst[o+5] = rd(p, q+3); return; }\n"
"  uint i = t + 1; if (i + 1 >= p.count) return; uint o = t * 3; dst[o] = rd(p, 0); dst[o+1] = rd(p, i); dst[o+2] = rd(p, i+1); }\n"
// 间接计数绘制（同 vkCmdDraw[Indexed]IndirectCount）：实际条数 = min(计数缓冲首字, max)；前 n 条按游戏步长拷成紧排参数，其余清零（实例数 0 = 不画）
"struct IC { ulong src; ulong cnt; uint stride; uint max; uint words; };\n"
"kernel void ind_cnt(constant IC &p [[buffer(0)]], device uint *dst [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
"  if (t >= p.max) return; uint n = min(*((device const uint *)p.cnt), p.max);\n"
"  device const uint *s = (device const uint *)(p.src + (ulong)t * p.stride);\n"
"  for (uint k = 0; k < p.words; k++) dst[t * p.words + k] = t < n ? s[k] : 0u; }\n"
// 合批（同 ind_cnt，一次提交里进预载的各条一个派发做完）：t.y = 第几条任务、t.x = 条内序号
"struct ICJ { ulong src; ulong cnt; ulong dst; uint stride; uint max; uint words; uint pad; };\n"
"kernel void ind_cnt_b(device const ICJ *j [[buffer(0)]], uint2 t [[thread_position_in_grid]]) {\n"
"  ICJ p = j[t.y]; if (t.x >= p.max) return; uint n = min(*((device const uint *)p.cnt), p.max);\n"
"  device const uint *s = (device const uint *)(p.src + (ulong)t.x * p.stride); device uint *d = (device uint *)p.dst;\n"
"  for (uint k = 0; k < p.words; k++) d[t.x * p.words + k] = t.x < n ? s[k] : 0u; }\n";
static id<MTLComputePipelineState> g_idx_pso;
static id<MTL4ArgumentTable> g_idx_tab;
// 条带拓扑（LineStrip 3 / TriangleStrip 5）：Metal 对条带恒开图元重启，原生 16 位路径里 0xFFFF 就是重启；转 32 位时要保住这个语义
// 索引转换计算管线（运行时编辅助 MSL）：首次用到或 nxgal_warm_internal 预建
// 索引转换辅助库（k_idx_msl）里按函数名建计算管线：idx_conv 与 ind_cnt 共用
static id<MTLComputePipelineState> helper_pso(int k, NSString *name, NSError **e) {
    id<MTLLibrary> lib = gal_helper_lib(k, e); if (!lib) return nil;
    MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new];
    MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = lib; f.name = name;
    d.computeFunctionDescriptor = f;
    return gal_new_compute_pso(d, e);
}
static id<MTLComputePipelineState> idx_lib_pso(NSString *name, NSError **e) { return helper_pso(GH_IDX, name, e); }
id<MTLComputePipelineState> gal_helper_pso(int k, NSString *name) {
    NSError *e = nil; id<MTLComputePipelineState> p = helper_pso(k, name, &e);
    if (!p) GLOG("【红】辅助计算管线 %s 建不出：%s", name.UTF8String, e.localizedDescription.UTF8String);
    return p;
}
static id<MTLComputePipelineState> g_icnt_b_pso;   // 间接计数整理合批（ind_cnt_b）
static id<MTLComputePipelineState> g_icnt_pso;   // 间接计数整理（k_idx_msl ind_cnt）：与 idx_conv 同库，内部预建一起建（10-22：首次用到才建，怪猎首局计成游戏现建）
int gal_warm_idx(void) {
    if (g_idx_pso) return 1;
    NSError *e = nil;
    g_idx_pso = idx_lib_pso(@"idx_conv", &e);
    if (!g_idx_pso) { GLOG("【红】索引转换管线编译失败：%s", e.localizedDescription.UTF8String); return 0; }
    if (!g_icnt_pso) { g_icnt_pso = idx_lib_pso(@"ind_cnt", &e); if (!g_icnt_pso) GLOG("【红】间接计数整理着色器编译失败：%s", e.localizedDescription.UTF8String); }
    if (!g_icnt_b_pso) { g_icnt_b_pso = idx_lib_pso(@"ind_cnt_b", &e); if (!g_icnt_b_pso) GLOG("【红】间接计数整理合批着色器编译失败：%s", e.localizedDescription.UTF8String); }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2;
    g_idx_tab = [g_gdev newArgumentTableWithDescriptor:ad error:&e];
    return 1;
}
static int topo_is_strip(int t) { return t == 3 || t == 5; }
// GPU 上转换索引：返回转换结果的 GPU 地址（32 位索引），*count = 转换后个数；restart = 窄索引的全 1 转成 0xFFFFFFFF（见 k_idx_msl）
uint64_t g_idxconv_n[2];   // GPU 索引转换次数：[0] 在录流 [1] 遍前段
static uint64_t convert_indices_to(uint64_t src, int type, uint32_t n, int topo, int restart, uint32_t *count, uint64_t dst_fixed) {
    if (!g_idx_pso && !gal_warm_idx()) return 0;
    int mode = topo == 7 ? 1 : topo_needs_conv(topo) ? 2 : 0;
    uint32_t out_n = mode ? conv_count(topo, n) : n, threads = mode == 1 ? n / 4 : mode == 2 ? (n >= 2 ? n - 2 : 0) : n;
    *count = out_n; if (!out_n) return 0;
    // 转换结果只由 GPU 写、GPU 读：GPU 临时池（私有存储，不占进程地址，见 gal_transient_gpu）
    uint64_t dst = dst_fixed; if (!dst && !(dst = gal_transient_gpu(out_n * 4, 16))) return 0;
    struct { uint64_t src; uint32_t count, type, mode, restart; } prm = {src, n, (uint32_t)type, (uint32_t)mode, (uint32_t)(restart != 0)};
    uint64_t pg; void *pp = gal_transient(sizeof prm, 16, &pg); if (!pp) return 0;
    memcpy(pp, &prm, sizeof prm);
    // 帧级调度：渲染遍开着、本遍没有存储写（索引不会是本遍画出来的）→ 录进遍前段，本遍不收（结果写进新分配的块，本遍里没人读过）；
    // 否则录进在录流（结束渲染通道，转换结果下一个通道里用）
    id<MTL4ComputeCommandEncoder> e = nil;
    { int k; gal_cur_enc(&k); if (k == 1 && !gal_pass_swr()) { gal_prepass_want(); e = gal_prepass_enc(); } }
    g_idxconv_n[e != nil]++;
    if (!e) e = gal_cmp_enc();
    if (!e) return 0;
    [e setComputePipelineState:g_idx_pso];
    [g_idx_tab setAddress:pg atIndex:0]; [g_idx_tab setAddress:dst atIndex:1];
    [e setArgumentTable:g_idx_tab];
    [e dispatchThreads:MTLSizeMake(threads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    return dst;
}

// 图元重启只在条带拓扑、且游戏开着重启时成立（10-23 图形接口盘点静默 3：原先只看拓扑、不读开关，关重启时条带里的全 1 顶点号被当成重启）
static int restart_on(int topo) { return topo_is_strip(topo) && g_gs.restart; }
static uint64_t convert_indices(uint64_t src, int type, uint32_t n, int topo, uint32_t *count) { return convert_indices_to(src, type, n, topo, restart_on(topo), count, 0); }
// CPU 上转换（语义逐条同 k_idx_msl）：索引在 CPU 侧可读到当前内容时（gal_buf_cpu_view），只转本次绘制用到的那段进临时缓冲，不开计算编码器、不切渲染通道。
// 10-19 Mac 马车8 赛道：GPU 转换每帧约 27 次切开 1920×1080 主目标的渲染通道，每次整套附件（约 25 MB）读入 + 存回
static uint64_t convert_indices_cpu(const uint8_t *src, int type, uint32_t n, int topo, int restart, uint32_t *count) {
    int mode = topo == 7 ? 1 : topo_needs_conv(topo) ? 2 : 0;
    uint32_t out_n = mode ? conv_count(topo, n) : n; *count = out_n; if (!out_n) return 0;
    uint64_t gpu; uint32_t *d = gal_transient(out_n * 4, 16, &gpu); if (!d) return 0;
    uint32_t rs = type == 0 ? 0xFFu : 0xFFFFu;
#define RD(i) (type == 2 ? ((const uint32_t *)src)[i] : ({ uint32_t v_ = type == 0 ? src[i] : ((const uint16_t *)src)[i]; restart && v_ == rs ? 0xFFFFFFFFu : v_; }))
    if (mode == 0) for (uint32_t t = 0; t < n; t++) d[t] = RD(t);
    else if (mode == 1) for (uint32_t q = 0, o = 0; q + 3 < n; q += 4, o += 6) { d[o] = RD(q); d[o + 1] = RD(q + 1); d[o + 2] = RD(q + 2); d[o + 3] = RD(q); d[o + 4] = RD(q + 2); d[o + 5] = RD(q + 3); }
    else for (uint32_t i = 1, o = 0; i + 1 < n; i++, o += 3) { d[o] = RD(0); d[o + 1] = RD(i); d[o + 2] = RD(i + 1); }
#undef RD
    return gpu;
}

// ---------- 绘制 ----------
// ---------- 宽线（gal_wline.m）----------
// 线拓扑（列表 / 环 / 条带）且线宽 > 1：管线换顶点着色器的 s<键>_wl 入口（三角形），每段 6 个顶点；宽线参数（S2AWideLine 48 字节）绑 GAL_WLINE_SLOT，
// 主入口没走顶点自取的也按自取表取属性（绑 GAL_VPULL_SLOT）。返回 1 = 已处理（画了或无段可画）；0 = 不是宽线或没法展开（调用方照 1 像素画）
static const char *topo_line_name(int t) { return t == 1 ? "列表" : t == 2 ? "环" : "条带"; }
static int wide_line_draw(int t, uint32_t n, uint32_t inst, uint64_t ib, int itype, uint32_t first, int32_t bv, uint32_t base_inst) {
    if (g_line_width <= 1.5f || (t != 1 && t != 2 && t != 3)) return 0;
    const gal_prog *pg0 = gal_prog_get(g_gs.prog);
    if (!pg0 || !pg0->fn_wl || pg0->is_tess) {
        g_wide_line_draws[1]++;
        GRED_ONCE("画宽线（线宽 %.1f，%s）但顶点着色器 %016llx 没有宽线入口（输入结构不规整 / 曲面），照 1 像素画", g_line_width, topo_line_name(t), pg0 ? (unsigned long long)pg0->stage_hash[1] : 0ull);
        return 0;
    }
    uint32_t nseg = t == 1 ? n / 2 : n >= 2 ? (t == 3 ? n - 1 : n) : 0;
    if (!nseg) return 1;
    int w, h, hd, hs; gal_pass_info(&w, &h, &hd, &hs);
    float hx = g_gs.nvp ? fabsf(g_gs.vp[0].w) * 0.5f : w * 0.5f, hy = g_gs.nvp ? fabsf(g_gs.vp[0].h) * 0.5f : h * 0.5f;
    // rst：开图元重启时条带 / 环在全 1 索引处断开（审计 #846 F-wline-restart；同 1 像素条带的 restart_on，列表不重启同 Metal 列表）
    struct { uint64_t ib; uint32_t itype, first; int32_t bv; uint32_t mode, count, rst; float hx, hy, width; uint32_t pad2; } prm =
        {ib, (uint32_t)itype, first, bv, t == 1 ? 0u : t == 3 ? 1u : 2u, n, g_gs.restart && t != 1, hx > 0 ? hx : 1, hy > 0 ? hy : 1, g_line_width, 0};
    _Static_assert(sizeof prm == 48, "S2AWideLine 48 字节（gal_wline.m）");
    uint64_t gpu; void *pp = gal_transient(sizeof prm, 16, &gpu); if (!pp) return 1;
    memcpy(pp, &prm, sizeof prm);
    g_draw_wl = 1; g_gs.dirty |= GS_PSO;
    const gal_prog *pg; __auto_type e = prepare_draw(&pg);
    g_draw_wl = 0; g_gs.dirty |= GS_PSO;   // 下一次普通绘制按普通键取管线、重绑取数表
    if (!e) return 1;
    if (!pg->vs_pulled) { uint64_t vt; if (!gal_vpull_fill(pg, &vt)) return 1; [g_vt setAddress:vt atIndex:GAL_VPULL_SLOT]; }
    [g_vt setAddress:gpu atIndex:GAL_WLINE_SLOT];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 * nseg instanceCount:inst baseInstance:base_inst];
    if (!g_wide_line_draws[0]++) GLOG("宽线展开：线宽 %.1f、%s %u 段（顶点着色器 %016llx，gal_wline.m）", g_line_width, topo_line_name(t), nseg, (unsigned long long)pg->stage_hash[1]);
    return 1;
}

NXGAL_API void nxgal_draw(int32_t vertex_count, int32_t instance_count, int32_t first_vertex, int32_t first_instance) { GAL_API_LOCK();
    GP_SCOPE(GP_DRAW);
    if (vertex_count <= 0 || instance_count <= 0) return;
    if (g_gs.topology == 14) { gal_tess_draw(0, (uint32_t)vertex_count, (uint32_t)instance_count, (uint32_t)first_vertex, 0, (uint32_t)first_instance); return; }   // 曲面片（gal_tess.m）
    int t = g_gs.topology, ok; MTLPrimitiveType pt = gal_prim(t, &ok);
    if (!ok) { GRED_ONCE("拓扑 %d 未实现（邻接），绘制跳过", t); return; }
    if (wide_line_draw(t, (uint32_t)vertex_count, (uint32_t)instance_count, 0, 0, (uint32_t)first_vertex, 0, (uint32_t)first_instance)) return;
    if (topo_needs_conv(t)) {   // 模式索引在 CPU 生成（与数据无关）
        uint32_t n = conv_count(t, (uint32_t)vertex_count); if (!n) return;
        uint64_t ig; uint32_t *ix = gal_transient(n * 4, 16, &ig); if (!ix) return;
        gen_pattern(t, (uint32_t)vertex_count, ix);
        const gal_prog *pg; id<MTL4RenderCommandEncoder> e = prepare_draw(&pg); if (!e) return;
        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ig indexBufferLength:n * 4
                   instanceCount:instance_count baseVertex:first_vertex baseInstance:first_instance];
        return;
    }
    const gal_prog *pg; id<MTL4RenderCommandEncoder> e = prepare_draw(&pg); if (!e) return;
    [e drawPrimitives:pt vertexStart:first_vertex vertexCount:vertex_count instanceCount:instance_count baseInstance:first_instance];
}

NXGAL_API void nxgal_draw_indexed(int32_t index_count, int32_t instance_count, int32_t first_index, int32_t first_vertex, int32_t first_instance) { GAL_API_LOCK();
    GP_SCOPE(GP_DRAW);
    if (index_count <= 0 || instance_count <= 0) return;
    if (g_gs.topology == 14) { gal_tess_draw(1, (uint32_t)index_count, (uint32_t)instance_count, (uint32_t)first_index, first_vertex, (uint32_t)first_instance); return; }   // 曲面片（gal_tess.m）
    int t = g_gs.topology, ok; MTLPrimitiveType pt = gal_prim(t, &ok);
    if (!ok) { GRED_ONCE("拓扑 %d 未实现（邻接），绘制跳过", t); return; }
    int isz = g_gs.ib_type == 0 ? 1 : g_gs.ib_type == 1 ? 2 : 4;
    uint64_t base = gal_buf_read_gpu(g_gs.ib.buf, g_gs.ib.offset, g_gs.ib.size), src = base ? base + (uint64_t)first_index * isz : 0;
    if (!src) { GRED_ONCE("索引绘制没有有效的索引缓冲"); return; }
    if (wide_line_draw(t, (uint32_t)index_count, (uint32_t)instance_count, src, g_gs.ib_type + 1, 0, first_vertex, (uint32_t)first_instance)) return;
    uint64_t ia = src; MTLIndexType it = isz == 2 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32; uint32_t n = (uint32_t)index_count;
    // 关重启的 16 位条带：Metal 条带对 16 位恒按 0xFFFF 重启，而这时 0xFFFF 是顶点 65535——索引里有 0xFFFF 就要零扩成 32 位（32 位全 1 当顶点本来就越界，不处理）
    int norst16 = isz == 2 && topo_is_strip(t) && !g_gs.restart;
    // 要转换（8 位 / 拓扑转换 / 16 位起点未对齐 / 关重启的 16 位条带）且 CPU 侧能读到当前内容：在 CPU 上转本次用到的那段，不切渲染通道
    if ((isz == 1 || topo_needs_conv(t) || (isz == 2 && (src & 3)) || norst16) && (int64_t)(first_index + (int64_t)index_count) * isz <= g_gs.ib.size) {
        const uint8_t *cpu = gal_buf_cpu_view(g_gs.ib.buf, g_gs.ib.offset + first_index * isz, index_count * isz);
        // 关重启的 16 位条带、对齐、索引里没有 0xFFFF：原样走 16 位，不转
        int plain = 0;
        if (cpu && norst16 && !(src & 3)) { plain = 1; for (int32_t k = 0; k < index_count; k++) if (((const uint16_t *)cpu)[k] == 0xFFFF) { plain = 0; break; } }
        if (cpu && !plain && (ia = convert_indices_cpu(cpu, g_gs.ib_type, (uint32_t)index_count, t, restart_on(t), &n))) {
            it = MTLIndexTypeUInt32; if (topo_needs_conv(t)) pt = MTLPrimitiveTypeTriangle;
            const gal_prog *pg; id<MTL4RenderCommandEncoder> e = prepare_draw(&pg); if (!e) return;
            [e drawIndexedPrimitives:pt indexCount:n indexType:it indexBuffer:ia indexBufferLength:(NSUInteger)n * 4
                       instanceCount:instance_count baseVertex:first_vertex baseInstance:first_instance];
            return;
        }
        if (cpu && !plain) return;   // 转换后为空（如不足一个图元）
        ia = src; n = (uint32_t)index_count; if (plain) norst16 = 0;
    }
    // 索引起点地址不是 4 的倍数（16 位索引落在 2 字节处）：Metal 读出来的三角形不对（10-18 塞尔达神庙第 717 次绘制少一条几何，对拍逐像素核实；
    // 转成 32 位后到第 9452 条全部一致）。整段绑定区间转成对齐的 32 位索引，按（偏移, 长度）缓存在缓冲上、被写才作废，只在缓存不命中时切通道
    // 关重启的 16 位条带且 CPU 读不到（不知道有没有 0xFFFF）：同样整段零扩成 32 位、按缓冲缓存（被写才作废），每份内容只转一次
    if (isz == 2 && ((src & 3) || norst16) && !topo_needs_conv(t) && g_gs.ib.size >= 2) {
        uint32_t total = (uint32_t)g_gs.ib.size / 2, cn;
        // 缓存键：跨度 -2 = 不带重启、-3 = 条带开重启（0xFFFF → 0xFFFFFFFF）——同一段索引被列表和条带分别用时结果不同（10-19 怪猎语言页：零扩把重启变成顶点 65535，画出斜向乱三角）
        int strip = restart_on(t), fresh; uint64_t dst = gal_buf_restride(g_gs.ib.buf, g_gs.ib.offset, g_gs.ib.size, strip ? -3 : -2, total * 4, &fresh);
        SW_SCOPE(SW_IDXCONV, gal_sw_hit(SW_BUFKEY(g_gs.ib.buf), 1));   // 调度测算：索引转换挪到遍外，源索引是本遍画出来的才是真依赖
        if (dst && (!fresh || convert_indices_to(base, 1, total, 4, strip, &cn, dst))) { ia = dst + (uint64_t)first_index * 4; it = MTLIndexTypeUInt32; g_gp_n[GP_IDXALIGN]++; }
        // 刚建的缓存没转成（临时内存取不到）：作废，下面走一次性转换
        else if (dst && fresh) gal_buf_restride_drop(g_gs.ib.buf, g_gs.ib.offset, g_gs.ib.size);
    }
    if (isz == 1 || topo_needs_conv(t) || (it == MTLIndexTypeUInt16 && ((ia & 3) || norst16))) {   // 8 位索引 / 需拓扑转换 / 未对齐或关重启的 16 位条带且缓存没取到：GPU 上转成 32 位（切开渲染通道）
        { SW_SCOPE(SW_IDXCONV, gal_sw_hit(SW_BUFKEY(g_gs.ib.buf), 1)); ia = convert_indices(src, g_gs.ib_type, (uint32_t)index_count, t, &n); } if (!ia) return;
        it = MTLIndexTypeUInt32; if (topo_needs_conv(t)) pt = MTLPrimitiveTypeTriangle;
    }
    const gal_prog *pg; id<MTL4RenderCommandEncoder> e = prepare_draw(&pg); if (!e) return;
    [e drawIndexedPrimitives:pt indexCount:n indexType:it indexBuffer:ia indexBufferLength:(NSUInteger)n * (it == MTLIndexTypeUInt16 ? 2 : 4)
               instanceCount:instance_count baseVertex:first_vertex baseInstance:first_instance];
}

// 关重启的 16 位条带间接绘制：要画的那几段在 GPU 参数里、CPU 不知道，整段绑定区间零扩成 32 位（同上面直接绘制的缓存，跨度键 -2 = 不带重启），
// 间接参数的首索引按个数计、转后照用。返回 32 位索引的 GPU 地址，0 = 没转成（照原 16 位画，报红）
static uint64_t ib_norestart32(void) {
    if (g_gs.ib.size < 2) return 0;
    uint64_t base = gal_buf_read_gpu(g_gs.ib.buf, g_gs.ib.offset, g_gs.ib.size); if (!base) return 0;
    uint32_t total = (uint32_t)g_gs.ib.size / 2, cn; int fresh;
    uint64_t dst = gal_buf_restride(g_gs.ib.buf, g_gs.ib.offset, g_gs.ib.size, -2, total * 4, &fresh);
    if (dst && (!fresh || convert_indices_to(base, 1, total, 4, 0, &cn, dst))) return dst;
    if (dst && fresh) gal_buf_restride_drop(g_gs.ib.buf, g_gs.ib.offset, g_gs.ib.size);
    GRED_ONCE("关重启的 16 位条带间接绘制：索引没转成 32 位，含 0xFFFF 时会被 Metal 当重启");
    return 0;
}
NXGAL_API void nxgal_draw_indirect(const nxgal_buf_range *ind, int32_t indexed) { GAL_API_LOCK();
    GP_SCOPE(GP_DRAW);
    int t = g_gs.topology, ok; MTLPrimitiveType pt = gal_prim(t, &ok);
    if (!ok || topo_needs_conv(t)) { GRED_ONCE("间接绘制的拓扑 %d 需要转换，未实现，绘制跳过", t); return; }
    if (g_line_width > 1.5f && (t == 1 || t == 2 || t == 3)) { g_wide_line_draws[1]++; GRED_ONCE("间接绘制画宽线（线宽 %.1f）：段数在 GPU 上，未展开，照 1 像素画", g_line_width); }
    uint64_t a = gal_buf_gpu(ind->buf, ind->offset); if (!a) return;
    if (indexed) {
        if (g_gs.ib_type == 0) { GRED_ONCE("间接索引绘制用 8 位索引，未实现，绘制跳过"); return; }
        int isz = g_gs.ib_type == 1 ? 2 : 4; NSUInteger ilen = (NSUInteger)g_gs.ib.size;
        uint64_t ib = 0, z = isz == 2 && topo_is_strip(t) && !g_gs.restart ? ib_norestart32() : 0;
        if (z) { ib = z; isz = 4; ilen = (NSUInteger)(g_gs.ib.size / 2) * 4; }
        else if (!(ib = gal_buf_gpu(g_gs.ib.buf, g_gs.ib.offset))) return;
        const gal_prog *pg; id<MTL4RenderCommandEncoder> e = prepare_draw(&pg); if (!e) return;
        [e drawIndexedPrimitives:pt indexType:isz == 2 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32 indexBuffer:ib indexBufferLength:ilen indirectBuffer:a];
    } else {
        const gal_prog *pg; id<MTL4RenderCommandEncoder> e = prepare_draw(&pg); if (!e) return;
        [e drawPrimitives:pt indirectBuffer:a];
    }
}
// 间接计数绘制：GPU 上按计数缓冲把参数整理成紧排的 max_draws 条（超出计数的清零，见 k_idx_msl ind_cnt），再发 max_draws 次普通间接绘制。
// 计数在 GPU 上才知道（游戏的计算着色器刚写），CPU 不读回；整理要计算编码器，切开渲染通道（同 GPU 索引转换）。10-20 怪猎第 946 帧在这里跳绘制后 GPU 卡死
// 参数整理次数：[0] 在录流（遍开着就切遍）[1] 遍前段（不切遍）
uint64_t g_icnt_n[2];
// 间接计数整理挪进预载段的次数，与没挪进预载的原因：[0] 参数 / 计数被本命令缓冲在录流里的 GPU 工作写过，[1] 有录进在录流的上传 / 待拷回（单测 / 诊断）
uint64_t g_icnt_pre, g_icnt_nopre[2];
// 开遍预整理（10-22 帧率能耗线）：怪猎几乎每遍都有间接计数绘制、参数常是本帧 GPU 计算写的（预载读不到），遍开着才来整理只能插遍前段（要分段，每段一个命令缓冲）
// 或切遍。同一目标组里游戏每帧用的参数位置（缓冲 / 偏移 / 条数上限 / 步长）基本不变：记下上一帧每个目标组出现过的，开遍时（渲染编码器之前、同一段里，
// 开遍那一刻参数的内容就是遍里绘制时的内容——只要之后没人写它）先整理好；遍里的绘制位置对得上、参数缓冲开遍后没被写过（gal_buf_wser）、本遍没有存储写，就直接取结果。
// 对不上的照旧走预载 / 遍前段 / 在录流。猜错只多做一次整理（GPU 临时内存，随提交回收），不影响正确性
static int icnt_inpass(void);
typedef struct { uint32_t ib, pb; int32_t io, po, max, stride, words; } icnt_key;
enum { ICS_N = 2048, ICS_GRP = 1024, ICP_N = 64 };
static struct { icnt_key k; uint32_t grp; int next; } g_ics[2][ICS_N];   // 按帧奇偶两格：本帧记、上一帧用
static int g_nics[2], g_ics_head[2][ICS_GRP]; static uint64_t g_ics_frame[2] = {UINT64_MAX, UINT64_MAX};   // 初值「无」：零初值会让第 1 帧把没清过的头指针（0）当成有效链表、成环
static struct { icnt_key k; uint64_t dst; uint32_t wser; } g_icp[ICP_N]; static int g_nicp; static uint64_t g_icp_pass;
uint64_t g_icnt_pb, g_icnt_pbw;   // 开遍预整理：遍里直接取用次数 / 预整理次数（单测 / 诊断）
uint32_t gal_pass_group(void);
static int ics_slot(void) {
    int s = (int)(g_gp_frame & 1);
    if (g_ics_frame[s] != g_gp_frame) { g_ics_frame[s] = g_gp_frame; g_nics[s] = 0; for (int i = 0; i < ICS_GRP; i++) g_ics_head[s][i] = -1; }
    return s;
}
static void ics_note(const icnt_key *k, uint32_t grp) {
    if (grp >= ICS_GRP) return;
    int s = ics_slot();
    for (int i = g_ics_head[s][grp]; i >= 0; i = g_ics[s][i].next) if (!memcmp(&g_ics[s][i].k, k, sizeof *k)) return;
    if (g_nics[s] >= ICS_N) return;
    int i = g_nics[s]++; g_ics[s][i].k = *k; g_ics[s][i].grp = grp; g_ics[s][i].next = g_ics_head[s][grp]; g_ics_head[s][grp] = i;
}
static int icnt_encode(id ce, uint64_t src, uint64_t cnt, const icnt_key *k, uint64_t dst);
// 开遍时调（gal_core.m gal_render_begin_desc，渲染编码器之前）：上一帧同一目标组出现过的间接计数，参数此刻可读就先整理
void gal_icnt_prebegin(uint32_t grp, id (*enc)(void)) {
    g_nicp = 0; g_icp_pass = gal_pass_serial();
    if (grp >= ICS_GRP || icnt_inpass() || !g_gp_frame) return;
    int s = (int)((g_gp_frame - 1) & 1);
    if (g_ics_frame[s] != g_gp_frame - 1) return;
    for (int i = g_ics_head[s][grp]; i >= 0 && g_nicp < ICP_N; i = g_ics[s][i].next) {
        const icnt_key *k = &g_ics[s][i].k;
        if (!gal_buf_size(k->ib) || !gal_buf_size(k->pb)) continue;
        int32_t ilen = (k->max - 1) * k->stride + k->words * 4;
        uint64_t src = gal_buf_read_gpu(k->ib, k->io, ilen), cnt = gal_buf_read_gpu(k->pb, k->po, 4); if (!src || !cnt) continue;
        uint64_t dst = gal_transient_gpu((uint32_t)k->max * (uint32_t)k->words * 4, 16); if (!dst) continue;
        if (!icnt_encode(enc(), src, cnt, k, dst)) continue;
        g_icp[g_nicp].k = *k; g_icp[g_nicp].dst = dst; g_icp[g_nicp].wser = gal_buf_wser_now(); g_nicp++; g_icnt_pbw++;
    }
}
// 预载里的间接计数整理合批（缺省开，NXGAL_ICNT_BATCH=0 关）：怪猎每帧约 860 次带计数的间接绘制（89% 只 1 条），原先每次一个派发、
// 预载编码器里相邻两条之间一道屏障（enc_seq_barrier），GPU 时间耗在派发与屏障上（10-24 帧率能耗线真机约 12 ms/帧）。
// 进预载的整理只读本次提交开头的内容（gal_buf_preload_readable）、各写各的临时块，先后无关：先记成任务表，提交收尾时
// （gal_icnt_batch_flush，预载编码器收口之前）一个二维派发做完；录绘制时只记下结果地址
static int icnt_batch_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_ICNT_BATCH"); v = !(e && *e == '0'); } return v; }
static struct icj { uint64_t src, cnt, dst; uint32_t stride, max, words, pad; } *g_icj; static uint32_t g_nicj, g_capicj, g_icj_max;
uint64_t g_icnt_batch_n[2];   // [0] 合批派发次数 [1] 合进去的整理条数（单测 / 诊断）
static int icnt_encode(id ce, uint64_t src, uint64_t cnt, const icnt_key *k, uint64_t dst);
static int icj_add(uint64_t src, uint64_t cnt, const icnt_key *k, uint64_t dst) {
    if (!g_icnt_b_pso && !gal_warm_idx()) return 0;
    if (!g_icnt_b_pso) return 0;
    if (g_nicj == g_capicj) { uint32_t nc = g_capicj ? g_capicj * 2 : 256; struct icj *nj = realloc(g_icj, nc * sizeof *nj); if (!nj) return 0; g_icj = nj; g_capicj = nc; }
    g_icj[g_nicj++] = (struct icj){src, cnt, dst, (uint32_t)k->stride, (uint32_t)k->max, (uint32_t)k->words, 0};
    if ((uint32_t)k->max > g_icj_max) g_icj_max = (uint32_t)k->max;
    return 1;
}
void gal_icnt_batch_flush(void) {
    if (!g_nicj) return;
    uint32_t n = g_nicj, w = g_icj_max; g_nicj = 0; g_icj_max = 0;
    id ce = gal_preload_cmp_enc(); if (!ce) { GRED_ONCE("间接计数整理合批：取不到预载编码器，%u 条没整理", n); return; }
    uint64_t jg; void *jp = gal_transient(n * (uint32_t)sizeof *g_icj, 16, &jg);
    if (!jp) {   // 临时内存取不到：逐条退回单派发（绘制已录、结果地址已定，不能不写）
        GRED_ONCE("间接计数整理合批：任务表 %u 条取不到临时内存，逐条派发", n);
        for (uint32_t i = 0; i < n; i++) { icnt_key k = {0}; k.stride = (int32_t)g_icj[i].stride; k.max = (int32_t)g_icj[i].max; k.words = (int32_t)g_icj[i].words;
            icnt_encode(i ? gal_preload_cmp_enc() : ce, g_icj[i].src, g_icj[i].cnt, &k, g_icj[i].dst); }
        return;
    }
    memcpy(jp, g_icj, n * sizeof *g_icj);
    [ce setComputePipelineState:g_icnt_b_pso];
    [g_idx_tab setAddress:jg atIndex:0];
    [ce setArgumentTable:g_idx_tab];
    [ce dispatchThreads:MTLSizeMake(w, n, 1) threadsPerThreadgroup:MTLSizeMake(w < 64 ? w : 64, w < 64 ? (64 / w < n ? 64 / w : n) : 1, 1)];
    g_icnt_batch_n[0]++; g_icnt_batch_n[1] += n;
}
static int icnt_inpass(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_ICNT_INPASS"); v = e && *e == '1'; } return v; }
NXGAL_API void nxgal_draw_indirect_count(const nxgal_buf_range *ind, const nxgal_buf_range *param, int32_t max_draws, int32_t stride, int32_t indexed) { GAL_API_LOCK();
    GP_SCOPE(GP_DRAW);
    if (max_draws <= 0) return;
    int t = g_gs.topology, ok; MTLPrimitiveType pt = gal_prim(t, &ok);
    if (!ok || topo_needs_conv(t)) { GRED_ONCE("间接计数绘制的拓扑 %d 需要转换，未实现，绘制跳过", t); return; }
    if (g_line_width > 1.5f && (t == 1 || t == 2 || t == 3)) { g_wide_line_draws[1]++; GRED_ONCE("间接计数绘制画宽线（线宽 %.1f）：段数在 GPU 上，未展开，照 1 像素画", g_line_width); }
    uint32_t words = indexed ? 5 : 4;   // Vulkan / Metal 间接参数布局相同：索引 5 字（数、实例、首索引、基顶点、首实例），非索引 4 字
    if (stride < (int32_t)words * 4 || (stride & 3)) { GRED_ONCE("间接计数绘制步长 %d 不合法（至少 %u 字节且 4 字节对齐），绘制跳过", stride, words * 4); return; }
    // 参数 / 计数只读：按只读取址（登记读用法、不记 GPU 写；读到待拷回的取镜像）。先判预载可读再取址——通用取址 gal_buf_gpu 按「GPU 可能写」登记，
    // 本命令缓冲里就算被它写过，之后的间接计数整理全进不了预载（10-22 单测：参数 / 计数缓冲次次判成「被本命令缓冲 GPU 写」）
    int32_t ilen = (max_draws - 1) * stride + (int32_t)words * 4;
    int pre = gal_buf_preload_readable(ind->buf, ind->offset, ilen) && gal_buf_preload_readable(param->buf, param->offset, 4);
    if (!pre) g_icnt_nopre[gal_buf_gpu_written(ind->buf) || gal_buf_gpu_written(param->buf) ? 0 : 1]++;
    uint64_t src = gal_buf_read_gpu(ind->buf, ind->offset, ilen), cnt = gal_buf_read_gpu(param->buf, param->offset, 4); if (!src || !cnt) return;
    uint64_t ib = 0; int isz = 0;
    if (indexed) {
        if (g_gs.ib_type == 0) { GRED_ONCE("间接计数索引绘制用 8 位索引，未实现，绘制跳过"); return; }
        isz = g_gs.ib_type == 1 ? 2 : 4;
        uint64_t z = isz == 2 && topo_is_strip(t) && !g_gs.restart ? ib_norestart32() : 0;
        if (z) { ib = z; isz = 4; } else if (!(ib = gal_buf_gpu(g_gs.ib.buf, g_gs.ib.offset))) return;
    }
    icnt_key key; memset(&key, 0, sizeof key);
    key.ib = ind->buf; key.pb = param->buf; key.io = ind->offset; key.po = param->offset; key.max = max_draws; key.stride = stride; key.words = (int32_t)words;
    // 开遍预整理取用：本遍开遍时已按同一位置整理过、之后参数缓冲没被写过、本遍没有存储写
    uint64_t dst = 0;
    { int k; gal_cur_enc(&k);
      if (k == 1 && g_icp_pass == gal_pass_serial() && !gal_pass_swr())
          for (int i = 0; i < g_nicp; i++) if (!memcmp(&g_icp[i].k, &key, sizeof key) && gal_buf_wser(key.ib) <= g_icp[i].wser && gal_buf_wser(key.pb) <= g_icp[i].wser) { dst = g_icp[i].dst; g_icnt_pb++; break; } }
    if (!dst) {
    // 整理结果只由 GPU 写、GPU 读：GPU 临时池（私有存储）
    dst = gal_transient_gpu((uint32_t)max_draws * words * 4, 16); if (!dst) return;
    // 不切遍（帧率能耗线 10-21；NXGAL_ICNT_INPASS=1 退回）。先试预载段：参数 / 计数两段此刻的内容与本命令缓冲开头相同
    //（本命令缓冲的在录流里没有 GPU 写它们、没有录进在录流的上传，判据同顶点重排 / 缓冲拷贝挪进预载：gal_buf_preload_readable），
    // 整理录进预载（每次提交一个，排在本命令缓冲全部工作之前），不用为本遍单开命令缓冲。10-22 怪猎每遍都有间接计数绘制：只靠遍前段时每遍要分段，
    // 分段受命令分配器内存限住（549a65458）后每帧 121 → 200 遍。
    // 预载不行再试遍前段（渲染遍开着、开在段首、本遍里还没有存储写时，参数此刻的内容就是开遍时的内容，录进 gal_prepass_enc，排在本遍之前）；
    // 都不行照旧录进在录流：结束渲染通道，编码器之间全序屏障保证下一个通道读到整理结果
    id ce = nil; int queued = 0;
    if (pre && !icnt_inpass()) {
        if (icnt_batch_on() && gal_be_kind() == GAL_BE_MTL4 && icj_add(src, cnt, &key, dst)) queued = 1;
        else ce = gal_preload_cmp_enc();
        g_icnt_pre++;
    }
    if (!queued) {
    if (!ce) {
        gal_prepass_want();
        ce = gal_pass_swr() ? nil : gal_prepass_enc();
        g_icnt_n[ce != nil]++;
    }
    if (!ce) ce = gal_cmp_enc();
    if (!ce) return;
    if (!icnt_encode(ce, src, cnt, &key, dst)) return;
    }
    }
    const gal_prog *pg2; __auto_type e = prepare_draw(&pg2); if (!e) return;
    ics_note(&key, gal_pass_group());
    // 读绘制号的程序：第 i 条子绘制的绘制号 = i（同 vkCmdDrawIndirectCount 的 gl_DrawID），逐条把 GAL_DRAWID_SLOT 指向序号表第 i 项；画完指回 0
    uint64_t dids = 0;
    if (pg2->drawid) { uint32_t *t = gal_transient((uint32_t)max_draws * 4, 16, &dids); if (!t) return; for (int32_t i = 0; i < max_draws; i++) t[i] = (uint32_t)i; }
    for (int32_t i = 0; i < max_draws; i++) {
        uint64_t a = dst + (uint64_t)i * words * 4;
        if (dids) [g_vt setAddress:dids + (uint64_t)i * 4 atIndex:GAL_DRAWID_SLOT];
        if (indexed) [e drawIndexedPrimitives:pt indexType:isz == 2 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32 indexBuffer:ib indexBufferLength:(NSUInteger)(g_gs.ib.size / (g_gs.ib_type == 1 ? 2 : 4)) * (NSUInteger)isz indirectBuffer:a];
        else [e drawPrimitives:pt indirectBuffer:a];
    }
    if (dids) [g_vt setAddress:g_zero.gpuAddress atIndex:GAL_DRAWID_SLOT];
}
// 录一次间接计数整理：src = 带计数的参数、cnt = 计数，结果逐条写进 dst（Metal 间接参数布局）。返回 0 = 着色器 / 临时内存取不到（已报红）
static int icnt_encode(id ce, uint64_t src, uint64_t cnt, const icnt_key *k, uint64_t dst) {
    if (!g_icnt_pso) { NSError *e = nil; g_icnt_pso = idx_lib_pso(@"ind_cnt", &e); if (!g_icnt_pso) { GRED_ONCE("间接计数整理着色器编译失败：%s", e.localizedDescription.UTF8String); return 0; } }
    if (!g_idx_tab && !gal_warm_idx()) return 0;
    struct { uint64_t src, cnt; uint32_t stride, max, words; } prm = {src, cnt, (uint32_t)k->stride, (uint32_t)k->max, (uint32_t)k->words};
    uint64_t pg; void *pp = gal_transient(sizeof prm, 16, &pg); if (!pp) return 0; memcpy(pp, &prm, sizeof prm);
    [ce setComputePipelineState:g_icnt_pso];
    [g_idx_tab setAddress:pg atIndex:0]; [g_idx_tab setAddress:dst atIndex:1];
    [ce setArgumentTable:g_idx_tab];
    [ce dispatchThreads:MTLSizeMake((NSUInteger)k->max, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    return 1;
}
// DrawTexture（同 Vulkan HelperShader.DrawTexture）：保留当前混合 / 写掩码，关剔除与深度模板，视口 = 目标矩形，三角带 4 顶点采样源矩形。
// 实现：内置辅助程序走普通绘制路径（管线缓存 / 参数缓冲同一套），前后保存恢复被临时改动的状态。
NSString *const k_dt_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VO { float4 pos [[position]]; float2 tc; };\n"
"struct S0 { constant float4 *r [[id(0)]]; };\n"
"struct S2 { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
"vertex VO dt_vs(uint v [[vertex_id]], constant S0 &s0 [[buffer(0)]]) {\n"
"  float2 uv = float2(v & 1, v >> 1); float4 r = s0.r[0];\n"
"  VO o; o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0); o.tc = float2(mix(r.x, r.y, uv.x), mix(r.z, r.w, uv.y)); return o; }\n"
"fragment float4 dt_fs(VO in [[stage_in]], constant S2 &s2 [[buffer(2)]]) { return s2.t.sample(s2.s, in.tc); }\n";
static gal_prog g_dt_prog; static gal_arg g_dt_args[3];
NXGAL_API void nxgal_draw_texture(uint32_t tex, uint32_t smp, const float src[4], const float dst[4]) { GAL_API_LOCK();
    gal_tex *t = gal_tex_get(tex); if (!t) return;
    if (!g_dt_prog.live) {
        NSError *e = nil; id<MTLLibrary> lib = gal_helper_lib(GH_DT, &e);
        if (!lib) { GLOG("【红】DrawTexture 辅助着色器编译失败：%s", e.localizedDescription.UTF8String); return; }
        MTL4LibraryFunctionDescriptor *v = [MTL4LibraryFunctionDescriptor new], *f = [MTL4LibraryFunctionDescriptor new];
        v.library = f.library = lib; v.name = @"dt_vs"; f.name = @"dt_fs";
        g_dt_args[0] = (gal_arg){GAL_ARG_UBO, 0, GS_MAX_BUF - 1, 0, 1, 1u << 1};
        g_dt_args[1] = (gal_arg){GAL_ARG_TEX, 2, GS_MAX_TEX - 1, 0, 1, 1u << 5};
        g_dt_args[2] = (gal_arg){GAL_ARG_SMP, 2, GS_MAX_TEX - 1, 8, 1, 1u << 5};
        g_dt_prog.fn[1] = v; g_dt_prog.fn[5] = f; g_dt_prog.args = g_dt_args; g_dt_prog.nargs = 3;
        g_dt_prog.set_size[0] = 8; g_dt_prog.set_stages[0] = 1u << 1; g_dt_prog.set_size[2] = 16; g_dt_prog.set_stages[2] = 1u << 5;
        g_dt_prog.stage_set_size[1][0] = 8; g_dt_prog.stage_set_size[5][2] = 16;
        g_dt_prog.fs_outputs = 1; g_dt_prog.hash = 0xd7a3e1c0de000001ull; for (int i = 0; i < 6; i++) g_dt_prog.size_buf_index[i] = -1;
        g_dt_prog.live = 1;
    }
    static uint32_t prog_id; if (!prog_id) prog_id = gal_prog_register_builtin(&g_dt_prog);
    if (!prog_id) return;
    // 区域常量：源矩形归一化；目标矩形反向时交换（同 Vulkan）
    float w = (float)t->tex.width, h = (float)t->tex.height, r[4] = {src[0] / w, src[2] / w, src[1] / h, src[3] / h};
    if (dst[0] > dst[2]) { float x = r[0]; r[0] = r[1]; r[1] = x; }
    if (dst[1] > dst[3]) { float x = r[2]; r[2] = r[3]; r[3] = x; }
    uint32_t rb = nxgal_buf_create(16, 0); nxgal_buf_set_data(rb, 0, r, 16);
    gal_state saved = g_gs;
    g_gs.prog = prog_id; g_gs.topology = 5; g_gs.cull_en = 0; g_gs.depth.test = 0; g_gs.depth.write = 0; g_gs.stencil.enable = 0;
    float x0 = dst[0] < dst[2] ? dst[0] : dst[2], y0 = dst[1] < dst[3] ? dst[1] : dst[3];
    g_gs.vp[0] = (nxgal_viewport){x0, y0, fabsf(dst[2] - dst[0]), fabsf(dst[3] - dst[1]), {0, 2, 4, 6}, 0, 1}; g_gs.nvp = 1;
    g_gs.ubo[GS_MAX_BUF - 1] = (nxgal_buf_range){rb, 0, 16, 0};
    g_gs.tex[GS_MAX_TEX - 1] = tex; g_gs.smp[GS_MAX_TEX - 1] = smp;
    g_gs.dirty = ~0u;
    nxgal_draw(4, 1, 0, 0);
    saved.dirty = ~0u; g_gs = saved;
    nxgal_buf_delete(rb);
}
// ---- 第 8 块（曲面细分，gal_tess.m）用的内部件 ----
id gal_draw_table(int which) { draw_init(); return which == 0 ? g_vt : which == 1 ? g_ft : g_ct; }
int gal_bind_stage(const gal_prog *pg, int st, id table) { int m = 0; return bind_stage(pg, st, table, &m); }
void gal_draw_preflush(const gal_prog *pg) { draw_init(); restride_vertex_buffers(pg); preflush_nonmirror(pg); if (gal_pass_texbar_armed() && tex_hit(pg, gal_pass_is_attachment)) gal_enc_end(); if (gal_pass_hidden_any() && tex_hit(pg, gal_pass_hidden_hit)) gal_enc_end(); clears_touch(pg); }
id gal_prepare_draw(const gal_prog **out_pg) { return prepare_draw(out_pg); }
NXGAL_API void nxgal_begin_transform_feedback(int32_t topology) { GAL_API_LOCK(); GRED_ONCE("变换反馈未实现（第 8 块；能力表报不支持）"); }
NXGAL_API void nxgal_end_transform_feedback(void) { GAL_API_LOCK();}

// ---------- 计算派发 ----------
typedef struct { uint64_t hash; id<MTLComputePipelineState> p; } cpso_ent;
static cpso_ent *g_cpso; static int g_ncpso;
// 着色器函数 → 计算管线，按键缓存（计算程序按程序哈希；曲面的顶点 / TCS 计算核按着色器键）
id<MTLComputePipelineState> gal_fn_compute_pso(id fn, uint64_t key) {
    for (int i = 0; i < g_ncpso; i++) if (g_cpso[i].hash == key) return g_cpso[i].p;
    MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new];
    d.computeFunctionDescriptor = fn;
    NSError *e = nil;
    id<MTLComputePipelineState> p = gal_new_compute_pso(d, &e);
    // 编不过也记进缓存（p = nil）：以后同键直接返回空、不再重编。10-21 怪猎 98e4eb43c87f2b1c 运行时编一次约 1.6 秒（系统编译服务中止后返回空），
    //   不缓存就每次派发都在 API 锁里重编一遍，表现为持续卡顿
    if (!p) { static int n; if (n++ < 8) GLOG("【红】计算管线编译失败（键 %016llx）：%s；记为编不过，同键不再重编", (unsigned long long)key, e.localizedDescription.UTF8String); }
    __typeof__(g_cpso) nc = gal_grow(g_cpso, (size_t)g_ncpso + 1, sizeof *g_cpso, "计算管线缓存"); if (!nc) return p;   // 扩不了（P1-44）：这次照用、不进缓存
    g_cpso = nc; memset((void *)&g_cpso[g_ncpso], 0, sizeof *g_cpso);
    g_cpso[g_ncpso].hash = key; g_cpso[g_ncpso].p = p; g_ncpso++;
    return p;
}
// 派发次数：[0] 在录流（遍开着就切遍）[1] 遍前段（不切遍）
uint64_t g_disp_n[2];
// 遍内派发能否挪到当前遍之前（遍前段）：渲染遍开着、本遍还没有存储写（派发不会要读遍里画的结果）；派发不碰本遍附件；
// 要写的缓冲区间本遍没人用过（gal_buf_prepass_ok；有待拷回镜像的缓冲，拷回一并录进遍前段）；写的图像本遍没用过（gal_pass_tex_used，贴图不换块）
// 诊断：遍开着却没挪的原因计数 [0] 本遍有存储写 [1]（不再拦：待拷回镜像一并拷回进遍前段）[2] 用到本遍附件 [3] 写的图像本遍用过 [4] 遍前段没开 [5] 要写 / 要拷回的缓冲区间本遍已用
uint64_t g_disp_why[6];
static int dispatch_hoistable(const gal_prog *pg) {
    int k; gal_cur_enc(&k); if (k != 1) return 0;
    if (gal_pass_swr()) { g_disp_why[0]++; return 0; }
    int ok = 1;
    for (int i = 0; i < pg->nargs && ok; i++) {
        const gal_arg *a = &pg->args[i]; int array = a->count > 1 || a->set >= 4;
        for (uint32_t j = 0; j < a->count && ok; j++) {
            uint32_t b = a->binding + (array ? 0 : j);
            if (a->kind == GAL_ARG_TEX || a->kind == GAL_ARG_IMG || a->kind == GAL_ARG_BUFTEX || a->kind == GAL_ARG_BUFIMG) {
                uint32_t tid = array ? arr_tex(a->binding, a->set, j, 0) : bound_tex(a->kind, b);
                gal_tex *t = tid ? gal_tex_get(tid) : NULL; if (!t) continue;
                if (t->storage.buf) { int w = gal_buf_prepass_ok(t->storage.buf, t->storage.offset, t->storage.size, a->kind == GAL_ARG_BUFIMG, 1); ok = w != 2; if (w == 2) g_disp_why[5]++; }
                else if (gal_pass_is_attachment(t->root)) { ok = 0; g_disp_why[2]++; }
                // 写图像：贴图不换块，本遍里用过的（采样 / 图像）挪到遍前会被更早的绘制读到写后的值；本遍没用过的照挪
                else if (a->kind != GAL_ARG_TEX && gal_pass_tex_used(t->root)) { ok = 0; g_disp_why[3]++; }
            } else if (a->kind == GAL_ARG_SSBO) {
                const nxgal_buf_range *r = b < GS_MAX_BUF ? &g_gs.ssbo[b] : NULL;
                if (r && r->buf) { int w = gal_buf_prepass_ok(r->buf, r->offset, r->size, r->write != 0, r->write != 0); ok = w != 2; if (w == 2) g_disp_why[5]++; }
            }
        }
    }
    return ok;
}
NXGAL_API void nxgal_dispatch(int32_t x, int32_t y, int32_t z) { GAL_API_LOCK();
    GP_SCOPE(GP_DRAW);
    if (x <= 0 || y <= 0 || z <= 0) return;
    if (!draw_init()) return;
    int pend = 0; const gal_prog *pg = gal_prog_get_draw(g_gs.prog, &pend);
    if (pend) { gal_first_skip_note(g_gs.prog, "派发"); return; }
    if (!pg || !pg->is_compute || !pg->fn[0] || pg->status != 0) { GRED_ONCE("派发时没有有效的计算程序（程序 %u）", g_gs.prog); return; }
    id<MTLComputePipelineState> p = gal_fn_compute_pso(pg->fn[0], pg->hash);
    if (!p) return;
    // 线程组超管线上限（10-24 图形接口盘点静默 4）：Vulkan 里本地尺寸只受设备上限约束（Switch 程序 ≤ 1024，设备上限都够），Metal 按管线给上限，
    //   寄存器压满的程序可能 < 1024；按超限的尺寸派发是未定义行为。报红跳过（不改管线描述符：改了出包归档里的计算管线就对不上键、首遇现编）
    { MTLSize tg0 = pg->threadgroup; NSUInteger tt = (tg0.width ? tg0.width : 1) * (tg0.height ? tg0.height : 1) * (tg0.depth ? tg0.depth : 1);
      if (tt > p.maxTotalThreadsPerThreadgroup) { GRED_ONCE("计算着色器 %016llx 线程组 %lu 个线程超过管线上限 %lu（寄存器压力），跳过派发", (unsigned long long)pg->hash, (unsigned long)tt, (unsigned long)p.maxTotalThreadsPerThreadgroup); return; } }
    SW_SCOPE(SW_DISPATCH, sw_dispatch_dep(pg));   // 调度测算：派发挪到遍外是否真有依赖
    // 遍内派发挪到当前遍之前（帧级调度，帧率能耗线 10-21；NXGAL_PREPASS_OFF=1 退回切遍）：判过 dispatch_hoistable 就录进遍前段，本遍照常接着画；
    // 遍前段没开（本帧前两帧没人要过）就记一笔「想要」，这次照旧切遍。用到的缓冲有待拷回镜像的，拷回先录进遍前段（之后 preflush 无事可做、不切遍）；
    // 落实挂起清屏收了遍（派发要读被清的贴图，得排在清屏之后）就照旧录进在录流
    int pre = 0;
    if (dispatch_hoistable(pg)) {
        gal_prepass_want();
        // 只拷回读不到镜像的用法（会写、或经贴图缓冲读）：只读存储缓冲取址时就绑镜像，不必拷回
        if (gal_prepass_enc()) { pre = 1; sw_each(pg, ^(int kind, id<MTLTexture> root, uint32_t buf, int bw) { (void)root; if (buf && (bw || kind == GAL_ARG_BUFTEX)) gal_buf_prepass_flush(buf); }); }
        else g_disp_why[4]++;
    }
    preflush_nonmirror(pg);
    clears_touch(pg);
    if (PSTAT_ON()) pstat_samples(pg, 1);
    id<MTL4ComputeCommandEncoder> e = nil;
    { int k; gal_cur_enc(&k); if (pre && k == 1) e = gal_prepass_enc(); }
    g_disp_n[e != nil]++;
    if (!e) e = gal_cmp_enc();
    if (!e) return;
    [e setComputePipelineState:p];
    // 挪到遍前段的派发：绑定时缓冲用法只登记本次提交、不算本遍（gal_buf.m g_buf_prepass_bind）
    g_buf_prepass_bind = pre && e != nil;
    int bound = bind_sets(pg, 1); g_buf_prepass_bind = 0;
    if (!bound) return;
    if (pg->cs_spill) {
        // 共享内存溢出段（gal_prog.m spill_msl）：每线程组一段，本次派发用完即弃
        uint64_t n = (uint64_t)x * (uint64_t)y * (uint64_t)z * pg->cs_spill, gpu = 0;
        if (n > (256u << 20)) { GRED_ONCE("计算着色器 %016llx 共享内存溢出段 %llu 字节超过 256 MB，跳过派发", (unsigned long long)pg->hash, (unsigned long long)n); return; }
        // 取不到（gal_transient 已报红）：跳过本次派发，参数表下次重填
        if (!gal_transient((uint32_t)n, 16, &gpu)) { g_gs.dirty |= GS_ARGS; return; }
        [g_ct setAddress:gpu atIndex:GAL_SPILL_SLOT];
    }
    if (pg->border_stages & 1u) { uint64_t bt; if (!gal_border_table((gal_prog *)pg, &bt)) { g_gs.dirty |= GS_ARGS; return; } [g_ct setAddress:bt atIndex:GAL_BORDER_SLOT]; }
    border_unrewritten(pg);
    [e setArgumentTable:g_ct];
    MTLSize tg = pg->threadgroup; if (!tg.width) tg = MTLSizeMake(1, 1, 1);
    [e dispatchThreadgroups:MTLSizeMake(x, y, z) threadsPerThreadgroup:tg];
    gal_hang_note(2, pg, x * y * z);
    g_gs.dirty |= GS_ARGS;
}
void gal_draw_reset_session(void) {
    for (int st = 0; st < 6; st++) for (int s = 0; s < GAL_MAX_SETS; s++) {
        free(g_setc[st][s].sh); g_setc[st][s] = (set_cache){0};
    }
    g_draw_pg = NULL; g_cur_pso = nil; g_cur_pso_enc = nil;
    g_vt = g_ft = g_ct = nil;
    if (g_zero) gal_res_remove(g_zero); g_zero = nil; // draw_init recreates tables
    memset(g_tab_addr, 0, sizeof g_tab_addr); memset(g_vb_over, 0, sizeof g_vb_over); memset(g_vb_over_stride, 0, sizeof g_vb_over_stride);
    g_applied_serial = ~0u; g_color_round_mask = ~0u; g_in_bind = 0;
    g_nics[0] = g_nics[1] = g_nicp = 0; g_ics_frame[0] = g_ics_frame[1] = UINT64_MAX;
    g_nicj = 0; g_stat_draws = g_stat_skips = 0;
}
GAL_MTL4_ZONE_END

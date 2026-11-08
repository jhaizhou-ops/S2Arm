// 第 5 / 6 块共享：GAL 管线状态记录（gal_state.m）与绘制（gal_draw.m）之间的接口。
#pragma once
#import "gal_internal.h"
GAL_MTL4_ZONE_BEGIN   // 本头自己的声明（gal_internal.h）

// 绑定号上限：Ryujinx 的绑定号跨阶段累计且有保留段（贴图从 128 起，10-18 动森真局 128 号贴图被 128 格的表静默丢掉），统一开 1024 格，越界报红
#define GS_MAX_BUF 1024
#define GS_MAX_TEX 1024
#define GS_MAX_IMG 1024
#define GS_MAX_ARR 1024
#define GAL_ZERO_VB 25          // 零属性（is_zero / 着色器读但没设置的属性）用的常量缓冲槽（参数表后端内部段 24–29）
enum { GS_PSO = 1, GS_DSS = 2, GS_DYN = 4, GS_VB = 8, GS_ARGS = 16 };

typedef struct {
    uint32_t dirty;
    uint32_t prog;
    nxgal_blend blend[8]; uint32_t mask[8];
    int32_t bias_en; float bias_factor, bias_units, bias_clamp;
    int32_t depth_clamp;
    nxgal_depth_test depth; nxgal_stencil stencil;
    int32_t cull_en, cull_face, front_face, poly;
    int32_t a2c, a2one, restart, topology, discard;
    nxgal_viewport vp[16]; int32_t nvp;
    nxgal_vattr attr[32]; int32_t nattr;
    nxgal_vbuf vb[16]; int32_t nvb;
    nxgal_buf_range ib; int32_t ib_type;
    int32_t patch_vertices; float patch_outer[4], patch_inner[2];   // SetPatchParameters（第 8 块）
    nxgal_buf_range ubo[GS_MAX_BUF], ssbo[GS_MAX_BUF];
    uint32_t tex[GS_MAX_TEX], smp[GS_MAX_TEX], img[GS_MAX_IMG], arr[GS_MAX_ARR], arr_set[GAL_MAX_SETS];
    // 贴图缓冲 / 图像缓冲另一张表（同 Ryujinx Vulkan DescriptorSetUpdater _bufferTextureRefs / _bufferImageRefs）：同一绑定号上普通贴图与贴图缓冲互不覆盖。
    //   10-22 八方2 酒馆全暗：色调映射顶点着色器绑定 0 的 1×1 曝光贴图被同绑定号的贴图缓冲顶掉，曝光读成 0
    uint32_t buftex[GS_MAX_TEX], bufimg[GS_MAX_IMG];
    // 绑定代数（参数缓冲按集复用用）：该绑定号的值真变了才记成 ++g_bind_gen
    uint32_t ubo_gen[GS_MAX_BUF], ssbo_gen[GS_MAX_BUF], tex_gen[GS_MAX_TEX], img_gen[GS_MAX_IMG], buftex_gen[GS_MAX_TEX], bufimg_gen[GS_MAX_IMG];
} gal_state;
extern gal_state g_gs;
extern uint32_t g_bind_gen;   // 绑定代数计数
extern uint32_t g_obj_gen;    // 对象代数：删 / 建缓冲、贴图、采样器，换贴图缓冲挂载，改贴图数组时加一（同号换对象，地址 / 资源号会变）

void gal_state_init(void);
MTLCompareFunction gal_cmp(int32_t op);
MTLPrimitiveType gal_prim(int32_t topology, int *ok);
id<MTLRenderPipelineState> gal_pso_get(const gal_prog *pg, uint8_t *color_round_mask, uint64_t *lop_addr);   // *lop_addr：逻辑运算入口管线的 S2ALop 参数地址（0 = 不用）
int gal_pso_pending(void);   // 上次 gal_pso_get 返回空是因为基础管线异步现建中（调用方跳过绘制并计数，gal_state.m）
id<MTLDepthStencilState> gal_dss_get(int has_depth, int has_stencil);
void gal_state_apply_dynamic(id<MTL4RenderCommandEncoder> e, int rt_w, int rt_h, int has_depth, int has_stencil);
int gal_state_cull_all(void);
int gal_pso_count(void);

// gal_pass.m 提供：当前渲染目标的颜色格式（MTLPixelFormat，0 = 无）/ 采样数 / 尺寸 / 有无深度模板
void gal_pass_formats(uint32_t cf[8], uint32_t *samples);
void gal_pass_ds_formats(uint32_t *depth, uint32_t *stencil);
void gal_pass_info(int *w, int *h, int *has_depth, int *has_stencil);
// 无附件目标组：视口超出开着的通道范围时收遍并按视口重开尺寸（返回 1 = 收过遍）；有附件时什么都不做
int gal_pass_targetless_fit(void);

// 计数模块（gal_cnt.m）的钩子：每次绘制前调用（设可见性结果模式）。gal_draw.m 给弱定义空实现，gal_cnt.m 提供强定义
void gal_cnt_on_draw(id<MTL4RenderCommandEncoder> e);

// ---- 第 8 块（曲面细分，gal_tess.m 用 gal_draw.m 的内部件）----
id gal_draw_table(int which);                                   // 0 顶点 1 片元 2 计算参数表
int gal_bind_stage(const gal_prog *pg, int st, id table);      // 把程序某阶段的各集参数缓冲写进给定参数表；0 = 临时内存取不到
int gal_vpull_fill(const gal_prog *pg, uint64_t *gpu);          // 顶点自取取数表（不绑）；0 = 临时内存取不到
void gal_draw_preflush(const gal_prog *pg);                     // 开编码器前：顶点重排 / 镜像拷回 / 挂起清屏落实（会切通道）
id gal_prepare_draw(const gal_prog **out_pg);                   // 开渲染编码器并应用全部状态（同普通绘制）
id<MTLComputePipelineState> gal_fn_compute_pso(id fn, uint64_t key);    // 着色器函数 → 计算管线（按键缓存）
id<MTLComputePipelineState> gal_helper_pso(int lib, NSString *name);   // 辅助库函数 → 计算管线
void gal_tess_draw(int indexed, uint32_t count, uint32_t inst, uint32_t first, int32_t base_vertex, uint32_t first_inst);
GAL_MTL4_ZONE_END

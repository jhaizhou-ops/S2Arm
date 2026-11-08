// GAL Metal 后端内部共享（各块文件都包含）。约定见 gal_abi.h 与 设计.md。
#pragma once
#import <Metal/Metal.h>
#include "gal_colorround.h"   // 颜色出口改写的槽号与原型（纯 C，在可用性区之外声明，gal_colorround.c 单独编时同一份）
#include "gal_log.h"          // GLOG / GRED_ONCE（纯 C，gal_spvx.c 单独编时同一份，#783）
#include "gal_spvx.h"         // SPIR-V 加固改写的绑定号、计数枚举与原型（纯 C，gal_spvx.c 单独编时同一份，#783）
#include "gal_spill.h"        // 共享内存溢出改写的上限 GAL_TG_MEM_MAX 与原型（纯 C，gal_spill.c 单独编时同一份，#783）
#include "gal_tess.h"         // 曲面细分接口的常量、规范布局与翻译段原型（纯 C，在可用性区之外声明，Windows / Linux 出包机单独编 gal_tessxc.c 时同一份）
// Metal 4 可用性区（10-19 jhz：下限 iOS 17 / macOS 14，Metal 4 为主路径、Metal 3 兼容路径另做，见 gal_be.h）：区内所有函数 / 方法 / 全局变量 / 结构体
// 都标「macOS 26 / iOS 26 起可用」，编译器据此核查；运行时只有 nxgal_init 的 @available 判过才会走进来。
// 用法：每个 .m 在自己的 #import / #include 段之后 GAL_MTL4_ZONE_BEGIN、文件末 GAL_MTL4_ZONE_END；区内不许再引入系统头（标注会落到系统声明上）。
// 新代码不许再往区里加 MTL4 调用：走 gal_be.h（门禁按 MTL4 出现处数棘轮，只减不增）
#define GAL_MTL4_ZONE_BEGIN _Pragma("clang attribute push (__attribute__((availability(macos, introduced=26.0), availability(ios, introduced=26.0))), apply_to = any(function, objc_method, variable(is_global), record, type_alias))")
#define GAL_MTL4_ZONE_END _Pragma("clang attribute pop")
// Metal 3 可用性区（#117 段 B）：Metal 3 兼容路径（macOS 15 / iOS 18 起）真的会执行的代码必须按这个下限编，不能挂在 26 门槛后面。
//   和上面那对 26 区一样是 clang attribute push / pop、成对使用，区别只在门槛：区内的函数 / 记录在 M3 侧能直接引用，
//   代价是编译器按 15 / 18 核查——区内碰 MTL4 专有接口的地方必须自己写 @available 判，写不出来就说明那段不该在 M3 侧。
//   不要和 26 区嵌套（push 是叠加不是遮蔽：套着写同一份声明会同时带 15 与 26 两条标注，-Wavailability 直接报不一致）；
//   文件里既有 M3 又有 26 代码时，一段收、另一段起，先后分开。
//   下限取 gal_be.h:23–24 的既有值（macOS 15 / iOS 18），不另立数字。
#define GAL_M3_ZONE_BEGIN _Pragma("clang attribute push (__attribute__((availability(macos, introduced=15.0), availability(ios, introduced=18.0))), apply_to = any(function, objc_method, variable(is_global), record, type_alias))")
#define GAL_M3_ZONE_END _Pragma("clang attribute pop")
GAL_MTL4_ZONE_BEGIN   // 本头自己的声明
#include <stdio.h>
#include "gal_abi.h"
#include "gal_be.h"

// 扩表（gal_core.m；11-01 审计 P1-44）：把 p 重分配成 n 个 elem 字节的元素，返回新指针；失败（含 n × elem 溢出）返回 NULL、p 原样有效、报红（前 8 次）。
//   调用方只在成功后写回表指针和容量：原先「先改容量、再 p = realloc(p, …)、再清零 / 写入」，失败时表指针成空、容量已加倍，下一行往「空指针 + 偏移」写（段错误），旧表也丢了
void *gal_grow(void *p, size_t n, size_t elem, const char *what);

// ---------- 设备与提交（gal_core.m）----------
// 设备两边都有（Metal 3 的动态库 / 老编码器 / 老管线也用它）：单条显式标 M3 下限（同 gal_be.h:23 的做法），
// 其余全局（g_gq / g_gcb / g_gres / g_gcomp）是 Metal 4 专有，留在本头缺省的 26 区里
extern id<MTLDevice> g_gdev __attribute__((availability(macos, introduced=15.0), availability(ios, introduced=18.0)));
extern id<MTL4CommandQueue> g_gq;            // Metal 4 主队列（选到 GAL_BE_MTL3 时为 nil）
extern id<MTLCommandQueue> g_cq3;            // Metal 3 兼容路径的主队列（选到 GAL_BE_MTL4 时为 nil；见 gal_be.h「选路径 / 驻留」）
extern id<MTL4CommandBuffer> g_gcb;           // 当前在录的命令缓冲（nil = 还没开）
extern id<MTLResidencySet> g_gres;
extern id<MTL4Compiler> g_gcomp;               // 运行时编辅助着色器 / 管线用
void gal_cb_begin(void);                        // 没开就开一条命令缓冲
uint64_t gal_commit(void);                      // 结束编码、提交；返回本次提交的栅栏值（没有在录的 = 返回最后一次的栅栏值）
void gal_wait(uint64_t fence);                  // 等这个栅栏值完成
int gal_wait_fence_timeout(uint64_t fence, int ms);   // 不持 API 锁等主栅栏（计数线程用）；1 = 已完成
void gal_cnt_on_cb_done(uint64_t fence, double gpu_end_s);
void gal_rtd_frame_end(void);   // 诊断 NXGAL_RT_DIMS：每帧出图时结算最大渲染目标尺寸（gal_pass.m）   // 提交反馈：记这次提交的 GPU 结束时刻（时间戳计数，gal_cnt.m）
uint64_t gal_done(void);                        // 已完成的栅栏值
void gal_finish(void);                          // 提交并等全部完成（读回前用）
void gal_gate_enter(void);                      // 后台闸门（gal_core.m）：每次向 GPU 队列提交前进、提交完出；关闸时在 enter 里等
void gal_gate_leave(void);
int gal_gate_held(void);                       // 此刻是否已要求关闸（只读，诊断用：出图线程取画布慢 / 取不到时记进日志）
int gal_present_drain(int timeout_ms);          // 等出图队列已提交的做完（gal_present.m）；1 = 做完 / 没有出图队列
const char *gal_mem_note(void);               // 分配失败时附的内存读数：进程实占 / 系统可用余量（iOS）/ Metal 已分配（线程局部缓冲，下次调用前有效）
void gal_res_add(id<MTLAllocation> a);          // 进驻留集（下次提交前统一 commit）
void gal_res_remove(id<MTLAllocation> a);
// 延后释放：对象在当前在录命令（含已提交未完成的）用完前不能放；挂到下次提交的栅栏上，完成后再放（也移出驻留集）
void gal_release_later(id obj, int residency);

// 临时数据（每次提交后随栅栏回收的共享内存）：返回 CPU 指针，*gpu = GPU 地址。用于常量、清屏颜色等小块数据
// 建块失败返回 NULL（*gpu = 0，已报红）：调用方必须判空、跳过本次命令
void *gal_transient(uint32_t size, uint32_t align, uint64_t *gpu);
uint64_t gal_transient_gpu(uint32_t size, uint32_t align);   // 只给 GPU 用的临时内存（私有存储，不占进程地址）：返回 GPU 地址，0 = 取不到（已报红）
// 单测故障注入：非 0 时换块当作建块失败
extern int gal_tr_test_fail;
// 单测故障注入：非 0 时下列建缓冲点当作 newBufferWithLength 返回 nil（重排缓存、暂存块、绘制零缓冲、越界 / 循环计数格、可见性结果缓冲、贴图原始拷贝 / 深度模板打包中转）
extern int gal_newbuf_test_fail;
id<MTL4ComputeCommandEncoder> gal_preload_enc(void);   // 预载拷贝编码器：提交时排在在录命令缓冲之前（只给「本次提交还没用到的区间」写）
#define GAL_MSL_NP "\n//@@GAL_MSL_NP@@\n"   // MSL 里主份与无点大小变体的分隔（两个编译单元）
uint64_t gal_cb_id(void);
extern uint32_t g_obj_gen;   // 对象代数（见 gal_draw_internal.h）      // 在录命令缓冲提交后的栅栏值（本次提交的标识）
uint64_t gal_done_fence(void); // GPU 已完成的栅栏值

// ---------- 编码器（gal_core.m）：同一时刻至多一个开着；编码器之间全序屏障 ----------
// 渲染编码器由 gal_pass.m 按当前渲染目标开（gal_render_enc），这里只负责登记 / 屏障
id<MTL4RenderCommandEncoder> gal_render_begin_desc(MTL4RenderPassDescriptor *d);
id<MTL4ComputeCommandEncoder> gal_blit_enc(void);    // 拷贝编码器（Metal 4 拷贝 / 计算合一；Metal 3 是 MTLBlitCommandEncoder，第二条起换新编码器）；同一编码器内相邻两条之间也加屏障
id gal_cmp_enc(void);                                  // 计算派发用的编码器：Metal 4 = gal_blit_enc；Metal 3 = MTLComputeCommandEncoder（参数绑定 M3-7 合入前报红返回 nil）
id gal_preload_cmp_enc(void);                          // 预载里的计算派发：Metal 4 = gal_preload_enc；Metal 3 报红返回 nil（同上）
int gal_m3_unbound(int what);                          // Metal 3 下参数绑定（M3-7）未合入：报红并返回 1 = 本次绘制 / 派发跳过（what：0 绘制 1 派发 2 遍内清屏 3 辅助绘制）；Metal 4 返回 0
id gal_cur_enc(int *kind);
id gal_prepass_enc(void);                             // 当前渲染遍的遍前计算编码器（帧级调度的插入点，gal_core.m g_segs）；没有返回 nil
void gal_prepass_want(void);
uint64_t gal_pass_serial(void);
int gal_sampler_lod(uint32_t id, float *min_lod, float *lod_bias);   // 采样器的最小 LOD 与 LOD 偏移（gal_tex.m）；无效编号返回 0
id gal_prepass_render(id d);   // 遍前段里开渲染编码器（落实挂起清屏用）；遍前段不可用返回 nil（gal_core.m）
void gal_pass_tex_note(id<MTLTexture> root, int write);          // 本遍绘制用到这张贴图（写参数时打戳，gal_pass.m）
int gal_pass_tex_written(id<MTLTexture> root);        // 本遍写过（当前附件 / 当图像绑过；戳表溢出一律按写过）
int gal_pass_tex_used(id<MTLTexture> root);           // 本遍里用过（采样 / 图像 / 当前附件；戳表溢出时一律按用过）                       // 渲染遍序号（开遍 +1，gal_core.m）                          // 本帧有遍内操作想挪到遍前（之后两帧开遍分段，留遍前段位置）                            // kind：0 无 1 渲染 2 拷贝计算
int gal_on_rec_thread(void);                          // 调用线程就是在录命令缓冲的线程（或没有在录的）
id gal_readback_enc(void);  // 读回用的拷贝编码器：渲染线程 = gal_blit_enc；其他线程 = 后台读回队列上一次性命令缓冲的拷贝编码器（MTLBlitCommandEncoder，拷贝选择子两者相同）
void gal_readback_finish(void);                       // 读回编码完：录制线程 = gal_finish；其他线程 = 提交一次性命令缓冲并等它
uint64_t gal_committed_fence(void);                   // 最后一次提交的栅栏值
void gal_enc_end(void);                               // 结束当前编码器（任何类型）
extern void (*gal_on_enc_end)(void);                  // 渲染编码器结束时的回调（gal_pass.m 置位：标记通道已关）

// ---------- 贴图表（gal_tex.m）----------
// tex = 底层（恒等交换通道）：渲染目标 / 图像（着色器写）/ 拷贝用。Metal 规定带交换通道的贴图不能当渲染目标或被着色器写（调试层断言），
//   所以交换通道只放在 smp 上（同 Vulkan 后端 _imageView 与 _imageViewIdentity 分开）。
// smp = 采样视图：GAL 交换通道 + 16 位打包格式的分量修正 + 深度模板按 ds_mode 选平面；绑定采样贴图（SetTextureAndSampler / 贴图数组）一律用它。
// gen：tex / smp 换过就递增（贴图缓冲 SetStorage 重挂）；绑定处与 gal_tarr.serial 一起据此判断要不要重写参数缓冲。
// storage：贴图缓冲（Target.TextureBuffer）当前挂的缓冲区间；tex 由该缓冲直接建（共用内存）。
// root / base_layer / base_level：视图一律直接基于底层存储贴图建（Metal「视图的视图」开 GPU 校验时读出全 0），级 / 层偏移逐层累加；底层贴图 root = tex、偏移 0。
typedef struct { id<MTLTexture> tex; nxgal_tex_info info; uint32_t parent; int live; id<MTLTexture> smp; uint32_t gen; nxgal_buf_range storage;
                 id<MTLTexture> root; int32_t base_layer, base_level; uint8_t uw_written, uw_rep;
                 // （10-23 原生层线）tex / smp 的 gpuResourceID 缓存：绑定热路径直接读，不取强引用、不发消息；tex / smp 一改就调 gal_tex_rid 刷新（0 = 没有 / 没刷，用的地方退回现取）
                 uint64_t rid_tex, rid_smp; } gal_tex;
void gal_tex_rid(gal_tex *t);
// 绘制固定开销四处削减（临时内存地址缓存 / 管线表 8 字节哈希 / 贴图资源号缓存 / 已用区间整段覆盖快路径）的总开关：NXGAL_DRAW_FIXED=0 退回旧路径（同包真机 A/B 用），缺省开
static inline int gal_draw_fixed(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_DRAW_FIXED"); v = !(e && *e == '0'); } return v; }
gal_tex *gal_tex_get(uint32_t id);              // 编号无效返回 NULL
// 诊断「未写先采样」，缺省常开（NXGAL_UNWRITTEN_SAMPLE=0 关；总指挥 10-23：九款正式局常开、哪局自然出现黑块现场就在哪局；dev_run.sh 把计数并进结论）（帧率能耗线 10-23，八方2 地面黑块）：贴图（按底层存储算，视图共用）新建后从没被写过
//（上传 / 拷贝进 / 当附件 / 图像写 / 挂缓冲）就被绑去采样，每张底层只报第一次，另计总次数。关时每次只多一次布尔判断
extern int g_uw_on;
void gal_uw_write(uint32_t tid);
void gal_uw_sample(uint32_t tid, const char *where);
// GAL Format → Metal 像素格式；没映射返回 MTLPixelFormatInvalid
MTLPixelFormat gal_fmt_mtl(int32_t gal_format);
// 分量类型：0 浮点（含 unorm / snorm）1 无符号整数 2 有符号整数
int gal_fmt_ctype(int32_t gal_format);
int gal_fmt_is_ds(int32_t gal_format);          // 1 深度 2 模板 3 深度模板 0 颜色

// ---------- 渲染通道（gal_pass.m）----------
id<MTL4RenderCommandEncoder> gal_render_enc(void);   // 按当前渲染目标开 / 续用渲染编码器
void gal_pass_texbar_arm(void);                         // TextureBarrier 挂起（渲染通道开着时；通道结束即清）
void gal_pass_membar_arm(void);                         // Barrier / CommandBufferBarrier 挂起（同上，gal_pass.m）
int gal_pass_membar_split(int draw_swr);                // 挂起的内存屏障要在这次绘制前拆遍（draw_swr = 这次绘制有存储写）
void gal_pass_note_swr(void);
int gal_pass_swr(void);                                 // 开着的遍里已有存储写                           // 本遍有了存储写
int gal_pass_texbar_armed(void);
// 挂在贴图上的整附件清屏（gal_pass.m g_pc）：touch = 底层是 root 的落实（绘制 / 派发开编码器前，对要采样 / 当图像用的贴图调）
void gal_pass_close(void);
void gal_pass_rt_dirty(void);   // 贴图建 / 放 / 换存储后调：通道尺寸缓存作废   // 只收渲染通道，不落实挂起清屏（贴图拷贝内部用；入口已按涉及的贴图 touch 过）
void gal_pass_clears_touch(id<MTLTexture> root);
int gal_pass_clears_any(void);
int gal_pass_is_attachment(id<MTLTexture> root);       // root 是当前通道某个颜色 / 深度附件的底层存储
int gal_pass_is_color_attachment(id<MTLTexture> root); // root 是当前通道某个颜色附件（不含深度模板）
void gal_pass_ds_written(void);                         // 本遍写了深度模板（绘制 / 遍内清屏）
int gal_pass_ds_mem(void);                              // 深度模板内存那份 = 片上（开遍载入、本遍没写过）：屏障后采样深度可不收遍
// 两遍合一（NXGAL_PASS_MERGE）：root 是开着的遍里被换组藏起来的颜色附件（还在片上、没存回；本遍里要采样它须先收遍）
int gal_pass_hidden_hit(id<MTLTexture> root);
int gal_pass_hidden_any(void);
uint32_t gal_pass_hidden_mask(void);
// 渲染编码器状态代数：新开渲染编码器、或辅助绘制（清屏等）改动了管线 / 视口 / 剪裁 / 深度模板状态时递增。
// 绘制模块记下上次应用状态时的代数，不等就全部重设
extern uint32_t g_genc_serial;
extern nxgal_rect g_scissors[16]; extern int g_nscissors; extern uint32_t g_scissor_serial;   // SetScissors 原样（第 0 个兼作清屏剪裁）

// ---------- 缓冲（gal_buf.m，第 2 块）----------
// 编号 → Metal 缓冲与起点偏移（零拷贝缓冲可能落在分窗里的某个 MTLBuffer 中间）；无效返回 nil
id<MTLBuffer> gal_buf_mtl(uint32_t buf, int32_t offset, uint64_t *mtl_offset);
uint64_t gal_buf_gpu(uint32_t buf, int32_t offset);   // GPU 地址（参数缓冲 / 参数表直接用）；无效返回 0
int32_t gal_buf_size(uint32_t buf);
// 带长度的版本（第 2 块追加）：len = 本次要用到的字节数（≤ 0 = 到缓冲尾）。分窗的宿主映射缓冲按 [offset, offset + len) 取恰好覆盖它的窗口；
// 不带长度的两个按「到缓冲尾」取（正确但可能多钉页）。凡交出 Metal 缓冲 / GPU 地址的调用都把该缓冲记为「GPU 碰过」（之后 SetData 走按序拷贝）
id<MTLBuffer> gal_buf_mtl_range(uint32_t buf, int32_t offset, int32_t len, uint64_t *mtl_offset);
uint64_t gal_buf_gpu_range(uint32_t buf, int32_t offset, int32_t len);
uint64_t gal_buf_read_gpu(uint32_t buf, int32_t offset, int32_t len);   // 只读绑定（常量 / 顶点 / 索引）取址：有未拷回的镜像数据就给镜像
const uint8_t *gal_buf_cpu_view(uint32_t bid, int32_t offset, int32_t len);   // CPU 侧此刻的逻辑内容（拿不准返回 NULL），见 gal_buf.m
void gal_buf_preflush(uint32_t buf);
void gal_buf_gpu_write(uint32_t buf, int32_t offset, int32_t len);   // 本次绘制 / 派发会写它的 [offset, offset + len)（len ≤ 0 = 到末尾）：拷回镜像、记在录流 GPU 写（gal_buf.m）
void gal_icnt_batch_flush(void);   // 提交时：预载里攒的间接计数整理一个派发做完（gal_draw.m）
void gal_buf_note_use(uint32_t buf, int32_t offset, int32_t len);
void gal_upload_va_note(char *o, size_t n);   // 上传租约地址账（gal_tex.m，拼进 gal_buf_va_note）
int gal_buf_prepass_ok(uint32_t buf, int32_t offset, int32_t len, int write, int flush);   // 这次用法能否挪到遍前段：0 能 1 能但要先拷回镜像 2 不能（gal_buf.m）
void gal_buf_prepass_flush(uint32_t buf);           // 挪到遍前段的命令用到的缓冲：待拷回镜像 / 暂存补丁的拷回录进遍前段（gal_prepass_enc）
extern int g_buf_prepass_bind;                      // 挪到遍前段的命令绑定期间置 1：缓冲用法不算本遍（gal_buf.m）   // 这次用法能否挪到遍前段：0 能 1 有待拷回镜像 2 要写的区间本遍已用（gal_buf.m）   // 本次绘制 / 派发经贴图缓冲用到这段：登记本次提交已用区间（gal_buf.m）
// 作废与（偏移, 长度）相交的重排缓存（fresh 后没派发成转换时）
void gal_buf_restride_drop(uint32_t buf, int32_t off, int32_t size);
int gal_buf_preload_readable(uint32_t buf, int32_t off, int32_t len);
uint32_t gal_buf_wser(uint32_t buf); uint32_t gal_buf_wser_now(void);   // 缓冲最近一次写的全局写序号 / 当前写序号（gal_buf.m；开遍预整理间接计数用）
int gal_buf_gpu_written(uint32_t buf);   // 本命令缓冲的在录流里有 GPU 写过它（gal_buf.m，诊断）   // 预载里读这段与此刻在录流里读到的相同（gal_buf.m）
uint64_t gal_buf_restride(uint32_t buf, int32_t off, int32_t size, int32_t stride, uint32_t out_len, int *fresh);   // 跨度转换结果（缓存），fresh = 要派发转换   // 非镜像用到前（开渲染 / 计算编码器之前）：拷回镜像数据、丢影子
void gal_buf_commit_flush(void);       // 提交前：全部镜像数据拷回真缓冲
void gal_draw_rebind_buffers(void);    // 镜像改动：顶点缓冲 / 参数缓冲下次绘制重绑
int gal_in_bind(void);
uint32_t gal_state_color_mask(int i);   // 当前颜色写掩码（第 i 槽）
void gal_pass_masks_changed(void);     // 写掩码变了：有重复绑定的渲染目标按掩码重新去重                 // 正在渲染编码器的绑定阶段（这时不能再开拷贝编码器）

// ---------- 采样器与贴图数组（gal_tex.m，第 3 块）----------
id<MTLSamplerState> gal_sampler_get(uint32_t smp);
typedef struct { uint32_t *tex; uint32_t *smp; int32_t size; int is_buffer, is_image, live; uint32_t serial; } gal_tarr;   // serial：内容改过就递增（绑定处据此重写参数缓冲）
gal_tarr *gal_tarr_get(uint32_t arr);
// 采样器描述翻译（nxgal_sampler_create 用；单测直接核字段）
MTLSamplerDescriptor *gal_sampler_desc(const nxgal_sampler_info *i);
// 原始字节视图格式：每像素 1/2/4/8/16 字节 → R8Uint / R16Uint / R32Uint / RG32Uint / RGBA32Uint；其他返回 Invalid
MTLPixelFormat gal_raw_uint_fmt(int bpp);

// ---------- 程序（gal_prog.m，第 4 块）----------
MTLCompileOptions *gal_msl_opts(void) __attribute__((availability(macos, introduced=15.0), availability(ios, introduced=18.0)));   // 翻译后着色器的编译选项（relaxed + preserveInvariance，#807）
// 参数缓冲布局：Ryujinx 的每个描述符集 = 一个参数缓冲，绑在该阶段参数表的 [[buffer(set)]]（SPIRV-Cross --msl-argument-buffers 缺省映射）。
// 参数缓冲内容（Metal 4 / 参数缓冲第 2 档，直接写 64 位值）：缓冲 = GPU 地址；贴图 / 采样器 = MTLResourceID；数组按元素连排。
// 绑定处（第 5/6 块）只按本表写值，不关心 SPIR-V。
enum { GAL_ARG_UBO = 0, GAL_ARG_SSBO = 1, GAL_ARG_TEX = 2, GAL_ARG_SMP = 3, GAL_ARG_BUFTEX = 6, GAL_ARG_IMG = 5, GAL_ARG_BUFIMG = 7 };   // = ResourceType（TextureAndSampler 拆成 TEX + SMP 两条）
typedef struct {
    uint8_t kind;          // GAL_ARG_*
    uint8_t set;           // 描述符集号
    uint16_t binding;      // Ryujinx 绑定号（SetUniformBuffers / SetTextureAndSampler 等的 binding）
    uint32_t offset;       // 在该集参数缓冲里的字节偏移
    uint32_t count;        // 数组长度（≥ 1）
    uint32_t stages;       // 用到它的阶段位（1 << ShaderStage）
    uint32_t slot;         // （第 4 块追加）存储缓冲：它在该集缓冲长度表里的下标；其余 0
} gal_arg;
// （第 4 块追加）该集的缓冲长度表（SPIRV-Cross spvBufferSizeConstants，只在着色器用到存储缓冲 .length() 时出现）：
//   参数缓冲 offset 处写一个 GPU 地址，指向 uint32 数组，数组[存储缓冲的 slot] = 该存储缓冲绑定的字节数。binding = 0xffff，count = 1
#define GAL_ARG_SIZES 8
// （10-19 越界改写追加；10-21 改存个数）常量缓冲长度表：gal_spvx.m 在用到常量缓冲的集里新增一个只读存储缓冲（绑定号 GAL_UBOLEN_BINDING），
//   参数缓冲 offset 处写一个 GPU 地址，指向 uint32 数组，数组[常量缓冲绑定号] = 该常量缓冲绑定的 vec4 个数（ceil(字节数/16)，封顶 4096；未绑定 = 0）；slot = 数组长度
#define GAL_ARG_UBOLEN 9   // 绑定号 GAL_UBOLEN_BINDING 在 gal_spvx.h
// （10-21 改常态）越界 / 循环到上限计数：gal_spvx.m 给每支加固过的着色器一个 16 字节计数格（集 0 绑定 GAL_OOBCNT_BINDING）：
//   [0] 有越界访问的调用数  [1] 越界类别位（GAL_OOB_* 按位或）  [2] 循环到上限的调用数  [3] 空
//   着色器里按调用累计（每类一个私有布尔「全在界内」+ 循环到上限布尔），收尾（返回 / 丢弃前）有一项为真才原子加。
//   开关在翻译期：计数开才插收尾与计数格，计数关（缺省）不插、零开销；离线库（gal_xc）出包一律计数关，计数开时不开离线库、全部现翻（全覆盖），持久缓存分 cnt/ 子目录。
//   不用函数常量：applegpu-nt 离线编渲染管线时带函数常量的片元一特化就报「cannot find private metadata」，整片归档失败（10-21，docs/坑记录.md）。
//   gal_draw.m 按着色器键给每支着色器一个格（参数缓冲 offset 处写格的 GPU 地址），nxgal_bounds_report 按键报数
#define GAL_ARG_OOBCNT 10   // 绑定号 GAL_OOBCNT_BINDING、类别位 GAL_OOB_* 与 gal_spvx_counting 在 gal_spvx.h
uint64_t gal_oob_cell(uint64_t shader_hash);
int32_t gal_bounds_report_delta(void);   // 中途报数：只报次数有增长的着色器（gal_present.m 每 600 次出图）
// 线程时间约束（实时）声明（gal_rt.m，缺省关 NXGAL_RT=1）：每帧调 gal_rt_tick(帧周期毫秒)，按本线程每帧 CPU 时间自适应声明计算量
#define GAL_RT_WIN 120
typedef struct { uint64_t declares, spike_windows; double last_comp_ms; } gal_rt_stat_t;   // spike_windows：峰值超封顶、跳过重声明的窗口数
extern gal_rt_stat_t g_rt_stat;
int gal_rt_on(void);
void gal_rt_tick(double period_ms);
double gal_rt_comp_from_window(const double win[GAL_RT_WIN], double period_ms);   // 纯函数：max(1.25 × p90, 1.1 × 峰值)，封顶 0.9 × 周期、下限 1 ms
// SPIR-V 加固改写（gal_spvx.c）的计数枚举、gal_spv_harden / gal_spvx_totals 与 GAL_MAX_SETS 在 gal_spvx.h（#783）
// 片元帧缓冲读取证明（gal_fbr.m，10-21）：证得出的程序才有，内含可改读颜色附件的绑定、y 符号、缩放因子条件、片元 SPIR-V 拷贝与变体缓存
typedef struct gal_fbr gal_fbr;
typedef struct {
    int live;
    int status;                                    // ProgramLinkStatus
    int is_compute;
    MTL4LibraryFunctionDescriptor *fn[6];          // 按 ShaderStage；nil = 无此阶段
    uint32_t set_size[GAL_MAX_SETS];               // 各集参数缓冲字节数（0 = 该集不用）
    uint32_t set_stages[GAL_MAX_SETS];             // 各集被哪些阶段引用（只给这些阶段的参数表设地址）
    gal_arg *args; int nargs;
    int32_t size_buf_index[6];                     // SPIRV-Cross 缓冲长度表（spvBufferSizeConstants）在该阶段参数表的下标，-1 = 不需要
    uint32_t vs_inputs;                            // 顶点着色器读的属性位置位
    uint8_t vs_input_ctype[32];                    // 各属性位置的分量类型：0 浮点 1 无符号 2 有符号（顶点描述符格式要与之相容）
    uint8_t fs_output_ctype[8];                    // 片元输出各位置分量类型（同上）；fs_outputs 位
    uint32_t fs_outputs;
    int fs_color_round;                           // 片元主入口支持逐绘制 half 量化；不支持时完整版与链接桩的 mask 均为 0
    MTLSize threadgroup;                           // 计算着色器线程组大小
    uint32_t cs_spill;                             // 计算着色器：共享内存溢出到设备内存的每线程组字节（0 = 没溢出；记录 GAL_REC_SPILL，字节数放记录的 io_mask）
    uint64_t hash;                                 // 内容哈希（管线缓存键用）
    // ---- 第 4 块追加（10-18）----
    // 绑定模型细化：每个阶段、每个集各一块参数缓冲（不同阶段不共用：各阶段结构体布局只由本阶段 SPIR-V 决定，离线库按单支着色器索引）。
    //   gal_arg.offset 是「该阶段该集参数缓冲」里的偏移；gal_arg.stages 有几位就要在几个阶段的缓冲里各写一次（同一资源在各阶段偏移不同时拆成多条 gal_arg）。
    //   set_size[s] = 各阶段该集大小的最大值（按它分配即可盖住任一阶段）；精确大小见 stage_set_size。
    //   缓冲长度表：着色器读的是参数缓冲里的那份（GAL_ARG_SIZES）；SPIRV-Cross 还会在入口签名里多留一个不读的 [[buffer(24)]] 参数，此时 size_buf_index[阶段] = 24，
    //   绑定处把同一张长度表也设到该阶段参数表 24 号（不读，但声明了就绑上，免校验层报未绑定）；否则 -1。
    uint32_t stage_set_size[6][GAL_MAX_SETS];      // [ShaderStage][集] 该阶段该集参数缓冲字节数（0 = 该阶段不用此集）
    uint64_t stage_hash[6];                        // 各阶段 SPIR-V 键（SHA-256 前 8 字节）；MSL 函数名 = "s" + 16 位十六进制键
    int32_t frag_output_map;                       // ShaderInfo.FragmentOutputMap 原样
    uint8_t vs_point_size;
    uint8_t vs_pulled;
    uint8_t vs_writes_layer;                       // 顶点着色器写层号（记录位 8）：管线必须指定拓扑类别                             // 顶点着色器自己取属性（记录位 4，gal_vpull.m）：管线不带顶点描述符，绘制时绑取数表
    uint8_t vs_layer_np;                           // 顶点着色器同时写层号与点大小：非点拓扑用无点大小变体 fn_np（见 gal_prog.m xc_shader）
    MTL4LibraryFunctionDescriptor *fn_np;                         // 顶点着色器写点大小：管线拓扑类不能是 Line / Triangle（Metal 规则），按 Unspecified 建
    // ---- 第 8 块追加（10-21 曲面细分，gal_tess.m）：fn[1] = 曲面前顶点计算核、fn[2] = TCS 计算核、fn[3] = TES 改写的顶点函数 ----
    uint8_t is_tess, tess_dom, tess_part, tess_cw, tess_point, tess_patch;   // 域 / 分区（GAL_TESS_*）/ 顺时针 / 点模式 / 有每片属性（取 TES 记录，TCS 须一致）
    uint8_t tess_ocp;                              // TCS 输出控制点数（OutputVertices）
    uint64_t oob_cell[6];                          // （10-21）各阶段越界计数格的 GPU 地址（gal_draw.m 首次写参数时按键查一次后缓存；0 = 还没查）
    // （10-21 画面·着色器线）片元帧缓冲读取证明（gal_fbr.m）；NULL = 证不出 / 没有 SPIR-V（load_binary）
    gal_fbr *fbr;
    // （10-21 画面·着色器线）自定义边框色（gal_border.m）：改写过采样的阶段位（记录位 GAL_REC_BORDER）；border_n = 边框表项数 + 1（0 = 还没算）
    uint8_t border_stages; uint16_t border_n;
    uint8_t drawid;   // 顶点着色器读绘制号（GAL_REC_DRAWID）：每次绘制往 GAL_DRAWID_SLOT 绑当前子绘制序号（普通绘制 0）
    // （10-21 画面·着色器线）宽线展开入口 s<键>_wl（gal_wline.m，记录位 GAL_REC_WLINE）；nil = 没有（宽线照 1 像素画并报红）
    id fn_wl;   // 函数描述（gal_be_fn_desc）
    // （10-24 画面·着色器线）逻辑运算入口 s<键>_lo（gal_logicop.m，记录位 GAL_REC_LOGICOP）：片元有整数颜色输出时才有；nil = 没有（整数目标逻辑运算照复制画并报红）
    id fn_lo;
    // （10-23 原生层线）各阶段各集用到的参数下标位图（第 i 位 = args[i]），bind_stage 判复用 / 增量写时只扫这些，不再每次绘制扫全部参数；
    //   ssa_ok：0 = 还没算（首次 bind_stage 懒算），1 = 可用，2 = 参数多于 64 个、照旧全扫
    uint64_t ssa_mask[6][GAL_MAX_SETS]; uint8_t ssa_ok;
} gal_prog;
// ---- 曲面细分（第 8 块，10-21：计算展开，gal_tess.m；设计见 曲面几何设计.md 第一节「实现」）----
#define GAL_XC_VT NXGAL_XC_VT
#define GAL_VT_SALT NXGAL_VT_SALT
// 翻译标志：片元帧缓冲读取变体，SPIRV-Cross 开 framebuffer_fetch_subpass（gal_fbr.m 改写的 SubpassData 输入附件 → [[color(n)]]）；出包 gal_xc 对 *.fbf.spv 给这一位（gal_abi.h）
#define GAL_XC_FBF NXGAL_XC_FBF
// 片元帧缓冲读取（gal_fbr.m）：建程序时证明（顶点 / 片元 SPIR-V 字数）；释放；变体构建（gal_prog.m）；计数（0 证得的程序 1 建成的变体 2 改写 / 构建失败 3 恢复的证明缺变体）
gal_fbr *gal_fbr_prove(const uint32_t *vs, uint32_t vn, const uint32_t *fs, uint32_t fn);
void gal_fbr_free(gal_fbr *f);
gal_prog *gal_prog_fbr_build(const gal_prog *pg, const uint32_t *fs, uint32_t nw, int *pending);
// 变体表命中（10-22）：按（pg 的顶点阶段 + 变体片元键）取函数建变体程序（内存缓存 / 离线库 / 持久缓存，同 load_binary，不现翻）；取不到 NULL（g_last_err 写原因）
gal_prog *gal_prog_fbr_load(const gal_prog *pg, uint64_t fs_key);
void gal_fbr_stats(uint64_t out[4]);
// 程序二进制尾段（10-22，gal_prog.m BIN_VERSION 2）：证明 + 变体表的序列化（out NULL 只算长度）；读回（len 正好一个尾段，坏 → NULL、*why 原因；恢复的证明没有 SPIR-V）
uint32_t gal_fbr_ser(const gal_fbr *f, uint8_t *out);
gal_fbr *gal_fbr_deser(const uint8_t *p, uint32_t len, const char **why);
// 单测读证明各字段（f 为空则全 0）：ok 位、运行时条件（常量缓冲绑定 / 字节偏移 / 位号 / 所属贴图绑定 / 种类 0 位为 0、1 浮点为 0）、带片元键的变体数、是否留着片元 SPIR-V
typedef struct { uint64_t ok[2][4]; int ncond; uint16_t cubo[16]; uint32_t coff[16]; uint8_t cbit[16], cbind[16], ckind[16]; int nvar, has_fs; } gal_fbr_view;
void gal_fbr_view_of(const gal_fbr *f, gal_fbr_view *v);
// 着色器记录 flags（续位 0–3）：位 4 曲面前顶点计算核；位 5–6 域；位 7–8 分区；位 9 顺时针；位 10 点模式
NSString *gal_tess_msl(void);
void gal_helper_kick(int k);                    // 后台开始编某个辅助库（曲面细分器只在首个曲面程序建出时编，gal_core.m）
void gal_hang_note(int kind, const gal_prog *pg, uint32_t n);   // 卡死现场记录（gal_core.m）：1 绘制 2 派发
gal_prog *gal_prog_get(uint32_t prog);
// 绘制 / 派发取程序：首遇作业没编完不等，返回空且 *pending = 1（调用方跳过这次绘制、gal_first_skip_note 计数）；见 gal_prog.m
gal_prog *gal_prog_get_draw(uint32_t prog, int *pending);
void gal_first_skip_note(uint32_t prog, const char *what);
// （第 4 块追加）后端内置辅助程序（gal_draw.m 的 DrawTexture 等手搭的 gal_prog）登记进程序表，返回编号；p 由调用方长期持有（live 由本函数置 1），
// 之后 gal_prog_get(编号) 返回 p；nxgal_prog_release 对它无效
uint32_t gal_prog_register_builtin(gal_prog *p);
uint64_t gal_spv_hash(const void *code, uint32_t len);   // SHA-256 前 8 字节（小端）
// 参数表下标分配（各块共同遵守）：0–7 描述符集参数缓冲；8–23 顶点缓冲（stage_in，属性 bufferIndex = 8 + GAL 缓冲号）；24–29 缓冲长度表等后端内部用
#define GAL_VB_BASE 8
#define GAL_TABLE_SLOTS 30
#define GAL_VPULL_SLOT 26   // 顶点自取的取数表（gal_vpull.m；25 是零属性缓冲 GAL_ZERO_VB）
// 计算着色器共享内存溢出（gal_prog.m spill_msl）：线程组内存总量超过 Apple GPU 上限的计算着色器，超出的共享数组整段改放设备内存，
// 每线程组一段，派发时按线程组数从临时分配器取、绑参数表这个槽。Ryujinx 按后端上报的上限截共享内存，后端报 Switch 的 48 KB，翻译不再截断
#define GAL_SPILL_SLOT 27
// 自定义采样器边框色（gal_border.m）：改写过的着色器入口读这个槽的边框表（每个采样器绑定号一项 32 字节：副份采样器、on、自定义色）
#define GAL_BORDER_SLOT 28
// 宽线（gal_wline.m）：顶点着色器的 s<键>_wl 入口读这个槽的宽线参数（S2AWideLine 48 字节）
#define GAL_WLINE_SLOT 29
// 逻辑运算（gal_logicop.m）：片元 s<键>_lo 入口读这个槽的逻辑运算参数（S2ALop：运算号 + 每目标格式类别 / 各分量位宽，gal_state.m 常驻表一项）。
//   29 号在片元阶段原本空着（GAL_WLINE_SLOT 只在顶点阶段用），同 27 号按阶段复用
#define GAL_LOP_SLOT 29
// 绘制号（gl_DrawID，10-24 图形接口盘点静默 1）：SPIRV-Cross 把 BuiltIn DrawIndex 固定模拟成读 [[buffer(19)]]（draw_id_buffer_index，C 接口设不了），
//   19 号在我们这儿是顶点缓冲 11；gal_prog.m 把它改到顶点阶段的这个槽（27 在顶点阶段空着：片元给颜色舍入表、计算给共享内存溢出），记录位 GAL_REC_DRAWID
#define GAL_DRAWID_SLOT 27
#define GAL_REC_DRAWID (1u << 18)   // 第 17 位已给 GAL_REC_LOGICOP（画面·着色器线 logicop-emu）
id<MTLRenderPipelineState> gal_pso_arch_lookup(id d);
// 后台编译入口（gal_core.m）：挂序列化器的编译器不能走异步接口（Metal 内部段错误），一律在自己的队列上调同步接口，同时最多 2 条
void gal_compile_bg(void (^blk)(id comp));
// 设备归档（gal_core.m）：写盘（原因进日志）、读数 [0] 本局命中 [1] 累计写条数 [2] 写的文件数、目录（没开为 nil）
void gal_pso_dev_flush(const char *why);
void gal_pso_dev_stats(uint64_t out[6]);   // 再加 [3] 特化结果后台按完整描述编 起 [4] 收下 [5] 失败
id gal_pso_dev_lookup(id d);          // 只查设备归档（完整描述 → 特化结果）
id<MTLRenderPipelineState> gal_pso_pack_lookup(id d);   // 只查包归档（完整描述 → 出包预编的特化结果，gal_core.m）
void gal_pso_note_desc(id d);         // 运行时真特化 / 现建了游戏程序的管线：记「特化管线」行（出包 specpipe.py 收，gal_core.m）
void gal_pso_dev_capture(id d);        // 特化结果按完整描述后台编一条进设备归档
uint64_t gal_spec_dev_hits(void);      // gal_state.m：首遇特化改由设备归档直接取的次数
uint64_t gal_spec_pack_hits(void);     // gal_state.m：首遇特化改由包归档（出包预编）直接取的次数
NSString *gal_pso_dev_dir(void);
// 管线预取（gal_state.m，10-22 换场景首帧建管线）：包里 shaders/pso_use.tsv（各正式局「管线首用」行收的用表）→ 程序建成时后台按表从归档取管线进预取池，渲染线程首遇先查池
void gal_pso_pf_load(const char *path);
void gal_pso_pf_prog(const gal_prog *pg);   // 程序建成（持 API 锁）：排它在用表里的管线
void gal_pso_pf_report(void);
void gal_pso_pf_stats(uint64_t out[7]);   // [0] 已排 [1] 取到 [2] 归档没有 [3] 渲染线程取用 [4] 后台用时 ns [5] 用表条数 [6] 坏行
int gal_pso_warming(void);            // 内部管线预建中（gal_core.m）
NSString *gal_pso_pname(id d);        // 管线描述的键串：所引用函数名逗号相连（gal_core.m）
uint64_t gal_present_count(void);     // 已出图次数（gal_present.m）
uint32_t gal_prog_slots(void);        // 程序编号上界（gal_prog.m，编号 1 起）
#define GAL_REC_COLOR_ROUND (1u << 16)             // 片元主入口颜色出口改写成功（gal_colorround.c）
#define GAL_REC_WLINE (1u << 14)        // 着色器记录位 14：顶点着色器带宽线展开入口 s<键>_wl（gal_wline.m）
char *gal_wline_msl(const char *msl, const char *entry);
#define GAL_REC_LOGICOP (1u << 17)      // 着色器记录位 17：片元着色器带逻辑运算入口 s<键>_lo（gal_logicop.m；只给有整数颜色输出的片元）
// 逻辑运算入口：追加段以 GAL_MSL_LOP 起头、接在原 MSL 末尾（原入口一字不改）
#define GAL_MSL_LOP "\n//@@GAL_MSL_LOP@@\n"
char *gal_logicop_msl(const char *msl, const char *entry);
const char *gal_logicop_helpers(void);   // 逻辑运算辅助函数 MSL（S2ALop 结构 + s2a_lop_apply 各重载；单测直接编它核换算）
extern float g_line_width;            // 当前线宽（nxgal_set_line_params）
extern int g_draw_wl;                 // 本次绘制按宽线展开（gal_draw.m 设，管线键 wl 位读）
extern uint64_t g_wide_line_draws[3]; // [0] 宽线展开画了 [1] 没法展开照 1 像素画 [2] 多边形线模式宽线（照 1 像素）
#define GAL_REC_BORDER (1u << 13)       // 着色器记录位 13：采样改写成带自定义边框色 / LOD 偏置模拟的辅助函数（入口多一个 [[buffer(GAL_BORDER_SLOT)]]）
char *gal_border_msl(const char *msl, const char *entry, const char *const *names, const uint16_t *binds, int n);
// 采样器要着色器模拟的部分（gal_tex.m）：自定义边框色（*alt = 副份的 gpuResourceID、c = 混合系数；不是自定义色时 *alt = 0）与着色器加的 LOD 偏置 *lb；两样都没有返回 0
int gal_sampler_border(uint32_t sid, uint64_t *alt, float c[4], float *lb);
int gal_sampler_border_custom(const nxgal_sampler_info *i);   // 1 = 自定义边框色要着色器模拟
int gal_sampler_border_kind(const nxgal_sampler_info *i);     // 主份边框色：0 透明黑 1 不透明黑 2 不透明白
extern uint32_t g_smp_custom;                                 // 在用的着色器模拟采样器个数（自定义边框色 / 着色器加 LOD 偏置）
// GAL_TG_MEM_MAX（离线出库的线程组内存上限）在 gal_spill.h（#783）
// 顶点自取（gal_vpull.m）：MSL 改写（不规整返回 NULL）、GAL 格式 → 格式描述（GAL_VPULL_BAD = 不支持）、写一项取数表（16 字节）
//   不支持不能用 0 表示：R8Unorm（GAL 格式 0）的描述按位编码恰好是 0（1 分量、1 字节、unorm），10-21 塞尔达顶点属性 R8Unorm 因此被当不支持读成零
#define GAL_VPULL_BAD 0xffffffffu
char *gal_vpull_msl(const char *msl, const char *entry);
const char *nxgal_test_vpull_msl(void);   // 顶点自取辅助 MSL 原文（gal_vpull.m）
char *gal_vpull_msl_in(const char *msl, const char *entry, const char *in_struct);   // 同上，stage_in 结构体名另给（直连 main0 / main0_z 共用 main0_in）
uint32_t gal_vpull_desc(int32_t fmt);
void gal_vpull_entry(uint32_t *o, uint64_t addr, uint32_t stride, uint32_t desc, uint32_t step, uint32_t divisor, uint32_t len);
#define GAL_VPULL_ENTRY 24   // 取数表每项字节数（= MSL S2AVtxAttr 大小）
int gal_vpull_on(void);
// 顶点输入成员的读法（f / u / i 按类型、r 原始位，0 = 认不出）；MSL 输入结构体里有没有原始位成员（有就必须自取）
int gal_vpull_raw_in(const char *msl, const char *entry);

// ---------- 计数与条件渲染（gal_cnt.m）----------
// SamplesPassed 用 Metal 可见性结果（编码器 Counting 模式 + 通道描述符 visibilityResultType = Accumulate）：
//   每个「区间」（相邻两次 Report / Reset 之间）占共享可见性缓冲里的一条槽链（8 字节一槽；单个编码器里被辅助绘制切成几段就几个槽），跨通道 / 跨提交都累加进同一条链。
// 钩子约定（只有这三处碰编码器的可见性状态）：
//   gal_cnt_on_pass_begin(d)：gal_render_enc 建每个渲染通道描述符时调用（挂可见性缓冲 + Accumulate）；新编码器的可见性模式视为关闭。
//   gal_cnt_on_draw(e)：绘制模块在每条游戏绘制（Draw / DrawIndexed / 各种间接 / DrawTexture）编码 draw 调用之前调用；
//     按需设 Counting + 当前区间槽偏移（同编码器同槽不重复设），并计入区间绘制数（同 Vulkan 后端 DrawCount）。
//   gal_cnt_on_aux_draw(e)：后端辅助绘制（清屏三角等，硬件上不计样本）编码前调用；可见性计数开着就关掉。
//   gal_cnt_aux_wants_break()：辅助绘制取编码器之前调用，返回 1 就先 gal_pass_close()——区间在单个编码器里的段数（= 槽链长）封顶 VIS_SEG_MAX。
void gal_cnt_on_pass_begin(MTL4RenderPassDescriptor *d);
void gal_cnt_on_draw(id<MTL4RenderCommandEncoder> e);
void gal_cnt_on_aux_draw(id<MTL4RenderCommandEncoder> e);
int gal_cnt_aux_wants_break(void);
//   gal_cnt_on_commit()：gal_commit 提交后调用；有在途计数就叫醒等结果的计数线程（nxgal_counter_wait）
void gal_cnt_on_commit(void);

// ---------- 性能计数（nxgal_perf_read）：各段 CPU 墙钟（mach 时基）累计与次数，GPU 时间从命令缓冲完成回调累计 ----------
#include <mach/mach_time.h>
enum { GP_DRAW, GP_PSO, GP_PSO_BUILD, GP_BIND, GP_DYN, GP_UPLOAD, GP_CLEAR, GP_COMMIT, GP_WAIT, GP_XCWAIT, GP_PRESENT, GP_COPY, GP_RENC, GP_CENC, GP_PRELOAD, GP_INLINEUP, GP_SETREUSE, GP_MIRRORW, GP_MIRROR, GP_IDXALIGN, GP_PSO_OPEN, GP_PSO_ARCH, GP_N };
extern uint64_t g_gp_t[GP_N], g_gp_n[GP_N];
extern _Atomic uint64_t g_gp_gpu_ns, g_gp_cmdbufs;
extern uint64_t g_gp_frame; extern int g_gp_commit_present;
// 诊断开关交替（NXGAL_DIAG_ALT=1，缺省关）：按程序跳过 / 去片元只在奇数帧生效，同一次回放里开关交替比 GPU 时间（抵消频率漂移）；返回 1 = 本帧不生效
static inline int gal_diag_alt_off(void) { static int a = -1; if (a < 0) { const char *v = getenv("NXGAL_DIAG_ALT"); a = v && *v == '1'; } return a && !(g_gp_frame & 1); }   // 出图前置 1：本次提交是该帧最后一个命令缓冲（nxgal_last_gpu_ms 按帧归账）
// 分段 CPU 计时缺省关（NXGAL_PERF_TIME=1 才开，进程起来后第一次初始化时读）：每次绘制要过 3–4 个计时段，mach_absolute_time 每次约 50 ns，
// 10-19 Mac 岛上录像回放采样占渲染线程 10.6%（约 0.9 ms/帧，与 13ba750 关掉的 GalTiming 同一类开销）。关时只计次数，时间记 0
extern int g_gp_time;
typedef struct { int k; uint64_t t; } gp_scope;
static inline void gp_end(gp_scope *s) { if (s->t) g_gp_t[s->k] += mach_absolute_time() - s->t; g_gp_n[s->k]++; }
#define GP_SCOPE(k) gp_scope _gps_##k __attribute__((cleanup(gp_end))) = {k, g_gp_time ? mach_absolute_time() : 0}
// 建资源与驻留集记账（同上开关，缺省关）：建贴图 / 上传暂存缓冲 / 建缓冲（个数、字节、时间）、驻留集加入与提交（次数、时间）。
// 原生层线 10-20：动森开局装载帧一帧新建约 900 个 Metal 对象（Mac 合计约 3.5 ms），要量 iPhone 上的单价；渲染器本帧合计 > 15 ms 时由 nxgal_frame_totals 逐帧打一行
enum { RS_TEX, RS_STAGING, RS_BUF, RS_RESADD, RS_RESCOMMIT, RS_N };
extern uint64_t g_rs_n[RS_N], g_rs_b[RS_N], g_rs_t[RS_N];
typedef struct { int k; uint64_t t; } rs_scope;
static inline void rs_end(rs_scope *s) { if (s->t) { g_rs_t[s->k] += mach_absolute_time() - s->t; g_rs_n[s->k]++; } }
#define RS_SCOPE(k) rs_scope _rss_##k __attribute__((cleanup(rs_end))) = {k, g_gp_time ? mach_absolute_time() : 0}
#define RS_BYTES(k, n) do { if (g_gp_time) g_rs_b[k] += (uint64_t)(n); } while (0)

// 渲染器内部辅助库（顶点重排 / 索引转换 / DrawTexture / 清屏 / 出图 / 贴图转换，MSL 源码在各模块）：nxgal_init 末尾后台并行编（iOS 上现编 MSL 每支几十 ms，
// 原先在首次用到时同步编，落在游戏帧里成长帧）；首用时取结果，没编完才等，耗时与等待各记一行日志
enum { GH_RESTRIDE, GH_IDX, GH_DT, GH_CLEAR, GH_PRESENT, GH_TEX, GH_TESS, GH_SMAA_EDGE, GH_SMAA_BLEND, GH_SMAA_NEIGHBOUR, GH_N };   // 曲面与 AA 首次使用时载入离线库
NXGAL_API uint64_t nxgal_helper_compiles(void);   // 内部辅助库现编次数（离线库都在时为 0；单测断言）
NXGAL_API const char *nxgal_helper_src(int32_t k, const char **base);   // gal_xc --helpers 导出第 k 个辅助库源码；*base = 离线库基础文件名 gal_helper_<键>.<源码哈希>
extern NSString *const k_restride_msl, *const k_idx_msl, *const k_dt_msl, *const k_clear_msl, *const k_present_msl, *const k_tex_msl;
void gal_helpers_prewarm(void);
id<MTLLibrary> gal_helper_lib(int k, NSError **e);
NSString *gal_aa_msl(int index);
int gal_aa_encode(id<MTLTexture> src, id<MTLTexture> dst, int mode);   // src 是伽马编码 UNORM 定格；不碰原始截图
// 建管线一律经这两个（先查随包归档 NXGAL_PSO_ARCHIVE，再现建；计数 / 收描述见 gal_core.m）；gal_pso_cache_flush 把收到的描述 / 二进制写盘
id<MTLRenderPipelineState> gal_new_render_pso(MTL4PipelineDescriptor *d, NSError **e);
id<MTLComputePipelineState> gal_new_compute_pso(MTL4ComputePipelineDescriptor *d, NSError **e);
// 异步现建（首局根治 B，安全网；gal_core.m）：先同步查归档（命中直接给 *hit），没命中交编译器异步任务、返回任务；编好前调用方跳过绘制。
//   gal_pso_job_take：没编完返回空且 *done = 0；编完返回管线（失败为空）、*done = 1，任务随之释放。gal_pso_async_on：NXGAL_PSO_ASYNC=1 开，缺省关（产品局由 RenderLoop.cs 打开）
typedef struct gal_pso_job gal_pso_job;
int gal_pso_async_on(void);
gal_pso_job *gal_new_render_pso_async(id d, id<MTLRenderPipelineState> *hit);
id<MTLRenderPipelineState> gal_pso_job_take(gal_pso_job *j, int *done);
id<MTLRenderPipelineState> gal_pso_job_wait(gal_pso_job *j);   // 等编完并取用
void gal_pso_arch_stats(uint64_t out[5]);   // 分片归档按需开片（gal_core.m）：[0] 开片 [1] 腾退关片 [2] 低区账本不给开 [3] 开失败 [4] 当前已开字节
void gal_pso_cache_flush(void);
// 管线特化（gal_be.h「管线特化」，只 Metal 4）：基础管线片元输出留空，首遇按颜色格式 / 混合特化；gal_pso_can_specialize 为假时走完整建
int gal_pso_can_specialize(void);
void gal_pso_unspecialize_color(MTL4RenderPipelineDescriptor *d, int i);
id<MTLRenderPipelineState> gal_specialize_render_pso(MTL4RenderPipelineDescriptor *d, id<MTLRenderPipelineState> base, NSError **e);
// 通用特化预热（gal_state.m，10-22 动森首遇特化慢根治）：异步特化；清屏基础管线与对应的颜色留空描述（gal_pass.m，ctype 0 浮点 1 无符号 2 有符号）；
//   启动时起预热（nxgal_warm_internal）；读数（0 起 1 完成 2 失败）
void gal_specialize_render_pso_async(id d, id<MTLRenderPipelineState> base, void (^done)(id<MTLRenderPipelineState>));
id gal_clr_spec_base(int ctype);
id gal_clr_spec_desc(int ctype);
void gal_warm_spec_combos(void);
void gal_spec_combo_stats(uint64_t out[4]);   // 0 起（后台还在提交时 UINT64_MAX）1 完成 2 失败 3 本进程记下的「特化组合」行数
int gal_spec_combo_load(const char *path);
void gal_pso_warming_push(void);   // 内部管线预建（不计入现建），可嵌套（gal_core.m）
void gal_pso_warming_pop(void);
// 慢特化诊断：这个颜色附件描述（Metal 层）的组合预热状态：0 不在表 1 在编 2 成功 3 失败
int gal_spec_combo_status(id ca);   // 载入运行时收来的组合表并后台预热，返回条数
uint64_t gal_pso_spec_count(void);

// ---------- 导出入口全局锁（Ryujinx 多线程后端 ThreadedRenderer：大部分调用排到单一渲染线程，但 CreateTexture / GetBufferData / 贴图 GetData /
// WaitSync / 后台上下文动作等会从别的线程直接调进来；C 层是单线程设计，所有 NXGAL_API 入口经此串行）。可重入（入口互调），不竞争时只做一次原子比较
int gal_api_enter(void);
void gal_api_leave(int *depth_token);
#define GAL_API_LOCK() __attribute__((cleanup(gal_api_leave), unused)) int _gal_api_lk = gal_api_enter()

// 等 GPU 超过 3 秒 / 命令缓冲执行出错：判红写现场后 _exit(86)（gal_core.m）
void gal_gpu_stall_exit(id<MTLSharedEvent> ev, const char *what, uint64_t want, uint64_t have);   // Mac：3 秒即退；iPhone：报警后继续等 ev 到 want（栅栏前进重新计时），满 20 秒或回执报错才退；返回 = 等到了
void gal_gpu_error_exit(const char *who, NSError *err);
GAL_MTL4_ZONE_END   // 本头自己的声明到此

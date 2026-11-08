// s2a_widen.h：宽屏第三层核心（识别和改写）的 C 接口。实现在 graphics/widen（C#，不依赖 Ryujinx），NativeAOT 导出，和 S2A.Aot 同一个库。
// 两种图形模式用同一份核心：通用模式（Ryujinx GAL 包装层 graphics/widen/gal）在 C# 里直接调核心；直连模式（graphics/nvn 回放层）经本头文件调。
// 设计约定见 docs/设计_直连架构.md §12.4。
//
// 线程：渲染路径函数（s2a_widen_texture 到 s2a_widen_present）同一时刻只许一条线程调（直连 = 直连回放 / 编码线程），可以不是主线程；
//       离线函数（s2a_widen_spirv_*）任意线程、可并发。
// 零分配：渲染路径每次调用不分配托管内存（s2a_widen_shader 例外：建着色器时调一次，可分配）。s2a_widen_alloc_bytes() 给出调用线程累计托管分配字节，
//       每帧打一行即实测；判据 = 稳态每帧增量 0。
// 不抛异常：内部异常一律吞掉、计数（s2a_widen_report 的「异常」项），该次调用按「不改」返回。
// 关闭时（s2a_widen_init 返回 0）：所有函数原样返回（宽不变、视口不变、常量返回 0 = 零拷贝原样绑定）。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- 0. 初始化（一局一次，起局时、第一帧之前） ----------
// flags：原生层 s2a_widen_game() / s2a_widen_layout() / s2a_widen_full() 的结果按位或（runtime/include/s2a_native.h）。
enum { S2A_WIDEN_GAME = 1, S2A_WIDEN_LAYOUT = 2, S2A_WIDEN_FULL = 4, S2A_WIDEN_OBSERVE = 8 };   // OBSERVE：只观察（宽屏关着、自动玩家开着时：给 s2a_ap_cam 认镜头位姿，不改画面）
// 模式：通用模式 services/aot/Compose.cs 现有判定原样搬进核心，两边同一份。
enum {
    S2A_WIDEN_OFF = 0,       // 屏幕不比 16:9 宽：什么都不改
    S2A_WIDEN_UI = 1,        // 游戏自己按屏幕比出图（第二层生效，动森 / 塞尔达 / 暗黑3 / 怪猎）：不放宽贴图，只把界面层收回 16:9 原尺寸居中
    S2A_WIDEN_ALL = 2,       // 整套放宽（第三层表验过）：16:9 一族渲染目标放宽、投影改写
    S2A_WIDEN_PILLAR = 3,    // 第三层没验过：不改，16:9 原比例居中、两侧黑边（出图层不报未满屏）
    S2A_WIDEN_OBS = 4,       // 只观察（flags 带 S2A_WIDEN_OBSERVE）：不放宽、不改写，只从常量里认镜头位姿给自动玩家（s2a_ap_cam）
};
// screen_w = 1080 高对应的屏幕宽（原生层 s2a_screen_w()；iPhone 17 Pro Max = 2346）；screen_h = 1920 宽对应的屏幕高（s2a_screen_h()；
//   屏幕比 16:9 窄时 > 1080，iPhone Duo 内屏 1350，宽屏 1080）。返回模式（上面四种之一）。
int s2a_widen_init(int screen_w, int screen_h, uint32_t flags);
// 运行中换屏（10-27 Duo 合上 / 展开、macOS 窗口拖拽）：按新屏幕宽 / 高重定模式与 K / Ky、换一份新的帧状态（贴图登记全清，着色器句柄照用），返回新模式（同 init）。
//   调用方随后按新尺寸重新登记贴图、重建放宽的渲染目标；游戏自己出宽图（S2A_WIDEN_GAME）时不换。持核心锁、在没有开着的渲染遍时调
int s2a_widen_reaspect(int screen_w, int screen_h);
// 横向放宽比 k（≥ 1，吸附到 1920 宽多出偶数列；OFF / PILLAR 时 1）。
float s2a_widen_k(void);
// 导出入口异常累计（宿主问玩家退回 16:9 用，见 runtime/src/qprompt.c s2a_qp_unfit_sample）
int64_t s2a_widen_errors(void);
int64_t s2a_widen_stretch(int which);   // 拉伸风险累计：0 对 / 1 拉伸 / 2 收窄（场景 3D 笔数）；没有会话 -1

// ---------- 2. 贴图（建渲染目标；对应调用点 2） ----------
// id：调用方自己的贴图号（非 0，同一局内唯一，释放后可复用）。w、h：游戏要的尺寸。res_scale：分辨率倍率（直连恒 1）。
// usage：S2A_WIDEN_USE_RT = 会当颜色 / 深度目标、存储由回放层自己分配（GPU 私有）。只有带它的才可能放宽；
//        存储就是游戏内存池（CPU 写、游戏按自己的布局读）的贴图一律不放宽，不传 RT。
//        S2A_WIDEN_USE_REBUILD（与 RT 一起给）= 调用方能在运行中按更宽的宽重建这张贴图的存储：尺寸不属 16:9 一族的先记「未定」，
//        上面有一笔铺满视口、读到 16:9 镜头矩阵就判为画布（10-30 银河2 1920×1584 Wii EFB），由 s2a_widen_promoted 交出、调用方重建。
// 返回实际要建的宽（不放宽 = w；高不变）。UI / PILLAR / OFF 模式恒返回 w。
enum { S2A_WIDEN_USE_RT = 1, S2A_WIDEN_USE_REBUILD = 2 };
int s2a_widen_texture(uint32_t id, int w, int h, float res_scale, uint32_t usage);
// 取走上次调用以来按内容判成画布的贴图号（最多 cap 个，返回个数）：每张按 s2a_widen_texture 同一贴图号的新宽（s2a_widen_map_x 等照常可用）重建存储、
// 旧内容按 Hor 平移 (新宽 − 旧宽) / 2 拷进中间，再对它的视图重新调 s2a_widen_view。在两次提交回放之间、同渲染路径线程调。之后同尺寸新建的贴图直接按放宽建
int s2a_widen_promoted(uint32_t *ids, int cap);
// 视图：id 是 parent 第 level 级的视图（游戏宽 w0）。返回视图实际宽（父放宽则按级缩，否则 w0）。
int s2a_widen_view(uint32_t id, uint32_t parent, int level, int w0);
void s2a_widen_release(uint32_t id);
// GPU 写过这张贴图（计算派发写的图像、贴图拷贝的目标）：不是 CPU 供图，不当 16:9 原比例页的来源；放不放宽都要报（放宽的已由 s2a_widen_texture 登记）。
// src ≠ 0（拷贝）：只在 src 本身是 GPU 写的 / 登记过的渲染目标时才记——CPU 供图拷来拷去仍是图片。返回 1 = 记了。
//   id 是放宽的贴图、src = 0（计算整张写，组数已补到放宽宽度）或 src 也放宽（整屏拷贝）：两侧带本帧有确定内容（S2A_WIDEN_DRAW_WRITES 的兜底据此不清）。
int s2a_widen_gpu_wrote(uint32_t id, uint32_t src);
// 画面分层图集按需放宽（同通用模式 WidenTexture.ForceWiden → WidenFrame.LayerWiden）：没放宽的单层 2D 颜色目标第一次被「读放宽外延内容」的绘制当目标时调。
// 尺寸是某个已放宽 16:9 画面按级缩的两层竖拼（宽 = 画面宽 ÷2^n、高 2–2.5 倍）就登记成放宽、返回放宽宽，否则返回 w；之后照 ① 按放宽存储建。
int s2a_widen_layer_widen(uint32_t id, int w, int h);
// 按区域拷贝 / 上屏裁剪时：贴图 tex 上的横坐标 x（游戏坐标）换成实际坐标（没放宽原样）。
int s2a_widen_map_x(uint32_t tex, int x);

// ---------- 3. 每次绘制（调用点 3、4） ----------
// 每次绘制的调用顺序（必须按这个顺序，顺序就是语义）：
//   ① s2a_widen_targets（目标变了才调）；
//   ② 本次绘制用到的每个常量槽 s2a_widen_cbuf_bind（内容只比影子、只扫变了的字节）；
//   ③ s2a_widen_draw → 得出这笔的画法 mode；
//   ④ 每个视口 / 裁剪框 s2a_widen_map_viewport / s2a_widen_map_scissor(mode, …)；
//   ⑤ 每个常量槽 s2a_widen_cbuf_emit：返回 > 0 就绑调用方暂存区（改写后的整段），0 就照原样零拷贝绑游戏内存。
// 为什么 ② 和 ⑤ 分开：同一段常量对不同绘制要原值还是改写值，取决于这笔画到哪、读了什么（界面层 / 没放宽目标要原值），必须先看完全部绑定再决定（③）。

// 颜色目标 0、深度目标的贴图号（0 = 没有）。
void s2a_widen_targets(uint32_t color0, uint32_t depth);

// ①' 每笔绘制的快判（① 之后、② 之前）：视口 0（游戏原值）落不落在放宽 / 原生宽区域。返回 0 = 不落在（核心对这笔只会「原样」：画法 KEEP、各槽出数 0），
//    调用方可以整笔跳过 ②–⑤（不绑定、不定画法、不出数），省掉直连每笔的核心开销（10-24 动森约一半绘制画在没放宽的目标上）；返回 1 照常走 ②–⑤。
//    当前颜色目标是「未定」目标（S2A_WIDEN_USE_REBUILD 建的非 16:9 附件）时也返回 1：常量要交给核心按内容判画布，画法仍是 KEEP。
int s2a_widen_viewport(float x, float w, float h, float res_scale);

// 常量槽绑定：stage 0 顶点 / 1 片元 / 2 几何 / 3 外壳 / 4 域 / 5 计算；slot 0..17；cpu = 被绑区间在游戏内存里的 CPU 地址，len 字节（0 = 解绑）。
// 只读游戏内存、绝不写。内部按 CPU 地址建影子页（4 KB），逐 16 字节比，只扫变了的；同一地址被多个槽 / 多次绘制绑定只扫一次变化。
void s2a_widen_cbuf_bind(int stage, int slot, const void *cpu, uint32_t len);
// 同 s2a_widen_cbuf_bind，另给 n 对 [lo, hi)（相对 cpu 的字节偏移，升序）：调用方保证上一次交给这个槽的是同一处（同 cpu、同 len），且这些区间以外的字节没变
//   （直连胶水按影子续拼的更新段给）。核心只比这些区间；影子不满足前提（未知粒 / 未对齐 / 页被回收）时自己改整段比，结果与整段比逐项相同。n ≤ 0 或 > 256 = 整段比
void s2a_widen_cbuf_bind_ranges(int stage, int slot, const void *cpu, uint32_t len, const uint32_t *ranges, int n);

// 片元实际采样的一张贴图（程序反射里真用到的绑定，不是槽位残留）。
enum { S2A_WIDEN_TEX_TILE_U = 1,     // 采样器横向重复寻址（平铺）
       S2A_WIDEN_TEX_FLAT_KNOWN = 2,   // 调用方量过这张贴图的横向细节（见 s2a_widen_draw_out.want_flat）
       S2A_WIDEN_TEX_FLAT_CONTENT = 4,   // 量过且横向平滑（拉宽看不出）：铺满画布的界面层可以推满
       S2A_WIDEN_TEX_EDGE_SMOOTH = 8,    // 量过：整体有细节，但左右各 1/16 宽的边缘带平滑或透明（族 2：半透明叠加层推满时采样外扩、调用方换钳边，两侧是边缘的平滑延续）
       S2A_WIDEN_TEX_SEAMLESS_U = 16,    // 量过：首列与末列几乎相同（平铺设计，横向重复寻址时外扩按平铺延续无缝）
       S2A_WIDEN_TEX_ROW_CONST = 32 };   // 量过：每行横向不变（全部行逐点与本行中点差都 ≤ 0.10）：原尺寸居中层「收缩 + 推满」的前提（11-06 八方2 小地图底盘：曲率处处小、行内变化大的圆盘不许收缩）  // 量过：首列与末列几乎相同（平铺设计，横向重复寻址时外扩按平铺延续无缝）
typedef struct { uint32_t id; int32_t w, h; float res_scale; uint32_t flags; } s2a_widen_tex;
// 调用方跳过核心的绘制（s2a_widen_viewport 回 0）里视口铺满整张颜色目标 0 的那笔：只交采样表登记整屏副本来历（采样的全是整屏画面 / 副本 → 目标是副本），不改画法。
//   w / h = 目标客体宽高。11-02 塞尔达直连菜单底图缩图链断在 16:9 一环（Ui 模式 16:9 视口不进核心）
void s2a_widen_note_fill(uint32_t id, int w, int h, const s2a_widen_tex *tex, int n);

enum { S2A_WIDEN_DRAW_FRAGCOORD = 1,   // 程序读片元坐标
       S2A_WIDEN_DRAW_COLOR = 2,       // 有颜色目标（只写深度 / 模板的遮罩不带）
       S2A_WIDEN_DRAW_WRITES = 4,      // 调用方把颜色目标的清屏（s2a_widen_target_cleared）、贴图拷贝 / 计算整张写（s2a_widen_gpu_wrote）都报了：
                                       //   放宽目标本帧第一次被画、两侧带还没有确定内容时，核心让这笔带 S2A_WIDEN_OUT_PAGE_SIDES、交出两侧条带清黑（不留上一帧，10-29 马车8 选轮胎页）；
                                       //   这第一笔自己就不透明铺满全宽（带 S2A_WIDEN_DRAW_OPAQUE、铺满画布、画法 SCALEK / HOR）时不清。
                                       //   没报全的调用方（GL / Vulkan 胶水）不要带：带了会把游戏清成别的颜色的两侧再清黑
       S2A_WIDEN_DRAW_OPAQUE = 8,      // 颜色目标 0 不混合、四通道全写（配合 S2A_WIDEN_DRAW_WRITES 用）
       S2A_WIDEN_DRAW_DEPTH_WRITE = 16,     // 写深度（挂深度目标、开深度测试与深度写）：这笔给之后的笔铺几何，核心不外推它的顶点（WidenSession.Draw）
       S2A_WIDEN_DRAW_INSTANCED = 32,       // 一笔多实例（实例数 > 1，CPU 上已知的）：一批贴片不是一整块面，核心不外推它的顶点（WidenSession.Draw）
       S2A_WIDEN_DRAW_PATCHES = 64 };       // 一笔不止一个四边形（非间接绘制、顶点 / 索引数 > 6）：同多实例，一批贴片不是一整块面，不外推、不外扩采样坐标
                                            //   （11-02 泡泡龙4 说明页：整页字形网格 270 顶点一笔，被当铺满层推满 + 采样坐标外扩，每个字采到图集别处）
typedef struct {
    float vp_x, vp_y, vp_w, vp_h;      // 视口 0（游戏给的原值）
    float target_scale;                // 颜色目标 0 的分辨率倍率（直连恒 1）
    int32_t shader[6];                 // 各阶段 s2a_widen_shader 的句柄（0 = 没有这一阶段 / 没登记）
    uint32_t flags;                    // S2A_WIDEN_DRAW_*
    const s2a_widen_tex *tex; int32_t ntex;   // 片元实际采样的贴图
} s2a_widen_draw_in;

// 画法（mode）：
enum { S2A_WIDEN_KEEP = 0,     // 原样
       S2A_WIDEN_SCALEK = 1,   // 2D / 全屏遍：视口 / 裁剪横向乘 k
       S2A_WIDEN_HOR = 2,      // 读了改写投影的 3D：视口中心平移 + 宽乘 k（视野变宽、不拉伸）
       S2A_WIDEN_CENTER = 3,   // 界面层：原尺寸居中
       S2A_WIDEN_PAGE = 4 };   // 16:9 原比例页：视口 / 裁剪原尺寸、整体平移到页面中心（起页那笔带 S2A_WIDEN_OUT_PAGE_SIDES）
// 直连：顶点外推参数（下面 push[4]）交给顶点着色器的 Metal 顶点缓冲槽（10-24 宽屏线定，与着色器线 / 直连线对齐）。
//   直连回放层槽位：0 参数块、1–12 顶点格式转换、14–29 顶点流、30 常量兜底，13 是唯一空槽。
//   直连库里带外推尾段的顶点着色器声明 constant float4 &s2a_push [[buffer(S2A_WIDEN_PUSH_SLOT)]]，读它的着色器每笔都要有绑定（不外推的笔写 0）。
#define S2A_WIDEN_PUSH_SLOT 13
typedef struct {
    int32_t mode;
    // 顶点越界外推参数（着色器经调用点 6 改过才有用；没改过的着色器忽略）：x = 外推量、y = 门限²、z = 横向收缩量、w = 原画框外推 pad（v1 直连恒 0）。
    // 对应通用模式写进支持缓冲 s2a_widen 字段的 4 个浮点（Ryujinx 补丁 0066）。全 0 = 不外推。
    float push[4];
    // 读片元坐标的程序在放宽目标上要乘的横向倍率（通用模式 render_scale[0]）；1 = 不变。UI 模式恒 1。
    float frag_scale_x;
    // S2A_WIDEN_OUT_NO_EMIT：本笔各槽出数全为 0（照原样零拷贝绑游戏内存），调用方可以不调 ⑤。
    uint32_t flags;
    // 想量的贴图号（0 = 没有）：这笔有张贴图只因尺寸规则被判「有细节」、调用方还没交过内容结论（S2A_WIDEN_TEX_FLAT_KNOWN）。
    //   调用方量它的横向高频细节，之后交贴图时带上 S2A_WIDEN_TEX_FLAT_KNOWN（平滑再加 S2A_WIDEN_TEX_FLAT_CONTENT）
    uint32_t want_flat;
} s2a_widen_draw_out;
// S2A_WIDEN_OUT_PAGE_SIDES：画这笔之前要清两侧条带——本笔起了 16:9 原比例页（放宽目标上采样整画布 16:9 图片：标题图 / 视频帧 / 全屏 2D 背景，放宽也扩不出内容，按原比例居中、两侧黑边），
//   或（带 S2A_WIDEN_DRAW_WRITES 时）放宽目标本帧第一次被画、两侧带没有确定内容（条带 = 中间客体宽以外的两侧）。
//   调用方取 s2a_widen_page_sides 的两侧条带，画这笔之前把颜色目标 0 的这两条整高清成全 0（黑，同通用模式 ClearCols）。
// S2A_WIDEN_OUT_UV_EXTEND：本笔是带纹理的半透明叠加层、按推满画（族 2，11-01）——调用方把它采样的没放宽过的贴图的横向归一化坐标以 0.5 为中心
//   放大 k 倍（k = 目标放宽比，同推满把画布边顶点推到屏幕边的拉宽倍数）：中间 16:9 区逐像素同原版，两侧采样落在 [0,1] 外按采样器取（钳边 / 镜像 / 平铺）。
//   直连胶水用 uvx（x' = x·(1 + q.x) + q.y，q = (k − 1, (1 − k) / 2)）
enum { S2A_WIDEN_OUT_NO_EMIT = 1, S2A_WIDEN_OUT_PAGE_SIDES = 2, S2A_WIDEN_OUT_UV_EXTEND = 4 };
// 本笔要清两侧条带（起页 / 两侧兜底）时返回 1，cols = 两侧条带 [cols[0], cols[1]) 与 [cols[2], cols[3])（放宽贴图的像素列，整高）；否则 0。
int s2a_widen_page_sides(int32_t cols[4]);
// 窄屏加高的目标上起页时返回 1，rows = 上下条带 [rows[0], rows[1]) 与 [rows[2], rows[3])（像素行，整宽；页内容在 [rows[1], rows[2])）；否则 0。
//   调用方与两侧条带一起在画这笔之前清成全 0（10-28 B06；宽屏 / 16:9 时恒 0，行为不变）。
int s2a_widen_page_rows(int32_t rows[4]);
// 出数状态版本：同一次提交（游戏内存不变）里同一绑定、本值没变，⑤ 的结果必与上次相同，调用方可复用上次结果、不再调 ⑤。③ 之后取。
int64_t s2a_widen_state_gen(void);
// 返回 mode（同 out->mode）。
int s2a_widen_draw(const s2a_widen_draw_in *in, s2a_widen_draw_out *out);
// 写深度 3D 笔旁路（游戏自出宽图、原生宽场景目标、开深度测试且写深度；按目标学习放行、每张目标每帧至少一笔照走全量）：1 = 已按 ScaleK、出数 0 处理（out 同 s2a_widen_draw），0 = 照走 s2a_widen_draw
int s2a_widen_draw_light(const s2a_widen_draw_in *in, s2a_widen_draw_out *out);

// 视口 / 裁剪换算（x、w 原地改；y、h 不变）。mode = 本笔 s2a_widen_draw 的结果。
void s2a_widen_map_viewport(int mode, float *x, float *w);
void s2a_widen_map_scissor(int mode, int32_t *x, int32_t *w);

// ---------- 窄屏上下多画（10-26 任意宽高比：屏幕比 16:9 窄，宽不动、高放 ky） ----------
// 纵向放高比 ky（≥ 1；宽屏 / 关闭时 1）。k 与 ky 至多一个 > 1。
float s2a_widen_ky(void);
// 贴图 / 视图实际要建的高：窄屏加高了的返回放高高，否则原样 h。s2a_widen_texture / s2a_widen_view 之后调。
int s2a_widen_tex_h(uint32_t id, int h);
// 贴图的客体宽：放宽了的返回游戏建的原宽，否则原样 w（GL 直连原比例回退要两侧放宽带宽 = (存储宽 − 客体宽) / 2）。
int s2a_widen_tex_guest_w(uint32_t id, int w);
// 视口 / 裁剪纵向换算（y、h 原地改；x、w 由 s2a_widen_map_viewport / map_scissor 换）。mode = 本笔 s2a_widen_draw 的结果。
void s2a_widen_map_viewport_y(int mode, float *y, float *h);
void s2a_widen_map_scissor_y(int mode, int32_t *y, int32_t *h);
// 本笔读片元坐标的程序在加高目标上片元 y 要乘的倍率（render_scale_y，Ryujinx 补丁 0206 分轴）；其余 1。s2a_widen_draw 之后取。
float s2a_widen_frag_scale_y(void);

// 常量出数：本笔绘制这个槽该看到的内容。返回改写处个数：
//   > 0：scratch[0..len) 已写好（游戏原值 + 改写值），绑 scratch；0：照原样零拷贝绑游戏内存（scratch 不碰）。
//   cap < 绑定长度且需要改写时返回 0 并记一次红（「暂存区不够」）——调用方按绑定长度给暂存区。
uint32_t s2a_widen_cbuf_emit(int stage, int slot, void *scratch, uint32_t cap);

// 计算派发前（绑定照 ② 调过）：narrow_only = 只写没放宽的图像（如调色 LUT）。之后照 ⑤ 出数。
void s2a_widen_dispatch(const int32_t shader[6], int narrow_only);
// 写放宽图像的派发：按像素铺（gx = ⌈w0 / Lx⌉）时返回铺满放宽宽 w1 的 X 组数，否则 −1（照原样派、记红）。纯函数。
int s2a_widen_groups_x(int gx, int gy, int w0, int w1, int h);
// 游戏清颜色目标（整屏副本来历作废）。
void s2a_widen_target_cleared(uint32_t tex);

// ---------- 着色器登记（建程序 / 载入着色器时一次） ----------
// use_text = 离线表里这条着色器的常量读法（s2a_widen_spirv_cbuf_use 的输出原样）；NULL 或空 = 不知道（按「整个绑定都会读」保守处理）。
// flags：S2A_WIDEN_SH_PUSH = 顶点着色器经调用点 6 改过（能越界外推），且运行时会把 s2a_widen_draw_out.push 交给它。
//        只改了着色器、push 没交过去时不要带：带了核心会把原尺寸居中层改成全宽视口等着色器收缩，着色器不收缩界面就被拉宽。
// 返回句柄（> 0），放进 s2a_widen_draw_in.shader[stage]；0 = 失败（按没登记处理）。
enum { S2A_WIDEN_SH_PUSH = 1 };
int32_t s2a_widen_shader(int stage, const char *use_text, uint32_t flags);

// ---------- 1 / 5. 帧结束：上屏（调用点 1、5） ----------
// tex = 这次上屏的贴图号；crop 原地改：横向裁剪按放宽换算、纵向（窄屏）按放高换算、宽高比按屏幕比。返回 1 = 本帧按 16:9 原比例居中留黑边（PILLAR 或原比例页），
// 2 = 上屏贴图两侧是放宽内容画的（黑是游戏画的，满屏判据只免纯黑带），5 = 原比例回退（纯 2D 帧两侧游戏都没内容整帧 16:9 居中；3D 镜头帧两侧游戏都没画到、裁剪框收进存储中间 16:9，见 s2a_widen_side_coverage），0 = 满屏。
// 帧号由核心自己数（每次上屏 +1），不用传。
typedef struct { int32_t left, right, top, bottom; float aspect_x, aspect_y; } s2a_widen_crop;
int s2a_widen_present(uint32_t tex, s2a_widen_crop *crop);
// 原比例回退的反馈（上屏路径常驻采样，渲染路径线程调）：left_drawn / right_drawn = 出图两侧带本帧被游戏画到（按哨兵判，不按亮度）；
// sig = 中间区 8 格各 4 位亮度（第 i 格在 4i 位），回退中它大变才重试放宽。纯 2D 帧连续 2 个样本两侧都没画到（只一侧没画到是关卡一端，不回退） → 之后 s2a_widen_present 返回 5
// left_undrawn / right_undrawn：两侧带一半以上的点游戏根本没画到（哨兵还在）。3D 镜头帧只按它判回退（上屏收进中间 16:9，见 WidenSession.Crop3D）
void s2a_widen_side_coverage(int left_drawn, int right_drawn, int left_undrawn, int right_undrawn, uint32_t sig);
// 本帧（或上一帧）是纯 2D 帧（像素正交按场景改写了，或原比例回退中本该改写）：1 = 是。调用方据此决定给哪张目标放哨兵、采不采两侧覆盖
int s2a_widen_pure2d(void);

// ---------- 6. 离线（出包 / 着色器库构建时调；不在渲染路径） ----------
// 顶点着色器 SPIR-V 的越界外推改写（同通用模式 WidenShaders.Vertex，离线预编与运行时同一份字节）。
// 返回改写后的字节数：0 = 不改（原样用）；> cap = 暂存区不够，按返回值重给一次。改了的着色器登记时带 S2A_WIDEN_SH_PUSH，
// 并要求运行时把 s2a_widen_draw_out.push 交给它（通用模式走支持缓冲 s2a_widen 字段；直连的传参方式由直连线 / 着色器线定）。
size_t s2a_widen_spirv_vertex(const void *spv, size_t len, void *out, size_t cap);
// 注意：顶点改写要求 SPIR-V 的支持缓冲里有 s2a_widen 成员（Ryujinx 补丁 0066 加的）；直连离线链翻译器副本的 SupportBuffer 没有它，不补就恒返回 0（不改）。
// 着色器 SPIR-V 的常量读法（SpirvCbufUse），一行文本（格式见 graphics/widen/SpirvCbufUseText.cs），写进离线表、运行时原样交给 s2a_widen_shader。
// slot_of_binding[SPIR-V 绑定号] = 常量槽号（NULL = 绑定号就是槽号；映射为负的跳过）。返回字节数（含结尾 0；> cap 同上）。
size_t s2a_widen_spirv_cbuf_use(const void *spv, size_t len, const int32_t *slot_of_binding, int nmap, char *out, size_t cap);

// ---------- 诊断 ----------
// 几何判据（11-06）：收缩 + 推满只给两侧都贴画布边的整画布层。key = 顶点着色器键（切片按它缓存），slice = 直连库 json pos_slice 解出的字节；
//   vids = 本笔要算的顶点号（≤ 64，非索引 first + k，索引 = 索引值 + base_vertex），inst = 实例号；env 两个回调读顶点属性原始位 / 常量字（读到返回 1）。
//   返回 1 铺满（NDC x 两侧到 ±1）、0 只盖部分、−1 判不出；mnmx 可空，写 NDC 最小 / 最大
typedef struct { int (*attr)(void *u, int location, int lane, uint32_t vid, uint32_t iid, uint32_t *bits); int (*ubo)(void *u, int binding, int offset, uint32_t *bits); void *u; } s2a_widen_geom_env;
int s2a_widen_geom(uint64_t key, const uint8_t *slice, int len, const uint32_t *vids, int n, uint32_t inst, const s2a_widen_geom_env *env, float *mnmx);
// 核心在「原尺寸居中层收缩」候选笔上回调宿主要本笔几何结论：1 / 0 / −1 同 s2a_widen_geom，−2 = 这支顶点着色器没有位置切片（照旧收缩）
void s2a_widen_set_geom_cb(int (*cb)(void));
char *s2a_widen_geom_why(void);     // 上一次 s2a_widen_geom 返回 −1 的原因（UTF-8）
uint64_t s2a_widen_alloc_bytes(void);     // 调用线程累计托管分配字节（GC.GetAllocatedBytesForCurrentThread）
int s2a_widen_report(char *buf, int cap); // 一行中文统计（命中种类、绘制分类、红项、异常），返回写入字节数（不含结尾 0）

#ifdef __cplusplus
}
#endif

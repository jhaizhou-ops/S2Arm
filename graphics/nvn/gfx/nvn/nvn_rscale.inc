// S2Arm 内部分辨率（S2A_RES_SCALE < 1，10-30 帧率能耗线；语义照 Ryujinx 分辨率缩放，MIT）：可缩的渲染目标的 Metal 存储按比例 s 缩小，游戏看不见（贴图查询、
//   游戏常量、游戏坐标都是原尺寸），换算只在回放层碰 Metal 的地方做：视口 / 裁剪 / 清除区域、片元坐标与取图倍率（支持缓冲 render_scale / render_scale_y）、
//   拷贝区域、CPU 读写、上屏裁剪。比例为 1（缺省）时这里每个入口第一句就返回，行为与没有本文件时逐字节相同。
// 单位：游戏坐标 →（宽屏层换算）→ 画布坐标 →（× s）→ 存储坐标。画布 = 不缩时这张存储该有的尺寸（宽屏放宽过的就是放宽尺寸），存储 = ⌈画布 × s⌉（Ryujinx GetCreateInfo 取整）。
// 哪些存储缩（rs_eligible，同 Ryujinx IsUpscaleCompatible + UpscaleSafeMode，再加直连自己的条件）：
//   - 游戏标了可压缩（NVN 给渲染目标的标志）、没标上屏 / 视频解码 / 线性 / 稀疏；二维、二维数组、矩形（不缩多重采样：缩放拷贝画不了它）；
//     建时的存储图像标志不再算在内（Ryujinx 没有建时标志）：真被存储图像槽绑上时才退回 / 记成不缩，见下面「退回原尺寸」；
//   - 缩放拷贝两个方向都画得了的格式（copy_t2t_draw：浮点 / 归一化颜色、D32F、D32F+S8；不缩整数格式和 D16）；不是随包 / 缓冲 / 视图 / 压缩 / 3D（tex_widen_why）；
//   - Ryujinx 安全尺寸：级数 ≤ 3、宽高 ≥ 8、非深度且多通道的不缩方形、高 < 360 的 16:9 不缩（模糊 / 泛光）、宽 = 高² 的不缩（二维当三维的查色表）。
// 什么时候缩：第一次当渲染目标时（rs_rts，开遍前；同 Ryujinx「可缩 → 当目标时缩」），同一遍的附件比例一致：有一个不可缩 / 被拉黑，全遍退回 1。
// 退回原尺寸（拉黑，Ryujinx BlacklistScale）：缩放图被顶点 / 计算阶段读、被存储图像槽绑、被句柄数组读、被不精确的片元着色器（scale_exact ≠ 1）读、
//   被缓冲 → 贴图拷贝写（CPU 写入：Ryujinx 部分写入即拉黑）、当多重采样解析的目标。前三类是绑定时发现的，记进待办，下一个安全点（开遍前 / 派发前）就换回原尺寸存储。
//   存储图像槽这一类不等下一个安全点：图像读写用游戏坐标的整数纹素，落在缩过的存储上位置全错。用它的绘制 / 派发开始之前就换回（rs_pre_draw / rs_pre_images，
//     同 Ryujinx CommitImageBindings → UpdateScale 在画之前同步拉黑）；还没缩过的记成不缩，以后当渲染目标也不缩；片元阶段写存储图像的绘制，本遍附件也退回（rs_pre_draw）。
// 放大（S2A_RES_SCALE > 1，上限 4；11-12）：同一套机制，存储 = ⌈画布 × s⌉，上面「缩」读作「按比例换存储」。与缩小不同的只有这几处：
//   - 方形的存储一律不放大，深度 / 单通道也不放大（比 Ryujinx 严：方形多半是阴影图 / 查找表，4096x4096 放大 2 倍边长多占约 256 MB、对清晰度没用）；缩小时方形规则照旧；
//   - 放大后任一边超过设备贴图上限（rs_tex_max）的不放大；多重采样照旧不缩放；
//   - 上屏标志（窗口贴图）放大时不再否决：它也按倍率建存储，放大的像素一路带到上屏（Ryujinx 没有这个标志，Window.Present 用 WithUpscale 取贴图、裁剪 × ScaleFactor）。
//     上屏那一段在 nvn_mtl.m present_now：游戏给的裁剪、满屏判据、无窗口抓图的尺寸按画布（游戏）尺寸算，交给上屏编码之前才换成存储纹素（左上向下、右下向上取整）；
//     截图（shot）线性缩回游戏尺寸；上屏抗锯齿的中间图取存储与出图视口里小的那个（rs_aa_crop）；MetalFX 只在存储比视口小时建（present_fx_for 原有的判断）；
//     已放大的图拷进还没定比例的窗口贴图时窗口贴图先放大（copy_t2t → rs_copy_up；Ryujinx TwodClass：目标按来源的缩放模式建）。
//     缩小（< 1）时上屏标志照旧否决：现有行为是场景缩、最后一遍与界面在原尺寸的窗口贴图上画，改成也缩会让界面跟着糊，不动；
//   - 游戏坐标读回（ReadTexels / CopyTextureToBuffer）线性缩回游戏尺寸（Ryujinx CopyTo(linear)），深度取最近纹素；
//   - 张量核网络顶替 / DLSS 求值按存储尺寸的比值配 MetalFX：它们读写的放大图先退回原尺寸（nvn_mtl.m dispatch / nvn_dlss.inc dlss_eval）。
#import <objc/runtime.h>

static double g_rs = -1;   // 设定比例（S2A_RES_SCALE；1 = 关）
static double rs_setting(void) {
    if (g_rs < 0) {
        const char *e = getenv("S2A_RES_SCALE"); double v = e && *e ? atof(e) : 1.0;
        if (!(v > 0)) v = 1.0;
        if (v > 4.0) { MLOG("内部分辨率：S2A_RES_SCALE=%s 大于 4，按 4", e); v = 4.0; }   // 大于 1 不再按 1（放大），上限 4
        if (v < 0.25) { MLOG("内部分辨率：S2A_RES_SCALE=%s 小于 0.25，按 0.25", e); v = 0.25; }
        g_rs = v;
        if (v < 1.0) MLOG("内部分辨率：可缩的渲染目标按 %.3f 画（S2A_RES_SCALE；游戏看不见，上屏放大回来）", v);
        else if (v > 1.0) MLOG("内部分辨率：可放大的渲染目标按 %.3f 倍画（S2A_RES_SCALE；游戏看不见，窗口贴图也按倍率画、上屏按存储尺寸取）", v);
    }
    return g_rs;
}
static inline int rs_on(void) { return (g_rs < 0 ? rs_setting() : g_rs) != 1.0; }   // 原为 < 1（只缩小）
static inline int rs_up_on(void) { return (g_rs < 0 ? rs_setting() : g_rs) > 1.0; }   // 放大
// 设备的二维贴图边长上限。Metal 没有查询接口，按苹果的特性表认 GPU 家族：Apple3 起（A9）与 Mac2 是 16384，更早的 8192。g_rs_texmax 非 0 = 单测调小的上限
static int g_rs_texmax;
static NSUInteger rs_tex_max(void) {
    if (g_rs_texmax > 0) return (NSUInteger)g_rs_texmax;
    static NSUInteger m; if (!m) m = [g_dev supportsFamily:MTLGPUFamilyApple3] || [g_dev supportsFamily:MTLGPUFamilyMac2] ? 16384 : 8192;
    return m;
}

// 每份存储的缩放记录挂在 Metal 根贴图上（关联对象：存储释放时一起走，地址复用不会认错）
enum { RS_NONE = 0, RS_SCALED = 1, RS_BLACK = 2 };
@interface NvRsInfo : NSObject { @public int state; NSUInteger cw, ch; int fails; } @end   // fails = 这份缩放存储退回原尺寸失败过几次（rs_rescale_failed）
@implementation NvRsInfo @end
static char k_rs_info;
static id<MTLTexture> rs_root(id<MTLTexture> t0) { id<MTLTexture> t = t0; while (t.parentTexture) t = t.parentTexture; return t; }
static NvRsInfo *rs_info(id<MTLTexture> t) { return t ? objc_getAssociatedObject(rs_root(t), &k_rs_info) : nil; }
static int rs_state(id<MTLTexture> t) { if (!t || !rs_on()) return RS_NONE; NvRsInfo *i = rs_info(t); return i ? i->state : RS_NONE; }
static void rs_set_info(id<MTLTexture> t, int state, NSUInteger cw, NSUInteger ch) {
    NvRsInfo *i = [NvRsInfo new]; i->state = state; i->cw = cw; i->ch = ch;
    objc_setAssociatedObject(rs_root(t), &k_rs_info, i, OBJC_ASSOCIATION_RETAIN);
}
// 退回原尺寸失败满 RS_FAIL_MAX 次的缩放存储不再试（rs_rescale 直接返回、rs_image_slots 不再排队）：每试一次要建一份新存储，
//   存储图像槽上的这种图每次绘制 / 派发都会被扫到，不限次就是每次绘制建一份。3 次：建不出多半是一时的内存压力，留两次重试；缩放拷贝画不了是确定性的，多试无益
enum { RS_FAIL_MAX = 3 };
static int rs_stuck(id<MTLTexture> t) { NvRsInfo *i = rs_info(t); return i && i->state == RS_SCALED && i->fails >= RS_FAIL_MAX; }
// 这份存储相对画布的比例（没缩 = 1）
static double rs_of(id<MTLTexture> t) { return rs_state(t) == RS_SCALED ? g_rs : 1.0; }
// 画布尺寸（第 level 级，相对 t 自己的级；没缩 = 存储尺寸）
static NSUInteger rs_mip(NSUInteger v, NSUInteger level) { return level < sizeof(v) * 8 ? MAX(v >> level, 1u) : 1; }
static void rs_canvas(id<MTLTexture> t, NSUInteger level, NSUInteger *w, NSUInteger *h) {
    NvRsInfo *i = rs_state(t) == RS_SCALED ? rs_info(t) : nil;
    if (!i) { *w = rs_mip(t.width, level); *h = rs_mip(t.height, level); return; }
    NSUInteger rl = level; for (id<MTLTexture> p = t; p.parentTexture; p = p.parentTexture) rl += p.parentRelativeLevel;
    *w = rs_mip(i->cw, rl); *h = rs_mip(i->ch, rl);
}
// 这个对象（贴图或视图）自己第 0 级的画布宽 / 高（宽屏胶水比较「放没放宽」用画布，不用存储）
static NSUInteger rs_cw(id<MTLTexture> t) { NSUInteger w, h; if (!t) return 0; rs_canvas(t, 0, &w, &h); return w; }
static NSUInteger rs_ch(id<MTLTexture> t) { NSUInteger w, h; if (!t) return 0; rs_canvas(t, 0, &w, &h); return h; }
static NSUInteger rs_up(NSUInteger v, double s) { NSUInteger r = (NSUInteger)ceil((double)v * s - 1e-9); return r ? r : 1; }   // Ryujinx：⌈v·s⌉
// 画布矩形 → 存储矩形（起点向下取整、终点向上取整，盖住画布矩形碰到的每个存储像素；同 Ryujinx 裁剪缩放）
static void rs_rect(double s, long *x, long *y, long *w, long *h) {
    if (s == 1.0) return;
    long x0 = (long)floor(*x * s), y0 = (long)floor(*y * s), x1 = (long)ceil((*x + *w) * s - 1e-9), y1 = (long)ceil((*y + *h) * s - 1e-9);
    *x = x0; *y = y0; *w = x1 - x0; *h = y1 - y0;
}

static const char *tex_widen_why(const tex_t *t);
static int fmt_int_or_ds(MTLPixelFormat f);
static void rs_report(uint64_t frame);   // 覆盖面读数（nvn_rscale_ops.inc；nvn_be_mem_stat 每 300 帧调）
static id<MTLTexture> rs_rescale(id<MTLTexture> base, int to_scaled, const char *why);   // nvn_rscale_ops.inc（tex_widen 在放大超过贴图上限时先退回原尺寸）
// 单通道颜色格式（Ryujinx 不缩方形的规则对它放行，同深度）
static int rs_one_comp(MTLPixelFormat f) {
    switch (f) { case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm: case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Float: case MTLPixelFormatR32Float: case MTLPixelFormatA8Unorm: return 1; default: return 0; }
}
// 这张贴图的存储能不能缩（见文件头）；why 给不能缩的原因（日志用）
static int rs_eligible(const tex_t *t, id<MTLTexture> base, const char **why) {
    const char *w = NULL;
    // 建时的存储图像标志（NVN_TEXTURE_FLAGS_IMAGE，只是「可以当存储图像绑」的能力）不再判不可缩：Ryujinx 没有建时标志，拉黑在绑定 / 使用时
    //   （TextureBindingsManager.UpdateScale → BlacklistScale）。真被当存储图像用的退回原尺寸：rs_pre_draw / rs_pre_images / rs_bind_check（nvn_rscale_ops.inc）
    uint32_t bad = NVN_TEXTURE_FLAGS_DISPLAY | NVN_TEXTURE_FLAGS_VIDEO_DECODE | NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_SPARSE | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET;
    if (g_rs > 1.0) bad &= ~(uint32_t)NVN_TEXTURE_FLAGS_DISPLAY;   // 放大时窗口贴图也按倍率建存储（见文件头；缩小时照旧否决）
    if (!t || !base) { if (why) *why = "没有存储"; return 0; }
    MTLPixelFormat pf = base.pixelFormat; int depth = pf == MTLPixelFormatDepth32Float || pf == MTLPixelFormatDepth32Float_Stencil8;
    NSUInteger gw = t->d.width, gh = t->d.height;
    if (!(t->d.flags & NVN_TEXTURE_FLAGS_COMPRESSIBLE) || (t->d.flags & bad)) w = "标志（不可压缩 / 上屏 / 视频 / 线性 / 稀疏）";
    else if (t->d.target != NVN_TEXTURE_TARGET_2D && t->d.target != NVN_TEXTURE_TARGET_2D_ARRAY && t->d.target != NVN_TEXTURE_TARGET_RECTANGLE) w = "类型（只缩二维 / 二维数组 / 矩形）";
    else if (base.sampleCount > 1 || base.parentTexture || base.buffer) w = "多重采样 / 视图 / 缓冲";
    else if (tex_widen_why(t)) w = tex_widen_why(t);
    else if (!depth && fmt_int_or_ds(pf)) w = "格式（整数 / D16 / 只有模板：缩放拷贝画不了）";
    else if ((t->d.levels ? t->d.levels : 1) > 3) w = "级数 > 3（多半是游戏贴图）";
    else if (gw < 8 || gh < 8) w = "太小";
    else if (g_rs > 1.0 && gw == gh) w = "方形（放大时一律不放大）";   // 放大时深度 / 单通道的方形也不放大（见文件头）
    else if (!depth && !rs_one_comp(pf) && gw == gh) w = "方形";
    else if (gh < 360 && fabs((double)gw - gh * 16.0 / 9.0) <= 16) w = "高 < 360 的 16:9（模糊 / 泛光）";
    else if (gw == gh * gh) w = "宽 = 高²（查色表）";
    // 放大后的存储 ⌈画布 × s⌉（此时还没缩放，画布 = 这份存储的尺寸，宽屏放宽过的就是放宽尺寸）任一边超过设备上限：建不出来（Metal 断言），不放大
    else if (g_rs > 1.0 && (rs_up(base.width, g_rs) > rs_tex_max() || rs_up(base.height, g_rs) > rs_tex_max())) w = "放大后超过贴图上限";
    if (why) *why = w;
    return !w;
}

// NVN2（Switch 2）nvnCommandBufferEvaluateDlss 的回放：DLSS 时域超分换成 MetalFX 时域放大（MTLFXTemporalScaler，iOS 16 / macOS 13 起，Metal 4 走 MTL4FX 接口）。
// 两者输入一一对应：输入色 / 深度 / 运动向量 / 输出色四张图，抖动、运动向量缩放、预曝光、历史重置、输入内容尺寸（子矩形大小）、深度反向（网络标志第 3 位）。
// 不做就没有 3D 场景：火纹 Fortune's Weave 960x540 的场景经这一遍放进 1920x1080 的输出图（11-03 Mac 局 fe_dl1 第 9000 帧：输出图 ser=5930 本帧先被采样、之前没人写），
//   之后的后处理、界面层都画在它上面——没有这一遍时剧情对话背景全黑、捏人页背景全白没有角色。
// 放大器每个网络对象一个（历史随网络：驱动按输出尺寸 / 预设给网络算的那块存储就是它的历史）；求值序号只选「求值条目」（每条 0x10000 字节的每次求值参数区，
//   让几次求值同时在飞），不分历史——火纹的最多条目是 2、序号 0 / 1 交替用，按序号分放大器会让每个只见隔一帧的画面。图的格式 / 尺寸变了才重建。放大倍数超出 MetalFX 时域放大的上限
//   （supportedInputContentMaxScale，M5 Max 实测 3）时退到 MetalFX 空间放大，报红一次。子矩形起点非 0 的情况 MetalFX 不支持（它从原点读写），报红一次照原点做。
// 顺序：前后各一个空的拷贝编码器（自带队列级全屏障，blit / enc_close_blit），保证「场景各遍 → MetalFX → 后处理」按序；放大器另带一个栅栏
//   （Metal 4 不带时校验层断言，同上屏放大 nvn_present_fx.inc；Metal 3 用 g_fence3，与回放各编码器同一个栅栏）。
// 编码线程（DM_NVN_ENC_THREAD，iOS 缺省开）：放大器与四张图、参数录成一条 RO_FX，在编码线程上设属性、编码进真的命令缓冲（nvn_rec.h）。
// 不链 MetalFX 框架：类按名字取（首次 dlopen 系统框架，同 nvn_present_fx.inc）；没有 MetalFX 的设备报红一次、这一遍不做。
@interface NvDlss : NSObject {
@public
    id scaler; BOOL spatial, m4;
    uint64_t net;
    MTLPixelFormat cf, df, mf, of; NSUInteger iw, ih, ow, oh; uint32_t flags;
}
@end
@implementation NvDlss @end
static NvDlss *g_dlss[4];
static uint64_t g_dlss_evals, g_dlss_skips;

static Class dlss_class(const char *name) {
    static int opened; if (!opened) { opened = 1; dlopen("/System/Library/Frameworks/MetalFX.framework/MetalFX", RTLD_LAZY); }
    Class c = NSClassFromString(@(name));
    return c && [c supportsDevice:g_dev] ? c : nil;
}
static NvDlss *dlss_scaler(const p_dlss *d, id<MTLTexture> c, id<MTLTexture> dp, id<MTLTexture> mv, id<MTLTexture> o, NSUInteger cw, NSUInteger ch) {
    BOOL m4 = !g_m3; int free_i = -1, hit = -1;
    for (int i = 0; i < 4; i++) { if (!g_dlss[i]) { if (free_i < 0) free_i = i; continue; } if (g_dlss[i]->net == d->network) hit = i; }
    NvDlss *f = hit >= 0 ? g_dlss[hit] : nil;
    if (f && f->m4 == m4 && f->cf == c.pixelFormat && f->df == dp.pixelFormat && f->mf == mv.pixelFormat && f->of == o.pixelFormat && f->iw == c.width && f->ih == c.height
        && f->ow == o.width && f->oh == o.height && f->flags == d->flags) return f;
    int slot = hit >= 0 ? hit : free_i >= 0 ? free_i : (int)(g_dlss_evals % 4);
    Class tc = dlss_class("MTLFXTemporalScalerDescriptor");
    if (!tc) { RED_ONCE(143, "DLSS：这台设备没有 MetalFX 时域放大，这一遍不做（场景不会进输出图）"); return nil; }
    float maxs = [tc supportedInputContentMaxScaleForDevice:g_dev];
    double need = MAX((double)o.width / (double)MAX(cw, 1u), (double)o.height / (double)MAX(ch, 1u));
    id sc = nil; BOOL spatial = NO;
    if (need <= maxs + 1e-3) {
        MTLFXTemporalScalerDescriptor *td = [tc new];
        td.colorTextureFormat = c.pixelFormat; td.depthTextureFormat = dp.pixelFormat; td.motionTextureFormat = mv.pixelFormat; td.outputTextureFormat = o.pixelFormat;
        td.inputWidth = c.width; td.inputHeight = c.height; td.outputWidth = o.width; td.outputHeight = o.height;
        // 输入内容尺寸逐帧给（子矩形大小，动态分辨率）：比例范围放到设备上限
        td.inputContentPropertiesEnabled = YES; td.inputContentMinScale = 1.0f; td.inputContentMaxScale = maxs;
        td.autoExposureEnabled = (d->flags & DLF_AUTO_EXPOSURE) != 0;
        if (m4) { if (@available(macOS 26.0, iOS 26.0, *)) { id comp = present_fx_compiler(); if (comp) sc = [td newTemporalScalerWithDevice:g_dev compiler:comp]; } }
        else sc = [td newTemporalScalerWithDevice:g_dev];
        if (sc) [(id<MTLFXTemporalScalerBase>)sc setDepthReversed:(d->flags & DLF_DEPTH_INVERTED) != 0];
    }
    if (!sc) {
        Class scl = dlss_class("MTLFXSpatialScalerDescriptor");
        RED_ONCE(144, "DLSS：%lux%lu → %lux%lu 要放大 %.2f 倍，MetalFX 时域放大做不了（上限 %.2f 倍 / 格式 色 %lu 深 %lu 动 %lu 出 %lu），改用 MetalFX 空间放大（没有历史累积，画面更软）",
                 (unsigned long)cw, (unsigned long)ch, (unsigned long)o.width, (unsigned long)o.height, need, maxs, (unsigned long)c.pixelFormat, (unsigned long)dp.pixelFormat,
                 (unsigned long)mv.pixelFormat, (unsigned long)o.pixelFormat);
        if (scl) {
            MTLFXSpatialScalerDescriptor *sd = [scl new];
            sd.colorTextureFormat = c.pixelFormat; sd.outputTextureFormat = o.pixelFormat; sd.inputWidth = c.width; sd.inputHeight = c.height; sd.outputWidth = o.width; sd.outputHeight = o.height;
            sd.colorProcessingMode = d->flags & DLF_LDR ? MTLFXSpatialScalerColorProcessingModePerceptual : MTLFXSpatialScalerColorProcessingModeHDR;
            if (m4) { if (@available(macOS 26.0, iOS 26.0, *)) { id comp = present_fx_compiler(); if (comp) sc = [sd newSpatialScalerWithDevice:g_dev compiler:comp]; } }
            else sc = [sd newSpatialScalerWithDevice:g_dev];
            spatial = sc != nil;
        }
    }
    if (!sc) { RED_ONCE(145, "DLSS：建 MetalFX 放大器失败（%lux%lu → %lux%lu 格式 色 %lu 深 %lu 动 %lu 出 %lu），这一遍不做", (unsigned long)c.width, (unsigned long)c.height,
                        (unsigned long)o.width, (unsigned long)o.height, (unsigned long)c.pixelFormat, (unsigned long)dp.pixelFormat, (unsigned long)mv.pixelFormat, (unsigned long)o.pixelFormat); return nil; }
    // 放大器自己的栅栏：Metal 4 不带时校验层断言（同 nvn_present_fx.inc），前后顺序由两侧的队列级全屏障保证；Metal 3 用回放各编码器同一个 g_fence3
    id<MTLFence> fence = m4 ? [g_dev newFence] : g_fence3;
    if (spatial) [(id<MTLFXSpatialScalerBase>)sc setFence:fence]; else [(id<MTLFXTemporalScalerBase>)sc setFence:fence];
    if (g_dlss[slot]) defer_obj_unref(g_dlss[slot]->scaler);   // 在飞的命令缓冲可能还在用：等它们完成再放
    f = [NvDlss new];
    f->scaler = sc; f->spatial = spatial; f->m4 = m4; f->net = d->network; f->flags = d->flags;
    f->cf = c.pixelFormat; f->df = dp.pixelFormat; f->mf = mv.pixelFormat; f->of = o.pixelFormat; f->iw = c.width; f->ih = c.height; f->ow = o.width; f->oh = o.height;
    g_dlss[slot] = f;
    MLOG("DLSS → MetalFX %s放大（%s）：网络 %#llx，输入 %lux%lu（内容 %lux%lu）格式 色 %lu 深 %lu 动 %lu → 输出 %lux%lu 格式 %lu，深度%s，网络输出 %dx%d 方法 %d 标志 %#x",
         spatial ? "空间" : "时域", m4 ? "Metal 4" : "Metal 3", (unsigned long long)d->network, (unsigned long)c.width, (unsigned long)c.height, (unsigned long)cw, (unsigned long)ch,
         (unsigned long)c.pixelFormat, (unsigned long)dp.pixelFormat, (unsigned long)mv.pixelFormat, (unsigned long)o.width, (unsigned long)o.height, (unsigned long)o.pixelFormat,
         d->flags & DLF_DEPTH_INVERTED ? "反向" : "正向", d->out_w, d->out_h, d->method, d->flags);
    return f;
}
// 设属性并编码（提交线程直接调，或编码线程放 RO_FX 时调）：a[0] 放大器，a[1..4] 色 / 深 / 动 / 出，a[5..9] 抖动 xy、运动向量缩放 xy、预曝光（rec_f），a[10] 重置，a[11..12] 内容宽高，a[13] 空间放大
static void dlss_fx_run(id cb, const uint64_t *a) {
    id s = rec_id(a[0]);
    if (a[13]) {
        id<MTLFXSpatialScalerBase> sp = s;
        sp.colorTexture = rec_id(a[1]); sp.outputTexture = rec_id(a[4]); sp.inputContentWidth = a[11]; sp.inputContentHeight = a[12];
    } else {
        id<MTLFXTemporalScalerBase> t = s;
        t.colorTexture = rec_id(a[1]); t.depthTexture = rec_id(a[2]); t.motionTexture = rec_id(a[3]); t.outputTexture = rec_id(a[4]);
        t.jitterOffsetX = rec_fv(a[5]); t.jitterOffsetY = rec_fv(a[6]); t.motionVectorScaleX = rec_fv(a[7]); t.motionVectorScaleY = rec_fv(a[8]); t.preExposure = rec_fv(a[9]);
        t.reset = a[10] != 0; t.inputContentWidth = a[11]; t.inputContentHeight = a[12];
    }
    [(id)s encodeToCommandBuffer:cb];
}
// 这张图满足放大器要的用途（读 / 写 / 渲染目标），不满足就升级（tex_upgrade：同格式同尺寸新建、拷内容、换进序号表）
static id<MTLTexture> dlss_usage(const tex_t *t, id<MTLTexture> m, MTLTextureUsage need) { return (m.usage & need) == need ? m : tex_upgrade(t, m, need & ~m.usage, m.pixelFormat); }
static void dlss_eval(const p_dlss *d, uint32_t size) {
    (void)size;
    const tex_t *tc = d->tex[DLT_COLOR], *to = d->tex[DLT_OUTPUT], *td = d->tex[DLT_DEPTH], *tm = d->tex[DLT_MOTION];
    id<MTLTexture> c = tc ? tex_mtl(tc) : nil, o = to ? tex_mtl(to) : nil, dp = td ? tex_mtl(td) : nil, mv = tm ? tex_mtl(tm) : nil;
    PD("L %llu dlss color=%llu depth=%llu motion=%llu output=%llu in=%dx%d jitter=%g,%g mv=%g,%g reset=%d index=%d", g_stat_pass, tc ? (unsigned long long)tc->serial : 0ull,
       td ? (unsigned long long)td->serial : 0ull, tm ? (unsigned long long)tm->serial : 0ull, to ? (unsigned long long)to->serial : 0ull, d->in_w, d->in_h,
       d->jitter[0], d->jitter[1], d->mv_scale[0], d->mv_scale[1], d->reset, d->index);
    if (!c || !o || !dp || !mv) { g_dlss_skips++; RED_ONCE(146, "DLSS：求值缺图（色 %d 出 %d 深 %d 动 %d），这一遍不做", c != nil, o != nil, dp != nil, mv != nil); return; }
    for (int k = 0; k < DLT_N; k++) if (d->has_view[k] && (d->view[k].set_levels || d->view[k].set_layers || d->view[k].set_format)) {
        static int once; if (!once++) MLOG("【红】 DLSS：第 %d 张图带视图（层级 / 层 / 格式），MetalFX 用整张图的第 0 级", k); break; }
    for (int k = 0; k < 5; k++) if (d->base[k][0] || d->base[k][1]) {
        static int once; if (!once++) MLOG("【红】 DLSS：子矩形起点 %d,%d（第 %d 项）不是原点，MetalFX 从原点读写", d->base[k][0], d->base[k][1], k); break; }
    // 内容尺寸：子矩形大小（0 = 输入图的游戏尺寸），换到存储尺寸（满屏放宽 / 内部分辨率会改存储，与 copy_t2t 同口径）
    NSUInteger gw = d->in_w > 0 ? (NSUInteger)d->in_w : tc->d.width, gh = d->in_h > 0 ? (NSUInteger)d->in_h : tc->d.height;
    NSUInteger cw = MIN(c.width, (NSUInteger)llround((double)gw * c.width / MAX(tc->d.width, 1u))), ch = MIN(c.height, (NSUInteger)llround((double)gh * c.height / MAX(tc->d.height, 1u)));
    if (d->out_w > 0 && d->out_h > 0 && ((NSUInteger)d->out_w < o.width || (NSUInteger)d->out_h < o.height)) {
        static int once; if (!once++) MLOG("【红】 DLSS：网络输出 %dx%d 小于输出图 %lux%lu，MetalFX 写满整张输出图", d->out_w, d->out_h, (unsigned long)o.width, (unsigned long)o.height); }
    NvDlss *f = dlss_scaler(d, c, dp, mv, o, cw, ch);
    if (!f) { g_dlss_skips++; return; }
    id<MTLFXTemporalScalerBase> ts = f->spatial ? nil : f->scaler; id<MTLFXSpatialScalerBase> ss = f->spatial ? f->scaler : nil;
    c = dlss_usage(tc, c, ts ? ts.colorTextureUsage : ss.colorTextureUsage);
    o = dlss_usage(to, o, ts ? ts.outputTextureUsage : ss.outputTextureUsage);
    if (ts) { dp = dlss_usage(td, dp, ts.depthTextureUsage); mv = dlss_usage(tm, mv, ts.motionTextureUsage); }
    zskip_del(to->serial);
    pkg_gpu_wrote(to, 0, 0, 1, 0, 0, (uint32_t)to->d.width, (uint32_t)to->d.height);
    if (g_wd > 0) { pthread_mutex_lock(&g_wd_mu); s2a_widen_gpu_wrote((uint32_t)to->serial, (uint32_t)tc->serial); pthread_mutex_unlock(&g_wd_mu); }
    // 前一侧的全屏障：一个空的拷贝编码器（开时等此前全部工作、关时让此后全部等它），MetalFX 的编码器排在它之后
    rp_flush(); (void)blit(); enc_close_blit();
    uint64_t a[15] = {0};
    a[5] = rec_f(d->jitter[0]); a[6] = rec_f(d->jitter[1]); a[7] = rec_f(d->mv_scale[0]); a[8] = rec_f(d->mv_scale[1]); a[9] = rec_f(d->pre_exposure);
    a[10] = d->reset; a[11] = cw; a[12] = ch; a[13] = f->spatial;
    if (rec_on()) {   // 编码线程：放大器与四张图由记录持有到调用完
        rec_t *r = rec_put(RO_FX, 5); memcpy(r->a, a, sizeof a);
        r->a[0] = rec_obj(f->scaler); r->a[1] = rec_obj(c); r->a[2] = rec_obj(ts ? dp : nil); r->a[3] = rec_obj(ts ? mv : nil); r->a[4] = rec_obj(o);
    } else {
        a[0] = (uint64_t)(__bridge void *)f->scaler; a[1] = (uint64_t)(__bridge void *)c; a[2] = (uint64_t)(__bridge void *)dp; a[3] = (uint64_t)(__bridge void *)mv; a[4] = (uint64_t)(__bridge void *)o;
        dlss_fx_run(g_cb, a);
    }
    // 后一侧：下一个编码器开时做全屏障（不按放宽的上一遍结尾算），也不沿用「上一编码器已全屏障」的证明
    g_last_end_relaxed = 0; main_barrier_reset();
    g_dlss_evals++;
}

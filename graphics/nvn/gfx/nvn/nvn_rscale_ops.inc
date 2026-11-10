// S2Arm 内部分辨率的动作（状态与判定见 nvn_rscale.inc）：换存储（缩放 / 退回原尺寸）、开遍前定比例、待退回队列、片元支持缓冲的倍率副本、计算派发前的检查。
// 由 nvn_mtl.m 在 widen_glue.inc 之后 #include（要用回放层的 R / S / g_pass / arena_alloc 与宽屏胶水的 wd_tex_scales / g_wd_rs_gpu）。比例为 1 时每个入口第一句返回。
static int copy_t2t_draw(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror);
static uint64_t g_rs_up, g_rs_down, g_rs_fail;   // 缩了 / 退回原尺寸 / 换存储失败的存储数（日志）

// 把存储 base 换成按画布 × s（to_scaled）或画布原尺寸的新存储，内容用缩放拷贝带过去（Ryujinx SetScale：GetScaledHostTexture(copy) + ReplaceStorage），
//   所有表里指向旧存储的项换成新的（tex_swap_storage）。只在没有开着的渲染遍时调（copy_t2t_draw 自己收遍）。失败 = 旧存储不动、记成不缩（以后不再试）。返回新存储
static id<MTLTexture> rs_rescale(id<MTLTexture> base, int to_scaled, const char *why) {
    NvRsInfo *i = rs_info(base);
    NSUInteger cw = i && i->state == RS_SCALED ? i->cw : base.width, ch = i && i->state == RS_SCALED ? i->ch : base.height;
    NSUInteger w = to_scaled ? rs_up(cw, g_rs) : cw, h = to_scaled ? rs_up(ch, g_rs) : ch;
    if (w == base.width && h == base.height) { rs_set_info(base, to_scaled ? RS_SCALED : RS_BLACK, cw, ch); return base; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = base.textureType; d.pixelFormat = base.pixelFormat; d.width = w; d.height = h; d.depth = base.depth;
    d.arrayLength = base.arrayLength; d.mipmapLevelCount = base.mipmapLevelCount; d.sampleCount = base.sampleCount;
    d.storageMode = base.storageMode; d.cpuCacheMode = base.cpuCacheMode; d.hazardTrackingMode = base.hazardTrackingMode; d.resourceOptions = base.resourceOptions;
    // 新存储一定当渲染目标用（缩放拷贝画进去、之后游戏在上面画）：旧存储没有渲染目标用途时补上（打包贴图建时不带，copy_t2t_draw 见目标没有这一用途就画不了，
    //   11-09 #312 暗黑地牢2：1280x720 RG11B10Float 颜色目标「缩放拷贝画不了，不缩」，同遍深度却缩了）
    d.usage = base.usage | (mtl_fmt_block(base.pixelFormat) ? 0 : MTLTextureUsageRenderTarget);
    id<MTLTexture> n = [g_dev newTextureWithDescriptor:d];
    if (!n) { g_rs_fail++; RED_ONCE(114, "内部分辨率：%lux%lu 格式 %lu 的存储换成 %lux%lu 失败（建不出），不缩", (unsigned long)base.width, (unsigned long)base.height, (unsigned long)base.pixelFormat, (unsigned long)w, (unsigned long)h);
        rs_set_info(base, RS_BLACK, 0, 0); return nil; }
    res_add(n);
    for (NSUInteger l = 0; l < base.mipmapLevelCount; l++) {
        NVNcopyRegion sr = {0, 0, 0, (int)rs_mip(base.width, l), (int)rs_mip(base.height, l), (int)base.arrayLength};
        NVNcopyRegion dr = {0, 0, 0, (int)rs_mip(w, l), (int)rs_mip(h, l), (int)base.arrayLength};
        if (!copy_t2t_draw(base, n, (unsigned)l, 0, (unsigned)l, 0, &sr, &dr, 1, 0)) {
            g_rs_fail++; RED_ONCE(115, "内部分辨率：%lux%lu 格式 %lu 的缩放拷贝画不了，不缩（首例）", (unsigned long)base.width, (unsigned long)base.height, (unsigned long)base.pixelFormat);
            defer_obj_release(n); rs_set_info(base, RS_BLACK, 0, 0); return nil; }
    }
    rs_set_info(n, to_scaled ? RS_SCALED : RS_BLACK, cw, ch);
    tex_swap_storage(base, n);
    uint64_t k = to_scaled ? g_rs_up++ : g_rs_down++;
    if (k < 12 || !(k & (k - 1))) MLOG("内部分辨率：存储 %lux%lu 格式 %lu %s %lux%lu（第 %llu 份%s%s）", (unsigned long)base.width, (unsigned long)base.height, (unsigned long)base.pixelFormat,
                                       to_scaled ? "缩到" : "退回原尺寸", (unsigned long)w, (unsigned long)h, (unsigned long long)k + 1, why ? "；" : "", why ? why : "");
    return n;
}

// 待退回队列：绑定时发现缩放图被不支持缩放的地方读写，下一个安全点（开遍前 rs_rts / 派发前 rs_pre_compute）换回原尺寸。根存储去重
enum { RS_BADQ = 64 };
static __strong id<MTLTexture> g_rs_bad[RS_BADQ]; static const char *g_rs_bad_why[RS_BADQ]; static int g_rs_nbad; static pthread_mutex_t g_rs_mu = PTHREAD_MUTEX_INITIALIZER;
static void rs_bad(id<MTLTexture> t, const char *why) {
    if (!t || !rs_on()) return;
    id<MTLTexture> r = rs_root(t);
    if (rs_state(r) != RS_SCALED) return;
    pthread_mutex_lock(&g_rs_mu);
    int k = 0; while (k < g_rs_nbad && g_rs_bad[k] != r) k++;
    if (k == g_rs_nbad && g_rs_nbad < RS_BADQ) { g_rs_bad[g_rs_nbad] = r; g_rs_bad_why[g_rs_nbad++] = why; }
    pthread_mutex_unlock(&g_rs_mu);
}
static void rs_flush(void) {
    if (!rs_on() || !g_rs_nbad) return;
    __strong id<MTLTexture> q[RS_BADQ]; const char *w[RS_BADQ]; int n;
    pthread_mutex_lock(&g_rs_mu); n = g_rs_nbad; for (int k = 0; k < n; k++) { q[k] = g_rs_bad[k]; w[k] = g_rs_bad_why[k]; g_rs_bad[k] = nil; } g_rs_nbad = 0; pthread_mutex_unlock(&g_rs_mu);
    for (int k = 0; k < n; k++) if (rs_state(q[k]) == RS_SCALED) rs_rescale(q[k], 0, w[k]);
}

// 开遍前（rp_begin_ex_，宽屏放宽之后）：本遍颜色 / 深度目标定比例。都可缩（或已缩）→ 没缩的缩；有一个不可缩 / 被拉黑 → 已缩的退回、没定的记不缩（Ryujinx：黑名单在目标间传播）
static void rs_note_skip(const tex_t *t, const char *why) {
    static int n; if (n++ < 16) MLOG("内部分辨率：渲染目标 ser=%llu %ux%u 格式 %#x 标志 %#x 不缩（%s）", (unsigned long long)t->serial, t->d.width, t->d.height, t->d.format, t->d.flags, why ? why : "?");
}
static void rs_rts(void) {
    if (!rs_on()) return;
    rs_flush();
    const tex_t *ts[9]; int n = 0, block = 0;
    for (int i = 0; i < R.rt.n && i < 8; i++) if (R.rt.color[i]) ts[n++] = R.rt.color[i];
    if (R.rt.depth) ts[n++] = R.rt.depth;
    for (int k = 0; k < n; k++) {
        id<MTLTexture> b = tex_mtl(ts[k]); int st = rs_state(b);
        if (!b) continue;
        if (st == RS_BLACK) block = 1;
        else if (st == RS_NONE) { const char *why = NULL; if (!rs_eligible(ts[k], b, &why)) { rs_set_info(b, RS_BLACK, 0, 0); rs_note_skip(ts[k], why); block = 1; } }
    }
    for (int k = 0; k < n; k++) {
        id<MTLTexture> b = tex_mtl(ts[k]); int st = rs_state(b);
        if (!b) continue;
        if (block) { if (st == RS_SCALED) rs_rescale(b, 0, "同一遍有不缩的附件"); else if (st == RS_NONE) rs_set_info(b, RS_BLACK, 0, 0); }
        else if (st == RS_NONE && !rs_rescale(b, 1, NULL)) block = 1;   // 换存储失败（rs_rescale 已把它记成不缩）
    }
    // 同一遍里有附件没缩成：已缩的附件退回原尺寸，同一遍的附件尺寸必须一致（11-09 #312：颜色目标缩放拷贝失败、深度照样缩到一半，同遍尺寸不一，iPhone 上闪粉色块）
    if (block) for (int k = 0; k < n; k++) {
        id<MTLTexture> b = tex_mtl(ts[k]); int st = rs_state(b);
        if (!b) continue;
        if (st == RS_SCALED) rs_rescale(b, 0, "同一遍有附件没缩成"); else if (st == RS_NONE) rs_set_info(b, RS_BLACK, 0, 0);
    }
}

// 片元阶段的支持缓冲（encode_args_ NVN_RB_SUPPORT；调用时已持 g_rmu，所以用 wd_tex_scales_locked——10-30 真机：调加锁版在同一线程上自锁，缩放局第一笔精确着色器的绘制就卡死）：片元坐标倍率 = 宽屏核心给的 × 本遍比例；取图 / 尺寸查询倍率 = 所绑贴图「存储 ÷ 游戏」两轴（wd_tex_scales：宽屏 k 与 s 自然相乘），
//   只在着色器精确（scale_exact 且清单没截断）时写。都是 1 = 照旧（宽屏的副本或静态那份），不另起副本
// cpu（可空）：同时给出这份支持缓冲的 CPU 字节（ABI2 尺寸表 size_abi_begin 以它为底，内部分辨率下片元倍率不丢）
static uint64_t rs_support_cpu(const NvShader *fs, const uint8_t **cpu) {
    uint64_t wd = g_wd > 0 && g_wd_rs_gpu ? g_wd_rs_gpu : 0;
    float f0 = wd ? g_wd_fsc : 1.0f, fy0 = wd ? g_wd_fsyc : 1.0f, f = (float)(f0 * g_pass.rs), fy = (float)(fy0 * g_pass.rs);
    uint8_t ix[72]; float v[72], vy[72]; int n = fs && fs->exact == 1 && !fs->ts_lost ? wd_tex_scales_locked(fs, f, ix, v, fy, vy) : 0;
    int any = f != f0 || fy != fy0; for (int i = 0; i < n; i++) any |= v[i] != 1.0f || vy[i] != 1.0f;
    if (!any) { if (cpu) *cpu = wd ? g_wd_rs_data : support_buf().contents; return wd ? wd : support_gpu(); }
    static uint64_t last_gpu, last_sub; static const uint8_t *last_data; static float lf, lfy, lv[72], lvy[72]; static uint8_t lix[72]; static int ln;
    if (!(last_gpu && last_sub == g_arena_gen && lf == f && lfy == fy && ln == n && !memcmp(lix, ix, (size_t)n) && !memcmp(lv, v, sizeof *v * (size_t)n) && !memcmp(lvy, vy, sizeof *vy * (size_t)n))) {
        id<MTLBuffer> ab; size_t o = arena_alloc(4096, &ab); uint8_t *d = (uint8_t *)ab.contents + o;
        memcpy(d, support_buf().contents, 4096); memcpy(d + 192, &f, 4); memcpy(d + 1440, &fy, 4);   // render_scale[i] 在 192 + 16 i、render_scale_y[i] 在 1440 + 16 i（取 .x），同 wd_rscale
        for (int i = 0; i < n; i++) { memcpy(d + 192 + 16 * ix[i], &v[i], 4); memcpy(d + 1440 + 16 * ix[i], &vy[i], 4); }
        last_gpu = ab.gpuAddress + o; last_data = d; last_sub = g_arena_gen; lf = f; lfy = fy; ln = n; memcpy(lix, ix, (size_t)n); memcpy(lv, v, sizeof *v * (size_t)n); memcpy(lvy, vy, sizeof *vy * (size_t)n);
    }
    if (cpu) *cpu = last_data;
    return last_gpu;
}
static uint64_t rs_support(const NvShader *fs) { return rs_support_cpu(fs, NULL); }
// 绑定时：这张图在这里读写不支持缩放（顶点 / 计算等非片元阶段、不精确的片元着色器、句柄数组、存储图像槽）→ 记进待退回（只对已缩的起作用）
static inline void rs_bind_check(id<MTLTexture> t, const NvShader *sh, int nvn_stage, int kind) {
    if (!t || !rs_on()) return;
    if (kind == 2) rs_bad(t, "绑在存储图像槽");
    else if (kind == 1) rs_bad(t, "被句柄数组读");
    else if (nvn_stage != 1) rs_bad(t, "被顶点 / 计算等非片元阶段读");
    else if (sh->exact != 1 || sh->ts_lost || (sh->size_abi && !sh->size_exact)) rs_bad(t, "被取图倍率不精确的片元着色器读");   // ABI2 非 exact（legacy_1x）同不精确
}
// 计算派发前（dispatch，此时没有开着的遍）：这次派发要读写的缩放图当场换回原尺寸，这次派发就读到对的（绑定时的检查只能等下一个安全点）
static void rs_pre_compute(NvShader *sh) {
    if (!rs_on() || !sh) return;
    __strong id<MTLTexture> q[32]; int n = 0;
    pthread_mutex_lock(&g_rmu);
    for (int i = 0; i < sh->rf.nb && n < 32; i++) {
        const nvn_rbind *b = &sh->rf.b[i]; int reg = b->reg, tid = 0;
        if (b->kind == NVN_RB_TEX) tid = (int)(tex_slot_h(S.tex[5], S.img[5], reg) & 0xfffff);
        else if (b->kind == NVN_RB_TEXU) tid = b->n ? ubo_tex_id(ubo_handle(5, reg, b->off)) : ubo_tex_id(ubo_packed(5, b));
        else if (b->kind == NVN_RB_IMG || b->kind == NVN_RB_IMGU) tid = img_tid(b, 5);
        else continue;
        void *tv = NULL; if (tid > 0 && tid < g_ntreg && g_treg[tid].ok) tex_fast_rid(tid, &tv);
        id<MTLTexture> t = (__bridge id<MTLTexture>)tv;
        if (t && rs_state(t) == RS_SCALED) q[n++] = rs_root(t);
    }
    pthread_mutex_unlock(&g_rmu);
    for (int k = 0; k < n; k++) if (rs_state(q[k]) == RS_SCALED) rs_rescale(q[k], 0, "计算派发读写");
    rs_flush();
}

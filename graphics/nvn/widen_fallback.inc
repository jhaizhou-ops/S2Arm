// 宽屏原比例回退的两侧覆盖采样：NVN 直连（widen_glue.inc）与 GL 直连（gl/gl_widen.inc）共用的一份（11-01 从 widen_glue.inc 抽出）。
// 目标按「键」认（NVN 贴图序号 / GL 核心目标号），每处给出它的 Metal 存储与客体宽；后端差异由包含方在包含前给出：
//   WD_P2_LOG(...)                                    日志
//   WD_P2_DEV                                         id<MTLDevice>
//   static int wd_p2_widen_on(void)                   宽屏开着（核心起好）
//   static id<MTLCommandBuffer> wd_p2_cmdbuf(void)    采样用的命令缓冲：执行顺序排在本帧所有绘制之后（NVN 等本帧提交事件；GL 同一队列、本帧已提交）
//   uint64_t g_wd_frame                               上屏次数
//   int g_wd                                          核心模式（S2A_WIDEN_UI = 游戏自己出宽图：两侧带按 k 算，见 wd_p2_band）
// 包含方要做的：每笔按放宽画（HOR）或回退中的纯 2D 绘制调 wd_fb_vote；颜色清屏调 wd_fb_arm_full / wd_fb_arm_rect（改清屏色的 alpha）；本帧第一笔画进世界目标前
//   wd_fb_want_self 为真就在两侧带画哨兵（黑、alpha WD_P2_DA）；上屏先 wd_fb_present_tex 再 wd_p2_present，核心 s2a_widen_present 返回 5 时 g_p2_fb = 1。
// ---------- 原比例回退的两侧覆盖采样（11-01，根因族 1「放宽后一侧游戏没画到」）----------
// 纯 2D 帧（s2a_widen_pure2d）里最后一笔按放宽画（HOR）的目标 = 纯 2D 世界目标（忍者龟 480×270 → 586 的小画布、植物大战僵尸的出图目标）。
//   哨兵：下一帧它整幅清屏（load-action）时 alpha 挪 WD_P2_DA（出图合成一般不显示 alpha、sRGB 的 alpha 不过伽马，读回精确）；颜色不动，看不出。
//   每 WD_P2_EVERY 次上屏在旧队列上等本帧提交事件，计算内核 wd_p2 读它两侧带各 16 列 × 32 行，数「alpha 是哨兵、颜色是原清屏色」的点（= 本帧没被画到），
//   并取中间区 8 格亮度（开平方后分 16 档：暗部更敏感，植物大战僵尸开机商标 → 暗底协议页按原亮度只变 0–2 档、判不出换场景，开平方后 3–6 档）作场景签名；完成回调只记结果，下次上屏由渲染线程交核心（s2a_widen_side_coverage，核心按迟滞决定回退 / 解除）。
//   只认带完整 alpha 的格式（RGBA8 / BGRA8 / RGBA16F / RGBA32F 及 sRGB），别的目标不放哨兵、不判
#define WD_P2_DA (4.0 / 255.0)
#define WD_P2_EVERY 30
#define WD_P2_FLAT 16   // 一侧带画到的点亮度最大 − 最小 ≤ 16/255 = 一片均匀（纯黑边 / 纯色底），不算有内容
static const char k_wd_p2_msl[] =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void wd_p2(texture2d<float, access::read> t [[texture(0)]], device atomic_uint *o [[buffer(0)]], constant float4 &s [[buffer(1)]], constant uint4 &p [[buffer(2)]], constant uint4 &q [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {\n"
    "  uint i = g.x, j = g.y; if (j >= 32u) return; uint y = q.x + (2u * j + 1u) * q.y / 64u;\n"
    "  if (i < 32u) { uint side = i / 16u, k = i % 16u, x = p.x + (2u * k + 1u) * p.z / 32u; if (side) x += p.y - p.z;\n"
    "    float4 v = t.read(uint2(x, y)); if (abs(v.a - s.a) < 0.002f && all(abs(v.rgb - s.rgb) < 0.01f)) atomic_fetch_add_explicit(&o[side], 1u, memory_order_relaxed);\n"
    "    else { uint l = uint(dot(clamp(v.rgb, 0.0f, 1.0f), float3(0.299f, 0.587f, 0.114f)) * 255.0f);\n"
    "      atomic_fetch_min_explicit(&o[10u + 2u * side], l, memory_order_relaxed); atomic_fetch_max_explicit(&o[11u + 2u * side], l, memory_order_relaxed); } }\n"
    "  else if (i < 40u) { uint c = i - 32u, cw = p.y - 2u * p.z, x = p.x + p.z + c * cw / 8u + cw / 16u;\n"
    "    float4 v = t.read(uint2(x, y)); float l = dot(clamp(v.rgb, 0.0f, 1.0f), float3(0.299f, 0.587f, 0.114f));\n"
    "    atomic_fetch_add_explicit(&o[2u + c], uint(sqrt(l) * 255.0f), memory_order_relaxed); }\n"
    "}\n";
// 纯 2D 世界目标 = 最近几帧里按放宽画（HOR）笔数最多的目标（提交线程写；清屏时读）。记一个小环而不是只记上一帧那张：
//   游戏直接画进轮换的多缓冲目标（DOUBLE DRAGON4 三张 1920x1080 轮流）时，上一帧的那张这一帧不会再清屏，只记一张就永远放不上哨兵
#define WD_P2_NSER 4
//   每张记最后一次当选的出图帧号，只认最近 WD_P2_AGE 帧内当选过的（换场景后旧目标自然过期，不会给离屏目标放哨兵）
#define WD_P2_AGE 8
static uint64_t g_p2_sers[WD_P2_NSER], g_p2_seen[WD_P2_NSER]; static uint32_t g_p2_srect[WD_P2_NSER][5];   // 各格最近一次清屏的存储范围（起列、宽、起行、高、两侧带宽），游戏不清屏的帧自己放哨兵用
static int wd_p2_slot(uint64_t ser) { if (!ser) return -1; for (int i = 0; i < WD_P2_NSER; i++) if (g_p2_sers[i] == ser) return i; return -1; }
//   回退中（上屏返回 5）不过期：回退时游戏的笔不再按放宽画，没有目标当选，按龄过期就再不放哨兵、不采样、永远解除不了
//   （植物大战僵尸开机黑屏回退后只采到 11 个样本，加载页整页锁在 16:9、两侧边饰丢了）
static int g_p2_fb;
static uint64_t g_p2_pser; static uint32_t g_p2_pw, g_p2_ph;   // 本帧上屏的贴图（3D 镜头帧没有放宽笔投票时，它就是世界目标）   // 状态行用：本帧上屏的贴图（序号、宽高），与世界目标对账
static uint32_t g_p2_clr[4];   // 状态行用：世界目标上的颜色清屏按路径计数（整幅 load-action / 三角形 / 零缓冲拷贝 / 别的），每行清零
static int wd_p2_is_world(uint64_t ser) { int i = wd_p2_slot(ser); return i >= 0 && (g_p2_fb || g_wd_frame - g_p2_seen[i] <= WD_P2_AGE); }
typedef struct { uint64_t ser; uint32_t n, w, h; } wd_p2_cnt;
static wd_p2_cnt g_p2_cnt[8]; static int g_p2_ncnt;             // 本帧各目标的 HOR 笔数（上屏时定下一帧的世界目标）
static uint64_t g_p2_armed_ser; static __strong id<MTLTexture> g_p2_armed_mt;   // 本帧放了哨兵的那张（采样只读它：交换链两张轮换，读另一张没意义）
static int g_p2_armed; static MTLClearColor g_p2_sent;          // 本帧这张目标放了哨兵、哨兵值
static uint32_t g_p2_rect[5];                                    // 放哨兵那次清屏的存储范围：起列、宽、起行、高、两侧放宽带宽（采样只在这块里取）
static _Atomic int g_p2_ready; static int g_p2_l, g_p2_r, g_p2_ul, g_p2_ur; static uint32_t g_p2_sig, g_p2_rng[4], g_p2_cnt_l, g_p2_cnt_r;   // 采样结果（完成回调写、上屏读）
static _Atomic int g_p2_busy; static uint64_t g_p2_n, g_p2_samples;
static int wd_p2_fmt_ok(MTLPixelFormat f) {
    switch (f) { case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
                 case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA32Float: return 1; default: return 0; }
}
// nvn_mtl.m 颜色清屏（整幅、load-action）记下清屏色之后调：这张是纯 2D 世界目标就把 alpha 挪成哨兵
static int wd_p2_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_WIDEN_FALLBACK"); v = !(e && !strcmp(e, "0")); if (!v) WD_P2_LOG("宽屏·原比例回退：关（S2A_WIDEN_FALLBACK=0，开 / 关对照量代价用）"); } return v; }
// 两侧带宽（存储像素）：宿主放宽的 = 存储比客体宽多出的一半（客体 gw 映射成 cw）；游戏自己出宽图（Ui 模式，11-02）客体坐标本来就是宽的（gw = cw），
//   原比例那块 = 中间 宽 ÷ k，两侧带 = 宽 ×（1 − 1/k）/ 2。原先 Ui 模式按 gw / cw 算成 0、剪裁清屏还被当「没被放宽」不放哨兵，回退从不触发：
//   怪猎健康提醒页（第 2 次出图起「剪裁清屏不放哨兵（客体剪裁宽 1564、映射宽 1564）」）两侧露游戏的白色清屏色
static uint32_t wd_p2_band(uint32_t w, long gw, long cw) {
    if (g_wd == S2A_WIDEN_UI) { float k = s2a_widen_k(); return k > 1.0f ? (uint32_t)((double)w * (1.0 - 1.0 / k) / 2.0) : 0; }
    return cw > gw ? (uint32_t)((double)w * (1.0 - (double)gw / (double)cw) / 2.0) : 0;
}
static void wd_fb_arm_full(uint64_t ser, id<MTLTexture> mt, uint32_t gw, MTLClearColor *cc) {   // mt = 这张目标的 Metal 存储（可能放宽），gw = 客体宽
    if (!wd_p2_on() || !ser || !wd_p2_is_world(ser) || !wd_p2_widen_on()) return;
    const char *why = !mt || !wd_p2_fmt_ok(mt.pixelFormat) ? "格式不支持" : NULL;
    if (why) { static int n; if (n++ < 6) WD_P2_LOG("宽屏·原比例回退：世界目标 ser=%llu 整幅清屏不放哨兵（%s；格式 %lu）", (unsigned long long)ser, why, mt ? (unsigned long)mt.pixelFormat : 0ul); return; }
    cc->alpha = cc->alpha >= 0.5 ? cc->alpha - WD_P2_DA : cc->alpha + WD_P2_DA;
    g_p2_sent = *cc; g_p2_armed = 1; g_p2_armed_ser = ser; g_p2_armed_mt = mt;
    g_p2_rect[0] = 0; g_p2_rect[1] = (uint32_t)mt.width; g_p2_rect[2] = 0; g_p2_rect[3] = (uint32_t)mt.height;
    g_p2_rect[4] = wd_p2_band((uint32_t)mt.width, gw, (long)mt.width);   // 放宽存储比客体宽多出的两侧（Ui 模式按 k）
    { int si = wd_p2_slot(ser); if (si >= 0) memcpy(g_p2_srect[si], g_p2_rect, sizeof g_p2_rect); }
    { static int n; if (n++ < 4) WD_P2_LOG("宽屏·原比例回退：世界目标 ser=%llu 清屏放哨兵（alpha %.4f，格式 %lu）", (unsigned long long)ser, cc->alpha, (unsigned long)mt.pixelFormat); }
}
// nvn_mtl.m 带剪裁的颜色清屏（画成三角形）调：游戏只在目标的一块里画（DOUBLE DRAGON4 在 1920x1080 目标左上 1280x720 剪裁清屏），
//   这块的清屏同样放哨兵，采样只在这块里取。只认全掩码、客体宽至少占目标一半的清屏（清小块界面的不算世界清屏）。
//   不管清屏前这张目标画没画过、在不在已开的 pass 里（植物大战僵尸两样都是）：清屏把范围里先前画的全抹掉，帧末采到的哨兵只说明
//   「最后一次清屏之后游戏没画到这里」，正是要判的；同帧清多次以最后一次的范围与哨兵为准。
//   sc = 换算到存储的清屏范围；gw = 客体剪裁宽；cw = gw 经宽屏映射后的宽（两侧放宽带 = 存储宽 ×（1 − gw / cw）/ 2）
static void wd_fb_arm_rect(uint64_t ser, id<MTLTexture> mt, uint32_t tw, float *rgba, int mask, MTLScissorRect sc, long gw, long cw) {   // tw = 目标客体宽
    if (!wd_p2_on() || !ser || !wd_p2_is_world(ser) || !wd_p2_widen_on()) return;
    const char *why = mask != 0xf ? "掩码不全" : gw * 2 < (long)tw ? "剪裁不到目标一半宽" : cw <= gw && g_wd != S2A_WIDEN_UI ? "剪裁没被放宽" : !mt || !wd_p2_fmt_ok(mt.pixelFormat) ? "格式不支持" : NULL;
    if (why) { static int n; if (n++ < 6) WD_P2_LOG("宽屏·原比例回退：世界目标 ser=%llu 剪裁清屏不放哨兵（%s；掩码 %#x、客体剪裁宽 %ld、映射宽 %ld、格式 %lu）", (unsigned long long)ser, why, mask, gw, cw, mt ? (unsigned long)mt.pixelFormat : 0ul); return; }
    rgba[3] = rgba[3] >= 0.5f ? rgba[3] - (float)WD_P2_DA : rgba[3] + (float)WD_P2_DA;
    g_p2_sent = MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]); g_p2_armed = 1; g_p2_armed_ser = ser; g_p2_armed_mt = mt;
    g_p2_rect[0] = (uint32_t)sc.x; g_p2_rect[1] = (uint32_t)sc.width; g_p2_rect[2] = (uint32_t)sc.y; g_p2_rect[3] = (uint32_t)sc.height;
    g_p2_rect[4] = wd_p2_band((uint32_t)sc.width, gw, cw);
    { int si = wd_p2_slot(ser); if (si >= 0) memcpy(g_p2_srect[si], g_p2_rect, sizeof g_p2_rect); }
    { static int n; if (n++ < 4) WD_P2_LOG("宽屏·原比例回退：世界目标 ser=%llu 剪裁清屏放哨兵（存储 %lu,%lu %lux%lu、两侧带 %u、alpha %.4f）", (unsigned long long)ser,
          (unsigned long)sc.x, (unsigned long)sc.y, (unsigned long)sc.width, (unsigned long)sc.height, g_p2_rect[4], rgba[3]); }
}
// 游戏这帧不清世界目标（植物大战僵尸进加载页后整幅直接画，清屏计数 0）：nvn_mtl.m 每笔画前调，本帧第一笔画进世界目标、还没放哨兵、
//   这张以前清过屏（记得范围）时返回 1 并给出范围，调用方在这笔之前把两侧带写成自己的哨兵（黑、alpha = WD_P2_DA）。
//   游戏没画到的两侧在放宽时露黑（原先露旧帧），回退时两侧不上屏，都不比原来坏
static int wd_fb_want_self(uint64_t ser, id<MTLTexture> mt, uint32_t r5[5]) {
    if (!ser || !wd_p2_on() || !wd_p2_widen_on() || !wd_p2_is_world(ser) || (g_p2_armed && g_p2_armed_ser == ser)) return 0;
    int si = wd_p2_slot(ser); if (si < 0 || g_p2_srect[si][4] < 4) return 0;
    if (!mt || !wd_p2_fmt_ok(mt.pixelFormat)) return 0;
    memcpy(r5, g_p2_srect[si], sizeof g_p2_srect[si]); memcpy(g_p2_rect, r5, sizeof g_p2_rect);
    g_p2_sent = MTLClearColorMake(0, 0, 0, WD_P2_DA); g_p2_armed = 1; g_p2_armed_ser = ser; g_p2_armed_mt = mt;
    { static int n; if (n++ < 4) WD_P2_LOG("宽屏·原比例回退：世界目标 ser=%llu 本帧没清屏，自己在两侧带放哨兵（存储 %u,%u %ux%u、两侧带 %u）", (unsigned long long)ser, r5[0], r5[2], r5[1], r5[3], r5[4]); }
    return 1;
}
static id<MTLComputePipelineState> wd_p2_pso(void) {
    static id<MTLComputePipelineState> ps; static int failed;
    if (!ps && !failed) { NSError *e = nil; id<MTLLibrary> lib = [WD_P2_DEV newLibraryWithSource:@(k_wd_p2_msl) options:nil error:&e]; id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"wd_p2"] : nil;
        ps = fn ? [WD_P2_DEV newComputePipelineStateWithFunction:fn error:&e] : nil;
        if (!ps) { failed = 1; WD_P2_LOG("【红】 宽屏·原比例回退：两侧覆盖采样管线建不出（%s），不判回退", e.localizedDescription.UTF8String); } }
    return ps;
}
// 上屏（持 g_wd_mu）：先把上次的采样结果交核心，再按节拍起这一帧的采样
static void wd_p2_present(void) {
    if (atomic_exchange(&g_p2_ready, 0)) { s2a_widen_side_coverage(g_p2_l, g_p2_r, g_p2_ul, g_p2_ur, g_p2_sig); g_p2_samples++;
        // 还没回退、这个样本按核心同一判据算「两侧空」（纯 2D：两侧没内容；3D：两侧没画到；中间也空的样本不算）：下一次放了哨兵的上屏就补采一次（不等 WD_P2_EVERY），
        //   核心「连续 FallbackSamples 个样本」不变，回退在 2–3 次上屏内生效。每段只补一次：补采的样本再空、核心仍没回退（判据不同）就回到每 WD_P2_EVERY 次一采
        //   （怪猎健康提醒页 11-02 jhz「白了几帧然后切成黑色」：第 1 个样本第 115 次出图、第 2 个隔 30 次才采，两侧白 30 次上屏）
        { static int quick; uint32_t top = 0; for (int i = 0; i < 8; i++) top = MAX(top, g_p2_sig >> (4 * i) & 15);
          int bare = top > 1 && (s2a_widen_pure2d() ? !g_p2_l && !g_p2_r : g_p2_ul && g_p2_ur);
          if (bare && !g_p2_fb && !quick) { g_p2_n = 0; quick = 1; } else quick = 0; }
        if (g_p2_samples <= 16 || (!g_p2_l || !g_p2_r)) { static int n; if (n++ < 200) WD_P2_LOG("宽屏·原比例回退：两侧覆盖样本 %llu 左%s 右%s 签名 %08x（第 %llu 次出图；两侧哨兵点 %u / %u，画到点亮度 左 %u–%u 右 %u–%u）", (unsigned long long)g_p2_samples, g_p2_l ? "有内容" : "没内容", g_p2_r ? "有内容" : "没内容", g_p2_sig, (unsigned long long)g_wd_frame, g_p2_cnt_l, g_p2_cnt_r, g_p2_rng[0], g_p2_rng[1], g_p2_rng[2], g_p2_rng[3]); } }
    int armed = g_p2_armed; MTLClearColor sent = g_p2_sent; uint64_t aser = g_p2_armed_ser; id<MTLTexture> amt = g_p2_armed_mt; g_p2_armed = 0; g_p2_armed_mt = nil;
    // 3D 镜头帧（核心说不是纯 2D、本帧没有按放宽画的笔投票）：上屏的那张就是世界目标（族 1 ③ 3D 镜头帧回退：清屏放哨兵、采它两侧有没有被画到）
    if (!g_p2_ncnt && !s2a_widen_pure2d() && g_p2_pser) g_p2_cnt[g_p2_ncnt++] = (wd_p2_cnt){g_p2_pser, 1, g_p2_pw, g_p2_ph};
    { int best = -1; for (int i = 0; i < g_p2_ncnt; i++) if (best < 0 || g_p2_cnt[i].n > g_p2_cnt[best].n) best = i;   // 下一帧的世界目标：本帧 HOR 笔数最多的那张
      int si = best >= 0 ? wd_p2_slot(g_p2_cnt[best].ser) : -1;
      if (si >= 0) g_p2_seen[si] = g_wd_frame;
      else if (best >= 0) { int o = 0; for (int i = 1; i < WD_P2_NSER; i++) if (!g_p2_sers[o]) break; else if (!g_p2_sers[i] || g_p2_seen[i] < g_p2_seen[o]) o = i;   // 先用空格，没空格换掉最久没当选的那格
        g_p2_sers[o] = g_p2_cnt[best].ser; g_p2_seen[o] = g_wd_frame; static int n; if (n++ < 200) WD_P2_LOG("宽屏·原比例回退：纯 2D 世界目标 ser=%llu %ux%u（本帧 %u 笔%s，第 %llu 次出图）", (unsigned long long)g_p2_cnt[best].ser, g_p2_cnt[best].w, g_p2_cnt[best].h, g_p2_cnt[best].n, g_p2_fb ? "（回退中，全部笔）" : "放宽", (unsigned long long)g_wd_frame); }
      // 状态行（每 30 次上屏一行、整局 300 行，不按前几条截）：回退与否、本帧纯 2D 与否、候选（本帧前 4 个目标:笔数）、小环各格离上次当选几次上屏、本帧放没放哨兵、采样忙不忙
      if (g_wd_frame % 30 == 0) { static int sn; if (sn++ < 300) { char cb[160] = "", rb[160] = ""; int o = 0;
          for (int i = 0; i < g_p2_ncnt && i < 4 && o < 150; i++) o += snprintf(cb + o, sizeof cb - o, " %llu:%u", (unsigned long long)g_p2_cnt[i].ser, g_p2_cnt[i].n);
          o = 0; for (int i = 0; i < WD_P2_NSER && o < 150; i++) if (g_p2_sers[i]) o += snprintf(rb + o, sizeof rb - o, " %llu@%llu", (unsigned long long)g_p2_sers[i], (unsigned long long)(g_wd_frame - g_p2_seen[i]));
          WD_P2_LOG("宽屏·原比例回退状态：第 %llu 次出图 回退%s 纯2D%s 候选[%s ] 小环[%s ] 哨兵%s 采样忙%s 样本 %llu 清屏[整幅 %u 三角 %u 零拷 %u 别的 %u] 上屏 ser=%llu %ux%u", (unsigned long long)g_wd_frame, g_p2_fb ? "是" : "否", s2a_widen_pure2d() ? "是" : "否", cb, rb, armed ? "放了" : "没放", atomic_load(&g_p2_busy) ? "是" : "否", (unsigned long long)g_p2_samples, g_p2_clr[0], g_p2_clr[1], g_p2_clr[2], g_p2_clr[3], (unsigned long long)g_p2_pser, g_p2_pw, g_p2_ph); memset(g_p2_clr, 0, sizeof g_p2_clr); } }
      g_p2_ncnt = 0; }
    if (!armed || g_p2_n++ % WD_P2_EVERY || atomic_load(&g_p2_busy)) return;
    id<MTLTexture> mt = amt; id<MTLComputePipelineState> ps = wd_p2_pso();
    uint32_t rx = g_p2_rect[0], rw = g_p2_rect[1], ry = g_p2_rect[2], rh = g_p2_rect[3], pad = g_p2_rect[4];   // 放哨兵那次清屏的范围与两侧放宽带（各 pad 纹素）
    if (!mt || !ps || pad < 4 || rw < 2 * pad + 8 || rh < 32 || rx + rw > mt.width || ry + rh > mt.height) { static int n; if (n++ < 4) WD_P2_LOG("宽屏·原比例回退：世界目标 ser=%llu 采不了（贴图 %p %lux%lu、范围 %u,%u %ux%u、两侧带 %u）", (unsigned long long)aser, (__bridge void *)mt, (unsigned long)mt.width, (unsigned long)mt.height, rx, ry, rw, rh, pad); return; }
    id<MTLCommandBuffer> cb = wd_p2_cmdbuf();   // 包含方给：执行顺序排在本帧所有绘制之后
    id<MTLBuffer> ob = cb ? [WD_P2_DEV newBufferWithLength:14 * 4 options:MTLResourceStorageModeShared] : nil;   // 0/1 两侧哨兵点数、2..9 中间 8 格亮度和、10..13 两侧画到点的亮度最小 / 最大
    if (!cb || !ob) return;
    memset(ob.contents, 0, 56); ((uint32_t *)ob.contents)[10] = ((uint32_t *)ob.contents)[12] = 255;
    // 世界目标没有着色器可读用途（只当渲染目标建：植物大战僵尸的 1/2/3）时计算内核读出来全是 0（f41aa7178 局：同一命令缓冲里拷贝读得到协议页、
    //   内核读到两侧亮度 0–0、哨兵 0）：先把采样范围拷进一张可读的临时贴图（同格式，按尺寸 / 格式缓存一张），内核读它
    id<MTLTexture> src = mt; uint32_t sx = rx, sy = ry;
    { static int un; if (un++ < 4) WD_P2_LOG("宽屏·原比例回退：世界目标 ser=%llu 用途 %#lx%s", (unsigned long long)aser, (unsigned long)mt.usage, (mt.usage & MTLTextureUsageShaderRead) ? "" : "（不可读，经临时贴图采样）"); }
    if (!(mt.usage & MTLTextureUsageShaderRead)) {
        static id<MTLTexture> scr; if (!scr || scr.width != rw || scr.height != rh || scr.pixelFormat != mt.pixelFormat) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mt.pixelFormat width:rw height:rh mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate; scr = [WD_P2_DEV newTextureWithDescriptor:d]; }
        id<MTLBlitCommandEncoder> be = scr && mt.textureType == MTLTextureType2D ? [cb blitCommandEncoder] : nil;
        if (!be) { static int n; if (n++ < 4) WD_P2_LOG("【红】 宽屏·原比例回退：世界目标 ser=%llu 不可读、临时贴图建不出（%ux%u 格式 %lu 类型 %lu），不采样", (unsigned long long)aser, rw, rh, (unsigned long)mt.pixelFormat, (unsigned long)mt.textureType); return; }
        [be copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(rx, ry, 0) sourceSize:MTLSizeMake(rw, rh, 1) toTexture:scr destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)]; [be endEncoding];
        src = scr; sx = sy = 0; }
    float s4[4] = {(float)sent.red, (float)sent.green, (float)sent.blue, (float)sent.alpha}; uint32_t p4[4] = {sx, rw, pad, 0}, q4[4] = {sy, rh, 0, 0};
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder]; [e setComputePipelineState:ps];
    [e setTexture:src atIndex:0]; [e setBuffer:ob offset:0 atIndex:0]; [e setBytes:s4 length:sizeof s4 atIndex:1]; [e setBytes:p4 length:sizeof p4 atIndex:2]; [e setBytes:q4 length:sizeof q4 atIndex:3];
    [e dispatchThreads:MTLSizeMake(40, 32, 1) threadsPerThreadgroup:MTLSizeMake(40, 1, 1)]; [e endEncoding];
    // 诊断（S2A_WIDEN_FB_DUMP=<目录>）：第 3、10、30、60 个样本把采样那一刻的整张贴图拷出来存 PPM（只认 4 字节 RGBA / BGRA），与上屏截图对账
    id<MTLBuffer> db = nil; uint32_t dw = 0, dh = 0, dbgr = 0; uint64_t dn = g_p2_samples + 1; const char *dd = getenv("S2A_WIDEN_FB_DUMP");
    if (dd && (dn == 3 || dn == 10 || dn == 30 || dn == 60)) { MTLPixelFormat pf = mt.pixelFormat;
        if (pf == MTLPixelFormatRGBA8Unorm || pf == MTLPixelFormatRGBA8Unorm_sRGB || pf == MTLPixelFormatBGRA8Unorm || pf == MTLPixelFormatBGRA8Unorm_sRGB) {
            dw = (uint32_t)mt.width; dh = (uint32_t)mt.height; dbgr = pf == MTLPixelFormatBGRA8Unorm || pf == MTLPixelFormatBGRA8Unorm_sRGB;
            db = [WD_P2_DEV newBufferWithLength:(NSUInteger)dw * dh * 4 options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> be = db ? [cb blitCommandEncoder] : nil;
            if (be) { [be copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(dw, dh, 1) toBuffer:db destinationOffset:0 destinationBytesPerRow:dw * 4 destinationBytesPerImage:(NSUInteger)dw * dh * 4]; [be endEncoding]; }
            else db = nil; } }
    char *dpath = NULL; if (db) asprintf(&dpath, "%s/fb_s%llu_f%llu_ser%llu.ppm", dd, (unsigned long long)dn, (unsigned long long)g_wd_frame, (unsigned long long)aser);   // 块里不能捕获数组，用堆串（完成回调里 free）
    atomic_store(&g_p2_busy, 1);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        const uint32_t *r = ob.contents;
        if (db && dpath && !c.error) { FILE *f = fopen(dpath, "wb"); if (f) { fprintf(f, "P6\n%u %u\n255\n", dw, dh); const uint8_t *px = db.contents;
            for (size_t i = 0; i < (size_t)dw * dh; i++) { uint8_t rgb[3] = {px[4 * i + (dbgr ? 2 : 0)], px[4 * i + 1], px[4 * i + (dbgr ? 0 : 2)]}; fwrite(rgb, 1, 3, f); } fclose(f);
            WD_P2_LOG("宽屏·原比例回退：诊断存图 %s（%ux%u，采样范围 %u,%u %ux%u、两侧带 %u）", dpath, dw, dh, rx, ry, rw, rh, pad); } }
        free(dpath);
        if (!c.error) {   // 一侧 512 个采样点里一半以上还是哨兵 = 这一侧本帧游戏没画到
            // 一侧「有内容」= 一半以上的点游戏画到了、且画到的点亮度不是一片均匀（最大 − 最小 > WD_P2_FLAT）。
            //   只看「画到」不够：忍者龟放大那一遍没铺满时游戏在右侧画纯黑，算画到却没内容；DOUBLE DRAGON4 关卡左端右侧画的是场景，才算有内容
            g_p2_l = r[0] < 256 && r[11] > r[10] + WD_P2_FLAT; g_p2_r = r[1] < 256 && r[13] > r[12] + WD_P2_FLAT; g_p2_ul = r[0] >= 256; g_p2_ur = r[1] >= 256;
            // 上一行 ul / ur：没画到 = 一半以上的点哨兵还在（3D 镜头帧回退只认它）
            memcpy(g_p2_rng, r + 10, sizeof g_p2_rng); g_p2_cnt_l = r[0]; g_p2_cnt_r = r[1]; uint32_t sig = 0; for (int k = 0; k < 8; k++) { uint32_t m = r[2 + k] / 32; sig |= (m >> 4 & 15u) << (4 * k); } g_p2_sig = sig;
            // 游戏自己出宽图（Ui 模式，11-02 怪猎真机）：两侧一定被游戏的清屏画到，哨兵判「没画到」永远不成立，3D 帧回退走不到——健康提醒页两侧是一片 253 的白、
            //   中间紧挨的格是 0 档黑底。一侧「画到但一片均匀、且与紧挨的中间格（左：第 0 格，右：第 7 格）亮度断开」= 16:9 页面两侧的清屏色，按没画到交核心。
            //   与真 3D 场景两侧一片天空分开靠「断开」：天空和相邻画面连续。比较在中间格的刻度上（开平方 × 255）：两侧取画到点亮度中值换过去，差 > 64（满刻度 1/4）
            if (g_wd == S2A_WIDEN_UI) {
                for (int sd = 0; sd < 2; sd++) {
                    uint32_t lo = r[10 + 2 * sd], hi = r[11 + 2 * sd]; int *u = sd ? &g_p2_ur : &g_p2_ul, drawn = sd ? g_p2_r : g_p2_l;
                    if (*u || drawn || hi < lo) continue;   // 已判没画到 / 有内容 / 没有画到的点
                    double sv = sqrt(((double)lo + hi) / 2 / 255.0) * 255.0, cv = (double)(r[sd ? 9 : 2] / 32);
                    if (fabs(sv - cv) > 64) *u = 1;
                }
            }
            atomic_store(&g_p2_ready, 1);
        }
        atomic_store(&g_p2_busy, 0);
    }];
    [cb commit];
}
// 本笔投票（包含方持自己的宽屏锁调）：纯 2D 帧里按放宽画的目标（回退中全部笔）记一票
static void wd_fb_vote(uint64_t ser, uint32_t w, uint32_t h) {
    int i = 0; while (i < g_p2_ncnt && g_p2_cnt[i].ser != ser) i++;
    if (i < g_p2_ncnt) g_p2_cnt[i].n++; else if (g_p2_ncnt < 8) g_p2_cnt[g_p2_ncnt++] = (wd_p2_cnt){ser, 1, w, h};
}
// 上屏前：本帧上屏的贴图（3D 镜头帧没有放宽笔投票时它就是世界目标；状态行对账）
static void wd_fb_present_tex(uint64_t ser, uint32_t w, uint32_t h) { g_p2_pser = ser; g_p2_pw = w; g_p2_ph = h; }

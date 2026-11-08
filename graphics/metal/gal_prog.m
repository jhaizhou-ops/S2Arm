// GAL Metal 后端：第 4 块「程序（着色器）」——SPIR-V（Ryujinx TargetApi.Vulkan 产出）→ MSL（SPIRV-Cross，参数缓冲第 2 档）→ MTLLibrary / 离线 metallib，
// 并给出绑定模型：每个资源在「该阶段、该描述符集的参数缓冲」里的字节偏移（gal_arg）。第 5/6 块只按 gal_prog 写参数缓冲。
//
// 绑定模型（本块定，第 5/6 块照做；详见 设计.md「资源绑定模型」）：
//   · 每个阶段、每个描述符集各一个参数缓冲，绑在该阶段参数表的 [[buffer(集号)]]。不同阶段不共用同一块：各阶段的结构体布局只由本阶段 SPIR-V 决定
//     （离线库按单个着色器的 SPIR-V 哈希索引，布局不能依赖同程序里的其他阶段）。
//   · 集内 [[id]] 分配（本块显式指定，不用 SPIRV-Cross 自动分配）：本阶段声明的全部资源按 (集, 绑定号) 升序，依次占号——
//       常量 / 存储缓冲 count 个；组合贴图采样器（TextureAndSampler，非缓冲维）先贴图 count 个、再采样器 count 个；贴图缓冲 / 分离贴图 / 图像 count 个；分离采样器 count 个；
//       集内有存储缓冲时末尾再留 1 个号给缓冲长度表（spvBufferSizeConstants，只在着色器用到 .length() 时真的出现）。
//     参数缓冲第 2 档：每个成员 8 字节（缓冲 = GPU 地址，贴图 = MTLResourceID，采样器 = MTLResourceID，缓冲长度表 = GPU 地址），数组连排，
//     结构体按 [[id]] 升序紧排——所以 offset = id × 8。这一点不靠推断：编完后逐行解析 MSL 里的 spvDescriptorSetBufferN 结构体，按真实成员累加偏移，
//     与 id × 8 不符、成员缺失或出现认不出的成员类型都当失败（status = Failure，首例报红）。
//   · force_active_argument_buffer_resources = 1：声明了但没用到的资源也进结构体，布局 = 声明表，不随死代码消除漂移。
//   · 缓冲长度表：参数缓冲模式下 SPIRV-Cross 把它放进该集参数缓冲（成员 spvBufferSizeConstants，下标 = 存储缓冲的 [[id]]），不是独立的 [[buffer(n)]]；
//     记成 kind = GAL_ARG_SIZES 的 gal_arg，各存储缓冲 gal_arg.slot = 它在长度表里的下标。SPIRV-Cross 另在入口签名里留一个不读的 [[buffer(24)]]，记 size_buf_index = 24。
// 着色器键 = SHA-256(SPIR-V) 前 8 字节（小端 u64）；MSL 入口函数名 = "s" + 16 位十六进制键（离线库里多支着色器共存靠它区分）。
// 查找顺序：内存缓存 → 离线库（nxgal_prog_lib_open）→ Mac 运行时现编（SPIRV-Cross C API + newLibraryWithSource）；iOS 不现编，未命中报红计数。
#import "gal_internal.h"
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <sys/stat.h>
#include <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
// SPIRV-Cross：本仓 graphics/third_party/spirv_cross（1.4.363.0），Mac 运行时现编 / iOS 首遇现编 / 离线出库三处同一份源码。NXGAL_NO_XC 可整体关掉
#if !defined(NXGAL_NO_XC)
#include "spirv_cross_c.h"
#include "gal_tessxc.h"
#define GAL_HAVE_XC 1
#if TARGET_OS_IPHONE
#define XC_PLATFORM SPVC_MSL_PLATFORM_IOS
#else
#define XC_PLATFORM SPVC_MSL_PLATFORM_MACOS
#endif
#else
#define GAL_HAVE_XC 0
#endif

// ---------- 着色器记录（单阶段的翻译结果；离线索引与程序二进制共用同一序列化格式）----------
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
typedef struct { uint8_t kind, set; uint16_t binding; uint32_t offset, count, slot; } shd_arg;   // 16 字节
typedef struct {
    uint64_t hash; uint32_t stage;
    uint32_t set_size[GAL_MAX_SETS];
    uint32_t io_mask; uint8_t io_ctype[32];   // 顶点：输入属性位置；片元：输出颜色位置
    uint32_t tg[3];
    int32_t size_buf;                          // 入口函数是否另带 [[buffer(24)]] 的缓冲长度表参数（-1 无，否则 24）
    uint32_t flags;                            // 位 0：顶点着色器写点大小（[[point_size]]；Metal 要求这类管线拓扑类为 Point / Unspecified）
    uint32_t nargs; shd_arg *args;
} shd_rec;
#define REC_HDR (8 + 4 + 4 * GAL_MAX_SETS + 4 + 32 + 12 + 4 + 4 + 4)
static uint32_t rec_size(const shd_rec *r) { return REC_HDR + 16 * r->nargs; }
static void put32(uint8_t **p, uint32_t v) { memcpy(*p, &v, 4); *p += 4; }
static uint32_t get32(const uint8_t **p) { uint32_t v; memcpy(&v, *p, 4); *p += 4; return v; }
static void rec_write(const shd_rec *r, uint8_t *o) {
    memcpy(o, &r->hash, 8); o += 8; put32(&o, r->stage);
    for (int s = 0; s < GAL_MAX_SETS; s++) put32(&o, r->set_size[s]);
    put32(&o, r->io_mask); memcpy(o, r->io_ctype, 32); o += 32;
    for (int i = 0; i < 3; i++) put32(&o, r->tg[i]);
    put32(&o, (uint32_t)r->size_buf);
    put32(&o, r->flags);
    put32(&o, r->nargs);
    for (uint32_t i = 0; i < r->nargs; i++) {
        const shd_arg *a = &r->args[i]; *o++ = a->kind; *o++ = a->set; memcpy(o, &a->binding, 2); o += 2;
        put32(&o, a->offset); put32(&o, a->count); put32(&o, a->slot);
    }
}
// 读记录；返回消耗的字节数，0 = 格式错
static uint32_t rec_read(const uint8_t *p, uint32_t len, shd_rec *r) {
    if (len < REC_HDR) return 0;
    const uint8_t *q = p; memset(r, 0, sizeof *r);
    memcpy(&r->hash, q, 8); q += 8; r->stage = get32(&q);
    for (int s = 0; s < GAL_MAX_SETS; s++) r->set_size[s] = get32(&q);
    r->io_mask = get32(&q); memcpy(r->io_ctype, q, 32); q += 32;
    for (int i = 0; i < 3; i++) r->tg[i] = get32(&q);
    r->size_buf = (int32_t)get32(&q);
    r->flags = get32(&q);
    r->nargs = get32(&q);
    if (r->stage > 5 || r->nargs > 4096 || len < REC_HDR + 16 * r->nargs) return 0;
    r->args = calloc(r->nargs ? r->nargs : 1, sizeof *r->args);
    for (uint32_t i = 0; i < r->nargs; i++) {
        shd_arg *a = &r->args[i]; a->kind = *q++; a->set = *q++; memcpy(&a->binding, q, 2); q += 2;
        a->offset = get32(&q); a->count = get32(&q); a->slot = get32(&q);
        if (a->set >= GAL_MAX_SETS || a->kind > GAL_ARG_OOBCNT) { free(r->args); r->args = NULL; return 0; }
    }
    return (uint32_t)(q - p);
}

uint64_t gal_spv_hash(const void *code, uint32_t len) {
    uint8_t d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(code, len, d);
    uint64_t h; memcpy(&h, d, 8); return h;
}
static NSString *fn_name(uint64_t h) { return [NSString stringWithFormat:@"s%016llx", (unsigned long long)h]; }
// 翻译后着色器的编译选项（运行时现编；离线 gal_offline.py 的 xcrun metal 同口径 -fmetal-math-mode=relaxed -fpreserve-invariance，直连 dm_msl_opts 也是这一份）：
//   relaxed：保留 fast 的重结合 / 融合，但不许假设没有 NaN / Inf——Ryujinx 翻译对 FSET / FSETP 无序比较生成 isnan 选择复现 Maxwell 的 NaN 语义，
//   Metal 缺省 fast 下编译器把 isnan 当恒假（#807；直连 10-27 同病：A20 Pro 开场奇数帧 72.7 万个 NaN 像素成黑带）；preserveInvariance：[[invariant]] 位置
MTLCompileOptions *gal_msl_opts(void) {
    static MTLCompileOptions *o; static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [MTLCompileOptions new]; o.mathMode = MTLMathModeRelaxed; o.preserveInvariance = YES; });
    return o;
}
// 编 MSL：带 GAL_MSL_NP 分隔的是两个编译单元（主份 + 无点大小变体，各有一份辅助函数定义，不能合编），分开编；*np = 变体库（无则 nil）
static id<MTLLibrary> msl_compile(const char *msl, id<MTLLibrary> *np, NSError **err) {
    *np = nil;
    const char *m = strstr(msl, GAL_MSL_NP);
    if (!m) return [g_gdev newLibraryWithSource:@(msl) options:gal_msl_opts() error:err];
    NSString *a = [[NSString alloc] initWithBytes:msl length:(NSUInteger)(m - msl) encoding:NSUTF8StringEncoding];
    id<MTLLibrary> lib = [g_gdev newLibraryWithSource:a options:gal_msl_opts() error:err]; if (!lib) return nil;
    *np = [g_gdev newLibraryWithSource:@(m + strlen(GAL_MSL_NP)) options:gal_msl_opts() error:err];
    return *np ? lib : nil;
}

// ---------- 错误与计数 ----------
static char g_last_err[512];
static uint32_t g_stats[6];   // 0 建成 1 失败 2 离线库命中 3 离线库未命中（iOS 红计数）4 运行时现编 5 内存缓存命中
static void set_err(const char *cls, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void set_err(const char *cls, const char *fmt, ...) {
    char msg[480]; va_list ap; va_start(ap, fmt); vsnprintf(msg, sizeof msg, fmt, ap); va_end(ap);
    snprintf(g_last_err, sizeof g_last_err, "%s｜%s", cls, msg);   // 「类｜详情」：单测按类统计失败
    // 每一类失败首例报红（类名 = cls）
    static char seen[32][32]; static int nseen;
    for (int i = 0; i < nseen; i++) if (!strcmp(seen[i], cls)) return;
    if (nseen < 32) snprintf(seen[nseen++], 32, "%s", cls);
    GLOG("【红】程序：%s", g_last_err);
}

// ---------- SPIR-V → MSL + 布局（Mac；离线工具也走这里）----------
#if GAL_HAVE_XC
typedef struct { uint32_t set, binding, count, kind, id, nid; int is_combined; spvc_variable_id var; } xc_ent;
static void xc_err_cb(void *ud, const char *msg) { snprintf((char *)ud, 512, "%s", msg); }

static int ctype_of(spvc_compiler c, spvc_type_id tid) {
    spvc_basetype b = spvc_type_get_basetype(spvc_compiler_get_type_handle(c, tid));
    switch (b) {
    case SPVC_BASETYPE_UINT8: case SPVC_BASETYPE_UINT16: case SPVC_BASETYPE_UINT32: case SPVC_BASETYPE_UINT64: return 1;
    case SPVC_BASETYPE_INT8: case SPVC_BASETYPE_INT16: case SPVC_BASETYPE_INT32: case SPVC_BASETYPE_INT64: return 2;
    default: return 0;
    }
}
static uint32_t array_count(spvc_compiler c, spvc_type t) {
    unsigned nd = spvc_type_get_num_array_dimensions(t); uint32_t n = 1;
    for (unsigned d = 0; d < nd; d++) {
        uint32_t v;
        if (spvc_type_array_dimension_is_literal(t, d)) v = spvc_type_get_array_dimension(t, d);
        else { spvc_constant k = spvc_compiler_get_constant_handle(c, spvc_type_get_array_dimension(t, d)); v = k ? spvc_constant_get_scalar_u32(k, 0, 0) : 0; }
        n *= v;   // 运行时长度数组 → 0（下面判失败）
    }
    return n;
}

// 解析 MSL 里 struct spvDescriptorSetBuffer<set> 的成员：按真实成员累加偏移（第 2 档每元素 8 字节）
typedef struct { uint32_t id, offset, count; char name[96]; } msl_mbr;
static int parse_set_struct(const char *msl, int set, msl_mbr *m, int cap, uint32_t *size, char *why) {
    char head[64]; snprintf(head, sizeof head, "struct spvDescriptorSetBuffer%d\n{\n", set);
    const char *p = strstr(msl, head); *size = 0;
    if (!p) return 0;
    p += strlen(head);
    int n = 0; uint32_t off = 0;
    while (*p && strncmp(p, "};", 2)) {
        const char *e = strchr(p, '\n'); if (!e) break;
        char ln[512]; size_t L = (size_t)(e - p) < sizeof ln - 1 ? (size_t)(e - p) : sizeof ln - 1; memcpy(ln, p, L); ln[L] = 0; p = e + 1;
        char *s = ln; while (*s == ' ' || *s == '\t') s++;
        if (!*s) continue;
        char *idp = strstr(s, " [[id("); if (!idp) { snprintf(why, 256, "集 %d 成员无 [[id]]：%s", set, s); return -1; }
        uint32_t id = (uint32_t)strtoul(idp + 6, NULL, 10);
        *idp = 0;   // s = "类型 名字" 或 "类型 名字[N]"
        char *sp = strrchr(s, ' '); if (!sp) { snprintf(why, 256, "集 %d 成员认不出：%s", set, s); return -1; }
        char *name = sp + 1; *sp = 0; const char *type = s;
        uint32_t count = 1;
        char *br = strchr(name, '['); if (br) { count = (uint32_t)strtoul(br + 1, NULL, 10); *br = 0; }
        if (!strncmp(type, "array<", 6)) { const char *c = strrchr(type, ','); count *= c ? (uint32_t)strtoul(c + 1, NULL, 10) : 0; }
        // 只认 8 字节句柄 / 指针成员：其余（内联常量块等）布局另算，一律当失败
        int ok = strchr(type, '*') || strstr(type, "texture") || strstr(type, "depth") || strstr(type, "sampler");
        if (!ok || !count) { snprintf(why, 256, "集 %d 成员类型不是 8 字节句柄：%s %s", set, type, name); return -1; }
        if (n == cap) { snprintf(why, 256, "集 %d 成员过多", set); return -1; }
        m[n].id = id; m[n].offset = off; m[n].count = count; snprintf(m[n].name, sizeof m[n].name, "%s", name); n++;
        off += 8 * count;
    }
    *size = off;
    return n;
}

static int ent_cmp(const void *a, const void *b) {
    const xc_ent *x = a, *y = b;
    if (x->set != y->set) return x->set < y->set ? -1 : 1;
    if (x->binding != y->binding) return x->binding < y->binding ? -1 : 1;
    return 0;
}

// 计算着色器共享内存溢出改写在 gal_spill.c（#783 搬出，纯 C）；这里只留运行时入口与上限：运行时按 MTLDevice 当场查询，
//   离线出库（gal_xc 不建设备）按目标设备常量 GAL_TG_MEM_MAX——与搬出前 spill_msl_at 里的取法相同
uint32_t gal_spill_limit(void) { return g_gdev ? (uint32_t)g_gdev.maxThreadgroupMemoryLength : GAL_TG_MEM_MAX; }
static char *spill_msl(const char *src, uint32_t *bytes, char *why) { return gal_spill_msl(src, GAL_SPILL_SLOT, bytes, why); }

// NoContraction（Ryujinx 给浮点乘加打的「不许合并」标记，保证深度预通道与主通道算出的位置逐位一样）：SPIRV-Cross 生成 [[clang::optnone]] 的
// spvFAdd / spvFSub / spvFMul* 辅助函数——optnone 在 clang 里同时禁内联，每次乘加都成一次不优化的函数调用（动森岛片元着色器一支 446 次）。
// 改为强制内联 + 文件级 #pragma METAL fp contract(off)：同样不合并成 fma（中间码里 contract 标记去掉，已核），没有调用开销。
// Air galrec4 每帧 GPU 12.9 → 7.4 ms；spvQuantizeToF16 等靠 optnone 防折叠的不动
static char *nocontract_fix(char *src) {
    static const char *k[] = {"T spvFAdd(", "T spvFSub(", "T spvFMul(", "vec<T, Cols> spvFMulVectorMatrix(", "vec<T, Rows> spvFMulMatrixVector(", "matrix<T, RCols, LRows> spvFMulMatrixMatrix("};
    static const char on[] = "[[clang::optnone]] ", in[] = "[[clang::always_inline]] inline ", pr[] = "#pragma METAL fp contract(off)\n";
    { static int keep = -1; if (keep < 0) { const char *v = getenv("NXGAL_XC_OPTNONE_KEEP"); keep = v && *v == '1'; } if (keep) return src; }   // A/B（只量收益用）：=1 保留原 optnone，同一翻译口径出对照库
    int hit = 0; for (int i = 0; i < 6; i++) { char pat[96]; snprintf(pat, sizeof pat, "%s%s", on, k[i]); if (strstr(src, pat)) hit++; }
    if (!hit) return src;
    size_t n = strlen(src); char *o = malloc(n + sizeof pr + hit * (sizeof in - sizeof on) + 1), *w = o; memcpy(w, pr, sizeof pr - 1); w += sizeof pr - 1;
    for (const char *p = src; *p; ) {
        int m = 0;
        if (!strncmp(p, on, sizeof on - 1)) for (int i = 0; i < 6; i++) if (!strncmp(p + sizeof on - 1, k[i], strlen(k[i]))) { m = 1; break; }
        if (m) { memcpy(w, in, sizeof in - 1); w += sizeof in - 1; p += sizeof on - 1; } else *w++ = *p++;
    }
    *w = 0; free(src); return o;
}
// 片元的用户输入分量数（不含内建）：每个输入 = 向量宽 × 列数 × 数组元素数
static _Atomic uint32_t g_frag_in_over;   // 片元输入超 124 分量的着色器数（含降级成功的）
static uint32_t frag_in_comps(spvc_compiler c, spvc_resources res) {
    const spvc_reflected_resource *l; size_t n; uint32_t comps = 0;
    spvc_resources_get_resource_list_for_type(res, SPVC_RESOURCE_TYPE_STAGE_INPUT, &l, &n);
    for (size_t i = 0; i < n; i++) {
        if (spvc_compiler_has_decoration(c, l[i].id, SpvDecorationBuiltIn)) continue;
        spvc_type t = spvc_compiler_get_type_handle(c, l[i].type_id), bt = spvc_compiler_get_type_handle(c, l[i].base_type_id);
        uint32_t ac = spvc_type_get_num_array_dimensions(t) ? array_count(c, t) : 1;
        comps += spvc_type_get_vector_size(bt) * spvc_type_get_columns(bt) * (ac ? ac : 1);
    }
    return comps;
}
// 翻一支：成功返回 1，*msl_out = malloc 的 MSL 源码，rec 填好（args malloc）
static atomic_uint g_vpull_fallback;   // 顶点着色器 MSL 不规整、没改成自取的支数（照旧顶点描述符）
static atomic_uint g_color_round_skip;   // 片元颜色出口改写失败、保留原 MSL 并禁用该程序量化的支数
// 原始位输入的顶点着色器（Ryujinx 补丁 vattr-raw）不看本开关、一律自取（见 xc_shader1）；本开关只管按类型声明的旧口径着色器
// 缺省关（10-20）：顶点自取让基础管线编译 26 → 39 ms（psobench），出包预编（2c）落地、测试机1 GPU A/B 量完再改缺省开；NXGAL_VPULL=1 开（出包时给，记录位 4 随库走，运行时按记录）
int gal_vpull_on(void) { static int on = -1; if (on < 0) { const char *v = getenv("NXGAL_VPULL"); on = v && *v == '1'; } return on; }
// ---------- 曲面细分（计算展开）：翻译选项与 MSL 后处理在 gal_tessxc.m（与直连离线链共用，直连链版本按那份源码算）----------
// vt：顶点着色器按「曲面细分前的顶点」翻成计算核（SPIRV-Cross vertex_for_tessellation），键 = 原键 ^ GAL_VT_SALT（同一支 SPIR-V 两种入口，离线库按键各存一份）
// fbf：片元帧缓冲读取变体（gal_fbr.m 改写过的 SPIR-V，SubpassData 输入附件译成 [[color(n)]]）
static int xc_shader1(const uint8_t *spv, uint32_t len, int platform, int np, int vt, int fbf, char **msl_out, shd_rec *rec, char *why) {
    *msl_out = NULL; memset(rec, 0, sizeof *rec);
    if (len < 20 || (len & 3) || *(const uint32_t *)spv != 0x07230203) { snprintf(why, 256, "不是 SPIR-V（长 %u）", len); return 0; }
    rec->hash = gal_spv_hash(spv, len) ^ (vt ? GAL_VT_SALT : 0);
    spvc_context ctx = NULL; int ok = 0; char cberr[512] = "";
    if (spvc_context_create(&ctx) != SPVC_SUCCESS) { snprintf(why, 256, "SPIRV-Cross 上下文建不出"); return 0; }
    spvc_context_set_error_callback(ctx, xc_err_cb, cberr);
    spvc_parsed_ir ir = NULL; spvc_compiler c = NULL;
    char (*bs_name)[96] = NULL; uint16_t *bs_bind = NULL; int nbs = 0;   // 自定义边框色改写要的单个采样器成员（下面按 MSL 结构体收）
    xc_ent *ents = NULL; int nent = 0;
    {   // 越界钳位 + 循环上限（gal_spvx.m）：键仍按原 SPIR-V 算，改写口径变了靠 NXGAL_XC_VERSION 作废旧库
        static int harden = -1; if (harden < 0) { const char *v = getenv("NXGAL_SPVX"); harden = !(v && *v == '0'); if (!harden) GLOG("【红】NXGAL_SPVX=0：SPIR-V 加固关（只许诊断，不得出包）"); }
        uint32_t gw = 0; uint32_t *g = harden ? gal_spv_harden((const uint32_t *)spv, len / 4, &gw, NULL) : NULL;
        int pr = spvc_context_parse_spirv(ctx, g ? (const SpvId *)g : (const SpvId *)spv, g ? gw : len / 4, &ir); free(g);
        if (pr != SPVC_SUCCESS) { snprintf(why, 256, "SPIRV-Cross 解析失败：%s", cberr); goto out; }
    }
    if (spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &c) != SPVC_SUCCESS) { snprintf(why, 256, "SPIRV-Cross 建编译器失败：%s", cberr); goto out; }
    {
        const spvc_entry_point *eps; size_t neps;
        spvc_compiler_get_entry_points(c, &eps, &neps);
        if (neps != 1) { snprintf(why, 256, "入口数 %zu ≠ 1", neps); goto out; }
        SpvExecutionModel model = eps[0].execution_model;
        int stage = model == SpvExecutionModelVertex ? 1 : model == SpvExecutionModelFragment ? 5 : model == SpvExecutionModelGLCompute ? 0
                  : model == SpvExecutionModelTessellationControl ? 2 : model == SpvExecutionModelTessellationEvaluation ? 3 : model == SpvExecutionModelGeometry ? 4 : -1;
        if (stage < 0 || stage == 4) { snprintf(why, 256, "阶段不支持（执行模型 %d；几何属第 8 块）", (int)model); goto out; }
        if (vt && stage != 1) { snprintf(why, 256, "曲面前顶点变体只给顶点着色器（执行模型 %d）", (int)model); goto out; }
        rec->stage = (uint32_t)stage;
        int tess = vt || stage == 2 || stage == 3;
        if (tess && !gal_tessxc_modes(c, stage, vt, &rec->flags, &rec->tg[0], why)) goto out;
        char newname[40]; snprintf(newname, sizeof newname, "s%016llx%s", (unsigned long long)rec->hash, np ? "_np" : "");
        spvc_compiler_rename_entry_point(c, eps[0].name, newname, model);

        spvc_compiler_options o = NULL; spvc_compiler_create_compiler_options(c, &o);
        // MSL 3.1：Metal 4 设备都支持；3.1 起图像原子走原生（2.3 时 SPIRV-Cross 用附带缓冲模拟，多出的 _atomic 成员与别的资源撞 [[id]]，acnh 语料 2 支因此失败）
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_VERSION, SPVC_MAKE_MSL_VERSION(3, 1, 0));
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_PLATFORM, (unsigned)platform);
        // iOS：顶点着色器用到 BaseVertex / BaseInstance 时 SPIRV-Cross 要显式声明支持（A9+ 都支持），否则 16% 着色器翻译失败（出包线 10-18 实测 467 支里 75 支）
        if (platform == SPVC_MSL_PLATFORM_IOS) spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_IOS_SUPPORT_BASE_VERTEX_INSTANCE, SPVC_TRUE);
        // iOS：子群操作用 simdgroup（32 线程，A13+ 都有），不用 SPIRV-Cross 缺省的 quad（4 线程）——Switch 着色器按 32 线程线程束写，
        // quad 版 ballot / shuffle 只看 4 条线程，结果错（10-18 同一批 467 支两平台翻译比对：17 支 ballot + 1 支 shuffle 只在此处不同）
        if (platform == SPVC_MSL_PLATFORM_IOS) spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_IOS_USE_SIMDGROUP_FUNCTIONS, SPVC_TRUE);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, SPVC_TRUE);
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS_TIER, 1);   // Tier2
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_TEXTURE_BUFFER_NATIVE, SPVC_TRUE);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_PAD_FRAGMENT_OUTPUT_COMPONENTS, SPVC_TRUE);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_FORCE_ACTIVE_ARGUMENT_BUFFER_RESOURCES, SPVC_TRUE);
        // 缓冲长度表：着色器实际读参数缓冲里的那份（GAL_ARG_SIZES）；SPIRV-Cross 另在入口签名里留一个 [[buffer(n)]] 参数（不读），n 定为参数表 24 号（后端内部段）
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_BUFFER_SIZE_BUFFER_INDEX, 24);
        if (np) spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_ENABLE_POINT_SIZE_BUILTIN, SPVC_FALSE);   // 变体：点大小写成普通成员
        if (fbf) spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_FRAMEBUFFER_FETCH_SUBPASS, SPVC_TRUE);
        if (tess) gal_tessxc_options(c, o, vt, GAL_TESS_SLOT_IN);
        spvc_compiler_install_compiler_options(c, o);

        // ---- 资源反射 → 显式 [[id]] ----
        spvc_resources res = NULL; spvc_compiler_create_shader_resources(c, &res);
        static const spvc_resource_type kinds[] = { SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, SPVC_RESOURCE_TYPE_STORAGE_BUFFER, SPVC_RESOURCE_TYPE_SAMPLED_IMAGE,
            SPVC_RESOURCE_TYPE_SEPARATE_IMAGE, SPVC_RESOURCE_TYPE_SEPARATE_SAMPLERS, SPVC_RESOURCE_TYPE_STORAGE_IMAGE };
        size_t cap = 0;
        for (int k = 0; k < 6; k++) { const spvc_reflected_resource *l; size_t n; spvc_resources_get_resource_list_for_type(res, kinds[k], &l, &n); cap += n; }
        ents = calloc(cap + 1, sizeof *ents);
        for (int k = 0; k < 6; k++) {
            const spvc_reflected_resource *l; size_t n; spvc_resources_get_resource_list_for_type(res, kinds[k], &l, &n);
            for (size_t i = 0; i < n; i++) {
                xc_ent *e = &ents[nent++]; e->var = l[i].id;
                e->set = spvc_compiler_get_decoration(c, l[i].id, SpvDecorationDescriptorSet);
                e->binding = spvc_compiler_get_decoration(c, l[i].id, SpvDecorationBinding);
                spvc_type t = spvc_compiler_get_type_handle(c, l[i].type_id);
                e->count = array_count(c, t);
                spvc_type bt = spvc_compiler_get_type_handle(c, l[i].base_type_id);
                int buf_dim = (kinds[k] != SPVC_RESOURCE_TYPE_UNIFORM_BUFFER && kinds[k] != SPVC_RESOURCE_TYPE_STORAGE_BUFFER && kinds[k] != SPVC_RESOURCE_TYPE_SEPARATE_SAMPLERS)
                              && spvc_type_get_image_dimension(bt) == SpvDimBuffer;
                switch (kinds[k]) {
                case SPVC_RESOURCE_TYPE_UNIFORM_BUFFER: e->kind = GAL_ARG_UBO; break;
                case SPVC_RESOURCE_TYPE_STORAGE_BUFFER: e->kind = e->binding == GAL_UBOLEN_BINDING ? GAL_ARG_UBOLEN : e->binding == GAL_OOBCNT_BINDING ? GAL_ARG_OOBCNT : GAL_ARG_SSBO; break;
                case SPVC_RESOURCE_TYPE_SAMPLED_IMAGE: e->kind = buf_dim ? GAL_ARG_BUFTEX : GAL_ARG_TEX; e->is_combined = !buf_dim; break;
                case SPVC_RESOURCE_TYPE_SEPARATE_IMAGE: e->kind = buf_dim ? GAL_ARG_BUFTEX : GAL_ARG_TEX; break;
                case SPVC_RESOURCE_TYPE_SEPARATE_SAMPLERS: e->kind = GAL_ARG_SMP; break;
                default: e->kind = buf_dim ? GAL_ARG_BUFIMG : GAL_ARG_IMG; break;
                }
                if (e->set >= GAL_MAX_SETS) { snprintf(why, 256, "资源 %s 在集 %u（≥ %d）", l[i].name, e->set, GAL_MAX_SETS); goto out; }
                if (!e->count) { snprintf(why, 256, "资源 %s 是运行时长度数组（集 %u 绑定 %u），参数缓冲需定长", l[i].name, e->set, e->binding); goto out; }
                if (e->kind == GAL_ARG_UBOLEN) {   // 常量缓冲长度表的元素个数（gal_spvx.m 建的 uint[n]）记在 nid，进记录的 slot
                    spvc_type mt = spvc_compiler_get_type_handle(c, spvc_type_get_member_type(bt, 0));
                    e->nid = spvc_type_get_num_array_dimensions(mt) == 1 ? array_count(c, mt) : 0;
                    if (!e->nid) { snprintf(why, 256, "常量缓冲长度表类型认不出（集 %u）", e->set); goto out; }
                }
            }
        }
        qsort(ents, nent, sizeof *ents, ent_cmp);
        uint32_t next[GAL_MAX_SETS] = {0}; int has_ssbo[GAL_MAX_SETS] = {0};
        SpvExecutionModel em = model;
        for (int i = 0; i < nent; i++) {
            xc_ent *e = &ents[i];
            if (i && e->set == ents[i - 1].set && e->binding == ents[i - 1].binding) { snprintf(why, 256, "集 %u 绑定 %u 被两个变量占用", e->set, e->binding); goto out; }
            spvc_msl_resource_binding_2 b; spvc_msl_resource_binding_init_2(&b);
            b.stage = em; b.desc_set = e->set; b.binding = e->binding; b.count = e->count;
            e->id = next[e->set];
            if (e->kind == GAL_ARG_UBO || e->kind == GAL_ARG_SSBO || e->kind == GAL_ARG_UBOLEN || e->kind == GAL_ARG_OOBCNT) { b.msl_buffer = e->id; next[e->set] += e->count; if (e->kind == GAL_ARG_SSBO) has_ssbo[e->set] = 1; }
            else if (e->kind == GAL_ARG_SMP) { b.msl_sampler = e->id; next[e->set] += e->count; }
            else if (e->is_combined) { b.msl_texture = e->id; b.msl_sampler = e->nid = e->id + e->count; next[e->set] += 2 * e->count; }
            else { b.msl_texture = e->id; next[e->set] += e->count; }
            spvc_compiler_msl_add_resource_binding_2(c, &b);
        }
        uint32_t size_id[GAL_MAX_SETS];
        for (int s = 0; s < GAL_MAX_SETS; s++) {
            size_id[s] = UINT32_MAX;
            if (!has_ssbo[s]) continue;
            spvc_msl_resource_binding_2 b; spvc_msl_resource_binding_init_2(&b);
            b.stage = em; b.desc_set = (unsigned)s; b.binding = SPVC_MSL_BUFFER_SIZE_BUFFER_BINDING; b.count = 1; b.msl_buffer = size_id[s] = next[s]++;
            spvc_compiler_msl_add_resource_binding_2(c, &b);
        }

        // ---- 片元输入分量上限（测试出包线 10-19 测试机1 实测：Apple GPU 片元输入最多 124 个分量，32 个 float4 全读 = 128 建管线失败、
        //      XPC 编译服务中断而不是正常报错）：声明的用户输入超 124 时只保留实际读到的（SPIRV-Cross 活跃接口变量）；还超就判失败报红，不交给 Metal 崩 ----
        if (stage == 5) {
            uint32_t comps = frag_in_comps(c, res);
            if (comps > 124) {
                spvc_set act = NULL; spvc_compiler_get_active_interface_variables(c, &act); spvc_compiler_set_enabled_interface_variables(c, act);
                spvc_resources ra = NULL; spvc_compiler_create_shader_resources_for_active_variables(c, &ra, act);
                uint32_t used = ra ? frag_in_comps(c, ra) : comps;
                atomic_fetch_add(&g_frag_in_over, 1);
                if (used > 124) { snprintf(why, 256, "片元输入 %u 个分量，只留实际读到的也有 %u 个，超 Apple GPU 上限 124（键 %016llx）", comps, used, (unsigned long long)rec->hash); goto out; }
                GLOG("【红】片元声明了 %u 个输入分量（超上限 124），只保留实际读到的 %u 个（键 %016llx，累计 %u 支）", comps, used, (unsigned long long)rec->hash, atomic_load(&g_frag_in_over));
            }
        }
        // ---- 阶段输入 / 输出、线程组 ----
        if (stage == 1 || stage == 5) {
            const spvc_reflected_resource *l; size_t n;
            spvc_resources_get_resource_list_for_type(res, stage == 1 ? SPVC_RESOURCE_TYPE_STAGE_INPUT : SPVC_RESOURCE_TYPE_STAGE_OUTPUT, &l, &n);
            for (size_t i = 0; i < n; i++) {
                if (!spvc_compiler_has_decoration(c, l[i].id, SpvDecorationLocation)) continue;
                uint32_t loc = spvc_compiler_get_decoration(c, l[i].id, SpvDecorationLocation);
                if (loc >= (stage == 1 ? 32u : 8u)) { snprintf(why, 256, "%s 位置 %u 越界", stage == 1 ? "顶点输入" : "片元输出", loc); goto out; }
                rec->io_mask |= 1u << loc; rec->io_ctype[loc] = (uint8_t)ctype_of(c, l[i].base_type_id);
            }
        }
        if (stage == 0) for (int i = 0; i < 3; i++) { rec->tg[i] = spvc_compiler_get_execution_mode_argument_by_index(c, SpvExecutionModeLocalSize, (unsigned)i); if (!rec->tg[i]) rec->tg[i] = 1; }

        const char *src = NULL;
        if (spvc_compiler_compile(c, &src) != SPVC_SUCCESS || !src) { snprintf(why, 256, "SPIRV-Cross 转 MSL 失败：%s", cberr); goto out; }

        rec->size_buf = strstr(src, "spvBufferSizeConstants [[buffer(24)]]") ? 24 : -1;
        if ((rec->stage == 1 || rec->stage == 3) && strstr(src, "[[point_size]]")) rec->flags |= 1;   // 曲面程序的「顶点函数」是 TES（gal_tess.m）
        // 写视口号（[[viewport_array_index]]，能力表 supportsViewportIndexVertexTessellation）与写层号同约束：管线必须指定拓扑类别
        if ((rec->stage == 1 || rec->stage == 3) && (strstr(src, "[[render_target_array_index]]") || strstr(src, "[[viewport_array_index]]"))) rec->flags |= 8;   // 写层号：管线必须指定拓扑类别（基础管线不能留「未指定」，gal_state.m / shbake/pso_gen.py）   // 写层号：管线必须指定拓扑类别（基础管线不能留「未指定」，gal_state.m / shbake/pso_gen.py）
        // ---- 按真实 MSL 结构体核对偏移 ----
        rec->args = calloc((size_t)nent * 2 + GAL_MAX_SETS + 1, sizeof *rec->args);
        msl_mbr *mb = calloc(1024, sizeof *mb);
        // 自定义边框色改写（gal_border.m）要的：参数缓冲里单个采样器成员（不是数组、不在数组集 ≥ 4）的 MSL 名与绑定号
        bs_name = calloc((size_t)nent * 2 + 1, sizeof *bs_name); bs_bind = calloc((size_t)nent * 2 + 1, sizeof *bs_bind);
        for (int s = 0; s < GAL_MAX_SETS; s++) {
            uint32_t sz; int nm = parse_set_struct(src, s, mb, 1024, &sz, why);
            if (nm < 0) { free(mb); goto out; }
            rec->set_size[s] = sz;
            int want = 0;
            for (int i = 0; i < nent; i++) if ((int)ents[i].set == s) want += ents[i].is_combined ? 2 : 1;
            int sizes_seen = 0;
            for (int j = 0; j < nm; j++) {
                msl_mbr *m = &mb[j];
                // 反例检查：真实偏移必须 = id × 8（稠密）
                if (m->offset != m->id * 8) { snprintf(why, 256, "集 %d 成员 %s：[[id(%u)]] 真实偏移 %u ≠ id×8", s, m->name, m->id, m->offset); free(mb); goto out; }
                if (m->id == size_id[s] && !strcmp(m->name, "spvBufferSizeConstants")) {
                    rec->args[rec->nargs++] = (shd_arg){GAL_ARG_SIZES, (uint8_t)s, 0xffff, m->offset, 1, 0}; sizes_seen = 1; continue;
                }
                int hit = 0;
                for (int i = 0; i < nent && !hit; i++) {
                    xc_ent *e = &ents[i]; if ((int)e->set != s) continue;
                    if (m->id == e->id) {
                        if (m->count != e->count) { snprintf(why, 256, "集 %d 成员 %s 个数 %u ≠ 反射 %u", s, m->name, m->count, e->count); free(mb); goto out; }
                        rec->args[rec->nargs++] = (shd_arg){(uint8_t)e->kind, (uint8_t)s, (uint16_t)e->binding, m->offset, e->count, e->kind == GAL_ARG_SSBO ? e->id : e->kind == GAL_ARG_UBOLEN ? e->nid : 0};
                        if (e->kind == GAL_ARG_SMP && e->count == 1 && s < 4) { snprintf(bs_name[nbs], 96, "%s", m->name); bs_bind[nbs++] = (uint16_t)e->binding; }
                        hit = 1;
                    } else if (e->is_combined && e->kind != GAL_ARG_UBOLEN && e->kind != GAL_ARG_OOBCNT && m->id == e->nid) {
                        if (m->count != e->count) { snprintf(why, 256, "集 %d 采样器成员 %s 个数 %u ≠ 反射 %u", s, m->name, m->count, e->count); free(mb); goto out; }
                        rec->args[rec->nargs++] = (shd_arg){GAL_ARG_SMP, (uint8_t)s, (uint16_t)e->binding, m->offset, e->count, 0};
                        if (e->count == 1 && s < 4) { snprintf(bs_name[nbs], 96, "%s", m->name); bs_bind[nbs++] = (uint16_t)e->binding; }
                        hit = 1;
                    }
                }
                if (!hit) { snprintf(why, 256, "集 %d 成员 %s [[id(%u)]] 对不上任何资源", s, m->name, m->id); free(mb); goto out; }
            }
            if (nm - sizes_seen != want) { snprintf(why, 256, "集 %d 结构体成员 %d 个 ≠ 反射资源 %d 个", s, nm - sizes_seen, want); free(mb); goto out; }
        }
        free(mb);
        if (tess) {
            char *t = gal_tessxc_post(c, res, src, stage, vt, newname, &rec->flags, GAL_TESS_SLOT_IN, why);
            if (!t) goto out;
            *msl_out = nocontract_fix(t); ok = 1;
        } else *msl_out = nocontract_fix(strdup(src)), ok = 1;
        // 顶点自取（第 2 步 2b）：改写不了就照旧走顶点描述符。原始位输入（Ryujinx 补丁 vattr-raw，成员 s2a_raw<位置>）不看开关、必须自取：
        //   顶点描述符给不出 Maxwell 寄存器位（unorm / snorm / scaled → 浮点位），改写不了就是翻译失败
        int raw_in = rec->stage == 1 && !vt && rec->io_mask && gal_vpull_raw_in(*msl_out, newname);
        if (rec->stage == 1 && !vt && rec->io_mask && (gal_vpull_on() || raw_in)) {
            char *vp = gal_vpull_msl(*msl_out, newname);
            if (vp) { free(*msl_out); *msl_out = vp; rec->flags |= 4; }
            else if (raw_in) { snprintf(why, 256, "顶点输入按原始位读（s2a_raw）但 MSL 输入结构不规整，改不成自取"); free(*msl_out); *msl_out = NULL; ok = 0; goto out; }
            else { unsigned k = atomic_fetch_add(&g_vpull_fallback, 1) + 1; if ((k & (k - 1)) == 0) GLOG("顶点自取：MSL 不规整、照旧走顶点描述符的第 %u 支（键 %016llx）", k, (unsigned long long)rec->hash); }
        }
        if (rec->stage == 0) {   // 计算着色器共享内存超 Apple 上限：超出的数组溢出到设备内存（记录 GAL_REC_SPILL，每线程组字节放 io_mask）
            uint32_t sb = 0; char *sp = spill_msl(*msl_out, &sb, why);
            if (sp == (char *)-1) { free(*msl_out); *msl_out = NULL; ok = 0; goto out; }
            if (sp) { free(*msl_out); *msl_out = sp; rec->flags |= GAL_REC_SPILL; rec->io_mask = sb; }
        }
        // 自定义边框色（gal_border.m）：入口里对单个采样器的 sample / gather 改走辅助函数；曲面各段不改（照旧最近三种之一）
        if (!tess && nbs) {
            const char *nmp[nbs]; for (int i = 0; i < nbs; i++) nmp[i] = bs_name[i];
            char *bo = gal_border_msl(*msl_out, newname, nmp, bs_bind, nbs);
            if (bo) { free(*msl_out); *msl_out = bo; rec->flags |= GAL_REC_BORDER; }
        }
        // 绘制号（GAL_DRAWID_SLOT）：把 SPIRV-Cross 固定的 [[buffer(19)]] 改到 27（两位数原地改）；曲面路径不改、报红（MSL 形态不同，没遇到过）
        if (rec->stage == 1) {
            static const char k_did[] = "spvDrawIndex [[buffer(19)]]";
            char *dp = strstr(*msl_out, k_did);
            if (dp && tess) GRED_ONCE("顶点着色器读绘制号（gl_DrawID）且带曲面细分：未改绑定，读到的是 19 号顶点缓冲（键 %016llx）", (unsigned long long)rec->hash);
            else if (dp) { char *num = dp + sizeof k_did - 1 - 5;   /* 末尾「19)]]」：两位数字在倒数第 5、4 个字符 */ num[0] = '0' + GAL_DRAWID_SLOT / 10; num[1] = '0' + GAL_DRAWID_SLOT % 10; rec->flags |= GAL_REC_DRAWID; }
        }
        // 宽线（gal_wline.m）：顶点着色器同一编译单元里加 s<键>_wl 入口（主入口改调同一函数体）；在边框改写之后，函数体里的边框辅助照用
        if (!tess && rec->stage == 1) {
            char *wl = gal_wline_msl(*msl_out, newname);
            if (wl) { free(*msl_out); *msl_out = wl; rec->flags |= GAL_REC_WLINE; }
        }
        if (rec->stage == 5) {
            char rwhy[256] = "";
            char *rounded = gal_color_round_msl(*msl_out, newname, rwhy);
            if (rounded) { free(*msl_out); *msl_out = rounded; rec->flags |= GAL_REC_COLOR_ROUND; }
            else { unsigned k = atomic_fetch_add(&g_color_round_skip, 1) + 1; if ((k & (k - 1)) == 0) GLOG("颜色出口量化：保留原 MSL、禁用量化的第 %u 支（键 %016llx 阶段 %u）：%s", k, (unsigned long long)rec->hash, rec->stage, rwhy); }
            // 逻辑运算（gal_logicop.m）：有整数颜色输出的片元在末尾追加 s<键>_lo 入口（原入口不改）；放在全部改写之后，_lob 副本带着量化 / 边框改写后的函数体
            char *lo = gal_logicop_msl(*msl_out, newname);
            if (lo) { free(*msl_out); *msl_out = lo; rec->flags |= GAL_REC_LOGICOP; }
        }
    }
out:
    free(bs_name); free(bs_bind);
    free(ents);
    spvc_context_destroy(ctx);
    if (!ok) { free(rec->args); rec->args = NULL; rec->nargs = 0; }
    return ok;
}
// 顶点着色器同时写层号（[[render_target_array_index]]）与点大小：Metal 要求写层号的管线指定拓扑类别（不能 Unspecified），而写点大小的管线
// 类别只能是 Point / Unspecified（10-18 本机逐组合实测：两者都写时只有 Point 能建）。画线 / 三角形要一份不输出点大小的变体（点大小对非点图元无意义，
// 画面不变）：同一 SPIR-V 关掉 SPIRV-Cross 点大小内建再翻一份，入口 s<键>_np，MSL 以 GAL_MSL_NP 分隔接在主份后面（离线工具拆成两个 .metal），记录位 1 标记
static int xc_shader(const uint8_t *spv, uint32_t len, int platform, char **msl_out, shd_rec *rec, char *why) {
    int vt = (platform & GAL_XC_VT) != 0, fbf = (platform & GAL_XC_FBF) != 0; platform &= ~(GAL_XC_VT | GAL_XC_FBF);
    if (!xc_shader1(spv, len, platform, 0, vt, fbf, msl_out, rec, why)) return 0;
    if (vt) return 1;
    if (rec->stage != 1 || !(strstr(*msl_out, "[[render_target_array_index]]") || strstr(*msl_out, "[[viewport_array_index]]")) || !strstr(*msl_out, "[[point_size]]")) return 1;
    char *np = NULL; shd_rec r2;
    if (!xc_shader1(spv, len, platform, 1, 0, fbf, &np, &r2, why)) { free(*msl_out); *msl_out = NULL; free(rec->args); rec->args = NULL; return 0; }
    free(r2.args);
    if ((r2.flags & 4) != (rec->flags & 4)) { snprintf(why, 256, "无点大小变体与主份顶点自取口径不一"); free(np); free(*msl_out); *msl_out = NULL; free(rec->args); rec->args = NULL; return 0; }
    if (strstr(np, "[[point_size]]")) { snprintf(why, 256, "无点大小变体里仍有 [[point_size]]"); free(np); free(*msl_out); *msl_out = NULL; free(rec->args); rec->args = NULL; return 0; }
    size_t a = strlen(*msl_out), b = strlen(np), m = strlen(GAL_MSL_NP);
    char *all = malloc(a + m + b + 1); memcpy(all, *msl_out, a); memcpy(all + a, GAL_MSL_NP, m); memcpy(all + a + m, np, b + 1);
    free(*msl_out); free(np); *msl_out = all; rec->flags |= 2;
    return 1;
}
#endif

// ---------- 着色器缓存（内存）与离线库 ----------
typedef struct { shd_rec r; id<MTLLibrary> lib, lib_np; } shd_ent;   // lib_np：无点大小变体所在库（记录位 1）
static shd_ent *g_shd; static int g_nshd, g_capshd;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_shd_map;
static int g_xc_enabled = GAL_HAVE_XC;
// 离线库
// 分片（gal_offline.py）：第 i 片含首键 ≥ g_off_first[i] 且 < g_off_first[i+1] 的函数；按键二分取片
#define OFF_MAXLIB 1024   // 离线库片数上限（gal_offline.py 缺省每片 .air 4 MB，10-21 起；九款最大约 110 片）
static id<MTLLibrary> g_off_libs[OFF_MAXLIB]; static uint64_t g_off_first[OFF_MAXLIB]; static int g_off_nlib;
static uint8_t *g_off_idx; static uint32_t g_off_n; static uint64_t g_off_len;
static id<MTLLibrary> off_lib(uint64_t h) {
    int lo = 0, hi = g_off_nlib;   // 找最后一个首键 ≤ h 的片
    while (lo < hi) { int mid = (lo + hi) / 2; if (g_off_first[mid] <= h) lo = mid + 1; else hi = mid; }
    return lo ? g_off_libs[lo - 1] : nil;
}
#define IDX_MAGIC 0x494c4147u   // "GALI"
#define IDX_VERSION 1u
#define GAL_XC_VERSION NXGAL_XC_VERSION   // 见 gal_abi.h
#define BIN_MAGIC 0x504c4147u   // "GALP"
// 2（10-22 画面·着色器线 gfxsh/fbrp）：记录之后可带读帧缓冲证明尾段（gal_fbr.m gal_fbr_ser，魔数 FBR2）；读时 1 照旧可读（没有尾段 = 没有证明）
#define BIN_VERSION 2u

static pthread_mutex_t g_shd_mu = PTHREAD_MUTEX_INITIALIZER;   // 着色器缓存表：GPU 线程读写，现编工作线程只经 finalize 由 GPU 线程写入（锁防将来扩展）
static shd_ent *shd_find(uint64_t h) {
    pthread_mutex_lock(&g_shd_mu); NSNumber *i = g_shd_map[@(h)]; shd_ent *e = i ? &g_shd[i.intValue] : NULL; pthread_mutex_unlock(&g_shd_mu); return e;
}
static shd_ent *shd_add(shd_rec *r, id<MTLLibrary> lib, id<MTLLibrary> lib_np) {
    pthread_mutex_lock(&g_shd_mu);
    if (!g_shd_map) g_shd_map = [NSMutableDictionary new];
    if (g_nshd == g_capshd) { g_capshd = g_capshd ? g_capshd * 2 : 256; g_shd = realloc(g_shd, g_capshd * sizeof *g_shd); memset((void *)(g_shd + g_nshd), 0, (g_capshd - g_nshd) * sizeof *g_shd); }
    shd_ent *e = &g_shd[g_nshd]; e->r = *r; e->lib = lib; e->lib_np = lib_np;
    g_shd_map[@(r->hash)] = @(g_nshd); g_nshd++;
    pthread_mutex_unlock(&g_shd_mu);
    return e;
}
static int off_lookup(uint64_t h, shd_rec *r) {
    if (!g_off_idx) return 0;
    const uint8_t *tab = g_off_idx + 24; uint32_t lo = 0, hi = g_off_n;
    while (lo < hi) {
        uint32_t mid = (lo + hi) / 2; uint64_t k; memcpy(&k, tab + mid * 16, 8);
        if (k == h) {
            uint32_t off, len; memcpy(&off, tab + mid * 16 + 8, 4); memcpy(&len, tab + mid * 16 + 12, 4);
            if ((uint64_t)off + len > g_off_len || !rec_read(g_off_idx + off, len, r) || r->hash != h) { set_err("离线索引坏", "离线索引记录损坏（键 %016llx）", (unsigned long long)h); return 0; }
            return 1;
        }
        if (k < h) lo = mid + 1; else hi = mid;
    }
    return 0;
}

// 只查不编、不报错（首遇现编的预查：未命中是常态，随后起异步作业）：内存缓存 → 离线库
static shd_ent *shd_lookup_quiet(uint64_t h) {
    shd_ent *e = shd_find(h); if (e) return e;
    shd_rec r;
    if (off_lookup(h, &r)) {
        id<MTLLibrary> L = off_lib(h); NSArray<NSString *> *fns = L.functionNames;
        if (![fns containsObject:fn_name(h)]) { free(r.args); return NULL; }
        g_stats[2]++; return shd_add(&r, L, (r.flags & 2) ? L : nil);
    }
    return NULL;
}
static void cache_write(const shd_rec *r, const char *msl);
static double ms_of(uint64_t t);
// 取一支着色器：内存缓存 → 离线库 → 运行时现编（spv 为空 = 只许前两条路，load_binary 用）
static shd_ent *shd_get(uint64_t h, const uint8_t *spv, uint32_t len, const shd_rec *expect, int vt) {
    shd_ent *e = shd_find(h);
    if (e) { g_stats[5]++; return e; }
    shd_rec r;
    if (off_lookup(h, &r)) {
        id<MTLLibrary> L = off_lib(h); NSArray<NSString *> *fns = L.functionNames;
        if (![fns containsObject:fn_name(h)]) { set_err("离线库缺函数", "离线索引有键 %016llx 但 metallib 里没有函数 %s", (unsigned long long)h, fn_name(h).UTF8String); free(r.args); return NULL; }
        if ((r.flags & 2) && ![fns containsObject:[fn_name(h) stringByAppendingString:@"_np"]]) { set_err("离线库缺函数", "键 %016llx 记录有无点大小变体，metallib 里没有 %s_np", (unsigned long long)h, fn_name(h).UTF8String); free(r.args); return NULL; }
        g_stats[2]++; return shd_add(&r, L, (r.flags & 2) ? L : nil);
    }
    if (g_off_idx) g_stats[3]++;
#if GAL_HAVE_XC
    if (g_xc_enabled && spv) {
        char why[256] = "", *msl = NULL;
        if (!xc_shader(spv, len, XC_PLATFORM | (vt ? GAL_XC_VT : 0), &msl, &r, why)) { set_err("SPIRV-Cross", "键 %016llx 翻译失败：%s", (unsigned long long)h, why); return NULL; }
        NSError *err = nil; id<MTLLibrary> np = nil;
        uint64_t tm0 = mach_absolute_time(); id<MTLLibrary> lib = msl_compile(msl, &np, &err);
        GLOG("着色器首遇现编（同步）：键 %016llx Metal %.1f ms", (unsigned long long)h, ms_of(mach_absolute_time() - tm0));
        // 同步现编（NXGAL_ASYNC_XC=0）与异步作业一样写持久缓存：Ryujinx 存的程序二进制只有键，下次开机 load_binary 要按键在缓存里找回 MSL
        if (lib) cache_write(&r, msl);
        free(msl);
        if (!lib) { set_err("Metal 编译", "键 %016llx MSL 编译失败：%s", (unsigned long long)h, err.localizedDescription.UTF8String); free(r.args); return NULL; }
        g_stats[4]++;
        return shd_add(&r, lib, np);
    }
#endif
    (void)len; (void)expect;
    set_err("离线库未命中", "键 %016llx 离线库未命中且不能现编（%s）", (unsigned long long)h, GAL_HAVE_XC ? (spv ? "现编已关" : "程序二进制里没有 SPIR-V") : "iOS 不现编");
    return NULL;
}

// ---------- 程序表：编号 → gal_prog 指针（本块建的 calloc 自有；内置辅助程序由调用方持有，只登记）----------
static gal_prog **g_progp; static uint8_t *g_prog_own; static uint32_t g_nprog, g_capprog;
static uint32_t *g_prog_free; static uint32_t g_nprog_free, g_capprog_free;
static int prog_finalize(uint32_t id, int blocking);
typedef struct xjob xjob;
typedef struct { int n; uint64_t h[6]; int stage[6]; xjob *job[6]; nxgal_res_desc *descs; int ndesc; uint64_t t_create; } ppend;
static ppend **g_pend; static uint32_t g_cappend;   // 挂起（首遇现编中）的程序：首用时收尾
gal_prog *gal_prog_get(uint32_t id) {
    if (!(id && id < g_nprog && g_progp[id] && g_progp[id]->live)) return NULL;
    if (id < g_cappend && g_pend[id]) { @autoreleasepool { prog_finalize(id, 1); } }   // 首用：没编完就等（同参照 IsLinked）
    return g_progp[id];
}
uint32_t gal_prog_slots(void) { return g_nprog; }
static uint32_t prog_slot(void) {
    if (g_nprog_free) return g_prog_free[--g_nprog_free];
    if (!g_nprog) g_nprog = 1;   // 0 = 空
    if (g_nprog >= g_capprog) {
        uint32_t nc = g_capprog ? g_capprog * 2 : 256;
        g_progp = realloc(g_progp, nc * sizeof *g_progp); g_prog_own = realloc(g_prog_own, nc);
        memset(g_progp + g_capprog, 0, (nc - g_capprog) * sizeof *g_progp); memset(g_prog_own + g_capprog, 0, nc - g_capprog); g_capprog = nc;
    }
    return g_nprog++;
}
static uint32_t prog_alloc(void) {
    uint32_t id = prog_slot();
    gal_prog *p = calloc(1, sizeof *p);
    // 分配失败不静默：10-24 怪猎 mhrise_1024183202_1 加载期低区耗尽（崩时空洞 6 MB），calloc 回空、下一句写成员段错误在 +0x9c，现场看不出是内存
    if (!p) { fprintf(stderr, "[gal] 【红】程序对象分配失败（calloc %zu 字节）：%s\n", sizeof *p, gal_mem_note()); abort(); }
    for (int i = 0; i < 6; i++) p->size_buf_index[i] = -1;
    p->status = 1; p->live = 1;
    g_progp[id] = p; g_prog_own[id] = 1;
    return id;
}
// 后端内置辅助程序（gal_draw.m 的 DrawTexture 等手搭的 gal_prog）登记进程序表；p 由调用方长期持有，本表不释放它
uint32_t gal_prog_register_builtin(gal_prog *p) {
    if (!p) return 0;
    uint32_t id = prog_slot();
    p->live = 1; g_progp[id] = p; g_prog_own[id] = 0;
    return id;
}

// 把一支着色器并进程序：同 (kind, set, binding) 且偏移相同的合成一条（stages 或位），偏移不同各留一条
static void prog_merge(gal_prog *p, shd_ent *e) {
    int st = (int)e->r.stage; uint32_t bit = 1u << st;
    __auto_type f = [MTL4LibraryFunctionDescriptor new]; f.library = e->lib; f.name = fn_name(e->r.hash);
    p->fn[st] = f; p->stage_hash[st] = e->r.hash;
    p->args = realloc(p->args, (p->nargs + e->r.nargs + 1) * sizeof *p->args);
    for (uint32_t i = 0; i < e->r.nargs; i++) {
        const shd_arg *a = &e->r.args[i]; int merged = 0;
        for (int j = 0; j < p->nargs && !merged; j++) {
            gal_arg *b = &p->args[j];
            if (b->kind == a->kind && b->set == a->set && b->binding == a->binding && b->offset == a->offset && b->count == a->count && b->slot == a->slot) { b->stages |= bit; merged = 1; }
        }
        if (!merged) p->args[p->nargs++] = (gal_arg){a->kind, a->set, a->binding, a->offset, a->count, bit, a->slot};
        p->set_stages[a->set] |= bit;
    }
    for (int s = 0; s < GAL_MAX_SETS; s++) {
        p->stage_set_size[st][s] = e->r.set_size[s];
        if (e->r.set_size[s] > p->set_size[s]) p->set_size[s] = e->r.set_size[s];
        if (e->r.set_size[s]) p->set_stages[s] |= bit;
    }
    if (st == 1 && (e->r.flags & GAL_REC_VT)) { p->vs_inputs = e->r.io_mask; memcpy(p->vs_input_ctype, e->r.io_ctype, 32); p->vs_pulled = (e->r.flags & 4) != 0; }   // 曲面前顶点计算核：点大小 / 层号看 TES
    else if (st == 1) { p->vs_inputs = e->r.io_mask; memcpy(p->vs_input_ctype, e->r.io_ctype, 32); p->vs_point_size = (e->r.flags & 1) != 0; p->vs_pulled = (e->r.flags & 4) != 0; p->vs_writes_layer = (e->r.flags & 8) != 0;
        p->vs_layer_np = (e->r.flags & 2) && e->lib_np;
        if (p->vs_layer_np) { __auto_type g = [MTL4LibraryFunctionDescriptor new]; g.library = e->lib_np; g.name = [fn_name(e->r.hash) stringByAppendingString:@"_np"]; p->fn_np = g; }
        else if (e->r.flags & 2) GRED_ONCE("顶点着色器 %016llx 写层号与点大小，但没有无点大小变体：画线 / 三角形的管线会建不出", (unsigned long long)e->r.hash); }
    if (st == 5) { p->fs_outputs = e->r.io_mask; memcpy(p->fs_output_ctype, e->r.io_ctype, 8); p->fs_color_round = (e->r.flags & GAL_REC_COLOR_ROUND) != 0; }
    if (e->r.flags & GAL_REC_BORDER) p->border_stages |= (uint8_t)(1u << st);
    if (st == 1 && (e->r.flags & GAL_REC_DRAWID)) p->drawid = 1;
    if (st == 1 && (e->r.flags & GAL_REC_WLINE) && !(e->r.flags & GAL_REC_VT)) {   // 宽线展开入口：写层号 + 点大小的走无点大小变体库里的 s<键>_np_wl
        id<MTLLibrary> L = p->vs_layer_np ? e->lib_np : e->lib; NSString *nm = [fn_name(e->r.hash) stringByAppendingString:p->vs_layer_np ? @"_np_wl" : @"_wl"];
        // 不查 functionNames（离线库一片几千个函数，每建一个程序列一遍太贵）：记录位为准，库里真没有时建宽线管线失败报红
        if (L) p->fn_wl = gal_be_fn_desc(L, nm);
    }
    // 逻辑运算入口（gal_logicop.m）：记录位为准、不查 functionNames（同宽线）
    if (st == 5 && (e->r.flags & GAL_REC_LOGICOP) && e->lib) p->fn_lo = gal_be_fn_desc(e->lib, [fn_name(e->r.hash) stringByAppendingString:@"_lo"]);
    p->size_buf_index[st] = e->r.size_buf;
    if (st == 0) { p->is_compute = 1; p->threadgroup = MTLSizeMake(e->r.tg[0], e->r.tg[1], e->r.tg[2]); p->cs_spill = (e->r.flags & GAL_REC_SPILL) ? e->r.io_mask : 0; }
    if (st == 2 || st == 3) {   // 曲面（gal_tess.m）：域 / 分区 / 绕序 / 点模式以 TES 为准（TCS 的须一致，否则因子布局对不上），输出控制点数取 TCS
        uint32_t f = e->r.flags; uint8_t dom = (f >> GAL_REC_DOM_SHIFT) & 3;
        if (st == 2) p->tess_ocp = (uint8_t)e->r.tg[0];
        if (p->is_tess && p->tess_dom && p->tess_dom != dom) { GRED_ONCE("曲面程序 TCS 与 TES 的域不一致（%u ≠ %u），按 TES", p->tess_dom, dom); }
        if (st == 3 || !p->tess_dom) { p->tess_dom = dom; p->tess_part = (f >> GAL_REC_SP_SHIFT) & 3; p->tess_cw = (f & GAL_REC_CW) != 0; p->tess_point = (f & GAL_REC_POINT) != 0; }
        if (f & GAL_REC_PATCH) p->tess_patch = 1;
        if (st == 3) { p->vs_point_size = (f & 1) != 0; p->vs_writes_layer = (f & 8) != 0; p->vs_layer_np = 0; }
        if (!p->is_tess) { p->is_tess = 1; gal_helper_kick(GH_TESS); }
    }
}
static uint64_t g_prog_variant;   // nxgal_prog_set_variant：同进程 A/B 时混进程序哈希，各变体的管线 / 计算管线缓存分开（缺省 0 = 与原先相同）
static void prog_finish_hash(gal_prog *p) {
    uint64_t buf[7]; for (int i = 0; i < 6; i++) buf[i] = p->stage_hash[i];
    buf[6] = g_prog_variant; if (!g_prog_variant) { p->hash = gal_spv_hash(buf, 6 * sizeof *buf); return; }
    p->hash = gal_spv_hash(buf, sizeof buf);
}

// 资源布局交叉核对：着色器里的资源应在 Gpu 层给的描述符里（类型相容）；不在 = Gpu 层不会绑它，报红但不判失败
static void check_descs(const gal_prog *p, const nxgal_res_desc *d, int nd) {
    if (!d || nd <= 0) return;
    for (int i = 0; i < p->nargs; i++) {
        const gal_arg *a = &p->args[i]; if (a->kind == GAL_ARG_SIZES || a->kind == GAL_ARG_UBOLEN || a->kind == GAL_ARG_OOBCNT) continue;   // 后端自己的表，不是 Gpu 层资源
        int found = 0, compat = 0;
        for (int j = 0; j < nd; j++) {
            if (d[j].set != a->set || d[j].binding != a->binding) continue;
            found = 1;
            int t = d[j].type;   // ResourceType
            compat = (a->kind == GAL_ARG_UBO && t == 0) || (a->kind == GAL_ARG_SSBO && t == 1) || (a->kind == GAL_ARG_TEX && (t == 2 || t == 4)) ||
                     (a->kind == GAL_ARG_SMP && (t == 3 || t == 4)) || (a->kind == GAL_ARG_IMG && t == 5) || (a->kind == GAL_ARG_BUFTEX && (t == 6 || t == 2 || t == 4)) || (a->kind == GAL_ARG_BUFIMG && (t == 7 || t == 5));
            if (compat) break;
        }
        if (!found) GRED_ONCE("程序资源（集 %u 绑定 %u 类 %u）不在 Gpu 层的资源布局里：Gpu 层不会绑定它（首例）", a->set, a->binding, a->kind);
        else if (!compat) GRED_ONCE("程序资源（集 %u 绑定 %u 类 %u）与资源布局类型不符（首例）", a->set, a->binding, a->kind);
    }
}

static void prog_env(void); static const char *g_spv_dump; static void spv_dump(uint64_t h, const void *code, uint32_t len, int vt);

// ---------- 首遇现编（方案第九节）：离线库 / 持久缓存都没命中的着色器，在前台需求线程上异步编 ----------
// 口径同参照（Ryujinx Vulkan 后端 ShaderCollection：后台编、绘制用到时 IsLinked 阻塞等编完）：建程序立即返回（状态 Incomplete），
// GPU 线程第一次取用（gal_prog_get / 阻塞 CheckProgramLink）时等它编完再合并；从不跳过、从不画错。等待次数 / 时长计数可查。
// 持久缓存：NXGAL_SHADER_CACHE_DIR=<目录>（iOS 由宿主给 Caches 目录）——编好后写 <键>.msl + <键>.rec，下次跳过 SPIRV-Cross 直接编 MSL。
// 开关：NXGAL_ASYNC_XC=0 改回同步现编；NXGAL_XC_LOG=<文件> 每支一行耗时（键 / 来源 / SPIRV-Cross ms / Metal ms / 建程序到首用 ms / 等待 ms）。
struct xjob {
    uint64_t h; uint8_t *spv; uint32_t len;
    dispatch_semaphore_t sem; volatile int done; int ok, added, from_disk, vt;   // vt：曲面前顶点计算核变体（键已异或 GAL_VT_SALT）
    int claimed;   // 0 排队中；1 已有线程在编（后台槽线程，或首用时还在排队、由等待线程就地编）
    // fbf：片元帧缓冲读取变体（gal_fbr.m），翻译带 GAL_XC_FBF
    int fbf;
    shd_rec r; void *lib, *lib_np;   // lib / lib_np：CFBridgingRetain 的 id<MTLLibrary>（lib_np = 无点大小变体，可空）
    char why[256];
    uint64_t t_start, t_xc, t_mtl;   // mach 时基
    uint32_t run_qos, run_active;   // 真实队列基准：进入编译时的线程 QoS / 同时在编数
};
static NSMutableDictionary<NSNumber *, NSValue *> *g_jobs;   // 键 → xjob*（同一支着色器多个程序共用一个作业）
static dispatch_queue_t g_xc_q; static dispatch_semaphore_t g_xc_slots; static int g_xc_n; static uint64_t g_xc_inline;
static int g_async = -1; static const char *g_cache_dir; static FILE *g_xc_log;
static uint64_t g_xs[8];   // 0 异步作业 1 持久缓存命中 2 失败 3 首用时未编完的程序 4 等待总 ms 5 等待最大 ms 6 建程序后 100 ms 内首用的程序 7 异步程序数
static double ms_of(uint64_t t) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)t * tb.numer / tb.denom / 1e6; }

#define CACHE_MAGIC 0x43414c47u   // "GLAC"
static int cache_read(uint64_t h, shd_rec *r, char **msl) {
    if (!g_cache_dir) return 0;
    char p[1200]; snprintf(p, sizeof p, "%s/%016llx.rec", g_cache_dir, (unsigned long long)h);
    NSData *d = [NSData dataWithContentsOfFile:@(p)]; if (!d || d.length < 8) return 0;
    uint32_t m, v; memcpy(&m, d.bytes, 4); memcpy(&v, (const uint8_t *)d.bytes + 4, 4);
    if (m != CACHE_MAGIC || v != GAL_XC_VERSION || !rec_read((const uint8_t *)d.bytes + 8, (uint32_t)d.length - 8, r) || r->hash != h) return 0;
    snprintf(p, sizeof p, "%s/%016llx.msl", g_cache_dir, (unsigned long long)h);
    NSString *src = [NSString stringWithContentsOfFile:@(p) encoding:NSUTF8StringEncoding error:nil];
    if (!src) { free(r->args); return 0; }
    *msl = strdup(src.UTF8String); return 1;
}
// 写持久缓存不挡作业完成（10-24 出图停 60 秒以上：现编线程卡在写缓存的 rename()，作业「完成」在写缓存之后，等这支程序的渲染线程跟着停；
//   就地编时写盘还落在等待线程上）：cache_write 当场只打包，写盘丢到一条后台串行队列。进程退出时最多等 2 秒排空（t_prog --cache-fill 子进程写完即退）
static dispatch_queue_t g_cw_q; static dispatch_group_t g_cw_g;
static void cache_write_drain(void) { dispatch_group_wait(g_cw_g, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)); }
// 单测钩子（tests/t_xcstall.m）：on = 1 时后台写盘在这里等到放开，模拟 rename() 在文件系统里卡住
static _Atomic int g_cw_hold; static dispatch_semaphore_t g_cw_gate;
NXGAL_API void nxgal_test_cache_write_hold(int on) {
    if (on) { if (!g_cw_gate) g_cw_gate = dispatch_semaphore_create(0); atomic_store(&g_cw_hold, 1); }
    else if (atomic_exchange(&g_cw_hold, 0) && g_cw_gate) dispatch_semaphore_signal(g_cw_gate);
}
static void cache_put(const char *dir, uint64_t h, char *msl, uint8_t *b, uint32_t n) {
    if (atomic_load(&g_cw_hold) && g_cw_gate) { dispatch_semaphore_wait(g_cw_gate, DISPATCH_TIME_FOREVER); dispatch_semaphore_signal(g_cw_gate); }
    char p[1200], t[1300];
    snprintf(p, sizeof p, "%s/%016llx.msl", dir, (unsigned long long)h); snprintf(t, sizeof t, "%s.%d.tmp", p, getpid());
    FILE *f = fopen(t, "wb"); if (f) { fputs(msl, f); fclose(f); rename(t, p); }
    snprintf(p, sizeof p, "%s/%016llx.rec", dir, (unsigned long long)h); snprintf(t, sizeof t, "%s.%d.tmp", p, getpid());   // .rec 后写：读端以它为准
    f = fopen(t, "wb"); if (f) { fwrite(b, 1, n, f); fclose(f); rename(t, p); }
    free(msl); free(b);
}
static void cache_write(const shd_rec *r, const char *msl) {
    if (!g_cache_dir) return;
    uint32_t n = rec_size(r); uint8_t *b = malloc(8 + n); uint32_t m = CACHE_MAGIC, v = GAL_XC_VERSION;
    memcpy(b, &m, 4); memcpy(b + 4, &v, 4); rec_write(r, b + 8);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_cw_q = dispatch_queue_create("nxgal.cachew", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
                            g_cw_g = dispatch_group_create(); atexit(cache_write_drain); });
    const char *dir = g_cache_dir; uint64_t h = r->hash; char *s = strdup(msl);
    dispatch_group_async(g_cw_g, g_cw_q, ^{ cache_put(dir, h, s, b, 8 + n); });
}
static _Atomic int g_xc_busy;   // 正在编的着色器作业数（gal_core.m 慢特化行报）
int gal_xc_busy(void) { return g_xc_busy; }
static void xjob_run(xjob *j) {
    j->run_active = ++g_xc_busy;
    j->run_qos = qos_class_self();
#if GAL_HAVE_XC
    @autoreleasepool {
        uint64_t t0 = mach_absolute_time(); char *msl = NULL;
        if (cache_read(j->h, &j->r, &msl)) j->from_disk = 1;
        else if (!xc_shader(j->spv, j->len, XC_PLATFORM | (j->vt ? GAL_XC_VT : 0) | (j->fbf ? GAL_XC_FBF : 0), &msl, &j->r, j->why)) { j->ok = 0; goto out; }
        else cache_write(&j->r, msl);
        uint64_t t1 = mach_absolute_time(); j->t_xc = t1 - t0;
        NSError *err = nil; id<MTLLibrary> np = nil, lib = msl_compile(msl, &np, &err);
        j->t_mtl = mach_absolute_time() - t1;
        free(msl);
        if (!lib) { snprintf(j->why, sizeof j->why, "MSL 编译失败：%s", err.localizedDescription.UTF8String); free(j->r.args); j->ok = 0; goto out; }
        j->lib = (void *)CFBridgingRetain(lib); j->lib_np = np ? (void *)CFBridgingRetain(np) : NULL; j->ok = 1;
    }
out:
#endif
    free(j->spv); j->spv = NULL;
    g_xc_busy--;
    __atomic_store_n(&j->done, 1, __ATOMIC_RELEASE);
    dispatch_semaphore_signal(j->sem);
}
static void xc_init(void) {
    if (g_jobs) return;
    g_jobs = [NSMutableDictionary new];
    int n = (int)[NSProcessInfo processInfo].activeProcessorCount; n = TARGET_OS_IPHONE ? 2 : (n / 4 > 2 ? n / 4 : 2);
    g_xc_n = n; g_xc_slots = dispatch_semaphore_create(n);
    // 缺省 USER_INITIATED（10-28 喷3 冷局第 42 帧「停帧」根因）：渲染线程（UI）在 SetProgram / 首用处阻塞等这里的作业，作业跑在 UTILITY = 优先级反转——
    //   宿主一忙（门禁 / 别的局），UTILITY 线程连同它发给 Metal 编译服务的请求被饿住：Air 8 个 DEFAULT 忙循环陪跑同场冷局，
    //   UTILITY 单支 SPIRV-Cross + Metal 最长 13 秒、加载帧 22–26 秒，USER_INITIATED 加载帧 1–4 秒；Mac 负载 16 时加载帧超 60 秒被判停帧。
    //   USER_INITIATED 仍低于渲染线程与游戏线程（UI），只压过 DEFAULT 及以下的后台负载；槽数不变。NXGAL_XC_QOS=utility 显式回到旧档（A/B 用）
    const char *q = getenv("NXGAL_XC_QOS");
    if (q && strcmp(q, "utility") && strcmp(q, "user-initiated")) { GLOG("【红】NXGAL_XC_QOS 只接受 utility / user-initiated，实得：%s", q); abort(); }
    qos_class_t qos = q && !strcmp(q, "utility") ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED;
    g_xc_q = dispatch_queue_create("nxgal.xc", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, qos, 0));
    GLOG("首遇现编队列：QoS %s，最多 %d 支并发", qos == QOS_CLASS_UTILITY ? "UTILITY" : "USER_INITIATED", n);
}
static xjob *xjob_start(uint64_t h, const uint8_t *spv, uint32_t len, int vt, int fbf) {
    xc_init();
    NSValue *v = g_jobs[@(h)]; if (v) return v.pointerValue;
    xjob *j = calloc(1, sizeof *j); j->h = h; j->len = len; j->vt = vt; j->fbf = fbf; j->spv = malloc(len); memcpy(j->spv, spv, len);
    j->sem = dispatch_semaphore_create(0); j->t_start = mach_absolute_time();
    g_jobs[@(h)] = [NSValue valueWithPointer:j]; g_xs[0]++;
    // 拿到槽时作业若已被首用的等待线程认领（就地编了），跳过
    dispatch_async(g_xc_q, ^{ dispatch_semaphore_wait(g_xc_slots, DISPATCH_TIME_FOREVER);
        if (!__atomic_exchange_n(&j->claimed, 1, __ATOMIC_ACQ_REL)) xjob_run(j);
        dispatch_semaphore_signal(g_xc_slots); });
    return j;
}
// 程序收尾：等（blocking）/ 查（非阻塞）各阶段作业，全部完成后在 GPU 线程合并。返回 ProgramLinkStatus
static int prog_finalize(uint32_t pid, int blocking) {
    ppend *pd = pid < g_cappend ? g_pend[pid] : NULL; gal_prog *p = g_progp[pid];
    if (!pd) return p->status;
    uint64_t now = mach_absolute_time(); int waited = 0;
    for (int i = 0; i < pd->n; i++) {
        xjob *j = pd->job[i]; if (!j || __atomic_load_n(&j->done, __ATOMIC_ACQUIRE)) continue;
        if (!blocking) return 2;
        // 首用时作业还在排队（没拿到槽）：等待线程自己就地编，不排在低优先级队列后面——10-21 Mac 怪猎 / 暗黑2 / 暗黑3 / 巫师3 局 GPU 线程在这里停 60 秒：
        // 现翻作业 UTILITY 档、只有 2–4 个槽，负载 60–80 时每支编 3–6 秒（缺省 / UI 档 0.13–0.25 秒），首用的那支排在一串后台作业后面。
        // 已在编的照等（本 MTLDevice 路径用 dispatch_block_wait 的旧对照无改善；不代表 Metal 4 编译器不能提优）
        if (!__atomic_exchange_n(&j->claimed, 1, __ATOMIC_ACQ_REL)) {
            GP_SCOPE(GP_XCWAIT); uint64_t k = ++g_xc_inline;
            if (k <= 8 || k % 100 == 0) GLOG("首遇现编：键 %016llx 首用时还在排队，在等待线程上就地编（第 %llu 支）", (unsigned long long)j->h, (unsigned long long)k);
            xjob_run(j);
        }
        { GP_SCOPE(GP_XCWAIT); dispatch_semaphore_wait(j->sem, DISPATCH_TIME_FOREVER); dispatch_semaphore_signal(j->sem); }   // 留给共用此作业的其他程序
        waited = 1;
    }
    double wait_ms = waited ? ms_of(mach_absolute_time() - now) : 0, first_use_ms = blocking ? ms_of(now - pd->t_create) : -1;
    if (waited) { g_xs[3]++; g_xs[4] += (uint64_t)wait_ms; if (wait_ms > g_xs[5]) g_xs[5] = (uint64_t)wait_ms; }
    if (blocking && first_use_ms < 100) g_xs[6]++;
    int ok = 1;
    for (int i = 0; i < pd->n && ok; i++) {
        xjob *j = pd->job[i];
        if (j && !j->added) {
            if (!j->ok) { set_err("首遇现编", "键 %016llx：%s", (unsigned long long)j->h, j->why); g_xs[2]++; ok = 0; break; }
            shd_add(&j->r, (__bridge id<MTLLibrary>)j->lib, (__bridge id<MTLLibrary>)j->lib_np); j->added = 1; g_stats[4]++; if (j->from_disk) g_xs[1]++;
            if (g_xc_log) fprintf(g_xc_log, "%016llx\t%s\t%.2f\t%.2f\t%.1f\t%.1f\n", (unsigned long long)j->h, j->from_disk ? "缓存" : "现编", ms_of(j->t_xc), ms_of(j->t_mtl), first_use_ms, wait_ms);
            // 首遇现编逐支进 host.log（判据「shader_miss 0」的逐条读数；10-21 暗黑2 冷局一帧 6540 ms 拆不开翻译 / Metal 编各占多少）
            // 非阻塞轮询（首用之前）就收尾的：没有首用时刻，明写「首用前后台编好、首用不等」，不打 -1（10-23 暗黑2 读数被读成「首用等了 0 ms 却卡」）
            if (first_use_ms < 0)
                GLOG("着色器首遇现编：键 %016llx（%s）SPIRV-Cross %.1f ms、Metal %.1f ms，首用前已在后台编好、首用不等", (unsigned long long)j->h, j->from_disk ? "持久缓存 MSL" : "现翻",
                     ms_of(j->t_xc), ms_of(j->t_mtl));
            else
                GLOG("着色器首遇现编：键 %016llx（%s）SPIRV-Cross %.1f ms、Metal %.1f ms，建程序到首用 %.1f ms、首用时等 %.1f ms", (unsigned long long)j->h, j->from_disk ? "持久缓存 MSL" : "现翻",
                     ms_of(j->t_xc), ms_of(j->t_mtl), first_use_ms, wait_ms);
        }
        shd_ent *e = shd_find(pd->h[i]);
        if (!e) { ok = 0; break; }
        if ((int)e->r.stage != pd->stage[i]) { set_err("阶段不符", "键 %016llx：GAL 说阶段 %d，SPIR-V 入口是阶段 %u", (unsigned long long)pd->h[i], pd->stage[i], e->r.stage); ok = 0; break; }
        prog_merge(p, e);
    }
    if (g_xc_log) fflush(g_xc_log);
    if (ok && p->is_compute && pd->n != 1) { set_err("阶段组合", "计算程序带了 %d 个阶段", pd->n); ok = 0; }
    prog_finish_hash(p);
    if (ok) check_descs(p, pd->descs, pd->ndesc);
    else { static int nr; if (nr++ < 8) GLOG("【红】首遇现编失败（程序 %u）：%s", pid, g_last_err); }
    p->status = ok ? 0 : 1; g_stats[ok ? 0 : 1]++;
    if (ok) gal_pso_pf_prog(p);
    free(pd->descs); free(pd); g_pend[pid] = NULL;
    return p->status;
}
NXGAL_API void nxgal_prog_xc_stats(uint64_t out[8]) { GAL_API_LOCK(); memcpy(out, g_xs, sizeof g_xs); }
// 单测钩子：占住（on = 1）/ 放开（0）全部后台现编槽，模拟首用时作业还排在后台作业后面
NXGAL_API void nxgal_test_xc_hold_slots(int on) {
    xc_init(); static int held;
    if (on && !held) { for (int i = 0; i < g_xc_n; i++) dispatch_semaphore_wait(g_xc_slots, DISPATCH_TIME_FOREVER); held = 1; }
    else if (!on && held) { for (int i = 0; i < g_xc_n; i++) dispatch_semaphore_signal(g_xc_slots); held = 0; }
}
// 测量用（tools/xc_bench.m）：与异步作业同一条路同步跑一支，返回各段耗时；不进内存缓存
int gal_xc_bench_one(const void *spv, uint32_t len, double *xc_ms, double *mtl_ms, int *from_disk, char *why) {
    prog_env();
    xjob j; memset(&j, 0, sizeof j); j.h = gal_spv_hash(spv, len); j.len = len; j.spv = malloc(len); memcpy(j.spv, spv, len); j.sem = dispatch_semaphore_create(0);
    xjob_run(&j);
    *xc_ms = ms_of(j.t_xc); *mtl_ms = ms_of(j.t_mtl); *from_disk = j.from_disk;
    if (!j.ok) { snprintf(why, 256, "%s", j.why); return 0; }
    CFRelease(j.lib); free(j.r.args); return 1;
}
// 真实语料队列基准：走产品 xjob_start 的去重、槽和工作队列，不从等待线程抢编。
// 每进程只提交每个键一次；作业仍归 g_jobs 持有，和产品首遇路径的生命周期一致。
__attribute__((visibility("hidden"))) void *gal_xc_bench_start(const void *spv, uint32_t len) {
    prog_env();
    return xjob_start(gal_spv_hash(spv, len), spv, len, 0, 0);
}
__attribute__((visibility("hidden"))) int gal_xc_bench_collect(void *job, double *xc_ms, double *mtl_ms, int *from_disk, uint32_t *qos, uint32_t *active, char *why) {
    xjob *j = job;
    dispatch_semaphore_wait(j->sem, DISPATCH_TIME_FOREVER); dispatch_semaphore_signal(j->sem);
    *xc_ms = ms_of(j->t_xc); *mtl_ms = ms_of(j->t_mtl); *from_disk = j->from_disk;
    *qos = j->run_qos; *active = j->run_active;
    if (!j->ok) snprintf(why, 256, "%s", j->why);
    return j->ok;
}
NXGAL_API uint32_t nxgal_prog_create(const nxgal_shader *shaders, int32_t n, const nxgal_res_desc *descs, int32_t ndesc, int32_t frag_output_map) { GAL_API_LOCK();
    @autoreleasepool {
        uint32_t id = prog_alloc(); gal_prog *p = g_progp[id];
        p->frag_output_map = frag_output_map;
        int ok = n > 0 && n <= 6;
        prog_env();
        // 曲面程序（带 TCS / TES）：顶点着色器用「曲面前顶点计算核」变体，键 = SPIR-V 键 ^ GAL_VT_SALT（gal_tess.m）
        int tess = 0; for (int i = 0; ok && i < n; i++) tess |= shaders[i].stage == 2 || shaders[i].stage == 3;
        // 片元帧缓冲读取证明（gal_fbr.m）：只看「顶点 + 片元」两段程序，证得出才留片元 SPIR-V 拷贝
        if (ok && n == 2 && !tess) {
            int vi = shaders[0].stage == 1 ? 0 : 1, fi = 1 - vi;
            if (shaders[vi].stage == 1 && shaders[fi].stage == 5 && !(shaders[vi].len & 3) && !(shaders[fi].len & 3))
                p->fbr = gal_fbr_prove((const uint32_t *)shaders[vi].code, shaders[vi].len / 4, (const uint32_t *)shaders[fi].code, shaders[fi].len / 4);
        }
        // 先看能否立即建成（内存缓存 / 离线库 / 持久缓存之外不现编）；异步模式下缺的阶段起作业，程序挂起到首用
        ppend *pd = NULL;
        if (ok && g_async && g_xc_enabled) {
            for (int i = 0; i < n; i++) {
                int vt = tess && shaders[i].stage == 1;
                uint64_t h = gal_spv_hash(shaders[i].code, shaders[i].len);
                if (g_spv_dump) spv_dump(h, shaders[i].code, shaders[i].len, vt);
                if (vt) h ^= GAL_VT_SALT;
                xjob *j = NULL;
                if (!shd_lookup_quiet(h)) j = xjob_start(h, shaders[i].code, shaders[i].len, vt, 0);
                if (j && !pd) pd = calloc(1, sizeof *pd);
                if (!pd) continue;
                pd->h[i] = h; pd->stage[i] = shaders[i].stage; pd->job[i] = j;
            }
            if (pd) {
                pd->n = n; pd->t_create = mach_absolute_time();
                for (int i = 0; i < n; i++) if (!pd->h[i]) { pd->h[i] = gal_spv_hash(shaders[i].code, shaders[i].len) ^ (tess && shaders[i].stage == 1 ? GAL_VT_SALT : 0); pd->stage[i] = shaders[i].stage; }
                if (ndesc > 0) { pd->descs = malloc(ndesc * sizeof *descs); memcpy(pd->descs, descs, ndesc * sizeof *descs); pd->ndesc = ndesc; }
                if (id >= g_cappend) { uint32_t nc = g_capprog > id ? g_capprog : id + 256; g_pend = realloc(g_pend, nc * sizeof *g_pend); memset(g_pend + g_cappend, 0, (nc - g_cappend) * sizeof *g_pend); g_cappend = nc; }
                g_pend[id] = pd; p->status = 2; g_xs[7]++;
                return id;
            }
        }
        for (int i = 0; i < n && ok; i++) {
            int vt = tess && shaders[i].stage == 1;
            uint64_t h = gal_spv_hash(shaders[i].code, shaders[i].len);
            if (g_spv_dump && !g_async) spv_dump(h, shaders[i].code, shaders[i].len, vt);
            if (vt) h ^= GAL_VT_SALT;
            shd_ent *e = shd_get(h, shaders[i].code, shaders[i].len, NULL, vt);
            if (!e) { ok = 0; break; }
            if ((int)e->r.stage != shaders[i].stage) { set_err("阶段不符", "键 %016llx：GAL 说阶段 %d，SPIR-V 入口是阶段 %u", (unsigned long long)h, shaders[i].stage, e->r.stage); ok = 0; break; }
            prog_merge(p, e);
        }
        if (ok && p->is_compute && n != 1) { set_err("阶段组合", "计算程序带了 %d 个阶段", n); ok = 0; }
        prog_finish_hash(p);
        if (ok) check_descs(p, descs, ndesc);
        p->status = ok ? 0 : 1; g_stats[ok ? 0 : 1]++;
        if (ok) gal_pso_pf_prog(p);
        return id;   // 失败也给编号（status = Failure），Gpu 层按 CheckProgramLink 处理
    }
}
// 变体程序 = pg 的顶点阶段 + 变体片元（调用方持有，gal_fbr_free 释放）
static gal_prog *fbr_mkprog(const gal_prog *pg, shd_ent *ve, shd_ent *e) {
    if (!e || e->r.stage != 5) return NULL;
    gal_prog *p = calloc(1, sizeof *p);
    for (int i = 0; i < 6; i++) p->size_buf_index[i] = -1;
    prog_merge(p, ve); prog_merge(p, e);
    p->frag_output_map = pg->frag_output_map;
    prog_finish_hash(p); p->status = 0; p->live = 1;
    return p;
}
// 只凭键取一支着色器（没有 SPIR-V、不现翻）：内存缓存 → 离线库 → 持久缓存 MSL——load_binary 取函数的三条路（变体表命中时用）
static shd_ent *shd_get_key(uint64_t h) {
    shd_ent *e = shd_lookup_quiet(h); if (e) return e;
    shd_rec r; char *msl = NULL;
    if (!cache_read(h, &r, &msl)) return NULL;
    uint64_t tm0 = mach_absolute_time(); NSError *err = nil; id<MTLLibrary> np = nil, lib = msl_compile(msl, &np, &err);
    // 离线库没有、持久缓存里有 MSL：现编成 Metal 库（不经 SPIRV-Cross），逐支记耗时
    GLOG("着色器首遇现编（持久缓存 MSL，读帧缓冲变体表）：键 %016llx Metal %.1f ms", (unsigned long long)h, ms_of(mach_absolute_time() - tm0));
    free(msl);
    if (!lib) { set_err("Metal 编译", "键 %016llx 持久缓存 MSL 编译失败：%s", (unsigned long long)h, err.localizedDescription.UTF8String); free(r.args); return NULL; }
    g_stats[4]++; g_xs[1]++;
    return shd_add(&r, lib, np);
}
// 帧缓冲读取变体（gal_fbr.m 调）：改写过的片元 SPIR-V 带 GAL_XC_FBF 翻译，与 pg 的顶点阶段拼成独立程序（调用方持有，gal_fbr_free 释放）。
// 异步现编（缺省）：首次只起作业，没编完返回 NULL 且 *pending = 1，下次再调取结果；同步（NXGAL_ASYNC_XC=0）当场编。失败返回 NULL、*pending = 0
gal_prog *gal_prog_fbr_build(const gal_prog *pg, const uint32_t *fs, uint32_t nw, int *pending) {
    *pending = 0;
    shd_ent *ve = pg && !pg->is_tess && pg->fn[1] && pg->fn[5] ? shd_find(pg->stage_hash[1]) : NULL;
    if (!ve) return NULL;
    uint32_t len = nw * 4; uint64_t h = gal_spv_hash(fs, len);
    shd_ent *e = shd_find(h);
#if GAL_HAVE_XC
    if (!e && g_xc_enabled) {
        if (g_async) {
            xjob *j = xjob_start(h, (const uint8_t *)fs, len, 0, 1);
            if (!__atomic_load_n(&j->done, __ATOMIC_ACQUIRE)) { *pending = 1; return NULL; }
            if (!j->ok) { set_err("帧缓冲读取变体", "键 %016llx：%s", (unsigned long long)h, j->why); return NULL; }
            if (!j->added) { e = shd_add(&j->r, (__bridge id<MTLLibrary>)j->lib, (__bridge id<MTLLibrary>)j->lib_np); j->added = 1; g_stats[4]++; }
            else e = shd_find(h);
        } else {
            char why[256] = "", *msl = NULL; shd_rec r;
            if (!xc_shader((const uint8_t *)fs, len, XC_PLATFORM | GAL_XC_FBF, &msl, &r, why)) { set_err("帧缓冲读取变体", "键 %016llx 翻译失败：%s", (unsigned long long)h, why); return NULL; }
            NSError *err = nil; id<MTLLibrary> np = nil, lib = msl_compile(msl, &np, &err);
            if (lib) cache_write(&r, msl);
            free(msl);
            if (!lib) { set_err("帧缓冲读取变体", "键 %016llx MSL 编译失败：%s", (unsigned long long)h, err.localizedDescription.UTF8String); free(r.args); return NULL; }
            g_stats[4]++; e = shd_add(&r, lib, np);
        }
    }
#endif
    return fbr_mkprog(pg, ve, e);
}
// 变体表命中（gal_fbr.m 调）：变体片元只按键取（内存缓存 → 离线库 → 持久缓存 MSL），与 pg 的顶点阶段拼成独立程序；不现翻、不要 SPIR-V
gal_prog *gal_prog_fbr_load(const gal_prog *pg, uint64_t fs_key) {
    shd_ent *ve = pg && !pg->is_tess && pg->fn[1] && pg->fn[5] ? shd_find(pg->stage_hash[1]) : NULL;
    if (!ve) { set_err("帧缓冲读取变体", "程序 %016llx 没有可用的顶点阶段", pg ? (unsigned long long)pg->hash : 0ull); return NULL; }
    shd_ent *e = shd_get_key(fs_key);
    if (!e) { set_err("帧缓冲读取变体", "变体片元 %016llx 在内存缓存、离线库与持久缓存（%s）里都没有", (unsigned long long)fs_key, g_cache_dir ? g_cache_dir : "未设 NXGAL_SHADER_CACHE_DIR"); return NULL; }
    return fbr_mkprog(pg, ve, e);
}
// 首遇不阻塞（10-21 首局根治 A 层）：绘制 / 派发取程序用这个。作业没编完不等，返回空且 *pending = 1，调用方跳过这次绘制并计数（跳过次数 = 静态抽取覆盖面读数）；
//   作业编完后下一次绘制照常收尾换上。原先 gal_prog_get 首用时阻塞等（单支几百 ms 到秒级，首局卡帧来源之一）。
//   缺省阻塞（单测 / 录放逐像素要确定性：10-21 合批门禁宽屏出图 2/5 帧过，关跳过 5/5），产品局由 graphics/loop/RenderLoop.cs 设 NXGAL_FIRST_SKIP=1 打开
static int g_first_skip = -1;
// 首用时还没被认领的作业：认领下来丢到较高优先级的全局队列马上编（现翻作业队列 UTILITY 档、只有 2–4 个槽，首遇的那支排在后台作业后面会迟迟编不出来）
static void prog_boost(uint32_t pid) {
    // NXGAL_FIRST_BOOST=0 不加速（单测要确定地看到「作业没编完」；不改导出接口，免得翻译键变、九款白重出）
    static int on = -1; if (on < 0) { const char *v = getenv("NXGAL_FIRST_BOOST"); on = !(v && *v == '0'); }
    ppend *pd = pid < g_cappend ? g_pend[pid] : NULL; if (!pd || !on) return;
    for (int i = 0; i < pd->n; i++) {
        xjob *j = pd->job[i];
        if (!j || __atomic_load_n(&j->done, __ATOMIC_ACQUIRE) || __atomic_exchange_n(&j->claimed, 1, __ATOMIC_ACQ_REL)) continue;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ xjob_run(j); });
    }
}
uint64_t g_first_skips;   // 首遇编译中跳过的绘制 / 派发次数（单测 / 诊断读）
void gal_first_skip_note(uint32_t prog, const char *what) {
    uint64_t n = ++g_first_skips;
    if (!(n & (n - 1))) GLOG("【首遇】程序 %u 编译中，跳过本次%s（第 %llu 次）", prog, what, (unsigned long long)n);
}
gal_prog *gal_prog_get_draw(uint32_t id, int *pending) {
    *pending = 0;
    if (!(id && id < g_nprog && g_progp[id] && g_progp[id]->live)) return NULL;
    if (id < g_cappend && g_pend[id]) {
        if (g_first_skip < 0) { const char *v = getenv("NXGAL_FIRST_SKIP"); g_first_skip = v && *v == '1'; }
        @autoreleasepool { if (prog_finalize(id, !g_first_skip) == 2) { prog_boost(id); *pending = 1; return NULL; } }
    }
    return g_progp[id];
}
NXGAL_API int32_t nxgal_prog_status(uint32_t prog, int32_t blocking) { GAL_API_LOCK();
    if (prog && prog < g_nprog && prog < g_cappend && g_pend[prog]) { @autoreleasepool { return prog_finalize(prog, blocking); } }
    gal_prog *p = gal_prog_get(prog); return p ? p->status : 1;
}
NXGAL_API void nxgal_prog_release(uint32_t prog) { GAL_API_LOCK();
    g_obj_gen++;   // 程序结构体可能被复用：按集复用的参数缓冲作废
    if (prog && prog < g_cappend && g_pend[prog]) { free(g_pend[prog]->descs); free(g_pend[prog]); g_pend[prog] = NULL; }   // 没用过就释放：作业照常编完进缓存
    gal_prog *p = prog && prog < g_nprog ? g_progp[prog] : NULL; if (!p || !p->live) return;
    if (!g_prog_own[prog]) { GRED_ONCE("释放内置辅助程序 %u：忽略（由登记方持有）", prog); return; }
    for (int i = 0; i < 6; i++) p->fn[i] = nil;   // 库对象由着色器缓存持有；管线（第 5 块）各自持有函数引用
    gal_fbr_free(p->fbr); p->fbr = NULL;
    free(p->args); free(p); g_progp[prog] = NULL;
    if (g_nprog_free == g_capprog_free) { g_capprog_free = g_capprog_free ? g_capprog_free * 2 : 256; g_prog_free = realloc(g_prog_free, g_capprog_free * sizeof *g_prog_free); }
    g_prog_free[g_nprog_free++] = prog;
}

// ---------- 程序二进制 ----------
// 格式（小端）：u32 魔数 "GALP"、u32 BIN_VERSION、u32 GAL_XC_VERSION、u32 阶段数 m、i32 frag_output_map，
//   然后 m 个「u32 记录长 + 着色器记录」（记录 = 键、阶段、各集参数缓冲字节数、输入输出位与类型、线程组、全部参数条目，与离线索引同格式）；
//   版本 2：其后可有读帧缓冲证明尾段（直到二进制末尾，gal_fbr.m gal_fbr_ser；没有 = 没证明）。版本 1 照读，记录后的字节不看。
// 自足：load_binary 只凭它重建 gal_prog（参数布局全在记录里），函数按键从内存缓存或离线库取，不需要 SPIR-V、不调 SPIRV-Cross。
NXGAL_API int32_t nxgal_prog_binary(uint32_t prog, void *out, int32_t cap) { GAL_API_LOCK();
    gal_prog *p = gal_prog_get(prog); if (!p || p->status) return 0;
    uint32_t total = 20, m = 0;
    for (int st = 0; st < 6; st++) if (p->fn[st]) { shd_ent *e = shd_find(p->stage_hash[st]); if (!e) return 0; total += 4 + rec_size(&e->r); m++; }
    // 读帧缓冲证明尾段（gal_fbr.m）：证明 + 已建成的变体（映射 → 变体片元键）。下次开机 load_binary 恢复证明，变体按表从缓存取、不现翻
    uint32_t tl = gal_fbr_ser(p->fbr, NULL); total += tl;
    if (!out) return (int32_t)total;
    if (cap < (int32_t)total) return 0;
    uint8_t *o = out; put32(&o, BIN_MAGIC); put32(&o, BIN_VERSION); put32(&o, GAL_XC_VERSION); put32(&o, m); put32(&o, (uint32_t)p->frag_output_map);
    for (int st = 0; st < 6; st++) if (p->fn[st]) { shd_ent *e = shd_find(p->stage_hash[st]); uint32_t L = rec_size(&e->r); put32(&o, L); rec_write(&e->r, o); o += L; }
    if (tl) gal_fbr_ser(p->fbr, o);
    return (int32_t)total;
}
// load_binary 的第三条路：键不在离线库（包外、运行时首遇现编过的着色器）→ 按键读持久缓存里的 MSL 编 Metal 库（不经 SPIRV-Cross）。
// 没有这条路时：上一局首遇现编的程序被 Ryujinx 存进主机缓存（只有键），下次开机 load_binary 必失败，Ryujinx 回退现翻并把整份主机缓存重写
// （ParallelDiskCacheLoader：_needsHostRegen → Rebuilding N shaders；10-20 jhz 测试机1 塞尔达 / 巫师3 / 暗黑3 / 八方2 / 动森每次开机都整份重写）。
// 布局以二进制里的记录为准（同离线库路径），r 的参数表归新条目所有
static shd_ent *cache_load(shd_rec *r) {
    shd_rec rc; char *msl = NULL;
    if (!cache_read(r->hash, &rc, &msl)) return NULL;
    if (rc.nargs != r->nargs || memcmp(rc.args, r->args, 16 * r->nargs) || memcmp(rc.set_size, r->set_size, sizeof r->set_size))
        set_err("二进制与持久缓存不符", "键 %016llx 的布局与持久缓存记录不一致，以二进制为准", (unsigned long long)r->hash);
    free(rc.args);
    uint64_t tm0 = mach_absolute_time(); NSError *err = nil; id<MTLLibrary> np = nil, lib = msl_compile(msl, &np, &err);
    // 载程序二进制时离线库没有、持久缓存里有 MSL：现编成 Metal 库，逐支记耗时
    GLOG("着色器首遇现编（持久缓存 MSL，载二进制时）：键 %016llx Metal %.1f ms", (unsigned long long)r->hash, ms_of(mach_absolute_time() - tm0));
    free(msl);
    if (!lib) { set_err("Metal 编译", "键 %016llx 持久缓存 MSL 编译失败：%s", (unsigned long long)r->hash, err.localizedDescription.UTF8String); return NULL; }
    g_stats[4]++; g_xs[1]++;
    return shd_add(r, lib, np);
}
NXGAL_API uint32_t nxgal_prog_load_binary(const void *data, int32_t len, int32_t has_fragment) { GAL_API_LOCK();
    @autoreleasepool {
        prog_env();   // 先按环境开离线库：Ryujinx 磁盘缓存在任何 CreateProgram 之前就载主机二进制，原先库在首个 create 才开，之前载的程序全判「离线库未命中」→ 退回现翻，现翻关着就跳过绘制（10-19 动森帐篷全黑）
        uint32_t id = prog_alloc(); gal_prog *p = g_progp[id];
        const uint8_t *q = data; int ok = 0;
        uint32_t bv = 0;
        if (len >= 20 && get32(&q) == BIN_MAGIC && ((bv = get32(&q)) == 1u || bv == BIN_VERSION)) {
            uint32_t xv = get32(&q), m = get32(&q); p->frag_output_map = (int32_t)get32(&q);
            if (xv != GAL_XC_VERSION) set_err("二进制口径旧", "程序二进制翻译口径 %u ≠ 当前 %u", xv, GAL_XC_VERSION);
            else {
                ok = m > 0 && m <= 6;
                for (uint32_t i = 0; i < m && ok; i++) {
                    if (q + 4 > (const uint8_t *)data + len) { ok = 0; break; }
                    uint32_t L = get32(&q); shd_rec r;
                    if (q + L > (const uint8_t *)data + len || rec_read(q, L, &r) != L) { set_err("二进制坏", "程序二进制记录损坏"); ok = 0; break; }
                    q += L;
                    shd_ent *e = shd_find(r.hash);
                    if (!e) {
                        shd_rec r2;   // 离线库：函数从库里取，布局以二进制里的记录为准（两者同源；不同则报红）
                        if (off_lookup(r.hash, &r2)) {
                            if (rec_size(&r2) != L || r2.nargs != r.nargs || memcmp(r2.args, r.args, 16 * r.nargs) || memcmp(r2.set_size, r.set_size, sizeof r.set_size))
                                set_err("二进制与离线库不符", "键 %016llx 的布局与离线库记录不一致，以二进制为准", (unsigned long long)r.hash);
                            free(r2.args);
                            __auto_type L = off_lib(r.hash);   // 本函数里 id 是局部变量名，不能写 id<MTLLibrary>
                            NSArray<NSString *> *fns = L.functionNames;
                            if ([fns containsObject:fn_name(r.hash)]) { g_stats[2]++; e = shd_add(&r, L, (r.flags & 2) ? L : nil); }
                        }
                        if (!e) e = cache_load(&r);
                    } else free(r.args);
                    if (!e) { if (g_off_idx) g_stats[3]++; set_err("离线库未命中", "程序二进制的键 %016llx 在内存缓存、离线库与持久缓存（%s）里都没有函数", (unsigned long long)r.hash, g_cache_dir ? g_cache_dir : "未设 NXGAL_SHADER_CACHE_DIR"); if (!shd_find(r.hash)) free(r.args); ok = 0; break; }
                    prog_merge(p, e);
                }
                // 版本 2 的尾段：读帧缓冲证明（没有 SPIR-V；变体只按表取）。尾段坏 = 二进制坏（格式不符不静默丢证明）
                const uint8_t *end = (const uint8_t *)data + len;
                if (ok && bv == 2u && q < end) {
                    const char *why = NULL; p->fbr = gal_fbr_deser(q, (uint32_t)(end - q), &why);
                    if (!p->fbr) { set_err("二进制坏", "程序二进制读帧缓冲尾段坏（%u 字节）：%s", (unsigned)(end - q), why ? why : "?"); ok = 0; }
                }
            }
        } else set_err("二进制坏", "程序二进制魔数 / 版本不符（长 %d）", len);
        if (ok && (has_fragment != 0) != (p->fn[5] != nil)) GRED_ONCE("load_binary：has_fragment = %d 与二进制里的阶段不符（以二进制为准）", has_fragment);
        prog_finish_hash(p);
        p->status = ok ? 0 : 1; g_stats[ok ? 0 : 1]++;
        // 管线预取（gal_state.m）：开机从主机缓存恢复的程序按用表后台取它的管线
        if (ok) gal_pso_pf_prog(p);
        return id;
    }
}

// ---------- 离线库 / 工具 / 测试入口 ----------
// 开离线库目录：<dir>/gal.idx + <dir>/gal.shards（每行「首键 16 位十六进制<TAB>文件名」，按键升序）+ 各片 metallib。
// 每片按文件 URL 开（Metal 自己映射，≤64 MB 一块）：不再要整库一块连续地址，也不再整库复制一份（原先映射 + dispatch_data 复制 = 两块整库大小）
NXGAL_API int32_t nxgal_prog_lib_open(const char *dir) { GAL_API_LOCK();
    // 计数开（诊断）不开离线库：离线库按出包口径不带计数（gal_xc 一律关），开了只计现翻的那部分、判据会绿着漏；计数开 = 全部现翻、全覆盖
    if (gal_spvx_counting()) { static int once; if (!once++) GLOG("计数开（NXGAL_BOUNDS_COUNT=1）：不开离线库 %s，全部现翻（离线库不带计数）", dir ? dir : "-"); return 0; }
    @autoreleasepool {
        if (!g_gdev) { set_err("离线库", "nxgal_init 之前不能开离线库"); return -1; }
        uint64_t t0 = mach_absolute_time();
        NSString *D = @(dir); NSError *e = nil;
        NSData *d = [NSData dataWithContentsOfFile:[D stringByAppendingPathComponent:@"gal.idx"] options:NSDataReadingMappedIfSafe error:&e];
        if (!d) { set_err("离线库", "读不了 %s/gal.idx：%s", dir, e.localizedDescription.UTF8String); return -1; }
        if (d.length < 24) { set_err("离线库", "离线索引太短（%llu 字节）", (unsigned long long)d.length); return -1; }
        const uint8_t *q = d.bytes;
        uint32_t magic = get32(&q), ver = get32(&q), xv = get32(&q), plat = get32(&q), n = get32(&q); (void)plat;
        if (magic != IDX_MAGIC || ver != IDX_VERSION || xv != GAL_XC_VERSION || 24 + (uint64_t)n * 16 > d.length) { set_err("离线库", "离线索引魔数 / 版本 / 口径不符（口径 %u，当前 %u）", xv, GAL_XC_VERSION); return -1; }
        NSString *man = [NSString stringWithContentsOfFile:[D stringByAppendingPathComponent:@"gal.shards"] encoding:NSUTF8StringEncoding error:&e];
        if (!man) { set_err("离线库", "读不了 %s/gal.shards：%s", dir, e.localizedDescription.UTF8String); return -1; }
        id<MTLLibrary> libs[OFF_MAXLIB]; uint64_t first[OFF_MAXLIB]; int nl = 0; uint64_t bytes = 0;
        for (NSString *ln in [man componentsSeparatedByString:@"\n"]) {
            if (!ln.length) continue;
            NSArray<NSString *> *f = [ln componentsSeparatedByString:@"\t"];
            if (f.count != 2 || f[0].length != 16 || nl == OFF_MAXLIB) { set_err("离线库", "gal.shards 第 %d 行坏或超 %d 片：%s", nl + 1, OFF_MAXLIB, ln.UTF8String); return -1; }
            first[nl] = strtoull(f[0].UTF8String, NULL, 16);
            if (nl && first[nl] <= first[nl - 1]) { set_err("离线库", "gal.shards 首键不升序（第 %d 行）", nl + 1); return -1; }
            NSString *path = [D stringByAppendingPathComponent:f[1]];
            libs[nl] = [g_gdev newLibraryWithURL:[NSURL fileURLWithPath:path] error:&e];
            if (!libs[nl]) {
                uint64_t ht = 0, hl = 0; void (*holes)(uint64_t *, uint64_t *) = (void (*)(uint64_t *, uint64_t *))dlsym(RTLD_DEFAULT, "s2a_low_holes");
                if (holes) holes(&ht, &hl);   // 原生层（runtime/src/vawin.c）：4 GB 到窗口底的空洞；运行时查找（单测 / 回放不链原生层时没有）
                set_err("离线库", "第 %d 片 %s 载入失败（%llu 字节）：%s；低区空洞合计 %llu MB、最大一块 %llu MB（0 = 本进程无原生层读数）", nl, path.UTF8String,
                    (unsigned long long)[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileSize, e.localizedDescription.UTF8String,
                    (unsigned long long)(ht >> 20), (unsigned long long)(hl >> 20)); return -1; }
            bytes += [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileSize; nl++;
        }
        free(g_off_idx); g_off_idx = malloc(d.length); memcpy(g_off_idx, d.bytes, d.length); g_off_len = d.length; g_off_n = n;
        for (int i = 0; i < OFF_MAXLIB; i++) g_off_libs[i] = i < nl ? libs[i] : nil;
        memcpy(g_off_first, first, sizeof(uint64_t) * (size_t)nl); g_off_nlib = nl;
        static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
        GLOG("离线着色器库：%u 支，%d 片共 %.1f MB，开库 %.1f ms", n, nl, bytes / 1048576.0, (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6);
        return 0;
    }
}
// 环境变量（首次建程序时读一次）：
//   NXGAL_SHLIB_DIR=<目录>：自动开该目录的离线库（gal.idx + gal.shards + 各片，tools/gal_offline.py 的输出）
//   SW_GAL_SPV_DUMP=<目录>：每支着色器按键写 <目录>/<键 16 位十六进制>.spv（已存在不重写）；录种子局收集离线库输入用，gal_offline.py 直接吃这个目录
static int g_env_done;
static void prog_env(void) {
    if (g_env_done++) return;
    const char *d = getenv("NXGAL_SHLIB_DIR");
    // 「~/」开头按 $HOME 展开：iOS 上 HOME = 本 App 数据容器，真机回放可把离线库推到 Documents 再用 NXGAL_SHLIB_DIR=~/Documents/<目录> 起局
    // （起局环境变量优先于包里 game.env；容器路径每次安装都变，起局时写不出绝对路径）
    char hd[1024]; if (d && d[0] == '~' && d[1] == '/' && getenv("HOME")) { snprintf(hd, sizeof hd, "%s%s", getenv("HOME"), d + 1); d = hd; }
    if (d && *d) {
        if (nxgal_prog_lib_open(d)) GLOG("【红】NXGAL_SHLIB_DIR=%s 开离线库失败：%s", d, g_last_err); }
    g_spv_dump = getenv("SW_GAL_SPV_DUMP"); if (g_spv_dump && !*g_spv_dump) g_spv_dump = NULL;
    const char *a = getenv("NXGAL_ASYNC_XC"); g_async = a ? atoi(a) != 0 : 1;
    g_cache_dir = getenv("NXGAL_SHADER_CACHE_DIR"); if (g_cache_dir && !*g_cache_dir) g_cache_dir = NULL;
    if (g_cache_dir) mkdir(g_cache_dir, 0755);
    // 计数开的翻译带计数收尾（gal_spvx.m 翻译期开关）：持久缓存另放 cnt/ 子目录，与计数关（出包同口径）的译文互不覆盖
    if (g_cache_dir && gal_spvx_counting()) { static char cd[1100]; snprintf(cd, sizeof cd, "%s/cnt", g_cache_dir); mkdir(cd, 0755); g_cache_dir = cd; }
    const char *lg = getenv("NXGAL_XC_LOG"); if (lg && *lg) { g_xc_log = fopen(lg, "a"); if (g_xc_log) fprintf(g_xc_log, "# 键\t来源\tSPIRV-Cross_ms\tMetal_ms\t建程序到首用_ms\t等待_ms\n"); }
    if (g_spv_dump) { mkdir(g_spv_dump, 0755); GLOG("着色器落盘：%s", g_spv_dump); }
}
static void spv_dump(uint64_t h, const void *code, uint32_t len, int vt) {
    char path[1200]; snprintf(path, sizeof path, "%s/%016llx%s.spv", g_spv_dump, (unsigned long long)h, vt ? ".vt" : "");
    if (access(path, F_OK) == 0) return;
    char tmp[1300]; snprintf(tmp, sizeof tmp, "%s.%d.tmp", path, getpid());   // 先写临时名再改名：并行局不会读到半个文件
    FILE *f = fopen(tmp, "wb"); if (!f) { GRED_ONCE("着色器落盘写不了 %s", tmp); return; }
    fwrite(code, 1, len, f); fclose(f); rename(tmp, path);
}
NXGAL_API void nxgal_prog_set_xc(int32_t enable) { GAL_API_LOCK(); g_xc_enabled = GAL_HAVE_XC && enable; }
NXGAL_API void nxgal_prog_cache_clear(void) { GAL_API_LOCK();
    for (int i = 0; i < g_nshd; i++) { g_shd[i].lib = nil; free(g_shd[i].r.args); }
    g_nshd = 0; [g_shd_map removeAllObjects];
}
NXGAL_API void nxgal_prog_set_variant(uint64_t v) { GAL_API_LOCK(); g_prog_variant = v; nxgal_prog_cache_clear(); }
NXGAL_API void nxgal_prog_stats(uint32_t out[6]) { GAL_API_LOCK(); memcpy(out, g_stats, sizeof g_stats); }
NXGAL_API const char *nxgal_prog_last_error(void) { GAL_API_LOCK(); return g_last_err; }

// 离线工具用：一支 SPIR-V → MSL 源码 + 着色器记录（不需要 Metal 设备）。platform：0 iOS 1 macOS。
// 返回 1 成功；*msl / *rec 为 malloc 的内存（调用方 free），*rec_len = 记录字节数，*hash = 键
NXGAL_API int32_t nxgal_prog_xc(const void *spv, uint32_t len, int32_t platform, char **msl, void **rec, uint32_t *rec_len, uint64_t *hash) { GAL_API_LOCK();
#if GAL_HAVE_XC
    shd_rec r; char why[256] = "";
    if (!xc_shader(spv, len, platform, msl, &r, why)) { snprintf(g_last_err, sizeof g_last_err, "%s", why); return 0; }
    *rec_len = rec_size(&r); *rec = malloc(*rec_len); rec_write(&r, *rec); *hash = r.hash; free(r.args);
    return 1;
#else
    snprintf(g_last_err, sizeof g_last_err, "iOS 构建没有 SPIRV-Cross"); return 0;
#endif
}
// 离线工具并行用（gal_xc 多线程翻译，10-20：串行时动森 1.59 万支 77 s）：同 nxgal_prog_xc，但不取 API 锁、错误写进调用方的 err（≥ 256 字节）。
// xc_shader 本身线程安全（运行时异步现编就在多个工作线程上并行调它），锁只护 g_last_err
NXGAL_API int32_t nxgal_prog_xc_mt(const void *spv, uint32_t len, int32_t platform, char **msl, void **rec, uint32_t *rec_len, uint64_t *hash, char *err) {
#if GAL_HAVE_XC
    shd_rec r; err[0] = 0;
    if (!xc_shader(spv, len, platform, msl, &r, err)) return 0;
    *rec_len = rec_size(&r); *rec = malloc(*rec_len); rec_write(&r, *rec); *hash = r.hash; free(r.args);
    return 1;
#else
    snprintf(err, 256, "iOS 构建没有 SPIRV-Cross"); return 0;
#endif
}
// 直连兜底现编（graphics/tools/direct/dsh，S2A.Dsh 的设备后端）：一支 SPIR-V 照直连离线链 dmsh_build.py 的 XC 出 MSL——
//   spirv-cross --msl --msl-version 30100 --msl-argument-buffers --msl-texture-buffer-native --msl-pad-fragment-output，其余全取 SPIRV-Cross 缺省（平台 macOS：离线链的 iOS 库也是这份 MSL 编的）；
//   glsl = 1 出 GLSL 450（spirv-cross <spv> --version 450，gs_slice 只拿它认几何着色器形状）。不加固、不改名、不改绑定，与本文件 xc_shader1 的渲染器口径无关。
// 线程安全（每次自建上下文，不碰全局）。返回 0 成功、*out 为 malloc 的文本（调用方 free，或 nxgal_dmsh_xc_free）；非 0 失败、err 写原因（截到 errlen）
NXGAL_API int32_t nxgal_dmsh_xc(const void *spv, uint64_t len, int32_t glsl, char **out, char *err, uint64_t errlen) {
    *out = NULL; if (errlen) err[0] = 0;
#if GAL_HAVE_XC
    if (len < 20 || (len & 3) || *(const uint32_t *)spv != 0x07230203) { snprintf(err, errlen, "不是 SPIR-V（长 %llu）", (unsigned long long)len); return 1; }
    spvc_context ctx = NULL; char cberr[512] = ""; int rc = 1;
    if (spvc_context_create(&ctx) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 上下文建不出"); return 1; }
    spvc_context_set_error_callback(ctx, xc_err_cb, cberr);
    spvc_parsed_ir ir = NULL; spvc_compiler c = NULL; spvc_compiler_options o = NULL; const char *src = NULL;
    if (spvc_context_parse_spirv(ctx, (const SpvId *)spv, (size_t)(len / 4), &ir) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 解析失败：%s", cberr); goto out; }
    if (spvc_context_create_compiler(ctx, glsl ? SPVC_BACKEND_GLSL : SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &c) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 建编译器失败：%s", cberr); goto out; }
    spvc_compiler_create_compiler_options(c, &o);
    if (glsl) {
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_GLSL_VERSION, 450);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_GLSL_ES, SPVC_FALSE);
    } else {
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_MACOS);
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_VERSION, 30100);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, SPVC_TRUE);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_TEXTURE_BUFFER_NATIVE, SPVC_TRUE);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_PAD_FRAGMENT_OUTPUT_COMPONENTS, SPVC_TRUE);
    }
    spvc_compiler_install_compiler_options(c, o);
    if (spvc_compiler_compile(c, &src) != SPVC_SUCCESS || !src) { snprintf(err, errlen, "SPIRV-Cross 编译失败：%s", cberr); goto out; }
    *out = strdup(src); rc = *out ? 0 : 1;
    if (rc) snprintf(err, errlen, "内存不足");
out:
    spvc_context_destroy(ctx);
    return rc;
#else
    (void)spv; (void)len; (void)glsl; snprintf(err, errlen, "本构建没有 SPIRV-Cross（NXGAL_NO_XC）"); return 1;
#endif
}
NXGAL_API void nxgal_dmsh_xc_free(char *p) { free(p); }
int gal_prog_drain_session(void) {
    // Caller holds the GAL API lock. Pending programs only borrow jobs from
    // process-owned g_jobs; released programs leave no session owner to drain.
    // Observe the jobs themselves, including those claimed by prog_boost on a
    // different queue. Do not finalize here: that would merge old programs and
    // start pipeline prefetch. One deadline covers this entire drain.
    dispatch_time_t until = dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC);
    for (uint32_t id = 1; id < g_nprog && id < g_cappend; id++) {
        ppend *pd = g_pend[id]; if (!pd) continue;
        for (int i = 0; i < pd->n; i++) {
            xjob *j = pd->job[i];
            if (!j || __atomic_load_n(&j->done, __ATOMIC_ACQUIRE)) continue;
            if (dispatch_semaphore_wait(j->sem, until)) return -ETIMEDOUT;
            dispatch_semaphore_signal(j->sem); // preserve completion for shared jobs
        }
    }
    return 0;
}
int gal_prog_reset_session(void) {
    for (uint32_t i = 1; i < g_nprog; i++) if (g_prog_own[i]) nxgal_prog_release(i);
    return 0;
}
GAL_MTL4_ZONE_END

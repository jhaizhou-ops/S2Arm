// GAL 曲面细分的翻译段（纯 C：只用 SPIRV-Cross 的 C 接口，不碰 Metal；Mac / iOS 经 gal_tessxc.m 编，Windows 出包机经 nxgal_win.py 编进 nxgal.dll，11-05）（10-25 从 gal_prog.m 拆出，直连曲面细分 T2）——SPIRV-Cross 曲面选项、翻完的 MSL 后处理、直连离线链 / 设备兜底用的导出 nxgal_dmsh_xc_tess。
// 单独成文件是为了直连链版本（translator/dmsh_chain.py）只按这份与 gal_tess.m 算：通用模式渲染器其余翻译代码（gal_prog.m）怎么改都不换直连链
#include "gal_abi.h"
#include "gal_tess.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#if !defined(NXGAL_NO_XC)
#include "gal_tessxc.h"

// ================= MSL 文本改写（翻译时，本文件 tess_post 调）=================
typedef struct { char *s; size_t n, cap; } sb;
static void sb_put(sb *b, const char *p, size_t n) {
    if (b->n + n + 1 > b->cap) { b->cap = (b->n + n + 1) * 2; b->s = realloc(b->s, b->cap); }
    memcpy(b->s + b->n, p, n); b->n += n; b->s[b->n] = 0;
}
static void sb_str(sb *b, const char *p) { sb_put(b, p, strlen(p)); }
static void sb_fmt(sb *b, const char *f, ...) __attribute__((format(printf, 2, 3)));
static void sb_fmt(sb *b, const char *f, ...) { char t[1024]; va_list ap; va_start(ap, f); int n = vsnprintf(t, sizeof t, f, ap); va_end(ap); if (n > 0) sb_put(b, t, (size_t)n < sizeof t ? (size_t)n : sizeof t - 1); }
// 全部替换 a → b，返回新串（调用方 free），*n = 替换次数
static char *repl_all(const char *s, const char *a, const char *b, int *n) {
    sb o = {0}; size_t la = strlen(a); *n = 0; const char *p = s, *q;
    while ((q = strstr(p, a))) { sb_put(&o, p, (size_t)(q - p)); sb_str(&o, b); p = q + la; (*n)++; }
    sb_str(&o, p); return o.s;
}
static int repl_inplace(char **s, const char *a, const char *b) { int n; char *r = repl_all(*s, a, b, &n); free(*s); *s = r; return n; }

// ---- 规范布局：结构体 struct <名>{…}; 按成员 Location 重排补位 ----
// 成员 → 槽：通用位置 L（0–31）→ 字节 16·L；gl_Position → 512；gl_PointSize → 528；gl_ClipDistance → 544（至多 8 个 float）。每控制点 576 字节，每片属性 512 字节
static int mbr_size(const char *ty, uint32_t *sz) {
    static const struct { const char *t; uint32_t s; } k[] = { {"float4", 16}, {"uint4", 16}, {"int4", 16}, {"float3", 16}, {"uint3", 16}, {"int3", 16},
        {"float2", 8}, {"uint2", 8}, {"int2", 8}, {"float", 4}, {"uint", 4}, {"int", 4} };
    for (unsigned i = 0; i < sizeof k / sizeof *k; i++) if (!strcmp(ty, k[i].t)) { *sz = k[i].s; return 1; }
    return 0;
}
int gal_tess_canon(char **msl, const char *sname, int per_vertex, const gal_tess_loc *locs, int nlocs, char *why) {
    char head[160]; snprintf(head, sizeof head, "struct %s\n{\n", sname);
    char *sp = strstr(*msl, head); if (!sp) return 1;   // 本阶段没有这个结构体（如没有每片属性）
    // 结尾从头的最后一个换行起找：空结构体（顶点阶段不写通用输出时 SPIRV-Cross 出 struct main0_out\n{\n};）的结尾就在那里；
    // 从 bp 起找会落到下一个结构体的结尾、把「};」当成员（11-02 普查：泡姆泡姆 / 符文工房5 / 奥日2 / 泡泡龙4 / 马力欧派对 共 80 支编不过）
    char *bp = sp + strlen(head), *ep = strstr(bp - 1, "\n};\n"); if (!ep) { snprintf(why, 256, "结构体 %s 没有结尾", sname); return 0; }
    typedef struct { char line[200]; uint32_t sz; int used; } slot;
    int nslot = per_vertex ? 35 : 32; slot sl[35]; memset(sl, 0, sizeof sl);
    char *body = strndup(bp, ep > bp ? (size_t)(ep - bp) : 0), *sv = NULL;
    for (char *ln = strtok_r(body, "\n", &sv); ln; ln = strtok_r(NULL, "\n", &sv)) {
        char ty[64], nm[96]; int cnt = 1;
        if (sscanf(ln, " %63s %95[^;[ ]", ty, nm) != 2) { snprintf(why, 256, "%s 成员认不出：%s", sname, ln); free(body); return 0; }
        char *br = strchr(ln, '['); if (br && strchr(ln, ';') > br) { cnt = atoi(br + 1); if (cnt <= 0) { snprintf(why, 256, "%s 数组成员认不出：%s", sname, ln); free(body); return 0; } }
        if (strstr(ln, "[[")) { snprintf(why, 256, "%s 成员带属性：%s", sname, ln); free(body); return 0; }
        uint32_t es; if (!mbr_size(ty, &es)) { snprintf(why, 256, "%s 成员类型 %s 不在规范布局里（%s）", sname, ty, nm); free(body); return 0; }
        int s = -1; uint32_t cap = 16;
        if (per_vertex && !strcmp(nm, "gl_Position")) s = 32;
        else if (per_vertex && !strcmp(nm, "gl_PointSize")) s = 33;
        else if (per_vertex && !strcmp(nm, "gl_ClipDistance")) { s = 34; cap = 32; }
        else for (int i = 0; i < nlocs && s < 0; i++) if (!strcmp(locs[i].name, nm) && locs[i].patch == !per_vertex) s = (int)locs[i].loc;
        if (s < 0 || s >= nslot || (s < 32 && s >= GAL_TESS_LOC_POS)) { snprintf(why, 256, "%s 成员 %s 找不到位置号（规范布局只认通用位置 0–31 与位置 / 点大小 / 裁剪距离）", sname, nm); free(body); return 0; }
        if (sl[s].used) { snprintf(why, 256, "%s 两个成员占同一槽 %d（%s）", sname, s, nm); free(body); return 0; }
        if (es * (uint32_t)cnt > cap) { snprintf(why, 256, "%s 成员 %s 超出槽宽 %u 字节", sname, nm, cap); free(body); return 0; }
        snprintf(sl[s].line, sizeof sl[s].line, "%s", ln); sl[s].sz = es * (uint32_t)cnt; sl[s].used = 1;
    }
    free(body);
    sb o = {0}; sb_put(&o, *msl, (size_t)(bp - *msl));
    for (int s = 0; s < nslot; s++) {
        uint32_t w = s == 34 ? 32 : 16;
        if (sl[s].used) { sb_str(&o, sl[s].line); sb_str(&o, "\n"); if (sl[s].sz < w) sb_fmt(&o, "    uint s2a_p%d[%u];\n", s, (w - sl[s].sz) / 4); }
        else sb_fmt(&o, "    uint s2a_p%d[%u];\n", s, w / 4);
    }
    o.n--; o.s[o.n] = 0;   // 去掉最后一个换行（原文 ep 处是 "\n};"）
    sb_str(&o, ep);
    free(*msl); *msl = o.s;
    return 1;
}

// ---- 曲面前顶点计算核：取属性（顶点自取表）+ 顶点号 / 实例号按本次绘制参数（s2a_td）算 ----
// SPIRV-Cross 生成：kernel void <入口>(<入口>_in in [[stage_in]]?, …, uint3 gl_GlobalInvocationID [[thread_position_in_grid]], uint3 spvStageInputSize [[grid_size]], uint3 spvDispatchBase [[grid_origin]]?, device <入口>_out* spvOut [[buffer(9)]])
//   体内 gl_VertexIndex = gl_GlobalInvocationID.x + spvDispatchBase.x; 等。改成：
//   去 [[stage_in]]（属性按 gal_vpull 的取数表读）、去 [[grid_origin]]，加 S2ATessVtx 参数（[[buffer(13)]]），函数体开头算 s2a_vid / s2a_iid / s2a_bv / s2a_bi
static const char k_vt_hdr[] =
"struct S2ATessVtx { ulong ib; uint isz; uint first; int base_vertex; uint base_instance; uint pad0, pad1; };\n"
"static inline uint s2a_tess_vid(constant S2ATessVtx& t, uint i) {\n"
"    if (t.ib == 0ul) return t.first + i;\n"
"    uint k = t.first + i;\n"
"    uint v = t.isz == 1u ? uint(((const device uchar*)t.ib)[k]) : t.isz == 2u ? uint(((const device ushort*)t.ib)[k]) : ((const device uint*)t.ib)[k];\n"
"    return uint(int(v) + t.base_vertex);\n"
"}\n";
char *gal_tess_vt_msl(const char *msl, const char *entry, int *pulled, uint32_t base, char *why) {
    *pulled = 0;
    char ksig[160]; snprintf(ksig, sizeof ksig, "kernel void %s(", entry);
    const char *ks = strstr(msl, ksig); if (!ks) { snprintf(why, 256, "曲面前顶点：找不到入口 %s", entry); return NULL; }
    const char *ke = strchr(ks, '\n'); const char *bo = ke ? strstr(ke, "\n{\n") : NULL;
    if (!ke || !bo || bo != ke) { snprintf(why, 256, "曲面前顶点：入口签名不规整"); return NULL; }
    char *sig = strndup(ks, (size_t)(ke - ks));
    // 属性结构体（stage_in）：去 [[attribute]]，记成员
    typedef struct { char ty, name[64]; int loc; } mb; mb m[32]; int nm = 0;
    char inhdr[160]; snprintf(inhdr, sizeof inhdr, "struct %s_in\n{\n", entry);
    char instage[200]; snprintf(instage, sizeof instage, "%s_in in [[stage_in]], ", entry);
    sb o = {0};
    const char *sb0 = strstr(msl, inhdr), *se = sb0 ? strstr(sb0, "\n};\n") : NULL;
    const char *ns = strstr(msl, "using namespace metal;\n"); if (!ns) { free(sig); snprintf(why, 256, "曲面前顶点：没有 using namespace metal"); return NULL; }
    ns += strlen("using namespace metal;\n");
    if (sb0 && se && se < ks && strstr(sig, instage)) {
        sb_put(&o, msl, (size_t)(ns - msl)); sb_str(&o, nxgal_test_vpull_msl()); sb_str(&o, k_vt_hdr);
        sb_put(&o, ns, (size_t)(sb0 + strlen(inhdr) - ns));
        char *body = strndup(sb0 + strlen(inhdr), (size_t)(se - (sb0 + strlen(inhdr)))), *sv = NULL;
        for (char *ln = strtok_r(body, "\n", &sv); ln; ln = strtok_r(NULL, "\n", &sv)) {
            char ty[16], name[64]; int loc;
            if (sscanf(ln, " %15s %63s [[attribute(%d)]];", ty, name, &loc) != 3 || nm >= 32 || loc < 0 || loc >= 32 || strchr(name, '[')) { snprintf(why, 256, "曲面前顶点：属性成员认不出：%s", ln); free(body); free(sig); free(o.s); return NULL; }
            char c = gal_vpull_kind(ty, name);
            if (!c) { snprintf(why, 256, "曲面前顶点：属性类型 %s 不是四分量", ty); free(body); free(sig); free(o.s); return NULL; }
            m[nm].ty = c; snprintf(m[nm].name, sizeof m[nm].name, "%s", name); m[nm].loc = loc; nm++;
            sb_fmt(&o, "    %s %s;\n", ty, name);
        }
        free(body);
        sb_put(&o, se + 1, (size_t)(ks - (se + 1)));
        *pulled = 1;
    } else {
        sb_put(&o, msl, (size_t)(ns - msl)); sb_str(&o, k_vt_hdr); sb_put(&o, ns, (size_t)(ks - ns));
    }
    // 签名：去 stage_in / grid_origin，加取数表与绘制参数
    // [[grid_size]] / [[grid_origin]] 是 stage_in 区域（setStageInRegion）的属性：不用 stage_in 时为 0，SPIRV-Cross 的越界判断会让全部线程直接返回
    //   （10-21 单测实测输出全 0）。网格大小改取 [[threads_per_grid]]，起点由 s2a_td 给
    int k; char *s1 = repl_all(sig, instage, "", &k), *s2 = repl_all(s1, ", uint3 spvDispatchBase [[grid_origin]]", "", &k); free(s1); free(sig);
    repl_inplace(&s2, "uint3 spvStageInputSize [[grid_size]]", "uint3 spvStageInputSize [[threads_per_grid]]");
    if (strstr(s2, "[[grid_size]]") || strstr(s2, "[[grid_origin]]")) { snprintf(why, 256, "曲面前顶点：签名里还有 stage_in 区域属性"); free(s2); free(o.s); return NULL; }
    size_t L = strlen(s2); if (L < 2 || s2[L - 1] != ')') { snprintf(why, 256, "曲面前顶点：签名结尾不是 )"); free(s2); free(o.s); return NULL; }
    s2[L - 1] = 0; sb_str(&o, s2); free(s2);
    sb_fmt(&o, ", constant S2ATessVtx& s2a_td [[buffer(%u)]]%s)\n{\n", GAL_TESS_AT(base, GAL_TESS_SLOT_POINTS), *pulled ? ", constant S2AVtxAttr* s2a_vt [[buffer(26)]]" : "");
    sb_str(&o, "    uint s2a_vid = s2a_tess_vid(s2a_td, gl_GlobalInvocationID.x); uint s2a_bi = s2a_td.base_instance; uint s2a_iid = gl_GlobalInvocationID.y + s2a_bi; int s2a_bv = s2a_td.base_vertex; (void)s2a_bv;\n");
    if (*pulled) {
        sb_fmt(&o, "    %s_in in = {};\n", entry);
        for (int i = 0; i < nm; i++) sb_fmt(&o, "    in.%s = s2a_v%c(s2a_vt, %d, s2a_vid, s2a_iid, s2a_bi);\n", m[i].name, m[i].ty, m[i].loc);
    }
    char *rest = strdup(bo + 3);
    int nv = repl_inplace(&rest, "gl_GlobalInvocationID.x + spvDispatchBase.x;", "s2a_vid;");
    int ni = repl_inplace(&rest, "gl_GlobalInvocationID.y + spvDispatchBase.y;", "s2a_iid;");
    int nbv = repl_inplace(&rest, " = spvDispatchBase.x;", " = uint(s2a_bv);");
    int nbi = repl_inplace(&rest, " = spvDispatchBase.y;", " = s2a_bi;");
    (void)nv; (void)ni; (void)nbv; (void)nbi;
    if (strstr(rest, "spvDispatchBase")) { snprintf(why, 256, "曲面前顶点：还有认不出的 spvDispatchBase 用法"); free(rest); free(o.s); return NULL; }
    sb_str(&o, rest); free(rest);
    return o.s;
}

// 从入口签名里删一个参数（在首位时后面跟 ", "，否则前面是 ", "）；返回删掉的次数
static int drop_param(char **sig, const char *p) {
    char a[260]; int n;
    snprintf(a, sizeof a, ", %s", p); n = repl_inplace(sig, a, ""); if (n) return n;
    snprintf(a, sizeof a, "%s, ", p); n = repl_inplace(sig, a, ""); if (n) return n;
    return repl_inplace(sig, p, "");
}
// ---- TES → 普通顶点函数 ----
// SPIRV-Cross 生成：[[ patch(quad|triangle[, N]) ]] vertex <入口>_out <入口>(…, float2 gl_TessCoordIn [[position_in_patch]] | float3 gl_TessCoord [[position_in_patch]], uint gl_PrimitiveID [[patch_id]]?, …)
//   体内 gl_in = &spvIn[gl_PrimitiveID * N]、gl_PatchVerticesIn = N（N = 翻译时设的输出控制点数哨兵 GAL_TESS_OCP_SENTINEL）。改成：
//   普通 vertex 函数，参数换成 [[vertex_id]] + 域点缓冲（[[buffer(13)]]）+ 输出控制点数（[[buffer(12)]]），函数体开头从域点取 gl_TessCoord / gl_PrimitiveID
char *gal_tess_tes_msl(const char *msl, const char *entry, int tri, uint32_t base, char *why) {
    char a1[200], a2[200];
    snprintf(a1, sizeof a1, "%s gl_TessCoord%s [[position_in_patch]]", tri ? "float3" : "float2", tri ? "" : "In");
    const char *pp = strstr(msl, "[[ patch(");
    char sig[160]; snprintf(sig, sizeof sig, "vertex %s_out %s(", entry, entry);
    const char *vs = strstr(msl, sig);
    if (!pp || !vs || pp > vs) { snprintf(why, 256, "TES：找不到 [[patch]] 入口 %s", entry); return NULL; }
    const char *pe = strstr(pp, ") ]] "); if (!pe || pe + 5 != vs) { snprintf(why, 256, "TES：[[patch]] 属性不规整"); return NULL; }
    const char *ke = strchr(vs, '\n'); if (!ke || strncmp(ke, "\n{\n", 3)) { snprintf(why, 256, "TES：入口签名不规整"); return NULL; }
    char *s2 = strndup(vs, (size_t)(ke - vs)); (void)a2;
    int k1 = drop_param(&s2, a1), k2 = drop_param(&s2, "uint gl_PrimitiveID [[patch_id]]");
    if (!k1) { snprintf(why, 256, "TES：签名里没有 %s", a1); free(s2); return NULL; }
    size_t L = strlen(s2); if (s2[L - 1] != ')') { free(s2); snprintf(why, 256, "TES：签名结尾不是 )"); return NULL; }
    s2[L - 1] = 0;
    sb o = {0}; sb_put(&o, msl, (size_t)(pp - msl)); sb_str(&o, s2); free(s2);
    sb_fmt(&o, ", uint s2a_vid [[vertex_id]], const device float4* s2a_pts [[buffer(%u)]], constant uint& s2a_ocp [[buffer(%u)]])\n{\n", GAL_TESS_AT(base, GAL_TESS_SLOT_POINTS), GAL_TESS_AT(base, GAL_TESS_SLOT_PARAMS));
    sb_fmt(&o, "    float4 s2a_pt = s2a_pts[s2a_vid];\n    %s\n", tri ? "float3 gl_TessCoord = s2a_pt.xyz;" : "float2 gl_TessCoordIn = s2a_pt.xy;");
    if (k2) sb_str(&o, "    uint gl_PrimitiveID = as_type<uint>(s2a_pt.w);\n");
    char *rest = strdup(ke + 3), num[24]; snprintf(num, sizeof num, "%u", GAL_TESS_OCP_SENTINEL);
    char r1[48], r2[48]; snprintf(r1, sizeof r1, " * %s]", num); snprintf(r2, sizeof r2, " = %s;", num);
    repl_inplace(&rest, r1, " * s2a_ocp]"); repl_inplace(&rest, r2, " = s2a_ocp;");
    sb_str(&o, rest); free(rest);
    if (strstr(o.s, num)) { snprintf(why, 256, "TES：输出控制点数哨兵 %s 还有残留（SPIRV-Cross 生成形式变了）", num); free(o.s); return NULL; }
    if (strstr(o.s, "[[position_in_patch]]") || strstr(o.s, "[[patch_id]]")) { const char *q = strstr(o.s, "[[patch_id]]"); if (!q) q = strstr(o.s, "[[position_in_patch]]");
        snprintf(why, 256, "TES：改写后仍有 [[position_in_patch]] / [[patch_id]]（%.80s）", q > o.s + 60 ? q - 60 : o.s); free(o.s); return NULL; }
    return o.s;
}

static void xc_err_cb(void *ud, const char *msg) { snprintf((char *)ud, 512, "%s", msg); }

// ---------- 曲面细分（计算展开，gal_tess.m）：SPIRV-Cross 选项与翻完的 MSL 后处理 ----------
// Metal 4 没有固定功能曲面细分（MTL4RenderCommandEncoder 无 drawPatches、MTL4RenderPipelineDescriptor 无细分属性，10-21 M5 Max 运行时探针核过），
// 所以三段都翻成我们自己调度的东西：顶点 → 计算核（写控制点）、TCS → 计算核（写控制点 + 细分因子，multi_patch_workgroup）、
// TES → 普通顶点函数（gal_tess.m 把 SPIRV-Cross 的 [[patch]] 后细分函数改写成按域点缓冲取 gl_TessCoord / gl_PrimitiveID），中间的细分器是 gal_tess.m 的计算核（D3D11 参照算法）。
// 阶段之间的接口（控制点 / 每片属性结构体）固定成「规范布局」（gal_internal.h GAL_TESS_CP_BYTES）：翻完由 gal_tess_canon 按成员 Location 重排补位，
// 单支着色器可以单独翻、离线库按单支索引；不在规范里的成员判翻译失败。（SPIRV-Cross 自带的 add_msl_shader_input/output 补位不行：
// 内建成员一律排在末尾、按类型排序，没写的内建补成 uint，两边内建集合不同时布局就错开——10-21 怪猎实测顶点输出 560 字节、TCS 输入 544 字节）
// 读曲面执行模式进记录（TCS / TES）；isolines 交给 SPIRV-Cross 时按 quads 翻（Metal 没有 isolines，SPIRV-Cross 直接拒绝；我们的细分器自己展开等值线，着色器只用 gl_TessCoord.xy）
// stage：1 顶点（vt 变体）/ 2 TCS / 3 TES；*flags 收记录位，*ocp 收 TCS 输出控制点数
int gal_tessxc_modes(spvc_compiler c, int stage, int vt, uint32_t *flags, uint32_t *ocp, char *why) {
    (void)vt;
    if (stage == 1) { *flags |= GAL_REC_VT; return 1; }
    const SpvExecutionMode *m; size_t n; spvc_compiler_get_execution_modes(c, &m, &n);
    uint32_t dom = 0, sp = 0, cw = 0, pt = 0;
    for (size_t i = 0; i < n; i++) switch (m[i]) {
        case SpvExecutionModeIsolines: dom = GAL_TESS_ISO; break;
        case SpvExecutionModeTriangles: dom = GAL_TESS_TRI; break;
        case SpvExecutionModeQuads: dom = GAL_TESS_QUAD; break;
        case SpvExecutionModeSpacingEqual: sp = GAL_TESS_EQUAL; break;
        case SpvExecutionModeSpacingFractionalOdd: sp = GAL_TESS_FODD; break;
        case SpvExecutionModeSpacingFractionalEven: sp = GAL_TESS_FEVEN; break;
        case SpvExecutionModeVertexOrderCw: cw = 1; break;
        case SpvExecutionModePointMode: pt = 1; break;
        default: break;
    }
    if (!dom) { snprintf(why, 256, "曲面阶段（执行模型 %d）没有域执行模式（Ryujinx 补丁 tess-tcs-modes 让 TCS 也带域）", stage == 2 ? 1 : 2); return 0; }
    if (!sp) sp = GAL_TESS_EQUAL;
    *flags |= dom << GAL_REC_DOM_SHIFT | sp << GAL_REC_SP_SHIFT | (cw ? GAL_REC_CW : 0) | (pt ? GAL_REC_POINT : 0);
    if (dom == GAL_TESS_ISO) { spvc_compiler_unset_execution_mode(c, SpvExecutionModeIsolines); spvc_compiler_set_execution_mode(c, SpvExecutionModeQuads); }
    if (stage == 2) {
        *ocp = spvc_compiler_get_execution_mode_argument(c, SpvExecutionModeOutputVertices);
        if (!*ocp || *ocp > 32) { snprintf(why, 256, "TCS 输出控制点数 %u 不在 1..32", *ocp); return 0; }
    }
    return 1;
}
// base：曲面接口缓冲的起始槽号，依次 IN / OUT / PATCH / FACTOR / PARAMS / POINTS（gal 用 GAL_TESS_SLOT_IN = 8；直连另给，见 nxgal_dmsh_xc_tess）
void gal_tessxc_options(spvc_compiler c, spvc_compiler_options o, int vt, uint32_t base) {
    spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_MULTI_PATCH_WORKGROUP, SPVC_TRUE);
    spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_RAW_BUFFER_TESE_INPUT, SPVC_TRUE);
    if (vt) { spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_VERTEX_FOR_TESSELLATION, SPVC_TRUE); spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_VERTEX_INDEX_TYPE, SPVC_MSL_INDEX_TYPE_NONE); }
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_SHADER_INPUT_BUFFER_INDEX, base);
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_SHADER_OUTPUT_BUFFER_INDEX, GAL_TESS_AT(base, GAL_TESS_SLOT_OUT));
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_SHADER_PATCH_OUTPUT_BUFFER_INDEX, GAL_TESS_AT(base, GAL_TESS_SLOT_PATCH));
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_SHADER_PATCH_INPUT_BUFFER_INDEX, GAL_TESS_AT(base, GAL_TESS_SLOT_PATCH));
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_SHADER_TESS_FACTOR_OUTPUT_BUFFER_INDEX, GAL_TESS_AT(base, GAL_TESS_SLOT_FACTOR));
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_INDIRECT_PARAMS_BUFFER_INDEX, GAL_TESS_AT(base, GAL_TESS_SLOT_PARAMS));
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_SHADER_INPUT_WORKGROUP_INDEX, 0);
    // TES 单独翻时不知道 TCS 的输出控制点数：先填哨兵，改写时换成运行时参数（gal_tess_tes_msl）
    if (spvc_compiler_get_execution_model(c) == SpvExecutionModelTessellationEvaluation)
        spvc_compiler_set_execution_mode_with_arguments(c, SpvExecutionModeOutputVertices, GAL_TESS_OCP_SENTINEL, 0, 0);
}
// 接口变量名 → 位置号（规范布局重排用）：SPIRV-Cross 的成员名有名用名、无名是 m_<变量号>，两个都登记
static gal_tess_loc *tess_locs(spvc_compiler c, spvc_resources res, int *n) {
    const spvc_reflected_resource *l; size_t k; int cap = 0; *n = 0; gal_tess_loc *o = NULL;
    for (int io = 0; io < 2; io++) {
        spvc_resources_get_resource_list_for_type(res, io ? SPVC_RESOURCE_TYPE_STAGE_OUTPUT : SPVC_RESOURCE_TYPE_STAGE_INPUT, &l, &k);
        for (size_t i = 0; i < k; i++) {
            if (spvc_compiler_has_decoration(c, l[i].id, SpvDecorationBuiltIn) || !spvc_compiler_has_decoration(c, l[i].id, SpvDecorationLocation)) continue;
            if (*n + 2 > cap) { cap = cap ? cap * 2 : 64; o = realloc(o, (size_t)cap * sizeof *o); }
            uint32_t loc = spvc_compiler_get_decoration(c, l[i].id, SpvDecorationLocation); uint8_t pt = spvc_compiler_has_decoration(c, l[i].id, SpvDecorationPatch);
            snprintf(o[*n].name, sizeof o[*n].name, "m_%u", (unsigned)l[i].id); o[*n].loc = loc; o[*n].patch = pt; (*n)++;
            if (l[i].name && *l[i].name) { snprintf(o[*n].name, sizeof o[*n].name, "%s", l[i].name); o[*n].loc = loc; o[*n].patch = pt; (*n)++; }
        }
    }
    return o;
}
// 翻完的曲面阶段 MSL 后处理：顶点计算核取属性 / TES 改普通顶点函数 / 接口结构体规范布局。成功返回新串（调用方 free），失败 NULL + why
static char *tess_post(const char *src, int stage, int vt, const char *entry, uint32_t *flags, const gal_tess_loc *locs, int nlocs, uint32_t base, char *why) {
    char *m = NULL; int pulled = 0;
    if (vt) { m = gal_tess_vt_msl(src, entry, &pulled, base, why); if (m && pulled) *flags |= 4; }
    else if (stage == 3) m = gal_tess_tes_msl(src, entry, ((*flags >> GAL_REC_DOM_SHIFT) & 3) == GAL_TESS_TRI, base, why);
    else m = strdup(src);
    if (!m) return NULL;
    char nm[160]; int ok = 1;
    snprintf(nm, sizeof nm, "%s_patchOut", entry); if (strstr(m, nm)) *flags |= GAL_REC_PATCH;
    snprintf(nm, sizeof nm, "%s_patchIn", entry); if (strstr(m, nm)) *flags |= GAL_REC_PATCH;
    if (vt || stage == 2) { snprintf(nm, sizeof nm, "%s_out", entry); ok = ok && gal_tess_canon(&m, nm, 1, locs, nlocs, why); }
    if (stage == 2 || stage == 3) { snprintf(nm, sizeof nm, "%s_in", entry); ok = ok && gal_tess_canon(&m, nm, 1, locs, nlocs, why); }
    if (stage == 2) { snprintf(nm, sizeof nm, "%s_patchOut", entry); ok = ok && gal_tess_canon(&m, nm, 0, locs, nlocs, why); }
    if (stage == 3) { snprintf(nm, sizeof nm, "%s_patchIn", entry); ok = ok && gal_tess_canon(&m, nm, 0, locs, nlocs, why); }
    if (!ok) { free(m); return NULL; }
    return m;
}

// 翻完的曲面阶段：接口变量位置表 + 后处理（顶点计算核取属性 / TES 改普通顶点函数 / 规范布局）。成功返回新串（调用方 free），失败 NULL + why
char *gal_tessxc_post(spvc_compiler c, spvc_resources res, const char *src, int stage, int vt, const char *entry, uint32_t *flags, uint32_t base, char *why) {
    int nl = 0; gal_tess_loc *locs = tess_locs(c, res, &nl);
    char *t = tess_post(src, stage, vt, entry, flags, locs, nl, base, why); free(locs);
    return t;
}

// 直连曲面阶段（10-24 直连曲面细分 T1，docs/研究/直连曲面细分设计.md；与渲染器同一套曲面翻译）：一支 SPIR-V 按 nxgal_dmsh_xc 的直连口径（不加固、不改名、不改绑定）
//   + 本文件的曲面选项与改写（tess_modes / tess_options / tess_post：规范布局、曲面前顶点计算核、TES 转普通顶点函数）出 MSL。
//   vt = 1：顶点着色器按「曲面细分前的顶点」翻成计算核；否则按执行模型：TCS → 计算核、TES → 普通顶点函数。base：曲面接口缓冲起始槽号（GAL_TESS_AT；渲染器用 GAL_TESS_SLOT_IN）。
//   *flags = 记录位（域 / 分区 / 绕序 / 点模式 / 每片属性 / 顶点自取，同离线索引），*ocp = TCS 的输出控制点数（其余阶段 0）。返回 0 成功、*out 为 malloc 的文本（nxgal_dmsh_xc_free）；非 0 失败、err 写原因
NXGAL_API int32_t nxgal_dmsh_xc_tess(const void *spv, uint64_t len, int32_t vt, uint32_t base, char **out, uint32_t *flags, uint32_t *ocp, char *err, uint64_t errlen) {
    *out = NULL; *flags = 0; *ocp = 0; if (errlen) err[0] = 0;
    if (len < 20 || (len & 3) || *(const uint32_t *)spv != 0x07230203) { snprintf(err, errlen, "不是 SPIR-V（长 %llu）", (unsigned long long)len); return 1; }
    spvc_context ctx = NULL; char cberr[512] = "", why[256] = ""; int rc = 1; uint32_t fl = 0, oc = 0;
    if (spvc_context_create(&ctx) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 上下文建不出"); return 1; }
    spvc_context_set_error_callback(ctx, xc_err_cb, cberr);
    spvc_parsed_ir ir = NULL; spvc_compiler c = NULL; spvc_compiler_options o = NULL; spvc_resources res = NULL; const char *src = NULL;
    if (spvc_context_parse_spirv(ctx, (const SpvId *)spv, (size_t)(len / 4), &ir) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 解析失败：%s", cberr); goto out; }
    if (spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &c) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 建编译器失败：%s", cberr); goto out; }
    const spvc_entry_point *eps; size_t neps; spvc_compiler_get_entry_points(c, &eps, &neps);
    if (neps != 1) { snprintf(err, errlen, "入口数 %zu ≠ 1", neps); goto out; }
    SpvExecutionModel model = eps[0].execution_model;
    int stage = model == SpvExecutionModelVertex && vt ? 1 : model == SpvExecutionModelTessellationControl ? 2 : model == SpvExecutionModelTessellationEvaluation ? 3 : -1;
    if (stage < 0) { snprintf(err, errlen, "不是曲面阶段（执行模型 %d、vt %d）", (int)model, vt); goto out; }
    if (!gal_tessxc_modes(c, stage, vt, &fl, &oc, why)) { snprintf(err, errlen, "%s", why); goto out; }
    spvc_compiler_create_compiler_options(c, &o);
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_MACOS);
    spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_VERSION, SPVC_MAKE_MSL_VERSION(3, 1, 0));   // 同直连非曲面（nxgal_dmsh_xc）与通用层曲面（gal_prog.m）：图像原子走原生（审计 #1534 P1-43）
    spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, SPVC_TRUE);
    spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_TEXTURE_BUFFER_NATIVE, SPVC_TRUE);
    spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_PAD_FRAGMENT_OUTPUT_COMPONENTS, SPVC_TRUE);
    gal_tessxc_options(c, o, vt, base);
    spvc_compiler_install_compiler_options(c, o);
    if (spvc_compiler_compile(c, &src) != SPVC_SUCCESS || !src) { snprintf(err, errlen, "SPIRV-Cross 编译失败：%s", cberr); goto out; }
    spvc_compiler_create_shader_resources(c, &res);
    {   char *t = gal_tessxc_post(c, res, src, stage, vt, spvc_compiler_get_cleansed_entry_point_name(c, eps[0].name, model), &fl, base, why);
        if (!t) { snprintf(err, errlen, "%s", why); goto out; }
        *out = t; *flags = fl; *ocp = stage == 2 ? oc : 0; rc = 0; }
out:
    spvc_context_destroy(ctx);
    return rc;
}
#else
NXGAL_API int32_t nxgal_dmsh_xc_tess(const void *spv, uint64_t len, int32_t vt, uint32_t base, char **out, uint32_t *flags, uint32_t *ocp, char *err, uint64_t errlen) {
    (void)spv; (void)len; (void)vt; (void)base; *out = NULL; *flags = 0; *ocp = 0; snprintf(err, errlen, "本构建没有 SPIRV-Cross（NXGAL_NO_XC）"); return 1;
}
#endif

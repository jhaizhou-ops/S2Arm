// 逻辑运算（10-24 画面·着色器线，异度神剑3 实局 OR 写 RG32Uint / R32Uint）：Metal 片元没有逻辑运算（Vulkan logicOp），用帧缓冲读取仿真。
// 参照：MoltenVK 报 logicOp 不支持；Ryujinx Metal 后端不实现。苹果 GPU 片元可用 [[color(n)]] 读当前附件值（整数格式也行），这里在片元阶段自己算：
// 做法（结构同宽线 gal_wline.m「同一编译单元再出一个入口」）：片元着色器在 MSL 末尾追加（以 GAL_MSL_LOP 起头）——
//   原入口函数体照搬成普通函数 s<键>_lob（参数去掉 [[属性]]），新入口 s<键>_lo = 原参数 + 每个整数输出位置 i 一个 [[color(i)]] 读当前值
//   + [[buffer(GAL_LOP_SLOT)]] 的逻辑运算参数，调 _lob 得输出后对每个整数输出做 s2a_lop_apply（按位，16 种 GL 逻辑运算），浮点输出原样。
//   与宽线不同：原入口不改调 _lob（函数体在源码里出现两次，前端多编一份，只发生在有整数颜色输出的片元上，九款普查约万分之几）。
//   普通函数里的 discard_fragment() 照常丢弃（MSL 允许片元入口调用链里的函数丢弃；单测 t_logicop 丢弃一半像素验证）。
// 参数表 S2ALop（gal_state.m 常驻表一项）：运算号（0–15 = GL 0x1500–0x150F）+ 每目标格式类别与各分量位宽（r | g<<8 | b<<16 | a<<24）。
//   类别 0 原样（浮点 / sRGB / 不做的目标）、1 纯无符号整数、2 纯有符号整数、3 unorm、4 snorm（未实现，原样）。
//   整数按位宽截取后运算（R8Uint 的 INVERT 只翻低 8 位，有符号再按位宽符号扩展）；unorm 按存储位模式：round(x × (2^位宽 − 1)) 成整数，运算后再除回。
//   unorm 分支已写好、单测核过 R8Unorm / RGBA8Unorm 换算，但 _lo 入口只给整数输出的片元出：unorm 目标由浮点输出写，几乎所有片元都是，全出会让离线库片元代码量翻倍（10-24 总指挥拍板）。
#include "gal_internal.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char k_lop_msl[] =
"// ---- S2A 逻辑运算（gal_logicop.m）----\n"
"#pragma clang diagnostic push\n#pragma clang diagnostic ignored \"-Wunused-function\"\n"
"struct S2ALop { uint op; uint kind[8]; uint bits[8]; };\n"
"static inline uint s2a_lop1(uint s, uint d, uint op) {\n"
"    switch (op & 15u) {\n"
"    case 0u: return 0u;          case 1u: return s & d;      case 2u: return s & ~d;     case 3u: return s;\n"
"    case 4u: return ~s & d;      case 5u: return d;          case 6u: return s ^ d;      case 7u: return s | d;\n"
"    case 8u: return ~(s | d);    case 9u: return ~(s ^ d);   case 10u: return ~d;        case 11u: return s | ~d;\n"
"    case 12u: return ~s;         case 13u: return ~s | d;    case 14u: return ~(s & d);  default: return 0xffffffffu;\n"
"    }\n"
"}\n"
"static inline uint4 s2a_lop_w(uint b) { return uint4(b & 255u, (b >> 8) & 255u, (b >> 16) & 255u, b >> 24); }\n"
"static inline uint4 s2a_lop_m(uint4 w) { return select((uint4(1u) << min(w, uint4(31u))) - 1u, uint4(0xffffffffu), w >= 32u); }\n"
"// 整数：按位宽截取 → 运算 → 截取；有符号按位宽符号扩展（写回窄格式时与存储位一致）\n"
"static inline uint4 s2a_lop_i(uint4 s, uint4 d, uint op, uint kind, uint bits) {\n"
"    uint4 w = s2a_lop_w(bits), m = s2a_lop_m(w), r;\n"
"    for (int c = 0; c < 4; c++) r[c] = s2a_lop1(s[c] & m[c], d[c] & m[c], op) & m[c];\n"
"    if (kind == 2u) r = select(r, r | ~m, w > 0u && w < 32u && (r & (uint4(1u) << (w - min(w, uint4(1u))))) != 0u);\n"
"    return kind == 1u || kind == 2u ? r : s;\n"
"}\n"
"// unorm：按存储位模式（round(x × (2^位宽 − 1))）运算再换回\n"
"static inline float4 s2a_lop_un(float4 s, float4 d, uint op, uint kind, uint bits) {\n"
"    if (kind != 3u) return s;\n"
"    uint4 w = s2a_lop_w(bits), m = s2a_lop_m(min(w, uint4(24u))); float4 mx = float4(m);\n"
"    uint4 su = uint4(rint(saturate(s) * mx)), du = uint4(rint(saturate(d) * mx)), r;\n"
"    for (int c = 0; c < 4; c++) r[c] = s2a_lop1(su[c], du[c], op) & m[c];\n"
"    return select(s, float4(r) / mx, w != 0u);\n"
"}\n"
"static inline uint4 s2a_lop_apply(uint4 s, uint4 d, constant S2ALop& L, uint i) { return s2a_lop_i(s, d, L.op, L.kind[i], L.bits[i]); }\n"
"static inline uint3 s2a_lop_apply(uint3 s, uint3 d, constant S2ALop& L, uint i) { return s2a_lop_i(uint4(s, 0u), uint4(d, 0u), L.op, L.kind[i], L.bits[i]).xyz; }\n"
"static inline uint2 s2a_lop_apply(uint2 s, uint2 d, constant S2ALop& L, uint i) { return s2a_lop_i(uint4(s, 0u, 0u), uint4(d, 0u, 0u), L.op, L.kind[i], L.bits[i]).xy; }\n"
"static inline uint s2a_lop_apply(uint s, uint d, constant S2ALop& L, uint i) { return s2a_lop_i(uint4(s, 0u, 0u, 0u), uint4(d, 0u, 0u, 0u), L.op, L.kind[i], L.bits[i]).x; }\n"
"static inline int4 s2a_lop_apply(int4 s, int4 d, constant S2ALop& L, uint i) { return as_type<int4>(s2a_lop_apply(as_type<uint4>(s), as_type<uint4>(d), L, i)); }\n"
"static inline int3 s2a_lop_apply(int3 s, int3 d, constant S2ALop& L, uint i) { return as_type<int3>(s2a_lop_apply(as_type<uint3>(s), as_type<uint3>(d), L, i)); }\n"
"static inline int2 s2a_lop_apply(int2 s, int2 d, constant S2ALop& L, uint i) { return as_type<int2>(s2a_lop_apply(as_type<uint2>(s), as_type<uint2>(d), L, i)); }\n"
"static inline int s2a_lop_apply(int s, int d, constant S2ALop& L, uint i) { return as_type<int>(s2a_lop_apply(as_type<uint>(s), as_type<uint>(d), L, i)); }\n"
"static inline float4 s2a_lop_apply(float4 s, float4 d, constant S2ALop& L, uint i) { return s2a_lop_un(s, d, L.op, L.kind[i], L.bits[i]); }\n"
"static inline float3 s2a_lop_apply(float3 s, float3 d, constant S2ALop& L, uint i) { return s2a_lop_un(float4(s, 0.0f), float4(d, 0.0f), L.op, L.kind[i], L.bits[i]).xyz; }\n"
"static inline float2 s2a_lop_apply(float2 s, float2 d, constant S2ALop& L, uint i) { return s2a_lop_un(float4(s, 0.0f, 0.0f), float4(d, 0.0f, 0.0f), L.op, L.kind[i], L.bits[i]).xy; }\n"
"static inline float s2a_lop_apply(float s, float d, constant S2ALop& L, uint i) { return s2a_lop_un(float4(s, 0.0f, 0.0f, 0.0f), float4(d, 0.0f, 0.0f, 0.0f), L.op, L.kind[i], L.bits[i]).x; }\n"
"#pragma clang diagnostic pop\n"
"// ---- 逻辑运算辅助完 ----\n";
const char *gal_logicop_helpers(void) { return k_lop_msl; }

typedef struct { char *s; size_t n, cap; } lsb_;
static void put(lsb_ *b, const char *p, size_t n) {
    if (b->n + n + 1 > b->cap) { b->cap = (b->n + n + 1) * 2; b->s = realloc(b->s, b->cap); }
    memcpy(b->s + b->n, p, n); b->n += n; b->s[b->n] = 0;
}
static void str(lsb_ *b, const char *p) { put(b, p, strlen(p)); }
static void fmt(lsb_ *b, const char *f, ...) __attribute__((format(printf, 2, 3)));
static void fmt(lsb_ *b, const char *f, ...) { char t[1024]; va_list ap; va_start(ap, f); vsnprintf(t, sizeof t, f, ap); va_end(ap); str(b, t); }
static const char *closep(const char *p) { int d = 0; for (const char *q = p; *q; q++) { if (*q == '(') d++; else if (*q == ')' && --d == 0) return q; } return NULL; }

// 参数切分（同 gal_wline.m）：a 起、ne 名尾、nb 名首、at 属性起（无则 = e）、e 止
typedef struct { const char *a, *ne, *nb, *at, *e; } lprm;
static int params(const char *lp, const char *rp, lprm *o, int cap) {
    int n = 0;
    for (const char *p = lp + 1; p < rp && n < cap;) {
        int dd = 0; const char *e = p;
        for (; e < rp; e++) { if (*e == '(' || *e == '<' || *e == '[') dd++; else if (*e == ')' || *e == '>' || *e == ']') dd--; else if (*e == ',' && dd == 0) break; }
        const char *a = p; while (a < e && isspace((unsigned char)*a)) a++;
        const char *at = strstr(a, "[["); if (!at || at > e) at = e;
        const char *ne = at; while (ne > a && ne[-1] == ' ') ne--;
        const char *nb = ne; while (nb > a && (isalnum((unsigned char)nb[-1]) || nb[-1] == '_')) nb--;
        if (nb == ne) return -1;
        o[n++] = (lprm){a, ne, nb, at, e};
        p = e < rp ? e + 1 : rp;
    }
    return n;
}
// 整数颜色类型：uint / uint2–4 / int / int2–4
static int int_type(const char *t, size_t n) {
    size_t k = n >= 4 && !strncmp(t, "uint", 4) ? 4 : n >= 3 && !strncmp(t, "int", 3) ? 3 : 0;
    if (!k) return 0;
    return n == k || (n == k + 1 && t[k] >= '2' && t[k] <= '4');
}

// msl：片元着色器整份 MSL；entry：入口名。返回追加了 s<键>_lo 入口的 MSL，NULL = 不出（没有整数颜色输出 / 不规整）
char *gal_logicop_msl(const char *msl, const char *entry) {
    if (strstr(msl, GAL_MSL_LOP)) return NULL;
    char pat[96]; snprintf(pat, sizeof pat, " %s(", entry);
    const char *sig = NULL, *ls = NULL, *fk = NULL;
    for (const char *q = strstr(msl, pat); q; q = strstr(q + 1, pat)) {
        const char *l = q; while (l > msl && l[-1] != '\n') l--;
        const char *f = strstr(l, "fragment ");   // 行首可带 [[ early_fragment_tests ]]
        if (f && f < q && (f == l || f[-1] == ' ')) { sig = q; ls = l; fk = f; break; }
    }
    if (!sig) return NULL;
    char ret[128]; size_t rl = (size_t)(sig - (fk + 9)); if (rl == 0 || rl >= sizeof ret) return NULL; memcpy(ret, fk + 9, rl); ret[rl] = 0;
    if (!strcmp(ret, "void")) return NULL;
    // 输出结构体：「    <类型> <名> [[color(N)]];」整数类型的记下（带 index(…) 的双源输出不出）
    char sh[160]; snprintf(sh, sizeof sh, "struct %s\n{\n", ret);
    const char *sb = strstr(msl, sh); if (!sb) return NULL;
    const char *se = strstr(sb, "\n};\n"); if (!se) return NULL;
    char oty[8][16], onm[8][96]; uint32_t ints = 0;
    for (const char *ln = sb + strlen(sh); ln < se;) {
        const char *le = strchr(ln, '\n'); if (!le || le > se) le = se;
        char line[256]; size_t ll = (size_t)(le - ln); if (ll >= sizeof line) return NULL; memcpy(line, ln, ll); line[ll] = 0;
        char ty[32], nm[96]; int loc = -1, used = 0;
        if (strstr(line, "[[color(")) {
            if (strstr(line, "index(")) return NULL;
            if (sscanf(line, " %31s %95s [[color(%d)]];%n", ty, nm, &loc, &used) < 3 || !used || loc < 0 || loc >= 8) return NULL;
            if (int_type(ty, strlen(ty))) {
                if (ints >> loc & 1) return NULL;
                ints |= 1u << loc; snprintf(oty[loc], sizeof oty[loc], "%s", ty); snprintf(onm[loc], sizeof onm[loc], "%s", nm);
            }
        }
        ln = le + 1;
    }
    if (!ints) return NULL;
    const char *lp = sig + strlen(pat) - 1, *rp = closep(lp); if (!rp) return NULL;
    const char *body = strstr(rp, "\n{\n"); if (!body) return NULL; body += 1;
    int d = 0; const char *be = NULL;
    for (const char *q = body; *q; q++) { if (*q == '{') d++; else if (*q == '}' && --d == 0) { be = q; break; } }
    if (!be) return NULL;
    lprm pm[64]; int np = params(lp, rp, pm, 64); if (np < 0 || np >= 64) return NULL;
    // 原入口已有的 [[color(i)]] 读（帧缓冲读取变体）沿用其名，不重复声明同一位置；GAL_LOP_SLOT 已被占用则不出
    char ldn[8][96]; for (int i = 0; i < 8; i++) snprintf(ldn[i], sizeof ldn[i], "s2a_ld%d", i);
    uint32_t have = 0;
    for (int i = 0; i < np; i++) {
        int c = -1, b = -1;
        if (pm[i].at < pm[i].e && sscanf(pm[i].at, "[[color(%d)", &c) == 1 && c >= 0 && c < 8 && (ints >> c & 1)) {
            size_t L = (size_t)(pm[i].ne - pm[i].nb); if (L >= sizeof ldn[c]) return NULL; memcpy(ldn[c], pm[i].nb, L); ldn[c][L] = 0; have |= 1u << c;
        }
        if (pm[i].at < pm[i].e && sscanf(pm[i].at, "[[buffer(%d)", &b) == 1 && b == GAL_LOP_SLOT) return NULL;
    }
    lsb_ plain = {0}, eps = {0}, call = {0};
    for (int i = 0; i < np; i++) {
        if (i) { str(&plain, ", "); str(&eps, ", "); str(&call, ", "); }
        put(&plain, pm[i].a, (size_t)(pm[i].ne - pm[i].a));
        put(&eps, pm[i].a, (size_t)(pm[i].e - pm[i].a));
        put(&call, pm[i].nb, (size_t)(pm[i].ne - pm[i].nb));
    }
    lsb_ o = {0};
    str(&o, msl); str(&o, GAL_MSL_LOP); str(&o, k_lop_msl);
    fmt(&o, "static inline %s %s_lob(", ret, entry); put(&o, plain.s ? plain.s : "", plain.n); str(&o, ")\n");
    put(&o, body, (size_t)(be + 1 - body)); str(&o, "\n\n");
    put(&o, ls, (size_t)(fk - ls));   // 入口前缀属性（early_fragment_tests 等）照搬
    fmt(&o, "fragment %s %s_lo(", ret, entry); put(&o, eps.s ? eps.s : "", eps.n);
    for (int i = 0; i < 8; i++) if ((ints >> i & 1) && !(have >> i & 1)) fmt(&o, "%s%s %s [[color(%d)]]", o.s[o.n - 1] == '(' ? "" : ", ", oty[i], ldn[i], i);
    fmt(&o, "%sconstant S2ALop& s2a_lop [[buffer(%d)]])\n{\n", o.s[o.n - 1] == '(' ? "" : ", ", GAL_LOP_SLOT);
    fmt(&o, "    %s s2a_r = %s_lob(", ret, entry); put(&o, call.s ? call.s : "", call.n); str(&o, ");\n");
    for (int i = 0; i < 8; i++) if (ints >> i & 1) fmt(&o, "    s2a_r.%s = s2a_lop_apply(s2a_r.%s, %s, s2a_lop, %du);\n", onm[i], onm[i], ldn[i], i);
    str(&o, "    return s2a_r;\n}\n");
    free(plain.s); free(eps.s); free(call.s);
    return o.s;
}

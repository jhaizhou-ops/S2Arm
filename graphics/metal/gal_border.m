// 自定义采样器边框颜色（10-21 画面·着色器线）：Metal 采样器只有透明黑 / 不透明黑 / 不透明白三种边框色，Maxwell 采样器的边框色任意（塞尔达 (0.13,0.5,0.5,0.03)）。
// 参照：Ryujinx Metal 后端（SamplerHolder.GetConstrainedBorderColor）与 MoltenVK（mvkMTLSamplerBorderColorFromVkBorderColor，不支持 VK_EXT_custom_border_color）
//   都只取最近的三种之一；这里改成着色器里模拟，结果精确：
// 做法：边框色不是三种之一（且确实有边框寻址、不是比较采样）的采样器建两份 Metal 采样器——主份透明黑 (0,0,0,0)、副份不透明白 (1,1,1,1)，其余状态相同。
//   过滤是各采样点的线性组合：结果 = Σ 界内权重 × 纹素 + 界外权重 W × 边框色。两份之差逐分量正好 = W，所以
//   结果 = 主份 + (副份 − 主份) × 自定义色（逐分量），双线性 / 三线性 / 各向异性 / 多级都精确；gather 每个采样点权重 0 或 1，同式按取的分量算。
// 着色器侧：SPIRV-Cross 出的 MSL 上做文本改写（同顶点自取的后处理层）——入口函数体里 X.sample(S, …) / X.gather(S, …)（S 是参数缓冲里的单个采样器，不是数组）
//   改成 s2a_bsample(X, S, s2a_bt[绑定号], …) / s2a_bgather<分量>(…)，入口加 constant S2ABorder* s2a_bt [[buffer(GAL_BORDER_SLOT)]]；
//   辅助函数在表项 on = 0 时只采一次（统一分支，表项每次绘制同值），on = 1 才采副份并混合。记录位 GAL_REC_BORDER 标出改写过的着色器，绘制时按程序的采样器绑定填表。
// 不改写的（照旧最近三种之一 + 首例报红）：比较采样（深度比较只看 R，R 是 0 / 1 时三种之一已精确）、采样器数组、入口以外的函数里的采样、曲面程序各段。
// 同一张表还管 LOD 偏置（#800）：本机 GPU 原生采样器偏置不生效时（gal_samp_caps.h s2a_lodbias_native，如 M3），采样器不带偏置、表项 lb = 偏置，
//   s2a_bsample 把它加到这次采样的 LOD 上（lb = 0 原样采，逐位同改写前）。gather 不涉 LOD，不加；比较采样不改写，带偏置的比较采样器建时报红（gal_tex.m）
#include "gal_internal.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char k_border_msl[] =
"// ---- S2A 自定义边框色（gal_border.m）----\n"
"struct S2ABorder { sampler alt; uint on; float lb; float4 c; };\n"
"static inline float4 s2a_bmix(float4 a, float4 b, float4 c) { return a + (b - a) * c; }\n"
"static inline half4 s2a_bmix(half4 a, half4 b, float4 c) { return half4(float4(a) + float4(b - a) * c); }\n"
"static inline float s2a_bmix(float a, float b, float4 c) { return a + (b - a) * c.x; }\n"
"template<typename T> static inline T s2a_bmix(T a, T b, float4 c) { return a; }\n"
"static inline float4 s2a_bmix1(float4 a, float4 b, float c) { return a + (b - a) * c; }\n"
"static inline half4 s2a_bmix1(half4 a, half4 b, float c) { return half4(float4(a) + float4(b - a) * c); }\n"
"template<typename T> static inline T s2a_bmix1(T a, T b, float c) { return a; }\n"
"// LOD 偏置模拟（#800）：b.lb ≠ 0 时把它加到这次采样的 LOD 上，同 Metal 26 采样器 lodBias 的语义（10-28 M5 Max 实测：隐式 / level / bias / gradient 都加）：\n"
"//   level(l) → level(l + k)，bias(x) → bias(x + k)，gradient → 两个导数 × 2^k；没写 LOD 的隐式采样插一个 S2A_LBK(k)：片元 bias(k)，顶点 / 计算 level(k)（那里隐式 LOD 就是 0）\n"
"#ifndef S2A_LBK\n#define S2A_LBK(k) level(k)\n#endif\n"
"static inline level s2a_lx(float k, level l) { return level(l.lod + k); }\n"
"static inline bias s2a_lx(float k, bias b) { return bias(b.value + k); }\n"
"static inline gradient2d s2a_lx(float k, gradient2d g) { float e = precise::exp2(k); return gradient2d(g.dPdx * e, g.dPdy * e); }\n"
"static inline gradient3d s2a_lx(float k, gradient3d g) { float e = precise::exp2(k); return gradient3d(g.dPdx * e, g.dPdy * e); }\n"
"static inline gradientcube s2a_lx(float k, gradientcube g) { float e = precise::exp2(k); return gradientcube(g.dPdx * e, g.dPdy * e); }\n"
"template<typename T> static inline T s2a_lx(float k, T a) { return a; }\n"
"template<int N> struct s2a_lt {};\n"
"template<typename T> struct s2a_il { enum { v = 0 }; };\n"
"template<> struct s2a_il<level> { enum { v = 1 }; }; template<> struct s2a_il<bias> { enum { v = 1 }; }; template<> struct s2a_il<gradient2d> { enum { v = 1 }; };\n"
"template<> struct s2a_il<gradient3d> { enum { v = 1 }; }; template<> struct s2a_il<gradientcube> { enum { v = 1 }; };\n"
"template<typename... A> struct s2a_al { enum { v = 0 }; };\n"
"template<typename H, typename... A> struct s2a_al<H, A...> { enum { v = s2a_il<H>::v | s2a_al<A...>::v }; };\n"
"struct s2a_tsmp { template<typename Tex, typename... A> auto operator()(Tex t, sampler s, A... a) const -> decltype(t.sample(s, a...)) { return t.sample(s, a...); } };\n"
"template<typename F, typename Tex, typename... A> static inline auto s2a_lbd(F f, Tex t, sampler s, float k, s2a_lt<1>, A... a) -> decltype(f(t, s, a...)) { return f(t, s, s2a_lx(k, a)...); }\n"
"template<typename F, typename Tex, typename C> static inline auto s2a_lbd(F f, Tex t, sampler s, float k, s2a_lt<0>, C c) -> decltype(f(t, s, c, S2A_LBK(k))) { return f(t, s, c, S2A_LBK(k)); }\n"
"template<typename F, typename Tex, typename C> static inline auto s2a_lbd(F f, Tex t, sampler s, float k, s2a_lt<0>, C c, int2 o) -> decltype(f(t, s, c, S2A_LBK(k), o)) { return f(t, s, c, S2A_LBK(k), o); }\n"
"template<typename F, typename Tex, typename C> static inline auto s2a_lbd(F f, Tex t, sampler s, float k, s2a_lt<0>, C c, int3 o) -> decltype(f(t, s, c, S2A_LBK(k), o)) { return f(t, s, c, S2A_LBK(k), o); }\n"
"template<typename F, typename Tex, typename C> static inline auto s2a_lbd(F f, Tex t, sampler s, float k, s2a_lt<0>, C c, uint i) -> decltype(f(t, s, c, i, S2A_LBK(k))) { return f(t, s, c, i, S2A_LBK(k)); }\n"
"template<typename F, typename Tex, typename C> static inline auto s2a_lbd(F f, Tex t, sampler s, float k, s2a_lt<0>, C c, uint i, int2 o) -> decltype(f(t, s, c, i, S2A_LBK(k), o)) { return f(t, s, c, i, S2A_LBK(k), o); }\n"
"template<typename F, typename Tex, typename... A> static inline auto s2a_lbd(F f, Tex t, sampler s, float k, s2a_lt<0>, A... a) -> decltype(f(t, s, a...)) { return f(t, s, a...); }\n"
"template<typename F, typename Tex, typename... A> static inline auto s2a_lb(F f, Tex t, sampler s, float k, A... a) -> decltype(f(t, s, a...)) { return s2a_lbd(f, t, s, k, s2a_lt<s2a_al<A...>::v>(), a...); }\n"
"template<typename Tex, typename... Ts> static inline auto s2a_bsample(Tex t, sampler s, constant S2ABorder& b, Ts... a) -> decltype(t.sample(s, a...)) {\n"
"    decltype(t.sample(s, a...)) r;\n"
"    if (b.lb == 0.0f) r = t.sample(s, a...); else r = s2a_lb(s2a_tsmp(), t, s, b.lb, a...);\n"
"    if (b.on != 0u) { decltype(r) r2; if (b.lb == 0.0f) r2 = t.sample(b.alt, a...); else r2 = s2a_lb(s2a_tsmp(), t, b.alt, b.lb, a...); r = s2a_bmix(r, r2, b.c); }\n"
"    return r;\n"
"}\n"
"#define S2A_BGATHER(X, I) template<typename Tex, typename... Ts> static inline auto s2a_bgather_##X(Tex t, sampler s, constant S2ABorder& b, Ts... a) -> decltype(t.gather(s, a..., component::X)) { \\\n"
"    auto r = t.gather(s, a..., component::X); if (b.on != 0u) r = s2a_bmix1(r, t.gather(b.alt, a..., component::X), b.c[I]); return r; }\n"
"S2A_BGATHER(x, 0)\nS2A_BGATHER(y, 1)\nS2A_BGATHER(z, 2)\nS2A_BGATHER(w, 3)\n"
"#undef S2A_BGATHER\n"
"// ---- 自定义边框色完 ----\n";

NXGAL_API const char *nxgal_test_border_msl(void) { return k_border_msl; }

typedef struct { char *s; size_t n, cap; } bsb;
static void bput(bsb *b, const char *p, size_t n) {
    if (b->n + n + 1 > b->cap) { b->cap = (b->n + n + 1) * 2; b->s = realloc(b->s, b->cap); }
    memcpy(b->s + b->n, p, n); b->n += n; b->s[b->n] = 0;
}
static void bstr(bsb *b, const char *p) { bput(b, p, strlen(p)); }

typedef struct { const char *const *names; const uint16_t *binds; int n; int hits; } bctx;
static int ident(char c) { return isalnum((unsigned char)c) || c == '_'; }
// [p, e) 里第一个顶层逗号（括号 / 方括号 / 尖括号不计；没有返回 e）
static const char *top_comma(const char *p, const char *e) {
    int d = 0;
    for (const char *q = p; q < e; q++) {
        if (*q == '(' || *q == '[') d++; else if (*q == ')' || *q == ']') d--;
        else if (*q == ',' && d == 0) return q;
    }
    return e;
}
// p 指向 '('：返回匹配的 ')'（没有返回 NULL）
static const char *close_paren(const char *p, const char *e) {
    int d = 0;
    for (const char *q = p; q < e; q++) { if (*q == '(') d++; else if (*q == ')' && --d == 0) return q; }
    return NULL;
}
// 采样器表达式 → 绑定号（-1 = 不是登记的单个采样器）
static int smp_bind(const bctx *x, const char *p, const char *e) {
    while (p < e && *p == ' ') p++; while (e > p && e[-1] == ' ') e--;
    if ((size_t)(e - p) < 18 || strncmp(p, "spvDescriptorSet", 16)) return -1;
    const char *d = p + 16; while (d < e && isdigit((unsigned char)*d)) d++;
    if (d == p + 16 || d >= e || *d != '.') return -1;
    d++;
    for (int i = 0; i < x->n; i++) { size_t L = strlen(x->names[i]); if ((size_t)(e - d) == L && !memcmp(d, x->names[i], L)) return x->binds[i]; }
    return -1;
}
// 改写 [p, e)：逐个 .sample( / .gather(（不含 _compare 等后缀），参数里嵌套的采样递归改写
static void rw(bctx *x, const char *p, const char *e, bsb *o) {
    const char *w = p;   // 已输出到 w
    for (const char *q = p; q < e; q++) {
        int gat = 0; size_t L;
        if (*q != '.') continue;
        if ((size_t)(e - q) > 8 && !memcmp(q, ".sample(", 8)) L = 8;
        else if ((size_t)(e - q) > 8 && !memcmp(q, ".gather(", 8)) { L = 8; gat = 1; }
        else continue;
        // 接收者：标识符与点（参数缓冲成员 spvDescriptorSetN.名）；带下标的（数组）不改
        const char *r0 = q; while (r0 > w && (ident(r0[-1]) || r0[-1] == '.')) r0--;
        if (r0 == q || (r0 > p && r0[-1] == ']')) continue;
        const char *lp = q + L - 1, *rp = close_paren(lp, e); if (!rp) continue;
        const char *c1 = top_comma(lp + 1, rp);
        int k = smp_bind(x, lp + 1, c1);
        if (k < 0) continue;
        // gather 的分量参数（末个顶层参数 component::x…）摘出来，编进辅助函数名
        const char *ae = rp; char comp = 'x';
        if (gat) {
            const char *last = c1, *t = c1;
            while (t < rp) { const char *n = top_comma(t + 1, rp); if (n >= rp) break; last = n; t = n; }
            const char *a = last + 1; while (a < rp && *a == ' ') a++;
            if (last > c1 && (size_t)(rp - a) == 12 && !strncmp(a, "component::", 11) && strchr("xyzw", a[11])) { comp = a[11]; ae = last; }
        }
        bput(o, w, (size_t)(r0 - w));
        char head[64]; if (gat) snprintf(head, sizeof head, "s2a_bgather_%c(", comp); else snprintf(head, sizeof head, "s2a_bsample(");
        bstr(o, head); bput(o, r0, (size_t)(q - r0)); bstr(o, ", ");
        bput(o, lp + 1, (size_t)(c1 - (lp + 1)));
        char tb[48]; snprintf(tb, sizeof tb, ", s2a_bt[%d]", k); bstr(o, tb);
        if (c1 < ae) rw(x, c1, ae, o);   // 余下参数（含前导逗号）
        bstr(o, ")");
        x->hits++;
        w = q = rp + 1; q--;
    }
    bput(o, w, (size_t)(e - w));
}

// msl：SPIRV-Cross 出的整份 MSL；entry：入口函数名；names / binds：参数缓冲里单个采样器成员名与绑定号。返回改写后的 MSL，NULL = 没有可改写的采样（原样用）
char *gal_border_msl(const char *msl, const char *entry, const char *const *names, const uint16_t *binds, int n) {
    if (n <= 0) return NULL;
    char pat[96]; snprintf(pat, sizeof pat, " %s(", entry);
    const char *sig = NULL;
    for (const char *q = strstr(msl, pat); q; q = strstr(q + 1, pat)) {
        const char *ls = q; while (ls > msl && ls[-1] != '\n') ls--;
        if (!strncmp(ls, "fragment ", 9) || !strncmp(ls, "vertex ", 7) || !strncmp(ls, "kernel ", 7) || !strncmp(ls, "[[", 2)) { sig = q; break; }
    }
    if (!sig) return NULL;
    const char *lp = sig + strlen(pat) - 1, *rp = close_paren(lp, msl + strlen(msl)); if (!rp) return NULL;
    const char *body = strstr(rp, "\n{\n"); if (!body) return NULL;
    body += 1;   // 指向函数体的 '{'
    int d = 0; const char *be = NULL;
    for (const char *q = body; *q; q++) { if (*q == '{') d++; else if (*q == '}' && --d == 0) { be = q; break; } }
    if (!be) return NULL;
    bctx x = {names, binds, n, 0};
    bsb nb = {0}; rw(&x, body, be, &nb);
    if (!x.hits) { free(nb.s); return NULL; }
    const char *ls = sig; while (ls > msl && ls[-1] != '\n') ls--;
    bsb o = {0};
    bput(&o, msl, (size_t)(ls - msl));
    const char *fr = strstr(ls, "fragment "); if (fr && fr < sig) bstr(&o, "#define S2A_LBK(k) bias(k)\n");   // 片元的隐式采样插 bias(k)（顶点 / 计算缺省 level(k)，见 k_border_msl）
    bstr(&o, k_border_msl);
    bput(&o, ls, (size_t)(rp - ls));
    char add[96]; snprintf(add, sizeof add, ", constant S2ABorder* s2a_bt [[buffer(%d)]]", GAL_BORDER_SLOT); bstr(&o, add);
    bput(&o, rp, (size_t)(body - rp));
    bput(&o, nb.s, nb.n); free(nb.s);
    bstr(&o, be);
    return o.s;
}

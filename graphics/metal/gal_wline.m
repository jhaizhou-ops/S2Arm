// 宽线（10-21 画面·着色器线）：Maxwell 线宽任意（塞尔达 2.0），Metal 只有 1 像素线。
// 参照：MoltenVK 只在开私有接口（useMetalPrivateAPI，-[MTLRenderCommandEncoder setLineWidth:]）时报 wideLines，否则线宽范围 [1,1]；
//   Ryujinx Metal 后端 SetLineParameters 为空（「Metal does not support wide-lines」）。两家都不模拟，这里在顶点阶段展开成四边形：
// 做法：顶点着色器在同一编译单元里再出一个入口 s<键>_wl——原入口函数体照搬成普通函数 s<键>_wlb（参数去掉 [[属性]]），
//   新入口按 vertex_id 算「第几段、段内第几个角」（每段 6 个顶点 = 2 个三角形），按线拓扑（列表 / 条带 / 环）与索引取两端的顶点号，
//   两端各按顶点自取（gal_vpull.m 的取数辅助，主入口没自取时也用它：stage_in 只能取当前顶点）填输入结构体、各调一次 s<键>_wlb 得两端的输出，在屏幕空间沿线段法向各推半个线宽（矩形线，同 Vulkan strictLines），其余输出原样（平直插值取第一个顶点 = a 端）。
//   绘制时（gal_draw.m）线拓扑且线宽 > 1：管线换 s<键>_wl（三角形拓扑类），画 6 × 段数个顶点，宽线参数绑参数表 GAL_WLINE_SLOT。
//   离线库里只多 AIR（中间码）；后端编码只在第一次画宽线建管线时发生（不进管线归档），没有宽线的程序不付后端编译。
// 不展开的（照 1 像素画并首例报红）：输入结构不规整的、同时写层号与点大小（无点大小变体另一库）、间接绘制、多边形线模式。
#include "gal_internal.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char k_wline_msl[] =
"// ---- S2A 宽线展开（gal_wline.m）----\n"
// rst = 开图元重启（条带 / 环，gal_draw.m 置）：索引等于该宽度的全 1 时断带——碰到它的段不画（同 1 像素条带的重启），不把它当顶点号取
"struct S2AWideLine { ulong ib; uint itype; uint first; int bv; uint mode; uint count; uint rst; float2 half_px; float width; uint pad2; };\n"
"static inline uint s2a_wl_raw(constant S2AWideLine& w, uint i) {\n"
"    return w.itype == 0u ? w.first + i : w.itype == 1u ? uint(reinterpret_cast<const device uchar*>(w.ib)[i])\n"
"           : w.itype == 2u ? uint(reinterpret_cast<const device ushort*>(w.ib)[i]) : reinterpret_cast<const device uint*>(w.ib)[i];\n"
"}\n"
"static inline uint2 s2a_wl_idx(constant S2AWideLine& w, uint s) {\n"
"    return uint2(w.mode == 0u ? 2u * s : s, w.mode == 0u ? 2u * s + 1u : w.mode == 2u && s + 1u == w.count ? 0u : s + 1u);\n"
"}\n"
"static inline uint2 s2a_wl_ends(constant S2AWideLine& w, uint s) {\n"
"    uint2 i = s2a_wl_idx(w, s); return uint2(uint(int(s2a_wl_raw(w, i.x)) + w.bv), uint(int(s2a_wl_raw(w, i.y)) + w.bv));\n"
"}\n"
"static inline bool s2a_wl_cut(constant S2AWideLine& w, uint s) {\n"
"    if (w.rst == 0u || w.itype == 0u) return false;\n"
"    uint2 i = s2a_wl_idx(w, s); uint r = w.itype == 1u ? 0xFFu : w.itype == 2u ? 0xFFFFu : 0xFFFFFFFFu;\n"
"    return s2a_wl_raw(w, i.x) == r || s2a_wl_raw(w, i.y) == r;\n"
"}\n"
"// 角 0..5：(a−, a+, b+), (a−, b+, b−)；矩形线：两端沿法向各推半个线宽（像素），换回裁剪空间乘 w。断带的段 6 个角落在同一点（零面积，不光栅化）\n"
"template<typename T> static inline T s2a_wl_quad(T a, T b, uint c, constant S2AWideLine& w, bool cut) {\n"
"    if (cut) { T r = a; r.gl_Position = float4(0.0f, 0.0f, 0.0f, 1.0f); return r; }\n"
"    bool atb = c == 2u || c == 4u || c == 5u; float side = (c == 1u || c == 2u || c == 4u) ? 1.0f : -1.0f;\n"
"    float2 pa = a.gl_Position.xy / a.gl_Position.w * w.half_px, pb = b.gl_Position.xy / b.gl_Position.w * w.half_px;\n"
"    float2 d = pb - pa; float l = length(d); d = l > 1e-6f ? d / l : float2(1.0f, 0.0f);\n"
"    float2 n = float2(-d.y, d.x) * (0.5f * w.width);\n"
"    T r = atb ? b : a; r.gl_Position.xy += n * side / w.half_px * r.gl_Position.w; return r;\n"
"}\n"
"// ---- 宽线展开完 ----\n";

typedef struct { char *s; size_t n, cap; } wsb;
static void wput(wsb *b, const char *p, size_t n) {
    if (b->n + n + 1 > b->cap) { b->cap = (b->n + n + 1) * 2; b->s = realloc(b->s, b->cap); }
    memcpy(b->s + b->n, p, n); b->n += n; b->s[b->n] = 0;
}
static void wstr(wsb *b, const char *p) { wput(b, p, strlen(p)); }
static const char *wclose(const char *p) { int d = 0; for (const char *q = p; *q; q++) { if (*q == '(') d++; else if (*q == ')' && --d == 0) return q; } return NULL; }

// 参数切分：[p, e) 顶层逗号
typedef struct { const char *a, *ne, *nb, *at, *e; } wprm;
static int wparams(const char *lp, const char *rp, wprm *o, int cap) {
    int n = 0;
    for (const char *p = lp + 1; p < rp && n < cap;) {
        int dd = 0; const char *e = p;
        for (; e < rp; e++) { if (*e == '(' || *e == '<' || *e == '[') dd++; else if (*e == ')' || *e == '>' || *e == ']') dd--; else if (*e == ',' && dd == 0) break; }
        const char *a = p; while (a < e && *a == ' ') a++;
        const char *at = strstr(a, "[["); if (!at || at > e) at = e;
        const char *ne = at; while (ne > a && ne[-1] == ' ') ne--;
        const char *nb = ne; while (nb > a && (isalnum((unsigned char)nb[-1]) || nb[-1] == '_')) nb--;
        if (nb == ne) return -1;
        o[n++] = (wprm){a, ne, nb, at, e};
        p = e < rp ? e + 1 : rp;
    }
    return n;
}
static int wattr(const wprm *p, const char *at) { return p->at < p->e && !strncmp(p->at, at, strlen(at)); }

// msl：顶点着色器整份 MSL；entry：入口名。返回追加了 s<键>_wl 入口的 MSL，NULL = 不规整（不出宽线入口）
char *gal_wline_msl(const char *msl, const char *entry) {
    char pat[96]; snprintf(pat, sizeof pat, " %s(", entry);
    const char *sig = NULL, *ls = NULL;
    for (const char *q = strstr(msl, pat); q; q = strstr(q + 1, pat)) {
        const char *l = q; while (l > msl && l[-1] != '\n') l--;
        if (!strncmp(l, "vertex ", 7)) { sig = q; ls = l; break; }
    }
    if (!sig) return NULL;
    // 返回类型：「vertex <类型> <入口>(」；输出结构体须有 gl_Position [[position]]
    char ret[128]; size_t rl = (size_t)(sig - (ls + 7)); if (rl == 0 || rl >= sizeof ret) return NULL; memcpy(ret, ls + 7, rl); ret[rl] = 0;
    { char sh[160]; snprintf(sh, sizeof sh, "struct %s\n{\n", ret); const char *st = strstr(msl, sh); if (!st) return NULL; const char *se = strstr(st, "\n};\n"); const char *gp = strstr(st, " gl_Position [[position]]");
      if (!se || !gp || gp > se) return NULL; }
    const char *lp = sig + strlen(pat) - 1, *rp = wclose(lp); if (!rp) return NULL;
    const char *body = strstr(rp, "\n{\n"); if (!body) return NULL; body += 1;
    int d = 0; const char *be = NULL;
    for (const char *q = body; *q; q++) { if (*q == '{') d++; else if (*q == '}' && --d == 0) { be = q; break; } }
    if (!be) return NULL;
    wprm pm[64]; int np = wparams(lp, rp, pm, 64); if (np < 0 || np >= 64) return NULL;
    int pulled = strstr(msl, "S2AVtxAttr* s2a_vt") != NULL, si = -1;
    for (int i = 0; i < np; i++) if (wattr(&pm[i], "[[stage_in]]")) si = i;
    // 自取取数用的名字：主入口已自取 → 沿用其 vertex_id / instance_id / base_instance 与 s2a_vt；否则新入口自己加
    char vid[64] = "s2a_vid", iid[64] = "s2a_iid", bi[64] = "s2a_bi"; int have[3] = {0, 0, 0};
    for (int i = 0; i < np; i++) {
        char *dst = wattr(&pm[i], "[[vertex_id]]") ? vid : wattr(&pm[i], "[[instance_id]]") ? iid : wattr(&pm[i], "[[base_instance]]") ? bi : NULL;
        if (!dst) continue; size_t L = (size_t)(pm[i].ne - pm[i].nb); if (L >= 63) return NULL; memcpy(dst, pm[i].nb, L); dst[L] = 0;
        have[dst == vid ? 0 : dst == iid ? 1 : 2] = 1;
    }
    // stage_in 输入结构体成员（「    T 名 [[attribute(L)]];」）→ 新入口里按自取填
    wsb fill_a = {0}, fill_b = {0}; char inty[96] = "";
    if (si >= 0) {
        if (pulled) return NULL;
        size_t L = (size_t)(pm[si].nb - pm[si].a); while (L && pm[si].a[L - 1] == ' ') L--; if (!L || L >= sizeof inty) return NULL; memcpy(inty, pm[si].a, L); inty[L] = 0;
        char hdr[160]; snprintf(hdr, sizeof hdr, "struct %s\n{\n", inty);
        const char *sb = strstr(msl, hdr); if (!sb) return NULL; const char *se = strstr(sb, "\n};\n"); if (!se) return NULL;
        snprintf(hdr + 0, sizeof hdr, "    %s s2a_ia = {}, s2a_ib = {};\n", inty); wstr(&fill_a, hdr);
        for (const char *ln = sb + strlen("struct ") + strlen(inty) + 3; ln < se;) {
            const char *le = strchr(ln, '\n'); if (!le || le > se) le = se;
            char line[256]; size_t ll = (size_t)(le - ln); if (ll >= sizeof line) { free(fill_a.s); free(fill_b.s); return NULL; } memcpy(line, ln, ll); line[ll] = 0;
            char ty[16], name[64]; int loc;
            if (sscanf(line, " %15s %63s [[attribute(%d)]];", ty, name, &loc) != 3 || loc < 0 || loc >= 32 || strchr(name, '[')) { free(fill_a.s); free(fill_b.s); return NULL; }
            char k = gal_vpull_kind(ty, name); if (!k) { free(fill_a.s); free(fill_b.s); return NULL; }
            char t[256];
            snprintf(t, sizeof t, "    s2a_ia.%s = s2a_v%c(s2a_vt, %d, s2a_e.x, %s, %s);\n", name, k, loc, iid, bi); wstr(&fill_a, t);
            snprintf(t, sizeof t, "    s2a_ib.%s = s2a_v%c(s2a_vt, %d, s2a_e.y, %s, %s);\n", name, k, loc, iid, bi); wstr(&fill_b, t);
            ln = le + 1;
        }
    } else if (!pulled || !have[0]) return NULL;
    // 普通函数（参数去属性）与两次调用的实参：stage_in → 填好的输入、vertex_id → 端点号、base_vertex → 宽线参数里的基顶点
    wsb plain = {0}, call_a = {0}, call_b = {0}, eps = {0};
    for (int i = 0; i < np; i++) {
        const wprm *q = &pm[i];
        if (plain.n) { wstr(&plain, ", "); wstr(&call_a, ", "); wstr(&call_b, ", "); }
        wput(&plain, q->a, (size_t)(q->ne - q->a));
        if (i == si) { wstr(&call_a, "s2a_ia"); wstr(&call_b, "s2a_ib"); continue; }
        if (eps.n) wstr(&eps, ", ");
        wput(&eps, q->a, (size_t)(q->e - q->a));
        if (wattr(q, "[[vertex_id]]")) { wstr(&call_a, "s2a_e.x"); wstr(&call_b, "s2a_e.y"); }
        else if (wattr(q, "[[base_vertex]]")) { wstr(&call_a, "uint(s2a_wl.bv)"); wstr(&call_b, "uint(s2a_wl.bv)"); }
        else { wput(&call_a, q->nb, (size_t)(q->ne - q->nb)); wput(&call_b, q->nb, (size_t)(q->ne - q->nb)); }
    }
    char t[512];
    if (si >= 0) {   // 新入口的自取参数（主入口没有的）
        snprintf(t, sizeof t, "%sconstant S2AVtxAttr* s2a_vt [[buffer(%d)]]%s%s%s", eps.n ? ", " : "", GAL_VPULL_SLOT,
                 have[0] ? "" : ", uint s2a_vid [[vertex_id]]", have[1] ? "" : ", uint s2a_iid [[instance_id]]", have[2] ? "" : ", uint s2a_bi [[base_instance]]");
        wstr(&eps, t);
    }
    // 主入口改成调同一个函数体（源码里函数体只出现一次，前端只编一份；后端内联后与原来一样）
    wsb mc = {0};
    for (int i = 0; i < np; i++) { if (mc.n) wstr(&mc, ", "); wput(&mc, pm[i].nb, (size_t)(pm[i].ne - pm[i].nb)); }
    wsb o = {0};
    wput(&o, msl, (size_t)(ls - msl));
    if (!pulled) { extern const char *nxgal_test_vpull_msl(void); wstr(&o, nxgal_test_vpull_msl()); }
    wstr(&o, k_wline_msl);
    snprintf(t, sizeof t, "static inline %s %s_wlb(", ret, entry); wstr(&o, t); wput(&o, plain.s, plain.n); wstr(&o, ")\n");
    wput(&o, body, (size_t)(be + 1 - body)); wstr(&o, "\n\n");
    wput(&o, ls, (size_t)(body - ls));
    snprintf(t, sizeof t, "{\n    return %s_wlb(", entry); wstr(&o, t); wput(&o, mc.s, mc.n); wstr(&o, ");\n}");
    wstr(&o, be + 1); wstr(&o, "\n");
    free(mc.s);
    snprintf(t, sizeof t, "vertex %s %s_wl(", ret, entry); wstr(&o, t); wput(&o, eps.s, eps.n);
    snprintf(t, sizeof t, "%sconstant S2AWideLine& s2a_wl [[buffer(%d)]])\n{\n", eps.n ? ", " : "", GAL_WLINE_SLOT); wstr(&o, t);
    // 断带的段：端点号换成首个顶点号再取（不拿重启值去取顶点），输出零面积
    snprintf(t, sizeof t, "    uint s2a_seg = %s / 6u, s2a_cor = %s %% 6u;\n    bool s2a_cut = s2a_wl_cut(s2a_wl, s2a_seg);\n    uint2 s2a_e = s2a_cut ? uint2(uint(s2a_wl.bv)) : s2a_wl_ends(s2a_wl, s2a_seg);\n", vid, vid); wstr(&o, t);
    if (fill_a.n) { wput(&o, fill_a.s, fill_a.n); wput(&o, fill_b.s, fill_b.n); }
    snprintf(t, sizeof t, "    %s s2a_a = %s_wlb(", ret, entry); wstr(&o, t); wput(&o, call_a.s, call_a.n); wstr(&o, ");\n");
    snprintf(t, sizeof t, "    %s s2a_b = %s_wlb(", ret, entry); wstr(&o, t); wput(&o, call_b.s, call_b.n); wstr(&o, ");\n");
    wstr(&o, "    return s2a_wl_quad(s2a_a, s2a_b, s2a_cor, s2a_wl, s2a_cut);\n}\n");
    free(plain.s); free(call_a.s); free(call_b.s); free(eps.s); free(fill_a.s); free(fill_b.s);
    return o.s;
}

// Vulkan 层的采样器 LOD 偏置着色器模拟（#800，graphics/metal/gal_samp_caps.h：本机 GPU 实测采样器 lodBias 不生效（M3）或系统早于 26 时）：由 hle_vk.m 包含，纯 C（单测
//   graphics/nvn/tests/t_vk_lbias.c 单独包含它）。离线库不带（同直连 B 库的体积口径，translator/dmsh_red.py 文件头），绘制 / 派发真绑了带偏置的采样器时，宿主把这支的 SPIR-V
//   在设备上重翻（s2a_vk_xlate，与出包工具 vk_shaders.py 同口径）、经这里改写入口函数、现编成这条管线的模拟版（hle_vk.m vk_se_pso / vk_se_cps）。
// 改写（SPIRV-Cross --msl-decoration-binding 的离散绑定形态，入口 vk_<键> 或 vk_<键>_d）：入口函数体里每处 T.sample(S, …)（T 是入口的贴图参数、S 是入口的单个采样器参数
//   sampler S [[sampler(N)]]）加表里的偏置 b = s2a_vkb[N].x，规则同 dmsh_red.py fs_red（Vulkan 规范 16.5.7：采样器偏置隐式 / 显式 LOD 都加，同 M5 上 Metal lodBias 实测）：
//   level(l) → level((l) + b)、bias(x) → bias((x) + b)、gradient → 两个导数 × precise::exp2(b)、没写 LOD → 片元插 bias(b) / 计算插 level(b)（计算只带 min_lod_clamp(m) 的 → level(max(b, m))）；
//   入口参数末尾加 constant float4* s2a_vkb [[buffer(槽)]]。宿主每笔按采样器槽填表：绑的采样器带模拟偏置的填它的偏置，其余 0（零表项的采样与原样逐位相等，t_red.py ③ 同口径实测）。
//   比较采样（sample_compare）、采样器数组、入口外函数里的采样不改：数进 *left，调用方报红一次
#include <stdlib.h>
#include <string.h>

typedef struct { char *p; size_t n, cap; } vlb_str;
static void vlb_put(vlb_str *s, const char *a, size_t n) {
    if (s->n + n + 1 > s->cap) { s->cap = (s->n + n + 1) * 2; s->p = realloc(s->p, s->cap); }
    memcpy(s->p + s->n, a, n); s->n += n; s->p[s->n] = 0;
}
static void vlb_puts(vlb_str *s, const char *a) { vlb_put(s, a, strlen(a)); }
static int vlb_ident(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'; }
// a .. b 去掉两头空白
static void vlb_trim(const char **a, const char **b) { while (*a < *b && (**a == ' ' || **a == '\n')) (*a)++; while (*b > *a && ((*b)[-1] == ' ' || (*b)[-1] == '\n')) (*b)--; }
// 从 p（指在 '(' 之后）起按括号深度切顶层参数，到配对的 ')' 为止：参数起止写进 a / b（最多 n 个），返回参数个数，*end 指在 ')' 上；不配对返回 -1
static int vlb_args(const char *p, const char *lim, const char **a, const char **b, int n, const char **end) {
    int d = 1, k = 0; const char *s = p;
    for (const char *q = p; q < lim; q++) {
        if (*q == '(' || *q == '[') d++;
        else if (*q == ')' || *q == ']') d--;
        if ((*q == ',' && d == 1) || !d) { if (k < n) { a[k] = s; b[k] = q; vlb_trim(&a[k], &b[k]); } k++; s = q + 1; }
        if (!d) { *end = q; return k; }
    }
    return -1;
}
static int vlb_is(const char *a, const char *b, const char *w) { size_t n = strlen(w); return (size_t)(b - a) == n && !memcmp(a, w, n); }
// 参数 / 实参 a..b 是不是「名字(…)」整串、名字在 names 里：是就返回名字序号，inner 指括号里
static int vlb_call(const char *a, const char *b, const char *const *names, int nn, const char **ia, const char **ib) {
    for (int i = 0; i < nn; i++) {
        size_t n = strlen(names[i]);
        if ((size_t)(b - a) > n + 1 && !memcmp(a, names[i], n) && a[n] == '(' && b[-1] == ')') {
            const char *x[1], *y[1], *e; if (vlb_args(a + n + 1, b, x, y, 1, &e) < 0 || e != b - 1) return -1;   // 括号在最后一个字符配上：整串是一次调用
            *ia = a + n + 1; *ib = b - 1; return i;
        }
    }
    return -1;
}
typedef struct { char name[64]; int slot, arr, is_tex; } vlb_par;
// msl 的入口 entry（fragment / kernel）改写：成功返回改写的采样处数（0 = 没有能改的，*out 不动），*out = 新源码（调用方 free）；*left = 没改的采样处数；入口认不出返回 -1
static int vk_lb_rewrite(const char *msl, const char *entry, int slot, char **out, int *left) {
    *left = 0;
    size_t en = strlen(entry); const char *e = NULL;
    for (const char *q = strstr(msl, entry); q; q = strstr(q + 1, entry)) {
        if (q[en] != '(' || q == msl || q[-1] != ' ') continue;
        const char *ls = q; while (ls > msl && ls[-1] != '\n') ls--;
        if (!strncmp(ls, "fragment ", 9) || !strncmp(ls, "kernel ", 7)) { e = q; break; }
    }
    if (!e) return -1;
    const char *ls = e; while (ls > msl && ls[-1] != '\n') ls--;
    int frag = !strncmp(ls, "fragment ", 9);
    enum { MAXP = 64 }; const char *pa[MAXP], *pb[MAXP], *pend;
    int np = vlb_args(e + en + 1, msl + strlen(msl), pa, pb, MAXP, &pend);
    if (np < 0 || np > MAXP || strncmp(pend, ")\n{\n", 4)) return -1;
    vlb_par par[MAXP]; int npar = 0;
    for (int i = 0; i < np; i++) {   // 「类型 名字 [[sampler(N)]]」/「texture…<…> 名字 [[texture(M)]]」
        const char *at = strstr(pa[i], " [[");
        if (!at || at > pb[i]) continue;
        const char *nb = at; while (nb > pa[i] && vlb_ident(nb[-1])) nb--;
        if (nb == at || at - nb >= 63) continue;
        vlb_par *v = &par[npar]; memset(v, 0, sizeof *v); memcpy(v->name, nb, (size_t)(at - nb));
        if (!strncmp(pa[i], "sampler ", 8) && !strncmp(at, " [[sampler(", 11)) { v->slot = atoi(at + 11); npar++; }
        else if ((!strncmp(pa[i], "texture", 7) || !strncmp(pa[i], "depth", 5)) && !strncmp(at, " [[texture(", 11)) {
            v->is_tex = 1; const char *lt = strchr(pa[i], '<'); v->arr = lt && lt - pa[i] >= 6 && !strncmp(lt - 6, "_array", 6); npar++; }
    }
    const char *b0 = pend + 4, *b1 = strstr(b0 - 1, "\n}\n");
    if (!b1) return -1;
    b1++;   // 函数体 b0 .. b1（含最后一行的换行）
    // 入口外的采样：不改，记数
    for (const char *q = strstr(msl, ".sample("); q; q = strstr(q + 1, ".sample(")) if (q < b0 || q >= b1) (*left)++;
    for (const char *q = strstr(msl, ".sample_compare("); q; q = strstr(q + 1, ".sample_compare(")) if (q >= b0 && q < b1) (*left)++;
    // 函数体里的采样，从后往前改（外层坐标里套着的内层先改）：改写结果放进新串 body
    vlb_str body = {0}; vlb_put(&body, b0, (size_t)(b1 - b0));
    int n = 0; static const char *const lodn[] = {"level", "bias", "gradient2d", "gradient3d", "gradientcube", "min_lod_clamp"};
    for (size_t pos = body.n; pos > 0;) {
        char *q = NULL;
        for (size_t k = pos; k-- > 0;) if (!strncmp(body.p + k, ".sample(", 8)) { q = body.p + k; break; }
        if (!q) break;
        pos = (size_t)(q - body.p);
        const char *tn = q; while (tn > body.p && vlb_ident(tn[-1])) tn--;
        int ti = -1; for (int i = 0; i < npar; i++) if (par[i].is_tex && vlb_is(tn, q, par[i].name)) ti = i;
        if (ti < 0) { (*left)++; continue; }   // 贴图不是入口的单个参数（数组元素等）
        enum { MAXA = 8 }; const char *aa[MAXA], *ab[MAXA], *ae;
        int na = vlb_args(q + 8, body.p + body.n, aa, ab, MAXA, &ae);
        int si = -1; if (na > 0) for (int i = 0; i < npar; i++) if (!par[i].is_tex && vlb_is(aa[0], ab[0], par[i].name)) si = i;
        int k = par[ti].arr ? 3 : 2;
        if (na < 0 || na > MAXA || si < 0 || na < k) { (*left)++; continue; }   // 采样器不是单个参数（数组 / 表达式）
        char b[48]; snprintf(b, sizeof b, "s2a_vkb[%d].x", par[si].slot);
        int lj = -1, li = -1, mj = -1; const char *ia = NULL, *ib = NULL, *ma = NULL, *mb = NULL;
        for (int j = k; j < na; j++) { const char *x, *y; int w = vlb_call(aa[j], ab[j], lodn, 6, &x, &y); if (w == 5) { mj = j; ma = x; mb = y; } else if (w >= 0 && lj < 0) { lj = j; li = w; ia = x; ib = y; } }
        vlb_str r = {0}; vlb_put(&r, tn, (size_t)(q - tn)); vlb_puts(&r, ".sample(");
        for (int j = 0; j < na; j++) {
            if (j) vlb_puts(&r, ", ");
            if (j == k && lj < 0 && (frag || mj < 0)) { vlb_puts(&r, frag ? "bias(" : "level("); vlb_puts(&r, b); vlb_puts(&r, "), "); }   // 没写 LOD：在 LOD 位置插入
            if (j == lj && (li == 0 || li == 1)) { vlb_puts(&r, lodn[li]); vlb_puts(&r, "(("); vlb_put(&r, ia, (size_t)(ib - ia)); vlb_puts(&r, ") + "); vlb_puts(&r, b); vlb_puts(&r, ")"); }
            else if (j == lj) {   // gradient：两个导数各乘 2^b
                const char *ga[2], *gb[2], *ge;
                vlb_str g = {0}; vlb_put(&g, ia, (size_t)(ib - ia)); vlb_puts(&g, ")");
                int ng = vlb_args(g.p, g.p + g.n, ga, gb, 2, &ge);
                if (ng != 2) { free(g.p); free(r.p); r.p = NULL; break; }
                vlb_puts(&r, lodn[li]); vlb_puts(&r, "((");
                vlb_put(&r, ga[0], (size_t)(gb[0] - ga[0])); vlb_puts(&r, ") * precise::exp2("); vlb_puts(&r, b); vlb_puts(&r, "), (");
                vlb_put(&r, ga[1], (size_t)(gb[1] - ga[1])); vlb_puts(&r, ") * precise::exp2("); vlb_puts(&r, b); vlb_puts(&r, "))"); free(g.p);
            }
            else if (j == mj && !frag && lj < 0) { vlb_puts(&r, "level(max("); vlb_puts(&r, b); vlb_puts(&r, ", "); vlb_put(&r, ma, (size_t)(mb - ma)); vlb_puts(&r, "))"); }   // 计算只带 min_lod_clamp(m)：level(max(b, m))
            else vlb_put(&r, aa[j], (size_t)(ab[j] - aa[j]));
        }
        if (!r.p) { (*left)++; continue; }
        if (na == k && lj < 0 && (frag || mj < 0)) { vlb_puts(&r, ", "); vlb_puts(&r, frag ? "bias(" : "level("); vlb_puts(&r, b); vlb_puts(&r, ")"); }   // LOD 位置在最后
        vlb_puts(&r, ")");
        size_t s0 = (size_t)(tn - body.p), s1 = (size_t)(ae + 1 - body.p);
        vlb_str nb2 = {0}; vlb_put(&nb2, body.p, s0); vlb_put(&nb2, r.p, r.n); vlb_put(&nb2, body.p + s1, body.n - s1);
        free(r.p); free(body.p); body = nb2; pos = s0; n++;
    }
    if (!n) { free(body.p); return 0; }
    vlb_str o = {0}; char prm[96]; snprintf(prm, sizeof prm, ", constant float4* s2a_vkb [[buffer(%d)]]", slot);
    vlb_put(&o, msl, (size_t)(pend - msl)); vlb_puts(&o, np ? prm : prm + 2); vlb_put(&o, pend, (size_t)(b0 - pend)); vlb_put(&o, body.p, body.n); vlb_puts(&o, b1);
    free(body.p); *out = o.p; return n;
}

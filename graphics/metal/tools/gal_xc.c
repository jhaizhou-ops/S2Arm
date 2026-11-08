// 离线着色器库第一步：SPIR-V 目录 → 每支一个 MSL（<键>.metal）+ 离线索引 gal.idx。翻译走 libnxgal 的 nxgal_prog_xc（与 Mac 运行时现编同一份代码，布局逐字节相同）。
// 用法：gal_xc <SPIR-V 目录（*.spv；*.vt.spv = 曲面前顶点变体）> <输出目录> <平台 0 iOS | 1 macOS>
// 输出：<输出目录>/msl/<键>.metal、<输出目录>/gal.idx、<输出目录>/xc_failed.txt（翻译失败的文件与原因）。按键去重（同内容的 SPIR-V 只出一份）。
// 第二步（并行 xcrun metal → .air → metallib）在 tools/gal_offline.py。
// 子命令 gal_xc --fbr <配对表> <SPIR-V 目录> <输出表> [<变体请求表>]（读帧缓冲证明 + 变体改写，见 fbr_main）。
#include "../gal_abi.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dispatch/dispatch.h>
#include <CommonCrypto/CommonDigest.h>
NXGAL_API const char *nxgal_helper_src(int32_t k, const char **base);   // gal_core.m（内部头 gal_internal.h 里声明，这里 C 端直接声明）

typedef struct { uint64_t hash; void *rec; uint32_t len; } ent;
static int cmp(const void *a, const void *b) { uint64_t x = ((const ent *)a)->hash, y = ((const ent *)b)->hash; return x < y ? -1 : x > y; }
static void *slurp(const char *path, uint32_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    void *b = malloc(n ? n : 1); if (fread(b, 1, n, f) != (size_t)n) { free(b); fclose(f); return NULL; }
    fclose(f); *len = (uint32_t)n; return b;
}
static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
static int scmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

// ---------- gal_xc --fbr（读帧缓冲证明出包，10-22）----------
// gal_xc --fbr <配对表> <SPIR-V 目录> <输出表> [<变体请求表>]
//   配对表：每行「<顶点键> <片元键>」（16 位十六进制，# 开头为注释）——出包程序表里只有顶点 + 片元两段的图形程序（ShaderBake.cs 写）；SPIR-V 取 <目录>/<键>.spv。
//   变体请求表：specpipe 式收集的「读帧缓冲变体缺 v1 <顶点键> <片元键> <ydown> <绑定:槽>…」（graphics/tools/shbake/fbrvars.py → fbr_vars.tsv，每行从 v1 起），不在配对表里的程序跳过。
//   每对跑证明（gal_fbr.m，与运行时建程序同一份）；对每条请求按映射改写片元，先按 iOS 口径带 NXGAL_XC_FBF 试译一遍（译不出的不进表），
//   改写后的 SPIR-V 写成 <目录>/<新键>.fbf.spv（随后 gal_xc 主流程带 NXGAL_XC_FBF 翻进离线库，键 = 改写后 SPIR-V 的键）。
//   输出表：「P <顶点键> <片元键> <尾段十六进制>」每个证得的程序一行（ShaderBake.cs 原样接在程序二进制后，格式见 gal_fbr.m gal_fbr_ser），
//           「V <顶点键> <片元键> <ydown> <变体片元键> <绑定:槽>…」每个变体一行（pso_gen.py 给（顶点, 变体片元）出基础管线）。
typedef struct { uint64_t vs, fs; int nreq; struct { int n, yd; uint8_t b[8], s[8]; } req[64]; void *h; int nv; uint64_t vk[64]; int vi[64]; int bad_map, bad_rw, bad_xc; } fpair;
static uint64_t spv_key(const void *b, uint32_t n) { uint8_t d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(b, n, d); uint64_t k; memcpy(&k, d, 8); return k; }
static int pair_cmp(const void *a, const void *b) {
    const fpair *x = a, *y = b;
    if (x->vs != y->vs) return x->vs < y->vs ? -1 : 1;
    return x->fs < y->fs ? -1 : x->fs > y->fs;
}
static fpair *pair_find(fpair *ps, int n, uint64_t vs, uint64_t fs) {
    fpair k; k.vs = vs; k.fs = fs; return bsearch(&k, ps, n, sizeof *ps, pair_cmp);
}
static int fbr_main(int argc, char **argv) {
    const char *pt = argv[2], *dir = argv[3], *outp = argv[4], *rq = argc > 5 ? argv[5] : NULL;
    FILE *f = fopen(pt, "r"); if (!f) { fprintf(stderr, "【红】读不了配对表 %s\n", pt); return 1; }
    fpair *ps = NULL; int np = 0, cap = 0; char ln[4096];
    while (fgets(ln, sizeof ln, f)) {
        unsigned long long a, b; if (ln[0] == '#' || sscanf(ln, "%llx %llx", &a, &b) != 2) continue;
        if (np == cap) { cap = cap ? cap * 2 : 1024; ps = realloc(ps, cap * sizeof *ps); }
        memset(&ps[np], 0, sizeof *ps); ps[np].vs = a; ps[np].fs = b; np++;
    }
    fclose(f);
    qsort(ps, np, sizeof *ps, pair_cmp);
    int w = 0; for (int i = 0; i < np; i++) if (!w || pair_cmp(&ps[i], &ps[w - 1])) ps[w++] = ps[i];
    np = w;
    int nreq = 0, req_out = 0, req_dup = 0, req_over = 0;
    if (rq && (f = fopen(rq, "r"))) {
        while (fgets(ln, sizeof ln, f)) {
            char *v = strstr(ln, "v1 "); if (ln[0] == '#' || !v) continue;
            unsigned long long a, b; int yd, off = 0;
            if (sscanf(v, "v1 %llx %llx %d%n", &a, &b, &yd, &off) != 3 || (yd != 0 && yd != 1)) continue;
            int n = 0, k; unsigned bb, ss; uint8_t B[8], S[8]; char *p = v + off;
            while (n < 8 && sscanf(p, " %u:%u%n", &bb, &ss, &k) == 2 && bb < 256 && ss < 8) { B[n] = (uint8_t)bb; S[n] = (uint8_t)ss; n++; p += k; }
            if (!n) continue;
            nreq++;
            fpair *P = pair_find(ps, np, a, b); if (!P) { req_out++; continue; }
            int dup = 0;
            for (int i = 0; i < P->nreq && !dup; i++) dup = P->req[i].n == n && P->req[i].yd == yd && !memcmp(P->req[i].b, B, n) && !memcmp(P->req[i].s, S, n);
            if (dup) { req_dup++; continue; }
            if (P->nreq == 64) { req_over++; continue; }
            P->req[P->nreq].n = n; P->req[P->nreq].yd = yd; memcpy(P->req[P->nreq].b, B, n); memcpy(P->req[P->nreq].s, S, n); P->nreq++;
        }
        fclose(f);
    } else if (rq) { fprintf(stderr, "【红】读不了变体请求表 %s\n", rq); return 1; }
    // 离线库 = 出包口径：越界 / 循环计数关（同主流程）
    setenv("NXGAL_BOUNDS_COUNT", "0", 1);
    __block int nmiss = 0;
    dispatch_apply((size_t)np, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        fpair *P = &ps[i]; char pp[4096]; uint32_t vl, fl;
        snprintf(pp, sizeof pp, "%s/%016llx.spv", dir, (unsigned long long)P->vs); void *v = slurp(pp, &vl);
        snprintf(pp, sizeof pp, "%s/%016llx.spv", dir, (unsigned long long)P->fs); void *fs = v ? slurp(pp, &fl) : NULL;
        if (!v || !fs) { free(v); free(fs); __atomic_fetch_add(&nmiss, 1, __ATOMIC_RELAXED); return; }
        P->h = nxgal_fbr_prove_spv(v, vl, fs, fl); free(v); free(fs);
        for (int r = 0; P->h && r < P->nreq; r++) {
            uint32_t len = 0; void *o = nxgal_fbr_rewrite_spv(P->h, P->req[r].n, P->req[r].yd, P->req[r].b, P->req[r].s, &len);
            if (!o) { P->bad_map++; continue; }
            char *msl = NULL, err[256]; void *rec = NULL; uint32_t rl = 0; uint64_t h = 0;
            if (!nxgal_prog_xc_mt(o, len, 0 | NXGAL_XC_FBF, &msl, &rec, &rl, &h, err)) { P->bad_xc++; fprintf(stderr, "【红】gal_xc --fbr：%016llx 变体试译失败：%s\n", (unsigned long long)P->fs, err); free(o); continue; }
            free(msl); free(rec);
            uint64_t k = spv_key(o, len);
            if (k != h || !nxgal_fbr_add_variant(P->h, P->req[r].n, P->req[r].yd, P->req[r].b, P->req[r].s, k)) { P->bad_rw++; free(o); continue; }
            snprintf(pp, sizeof pp, "%s/%016llx.fbf.spv", dir, (unsigned long long)k);
            char tmp[4200]; snprintf(tmp, sizeof tmp, "%s.%zu.tmp", pp, i);
            FILE *of = fopen(tmp, "wb"); if (of) { fwrite(o, 1, len, of); fclose(of); rename(tmp, pp); }
            P->vk[P->nv] = k; P->vi[P->nv] = r; P->nv++;
            free(o);
        }
    });
    FILE *o = fopen(outp, "w"); if (!o) { fprintf(stderr, "【红】写不了 %s\n", outp); return 1; }
    fprintf(o, "# 读帧缓冲证明表（gal_xc --fbr）：P <顶点键> <片元键> <尾段十六进制>（ShaderBake.cs 接在程序二进制后）；V <顶点键> <片元键> <ydown> <变体片元键> <绑定:槽>…（pso_gen.py 出基础管线）\n");
    int nok = 0, nv = 0, bm = 0, br = 0, bx = 0;
    for (int i = 0; i < np; i++) {
        fpair *P = &ps[i]; bm += P->bad_map; br += P->bad_rw; bx += P->bad_xc;
        if (!P->h) continue;
        nok++;
        int32_t tl = nxgal_fbr_trailer(P->h, NULL); uint8_t *t = malloc(tl > 0 ? tl : 1); nxgal_fbr_trailer(P->h, t);
        fprintf(o, "P\t%016llx\t%016llx\t", (unsigned long long)P->vs, (unsigned long long)P->fs);
        for (int k = 0; k < tl; k++) fprintf(o, "%02x", t[k]);
        fputc('\n', o); free(t);
        for (int k = 0; k < P->nv; k++) {
            int r = P->vi[k]; uint8_t b[8], s[8]; int n = P->req[r].n;
            memcpy(b, P->req[r].b, n); memcpy(s, P->req[r].s, n);
            fprintf(o, "V\t%016llx\t%016llx\t%d\t%016llx\t", (unsigned long long)P->vs, (unsigned long long)P->fs, P->req[r].yd, (unsigned long long)P->vk[k]);
            for (int j = 0; j < n; j++) fprintf(o, "%s%u:%u", j ? " " : "", b[j], s[j]);
            fputc('\n', o); nv++;
        }
        nxgal_fbr_release(P->h);
    }
    fclose(o); free(ps);
    printf("gal_xc --fbr：配对 %d（缺 SPIR-V %d），证得 %d；变体请求 %d（程序不在本包 %d、重复 %d、超量 %d、映射不在证明里 %d、试译失败 %d、改写不符 %d），变体 %d\n",
           np, nmiss, nok, nreq, req_out, req_dup, req_over, bm, bx, br, nv);
    return bx || br ? 1 : 0;
}

int main(int argc, char **argv) {
    if ((argc == 5 || argc == 6) && !strcmp(argv[1], "--fbr")) return fbr_main(argc, argv);
    // 内部辅助库离线化（10-23）：gal_xc --helpers <输出目录>：渲染器内部辅助库的 MSL 写成 <目录>/gal_helper_<键>.<源码哈希>.metal（Makefile / 出包再 xcrun metal -std=metal4.0 编成同名 .metallib）
    if (argc == 3 && !strcmp(argv[1], "--helpers")) {
        mkdir(argv[2], 0755); int n = 0;
        for (int32_t k = 0;; k++) {
            const char *base = NULL, *src = nxgal_helper_src(k, &base); if (!src) break;
            char p[4096]; snprintf(p, sizeof p, "%s/%s.metal", argv[2], base);
            FILE *f = fopen(p, "w"); if (!f) { fprintf(stderr, "【红】写不了 %s\n", p); return 1; }
            fputs(src, f); fclose(f); n++;
        }
        printf("helpers 写出 %d 个\n", n);
        return n ? 0 : 1;
    }
    if (argc != 4) { fprintf(stderr, "用法：gal_xc <SPIR-V 目录> <输出目录> <0 iOS | 1 macOS> | gal_xc --fbr <配对表> <SPIR-V 目录> <输出表> [<变体请求表>]\n"); return 2; }
    // 离线库 = 出包口径：越界 / 循环计数一律关（翻译期开关，gal_spvx.m），不受调用方环境影响
    setenv("NXGAL_BOUNDS_COUNT", "0", 1);
    const char *in = argv[1], *out = argv[2]; int plat = atoi(argv[3]);
    char p[4096]; mkdir(out, 0755); snprintf(p, sizeof p, "%s/msl", out); mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/xc_failed.txt", out); FILE *ff = fopen(p, "w");
    DIR *d = opendir(in); if (!d) { fprintf(stderr, "【红】打不开 %s\n", in); return 1; }
    // 文件名先全列出来、排序（产物与目录遍历顺序无关），再并行翻译（GAL_XC_J，缺省 = 核数；1 = 串行，对拍用），按排序后的顺序串行写盘 / 去重
    char **fn = NULL; int nf = 0, fcap = 0; struct dirent *de;
    while ((de = readdir(d))) {
        size_t L = strlen(de->d_name); if (L < 5 || strcmp(de->d_name + L - 4, ".spv")) continue;
        if (nf == fcap) { fcap = fcap ? fcap * 2 : 1024; fn = realloc(fn, fcap * sizeof *fn); }
        fn[nf++] = strdup(de->d_name);
    }
    closedir(d);
    qsort(fn, nf, sizeof *fn, scmp);
    typedef struct { char *msl; void *rec; uint32_t rl; uint64_t h; int ok; char err[256]; } res_t;
    res_t *rs = calloc(nf ? nf : 1, sizeof *rs);
    const char *jv = getenv("GAL_XC_J"); long J = jv ? atol(jv) : 0;
    void (^one)(size_t) = ^(size_t k) {
        char pp[4096]; snprintf(pp, sizeof pp, "%s/%s", in, fn[k]); uint32_t len; void *spv = slurp(pp, &len);
        if (!spv) { snprintf(rs[k].err, sizeof rs[k].err, "读不了"); return; }
        size_t fl = strlen(fn[k]); int vt = fl > 7 && !strcmp(fn[k] + fl - 7, ".vt.spv");   // <键>.vt.spv：曲面程序里的顶点着色器，出「曲面前顶点计算核」变体（键 ^ NXGAL_VT_SALT）
        // <键>.fbf.spv：读帧缓冲变体片元（gal_xc --fbr 改写出的），带 NXGAL_XC_FBF 翻译（SubpassData 输入附件 → [[color(n)]]）
        int fbf = fl > 8 && !strcmp(fn[k] + fl - 8, ".fbf.spv");
        rs[k].ok = nxgal_prog_xc_mt(spv, len, plat | (vt ? NXGAL_XC_VT : 0) | (fbf ? NXGAL_XC_FBF : 0), &rs[k].msl, &rs[k].rec, &rs[k].rl, &rs[k].h, rs[k].err); free(spv);
    };
    if (J == 1) for (int k = 0; k < nf; k++) one((size_t)k);
    else dispatch_apply((size_t)nf, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), one);
    ent *es = NULL; int n = 0, cap = 0, nfile = nf, nfail = 0, ndup = 0;
    uint64_t *seen = calloc(1u << 20, sizeof *seen); // 去重：开放寻址哈希集（键 0 当空槽，键 0 极不可能）
    for (int k = 0; k < nf; k++) {
        if (!rs[k].ok) { nfail++; fprintf(ff, "%s\t%s\n", fn[k], rs[k].err); free(fn[k]); continue; }
        uint64_t h = rs[k].h; char *msl = rs[k].msl; void *rec = rs[k].rec; uint32_t rl = rs[k].rl;
        uint32_t slot = (uint32_t)(h * 0x9e3779b97f4a7c15ull >> 44); int dup = 0;
        while (seen[slot]) { if (seen[slot] == h) { dup = 1; break; } slot = (slot + 1) & ((1u << 20) - 1); }
        free(fn[k]);
        if (dup) { ndup++; free(msl); free(rec); continue; }
        seen[slot] = h;
        // 主份与无点大小变体是两个编译单元（各带一份辅助函数定义）：拆成 <键>.metal 与 <键>_np.metal，gal_offline 各编成 .air 再链进同一个 metallib
        char *np = strstr(msl, "\n//@@GAL_MSL_NP@@\n"); if (np) { *np = 0; np += strlen("\n//@@GAL_MSL_NP@@\n"); }
        snprintf(p, sizeof p, "%s/msl/%016llx.metal", out, (unsigned long long)h);
        FILE *mf = fopen(p, "w"); fputs(msl, mf); fclose(mf);
        if (np) { snprintf(p, sizeof p, "%s/msl/%016llx_np.metal", out, (unsigned long long)h); mf = fopen(p, "w"); fputs(np, mf); fclose(mf); }
        free(msl);
        if (n == cap) { cap = cap ? cap * 2 : 256; es = realloc(es, cap * sizeof *es); }
        es[n++] = (ent){h, rec, rl};
    }
    free(rs); free(fn); free(seen);
    fclose(ff);
    qsort(es, n, sizeof *es, cmp);
    snprintf(p, sizeof p, "%s/gal.idx", out); FILE *f = fopen(p, "wb");
    put32(f, 0x494c4147u); put32(f, 1); put32(f, NXGAL_XC_VERSION); put32(f, (uint32_t)plat); put32(f, (uint32_t)n); put32(f, 0);
    uint32_t off = 24 + 16 * (uint32_t)n;
    for (int i = 0; i < n; i++) { fwrite(&es[i].hash, 8, 1, f); put32(f, off); put32(f, es[i].len); off += es[i].len; }
    for (int i = 0; i < n; i++) { fwrite(es[i].rec, 1, es[i].len, f); free(es[i].rec); }
    fclose(f);
    printf("gal_xc：SPIR-V %d 支，翻译失败 %d，重复 %d，入索引 %d\n", nfile, nfail, ndup, n);
    return 0;
}

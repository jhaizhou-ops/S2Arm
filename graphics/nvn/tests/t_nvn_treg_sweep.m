// 贴图登记表按序号反查（nvn_mtl.m g_treg_ser / treg_sweep_gone / alias_dead_views）：被删贴图的编号视图只按它的序号找，不再整表扫。
// 背景：11-07 E1 真机，时之笛约 33,000 个编号，每次提交（只要上次以来删过贴图）整表扫一遍，占提交 CPU 11%（约 2.5 ms/帧）、金刚 39%。
// 期望（按改前的语义手写，不由被测实现推出）：
//   ① 清扫后被丢视图的编号集合 = 改前全表扫的答案：已登记（ok）且有视图、序号在删除列表里的编号；其余编号的视图指针原样不动。
//      覆盖：同一贴图登记在多个编号、编号改登记成别的贴图（旧序号删了不碰它）、编号被区间注销后再登记、删除列表里有没人登记的序号、重复序号
//   ② 每次清扫看的编号数 = 登记了被删序号的编号数，与表大小无关：表 1,000 和 40,000 两档读数相同（计数，不计时）
//   ③ 被覆写放掉的贴图（alias_dead_views）同样按序号找：丢视图的集合 = 全表扫答案，看的编号数与表大小无关
//   负对照 neg：登记后把反查表清空（等于删除时没记进待处理 / 登记时没挂链），①③ 必须红——证明本测真的在查反查表
// 跑法：t_nvn_treg_sweep（正常，全绿退出 0）| t_nvn_treg_sweep neg（负对照，必须出现 FAIL，出现则退出 0）
// 需要 GPU 吗：不需要。视图用普通对象占位（清扫只 CFRelease / 延后释放它们），不建 MTLTexture。
#include "../gfx/nvn/nvn_mtl.m"
#include "s2a_t_result.h"

static unsigned checks, failures; static int g_neg;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static void *obj(void) { return (void *)CFBridgingRetain([NSObject new]); }
static tex_t mk(uint64_t ser) { tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T', 'E', 'X', 0); t.serial = ser; t.d.width = t.d.height = 4; return t; }
static int has_views(const treg_t *r) { return r->view || r->alt || r->ar || r->im; }
static int in(uint64_t s, const uint64_t *set, int n) { for (int k = 0; k < n; k++) if (set[k] == s) return 1; return 0; }

// 表大小 n 的一局：返回本局清扫看的编号数（②）
static uint64_t run(int n, int alias) {
    enum { SER0 = 1000000 };
    // 清干净上一局：区间注销全部（也走一遍解链），再从空表开始
    if (g_ntreg) nvn_be_unreg_tex_range(0, g_ntreg);
    pthread_mutex_lock(&g_rmu); REQUIRE(g_neg || g_treg_ser.n == 0); pthread_mutex_unlock(&g_rmu);
    uint64_t S_shared = SER0 + 900000, X = SER0 + 900001, Y = SER0 + 900002, Z = SER0 + 900003, W = SER0 + 900004, NOBODY = SER0 + 900005;
    for (int i = 1; i < n; i++) { tex_t t = mk(SER0 + (uint64_t)i); nvn_be_reg_tex(i, &t, NULL); }
    tex_t ts = mk(S_shared), tx = mk(X), ty = mk(Y), tz = mk(Z), tw = mk(W);
    nvn_be_reg_tex(10, &ts, NULL); nvn_be_reg_tex(20, &ts, NULL); nvn_be_reg_tex(n - 1, &ts, NULL);   // 同一贴图登记在三个编号（含表尾）
    nvn_be_reg_tex(40, &tx, NULL); nvn_be_reg_tex(41, &tx, NULL); nvn_be_reg_tex(40, &ty, NULL);       // 40 改登记成 Y：删 X 只碰 41
    nvn_be_reg_tex(50, &tz, NULL); nvn_be_unreg_tex_range(50, 1); nvn_be_reg_tex(50, &tw, NULL);        // 50 注销后再登记成 W：删 Z 不碰它
    nvn_be_reg_tex(60, &tz, NULL); nvn_be_reg_tex(60, &tz, NULL);                                        // 同样内容重复登记：链上只一份
    // 视图：每 7 个编号一个，外加所有特殊编号（四种视图字段都覆盖到）
    pthread_mutex_lock(&g_rmu);
    for (int i = 1; i < n; i++) if (!(i % 7) || i == 10 || i == 20 || i == n - 1 || i == 40 || i == 41 || i == 50 || i == 60 || i == 77) {
        treg_t *r = &g_treg[i];
        switch (i % 4) { case 0: r->view = obj(); break; case 1: r->alt = obj(); break; case 2: r->ar = obj(); break; default: r->im = obj(); r->view = obj(); }
    }
    if (g_neg) nvn_hm_clear(&g_treg_ser, NULL);   // 负对照：反查表丢了（删除 / 登记时没记）
    // 被删序号：共享的、ID 77 的、X、Z、没人登记的、再重复一次 77 的
    uint64_t gone[] = {S_shared, SER0 + 77, X, Z, NOBODY, SER0 + 77}; int ng = (int)(sizeof gone / sizeof *gone);
    // 期望：改前全表扫的答案（测试自己扫，不用被测的反查表）
    void **before = calloc((size_t)n * 4, sizeof *before); uint8_t *want = calloc((size_t)n, 1); uint64_t want_n = 0, owners = 0; REQUIRE(before && want);
    for (int i = 0; i < n; i++) { treg_t *r = &g_treg[i]; before[4 * i] = r->view; before[4 * i + 1] = r->alt; before[4 * i + 2] = r->ar; before[4 * i + 3] = r->im;
        if (r->ok && in(r->t.serial, gone, ng)) { owners++; if (has_views(r)) { want[i] = 1; want_n++; } } }
    pthread_mutex_unlock(&g_rmu);
    uint64_t w0 = g_treg_ser_walk;
    if (!alias) { for (int k = 0; k < ng; k++) mtl_vc_drop(gone[k]); treg_sweep_gone(); }   // 删除时记进待处理，提交开头清扫
    else { pthread_mutex_lock(&g_smu); for (int k = 0; k < ng; k++) { if (g_alias_dead_n == g_alias_dead_cap) { g_alias_dead_cap = g_alias_dead_cap ? 2 * g_alias_dead_cap : 64; g_alias_dead_ser = realloc(g_alias_dead_ser, g_alias_dead_cap * sizeof *g_alias_dead_ser); REQUIRE(g_alias_dead_ser); }
                                                             g_alias_dead_ser[g_alias_dead_n++] = gone[k]; } pthread_mutex_unlock(&g_smu);
           alias_dead_views(); }
    uint64_t walked = g_treg_ser_walk - w0;
    pthread_mutex_lock(&g_rmu);
    uint64_t dropped = 0, wrong_drop = 0, kept_wrong = 0;
    for (int i = 0; i < n; i++) { treg_t *r = &g_treg[i];
        int same = r->view == before[4 * i] && r->alt == before[4 * i + 1] && r->ar == before[4 * i + 2] && r->im == before[4 * i + 3];
        if (want[i]) { if (has_views(r)) kept_wrong++; else dropped++; }
        else if (!same) wrong_drop++; }
    int sh_ok = !has_views(&g_treg[10]) && !has_views(&g_treg[20]) && !has_views(&g_treg[n - 1]) && !has_views(&g_treg[41]) && has_views(&g_treg[40]) && has_views(&g_treg[50]) && !has_views(&g_treg[60]);
    pthread_mutex_unlock(&g_rmu);
    const char *what = alias ? "③ 覆写放掉" : "① 删除清扫";
    CHECK(dropped == want_n && !kept_wrong && !wrong_drop && sh_ok, "%s 表 %d：丢视图 %llu 个（期望 %llu = 全表扫答案）、该丢没丢 %llu、不该丢丢了 %llu、特殊编号（共享三处 / 改登记 / 注销再登记 / 重复登记）%s",
          what, n, (unsigned long long)dropped, (unsigned long long)want_n, (unsigned long long)kept_wrong, (unsigned long long)wrong_drop, sh_ok ? "对" : "错");
    CHECK(walked == owners + (in(SER0 + 77, gone, ng) ? 1 : 0), "%s 表 %d：看了 %llu 个编号（期望 %llu：登记了被删序号的编号数，重复序号多看一遍）", what, n,
          (unsigned long long)walked, (unsigned long long)(owners + 1));
    free(before); free(want);
    return walked;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        g_neg = argc > 1 && !strcmp(argv[1], "neg");
        for (int alias = 0; alias < 2; alias++) {
            uint64_t small = run(1000, alias), big = run(40000, alias);
            CHECK(small == big && small > 0 && small < 16, "%s 每次看的编号数与表大小无关：表 1,000 → %llu、表 40,000 → %llu", alias ? "③" : "②",
                  (unsigned long long)small, (unsigned long long)big);
        }
        if (g_neg) { printf(failures ? "✓ t_nvn_treg_sweep neg：反查表清空后 %u/%u 项红 → 负对照成立\n" : "✗ t_nvn_treg_sweep neg：反查表清空后仍全绿，本测没有查到反查表\n", failures, checks); return failures ? 0 : 1; }
        return S2A_T_RESULT("t_nvn_treg_sweep", failures);
    }
}

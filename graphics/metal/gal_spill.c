// 计算着色器共享内存溢出改写（翻译期，MSL 文本）。纯 C、不引 Metal 头（#783）：Mac / iOS 经 gal_spill.m 的 #include 编进 libnxgal
//   （gal_*.m 通配与出包翻译键 xc_key.sh 不用改），Linux / Windows 出包机与 gal_colorround.c / gal_spvx.c 一起编成小库（Makefile 的 linux 目标），
//   S2A.Dsh 的 NxgalSpvCross.SpillFix 照旧 DllImport("nxgal")。代码从 gal_prog.m 原样搬来；上限改由 gal_spill_limit() 取（见 gal_spill.h）。
#include "gal_spill.h"
#include "gal_abi.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef GAL_SPILL_STANDALONE
// 单独成库（Linux / Windows 出包机）：没有设备，同离线出库取目标设备常量；Mac / iOS 的 libnxgal 由 gal_prog.m 提供（运行时按 MTLDevice 查询）
uint32_t gal_spill_limit(void) { return GAL_TG_MEM_MAX; }
#endif

// 计算着色器共享内存溢出（10-20）：Switch 计算着色器最多 48 KB 共享内存，Apple GPU 只有 GAL_TG_MEM_MAX（32 KB）。怪猎捏人页脸部那支要 37 KB，
// 原先 Ryujinx 照后端上限截成 32 KB、越界写被丢（越界计数 1463 万次）→ 脸上错位面。做法：kernel 体内 SPIRV-Cross 出的
// 「threadgroup spvUnsafeArray<T, N> 名;」总量超限时，从最大的起整段改成指向溢出缓冲的 device 引用（每线程组一段，按线程组线性号取），
// 这些数组的 threadgroup 原子转型改 device，threadgroup_barrier 一律带上 mem_device（组内可见靠它），入口加溢出缓冲 [[buffer(GAL_SPILL_SLOT)]]。
// 返回：NULL = 没超限（原样）；(char *)-1 = 结构不认识（写 why，调用方按翻译失败处理，不静默截断）；否则新 MSL，*bytes = 每线程组溢出字节。
typedef struct { size_t at, len; char ty[24]; uint32_t n, esz, off; char name[32]; int spill; } spill_arr;
typedef struct { size_t at, len; char *txt; } spill_edit;
static int spill_edit_cmp(const void *a, const void *b) { size_t x = ((const spill_edit *)a)->at, y = ((const spill_edit *)b)->at; return x < y ? -1 : x > y; }
static uint32_t spill_esz(const char *t) {
    static const struct { const char *t; uint32_t z; } k[] = { {"uint", 4}, {"int", 4}, {"float", 4}, {"uint2", 8}, {"int2", 8}, {"float2", 8},
        {"uint4", 16}, {"int4", 16}, {"float4", 16}, {"ushort", 2}, {"short", 2}, {"half", 2}, {"uchar", 1}, {"char", 1} };
    for (size_t i = 0; i < sizeof k / sizeof *k; i++) if (!strcmp(t, k[i].t)) return k[i].z;
    return 0;
}
char *gal_spill_msl(const char *src, uint32_t slot, uint32_t *bytes, char *why) {
    *bytes = 0;
    const char *kv = strstr(src, "kernel void "); if (!kv) return NULL;
    const char *body = strchr(kv, '{'); if (!body) return NULL;
    spill_arr a[16]; int na = 0; uint64_t total = 0; int other = 0;
    for (const char *q = strstr(kv, "threadgroup"); q; q = strstr(q + 11, "threadgroup")) {
        if ((q > src && (isalnum((unsigned char)q[-1]) || q[-1] == '_')) || q[11] != ' ') continue;   // 只认独立的 threadgroup 修饰词（mem_threadgroup / threadgroup_barrier / [[thread_position_in_threadgroup]] 等不算）
        if (q > src && q[-1] == '(' && !strncmp(q, "threadgroup atomic_", 19)) continue;   // 原子转型，后面按名字改
        if (strncmp(q, "threadgroup spvUnsafeArray<", 27)) { other++; continue; }
        if (na == 16) { snprintf(why, 256, "共享数组超过 16 个"); return (char *)-1; }
        spill_arr *x = &a[na]; memset(x, 0, sizeof *x); const char *t = q + 27;
        if (sscanf(t, "%23[a-z0-9], %u> %31[A-Za-z0-9_];", x->ty, &x->n, x->name) != 3 || !(x->esz = spill_esz(x->ty))) { snprintf(why, 256, "共享数组声明不认识：%.60s", q); return (char *)-1; }
        const char *e = strchr(t, ';'); x->at = (size_t)(q - src); x->len = (size_t)(e + 1 - q);
        total += ((uint64_t)x->n * x->esz + 15) & ~15ull; na++;
    }
    // 上限：运行时按 MTLDevice 当场查询；离线出库（gal_xc 不建设备）按目标设备常量 GAL_TG_MEM_MAX（iPhone / Apple 芯片 Mac 同为 32 KB）
    uint32_t lim = gal_spill_limit();
    if (total <= lim) return NULL;
    if (other) { snprintf(why, 256, "共享内存 %llu 字节超限，但有 %d 处非 spvUnsafeArray 的 threadgroup 声明，改不了", (unsigned long long)total, other); return (char *)-1; }
    uint64_t left = total; uint32_t stride = 0;
    while (left > lim) {   // 从最大的起溢出
        int big = -1; for (int i = 0; i < na; i++) if (!a[i].spill && (big < 0 || a[i].n * a[i].esz > a[big].n * a[big].esz)) big = i;
        if (big < 0) break;
        uint32_t sz = (a[big].n * a[big].esz + 15) & ~15u;
        a[big].spill = 1; a[big].off = stride; stride += sz; left -= sz;
    }
    // 辅助函数以引用收共享数组（kernel 之前的签名里出现同类型 threadgroup 引用）：这一版不改写，按改不了处理
    for (int i = 0; i < na; i++) if (a[i].spill) {
        char sig[64]; snprintf(sig, sizeof sig, "threadgroup spvUnsafeArray<%s, %u>&", a[i].ty, a[i].n);
        if (strstr(src, sig)) { snprintf(why, 256, "溢出的共享数组 %s 被辅助函数以引用传入，这一版不支持", a[i].name); return (char *)-1; }
    }
    // 入口参数：线程组号 / 线程组数借已有的同属性参数，没有就加
    const char *pe = body; while (pe > kv && *pe != ')') pe--;
    char tg[40] = "s2a_tg", tgn[40] = "s2a_tgn", extra[256] = "";
    const char *h = strstr(kv, "[[threadgroup_position_in_grid]]");
    if (h && h < pe) { const char *b0 = h; while (b0 > kv && b0[-1] == ' ') b0--; const char *n0 = b0; while (n0 > kv && (isalnum((unsigned char)n0[-1]) || n0[-1] == '_')) n0--; snprintf(tg, sizeof tg, "%.*s", (int)(b0 - n0), n0); }
    else strcat(extra, ", uint3 s2a_tg [[threadgroup_position_in_grid]]");
    h = strstr(kv, "[[threadgroups_per_grid]]");
    if (h && h < pe) { const char *b0 = h; while (b0 > kv && b0[-1] == ' ') b0--; const char *n0 = b0; while (n0 > kv && (isalnum((unsigned char)n0[-1]) || n0[-1] == '_')) n0--; snprintf(tgn, sizeof tgn, "%.*s", (int)(b0 - n0), n0); }
    else strcat(extra, ", uint3 s2a_tgn [[threadgroups_per_grid]]");
    size_t cap = 64; spill_edit *ed = calloc(cap, sizeof *ed); int ne = 0;
#define SPILL_ADD(AT, LEN, ...) do { if (ne == (int)cap) { cap *= 2; ed = realloc(ed, cap * sizeof *ed); } char *t_; if (asprintf(&t_, __VA_ARGS__) < 0) t_ = NULL; ed[ne++] = (spill_edit){(AT), (LEN), t_}; } while (0)
    SPILL_ADD((size_t)(pe - src), 0, ", device uchar* s2a_spill [[buffer(%u)]]%s", slot, extra);
    SPILL_ADD((size_t)(body + 1 - src), 0, "\n    ulong s2a_spill_base = (ulong(%s.z * %s.y + %s.y) * ulong(%s.x) + ulong(%s.x)) * %uul;", tg, tgn, tg, tgn, tg, stride);
    for (int i = 0; i < na; i++) if (a[i].spill)
        SPILL_ADD(a[i].at, a[i].len, "device spvUnsafeArray<%s, %u>& %s = *reinterpret_cast<device spvUnsafeArray<%s, %u>*>(s2a_spill + s2a_spill_base + %uul);",
                  a[i].ty, a[i].n, a[i].name, a[i].ty, a[i].n, a[i].off);
    for (const char *q = strstr(kv, "(threadgroup atomic_"); q; q = strstr(q + 1, "(threadgroup atomic_")) {
        const char *amp = strstr(q, "*)&"); if (!amp) continue;
        for (int i = 0; i < na; i++) if (a[i].spill) {
            size_t L = strlen(a[i].name);
            if (!strncmp(amp + 3, a[i].name, L) && amp[3 + L] == '[') { SPILL_ADD((size_t)(q + 1 - src), 11, "device"); break; }
        }
    }
    // 屏障：整份 MSL 都扫（辅助函数里的屏障也要管到溢出段），组内屏障与子群屏障（SPIRV-Cross 对子群范围的 OpMemoryBarrier 出 simdgroup_barrier）都带上 mem_device
    static const char *const bar[2] = {"threadgroup_barrier(", "simdgroup_barrier("};
    for (int b = 0; b < 2; b++) for (const char *q = strstr(src, bar[b]); q; q = strstr(q + 1, bar[b])) {
        if (q > src && (isalnum((unsigned char)q[-1]) || q[-1] == '_')) continue;
        size_t L = strlen(bar[b]); const char *e = strchr(q, ')'); if (!e) continue;
        if (!memmem(q, (size_t)(e - q), "mem_device", 10)) SPILL_ADD((size_t)(q + L - src), 0, "mem_flags::mem_device | ");
    }
#undef SPILL_ADD
    qsort(ed, (size_t)ne, sizeof *ed, spill_edit_cmp);
    size_t n = strlen(src), outn = n + 1; for (int i = 0; i < ne; i++) outn += ed[i].txt ? strlen(ed[i].txt) : 0;
    char *out = malloc(outn), *o = out; size_t at = 0;
    for (int i = 0; i < ne; i++) {
        memcpy(o, src + at, ed[i].at - at); o += ed[i].at - at;
        if (ed[i].txt) { size_t L = strlen(ed[i].txt); memcpy(o, ed[i].txt, L); o += L; free(ed[i].txt); }
        at = ed[i].at + ed[i].len;
    }
    memcpy(o, src + at, n - at); o += n - at; *o = 0; free(ed);
    *bytes = stride;
    return out;
}
// 直连离线链（translator/dmsh_build.py spill_fix）用同一份改写：slot = 溢出缓冲的 Metal 槽号（直连计算阶段只用 0 号参数缓冲，也取 27）。
//   返回 0 = 没超限（*out = NULL）、1 = 改写了（*out 用 nxgal_dmsh_xc_free 释放，*bytes = 每线程组溢出字节）、-1 = 结构不认识（err 写原因，调用方按翻译失败处理）
NXGAL_API int32_t nxgal_dmsh_spill(const char *src, uint32_t slot, char **out, uint32_t *bytes, char *err, uint64_t errlen) {
    char why[256] = ""; *out = NULL; *bytes = 0;
    char *sp = gal_spill_msl(src, slot, bytes, why);
    if (sp == (char *)-1) { snprintf(err, errlen, "%s", why); *bytes = 0; return -1; }
    if (!sp) return 0;
    *out = sp; return 1;
}

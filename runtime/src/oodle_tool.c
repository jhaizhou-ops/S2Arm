// 宿主工具模式：用游戏自带的解码器（main 里静态链接的 OodleLZ_Decompress，或 LZ5_decompress_safe）给出包期的着色器工具解压。
// 取自上游 参考实现（MIT，© seedds）dm/host/hle_oodle.c，按 S2Arm 原生层的 module_t / 装载器接口移植；协议与环境变量名原样保留，工具侧
//   （translator/uepak.py OodleHost、shader_split.py oodle()、pack/ue_pak.py、graphics/tools/shbake/nxsh_extract.py）按同一协议对接。
// 为什么要它：UE 游戏的着色器代码存档每支按 Oodle 压缩（Mermaid / Kraken 块头 8C xx），PlatinumGames 的 PKZ 成员是 OodleKraken，Oodle 解码器不开源、
//   不能随仓库分发；游戏 main 里就有一份，出包在 Mac 上装好模块后直接调它（不起 C#、不起图形、不进 nnMain）。
// 两种模式（都在游戏主线程上、客体主栈上跑，由 guest_main.c 在 SDK 初始化前后各调一次）：
//   DM_OODLE_JOB=<作业文件>  批量：读 "DMOJ" u32 条数，每条 u32 压缩长 u32 原长 + 压缩字节；写 <作业文件>.out："DMOR" u32 条数，每条 u32 解出长（0 = 失败）+ 字节；退出
//   DM_OODLE_SERVE=1         服务：stdin 每请求 u64 压缩长 u64 原长 + 压缩字节 → stdout u64 解出长（0 = 失败）+ 字节；stdin 结束即退出（有失败退 1）
// 解码器定位（上游规则，Octopath 0 main+0x4f77e10、宝可梦 Z-A main+0x1a9c9e0 已核）：main 只读段里以 NUL 结尾的字符串 "OodleLZ_Decompress"（Oodle 自己的
//   性能剖析作用域名，与引擎无关），全 text 里唯一一个用 adrp+add 取它地址的函数，函数起点查 .eh_frame_hdr（MOD0+16）。LZ5 由 main 按名导出（勇者斗恶龙 XI S）。
// 时机：Oodle 在 SDK 前（late=0）——工作内存由宿主给，不碰游戏分配器；LZ5 在 nninitStartup 与 DT_INIT 之后（late=1）——LZ5_decompress_safe 每次从游戏 malloc 取 512 KB。
#include "native.h"
#include <unistd.h>

#define OODLE_NAME "OodleLZ_Decompress"

static uint64_t eh_read(const uint8_t *b, uint64_t *o, int enc, uint64_t ehs) {   // .eh_frame_hdr 的一个值（udata4 / sdata4 / udata8，相对自身或相对表头）
    uint64_t v; int fmt = enc & 0xF, app = enc & 0x70; uint64_t at = *o;
    if (fmt == 0x3) { uint32_t x; memcpy(&x, b + at, 4); v = x; *o += 4; }
    else if (fmt == 0xB) { int32_t x; memcpy(&x, b + at, 4); v = (uint64_t)(int64_t)x; *o += 4; }
    else if (fmt == 0x4) { memcpy(&v, b + at, 8); *o += 8; }
    else die("【红】Oodle 工具模式：.eh_frame_hdr 编码 %#x 不认识", enc);
    return app == 0x10 ? v + at : app == 0x30 ? v + ehs : v;
}
// 含 off 的函数的 [起点, 终点)（终点 = 表里下一个起点，没有则 text 末；表按起点升序）
static void func_span(const module_t *m, uint64_t off, uint64_t *start, uint64_t *end) {
    const uint8_t *b = m->base; uint32_t m0; int32_t eh; memcpy(&m0, b + 4, 4);
    if (memcmp(b + m0, "MOD0", 4)) die("【红】Oodle 工具模式：%s 没有 MOD0", m->name);
    memcpy(&eh, b + m0 + 16, 4);
    uint64_t ehs = m0 + (int64_t)eh, o = ehs + 4; int penc = b[ehs + 1], cenc = b[ehs + 2], tenc = b[ehs + 3];
    eh_read(b, &o, penc, ehs); uint64_t n = eh_read(b, &o, cenc, ehs), best = 0, next = m->text_end;
    for (uint64_t i = 0; i < n; i++) { uint64_t s = eh_read(b, &o, tenc, ehs); eh_read(b, &o, tenc, ehs); if (s <= off && s > best) best = s; if (s > off && s < next) next = s; }
    *start = best; *end = next;
}
static uint64_t func_start(const module_t *m, uint64_t off) { uint64_t s, e; func_span(m, off, &s, &e); return s; }
static uint64_t func_end(const module_t *m, uint64_t f) { uint64_t s, e; func_span(m, f, &s, &e); return e; }
// 只读段里整串（前一字节 NUL、含结尾 NUL）出现的位置，最多 cap 个
static int find_strs(const module_t *m, const char *lit, size_t n, uint64_t *out, int cap) {
    const uint8_t *b = m->base, *ro = b + m->ro_off, *re = b + m->data_off; int ns = 0;
    for (const uint8_t *p = ro; ns < cap && (p = memmem(p, (size_t)(re - p), lit, n)); p += n)
        if (p > ro && p[-1] == 0) out[ns++] = (uint64_t)(p - b);   // 前一字节是 NUL：整串，不是别的串的尾巴
    return ns;
}
// text 里用 adrp+add 取 strs 中任一地址的函数（起点，去重），最多 cap 个；返回个数
static int ref_funcs(const module_t *m, const uint64_t *strs, int ns, uint64_t *fns, int cap) {
    const uint8_t *b = m->base; int nfn = 0;
    for (uint64_t pc = 0; pc + 4 <= m->text_end; pc += 4) {
        uint32_t w; memcpy(&w, b + pc, 4);
        if ((w & 0x9F000000) != 0x90000000) continue;   // adrp xd, page
        int64_t imm = (int64_t)(((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2)); if (imm & (1 << 20)) imm -= 1 << 21;
        uint64_t page = (pc & ~0xFFFull) + (uint64_t)(imm << 12);
        for (int k = 1; k < 8 && pc + 4 * k + 4 <= m->text_end; k++) {   // 几条之内补齐它的 add xd, xd, #imm
            uint32_t w2; memcpy(&w2, b + pc + 4 * k, 4);
            if ((w2 & 0xFF800000) != 0x91000000 || ((w2 >> 5) & 31) != (w & 31)) continue;
            uint64_t a = page + ((w2 >> 10) & 0xFFF);
            for (int s = 0; s < ns; s++) if (a == strs[s]) {
                uint64_t f = func_start(m, pc + 4 * k); int seen = 0;
                for (int i = 0; i < nfn; i++) if (fns[i] == f) seen = 1;
                if (!seen && nfn < cap) fns[nfn++] = f;
            }
            break;
        }
    }
    return nfn;
}
// 函数 f 里有没有 bl / b 到 target
static int calls(const module_t *m, uint64_t f, uint64_t target) {
    uint64_t e = func_end(m, f); const uint8_t *b = m->base;
    for (uint64_t pc = f; pc + 4 <= e; pc += 4) {
        uint32_t w; memcpy(&w, b + pc, 4);
        if ((w & 0xFC000000) != 0x94000000 && (w & 0xFC000000) != 0x14000000) continue;
        int64_t imm = w & 0x3FFFFFF; if (imm & (1 << 25)) imm -= 1 << 26;
        if ((uint64_t)((int64_t)pc + imm * 4) == target) return 1;
    }
    return 0;
}
// 构造解码器魔数 0xabadf00dc0cac01a（movk xN, #0xf00d, lsl #32 紧接 movk xN, #0xabad, lsl #48）的函数，最多 cap 个
static int magic_funcs(const module_t *m, uint64_t *fns, int cap) {
    const uint8_t *b = m->base; int nfn = 0;
    for (uint64_t pc = 4; pc + 4 <= m->text_end; pc += 4) {
        uint32_t w, w0; memcpy(&w, b + pc, 4); memcpy(&w0, b + pc - 4, 4);
        if ((w & 0xFFE00000) != 0xF2E00000 || ((w >> 5) & 0xFFFF) != 0xabad) continue;          // movk xd, #0xabad, lsl #48
        if ((w0 & 0xFFE00000) != 0xF2C00000 || ((w0 >> 5) & 0xFFFF) != 0xf00d || (w0 & 31) != (w & 31)) continue;   // 前一条 movk xd, #0xf00d, lsl #32
        uint64_t f = func_start(m, pc); int seen = 0; for (int i = 0; i < nfn; i++) if (fns[i] == f) seen = 1;
        if (!seen && nfn < cap) fns[nfn++] = f;
    }
    return nfn;
}
// 从候选里剔掉 DecodeSome 自己与调它的函数（公开入口把 Create / MemorySizeNeeded 内联时会同时带这些特征），原地压缩
static int drop_callers(const module_t *m, uint64_t decsome, uint64_t *fns, int n) {
    int k = 0; for (int i = 0; i < n; i++) if (fns[i] != decsome && !calls(m, fns[i], decsome)) fns[k++] = fns[i];
    return k;
}
// 定位结果：各项偏移（0 = 没认出）与候选个数（-1 = 连特征字符串都没有）。单测直接调
//   decompress  规则 1（上游）：独立整串 "OodleLZ_Decompress"（Oodle 性能剖析作用域名）的唯一引用函数。Octopath 0 / 宝可梦 Z-A / 双人成行 main+0x62ff370 已核
//   decsome     OodleLZDecoder_DecodeSome：同时引用 Oodle 自己的两条错误消息 "1000 calls without progress!" 与 "you didn't give me enough window!" 的唯一函数
//               （双人成行 main+0x62fe600，被 Decompress 调；猎天使魔女3 main+0x12ff2f0，游戏直接调）
//   msn         OodleLZDecoder_MemorySizeNeeded：引用 "OODLE ERROR : OodleLZ_Decompress: asked to decode Legacy…" 消息、且不调 DecodeSome 的唯一函数
//               （双人成行 main+0x62fe4c0；猎天使魔女3 main+0x12fefd0；两款都 320 字节）
//   create      OodleLZDecoder_Create：构造解码器魔数 0xabadf00dc0cac01a 并写进解码器 +0x20、且不调 DecodeSome 的唯一函数（猎天使魔女3 main+0x12ff110；
//               双人成行把它内联进了 Decompress，剔掉后为空——那款走规则 1，不需要它）
typedef struct { uint64_t decompress, decsome, msn, create; int n_decompress, n_decsome, n_msn, n_create; } oodle_locs;
void s2a_oodle_locate(const module_t *m, oodle_locs *L) {
    static const char e1[] = "OODLE ERROR : 1000 calls without progress!\n", e2[] = "OODLE ERROR : you didn't give me enough window!\n",
                      e3[] = "OODLE ERROR : " OODLE_NAME ": asked to decode Legacy";   // 前缀：后面的措辞按版本不同
    uint64_t s[8], s2[8], f1[8], f2[8]; int ns, n2;
    memset(L, 0, sizeof *L); L->n_decompress = L->n_decsome = L->n_msn = L->n_create = -1;
    if ((ns = find_strs(m, OODLE_NAME, sizeof OODLE_NAME, s, 8))) { L->n_decompress = ref_funcs(m, s, ns, f1, 8); if (L->n_decompress == 1) L->decompress = f1[0]; }
    ns = find_strs(m, e1, sizeof e1, s, 8); n2 = find_strs(m, e2, sizeof e2, s2, 8);
    if (ns && n2) {
        int nf1 = ref_funcs(m, s, ns, f1, 8), nf2 = ref_funcs(m, s2, n2, f2, 8); L->n_decsome = 0;
        for (int i = 0; i < nf1; i++) for (int j = 0; j < nf2; j++) if (f1[i] == f2[j]) { L->decsome = f1[i]; L->n_decsome++; }
        if (L->n_decsome != 1) L->decsome = 0;
    }
    if (!L->decsome) return;   // 没有 DecodeSome 就没法剔内联，后两项不算
    if ((ns = find_strs(m, e3, sizeof e3 - 1, s, 8))) { L->n_msn = drop_callers(m, L->decsome, f1, ref_funcs(m, s, ns, f1, 8)); if (L->n_msn == 1) L->msn = f1[0]; }
    L->n_create = drop_callers(m, L->decsome, f1, magic_funcs(m, f1, 8)); if (L->n_create == 1) L->create = f1[0];
}
// 按定位结果选后端：1 = 调公开入口 OodleLZ_Decompress，2 = 宿主自己走 Decoder 三件套（MemorySizeNeeded → Create → DecodeSome 循环）；0 = 认不出（*why 说原因）。
//   两条路都能算时互相校验：Decompress 必须调 DecodeSome（它就是那个循环的外壳），否则 -1
int s2a_oodle_pick(const module_t *m, const oodle_locs *L, const char **why) {
    static char buf[512];
    if (L->decompress) {
        if (L->decsome && !calls(m, L->decompress, L->decsome)) {
            snprintf(buf, sizeof buf, "规则 1 认出的 " OODLE_NAME "（main+%#llx）没有调用 DecodeSome（main+%#llx），两条规则不一致", (unsigned long long)L->decompress, (unsigned long long)L->decsome); *why = buf; return -1; }
        *why = L->decsome ? "规则 1（独立整串 \"" OODLE_NAME "\" 的唯一引用函数），且它调用了规则 2 认出的 DecodeSome" : "规则 1（独立整串 \"" OODLE_NAME "\" 的唯一引用函数）";
        return 1;
    }
    if (L->decsome && L->msn && L->create) { *why = "规则 2（这款没有公开入口 OodleLZ_Decompress：宿主自己调 Decoder 三件套 MemorySizeNeeded → Create → DecodeSome）"; return 2; }
    if (L->n_decompress == -1 && L->n_decsome == -1) { *why = "main 的只读段里既没有 \"" OODLE_NAME "\" 整串、也没有 Oodle 自己的错误消息——这款没把 Oodle 链进 main"; return 0; }
    snprintf(buf, sizeof buf, "候选数：" OODLE_NAME " %d、DecodeSome %d、MemorySizeNeeded %d、Create %d（各要恰好 1；-1 = 没有特征串）", L->n_decompress, L->n_decsome, L->n_msn, L->n_create);
    *why = buf; return 0;
}

// OodleLZ_Decompress(compBuf, compBufSize, rawBuf, rawLen, fuzzSafe, checkCRC, verbosity, decBufBase, decBufSize, fpCallback, callbackUserData, decoderMemory, decoderMemorySize, threadPhase)
//   第 9–14 个参数走栈；全按 64 位声明，Apple 与 AAPCS64 的栈布局才一致（Apple 会把小于 8 字节的栈参数挤紧）
typedef int64_t (*oodle_fn)(const void *, int64_t, void *, int64_t, int64_t, int64_t, int64_t, void *, int64_t, void *, void *, void *, int64_t, int64_t);
// LZ5_decompress_safe(source, dest, compressedSize, maxDecompressedSize) → 解出字节数，负 = 失败
typedef int32_t (*lz5_fn)(const void *, void *, int32_t, int32_t);
// Decoder 三件套（Oodle 公开头文件的签名；猎天使魔女3 游戏侧调用点 main+0xcbc698 / 0xcbc7f8 的传参逐项对上）：
//   S32 OodleLZDecoder_MemorySizeNeeded(OodleLZ_Compressor compressor, SINTa rawLen)      compressor -1 = 不限（按最大的算），rawLen -1 = 不限
//   OodleLZDecoder *OodleLZDecoder_Create(compressor, S64 rawLen, void *memory, SINTa memorySize)   memory 给了就用它（够大才行），不碰 Oodle 的分配器
//   OO_BOOL OodleLZDecoder_DecodeSome(decoder, OodleLZ_DecodeSome_Out *out, void *decBuf, SINTa decBufPos, SINTa decBufferSize, SINTa decBufAvail,
//                                    const void *compPtr, SINTa compAvail, fuzzSafe, checkCRC, verbosity, threadPhase)   后 4 个走栈，按 64 位声明（同上）
//   OodleLZ_DecodeSome_Out = { S32 decodedCount, compBufUsed, curQuantumRawLen, curQuantumCompLen }
typedef int32_t (*msn_fn)(int32_t, int64_t);
typedef void *(*create_fn)(int32_t, int64_t, void *, int64_t);
typedef int32_t (*decsome_fn)(void *, int32_t *, void *, int64_t, int64_t, int64_t, const void *, int64_t, int64_t, int64_t, int64_t, int64_t);

static struct { const char *name; oodle_fn oodle; lz5_fn lz5; msn_fn msn; create_fn create; decsome_fn decsome; uint64_t off; int found; int32_t api_need; } g_dec;
static void dec_find(const char *mode) {
    if (g_dec.found) return;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) {
        module_t *m = &g_mod[i];
        void *p = module_sym(m, "LZ5_decompress_safe");
        if (p) { g_dec.name = "LZ5_decompress_safe"; g_dec.lz5 = (lz5_fn)p; g_dec.off = (uint64_t)((uint8_t *)p - m->base); g_dec.found = 1; return; }
        const char *fx = getenv("DM_OODLE_FN");   // 诊断 / 救急：规则都认不出时按手工给的 main 内偏移当 OodleLZ_Decompress 调（十六进制）；对不对由工具侧的长度 / 魔数校验兜底
        if (fx && *fx) {
            g_dec.off = strtoull(fx, NULL, 16);
            if (g_dec.off < 4 || g_dec.off >= m->text_end) die("【红】%s：DM_OODLE_FN=main+%#llx 不在代码段内", mode, (unsigned long long)g_dec.off);
            LOG("【注意】%s：DM_OODLE_FN 手工指定 " OODLE_NAME " = main+%#llx（没经规则认定，解出的内容要靠下游校验）", mode, (unsigned long long)g_dec.off);
            g_dec.oodle = (oodle_fn)(void *)(m->base + g_dec.off); g_dec.name = OODLE_NAME; g_dec.found = 1; return;
        }
        oodle_locs L; const char *why; s2a_oodle_locate(m, &L); int pick = s2a_oodle_pick(m, &L, &why);
        LOG("Oodle 定位：" OODLE_NAME " main+%#llx（候选 %d）、DecodeSome main+%#llx（%d）、MemorySizeNeeded main+%#llx（%d）、Create main+%#llx（%d）",
            (unsigned long long)L.decompress, L.n_decompress, (unsigned long long)L.decsome, L.n_decsome, (unsigned long long)L.msn, L.n_msn, (unsigned long long)L.create, L.n_create);
        if (pick <= 0) die("【红】%s：认不出游戏自带的 Oodle 解码器——%s%s", mode, why, pick == 0 && L.n_decompress != -1 ? "；可用 DM_OODLE_FN=<main 内偏移> 手工指定后由下游校验" : "");
        LOG("Oodle 工具模式：%s", why);
        if (pick == 1) { g_dec.off = L.decompress; g_dec.oodle = (oodle_fn)(void *)(m->base + L.decompress); g_dec.name = OODLE_NAME; }
        else {
            g_dec.off = L.decsome; g_dec.msn = (msn_fn)(void *)(m->base + L.msn); g_dec.create = (create_fn)(void *)(m->base + L.create); g_dec.decsome = (decsome_fn)(void *)(m->base + L.decsome);
            g_dec.name = "OodleLZDecoder_MemorySizeNeeded / Create / DecodeSome";
        }
        g_dec.found = 1; return;
    }
    die("【红】%s：没有 main 模块", mode);
}
// Decoder 三件套版的 Decompress（照公开入口的做法）：工作内存按「不限压缩器、不限原长」问一次大小（≥ 任何一块所需），每块 Create 在上面、DecodeSome 循环到解满
static int64_t dec_run_api(const void *c, int64_t cl, void *r, int64_t rl, uint8_t *scratch, int64_t scratch_n) {
    if (!g_dec.api_need) {
        g_dec.api_need = g_dec.msn(-1, -1);
        LOG("Oodle 工具模式：MemorySizeNeeded(-1, -1) = %d 字节", g_dec.api_need);
        if (g_dec.api_need <= 0) die("【红】Oodle 工具模式：OodleLZDecoder_MemorySizeNeeded 返回 %d", g_dec.api_need);
        if (g_dec.api_need + 64 > scratch_n) die("【红】Oodle 工具模式：解码器要 %d 字节工作内存，宿主只备了 %lld", g_dec.api_need, (long long)scratch_n);
    }
    void *dec = g_dec.create(-1, rl, scratch, g_dec.api_need + 64);   // Create 会先把 memory 向上对齐 16、再核 memorySize − 16 ≥ 所需
    if (!dec) return -3;
    int64_t pos = 0, cpos = 0; int32_t out[4]; int rounds = 0;
    while (pos < rl) {
        memset(out, 0, sizeof out);
        int32_t ok = g_dec.decsome(dec, out, r, pos, rl, rl - pos, (const uint8_t *)c + cpos, cl - cpos, 1, 0, 0, 3);   // fuzzSafe、不查 CRC、不打印、ThreadPhaseAll
        if (!ok) return -4;
        if (out[0] <= 0 || out[1] < 0 || cpos + out[1] > cl || ++rounds > 1000000) return -5;   // 没前进 / 读过头：不死循环
        pos += out[0]; cpos += out[1];
    }
    return pos;
}
static int64_t dec_run(const void *c, int64_t cl, void *r, int64_t rl, void *scratch, int64_t scratch_n) {
    if (g_dec.lz5) return cl > INT32_MAX || rl > INT32_MAX ? -1 : g_dec.lz5(c, r, (int32_t)cl, (int32_t)rl);
    if (g_dec.decsome) return dec_run_api(c, cl, r, rl, scratch, scratch_n);
    return g_dec.oodle(c, cl, r, rl, 1, 0, 0, NULL, 0, NULL, NULL, scratch, scratch_n, 3);   // fuzzSafe、不查 CRC、不打印、不分线程
}

int s2a_oodle_tool_on(void) {
    const char *j = getenv("DM_OODLE_JOB"), *s = getenv("DM_OODLE_SERVE");
    return (j && *j) || (s && *s);
}

static uint32_t rd32(FILE *f) { uint32_t v = 0; if (fread(&v, 4, 1, f) != 1) die("【红】DM_OODLE_JOB：作业文件提前结束"); return v; }
static void job_run(const char *job) {
    FILE *in = fopen(job, "rb"); if (!in) die("【红】DM_OODLE_JOB：打不开 %s", job);
    if (rd32(in) != 0x4a4f4d44) die("【红】DM_OODLE_JOB：%s 不是作业文件（魔数不是 DMOJ）", job);
    uint32_t n = rd32(in);
    char outp[1024]; snprintf(outp, sizeof outp, "%s.out", job);
    FILE *out = fopen(outp, "wb"); if (!out) die("【红】DM_OODLE_JOB：写不了 %s", outp);
    uint32_t hdr[2] = {0x524f4d44, n}; fwrite(hdr, 4, 2, out);
    size_t scratch_n = 16u << 20; void *scratch = malloc(scratch_n);   // 解码器工作内存由宿主给，Oodle 不会去调它的分配器
    if (!scratch) die("【红】DM_OODLE_JOB：解码器工作内存分配失败");
    uint32_t bad = 0; uint64_t raw_total = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t cl = rd32(in), rl = rd32(in);
        uint8_t *c = malloc(cl ? cl : 1), *r = malloc(rl ? rl : 1);
        if (!c || !r) die("【红】DM_OODLE_JOB：第 %u 条缓冲分配失败（%u → %u 字节）", i, cl, rl);
        if (fread(c, 1, cl, in) != cl) die("【红】DM_OODLE_JOB：第 %u 条提前结束", i);
        int64_t got = dec_run(c, cl, r, rl, scratch, (int64_t)scratch_n);
        uint32_t ol = got == (int64_t)rl ? rl : 0;
        if (!ol && bad++ < 8) LOG("【红】DM_OODLE_JOB：第 %u 条（%u → %u 字节）失败（解码器返回 %lld）", i, cl, rl, (long long)got);
        fwrite(&ol, 4, 1, out); if (ol) fwrite(r, 1, ol, out);
        raw_total += ol; free(c); free(r);
    }
    fclose(in); fclose(out); free(scratch);
    LOG("DM_OODLE_JOB：%u 条用游戏的 %s 解出（%u 条失败，共 %.1f MB）→ %s", n - bad, g_dec.name, bad, raw_total / 1048576.0, outp);
    fflush(stderr); _exit(bad ? 1 : 0);
}

static int read_all(int fd, void *p, size_t n) {
    for (uint8_t *q = p; n; ) { ssize_t k = read(fd, q, n); if (k <= 0) return 0; q += k; n -= (size_t)k; }
    return 1;
}
static void write_all(int fd, const void *p, size_t n) {
    for (const uint8_t *q = p; n; ) { ssize_t k = write(fd, q, n); if (k <= 0) die("【红】DM_OODLE_SERVE：写应答失败"); q += k; n -= (size_t)k; }
}
// 应答专用的描述符：服务模式的应答走原 stdout 管道，宿主 / C# 服务层的日志不许混进去（11-01 勇者斗恶龙 XI S：LZ5 要先起 C#，C# 起局往 stdout 打日志，
//   工具侧把日志文字当成应答长度读，解码全错）。s2a_oodle_tool_claim_stdout 在任何日志之前把原 stdout 另存、fd 1 改指 stderr
static int g_out = 1;
void s2a_oodle_tool_claim_stdout(void) {
    int fd = dup(1);
    if (fd < 0 || dup2(2, 1) < 0) die("【红】Oodle 工具模式：另存应答用的 stdout 失败");
    g_out = fd;
}
static void serve_run(void) {
    enum { SLACK = 0x10000 };
    size_t scratch_n = 16u << 20; uint8_t *scratch = malloc(scratch_n), *comp = NULL, *raw = NULL; size_t comp_cap = 0, raw_cap = 0; uint64_t n = 0, bad = 0;
    if (!scratch) die("【红】DM_OODLE_SERVE：解码器工作内存分配失败");
    LOG("DM_OODLE_SERVE：%s 在 main+%#llx，等 stdin 上的请求", g_dec.name, (unsigned long long)g_dec.off);
    for (;;) {
        uint64_t hdr[2];
        if (!read_all(0, hdr, sizeof hdr)) break;
        if (hdr[0] > (1ull << 32) || hdr[1] > (1ull << 32)) die("【红】DM_OODLE_SERVE：请求太大（%#llx → %#llx）", (unsigned long long)hdr[0], (unsigned long long)hdr[1]);
        if (hdr[0] > comp_cap) { free(comp); comp_cap = hdr[0]; if (!(comp = malloc(comp_cap))) die("【红】DM_OODLE_SERVE：输入缓冲分配失败"); }
        if (hdr[1] + SLACK > raw_cap) { free(raw); raw_cap = hdr[1] + SLACK; if (!(raw = malloc(raw_cap))) die("【红】DM_OODLE_SERVE：输出缓冲分配失败"); }
        if (!read_all(0, comp, hdr[0])) die("【红】DM_OODLE_SERVE：请求被截断");
        int64_t got = dec_run(comp, (int64_t)hdr[0], raw, (int64_t)hdr[1], scratch, (int64_t)scratch_n);
        uint64_t out = got == (int64_t)hdr[1] ? (uint64_t)got : 0;
        if (!out && hdr[1] && bad++ < 8) LOG("【红】DM_OODLE_SERVE：第 %llu 个请求（%llu → %llu 字节）失败（解码器返回 %lld）", (unsigned long long)n, (unsigned long long)hdr[0], (unsigned long long)hdr[1], (long long)got);
        write_all(g_out, &out, sizeof out);
        if (out) write_all(g_out, raw, out);
        n++;
    }
    LOG("DM_OODLE_SERVE：%llu 个请求，%llu 个失败", (unsigned long long)n, (unsigned long long)bad);
    fflush(stderr); _exit(bad ? 1 : 0);
}

// 选到的解码器要不要 SDK 初始化（LZ5 要游戏 malloc，在 SDK 初始化之后才做）：host_main.c 据此决定起不起 C# 服务层（nninitInitializeSdkModule 连系统服务 svc 0x1f 要它）。
//   模块已装好、游戏主线程未起时调；同一份选择结果供下面 s2a_oodle_tool_maybe 用
int s2a_oodle_tool_needs_sdk(void) {
    const char *job = getenv("DM_OODLE_JOB");
    dec_find(job && *job ? "DM_OODLE_JOB" : "DM_OODLE_SERVE");
    return g_dec.lz5 != NULL;
}

// guest_main.c 调两次：SDK 初始化前 late=0、nninitStartup 与各模块 DT_INIT 之后 late=1。Oodle 在前一次做（不依赖 SDK），LZ5 在后一次（要游戏的 malloc）；
//   另一次直接返回。做完 _exit，不进 nnMain
void s2a_oodle_tool_maybe(int late) {
    const char *job = getenv("DM_OODLE_JOB"), *serve = getenv("DM_OODLE_SERVE");
    int want_job = job && *job, want_serve = serve && *serve;
    if (!want_job && !want_serve) return;
    dec_find(want_job ? "DM_OODLE_JOB" : "DM_OODLE_SERVE");
    if (late != (g_dec.lz5 != NULL)) return;
    LOG("Oodle 工具模式：%s 在 main+%#llx（%s）", g_dec.name, (unsigned long long)g_dec.off, late ? "SDK 初始化之后" : "SDK 初始化之前");
    if (want_job) job_run(job);
    serve_run();
}

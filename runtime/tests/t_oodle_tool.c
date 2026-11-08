// Oodle 工具模式定位器单测（oodle_tool.c s2a_oodle_locate / s2a_oodle_pick）：手拼一个最小「模块映像」——MOD0 头、.eh_frame_hdr 函数表、只读段里的特征字符串、
//   text 里 adrp+add 取地址 / bl / movk 魔数——期望值就是拼进去的函数起点，不跑被测实现算。
//   编码按 ARMv8 手册手算：adrp 0x90000000 | immlo<<29 | immhi<<5 | rd；add 0x91000000 | imm12<<10 | rn<<5 | rd；bl 0x94000000 | imm26；movk 0xF2800000 | hw<<21 | imm16<<5 | rd
#include "../src/native.h"
S2A_TEST_MOD_TABLE(64); int g_nmod;
void *module_sym(module_t *m, const char *name) { (void)m; (void)name; return NULL; }
typedef struct { uint64_t decompress, decsome, msn, create; int n_decompress, n_decsome, n_msn, n_create; } oodle_locs;
void s2a_oodle_locate(const module_t *m, oodle_locs *L);
int s2a_oodle_pick(const module_t *m, const oodle_locs *L, const char **why);

static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } } while (0)
enum { IMG = 0x3000, TEXT_END = 0x1000, RO = 0x1000, DATA = 0x2000, MOD0 = 0x800, EH = 0x1800, STR = 0x1200, DECOY = 0x1300, E1 = 0x1400, E2 = 0x1480, E3 = 0x1500 };
static const char e1[] = "OODLE ERROR : 1000 calls without progress!\n", e2[] = "OODLE ERROR : you didn't give me enough window!\n",
                  e3[] = "OODLE ERROR : OodleLZ_Decompress: asked to decode Legacy compressor; not supported!\n";
static void w32(uint8_t *b, uint64_t at, uint32_t v) { memcpy(b + at, &v, 4); }
static void wi32(uint8_t *b, uint64_t at, int32_t v) { memcpy(b + at, &v, 4); }
static void adrp_add(uint8_t *b, uint64_t pc, uint64_t target, int rd) {   // pc 处 adrp rd, 页；pc+4 处 add rd, rd, #页内偏移
    int64_t pages = (int64_t)((target & ~0xFFFull) >> 12) - (int64_t)((pc & ~0xFFFull) >> 12);
    uint32_t immlo = (uint32_t)pages & 3, immhi = ((uint32_t)pages >> 2) & 0x7FFFF;
    w32(b, pc, 0x90000000u | immlo << 29 | immhi << 5 | (uint32_t)rd);
    w32(b, pc + 4, 0x91000000u | (uint32_t)(target & 0xFFF) << 10 | (uint32_t)rd << 5 | (uint32_t)rd);
}
static void bl(uint8_t *b, uint64_t pc, uint64_t target) { w32(b, pc, 0x94000000u | ((uint32_t)(((int64_t)target - (int64_t)pc) / 4) & 0x3FFFFFF)); }
static void magic(uint8_t *b, uint64_t pc, int rd) {   // mov x, #0xc01a；movk #0xc0ca lsl 16；movk #0xf00d lsl 32；movk #0xabad lsl 48；str x, [x0, #0x20]
    w32(b, pc, 0xD2800000u | 0xc01au << 5 | (uint32_t)rd); w32(b, pc + 4, 0xF2A00000u | 0xc0cau << 5 | (uint32_t)rd);
    w32(b, pc + 8, 0xF2C00000u | 0xf00du << 5 | (uint32_t)rd); w32(b, pc + 12, 0xF2E00000u | 0xabadu << 5 | (uint32_t)rd);
    w32(b, pc + 16, 0xF9001000u | (uint32_t)rd);
}
static module_t make(uint8_t *b, const uint64_t *funcs, int nf) {
    memset(b, 0, IMG);
    w32(b, 4, MOD0); memcpy(b + MOD0, "MOD0", 4); wi32(b, MOD0 + 16, EH - MOD0);
    // .eh_frame_hdr：版本 1，eh_frame_ptr 编码 pcrel sdata4（0x1B），计数 udata4（0x03），表项 datarel sdata4（0x3B）
    b[EH] = 1; b[EH + 1] = 0x1B; b[EH + 2] = 0x03; b[EH + 3] = 0x3B;
    uint64_t o = EH + 4; wi32(b, o, 0); o += 4; w32(b, o, (uint32_t)nf); o += 4;
    for (int i = 0; i < nf; i++) { wi32(b, o, (int32_t)(funcs[i] - EH)); o += 4; wi32(b, o, 0); o += 4; }
    module_t m = {0}; strcpy(m.name, "main"); m.base = b; m.size = IMG; m.text_end = TEXT_END; m.ro_off = RO; m.data_off = DATA;
    return m;
}
// 规则 2 的布局（猎天使魔女3）：0x100 MemorySizeNeeded（引用 e3）、0x300 DecodeSome（引用 e1 e2）、0x500 Create（写魔数）、0x700 游戏代码（bl 0x300）
static void layout_api(uint8_t *b) {
    memset(b + 0x100, 0, 0x700); memcpy(b + E1, e1, sizeof e1); memcpy(b + E2, e2, sizeof e2); memcpy(b + E3, e3, sizeof e3);
    adrp_add(b, 0x110, E3, 3); adrp_add(b, 0x320, E1, 1); adrp_add(b, 0x3a0, E2, 1); magic(b, 0x520, 8); bl(b, 0x740, 0x300);
    w32(b, 0x330, 0x14000000u | ((uint32_t)((0x300 - 0x330) / 4) & 0x3FFFFFF));   // 解码循环内部跳回自己起点：不算别人调它
}
int main(void) {
    static uint8_t b[IMG]; const uint64_t funcs[] = {0x100, 0x300, 0x500, 0x700, 0x900}; oodle_locs L; const char *why; int pick;
    module_t m = make(b, funcs, 5);
    // ① 规则 1（上游，Octopath 0 / Z-A）：一个函数（0x300）里两处取独立整串地址 → decompress 0x300、候选 1；没有错误串 → 其余 -1；选后端 1
    memcpy(b + STR, "OodleLZ_Decompress", 19); adrp_add(b, 0x310, STR, 8); adrp_add(b, 0x340, STR, 1);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(L.decompress == 0x300 && L.n_decompress == 1 && L.n_decsome == -1 && pick == 1, "① decompress %#llx/%d decsome %d pick %d，应为 0x300/1/-1/1", (unsigned long long)L.decompress, L.n_decompress, L.n_decsome, pick);
    // ② 什么特征串都没有 → 全 -1、pick 0、原因说「没把 Oodle 链进 main」
    memset(b + STR, 0, 19);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(L.n_decompress == -1 && L.n_decsome == -1 && pick == 0 && strstr(why, "没把 Oodle 链进 main"), "② 无串时 %d/%d pick %d（%s）", L.n_decompress, L.n_decsome, pick, why);
    // ③ 别的名字的尾巴（"XOodleLZ_Decompress"，前一字节不是 NUL）不算整串：仍 -1
    memcpy(b + DECOY - 1, "XOodleLZ_Decompress", 20); adrp_add(b, 0x310, DECOY, 8);
    s2a_oodle_locate(&m, &L);
    CHECK(L.n_decompress == -1, "③ 带前缀的串被当成整串（候选 %d）", L.n_decompress);
    memset(b + DECOY - 1, 0, 20);
    // ④ 两个函数（0x300、0x500）都引用整串 → 候选 2、decompress 0、pick 0 且原因带候选数
    memcpy(b + STR, "OodleLZ_Decompress", 19); adrp_add(b, 0x310, STR, 8); adrp_add(b, 0x520, STR, 9);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(L.n_decompress == 2 && L.decompress == 0 && pick == 0 && strstr(why, "OodleLZ_Decompress 2"), "④ 两函数引用时候选 %d / %#llx pick %d（%s）", L.n_decompress, (unsigned long long)L.decompress, pick, why);
    // ⑤ adrp 的寄存器与 add 的 rn 不同（不是同一次取址）→ 不算引用：候选 0
    memset(b + 0x300, 0, 0x300);
    adrp_add(b, 0x310, STR, 8); w32(b, 0x314, 0x91000000u | (uint32_t)(STR & 0xFFF) << 10 | 9u << 5 | 9u);
    s2a_oodle_locate(&m, &L);
    CHECK(L.n_decompress == 0, "⑤ adrp / add 寄存器不配时候选 %d，应为 0", L.n_decompress);
    // ⑥ 引用落在 0x500 里、add 隔了 3 条指令 → decompress 0x500
    memset(b + 0x300, 0, 0x300);
    { int64_t pages = (STR >> 12) - (0x510 >> 12); w32(b, 0x510, 0x90000000u | ((uint32_t)pages & 3) << 29 | (((uint32_t)pages >> 2) & 0x7FFFF) << 5 | 8u); }
    w32(b, 0x51c, 0x91000000u | (uint32_t)(STR & 0xFFF) << 10 | 8u << 5 | 8u);
    s2a_oodle_locate(&m, &L);
    CHECK(L.decompress == 0x500 && L.n_decompress == 1, "⑥ 隔几条指令的 add：%#llx/%d，应为 0x500/1", (unsigned long long)L.decompress, L.n_decompress);
    // ⑦ 规则 2（猎天使魔女3 的布局）：没有整串；三件套各唯一（游戏代码 0x700 调 DecodeSome 不影响）→ pick 2
    memset(b + STR, 0, 19); layout_api(b);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(L.n_decompress == -1 && L.decsome == 0x300 && L.msn == 0x100 && L.create == 0x500 && pick == 2,
          "⑦ 规则 2：decompress %d decsome %#llx msn %#llx create %#llx pick %d，应为 -1/0x300/0x100/0x500/2", L.n_decompress, (unsigned long long)L.decsome, (unsigned long long)L.msn, (unsigned long long)L.create, pick);
    // ⑧ 双人成行的布局：公开入口 0x900 引用整串、调 DecodeSome、并把 Create / MemorySizeNeeded 内联（也引用 e3、也写魔数）→ 剔掉它后 msn / create 仍各 1；pick 1、原因带「调用了…DecodeSome」
    adrp_add(b, 0x910, STR, 8); memcpy(b + STR, "OodleLZ_Decompress", 19); bl(b, 0x940, 0x300); adrp_add(b, 0x950, E3, 3); magic(b, 0x960, 8);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(L.decompress == 0x900 && L.n_msn == 1 && L.msn == 0x100 && L.n_create == 1 && L.create == 0x500 && pick == 1 && strstr(why, "DecodeSome"),
          "⑧ 两规则并存：decompress %#llx msn %#llx/%d create %#llx/%d pick %d（%s）", (unsigned long long)L.decompress, (unsigned long long)L.msn, L.n_msn, (unsigned long long)L.create, L.n_create, pick, why);
    // ⑨ 公开入口候选不调 DecodeSome（整串被别的函数引用）→ 两规则不一致：pick -1
    w32(b, 0x940, 0);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(pick == -1 && strstr(why, "不一致"), "⑨ 不一致时 pick %d（%s）", pick, why);
    // ⑩ 双人成行真实情形：Create 完全内联进公开入口（0x500 没有魔数）→ create 候选 0，但规则 1 在，仍 pick 1
    bl(b, 0x940, 0x300); memset(b + 0x520, 0, 20);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(L.n_create == 0 && pick == 1, "⑩ Create 内联时 create 候选 %d pick %d，应为 0/1", L.n_create, pick);
    // ⑪ 没有规则 1、Create 也认不出 → pick 0，原因列候选数（Create 0）
    memset(b + 0x900, 0, 0x100); memset(b + STR, 0, 19);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(pick == 0 && strstr(why, "Create 0"), "⑪ 三件套不齐时 pick %d（%s）", pick, why);
    // ⑫ 两条错误串落在不同函数（0x300 / 0x500）→ 没有 DecodeSome：n_decsome 0，后两项不算（-1）
    layout_api(b); memset(b + 0x3a0, 0, 8); adrp_add(b, 0x540, E2, 1);
    s2a_oodle_locate(&m, &L); pick = s2a_oodle_pick(&m, &L, &why);
    CHECK(L.n_decsome == 0 && L.n_msn == -1 && pick == 0, "⑫ 两串分在两函数：decsome 候选 %d msn %d pick %d，应为 0/-1/0", L.n_decsome, L.n_msn, pick);
    if (!bad) printf("✓ t_oodle_tool：0 处不符（共 12 项）\n");
    return bad != 0;
}

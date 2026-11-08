// F4.3/F4.2A/P1 的生产接缝回归（宿主）。
//
// 这里原样链接生产实现，不另写模型：
//   * direct/source_store.c        —— 捕获期完整摘要、短 key 校验、按代际 pin
//   * nvn/nvn_vk_compile_facts.c  —— Draw 快照 → 编译事实 / 规范内容身份 / P1 备忘键
//   * direct/input_identity.c     —— 规范编码
//
// 独立期望：凡是会改变“编译请求”的事实，必须同时改变规范身份与 P1 备忘键；缺完整源证明时
// 身份必须不可用（本次绘制不做缓存查找），不能退回短 stage key。
// 反例基线：
//   * `a922d636`：`vattr_fmt` 0x1→0x3 时 attributeTypes Float→Uint、完整身份不同，但 P1 备忘仍命中。
//   * 强制同短 key、不同 code：旧编码（只含 8 字节 key）完全相同，canonical_equal=1。
#include <stdio.h>
#include <string.h>

#include "direct/input_identity.h"
#include "direct/sha256.h"
#include "direct/source_store.h"
#include "nvn/nvn_vk_compile_facts.h"
#include "nvn.h"

// source_store 的失败日志出口在设备上由 hle_nvn 接到 logcat；宿主测试给空实现。
void s2a_source_log_line(const char *line) { (void)line; }
// 生产定义在 nvn_vk_draw.c（弱引用）；本夹具不链 draw.c，这里给恒等实现让 macOS 链接器也能解析。
uint32_t nvk_attr_pair_canon(uint32_t f) { return f; }

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

// 桩注册表：id → 描述符（nvk_texture_facts_fill 的 lookup 注入；生产是带缓存的
// s2a_vk_adapter_tex_facts 包装）。valid=0 即“注册表里没有这个 id”。
struct reg_desc { int valid; uint32_t fmt, target, layers; };
static struct reg_desc g_reg[4096];
static int stub_tex_lookup(int id, struct nvk_tex_desc *out, void *opaque) {
    (void)opaque;
    if (id < 0 || id >= (int)(sizeof g_reg / sizeof g_reg[0]) || !g_reg[id].valid) return -1;
    out->nvn_format = g_reg[id].fmt;
    out->nvn_target = g_reg[id].target;
    out->layers = g_reg[id].layers;
    return 0;
}

// 测试提供“设备级真实状态”的强定义（生产里是 hle_nvn 的全局量；这里只有弱引用）。
int s2a_nvn_depth_mode = 1;
int s2a_nvn_window_origin_mode = 1;
static uint64_t g_reggen = 7;
uint64_t s2a_vk_adapter_registry_generation(void) { return g_reggen; }

static void make_key(const void *code, uint32_t code_bytes, const void *control, uint32_t control_bytes,
                     uint8_t out[8]) {
    s2a_sha256 c;
    uint8_t md[32];
    s2a_sha256_init(&c);
    s2a_sha256_update(&c, control, control_bytes);
    s2a_sha256_update(&c, code, code_bytes);
    s2a_sha256_final(&c, md);
    memcpy(out, md, 8);
}

enum { CODE_BYTES = 0x200 };
static uint8_t g_code[2][CODE_BYTES];
static uint8_t g_ctl[2][S2A_SOURCE_CONTROL_BYTES];
static uint8_t g_key[2][8];

static void build_source(int slot, uint8_t seed) {
    for (int i = 0; i < CODE_BYTES; i++) g_code[slot][i] = (uint8_t)(i * (seed ? 13 : 7) + seed);
    for (unsigned i = 0; i < S2A_SOURCE_CONTROL_BYTES; i++) g_ctl[slot][i] = (uint8_t)(i * 3u + seed);
    uint32_t n = CODE_BYTES;
    memcpy(g_ctl[slot] + 0x704, &n, 4);          // 控制段自述的 code 长度
    uint32_t c1_begin = CODE_BYTES - 0x40, c1_end = CODE_BYTES + 0x40;
    memcpy(g_ctl[slot] + 0x700, &c1_begin, 4);   // c1 真实范围（相对 code 起点）
    memcpy(g_ctl[slot] + 0x704, &c1_end, 4);
    make_key(g_code[slot], CODE_BYTES, g_ctl[slot], S2A_SOURCE_CONTROL_BYTES, g_key[slot]);
}

struct fixture {
    struct s2a_record_draw_state st;
    struct s2a_direct_compile_context pc;
    struct nvk_env env;
};

static void fixture_init(struct fixture *f) {
    memset(f, 0, sizeof *f);
    f->pc.session = 11;
    f->pc.generation = 3;
    f->pc.profile_json = "{\"profileHash\":\"sha256-test\"}";
    f->pc.profile_bytes = strlen(f->pc.profile_json);
    f->pc.direct_abi = 5;
    f->pc.translator_closure = "nvn-2d9c7704";
    f->pc.shader_draw_parameters = 1;

    f->st.stages = 0x3;
    memcpy(f->st.keys[0], g_key[0], 8);   // vs
    memcpy(f->st.keys[1], g_key[1], 8);   // fs
    f->st.prim = 0x4;                     // Triangles
    f->st.rt_count = 1;
    f->st.rt[0].key = 0x1000;
    f->st.rt[0].format = VK_FORMAT_R8G8B8A8_UNORM;
    f->st.rt[0].nvn_format = 0x8;
    f->st.rt[0].obj_magic = 0x00584554u;
    f->st.tex_pool_n = 10256;
    f->st.samp_pool_n = 1256;
    f->st.ubo_use[0] = 1;
    f->st.ubo_use[1] = 0x1f;
    for (int i = 0; i < 32; i++) f->st.vattr_fmt[i] = 0x1;   // Float
    f->st.state_seen = 0x3f;
    for (int i = 0; i < 6; i++)
        for (int b = 0; b < 0x18; b++) f->st.state_obj[i][b] = (uint8_t)(i * 0x18 + b);
    // 绘制参数（不参与身份，也不进备忘键）：这里放一组非零值，后面对照“改它不改变身份”。
    f->st.count = 3625;
    f->st.first = 0;
    f->st.instances = 1;
    f->st.vp_x = 0.0f;
    f->st.vp_w = 1024.0f;
    f->st.ubo_addr = 0x103f740300ull;
    f->st.ubo_size = 6192;
    f->st.vb_n = 3;
    f->st.tex_n = 1;
    nvk_env_fill(&f->pc, &f->env);
}

// 生产口径的“这次 draw 的规范身份”。返回 nvk_input_identity 的码（0 可用 / -2 缺源）。
static int identity_of(const struct fixture *f, const struct s2a_compile_graphics_src *gfx,
                       struct nvk_src_ids *ids, uint8_t *buf, size_t *len, uint8_t sha[32]) {
    return nvk_input_identity(&f->st, &f->pc, &f->env, gfx, NULL, 0, ids, buf, len, sha);
}

static int same_bytes(const uint8_t *a, const uint8_t *b, size_t n) { return !memcmp(a, b, n); }

int main(void) {
    build_source(0, 1);
    build_source(1, 2);
    CHECK(memcmp(g_key[0], g_key[1], 8) != 0, "fixtures have distinct stage keys");
    CHECK(s2a_source_keep(g_key[0], 0, g_code[0], CODE_BYTES, g_ctl[0], S2A_SOURCE_CONTROL_BYTES) == 0,
          "register vs source at capture time");
    CHECK(s2a_source_keep(g_key[1], 1, g_code[1], CODE_BYTES, g_ctl[1], S2A_SOURCE_CONTROL_BYTES) == 0,
          "register fs source at capture time");

    struct fixture f;
    fixture_init(&f);
    struct s2a_compile_graphics_src gfx;
    memset(&gfx, 0, sizeof gfx);
    int complete = 1;
    nvk_compile_facts_fill(&gfx, &f.st, &f.pc, &complete);
    CHECK(complete == 1, "baseline attachment facts are complete");
    {
        // 压缩底图经“块=像素”的无压缩视图渲染（bcrt 影子）：编译事实必须按视图格式给出
        // fragmentOutputTypes（之前压缩格式无类型 → 请求缺字段被编译器拒绝）。
        struct fixture b;
        memcpy(&b, &f, sizeof b);
        b.st.rt[0].format = VK_FORMAT_BC4_UNORM_BLOCK;
        b.st.rt[0].nvn_format = 0x2C;   // NVN RGBA16UI（视图覆盖）
        b.st.rt[0].view_format = 0x2C;
        struct s2a_compile_graphics_src bgfx;
        memset(&bgfx, 0, sizeof bgfx);
        int bcomplete = 1;
        nvk_compile_facts_fill(&bgfx, &b.st, &b.pc, &bcomplete);
        CHECK(bcomplete == 1, "bcrt attachment: colour type comes from the block-encoding view format");
    }

    // #1409：线上 graphicsState.depthMode 的消费端语义是 MinusOneToOne（GpuGraphicsState
    // DepthMode true = [-1,1]），不是 NVN 原生枚举值。生产端曾写 !=0（"near=0"），
    // 默认 MINUS_W 的游戏被读成 [0,1] → 跳过 z 注入 → clip 黑屏。
    CHECK(gfx.has_depth_mode == 1 && gfx.depth_mode == 0,
          "NEAR_IS_ZERO maps to wire depthMode=false (negative control: no z fixup injected)");
    {
        struct s2a_compile_graphics_src gz;
        memset(&gz, 0, sizeof gz);
        int zc = 1;
        s2a_nvn_depth_mode = 0;   // NVN_DEPTH_MODE_NEAR_IS_MINUS_W（NVN 默认）
        nvk_compile_facts_fill(&gz, &f.st, &f.pc, &zc);
        CHECK(gz.has_depth_mode == 1 && gz.depth_mode == 1,
              "NEAR_IS_MINUS_W maps to wire depthMode=true (MinusOneToOne)");
        s2a_nvn_depth_mode = 1;
    }

    static uint8_t base[S2A_INPUT_IDENTITY_MAX], other[S2A_INPUT_IDENTITY_MAX];
    size_t base_len = 0, other_len = 0;
    uint8_t base_sha[32], other_sha[32];
    struct nvk_src_ids ids;
    memset(&ids, 0, sizeof ids);
    int rc = identity_of(&f, &gfx, &ids, base, &base_len, base_sha);
    CHECK(rc == 0, "baseline identity is available");
    CHECK(base_len > 0 && base_len < sizeof base, "baseline identity is bounded");
    CHECK(ids.present == 0x3, "both stages carry a full source identity");
    CHECK(ids.code_bytes[0] == CODE_BYTES && ids.control_bytes[1] == S2A_SOURCE_CONTROL_BYTES,
          "source identity carries the real lengths");

    struct nvk_id_key base_key;
    nvk_id_key_fill(&base_key, &f.st, &f.pc, &f.env);
    struct nvk_id_memo memo;
    memset(&memo, 0, sizeof memo);
    nvk_id_memo_store(&memo, &base_key, &f.st, 0x1234, 0);
    CHECK(nvk_id_memo_match(&memo, &base_key, &f.st) == 1, "memo matches its own baseline");

    // 对照：绘制参数变化既不改变身份，也不改变备忘键（备忘只是“事实没变就不重算”）。
    {
        struct fixture d = f;
        d.st.count = 1;
        d.st.instances = 7;
        d.st.first = 12;
        d.st.vp_x = 3.5f;
        d.st.ubo_addr = 0xdeadbeefull;
        d.st.tex_n = 0;
        d.st.vb_n = 0;
        struct s2a_compile_graphics_src dg; memset(&dg, 0, sizeof dg);
        int dc = 1;
        nvk_compile_facts_fill(&dg, &d.st, &d.pc, &dc);
        struct nvk_src_ids dids; memset(&dids, 0, sizeof dids);
        other_len = 0;
        CHECK(identity_of(&d, &dg, &dids, other, &other_len, other_sha) == 0 &&
              other_len == base_len && same_bytes(base, other, base_len),
              "draw parameters are not part of the content identity");
        struct nvk_id_key dk;
        nvk_id_key_fill(&dk, &d.st, &d.pc, &d.env);
        CHECK(nvk_id_memo_match(&memo, &dk, &d.st) == 1, "draw parameters are not part of the memo key");
    }

    // Per-NVN-stage storage state: compute never poisons graphics identity;
    // unbinding one graphics slot cannot erase another stage's binding.
    {
        struct fixture m = f;
        struct s2a_compile_graphics_src g;
        struct nvk_id_key k;
        int complete;
        m.st.ssbo_bound[5] = 1u << 7;
        m.st.ssbo[5][7].addr = 0x5000;
        memset(&g, 0, sizeof g);
        nvk_compile_facts_fill(&g, &m.st, &m.pc, &complete);
        nvk_id_key_fill(&k, &m.st, &m.pc, &m.env);
        CHECK(g.has_unaligned_ssbo && !g.unaligned_ssbo && !k.ssbo_bound,
              "compute stage 5 storage is independent of graphics");
        m.st.ssbo_bound[4] = 1u << 15;
        m.st.ssbo[4][15].addr = 0x4000;
        memset(&g, 0, sizeof g);
        nvk_compile_facts_fill(&g, &m.st, &m.pc, &complete);
        nvk_id_key_fill(&k, &m.st, &m.pc, &m.env);
        CHECK(!g.has_unaligned_ssbo && k.ssbo_bound,
              "NVN fragment stage 4 slot 15 is retained");
        m.st.ssbo_bound[0] = 1;
        m.st.ssbo_bound[4] = 0;
        m.st.ssbo[4][15].addr = 0;
        memset(&g, 0, sizeof g);
        nvk_compile_facts_fill(&g, &m.st, &m.pc, &complete);
        nvk_id_key_fill(&k, &m.st, &m.pc, &m.env);
        CHECK(!g.has_unaligned_ssbo && k.ssbo_bound,
              "unbinding fragment does not erase vertex storage binding");
        m.st.ssbo_bound[0] = 0;
        memset(&g, 0, sizeof g);
        nvk_compile_facts_fill(&g, &m.st, &m.pc, &complete);
        nvk_id_key_fill(&k, &m.st, &m.pc, &m.env);
        CHECK(g.has_unaligned_ssbo && !k.ssbo_bound,
              "last graphics unbind restores absence even with compute bound");
    }

    // #1398：hasUnalignedStorageBuffer 的来源 = 已绑定 graphics SSBO 地址对
    // minStorageBufferOffsetAlignment 的对齐。对齐→false；不齐→true；没绑定→false；
    // 有绑定但没有对齐来源（0）时不能伪造 false，事实必须缺失（请求报缺口）。
    {
        struct fixture m = f;
        struct s2a_compile_graphics_src g;
        struct nvk_id_key k;
        int complete;
        m.pc.storage_buffer_offset_alignment = 16;

        memset(&g, 0, sizeof g);
        nvk_compile_facts_fill(&g, &m.st, &m.pc, &complete);
        CHECK(g.has_unaligned_ssbo && !g.unaligned_ssbo,
              "no graphics SSBO -> hasUnalignedStorageBuffer=false");

        m.st.ssbo_bound[4] = 1u << 7;
        m.st.ssbo[4][7].addr = 0x2000;   // 16 对齐
        memset(&g, 0, sizeof g);
        nvk_compile_facts_fill(&g, &m.st, &m.pc, &complete);
        nvk_id_key_fill(&k, &m.st, &m.pc, &m.env);
        CHECK(g.has_unaligned_ssbo && !g.unaligned_ssbo,
              "aligned SSBO address -> hasUnalignedStorageBuffer=false");
        CHECK(k.ssbo_unaligned_known && !k.ssbo_unaligned,
              "memo key carries the aligned fact");

        struct nvk_id_memo um;
        memset(&um, 0, sizeof um);
        nvk_id_memo_store(&um, &k, &m.st, 0x2211, 0);
        m.st.ssbo[4][7].addr = 0x2004;   // 同一 binding，地址不齐
        memset(&g, 0, sizeof g);
        nvk_compile_facts_fill(&g, &m.st, &m.pc, &complete);
        nvk_id_key_fill(&k, &m.st, &m.pc, &m.env);
        CHECK(g.has_unaligned_ssbo && g.unaligned_ssbo,
              "unaligned SSBO address -> hasUnalignedStorageBuffer=true");
        CHECK(k.ssbo_unaligned_known && k.ssbo_unaligned,
              "memo key carries the unaligned fact");
        CHECK(nvk_id_memo_match(&um, &k, &m.st) == 0,
              "alignment change invalidates the memo key");

        // 负控：绑定存在、对齐来源缺失 → 事实缺失，不能按 0 或 false 猜。
        // 同一地址在“有来源且对齐”时是已知 false；未知与 false 不能混为一谈。
        m.st.ssbo[4][7].addr = 0x2000;
        m.pc.storage_buffer_offset_alignment = 0;
        memset(&g, 0, sizeof g);
        nvk_compile_facts_fill(&g, &m.st, &m.pc, &complete);
        nvk_id_key_fill(&k, &m.st, &m.pc, &m.env);
        CHECK(!g.has_unaligned_ssbo && !k.ssbo_unaligned_known,
              "bound SSBO without alignment source stays unknown");
        CHECK(nvk_id_memo_match(&um, &k, &m.st) == 0,
              "unknown alignment cannot reuse the aligned memo");
    }

    // 事实变更表：凡是改变编译请求的事实，都必须改变规范身份与 P1 备忘键。
    // ID_SAME_OK 的少数项（颜色槽未绑定 vs 绑了 UNORM）在“编译器输入”上确实相同
    // （fragmentOutputTypes 都是 Float）；备忘仍按原始附件事实区分，绝不因此误命中。
    enum { ID_DIFF = 0, ID_SAME_OK = 1, ID_UNAVAILABLE = 2 };
    static const struct { const char *what; int expect; } cases[] = {
        { "vertex attribute Float->Uint (a922d636 反例)", ID_DIFF },
        { "color attachment format Unorm->Uint", ID_DIFF },
        { "color attachment slot unbound (depth-only)", ID_SAME_OK },
        { "color attachment object untrusted (magic)", ID_DIFF },
        { "SSBO bound (unaligned requirement presence)", ID_DIFF },
        { "constantBufferUse", ID_DIFF },
        { "stage key (no source under the new key)", ID_UNAVAILABLE },
        { "translator closure", ID_DIFF },
        { "shader draw parameters capability", ID_DIFF },
        { "texture pool capacity", ID_DIFF },
        { "sampler pool capacity", ID_DIFF },
        { "transform feedback", ID_DIFF },
        { "primitive topology", ID_DIFF },
        { "rt_count", ID_DIFF },
        { "bound state object (dual-source blend)", ID_DIFF },
        { "ubo_use_overflow", ID_DIFF },
        { "direct ABI", ID_DIFF },
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        struct fixture m = f;
        switch (i) {
            case 0: m.st.vattr_fmt[0] = 0x3; break;                       // Float -> Uint
            case 1: m.st.rt[0].format = VK_FORMAT_R8G8B8A8_UINT; break;    // Float -> Uint
            case 2: m.st.rt[0].key = 0; break;                             // 合法未绑定槽（depth-only）
            case 3: m.st.rt[0].obj_magic = 0; break;                       // 快照丢失：格式不可信
            case 4: m.st.ssbo_bound[4] = 1u << 7; m.st.ssbo[4][7].addr = 0x2000; break;                        // 绑定了 SSBO
            case 5: m.st.ubo_use[1] = 0; break;
            case 6: m.st.keys[1][3] ^= 0x40; break;                        // 没有对应源 → 身份不可用
            case 7: m.pc.translator_closure = "nvn-00000000"; break;
            case 8: m.pc.shader_draw_parameters = 0; break;
            case 9: m.st.tex_pool_n = 4096; break;
            case 10: m.st.samp_pool_n = 64; break;
            case 11: m.st.tf_enabled = 1; break;
            case 12: m.st.prim = 0x1; break;
            case 13: m.st.rt_count = 2; break;
            case 14: m.st.state_obj[0][0] = 0x80u; m.st.state_obj[0][1] = 0; break;   // blend_st.src_rgb = 0x10 (SRC1)
            case 15: m.st.ubo_use_overflow = 1; break;
            case 16: m.pc.direct_abi = 6; break;
        }
        nvk_env_fill(&m.pc, &m.env);
        struct s2a_compile_graphics_src mg; memset(&mg, 0, sizeof mg);
        int mc = 1;
        nvk_compile_facts_fill(&mg, &m.st, &m.pc, &mc);
        struct nvk_src_ids mids; memset(&mids, 0, sizeof mids);
        other_len = 0;
        int mrc = identity_of(&m, &mg, &mids, other, &other_len, other_sha);
        if (cases[i].expect == ID_UNAVAILABLE) {
            CHECK(mrc == -2, cases[i].what);
        } else if (cases[i].expect == ID_DIFF) {
            CHECK(mrc == 0 && (other_len != base_len || !same_bytes(base, other, base_len)), cases[i].what);
        } else {
            CHECK(mrc == 0 && other_len == base_len && same_bytes(base, other, base_len), cases[i].what);
        }
        if (mrc == 0) {
            struct nvk_id_key mk;
            nvk_id_key_fill(&mk, &m.st, &m.pc, &m.env);
            CHECK(nvk_id_memo_match(&memo, &mk, &m.st) == 0,
                  "P1 memo must not match when the draw facts changed");
        } else {
            struct nvk_id_key mk;
            nvk_id_key_fill(&mk, &m.st, &m.pc, &m.env);
            CHECK(nvk_id_memo_match(&memo, &mk, &m.st) == 0,
                  "P1 memo must not match when the content identity is unavailable");
        }
    }

    // profile 原文按 (session, generation) 固化：provider 在同一代里给同一份 profile，
    // 摘要缓存是这一合同的一部分（换 profile 必须换 generation）。这里固定该行为，避免
    // 有人把“同代换 profile”当成可命中的输入。
    {
        struct fixture m = f;
        m.pc.profile_json = "{\"profileHash\":\"sha256-other\"}";
        nvk_env_fill(&m.pc, &m.env);
        CHECK(m.env.have_profile && !memcmp(m.env.profile_sha, f.env.profile_sha, 32),
              "profile text is pinned by (session, generation)");
        m.pc.generation = f.pc.generation + 1;
        nvk_env_fill(&m.pc, &m.env);
        CHECK(memcmp(m.env.profile_sha, f.env.profile_sha, 32) != 0,
              "a new generation re-reads the profile text");
    }

    // 反例（F4.3）：同一短 key、不同内容。存储拒绝这次登记并把 key 标成语义歧义，
    // 身份因此不可用——本次绘制不做缓存查找，不能静默复用先前那份程序。
    {
        uint8_t sink[8];
        memcpy(sink, g_key[0], 8);
        // 用另一份内容伪造相同的短 key：keep 必须拒绝。
        CHECK(s2a_source_keep(sink, 0, g_code[1], CODE_BYTES, g_ctl[1], S2A_SOURCE_CONTROL_BYTES) != 0,
              "a different content cannot be stored under the same short key");
        struct s2a_compile_graphics_src g2; memset(&g2, 0, sizeof g2);
        int c2 = 1;
        nvk_compile_facts_fill(&g2, &f.st, &f.pc, &c2);
        struct nvk_src_ids i2; memset(&i2, 0, sizeof i2);
        other_len = 0;
        CHECK(identity_of(&f, &g2, &i2, other, &other_len, other_sha) == -2,
              "forced short-key collision makes the identity unavailable (no silent reuse)");
    }

    // 缺源（从未登记 / 已淘汰）：身份不可用，绝不能只按短 key 编码。
    {
        s2a_source_clear();
        struct s2a_compile_graphics_src g3; memset(&g3, 0, sizeof g3);
        int c3 = 1;
        nvk_compile_facts_fill(&g3, &f.st, &f.pc, &c3);
        struct nvk_src_ids i3; memset(&i3, 0, sizeof i3);
        other_len = 0;
        CHECK(identity_of(&f, &g3, &i3, other, &other_len, other_sha) == -2,
              "missing full source snapshot means no content identity (accurate failure)");
        CHECK(i3.missing_stage == 0 && !memcmp(i3.missing_key, g_key[0], 8),
              "both stages missing: the diagnostic names the first checked stage (VS) and its key");
        // 只登记 VS：缺源诊断必须指向 FS，不能笼统报“缺源”。
        CHECK(s2a_source_keep(g_key[0], 0, g_code[0], CODE_BYTES, g_ctl[0], S2A_SOURCE_CONTROL_BYTES) == 0,
              "register only the VS source");
        struct nvk_src_ids only_vs;
        memset(&only_vs, 0, sizeof only_vs);
        other_len = 0;
        CHECK(identity_of(&f, &g3, &only_vs, other, &other_len, other_sha) == -2,
              "FS-only missing source still fails identity");
        CHECK(only_vs.missing_stage == 1 && !memcmp(only_vs.missing_key, g_key[1], 8),
              "missing-source diagnostic names FS and the FS key");
        s2a_source_clear();
        // 重新登记后身份恢复，且与基线逐字节相同（同一内容的身份是确定的）。
        CHECK(s2a_source_keep(g_key[0], 0, g_code[0], CODE_BYTES, g_ctl[0], S2A_SOURCE_CONTROL_BYTES) == 0 &&
              s2a_source_keep(g_key[1], 1, g_code[1], CODE_BYTES, g_ctl[1], S2A_SOURCE_CONTROL_BYTES) == 0,
              "re-register the same sources");
        struct fixture r;
        fixture_init(&r);
        struct s2a_compile_graphics_src rg; memset(&rg, 0, sizeof rg);
        int rcv = 1;
        nvk_compile_facts_fill(&rg, &r.st, &r.pc, &rcv);
        CHECK(identity_of(&r, &rg, &ids, other, &other_len, other_sha) == 0 &&
              other_len == base_len && same_bytes(base, other, base_len),
              "same captured bytes produce the same identity again");
    }


    // #1388：顶点属性类型表必须覆盖 32 位整数 / I2F-UI2F / 归一化变体；未支持格式仍为 NULL。
    {
        struct {
            uint32_t fmt;
            const char *want;
        } cases[] = {
            {0x03, "Uint"}, {0x0B, "Uint"}, {0x08, "Uint"}, {0x0F, "Uint"}, {0x14, "Uint"},
            {0x17, "Uint"}, {0x1B, "Uint"}, {0x20, "Uint"}, {0x23, "Uint"}, {0x27, "Uint"},
            {0x2C, "Uint"}, {0x2F, "Uint"}, {0x3E, "Uint"},
            {0x04, "Sint"}, {0x0C, "Sint"}, {0x09, "Sint"}, {0x10, "Sint"}, {0x15, "Sint"},
            {0x18, "Sint"}, {0x1C, "Sint"}, {0x21, "Sint"}, {0x24, "Sint"}, {0x28, "Sint"},
            {0x2D, "Sint"}, {0x30, "Sint"},
            {0x00, "Float"}, {0x01, "Float"}, {0x29, "Float"}, {0x3D, "Float"}, {0x3F, "Float"},
            {0x51, "Float"}, {0x57, "Float"}, {0x5D, "Float"}, {0x68, "Float"},
            {0x69, "Float"}, {0x9A, "Float"},
            {0x6A, "Sint"},
            {0x6B, "Float"}, {0x6C, "Float"},
            {0x37, "Float"}, {0x95, "Float"}, {0x96, "Float"}, {0x97, "Float"},
            {0x98, "Float"}, {0x99, "Float"}, {0x9B, "Float"}, {0x9C, "Float"},
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            struct fixture a = f;
            struct s2a_compile_graphics_src g;
            int complete = 1;
            for (int k = 0; k < 32; k++) a.st.vattr_fmt[k] = 0x01;   // Float
            a.st.vattr_fmt[0] = cases[i].fmt;
            memset(&g, 0, sizeof g);
            nvk_compile_facts_fill(&g, &a.st, &a.pc, &complete);
            if (!g.attribute_types[0] || strcmp(g.attribute_types[0], cases[i].want)) {
                printf("FAIL: vertex format 0x%X -> %s (want %s)\n", cases[i].fmt,
                       g.attribute_types[0] ? g.attribute_types[0] : "NULL", cases[i].want);
                fails++;
            }
        }
        // 负控：旧表漏掉的格式如果仍返回 NULL，上面的正例就会红。这里显式列出旧表缺口，
        // 证明用例真的覆盖了 #1388，而不是只测已映射的格式。
        static const uint32_t legacy_missing[] = {0x0B, 0x0C, 0x17, 0x18, 0x51, 0x69, 0x9A,
                                                  0x6A, 0x6B, 0x6C, 0x37, 0x95, 0x9C};
        for (size_t i = 0; i < sizeof legacy_missing / sizeof legacy_missing[0]; i++) {
            struct fixture a = f;
            struct s2a_compile_graphics_src g;
            int complete = 1;
            for (int k = 0; k < 32; k++) a.st.vattr_fmt[k] = 0x01;
            a.st.vattr_fmt[0] = legacy_missing[i];
            memset(&g, 0, sizeof g);
            nvk_compile_facts_fill(&g, &a.st, &a.pc, &complete);
            CHECK(g.attribute_types[0] != NULL, "negative control: pre-fix gap is now mapped");
        }
        static const uint32_t unsupported[] = {0x31, 0x41, 0xFF};
        for (size_t i = 0; i < sizeof unsupported / sizeof unsupported[0]; i++) {
            struct fixture a = f;
            struct s2a_compile_graphics_src g;
            int complete = 1;
            for (int k = 0; k < 32; k++) a.st.vattr_fmt[k] = 0x01;
            a.st.vattr_fmt[0] = unsupported[i];
            memset(&g, 0, sizeof g);
            nvk_compile_facts_fill(&g, &a.st, &a.pc, &complete);
            CHECK(g.attribute_types[0] == NULL, "unsupported vertex format still reports a gap");
        }
    }

    // ---- nvk_texture_facts_fill：每个在场阶段的 32 个组合槽都出一条事实 ----
    // 回归点（8E Wonder direct 崩溃）：片元 shader 引用 handle=26（组合槽 9），记录里该槽
    // 没有可解析的绑定 → textures[] 里没有 (fs,26,-1) 事实 → QueryTextureCoordNormalized
    // MISSING_FACT → compile_fn rc=-1 → draw program not available → SIGABRT。
    // 语义对齐 Ryujinx TextureBindingsManager.GetTextureDescriptor：未写槽条目=0（池局部 0），
    // 池内未注册按全零 TIC 解码 {1d, 不归一化}，池外 id 按上游显式默认 {2d, 归一化}。
    {
        memset(g_reg, 0, sizeof g_reg);
        // 池基址 100、容量 200：绝对 id 100..299 在池内。
        struct s2a_record_draw_state ts;
        memset(&ts, 0, sizeof ts);
        ts.stages = 0x2;                    // 只有 fs
        ts.tex_pool_base = 100;
        ts.tex_pool_n = 200;
        struct nvk_texture_set set;

        // 正例 1：槽 9 已绑定、注册过 2D/RGBA8 → (fs,26,-1) 真实事实。
        g_reg[142] = (struct reg_desc){ 1, NVN_FORMAT_RGBA8, NVN_TEXTURE_TARGET_2D, 1 };
        ts.tex_present[1][9] = 1;
        ts.tex_handle[1][9] = 142 | (7ull << 20);   // tid=142, sid=7
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        CHECK(set.count == 32, "fs stage emits one fact per combined slot");
        const struct s2a_compile_texture_src *t9 = NULL;
        for (int i = 0; i < set.count; i++)
            if (set.items[i].handle == 26) t9 = &set.items[i];
        CHECK(t9 && !strcmp(t9->stage, "fs") && t9->cbuf_slot == -1 &&
              !strcmp(t9->sampler_type, "2d") && !strcmp(t9->format, "R8G8B8A8Unorm") &&
              t9->normalized == 1 && t9->is_buffer == 0 && t9->separate == 0 &&
              t9->array_length == 1,
              "bound+registered slot 9 yields the real (fs,handle=26,cbufSlot=-1) fact");
        CHECK(set.unmapped_total == 0, "no unmapped slots in the baseline");

        // 正例 2：未绑定槽 → 表条目 0 → 池局部 id 0 → 池基址的注册描述符（上游 pool[0] 语义）。
        g_reg[100] = (struct reg_desc){ 1, NVN_FORMAT_RGBA8, NVN_TEXTURE_TARGET_2D, 1 };
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        const struct s2a_compile_texture_src *t0 = NULL;
        for (int i = 0; i < set.count; i++)
            if (set.items[i].handle == 8) t0 = &set.items[i];
        CHECK(t0 && !strcmp(t0->sampler_type, "2d") && !strcmp(t0->format, "R8G8B8A8Unorm") &&
              t0->normalized == 1, "unwritten slot resolves through pool-local descriptor 0");

        // 池内未注册（含未写槽→池局部 0、已绑但解析不了的 id）→ 全零 TIC 解码 {1d, 不归一化}。
        memset(g_reg, 0, sizeof g_reg);
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        CHECK(set.count == 32, "unresolvable slots still emit the zero-descriptor fact");
        const struct s2a_compile_texture_src *u0 = NULL;
        for (int i = 0; i < set.count; i++)
            if (set.items[i].handle == 8) u0 = &set.items[i];
        CHECK(u0 && !strcmp(u0->sampler_type, "1d") && !strcmp(u0->format, "Unknown") &&
              u0->normalized == 0 && u0->array_length == 1,
              "in-pool unresolvable decodes as the all-zero descriptor");

        // 池外 id（绑定句柄的 tid 超出池容量）→ 上游显式默认 {2d, 归一化}。
        ts.tex_handle[1][3] = 500 | (1ull << 20);   // tid=500：local=400 ≥ pool_n=200
        ts.tex_present[1][3] = 1;
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        const struct s2a_compile_texture_src *o3 = NULL;
        for (int i = 0; i < set.count; i++)
            if (set.items[i].handle == 8 + 2 * 3) o3 = &set.items[i];
        CHECK(o3 && !strcmp(o3->sampler_type, "2d") && o3->normalized == 1,
              "out-of-pool bound id takes the upstream invalid-id default");
        // 没有绑过纹理池（base=-1）：全部按池外。
        ts.tex_pool_base = -1;
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        const struct s2a_compile_texture_src *o9 = NULL;
        for (int i = 0; i < set.count; i++)
            if (set.items[i].handle == 26) o9 = &set.items[i];
        CHECK(o9 && !strcmp(o9->sampler_type, "2d") && o9->normalized == 1,
              "no bound pool: every unresolvable slot is out-of-pool");
        ts.tex_pool_base = 100;

        // rect 注册描述符：上游 Texture2DRect → 2d + 不归一化。
        memset(g_reg, 0, sizeof g_reg);
        g_reg[177] = (struct reg_desc){ 1, NVN_FORMAT_RGBA8, NVN_TEXTURE_TARGET_RECTANGLE, 1 };
        memset(&ts, 0, sizeof ts);
        ts.stages = 0x2; ts.tex_pool_base = 100; ts.tex_pool_n = 200;
        ts.tex_present[1][5] = 1;
        ts.tex_handle[1][5] = 177;
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        const struct s2a_compile_texture_src *r5 = NULL;
        for (int i = 0; i < set.count; i++)
            if (set.items[i].handle == 8 + 2 * 5) r5 = &set.items[i];
        CHECK(r5 && !strcmp(r5->sampler_type, "2d") && r5->normalized == 0,
              "rect texture fact is 2d and never normalized");

        // 负控 1：注册过但目标表达不了（BUFFER）→ 仍不出事实、进 unmapped 明细（准确失败保住）。
        memset(g_reg, 0, sizeof g_reg);
        g_reg[120] = (struct reg_desc){ 1, NVN_FORMAT_RGBA8, NVN_TEXTURE_TARGET_BUFFER, 1 };
        memset(&ts, 0, sizeof ts);
        ts.stages = 0x2; ts.tex_pool_base = 100; ts.tex_pool_n = 200;
        ts.tex_present[1][2] = 1;
        ts.tex_handle[1][2] = 120;
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        CHECK(set.count == 31 && set.unmapped_total == 1,
              "buffer texture stays a gap: no fact, one unmapped entry");
        CHECK(set.unmapped[0].stage == 1 && set.unmapped[0].slot == 2 &&
              set.unmapped[0].id == 120 && set.unmapped[0].nvn_target == NVN_TEXTURE_TARGET_BUFFER,
              "unmapped entry records the real slot/id/target");

        // 负控 2：UI2F 注册格式 → 同样不出事实（不静默当 Uint）。
        memset(g_reg, 0, sizeof g_reg);
        g_reg[130] = (struct reg_desc){ 1, NVN_FORMAT_RGBA8_UI2F, NVN_TEXTURE_TARGET_2D, 1 };
        ts.tex_handle[1][2] = 130;
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        CHECK(set.count == 31 && set.unmapped_total == 1,
              "UI2F stays a gap, not silently Uint");

        // 句柄坐标抽查：handle=8+2*slot、cbufSlot=-1、stage 名 vs/fs 对应 NVN stage 0/1。
        memset(g_reg, 0, sizeof g_reg);
        memset(&ts, 0, sizeof ts);
        ts.stages = 0x3;                    // vs+fs
        ts.tex_pool_base = 100; ts.tex_pool_n = 200;
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        CHECK(set.count == 64, "vs+fs fill all 64 contract slots");
        int saw_vs = 0, saw_fs = 0;
        for (int i = 0; i < set.count; i++) {
            saw_vs += !strcmp(set.items[i].stage, "vs");
            saw_fs += !strcmp(set.items[i].stage, "fs");
            CHECK(set.items[i].handle == (uint32_t)(8 + 2 * (i % 32)) && set.items[i].cbuf_slot == -1,
                  "handle coordinates are 8+2*slot with cbufSlot -1");
        }
        CHECK(saw_vs == 32 && saw_fs == 32, "stage names follow NVN stage 0/1");
        // 无在场阶段 → 0 条。
        memset(&ts, 0, sizeof ts);
        nvk_texture_facts_fill(&ts, stub_tex_lookup, NULL, &set);
        CHECK(set.count == 0, "no active stages, no facts");
    }

    if (fails) { printf("nvn compile facts test: %d FAILED\n", fails); return 1; }
    printf("nvn compile facts test: ok (%zu B baseline identity, memo key %zu B)\n", base_len, sizeof base_key);
    return 0;
}

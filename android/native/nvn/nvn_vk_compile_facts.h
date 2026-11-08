// Draw 快照 → 编译事实/内容身份/P1 备忘键（纯计算，可在宿主回归里原样编译）。
//
// 这个单元是“查找与编译共用同一份输入”的唯一生产者：nvk_draw 只负责取真实快照、
// 查表、调用编译器和执行；事实推导、规范身份编码和内容身份备忘的判据都在这里，
// 回归测试因此能直接跑生产实现，而不是另抄一份模型。
//
// 判据：规范输入原文逐字节相等（s2a_input_identity_encode 的字节，不是短 stage key，
// 也不是 requestId/session）。备忘只是“这些事实一字未变时不再重算”的捷径，
// 它的键必须覆盖身份的每一个输入；缺一个字段就是一个误命中入口。
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "direct/compile_request.h"
#include "direct/texture_facts.h"
#include "vk_record.h"

#ifdef __cplusplus
extern "C" {
#endif

// 本局 transport 环境（profile 原文摘要 + translator closure）：一局一份，按 (session, generation) 缓存。
struct nvk_env {
    uint8_t profile_sha[32];
    // profile 里 needsFragmentOutputSpecialization：为假时片元输出类型不参与特化，
    // 身份键里就不能按 8 个类型名区分（否则“不同身份、相同产物”，实测占 42%）。
    int frag_out_specialization;
    uint64_t closure_hash;   // FNV-1a 64(closure 字节)；NULL 与空串分开编码
    int have_profile;
};

// 各阶段的完整源身份（与 Draw 快照的 keys 同序：第 i 项对应第 i 个置位的 NVN 阶段）。
// 短 stage key 只是 SHA-256 的前 8 字节；撞在同一 key 上的不同代码/控制段是合法字节组合，
// 只按短 key 编码就会把它们当成同一份输入。
struct nvk_src_ids {
    uint8_t present;            // bit i = 第 i 个置位阶段的源身份有效
    uint8_t missing_stage;      // 缺源时第一个失败的 NVN stage（0=VS,1=FS,...）；0xff=未缺
    uint8_t missing_key[8];     // 该失败阶段的短 key（诊断用）
    uint8_t sha[6][32];
    uint32_t code_bytes[6], control_bytes[6];
};

void nvk_env_fill(const struct s2a_direct_compile_context *pc, struct nvk_env *out);
uint64_t nvk_closure_hash(const char *s);
void nvk_sha256_bytes(const uint8_t *buf, size_t len, uint8_t sha[32]);

// 片元输出类型是否参与特化（由 profile 的 needsFragmentOutputSpecialization 决定，见 nvk_env_fill）。
// 默认 1 = 保持原行为；宿主测试不设它，语义不变。
void nvk_compile_facts_set_frag_out_specialization(int on);
int nvk_compile_facts_frag_out_specialization(void);

// Draw 快照 → graphicsState 事实。*complete 为 0 表示附件事实缺项（颜色槽没有可信格式），
// 调用方据此输出事实行并让编译器报 MISSING_FIELD；这里不补默认格式。
void nvk_compile_facts_fill(struct s2a_compile_graphics_src *gfx,
                            const struct s2a_record_draw_state *state,
                            const struct s2a_direct_compile_context *pc, int *complete);

// 规范内容身份。返回 0 = 可用；-1 = 编码失败/输入越规格；-2 = 缺完整源快照（不能证明内容相同）。
// ids 可为 NULL；非 NULL 时写回各阶段摘要与真实长度，供编译前核对被 pin 住的那份快照。
int nvk_input_identity(const struct s2a_record_draw_state *state,
                       const struct s2a_direct_compile_context *pc,
                       const struct nvk_env *env,
                       const struct s2a_compile_graphics_src *gfx,
                       const struct s2a_compile_texture_src *textures, int texture_count,
                       struct nvk_src_ids *ids,
                       uint8_t *buf, size_t *len, uint8_t sha[32]);

// ---- Draw 快照 → program.textures[] 事实 ----
// 注册表读回的一条真实纹理描述（事实所需的子集；完整结构在 mtl_vk_adapter.h s2a_vk_tex_facts）。
struct nvk_tex_desc {
    uint32_t nvn_format, nvn_target, layers;
};

// 契约上限 64 条；句柄坐标 handle = 8 + 2 * slot（组合纹理表 cbuf word 8 起，每槽 8 字节）。
#define NVK_TEXTURE_SET_MAX 64
#define NVK_TEXTURE_UNMAPPED_MAX 8
struct nvk_texture_set {
    struct s2a_compile_texture_src items[NVK_TEXTURE_SET_MAX];
    char fmt[NVK_TEXTURE_SET_MAX][S2A_TEX_FORMAT_MAX];
    char smp[NVK_TEXTURE_SET_MAX][S2A_TEX_SAMPLER_MAX];
    int count;
    // 注册表里有描述符但目标/格式映射不了的槽位（这些槽位不出事实，编译器按缺口准确失败）。
    // 只记前 NVK_TEXTURE_UNMAPPED_MAX 条明细；unmapped_total 记真实总数。
    int unmapped_total;
    struct { uint8_t stage, slot; uint32_t id, nvn_format, nvn_target, layers; } unmapped[NVK_TEXTURE_UNMAPPED_MAX];
};

typedef int (*nvk_tex_lookup_fn)(int id, struct nvk_tex_desc *out, void *opaque);

// 每个在场阶段的 32 个组合纹理槽都出一条事实，槽位语义对齐 Ryujinx TextureBindingsManager
// .GetTextureDescriptor：句柄表条目 = 绑定值（未写过的槽读 0 = 池局部纹理 id 0）；
// id → 已绑定纹理池的描述符（lookup 即注册表查询）。注册表解析不了时按上游既定答案给：
//   池内（含未绑槽的条目 0 → 池局部 0）= 该池槽内容对我们不可见 → 全零 TIC 解码
//     {target=0 → "1d", normalized=false}（全零 TextureDescriptor 的 target 枚举值是 Texture1D）；
//   池外 id = 上游显式默认 {Texture2D, "Coords normalized" → "2d", normalized=true}。
// 注册过但目标/格式映射不了（buffer 目标、UI2F/I2F 格式等不可表达组合）仍不出事实——
// 那是真实缺项，记在 set->unmapped[] 供诊断，编译器继续按 MISSING_FACT 准确失败。
void nvk_texture_facts_fill(const struct s2a_record_draw_state *state,
                            nvk_tex_lookup_fn lookup, void *opaque,
                            struct nvk_texture_set *set);

// Dispatch 快照 → program.textures[] 事实：NVN CS stage（5）的 32 个组合纹理槽各出一条，
// stage="cs"，句柄坐标 handle = 8 + 2 * slot 与图形同一坐标系；规则与上面完全相同。
void nvk_compute_texture_facts_fill(const struct s2a_record_dispatch_state *state,
                                    nvk_tex_lookup_fn lookup, void *opaque,
                                    struct nvk_texture_set *set);

// W2 仅观察原 facts 读取的注册元数据，不证明当前 descriptor pool 的活性。
#define NVK_W2_CAPSULE_API 1
struct nvk_w2_raw_registration {
    int present, view_present, view_complete;
    uint32_t format, target, layers;
    uint32_t view_format, view_target, view_layers;
};
struct nvk_w2_capsule;
struct s2a_w2_query;
int nvk_w2_capsule_claim(const struct s2a_compile_request_input *in, struct nvk_w2_capsule **out);
int nvk_w2_capsule_publish(struct nvk_w2_capsule *cap, const struct s2a_w2_query *query,
                          const uint8_t *error, size_t error_bytes);
// abandon 只能做原子撤销：worker 可在自己的锁下调用，不分配、不等待、不回调。
void nvk_w2_capsule_abandon(struct nvk_w2_capsule *cap, int reason);
void nvk_w2_capsule_release(struct nvk_w2_capsule *cap);
// 由 execute/run 真正返回的调用线程交接，增持本线程一次性回执；NULL 清旧回执。
void nvk_w2_capsule_returned(struct nvk_w2_capsule *cap);
void nvk_w2_diagnostic_init(void);
void nvk_w2_diagnostic_cancel(void);
void nvk_w2_diagnostic_resume(void);

// ---- P1 内容身份备忘的键 ----
// 下列事实覆盖规范身份的全部输入；绘制参数（count/first/instances/索引/视口/裁剪/顶点流/UBO 地址）
// 不参与身份，也不进键。所有字段先 memset，比较用整块 memcmp（没有未初始化 padding）。
struct nvk_rt_key {
    uint64_t key;          // 0 = 该颜色槽没有绑定纹理（合法）
    uint32_t format;       // 记录里的 VkFormat
    uint32_t nvn_format;   // 纹理表未解析时的 NVN 兜底格式
    uint32_t obj_magic;    // 'TEX0' 才可信；其他值是真实缺项
};

struct nvk_id_key {
    uint64_t session, generation, reggen, src_epoch, closure_hash;
    uint32_t prim, rt_count, stages, tex_pool_n, samp_pool_n;
    int32_t tex_pool_base;      // 未绑槽的事实按池局部 0 解析到注册表：基址不同就是不同事实来源
    uint32_t tf_enabled, ubo_overflow, state_seen, direct_abi, cb_draw_params, ssbo_bound;
    // hasUnalignedStorageBuffer 已推出时必须进键：同一组绑定地址在不同对齐下会得到
    // 不同事实，只比“有没有绑定”会让备忘误命中。
    uint32_t ssbo_unaligned, ssbo_unaligned_known;
    int depth_mode, origin_mode;
    uint32_t vattr_fmt[32];
    struct nvk_rt_key rt[8];
};

struct nvk_id_memo {
    uint64_t hash;        // 整键+状态表的廉价 64 位摘要：线性扫描时先比它，命中再逐字节比较
    struct nvk_id_key k;
    uint8_t keys[6][8];
    uint32_t ubo_use[6];
    uint8_t state_obj[6][0x18];
    uint8_t tex_present[6][32];
    uint64_t tex_handle[6][32];
    uint64_t serial;      // 0 = 空槽；与条目当前代号不等即视为未命中
    unsigned idx;
};

void nvk_id_key_fill(struct nvk_id_key *k, const struct s2a_record_draw_state *st,
                     const struct s2a_direct_compile_context *pc, const struct nvk_env *env);
int nvk_id_memo_match(const struct nvk_id_memo *m, const struct nvk_id_key *k,
                      const struct s2a_record_draw_state *st);
void nvk_id_memo_store(struct nvk_id_memo *m, const struct nvk_id_key *k,
                       const struct s2a_record_draw_state *st, uint64_t serial, unsigned idx);
uint64_t nvk_id_memo_hash(const struct nvk_id_key *k, const struct s2a_record_draw_state *st);

#ifdef __cplusplus
}
#endif

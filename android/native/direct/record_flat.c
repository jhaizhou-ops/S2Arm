// 命令流拍平：A2（延迟参数在“提交/拍平”时取进记录）+ A4（记录内引用重定位）。
// 分类与约束见 record_flat.h 顶部说明。纯 C、不建 Vulkan 对象、不分配 GPU 资源；单线程调用。
#include "record_flat.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bind_defer.h"
#include "nvn_obj.h"
#include "nvn2_cmd.h"   // OP_DLSS（记录内含 tex 快照指针，本模块明确拒绝拍平）

#define SNAP_OFF(T) ((sizeof(T) + 7) & ~(size_t)7)

// 生产侧由 mtl_vk_adapter.c 导出（guest CPU 地址直读）；宿主合同测试提供替身。
// 缺失时一律按“无法证明捕获”失败，不静默按 0 放行。
extern int s2a_vk_adapter_guest_read(uint64_t address, void *dst, size_t bytes) __attribute__((weak));
// GPU 地址 → 池 CPU 地址（hle_nvn.c；窗口外原样返回，与录制侧 GA() 同一语义）。
extern uint64_t nvn_ga2ca(uint64_t address) __attribute__((weak));

static int flat_read(uint64_t address, void *dst, size_t bytes) {
    if (!address || !dst || !bytes || !s2a_vk_adapter_guest_read) return -1;
    return s2a_vk_adapter_guest_read(address, dst, bytes);
}

static uint64_t flat_ga2ca(uint64_t address) { return nvn_ga2ca ? nvn_ga2ca(address) : address; }

static int flat_fail(char *why, size_t why_size, int code, const char *msg) {
    if (why && why_size) snprintf(why, why_size, "%s", msg);
    return code;
}

// ---- 拍平写入上下文：dst 固定（调用方自有）或模块自有可增长缓冲 ----
// owned=1 时记录还会 realloc，因此**不能**把地址直接写进记录：先登记（字段偏移, 快照偏移），take 时落地址。
struct flat_wr {
    const uint8_t *rec;
    size_t size;
    uint8_t *dst;
    int owned;          // 1 = dst 属于本模块的可增长缓冲
    unsigned char *why;
    size_t why_size;
};
struct flat_fix { size_t field_off, snap_off; };
static struct flat_fix *g_fix;
static size_t g_nfix, g_fix_cap;
static uint8_t *g_buf;
static size_t g_len, g_cap;

static int flat_fix_add(size_t field_off, size_t snap_off) {
    if (g_nfix == g_fix_cap) {
        size_t cap = g_fix_cap ? g_fix_cap * 2 : 64;
        struct flat_fix *q = (struct flat_fix *)realloc(g_fix, cap * sizeof *q);
        if (!q) return -1;   // 无法登记 = 无法保证地址正确：按失败返回，不静默写悬垂地址
        g_fix = q; g_fix_cap = cap;
    }
    g_fix[g_nfix].field_off = field_off;
    g_fix[g_nfix].snap_off = snap_off;
    g_nfix++;
    return 0;
}

// 记录内引用落地址：dst 固定时直接写；模块自有缓冲时只登记偏移，take 时再写（增长会 realloc）。
static int flat_point(struct flat_wr *w, const tex_t **field, tex_t *snap) {
    if (!w->owned) { *field = snap; return 0; }
    return flat_fix_add((size_t)((const uint8_t *)field - g_buf), (size_t)((const uint8_t *)snap - g_buf));
}

// 一条记录里对 tex_t 的引用只有两种来源（见 hle_nvn.c tex_snap）：
//   1) 录制时对象有效 → 记录内已有快照，指针指向本记录内快照区；
//   2) 录制时对象无效（游戏在录制与提交之间 finalize/重建）→ 指针指向 guest 对象本身，旧回放在回放
//      时再读一次。拍平后副本不再拥有源记录，二者都必须改写成“宿主持有的快照字节”：
//      记录内引用按字节复制到目标槽；guest 对象在所有权转移点读一次写进目标槽。
// 读不到 guest 对象时**不能**留下悬垂指针或伪造成功：这是“无法证明捕获”，整笔提交不得发布完成证明。
static int flat_tex_ref(const uint8_t *src_rec, size_t src_size, const void *ref,
                        tex_t *slot, char *why, size_t why_size) {
    if ((const uint8_t *)ref >= src_rec && (const uint8_t *)ref + sizeof(tex_t) <= src_rec + src_size) {
        memcpy(slot, ref, sizeof *slot);
        return 0;
    }
    if (flat_read((uint64_t)(uintptr_t)ref, slot, sizeof *slot))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_MEMORY,
                         "texture object referenced by the record is unreadable at ownership transfer "
                         "(cannot capture a self-held snapshot)");
    return 0;
}

// OP_SET_RT 紧凑记录（nvn_obj.h）：指针数组按槽序（非空颜色，再深度），快照区紧随视图区。
static int flat_set_rt(struct flat_wr *w) {
    const uint8_t *rec = w->rec;
    const size_t size = w->size;
    uint8_t *const dst = w->dst;
    char *const why = (char *)w->why;
    const size_t why_size = w->why_size;
    if (size < sizeof(op_hdr) + sizeof(p_set_rt_c))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "set-render-target payload too small");
    const p_set_rt_c *h = (const p_set_rt_c *)(rec + sizeof(op_hdr));
    if ((size_t)(size - sizeof(op_hdr)) < set_rt_payload(h))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "set-render-target payload shorter than its header");
    const uint32_t ntex = set_rt_ntex(h);
    const uint8_t *src_payload = rec + sizeof(op_hdr);
    uint8_t *dst_payload = dst + sizeof(op_hdr);
    const tex_t *const *src_pt = (const tex_t *const *)(src_payload + sizeof *h);
    const tex_t **dst_pt = (const tex_t **)(dst_payload + sizeof *h);
    tex_t *dst_snap = (tex_t *)(dst_payload + set_rt_snap_off(h));
    for (uint32_t i = 0; i < ntex; i++) {
        if (!src_pt[i]) continue;   // 未绑定：保持 NULL，与“已绑定但描述无效”区分
        if (flat_tex_ref(rec, size, src_pt[i], &dst_snap[i], why, why_size)) return S2A_RECORD_FLAT_MEMORY;
        if (flat_point(w, &dst_pt[i], &dst_snap[i])) return S2A_RECORD_FLAT_MEMORY;
    }
    return 0;
}

// OP_COPY_B2T / OP_COPY_T2B：单快照（SNAP_OFF 后 1 份 tex_t）。
static int flat_copy_b(struct flat_wr *w) {
    const uint8_t *rec = w->rec;
    const size_t size = w->size;
    uint8_t *const dst = w->dst;
    char *const why = (char *)w->why;
    const size_t why_size = w->why_size;
    if (size < sizeof(op_hdr) + sizeof(p_copy_b2t))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "copy payload too small");
    if ((size_t)(size - sizeof(op_hdr)) < SNAP_OFF(p_copy_b2t) + sizeof(tex_t))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "copy payload has no snapshot area");
    const p_copy_b2t *src = (const p_copy_b2t *)(rec + sizeof(op_hdr));
    p_copy_b2t *out = (p_copy_b2t *)(dst + sizeof(op_hdr));
    tex_t *slot = (tex_t *)(dst + sizeof(op_hdr) + SNAP_OFF(p_copy_b2t));
    if (src->tex) {
        if (flat_tex_ref(rec, size, src->tex, slot, why, why_size)) return S2A_RECORD_FLAT_MEMORY;
        if (flat_point(w, &out->tex, slot)) return S2A_RECORD_FLAT_MEMORY;
    }
    return 0;
}

// OP_COPY_T2T：两份快照（src 在前、dst 在后）。
static int flat_copy_t2t(struct flat_wr *w) {
    const uint8_t *rec = w->rec;
    const size_t size = w->size;
    uint8_t *const dst = w->dst;
    char *const why = (char *)w->why;
    const size_t why_size = w->why_size;
    if (size < sizeof(op_hdr) + sizeof(p_copy_t2t))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "texture-copy payload too small");
    if ((size_t)(size - sizeof(op_hdr)) < SNAP_OFF(p_copy_t2t) + 2 * sizeof(tex_t))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "texture-copy payload has no snapshot area");
    const p_copy_t2t *src = (const p_copy_t2t *)(rec + sizeof(op_hdr));
    p_copy_t2t *out = (p_copy_t2t *)(dst + sizeof(op_hdr));
    tex_t *slots = (tex_t *)(dst + sizeof(op_hdr) + SNAP_OFF(p_copy_t2t));
    if (src->src) {
        if (flat_tex_ref(rec, size, src->src, &slots[0], why, why_size)) return S2A_RECORD_FLAT_MEMORY;
        if (flat_point(w, &out->src, &slots[0])) return S2A_RECORD_FLAT_MEMORY;
    }
    if (src->dst) {
        if (flat_tex_ref(rec, size, src->dst, &slots[1], why, why_size)) return S2A_RECORD_FLAT_MEMORY;
        if (flat_point(w, &out->dst, &slots[1])) return S2A_RECORD_FLAT_MEMORY;
    }
    return 0;
}

// OP_CLEAR_TEX：单快照。
static int flat_clear_tex(struct flat_wr *w) {
    const uint8_t *rec = w->rec;
    const size_t size = w->size;
    uint8_t *const dst = w->dst;
    char *const why = (char *)w->why;
    const size_t why_size = w->why_size;
    if (size < sizeof(op_hdr) + sizeof(p_clear_tex))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "clear-texture payload too small");
    if ((size_t)(size - sizeof(op_hdr)) < SNAP_OFF(p_clear_tex) + sizeof(tex_t))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "clear-texture payload has no snapshot area");
    const p_clear_tex *src = (const p_clear_tex *)(rec + sizeof(op_hdr));
    p_clear_tex *out = (p_clear_tex *)(dst + sizeof(op_hdr));
    tex_t *slot = (tex_t *)(dst + sizeof(op_hdr) + SNAP_OFF(p_clear_tex));
    if (src->tex) {
        if (flat_tex_ref(rec, size, src->tex, slot, why, why_size)) return S2A_RECORD_FLAT_MEMORY;
        if (flat_point(w, &out->tex, slot)) return S2A_RECORD_FLAT_MEMORY;
    }
    return 0;
}

// OP_BIND_UBO / OP_BIND_SSBO 的 Deferred 版：记录里存的是 guest NVNbufferRange 元素的地址。
// 在所有权转移点把范围值取进记录（与普通绑定的记录形状一致），回放不再读 guest。
static int flat_bind_buf(struct flat_wr *w) {
    const uint8_t *rec = w->rec;
    const size_t size = w->size;
    uint8_t *const dst = w->dst;
    char *const why = (char *)w->why;
    const size_t why_size = w->why_size;
    if (size < sizeof(op_hdr) + sizeof(p_bind_buf))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "bind-buffer payload too small");
    const p_bind_buf *src = (const p_bind_buf *)(rec + sizeof(op_hdr));
    p_bind_buf *out = (p_bind_buf *)(dst + sizeof(op_hdr));
    if (!(src->stage & BIND_BUF_DEFER)) return 0;
    NVNbufferRange range;
    if (flat_read(src->addr, &range, sizeof range))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_MEMORY,
                         "deferred buffer range unreadable at ownership transfer");
    out->stage = (int32_t)((uint32_t)src->stage & ~(uint32_t)BIND_BUF_DEFER);
    out->addr = flat_ga2ca((uint64_t)(uintptr_t)range.address);
    out->size = (uint64_t)range.size;
    return 0;
}

static int flat_rd(void *opaque, uint64_t address, void *dst, size_t bytes) {
    (void)opaque;
    return flat_read(address, dst, bytes);
}

// OP_BIND_TEX / OP_BIND_SAMP / OP_BIND_IMG 的 Deferred 版：记录里存 guest 句柄数组地址 + 录制时的池基址。
// 在所有权转移点读一次句柄数组并按同一编码平移到池基址。解析/重基复用 bind_defer.c 的同一份实现
// （与回放侧历史读法逐字段一致），本模块只负责“在拍平时读”和把结果落成普通绑定记录。
static int flat_bind_handles(struct flat_wr *w) {
    const uint8_t *rec = w->rec;
    const size_t size = w->size;
    uint8_t *const dst = w->dst;
    char *const why = (char *)w->why;
    const size_t why_size = w->why_size;
    if (size < sizeof(op_hdr) + offsetof(p_bind_handles, h))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "bind-handles payload too small");
    const p_bind_handles *src = (const p_bind_handles *)(rec + sizeof(op_hdr));
    p_bind_handles *out = (p_bind_handles *)(dst + sizeof(op_hdr));
    if (!src->defer) return 0;
    p_bind_handles parsed;
    const char *why_s = NULL;
    int rc = s2a_bind_handles_parse(flat_rd, NULL, rec + sizeof(op_hdr), (uint32_t)(size - sizeof(op_hdr)),
                                    &parsed, &why_s);
    if (rc != S2A_BH_OK)
        return flat_fail(why, why_size, rc == S2A_BH_MEMORY ? S2A_RECORD_FLAT_MEMORY : S2A_RECORD_FLAT_INVALID,
                         why_s ? why_s : "deferred bind-handles record is invalid");
    for (int32_t i = 0; i < parsed.n; i++) out->h[i] = parsed.h[i];
    out->defer = 0;
    out->src = 0;
    return 0;
}

// OP_BIND_TEX1：单条组合纹理绑定；BIND_TEX1_AT 时句柄放在游戏命令内存的字里（游戏在录制后、提交前原地改写，
// Luigi's Mansion 3 每帧如此）。拍平时读一次该字，回放不再依赖游戏命令内存。
static int flat_bind_tex1(struct flat_wr *w) {
    const uint8_t *rec = w->rec;
    const size_t size = w->size;
    uint8_t *const dst = w->dst;
    char *const why = (char *)w->why;
    const size_t why_size = w->why_size;
    if (size < sizeof(op_hdr) + sizeof(p_bind_tex1))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "bind-texture record too small");
    const p_bind_tex1 *src = (const p_bind_tex1 *)(rec + sizeof(op_hdr));
    p_bind_tex1 *out = (p_bind_tex1 *)(dst + sizeof(op_hdr));
    if (!(src->slot & BIND_TEX1_AT)) return 0;
    if (size < sizeof(op_hdr) + sizeof(p_bind_tex1) + 8)
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "bind-texture record is missing its device word");
    uint64_t word_addr = 0;
    memcpy(&word_addr, rec + sizeof(op_hdr) + sizeof(p_bind_tex1), 8);
    uint64_t handle = 0;
    if (flat_read(word_addr, &handle, 8))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_MEMORY,
                         "bind-texture device word unreadable at ownership transfer");
    out->h = handle;
    out->slot = src->slot & ~BIND_TEX1_AT;
    return 0;
}

size_t s2a_record_flat_size(const uint8_t *record, size_t size) {
    (void)record;
    return size;   // 当前没有需要内联扩容的记录（延后推常量无 Vulkan 解码器，见头文件分类表）
}

// 一条记录的拍平：先整条复制（保留未知 opcode 的原样语义），再在副本上改引用。
// 返回 0 = 已拍平；负值 = 准确失败（调用方不得发布完成证明）。
static int flat_one(struct flat_wr *w) {
    if (!w->rec || !w->dst || w->size < sizeof(op_hdr))
        return flat_fail((char *)w->why, w->why_size, S2A_RECORD_FLAT_INVALID, "record too small");
    op_hdr h;
    memcpy(&h, w->rec, sizeof h);
    if (h.size < sizeof(op_hdr) || h.size != w->size || (h.size & 7u))
        return flat_fail((char *)w->why, w->why_size, S2A_RECORD_FLAT_INVALID,
                         "record header size does not match its bytes");
    memcpy(w->dst, w->rec, w->size);
    switch (h.op) {
        case OP_SET_RT:      return flat_set_rt(w);
        case OP_COPY_B2T:
        case OP_COPY_T2B:    return flat_copy_b(w);
        case OP_COPY_T2T:    return flat_copy_t2t(w);
        case OP_CLEAR_TEX:   return flat_clear_tex(w);
        case OP_BIND_UBO:
        case OP_BIND_SSBO:   return flat_bind_buf(w);
        case OP_BIND_TEX:
        case OP_BIND_SAMP:
        case OP_BIND_IMG:    return flat_bind_handles(w);
        case OP_BIND_TEX1:   return flat_bind_tex1(w);
        case OP_DLSS:
            // 记录内含 tex 快照指针，本后端没有解码器；不把悬垂引用带进拍平缓冲，明确拒绝。
            return flat_fail((char *)w->why, w->why_size, S2A_RECORD_FLAT_UNSUPPORTED,
                             "record carries internal texture snapshots but has no Vulkan decoder; refusing a dangling reference");
        default:
            // A1 表已逐类核对：其余记录不含指向记录内快照的指针。PUSH_CONST_PTR 的 data 指针属于
            // “延迟但本后端无解码器”，回放会准确拒绝该 opcode，不在这里改写。
            return 0;
    }
}

int s2a_record_flat_write(const uint8_t *record, size_t size, void *dst, char *why, size_t why_size) {
    if (why && why_size) why[0] = 0;
    struct flat_wr w = { record, size, (uint8_t *)dst, 0, (unsigned char *)why, why_size };
    return flat_one(&w);
}

// ---- 追加式拍平缓冲：生产路径（mtl_vk_shim.c）。地址在 take 时才落，避免增长导致的悬垂。----
void s2a_record_flat_reset(void) {
    g_len = 0;
    g_nfix = 0;
}

static int flat_grow(size_t need) {
    if (g_len + need <= g_cap) return 0;
    size_t cap = g_cap ? g_cap : 65536;
    while (cap < g_len + need) cap <<= 1;
    uint8_t *q = (uint8_t *)realloc(g_buf, cap);
    if (!q) return -1;   // OOM：准确失败（调用方不发布完成证明）
    g_buf = q; g_cap = cap;
    return 0;
}

int s2a_record_flat_append(const uint8_t *record, size_t size, char *why, size_t why_size) {
    if (why && why_size) why[0] = 0;
    if (!record || size < sizeof(op_hdr))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "record too small");
    op_hdr h;
    memcpy(&h, record, sizeof h);
    if (h.size < sizeof(op_hdr) || h.size != size || (h.size & 7u))
        return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "record header size does not match its bytes");
    const size_t need = s2a_record_flat_size(record, size);
    if (need < size) return flat_fail(why, why_size, S2A_RECORD_FLAT_INVALID, "record size shrank");
    if (flat_grow(need)) return flat_fail(why, why_size, S2A_RECORD_FLAT_MEMORY, "flatten buffer allocation failed");
    struct flat_wr w = { record, size, g_buf + g_len, 1, (unsigned char *)why, why_size };
    const int rc = flat_one(&w);
    if (rc) return rc;   // 失败不推进游标：调用方整笔提交作废
    g_len += need;
    return 0;
}

uint8_t *s2a_record_flat_take(size_t *len) {
    // 缓冲不再移动：此刻才把登记过的记录内引用写成真实地址。重复调用是幂等的（同一偏移重写同一值）。
    for (size_t i = 0; i < g_nfix; i++)
        *(const tex_t **)(void *)(g_buf + g_fix[i].field_off) = (const tex_t *)(const void *)(g_buf + g_fix[i].snap_off);
    uint8_t *b = g_buf;
    if (len) *len = g_len;
    g_buf = NULL; g_cap = 0; g_len = 0; g_nfix = 0;   // 所有权交给调用方（由它 free）
    return b;
}

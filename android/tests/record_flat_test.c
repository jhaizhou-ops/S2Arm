// 批次 1 / 模块 A 的宿主合同（A1/A2/A4）：命令流拍平后，
//   1) 记录内指向快照的指针必须落到宿主自有缓冲（源记录释放/改写后副本仍正确）；
//   2) Deferred 参数数组在拍平（命令数据所有权转移点）取一次，回放不再读 guest；
//   3) 拍不到的 guest 数据必须准确失败（整笔提交不发布完成证明），不能按 0 放行或留悬垂指针；
//   4) 非延迟记录与未知 opcode 原样透传（行为不变）。
//
// 只用生产的 record_flat.c + bind_defer.c 与 nvn_obj.h 的记录布局；不建 Vulkan 对象、不碰设备。
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "record_flat.h"
#include "nvn_obj.h"

#define SNAP_OFF(T) ((sizeof(T) + 7) & ~(size_t)7)

static int g_checks, g_failed;
#define CHECK(cond, ...) do { \
    g_checks++; \
    if (!(cond)) { g_failed++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
                   fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } \
} while (0)

// ---- guest 内存替身：地址 [0x1000, 0x1000+size) 直接映射本进程字节；其余地址不可读 ----
static uint8_t g_guest[8192];
int s2a_vk_adapter_guest_read(uint64_t address, void *dst, size_t bytes) {
    if (address < 0x1000 || address + bytes > 0x1000 + sizeof g_guest) return -1;
    memcpy(dst, g_guest + (address - 0x1000), bytes);
    return 0;
}
// 与录制侧 GA() 同接口：测试把 0x80001000 映射到 0x12345678，其余原样（窗口外原样返回）。
uint64_t nvn_ga2ca(uint64_t address) { return address == 0x80001000ull ? 0x12345678ull : address; }

static tex_t make_tex(uint64_t serial, uint32_t w, uint32_t h, uint32_t fmt) {
    tex_t t;
    memset(&t, 0, sizeof t);
    t.magic = MAGIC('T', 'E', 'X', 0);
    t.serial = serial;
    t.d.width = w;
    t.d.height = h;
    t.d.depth = 1;
    t.d.levels = 1;
    t.d.target = 1;
    t.d.format = (int)fmt;
    t.pool = (pool_t *)(uintptr_t)0x1000;
    return t;
}

// 模拟 hle_nvn.c SetRenderTargets 的紧凑记录：
//   color0 = 录制时有效（记录内快照）、color1 = 录制时无效（保留 guest 对象指针）、depth 有效（快照）。
static size_t build_set_rt(uint8_t *rec, const tex_t *snap0, uint64_t guest1_addr,
                           const tex_t *snap_depth) {
    p_set_rt r;
    memset(&r, 0, sizeof r);
    r.n = 2;
    r.color[0] = snap0;
    r.color[1] = (const tex_t *)(uintptr_t)guest1_addr;
    r.depth = snap_depth;
    size_t payload = set_rt_size(&r);
    op_hdr h = {OP_SET_RT, (uint32_t)(sizeof(op_hdr) + payload)};
    memcpy(rec, &h, sizeof h);
    p_set_rt_c *hc = set_rt_put(rec + sizeof h, &r);
    const tex_t **pt = (const tex_t **)(hc + 1);
    tex_t *snaps = (tex_t *)(rec + sizeof h + set_rt_snap_off(hc));
    memcpy(&snaps[0], snap0, sizeof *snap0);
    pt[0] = &snaps[0];
    pt[1] = (const tex_t *)(uintptr_t)guest1_addr;   // 记录时对象无效：与 tex_snap 一样保留 guest 指针
    memcpy(&snaps[2], snap_depth, sizeof *snap_depth);
    pt[2] = &snaps[2];
    return h.size;
}

static size_t build_copy_b2t(uint8_t *rec, const tex_t *snap) {
    size_t payload = SNAP_OFF(p_copy_b2t) + sizeof(tex_t);
    op_hdr h = {OP_COPY_B2T, (uint32_t)(sizeof(op_hdr) + payload)};
    memcpy(rec, &h, sizeof h);
    p_copy_b2t *r = (p_copy_b2t *)(rec + sizeof h);
    memset(r, 0, sizeof *r);
    tex_t *slot = (tex_t *)(rec + sizeof h + SNAP_OFF(p_copy_b2t));
    memcpy(slot, snap, sizeof *snap);
    r->tex = slot;
    r->row_stride = 64;
    return h.size;
}

static size_t build_clear_tex(uint8_t *rec, const tex_t *snap) {
    size_t payload = SNAP_OFF(p_clear_tex) + sizeof(tex_t);
    op_hdr h = {OP_CLEAR_TEX, (uint32_t)(sizeof(op_hdr) + payload)};
    memcpy(rec, &h, sizeof h);
    p_clear_tex *r = (p_clear_tex *)(rec + sizeof h);
    memset(r, 0, sizeof *r);
    tex_t *slot = (tex_t *)(rec + sizeof h + SNAP_OFF(p_clear_tex));
    memcpy(slot, snap, sizeof *snap);
    r->tex = slot;
    r->mask = 0xf;
    return h.size;
}

static size_t build_bind_buf_defer(uint8_t *rec, int op, uint64_t range_guest_addr) {
    op_hdr h = {(uint32_t)op, (uint32_t)(sizeof(op_hdr) + sizeof(p_bind_buf))};
    memcpy(rec, &h, sizeof h);
    p_bind_buf *b = (p_bind_buf *)(rec + sizeof h);
    b->stage = 1 | BIND_BUF_DEFER;
    b->index = 3;
    b->addr = range_guest_addr;
    b->size = 0;
    return h.size;
}

static size_t build_bind_handles_defer(uint8_t *rec, int op, int32_t stage, uint64_t handles_guest_addr,
                                       int32_t n, int32_t tbase, int32_t sbase) {
    size_t payload = offsetof(p_bind_handles, h) + 8u * (size_t)n + sizeof(p_bind_pool_bases);
    op_hdr h = {(uint32_t)op, (uint32_t)(sizeof(op_hdr) + payload)};
    memcpy(rec, &h, sizeof h);
    p_bind_handles *b = (p_bind_handles *)(rec + sizeof h);
    memset(b, 0, payload);
    b->stage = stage;
    b->first = 0;
    b->n = n;
    b->defer = 1;
    b->src = handles_guest_addr;
    p_bind_pool_bases bases = {tbase, sbase};
    memcpy(b->h + n, &bases, sizeof bases);
    return h.size;
}

static size_t build_bind_tex1_at(uint8_t *rec, uint64_t word_guest_addr) {
    op_hdr h = {OP_BIND_TEX1, (uint32_t)(sizeof(op_hdr) + sizeof(p_bind_tex1) + 8)};
    memcpy(rec, &h, sizeof h);
    p_bind_tex1 *b = (p_bind_tex1 *)(rec + sizeof h);
    memset(b, 0, sizeof *b + 8);
    b->stage = 1;
    b->slot = 5 | BIND_TEX1_AT;
    b->h = 0;
    memcpy((uint8_t *)b + sizeof *b, &word_guest_addr, 8);
    return h.size;
}

static int ptr_in(const void *p, const uint8_t *base, size_t n) {
    return (const uint8_t *)p >= base && (const uint8_t *)p < base + n;
}

int main(void) {
    static uint8_t src[4096], dst[4096];
    char why[192];

    // ---- A4.1 SET_RT：记录内快照重定位 + 录制时失效对象的 guest 指针在拍平时取成自有快照 ----
    {
        tex_t snap0 = make_tex(101, 64, 64, 0x2a);
        tex_t snapd = make_tex(202, 128, 128, 0x32);
        tex_t guest1 = make_tex(303, 256, 256, 0x2a);
        memcpy(g_guest + 0x400, &guest1, sizeof guest1);   // guest 地址 0x1400
        size_t n = build_set_rt(src, &snap0, 0x1400, &snapd);
        memset(dst, 0xAA, sizeof dst);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == 0, "set_rt flatten failed: %s", why);
        op_hdr *h = (op_hdr *)dst;
        const p_set_rt_c *hc = (const p_set_rt_c *)(dst + sizeof(op_hdr));
        const tex_t **pt = (const tex_t **)(hc + 1);
        const tex_t *snaps = (const tex_t *)(dst + sizeof(op_hdr) + set_rt_snap_off(hc));
        CHECK(h->size == n && h->op == OP_SET_RT, "set_rt header changed: op=%u size=%u want=%zu", h->op, h->size, n);
        CHECK((size_t)(h->size - sizeof(op_hdr)) >= set_rt_payload(hc), "set_rt payload shortened");
        CHECK(set_rt_ntex(hc) == 3, "set_rt ntex=%u want 3", set_rt_ntex(hc));
        for (uint32_t i = 0; i < 3; i++)
            CHECK(ptr_in(pt[i], dst, n), "set_rt pointer %u not in flat buffer (%p)", i, (const void *)pt[i]);
        CHECK(pt[0] == &snaps[0] && pt[2] == &snaps[2], "set_rt snapshots not at documented slots");
        CHECK(!memcmp(&snaps[0], &snap0, sizeof snap0), "set_rt color0 snapshot byte mismatch");
        CHECK(!memcmp(&snaps[1], &guest1, sizeof guest1), "set_rt guest object not captured at flat time");
        CHECK(snaps[1].serial == 303, "set_rt guest snapshot serial=%llu want 303", (unsigned long long)snaps[1].serial);
        CHECK(!memcmp(&snaps[2], &snapd, sizeof snapd), "set_rt depth snapshot byte mismatch");
        // 源记录/guest 对象在所有权转移后被释放或改写：副本必须不变。
        memset(src, 0, sizeof src);
        memset(g_guest + 0x400, 0x5A, sizeof guest1);
        CHECK(!memcmp(&snaps[0], &snap0, sizeof snap0), "set_rt copy depends on source record after flatten");
        CHECK(snaps[1].serial == 303 && snaps[1].d.width == 256,
              "set_rt copy depends on guest object after flatten");
    }

    // ---- A4.2 COPY_B2T / CLEAR_TEX：单快照重定位 ----
    {
        tex_t snap = make_tex(404, 32, 16, 0x2a);
        size_t n = build_copy_b2t(src, &snap);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == 0, "copy flatten failed: %s", why);
        const p_copy_b2t *r = (const p_copy_b2t *)(dst + sizeof(op_hdr));
        CHECK(ptr_in(r->tex, dst, n), "copy snapshot pointer not relocated");
        CHECK(!memcmp(r->tex, &snap, sizeof snap), "copy snapshot bytes mismatch");
        CHECK(r->row_stride == 64, "copy non-pointer field changed");
        memset(src, 0, sizeof src);
        CHECK(r->tex->serial == 404, "copy snapshot depends on source after flatten");

        n = build_clear_tex(src, &snap);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == 0, "clear flatten failed: %s", why);
        const p_clear_tex *c = (const p_clear_tex *)(dst + sizeof(op_hdr));
        CHECK(ptr_in(c->tex, dst, n), "clear snapshot pointer not relocated");
        CHECK(c->tex->serial == 404 && c->mask == 0xf, "clear snapshot/mask mismatch");
        CHECK(!memcmp(c->tex, &snap, sizeof snap), "clear snapshot bytes mismatch");
    }

    // ---- A4.3 拍不到的 guest 快照必须准确失败 ----
    {
        tex_t snap = make_tex(505, 8, 8, 0x2a);
        size_t n = build_set_rt(src, &snap, 0x90000000ull /* 不可读 */, &snap);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == S2A_RECORD_FLAT_MEMORY,
              "unreadable set_rt object must fail MEMORY, got otherwise (%s)", why);
        n = build_bind_buf_defer(src, OP_BIND_UBO, 0x90000000ull);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == S2A_RECORD_FLAT_MEMORY,
              "unreadable deferred range must fail MEMORY");
    }

    // ---- A2.1 延迟 UBO/SSBO：数组元素在拍平时取一次并做 GPU→CPU 换算 ----
    {
        NVNbufferRange range;
        range.address = 0x80001000ull;
        range.size = 0x1234;
        memcpy(g_guest + 0x100, &range, sizeof range);   // guest 地址 0x1100
        size_t n = build_bind_buf_defer(src, OP_BIND_UBO, 0x1100);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == 0, "defer ubo flatten failed: %s", why);
        const p_bind_buf *b = (const p_bind_buf *)(dst + sizeof(op_hdr));
        CHECK((b->stage & BIND_BUF_DEFER) == 0, "deferred marker not cleared (replay would read guest again)");
        CHECK(b->addr == 0x12345678ull, "deferred range address not captured/translated: %llx",
              (unsigned long long)b->addr);
        CHECK(b->size == 0x1234ull, "deferred range size=%llu want 0x1234", (unsigned long long)b->size);
        CHECK(b->index == 3, "deferred range index changed");
        // guest 数组改写后，拍平记录不变
        memset(g_guest + 0x100, 0, sizeof range);
        CHECK(b->addr == 0x12345678ull && b->size == 0x1234ull,
              "flattened range depends on guest array after flatten");
        n = build_bind_buf_defer(src, OP_BIND_SSBO, 0x1100);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == 0, "defer ssbo flatten failed: %s", why);
    }

    // ---- A2.2 延迟纹理/采样器句柄数组：拍平时读一次并按池基址平移 ----
    {
        uint64_t handles[2] = {0x105ull, 0x20300107ull};
        memcpy(g_guest + 0x200, handles, sizeof handles);   // guest 地址 0x1200
        size_t n = build_bind_handles_defer(src, OP_BIND_TEX, 1, 0x1200, 2, 0x100, 0x200);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == 0, "defer tex handles flatten failed: %s", why);
        const p_bind_handles *b = (const p_bind_handles *)(dst + sizeof(op_hdr));
        CHECK(b->defer == 0, "deferred handles marker not cleared");
        CHECK(b->src == 0, "deferred handles source address not cleared");
        CHECK(b->h[0] == 0x205ull, "handle[0]=%llx want 0x205", (unsigned long long)b->h[0]);
        uint64_t want1 = (0x107ull + 0x100ull) | ((0x203ull + 0x200ull) << 20);
        CHECK(b->h[1] == want1, "handle[1]=%llx want %llx", (unsigned long long)b->h[1],
              (unsigned long long)want1);
        CHECK(b->n == 2 && b->stage == 1 && b->first == 0, "handles record header changed");
        memset(g_guest + 0x200, 0, sizeof handles);
        CHECK(b->h[0] == 0x205ull && b->h[1] == want1, "flattened handles depend on guest array after flatten");
        // separate sampler：只加采样器池基址
        uint64_t samp = 0x300ull << 20;   // separate sampler 句柄 = id << 20（tid 0）
        memcpy(g_guest + 0x280, &samp, sizeof samp);
        n = build_bind_handles_defer(src, OP_BIND_SAMP, 1, 0x1280, 1, 0, 0x80);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == 0, "defer sampler flatten failed: %s", why);
        const p_bind_handles *sb = (const p_bind_handles *)(dst + sizeof(op_hdr));
        CHECK(sb->h[0] == ((0x300ull + 0x80ull) << 20), "separate sampler handle=%llx", (unsigned long long)sb->h[0]);
    }

    // ---- A2.3 BindTexture 单条（BIND_TEX1_AT）：设备字在拍平时取一次 ----
    {
        uint64_t word = 0x50abcull;
        memcpy(g_guest + 0x300, &word, sizeof word);   // guest 地址 0x1300
        size_t n = build_bind_tex1_at(src, 0x1300);
        CHECK(s2a_record_flat_write(src, n, dst, why, sizeof why) == 0, "bind_tex1 flatten failed: %s", why);
        const p_bind_tex1 *b = (const p_bind_tex1 *)(dst + sizeof(op_hdr));
        CHECK((b->slot & BIND_TEX1_AT) == 0, "BIND_TEX1_AT marker not cleared");
        CHECK(b->slot == 5, "bind_tex1 slot=%d want 5", b->slot);
        CHECK(b->h == 0x50abcull, "bind_tex1 handle=%llx want 0x50abc", (unsigned long long)b->h);
        memset(g_guest + 0x300, 0, sizeof word);
        CHECK(b->h == 0x50abcull, "bind_tex1 depends on guest word after flatten");
    }

    // ---- 行为不变：普通（非 Deferred）绑定与未知 opcode 原样透传 ----
    {
        // 普通句柄绑定：defer=0，记录内容一个字节都不变。
        memset(src, 0, sizeof src);
        size_t payload = offsetof(p_bind_handles, h) + 8u;
        op_hdr h = {OP_BIND_TEX, (uint32_t)(sizeof(op_hdr) + payload)};
        memcpy(src, &h, sizeof h);
        p_bind_handles *b = (p_bind_handles *)(src + sizeof h);
        b->stage = 1;
        b->n = 1;
        b->h[0] = 0x777ull;
        memcpy(dst, src, h.size);
        CHECK(s2a_record_flat_write(src, h.size, dst, why, sizeof why) == 0, "normal bind flatten failed: %s", why);
        CHECK(!memcmp(src, dst, h.size), "normal bind record was rewritten");
        // 未知 opcode（这里用 OP_COUNT_ 之后的 DLSS 同号以外的普通未知值）：原样拷贝透传。
        uint8_t raw[32];
        memset(raw, 0x3C, sizeof raw);
        op_hdr uh = {OP_COUNT_ + 5, (uint32_t)sizeof raw};
        memcpy(raw, &uh, sizeof uh);
        CHECK(s2a_record_flat_size(raw, sizeof raw) == sizeof raw, "flat size changed for unknown record");
        CHECK(s2a_record_flat_write(raw, sizeof raw, dst, why, sizeof why) == 0, "unknown record rejected: %s", why);
        CHECK(!memcmp(raw, dst, sizeof raw), "unknown record not passed through byte-identically");
        // 头部自相矛盾：准确失败
        CHECK(s2a_record_flat_write(raw, 8, dst, why, sizeof why) == S2A_RECORD_FLAT_INVALID,
              "malformed record must fail INVALID");
    }

    // ---- A2 寿命：追加式拍平缓冲（真机 2026-11-07 打出的缺陷）----
    // 一条命令链有上万条记录，缓冲必须增长（realloc）。若在追加时就把“快照地址”写进记录，后续增长会
    // 让该地址悬垂：真机表现为 rt 快照读成全零（snap_fmt=0x0 serial=0）→ fragmentOutputTypes 缺项 →
    // 首笔图形 draw 报红。正确做法是追加时登记偏移、定稿（take）时才落地址。这里是它的宿主判据。
    {
        uint8_t big_guest[256];
        memset(big_guest, 0x5A, sizeof big_guest);
        memcpy(g_guest, big_guest, sizeof big_guest);   // guest 0x1000 起：可读对象
        tex_t t0 = make_tex(0x11, 64, 64, 0x1a), td = make_tex(0x22, 64, 64, 0x05);
        static uint8_t rec[4096];
        const size_t n = build_set_rt(rec, &t0, 0x1000, &td);
        s2a_record_flat_reset();
        CHECK(s2a_record_flat_append(rec, n, why, sizeof why) == 0, "append of set-rt failed: %s", why);
        // 追加足够多的记录把缓冲推到远超初始容量，逼它 realloc（记录内容无关，只要合法）。
        static uint8_t filler[1024];
        memset(filler, 0, sizeof filler);
        for (int i = 0; i < 200; i++) {
            op_hdr fh = {OP_VIEWPORTS, (uint32_t)sizeof filler};
            memcpy(filler, &fh, sizeof fh);
            CHECK(s2a_record_flat_append(filler, sizeof filler, why, sizeof why) == 0, "append filler %d failed", i);
        }
        size_t flat_len = 0;
        uint8_t *flat = s2a_record_flat_take(&flat_len);
        CHECK(flat != NULL, "take returned no buffer");
        CHECK(flat_len >= n, "flattened length %zu shorter than the first record %zu", flat_len, n);
        if (flat) {
            const op_hdr *fh = (const op_hdr *)flat;
            CHECK(fh->op == OP_SET_RT && fh->size == n, "first flattened record is not the set-render-target");
            const p_set_rt_c *h = (const p_set_rt_c *)(flat + sizeof(op_hdr));
            const tex_t *const *pt = (const tex_t *const *)((const uint8_t *)h + sizeof *h);
            // 权威判据：定稿后记录内指针必须落在拍平缓冲内，且指向 magic='TEX0' 的快照（与回放读法一致）。
            CHECK((const uint8_t *)pt[0] >= flat && (const uint8_t *)pt[0] + sizeof(tex_t) <= flat + flat_len,
                  "snapshot pointer for slot 0 is outside the flattened buffer (dangling after growth)");
            if ((const uint8_t *)pt[0] >= flat && (const uint8_t *)pt[0] + sizeof(tex_t) <= flat + flat_len) {
                const tex_t *sn = pt[0];
                CHECK(sn->magic == MAGIC('T', 'E', 'X', 0), "slot 0 snapshot magic=0x%x (expected TEX0): all-zero snapshot?",
                      sn->magic);
                CHECK(sn->serial == 0x11, "slot 0 snapshot serial=%llu (expected 0x11)", (unsigned long long)sn->serial);
            }
            // 槽 1 是“录制时对象无效、按 guest 重读”的那一路：定稿后同样必须落在缓冲内且内容为 guest 字节。
            CHECK((const uint8_t *)pt[1] >= flat && (const uint8_t *)pt[1] + sizeof(tex_t) <= flat + flat_len,
                  "snapshot pointer for slot 1 is outside the flattened buffer");
            // 槽 2（深度）同样可读。
            CHECK((const uint8_t *)pt[2] >= flat && (const uint8_t *)pt[2] + sizeof(tex_t) <= flat + flat_len,
                  "depth snapshot pointer is outside the flattened buffer");
            free(flat);   // take 交出的所有权归调用方
        }
        s2a_record_flat_reset();
    }

    printf("record_flat: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}

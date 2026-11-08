// 资源身份账本 + VM 替页事务的实现。见 vk_resid.h 的职责说明。
// 这里只做「身份/代际/内容版本/在途引用」的记账与事务编排；真正的映射变更由注入的 ops 执行，
// 因此每个阶段的失败与回滚都能在宿主上确定性地复现。
#include "vk_resid.h"
#include <pthread.h>

#include <stdio.h>
#include <string.h>

#define RS_MAX_RANGES 256
#define RS_MAX_BACKINGS 256
#define RS_MAX_COMMITS 128
#define RS_PAGE 4096ull

struct rs_range {
    uint64_t addr, len;          // guest 地址范围（页对齐）
    uint64_t pool_id;            // 池身份
    uint64_t backing_id;         // 当前后备对象身份
    uint64_t gen;                // 映射代际：每次换底/重建 +1
    uint64_t content_version;    // 内容版本：写跟踪/更新 +1
    int state;                   // S2A_RES_FREE / LIVE / RETIRED
};

struct rs_commit {
    uint64_t seq;
    uint64_t backing_id;
    uint64_t addr, len;
    int used;
};

struct rs_backing {
    uint64_t id;
    int used;
};

static struct rs_range g_ranges[RS_MAX_RANGES];
static struct rs_commit g_commits[RS_MAX_COMMITS];
static struct rs_backing g_backs[RS_MAX_BACKINGS];
static int g_migrating;
static struct s2a_res_stats g_stats;

// UBO 快照槽（按写入序号判先后，回绕后同 seq 仍取后写的）
#define RS_UBO_SLOTS 64
#define RS_UBO_BYTES 256
// age = 全局单调写入序号：回绕到同一槽后只按 seq 挑会在“同 draw_seq 先后写两次”时选错
// （复核项 2：先写 0xAA 后写 0xBB 回绕到 0 号槽，解析会得 0xAA）；同 seq 用 age 定先后。
struct rs_ubo { uint64_t seq; uint64_t age; size_t len; uint8_t bytes[RS_UBO_BYTES]; int used; };
static struct rs_ubo g_ubo[RS_UBO_SLOTS];
static unsigned g_ubo_next;
static uint64_t g_ubo_age;


// 并发合同：本层入口会被绘制线程（lookup/ref_valid）、guest 线程（FlushMappedRange → note_write）、
// 帧完成点（ref_commit / complete / retire）与 VM owner 窗口（migrate）同时调用，所以**必须**有锁。
// 单把互斥锁保护全部账本状态；cleanup 属性保证任何 return 分支都解锁（不会有漏解锁的早退）。
static pthread_mutex_t g_res_mu = PTHREAD_MUTEX_INITIALIZER;
static void res_mu_unlock(pthread_mutex_t **m) { if (m && *m) pthread_mutex_unlock(*m); }
#define RES_GUARD() \
    __attribute__((cleanup(res_mu_unlock))) pthread_mutex_t *res_mu = &g_res_mu; \
    pthread_mutex_lock(res_mu); \
    (void)res_mu

static int page_ok(uint64_t v) { return v % RS_PAGE == 0; }

void s2a_res_reset(void) {
    RES_GUARD();
    memset(g_ranges, 0, sizeof g_ranges);
    memset(g_commits, 0, sizeof g_commits);
    memset(g_backs, 0, sizeof g_backs);
    g_migrating = 0;
    memset(&g_stats, 0, sizeof g_stats);
    memset(g_ubo, 0, sizeof g_ubo);   // 内联：ubo_* 也拿同一把锁，这里不能再调公开入口（非递归锁）
    g_ubo_next = 0;
    g_ubo_age = 0;
}

void s2a_res_stats_get(struct s2a_res_stats *out) {
    RES_GUARD();
    if (out) *out = g_stats;
}

// 后备槽的回收：只增不减会让账本在一局内迁移 256 次后永久 ENOSPC（复核项 1）。
// 只有当没有任何范围 / 在途提交还引用这个后备时才释放。
static int range_uses_backing(uint64_t id) {
    for (int i = 0; i < RS_MAX_RANGES; i++)
        if (g_ranges[i].state != S2A_RES_FREE && g_ranges[i].backing_id == id) return 1;
    return 0;
}
static int commit_uses_backing(uint64_t id) {
    for (int i = 0; i < RS_MAX_COMMITS; i++)
        if (g_commits[i].used && g_commits[i].backing_id == id) return 1;
    return 0;
}
static void backing_release_if_unused(uint64_t id) {
    if (!id) return;
    if (range_uses_backing(id) || commit_uses_backing(id)) return;
    for (int i = 0; i < RS_MAX_BACKINGS; i++)
        if (g_backs[i].used && g_backs[i].id == id) { g_backs[i].used = 0; g_backs[i].id = 0; return; }
}
// 容量预检：动映射之前就要知道有没有后备槽（复核项 4：满了不能先 remap/publish 再回滚已发布映射）。
static int backing_capacity_available(void) {
    for (int i = 0; i < RS_MAX_BACKINGS; i++) if (!g_backs[i].used) return 1;
    return 0;
}

static int backing_track(uint64_t id) {
    if (!id) return 0;
    for (int i = 0; i < RS_MAX_BACKINGS; i++) if (g_backs[i].used && g_backs[i].id == id) return 0;
    for (int i = 0; i < RS_MAX_BACKINGS; i++)
        if (!g_backs[i].used) { g_backs[i].used = 1; g_backs[i].id = id; return 0; }
    return -1;
}

static struct rs_range *range_covering(uint64_t addr, uint64_t len, int live_only) {
    if (!len) return NULL;
    if (addr + len < addr) return NULL;   // 溢出
    for (int i = 0; i < RS_MAX_RANGES; i++) {
        struct rs_range *r = &g_ranges[i];
        if (r->state == S2A_RES_FREE) continue;
        if (live_only && r->state != S2A_RES_LIVE) continue;
        if (addr < r->addr) continue;
        uint64_t off = addr - r->addr;
        if (off > r->len || len > r->len - off) continue;
        return r;
    }
    return NULL;
}

static int range_has_commit(struct rs_range *r) {
    for (int i = 0; i < RS_MAX_COMMITS; i++) {
        struct rs_commit *c = &g_commits[i];
        if (!c->used || c->backing_id != r->backing_id) continue;
        if (c->addr == 0 && c->len == 0) return 1;   // 对象级保活
        // 提交区间与范围有交集就算仍持有该后备
        if (c->addr < r->addr + r->len && r->addr < c->addr + c->len) return 1;
    }
    return 0;
}

static int range_overlaps_any(uint64_t addr, uint64_t len) {
    for (int i = 0; i < RS_MAX_RANGES; i++) {
        struct rs_range *r = &g_ranges[i];
        if (r->state == S2A_RES_FREE) continue;
        if (addr < r->addr + r->len && r->addr < addr + len) return 1;   // 任何重叠都拒绝（部分重叠同样危险）
    }
    return 0;
}

int s2a_res_register(uint64_t addr, uint64_t len, uint64_t pool_id, uint64_t backing_id, uint64_t *out_gen) {
    RES_GUARD();
    if (!len || !page_ok(addr) || !page_ok(len) || addr + len < addr) return S2A_RES_EINVAL;
    if (range_overlaps_any(addr, len)) return S2A_RES_EBUSY;   // 必须先 retire 旧范围
    if (backing_track(backing_id)) return S2A_RES_ENOSPC;
    for (int i = 0; i < RS_MAX_RANGES; i++) {
        struct rs_range *r = &g_ranges[i];
        if (r->state != S2A_RES_FREE) continue;
        memset(r, 0, sizeof *r);
        r->addr = addr; r->len = len; r->pool_id = pool_id;
        r->backing_id = backing_id; r->gen = 1; r->content_version = 1;
        r->state = S2A_RES_LIVE;
        if (out_gen) *out_gen = r->gen;
        return S2A_RES_OK;
    }
    return S2A_RES_ENOSPC;
}

int s2a_res_lookup(uint64_t addr, uint64_t len, struct s2a_res_ref *out) {
    RES_GUARD();
    if (!out || !len) return S2A_RES_EINVAL;
    struct rs_range *r = range_covering(addr, len, 1);
    if (!r) return S2A_RES_ENOENT;
    out->backing_id = r->backing_id;
    out->gen = r->gen;
    out->offset = addr - r->addr;
    out->len = len;
    out->content_version = r->content_version;
    return S2A_RES_OK;
}

int s2a_res_ref_valid(const struct s2a_res_ref *ref) {
    RES_GUARD();
    if (!ref || !ref->len) return S2A_RES_EINVAL;
    for (int i = 0; i < RS_MAX_RANGES; i++) {
        struct rs_range *r = &g_ranges[i];
        if (r->state == S2A_RES_FREE || r->backing_id != ref->backing_id) continue;
        if (r->gen != ref->gen) continue;
        if (ref->offset > r->len || ref->len > r->len - ref->offset) continue;
        return S2A_RES_OK;   // 身份+代际+范围都还对得上
    }
    g_stats.stale_hits++;
    return S2A_RES_ESTALE;
}

int s2a_res_note_write(uint64_t addr, uint64_t len) {
    RES_GUARD();
    if (!len) return S2A_RES_EINVAL;
    int hit = 0;
    for (int i = 0; i < RS_MAX_RANGES; i++) {
        struct rs_range *r = &g_ranges[i];
        if (r->state != S2A_RES_LIVE) continue;
        if (addr + len < addr) return S2A_RES_EINVAL;
        if (addr + len <= r->addr || r->addr + r->len <= addr) continue;
        r->content_version++;
        hit = 1;
    }
    return hit ? S2A_RES_OK : S2A_RES_ENOENT;
}

int s2a_res_retire(uint64_t addr, uint64_t len) {
    RES_GUARD();
    struct rs_range *r = range_covering(addr, len, 1);
    if (!r) return S2A_RES_ENOENT;
    r->state = S2A_RES_RETIRED;
    if (!range_has_commit(r)) {
        uint64_t old = r->backing_id;
        r->state = S2A_RES_FREE;
        memset(r, 0, sizeof *r);
        backing_release_if_unused(old);
    }
    return S2A_RES_OK;
}

int s2a_res_ref_commit_backing(uint64_t commit_seq, uint64_t backing_id) {
    RES_GUARD();
    if (!commit_seq || !backing_id) return S2A_RES_EINVAL;
    for (int i = 0; i < RS_MAX_COMMITS; i++) {
        struct rs_commit *c = &g_commits[i];
        if (c->used && c->seq == commit_seq && c->backing_id == backing_id) return S2A_RES_OK;   // 幂等
    }
    for (int i = 0; i < RS_MAX_COMMITS; i++) {
        struct rs_commit *c = &g_commits[i];
        if (c->used) continue;
        c->used = 1; c->seq = commit_seq; c->backing_id = backing_id;
        c->addr = 0; c->len = 0;   // 0/0 = 对象级保活（不绑定具体范围）
        g_stats.refs_committed++;
        return S2A_RES_OK;
    }
    return S2A_RES_ENOSPC;
}

int s2a_res_ref_commit(uint64_t commit_seq, uint64_t addr, uint64_t len) {
    RES_GUARD();
    struct rs_range *r = range_covering(addr, len, 1);
    if (!r) return S2A_RES_ENOENT;
    for (int i = 0; i < RS_MAX_COMMITS; i++) {
        struct rs_commit *c = &g_commits[i];
        if (c->used) continue;
        c->used = 1; c->seq = commit_seq; c->backing_id = r->backing_id;
        c->addr = addr; c->len = len;
        g_stats.refs_committed++;
        return S2A_RES_OK;
    }
    return S2A_RES_ENOSPC;
}

int s2a_res_complete(uint64_t commit_seq) {
    RES_GUARD();
    int done = 0;
    for (int i = 0; i < RS_MAX_COMMITS; i++) {
        struct rs_commit *c = &g_commits[i];
        if (!c->used || c->seq != commit_seq) continue;
        uint64_t backing = c->backing_id;
        c->used = 0;
        // 复核项 4：只回收“已退休范围”的后备不够——迁移换底后旧后备只有这些在途提交还引用它，
        // 提交清掉后必须立刻尝试回收，否则同一范围循环 256 次账本就废。
        backing_release_if_unused(backing);
        done = 1;
    }
    // 幂等：同一个提交号重复完成是正常调用路径（槽位复用/延迟退休重入），不能报错；
    // 但要让调用方能区分“这次真的清了一批”与“本来就没人持有”，所以记在统计里。
    if (!done) { g_stats.completes_noop++; return S2A_RES_OK; }
    // 提交完成后，已 retire 且没人引用的范围可以释放槽位
    for (int i = 0; i < RS_MAX_RANGES; i++) {
        struct rs_range *r = &g_ranges[i];
        if (r->state != S2A_RES_RETIRED) continue;
        if (range_has_commit(r)) continue;
        uint64_t old = r->backing_id;
        memset(r, 0, sizeof *r);
        backing_release_if_unused(old);
    }
    return S2A_RES_OK;
}

int s2a_res_backing_busy(uint64_t backing_id, int *out_busy) {
    RES_GUARD();
    if (!backing_id) return S2A_RES_EINVAL;
    int busy = 0;
    for (int i = 0; i < RS_MAX_COMMITS; i++) {
        struct rs_commit *c = &g_commits[i];
        if (c->used && c->backing_id == backing_id) { busy = 1; break; }
    }
    if (busy) g_stats.backs_busy++;
    if (out_busy) *out_busy = busy;
    return S2A_RES_OK;
}

void s2a_res_ubo_reset(void) {
    RES_GUARD();
    memset(g_ubo, 0, sizeof g_ubo);
    g_ubo_next = 0;
    g_ubo_age = 0;
}

int s2a_res_ubo_write(uint64_t draw_seq, const void *data, size_t len) {
    RES_GUARD();
    if (!data || !len || len > RS_UBO_BYTES) return S2A_RES_EINVAL;
    struct rs_ubo *slot = &g_ubo[g_ubo_next % RS_UBO_SLOTS];
    slot->used = 1; slot->seq = draw_seq; slot->age = ++g_ubo_age; slot->len = len;
    memcpy(slot->bytes, data, len);
    g_ubo_next++;
    return S2A_RES_OK;
}

int s2a_res_ubo_resolve(uint64_t draw_seq, const void **out_data, size_t *out_len) {
    RES_GUARD();
    const struct rs_ubo *best = NULL;
    // 取 seq <= draw_seq 的最新一次写入；同 seq 时按写入顺序（age）后写的赢。
    for (int i = 0; i < RS_UBO_SLOTS; i++) {
        const struct rs_ubo *u = &g_ubo[i];
        if (!u->used || u->seq > draw_seq) continue;
        if (!best || u->seq > best->seq || (u->seq == best->seq && u->age > best->age)) best = u;
    }
    if (!best) return S2A_RES_ENOENT;
    if (out_data) *out_data = best->bytes;
    if (out_len) *out_len = best->len;
    return S2A_RES_OK;
}

int s2a_res_migrate(const struct s2a_res_ops *ops, uint64_t addr, uint64_t len,
                   uint64_t source_alias, uint64_t *out_gen) {
    RES_GUARD();
    if (!ops || !len || !page_ok(addr) || !page_ok(len) || addr + len < addr) return S2A_RES_EINVAL;
    if (g_migrating) return S2A_RES_EBUSY;
    // 只支持单映射：有多别名（source != 0）时必须在改动映射前拒绝（合同未覆盖完整别名迁移）。
    if (source_alias) { g_stats.notsup++; return S2A_RES_ENOTSUP; }
    struct rs_range *r = range_covering(addr, len, 1);
    if (!r) return S2A_RES_ENOENT;
    // 整段必须落在一个受管范围内，且范围本身页对齐（不能“夹到范围再向外对齐”）。
    if (r->addr != addr || r->len != len) { g_stats.notsup++; return S2A_RES_ENOTSUP; }
    if (ops->prepare_backing && ops->track_begin && ops->copy_content && ops->remap && ops->track_end) {
        /* 必备 ops 到位 */
    } else {
        return S2A_RES_EINVAL;
    }

    // 容量预检放在动映射之前：后备槽满了就直接失败，不产生“先发布再回滚”的窗口（复核项 4）。
    if (!backing_capacity_available()) { g_stats.migrations_fail++; return S2A_RES_ENOSPC; }
    g_migrating = 1;
    uint64_t new_backing = 0;
    int rc = S2A_RES_EIO;
    int remapped = 0;
    if (ops->track_begin(ops->ctx, addr, len, 0) != 0) { g_migrating = 0; g_stats.migrations_fail++; return S2A_RES_EIO; }
    if (ops->prepare_backing(ops->ctx, len, &new_backing) != 0) goto rollback;
    if (ops->copy_content(ops->ctx, addr, new_backing, len) != 0) goto rollback;
    if (ops->remap(ops->ctx, addr, len, new_backing) != 0) goto rollback;
    remapped = 1;
    if (ops->rebuild_protection && ops->rebuild_protection(ops->ctx, addr, len) != 0) goto rollback;
    if (ops->publish && ops->publish(ops->ctx, addr, len) != 0) goto rollback;
    // 账本发布：新后备 + 代际 +1 + 内容版本 +1（映射变了，下游必须重读）
    if (backing_track(new_backing)) { rc = S2A_RES_ENOSPC; goto rollback; }
    {
        uint64_t old = r->backing_id;
        r->backing_id = new_backing;
        backing_release_if_unused(old);   // 旧后备在没人引用时回收（复核项 1）
    }
    r->gen++;
    r->content_version++;
    if (out_gen) *out_gen = r->gen;
    ops->track_end(ops->ctx, addr, len, 1, 1);
    g_stats.migrations_ok++;
    g_migrating = 0;
    return S2A_RES_OK;

rollback: {
    // 合同：mapped=1 表示“旧映射仍有效”（包括失败但完整回滚），mapped=0 仅用于已解除映射。
    int restored = 1;
    if (remapped) restored = ops->rollback_map ? (ops->rollback_map(ops->ctx, addr, len) == 0) : 0;
    if (restored && new_backing && ops->release_backing) ops->release_backing(ops->ctx, new_backing);
    else if (!restored) {
        // 无法恢复合法映射：按合同必须终止，不能带着半迁移状态继续画。新后备也不能释放（仍被引用）。
        ops->track_end(ops->ctx, addr, len, 0, 0);
        g_stats.rollbacks++;
        g_stats.migrations_fail++;
        g_migrating = 0;
        return S2A_RES_EFATAL;   // 与“完整回滚的 EIO”区分：调用方必须终止
    }
    ops->track_end(ops->ctx, addr, len, restored ? 1 : 0, 0);
    g_stats.rollbacks++;
    g_stats.migrations_fail++;
    g_migrating = 0;
    return rc;
}
}

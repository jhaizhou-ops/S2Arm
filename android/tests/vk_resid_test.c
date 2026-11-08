// 资源身份账本 + VM 替页事务的确定性反例（宿主）。每个用例都对应方案 §8 的一条验收项。
// 失败时打印 FAIL 并返回非 0；全部通过打印汇总行。
#include <stdio.h>
#include <string.h>

#include "direct/vk_resid.h"

static int g_fail, g_checks;
#define CHECK(cond) do { g_checks++; if (!(cond)) { g_fail++; printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CASE(name) printf("  case %-28s", name)

// ---- mock ops -------------------------------------------------------------
struct mock {
    int fail_prepare, fail_copy, fail_remap, fail_rebuild, fail_publish, rollback_fail;
    int track_begin_n, track_end_n, track_end_committed, track_end_rolled;
    int prepare_n, copy_n, remap_n, rebuild_n, publish_n, rollback_n, release_n;
    uint64_t next_backing;
};
static int m_track_begin(void *c, uint64_t a, uint64_t n, uint64_t src) {
    struct mock *m = c; (void)a; (void)n; (void)src; m->track_begin_n++; return 0;
}
static void m_track_end(void *c, uint64_t a, uint64_t n, int mapped, int committed) {
    struct mock *m = c; (void)a; (void)n;
    m->track_end_n++;
    if (committed) m->track_end_committed++; else m->track_end_rolled++;
    (void)mapped;
}
static int m_prepare(void *c, uint64_t len, uint64_t *id) {
    struct mock *m = c; (void)len;
    m->prepare_n++;
    if (m->fail_prepare) return -1;
    *id = m->next_backing++;   // 模拟“每次分配得到新后备身份”
    return 0;
}
static int m_copy(void *c, uint64_t a, uint64_t id, uint64_t len) {
    struct mock *m = c; (void)a; (void)id; (void)len; m->copy_n++; return m->fail_copy ? -1 : 0;
}
static int m_remap(void *c, uint64_t a, uint64_t n, uint64_t id) {
    struct mock *m = c; (void)a; (void)n; (void)id; m->remap_n++; return m->fail_remap ? -1 : 0;
}
static int m_rebuild(void *c, uint64_t a, uint64_t n) {
    struct mock *m = c; (void)a; (void)n; m->rebuild_n++; return m->fail_rebuild ? -1 : 0;
}
static int m_publish(void *c, uint64_t a, uint64_t n) {
    struct mock *m = c; (void)a; (void)n; m->publish_n++; return m->fail_publish ? -1 : 0;
}
static int m_rollback_map(void *c, uint64_t a, uint64_t n) { struct mock *m = c; (void)a; (void)n; m->rollback_n++; return m->rollback_fail ? -1 : 0; }
static void m_release(void *c, uint64_t id) { struct mock *m = c; (void)id; m->release_n++; }
static void mock_init(struct mock *m) { memset(m, 0, sizeof *m); m->next_backing = 1000; }
static struct s2a_res_ops ops_of(struct mock *m) {
    struct s2a_res_ops o = {0};
    o.ctx = m;
    o.track_begin = m_track_begin;
    o.track_end = m_track_end;
    o.prepare_backing = m_prepare;
    o.copy_content = m_copy;
    o.remap = m_remap;
    o.rebuild_protection = m_rebuild;
    o.publish = m_publish;
    o.rollback_map = m_rollback_map;
    o.release_backing = m_release;
    return o;
}

int main(void) {
    const uint64_t A = 0x10000000ull;
    const uint64_t L = 0x4000ull;

    s2a_res_reset();
    CASE("basic_lookup");
    {
        uint64_t gen = 0;
        CHECK(s2a_res_register(A, L, 7, 1, &gen) == S2A_RES_OK);
        CHECK(gen == 1);
        struct s2a_res_ref r;
        CHECK(s2a_res_lookup(A + 0x1000, 0x1000, &r) == S2A_RES_OK);
        CHECK(r.backing_id == 1 && r.gen == 1 && r.offset == 0x1000);
        CHECK(s2a_res_ref_valid(&r) == S2A_RES_OK);
        CHECK(s2a_res_lookup(A + L, 0x1000, &r) == S2A_RES_ENOENT);   // 范围外
        CHECK(s2a_res_lookup(A + 0x3000, 0x2000, &r) == S2A_RES_ENOENT); // 跨出范围
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("stale_after_migrate");
    {
        struct mock m; mock_init(&m);
        struct s2a_res_ops ops = ops_of(&m);
        struct s2a_res_ref before;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_lookup(A, L, &before) == S2A_RES_OK);
        uint64_t gen = 0;
        CHECK(s2a_res_migrate(&ops, A, L, 0, &gen) == S2A_RES_OK);
        CHECK(gen == 2);
        CHECK(s2a_res_ref_valid(&before) == S2A_RES_ESTALE);   // 旧引用必须失效
        struct s2a_res_ref after;
        // 迁移只换尾段：整段换底后统一身份，这里再查一遍同样的整段
        CHECK(s2a_res_lookup(A, L, &after) == S2A_RES_OK);
        CHECK(after.gen == 2 && after.backing_id == 1000);
        CHECK(s2a_res_ref_valid(&after) == S2A_RES_OK);
        CHECK(m.track_end_committed == 1 && m.track_end_rolled == 0);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("write_tracking_after_migrate");
    {
        struct mock m; mock_init(&m);
        struct s2a_res_ops ops = ops_of(&m);
        struct s2a_res_ref r0;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_lookup(A, 0x1000, &r0) == S2A_RES_OK);
        uint64_t v0 = r0.content_version;
        CHECK(s2a_res_migrate(&ops, A, L, 0, NULL) == S2A_RES_OK);
        // 换页必须重建页保护（写跟踪）：ops 被调用一次
        CHECK(m.rebuild_n == 1);
        struct s2a_res_ref r1;
        CHECK(s2a_res_lookup(A, 0x1000, &r1) == S2A_RES_OK);
        CHECK(r1.content_version > v0);       // 映射变化 = 内容版本推进，下游必须重读
        CHECK(s2a_res_note_write(A, 0x1000) == S2A_RES_OK);
        struct s2a_res_ref r2;
        CHECK(s2a_res_lookup(A, 0x1000, &r2) == S2A_RES_OK);
        CHECK(r2.content_version > r1.content_version);   // 写入被跟踪到
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("ubo_7_then_11");
    {
        uint8_t seven[16], eleven[16];
        memset(seven, 7, sizeof seven); memset(eleven, 11, sizeof eleven);
        const void *p = NULL; size_t n = 0;
        CHECK(s2a_res_ubo_write(1, seven, sizeof seven) == S2A_RES_OK);   // 写入 7
        CHECK(s2a_res_ubo_resolve(1, &p, &n) == S2A_RES_OK);              // Draw A
        CHECK(n == sizeof seven && ((const uint8_t *)p)[0] == 7);
        CHECK(s2a_res_ubo_write(2, eleven, sizeof eleven) == S2A_RES_OK); // 写入 11
        CHECK(s2a_res_ubo_resolve(2, &p, &n) == S2A_RES_OK);              // Draw B
        CHECK(((const uint8_t *)p)[0] == 11);
        CHECK(s2a_res_ubo_resolve(1, &p, &n) == S2A_RES_OK);              // 回看 Draw A 仍是 7
        CHECK(((const uint8_t *)p)[0] == 7);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("window_bounds_reject");
    {
        // 池在窗口偏移 0x3000、长度 0x2000：请求整段换底时，前后都不能碰池外页。
        const uint64_t P = 0x20000000ull + 0x3000ull;
        const uint64_t PL = 0x2000ull;
        struct mock m; mock_init(&m);
        struct s2a_res_ops ops = ops_of(&m);
        CHECK(s2a_res_register(P, PL, 9, 5, NULL) == S2A_RES_OK);
        CHECK(s2a_res_migrate(&ops, P - 0x3000ull, 0x5000ull, 0, NULL) == S2A_RES_ENOENT);
        // 跨出范围：被拒绝即可（ENOENT=没有范围完整覆盖，ENOTSUP=不允许迁移），关键是没动映射
        CHECK(s2a_res_migrate(&ops, P, 0x3000ull, 0, NULL) != S2A_RES_OK);
        CHECK(m.track_begin_n == 0 && m.remap_n == 0 && m.publish_n == 0);        // 什么都没动
        struct s2a_res_ref r;
        CHECK(s2a_res_lookup(P, PL, &r) == S2A_RES_OK && r.gen == 1);             // 状态不变
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("alias_reject_before_change");
    {
        struct mock m; mock_init(&m);
        struct s2a_res_ops ops = ops_of(&m);
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_migrate(&ops, A, L, 0x5000, NULL) == S2A_RES_ENOTSUP);      // 有别名 → 拒绝
        CHECK(m.track_begin_n == 0 && m.remap_n == 0);                            // 改动前就拒绝
        struct s2a_res_ref r;
        CHECK(s2a_res_lookup(A, L, &r) == S2A_RES_OK && r.gen == 1);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("inflight_keepalive");
    {
        int busy = 0;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_ref_commit(5, A, L) == S2A_RES_OK);
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 1);
        CHECK(s2a_res_retire(A, L) == S2A_RES_OK);          // 退休：新命中立即停
        struct s2a_res_ref r;
        CHECK(s2a_res_lookup(A, L, &r) == S2A_RES_ENOENT);
        // 未提交的序号：完成是幂等的（不报错），但必须什么都不清——记在 completes_noop 里。
        CHECK(s2a_res_complete(4) == S2A_RES_OK);
        { struct s2a_res_stats st; s2a_res_stats_get(&st); CHECK(st.completes_noop == 1); }
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 1);
        CHECK(s2a_res_complete(5) == S2A_RES_OK);            // fence 完成
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 0);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("same_addr_rebuild_new_gen");
    {
        struct s2a_res_ref old_ref;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_lookup(A, L, &old_ref) == S2A_RES_OK);
        CHECK(s2a_res_retire(A, L) == S2A_RES_OK);
        uint64_t gen2 = 0;
        CHECK(s2a_res_register(A, L, 7, 2, &gen2) == S2A_RES_OK);   // 同址新建：新后备身份
        struct s2a_res_ref fresh;
        CHECK(s2a_res_lookup(A, L, &fresh) == S2A_RES_OK);
        CHECK(fresh.backing_id == 2);
        CHECK(s2a_res_ref_valid(&old_ref) == S2A_RES_ESTALE);       // 旧引用不得命中新资源
        printf("ok\n");
    }

    // 逐阶段注入失败：必须完整回滚，账本与映射都不前进。
    for (int stage = 0; stage < 5; stage++) {
        char name[64];
        snprintf(name, sizeof name, "rollback_stage%d", stage);
        s2a_res_reset();
        CASE(name);
        struct mock m; mock_init(&m);
        struct s2a_res_ops ops = ops_of(&m);
        if (stage == 0) m.fail_prepare = 1;
        else if (stage == 1) m.fail_copy = 1;
        else if (stage == 2) m.fail_remap = 1;
        else if (stage == 3) m.fail_rebuild = 1;
        else m.fail_publish = 1;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        uint64_t gen = 0;
        int rc = s2a_res_migrate(&ops, A, L, 0, &gen);
        CHECK(rc != S2A_RES_OK);                          // 必须失败
        CHECK(gen == 0);                                  // 没有发布新代际
        struct s2a_res_ref r;
        CHECK(s2a_res_lookup(A, L, &r) == S2A_RES_OK && r.gen == 1 && r.backing_id == 1);
        CHECK(m.track_end_rolled == 1 && m.track_end_committed == 0);
        CHECK(m.publish_n == ((stage == 4) ? 1 : 0));   // 只有 publish 阶段是“调用了但失败”
        // remap 之后才失败的阶段必须回滚映射；之前的阶段没有映射可回滚
        CHECK(m.rollback_n == ((stage >= 3) ? 1 : 0));
        // 只有真的分配过新后备才需要释放
        CHECK(m.release_n == ((stage >= 1) ? 1 : 0));
        printf("ok (rc=%d)\n", rc);
    }

    s2a_res_reset();
    CASE("stop_rebuild_no_inherit");
    {
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_ref_commit(5, A, L) == S2A_RES_OK);
        s2a_res_reset();                                  // Stop / 会话重建
        struct s2a_res_ref r;
        CHECK(s2a_res_lookup(A, L, &r) == S2A_RES_ENOENT);   // 不继承旧映射
        int busy = 1;
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 0);  // 不伪造完成
        struct s2a_res_stats st;
        s2a_res_stats_get(&st);
        CHECK(st.migrations_ok == 0 && st.refs_committed == 0);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("partial_overlap_rejected");
    {
        // 部分重叠登记必须拒绝：否则同一段内存会有两个身份，代际/引用全乱。
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_register(A + 0x2000, L, 7, 2, NULL) == S2A_RES_EBUSY);
        CHECK(s2a_res_register(A - 0x2000, 0x4000, 7, 2, NULL) == S2A_RES_EBUSY);
        struct s2a_res_ref r;
        CHECK(s2a_res_lookup(A, L, &r) == S2A_RES_OK && r.backing_id == 1);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("ref_table_exhaustion");
    {
        // 引用表满时必须让调用者知道（不能漏记继续画）：登记失败要返回非 0。
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        int ok = 0, full = 0;
        for (int i = 0; i < 400; i++) {
            int rc = s2a_res_ref_commit((uint64_t)(i + 1), A, L);
            if (rc == S2A_RES_OK) ok++;
            else { full = 1; CHECK(rc == S2A_RES_ENOSPC); break; }
        }
        CHECK(ok == 128 && full);              // 128 槽写满后必须报 ENOSPC
        for (int i = 0; i < 128; i++) (void)s2a_res_complete((uint64_t)(i + 1));
        CHECK(s2a_res_ref_commit(999, A, L) == S2A_RES_OK);   // 退休后可以再登记
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("rollback_unrecoverable_is_fatal");
    {
        // 无法恢复旧映射时必须返回 EIO（合同：无法恢复合法映射应终止），不能假装成功。
        struct mock m; mock_init(&m);
        struct s2a_res_ops ops = ops_of(&m);
        m.fail_rebuild = 1;
        m.rollback_fail = 1;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_migrate(&ops, A, L, 0, NULL) == S2A_RES_EFATAL);   // 回滚失败：合同要求终止
        CHECK(m.rollback_n == 1);
        CHECK(m.release_n == 0);           // 恢复不了时新后备不能释放（仍可能被引用）
        CHECK(m.track_end_committed == 0);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("pool_removed_keeps_inflight");
    {
        // 池删除：新命中立即停；在途引用直到完成证明才可释放（账本不能提前把后备判空闲）。
        int busy = 0;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_ref_commit(3, A, L) == S2A_RES_OK);
        CHECK(s2a_res_retire(A, L) == S2A_RES_OK);
        struct s2a_res_ref r;
        CHECK(s2a_res_lookup(A, L, &r) == S2A_RES_ENOENT);                    // 新命中停
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 1);      // 在途仍持有
        CHECK(s2a_res_complete(3) == S2A_RES_OK);
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 0);      // 完成证明后才空闲
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("note_write_advances_version");
    {
        struct s2a_res_ref r0, r1;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_lookup(A, L, &r0) == S2A_RES_OK);
        CHECK(s2a_res_note_write(A, L) == S2A_RES_OK);
        CHECK(s2a_res_lookup(A, L, &r1) == S2A_RES_OK);
        CHECK(r1.content_version > r0.content_version);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("backing_keepalive_idempotent");
    {
        // 同一提交对同一后备登记 400 次只占一项（否则 128 槽上限会把采用率压到 64 次/帧）。
        int busy = 0;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        for (int i = 0; i < 400; i++) CHECK(s2a_res_ref_commit_backing(5, 1) == S2A_RES_OK);
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 1);
        // 两个提交同时持有：完成一个，另一个仍保活
        CHECK(s2a_res_ref_commit_backing(6, 1) == S2A_RES_OK);
        CHECK(s2a_res_complete(5) == S2A_RES_OK);
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 1);
        CHECK(s2a_res_complete(6) == S2A_RES_OK);
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 0);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("monotonic_seq_no_cross_release");
    {
        // 直线流水：N-1 与 N+1 同时在途，两帧引用同一后备但提交号不同。
        // 完成 N-1 之后，N+1 的保活必须还在（否则会销毁 GPU 仍在读的缓冲）。
        int busy = 0;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_ref_commit_backing(101, 1) == S2A_RES_OK);
        CHECK(s2a_res_ref_commit_backing(103, 1) == S2A_RES_OK);
        CHECK(s2a_res_complete(101) == S2A_RES_OK);
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 1);
        CHECK(s2a_res_complete(103) == S2A_RES_OK);
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 0);
        // 重复完成同一个号是幂等的，不能把后来的保活误清
        CHECK(s2a_res_ref_commit_backing(104, 1) == S2A_RES_OK);
        CHECK(s2a_res_complete(103) == S2A_RES_OK);
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 1);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("same_seq_would_collapse");
    {
        // 反例说明为什么提交号必须单调：两帧用同一个号登记同一后备，只会得到一项保活，
        // 完成其中一帧就把另一帧仍然在 GPU 上读的引用一起清掉（VUID-vkDestroyBuffer-buffer-00922）。
        int busy = 0;
        CHECK(s2a_res_register(A, L, 7, 1, NULL) == S2A_RES_OK);
        CHECK(s2a_res_ref_commit_backing(7, 1) == S2A_RES_OK);   // 帧 N-1
        CHECK(s2a_res_ref_commit_backing(7, 1) == S2A_RES_OK);   // 帧 N+1（同号，被幂等合并）
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 1);
        CHECK(s2a_res_complete(7) == S2A_RES_OK);                // 只完成一帧
        CHECK(s2a_res_backing_busy(1, &busy) == S2A_RES_OK && busy == 0);   // 两帧都没保活了 → 就是旧实现的 bug
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("backing_recycled_300");
    {
        // 复核项 1：后备槽只增不减时，同一范围「登记→退休」循环到第 257 次就永久 ENOSPC。
        // 现在退休/完成后回收没人引用的后备槽，300 次循环都必须成功。
        int bad = -1;
        for (int i = 0; i < 300; i++) {
            uint64_t gen = 0;
            int rc = s2a_res_register(A, L, 7, (uint64_t)(1000 + i), &gen);
            if (rc != S2A_RES_OK) { bad = i; break; }
            if (s2a_res_retire(A, L) != S2A_RES_OK) { bad = i; break; }
        }
        CHECK(bad == -1);
        // 退休后该后备不再被引用：重新登记同一后备身份也能成功（说明槽确实回收了）
        CHECK(s2a_res_register(A, L, 7, 1000, NULL) == S2A_RES_OK);
        CHECK(s2a_res_retire(A, L) == S2A_RES_OK);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("ubo_wrap_write_order");
    {
        // 复核项 2：同 draw_seq 先写 0xAA 后写 0xBB，第二笔回绕到 0 号槽；
        // 只按 seq 挑会解析出 0xAA，必须按写入序号（age）取后写的 0xBB。
        const unsigned char aa = 0xAA, bb = 0xBB;
        const void *out = NULL;
        size_t len = 0;
        // 先写 63 笔把槽位推到 63：第 64 笔（0xAA）落 63 号槽，第 65 笔（0xBB）回绕到 0 号槽。
        // 这样“按槽位下标挑”一定会选到 0 号槽的 0xAA（旧实现的错），必须按写入序号才得 0xBB。
        for (int i = 0; i < 63; i++) {
            unsigned char v = (unsigned char)i;
            CHECK(s2a_res_ubo_write((uint64_t)(10 + i), &v, 1) == S2A_RES_OK);
        }
        CHECK(s2a_res_ubo_write(200, &aa, 1) == S2A_RES_OK);   // 回绕到 0 号槽
        CHECK(s2a_res_ubo_write(200, &bb, 1) == S2A_RES_OK);   // 回绕到 1 号槽，同 seq 后写
        CHECK(s2a_res_ubo_resolve(200, &out, &len) == S2A_RES_OK);
        CHECK(len == 1 && out && *(const unsigned char *)out == 0xBB);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("migrate_enospc_before_remap");
    {
        // 复核项 4：后备账本满时必须在动映射之前失败，不能先 remap/publish 再回滚已发布的映射。
        const uint64_t base = 0x20000000ull;
        for (int i = 0; i < 256; i++) {   // RS_MAX_RANGES / RS_MAX_BACKINGS = 256
            uint64_t gen = 0;
            int rc = s2a_res_register(base + (uint64_t)i * L, L, 7, (uint64_t)(5000 + i), &gen);
            CHECK(rc == S2A_RES_OK);
            if (rc != S2A_RES_OK) break;
        }
        struct mock m; mock_init(&m);
        struct s2a_res_ops ops = ops_of(&m);
        uint64_t gen = 0;
        int rc = s2a_res_migrate(&ops, base, L, 0, &gen);
        CHECK(rc == S2A_RES_ENOSPC);
        CHECK(m.track_begin_n == 0 && m.prepare_n == 0 && m.remap_n == 0 && m.publish_n == 0);
        CHECK(m.rollback_n == 0);
        printf("ok\n");
    }

    s2a_res_reset();
    CASE("backing_recycled_with_commits");
    {
        // 复核项 4 的反例：同一范围「登记 → ref_commit → migrate → retire → complete」循环。
        // 旧实现下旧后备只被提交引用，complete 清提交时没人回收 → 第 256 次 migrate 报 ENOSPC。
        struct mock m; mock_init(&m);
        struct s2a_res_ops ops = ops_of(&m);
        int bad = -1;
        for (int i = 0; i < 300; i++) {
            uint64_t seq = (uint64_t)(1000 + i);
            if (s2a_res_register(A, L, 7, 0, NULL) != S2A_RES_OK) { bad = i; break; }
            if (s2a_res_ref_commit(seq, A, L) != S2A_RES_OK) { bad = i; break; }
            if (s2a_res_migrate(&ops, A, L, 0, NULL) != S2A_RES_OK) { bad = i; break; }
            if (s2a_res_retire(A, L) != S2A_RES_OK) { bad = i; break; }
            if (s2a_res_complete(seq) != S2A_RES_OK) { bad = i; break; }
        }
        CHECK(bad == -1);
        printf("ok\n");
    }

    printf("vk-resid: 检查 %d 项，失败 %d 项 → %s\n", g_checks, g_fail, g_fail ? "红" : "通过");
    return g_fail ? 1 : 0;
}

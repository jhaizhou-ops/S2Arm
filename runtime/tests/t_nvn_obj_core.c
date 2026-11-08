// D7 第六片：nvn_obj.h 的命令记录解码 / 同步发布是纯 C（只依赖 stdint/string + nvn.h），能在 Linux 上单独编译验证。
// 期望值按记录格式手算：完整记录直接引用；短记录零填充后按字节拷入；单实例索引绘制补 instances=1；
// combined handle 按 (texture ID + tbase) | (sampler ID + sbase) << 20 还原。
#include "nvn_obj.h"
#include <stdio.h>
#include <string.h>

static int fails, checks;

static void eq_i(const char *what, int got, int want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %d，期望 %d\n", what, got, want); }
}

static void eq_u64(const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %llu，期望 %llu\n", what, (unsigned long long)got, (unsigned long long)want); }
}

int main(void) {
    // 同步发布：先 fence 后 fenced（release），读侧 acquire；初值不可见
    sync_t sy; memset(&sy, 0, sizeof sy);
    uint64_t fence = 0;
    eq_i("初始未发布", sync_published(&sy, &fence), 0);
    sync_publish(&sy, 0xABCDEF);
    eq_i("发布后可见", sync_published(&sy, &fence), 1);
    eq_u64("发布后 fence", fence, 0xABCDEF);
    eq_i("fence 可空", sync_published(&sy, NULL), 1);

    // BindVertexBuffer 单段短记录：size-8 正好是 p_bind_vbuf_single 时展开成一条 range
    p_bind_vbuf_single bs = {.first = 3, .size = 64, .addr = 0x12345678};
    p_bind_vbuf bv;
    memset(&bv, 0, sizeof bv);
    const p_bind_vbuf *bp = bind_vbuf_rec(&bs, (uint32_t)sizeof bs + 8, &bv);
    eq_i("单段记录走临时缓冲", bp == &bv, 1);
    eq_i("单段 first", bv.first, 3);
    eq_i("单段 n", bv.n, 1);
    eq_u64("单段 addr", bv.r[0].address, 0x12345678);
    eq_u64("单段 size", bv.r[0].size, 64);
    const p_bind_vbuf *bp2 = bind_vbuf_rec(&bs, 40, &bv);
    eq_i("非单段直接引用", bp2 == (const p_bind_vbuf *)&bs, 1);

    // combined texture handle：texture ID | sampler ID << 20，再各自加池基址
    p_bind_tex1 t1;
    memset(&t1, 0, sizeof t1);
    t1.stage = 2; t1.slot = 5; t1.h = 0x12345ull | (0x67ull << 20); t1.tbase = 100; t1.sbase = 200;
    p_bind_handles bh;
    memset(&bh, 0, sizeof bh);
    const p_bind_handles *hp = bind_rec(OP_BIND_TEX1, &t1, &bh);
    eq_i("combined 走临时缓冲", hp == &bh, 1);
    eq_i("combined stage", bh.stage, 2);
    eq_i("combined first", bh.first, 5);
    eq_i("combined n", bh.n, 1);
    eq_u64("combined handle", bh.h[0], (0x12345ull + 100) | ((0x67ull + 200) << 20));
    hp = bind_rec(OP_DRAW, &t1, &bh);
    eq_i("非 combined 直接引用", hp == (const p_bind_handles *)&t1, 1);

    // Draw：完整记录直接引用；短记录零填充后拷贝已有字节
    p_draw d;
    memset(&d, 0, sizeof d);
    d.prim = 4; d.first = 1; d.count = 3; d.instances = 1;
    p_draw tmpd;
    const p_draw *dp = draw_rec(&d, (uint32_t)sizeof d + 8, &tmpd);
    eq_i("完整 draw 直接引用", dp == &d, 1);
    p_draw shortd;
    memset(&shortd, 0xAA, sizeof shortd);
    dp = draw_rec(&d, 16, &shortd);   // size-8 = 8：只拷 prim / first
    eq_i("短 draw 走临时", dp == &shortd, 1);
    eq_i("短 draw prim", shortd.prim, 4);
    eq_i("短 draw first", shortd.first, 1);
    eq_i("短 draw count 归零", shortd.count, 0);
    eq_i("短 draw instances 归零", shortd.instances, 0);
    memset(&shortd, 0xAA, sizeof shortd);
    dp = draw_rec(&d, 8, &shortd);    // size-8 = 0：全零
    eq_i("空 draw 走临时", dp == &shortd, 1);
    eq_i("空 draw prim 归零", shortd.prim, 0);

    // DrawElements：完整记录直接引用；单实例短记录补 instances=1；其他短记录只拷已有字段
    p_draw_idx di;
    memset(&di, 0, sizeof di);
    di.prim = 4; di.itype = 1; di.count = 6; di.ibuf = 0x1000;
    p_draw_idx tmp2;
    const p_draw_idx *dip = draw_idx_rec(&di, (uint32_t)sizeof di + 8, &tmp2);
    eq_i("完整 indexed 直接引用", dip == &di, 1);
    p_draw_idx_single ds = {.prim = 4, .itype = 1, .count = 6, .base_vertex = 2, .ibuf = 0x1000};
    p_draw_idx tmp;
    memset(&tmp, 0xAA, sizeof tmp);
    dip = draw_idx_rec(&ds, (uint32_t)sizeof ds + 8, &tmp);
    eq_i("单实例 indexed 走临时", dip == &tmp, 1);
    eq_i("单实例 indexed instances", tmp.instances, 1);
    eq_i("单实例 indexed base_instance", tmp.base_instance, 0);
    eq_u64("单实例 indexed ibuf", tmp.ibuf, 0x1000);
    memset(&tmp, 0xAA, sizeof tmp);
    dip = draw_idx_rec(&ds, 24, &tmp);   // size-8 = 16：只拷前四个 int
    eq_i("其他短 indexed 走临时", dip == &tmp, 1);
    eq_i("其他短 indexed prim", tmp.prim, 4);
    eq_i("其他短 indexed base_vertex", tmp.base_vertex, 2);
    eq_i("其他短 indexed instances 归零", tmp.instances, 0);
    eq_u64("其他短 indexed ibuf 归零", tmp.ibuf, 0);

    if (fails) printf("✗ t_nvn_obj_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_obj_core：命令记录解码 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}

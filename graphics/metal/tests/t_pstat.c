// 遍统计（gal_pstat.m，NXGAL_PSTAT）单测：纯逻辑 gal_pstat_analyze 用手算期望的小序列核；GPFIFO 段统计用固定内存跑 300 帧核汇总行。
// 期望值都是按口径手算的（见各用例注释），不跑被测实现得出。
#include "../gal_pstat.h"
#include "../gal_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_fail, g_n;
#define EQ(a, b) do { g_n++; unsigned long long a_ = (unsigned long long)(a), b_ = (unsigned long long)(b); if (a_ != b_) { g_fail++; fprintf(stderr, "失败 %s:%d：%s = %llu，期望 %llu\n", __FILE__, __LINE__, #a, a_, b_); } } while (0)

static ps_ev P(void) { return (ps_ev){PS_PASS, 0, 0, 0, 0, 0}; }
static ps_ev A(uint32_t r, int clear, uint64_t b) { return (ps_ev){PS_ATT, (uint8_t)clear, 0, 0, r, b}; }
static ps_ev AV(uint32_t r, int clear, uint64_t b, uint32_t v) { return (ps_ev){PS_ATT, (uint8_t)clear, 0, 0, r, b, v}; }
static ps_ev S(uint32_t r, int inpass, int cs) { return (ps_ev){PS_SAMPLE, 0, (uint8_t)inpass, (uint8_t)cs, r, 0}; }
static ps_ev R(uint32_t r) { return (ps_ev){PS_READ, 0, 0, 0, r, 0}; }
static uint32_t scr[16 * 5];
static ps_res run(const ps_ev *e, int n) { ps_res r; memset(&r, 0, sizeof r); gal_pstat_analyze(e, n, 16, scr, &r); return r; }

int main(void) {
    enum { a = 1, b = 2, c = 3, d = 4, e5 = 5, f = 6 };
    // 用例 1：A 写 → B 遍采样 A → A 被清。A 第 1 遍存回后下一事件是采样（要存）；B、第 3 遍的 A 之后再没用到（本帧后不再读）；第 2 遍采样第 1 遍的附件 = 1 对
    {
        ps_ev s[] = {P(), A(a, 0, 100), P(), A(b, 0, 50), S(a, 1, 0), P(), A(a, 1, 100)};
        ps_res r = run(s, 7);
        EQ(r.passes, 3); EQ(r.st_n, 3); EQ(r.st_bytes, 250); EQ(r.ld_n, 2); EQ(r.ld_bytes, 150);
        EQ(r.clr_n, 0); EQ(r.dead_n, 2); EQ(r.dead_bytes, 150); EQ(r.adj_n, 0); EQ(r.pairs, 1);
    }
    // 用例 2：A 写后、被读之前又被清（可省 100）；B 本帧后不再读（40）；第 3 遍的 A 之后被拷贝读（要存）。无读入、无相邻对
    {
        ps_ev s[] = {P(), A(a, 1, 100), P(), A(b, 1, 40), P(), A(a, 1, 100), R(a)};
        ps_res r = run(s, 7);
        EQ(r.passes, 3); EQ(r.st_n, 3); EQ(r.ld_n, 0); EQ(r.clr_n, 1); EQ(r.clr_bytes, 100); EQ(r.dead_n, 1); EQ(r.dead_bytes, 40); EQ(r.pairs, 0);
    }
    // 用例 3：两遍续用同一组附件（A、D 第 1 遍清开、第 2 遍读入）→ 相邻续用 2 次，存回 130、读入 130；第 3 遍采样第 2 遍的 A = 1 对
    {
        ps_ev s[] = {P(), A(a, 1, 100), A(d, 1, 30), P(), A(a, 0, 100), A(d, 0, 30), P(), A(c, 0, 20), S(a, 1, 0)};
        ps_res r = run(s, 9);
        EQ(r.passes, 3); EQ(r.st_n, 5); EQ(r.st_bytes, 280); EQ(r.ld_n, 3); EQ(r.ld_bytes, 150);
        EQ(r.adj_n, 2); EQ(r.adj_st_bytes, 130); EQ(r.adj_ld_bytes, 130);
        EQ(r.dead_n, 2); EQ(r.dead_bytes, 50); EQ(r.clr_n, 0); EQ(r.pairs, 1);
    }
    // 用例 4：计算派发采样算「读」但不算相邻对；遍外采样归下一个遍（第 4 遍不存在，B 不是第 3 遍的附件 → 不成对）
    {
        ps_ev s[] = {P(), A(a, 0, 10), S(a, 0, 1), P(), A(b, 0, 10), P(), A(a, 0, 10), S(b, 0, 0)};
        ps_res r = run(s, 8);
        EQ(r.passes, 3); EQ(r.pairs, 0); EQ(r.dead_n, 1); EQ(r.dead_bytes, 10); EQ(r.adj_n, 0); EQ(r.clr_n, 0);
    }
    // 用例 5：遍外采样（编码器还没开）归下一个遍：E 第 1 遍写、第 2 遍开之前采样 → 1 对；E 要存，F 本帧后不再读
    {
        ps_ev s[] = {P(), A(e5, 0, 8), S(e5, 0, 0), P(), A(f, 1, 8)};
        ps_res r = run(s, 5);
        EQ(r.pairs, 1); EQ(r.dead_n, 1); EQ(r.dead_bytes, 8);
    }
    // 用例 3b：同一底层贴图相邻两遍续用，按视图拆：A 第 1→2 遍同视图 7（可合）、D 第 1→2 遍视图 8 → 9（同贴图不同 mip / 层，不可合）
    {
        ps_ev s[] = {P(), AV(a, 1, 100, 7), AV(d, 1, 30, 8), P(), AV(a, 0, 100, 7), AV(d, 0, 30, 9)};
        ps_res r = run(s, 6);
        EQ(r.adj_n, 2); EQ(r.adj_same_n, 1); EQ(r.adj_same_st_bytes, 100);
    }
    // 用例 3c：视图未知（0）不算同视图
    {
        ps_ev s[] = {P(), A(a, 1, 100), P(), A(a, 0, 100)};
        ps_res r = run(s, 4);
        EQ(r.adj_n, 1); EQ(r.adj_same_n, 0);
    }
    // 用例 6：隔一遍再读入不算相邻续用（A 第 1 遍 → 第 3 遍读入：要存）
    {
        ps_ev s[] = {P(), A(a, 0, 10), P(), A(b, 1, 10), P(), A(a, 0, 10)};
        ps_res r = run(s, 6);
        EQ(r.adj_n, 0); EQ(r.clr_n, 0); EQ(r.dead_n, 2); EQ(r.dead_bytes, 20); EQ(r.ld_n, 2);
    }
    // 用例 7：同一遍 2 个颜色 + 1 深度都被下一遍以清开 → 3 次可省（先被清）；相邻对 0（没有采样）
    {
        ps_ev s[] = {P(), A(a, 0, 4), A(b, 0, 4), A(c, 0, 2), P(), A(a, 1, 4), A(b, 1, 4), A(c, 1, 2)};
        ps_res r = run(s, 8);
        EQ(r.clr_n, 3); EQ(r.clr_bytes, 10); EQ(r.dead_n, 3); EQ(r.ld_n, 3); EQ(r.ld_bytes, 10); EQ(r.pairs, 0);
    }

    // GPFIFO 段：一块 8 KB（两页）命令内存，300 帧每帧提交同样内容一次。第 1 帧两页都是第一次见 → 算变了；之后 299 帧页内容不变 → 未变字节 / 段 = 299/300 = 99.7%。
    // 段内容第 1 帧新、之后每帧都与上一帧相同 → 99.7%。写跟踪查询在单测里是弱缺省（-1）→ 汇总行标「查询不可用」
    setenv("NXGAL_PSTAT", "1", 1);
    if (!PSTAT_ON()) { fprintf(stderr, "失败：NXGAL_PSTAT=1 没开\n"); return 1; }
    uint8_t *mem; if (posix_memalign((void **)&mem, 4096, 8192)) return 1;
    for (int i = 0; i < 8192; i++) mem[i] = (uint8_t)(i * 7);
    char path[] = "/tmp/t_pstat_XXXXXX"; int fd = mkstemp(path); int save = dup(2); dup2(fd, 2);
    for (int fr = 0; fr < 300; fr++) {
        uint64_t rg[2] = {(uint64_t)(uintptr_t)mem, 8192};
        nxgal_pstat_seg(rg, 1, 8192);
        // 也走一遍遍记录（假指针）：每帧 1 遍 1 附件、之后被出图读
        gal_pstat_pass(); gal_pstat_att((void *)0x1000, 1, 64, 0, 1); gal_pstat_use((void *)0x1000, PS_READ, 0, 0);
        gal_pstat_frame();
    }
    fflush(stderr); dup2(save, 2);
    char buf[4096] = {0}; lseek(fd, 0, SEEK_SET); read(fd, buf, sizeof buf - 1); close(fd); unlink(path);
    fprintf(stderr, "汇总行：%s", buf);
    g_n++; if (!strstr(buf, "页未变 字节 99.7% 段 99.7%")) { g_fail++; fprintf(stderr, "失败：页未变比例不是 99.7%%\n"); }
    g_n++; if (!strstr(buf, "段内容同前 2 帧 字节 99.7% 段 99.7%")) { g_fail++; fprintf(stderr, "失败：段内容比例不是 99.7%%\n"); }
    g_n++; if (!strstr(buf, "每帧 1.0 段 8.0 KB")) { g_fail++; fprintf(stderr, "失败：每帧段数 / 字节不对\n"); }
    g_n++; if (!strstr(buf, "每帧 遍 1.0、附件存回 1.0 次 0.00 MB、读入 0.0 次")) { g_fail++; fprintf(stderr, "失败：遍记录汇总不对\n"); }
    g_n++; if (!strstr(buf, "写跟踪覆盖字节 （查询不可用）")) { g_fail++; fprintf(stderr, "失败：写跟踪查询弱缺省没标不可用\n"); }
    // 改一页内容后再提交：该段两页里一页变了 → 本帧该段不算未变（下一行汇总在第 600 帧；这里只核不崩、不越界）
    mem[100] ^= 0xff; { uint64_t rg[2] = {(uint64_t)(uintptr_t)mem, 8192}; nxgal_pstat_seg(rg, 1, 8192); }
    fprintf(stderr, "t_pstat：%d 项，失败 %d\n", g_n, g_fail);
    return g_fail != 0;
}

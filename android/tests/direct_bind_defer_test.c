// Bind*Deferred 句柄记录的回放解析（宿主回归）：直接链接生产实现 bind_defer.c，
// 不另写模型。回归点（8E Wonder direct 崩溃）：vk 回放原先只按 p_bind_handles 取 h[]，
// defer=1 的记录在游戏之后才写句柄数组，h[] 里是录制时的陈旧字节——fs 槽 9 的绑定
// 被读成不存在/野 id，textures[] 缺 (fs,handle=26,cbufSlot=-1) 事实，
// QueryTextureCoordNormalized MISSING_FACT → 进程退出。
// 语义对齐 nvn_mtl.m bh_fresh：回放读时才取句柄，并按记录尾部 p_bind_pool_bases 的
// 录制期池基址把池局部编号换成绝对编号。
#include <stdio.h>
#include <string.h>

#include "direct/bind_defer.h"

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

// 假 guest 内存：g_mem[addr] 可读。
static uint8_t g_mem[4096];
static int g_read_calls;
static int t_rd(void *opaque, uint64_t addr, void *dst, size_t n) {
    (void)opaque;
    g_read_calls++;
    if (addr + n > sizeof g_mem) return -1;
    memcpy(dst, g_mem + addr, n);
    return 0;
}

// 组一条 OP_BIND_TEX/SAMP/IMG 载荷：定长头 + n 个 h + （deferred 时）p_bind_pool_bases 尾。
// h[] 物理上只有 32 项：n 越界时按截断载荷写（解析器按头里的 n 判 INVALID）。
static size_t put_rec(uint8_t *buf, int stage, int first, int n, int defer, uint64_t src,
                      const uint64_t *h, int32_t tbase, int32_t sbase) {
    p_bind_handles r;
    memset(&r, 0, sizeof r);
    r.stage = stage; r.first = first; r.n = n; r.defer = defer; r.src = src;
    int phys = n > 32 ? 32 : n;
    if (h) memcpy(r.h, h, (size_t)phys * 8u);
    memcpy(buf, &r, offsetof(p_bind_handles, h) + (size_t)phys * 8u);
    size_t len = offsetof(p_bind_handles, h) + (size_t)phys * 8u;
    if (defer) {
        p_bind_pool_bases b = { tbase, sbase };
        memcpy(buf + len, &b, sizeof b);
        len += sizeof b;
    }
    return len;
}

int main(void) {
    const char *why = NULL;
    p_bind_handles out;
    uint8_t buf[sizeof(p_bind_handles) + sizeof(p_bind_pool_bases) + 8];

    // 非 deferred：h[] 原样透出，不读 guest 内存。
    {
        uint64_t h[2] = { 0x12345 | (3ull << 20), 0x9abcd };
        size_t n = put_rec(buf, 1, 4, 2, 0, 0, h, 0, 0);
        g_read_calls = 0;
        memset(&out, 0xAA, sizeof out);
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, (uint32_t)n, &out, &why) == S2A_BH_OK,
              "non-deferred bind parses");
        CHECK(out.stage == 1 && out.first == 4 && out.n == 2 && out.h[0] == h[0] && out.h[1] == h[1],
              "non-deferred handles pass through");
        CHECK(g_read_calls == 0, "non-deferred bind never reads guest memory");
    }

    // deferred 组合纹理：回放时读 src 指向的句柄数组，按 {tbase,sbase} 重基。
    {
        // 游戏在录制之后才填的句柄数组（记录里 h[] 是陈旧字节，不算数）。
        uint64_t *gh = (uint64_t *)(g_mem + 0x200);
        gh[0] = 42 | (7ull << 20);      // tid=42 sid=7
        gh[1] = 9;                       // tid=9  sid=0 → sid 保持 0（bh_fresh 的 0 特例）
        gh[2] = 300 | (11ull << 20);
        memset(buf + offsetof(p_bind_handles, h), 0xEE, 3 * 8 + 8);   // 模拟陈旧 h[] + bases 区
        size_t n = put_rec(buf, 1, 9, 3, 1, 0x200, NULL, 100, 1000);   // h[]=0（录制时未填）
        g_read_calls = 0;
        memset(&out, 0, sizeof out);
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, (uint32_t)n, &out, &why) == S2A_BH_OK,
              "deferred texture bind parses");
        CHECK(g_read_calls == 1, "deferred bind reads the handle array once");
        CHECK(out.h[0] == ((42 + 100) | ((7 + 1000ull) << 20)), "tid + tbase, sid + sbase");
        CHECK(out.h[1] == 9 + 100, "sid 0 stays 0 (texture ID 0 is a real pool entry)");
        CHECK(out.h[2] == ((300 + 100) | ((11 + 1000ull) << 20)), "rebase applies per entry");
        CHECK(out.first == 9 && out.n == 3, "slot window preserved");
    }

    // deferred 独立采样器：句柄本身存为 id<<20（GetSeparateSamplerHandle）→ (id + sbase)<<20。
    {
        uint64_t *gh = (uint64_t *)(g_mem + 0x400);
        gh[0] = 5ull << 20;
        size_t n = put_rec(buf, 1, 0, 1, 1, 0x400, NULL, 0, 1000);
        memset(&out, 0, sizeof out);
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, (uint32_t)n, &out, &why) == S2A_BH_OK,
              "deferred sampler bind parses");
        CHECK(out.h[0] == ((5 + 1000ull) << 20), "separate sampler id rebased by sbase");
    }

    // deferred 独立纹理/图像：句柄只有纹理 id → id + tbase（sbase 录为 0，不生效）。
    {
        uint64_t *gh = (uint64_t *)(g_mem + 0x600);
        gh[0] = 77;
        gh[1] = 88;
        size_t n = put_rec(buf, 5, 0, 2, 1, 0x600, NULL, 100, 0);
        memset(&out, 0, sizeof out);
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, (uint32_t)n, &out, &why) == S2A_BH_OK,
              "deferred image bind parses");
        CHECK(out.h[0] == 177 && out.h[1] == 188, "separate texture/image id rebased by tbase");
    }

    // 负控 1：deferred 记录缺 p_bind_pool_bases 尾（载荷被截）→ INVALID，不读内存。
    {
        size_t n = put_rec(buf, 1, 0, 2, 1, 0x200, NULL, 0, 0);
        g_read_calls = 0;
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, (uint32_t)(n - 8), &out, &why) == S2A_BH_INVALID,
              "deferred record without appended pool bases is rejected");
        CHECK(g_read_calls == 0, "rejected record never reads guest memory");
    }

    // 负控 2：deferred 句柄数组读不到 → MEMORY（真实失败，不算已绑定）。
    {
        size_t n = put_rec(buf, 1, 0, 2, 1, 0x3ff0, NULL, 0, 0);   // src 越出假内存
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, (uint32_t)n, &out, &why) == S2A_BH_MEMORY,
              "unreadable deferred handle array is a memory failure");
    }

    // 负控 3：n 越界 / 载荷太短 → INVALID。
    {
        size_t n = put_rec(buf, 1, 0, 40, 0, 0, NULL, 0, 0);      // n=40 > 32
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, (uint32_t)n, &out, &why) == S2A_BH_INVALID,
              "handle count outside the record is rejected");
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, 8, &out, &why) == S2A_BH_INVALID,
              "short payload is rejected");
    }

    // defer=1 但 src=0（录制侧没给数组）→ 直通，不读内存（bh_fresh 同条件）。
    {
        size_t n = put_rec(buf, 1, 0, 2, 1, 0, NULL, 0, 0);
        g_read_calls = 0;
        CHECK(s2a_bind_handles_parse(t_rd, NULL, buf, (uint32_t)n, &out, &why) == S2A_BH_OK,
              "deferred flag without a source pointer passes through");
        CHECK(g_read_calls == 0, "no source pointer, no read");
    }

    if (fails) { printf("bind defer test: %d FAILURES\n", fails); return 1; }
    printf("bind defer test: ok\n");
    return 0;
}

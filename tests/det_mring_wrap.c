// 确定性记录环：跨过环尾的记录必须读回写入的字节。期望是写入前的原样，不靠被测函数再算一遍。
#include "../runtime/src/det_mring.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;

static void check(const char *what, int ok) {
    printf("%s %s\n", ok ? "通" : "不通", what);
    fails += !ok;
}

static uint64_t advance(uint64_t len) { return 16 + ((len + 15) & ~15ull); }

// 与 det.c mq_drain 同一读法：头两段各 8 字节，负载能线性放就用环内指针，否则拼进 scratch。
static int read_rec(const uint8_t *ring, uint64_t n, uint64_t r, uint64_t *addr, uint64_t *len, uint8_t *dst) {
    mring_get(addr, ring, n, r, 8);
    mring_get(len, ring, n, r + 8, 8);
    uint32_t nlen = (uint32_t)*len;
    uint8_t scratch[4096];
    if (nlen > sizeof scratch) return 0;
    const void *src = mring_payload(ring, n, r + 16, nlen, scratch);
    if (nlen) memcpy(dst, src, nlen);
    return 1;
}

static void write_rec(uint8_t *ring, uint64_t n, uint64_t w, uint64_t addr, const void *src, uint64_t len) {
    uint64_t h[2] = { addr, len };
    mring_put(ring, n, w, h, 16);
    mring_put(ring, n, w + 16, src, len);
}

static void fill(uint8_t *p, uint32_t n, uint8_t seed) {
    for (uint32_t i = 0; i < n; i++) p[i] = (uint8_t)(seed + i * 3);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0); // ASan 中止前也保留断言读数。
    enum { N = 256, POISON = 32 };
    uint8_t *buf = malloc(N + POISON);
    if (!buf) return 2;
    uint8_t *ring = buf;
    memset(ring, 0xFF, N);
    memset(ring + N, 0xA5, POISON);

    // 不跨环尾：负载来源必须是环内指针，字节与直接 memcpy 相同。
    {
        uint8_t src[20]; fill(src, 20, 1);
        write_rec(ring, N, 32, 0x1111, src, 20);
        const uint8_t *lin = mring_linear(ring, N, 32 + 16, 20);
        uint8_t scratch[20]; memset(scratch, 0xEE, sizeof scratch);
        const void *got = mring_payload(ring, N, 32 + 16, 20, scratch);
        int poison_ok = 1;
        for (int i = 0; i < POISON; i++) if (ring[N + i] != 0xA5) poison_ok = 0;
        check("不跨环尾时负载指针在环内、与线性地址相同", lin && got == lin && lin == ring + 48);
        check("不跨环尾的负载字节与写入相同", lin && !memcmp(lin, src, 20));
        check("不跨环尾不改 scratch、不写出环", scratch[0] == 0xEE && poison_ok);
    }

    // 生产对齐：游标 16 对齐、环长 16 对齐。头放得下，负载从 N-16 起、长度 40，跨过环尾 24 字节。
    {
        memset(ring, 0xFF, N);
        uint8_t src[40]; fill(src, 40, 7);
        uint64_t w = N - 32, addr = 0xABCDE000ULL;
        write_rec(ring, N, w, addr, src, 40);
        uint64_t got_addr = 0, got_len = 0; uint8_t dst[40]; memset(dst, 0, sizeof dst);
        int rd = read_rec(ring, N, w, &got_addr, &got_len, dst);
        int poison_ok = 1;
        for (int i = 0; i < POISON; i++) if (ring[N + i] != 0xA5) poison_ok = 0;
        check("负载跨环尾：地址和长度读回", rd && got_addr == addr && got_len == 40);
        check("负载跨环尾：40 字节与写入相同（含卷回环首的 24 字节）", rd && !memcmp(dst, src, 40));
        // 这个样本的 40 字节为 7..124，不含 0xA5；检查实际读回，不能只查毒区未写。
        check("负载跨环尾：读回不含环外的 0xA5", rd && !memchr(dst, 0xA5, sizeof dst));
        check("负载跨环尾：环外毒字节没被写掉", poison_ok);
    }

    // 头本身被环尾切开（8 字节字段跨尾）。生产游标是 16 对齐时碰不到，读法仍要按段。
    {
        memset(ring, 0xFF, N);
        uint8_t src[4] = { 9, 8, 7, 6 };
        uint64_t w = N - 4, addr = 0x1122334455667788ULL;
        write_rec(ring, N, w, addr, src, 4);
        uint64_t got_addr = 0, got_len = 0; uint8_t dst[4];
        int rd = read_rec(ring, N, w, &got_addr, &got_len, dst);
        check("头跨环尾：地址读回 0x1122334455667788", rd && got_addr == addr);
        check("头跨环尾：长度 4、负载 4 字节", rd && got_len == 4 && !memcmp(dst, src, 4));
    }

    // 两条记录：第一条负载跨尾，第二条从卷绕后的游标接着写，按放锁时的步进读回。
    {
        memset(ring, 0xFF, N);
        uint8_t a[40], b[3]; fill(a, 40, 20); fill(b, 3, 90);
        uint64_t w = N - 32;
        write_rec(ring, N, w, 0x10, a, 40);
        uint64_t w2 = w + advance(40);
        write_rec(ring, N, w2, 0x20, b, 3);
        uint64_t r = w, addr, len; uint8_t dst[40];
        int ok1 = read_rec(ring, N, r, &addr, &len, dst) && addr == 0x10 && len == 40 && !memcmp(dst, a, 40);
        r += advance(len);
        uint8_t dst2[3];
        int ok2 = read_rec(ring, N, r, &addr, &len, dst2) && addr == 0x20 && len == 3 && !memcmp(dst2, b, 3);
        check("跨尾记录之后的下一条仍按 16 对齐步进读回", ok1 && ok2 && r == w2);
    }

    // 负载刚好贴到环尾、不越过：仍走线性指针。
    {
        memset(ring, 0xFF, N);
        uint8_t src[16]; fill(src, 16, 50);
        uint64_t w = N - 32;
        write_rec(ring, N, w, 0x30, src, 16);
        const void *got = mring_payload(ring, N, w + 16, 16, NULL);
        check("负载刚好到环尾仍是环内指针且字节相同", got == ring + (N - 16) && !memcmp(got, src, 16));
    }

    // 不留环外垫片：线性读的 24 个越界字节必须命中 ASan 的堆红区。
    {
        uint8_t *exact = malloc(N);
        if (!exact) { free(buf); return 2; }
        memset(exact, 0xFF, N);
        uint8_t src[40]; fill(src, 40, 7);
        uint64_t w = N - 32, addr = 0xABCDE000ULL;
        write_rec(exact, N, w, addr, src, sizeof src);
        uint64_t got_addr = 0, got_len = 0; uint8_t dst[40];
        int rd = read_rec(exact, N, w, &got_addr, &got_len, dst);
        check("恰好 N 字节的环：跨尾读不越界、头和负载相同",
              rd && got_addr == addr && got_len == sizeof src && !memcmp(dst, src, sizeof src));
        free(exact);
    }

    free(buf);
    printf("%s det_mring_wrap：%d 处不符\n", fails ? "不通" : "通", fails);
    return fails ? 1 : 0;
}

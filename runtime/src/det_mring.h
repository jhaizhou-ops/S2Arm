#pragma once
// 确定性记录档的宿主写待办环（det.c）。off 是单调游标，物理下标 = off % n。
// 跨过环尾的一段不能按线性 memcpy 读：环是恰好 n 字节的映射，线性读会落到环外，卷绕回去的字节被丢掉。
#include <stdint.h>
#include <string.h>

static inline void mring_put(uint8_t *ring, uint64_t n, uint64_t off, const void *src, uint64_t len) {
    const uint8_t *s = src;
    for (uint64_t i = 0; i < len; i++) ring[(off + i) % n] = s[i];
}

static inline void mring_get(void *dst, const uint8_t *ring, uint64_t n, uint64_t off, uint64_t len) {
    uint8_t *d = dst;
    while (len) {
        uint64_t p = off % n, n1 = n - p;
        if (n1 > len) n1 = len;
        memcpy(d, ring + p, (size_t)n1);
        d += n1; off += n1; len -= n1;
    }
}

// 这一段不跨环尾时回环内指针（调用方直接用）；跨了回 NULL。
static inline const uint8_t *mring_linear(const uint8_t *ring, uint64_t n, uint64_t off, uint64_t len) {
    uint64_t p = off % n;
    if (len > n - p) return NULL;
    return ring + p;
}

// 负载来源：不跨环尾回环内指针（与线性 memcpy 同一地址）；跨了才抄进 scratch。
static inline const void *mring_payload(const uint8_t *ring, uint64_t n, uint64_t off, uint32_t nlen, void *scratch) {
    const uint8_t *lin = mring_linear(ring, n, off, nlen);
    if (lin) return lin;
    if (nlen) mring_get(scratch, ring, n, off, nlen);
    return scratch;
}

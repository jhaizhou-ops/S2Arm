// 最小 SHA-256（FIPS 180-4），只用于直连内容身份与 implementationKey。
// 不依赖 OpenSSL / CommonCrypto：host 测试、NDK、NativeAOT 同 DSO 三处必须一致。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t h[8];
    uint64_t bytes;
    uint8_t block[64];
    uint32_t used;
} s2a_sha256;

void s2a_sha256_init(s2a_sha256 *ctx);
void s2a_sha256_update(s2a_sha256 *ctx, const void *data, size_t bytes);
void s2a_sha256_final(s2a_sha256 *ctx, uint8_t out[32]);

// 输出小写 hex + NUL；out 至少 65 字节。
void s2a_sha256_hex(const uint8_t digest[32], char out[65]);

// 诊断/记账：累计被哈希的字节数与 update 调用次数（读取即清零）。采样剖析里 SHA-256 曾是
// 绘制线程最大单项，没有这两个数就只能猜“是谁在逐笔哈希”。
void s2a_sha256_stats(uint64_t *bytes, uint64_t *calls);

#ifdef __cplusplus
}
#endif

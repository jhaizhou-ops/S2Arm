#pragma once
#include <stdint.h>
#include <stddef.h>
#include "sha256.h"
#define CC_SHA256_DIGEST_LENGTH 32
typedef uint32_t CC_LONG;
typedef s2a_sha256 CC_SHA256_CTX;
void CC_SHA256_Init(CC_SHA256_CTX *ctx);
void CC_SHA256_Update(CC_SHA256_CTX *ctx, const void *data, CC_LONG length);
void CC_SHA256_Final(unsigned char *md, CC_SHA256_CTX *ctx);
unsigned char *CC_SHA256(const void *data, CC_LONG length, unsigned char *md);

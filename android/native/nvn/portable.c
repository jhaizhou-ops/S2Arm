// Android 兼容实现：CommonCrypto SHA-256 与 CFDictionary 指针表，只服务共享 NVN 前端。
#include <stdlib.h>
#include <string.h>
#include "../../../runtime/direct/sha256.h"
#include "../../../runtime/nvn/compat/CommonCrypto/CommonDigest.h"
#include "../../../runtime/nvn/compat/CoreFoundation/CoreFoundation.h"

void CC_SHA256_Init(CC_SHA256_CTX *ctx) { s2a_sha256_init(ctx); }
void CC_SHA256_Update(CC_SHA256_CTX *ctx, const void *data, CC_LONG length) { s2a_sha256_update(ctx, data, length); }
void CC_SHA256_Final(unsigned char *md, CC_SHA256_CTX *ctx) { s2a_sha256_final(ctx, md); }
unsigned char *CC_SHA256(const void *data, CC_LONG length, unsigned char *md) {
    s2a_sha256 ctx; s2a_sha256_init(&ctx); s2a_sha256_update(&ctx, data, length); s2a_sha256_final(&ctx, md); return md;
}

struct pair { const void *key, *value; };
struct __CFDictionary { struct pair *items; size_t count, capacity; };

// 兼容层只创建过共享前端的程序键表；CFRelease 只释放本层生成的表，其余对象保持空操作，
// 避免 Apple 专有代码路径在 Android 上误放非本层指针。
static struct __CFDictionary *g_dicts[16];
static size_t g_dict_count;

CFMutableDictionaryRef CFDictionaryCreateMutable(const void *allocator, long capacity,
                                                 const void *keyCallBacks, const void *valueCallBacks) {
    (void)allocator; (void)keyCallBacks; (void)valueCallBacks;
    struct __CFDictionary *dict = calloc(1, sizeof *dict);
    if (!dict) return NULL;
    dict->capacity = capacity > 0 ? (size_t)capacity : 16;
    dict->items = calloc(dict->capacity, sizeof *dict->items);
    if (!dict->items) { free(dict); return NULL; }
    if (g_dict_count < sizeof g_dicts / sizeof g_dicts[0]) g_dicts[g_dict_count++] = dict;
    return dict;
}
const void *CFDictionaryGetValue(CFMutableDictionaryRef dict, const void *key) {
    if (!dict) return NULL;
    for (size_t i = 0; i < dict->count; i++) if (dict->items[i].key == key) return dict->items[i].value;
    return NULL;
}
void CFDictionarySetValue(CFMutableDictionaryRef dict, const void *key, const void *value) {
    if (!dict) return;
    for (size_t i = 0; i < dict->count; i++)
        if (dict->items[i].key == key) { dict->items[i].value = value; return; }
    if (dict->count == dict->capacity) {
        size_t next = dict->capacity * 2;
        struct pair *grown = realloc(dict->items, next * sizeof *grown);
        if (!grown) return;
        dict->items = grown; dict->capacity = next;
    }
    dict->items[dict->count++] = (struct pair){key, value};
}
void CFDictionaryRemoveValue(CFMutableDictionaryRef dict, const void *key) {
    if (!dict) return;
    for (size_t i = 0; i < dict->count; i++) {
        if (dict->items[i].key == key) {
            dict->items[i] = dict->items[--dict->count];
            return;
        }
    }
}

long CFDictionaryGetCount(CFMutableDictionaryRef dict) { return dict ? (long)dict->count : 0; }
void CFDictionaryApplyFunction(CFMutableDictionaryRef dict, CFDictionaryApplierFunction applier, void *context) {
    if (!dict || !applier) return;
    for (size_t i = 0; i < dict->count; i++) applier(dict->items[i].key, dict->items[i].value, context);
}
void CFRelease(const void *object) {
    if (!object) return;
    struct __CFDictionary *dict = (struct __CFDictionary *)object;
    for (size_t i = 0; i < g_dict_count; i++) {
        if (g_dicts[i] != dict) continue;
        g_dicts[i] = g_dicts[--g_dict_count];
        free(dict->items); free(dict);
        return;
    }
}

#pragma once
#include <stdint.h>
#include <time.h>
typedef double CFAbsoluteTime;
typedef double CFTimeInterval;
typedef struct __CFDictionary *CFMutableDictionaryRef;
typedef const void *CFDictionaryKeyCallBacks;
typedef const void *CFDictionaryValueCallBacks;
static inline CFAbsoluteTime CFAbsoluteTimeGetCurrent(void) {
    struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
    return (double)t.tv_sec + 1e-9 * (double)t.tv_nsec;
}
CFMutableDictionaryRef CFDictionaryCreateMutable(const void *allocator, long capacity,
                                                 const void *keyCallBacks, const void *valueCallBacks);
const void *CFDictionaryGetValue(CFMutableDictionaryRef dict, const void *key);
void CFDictionarySetValue(CFMutableDictionaryRef dict, const void *key, const void *value);
void CFDictionaryRemoveValue(CFMutableDictionaryRef dict, const void *key);
long CFDictionaryGetCount(CFMutableDictionaryRef dict);
typedef void (*CFDictionaryApplierFunction)(const void *key, const void *value, void *context);
void CFDictionaryApplyFunction(CFMutableDictionaryRef dict, CFDictionaryApplierFunction applier, void *context);
void CFRelease(const void *object);

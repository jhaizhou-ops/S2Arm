// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Diagnostic Metal allocation-object identities, not physical-page accounting.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#if (defined(NVN_MEM_ACCOUNT_SKIP_BACKING) || defined(NVN_MEM_ACCOUNT_REPLACE_OWNER) || defined(NVN_MEM_ACCOUNT_BY_SIZE) || defined(NVN_MEM_ACCOUNT_TABLE_SUM)) && !defined(S2A_MEM_ACCOUNT_TEST)
#error Test-only negative control must not enter a production build
#endif
static NSHashTable *nvn_mem_account_snapshot(void) {
    return [[NSHashTable alloc] initWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality capacity:0];
}
enum { NVN_MEM_BUFFER, NVN_MEM_TEXTURE, NVN_MEM_HEAP, NVN_MEM_OTHER };
static id nvn_mem_account_root(id resource, unsigned *kind) {
    id node = resource;
    if ([node conformsToProtocol:@protocol(MTLTexture)]) {
        for (unsigned n = 0; ; n++) {
            id parent = [(id<MTLTexture>)node parentTexture];
            if (!parent) break;
            if (parent == node || n == 63) return nil;
            node = parent;
        }
#ifndef NVN_MEM_ACCOUNT_SKIP_BACKING
        id buffer = [(id<MTLTexture>)node buffer];
        if (buffer) node = buffer;
#endif
    }
    if ([node conformsToProtocol:@protocol(MTLTexture)] || [node conformsToProtocol:@protocol(MTLBuffer)]) {
        id heap = [(id<MTLResource>)node heap];
        if (heap) node = heap;
    }
    if ([node conformsToProtocol:@protocol(MTLHeap)]) *kind = NVN_MEM_HEAP;
    else if ([node conformsToProtocol:@protocol(MTLBuffer)]) *kind = NVN_MEM_BUFFER;
    else if ([node conformsToProtocol:@protocol(MTLTexture)]) *kind = NVN_MEM_TEXTURE;
    else if ([node conformsToProtocol:@protocol(MTLAllocation)]) *kind = NVN_MEM_OTHER;
    else return nil;
    return node;
}
@interface NvnMemAccount : NSObject
@property(nonatomic,strong) NSHashTable *roots;
@property(nonatomic,strong) NSMapTable *owners;
@property(nonatomic,strong) NSMapTable *allocationBytes;
@property(nonatomic) uint64_t bytes, bufferBytes, textureBytes, heapBytes, otherBytes;
@property(nonatomic) NSUInteger buffers, textures, heaps, others, duplicateReferences, ignored;
@property(nonatomic) BOOL overflow;
- (void)addResource:(id)resource;
- (void)addResource:(id)resource ownerMask:(uint64_t)mask;
@end
@implementation NvnMemAccount
- (instancetype)init { if ((self = [super init])) { _roots = nvn_mem_account_snapshot(); _owners = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory capacity:0]; _allocationBytes = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory capacity:0]; } return self; }
- (void)addResource:(id)resource { [self addResource:resource ownerMask:0]; }
- (void)addResource:(id)resource ownerMask:(uint64_t)mask {
    unsigned kind = 0; id root = nvn_mem_account_root(resource, &kind);
    if (!root) { if (resource) _ignored++; return; }
    uint64_t previous = [[_owners objectForKey:root] unsignedLongLongValue];
#ifdef NVN_MEM_ACCOUNT_REPLACE_OWNER
    previous = 0; // test-only wrong implementation: destroys previously observed owners
#endif
    [_owners setObject:@(previous | mask) forKey:root];
#ifndef NVN_MEM_ACCOUNT_TABLE_SUM
    if ([_roots containsObject:root]) { _duplicateReferences++; return; }
#endif
    uint64_t bytes = kind == NVN_MEM_HEAP ? [(id<MTLHeap>)root size] : [(id<MTLAllocation>)root allocatedSize];
#ifdef NVN_MEM_ACCOUNT_BY_SIZE
    // Wrong implementation for the independent-allocation negative control.
    for (id previousRoot in _roots) {
        uint64_t previousBytes = [[_allocationBytes objectForKey:previousRoot] unsignedLongLongValue];
        if (previousBytes == bytes) { _duplicateReferences++; return; }
    }
#endif
    [_roots addObject:root];
    // Bound totals so the signed residual is representable; never wrap into a plausible budget.
    if (bytes > INT64_MAX || _bytes > (uint64_t)INT64_MAX - bytes) { _overflow = YES; return; }
    if (![_allocationBytes objectForKey:root]) [_allocationBytes setObject:@(bytes) forKey:root];
    _bytes += bytes;
    if (kind == NVN_MEM_HEAP) { _heapBytes += bytes; _heaps++; }
    else if (kind == NVN_MEM_BUFFER) { _bufferBytes += bytes; _buffers++; }
    else if (kind == NVN_MEM_TEXTURE) { _textureBytes += bytes; _textures++; }
    else { _otherBytes += bytes; _others++; }
}
@end

// Signed GPU-minus-known residual. Negative means overlapping/unmatched semantics, not a free/eviction budget.
static BOOL nvn_mem_account_delta(uint64_t gpu, uint64_t known, int64_t *out) {
    if (gpu > INT64_MAX || known > INT64_MAX) return NO;
    *out = (int64_t)gpu - (int64_t)known;
    return YES;
}

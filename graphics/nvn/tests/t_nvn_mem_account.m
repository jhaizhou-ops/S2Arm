// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include "../gfx/nvn/nvn_mem_account.inc"
static unsigned checks, failures;
#define CK(c,msg) do{checks++;if(!(c)){failures++;fprintf(stderr,"RED %s\n",msg);}}while(0)
@interface FakeNode:NSObject
@property(nonatomic) unsigned kind;
@property(nonatomic) NSUInteger allocatedSize,size;
@property(nonatomic,strong) id parentTexture,buffer,heap;
@end
@implementation FakeNode
- (BOOL)conformsToProtocol:(Protocol*)p {
    if (p==@protocol(MTLTexture)) return _kind==NVN_MEM_TEXTURE;
    if (p==@protocol(MTLBuffer)) return _kind==NVN_MEM_BUFFER;
    if (p==@protocol(MTLHeap)) return _kind==NVN_MEM_HEAP;
    if (p==@protocol(MTLAllocation)) return _kind==NVN_MEM_OTHER;
    return [super conformsToProtocol:p];
}
- (BOOL)isEqual:(id)o { return [o isKindOfClass:FakeNode.class] && ((FakeNode*)o).kind==_kind && ((FakeNode*)o).allocatedSize==_allocatedSize; }
- (NSUInteger)hash { return _kind; }
@end
static FakeNode *node(unsigned k,NSUInteger size) { FakeNode*n=[FakeNode new];n.kind=k;n.size=n.allocatedSize=size;return n; }
int main(void) {@autoreleasepool {
    FakeNode *buffer=node(NVN_MEM_BUFFER,32768),*a=node(NVN_MEM_TEXTURE,32768),*b=node(NVN_MEM_TEXTURE,32768);
    a.buffer=b.buffer=buffer;
    NvnMemAccount*l=[NvnMemAccount new];[l addResource:a];[l addResource:b];
    CK(l.bytes==32768,"two buffer-backed textures must count one32768 allocation");CK(l.buffers==1 && l.textures==0,"texture buffer must resolve to buffer root");
    FakeNode *base=node(NVN_MEM_TEXTURE,8192),*view=node(NVN_MEM_TEXTURE,8192);view.parentTexture=base;
    l=[NvnMemAccount new];[l addResource:base];[l addResource:view];CK(l.bytes==8192 && l.textures==1,"view shares base texture allocation");
    FakeNode *view2=node(NVN_MEM_TEXTURE,32768);view2.parentTexture=a;
    l=[NvnMemAccount new];[l addResource:view2];[l addResource:buffer];CK(l.bytes==32768 && l.buffers==1,"view of buffer texture resolves through both levels");
    l=[NvnMemAccount new];[l addResource:buffer];[l addResource:node(NVN_MEM_BUFFER,32768)];
    CK(l.bytes==65536 && l.buffers==2,"equal-value independent allocations remain distinct");
    l=[NvnMemAccount new];[l addResource:node(NVN_MEM_TEXTURE,8192)];[l addResource:node(NVN_MEM_TEXTURE,8192)];
    CK(l.bytes==16384 && l.textures==2,"equal-size independent textures must remain two allocations");
    FakeNode *dynamic=node(NVN_MEM_OTHER,4096);l=[NvnMemAccount new];[l addResource:dynamic ownerMask:1];dynamic.allocatedSize=8192;[l addResource:dynamic ownerMask:2];
    CK(l.bytes==4096 && [[l.allocationBytes objectForKey:dynamic] unsignedLongLongValue]==4096,"allocation metadata sampled once per snapshot root");
    FakeNode *heap=node(NVN_MEM_HEAP,131072),*hb1=node(NVN_MEM_BUFFER,32768),*hb2=node(NVN_MEM_BUFFER,32768);hb1.heap=hb2.heap=heap;
    l=[NvnMemAccount new];[l addResource:hb1];[l addResource:hb2];[l addResource:heap];CK(l.bytes==131072 && l.heaps==1,"shared heap counted once at capacity");
    FakeNode *ht=node(NVN_MEM_TEXTURE,65536);ht.heap=heap;[l addResource:ht];CK(l.bytes==131072,"heap texture overlaps buffered heap owners");
    l=[NvnMemAccount new];for(unsigned i=0;i<6;i++) [l addResource:buffer ownerMask:1ull<<i];CK(l.bytes==32768 && l.duplicateReferences==5,"same allocation across six owner tables counted once");
    l=[NvnMemAccount new];[l addResource:nil];[l addResource:[NSObject new]];CK(l.bytes==0 && l.ignored==1,"non-resources not counted as allocation bytes");
    FakeNode*z=node(NVN_MEM_TEXTURE,0);[l addResource:z];CK(l.bytes==0 && l.textures==1,"zero-sized memoryless object contributes zero bytes");
    l=[NvnMemAccount new];[l addResource:a ownerMask:1];[l addResource:b ownerMask:2];
    CK([[l.owners objectForKey:buffer] unsignedLongLongValue]==3 && l.bytes==32768,"shared buffer has both owners,bytes once");
    [l addResource:view2 ownerMask:4];
    CK([[l.owners objectForKey:buffer] unsignedLongLongValue]==7,"view adds owner to same backing root");
    FakeNode*equal=node(NVN_MEM_BUFFER,32768);[l addResource:equal ownerMask:8];
    CK(l.owners.count==2 && [[l.owners objectForKey:equal] unsignedLongLongValue]==8 && [[l.owners objectForKey:buffer] unsignedLongLongValue]==7,"equal-value different roots have separate owner masks");
    [l addResource:equal ownerMask:8];
    CK([[l.owners objectForKey:equal] unsignedLongLongValue]==8 && l.bytes==65536,"same owner repeated does not change mask or bytes");
    __weak FakeNode *weak;
    @autoreleasepool {
        NSHashTable*snap=nvn_mem_account_snapshot();
        @autoreleasepool { FakeNode*t=node(NVN_MEM_TEXTURE,1);weak=t;[snap addObject:t];t=nil; }
        CK(weak!=nil,"strong snapshot must keep removed-owner object alive");snap=nil;
    }
    CK(weak==nil,"snapshot release must release its own reference");
    int64_t delta=0;
    CK(nvn_mem_account_delta(1024,2048,&delta) && delta==-1024,"negative residual must remain signed");
    CK(nvn_mem_account_delta(4096,2048,&delta) && delta==2048,"positive residual must remain signed");
    CK(!nvn_mem_account_delta(UINT64_MAX,0,&delta),"oversized GPU counter has no representable signed residual");
    l=[NvnMemAccount new];[l addResource:node(NVN_MEM_OTHER,4096)];
    CK(l.bytes==4096 && l.others==1,"standalone MTLAllocation command storage counted once");
    l=[NvnMemAccount new];[l addResource:node(NVN_MEM_BUFFER,INT64_MAX)];[l addResource:node(NVN_MEM_BUFFER,1)];
    CK(l.overflow && l.bytes==INT64_MAX,"overflow must be explicit,not wrap");
    id<MTLDevice>d=MTLCreateSystemDefaultDevice();unsigned real=0;
    if(d){@autoreleasepool{
        NSUInteger row=256,align=[d minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatRGBA8Unorm];if(align>row)row=align;
        id<MTLBuffer>buf=[d newBufferWithLength:row*64*2 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
        id<MTLTexture>t1=[buf newTextureWithDescriptor:td offset:0 bytesPerRow:row],t2=[buf newTextureWithDescriptor:td offset:row*64 bytesPerRow:row];
        CK(buf && t1 && t2,"real Metal buffer-texture fixtures must exist");
        if(buf && t1 && t2){l=[NvnMemAccount new];[l addResource:t1];[l addResource:t2];[l addResource:buf];CK(l.bytes==buf.allocatedSize && l.buffers==1 && l.textures==0,"real Metal two aliases + buffer counted once");real=1;}
    }}
    fprintf(stderr,"Ledger checks %u/%u; realMetalObjectFixture=%u (no command submission)\n",checks-failures,checks,real);
    if (failures) { fprintf(stderr,"✗ t_nvn_mem_account: %u/%u checks failed\n",failures,checks); return 1; }
    if (!d) { fprintf(stderr,"UNTESTED real Metal fixture:no device\n"); return 75; }
    fprintf(stderr,"✓ t_nvn_mem_account: %u/%u; real Metal objects, no command submission\n",checks,checks);
    return 0;
}}

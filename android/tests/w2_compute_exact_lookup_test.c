// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
/* Real offline library + runtime lookup; worker boundary deliberately unavailable. */
#include "nvn/nvn_vk_compute_lookup.h"
#include "direct/offline_library.h"
#include "direct/program_cache.h"
#include "direct/compile_worker.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static struct s2a_direct_compile_context context;
// 宿主强符号桩：lookup.c 的截断诊断走弱缝 __android_log_print，macOS 未定义
// 弱外部须强符号补位。
int __android_log_print(int prio,const char *tag,const char *fmt,...) {
    (void)prio;(void)tag;(void)fmt;return 0;
}
static int compiled;
int s2a_direct_provider_compile_context(struct s2a_direct_compile_context *out) { *out=context;return 0; }
int s2a_program_cache_load(const char *root,const uint8_t id[32],uint8_t **b,size_t *n,uint8_t sha[32],char *why,size_t cap) {
    (void)root;(void)id;(void)b;(void)n;(void)sha;(void)why;(void)cap;abort();
}
int s2a_program_cache_store_async(const char *root,const uint8_t id[32],const uint8_t *b,size_t n) {
    (void)root;(void)id;(void)b;(void)n;abort();
}
int s2a_compile_worker_run(uint64_t s,uint64_t g,const char *j,size_t n,const uint8_t id[32],int deadline,
    int(*pause)(void*),void(*resume)(void*),void *ctx,uint8_t **b,size_t *len,char *why,size_t cap) {
    (void)s;(void)g;(void)j;(void)n;(void)id;(void)deadline;(void)pause;(void)resume;(void)ctx;(void)b;(void)len;
    compiled++;snprintf(why,cap,"test worker unavailable");return -1;
}
int main(int argc,char **argv) {
    if(argc!=8 && argc!=9)return 2;
    /* root, identity hex, REQUEST path, closure, profile, expected hit, prepared profile alignment */
    context=(struct s2a_direct_compile_context){.session=11,.generation=22,.direct_abi=1,
        .translator_closure=argv[4],.profile_hash=argv[5],.offline_profile_available=1};
    struct nvk_compute_request r={.session=11,.generation=22,.canonical_bytes=1};
    r.profile.storage_alignment=(uint32_t)strtoul(argv[7],NULL,10);
    snprintf(r.profile.hash,sizeof r.profile.hash,"%s",argv[5]);
    if(strlen(argv[2])!=64)return 2;
    for(int i=0;i<32;i++){unsigned b;if(sscanf(argv[2]+i*2,"%2x",&b)!=1)return 2;r.identity[i]=(uint8_t)b;}
    FILE *f=fopen(argv[3],"rb");if(!f)return 2;
    fseek(f,0,SEEK_END);r.json_bytes=(size_t)ftell(f);rewind(f);r.json=malloc(r.json_bytes);
    if(!r.json||fread(r.json,1,r.json_bytes,f)!=r.json_bytes)return 2;fclose(f);
    struct nvk_compute_lookup_options options={.revision_root=argv[1], .no_live_compile=argc==9?atoi(argv[8]):0};
    struct nvk_compute_lookup_result out;char why[256];
    int rc=nvk_compute_lookup(&r,&context,&options,&out,why,sizeof why);
    int hit=atoi(argv[6]);int ok=hit ? !rc&&out.origin==NVK_COMPUTE_OFFLINE&&!compiled : rc&&compiled==(options.no_live_compile?0:1)&&!out.bytes;
    printf("expected=%s actual=%s offline_hits=%llu offline_misses=%llu compile=%d reason=%s\n",
        hit?"hit":"miss",rc?"miss":"hit",(unsigned long long)s2a_offline_hits(),(unsigned long long)s2a_offline_misses(),compiled,rc?why:"");
    free(r.json);free(out.bytes);return ok?0:1;
}

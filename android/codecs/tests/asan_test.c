#include "../s2a_avc.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint32_t bytes,token; uint8_t *au; } frame;
static s2a_avc_diag diagnostic(void) { s2a_avc_diag d={0};d.abi_version=1;d.struct_size=sizeof(d);return d; }
static uint32_t word(FILE *file) { uint32_t value;assert(fread(&value,4,1,file)==1);return value; }
static uint8_t *blob(FILE *file,uint32_t bytes) { uint8_t *p=malloc(bytes);assert(p);assert(fread(p,1,bytes,file)==bytes);return p; }
static void sequence(s2a_avc_config cfg,uint8_t *sps,uint32_t sn,uint8_t *pps,uint32_t pn,frame *frames,uint32_t count,int may_fail) {
    s2a_avc *h=NULL;s2a_avc_diag d=diagnostic();
    int rc=s2a_avc_create(&cfg,&h,&d);
    if(rc) { assert(may_fail && !h);return; }
    for(uint32_t i=0;i<count;i++) {
        d=diagnostic();rc=s2a_avc_decode(h,frames[i].au,frames[i].bytes,sps,sn,pps,pn,frames[i].token,&d);
        if(rc) { assert(may_fail);break; }
        s2a_avc_planes_v1 view={0};view.abi_version=1;view.struct_size=sizeof(view);d=diagnostic();
        assert(!s2a_avc_planes(h,frames[i].token,&view,&d));
        assert(view.token==frames[i].token && view.generation==1);
        for(unsigned j=0;j<3;j++) {
            const s2a_avc_plane *p=&view.plane[j];assert(p->data && p->width && p->height && p->stride>=p->width);
            assert((uint64_t)(p->height-1)*p->stride+p->width<=p->capacity);
            volatile uint8_t pixel=p->data[(size_t)(p->height-1)*p->stride+p->width-1];(void)pixel;
        }
    }
    d=diagnostic();assert(!s2a_avc_destroy(h,&d));assert(!s2a_avc_test_live_allocations());
}
int main(int argc,char **argv) {
    assert(argc==2);FILE *file=fopen(argv[1],"rb");assert(file);
    s2a_avc_config cfg={1,sizeof(cfg),word(file),word(file)};
    uint32_t sn=word(file),pn=word(file),count=word(file);assert(sn<=512 && pn<=512 && count<=1024);
    uint8_t *sps=blob(file,sn),*pps=blob(file,pn);frame *frames=calloc(count,sizeof(*frames));assert(frames);
    for(uint32_t i=0;i<count;i++) { frames[i].bytes=word(file);frames[i].token=word(file);frames[i].au=blob(file,frames[i].bytes); }
    fclose(file);
    s2a_avc_test_fail_allocation(-1);sequence(cfg,sps,sn,pps,pn,frames,count,0);
    uint64_t calls=s2a_avc_test_allocation_calls();assert(calls<10000);
    for(uint64_t i=0;i<calls;i++) { s2a_avc_test_fail_allocation((int64_t)i);sequence(cfg,sps,sn,pps,pn,frames,count,1);assert(!s2a_avc_test_live_allocations()); }
    for(uint32_t i=0;i<count;i++) free(frames[i].au);
    free(frames);free(sps);free(pps);
    printf("PASS ASan/UBSan decode, token/planes, %llu allocation failures, live=0\n",(unsigned long long)calls);
    return 0;
}

#include "../s2a_avc.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned rd(FILE*f){unsigned v;assert(fread(&v,4,1,f)==1);return v;}
static unsigned char* blob(FILE*f,unsigned n){unsigned char*p=malloc(n);assert(p);assert(fread(p,1,n,f)==n);return p;}
static s2a_avc_diag diag(void){s2a_avc_diag d={0};d.abi_version=1;d.struct_size=sizeof(d);return d;}
int main(int argc,char **argv){
 assert(argc==2); FILE*f=fopen(argv[1],"rb");assert(f);
 unsigned sn=rd(f),pn=rd(f),an=rd(f),qn=rd(f);
 unsigned char*sps=blob(f,sn),*pps=blob(f,pn),*au=blob(f,an),*qps=blob(f,qn);fclose(f);
 s2a_avc_config cfg={1,sizeof(cfg),16,16};s2a_avc*h=NULL;s2a_avc_diag d=diag();
 assert(s2a_avc_create(&cfg,&h,&d)==0);
 d=diag();int rc=s2a_avc_decode(h,au,an,sps,sn,pps,pn,1,&d);printf("first rc=%d stage=%u\n",rc,d.stage);
 assert(rc==0);
 d=diag();rc=s2a_avc_decode(h,au,an,sps,sn,qps,qn,2,&d);printf("second rc=%d stage=%u code=%d\n",rc,d.stage,d.code);
 assert(rc==0);
 d=diag();assert(!s2a_avc_destroy(h,&d));
 assert(!s2a_avc_test_live_allocations());
 free(sps);free(pps);free(au);free(qps);
 return 0;
}

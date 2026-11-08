// 真实 Linux ARM64 4 KiB：生产 copy + tracker + plat_vm_alias；QueryMemory 只描述夹具映射。
#include "../../../native/runtime/tracking/readonly_copy.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
extern void *fixture_create(int);
extern int fixture_none(void),fixture_protection(uint64_t),fixture_gpu_modified(void);
extern void fixture_hole(int);
static int checked;
#define CHECK(x) do { ++checked; assert(x); } while(0)
int main(int argc,char **argv) {
    CHECK(argc==2);int private=!strcmp(argv[1],"private");uint8_t *p=fixture_create(!private);CHECK(p!=NULL);
    int bounded = strcmp(argv[1], "legacy") != 0;
    CHECK(s2a_android_readonly_configure_bounded(2)==EINVAL);
    CHECK(s2a_android_readonly_configure_bounded(bounded)==0);
    CHECK(sysconf(_SC_PAGESIZE)==4096);CHECK(fixture_none()==0);CHECK(fixture_gpu_modified());
    if(!strcmp(argv[1],"red")){puts("ENTER original protected source load");fflush(stdout);return *(volatile uint8_t *)(p+0x400);}
    uint8_t result[0x1100];memset(result,0xcc,sizeof result);
    int e=s2a_android_copy_guest_readonly((uintptr_t)p+0x400,result,0x200);
    CHECK(s2a_android_readonly_configure_bounded(bounded)==0);
    CHECK(s2a_android_readonly_configure_bounded(!bounded)==EBUSY);
    if(private){CHECK(e!=0);CHECK(result[0]==0xcc);}
    else {
        CHECK(e==0);for(size_t i=0;i<0x200;i++)CHECK(result[i]==(uint8_t)((0x400+i)*37+11));
        CHECK(s2a_android_copy_guest_readonly((uintptr_t)p+0xff0,result,0x1020)==0);
        for(size_t i=0;i<0x1020;i++)CHECK(result[i]==(uint8_t)((0xff0+i)*37+11));
        fixture_hole(1);CHECK(s2a_android_copy_guest_readonly((uintptr_t)p+0x400,result,1)==EFAULT);fixture_hole(0);
        CHECK(s2a_android_copy_guest_readonly(UINT64_MAX-4,result,16)==EINVAL);
        CHECK(s2a_android_copy_guest_readonly((uintptr_t)p,p+1,8)==EINVAL);
        CHECK(s2a_android_copy_guest_readonly(0,NULL,0)==0);
    }
    CHECK(fixture_protection((uintptr_t)p)==0);CHECK(fixture_gpu_modified());
    printf("PASS %s: %d assertions; true Linux ARM64 4096-byte pages\n",argv[1],checked);return 0;
}

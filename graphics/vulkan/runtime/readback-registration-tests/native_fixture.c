#define _GNU_SOURCE
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/syscall.h>
#include <linux/memfd.h>
#include "../../../track/track.c"
#include "../../../../android/native/runtime/tracking/platform.c"
#include "../../../../android/native/plat_android.c"
#define API __attribute__((visibility("default")))
static int fixture_fd=-1;
API uint64_t ep_alloc(void) {
    fixture_fd=(int)syscall(__NR_memfd_create,"s2arm-readback-epoch",MFD_CLOEXEC);
    if(fixture_fd<0||ftruncate(fixture_fd,8192))abort();
    void*p=mmap(0,8192,PROT_READ|PROT_WRITE,MAP_SHARED,fixture_fd,0);
    if(p==MAP_FAILED)abort();memset(p,0x11,8192);return(uint64_t)(uintptr_t)p;
}
API void ep_prepare(void) {
    s2a_track_prepare();s2a_track_set_readflush(1);s2a_track_set_walias(1);
    s2a_track_set_emul(0);s2a_track_set_emul_store(0);
}
API void ep_callback(void(*fn)(uint64_t,uint64_t,int)){s2a_track_set_touch(fn);}
API void ep_reprotect(uint64_t a,uint64_t n,int p){s2a_track_reprotect(a,n,p);}
API void ep_touch(uint64_t a){s2a_track_touch(a);}
API void ep_write(uint64_t a,void*p,uint64_t n){s2a_track_write_untracked(a,p,n,1);}
API int ep_perm(uint64_t a){return s2a_track_platform_protection(a);}
API int ep_dirty(uint64_t a,uint64_t n){return s2a_track_gpu_modified(a,n);}
API int ep_byte(uint64_t a){uint8_t v;s2a_track_read_untracked(a,&v,1);return v;}
API void ep_free(uint64_t a){munmap((void*)(uintptr_t)a,8192);close(fixture_fd);}

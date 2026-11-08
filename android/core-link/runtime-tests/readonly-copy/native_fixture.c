// 真 Linux 共享映射 + 生产 tracker/alias/read-copy；逻辑 VM 查询只为这段测试内存提供显式端点。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "s2a_native.h"
#include "../../../../graphics/track/s2a_track.h"
#include "../../../../graphics/track/track_platform.h"
#include "../../../../platform/plat.h"
#include <errno.h>
#include <stdatomic.h>
#include <stdint.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
static uint8_t *base; static size_t bytes; static int query_hole;
int s2a_mem_query(uint64_t address,s2a_meminfo *out) {
    memset(out,0,sizeof(*out));
    if (address<(uintptr_t)base || address>=(uintptr_t)base+bytes || query_hole) return EFAULT;
    out->base=(uintptr_t)base; out->size=bytes; out->perm=3; return 0;
}
int s2a_mem_readable(uint64_t address,uint64_t size) {
    s2a_meminfo info;
    if (!size) return 1;
    return size <= UINT64_MAX-address && !s2a_mem_query(address,&info) &&
        (info.perm&1) && address+size <= info.base+info.size;
}
void *fixture_create(int shared) {
    bytes=3*(size_t)sysconf(_SC_PAGESIZE);
    // Keep the synthetic guest arena inside the production 39-bit address contract
    // also on Linux/x64 hosts; this is a hint, never a fixed overwrite of a mapping.
    base=mmap((void *)(uintptr_t)0x2000000000ull,bytes,PROT_READ|PROT_WRITE,(shared?MAP_SHARED:MAP_PRIVATE)|MAP_ANONYMOUS,-1,0);
    if (base!=MAP_FAILED && ((uintptr_t)base+bytes)>(1ull<<39)) { munmap(base,bytes); return NULL; }
    if (base==MAP_FAILED) return NULL;
    for (size_t i=0;i<bytes;i++) base[i]=(uint8_t)(i*37+11);
    s2a_track_prepare(); s2a_track_set_readflush(1);
    return base;
}
int fixture_none(void) {
    s2a_track_reprotect((uintptr_t)base,0x400,S2A_TRACK_NONE);
    return s2a_track_platform_protection((uintptr_t)base);
}
int fixture_protection(uint64_t address) { return s2a_track_platform_protection(address); }
int fixture_gpu_modified(void) { return s2a_track_gpu_modified((uintptr_t)base,0x400); }
void fixture_hole(int on) { query_hole=on; }
int fixture_readonly(void) { return mprotect(base,bytes,PROT_READ)?errno:0; }

// ---- readflush 档（#199 收口回写）：托管不跟踪读碰 GPU 改过、还没回写的 NONE 子页前先回写 ----
int fixture_reprotect(uint64_t a,uint64_t n,int perm) { s2a_track_reprotect(a,n,perm); return 0; }
int fixture_gpu_mod(uint64_t a,uint64_t n) { return s2a_track_gpu_modified(a,n); }
void fixture_write_untracked(uint64_t a,const void *src,uint64_t n,int flush) { s2a_track_write_untracked(a,src,n,flush); }
// 信号探针：记「托管读是否进了 SIGSEGV 处理」。数到之后链回调用者原本的处理（dotnet 的 AV 报点），行为不变
static _Atomic int g_entered;
static struct sigaction g_segv_old;
static void tripwire(int sig,siginfo_t *si,void *uc) {
    atomic_fetch_add(&g_entered,1);
    if ((g_segv_old.sa_flags&SA_SIGINFO)&&g_segv_old.sa_sigaction) { g_segv_old.sa_sigaction(sig,si,uc); return; }
    if (g_segv_old.sa_handler&&g_segv_old.sa_handler!=SIG_DFL&&g_segv_old.sa_handler!=SIG_IGN) { g_segv_old.sa_handler(sig); return; }
    signal(sig,SIG_DFL); raise(sig);
}
int fixture_arm_tripwire(void) {
    struct sigaction sa; memset(&sa,0,sizeof sa);
    sa.sa_sigaction=tripwire; sa.sa_flags=SA_SIGINFO; sigemptyset(&sa.sa_mask);
    return sigaction(SIGSEGV,&sa,&g_segv_old)?errno:0;
}
int fixture_entered(void) { return atomic_load(&g_entered); }

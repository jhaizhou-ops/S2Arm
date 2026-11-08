// Linux host: real production svc_mem and real kernel mappings; tracker/writer
// endpoints are explicit fixture providers. No Android/Bionic or GPU execution.
#include "../../runtime/src/native.h"
#include "../../platform/plat.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <unistd.h>

static uint8_t *source;
static uint64_t logical_size = 0x1000;
static void *code_object;
S2A_TEST_MOD_TABLE(64); int g_nmod;
#include "../core-link/runtime-tests/vm/core_endpoints.inc"
void s2a_mem_test_setup(uint64_t,uint64_t,uint64_t,uint64_t,void *,uint64_t);
void s2a_mem_test_sysres(uint64_t,uint64_t);
void s2a_mem_test_map(uint64_t,uint64_t);
int svc_mem(int,uint64_t *,uint64_t);

void s2a_thread_dump(void) { abort(); }
void s2a_det_apply_host(uint32_t id,int op) { (void)id;(void)op; abort(); }
static int writer_active;
int s2a_android_guest_writers_begin(void) { assert(!writer_active); writer_active=1; return 0; }
// #1003（c105bd4fc）起 svc_mem.c 的 0x2C 全空页增页走「只串行」准入，条件不成立时升级为全体停稳：
//   本测试里写者只有一个，串行与全体停稳等价——begin_serial 同 begin 占住写者，quiesce 只能在已持有时调用。
int s2a_android_guest_writers_begin_serial(void) { assert(!writer_active); writer_active=1; return 0; }
int s2a_android_guest_writers_quiesce(void) { assert(writer_active); return 0; }
void s2a_android_guest_writers_end(void) { assert(writer_active); writer_active=0; }
// 撤销状态由真实 VM 组合层提供；这两个目标只链 svc_mem.c 的映射逻辑，事务永不撤销。
int s2a_android_guest_writers_revoked(void) { return 0; }
int s2a_android_vm_writer_held(void) { return writer_active; }
// 替身：svc_mem.c 的 GetInfo 读硬件核数与计数器换算（真实现在 thread.c / os.c，本单测不链）；取 Switch 1 口径
int s2a_thread_hw_cores(void) { return 4; }
uint64_t s2a_ns_to_tick(uint64_t ns) { return (uint64_t)((unsigned __int128)ns * 19200000u / 1000000000u); }
int s2a_android_guest_writers_ready(void) { return 0; }
int s2a_track_backing_begin(uint64_t a,uint64_t n,uint64_t s) { (void)a;(void)n;(void)s; abort(); }
void s2a_track_backing_reset_before_publish(uint64_t a,uint64_t n) { (void)a;(void)n; abort(); }
void s2a_track_backing_end(uint64_t a,uint64_t n,int m,int c) { (void)a;(void)n;(void)m;(void)c; abort(); }
void s2a_track_prot_changed(uint64_t a,uint64_t n) { (void)a;(void)n; abort(); }
void s2a_track_write(uint64_t a,uint64_t n) { (void)a;(void)n; abort(); }
static uint64_t notified_addr,notified_size;
static void on_prot(uint64_t a,uint64_t n) { notified_addr=a; notified_size=n; }
static void on_write(uint64_t a,uint64_t n) { (void)a;(void)n; assert(writer_active); }
static uint64_t call(int number,uint64_t a,uint64_t b,uint64_t c) {
    uint64_t regs[32]={a,b,c}; assert(svc_mem(number,regs,0)==1); assert(!writer_active); return regs[0];
}
static int perms(void *address) {
    FILE *f=fopen("/proc/self/maps","r"); assert(f); char line[512],p[8]; unsigned long lo,hi;
    while(fgets(line,sizeof line,f)) if(sscanf(line,"%lx-%lx %7s",&lo,&hi,p)==3 && lo<=(uintptr_t)address && (uintptr_t)address<hi) {
        fclose(f); return (p[0]=='r'?1:0)|(p[1]=='w'?2:0)|(p[2]=='x'?4:0);
    }
    fclose(f); return -1;
}
int main(void) {
    if (plat_page_size()!=0x1000) { puts("SKIP guest-page: requires a real 4 KiB Linux host page"); return 77; }
    void *window=NULL; assert(!plat_vm_reserve(0x100000,0x4000,1ull<<39,&window));
    uint8_t *protect=(uint8_t *)window+0x11000, *stack=(uint8_t *)window+0x21000;
    source=(uint8_t *)window+0x80000;
    assert(mmap(source,0x4000,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS|MAP_FIXED,-1,0)==source);
    source[7]=0x19;
    s2a_mem_test_setup((uintptr_t)window+0xc0000,0x40000,(uintptr_t)window,0x100000,source,0x4000);
    s2a_mem_test_sysres(0,0x4000);
    s2a_track_hooks hooks={on_prot,on_write,NULL,NULL}; s2a_register_track_hooks(&hooks);
    assert(!mprotect(protect-0x1000,0x3000,PROT_READ|PROT_WRITE));
    protect[-1]=0x51; protect[0x1000]=0x62;
    assert(!call(0x02,(uintptr_t)protect,0x1000,1));
    assert(perms(protect)==1 && perms(protect-0x1000)==3 && perms(protect+0x1000)==3);
    assert(notified_addr==(uintptr_t)protect && notified_size==0x1000);
    assert(!call(0x02,(uintptr_t)protect,0x1000,3));
    assert(perms(protect)==3 && protect[-1]==0x51 && protect[0x1000]==0x62);
    s2a_layout *layout=(s2a_layout *)(uintptr_t)s2a_layout_get();
    layout->stack_base=(uintptr_t)stack; layout->stack_size=0x1000;
    assert(!call(0x04,(uintptr_t)stack,(uintptr_t)source,0x1000));
    assert(perms(stack)==3 && perms(stack-0x1000)==0 && perms(stack+0x1000)==0);
    assert(notified_addr==(uintptr_t)stack && notified_size==0x1000);
    stack[7]=0x42;
    assert(!call(0x05,(uintptr_t)stack,(uintptr_t)source,0x1000));
    assert(source[7]==0x42 && perms(stack)==0 && perms(stack-0x1000)==0 && perms(stack+0x1000)==0);
    // Once SVCs are live, an unowned map mutation must reach the production
    // epoch assertion. The fixture reports its real begin/end state above.
    int epoch_pipe[2]; assert(!pipe(epoch_pipe)); pid_t epoch_child=fork(); assert(epoch_child>=0);
    if (!epoch_child) {
        close(epoch_pipe[0]); assert(dup2(epoch_pipe[1],2)==2); close(epoch_pipe[1]);
        s2a_mem_test_map((uintptr_t)window+0x50000,0x1000);
        _exit(42);
    }
    close(epoch_pipe[1]); char epoch_report[1024]; ssize_t epoch_got=read(epoch_pipe[0],epoch_report,sizeof epoch_report-1); close(epoch_pipe[0]);
    int epoch_status=0; assert(waitpid(epoch_child,&epoch_status,0)==epoch_child);
    assert(WIFSIGNALED(epoch_status) && WTERMSIG(epoch_status)==SIGABRT);
    assert(epoch_got>0); epoch_report[epoch_got]=0;
    assert(strstr(epoch_report,"不在 VM epoch 内"));
    // A real alias succeeds, protection then fails, and restoration is forced to
    // fail. The production deterministic reader must abort rather than fall back.
    extern int g_det;
    int s2a_det_shmem_map(uint64_t,const void *,uint64_t,uint64_t,int);
    void plat_vm_test_set_protect_fail(int), plat_vm_test_set_restore_fail(int);
    int fds[2]; assert(!pipe(fds)); pid_t child=fork(); assert(child>=0);
    if (!child) {
        close(fds[0]); assert(dup2(fds[1],2)==2); close(fds[1]);
        g_det=3; plat_vm_test_set_protect_fail(1); plat_vm_test_set_restore_fail(1);
        (void)s2a_det_shmem_map((uintptr_t)window+0x30000,source,0x1000,0x1000,PROT_READ|PROT_WRITE);
        _exit(42);
    }
    close(fds[1]); char report[1024]; ssize_t got=read(fds[0],report,sizeof report-1); close(fds[0]);
    int status=0; assert(waitpid(child,&status,0)==child);
    assert(WIFSIGNALED(status) && WTERMSIG(status)==SIGABRT);
    assert(got>0); report[got]=0;
    assert(strstr(report,"确定性共享内存无法恢复地址保留"));
    assert(!munmap(window,0x100000));
    puts("guest-page: 4K page isolation and poisoned alias fatal path passed");
    return 0;
}

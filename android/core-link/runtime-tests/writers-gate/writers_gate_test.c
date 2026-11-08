// 真实 thread owner、gate、SVC、VM/tracker 与内核信号；仅 module/TSD 和未执行端点为测试 provider。
// trylock 包装只观察/延迟真实返回，不替换 writers 实现。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef S2A_UNIT_TEST
#define S2A_UNIT_TEST
#endif
#include "../../../../runtime/src/thread.c"
#include "../../../native/guest_signal.h"
#include <sys/mman.h>
#include <fcntl.h>
void s2a_crash_install(void);
int s2a_svc_park_all(int);
extern void s2a_fault_test_guest_stack(void (*)(void),void *), s2a_thread_test_loop(void *);
extern char s2a_thread_test_guest_start[],s2a_thread_test_guest_end[];
static _Atomic int race_active, race_serial_busy, race_hook_entered, race_release;
static _Atomic int checks;
static void check(int yes,const char *name){++checks;if(!yes){fprintf(stderr,"FAIL %s\n",name);exit(1);}}
pthread_key_t g_key18,g_keytls,g_keytlr,g_keygate;
void sw_gate(void){abort();}
uint64_t plat_tsd_base(void){return 0;}
int plat_tsd_init(void){return 0;}
int plat_tsd_offset(uint32_t key,uint64_t *offset){*offset=(uint64_t)key*8;return 0;}
module_t *module_of(const void *pc){static module_t m; m.base=(void*)s2a_thread_test_guest_start; m.patch_off=s2a_thread_test_guest_end-s2a_thread_test_guest_start; uintptr_t p=(uintptr_t)pc;return p>=(uintptr_t)s2a_thread_test_guest_start&&p<(uintptr_t)s2a_thread_test_guest_end?&m:NULL;}
int s2a_direct_fault(void*a,int w,void*c){(void)a;(void)w;(void)c;return 0;}
// 前两个字段与已有 thread_guest.S 的测试循环共享布局。
struct job{_Atomic uint64_t count,stop;_Atomic int phase,release;thr_t*thread; uint64_t result; int mode; uint8_t *target; int svc; uint64_t pc, size;};
static _Thread_local struct job *job;
int svc_mem(int, uint64_t *, uint64_t);
static _Atomic int busy_go, busy_done, busy_owner_ready, busy_owner_release;
static int stop_mode; static _Atomic int serial_acquired,allow_serial_return; static int timeout_mode, progress_mode;
// The native authority is production code; only the host boundary/shared lock is controlled.
#include "backing_test.h"
static uint64_t *external_backing;
static pthread_mutex_t test_backing_lock=PTHREAD_MUTEX_INITIALIZER;
static s2a_backing_wait test_backing;
static int test_foreground=1;
int s2a_android_host_backing_admission(unsigned writer,uint64_t *deadline) {
    if(external_backing) return writer ? backing_test_admission(external_backing,deadline) : 0;
    pthread_mutex_lock(&test_backing_lock);
    int found=writer && writer==test_backing.writer && test_backing.owner;
    if(found)*deadline=s2a_backing_deadline(&test_backing,test_foreground,S2A_BACKING_ADMISSION_MARGIN_MS);
    pthread_mutex_unlock(&test_backing_lock);return found;
}
static void *backing_pinger(void *arg) {
    int ms=(int)(intptr_t)arg;uint64_t owner=0;
    for(int t=0;t<ms;t+=200) {
        pthread_mutex_lock(&test_backing_lock);
        owner=s2a_backing_publish(&test_backing,s2a_android_guest_writers_epoch(),owner,1,test_foreground);
        pthread_mutex_unlock(&test_backing_lock);usleep(200000);
    }return NULL;
}
 static uint64_t request_result; static int busy_owner_error, active_svc=0x2C, core_mode; static _Atomic int serial_busy_seen; static unsigned observed_epoch;
static uint8_t *target,*source; static const uint64_t ret_pc=0x12344, orig_pc=0x12340;
// 只在本夹具里模拟 16 KiB 宿主页与实际分配失败；生产 svc_mem.c 仍走真实 plat_page_size/mmap。
size_t __real_plat_page_size(void);
static int fake_page16;
size_t __wrap_plat_page_size(void){ return fake_page16 ? 0x4000 : __real_plat_page_size(); }
void *__real_mmap(void*,size_t,int,int,int,off_t);
static int fail_map_alloc;
void *__wrap_mmap(void *address,size_t size,int prot,int flags,int fd,off_t offset){
    if (fail_map_alloc && address==target && size && prot==(PROT_READ|PROT_WRITE) && (flags&MAP_FIXED) && (flags&MAP_SHARED)) {
        fail_map_alloc=0; errno=ENOMEM; return MAP_FAILED;
    }
    return __real_mmap(address,size,prot,flags,fd,offset);
}
S2A_TEST_MOD_TABLE(64); int g_nmod;
void s2a_mem_test_setup(uint64_t,uint64_t,uint64_t,uint64_t,void*,uint64_t);
void s2a_mem_test_sysres(uint64_t,uint64_t);
#include "../../../native/runtime/tracking/runtime.h"
#include "../../../native/runtime/vm/memory.h"
// Schedule a real independent roster owner after the contender acquires serial.
// This never replaces a production lock or changes production timing functions.
static _Atomic int roster_held;
static void *hold_roster_after_serial(void *unused) {
 (void)unused;pthread_mutex_lock(&G);atomic_store(&roster_held,1);
 fprintf(stderr,"INJECT: independent owner holds G for 350ms after admission serial acquired\n");
 usleep(350000);pthread_mutex_unlock(&G);return NULL;
}
int __real_pthread_mutex_trylock(pthread_mutex_t *lock);
int __wrap_pthread_mutex_trylock(pthread_mutex_t *lock){
 int error=__real_pthread_mutex_trylock(lock);
 if (atomic_load(&race_active) && lock==&android_vm_serial && error==EBUSY) atomic_store(&race_serial_busy,1);
 if(lock==&android_vm_serial && job && !error && external_backing && getenv("S2A_TEST_ROSTER_HANDOFF")) {
   pthread_t blocker;check(!pthread_create(&blocker,NULL,hold_roster_after_serial,NULL),"roster blocker starts");
   while(!atomic_load(&roster_held))usleep(100);pthread_detach(blocker);
 }

 if(lock==&android_vm_serial && job && error==EBUSY){observed_epoch=atomic_load(&android_vm_epoch);atomic_store(&serial_busy_seen,1);}
 if(lock==&android_vm_serial && job && !error && stop_mode==2){atomic_store(&serial_acquired,1);while(!atomic_load(&allow_serial_return))usleep(100);}
 return error;
}
static uint64_t call_map(void){
  int svc=job&&job->svc?job->svc:active_svc;
  uint8_t *dst=job&&job->target?job->target:target;
  uint64_t pc=job&&job->pc?job->pc:ret_pc;
  uint64_t length=job&&job->size?job->size:0x4000;
  uint64_t regs[32]={(uintptr_t)dst,(svc==4||svc==5)?(uintptr_t)source:length,(svc==4||svc==5)?0x4000:0};
  if(svc==1){regs[0]=0;regs[1]=0x200000;regs[2]=0;}
  if(svc==6){regs[0]=regs[1]=0;regs[2]=(uintptr_t)dst;}
  if(svc==3)regs[0]++;
  uint64_t r=gate_dispatch(pc,regs);check(r==regs[0],"actual gate result matches registers");return r;
}

static void guest_body(void){s2a_thread_test_loop(job);}
static void *worker(void *arg){
    job=arg;
    thr_t*t=calloc(1,sizeof*t);check(t!=NULL,"allocate fixture thread");job->thread=t;
    t->pt=pthread_self();t->started=1;atomic_store(&t->in_svc,1);t->prio=44;t->mask=7;
    check(!pthread_cond_init(&t->cv,NULL),"thread condition");
    glock();t->all=g_all;g_all=t;pthread_mutex_unlock(&G);
    thread_bind_host(t); // 生产入口屏障、TSD 与 guest TLS 初始化。
    sw_xstack_thread_init(((uintptr_t)__builtin_frame_address(0)-0x400)&~15ull,0);
    if(s2a_android_fault_probe())_exit(111);
    check(core_part(t)==core_mode,"full/off/ondemand participation matches fixture");
    core_acquire(t); // 即使不参与虚拟核也必须执行 Android VM 返回屏障。
    atomic_store(&job->phase,1);
    while(!atomic_load(&busy_go))usleep(100);
    job->result=call_map(); if (!atomic_load(&race_active)) request_result=job->result;
    if (atomic_load(&race_active)) {
        check(job->result==0 || job->result==0xD401,"concurrent guest result");
        svc_exit(t); atomic_store(&job->phase,3);
        size_t n=1<<20; void *stack=mmap(NULL,n,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
        check(stack!=MAP_FAILED,"race guest stack"); s2a_fault_test_guest_stack(guest_body,(char*)stack+n); munmap(stack,n);
        core_release(t); s2a_tlr_free(t->tlr); t->tlr=NULL; s2a_android_fault_thread_fini(); sw_xstack_thread_fini(); s2a_android_altstack_free();
        glock(); t->exited=1; t->closed=1; pthread_setspecific(g_keythr,NULL); thr_free(t); pthread_mutex_unlock(&G); atomic_store(&job->phase,4); return NULL;
    }
    atomic_store(&busy_done,1);
    int svc=job->svc?job->svc:active_svc; uint8_t *dst=job->target?job->target:target; uint64_t length=job->size?job->size:0x4000;
    check(request_result==(svc==3?0xCC01:0),"actual gate retains correct guest result");
    check(!android_vm_active&&!android_vm_beginning&&!android_vm_memory_scope&&!t->vm_admission_wait,"no leaked thread admission state");
    check(!atomic_load(&android_vm_epoch),"own epoch ended before guest return");
    if(core_mode)check(atomic_load(&t->held_core)!=0,"normal return reacquired virtual core");
    if(svc==3||svc==6)check(!s2a_mem_mapped((uintptr_t)dst,length),"non-mapping SVC leaves metadata unchanged");
    else if(svc==0x2D)check(!s2a_mem_mapped((uintptr_t)dst,length),"actual physical unmap metadata");
    else {check(s2a_mem_mapped((uintptr_t)dst,length),"actual mapped metadata");if(job->mode==2)check(dst[7]==0,"new physical page is zero");else {dst[7]=0x6b;check(dst[7]==0x6b,"actual target writable");}}
    svc_exit(t);atomic_store(&job->phase,3);
    size_t n=1<<20;void*stack=mmap(NULL,n,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    check(stack!=MAP_FAILED,"fixture guest stack");
    s2a_fault_test_guest_stack(guest_body,(char*)stack+n);munmap(stack,n);
    core_release(t);s2a_tlr_free(t->tlr);t->tlr=NULL;
    s2a_android_fault_thread_fini();sw_xstack_thread_fini();s2a_android_altstack_free();
    glock();t->exited=1;t->closed=1;pthread_setspecific(g_keythr,NULL);thr_free(t);pthread_mutex_unlock(&G);
    atomic_store(&job->phase,4);return NULL;
}
static void until(_Atomic int*s,int want){uint64_t end=plat_now_ns()+3000000000ull;while(atomic_load(s)!=want){if(plat_now_ns()>end){fprintf(stderr,"timeout phase %d expected %d\n",atomic_load(s),want);exit(1);}usleep(100);}}
static pthread_t start(struct job*j){memset(j,0,sizeof*j);pthread_t p;check(!pthread_create(&p,NULL,worker,j),"create worker");until(&j->phase,1);return p;}
static void stop(struct job*j,pthread_t p){atomic_store(&j->stop,1);check(!pthread_join(p,NULL),"worker joins");}
// 真实登记线程停在宿主回调（off_guest，不持虚拟核）：0x2C 空页增页的停世界到期只由它造成。
static void *callback_worker(void *arg){
    struct job *j=arg; job=j;
    thr_t *t=calloc(1,sizeof*t); check(t!=NULL,"allocate callback thread"); j->thread=t;
    t->pt=pthread_self(); t->started=1; atomic_store(&t->in_svc,1); t->prio=44; t->mask=7;
    check(!pthread_cond_init(&t->cv,NULL),"callback condition");
    glock(); t->all=g_all; g_all=t; pthread_mutex_unlock(&G);
    thread_bind_host(t);
    sw_xstack_thread_init(((uintptr_t)__builtin_frame_address(0)-0x400)&~15ull,0);
    if(s2a_android_fault_probe())_exit(111);
    check(core_part(t)==core_mode,"callback core participation");
    core_acquire(t);
    s2a_core_leave();   // 生产回调入口：off_guest=1 且不持虚拟核
    atomic_store(&j->phase,1);
    while(!atomic_load(&j->release)) usleep(100);
    s2a_core_enter();   // 普通上下文回到 guest 侧
    svc_exit(t); atomic_store(&j->phase,3);
    core_release(t); s2a_tlr_free(t->tlr); t->tlr=NULL;
    s2a_android_fault_thread_fini(); sw_xstack_thread_fini(); s2a_android_altstack_free();
    glock(); t->exited=1; t->closed=1; pthread_setspecific(g_keythr,NULL); thr_free(t); pthread_mutex_unlock(&G);
    atomic_store(&j->phase,4); return NULL;
}
static pthread_t start_callback(struct job*j){memset(j,0,sizeof*j);j->mode=1;pthread_t p;check(!pthread_create(&p,NULL,callback_worker,j),"create callback thread");until(&j->phase,1);return p;}
static pthread_t start_action(struct job*j){memset(j,0,sizeof*j);j->mode=2;pthread_t p;check(!pthread_create(&p,NULL,worker,j),"create action thread");until(&j->phase,1);return p;}
// callback-map：A 停在宿主回调时，B 的 0x2C 空页增页必须由只串行路径完成；修前这里会按 2 s 停世界到期退出 134。
// callback-unmap：同样条件下 0x2D 必须等 A 回到安全点；释放 A 前 B 不得完成。
static int run_callback(int unmap){
    struct job callback; pthread_t a=start_callback(&callback);
    check(atomic_load(&callback.thread->off_guest), "callback thread is off guest before the SVC");
    struct job action; pthread_t b=start_action(&action);
    atomic_store(&busy_go,1);
    if(unmap){
        uint64_t epoch_deadline=plat_now_ns()+1000000000ull;
        while(!atomic_load(&android_vm_epoch)&&!atomic_load(&busy_done)&&plat_now_ns()<epoch_deadline)usleep(1000);
        check(!atomic_load(&busy_done)&&(!atomic_load(&action.phase)||atomic_load(&action.phase)==1),"unmap cannot complete while callback is live");
        check(atomic_load(&android_vm_epoch)!=0,"0x2D published its writer epoch");
        check(atomic_load(&callback.thread->off_guest),"callback still off guest while 0x2D waits");
        check(s2a_mem_mapped((uintptr_t)target,0x4000),"target stays mapped until callback reaches safe point");
        atomic_store(&callback.release,1);
        until(&action.phase,3);
        check(action.result==0,"unmap succeeds after callback release");
        check(!s2a_mem_mapped((uintptr_t)target,0x4000),"actual physical unmap metadata");
    } else {
        until(&action.phase,3);
        check(action.result==0,"empty-page map succeeds while callback is live");
        check(atomic_load(&callback.thread->off_guest),"map did not wait for the host callback");
        check(s2a_mem_mapped((uintptr_t)target,0x4000),"actual mapped metadata");
        check(target[7]==0,"new physical page is zero");
        check(!atomic_load(&android_vm_epoch)&&!atomic_load(&android_vm_current_serial_only),"fast epoch retired before guest return");
    }
    atomic_store(&callback.release,1);
    until(&callback.phase,4);
    stop(&callback,a); stop(&action,b);
    printf("PASS callback-%s: %s\n", unmap?"unmap":"map", unmap?"0x2D waited for host callback":"0x2C added an empty page without stopping the callback");
    return 0;
}
// 相邻活页：4K 宿主页下新页与已映射页是不同宿主页；新增页必须为零，邻居内容原样。
static int run_callback_adjacent(void){
    uint64_t regs[32]={(uintptr_t)target,0x1000,0};
    check(svc_mem(0x2C,regs,0)==1 && regs[0]==0,"adjacent base page maps");
    target[0]=0x5a;
    struct job callback; pthread_t a=start_callback(&callback);
    struct job action; memset(&action,0,sizeof action); action.mode=2; action.target=target+0x1000; action.svc=0x2C; action.size=0x1000;
    pthread_t b; check(!pthread_create(&b,NULL,worker,&action),"create adjacent action");
    until(&action.phase,1); atomic_store(&busy_go,1);
    until(&action.phase,3);
    check(action.result==0,"adjacent empty page maps while callback is live");
    check(atomic_load(&callback.thread->off_guest),"adjacent map did not wait for callback");
    check(target[0]==0x5a,"live neighbour content preserved");
    check((target+0x1000)[7]==0,"adjacent new page is zero");
    check(s2a_mem_mapped((uintptr_t)target,0x2000),"both adjacent pages mapped");
    atomic_store(&callback.release,1); until(&callback.phase,4);
    stop(&callback,a); stop(&action,b);
    printf("PASS callback-map-adjacent: live neighbour preserved, new page zero\n"); return 0;
}
// 16K 模型：整宿主页新增可走只串行；相邻的整页活映射内容保留。
static int run_callback_adjacent16(void){
    fake_page16=1;
    uint64_t regs[32]={(uintptr_t)target,0x4000,0};
    check(svc_mem(0x2C,regs,0)==1 && regs[0]==0,"16K base host page maps");
    target[0]=0x5a;
    struct job callback; pthread_t a=start_callback(&callback);
    struct job action; memset(&action,0,sizeof action); action.mode=2; action.target=target+0x4000; action.svc=0x2C; action.size=0x4000;
    pthread_t b; check(!pthread_create(&b,NULL,worker,&action),"create 16K adjacent action");
    until(&action.phase,1); atomic_store(&busy_go,1);
    until(&action.phase,3);
    check(action.result==0,"adjacent 16K empty host page maps while callback is live");
    check(atomic_load(&callback.thread->off_guest),"16K adjacent map did not wait for callback");
    check(target[0]==0x5a,"16K live neighbour content preserved");
    check((target+0x4000)[7]==0,"16K adjacent new host page is zero");
    check(s2a_mem_mapped((uintptr_t)target,0x8000),"both 16K host pages mapped");
    atomic_store(&callback.release,1); until(&callback.phase,4);
    stop(&callback,a); stop(&action,b);
    printf("PASS callback-map-16k-adjacent: live 16K neighbour preserved, new host page zero\n"); return 0;
}
// 16K 模拟：整页新增可走只串行；4K 部分宿主页不得借只串行绕过，仍有回调时按停世界到期失败。
static int run_partial16(int with_callback){
    fake_page16=1;
    if(!with_callback){
        uint64_t regs[32]={(uintptr_t)target,0x1000,0};
        check(svc_mem(0x2C,regs,0)==1,"partial host page reaches handler");
        check(regs[0]==0xD401,"partial host page rejected without mutation");
        check(!s2a_mem_mapped((uintptr_t)target,0x1000),"rejected partial page stays unmapped");
        printf("PASS map-partial16: modeled 16K partial host page rejected\n"); return 0;
    }
    struct job callback; pthread_t a=start_callback(&callback);
    struct job action; memset(&action,0,sizeof action); action.mode=2; action.target=target; action.svc=0x2C; action.size=0x1000;
    pthread_t b; check(!pthread_create(&b,NULL,worker,&action),"create partial16 action");
    until(&action.phase,1); atomic_store(&busy_go,1);
    for(;;) pause();   // 只串行不得接住部分宿主页；预期 2 s 停世界到期、errno=110。
}
// 分配失败：新增页失败回滚到 PROT_NONE，metadata/epoch 不留下半成品；随后重试成功。
static int run_fast_map_rollback(void){
    fail_map_alloc=1;
    uint64_t regs[32]={(uintptr_t)target,0x1000,0};
    check(svc_mem(0x2C,regs,0)==1,"rollback map reaches handler");
    check(regs[0]!=0,"allocation failure surfaces to guest");
    check(!fail_map_alloc,"allocation failure was injected");
    check(!s2a_mem_mapped((uintptr_t)target,0x1000),"failed new page leaves no mapping");
    check(!android_vm_epoch&&!android_vm_current_serial_only,"failed fast transaction retires epoch");
    regs[0]=(uintptr_t)target; regs[1]=0x1000; regs[2]=0;
    check(svc_mem(0x2C,regs,0)==1 && regs[0]==0,"retry after rollback succeeds");
    check(s2a_mem_mapped((uintptr_t)target,0x1000) && target[7]==0,"retry maps a zero page");
    printf("PASS fast-map-rollback: failed allocation rolled back, retry succeeded\n"); return 0;
}
// 停止优先于只串行入口：不再映射，也不发布 epoch。
static int run_fast_stop(void){
    uint64_t regs[32]={(uintptr_t)target,0x1000,0};
    s2a_android_memory_svc_enter(0x2C,regs);
    check(!s2a_svc_park_all(0),"stop gate published");
    int error=s2a_android_guest_writers_begin_serial();
    check(error==ECANCELED,"fast begin cancels on stop");
    check(!android_vm_epoch,"cancelled fast begin leaves no epoch");
    s2a_android_memory_svc_unhandled();
    printf("PASS fast-stop: stop cancels serial-only admission before mapping\n"); return 0;
}
// 两个真实 guest 线程并发走不同内存 SVC：同一 serial 串行，空页新增与活页收回都成功。
static int run_race_map_unmap(int with_unmap){
    if(with_unmap){
        uint64_t regs[32]={(uintptr_t)target,0x1000,0};
        check(svc_mem(0x2C,regs,0)==1 && regs[0]==0,"race base page maps");
        target[0]=0x42;
        gate_register(ret_pc+0x80,"svc",0x2D,orig_pc+0x80);
    }
    struct job first,second;
    pthread_t a=start(&first);
    first.target=target+0x1000; first.svc=0x2C; first.size=0x1000;
    pthread_t b=start(&second);
    second.target=target; second.svc=with_unmap?0x2D:0x2C; second.size=0x1000;
    if(with_unmap)second.pc=ret_pc+0x80;
    atomic_store(&race_active,1);
    atomic_store(&busy_go,1);
    until(&first.phase,3); until(&second.phase,3);
    check(first.result==0&&second.result==0,"both concurrent memory SVCs succeed");
    if(with_unmap){
        check(!s2a_mem_mapped((uintptr_t)target,0x1000),"concurrent unmap retired the live page");
        check(s2a_mem_mapped((uintptr_t)target+0x1000,0x1000),"concurrent map added the adjacent zero page");
        check((target+0x1000)[7]==0,"concurrent mapped page is zero");
    } else {
        check(s2a_mem_mapped((uintptr_t)target,0x1000)&&s2a_mem_mapped((uintptr_t)target+0x1000,0x1000),"both empty pages mapped");
        check(target[7]==0&&(target+0x1000)[7]==0,"both new pages are zero");
    }
    stop(&first,a); stop(&second,b);
    printf("PASS race-%s: concurrent memory SVCs serialized, both correct\n",with_unmap?"map-unmap":"map-map"); return 0;
}
// 宿主回调永不释放：0x2D 必须在唯一预算到期时先留下 epoch/线程/回调证据，再以 errno=110 终止。
static _Noreturn void run_callback_stuck(void){
    struct job callback; pthread_t a=start_callback(&callback);
    struct job action; pthread_t b=start_action(&action);
    (void)a; (void)b;
    atomic_store(&busy_go,1);
    for(;;) pause();
}
static void *busy_owner(void *unused){
    (void)unused;
    busy_owner_error=s2a_android_guest_writers_begin();
    atomic_store(&busy_owner_ready,1);
    if(!busy_owner_error){while(!atomic_load(&busy_owner_release))usleep(100);s2a_android_guest_writers_end();}
    return NULL;
}
static int run_busy(int published){
    struct job consumer;pthread_t client=start(&consumer),owner;
    if(!published)glock();
    check(!pthread_create(&owner,NULL,busy_owner,NULL),"create competing real owner");
    uint64_t deadline=plat_now_ns()+1000000000ull;
    if(published){while(!atomic_load(&android_vm_epoch)){check(plat_now_ns()<deadline,"epoch published before deadline");usleep(100);}}
    else{for(;;){int e=pthread_mutex_trylock(&android_vm_serial);if(e==EBUSY)break;check(e==0,"serial lock valid");pthread_mutex_unlock(&android_vm_serial);check(plat_now_ns()<deadline,"owner admission before deadline");usleep(100);}}
    check(!atomic_load(&busy_owner_ready),"owner census has not completed");
    check(!!atomic_load(&android_vm_epoch)==!!published,"requested epoch publication window");
    atomic_store(&busy_go,1);
    if(active_svc!=3&&active_svc!=6){until(&serial_busy_seen,1);check(!!observed_epoch==!!published,"actual serial contention observed in requested window");}
    if(!published)pthread_mutex_unlock(&G);
    uint64_t end=plat_now_ns()+1500000000ull;
    while(!atomic_load(&busy_owner_ready)){
      check(!atomic_load(&busy_done),"accepted request cannot return before owner completes");
      check(plat_now_ns()<end,"owner progresses through waiting contender");usleep(100);
    }
    check(busy_owner_error==0,"actual owner finished census");
    glock();if(active_svc==3||active_svc==6)check(atomic_load(&consumer.thread->vm_ack)==atomic_load(&android_vm_epoch),"non-backing return parked on actual epoch");else check(consumer.thread->vm_admission_wait,"contender remains explicit admission-safe");pthread_mutex_unlock(&G);
    check(!atomic_load(&consumer.thread->held_core),"contender released virtual core");
    check(!atomic_load(&busy_done),"no mapping before owner release");
    if(external_backing){
      atomic_store((_Atomic uint64_t *)&external_backing[5],1);
      uint64_t limit=plat_now_ns()+45000000000ull;
      while(!atomic_load((_Atomic uint64_t *)&external_backing[6])){
        glock();int safe=consumer.thread->vm_admission_wait;pthread_mutex_unlock(&G);
        check(safe,"native lifecycle admission expired while managed backing wait remains legal");
        check(plat_now_ns()<limit,"external managed controller completes");usleep(10000);
      }
    }
    if(timeout_mode){usleep(2100000);glock();check(!consumer.thread->vm_admission_wait,"timed out waiter revoked admission-safe");pthread_mutex_unlock(&G);check(!atomic_load(&busy_done),"timed out waiter cannot return through active epoch");}
    // 持 epoch 的换页在推进（排空期间渲染侧一直在干活）：第二条线程的准入等待续期，不按 2 s 判死；推进停了按无干活上限 + 1 s 判
    if(progress_mode){pthread_t pinger;check(!pthread_create(&pinger,NULL,backing_pinger,(void*)(intptr_t)(progress_mode==1?3200:500)),"backing progress publisher");
      usleep(progress_mode==1?3000000:5500000);
      glock();check(!!consumer.thread->vm_admission_wait==(progress_mode==1),progress_mode==1?"waiter renewed while the backing change progresses":"waiter times out once progress stops for idle + 1 s");pthread_mutex_unlock(&G);check(!atomic_load(&busy_done),"waiter cannot return through active epoch");
      check(!pthread_join(pinger,NULL),"publisher ends");}
    if(stop_mode==1)check(!s2a_svc_park_all(0),"actual shutdown gate published");
    atomic_store(&busy_owner_release,1);check(!pthread_join(owner,NULL),"owner ended");
    if(stop_mode){
      if(stop_mode==2){until(&serial_acquired,1);check(!s2a_svc_park_all(0),"stop after waiter owns serial");atomic_store(&allow_serial_return,1);}
      uint64_t stop_deadline=plat_now_ns()+1000000000ull;int parked=0;
      while(!parked){glock();parked=consumer.thread->vm_wait_safe;check(!consumer.thread->vm_admission_wait||!parked,"permanent park cleared admission");pthread_mutex_unlock(&G);check(!atomic_load(&busy_done),"shutdown never returns guest result");check(plat_now_ns()<stop_deadline,"waiter reaches real permanent park");usleep(100);}
      check(!s2a_mem_mapped((uintptr_t)target,0x4000),"shutdown waiter did not map");
      check(!s2a_android_guest_writers_begin(),"shutdown host owner can still quiesce parked guest");s2a_android_guest_writers_end();
      printf("PASS actual-gate shutdown mode=%d: no guest return, no map, serial released, host owner proceeds\n",stop_mode);return 0;
    }
    until(&consumer.phase,3);stop(&consumer,client);
    check(!atomic_load(&android_vm_epoch)&&!android_vm_pin_count,"epoch and pins retired");
    check(!pthread_mutex_trylock(&android_vm_serial),"serial unlocked");pthread_mutex_unlock(&android_vm_serial);
    check(!s2a_android_guest_writers_begin(),"later independent owner succeeds");check(s2a_android_guest_writers_begin()==EDEADLK,"nested owner still refused");s2a_android_guest_writers_end();
    printf("PASS actual-gate svc=%#x window=%s cores=%d result=%#llx real-metadata/readwrite checks=%d\n",active_svc,published?"epoch-published":"before-epoch",core_mode,(unsigned long long)request_result,checks);
    return 0;
}

#include "thread_lifetime_test.inc"
#include "thread_sleep_test.inc"

static int run_renew_budget(void) {
 uint64_t now=plat_now_ns(),deadline=now+2000000000ull;
 android_vm_renew_state state={0};atomic_store(&android_vm_epoch,7);
 android_vm_renew(&state,now,&deadline);
 check(deadline==now+2000000000ull,"false without publication keeps original deadline");
 uint64_t owner=s2a_backing_publish(&test_backing,7,0,1,test_foreground);
 android_vm_renew(&state,now,&deadline);
 check(state.extended && deadline==test_backing.progress+4000000000ull,"foreground native authority plus margin");
 test_foreground=0;android_vm_renew(&state,now,&deadline);
 check(deadline==UINT64_MAX,"background ignores expired foreground idle");
 s2a_backing_publish(&test_backing,7,owner,0,test_foreground);android_vm_renew(&state,now,&deadline);
 check(deadline==UINT64_MAX,"withdrawn publication still pauses in background");
 test_foreground=1;s2a_backing_resumed(&test_backing);
 android_vm_renew(&state,now,&deadline);
 check(deadline==test_backing.start+4000000000ull,"resume resets idle even without new work");
 atomic_store(&android_vm_epoch,9);android_vm_renew(&state,now,&deadline);
 check(deadline==now+2000000000ull,"stale writer cannot renew new epoch; no background slice leak");
 android_vm_admitted(&state,now+350000000ull,&deadline);
 check(deadline==now+2350000000ull,"serial acquired has independent roster budget");
 printf("PASS actual-gate renew budgets checks=%d\n",checks);return 0;
}

int svc_mem(int, uint64_t *, uint64_t);
void s2a_track_prot_changed(uint64_t, uint64_t);
void s2a_track_write(uint64_t, uint64_t);
int __real_s2a_track_backing_begin(uint64_t,uint64_t,uint64_t);
int __wrap_s2a_track_backing_begin(uint64_t a,uint64_t n,uint64_t src) {
 int result=__real_s2a_track_backing_begin(a,n,src);
 if (atomic_load(&race_active) && active_svc==1 && !result && !atomic_exchange(&race_hook_entered,1)) while (!atomic_load(&race_release)) usleep(100);
 return result;
}
static void race_host_write(uint64_t a, uint64_t n) {
    s2a_track_write(a,n);
    if (!atomic_exchange(&race_hook_entered,1)) while (!atomic_load(&race_release)) usleep(100);
}
static int run_two_stack(void) {
    s2a_layout *layout=(s2a_layout *)(uintptr_t)s2a_layout_get();
    layout->stack_base=(uintptr_t)target; layout->stack_size=0x4000;
    check(mmap(source,0x4000,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS|MAP_FIXED,-1,0)==source,"real source");
    source[7]=0x32;
    if (active_svc==5) { uint64_t r[32]={(uintptr_t)target,(uintptr_t)source,0x4000}; check(svc_mem(4,r,0)==1 && r[0]==0,"initial stack map"); }
    if (active_svc!=1) { s2a_track_hooks hooks={s2a_track_prot_changed,race_host_write,NULL}; s2a_register_track_hooks(&hooks); }
    struct job first,second; pthread_t a=start(&first), b=start(&second);
    atomic_store(&race_active,1); atomic_store(&busy_go,1);
    until(&race_hook_entered,1); until(&race_serial_busy,1);
    check(atomic_load(&first.phase)==1 && atomic_load(&second.phase)==1,"second waits while first inside unlocked host_write");
    atomic_store(&race_release,1); until(&first.phase,3); until(&second.phase,3);
    stop(&first,a); stop(&second,b);
    if(active_svc==1) { check(first.result==0 && second.result==0,"both identical heap requests succeed"); check(s2a_mem_heap_end()==(uintptr_t)source+0x200000,"heap state agrees with real final mapping"); }
    else { check((first.result==0 && second.result==0xD401)||(second.result==0 && first.result==0xD401),"one map succeeds and overlap rejected"); check(!!s2a_mem_mapped((uintptr_t)target,0x4000)==(active_svc==4),"expected final mapping"); }
    printf("PASS actual-gate two memory SVCs: svc=%#x result=%#llx/%#llx; second blocked during unlocked callback\n",active_svc,(unsigned long long)first.result,(unsigned long long)second.result); return 0;
}
int main(int argc,char**argv){
 check(argc==2||argc==3,"window argument");if(!strcmp(argv[1],"renew-budget"))return run_renew_budget();core_mode=argc==3&&!strcmp(argv[2],"cores");if(argc==3&&!strcmp(argv[2],"default"))unsetenv("S2A_CORES");else setenv("S2A_CORES",argc==3&&!strcmp(argv[2],"ondemand")?"ondemand":core_mode?"1":"0",1);active_svc=!strcmp(argv[1],"callback-unmap")||!strcmp(argv[1],"callback-unmap-stuck")?0x2D:!strcmp(argv[1],"callback-map")?0x2C:!strcmp(argv[1],"race-heap")?1:!strcmp(argv[1],"race-unmap")?5:(!strcmp(argv[1],"race-stack")||!strcmp(argv[1],"diag-race-stack")||!strncmp(argv[1],"diag-",5))?4:!strncmp(argv[1],"unmap",5)?0x2D:!strncmp(argv[1],"stack",5)?4:!strncmp(argv[1],"query",5)?6:!strncmp(argv[1],"invalid",7)?3:0x2C;timeout_mode=!strncmp(argv[1],"timeout",7);progress_mode=!strncmp(argv[1],"progress-stall",14)?2:!strncmp(argv[1],"progress",8)?1:0;stop_mode=!strncmp(argv[1],"stop-acquired",13)?2:(!strncmp(argv[1],"stop",4)||strstr(argv[1],"-stop"))?1:0;
 if(!strncmp(argv[1],"diag-",5) || (argc==3 && !strcmp(argv[2],"diag"))) setenv("S2A_MAP_DIAG","1",1);
 if(!strncmp(argv[1],"external",8)){
   const char *path=getenv("S2A_BACKING_SHARED");check(path!=NULL,"external shared page path");
   int fd=open(path,O_RDWR);check(fd>=0,"external shared page opened");
   external_backing=mmap(NULL,256,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);close(fd);
   check(external_backing!=MAP_FAILED,"external shared page mapped");
 }
 void *window=NULL;check(!plat_vm_reserve(16u<<20,2u<<20,1ull<<39,&window),"real reserved window");target=(uint8_t*)window+0x400000;source=(uint8_t*)window+0x800000;
 if(!strcmp(argv[1],"det-poison")) {
   extern int g_det; extern int s2a_det_shmem_map(uint64_t,const void *,uint64_t,uint64_t,int);
   void plat_vm_test_set_protect_fail(int),plat_vm_test_set_restore_fail(int);
   g_det=3; plat_vm_test_set_protect_fail(1); plat_vm_test_set_restore_fail(1);
   (void)s2a_det_shmem_map((uintptr_t)target,source,0x4000,0x4000,PROT_READ|PROT_WRITE);
   fprintf(stderr,"FAIL poisoned deterministic destination returned to caller\n"); return 2;
 }
 s2a_mem_test_setup((uintptr_t)target,0x200000,(uintptr_t)window,16u<<20,(uint8_t*)window+0x800000,0);s2a_mem_test_sysres(0x4000,0x200000);
 s2a_layout *layout=(s2a_layout*)(uintptr_t)s2a_layout_get();layout->tlsio_base=(uintptr_t)window+0xc00000;layout->tlsio_size=0x40000;
 check(!s2a_android_tracking_vm_prepare()&&!s2a_track_runtime_prepare(),"real tracker and VM hooks");
 gate_register(ret_pc,"svc",active_svc,orig_pc);
 check(!pthread_key_create(&g_key18,NULL)&&!pthread_key_create(&g_keytls,NULL)&&!pthread_key_create(&g_keytlr,NULL)&&!pthread_key_create(&g_keygate,NULL),"fixture guest TLS keys");
 check(!s2a_android_guest_writers_ready(),"not ready before install");check(!s2a_android_guest_writers_init(),"real install");check(s2a_android_guest_writers_ready(),"installed ready");s2a_crash_install();
 if(!strcmp(argv[1],"race-stack") || !strcmp(argv[1],"diag-race-stack") || !strcmp(argv[1],"race-unmap") || !strcmp(argv[1],"race-heap"))return run_two_stack();
 if(!strncmp(argv[1],"lifetime-",9))return run_lifetime(argv[1]);
 if(!strncmp(argv[1],"sleep-pause",11))return run_sleep_pause(argv[1]);
 if(!strncmp(argv[1],"sleep-",6))return run_sleep(argv[1]);
 if(!strcmp(argv[1],"diag-writer-fatal")){check(!s2a_android_guest_writers_begin(),"real nested owner");call_map();check(0,"MapMemory nested admission must not return");}
 if(!strcmp(argv[1],"diag-mprotect-fatal")){layout->stack_base=(uintptr_t)target;layout->stack_size=0x4000;check(!munmap(target,0x4000),"unmap actual target pages");call_map();check(0,"MapMemory mprotect failure must not return");}
 if(!strcmp(argv[1],"nested-fatal")){check(!s2a_android_guest_writers_begin(),"real nested owner");call_map();check(0,"nested coordination failure must not return guest result");}
 if(active_svc==0x2D){gate_register(ret_pc+0x40,"svc",0x2C,orig_pc+0x40);uint64_t regs[32]={(uintptr_t)target,0x4000,0};check(!gate_dispatch(ret_pc+0x40,regs),"unmap starts with real mapped memory");target[7]=0x32;}
 if(active_svc==4){layout->stack_base=(uintptr_t)target;layout->stack_size=0x4000;check(mmap(source,0x4000,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS|MAP_FIXED,-1,0)==source,"real source pages");source[7]=0x32;}
  if(!strcmp(argv[1],"callback-map"))return run_callback(0);
  if(!strcmp(argv[1],"callback-unmap"))return run_callback(1);
  if(!strcmp(argv[1],"callback-unmap-stuck"))run_callback_stuck();
  if(!strcmp(argv[1],"callback-map-adjacent"))return run_callback_adjacent();
  if(!strcmp(argv[1],"callback-map-16k-adjacent"))return run_callback_adjacent16();
  if(!strcmp(argv[1],"callback-map-partial16"))return run_partial16(1);
  if(!strcmp(argv[1],"map-partial16"))return run_partial16(0);
  if(!strcmp(argv[1],"fast-map-rollback"))return run_fast_map_rollback();
  if(!strcmp(argv[1],"fast-stop"))return run_fast_stop();
  if(!strcmp(argv[1],"race-map-map"))return run_race_map_unmap(0);
  if(!strcmp(argv[1],"race-map-unmap"))return run_race_map_unmap(1);
 return run_busy(strstr(argv[1],"published")!=NULL);
}

// 仅为同TU中本例不执行的其它SVC/loader分支提供链接；若误执行立即失败，不返回假成功。
int s2a_android_runtime_enter_guest_thread(void){if(lifetime_mode)return 0;abort();}
void sw_thread_enter(uint64_t a,uint64_t b,uint64_t c){(void)c;if(lifetime_mode&&a==(uintptr_t)lifetime_child){lifetime_child(b);abort();}abort();}
void (*s2a_test_cv_after_release)(void);
void s2a_low_holes(uint64_t*a,uint64_t*b){(void)a;(void)b;abort();}
void s2a_widen_gate(int a,uint64_t*b,uint64_t c){(void)a;(void)b;(void)c;abort();}
void s2a_host_shutdown(const char*w){(void)w;abort();}

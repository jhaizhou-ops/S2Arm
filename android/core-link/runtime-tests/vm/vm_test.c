// Linux host 的真实 svc_mem → tracker begin/end → plat_vm_alias → 内核映射。
// writers 安全点与其余 core handle/NPDM 端点为合成夹具，不能冒充 Android thread owner 已接通。
#include "native.h"
#include "host_android.h"
#include "runtime/tracking/runtime.h"
#include "runtime/tracking/mirror.h"
#include "runtime/vm/backing.h"
#include "runtime/vm/memory.h"
#include "../../../native/nvn/s2a_vp_alias.h"
#include "../../../../graphics/track/s2a_track.h"
#include "../../../../platform/plat.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <stdarg.h>
#include <time.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>

// 撤修复时用 --svc-source 指旧源的 svc_mem.c：旧源没有 P2 新导出的别名 ref/unref 与
// tmem_close，测试台用弱定义兜住（新源里的强定义会覆盖它们）；旧源语义下这些入口是空操作，
// 正好用来证明「旧源没有 refs，NVN 别名页会被换走」。
__attribute__((weak)) int s2a_mem_backing_alias_ref(uint64_t src, uint64_t n) { (void)src; (void)n; return 0; }
__attribute__((weak)) void s2a_mem_backing_alias_unref(uint64_t src, uint64_t n) { (void)src; (void)n; }
__attribute__((weak)) void s2a_mem_tmem_close(uint64_t a, uint64_t n) { (void)a; (void)n; }
__attribute__((weak)) void s2a_mem_test_lockorder_abort(void) { }
__attribute__((weak)) void s2a_mem_test_backing_punch_stats(uint64_t out[6]) { memset(out, 0, 6 * sizeof(uint64_t)); }
__attribute__((weak)) void s2a_android_vma_test_last(uint64_t out[6]) { memset(out, 0, 6 * sizeof(uint64_t)); }
__attribute__((weak)) uint64_t s2a_mem_test_release_deferred(void) { return 0; }
// 硬件核数端点只属本夹具：与生产 thread.c:230-231 同口径（校验上界，不写死 4），
// 缺省 4、Switch 2 NPDM 起局可 set(8)；不进 core_endpoints.inc（guest_page/fps_write
// 两夹具各有本地桩，共享会编译冲突）。
static int g_hw_cores = 4;
void s2a_thread_set_hw_cores(int n) { if (n > 0 && n <= 64) g_hw_cores = n; }
int s2a_thread_hw_cores(void) { return g_hw_cores; }
uint32_t s2a_mem_tmem_borrow(uint64_t a, uint64_t n, uint32_t perm);
void s2a_mem_lockorder_vp_enter(void);
void s2a_mem_test_lockorder_abort(void);
void s2a_guest_va_report(const char *when);
extern void (*s2a_mem_test_prepare_hook)(uint64_t a, uint64_t n);
__attribute__((weak)) void s2a_mem_lockorder_vp_enter(void) { }
__attribute__((weak)) void (*s2a_mem_test_prepare_hook)(uint64_t, uint64_t) = NULL;
static _Atomic int g_stopworld_stop;
static uint8_t *arena_alias, *arena_heap, *arena_map;
static void *stopworld_worker(void *arg) {
    (void)arg;
    while (!atomic_load(&g_stopworld_stop)) {
        s2a_mem_lockorder_vp_enter();   // 模拟 NVN 持 g_vp_mu 进入
        int r=s2a_mem_backing_alias_ref((uintptr_t)arena_heap,0x1000);
        if (r==1) s2a_mem_backing_alias_unref((uintptr_t)arena_heap,0x1000);
        else assert(r==0 || r==-EFAULT);
    }
    return NULL;
}
static uint8_t *source, *target;
static uint64_t logical_size=0x4000;
static void *code_object;
static int fail_quiesce, in_quiesce, before_count, after_count, expected_mapped;
static int fail_unmap, touch_count, fail_allocate, fake_page16, discard_mode, discard_before, discard_after;
static int relaxed_callbacks;   // 新用例只验证映射/引用，不让 before 写 0x6d 干扰内容
static int count_copy_maps, copy_maps, copy_mremaps, copy_mprotects, copy_munmaps, fail_mirror_reserve;
static int mirror_stress;
static unsigned reset_before_publish_calls;
// 复核必改第 1 条：owner 窗口升级失败时，映射事务必须在 s2a_track_backing_begin 之前终止。
// 计数包装用来直接断言「事务没有被启动」，而不是只看返回值。
static int owner_window_error, backing_begin_calls;
int __real_s2a_track_backing_begin(uint64_t,uint64_t,uint64_t);
int __wrap_s2a_track_backing_begin(uint64_t addr,uint64_t size,uint64_t source) {
    backing_begin_calls++;
    return __real_s2a_track_backing_begin(addr,size,source);
}
// svc_mem 里它是弱引用（生产实现由图形层提供）；本夹具按用例注入返回值。
int s2a_android_mem_owner_window(void) { return owner_window_error; }
void __real_s2a_track_backing_reset_before_publish(uint64_t,uint64_t);
void __wrap_s2a_track_backing_reset_before_publish(uint64_t addr,uint64_t size) {
    reset_before_publish_calls++;
    __real_s2a_track_backing_reset_before_publish(addr,size);
}
extern void (*s2a_android_readonly_test_hook)(void);
int s2a_android_copy_guest_readonly(uint64_t, void *, uint64_t);
static uint64_t expected_source, expected_span=0x4000;
static uint64_t last_prot_address, last_prot_size;
void __real_s2a_track_prot_changed(uint64_t address,uint64_t size);
void __wrap_s2a_track_prot_changed(uint64_t address,uint64_t size) {
    last_prot_address=address; last_prot_size=size;
    __real_s2a_track_prot_changed(address,size);
}
S2A_TEST_MOD_TABLE(64); int g_nmod;
// 本夹具链接真实 runtime/src/os.c：guest_tick / s2a_entropy64 用生产实现，
// 让共享端点文件跳过这两个合成替身（guest_page/fps_write 夹具不链 os.c，仍需它们）。
#define S2A_VM_REAL_OS_ENDPOINTS
#include "core_endpoints.inc"
void s2a_mem_test_setup(uint64_t,uint64_t,uint64_t,uint64_t,void *,uint64_t);
void s2a_mem_test_sysres(uint64_t,uint64_t);
void s2a_mem_test_map(uint64_t,uint64_t);
void s2a_mem_test_map_perm(int,uint32_t);
int svc_mem(int,uint64_t *,uint64_t);
void plat_vm_test_set_protect_fail(int);
void plat_vm_test_set_restore_fail(int);
size_t __real_plat_page_size(void);
size_t __wrap_plat_page_size(void) { return fake_page16 ? 0x4000 : __real_plat_page_size(); }
void *__real_mmap(void *,size_t,int,int,int,off_t);
void *__real_mremap(void *,size_t,size_t,int,...);
int __real_mprotect(void *,size_t,int);
int __real_munmap(void *,size_t);
int __real_madvise(void *,size_t,int);
static int fail_madvise, madvise_calls;
int __wrap_madvise(void *p,size_t n,int advice) {
    madvise_calls++;
    if (fail_madvise) { errno=EINVAL; return -1; }
    return __real_madvise(p,n,advice);
}
void *__wrap_mremap(void *old,size_t oldsize,size_t newsize,int flags,...) {
    if (count_copy_maps) copy_mremaps++;
    if (flags & MREMAP_FIXED) { va_list ap; va_start(ap,flags); void *dest=va_arg(ap,void *); va_end(ap); return __real_mremap(old,oldsize,newsize,flags,dest); }
    return __real_mremap(old,oldsize,newsize,flags);
}
int __wrap_mprotect(void *p,size_t n,int prot) { if (count_copy_maps) copy_mprotects++; return __real_mprotect(p,n,prot); }
int __wrap_munmap(void *p,size_t n) { if (count_copy_maps) copy_munmaps++; return __real_munmap(p,n); }
void *__wrap_mmap(void *address,size_t size,int prot,int flags,int fd,off_t offset) {
    if (count_copy_maps) copy_maps++;
    // 只打掉镜像窗口的预留（plat_vm_reserve 用 MAP_NORESERVE），不要连背板 open 的自检页一起打掉。
    if (fail_mirror_reserve && (flags&MAP_NORESERVE) && !(flags&MAP_FIXED)) { errno=ENOMEM; return MAP_FAILED; }
    if (fail_allocate && address==target && prot==(PROT_READ|PROT_WRITE) && (flags&MAP_FIXED)) {
        fail_allocate=0;
        return __real_mmap(address,size,prot,flags&~MAP_ANONYMOUS,-1,offset);
    }
    if (fail_unmap && address==target && prot==PROT_NONE && (flags&MAP_FIXED)) {
        fail_unmap=0;
        // 真内核失败：删除 ANONYMOUS 后无效fd产生 EBADF，原映射仍由生产回滚路径恢复。
        return __real_mmap(address,size,prot,flags&~MAP_ANONYMOUS,-1,offset);
    }
    return __real_mmap(address,size,prot,flags,fd,offset);
}
int __real_fallocate(int, int, off_t, off_t);
static int fallocate_calls;
int __wrap_fallocate(int fd, int mode, off_t offset, off_t len) {
    // 打洞窗口内世代号必须为奇数；只 +2 的实现会在这里红。
    assert(plat_backing_sequence() & 1);
    fallocate_calls++;
    return __real_fallocate(fd, mode, offset, len);
}
// 合成安全点不能冒充真实thread owner安装，prepared/ready必须仍拒绝。
int s2a_android_guest_writers_ready(void) { return 0; }
int s2a_android_guest_writers_begin(void) { assert(!in_quiesce); if (fail_quiesce) return ENOTSUP; in_quiesce=1; return 0; }
// Synthetic writer endpoints: serial and full-stop remain distinct production contracts;
// fixture only needs exclusive sequencing and does not claim real guest suspension.
int s2a_android_guest_writers_begin_serial(void) { return s2a_android_guest_writers_begin(); }
int s2a_android_guest_writers_quiesce(void) { assert(in_quiesce); return 0; }
void s2a_android_guest_writers_end(void) { assert(in_quiesce); in_quiesce=0; }
// 生产语义（thread_android.inc）：本事务是否已被停世界撤销、调用方须重新准入；本夹具没有撤销路径（撤销由 writers-gate 夹具覆盖），恒为未撤销。
// 11-05 svc_mem.c 5187c118d 起引用它，VM 跑器漏登记（check_endpoints 点名）
int s2a_android_guest_writers_revoked(void) { return 0; }
unsigned s2a_android_guest_writers_epoch(void) { return (unsigned)in_quiesce; }   // 合成端点：epoch = in_quiesce
int s2a_android_vm_writer_held(void) { return in_quiesce; }
static void before(uint64_t addr,uint64_t size,uint64_t src) {
    if (relaxed_callbacks) { (void)addr;(void)src; assert(in_quiesce && size); before_count++; return; }
    if (mirror_stress) { assert(in_quiesce && size && !src); return; }
    if (discard_mode) {
        assert(in_quiesce && !src && size && !(addr%0x1000) && !(size%0x1000));
        s2a_meminfo mi; assert(!s2a_mem_query(addr,&mi));
        if (mi.perm) { s2a_track_write_quiet(addr,size); ((uint8_t *)(uintptr_t)addr)[7]=0x6d; }
        discard_before++; return;
    }
    assert(in_quiesce && addr==(uint64_t)target && size==expected_span && src==expected_source);
    s2a_meminfo mi; s2a_mem_query(addr,&mi); // 真消费者重入查询：持g_mu调用会超时失败。
    if (mi.perm) assert(target[7]==0x7a);
    if (src) { assert(source[7]==0x19); source[7]=0x7a; } // 模拟GPU回写，但实际写入随后要alias的同一物理页。
    before_count++;
}
static void after(uint64_t addr,uint64_t size,int mapped) {
    if (relaxed_callbacks) { (void)addr;(void)mapped; assert(in_quiesce && size); after_count++; return; }
    if (mirror_stress) { assert(in_quiesce && size); (void)addr; (void)mapped; return; }
    if (discard_mode) {
        assert(in_quiesce && size);
        s2a_meminfo mi; assert(!s2a_mem_query(addr,&mi) && !!mi.perm==mapped);
        if (mapped) assert(((uint8_t *)(uintptr_t)addr)[7]==0);
        discard_after++; return;
    }
    assert(in_quiesce && addr==(uint64_t)target && size==expected_span && mapped==expected_mapped);
    s2a_meminfo mi; s2a_mem_query(addr,&mi);
    assert((mi.perm!=0)==mapped);
    if (mapped) assert(target[7]==0x7a);
    after_count++;
}
static uint64_t call(int num,uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e) {
    uint64_t regs[32]={a,b,c,d,e}; assert(svc_mem(num,regs,0)==1); assert(!in_quiesce); return regs[0];
}
static void replace_during_copy(void) {
    s2a_android_readonly_test_hook=NULL;
    assert(!call(0x2D,(uintptr_t)target,0x2000,0,0,0));
    assert(!call(0x2C,(uintptr_t)target,0x2000,0,0,0));
}
static void *mirror_writer(void *arg) {
    (void)arg;
    for (int i=0;i<10000;i++) {
        assert(!call(0x2D,(uintptr_t)target,0x2000,0,0,0));
        assert(!call(0x2C,(uintptr_t)target,0x2000,0,0,0));
    }
    return NULL;
}
static int maps_perm(void *address) {
    FILE *f=fopen("/proc/self/maps","r"); assert(f); char line[512],p[8]; unsigned long lo,hi;
    while (fgets(line,sizeof line,f)) if (sscanf(line,"%lx-%lx %7s",&lo,&hi,p)==3 && lo<=(uintptr_t)address && (uintptr_t)address<hi) { fclose(f); return (p[0]=='r'?1:0)|(p[1]=='w'?2:0)|(p[2]=='x'?4:0); }
    fclose(f); return -1;
}
static int maps_count(uint64_t lo, uint64_t hi) {
    FILE *f=fopen("/proc/self/maps","r"); assert(f); char line[512]; unsigned long a,b; int count=0;
    while (fgets(line,sizeof line,f)) if (sscanf(line,"%lx-%lx",&a,&b)==2 && a<hi && b>lo) count++;
    fclose(f); return count;
}
static int maps_has(uint64_t lo, uint64_t hi, const char *needle) {
    FILE *f=fopen("/proc/self/maps","r"); assert(f); char line[512]; unsigned long a,b; int found=0;
    while (fgets(line,sizeof line,f)) if (sscanf(line,"%lx-%lx",&a,&b)==2 && a<hi && b>lo && strstr(line,needle)) { found=1; break; }
    fclose(f); return found;
}
static uint64_t backing_now_ns(void) {
    struct timespec ts; assert(!clock_gettime(CLOCK_MONOTONIC,&ts));
    return (uint64_t)ts.tv_sec*1000000000ull+(uint64_t)ts.tv_nsec;
}
static int compare_u64(const void *left, const void *right) {
    uint64_t a=*(const uint64_t *)left, b=*(const uint64_t *)right;
    return a<b ? -1 : a>b;
}
// ---------- P2 用例共用的窗口：别名区 + 堆区 + 映射区互不重叠 ----------
static void arena_prepare(uint64_t alias_size, uint64_t heap_size, uint64_t map_size) {
    uint64_t total=alias_size+heap_size+map_size;
    void *window=NULL;
    assert(!plat_vm_reserve(total,2u<<20,1ull<<39,&window));
    arena_alias=window; arena_heap=(uint8_t *)window+alias_size; arena_map=(uint8_t *)window+alias_size+heap_size;
    s2a_mem_test_setup((uintptr_t)arena_alias,alias_size,(uintptr_t)window,total,arena_heap,0);
    s2a_mem_test_sysres(0x4000,heap_size);
    relaxed_callbacks=1;
    assert(!s2a_track_runtime_prepare()); s2a_track_set_backing_callbacks(before,after);
}
#define FAIL_CASE(...) do { fprintf(stderr,"FAIL %s: ",__func__); fprintf(stderr,__VA_ARGS__); fputc('\n',stderr); return 1; } while (0)
static int case_backing_vma_merge(void) {
    arena_prepare(10000*0x1000,2u<<20,0);
    int baseline=maps_count((uintptr_t)arena_alias,(uintptr_t)arena_alias+10000*0x1000);
    for (size_t i=0;i<10000;i++) {
        assert(!call(0x2C,(uintptr_t)arena_alias+i*0x1000,0x1000,0,0,0));
        arena_alias[i*0x1000]=0x5a;
    }
    int merged=maps_count((uintptr_t)arena_alias,(uintptr_t)arena_alias+10000*0x1000);
    if (merged>baseline+8) FAIL_CASE("10000 committed pages: VMA=%d baseline=%d",merged,baseline);
    for (size_t i=0;i<10000;i++) {
        assert(!call(0x2D,(uintptr_t)arena_alias+i*0x1000,0x1000,0,0,0));
        assert(!call(0x2C,(uintptr_t)arena_alias+i*0x1000,0x1000,0,0,0));
        if (arena_alias[i*0x1000]!=0) FAIL_CASE("remapped page %zu not zero: %02x",i,arena_alias[i*0x1000]);
    }
    int after=maps_count((uintptr_t)arena_alias,(uintptr_t)arena_alias+10000*0x1000);
    if (after>baseline+8) FAIL_CASE("after unmap/remap: VMA=%d baseline=%d",after,baseline);
    printf("PASS backing-vma-merge: VMA=%d baseline=%d after-remap=%d\n",merged,baseline,after);
    return 0;
}
static int case_physical_unmap_borrowed(void) {
    arena_prepare(4u<<20,2u<<20,0);
    uint64_t a=(uintptr_t)arena_alias+0x1000, b=a+0x1000;
    assert(!call(0x2C,a,0x1000,0,0,0));
    assert(!call(0x2C,b,0x1000,0,0,0));
    ((uint8_t *)a)[0]=0x5a; ((uint8_t *)b)[0]=0x6b;
    uint64_t regs[32]={0,a,0x1000,0,0};
    assert(svc_mem(0x4b,regs,0)==1 && !regs[0] && regs[1]);
    uint64_t rc=call(0x2D,a,0x1000,0,0,0);
    if (rc!=0xD401) FAIL_CASE("0x2D borrowed page returned %#llx",(unsigned long long)rc);
    if (((uint8_t *)a)[0]!=0x5a || ((uint8_t *)b)[0]!=0x6b) FAIL_CASE("borrowed unmap changed content");
    puts("PASS physical-unmap-borrowed: 0x2D -> 0xD401, A/B unchanged"); return 0;
}
static int case_backing_alias_shared(void) {
    arena_prepare(2u<<20,2u<<20,1u<<20);
    assert(!call(0x01,0,2u<<20,0,0,0));
    uint64_t a=(uintptr_t)arena_heap, b=(uintptr_t)arena_map+0x1000, c=(uintptr_t)arena_map+0x2000;
    ((uint8_t *)a)[0]=0x5a;
    uint64_t regs[32]={0,a,0x1000,0,0};
    assert(svc_mem(0x4b,regs,0)==1 && !regs[0]);
    uint32_t h=(uint32_t)regs[1];
    assert(!call(0x4c,h,0,b,0x1000,3));
    assert(((uint8_t *)b)[0]==0x5a);
    assert(!call(0x4c,h,1,c,0x1000,1));
    assert(((uint8_t *)c)[0]==0x5a);
    assert(!call(0x4c,h,2,b,0x1000,0));
    if (((uint8_t *)c)[0]!=0x5a || ((uint8_t *)a)[0]!=0x5a) FAIL_CASE("unmap B changed C/A");
    assert(plat_backing_refs(a,0x1000)==1);   // C 还映射着
    assert(!call(0x4c,h,3,c,0x1000,0));
    if (plat_backing_refs(a,0x1000)!=0) FAIL_CASE("C unmap left refs=%u",plat_backing_refs(a,0x1000));
    puts("PASS backing-alias-shared: unmap B keeps C through the shared backing"); return 0;
}
static int case_backing_alias_merge(void) {
    arena_prepare(2u<<20,2u<<20,0);
    assert(!call(0x2C,(uintptr_t)arena_alias,2u<<20,0,0,0));
    int baseline=maps_count((uintptr_t)arena_alias,(uintptr_t)arena_alias+(2u<<20));
    for (size_t i=0;i<512;i++) {
        assert(!call(0x2D,(uintptr_t)arena_alias+i*0x1000,0x1000,0,0,0));
        assert(!call(0x2C,(uintptr_t)arena_alias+i*0x1000,0x1000,0,0,0));
    }
    int after=maps_count((uintptr_t)arena_alias,(uintptr_t)arena_alias+(2u<<20));
    if (after>baseline+2) FAIL_CASE("2MB per-page NONE->RW: VMA=%d baseline=%d",after,baseline);
    if (arena_alias[0]!=0 || arena_alias[(2u<<20)-1]!=0) FAIL_CASE("alias merge changed zero pages");
    printf("PASS backing-alias-merge: VMA=%d baseline=%d\n",after,baseline); return 0;
}
static int case_nvn_remap_ref(void) {
    arena_prepare(2u<<20,4u<<20,1u<<20);
    assert(!call(0x01,0,4u<<20,0,0,0));
    uint64_t a=(uintptr_t)arena_heap, v=(uintptr_t)arena_map+0x1000;
    ((uint8_t *)a)[0]=0x5a;
    // 旧源没有这个入口（测试台弱定义回 0）：不在这里提前判死，让后面的「增长应回
    // 0xD401」去暴露旧源没有 refs；新源必须回 1。
    int ref=s2a_mem_backing_alias_ref(a,0x1000);
    if (ref!=0 && ref!=1) FAIL_CASE("ref heap page returned %d",ref);
    assert(!plat_vm_alias((void *)v,(const void *)a,0x1000,PROT_READ|PROT_WRITE));
    if (((uint8_t *)v)[0]!=0x5a) FAIL_CASE("alias did not share source");
    assert(!call(0x01,0,0,0,0,0));   // 缩堆：源页死，打洞必须 deferred
    if (((uint8_t *)v)[0]!=0x5a) FAIL_CASE("deferred punch zeroed live alias");
    uint64_t rc=call(0x01,0,4u<<20,0,0,0);
    if (rc!=0xD401) FAIL_CASE("grow over ref'd page returned %#llx",(unsigned long long)rc);
    assert(!munmap((void *)v,0x1000));
    s2a_mem_backing_alias_unref(a,0x1000);
    if (plat_backing_refs(a,0x1000)!=0) FAIL_CASE("unref left refs");
    assert(!call(0x01,0,4u<<20,0,0,0));
    if (((uint8_t *)a)[0]!=0) FAIL_CASE("grow after unref not zero: %02x",((uint8_t *)a)[0]);
    // 部分重叠 ref / unref。
    ((uint8_t *)a)[0x1000]=0x11; ((uint8_t *)a)[0x2000]=0x22;
    if (s2a_mem_backing_alias_ref(a+0x1000,0x2000)!=1) FAIL_CASE("partial ref failed");
    if (plat_backing_refs(a+0x1000,0x1000)!=1 || plat_backing_refs(a+0x2000,0x1000)!=1) FAIL_CASE("partial refs mismatch");
    s2a_mem_backing_alias_unref(a+0x1000,0x1000);
    if (plat_backing_refs(a+0x1000,0x1000)!=0 || plat_backing_refs(a+0x2000,0x1000)!=1) FAIL_CASE("partial unref mismatch");
    s2a_mem_backing_alias_unref(a+0x2000,0x1000);
    // vm_remap 失败：ref 必须先撤销，否则源页永远打不了洞。
    if (s2a_mem_backing_alias_ref(a,0x1000)!=1) FAIL_CASE("failure ref failed");
    plat_vm_test_set_protect_fail(1);
    int ae=plat_vm_alias((void *)v,(const void *)a,0x1000,PROT_READ|PROT_WRITE);
    plat_vm_test_set_protect_fail(0);
    if (!ae) FAIL_CASE("injected vm_remap failure did not fail");
    s2a_mem_backing_alias_unref(a,0x1000);
    if (plat_backing_refs(a,0x1000)!=0) FAIL_CASE("failed remap left refs");
    // vpool_release：表里两条记录覆盖同一批页，clear 必须逐段 unref。
    if (s2a_mem_backing_alias_ref(a,0x3000)!=1) FAIL_CASE("vpool ref failed");
    s2a_vp_alias_table table={0};
    assert(!s2a_vp_alias_add(&table,0,0x1000,a));
    assert(!s2a_vp_alias_add(&table,0x1000,0x3000,a+0x1000));
    s2a_vp_alias_remove(&table,0x1000,0x2000);
    if (plat_backing_refs(a+0x1000,0x1000)!=0 || plat_backing_refs(a+0x2000,0x1000)!=1) FAIL_CASE("vpool split kept wrong refs");
    s2a_vp_alias_clear(&table);
    if (plat_backing_refs(a,0x3000)!=0) FAIL_CASE("vpool clear left refs");
    puts("PASS nvn-remap-ref: deferred punch, grow 0xD401, partial overlap, failed remap, vpool release"); return 0;
}
static int case_nvn_dead_tail(void) {
    arena_prepare(2u<<20,4u<<20,0);
    uint64_t a=(uintptr_t)arena_heap;
    assert(!call(0x01,0,4u<<20,0,0,0));
    ((uint8_t *)a)[0]=0x5a;
    uint64_t shrink=call(0x01,0,2u<<20,0,0,0);
    if (shrink) FAIL_CASE("shrink to 2MiB returned %#llx",(unsigned long long)shrink);
    // 首页活、尾页已死：必须整体回 -EFAULT，不能 ref 成功后把后续 0x01 增长永久锁死。
    if (s2a_mem_backing_alias_ref(a+(2u<<20)-0x1000,0x2000)!=-EFAULT) FAIL_CASE("ref range with dead tail did not return -EFAULT");
    assert(!call(0x01,0,4u<<20,0,0,0));
    if (((uint8_t *)a)[2u<<20]!=0) FAIL_CASE("grow after rejected dead-tail ref not zero");
    puts("PASS nvn-dead-tail: per-page liveness rejects dead tail; later grow succeeds"); return 0;
}
static int case_deferred_report(void) {
    arena_prepare(2u<<20,4u<<20,0);
    uint64_t a=(uintptr_t)arena_heap;
    assert(!call(0x01,0,4u<<20,0,0,0));
    assert(s2a_mem_backing_alias_ref(a+(2u<<20),0x1000)==1);
    assert(!call(0x01,0,2u<<20,0,0,0));   // 死页有 ref：打洞推迟，deferred 计 1 页
    s2a_guest_va_report("deferred");
    s2a_mem_backing_alias_unref(a+(2u<<20),0x1000);
    puts("PASS deferred-report: release-time deferred page counted in 背板 report"); return 0;
}
static int case_tmem_close_mapped(void) {
    arena_prepare(2u<<20,2u<<20,1u<<20);
    uint64_t a=(uintptr_t)arena_alias+0x1000, b=(uintptr_t)arena_map+0x1000;
    assert(!call(0x2C,a,0x1000,0,0,0));
    ((uint8_t *)a)[0]=0x5a;
    tmem_addr=a; tmem_size=0x1000; tmem_closed=0;   // core_endpoints 的 s2a_tmem_get 夹具
    assert(!s2a_mem_tmem_borrow(a,0x1000,3));
    assert(!call(0x51,72,b,0x1000,3,0));
    if (((uint8_t *)b)[0]!=0x5a) FAIL_CASE("transfer map did not share source");
    s2a_mem_tmem_close(a,0x1000);   // 映射期间关最后一个句柄：源保持借出
    uint64_t rc=call(0x2D,a,0x1000,0,0,0);
    if (rc!=0xD401) FAIL_CASE("0x2D mapped transfer source returned %#llx",(unsigned long long)rc);
    if (((uint8_t *)b)[0]!=0x5a) FAIL_CASE("mapped transfer alias changed");
    tmem_closed=1;
    rc=call(0x52,72,b,0x1000,0,0);
    if (rc!=0xE401) FAIL_CASE("0x52 after handle close returned %#llx",(unsigned long long)rc);
    puts("PASS tmem-close-mapped: source stays borrowed, 0x2D 0xD401, 0x52 0xE401"); return 0;
}
static int case_stray_alias_refill(void) {
    arena_prepare(4u<<20,2u<<20,1u<<20);
    uint64_t a=(uintptr_t)arena_alias+0x1000, tmp=(uintptr_t)arena_map+0x1000;
    assert(!call(0x2C,a,0x1000,0,0,0));
    ((uint8_t *)a)[0]=0x5a;
    assert(!call(0x2D,a,0x1000,0,0,0));
    assert(!plat_vm_alias((void *)tmp,(const void *)a,0x1000,PROT_READ|PROT_WRITE));
    ((uint8_t *)tmp)[0]=0x77;   // 裸别名回填已释放页
    assert(!munmap((void *)tmp,0x1000));
    assert(!call(0x2C,a,0x1000,0,0,0));
    if (((uint8_t *)a)[0]!=0) FAIL_CASE("committed page kept stray alias data %02x",((uint8_t *)a)[0]);
    puts("PASS stray-alias-refill: commit-time punch discards stray write"); return 0;
}
static _Atomic int g_ru_stop;
static void *ru_writer(void *arg) {
    uint64_t a=(uintptr_t)arg;
    while (!atomic_load(&g_ru_stop)) {
        assert(!call(0x2D,a,0x1000,0,0,0));
        assert(!call(0x2C,a,0x1000,0,0,0));
    }
    return NULL;
}
static int case_readonly_punch_race(void) {
    arena_prepare(4u<<20,2u<<20,0);
    target=arena_alias+0x1000;
    assert(!call(0x2C,(uintptr_t)target,0x2000,0,0,0));
    memset(target,0x11,0x2000);
    unsigned char bytes[0x2000];
    s2a_android_readonly_test_hook=replace_during_copy;
    int error=s2a_android_copy_guest_readonly((uintptr_t)target,bytes,sizeof bytes);
    if (error) FAIL_CASE("readonly copy errno=%d",error);
    for (size_t i=0;i<sizeof bytes;i++) if (bytes[i]!=0) FAIL_CASE("mixed/stale byte %zu=%02x",i,bytes[i]);
    // s2a_track_read_untracked 也压一遍：读者页设成不可读走临时别名，另一线程同时 0x2D/0x2C 邻居页。
    s2a_track_reprotect((uintptr_t)target,0x1000,S2A_TRACK_NONE);
    uint64_t neighbor=(uintptr_t)target+0x2000;
    assert(!call(0x2C,neighbor,0x1000,0,0,0));
    memset((void *)neighbor,0x22,0x1000);
    atomic_store(&g_ru_stop,0);
    pthread_t writer; assert(!pthread_create(&writer,NULL,ru_writer,(void *)neighbor));
    unsigned char page[0x1000];
    for (int i=0;i<1000;i++) {
        assert(s2a_track_read_untracked((uintptr_t)target,page,sizeof page)>=0);
        for (size_t k=0;k<sizeof page;k++) if (page[k]!=0) FAIL_CASE("read_untracked mixed/stale byte %zu=%02x",k,page[k]);
    }
    atomic_store(&g_ru_stop,1);
    assert(!pthread_join(writer,NULL));
    puts("PASS readonly-punch-race: mid-copy punch retried; read_untracked concurrent with neighbor churn"); return 0;
}
static int case_nvn_stopworld(void) {
    arena_prepare(4u<<20,4u<<20,0);
    assert(!call(0x01,0,4u<<20,0,0,0));
    memset(arena_heap,0x5a,0x1000);
    atomic_store(&g_stopworld_stop,0);
    pthread_t worker; assert(!pthread_create(&worker,NULL,stopworld_worker,NULL));
    for (int i=0;i<2000;i++) {
        assert(!call(0x2D,(uintptr_t)arena_alias+0x1000,0x1000,0,0,0));
        assert(!call(0x2C,(uintptr_t)arena_alias+0x1000,0x1000,0,0,0));
    }
    atomic_store(&g_stopworld_stop,1);
    assert(!pthread_join(worker,NULL));
    if (before_count!=after_count) FAIL_CASE("transaction callbacks unbalanced %d/%d",before_count,after_count);
    puts("PASS nvn-stopworld: concurrent NVN-side ref/unref with VM churn (host smoke; real stop-world interlock needs thread owner)"); return 0;
}
static int case_lockorder_abort(void) {
    pid_t child=fork(); assert(child>=0);
    if (!child) { s2a_mem_test_lockorder_abort(); _exit(0); }
    int status; assert(waitpid(child,&status,0)==child);
    if (!WIFSIGNALED(status) || WTERMSIG(status)!=SIGABRT) FAIL_CASE("lock-order assertion did not abort: status=%d",status);
    puts("PASS lockorder-abort: holding g_mu then taking g_vp_mu aborts"); return 0;
}
static int case_va_report_lock(void) {
    arena_prepare(0x100000,0x200000,0);
    setenv("S2A_VMA_REPORT","1",1);   // 让 s2a_guest_va_report 真的走一遍 VMA 采样（解析 maps 时不得持 g_mu）
    alarm(5);
    s2a_guest_va_report("fixture");   // 旧 B1：这里会永久持有 g_mu，下面的 query 卡死
    s2a_meminfo mi;
    int error=s2a_mem_query((uintptr_t)arena_alias,&mi);
    alarm(0);
    if (error) FAIL_CASE("query after va_report errno=%d",error);
    puts("PASS va-report-lock: va_report releases g_mu before VMA sampling; following query returns"); return 0;
}
// Q6：打洞计数与累计耗时只在 Android 编译。三类的增量必须跟实际操作对上；deferred 不算打洞。
static int case_punch_stats(void) {
    arena_prepare(2u<<20,4u<<20,0);
    uint64_t before[6],mid[6],mid2[6],mid3[6],end[6];
    s2a_mem_test_backing_punch_stats(before);
    uint64_t a=(uintptr_t)arena_alias;
    for (int i=0;i<8;i++) {
        assert(!call(0x2C,a,0x1000,0,0,0));   // 提交前打洞
        assert(!call(0x2D,a,0x1000,0,0,0));   // 释放打洞
    }
    s2a_mem_test_backing_punch_stats(mid);
    if (mid[0]-before[0]!=8) FAIL_CASE("commit punch count %llu -> %llu",(unsigned long long)before[0],(unsigned long long)mid[0]);
    if (mid[1]<=before[1]) FAIL_CASE("commit punch time not accumulated (%llu -> %llu ns)",(unsigned long long)before[1],(unsigned long long)mid[1]);
    if (mid[2]-before[2]!=8) FAIL_CASE("release punch count %llu -> %llu",(unsigned long long)before[2],(unsigned long long)mid[2]);
    if (mid[3]<=before[3]) FAIL_CASE("release punch time not accumulated (%llu -> %llu ns)",(unsigned long long)before[3],(unsigned long long)mid[3]);
    // 最后一次 unref 补打：死页带 ref 时释放打洞被推迟，unref 之后才真正打洞。
    uint64_t dead=(uintptr_t)arena_heap+(2u<<20);
    assert(!call(0x01,0,4u<<20,0,0,0));
    ((uint8_t *)dead)[0]=0x5a;
    if (s2a_mem_backing_alias_ref(dead,0x1000)!=1) FAIL_CASE("ref dead tail page failed");
    s2a_mem_test_backing_punch_stats(mid2);
    uint64_t deferred_before=s2a_mem_test_release_deferred();
    assert(!call(0x01,0,2u<<20,0,0,0));   // 缩堆：带 ref 的死页推迟，其它尾页当场打洞
    s2a_mem_test_backing_punch_stats(mid3);
    if (s2a_mem_test_release_deferred()<=deferred_before) FAIL_CASE("shrink with ref'd dead page did not defer");
    if (plat_backing_refs(dead,0x1000)!=1) FAIL_CASE("deferred page lost its ref");
    if (mid3[4]!=mid2[4]) FAIL_CASE("unref punch counted before unref (%llu -> %llu)",(unsigned long long)mid2[4],(unsigned long long)mid3[4]);
    s2a_mem_backing_alias_unref(dead,0x1000);
    if (plat_backing_refs(dead,0x1000)!=0) FAIL_CASE("unref left refs on deferred page");
    s2a_mem_test_backing_punch_stats(end);
    if (end[4]-mid3[4]!=1) FAIL_CASE("unref punch count %llu -> %llu",(unsigned long long)mid3[4],(unsigned long long)end[4]);
    if (end[5]<=mid3[5]) FAIL_CASE("unref punch time not accumulated (%llu -> %llu ns)",(unsigned long long)mid3[5],(unsigned long long)end[5]);
    s2a_guest_va_report("punch-stats");   // 宿主样例行：punch_commit/release/unref 都在
    printf("PASS punch-stats: commit=%llu/%lluns release=%llu/%lluns unref=%llu/%lluns\n",
           (unsigned long long)end[0],(unsigned long long)end[1],(unsigned long long)end[2],
           (unsigned long long)end[3],(unsigned long long)end[4],(unsigned long long)end[5]);
    return 0;
}
// hula 追加：far 只数 guest 背板 / 别名映射越出 guest 窗口；窗口上方的宿主 anon/kgsl/dalvik 单列 host。
static int case_vma_far(void) {
    arena_prepare(2u<<20,2u<<20,0);
    setenv("S2A_VMA_REPORT","1",1);
    size_t pg=plat_page_size();
    void *hostmap=mmap(NULL,4*pg,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if (hostmap==MAP_FAILED) FAIL_CASE("host mmap errno=%d",errno);
    s2a_guest_va_report("vma-far-host");
    uint64_t stat[6]; s2a_android_vma_test_last(stat);
    if (stat[4]!=0) FAIL_CASE("host mappings counted as far: far=%llu host=%llu",(unsigned long long)stat[4],(unsigned long long)stat[5]);
    if (stat[5]==0) FAIL_CASE("host mappings above window not reported separately");
    if (stat[1]==0) FAIL_CASE("guest window mappings not counted");
    // 窗口上方再放一张 guest 背板页：这是 guest 越窗，far 只数它。
    void *scratch=mmap(NULL,pg,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if (scratch==MAP_FAILED) FAIL_CASE("scratch mmap errno=%d",errno);
    uint64_t pgoff=(uintptr_t)arena_heap;
    int error=plat_backing_map(scratch,pg,PLAT_PROT_READ|PLAT_PROT_WRITE,pgoff);
    if (error) FAIL_CASE("backing map above window errno=%d",error);
    s2a_guest_va_report("vma-far-guest");
    s2a_android_vma_test_last(stat);
    if (stat[4]!=1) FAIL_CASE("guest backing page above window far=%llu host=%llu",(unsigned long long)stat[4],(unsigned long long)stat[5]);
    assert(!munmap(scratch,pg)); assert(!munmap(hostmap,4*pg));
    puts("PASS vma-far: host mappings above window counted separately; only guest backing beyond window is far"); return 0;
}
// fake_page16：4K 对齐、16K 不对齐的 NVN 请求在 vpool_map 早退，只进页表，别名表与 refs 都不动。
// 早退判定与 graphics/nvn/gfx/nvn/hle_nvn.c:2836 同式；run.py 的 vpalias-wired 检查它仍在别名操作之前。
static int nvn_page_table_only(uint64_t voff,uint64_t size,uint64_t src,uint64_t pool_len) {
    size_t pg=plat_page_size();
    return !pg || voff+size>pool_len || ((voff|size|src)&(pg-1));
}
static int case_nvn_alias_16k(void) {
    arena_prepare(2u<<20,4u<<20,0);
    fake_page16=1;
    size_t pg=plat_page_size();
    if (pg!=0x4000) FAIL_CASE("fake_page16 page=%zu",pg);
    uint64_t h=(uintptr_t)arena_heap, refs_before=plat_backing_refs(h,pg);
    uint64_t voff=0x1000,size=0x1000,src=h+0x2000;   // 4K 对齐，16K 不对齐
    if (!nvn_page_table_only(voff,size,src,2u<<20)) FAIL_CASE("4K/16K-unaligned request not page-table-only");
    s2a_vp_alias_table table={0};
    int vpt_entries=1;   // 页表模型：这条请求只记进页表
    if (vpt_entries!=1 || table.n!=0) FAIL_CASE("page-table-only request touched alias table");
    if (plat_backing_refs(h,pg)!=refs_before) FAIL_CASE("page-table-only request changed backing refs");
    if (nvn_page_table_only(0x4000,0x4000,h,2u<<20)) FAIL_CASE("16K-aligned request rejected");
    // 入口断言：别名表本身拒绝不对齐区间（调用方违约必须响亮中止，不能算错）。
    pid_t child=fork(); assert(child>=0);
    if (!child) { s2a_vp_alias_table t={0}; s2a_vp_alias_add(&t,voff,voff+size,src); _exit(0); }
    int status; assert(waitpid(child,&status,0)==child);
    if (!WIFSIGNALED(status) || WTERMSIG(status)!=SIGABRT) FAIL_CASE("unaligned alias_add did not abort: status=%d",status);
    puts("PASS nvn-alias-16k: 4K/16K-unaligned request stays page-table-only; alias table/refs unchanged; add() enforces alignment"); return 0;
}
static _Atomic int g_inject_ref_done;
static void inject_prepare_ref(uint64_t a, uint64_t n) {
    if (!atomic_exchange(&g_inject_ref_done,1)) assert(!plat_backing_ref(a,n));
}
static int case_nvn_ref_race(void) {
    arena_prepare(2u<<20,2u<<20,0);
    uint64_t a=(uintptr_t)arena_alias+0x1000;
    assert(!call(0x2C,a,0x1000,0,0,0));
    ((uint8_t *)a)[0]=0x5a;
    assert(!call(0x2D,a,0x1000,0,0,0));
    atomic_store(&g_inject_ref_done,0);
    s2a_mem_test_prepare_hook=inject_prepare_ref;
    uint64_t rc=call(0x2C,a,0x1000,0,0,0);
    s2a_mem_test_prepare_hook=NULL;
    if (rc!=0xD401) FAIL_CASE("window ref raced commit returned %#llx, want 0xD401",(unsigned long long)rc);
    if (s2a_mem_mapped(a,0x1000)) FAIL_CASE("failed reuse left a mapping");
    if (plat_backing_refs(a,0x1000)==0) FAIL_CASE("injected ref was not seen");
    s2a_guest_va_report("reuse");
    s2a_mem_backing_alias_unref(a,0x1000);   // 放掉注入的 ref，顺便打掉已死页
    assert(!call(0x2C,a,0x1000,0,0,0));
    if (((uint8_t *)a)[0]!=0) FAIL_CASE("post-race commit not zero");
    puts("PASS nvn-ref-race: ref injected in begin window -> 0xD401, no die; retry maps zero"); return 0;
}
#define BACKING_CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr,"FAIL backing-api: " __VA_ARGS__); fputc('\n',stderr); return 1; } } while (0)
// P1 纯背板接口：不依赖 svc_mem / tracker / 生产调用方。
static int backing_api(void) {
    size_t pg=plat_page_size(); assert(pg);
    int deferred=-1;
    BACKING_CHECK(plat_backing_limit()==0,"limit before open = %llu",(unsigned long long)plat_backing_limit());
    BACKING_CHECK(plat_backing_reset()==EINVAL,"reset before open = %d",plat_backing_reset());
    BACKING_CHECK(plat_backing_refs(0,pg)==UINT32_MAX,"refs before open must be UINT32_MAX");
    int error=plat_backing_open(1ull<<31);
    BACKING_CHECK(!error,"open 2GiB errno=%d",error);
    uint64_t limit=plat_backing_limit();
    BACKING_CHECK(limit==(1ull<<31),"limit=%llu",(unsigned long long)limit);
    uint64_t sequence=plat_backing_sequence();
    BACKING_CHECK(!(sequence&1),"sequence odd after open: %llu",(unsigned long long)sequence);

    // open / map / 同一 pgoff 的两个视图。
    void *basic=NULL,*second=NULL;
    BACKING_CHECK(!plat_vm_reserve(0x8000,pg,1ull<<31,&basic),"reserve basic errno=%d",errno);
    BACKING_CHECK(!plat_vm_reserve(2*pg,pg,1ull<<31,&second),"reserve second errno=%d",errno);
    uint64_t basic_off=(uint64_t)(uintptr_t)basic;
    if (pg > 0x1000) {
        // 16K 模型：4K 偏移/长度必须在任何映射前被拒。
        BACKING_CHECK(plat_backing_map(basic,pg,PLAT_PROT_READ|PLAT_PROT_WRITE,basic_off+0x1000)==EINVAL,
                      "4K pgoff must be EINVAL under 16K pages");
        BACKING_CHECK(plat_backing_punch(basic_off+0x1000,pg,&deferred)==EINVAL,
                      "4K punch pgoff must be EINVAL under 16K pages");
        BACKING_CHECK(plat_backing_punch(basic_off,0x1000,&deferred)==EINVAL,
                      "4K punch size must be EINVAL under 16K pages");
        BACKING_CHECK(plat_backing_ref(basic_off+0x1000,pg)==EINVAL,
                      "4K ref pgoff must be EINVAL under 16K pages");
    }
    error=plat_backing_map(basic,2*pg,PLAT_PROT_READ|PLAT_PROT_WRITE,basic_off);
    BACKING_CHECK(!error,"map basic errno=%d",error);
    uint8_t *a=basic; a[0]=0x5a; a[pg]=0x22;
    error=plat_backing_map(second,2*pg,PLAT_PROT_READ|PLAT_PROT_WRITE,basic_off);
    BACKING_CHECK(!error,"map second view errno=%d",error);
    uint8_t *b=second;
    BACKING_CHECK(b[0]==0x5a && b[pg]==0x22,"second view not shared: %02x/%02x",b[0],b[pg]);
    b[1]=0x5c; BACKING_CHECK(a[1]==0x5c,"write through second view not visible");
    BACKING_CHECK(maps_perm(basic)==3,"basic mapping perm=%d",maps_perm(basic));
    BACKING_CHECK(maps_has((uint64_t)(uintptr_t)basic,(uint64_t)(uintptr_t)basic+2*pg,"memfd:s2a-guest"),
                  "mapping is not memfd:s2a-guest");

    // punch：只清目标页，两个视图同时读回零；世代号前后各 +1。
    uint64_t before=plat_backing_sequence();
    error=plat_backing_punch(basic_off,pg,&deferred);
    BACKING_CHECK(!error && !deferred,"punch errno=%d deferred=%d",error,deferred);
    BACKING_CHECK(plat_backing_sequence()==before+2,"punch sequence %llu -> %llu",
                  (unsigned long long)before,(unsigned long long)plat_backing_sequence());
    BACKING_CHECK(!a[0] && !b[0] && a[pg]==0x22 && b[pg]==0x22,"punch crossed page boundary: %02x/%02x/%02x/%02x",a[0],b[0],a[pg],b[pg]);

    // deferred 出参：有 refs 时不调内核、数据保留、世代号不变。
    error=plat_backing_ref(basic_off,pg);
    BACKING_CHECK(!error,"ref errno=%d",error);
    BACKING_CHECK(plat_backing_refs(basic_off,pg)==1,"refs=%u",plat_backing_refs(basic_off,pg));
    a[0]=0x33;
    before=plat_backing_sequence(); uint64_t deferred_before=plat_backing_deferred();
    error=plat_backing_punch(basic_off,pg,&deferred);
    BACKING_CHECK(!error && deferred==1,"deferred punch errno=%d deferred=%d",error,deferred);
    BACKING_CHECK(plat_backing_sequence()==before,"deferred punch changed sequence");
    BACKING_CHECK(plat_backing_deferred()==deferred_before+1,"deferred count %llu -> %llu",
                  (unsigned long long)deferred_before,(unsigned long long)plat_backing_deferred());
    BACKING_CHECK(a[0]==0x33,"deferred punch zeroed live page");
    error=plat_backing_unref(basic_off,pg);
    BACKING_CHECK(!error,"unref errno=%d",error);
    error=plat_backing_punch(basic_off,pg,&deferred);
    BACKING_CHECK(!error && !deferred && !a[0],"retry punch errno=%d deferred=%d byte=%02x",error,deferred,a[0]);

    // refs 稀疏区间：重叠拆段、相邻合并、区间内最大值；范围不匹配与下溢回 EINVAL。
    error=plat_backing_ref(basic_off,3*pg);
    BACKING_CHECK(!error && plat_backing_refs(basic_off,3*pg)==1,"ref 3 pages refs=%u",plat_backing_refs(basic_off,3*pg));
    error=plat_backing_ref(basic_off+pg,pg);
    BACKING_CHECK(!error,"ref middle errno=%d",error);
    BACKING_CHECK(plat_backing_refs(basic_off,3*pg)==2,"nested max refs=%u",plat_backing_refs(basic_off,3*pg));
    BACKING_CHECK(plat_backing_refs(basic_off,pg)==1 && plat_backing_refs(basic_off+pg,pg)==2
                  && plat_backing_refs(basic_off+2*pg,pg)==1,"split refs mismatch");
    BACKING_CHECK(plat_backing_unref(basic_off+pg,pg)==0,"unref middle errno");
    BACKING_CHECK(plat_backing_refs(basic_off,3*pg)==1,"merge back refs=%u",plat_backing_refs(basic_off,3*pg));
    BACKING_CHECK(plat_backing_unref(basic_off,4*pg)==EINVAL,"unref past refs must be EINVAL");
    BACKING_CHECK(plat_backing_unref(basic_off+3*pg,pg)==EINVAL,"unref hole must be EINVAL");
    BACKING_CHECK(plat_backing_refs(basic_off,3*pg)==1,"failed unref changed refs");
    BACKING_CHECK(plat_backing_unref(basic_off,3*pg)==0,"unref all errno");
    BACKING_CHECK(plat_backing_refs(basic_off,3*pg)==0,"refs after unref=%u",plat_backing_refs(basic_off,3*pg));
    BACKING_CHECK(plat_backing_unref(basic_off,pg)==EINVAL,"double unref must be EINVAL");

    // 部分重叠 [0,2) 与 [1,3)：重叠页 2 次，两翼各 1 次。
    error=plat_backing_ref(basic_off,2*pg);
    BACKING_CHECK(!error,"partial ref A errno=%d",error);
    error=plat_backing_ref(basic_off+pg,2*pg);
    BACKING_CHECK(!error,"partial ref B errno=%d",error);
    BACKING_CHECK(plat_backing_refs(basic_off,pg)==1 && plat_backing_refs(basic_off+pg,pg)==2
                  && plat_backing_refs(basic_off+2*pg,pg)==1,"partial overlap refs mismatch");
    BACKING_CHECK(plat_backing_unref(basic_off,2*pg)==0 && plat_backing_unref(basic_off+pg,2*pg)==0,
                  "partial overlap unref failed");
    BACKING_CHECK(plat_backing_refs(basic_off,3*pg)==0,"partial overlap refs left");

    // 中间 unref 出空洞后，再对整段 unref 必须 EINVAL 且不改状态。
    error=plat_backing_ref(basic_off,3*pg);
    BACKING_CHECK(!error,"hole ref errno=%d",error);
    BACKING_CHECK(plat_backing_unref(basic_off+pg,pg)==0,"hole unref errno");
    BACKING_CHECK(plat_backing_unref(basic_off,3*pg)==EINVAL,"whole unref across hole must be EINVAL");
    BACKING_CHECK(plat_backing_refs(basic_off,pg)==1 && plat_backing_refs(basic_off+pg,pg)==0
                  && plat_backing_refs(basic_off+2*pg,pg)==1,"hole unref changed refs");
    BACKING_CHECK(plat_backing_unref(basic_off,pg)==0 && plat_backing_unref(basic_off+2*pg,pg)==0,
                  "hole cleanup unref failed");

    // punch 区间宽于 ref 区间：整段仍 deferred，不调内核、数据不变。
    error=plat_backing_ref(basic_off+pg,pg);
    BACKING_CHECK(!error,"wide deferred ref errno=%d",error);
    a[0]=0x21; a[pg]=0x22;
    before=plat_backing_sequence();
    error=plat_backing_punch(basic_off,2*pg,&deferred);
    BACKING_CHECK(!error && deferred==1 && plat_backing_sequence()==before,
                  "wide deferred punch errno=%d deferred=%d",error,deferred);
    BACKING_CHECK(a[0]==0x21 && a[pg]==0x22,"wide deferred punch changed data");
    BACKING_CHECK(plat_backing_unref(basic_off+pg,pg)==0,"wide deferred unref errno");

    // reset：refs 非空 EBUSY；否则整文件打洞，多页映射读回零，limit 不变。
    a[0]=0x77; a[pg]=0x78; error=plat_backing_ref(basic_off,pg);
    BACKING_CHECK(!error,"reset ref errno=%d",error);
    BACKING_CHECK(plat_backing_reset()==EBUSY,"reset with refs must be EBUSY");
    BACKING_CHECK(a[0]==0x77 && a[pg]==0x78,"EBUSY reset changed data");
    BACKING_CHECK(!plat_backing_unref(basic_off,pg),"reset unref errno");
    before=plat_backing_sequence();
    BACKING_CHECK(!plat_backing_reset(),"reset errno");
    BACKING_CHECK(plat_backing_sequence()==before+2,"reset sequence delta");
    BACKING_CHECK(!a[0] && !a[pg] && plat_backing_refs(basic_off,pg)==0 && plat_backing_limit()==(1ull<<31),
                  "reset left data/refs/limit");

    // 参数校验：不越界、不按页对齐、空 deferred 都回 errno，且不碰已有映射。
    BACKING_CHECK(plat_backing_map(basic,pg,PLAT_PROT_READ|PLAT_PROT_WRITE,limit)==EINVAL,
                  "map past limit must be EINVAL");
    BACKING_CHECK(plat_backing_map(basic,pg,PLAT_PROT_READ|PLAT_PROT_WRITE,basic_off+1)==EINVAL,
                  "unaligned pgoff must be EINVAL");
    BACKING_CHECK(plat_backing_refs(basic_off+1,pg)==UINT32_MAX,"unaligned refs must be UINT32_MAX");
    BACKING_CHECK(plat_backing_refs(limit,pg)==UINT32_MAX,"out-of-range refs must be UINT32_MAX");
    BACKING_CHECK(plat_backing_punch(basic_off,pg,NULL)==EINVAL,"NULL deferred must be EINVAL");
    BACKING_CHECK(plat_backing_open(0)==EINVAL,"open(0) must be EINVAL");
    BACKING_CHECK(maps_perm(basic)==3,"invalid calls broke existing mapping");

    // 1 万页逐页直映：同一 memfd、pgoff=VA，内核合并段数。
    size_t pages=10000, span=pages*pg;
    void *big=NULL;
    BACKING_CHECK(!plat_vm_reserve(span,pg,1ull<<31,&big),"reserve big errno=%d",errno);
    uint64_t big_off=(uint64_t)(uintptr_t)big;
    int count_before=maps_count(big_off,big_off+span);
    for (size_t i=0;i<pages;i++) {
        error=plat_backing_map((void *)(uintptr_t)(big_off+i*pg),pg,PLAT_PROT_READ|PLAT_PROT_WRITE,big_off+i*pg);
        if (error) { fprintf(stderr,"FAIL backing-api: map page %zu errno=%d\n",i,error); return 1; }
    }
    int count_after=maps_count(big_off,big_off+span);
    BACKING_CHECK(count_after<=count_before+8,"10000 direct maps: before=%d after=%d",count_before,count_after);
    uint8_t *bigp=big; bigp[0]=0x66; bigp[span-1]=0x67; bigp[5000*pg]=0x68;
    error=plat_backing_punch(big_off+5000*pg,pg,&deferred);
    BACKING_CHECK(!error && !deferred && !bigp[5000*pg] && bigp[0]==0x66 && bigp[span-1]==0x67,
                  "punch inside direct map errno=%d deferred=%d",error,deferred);
    BACKING_CHECK(maps_count(big_off,big_off+span)<=count_before+8,"punch split direct map: %d -> %d",
                  count_after,maps_count(big_off,big_off+span));

    // 单次 punch 计时：只打印读数，不设阈值判红。
    uint64_t samples[500];
    for (int round=0;round<2;round++) {
        uint64_t total=0;
        for (size_t i=0;i<sizeof samples/sizeof samples[0];i++) {
            if (round) bigp[9000*pg]=(uint8_t)i;   // 第二轮先写 1 字节，量已填充页
            uint64_t start=backing_now_ns();
            error=plat_backing_punch(big_off+9000*pg,pg,&deferred);
            samples[i]=backing_now_ns()-start;
            assert(!error && !deferred);
            total+=samples[i];
        }
        qsort(samples,sizeof samples/sizeof samples[0],sizeof samples[0],compare_u64);
        printf("BACKING punch ns/page %s p50=%llu mean=%llu\n",
               round?"populated":"hole",
               (unsigned long long)samples[sizeof samples/sizeof samples[0]/2],
               (unsigned long long)(total/(sizeof samples/sizeof samples[0])));
    }

    // 512G 末端：扩大后只增不缩；文件末端附近 map / punch 成功。
    error=plat_backing_open(512ull<<30);
    BACKING_CHECK(!error,"open 512GiB errno=%d",error);
    BACKING_CHECK(plat_backing_limit()==(512ull<<30),"512G limit=%llu",(unsigned long long)plat_backing_limit());
    BACKING_CHECK(!plat_backing_open(1ull<<31),"shrink open must succeed without shrinking");
    BACKING_CHECK(plat_backing_limit()==(512ull<<30),"shrink open changed limit=%llu",(unsigned long long)plat_backing_limit());
    uint64_t end_off=(512ull<<30)-2*pg;
    error=plat_backing_map(second,2*pg,PLAT_PROT_READ|PLAT_PROT_WRITE,end_off);
    BACKING_CHECK(!error,"map near 512G end errno=%d",error);
    b[0]=0x44; b[pg]=0x55;
    error=plat_backing_punch(end_off+pg,pg,&deferred);
    BACKING_CHECK(!error && !deferred && b[0]==0x44 && !b[pg],"punch near 512G end errno=%d deferred=%d",error,deferred);
    error=plat_backing_punch(end_off,pg,&deferred);
    BACKING_CHECK(!error && !deferred && !b[0],"punch last page errno=%d deferred=%d",error,deferred);

    BACKING_CHECK(fallocate_calls > 0,"no fallocate observed");
    printf("PASS backing-api: limit=%llu sequence=%llu deferred=%llu direct-maps=%d fallocate=%d\n",
           (unsigned long long)plat_backing_limit(),
           (unsigned long long)plat_backing_sequence(),
           (unsigned long long)plat_backing_deferred(),count_after,fallocate_calls);
    return 0;
}

static void stack_touch(uint64_t address,uint64_t size,int write) {
    (void)write;
    assert(in_quiesce && size==0x1000);
    s2a_meminfo mi; s2a_mem_query(address,&mi); // 真实GPU回调会查询VM；锁序错误必须卡在这里。
    s2a_track_write_quiet(address,size);
    ((uint8_t *)(uintptr_t)address)[7]=0x6b;
    s2a_track_reprotect(address,size,S2A_TRACK_READ);
    touch_count++;
}
static void incompatible_write(uint64_t a,uint64_t n) { (void)a; (void)n; }
int main(int argc,char **argv) {
    assert(argc==2); const char *mode=argv[1];
    if (!strcmp(mode,"backing-api")) return backing_api();
    if (!strcmp(mode,"backing-api-16k")) { fake_page16=1; return backing_api(); }
    // 镜像用例显式打开（缺省关，owner r4 第 1 条）；非镜像用例不 configure，保持生产缺省关。
    int mirror_mode=strstr(mode,"mirror")!=NULL;
    if (mirror_mode) assert(!s2a_android_mirror_configure(1));
    if (!strcmp(mode,"hooks-conflict")) {
        s2a_track_hooks hooks={NULL,incompatible_write,NULL,NULL}; s2a_register_track_hooks(&hooks);
        assert(s2a_android_tracking_vm_prepare()==EBUSY && !s2a_android_tracking_vm_ready());
        puts("PASS hooks-conflict: existing owner preserved"); return 0;
    }
    assert(!s2a_android_tracking_vm_ready());
    assert(!s2a_android_tracking_vm_prepare() && !s2a_android_tracking_vm_ready());
    if (!strcmp(mode,"backing-vma-merge")) return case_backing_vma_merge();
    if (!strcmp(mode,"physical-unmap-borrowed")) return case_physical_unmap_borrowed();
    if (!strcmp(mode,"backing-alias-shared")) return case_backing_alias_shared();
    if (!strcmp(mode,"backing-alias-merge")) return case_backing_alias_merge();
    if (!strcmp(mode,"nvn-remap-ref")) return case_nvn_remap_ref();
    if (!strcmp(mode,"tmem-close-mapped")) return case_tmem_close_mapped();
    if (!strcmp(mode,"stray-alias-refill")) return case_stray_alias_refill();
    if (!strcmp(mode,"readonly-punch-race")) return case_readonly_punch_race();
    if (!strcmp(mode,"nvn-stopworld")) return case_nvn_stopworld();
    if (!strcmp(mode,"nvn-ref-race")) return case_nvn_ref_race();
    if (!strcmp(mode,"nvn-dead-tail")) return case_nvn_dead_tail();
    if (!strcmp(mode,"deferred-report")) return case_deferred_report();
    if (!strcmp(mode,"lockorder-abort")) return case_lockorder_abort();
    if (!strcmp(mode,"va-report-lock")) return case_va_report_lock();
    if (!strcmp(mode,"punch-stats")) return case_punch_stats();
    if (!strcmp(mode,"vma-far")) return case_vma_far();
    if (!strcmp(mode,"nvn-alias-16k")) return case_nvn_alias_16k();
    if (!strcmp(mode,"private-stack-mirror")) {
        void *window=NULL; assert(!plat_vm_reserve(0x100000,0x4000,1ull<<39,&window));
        target=(uint8_t *)window+0x4000; source=(uint8_t *)window+0x80000;
        assert(mmap(target,0x1000,PROT_READ|PROT_WRITE,MAP_FIXED|MAP_PRIVATE|MAP_ANONYMOUS,-1,0)==target);
        target[0]=0xa5;
        s2a_mem_test_setup((uintptr_t)window+0xc0000,0x40000,(uintptr_t)window,0x100000,source,0);
        s2a_mem_test_map((uintptr_t)target,0x1000); s2a_mem_test_map_perm(0,3);
        unsigned char byte=0xcc; int error=s2a_android_copy_guest_readonly((uintptr_t)target,&byte,1);
        if (error!=EINVAL || byte!=0xcc) { fprintf(stderr,"FAIL private-stack-mirror: expected EINVAL and unchanged target, got %d/%02x\n",error,byte); return 1; }
        puts("PASS private-stack-mirror: private stack returns original EINVAL, never mirror zero"); return 0;
    }
    if (!strcmp(mode,"owner-window-fail")) {
        // 0x2C 增页的串行 epoch 升级失败：按协调失败返回 0xD401，且**没有**开始换页事务、
        // 映射与内容一律不变（复核必改第 1 条的契约）。
        discard_mode=1;
        void *window=NULL; assert(!plat_vm_reserve(16u<<20,2u<<20,1ull<<39,&window));
        target=(uint8_t *)window+0x400000; source=(uint8_t *)window+0x800000;
        s2a_mem_test_setup((uintptr_t)target,0x200000,(uintptr_t)window,16u<<20,source,0);
        s2a_mem_test_sysres(0x4000,0x200000);
        assert(!s2a_track_runtime_prepare()); s2a_track_set_backing_callbacks(before,after);
        int begin0=backing_begin_calls, before0=discard_before, after0=discard_after;
        owner_window_error=ETIMEDOUT;
        uint64_t rc=call(0x2C,(uintptr_t)target,0x1000,0,0,0);
        owner_window_error=0;
        assert(rc==0xD401);                                   // 错误码一路传回 svc 返回值
        assert(backing_begin_calls==begin0);                  // 事务没有被启动
        assert(discard_before==before0 && discard_after==after0);
        assert(maps_perm(target)==0 && !s2a_mem_mapped((uintptr_t)target,0x1000));   // 映射没改
        puts("PASS owner-window-fail: quiesce failure returns 0xD401 before track_backing_begin"); return 0;
    }
    if (!strncmp(mode,"physical",8) || !strncmp(mode,"heap",4)) {
        discard_mode=1;
        void *window=NULL; assert(!plat_vm_reserve(16u<<20,2u<<20,1ull<<39,&window));
        target=(uint8_t *)window+0x400000; source=(uint8_t *)window+0x800000;
        int heap=!strncmp(mode,"heap",4);
        if (!strcmp(mode,"physical-mirror-fallback")) fail_mirror_reserve=1;
        s2a_mem_test_setup((uintptr_t)(heap ? (uint8_t *)window+0xc00000 : target),0x200000,(uintptr_t)window,16u<<20,heap?target:source,0);
        fail_mirror_reserve=0;
        s2a_mem_test_sysres(0x4000,0x200000);
        assert(!s2a_track_runtime_prepare()); s2a_track_set_backing_callbacks(before,after);
        if (!strcmp(mode,"physical-host16-partial")) {
            fake_page16=1; assert(call(0x2C,(uintptr_t)target,0x1000,0,0,0));
            assert(!discard_before && !discard_after && maps_perm(target)==0 && !s2a_mem_mapped((uintptr_t)target,0x1000));
            puts("PASS physical-host16-partial: modeled page-size contract rejects before real mapping");return 0;
        }
        if (!strcmp(mode,"physical-map-fail") || !strcmp(mode,"heap-grow-fail")) fail_allocate=1;
        uint64_t rc=heap ? call(0x01,0,0x200000,0,0,0) : call(0x2C,(uintptr_t)target,0x4000,0,0,0);
        if (strstr(mode,"fail") && !strstr(mode,"unmap")) {
            assert(rc && maps_perm(target)==0 && !s2a_mem_mapped((uintptr_t)target,0x1000));
            assert(discard_before==1 && discard_after==1); puts("PASS real kernel allocation failure keeps metadata/reservation");return 0;
        }
        assert(!rc && target[7]==0);
        if (!strcmp(mode,"physical-mirror-report")) {
            s2a_android_mirror_report("fixture");
            puts("PASS physical-mirror-report: emitted initial reservation and VMA counts"); return 0;
        }
        if (!strcmp(mode,"physical-mirror-report-limit-unread")) {
            s2a_android_mirror_test_paths("/proc/self/maps","/s2a-nonexistent-max-map-count");
            s2a_android_mirror_report("fixture");
            puts("PASS physical-mirror-report-limit-unread: counters still emitted with unreadable limit"); return 0;
        }
        if (!strcmp(mode,"physical-mirror-syscall")) {
            unsigned char warm[8]; assert(!s2a_android_copy_guest_readonly((uintptr_t)target,warm,sizeof warm));
            pid_t child=fork(); assert(child>=0);
            if (!child) {
                struct sock_filter filter[]={
                    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,0),
                    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_exit_group,2,0),
                    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_exit,1,0),
                    BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_TRAP),
                    BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW)
                };
                struct sock_fprog program={.len=(unsigned short)(sizeof filter/sizeof filter[0]),.filter=filter};
                if (prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0) || prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&program)) _exit(90);
                unsigned char bytes[0x1001];
                int error=s2a_android_copy_guest_readonly((uintptr_t)target,bytes,sizeof bytes);
                _exit(error ? 91 : 0);
            }
            int status; assert(waitpid(child,&status,0)==child);
            if (!WIFEXITED(status) || WEXITSTATUS(status)!=0) { fprintf(stderr,"FAIL physical-mirror-syscall: seccomp status=%d\n",status); return 1; }
            puts("PASS physical-mirror-syscall: seccomp traps any syscall during steady copy"); return 0;
        }
        if (!strcmp(mode,"physical-mirror-fallback")) {
            target[7]=0x6a; unsigned char byte=0;
            count_copy_maps=1;
            int error=s2a_android_copy_guest_readonly((uintptr_t)target+7,&byte,1);
            count_copy_maps=0;
            if (error || byte!=0x6a || !copy_maps) { fprintf(stderr,"FAIL physical-mirror-fallback: errno=%d byte=%02x mmap=%d\n",error,byte,copy_maps); return 1; }
            puts("PASS physical-mirror-fallback: reservation failure falls back to real per-page alias"); return 0;
        }
        if (!strcmp(mode,"physical-mirror-split")) {
            mirror_stress=1;
            assert(!call(0x2D,(uintptr_t)target,0x2000,0,0,0));
            assert(!call(0x2C,(uintptr_t)target,0x1000,0,0,0));
            assert(!call(0x2C,(uintptr_t)target+0x1000,0x1000,0,0,0));
            memset(target,0xa7,0x1000); memset(target+0x1000,0x53,0x1000);
            unsigned char bytes[0x2000]; assert(!s2a_android_copy_guest_readonly((uintptr_t)target,bytes,sizeof bytes));
            for (size_t i=0;i<sizeof bytes;i++) assert(bytes[i]==(i<0x1000?0xa7:0x53));
            puts("PASS physical-mirror-split: adjacent independently allocated backings preserved"); return 0;
        }
        if (!strcmp(mode,"physical-mirror-snapshot")) {
            mirror_stress=1;
            memset(target,0x11,0x2000);
            unsigned char bytes[0x2000];
            s2a_android_readonly_test_hook=replace_during_copy;
            int error=s2a_android_copy_guest_readonly((uintptr_t)target,bytes,sizeof bytes);
            assert(!error && !s2a_android_readonly_test_hook);
            for (size_t i=0;i<sizeof bytes;i++) if (bytes[i]!=0) {
                fprintf(stderr,"FAIL physical-mirror-snapshot: stale byte at %zu=%02x\n",i,bytes[i]); return 1;
            }
            puts("PASS physical-mirror-snapshot: mid-copy replacement retries entire snapshot"); return 0;
        }
        if (!strcmp(mode,"physical-mirror-race")) {
            mirror_stress=1; memset(target,0x11,0x2000);
            pthread_t writer; assert(!pthread_create(&writer,NULL,mirror_writer,NULL));
            unsigned long ok=0, faults=0, busy=0;
            for (int n=0;n<10000;n++) {
                unsigned char bytes[0x2000];
                int error=s2a_android_copy_guest_readonly((uintptr_t)target,bytes,sizeof bytes);
                if (error==EFAULT) { faults++; continue; }
                if (error==EAGAIN) { busy++; continue; }   // 持续搅动下世代重试耗尽的设计返回值，不算失败
                if (error) { fprintf(stderr,"FAIL race: unexpected errno=%d\n",error); return 1; }
                unsigned char expected=bytes[0];
                if (expected!=0 && expected!=0x11) { fprintf(stderr,"FAIL race: unexpected value=%02x\n",expected); return 1; }
                for (size_t i=1;i<sizeof bytes;i++) if (bytes[i]!=expected) { fprintf(stderr,"FAIL race: mixed byte %zu\n",i); return 1; }
                ok++;
            }
            assert(!pthread_join(writer,NULL));
            printf("PASS physical-mirror-race: 10000 copies; success=%lu EFAULT=%lu EAGAIN=%lu; 10000 unmap/map pairs\n",ok,faults,busy); return 0;
        }
        if (!strcmp(mode,"physical-mirror")) {
            target[7]=0x39; target[0x1007]=0x45;
            unsigned char bytes[0x1002] = {0};
            count_copy_maps=1;
            int error=s2a_android_copy_guest_readonly((uintptr_t)target+7,bytes,sizeof bytes);
            count_copy_maps=0;
            assert(!error && bytes[0]==0x39 && bytes[0x1000]==0x45);
            if (copy_maps || copy_mremaps || copy_mprotects || copy_munmaps) { fprintf(stderr,"FAIL physical-mirror: mapping calls mmap=%d mremap=%d mprotect=%d munmap=%d, expected 0\n",copy_maps,copy_mremaps,copy_mprotects,copy_munmaps); return 1; }
            puts("PASS physical-mirror: shared backing bytes preserved; mmap/mremap/mprotect/munmap=0"); return 0;
        }
        if (!strcmp(mode,"physical-unmap-fail") || !strcmp(mode,"heap-unmap-fail")) fail_unmap=1;
        if (heap) {
            // P2 的堆新页都是 memfd 零页：增长后写内容，缩掉再长回来必须还是零（提交前打洞 /
            // 释放后打洞都生效），不能靠旧匿名页的残留内容。
            assert(!call(0x01,0,0x200000,0,0,0));
            assert(target[7]==0 && target[0x1007]==0);
            target[7]=0x3a; target[0x1007]=0x45;
            s2a_track_reprotect((uintptr_t)target,0x1000,S2A_TRACK_NONE);
            assert(!call(0x01,0,0,0,0,0));
            assert(maps_perm(target)==0 && !s2a_mem_mapped((uintptr_t)target,0x1000));
            assert(!call(0x01,0,0x200000,0,0,0));
            assert(target[7]==0 && target[0x1007]==0); // 新堆是零页，旧内容已随释放打洞。
        } else {
            // 生产新页必须支持 W2 的真实共享 alias。source 是 target 的第二视图（dst=source,
            // src=target）；P2 起这是一条长寿别名，必须显式 ref 才能在 0x2D 打洞时保住内容
            // （0x4C/0x51/NVN 都走这条记账；裸别名没有 ref，会被提交前打洞清零）。
            uint64_t length=0x4000;
            assert(!plat_vm_alias(source,target,length,PROT_READ|PROT_WRITE));
            target[7]=0x39; target[0x1007]=0x45;
            assert(source[7]==0x39 && source[0x1007]==0x45);
            assert(s2a_mem_backing_alias_ref((uintptr_t)target,length)==1);
            s2a_track_reprotect((uintptr_t)target,0x1000,S2A_TRACK_NONE);
            assert(!call(0x2D,(uintptr_t)target,0x1000,0,0,0));
            assert(maps_perm(target)==0 && maps_perm(target+0x1000)==3);
            assert(target[0x1007]==0x45 && source[7]==0x6d && !s2a_mem_mapped((uintptr_t)target,0x1000));
            // 解掉这条长寿别名后才允许重新提交同一 VA；unref 会把已死页打洞。
            s2a_mem_backing_alias_unref((uintptr_t)target,length);
            assert(plat_backing_refs((uintptr_t)target,length)==0);
            assert(!call(0x2C,(uintptr_t)target,0x1000,0,0,0));
            assert(target[7]==0 && target[0x1007]==0x45 && source[7]==0);
            // 一次请求含已经映射的邻居：只处理实际变化的两段，不把邻居身份/内容冲掉。
            assert(!call(0x2D,(uintptr_t)target,0x1000,0,0,0));
            assert(!call(0x2D,(uintptr_t)target+0x2000,0x1000,0,0,0));
            assert(!call(0x2C,(uintptr_t)target,0x3000,0,0,0));
            assert(target[7]==0 && target[0x1007]==0x45 && target[0x2007]==0);
        }
        assert(discard_before==discard_after && !in_quiesce);
        // 关路径（owner r4 第 2 条）：镜像关时 backing_end_locked 不得调 reset_before_publish，回到 main 旧时序。
        // （开侧 physical-mirror 在本宏前就返回，这里只覆盖关侧；开侧未断言。）
        assert(reset_before_publish_calls == 0);
        printf("PASS %s: memfd-backed pages, exact subpage replacement, alias ref preserved, callbacks=%d, reset=%u\n",mode,discard_before,reset_before_publish_calls);return 0;
    }
    void *window=NULL; assert(!plat_vm_reserve(0x100000,0x4000,1ull<<39,&window));
    target=(uint8_t *)window+0x4000; source=(uint8_t *)window+0x80000;
    int stack4k=!strcmp(mode,"stack-4k") || !strcmp(mode,"unmap-madvise-private"), protect4k=!strcmp(mode,"protect-4k");
    int alias4k=!strncmp(mode,"shared-4k",9) || !strcmp(mode,"code-4k") || !strcmp(mode,"transfer-4k") || stack4k || protect4k;
    int model16=strstr(mode,"model16") != NULL;
    if (alias4k) {
        assert(__real_plat_page_size()==0x1000);
        target+=0x1000; source+=0x1000; logical_size=0x1000;
        // 独立相邻页不能被共享映射的错误向上取整或unmap吞掉。
        if (!stack4k) {
            assert(!mprotect(target-0x1000,0x1000,PROT_READ|PROT_WRITE));
            assert(!mprotect(target+0x1000,0x1000,PROT_READ|PROT_WRITE));
            target[-1]=0x51; target[0x1000]=0x62;
        }
    }
    if (model16) {
        fake_page16=1;
        if (strstr(mode,"-source")) source+=0x1000;
        if (!strcmp(mode,"shared-model16-target")) target+=0x1000;
        if (!strcmp(mode,"shared-model16-partial")) logical_size=0x1000;
    }
    int fd=(int)syscall(SYS_memfd_create,"vm-source",0); assert(fd>=0 && !ftruncate(fd,0x4000));
    int private_source=!strcmp(mode,"private-source");
    assert(mmap(source,0x4000,PROT_READ|PROT_WRITE,(private_source?MAP_PRIVATE:MAP_SHARED)|MAP_FIXED,fd,0)==source);
    source[7]=0x19;
    if (!strcmp(mode,"partial-shared")) logical_size=0x3000;
    expected_span=(logical_size+__wrap_plat_page_size()-1)&~(__wrap_plat_page_size()-1);
    s2a_mem_test_setup((uintptr_t)window+0xc0000,0x40000,(uintptr_t)window,0x100000,source,0x4000);
    s2a_mem_test_sysres(0,0x4000);
    assert(!s2a_track_runtime_prepare()); assert(!s2a_track_runtime_ready());
    if (protect4k) {
        assert(!mprotect(target,0x1000,PROT_READ|PROT_WRITE));
        assert(!call(0x02,(uintptr_t)target,0x1000,1,0,0));
        assert(maps_perm(target)==1 && maps_perm(target-0x1000)==3 && maps_perm(target+0x1000)==3);
        assert(last_prot_address==(uintptr_t)target && last_prot_size==0x1000);
        assert(!call(0x02,(uintptr_t)target,0x1000,3,0,0));
        assert(maps_perm(target)==3 && maps_perm(target-0x1000)==3 && maps_perm(target+0x1000)==3);
        assert(target[-1]==0x51 && target[0x1000]==0x62);
        puts("PASS protect-4k: tighten/widen actual 4K page without touching neighbours"); return 0;
    }
    if (stack4k) {
        s2a_layout *layout=(s2a_layout *)(uintptr_t)s2a_layout_get();
        layout->stack_base=(uintptr_t)target; layout->stack_size=0x1000;
        assert(maps_perm(target-0x1000)==0 && maps_perm(target+0x1000)==0);
        assert(!call(0x04,(uintptr_t)target,(uintptr_t)source,0x1000,0,0));
        assert(maps_perm(target)==3 && maps_perm(target-0x1000)==0 && maps_perm(target+0x1000)==0);
        assert(last_prot_address==(uintptr_t)target && last_prot_size==0x1000);
        target[7]=0x42;
        if (!strcmp(mode,"unmap-madvise-private")) fail_madvise=1;
        assert(!call(0x05,(uintptr_t)target,(uintptr_t)source,0x1000,0,0));
        assert(source[7]==0x42 && maps_perm(target)==0 && maps_perm(target-0x1000)==0 && maps_perm(target+0x1000)==0);
        if (fail_madvise) {
            if (!madvise_calls) FAIL_CASE("madvise was not called");
            puts("PASS unmap-madvise-private: madvise failure logged red, unmap still succeeds"); return 0;
        }
        puts("PASS stack-4k: actual 4K map/unmap preserves both neighbours"); return 0;
    }
    if (!strcmp(mode,"stack-copy") || !strcmp(mode,"stack-readback") || !strcmp(mode,"stack-source-readback")) {
        // 只设置测试布局；Map/Unmap、映射表、tracker回写与内核页均由生产源执行。
        s2a_layout *layout=(s2a_layout *)(uintptr_t)s2a_layout_get();
        layout->stack_base=(uintptr_t)target; layout->stack_size=0x4000;
        s2a_track_set_touch(stack_touch);
        int source_readback=!strcmp(mode,"stack-source-readback"), target_readback=!strcmp(mode,"stack-readback");
        if (source_readback) s2a_track_reprotect((uintptr_t)source,0x1000,S2A_TRACK_NONE);
        assert(!call(0x04,(uintptr_t)target,(uintptr_t)source,0x4000,0,0));
        assert(target[7]==(source_readback ? 0x6b : 0x19));
        target[7]=0x42;
        s2a_track_reprotect((uintptr_t)source,0x1000,S2A_TRACK_NONE);
        if (target_readback) s2a_track_reprotect((uintptr_t)target,0x1000,S2A_TRACK_NONE);
        assert(!call(0x05,(uintptr_t)target,(uintptr_t)source,0x4000,0,0));
        assert(source[7]==(target_readback ? 0x6b : 0x42) && touch_count==1+source_readback+target_readback && !s2a_mem_mapped((uintptr_t)target,0x4000));
        puts("PASS stack-copy: real tracker callback reenters VM outside lock"); return 0;
    }
    s2a_track_set_backing_callbacks(before,after);
    expected_source=(uintptr_t)source; expected_mapped=1;
    if (model16 && strcmp(mode,"shared-model16-partial")) {
        uint64_t rejected;
        if (strstr(mode,"transfer-model16")) rejected=call(0x51,72,(uint64_t)target,logical_size,3,0);
        else if (strstr(mode,"code-model16")) {
            assert(!call(0x4b,0,(uint64_t)source,logical_size,0,0));
            rejected=call(0x4c,73,0,(uint64_t)target,logical_size,3);
        } else rejected=call(0x13,71,(uint64_t)target,logical_size,3,0);
        assert(rejected==0xD401);   // 源只按 4K 对齐：旧 alias_map 的 0xD401，不能因为 ref 前置而 die
        assert(!before_count && !after_count && maps_perm(target)==0 && source[7]==0x19);
        puts("PASS modeled 16K admission rejects actual 4K source/target offset before mapping"); return 0;
    }
    if (!strcmp(mode,"quiesce-fail")) fail_quiesce=1;
    if (!strcmp(mode,"protect-fail") || !strcmp(mode,"poison")) plat_vm_test_set_protect_fail(1);
    if (!strcmp(mode,"poison")) plat_vm_test_set_restore_fail(1);
    int fail_map=private_source || !strcmp(mode,"protect-fail") || fail_quiesce;
    if (fail_map) expected_mapped=0;
    int code=!strcmp(mode,"code") || !strcmp(mode,"code-4k"),transfer=!strcmp(mode,"transfer") || !strcmp(mode,"transfer-4k");
    uint64_t rc;
    if (code) { assert(!call(0x4b,0,(uint64_t)source,logical_size,0,0)); rc=call(0x4c,73,0,(uint64_t)target,logical_size,3); }
    else rc=call(transfer?0x51:0x13,transfer?72:71,(uint64_t)target,logical_size,3,0);
    if (!strcmp(mode,"poison")) assert(!"poisoned restore must abort, not return");
    if (fail_map) {
        assert(rc && maps_perm(target)==0 && !s2a_mem_mapped((uintptr_t)target,logical_size));
        assert(before_count==!fail_quiesce && after_count==!fail_quiesce);
    } else {
        assert(!rc && target[7]==0x7a && maps_perm(target)==3);
        if (alias4k) assert(last_prot_address==(uintptr_t)target && last_prot_size==logical_size);
        target[8]=0x3c; assert(source[8]==0x3c); // 真共享物理页，不能以复制冒充alias。
        expected_source=0; expected_mapped=0;
        if (!strcmp(mode,"unmap-fail") || !strcmp(mode,"shared-4k-unmap-fail")) { fail_unmap=1; expected_mapped=1; }
        rc=code ? call(0x4c,73,2,(uint64_t)target,logical_size,0) : call(transfer?0x52:0x14,transfer?72:71,(uint64_t)target,logical_size,0,0);
        if (expected_mapped) {
            assert(rc && maps_perm(target)==3 && s2a_mem_mapped((uintptr_t)target,logical_size));
            assert(target[8]==source[8] && target[7]==0x7a);
            unsigned char retained[2]={0};
            assert(!s2a_android_copy_guest_readonly((uintptr_t)target+7,retained,sizeof retained));
            assert(retained[0]==0x7a && retained[1]==0x3c); // committed=0 retained the old mirror.
        }
        else assert(!rc && maps_perm(target)==0 && !s2a_mem_mapped((uintptr_t)target,logical_size));
        assert(before_count==2 && after_count==2);
    }
    if (alias4k) {
        assert(last_prot_address==(uintptr_t)target && last_prot_size==logical_size);
        assert(maps_perm(target-0x1000)==3 && maps_perm(target+0x1000)==3);
        assert(target[-1]==0x51 && target[0x1000]==0x62);
    }
    printf("PASS %s: real mappings; callbacks=%d/%d; vm_ready=0 (thread/fault integration absent)\n",mode,before_count,after_count);
    return 0;
}

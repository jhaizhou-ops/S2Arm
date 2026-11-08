// 真实 Linux VM 操作。共享算法在 graphics/track/track.c，不能在此另建一套脏页状态机。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../../../../graphics/track/track_platform.h"
#include "../../../../platform/plat.h"
#include "mirror.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdatomic.h>
#include <string.h>
#include <sched.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#if !defined(__linux__)
#error "Android tracking platform requires Linux VM semantics"
#endif

// maps 的前缀有固定字段，路径可任意长。流式丢弃路径，不分配行缓冲。
// 缺页时不读 /proc/self/smaps、不经过 stdio 锁，且保留被中断代码的 errno。
static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
// maps 单次扫描：返回宿主权限（PROT_*，负 errno 失败），shared 非空时回填 1 = 's' 共享映射 / 0 = 'p' 私有。
static int maps_state(uintptr_t address, int *shared) {
    int saved_errno = errno, result = -ENOENT;
    int fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { result = -errno; errno = saved_errno; return result; }
    char buffer[4096];
    uintptr_t start = 0, end = 0;
    unsigned field = 0, digits = 0, permissions = 0;
    int invalid = 0, sh = -1;
    for (;;) {
        ssize_t n = read(fd, buffer, sizeof buffer);
        if (n < 0) { if (errno == EINTR) continue; result = -errno; break; }
        if (!n) break;
        for (ssize_t i = 0; i < n; ++i) {
            unsigned char c = (unsigned char)buffer[i];
            if (c == '\n') {
                if (!invalid && field >= 6 && start <= address && address < end) {
                    result = (int)permissions;
                    if (shared) *shared = sh;
                    goto done;
                }
                start = end = 0; field = digits = permissions = 0; invalid = 0; sh = -1;
                continue;
            }
            if (invalid || field >= 6) continue;
            if (field <= 1) {
                int d = hex_digit(c);
                if (d >= 0) {
                    uintptr_t *v = field ? &end : &start;
                    if (*v > (UINTPTR_MAX - (unsigned)d) / 16) invalid = 1;
                    else { *v = *v * 16 + (unsigned)d; ++digits; }
                } else if (digits && ((!field && c == '-') || (field == 1 && c == ' '))) {
                    ++field; digits = 0;
                } else invalid = 1;
            } else {
                static const char expected[] = "rwx";
                if (field < 5) {
                    if (c == expected[field - 2]) permissions |= 1u << (field - 2);
                    else if (c != '-') invalid = 1;
                } else if (c != 'p' && c != 's') invalid = 1;
                else sh = c == 's';
                ++field;
            }
        }
    }
done:
    close(fd); errno = saved_errno; return result;
}
int s2a_track_platform_protection(uintptr_t address) { return maps_state(address, NULL); }
int s2a_track_platform_prot_shared(uintptr_t address, int *shared) { return maps_state(address, shared); }

// Mirror state is published before guest threads are started and lives for the process.
// Only the VM writer changes mappings and bitmap, with g_mu held and seq odd.
// 生产开关（#1184 / owner #1285）：s2arm.mirror=on|off，缺省关。宿主创建前由 bridge 设一次；
// 首次 mirror_init（不论开关开/关）即冻结，之后 configure 只能同值幂等成功。关时每个钩子入口
// 只判这一位就返回：不建窗口、不映射、不分配、不动世代号。
static _Atomic int mirror_enabled;
static uintptr_t mirror_guest, mirror_address;
static size_t mirror_size, mirror_page;
static int mirror_initialized, mirror_frozen;
static _Atomic unsigned char *mirror_bits;
static _Atomic uint64_t mirror_seq;
static _Atomic uint64_t mirror_retries, mirror_waits, mirror_outside;
static _Atomic uint64_t mirror_hits, mirror_misses, mirror_init_failures;   // ⑪：命中/窗内未命中回退/init 失败计数
static _Atomic long mirror_timeout_us = 10000000;   // 有界等待上限：10 s（写者只持有一个宿主页的拷贝）
// 在途镜像写者（#1184 D1）：写路径 memcpy 前 +1、解别名后 -1。mirror_begin 翻奇数后等它归零再动映射，
// 所以换页与写永不重叠。计数中的写者遇到奇数世代立刻退计数（EAGAIN），由调用方等偶数后重试，
// 不能在这里等——mirror_begin 正等它离开。
static _Atomic unsigned mirror_writers;
static _Thread_local unsigned mirror_writer_depth;
#ifdef S2A_UNIT_TEST
void s2a_android_mirror_test_timeout_us(long us) { if (us > 0) atomic_store_explicit(&mirror_timeout_us, us, memory_order_relaxed); }
uint64_t s2a_android_mirror_test_retries(void) { return atomic_load_explicit(&mirror_retries, memory_order_relaxed); }
uint64_t s2a_android_mirror_test_waits(void) { return atomic_load_explicit(&mirror_waits, memory_order_relaxed); }
int s2a_android_mirror_test_initialized(void) { return mirror_initialized; }
void s2a_android_mirror_test_stats(uint64_t *hits, uint64_t *misses, uint64_t *outside, uint64_t *init_failures) {
    if (hits) *hits = atomic_load_explicit(&mirror_hits, memory_order_relaxed);
    if (misses) *misses = atomic_load_explicit(&mirror_misses, memory_order_relaxed);
    if (outside) *outside = atomic_load_explicit(&mirror_outside, memory_order_relaxed);
    if (init_failures) *init_failures = atomic_load_explicit(&mirror_init_failures, memory_order_relaxed);
}
#endif
#define MIRROR_ALIAS_DEPTH 16
static _Thread_local struct { void *address; size_t size; uint64_t seq; } mirror_aliases[MIRROR_ALIAS_DEPTH];
static _Thread_local unsigned mirror_alias_depth;

static int mirror_on(void) { return atomic_load_explicit(&mirror_enabled, memory_order_acquire); }
int s2a_android_mirror_enabled(void) { return mirror_on(); }
// 开关只在首次 init 前生效一次；与 s2a_android_vk_select 相同，冻结后同值返回 0、不同值返回 EBUSY。
// 关态 init 也要冻结，否则宿主起来后 configure(1) 会让「关时零副作用」的承诺失效。
int s2a_android_mirror_configure(int enabled) {
    if (enabled != 0 && enabled != 1) return EINVAL;
    int value = enabled ? 1 : 0;
    if (mirror_frozen && mirror_on() != value) return EBUSY;
    atomic_store_explicit(&mirror_enabled, value, memory_order_release);
    return 0;
}

void s2a_android_mirror_init(uintptr_t base, size_t size) {
    mirror_frozen = 1;   // 首次 init 即冻结：关时也拒绝宿主起来后再改开关
    if (!mirror_on()) return;   // 关：不 reserve、不 calloc、不 mprotect，mirror_initialized 保持 0
    size_t page = plat_page_size();
    if (mirror_initialized) {
        if (base != mirror_guest || size != mirror_size) { fprintf(stderr,"[mirror] 【红】窗口生命周期变化\n"); abort(); }
        return;
    }
    if (!base || !size || !page || base % page || size % page || size > UINTPTR_MAX-base) {
        atomic_fetch_add_explicit(&mirror_init_failures,1,memory_order_relaxed);
        fprintf(stderr,"[mirror] 【红】guest 窗口参数错误，保留旧别名路径\n"); return;
    }
    mirror_initialized=1; mirror_guest=base; mirror_size=size; mirror_page=page;
    void *reserved = NULL;
    size_t alignment = size >= (1ull << 30) ? (1ull << 30) : page;
    int error = plat_vm_reserve(size, alignment, 1ull << 39, &reserved);
    if (error) {
        atomic_fetch_add_explicit(&mirror_init_failures,1,memory_order_relaxed);
        fprintf(stderr,"[mirror] 【红】第二窗口预留失败 errno=%d，保留旧别名路径\n",error); return;
    }
    size_t pages = size / page;
    _Atomic unsigned char *bits = calloc((pages + 7) / 8, sizeof *bits);
    int init_error = !bits ? ENOMEM : !atomic_is_lock_free(bits) ? ENOTSUP :
                     mprotect(reserved, size, PROT_READ) ? errno : 0;
    if (init_error) {
        int e = init_error; free(bits);
        if (munmap(reserved,size)) { fprintf(stderr,"[mirror] 【红】第二窗口清理失败 errno=%d\n",errno); abort(); }
        atomic_fetch_add_explicit(&mirror_init_failures,1,memory_order_relaxed);
        fprintf(stderr,"[mirror] 【红】第二窗口初始化失败 errno=%d，保留旧别名路径\n",e); return;
    }
    for (size_t i=0;i<(pages+7)/8;i++) atomic_init(&bits[i],0);
    mirror_address=(uintptr_t)reserved; mirror_bits=bits;
    fprintf(stderr,"[mirror] 窗口 guest=%#lx+%zu mirror=%#lx+%zu\n",(unsigned long)base,size,(unsigned long)mirror_address,size);
}
static int mirror_contains(uintptr_t a, size_t n) {
    return mirror_address && n <= mirror_size && a >= mirror_guest && a-mirror_guest <= mirror_size-n;
}
// 事务区间与镜像窗相交才翻世代：无关事务不再让所有在途别名 ESTALE（#1184 复核 ⑧）。
static int mirror_overlaps(uintptr_t base, size_t size) {
    return mirror_address && size && base <= UINTPTR_MAX - size
        && base < mirror_guest + mirror_size && base + size > mirror_guest;
}
static int mirror_valid(uintptr_t a, size_t n) {
    if (!mirror_contains(a,n)) return 0;
    size_t first=(a-mirror_guest)/mirror_page, end=(a-mirror_guest+n+mirror_page-1)/mirror_page;
    for (size_t i=first;i<end;i++) if (!(atomic_load_explicit(&mirror_bits[i/8],memory_order_acquire)&(1u<<(i%8)))) return 0;
    return 1;
}
uint64_t s2a_android_mirror_sequence(void) { return atomic_load_explicit(&mirror_seq,memory_order_acquire); }
void s2a_android_mirror_region(uintptr_t *base, size_t *size) {
    if (base) *base = mirror_address;
    if (size) *size = mirror_address ? mirror_size : 0;
}
void s2a_android_mirror_note_retry(void) { if (mirror_on()) atomic_fetch_add_explicit(&mirror_retries,1,memory_order_relaxed); }
void s2a_android_mirror_note_wait(void) { if (mirror_on()) atomic_fetch_add_explicit(&mirror_waits,1,memory_order_relaxed); }
static uint64_t mirror_now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
void s2a_track_platform_writer_enter(void) {
    if (!mirror_on()) return;   // 关：写路径不进镜像记账，不碰原子计数
    // seq_cst 与 mirror_begin「先翻奇数、再读计数」构成 Dekker 握手：两边至少一方看见对方。
    // 先计入在途写者、再加深线程局部嵌套：两步之间若有信号打断，全局计数已经覆盖本线程，
    // mirror_begin 不会漏看一个已进入写路径的线程（#1184 复验建议）。
    if (!mirror_writer_depth) atomic_fetch_add_explicit(&mirror_writers, 1, memory_order_seq_cst);
    mirror_writer_depth++;
}
void s2a_track_platform_writer_leave(void) {
    if (!mirror_on()) return;   // 与 enter 同一位：关时不配对也不报下溢
    if (!mirror_writer_depth) { fprintf(stderr, "[mirror] 【红】写者计数下溢（leave 不配对）\n"); abort(); }
    if (--mirror_writer_depth == 0) atomic_fetch_sub_explicit(&mirror_writers, 1, memory_order_seq_cst);
}
int s2a_track_platform_wait_stable(void) {
    if (!mirror_on()) return 0;   // 关：没有换页事务，直接放行
    uint64_t start = mirror_now_ns();
    long timeout = atomic_load_explicit(&mirror_timeout_us, memory_order_relaxed);
    while (atomic_load_explicit(&mirror_seq, memory_order_seq_cst) & 1) {
        s2a_android_mirror_note_wait();
        if (mirror_now_ns() - start >= (uint64_t)timeout * 1000ull) {
            fprintf(stderr, "[mirror] 【红】等待换页世代回到偶数超时（%ld ms），拒绝在事务未完成时继续\n", timeout / 1000);
            return ETIMEDOUT;
        }
        sched_yield();
    }
    return 0;
}
#ifdef S2A_UNIT_TEST
static const char *mirror_maps_path="/proc/self/maps", *mirror_limit_path="/proc/sys/vm/max_map_count";
void s2a_android_mirror_test_paths(const char *maps_path, const char *limit_path) { mirror_maps_path=maps_path; mirror_limit_path=limit_path; }
uintptr_t s2a_android_mirror_test_base(void) { return mirror_address; }
#else
static const char *const mirror_maps_path="/proc/self/maps", *const mirror_limit_path="/proc/sys/vm/max_map_count";
#endif
void s2a_android_mirror_report(const char *when) {
    if (!mirror_on()) {   // 关：只报一次开关状态，不读 /proc，不建任何状态
        fprintf(stderr,"[mirror] [%s] 开关关（s2arm.mirror=off）：未建镜像，无映射 / 无分配 / 世代号不变\n",when);
        return;
    }
    FILE *maps=fopen(mirror_maps_path,"r");
    int maps_errno=maps?0:errno;
    FILE *limit=fopen(mirror_limit_path,"r");
    int limit_errno=limit?0:errno;
    unsigned long total=0, guest=0, mirror=0, maximum=0;
    int maps_ok=maps!=NULL, limit_ok=limit && fscanf(limit,"%lu",&maximum)==1;
    if (limit && !limit_ok && !limit_errno) limit_errno=EIO;
    if (limit) fclose(limit);
    if (maps) {
        char *line=NULL; size_t capacity=0;
        while (getline(&line,&capacity,maps)>=0) {
            unsigned long lo,hi;
            if (sscanf(line,"%lx-%lx",&lo,&hi)!=2) { maps_ok=0; maps_errno=EINVAL; break; }
            total++;
            if (mirror_guest && lo<mirror_guest+mirror_size && hi>mirror_guest) guest++;
            if (mirror_address && lo<mirror_address+mirror_size && hi>mirror_address) mirror++;
        }
        if (ferror(maps)) { maps_ok=0; if (!maps_errno) maps_errno=errno?errno:EIO; }
        free(line); fclose(maps);
    }
    fprintf(stderr,"[mirror] [%s] guest=%#lx+%zu mirror=%#lx+%zu hit=%llu miss=%llu retry=%llu odd_wait=%llu outside=%llu init_fail=%llu",
        when,(unsigned long)mirror_guest,mirror_size,(unsigned long)mirror_address,mirror_size,
        (unsigned long long)atomic_load_explicit(&mirror_hits,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&mirror_misses,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&mirror_retries,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&mirror_waits,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&mirror_outside,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&mirror_init_failures,memory_order_relaxed));
    if (maps_ok) {
        fprintf(stderr," VMA guest=%lu mirror=%lu total=%lu",guest,mirror,total);
        if (limit_ok) fprintf(stderr," max=%lu\n",maximum);
        else fprintf(stderr," max=不可读 errno=%d\n",limit_errno);
    } else fprintf(stderr," VMA 不可读 errno=%d\n",maps_errno);
    if (maps_ok && limit_ok && total>maximum) { fprintf(stderr,"[mirror] 【红】VMA 超出 vm.max_map_count\n"); abort(); }
}
void s2a_android_mirror_begin(uintptr_t base, size_t size) {
    if (!mirror_on()) return;   // 关：不翻世代号
    if (!mirror_overlaps(base, size)) return;
    uint64_t old=atomic_fetch_add_explicit(&mirror_seq,1,memory_order_seq_cst);
    if ((old&1) || old>=UINT64_MAX-1) { fprintf(stderr,"[mirror] 【红】世代冲突或耗尽\n"); abort(); }
    // 翻奇数后先等在途写者归零，再让调用方 mremap / 改映射（#1184 D1）。写者先加计数再读世代，
    // 这里先翻奇数再读计数：两边至少一方看见对方；看不见的一方（写者读到偶数）必然已计入，这里就会等它。
    uint64_t start=mirror_now_ns();
    long timeout=atomic_load_explicit(&mirror_timeout_us,memory_order_relaxed);
    while (atomic_load_explicit(&mirror_writers,memory_order_seq_cst)) {
        s2a_android_mirror_note_wait();
        if (mirror_now_ns()-start >= (uint64_t)timeout*1000ull) {
            fprintf(stderr,"[mirror] 【红】换页等待在途写者归零超时（%u 个，%ld ms），拒绝在写者未停稳时改映射\n",
                    atomic_load_explicit(&mirror_writers,memory_order_relaxed),timeout/1000);
            abort();
        }
        sched_yield();
    }
}
void s2a_android_mirror_end(uintptr_t base, size_t size, int mapped, int committed) {
    if (!mirror_on()) return;   // 关：不 mremap / mmap，不翻世代号
    if (!mirror_overlaps(base, size)) return;
    if (committed) {
        uintptr_t lo=base>mirror_guest ? base : mirror_guest;
        uintptr_t hi=base+size<mirror_guest+mirror_size ? base+size : mirror_guest+mirror_size;
        base=lo; size=hi-lo;
        if (base%mirror_page || size%mirror_page) { fprintf(stderr,"[mirror] 【红】替页未对齐\n"); abort(); }
        for (size_t off=0;off<size;off+=mirror_page) {
            uintptr_t source=base+off, dest=mirror_address+(source-mirror_guest);
            size_t bit=(source-mirror_guest)/mirror_page;
            int shared=0;
            if (mapped) {
                // Prepare a readable/writable alias before replacing the live mirror.
                // Source may currently be PROT_NONE due to tracker protections.
                void *staged=mremap((void *)source,0,mirror_page,MREMAP_MAYMOVE);
                if (staged==MAP_FAILED) {
                    if (errno != EINVAL) { fprintf(stderr,"[mirror] 【红】复制共享页失败 errno=%d\n",errno); abort(); }
                } else {
                    if (mprotect(staged,mirror_page,PROT_READ|PROT_WRITE) ||
                        mremap(staged,mirror_page,mirror_page,MREMAP_MAYMOVE|MREMAP_FIXED,(void *)dest)==MAP_FAILED) {
                        fprintf(stderr,"[mirror] 【红】提交共享镜像失败 errno=%d\n",errno); abort();
                    }
                    shared=1;
                }
            }
            if (!shared && mmap((void *)dest,mirror_page,PROT_READ,MAP_FIXED|MAP_PRIVATE|MAP_ANONYMOUS,-1,0)==MAP_FAILED) {
                fprintf(stderr,"[mirror] 【红】安装镜像零页失败 errno=%d\n",errno); abort();
            }
            unsigned char mask=(unsigned char)(1u<<(bit%8));
            if (shared) atomic_fetch_or_explicit(&mirror_bits[bit/8],mask,memory_order_release);
            else atomic_fetch_and_explicit(&mirror_bits[bit/8],(unsigned char)~mask,memory_order_release);
        }
    }
    uint64_t old=atomic_fetch_add_explicit(&mirror_seq,1,memory_order_release);
    if (!(old&1)) { fprintf(stderr,"[mirror] 【红】未配对事务\n"); abort(); }
}

int s2a_track_platform_alias(uintptr_t address, size_t size, int protection, void **out) {
    if (!out) return EINVAL;
    *out = NULL;
    size_t page = plat_page_size();
    if (!page || !size || address % page || size % page || size > UINTPTR_MAX - address
        || (protection != PROT_READ && protection != (PROT_READ | PROT_WRITE))) return EINVAL;
    int on = mirror_on();   // 每个入口只判这一位；关时整段镜像分支不进入
    // #1217 §2.6-② 镜像快路径：mirror_end 提交时对 mapped 页置 mirror_bits、对未映射页清位；
    //   0x2D / 缩堆走 committed=1 的 end，死页的位在事务内清掉，之后 mirror_valid 返回 0，
    //   不会从镜像里拿到已死页。未命中回退的旧别名路只读（或由 tracker 的 lastp 前提挡住写），
    //   死页的 memfd 洞读回零，不会把旧内容当活页。
    if (on && mirror_contains(address,size)) {
        uint64_t seq;
        for (;;) {
            seq=atomic_load_explicit(&mirror_seq,memory_order_seq_cst);
            if (!(seq&1)) break;
            if (mirror_writer_depth) return EAGAIN;   // 计数中的写者立刻退计数；等待会与 mirror_begin 等计数互锁
            int wait=s2a_track_platform_wait_stable();
            if (wait) return wait;
        }
        if (mirror_valid(address,size)) {
            if (mirror_alias_depth == MIRROR_ALIAS_DEPTH) return EOVERFLOW;
            void *p=(void *)(mirror_address+(address-mirror_guest));
            mirror_aliases[mirror_alias_depth++] = (typeof(mirror_aliases[0])){p,size,seq};
            atomic_fetch_add_explicit(&mirror_hits,1,memory_order_relaxed);
            *out=p; return 0;
        }
        atomic_fetch_add_explicit(&mirror_misses,1,memory_order_relaxed);   // 窗内未命中回退旧别名路
    } else if (on && mirror_address) atomic_fetch_add_explicit(&mirror_outside,1,memory_order_relaxed);
    void *alias = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (alias == MAP_FAILED) return errno;
    unsigned perm = PLAT_PROT_READ | (protection & PROT_WRITE ? PLAT_PROT_WRITE : 0);
    // 复用既有真实 mremap(old_size=0) 路径及失败恢复；私有 backing 返回错误。
    int error = plat_vm_alias(alias, (const void *)address, size, perm);
    // EIO means restoration of the destination reservation failed: ownership
    // is no longer established, so neither unmap it nor continue execution.
    if (error == EIO) { fprintf(stderr, "[track] 【红】共享别名保留区失效，拒绝清理或继续\n"); abort(); }
    if (error) { munmap(alias, size); return error; }
    *out = alias;
    return 0;
}
int s2a_track_platform_unalias(void *address, size_t size) {
    if (mirror_on() && mirror_address && (uintptr_t)address >= mirror_address && (uintptr_t)address-mirror_address < mirror_size) {
        if (!mirror_alias_depth) return ENOENT;
        typeof(mirror_aliases[0]) saved=mirror_aliases[--mirror_alias_depth];
        if (saved.address!=address || saved.size!=size) return EINVAL;
        atomic_thread_fence(memory_order_seq_cst);
        return s2a_android_mirror_sequence()==saved.seq ? 0 : ESTALE;
    }
    return munmap(address, size) ? errno : 0;
}
void s2a_track_platform_note_stale(void) { s2a_android_mirror_note_retry(); }
int s2a_track_platform_discard(void *address, size_t size) {
    return madvise(address, size, MADV_DONTNEED) ? errno : 0;
}

// 16 KB 页精确写跟踪（帧率能耗线，graphics/track）：给 Ryujinx MemoryTracking 当「虚拟内存管理器」那一半——Ryujinx 原版靠 CPU 模拟器的访存检查
// 或 4 KB 页保护得到「CPU 写了哪段」，我们游戏直跑在真内存上、宿主页 16 KB，改由本模块用页保护 + 缺页实现，语义按 4 KB 子页对齐原版。
// 设计与逐条对齐表见 graphics/track/设计.md。调用方：
//   C#（服务接入线的 IVirtualMemoryManager 实现）：reprotect / write / write_untracked / drain；
//   原生层：信号处理先调 s2a_track_fault；§4.5 的两个钩子（改游戏页权限后 / 自己写游戏内存前）由 glue.c 启动时登记到 s2a_track_prot_changed / s2a_track_write。
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Ryujinx.Memory.MemoryPermission 原值：TrackingReprotect 的 protection 原样传
enum { S2A_TRACK_NONE = 0, S2A_TRACK_READ = 1, S2A_TRACK_RW = 3 };
// 启动阶段预分配缺页路径资源；必须在放行 guest / 注册托管回调之前调用。
// Apple 仍可沿原来的首次 reprotect 初始化。失败按现有分配失败协议报红终止。
void s2a_track_prepare(void);
// VM 两阶段替页专用：guest/GPU 均停、旧资源已回写并失效后，清除整宿主页旧世代。
// 不读取旧/新页、不更改内核权限；调用者随后建立新跟踪。不能用作普通改权限通知。
void s2a_track_backing_reset(uint64_t addr, uint64_t size);
#if defined(__APPLE__)
// 苹果换页事务（原生层 svc_mem 改表系统调用：先改保护 / 换页、后重算记账）：begin 等在途排空期（drain → drain_done）结束并挡住新的，
//   end（committed）重算这段并放行。范围须整宿主页；同一时刻只一个事务。安卓同名函数在 android/native/runtime/tracking/runtime.c
int s2a_track_backing_begin(uint64_t addr, uint64_t size, uint64_t source);
void s2a_track_backing_end(uint64_t addr, uint64_t size, int mapped, int committed);
#endif
// reprotect 的 perm 可或上这一位：这次「GPU 改过」（NONE）是缓冲登记回写动作时设的（C# 在 Buffer 登记回写动作期间置线程标志）。拦写模拟据此给子页「缓冲担保」；
// 不带这一位的 NONE（贴图、部分回写等）给子页置「污染」，之后永不模拟（docs/研究/拦写模拟.md §4）
#define S2A_TRACK_FROM_BUFFER 0x100

// ---------- C# → 本模块 ----------
// TrackingReprotect(va, size, protection)：按 4 KB 子页记 Ryujinx 的保护意图。
//   RW   = 不跟踪；
//   READ = 跟踪写（CPU 写了就报脏）；
//   NONE = 该子页 GPU 改过、客体内存是旧的（Ryujinx 原版：CPU 读写都先回写）。本模块只拦写：首次写前拍 4 KB 快照，排空时逐字节比出 CPU 真写了哪些字节，
//          按位图报精确写（不触发回写）；CPU 读不拦（已知缺口，见 设计.md「读」一行）。
void s2a_track_reprotect(uint64_t addr, uint64_t size, int perm);
// C# / 宿主即将写游戏内存（Ryujinx IVirtualMemoryManager.Write 等「跟踪写」）：等同 CPU 写——涉及的只读页解开，写到的子页报脏 / 进快照比对。
void s2a_track_write(uint64_t addr, uint64_t size);
#if !defined(__APPLE__)
// 安卓 checked store 提交（s2a_mem_write32_checked，调用方已持 VM g_mu）：tracker 互斥 + drain 门全 trylock，
//   任一拿不到反向放掉已得的回 -EAGAIN。成功时持两锁 + 页占用返回，prior = 被占前页状态（页无跟踪 = 0xff）。
//   -EACCES = 外部记过的保护经内核现态复核不可写。写完后必须同线程调 release 放占（wrote = 别名写是否落地）。
int s2a_track_store32_claim(uint64_t addr, uint8_t *prior);
void s2a_track_store32_release(uint64_t addr, uint8_t prior, int wrote);
#endif
// C# 即将直接写游戏内存但不跟踪（Ryujinx GetWritableRegion(tracked: false)：服务写 IPC 缓冲等）：只解开只读页、报脏，不触发 GPU 改过子页的先回写（原版不跟踪写不发跟踪事件）
void s2a_track_write_quiet(uint64_t addr, uint64_t size);
// [addr, addr+size) 涉及的 4 KB 子页里有没有 Ryujinx 标了 GPU 改过（None 保护）的：1 = 有。只读状态，不改保护、不报事件
//（C# 常量缓冲内联更新据此决定按原版比内容，还是发精确写：GuestMemory.WriteWithRedundancyCheck）
int s2a_track_gpu_modified(uint64_t addr, uint64_t size);
// 定向读时回写：登记这段（按宿主页）——这些页里有 GPU 改过、还没回写的子页时，游戏读也先回写（同 S2A_TRACK_READFLUSH，只对登记页）。非信号路径
void s2a_track_mark_readflush(uint64_t addr, uint64_t size);
// 不跟踪写（WriteUntracked：GPU 数据回写到客体内存、信号量 / 报告值）由本模块代为复制 [src, src+size) → [addr, addr+size)：不报脏；
// 写完的内容当基线，之后 CPU 对同一子页的写排空时照样比得出来（先解开整页、排空前 CPU 再写同一子页不漏）。
// flush = 1（GPU 回写）：CPU 先写过、还没报的字节写完后放回 CPU 的值（原版次序：先回写、再让 CPU 写）；flush = 0（信号量 / 报告值，时间上晚于 CPU 写）：以写入值为准。
void s2a_track_write_untracked(uint64_t addr, const void *src, uint64_t size, int flush);
// 宿主读游戏内存、不经页保护（读时回写设成不可读的页走临时共享别名，不缺页）；正常上下文调。见 track.c
int s2a_track_read_untracked(uint64_t va, void *dst, uint64_t n);
// Precise-drain consumer: on Android always copies via a read-only shared
// alias, even if the guest page is currently readable; its protection can
// change concurrently. Normal context only, never a fault/signal handler.
// Apple: under the tracker lock, pages it knows readable are copied directly,
// all others through a temporary read-only alias; never changes guest protection.
int s2a_track_copy_precise(uint64_t va, void *dst, uint64_t n);
// Restore a merged precise snapshot through a shared writable alias without
// changing the guest mapping's protection.
void s2a_track_restore_precise(uint64_t va, const void *src, uint64_t n);

// 排空（提交前一次，单线程调用）：一次跨界拿走全部变化。数组归本模块，下次 drain 前有效。
// 次序约定：C# 先处理 precise（精确写，不触发回写），再处理 ranges（普通脏区间，可能触发回写）——回写不能早于同批快照比对。
typedef struct { uint64_t addr, size; } s2a_track_range;                 // 已合并的连续脏区间（4 KB 对齐）
typedef struct { uint64_t addr; uint64_t bits[64]; } s2a_track_precise;  // 一个 NONE 子页（4 KB 对齐）+ CPU 改过的字节位图（bit i = 第 i 字节）
typedef struct {
    const s2a_track_precise *precise; uint32_t nprecise;
    const s2a_track_range *ranges; uint32_t nranges;
    int overflow;   // 1 = 脏页环溢出过（计数/报红）；ranges 已完整覆盖全部当前跟踪子页，照常消费（可保守合并成包围区间）
} s2a_track_batch;
void s2a_track_drain(s2a_track_batch *out);

// ---------- 原生层 → 本模块 ----------
// SIGBUS / SIGSEGV 处理里先调（信号上下文安全：只用原子与 mprotect）：返回 1 = 本模块的页，已解保护，重执行即可；0 = 不是本模块的页。
// 注意安卓原生层 on_crash 收到 0 会 _exit(128 + sig)，不是回原信号处理函数。
int s2a_track_fault(void *addr, int is_write);
// 宿主写游戏内存前的外挂通知（双轨直连：原生层 direct_host.c 把直连写跟踪的写前回调接到这里）：s2a_track_write / _quiet / _untracked 进门先调；NULL = 不调。
//   约束：回写回调期间（t_in_touch、渲染线程上的回写）也会经 write_untracked 调到，回调里不许再写游戏内存、不许拿 RegionHandle 的锁，否则重入 / 死锁
void s2a_track_set_write_prep(void (*fn)(uint64_t addr, uint64_t size));
// 累计设成非可读写的宿主页数（双轨：直连模式下本模块不保护任何页，直连局应恒为 0）
uint64_t s2a_track_protected_pages(void);
// 诊断查询（只读、任意线程）：addr 所在宿主页的写跟踪状态。没跟踪过回 UINT64_MAX；否则按字节打包——
//   [0] 页状态（0 可写 / 1 受保护 / 2 改动中） [1] 记账保护（PROT_*，0xfe = 外部改过） [2] GPU 改过的子页位 [3] Ryujinx 要保护的子页位
//   [4] 定向读时回写登记（READFLUSH，1 = 是；全局 READFLUSH 开时也算 1） [5] 待通知的脏子页位（子页 i = 第 i 个 4 KB）
uint64_t s2a_track_page_info(uint64_t addr);
// 游戏代码的写缺页（原生层信号处理在 pc 属游戏模块时调这个）：返回 2 = 页里有 GPU 改过的子页、已登记回写回调，
// 调用方须把线程改道到正常上下文调 s2a_track_touch(addr) 后重执行那条写；其余同 s2a_track_fault
// skip：本线程刚回写过的页内地址（0 = 无），见 track.c
int s2a_track_fault_guest(void *addr, int is_write, uint64_t skip);
// 缺页处模拟读（方案 B）：缺省开（S2A_TRACK_EMUL=0 关），set_emul 供单测切；read_emulable / emul_ok 信号里调（见 track.c），note_emul 计数
void s2a_track_set_emul(int on);
int s2a_track_read_emulable(void *addr);
int s2a_track_emul_ok(uint64_t ea, uint64_t len);
void s2a_track_note_emul(void);
void s2a_track_set_walias(int on);
void s2a_track_note_emul_fail(int cls, uint32_t insn, uint64_t pc);
void s2a_track_touch(uint64_t addr);
// C# 登记：回调 = 对 [addr, addr+size) 发 VirtualMemoryEvent（write 1 写 / 0 读），Ryujinx 当场回写 GPU 数据并改保护
void s2a_track_set_touch(void (*cb)(uint64_t addr, uint64_t size, int write));
// 原生层改了游戏页的可访问性（堆伸缩、Map/Unmap、物理内存映射 …）之后：跟踪中的子页按脏报（内容可能换了）
void s2a_track_prot_changed(uint64_t addr, uint64_t size);
// 客人 SetMemoryPermission（安卓）：mprotect 与跟踪记账在同一临界区，先占页再改内核保护。
// 缺页自愈也先占同一页，所以外部只读不会被并发的自愈改回可写。返回 0；失败返回 errno（占到的页恢复原状态）。
// Apple 的 SetMemoryPermission 仍走原来的 mprotect + s2a_track_prot_changed，行为不变。
int s2a_track_set_guest_protection(uint64_t addr, uint64_t size, int prot);
// 原生层报「这段物理页被换掉」（s2a_track_hooks.backing_changed）：转给 C# 登记的回调（渲染器零拷贝缓冲作废重建）；没登记就不做
void s2a_track_backing_changed(uint64_t addr, uint64_t size);
void s2a_track_set_remap_cb(void (*cb)(uint64_t addr, uint64_t size));

// ---------- 拦写模拟（S2A_TRACK_EMUL_STORE=1，缺省关；docs/研究/拦写模拟.md）----------
// C# → 本模块（非信号路径）：GPU 改过的字节表。set 向外取整到 64 字节（超集，BufferModifiedRangeList 每加一段就调）；
// clear 只清完全落在区间里的 64 字节块（一段修改回写完成、或 Clear 之后调）
void s2a_track_mod_set(uint64_t addr, uint64_t size);
void s2a_track_mod_clear(uint64_t addr, uint64_t size);
// 原生层信号处理里调：store_try 解码前粗筛（缺页地址所在子页 GPU 改过、缓冲担保、没污染）；store_ok 是 s2a_emul_store 的判定回调
// （不碰 GPU 改过字节、不在排空中、位图槽拿得到 → 1 并计入在途）；store_done 写成之后记「CPU 写过」位图、进排空环、在途减一（ns = 本次耗时）；
// note_store_fail：原生层记没模拟的原因（6 别名建不出、7 解码不认 / 越页）
int s2a_track_store_try(void *addr);
int s2a_track_store_ok(uint64_t ea, uint64_t len);
void s2a_track_store_done(uint64_t ea, uint64_t len, uint64_t ns);
void s2a_track_note_store_fail(int why);
// C# 处理完一次排空的精确写之后调：模拟写恢复（排空开始到这里之间的写走老路）
void s2a_track_drain_done(void);
// 单测：开关（须在第一次 reprotect 之前）；计数 out[0] 次数 [1] 字节 [2] 耗时纳秒 [3..10] 没模拟原因 [11] 位图槽峰值
void s2a_track_set_emul_store(int on);
void s2a_track_es_stats(uint64_t out[12]);

// ---------- 计数（健康表 / 判据）----------
typedef struct {
    uint64_t faults, races, heals, preps, ranges, mprotects, watch_hit, watch_miss, rearms;
    uint64_t psnaps, pfull, psame, precise, pbytes, ucw_hit, ucw_inter, restore_bytes, overflows;
    uint64_t rf_flush, rf_hostread;   // READFLUSH：游戏读写不可读页先回写次数、宿主读不可读页放成只读（不回写）次数
    uint64_t snap_peak, snap_chunks, snap_freed;   // 快照池：同时占用的槽数峰值、已映射块数（每块 8192 槽 = 32 MB）、整块空了交还物理页的次数
} s2a_track_stat;
void s2a_track_stats(s2a_track_stat *out);
// 诊断只读查询：addr 所在 4 KB 子页的状态位（1 跟踪中 2 待排空脏 4 观察中 8 GPU 改过；0 = 不在跟踪里），不改状态
int s2a_track_sub_state(uint64_t addr);
// 诊断：READFLUSH（GPU 改过的页读也先回写）开关；缺省按环境变量 S2A_TRACK_READFLUSH=1，单测用这个临时开关
void s2a_track_set_readflush(int on);
// 诊断 / 单测：累计算过内容哈希的字节数（观察中子页的基线与比对）
uint64_t s2a_track_hash_bytes(void);
// Guest, service and GPU threads must be joined before reset; native remaps the guest window afterwards.
int s2a_track_reset_session(void);
void s2a_track_bind_host(void);

#ifdef __cplusplus
}
#endif

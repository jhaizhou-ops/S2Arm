// GAL Metal 后端：第 2 块「缓冲」——建 / 删 / 读写 / 清 / 拷，宿主映射（零拷贝 + 分窗 + 驻留安全阀），以及给绘制块用的编号 → Metal 缓冲 / GPU 地址。
// 语义对照 Ryujinx Vulkan 后端（BufferManager / BufferHolder / PipelineBase.ClearBuffer、CopyBuffer）：
//   SetData / Clear / Copy 一律「按命令顺序生效」：落在已录命令之后、之后命令之前；GetData 只等写过这块缓冲的 GPU 工作做完后读（写在在录命令缓冲里才提交，见 nxgal_buf_get_data）。
// 存储：Apple 芯片统一内存，全部缓冲用 Shared（CPU 可直接读写，GetData 免暂存回拷）；BufferAccess 的 Host / Device 提示在统一内存上不改变放置。
// SetData 两条路：
//   ① 缓冲从没被 GPU 碰过（没交出过 Metal 缓冲 / GPU 地址、也没录过拷贝清除）→ CPU 直接写：此刻没有任何命令引用它，直接写 ≡ 按命令顺序写。
//   ② 否则 → 数据进暂存块，录一条拷贝到当前命令流（gal_blit_enc 负责与前后命令的屏障）。
//   不做 Vulkan 的「不在飞就直接写」：那要知道缓冲最后一次被哪个提交用到，而绘制块会缓存 GPU 地址（参数缓冲按序号复用），
//   用法登记一漏就是 CPU 与 GPU 抢写的无声错；①只依赖「从没交出过」这一条无需登记的事实，永远成立。
#import "gal_internal.h"
#include "gal_pstat.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <stdatomic.h>

// ---------- 缓冲表（照 gal_tex.m：0 = 空，删除走 gal_release_later，编号回收复用）----------
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
// 区间集：[lo, hi) 对按起点有序、互不相交也不相邻（iv 依次存 lo、hi）；tag 变了视为空（换提交 / 换遍清零不必遍历）
typedef struct { uint64_t tag; int n, cap; int32_t *iv; } ivset;
typedef struct {
    void *mtl;              // id<MTLBuffer>（CFBridgingRetain）：普通缓冲 / 小宿主映射整段；分窗宿主映射 = NULL
    uint64_t gpu;           // mtl 的 gpuAddress（建时取一次；Metal 缓冲地址终身不变）：绑定热路径不再每次走 objc 取地址
    void *win;              // 分窗宿主映射的窗口表 NSMutableDictionary（键 = 起点步号 × 8192 + 长度步数）
    int32_t size;
    uint8_t live, touched, host;
    uintptr_t base, end;    // 宿主映射：页对齐后的区间 [base, end)
    uintptr_t abase;        // 宿主映射：[base, end) 的可读写别名（同物理页，见 host_alias）：Metal 缓冲与渲染器自己的 CPU 读写都走它
    uint32_t lead;          // 宿主映射：用户指针 - base
    // 交出过地址的区间（GPU 会读 / 写），本次提交里的（键 = 命令缓冲号，换提交清零）：精确区间集。
    // 原先只记 8 段、超了并成外包：暗黑2 19 MB 流式缓冲每帧上千个偏移，外包成整块后每次写都判「已用」、录进在录流切遍（每帧 211 次），精确判只剩 0–5 次（10-21 帧率能耗线）
    ivset use;
    // 当前渲染遍里用过的区间外包（键 = 遍序号）：帧级调度判能否挪到遍前段用，只会判多、不会判少。原先也按精确区间集记，每次登记多维护一份按遍清零的集合，
    // 塞尔达录像回放 CPU（user + sys）25 秒 vs 不记 20 秒；外包 O(1)
    uint64_t upass; int32_t uplo, uphi;
    // 镜像（同 Ryujinx Vulkan 后端 BufferHolder 的 mirror，按统一内存简化）：
    //   sh = 影子副本（整块逻辑内容）：只在「没有 GPU 写在途」时从 CPU 内容建（此刻 CPU 内容就是真值），之后每次 SetData 同步写它，GPU 一侧可能写它（存储缓冲 / 贴图缓冲 / 拷贝目标）就丢掉；
    //   pend = 写进影子、还没拷回真缓冲的区间（命中本次提交已用区间的写走这里，不录 GPU 命令、不切渲染通道），提交时在命令缓冲末尾拷回；
    //   只读绑定（常量 / 顶点 / 索引）读到 pend 时绑影子的临时拷贝（镜像，本次提交内按区间缓存）
    uint8_t *sh; int npend; int32_t plo[16], phi[16];
    uint64_t wfence;        // GPU 一侧对它的写（拷贝 / 预载 / 存储缓冲 / 贴图缓冲）在哪次提交里：≤ 已完成值才可从 CPU 内容建影子
    // 建影子不必等 CPU 递过去的上传落地（10-19 真机 GPU 是瓶颈、完成值总落后 1–2 帧，按 wfence 建影子从没成立过：三款镜像写全 0，暗黑2 每帧切通道上传 617 次）：
    //   gwfence = GPU 自己产生的写（存储缓冲 / 拷贝目标 / 清除 / 贴图缓冲）在哪次提交；up = 还在途的 CPU 上传（数据在暂存里，所属提交完成前不回收）
    //   gwfence 已完成时，影子 = 当前内存 + 按序叠上在途上传，就是整块逻辑内容；在途上传超过 UP_MAX 条（upov）：碰到溢出区间的读拿不准，溢出那条完成后作废（见 ovlo）
    //   up 按需增长（10-23 画幅线：固定 8 条时巫师3 10 MB 顶点环一个命令缓冲里上传几十次，全屏遍那段四边形顶点落在没记下的几条里，几何判定读不读得到取决于 GPU 完成时机、
    //   同一遍逐帧在外推 / 拉伸间跳）；每次追加先剔掉已完成的，条目数 = 在途上传数，上限 UP_MAX 之后才溢出
    uint64_t gwfence; uint8_t upov; int32_t nup, upcap; struct gup { int32_t off, size; const uint8_t *src; uint64_t cb; } *up;
    // 溢出（超过 UP_MAX 条没记下）的上传：覆盖区间并集 [ovlo, ovhi) 与其中最晚那条所在命令缓冲 ovcb——它完成后溢出作废（upov 清零）；不等它完成时只有碰到这个区间的读才拿不准
    //（10-23 前 upov 置上就只在建影子时清，大于 4 MB 不建影子的流式缓冲一溢出就永远读不到：巫师3 10 MB 顶点环每帧几何判定读不到、全屏遍逐帧在外推 / 拉伸间跳）
    int32_t ovlo, ovhi; uint64_t ovcb;
    int nmir; struct { int32_t lo, hi; uint64_t cb, gpu; } mir[4];
    // 跨度转换缓存（同 Ryujinx Vulkan 后端 BufferHolder.GetAlignedVertexBuffer + _cachedConvertedBuffers）：顶点跨度不是 4 的倍数时的重排结果，
    // 按（偏移, 长度, 跨度）复用；缓冲这段被写就作废（SignalWrite → ClearRange）
    int ncv; struct { int32_t off, size, stride; void *dst; uint64_t gpu; } cv[8];
    uint64_t pgw_cb;        // = gal_cb_id() 时：本次提交里 GPU 对它的写全在预载命令缓冲里（挪进预载的拷贝目标）；在录流里的 GPU 写（buf_gpu_write_use）清零
    uint64_t inl_cb;        // 本次提交里有过录进在录命令流的上传 / 镜像写（内联上传、pend）：这些在在录命令缓冲里，拷贝挪进预载会读到它们之前的值（nxgal_buf_copy）
    // 暂存补丁（没有影子时的镜像，见 nxgal_buf_set_data ③）：命中本次已用区间、又建不了影子（GPU 写在途 / 在途上传超 8 条）的写，
    // 数据留在暂存里、按序记下，不录 GPU 命令；读到补丁的只读绑定由预载拼镜像（真缓冲这段 + 按序叠补丁），提交时 / 非镜像用到前在录流里拷回
    int ngp; struct { int32_t off, size; void *stg; uint64_t so; const uint8_t *src; } gp[8];
    uint32_t wser;          // 最近一次写（上传 / 清 / 拷贝目标 / GPU 可能写）的全局写序号（g_buf_wser）：开遍预整理间接计数后判参数有没有被改过
    // GPU 写按区间作废（缺省开，NXGAL_GW_RANGE=0 应急关；正确性对齐，不是取舍）：在途的 GPU 写只记区间 sx（最多 4 段；sxov = 记不下 / 区间不明），影子只在这些区间里过期，别处照常镜像，
    // 同 Ryujinx Vulkan 后端 BufferHolder 写时 ClearMirrors(offset, size) 只清相交的。10-24 怪猎：768 KB 宿主缓冲里存储缓冲写 [560640, 593920)、常量小写在 [524288, 528384)，
    // 整块作废后每次常量写都录进在录流切遍（每帧约 124 次、附件存回 + 读入 358 MB）。
    // 不变式：pend 与 sx 不相交；CPU 写 / 读碰到 sx 先退影子（sh_retire）；sx 完成后从内存回填影子（sx_settle）
    int nsx; uint8_t sxov; struct { int32_t lo, hi; uint64_t cb; } sx[4];
} gbuf;
static uint32_t g_buf_wser;
uint32_t gal_buf_wser_now(void) { return g_buf_wser; }
static gbuf *g_buf; static uint32_t g_nbuf, g_capbuf;
static uint32_t *g_buf_free; static uint32_t g_nbuf_free, g_cap_free;
// 游戏换页登记（nxgal_host_remapped，游戏线程、不拿锁）：环里放区间、代号 +1；渲染器取用任何缓冲（buf_get，入口锁内）先比代号，变了就排空重建。
// 回调只登记、不等渲染线程、不拿入口锁（原生层线 10-23 审：游戏线程在系统调用里、可能拿着虚拟核与游戏自己的锁，等渲染线程会成环）；
// 每次取用都先核代号，所以作废之后、重建之前不会再用旧缓冲录命令
#define RMQ 64
static struct { _Atomic uint64_t seq; uint64_t a, n; } g_rmq[RMQ];
static _Atomic uint64_t g_rm_head; static uint64_t g_rm_tail;
static void remap_drain(void);
static gbuf *buf_get(uint32_t bid) {
    if (__builtin_expect(atomic_load_explicit(&g_rm_head, memory_order_acquire) != g_rm_tail, 0)) remap_drain();
    return bid && bid < g_nbuf && g_buf[bid].live ? &g_buf[bid] : NULL;
}
#define bid_get buf_get
static uint32_t buf_alloc(void) {   // 0 = 表扩不了（已报红），调用方按建失败返回 0
    if (g_nbuf_free) return g_buf_free[--g_nbuf_free];
    if (!g_nbuf) g_nbuf = 1;
    if (g_nbuf >= g_capbuf) {
        uint32_t nc = g_capbuf ? g_capbuf * 2 : 1024; gbuf *nb = gal_grow(g_buf, nc, sizeof *g_buf, "缓冲表"); if (!nb) return 0;
        g_buf = nb; memset((void *)(g_buf + g_nbuf), 0, (nc - g_nbuf) * sizeof *g_buf); g_capbuf = nc;
    }
    return g_nbuf++;
}
static inline id<MTLBuffer> M(void *p) { return (__bridge id<MTLBuffer>)p; }

// ---------- 暂存块：4 MB 共享缓冲，按「退役时挂的哨兵对象」回收 ----------
// 不用 gal_transient：它只给 CPU 指针与 GPU 地址，Metal 4 的拷贝命令要 MTLBuffer 对象。
// 回收不需要知道栅栏值：块用满退役时 gal_release_later(哨兵)——它挂在「当前在录命令提交后的栅栏」上，≥ 这块此前每次被用到的那次提交；
// 栅栏完成后核心释放哨兵，哨兵 dealloc 把块标回空闲。超过一块大小的单次数据用独立缓冲，直接 gal_release_later。
#define STG_CHUNK (4u << 20)
typedef struct { void *buf; int busy; } stg_chunk;
static stg_chunk *g_stg; static int g_nstg; static int g_stg_cur = -1; static uint32_t g_stg_off;
static uint64_t g_stg_generation;
@interface GalStgSentinel : NSObject { @public int idx; uint64_t generation; } @end
@implementation GalStgSentinel
- (void)dealloc { if (generation == g_stg_generation && idx >= 0 && idx < g_nstg) g_stg[idx].busy = 0; }
@end
// 返回暂存缓冲与偏移，*cpu = 写入处
static id<MTLBuffer> stg_alloc(uint32_t size, uint64_t *off, uint8_t **cpu) {
    if (size > STG_CHUNK) {
        id<MTLBuffer> b = [g_gdev newBufferWithLength:size options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        if (!b) { GLOG("【红】建 %u 字节暂存缓冲失败", size); return nil; }
        gal_res_add(b); gal_release_later(b, 1);   // 本次命令用完即放
        *off = 0; *cpu = b.contents; return b;
    }
    uint32_t o = (g_stg_off + 15) & ~15u;
    if (g_stg_cur < 0 || o + size > STG_CHUNK) {
        if (g_stg_cur >= 0) { GalStgSentinel *s = [GalStgSentinel new]; s->idx = g_stg_cur; s->generation = g_stg_generation; gal_release_later(s, 0); }
        int pick = -1;
        for (int i = 0; i < g_nstg; i++) if (!g_stg[i].busy) { pick = i; break; }
        if (pick < 0) {
            id<MTLBuffer> b = gal_newbuf_test_fail ? nil : [g_gdev newBufferWithLength:STG_CHUNK options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
            // 建不出：当前块上面已挂哨兵退役，不能留作 g_stg_cur（下次小数据会写进已退役块，哨兵放掉后被别处复用而在途命令还在读）；同 gal_transient 置 -1
            if (!b) { GLOG("【红】建暂存块失败（本次上传跳过）：%s", gal_mem_note()); g_stg_cur = -1; g_stg_off = 0; return nil; }
            // 审计 P1-67：块表扩不动（gal_grow 报红、留原表）同建不出块：本次上传跳过，新块随 ARC 放掉（还没进驻留集）
            stg_chunk *ns = gal_grow(g_stg, (size_t)g_nstg + 1, sizeof *g_stg, "暂存块表"); if (!ns) { g_stg_cur = -1; g_stg_off = 0; return nil; }
            g_stg = ns; gal_res_add(b);
            g_stg[g_nstg] = (stg_chunk){(void *)CFBridgingRetain(b), 0}; pick = g_nstg++;
        }
        g_stg[pick].busy = 1; g_stg_cur = pick; o = 0;
    }
    g_stg_off = o + size;
    id<MTLBuffer> b = M(g_stg[g_stg_cur].buf);
    *off = o; *cpu = (uint8_t *)b.contents + o; return b;
}

static uint64_t g_wins, g_win_bytes;   // 宿主映射分窗（见 host_win）
// 地址账（诊断，原生层低区全列时经 dlsym 调）：GAL 缓冲（共享）个数 / 字节、暂存块、影子
void gal_buf_va_note(char *o, size_t n) {
    uint64_t nb = 0, bb = 0, nh = 0, shb = 0, big = 0, ab = 0; for (uint32_t i = 1; i < g_nbuf; i++) if (g_buf[i].live) { if (g_buf[i].host) { nh++; if (g_buf[i].abase) ab += g_buf[i].end - g_buf[i].base; } else { nb++; bb += (uint64_t)g_buf[i].size; if (g_buf[i].size >= (1 << 20)) big += (uint64_t)g_buf[i].size; } if (g_buf[i].sh) shb += (uint64_t)g_buf[i].size; }
    char ul[256]; gal_upload_va_note(ul, sizeof ul);
    snprintf(o, n, "GAL 缓冲 %llu 个 %llu MB（≥1 MB 的合计 %llu MB）、宿主映射 %llu 个（别名占地址 %llu MB、已建窗口 %llu 个 %llu MB）；暂存块 %d 个 %u MB；影子 %llu MB；%s", (unsigned long long)nb, (unsigned long long)(bb >> 20), (unsigned long long)(big >> 20), (unsigned long long)nh, (unsigned long long)(ab >> 20), (unsigned long long)g_wins, (unsigned long long)(g_win_bytes >> 20), g_nstg, (unsigned)(g_nstg * (STG_CHUNK >> 20)), (unsigned long long)(shb >> 20), ul);
}

// ---------- 驻留安全阀（照 ins/main sw/gfx/nvn/nvn_mtl.m res_valve_ok，10-18 内核恐慌）----------
// 零拷贝缓冲一进驻留集，整段页钉成 wired，撤出驻留集也不放、到进程退出才放。再驻留 n 字节会让本进程驻留集超 NX_RES_CAP_GB（缺省 6），
// 或整机 wired 已超物理内存 45%，就报红拒绝——取址失败，调用方按无效缓冲丢掉这次命令，不硬塞把整机钉死。上限每次读环境变量（单测可临时调）。
static uint64_t g_res_refused;
static int res_valve_ok(uint64_t n) {
    const char *e = getenv("NX_RES_CAP_GB");
    uint64_t cap = e && atof(e) > 0 ? (uint64_t)(atof(e) * (1ull << 30)) : 6ull << 30;
    static uint64_t phys; if (!phys) { size_t l = sizeof phys; sysctlbyname("hw.memsize", &phys, &l, NULL, 0); }
    uint64_t have = g_gres.allocatedSize, wired = 0;
    vm_statistics64_data_t v; mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&v, &c) == KERN_SUCCESS) wired = (uint64_t)v.wire_count * vm_kernel_page_size;
    if (have + n <= cap && (!phys || wired <= phys / 100 * 45)) return 1;
    g_res_refused++;
    if (g_res_refused <= 4 || !(g_res_refused & (g_res_refused - 1)))
        GLOG("【红】驻留安全阀：拒绝新增驻留 %.1f MB（本进程驻留集 %.1f MB / 上限 %.1f MB；整机 wired %.1f GB / 物理内存 %.1f GB 的 45%%）——这次取址失败，累计拒绝 %llu 次",
             n / 1048576.0, have / 1048576.0, cap / 1048576.0, wired / 1073741824.0, phys / 1073741824.0, (unsigned long long)g_res_refused);
    return 0;
}

// ---------- 宿主映射分窗（照 nvn_mtl.m pool_win）----------
// 大于 WIN_LEN 的宿主映射不建整段缓冲：按 GPU 实际取址的区段懒建零拷贝窗口。窗口长 WIN_LEN、起点按 WIN_STEP 步进（相邻重叠一半），
// 长度 ≤ WIN_STEP 的区间总能整个落进它起点所在步的窗口；更长的建一个按步长取整、恰好覆盖它的窗口。窗口建成不替换（地址可能已被记下），删缓冲时随之延后释放。
#define WIN_STEP (2ull << 20)
#define WIN_LEN  (4ull << 20)
static id<MTLBuffer> host_win(gbuf *b, uint64_t rel, uint64_t len, uint64_t *woff) {
    NSMutableDictionary *d = (__bridge NSMutableDictionary *)b->win;
    uint64_t s0 = rel / WIN_STEP * WIN_STEP, n = WIN_LEN;
    if (rel + len > s0 + WIN_LEN) n = (rel + len - s0 + WIN_STEP - 1) / WIN_STEP * WIN_STEP;
    if (b->base + s0 + n > b->end) n = b->end - b->base - s0;
    NSNumber *k = @(s0 / WIN_STEP * 8192 + (n + WIN_STEP - 1) / WIN_STEP);
    id<MTLBuffer> w = d[k];
    if (!w) {
        if (!res_valve_ok(n)) return nil;
        w = [g_gdev newBufferWithBytesNoCopy:(void *)(b->abase + s0) length:n options:MTLResourceStorageModeShared deallocator:nil];
        if (!w) { GLOG("【红】宿主映射 %p 窗口 +%#llx 长 %#llx 建零拷贝缓冲失败", (void *)b->base, (unsigned long long)s0, (unsigned long long)n); return nil; }
        d[k] = w; gal_res_add(w); g_wins++; g_win_bytes += n;
        if (g_wins <= 2 || !(g_wins & (g_wins - 1))) GLOG("宿主映射分窗：已建窗口 %llu 个共 %.1f MB", (unsigned long long)g_wins, g_win_bytes / 1048576.0);
    }
    *woff = rel - s0; return w;
}

// ---------- 本次提交已用区间 ----------
extern uint32_t g_entry_dirty;
// 第一个终点 ≥ x 的区间下标（区间有序且互不相交，终点随下标递增）；都 < x 返回 n
static int iv_find(const ivset *v, int32_t x) {
    int l = 0, r = v->n;
    while (l < r) { int m = (l + r) / 2; if (v->iv[2 * m + 1] < x) l = m + 1; else r = m; }
    return l;
}
static void iv_add(ivset *v, uint64_t tag, int32_t lo, int32_t hi) {
    if (v->tag != tag) { v->tag = tag; v->n = 0; }
    if (hi <= lo) return;
    // 与 [lo, hi) 相交或相邻的是 [i, j)：并成一段
    int i = iv_find(v, lo), j = i;
    // 已被一段整段盖住（同一缓冲同一段每次绘制重复绑定）：什么都不用改，免得走下面的挪动（10-23 原生层线：Mac 塞尔达回放 use_add 占绘制路径约 12%）
    if (i < v->n && v->iv[2 * i] <= lo && v->iv[2 * i + 1] >= hi && gal_draw_fixed()) return;
    while (j < v->n && v->iv[2 * j] <= hi) j++;
    if (i < j) { if (v->iv[2 * i] < lo) lo = v->iv[2 * i]; if (v->iv[2 * (j - 1) + 1] > hi) hi = v->iv[2 * (j - 1) + 1]; }
    int n = v->n - (j - i) + 1;
    if (n > v->cap) { v->cap = v->cap ? v->cap * 2 : 16; if (v->cap < n) v->cap = n; v->iv = realloc(v->iv, (size_t)v->cap * 2 * sizeof *v->iv); }
    memmove(v->iv + 2 * (i + 1), v->iv + 2 * j, (size_t)(v->n - j) * 2 * sizeof *v->iv);
    v->iv[2 * i] = lo; v->iv[2 * i + 1] = hi; v->n = n;
}
static int iv_hit(const ivset *v, uint64_t tag, int32_t lo, int32_t hi) {
    if (v->tag != tag || hi <= lo) return 0;
    int i = iv_find(v, lo + 1);   // 第一个终点 > lo 的区间
    return i < v->n && v->iv[2 * i] < hi;
}
static void use_add(gbuf *b, int32_t lo, int32_t hi) {
    g_entry_dirty = 1;
    iv_add(&b->use, gal_cb_id(), lo, hi);
    if (!g_buf_prepass_bind && hi > lo) { uint64_t ps = gal_pass_serial(); if (b->upass != ps) { b->upass = ps; b->uplo = lo; b->uphi = hi; } else { if (lo < b->uplo) b->uplo = lo; if (hi > b->uphi) b->uphi = hi; } }
}
static int use_hit(const gbuf *b, int32_t lo, int32_t hi) { return iv_hit(&b->use, gal_cb_id(), lo, hi); }

// ---------- 跨度转换缓存 ----------
static void cv_clear(gbuf *b, int32_t lo, int32_t hi) {
    for (int i = 0; i < b->ncv; i++) if (lo < b->cv[i].off + b->cv[i].size && b->cv[i].off < hi) {
        gal_release_later((__bridge_transfer id)b->cv[i].dst, 1);
        b->cv[i] = b->cv[--b->ncv]; i--;
    }
}
// 取（偏移, 长度, 跨度）的重排结果地址；*fresh = 1 表示刚建、调用方要派发转换（src 由 gal_buf_read_gpu 取）
uint64_t gal_buf_restride(uint32_t bid, int32_t off, int32_t size, int32_t stride, uint32_t out_len, int *fresh) {
    gbuf *b = buf_get(bid); *fresh = 0; if (!b) return 0;
    for (int i = 0; i < b->ncv; i++) if (b->cv[i].off == off && b->cv[i].size == size && b->cv[i].stride == stride) return b->cv[i].gpu;
    id<MTLBuffer> d = gal_newbuf_test_fail ? nil : [g_gdev newBufferWithLength:out_len ? out_len : 4 options:MTLResourceStorageModePrivate];
    if (!d) { GLOG("【红】建 %u 字节重排缓存失败（顶点：本次绘制跳过；索引：走一次性转换）：%s", out_len, gal_mem_note()); return 0; }
    gal_res_add(d);
    if (b->ncv == 8) cv_clear(b, b->cv[0].off, b->cv[0].off + 1);
    b->cv[b->ncv].off = off; b->cv[b->ncv].size = size; b->cv[b->ncv].stride = stride; b->cv[b->ncv].dst = (void *)CFBridgingRetain(d); b->cv[b->ncv].gpu = d.gpuAddress; b->ncv++;
    *fresh = 1; return d.gpuAddress;
}
// 作废与（偏移, 长度）相交的重排缓存：gal_buf_restride 刚建（fresh）而调用方没派发成转换时用，免得下次当成已转好的；
// 绘制 / 派发可能写这段时也用（gal_draw.m preflush_nonmirror）
void gal_buf_restride_drop(uint32_t bid, int32_t off, int32_t size) { gbuf *b = buf_get(bid); if (b) cv_clear(b, off, off + (size > 0 ? size : 1)); }

// ---------- 镜像 ----------
static uint8_t *cpu_ptr(gbuf *b, int32_t offset);
static id<MTLBuffer> buf_mtl(gbuf *b, int32_t offset, int32_t len, uint64_t *mtl_offset);
static id<MTLBuffer> stg_alloc(uint32_t size, uint64_t *off, uint8_t **cpu);
static uint32_t *g_pend_ids; static int g_npend_ids, g_cap_pend_ids;   // 有 pend 的缓冲（提交时拷回）
static void pend_flush(gbuf *b);
static int sx_hit(gbuf *b, int32_t lo, int32_t hi);
static int pend_hit(const gbuf *b, int32_t lo, int32_t hi) { for (int i = 0; i < b->npend; i++) if (lo < b->phi[i] && b->plo[i] < hi) return 1; return 0; }
static void pend_add(uint32_t bid, gbuf *b, int32_t lo, int32_t hi) {
    b->inl_cb = gal_cb_id();
    if (!b->npend) { if (g_npend_ids == g_cap_pend_ids) { g_cap_pend_ids = g_cap_pend_ids ? g_cap_pend_ids * 2 : 64; g_pend_ids = realloc(g_pend_ids, g_cap_pend_ids * sizeof *g_pend_ids); } g_pend_ids[g_npend_ids++] = bid; }
    for (int i = 0; i < b->npend; i++) if (lo <= b->phi[i] && b->plo[i] <= hi) {   // 相交或相邻：并进去（影子是整块真值，并出来的外包也对）
        if (lo < b->plo[i]) b->plo[i] = lo;
        if (hi > b->phi[i]) b->phi[i] = hi;
        return;
    }
    if (b->npend < 16) { b->plo[b->npend] = lo; b->phi[b->npend] = hi; b->npend++; return; }
    if (b->nsx) {   // 并成外包可能盖住 sx（影子在那里是旧的，拷回会盖掉 GPU 写）：先拷回；没拷成的段留在 pend 里，新段接在后面
        pend_flush(b);
        if (b->npend < 16) { b->plo[b->npend] = lo; b->phi[b->npend] = hi; b->npend++; return; }
        GRED_ONCE("缓冲镜像：16 段待拷回全部拷不回（暂存块建不出），只能并成外包，可能盖住 GPU 写在途段");
    }
    for (int i = 1; i < 16; i++) { if (b->plo[i] < b->plo[0]) b->plo[0] = b->plo[i]; if (b->phi[i] > b->phi[0]) b->phi[0] = b->phi[i]; }
    if (lo < b->plo[0]) b->plo[0] = lo;
    if (hi > b->phi[0]) b->phi[0] = hi;
    b->npend = 1;
}
// 拷回录进哪个编码器：缺省在录命令流（gal_blit_enc，遍开着会切遍）；遍内派发挪到遍前段时一并录进遍前段（g_flush_enc，见 gal_buf_prepass_flush）
// 每条拷贝都重新取编码器：取一次就和前一条之间加一道屏障（暂存补丁可能按序覆盖同一段）
static int g_flush_pre;
static id flush_enc(void) { return g_flush_pre ? gal_prepass_enc() : gal_blit_enc(); }
// 把 pend 拷回真缓冲：录进在录命令流（gal_blit_enc；调用方保证此刻不在渲染编码器的绑定阶段中途）
// 暂存块建不出（stg_alloc 返回 nil）的段留在 pend 里（审计 #846 F-pend-flush-drop）：影子还在，读这段的只读绑定照旧走镜像，
//   下次提交 / 非镜像用到前再拷；全部拷完才清表、把绑定从镜像改回真缓冲。pend 只在有影子的缓冲上（不是宿主映射），buf_mtl 恒有整段缓冲
static void pend_flush(gbuf *b) {
    if (!b->npend) return;
    int k = 0;
    @autoreleasepool {
        for (int i = 0; i < b->npend; i++) {
            uint32_t n = (uint32_t)(b->phi[i] - b->plo[i]);
            uint64_t so; uint8_t *p; id<MTLBuffer> s = stg_alloc(n, &so, &p);
            if (!s) { b->plo[k] = b->plo[i]; b->phi[k] = b->phi[i]; k++; continue; }
            memcpy(p, b->sh + b->plo[i], n);
            uint64_t doff; id<MTLBuffer> d = buf_mtl(b, b->plo[i], (int32_t)n, &doff);
            [flush_enc() copyFromBuffer:s sourceOffset:so toBuffer:d destinationOffset:doff size:n];
        }
    }
    b->wfence = gal_cb_id();
    if (k) { b->npend = k; GRED_ONCE("缓冲镜像拷回：暂存块建不出，%d 段待拷回留到下次（读这几段仍走镜像）", k); return; }
    b->npend = 0; b->nmir = 0;
    g_obj_gen++; gal_draw_rebind_buffers();   // 绑定从镜像回到真缓冲
}
// 影子要丢（GPU 可能写 / 退影子）而 pend 还有没拷成的段：数据源随影子没了，这几段只能丢——响亮报红（GPU 读到这几段写前的字节）
static void pend_lost(gbuf *b) {
    if (!b->npend) return;
    GLOG("【红】缓冲镜像：%d 段待拷回拷不回（暂存块建不出），影子要丢，这几段的 CPU 写丢失", b->npend);
    b->npend = 0; b->nmir = 0;
    g_obj_gen++; gal_draw_rebind_buffers();
}
static int gp_hit(const gbuf *b, int32_t lo, int32_t hi) { for (int i = 0; i < b->ngp; i++) if (lo < b->gp[i].off + b->gp[i].size && b->gp[i].off < hi) return 1; return 0; }
#define UP_MAX 4096
static void up_add(gbuf *b, int32_t off, int32_t size, const uint8_t *src);
// 暂存补丁按序拷回真缓冲：录进在录命令流（同 pend_flush）。拷回后它们就是普通的在途上传（记 up，供以后建影子）
static void gp_flush(gbuf *b) {
    if (!b->ngp) return;
    for (int i = 0; i < b->ngp; i++) {
        uint64_t doff; id<MTLBuffer> d = buf_mtl(b, b->gp[i].off, b->gp[i].size, &doff); if (!d) continue;
        [flush_enc() copyFromBuffer:(__bridge id<MTLBuffer>)b->gp[i].stg sourceOffset:b->gp[i].so toBuffer:d destinationOffset:doff size:(NSUInteger)b->gp[i].size];
        up_add(b, b->gp[i].off, b->gp[i].size, b->gp[i].src);
    }
    b->ngp = 0; b->nmir = 0; b->wfence = gal_cb_id(); b->inl_cb = gal_cb_id();
    g_obj_gen++; gal_draw_rebind_buffers();
}
// 预载命令缓冲里读这段（gal_buf_read_gpu 给的地址）与此刻在录流里读到的内容相同：读的是镜像（影子的临时拷贝，CPU 已写好）；
// 或读真缓冲，且本次提交的在录流里没有对它的 GPU 写（gwfence，写全在预载里的不算）、没有录进在录流的上传 / 镜像写（inl_cb）——
// 于是此刻内容 = 之前提交 + 预载里已排的上传。口径同 nxgal_buf_copy 挪进预载的源条件
int gal_buf_preload_readable(uint32_t bid, int32_t offset, int32_t len) {
    gbuf *b = buf_get(bid); if (!b) return 0;
    int32_t hi = len > 0 ? offset + len : b->size; if (hi > b->size) hi = b->size;
    if (b->npend && b->sh && pend_hit(b, offset, hi) && !(b->nsx && sx_hit(b, offset, hi))) return 1;
    if (b->ngp && gp_hit(b, offset, hi)) return 1;
    uint64_t cur = gal_cb_id();
    return !(b->gwfence == cur && b->pgw_cb != cur) && b->inl_cb != cur && !b->npend;
}
// 本命令缓冲的在录流里有 GPU 写过这个缓冲（诊断：间接计数整理没挪进预载的原因）
uint32_t gal_buf_wser(uint32_t bid) { gbuf *b = buf_get(bid); return b ? b->wser : UINT32_MAX; }
int gal_buf_gpu_written(uint32_t bid) { gbuf *b = buf_get(bid); uint64_t cur = gal_cb_id(); return b && b->gwfence == cur && b->pgw_cb != cur; }
static void sh_drop(gbuf *b) { free(b->sh); b->sh = NULL; b->nmir = 0; }
// 单测（tests/t_gwrange.m）：≥ 0 时代替环境变量（同一进程里比开 / 关）
int gal_gwr_test = -1;
static int gwr_on(void) { if (gal_gwr_test >= 0) return gal_gwr_test; static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_GW_RANGE"); v = !(e && *e == '0'); } return v; }
static uint64_t up_done(void);
// 已完成的在途 GPU 写：有影子时从内存回填这段（此刻内存就是写的结果：CPU 写碰到 sx 早已退了影子，在途上传按 sx_add 时取晚的提交号），然后删掉
static void sx_settle(gbuf *b) {
    if (!b->nsx) return;
    uint64_t done = up_done(); int k = 0;
    for (int i = 0; i < b->nsx; i++) {
        if (b->sx[i].cb > done) { b->sx[k++] = b->sx[i]; continue; }
        if (b->sh) memcpy(b->sh + b->sx[i].lo, cpu_ptr(b, b->sx[i].lo), (size_t)(b->sx[i].hi - b->sx[i].lo));
    }
    b->nsx = k;
}
static int sx_hit(gbuf *b, int32_t lo, int32_t hi) { sx_settle(b); for (int i = 0; i < b->nsx; i++) if (lo < b->sx[i].hi && b->sx[i].lo < hi) return 1; return 0; }
// 记一段在途 GPU 写（与已有段相交 / 相邻就并，提交号取新的）；记不下返回 0
static int sx_add(gbuf *b, int32_t lo, int32_t hi, uint64_t cb) {
    sx_settle(b);
    for (int i = 0; i < b->nsx; i++) if (lo <= b->sx[i].hi && b->sx[i].lo <= hi) {
        if (lo < b->sx[i].lo) b->sx[i].lo = lo;
        if (hi > b->sx[i].hi) b->sx[i].hi = hi;
        b->sx[i].cb = cb; return 1;
    }
    if (b->nsx == 4) return 0;
    b->sx[b->nsx].lo = lo; b->sx[b->nsx].hi = hi; b->sx[b->nsx].cb = cb; b->nsx++; return 1;
}
// 提交前：全部 pend 拷回（命令缓冲末尾，渲染通道已结束，不额外切）。拷回的数据与影子相同，影子保留
// 没拷成的（见 pend_flush）留在表里，下次提交再拷
void gal_buf_commit_flush(void) {
    int n = 0;
    for (int k = 0; k < g_npend_ids; k++) { gbuf *b = bid_get(g_pend_ids[k]); if (b) { pend_flush(b); gp_flush(b); if (b->npend || b->ngp) g_pend_ids[n++] = g_pend_ids[k]; } }
    g_npend_ids = n;
}
// 非镜像用法（GPU 可能写）：先拷回 pend，丢影子，记 GPU 写在途。keep_up：区间作废时留着在途上传（之后 GPU 写还在途就建影子，要按序叠上它们）
static void gw_whole(gbuf *b, int keep_up) {
    b->wser = ++g_buf_wser;
    if (b->ncv) cv_clear(b, 0, b->size);   // GPU 可能写：转换结果全作废
    if (b->npend) { pend_flush(b); pend_lost(b); }
    if (b->ngp) gp_flush(b);
    if (b->sh) sh_drop(b);
    b->wfence = gal_cb_id(); b->gwfence = gal_cb_id(); b->pgw_cb = 0;
    if (!keep_up) { b->nup = 0; b->upov = 0; }   // GPU 自写：此前的在途上传都在它之前，等它完成时一并完成
}
// 区间不明的 GPU 写：整块作废，影子要等这次写做完才能重建
static void buf_gpu_write_use(gbuf *b) { gw_whole(b, 0); b->sxov = 1; b->nsx = 0; }
// GPU 写 [lo, hi)：区间作废开着、有影子、不碰 pend 时只记这段过期（不切遍、影子留着），否则整块作废，开着时仍记下区间供重建影子
static void buf_gpu_write_rng(gbuf *b, int32_t lo, int32_t hi) {
    if (!gwr_on() || lo >= hi) { buf_gpu_write_use(b); return; }
    uint64_t cur = gal_cb_id();
    if (b->sh && !b->sxov && !(b->npend && pend_hit(b, lo, hi)) && sx_add(b, lo, hi, cur)) {
        b->wser = ++g_buf_wser;
        if (b->ncv) cv_clear(b, lo, hi);
        for (int i = 0; i < b->nmir; i++) if (lo < b->mir[i].hi && b->mir[i].lo < hi) { b->mir[i] = b->mir[--b->nmir]; i--; }
        b->wfence = cur; b->gwfence = cur; b->pgw_cb = 0;
        return;
    }
    gw_whole(b, 1);
    if (b->sxov || !sx_add(b, lo, hi, cur)) { b->sxov = 1; b->nsx = 0; b->nup = 0; b->upov = 0; }
}
// 退影子（读 / 写碰到过期区间）：pend 拷回（录进在录流）、影子丢掉；此前影子期间的上传没记在途表，按整块写在途处理，等它们做完才重建
static void sh_retire(gbuf *b) { if (b->npend) { pend_flush(b); pend_lost(b); } sh_drop(b); b->wfence = gal_cb_id(); b->gwfence = gal_cb_id(); b->pgw_cb = 0; b->sxov = 1; b->nsx = 0; b->nup = 0; b->upov = 0; }
void gal_buf_preflush(uint32_t bid) { gbuf *b = bid_get(bid); if (b && (b->npend || b->sh || b->ngp)) buf_gpu_write_use(b); }
// 本次绘制 / 派发会写它（可写存储缓冲、图像缓冲挂的缓冲；开编码器前调）：照 buf_gpu_write_use 记在录流 GPU 写。参数集照用时不再经取址登记，
// 这里补上——之后的重排 / 拷贝按 gwfence 判「预载里读到的与此刻相同」（gal_buf_preload_readable）时不会把这次写漏掉
void gal_buf_gpu_write(uint32_t bid, int32_t offset, int32_t len) {
    gbuf *b = bid_get(bid); if (!b) return;
    b->touched = 1;
    int32_t hi = len > 0 ? offset + len : b->size; if (offset < 0) offset = 0; if (hi > b->size) hi = b->size;
    buf_gpu_write_rng(b, offset, hi);
}
// 本次绘制 / 派发经贴图缓冲（缓冲上建的贴图视图）读 / 写这段：登记本次提交已用区间。贴图缓冲跨提交长期存在、不经取址，
// 不登记的话之后对这段的写会判「没人用过」进预载，排到这次读之前（10-21 精确已用区间后补上；8 段外包时代碰巧被外包盖住）
void gal_buf_note_use(uint32_t bid, int32_t offset, int32_t len) { gbuf *b = bid_get(bid); if (b) { b->touched = 1; use_add(b, offset, len > 0 ? offset + len : b->size); } }
// 遍内操作挪到遍前段（gal_draw.m 派发）对这个缓冲的要求：没有待拷回的镜像数据 / 暂存补丁（挪前要先拷回，拷回录在在录流会切遍）；
// 要写的区间本遍里没被用过（遍前段排在本遍之前、更早各遍之后：本遍里更早的读写会被它越过，更早各遍不会）
// 遍内派发挪到遍前段时，它用到的缓冲若有待拷回镜像 / 暂存补丁，拷回一并录进遍前段（不在录流里切遍）：
// 拷回写的是此刻的逻辑内容，提前到本遍之前写真缓冲；前提（gal_buf_prepass_ok 判）是待拷回的区间本遍没人用过——
// 本遍里在上传之前的绘制读的是真缓冲，提前写会被它们读到；更早各遍排在遍前段之前，不受影响
void gal_buf_prepass_flush(uint32_t bid) {
    gbuf *b = bid_get(bid); if (!b || !(b->npend || b->ngp)) return;
    g_flush_pre = 1; pend_flush(b); gp_flush(b); g_flush_pre = 0;
}
// 挪到遍前段的命令绑定期间：用法只登记本次提交（use），不登记本遍（puse）——遍前段排在本遍之前，不算本遍的读写
int g_buf_prepass_bind;
// 遍内写缓冲（上传最后一层 / 填充）能否录进遍前段（帧级调度）：渲染遍开着、要写的区间本遍没用过、待拷回镜像的区间本遍也没用过
// （拷回一并录进遍前段）。能就返回遍前编码器（遍前段没开记「想要」、返回 nil，调用方照旧录进在录流）
uint64_t g_bufw_pre;   // 写缓冲进遍前段的次数（单测 / 诊断）
static int pass_hit(const gbuf *b, int32_t lo, int32_t hi);
static id pre_write_enc(uint32_t bid, gbuf *b, int32_t lo, int32_t hi) {
    int k; gal_cur_enc(&k); if (k != 1 || pass_hit(b, lo, hi)) return nil;
    for (int i = 0; i < b->npend; i++) if (pass_hit(b, b->plo[i], b->phi[i])) return nil;
    for (int i = 0; i < b->ngp; i++) if (pass_hit(b, b->gp[i].off, b->gp[i].off + b->gp[i].size)) return nil;
    gal_prepass_want();
    if (!gal_prepass_enc()) return nil;
    gal_buf_prepass_flush(bid);
    g_bufw_pre++;
    return gal_prepass_enc();   // 再取一次：与拷回之间加屏障
}
// write：这次会写；flush：这次用法读不到镜像（会写、或经贴图缓冲读），要先把待拷回镜像 / 暂存补丁拷回真缓冲。
static int pass_hit(const gbuf *b, int32_t lo, int32_t hi) { return b->upass == gal_pass_serial() && lo < b->uphi && b->uplo < hi; }
// 返回 0 = 能挪；1 = 能挪，但要先拷回（gal_buf_prepass_flush）；2 = 不能挪：要写的区间本遍已用，或要拷回的区间本遍已用
int gal_buf_prepass_ok(uint32_t bid, int32_t offset, int32_t len, int write, int flush) {
    gbuf *b = bid_get(bid); if (!b) return 0;
    if (write && pass_hit(b, offset, len > 0 ? offset + len : b->size)) return 2;
    if (!flush || !(b->npend || b->ngp)) return 0;
    for (int i = 0; i < b->npend; i++) if (pass_hit(b, b->plo[i], b->phi[i])) return 2;
    for (int i = 0; i < b->ngp; i++) if (pass_hit(b, b->gp[i].off, b->gp[i].off + b->gp[i].size)) return 2;
    return 1;
}

// ---------- 块间内部接口 ----------
static id<MTLBuffer> buf_mtl(gbuf *b, int32_t offset, int32_t len, uint64_t *mtl_offset) {
    if (b->mtl) { *mtl_offset = (uint64_t)b->lead + (uint64_t)offset; return M(b->mtl); }
    uint64_t n = len > 0 ? (uint64_t)len : (offset < b->size ? (uint64_t)(b->size - offset) : 1);
    return host_win(b, (uint64_t)b->lead + (uint64_t)offset, n, mtl_offset);
}
// 交出地址 = 本次提交的命令会读 / 写这段：记进已用区间（之后对它的写不能走预载）
static gbuf *buf_use_rw(uint32_t bid, int32_t offset, int32_t len) {   // 读写用法的登记（已用区间 + GPU 可能写）
    gbuf *b = buf_get(bid); if (!b) return NULL;
    b->touched = 1;
    int32_t hi = len > 0 ? offset + len : b->size; if (hi > b->size) hi = b->size;
    use_add(b, offset, hi);
    // 区间作废下不碰 pend 的写不拷回（gwr_keep），不算缺陷
    int keep = gwr_on() && b->sh && !b->sxov && !(b->npend && pend_hit(b, offset, hi));
    if ((b->npend || b->ngp) && !keep && gal_in_bind()) GRED_ONCE("【缺陷】缓冲 %u 有未拷回的镜像数据，却在渲染编码器绑定阶段被非镜像用到（应在开通道前 gal_buf_preflush）", bid);
    buf_gpu_write_rng(b, offset, hi);
    return b;
}
id<MTLBuffer> gal_buf_mtl_range(uint32_t bid, int32_t offset, int32_t len, uint64_t *mtl_offset) {
    gbuf *b = buf_use_rw(bid, offset, len); if (!b) return nil;
    return buf_mtl(b, offset, len, mtl_offset);
}
// 只读绑定（常量 / 顶点 / 索引缓冲）：区间读到 pend → 绑影子的临时拷贝（镜像）；否则真缓冲
uint64_t gal_buf_read_gpu(uint32_t bid, int32_t offset, int32_t len) {
    gbuf *b = buf_get(bid); if (!b) return 0;
    int32_t hi = len > 0 ? offset + len : b->size; if (hi > b->size) hi = b->size;
    int mirror = b->npend && b->sh && pend_hit(b, offset, hi);
    // 同一绑定既读到 pend 又读到过期区间：影子拼不出，退影子（pend 拷回、读真缓冲）。绑定阶段中途退会切遍，报一次缺陷
    if (mirror && b->nsx && sx_hit(b, offset, hi)) {
        if (gal_in_bind()) GRED_ONCE("【缺陷】缓冲 %u 的只读绑定 [%d, %d) 同时读到待拷回段与 GPU 写在途段，绑定阶段退影子", bid, offset, hi);
        sh_retire(b); mirror = 0;
    }
    if (mirror) {
        uint64_t cb = gal_cb_id();
        for (int i = 0; i < b->nmir; i++) if (b->mir[i].cb == cb && b->mir[i].lo == offset && b->mir[i].hi == hi) return b->mir[i].gpu;
        uint64_t gpu; uint8_t *p = gal_transient((uint32_t)(hi - offset), 256, &gpu); if (!p) return 0;
        memcpy(p, b->sh + offset, (size_t)(hi - offset));
        int k = b->nmir < 4 ? b->nmir++ : (int)(cb & 3);
        b->mir[k].lo = offset; b->mir[k].hi = hi; b->mir[k].cb = cb; b->mir[k].gpu = gpu;
        g_gp_n[GP_MIRROR]++;
        return gpu;
    }
    // 读到暂存补丁：预载里拼镜像（真缓冲这段 → 暂存块，再按序叠上相交的补丁），本次提交内按区间缓存；这段记已用（之后的写不能再进预载、排到拼镜像之前）
    if (b->ngp && gp_hit(b, offset, hi)) {
        uint64_t cb = gal_cb_id();
        for (int i = 0; i < b->nmir; i++) if (b->mir[i].cb == cb && b->mir[i].lo == offset && b->mir[i].hi == hi) return b->mir[i].gpu;
        uint32_t n = (uint32_t)(hi - offset);
        uint64_t mo, so; uint8_t *mp; id<MTLBuffer> m = stg_alloc(n, &mo, &mp); if (!m) return 0;
        id<MTLBuffer> src = buf_mtl(b, offset, (int32_t)n, &so); if (!src) return 0;
        b->touched = 1; use_add(b, offset, hi);
        [gal_preload_enc() copyFromBuffer:src sourceOffset:so toBuffer:m destinationOffset:mo size:n];
        for (int i = 0; i < b->ngp; i++) {
            int32_t lo = b->gp[i].off > offset ? b->gp[i].off : offset, e = b->gp[i].off + b->gp[i].size < hi ? b->gp[i].off + b->gp[i].size : hi;
            if (lo >= e) continue;
            [gal_preload_enc() copyFromBuffer:(__bridge id<MTLBuffer>)b->gp[i].stg sourceOffset:b->gp[i].so + (uint64_t)(lo - b->gp[i].off) toBuffer:m destinationOffset:mo + (uint64_t)(lo - offset) size:(NSUInteger)(e - lo)];
        }
        int k = b->nmir < 4 ? b->nmir++ : (int)(cb & 3);
        b->mir[k].lo = offset; b->mir[k].hi = hi; b->mir[k].cb = cb; b->mir[k].gpu = m.gpuAddress + mo;
        g_gp_n[GP_MIRROR]++;
        return m.gpuAddress + mo;
    }
    b->touched = 1;
    use_add(b, offset, hi);
    if (b->mtl) return b->gpu + b->lead + (uint64_t)offset;   // 整段缓冲：直接用建时缓存的地址（同 buf_mtl 的偏移算法）
    uint64_t o; id<MTLBuffer> m = buf_mtl(b, offset, len, &o);
    return m ? m.gpuAddress + o : 0;
}
id<MTLBuffer> gal_buf_mtl(uint32_t bid, int32_t offset, uint64_t *mtl_offset) { return gal_buf_mtl_range(bid, offset, 0, mtl_offset); }
// 取地址的热路径（存储缓冲 / 间接参数等每次绘制都取）：整段缓冲直接用建时缓存的地址。原先经 gal_buf_mtl_range 返回 id 再取 gpuAddress，
// 每次都有 objc 消息 + 自动释放池登记（10-19 Mac 岛上录像回放：只读路径改缓存后每帧 CPU 6.9 → 4.6 ms）
uint64_t gal_buf_gpu_range(uint32_t bid, int32_t offset, int32_t len) {
    gbuf *b = buf_use_rw(bid, offset, len); if (!b) return 0;
    if (b->mtl) return b->gpu + b->lead + (uint64_t)offset;
    uint64_t o; id<MTLBuffer> m = buf_mtl(b, offset, len, &o);
    return m ? m.gpuAddress + o : 0;
}
uint64_t gal_buf_gpu(uint32_t bid, int32_t offset) { return gal_buf_gpu_range(bid, offset, 0); }
int32_t gal_buf_size(uint32_t bid) { gbuf *b = buf_get(bid); return b ? b->size : 0; }

// ---------- 建 / 删 ----------
NXGAL_API uint32_t nxgal_buf_create(int32_t size, int32_t access) { GAL_API_LOCK();
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    (void)access;   // 统一内存：Host / Device / Stream 提示不改变放置（见文件头）
    if (size < 0) { GLOG("【红】建缓冲：大小 %d 为负", size); return 0; }
    id<MTLBuffer> m; { RS_SCOPE(RS_BUF); m = [g_gdev newBufferWithLength:size > 0 ? (NSUInteger)size : 16 options:MTLResourceStorageModeShared]; } RS_BYTES(RS_BUF, size);
    if (!m) { GLOG("【红】建 %d 字节缓冲失败：%s", size, gal_mem_note()); return 0; }
    gal_res_add(m);
    uint32_t bid = buf_alloc(); if (!bid) { gal_res_remove(m); return 0; }
    g_buf[bid] = (gbuf){(void *)CFBridgingRetain(m), m.gpuAddress, NULL, size, 1, 0, 0, 0, 0, 0};
    return bid;
}

// 宿主映射的可读写别名（10-23 帧率能耗线，缓冲零拷贝）：newBufferWithBytesNoCopy 按「建缓冲那一刻」的页保护给 GPU 映射——
// 建在不可访问页上建不出来，建在只读页上建得出来但 GPU 写无声丢失（CPU 读到旧值、命令状态「已完成」）；之后再改 CPU 侧保护不影响 GPU。
// 游戏内存常被写跟踪设成只读 / 不可访问，所以不直接建在游戏地址上：vm_remap 同物理页（共享、不拷）到新地址、改成可读写，在别名上建。
// 游戏那边的页保护不受影响，写跟踪照常；渲染器自己的 CPU 读写也走别名（不经写跟踪，同「不跟踪写」）。返回 0 = 失败
static uintptr_t host_alias(uintptr_t a, uintptr_t n) {
    vm_address_t al = 0; vm_prot_t cur, mx;
    if (vm_remap(mach_task_self(), &al, n, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)a, FALSE, &cur, &mx, VM_INHERIT_NONE) != KERN_SUCCESS) return 0;
    if (mprotect((void *)al, n, PROT_READ | PROT_WRITE)) { vm_deallocate(mach_task_self(), al, n); return 0; }
    return (uintptr_t)al;
}
// 别名随缓冲删除延后释放：包成对象交 gal_release_later，栅栏完成（GPU 不再碰）后 vm_deallocate
//   交出时第二个参数必须是 0：这个 NSData 从没进过驻留集、也不是 MTLAllocation，给 1 会让 dead_reap 拿它去 removeAllocation——
//   校验层下抛 unrecognized selector（-[NSConcreteData baseObject]），不开校验层是未定义行为（10-24 画幅线开校验层跑 t_buf 查出）
static id alias_holder(uintptr_t al, uintptr_t n) {
    return [[NSData alloc] initWithBytesNoCopy:(void *)al length:n deallocator:^(void *p, NSUInteger len) { vm_deallocate(mach_task_self(), (vm_address_t)p, len); }];
}

// CreateBuffer(nint, int)：零拷贝映射宿主内存（同 Vulkan BufferManager.CreateHostImported）。newBufferWithBytesNoCopy 要页对齐：区间外扩到整页，记前导偏移。
// 页对齐后 ≤ WIN_LEN：整段一个缓冲（过安全阀后进驻留集）；更大：分窗、按取址懒建（host_win）。
NXGAL_API uint32_t nxgal_buf_create_host(void *ptr, int32_t size) { GAL_API_LOCK();
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    if (!ptr || size <= 0) { GLOG("【红】宿主映射：指针 %p 大小 %d 无效", ptr, size); return 0; }
    uintptr_t pg = (uintptr_t)getpagesize(), lo = (uintptr_t)ptr;
    uintptr_t a = lo & ~(pg - 1), e = (lo + (uintptr_t)size + pg - 1) & ~(pg - 1);
    void *mtl = NULL, *win = NULL;
    uintptr_t al = host_alias(a, e - a);
    if (!al) { GLOG("【红】宿主映射 %p+%#x 建可读写别名失败", ptr, size); return 0; }
    if (e - a <= WIN_LEN) {
        if (!res_valve_ok(e - a)) { vm_deallocate(mach_task_self(), al, e - a); return 0; }
        id<MTLBuffer> m = [g_gdev newBufferWithBytesNoCopy:(void *)al length:e - a options:MTLResourceStorageModeShared deallocator:nil];
        if (!m) { GLOG("【红】宿主映射 %p+%#x 建零拷贝缓冲失败", ptr, size); vm_deallocate(mach_task_self(), al, e - a); return 0; }
        gal_res_add(m); mtl = (void *)CFBridgingRetain(m);
    } else win = (void *)CFBridgingRetain([NSMutableDictionary dictionary]);
    uint32_t bid = buf_alloc();
    if (!bid) {   // 表扩不了（已报红）：放掉这次建的整段缓冲 / 窗口表与别名
        if (mtl) { gal_res_remove(M(mtl)); CFBridgingRelease(mtl); }
        if (win) CFBridgingRelease(win);
        vm_deallocate(mach_task_self(), al, e - a); return 0;
    }
    g_buf[bid] = (gbuf){mtl, mtl ? M(mtl).gpuAddress : 0, win, size, 1, 0, 1, a, e, al, (uint32_t)(lo - a)};
    return bid;
}

// 游戏内存某段物理页被换掉（原生层 backing_changed → 写跟踪 → C# → nxgal_host_remapped 登记 → 下次取用时 host_rebuild）：重叠的宿主映射，旧别名 / 窗口 / 整段缓冲延后到栅栏释放（在途命令照用旧页，
// 那是换页前录的），对新页重建别名；小映射当场重建整段缓冲、换 GPU 地址，大映射清空窗口表、下次取址按新别名懒建
NXGAL_API void nxgal_host_remapped(uint64_t addr, uint64_t size) {   // 不拿入口锁（见 buf_get 前）
    uint64_t i = atomic_fetch_add(&g_rm_head, 1);
    g_rmq[i % RMQ].a = addr; g_rmq[i % RMQ].n = size; atomic_store_explicit(&g_rmq[i % RMQ].seq, i + 1, memory_order_release);
}
static void host_rebuild(uint64_t addr, uint64_t size);
static void remap_drain(void) {   // 入口锁内（buf_get）
    uint64_t h = atomic_load_explicit(&g_rm_head, memory_order_acquire);
    if (h - g_rm_tail > RMQ) { g_rm_tail = h; host_rebuild(0, UINT64_MAX); GLOG("【红】换页登记环溢出：全部宿主映射重建"); return; }
    for (; g_rm_tail < h; g_rm_tail++) {
        uint64_t k = g_rm_tail % RMQ;
        // 写入方已占号、还没写完：只等有限次（写方游戏线程可能被系统切走 / 等核，毫秒级；渲染线程不能陪等），等不到按「被追尾」处理。
        // 全部重建是安全的：原生层先换完页才回调，此刻重建拿到的就是新页；写方晚写完的那一格编号已在读指针之后，被忽略（原生层线 10-23 审）
        uint64_t sq; int spin = 0;
        while ((sq = atomic_load_explicit(&g_rmq[k].seq, memory_order_acquire)) < g_rm_tail + 1 && ++spin < 4096) {}
        if (sq != g_rm_tail + 1) { g_rm_tail = atomic_load_explicit(&g_rm_head, memory_order_acquire); host_rebuild(0, UINT64_MAX); GLOG("【红】换页登记环被追尾：全部宿主映射重建"); return; }
        host_rebuild(g_rmq[k].a, g_rmq[k].n);
    }
}
static void host_rebuild(uint64_t addr, uint64_t size) {
    uint64_t e = size == UINT64_MAX ? UINT64_MAX : addr + size; int n = 0;
    for (uint32_t i = 1; i < g_nbuf; i++) {
        gbuf *b = &g_buf[i]; if (!b->live || !b->host || b->end <= addr || b->base >= e) continue;
        uintptr_t al = host_alias(b->base, b->end - b->base);
        if (!al) { GLOG("【红】换页后重建宿主映射别名失败：%p+%#llx（该缓冲之后 GPU 读写的仍是旧页）", (void *)b->base, (unsigned long long)(b->end - b->base)); continue; }
        if (b->abase) gal_release_later(alias_holder(b->abase, b->end - b->base), 0);
        b->abase = al;
        if (b->win) { NSMutableDictionary *d = (__bridge NSMutableDictionary *)b->win; for (id<MTLBuffer> w in d.allValues) gal_release_later(w, 1); [d removeAllObjects]; }
        if (b->mtl) {
            id<MTLBuffer> m = [g_gdev newBufferWithBytesNoCopy:(void *)al length:b->end - b->base options:MTLResourceStorageModeShared deallocator:nil];
            gal_release_later((__bridge_transfer id)b->mtl, 1);
            if (m) { gal_res_add(m); b->mtl = (void *)CFBridgingRetain(m); b->gpu = m.gpuAddress; } else { b->mtl = NULL; b->gpu = 0; GLOG("【红】换页后重建零拷贝缓冲失败：%p", (void *)b->base); }
        }
        g_obj_gen++; n++;
    }
    if (n) { static uint64_t tot; tot += n; if (tot <= 4 || !(tot & (tot - 1))) GLOG("宿主映射换页重建：本次 %d 个，累计 %llu 个（%#llx+%#llx）", n, (unsigned long long)tot, (unsigned long long)addr, (unsigned long long)size); }
}

// 稀疏缓冲：能力表报 supportsSparseBuffer = false，Gpu 层只在该能力为真时调 CreateBufferSparse（BufferCache.cs:312 → MultiRangeBuffer.cs:96），否则走普通 CreateBuffer + 拷贝依赖。
NXGAL_API uint32_t nxgal_buf_create_sparse(const nxgal_buf_range *ranges, int32_t n) { GAL_API_LOCK();
    (void)ranges; (void)n;
    GRED_ONCE("CreateBufferSparse 被调用：能力表报不支持稀疏缓冲，不该走到这里（返回空句柄）");
    return 0;
}

NXGAL_API void nxgal_buf_delete(uint32_t bid) { GAL_API_LOCK();
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    gbuf *b = buf_get(bid); if (!b) return;
    if (b->mtl) gal_release_later((__bridge_transfer id)b->mtl, 1);
    if (b->win) { NSMutableDictionary *d = (__bridge_transfer NSMutableDictionary *)b->win; for (id<MTLBuffer> w in d.allValues) gal_release_later(w, 1); }
    if (b->host && b->abase) { gal_release_later(alias_holder(b->abase, b->end - b->base), 0); b->abase = 0; }
    b->mtl = b->win = NULL; b->live = 0;
    cv_clear(b, 0, b->size); sh_drop(b); b->npend = 0; b->ngp = 0; b->use.n = 0; b->use.tag = 0; b->upass = 0; b->wfence = 0; b->gwfence = 0; b->nup = 0; b->upov = 0; b->touched = 0; b->nsx = 0; b->sxov = 0;
    free(b->up); b->up = NULL; b->upcap = 0;   // 建缓冲按 (gbuf){…} 整体赋值、不会释放，删时放掉在途上传表
    free(b->use.iv); b->use = (ivset){0};
    for (int k = 0; k < g_npend_ids; k++) if (g_pend_ids[k] == bid) { g_pend_ids[k] = g_pend_ids[--g_npend_ids]; break; }
    if (g_nbuf_free == g_cap_free) { g_cap_free = g_cap_free ? g_cap_free * 2 : 1024; g_buf_free = realloc(g_buf_free, g_cap_free * sizeof *g_buf_free); }
    g_buf_free[g_nbuf_free++] = bid;
}

// 宿主映射默认不放行（Gpu 层退到 CreateBuffer(size, HostMemory) + CPU 回拷，TextureGroup.cs:670–678；同 Vulkan 不支持宿主导入时）：
//   ① 我们的内存后端 GetHostRegions 恒返回 null（sw/gfx/tools/ryu_judge/core/Memory.cs:171），PhysicalMemory.GetHostPointer 得 0，Gpu 层根本走不到这里；
//   ② 零拷贝缓冲驻留后整段 wired、到进程退出才放；刷回缓冲随贴图换地址反复建，wired 只增不减（10-18 内核恐慌根因），收益只是省一次线性贴图的 CPU 拷贝。
NXGAL_API int32_t nxgal_prepare_host_mapping(void *addr, uint64_t size) { GAL_API_LOCK();
    (void)addr; (void)size;
    return 0;
}

// ---------- 读写清拷 ----------
// 区间合法：0 ≤ offset，offset + size ≤ 缓冲大小
static int range_ok(const gbuf *b, int32_t offset, int32_t size) { return offset >= 0 && size >= 0 && (int64_t)offset + size <= b->size; }
static uint8_t *cpu_ptr(gbuf *b, int32_t offset) { return b->host ? (uint8_t *)(b->abase + b->lead) + offset : (uint8_t *)M(b->mtl).contents + offset; }
// 建影子 / 记在途上传用的「已完成」值；NXGAL_TEST_UPLAG=N 让它比真实值落后 N 个命令缓冲（测试：Mac GPU 快、完成值几乎不落后，用它模拟真机落后 1–2 帧）
static uint64_t up_done(void) { static int64_t lag = -1; if (lag < 0) { const char *v = getenv("NXGAL_TEST_UPLAG"); lag = v ? atoll(v) : 0; } uint64_t d = gal_done_fence(); return d > (uint64_t)lag ? d - (uint64_t)lag : 0; }
// 建影子（见 gbuf.gwfence / up）：成功返回 1
// 单测故障注入（tests/t_buf.c）：非 0 时影子 malloc 当作失败
int gal_sh_test_fail;
static int sh_try_build(gbuf *b) {
    if (b->sh) return 1;
    // 有暂存补丁：内存里没有它们（拷回前），影子建不全
    if (b->host || b->size > (4 << 20) || b->ngp) return 0;
    uint64_t done = up_done();
    if (b->upov && b->ovcb <= done) b->upov = 0;
    if (b->gwfence <= done) { b->sxov = 0; b->nsx = 0; }
    // 区间作废：GPU 写还在途也能建，前提是在途的 GPU 写都记下了区间（sx，那里影子先算过期）
    if ((b->gwfence > done && (!gwr_on() || b->sxov)) || b->upov) return 0;
    // 影子 malloc 失败（10-21 巫师3 iPhone 低区地址耗尽，NULL 上 memcpy SIGSEGV）：报红、不建影子，调用方照无影子走暂存路径
    b->sh = gal_sh_test_fail ? NULL : malloc((size_t)b->size);
    if (!b->sh) { static int nf; if (nf++ < 4 || !(nf & (nf - 1))) GLOG("【红】建 %d 字节缓冲影子失败（第 %d 次，本次不镜像、走暂存上传）：%s", b->size, nf, gal_mem_note()); return 0; }
    memcpy(b->sh, cpu_ptr(b, 0), (size_t)b->size);
    for (int i = 0; i < b->nup; i++) if (b->up[i].cb > done) {
        memcpy(b->sh + b->up[i].off, b->up[i].src, (size_t)b->up[i].size);
        // 与过期区间相交的在途上传：回填要等它也落地（取晚的提交号）
        for (int k = 0; k < b->nsx; k++) if (b->up[i].off < b->sx[k].hi && b->sx[k].lo < b->up[i].off + b->up[i].size && b->up[i].cb > b->sx[k].cb) b->sx[k].cb = b->up[i].cb;
    }
    b->nup = 0; b->upov = 0;
    return 1;
}
// 记一条在途 CPU 上传（无影子时；src 是暂存里的数据）
static void up_add(gbuf *b, int32_t off, int32_t size, const uint8_t *src) {
    uint64_t done = up_done(); int k = 0;
    for (int i = 0; i < b->nup; i++) if (b->up[i].cb > done) b->up[k++] = b->up[i];
    b->nup = k;
    if (b->upov && b->ovcb <= done) b->upov = 0;
    if (k == b->upcap && k < UP_MAX) {
        int32_t nc = b->upcap ? b->upcap * 2 : 8; if (nc > UP_MAX) nc = UP_MAX;
        struct gup *nu = realloc(b->up, (size_t)nc * sizeof *nu);
        if (nu) { b->up = nu; b->upcap = nc; }
    }
    if (k < b->upcap) { b->up[k].off = off; b->up[k].size = size; b->up[k].src = src; b->up[k].cb = gal_cb_id(); b->nup++; }
    else {
        if (!b->upov) { b->ovlo = off; b->ovhi = off + size; } else { if (off < b->ovlo) b->ovlo = off; if (off + size > b->ovhi) b->ovhi = off + size; }
        b->upov = 1; b->ovcb = gal_cb_id();
    }
}
// CPU 侧此刻的逻辑内容（只读；索引转换等在 CPU 上做、免切渲染通道用）：有影子读影子（整块真值）；否则没有待拷回段、且从没被 GPU 碰过或
// GPU 对它的写（拷贝 / 清除 / 预载 / 存储缓冲 / 贴图缓冲，都记 wfence）已完成时读 CPU 指针；拿不准返回 NULL，调用方走 GPU 路径
const uint8_t *gal_buf_cpu_view(uint32_t bid, int32_t offset, int32_t len) {
    gbuf *b = buf_get(bid); if (!b || !range_ok(b, offset, len)) return NULL;
    if (b->sh) return b->nsx && sx_hit(b, offset, offset + len) ? NULL : b->sh + offset;
    if (b->npend || b->ngp || (b->touched && b->wfence > gal_done_fence())) return NULL;
    return cpu_ptr(b, offset);
}

// 诊断 NXGAL_WAIT_SITE=1（缺省关）：缓冲读回按「此刻需不需要等 GPU」分类计次 / 等待毫秒 / 字节，每 5 秒打一行 [getdata]。
// 类别：0 影子 1 没被 GPU 碰过 2 GPU 对它的写（wfence）已完成 3 写在已提交未完成的命令缓冲里 4 写在在录命令缓冲里
static void getdata_note(int cat, uint64_t ns, int32_t size) {
    static int on = -1; if (on < 0) on = getenv("NXGAL_WAIT_SITE") != NULL;
    if (!on) return;
    static uint64_t n[5], t[5], by[5], last;
    n[cat]++; t[cat] += ns; by[cat] += (uint64_t)size;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - last < 5000000000ull) return;
    last = now;
    fprintf(stderr, "[getdata] 影子 %llu 次 / 未碰 %llu 次 / 写已完成 %llu 次等 %.0f ms / 写已提交未完成 %llu 次等 %.0f ms / 写在在录 %llu 次等 %.0f ms；字节 %llu KB\n",
            (unsigned long long)n[0], (unsigned long long)n[1], (unsigned long long)n[2], t[2] / 1e6, (unsigned long long)n[3], t[3] / 1e6, (unsigned long long)n[4], t[4] / 1e6,
            (unsigned long long)((by[0] + by[1] + by[2] + by[3] + by[4]) >> 10));
}
// 不等 GPU 的读（宽屏层几何判定，10-23）：逻辑内容在 CPU 侧拿得准才拷出、返回 1；拿不准返回 0，绝不提交 / 等 GPU。
// 10-23 帧率能耗线：几何判定走 nxgal_buf_get_data 读刚在在录命令缓冲里写过的小缓冲，次次 gal_finish（马车8 读回 4.43 s）。
// 判据同建影子（sh_try_build）：有影子读影子；否则没有暂存补丁、GPU 自己产生的写（gwfence）已完成时，逻辑内容 = 当前内存 + 按序叠上在途上传
//   （只用 gal_buf_cpu_view 时在途上传一律判拿不准：常量缓冲多半在途，巫师3 每帧 343 笔几何判定读不到）
NXGAL_API int32_t nxgal_buf_peek_cpu(uint32_t bid, int32_t offset, int32_t size, void *out) { GAL_API_LOCK();
    gbuf *b = buf_get(bid); if (!b || !range_ok(b, offset, size)) return 0;
    if (b->sh) { if (b->nsx && sx_hit(b, offset, offset + size)) return 0; memcpy(out, b->sh + offset, (size_t)size); return 1; }
    if (b->host || b->ngp) return 0;
    uint64_t done = up_done();
    if (b->upov && b->ovcb <= done) b->upov = 0;
    if (b->gwfence > done || (b->upov && offset < b->ovhi && b->ovlo < offset + size)) return 0;
    memcpy(out, cpu_ptr(b, offset), (size_t)size);
    for (int i = 0; i < b->nup; i++) {
        if (b->up[i].cb <= done) continue;
        int32_t lo = b->up[i].off > offset ? b->up[i].off : offset, hi = b->up[i].off + b->up[i].size < offset + size ? b->up[i].off + b->up[i].size : offset + size;
        if (lo < hi) memcpy((uint8_t *)out + (lo - offset), b->up[i].src + (lo - b->up[i].off), (size_t)(hi - lo));
    }
    return 1;
}
NXGAL_API int32_t nxgal_buf_get_data(uint32_t bid, int32_t offset, int32_t size, void *out) { GAL_API_LOCK();
    SW_SCOPE(SW_READBACK, 1);
    // 编号无效（宿主缓冲已释放，Gpu 层仍来回读）：同 Ryujinx Vulkan BufferManager.GetData 返回空、不算错（调用方交回空数据，不写客体内存）
    gbuf *b = buf_get(bid); if (!b) { static _Atomic int once; if (!atomic_exchange(&once, 1)) GLOG("读缓冲：编号 %u 无效，按 Ryujinx 口径返回空（之后同类不再打）", bid); return -1; }
    if (!range_ok(b, offset, size)) { GLOG("【红】读缓冲 %u：区间 %d+%d 超出大小 %d", bid, offset, size, b->size); return -1; }
    // 从没被 GPU 碰过：没有任何命令会写它，内容就是 CPU 写进去的，免提交免等
    if (b->sh && b->nsx && sx_hit(b, offset, offset + size)) sh_retire(b);   // 读到 GPU 写在途段：退影子，照下面等 GPU
    if (b->sh) { getdata_note(0, 0, size); memcpy(out, b->sh + offset, size); return 0; }   // 影子就是逻辑内容（GPU 写在途的区间不读影子，见上）
    int cat = !b->touched ? 1 : b->wfence <= gal_done_fence() ? 2 : b->wfence < gal_cb_id() ? 3 : 4;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    // 按需同步：只等这块缓冲自己的 GPU 写（wfence：拷贝 / 清除 / 预载 / 存储缓冲 / 贴图缓冲 / 在途上传，交出可写地址一律记，只多不少），不等别的已提交工作。
    // 同 Ryujinx Vulkan 后端：统一内存上缓冲是映射的，BufferHolder.GetData 直接读、不等 GPU；先后由 Gpu 层保证（WaitForAndFlushRanges 先 WaitSync 到写它的同步号）。
    // 渲染线程：写还在在录命令缓冲里（或有待拷回的暂存补丁）才提交并等完，否则只等 wfence；非渲染线程不提交别人在录的，只等 wfence 与已提交的较小者（见 gal_core.m gal_readback_enc）。
    // 10-21 改前一律等全部已提交（渲染线程还先提交在录的）：塞尔达每帧上百次回写里 GPU 写早已做完的占 99%，每次照样等满在途的一整帧
    if (b->touched) {
        if (gal_on_rec_thread()) { if (b->ngp || b->wfence >= gal_cb_id()) gal_finish(); else gal_wait(b->wfence); }
        else { uint64_t c = gal_committed_fence(); gal_wait(b->wfence < c ? b->wfence : c); }
    }
    getdata_note(cat, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0, size);
    memcpy(out, cpu_ptr(b, offset), size);
    return 0;
}

NXGAL_API void nxgal_buf_set_data(uint32_t bid, int32_t offset, const void *data, int32_t size) { GAL_API_LOCK();
    SW_SCOPE(SW_UPLOAD, 0);   // 调度测算：遍内写缓冲换新块即可，不算真依赖
    GP_SCOPE(GP_UPLOAD);
    gbuf *b = buf_get(bid); if (!b) { GRED_ONCE("写缓冲：编号 %u 无效", bid); return; }
    if (offset < 0 || offset > b->size) { GLOG("【红】写缓冲 %u：偏移 %d 超出大小 %d", bid, offset, b->size); return; }
    if (size > b->size - offset) size = b->size - offset;   // 同 Vulkan BufferHolder.SetData：dataSize = min(data.Length, Size - offset)
    if (size <= 0) return;
    b->wser = ++g_buf_wser;
    { static int tr = -1; if (tr < 0) tr = getenv("NXGAL_TRACE_BUFW") != NULL; if (tr) fprintf(stderr, "[bufw] %u %d %d %d %d %d\n", bid, offset, size, b->size, b->touched, use_hit(b, offset, offset + size)); }
    // NXGAL_PERF_DIRECTUP=1：拆账实验（只量时间，画面不保证对）——GPU 在用也直接写 CPU 指针，不开拷贝编码器、不打断渲染通道，量「镜像」去法的收益上限
    static int direct = -1; if (direct < 0) { const char *v = getenv("NXGAL_PERF_DIRECTUP"); direct = v && *v == '1'; }
    if (b->ncv) cv_clear(b, offset, offset + size);
    if (b->sh && b->nsx && sx_hit(b, offset, offset + size)) sh_retire(b);   // 写进 GPU 写在途段：退影子（这段的先后要按命令流来）
    if (b->sh) {   // 影子随写（各路径都写，影子始终是整块逻辑内容）
        memcpy(b->sh + offset, data, size);
        // 与这次写重叠的镜像（影子的临时拷贝，gal_buf_read_gpu 按本次提交 + 区间缓存复用）随之过期：一律作废、绑定重取。
        // 原先只在镜像分支作废；镜像读不登记已用区间，紧跟的写常走预载分支，下一次绘制命中旧镜像读到写前内容
        // （10-20 画幅线：丝之歌每帧现写顶点的精灵整批不画，录像对参照差 41%，NXGAL_NO_MIRROR=1 下 0%）
        int dropped = 0;
        for (int i = 0; i < b->nmir; i++) if (offset < b->mir[i].hi && b->mir[i].lo < offset + size) { b->mir[i] = b->mir[--b->nmir]; i--; dropped = 1; }
        if (dropped) { g_obj_gen++; gal_draw_rebind_buffers(); }
    }
    if (!b->touched || direct) { memcpy(cpu_ptr(b, offset), data, size); return; }
    static int nopre = -1, nomir = -1;
    if (nopre < 0) { const char *v = getenv("NXGAL_NO_PRELOAD"); nopre = v && *v == '1'; v = getenv("NXGAL_NO_MIRROR"); nomir = v && *v == '1'; }
    int hit = nopre || use_hit(b, offset, offset + size);
    // 命中本次提交已用区间：能建 / 已有影子就只记 pend（镜像），不录 GPU 命令、不切通道。宿主映射缓冲不镜像（CPU 内容随客体内存变）
    int had_sh = b->sh != NULL;
    // 写落在 GPU 写在途段（sx）里：这段影子建出来也是旧的、pend 会盖掉 GPU 写，不现建影子（有影子时上面已退）
    int stale = !had_sh && b->nsx && sx_hit(b, offset, offset + size);
    if (hit && !nomir && !stale && (had_sh || sh_try_build(b))) {
        if (!had_sh) memcpy(b->sh + offset, data, size);
        pend_add(bid, b, offset, offset + size);   // 重叠的旧镜像已在上面影子随写处作废
        g_obj_gen++; gal_draw_rebind_buffers();   // 读这段的绑定要改指镜像
        g_gp_n[GP_MIRRORW]++;
        return;
    }
    @autoreleasepool {
        uint64_t so; uint8_t *p; id<MTLBuffer> s = stg_alloc((uint32_t)size, &so, &p); if (!s) return;
        memcpy(p, data, size);
        // 这段在本次提交里还没被任何命令用到 → 拷贝进预载命令缓冲（排在在录命令缓冲之前、之前提交之后：对之前的命令不可见，对本次提交全部命令可见），
        // 不切开渲染通道（同 Ryujinx Vulkan 后端 BufferHolder.SetData 的 preload 分支）。用到过 → 录进在录命令流（会切开通道）
        if (!hit) {
            uint64_t doff; id<MTLBuffer> d = buf_mtl(b, offset, size, &doff); if (!d) return;
            [gal_preload_enc() copyFromBuffer:s sourceOffset:so toBuffer:d destinationOffset:doff size:size];
            // 能建就顺手建影子（当前内存 + 在途上传 + 这次的数据，见 sh_try_build）：否则这次预载记「写在途」，本帧之后命中已用区间的上传只能录拷贝
            // 切开渲染通道，下帧重来（10-19 Mac 马车8 整局 26 万次；真机三款镜像写全 0）。建不了就把这次记进在途上传，下次再建
            if (!b->sh && !nomir && !stale && sh_try_build(b)) memcpy(b->sh + offset, data, size);
            if (!b->sh) { up_add(b, offset, size, p); b->wfence = gal_cb_id(); }   // 有影子时这次写已进影子，影子仍是真值
            g_gp_n[GP_PRELOAD]++;
            return;
        }
        // ③ 命中已用区间、建不了影子：暂存补丁（不录 GPU 命令、不切通道），条件 = 预载里读真缓冲与此刻在录流里读到的相同（gal_buf_preload_readable 的真缓冲口径），
        // 补丁不满 8 条、不是宿主映射、≤ 4 MB（读到补丁的绑定要在预载里拼镜像，拷整段区间）。NXGAL_NO_UPPATCH=1 关（照旧录进在录流，切开通道）
        {
            static int nogp = -1; if (nogp < 0) { const char *v = getenv("NXGAL_NO_UPPATCH"); nogp = v && *v == '1'; }
            uint64_t cur = gal_cb_id();
            if (!nogp && !nopre && !nomir && !b->host && b->size <= (4 << 20) && b->ngp < 8 && !b->npend && !b->sh
                && !(b->gwfence == cur && b->pgw_cb != cur) && b->inl_cb != cur) {
                if (!b->ngp) { if (g_npend_ids == g_cap_pend_ids) { g_cap_pend_ids = g_cap_pend_ids ? g_cap_pend_ids * 2 : 64; g_pend_ids = realloc(g_pend_ids, g_cap_pend_ids * sizeof *g_pend_ids); } g_pend_ids[g_npend_ids++] = bid; }
                b->gp[b->ngp].off = offset; b->gp[b->ngp].size = size; b->gp[b->ngp].stg = (__bridge void *)s; b->gp[b->ngp].so = so; b->gp[b->ngp].src = p; b->ngp++;
                // 补丁整段记已用：之后与它相交的写也走补丁（按序），不进预载——预载写排在提交开头，会被这条更早的补丁在提交时盖掉
                use_add(b, offset, offset + size);
                // 与这次写重叠的镜像作废（之后的读按新补丁重拼）
                for (int i = 0; i < b->nmir; i++) if (offset < b->mir[i].hi && b->mir[i].lo < offset + size) { b->mir[i] = b->mir[--b->nmir]; i--; }
                g_obj_gen++; gal_draw_rebind_buffers();
                g_gp_n[GP_MIRRORW]++;
                return;
            }
        }
        // ④ 区间本遍没用过：录进遍前段（排在本遍之前、更早各遍之后），本遍不收
        id pe = pre_write_enc(bid, b, offset, offset + size);
        if (!pe) { if (b->npend) pend_flush(b); if (b->ngp) gp_flush(b); }
        uint64_t doff; id<MTLBuffer> d = buf_mtl(b, offset, size, &doff); if (!d) return;
        g_buf_prepass_bind = pe != nil; use_add(b, offset, offset + size); g_buf_prepass_bind = 0;
        b->touched = 1; b->inl_cb = gal_cb_id();
        [pe ? pe : gal_blit_enc() copyFromBuffer:s sourceOffset:so toBuffer:d destinationOffset:doff size:size];
        if (!b->sh) { up_add(b, offset, size, p); b->wfence = gal_cb_id(); }
        g_gp_n[GP_INLINEUP]++;
    }
}

// ClearBuffer：32 位值重复填充（Vulkan vkCmdFillBuffer）。Metal fillBuffer 只填单字节：四字节相同时直接用；否则 CPU 在暂存里铺一段图样（≤ 64 KB），
// 再按段拷到目标——各段写互不重叠、源只读，同一编码器里不需要段间屏障。
// 长度非 4 的倍数：Gpu 层保证对齐（BufferCache.cs:779「address and size must be aligned to 4 bytes」）；Vulkan 对此是未定义，
// 唯一有定义的近似是 VK_WHOLE_SIZE 的「取不超过的 4 的倍数」——这里照此向下取整、尾部不写，并报红一次。
#define CLR_PAT (64u << 10)
NXGAL_API void nxgal_buf_clear(uint32_t bid, int32_t offset, int32_t size, uint32_t value) { GAL_API_LOCK();
    SW_SCOPE(SW_FILL, 0);   // 调度测算：同写缓冲
    GP_SCOPE(GP_COPY);
    gbuf *b = buf_get(bid); if (!b) { GRED_ONCE("清缓冲：编号 %u 无效", bid); return; }
    if (size & 3) { GRED_ONCE("清缓冲：长度 %d 不是 4 的倍数（Gpu 层约定对齐），按向下取整处理", size); size &= ~3; }
    if (!range_ok(b, offset, size)) { GLOG("【红】清缓冲 %u：区间 %d+%d 超出大小 %d", bid, offset, size, b->size); return; }
    if (!size) return;
    b->wser = ++g_buf_wser;
    @autoreleasepool {
        // 区间本遍没用过：填充录进遍前段（待拷回镜像一并拷回进遍前段），本遍不收
        id pe = pre_write_enc(bid, b, offset, offset + size);
        g_buf_prepass_bind = pe != nil;
        uint64_t doff; id<MTLBuffer> d = gal_buf_mtl_range(bid, offset, size, &doff); g_buf_prepass_bind = 0; if (!d) return;
        uint8_t b0 = value & 0xff;
        if (value == b0 * 0x01010101u) { [pe ? pe : gal_blit_enc() fillBuffer:d range:NSMakeRange(doff, size) value:b0]; return; }
        uint32_t pat = (uint32_t)size < CLR_PAT ? (uint32_t)size : CLR_PAT;
        uint64_t so; uint8_t *p; id<MTLBuffer> s = stg_alloc(pat, &so, &p); if (!s) return;
        for (uint32_t k = 0; k < pat; k += 4) memcpy(p + k, &value, 4);
        id e = pe ? pe : gal_blit_enc();
        for (uint32_t k = 0; k < (uint32_t)size; k += pat) {
            uint32_t n = (uint32_t)size - k < pat ? (uint32_t)size - k : pat;
            [e copyFromBuffer:s sourceOffset:so toBuffer:d destinationOffset:doff + k size:n];
        }
    }
}

// CopyBuffer：同一缓冲且区间重叠时 Metal / Vulkan 都未定义；Gpu 层的 DMA 拷贝可能落在同一缓冲上（BufferCache.CopyBufferSingleRange），
// 这里按 memmove 语义：先拷到暂存、屏障、再拷回。
NXGAL_API void nxgal_buf_copy(uint32_t src, uint32_t dst, int32_t src_offset, int32_t dst_offset, int32_t size) { GAL_API_LOCK();
    SW_SCOPE(SW_BUFCOPY, gal_sw_hit(SW_BUFKEY(src), 1));   // 调度测算：目标换新块；源是本遍画出来的才是真依赖
    GP_SCOPE(GP_COPY);
    gbuf *s = buf_get(src), *d = buf_get(dst);
    if (!s || !d) { GRED_ONCE("拷缓冲：编号 %u → %u 无效", src, dst); return; }
    if (!range_ok(s, src_offset, size) || !range_ok(d, dst_offset, size)) { GLOG("【红】拷缓冲 %u+%d → %u+%d 长 %d 超出大小 %d / %d", src, src_offset, dst, dst_offset, size, s->size, d->size); return; }
    if (!size) return;
    d->wser = ++g_buf_wser;
    // 缓冲搬家拷贝挪进预载（10-20 动森进岛第 278 帧 377 遍里 272 遍由 Ryujinx BufferCache.CreateBufferAligned 的搬家拷贝切开，附件读写 3.37 GB）：
    // 预载命令缓冲排在在录命令缓冲之前、之前提交之后。能挪的条件（缺一不可）：源在本次提交里没被 GPU 写过（gwfence）、没有录进在录流的上传 / 镜像写（inl_cb / pend），
    // 于是源此刻的内容 = 之前提交 + 预载里已排的上传，挪前挪后读到的一样；目标区间本次提交里没被任何命令用到、也没有在录流里的写，于是没人会在拷贝之前读到它。
    // 挪后：源 / 目标都记「GPU 碰过」（之后的 CPU 写不能直写内存抢在预载拷贝之前），目标记 GPU 写在途。NXGAL_NO_PRELOAD=1 关（同上传）
    {
        static int nopre = -1; if (nopre < 0) { const char *v = getenv("NXGAL_NO_PRELOAD"); nopre = v && *v == '1'; }
        uint64_t cur = gal_cb_id();
        // 诊断（NXGAL_TRACE_ENC 按帧排行里打）：没挪成的原因计数 0 同缓冲 1 源本次被 GPU 写 2 源有在录流写 3 源有镜像待拷回 4 目标本次被 GPU 写 5 目标有在录流写 / 待拷回 6 目标区间已被用到
        extern uint32_t g_copy_why[8];
        // 「本次被 GPU 写」只看在录流里的写：写全在预载里（之前挪进去的拷贝，pgw_cb）时顺序本来就对（同一帧几块旧缓冲先后并进同一新缓冲、新缓冲再搬家）
        int sgw = s->gwfence == cur && s->pgw_cb != cur, dgw = d->gwfence == cur && d->pgw_cb != cur;
        int why = nopre ? 7 : src == dst ? 0 : sgw ? 1 : s->inl_cb == cur ? 2 : (s->npend || s->ngp) ? 3 : dgw ? 4 : (d->inl_cb == cur || d->npend || d->ngp) ? 5 : use_hit(d, dst_offset, dst_offset + size) ? 6 : -1;
        if (why >= 0) g_copy_why[why]++;
        if (why < 0) {
            @autoreleasepool {
                uint64_t so, doff; id<MTLBuffer> sm = buf_mtl(s, src_offset, size, &so), dm = buf_mtl(d, dst_offset, size, &doff);
                if (sm && dm) {
                    [gal_preload_enc() copyFromBuffer:sm sourceOffset:so toBuffer:dm destinationOffset:doff size:size];
                    s->touched = 1; d->touched = 1; buf_gpu_write_rng(d, dst_offset, dst_offset + size); d->pgw_cb = cur;   // 目标的 GPU 写在预载里
                    g_gp_n[GP_PRELOAD]++;
                    return;
                }
            }
        }
    }
    @autoreleasepool {
        uint64_t so, doff;
        id<MTLBuffer> sm = gal_buf_mtl_range(src, src_offset, size, &so), dm = gal_buf_mtl_range(dst, dst_offset, size, &doff);
        if (!sm || !dm) return;
        int overlap = src == dst && src_offset < dst_offset + size && dst_offset < src_offset + size;
        if (!overlap) { [gal_blit_enc() copyFromBuffer:sm sourceOffset:so toBuffer:dm destinationOffset:doff size:size]; return; }
        if (src_offset == dst_offset) return;
        uint64_t to; uint8_t *p; id<MTLBuffer> t = stg_alloc((uint32_t)size, &to, &p); if (!t) return;
        [gal_blit_enc() copyFromBuffer:sm sourceOffset:so toBuffer:t destinationOffset:to size:size];
        [gal_blit_enc() copyFromBuffer:t sourceOffset:to toBuffer:dm destinationOffset:doff size:size];   // 第二次取编码器 = 两条之间加屏障
    }
}
// Caller has stopped all API producers, drained the GPU and reaped deferred objects.
// Residency/device remain alive until all three resource-table resets have returned.
void gal_buf_reset_session(void) {
    g_stg_generation++;
    for (uint32_t i = 1; i < g_nbuf; i++) {
        gbuf *b = &g_buf[i];
        if (b->mtl) { id<MTLBuffer> m = (__bridge_transfer id<MTLBuffer>)b->mtl; gal_res_remove(m); b->mtl = NULL; }
        if (b->win) {
            NSMutableDictionary *windows = (__bridge_transfer NSMutableDictionary *)b->win;
            for (id<MTLBuffer> window in windows.allValues) gal_res_remove(window);
            [windows removeAllObjects]; b->win = NULL;
        }
        for (int k = 0; k < b->ncv; k++) {
            id<MTLBuffer> converted = (__bridge_transfer id<MTLBuffer>)b->cv[k].dst;
            gal_res_remove(converted); b->cv[k].dst = NULL;
        }
        if (b->host && b->abase) vm_deallocate(mach_task_self(), b->abase, b->end - b->base);
        free(b->sh); free(b->up); free(b->use.iv);
    }
    free(g_buf); g_buf = NULL; g_nbuf = g_capbuf = 0;
    free(g_buf_free); g_buf_free = NULL; g_nbuf_free = g_cap_free = 0;
    free(g_pend_ids); g_pend_ids = NULL; g_npend_ids = g_cap_pend_ids = 0;
    for (int i = 0; i < g_nstg; i++) {
        id<MTLBuffer> staging = (__bridge_transfer id<MTLBuffer>)g_stg[i].buf;
        gal_res_remove(staging); g_stg[i].buf = NULL;
    }
    free(g_stg); g_stg = NULL; g_nstg = 0; g_stg_cur = -1; g_stg_off = 0;
    memset(g_rmq, 0, sizeof g_rmq); atomic_store(&g_rm_head, 0); g_rm_tail = 0;
    g_buf_wser = 0; g_flush_pre = 0; g_wins = g_win_bytes = g_res_refused = 0;
}
GAL_MTL4_ZONE_END

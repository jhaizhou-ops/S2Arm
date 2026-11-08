// nvn_vk_poolahb.c 的宿主单测：AHB 池后备的准入、迁移事务与单调提交序号的退休语义。
//
// 为什么必须 -D__ANDROID__：生产实现 s2a_poolahb_enabled() 在非 Android 宿主上直接把 g_pa_on 置 0
// （见 nvn_vk_poolahb.c 的 #else 分支），不开这个宏连 s2a_poolahb_init 的准入都进不去，只能测到
// 「恒禁用」。Android 系统头（android/log.h、sys/system_properties.h）由 tests/hostvk 的宿主桩
// 提供；本文件只替身**外部依赖**（Vulkan 缓冲、适配层池表、tracking 合同、脏页跟踪），生产实现
// （nvn_vk_poolahb.c + vk_resid.c + poolahb_cover.c + poolahb_policy.c + poolahb_alias.c）全部真编。
//
// 覆盖（对应 PR #1378 复核退回意见：AHB 池在 GPU 仍读时被释放 / VUID-vkDestroyBuffer-buffer-00922）：
//   1. init 准入：caps.ahb=0 与 dev->ahb_import_enabled=0 两个分支分别关掉（各自独立进程，
//      因为生产实现把禁用状态缓存进 g_pa_on，同进程没法再翻回来）；都可用时 enabled()=1。
//   2. 迁移必须有 owner 证明：没有 s2a_poolahb_owner_note_writers_stopped(1) 时 service 拒绝，
//      且连 AHB 都没分配；给证明后能迁一个热池，迁完 lookup 命中且 buf/off 正确。
//   3. begin_seq 单调递增（不是「帧槽奇偶+1」那种只有两个值）。
//   4. 反例 A（不同提交号互不影响）：A、B 两个提交号引用同一后备，complete(A) 后不能销毁；
//      complete(B) 后恰好销毁一次，账本清零。
//   5. 反例 B（同号塌成一项）：同一提交号下两次 ref 只算一项，complete 一次就把两笔一起退休
//      ——这就是提交号必须单调递增的原因（否则延迟上屏时 N-1 与 N+1 撞号，一帧完成就销毁
//      GPU 仍在读的缓冲，即 VUID-vkDestroyBuffer-buffer-00922）。
//   6. 池删除语义：pool_removed 只标匹配 addr/len 的条目（长度不符不 retire）；新 lookup 立即
//      不命中（即使后备还在）；在途引用完成前不销毁。
//   7. 统计口径：misses == 各 miss_* 之和；established/refused 与实际行为一致。
//   8. shutdown 幂等、清账本；之后的 lookup 返回 -1。
//
// 另有 4 个回归用例（对应本轮修掉的生产缺陷，修前实现跑必红）：
//   D. 首帧前（还没有 begin_seq）lookup 必须 miss 且不登记在途引用（seq=0 → 保活登记 EINVAL）；
//      begin_seq 首帧从 1 开始、之后严格递增。
//   A. 迁移 a<b<c → 删除 a 并 reap（数组压缩）→ 再迁地址 > c 的 d：b/c/d 必须仍全部命中
//      （旧实现复用低位空槽 + 只左移 → 数组乱序 → 二分漏命中 d）。
//   B. 会话重建（shutdown→init）后同一 base 重新注册：不继承上一局的 failed/done
//      （旧实现会让该池永远 miss_pool_failed / 永远不再迁移）。
//   C. 迁移早退（cover 拒绝 / 事务失败）后一次性 owner 授权必须被消费：不带新证明再调
//      service 必须 -1 且不分配 AHB（旧实现残留授权会继续尝试）。
//
// 池地址用真实匿名 mmap（poolahb_cover_check_path 读真实 /proc/self/maps，且 4 KiB 对齐），
// 这样才能真的走通「覆盖判定 → AHB 事务」而不是把 cover 也替身掉。
// macOS 门禁机没有 /proc：下面的 s2a_poolahb_maps_path 按 mach_vm_region 枚举的真实区域写出同格式的表，
//   挖掉的空洞照样看得见（11-02 合入线：原先 Mac 上 fopen 失败、迁移一律被拒，234 项红 76）。
#define _DEFAULT_SOURCE 1

#include <stdarg.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <unistd.h>
#endif

#include "direct/vk_device.h"
#include "direct/vk_membuf.h"
#include "direct/vk_resid.h"
#include "mtl_vk_adapter.h"
#include "nvn_dirty.h"
#include "nvn_vk_poolahb.h"
#include "runtime/tracking/runtime.h"

static int g_fail, g_checks;
#define CHECK(cond) do { g_checks++; if (!(cond)) { g_fail++; \
    printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CASE(name) printf("  case %-34s", name)

#ifdef __APPLE__
// 生产实现里是弱符号、返回 /proc/self/maps。每次调用都按当前虚拟内存重写一遍（池会随用例增减）。
// 只写「地址区间 + 权限」，路径留空 = 匿名映射，与 Linux procfs 里匿名行同格式。
static char g_maps_file[256];
static void maps_file_rm(void) { if (g_maps_file[0]) unlink(g_maps_file); }
const char *s2a_poolahb_maps_path(void) {
    if (!g_maps_file[0]) {
        const char *t = getenv("TMPDIR");
        snprintf(g_maps_file, sizeof g_maps_file, "%s/vk_poolahb_maps.%d", t && t[0] ? t : "/tmp", (int)getpid());
        atexit(maps_file_rm);
    }
    FILE *f = fopen(g_maps_file, "w");
    if (!f) return g_maps_file;
    mach_vm_address_t a = 0;
    for (;;) {
        mach_vm_size_t sz = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (mach_vm_region(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
        fprintf(f, "%llx-%llx %c%c%cp 00000000 00:00 0\n", (unsigned long long)a, (unsigned long long)(a + sz),
                (info.protection & VM_PROT_READ) ? 'r' : '-', (info.protection & VM_PROT_WRITE) ? 'w' : '-',
                (info.protection & VM_PROT_EXECUTE) ? 'x' : '-');
        a += sz;
    }
    fclose(f);
    return g_maps_file;
}
#endif

// ---- 宿主 Android 桩（-D__ANDROID__ 编译生产实现时需要）--------------------
static int g_verbose;
int __system_property_get(const char *name, char *value) {
    (void)name;                        // 属性全未设置：debug.s2a.pool_ahb 走默认值
    if (value) value[0] = 0;
    return 0;
}
int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio; (void)tag;
    if (!g_verbose) return 0;          // 默认静默，S2A_POOLAHB_TEST_VERBOSE=1 时打到 stderr
    va_list ap;
    va_start(ap, fmt);
    fputs("[poolahb] ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    return 0;
}

// ---- 适配层池表替身（生产实现在 mtl_vk_adapter.c，按地址区间查池）----------
#define FAKE_POOLS 512
struct fake_pool { uint64_t base, len; };
static struct fake_pool g_fake_pools[FAKE_POOLS];
static int g_fake_pool_n;

static int fake_pool_add(uint64_t base, uint64_t len) {
    if (!len || g_fake_pool_n >= FAKE_POOLS) return -1;
    int pos = g_fake_pool_n;
    while (pos > 0 && g_fake_pools[pos - 1].base > base) {
        g_fake_pools[pos] = g_fake_pools[pos - 1];
        pos--;
    }
    if (pos > 0 && g_fake_pools[pos - 1].base == base) {
        // 会话重建后适配层会重新登记同一个池（base/len 相同）：幂等成功。
        return g_fake_pools[pos - 1].len == len ? 0 : -1;
    }
    g_fake_pools[pos].base = base;
    g_fake_pools[pos].len = len;
    g_fake_pool_n++;
    return 0;
}

int s2a_vk_adapter_pool_find(uint64_t addr, uint64_t len, uint64_t *base, uint64_t *size) {
    if (!len) return -1;
    int best = -1;
    for (int i = 0; i < g_fake_pool_n; i++) {
        if (g_fake_pools[i].base > addr) continue;
        if (best < 0 || g_fake_pools[i].base > g_fake_pools[best].base) best = i;
    }
    if (best < 0) return -1;
    uint64_t off = addr - g_fake_pools[best].base;
    if (off > g_fake_pools[best].len || len > g_fake_pools[best].len - off) return -1;   // 必须整段落在一个池内
    if (base) *base = g_fake_pools[best].base;
    if (size) *size = g_fake_pools[best].len;
    return 0;
}

void s2a_vk_adapter_pool_written(const void *mem, uint64_t off, uint64_t size) {
    (void)mem; (void)off; (void)size;
}

// ---- 内存能力/缓冲替身（生产实现在 direct/vk_membuf.c，需要真 Vulkan）------
static struct s2a_gpu_mem_caps g_caps;

const struct s2a_gpu_mem_caps *s2a_gpu_mem_caps_get(void) { return &g_caps; }

int s2a_gpu_mem_probe(struct s2a_vk_device *device, struct s2a_gpu_mem_caps *caps,
                      char *why, size_t why_size) {
    (void)device;
    if (caps) *caps = g_caps;
    if (why && why_size) why[0] = 0;
    return 0;
}

#define FAKE_BUFS 256
struct fake_buf {
    int used, destroyed;
    VkBuffer buf;
    void *cpu;
    VkDeviceSize size;
    int kind;
};
static struct fake_buf g_bufs[FAKE_BUFS];
static int g_buf_create_n, g_buf_destroy_n, g_buf_destroy_unknown;
static int g_buf_map_at_n;
static int g_map_at_fail_once;          // 注入一次 map_at 失败：让迁移事务走到回滚路径
static VkBuffer g_last_buf;

static struct fake_buf *fake_buf_find(VkBuffer b) {
    for (int i = 0; i < FAKE_BUFS; i++)
        if (g_bufs[i].used && g_bufs[i].buf == b) return &g_bufs[i];
    return NULL;
}

int s2a_gpu_buf_create(struct s2a_vk_device *device, VkDeviceSize size, VkBufferUsageFlags usage,
                       int kind, struct s2a_gpu_buf *out, char *why, size_t why_size) {
    (void)device; (void)usage;
    if (!out) return -1;
    if (why && why_size) why[0] = 0;
    for (int i = 0; i < FAKE_BUFS; i++) {
        if (g_bufs[i].used) continue;
        void *cpu = malloc((size_t)size);
        if (!cpu) return -1;
        memset(cpu, 0, (size_t)size);
        memset(&g_bufs[i], 0, sizeof g_bufs[i]);
        g_bufs[i].used = 1;
        g_bufs[i].buf = (VkBuffer)(uintptr_t)(0x10000u + (unsigned)i * 0x10u);
        g_bufs[i].cpu = cpu;
        g_bufs[i].size = size;
        g_bufs[i].kind = kind;
        memset(out, 0, sizeof *out);
        out->buf = g_bufs[i].buf;
        out->size = size;
        out->alloc_size = size;
        out->kind = kind;
        out->coherent = 1;
        out->mapped = 1;
        out->cpu = cpu;
        out->ahb = (void *)(uintptr_t)0xa1;
        out->fd = -1;
        g_buf_create_n++;
        g_last_buf = out->buf;
        return 0;
    }
    return -1;
}

int s2a_gpu_buf_import(struct s2a_vk_device *device, const void *host, VkDeviceSize size,
                       VkBufferUsageFlags usage, struct s2a_gpu_buf *out,
                       char *why, size_t why_size) {
    (void)device; (void)host; (void)size; (void)usage; (void)out;
    if (why && why_size) snprintf(why, why_size, "import not stubbed");
    return -1;
}

void s2a_gpu_buf_destroy(struct s2a_vk_device *device, struct s2a_gpu_buf *b) {
    (void)device;
    if (!b) return;
    struct fake_buf *f = fake_buf_find(b->buf);
    if (!f) {                      // 销毁了不该销毁的东西：测试按红处理
        g_buf_destroy_unknown++;
        b->cpu = NULL;
        b->buf = 0;
        return;
    }
    if (f->destroyed) {            // 重复销毁：测试按红处理
        g_buf_destroy_unknown++;
        return;
    }
    f->destroyed = 1;
    free(f->cpu);
    f->cpu = NULL;
    b->cpu = NULL;
    b->buf = 0;
    g_buf_destroy_n++;
}

int s2a_gpu_buf_map_at(struct s2a_gpu_buf *b, void *addr, size_t len, void **mapped,
                       char *why, size_t why_size) {
    (void)b; (void)len;
    if (why && why_size) why[0] = 0;
    g_buf_map_at_n++;
    if (g_map_at_fail_once) {
        g_map_at_fail_once = 0;
        if (why && why_size) snprintf(why, why_size, "injected map_at failure");
        return -1;
    }
    if (mapped) *mapped = addr;
    // 测试不要求真别名：guest 匿名页保持可写，后面的断言仍要读它（pa_copy 已把旧内容搬走）。
    return 0;
}

void s2a_gpu_buf_flush(struct s2a_vk_device *device, const struct s2a_gpu_buf *b,
                       VkDeviceSize off, VkDeviceSize len) {
    (void)device; (void)b; (void)off; (void)len;
}

void s2a_gpu_buf_invalidate(struct s2a_vk_device *device, const struct s2a_gpu_buf *b,
                            VkDeviceSize off, VkDeviceSize len) {
    (void)device; (void)b; (void)off; (void)len;
}

// ---- tracking 合同 / 脏页跟踪替身（生产实现在 runtime 与 graphics/nvn）----------
static int g_track_begin_n, g_track_end_committed_n, g_track_end_rolled_n;
static int g_dirty_n, g_dirty_replace_n;

int s2a_track_backing_begin(uint64_t addr, uint64_t size, uint64_t source) {
    (void)addr; (void)size; (void)source;
    g_track_begin_n++;
    return 0;
}

void s2a_track_backing_end(uint64_t addr, uint64_t size, int mapped, int committed) {
    (void)addr; (void)size; (void)mapped;
    if (committed) g_track_end_committed_n++;
    else g_track_end_rolled_n++;
}

void nvn_dirty_add_range(const void *mem, size_t size) {
    (void)mem; (void)size;
    g_dirty_n++;
}

// 本夹具只核对迁移是否调用换底接口；真实保护/代际由 t_dirty_chunk 覆盖。
int nvn_dirty_replace_range(const void *mem, size_t size) {
    (void)mem; (void)size;
    g_dirty_n++;
    g_dirty_replace_n++;
    return 1;
}

// 生产实现里是普通符号（Mach-O 上 weak 声明会链接失败）；宿主夹具给同口径替身：安卓直连 1 MiB / 4 KiB = 256 页。
uint32_t nvn_dirty_chunk_pages(void) { return 256u; }

// 弱引用在 Mach-O（macOS 门禁）上仍需要可解析：给宿主单测一个替身，走“恢复不了原背板”的回退路径。
// （生产实现是 runtime/vm/backing.c；本套用例不会触发回滚，替身只保证链接一致。）
int plat_backing_map(void *addr, size_t size, uint32_t plat_prot, uint64_t pgoff) {
    (void)addr; (void)size; (void)plat_prot; (void)pgoff;
    return -1;
}

// 同上：生产实现是 runtime/fault/thread_android.inc 的“本线程 epoch 是否只串行（不停其他 writer）”。
// 宿主替身默认 0（= 独占 epoch，允许迁移），与生产里的真证明路径一致；用例可切 1 压升级分支。
static int g_serial_only, g_quiesce_calls, g_quiesce_error;
#ifdef VK_POOLAHB_TEST_NO_QUIESCE_ENTRY
// 这个构建专门模拟“链接里没有 quiesce 入口”（安卓之外/旧链接才可能）：串行 epoch 恒为真，
// quiesce 符号不存在 → 生产代码必须“拒迁但返回 0”，不能当成协调失败终止 svc。
int s2a_android_guest_writers_serial_only(void) { return 1; }
#else
int s2a_android_guest_writers_serial_only(void) { return g_serial_only; }
// 串行 epoch 的升级入口（生产：把只串行事务升级为全体停稳）。替身可记次数、可注入失败。
int s2a_android_guest_writers_quiesce(void) { g_quiesce_calls++; return g_quiesce_error; }
#endif

// ---- 测试驱动 ---------------------------------------------------------------
#define POOL_LEN (256ull << 10)     // 单个池 256 KiB：4 KiB 对齐、远小于 PA_POOL_MAX(64 MiB)
#define CHUNK 4096ull
#define HOT_LOOKUPS 40              // 40 × 4 KiB = 160 KiB；service 会先衰减一半 → 80 KiB ≥ 64 KiB 门槛

static struct s2a_vk_device g_dev;

struct test_pool { uint64_t base, len; };

static struct s2a_poolahb_stats pa_stats(void) {
    struct s2a_poolahb_stats s;
    memset(&s, 0, sizeof s);
    s2a_poolahb_stats_get(&s);
    return s;
}

static uint64_t miss_sum(const struct s2a_poolahb_stats *s) {
    return s->miss_no_pool + s->miss_cold + s->miss_pool_failed +
           s->miss_range_unregistered + s->miss_ref_full + s->miss_table_full;
}

// 每次用例开始都重置：生产实现有全局状态（含 owner 一次性授权），shutdown 后重新 init。
static void session_reset(void) {
    s2a_poolahb_owner_note_writers_stopped(0);
    s2a_poolahb_shutdown();
}

static int session_start(void) {
    session_reset();
    memset(&g_dev, 0, sizeof g_dev);
    g_dev.ahb_import_enabled = 1;
    return s2a_poolahb_init(&g_dev);
}

// 适配层登记 + 建立点（池地址由调用者给：连续 arena 切分时用）。
static int pool_register(struct test_pool *p, uint64_t base, uint64_t len) {
    p->base = base;
    p->len = len;
    if (!base || base % CHUNK || !len || len % CHUNK) return -1;
    if (fake_pool_add(base, len) != 0) return -1;
    return s2a_poolahb_establish(base, len);   // 对齐的候选：只登记候选，不迁移
}

// 池 = 真实匿名映射（cover 判定读 /proc/self/maps，不能替身）+ 适配层池表登记 + 建立点。
// 故意不 munmap 正常池：地址释放后可能被后续 mmap 复用，会和 g_pa_pool 里的历史条目撞车。
static int pool_open(struct test_pool *p, uint64_t len) {
    void *m = mmap(NULL, (size_t)len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return -1;
    memset(m, 0x5a, (size_t)len);       // 可辨认的旧内容（pa_copy 会整段 memcpy 进 AHB 后备）
    return pool_register(p, (uint64_t)(uintptr_t)m, len);
}

// 覆盖不足的池：映射整段再挖掉后半，cover 判定读真实 maps 会看到空洞 → 拒绝迁移。
static int pool_open_hole(struct test_pool *p, uint64_t len) {
    if (len < 2 * CHUNK || len % (2 * CHUNK)) return -1;
    void *m = mmap(NULL, (size_t)len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return -1;
    memset(m, 0x5a, (size_t)len);
    uint64_t half = len / 2;
    if (munmap((void *)((uintptr_t)m + half), (size_t)(len - half)) != 0) return -1;
    return pool_register(p, (uint64_t)(uintptr_t)m, len);
}

// 连续匿名 arena：切出来的池地址顺序确定（A 回归需要 a < b < c < d）。
static int arena_open(void **out, uint64_t total) {
    void *m = mmap(NULL, (size_t)total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return -1;
    memset(m, 0x5a, (size_t)total);
    *out = m;
    return 0;
}

// 冷池制造「热」：每笔 lookup 都是 miss_cold，累计 bytes/refs，供 service 选池。
static int pool_lookups(const struct test_pool *p, int n) {
    int chunks = (int)(p->len / CHUNK);
    for (int i = 0; i < n; i++) {
        VkBuffer buf = 0;
        uint64_t off = 0;
        uint64_t at = p->base + (uint64_t)(i % chunks) * CHUNK;
        if (s2a_poolahb_lookup(at, CHUNK, &buf, &off) != -1) return -1;   // 未迁移时必须 miss
    }
    return 0;
}

static int service_migrate(void) {
    s2a_poolahb_owner_note_writers_stopped(1);   // owner 证明：writers 已停稳
    return s2a_poolahb_service();
}

// 生产入口：runtime/src/svc_mem.c 的 backing_begin_locked() 弱调用它。
// 新版本头文件已声明；这里保留一份本地声明，保证拿旧版头文件（HEAD，红-绿对照）也能编。
extern int s2a_android_mem_owner_window(void);

// ===========================================================================
// D 回归：首帧（第一次 begin_seq）之前没有提交序号，lookup 必须回退上传（miss）且不登记在途引用。
// 注意：g_pa_seq 只在**进程内**第一次 begin_seq 之前为 0（会话重建不重置单调序号），
// 所以本用例必须排在 core 的第一个。
static void case_lookup_before_commit_seq(void) {
    CASE("lookup_before_commit_seq");
    CHECK(session_start() == 0);

    struct test_pool p;
    CHECK(pool_open(&p, POOL_LEN) == 0);
    CHECK(pool_lookups(&p, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);                 // 迁移本身不需要提交序号

    struct s2a_poolahb_stats s0 = pa_stats();
    struct s2a_res_stats r0;
    s2a_res_stats_get(&r0);
    VkBuffer buf = (VkBuffer)(uintptr_t)0x1234ull;
    uint64_t off = 0x1234ull;
    CHECK(s2a_poolahb_lookup(p.base, CHUNK, &buf, &off) == -1);   // 安全回退：不能拿零拷贝结果
    CHECK(buf == (VkBuffer)(uintptr_t)0x1234ull && off == 0x1234ull);   // 失败时不给出 buf/off
    struct s2a_poolahb_stats s1 = pa_stats();
    struct s2a_res_stats r1;
    s2a_res_stats_get(&r1);
    CHECK(s1.misses == s0.misses + 1);
    CHECK(s1.miss_ref_full == s0.miss_ref_full + 1);              // 保活登记被拒（seq=0 → EINVAL）
    CHECK(r1.refs_committed == r0.refs_committed);                // 没有登记任何在途引用

    uint64_t seq = s2a_poolahb_begin_seq();
    CHECK(seq == 1);                              // 初值 0：首帧从 1 开始（不与“无序号”同号）
    CHECK(s2a_poolahb_lookup(p.base, CHUNK, &buf, &off) == 0);    // 有提交序号后才命中
    CHECK(off == 0);
    s2a_poolahb_complete_seq(seq);
    printf("ok (无序号时 miss_ref_full=%llu 且 refs 不涨；begin_seq 首个=%llu 后命中)\n",
           (unsigned long long)(s1.miss_ref_full - s0.miss_ref_full), (unsigned long long)seq);
}

static void case_migration_requires_owner_proof(void) {
    CASE("migration_requires_owner_proof");
    CHECK(session_start() == 0);
    CHECK(s2a_poolahb_enabled() == 1);

    struct test_pool p;
    CHECK(pool_open(&p, POOL_LEN) == 0);
    CHECK(pool_lookups(&p, HOT_LOOKUPS) == 0);    // 冷池：先积累热度（misses/refs）

    struct s2a_poolahb_stats before = pa_stats();
    CHECK(before.misses >= HOT_LOOKUPS);          // 每笔都是 miss，且分类到 miss_cold
    CHECK(before.miss_cold == (uint64_t)HOT_LOOKUPS);
    CHECK(before.established == 0);

    int creates = g_buf_create_n;
    CHECK(s2a_poolahb_service() == -1);           // 没有 owner 证明：拒绝迁移
    CHECK(g_buf_create_n == creates);             // 连 AHB 都没分配，不是「分配了再回滚」

    VkBuffer buf = 0;
    uint64_t off = 0;
    CHECK(s2a_poolahb_lookup(p.base, CHUNK, &buf, &off) == -1);   // 仍未迁移

    int tb = g_track_begin_n, tec = g_track_end_committed_n, ter = g_track_end_rolled_n;
    int dirty = g_dirty_n, replaced = g_dirty_replace_n, mapat = g_buf_map_at_n;
    CHECK(service_migrate() == 1);                // 给证明后迁一个热池
    CHECK(g_buf_create_n == creates + 1);         // 恰好分配一个 AHB 后备
    CHECK(g_track_begin_n == tb + 1);             // 合同 begin/end 严格配对
    CHECK(g_track_end_committed_n == tec + 1);
    CHECK(g_track_end_rolled_n == ter);
    CHECK(g_dirty_n == dirty + 1);                // 换页后重建了脏页跟踪
    CHECK(g_dirty_replace_n == replaced + 1);     // 必须替换旧跟踪，不能追加同址条目
    CHECK(g_buf_map_at_n == mapat + 1);           // 真做了「映射到指定地址」这一步

    // 生产顺序：帧首 begin_seq 之后才录制 draw（lookup）；有提交序号才能登记在途保活。
    uint64_t seq = s2a_poolahb_begin_seq();
    CHECK(seq != 0);
    CHECK(s2a_poolahb_lookup(p.base + 0x2000, CHUNK, &buf, &off) == 0);
    CHECK(buf == g_last_buf);                     // 命中给出的是迁移后的 AHB 缓冲
    CHECK(off == 0x2000);                         // 偏移按池内偏移算
    struct s2a_poolahb_stats after = pa_stats();
    CHECK(after.established == 1);
    CHECK(after.misses == before.misses + 1);     // 上面那笔命中不再记 miss
    CHECK(after.lookups == 1);
    CHECK(after.hit_bytes == CHUNK);
    s2a_poolahb_complete_seq(seq);
    printf("ok (命中 buf=%#llx off=%#llx, established=%llu)\n",
           (unsigned long long)(uintptr_t)buf, (unsigned long long)off,
           (unsigned long long)after.established);
}

static void case_begin_seq_monotonic(void) {
    CASE("begin_seq_monotonic");
    CHECK(session_start() == 0);
    uint64_t first = s2a_poolahb_begin_seq();
    CHECK(first != 0);
    uint64_t prev = first;
    int distinct = 1;
    for (int i = 0; i < 5; i++) {
        uint64_t s = s2a_poolahb_begin_seq();
        CHECK(s > prev);                // 严格递增：旧「帧槽奇偶+1」只会有两个值
        if (s > prev) distinct++;
        prev = s;
    }
    CHECK(distinct == 6);               // 6 次调用得到 6 个互不相同的号
    printf("ok (%llu → %llu, 6 个号互不相同且递增)\n",
           (unsigned long long)first, (unsigned long long)prev);
}

// 反例 A：不同提交号互不影响。A 完成后 B 仍保活，后备绝不能销毁。
static void case_two_seqs_independent(void) {
    CASE("counterexample_two_seqs");
    CHECK(session_start() == 0);

    struct test_pool p;
    CHECK(pool_open(&p, POOL_LEN) == 0);
    CHECK(pool_lookups(&p, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);

    // 两个不同的提交（延迟上屏时 N-1 与 N+1 会同时在途）各引用同一后备。
    struct s2a_res_stats r0;
    s2a_res_stats_get(&r0);
    uint64_t seq_a = s2a_poolahb_begin_seq();
    VkBuffer buf = 0;
    uint64_t off = 0;
    CHECK(s2a_poolahb_lookup(p.base, CHUNK, &buf, &off) == 0);
    uint64_t seq_b = s2a_poolahb_begin_seq();
    CHECK(seq_b != seq_a);
    CHECK(s2a_poolahb_lookup(p.base + CHUNK, CHUNK, &buf, &off) == 0);
    struct s2a_res_stats r1;
    s2a_res_stats_get(&r1);
    CHECK(r1.refs_committed == r0.refs_committed + 2);   // 两个提交各一项保活

    struct s2a_res_ref ref;
    CHECK(s2a_res_lookup(p.base, CHUNK, &ref) == S2A_RES_OK);
    int busy = 0;
    CHECK(s2a_res_backing_busy(ref.backing_id, &busy) == S2A_RES_OK && busy == 1);

    int d0 = g_buf_destroy_n;
    s2a_poolahb_pool_removed(p.base, p.len);      // 池删除：新命中立即停
    VkBuffer miss_buf = 0;
    uint64_t miss_off = 0;
    CHECK(s2a_poolahb_lookup(p.base, CHUNK, &miss_buf, &miss_off) == -1);
    CHECK(g_buf_destroy_n == d0);                 // 还有在途引用：不能销毁

    // 帧边界只负责切号/迁移前置条件，绝不在这里做「完成证明」（延迟 present 时 fence 还没等到）。
    s2a_poolahb_frame_boundary(seq_b + 1);
    CHECK(g_buf_destroy_n == d0);
    CHECK(s2a_res_backing_busy(ref.backing_id, &busy) == S2A_RES_OK && busy == 1);

    s2a_poolahb_complete_seq(seq_a);              // A 完成
    int d_after_a = g_buf_destroy_n;
    CHECK(d_after_a == d0);                       // B 仍持有 → 绝不能 destroy（否则 GPU 读到已释放缓冲）
    CHECK(s2a_res_backing_busy(ref.backing_id, &busy) == S2A_RES_OK && busy == 1);

    s2a_poolahb_complete_seq(seq_b);              // B 完成
    int d_after_b = g_buf_destroy_n;
    CHECK(d_after_b == d0 + 1);                   // 恰好销毁一次
    CHECK(fake_buf_find(g_last_buf) && fake_buf_find(g_last_buf)->destroyed == 1);
    CHECK(s2a_res_backing_busy(ref.backing_id, &busy) == S2A_RES_OK && busy == 0);
    struct s2a_res_ref gone;
    CHECK(s2a_res_lookup(p.base, CHUNK, &gone) == S2A_RES_ENOENT);   // 账本清零

    s2a_poolahb_complete_seq(seq_a);              // 重复完成是幂等的，不能再次销毁
    CHECK(g_buf_destroy_n == d_after_b);
    CHECK(g_buf_destroy_unknown == 0);
    printf("ok (seqA=%llu seqB=%llu；complete(A)后 destroy=%d，complete(B)后 destroy=%d)\n",
           (unsigned long long)seq_a, (unsigned long long)seq_b,
           d_after_a - d0, d_after_b - d0);
}

// 反例 B：同号塌成一项。同一提交号下两次 ref 只登记一项，complete 一次就把两笔一起退休。
static void case_same_seq_collapse(void) {
    CASE("counterexample_same_seq");
    CHECK(session_start() == 0);

    struct test_pool p;
    CHECK(pool_open(&p, POOL_LEN) == 0);
    CHECK(pool_lookups(&p, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);

    // 模拟「旧实现帧槽奇偶+1」撞号：两个本该独立的提交拿到同一个号，各引用一次同一后备。
    uint64_t seq = s2a_poolahb_begin_seq();
    struct s2a_res_stats r0;
    s2a_res_stats_get(&r0);
    VkBuffer buf = 0;
    uint64_t off = 0;
    CHECK(s2a_poolahb_lookup(p.base, CHUNK, &buf, &off) == 0);          // 第 1 笔
    CHECK(s2a_poolahb_lookup(p.base + CHUNK, CHUNK, &buf, &off) == 0);  // 第 2 笔（同号）
    struct s2a_res_stats r1;
    s2a_res_stats_get(&r1);
    CHECK(r1.refs_committed == r0.refs_committed + 1);   // 两笔 ref 塌成一项（幂等合并）

    struct s2a_res_ref ref;
    CHECK(s2a_res_lookup(p.base, CHUNK, &ref) == S2A_RES_OK);
    int d0 = g_buf_destroy_n;
    s2a_poolahb_pool_removed(p.base, p.len);
    CHECK(g_buf_destroy_n == d0);
    s2a_poolahb_complete_seq(seq);               // 只完成一次 → 两笔一起退休
    CHECK(g_buf_destroy_n == d0 + 1);
    int busy = 1;
    CHECK(s2a_res_backing_busy(ref.backing_id, &busy) == S2A_RES_OK && busy == 0);
    printf("ok (同号两笔 ref 只占 1 项；complete 一次即销毁，destroy=%d)\n",
           g_buf_destroy_n - d0);
    printf("    → 这就是提交号必须单调递增的原因：撞号时另一笔仍在 GPU 读的引用被一起清掉，\n"
           "      会销毁仍在使用的后备（VUID-vkDestroyBuffer-buffer-00922）。\n");
}

// 池删除语义：只标匹配 addr/len 的条目；新 lookup 立即不命中；在途未完成前不销毁。
static void case_pool_removed_semantics(void) {
    CASE("pool_removed_semantics");
    CHECK(session_start() == 0);
    // 本用例的所有命中保活都记在这个提交号下（否则 complete 只清得掉一部分，
    // 更早的命中会用上一个用例残留的号，destroy 就永远等不到「没人引用」）。
    uint64_t seq = s2a_poolahb_begin_seq();

    struct test_pool a, b;
    CHECK(pool_open(&a, POOL_LEN) == 0);
    CHECK(pool_open(&b, POOL_LEN) == 0);

    CHECK(pool_lookups(&a, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);               // 每次 service 只迁一个池
    VkBuffer buf = 0;
    uint64_t off = 0;
    CHECK(s2a_poolahb_lookup(a.base + CHUNK, CHUNK, &buf, &off) == 0);

    CHECK(pool_lookups(&b, HOT_LOOKUPS) == 0);
    CHECK(s2a_android_mem_owner_window() == 0);  // 生产真实入口：内部给 owner 证明 + service
    CHECK(s2a_poolahb_lookup(b.base + CHUNK, CHUNK, &buf, &off) == 0);

    CHECK(s2a_poolahb_lookup(a.base, CHUNK, &buf, &off) == 0);   // A 的在途引用（记在 seq 下）
    int d0 = g_buf_destroy_n;

    // 长度不符：不是这条窗口，什么都不 retire。
    s2a_poolahb_pool_removed(a.base, a.len + CHUNK);
    CHECK(s2a_poolahb_lookup(a.base, CHUNK, &buf, &off) == 0);   // 仍命中
    CHECK(g_buf_destroy_n == d0);
    // 精确 addr/len：只 retire A。
    s2a_poolahb_pool_removed(a.base, a.len);
    CHECK(s2a_poolahb_lookup(a.base, CHUNK, &buf, &off) == -1);  // 新 lookup 立即不命中
    CHECK(s2a_poolahb_lookup(b.base, CHUNK, &buf, &off) == 0);   // B 不受影响
    CHECK(g_buf_destroy_n == d0);                                // A 在途引用还没完成

    s2a_poolahb_complete_seq(seq);
    CHECK(g_buf_destroy_n == d0 + 1);                            // 只释放 A
    CHECK(s2a_poolahb_lookup(b.base, CHUNK, &buf, &off) == 0);   // B 依然可用
    CHECK(g_buf_destroy_unknown == 0);
    printf("ok (长度不符不 retire；精确删除后 A 立即 miss、B 仍命中；destroy=%d)\n",
           g_buf_destroy_n - d0);
}


// A 回归：g_pa_live 必须始终保持 [0, n) 紧凑有序。旧实现「最低空槽 + 只左移」在回收低槽后
// 复用给更大地址的窗口时会乱序，二分查找漏命中（修复前实测：迁成功却查不到，永久丢零拷贝）。
static void case_live_order_regression(void) {
    CASE("live_order_regression");
    CHECK(session_start() == 0);

    void *arena = NULL;
    CHECK(arena_open(&arena, 4 * POOL_LEN) == 0);
    uint64_t base = (uint64_t)(uintptr_t)arena;
    struct test_pool a, b, c, d;
    CHECK(pool_register(&a, base, POOL_LEN) == 0);
    CHECK(pool_register(&b, base + POOL_LEN, POOL_LEN) == 0);
    CHECK(pool_register(&c, base + 2 * POOL_LEN, POOL_LEN) == 0);
    CHECK(pool_register(&d, base + 3 * POOL_LEN, POOL_LEN) == 0);

    VkBuffer buf = 0;
    uint64_t off = 0;
    CHECK(pool_lookups(&a, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);
    VkBuffer exp_a = g_last_buf;
    CHECK(pool_lookups(&b, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);
    VkBuffer exp_b = g_last_buf;
    CHECK(pool_lookups(&c, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);
    VkBuffer exp_c = g_last_buf;
    // 本用例所有命中保活记在同一提交号下（否则更早的命中会用上一个用例残留的号，
    // complete 清不掉它，a 的后备就永远等不到“没人引用”）。
    uint64_t seq = s2a_poolahb_begin_seq();
    CHECK(s2a_poolahb_lookup(a.base + CHUNK, CHUNK, &buf, &off) == 0 && buf == exp_a);

    // 删除 a 并拿到完成证明：reap 释放条目，数组压缩成 [b, c]。
    CHECK(s2a_poolahb_lookup(a.base, CHUNK, &buf, &off) == 0);    // a 的在途引用
    int d0 = g_buf_destroy_n;
    s2a_poolahb_pool_removed(a.base, a.len);
    s2a_poolahb_complete_seq(seq);
    CHECK(g_buf_destroy_n == d0 + 1);                             // 只释放 a
    CHECK(s2a_poolahb_lookup(a.base, CHUNK, &buf, &off) == -1);

    // 再迁一块地址比 c 更大的池 d：旧实现会把 d 放进被腾空的低位槽且只左移 → 数组乱序。
    CHECK(pool_lookups(&d, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);
    VkBuffer exp_d = g_last_buf;
    CHECK(s2a_poolahb_lookup(b.base + CHUNK, CHUNK, &buf, &off) == 0 && buf == exp_b && off == CHUNK);
    CHECK(s2a_poolahb_lookup(c.base + CHUNK, CHUNK, &buf, &off) == 0 && buf == exp_c && off == CHUNK);
    CHECK(s2a_poolahb_lookup(d.base + CHUNK, CHUNK, &buf, &off) == 0 && buf == exp_d && off == CHUNK);
    printf("ok (删 a 后迁 d：b/c/d 仍全部命中，a 已 miss)\n");
}

// B 回归：会话重建（shutdown→init）必须清掉池统计表，同 base 重新注册不能继承上一局的 failed/done，
// 否则该池在新会话里永远 miss_pool_failed / 永远不再迁移（旧实现的两处泄漏）。
static void case_session_rebuild_reset(void) {
    CASE("session_rebuild_reset");
    CHECK(session_start() == 0);
    VkBuffer buf = 0;
    uint64_t off = 0;

    // (1) 迁移失败过（cover 拒绝）的池：会话重建后重新登记，miss 原因必须回到 cold。
    struct test_pool h;
    CHECK(pool_open_hole(&h, 2 * POOL_LEN) == 0);
    CHECK(pool_lookups(&h, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == -1);                              // cover 拒绝
    CHECK(s2a_poolahb_lookup(h.base, CHUNK, &buf, &off) == -1);
    struct s2a_poolahb_stats before_rebuild = pa_stats();
    CHECK(before_rebuild.miss_pool_failed == 1);

    CHECK(session_start() == 0);                                 // shutdown + init
    CHECK(fake_pool_add(h.base, h.len) == 0);                    // 适配层重新登记同一个池
    CHECK(s2a_poolahb_establish(h.base, h.len) == 0);
    struct s2a_poolahb_stats s0 = pa_stats();
    CHECK(pool_lookups(&h, HOT_LOOKUPS) == 0);
    struct s2a_poolahb_stats s1 = pa_stats();
    CHECK(s1.miss_cold == s0.miss_cold + HOT_LOOKUPS);           // 重新变回 cold（旧实现：pool_failed）
    CHECK(s1.miss_pool_failed == s0.miss_pool_failed);
    CHECK(service_migrate() == -1);                              // 能再进候选（仍被 cover 拒绝），不是被 failed 跳过

    // (2) 已迁移过（done）的池：会话重建后同 base 重新注册必须能再次进入候选并迁移。
    CHECK(session_start() == 0);
    struct test_pool y;
    CHECK(pool_open(&y, POOL_LEN) == 0);
    CHECK(pool_lookups(&y, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);
    uint64_t seq = s2a_poolahb_begin_seq();
    CHECK(s2a_poolahb_lookup(y.base, CHUNK, &buf, &off) == 0);
    s2a_poolahb_pool_removed(y.base, y.len);
    s2a_poolahb_complete_seq(seq);                               // reap 释放
    CHECK(s2a_poolahb_lookup(y.base, CHUNK, &buf, &off) == -1);

    CHECK(session_start() == 0);                                 // 会话重建
    CHECK(fake_pool_add(y.base, y.len) == 0);
    CHECK(s2a_poolahb_establish(y.base, y.len) == 0);
    struct s2a_poolahb_stats t0 = pa_stats();
    CHECK(pool_lookups(&y, HOT_LOOKUPS) == 0);
    struct s2a_poolahb_stats t1 = pa_stats();
    CHECK(t1.miss_cold == t0.miss_cold + HOT_LOOKUPS);           // 旧实现：done → miss_range_unregistered
    CHECK(t1.miss_range_unregistered == t0.miss_range_unregistered);
    CHECK(service_migrate() == 1);                               // done 不再继承 → 能再次迁移
    CHECK(s2a_poolahb_lookup(y.base + CHUNK, CHUNK, &buf, &off) == 0);
    printf("ok (failed/done 都不跨会话继承：重建后重新 cold 并可再次迁移)\n");
}

// C 回归：owner 授权是一次性的，迁移“早退”（cover/alias 拒绝、事务失败）也必须消费掉。
// 旧实现只在成功路径清 g_pa_owner_ready，下一次不带证明的 service 会拿残留授权继续迁移。
// 复核必改第 2 条：没有待迁移窗口时绝不升级 writer epoch。
// 加载期 0x2C 增页很密，只要「有串行 epoch 就先 quiesce」，等于把每次增页都变成全体停稳，
// 原本的快路径整个被抹掉。因此 owner 窗口必须先用原子计数判断「有没有活」。
static void case_owner_window_skips_quiesce_without_pending(void) {
    CASE("owner_window_skips_quiesce_without_pending");
    CHECK(session_start() == 0);
    g_serial_only = 1; g_quiesce_calls = 0; g_quiesce_error = 0;

    int creates = g_buf_create_n, tb = g_track_begin_n;
    CHECK(s2a_android_mem_owner_window() == 0);   // 池表全空：没有待迁移槽
    CHECK(g_quiesce_calls == 0);                  // 一次都不许停世界
    CHECK(g_buf_create_n == creates);             // 也没开始任何事务
    CHECK(g_track_begin_n == tb);

    // 反向对照：真的有待迁移槽、但窗口只有串行 epoch → 不是安全点，**延期**迁移，
    // 既不升级停世界（旧策略在补编压力下 2 s 会到期、撤销 epoch），也不开始事务。
    struct test_pool p;
    CHECK(pool_open(&p, POOL_LEN) == 0);
    CHECK(pool_lookups(&p, HOT_LOOKUPS) == 0);
    g_quiesce_calls = 0;
    CHECK(s2a_android_mem_owner_window() == 0);   // 延期不是错误，映射事务继续
    CHECK(g_quiesce_calls == 0);                  // 一次都不许为可选迁移停世界
    CHECK(g_track_begin_n == tb);                 // 也没有开始迁移事务
    VkBuffer pending = 0;
    uint64_t pending_off = 0;
    CHECK(s2a_poolahb_lookup(p.base + CHUNK, CHUNK, &pending, &pending_off) == -1);   // 仍未迁移
    // 真正的全体停稳窗口（serial_only=0）里同一批 pending 必须迁掉：延期不等于放弃
    g_serial_only = 0;
    CHECK(s2a_android_mem_owner_window() == 0);
    CHECK(g_track_begin_n == tb + 1);
    CHECK(s2a_poolahb_lookup(p.base + CHUNK, CHUNK, &pending, &pending_off) == 0);
    // 迁完之后又没有活了：不得再停世界
    g_quiesce_calls = 0;
    CHECK(s2a_android_mem_owner_window() == 0);
    CHECK(g_quiesce_calls == 0);
    printf("ok (无 pending 不动；串行窗不升级只延期；全体停稳窗迁掉；迁完不再动)\n");
}

// 复核必改第 1 条（已按新合同改写）：串行窗口不升级停世界 → 迁移延期、映射事务继续；
// 到期风险不再存在，因此这里不再有“升级失败往上抛”的分支。真正的安全点（全体停稳窗口）
// 到达后同一批 pending 必须迁掉，延期不留粘滞状态。
static void case_owner_window_defers_on_serial_epoch(void) {
    CASE("owner_window_defers_on_serial_epoch");
    CHECK(session_start() == 0);
    g_serial_only = 1; g_quiesce_calls = 0;

    struct test_pool p;
    CHECK(pool_open(&p, POOL_LEN) == 0);
    CHECK(pool_lookups(&p, HOT_LOOKUPS) == 0);
    int creates = g_buf_create_n, tb = g_track_begin_n;
    CHECK(s2a_android_mem_owner_window() == 0);          // 延期不是错误：普通增页继续
    CHECK(g_quiesce_calls == 0);                         // 不为可选迁移停世界
    CHECK(g_buf_create_n == creates);                    // 没有开始任何迁移事务
    CHECK(g_track_begin_n == tb);
    VkBuffer buf = 0;
    uint64_t off = 0;
    CHECK(s2a_poolahb_lookup(p.base + CHUNK, CHUNK, &buf, &off) == -1);   // 仍未迁移
    CHECK(s2a_poolahb_service() == -1);                  // 延期不留 owner 证明

    // 下一个全体停稳窗口：同一批 pending 照常迁掉
    g_serial_only = 0;
    CHECK(s2a_android_mem_owner_window() == 0);
    CHECK(g_track_begin_n == tb + 1);
    CHECK(s2a_poolahb_lookup(p.base + CHUNK, CHUNK, &buf, &off) == 0);
    printf("ok (串行窗延期、不停世界、不留证明；全体停稳窗迁掉)\n");
}

static void case_owner_grant_consumed(void) {
    CASE("owner_grant_consumed");
    CHECK(session_start() == 0);
    VkBuffer buf = 0;
    uint64_t off = 0;

    // (1) cover 拒绝的早退
    struct test_pool h;
    CHECK(pool_open_hole(&h, 2 * POOL_LEN) == 0);
    CHECK(pool_lookups(&h, HOT_LOOKUPS) == 0);
    int creates = g_buf_create_n;
    CHECK(service_migrate() == -1);                              // 给证明也没迁成（cover 拒绝）
    CHECK(g_buf_create_n == creates);                            // 连 AHB 都没分配
    CHECK(s2a_poolahb_service() == -1);                          // 不带新证明：必须 -1
    CHECK(g_buf_create_n == creates);

    // (2) 事务失败的早退：注入一次 map_at 失败 → 回滚释放新后备 → 授权同样被消费
    struct test_pool e;
    CHECK(pool_open(&e, POOL_LEN) == 0);
    CHECK(pool_lookups(&e, HOT_LOOKUPS) == 0);
    int destroys = g_buf_destroy_n;
    g_map_at_fail_once = 1;
    CHECK(service_migrate() == -1);                              // 事务失败
    CHECK(g_buf_create_n == creates + 1);                        // 分配过新后备
    CHECK(g_buf_destroy_n == destroys + 1);                      // 回滚已释放（不留半迁移）
    CHECK(s2a_poolahb_service() == -1);                          // 授权已消费
    CHECK(g_buf_create_n == creates + 1);                        // 没有再分配

    // (3) 带证明才迁
    struct test_pool f;
    CHECK(pool_open(&f, POOL_LEN) == 0);
    CHECK(pool_lookups(&f, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);
    CHECK(s2a_poolahb_lookup(f.base + CHUNK, CHUNK, &buf, &off) == 0);
    printf("ok (cover/事务早退后无证明 service=-1 且不分配 AHB；带证明才迁)\n");
}

// 统计口径：misses == 各 miss_* 之和；established/refused 与实际行为一致。
static void case_stats_accounting(void) {
    CASE("stats_accounting");
    CHECK(session_start() == 0);
    VkBuffer buf = 0;
    uint64_t off = 0;

    // (a) 地址不在任何已注册池 → miss_no_pool
    CHECK(s2a_poolahb_lookup(0x100000000ull, CHUNK, &buf, &off) == -1);
    // (b) 未对齐的 establish → refused（这是唯一会记 refused 的准入拒绝）
    CHECK(s2a_poolahb_establish(0x12345678ull, CHUNK) == -1);
    struct s2a_poolahb_stats s = pa_stats();
    CHECK(s.miss_no_pool == 1);
    CHECK(s.refused == 1 && s.established == 0);

    // (c) 覆盖不足的池：mmap 一块后挖掉上半，cover 判定读真实 maps 会看到空洞 → 拒绝迁移。
    //     这条路径只标 ps->failed（诊断计数 g_fail_multi），不计 refused。
    void *hole = mmap(NULL, (size_t)(2 * POOL_LEN), PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(hole != MAP_FAILED);
    memset(hole, 0x5a, (size_t)(2 * POOL_LEN));
    CHECK(munmap((void *)((uintptr_t)hole + POOL_LEN), (size_t)POOL_LEN) == 0);
    struct test_pool d;
    d.base = (uint64_t)(uintptr_t)hole;
    d.len = 2 * POOL_LEN;
    CHECK(fake_pool_add(d.base, d.len) == 0);
    CHECK(s2a_poolahb_establish(d.base, d.len) == 0);
    CHECK(pool_lookups(&d, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == -1);              // 覆盖不足：事务不启动
    s = pa_stats();
    CHECK(s.established == 0);
    CHECK(s.refused == 1);                       // 覆盖不足不计 refused（口径见日志里的失败原因）

    // (d) 池迁移失败过 → 后续 lookup 记 miss_pool_failed
    CHECK(s2a_poolahb_lookup(d.base, CHUNK, &buf, &off) == -1);
    s = pa_stats();
    CHECK(s.miss_pool_failed == 1);

    // (e) 正常池迁移成功 → established +1，之后命中不再记 miss
    struct test_pool c;
    CHECK(pool_open(&c, POOL_LEN) == 0);
    CHECK(pool_lookups(&c, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);
    CHECK(s2a_poolahb_lookup(c.base + CHUNK, CHUNK, &buf, &off) == 0);
    // (f) 池删除后再 lookup → 该池已标失败 → miss_pool_failed
    s2a_poolahb_pool_removed(c.base, c.len);
    CHECK(s2a_poolahb_lookup(c.base, CHUNK, &buf, &off) == -1);

    s = pa_stats();
    CHECK(s.misses == miss_sum(&s));             // 核心口径：各原因之和恰好等于 misses
    CHECK(s.miss_cold == (uint64_t)(2 * HOT_LOOKUPS));
    CHECK(s.miss_pool_failed == 2);
    CHECK(s.miss_range_unregistered == 0);
    CHECK(s.miss_ref_full == 0);
    CHECK(s.miss_table_full == 0);
    CHECK(s.established == 1);
    CHECK(s.refused == 1);
    CHECK(s.lookups >= 1);
    printf("ok (misses=%llu=各原因和, cold=%llu failed=%llu no_pool=%llu, established=%llu refused=%llu)\n",
           (unsigned long long)s.misses, (unsigned long long)s.miss_cold,
           (unsigned long long)s.miss_pool_failed, (unsigned long long)s.miss_no_pool,
           (unsigned long long)s.established, (unsigned long long)s.refused);
}

// shutdown 幂等、清账本；之后的 lookup 返回 -1。
static void case_shutdown_idempotent(void) {
    CASE("shutdown_idempotent");
    CHECK(session_start() == 0);

    struct test_pool p;
    CHECK(pool_open(&p, POOL_LEN) == 0);
    CHECK(pool_lookups(&p, HOT_LOOKUPS) == 0);
    CHECK(service_migrate() == 1);

    uint64_t seq = s2a_poolahb_begin_seq();
    VkBuffer buf = 0;
    uint64_t off = 0;
    CHECK(s2a_poolahb_lookup(p.base, CHUNK, &buf, &off) == 0);    // 在途引用
    struct s2a_res_ref ref;
    CHECK(s2a_res_lookup(p.base, CHUNK, &ref) == S2A_RES_OK);
    (void)seq;

    int d0 = g_buf_destroy_n;
    s2a_poolahb_shutdown();                      // 第一次
    CHECK(g_buf_destroy_n == d0 + 1);            // 迁移窗口的后备被清掉
    int busy = 1;
    CHECK(s2a_res_backing_busy(ref.backing_id, &busy) == S2A_RES_OK && busy == 0);
    struct s2a_res_ref gone;
    CHECK(s2a_res_lookup(p.base, CHUNK, &gone) == S2A_RES_ENOENT);   // 账本清空

    s2a_poolahb_shutdown();                      // 第二次：幂等，不崩、不重复销毁
    CHECK(g_buf_destroy_n == d0 + 1);

    CHECK(s2a_poolahb_lookup(p.base, CHUNK, &buf, &off) == -1);      // 之后的 lookup 返回 -1
    CHECK(g_buf_destroy_unknown == 0);
    printf("ok (两次 shutdown，销毁 %d 次，账本清空，之后 lookup=-1)\n", g_buf_destroy_n - d0);
}

// 内部池统计表满：新池 lookup 必须报 miss_table_full（不能静默当成 cold）。
static void case_pool_table_exhaustion(void) {
    CASE("pool_table_exhaustion");
    CHECK(session_start() == 0);
    int i = 0, saw_full = 0, table_ok = 1;
    // 这些地址不需要真映射：只走 miss 分类，不解引用。
    for (i = 0; i < 200; i++) {
        uint64_t base = 0x400000000ull + (uint64_t)i * 0x100000ull;
        if (fake_pool_add(base, 0x100000ull) != 0) break;
        struct s2a_poolahb_stats before = pa_stats();
        VkBuffer buf = 0;
        uint64_t off = 0;
        if (s2a_poolahb_lookup(base, CHUNK, &buf, &off) != -1) { table_ok = 0; break; }
        struct s2a_poolahb_stats after = pa_stats();
        if (after.miss_table_full > before.miss_table_full) { saw_full = 1; break; }
        if (after.miss_cold != before.miss_cold + 1) { table_ok = 0; break; }
    }
    CHECK(table_ok);
    CHECK(saw_full);
    // B 修复（init/shutdown 清池表）后本用例从空表开始：前 64 个新池占满 PA_POOLS=64 槽，
    // 第 65 个触发 miss_table_full。旧实现不清池表，会带着前面用例累积的条目提前触发
    // （旧实现 + 本套用例顺序下实测第 47 个），而且每次会话重建的残留数量都可能不同。
    CHECK(i + 1 == 65);
    struct s2a_poolahb_stats s = pa_stats();
    CHECK(s.misses == miss_sum(&s));
    printf("ok (第 %d 个新池触发 miss_table_full；B 修复后从空表开始，PA_POOLS=64 → 固定第 65 个)\n",
           i + 1);
}

static void run_core(void) {
    case_lookup_before_commit_seq();  // 必须第一：要观察“还没有任何提交序号”的初始状态
    case_migration_requires_owner_proof();
    case_begin_seq_monotonic();
    case_two_seqs_independent();
    case_same_seq_collapse();
    case_pool_removed_semantics();
    case_live_order_regression();     // A
    case_session_rebuild_reset();     // B
    case_owner_grant_consumed();      // C
    case_owner_window_skips_quiesce_without_pending();
    case_owner_window_defers_on_serial_epoch();
    case_stats_accounting();
    case_shutdown_idempotent();
    case_pool_table_exhaustion();     // 会占满内部池表（64 槽），放最后
}

// 准入单测：禁用状态会被生产实现缓存进 g_pa_on，所以每个分支都用独立进程跑。
static int run_admission(const char *mode) {
    memset(&g_caps, 0, sizeof g_caps);
    memset(&g_dev, 0, sizeof g_dev);
    if (!strcmp(mode, "admission-ok")) {
        g_caps.ahb = 1;
        g_dev.ahb_import_enabled = 1;
        CASE("admit_ahb_available");
        CHECK(s2a_poolahb_init(&g_dev) == 0);
        CHECK(s2a_poolahb_enabled() == 1);
        CHECK(s2a_poolahb_establish(0x100000000ull, CHUNK) == 0);   // 对齐候选：准入
        printf("ok (caps.ahb=1 import_enabled=1)\n");
    } else if (!strcmp(mode, "admission-ahb0")) {
        g_caps.ahb = 0;
        g_dev.ahb_import_enabled = 1;
        CASE("reject_caps_ahb_zero");
        CHECK(s2a_poolahb_init(&g_dev) == -1);
        CHECK(s2a_poolahb_enabled() == 0);
        CHECK(s2a_poolahb_establish(0x100000000ull, CHUNK) == -1);  // 禁用后不再接候选
        CHECK(s2a_poolahb_service() == -1);
        CHECK(s2a_poolahb_begin_seq() == 0);                        // 禁用时不算提交号
        printf("ok (caps.ahb=0 → init<0, enabled()=0)\n");
    } else if (!strcmp(mode, "admission-importoff")) {
        g_caps.ahb = 1;
        g_dev.ahb_import_enabled = 0;
        CASE("reject_import_disabled");
        CHECK(s2a_poolahb_init(&g_dev) == -1);
        CHECK(s2a_poolahb_enabled() == 0);
        CHECK(s2a_poolahb_establish(0x100000000ull, CHUNK) == -1);
        printf("ok (import_enabled=0 → init<0, enabled()=0)\n");
    } else {
        return 2;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "core";
    g_verbose = getenv("S2A_POOLAHB_TEST_VERBOSE") != NULL;
    // 默认设备支持 AHB 且允许导入；禁用分支由各 admission-* 模式单独覆盖。
    memset(&g_caps, 0, sizeof g_caps);
    memset(&g_dev, 0, sizeof g_dev);
    g_caps.ahb = 1;
    g_dev.ahb_import_enabled = 1;
    int rc = 0;
    if (!strcmp(mode, "owner-window-no-quiesce")) {
        // 复核（非阻塞项）：quiesce 入口不存在时 epoch 并没有被撤销，窗口必须**拒迁并返回 0**，
        // 不能当成协调失败（EOPNOTSUPP）往上抛、让调用方终止这次 svc。
        CHECK(session_start() == 0);
        struct test_pool p;
        CHECK(pool_open(&p, POOL_LEN) == 0);
        CHECK(pool_lookups(&p, HOT_LOOKUPS) == 0);        // 有 pending 槽（否则窗口直接早退）
        int creates = g_buf_create_n;
        CHECK(s2a_android_mem_owner_window() == 0);       // 返回 0 = 不改映射、也不算协调失败
        CHECK(g_buf_create_n == creates);                 // 没分配 AHB → 真的没迁
        CHECK(s2a_poolahb_lookup(p.base + CHUNK, CHUNK, &(VkBuffer){0}, &(uint64_t){0}) == -1);
    } else if (!strcmp(mode, "core")) {
        run_core();
        CHECK(g_buf_destroy_unknown == 0);       // 全程没有重复销毁/销毁未知缓冲
    } else {
        rc = run_admission(mode);
    }
    if (rc == 2) {
        fprintf(stderr, "unknown mode: %s\n", mode);
        return 2;
    }
    printf("%s: 检查 %d 项，失败 %d 项 → %s\n",
           mode, g_checks, g_fail, g_fail ? "红" : "通过");
    return g_fail ? 1 : 0;
}

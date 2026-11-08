// 贴图初始内容判全 0（nvn_mtl.m tex_init_fill → mem_any_touched）不读游戏从没碰过的页。
// 背景（11-05 时之笛 Switch 2 版 iPhone 读档进场景被系统杀，实占 7339 MB 里客体窗口 6616 MB）：新建 GPU 贴图都要判存储是否全 0，原先 mem_any 整段读一遍；
//   宿主内核对没写过的匿名页一读就给一页零页、计进进程实占（M5 Pro 实测：512 MB 未写匿名内存逐页读一遍 phys_footprint +512 MB），
//   游戏没写过的渲染目标 / 图像存储白白进足迹。
// 期望（按宿主内核行为与 Switch 语义手写，不由被测实现推出；不经 Metal，读数不受 GPU 驻留影响）：
//   ① 新映射 64 MB 匿名内存（同客体新内存，没写过）：判为全 0；判完常驻 / 压缩页 0；进程实占增量 < 1 MB
//   ② 同一段第 40 MB + 5 字节写一个非 0 字节：判为非 0
//   ③ 另一段 64 MB 只往第 3 页写 0（碰过、内容仍是 0）：判为全 0，且只有那 1 页常驻
//   ④ 判断区段不从页首开始、也不到页尾（贴图存储 512 字节对齐）：区段外同页里的非 0 字节不算
#include "../gfx/nvn/nvn_mtl.m"
#include <mach/mach.h>

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static int64_t footprint(void) { task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; REQUIRE(task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c) == KERN_SUCCESS); return (int64_t)i.phys_footprint; }
static uint64_t touched(const void *p, size_t n) {
    size_t pg = (size_t)getpagesize(), np = (n + pg - 1) / pg; unsigned char *v = malloc(np); REQUIRE(v && !mincore((void *)p, n, (char *)v));
    uint64_t r = 0; for (size_t i = 0; i < np; i++) if (v[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT)) r += pg; free(v); return r;
}
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        enum { N = 64 << 20 };
        size_t pg = (size_t)getpagesize();
        uint8_t *a = mmap(NULL, N, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), *b = mmap(NULL, N, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        REQUIRE(a != MAP_FAILED && b != MAP_FAILED);
        int64_t f0 = footprint(); int r = mem_any_touched(a, N); int64_t df = footprint() - f0;
        CHECK(r == 0, "① 未写 64 MB：判为全 0（返回 %d）", r);
        CHECK(touched(a, N) == 0, "① 判完常驻 / 压缩 %llu KB（期望 0）", (unsigned long long)(touched(a, N) >> 10));
        CHECK(df < (1 << 20), "① 判这 64 MB 前后进程实占 +%lld KB（期望 < 1024 KB；整段读会 +65536 KB）", (long long)(df >> 10));
        a[(40u << 20) + 5] = 7;
        CHECK(mem_any_touched(a, N) == 1, "② 第 40 MB + 5 字节非 0：判为非 0");
        memset(b + 3 * pg, 0, 16);
        CHECK(mem_any_touched(b, N) == 0 && touched(b, N) == pg, "③ 只往第 3 页写 0：判为全 0，常驻 %llu KB（期望 %zu KB）", (unsigned long long)(touched(b, N) >> 10), pg >> 10);
        b[5 * pg + 100] = 9; b[6 * pg - 100] = 9;   // 第 5 页里区段外的两个非 0 字节
        CHECK(mem_any_touched(b + 5 * pg + 512, pg - 1024) == 0, "④ 页内区段 [512, 页长 − 512)：区段外的非 0 字节不算，判为全 0");
        CHECK(mem_any_touched(b + 5 * pg + 64, pg - 1024) == 1, "④ 区段 [64, …) 盖住第 100 字节：判为非 0");
        printf("%s t_nvn_initfill_untouched: %u checks %u failures; untouched bytes not read %llu MB\n", failures ? "✗" : "✓", checks, failures, (unsigned long long)(g_fill_untouched_bytes >> 20));
        return failures != 0;
    }
}

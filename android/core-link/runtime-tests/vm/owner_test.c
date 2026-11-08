// 改表断言单测（#619 P1-1 加固）：Linux ARM64 上把生产 runtime/src/svc_mem.c 按 __ANDROID__ 编进来，外部依赖全部最小桩。
//   ① 起局建表（还没进过 svc_mem）在 VM epoch 外改表：放行；② 进入运行期后在 epoch 内改表：放行；
//   ③ 运行期在 epoch 外改表（= 新改表的系统调用没登记进 svc_mem() 的 backing 列表）：必须当场终止。旧 svc_mem.c 在 ③ 静默改表 → 本单测红。
//   用法见 run_owner.sh。不依赖 graphics/track（同目录 run.py 的整套夹具要 track_platform.h，main 上缺）
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

void s2a_mem_test_setup(uint64_t alias_base, uint64_t alias_size, uint64_t win_base, uint64_t win_size, void *heap, uint64_t heap_cur);
void s2a_mem_test_map(uint64_t b, uint64_t n);
int svc_mem(int num, uint64_t *regs, uint64_t orig);

static int held;
int s2a_android_vm_writer_held(void) { return held; }
int s2a_android_guest_writers_begin(void) { return 0; }
int s2a_android_guest_writers_begin_serial(void) { return 0; }
int s2a_android_guest_writers_quiesce(void) { return 0; }
// 此夹具只验证 writer epoch，镜像由独立真实 VM 测试验证。
void s2a_android_mirror_init(uintptr_t a, size_t n) { (void)a; (void)n; }
void s2a_android_mirror_begin(uintptr_t a, size_t n) { (void)a; (void)n; }
void s2a_android_mirror_end(uintptr_t a, size_t n, int m, int c) { (void)a; (void)n; (void)m; (void)c; }
void s2a_android_mirror_report(const char *w) { (void)w; }
void s2a_android_mirror_region(uintptr_t *b, size_t *n) { if (b) *b = 0; if (n) *n = 0; }
int s2a_android_mirror_enabled(void) { return 0; }
unsigned s2a_android_guest_writers_epoch(void) { return (unsigned)held; }
int s2a_track_backing_busy(void) { return 0; }
int s2a_track_store32_claim(uint64_t a, uint8_t *p) { (void)a; (void)p; return -EOPNOTSUPP; }
void s2a_track_store32_release(uint64_t a, uint8_t p, int w) { (void)a; (void)p; (void)w; }
int s2a_track_platform_alias(uintptr_t a, size_t n, int p, void **out) { (void)a; (void)n; (void)p; if (out) *out = NULL; return EOPNOTSUPP; }
int s2a_track_platform_unalias(void *a, size_t n) { (void)a; (void)n; return 0; }
void s2a_track_backing_reset_before_publish(uint64_t a, uint64_t n) { (void)a; (void)n; }
void s2a_android_guest_writers_end(void) {}
int s2a_android_guest_writers_ready(void) { return 1; }
void s2a_android_guest_park_forever(void) { abort(); }
int s2a_svc_stopping(void) { return 0; }
// 其余外部符号：本单测走不到它们的语义，给最小桩
void *g_mod; int g_nmod;
uint64_t guest_tick(void) { return 0; }
void *module_of(void *p) { (void)p; return NULL; }
int plat_layout_override(void) { return 95; }
size_t plat_page_size(void) { return 4096; }
int plat_vm_alias(void *a, void *b, size_t n, int p) { (void)a; (void)b; (void)n; (void)p; return 0; }
void s2a_backtrace(void) {}
int s2a_det_shmem_map(void) { return 0; }
uint64_t s2a_det_tick(uint64_t v) { return v; }
uint64_t s2a_entropy64(void) { return 0; }
int s2a_handle_kind_count(int k) { (void)k; return 0; }
void s2a_host_shutdown(const char *why) { (void)why; exit(3); }
int s2a_layout_compute(void) { return -1; }
uint64_t s2a_layout_need(void) { return 0; }
void s2a_low_holes(uint64_t *t, uint64_t *b) { *t = *b = 0; }
uint64_t s2a_module_span(void) { return 0; }
uint32_t s2a_native_handle_new(void) { return 0; }
void *s2a_native_handle_obj(void) { return NULL; }
uint64_t s2a_process_id(void) { return 0x51; }
void *s2a_shmem_lookup(void) { return NULL; }
int s2a_svc_check_perm(void) { return 0; }
void *s2a_svc_frame(void) { return NULL; }
void s2a_svc_red(void) {}
void s2a_svc_ryu_missing(void) {}
int s2a_thread_alive_count(void) { return 1; }
uint64_t s2a_thread_cpu_ns(void) { return 0; }
int s2a_thread_cur_core(void) { return 0; }
void s2a_thread_set_caps(void) {}
void s2a_thread_set_npdm(void) {}
void *s2a_tmem_get(void) { return NULL; }
int s2a_track_backing_begin(uint64_t a, uint64_t n, uint64_t s) { (void)a; (void)n; (void)s; return 0; }
void s2a_track_backing_end(uint64_t a, uint64_t n, int m, int c) { (void)a; (void)n; (void)m; (void)c; }
void s2a_track_prot_changed(uint64_t a, uint64_t n) { (void)a; (void)n; }
void s2a_track_write(uint64_t a, uint64_t n) { (void)a; (void)n; }
int s2a_track_set_guest_protection(uint64_t a, uint64_t n, int p) { (void)a; (void)n; (void)p; return 0; }
void s2a_window_get(uint64_t *b, uint64_t *s) { *b = *s = 0; }
void s2a_window_trim(void) {}
// 生产 os.c:152-155 同口径：缺省 19.2 MHz，Switch 2 NPDM 起局可 set(31.25 MHz)。
static uint64_t g_tick_hz = 19200000;
void s2a_guest_tick_hz_set(uint64_t h) { g_tick_hz = h; }
uint64_t s2a_ns_to_tick(uint64_t ns) { return (uint64_t)((unsigned __int128)ns * g_tick_hz / 1000000000u); }
// 生产 thread.c:230-231 同口径：核号校验上界缺省 4、可设。
static int g_hw_cores = 4;
void s2a_thread_set_hw_cores(int n) { if (n > 0 && n <= 64) g_hw_cores = n; }
int s2a_thread_hw_cores(void) { return g_hw_cores; }
// 生产 layout.c:38-39 同口径：应用池大小可设。
static uint64_t g_app_pool;
uint64_t s2a_app_pool(void) { return g_app_pool; }
void s2a_app_pool_set(uint64_t v) { g_app_pool = v; }

static int fails;
#define CHECK(c, what) do { if (c) printf("  ok %s\n", what); else { printf("  ✗ %s\n", what); fails++; } } while (0)

// 子进程里改一次表，返回：0 = 正常返回，SIGABRT = 断言终止
static int child_map(uint64_t b) {
    pid_t p = fork();
    if (!p) { s2a_mem_test_map(b, 0x1000); _exit(0); }
    int st; waitpid(p, &st, 0);
    return WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st) ? -WEXITSTATUS(st) : 0;
}

int main(void) {
    uint8_t *w = mmap(NULL, 16u << 20, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (w == MAP_FAILED) { puts("mmap 失败"); return 2; }
    s2a_mem_test_setup((uintptr_t)w + 0xc00000, 0x200000, (uintptr_t)w, 16u << 20, w + 0x400000, 0);
    CHECK(child_map((uintptr_t)w + 0x100000) == 0, "① 起局建表（还没进过 svc_mem）在 epoch 外改表：放行");
    uint64_t regs[32] = {0, 0, (uintptr_t)w};   // QueryMemory 不回写：只为进入运行期
    svc_mem(0x06, regs, 0);
    held = 1;
    CHECK(child_map((uintptr_t)w + 0x200000) == 0, "② 运行期、在 epoch 内改表：放行");
    held = 0;
    CHECK(child_map((uintptr_t)w + 0x300000) == SIGABRT, "③ 运行期、在 epoch 外改表（漏登记）：当场终止");
    printf("%s owner_test：%d 处不符\n", fails ? "✗" : "✓", fails);
    return fails != 0;
}

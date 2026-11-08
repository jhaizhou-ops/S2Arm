// 明确合成的其它 core provider；被测 VM、metadata、tracker、内核映射均用真实生产源。
// S2A_VM_REAL_OS_ENDPOINTS：本夹具链接真实 os.c 时定义，跳过 guest_tick/s2a_entropy64 合成替身。
void s2a_backtrace(uint64_t fp) { (void)fp; }
#ifndef S2A_PAGE_TEST_REAL_DET
int s2a_det_shmem_map(uint64_t ga, const void *h, uint64_t n, uint64_t sp, int pr) { (void)ga; (void)h; (void)n; (void)sp; (void)pr; return 0; }
uint64_t s2a_det_tick(uint64_t t) { return t; }
#endif
#ifndef S2A_VM_REAL_OS_ENDPOINTS
uint64_t s2a_entropy64(void) { return 0; }
#endif
void s2a_host_shutdown(const char *w) { (void)w; }
void s2a_low_holes(uint64_t *t, uint64_t *l) { *t = *l = 0; } uint64_t s2a_process_id(void) { return 0x51; } void *s2a_shmem_lookup(uint32_t h, uint64_t *s) { if (h != 71) return NULL; *s = logical_size; return source; }
void s2a_svc_frame(uint64_t pc) { (void)pc; } void s2a_svc_red(int n, const uint64_t *r, uint64_t o, const char *w) { (void)n; (void)r; (void)o; (void)w; }
int s2a_thread_alive_count(void) { return 0; } void s2a_thread_set_npdm(int c, int p) { (void)c; (void)p; } uint32_t s2a_native_handle_new(uint32_t s, void *o) { assert(s == 2); code_object = o; return 73; } void *s2a_native_handle_obj(uint32_t h, uint32_t s) { return h == 73 && s == 2 ? code_object : NULL; } void s2a_handle_kind_count(uint32_t k, int *c, int *p) { (void)k; *c = *p = 0; } static uint64_t tmem_addr; static uint64_t tmem_size; static int tmem_closed;
int s2a_tmem_get(uint32_t h, uint64_t *a, uint64_t *n, uint32_t *p) { if (h != 72 || tmem_closed) return 0; *a=tmem_addr?tmem_addr:(uint64_t)source; *n=tmem_size?tmem_size:logical_size; *p=3; return 1; } void s2a_thread_set_caps(uint64_t c, uint64_t p) { (void)c; (void)p; } uint64_t s2a_thread_cpu_ns(uint32_t h, int *ok) { (void)h; *ok = 0; return 0; } int s2a_thread_cur_core(void) { return 0; }
#ifndef S2A_VM_REAL_OS_ENDPOINTS
uint64_t guest_tick(void) { return 0; }
#endif
module_t *module_of(const void *p) { (void)p; return NULL; }
void s2a_window_get(uint64_t *b, uint64_t *s) { *b = *s = 0; } void s2a_window_trim(uint64_t s) { (void)s; }

// 137fa新增NPDM诊断；该夹具使用显式测试布局，不调用s2a_mem_init。
int s2a_svc_check_perm(const uint64_t p[3], char *out, size_t cap) { (void)p; (void)out; (void)cap; assert(!"unexpected NPDM parser in VM fixture"); return -1; }
int s2a_svc_ryu_missing(int n) { (void)n; assert(!"unexpected NPDM parser in VM fixture"); return -1; }

// 这个 VM 夹具没有停机会话；真实 g_park/永久 park 由相邻 writers-gate 夹具覆盖。
int s2a_svc_stopping(void) { return 0; }
_Noreturn void s2a_android_guest_park_forever(void) { assert(!"unexpected shutdown park in VM fixture"); abort(); }
// VM fixture never loads modules; do not turn an unexpected call into success.
uint64_t s2a_module_span(const char *path) { (void)path; assert(!"unexpected module span in VM fixture"); abort(); }

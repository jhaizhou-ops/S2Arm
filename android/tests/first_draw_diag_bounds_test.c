// #1229（P0-9）首绘诊断边界验收夹具，宿主编译跑：
//   A1) 修前基线复刻（仅 192 字节属性串拼接，子进程跑）——16+ 启用 location
//       让 off 越过缓冲尾后 sizeof a - off 无符号回绕，ASan 报栈越界。
//   A2) 修前基线复刻（仅客机内存读取，子进程跑）——索引/顶点缓冲末尾贴
//       PROT_NONE 页，无长度依据的读取直接吃 SIGSEGV。
//   B)  生产 s2a_first_draw_diag：同样构造，不越界、不读保护页，日志照常出。
//   B2) vbuf_size 恰好盖住 3 * stride + 16 时照常读，合法数据不丢。
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../native/direct/vk_record.h"
#include "../native/nvn/nvn_vk_draw_diag.h"

static int log_calls;
static size_t log_max_line;
static int log_truncated;
static char log_text[65536];
// 出口复刻生产 fd_diag_log：先按生产容量截断，再把整行交给日志 sink。
static void sink(const char *fmt, ...) {
    char line[8192];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (n < 0) { log_truncated = 1; log_calls++; return; }
    if ((size_t)n > log_max_line) log_max_line = (size_t)n;
    char msg[S2A_FIRST_DRAW_DIAG_MSG_CAP];
    if ((size_t)n >= sizeof msg || (size_t)n >= sizeof line) log_truncated = 1;
    size_t ncopy = (size_t)n < sizeof msg - 1 ? (size_t)n : sizeof msg - 1;
    memcpy(msg, line, ncopy);
    msg[ncopy] = 0;
    size_t used = strlen(log_text);
    if (used < sizeof log_text - 1) snprintf(log_text + used, sizeof log_text - used, "%s\n", msg);
    log_calls++;
}

// —— A1：修前属性串拼接原样（snprintf 返回值无界前进） ——
static void diag_buggy_attr(const struct s2a_record_draw_state *state,
                            uint32_t attr_mask, void (*log)(const char *, ...)) {
    char a[192] = "";
    int off = 0;
    for (int loc = 0; loc < 32; loc++) {
        if (!(attr_mask & (1u << loc))) continue;
        off += snprintf(a + off, sizeof a - (size_t)off, "loc%d=f%d@%u/s%u ", loc,
                        state->vattr[loc].format, state->vattr[loc].offset,
                        state->vattr[loc].stream);
    }
    log("buggy attr[%s]", a);
}

// —— A2：修前客机内存读取原样（索引按 count 读、顶点按 stride 读，均不看记录长度） ——
static void diag_buggy_reads(const struct s2a_record_draw_state *state,
                             void (*log)(const char *, ...)) {
    uint32_t idx[8] = {0};
    if (state->index_address && state->count) {
        size_t n = state->count < 8 ? state->count : 8;
        uint32_t isz = state->index_type == 0 ? 1 : state->index_type == 1 ? 2 : 4;
        for (size_t i = 0; i < n; i++) {
            const uint8_t *ip = (const uint8_t *)(uintptr_t)state->index_address + i * isz;
            if (state->index_type == 0) idx[i] = *ip;
            else if (state->index_type == 1) { uint16_t v; memcpy(&v, ip, 2); idx[i] = v; }
            else memcpy(&idx[i], ip, 4);
        }
    }
    float v0[4] = {0};
    int16_t s3[4] = {0};
    uint32_t stride0 = state->vstream_stride[0];
    if (state->vbuf_addr[0] && stride0) {
        memcpy(v0, (const void *)(uintptr_t)state->vbuf_addr[0], 16);
        memcpy(s3, (const void *)(uintptr_t)(state->vbuf_addr[0] + 3 * stride0), 8);
    }
    log("buggy reads idx0=%u v0=(%.1f,%.1f) s3_0=%d", idx[0], v0[0], v0[1], s3[0]);
}

static uint8_t *guard_backed_vbuf(size_t page) {
    // 两页映射：第二页 PROT_NONE；返回第一页首地址，记录长度故意短于实际读取范围。
    uint8_t *m = mmap(NULL, 2 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); exit(2); }
    if (mprotect(m + page, page, PROT_NONE)) { perror("mprotect"); exit(2); }
    return m;
}

static void fill_state(struct s2a_record_draw_state *st, uint8_t *m, size_t page) {
    memset(st, 0, sizeof *st);
    for (int loc = 0; loc < 32; loc++) {
        st->vattr[loc].format = 1;
        st->vattr[loc].offset = 0;
        st->vattr[loc].stream = 0;
    }
    st->count = 8;
    st->index_type = 2;                       // 4 字节索引
    st->index_address = (uint64_t)(uintptr_t)(m + page - 4);  // 读第 2 个索引即撞保护页
    st->vstream_stride[0] = 16;
    st->vbuf_addr[0] = (uint64_t)(uintptr_t)(m + page - 8);   // memcpy 16B 必然越页
    st->vbuf_size[0] = 8;                     // 只记了 8 字节：3*16+16=64 盖不住
}

static int run_child(void (*fn)(void)) {
    pid_t pid = fork();
    if (pid == 0) { fn(); _exit(0); }   // 没死 = 夹具构造无效
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFSIGNALED(status)) return 0;
    return WTERMSIG(status);
}

static struct s2a_record_draw_state g_st;
static void child_attr(void) { diag_buggy_attr(&g_st, 0xFFFFFu, sink); }
static void child_reads(void) { diag_buggy_reads(&g_st, sink); }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    // 建议项：出口缓冲下限 1024。当前 20 个 location 的一行约 358 B，512 余量太薄，
    // 更长 request id / 将来加字段就会截掉属性串尾部。
    if (S2A_FIRST_DRAW_DIAG_MSG_CAP < 1024) {
        fprintf(stderr, "FAIL diag log buffer %d B < 1024 B\n", S2A_FIRST_DRAW_DIAG_MSG_CAP);
        return 1;
    }
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    uint8_t *m = guard_backed_vbuf(page);
    fill_state(&g_st, m, page);

    // A1) 修前属性串：子进程里应带信号死掉（ASan 栈越界）。
    int sig = run_child(child_attr);
    if (!sig) { fprintf(stderr, "FAIL buggy attr list did not crash\n"); return 1; }
    printf("buggy attr list crashed as expected (signal %d)\n", sig);

    // A2) 修前客机读取：子进程里应带信号死掉（保护页 SIGSEGV）。
    sig = run_child(child_reads);
    if (!sig) { fprintf(stderr, "FAIL buggy guest reads did not crash\n"); return 1; }
    printf("buggy guest reads crashed as expected (signal %d)\n", sig);

    // B) 生产实现：同一份 20 个启用 location + 危险缓冲，必须安全跑完、日志照出。
    log_calls = 0; log_text[0] = 0;
    s2a_first_draw_diag(&g_st, 0xFFFFFu, "req-fixed", sink);
    if (log_calls == 0) { fprintf(stderr, "FAIL fixed diag produced no output\n"); return 1; }
    if (!strstr(log_text, "attr[loc0")) { fprintf(stderr, "FAIL attr list missing loc0\n%s\n", log_text); return 1; }
    if (strstr(log_text, "loc19")) { fprintf(stderr, "FAIL attr overflowed past buffer end\n%s\n", log_text); return 1; }
    if (!strstr(log_text, "idx=?")) { fprintf(stderr, "FAIL unrecorded index bytes were read\n%s\n", log_text); return 1; }
    // 建议项：最长一行（固定段 + 属性串 + request id）必须整行落得下生产出口的缓冲。
    if (log_truncated) {
        fprintf(stderr, "FAIL diag line truncated at %d B (need %zu B)\n",
                S2A_FIRST_DRAW_DIAG_MSG_CAP, log_max_line + 1);
        return 1;
    }
    printf("worst diag line %zu B fits %d B log buffer\n", log_max_line + 1,
           S2A_FIRST_DRAW_DIAG_MSG_CAP);
    printf("fixed diag survived: %d log calls, no guard-page read\n", log_calls);

    // B2) vbuf_size 盖得住时照常读：整页可读的缓冲 + 已知 float 内容。
    uint8_t *full = calloc(1, page);
    float fv[8] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f};
    memcpy(full, fv, sizeof fv);
    memset(&g_st, 0, sizeof g_st);
    g_st.vstream_stride[0] = 16;
    g_st.vbuf_addr[0] = (uint64_t)(uintptr_t)full;
    g_st.vbuf_size[0] = 64;   // == 3*16+16，恰好盖过最远一次 memcpy
    log_calls = 0; log_text[0] = 0;
    s2a_first_draw_diag(&g_st, 0, "req-readable", sink);
    if (!strstr(log_text, "v0=(1.0,2.0,3.0,4.0)")) {
        fprintf(stderr, "FAIL bounded read lost legit data\n%s\n", log_text);
        return 1;
    }
    printf("bounded read kept legit data\n");

    printf("first_draw_diag_bounds_test: OK\n");
    return 0;
}

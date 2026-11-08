// 日志层防刷屏 + 滚动（runtime/src/logcap.c；11-07 测试机2 金刚挂死后一局刷 1.6 万行红行）。期望值手写：
//   ① 同一条红行（只差栅栏号 / 地址）写 50 次：文件里只有前 8 条 + 汇总行（「压掉同类红行」，不超过 2 行：每秒至多一行）；
//      10 条各不相同的红行全留；负对照：同样内容但不是红行的 50 行全留（只管红行）。
//   ② 上限缩到 1 MB（头 128 KB、留尾 256 KB）写 3 MB：文件 ≤ 上限 + 一次检查间隔；第一行（起局）还在；最后一行还在；有滚动标记行
#include "../src/native.h"
#include "s2a_t_result.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

extern uint64_t s2a_logcap_test_cap, s2a_logcap_test_head, s2a_logcap_test_keep;
static int bad;
#define CHECK(c, ...) do { int ok_ = !!(c); if (!ok_) bad++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static char *slurp(const char *p, size_t *n) {
    int fd = open(p, O_RDONLY); struct stat st; if (fd < 0 || fstat(fd, &st)) return NULL;
    char *b = malloc((size_t)st.st_size + 1); ssize_t r = read(fd, b, (size_t)st.st_size); close(fd); b[r > 0 ? r : 0] = 0; *n = r > 0 ? (size_t)r : 0; return b;
}
static int count(const char *h, const char *needle) { int c = 0; for (const char *p = h; (p = strstr(p, needle)); p += strlen(needle)) c++; return c; }
static void emit(int fd, const char *fmt, unsigned v) { char b[512]; int n = snprintf(b, sizeof b, fmt, v, v * 7919u); s2a_log_out(fd, b, (size_t)n); }

int main(void) {
    char p1[] = "/tmp/t_logcap_a_XXXXXX"; int fd = mkstemp(p1); if (fd < 0) return 2;
    fcntl(fd, F_SETFL, O_APPEND);
    for (unsigned i = 0; i < 50; i++) emit(fd, "[dm] [nvn-mtl] 【红】 command buffer error details fence=%u: Discarded (victim) 0x%x\n", 6700 + i);
    for (unsigned i = 0; i < 10; i++) { char b[128]; int n = snprintf(b, sizeof b, "[s2a] 【红】不同的红行 %c 类\n", 'a' + i); s2a_log_out(fd, b, (size_t)n); }
    for (unsigned i = 0; i < 50; i++) emit(fd, "[dm] [nvn-mtl] upload batch %u done at 0x%x\n", i);
    s2a_log_out(fd, "[s2a] 【红】收尾一行\n", strlen("[s2a] 【红】收尾一行\n"));   // 触发待打的汇总
    close(fd);
    size_t n; char *s = slurp(p1, &n);
    int same = count(s, "\n[dm] [nvn-mtl] 【红】 command buffer error details") + !strncmp(s, "[dm] [nvn-mtl] 【红】 command buffer error details", strlen("[dm] [nvn-mtl] 【红】 command buffer error details")), sum = count(s, "压掉同类红行"), diff = count(s, "不同的红行"), plain = count(s, "upload batch");
    CHECK(same == 8, "同一条红行写 50 次只留前 8 条（实际 %d）", same);
    CHECK(sum >= 1 && sum <= 2, "压掉的有汇总行，每秒至多一行（实际 %d 行）", sum);
    CHECK(diff == 10, "10 条各不相同的红行全留（实际 %d）", diff);
    CHECK(plain == 50, "负对照：非红行 50 行全留（实际 %d）", plain);
    free(s); unlink(p1);

    s2a_logcap_test_cap = 1u << 20; s2a_logcap_test_head = 128u << 10; s2a_logcap_test_keep = 256u << 10;
    char p2[] = "/tmp/t_logcap_b_XXXXXX"; fd = mkstemp(p2); if (fd < 0) return 2;
    fcntl(fd, F_SETFL, O_APPEND);
    s2a_log_out(fd, "[s2a] 起局第一行\n", strlen("[s2a] 起局第一行\n"));
    unsigned i = 0; for (size_t w = 0; w < (3u << 20); i++) { char b[160]; int k = snprintf(b, sizeof b, "[s2a] 普通行 %08u xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i); s2a_log_out(fd, b, (size_t)k); w += (size_t)k; }
    char last[64]; snprintf(last, sizeof last, "普通行 %08u", i - 1);
    close(fd);
    s = slurp(p2, &n);
    CHECK(n <= (1u << 20) + (1u << 20) / 64 + 4096, "滚动后文件 %zu 字节（上限 1 MB + 一次检查间隔）", n);
    CHECK(s && !strncmp(s, "[s2a] 起局第一行", strlen("[s2a] 起局第一行")), "开头（起局第一行）保留");
    CHECK(s && strstr(s, last), "最新一行（%s）保留", last);
    CHECK(s && strstr(s, "滚动截掉中间"), "有滚动标记行");
    free(s); unlink(p2);
    return S2A_T_RESULT("t_logcap", bad);
}

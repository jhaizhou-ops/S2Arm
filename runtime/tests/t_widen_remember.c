// 满屏自检「两次不同启动都触发才记住」单测（runtime/src/widen_remember.c）。期望手算：
//   文件不在 → 已记 0；第一次触发 → 1、不持久；第二次（另一次启动）→ 2、持久；删文件（清记忆）→ 0，再触发 → 1、不持久（重新试满屏）
#include "s2a_widen_remember.h"
#include <stdio.h>
#include <unistd.h>
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } else { printf("✓ " __VA_ARGS__); printf("\n"); } } while (0)
int main(void) {
    char p[] = "/tmp/t_widen_remember_XXXXXX"; int fd = mkstemp(p); close(fd); unlink(p);
    CHECK(s2a_wr_load(p) == 0, "没有记录文件：已记 0 次");
    int n1 = s2a_wr_note(p); CHECK(n1 == 1 && !s2a_wr_persist(n1), "第一次启动触发退回：记 1 次、不持久（下次起局重新试满屏）");
    CHECK(s2a_wr_load(p) == 1, "下次起局读到已记 1 次");
    int n2 = s2a_wr_note(p); CHECK(n2 == 2 && s2a_wr_persist(n2), "第二次（另一次启动）触发：记 2 次、持久记住本款 16:9");
    unlink(p); CHECK(s2a_wr_load(p) == 0, "清记忆（删记录文件）：已记 0 次");
    int n3 = s2a_wr_note(p); CHECK(n3 == 1 && !s2a_wr_persist(n3), "清记忆后再触发：重新从 1 次算、不持久");
    unlink(p);
    printf("%s t_widen_remember：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}

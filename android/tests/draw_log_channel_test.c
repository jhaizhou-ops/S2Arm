// 宿主回归（#1229 生产通道）：s2a_fd_set_draw_log 覆盖值与 debug.s2a.draw_log
// 属性的优先级。整个 nvn_vk_first_draw.c 按翻译单元收进来，直接打它的 static 通道。
//
// 锁的行为：
//   1. 覆盖未设（初值 -1）→ fd_verbose 看属性：没属性=0、属性=1 时=1。
//   2. 覆盖 -1 = 不动（JNI 传 -1 不该写状态）。
//   3. 覆盖 1/0 → 压过属性（含属性已缓存的情况；属性值此后不再读）。
//   4. 覆盖 0 → 关诊断（生产关腿语义：玩家包默认无声）。
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

static struct { const char *name; const char *value; } g_props[16];
static int g_prop_count;
static void fake_set_property(const char *name, const char *value) {
    for (int i = 0; i < g_prop_count; i++)
        if (!strcmp(g_props[i].name, name)) { g_props[i].value = value; return; }
    if (g_prop_count < 16) { g_props[g_prop_count].name = name; g_props[g_prop_count].value = value; g_prop_count++; }
}
static int g_prop_gets;
int __system_property_get(const char *name, char *value) {
    g_prop_gets++;
    for (int i = 0; i < g_prop_count; i++)
        if (!strcmp(g_props[i].name, name)) { strcpy(value, g_props[i].value); return (int)strlen(value); }
    value[0] = 0;
    return 0;
}
int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio; (void)tag; (void)fmt;
    return 0;
}

#include "nvn_vk_first_draw.c"

static int fails;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %d: %s\n", __LINE__, #cond); fails++; } } while (0)

int main(void) {
    // 1. 默认 -1：属性缺省 → 关
    CHECK(fd_verbose() == 0);

    // 2. 属性打开，但没起覆盖 → 开（缓存自此生效）
    fake_set_property("debug.s2a.draw_log", "1");
    // fd_verbose 已缓存 v=0：模拟「属性读发生在覆盖检查之前」的最坏时序——
    // 覆盖必须压过缓存值，否则 user 版上的关腿包一旦把 0 缓存进 v，extra 再也开不了。
    s2a_fd_set_draw_log(1);
    CHECK(fd_verbose() == 1);

    // 3. 覆盖 0 → 关，且不再读属性
    s2a_fd_set_draw_log(0);
    int before = g_prop_gets;
    CHECK(fd_verbose() == 0);
    CHECK(g_prop_gets == before);

    // 4. 覆盖 -1 = 不动（JNI 无 extra 时传 -1）：当前覆盖 0 保持不变
    s2a_fd_set_draw_log(-1);
    CHECK(fd_verbose() == 0);

    if (fails) { printf("%d check(s) failed\n", fails); return 1; }
    printf("override precedence ok: override>prop, -1 leaves state, off reads no prop\n");
    return 0;
}

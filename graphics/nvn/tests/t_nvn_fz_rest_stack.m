// 往前看游标在绘制中途（CALL 子列表内）起步必须带回放返回栈：子列表 END 后回到调用方续行，而不是跳到 g_rest 走进外来内存。
// 期望按 nvn_obj.h 记录格式手写（size 含 8 字节头、按 8 对齐；OP_BEGIN 早已不录，用作 g_rest 里的坏记录头）：
//   回放状态：g_ret_n = 1（在 CALL 子列表内），g_ret[0] = 调用方续行（{DRAW}{END}），g_exec_next 指向子列表（{DRAW}{END}），g_rest[0] = 坏记录（{OP_BEGIN, 0}）。
//   ① 新代码（fz_cursor_from_exec，拷贝 g_ret）：子列表第一条 DRAW；
//   ② 新代码：子列表 END 后回到调用方续行读到 DRAW（不跳 g_rest）—— 关键项；
//   ③ 新代码：调用方 END 后到 g_rest 坏记录结束（此时才该到 g_rest）；
//   ④ 旧代码（fz_cursor {.p = g_exec_next}，ret_n = 0）：子列表第一条 DRAW；
//   ⑤ 旧代码：子列表 END 后直跳 g_rest 坏记录（走出范围、漏走调用方续行）—— 反证旧代码走出范围。
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static void put(uint8_t *p, uint32_t op, uint32_t size) { op_hdr h = {op, size}; memcpy(p, &h, sizeof h); }

int main(void) {
    @autoreleasepool {
        mtl_init();
        g_hoist_n = 0;

        // 子列表：{DRAW}{END}；buf[64] = 512 字节，p_draw 最大也够放
        static uint64_t sub_buf[64]; memset(sub_buf, 0, sizeof sub_buf);
        uint8_t *sub = (uint8_t *)sub_buf;
        uint32_t dsz = (uint32_t)((sizeof(op_hdr) + sizeof(p_draw) + 7) & ~7u);
        put(sub, OP_DRAW, dsz); put(sub + dsz, OP_END, 8);

        // 调用方续行（返回点）：{DRAW}{END}
        static uint64_t cont_buf[64]; memset(cont_buf, 0, sizeof cont_buf);
        uint8_t *cont = (uint8_t *)cont_buf;
        put(cont, OP_DRAW, dsz); put(cont + dsz, OP_END, 8);

        // g_rest：一个坏记录头（OP_BEGIN 早已不录）—— 游标不该在走完调用方之前到这里
        static uint64_t rest_buf[4]; memset(rest_buf, 0, sizeof rest_buf);
        put((uint8_t *)rest_buf, OP_BEGIN, 0);
        static uint64_t rest_handles[1]; rest_handles[0] = (uint64_t)(uintptr_t)rest_buf;

        // 回放状态：在 CALL 子列表内
        g_ret[0] = cont; g_ret_n = 1; g_exec_next = sub;
        g_rest = rest_handles; g_nrest = 1;

        // 新代码：fz_cursor_from_exec 拷贝 g_ret
        fz_cursor cur = fz_cursor_from_exec();
        const uint8_t *q; op_hdr h; const void *a;

        int r1 = fz_next(&cur, &q, &h, &a);
        VERIFY(r1 == 1 && h.op == OP_DRAW, "① 子列表第一条 DRAW：返回 %d、op %u（期望 1、DRAW）", r1, h.op);

        int r2 = fz_next(&cur, &q, &h, &a);
        VERIFY(r2 == 1 && h.op == OP_DRAW && q == cont, "② 子列表 END 后回到调用方续行读到 DRAW（不跳 g_rest）：返回 %d、op %u、指针 %p（期望 1、DRAW、%p）", r2, h.op, (void*)q, (void*)cont);

        int r3 = fz_next(&cur, &q, &h, &a);
        VERIFY(r3 == 0 && cur.bad, "③ 调用方 END 后到 g_rest 坏记录结束：返回 %d、游标坏 %d（期望 0、1）", r3, cur.bad);

        // 旧代码反证：fz_cursor {.p = g_exec_next}，ret_n = 0
        fz_cursor old = {.p = sub};
        int ro1 = fz_next(&old, &q, &h, &a);
        VERIFY(ro1 == 1 && h.op == OP_DRAW, "④ 旧代码子列表第一条 DRAW：返回 %d（期望 1）", ro1);

        int ro2 = fz_next(&old, &q, &h, &a);
        VERIFY(ro2 == 0 && old.bad, "⑤ 旧代码子列表 END 后直跳 g_rest 坏记录（走出范围、漏走调用方续行）：返回 %d、游标坏 %d（期望 0、1）", ro2, old.bad);
    }
    {   // 回放 CALL 嵌套比返回栈深（g_ret 只存前 16 层、g_ret_n 照数）：往前看起步不越界拷贝、不猜调用方，直接停
        const uint8_t *save = g_exec_next; int save_n = g_ret_n;
        g_ret_n = (int)(sizeof g_ret / sizeof *g_ret) + 1;
        fz_cursor deep = fz_cursor_from_exec(); const uint8_t *q; op_hdr h; const void *a;
        int rd = fz_next(&deep, &q, &h, &a);
        VERIFY(deep.bad && deep.ret_n == 0 && rd == 0, "⑥ 嵌套 17 层（返回栈 16 层）起步：游标坏 %d、ret_n %d、fz_next 返回 %d（期望 1、0、0）", deep.bad, deep.ret_n, rd);
        g_ret_n = (int)(sizeof g_ret / sizeof *g_ret);
        fz_cursor full = fz_cursor_from_exec();
        VERIFY(!full.bad && full.ret_n == 16, "⑦ 嵌套正好 16 层：游标坏 %d、ret_n %d（期望 0、16）", full.bad, full.ret_n);
        g_exec_next = save; g_ret_n = save_n;
    }
    if (failures) { printf("✗ t_nvn_fz_rest_stack：%u 项里 %u 项不符\n", checks, failures); fflush(stdout); _exit(1); }
    printf("✓ t_nvn_fz_rest_stack：%u 项全过（往前看在 CALL 子列表内起步带返回栈，子列表 END 回到调用方续行）\n", checks); return 0;
}

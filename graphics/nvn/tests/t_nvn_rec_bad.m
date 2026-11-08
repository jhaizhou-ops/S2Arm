// 命令流游标遇到不是我方写的记录头（rec_bad：size < 8、不是 8 的倍数、op ≥ OP_NVN2_END_、op == OP_BEGIN）：打红行、结束该列表，不原地打转。
// 期望按 nvn_obj.h 的记录格式手写（size 含 8 字节头、按 8 对齐；OP_BEGIN 早已不录），不由被测实现推出：
//   ① fz_next 读到 {op 2, size 0} → 返回 0、游标置坏、指针清空（改前：返回 1 且指针不动，往前看在同一处读 20 万次）；
//   ② fz_next 读到 size 4 / size 12 / op = OP_NVN2_END_（宿主录的最后一个操作码之后）→ 同样返回 0；
//   ⑥ NVN2 的两条宿主记录 OP_PUSH_CONST / OP_DLSS（编号接在 OP_COUNT_ 之后，nvn2_cmd.h）是我方记录：游标照常交出、不置坏
//      （11-04 金刚：原判据 op ≥ OP_COUNT_ 把推常量当坏记录，放大器那遍之后整条列表被截断，画面只剩清屏紫色）；
//   ③ 正对照：合法的 {DRAW} {END} → 先返回 1 交出那笔绘制，再返回 0（列表正常结束、不置坏）；
//   ④ nvn_be_exec 回放：顶层 {CALL 子列表} {END}，子列表第一条是 {op 2, size 0} → 回放在 3 秒内返回（改前：健身环 11-03 第 454 帧提交线程原地 80 秒）；
//   ⑤ nvn_be_exec 顶层第一条就是 {op 2, size 0} → 返回；
//   ⑦ 延后推常量 OP_PUSH_CONST_PTR（11-04，接在 OP_DLSS 之后）：游标照常交出不置坏；回放（state_op）按记录里的指针在回放时读数据——录完再改源数据，
//      回放读到的是改后的值（真机：队列处理时才读，nvn2_cmd.h p_push_const_ptr），落在 计算 / 槽 1 / 偏移 0x40 起 8 字节。
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static void put(uint8_t *p, uint32_t op, uint32_t size) { op_hdr h = {op, size}; memcpy(p, &h, sizeof h); }

static int fz_first(const uint8_t *p, op_hdr *got, int *bad) {   // 一个游标从 p 起取一条
    fz_cursor c = {.p = p}; const uint8_t *q; const void *a; int r = fz_next(&c, &q, got, &a); *bad = c.bad; return r;
}

static _Atomic int t_exec_returned;
static void *exec_thread(void *arg) { nvn_be_exec((const uint8_t *)arg); atomic_store(&t_exec_returned, 1); return NULL; }
static int exec_returns(const uint8_t *p) {   // 回放在 3 秒内返回 → 1；没返回 → 0（那条线程留着打转，测试照常往下判、最后退出）
    atomic_store(&t_exec_returned, 0); pthread_t t; if (pthread_create(&t, NULL, exec_thread, (void *)p)) return 0;
    for (int i = 0; i < 300 && !atomic_load(&t_exec_returned); i++) usleep(10000);
    if (!atomic_load(&t_exec_returned)) return 0;
    pthread_join(t, NULL); return 1;
}

int main(void) {
    @autoreleasepool {
        mtl_init();
        g_nrest = 0; g_hoist_n = 0;
        static uint64_t buf[64];
        uint8_t *b = (uint8_t *)buf; op_hdr h; int bad;

        memset(buf, 0, sizeof buf); put(b, OP_BEGIN, 0);
        int r = fz_first(b, &h, &bad);
        VERIFY(r == 0 && bad, "① fz_next 读到 {op 2, size 0}：返回 %d（期望 0）、游标坏 %d（期望 1）", r, bad);

        const struct { uint32_t op, size; const char *what; } badh[] = { {OP_DRAW, 4, "size 4（< 8）"}, {OP_DRAW, 12, "size 12（不是 8 的倍数）"}, {OP_NVN2_END_, 16, "op = OP_NVN2_END_"} };
        for (int i = 0; i < 3; i++) { memset(buf, 0, sizeof buf); put(b, badh[i].op, badh[i].size); r = fz_first(b, &h, &bad);
            VERIFY(r == 0 && bad, "② fz_next 读到 %s：返回 %d（期望 0）、游标坏 %d", badh[i].what, r, bad); }

        // ⑥ NVN2 宿主记录：{PUSH_CONST 32} {DLSS 16} {END} → 两条都交出、正常结束、不置坏
        memset(buf, 0, sizeof buf); put(b, OP_PUSH_CONST, 32); put(b + 32, OP_DLSS, 16); put(b + 48, OP_END, 8);
        { fz_cursor c = {.p = b}; const uint8_t *q = NULL; const void *a; int n = 0, ops[3] = {-1, -1, -1};
          for (int k = 0; k < 3; k++) { int rr = fz_next(&c, &q, &h, &a); if (!rr) break; ops[n++] = (int)h.op; }
          VERIFY(!c.bad && n >= 1 && ops[0] == OP_PUSH_CONST, "⑥ NVN2 推常量 / DLSS 记录是我方记录：游标不置坏（%d）、交出 %d 条（首条 op %d，期望 %d）", c.bad, n, ops[0], OP_PUSH_CONST); }
        // ⑦ 延后推常量：{PUSH_CONST_PTR 24} {END} 交出、不置坏；回放读指针处此刻的字节
        memset(buf, 0, sizeof buf); put(b, OP_PUSH_CONST_PTR, 8 + sizeof(p_push_const_ptr)); put(b + 8 + sizeof(p_push_const_ptr), OP_END, 8);
        { fz_cursor c = {.p = b}; const uint8_t *q = NULL; const void *a; int rr = fz_next(&c, &q, &h, &a);
          VERIFY(rr == 1 && !c.bad && h.op == OP_PUSH_CONST_PTR, "⑦ 延后推常量记录是我方记录：交出 %d、游标坏 %d、op %u（期望 %d）", rr, c.bad, h.op, OP_PUSH_CONST_PTR); }
        { static uint8_t src[8] = {1, 2, 3, 4, 5, 6, 7, 8}; p_push_const_ptr pc = {.compute = 1, .slot = 1, .offset = 0x40, .size = 8, .data = (uint64_t)(uintptr_t)src};
          memset(S.push[1][1], 0, NVN2_PUSH_BYTES);
          for (int i = 0; i < 8; i++) src[i] = (uint8_t)(0xa0 + i);   // 录完（记录已成）再改源数据
          state_op(OP_PUSH_CONST_PTR, &pc, (uint32_t)sizeof pc);
          int ok = 1; for (int i = 0; i < 8; i++) ok &= S.push[1][1][0x40 + i] == (uint8_t)(0xa0 + i);
          VERIFY(ok && S.push[1][1][0x3f] == 0 && S.push[1][1][0x48] == 0, "⑦ 回放按指针读回放时的数据：计算槽 1 偏移 0x40 = a0..a7（%02x %02x），前后不动", S.push[1][1][0x40], S.push[1][1][0x47]); }
        memset(buf, 0, sizeof buf); uint32_t dsz = (uint32_t)(sizeof(op_hdr) + sizeof(p_draw)); dsz = (dsz + 7) & ~7u;
        put(b, OP_DRAW, dsz); put(b + dsz, OP_END, 8);
        { fz_cursor c = {.p = b}; const uint8_t *q = NULL; const void *a; int r1 = fz_next(&c, &q, &h, &a); int r2 = fz_next(&c, &q, &h, &a);
          VERIFY(r1 == 1 && r2 == 0 && !c.bad, "③ 正对照 {DRAW} {END}：先交出绘制（%d）、再正常结束（%d）、不置坏（%d）", r1, r2, c.bad); }

        static uint64_t top[8], sub[8];
        memset(top, 0, sizeof top); memset(sub, 0, sizeof sub);
        put((uint8_t *)sub, OP_BEGIN, 0);
        uint64_t t = (uint64_t)(uintptr_t)sub; put((uint8_t *)top, OP_CALL, 16); memcpy((uint8_t *)top + 8, &t, 8); put((uint8_t *)top + 16, OP_END, 8);
        VERIFY(exec_returns((const uint8_t *)top), "④ 回放 {CALL 子列表} {END}、子列表是 {op 2, size 0}：3 秒内返回");

        memset(sub, 0, sizeof sub); put((uint8_t *)sub, OP_BEGIN, 0);
        VERIFY(exec_returns((const uint8_t *)sub), "⑤ 回放顶层第一条就是 {op 2, size 0}：3 秒内返回");
    }
    if (failures) { printf("✗ t_nvn_rec_bad：%u 项里 %u 项不符\n", checks, failures); fflush(stdout); _exit(1); }   // 回放线程可能还在打转：直接退出
    printf("✓ t_nvn_rec_bad：%u 项全过（命令流游标遇到不是我方的记录头打红行、结束该列表）\n", checks); return 0;
}

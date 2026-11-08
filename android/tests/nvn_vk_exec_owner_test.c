// F4.4 宿主回归：执行包 owner 控制状态机（纯判决，无 Vulkan）。
//
// 覆盖的独立期望：
//   1. 单执行包：第二个进入者必须 WAIT，不能越过仍持有/挂起的包；
//   2. 挂起/恢复：只有当前执行包线程、当前令牌、当前代际能恢复；重复挂起/重复恢复/外来线程/
//      旧令牌/Stop 后恢复都必须准确拒绝并计数；
//   3. 挂起顺序：enter → suspend → owner 处理到控制事件 → resume → leave，事件顺序固定；
//   4. Stop：挂起中发布 Stop 记 stop_during_suspend，恢复返回 STOPPED，新进入者 STOPPED；
//   5. 换代：旧挂起令牌失效（STALE），不能在新代际上恢复旧包；
//   6. 协议错误：挂起中直接 leave 记为 leaves_while_suspended，不当成正常完成。
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "nvn_vk_exec_owner.h"

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

// ---- 3) 挂起期间 owner 处理到控制事件的顺序 ----
static struct nvk_exec_owner g_order_owner;
static pthread_mutex_t g_order_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_order_cv = PTHREAD_COND_INITIALIZER;
static int g_owner_handled;
static int g_packet_suspended;
static char g_order[64][16];
static int g_order_n;

static void order_note(const char *what) {
    pthread_mutex_lock(&g_order_mu);
    if (g_order_n < 64) snprintf(g_order[g_order_n], 16, "%s", what);
    g_order_n++;
    pthread_mutex_unlock(&g_order_mu);
}

static void *packet_thread(void *unused) {
    (void)unused;
    uint64_t me = 100;
    CHECK(nvk_exec_owner_enter(&g_order_owner, me) == NVK_EXEC_ENTER_READY, "packet enters");
    order_note("enter");
    uint64_t token = nvk_exec_owner_suspend(&g_order_owner, me);
    CHECK(token != 0, "packet suspends with a token");
    order_note("suspend");
    pthread_mutex_lock(&g_order_mu);
    g_packet_suspended = 1;
    pthread_cond_broadcast(&g_order_cv);
    while (!g_owner_handled) pthread_cond_wait(&g_order_cv, &g_order_mu);
    pthread_mutex_unlock(&g_order_mu);
    CHECK(nvk_exec_owner_resume(&g_order_owner, me, token) == NVK_EXEC_RESUME_OK,
          "packet resumes exactly once");
    order_note("resume");
    CHECK(nvk_exec_owner_leave(&g_order_owner, me) == 0, "packet leaves");
    order_note("leave");
    return NULL;
}

static void *owner_thread(void *unused) {
    (void)unused;
    pthread_mutex_lock(&g_order_mu);
    while (!g_packet_suspended) pthread_cond_wait(&g_order_cv, &g_order_mu);
    CHECK(nvk_exec_owner_suspended(&g_order_owner) == 1, "owner sees the published suspension");
    pthread_mutex_unlock(&g_order_mu);
    // owner 在挂起窗口内处理控制事件（Stop/窗口）；模型里只记顺序。
    order_note("owner-event");
    pthread_mutex_lock(&g_order_mu);
    g_owner_handled = 1;
    pthread_cond_broadcast(&g_order_cv);
    pthread_mutex_unlock(&g_order_mu);
    return NULL;
}

int main(void) {
    // 1) 单执行包 + 进入/释放。
    struct nvk_exec_owner o;
    nvk_exec_owner_init(&o, 7);
    CHECK(nvk_exec_owner_generation(&o) == 7, "generation recorded");
    CHECK(nvk_exec_owner_enter(&o, 1) == NVK_EXEC_ENTER_READY, "first enter is ready");
    CHECK(nvk_exec_owner_busy(&o) == 1, "execution packet is owned");
    CHECK(nvk_exec_owner_enter(&o, 2) == NVK_EXEC_ENTER_WAIT,
          "second guest packet must not overtake the owner");
    CHECK(nvk_exec_owner_leave(&o, 2) == -1, "foreign thread cannot release the packet");
    CHECK(nvk_exec_owner_enter(&o, 2) == NVK_EXEC_ENTER_WAIT, "still waiting");
    CHECK(nvk_exec_owner_leave(&o, 1) == 0, "owner releases");
    CHECK(nvk_exec_owner_enter(&o, 2) == NVK_EXEC_ENTER_READY, "waiter takes over after release");
    CHECK(nvk_exec_owner_leave(&o, 2) == 0, "second packet releases");

    // 2) 挂起/恢复的拒绝矩阵。
    CHECK(nvk_exec_owner_enter(&o, 10) == NVK_EXEC_ENTER_READY, "enter for suspend tests");
    CHECK(nvk_exec_owner_suspend(&o, 11) == 0, "foreign thread cannot suspend");
    uint64_t token = nvk_exec_owner_suspend(&o, 10);
    CHECK(token != 0 && nvk_exec_owner_suspended(&o) == 1, "owner suspends");
    CHECK(nvk_exec_owner_suspend(&o, 10) == 0, "double suspend is refused");
    CHECK(nvk_exec_owner_resume(&o, 10, token + 1) == NVK_EXEC_RESUME_STALE,
          "wrong token must not resume");
    CHECK(nvk_exec_owner_resume(&o, 11, token) == NVK_EXEC_RESUME_NOT_OWNER,
          "foreign thread cannot resume");
    CHECK(nvk_exec_owner_resume(&o, 10, token) == NVK_EXEC_RESUME_OK, "owner resumes");
    CHECK(nvk_exec_owner_resume(&o, 10, token) == NVK_EXEC_RESUME_NOT_SUSPENDED,
          "resume happens only once");
    CHECK(nvk_exec_owner_leave(&o, 10) == 0, "leave after resume");

    // 3) 挂起 → owner 事件 → 恢复的顺序。
    nvk_exec_owner_init(&g_order_owner, 3);
    g_owner_handled = 0;
    g_order_n = 0;
    pthread_t pkt, own;
    pthread_create(&own, NULL, owner_thread, NULL);
    pthread_create(&pkt, NULL, packet_thread, NULL);
    pthread_join(pkt, NULL);
    pthread_join(own, NULL);
    const char *expect[] = {"enter", "suspend", "owner-event", "resume", "leave"};
    CHECK(g_order_n == 5, "exactly five ordering events");
    for (int i = 0; i < 5 && i < g_order_n; i++)
        CHECK(!strcmp(g_order[i], expect[i]), "owner handles control while the packet is suspended");

    // 4) Stop：挂起中发布，恢复被拒绝，新工作准确失败。
    nvk_exec_owner_init(&o, 11);
    CHECK(nvk_exec_owner_enter(&o, 20) == NVK_EXEC_ENTER_READY, "enter before stop");
    token = nvk_exec_owner_suspend(&o, 20);
    CHECK(token != 0, "suspend before stop");
    nvk_exec_owner_request_stop(&o);
    CHECK(nvk_exec_owner_stop_requested(&o) == 1, "stop published");
    CHECK(nvk_exec_owner_resume(&o, 20, token) == NVK_EXEC_RESUME_STOPPED,
          "stop must not resume the suspended packet");
    CHECK(nvk_exec_owner_enter(&o, 21) == NVK_EXEC_ENTER_STOPPED,
          "new work is refused after stop");
    CHECK(nvk_exec_owner_leave(&o, 20) == 0, "suspended packet can be released after stop");

    // 5) 换代：旧令牌失效，不能在新代际上恢复旧包。
    nvk_exec_owner_init(&o, 30);
    CHECK(nvk_exec_owner_enter(&o, 30) == NVK_EXEC_ENTER_READY, "enter before generation change");
    token = nvk_exec_owner_suspend(&o, 30);
    CHECK(token != 0, "suspend before generation change");
    nvk_exec_owner_set_generation(&o, 31);
    CHECK(nvk_exec_owner_suspended(&o) == 0, "generation change clears the suspend");
    CHECK(nvk_exec_owner_resume(&o, 30, token) == NVK_EXEC_RESUME_NOT_SUSPENDED,
          "stale token cannot resume in a new generation");
    CHECK(nvk_exec_owner_leave(&o, 30) == 0, "leave after generation change");

    // 6) 协议错误：挂起中直接 leave。
    nvk_exec_owner_init(&o, 40);
    CHECK(nvk_exec_owner_enter(&o, 40) == NVK_EXEC_ENTER_READY, "enter for leave-while-suspended");
    CHECK(nvk_exec_owner_suspend(&o, 40) != 0, "suspend for leave-while-suspended");
    CHECK(nvk_exec_owner_leave(&o, 40) == 0, "leave clears the dangling suspend");
    struct nvk_exec_owner_stats st;
    nvk_exec_owner_get_stats(&o, &st);
    CHECK(st.leaves_while_suspended == 1, "leaving while suspended is recorded as a protocol error");

    // 统计口径：拒绝次数必须来自真实调用，不是推测。
    nvk_exec_owner_init(&o, 50);
    CHECK(nvk_exec_owner_enter(&o, 50) == NVK_EXEC_ENTER_READY, "stats enter");
    CHECK(nvk_exec_owner_enter(&o, 51) == NVK_EXEC_ENTER_WAIT, "stats wait enter");
    (void)nvk_exec_owner_suspend(&o, 99);                   // foreign
    token = nvk_exec_owner_suspend(&o, 50);
    (void)nvk_exec_owner_suspend(&o, 50);                   // double suspend
    (void)nvk_exec_owner_resume(&o, 50, token + 7);         // stale token
    CHECK(nvk_exec_owner_resume(&o, 50, token) == NVK_EXEC_RESUME_OK, "stats resume");
    (void)nvk_exec_owner_resume(&o, 50, token);             // double resume
    CHECK(nvk_exec_owner_leave(&o, 50) == 0, "stats leave");
    nvk_exec_owner_get_stats(&o, &st);
    CHECK(st.enters == 1 && st.wait_enters == 1, "enter/wait counters are actual calls");
    CHECK(st.suspends == 1 && st.resumes == 1, "suspend/resume counters are actual calls");
    CHECK(st.refused_foreign == 1, "foreign refusal counted");
    CHECK(st.refused_double_suspend == 1, "double suspend counted");
    CHECK(st.refused_stale == 1, "stale token counted");
    CHECK(st.refused_double_resume == 1, "double resume counted");

    if (fails) { printf("exec owner: %d FAILURES\n", fails); return 1; }
    printf("exec owner: ok (single packet, suspend/resume matrix, owner event ordering, stop, generation, stats)\n");
    return 0;
}

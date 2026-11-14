// nvn_vk_pipe_demand 宿主集成测：fake 建管线驱动 demand 后台线程。
// 覆盖：kick→PENDING→后台建→READY（lookup 命中）；同配方二次 kick 立即 READY；后台失败→FAILED；
//        仅着色器不同（状态/格式相同）的两套配方不得串管线（P0 回归）；停局 stop 有界不挂。
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "nvn_backend.h"
#include "rp_shader.h"
#include "nvn_vk_pipe_demand.h"

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static nvn_gpu_pipe g_installed;
static nvn_gpu_pipe_desc g_inst_desc;
static int g_has_inst;
static int g_fail_next;
static int g_build_calls;

int nvn_gpu_pipe_lookup(const nvn_gpu_pipe_desc *d, nvn_gpu_pipe *out) {
    if (out) *out = NULL;
    pthread_mutex_lock(&g_mu);
    int hit = g_has_inst && d && memcmp(d, &g_inst_desc, sizeof *d) == 0;
    if (hit && out) *out = g_installed;
    pthread_mutex_unlock(&g_mu);
    return hit;
}
nvn_gpu_rc nvn_gpu_pipe_get(const nvn_gpu_pipe_desc *d, int mode, nvn_gpu_pipe *out, nvn_gpu_err *err) {
    (void)mode;
    struct timespec ts = {0, 3000000L}; nanosleep(&ts, NULL);
    pthread_mutex_lock(&g_mu);
    g_build_calls++;
    int fail = g_fail_next;
    nvn_gpu_pipe built = (nvn_gpu_pipe)(uintptr_t)(0x9000 + g_build_calls);
    if (!fail) { g_inst_desc = *d; g_installed = built; g_has_inst = 1; }
    if (out) *out = fail ? NULL : built;
    pthread_mutex_unlock(&g_mu);
    nvn_gpu_rc r; r.code = fail ? NVN_GPU_E_COMPILE : NVN_GPU_OK;
    if (fail && err) snprintf(err->why, sizeof err->why, "fake compile fail");
    return r;
}
int nvn_plat_flag(const char *name, int dflt) { if (!strcmp(name, "nvk_pipe_async")) return 1; return dflt; }
static struct rp_prog g_prog;
int rp_shader_prog_borrow(const uint8_t identity[32], const struct rp_prog **out) { (void)identity; if (out) *out = &g_prog; return 1; }
void rp_shader_prog_return(const uint8_t identity[32]) { (void)identity; }

static int fails;
#define CHECK(c, m) do { if (!(c)) { printf("FAIL: %s (line %d)\n", m, __LINE__); fails++; } } while (0)

static void set_ident(uint8_t *id, uint8_t v) { memset(id, v, 32); }

int main(void) {
    memset(&g_prog, 0, sizeof g_prog);
    g_prog.sh[0] = (nvn_gpu_shader)(uintptr_t)0x1;
    g_prog.sh[1] = (nvn_gpu_shader)(uintptr_t)0x2;
    nvn_vk_pipe_demand_start();

    uint8_t idA[32], idC[32], idB[32];
    set_ident(idA, 0xA1); set_ident(idC, 0xC3); set_ident(idB, 0xB2);

    nvn_gpu_pipe_desc a; memset(&a, 0, sizeof a);
    a.st[0].sh = g_prog.sh[0]; a.st[1].sh = g_prog.sh[1]; a.prim = 3;

    nvn_gpu_pipe cached = NULL, out = NULL; char why[128];
    int k = nvn_vk_pipe_demand_kick(&a, idA, &cached);
    CHECK(k == NVK_DEMAND_PENDING, "first kick PENDING");
    int w = nvn_vk_pipe_demand_wait(&a, idA, 2000, &out, why, sizeof why);
    CHECK(w == 0 && out != NULL, "wait READY after background build");
    nvn_gpu_pipe hit = NULL;
    CHECK(nvn_gpu_pipe_lookup(&a, &hit) && hit == out, "lookup hits after build");
    CHECK(nvn_vk_pipe_demand_state(&a, idA, &cached) == NVK_DEMAND_READY, "state READY");

    k = nvn_vk_pipe_demand_kick(&a, idA, &cached);
    CHECK(k == NVK_DEMAND_READY && cached == out, "second kick READY from cache");

    // P0 回归：状态/格式相同、仅着色器句柄不同 → 必须各自建，不得串管线
    nvn_gpu_pipe outA = out;
    nvn_gpu_pipe_desc c; memset(&c, 0, sizeof c);
    c.st[0].sh = (nvn_gpu_shader)(uintptr_t)0x11; c.st[1].sh = (nvn_gpu_shader)(uintptr_t)0x22; c.prim = 3;
    int kc = nvn_vk_pipe_demand_kick(&c, idC, &cached);
    CHECK(kc == NVK_DEMAND_PENDING, "diff-shader rename kick must be PENDING (not READY from A)");
    nvn_gpu_pipe outC = NULL;
    int wc = nvn_vk_pipe_demand_wait(&c, idC, 2000, &outC, why, sizeof why);
    CHECK(wc == 0 && outC != NULL, "diff-shader wait READY");
    CHECK(outC != outA, "P0: diff-shader recipe must NOT get A's pipeline object");

    // 后台失败
    pthread_mutex_lock(&g_mu); g_fail_next = 1; g_has_inst = 0; pthread_mutex_unlock(&g_mu);
    nvn_gpu_pipe_desc b; memset(&b, 0, sizeof b); b.st[0].sh = g_prog.sh[0]; b.prim = 4;
    k = nvn_vk_pipe_demand_kick(&b, idB, &cached);
    CHECK(k == NVK_DEMAND_PENDING, "fail-recipe kick PENDING");
    w = nvn_vk_pipe_demand_wait(&b, idB, 2000, &out, why, sizeof why);
    CHECK(w == 2 && out == NULL, "wait FAILED with why");
    CHECK(why[0] != 0, "failure carries why text");

    nvn_vk_pipe_demand_stop();
    printf("%s (%d failures, builds=%d)\n", fails ? "RED" : "GREEN", fails, g_build_calls);
    return fails ? 1 : 0;
}

// Android 直连运行时补编：ProgramSetShaders 时把每个缺失的 code/control 交给 NativeAOT 的
// s2a_direct_bundle_v1 编译成 <键>.program.json（s2a-direct-program-v1），写进直连着色器目录。
// 阶段判定与 main/iOS 的 dsh_stage 一致（图形头魔数 + SPH 位；否则计算）；不按段数猜。
// 通用、零逐款规则；由 debug.s2a.compile_shaders=1 开启（默认关）。产物/标记写本局私有诊断目录
// （provider 设 S2A_DIRECT_DIAG_DIR，F4.1），不能写安装 revision；没有该目录就不做这一步。
#include <android/log.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/system_properties.h>
#include <sys/stat.h>
#include <pthread.h>

#define TAG "S2Arm"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

extern void *s2a_direct_provider_compile_fn(void) __attribute__((weak));
extern void *s2a_direct_bound_compile_any(void) __attribute__((weak));
extern void s2a_source_stats(uint32_t *entries, uint32_t *bytes, uint32_t *dropped) __attribute__((weak));
extern int s2a_direct_bundle_v1(const void *code, size_t code_len, const void *ctl, size_t ctl_len, int stage, const char *out_dir, int flags) __attribute__((weak));

// main/iOS dsh_stage：图形代码区以 NVN 头魔数 78563412 开头，SPH 字 0（+0x30）第 10..13 位 1 顶点 4 几何 5 像素；
// 不是图形头的按计算着色器。→ NVN 阶段 0 vs / 3 gs / 4 ps / 5 cs，-1 认不出或长度不对。
static int dsh_stage(const uint8_t *cd, const uint8_t *ctl, uint32_t *ncode, uint32_t *nctl) {
    uint32_t w; memcpy(ncode, ctl + 0x704, 4); memcpy(nctl, ctl + 0x20, 4); memcpy(&w, cd + 0x30, 4);
    static const uint8_t gfx_magic[4] = {0x78, 0x56, 0x34, 0x12};
    int t = (w >> 10) & 0xf; if (t == 0 && (w & 0x1f) == 1) t = 1;
    int st = memcmp(cd, gfx_magic, 4) ? 5 : t == 1 ? 0 : t == 5 ? 4 : t == 4 ? 3 : -1;
    return !*ncode || *ncode >= (1u << 24) || *nctl < 0x100 || *nctl >= (1u << 20) ? -1 : st;
}

// 编译器还没绑定（direct 会话激活晚于部分 SetShaders）时把 code/control 快照排进队列，
// 等绘制前/编译器就绪后补编。control 只在 SetShaders 期间有效，所以必须当场复制。
#define SURVEY_PENDING 48
#define SURVEY_MAX_CODE (256u * 1024u)
struct survey_pending {
    uint8_t key[8];
    int stage;
    uint32_t ncode;
    uint8_t *code;
    uint8_t ctl[0x880];
};
static struct survey_pending g_pending[SURVEY_PENDING];
static int g_npending;
static pthread_mutex_t g_pending_mu = PTHREAD_MUTEX_INITIALIZER;

static int survey_on(void) {
    static int enabled = -1;
    if (enabled < 0) { char v[PROP_VALUE_MAX] = {0}; __system_property_get("debug.s2a.compile_shaders", v); enabled = v[0] == '1'; }
    return enabled;
}


// 旧 XGS 产物不再被任何消费端读取：遇到就移到 <dir>/legacy-xgs 隔离（保留证据，不进新程序缓存）。
static void quarantine_legacy_xgs(const char *dir, const char *key_hex) {
    static const char *const suffixes[] = { ".xgs", ".stripped.xgs" };
    for (int i = 0; i < 2; i++) {
        char path[1300], qdir[1300], dst[1400];
        snprintf(path, sizeof path, "%s/%s%s", dir, key_hex, suffixes[i]);
        if (access(path, R_OK) != 0) continue;
        snprintf(qdir, sizeof qdir, "%s/legacy-xgs", dir);
        mkdir(qdir, 0777);
        snprintf(dst, sizeof dst, "%s/%s%s", qdir, key_hex, suffixes[i]);
        if (rename(path, dst) == 0) LOGI("direct shader: 旧产物 %s%s 已隔离到 legacy-xgs（不再消费）", key_hex, suffixes[i]);
    }
}

void dm_shader_survey(const uint8_t key[8], uint64_t code, const void *control) {
    static int traced;
    char tk[17];
    for (int b = 0; b < 8; b++) snprintf(tk + 2 * b, 3, "%02x", key[b]);
    int trace = traced < 24;
    if (trace) traced++;
    if (!survey_on()) { if (trace) LOGI("survey %s: compile_shaders off", tk); return; }
    const char *dir = getenv("S2A_DIRECT_DIAG_DIR");   // F4.1：诊断产物只进私有目录
    if (!dir || !dir[0]) { if (trace) LOGI("survey %s: no private diagnostics dir; revision left untouched", tk); return; }
    if (!control || !code || (uintptr_t)control >= (1ull << 47)) {
        if (trace) LOGI("survey %s: bad code/control (code=%llx ctl=%p)", tk, (unsigned long long)code, control);
        return;
    }
    // 目录/编译器都要等到 direct 会话激活才就绪；早期的 SetShaders 先入队，绘制前补编。
    if (!s2a_direct_bundle_v1 || !dir || !*dir) {
        // 编译器未绑定：把这一支的 code/control 复制下来，稍后补编（control 之后就无效了）。
        uint32_t ncode = 0, nctl = 0;
        int st = dsh_stage((const uint8_t *)(uintptr_t)code, (const uint8_t *)control, &ncode, &nctl);
        if (st < 0 || !ncode || ncode > SURVEY_MAX_CODE) {
            if (trace) LOGI("survey %s: queued? no: stage=%d code=%u", tk, st, ncode);
            return;
        }
        if (trace) LOGI("survey %s: queued stage=%d code=%u", tk, st, ncode);
        pthread_mutex_lock(&g_pending_mu);
        if (g_npending < SURVEY_PENDING) {
            struct survey_pending *e = &g_pending[g_npending];
            memcpy(e->key, key, 8);
            e->stage = st;
            e->ncode = ncode;
            e->code = malloc(ncode);
            if (e->code) {
                memcpy(e->code, (const void *)(uintptr_t)code, ncode);
                memcpy(e->ctl, control, 0x880);
                g_npending++;
            }
        }
        pthread_mutex_unlock(&g_pending_mu);
        return;
    }
    char k[17]; for (int i = 0; i < 8; i++) snprintf(k + 2 * i, 3, "%02x", key[i]);
    quarantine_legacy_xgs(dir, k);
    char strip[PROP_VALUE_MAX] = {0};
    __system_property_get("debug.s2a.strip_interlock", strip);
    int flags = strip[0] == '1' ? 1 : 0;
    char path[1200]; snprintf(path, sizeof path, "%s/%s.program.json", dir, k);
    // 剥离过 interlock 的产物不能当正式结果复用：编剥离版时留 .stripped 标记，
    // 关掉剥离后再遇到它，先把旧文件改名留证据，再按不剥离重编。
    char marker[1240]; snprintf(marker, sizeof marker, "%s/%s.stripped", dir, k);
    if (!flags) {
        if (access(path, R_OK) == 0 && access(marker, R_OK) != 0) { LOGI("direct shader survey: %s reused (%s)", k, path); return; }
        if (access(path, R_OK) == 0) {
            char keep[1240]; snprintf(keep, sizeof keep, "%s/%s.stripped.program.json", dir, k);
            if (rename(path, keep) == 0) LOGI("direct shader survey: %s 旧剥离产物已归档为 %s，按不剥离重编", k, keep);
        }
    }
    uint32_t ncode = 0, nctl = 0;
    int st = dsh_stage((const uint8_t *)(uintptr_t)code, (const uint8_t *)control, &ncode, &nctl);
    if (st < 0) { LOGE("【红】direct shader survey: %s 阶段无法判定（code=%u ctl=%u）", k, ncode, nctl); return; }
    // 控制段按 NVN 记录固定 0x880（0x850 是头部声明长度，Dsh 记录要求 0x880）
    int rc = s2a_direct_bundle_v1((const void *)(uintptr_t)code, ncode, control, 0x880, st, dir, flags);
    if (rc == 0) {
        if (flags) { FILE *m = fopen(marker, "wb"); if (m) fclose(m); }
        else remove(marker);
    }
    if (rc) {
        LOGE("【红】direct shader survey: %s 现编失败 stage=%d code=%u ctl=%u rc=%d", k, st, ncode, nctl, rc);
        char dump[256] = {0};
        __system_property_get("debug.s2a.dump_fail", dump);
        if (dump[0] == '/') {
            char cp[512], kp[512];
            snprintf(cp, sizeof cp, "%s/%s.code", dump, k);
            snprintf(kp, sizeof kp, "%s/%s.ctl", dump, k);
            FILE *f = fopen(cp, "wb"); if (f) { fwrite((const void *)(uintptr_t)code, 1, ncode, f); fclose(f); }
            f = fopen(kp, "wb"); if (f) { fwrite(control, 1, 0x880, f); fclose(f); }
            LOGI("direct shader survey: dumped %s code/ctl to %s", k, dump);
        }
    }
    else LOGI("direct shader survey: %s compiled stage=%d code=%u ctl=%u", k, st, ncode, nctl);
}

// 补编排队项：编译器绑定后、或绘制前发现缺 bundle 时调用。返回补编成功数。
int dm_shader_survey_flush(void) {
    static int last = -1;
    if (s2a_source_stats) {
        static int logged;
        uint32_t entries = 0, bytes = 0, dropped = 0;
        s2a_source_stats(&entries, &bytes, &dropped);
        if (entries && !logged) {
            logged = 1;
            LOGI("direct 源快照：%u 条 / %u KiB（淘汰 %u）", entries, bytes >> 10, dropped);
        }
    }
    {
        int now = (s2a_direct_bound_compile_any && s2a_direct_bound_compile_any()) ? 1 : 0;
        if (now != last) {
            last = now;
            LOGI("direct 统一编译入口：%s", now ? "已绑定（s2a_direct_compile_fn）" : "未绑定（等 direct 会话绑定）");
        }
    }
    if (!s2a_direct_bundle_v1 || !survey_on()) return 0;
    const char *dir = getenv("S2A_DIRECT_DIAG_DIR");   // F4.1：不写安装 revision
    if (!dir || !*dir) return 0;
    char strip[PROP_VALUE_MAX] = {0};
    __system_property_get("debug.s2a.strip_interlock", strip);
    int flags = strip[0] == '1' ? 1 : 0;
    int done = 0;
    pthread_mutex_lock(&g_pending_mu);
    for (int i = 0; i < g_npending; i++) {
        struct survey_pending *e = &g_pending[i];
        if (!e->code) continue;
        char k[17];
        for (int b = 0; b < 8; b++) snprintf(k + 2 * b, 3, "%02x", e->key[b]);
        char path[1200];
        snprintf(path, sizeof path, "%s/%s.program.json", dir, k);
        if (access(path, R_OK) == 0) { free(e->code); e->code = NULL; continue; }
        int rc = s2a_direct_bundle_v1(e->code, e->ncode, e->ctl, 0x880, e->stage, dir, flags);
        if (rc == 0) {
            done++;
            LOGI("direct shader survey: %s queued compile ok (stage=%d code=%u)", k, e->stage, e->ncode);
        } else {
            LOGE("【红】direct shader survey: %s queued compile failed (stage=%d code=%u rc=%d)", k, e->stage, e->ncode, rc);
        }
        free(e->code);
        e->code = NULL;
    }
    int left = 0;
    for (int i = 0; i < g_npending; i++) if (g_pending[i].code) g_pending[left++] = g_pending[i];
    g_npending = left;
    pthread_mutex_unlock(&g_pending_mu);
    return done;
}

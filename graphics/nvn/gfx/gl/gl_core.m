// OpenGL 前端公共部分：对象表、错误码、计数、函数表查找（eglGetProcAddress 与装载器共用）。接口见 docs/研究/GL前端接口.md
#include "gl_int.h"
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>

__thread gl_state *gl_cur;   // 按线程（egl.m 文件头）
gl_names gl_buffers, gl_vaos, gl_shaders, gl_programs;
_Atomic uint64_t gl_n_frames, gl_n_draws, gl_n_passes, gl_bad_feat, gl_bad_err;

// ---------- 对象表 ----------
void *gl_name_get(gl_names *t, GLuint name) { return name && name < t->n ? t->v[name] : NULL; }
static void grow(gl_names *t, uint32_t need) {
    if (need <= t->cap) return;
    uint64_t c = t->cap ? t->cap : 64; while (c < need) c *= 2;
    void **v = realloc(t->v, c * sizeof *v); if (!v) die("[gl] 对象表扩容失败（%llu）", (unsigned long long)c);
    memset(v + t->cap, 0, (c - t->cap) * sizeof *v); t->v = v; t->cap = (uint32_t)c;
}
GLuint gl_name_new(gl_names *t, void *obj) {
    if (!obj) { gl_set_error(0x0505); return 0; }   // GL_OUT_OF_MEMORY：不发布空槽，也不扩表
    if (!t->n) t->n = 1;   // 0 号不用（GL 的 0 = 没有对象）
    for (uint32_t i = 1; i < t->n; i++) if (!t->v[i]) { t->v[i] = obj; return i; }
    grow(t, t->n + 1); t->v[t->n] = obj; return t->n++;
}
// 表是按名字下标的稠密数组：Gen 出的名字从 1 连号，绑定自选名字（兼容配置允许）超过 GL_NAME_DENSE_MAX 就拒绝，不为一个大名字开整张表，
//   也不让 name + 1（UINT32_MAX 回绕成 0）和扩容倍增回绕（wwmogu #360 复审指出）
int gl_name_put(gl_names *t, GLuint name, void *obj) {
    if (!name) return 1;
    if (name >= GL_NAME_DENSE_MAX) { GLRED1("对象名字 %u 超过稠密表上限 %u：不建（报 GL_OUT_OF_MEMORY）", name, GL_NAME_DENSE_MAX); return 0; }
    grow(t, name + 1); if (t->n <= name) t->n = name + 1; t->v[name] = obj; return 1;
}
void *gl_name_del(gl_names *t, GLuint name) { void *o = gl_name_get(t, name); if (o) t->v[name] = NULL; return o; }
void gl_names_clear(gl_names *t, void (*destroy)(void *)) {
    for (uint32_t i = 1; i < t->n; i++) if (t->v[i]) destroy(t->v[i]);
    free(t->v); *t = (gl_names){0};
}

// ---------- 错误 ----------
#undef gl_set_error
void gl_set_error(GLenum e) { if (gl_cur && !gl_cur->error) gl_cur->error = e; }
void gl_set_error_at(GLenum e, const char *fn) {
    if (!gl_cur || gl_cur->error) return;
    gl_cur->error = e;
    static _Atomic int n; if (atomic_fetch_add(&n, 1) < 32) GLOG("GL 错误 %#x 由 %s 置（游戏 glGetError 会读到）", e, fn ? fn : "?");
}
GL(glGetError, GLenum, void) { if (!gl_cur) return 0; GLenum e = gl_cur->error; gl_cur->error = 0; return e; }

// ---------- 对公共部分的导出 ----------
void dm_gl_stats(uint64_t *frames, uint64_t *draws, uint64_t *passes) { *frames = gl_n_frames; *draws = gl_n_draws; *passes = gl_n_passes; }
void dm_gl_bad_draws(uint64_t *feat, uint64_t *err) { *feat = gl_bad_feat; *err = gl_bad_err; }

// ---------- 函数表查找 ----------
// 引用各片的锚（gl_int.h「分片锚」）：静态链接时每片的登记段都进来（used：没人读也留着这些引用）
__attribute__((used)) static const char *const gl_slices[] = {&gl_slice_egl, &gl_slice_gl_buf, &gl_slice_gl_draw, &gl_slice_gl_fb, &gl_slice_gl_prog, &gl_slice_gl_tex};
// __DATA,swgl：GL / GLB 宏登记的（名字 → 实现）。没有的名字回 NULL（GL 规范允许取不到扩展函数），每个名字记一次日志，供普查差集
void *gl_lookup(const char *name) {
    static const hle_ent *sec; static unsigned long sz;
    if (!name) return NULL;
    if (!sec) sec = (const hle_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swgl", &sz);
    void *fn = NULL;
    for (unsigned long i = 0; i < sz / sizeof *sec && !fn; i++) if (!strcmp(sec[i].name, name)) fn = sec[i].fn;
    static const char *seen[4096]; static int nseen; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    int known = 0; for (int i = 0; i < nseen; i++) if (!strcmp(seen[i], name)) { known = 1; break; }
    if (!known && nseen < 4096) { seen[nseen++] = strdup(name); GLOG("lookup %s → %s", name, fn ? "宿主实现" : "没有（回空）"); }
    pthread_mutex_unlock(&mu);
    return fn;
}
void *sw_xstack_wrap(const char *name, void *fn);   // S2Arm 宿主：在宿主栈上跑的切栈桩（单测给替身）
int gl_is_big(const char *name);
// 交给游戏的入口（装载器解析的导入、eglGetProcAddress 交出的指针同一条路）：查表，重活（swglb 登记的）套切栈桩
void *gl_entry(const char *name) { void *fn = gl_lookup(name); return fn && gl_is_big(name) ? sw_xstack_wrap(name, fn) : fn; }
// __DATA,swglb：要跑在宿主栈上的名字（适配层交给游戏前套切栈桩）
int gl_is_big(const char *name) {
    static const char *const *sec; static unsigned long sz;
    if (!sec) sec = (const char *const *)getsectiondata(&_mh_execute_header, "__DATA", "swglb", &sz);
    for (unsigned long i = 0; sec && i < sz / sizeof *sec; i++) if (!strcmp(sec[i], name)) return 1;
    return 0;
}

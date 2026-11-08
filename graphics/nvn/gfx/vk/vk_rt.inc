// 设备上现编（乙，总指挥 10-25）：离线库（出包期翻好的，含出包期自动生成抓到的）里没有的 SPIR-V，在设备上翻成 MSL 并现编。由 hle_vk.m 在 vkCreateShaderModule 前包含。
// · 游戏线程不等：vkCreateShaderModule 只登记、交后台队列。编好之前建的管线照直连安全网跳过它的绘制（计数照旧）；编好之后建的管线直接用（mod_ready）
// · 翻译规则在 graphics/metal/gal_vkx.m（SPIRV-Cross 编在那份库里），与出包工具 vk_shaders.py 同口径；弱引用：只链 libnvn 的单测没有它，未命中照旧报红
// · 持久化：编好的 MSL 源码与资源栏写进 <DM_MSL_FALLBACK>/vk/<键>.metal（第二混合源变体 <键>_d.metal）与 <键>.row（最后写，写完才算数；行首 RT_ROW_TAG）；
//   下次开机第一次 dev_init 就把它们交后台预编，游戏建到时多半已就绪，不再计未命中
// · 存 SPIR-V：未命中的游戏 SPIR-V 原样存 <键>.spv（翻不翻得成都存），收局并进跑局知识，下次出包离线翻进库（11-05）
// · 读数：每支未命中一行「[vk] 现编：<键> 不在离线库」带帧号；编好 / 失败各一行；dm_vk_rt_stats 给累计（未命中 / 编好 / 失败 / 读持久化）
int s2a_vk_xlate(const uint32_t *code, size_t nwords, const char *key, char **msl, char **msl_d, char *res, size_t rescap, int *stage, char *err, size_t errcap) __attribute__((weak_import));
static uint64_t g_frames;   // 已上屏帧数（定义在 frame_end 旁）
typedef struct rt_ent { char key[17]; _Atomic int state; shinfo si; __strong id<MTLFunction> fn, fn_d; struct rt_ent *next; } rt_ent;   // state：0 编着 / 1 好 / 2 坏
static rt_ent *g_rt; static pthread_mutex_t g_rt_mu = PTHREAD_MUTEX_INITIALIZER;
// .row 格式标记：10-31 前写的 .row 资源栏只剩第一项（sh_parse 用 strtok 原地切了 res 之后才落盘，Minecraft 第二次开机起界面贴图全没绑、文字图片空白），没有这个标记的一律不读、重编覆盖
// r3（审计 #1534 P1-66）：翻译改 MSL 3.1，之前存的 2.3 源码（图像原子走模拟缓冲）一律不读、重翻覆盖
#define RT_ROW_TAG "r3\t"
static _Atomic uint64_t g_rt_miss, g_rt_ok, g_rt_bad, g_rt_disk, g_rt_saved;
void dm_vk_rt_stats(uint64_t *miss, uint64_t *ok, uint64_t *bad, uint64_t *disk) { *miss = g_rt_miss; *ok = g_rt_ok; *bad = g_rt_bad; *disk = g_rt_disk; }
// 持久化写完（<键>.row 落盘）的累计：「编好」计数在落盘之前就加（先给渲染用、再写盘），等落盘的要看这个
//   （10-26 vk_core ⑬ 列车本机负载 33 时连续红：测试见「编好 +1」就数文件、随即退出，后台还没写 .row，目录里只剩 .metal）
uint64_t dm_vk_rt_saved(void) { return g_rt_saved; }
// 单测用：按住后台现编（翻译前等着），测「管线建在着色器编好之前」那条路（tests/vk_core ⑳）；产品代码不调
static _Atomic int g_rt_hold;
void dm_vk_rt_hold(int on) { g_rt_hold = on; }
static dispatch_queue_t rt_queue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("s2a.vk.rt", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0)); });
    return q;
}
static const char *rt_dir(void) {
    static char d[1100]; static dispatch_once_t once;
    dispatch_once(&once, ^{ const char *f = getenv("DM_MSL_FALLBACK"); if (f && *f) { snprintf(d, sizeof d, "%s/vk", f); mkdir(f, 0755); mkdir(d, 0755); } });
    return d[0] ? d : NULL;
}
static char *rt_read(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL; fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *s = n >= 0 ? malloc((size_t)n + 1) : NULL; if (s && fread(s, 1, (size_t)n, f) == (size_t)n) s[n] = 0; else { free(s); s = NULL; }
    fclose(f); return s;
}
static int rt_write(const char *path, const char *s) {   // 整文件写到临时名再改名：被杀在半路也不留半个文件
    char t[1200]; snprintf(t, sizeof t, "%s.%d.tmp", path, getpid()); FILE *f = fopen(t, "wb"); if (!f) return 0;
    size_t n = strlen(s); int ok = fwrite(s, 1, n, f) == n; ok &= fclose(f) == 0;
    if (ok) ok = rename(t, path) == 0; if (!ok) unlink(t); return ok;
}
static int rt_writeb(const char *path, const void *b, size_t n) {   // 二进制版（SPIR-V），同样临时名再改名
    char t[1200]; snprintf(t, sizeof t, "%s.%d.tmp", path, getpid()); FILE *f = fopen(t, "wb"); if (!f) return 0;
    int ok = fwrite(b, 1, n, f) == n; ok &= fclose(f) == 0;
    if (ok) ok = rename(t, path) == 0; if (!ok) unlink(t); return ok;
}
static id<MTLFunction> rt_fn(const char *src, const char *name, char *why, size_t cap) {
    MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion3_1;   // 同翻译口径 MSL 3.1（gal_vkx.m，审计 #1534 P1-66）
#if TARGET_OS_IPHONE
    o.mathMode = MTLMathModeRelaxed;   // 同出包工具的 iPhone 库（-fmetal-math-mode=relaxed：不许编译器假设没有 NaN，precise:: 的 NaN 口径才保得住）
#endif
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@(src) options:o error:&e];
    id<MTLFunction> fn = l ? [l newFunctionWithName:@(name)] : nil;
    if (!fn) snprintf(why, cap, "%s", e ? e.localizedDescription.UTF8String : "库里没有入口");
    return fn;
}
static _Atomic uint64_t g_vin_ok, g_vin_bad;   // 顶点输入重翻（vk_vin.inc）的编好 / 失败
// 编好一支：填 shinfo / 函数，最后发布状态（读的一方 acquire 看到 1 才读字段）；from_disk：0 现编 / 1 读持久化的 / 2 顶点输入重翻（vk_vin.inc，不持久化）
static void rt_finish(rt_ent *e, const char *msl, const char *msl_d, const char *res, int stage, int from_disk) {
    @autoreleasepool {
        char name[40], why[600] = ""; snprintf(name, sizeof name, "vk_%s", e->key);
        id<MTLFunction> fn = rt_fn(msl, name, why, sizeof why), fd = nil;
        if (fn && msl_d) { char nd[44]; snprintf(nd, sizeof nd, "vk_%s_d", e->key); fd = rt_fn(msl_d, nd, why, sizeof why); }
        if (!fn) { LOG("[vk] 【红】 现编：%s%s 编不过：%.400s", e->key, from_disk == 2 ? "（顶点输入重翻）" : "", why); if (from_disk == 2) g_vin_bad++; else g_rt_bad++; atomic_store_explicit(&e->state, 2, memory_order_release); return; }
        memset(&e->si, 0, sizeof e->si); memcpy(e->si.key, e->key, 16); e->si.frag = stage == 1; e->si.comp = stage == 2;
        { char *r = strdup(res); sh_parse(&e->si, r); free(r); }   // sh_parse 原地切串：res 之后还要原样落盘
        e->fn = fn; e->fn_d = fd;
        atomic_store_explicit(&e->state, 1, memory_order_release);
        if (from_disk == 2) g_vin_ok++; else if (from_disk) g_rt_disk++; else g_rt_ok++;
        LOG("[vk] 现编：%s 编好%s（第 %llu 帧）", e->key, from_disk == 2 ? "（顶点输入重翻）" : from_disk ? "（读上次持久化的）" : "", (unsigned long long)g_frames);
    }
}
static rt_ent *rt_new(const char *key) { rt_ent *e = calloc(1, sizeof *e); memcpy(e->key, key, 16); e->next = g_rt; g_rt = e; return e; }
static rt_ent *rt_find(const char *key) { for (rt_ent *e = g_rt; e; e = e->next) if (!memcmp(e->key, key, 16)) return e; return NULL; }
// 读一支持久化的（<键>.row 在才算），交后台编
static int rt_from_disk(rt_ent *e) {
    const char *d = rt_dir(); if (!d) return 0;
    char p[1200]; snprintf(p, sizeof p, "%s/%s.row", d, e->key); char *row = rt_read(p); if (!row) return 0;
    if (strncmp(row, RT_ROW_TAG, strlen(RT_ROW_TAG))) { free(row); return 0; }
    snprintf(p, sizeof p, "%s/%s.metal", d, e->key); char *msl = rt_read(p);
    snprintf(p, sizeof p, "%s/%s_d.metal", d, e->key); char *msl_d = rt_read(p);
    if (!msl) { free(row); free(msl_d); return 0; }
    dispatch_async(rt_queue(), ^{
        char *rest = row + strlen(RT_ROW_TAG), *st = strsep(&rest, "\t"), *res = strsep(&rest, "\n");
        rt_finish(e, msl, msl_d, res ? res : "", st ? atoi(st) : 0, 1); free(row); free(msl); free(msl_d);
    });
    return 1;
}
// 开机：上次持久化的全部交后台预编（dev_init 里调一次）
static void rt_preload(void) {
    const char *d = rt_dir(); if (!d) return;
    DIR *dp = opendir(d); if (!dp) return; struct dirent *de; int n = 0;
    pthread_mutex_lock(&g_rt_mu);
    while ((de = readdir(dp))) {
        size_t l = strlen(de->d_name); if (l != 20 || strcmp(de->d_name + 16, ".row")) continue;
        char key[17]; memcpy(key, de->d_name, 16); key[16] = 0;
        if (sh_find(key) || rt_find(key)) continue;   // 新包的离线库已有：不用持久化的
        rt_ent *e = rt_new(key);
        if (rt_from_disk(e)) n++; else { g_rt = e->next; free(e); }   // 读不了（旧格式 / 缺源码）：不留「编着」的空条目，游戏建到时照未命中现编
    }
    pthread_mutex_unlock(&g_rt_mu); closedir(dp);
    if (n) LOG("[vk] 现编：开机预编上次持久化的 %d 支（%s）", n, d);
}
static rt_ent *rt_get(const char *key, const void *code, size_t size) {
    pthread_mutex_lock(&g_rt_mu);
    rt_ent *e = rt_find(key);
    if (e) { pthread_mutex_unlock(&g_rt_mu); return e; }
    e = rt_new(key);
    if (rt_from_disk(e)) { pthread_mutex_unlock(&g_rt_mu); return e; }
    pthread_mutex_unlock(&g_rt_mu);
    g_rt_miss++;
    LOG("[vk] 现编：%s 不在离线库（%zu 字节 SPIR-V，第 %llu 帧），交设备现编", key, size, (unsigned long long)g_frames);
    if (!s2a_vk_xlate || size % 4) { LOG("[vk] 【红】 现编：%s 没有设备上的 SPIR-V 翻译（这份宿主没链 graphics/metal）", key); g_rt_bad++; atomic_store(&e->state, 2); return e; }
    uint32_t *w = malloc(size); memcpy(w, code, size);   // 游戏的内存随后会改：拷一份交后台
    dispatch_async(rt_queue(), ^{
        // 离线库没有的游戏 SPIR-V 原样存一份 <键>.spv（11-05：出包不起局抓着色器，运行时生成 SPIR-V 的款靠这份真跑学到）：
        //   收局拉回 pso_seed/<程序号>/vk_spv/（tools/dev_run.sh、tools/pso_seed_keep.sh），下次出包经跑局知识快照翻进离线库。着色器属游戏内容，只在本机 / 我方机器流转
        { const char *dd = rt_dir(); if (dd) { char sp[1200]; snprintf(sp, sizeof sp, "%s/%s.spv", dd, e->key); if (access(sp, F_OK) && !rt_writeb(sp, w, size)) LOG("[vk] 【红】 现编：%s 的 SPIR-V 存不进 %s", e->key, dd); } }
        while (atomic_load(&g_rt_hold)) usleep(2000);
        char *msl = NULL, *msl_d = NULL, res[2048], err[512]; int stage = 0;
        int rc = s2a_vk_xlate(w, size / 4, e->key, &msl, &msl_d, res, sizeof res, &stage, err, sizeof err); free(w);
        if (rc) {
            if (rc > 0) LOG("[vk] 现编：%s 是 Metal 没有的阶段，跳过", e->key); else LOG("[vk] 【红】 现编：%s 翻译失败：%s", e->key, err);
            g_rt_bad++; atomic_store_explicit(&e->state, 2, memory_order_release); return;
        }
        rt_finish(e, msl, msl_d, res, stage, 0);
        const char *d = rt_dir();
        if (d && atomic_load(&e->state) == 1) {   // 持久化：源码先、资源栏最后（.row 在 = 整份可用）
            char p[1200], row[2100]; int ok = 1;
            snprintf(p, sizeof p, "%s/%s.metal", d, e->key); ok &= rt_write(p, msl);
            if (msl_d) { snprintf(p, sizeof p, "%s/%s_d.metal", d, e->key); ok &= rt_write(p, msl_d); }
            snprintf(row, sizeof row, RT_ROW_TAG "%d\t%s\n", stage, res); snprintf(p, sizeof p, "%s/%s.row", d, e->key); if (ok) ok &= rt_write(p, row);
            if (!ok) LOG("[vk] 【红】 现编：%s 持久化写不进 %s", e->key, d); else g_rt_saved++;
        }
        free(msl); free(msl_d);
    });
    return e;
}
// 模块还没函数、它那份现编已好：补上（建管线前调；几条线程可能同时建管线，加锁）
static void mod_ready(VkShaderModule m) {
    if (m->fn || !m->rt || atomic_load_explicit(&m->rt->state, memory_order_acquire) != 1) return;
    pthread_mutex_lock(&g_rt_mu);
    if (!m->fn) { m->si = &m->rt->si; m->fn_d = m->rt->fn_d; m->tried_d = 1; m->fn = m->rt->fn; }
    pthread_mutex_unlock(&g_rt_mu);
}

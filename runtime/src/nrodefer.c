// romfs NRO 导出表（10-25 总指挥批，装载器口径）：游戏自带的 NRO（romfs/nro/*.nro）要等游戏用 nn::ro 装进来，rtld 才拿它们的导出解析别的模块的导入（Horizon 语义）；
//   起局时这类导入在已装模块里找不到定义是正常的。表由出包工具 tools/nro_exports.py 写进模块目录的 nro_exports.tsv（符号<TAB>NRO 文件名），
//   装载器（loader.c relocate）遇到未解析的强导入先查这里：命中记「延迟到 nn::ro 装载」普通日志、不计红；桩照旧，真被调到仍报红中止。
//   没有表（没有 romfs/nro 的款）= 全部照旧报红
// 随包表：nro_exports.tsv（出包组装 pack/ship_ext.py 从产物根拷进 App，runtime/build.mk 按这行自动收清单）
#include "native.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char *name, *file; } nro_ent;
static nro_ent *g_ent; static size_t g_n;
static _Thread_local FILE *g_boot_file;
void s2a_nro_abort_boot_inputs(void) {
    FILE *file = g_boot_file; g_boot_file = NULL;
    if (file && fclose(file)) LOG("【红】失败装载的 NRO 表关闭失败 errno=%d", errno);
}
void s2a_nro_table_reset(void) {
    for (size_t i = 0; i < g_n; i++) { free(g_ent[i].name); free(g_ent[i].file); }
    free(g_ent); g_ent = NULL; g_n = 0;
}
static int cmp_ent(const void *a, const void *b) { return strcmp(((const nro_ent *)a)->name, ((const nro_ent *)b)->name); }

void s2a_nro_table_load(const char *dir) {
    s2a_nro_table_reset();
    char p[1100]; snprintf(p, sizeof p, "%s/nro_exports.tsv", dir);
    FILE *f = fopen(p, "r"); if (!f) return;
    g_boot_file = f;
    size_t cap = 0; char l[1024];
    while (fgets(l, sizeof l, f)) {
        if (l[0] == '#' || l[0] == '\n') continue;
        char *t = strchr(l, '\t'); if (!t) continue; *t++ = 0; t[strcspn(t, "\r\n")] = 0;
        // 分配失败就中止（审计 #814 F-nro-oom-null）：截断的表当完整表用，后面 NRO 的导入会误报未解析；空名字排序 / 查找时解引用空指针
        if (g_n == cap) { cap = cap ? cap * 2 : 256; nro_ent *nb = realloc(g_ent, cap * sizeof *g_ent); if (!nb) die("romfs NRO 导出表：扩到 %zu 项时内存不足（%s）", cap, p); g_ent = nb; }
        char *name = strdup(l), *file = strdup(t);
        if (!name || !file) {
            free(name); free(file);
            die("romfs NRO 导出表：第 %zu 项复制时内存不足（%s）", g_n + 1, p);
        }
        g_ent[g_n++] = (nro_ent){name, file};
    }
    fclose(f); g_boot_file = NULL;
    if (g_n) qsort(g_ent, g_n, sizeof *g_ent, cmp_ent);
    LOG("romfs NRO 导出表：%zu 个符号（%s）", g_n, p);
}
// name 是不是 romfs 里某个 NRO 的导出：是 → 回 NRO 文件名，否 → NULL
const char *s2a_nro_defer_lookup(const char *name) {
    if (!g_n) return NULL;
    nro_ent k = {(char *)name, NULL}; const nro_ent *e = bsearch(&k, g_ent, g_n, sizeof *g_ent, cmp_ent);
    return e ? e->file : NULL;
}

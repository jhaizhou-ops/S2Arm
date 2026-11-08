// 补丁包 [data] 段的生效（正确性类，补丁包_v1设计.md 12.12；一次成功线 11-03，首款马力欧激战前锋 NuCachedSource2 缓存配置串）。
//   解析在 patch.c；写入复用 cpatch.c 的数据写入（s2a_cpatch_data_writes：范围只许代码段末页之后到键页前，先全核原值再写）。
//   单独成文件：cpatch.c 的单测 / 安卓闭包测试只连 cpatch.c，patch.c 的单测不连 cpatch.c，两边都不多出依赖。
#include "native.h"
#include "../include/patch.h"
#include <strings.h>
int s2a_cpatch_data_writes(module_t *m, const char *spec, int mode);
#define data_writes s2a_cpatch_data_writes
// 补丁包 [data] 段（正确性类，设计稿 12.12；一次成功线 11-03，首款马力欧激战前锋缓存配置串）：每个模块映射后、满屏装载前调（loader.c），
//   无条件生效（不挂 60 帧 / 满屏开关）。补丁编写构建 = 本包主程序构建号：按偏移核原字节后写；不同：在本模块代码段之后、键页之前
//   （同 data_writes 的范围：只读数据 + 数据段）按「前 sig + 原字节 + 后 sig」逐字节扫，唯一命中才写；0 或多处、原字节不符都跳过记黄。
//   写入复用 data_writes（先 mode 0 全核、再 mode 1 写）；写过的范围登记给满屏数据点避让（patch.c s2a_patch_data_mark）；每行结果进 .applied。
static int data_at(const module_t *m, int64_t p, const uint8_t *b, const uint8_t *mk, int n) {
    if (p < 0 || (uint64_t)p + (uint64_t)n > m->size) return 0;
    for (int i = 0; i < n; i++) if ((m->base[p + i] & (mk ? mk[i] : 0xff)) != (b[i] & (mk ? mk[i] : 0xff))) return 0;
    return 1;
}
static void data_spec(char *spec, size_t cap, uint64_t at, const s2a_patch_drow_t *r) {
    size_t k = (size_t)snprintf(spec, cap, "%llx:", (unsigned long long)at);
    for (int i = 0; i < r->n && k + 3 < cap; i++) k += (size_t)snprintf(spec + k, cap - k, "%02x", r->orig[i]);
    if (k + 2 < cap) spec[k++] = ':';
    for (int i = 0; i < r->n && k + 3 < cap; i++) k += (size_t)snprintf(spec + k, cap - k, "%02x", r->nw[i]);
    spec[k < cap ? k : cap - 1] = 0;
}
void s2a_patch_data_apply(module_t *m) {
    const s2a_patch_drow_t *r; int n = s2a_patch_data_rows(m->name, &r);
    if (n <= 0) return;
    const char *pb = s2a_patch_build(), *mb = s2a_main_build_id(); int same = pb[0] && mb && !strcasecmp(pb, mb);
    uint64_t low = ((m->text_end + m->load_bias + 0x3fff) & ~0x3fffull) - m->load_bias, hi = m->key_page_off;
    char spec[300];
    for (int j = 0; j < n; j++) {
        int64_t at = -1; int nh = 0; char why[120] = "";
        if (same) {
            data_spec(spec, sizeof spec, r[j].off, &r[j]);
            if (!data_writes(m, spec, 0)) at = r[j].off;
            else snprintf(why, sizeof why, "同构建号，偏移处原字节对不上或不在只读数据 / 数据段");
        } else if (!r[j].npre && !r[j].npost) snprintf(why, sizeof why, "本包构建 %s 不是补丁编写构建，这行没写 sig 不能按特征定位", mb ? mb : "?");
        else {
            for (uint64_t p = low; p + (uint64_t)r[j].n <= hi; p++)
                if (data_at(m, (int64_t)p, r[j].orig, NULL, r[j].n) && data_at(m, (int64_t)p - r[j].npre, r[j].pre, r[j].prem, r[j].npre) &&
                    data_at(m, (int64_t)p + r[j].n, r[j].post, r[j].postm, r[j].npost)) { if (!nh) at = (int64_t)p; nh++; }
            if (nh != 1) { snprintf(why, sizeof why, "本版本 %s 上特征命中 %d 处（要唯一）", mb ? mb : "?", nh); at = -1; }
            else { data_spec(spec, sizeof spec, (uint64_t)at, &r[j]); if (data_writes(m, spec, 0)) { snprintf(why, sizeof why, "特征命中处不在只读数据 / 数据段"); at = -1; } }
        }
        if (at < 0) {
            s2a_patch_count(2);
            s2a_patch_note("【黄】[data] 第 %d 行 %s+%#x 跳过：%s", r[j].line, m->name, r[j].off, why);
            continue;
        }
        if (data_writes(m, spec, 1)) die("补丁 [data] 已校验的数据写入失败");
        s2a_patch_data_mark(m->name, (uint64_t)at, (uint64_t)r[j].n);
        s2a_patch_count(same ? 0 : 1);
        if (same) s2a_patch_note("[data] 第 %d 行 %s+%#x 按偏移（快路径）写入 %d 字节", r[j].line, m->name, r[j].off, r[j].n);
        else s2a_patch_note("[data] 第 %d 行 %s+%#x 按特征定位到 +%#llx 写入 %d 字节", r[j].line, m->name, r[j].off, (unsigned long long)at, r[j].n);
    }
}

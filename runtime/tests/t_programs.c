// 多程序合集：包里几支程序、下一局装哪一支（runtime/src/programs.c）。
//   起因：普查 c1105_r4 索尼克×夏特 世代重启主菜单选游戏后 ExecuteProgram(1)，我方只能重启当前程序、报红停帧。
//   约定（runtime/include/s2a_programs.h）：序号 0 = 根目录，序号 n 在 <根>/programs/<n>/，有 main.npdm 才算，只数从 0 起的连续段（Ryujinx RegisterProgramMapInfo）。
//   期望全部手算：
//   ① 根 + programs/1 + programs/3（缺 2）→ 2 支；根没有 main.npdm → 0 支；空串 → 0
//   ② 目录：序号 0 = 根本身，1 = 根/programs/1；序号 16 / -1 / 缓冲放不下 → -1
//   ③ 没登记根就选 → -2；登记后共 2 支、当前 0；选 2 → -1（不登记）；没选就取 → -1
//   ④ 选 1 → 0，取 → 1、目录 根/programs/1、当前变 1；再取 → -1（取一次就清）；选 0 → 取 → 0、目录 = 根
#include "../src/native.h"
#include "s2a_programs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int bad;
static void eq_i(const char *what, int want, int got) { if (want != got) { bad++; printf("✗ %s：期望 %d → 真结果 %d\n", what, want, got); } else printf("  %s：%d\n", what, got); }
static void eq_s(const char *what, const char *want, const char *got) { if (strcmp(want, got)) { bad++; printf("✗ %s：期望 %s → 真结果 %s\n", what, want, got); } else printf("  %s：%s\n", what, got); }
static void touch(const char *dir) { char p[1200]; mkdir(dir, 0755); snprintf(p, sizeof p, "%s/main.npdm", dir); FILE *f = fopen(p, "w"); if (f) { fputs("META", f); fclose(f); } }

int main(void) {
    char base[512], d[1100], want[1200];
    snprintf(base, sizeof base, "%s/t_programs_%d", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
    mkdir(base, 0755); snprintf(d, sizeof d, "%s/programs", base); mkdir(d, 0755);
    char empty[600]; snprintf(empty, sizeof empty, "%s/empty", base); mkdir(empty, 0755);
    touch(base); snprintf(d, sizeof d, "%s/programs/1", base); touch(d); snprintf(d, sizeof d, "%s/programs/3", base); touch(d);

    eq_i("① 根 + 1 + 3（缺 2）支数", 2, s2a_programs_count(base));
    eq_i("① 根没有 main.npdm 支数", 0, s2a_programs_count(empty));
    eq_i("① 空串支数", 0, s2a_programs_count(""));

    eq_i("② 序号 0 目录返回", 0, s2a_programs_dir(base, 0, d, sizeof d)); eq_s("② 序号 0 目录", base, d);
    eq_i("② 序号 1 目录返回", 0, s2a_programs_dir(base, 1, d, sizeof d)); snprintf(want, sizeof want, "%s/programs/1", base); eq_s("② 序号 1 目录", want, d);
    eq_i("② 序号 16", -1, s2a_programs_dir(base, 16, d, sizeof d));
    eq_i("② 序号 -1", -1, s2a_programs_dir(base, -1, d, sizeof d));
    eq_i("② 缓冲放不下", -1, s2a_programs_dir(base, 1, d, 8));

    eq_i("③ 没登记根就选", -2, s2a_host_select_program(1));
    s2a_programs_init(base);
    eq_i("③ 登记后支数", 2, s2a_host_program_count());
    eq_i("③ 登记后当前序号", 0, s2a_host_program_index());
    eq_i("③ 选包里没有的 2", -1, s2a_host_select_program(2));
    eq_i("③ 没选就取", -1, s2a_programs_take(d, sizeof d));

    eq_i("④ 选 1", 0, s2a_host_select_program(1));
    eq_i("④ 取", 1, s2a_programs_take(d, sizeof d)); eq_s("④ 取到的目录", want, d);
    eq_i("④ 取后当前序号", 1, s2a_host_program_index());
    eq_i("④ 再取（取一次就清）", -1, s2a_programs_take(d, sizeof d));
    eq_i("④ 选 0", 0, s2a_host_select_program(0));
    eq_i("④ 取回 0", 0, s2a_programs_take(d, sizeof d)); eq_s("④ 序号 0 目录", base, d);
    eq_i("④ 当前序号回 0", 0, s2a_host_program_index());

    char cmd[700]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", base); (void)system(cmd);
    printf("%s t_programs：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}

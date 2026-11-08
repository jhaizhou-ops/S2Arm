// 多程序合集（一个应用里有多支程序：Program 内容的程序号末位 = 序号，Ryujinx 真值 Nca.ProgramIndex）。
// 包内约定：序号 0 = 现有根（模块目录 / 游戏数据目录）本身；序号 n ≥ 1 放在根下 programs/<n>/，结构与根相同
//   （模块目录：<名>.fixups.tsv、main.npdm、改写产物…；游戏数据：exefs/、romfs/、ctl/…）。
// 序号必须从 0 连续（同 Ryujinx ProcessLoaderHelper.RegisterProgramMapInfo：hasIndex 连续段才计数）。
// 切换走现有进程内重启：游戏 ExecuteProgram(n) → 服务层先 s2a_host_select_program(n) 登记下一局的序号，再 s2a_host_restart；
//   重建（host_main.c s2a_host_rebuild → 装模块）时 s2a_programs_take 取出生效。服务层按名找这几个导出；安卓没有（不支持进程内重建），找不到 = 报红。
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S2A_PROGRAMS_MAX 16   // 序号是程序号末位 4 位

// 根目录 base 下有几支程序：1 + 连续存在 programs/<n>/main.npdm 的个数（n = 1, 2, …）。base 为空或读不到 main.npdm 回 0
int s2a_programs_count(const char *base);
// 第 n 支程序的目录：n = 0 回 base 本身，否则 base/programs/<n>。成功 0；放不下 / 参数错 -1
int s2a_programs_dir(const char *base, int n, char *out, size_t len);

// 进程级状态（会话复位不清：序号要跨进程内重启存活）。base = 序号 0 的模块目录（宿主起局时登记一次）
void s2a_programs_init(const char *base);
int s2a_host_program_count(void);   // 包里几支程序（没登记过回 0）
int s2a_host_program_index(void);   // 当前这局跑的序号
// 登记下一局的序号（只登记，不发起重启）。0 = 已登记；-1 = 包里没有这个序号（报红）；-2 = 没登记根目录
int s2a_host_select_program(int n);
// 重建装模块前调：有登记就取出生效，把该序号的模块目录写进 out。回生效的序号；没有登记回 -1（out 不动）
int s2a_programs_take(char *out, size_t len);

#ifdef __cplusplus
}
#endif

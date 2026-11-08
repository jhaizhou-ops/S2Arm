// 原生 / 图形单测的门禁结论行（runtime/gate.sh 按「✓ t_<名>」「✗ t_<名>」判；没打结论行 rc=0 也算红）。
// 用法：#include "s2a_t_result.h"，main 末尾 return S2A_T_RESULT("t_<名>", bad);  bad = 不通的项数
//   打「✓ t_<名>：全过」或「✗ t_<名>：<n> 项不通」，返回 bad ? 1 : 0。入队预检 tools/t_result_lint.py 认这个宏
#ifndef S2A_T_RESULT_H
#define S2A_T_RESULT_H
#include <stdio.h>
#define S2A_T_RESULT(name, bad) \
    ((bad) ? (printf("✗ " name "：%d 项不通\n", (int)(bad)), fflush(stdout), 1) : (printf("✓ " name "：全过\n"), fflush(stdout), 0))
#endif

// 无人值守局（自动化 / 开发工具起的局）：执行器（tools/dev_run.sh 等）起局一律带 S2A_AUTOPLAY=1，玩家从主屏点开不带任何环境变量。
//   这类局里给玩家的问询界面（直连安全网提示页、「把上次的诊断发给我们？」、本地网络说明）不弹：日志本来由工具拉回，弹了只会挡住整局。
//   同一条规则只在这里一份：runtime/src/dguard.c、runtime/src/host_main.c、ios/diag.m、ios/lan_permission.m 都调它
#pragma once
#include <stdlib.h>
#include <string.h>
static inline int s2a_unattended(void) {
    const char *a = getenv("S2A_AUTOPLAY");
    return a && *a && strcmp(a, "0") != 0;
}

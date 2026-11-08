// 入口/准入测试只提供合成 SDK/core 端点，不运行游戏解码器。
// 产品目标链接 runtime/src/oodle_tool.c；夹具若误入工具模式必须失败，不能报成功。
#pragma once
#include <stdlib.h>
#include <stdio.h>
void s2a_oodle_tool_maybe(int late) {
    const char *job = getenv("DM_OODLE_JOB"), *serve = getenv("DM_OODLE_SERVE");
    if ((late != 0 && late != 1) || (job && *job) || (serve && *serve)) {
        fputs("Oodle tool mode is outside this synthetic entry fixture\n", stderr);
        abort();
    }
}

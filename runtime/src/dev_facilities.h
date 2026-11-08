// 开发设施总开关（11-07 质量线；方案与盘点见 cmdr/壳内开发设施盘点.md）。单独成头：native.h 在抽取阶段键里（pack/stage_inputs/extract.tsv），
//   这里的改动不该让全库冷重出。实现 runtime/src/os.c s2a_dev_on；用到的 ap_host.c / host_main.c / 单测各自包含本头
#pragma once
int s2a_dev_on(void);   // 0 = 玩家口径（Info.plist S2ADevFacilities=0）：停住现场 / 地址走势 / C# 内存与音频周期账不起；1 = 开发包
static inline int s2a_dev_decide(const char *env, int plist_has, int plist_on) {   // 判定本体（单测直接测）：环境变量 > Info.plist > 缺省开
    if (env && *env) return *env != '0';
    if (plist_has) return plist_on;
    return 1;
}

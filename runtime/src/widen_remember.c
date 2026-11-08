// 满屏自检「记住本款 16:9」的门槛（11-06 总指挥定，通用根修）：当场退回照旧（玩家看到的就是坏画面），但只有两次不同启动里都触发过退回才持久记住；
//   只触发一次的，下次启动重新试满屏、重新自检（标题动画 / 菜单 / 过场也能过「局内」门槛，靠局内判定区分判不准）。
//   计数存 <Documents>/widen_auto.txt 一行「launches=<n>」：每次启动最多加一（调用方一局只调一次）；删掉这个文件 = 清记忆、重新试满屏。
#include <stdio.h>
#include "s2a_widen_remember.h"
int s2a_wr_load(const char *path) {
    FILE *f = path ? fopen(path, "r") : NULL; int n = 0;
    if (f) { if (fscanf(f, "launches=%d", &n) != 1 || n < 0) n = 0; fclose(f); }
    return n;
}
int s2a_wr_note(const char *path) {
    int n = s2a_wr_load(path) + 1;
    if (!path) return n;
    char tmp[1200]; snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w"); if (!f) return n;
    fprintf(f, "launches=%d\n", n); fclose(f); rename(tmp, path);
    return n;
}
int s2a_wr_persist(int launches) { return launches >= 2; }

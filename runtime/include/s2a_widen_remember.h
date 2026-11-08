// 满屏自检「记住本款 16:9」门槛（runtime/src/widen_remember.c）：两次不同启动都触发退回才持久记住
#pragma once
int s2a_wr_load(const char *path);     // 已记的触发启动次数（文件不在 = 0）
int s2a_wr_note(const char *path);     // 本次启动触发了退回：次数 +1 写回，返回新次数（一局只调一次）
int s2a_wr_persist(int launches);      // 这个次数要不要持久记住（≥ 2）

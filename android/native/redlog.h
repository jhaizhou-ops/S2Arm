#pragma once
#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 红日志落盘（#1357）：目录只能由 Java 侧按当前应用传进来（getExternalFilesDir()，取不到退
// getFilesDir()），native 只拼文件名，不写死任何包名。路径在 set_dir 时算好存静态缓冲；
// 之后 red() / guest signal 处理器只做 open / write / fsync（异步信号安全）。
// 返回 0；EINVAL 目录为空或不是绝对路径；ENAMETOOLONG 超出缓冲；其它 errno = 预打开失败。
int s2a_android_redlog_set_dir(const char *dir);

// 把 n 字节原样追加到 red.log 和宿主日志 fd（g_s2a_logfd），两边各 fsync 一次。
// 异步信号安全：只用 open / write / fsync；red.log 还没打开时按初始化算好的路径重试。
void s2a_android_redlog_write(const char *line, size_t n);

// 显式红：格式化 "RED <原因>\n" 落两个 fd、fsync 后 abort，不返回。
__attribute__((noreturn, format(printf, 1, 2))) void s2a_android_red(const char *fmt, ...);
__attribute__((noreturn, format(printf, 1, 0))) void s2a_android_red_v(const char *fmt, va_list ap);

#ifdef __cplusplus
}
#endif

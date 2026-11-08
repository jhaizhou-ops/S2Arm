// F4.1：本局私有诊断目录。编译请求、补编产物、剥离标记等现场诊断只能写这里，
// 不能写安装 revision（不可变输入）。目录由 state_dir 派生，查找失败返回错误，
// 不回落 revision、不按进程当前目录猜。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// <state_dir>/direct-diagnostics。state_dir 必须是非空绝对路径；越界/相对路径准确失败。
// s2a_direct_diag_set_dir 设过外部根目录时忽略 state_dir，改从该根目录派生。
int s2a_direct_diag_dir(const char *state_dir, char *out, size_t out_size, char *why, size_t why_size);
// 外部私有诊断根目录覆盖（Java 经 JNI 注入，如 getExternalFilesDir(null)：外部应用
// 私有目录 adb 可直接拉，免 run-as）。dir 必须是非空绝对路径且给 direct-diagnostics
// 子目录留得出长度；返回 0 或 errno（EINVAL/ENAMETOOLONG），失败不改动既有覆盖。
// 进程级单值，activate 前由 JNI 注入一次；不设就用会话私有目录。
int s2a_direct_diag_set_dir(const char *dir);
// 写一个诊断文件（目录不存在时创建 0700）。name 只允许单层安全文件名：
// 非空、无 '/'（含反斜杠）、不是 "." / ".."、长度有界。
// 失败返回 -1 并写 why；调用方只记录“诊断未保存”，不改变正确的内存编译结果。
int s2a_direct_diag_write(const char *dir, const char *name, const void *data, size_t len,
                          char *why, size_t why_size);
// 目录清单摘要：按文件名排序，对每个普通文件取 “name\t<size>\t<sha256>\n”，
// 再对整段取 SHA-256。用于证明 revision 在启动/补编/停止前后逐文件内容不变。
// files/bytes 可为 NULL；digest_hex 至少 65 字节；空目录也有确定的摘要。
int s2a_direct_diag_manifest(const char *dir, char *digest_hex, size_t digest_size,
                             uint32_t *files, uint64_t *bytes, char *why, size_t why_size);

#ifdef __cplusplus
}
#endif

#pragma once
// UTF-8 文本脱敏；返回新分配的 UTF-8，调用方 free。空指针、无效 UTF-8 或规则失败返回 NULL，禁止回退原文。
// 只依赖 Foundation，可与生产同源在 Mac 编译；不访问设备、文件或密钥。
char *s2a_diag_redact(const char *text);

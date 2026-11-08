// Windows 出包机编 libnxgal 小库时预包含（graphics/metal/tools/nxgal_win.py 用 -include 给，#1100 W6）：补 Windows C 运行库没有的 POSIX 函数（asprintf / memmem；11-05 曲面翻译段 gal_tessxc.c 另要 strndup / strtok_r），
//   语义同 glibc / macOS libc。纯 C 源码一字不动，Mac / iOS / Linux 不经过这里。
#pragma once
#ifdef _WIN32
#define _CRT_SECURE_NO_WARNINGS      // MSVC 运行库把 sscanf / strcat / getenv 标「不安全」弃用，-Werror 下成错；标准 C 用法，不改源码
#define _CRT_NONSTDC_NO_DEPRECATE    // 同上：strdup 等 POSIX 名被标弃用
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline int vasprintf(char **out, const char *fmt, va_list ap) {
    va_list cp; va_copy(cp, ap); int n = vsnprintf(NULL, 0, fmt, cp); va_end(cp);
    *out = NULL; if (n < 0) return -1;
    char *b = (char *)malloc((size_t)n + 1); if (!b) return -1;
    vsnprintf(b, (size_t)n + 1, fmt, ap); *out = b; return n;
}
static inline int asprintf(char **out, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); int n = vasprintf(out, fmt, ap); va_end(ap); return n;
}
static inline void *memmem(const void *hay, size_t hn, const void *nee, size_t nn) {
    if (!nn) return (void *)hay;
    const char *h = (const char *)hay;
    for (size_t i = 0; i + nn <= hn; i++) if (h[i] == *(const char *)nee && !memcmp(h + i, nee, nn)) return (void *)(h + i);
    return NULL;
}
static inline char *strndup(const char *s, size_t n) {
    size_t l = 0; while (l < n && s[l]) l++;
    char *r = (char *)malloc(l + 1); if (!r) return NULL;
    memcpy(r, s, l); r[l] = 0; return r;
}
#define strtok_r strtok_s   // 同签名（char *, const char *, char **），C11 附录 K 版不同、这里是 MSVC 运行库的那个
#endif

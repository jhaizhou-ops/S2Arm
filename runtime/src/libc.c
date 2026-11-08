// libc 直通表（旧库 hle_table.c 直接搬）：AAPCS64 一致、无结构布局依赖的 C 库函数。只在「所有已装模块都没定义」时才用来解析导入（loader.c），
// 不覆盖模块里的任何定义——不是 SDK 拦截。
#include "native.h"
#include <math.h>
#include <ctype.h>
#include <time.h>
int s2a_getentropy(void *p, size_t n);
typedef struct { const char *name; void *fn; } libc_ent;
#define L(n) { #n, (void *)n },
static const libc_ent k_libc[] = {
L(memcpy) L(memset) L(memmove) L(memcmp) L(memchr) L(strlen) L(strnlen) L(strcmp) L(strncmp)
L(strcpy) L(strncpy) L(strcat) L(strncat) L(strchr) L(strrchr) L(strstr) L(strspn) L(strcspn)
L(strpbrk) L(strcasecmp) L(strncasecmp) L(atoi) L(atof) L(strtol) L(strtoul) L(strtoll) L(strtoull)
L(strtod) L(strtof) L(sqrtf) L(cbrtf) L(expf) L(acosf) L(cosf) L(sinf) L(atan2f) L(fmodf) L(cos)
L(sin) L(powf) L(atanf) L(tanf) L(asinf) L(log10) L(pow) L(logf) L(ldexpf) L(log10f) L(log)
L(ldexp) L(frexp) L(atan2) L(modff) L(exp2f) L(exp2) L(log2f) L(log2) L(lroundf)
L(mktime) L(timegm) L(gmtime_r) L(localtime_r) L(strftime)
{ "getentropy", (void *)s2a_getentropy },
};
void *s2a_libc_lookup(const char *name) {
    for (size_t i = 0; i < sizeof k_libc / sizeof *k_libc; i++) if (!strcmp(k_libc[i].name, name)) return k_libc[i].fn;
    return NULL;
}

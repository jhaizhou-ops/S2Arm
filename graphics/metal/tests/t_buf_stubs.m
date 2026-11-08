// t_buf 用：原生层全线程现场的桩——卡死 / 出错退出路径调到它时写一个标记文件（T_DUMP_MARK），父进程据此核「_exit(86) 前取了现场」
#include <stdio.h>
#include <stdlib.h>
int s2a_dump_threads(const char *why) {
    const char *p = getenv("T_DUMP_MARK"); if (!p) return 0;
    FILE *f = fopen(p, "w"); if (f) { fprintf(f, "%s\n", why); fclose(f); }
    return 1;
}

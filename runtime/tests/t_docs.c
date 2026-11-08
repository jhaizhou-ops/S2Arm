// 文档根唯一取法（runtime/include/s2a_docs.h，11-07 Mac 新前端 Hades 白屏根修）：S2A_DOCS 有就用它，没有（或空）才 $HOME/Documents。
//   期望值都按规则手写，不跑被测实现推
#include "s2a_docs.h"
#include "s2a_t_result.h"
#include <string.h>

static int bad;
static void ck(int ok, const char *what) { if (!ok) { bad++; printf("✗ %s\n", what); } else printf("通 %s\n", what); }

int main(void) {
    char o[256]; int k;
    setenv("HOME", "/h", 1);
    setenv("S2A_DOCS", "/lib/temp/0100535012974000", 1);
    k = s2a_docs_root(o, sizeof o);
    ck(!strcmp(o, "/lib/temp/0100535012974000") && k == 26, "设了 S2A_DOCS → 文档根就是它（不碰 $HOME/Documents）");
    k = s2a_docs_path(o, sizeof o, "wire/%016llX/shaders", 0x0100535012974000ull);
    ck(!strcmp(o, "/lib/temp/0100535012974000/wire/0100535012974000/shaders") && k == (int)strlen(o), "设了 S2A_DOCS → wire/<程序号>/shaders 拼在它下面");
    unsetenv("S2A_DOCS");
    s2a_docs_root(o, sizeof o);
    ck(!strcmp(o, "/h/Documents"), "没设 S2A_DOCS → $HOME/Documents（iOS 沙盒行为不变）");
    s2a_docs_path(o, sizeof o, "threads.txt");
    ck(!strcmp(o, "/h/Documents/threads.txt"), "没设 S2A_DOCS → $HOME/Documents/threads.txt");
    setenv("S2A_DOCS", "", 1);
    s2a_docs_root(o, sizeof o);
    ck(!strcmp(o, "/h/Documents"), "S2A_DOCS 为空串 = 没设");
    unsetenv("S2A_DOCS"); unsetenv("HOME");
    s2a_docs_root(o, sizeof o);
    ck(!strcmp(o, "./Documents"), "HOME 也没有 → ./Documents");
    setenv("S2A_DOCS", "/d", 1);
    k = s2a_docs_path(o, sizeof o, NULL);
    ck(!strcmp(o, "/d") && k == 2, "fmt 为 NULL → 文档根本身");
    k = s2a_docs_path(o, sizeof o, "%s", "");
    ck(!strcmp(o, "/d/") && k == 3, "fmt 拼出空串 → 根后带一个 /");
    char s[6]; k = s2a_docs_path(s, sizeof s, "abcdef");
    ck(k == 9 && !strcmp(s, "/d/ab"), "截断：返回完整长度 9（≥ 容量 6）、结果以 NUL 结尾");
    char t[2]; k = s2a_docs_path(t, sizeof t, "x");
    ck(k == 4 && !strcmp(t, "/"), "根本身就放不下：返回完整长度、不越界");
    return S2A_T_RESULT("t_docs", bad);
}

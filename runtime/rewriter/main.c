#include "rewriter.h"
#include <capstone/capstone.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char** argv) {
  if (argc == 2 && !strcmp(argv[1], "--version")) {  // App 打包后自检（launchers/macos/bundle_runtime.py）
    int maj, min;
    cs_version(&maj, &min);
    printf("s2a-rewrite capstone %d.%d\n", maj, min);
    return 0;
  }
  if (argc < 4 || argc > 5) {
    fprintf(stderr, "用法：%s <NSO> <输出目录> <模块名> [宽屏表]\n", argv[0]);
    return 1;
  }
  const char* spin = getenv("S2A_REWRITE_SPIN");
  s2a_rewrite_request r = {argv[1],
                           argv[2],
                           argv[3],
                           getenv("S2A_TARGET"),
                           argc == 5 ? argv[4] : NULL,
                           spin && !strcmp(spin, "1"),
                           getenv("S2A_FPS_TSV"),
                           getenv("S2A_CPATCH_TSV"),
                           getenv("S2A_CODE_PATCH"),
                           getenv("S2A_CODE_BUILD")};
  const char* cut = getenv("S2A_SDK_ADDR_CUT");
  const char* sj = getenv("S2A_REWRITE_SIGNED_JT");
  const char* acq = getenv("S2A_REWRITE_ACQ");
  const char* rel = getenv("S2A_REWRITE_REL");
  s2a_rewrite_options options = {!cut || strcmp(cut, "0") != 0, sj && !strcmp(sj, "1"), acq && !strcmp(acq, "0"),
                                 rel && !strcmp(rel, "0")};
  return s2a_rewrite_files_with_options(&r, &options, stdout);
}

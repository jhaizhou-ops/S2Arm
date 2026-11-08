#ifndef S2A_REWRITER_H
#define S2A_REWRITER_H
#include <stdio.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Paths are borrowed for this call. Each call owns its analysis and buffers; calls
 * may run concurrently on different threads, with distinct output directories.
 * target: apple/ios/macos/android/ohos. spin: 0 or 1. No environment is read by the
 * library. log is borrowed and may be NULL. Returns 0, 3 (rewrite gaps), or 1
 * (invalid input/I/O/encoding failure). No Python interpreter is required. */
typedef struct {
  const char *input, *output_dir, *module, *target, *widen_tsv;
  int spin;
  const char* fps_tsv; /* 帧率表（fps.tsv 的 c 行：按构建号改指令），NULL = 没有 */
  const char* cpatch_tsv; /* 社区补丁双路表（pack/cpatch.py 出的 w / p 行），NULL = 没有 */
  /* 补丁包 [code] 段（补丁包_v1设计.md 12.11，正确性类补丁）：<补丁目录>/<程序号>/patch.tsv，NULL = 没有。
   * code_build：本包主程序构建号（main NSO 头 0x40 起 16 字节，32 位小写十六进制）；与补丁文件头 build 相同按偏移打，不同按特征扫 */
  const char *code_patch, *code_build;
} s2a_rewrite_request;
int s2a_rewrite_files(const s2a_rewrite_request* request, FILE* log);
/* The original request layout and entry point remain ABI-compatible. NULL
 * options use the Python defaults; sdk_addr_cut=0 disables SDK cuts and gates. */
typedef struct {
  int sdk_addr_cut;
  /* 1：紧凑跳转表按硬件符号扩展恢复负偏移（X 目的的 ldrsb/ldrsh，以及 add 的 sxtb/sxth/sxtw）。
   * 同一开关下，ldrsb/ldrsh 写入 W 再 lsl #2 记缺口、不出映像。
   * 0：与打开此项之前逐字节相同。库不读环境变量；命令行只在 S2A_REWRITE_SIGNED_JT=1 时置 1。
   * 维护者完成 iPhone 同包 A/B 和逐款逐字节核对之前保持 0。 */
  int signed_jt;
  /* 1：不做「自旋取锁补 acquire」（ldxr → ldaxr，见 rewriter.c acq_upgrade）；0 = 做（缺省，零初始化即开）。
   * 命令行只在 S2A_REWRITE_ACQ=0 时置 1。 */
  int acq_off;
  /* 1：不做「独占存补 release」（LL/SC 环里的 stxr* / stxp → stlxr* / stlxp，见 rewriter.c rel_upgrade）；0 = 做（缺省）。
   * 命令行只在 S2A_REWRITE_REL=0 时置 1。 */
  int rel_off;
} s2a_rewrite_options;
int s2a_rewrite_files_with_options(const s2a_rewrite_request* request,
                                 const s2a_rewrite_options* options, FILE* log);
#ifdef __cplusplus
}
#endif
#endif

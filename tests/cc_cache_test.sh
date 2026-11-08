#!/bin/bash
# 编译缓存入口单测（tools/cc_cache.sh + tools/ccshim/；临时目录、临时缓存，约 5 秒）：bash tests/cc_cache_test.sh
# 期望（按规则手写，判据只用 ccache 每次编译的命中记录，不用耗时——同一份源再编会被系统缓存吃掉，耗时不可信）：
#   ① 两棵不同目录的树编同一份源：第二棵 1/1 命中，两份 .o 逐字节相同，.o 里没有树的绝对路径
#   ② 第二棵改了头文件内容 → 不命中（头文件进键）
#   ③ 只换 SDKROOT（xcrun 选 SDK 的环境变量，ccache 自己不算进键）→ 不命中（shim 补 -isysroot 进命令行）
#   ④ 链接（不带 -c）、xcrun 查询类调用原样直通：能链出可执行文件、不进命中记录；xcrun --show-sdk-path 与系统 xcrun 一致
#   ⑤ S2A_CCACHE=0 → 不改 PATH、不设 S2A_CCACHE_BIN
#   没装 ccache 的机器：只验 ④⑤（入口照样能编能链），①②③ 记「没装 ccache，跳过」
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
source "$H/tools/cc_cache.sh"
for d in a b; do mkdir -p "$T/$d/src" "$T/$d/tools"; ln -s "$H/tools/ccshim" "$T/$d/tools/ccshim"
  printf '#include "h.h"\nint f(void) { return K; }\n' > "$T/$d/src/x.c"; echo '#define K 3' > "$T/$d/src/h.h"
  printf '#include <stdio.h>\nint main(void) { puts("ok"); return 0; }\n' > "$T/$d/src/m.c"; done
on() { S2A_CCACHE_DIR=$T/cache S2A_CCACHE_LOG=$T/$1.log s2a_ccache_on "$T/$1"; }
cc1() { (on "$1"; cd "$T/$1" && clang -g -O1 -c "$T/$1/src/x.c" -o "$2" 2>&1); }
HAVE=$(command -v ccache || ls /opt/homebrew/bin/ccache 2> /dev/null || true)
if [ -n "$HAVE" ]; then
  cc1 a x.o > /dev/null; cc1 b x.o > /dev/null
  ck "① 第一棵 0/1 命中（$(s2a_ccache_sum "$T/a.log")）" '[ "$(s2a_ccache_sum "$T/a.log")" = "命中 0 / 共 1" ]'
  ck "① 第二棵 1/1 命中（$(s2a_ccache_sum "$T/b.log")）" '[ "$(s2a_ccache_sum "$T/b.log")" = "命中 1 / 共 1" ]'
  ck "① 两份 .o 逐字节相同" 'cmp -s "$T/a/x.o" "$T/b/x.o"'
  ck "① .o 里没有树的绝对路径" '! strings -a "$T/b/x.o" | grep -q "$T"'
  echo '#define K 4' > "$T/b/src/h.h"; : > "$T/b.log"; cc1 b x2.o > /dev/null
  ck "② 改头文件内容 → 不命中（$(s2a_ccache_sum "$T/b.log")）" '[ "$(s2a_ccache_sum "$T/b.log")" = "命中 0 / 共 1" ]'
  IS=$(/usr/bin/xcrun --sdk iphoneos --show-sdk-path 2> /dev/null)
  if [ -d "$IS" ]; then : > "$T/a.log"; (on a; cd "$T/a" && SDKROOT=$IS clang -target arm64-apple-ios17.0 -O1 -g -c src/x.c -o xi.o; SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path) clang -target arm64-apple-ios17.0 -O1 -g -c src/x.c -o xm.o) > /dev/null 2>&1
    ck "③ 只换 SDKROOT → 两次都不命中（$(s2a_ccache_sum "$T/a.log")）" '[ "$(s2a_ccache_sum "$T/a.log")" = "命中 0 / 共 2" ]'
  else echo "通 ③ 本机没有 iOS SDK，跳过"; fi
else echo "通 ①②③ 没装 ccache，跳过（入口直通，下面④⑤照验）"; fi
: > "$T/a.log"; o=$( (on a; cd "$T/a" && clang src/m.c -o m && ./m) 2>&1)
ck "④ 链接直通：链出可执行文件能跑（${o}）、不进命中记录（$(s2a_ccache_sum "$T/a.log")）" '[ "$o" = ok ] && [ "$(s2a_ccache_sum "$T/a.log")" = "命中 0 / 共 0" ]'
s1=$( (on a; xcrun --sdk macosx --show-sdk-path) ); s0=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
ck "④ xcrun 查询原样直通（${s1}）" '[ -n "$s1" ] && [ "$s1" = "$s0" ]'
r=$( (S2A_CCACHE=0; unset S2A_CCACHE_BIN; P0=$PATH; S2A_CCACHE_DIR=$T/cache s2a_ccache_on "$T/a"; [ "$PATH" = "$P0" ] && [ -z "${S2A_CCACHE_BIN:-}" ] && echo same) )
ck "⑤ S2A_CCACHE=0 不动 PATH、不开缓存" '[ "$r" = same ]'
# ⑥ 仓库里不提交软链（10-30 出包线：bundle_engine 拒收引擎输入里的软链，tools/ccshim/ 下 6 个软链让 build_app 打不出 App）：
#   tools/ccshim 只有 shim 一个普通文件；开缓存后入口名现建在 <根>/build/ccshim、排在 PATH 最前
ck "⑥ 仓库 tools/ccshim 里没有软链（实得：$(find "$H/tools/ccshim" -type l | wc -l | tr -d ' ') 个）" '[ -z "$(find "$H/tools/ccshim" -type l)" ]'
p6=$( (unset S2A_CCACHE_BIN; S2A_CCACHE_DIR=$T/cache s2a_ccache_on "$T/b"; [ -n "${S2A_CCACHE_BIN:-}" ] || { echo 跳过; exit 0; }; echo "${PATH%%:*}|$(readlink "$T/b/build/ccshim/cc")") )
[ "$p6" = 跳过 ] && echo "⑥ 没装 ccache，跳过入口名检查" || ck "⑥ 对 b 开缓存后 PATH 最前是 b/build/ccshim、cc → b/tools/ccshim/shim（实得：${p6}）" '[ "$p6" = "$T/b/build/ccshim|$T/b/tools/ccshim/shim" ]'

[ $bad = 0 ] && echo "cc_cache 单测全过"; exit $bad

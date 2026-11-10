#!/bin/bash
# 要跑通用模式的调用点都显式写 S2A_GFX=generic（10-25 起直连起手：不写就走直连）：bash tests/gfx_generic_callers_test.sh
# 规则：GAL 录像（S2A_GALREC）只有通用渲染器出——仓库里凡设 S2A_GALREC 起局的 .sh，脚本里必须有 S2A_GFX=generic
set -u; H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
scan() {   # scan <git 仓库> → 「个数|缺的脚本」
  local f n=0 miss=
  for f in $(cd "$1" && git grep -l -E 'S2A_GALREC=' -- '*.sh' | grep -v '^tests/gfx_generic_callers_test.sh$'); do
    n=$((n + 1)); grep -q 'S2A_GFX=generic' "$1/$f" || miss="$miss $f"; done
  echo "$n|${miss# }"; }
# 个数下限只证明扫描器真扫到了本仓库的调用点（查不查得出缺写由下面的反证管）：迁仓后公开仓剩 2 个（另一个随维护方工具留在 private-tools），原下限 3 从首次公开快照起一直红（11-09）
r=$(scan "$H"); ck "本仓库设 S2A_GALREC 起局的脚本都显式 S2A_GFX=generic（${r}）" '[ "${r%%|*}" -ge 1 ] && [ -z "${r#*|}" ]'
T=$(mktemp -d); (cd $T && git init -q && printf 'S2A_GFX=generic S2A_GALREC=$D/rec bash run_mac.sh\n' > ok.sh && printf 'export S2A_GALREC=$OUT/rec\nbash run_mac.sh\n' > bad.sh && git add -A)
r2=$(scan $T); ck "反证：临时仓库里一个写了、一个没写 → 点出 bad.sh（${r2}）" '[ "$r2" = "2|bad.sh" ]'
rm -rf $T; [ $bad = 0 ] && echo "gfx_generic_callers 单测全过" || { echo "gfx_generic_callers 单测有不通"; exit 1; }

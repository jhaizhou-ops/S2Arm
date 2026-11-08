#!/bin/bash
# 门禁只看：tools/gate_route.py
# 门禁路由「提示文字不是依赖」单测（tools/gate_route.py drop_prose，临时仓库、合成脚本，约 1 秒）：bash tests/gate_route_prose_test.sh
# 10-29 总指挥：改纯工具 tools/caps_policy.py 路由出 83 个单测，73 个只经 pack/ipa.sh 报错提示「先 pack/stage_rewrite.sh」这条边；
#   执行追踪：oneclick_test 真跑 pack/ipa.sh 78 次，一次都没执行 stage_rewrite.sh / caps_policy.py。
# 期望（按规则手写，不跑被测实现推）：单测 tests/x_test.sh 调 tools/a.sh c.sh e.sh g.sh p.py k.sh，各脚本里——
#   ① a.sh 只在 echo「【红】…（先跑 tools/b.sh）」里提到 b.sh → 改 b.sh 不选 x_test
#   ② c.sh 的 bash -c 'source tools/d.sh; d_run 单测'（命令串里带中文参数，是真执行）→ 改 d.sh 选 x_test
#   ③ e.sh 的 "$PY" tools/f.py "中文参数"（路径不在中文段里）→ 改 f.py 选 x_test
#   ④ g.sh 的 fail "…有 $(basename "$x")/ 却缺（重出：tools/h.sh）"：$( 前半段留、后半段是话 → 改 h.sh 不选
#   ⑤ p.py 的 print(f'用法：python3 tools/q.py …') → 改 q.py 不选；subprocess.run(['bash', 'tools/r.sh', '中文']) → 改 r.sh 选
#   ⑥ k.sh 的 eval "tools/s.sh 名单"（紧跟 eval）→ 改 s.sh 选
#   ⑦ 单测自己的标签 ck "改 tools/t.sh 后（中文）" 不算点名 → 改 t.sh 不选；同一单测命令位置 bash tools/u.sh "说明" → 改 u.sh 选
#   ⑧ 对照：没有中文的引号段 echo "see tools/v.sh" 照旧算（规则只认中文提示段，不改英文写法的旧口径）→ 改 v.sh 选
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1：期望 $3 → 真结果 $2"; else echo "不通 $1：期望 $3 → 真结果 $2"; bad=1; fi; }
R=$T/r; mkdir -p $R/tools $R/tests; cd $R || exit 1; git init -q
cp "$H/tools/gate_route.py" tools/; printf '# 合成路由表\nios\tnative/\n' > tools/gate_route.tsv
for f in b d h s t u v; do echo 'echo x' > tools/$f.sh; done; for f in f q; do echo 'print(1)' > tools/$f.py; done; echo 'echo r' > tools/r.sh
printf '#!/bin/bash\necho "【红】缺产物（先跑 tools/b.sh）"; exit 1\n' > tools/a.sh
printf '#!/bin/bash\nbash -c '"'"'source tools/d.sh; d_run 单测'"'"'\n' > tools/c.sh
printf '#!/bin/bash\n"$PY" tools/f.py "中文参数"\n' > tools/e.sh
printf '#!/bin/bash\nfail "直连库不全：有 $(basename "$x")/ 却缺（重出：tools/h.sh）"\n' > tools/g.sh
printf '#!/usr/bin/env python3\nimport subprocess\nprint(f'"'"'用法：python3 tools/q.py <目录>'"'"')\nsubprocess.run(['"'"'bash'"'"', '"'"'tools/r.sh'"'"', '"'"'中文'"'"'])\n' > tools/p.py
printf '#!/bin/bash\neval "tools/s.sh 名单"\necho "see tools/v.sh"\n' > tools/k.sh
printf '#!/bin/bash\nck "改 tools/t.sh 后（中文）" true\nbash tools/a.sh; bash tools/c.sh; bash tools/e.sh; bash tools/g.sh; python3 tools/p.py; bash tools/k.sh\nbash tools/u.sh "说明"\n' > tests/x_test.sh
git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture
r() { python3 tools/gate_route.py tests "$1" | tr '\n' ' ' | sed 's/ $//'; }
X=tests/x_test.sh
ck "① echo 提示里的 tools/b.sh 不是依赖" "$(r tools/b.sh)" ""
ck "② bash -c 带中文参数的命令串里 source 的 tools/d.sh 是依赖" "$(r tools/d.sh)" "$X"
ck "③ 路径在中文参数段外的 tools/f.py 是依赖" "$(r tools/f.py)" "$X"
ck "④ \$( 后半段提示里的 tools/h.sh 不是依赖" "$(r tools/h.sh)" ""
ck "⑤ print 用法提示里的 tools/q.py 不是依赖" "$(r tools/q.py)" ""
ck "⑤ subprocess 参数表里的 tools/r.sh 是依赖" "$(r tools/r.sh)" "$X"
ck "⑥ eval 后的中文命令串里的 tools/s.sh 是依赖" "$(r tools/s.sh)" "$X"
ck "⑦ 单测标签里的 tools/t.sh 不是依赖" "$(r tools/t.sh)" ""
ck "⑦ 单测命令位置的 tools/u.sh 是依赖" "$(r tools/u.sh)" "$X"
ck "⑧ 对照：无中文引号段里的 tools/v.sh 照旧算" "$(r tools/v.sh)" "$X"
[ $bad = 0 ] && echo "gate_route 提示文字单测全过" || { echo "gate_route 提示文字单测有不通"; exit 1; }

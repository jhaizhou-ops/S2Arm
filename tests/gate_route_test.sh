#!/bin/bash
# 门禁只看：tools/gate_route.py tools/gate_decl.py tools/stage_inputs.py pack/stage_inputs/*.tsv tests/autoplay_test.sh tests/dev_run_test.sh tests/devbattery_test.sh tests/gc_test.sh tests/health_test.sh tests/pack_jobs_test.sh tests/pack_test.sh tests/sched_test.sh tests/score_test.sh tests/stage_keys_test.sh tests/svc_hang_test.sh tests/train_test.sh tests/xc_key_test.sh tests/diagzip_test.sh
#   （10-28：断言的是对真实仓库算出的路由；改断言点名的单测（含它们头上的门禁声明）、路由脚本 / 表 / 阶段闭包才跑。被点名的工具脚本改了只影响「点名边」这类断言，交给改路由的那一笔）
# 门禁路由单测（tools/gate_route.py，读本仓库真实文件，约 3 秒）：bash tests/gate_route_test.sh
# 期望按路由规则手写（各钩子文件头「# 门禁路由：」+ 单测文本引用）：改调度只跑调度波及的单测、不跑钩子与 iOS；改文档什么都不跑；
# 改服务 → 服务 / 原生 / 画幅钩子 + iOS，不跑 gfx 钩子；表外代码路径 → 钩子全跑；空改动 → 全跑；证据阶梯按目录分级
set -u; H=$(cd "$(dirname "$0")/.." && pwd); cd "$H"; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
r() { python3 tools/gate_route.py "$@" | tr '\n' ' '; }
NT=$(( $(ls tests/*_test.sh | wc -l | tr -d ' ') + 1 ))   # 根单测 + 已登记的独立 drain_readflush 入口
# 单测自己带目录点名的本线外文件按仓库路径认（10-22：toolchain271 改 graphics/metal/Makefile、xc_key.sh，路由没带上 tests/xc_key_test.sh，main 红在它上）；
#   只认单测自己点名的，不顺着编排脚本往下认（train / gc 单测在假仓库里跑桩，不该挂到 gfx 工具上）
o=$(r tests graphics/tools/shbake/xc_key.sh); ck "改 graphics/tools/shbake/xc_key.sh → 含 xc_key 单测、不含 train / gc 单测（实得：${o}）" '[[ "$o" == *tests/xc_key_test.sh* ]] && [[ "$o" != *train_test* ]] && [[ "$o" != *gc_test* ]]'
o=$(r tests graphics/metal/Makefile); ck "改 graphics/metal/Makefile（没扩展名，靠单测头「门禁覆盖」）→ 含 xc_key 单测（实得：${o}）" '[[ "$o" == *tests/xc_key_test.sh* ]]'
o=$(r tests services/opus/build.sh); ck "改 services/opus/build.sh（单测按 services/ 下相对路径写 opus/build.sh，末两段唯一）→ 含 svc_hang 单测（实得：${o}）" '[[ "$o" == *tests/svc_hang_test.sh* ]]'
# 10-22 起 remote.sh 在远端跑 gc.sh、gc.sh 调 sched.sh：改 sched.sh 顺闭包带上 remote 单测是真依赖；不相干的举 dev_run（dev_run.sh 不调 sched.sh）
o=$(r tests tools/sched.sh); ck "改 tools/sched.sh → 单测含 sched、不含 autoplay / dev_run（实得：${o}）" '[[ " $o" == *tests/sched_test.sh* ]] && [[ "$o" != *autoplay_test* ]] && [[ "$o" != *dev_run_test* ]]'
ck "改 tools/sched.sh → 钩子 0 个、iOS 不跑" '[ -z "$(r hooks tools/sched.sh | tr -d " ")" ] && [ "$(r ios tools/sched.sh)" = "no " ]'
o=$(r tests tools/redline.py); ck "Python 同目录 import 也算覆盖：改 redline.py → score / health 单测（实得：${o}）" '[[ "$o" == *score_test* ]] && [[ "$o" == *health_test* ]]'
o=$(r tests tools/devbattery.sh); ck "传递闭包：改 devbattery.sh（被 devlock.sh 引用）→ dev_run 单测也跑（实得：${o}）" '[[ "$o" == *dev_run_test* ]] && [[ "$o" == *devbattery_test* ]]'
ck "整行注释里点名的文件不算依赖：改 tools/oneshot.sh 不带出 pack_test" '[[ "$(r tests tools/oneshot.sh)" != *pack_test* ]]'
ck "源文件后缀 .m 也认（10-28 总指挥：改 ios/diagzip.m 原先选不中 diagzip_test）" '[[ "$(r tests ios/diagzip.m)" == *tests/diagzip_test.sh* ]]'
# #925：期望直接来自三个生产消费者的测试合同，不从路由器输出生成期望。
o=$(r tests graphics/metal/cs/NxTrack.cs); ck "C# NxTrack 改动 → 独立排空/读时回写测试（实得：${o}）" '[[ "$o" == *graphics/track/tests/drain_readflush/build_run.sh* ]]'
o=$(r tests compat/tree/src/Ryujinx.Graphics.Gpu/Shader/ShaderCache.cs); ck "C# ShaderCache 改动 → 垃圾代码与失败负缓存测试" '[[ "$o" == *tests/shader_garbage_guard_test.sh* ]] && [[ "$o" == *tests/shader_fault_cache_test.sh* ]]'
o=$(r tests compat/tree/src/Ryujinx.Graphics.Gpu/Engine/Threed/StateUpdater.cs); ck "C# StateUpdater 改动 → 垃圾代码与失败负缓存测试" '[[ "$o" == *tests/shader_garbage_guard_test.sh* ]] && [[ "$o" == *tests/shader_fault_cache_test.sh* ]]'
o=$(r tests compat/tree/src/Ryujinx.Graphics.Gpu/Shader/S2AShaderFaultCache.cs); ck "C# 负缓存自身改动 → 对应纯逻辑测试" '[[ "$o" == *tests/shader_fault_cache_test.sh* ]]'
o=$(r tests docs/坑记录.md); ck "普通文档负对照 → 不跑三个C#目标测试" '[[ "$o" != *drain_readflush/build_run.sh* ]] && [[ "$o" != *shader_garbage_guard_test.sh* ]] && [[ "$o" != *shader_fault_cache_test.sh* ]]'
o=$(r tests graphics/metal/cs/NxTrack.cs.bak); ck "仅文件名近似 → 不选排空测试" '[[ "$o" != *drain_readflush/build_run.sh* ]]'
EV=$(grep -l '^# 门禁：每次' tests/*_test.sh | tr '\n' ' ')   # 头部声明「每次」的单测（共享位置扫描等）
ck "改文档 → 只有「每次」单测、钩子不跑、iOS 不跑" '[ "$(r tests docs/a.md)" = "$EV" ] && [ -z "$(r hooks docs/a.md | tr -d " ")" ] && [ "$(r ios docs/a.md)" = "no " ]'
o=$(r hooks graphics/tools/shbake/x.py); ck "改出包期着色器工具 graphics/tools → 跑 gfx 钩子、不跑画幅回放（10-24 门禁整改：回放器不编 graphics/tools；实得：${o}）" '[[ "$o" == *graphics/gate.sh* ]] && [[ "$o" != *tests/visual/gate.sh* ]]'
o=$(r hooks graphics/metal/x.m); ck "改渲染器 graphics/metal → 画幅回放照跑（实得：${o}）" '[[ "$o" == *tests/visual/gate.sh* ]]'
o=$(r hooks services/S2A.Services/A.cs); ck "改服务 → 服务钩子，不跑原生钩子（原生门禁 make host 不带 S2A_CS、不链 C#，99 组 C 单测不碰服务层；10-28 梳理）、不跑 gfx 钩子、不跑画幅回放；iOS 跑（实得：${o}）" '[[ "$o" != *runtime/gate.sh* ]] && [[ "$o" == *services/gate.sh* ]] && [[ "$o" != *tests/visual/gate.sh* ]] && [[ "$o" != *graphics/gate.sh* ]] && [ "$(r ios services/S2A.Services/A.cs)" = "yes " ]'
o=$(r hooks compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures/SmaaAreaTexture.bin); ck "改 SMAA 查表数据（graphics/nvn 生成 nvn_aa_lut.h、NVN 单测链它）→ 跑原生钩子（实得：${o}）" '[[ "$o" == *runtime/gate.sh* ]]'
o=$(r hooks compat/tree/src/Ryujinx.HLE/HOS/Services/Hid/IHidServer.cs); ck "改 Ryujinx 服务代码 → 不跑原生钩子、跑服务钩子（实得：${o}）" '[[ "$o" != *runtime/gate.sh* ]] && [[ "$o" == *services/gate.sh* ]]'
o=$(r hooks android/app/A.java); ck "改安卓外壳 → 只跑安卓钩子（实得：${o}）" '[ "$(echo $o)" = "android/gate.sh" ]'
o=$(r hooks runtime/rewriter/rewriter.c); ck "改改写器（runtime/rewriter/rewriter.c）→ 原生 + gfx + 安卓钩子（实得：${o}）" '[ "$(echo $o)" = "graphics/gate.sh runtime/gate.sh android/gate.sh" ]'
o=$(r hooks weird/x.c); ck "表外代码路径 → 钩子全跑（实得：${o}）" '[ "$(wc -w <<< "$o" | tr -d " ")" = "$(find . -mindepth 2 -maxdepth 4 -name gate.sh -not -path "./tools/*" -not -path "./.git/*" | wc -l | tr -d " ")" ]'
# #530 第一层：编进安卓单库的共用 C#（services/、compat/tree/src/、graphics/metal/cs/ 的 NxTrack.cs 带 s2a_native 导入）改了要跑安卓链接核对钩子
o=$(r hooks graphics/metal/cs/NxTrack.cs); ck "改 graphics/metal/cs/NxTrack.cs（编进安卓单库）→ 含安卓链接核对钩子（实得：${o}）" '[[ "$o" == *android/core-link/gate.sh* ]]'
o=$(r hooks services/S2A.Services/Native.cs); ck "改 services/S2A.Services/Native.cs → 含安卓链接核对钩子（实得：${o}）" '[[ "$o" == *android/core-link/gate.sh* ]]'
# 定义侧（#530 后续）：安卓单库编进去的共用原生源（runtime/src/、两个 graphics/nvn 文件）改了也要跑安卓链接核对钩子
o=$(r hooks runtime/src/alt.c); ck "改 runtime/src/alt.c（编进安卓单库、定义 C# 绑定的 s2a_alt_phase）→ 含安卓链接核对钩子（实得：${o}）" '[[ "$o" == *android/core-link/gate.sh* ]]'
o=$(r hooks launchers/macos/Sources/S2ArmLauncher/Store.swift); ck "改 Mac 前端 → 仅 Mac 钩子、iOS 不跑" '[ "$o" = "launchers/macos/gate.sh " ] && [ "$(r ios launchers/macos/Sources/S2ArmLauncher/Store.swift)" = "no " ]'
o=$(r hooks pack/roots.sh); ck "公共 pack 文件保留单测路由、不挂前端钩子" '[ -z "$(echo "$o" | tr -d " ")" ] && [[ "$(r tests pack/roots.sh)" == *tests/pack_test.sh* ]]'
o=$(r hooks tools/toolchain.sh); ck "公共工具链保留原有路由、不挂前端钩子" '[ -z "$(echo "$o" | tr -d " ")" ] && [ "$(r ios tools/toolchain.sh)" = "no " ]'
# tool 档要跑的钩子 = 文件头「# 门禁路由：」明确点到改动的（10-31：原先 tool 档一个钩子都不跑）
o=$(r claimed pack/jobs/core.py pack/contracts/README.md); ck "改 pack/jobs/ → claimed 只出 Mac 钩子（实得：${o}）" '[ "$o" = "launchers/macos/gate.sh " ]'
o=$(r claimed tools/train.sh tests/train_test.sh pack/roots.sh); ck "改纯本线工具 → claimed 0 个钩子、不吃表外兜底（实得：${o}）" '[ -z "$(echo "$o" | tr -d " ")" ]'
o=$(r claimed weird/x.c); ck "表外代码路径 → claimed 不兜底全跑（全跑归 full 档 hooks；实得：${o}）" '[ -z "$(echo "$o" | tr -d " ")" ]'
ck "空改动 → 单测全跑（$NT 份）" '[ "$(r tests | wc -w | tr -d " ")" = "$NT" ]'
ck "证据：改 native → 整局九款" '[[ "$(r evidence runtime/src/a.c)" == *整局* ]]'
ck "证据：改 ARMeilleure（执行模型）→ 整局" '[[ "$(r evidence compat/tree/src/ARMeilleure/a.cs)" == *整局* ]]'
ck "证据：改着色器翻译 → GAL 回放、不起整局" 'o=$(r evidence compat/tree/src/Ryujinx.Graphics.Shader/a.cs); [[ "$o" == *GAL* ]] && [[ "$o" != *整局：* ]]'
ck "证据：改服务 → IPC 回放、不起整局" 'o=$(r evidence services/S2A.Services/A.cs); [[ "$o" == *IPC* ]] && [[ "$o" != *整局：* ]]'
ck "证据：只改工具 → 单测即可" '[[ "$(r evidence tools/sched.sh)" == 单测即可* ]]'
# owns（10-25 总指挥：列车判红的钩子与本批有没有关）：按路由表 graphics/gate.sh 触发前缀 graphics/ runtime/ …——graphics/nvn 下的改动、runtime/ 下的改动都算它负责；文档、tools/ 不算
o=$(r owns graphics/gate.sh graphics/nvn/gfx/nvn/nvn_mtl.m runtime/src/gfxmode.c docs/a.md tools/train.sh); ck "owns graphics/gate.sh：只打 graphics/nvn/… 与 runtime/src/gfxmode.c（实得：${o}）" '[ "$o" = "graphics/nvn/gfx/nvn/nvn_mtl.m runtime/src/gfxmode.c " ]'
ck "owns：只改 tools/ 与文档 → 空" '[ -z "$(r owns graphics/gate.sh tools/train.sh docs/a.md | tr -d " ")" ]'
# 10-27 两例选测缺口：改 pack/jobs/saves.py（tool 档不跑 launchers/macos 钩子）→ 必选 pack_jobs 单测；改 pack/stage_direct.sh（在直连阶段闭包里；11-05 前样例是 runtime/run_mac.sh，出包不再起局后它不在闭包里）→ 必选 stage_keys 单测；
#   改 tools/sched.sh 两者都不选；临时克隆里 stage_direct.sh 新调用一个新脚本 tools/zz_probe.py（#550 的 mac_chain_check.py 同型）→ 改它也必选 stage_keys
o=$(r tests pack/jobs/saves.py); ck "改 pack/jobs/saves.py → 含 pack_jobs 单测（实得：${o}）" '[[ "$o" == *tests/pack_jobs_test.sh* ]]'
o=$(r tests pack/stage_direct.sh); ck "改 pack/stage_direct.sh → 含 stage_keys 单测" '[[ "$o" == *tests/stage_keys_test.sh* ]]'
o=$(r tests tools/sched.sh); ck "改 tools/sched.sh → 不含 pack_jobs / stage_keys 单测" '[[ "$o" != *pack_jobs_test* ]] && [[ "$o" != *stage_keys_test* ]]'
T=$(mktemp -d); git clone -q --shared "$H" "$T/c" 2> /dev/null && (cd "$T/c" && git checkout -q "$(git -C "$H" rev-parse HEAD)" 2> /dev/null; cp "$H/tools/gate_route.py" "$H/tests/stage_keys_test.sh" "$H/tests/pack_jobs_test.sh" "$T/c/tools/" 2> /dev/null
  cp "$H/tools/gate_route.py" tools/; cp "$H/tests/stage_keys_test.sh" "$H/tests/pack_jobs_test.sh" tests/; rm -f tools/stage_keys_test.sh tools/pack_jobs_test.sh
  echo 'print(1)' > tools/zz_probe.py; printf '\npython3 "$R/tools/zz_probe.py" > /dev/null\n' >> pack/stage_direct.sh
  git add -A > /dev/null && git -c user.email=t@t -c user.name=t commit -qm probe && python3 tools/gate_route.py tests tools/zz_probe.py) > "$T/o" 2>&1
ck "临时克隆：stage_direct.sh 新调用 tools/zz_probe.py，改它 → 含 stage_keys 单测（实得：$(tr '\n' ' ' < "$T/o" | cut -c1-200)）" 'grep -qx tests/stage_keys_test.sh "$T/o"'
rm -rf "$T"
# 定义侧负对照（#1044 列车线）：临时克隆里把 core-link 钩子文件头那行「# 门禁路由：runtime/src/ …」去掉 → 改 runtime/src/alt.c 不再选中它（正例见上面 alt.c 那条）
T=$(mktemp -d); git clone -q --shared "$H" "$T/c" 2> /dev/null && (cd "$T/c" && git checkout -q "$(git -C "$H" rev-parse HEAD)" 2> /dev/null
  cp "$H/tools/gate_route.py" "$H/tools/gate_decl.py" tools/ && cp "$H/android/core-link/gate.sh" android/core-link/gate.sh
  #   按行首删整行，不写死行尾文件清单（11-01：#1209 往这行加了 nvn_dirty.c，整行精确匹配删不掉，负对照假红）
  sed -i.bak '/^# 门禁路由：runtime\/src\/ /d' android/core-link/gate.sh
  rm -f android/core-link/gate.sh.bak
  grep -q '^# 门禁路由：runtime/src/' android/core-link/gate.sh && echo "负对照没删掉 runtime/src/ 登记行"
  python3 tools/gate_route.py hooks runtime/src/alt.c) > "$T/o" 2>&1
ck "负对照：临时克隆去掉 runtime/src/ 登记 → 改 runtime/src/alt.c 不选 core-link 钩子、原生钩子照选（实得：$(tr '\n' ' ' < "$T/o" | cut -c1-200)）" 'grep -qx runtime/gate.sh "$T/o" && ! grep -qx android/core-link/gate.sh "$T/o"'
rm -rf "$T"
[ $bad = 0 ] && echo "gate_route 单测全过" || { echo "gate_route 单测有不通"; exit 1; }

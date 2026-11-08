#!/bin/bash
# 门禁覆盖：pack/stage_direct.sh pack/roots.sh pack/refresh.sh
# 「出了直连库」判据各处一致（11-05：53d46fcb3 出包不起局后 Vulkan 款只出 vk/vk_shaders.tsv 表头，出库端多了一种形态；
#   判据当时散在 stage_direct.sh、refresh.sh、roots.sh root_pso0 三处各写一份，各自单测的假出库桩都只造「keys.tsv 非空」，
#   一处也没红，r4 Minecraft 出包红「直连缺口」后才逐处补（6e55b5df9、20d7bed3d））。
# 现状：refresh.sh 与 roots.sh 共用 root_has_direct；stage_direct.sh 判 direct.tmp（提交前的临时目录），另写一份（它是直连阶段「入」文件，
#   为收口改它会让全部款冷重出，不值）。本测从源码抽出两份认的形态（测试旗标 + 相对 direct 目录的路径）逐项比对：
#   ① stage_direct.sh 与 root_has_direct 形态集合相同，且都含 4 种（keys.tsv / gl 表头 / vk 表头 / runtime_only.txt）
#   ② refresh.sh 调 root_has_direct、不再自写「shaders/direct/keys.tsv」判据
# 期望按规则手写，不跑被测实现。
set -u
H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "🟢 $1"; else echo "🔴 $1"; bad=1; fi; }
forms() { grep -oE '\[ -[sf] "[^"]+" \]' | sed -E "s#\[ (-[sf]) \"[^\"]*${1}/([^\"]+)\" \]#\1 \2#" | sort -u; }
SD=$(grep -E 'direct\.tmp/keys\.tsv" \] \|\|' "$H/pack/stage_direct.sh" | forms 'direct\.tmp')
RH=$(grep -E '^root_has_direct\(\)' "$H/pack/roots.sh" | forms '\$d')
W=$(printf '%s\n' '-f runtime_only.txt' '-s gl/gl_shaders.tsv' '-s keys.tsv' '-s vk/vk_shaders.tsv')
ck "① stage_direct.sh 认的形态（$(echo $SD | tr '\n' ' ')）与 root_has_direct（$(echo $RH | tr '\n' ' ')）相同" '[ -n "$SD" ] && [ "$SD" = "$RH" ]'
ck "① 两处都含 4 种形态（keys.tsv / gl 表头 / vk 表头 / runtime_only.txt）" '[ "$RH" = "$W" ]'
ck "② refresh.sh 调 root_has_direct、不自写 shaders/direct/keys.tsv 判据" 'grep -q "root_has_direct" "$H/pack/refresh.sh" && ! grep -qE "\[ -s \"[^\"]*shaders/direct/keys\.tsv\" \]" "$H/pack/refresh.sh"'
[ $bad = 0 ] && echo "direct_forms 单测全过"; exit $bad

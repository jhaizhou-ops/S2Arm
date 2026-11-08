#!/bin/bash
# 单测不通时留现场（10-21 总指挥：按时间判的用例偶发红时临时目录跟着删了，没有现场只能猜机制）。在单测里 source 后调：
#   keep_scene <单测名> <目录>：把目录里的文本现场（*.log *.tsv *.txt *.json，单个 ≤ 20 MB）拷到
#   ${S2A_GATE_SCENE_DIR:-~/.s2arm/run/s2arm/wip/gate_scene}/<单测名>_<月日时分秒>_<pid>/（保留相对路径），打一行「现场 <主机>:<路径>」进门禁日志。
#   wip/ 下 6 小时没动由 tools/gc.sh 清；门禁派 mini 时现场在 mini 上（行里带主机名）
keep_scene() {
  local d=${S2A_GATE_SCENE_DIR:-$HOME/.s2arm/run/s2arm/wip/gate_scene}/${1}_$(date +%m%d%H%M%S)_$$
  mkdir -p "$d" && (cd "$2" 2> /dev/null && find . -type f \( -name '*.log' -o -name '*.tsv' -o -name '*.txt' -o -name '*.json' \) -size -20M -print0 | xargs -0 -I{} rsync -R -q {} "$d/") 2> /dev/null
  echo "现场 $(hostname -s):${d}（$(find "$d" -type f | wc -l | tr -d ' ') 个文件）"
}

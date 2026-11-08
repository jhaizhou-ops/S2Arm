#!/bin/bash
# 出包进度协议（10-25 jhz「速度还是好慢啊，能看到进度么？」）：一键出包（pack/oneclick/oneclick.sh）与启动器（pack/jobs/core.py run）读同一份进度文件。
#   调用方给 S2A_PROGRESS=<文件>；各阶段（任意一层子进程）每处理完一批就追加一行「时刻（秒）<TAB>阶段<TAB>已完成<TAB>总数」，没给就不写。
#   Python 子进程用 tools/progress.py（同一格式）。
# source 后：prog_tick <阶段> <已完成> <总数>
# 直接跑：bash tools/progress.sh show <文件> [现在（秒，单测用）] → 每个还没做完的阶段一段「<阶段> 已完成/总数（百分比），本段已用 X，预计还剩 Y」，
#   「；」隔开；预计 = 本段已用 ×（总数 − 已完成）÷ 已完成（本段起点 = 该阶段第一行的时刻；已完成为 0 时不估）。都做完了 / 没有文件 → 不打
#   总数 < S2A_PROG_EST_MIN（缺省 20）的是「阶段计数」（刷新各阶段 7/10、直连库 2/6）：各段耗时差几个数量级（解包十几秒、直连库一小时），按段数线性外推
#   没有意义（10-26 Air 斯普拉遁3：刷新 7/10 时报「还剩 32 分」且越跑越长），只报进度不估；逐项计数（编库 n/23502）照估
prog_tick() { [ -n "${S2A_PROGRESS:-}" ] || return 0; printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$S2A_PROGRESS"; }
prog_dur() { local s=$1; if [ "$s" -ge 3600 ]; then echo "$((s / 3600)) 小时 $((s % 3600 / 60)) 分"; elif [ "$s" -ge 60 ]; then echo "$((s / 60)) 分 $((s % 60)) 秒"; else echo "$s 秒"; fi; }
prog_show() {
  [ -s "${1:-}" ] || return 0
  local now=${2:-$(date +%s)} st d t t0 out=
  while IFS=$'\t' read -r st d t t0; do
    local e=$((now - t0)) p=$((d * 100 / t)) seg
    seg="$st $d/${t}（${p}%），本段已用 $(prog_dur $e)"; [ "$d" -gt 0 ] && [ "$t" -ge "${S2A_PROG_EST_MIN:-20}" ] && seg="${seg}，预计还剩 $(prog_dur $((e * (t - d) / d)))"
    out="${out:+${out}；}$seg"
  done < <(awk -F'\t' 'NF == 4 && $4 > 0 { if (!($2 in f)) { f[$2] = $1; o[++n] = $2 } d[$2] = $3; t[$2] = $4 }
    END { for (i = 1; i <= n; i++) { s = o[i]; if (d[s] < t[s]) printf "%s\t%d\t%d\t%d\n", s, d[s], t[s], f[s] } }' "$1")
  [ -n "$out" ] && echo "$out"; return 0
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1:-} in show) shift; prog_show "$@";; *) echo "用法：bash tools/progress.sh show <进度文件>" >&2; exit 2;; esac
fi

#!/bin/bash
# 自动玩家单测的假驾驶员（替 vision.sh）：bash fake_vision.sh <截图.png> <回答.json>
# 读假宿主写的当前状态（S2A_T_STATE），按 FAKE_MAP 作答：「状态=键1/键2/…[:play]」以分号分隔，如 TITLE=X/A;MENU=A;GAME=LS_RIGHT:play。
#   取第一个不在 S2A_VISION_TRIED（这页试过没用的键）里的键；带 :play 的状态回 playable=true。每次调用往 <截图目录>/../vision_calls.log 记一行「状态 键 试过」。
set -u
PNG=$1; OUT=$2; st=$(cat "${S2A_T_STATE:?}" 2> /dev/null); tried=",${S2A_VISION_TRIED:-},"
spec=$(printf '%s' "${FAKE_MAP:?}" | tr ';' '\n' | sed -n "s/^$st=//p" | head -1)
# FAKE_ESC_MAP（同格式，可空）：升级后端（S2A_VISION_ESCALATE=1）这一问按它作答、没写的状态照 FAKE_MAP（仿快档 haiku 与升级后端 sonnet 在同一页答得不一样）
if [ "${S2A_VISION_ESCALATE:-}" = 1 ]; then es=$(printf '%s' "${FAKE_ESC_MAP:-}" | tr ';' '\n' | sed -n "s/^$st=//p" | head -1); [ -n "$es" ] && spec=$es; fi
play=false; pp=; case $spec in (*:play) play=true; spec=${spec%:play};; (*:play[0-9][0-9]) pp=0.${spec##*:play}; play=true; spec=${spec%:play*};; esac
# :playNN = 可操控概率 0.NN（仿 Jev 低把握）；升级复核（S2A_VISION_ESCALATE=1）时这种页答「不是可操控」（仿暂停页：Jev 0.5 说是、升级后端说不是）
# FAKE_ESC_PLAY=1：升级复核也说可操控（仿街霸合集：Jev 低把握、升级后端确认在对战里）
[ -n "$pp" ] && [ "${S2A_VISION_ESCALATE:-}" = 1 ] && [ -z "${FAKE_ESC_PLAY:-}" ] && play=false
key=; IFS=/ read -ra cand <<< "$spec"; for k in "${cand[@]}"; do b=$k; case $k in (TOUCH:*) b=TOUCH;; esac   # 按完整动作比（同 autoplay.c tried_add：A:2 与 A 是两个、点触记 TOUCH）
  case $tried in (*,"$b",*) ;; (*) key=$k; break;; esac; done
echo "$st ${key:-无} ${S2A_VISION_TRIED:-}" >> "$(dirname "$PNG")/../vision_calls.log"
echo "$st ${S2A_VISION_ESCALATE:-0}" >> "$(dirname "$PNG")/../vision_env.log"   # 这一问是否升级后端
[ -n "$key" ] && ks="[\"${key//+/\",\"}\"]" || ks='[]'   # 「LEFT+A」= 一次答两个键
# 没键可按：同 vision.sh 的 "empty"——WAIT = 模型答空（等加载），候选全试过 = tried
em=; [ "$key" = WAIT ] && { ks='[]'; em=', "empty": "wait"'; }; [ -z "$key" ] && [ -n "$spec" ] && em=', "empty": "tried"'
printf '{"keys": %s, "playable": %s%s%s, "why": "假驾驶员：%s 页"}\n' "$ks" "$play" "${pp:+, \"p_play\": $pp}" "$em" "$st" > "$OUT"

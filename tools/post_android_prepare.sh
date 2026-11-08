#!/bin/bash
# 合入后钩子（tools/post_merge.tsv 登记；11-01 总指挥）：安卓 APK 门禁的准备标记跟上 main。
#   改准备清单（android/docker/cache-identity.py 的 REQUIRED）的合入一落 main，门禁机上的旧标记就失效，
#   原先要人记得去跑 prepare，期间 APK 门禁红、守望把它二分到改清单的那笔合入（11-01 #1207 / #1297）。
#   这里每次合入后在本机核宿主路标记（host/gate-apk.sh 只核标记模式，几秒），缺 / 不匹配就重跑宿主 prepare.sh（后台由 train_post.sh 托管），
#   跑完删守望的 last_checked，让守望重跑这一提交（补跑那一步）。标记相符直接退 0。
# 只在 macOS 门禁机跑（APK 门禁「门禁本机：apk」只在本机）；非 macOS 退 0。两棵钩子树可能同时跑，prepare 串行：同一把锁排队。
# 只核宿主路：macOS 上 APK 门禁不跑 docker 镜像步（#1299 / #1327，android/gate.sh run_apk_gate），备 docker 路是白备、核它报红是假红。
set -u
[ "$(uname -s)" = Darwin ] || { echo "非 macOS：本机不跑安卓 APK 门禁，跳过"; exit 0; }
TD=${S2A_TRAIN_DIR:-$HOME/.s2arm/run/s2arm/train}; LK=${S2A_ANDROID_PREPARE_LOCK:-$HOME/.cache/s2arm-build/post-prepare.lock}
mkdir -p "$(dirname "$LK")"
until mkdir "$LK" 2> /dev/null; do
  p=$(cat "$LK/pid" 2> /dev/null); kill -0 "$p" 2> /dev/null || { rm -rf "$LK"; continue; }
  echo "另一轮 prepare 在跑（pid ${p}），排队"; sleep 30; done
echo $$ > "$LK/pid"; trap 'rm -rf "$LK"' EXIT
need=()
for r in host; do
  o=$(S2A_APK_RECEIPT_CHECK=1 timeout 600 bash "android/$r/gate-apk.sh" 2>&1); rc=$?
  case $rc in
    0) echo "${r}：准备标记与当前依赖清单相符";;
    42) echo "${r}：$(tail -1 < <(printf '%s\n' "$o"))，重跑 prepare"; need+=("$r");;
    *) echo "${r}：只核标记退出 ${rc}（不是备料能修的，交门禁照常报）：$(tail -1 < <(printf '%s\n' "$o") | cut -c1-200)";;
  esac
done
[ ${#need[@]} -gt 0 ] || exit 0
bad=0
for r in "${need[@]}"; do
  # 心跳：NativeAOT 一步十几分钟没输出，会被 train_post.sh 的进展看门狗判挂死
  s=$SECONDS; ( while sleep 300; do echo "仍在 $r prepare（$((SECONDS - s)) 秒）"; done ) & hb=$!
  bash "android/$r/prepare.sh"; rc=$?; kill $hb 2> /dev/null; wait $hb 2> /dev/null
  echo "$r prepare：rc=${rc}，$((SECONDS - s)) 秒"; [ $rc = 0 ] || bad=1
done
[ $bad = 0 ] || { echo "🔴 安卓 APK 准备没跑通（见上），门禁照常报待宿主证 / 红"; exit 1; }
rm -f "$TD/watch/last_checked"
echo "安卓 APK 准备已跟上 $(git rev-parse --short=9 HEAD 2> /dev/null)：$(printf '%s ' "${need[@]}")；已让守望重跑本提交"

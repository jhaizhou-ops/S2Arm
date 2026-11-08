#!/bin/bash
# 管线分片并行编：本机与 mini 从同一队列领片（shader_pack.sh ④ 调；10-21 测试出包线：怪猎补全后 210 片、本机独编 976 秒）
#   bash pso_dist.sh run <分片清单文件（每行一个 pso.N.mtl4-json 或 pso.N.mtlp-json）> [应有片数]   本机编排：本机 PJ 个领片进程 + 一个 mini 送片进程，全部片做完才退出（编片红看 .fail、退出码 0；
#                                                                         给了应有片数而清单行数不符 → 不编、退出 1）
#   bash pso_dist.sh list <目录> <清单文件>                                列出 <目录>/pso.*.mtl4-json 与 pso.*.mtlp-json 到清单（find，不经命令行参数：怪猎 / 奥德赛上万片时
#                                                                         通配展开超 ARG_MAX 1 MB，ls 退出 126、清单 0 字节，10-24 #100）；find 失败退出 1
# 两种后缀（pso_gen 按 PSO_M3 二选一：Metal 4 .mtl4-json / Metal 3 .mtlp-json）：片号一律「去掉最后一个 .后缀 再取最后一段」（pso.3.mtlp-json → 3），
#   与 pso_chunk.sh:14 同一算法。若按 ${S%.mtl4-json} 写死去后缀，.mtlp-json 会算成 n=mtlp-json：全部片共用一个产物名，后编的覆盖先编的（tests/t_pso_cache.sh ⑨ 是这条的反证用例）。
#   队列（claim / done / nomini）按数字片号认片，所以 list 两种都列、但一个工作目录只放一种后缀：同号两种后缀混放会在 run 里报红，不当成同一片静默只编一次。
#   mini 编片服务只接 Metal 4 脚本（applegpu-nt -N 按扩展名认脚本、只认 .mtl4-json），.mtlp-json 片不进 mini 队列、全在本机编（feeder 里标 nomini 并报一行）。
#   bash pso_dist.sh serve <远端队列目录> [并行数]                      mini 上的编片服务（run 经 tools/remote.sh 起，不手工调）
# 分工 = 工作窃取：清单按分片脚本大小降序（与后缀无关，大的先编，尾巴是小片）；本机领片进程与 mini 送片进程都从头扫、mkdir 抢「领」标记，
#   谁快谁多领——本机被别的活占满时 mini 自然多编，不按核数比例写死。mini 在途片数 ≤ 远端并行数 + 1（多 1 片垫着，掩盖传输）。
#   本机领片进程每片走 pso_chunk.sh（先查缓存）；送片进程先在本机查缓存（--hit），不中才送 mini；mini 编好拉回后 pso_chunk.sh --put 进产物与缓存（键只在本机算）。
# mini 那边（tools/remote.sh：只跑提交态、远端满核槽、工具链核对、本机退出远端跟着被杀）：
#   serve 用 mini 上的统一工具链（tools/toolchain.env，与本机同一路径），核 SDK 版本 = PSO_SV 且 applegpu-nt 版本 = PSO_NTV（缓存键里的两项逐字相同），对不上就不开工（server.err）；
#   函数库（各片 gal.N.metallib）开工前整份传一次，分片脚本里的库路径在本机改成远端路径再送。
# 退回本机（不用 mini、照样全做完）：S2A_PSO_REMOTE=off；工作树有未提交改动 / 连不上 / 工具链不同 / 远端满核槽一直被占（remote.sh 退出）；
#   mini 中途掉线或送片进程死了 → 它在途的片「领」标记被收回，本机领片进程接着编；mini 编失败的片也收回、只在本机重编（红以本机日志为准）。
# 一致性（10-21 实测，怪猎曲面一片 112 个管线）：applegpu-nt 同输入本机两次编出来字节就不同（macOS 大小差 16 字节、iOS 差 1888 字节），不比字节；
#   改用运行时探针（tests/archprobe.m，MTL4Archive 按运行时描述查）：本机架构 macOS 26 归档 本机两次 / mini 一次（mini 经 serve、Xcode-26.6 同版 applegpu-nt）都 112/112。
# 环境：pso_chunk.sh 的 PSO_*（run 时）；PSO_PJ 本机并行片数（缺省 1）；S2A_PSO_REMOTE=auto（缺省）| off；PSO_MJ 远端并行片数（缺省远端核数：每片单线程 PSO_NTJ=1）；
#   PSO_REMOTE_NT 远端编译器路径（只给单测：不在 Xcode 里找）；S2A_REMOTE / S2A_REMOTE_ROOT 同 tools/remote.sh（单测用 local 模拟）
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); R=$(cd "$H/../../.." && pwd)
CH=$H/pso_chunk.sh
t(){ echo "[$(date +%T)] $*"; }

serve() {
  local Q=$1 MJ=${2:-${PSO_MJ:-}} SDKN d nt DD= NT= i
  mkdir -p "$Q/in" "$Q/out" "$Q/run" || exit 125
  [ -n "$MJ" ] || MJ=$(sysctl -n hw.ncpu); [ "$MJ" -ge 1 ] || MJ=1   # 每片单线程（PSO_NTJ=1），道数 = 核数
  SDKN=$([ "$PSO_PLAT" = ios ] && echo iphoneos || echo macosx)
  if [ -n "${PSO_REMOTE_NT:-}" ]; then NT=$PSO_REMOTE_NT; DD=$(xcode-select -p 2> /dev/null)
  else
    d=$(source "$(dirname "${BASH_SOURCE[0]}")/../../../tools/toolchain.sh" 2> /dev/null && echo "$DEVELOPER_DIR")
    if [ -n "$d" ] && [ "$(DEVELOPER_DIR=$d xcrun --sdk "$SDKN" --show-sdk-version 2> /dev/null)" = "$PSO_SV" ]; then
      nt=$(dirname "$(DEVELOPER_DIR=$d xcrun -f metal-tt 2> /dev/null)")/../metal/current/bin/applegpu-nt
      [ -x "$nt" ] && [ "$("$nt" --version 2>&1 | head -1)" = "$PSO_NTV" ] && { DD=$d; NT=$nt; }
    fi
  fi
  [ -n "$NT" ] || { echo "远端统一工具链（tools/toolchain.env）不是 SDK ${PSO_SV}（${SDKN}）+ ${PSO_NTV}" > "$Q/server.err"; exit 3; }
  SP=$(DEVELOPER_DIR=$DD xcrun --sdk "$SDKN" --show-sdk-path 2> /dev/null)
  echo "$MJ" > "$Q/ready.tmp" && mv "$Q/ready.tmp" "$Q/ready"
  for i in $(seq 1 "$MJ"); do sworker & done
  wait
}
sworker() {   # 远端领片：按送达序号（文件名前缀）领 in/<序号>.<片号>.go，编到 out/<片号>.bin，写 .ok / .fail；见到 end 且没有可领的就退出
  local g b n got
  while :; do
    got=
    for g in "$Q"/in/*.go; do
      [ -e "$g" ] || continue
      b=$(basename "$g" .go); n=${b#*.}
      mkdir "$Q/run/$n" 2> /dev/null && { got=$n; break; }
    done
    if [ -z "$got" ]; then [ -e "$Q/end" ] && return 0; sleep 0.3; continue; fi
    # -j 与本机 pso_chunk.sh 同（PSO_NTJ 进缓存键，--put 按本机键入缓存，远端线程数必须一致）
    if timeout 900 "$NT" -arch "$PSO_A" -platform_version "$PSO_PLAT" "$PSO_M.0" "$PSO_SV" -sysroot "$SP" ${PSO_NTJ:+-j "$PSO_NTJ"} -N "$Q/in/$b.mtl4-json" -o "$Q/out/$n.bin.tmp" > "$Q/out/$n.log" 2>&1 \
      && [ -s "$Q/out/$n.bin.tmp" ] && mv "$Q/out/$n.bin.tmp" "$Q/out/$n.bin"; then touch "$Q/out/$n.ok"; else touch "$Q/out/$n.fail"; fi
  done
}

# 片号写进 IDX（不 echo：调用方写 $(idx …) 每次都 fork 子 shell，清单 263 片时本机工人一轮约 3.5 万次 fork，10-21 测片长 P=40 调度开销约 0.3 秒 / 片）
# 去后缀取片号：与 pso_chunk.sh:14 同一算法（去掉最后一个 .xxx 再取最后一段），两种后缀都算对。
#   写死 ${1%.mtl4-json} 的话 .mtlp-json 片算成 n=mtlp-json，TAG / claim / done / 产物名全撞在一起
idx() { local x=${1%.*}; IDX=${x##*.}; }
lworker() {   # 本机领片：顺着清单扫，抢到就编（pso_chunk.sh 先查缓存），编完接着往下扫（不回头：前面的都已领或已做完）
  # 一轮扫完：送片进程还活着 → 等 0.5 秒再扫（mini 可能退回在途片）；送片进程没起过或已退出 → 先收回 mini 没做完的领标记，收回了就再扫，
  #   没收回的 = 剩下没做完的都是别的本机工人正在编的，本工人退出（它们自己收尾）。
  #   10-25 #266 BossaMelon（M5 Max 冷烘 6357 片，S2A_PSO_REMOTE=off）：原先送片进程不在时每轮都把全部领标记逐个 basename + cat（每片两次 fork），
  #   本机负载下约 7 片 / 秒、一轮十几分钟，最后几片还在编时空转的工人一直这样扫，看门狗「600 秒没有新产出」杀掉整个着色器阶段
  #   退出前要有一整轮是在「已确认送片进程不在」之后开始扫、且一片都没领到（送片进程退出前会把在途片退回成没领，早一轮扫的会漏看）
  local c n left got fpid gone=0 g0
  while :; do
    left=0; got=0; g0=$gone
    while read -r c; do
      idx "$c"; n=$IDX; [ -e "$LQ/done/$n" ] && continue; left=1
      mkdir "$LQ/claim/$n" 2> /dev/null || continue
      got=1; echo local > "$LQ/claim/$n/by"; bash "$CH" "$c"; mkdir "$LQ/done/$n" 2> /dev/null && echo local > "$LQ/done/$n/by"
    done < "$LQ/list"
    [ $left = 0 ] && return 0
    fpid=$(cat "$LQ/feeder.pid" 2> /dev/null)
    if [ -n "$fpid" ] && kill -0 "$fpid" 2> /dev/null; then sleep 0.5; continue; fi
    gone=1; reclaim_mini && continue
    [ $g0 = 1 ] && [ $got = 0 ] && return 0
  done
}
reclaim_mini() {   # 送片进程已退出：删掉 mini 领了没做完的领标记（一次 find + grep，不逐片 fork）；删了至少一个 → 0（调用方再扫），没有 → 1
  [ -e "$LQ/feeder.pid" ] || return 1   # 没起过送片进程（S2A_PSO_REMOTE=off / 连不上远端）：不会有 mini 领标记
  local f n r=1
  while read -r f; do [ -n "$f" ] || continue; n=${f%/by}; n=${n##*/}; [ -e "$LQ/done/$n" ] || { rm -rf "$LQ/claim/$n"; r=0; }
  done < <(find "$LQ/claim" -mindepth 2 -maxdepth 2 -name by -exec grep -lx mini {} + 2> /dev/null)
  return $r
}
progress() {   # 进度行（看门狗按工作目录里有没有新写入判进展）：做完的片数变了才打，最多 30 秒一行；没进展不打，免得心跳把卡死盖住
  local d last=-1 tot; tot=$(grep -c . "$LQ/list")
  while sleep "${PSO_PROGRESS_S:-30}"; do d=0; for f in "$LQ"/done/*; do [ -e "$f" ] && d=$((d + 1)); done
    [ $d != $last ] && { echo "  进度：$(date +%T) 做完 ${d} / ${tot} 片"; last=$d; }; done
}

# ---- mini 送片进程 ----
rx() { if [ "$HOST" = local ]; then timeout "${2:-60}" bash -c "$1"; else timeout "${2:-60}" ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 "$HOST" "bash -c $(printf '%q' "$1")"; fi; }
rp() { if [ "$HOST" = local ]; then echo "$1"; else echo "$HOST:$1"; fi; }
rs() { (cd "$R" && exec bash tools/remote.sh "$@"); }   # remote.sh 按当前目录认仓库：调用方（出包流程）当前目录不一定在仓库里
release() { local n; for n in $INF; do [ -e "$LQ/done/$n" ] || rm -rf "$LQ/claim/$n"; done; INF=; }
feeder() {
  local RH Q MJ c n seq=0 rpid out f kq=0 RUNID tmp M3SKIP=   # M3SKIP 必须显式赋空：set -u 下 local 只声明不赋值算未定义
  INF=; HOST=$(rs --host 2> /dev/null) && RH=$(rs --home 2> /dev/null) && [ -n "$RH" ] || { echo "mini：连不上（remote.sh --home 失败），全在本机编"; return 0; }
  RUNID=$(date +%m%d%H%M%S)-$$; Q=$RH/.s2arm/run/s2arm/psoq/$RUNID
  rx "mkdir -p '$Q/lib' && find '$RH/.s2arm/run/s2arm/psoq' -mindepth 1 -maxdepth 1 -mmin +720 -exec rm -rf {} + 2> /dev/null; true" || { echo "mini：建远端队列目录失败，全在本机编"; return 0; }
  # 远端编片服务：remote.sh 只接提交态、拿远端满核槽（排队上限 = 本机做完为止，本机做完就杀）
  # 不经 rs 函数后台起：函数 & 先开一层子 shell、函数体的 ( … exec ) 再开一层，$! 是外层，kill $rpid 杀不到 remote.sh，
  #   它成孤儿继续排 / 占 mini 满核槽（10-21 每次重烘漏一个，14 个孤儿占槽，mini 一下午编 0 片）；这里只开一层、exec 后 $! 就是 remote.sh
  (cd "$R" && S2A_REMOTE_WAIT_S=${S2A_REMOTE_WAIT_S:-3600} S2A_REMOTE_PRIO=${S2A_REMOTE_PRIO:-3} exec bash tools/remote.sh --name "pso-$(basename "$R")" --timeout 3600 --env PSO_A --env PSO_PLAT --env PSO_M --env PSO_SV --env PSO_NTV --env PSO_NTJ --env PSO_MJ --env PSO_REMOTE_NT \
    -- bash graphics/tools/shbake/pso_dist.sh serve "$Q") > "$PSO_W/pso_mini.$PSO_A.$PSO_PLAT$PSO_M.log" 2>&1 &
  rpid=$!; trap 'kill $rpid 2> /dev/null; exit 143' TERM INT   # 被杀时带走 remote.sh（它一退，远端命令跟着被杀、远端满核槽放掉）
  # 函数库整份传一次（和 remote.sh 起服务并行）
  timeout 900 rsync -a ${HOST:+-e "ssh -o BatchMode=yes -o ConnectTimeout=8"} "$PSO_O"/gal.*.metallib "$(rp "$Q/lib/")" 2>> "$PSO_W/pso_mini.$PSO_A.$PSO_PLAT$PSO_M.log" \
    || { echo "mini：传函数库失败，全在本机编"; kill $rpid 2> /dev/null; wait $rpid 2> /dev/null; return 0; }
  while :; do   # 等远端服务起来（本机已经在编）：服务报错 / remote.sh 退了 / 本机全做完 → 不用 mini
    rx "test -e '$Q/ready'" 20 && break
    kill -0 $rpid 2> /dev/null || { echo "mini：远端服务没起来（$(tail -1 "$PSO_W/pso_mini.$PSO_A.$PSO_PLAT$PSO_M.log" | cut -c1-200)）$(rx "cat '$Q/server.err' 2> /dev/null" 20)，全在本机编"; return 0; }
    [ -z "$(left_unclaimed)" ] && { kill $rpid 2> /dev/null; wait $rpid 2> /dev/null; rx "rm -rf '$Q'"; echo "mini：远端服务起来前本机已全部领完"; return 0; }
    sleep 2
  done
  MJ=$(rx "cat '$Q/ready'" 20); [ "${MJ:-0}" -ge 1 ] 2> /dev/null || MJ=1
  echo "mini：远端编片服务就绪（并行 ${MJ}）"
  tmp=$(mktemp -d)
  while :; do
    # 补货：在途 < MJ + 1 就再领（先本机查缓存，命中不送）
    while [ $(echo $INF | wc -w) -le "$MJ" ]; do
      c=$(left_unclaimed | head -1); [ -n "$c" ] || break
      # Metal 3 老格式片不进 mini 队列：远端编片服务用 applegpu-nt -N，它按扩展名认脚本、只认 .mtl4-json（metal/tests/t_m3probe.m:16 实测）；
      #   .mtlp-json 要走 metal-tt，远端没有这条路，送过去必然 .fail、白等一次传输与 900 秒编译超时。标 nomini = 只不再往队列送，本机工人照编。
      case $c in *.mtlp-json)
        idx "$c"; mkdir -p "$LQ/nomini/$IDX"
        [ -n "$M3SKIP" ] || { M3SKIP=1; echo "mini：Metal 3 片（.mtlp-json）不进 mini 队列（远端编片服务只接 Metal 4 脚本），全在本机编"; }
        continue;;
      esac
      idx "$c"; n=$IDX; mkdir "$LQ/claim/$n" 2> /dev/null || continue
      echo mini > "$LQ/claim/$n/by"
      if bash "$CH" --hit "$c"; then mkdir "$LQ/done/$n" 2> /dev/null && echo local > "$LQ/done/$n/by"; continue; fi
      # 队列文件名 = 送达序号 . 片号 . 原名后缀：上面已把 .mtlp-json 挡掉，所以这里进来的都是 Metal 4 脚本，
      #   写死 .mtl4-json 与原名后缀一致（applegpu-nt -N 按扩展名认脚本，后缀写成别的它会拒收）
      seq=$((seq + 1)); f=$(printf '%05d.%s' $seq "$n")
      python3 -c 'import json,os,sys;j=json.load(open(sys.argv[1]))
for l in j["libraries"]: l["path"]=os.path.join(sys.argv[2],os.path.basename(l["path"]))
json.dump(j,open(sys.argv[3],"w"))' "$c" "$Q/lib" "$tmp/$f.mtl4-json" && : > "$tmp/$f.go" \
        && timeout 120 rsync -a ${HOST:+-e "ssh -o BatchMode=yes -o ConnectTimeout=8"} "$tmp/$f.mtl4-json" "$(rp "$Q/in/")" \
        && timeout 60 rsync -a ${HOST:+-e "ssh -o BatchMode=yes -o ConnectTimeout=8"} "$tmp/$f.go" "$(rp "$Q/in/")" \
        || { rm -rf "$LQ/claim/$n"; echo "mini：送第 $n 片失败，退回本机"; release; break 2; }
      rm -f "$tmp/$f.mtl4-json" "$tmp/$f.go"; INF="$INF $n"
    done
    [ -z "$INF" ] && [ -z "$(left_unclaimed)" ] && break
    # 收货
    out=$(rx "cd '$Q/out' && ls" 30) || { kq=$((kq + 1)); [ $kq -ge 3 ] && { echo "mini：连续 3 次读不到远端结果，退回本机"; release; break; }; sleep 1; continue; }
    kq=0
    for n in $INF; do
      if grep -qx "$n.ok" <<< "$out"; then
        if timeout 300 rsync -a ${HOST:+-e "ssh -o BatchMode=yes -o ConnectTimeout=8"} "$(rp "$Q/out/$n.bin")" "$tmp/$n.bin" && bash "$CH" --put "$(grep -m1 -E "\.$n\.(mtl4|mtlp)-json$" "$LQ/list")" "$tmp/$n.bin"; then
          mkdir "$LQ/done/$n" 2> /dev/null && echo mini > "$LQ/done/$n/by"
        else echo "mini：拉回第 $n 片失败，退回本机"; mkdir -p "$LQ/nomini/$n"; rm -rf "$LQ/claim/$n"; fi
        rm -f "$tmp/$n.bin"; INF=$(echo " $INF " | sed "s/ $n / /"); INF=$(echo $INF)
      elif grep -qx "$n.fail" <<< "$out"; then
        timeout 60 rsync -a ${HOST:+-e "ssh -o BatchMode=yes -o ConnectTimeout=8"} "$(rp "$Q/out/$n.log")" "$PSO_W/pso_$PSO_A.$PSO_PLAT$PSO_M.$n.mini.log" 2> /dev/null
        echo "mini：第 $n 片编失败（$PSO_W/pso_$PSO_A.$PSO_PLAT$PSO_M.$n.mini.log），退回本机重编"; mkdir -p "$LQ/nomini/$n"; rm -rf "$LQ/claim/$n"
        INF=$(echo " $INF " | sed "s/ $n / /"); INF=$(echo $INF)
      fi
    done
    kill -0 $rpid 2> /dev/null || { echo "mini：远端服务退了（$(tail -1 "$PSO_W/pso_mini.$PSO_A.$PSO_PLAT$PSO_M.log" | cut -c1-200)），在途 $(echo $INF | wc -w) 片退回本机"; release; break; }
    sleep 1
  done
  rx "touch '$Q/end'" 20; for _ in $(seq 1 30); do kill -0 $rpid 2> /dev/null || break; sleep 1; done
  kill $rpid 2> /dev/null; wait $rpid 2> /dev/null; rx "rm -rf '$Q'" 60; rm -rf "$tmp"
}
left_unclaimed() {   # 清单顺序里还没领、没做完、没被 mini 退回过的片
  local c n
  while read -r c; do idx "$c"; n=$IDX; [ -e "$LQ/done/$n" ] || [ -e "$LQ/claim/$n" ] || [ -e "$LQ/nomini/$n" ] || echo "$c"; done < "$LQ/list"
}

run() {
  local L=$1 WANT=${2:-} PJ=${PSO_PJ:-1} i fp nl nm d f
  # 应有片数（调用方另行数的）与清单行数不符 = 清单坏了（10-24 #100：ls 超 ARG_MAX 清单 0 字节，原先当「没有分片」返回 0、出包照绿，到零归档检查才红）
  if [ -n "$WANT" ]; then
    local got; got=$(grep -c . "$L" 2> /dev/null); got=${got:-0}
    [ "$got" = "$WANT" ] || { echo "🔴 分片清单 ${L}：${got} 行，应有 ${WANT} 片（清单没列全）"; return 1; }
  fi
  LQ=$(mktemp -d "${TMPDIR:-/tmp}/pso_dist.XXXXXX"); mkdir -p "$LQ/claim" "$LQ/done" "$LQ/nomini"
  # 大的先编（LPT）：按分片脚本大小降序
  # GNU -f 是文件系统信息，失败仍可能输出多行；只接受成功读取的字节数。
  # 不把读大小、排序、去前缀串成管道，任一步失败都不得启动部分队列。
  local c size
  [ -r "$L" ] || { echo "🔴 读取分片清单失败：$L" >&2; rm -rf "$LQ"; return 1; }
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if size=$(stat -c %s "$c" 2> /dev/null); then :
    elif size=$(stat -f %z "$c" 2> /dev/null); then :
    else echo "🔴 读取分片大小失败：$c" >&2; rm -rf "$LQ"; return 1
    fi
    case "$size" in ''|*[!0-9]*) echo "🔴 分片大小不是字节数：$c" >&2; rm -rf "$LQ"; return 1;; esac
    printf '%s %s\n' "$size" "$c"
  done < "$L" > "$LQ/sizes"
  LC_ALL=C sort -k1,1nr -k2 "$LQ/sizes" > "$LQ/sorted" && cut -d' ' -f2- "$LQ/sorted" > "$LQ/list" \
    || { echo "🔴 分片清单排序失败：$L" >&2; rm -rf "$LQ"; return 1; }
  [ -s "$LQ/list" ] || { rm -rf "$LQ"; return 0; }
  # 一个工作目录只放一种后缀：队列按数字片号认片，.mtl4-json 与 .mtlp-json 同号会撞同一个 claim / done（后一片被当成已做完、静默漏编）
  local dup; dup=$(awk -F. 'NF > 1 { print $(NF - 1) }' "$LQ/list" | LC_ALL=C sort | uniq -d | head -3 | tr '\n' ' ')
  [ -z "$dup" ] || { echo "🔴 分片清单 ${L}：片号 ${dup% } 两种后缀同时存在（一个目录只放一种后缀；混放会当成同一片、漏编）"; rm -rf "$LQ"; return 1; }
  fp=; trap 'kill $(jobs -p) 2> /dev/null; rm -rf "$LQ"' EXIT; trap 'exit 143' TERM INT
  if [ "${S2A_PSO_REMOTE:-auto}" != off ]; then feeder > "$LQ/feeder.log" 2>&1 & fp=$!; echo $fp > "$LQ/feeder.pid"; fi
  local wp= pp; progress & pp=$!
  for i in $(seq 1 "$PJ"); do lworker & wp="$wp $!"; done
  wait $wp; pkill -P $pp 2> /dev/null; kill $pp 2> /dev/null; wait $pp 2> /dev/null
  d=0; for f in "$LQ"/done/*; do [ -e "$f" ] && d=$((d + 1)); done; echo "  进度：$(date +%T) 做完 ${d} / $(grep -c . "$LQ/list") 片"
  [ -n "$fp" ] && { wait "$fp"; sed 's/^/  /' "$LQ/feeder.log"; }
  nl=$(cat "$LQ"/done/*/by 2> /dev/null | grep -cx local); nm=$(cat "$LQ"/done/*/by 2> /dev/null | grep -cx mini)
  echo "  分工：本机 ${nl} 片（含缓存命中）/ mini ${nm} 片，共 $(grep -c . "$LQ/list") 片"
}

case ${1:-} in
  run) run "${2:?分片清单}" "${3:-}";;
  list) find "${2:?目录}" -maxdepth 1 -type f \( -name 'pso.*.mtl4-json' -o -name 'pso.*.mtlp-json' \) > "${3:?清单文件}.tmp" && LC_ALL=C sort "${3}.tmp" > "$3" && rm -f "${3}.tmp" \
          || { echo "🔴 列分片失败：${2}"; exit 1; };;
  serve) Q=${2:?远端队列目录}; serve "$Q" "${3:-}";;
  *) echo "用法：pso_dist.sh run <分片清单> [应有片数] | list <目录> <清单文件> | serve <远端队列目录> [并行数]" >&2; exit 2;;
esac

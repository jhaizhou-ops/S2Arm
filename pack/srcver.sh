#!/bin/bash
# 出包·原件版本核对：pack/srcver.sh <款>（pack/refresh.sh 开头调）
# 现行产物根的程序版本（exefs/main 构建号，NSO 头 0x40 起 16 字节）必须与本机原件（卡带 / 安装包 + 更新，按内容认包，pack/srcs.sh）选出的那一版相同。
#   10-25 总指挥：共享根动森停在 3.0.0（10-12 解包，之后各版本都从它克隆，刷新链里没有解包这一步），本机原件已是 3.0.3；
#   追加内容阶段因版本不符每次报黄跳过，正式包一直不带 DLC。玩家一键出包用的是自己手上最新的原件，我们的正式包也必须这样。
# 比法：nx_unpack --nacp-only 本身会把原件解出的 main 与输出目录里已有的 exefs/main 比构建号（不符报「版本不符」退出 1），
#   这里把现行 exefs/main 放进临时目录交给它比，不另写一套解包。
# 退出：0 = 相同；1 = 不同（打一行【红】，写明要按原件重解）；2 = 核不了（本机没有该款原件 / 解不出），打一行【黄】，刷新照常。
# 结果按键缓存（S2A_SRCVER_CACHE，缺省 run/s2arm/cache/srcver/<款>-<键>）：键 = 候选原件「路径 大小 修改时间 程序号」+ nx_unpack 程序内容哈希（只取哈希列，不带工具路径）+ 现行 main 构建号，
#   原件、工具、现行版本都没变就不再解（核不了的不缓存）
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd); source "$H/roots.sh"; source "$H/srcs.sh"
CUR=$(root_cur "$G"); [ -n "$CUR" ] && [ -f "$CUR/exefs/main" ] || { echo "【红】$G 现行产物根没有 exefs/main"; exit 1; }
TID=$(prog_id "$CUR"); [ -n "$TID" ] || { echo "🟡 $G 现行产物根取不到程序号，原件版本没核"; exit 2; }
L=$(src_ids) || { echo "🟡 $G 原件探测出错（见上一行【红】，机器原因），原件版本没核"; exit 2; }
L=$(printf '%s\n' "$L" | awk -F'\t' -v t="$TID" 'toupper($4) == t || $4 == "-"')
echo "$L" | awk -F'\t' -v t="$TID" 'toupper($4) == t {f=1} END {exit !f}' || { echo "🟡 $G 本机 ${SRC_DIR} 下没有程序号 $TID 的原始包，原件版本没核"; exit 2; }
# Python 是出包工具链的既有依赖；缺读工具、读盘失败或短头不能生成空构建号缓存。
MB=$(python3 -c '
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(0x40)
    build_id = f.read(16)
if len(build_id) != 16:
    raise ValueError("NSO 构建号不足 16 字节")
print(build_id.hex())
' "$CUR/exefs/main" 2>/dev/null) || { echo "🟡 $G 现行 main 构建号读不出，原件版本没核"; exit 2; }
# 工具只按内容进键：shasum 带文件名（完整检出 / 家目录路径）时换目录键就变，只取哈希列（同 pack/stage_rewrite.sh 10-23 那处）
K=$( { echo "$L"; for t in "$SRC_N.dll" "$SRC_N"; do [ -f "$t" ] && shasum -a 256 < "$t"; done; echo "$MB"; } | shasum -a 256 | cut -c1-16)
C=${S2A_SRCVER_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/srcver}/$G-$K
if [ ! -f "$C" ]; then
  fs=(); while IFS=$'\t' read -r f _; do fs+=("$f"); done <<< "$L"
  T=$(mktemp -d); mkdir -p "$T/exefs" && cp "$CUR/exefs/main" "$T/exefs/main" || { rm -rf "$T"; echo "🟡 $G 建核对目录失败，原件版本没核"; exit 2; }
  o=$("$SRC_N" "$SRC_K" "$T" --nacp-only --title-id="$TID" "${fs[@]}" 2>&1); r=$?; rm -rf "$T"
  mkdir -p "$(dirname "$C")"
  if [ $r = 0 ]; then printf '0\n' > "$C.tmp.$$"
  elif grep -q '版本不符' <<< "$o"; then printf '1\n%s\n' "$(grep -m1 '版本不符' <<< "$o" | sed 's/^🔴 //')" > "$C.tmp.$$"
  else echo "🟡 $G 原件解不出（$(tail -1 <<< "$o" | cut -c1-200)），原件版本没核"; exit 2; fi
  mv "$C.tmp.$$" "$C"
fi
[ "$(head -1 "$C")" = 0 ] && { echo "🟢 $G 现行程序版本与本机原件相同（main 构建号 ${MB:0:16}…）"; exit 0; }
echo "【红】$G 现行产物根（$(basename "$CUR")，main 构建号 ${MB:0:16}…）与本机原件不是同一版本：$(sed -n 2p "$C")。要按原件重解再出包（共享根找运维线；pack/stages/unpack.sh extract --src <原件目录> --out <新根>），不在旧版本上出"
exit 1

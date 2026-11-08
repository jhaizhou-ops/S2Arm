#!/bin/bash
# 起局用哪份存档（宽屏闭环 / 自动出表，graphics/widen/scan/closed_loop.sh 调）：graphics/widen/scan/save_pick.sh <款> <构建号>  → 打印存档目录（没有就不打印）
# 存档是只读种子（起局时整棵拷进游戏存档、不回写，services/S2A.Services/Saves.cs），所以可以借别的构建号的：
#   同构建号 <款>_<构建号> > 同构建号带后缀 <款>_<构建号>@…（取最新）> 同构建号别的款名 <别名>_<构建号>[@…]（取最新）> 同款别的构建号 <款>_<另一构建号>[@…]（取最新；游戏更新后读旧版存档一般自动迁移）
# 10-25：动森 3.0.3（新构建号）、巫师3（只有 @jhz1023terrace）原先只认完全同名，没有就从新游戏开场走，自动玩家进不了场景，判官全判「探测局没到 MARK」
# 第 3 个参数（可选）给产物根：从它的 unpack.tsv 取游戏显示版本，借别的构建号的存档时，存档游戏版本明确新于它的不借（11-02 jhz 手测星露谷：
#   1.4.4 的社区档借给 1.3.33 的包，读档就 Break，真 Switch 上同样读不了；tools/save_import.py --newer 判，读不出版本的照旧借）
SV=${S2A_SAVES:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/saves}; G=${1:?款}; B=${2:?构建号}
GV=$(awk -F'\t' '$1 == "display_version" {print $2}' "${3:-/nonexistent}/unpack.tsv" 2> /dev/null); TOOLS=$(cd "$(dirname "$0")/../../../tools" && pwd)
newer() { [ -n "$GV" ] && python3 "$TOOLS/save_import.py" --newer "$1" "$GV" && { echo "save_pick：跳过 ${1##*/}（存档游戏版本新于游戏 ${GV}）" >&2; return 0; }; return 1; }
# 标了不能自动用的存档（11-06 总指挥：鬼灭社区 100% 存档在库里这一版游戏上读不了，游戏弹「请更新游戏」后整局卡死，自动局全挑中它）：
#   存档目录下有「不兼容.txt」（确认读不了，留作对照不删）或「待核.txt」（社区存档版本核不了，导入时 save_import.py 写；跑一局确认能读后删掉）→ 跳过，打一行原因
held() { local f; for f in 不兼容 待核; do [ -e "$1/$f.txt" ] && { echo "save_pick：跳过 ${1##*/}（有 $f.txt：$(head -c 120 "$1/$f.txt" | tr '\n' ' ')）" >&2; return 0; }; done; return 1; }
first() { local d; for d in "$@"; do [ -d "$d" ] && ! held "$d" && { echo "$d"; return 0; }; done; return 1; }
first "$SV/${G}_$B" && exit 0
first $(ls -dt "$SV/${G}_$B@"* 2> /dev/null) && exit 0
# 同构建号、别的款名（取最新）：同一份 main 在不同出包名下（10-26：硬盘普查名 t0100fd8022daa000 与 smg2 是同一构建号，存档只登记在 smg2 名下，宽屏探测局没带存档）
first $(ls -dt "$SV/"*"_$B" "$SV/"*"_$B@"* 2> /dev/null) && exit 0
for d in $(ls -dt "$SV/${G}_"* 2> /dev/null); do n=${d##*/}; n=${n#"${G}_"}; [[ "${n%%@*}" =~ ^[0-9a-f]{32}$ ]] && ! held "$d" && ! newer "$d" && { echo "$d"; exit 0; }; done   # 只认 <款>_<32 位构建号>[@…]，别把别款同前缀的目录当成本款
exit 0

#!/bin/bash
# 进局检查（10-26 总指挥：宽屏自动出表的探测局停在菜单，硬盘 40 款宽屏交集也要用；做法通用）：tools/entry_check.sh <款> [handheld|docked] [局目录]
# 只回答一件事：这一款这一档读档后，自动玩家（AI 看屏驾驶）能不能到 MARK（游戏场景里可操作）。环境与宽屏探测局一致
#   （graphics/widen/scan/closed_loop.sh：同存档 save_pick.sh、S2A_DOCKED 按档位、屏幕宽缺省 1922），只是不开第二层点。
# 产物根：${S2A_ROOTS:-~/.s2arm/run/s2arm/roots}/<款>@${S2A_ROOT_TAG:-现行}（硬盘普查款给 S2A_ROOTS=<普查工作区>/smp_<程序号>/roots），起局前克隆一份快照，不碰共享根。
# 输出一行：「过」/「不过」+ MARK 帧、首帧到 MARK 秒数、用的存档、MARK 截图（ap_mark.png，交人核是不是游戏场景）；退出 0 = 到 MARK，3 = 局没起，5 = 待直连根（缺省直连、根里没有本链直连库，不起局）。
# 到不了 MARK：看局目录 vision/vNN.png|.json（每步截图与模型的回答）定卡在哪页，改导航规则（tests/autoplay/nav_rules.txt，两个驾驶员后端共用）。
set -u
G=${1:?款}; MODE=${2:-handheld}; case $MODE in handheld|docked) ;; *) echo "🔴 档位只认 handheld / docked"; exit 2;; esac
R=$(cd "$(dirname "$0")/.." && pwd); S=$R/graphics/widen/scan; PY=/usr/bin/python3
D=${3:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/entry_check/${G}_$MODE}
src=$(cd -P "${S2A_ROOTS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/roots}/$G@${S2A_ROOT_TAG:-现行}" 2>/dev/null && pwd) || { echo "🔴 $G 没有现行产物根（S2A_ROOTS 指到别处的给出来）"; exit 2; }
# 图形模式（10-27 jhz：「直连才是主力，通用是兜底」）：缺省直连——根里没有本链号直连库（NVN shaders/direct/b-<链>/lib.idx，或 Vulkan vk/ / OpenGL gl/）
#   就报「待直连根」退出 5、不起局（不拿通用局冒充直连读数）；收局核 host.log「图形模式：直连」。S2A_ENTRY_GFX=generic 只用于验通用兜底
GFX=${S2A_ENTRY_GFX:-direct}; case $GFX in direct|generic) ;; *) echo "🔴 S2A_ENTRY_GFX 只认 direct / generic"; exit 2;; esac
CH=$(sed -n 's/^#define DMSH_CHAIN "\([0-9a-f]*\)".*/\1/p' "$R/graphics/nvn/gfx/nvn/dmsh_chain.h" 2> /dev/null)
if [ "$GFX" = direct ] && ! { [ -n "$CH" ] && [ -f "$src/shaders/direct/b-$CH/lib.idx" ]; } && [ ! -d "$src/shaders/direct/vk" ] && [ ! -d "$src/shaders/direct/gl" ]; then
  has=$(ls -d "$src"/shaders/direct/b-* 2> /dev/null | sed 's#.*/##' | tr '\n' ' ')
  echo "🟡 待直连根 ${G} ${MODE}：根 $(basename "$src") 没有本链 ${CH:-?} 的直连库（有：${has:-无}），向出包运维线要当前链号的根；不起局"; exit 5
fi
rm -rf "$D"; mkdir -p "$D"; sn=$D/in_snap
# 直连库分片（11-01 究极4「direct library container: shard … missing」：出包时分片在、局快照里一开始就没有，丢在出包之后某一步）：以前只查 lib.idx 在不在，
#   现在核 idx 列出的每个分片都在且大小相符；缺就在起局前报红点名哪一片、哪个路径。源根与快照各核一次、各记一行分片清点（$D/shard_inventory.log），下次复现直接看丢在克隆前还是克隆后
SH=$R/tools/direct_shards.py
if [ "$GFX" = direct ] && [ -n "$CH" ] && [ -d "$src/shaders/direct/b-$CH" ]; then
  $PY "$SH" inventory "$src/shaders/direct/b-$CH" --label "进局检查·源根" --log "$D/shard_inventory.log" > /dev/null
  $PY "$SH" check "$src/shaders/direct/b-$CH" --label "进局检查·源根" || { echo "🔴 ${G} ${MODE}：源产物根的直连库分片不全（上行点名缺哪一片），不起局；分片清点 $D/shard_inventory.log"; exit 2; }
fi
$PY "$R/tools/clonedir.py" "$src" "$sn" || { echo "🔴 快照失败"; exit 2; }
if [ "$GFX" = direct ] && [ -n "$CH" ] && [ -d "$sn/shaders/direct/b-$CH" ]; then
  $PY "$SH" inventory "$sn/shaders/direct/b-$CH" --label "进局检查·快照" --log "$D/shard_inventory.log" > /dev/null
  $PY "$SH" check "$sn/shaders/direct/b-$CH" --label "进局检查·快照" || { echo "🔴 ${G} ${MODE}：克隆出的快照里直连库分片不全（源根是齐的才会到这里：丢在 clonedir 这一步），不起局；分片清点 $D/shard_inventory.log"; exit 2; }
fi
BID=$(xxd -s 0x40 -l 16 -p "$sn/exefs/main")
SA=$(bash "$S/save_pick.sh" "$G" "$BID" "$sn")
X=(); if [ -d "$SA" ]; then X+=("S2A_SAVE_DIR=$SA"); for k in system_time:S2A_SYSTEM_TIME language:S2A_SYSTEM_LANGUAGE region:S2A_REGION timezone:S2A_TIMEZONE; do
  [ -s "$SA/${k%%:*}" ] && X+=("${k#*:}=$(cat "$SA/${k%%:*}")"); done; fi
# 宿主先在局时限外编好（10-27 总指挥：普查局时限只算游戏局；负载 98 下 make host 吃掉 120 秒时限，4 款没起局就判超时）；run_mac.sh 里那次 make 变成空转。
#   必须带与起局同样的 S2A_CS=1：Makefile 构建配置戳含 S2A_CS，预编不带、起局带 → 局时限内整个重编（10-29 c1029c 首批 2/3 局 335 秒超时判「局异常退出」）
# 同一棵树的 make host 串行（11-02 一次成功线：普查本机 3–4 道局各自在同一棵冻结树里 make host、不加锁，两道同时重链同一个 build/s2arm-host，
#   幻想水浒那局拿到一个没链 C# 服务层的宿主「S2A_Init：没链 C#」、svc 0x1F 一直未实现、首帧没出）：按树加 lockf，锁文件 build/.make_host.lock
bash "$R/tools/host_build.sh" > "$D/build.out" 2>&1 || { echo "🔴 ${G} ${MODE}：宿主构建失败（见 $D/build.out）"; exit 2; }
X+=("S2A_HOST_PREBUILT=1")   # run_mac.sh 不再 make：局时限只算游戏局（10-29：共用 NativeAOT 缓存在排槽空档被别的工作树刷新，槽内重新链接被算进局时）
[ "$GFX" = generic ] && X+=("S2A_GFX=generic")
env ${X[@]+"${X[@]}"} S2A_CS=1 S2A_DOCKED=$([ "$MODE" = docked ] && echo 1 || echo 0) S2A_SCREEN_W="${S2A_SCREEN_W:-1922}" S2A_IN="$sn" \
  "COST_LINE=${COST_LINE:-自动玩家}" "COST_WHY=${COST_WHY:-进局检查 $G $MODE}" \
  bash "$R/tools/mac_slot_frozen.sh" run "进局检查 $G" "${S2A_LOOP_CAP:-295}" -- bash "$R/runtime/run_mac.sh" "$G" "$D" "${S2A_LOOP_SEC:-260}" > "$D/run.out" 2>&1; rc=$?
echo "$rc" > "$D/run.rc"   # 局退出码（tools/quicktest/verdict.py 据此分「被杀 / 超时」与正常收局）
chmod -R u+w "$sn" 2> /dev/null; rm -rf "$sn"
[ "$rc" = 3 ] && [ ! -s "$D/host.log" ] && { echo "🟡 局没起 ${G} ${MODE}：独占局等出包停 / 负载降没等到，或局槽排队超时（$(grep -a '🔴' "$D/run.out" | tail -1)）"; exit 3; }
gm=$(LC_ALL=C grep -a -m1 -o '图形模式：[^（]*' "$D/host.log" 2> /dev/null)
[ "$GFX" = direct ] && [ -s "$D/host.log" ] && [ "$gm" != "图形模式：直连" ] && { echo "🔴 没走直连 ${G} ${MODE}：${gm:-host.log 没有图形模式行}（$(LC_ALL=C grep -a -m1 '【红】图形模式' "$D/host.log" | cut -c1-160)）；局目录 $D"; exit 1; }
read -r mk mf fs < <($PY -c "import json,sys; d=json.load(open(sys.argv[1])); print(int(d.get('marked', False)), d.get('mark_frame', 0), d.get('first_frame_to_mark_s', -1))" "$D/ap_summary.json" 2> /dev/null || echo "0 0 -1")
# 小结是收局时写盘的：MARK 来得晚（10-29 王国之泪：260 秒局里第 217 秒才到）或收局时崩，小结就没有——按 MARK 当场写下的日志行判（同 tools/quicktest/verdict.py）
if [ "$mk" != 1 ] && [ ! -s "$D/ap_summary.json" ]; then ml=$(LC_ALL=C grep -a -m1 -o 'S2A 标记 MARK：帧 [0-9]*' "$D/host.log" 2> /dev/null)
  [ -n "$ml" ] && { mk=1; mf=${ml##*帧 }; fs=-1; }; fi
why=$(LC_ALL=C grep -a -o '自动玩家结论：[^；]*' "$D/host.log" 2> /dev/null | tail -1)
sn_=${SA##*/}; use="存档 ${sn_:-无}"
if [ "$mk" = 1 ]; then echo "🟢 过 ${G} ${MODE}：MARK 帧 ${mf}、首帧到 MARK ${fs} 秒（${use}）；截图 $D/ap_mark.png（核是不是游戏场景）"; exit 0; fi
echo "🔴 不过 ${G} ${MODE}：rc=${rc}，${why:-没有自动玩家结论}（${use}）；局目录 $D"; exit 1

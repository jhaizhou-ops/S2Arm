#!/bin/bash
# 快测 / 普查留存 host.log：bash tools/quicktest/keep_log.sh <源 host.log> <目的>
#   ≤ 2 MB 原样拷；超 2 MB 留头 1.5 MB + 尾 0.5 MB（收局标志与崩溃栈在尾部，离线重判 census.py rejudge 要用），
#   截掉的中间段里判据要读的关键行按原顺序留下（上限 400 KB）。11-02 总指挥：MARK 行被截掉，五问满屏判不出局内 / 界面页（DISGAEA 6 等落进待分层）。
#   关键行 = 五问 / 满屏三档（tools/score_cells.py fs_tier）读的：MARK、【红】、出图层原比例状态行、判据存图行、自动玩家截图行、直连出图层 / iOS 壳屏幕行；
#   加「不卡」的定因行（11-02 一次成功线：派对修后局第 19152 帧 2644 ms 落在截掉的 11 MB 里定不了因）：长帧 / 慢帧分解、首遇等待、并行预编、着色器预载 / 急载、出帧停住。
#   关键行上限 400 KB → 1.2 MB（慢帧分解开着时一局几百 KB）
set -u
S=${1:?源 host.log}; D=${2:?目的}
KEY='S2A 标记 MARK|【红】|出图原比例|出图离开原比例|出图两侧|出图没有可扩视野|出图恢复满屏|满屏判据|自动玩家：截图|直连：出图层|iOS 壳|\[longframe\]|\[slowframe\]|first-use wait|parallel precompile|shader prefetch:|shader lookahead loads|出图停住'
hz=$(wc -c < "$S")
if [ "$hz" -le 2000000 ]; then cp "$S" "$D"; exit; fi
{ head -c 1500000 "$S"; printf '\n…（中间截掉 %d 字节，下面是其中的关键行）…\n' $((hz - 2000000))
  tail -c +1500001 "$S" | head -c $((hz - 2000000)) | LC_ALL=C /usr/bin/grep -a -E "$KEY" | head -c 1200000
  printf '…（关键行止）…\n'; tail -c 500000 "$S"; } > "$D"

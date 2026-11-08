#!/bin/bash
# 看板收证据口径单测（tools/board.py accepted，约 1 秒）：bash tests/board_accept_test.sh
# 期望（10-24 总指挥定：按跑的条件认证据，不看谁排的）：同口径（无 --env、cold / run）OWNER=自动正式局 与 OWNER=测试出包 都收；
#   带 --env（诊断局）不收、登记冒烟（MODE=smoke）不收、实验包（包列「实验:…」）同口径也不收（反证）；作业文件被清了退回按 OWNER 认；jhz 实机判定行照收
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mk() {   # mk <局名> <OWNER> <ENVS> <MODE>：作业文件 + 局目录 out_1，打出局目录
  mkdir -p $T/jobs/$1/out_1; printf 'G=acnh\nMODE=%q\nOWNER=%q\nENVS=%q\nNOTE=%q\n' "$4" "$2" "$3" 说明 > $T/jobs/$1.job; echo $T/jobs/$1/out_1; }
A=$(mk acnh_1_1 自动正式局 '' cold); B=$(mk acnh_2_1 测试出包 '' cold); C=$(mk acnh_3_1 测试出包 '' run)
D=$(mk acnh_4_1 帧率能耗 ' S2A_CORES=0' run); E=$(mk acnh_5_1 自动正式局 '' smoke); F=$(mk acnh_6_1 测试出包 ' S2A_ROUTE_JOB=1' cold); GG=$(mk acnh_8_1 自动正式局 ' S2A_GFX=generic' run); GX=$(mk acnh_9_1 自动正式局 ' S2A_GFX=generic S2A_CORES=0' run)
G=$T/jobs/acnh_7_1/out_1; mkdir -p $G; mkdir -p $T/logs; echo '[10-24 16:00:00] 派 测试机1：acnh cold（自动正式局：正式局 auto x）包 x' > $T/logs/acnh_7_1.log
o=$(python3 - "$H" "$A" "$B" "$C" "$D" "$E" "$F" "$G" <<'PY'
import sys; sys.path.insert(0, sys.argv[1] + '/tools'); import board
row = lambda d, note='读数', pk='x': ['t', 'acnh', pk, '绿', '未测', '绿', '绿', '绿', '绿', note, d, '1', '']
print(' '.join('收' if board.accepted(row(d)) else '不收' for d in sys.argv[2:]), '收' if board.accepted(row('', '实机判 画面绿')) else '不收',
      *('收' if board.accepted(row(d, pk='实验:pkg')) else '不收' for d in sys.argv[2:4]), '收' if board.accepted(row('', '实机判 画面绿', '实验:pkg')) else '不收')
PY
)
read -r a b c d e f g h i j k <<< "$o"
ck "同口径不同 OWNER 都收：自动正式局 cold（${a}）、测试出包 cold（${b}）、测试出包 run（${c}）" '[ "$a $b $c" = "收 收 收" ]'
ck "反证：带 --env 的诊断局不收（${d}）、登记冒烟不收（${e}）、改路线（--route 写 S2A_ROUTE_JOB=1）不收（${f}）" '[ "$d $e $f" = "不收 不收 不收" ]'
ck "反证：实验包同口径局不收（自动正式局 cold → ${i}、测试出包 cold → ${j}）、实验包的实机判定行不收（${k}）" '[ "$i $j $k" = "不收 不收 不收" ]'
o2=$(python3 - "$H" "$GG" "$GX" <<'PY2'
import sys; sys.path.insert(0, sys.argv[1] + '/tools'); import board
row = lambda d: ['t', 'acnh', 'x', '绿', '未测', '绿', '绿', '绿', '绿', '读数', d, '1', '']
print(*('收' if board.accepted(row(d)) else '不收' for d in sys.argv[2:]))
PY2
)
ck "只带 S2A_GFX=generic 的正式局照收（模式是记分板维度，兜底质量局用）；再带别的 --env 照旧不收（${o2}）" '[ "$o2" = "收 不收" ]'
ck "作业文件被清了 → 按调度日志里的 OWNER 认（自动正式局 → ${g}）；jhz 实机判定行照收（${h}）" '[ "$g $h" = "收 收" ]'
# 模式维度（10-24 快速通用模式方案 §4）：同包一行通用（能玩绿）、一行直连（能玩红）、一行没有模式列的旧行（能玩绿）→ 主看板（MAIN_MODE=通用）能玩绿 2 局、直连看板能玩红 1 局；
#   score_cells.gfx_mode 按 host.log「图形模式：」取，没有这行 = 通用；10-25 起主看板 MAIN_MODE = 直连
o=$(python3 - "$H" "$T" <<'PY2'
import sys, os; sys.path.insert(0, sys.argv[1] + '/tools'); import board, score_cells
T = sys.argv[2]; sb = T + '/b.tsv'
row = lambda play, mode=None: ['10-24 23:00', 'acnh', 'p1', play, '未测', '未测', '未测', '未测', '未测', '读数', '', '1', '—', '—'] + ([mode] if mode else [])
open(sb, 'w').write('\n'.join('\t'.join(r) for r in [['表头'], row('绿', '通用'), row('红', '直连'), row('绿')]) + '\n')
board.SB = sb; board.accepted = lambda r: True
st, last, _ = board.board('通用'); sd, ld, _ = board.board('直连')
a = st[last['acnh'][0]]['#注']['能玩']; b = sd[ld['acnh'][0]]['#注']['能玩']
for n, t in (('d', '[s2a] 图形模式：直连（依据 环境变量）'), ('g', '[s2a] 图形模式：通用（依据 缺省）'), ('x', 'S2A 就绪')):
    os.makedirs(f'{T}/m{n}', exist_ok=True); open(f'{T}/m{n}/host.log', 'w').write(t + '\n')
print(f'{a[0]}{a[1]} {b[0]}{b[1]}', board.MAIN_MODE, *(score_cells.gfx_mode(f'{T}/m{n}') for n in 'dgx'))
PY2
)
ck "模式分开投票：board('通用') 能玩 绿 2 局（含没有模式列的旧行）、board('直连') 红 1 局；主看板 MAIN_MODE=直连；gfx_mode 直连 / 通用 / 没有图形模式行 → 通用（${o}）" '[ "$o" = "绿2 红1 直连 直连 通用 通用" ]'
rm -rf $T; [ $bad = 0 ] && echo "board_accept 单测全过" || { echo "board_accept 单测有不通"; exit 1; }

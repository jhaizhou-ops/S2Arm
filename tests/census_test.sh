#!/bin/bash
# 门禁覆盖：tools/census/census.py tools/census/census.sh tools/remote.sh tools/idle_timeout.sh tools/safe_killpg.sh tools/disk_low.sh
# 普查规则层单测（合成盘点 + 合成单款结果，不读硬盘、不起局，约 1 秒）：bash tests/census_test.sh
# 期望（按 census.py 文件头口径手写）：
#   ① 排队：本体 + 补丁按本体程序号合成一款；32 位本体也排（盘点报的指令集不作数，解包后判）；读不出清单的文件单独排一款（键 f_<名字哈希>）；0 字节文件记「源文件坏」；
#      XCI 头里有效数据结束地址比实际大小大（截断，t.xci：结束地址 10 → 应有 5632 字节，实际 1024）记「源文件坏：截断」；a_base.xci 头完整（结束地址 4 → 2560 ≤ 3000）照排；
#      队列按字节从小到大；只有补丁没有本体的程序号不成款
#   ② 拼行：one_game.sh 结果.tsv 末行 → 总表一行，解包秒用本机解包读数
#   ③ 三率：9 行（源文件坏 1、未判 1 不进分母）→ 普查 7 款（Alpha k1 Lam Mu Xi Beta Omi）；尝试解包 6（去掉 32 位 Beta），解包成功 5（k1 失败）；
#      进局分母去掉 Omi（进局「未判」：视觉判官不在）= 6，进局 2/6；起了局 5（Alpha Lam Mu Xi Omi），0 崩 4（Mu 崩）
#   ④ 逐类：崩溃去地址归「稳定崩溃：客体代码」、属主原生线；起来了没到 MARK 归「没进局」
#   ⑤ 断点续跑：再排一次，总表已有的款不再排，「未判」的重排
#   ⑥ rejudge：一行旧口径「稳定崩溃」，拉回的 host.log 里崩溃在「收局阶段」之后 → 结论 通过、崩溃 收局；没日志的行不动
#   ⑦ redo：根修后重排——Alpha（总表已「通过」）改记未判 / 重排：<原因>，再 plan 重新进队列；总表没有的键退出 1
#   ⑨ 机器原因不记游戏头上——出包日志磁盘不足、本行红行是环境 / 工具缺件（glslangValidator、DM_OODLE_HOST、rc=75）的出包失败 → 未判；跑局机缺链接桩：host.log / host_2.log 有「no stub archive」→ 不论结论一律未判（流水线缺陷不记游戏头上）；没有那行的直连异常照旧
#   ⑧ entry_ai（进局 = AI 看截图）：取 ap_mark + vision 最后两张 + last_vision（同内容去重），任一张游戏画面 → 是；都不是 → 否；没截图 / 判官抛错 → 未判（假判官，不联网）
#   ⑩ PFS0（NSP / NSZ）截断（#934）：按头算应有大小 = 数据区起点 0x10 + 0x18×n + 字符串表长 + max(条目偏移 + 条目大小)，
#      实际更小 →「源文件坏：截断」（格式同 XCI 那条）；末尾多追加 1 KB 填充 / 对齐 → 正常（实际 > 应有不算坏）；
#      头里没有 PFS0 →「源文件坏：不是 NSP 结构」；文件数 0、头不足 0x10 → 不判（交给解包）；.xci 判定不变、.xcz 仍不判；
#      端到端：截断的 NSP 本体直接记表、不进队列（改前会去解包、被记成我方缺陷），rejudge 复核没坏的再撤回
#   ㉘ 本机跑局工人先看机器槽有空位（槽目录缺、或持有进程已退）再领款；不走槽（没设 S2A_SLOT_RUN）当有
#   ⑪ 能力实际生效三列（10-29 总指挥）：满屏 = host.log 宽屏名单门结论（在名单 = 开 / 不在 = 关 / 没走到 = -）；60帧 = 能力清单行（帧率表起局说关就关）；
#      强信号 = 清单里写 0 的能力连同原因；都没有 = -
set -u
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
export S2A_DISK_FREE_GB=999 S2A_DISK_DIR=$T/diskadmit   # 工作盘准入（tools/disk_admit.py）：单测给假剩余与临时账本，不读真盘、不写真账
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3; C="$PY $R/tools/census/census.py"
chk() { if [ "$2" = "$3" ]; then echo "🟢 $1"; else echo "🔴 $1：期望「$2」→ 真结果「$3」"; bad=1; fi; }
D=$T/disk; B=$T/b; mkdir -p "$D" "$B/inventory"
mkf() { : > "$D/$1"; [ "$2" = 0 ] || head -c "$2" /dev/zero > "$D/$1"; }
mkf a_base.xci 3000; mkf a_upd.nsp 1000; mkf b32.nsp 500; mkf c.xcz 2000; mkf d.nsp 0; mkf e_upd.nsp 10; mkf t.xci 1024
xhead() { "$PY" -c 'import struct,sys; f=open(sys.argv[1],"r+b"); f.seek(0x100); f.write(b"HEAD"); f.seek(0x118); f.write(struct.pack("<I", int(sys.argv[2])))' "$D/$1" "$2"; }
xhead a_base.xci 4; xhead t.xci 10
# b32.nsp 造最小 PFS0（500 字节、1 个条目）：⑩ 之后 src_bad 按 PFS0 头判，零字节头的 .nsp 会记「不是 NSP 结构」而不是排队
"$PY" - "$D/b32.nsp" <<'PYEOF'
import struct, sys
n, names, data = 1, b'x.nca\0', 0x10 + 0x18 + 6
buf = bytearray(b'\0' * 500); buf[0:4] = b'PFS0'
struct.pack_into('<II', buf, 4, n, len(names))
struct.pack_into('<QQII', buf, 0x10, 0, 500 - data, 0, 0)
buf[0x28:0x28 + 6] = names
open(sys.argv[1], 'wb').write(buf)
PYEOF
j() { printf '{"schema": 1, "packages": [%s]}' "$2" > "$B/inventory/$1.json"; }
j a '{"baseId": "0100000000AAA000", "type": "base", "name": "Alpha", "display": "1.0.0", "version": 0, "guestIsa": "aarch64"}'
j u '{"baseId": "0100000000AAA000", "type": "update", "name": "Alpha", "display": "1.2.0", "version": 131072}'
j b '{"baseId": "0100000000BBB000", "type": "base", "name": "Beta", "display": "1.0", "version": 0, "guestIsa": "aarch32"}'
j e '{"baseId": "0100000000EEE000", "type": "update", "name": "Eps", "display": "1.1", "version": 65536}'
printf '文件\t字节\trc\t清单\n%s\t3000\t0\ta.json\n%s\t1000\t0\tu.json\n%s\t500\t0\tb.json\n%s\t2000\t1\tc.json\n%s\t0\t1\td.json\n%s\t10\t0\te.json\n%s\t1024\t1\tt.json\n' \
  "$D/a_base.xci" "$D/a_upd.nsp" "$D/b32.nsp" "$D/c.xcz" "$D/d.nsp" "$D/e_upd.nsp" "$D/t.xci" > "$B/inventory/inspect.tsv"
$C plan "$B" > /dev/null
q=$(awk -F'\t' 'NR > 1 {print $1 "/" $6}' "$B/queue.tsv" | tr '\n' ' ')
chk "① 队列（字节从小到大；Alpha 本体 + 补丁 4000；32 位 Beta 也排）" "0100000000BBB000/500 f_$(printf c.xcz | shasum | cut -c1-12)/2000 0100000000AAA000/4000 " "$q"
chk "① Alpha 版本取补丁" "1.2.0" "$(awk -F'\t' '$1 == "0100000000AAA000" {print $3}' "$B/queue.tsv")"
chk "① 直接记表（0 字节、截断 XCI）" "f_$(printf d.nsp | shasum | cut -c1-12)/源文件坏：0 字节 f_$(printf t.xci | shasum | cut -c1-12)/源文件坏：截断（应有 0.00 GB，实际 0.00 GB） " "$(awk -F'\t' 'NR > 1 {print $1 "/" $8}' "$B/总表.tsv" | tr '\n' ' ')"
# ② 拼行
H='源\t款\t程序号\t结论\t第一个失败点\t解包秒\t出包秒\tMac局秒\t首帧\t首帧毫秒\t帧数\t图形模式\t直连异常\t崩溃\t红行前3\t进局\n'
printf "$H"'s\talpha\t0100000000AAA000\t通过\t-\t0\t120\t300\t是\t900\t17000\t直连\t否\t否\t-\t是\n' > "$T/r.tsv"
$C row 0100000000AAA000 Alpha 1.2.0 air 0.0 "$T/r.tsv" 95 >> "$B/总表.tsv"
chk "② 拼行（机器 / 款 / 结论 / 解包秒 / 进局）" "air alpha 通过 95 是" "$(tail -1 "$B/总表.tsv" | cut -f4,6,7,9,19 | tr '\t' ' ')"
# ③ ④ 三率与逐类：再补 5 款
row() { printf '%s\t%s\t-\tair\t1.0\tg\t%s\t%s\t%s\t0\t%s\t-\t-\t0\t直连\t否\t%s\t-\t%s\t2026-10-29\n' "$1" "$2" "$3" "$4" "${7:-30}" "$5" "$6" "$8" >> "$B/总表.tsv"; }
#    键 名称 结论 第一个失败点 Mac局秒 崩溃 解包秒 进局
row k1 Kappa 失败 解包 0 - 40 -
row k2 Lam 通过 - 300 否 40 否
row k3 Mu 失败 "稳定崩溃：客体代码（main+0x1234）（首帧前）" 80 是 40 否
row k4 Nu 未判 局没起 0 - 40 -
row k5 Xi 通过 - 300 否 40 是
row 0100000000BBB000 Beta 失败 "不支持：32位" 0 - 30 -
row k6 Omi 通过 - 300 否 40 未判
out=$($C sum "$B")
chk "③ 三率" "普查三率：解包 5/6（83.3%） ｜进局 2/6（33.3%） ｜0 崩 4/5（80.0%）" "$(head -1 <<< "$out")"
chk "④ 进局未判归出包线（跑局机缺判官密钥）" "| 进局未判（视觉判官不在） | 1 | 出包线 | Omi |" "$(grep '进局未判' "$B/汇总.md")"
chk "④ 崩溃归类与属主" "| 稳定崩溃：客体代码 | 1 | 原生线 | Mu |" "$(grep '稳定崩溃' "$B/汇总.md")"
chk "④ 没进局" "| 没进局 | 1 | 泛化线 | Lam |" "$(grep '^| 没进局' "$B/汇总.md")"
# ③b 没进局拆两类（10-29 总指挥）。期望手算：进局列不是「是 / 未判」的 4 行（k1 解包 -、Lam 通过否、Mu 失败否、Beta 32 位 -）；工具 = 结论通过且进局否 = Lam 1；
#   游戏 = 3；去掉工具缺陷的进局率 = 进局 2 /（2 + 3）
chk "③b 没进局拆工具 / 游戏，另给去掉工具缺陷的进局率" "没进局 4 = 工具没进局 1（局正常、自动玩家没走进去）+ 游戏没进局 3（崩溃 / Break / 黑屏 / 出包 / 不支持） ｜去掉工具缺陷的进局率 2/5（40.0%）" "$(grep '^没进局' <<< "$out")"
# ⑤ 断点续跑
$C plan "$B" > /dev/null
chk "⑤ 续跑只排没做的与未判的" "f_$(printf c.xcz | shasum | cut -c1-12) " "$(awk -F'\t' 'NR > 1 {print $1}' "$B/queue.tsv" | tr '\n' ' ')"
# LC_ALL=C：macOS 自带 awk（20200816）在 UTF-8 locale 下比较多字节字符串恒真（10-29 实测：「未判」==「通过」都成立），按字节比才准
chk "⑤ 结论未判那行从总表去掉（等重跑）" "0" "$(LC_ALL=C awk -F'\t' '$7 == "未判"' "$B/总表.tsv" | grep -c .)"
# ⑥ rejudge
L=$B/work/k9/r/logs/k9; mkdir -p "$L"
printf '图形模式：直连\nnnMain → 首帧上屏 +900.0 ms\n自动玩家：导航 → 按 A（第 3 下）\n[s2a] 收局阶段 取消服务等待：累计 1 ms\nUnhandled exception. System.NullReferenceException: x\n[s2a] 【红】CRASH 信号 6 地址 0x0 pc __pthread_kill+0x8\n' > "$L/host.log"
echo "收局 rc=134" > "$L/run_mac.out"
row k9 Rho 失败 "稳定崩溃：C#未处理异常（System.NullReferenceException）" 300 是 40 -
$C rejudge "$B" > /dev/null
chk "⑥ rejudge：旧口径稳定崩溃 → 通过 / 收局" "通过 收局" "$(awk -F'\t' '$1 == "k9" {print $7, $17}' "$B/总表.tsv")"
chk "⑥ rejudge：没日志的行不动" "失败" "$(awk -F'\t' '$1 == "k3" {print $7}' "$B/总表.tsv")"
# ⑦ redo
$C redo "$B" 0100000000AAA000 改写器修好 > /dev/null; chk "⑦ redo 退出码" 0 $?
chk "⑦ redo：改记未判" "未判 重排：改写器修好" "$(awk -F'\t' '$1 == "0100000000AAA000" {print $7, $8}' "$B/总表.tsv")"
$C plan "$B" > /dev/null
chk "⑦ redo 后 plan 重排" "f_$(printf c.xcz | shasum | cut -c1-12) 0100000000AAA000 " "$(awk -F'\t' 'NR > 1 {print $1}' "$B/queue.tsv" | tr '\n' ' ')"
$C redo "$B" kNone x > /dev/null; chk "⑦ redo 没有的键退出 1" 1 $?
# ⑧ entry_ai
"$PY" - "$R" "$T" <<'PYEOF' || bad=1
import os, sys; sys.path.insert(0, os.path.join(sys.argv[1], 'tools/census')); import census
T = os.path.join(sys.argv[2], 'lg'); os.makedirs(os.path.join(T, 'run', 'vision'))
for n, c in (('ap_mark.png', b'm'), ('run/vision/v2.png', b'a'), ('run/vision/v10.png', b'b'), ('run/vision/v9.png', b'c'), ('last_vision.png', b'b')):
    open(os.path.join(T, n), 'wb').write(c)
seen = []
def judge(ps, game=None): seen.append([os.path.relpath(p, T) for p in ps]); return [{'游戏画面': '是' if p.endswith(game or '') and game else '否'} for p in ps]
ok = True
def chk(name, want, got):
    global ok
    if want != got: ok = False; print(f'🔴 {name}：期望「{want}」→ 真结果「{got}」')
    else: print(f'🟢 {name}')
r = census.entry_ai(T, lambda ps: judge(ps, 'v10.png'))
chk('⑧ 取图（去重 last_vision = v10）', ['ap_mark.png', 'run/vision/v9.png', 'run/vision/v10.png'], seen[-1]); chk('⑧ 一张游戏画面 → 是', '是', r[0])
chk('⑧ 都不是 → 否', '否', census.entry_ai(T, lambda ps: judge(ps))[0])
def boom(ps): raise RuntimeError('x')
chk('⑧ 判官失败 → 未判', '未判', census.entry_ai(T, boom)[0])
os.makedirs(os.path.join(T, '..', 'empty')); chk('⑧ 没截图 → 未判', '未判', census.entry_ai(os.path.join(T, '..', 'empty'), boom)[0])
# ⑧b 自动玩家打了 MARK（ap_summary.json marked=true）→ 进局 = 是、不调判官（判官抛错也不影响）；没到 MARK → 照旧交判官看截图（判官失败 = 未判）
import json
for n, m, want in (('sw1', True, '是'), ('sw2', False, '未判')):
    d = os.path.join(T, '..', n); os.makedirs(d); json.dump({'marked': m, 'why': 'x', 'first_frame_to_mark_s': 9.0, 'presses': 10, 'vision_asks': 4}, open(os.path.join(d, 'ap_summary.json'), 'w'))
    open(os.path.join(d, 'ap_mark.png'), 'wb').write(b'm'); chk(f'⑧b marked={m} → {want}', want, census.entry_ai(d, boom)[0])
# ⑧c 没有 ap_summary.json、host.log 里有 MARK 两行（11-02 Air 星之卡比）→ 是、不调判官；只有「MARK」没有「导航 → 局内段」→ 照旧交判官（判官失败 = 未判）
for n, hl, want in (('hl1', 'x\nS2A 标记 MARK：帧 8958\n自动玩家：导航 → 局内段（依据：模型说可操控）\n', '是'), ('hl2', 'x\nS2A 标记 MARK：帧 8958\n', '未判')):
    d = os.path.join(T, '..', n); os.makedirs(d); open(os.path.join(d, 'host.log'), 'w').write(hl); open(os.path.join(d, 'ap_mark.png'), 'wb').write(b'm')
    chk(f'⑧c host.log {n} → {want}', want, census.entry_ai(d, boom)[0])
sys.exit(0 if ok else 1)
PYEOF
# ⑨ 缺链接桩
"$PY" - "$R" "$T" <<'PYEOF' || bad=1
import os, sys; sys.path.insert(0, os.path.join(sys.argv[1], 'tools/census')); import census
d = os.path.join(sys.argv[2], 'stub'); os.makedirs(d)
r = {'结论': '失败', '第一个失败点': '直连异常：画面停住 45 秒'}
open(os.path.join(d, 'host.log'), 'w').write('linked stand-ins: no stub archive applegpu_g15g.macos27\n')
ok = census.stub_missing(r, d) is True
open(os.path.join(d, 'host.log'), 'w').write('别的红行\n')
ok = ok and census.stub_missing(r, d) is False and census.stub_missing({'结论': '通过', '第一个失败点': '-'}, d) is False
open(os.path.join(d, 'host.log'), 'w').write('linked stand-ins: no stub archive applegpu_g16s.macos27\n')
ok = ok and census.stub_missing({'结论': '通过', '第一个失败点': '-'}, d) is True   # 缺桩照样通过也不作数（10-29 送小羊回家）
open(os.path.join(d, 'host.log'), 'w').write('别的\n'); open(os.path.join(d, 'host_2.log'), 'w').write('no stub archive\n')
ok = ok and census.stub_missing({'结论': '失败', '第一个失败点': '稳定崩溃：客体代码'}, d) is True   # 补跑局缺桩同样不作数
d2 = os.path.join(sys.argv[2], 'packlog'); os.makedirs(os.path.join(d2, 'pack_logs'))
open(os.path.join(d2, 'pack_logs', 'refresh.log'), 'w').write('【红】x 出包要 40 GB，产物根所在卷（/r）只剩 12 GB：腾出空间后重新出包\n')
pr = {'结论': '失败', '第一个失败点': '出包：刷新其它'}
ok = ok and census.pack_machine(pr, d2) == census.MACHINE and census.pack_machine({'结论': '失败', '第一个失败点': '解包：坏'}, d2) is None
open(os.path.join(d2, 'pack_logs', 'refresh.log'), 'w').write('机器 磁盘不足：可用 20 G < 30 G\n'); ok = ok and census.pack_machine(pr, d2) == census.MACHINE
open(os.path.join(d2, 'pack_logs', 'refresh.log'), 'w').write('【红】改写 main 失败\n'); ok = ok and census.pack_machine(pr, d2) is None
# ⑨b 环境 / 工具缺件、被外部收掉（11-05 天眼普查实例原文）→ 机器原因（未判），原话留在失败点里；日志里提到环境、本行红行不是的照旧
env = ['出包（天眼）：【红】天眼出包失败 rc=1：【红】direct_lib.log：rc=1；[直连库] 🔴 OpenGL 款要 glslangValidator（brew install glslang spirv-cross）',
       '出包（天眼）：【红】天眼出包失败 rc=1：【红】direct_lib.log：rc=1；[RED] Oodle- or LZ5-compressed game files: set DM_OODLE_HOST',
       '出包（天眼）：【红】天眼出包失败 rc=1：九个轻阶段 rc=1；【红】light.log：rc=75；1.5.7',
       '出包（天眼）：【红】天眼出包失败 rc=1：【红】light.log：rc=1；【红】编排中止：[WinError 31] 连到系统上的设备没有发挥作用。']   # 天眼 Windows 系统错误（只在天眼出包道出现，不是游戏）
for fp in env: ok = ok and census.pack_machine({'结论': '失败', '第一个失败点': fp}, d2) == ('机器原因：' + fp)[:200]
ok = ok and census.pack_machine({'结论': '失败', '第一个失败点': '出包：刷新其它', '红行前3': '【红】环境未就绪：缺 zstd 1.5.7'}, d2).startswith('机器原因：出包：刷新其它')
real = {'结论': '失败', '第一个失败点': '出包（天眼）：【红】天眼出包失败 rc=1：light.log：rc=1；假的红行'}
open(os.path.join(d2, 'pack_logs', 'refresh.log'), 'w').write('旁支：环境未就绪 rc=75（与本单无关）\n')
ok = ok and census.pack_machine(real, d2) is None and census.pack_machine({'结论': '失败', '第一个失败点': '稳定崩溃：客体代码 rc=75'}, d2) is None
print(('🟢' if ok else '🔴') + ' ⑨ 缺链接桩的直连异常改记未判；出包失败因磁盘不足 / 环境工具缺件改记未判；真出包失败照旧'); sys.exit(0 if ok else 1)
PYEOF
# ⑩ PFS0（NSP / NSZ）截断：按头算应有大小 = 数据区起点（0x10 + 0x18×n + 字符串表长）+ max(偏移 + 大小)，
#    实际更小才是坏；末尾多出的填充 / 对齐不算坏（实际 > 应有 → 正常）
"$PY" - "$R" "$T" <<'PYEOF' || bad=1
import io, contextlib, os, struct, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'tools/census')); import census
T = os.path.join(sys.argv[2], 'pfs0'); os.makedirs(T)
def pfs0(path, entries):
    """最小 PFS0：entries=[(名字, 字节数)]，内容全 0；条目 offset 相对数据区起点"""
    names, ent, off, no = b'', b'', 0, 0
    for n, sz in entries:
        ent += struct.pack('<QQII', off, sz, no, 0)
        names += n.encode() + b'\0'; off += sz; no += len(n.encode()) + 1
    blob = b'PFS0' + struct.pack('<II', len(entries), len(names)) + b'\0' * 4 + ent + names + b'\0' * off
    open(path, 'wb').write(blob); return blob
def fmt(need, size):
    return f'源文件坏：截断（应有 {need / 2**30:.2f} GB，实际 {size / 2**30:.2f} GB）'
ok = True
def chk(name, want, got):
    global ok
    if want != got: ok = False; print(f'🔴 {name}：期望「{want}」→ 真结果「{got}」')
    else: print(f'🟢 {name}')

blob = pfs0(os.path.join(T, 'full.nsp'), [('a.nca', 4 << 20), ('b.nca', 4 << 20)])
chk('⑩ 完整合成 NSP（应有 = 实际）→ 正常', None, census.src_bad(os.path.join(T, 'full.nsp')))
open(os.path.join(T, 'cut.nsp'), 'wb').write(blob[:-1024])
chk('⑩ 截掉尾部 1 KB → 源文件坏：截断', fmt(len(blob), len(blob) - 1024), census.src_bad(os.path.join(T, 'cut.nsp')))
open(os.path.join(T, 'pad.nsp'), 'wb').write(blob + b'\0' * 1024)
chk('⑩ 末尾多追加 1 KB 填充 → 正常（不误判）', None, census.src_bad(os.path.join(T, 'pad.nsp')))
open(os.path.join(T, 'half.nsp'), 'wb').write(blob[:len(blob) // 2])
chk('⑩ 截掉一半（截在数据区里）→ 源文件坏：截断', fmt(len(blob), len(blob) // 2), census.src_bad(os.path.join(T, 'half.nsp')))
# NSZ 是 PFS0 外壳（条目里是压缩的 NCZ），同一条判据
nsz = pfs0(os.path.join(T, 'full.nsz'), [('a.ncz', 4 << 20)])
chk('⑩ 完整合成 NSZ → 正常', None, census.src_bad(os.path.join(T, 'full.nsz')))
open(os.path.join(T, 'cut.nsz'), 'wb').write(nsz[:len(nsz) - (1 << 20)])
chk('⑩ 截掉 1 MB 的 NSZ → 源文件坏：截断', fmt(len(nsz), len(nsz) - (1 << 20)), census.src_bad(os.path.join(T, 'cut.nsz')))
open(os.path.join(T, 'magic.nsp'), 'wb').write(b'XXXX' + b'\0' * 100)
chk('⑩ 头里没有 PFS0 → 不是 NSP 结构', '源文件坏：不是 NSP 结构（头里没有 PFS0）', census.src_bad(os.path.join(T, 'magic.nsp')))
pfs0(os.path.join(T, 'empty.nsp'), [])
chk('⑩ 文件数 0 → 正常（看不出坏不判）', None, census.src_bad(os.path.join(T, 'empty.nsp')))
open(os.path.join(T, 'tiny.nsp'), 'wb').write(b'PFS')
chk('⑩ 头比 0x10 还短 → 正常（看不出坏不判）', None, census.src_bad(os.path.join(T, 'tiny.nsp')))
open(os.path.join(T, 'hdr.nsp'), 'wb').write(b'PFS0' + struct.pack('<II', 3, 0) + b'\0' * 4 + struct.pack('<QQII', 0, 0, 0, 0))
chk('⑩ 条目表被截断 → 源文件坏：截断', fmt(0x10 + 0x18 * 3, 0x10 + 0x18), census.src_bad(os.path.join(T, 'hdr.nsp')))
open(os.path.join(T, 'x.xci'), 'wb').write(b'\0' * 0x200)
chk('⑩ XCI 判定没被改动（非 XCI 头照旧不是 XCI 结构）', '源文件坏：不是 XCI 结构（头里没有 HEAD）', census.src_bad(os.path.join(T, 'x.xci')))
open(os.path.join(T, 'plain.xcz'), 'wb').write(b'\0' * 0x200)
chk('⑩ .xcz 不在本次边界内（照旧不判）', None, census.src_bad(os.path.join(T, 'plain.xcz')))

# 端到端：截断的 NSP 本体不进队列（原来会去解包 → 记我方缺陷），rejudge 复核没坏的再撤回
B2 = os.path.join(sys.argv[2], 'b2'); os.makedirs(os.path.join(B2, 'inventory'))
brk = os.path.join(T, 'brk.nsp'); b2 = pfs0(brk, [('a.nca', 1 << 20)])
open(brk, 'wb').write(b2[:-1024])
open(os.path.join(B2, 'inventory', 'a.json'), 'w').write('{"schema": 1, "packages": [{"baseId": "0100000000FFF000", "type": "base", "name": "Broken", "display": "1.0", "version": 0, "guestIsa": "aarch64"}]}')
open(os.path.join(B2, 'inventory', 'inspect.tsv'), 'w').write('文件\t字节\trc\t清单\n' + f'{brk}\t{os.path.getsize(brk)}\t0\ta.json\n')
with contextlib.redirect_stdout(io.StringIO()): census.plan(B2)
chk('⑩ 端到端：截断 NSP 直接记表、不进队列', [fmt(len(b2), len(b2) - 1024)], [r['第一个失败点'] for r in census.tsv(os.path.join(B2, '总表.tsv'))])
chk('⑩ 端到端：队列里没有它', [], census.tsv(os.path.join(B2, 'queue.tsv')))
row = {k: '-' for k in census.TH}
row.update({'键': '0100000000FFF000', '名称': 'Broken', '版本': '1.0', '机器': '不起局', '源GB': '0.0', '结论': '源文件坏', '第一个失败点': fmt(len(b2), len(b2) - 1024)})
census.write_tsv(os.path.join(B2, '总表.tsv'), census.TH, [row])
open(brk, 'wb').write(b2)   # 复核：文件已补完整
with contextlib.redirect_stdout(io.StringIO()): census.rejudge(B2, sys.argv[1])
chk('⑩ 端到端：rejudge 复核没坏 → 撤回「源文件坏：截断」那行', [], census.tsv(os.path.join(B2, '总表.tsv')))
sys.exit(0 if ok else 1)
PYEOF
# ⑪ 能力实际生效（10-29 总指挥：普查按发布口径全能力跑，总表加 满屏 / 60帧 / 强信号 三列，读 host.log）
L1=$T/caps1; L2=$T/caps2; L3=$T/caps3; mkdir -p "$L1" "$L2" "$L3"
printf '%s\n' '[s2a] 能力清单：满屏开（S2A_WIDEN_CAPS=1）原因：默认开：来源 第三层通用满屏' '[s2a] 能力清单：60 帧关（S2A_FPS60=0）原因：强信号：静态无来源（没有帧率表）' \
  '[s2a] 宽屏：本款在宽屏已验证名单（包内能力清单开），屏幕宽 2346' > "$L1/host.log"
printf '%s\n' '[s2a] 能力清单：满屏关（S2A_WIDEN_CAPS=0）原因：强信号：宽屏画面坏（两侧残留）' '[s2a] 能力清单：60 帧开（S2A_FPS60=1）原因：默认开：来源 fps.tsv' \
  '[s2a] 宽屏：本款不在宽屏已验证名单（graphics/widen/tables/verified.tsv）或被设置 / 能力清单关掉，整局按 16:9 原比例加黑边（屏幕宽 2346 不放）' \
  '[s2a] 帧率表 /r/fps.tsv：60 帧开；出图间隔放开，数据写入 2 处' > "$L2/host.log"
printf '%s\n' '[s2a] 模块：1 个' > "$L3/host.log"
got=$("$PY" - "$R" "$L1" "$L2" "$L3" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
for d in sys.argv[2:]: c = census.caps_state(d); print(c['满屏能力'], c['60帧'], c['强信号'], sep='|')
PYEOF
)
chk "⑪ 能力实际生效：满屏按宽屏名单门结论、60帧按能力清单行、强信号列写关掉的能力和原因；没有清单行的局记「无清单」" \
  "开|关|60 帧：强信号：静态无来源（没有帧率表）
关|开|满屏：强信号：宽屏画面坏（两侧残留）
无清单|无清单|-" "$got"
# ⑪ 能力生效率（每轮可比）：分母同 0 崩率（起了 Mac 局的款）；无清单 = 满屏或 60帧 列记「无清单」的局。
#   期望手算：起局 4 款（a 开开、b 开关、c 关开、d 无清单无清单；e 没起局不进分母）→ 满屏 2/4、60 帧 2/4、无清单 1 局
B2=$T/b2; mkdir -p "$B2"
"$PY" - "$R" "$B2/总表.tsv" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
base = {'结论': '通过', '第一个失败点': '-', 'Mac局秒': '300', '崩溃': '否', '进局': '是'}
rows = [dict(base, 键=k, 名称=k, 满屏='过', 满屏能力=w, **{'60帧': f}) for k, w, f in (('a', '开', '开'), ('b', '开', '关'), ('c', '关', '开'), ('d', '无清单', '无清单'))]
rows.append(dict(base, 键='e', 名称='e', 结论='失败', 第一个失败点='解包', **{'Mac局秒': '0', '进局': '否', '满屏': '-', '满屏能力': '-', '60帧': '-'}))
census.write_tsv(sys.argv[2], census.TH, rows)
PYEOF
chk "⑪ 能力生效率（分母 = 起了 Mac 局的款）" "能力生效（能力清单开关，不是画面结论）：满屏 2/4（50.0%） ｜60 帧 2/4（50.0%）（另原生 60 0 款） ｜无清单 1 局" "$($C sum "$B2" | grep '^能力生效')"
chk "⑪ 汇总.md 带生效率行" "能力生效（能力清单开关，不是画面结论）：满屏 2/4（50.0%） ｜60 帧 2/4（50.0%）（另原生 60 0 款） ｜无清单 1 局" "$(grep '^能力生效' "$B2/汇总.md")"
chk "⑪ 满屏判据行：a-d 四款进局且记过 → 过 4/4，局内红 0 待分层 0 未判 0（e 没进局不进分母）" "满屏判据（三档）：过 4/4（100.0%）（分母 = 进局款）｜局内红 0 款｜待分层 0 款（红段在界面页或分不清，不算过也不算局内红）｜未判 0 款" "$(grep '^满屏判据' "$B2/汇总.md")"
# ⑪ 满屏看判据、不看能力清单开关（10-31）：能力清单写「满屏开」，host.log 有「【红】出图未满屏」就记红（第 N 次出图）、带 fit_red_1.png；判据起局行在且无红 = 过；判据行缺席 = 未判（不当绿）
F1=$T/fs1; F2=$T/fs2; F3=$T/fs3; mkdir -p "$F1" "$F2" "$F3"
printf '%s\n' '[s2a] 能力清单：满屏开（S2A_WIDEN_CAPS=1）原因：默认开' '[dm] [nvn-mtl] [画] 满屏判据 已开（直连上屏）' \
  '[dm] [nvn-mtl] 【红】出图未满屏（内容，第 180 次出图起，累计第 1 次）：画面 2346x1080 左右两边 16:9 外侧 213 像素黑带' '[dm] [nvn-mtl] 满屏判据第 1 次红的那一帧（第 180 次出图）存到 /x/fit_red_1.png' \
  '[dm] [nvn-mtl] 【红】出图未满屏（内容，第 373 次出图起，累计第 2 次）：画面 2346x1080' > "$F1/host.log"
printf '%s\n' '[s2a] 能力清单：满屏开（S2A_WIDEN_CAPS=1）原因：默认开' '[dm] [nvn-mtl] [画] 满屏判据 已开（直连上屏）' > "$F2/host.log"
printf '%s\n' '[s2a] 能力清单：满屏开（S2A_WIDEN_CAPS=1）原因：默认开' > "$F3/host.log"
got=$("$PY" - "$R" "$F1" "$F2" "$F3" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
for d in sys.argv[2:]: c = census.caps_state(d); print(c['满屏'].split('（')[0], c['满屏能力'], census.fs_state(d)[1], sep='|')
PYEOF
)
chk "⑪ 满屏列按判据三档（11-02）：有红但没到 MARK = 待分层、带截图 / 过 / 未判，能力开关另存满屏能力" "待分层|-|/x/fit_red_1.png
过|-|
未判|-|" "$got"
chk "⑪ 总表表头带三列（进局之后、日期之前），归约变体 / 原生帧率在日期之后，口径、系统版本、直连编不过、接口缺口、满屏能力、原生档、手测、不卡、一次成功在最后" "进局 满屏 60帧 强信号 日期 归约变体 原生帧率 首遇现建 宽屏断崖 口径 系统版本 直连编不过 接口缺口 满屏能力 原生档 手测 不卡 一次成功" "$("$PY" -c "import sys; sys.path.insert(0, '$R/tools/census'); import census; print(*census.TH[-19:-1])")"
# ㉜ 直连编不过列（11-01 总指挥：编不过的支数与清单进总表，交直连缺陷线归族）：期望按造的清单手写
mkdir -p "$B/df/a" "$B/df/b" "$B/df/c"; printf '键\t类别\t错误\nk1\tmetal failed\te1\nk2\tMSL failed\te2\nk3\tmetal failed\te3\n' > "$B/df/a/direct_fail.tsv"; printf '键\t类别\t错误\n' > "$B/df/b/direct_fail.tsv"
DF=$("$PY" -c "import sys, os; sys.path.insert(0, '$R/tools/census'); os.environ['CENSUS_FAIL_LIST'] = '$B/df/list.tsv'; import census; print(census.direct_fail('K1', '$B/df/a'), census.direct_fail('K2', '$B/df/b'), census.direct_fail('K3', '$B/df/c'), sep='|')")
chk "㉜ 直连编不过：3 支按类别计数 / 只有表头 = 0 / 没清单 = -" "3（metal failed 2、MSL failed 1）|0|-" "$DF"
chk "㉜ 批次清单：表头 + K1 的 3 行（只有表头的款不追加）" "4 K1" "$(wc -l < "$B/df/list.tsv" | tr -d ' ') $(sed -n 2p "$B/df/list.tsv" | cut -f1)"
# ㉛ 系统版本列（11-01 总指挥：同一份着色器 M3 / macOS 27 编译器内部错误、M5 / macOS 26 正常，按版本归因）：期望按日志行手写
mkdir -p "$B/sv/a" "$B/sv/b" "$B/sv/c"; printf '[s2a] 机器：系统 27.0，芯片 Apple M3\n' > "$B/sv/a/host.log"; printf '[dm] [nvn-mtl] Metal device Apple M5 Max\n' > "$B/sv/b/host.log"; : > "$B/sv/c/host.log"
chk "㉛ 系统版本：新宿主行 → 版本 / 芯片；旧宿主只取 Metal device；都没有空" "27.0 / Apple M3|? / Apple M5 Max|" "$("$PY" -c "import sys; sys.path.insert(0, '$R/tools/census'); import census; print('|'.join(census.sys_version('$B/sv/' + d) for d in 'abc'))")"
# ㉚ 口径列（11-01 总指挥：总表「通过」只是不崩 + 出图，不能把没进局的算通过）：期望手算
chk "㉚ 口径：通过+进局否→未进局；通过+进局是→不崩出图；通过+进局未判→进局未判；通过+通用→没走直连；失败/未判/源文件坏原样" "未进局 不崩出图 进局未判 没走直连 失败 未判 源文件坏" "$("$PY" -c "
import sys; sys.path.insert(0, '$R/tools/census'); import census as c
print(*[c.caliber(r) for r in (dict(结论='通过', 进局='否'), dict(结论='通过', 进局='是'), dict(结论='通过', 进局='未判'), dict(结论='通过', 进局='是', 图形模式='通用'), dict(结论='失败'), dict(结论='未判'), dict(结论='源文件坏'))])")"
# ⑫ 真绑归约变体（10-29 画面线 #800）：期望手写——3 种行；同一着色器两行算 1 支；失败没毫秒另计；没有行 = 空
L4=$T/red1; L5=$T/red2; L6=$T/red3; mkdir -p "$L4" "$L5" "$L6"
printf '%s\n' '[s2a] 归约变体：程序号 0100152000022000 着色器 vs_a1 后台编完成 12.5 ms' '[s2a] 归约变体：程序号 0100152000022000 着色器 fs_b2 同步现编完成 42.1 ms' \
  '[s2a] 归约变体：程序号 0100152000022000 着色器 vs_a1 后台编完成 3.0 ms' '[s2a] 归约变体：程序号 0100152000022000 着色器 fs_c3 后台编失败 7.0 ms：编译器拒绝（Metal 4）' '[s2a] 归约变体：程序号 0100152000022000 着色器 fs_d4 同步现编失败 99.0 ms：超时' > "$L4/host.log"
printf '%s\n' '[s2a] 归约变体：程序号 0100152000022000 着色器 fs_c3 后台编失败 3.0 ms：超时' > "$L5/host.log"
printf '%s\n' '[s2a] 模块：1 个' > "$L6/host.log"
got=$("$PY" - "$R" "$L4" "$L5" "$L6" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
for d in sys.argv[2:]: print(census.reduce_state(d) or '空')
PYEOF
)
chk "⑫ 归约变体：4 支 / 最大 42.1 ms（失败 2，含同步现编失败；失败的 99 ms 不算最大）；只有失败 → 1 支 / 最大 -（失败 1）；没有行 → 空" "4 支 / 最大 42.1 ms（失败 2）
1 支 / 最大 -（失败 1）
空" "$got"
B3=$T/b3; mkdir -p "$B3"
"$PY" - "$R" "$B3/总表.tsv" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
base = {'结论': '通过', '第一个失败点': '-', 'Mac局秒': '300', '崩溃': '否', '进局': '是', '满屏': '开', '60帧': '开'}
census.write_tsv(sys.argv[2], census.TH, [dict(base, 键='0100152000022000', 名称='马车8', 归约变体='3 支 / 最大 42.1 ms'), dict(base, 键='0100000000AAA000', 名称='别款', 归约变体='')])
PYEOF
$C sum "$B3" > /dev/null
chk "⑫ 汇总.md 列出真绑归约的款（只列有的那款）" "## 真绑归约的款（1 款）|| 马车8 | 0100152000022000 | 3 支 / 最大 42.1 ms | work/0100152000022000/r/logs/0100152000022000 ||" "$(grep -E '^## 真绑归约|^\| 马车8' "$B3/汇总.md" | tr '\n' '|')"
# ⑱ 局内帧率只按 MARK 之后（10-30 grokbot S 级③）+ L2 卡点（S 级②）。期望手写：
#   timing 窗口 up to 300/600 是 16.67、900/1200 是 33.33，MARK 在帧 600 → 只取 900、1200 两窗 → 30.0（请求间隔 1）；
#   同一份日志没到 MARK（marked false）→ 空；没 MARK 但 AI 判进局（entered）→ 只取局末 2 窗（M3：前 3 窗 33.33、末 2 窗 16.67）→ 60.0；
#   L2：30.0 + 60 帧开 → 是；30.0 + 60 帧关 + 间隔 2 → 不是；30.0 + 60 帧关 + 间隔 1 → 是；60.0 + 60 帧开 → 不是
M1=$T/m1; M2=$T/m2; mkdir -p "$M1" "$M2"
for d in "$M1" "$M2"; do { printf '%s\n' '[gal] 帧节拍：交换间隔 1，每帧 16.7 ms（60.0 帧/秒）'
  for n in 300 600; do printf '[s2a] [nvn] timing up to frame %s: frame time p50 16.67 / p95 17.0 / max 18 ms (300 frames)\n' $n; done
  for n in 900 1200; do printf '[s2a] [nvn] timing up to frame %s: frame time p50 33.33 / p95 34.0 / max 35 ms (300 frames)\n' $n; done; } > "$d/host.log"; done
M3=$T/m3; mkdir -p "$M3"; { printf '%s\n' '[gal] 帧节拍：交换间隔 1，每帧 16.7 ms（60.0 帧/秒）'   # 前 3 窗 33.33、末 2 窗 16.67：只取末 2 窗 → 60.0，取全部会是 30.0
  for n in 300 600 900; do printf '[s2a] [nvn] timing up to frame %s: frame time p50 33.33 / p95 34.0 / max 35 ms (300 frames)\n' $n; done
  for n in 1200 1500; do printf '[s2a] [nvn] timing up to frame %s: frame time p50 16.67 / p95 17.0 / max 18 ms (300 frames)\n' $n; done; } > "$M3/host.log"
echo '{"marked": true, "mark_frame": 600}' > "$M1/ap_summary.json"; echo '{"marked": false, "mark_frame": 0}' > "$M2/ap_summary.json"
got=$("$PY" - "$R" "$M1" "$M2" "$M3" <<'L2EOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
for d in sys.argv[2:4]: print(census.native_rate(d) or '空')
print(census.native_rate(sys.argv[4], True))
h = lambda v, f: census.l2_hit({'原生帧率': v, '60帧': f})
print(h('30.0（请求间隔 1）', '开'), h('30.0（请求间隔 2）', '关'), h('30.0（请求间隔 1）', '关'), h('60.0（请求间隔 1）', '开'))
L2EOF
)
chk "⑱ 局内帧率只取 MARK 后窗口、没 MARK 不判（AI 判进局取局末 2 窗）；L2 卡点判据" "30.0（请求间隔 1）
空
60.0（请求间隔 1）
True False True False" "$got"
# ⑱b 原生帧率不算逻辑速度同局 A/B 段里的窗口（11-04 提前收局：A/B 段占 MARK 后窗口的一半以上）。期望手写：60 帧关、游戏照常 30 帧（33.33 ms）的款，
#   A/B 放开段 3 窗 16.67、回原帧率 1 窗 33.33、再放开 3 窗 16.67、测完后第一窗 16.67（跨进照常，不算）、照常 2 窗 33.33 → 只剩照常 2 窗 → 30.0；全算是 7 窗 16.67 对 3 窗 33.33、中位 60.0
A1=$T/ab1; mkdir -p "$A1"; { printf '%s\n' '[gal] 帧节拍：交换间隔 1，每帧 16.7 ms（60.0 帧/秒）' '[s2a] 帧率表：逻辑速度同局 A/B 放开（测开段）'
  w() { for n in "$@"; do printf '[s2a] [nvn] timing up to frame %s: frame time p50 %s / p95 34.0 / max 35 ms (300 frames)\n' "${n%:*}" "${n#*:}"; done; }
  w 300:16.67 600:16.67 900:16.67; echo '[s2a] 帧率表：逻辑速度同局 A/B 回游戏原帧率（降档原因 3）'; w 1200:33.33
  echo '[s2a] 帧率表：逻辑速度同局 A/B 放开（测开段）'; w 1500:16.67 1800:16.67 2100:16.67; echo '[s2a] 帧率表：逻辑速度同局 A/B 测完，回到照常'; w 2400:16.67 2700:33.33 3000:33.33; } > "$A1/host.log"
echo '{"marked": true, "mark_frame": 0}' > "$A1/ap_summary.json"
chk "⑱b 原生帧率去掉逻辑速度同局 A/B 段窗口（60 帧关、照常 30 帧）" "30.0（请求间隔 1）" "$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1] + "/tools/census"); import census; print(census.native_rate(sys.argv[2]))' "$R" "$A1")"
# ⑬ 原生 60（10-29 c1029c：「60 帧静态无来源」多款原生就跑 60）。期望手写：请求间隔 1 + 帧表 600 帧 16.667 ms → 「60.0（请求间隔 1）」、60 帧关 → 原生 60；
#   请求间隔 1 但 33.333 ms（引擎自己限帧，大航海型）→ 30.0、不算；60 帧开 → 不算；帧表只 100 帧 → 空；native60 子命令写 1 行、重跑不重复
N1=$T/n1; N2=$T/n2; N3=$T/n3; mkdir -p "$N1/run" "$N2/run" "$N3/run"
for d in "$N1" "$N2" "$N3"; do printf '%s\n' '[gal] 帧节拍：交换间隔 1，每帧 16.7 ms（60.0 帧/秒）' '[s2a] 构建号 0123456789abcdef0123456789abcdef' > "$d/host.log"; done
for d in "$N1" "$N2" "$N3"; do echo '{"marked": true, "mark_frame": 0}' > "$d/ap_summary.json"; done
fr() { { printf 'frame\twall_us\n'; for i in $(seq 1 "$2"); do printf '%s\t%s\n' "$i" "$3"; done; } > "$1/run/frames.tsv"; }
fr "$N1" 600 16667; fr "$N2" 600 33333; fr "$N3" 100 16667
got=$("$PY" - "$R" "$N1" "$N2" "$N3" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
for d in sys.argv[2:]: print(census.native_rate(d) or '空')
r = lambda v, f: census.native60_hit({'原生帧率': v, '60帧': f})
print(r('60.0（请求间隔 1）', '关'), r('30.0（请求间隔 1）', '关'), r('60.0（请求间隔 1）', '开'), r('60.0（请求间隔 2）', '关'))
print(r('57.5（请求间隔 1）', '关'), r('58.0（请求间隔 1）', '关'))
PYEOF
)
chk "⑬ 原生帧率：60 帧 / 引擎限 30 / 帧表太短；判据只认 60 帧关 + 间隔 1 + ≥ 58" "60.0（请求间隔 1）
30.0（请求间隔 1）
空
True False False False
False True" "$got"
B4=$T/b4; mkdir -p "$B4/work/0100AAAA00000000/r/logs" "$T/repo4/docs"; cp -R "$N1" "$B4/work/0100AAAA00000000/r/logs/0100AAAA00000000"
mkdir -p "$T/repo4/docs/名单_60帧能力覆盖"; printf '程序号\t构建号\t款\tL1交换间隔\tL1依据\tL2引擎限帧\tL2依据\tL3时间步\tL3依据\t未达标原因\n' > "$T/repo4/docs/名单_60帧能力覆盖/_表头.tsv"   # 按款登记目录（10-30）
"$PY" - "$R" "$B4/总表.tsv" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
census.write_tsv(sys.argv[2], census.TH, [{'键': '0100AAAA00000000', '名称': 'n', '结论': '通过', '60帧': '关', '原生帧率': '60.0（请求间隔 1）'}])
PYEOF
$C native60 "$B4" "$T/repo4" > /dev/null; $C native60 "$B4" "$T/repo4" > /dev/null
chk "⑬ native60 写 1 行（L1 / L2 不需要、构建号取 host.log），重跑不重复" "1 0100AAAA00000000 0123456789abcdef0123456789abcdef 不需要 不需要" \
  "$("$PY" "$R/tools/reglist.py" cat "$T/repo4" 名单_60帧能力覆盖 | awk -F'\t' 'NR > 1 {n++; l = $1 " " $2 " " $4 " " $6} END {print n, l}')"
# ⑭ 首遇现建（10-29 画面线）。期望手写：MARK 后 / 预热后两种写法都认、取最后一行；没有行 → 空；最长 34.5 > 16.7 超一帧、12.0 不超
F1=$T/fb1; F2=$T/fb2; F3=$T/fb3; mkdir -p "$F1" "$F2" "$F3"
printf '%s\n' '[s2a] 首遇现建：预热后提交线程现建管线 3 条，最长 9.0 ms，合计 20.0 ms' '[s2a] 首遇现建：MARK 后提交线程现建管线 12 条，最长 34.5 ms，合计 80.2 ms' > "$F1/host.log"
printf '%s\n' '[s2a] 首遇现建：预热后提交线程现建管线 2 条，最长 12.0 ms，合计 15.0 ms' > "$F2/host.log"; printf '%s\n' '[s2a] 模块：1 个' > "$F3/host.log"
got=$("$PY" - "$R" "$F1" "$F2" "$F3" <<'FBEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
for d in sys.argv[2:]: v = census.first_build(d); print(v or '空', census.first_slow({'首遇现建': v}))
FBEOF
)
chk "⑭ 首遇现建：取最后一行、两种写法都认；超一帧判据" "12 条 / 最长 34.5 ms True
2 条 / 最长 12.0 ms False
空 False" "$got"
# ⑰ 主机档进局登记（10-30 S 级 ①）。期望手写：一款日志目录有 .进局档位（docked）、一款没有 → 表里加 1 行（程序号 docked）；重跑不重复；表不存在时连表头建
B6=$T/b6; mkdir -p "$B6/work/0100CCCC00000000/r/logs/0100CCCC00000000" "$B6/work/0100DDDD00000000/r/logs/0100DDDD00000000" "$T/repo6/docs"
printf 'docked\t点触没反应 3 次\n' > "$B6/work/0100CCCC00000000/r/logs/0100CCCC00000000/.进局档位"
"$PY" - "$R" "$B6/总表.tsv" <<'DKEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
census.write_tsv(sys.argv[2], census.TH, [{'键': '0100CCCC00000000', '名称': 'c', '结论': '通过'}, {'键': '0100DDDD00000000', '名称': 'd', '结论': '通过'}])
DKEOF
$C dock "$B6" "$T/repo6" > /dev/null; $C dock "$B6" "$T/repo6" > /dev/null
chk "⑰ dock 写 1 行（0100CCCC00000000 docked）、重跑不重复、带表头" "1 0100CCCC00000000 docked 程序号" \
  "$(awk -F'\t' '!/^#/ && NR > 2 {n++; l = $1 " " $2} /^程序号/ {h = $1} END {print n, l, h}' "$T/repo6/docs/名单_进局档位.tsv")"
# ⑲ 直连单轨（jhz 10-30 开发期只出直连）+ 直连缺陷表。期望手写：
#   三率：A 直连进局、B 通用进局（退到通用）、C 直连没进局（没崩）→ 进局 1/3、0 崩 2/3（通用局 B 不算进局也不算 0 崩）；klass(B) = 没走直连（退到通用）、归画面线
#   缺陷表：A 不列；B 画面线；C 泛化线（没有 host.log、没有挡进局的红行 → 没进局：未定因）；D 宿主 abort、关键红行是 [nvn-mtl] FATAL（不带【红】）→ 画面线、类别带（直连图形层）、首个红行列写 FATAL 行；
#   E 客体代码崩溃、崩溃前碰巧有 [gal] 红行 → 仍归原生线；上游对照表按程序号填 D 的上游与下一步（对照表优先，E 按类别给下一步）
B7=$T/b7; mkdir -p "$B7" "$T/repo7/docs"
for k in 0100D00000000000 0100E00000000000; do mkdir -p "$B7/work/$k/r/logs/$k"; done
printf '%s\n' '[dm] [nvn-mtl] 【红】 pipeline archive: cannot remove build folder' '[dm] [nvn-mtl] FATAL shader x has an unexpected argument buffer layout' '[s2a] 【红】崩溃原始现场 信号 6' > "$B7/work/0100D00000000000/r/logs/0100D00000000000/host.log"
printf '%s\n' '[gal] 【红】宏未离线编：程序 y' '[s2a] 【红】CRASH 信号 11 地址 0x0 pc main+0x10' > "$B7/work/0100E00000000000/r/logs/0100E00000000000/host.log"
printf '程序号\t关键词\t上游\t下一步\n0100D00000000000\t\t上游 #123\t照上游改\n' > "$T/repo7/docs/名单_直连缺陷上游.tsv"; "$PY" "$R/tools/reglist.py" migrate "$T/repo7" > /dev/null   # 拆成按款登记目录（10-30）
( "$PY" - "$R" "$B7/总表.tsv" <<'DDEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
b = {'机器': 'mini', 'Mac局秒': '100', '崩溃': '否', '第一个失败点': '-'}
census.write_tsv(sys.argv[2], census.TH, [dict(b, 键='0100A00000000000', 名称='A', 结论='通过', 进局='是', 图形模式='直连'),
    dict(b, 键='0100B00000000000', 名称='B', 结论='通过', 进局='是', 图形模式='通用'),
    dict(b, 键='0100C00000000000', 名称='C', 结论='通过', 进局='否', 图形模式='直连'),
    dict(b, 键='0100D00000000000', 名称='D', 结论='失败', 进局='否', 图形模式='直连', 崩溃='是', 第一个失败点='稳定崩溃：abort（首帧前）'),
    dict(b, 键='0100E00000000000', 名称='E', 结论='失败', 进局='否', 图形模式='直连', 崩溃='是', 第一个失败点='稳定崩溃：客体代码（main+0x10）')])
r = census.count_rates(census.tsv(sys.argv[2])[:3]); print(r[1], r[2], census.klass({'结论': '通过', '图形模式': '通用', '进局': '是'}), census.owner('没走直连（退到通用）'))
DDEOF
) > "$T/dd.out"
chk "⑲ 单轨三率：进局 1/3、0 崩 2/3；退到通用 → 没走直连、归画面线" "(1, 3) (2, 3) 没走直连（退到通用） 画面线" "$(head -1 "$T/dd.out")"
$C direct_defects "$B7" "$T/repo7" > /dev/null
chk "⑲ 缺陷表：B 画面线 / C 泛化线 / D 画面线（直连图形层，FATAL 行，上游 #123、下一步取对照表）/ E 原生线（下一步按类别）；A 不列" \
  "B 画面线 没走直连（退到通用）|C 泛化线 没进局：未定因|D 画面线 稳定崩溃：abort（直连图形层） 上游 #123 照上游改 [dm] [nvn-mtl] FATAL shader x has an unexpected argument buffer layout|E 原生线 稳定崩溃：客体代码 未查 先在 Ryujinx 上同版本对拍" \
  "$(awk -F'\t' 'NR > 1 {l = $1 " " $6 " " $5; if ($1 == "D") l = l " " $10 " " $7 " " $12; if ($1 == "E") l = l " " $10 " " substr($7, 1, index($7, "；") - 1); print l}' "$B7/直连缺陷表.tsv" | sort | paste -sd'|' -)"
# ⑳ 环境判据 + 退到通用的原因（10-30 画面线）。期望手写：F 失败局 host.log 有「GPU deswizzle init failed」→ 类别「环境：编译服务失效」、归属「环境（复跑再判）」；
#   G 退到通用、oneclick.log 有「unsupported graphics API: no main import nvnBootstrapLoader」→ 下一步以「非 NVN 款」开头；H 退到通用、没有出包日志 → 下一步提示重出看 oneclick.log
B8=$T/b8; for k in 0100F00000000000 0100F10000000000 0100F20000000000; do mkdir -p "$B8/work/$k/r/logs/$k"; echo '[s2a] 图形模式：通用' > "$B8/work/$k/r/logs/$k/host.log"; done
printf '%s\n' '[dm] [nvn-mtl] 【红】 GPU deswizzle init failed; swizzled textures fall back to the CPU' '[s2a] 【红】崩溃原始现场 信号 6' > "$B8/work/0100F00000000000/r/logs/0100F00000000000/host.log"
printf '%s\n' '【黄】直连缺口：配置推导不支持本款：unsupported graphics API: no main import nvnBootstrapLoader' > "$B8/work/0100F10000000000/r/logs/0100F10000000000/oneclick.log"
"$PY" - "$R" "$B8/总表.tsv" <<'ENVEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
b = {'机器': 'mini', 'Mac局秒': '100', '崩溃': '否', '第一个失败点': '-', '进局': '否'}
census.write_tsv(sys.argv[2], census.TH, [dict(b, 键='0100F00000000000', 名称='F', 结论='失败', 图形模式='直连', 崩溃='是', 第一个失败点='稳定崩溃：abort（首帧前）'),
    dict(b, 键='0100F10000000000', 名称='G', 结论='通过', 图形模式='通用'), dict(b, 键='0100F20000000000', 名称='H', 结论='通过', 图形模式='通用')])
ENVEOF
mkdir -p "$T/repo8/docs"; $C direct_defects "$B8" "$T/repo8" > /dev/null
chk "⑳ 环境判据 / 非 NVN 原因 / 没出包日志提示重出" "F 环境（复跑再判） 环境：编译服务失效|G 非 NVN 款|H 包里没出本链直连库" \
  "$(awk -F'\t' 'NR > 1 {if ($1 == "F") print $1 " " $6 " " $5; else print $1 " " substr($7, 1, index($7, "（") - 1)}' "$B8/直连缺陷表.tsv" | sort | paste -sd'|' -)"
# ㉑ 只出直连后的出包阶段直连缺口（10-30）。期望手写：P 出包失败、出包日志有「直连单轨停在 直连配置推导」→ 进缺陷表、类别「出包：直连缺口」、归画面线、
#   关键红行取出包日志那条；Q 出包失败但日志是别的（盘不足）→ 不进缺陷表（出包线的事）；旧行记成「出包：改写」的 P 也按日志改判
B9=$T/b9; for k in 0100F30000000000 0100F40000000000; do mkdir -p "$B9/work/$k/r/logs/$k"; done
printf '%s\n' '[14:11:41] 🔴 刷新停在：【红】tp 直连单轨停在 直连配置推导：直连缺口：配置推导不支持本款' > "$B9/work/0100F30000000000/r/logs/0100F30000000000/oneclick.log"
printf '%s\n' '【红】出包：本机盘不足' > "$B9/work/0100F40000000000/r/logs/0100F40000000000/oneclick.log"
"$PY" - "$R" "$B9/总表.tsv" <<'DGEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
b = {'机器': 'local', 'Mac局秒': '0', '崩溃': '-', '进局': '-', '图形模式': '-', '结论': '失败'}
census.write_tsv(sys.argv[2], census.TH, [dict(b, 键='0100F30000000000', 名称='P', 第一个失败点='出包：改写'), dict(b, 键='0100F40000000000', 名称='Q', 第一个失败点='出包：刷新其它')])
DGEOF
mkdir -p "$T/repo9/docs"; $C direct_defects "$B9" "$T/repo9" > /dev/null
chk "㉑ 出包阶段直连缺口进表归画面线、关键红行取出包日志；别的出包失败不进表" "P 画面线 出包：直连缺口 直连单轨停在" \
  "$(awk -F'\t' 'NR > 1 {r = ($12 ~ /直连单轨停在/) ? "直连单轨停在" : "无"; print $1 " " $6 " " $5 " " r}' "$B9/直连缺陷表.tsv" | paste -sd'|' -)"
# ㉒ 满屏判据红不当没进局的原因 + 已删机制的旧读数（10-30 总指挥）。期望手写（四款都直连、没进局、没崩）：
#   J 先打满屏判据红、后打「NVN address lookup」红 → 第一个失败点 / 首个红行 = NVN 那条，满屏判据红列 = 满屏那条，类别 没进局（直连图形层）、归画面线；
#   K 只有满屏判据红 → 没进局：未定因、首个红行 -、满屏列有；M「linked stand-in」红、局早于链接版删除合入（10-30 10:35）→ 旧读数待重测、环境（复跑再判）；
#   N 同样的红、局在删除之后 → 不当旧读数（[nvn-mtl] 红 → 没进局（直连图形层）、画面线）
B10=$T/b10; for k in 0100F50000000000 0100F60000000000 0100F70000000000 0100F80000000000; do mkdir -p "$B10/work/$k/r/logs/$k"; done
FSL='[dm] [nvn-mtl] 【红】出图未满屏（内容，第 9 次出图起）：画面 2346x1080 左侧到第 315 列起明显变暗'
printf '%s\n' "$FSL" '[s2a] 【红】 NVN address lookup of an unknown name: nvnX' > "$B10/work/0100F50000000000/r/logs/0100F50000000000/host.log"
printf '%s\n' "$FSL" > "$B10/work/0100F60000000000/r/logs/0100F60000000000/host.log"
for k in 0100F70000000000 0100F80000000000; do printf '%s\n' '[dm] [nvn-mtl] 【红】 linked stand-in: preload link failed (vertex a fragment b)' > "$B10/work/$k/r/logs/$k/host.log"; done
touch -t 202610291200 "$B10/work/0100F70000000000/r/logs/0100F70000000000/host.log"
"$PY" - "$R" "$B10/总表.tsv" <<'FSEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
b = {'机器': 'mini', 'Mac局秒': '100', '崩溃': '否', '第一个失败点': '-', '进局': '否', '结论': '通过', '图形模式': '直连'}
census.write_tsv(sys.argv[2], census.TH, [dict(b, 键=k, 名称=n) for k, n in (('0100F50000000000', 'J'), ('0100F60000000000', 'K'), ('0100F70000000000', 'M'), ('0100F80000000000', 'N'))])
FSEOF
mkdir -p "$T/repo10/docs"; $C direct_defects "$B10" "$T/repo10" > /dev/null
chk "㉒ 满屏判据红单独一列、不当没进局原因；已删机制的旧局记旧读数待重测" \
  "J 画面线 没进局（直连图形层） NVN NVN 满屏|K 泛化线 没进局：未定因 - - 满屏|M 环境（复跑再判） 旧读数待重测 旧读数待重测 linked -|N 画面线 没进局（直连图形层） linked linked -" \
  "$(awk -F'\t' 'NR > 1 {f = $4 ~ /NVN/ ? "NVN" : ($4 ~ /旧读数/ ? "旧读数待重测" : ($4 ~ /linked/ ? "linked" : $4)); r = $12 ~ /NVN/ ? "NVN" : ($12 ~ /linked/ ? "linked" : $12); s = $13 ~ /出图未满屏/ ? "满屏" : $13; print $1 " " $6 " " $5 " " f " " r " " s}' "$B10/直连缺陷表.tsv" | sort | paste -sd'|' -)"
# ㉓ 宽屏两侧缺渲染（10-30 #996）。期望手写：断崖 0.84、满屏开 → 判坏；0.84 但满屏关 → 不判（没放宽屏）；0.30 → 不判；widen_cliff 子命令写 1 行、重跑不重复
got=$("$PY" - "$R" <<'WCEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
print(census.cliff_bad({'满屏能力': '开', '宽屏断崖': '0.84'}), census.cliff_bad({'满屏能力': '关', '宽屏断崖': '0.84'}), census.cliff_bad({'满屏能力': '开', '宽屏断崖': '0.30'}), census.cliff_bad({'满屏': '开', '宽屏断崖': ''}))
WCEOF
)
chk "㉓ 宽屏缺渲染判据：满屏开且断崖 ≥ 0.5 才算" "True False False False" "$got"
B5=$T/b5; mkdir -p "$B5/work/0100BBBB00000000/r/logs/0100BBBB00000000" "$T/repo5/docs"
printf '[s2a] 构建号 0123456789abcdef0123456789abcdef\n' > "$B5/work/0100BBBB00000000/r/logs/0100BBBB00000000/host.log"
mkdir -p "$T/repo5/docs/名单_能力强信号"; printf '# 强信号\n程序号\t构建号\t能力\t内容哈希\t信号\t依据\t日期\n' > "$T/repo5/docs/名单_能力强信号/_表头.tsv"   # 按款登记目录（10-30）
"$PY" - "$R" "$B5/总表.tsv" <<'WCEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
census.write_tsv(sys.argv[2], census.TH, [{'键': '0100BBBB00000000', '名称': 'w', '结论': '通过', '满屏能力': '开', '宽屏断崖': '0.84'}])
WCEOF
$C widen_cliff "$B5" "$T/repo5" > /dev/null; $C widen_cliff "$B5" "$T/repo5" > /dev/null
chk "㉓ widen_cliff 写 1 行（widen 宽屏画面坏、构建号取 host.log、带 16 位哈希），重跑不重复" "1 0100BBBB00000000 0123456789abcdef0123456789abcdef widen 16 宽屏画面坏" \
  "$(awk -F'\t' 'NR > 2 {n++; l = $1 " " $2 " " $3 " " length($4) " " $5} END {print n, l}' <("$PY" "$R/tools/reglist.py" cat "$T/repo5" 名单_能力强信号))"
# ㉔ 没进局、没有挡进局的红行：一直正常出图（≥ 1000 帧、没崩、自动玩家在按键）→ 没进局：卡在导航（失败点带自动玩家结论）；出图少 → 仍未定因。期望手写
B11=$T/b11; for k in 0100F90000000000 0100FA0000000000; do mkdir -p "$B11/work/$k/r/logs/$k"; printf '%s\n' '自动玩家：导航 → 按 A（第 3 下）' '自动玩家结论：没到 MARK；到放弃时限 200 秒没进可玩（阶段：导航）；按键 3 下' > "$B11/work/$k/r/logs/$k/host.log"; done
"$PY" - "$R" "$B11/总表.tsv" <<'NVEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
b = {'机器': 'mini', 'Mac局秒': '300', '崩溃': '否', '第一个失败点': '-', '进局': '否', '结论': '通过', '图形模式': '直连'}
census.write_tsv(sys.argv[2], census.TH, [dict(b, 键='0100F90000000000', 名称='S', 帧数='15000'), dict(b, 键='0100FA0000000000', 名称='U', 帧数='40')])
NVEOF
mkdir -p "$T/repo11/docs"; $C direct_defects "$B11" "$T/repo11" > /dev/null
chk "㉔ 正常出图卡导航 → 卡在导航、泛化线、失败点带结论；出图少 → 未定因" "S 泛化线 没进局：卡在导航 到放弃时限 200 秒没进可玩（阶段：导航）|U 泛化线 没进局：未定因 -" \
  "$(awk -F'\t' 'NR > 1 {f = $4; sub(/^.*没崩）：/, "", f); print $1 " " $6 " " $5 " " f}' "$B11/直连缺陷表.tsv" | sort | paste -sd'|' -)"
# ㉕ 直连能跑口径（10-30 总指挥）。期望手写：分母 = 直连、起了 Mac 局、进局判得出的 4 款（V 通用、W 进局未判不算）；
#   进局 1（S2）；能跑 2 = S2（进局）+ S3（15000 帧、没崩、没红行）；S4 崩了、S5 有挡进局红行不算 → (1, 2, 4)
B12=$T/b12; for k in 0100FB0000000000 0100FC0000000000 0100FD0000000000 0100FE0000000000; do mkdir -p "$B12/work/$k/r/logs/$k"; : > "$B12/work/$k/r/logs/$k/host.log"; done
echo '[s2a] 【红】 NVN address lookup of an unknown name: nvnX' > "$B12/work/0100FE0000000000/r/logs/0100FE0000000000/host.log"
got=$("$PY" - "$R" "$B12" <<'RNEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
b = {'机器': 'mini', 'Mac局秒': '300', '崩溃': '否', '第一个失败点': '-', '进局': '否', '结论': '通过', '图形模式': '直连', '帧数': '15000'}
rows = [dict(b, 键='0100FB0000000000', 进局='是'), dict(b, 键='0100FC0000000000'), dict(b, 键='0100FD0000000000', 崩溃='是', 结论='失败'),
        dict(b, 键='0100FE0000000000'), dict(b, 键='0100FF0000000000', 图形模式='通用'), dict(b, 键='0100F00000000001', 进局='未判')]
print(census.runnable(sys.argv[2], rows))
RNEOF
)
chk "㉕ 直连能跑：(进局, 能跑, 分母) = (1, 2, 4)" "(1, 2, 4)" "$got"
# ㉖ 直连实测登记（direct_reg → docs/名单_直连实测/，兼容性清单对外版的数据源）。期望手写：A 直连进局不崩 → 能跑 是（替换仓里同键旧的「否」行）；
#   B 直连崩溃 → 否；C 通用模式不进分母、不写；D 取不到构建号不写；重跑不重复
B12=$T/b12; for k in 0100FB0000000000 0100FC0000000000 0100FD0000000000 0100FE0000000000; do mkdir -p "$B12/work/$k/r/logs/$k"; done
for kb in 0100FB0000000000:aaaafbaaaaaaaaaa0000000000000000 0100FC0000000000:aaaafcaaaaaaaaaa0000000000000000 0100FD0000000000:aaaafdaaaaaaaaaa0000000000000000; do
  printf '[s2a] 主程序构建号 %s\n' "${kb#*:}" > "$B12/work/${kb%%:*}/r/logs/${kb%%:*}/host.log"; done
printf 'no build id\n' > "$B12/work/0100FE0000000000/r/logs/0100FE0000000000/host.log"
"$PY" - "$R" "$B12/总表.tsv" <<'DREOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
b = {'机器': 'local', 'Mac局秒': '300', '崩溃': '否', '第一个失败点': '-', '进局': '是', '结论': '通过', '图形模式': '直连', '帧数': '5000'}
census.write_tsv(sys.argv[2], census.TH, [dict(b, 键='0100FB0000000000', 名称='A'), dict(b, 键='0100FC0000000000', 名称='B', 崩溃='是', 进局='否', 结论='失败', 第一个失败点='崩溃'),
                                          dict(b, 键='0100FD0000000000', 名称='C', 图形模式='通用'), dict(b, 键='0100FE0000000000', 名称='D')])
DREOF
mkdir -p "$T/repo12/docs/名单_直连实测"; printf '# 直连实测\n程序号\t构建号\t款\t平台\t直连能跑\t进局\t依据\t日期\n' > "$T/repo12/docs/名单_直连实测/_表头.tsv"
printf '程序号\t构建号\t款\t平台\t直连能跑\t进局\t依据\t日期\n0100FB0000000000\taaaafbaaaaaaaaaa0000000000000000\tx\tMac\t否\t否\t旧\t2026-10-29\n' > "$T/repo12/docs/名单_直连实测/0100FB0000000000.tsv"
$C direct_reg "$B12" "$T/repo12" > /dev/null; $C direct_reg "$B12" "$T/repo12" > /dev/null
chk "㉖ direct_reg：A 能跑 是（替换旧行）、B 否；C 通用 / D 无构建号不写；重跑不重复" \
  "0100FB0000000000 aaaafbaaaaaaaaaa0000000000000000 Mac 是 是|0100FC0000000000 aaaafcaaaaaaaaaa0000000000000000 Mac 否 否" \
  "$(awk -F'\t' 'NR > 2 {print $1 " " $2 " " $4 " " $5 " " $6}' <("$PY" "$R/tools/reglist.py" cat "$T/repo12" 名单_直连实测) | sort | paste -sd'|' -)"
# ㉘ 本机先看机器槽有空位再领款（10-31：本机 3 道全领走在 slot.sh 干等、Air 道领不到款）：local_slot_free 期望手算
eval "$(sed -n '/^# >>> local_slot_free/,/^# <<< local_slot_free/p' "$R/tools/census/census.sh")"
SD=$T/slots28; mkdir -p "$SD"
r28() { ( "$@"; local_slot_free ) && echo 有 || echo 无; }
chk "㉘a 没设 S2A_SLOT_RUN → 有空位" 有 "$(unset S2A_SLOT_RUN; r28 true)"
chk "㉘b 设了、槽目录空 → 有空位" 有 "$(S2A_SLOT_RUN=x S2A_SLOT_DIR=$SD r28 true)"
for k in 1 2 3; do mkdir -p "$SD/$k"; echo $$ > "$SD/$k/pid"; done
chk "㉘c 3 槽都由活进程占着 → 没空位" 无 "$(S2A_SLOT_RUN=x S2A_SLOT_DIR=$SD r28 true)"
echo 99999999 > "$SD/2/pid"
chk "㉘d 槽 2 的进程已退出 → 有空位" 有 "$(S2A_SLOT_RUN=x S2A_SLOT_DIR=$SD r28 true)"
echo $$ > "$SD/2/pid"
chk "㉘e 槽数 2、两个都占着 → 没空位" 无 "$(S2A_SLOT_RUN=x S2A_SLOT_DIR=$SD S2A_SLOTS=2 r28 true)"
# ㉙ 盘点沿用上一批（10-31 总指挥）：同级目录最新一批的盘点，路径 + 大小没变且文件不比那份盘点新就沿用（行和清单文件），大小变了的 / 读不出的不沿用。期望手写：f1 沿用、f2 大小变了不沿用、f3 rc=1 不沿用
got=$(S2A_RUN_ROOT=$T/seed29/run "$PY" - "$R" "$T" <<'PYEOF'   # 隔离运行区：不读本机真普查目录的盘点（逐文件取后会混进来）
import sys, os; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
t = os.path.join(sys.argv[2], 'seed29'); old = os.path.join(t, 'c_old'); new = os.path.join(t, 'c_new')
os.makedirs(os.path.join(old, 'inventory')); os.makedirs(os.path.join(new, 'inventory'))
src = os.path.join(t, 'src'); os.makedirs(src)
for n, sz in (('f1.nsp', 5), ('f2.nsp', 7), ('f3.nsp', 3)): open(os.path.join(src, n), 'wb').write(b'x' * sz)
rows = [{'文件': os.path.join(src, 'f1.nsp'), '字节': '5', 'rc': '0', '清单': 'a.json'}, {'文件': os.path.join(src, 'f2.nsp'), '字节': '9', 'rc': '0', '清单': 'b.json'}, {'文件': os.path.join(src, 'f3.nsp'), '字节': '3', 'rc': '1', '清单': 'c.json'}]
for r in rows: open(os.path.join(old, 'inventory', r['清单']), 'w').write('{}')
census.write_tsv(os.path.join(old, 'inventory', 'inspect.tsv'), ['文件', '字节', 'rc', '清单'], rows)
os.utime(os.path.join(old, 'inventory', 'inspect.tsv'), (4102444800, 4102444800))   # 盘点时刻晚于所有文件
import io, contextlib
with contextlib.redirect_stdout(io.StringIO()): census.seed_inventory(new, os.path.join(new, 'inventory'))
print([os.path.basename(r['文件']) for r in census.tsv(os.path.join(new, 'inventory', 'inspect.tsv'))], os.path.exists(os.path.join(new, 'inventory', 'a.json')), os.path.exists(os.path.join(new, 'inventory', 'b.json')))
PYEOF
)
chk "㉙ 盘点沿用上一批：f1 沿用（清单文件也拷过来）、大小变了的 f2 与读不出的 f3 不沿用" "['f1.nsp'] True False" "$got"
# ㉙b 批次放在别的盘、同级没有盘点（11-02 各线验证批次在 2T_B）：取运行区 <S2A_RUN_ROOT>/s2arm/census 下的盘点。期望手写：f1 沿用
got=$(S2A_RUN_ROOT=$T/seed29b/run "$PY" - "$R" "$T" <<'PYEOF'
import sys, os; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
t = os.path.join(sys.argv[2], 'seed29b'); old = os.path.join(t, 'run', 's2arm', 'census', 'c_old'); new = os.path.join(t, 'other_disk', 'v1')
os.makedirs(os.path.join(old, 'inventory')); os.makedirs(os.path.join(new, 'inventory'))
f = os.path.join(t, 'f1.nsp'); open(f, 'wb').write(b'x' * 5); open(os.path.join(old, 'inventory', 'a.json'), 'w').write('{}')
census.write_tsv(os.path.join(old, 'inventory', 'inspect.tsv'), ['文件', '字节', 'rc', '清单'], [{'文件': f, '字节': '5', 'rc': '0', '清单': 'a.json'}])
os.utime(os.path.join(old, 'inventory', 'inspect.tsv'), (4102444800, 4102444800))
import io, contextlib
with contextlib.redirect_stdout(io.StringIO()): census.seed_inventory(new, os.path.join(new, 'inventory'))
print([os.path.basename(r['文件']) for r in census.tsv(os.path.join(new, 'inventory', 'inspect.tsv'))])
PYEOF
)
chk "㉙b 同级没有盘点 → 沿用运行区普查目录的盘点" "['f1.nsp']" "$got"
# ㉙c 盘点认退出码、.NET 环境取自 pack/srcs.sh（11-05 after_r2 v4：launchctl submit 无 DOTNET_ROOT，--inspect 全回 131，367 个文件 0 个读出）。
#   假仓库 pack/srcs.sh 只在入口导出 DOTNET_ROOT=<假根>，假 nx_unpack 没收到它就退 131。期望手写：
#   ① 三个文件 a（读出，退 0）/ b（容器读不出，退 3）/ c（退 131 = 工具没跑成）→ inventory 返回 1、只为 c 打一行【红】机器原因（带 rc 131 与原话）、b 不报机器原因；
#   ② 去掉 c → 返回 0、读出 1、读不出 1（DOTNET_ROOT 从 srcs.sh 带进了 python 进程，否则 a 也会是 131）
I29=$T/inv29c; mkdir -p "$I29/repo/pack" "$I29/src" "$I29/b"
printf 'export DOTNET_ROOT=%s/dn\nSRC_N=%s/nxu\n' "$I29" "$I29" > "$I29/repo/pack/srcs.sh"
cat > "$I29/nxu" <<'NXEOF'
#!/bin/bash
[ "$DOTNET_ROOT" = "$FAKE_DN" ] || { echo "You must install .NET" >&2; exit 131; }
case $(basename "$3") in a.nsp) echo '{"packages": []}';; b.nsp) echo "容器读不出" >&2; exit 3;; *) echo "Killed: runtime gone" >&2; exit 131;; esac
NXEOF
chmod +x "$I29/nxu"; for n in a b c; do printf x > "$I29/src/$n.nsp"; done
got=$(env -u DOTNET_ROOT FAKE_DN="$I29/dn" S2A_RUN_ROOT="$I29/run" "$PY" - "$R" "$I29" <<'PYEOF'
import sys, os, io, contextlib; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
t = sys.argv[2]; repo, src, b = (os.path.join(t, x) for x in ('repo', 'src', 'b'))
o = io.StringIO()
with contextlib.redirect_stdout(o): r1 = census.inventory(src, b, repo)
reds = [l for l in o.getvalue().splitlines() if l.startswith('【红】机器原因')]
os.remove(os.path.join(src, 'c.nsp')); o2 = io.StringIO()
with contextlib.redirect_stdout(o2): r2 = census.inventory(src, b, repo)
j = ''.join(reds)
print(r1, len(reds), 'c.nsp' in j and '退出 131' in j and 'runtime gone' in j, 'b.nsp' in j, r2, '读出 1、读不出 1' in o2.getvalue())
PYEOF
)
chk "㉙c 盘点：131 → 停批、只 c 报机器原因带原话；3 不报；.NET 环境取自 srcs.sh" "1 1 True False 0 True" "$got"
# ㉙d 逐文件取最新有效行（11-05：最新一批是没 .NET 运行时的坏批，全 rc=131，v5 沿用 0 个、全量重探 8 分钟）。期望手写：
#   旧批 c_a（较早）f1 rc=0、f2 rc=0；坏批 c_bad（最新）f1 / f2 都 rc=131；较新批 c_b（介于两者）f2 rc=0 换了清单 b2.json → 沿用 f1（来自 c_a）、f2（来自 c_b，清单 b2.json）
got=$(S2A_RUN_ROOT=$T/seed29d/run "$PY" - "$R" "$T" <<'PYEOF'
import sys, os, io, contextlib; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census
t = os.path.join(sys.argv[2], 'seed29d'); src = os.path.join(t, 'src'); os.makedirs(src)
for n in ('f1.nsp', 'f2.nsp'): open(os.path.join(src, n), 'wb').write(b'xx')
f1, f2 = os.path.join(src, 'f1.nsp'), os.path.join(src, 'f2.nsp')
def batch(name, rows, stamp):
    d = os.path.join(t, name, 'inventory'); os.makedirs(d)
    for r in rows: open(os.path.join(d, r['清单']), 'w').write(name)
    census.write_tsv(os.path.join(d, 'inspect.tsv'), ['文件', '字节', 'rc', '清单'], rows); os.utime(os.path.join(d, 'inspect.tsv'), (stamp, stamp))
batch('c_a', [{'文件': f1, '字节': '2', 'rc': '0', '清单': 'a1.json'}, {'文件': f2, '字节': '2', 'rc': '0', '清单': 'a2.json'}], 4102444800)
batch('c_b', [{'文件': f2, '字节': '2', 'rc': '0', '清单': 'b2.json'}], 4102444900)
batch('c_bad', [{'文件': f1, '字节': '2', 'rc': '131', '清单': 'x1.json'}, {'文件': f2, '字节': '2', 'rc': '131', '清单': 'x2.json'}], 4102445000)
new = os.path.join(t, 'c_new'); os.makedirs(os.path.join(new, 'inventory'))
with contextlib.redirect_stdout(io.StringIO()): census.seed_inventory(new, os.path.join(new, 'inventory'))
rows = census.tsv(os.path.join(new, 'inventory', 'inspect.tsv'))
print(sorted((os.path.basename(r['文件']), r['清单'], open(os.path.join(new, 'inventory', r['清单'])).read()) for r in rows))
PYEOF
)
chk "㉙d 最新一批是坏批 → 逐文件取最新有效行：f1 来自 c_a、f2 来自 c_b" "[('f1.nsp', 'a1.json', 'c_a'), ('f2.nsp', 'b2.json', 'c_b')]" "$got"
# ㉟ 远端盘闸 disk_ok（11-01：马车8 在 Air 55~72 GB 下被旧闸静默拦 2.5 小时；旧估值 3×源+5 对中大款低估）：期望按公式手算
#   预估峰值 = 4.5 × 源 GB + 14（取整向上）、硬闸缺省 20：源 14.2 GB → 4.5×14.2+14 = 77.9 → 78，需 98；源 0.1 GB → 14.45 → 15，需 35
DK=$T/dk; mkdir -p "$DK/tools" "$DK/b/work/big" "$DK/b/work/small"; printf 'n\tv\t14.2\n' > "$DK/b/work/big/meta"; printf 'n\tv\t0.1\n' > "$DK/b/work/small/meta"
printf '#!/bin/bash\necho "air 可用 ${FAKE_FREE} G"\n' > "$DK/tools/remote.sh"
dkrun() { ( R=$DK; B=$DK/b; L=$DK/b.log; log() { echo "[x] $*" >> "$L"; }; eval "$(sed -n '/^# >>> _wait_helpers/,/^# <<< _wait_helpers/p;/^# >>> disk_ok/,/^# <<< disk_ok/p' "$ROOT_CENSUS_SH")"; FAKE_FREE=$1 disk_ok air "$2" && echo 过 || echo 不过 ); }
ROOT_CENSUS_SH=$R/tools/census/census.sh
chk "㉟a 大款 Air 可用 70 < 需 98 → 不过" 不过 "$(dkrun 70 big)"
chk "㉟b 大款不过时记一行【黄】等盘：可用 70 / 需 98" "1 【黄】等盘：air 可用 70 G / 需 98 G" "$(grep -c '等盘' "$DK/b.log") $(grep -o '【黄】等盘：air 可用 70 G / 需 98 G' "$DK/b.log" | head -1)"
chk "㉟b2 黄行原文（运维按原文看）：括号里是款、源、预估峰值、硬闸" 1 "$(grep -c '【黄】等盘：air 可用 70 G / 需 98 G（big 源 14.2 GB，预估峰值 78 G + 硬闸 20 G），已等 0 分钟' "$DK/b.log")"
dkrun 70 big > /dev/null
chk "㉟c 10 分钟内再判不过不重复记行" 1 "$(grep -c '等盘' "$DK/b.log")"
chk "㉟d 大款 Air 可用 98 = 需 98 → 过，清等待记录" "过 0" "$(dkrun 98 big) $(ls "$DK/b"/.wait_disk.air.big 2> /dev/null | wc -l | tr -d ' ')"
chk "㉟d2 判过写一行「盘已够」，这行不带「等盘」（ops_status.py 按子串判在等盘）" "1 1" "$(grep -c '盘已够' "$DK/b.log") $(grep -c '等盘' "$DK/b.log")"
chk "㉟e 小款 Air 可用 40 ≥ 需 35 → 过；34 → 不过" "过 不过" "$(dkrun 40 small) $(dkrun 34 small)"
printf '%s %s\n' "$(( $(date +%s) - 1000 ))" "$(( $(date +%s) - 700 ))" > "$DK/b/.wait_disk.air.big"
dkrun 70 big > /dev/null
chk "㉟f 同一款已隔 10 分钟 → 再记一行（日志共 3 行 = a + e 的 34 + 本条）" 3 "$(grep -c '等盘' "$DK/b.log")"
# ㊱i 没跑成写原因（11-03 P5 对战版「没跑成」空白）：有红行取红行；没红行、退出码 124 → 墙钟超时；其它 → 退出码 + run.out 末行。期望手写
NW=$T/norun; mkdir -p "$NW"; NF=$(sed -n '/^norun_why() {/,/esac; }$/p' "$R/tools/census/census.sh")
nr() { ( W=$NW; rc=$1; t0=$SECONDS; CENSUS_LOCAL_S=4200; eval "$NF"; norun_why ); }
printf '一行\n【红】出包失败\n' > "$NW/run.out"; o1=$(nr 1); printf '普通输出\n' > "$NW/run.out"; o2=$(nr 124); o3=$(nr 3)
chk "㊱i 没跑成原因：红行 / 墙钟超时 / 退出码" "【红】出包失败|墙钟超时|退出码 3" "$o1|$(grep -o '墙钟超时' <<< "$o2")|$(grep -o '退出码 3' <<< "$o3")"
# ㊲ 已实现接口只算一次（审计 P1-57）：api_census.implemented() 第二次调用读缓存、不再读源文件；源文件变了（大小 / 修改时间）重扫
API=$T/api; mkdir -p "$API"
got=$(S2A_API_IMPL_CACHE=$API/c.json "$PY" - "$R" <<'PYEOF'
import sys, pathlib; sys.path.insert(0, sys.argv[1] + '/tools/census'); import api_census as a
r1 = a.implemented()
orig = pathlib.Path.read_text
def boom(self, *x, **k): raise AssertionError('读了源文件')
pathlib.Path.read_text = boom
try: r2 = a.implemented(); ok = r1 == r2
except AssertionError: ok = False
pathlib.Path.read_text = orig
print(ok, len(r1[0]) > 0 and len(r1[1]) > 0)
PYEOF
)
chk "㊲a implemented() 第二次读缓存：结果相同、没读源文件；有 GL / NVN 已实现名" "True True" "$got"
printf '#!/bin/bash\n' > /dev/null
chk "㊲b 接线：缺陷表限频（距上次出表 < CENSUS_DEFECTS_EVERY_S 不重出），批末 census.py sum 仍出" "有 有" "$(grep -q 'CENSUS_DEFECTS_EVERY_S:-300' "$R/tools/census/census.sh" && echo 有) $(grep -q 'dd = direct_defects(b, ' "$R/tools/census/census.py" && echo 有)"
# ㊴ Mac 局槽被占识别（11-02 泰拉瑞亚在本机路连排两次各 ~10 分钟没拿到 Mac 局槽，one_game 照样写「未判 / 局没起」一行，被当成这款的结果）：期望手写——
#   结果是「未判 · 局没起」且 run_mac.out 有「Mac 局槽：」等待行 → 判成机器原因（放回待跑）；同样的行但没有槽等待行 → 不判；结果是别的结论 → 不判。脚本里的判据原样抽出来跑
mkdir -p $T/c39/r/logs/kA $T/c39/r/logs/kB; H1='源\t款\t程序号\t结论\t第一个失败点\n'
printf "$H1"'x\tn\tkA\t未判\t局没起\n' > $T/c39/ra.tsv; printf "$H1"'x\tn\tkB\t通过\t-\n' > $T/c39/rb.tsv
echo 'Mac 局槽：进局检查 kA 让门禁显卡步骤先跑' > $T/c39/r/logs/kA/run_mac.out
slot_starved() { awk -F'\t' 'NR > 1 && $4 == "未判" && $5 == "局没起" {f = 1} END {exit !f}' "$1" && grep -a -q 'Mac 局槽：' "$2" 2> /dev/null && echo 是 || echo 否; }
chk "㊴a 未判·局没起 + 有 Mac 局槽等待行 → 是" 是 "$(slot_starved $T/c39/ra.tsv $T/c39/r/logs/kA/run_mac.out)"
chk "㊴b 未判·局没起 但没有槽等待行（run_mac.out 没这行）→ 否" 否 "$(slot_starved $T/c39/ra.tsv $T/c39/r/logs/kB/run_mac.out)"
chk "㊴c 结果是通过（哪怕有槽等待行）→ 否" 否 "$(slot_starved $T/c39/rb.tsv $T/c39/r/logs/kA/run_mac.out)"
chk "㊴d 接线：census.sh 里真有这段判据并 return 2（放回待跑）" "有 有" "$(grep -q "Mac 局槽被占、局没起，放回待跑（不计次）" "$R/tools/census/census.sh" && echo 有) $(grep -q "NR > 1 && \$4 == \"未判\" && \$5 == \"局没起\"" "$R/tools/census/census.sh" && echo 有)"
# ㊵ 本机宿主编译串行（11-02 v2 本机 3 道同时 make host 抢同一棵树致一道「不跑局」；11-03 两个批次共用一棵树、配置不同互相重编出「没链 C#」宿主）：
#   期望按规则手写——同一棵树、3 个不同批次目录同时调 host_build，替身 make 一旦发现另一个在跑就失败、并记下每次的 S2A_CS；
#   串行则 3 个都 rc=0、替身从没见到并发、3 次都带 S2A_CS=1；锁在树上（build/.make_host.lock，与 entry_check 同一把）
HB=$T/hb40; mkdir -p $HB/bin $HB/b1 $HB/b2 $HB/b3 $HB/tree/tools; cp "$R/tools/host_build.sh" $HB/tree/tools/
printf '#!/bin/bash\necho "${S2A_CS:-未设}" >> %s/cs\n[ -e %s/running ] && { echo 并发 >> %s/overlap; exit 1; }\ntouch %s/running; sleep 1; rm -f %s/running; exit 0\n' $HB $HB $HB $HB $HB > $HB/bin/make; chmod +x $HB/bin/make
( eval "$(sed -n '/^# >>> host_build/,/^# <<< host_build/p' "$R/tools/census/census.sh")"; R=$HB/tree; PATH=$HB/bin:$PATH
  ( B=$HB/b1; host_build; echo $? >> $HB/rc ) & ( B=$HB/b2; host_build; echo $? >> $HB/rc ) & ( B=$HB/b3; host_build; echo $? >> $HB/rc ) & wait )
chk "㊵a 同一棵树 3 个批次同时 host_build：全部 rc=0、替身 make 没见过并发、3 次都带 S2A_CS=1、锁在树上" "0 0 0 无 1 1 1 有" "$(paste -sd' ' $HB/rc) $([ -e $HB/overlap ] && echo 有 || echo 无) $(paste -sd' ' $HB/cs) $([ -e $HB/tree/build/.make_host.lock ] && echo 有 || echo 无)"
chk "㊵b 接线：runner 里本机先 host_build（不再裸 make host）" "有 无" "$(grep -q 'host_build || { log' "$R/tools/census/census.sh" && echo 有) $(grep -q '    make -C "\$R" -s host > "\$B/local_host_build.log" 2>&1 ||' "$R/tools/census/census.sh" && echo 有 || echo 无)"
# ㊶ Air 路本地化（11-04 重做）：air_push（判完即删 / 批停清空）、Air 工作区上限清理（盘不足记红跳过不等待）、内存准入（第 2 道只开 1 道不交换）
# ㊶a air_push：远端没有 → rsync 带该文件；已有同名同大小 → 跳过；大小不符 → 只推不符的；rsync 失败 → 返回 1；无 hdd_read 引用
AP=$T/ap41; mkdir -p $AP/bin $AP/srcroot $AP/remote $AP/b; echo hello > $AP/srcroot/a.nsp; echo hello2 > $AP/srcroot/b.nsp
cat > $AP/bin/ssh <<'SSHEOF'
#!/bin/bash
cmd="${@: -1}"
case "$cmd" in mkdir*) exit 0;; stat*) p=${cmd#*\'}; p=${p%%\'*}; f=__APROOT__/remote/$(basename "$p"); [ -f "$f" ] && stat -f %z "$f" || exit 1;; esac
SSHEOF
sed -i '' "s|__APROOT__|$AP|" "$AP/bin/ssh"
printf '#!/bin/bash\necho "$@" >> %s/rsync.log\n[ -e %s/rsync_fail ] && exit 1\nexit 0\n' $AP $AP > $AP/bin/rsync; chmod +x $AP/bin/ssh $AP/bin/rsync
apush() { ( eval "$(sed -n '/^# >>> air_push/,/^# <<< air_push/p' "$R/tools/census/census.sh")"; B=$AP/b; AIRSRC=/air/src; PATH=$AP/bin:$PATH air_push airhost kA 100 "$@" > /dev/null 2>&1; echo $? ); }
rm -f $AP/rsync.log; r1=$(apush $AP/srcroot/a.nsp); n1=$(cat $AP/rsync.log 2>/dev/null | grep -c a.nsp)
cp $AP/srcroot/a.nsp $AP/remote/a.nsp; rm -f $AP/rsync.log; r2=$(apush $AP/srcroot/a.nsp); n2=$(cat $AP/rsync.log 2>/dev/null | grep -c .)
echo x > $AP/remote/b.nsp; rm -f $AP/rsync.log; r3=$(apush $AP/srcroot/a.nsp $AP/srcroot/b.nsp); n3=$(cat $AP/rsync.log 2>/dev/null | grep -c b.nsp); n3a=$(cat $AP/rsync.log 2>/dev/null | grep -c a.nsp)
touch $AP/rsync_fail; rm -f $AP/rsync.log; r4=$(apush $AP/srcroot/b.nsp)
hdd_ref=$(grep -c 'hdd_read\|S2A_HDD_READ' "$R/tools/census/census.sh" || true)
chk "㊶a 远端没有→rsync 带该文件 rc=0；已有同名同大小→不调 rsync；大小不符→只推不符的；rsync 失败→rc=1；无 hdd_read 引用" \
  "0 1 0 0 0 1 0 1 0" \
  "$r1 $n1 $r2 $n2 $r3 $n3 $n3a $r4 $hdd_ref"

# ㊶ 假 Air（11-04 复核返工）：替身 ssh 把远端命令交给 env -i 的 zsh 在本机执行——不继承本机环境变量，同真 Air（ssh 不传环境、登录 shell 是 zsh、没有 flock）；
#   替身 df / sysctl / vm_stat 读 $FA/ctl 下的控制文件给定盘 / 内存读数（控制文件不在就用真命令；df_kb / swap_mb 每行一个读数，读一次弹一行，剩最后一行时一直读它）
#   Air 函数全部从真 census.sh 按标记抽段（air_rsh 到 air_metrics 一整段），不复制实现
FA=$T/fakeair; mkdir -p $FA/bin $FA/abin $FA/ctl $FA/home
cat > $FA/bin/ssh <<'EOF'
#!/bin/bash
while [ $# -gt 1 ]; do case $1 in -o) shift 2;; *) break;; esac; done; shift
exec env -i PATH=__FA__/abin:/usr/bin:/bin:/usr/sbin:/sbin HOME=__FA__/home /bin/zsh -c "$*"
EOF
cat > $FA/abin/df <<'EOF'
#!/bin/bash
f=__FA__/ctl/df_kb; [ -s "$f" ] || exec /bin/df "$@"
v=$(head -1 "$f"); [ "$(wc -l < "$f")" -gt 1 ] && sed -i '' 1d "$f"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/fake 999999999 1 %s 1%% /x\n' "$v"
EOF
cat > $FA/abin/sysctl <<'EOF'
#!/bin/bash
c=__FA__/ctl
case "$*" in
  "-n vm.swapusage") f=$c/swap_mb; [ -s "$f" ] || exec /usr/sbin/sysctl "$@"; v=$(head -1 "$f"); [ "$(wc -l < "$f")" -gt 1 ] && sed -i '' 1d "$f"
    echo "total = 4096.00M  used = ${v}.00M  free = 1.00M  (encrypted)";;
  "-n kern.memorystatus_vm_pressure_level") [ -s $c/level ] && cat $c/level || exec /usr/sbin/sysctl "$@";;
  "-n hw.memsize") echo 17179869184;;
  *) exec /usr/sbin/sysctl "$@";;
esac
EOF
printf '#!/bin/bash\n[ -s __FA__/ctl/vm_stat ] && cat __FA__/ctl/vm_stat || exec /usr/bin/vm_stat "$@"\n' > $FA/abin/vm_stat
sed -i '' "s|__FA__|$FA|g" $FA/bin/ssh $FA/abin/df $FA/abin/sysctl $FA/abin/vm_stat; chmod +x $FA/bin/ssh $FA/abin/*
CS=$R/tools/census/census.sh
# 假 Air 上的 vm_stat：取 11-04 真 Air 空闲时一份读数（16 KB 页；free+inactive+speculative+purgeable = 639734 页 = 9995 MB，wired 174964 页 = 2733 MB）
vmfake() { printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                               %s.\nPages active:                             185286.\nPages inactive:                           169991.\nPages speculative:                         29447.\nPages throttled:                               0.\nPages wired down:                         174964.\nPages purgeable:                            9304.\n' "$1" > $FA/ctl/vm_stat; }
fa_reset() { rm -rf "$FA/ctl"/* "$FA/air"; mkdir -p "$FA/air/work" "$FA/air/src"; }
# fa <命令…>：在子 shell 里装好 Air 段函数与批次环境（本机设了 S2A_AIR_* —— 远端拿不到，只能靠参数传）再跑命令
fa() { ( PATH=$FA/bin:$PATH; B=$FA/b; T=$FA/b/总表.tsv; L=$FA/b/log; AIRSH=air; AIRSRC=$FA/air/src; mkdir -p "$B/running" "$B/work"
  S2A_AIR_WORK=${S2A_AIR_WORK:-$FA/air/work}; S2A_AIR_CAP_UNPACK_GB=${S2A_AIR_CAP_UNPACK_GB:-1}; S2A_AIR_CAP_RUNS_GB=${S2A_AIR_CAP_RUNS_GB:-1}; S2A_AIR_CAP_ROOTS_GB=${S2A_AIR_CAP_ROOTS_GB:-1}
  log() { echo "[x] $*" >> "$L"; }
  eval "$(sed -n '/^# >>> air_push/,/^# <<< air_push/p;/^# >>> air_rsh/,/^# <<< air_metrics/p;/^# >>> claim/,/^# <<< claim/p' "$CS")"; "$@" ) }
mk3m() { mkdir -p "$1"; dd if=/dev/zero of="$1/f" bs=1048576 count=3 2> /dev/null; }
# ㊶b 缺陷 1：air_cleaner 在「不继承环境」的远端真清——unpack 上限 0.005 GB（= 5 MB）、三个 3 MB 子目录按 mtime 旧→新 a_kRun / b_mid / c_new，kRun 在跑受保护：
#   9 MB > 5 → 删最旧未保护 b_mid → 6 > 5 → 删 c_new → 3 ≤ 5 停；runs 3 MB ≤ 1 GB 不动；roots 不在 = 0；工作区外的 other 不碰；锁目录用完删掉
fa_reset; AW=$FA/air/work; for d in cache/unpack/a_kRun cache/unpack/b_mid cache/unpack/c_new runs/r1 other; do mk3m "$AW/$d"; done
touch -t 202601010000 $AW/cache/unpack/a_kRun; touch -t 202601020000 $AW/cache/unpack/b_mid; touch -t 202601030000 $AW/cache/unpack/c_new
o=$(S2A_AIR_CAP_UNPACK_GB=0.005 fa air_cleaner air kRun)
chk "㊶b1 air_cleaner（远端无 S2A_* 环境）：删 b_mid、c_new，留在跑款 a_kRun；runs / other 不动；锁已释放" \
  "a_kRun r1 f 无" "$(ls $AW/cache/unpack | paste -sd' ' -) $(ls $AW/runs) $(ls $AW/other) $([ -e $AW/.air_cleaner.lock ] && echo 有 || echo 无)"
chk "㊶b2 记账行：删了什么 / 各区清后与上限 / 卷剩余" "删 cache/unpack/b_mid(3M) cache/unpack/c_new(3M)；清后 cache/unpack=3M/5M runs=3M/1024M roots=0/1024M free=NG" \
  "$(printf '%s' "$o" | sed 's/free=[0-9]*G$/free=NG/')"
o=$(S2A_AIR_WORK=$FA/air/nowork fa air_cleaner air)
chk "㊶b3 工作区不在 → 说明原因、没有 free= 段（调用方按量不到处理）" "Air 工作区不在：$FA/air/nowork" "$o"
# ㊶c 缺陷 2：单实例锁（Air 没有 flock：mkdir 锁目录 + pid）
fa_reset; AW=$FA/air/work; mk3m $AW/runs/x1; mk3m $AW/runs/x2
( : ) & dp=$!; wait $dp; mkdir $AW/.air_cleaner.lock; echo $dp > $AW/.air_cleaner.lock/pid
o=$(S2A_AIR_CAP_RUNS_GB=0.004 fa air_cleaner air)
chk "㊶c1 死锁（持锁 pid 已退出）→ 收回再清；用完删锁" "收回死锁（pid ${dp}）；删 runs/x1(3M)；清后 有 无" \
  "$(printf '%s' "$o" | sed 's/；清后.*/；清后/') $([ -n "$(printf '%s' "$o" | grep 'free=[0-9]*G$')" ] && echo 有) $([ -e $AW/.air_cleaner.lock ] && echo 有 || echo 无)"
sleep 30 & lp=$!; mkdir $AW/.air_cleaner.lock; echo $lp > $AW/.air_cleaner.lock/pid; mk3m $AW/runs/x3
o=$(S2A_AIR_CAP_RUNS_GB=0.001 CENSUS_AIR_LOCK_WAIT_S=1 fa air_cleaner air)
chk "㊶c2 活锁（持锁进程在）→ 等满 1 秒仍占用：本轮不清、一个不删、锁不动" "锁占用 1 秒（pid ${lp}），本轮不清 x2 x3 $lp" \
  "$(printf '%s' "$o" | sed 's/ free=.*//') $(ls $AW/runs | paste -sd' ' -) $(cat $AW/.air_cleaner.lock/pid)"
kill $lp 2> /dev/null; wait $lp 2> /dev/null; rm -rf $AW/.air_cleaner.lock
fa_reset; AW=$FA/air/work; for d in a b c d; do mk3m $AW/runs/$d; touch -t 2026010${#d}0000 $AW/runs/$d; done
touch -t 202601010000 $AW/runs/a; touch -t 202601020000 $AW/runs/b; touch -t 202601030000 $AW/runs/c; touch -t 202601040000 $AW/runs/d
( S2A_AIR_CAP_RUNS_GB=0.007 fa air_cleaner air > $FA/c1 ) & ( S2A_AIR_CAP_RUNS_GB=0.007 fa air_cleaner air > $FA/c2 ) & wait
chk "㊶c3 两个清理器同时起：串行（12 MB 上限 7 MB → 只删 a、b 各一次，两份记账合起来不重复），都出 free=，锁已释放" "runs/a(3M) runs/b(3M) c d 2 无" \
  "$(cat $FA/c1 $FA/c2 | grep -o 'runs/[a-d]([0-9]*M)' | sort | paste -sd' ' -) $(ls $AW/runs | paste -sd' ' -) $(cat $FA/c1 $FA/c2 | grep -c 'free=[0-9]*G$') $([ -e $AW/.air_cleaner.lock ] && echo 有 || echo 无)"
# ㊶d 缺陷 3、4：Air 采样器每拍一行、无进展分钟数 = 距总表最后一条结论行（总表 mtime；早于本批开跑按开跑），批结束由主流程（真 census.sh 的 batch_end 段）停采样器、出汇总行
fa_reset; rm -rf $FA/b; mkdir -p $FA/b/running; touch $FA/b/.census_batch $FA/b/running/kRun
printf '%s\n' 52428800 31457280 41943040 > $FA/ctl/df_kb; printf '%s\n' 900 2600 1200 > $FA/ctl/swap_mb; echo 1 > $FA/ctl/level   # 盘 50 / 30 / 40 GB，交换 900 / 2600 / 1200 MB
printf 'h\n' > $FA/b/总表.tsv; touch -t "$(date -v-7M +%Y%m%d%H%M.%S)" $FA/b/总表.tsv   # 最后一条结论行 7 分钟前
mt() { ( PATH=$FA/bin:$PATH; B=$FA/b; T=$FA/b/总表.tsv; L=$FA/b/log; AIRSH=air; AIRLOCAL=1; S2A_AIR_WORK=$FA/air/work; s0=$1; CENSUS_AIR_METRICS_S=1
  log() { echo "[x] $*" >> "$L"; }; eval "$(sed -n '/^# >>> air_rsh/,/^# <<< air_metrics/p' "$CS")"
  air_metrics_sampler & AIRMETRICS=$!
  i=0; while [ "$(wc -l < $FA/b/air_metrics.tsv 2> /dev/null || echo 0)" -lt 4 ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  ( : ) & RNS=($!); ( : ) & SAMPLER=$!; ( : ) & SUMLIVE=$!
  eval "$(sed -n '/^# >>> batch_end/,/^# <<< batch_end/p' "$CS")" > /dev/null 2>&1 ) }
mt "$(date -v-60M +%s)"
chk "㊶d1 采样表：表头 + 3 行（按拍取盘 50/30/40、交换 900/2600/1200、压力 1、在跑 kRun、距最后结论 7 分钟）" \
  "time ssd_free_gb swap_used_mb mem_pressure running_keys mins_since_last_row|50 900 1 kRun 7|30 2600 1 kRun 7|40 1200 1 kRun 7" \
  "$(head -4 $FA/b/air_metrics.tsv | cut -f2- | sed 's/^ssd/time\tssd/' | tr '\t' ' ' | paste -sd'|' -)"
chk "㊶d2 批结束（真 batch_end 段）驱动日志出汇总行：盘最低 30、交换最大 2600、最长无进展 7（采样行数 ≥ 3）" "Air 指标汇总：盘最低剩余 30 GB，交换最大 2600 MB，最长无进展 7 分钟" \
  "$(grep 'Air 指标汇总' $FA/b/log | sed 's/^\[x\] //; s/（[0-9]* 行）$//')"
chk "㊶d3 汇总后采样器已停（1.5 秒内不再长行）" 停 "$(n1=$(wc -l < $FA/b/air_metrics.tsv); sleep 1.5; [ "$(wc -l < $FA/b/air_metrics.tsv)" = "$n1" ] && echo 停 || echo 还在采)"
rm -f $FA/b/air_metrics.tsv $FA/b/log; printf '%s\n' 52428800 > $FA/ctl/df_kb; touch -t "$(date -v-90M +%Y%m%d%H%M.%S)" $FA/b/总表.tsv; touch $FA/b/.census_batch
mt "$(date -v-3M +%s)"
chk "㊶d4 总表最后写入早于本批开跑（续跑批）→ 按开跑时刻算：3 分钟（不是 90、也不是采样间隔 0）" 3 "$(sed -n 2p $FA/b/air_metrics.tsv | cut -f6)"
# ㊶e 缺陷 5：内存准入按内存口径（每款 CENSUS_AIR_MEM_EST_GB 缺省 5.5），不看源大小、不看交换已用量。vm_stat 取 11-04 真 Air 空闲读数（见 vmfake）：
#   可用 = (free 430992 + inactive 169991 + spec 29447 + purg 9304) × 16 KB = 9995 MB，常驻 2733 MB，物理 16384 MB；预估 5.5 GB = 5632 MB
#   在跑 1 款：静态 16384 − 2733 − 5632×2 = 2387 ≥ 0；实时 9995 − 5632 = 4363 ≥ 1024 → 过（交换已用 2456 MB 不影响；旧版 4.5×源+14 与「交换 < 2 GB」两条都会拒）
amr() { ( mkdir -p $FA/b/running; rm -f $FA/b/running/*; for i in $(seq 1 "$2"); do echo air > $FA/b/running/k$i; done; for i in $(seq 1 "${5:-0}"); do echo local > $FA/b/running/L$i; done; echo "$3" > $FA/ctl/level; vmfake "$4"; echo 2456 > $FA/ctl/swap_mb
  out=$(fa air_mem_ok air "$1"); rc=$?; [ $rc = 0 ] && echo 过 || echo "不过:${out%%：*}" ) }
fa_reset
chk "㊶e1 第 1 道不限（压力级别 4 危急、free 0 页、在跑 3 款也过）" 过 "$(amr 1 3 4 0)"
chk "㊶e2 真 Air 空闲读数、在跑 1 款、交换已用 2456 MB → 第 2 道过" 过 "$(amr 2 1 1 430992)"
chk "㊶e3 已在跑 2 款：静态 16384 − 2733 − 5632×3 = −3245 < 0 → 不过" "不过:静态账不够" "$(amr 3 2 1 430992)"
chk "㊶e4 内核内存压力级别 2（警告）→ 不过" "不过:内存压力非正常" "$(amr 2 1 2 430992)"
chk "㊶e5 free 只剩 50000 页：可用 (50000+169991+29447+9304)×16 KB = 4042 MB − 5632 < 1024 → 不过" "不过:实时可用不够" "$(amr 2 1 1 50000)"
chk "㊶e7 本机 3 道在跑、Air 在跑 1 款：静态只数 Air 的 → 16384 − 2733 − 5632×2 = 2387 ≥ 0 → 第 2 道过（11-04 数全部 running 时 −14000 永远不过）" 过 "$(amr 2 1 1 430992 3)"
chk "㊶e8 claim：待跑 → running，内容写机器名、时间戳保持原值（退避放回后排序不变）" "air 202601020304.05 无" \
  "$(rm -rf $FA/b/running $FA/b/packed; mkdir -p $FA/b/packed; touch -t 202601020304.05 $FA/b/packed/kC; PQ=$FA/b/packed fa claim air kC; echo "$(cat $FA/b/running/kC) $(stat -f %Sm -t %Y%m%d%H%M.%S $FA/b/running/kC) $([ -e $FA/b/packed/kC ] && echo 有 || echo 无)")"
chk "㊶e6 判据原文：可用 9995 MB、常驻 2733 MB 按 16 KB 页算（不是 4 KB）" "压力级别 1，物理 16384 MB − 常驻 2733 MB − 5.5 GB ×（在跑 2 + 1）= -3245 MB；可用 9995 MB − 5.5 GB = 4363 MB" \
  "$(rm -f $FA/b/running/*; echo air > $FA/b/running/k1; echo air > $FA/b/running/k2; echo 1 > $FA/ctl/level; vmfake 430992; fa air_mem_ok air 2 | sed 's/^[^：]*：//')"
# ㊶f 缺陷 7：批停 / 结束只删本批推过去的键——Air 原件目录里有本批 kA（经真 air_push 推过去）、别批 kOther、本批跳过推送的 kSkip（远端已有同名同大小 → 不记已推）
fa_reset; rm -rf $FA/b; mkdir -p $FA/b $FA/lsrc; echo aa > $FA/lsrc/a.nsp; echo bb > $FA/lsrc/b.nsp
mkdir -p $FA/air/src/kOther $FA/air/src/kSkip; echo other > $FA/air/src/kOther/o.nsp; cp $FA/lsrc/b.nsp $FA/air/src/kSkip/
printf '#!/bin/bash\nd=${@: -1}; d=${d#*:}; n=$(($# - 1)); /bin/cp "${@:2:$((n - 1))}" "$d"\n' > $FA/bin/rsync; chmod +x $FA/bin/rsync   # 替身 rsync -a <文件…> <主机:目录/> → 本机 cp
fa air_push air kA 3 $FA/lsrc/a.nsp; fa air_push air kSkip 3 $FA/lsrc/b.nsp
chk "㊶f1 真 air_push 推 kA 后 Air 有 kA/a.nsp；已推清单只记 kA（kSkip 远端已有、不算本批推的）" "a.nsp kA" "$(ls $FA/air/src/kA) $(paste -sd, $FA/b/.air_pushed)"
fa air_src_purge air
chk "㊶f2 air_src_purge：只删本批 kA，别批 kOther 与 kSkip 留着；已推清单删掉" "kOther kSkip 无" "$(ls $FA/air/src | paste -sd' ' -) $([ -e $FA/b/.air_pushed ] && echo 有 || echo 无)"
fa air_src_delete air kOther; fa air_src_rm air '../src' '' kNope
chk "㊶f3 air_src_delete 只删点名的一款；键带 / 或为空 → 跳过不删" "kSkip" "$(ls $FA/air/src | paste -sd' ' -)"
rm -f $FA/bin/rsync
# ㊶g 缺陷 6、9：真 runner 的 Air 道——开跑前先清一轮，清后仍不够 → 记【红】Air 盘不足（总表一行未判）、删这款 Air 原件、不 sleep 重试、不调 runone；够 → 照常 runone。
#   盘需求 = disk_ok 同一预估 4.5 × 源 + 14（S2A_REMOTE_EST_R / C）+ 待推原件（runner 处原件已在 Air = 0）+ 硬闸 20：源 10 GB → 45 + 14 + 0 + 20 = 79 GB（旧版只要源 + 2 = 12）
rnr() { ( PATH=$FA/bin:$PATH; B=$FA/b; T=$FA/b/总表.tsv; L=$FA/b/log; PQ=$FA/b/packed; AIRSH=air; AIRLOCAL=1; AIRSRC=$FA/air/src
  S2A_AIR_WORK=$FA/air/work; S2A_AIR_CAP_UNPACK_GB=1; S2A_AIR_CAP_RUNS_GB=1; S2A_AIR_CAP_ROOTS_GB=1
  rm -rf "$B"; mkdir -p "$B/running" "$PQ" "$B/work/kBig" "$FA/air/src/kBig"; touch "$PQ/kBig" "$B/.pack_done"; printf '大作\tv1\t10.0\n' > "$B/work/kBig/meta"; echo "$1" > $FA/ctl/df_kb
  log() { echo "[x] $*" >> "$L"; }; bat_ok() { :; }; lane_ok() { return 0; }; disk_ok() { echo disk_ok >> $FA/calls; return 1; }
  runone() { echo "runone $2" >> $FA/calls; return 0; }; sleep() { echo "sleep $1" >> $FA/calls; }
  eval "$(sed -n '/^# >>> air_rsh/,/^# <<< air_metrics/p;/^# >>> claim/,/^# <<< claim/p' "$CS")"; eval "$(sed -n '/^runner() {/,/^}/p' "$CS")"
  runner air 1 ) > /dev/null 2>&1; }
fa_reset; rm -f $FA/calls; rnr $((78 << 20))
chk "㊶g1 Air 可用 78 < 需 79：记红跳过——不调 runone / disk_ok、0 次 sleep、待跑与在跑都空、Air 原件 kBig 已删" "无 0 0 0 无" \
  "$(cat $FA/calls 2> /dev/null | grep -c . | sed 's/^0$/无/') $(ls $FA/b/packed | wc -l | tr -d ' ') $(ls $FA/b/running | wc -l | tr -d ' ') $(grep -c '^sleep' $FA/calls 2> /dev/null || echo 0) $([ -d $FA/air/src/kBig ] && echo 有 || echo 无)"
chk "㊶g2 先清一轮（记账行在红行前）再记红；红行带需求拆账" "Air 工作区清理（kBig）：删 无；清后|【红】Air 盘不足，跳过 kBig 大作：Air 可用 78 GB / 需 79 GB（源 10.0 GB 预估峰值 59 G + 待推原件 0 G + 硬闸 20 G），已清理一轮，不等|跑局工人 air#1 结束" \
  "$(sed 's/^\[x\] //' $FA/b/log | sed 's/；清后.*/；清后/' | paste -sd'|' -)"
chk "㊶g3 总表一行：kBig 机器 air、结论未判、失败点【红】Air 盘不足（机器原因，下批重排）" "kBig air 未判 【红】Air 盘不足：Air 可用 78 GB / 需 79 GB" \
  "$(awk -F'\t' '{print $1, $4, $7, $8}' $FA/b/总表.tsv | sed 's/（源.*//')"
fa_reset; rm -f $FA/calls; rnr $((79 << 20))
chk "㊶g4 Air 可用 79 = 需 79 → 过：调 runone kBig 一次，不走 disk_ok 等盘、0 次 sleep，总表无行" "runone kBig|0|无" \
  "$(paste -sd'|' $FA/calls)|$(grep -c '^sleep' $FA/calls)|$([ -s $FA/b/总表.tsv ] && echo 有 || echo 无)"
# ㊶h 缺陷 9：真 packer 的 Air 分支（11-04 拷贝工删掉后推原件由解包工人做）推原件前同样清一轮再判，需求多算这款还没推过去的原件：源 10 GB → 45 + 14 + 10 + 20 = 89；不够不推、不等
cpa() { ( PATH=$FA/bin:$PATH; B=$FA/b; T=$FA/b/总表.tsv; L=$FA/b/log; PQ=$FA/b/packed; AIRSH=air; AIRLOCAL=1; AIRSRC=$FA/air/src; LANES=2
  S2A_AIR_WORK=$FA/air/work; S2A_AIR_CAP_UNPACK_GB=1; S2A_AIR_CAP_RUNS_GB=1; S2A_AIR_CAP_ROOTS_GB=1
  rm -rf "$B"; mkdir -p "$B/running" "$B/work" "$PQ"; echo "$1" > $FA/ctl/df_kb
  Q=$B/q; printf '键\t名\t版\t本体\t文件\t字节\tnz\tisa\nkC\t大作\tv1\tb\t/x/a.nsp\t%s\t0\tx\n' $((10 << 30)) > "$Q"
  log() { echo "[x] $*" >> "$L"; }; bat_ok() { :; }; sleep() { echo "sleep $1" >> $FA/calls; }; air_push() { echo "push $2" >> $FA/calls; return 0; }
  eval "$(sed -n '/^# >>> work_rm/,/^# <<< work_rm/p;/^# >>> air_rsh/,/^# <<< air_metrics/p;/^# >>> packer/,/^# <<< packer/p' "$CS")"
  packer 1 ) > /dev/null 2>&1; }
fa_reset; rm -f $FA/calls; cpa $((88 << 20))
chk "㊶h1 解包工人 Air 可用 88 < 需 89：不推、0 次 sleep、待跑空，记红（需求含待推原件 10 G）" "无 0 1" \
  "$([ -s $FA/calls ] && paste -sd, $FA/calls || echo 无) $(ls $FA/b/packed | wc -l | tr -d ' ') $(grep -c '【红】Air 盘不足，跳过 kC 大作：Air 可用 88 GB / 需 89 GB（源 10.0 GB 预估峰值 59 G + 待推原件 10.0 G + 硬闸 20 G）' $FA/b/log)"
fa_reset; rm -f $FA/calls; cpa $((89 << 20))
chk "㊶h2 解包工人 Air 可用 89 = 需 89 → 推 kC、进待跑、写 meta" "push kC kC 大作" "$(paste -sd, $FA/calls) $(ls $FA/b/packed) $(cut -f1 $FA/b/work/kC/meta 2> /dev/null)"
# ㊶i 缺陷 8：Air 原件目录接 layout.env（S2A_AIR_SRC），CENSUS_AIR_SRC 显式给优先；CENSUS_AIR_LOCAL=1 缺键报红退出 2（抽真 census.sh 的 air_conf 段）
acf() { ( env -i PATH=/usr/bin:/bin "$@" bash -c 'eval "$(sed -n "/^# >>> air_conf/,/^# <<< air_conf/p" "$0")"; echo "rc=0 $AIRSRC"' "$CS" 2>&1 | sed 's/（source.*//' ) }
AK="S2A_AIR_WORK=/w S2A_AIR_CAP_GB=420 S2A_AIR_CAP_UNPACK_GB=200 S2A_AIR_CAP_RUNS_GB=150 S2A_AIR_CAP_ROOTS_GB=70"
chk "㊶i1 只给 layout.env 的 S2A_AIR_SRC → AIRSRC 取它" "rc=0 /lay/src" "$(acf CENSUS_AIR_LOCAL=1 S2A_AIR_SRC=/lay/src $AK)"
chk "㊶i2 CENSUS_AIR_SRC 显式给 → 优先" "rc=0 /cli/src" "$(acf CENSUS_AIR_LOCAL=1 CENSUS_AIR_SRC=/cli/src S2A_AIR_SRC=/lay/src $AK)"
chk "㊶i3 两个都没给 → 报红退出（不往下跑）" "🔴 CENSUS_AIR_LOCAL=1 但没有 Air 原件目录：CENSUS_AIR_SRC 和 layout.env 的 S2A_AIR_SRC 都没给" "$(acf CENSUS_AIR_LOCAL=1 $AK)"
chk "㊶i4 缺 S2A_AIR_CAP_RUNS_GB → 报红点名缺的键" "🔴 CENSUS_AIR_LOCAL=1 但 layout.env 缺键 S2A_AIR_CAP_RUNS_GB" "$(acf CENSUS_AIR_LOCAL=1 S2A_AIR_SRC=/s S2A_AIR_WORK=/w S2A_AIR_CAP_GB=1 S2A_AIR_CAP_UNPACK_GB=1 S2A_AIR_CAP_ROOTS_GB=1)"
chk "㊶i5 CENSUS_AIR_LOCAL 不是 1 → 不校验" "rc=0 " "$(acf CENSUS_AIR_LOCAL=0)"

# ㊶j 接线：纯 air 批才开本地化；packer 里 air_push 失败 → continue、推完即放行；runone 不再 --sync 解包目录、源给 Air 2T 原件目录、exefs 取自日志目录
e1=$(grep -c '\[ "\$HOSTS" = air \] || AIRLOCAL=0' "$R/tools/census/census.sh" || true)
e2=$(grep -c 'if ! air_push' "$R/tools/census/census.sh" || true)
e3=$(grep -c '放行 \$k \${nm}（Air 本地解包）' "$R/tools/census/census.sh" || true)
e4=$(grep -c 'echo "\$AIRSRC/\$k"' "$R/tools/census/census.sh" || true)
e5=$(grep -c 'EXD=\$W/r/logs/\$k/exefs' "$R/tools/census/census.sh" || true)
chk "㊶j 接线：纯 air 才开本地化 / air_push 失败 continue / 认领即放行 / 源给 Air 原件目录 / exefs 取自日志" \
  "有 有 有 有 有" \
  "$([ "$e1" -ge 1 ] && echo 有 || echo 无) $([ "$e2" -ge 1 ] && echo 有 || echo 无) $([ "$e3" -ge 1 ] && echo 有 || echo 无) $([ "$e4" -ge 1 ] && echo 有 || echo 无) $([ "$e5" -ge 1 ] && echo 有 || echo 无)"



chk "㊳ 接线：设 CENSUS_REMOTE_SLOT_RUN 时远端每道 one_game 套 S2A_SLOT_RUN + 槽数 1（Air 16 GB，出包段串行、跑局并行）；不设无此环境变量" "有 有" "$(grep -q 'CENSUS_REMOTE_SLOT_RUN:+S2A_SLOT_RUN=.*S2A_SLOTS=1' "$R/tools/census/census.sh" && echo 有) $(grep -c 'CENSUS_REMOTE_SLOT_RUN:+' "$R/tools/census/census.sh" | grep -qx 1 && echo 有)"
# ㊺ 按资料盘索引表取原件（11-04 jhz：只查表、不扫目录）：src_files("@表") 取路径列，sha256 为「-」的整目录行与非原件后缀不算；期望手写
IX=$T/ix45; mkdir -p $IX/other; printf '程序号\t款名\t版本\t角色\t路径\t字节\tsha256\n0100A\t甲\t1.0\t本体\t/lib/0100A/a.xci\t5\tab\n0100A\t甲\t1.1\t更新\t/x/0100A/b.nsp\t3\tcd\nSW2_X\t乙\t-\tNS2目录\t/lib/SW2_X\t9\t-\n0100B\t丙\t-\t?\t/lib/0100B/readme.txt\t1\tef\n' > $IX/index.tsv
touch $IX/other/c.nsz
got=$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1] + "/tools/census"); import census; print(census.src_files("@" + sys.argv[2]), [p.split("/")[-1] for p in census.src_files(sys.argv[3])])' "$R" $IX/index.tsv $IX/other)
chk "㊺ 索引表取两行原件（目录行、非原件后缀不算）；给目录照旧列一层" "['/lib/0100A/a.xci', '/x/0100A/b.nsp'] ['c.nsz']" "$got"
chk "㊺b 接线：census.sh 不给 --src 时用 @ 加索引表变量、不再扫 library/*/" "有 无" "$(grep -q 'SRC=@$S2A_LIBRARY_INDEX' "$R/tools/census/census.sh" && echo 有) $(grep -q '"$S2A_LIBRARY"/\*/' "$R/tools/census/census.sh" && echo 有 || echo 无)"
# ㊻ 跑局道静默等待要出声 + 批次停摆报红（11-04 压测：暂停旗遗留 45 分钟 0 行没人报）：期望手写
RW6=$T/rw46; mkdir -p $RW6; L=$RW6/批次.log; : > $L
( log() { echo "$*" >> "$L"; }; eval "$(sed -n '/^# >>> runner_wait/,/^# <<< runner_wait/p' "$R/tools/census/census.sh")"
  f=$RW6/st; rwait $f 原因甲; rwait $f 原因甲; CENSUS_WAIT_RED_S=0 rwait $f 原因甲; CENSUS_WAIT_RED_S=0 rwait $f 原因甲; rwait $f 原因乙; rwait_end $f; rwait_end $f )
chk "㊻a 进等待写黄、同因不重复、满时限红一次、换因再黄、领到款写一行并清状态、没等过静默" "1 1 1 1 1 无" "$(grep -c '【黄】跑局道等待：原因甲' $L) $(grep -c '【红】跑局道已等' $L) $(grep -c '【黄】跑局道等待：原因乙' $L) $(grep -c '不再等待（原因：原因乙' $L) $(grep -c 不再等待 $L) $([ -e $RW6/st ] && echo 有 || echo 无)"
SB=$RW6/b; mkdir -p $SB/running $SB/pq $SB/seen/kA $SB/seen/kB $SB/seen/kC $SB/work/kA; touch $SB/pq/kB $SB/.census_batch; printf 'x\n[天眼道] 排队：要 24 GB\n' > $SB/work/kA/pack.out; printf '键\nkC\t名\n' > $SB/总表.tsv; L2=$SB/批次.log; echo 旧行 > $L2; touch -t 202601010000 $L2; printf '0\t本机 1 道：暂停旗 x 在\t0\n' > $SB/.rwait.local.1
( B=$SB; L=$L2; PQ=$SB/pq; T=$SB/总表.tsv; log() { echo "$*" >> "$L"; }; eval "$(sed -n '/^# >>> stall_watch/,/^# <<< stall_watch/p' "$R/tools/census/census.sh")"
  CENSUS_STALL_EVERY_S=1 CENSUS_STALL_RED_S=60 stall_watch & p=$!; sleep 2.5; rm -f $SB/.census_batch; sleep 1.2; kill $p 2> /dev/null; wait $p 2> /dev/null )
chk "㊻b 批次日志 60 秒没新行 → 写一行红、带等待原因；写红后不再连报" "1 1" "$(grep -c '【红】批次 1 分钟没有新行' $L2) $(grep -c '跑局道在等：本机 1 道：暂停旗 x 在' $L2)"
# ㊻e 停摆红行带出包中的款（11-05 ty12 看似空转、实为两单在天眼）：kA 领过、不在待跑 / 在跑 / 总表 → 算出包中、带日志末行；kB 在待跑、kC 已有总表行 → 不算。期望手写
chk "㊻e 停摆红行列出出包中的款与日志末行，待跑 / 已出结论的不算" "1" "$(grep -c '出包中 1 款：kA（\[天眼道\] 排队：要 24 GB）；' $L2)"
PZ=$RW6/pause; L=$RW6/p.log; : > $L
pz() { ( log() { echo "$*" >> "$L"; }; S2A_CENSUS_LOCAL_PAUSE=$PZ; eval "$(sed -n '/^# >>> runner_wait/,/^# <<< runner_wait/p' "$R/tools/census/census.sh")"; local_paused && echo 停 || echo 走 ); }
sleep 30 & SP=$!; echo $SP > $PZ; a=$(pz); kill $SP; wait $SP 2> /dev/null; b=$(pz); c=$([ -e $PZ ] && echo 有 || echo 无); : > $PZ; d=$(pz); e=$(pz)
chk "㊻d 暂停旗有主才算数：主人活着停、主人退出走且删旗写红、空旗走且删旗、没旗走" "停 走 无 走 走 2" "$a $b $c $d $e $(grep -c '【红】本机暂停旗' $L)"
chk "㊻c 接线：本机暂停旗 / 机器槽 / 负载三处等待都调 rwait，领款前 rwait_end，批末停 stall_watch" "3 1 1" "$(grep -c 'rwait "$RW" "本机' "$R/tools/census/census.sh") $(grep -c '^    rwait_end "$RW"' "$R/tools/census/census.sh") $(grep -c 'kill "$SUMLIVE" "${STALLW:-}"' "$R/tools/census/census.sh")"
bash -n "$R/tools/census/census.sh" || { echo "🔴 census.sh 语法错"; bad=1; }
# ㊷ 每个批次自成会话组（11-02 本机路和 Air 路同组，杀一路连带停另一路）：抽出 census.sh 开头那段 setsid 重新执行，放进临时脚本，从「非组长」的后台子 shell 起它，
#   期望手写：脚本里的 pid 等于它的进程组号（自己是组长）、不等于起它的父 shell 的进程组号；已设 CENSUS_OWN_SESSION 时不再重新执行（防循环）
OS=$T/ownsession; mkdir -p "$OS"
{ echo '#!/bin/bash'; echo 'set -u'; sed -n '/^# 自成一个会话组/,/^  CENSUS_OWN_SESSION=1 exec/p' "$R/tools/census/census.sh" | sed '$ s/; fi$//'; echo 'fi'; echo 'echo "$$ $(ps -o pgid= -p $$ | tr -d " ")" > '"$OS"'/out'; } > "$OS/t.sh"
( bash "$OS/t.sh" & wait ) ; read -r op og < "$OS/out" 2> /dev/null
pg_parent=$(ps -o pgid= -p $$ | tr -d ' ')
chk "㊷a 非组长起的 census 脚本重新执行后自己是组长（pid=pgid）且不在父 shell 的组里" "是 是" "$([ "$op" = "$og" ] && echo 是 || echo "否(${op}/${og})") $([ "$og" != "$pg_parent" ] && echo 是 || echo 否)"
chk "㊷b 接线：census.sh 真有这段（CENSUS_OWN_SESSION + setsid）" "有 有" "$(grep -q 'CENSUS_OWN_SESSION:-' "$R/tools/census/census.sh" && echo 有) $(grep -q 'os.setsid()' "$R/tools/census/census.sh" && echo 有)"
# ㊸ 同一个包里有两个本体（索尼克×夏特 世代重启 的 xci 里还带「艺术集&原声集」一个 500 MB 的小应用）：解包按程序号取，不让它判「本体应恰好 1 款，实际 0 款」
#   接线：本机解包工人那行（QT_UNPACK_ONLY=1）与 Air 本地解包那行都带 QT_TITLE_ID=$k
chk "㊸ census.sh 解包两处（本机出包工人 QT_PACK_ONLY / Air 本地）都带 QT_TITLE_ID=\$k" "1 1" "$(grep 'QT_PACK_ONLY=1' "$R/tools/census/census.sh" | grep -c 'QT_TITLE_ID=\$k') $(grep 'QT_KEEP_EXEFS=\$AIRLOCAL' "$R/tools/census/census.sh" | grep -c 'QT_TITLE_ID=\$k')"
# ㊿ 原生档（11-02 jhz：局内失败 / 不崩没出图的款能力全关再跑一局，分清游戏本身跑不起来还是满屏 / 60 帧弄坏的）。期望手算：
#   a) row 读 logs/<键>/.原生档 → 「结论｜失败点｜首帧 X｜进局 Y」；没这个文件 → -
#   b) 主数字 16:9 原生档三率：4 款——P 主局通过出图进局（原生档 -）；Q 主局崩溃、原生档通过出图未进局；R 出包失败（原生档 -）；S 主局没出图、原生档也失败
#      出包成功 = P Q S = 3/4；不崩出画面 = P、Q（原生档通过且首帧是）= 2/4；进局 = P = 1/4；跑过原生档 2 款
NT=$T/nt; mkdir -p "$NT/logs/0100000000CCC000" "$NT/b"
printf "$H"'s\tcc\t0100000000CCC000\t失败\t稳定崩溃：客体代码\t0\t120\t300\t是\t900\t17000\t直连\t否\t是\t-\t否\n' > "$NT/结果.tsv"
printf '通过\t-\t是\t否\n' > "$NT/logs/0100000000CCC000/.原生档"
chk "㊿a row 读 .原生档" "通过｜-｜首帧 是｜进局 否" "$($C row 0100000000CCC000 Cc 1.0 local 1.0 "$NT/结果.tsv" 10 | awk -F'\t' '{print $(NF-4)}')"
rm "$NT/logs/0100000000CCC000/.原生档"
chk "㊿a 没跑原生档 → -" "-" "$($C row 0100000000CCC000 Cc 1.0 local 1.0 "$NT/结果.tsv" 10 | awk -F'\t' '{print $(NF-4)}')"
"$PY" - "$R" "$NT/b/总表.tsv" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census as c
def r(k, n, con, fp, first, ent, nt): d = {h: '-' for h in c.TH}; d.update({'键': k, '名称': n, '结论': con, '第一个失败点': fp, '首帧': first, '进局': ent, 'Mac局秒': '300', '原生档': nt}); return d
c.write_tsv(sys.argv[2], c.TH, [r('P', 'P', '通过', '-', '是', '是', '-'), r('Q', 'Q', '失败', '稳定崩溃：客体代码', '是', '否', '通过｜-｜首帧 是｜进局 否'),
                                r('R', 'R', '失败', '出包：改写', '-', '-', '-'), r('S', 'S', '通过', '-', '否', '否', '失败｜首帧｜首帧 否｜进局 否')])
PYEOF
$C sum "$NT/b" > /dev/null 2>&1
chk "㊿b 汇总主数字 = 一次成功率 + 三率（夹具没有不卡读数 → 一次成功 0，P 进了局但无帧读数 = 未判）" "一次成功（主数字：原生帧率 + 16:9，出包 / 进局 / 不崩 / 不卡死四件全过）①自动判定 0/4（0.0%） ｜②并入手测 0/4（0.0%）（待手测里已手测 0 款过 0，未测 1 款） ｜③扣除测试存档错配 / 普查环境 / 判据误判后 0/4（0.0%）（扣 0 款） ｜已修待复判 0 款 ｜出包成功 3/4（75.0%） ｜进局（自动 + 手测）1/4（25.0%） ｜不崩不卡死 0/4（0.0%） ｜补丁包修复 0 款（主局没一次成功、带补丁那局过，不计入一次成功）" "$(grep -o '一次成功（主数字[^*]*' "$NT/b/汇总.md")"
OG=$(sed -n '/原生档（11-02 jhz/,/^    fi$/p' "$R/tools/quicktest/one_game.sh")
chk "㊿c 接线：one_game 原生档只在 QT_NATIVE_TIER=1 且（失败或首帧没出）时跑，能力全关（60 帧关 / 满屏关 / 不做 A/B），写 .原生档；census.sh 三处（本机出包工人 / 本机道 / 远端道）都带 QT_NATIVE_TIER" "有 有 有 3" "$(grep -q 'QT_NATIVE_TIER:-0}" = 1' <<< "$OG" && echo 有) $(grep -q 'S2A_FPS60=0 S2A_WIDEN_CAPS=0 S2A_WIDEN_VERIFIED=0' <<< "$OG" && grep -q -- '-u S2A_FPS_AB' <<< "$OG" && echo 有) $(grep -q '\.原生档' <<< "$OG" && echo 有) $(grep -c 'QT_NATIVE_TIER=\${CENSUS_NATIVE_TIER:-1}' "$R/tools/census/census.sh")"

# 51 本机直连缓存淘汰放后台（11-02：前台全量 os.walk 在 2T 上一次 13 分钟，跑局道起局前被卡死）：接线——本次款前台先记 .used，dcache_gc 在后台子 shell 里跑、输出不进 run.out
RO=$(sed -n '/^runone() {/,/^}/p' "$R/tools/census/census.sh")
chk "51 接线：本机直连缓存淘汰后台跑、本次款先记用过" "有 有 无" "$(grep -q 'touch "$DCACHE/$k/.used"' <<< "$RO" && echo 有) $(grep -q '( "$PY" "$R/tools/census/dcache_gc.py".*& )' <<< "$RO" && echo 有) $(grep -q 'dcache_gc.py" "$DCACHE".*>> "$W/run.out"' <<< "$RO" && echo 有 || echo 无)"

# ㊹ 汇总.md 跟着跑（原先只在批次结束重算）：接线——census.sh 起 sum_live 后台循环、按 CENSUS_SUM_EVERY_S 调 census.py sum，批次结束时一并停
chk "㊹ census.sh 有 sum_live 循环（调 census.py sum）并在结束时 kill" "有 有 有" "$(grep -q '^sum_live() {' "$R/tools/census/census.sh" && grep -q 'CENSUS_SUM_EVERY_S' "$R/tools/census/census.sh" && echo 有) $(grep -q 'sum_live & SUMLIVE=' "$R/tools/census/census.sh" && echo 有) $(grep -q 'kill "$SUMLIVE" "${STALLW:-}"' "$R/tools/census/census.sh" && echo 有)"
# 52 远端局只拉回日志与结果表（11-02 Air 批：超墙钟 124 时整份 r/ 拉回，连 one_game 没来得及清的 r/work 22~34 GB 落本机、入表后没人清）：
#   期望按规则手写——真 remote.sh 本机模拟远端，命令写 r/work/大文件 + r/logs/<键>/host.log + r/结果.tsv 后睡过墙钟 → rc 124；本机只有 logs 与结果表，没有 r/work
PL=$T/pl52; mkdir -p $PL/home $PL/repo/tools; mkdir -p $PL/home/.s2arm/run/s2arm/bin; echo '# 测试用局槽仲裁副本' > $PL/home/.s2arm/run/s2arm/bin/mac_slot-now.sh; cp "$R/tools/remote.sh" "$R/tools/idle_timeout.sh" "$R/tools/safe_killpg.sh" "$R/tools/disk_low.sh" $PL/repo/tools/
( cd $PL/repo && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm 1 )
REL=.s2arm/run/s2arm/census/b52; k=K52; W=$PL/local/work/$k; eval "$(sed -n '/^# >>> pulls/,/^# <<< pulls/p' "$R/tools/census/census.sh")"
( cd $PL/repo && S2A_REMOTE=local S2A_REMOTE_ROOT=$PL/rr S2A_REMOTE_LOGS=$PL/logs S2A_REMOTE_FREE_GB=999 HOME=$PL/home bash tools/remote.sh --name t52 --timeout 3 "${PULLS[@]}" -- \
  bash -c "D=\$HOME/$REL/work/$k/r; mkdir -p \$D/work/$k/extract \$D/logs/$k; echo big > \$D/work/$k/extract/f; echo h > \$D/logs/$k/host.log; printf '源\\t款\\n' > \$D/结果.tsv; sleep 30" > /dev/null 2>&1 ); r52=$?
chk "52 超墙钟 124：本机有 r/logs/<键>/host.log 与 r/结果.tsv、没有 r/work" "124 有 有 无" "$r52 $([ -f $W/r/logs/$k/host.log ] && echo 有) $([ -f $W/r/结果.tsv ] && echo 有) $([ -e $W/r/work ] && echo 有 || echo 无)"

# 53 只跑原生档（11-02 15:5x jhz）与手测（期望按规则手写）：
#   a) CENSUS_NATIVE_ONLY=1：FAB = 三项能力关 + 照挂同局 A/B（11-04 总指挥：原生档主局补逻辑速度证据；A/B 段帧判据剔除，tools/ab_span.py），CENSUS_FPS_AB=0 才不带；屏宽 1920；不再补跑原生档（CENSUS_NATIVE_TIER=0）；不设时照旧 A/B + 2346
#   b) manual_queue：出包成功且进局 否 → 进队列；出包失败、进局 是 → 不进；同键再来不重复；进局 未判 → 进 → 表头 + 2 行
#   c) 手测结果.tsv 把 Q（自动判 否）记 是 → 主数字进局 1/4 → 2/4
NO=$(grep -E '^(FAB=; |\[ "\$\{CENSUS_NATIVE_ONLY|SW=)' "$R/tools/census/census.sh")
chk "53a 原生档开关：开 / 不开" "S2A_FPS60=0 S2A_WIDEN_CAPS=0 S2A_WIDEN_VERIFIED=0 S2A_AP_SPEED=ab S2A_FPS_AB=1|1920|0 ‖ S2A_AP_SPEED=ab S2A_FPS_AB=1|2346|" "$(CENSUS_NATIVE_ONLY=1 bash -c "$NO"$'\n''echo "$FAB|$SW|$CENSUS_NATIVE_TIER"') ‖ $(unset CENSUS_NATIVE_ONLY CENSUS_NATIVE_TIER; bash -c "$NO"$'\n''echo "$FAB|$SW|${CENSUS_NATIVE_TIER:-}"')"   # SW 那行带行尾注释，用换行接
chk "53a2 原生档 + CENSUS_FPS_AB=0 → 不带 A/B" "S2A_FPS60=0 S2A_WIDEN_CAPS=0 S2A_WIDEN_VERIFIED=0" "$(CENSUS_NATIVE_ONLY=1 CENSUS_FPS_AB=0 bash -c "$NO"$'\n''echo "$FAB"')"
MQ=$T/mq; mkdir -p $MQ
OUT53=$("$PY" - "$R" "$MQ" <<'PYEOF'
import sys, os; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census as c
d = sys.argv[2]; T = os.path.join(d, '总表.tsv'); Q = os.path.join(d, '队列.tsv'); n = []
def add(k, con, fp, ent):
    rows = c.tsv(T) if os.path.exists(T) else []
    x = {h: '-' for h in c.TH}; x.update({'键': k, '名称': k, '结论': con, '第一个失败点': fp, '进局': ent}); c.write_tsv(T, c.TH, rows + [x])
    n.append(c.manual_queue(T, Q, 'b53', 'abc1234'))
add('A', '通过', '-', '否'); add('B', '失败', '出包：改写', '-'); add('C', '通过', '-', '是'); add('A', '通过', '-', '否'); add('D', '失败', '稳定崩溃：客体代码', '未判')
print(' '.join(map(str, n)), len(open(Q).read().splitlines()), ','.join(r['键'] for r in c.tsv(Q)))
PYEOF
)
chk "53b 手测队列：追加 1 0 0 0 1，表头 + 2 行（A、D）" "1 0 0 0 1 3 A,D" "$OUT53"
printf '键\t手测\t备注\nQ\t是\tjhz 手玩进了\n' > "$NT/手测结果.tsv"; $C sum "$NT/b" > /dev/null 2>&1
printf '键\t原因\t备注\nR\t测试存档错配\t-\n' > "$NT/一次成功扣除.tsv"; $C sum "$NT/b" > /dev/null 2>&1
chk "53e 扣除表：R（出包失败、一次成功否）记测试存档错配 → 第三个分母 4 → 3" "③扣除测试存档错配 / 普查环境 / 判据误判后 0/3（0.0%）（扣 1 款）" "$(grep -o '③扣除测试存档错配 / 普查环境 / 判据误判后 [0-9/]*（[0-9.]*%）（扣 [0-9]* 款）' "$NT/b/汇总.md" | head -1)"
chk "53c 手测结果并入：Q 手测 是 → 进局 2/4" "进局（自动 + 手测）2/4（50.0%）" "$(grep -o '进局（自动 + 手测）[0-9]*/[0-9]*（[0-9.]*%）' "$NT/b/汇总.md" | head -1)"
# 53f 主数字三个 + 已修待复判（11-02 总指挥）：S 自动待手测、手测 是 → 已手测 1 款过 1、未测 0 款；R 登记已修待复判 → 单列 1 款（R）。期望手写
printf '键\t手测\t备注\nQ\t是\tjhz 手玩进了\nS\t是\t-\n' > "$NT/手测结果.tsv"; printf '键\t修复\t备注\nR\tabc1234\t-\n' > "$NT/已修待复判.tsv"; $C sum "$NT/b" > /dev/null 2>&1
chk "53f 主数字三个：②里已手测 1 款过 1、未测 0 款；已修待复判 1 款（R）" "（待手测里已手测 1 款过 1，未测 0 款） 已修待复判 1 款（R）" "$(grep -o '（待手测里已手测 [0-9]* 款过 [0-9]*，未测 [0-9]* 款）' "$NT/b/汇总.md" | head -1) $(grep -o '已修待复判 [0-9]* 款（[^）]*）' "$NT/b/汇总.md" | head -1)"
# 54 卡顿读数（11-03 jhz：只记不判，期望按口径手写：锁 60 → T = 16.7 ms，卡顿 = 帧时间 > 33.3 ms）
#   a) 1000 帧：990 帧 16667 µs + 10 帧 40000 µs → 卡顿 1.0%、最长 40 ms；b) 再加 1 帧 600000 µs → 11/1001 = 卡顿 1.1%、最长 600 ms（旧口径「不过」，现只是读数）
#   c) 锁 30（交换间隔 2）：1000 帧 33333 µs → 卡顿 0.0%；c2) 锁 60 实测稳定约 30 帧（中位 38000 → 实测 26）；c3) 锁 60 整局约 12.6 帧（中位 79500 → 实测 13）
SM=$T/sm54; OUT54=$("$PY" - "$R" "$SM" <<'PYEOF'
import sys, os; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census as c
d = sys.argv[2]
def mk(name, n, frames):
    lg = os.path.join(d, name); os.makedirs(lg, exist_ok=True)
    open(os.path.join(lg, 'host.log'), 'w').write(f'[gal] 帧节拍：交换间隔 {n}，每帧 {16.7 * n:.1f} ms（{60 / n:.1f} 帧/秒）\n')
    with open(os.path.join(lg, 'frames.tsv'), 'w') as f:
        f.write('frame\twall_us\tdisp_us\n'); [f.write(f'{i + 1}\t{w}\t\n') for i, w in enumerate(frames)]
    return c.smooth(lg)
print(' ‖ '.join([mk('a', 1, [16667] * 990 + [40000] * 10), mk('b', 1, [16667] * 990 + [40000] * 10 + [600000]), mk('c', 2, [33333] * 1000),
                  mk('d', 1, [33333, 38000] * 500), mk('e', 1, [79500] * 1000)]))
PYEOF
)
chk "54 卡顿读数（不带过 / 不过）" "卡顿 1.0%｜最长 40 ms｜锁 60｜实测 60 ‖ 卡顿 1.1%｜最长 600 ms｜锁 60｜实测 60 ‖ 卡顿 0.0%｜最长 33 ms｜锁 30｜实测 30 ‖ 卡顿 0.0%｜最长 38 ms｜锁 60｜实测 26 ‖ 卡顿 0.0%｜最长 80 ms｜锁 60｜实测 13" "$OUT54"
# 55 卡死（帧进度停住到收局 ≥ 60 秒；期望手算）：首帧上屏前时间戳 1.000 s，帧 1 间隔 0、其余 999 帧 × 100 ms → 最后一帧 100.9 s
#   a) 收局时间戳 300.000 → 到收局 199.1 秒 → 卡死；b) 101.500 → 0.6 秒 → 未卡死；c) 159.900 → 59.0 秒 → 未卡死；d) 161.900 → 61.0 秒 → 卡死
#   e) 宿主收不了局、墙钟杀（「超墙钟 330 秒没收局」，最后时间戳仍 1.000）→ 229.1 秒 → 卡死；f) 局中一帧 62 秒后又照常出帧、收局紧随 → 未卡死（慢不是卡死）
#   g) 没有 frames.tsv → '-'；没有帧节拍行 → 只记卡死与否
HG=$T/hg55; OUT55=$("$PY" - "$R" "$HG" <<'PYEOF'
import sys, os; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census as c
d = sys.argv[2]
def mk(name, tail_lines, frames=None):
    lg = os.path.join(d, name); os.makedirs(lg, exist_ok=True)
    open(os.path.join(lg, 'host.log'), 'w').write('00:00:01.000 |I| ServiceNv SetNvMapFd\n[起局] nnMain → 首帧上屏（游戏自身加载 + 渲染器首帧） +900.0 ms（本段 1.0 ms）\n' + tail_lines)
    if frames is not None:
        with open(os.path.join(lg, 'frames.tsv'), 'w') as f:
            f.write('frame\twall_us\tdisp_us\n'); [f.write(f'{i + 1}\t{w}\t\n') for i, w in enumerate(frames)]
    return c.stall_cell(lg)
F = [0] + [100000] * 999
print(' ‖ '.join([mk('a', '00:05:00.000 |W| ServiceNv Close: Closing channel\n', F), mk('b', '00:01:41.500 |W| ServiceNv Close: Closing channel\n', F),
                  mk('c', '00:02:39.900 |W| x\n', F), mk('d', '00:02:41.900 |W| x\n', F), mk('e', '【红】超墙钟 330 秒没收局\n', F),
                  mk('f', '00:02:44.000 |W| x\n', [0] + [100000] * 499 + [62000000] + [100000] * 499), mk('g', '00:05:00.000 |W| x\n')]))
PYEOF
)
chk "55 卡死按帧进度判" "卡死｜第 1000 帧后 199 秒到收局无新帧 ‖ 未卡死 ‖ 未卡死 ‖ 卡死｜第 1000 帧后 61 秒到收局无新帧 ‖ 卡死｜第 1000 帧后 229 秒到收局无新帧 ‖ 未卡死 ‖ -" "$OUT55"
# 56 一次成功 = 出包 + 进局 + 不崩 + 不卡死（11-03 jhz：卡顿 / 帧率 / 负载不进过不过，期望按口径手写）：
#   未卡死 → 是；进局否 → 待手测；进局否 + 手测是 → 是；手测否 → 否；卡死 → 否；结论失败 → 否；出包失败 → 否；没帧读数 → 未判；
#   旧口径行「不过｜卡顿 2.7%…」（卡顿不进判据）→ 是；旧「作废（并跑 4 道）｜不过…」（不再作废）→ 是
OUT56=$("$PY" - "$R" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1] + '/tools/census'); import census as c
o = lambda **k: c.one_shot({'结论': '通过', '第一个失败点': '-', '进局': '是', '手测': '-', '不卡': '未卡死｜卡顿 9.0%｜最长 742 ms｜锁 60｜实测 20'} | k)
print(o(), o(进局='否'), o(进局='否', 手测='是'), o(进局='否', 手测='否'), o(不卡='卡死｜第 296 帧后 94 秒到收局无新帧'), o(结论='失败'), o(第一个失败点='出包：改写'), o(不卡='-'),
      o(不卡='不过｜卡顿 2.7%｜最长 108 ms｜锁 60'), o(不卡='作废（并跑 4 道）｜不过｜卡顿 2.7%｜最长 108 ms｜锁 60'))
PYEOF
)
chk "56 一次成功不看卡顿 / 负载" "是 待手测 是 否 否 否 否 未判 是 是" "$OUT56"
# 57 补丁包修复（11-03 总指挥：补丁修复不计入一次成功，另列；激战前锋复判局没给 S2A_PATCH_DIR、[data] 没装）。期望按口径手写：
#   a) 总表最后一列是「补丁包修复」；b) 没给 CENSUS_PATCH_RES → '-'；c) 给了补丁局结果（失败、客体崩溃）→「否｜稳定崩溃：客体代码（main+0x10）」，一次成功列仍按主局
#   patch_run.sh（单款流水线换成记参数的替身）：d) 没设补丁根 → 不跑；e) 补丁根下没有这款 → 不跑；f) 有补丁、主局没一次成功 → 跑一次，S2A_PATCH_DIR = 补丁根、
#   QT_NATIVE_TIER=0、源同主局、输出 = 主局目录_patch；g) 主局一次成功（判断替身打「是」）→ 不跑
PT=$T/pt57; mkdir -p "$PT/patches/0100000000AAA000" "$PT/r"; touch "$PT/patches/0100000000AAA000/patch.tsv"
printf "$H"'s\talpha\t0100000000AAA000\t失败\t稳定崩溃：客体代码（main+0x10）\t0\t120\t300\t是\t900\t17000\t直连\t否\t是\t-\t否\n' > "$PT/rp.tsv"
cp "$T/r.tsv" "$PT/r/结果.tsv"
chk "57a 总表最后一列 = 补丁包修复" "补丁包修复" "$("$PY" -c "import sys; sys.path.insert(0, '$R/tools/census'); import census; print(census.TH[-1])")"
chk "57b 没给补丁局结果 → -" "-" "$($C row 0100000000AAA000 Alpha 1.2.0 local 0.0 "$T/r.tsv" 95 | awk -F'\t' '{print $NF}')"
chk "57c 补丁局失败 → 否｜失败点；一次成功列仍按主局" "否｜稳定崩溃：客体代码（main+0x10） 未判" "$(CENSUS_PATCH_RES="$PT/rp.tsv" $C row 0100000000AAA000 Alpha 1.2.0 local 0.0 "$T/r.tsv" 95 | awk -F'\t' '{print $NF, $(NF-1)}')"
cat > "$PT/og.sh" <<'OGEOF'
echo "$S2A_PATCH_DIR|$QT_NATIVE_TIER|$1|$2" >> "$OG_LOG"
OGEOF
pr() { rm -f "$PT/og.log"; OG_LOG="$PT/og.log" CENSUS_ONE_GAME="$PT/og.sh" "$@" bash "$R/tools/census/patch_run.sh" "$PT/src" "$PT/r" 0100000000AAA000 > /dev/null; cat "$PT/og.log" 2> /dev/null | tr '\n' ' '; }
chk "57d 没设补丁根 → 不跑" "" "$(pr env -u CENSUS_PATCH_DIR)"
chk "57e 补丁根下没有这款 → 不跑" "" "$(pr env CENSUS_PATCH_DIR="$PT/none")"
chk "57f 有补丁、主局没一次成功 → 带补丁根跑一局到 r_patch" "$PT/patches|0|$PT/src|$PT/r_patch " "$(pr env CENSUS_PATCH_DIR="$PT/patches")"
printf '#!/bin/bash\necho 是\n' > "$PT/py_yes"; chmod +x "$PT/py_yes"
chk "57g 主局已一次成功 → 不跑" "" "$(pr env CENSUS_PATCH_DIR="$PT/patches" PY="$PT/py_yes")"
# ㊵ _wait_helpers：首次黄行、每 10 分钟一次、超 CENSUS_WAIT_RED_S 报红并调钩子；恢复写「盘已够」。从 census.sh 按标记抽段测真实现
#   wrun <census.sh>：等 3 轮（每轮睡 1 秒，红线 2 秒）再恢复 → 输出「黄行数 红行数 钩子次数 盘已够行数」；期望手算：首轮黄 1、第 3 轮满 2 秒红 1、钩子 1、结束 1
WT=$T/wt; mkdir -p "$WT"
wrun() { ( B=$WT; L=$WT/log; rm -f "$L" "$WT/alert" "$WT/.wait_test"; log() { echo "[x] $*" >> "$L"; }
  eval "$(sed -n '/^# >>> _wait_helpers/,/^# <<< _wait_helpers/p' "$1")"
  for i in 1 2 3; do _wait_tick "$WT/.wait_test" "测试等盘：可用 $((i * 10)) GB / 需 50 GB"; sleep 1; done
  _wait_done "$WT/.wait_test" "测试完成（可用 50 GB）"
  echo "$(grep -c '【黄】等盘：测试等盘' "$L") $(grep -c '【红】等盘超.*测试等盘' "$L") $(cat "$WT/alert" 2> /dev/null | wc -l | tr -d ' ') $(grep -c '盘已够，等了.*测试完成' "$L")" ) }
got=$(CENSUS_WAIT_RED_S=2 CENSUS_ALERT_CMD="echo 告警 >> $WT/alert" wrun "$R/tools/census/census.sh")
chk "㊵ 首次黄行、超 2 秒写红行并调钩子、恢复写「盘已够」" "1 1 1 1" "$got"
# 负控：临时副本里删掉报红那段（if 超时 … fi），再抽段跑同一判据 → 必须红（红行 0、钩子 0），证明上面那条判得出报红被去掉
sed '/if \[ \$((now - t0)) -ge "\${CENSUS_WAIT_RED_S/,/^  fi$/d' "$R/tools/census/census.sh" > "$WT/census_nored.sh"
chk "㊵ 负控：副本确实删掉了报红段（【红】等盘超 0 处）" 0 "$(grep -c '【红】等盘超' "$WT/census_nored.sh")"
got=$(CENSUS_WAIT_RED_S=2 CENSUS_ALERT_CMD="echo 告警 >> $WT/alert" wrun "$WT/census_nored.sh")
chk "㊵ 负控：去掉报红段后同一判据红（期望 1 1 1 1 的那条在这里得 1 0 0 1）" "1 0 0 1" "$got"
# ㉟h 真 disk_ok 等盘报红：红线 0 秒 → 首次判不过即黄 + 红 + 钩子一次；钩子消息原文「…：<批次名> <标签>」（批次名 = basename $B = b，后面不能多引号，11-03 实测曾是 b"）
mkdir -p "$DK/b/work/kred"; printf 'n\tv\t14.2\n' > "$DK/b/work/kred/meta"
rm -f "$DK/alert"; CENSUS_WAIT_RED_S=0 CENSUS_ALERT_CMD="echo >> $DK/alert" dkrun 70 kred > /dev/null
chk "㉟h disk_ok 判不过：黄 1、红 1、钩子 1" "1 1 1" "$(grep -c '【黄】等盘：air 可用 70 G / 需 98 G（kred' "$DK/b.log") $(grep -c '【红】等盘超 0 分钟：air 可用 70 G / 需 98 G（kred' "$DK/b.log") $(cat "$DK/alert" 2> /dev/null | wc -l | tr -d ' ')"
chk "㉟h2 钩子消息原文：批次名后无多余引号" "【红】等盘超 0 分钟：b air 可用 70 G / 需 98 G（kred 源 14.2 GB，预估峰值 78 G + 硬闸 20 G）" "$(cat "$DK/alert" 2> /dev/null)"
# ㊾ 停批停干净（11-04 c1104_r2：TERM 停批后本机道 one_game 没停，马力欧惊奇旧局续跑到 09:33 收尾 rm -rf 工作目录，删掉新批刚播种的产物根）：
#   本机道 runone 用裸名 timeout -k 30 <秒> 包整款；GNU timeout 自立进程组，census 收到 TERM 的 kill 0 发不到它。
#   造一个同形的批：自成会话组 → 按真 census.sh 的 timeout_shim 段设 PATH → 装真 census.sh 的停止 trap → 后台「env timeout -k 30 100 <长活>」（同 runone 写法）；
#   给批发 TERM，期望（手写）：长活已起过（记了 pid）且 3 秒内不在了 →「起了 停了」。PATH 上没有任何 timeout 时长活起不来 →「没起」，不会假绿
STOPH=$T/stop_harness.sh; STOPP=$T/stop_inner.pid
{ echo '[ -n "${OWN:-}" ] || OWN=1 exec python3 -c "import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])" bash "$0" "$@"'
  echo 'set -u; log() { :; }; AIRLOCAL=0'
  sed -n '/^# >>> timeout_shim/,/^# <<< timeout_shim/p' "$R/tools/census/census.sh" | sed "s|\$(dirname \"\$0\")|$R/tools/census|g"
  grep '^trap .*kill 0' "$R/tools/census/census.sh"
  echo '( env timeout -k 30 100 bash -c '\''echo $$ > "$0"; sleep 300'\'' "$1" ) & wait'; } > "$STOPH"
rm -f "$STOPP"; bash "$STOPH" "$STOPP" > /dev/null 2>&1 & stp=$!
for _ in $(seq 50); do [ -s "$STOPP" ] && break; sleep 0.1; done
sti=$(cat "$STOPP" 2> /dev/null); kill -TERM "$stp" 2> /dev/null
for _ in $(seq 30); do [ -n "$sti" ] && kill -0 "$sti" 2> /dev/null || break; sleep 0.1; done
str="$([ -n "$sti" ] && echo 起了 || echo 没起) $([ -n "$sti" ] && kill -0 "$sti" 2> /dev/null && echo 漏停 || echo 停了)"
[ -n "$sti" ] && kill -KILL "$sti" 2> /dev/null; wait "$stp" 2> /dev/null
chk "㊾ 停批：TERM 后本机道 timeout 包着的长活一并停掉（不留续跑的旧局）" "起了 停了" "$str"
# 58 解包工人直读原件（11-04 资料盘 SSD 只读可多读者，删单读盘拷贝工 / stage 暂存 / stage_need 等盘准入）：抽真 census.sh 的 packer 段，
#   只把 one_game.sh 换成记录替身（假仓库 FR，tools/census 链真的 census.py，失败行走真 row）。期望全部手写：
#   a 批次目录里不出现 stage/；b 解包工人收到的源目录里只有指向队列（= 索引表）原件路径的软链，一个不少、不是副本；
#   c 两款都进 packed/、日志 0 行「等盘」、源目录（链接）解包后删、原件内容不动；d 待跑满 CENSUS_PACKED_MAX 就等（替身记起解包时的待跑数）；
#   e 原件不在 → 不调解包、总表记未判「机器原因」；f 两个解包工人同时跑 3 款，每款只解一次；g Air 本地化：判盘不过不推、过了推 + 进待跑
PK=$T/pk; FR=$PK/repo; mkdir -p "$FR/tools/quicktest" "$PK/lib/kA" "$PK/lib/kB" "$PK/lib/kD" "$PK/extra"; ln -s "$R/tools/census" "$FR/tools/census"; ln -s "$R/tools/disk_admit.py" "$FR/tools/disk_admit.py"; ln -s "$R/pack" "$FR/pack"
echo a > "$PK/lib/kA/a.nsp"; echo u > "$PK/extra/u.nsp"; echo b > "$PK/lib/kB/b.xci"; echo d > "$PK/lib/kD/d.nsp"
cat > "$FR/tools/quicktest/one_game.sh" << 'EOF'
#!/bin/bash
k=$QT_NAME; [ "${PK_SLOW:-0}" = 1 ] && sleep 0.3
printf '%s\t%s\t%s\n' "$k" "$(for f in "$1"/*; do [ -L "$f" ] && printf '%s>%s,' "$(basename "$f")" "$(readlink "$f")" || printf '%s>非链接,' "$(basename "$f")"; done)" "$(ls "$PK_PQ" | wc -l | tr -d ' ')" >> "$PK_LOG"
mkdir -p "$2/work/$k/extract/exefs" "$2/logs/$k"; printf 'G\t%s\t1\t1\n' "$k" > "$2/work/$k/.qt_packed"; echo "快测 ${k}：出包好"; exit 0
EOF
CSH=$R/tools/census/census.sh
# pkrun <packer 段来源文件> <队列行…（键|字节|文件1;文件2）> -- <命令…>：在干净批次里跑抽出来的真 packer 段
pkrun() { local src=$1; shift; local rows=(); while [ "$1" != -- ]; do rows+=("$1"); shift; done; shift
  ( . "$R/tools/_timeout.sh"; DCACHE=$PK/dc; FAB=; SW=2346; RUN_S=300; B=$PK/b; rm -rf "$B"; mkdir -p "$B/work" "$B/packed" "$B/running"; PQ=$B/packed; L=$B/批次.log; T=$B/总表.tsv; R=$FR; AIRLOCAL=0; LANES=2
    export PK_LOG=$PK/calls PK_PQ=$PQ; rm -f "$PK_LOG"; Q=$B/queue.tsv
    printf '键\t名称\t版本\t本体文件\t全部文件\t字节\t压缩件\t指令集\n' > "$Q"
    for r in "${rows[@]}"; do IFS='|' read -r k sz fs <<< "$r"; printf '%s\t名%s\t1.0\t%s\t%s\t%s\t0\tx\n' "$k" "$k" "${fs%%;*}" "${fs//;/|}" "$sz" >> "$Q"; done
    log() { echo "[x] $*" >> "$L"; }; bat_ok() { :; }
    eval "$(sed -n '/^# >>> work_rm/,/^# <<< work_rm/p;/^# >>> packer/,/^# <<< packer/p' "$src")"; "$@" ) > /dev/null 2>&1; }
KA="kA|3|$PK/lib/kA/a.nsp;$PK/extra/u.nsp"; KB="kB|2|$PK/lib/kB/b.xci"; KD="kD|2|$PK/lib/kD/d.nsp"
pkrun "$CSH" "$KA" "$KB" -- packer 1
chk "58a 批次目录里不出现 stage/" "无" "$([ -e "$PK/b/stage" ] && echo 有 || echo 无)"
chk "58b 解包工人收到的源目录 = 指向队列原件路径的软链（kA 本体在资料盘、补丁在溢出盘，两个都在）" \
  "kA a.nsp>$PK/lib/kA/a.nsp,u.nsp>$PK/extra/u.nsp,|kB b.xci>$PK/lib/kB/b.xci," "$(awk -F'\t' '{print $1 " " $2}' "$PK/calls" 2> /dev/null | paste -sd'|' -)"
chk "58c 两款进待跑、不打等盘、解包后源链接目录删掉、原件内容不动" "kA kB|0|无|a u b" \
  "$(ls "$PK/b/packed" | paste -sd' ' -)|$(grep -c '等盘' "$PK/b/批次.log" 2> /dev/null)|$(ls -d "$PK"/b/work/*/src 2> /dev/null | wc -l | sed 's/ *0$/无/;s/^ *[1-9].*/有/')|$(cat "$PK/lib/kA/a.nsp" "$PK/extra/u.nsp" "$PK/lib/kB/b.xci" | paste -sd' ' -)"
# d：待跑上限 1；sleep 替身第 3 次时把待跑清空（= 跑局道领走）。kB 只能在待跑空了才起解包 → 两次起解包时待跑数都是 0，且等过（sleep ≥ 1 次）
pkd() { ( . "$R/tools/_timeout.sh"; DCACHE=$PK/dc; FAB=; SW=2346; RUN_S=300; B=$PK/b; rm -rf "$B"; mkdir -p "$B/work" "$B/packed" "$B/running"; PQ=$B/packed; L=$B/批次.log; T=$B/总表.tsv; R=$FR; AIRLOCAL=0; LANES=2
    export PK_LOG=$PK/calls PK_PQ=$PQ CENSUS_PACKED_MAX=1; rm -f "$PK_LOG" "$PK/sleeps"; Q=$B/queue.tsv
    printf '键\t名称\t版本\t本体文件\t全部文件\t字节\t压缩件\t指令集\nkA\t甲\t1\t%s\t%s\t3\t0\tx\nkB\t乙\t1\t%s\t%s\t2\t0\tx\n' "$PK/lib/kA/a.nsp" "$PK/lib/kA/a.nsp" "$PK/lib/kB/b.xci" "$PK/lib/kB/b.xci" > "$Q"
    log() { echo "[x] $*" >> "$L"; }; bat_ok() { :; }; c=0; sleep() { c=$((c + 1)); echo "$c" >> "$PK/sleeps"; [ "$c" -ge 3 ] && rm -f "$PQ"/*; [ "$c" -lt 50 ] || exit 9; }
    eval "$(sed -n '/^# >>> work_rm/,/^# <<< work_rm/p;/^# >>> packer/,/^# <<< packer/p' "$1")"; packer 1 ) > /dev/null 2>&1
  echo "$(cut -f3 "$PK/calls" 2> /dev/null | paste -sd' ' -) $([ -s "$PK/sleeps" ] && echo 等过 || echo 没等)"; }
chk "58d 待跑满 CENSUS_PACKED_MAX=1 就等：kA、kB 起解包时待跑都是 0，kB 前等过" "0 0 等过" "$(pkd "$CSH")"
sed '/^# >>> packer/,/^# <<< packer/{/CENSUS_PACKED_MAX/d;}' "$CSH" > "$T/census_nothrottle.sh"
chk "58d 负控：删掉待跑上限那行后同一判据红（kB 起解包时待跑已有 1、没等）" "0 1 没等" "$(pkd "$T/census_nothrottle.sh")"
pkrun "$CSH" "kC|5|$PK/lib/kC/nope.nsp" "$KB" -- packer 1
chk "58e 原件不在：kC 不调解包、总表记未判（机器原因）、不进待跑；kB 照常" "kB|kC 未判 机器原因|kB" \
  "$(cut -f1 "$PK/calls" | paste -sd' ' -)|$(awk -F'\t' '{print $1, $7, ($8 ~ /^机器原因：原件不在/ ? "机器原因" : $8)}' "$PK/b/总表.tsv" 2> /dev/null)|$(ls "$PK/b/packed" | paste -sd' ' -)"
pk2() { packer 1 & packer 2 & wait; }; export PK_SLOW=1 CENSUS_PACKED_MAX=9; pkrun "$CSH" "$KA" "$KB" "$KD" -- pk2; unset PK_SLOW CENSUS_PACKED_MAX
chk "58f 两个解包工人同时跑 3 款：每款只解一次" "kA kB kD" "$(cut -f1 "$PK/calls" | sort | paste -sd' ' -)"
chk "58h 接线：census.sh 不再有拷贝工 / 暂存 / 等盘准入，census.py 不再有 stage_need / peak_sample" "0 0" \
  "$(grep -v '^ *#' "$CSH" | grep -c -E '^copier\(\)|copier &|stage_need|\$ST/|STAGE_MODE|peak_sampler') $(grep -c -E 'def (stage_need|peak_sample)\(' "$R/tools/census/census.py")"
# 58i 删款工作目录走 _root_rm（11-04 c1104_r2：work/<键>/p 里产物根的 RomFS 共享存储整棵只读，局被杀时裸 rm -rf 删不掉、漏盘）：抽真 census.sh 的 work_rm 段。期望手写：
#   只读存储整棵删掉、不写红行；chflags uchg 锁住的文件删不掉 → 返回 1、写一行【红】；负控：work_rm 换回裸 rm -rf，只读存储删不掉（目录还在）
WR=$T/wr; wrr() { ( L=$WR/log; log() { echo "$*" >> "$L"; }; eval "$(sed -n '/^# >>> work_rm/,/^# <<< work_rm/p' "$1")"; work_rm "$2"; echo $? ) 2> /dev/null; }
wmk() { rm -rf "$WR/w" 2> /dev/null; chmod -R u+w "$WR" 2> /dev/null; rm -rf "$WR"; mkdir -p "$WR/w/p/work/k/roots/.romfs_store/k/id1/sub"; echo x > "$WR/w/p/work/k/roots/.romfs_store/k/id1/sub/f"; chmod -R a-w "$WR/w/p/work/k/roots/.romfs_store"; }
wmk; chk "58i 只读 RomFS 存储：work_rm 整棵删掉、返回 0、不写红行" "0 无 0" "$(wrr "$CSH" "$WR/w") $([ -e "$WR/w" ] && echo 有 || echo 无) $(cat "$WR/log" 2> /dev/null | grep -c '【红】')"
wmk; chmod u+w "$WR/w/p/work/k/roots/.romfs_store/k/id1/sub"; chflags uchg "$WR/w/p/work/k/roots/.romfs_store/k/id1/sub/f"
chk "58i2 锁住删不掉：返回 1、写一行【红】带路径" "1 有 1" "$(wrr "$CSH" "$WR/w") $([ -e "$WR/w" ] && echo 有 || echo 无) $(grep -c "【红】普查：删不掉 $WR/w" "$WR/log" 2> /dev/null)"
chflags nouchg "$WR/w/p/work/k/roots/.romfs_store/k/id1/sub/f"
sed '/^# >>> work_rm/,/^# <<< work_rm/s/^work_rm() {.*/work_rm() { rm -rf "$1"; [ -e "$1" ] \&\& return 1; return 0; }/' "$CSH" > "$T/census_rawrm.sh"
wmk; chk "58i 负控：换回裸 rm -rf，只读存储删不掉（返回 1、目录还在）" "1 有" "$(wrr "$T/census_rawrm.sh" "$WR/w") $([ -e "$WR/w" ] && echo 有 || echo 无)"
chmod -R u+w "$WR"; rm -rf "$WR"
chk "58i3 接线：census.sh 删款工作目录（runone 丢回 / 收尾删 p / packone 开工 / 原件不在 / 出包失败删出包工作目录 / Air 放行 / 天眼道开工 / 天眼出包失败删出包工作目录）都走 work_rm、不再裸 rm -rf \$W" "8 0" \
  "$(grep -v '^ *#' "$CSH" | grep -c -E 'work_rm "\$(W|B/work/\$k)') $(grep -v '^ *#' "$CSH" | grep -c -E 'rm -rf "\$W"|rm -rf "\$W/p"|rm -rf "\$B/work/\$k"')"
# 59 出包提前到出包工人（11-04 总指挥方案 A：出包原在跑局道 runone 里与 Mac 局串行，直连库 Metal 冷编 30–40 分钟停住整道）：抽真 census.sh 的 packer 段 / runone，
#   one_game.sh、remote.sh 换记录替身（假仓库 F9，tools/census 链真的 census.py）。期望全部手写：
#   a packone 调 one_game 带 QT_PACK_ONLY=1，且 runone 本机段 one_game 那一行的每个环境变量（从 runone 源码抽，含 $FAB 展开；只除解包秒 QT_UNPACK_S：
#     它只给「源是别处解好的解包目录」用，packone 自己解包）在 packone 里取值相同；b 出好 → 进 packed/、写 meta 与 unpack_s（= .qt_packed 第 3 列）
#   c 本机道收到 .qt_packed 的款：源给 work/<键>/p/work/<键>（只跑局）、带 QT_KEEP=1（局槽被占放回待跑时包还在）、出包段日志并进 r/logs（exefs 不并）、
#     总表解包秒 7 / 出包秒 30 取自出包那次、跑完删 p/；d Air 道：--sync 同步 ~/<批次>/work/<键>/p/work/<键>，远端源同一目录
#   e 出包失败（替身写「失败 / 出包：着色器」退出 1）：总表记一行第一个失败点「出包：着色器」、不进 packed/、出包工作目录删掉（没留证）；
#     f 墙钟超时没写结果行（替身直接退出 124）：总表记一行未判「出包没写出结果行（退出码 124…」；g PACKERS 缺省 3
#   h 出好后只留 @现行：旧版本、没人指的 RomFS 存储身份、出包进程的钉删掉（rsync 不认克隆，旧版本每版整份传到 Air）
#   负控：① packone 回退成只解包（QT_UNPACK_ONLY=1，原写法）→ a 红；② packone 漏掉 QT_DUAL=1 → a 红；③ runone 去掉认 .qt_packed 那行 → c 的源变成 extract
P9=$T/p9; F9=$P9/repo; mkdir -p "$F9/tools/quicktest" "$P9/lib"; ln -s "$R/tools/census" "$F9/tools/census"; ln -s "$R/tools/disk_admit.py" "$F9/tools/disk_admit.py"; ln -s "$R/pack" "$F9/pack"; echo a > "$P9/lib/a.nsp"
cat > "$F9/tools/quicktest/one_game.sh" << 'EOF'
#!/bin/bash
k=$QT_NAME; { printf 'SRC=%s\n' "$1"; for v in $P9_VARS QT_PACK_ONLY QT_UNPACK_ONLY QT_KEEP; do printf '%s=%s\n' "$v" "${!v-<无>}"; done; } > "$P9_LOG"
if [ -f "$1/.qt_packed" ]; then mkdir -p "$2/logs/$k"; echo hl > "$2/logs/$k/oneclick.log"
  { printf '源\t款\t程序号\t结论\t第一个失败点\t解包秒\t出包秒\tMac局秒\t首帧\t首帧毫秒\t帧数\t图形模式\t直连异常\t崩溃\t红行前3\t进局\n'
    printf '%s\tG\t%s\t通过\t-\t%s\t%s\t100\t是\t1\t9\tdirect\t-\t否\t-\t否\n' "$1" "$k" "$(cut -f3 "$1/.qt_packed")" "$(cut -f4 "$1/.qt_packed")"; } > "$2/结果.tsv"; exit 0; fi
case ${P9_MODE:-ok} in
  ok) r=$2/work/$k/roots; mkdir -p "$r/.romfs_store/G/x" "$r/.romfs_store/G/y" "$r/G@a" "$r/G@b" "$2/logs/$k/exefs"; ln -s ../.romfs_store/G/x "$r/G@a/romfs"; ln -s ../.romfs_store/G/y "$r/G@b/romfs"
      ln -s G@b "$r/G@现行"; echo "1 x" > "$r/.pin.G@a.1"; echo m > "$2/logs/$k/exefs/main"; echo ol > "$2/logs/$k/oneclick.log"; echo dl > "$2/logs/$k/direct_fail.tsv"
      printf 'G\t%s\t7\t30\n' "$k" > "$2/work/$k/.qt_packed"; echo "快测 ${k}：出包好"; exit 0;;
  fail) mkdir -p "$2/work/$k/extract" "$2/logs/$k"
      { printf '源\t款\t程序号\t结论\t第一个失败点\t解包秒\t出包秒\tMac局秒\t首帧\t首帧毫秒\t帧数\t图形模式\t直连异常\t崩溃\t红行前3\t进局\n'
        printf '%s\tG\t%s\t失败\t出包：着色器\t7\t30\t-\t-\t-\t-\t-\t-\t-\tx\t-\n' "$1" "$k"; } > "$2/结果.tsv"; exit 1;;
  evid) mkdir -p "$2/work/$k/extract" "$2/logs/$k"; echo 出包失败 > "$2/logs/$k/.留证"; echo ol > "$2/logs/$k/oneclick.log"
      { printf '源\t款\t程序号\t结论\t第一个失败点\t解包秒\t出包秒\tMac局秒\t首帧\t首帧毫秒\t帧数\t图形模式\t直连异常\t崩溃\t红行前3\t进局\n'
        printf '%s\tG\t%s\t失败\t出包：着色器\t7\t30\t-\t-\t-\t-\t-\t-\t-\tx\t-\n' "$1" "$k"; } > "$2/结果.tsv"; exit 1;;
  hang) mkdir -p "$2/work/$k/extract" "$2/logs/$k"; exit 124;;
esac
EOF
cat > "$F9/tools/remote.sh" << 'EOF'
#!/bin/bash
[ "$3" = --load ] && { echo "0 0"; exit 0; }; printf '%s\n' "$@" > "$P9_RLOG"; exit 1
EOF
# p9ctx <census.sh> <命令…>：干净批次 + 真 census.sh 的 work_rm / packer / norun_why…runone 段 + FAB 那几行（缺省口径）
p9ctx() { local src=$1; shift
  ( . "$R/tools/_timeout.sh"; B=$P9/b; rm -rf "$B" "$P9/dc"; mkdir -p "$B/work" "$B/packed" "$B/running"; PQ=$B/packed; L=$B/批次.log; T=$B/总表.tsv; R=$F9; AIRLOCAL=0; LANES=2
    DCACHE=$P9/dc; RUN_S=300; SW=2346; REL=fake/b; NAME=census_only; RLANES=1; AIRSH=; unset S2A_SLOT_RUN CENSUS_NATIVE_TIER CENSUS_PATCH_DIR CENSUS_MANUAL_QUEUE
    export P9_LOG=$P9/env P9_RLOG=$P9/rargs P9_VARS="$P9_VARS"; rm -f "$P9_LOG" "$P9_RLOG"
    log() { echo "[x] $*" >> "$L"; }; bat_ok() { :; }
    eval "$(grep -E '^FAB=|^FAB="\$FAB ' "$src")"; SW=2346
    eval "$(sed -n '/^# >>> work_rm/,/^# <<< work_rm/p;/^# >>> packer/,/^# <<< packer/p;/^norun_why() {/,/^}/p' "$src")"; "$@" ) > /dev/null 2>&1; }
# runone 本机段 one_game 那一行的环境变量（续行拼起来再抽「名=值」；$FAB 另展开）：期望值按 runone 自己的表达式在同一上下文里求
RLOC=$(sed -n '/^runone() {/,/^}/p' "$CSH" | sed -n '/if \[ "\$h" = local \]; then   # 本机：直接跑/,/^  else$/p' | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | grep 'one_game.sh')
RVARS=$(grep -oE '(^| )[A-Z][A-Z0-9_]*=("[^"]*"|[^ ]*)' <<< "$RLOC" | sed 's/^ //' | grep -v '^QT_UNPACK_S=')
FABV=$( ( eval "$(grep -E '^FAB=|^FAB="\$FAB ' "$CSH")"; printf '%s\n' $FAB ) )
P9_VARS=$( { cut -d= -f1 <<< "$RVARS"; cut -d= -f1 <<< "$FABV"; } | sort -u | paste -sd' ' -)
p9want() { ( k=kP; DCACHE=$P9/dc; RUN_S=300; SW=2346; unset CENSUS_NATIVE_TIER; while IFS= read -r a; do [ -n "$a" ] || continue; n=${a%%=*}; eval "v=${a#*=}"; printf '%s=%s\n' "$n" "$v"; done <<< "$RVARS
$FABV" ) | sort -u; }
p9cmp() { local src=$1; P9_MODE=ok p9ctx "$src" packone kP 名P 1.0 1073741824 "$P9/lib/a.nsp"
  echo "$(grep '^QT_PACK_ONLY=' "$P9/env" 2> /dev/null || echo QT_PACK_ONLY=没调) 不符:$(p9want | while IFS= read -r l; do grep -qxF "$l" "$P9/env" 2> /dev/null || printf '%s,' "${l%%=*}"; done)"; }
chk "59a 射程：runone 本机段抽到的环境变量 ≥ 10 个（含 \$FAB 展开 3 个）" "是" "$([ "$(p9want | wc -l)" -ge 10 ] && [ "$(wc -l <<< "$FABV")" -ge 3 ] && echo 是 || echo "否（$(p9want | paste -sd' ' -)）")"
chk "59a packone 带 QT_PACK_ONLY=1，runone 本机段 one_game 的环境变量（$(p9want | wc -l | tr -d ' ') 个）取值全相同" "QT_PACK_ONLY=1 不符:" "$(p9cmp "$CSH")"
chk "59b 出好 → 进 packed/、meta、unpack_s = 7、源链接目录删掉、总表无行" "kP|名P|7|无|0" \
  "$(ls "$P9/b/packed")|$(cut -f1 "$P9/b/work/kP/meta" 2> /dev/null)|$(cat "$P9/b/work/kP/p/logs/kP/unpack_s" 2> /dev/null)|$([ -e "$P9/b/work/kP/src" ] && echo 有 || echo 无)|$(grep -c . "$P9/b/总表.tsv" 2> /dev/null || echo 0)"
chk "59h 出好后只留现行：旧版本 G@a、它独占的 RomFS 存储身份 x、钉都删掉；现行 G@b 与身份 y 留着" "G@b G@现行|y|0" \
  "$(ls "$P9/b/work/kP/p/work/kP/roots" | paste -sd' ' -)|$(ls "$P9/b/work/kP/p/work/kP/roots/.romfs_store/G" 2> /dev/null | paste -sd' ' -)|$(ls -a "$P9/b/work/kP/p/work/kP/roots" | grep -c '^\.pin\.')"
python3 - "$CSH" "$T/census_unpackonly.sh" "$T/census_nodual.sh" "$T/census_nopkl.sh" << 'EOF'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
a, b = s.index('  local sw=(); [ -n "${S2A_SLOT_RUN:-}" ]', s.index('packone() {')), s.index('rc=$?', s.index('QT_PACK_ONLY=1 QT_KEEP_EXEFS=1')) + 5
open(sys.argv[2], 'w', encoding='utf-8').write(s[:a] + '  QT_UNPACK_ONLY=1 QT_NAME=$k QT_TITLE_ID=$k bash "$R/tools/quicktest/one_game.sh" "$S" "$W/p" > "$W/pack.out" 2>&1; rc=$?' + s[b:])
p = s.index('packone() {'); q = s.index('QT_DUAL=1 ', p)
open(sys.argv[3], 'w', encoding='utf-8').write(s[:q] + s[q + len('QT_DUAL=1 '):])
open(sys.argv[4], 'w', encoding='utf-8').write(re.sub(r'\n  local PKL=; \[ -f [^\n]*', '\n  local PKL=', s, count=1))
EOF
chk "59a 负控①：packone 回退成只解包（QT_UNPACK_ONLY=1）→ 红（没有 QT_PACK_ONLY、出包变量全不符）" "QT_PACK_ONLY=<无> 有不符" "$(p9cmp "$T/census_unpackonly.sh" | sed 's/不符:..*/有不符/')"
chk "59a 负控②：packone 漏 QT_DUAL=1 → 红（不符 QT_DUAL）" "QT_PACK_ONLY=1 不符:QT_DUAL," "$(p9cmp "$T/census_nodual.sh")"
p9seq() { packone kP 名P 1.0 1073741824 "$P9/lib/a.nsp"; runone "$1" kP 1; }
p9run() { P9_MODE=ok p9ctx "$1" p9seq "$2"; }
p9run "$CSH" local
chk "59c 本机道只跑局：源 = p/work/kP、QT_KEEP=1、r/logs 有出包段 oneclick.log / direct_fail.tsv 没有 exefs、总表 解包秒 7 出包秒 30、跑完 p/ 删掉" \
  "SRC=$P9/b/work/kP/p/work/kP QT_KEEP=1|有 有 无|7 30 通过|无" \
  "$(grep -E '^(SRC|QT_KEEP)=' "$P9/env" | paste -sd' ' -)|$([ -f "$P9/b/work/kP/r/logs/kP/oneclick.log" ] && echo 有 || echo 无) $([ -f "$P9/b/work/kP/r/logs/kP/direct_fail.tsv" ] && echo 有 || echo 无) $([ -e "$P9/b/work/kP/r/logs/kP/exefs" ] && echo 有 || echo 无)|$(awk -F'\t' '{print $9, $10, $7}' "$P9/b/总表.tsv" 2> /dev/null)|$([ -e "$P9/b/work/kP/p" ] && echo 有 || echo 无)"
p9run "$T/census_nopkl.sh" local
chk "59c 负控③：runone 去掉认 .qt_packed 那行 → 源变成 extract（不存在 → 丢回重排，one_game 没被调）" "没调" "$(grep '^SRC=' "$P9/env" 2> /dev/null | grep -q "$P9/b/work/kP/p/work/kP$" && echo 只跑局 || echo 没调)"
p9run "$CSH" air; P9H='~'; P9R=fake/b
chk "59d Air 道只跑局：--sync 家目录下 <批次>/work/kP/p/work/kP，远端源同一目录（不同步 extract）" "有 有 无" \
  "$(grep -qxF -e '--sync' "$P9/rargs" && grep -qxF "$P9H/$P9R/work/kP/p/work/kP" "$P9/rargs" && echo 有 || echo 无) $(grep -qF "\"\$HOME/$P9R/work/kP/p/work/kP\"" "$P9/rargs" && echo 有 || echo 无) $(grep -q 'extract' "$P9/rargs" && echo 有 || echo 无)"
P9_MODE=fail p9ctx "$CSH" packone kP 名P 1.0 1073741824 "$P9/lib/a.nsp"
chk "59e 出包失败：总表一行「失败 出包：着色器」、不进 packed/、出包工作目录删掉" "kP 失败 出包：着色器|0|无" \
  "$(awk -F'\t' '{print $1, $7, $8}' "$P9/b/总表.tsv" 2> /dev/null | paste -sd'/' -)|$(ls "$P9/b/packed" | wc -l | tr -d ' ')|$([ -e "$P9/b/work/kP/p/work" ] && echo 有 || echo 无)"
# 59e2 留证款（one_game 写了 .留证）也当场删出包工作目录、只留日志（11-04 总指挥：判完当场释放大件，不留到批次收尾）：期望 work 无、日志 oneclick.log 在、批次日志写「只留日志」
P9_MODE=evid p9ctx "$CSH" packone kP 名P 1.0 1073741824 "$P9/lib/a.nsp"
chk "59e2 留证的出包失败：出包工作目录删掉、日志留着、批次日志写「只留日志」" "无|有|有" \
  "$([ -e "$P9/b/work/kP/p/work" ] && echo 有 || echo 无)|$([ -f "$P9/b/work/kP/p/logs/kP/oneclick.log" ] && echo 有 || echo 无)|$(grep -q '留证.*只留日志' "$P9/b/批次.log" 2> /dev/null && echo 有 || echo 无)"
P9_MODE=hang p9ctx "$CSH" packone kP 名P 1.0 1073741824 "$P9/lib/a.nsp"
chk "59f 没写结果行（退出 124）：总表一行未判「出包没写出结果行（退出码 124」、不进 packed/" "kP 未判 出包没写出结果行（退出码 124|0" \
  "$(awk -F'\t' '{print $1, $7, (index($8, "出包没写出结果行（退出码 124") == 1 ? "出包没写出结果行（退出码 124" : $8)}' "$P9/b/总表.tsv" 2> /dev/null | paste -sd'/' -)|$(ls "$P9/b/packed" | wc -l | tr -d ' ')"
chk "59g PACKERS 缺省 3" "3" "$(eval "$(grep -E '^ RUN_S=[0-9]+; ONLY=; PACKERS=' "$CSH")"; echo "$PACKERS")"
# 60 直连缓存选址（11-04：缺省用共享 S2A_XLATE_CACHE、不自带 40 GB 淘汰；显式 CENSUS_DCACHE / 没有共享缓存时才私有 + dcache_gc）
DCB=$(sed -n '/^# >>> dcache_pick/,/^# <<< dcache_pick/p' "$R/tools/census/census.sh")
dcp() { (B=$T/dc_b/batch; mkdir -p "$B"; eval "$DCB"; echo "$DCACHE|$DCACHE_GC") 2> /dev/null; }
chk "60 有共享缓存 → 用共享、不自带淘汰" "$T/dc_shared|0" "$(S2A_XLATE_CACHE=$T/dc_shared CENSUS_DCACHE= dcp)"
chk "60 显式 CENSUS_DCACHE → 私有 + 淘汰" "$T/dc_priv|1" "$(S2A_XLATE_CACHE=$T/dc_shared CENSUS_DCACHE=$T/dc_priv dcp)"
chk "60 都没有（贡献者单机）→ 批次旁 census_dcache + 淘汰" "$T/dc_b/census_dcache|1" "$(S2A_XLATE_CACHE= CENSUS_DCACHE= dcp)"
# 61 存档口径（11-04 总指挥：普查主数字一律不带存档，本机 / 远端统一；CENSUS_SAVES=lib 只给存档复判批）：抽真 census.sh 的 save_pick 段 + 真 tools/mac_save.sh。
#   夹具：假存档库 lib/<款>_<构建号>/device/x、假产物根 exefs/main（0x40 起 16 字节构建号 = 0x11 × 16）。期望手写：
#   none（缺省）→ S2A_SAVES 指不存在的目录、漏进来的 S2A_SAVE_DIR 被清、mac_save_prep 打「不带存档」且不拷 save/；lib → 照旧带上存档库那份；
#   其他值 → 退出 2；远端命令串以 ${RSAVE} 开头（远端同口径）
SVB=$(sed -n '/^# >>> save_pick/,/^# <<< save_pick/p' "$R/tools/census/census.sh")
SV=$T/sv; mkdir -p "$SV/in/exefs" "$SV/lib/g1_11111111111111111111111111111111/device" "$SV/run"; echo x > "$SV/lib/g1_11111111111111111111111111111111/device/x"
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"\0" * 0x40 + b"\x11" * 16 + b"\0" * 16)' "$SV/in/exefs/main"
svp() { (B=$SV/batch; export S2A_SAVES=$SV/lib S2A_SAVE_DIR=$SV/leak; eval "$SVB"; echo "S=${S2A_SAVES#$SV/}|D=$(basename "${S2A_SAVE_DIR:-无}")|$([ -e "$S2A_SAVES" ] && echo 在 || echo 不在)"; source "$R/tools/mac_save.sh"; unset S2A_SAVE_DIR; rm -rf "$SV/run/save"; mac_save_prep g1 "$SV/in" "$SV/run" | grep -q "不带存档" && echo 不带 || echo 带; [ -f "$SV/run/save/device/x" ] && echo 拷了 || echo 没拷) 2> /dev/null | tr '\n' ' '; }
chk "61 缺省 none：S2A_SAVES 指不存在的目录、漏进来的 S2A_SAVE_DIR 清掉、mac_save_prep 不带存档不拷" "S=batch/.不带存档|D=无|不在 不带 没拷 " "$(CENSUS_SAVES= svp)"
chk "61 lib（存档复判批）：照旧按构建号带存档库那份" "S=lib|D=leak|在 带 拷了 " "$(CENSUS_SAVES=lib svp)"
svk() { (B=$SV/batch; export S2A_SAVES=$SV/lib; eval "$SVB"; bash "$R/graphics/widen/scan/save_pick.sh" g1 11111111111111111111111111111111 | sed "s#^$SV/##") 2> /dev/null; }
chk "61 普查实际起局入口 save_pick.sh（entry_check 调）：none 不挑存档" "" "$(CENSUS_SAVES= svk)"
chk "61 save_pick.sh：lib 挑存档库那份" "lib/g1_11111111111111111111111111111111" "$(CENSUS_SAVES=lib svk)"
chk "61 其他值 → 退出 2" "2" "$( (B=$SV/batch; CENSUS_SAVES=yes; eval "$SVB") > /dev/null 2>&1; echo $?)"
chk "61 接线：远端命令串以 \${RSAVE:-} 开头（远端同口径）" "1" "$(grep -c 'bash -c "${RSAVE:-}S2A_SAFE_RM=' "$R/tools/census/census.sh")"
# 62 出包 / 整局墙钟只作兜底、按源 GB 算（11-04 总指挥：固定 4200 / 5400 秒杀掉还在进展的冷出包大作）：抽真 census.sh 的 wall_s 段；期望手写：
#   源 0 GB → 3600；源 14.2 GB → 3600 + 1800 × 14.2 = 29160；CENSUS_WALL_BASE_S=100 CENSUS_WALL_PER_GB_S=10、源 5 GB → 150；
#   接线：packone / runone 本机 / 远端三处 timeout 与未判提示都取 ${CENSUS_LOCAL_S|CENSUS_REMOTE_S:-${WALL:-…}}，不再有裸 4200 / 5400 缺省
WSB=$(sed -n '/^# >>> wall_s/,/^# <<< wall_s/p' "$R/tools/census/census.sh")
ws() { (eval "$WSB"; wall_s "$1") 2> /dev/null; }
chk "62 源 0 GB → 3600 秒" "3600" "$(ws 0)"
chk "62 源 14.2 GB → 29160 秒" "29160" "$(ws 14.2)"
chk "62 CENSUS_WALL_BASE_S / PER_GB_S 可覆盖：100 + 10 × 5 = 150" "150" "$(CENSUS_WALL_BASE_S=100 CENSUS_WALL_PER_GB_S=10 ws 5)"
chk "62 接线：三处墙钟 + 未判提示取 WALL（本机两处 + 远端一处 + 提示一处），没有裸 :-4200} / :-5400} 缺省" "4|0" "$(grep -c 'S:-${WALL:-' "$R/tools/census/census.sh")|$(grep -cE 'CENSUS_(LOCAL|REMOTE)_S:-(4200|5400)\}' "$R/tools/census/census.sh")"

[ $bad = 0 ] && echo "普查规则层单测全绿" || { echo "普查规则层单测有红"; exit 1; }

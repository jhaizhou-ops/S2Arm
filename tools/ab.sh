#!/bin/bash
# 同包开关 A/B 一键登记（10-23 总指挥：验证提速，「合入后 30 分钟内拿到 iPhone 读数」；底层改动一律缺省关合入 → iPhone 同包 A/B 达标 → 翻缺省）：
#   MERGE_OWNER=<线名> tools/ab.sh <款> <K=V>… [--device=1|2|any，缺省 2] [--act=秒，缺省 60] [--prio=N，缺省 2]
#     → 用该款登记的包排两局冷局：A 只带 S2A_AB=<号>:A；B 带 S2A_AB=<号>:B 和给的开关。两局都带 --env，按诊断局排（不写记分板），结果进发起线收件箱
#   tools/ab.sh report <号> [--wait=秒]
#     → 两局都出结果后打两行对比表（frame_gate 同口径：MARK 后满 60 秒的窗口；读回 / 帧数 / 每帧分配；GC 停顿按可玩段（MARK 后）最长，10-26 起）；--wait 时等到出齐或超时
set -u; TOOLS=$(cd "$(dirname "$0")" && pwd); SD=${S2A_SCHED_DIR:-$HOME/.s2arm/run/s2arm/sched}; SCH=${S2A_AB_SCHED:-$TOOLS/sched.sh}   # S2A_AB_SCHED：单测换假调度
if [ "${1:-}" = report ]; then
  id=${2:?号}; W=0; for a in "${@:3}"; do case $a in --wait=*) W=${a#*=};; esac; done; s=$SECONDS
  while :; do
    out=$(python3 - "$SD" "$id" "$TOOLS" <<'PY'
import sys, os, glob, re, csv, subprocess
SD, id, T = sys.argv[1:4]; sys.path.insert(0, T)
from frame_gate import judge; from game_fps import of_dir; from score_cells import window_power, energy_state, ab_power_noise, infra, test_unready, fps_basis, scene_menu, mark_draws
def note(f):
    try: return subprocess.run(['bash', '-c', f'. "{f}" 2>/dev/null; echo "$NOTE|$ENVS|$COMMIT|$G"'], capture_output=True, text=True).stdout.strip()
    except Exception: return ''
rows = {}; pws = {}; game = None; drw = {}; bad = {}
for f in glob.glob(f'{SD}/jobs/*.job'):
    n = note(f)
    m = re.search(r'A/B ' + re.escape(id) + r' ([AB])', n)
    if not m: continue
    outs = sorted(glob.glob(f[:-4] + '/out_*'))
    o = outs[-1] if outs else None; env, commit = n.split('|')[1], n.split('|')[2]; game = n.split('|')[3] if n.count('|') >= 3 else game
    if not o or not os.path.exists(o + '/host.log'): rows[m.group(1)] = (os.path.basename(f[:-4]), commit, env, '未出结果'); continue
    h = open(o + '/host.log', errors='replace').read(); mk = re.search(r'S2A 标记 MARK：帧 (\d+)', h)
    try: fr = list(csv.DictReader(open(o + '/frames.tsv', errors='replace'), delimiter='\t'))
    except OSError: fr = []
    if not mk: rows[m.group(1)] = (os.path.basename(f[:-4]), commit, env, '没到 MARK'); continue
    v, say = judge(fr, of_dir(o)[0], int(mk.group(1))); pw = window_power(o)
    # 局有效性（10-23 帧率能耗线：塞尔达 A 局把 DLC 介绍页当 MARK、每帧 114 次绘制，被当正常局报「功耗差 +2.49 W 超出噪声」）：
    #   记分板的局无效判定（基础设施 / 测试没到位 / 帧率口径 / 疑似菜单当 MARK）任一成立 → 这局不进功耗比较
    why = infra(o) or test_unready(o) or fps_basis(o) or scene_menu(o, game or '')
    if why: bad[m.group(1)] = why
    drw[m.group(1)] = mark_draws(o)
    if pw is not None and not why: pws[m.group(1)] = pw
    pws_s = f'功耗 {pw:.2f} W（{energy_state(o)}）' if pw is not None else '功耗 未测'
    g = lambda p: (re.search(p, say) or [None, '未测'])[1]
    rows[m.group(1)] = (os.path.basename(f[:-4]), commit, env, f"{v}｜{g(r'MARK 后 (\d+ 秒 \d+ 帧)')}｜读回 {g(r'读回合计 ([\d.]+ ms)')}｜每帧分配 {g(r'每帧分配均值 (\d+ B)')}｜GC 可玩段最长 {g(r'GC 停顿可玩段（MARK 后）最长 ([\d.]+ ms（帧 [^，）]+)')}）｜{pws_s}")
print('\n'.join(f'{k}  {r[0]}  包 {r[1]}  {r[2]}  →  {r[3]}' + (f'｜每帧绘制中位 {drw[k]}' if drw.get(k) else '') + (f'｜局无效：{bad[k]}' if k in bad else '') for k, r in sorted(rows.items())))
# 两局场景是否同一量级：MARK 后每帧绘制中位相差超过 4 倍 → 不是同一场景，功耗不下结论（阈值同 score_cells.scene_menu 的 1/4）
if drw.get('A') and drw.get('B') and max(drw['A'], drw['B']) > 4 * min(drw['A'], drw['B']):
    print(f"不可比：两局 MARK 后每帧绘制中位 A {drw['A']} / B {drw['B']}，差 {max(drw['A'], drw['B']) / min(drw['A'], drw['B']):.1f} 倍，不是同一场景，功耗不下结论"); pws.clear()
for k in sorted(bad): print(f"{k} 局无效（{bad[k]}），不进功耗比较")
# 功耗差判噪声（score_cells.ab_power_noise：按款查 tools/ab_noise.tsv 的同包 A/A 极差；没有该款 → 不判）
if 'A' in pws and 'B' in pws:
    d = pws['B'] - pws['A']; nz = ab_power_noise(game)
    if nz is None: print(f"功耗差 B−A {d:+.2f} W；{game} 无噪声底（tools/ab_noise.tsv 没有同包 A/A ≥ 3 局），功耗不判")
    else: print(f"功耗差 B−A {d:+.2f} W，噪声底 {nz[0]:.2f} W（{game}：{nz[1]}）→ {'超出噪声' if abs(d) > nz[0] else '噪声内，不算差别'}")
print('齐' if len(rows) == 2 and all(r[3] not in ('未出结果',) for r in rows.values()) else '未齐')
PY
)
    [ "$(echo "$out" | tail -1)" = 齐 ] || [ $((SECONDS - s)) -ge "$W" ] && { echo "$out" | sed '$d'; [ "$(echo "$out" | tail -1)" = 齐 ]; exit $?; }
    sleep 60
  done
fi
G=${1:?款}; shift; SW=(); DEV=2; ACT=60; PRIO=2
for a in "$@"; do case $a in --device=*) DEV=${a#*=};; --act=*) ACT=${a#*=};; --prio=*) PRIO=${a#*=};; *=*) SW+=("--env=$a");; *) echo "🔴 认不得参数 ${a}（开关写 K=V）"; exit 1;; esac; done
[ ${#SW[@]} -gt 0 ] || { echo "🔴 至少给一个开关 K=V"; exit 1; }
[ -n "${MERGE_OWNER:-}" ] || { echo "🔴 要 MERGE_OWNER=<线名>（结果进该线收件箱）"; exit 1; }
# 号 = 款-时刻-进程号（10-23 帧率能耗线：只取到秒时同一秒连登两款撞号，report 把两款混在一起）
id=$G-$(date +%m%d%H%M%S)-$$; c=$(. "$SD/pkgs/$G.env" 2> /dev/null; echo "${COMMIT:-?}")
# 两局要么都入队要么都不入（同上：B 被「每线 3 个」上限挡掉，只剩孤儿 A）：B 入队失败就撤掉刚入队的 A
oa=$(bash "$SCH" submit "$G" --mode=cold --act="$ACT" --prio="$PRIO" --device="$DEV" --env="S2A_AB=$id:A" "A/B ${id} A（缺省）" 2>&1); ra=$?; echo "$oa"; [ $ra = 0 ] || exit 1
qa=$(echo "$oa" | sed -n 's/^已入队 \([^；]*\.job\)；.*/\1/p' | tail -1)
if ! bash "$SCH" submit "$G" --mode=cold --act="$ACT" --prio="$PRIO" --device="$DEV" --env="S2A_AB=$id:B" "${SW[@]}" "A/B ${id} B（${SW[*]//--env=/}）"; then
  [ -n "$qa" ] && rm -f "$SD/queue/$qa" && echo "🔴 B 局没入队，已撤掉 A 局（${qa}），这对 A/B 没登记"; exit 1; fi
echo "A/B 号 ${id}：${G} 包 ${c}，测试机 ${DEV}；出结果后：tools/ab.sh report ${id}（--wait=秒 等到齐）"

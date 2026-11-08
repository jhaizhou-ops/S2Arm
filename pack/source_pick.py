#!/usr/bin/env python3
"""从原件内容清单选这次要出的那一款（一键出包 Mac 的 pack/oneclick/oneclick.sh 与 Windows 的 pack/orch/oneclick_win.py 共用，规则只在这里）。
  source_pick.py <临时目录>   临时目录里：idx（「序号<TAB>文件」每行一个）、i<序号>.json（nx_unpack --inspect 输出）；环境 S2A_WANT_TID 指定程序号
  标准输出：程序号 / 名称 / 显示版本 / 说明行 / 选中的文件（每行一个）；判不出或不支持报红到标准错误、退 1"""
import json, os, sys
d = sys.argv[1]; files = dict(l.rstrip('\n').split('\t', 1) for l in open(os.path.join(d, 'idx')))
pk = []   # (文件, 包)
for i, f in files.items():
    p = os.path.join(d, f'i{i}.json')
    if os.path.exists(p):
        for x in json.load(open(p))['packages']: pk.append((f, x))
bases = {x['baseId'] for _, x in pk if x['type'] == 'base'}
# 不止一个本体（10-26 #456：动森文件夹里还带同系列独立小程序「小岛转移工具」，另一个本体程序号，原先整个拒掉）：
#   --title-id 指定就用它；没指定时主游戏的内容远大于同系列小工具——最大的本体内容至少是第二大的 4 倍才自动挑它、打一行黄字点名跳过的；
#   两款差不多大（两个不同游戏放一起）判不出，报红列出候选、请用 --title-id 指定（启动器按游戏号总会给）
want = os.environ.get('S2A_WANT_TID', '').upper()
size = {b: sum(x.get('contentBytes') or 0 for _, x in pk if x['baseId'] == b and x['type'] == 'base') for b in bases}
names = {b: next((x['name'] for _, x in pk if x['baseId'] == b and x['type'] == 'base'), '') for b in bases}
cand = '、'.join(f'{names[b] or "?"}（{b}，{size[b] / 1e9:.2f} GB）' for b in sorted(bases, key=lambda b: -size[b]))
if want:
    if want not in bases:
        print(f'🔴 指定的程序号 {want} 不在这些包里的本体中（有：{cand or "无"}）', file=sys.stderr); sys.exit(1)
    tid = want
elif len(bases) == 1:
    tid = next(iter(bases))
elif len(bases) > 1:
    top = sorted(bases, key=lambda b: -size[b])
    if size[top[0]] > 0 and size[top[0]] >= 4 * size[top[1]]:
        tid = top[0]
        print(f'🟡 文件夹里有 {len(bases)} 个本体，按内容大小认 {names[tid] or tid}（{tid}）是主游戏，跳过：{"、".join(f"{names[b] or b}（{b}）" for b in top[1:])}；要出别的用 --title-id', file=sys.stderr)
    else:
        print(f'🔴 本体应恰好 1 款，实际 {len(bases)} 款，判不出哪个是主游戏（{cand}）：用 --title-id <程序号> 指定要出哪一款，或一个文件夹只放一个游戏的本体 + 更新 + DLC', file=sys.stderr); sys.exit(1)
else:
    print('🔴 本体应恰好 1 款，实际 0 款（无）：一个文件夹只放一个游戏的本体 + 更新 + DLC', file=sys.stderr); sys.exit(1)
mine = [(f, x) for f, x in pk if x['baseId'] == tid]
base = next(x for _, x in mine if x['type'] == 'base')
upd = max((x['version'] for _, x in mine if x['type'] == 'update'), default=None)
# 真正跑的是最新更新里的程序（更新的 ExeFS 是完整的）：有的游戏本体 32 位、更新后 64 位（马车8 1.0 AArch32 → 4.0.1 AArch64）；更新读不出（unknown）才看本体
isa = next((x['guestIsa'] for _, x in mine if x['type'] == 'update' and x['version'] == upd and x['guestIsa'] != 'unknown'), base['guestIsa'])
if isa != 'aarch64':
    print(f'🔴 {base["name"]} 是 {isa} 程序，S2Arm 只跑 AArch64', file=sys.stderr); sys.exit(1)
disp = next((x['display'] for _, x in mine if x['type'] == 'update' and x['version'] == upd), base['display'])
other = sorted({x['baseId'] for _, x in pk} - {tid})
print(tid); print(base['name']); print(disp)
print(f'更新 {upd if upd is not None else "无"}，DLC {sum(1 for _, x in mine if x["type"] == "dlc")} 个' + (f'；别的游戏的更新 / DLC 不取：{" ".join(other)}' if other else ''))
for f in sorted({f for f, _ in mine}): print(f)

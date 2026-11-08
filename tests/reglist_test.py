#!/usr/bin/env python3
"""tools/reglist.py 单测（10-30 登记表按款拆目录）。期望手写：
  ① 合并：_表头.tsv（说明 + 表头）+ 各款文件数据行（款文件首行表头不重复），按文件名排序；定位表给出每行来自哪个文件第几行
  ② 写回：合并文本改一款的行 → 只有那款文件内容变；某款没有行了 → 删它的文件；程序号空 → _无程序号.tsv
  ③ migrate：旧单文件 → 目录，表头逐字一致、行一行不差，旧文件删除
  ④ 真数据结构（仓库里五个按款登记目录）：每个款文件首行 = _表头.tsv 的表头行；文件里每行程序号 = 文件名（写错文件门禁当场红）"""
import os, sys, tempfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, os.path.join(R, 'tools'))
import reglist
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"🟢" if ok else "🔴"} {name}' + ('' if ok else f'：期望「{want}」→ 真结果「{got}」'))

d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, 'docs'))
H = '# 说明\n程序号\t值\n'
open(os.path.join(d, 'docs', '名单_60帧.tsv'), 'w').write(H + '0100B\t2\n0100A\t1\n0100B\t3\n')
reglist.migrate(d)
chk('③ migrate 删旧文件、建目录', (False, ['0100A.tsv', '0100B.tsv', '_表头.tsv']),
    (os.path.exists(os.path.join(d, 'docs', '名单_60帧.tsv')), sorted(os.listdir(os.path.join(d, 'docs', '名单_60帧')))))
t, loc = reglist.read(d, '名单_60帧')
chk('① 合并文本：表头一次、按文件名排序、同款内顺序不变', H + '0100A\t1\n0100B\t2\n0100B\t3\n', t)
chk('① 定位：第 4 行 = 0100B.tsv 第 2 行', ('docs/名单_60帧/0100B.tsv', 2), loc[3])
fa = os.path.join(d, 'docs', '名单_60帧', '0100A.tsv'); ma = os.path.getmtime(fa); b0 = open(fa).read()
reglist.write(d, '名单_60帧', H + '0100A\t1\n0100B\t9\n\t无号\n')
chk('② 只改 0100B：0100A 内容不变、0100B 变、空程序号进 _无程序号.tsv', (b0, '程序号\t值\n0100B\t9\n', True),
    (open(fa).read(), open(os.path.join(d, 'docs', '名单_60帧', '0100B.tsv')).read(), os.path.exists(os.path.join(d, 'docs', '名单_60帧', '_无程序号.tsv'))))
reglist.write(d, '名单_60帧', H + '0100B\t9\n')
chk('② 0100A 没行了 → 删文件', False, os.path.exists(fa))
for n in reglist.TABLES:
    dd = os.path.join(R, reglist.dir_of(n))
    if not os.path.isdir(dd): chk(f'④ {n} 是按款登记目录', True, False); continue
    hl = [l for l in open(os.path.join(dd, reglist.HEAD), encoding='utf-8').read().splitlines() if l.strip() and not l.startswith('#')]
    hdr = hl[0] if hl else None; k = hdr.split('\t').index('程序号'); wrong = []
    for f in sorted(os.listdir(dd)):
        if f == reglist.HEAD or not f.endswith('.tsv'): continue
        L = [l for l in open(os.path.join(dd, f), encoding='utf-8').read().splitlines() if l.strip()]
        if not L or L[0] != hdr: wrong.append(f'{f} 首行不是表头'); continue
        want = '' if f == reglist.NOPID else f[:-4]
        wrong += [f'{f}：{l.split(chr(9))[k]}' for l in L[1:] if l.split('\t')[k].strip().upper() != want]
    chk(f'④ {n}：{len(os.listdir(dd)) - 1} 个款文件表头一致、行的程序号 = 文件名', [], wrong)
# ⑤ 旧单文件路径不许再被引用（10-30：拆目录时没改引用，docs/排查 手册 4 处指向不存在的 .tsv，triage_docs_test 在 main 红）。
#    tools/ tests/ 里的 docs/<表名>.tsv 是逻辑路径常量（reglist.name_of 映射到目录），审计快照与坑记录写的是当时的状态，不查
import re, subprocess
OLD = re.compile('名单_(?:' + '|'.join(re.escape(n[3:]) for n in reglist.TABLES) + r')\.tsv')
SKIP = ('tools/', 'tests/', 'docs/audit/', 'docs/坑')
stale = []
for f in subprocess.run(['git', '-C', R, '-c', 'core.quotepath=off', 'ls-files'], capture_output=True, text=True, check=True).stdout.splitlines():
    if f.startswith(SKIP) or not os.path.isfile(os.path.join(R, f)): continue
    try: body = open(os.path.join(R, f), encoding='utf-8').read()
    except (UnicodeDecodeError, OSError): continue
    stale += [f'{f}:{body.count(chr(10), 0, m.start()) + 1} {m.group(0)}' for m in OLD.finditer(body)]
chk('⑤ 仓库里没有对旧单文件登记表的引用（改写成 docs/<表名>/ 或 docs/<表名>/<程序号>.tsv）', [], stale)
print('reglist 单测全绿' if not bad else 'reglist 单测有红'); sys.exit(1 if bad else 0)

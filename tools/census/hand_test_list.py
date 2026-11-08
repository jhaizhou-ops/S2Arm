#!/usr/bin/env python3
"""待手测总清单（11-04 总指挥）：python3 tools/census/hand_test_list.py <输出.tsv> [--census <普查目录>]
  按各批普查总表算出「驾驶员没进局、要 jhz 手测」的款，写 <输出.tsv>（先写 <输出>.new 再改名，读的人不会读到半张表）。
  原先是运行区一支手跑脚本（待手测总清单_build.py），第二轮普查后没人重跑、清单停在 31 款 → 搬进仓库，每批收批由 tools/census/reg.sh 自动刷新。
  普查目录缺省 ${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/census（环境变量 CENSUS_DIR 可整条覆盖）；host.log 先找批次目录，
  再找工作盘普查目录 ${CENSUS_HDD_GLOB:-$S2A_RUNS}/<批名>（S2A_RUNS 由运行区 layout.env 给；都没有就只看批次目录本身）。
口径：
  ⓪ 只读批次类型为「主批 / 复判」的批（11-04 总指挥：实验批不算）。类型先读 <批次>/.census_batch 里的 type=（census.sh --type 起批时写），
     没有再查普查目录下 批次类型.tsv（老批一次性补登：批次<TAB>类型<TAB>依据）；都读不到 → 打一行【红】跳过这批，不默认算进
  ① 各批 c1*/总表.tsv 每款取最新一行（日期，同日按总表修改时间），最新一行进局了 = 移出
  ② 最新一行「一次成功」= 待手测，或「一次成功」空且结论通过、进局否 = 进
  ③ 结论不是通过的（失败款，归我们修）不进
  ④ 普查目录下 手测结果.tsv 里「手测」已填 是 / 否 的不进
排序：「局时用完」族排后（等驾驶员改完再说），族内按源GB（大作）优先。
暂缓（11-04 总指挥：暂缓不能靠手写状态，由规则算）：状态列写「暂缓：<原因>」、优先级「-」、排在最后，不进本批装机：
  ⑤ 在跑的主批 / 复判批（census.sh 进程在跑这个批次目录；单测用 CENSUS_ACTIVE=<批名,…> 指定）队列里有这款、它的总表还没这款的行 →「暂缓：<批> 还没判」
  ⑥ 最新一行那局带了存档起局（host.log 有「S2A 带存档起局：account / device」；11-04 普查主数字改为一律不带存档）→「暂缓：上次带存档跑，待不带存档复判」
重生成读回旧表（keep_state）：人写的状态 / 手测备注按程序号原样保留，规则缺省（待 / 待多手柄）与「暂缓：…」照新算；人手加的行（最近判定批空、没手测判定）留着。
标准输出第一行「待手测 <N> 款」，之后是读不到类型的批（每批一行【红】）、各族款数与手测已判数。"""
import collections, csv, glob, os, re, subprocess, sys

COLS = ['程序号', '款名', '最近判定批', '日期', '驾驶员没进局原因族', '族内款数', '手测备注', '源GB', 'host.log', '优先级', '状态']


def census_dir():
    return os.environ.get('CENSUS_DIR') or os.path.join(os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run'), 's2arm', 'census')


def read_tsv(p):
    with open(p, encoding='utf-8') as fh:
        return list(csv.DictReader(fh, delimiter='\t'))


OK_TYPES = ('主批', '复判')
TYPES = ('主批', '复判', '实验')


def batch_types(C):
    """老批补登表：普查目录下 批次类型.tsv（批次 / 类型 / 依据），没有这张表 = 空。"""
    p = os.path.join(C, '批次类型.tsv')
    return {r['批次']: r['类型'] for r in read_tsv(p)} if os.path.exists(p) else {}


def batch_type(d, b, table):
    """批次类型：<批次>/.census_batch 的 type= 优先，再查补登表；读不到 / 不认得 → None。"""
    try:
        with open(os.path.join(d, '.census_batch'), encoding='utf-8') as fh:
            for l in fh:
                if l.startswith('type='): t = l[5:].strip(); return t if t in TYPES else None
    except OSError: pass
    t = table.get(b)
    return t if t in TYPES else None


def load_rows(C, reds=None):
    rows = []; table = batch_types(C); reds = [] if reds is None else reds
    for p in sorted(glob.glob(os.path.join(C, 'c1*', '总表.tsv'))):
        b = p.split('/')[-2]; t = batch_type(os.path.dirname(p), b, table)
        if t is None:
            reds.append(f'【红】批次 {b} 读不到类型（.census_batch 没有 type=，批次类型.tsv 也没登记），跳过这批'); continue   # 缺类型不算进
        if t not in OK_TYPES: continue
        try: rd = read_tsv(p)
        except Exception: continue   # 在跑的批可能正写到一半
        for r in rd:
            if not r.get('键') or r.get('结论') is None: continue
            r['_b'] = b; r['_d'] = os.path.realpath(os.path.dirname(p)); r['_m'] = os.path.getmtime(p); rows.append(r)
    return rows


def load_manual(C):
    return {r['键'].upper(): r['手测'] for r in read_tsv(os.path.join(C, '手测结果.tsv'))}


def latest(rows):
    """口径①：每款取最新一行（日期，同日按总表修改时间）。"""
    by = collections.defaultdict(list)
    for r in rows: by[r['键'].upper()].append(r)
    out = {}
    for k, rs in by.items():
        rs.sort(key=lambda r: (r.get('日期') or '', r['_m']))
        out[k] = rs[-1]
    return out


def wanted(last, manual):
    """口径②③④：通过没进局（或一次成功 = 待手测）、手测还没判是 / 否。"""
    if not (last.get('一次成功') == '待手测' or (not last.get('一次成功') and last.get('结论') == '通过' and last.get('进局') == '否')): return False
    return manual not in ('是', '否')


def hostlog(r):
    k = r['键']
    hdd = os.environ.get('CENSUS_HDD_GLOB') or os.environ.get('S2A_RUNS') or ''
    for base in [r['_d']] + (glob.glob(os.path.join(hdd, r['_b'])) if hdd else []):
        for c in glob.glob(f'{base}/work/{k}/r/logs/{k}/host.log') + glob.glob(f'{base}/work/{k}/*/logs/{k}/host.log'):
            return c


def reason(r):
    h = hostlog(r)
    if not h: return '无日志', ''
    last = ''
    with open(h, encoding='utf-8', errors='replace') as fh:
        for l in fh:
            if l.startswith('自动玩家结论'): last = l.strip()
    if not last: return '无自动玩家结论', h
    m = re.search(r'没到 MARK；([^；]*)', last); s = (m.group(1) if m else last[:60]).strip()
    s = re.sub(r'离收局只剩 \d+ 秒[^）]*', '局时用完（离收局几十秒还在菜单）', s); s = s.replace('没给出回答', '没给出可用键')
    return s, h


def active_batches(C):
    """在跑的批次名集合：CENSUS_ACTIVE（逗号分隔）给了就用它；否则看本机有没有 census.sh 进程在跑 <普查目录>/<批名>。"""
    if os.environ.get('CENSUS_ACTIVE') is not None: return {b for b in os.environ['CENSUS_ACTIVE'].split(',') if b}
    try: ps = subprocess.run(['ps', '-axo', 'command='], capture_output=True, text=True).stdout
    except OSError: return set()
    return {m.group(1) for m in re.finditer(r'census/census\.sh \S*/(c1[^/\s]*)', ps)}


def pending(C, table):
    """⑤ 在跑的主批 / 复判批里还没判的款：键 → 批名。"""
    out = {}; act = active_batches(C)
    for b in sorted(act):
        d = os.path.join(C, b); t = batch_type(d, b, table)
        if t not in OK_TYPES: continue
        try: q = {r['键'].upper() for r in read_tsv(os.path.join(d, 'queue.tsv')) if r.get('键')}
        except OSError: continue
        try: done = {r['键'].upper() for r in read_tsv(os.path.join(d, '总表.tsv')) if r.get('键')}
        except OSError: done = set()
        for k in q - done: out.setdefault(k, b)
    return out


def saved_run(h):
    """⑥ 那局带存档起局了没有（服务层起局时打的「S2A 带存档起局：account / device ← …」）。"""
    if not h: return False
    with open(h, encoding='utf-8', errors='replace') as fh:
        return any(re.match(r'S2A 带存档起局：(account|device) ', l) for l in fh)


def gb(v):
    return float((v or '0').replace('-', '0') or 0)


def build(C, reds=None):
    man = load_manual(C); pend = pending(C, batch_types(C))
    out = []
    for k, last in latest(load_rows(C, reds)).items():
        if not wanted(last, man.get(k)): continue
        why, h = reason(last)
        hold = f'暂缓：{pend[k]} 还没判' if k in pend else '暂缓：上次带存档跑，待不带存档复判' if saved_run(h) else ''
        out.append([k, last.get('名称', ''), last['_b'], last.get('日期', ''), why, man.get(k, ''), last.get('源GB', ''), h or '', hold])
    fam = collections.Counter(o[4] for o in out)
    for o in out: o.insert(5, str(fam[o[4]]))
    # 总指挥 11-04 01:4x：A 族（局时用完）等驾驶员改完再说，jhz 先测其余族与待多手柄；族内按体量（大作）优先；暂缓的排最后
    out.sort(key=lambda o: (bool(o[9]), '局时用完' in o[4], -gb(o[7])))
    rows = []; n = 0
    for o in out:
        hold = o.pop()
        if hold: rows.append(o + ['-', hold])
        else: n += 1; rows.append(o + [str(n), '待多手柄' if o[6] == '待多手柄' else '待'])
    return rows, fam, sum(1 for v in man.values() if v in ('是', '否'))


RULE_STATES = ('待', '待多手柄')


def keep_state(path, rows, man):
    """读回旧表（11-05 总指挥：重生成没读回状态列，装机进度「已装 测试机2…」被冲成「待」）：按程序号把旧表的「状态 / 手测备注」并进新表。
    状态：旧值是人写的（不是规则缺省 待 / 待多手柄、不是规则算的「暂缓：…」）就原样保留；规则算的照新算（暂缓不能靠手写，11-04）。
    手测备注：手测结果.tsv 没给就沿用旧表。旧表里人手加的行（最近判定批为空）新表没有、手测结果也没判是 / 否 → 照留在末尾（例：等合入再出包的款）。"""
    try: old = {r['程序号'].upper(): r for r in read_tsv(path) if r.get('程序号')}
    except OSError: return rows
    si, bi = COLS.index('状态'), COLS.index('手测备注'); seen = set()
    for r in rows:
        o = old.get(r[0].upper()); seen.add(r[0].upper())
        if not o: continue
        st = o.get('状态', '')
        if st and st not in RULE_STATES and not st.startswith('暂缓：') and not r[si].startswith('暂缓：'): r[si] = st
        if not r[bi] and o.get('手测备注'): r[bi] = o['手测备注']
    for k, o in old.items():
        if k in seen or o.get('最近判定批') or man.get(k) in ('是', '否'): continue
        rows.append([o.get(c, '') for c in COLS])
    return rows


def write(path, rows):
    tmp = path + '.new'
    with open(tmp, 'w', encoding='utf-8') as fh:
        w = csv.writer(fh, delimiter='\t', lineterminator='\n')
        w.writerow(COLS); w.writerows(rows)
    os.replace(tmp, path)


def main(argv):
    args = argv[1:]; C = census_dir()
    if '--census' in args:
        i = args.index('--census'); C = args[i + 1]; del args[i:i + 2]
    if len(args) != 1: sys.exit('用法：hand_test_list.py <输出.tsv> [--census <普查目录>]')
    reds = []
    rows, fam, done = build(C, reds)
    write(args[0], keep_state(args[0], rows, load_manual(C)))
    print(f'待手测 {len(rows)} 款')
    for r in reds: print(r)
    print('各族：' + '；'.join(f'{k} {n}' for k, n in fam.most_common()))
    print(f'手测已判 {done}')


if __name__ == '__main__':
    main(sys.argv)

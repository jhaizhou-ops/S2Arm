#!/usr/bin/env python3
"""工作盘准入（11-06 总指挥：起单前就扣预计占用；packq 有准入后，天眼回传 / 普查本机打包 / 手测包照样绕过它，15 分钟 118 → 73G）。
写工作盘的大单都经这里排同一本账：剩余 − 账内活着的预留 − 本单预计 ≥ 最低余量，才放行；不够就排队等。
  python3 tools/disk_admit.py run --cat <类别> --name <名> [--gb <预计>] [--measure <输出目录>] -- <命令…>
      排到再跑命令；结束按 --measure 目录的实占（APFS 独占字节，克隆不计）记成这个名字下次的预计。退出码 = 命令的退出码；--max-wait 等满还排不上退 75
  python3 tools/disk_admit.py status        打账（谁预留了多少）与剩余
  库：hold(cat, name, gb=None, measure=None) 上下文；reserve / release / admissible / est_gb（packq.py 用）
账本 = S2A_DISK_DIR（缺省 <运行区>/locks/disk）：use.<pid>.<序号>（JSON：进程号 + 启动时刻 + 预留 GB + 类别 / 名），进程不在或启动时刻对不上即作废；
  est.tsv（名 / 实测 GB / 类别，取最后一行；新名字按同类别最近一次实测，都没有才用缺省）。判断与登记在同一把文件锁（.lock，flock）里做，两家不会同时挤进去。
账内一单只算「还没写的」：max(0, 预留 − 实测目录已写)（11-06 准入卡单：已写进盘的字节剩余里已扣过一次，预留再扣一次 = 死账，dev34 写 28G 仍挂 5G、写满 21G 的天眼单仍挂 40G）。
外层预留里提的 packq 单（11-06 手测外壳预留 40G 后提单，packq 单又按 40G 排、被外壳自己挡住；执行器不是外层的子孙，S2A_DISK_HELD 管不到）：
  run 把本单预留路径经 S2A_DISK_HOLD 交给子孙，packq 提单记进单子（hold），执行器排队 / 开工时以 parent 带上 → 记为子单；一组只算 max(外层剩余, 子单剩余之和)，不叠加。
--work-only（入口闸用）：--measure 目录不在本机工作盘（S2A_DISK_WORK，缺省运行区 roots 所在卷）上、或本机没有工作盘 → 直接跑、不记账。
按卷记账（11-06）：实测目录在别的卷上（内置盘溢出）就记在那一卷的账上，保底 S2A_DISK_MIN_FREE_SYS_GB（缺省 60）；两本账互不相挤。
最低余量 S2A_DISK_MIN_FREE_GB、缺省预计 S2A_DISK_EST_GB：环境变量优先，再读上限表 env/layout.env，再退回 packq 同名旧键（S2A_PACKQ_*），缺省 50 / 40。
工作盘 = 运行区 roots 软链指向的卷；单测用 S2A_DISK_FREE_GB 给剩余。S2A_DISK_ADMIT=off 整个跳过（应急总开关，打一行【黄】）。
嵌套：run 给子进程设 S2A_DISK_HELD=1；环境里已有它时 reserve / hold / run 不再排队记账（外层那一笔就是本单的预留）。"""
import argparse, fcntl, json, os, subprocess, sys, time

RUN = os.path.join(os.environ.get('S2A_RUN_ROOT', os.path.expanduser('~/.s2arm/run')), 's2arm')
DIR = os.environ.get('S2A_DISK_DIR', os.path.join(RUN, 'locks', 'disk'))


def lay(k, d):
    if os.environ.get(k): return os.environ[k]
    try:
        for ln in open(os.environ.get('S2A_LAYOUT_ENV', os.path.join(RUN, 'env', 'layout.env')), encoding='utf-8'):
            ln = ln.split('#', 1)[0].strip()
            if ln.startswith('export ' + k + '='): return ln.split('=', 1)[1].strip().strip('"')
    except OSError: pass
    return d


def min_free(vol='work'):   # 工作盘保底 S2A_DISK_MIN_FREE_GB（缺省 50）；别的卷（内置盘溢出）保底 S2A_DISK_MIN_FREE_SYS_GB（缺省 60，留给系统）
    if vol != 'work': return float(lay('S2A_DISK_MIN_FREE_SYS_GB', '60'))
    return float(lay('S2A_DISK_MIN_FREE_GB', lay('S2A_PACKQ_MIN_FREE_GB', '50')))
def def_est(): return float(lay('S2A_DISK_EST_GB', lay('S2A_PACKQ_EST_GB', '40')))


def _dev(path):   # 路径所在卷的设备号（路径还没建就往上找存在的祖先）；取不到 None
    p = os.path.abspath(path)
    while not os.path.exists(p) and os.path.dirname(p) != p: p = os.path.dirname(p)
    try: return os.stat(os.path.realpath(p)).st_dev
    except OSError: return None


def work_dev(): return _dev(os.environ.get('S2A_DISK_WORK') or os.path.join(RUN, 'roots'))


def vol_of(measure):   # 按卷记账（11-06 总指挥：S2A_2T 满、内置盘空 244G，主线回归 reg16 0 款出包）：实测目录在别的卷上（内置盘）就记在那一卷的账上，
    #   没有实测目录 / 判不出卷 / 就在工作盘上 → 'work'（工作盘那本账，与原来相同）
    if not measure: return 'work'
    d, w = _dev(measure), work_dev()
    return 'work' if d is None or w is None or d == w else str(d)


def free_gb(where=None):   # where = 别的卷上的实测目录（缺省工作盘）
    if where and vol_of(where) != 'work':
        v = os.environ.get('S2A_DISK_FREE_OTHER_GB')
        if v: return float(v)
        st = os.statvfs(_existing(where)); return st.f_bavail * st.f_frsize / 2**30
    v = os.environ.get('S2A_DISK_FREE_GB')
    if v: return float(v)
    st = os.statvfs(os.path.realpath(os.path.join(RUN, 'roots'))); return st.f_bavail * st.f_frsize / 2**30


def _existing(path):
    p = os.path.abspath(path)
    while not os.path.exists(p) and os.path.dirname(p) != p: p = os.path.dirname(p)
    return p


def caller_env():   # 子进程拿调用方原样的区域（11-06 一次成功线：手测脚本经本工具重起后 `装测试机$DEV）` 报 DEV�: unbound variable）
    # Python 3.7+ 在区域为 C 时把 LC_CTYPE=C.UTF-8 写进自己的环境（PEP 538 区域强转），子进程会继承；
    #   macOS 的 bash 在任何 UTF-8 区域下把紧跟变量名的全角字首字节读进变量名，C 区域下不会。调用方原本没有它，就别带给子进程
    e = dict(os.environ)
    if e.get('LC_CTYPE') == 'C.UTF-8' and not e.get('LC_ALL') and not e.get('LANG'): e.pop('LC_CTYPE')
    return e


def on_work(path):   # 写入目标是否落在本机工作盘上（11-06 列车退回 ssh_argv_test：dev_run.sh 在 mini 远端根里跑，那边没有运行区 roots，statvfs 抛错、局没起）
    w = os.environ.get('S2A_DISK_WORK') or os.path.join(RUN, 'roots')
    try: wd = os.stat(os.path.realpath(w)).st_dev
    except OSError: return False   # 本机没有工作盘（远端主机 / 单测假根）：不归这本账管
    p = os.path.abspath(path)
    while not os.path.exists(p) and os.path.dirname(p) != p: p = os.path.dirname(p)
    try: return os.stat(p).st_dev == wd
    except OSError: return False


def lstart(pid):
    # 固定 C 区域（11-06：中文区域调用方读到「五 11月/ 6 04:41:03」，与英文区域写的记录对不上，把活着的金刚 c3 / 手测外壳预留当死单删了）
    r = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True, env=dict(os.environ, LC_ALL='C'))
    return ' '.join(r.stdout.split())


def live(kind='use.'):   # [(路径, 记录)]：进程还在、启动时刻对得上的预留（kind='wait.' 取排队号）
    out = []
    try: names = os.listdir(DIR)
    except OSError: return out
    for n in names:
        if not n.startswith(kind): continue
        p = os.path.join(DIR, n)
        try: r = json.load(open(p, encoding='utf-8'))
        except (OSError, ValueError): continue
        if r.get('pid') and lstart(r['pid']) == r.get('lstart'): out.append((p, r))
        else:
            try: os.unlink(p)
            except OSError: pass
    return out


_DU = {}
def written_gb(d):   # 实测目录已写多少（du_gb 独占字节，60 秒内复用，执行器每轮都要判）
    if not d or not os.path.exists(d): return 0.0
    t, v = _DU.get(d, (0, None))
    if v is None or time.time() - t > 60: v = du_gb(d) or 0.0; _DU[d] = (time.time(), v)
    return v


def remaining(r): return max(0.0, r['gb'] - written_gb(r.get('measure')))


def held_gb(L, extra=None):   # 账内合计：同一组（外层 + 它的子单）只算 max(外层剩余, 子单剩余之和)；extra = (外层路径, GB) 试算再加一单子单
    paths = {p for p, _ in L}; top, kids = {}, {}
    for p, r in L:
        par = r.get('parent')
        if par in paths and par != p: kids[par] = kids.get(par, 0.0) + remaining(r)
        else: top[p] = remaining(r)
    if extra:
        par, gb = extra
        if par in paths: kids[par] = kids.get(par, 0.0) + gb
        else: top[None] = top.get(None, 0.0) + gb
    return sum(max(top.get(k, 0.0), kids.get(k, 0.0)) for k in set(top) | set(kids))


def p80(v):   # 最近 20 次的第 80 百分位（向上取整那一位，不插值）
    v = sorted(v[-20:]); return v[min(len(v) - 1, -(-len(v) * 4 // 5) - 1)]


def est_gb(cat, name):
    """预计：本名最近一次实测 → 同类别最近 20 次实测的 p80 → 全部类别最近 20 次的 p80 → 缺省。
    11-06 Switch2 线：新名字一律吃缺省 40G、实际只写几 G。11-07 总指挥：原先「同类最近一次」被最后一条 27.5G 带偏，
    之后的新真机局全按 28G 排（239 条实测 156 条 ≤5G）；改 p80 不用中位数——中位数让一半的局低估，准入就失去意义"""
    e, ec, ea = {}, {}, []
    try:
        for ln in open(os.path.join(DIR, 'est.tsv'), encoding='utf-8'):
            c = ln.rstrip('\n').split('\t')
            if len(c) >= 2:
                try: v = float(c[1])
                except ValueError: continue
                e[c[0]] = v; ea.append(v)
                if len(c) >= 3 and c[2]: ec.setdefault(c[2], []).append(v)
    except OSError: pass
    if name in e: return e[name]
    if ec.get(cat): return p80(ec[cat])
    return p80(ea) if ea else def_est()


def _vol(r): return r.get('vol') or 'work'   # 旧记录没有卷号 = 工作盘


def ahead_gb(t, vol='work'):   # 同一卷上比 t 先排队、还在等的单的需求合计（先来先得：后来的单要把它们也算上；t=None 算全部）
    return sum(r['gb'] for _, r in live('wait.') if _vol(r) == vol and (t is None or r.get('t', 0) < t))


def bf_limits(): return float(lay('S2A_DISK_BACKFILL_GB', '2')), float(lay('S2A_DISK_BACKFILL_CAP_GB', '5'))


def admissible_bf(need, parent=None, t=None, where=None):   # → (放行?, 剩余, 账内（含先排队的需求）, 最低, 本单实际要加的 GB, 是否回填)
    """有界回填（11-07 总指挥拍板）：先来先得下队首大单等空间时，≤ S2A_DISK_BACKFILL_GB（缺省 2）的小单可越过排队者先跑——只要不算排队者也够；
    同卷同时在跑的回填单预留合计（含本单）不超过 S2A_DISK_BACKFILL_CAP_GB（缺省 5）：大单最多晚拿到 5G、不会被饿死，小单也不陪大单干等
    （11-07 01:3x：3 张 1G 真机局排在 28G 单后 7–10 分钟）"""
    vol = vol_of(where); f = free_gb(where); L = [x for x in live() if _vol(x[1]) == vol]
    held = held_gb(L); add = held_gb(L, (parent, need)) - held; ahead = ahead_gb(t, vol); m = min_free(vol)
    if f - held - ahead - add >= m: return True, f, held + ahead, m, add, False
    bmax, bcap = bf_limits()
    bf = ahead > 0 and add <= bmax and sum(r['gb'] for _, r in L if r.get('bf')) + add <= bcap and f - held - add >= m
    return bf, f, (held if bf else held + ahead), m, add, bf


def admissible(need, parent=None, t=None, where=None):   # → (放行?, 剩余, 账内（含先排队的需求）, 最低, 本单实际要加的 GB)；where = 实测目录（定记在哪一卷）
    return admissible_bf(need, parent, t, where)[:5]


def reserve(cat, name, gb=None, pid=None, wait=True, poll=30, max_wait=None, measure=None, parent=None, t=None, log=lambda s: print(s, file=sys.stderr, flush=True)):
    """返回预留文件路径；排不上且不等 / 等满 → None。parent = 外层预留路径（packq 执行器从单子的 hold 带上），本单记成它的子单。
    先来先得（11-06 Windows 线：金刚 c3 回传按 30 秒轮询，空位反复被后到的新单先拿走，排了 1 个半小时）：要等时登记排队号 wait.<pid>.<序号>（t = 开始排的时刻），
    之后到的单判余量时把先排队的需求也算上；t 缺省为进来的时刻（packq 执行器传提单时刻）"""
    if os.environ.get('S2A_DISK_ADMIT') == 'off':
        log('【黄】工作盘准入已关（S2A_DISK_ADMIT=off）：不排队直接跑'); return None
    if os.environ.get('S2A_DISK_HELD'):   # 外层已在准入里（11-06 金刚 c3：外层 run 记 40G、里面天眼道 hold 同一单又排 40G，自己挡自己；普查重跑批跟着卡在准入）：同一单只记一笔，不再排队
        log(f'工作盘准入：{cat}/{name} 外层已预留，不重复记账'); return None
    os.makedirs(DIR, exist_ok=True); need = est_gb(cat, name) if gb is None else float(gb); pid = pid or os.getpid(); t0 = time.time(); said = False
    t = t if t is not None else t0; tk = None
    try:
        while True:
            with open(os.path.join(DIR, '.lock'), 'a') as lk:
                fcntl.flock(lk, fcntl.LOCK_EX)
                ok, f, held, m, add, bf = admissible_bf(need, parent, t, measure); vol = vol_of(measure)
                if ok:
                    p = os.path.join(DIR, f'use.{pid}.{time.time_ns()}')
                    json.dump({'pid': pid, 'lstart': lstart(pid), 'gb': need, 'cat': cat, 'name': name, 't0': time.time(), 'free0': f,
                               'measure': os.path.abspath(measure) if measure else None, 'parent': parent, 'vol': vol, 'bf': bf}, open(p, 'w', encoding='utf-8'))
                    if bf: log(f'工作盘准入：{cat}/{name} 回填先跑（{add:.0f}G ≤ 回填单上限，越过排队的大单；同时在跑的回填合计不超过回填总上限）')
                    if said: log(f'工作盘准入：{cat}/{name} 排到（{"工作盘" if vol == "work" else "内置盘"}剩 {f:.0f}G − 账内 {held:.0f}G − 本单 {add:.0f}G ≥ {m:.0f}G）')
                    return p
                if wait and tk is None:
                    tk = os.path.join(DIR, f'wait.{pid}.{time.time_ns()}')
                    json.dump({'pid': pid, 'lstart': lstart(pid), 'gb': add, 'cat': cat, 'name': name, 't': t, 'vol': vol}, open(tk, 'w', encoding='utf-8'))
            if not wait or (max_wait is not None and time.time() - t0 >= max_wait): log(f'【红】工作盘准入：{cat}/{name} 排不上（{"工作盘" if vol == "work" else "内置盘"}剩 {f:.0f}G − 账内与先排队 {held:.0f}G − 本单 {add:.0f}G < {m:.0f}G）'); return None
            if not said: log(f'【排队】工作盘准入：{cat}/{name} 等（{"工作盘" if vol == "work" else "内置盘"}剩 {f:.0f}G − 账内与先排队 {held:.0f}G − 本单预计 {add:.0f}G < 最低 {m:.0f}G）'); said = True
            time.sleep(poll)
    finally:
        if tk:
            try: os.unlink(tk)
            except OSError: pass


def _priv_fn():   # APFS 文件独占字节（不与克隆共享的块）：getattrlist(ATTR_CMNEXT_PRIVATESIZE)；不是 macOS / 调不起 → None
    try:
        import ctypes, struct
        libc = ctypes.CDLL(None, use_errno=True); libc.getattrlist
    except (OSError, AttributeError): return None
    class AL(ctypes.Structure):
        _fields_ = [(n, t) for n, t in (('bitmapcount', ctypes.c_ushort), ('reserved', ctypes.c_uint16), ('commonattr', ctypes.c_uint32),
                    ('volattr', ctypes.c_uint32), ('dirattr', ctypes.c_uint32), ('fileattr', ctypes.c_uint32), ('forkattr', ctypes.c_uint32))]
    al = AL(5, 0, 0, 0, 0, 0, 0x8); buf = ctypes.create_string_buffer(16)   # forkattr 0x8 = ATTR_CMNEXT_PRIVATESIZE（配 FSOPT_ATTR_CMN_EXTENDED）
    def f(p):
        if libc.getattrlist(os.fsencode(p), ctypes.byref(al), buf, 16, 0x1 | 0x20) != 0: return None   # FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED
        return struct.unpack_from('<Iq', buf.raw)[1]
    return f


_PRIV = _priv_fn()
_PM = {}   # du_gb 的进程内记忆：目录 → {(设备, inode, 修改时刻, 大小): 独占字节}


def du_gb(d):
    """目录实占 GB：按 APFS 独占字节累加（11-07 总指挥：真机局作业目录 cp -cR 了资源包 pack/，克隆几乎不占盘，du 却按满额算，
    est.tsv 一半真机局记成 27.5G → p80 让新局一律按 28G 排、6 个真机局全堵）。克隆来的输入记 0，新写的、改写过的块照记。
    独占读不到的文件（非 APFS / 非 macOS）按分配块（st_blocks）算，等同原来的 du。局限：目录内部互相克隆的文件，共享那部分不计（真机局 / 出包里罕见）"""
    if not os.path.exists(d): return None
    # 进程内按文件记忆（11-07：读独占字节要逐文件数共享块，天眼回传目录 18.7 万文件 8.5 秒、du 1.2 秒；packq 执行器每轮重算在跑单的目录）：
    #   键 = (设备, inode, 修改时刻, 大小)，文件没变就不再读独占字节；每次只留本次走到的文件，记忆不随删掉的文件涨。
    #   局限：克隆源被删后本文件独占会变大而键不变，记忆偏小——只让「已写」偏小、剩余预留偏大，准入方向是保守的
    t, old, new = 0, _PM.get(d, {}), {}
    for r, _, fs in os.walk(d):
        for n in fs:
            p = os.path.join(r, n)
            try: st = os.lstat(p)
            except OSError: continue
            k = (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size)
            v = old.get(k)
            if v is None:
                v = _PRIV(p) if _PRIV else None
                if v is None: v = st.st_blocks * 512
            new[k] = v; t += v
    _PM[d] = new
    return t / 2**30


def release(p, name=None, measured=None, cat=None):   # est.tsv 一行：名 / 实测 GB / 类别（类别给新名字作预计）
    if measured is not None and name:
        os.makedirs(DIR, exist_ok=True)
        with open(os.path.join(DIR, 'est.tsv'), 'a', encoding='utf-8') as f: f.write(f'{name}\t{max(measured, 1.0):.1f}\t{cat or ""}\n')
    if p:
        try: os.unlink(p)
        except OSError: pass


class hold:
    def __init__(self, cat, name, gb=None, measure=None, **kw): self.a = (cat, name, gb); self.measure = measure; self.kw = kw; self.p = None
    def __enter__(self): self.p = reserve(*self.a, measure=self.measure, **self.kw); return self.p
    def __exit__(self, *e): release(self.p, self.a[1], du_gb(self.measure) if self.measure and os.path.exists(self.measure) else None, self.a[0])


def main(argv):
    if argv[:1] == ['status']:
        f = free_gb(); L = live(); LW = [x for x in L if _vol(x[1]) == 'work']; print(f'工作盘剩 {f:.0f}G，最低 {min_free():.0f}G，账内 {len(LW)} 单 {held_gb(LW):.0f}G（只算还没写的，嵌套不叠加）')
        for m0 in sorted({r.get('measure') for _, r in L if _vol(r) != 'work'} - {None})[:1]:
            LO = [x for x in L if _vol(x[1]) != 'work']; print(f'内置盘（溢出卷）剩 {free_gb(m0):.0f}G，最低 {min_free("other"):.0f}G，账内 {len(LO)} 单 {held_gb(LO):.0f}G')
        for p, r in L: print(f"  {'[内置盘] ' if _vol(r) != 'work' else ''}{r['cat']}/{r['name']}\t预留 {r['gb']:.0f}G 已写 {written_gb(r.get('measure')):.0f}G\tpid {r['pid']}\t{int(time.time() - r['t0'])} 秒{'（回填）' if r.get('bf') else ''}" + ('\t子单' if r.get('parent') in {q for q, _ in L} else ''))
        for _, r in sorted(live('wait.'), key=lambda x: x[1].get('t', 0)): print(f"  排队 {r['cat']}/{r['name']}\t要 {r['gb']:.0f}G\tpid {r['pid']}\t等了 {int(time.time() - r['t'])} 秒")
        return 0
    if argv[:1] != ['run'] or '--' not in argv: sys.exit(__doc__)
    i = argv.index('--'); ap = argparse.ArgumentParser(prog='disk_admit.py run')
    ap.add_argument('--cat', required=True); ap.add_argument('--name', required=True); ap.add_argument('--gb', type=float)
    ap.add_argument('--measure'); ap.add_argument('--work-only', action='store_true'); ap.add_argument('--max-wait', type=float); ap.add_argument('--poll', type=float, default=30)
    a = ap.parse_args(argv[1:i]); cmd = argv[i + 1:]
    if not cmd: sys.exit('-- 后面要有命令')
    e = caller_env(); e['S2A_DISK_HELD'] = e.get('S2A_DISK_HELD') or '1'   # 子孙里的 hold / run / 入口闸都认它：本单已在账上（或不归这本账管），不再排队
    if a.work_only and not (a.measure and on_work(a.measure)): return subprocess.call(cmd, env=e)   # 入口闸：写的不是本机工作盘 → 不排队、不记账，直接跑
    p = reserve(a.cat, a.name, a.gb, wait=True, poll=a.poll, max_wait=a.max_wait, measure=a.measure)
    if p is None and os.environ.get('S2A_DISK_ADMIT') != 'off' and not os.environ.get('S2A_DISK_HELD'): return 75
    if p: e['S2A_DISK_HOLD'] = p   # 子孙提的 packq 单记成本单的子单（执行器按组算，不叠加）
    try: rc = subprocess.call(cmd, env=e)
    finally: release(p, a.name, du_gb(a.measure) if a.measure and os.path.exists(a.measure) else None, a.cat)
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

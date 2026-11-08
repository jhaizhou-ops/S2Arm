#!/usr/bin/env python3
"""pack/orch/oneclick_win.py 直连缓存（11-06 出包速度线：天眼常驻直连缓存）单测：python3 tests/oneclick_win_dcache_test.py
直连库脚本换成替身（记下拿到的 S2A_DIRECT_CACHE，往缓存里写一条仓条目 + logs/direct_fail.log），淘汰跑真的 tools/direct_cache_lru.py；期望按 direct() 头注手写：
  ① 不设 S2A_DIRECT_CACHE_ROOT → 缓存 = <工作目录>/dcache（同改前）；不走锁、不淘汰
  ② 设 S2A_DIRECT_CACHE_ROOT → 缓存 = <根>/<程序号大写>；本次 logs/ 拷回 <工作目录>/dcache/logs（天眼道拉 direct_fail.log 的路径不变）；单结束后仓条目还在
  ③ 同时设 S2A_DIRECT_CACHE → 整条路径优先，不用根
  ④ 同款锁：别的进程拿着 <根>/<程序号>.lock → title_lock(wait=False) 拿不到；那个进程退出（被杀）→ 拿得到
  ⑤ 淘汰预算 0：别的进程正拿锁的款、本款都不动；没人拿锁的款仓条目删掉
  ⑥ 直连库失败：退出码照抛，logs/ 照样拷回，锁放掉"""
import os, subprocess, sys, tempfile, time
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R))
from pack.orch import oneclick_win as ow   # noqa: E402

bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

TID = '0100ABCD00001000'
seen = {}
real_sh = ow.Run.sh
def fake_sh(self, args, log, env=None, ok=(0,), cwd=None):
    if log != 'direct_lib.log': return real_sh(self, args, log, env, ok, cwd)
    c = Path(env['S2A_DIRECT_CACHE']); seen['c'] = c
    (c / 'store' / 'ab').mkdir(parents=True, exist_ok=True); (c / 'store' / 'ab' / 'x.e').write_bytes(b'e' * 100)
    (c / 'logs').mkdir(parents=True, exist_ok=True); (c / 'logs' / 'direct_fail.log').write_text(seen.get('tag', 'ok'), encoding='utf-8')
    if seen.get('fail'): raise ow.Fail('direct_lib.log：rc=1；替身失败', 1)
    return 0
ow.Run.sh = fake_sh

def holder(lock):   # 另起一个进程拿住锁，直到被杀
    code = f'import fcntl,time;f=open({str(lock)!r},"a+b");fcntl.flock(f.fileno(),fcntl.LOCK_EX);print("ok",flush=True);time.sleep(600)'
    p = subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.PIPE, text=True); p.stdout.readline(); return p

def steps(out): return [l.split('\t')[0] for l in (out / 'timing.tsv').read_text(encoding='utf-8').splitlines()]

with tempfile.TemporaryDirectory() as t:
    t = Path(t); cur = t / 'cur'; cur.mkdir()
    for k in ('S2A_DIRECT_CACHE', 'S2A_DIRECT_CACHE_ROOT', 'S2A_PSO_SOURCES', 'S2A_PSO_KNOW'): os.environ.pop(k, None)

    run = ow.Run(t / 'o1'); ow.direct(run, cur, 'ios', 2, TID.lower())
    chk('① 不设根：缓存在工作目录', str(t / 'o1' / 'dcache'), str(seen['c']))
    chk('① 不设根：不走锁 / 淘汰', False, any(s in steps(t / 'o1') for s in ('等同款直连缓存锁', '直连缓存淘汰')))

    root = t / 'root'; os.environ['S2A_DIRECT_CACHE_ROOT'] = str(root); seen['tag'] = 'job2'
    run = ow.Run(t / 'o2'); ow.direct(run, cur, 'ios', 2, TID.lower())
    chk('② 设根：缓存 = 根/程序号大写', str(root / TID), str(seen['c']))
    chk('② 日志拷回工作目录', 'job2', (t / 'o2' / 'dcache' / 'logs' / 'direct_fail.log').read_text(encoding='utf-8'))
    chk('② 单结束后仓条目还在', True, (root / TID / 'store' / 'ab' / 'x.e').is_file())
    chk('② 计时表有锁与淘汰两步', ['等同款直连缓存锁', '直连缓存淘汰'], [s for s in steps(t / 'o2') if s in ('等同款直连缓存锁', '直连缓存淘汰')])

    os.environ['S2A_DIRECT_CACHE'] = str(t / 'explicit')
    run = ow.Run(t / 'o3'); ow.direct(run, cur, 'ios', 2, TID.lower())
    chk('③ 整条路径优先', str(t / 'explicit'), str(seen['c'])); os.environ.pop('S2A_DIRECT_CACHE')

    lk = root / f'{TID}.lock'; p = holder(lk)
    chk('④ 别的进程拿着锁 → 拿不到', None, ow.title_lock(lk, wait=False))
    p.kill(); p.wait(); f = ow.title_lock(lk, wait=False)
    chk('④ 那个进程被杀 → 拿得到', True, f is not None); f.close()

    for tid in ('0100B00000001000', '0100C00000001000'):
        (root / tid / 'store' / 'cd').mkdir(parents=True); (root / tid / 'store' / 'cd' / 'y.e').write_bytes(b'y' * 100)
        os.utime(root / tid / 'store' / 'cd' / 'y.e', (time.time() - 86400, time.time() - 86400))
    p = holder(root / '0100B00000001000.lock')
    os.environ['S2A_DIRECT_CACHE_BUDGET_GB'] = '0'
    run = ow.Run(t / 'o5'); ow.direct(run, cur, 'ios', 2, TID.lower())
    p.kill(); p.wait(); os.environ.pop('S2A_DIRECT_CACHE_BUDGET_GB')
    chk('⑤ 别的进程拿锁的款不动', True, (root / '0100B00000001000' / 'store' / 'cd' / 'y.e').is_file())
    chk('⑤ 本款不动', True, (root / TID / 'store' / 'ab' / 'x.e').is_file())
    chk('⑤ 没人拿锁的款删掉', False, (root / '0100C00000001000' / 'store' / 'cd' / 'y.e').is_file())

    seen['fail'] = True; seen['tag'] = 'job6'
    run = ow.Run(t / 'o6')
    try: ow.direct(run, cur, 'ios', 2, TID.lower()); got = None
    except ow.Fail as e: got = e.code
    chk('⑥ 失败退出码照抛', 1, got)
    chk('⑥ 失败也拷回日志', 'job6', (t / 'o6' / 'dcache' / 'logs' / 'direct_fail.log').read_text(encoding='utf-8'))
    f = ow.title_lock(lk, wait=False); chk('⑥ 失败后锁放掉', True, f is not None); f and f.close()

print('全通' if not bad else f'{bad} 项不通'); sys.exit(1 if bad else 0)

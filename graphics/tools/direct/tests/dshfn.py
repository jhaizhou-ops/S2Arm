#!/usr/bin/env python3
# 单测共用：调 S2A.Dsh（graphics/tools/direct/dsh）的 C# 改写函数（dsh_cmp --fn，入口表在 dsh_cmp/Fn.cs）。直连着色器改写只有 C# 一份实现（不维护 Python 第二份）。
#   dll()：DSH_CMP_DLL 指定就用它；否则在 dsh_cmp/ 下 dotnet build -c Release（增量，持锁，与出包 dsh_batch 的构建及并发单测不互踩 S2A.Dsh 的 obj/）
#   batch([(名, [参数…]), …], nxgal=None) → 每例 {"ok": 值} | {"err": 类名}（值的形状见 Fn.cs 文件头：元组 → 列表）
#   fn(名, *参数, nxgal=None) → 值；C# 抛异常时抛 DshFnError(类名)。nxgal = libnxgal.dylib（spill_fix / color_round 等要它）
import fcntl, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '../../../..'))
PROJ = os.path.join(HERE, 'dsh_cmp', 'dsh_cmp.csproj'); OUT = os.path.join(HERE, 'dsh_cmp', 'bin', 'Release', 'net10.0', 'dsh_cmp.dll')
NXGAL = os.path.join(ROOT, 'build', 'gal', 'libnxgal.dylib')


class DshFnError(Exception):
    pass


def dotnet():
    d = os.environ.get('DOTNET') or os.path.expanduser('~/.dotnet/dotnet')
    return d if os.access(d, os.X_OK) else (shutil.which('dotnet') or d)


_dll = None
def dll():
    global _dll
    if _dll: return _dll
    if os.environ.get('DSH_CMP_DLL'):
        _dll = os.environ['DSH_CMP_DLL']; return _dll
    lkd = os.path.join(ROOT, 'build', 'dsh_batch'); os.makedirs(lkd, exist_ok=True)
    with open(os.path.join(lkd, '.lock'), 'w') as lk:   # 同出包 dmsh_build.py dsh_batch() 那把锁：两边都编 S2A.Dsh 工程、共用它的 obj/
        fcntl.flock(lk, fcntl.LOCK_EX)
        sys.path.insert(0, os.path.join(ROOT, 'translator')); import dsh_batch   # 按源内容判重编、不信时间戳（同 dsh_batch.build，见 src_digest）
        dg = dsh_batch.src_digest(PROJ); stamp = os.path.join(os.path.dirname(OUT), '.src_digest'); last = open(stamp).read().strip() if os.path.exists(stamp) else ''
        r = subprocess.run([dotnet(), 'build', PROJ, '-c', 'Release', '-nodeReuse:false', '-v', 'q', '-m:' + os.environ.get('S2A_CPU_GATE', '6'), *([] if dg == last else ['--no-incremental'])],
                           capture_output=True, text=True)
        if not r.returncode and os.path.exists(OUT): open(stamp, 'w').write(dg + '\n')
    if r.returncode or not os.path.exists(OUT):
        err = next((l for l in r.stdout.splitlines() if ' error ' in l), r.stdout[-300:] + r.stderr[-300:])
        raise SystemExit(f'✗ dsh_cmp 编不过（dotnet build {PROJ}）：{err.strip()[:300]}')
    _dll = OUT; return _dll


def batch(cases, nxgal=None):
    with tempfile.TemporaryDirectory(prefix='dshfn_') as t:
        ci, co = os.path.join(t, 'cases.json'), os.path.join(t, 'res.json')
        with open(ci, 'w') as f: json.dump([{'fn': n, 'args': list(a)} for n, a in cases], f)
        cmd = [dotnet(), dll(), '--fn', ci, co] + (['--nxgal', os.path.abspath(nxgal)] if nxgal else [])
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode or not os.path.exists(co): raise SystemExit(f'✗ dsh_cmp --fn 失败（退出 {r.returncode}）：{(r.stdout + r.stderr).strip()[-400:]}')
        with open(co) as f: res = json.load(f)
    if len(res) != len(cases): raise SystemExit(f'✗ dsh_cmp --fn 结果数 {len(res)} ≠ 用例数 {len(cases)}')
    return res


def fn(name, *args, nxgal=None):
    r = batch([(name, args)], nxgal)[0]
    if 'ok' not in r: raise DshFnError(r.get('err'))
    return r['ok']

# 阶段真实输入记录钩子（tools/stage_deps.py 的采集端，10-30 出包线）：阶段导出 S2A_DEPS_OUT=<目录> 并把本目录放到 PYTHONPATH 最前，
#   阶段里每个 Python 进程（含 `python3 -c`、后加的生成器）启动时自动装审计钩子，退出时写 <目录>/<pid>-<纳秒>.tsv：
#   f <路径> = 读过的文件（open 只读打开 + 退出时 sys.modules 里每个模块的源文件：有 .pyc 时导入不打开 .py，只看 open 会漏）
#   d <路径> = 列过的目录（os.listdir / os.scandir；glob、os.walk 都走 scandir）
#   w <路径> = 写过的文件（同一阶段自己写再读的不算输入）
#   没设 S2A_DEPS_OUT = 什么都不做。只记位置，内容哈希由 stage_deps.py collect 统一算
import os
import sys

_OUT = os.environ.get('S2A_DEPS_OUT')
if _OUT:
    _seen = set()
    _busy = [False]
    # 解释器自身（标准库 / site-packages / 本钩子）不算阶段输入：每个进程按自己的解释器排除（阶段里可能有 $PY 与 python3 两个解释器）
    def _sys_dirs():
        import site
        ds = {sys.prefix, sys.base_prefix, sys.exec_prefix, sys.base_exec_prefix, os.path.dirname(os.path.abspath(__file__))}
        try: ds.update(site.getsitepackages())
        except Exception: pass
        try: ds.add(site.getusersitepackages())
        except Exception: pass
        return tuple(os.path.realpath(d).rstrip('/') + '/' for d in ds if d)
    _SYS = _sys_dirs()

    def _mine(p):
        r = os.path.realpath(p)
        return r.startswith(_SYS) or (r + '/').startswith(_SYS) or '/site-packages/' in r or r.endswith('/site-packages')
    _WRITE = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND

    def _path(p):
        if p is None or isinstance(p, int): return None
        try: p = os.fsdecode(p)
        except Exception: return None
        return os.path.abspath(p)

    def _hook(ev, args):
        if _busy[0]: return
        if ev == 'open':
            p = _path(args[0])
            if p is None or _mine(p): return
            fl = args[2] if len(args) > 2 and isinstance(args[2], int) else 0
            m = args[1] if len(args) > 1 and isinstance(args[1], str) else ''
            _seen.add(('w' if (fl & _WRITE) or any(c in m for c in 'wax+') else 'f', p))
        elif ev in ('os.listdir', 'os.scandir'):
            f = sys._getframe(1)   # 导入系统自己列 sys.path 目录找模块（importlib FileFinder）不算：不然任何目录新加一个文件，所有阶段都重做
            for _ in range(8):
                if f is None: break
                if f.f_globals.get('__name__', '').startswith(('importlib', '_frozen_importlib')): return
                f = f.f_back
            p = _path(args[0] if args and args[0] is not None else '.')
            if p is not None and not _mine(p): _seen.add(('d', p))

    def _dump():
        _busy[0] = True
        rows = set(_seen)
        for m in list(sys.modules.values()):
            f = getattr(getattr(m, '__spec__', None), 'origin', None) or getattr(m, '__file__', None)
            if isinstance(f, str) and f.endswith('.py') and not _mine(f): rows.add(('f', os.path.abspath(f)))
        try:
            with open(os.path.join(_OUT, f'{os.getpid()}-{__import__("time").time_ns()}.tsv'), 'w', encoding='utf-8', errors='surrogateescape') as o:
                for k, p in sorted(rows): o.write(f'{k}\t{p}\n')
        except OSError:
            pass

    sys.addaudithook(_hook)
    __import__('atexit').register(_dump)


# 本钩子靠 PYTHONPATH 排在最前，会遮住解释器自带的 sitecustomize：Homebrew 的 Python 靠它把 /opt/homebrew/lib/pythonX.Y/site-packages 加进 sys.path，
#   遮住后 meson 这类装在那里的工具导入失败（11-05 dav1d 在阶段里 configure 报 No module named 'mesonbuild'，出根连红 5 次；终端里不设 PYTHONPATH 照常）。
#   这里接着执行 sys.path 上排在本目录之后的第一个 sitecustomize.py（有就执行、没有就算了），无论记不记依赖都接
def _s2a_chain_sitecustomize():
    import importlib.util
    here = os.path.dirname(os.path.realpath(__file__))
    for d in sys.path:
        if not d or os.path.realpath(d) == here:
            continue
        f = os.path.join(d, 'sitecustomize.py')
        if os.path.isfile(f):
            spec = importlib.util.spec_from_file_location('_s2a_chained_sitecustomize', f)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return


_s2a_chain_sitecustomize()

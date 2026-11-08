#!/usr/bin/env python3
"""nxsh_extract._cri_lib 并发首次编（11-06 天眼女神异闻录5：几个抽取进程同时编 libcrilayla，Windows 上目标已被别的进程加载，os.replace 报 WinError 5，整单抽取红）：
python3 tests/nxsh_crilayla_race_test.py。被测模块从仓库导入，__file__ 指到临时目录（库落临时目录的 build/shbake/，不碰仓库）；编译器、换上、加载一律替身。
期望（手写）：① 抢输（编完时库已被别的进程换上，os.replace 拒绝访问）→ 不抛错、删自己的临时文件、加载那份已在的库；
  ② 库不在时 os.replace 失败照样抛错（不吞真错）；③ 正常路径：编出、换上、加载同一路径"""
import importlib.util, os, shutil, sys, tempfile
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')
sys.path.insert(0, str(R / 'graphics/tools/shbake'))
import nxsh_extract as M
def load(t):   # 被测模块从仓库导入；把它的 __file__ 指到临时目录（_cri_lib 按 __file__ 找 crilayla.c、建 build/shbake/），库只落临时目录
    d = Path(t, 'graphics/tools/shbake'); d.mkdir(parents=True); shutil.copy(R / 'graphics/tools/shbake/crilayla.c', d / 'crilayla.c')
    M.__file__ = str(d / 'nxsh_extract.py'); return M
class Lib:
    def __init__(self, p): self.path = p; self.crilayla_dec = mock.MagicMock()
def case(lose, lib_there):
    with tempfile.TemporaryDirectory() as t:
        m = load(t); m._cri = None; os.environ.pop('NXSH_CRILAYLA', None)
        made = {}
        def cc(cmd, **kw):
            tmp = cmd[cmd.index('-o') + 1]; Path(tmp).write_bytes(b'mine'); made['tmp'] = tmp
            lib = tmp.rsplit('.', 2)[0]
            if lib_there: Path(lib).write_bytes(b'theirs')   # 别的进程先换上了
            return mock.Mock(returncode=0)
        real = os.replace
        def rep(a, b):
            if lose: raise PermissionError(5, '拒绝访问。')
            return real(a, b)
        err = None; lib = None
        with mock.patch.object(m.subprocess if hasattr(m, 'subprocess') else __import__('subprocess'), 'run', cc), mock.patch('subprocess.run', cc), mock.patch.object(m.os, 'replace', rep), mock.patch('ctypes.CDLL', Lib):
            try: lib = m._cri_lib()
            except OSError as e: err = e
        tmp = made.get('tmp', '')
        return err, (lib.path if lib else None), tmp, os.path.exists(tmp) if tmp else None, (open(lib.path, 'rb').read() if lib else None)
err, path, tmp, tmp_left, body = case(lose=True, lib_there=True)
chk('① 抢输：不抛错、删自己的临时文件、加载已在的那份', (None, False, b'theirs'), (err, tmp_left, body))
err, *_ = case(lose=True, lib_there=False)
chk('② 库不在时换上失败照样抛错', True, isinstance(err, PermissionError))
err, path, tmp, tmp_left, body = case(lose=False, lib_there=False)
chk('③ 正常路径：编出、换上、加载', (None, False, b'mine'), (err, tmp_left, body))
print(f'{"✓" if not bad else "✗"} nxsh_crilayla_race：{bad} 不通')
sys.exit(1 if bad else 0)

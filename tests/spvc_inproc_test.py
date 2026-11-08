#!/usr/bin/env python3
# spirv-cross 进程内调用（translator/spvc_inproc.py）单测。对照 = 同版本 spirv-cross 命令行（链锁 1.4.363.0），不跑被测实现推期望：
#   ① graphics/metal/tests 三支（顶点 / 像素 / 计算）按直连出库参数 XC：进程内与命令行 MSL 逐字节相同，rc 都 0
#   ② 不给 --output：MSL 从 stdout 交回（同命令行打印到 stdout）
#   ③ 坏输入（文件不在）：rc 1、报错含「Failed to open SPIR-V file」，本进程不退出
#   ④ 走命令行 exit 的分支（找不到入口点）：rc 1、报错含「Could not find an entry point」，本进程不退出（修前 exit 带走调用进程）
#   ⑤ 两个线程各调 20 次：结果都与单次调用相同（stderr 按线程分开、无串扰）
#   ⑦ Windows 垫片：内存输入搬运失败时 rc ≠ 0 并点名哪一步、系统错误码（只在 Windows 跑）
#   ⑧ Windows 垫片并发（11-05 天眼鬼灭之刃 9 支「mem:in 建临时文件 失败（GetLastError 5）」）：16 线程 × 200 次内存进出全部 rc 0、MSL 与单次逐字节同，
#      跑完临时目录里没有本进程名下的 s2a_spvc_<进程号>_* 文件（关闭即删；只在 Windows 跑）
#   ⑥ 输出身份（进缓存键）不含编译器版本：换 clang 版本身份不变、编好的库目录变（11-01 跨机实测：带编译器版本时本机与 Air 全部着色器键不同）
import os, subprocess, sys, tempfile, threading
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, os.path.join(ROOT, 'translator'))
import spvc_inproc as S
XC = ['--msl', '--msl-version', '30100', '--msl-argument-buffers', '--msl-texture-buffer-native', '--msl-pad-fragment-output']
bad = 0
def ck(name, ok):
    global bad; print(('通 ' if ok else '不通 ') + name); bad |= not ok
with tempfile.TemporaryDirectory(prefix='spvc_inproc_') as T:
    spv = {}
    for n in ('t_prog_vs', 't_prog_fs', 't_prog_cs'):
        spv[n] = os.path.join(T, n + '.spv'); subprocess.run(['spirv-as', '--target-env', 'spv1.3', os.path.join(ROOT, 'graphics/metal/tests', n + '.spvasm'), '-o', spv[n]], check=True)
    for n, p in spv.items():
        a, b = os.path.join(T, n + '.cli.metal'), os.path.join(T, n + '.in.metal')
        c = subprocess.run(['spirv-cross', *XC, p, '--output', a], capture_output=True, text=True); r = S.run([*XC, p, '--output', b])
        ck(f'① {n}：命令行 rc {c.returncode} / 进程内 rc {r.returncode}，MSL 逐字节相同', c.returncode == 0 and r.returncode == 0 and open(a, 'rb').read() == open(b, 'rb').read())
    one = S.run([*XC, spv['t_prog_fs']]); cli = subprocess.run(['spirv-cross', *XC, spv['t_prog_fs']], capture_output=True, text=True).stdout
    ck(f'② 不给 --output：stdout 交回 {len(one.stdout)} 字节、与命令行 stdout 相同', one.returncode == 0 and one.stdout == cli and len(cli) > 0)
    r = S.run(['--msl', os.path.join(T, 'nope.spv')]); ck(f'③ 坏输入：rc {r.returncode}、报错「{r.stderr.strip()[:40]}」', r.returncode == 1 and 'Failed to open SPIR-V file' in r.stderr)
    r = S.run(['--msl', '--entry', 'nosuch', '--stage', 'frag', spv['t_prog_fs']]); ck(f'④ exit 分支：rc {r.returncode}、本进程还在', r.returncode == 1 and 'Could not find an entry point' in r.stderr)
    got, lk = [], threading.Lock()
    def loop():
        for _ in range(20):
            x = S.run([*XC, spv['t_prog_fs']]); y = S.run(['--msl', os.path.join(T, 'nope.spv')])
            with lk: got.append((x.stdout == one.stdout, 'Failed to open' in y.stderr and 'entry point' not in y.stderr))
    ths = [threading.Thread(target=loop) for _ in range(2)]; [t.start() for t in ths]; [t.join() for t in ths]
    ck(f'⑤ 两线程各 20 次：{len(got)} 次全部与单次相同', len(got) == 40 and all(a and b for a, b in got))
    # ⑦ Windows 垫片搬运失败点名（11-05 天眼勇者斗恶龙 XI S 同输入两次各丢 1 / 6 支「Failed to open SPIR-V file: mem:in」，原先看不出哪一步）：
    #    内存输入 spvc_cli_run_mem、系统临时目录（TMP）指到不存在的目录 → 建临时文件失败：rc ≠ 0、报错含「[spvc 垫片] mem:in 建临时文件 失败」与 GetLastError
    if sys.platform == 'win32':
        import ctypes
        lib = ctypes.CDLL(S.lib_path()); f = lib.spvc_cli_run_mem
        f.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p), ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t)]
        data = open(spv['t_prog_fs'], 'rb').read(); buf = ctypes.create_string_buffer(data, len(data))
        args = [b'spirv-cross', b'--msl', b'mem:in', b'--output', b'mem:out']; argv = (ctypes.c_char_p * len(args))(*args)
        def call():
            o, on, e, en = ctypes.c_void_p(), ctypes.c_size_t(), ctypes.c_void_p(), ctypes.c_size_t()
            rc = f(len(args), argv, buf, len(data), ctypes.byref(o), ctypes.byref(on), ctypes.byref(e), ctypes.byref(en))
            return rc, ctypes.string_at(o, on.value) if o.value else b'', ctypes.string_at(e, en.value).decode('utf-8', 'replace') if e.value else ''
        rc, out, err = call(); ck(f'⑦ 内存输入正常：rc {rc}、MSL {len(out)} 字节', rc == 0 and b'main0' in out)
        old = os.environ.get('TMP'); os.environ['TMP'] = os.path.join(T, 'no', 'such')
        try: rc, out, err = call()
        finally:
            if old is None: os.environ.pop('TMP', None)
            else: os.environ['TMP'] = old
        ck(f'⑦ 临时目录不在：rc {rc}、报错点名步骤与错误码「{err.strip()[:70]}」', rc != 0 and '[spvc 垫片] mem:in 建临时文件 失败' in err and 'GetLastError' in err)
        ref = call()[1]; bad8, lk8 = [], threading.Lock()
        def loop8():
            for _ in range(200):
                r8 = call()
                if r8[0] != 0 or r8[1] != ref:
                    with lk8: bad8.append(r8[2][:120])
        ths8 = [threading.Thread(target=loop8) for _ in range(16)]; [t.start() for t in ths8]; [t.join() for t in ths8]
        import glob as _g, tempfile as _tf
        left = _g.glob(os.path.join(_tf.gettempdir(), f's2a_spvc_{os.getpid()}_*'))
        ck(f'⑧ 16 线程 × 200 次：失败 {len(bad8)}（{bad8[:1]}）、MSL 与单次同、本进程临时文件残留 {len(left)}', not bad8 and len(ref) > 0 and not left)
# ⑥ 跨机一致：换编译器版本（本机 clang-2100.1.1.101 / Air clang-2100.3.34.2），输出身份（进缓存键）不变、库目录变
_run = subprocess.run
def fake_clang(ver):
    def run(cmd, *a, **k):
        if cmd[:3] == ['xcrun', 'clang++', '--version']: return subprocess.CompletedProcess(cmd, 0, stdout=f'Apple clang version 21.0.0 ({ver})\n', stderr='')
        return _run(cmd, *a, **k)
    return run
ids = []
for ver in ('clang-2100.1.1.101', 'clang-2100.3.34.2'):
    S._id = None; subprocess.run = fake_clang(ver)
    try: ids.append((S.identity(), S._build_id()))
    finally: subprocess.run = _run
S._id = None
ck(f'⑥ 换编译器版本：输出身份 {ids[0][0]} / {ids[1][0]} 相同、库目录 {ids[0][1]} / {ids[1][1]} 不同', ids[0][0] == ids[1][0] and ids[0][1] != ids[1][1])
print('spvc_inproc 单测' + ('全过' if not bad else '有不通'))
sys.exit(1 if bad else 0)

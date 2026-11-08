#!/usr/bin/env python3
# spirv-cross 命令行在进程内跑（S2Arm 11-01 出包线）：直连出库的翻译段每支着色器起一次 spirv-cross 进程，异度3 600 支单线程分片 706 次共 6.22 秒、
#   光起进程 3.77 秒（比它干活还多）。这里把同一份命令行（graphics/third_party/spirv_cross/main.cpp，vulkan-sdk-1.4.363.0 标签原样，= 链锁 dmsh_chain.lock 的 spirv-cross 1.4.363.0）
#   与库源码编成一个动态库，按原参数在进程内调用：走命令行同一段代码，输出与命令行逐字节相同（spvc_cli/shim.h：exit 改抛异常、stderr 按线程收集）。
# 库按「源码 + 胶水 + 编译参数 + 编译器版本」的摘要编到 <仓库>/build/spvc_cli/<摘要>/，首次约 10 秒（文件锁，多进程只编一次）；Air 同样从仓库源码编，不依赖 Homebrew。
# run(args) → subprocess.CompletedProcess(args, 返回码, stdout, stderr)：args 不含程序名；没给 --output 时补一个临时文件、读回作 stdout（同命令行打印到 stdout）
import ctypes, hashlib, os, shutil, subprocess, sys, tempfile, threading
WIN = sys.platform == 'win32'   # Windows 出包机（#1100 W6）：LLVM clang++ 编 libspvc_cli.dll，胶水换 spvc_cli/win/shim.cpp（没有 fmemopen / open_memstream），输出身份不变
import xlock   # 同目录：跨平台文件锁
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '..'))
SRC = os.path.join(ROOT, 'graphics', 'third_party', 'spirv_cross'); SHIM = os.path.join(HERE, 'spvc_cli')
UNITS = ['spirv_cross', 'spirv_cfg', 'spirv_parser', 'spirv_cross_parsed_ir', 'spirv_glsl', 'spirv_msl', 'spirv_hlsl', 'spirv_cpp', 'spirv_reflect', 'spirv_cross_util']
FLAGS = ['-O2', '-std=c++14', '-fPIC']   # 进输出身份；Windows 编时去掉 -fPIC（该目标不认），见 _cxx
LIB = 'libspvc_cli.dll' if WIN else 'libspvc_cli.dylib'


def _cxx():   # 编译器命令前缀：Mac 走 xcrun；Windows 走 PATH 上的 clang++（或 S2A_CXX）
    return [os.environ.get('S2A_CXX') or 'clang++'] if WIN else ['xcrun', 'clang++']
_lib, _id, _lk = None, None, threading.Lock()


def identity():
    """输出的身份：源码、胶水、编译参数的摘要（进工具指纹，dmsh_build.py tool_fingerprint）。不含编译器版本：MSL 只由源码与参数定，
    11-01 实测 brew 编的命令行与本机 clang 编的库 26618/26618 逐字节一致；带上编译器版本则本机（clang-2100.1.1.101）与 Air（clang-2100.3.34.2）
    全部着色器键不同、缓存跨机不通（跨机实测 30035/30035 键不同）"""
    global _id
    if _id is None:
        h = hashlib.sha256()
        for d, names in ((SRC, sorted(os.listdir(SRC))), (SHIM, sorted(os.listdir(SHIM)))):
            for n in names:
                p = os.path.join(d, n)
                if os.path.isfile(p) and n.endswith(('.cpp', '.hpp', '.h')): h.update(n.encode() + b'\0' + open(p, 'rb').read() + b'\0')
        h.update(' '.join(FLAGS).encode())
        _id = h.hexdigest()[:16]
    return _id


def _build_id():   # 编好的库放哪：输出身份 + 编译器版本 + Windows 胶水（换了工具链 / 胶水就重编库，但不改缓存键）
    win = open(os.path.join(SHIM, 'win', 'shim.cpp'), 'rb').read() if WIN else b''   # 11-05：win/shim.cpp 不进输出身份，原先改了它旧库照用
    return hashlib.sha256((identity() + '\0' + subprocess.run([*_cxx(), '--version'], capture_output=True, text=True).stdout).encode() + b'\0' + win).hexdigest()[:16]


def _build(out):
    tmp = tempfile.mkdtemp(prefix='spvc_', dir=os.path.dirname(out))
    try:
        cc = [*_cxx(), *[f for f in FLAGS if not (WIN and f == '-fPIC')], '-I' + SRC]
        procs = [subprocess.Popen([*cc, '-c', os.path.join(SRC, u + '.cpp'), '-o', os.path.join(tmp, u + '.o')]) for u in UNITS]
        procs.append(subprocess.Popen([*cc, '-I' + SHIM, '-include', os.path.join(SHIM, 'shim.h'), '-c', os.path.join(SRC, 'main.cpp'), '-o', os.path.join(tmp, 'main.o')]))
        procs.append(subprocess.Popen([*cc, '-c', os.path.join(SHIM, 'win' if WIN else '', 'shim.cpp'), '-o', os.path.join(tmp, 'shim.o')]))
        if any(p.wait() for p in procs): raise RuntimeError('spirv-cross 进程内库编译失败（见上方编译器输出）')
        lib = os.path.join(tmp, LIB)
        subprocess.run([*_cxx(), '-shared' if WIN else '-dynamiclib', '-o', lib, *[os.path.join(tmp, f) for f in os.listdir(tmp) if f.endswith('.o')]], check=True)
        os.replace(lib, out)
    finally: shutil.rmtree(tmp, ignore_errors=True)


def prebuilt_id():   # 预编件身份：输出身份 + Windows 胶水（同 _build_id，但不含编译器版本：玩家机上没有编译器可问）
    win = open(os.path.join(SHIM, 'win', 'shim.cpp'), 'rb').read() if WIN else b''
    return hashlib.sha256(identity().encode() + b'\0' + win).hexdigest()[:16]


def prebuilt(*rel):
    """启动器随发版预编的一份（S2A_PREBUILT_TOOLS/spvc/，launchers/windows/bundle_prepare_win.py 编，.src_digest 记 prebuilt_id）：身份相同且文件在 → 路径；否则 None（照旧现编）"""
    d = os.environ.get('S2A_PREBUILT_TOOLS')
    if not d: return None
    p = os.path.join(d, 'spvc')
    try: same = open(os.path.join(p, '.src_digest')).read().strip() == prebuilt_id()
    except OSError: return None
    q = os.path.join(p, *rel)
    return q if same and os.path.isfile(q) else None


def lib_path():   # 库在哪（首次按需编）：本进程 ctypes 载入，出包 C# 批量进程（dsh/batch）也载这一份
    pre = prebuilt(LIB)
    if pre: return pre
    d = os.path.join(ROOT, 'build', 'spvc_cli', _build_id()); os.makedirs(d, exist_ok=True); p = os.path.join(d, LIB)
    if not os.path.exists(p):
        with xlock.held(os.path.join(d, '.lock')):
            if not os.path.exists(p): _build(p)
    return p


CLI = 'spirv-cross.exe' if WIN else 'spirv-cross'


def cli_path():
    """命令行 spirv-cross（Windows 出包机，#1100 W6）：没有 Homebrew，用同一份仓库源码（vulkan-sdk 标签原样，= 链锁版本）编成
    <仓库>/build/spvc_cli/<编库摘要>/cli/bin/spirv-cross.exe，旁边写 versions.json（spirvCross = 「spirv-cross <版本>」，版本取 spvc_cli/gitversion.h 的标签），
    dmsh_chain.spirv_cross_identity 按它认版本（同 S2Arm.app 运行时目录的规矩）。Windows 上预包含 spvc_cli/win/cli.h，输出按二进制写、与 Mac 逐字节同。
    Mac / Linux 照旧用系统装的 spirv-cross，不走这里"""
    import json, re
    pre = prebuilt('cli', 'bin', CLI)   # 预编的同布局（cli/bin/spirv-cross.exe + cli/versions.json）
    if pre: return pre
    d = os.path.join(ROOT, 'build', 'spvc_cli', _build_id(), 'cli'); b = os.path.join(d, 'bin'); p = os.path.join(b, CLI)
    if os.path.exists(p): return p
    os.makedirs(b, exist_ok=True)
    with xlock.held(os.path.join(d, '.lock')):
        if os.path.exists(p): return p
        m = re.search(r'vulkan-sdk-(\S+?)[ "]', open(os.path.join(SHIM, 'gitversion.h'), encoding='utf-8').read())
        if not m: raise RuntimeError('spvc_cli/gitversion.h 里读不出 vulkan-sdk 版本标签')
        tmp = tempfile.mkdtemp(prefix='spvcli_', dir=d)
        try:
            cc = [*_cxx(), *[f for f in FLAGS if f != '-fPIC'], '-I' + SRC, '-I' + SHIM]
            pre = ['-include', os.path.join(SHIM, 'win', 'cli.h')] if WIN else []
            procs = [subprocess.Popen([*cc, '-c', os.path.join(SRC, u + '.cpp'), '-o', os.path.join(tmp, u + '.o')]) for u in UNITS]
            procs.append(subprocess.Popen([*cc, *pre, '-c', os.path.join(SRC, 'main.cpp'), '-o', os.path.join(tmp, 'main.o')]))
            if any(x.wait() for x in procs): raise RuntimeError('spirv-cross 命令行编译失败（见上方编译器输出）')
            exe = os.path.join(tmp, CLI)
            subprocess.run([*_cxx(), '-o', exe, *[os.path.join(tmp, f) for f in os.listdir(tmp) if f.endswith('.o')]], check=True)
            with open(os.path.join(d, 'versions.json'), 'w', encoding='utf-8', newline='\n') as f: json.dump({'spirvCross': 'spirv-cross ' + m.group(1)}, f)
            os.replace(exe, p)
        finally: shutil.rmtree(tmp, ignore_errors=True)
    return p


def _load():
    global _lib
    with _lk:
        if _lib is None:
            lib = ctypes.CDLL(lib_path())
            lib.spvc_cli_run.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t)]
            lib.spvc_cli_run.restype = ctypes.c_int
            lib.spvc_cli_free.argtypes = [ctypes.c_void_p]
            _lib = lib
    return _lib


def run(args):
    lib = _load(); args = [str(a) for a in args]; tmp = None
    if '--output' not in args:
        fd, tmp = tempfile.mkstemp(suffix='.out'); os.close(fd); args_ = args + ['--output', tmp]
    else: args_ = args
    a = [b'spirv-cross'] + [x.encode() for x in args_]; arr = (ctypes.c_char_p * len(a))(*a)
    err, n = ctypes.c_void_p(), ctypes.c_size_t()
    try:
        rc = lib.spvc_cli_run(len(a), arr, ctypes.byref(err), ctypes.byref(n))   # ctypes 调用期间放开 GIL，分片里的线程可并行
        e = ctypes.string_at(err.value, n.value).decode('utf-8', 'replace') if err.value else ''
        if err.value: lib.spvc_cli_free(err)
        out = ''
        if tmp:
            with open(tmp, encoding='utf-8', errors='replace') as f: out = f.read() if rc == 0 else ''
    finally:
        if tmp: os.unlink(tmp)
    return subprocess.CompletedProcess(['spirv-cross', *args], rc, out, e)


if __name__ == '__main__':   # spvc_inproc.py lib | cli：打印库 / 命令行路径（首次按需编；direct_lib.sh 在 Windows 上把命令行目录放进 PATH）
    import sys as _s
    if _s.argv[1:] not in (['lib'], ['cli']): _s.exit('用法：spvc_inproc.py lib | cli')
    print(lib_path() if _s.argv[1] == 'lib' else cli_path())

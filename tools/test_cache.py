#!/usr/bin/env python3
"""门禁单测结果缓存（10-30 总指挥：合入前门禁只证明这次改动没弄坏它影响到的东西；输入没变的单测不重跑）。只缓存绿，红不记。
用法：
  python3 tools/test_cache.py key <仓库根> <单测文件…>   每个单测一行缓存键（按参数顺序）；算不出 / 不该缓存的那行打「-」（调用方当没命中照跑）
  python3 tools/test_cache.py hit <缓存目录> <键>        命中退出 0，没命中退出 1
  python3 tools/test_cache.py put <缓存目录> <键>        记一次绿
缓存键 = sha256（单测名 + 全部输入文件「路径 + 内容哈希」（按路径排序）+ 工具链指纹）。
  输入 = tools/gate_route.py 的单测覆盖面（cover_files：文本点名文件的传递闭包 + 门禁覆盖 / 门禁只看 / 门禁闭包）
       ∪ 单测文件头「# 门禁输入：<目录或通配…>」（tools/gate_decl.py inputs 收）；覆盖面是「门禁：每次」（与全部改动相关）的不缓存，打「-」。
  工具链指纹 = python3 --version、bash --version 首行、dotnet --version（有就加）、xcrun clang --version 首行（有就加）、tools/toolchain.env 内容。
缓存目录缺省 ${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/testres（tools/gate.sh 给；mini 上远端门禁那份在它自己的假家目录下）。
一个键一个空文件，写 .tmp 再 mv。"""
import fnmatch, hashlib, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run1(cmd):
    """命令的输出首行；命令不在 / 失败 → None"""
    if not shutil.which(cmd[0]): return None
    try: r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError): return None
    if r.returncode: return None
    return ((r.stdout or r.stderr).strip().split('\n') or [''])[0]


def toolchain(root):
    parts = []
    for name, cmd, need in (('python3', ['python3', '--version'], True), ('bash', ['bash', '--version'], True),
                            ('dotnet', ['dotnet', '--version'], False), ('clang', ['xcrun', 'clang', '--version'], False)):
        v = run1(cmd)
        if v is None and need: raise RuntimeError(f'{name} 版本取不到')
        parts.append(f'{name}={v or "无"}')
    try: parts.append('toolchain.env=' + hashlib.sha256(open(os.path.join(root, 'tools/toolchain.env'), 'rb').read()).hexdigest())
    except FileNotFoundError: parts.append('toolchain.env=无')
    return '\n'.join(parts)


def declared_inputs(root):
    r = subprocess.run([sys.executable, os.path.join(HERE, 'gate_decl.py'), 'inputs', root], capture_output=True, text=True, check=True)
    return {f: v.split() for f, _, v in (l.partition('\t') for l in r.stdout.splitlines() if l)}


DECL_READERS = {'tools/gate_route.py', 'tools/gate_decl.py'}
_DECL_FP = {}


def decl_fp(root):   # 全仓库文件头声明的指纹：gate_decl.py 各模式输出合起来
    if root not in _DECL_FP:
        h = hashlib.sha256()
        for m in ('route', 'local', 'manual', 'layer', 'inputs'):
            r = subprocess.run([sys.executable, os.path.join(HERE, 'gate_decl.py'), m, root], capture_output=True, text=True)
            h.update(f'{m}\0{r.returncode}\0{r.stdout}\n'.encode())
        _DECL_FP[root] = h.hexdigest()
    return _DECL_FP[root]


def keys(root, tests):
    os.chdir(root)
    sys.path.insert(0, HERE)
    import gate_route as gr
    files, by_name = gr.index()
    decl = declared_inputs(root)
    tc = toolchain(root)
    hashes = {}

    def fh(f):
        if f not in hashes:
            try: hashes[f] = hashlib.sha256(open(f, 'rb').read()).hexdigest()
            except (FileNotFoundError, IsADirectoryError): hashes[f] = '无'
        return hashes[f]

    out = []
    for t in tests:
        try:
            cov = gr.cover_files(t, files, by_name, full=True)   # 缓存输入走完整闭包，不受「门禁只看」截断
        except SystemExit:   # 覆盖面算不出（门禁只看写错 / 阶段闭包失败）：这支不缓存
            cov = None
        if cov is None: out.append('-'); continue
        for p in decl.get(t, ()):
            d = p.rstrip('/')
            cov |= {f for f in files if f == d or f.startswith(d + '/') or fnmatch.fnmatch(f, p)}
        h = hashlib.sha256()
        h.update(f'单测 {t}\n'.encode())
        # 读全仓库文件头声明的单测（覆盖面含 gate_route.py / gate_decl.py，如 gate_route_test / gate_route_matrix_test）：
        #   它的真实输入是所有文件的「# 门禁…」声明，单靠覆盖面算不进来（10-30：换链支改了 core-link/gate.sh 的路由，
        #   gate_route_matrix_test 在干净 main 上命中缓存「沿用上次的绿」，核 main 时给了假绿）→ 声明指纹进键
        if cov & DECL_READERS: h.update(f'声明 {decl_fp(root)}\n'.encode())
        for f in sorted(cov | {t}): h.update(f'{f}\0{fh(f)}\n'.encode())
        h.update(tc.encode())
        out.append(h.hexdigest())
    return out


def main():
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == 'key':
        try: print('\n'.join(keys(os.path.abspath(a[1]), a[2:])))
        except Exception as e:   # 算键失败一律当没命中（宁可多跑）
            print(f'test_cache：算键失败：{e}', file=sys.stderr); print('\n'.join('-' for _ in a[2:]))
    elif len(a) == 3 and a[0] == 'hit':
        sys.exit(0 if a[2] != '-' and os.path.isfile(os.path.join(a[1], a[2])) else 1)
    elif len(a) == 3 and a[0] == 'put':
        if a[2] == '-': return
        os.makedirs(a[1], exist_ok=True)
        tmp = os.path.join(a[1], f'.{a[2]}.{os.getpid()}.tmp'); open(tmp, 'w').close(); os.replace(tmp, os.path.join(a[1], a[2]))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()

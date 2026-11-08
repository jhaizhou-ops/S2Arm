#!/usr/bin/env python3
"""C# 工程的编译输入闭包（产物根阶段键收窄用）：python3 tools/csproj_closure.py <工程.csproj>… [--files | --key]
按 MSBuild 求值（dotnet msbuild -getItem / -pp）列出这些工程按 ProjectReference 传递闭包真正参与编译的仓库内文件：
  编译项 Compile、嵌入资源 EmbeddedResource、拷到输出的 None / Content / AdditionalFiles、各工程文件本身、导入的仓库内 .props / .targets，
  以及这些仓库内 .props / .targets 里以 $(MSBuildThisFileDirectory) 引的仓库文件（例：AbiHash.targets 从 gal_abi.h 生成编译项），外加沿途的 global.json / nuget.config。
--files：打印上述文件（仓库相对路径，一行一个）；--key：打印 dotnet SDK 版本 + 这些文件在 HEAD 的对象号拼起来的 16 位哈希。
用途：阶段键只认真正参与编译的源码——着色器烘焙 S2A.ShBake 依赖 Ryujinx.Graphics.Gpu → Shader / GAL …，不含 Ryujinx.HLE（服务层）、渲染器本体（只引能力表 caps/），
  也不含工程目录里不编译的脚本 / 表格 / 说明（graphics/widen/scan、tables）。
文件清单按「粗键」缓存（S2A_CSCLOSURE_CACHE，缺省 ~/.s2arm/run/s2arm/cache/csclosure）：粗键 = 各工程目录与沿途配置在 HEAD 的树 / 文件对象号 + SDK 版本 + 本脚本内容；
  清单只随工程结构变（加删文件、改工程文件都会改目录树号），文件内容每次按清单现取对象号，所以缓存命中也不会漏内容改动。命中约 0.1 秒，不中约每工程 1–2 秒。
认不出的引用、清单里有 HEAD 没跟踪的文件 → 报红退出（宁可失败，不悄悄少算依赖）。"""
import hashlib, json, os, re, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))   # 本脚本所在仓库（不按调用方当前目录）
UPCFG = ('Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'global.json', 'nuget.config')
CACHE = os.environ.get('S2A_CSCLOSURE_CACHE') or os.path.join(os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run'), 's2arm/cache/csclosure')


def die(msg): sys.exit(f'🔴 csproj_closure：{msg}')


def rel(p):
    r = os.path.relpath(os.path.realpath(p), os.path.realpath(ROOT))
    return None if r.startswith('..') else r


def git_ids(paths):
    if not paths: return []
    r = subprocess.run(['git', '-C', ROOT, 'rev-parse'] + [f'HEAD:{p}' for p in paths], capture_output=True, text=True)
    if r.returncode: die(f'取 HEAD 对象号失败（清单里有没跟踪的文件？）：{r.stderr.strip()[:300]}')
    return r.stdout.split()


def refs_regex(proj):
    """粗遍历（只为缓存粗键）：工程文件里的 ProjectReference，变量只认同文件定义的和 $(MSBuildThisFileDirectory)。"""
    txt = open(proj, encoding='utf-8-sig').read(); here = os.path.dirname(proj) + '/'
    var = {'MSBuildThisFileDirectory': here}
    for k, v in re.findall(r'<(\w+)(?:\s+Condition="[^"]*")?>([^<]*)</\1>', txt): var.setdefault(k, v)
    out = []
    for inc in re.findall(r'<ProjectReference\s+Include="([^"]+)"', txt):
        p = inc
        for _ in range(5): p = re.sub(r'\$\((\w+)\)', lambda m: var.get(m.group(1), m.group(0)), p)
        if '$(' in p: die(f'{proj}：认不出的 MSBuild 变量 {inc}')
        p = os.path.normpath(os.path.join(here, p.replace('\\', '/')))
        if not os.path.isfile(p): die(f'{proj}：引用的工程不存在 {p}')
        out.append(p)
    return out


def up_cfg(d):
    out = set()
    while True:
        for f in UPCFG:
            if os.path.isfile(os.path.join(d, f)) and rel(os.path.join(d, f)): out.add(rel(os.path.join(d, f)))
        if os.path.samefile(d, ROOT) or d == '/': break
        d = os.path.dirname(d)
    return out


def coarse_key(projs, sdk):
    seen, todo = set(), [os.path.abspath(p) for p in projs]
    while todo:
        p = todo.pop()
        if p in seen: continue
        seen.add(p); todo += refs_regex(p)
    paths = set()
    for p in seen: paths.add(rel(os.path.dirname(p))); paths |= up_cfg(os.path.dirname(p))
    paths = sorted(paths)
    me = open(os.path.abspath(__file__), 'rb').read()
    h = hashlib.sha256(('\n'.join(paths) + '\n' + '\n'.join(git_ids(paths)) + '\n' + sdk + '\n').encode() + me).hexdigest()
    return h[:32]


def eval_proj(proj):
    """一个工程的求值：(仓库内输入文件集合, 引用的工程绝对路径列表)"""
    r = subprocess.run(['dotnet', 'msbuild', proj, '-nologo', '-getItem:Compile', '-getItem:EmbeddedResource', '-getItem:None', '-getItem:Content',
                        '-getItem:AdditionalFiles', '-getItem:ProjectReference'], capture_output=True, text=True, cwd=os.path.dirname(proj))
    if r.returncode: die(f'{proj} 求值失败：{(r.stdout + r.stderr).strip()[-300:]}')
    items = json.loads(r.stdout).get('Items', {})
    files = {rel(proj)}
    for kind in ('Compile', 'EmbeddedResource', 'None', 'Content', 'AdditionalFiles'):
        for it in items.get(kind, []):
            if kind in ('None', 'Content') and it.get('CopyToOutputDirectory', '') in ('', 'Never'): continue   # 不进输出的 None / Content 不影响产物
            fp = it.get('FullPath') or os.path.join(os.path.dirname(proj), it['Identity'])
            if '/obj/' in fp or '/bin/' in fp: continue   # 构建生成物（不是源码）
            if rel(fp): files.add(rel(fp))
    refs = [it.get('FullPath') or os.path.normpath(os.path.join(os.path.dirname(proj), it['Identity'])) for it in items.get('ProjectReference', [])]
    with tempfile.NamedTemporaryFile(suffix='.xml') as t:   # 导入的仓库内 .props / .targets（预处理文件里每段导入有一行它的绝对路径）
        p = subprocess.run(['dotnet', 'msbuild', proj, '-nologo', f'-pp:{t.name}'], capture_output=True, text=True, cwd=os.path.dirname(proj))
        if p.returncode: die(f'{proj} 预处理失败：{(p.stdout + p.stderr).strip()[-300:]}')
        imps = {l.strip() for l in open(t.name, encoding='utf-8', errors='replace') if re.match(r'^\s*/\S+\.(props|targets)\s*$', l)}
    for f in imps:
        if not rel(f) or not os.path.isfile(f) or '/obj/' in f or '/bin/' in f: continue   # obj/ 下是还原生成的（nuget.g.props 等），由工程文件 + Directory.Packages.props 决定
        files.add(rel(f))
        for m in re.findall(r'\$\(MSBuildThisFileDirectory\)([^"\';)<>$]+)', open(f, encoding='utf-8-sig').read()):   # 目标里以本文件目录引的仓库文件
            q = os.path.normpath(os.path.join(os.path.dirname(f), m.strip()))
            if os.path.isfile(q) and rel(q): files.add(rel(q))
    files |= up_cfg(os.path.dirname(proj))
    return files, refs


def closure(projs):
    seen, files, todo = set(), set(), [os.path.abspath(p) for p in projs]
    with ThreadPoolExecutor(8) as ex:
        while todo:
            batch = [p for p in dict.fromkeys(todo) if p not in seen]; todo = []
            seen.update(batch)
            for fs, refs in ex.map(eval_proj, batch):
                files |= fs; todo += [r for r in refs if os.path.realpath(r) not in {os.path.realpath(s) for s in seen}]
    return sorted(f for f in files if f)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args: sys.exit('用法：csproj_closure.py <工程.csproj>… [--files | --key]')
    sdk = subprocess.run(['dotnet', '--version'], capture_output=True, text=True, cwd=ROOT).stdout.strip()
    ck = coarse_key(args, sdk); cf = os.path.join(CACHE, ck + '.files')
    os.makedirs(CACHE, exist_ok=True); lk = cf + '.lock'
    while not os.path.isfile(cf):   # 同一粗键只求值一份：各款刷新同时算键（九款并行出包），后到的等先到的写好清单；持锁进程死了接管
        try: os.mkdir(lk)
        except FileExistsError:
            try: pid = int(open(os.path.join(lk, 'pid')).read())
            except (OSError, ValueError): pid = 0
            if pid:
                try: os.kill(pid, 0)
                except ProcessLookupError: subprocess.run(['rm', '-rf', lk])
            time.sleep(0.5); continue
        try:
            open(os.path.join(lk, 'pid'), 'w').write(str(os.getpid()))
            if not os.path.isfile(cf):
                files = closure(args); tmp = f'{cf}.{os.getpid()}.tmp'; open(tmp, 'w').write('\n'.join(files)); os.replace(tmp, cf)
        finally: subprocess.run(['rm', '-rf', lk])
    files = open(cf).read().split('\n')
    files = [f for f in files if f]
    if '--key' not in sys.argv:
        print('\n'.join(files)); return
    print(hashlib.sha256(('sdk ' + sdk + '\n' + ''.join(f'{f} {i}\n' for f, i in zip(files, git_ids(files)))).encode()).hexdigest()[:16])


if __name__ == '__main__':
    main()

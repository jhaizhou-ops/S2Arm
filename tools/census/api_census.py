#!/usr/bin/env python3
"""全库图形接口清点（静态，不起局；总指挥 11-01）：各款 ExeFS 里用到的 GL / EGL / NVN 名字取并集，对照直连层已实现的入口出缺口表。
用法：python3 tools/census/api_census.py <ExeFS 根> [--names <普查 queue.tsv>] [--logs <host.log> …] [--tsv <缺口表输出>] [--gap <单款缺口数输出>] [--check]
  <ExeFS 根>：一款一个子目录（目录名 = 程序号），里面是 main / subsdk* / sdk 等 NSO（nx_unpack --exefs-only 的 exefs/）；也可直接给一个 exefs/ 目录。
  --names：普查 queue.tsv（键、名称两列），缺口表里写款名；--logs：普查 / 快测 host.log，装载期与运行期红行里的名字也并进来（动态补漏）。
  --gap：只给一个 exefs/ 时写这款的「接口缺口」一格（census.sh 解包后调，总表「接口缺口」列读它）：「N（类别 n、…）」/ 0 / 「32 位」/ 「读不动」。
  --check：有缺口或有读不动的款时退出 1（新游戏进库用）。
常设预检（总指挥 11-01）：不另设门禁步骤，普查每款解包后清点一次，新款带来的缺口自然出现在总表。
分母：给了 --names 就是队列里的全部款（ExeFS 没抽到的算读不动）；32 位款（nx_unpack --npdm-isa 判）单列「暂不支持」，不进缺口表、不算读不动（jhz 11-01）。
一款用到的名字（三种来源，任一中即算）：
  · 导入：NSO 动态符号表里未定义的 gl* / egl* / nvn* 符号（装载期要解析，没有就「导入没有任何模块定义」、调到即中止）；
  · 调用：按名取函数的加载器（glad 走 eglGetProcAddress、NVN 的 C 加载器走 nvnDeviceGetProcAddress）存进 GOT 槽、且别处代码读那个槽的名字（loader_census.scan）。
    只按「查过」算会多出几千个（glad 查 2956 个、代码只用 79 个），按「代码读槽」算才是真调用；
  · 运行期红行（--logs）：「lookup X → 没有」「导入 X 没有任何模块定义」「NVN address lookup of an unknown name: X」「NVN 未实现 X」。
已实现：GL / EGL = graphics/nvn/gfx/gl 下 GL( / GLB( 登记的名字；NVN = 直连层 NVN( / NVN_NOPROTO( 实现 + 空操作表（nvn_cover_status.code_surface），
  不在 names.txt 名字表里的 NVN 名字按名查直接回空（类别「查不到」），在表里但没实现的调到报未实现（类别「未实现」）。
只判「有没有这个名字的实现」，不判语义。"""
import collections, glob, json, os, re, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'graphics/nvn/tools')); import nso_syms, loader_census, nvn_cover_status

API = re.compile(r'^(gl|egl|nvn)[A-Z]\w*$')
GLREG = re.compile(r'^\s*GLB?\(\s*(\w+)\s*,', re.M)
LOGNAME = [re.compile(r'lookup (\w+) → 没有'), re.compile(r'导入 (\w+) 没有任何模块定义'), re.compile(r'NVN address lookup of an unknown name: (\w+)'),
           re.compile(r'NVN 未实现[：: ]*(\w+)'), re.compile(r'unimplemented NVN (\w+)')]


def _impl_stamp():
    """已实现接口所依赖的源文件的 (相对路径, 大小, 修改时间)：GL 的 graphics/gl/*.m、NVN 的 graphics/nvn/*.{c,m,inc,h}、names.txt、宿主钩子目录下的文件"""
    fs = [ROOT / 'graphics/nvn/gfx/nvn/names.txt']
    fs += sorted((ROOT / 'graphics/nvn/gfx/gl').glob('*.m'))
    fs += [f for f in sorted((ROOT / 'graphics/nvn/gfx/nvn').iterdir()) if f.suffix in ('.c', '.m', '.inc', '.h')]
    fs += [f for f in sorted((ROOT / 'graphics/nvn/host').rglob('*')) if f.is_file()]
    return [[str(f.relative_to(ROOT)), f.stat().st_size, int(f.stat().st_mtime)] for f in fs]


def implemented():
    """→ (GL 已实现, NVN 已实现, 名字表)。结果缓存到 S2A_API_IMPL_CACHE（缺省 ~/.cache/s2a/api_implemented.json），按源文件大小 + 修改时间认，源变了重扫
    （审计 P1-57：普查每款新起一个进程，原先每个进程都把 gl/*.m 与 nvn/* 全文读一遍再解析）"""
    cache = os.environ.get('S2A_API_IMPL_CACHE', os.path.expanduser('~/.cache/s2a/api_implemented.json'))
    stamp = _impl_stamp()
    try:
        c = json.load(open(cache))
        if c['stamp'] == stamp: return set(c['gl']), set(c['nvn']), set(c['table'])
    except (OSError, ValueError, KeyError): pass
    gl = set()
    for f in sorted((ROOT / 'graphics/nvn/gfx/gl').glob('*.m')): gl |= set(GLREG.findall(f.read_text(errors='replace')))
    text = ''.join(f.read_text(errors='replace') for d in ('graphics/nvn/gfx/nvn',) for f in sorted((ROOT / d).iterdir()) if f.suffix in ('.c', '.m', '.inc', '.h'))
    nvn = set(nvn_cover_status.code_surface(text))
    table = set((ROOT / 'graphics/nvn/gfx/nvn/names.txt').read_text().split())
    hooks = nso_syms.host_hooks(str(ROOT / 'graphics/nvn/host'))   # 宿主按名解析导入的 HLE 钩子（nvnBootstrapLoader 等）
    gl, nvn = gl | {h for h in hooks if h.startswith(('gl', 'egl'))}, nvn | {h for h in hooks if h.startswith('nvn')}
    try:   # 先写同目录临时文件再改名：普查几道同时起进程，不能读到半截缓存
        os.makedirs(os.path.dirname(cache), exist_ok=True); tmp = f'{cache}.{os.getpid()}.tmp'
        json.dump({'stamp': stamp, 'gl': sorted(gl), 'nvn': sorted(nvn), 'table': sorted(table)}, open(tmp, 'w')); os.replace(tmp, cache)
    except OSError: pass
    return gl, nvn, table


def modules(exefs):
    for n in sorted(os.listdir(exefs)):
        p = os.path.join(exefs, n)
        if os.path.isfile(p) and n != 'main.npdm' and not n.endswith(('.log', '.tsv')):
            with open(p, 'rb') as f:
                if f.read(4) == b'NSO0': yield n, p


def used(exefs):
    """→ {名字: 来源集合 {'导入', '调用'}}；结果缓存在 <exefs>/.api_used.json（按各模块大小 + 修改时间认，模块变了重扫；扫一款纯 Python 约 6 秒）"""
    stamp = [[m, os.path.getsize(p), int(os.path.getmtime(p))] for m, p in modules(exefs)]
    cache = os.path.join(exefs, '.api_used.json')
    try:
        c = json.load(open(cache))
        if c['stamp'] == stamp: return collections.defaultdict(set, {k: set(v) for k, v in c['used'].items()}), []
    except (OSError, ValueError, KeyError): pass
    out = collections.defaultdict(set); defs = set(); bad = []
    for mod, p in modules(exefs):
        try:
            img = nso_syms.load(p)
            for s, defined, _ in nso_syms.dynsyms(img):
                if defined: defs.add(s)
                elif API.match(s): out[s].add('导入')
            if nso_syms.is_32(img): continue   # 32 位代码不是 AArch64：加载器扫描按 A64 解码会出假名字，只读导入表
            im, text = loader_census.image(p)
            _, refs, _ = loader_census.scan(im, text)
            for nm in refs:
                if API.match(nm): out[nm].add('调用')
        except Exception as e:   # 一个模块读不动不挡全表：记一行
            print(f'【黄】{exefs}/{mod} 读不动：{type(e).__name__} {e}', file=sys.stderr); bad.append(mod)
    # 本款别的模块导出的 nvn*（FINAL FANTASY VII：NvMM 的 nvnBootstrapLoaderInternal 由同包模块给）：装载期模块间互解，不算缺口。
    #   gl* / egl* 不扣：游戏自带的 NVIDIA GL 驱动模块导出全部 GL 名字，宿主把整个驱动换成直连 GL 层（gfx_api.py gl_driver），游戏导入的都要宿主实现
    for s in (d for d in defs if d.startswith('nvn')):
        if out.get(s) == {'导入'}: del out[s]
        elif s in out: out[s].discard('导入')
    if not bad:
        try: json.dump({'stamp': stamp, 'used': {k: sorted(v) for k, v in out.items()}}, open(cache, 'w'))
        except OSError: pass
    return out, bad


# 程序位数只有一份判法：nx_unpack --npdm-isa（读 main.npdm 的 META 标志，pack/nx_unpack/Inspect.cs NpdmIsa；oneclick.sh 同用）。
#   队列的「指令集」列读的是本体，更新可能把 32 位本体换成 64 位（Captain Toad 1.1.0 标 aarch32，实为 64 位），所以按解出的 main.npdm 判。
#   马力欧卡丁车 8 豪华版那份原件（本体 1.0.0 + 更新 3.0.0）确实是 32 位：11-01 清点目录里那份是 10-15 从别的版本拷来的旧 exefs，曾误读成 64 位
_NXU = None
def nx_unpack():
    global _NXU
    if _NXU is None:   # 同 pack/srcs.sh 的取法：S2A_NX_UNPACK 给了就用，没给按本树源码哈希取编好的那份（没有就现编）
        _NXU = os.environ.get('S2A_NX_UNPACK') or subprocess.run(['bash', '-c', 'source "$1" > /dev/null 2>&1; echo "$SRC_N"', '_', str(ROOT / 'pack/srcs.sh')],
                                                                 capture_output=True, text=True).stdout.strip()
    return _NXU


def is_32_game(exefs):
    r = subprocess.run([nx_unpack(), '--npdm-isa', os.path.join(exefs, 'main.npdm')], capture_output=True, text=True)
    if r.returncode or r.stdout.strip() not in ('aarch64', 'aarch32'): raise OSError(f'main.npdm 判不出位数（nx_unpack --npdm-isa rc={r.returncode}：{(r.stderr or r.stdout).strip()[:80]}）')
    return r.stdout.strip() == 'aarch32'


def classify(nm, gl, nvn, table):
    if nm.startswith(('gl', 'egl')): return None if nm in gl else ('EGL 缺口' if nm.startswith('egl') else 'GL 缺口')
    if nm in nvn: return None
    return 'NVN 未实现' if nm in table else 'NVN 查不到'


def main(a):
    if not a or a[0].startswith('--'): sys.exit(__doc__)
    root, a = a[0], a[1:]
    opt = collections.defaultdict(list); k = None
    for x in a:
        if x.startswith('--'): k = x; opt[k]
        else: opt[k].append(x)
    names = {}
    for q in opt['--names']:
        for line in open(q, encoding='utf-8'):
            c = line.rstrip('\n').split('\t')
            if len(c) > 1 and c[0] != '键': names[c[0]] = c[1]
    if os.path.exists(os.path.join(root, 'main')): games = [(os.path.basename(root.rstrip('/')), root)]
    elif names:   # 分母 = 清点队列（款名表）里的全部款：队列有、ExeFS 没抽到的算读不动，目录里多出的不在分母
        games = [(k, os.path.join(root, k)) for k in sorted(names)]
    else: games = [(d, os.path.join(root, d)) for d in sorted(os.listdir(root)) if os.path.exists(os.path.join(root, d, 'main'))]
    gl, nvn, table = implemented()
    who = collections.defaultdict(set); src = collections.defaultdict(set)
    b32, unreadable = [], []   # 32 位款（jhz 11-01：暂不支持，单列、不进缺口表、不算读不动）；读不动款（工具缺陷，目标 0）
    for key, ex in games:
        try:
            if is_32_game(ex): b32.append(key); continue
            u, bad = used(ex)
        except Exception as e:
            print(f'【红】{key} 读不动：{type(e).__name__} {e}', file=sys.stderr); unreadable.append(key); continue
        if bad: unreadable.append(key)
        for nm, s in u.items(): who[nm].add(key); src[nm] |= s
    skip = set(b32) | set(unreadable)
    gone = 0
    for lg in opt['--logs']:
        m = re.search(r'([0-9A-Fa-f]{16})', lg); key = m.group(1).upper() if m else os.path.basename(os.path.dirname(lg))
        if key in skip: continue
        try: f = open(lg, encoding='utf-8', errors='replace')
        except OSError: gone += 1; continue   # 日志在清点期间被清掉（普查腾盘）：跳过、计数
        for line in f:
            for r in LOGNAME:
                for nm in r.findall(line):
                    if API.match(nm): who[nm].add(key); src[nm].add('运行期红行')
    rows = sorted(((nm, classify(nm, gl, nvn, table)) for nm in who), key=lambda r: (-len(who[r[0]]), r[0]))
    gaps = [(nm, c) for nm, c in rows if c]
    hdr = ['符号', '款数', '类别', '来源', '款名']
    out = [hdr] + [[nm, str(len(who[nm])), c, '/'.join(sorted(src[nm])), '、'.join(names.get(k, k) for k in sorted(who[nm]))] for nm, c in gaps]
    if opt['--tsv']: Path(opt['--tsv'][0]).write_text(''.join('\t'.join(r) + '\n' for r in out), encoding='utf-8')
    by = collections.Counter(c for _, c in gaps)
    if opt['--gap']:
        Path(opt['--gap'][0]).write_text(('32 位' if b32 else '读不动' if unreadable else
            f"{len(gaps)}（{'、'.join(f'{c} {n}' for c, n in by.most_common())}）" if gaps else '0') + '\n', encoding='utf-8')
    if gone: print(f'【黄】{gone} 份日志读时已不在（跳过）')
    n64 = len(games) - len(b32)
    print(f'清点 {len(games)} 款 = {n64} 款 64 位 + {len(b32)} 款 32 位（暂不支持：' + '、'.join(names.get(k, k) for k in b32) + '）；'
          f'读不动 {len(unreadable)} 款' + ('（' + '、'.join(names.get(k, k) for k in unreadable) + '）' if unreadable else '') + '；'
          f'用到 GL / EGL / NVN 名字 {len(rows)} 个，缺口 {len(gaps)} 个（' + '、'.join(f'{c} {n}' for c, n in by.most_common()) + '）')
    for r in out[1:21]: print('  ' + '\t'.join(r[:4]) + '\t' + r[4][:120])
    return 1 if ('--check' in opt and (gaps or unreadable)) else 0


if __name__ == '__main__': sys.exit(main(sys.argv[1:]))

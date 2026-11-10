#!/usr/bin/env python3
# 离线着色器库：SPIR-V 目录 → metallib + 索引（GAL 第 4 块；iOS 上运行时不现编，按 SPIR-V 键查这里）。
# 用法：gal_offline.py <SPIR-V 目录> <输出目录> <ios|macos>    环境 J = 并行编译数（缺省 = 核数；10-20 前上限 8，18 核机只用了一半）、GAL_XC = gal_xc 路径（缺省 <仓库根>/build/gal/gal_xc）、GAL_XC_DONE=1 = 输出目录里 gal_xc 已跑过（跳过 ①）
# 步骤：① gal_xc：每支 SPIR-V → <键>.metal + gal.idx（与运行时现编同一份翻译代码）；② 并行 xcrun metal -c → .air；③ 按键序分片，每片 xcrun metallib → gal.<片号>.metallib。
# 产物：<输出目录>/gal.<片号>.metallib、gal.shards（每行「首键 16 位十六进制<TAB>文件名」，按键升序）、gal.idx（运行时 nxgal_prog_lib_open(目录)）；中间 .metal / .air 留在 <输出目录>/msl 供排查。
# 分片（10-20）：整库一块要几百 MB 连续地址，iPhone 低区空洞被 C# 初始化与线程栈打碎（巫师3 365 MB 开不了）；每片 ≤64 MB（切片目标 GAL_SHARD_MB）。
import bisect, os, re, subprocess, sys, threading, concurrent.futures as cf

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../..'))
src, out, plat = sys.argv[1], sys.argv[2], sys.argv[3]
sdk = {'ios': 'iphoneos', 'macos': 'macosx'}[plat]
J = max(1, int(os.environ.get('J', str(os.cpu_count() or 8))))
xc = os.environ.get('GAL_XC', os.path.join(ROOT, 'build/gal/gal_xc'))
os.makedirs(out, exist_ok=True)
if os.environ.get('GAL_XC_DONE') == '1' and os.path.exists(os.path.join(out, 'gal.idx')):   # ① 已由调用方跑过（graphics/tools/shbake 出包时为拼宿主程序二进制先跑了 gal_xc）：不重翻
    print('gal_offline：gal_xc 已跑过（GAL_XC_DONE=1），直接编 MSL')
else:
    r = subprocess.run([xc, src, out, '0' if plat == 'ios' else '1'], capture_output=True, text=True, timeout=3600)
    sys.stdout.write(r.stdout); sys.stderr.write(r.stderr[-4000:])
    if r.returncode: sys.exit('【红】gal_xc 失败')
msl_dir = os.path.join(out, 'msl')
mets = sorted(f for f in os.listdir(msl_dir) if f.endswith('.metal'))
# 进度（10-26 维护者：进行中的环节要看得到着色器编了多少）：按支数写 S2A_PROGRESS（tools/progress.py，调用方没给就不写）
sys.path.insert(0, os.path.join(ROOT, 'tools')); from progress import Ticker
tk = Ticker('通用兜底·编 metallib', len(mets))
# .air 内容寻址缓存（10-19 出包线，按阶段缓存第一刀）：键 = sha256(MSL 源码 + 平台 + metal 编译器版本)，共享目录 GAL_AIR_CACHE（缺省 ~/.s2arm/run/gal_air_cache/<平台>）；
# 命中就 APFS 克隆进本次 msl/（不占空间）。原先只按同目录 mtime 复用，newarch_full 每次新建合并目录，马车8 14112 支每次全编 460 秒
import hashlib, shutil, ctypes
_libc = ctypes.CDLL(None, use_errno=True)
def clone(src, dst):
    """APFS 克隆（与 cp -c 同为 clonefile(2)，不起子进程：马车8 两万多键全命中时逐键起 cp 要约 100 秒）：dst 已在先删；成功返回 True"""
    try: os.unlink(dst)
    except FileNotFoundError: pass
    return _libc.clonefile(os.fsencode(src), os.fsencode(dst), 0) == 0
mver = subprocess.run(['xcrun', '-sdk', sdk, 'metal', '--version'], capture_output=True, text=True).stdout.strip()
# 着色器库里记着目标系统版本：不给就按 SDK 版本（26）编，老系统加载不了（小菠萝 10-13 撞过）。按产品下限编（iOS 18 / macOS 15，与 Makefile 一致），且进缓存键
TC = dict(l.strip().split('=', 1) for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'tools', 'toolchain.env')) if '=' in l and not l.lstrip().startswith('#'))   # 下限只取统一工具链那两行
MINV = {'ios': f"-mios-version-min={TC['IPHONEOS_DEPLOYMENT_TARGET']}", 'macos': f"-mmacosx-version-min={TC['MACOSX_DEPLOYMENT_TARGET']}"}[plat]
# 与运行时 gal_msl_opts（gal_prog.m）同口径：relaxed 不许编译器假设没有 NaN / Inf（翻译后的 isnan 选择要留住，#807），preserve-invariance 给 [[invariant]] 位置
MATH = ['-fmetal-math-mode=relaxed', '-fpreserve-invariance']
MATHK = ('\0' + '\0'.join(MATH)).encode()   # 编译旗进 .air 缓存键（11-01 审计 P2-41：只改旗时旧 .air 照样命中）
cache = os.path.join(os.environ.get('GAL_AIR_CACHE', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 'gal_air_cache')), plat); os.makedirs(cache, exist_ok=True)
hits = [0]
def hit_cache(ca, dst):
    """缓存命中：克隆进 dst 并刷新条目修改时间（克隆不读数据、本机读文件也不更新访问时间，不刷新的话 gc 只能按写入先后删、常用条目先删）；
    条目不在或克隆失败（gc 恰好删了）返回 False，照常编译"""
    if not os.path.exists(ca): return False
    if not clone(ca, dst): return False
    try: os.utime(ca)
    except OSError: pass
    return True

def avail_bytes():
    v = subprocess.run(['vm_stat'], capture_output=True, text=True).stdout
    pg = int(re.search(r'page size of (\d+)', v).group(1))
    n = lambda k: int(m.group(1)) if (m := re.search(k + r':\s+(\d+)', v)) else 0
    return (n('Pages free') + n('Pages inactive') + n('Pages speculative') + n('Pages purgeable')) * pg
# 编译并发按内存定、不按核数（10-26 交付线 Spare-host M3 斯普拉遁3：通用段两轮都卡在同一批 68a54d8545534700_u133_f——133 支合编、批里有 19.4 MB / 13.6 MB 两支巨型 MSL；
#   本机实测 19.4 MB 那支单编 91 秒、峰值内存 4.2 GB，Spare-host 当时空闲内存只剩约 430 MB、直连段同时在跑，一换页慢几倍，600 秒没新文件被判挂死）。同链接段的口径（admit）：
#   每个编译任务峰值估 = 64 MB + MSL 字节 × (80 + 135 × min(1, 字节 / 20 MB))：随大小超线性，本机 iOS 目标单编实测 83 KB → 65 MB、131 KB → 77 MB、
#   519 KB → 102 MB、19.4 MB → 4.16 GB，公式依次给 70 / 74 / 105 MB、3.9 GB（大支略低估 7%，有保底 4 GB 兜着）（GAL_COMP_K 整体乘一个系数自调，缺省 1）。开工前同时满足「本进程在跑估值合计 + 本任务 ≤ 预算」
#   （GAL_COMP_MEM_GB，缺省 = 起步时可用内存 × 0.6）与「此刻系统可用内存 − 保底 4 GB ≥ 本任务」；本进程一个都没在跑时照开（单个超预算也得编，不死等）
COMP_K = float(os.environ.get('GAL_COMP_K', '1'))
cbudget = int(float(os.environ['GAL_COMP_MEM_GB']) * (1 << 30)) if os.environ.get('GAL_COMP_MEM_GB') else int(avail_bytes() * 0.6)
cmu = threading.Condition(); crun = [0, 0]   # 在跑估值合计、在跑个数
import contextlib
@contextlib.contextmanager
def mem_slot(src_bytes):
    e = int(((64 << 20) + src_bytes * (80 + 135 * min(1.0, src_bytes / (20 << 20)))) * COMP_K)
    with cmu:
        while crun[1] and (crun[0] + e > cbudget or avail_bytes() - (4 << 30) < e): cmu.wait(2)
        crun[0] += e; crun[1] += 1
    try: yield
    finally:
        with cmu: crun[0] -= e; crun[1] -= 1; cmu.notify_all()
def comp(f):
    src_p = os.path.join(msl_dir, f); air = os.path.join(msl_dir, f[:-6] + '.air')
    key = hashlib.sha256(open(src_p, 'rb').read() + plat.encode() + mver.encode() + MINV.encode() + MATHK).hexdigest(); ca = os.path.join(cache, key[:2], key + '.air')
    if hit_cache(ca, air): hits[0] += 1; return f, 0, ''
    with mem_slot(os.path.getsize(src_p)): p = subprocess.run(['xcrun', '-sdk', sdk, 'metal', MINV, *MATH, '-c', src_p, '-o', air], capture_output=True, text=True, timeout=1800)
    if p.returncode == 0:
        os.makedirs(os.path.dirname(ca), exist_ok=True); tmp = f'{ca}.{os.getpid()}.tmp'; shutil.copyfile(air, tmp); os.replace(tmp, ca)
    return f, p.returncode, p.stderr[-800:]
bad = []
# 合并编译（10-23 用户体验线实测：逐支起 metal 每支都从头解析 metal_stdlib / SPIRV-Cross 模板 / s2a_* 辅助，0.178 s/支；合 25 支 0.036、合 400 支 0.028 s/支）：
#   按键序把相邻若干支（GAL_UNITY_N，缺省 48；1 = 关、逐支编）合成一个编译单元：公共 include / using / pragma 只留一份，每支整体包进 namespace n<文件名>，
#   入口函数加 [[host_name("<原名>")]] 保持对外名字不变，每支后面 #undef 它自己 #define 过的宏（S2A_HALF_ROUND 的 #ifndef 守卫否则会让后面的支缺定义）。
#   切批：预处理签名（#pragma METAL / #include 集合，例如 73 / 5034 支没有 fp contract(off)）变了就切，键与它的 _np 变体不拆开；批内容哈希作缓存键。
#   切点按键值定、不按支数（键本身是哈希：键 mod GAL_UNITY_N == 0 处开新批，平均 N 支一批）：增删一支只改它所在那一批，别的批内容不变、缓存照中
#   （按支数切则前面插一支、后面所有批整体错位，增量重烘退化成全编）。单批上限 4N 支兜底。
#   一批编不过 → 这批退回逐支编，定位到支、照旧记 metal_failed.txt。等价性：graphics/metal/tools/unity_check.py 逐函数比 AIR（同一份 MSL 逐支 vs 合编）
UNITY_N = max(1, int(os.environ.get('GAL_UNITY_N', '48')))
# 大 MSL 不进合编批（10-26 同上）：合编一批只能用一个核，一支巨型 MSL 把整批 100 多支拖成十几分钟的长尾；超过 GAL_UNITY_BIG_KB（缺省 1024 KB）的单独编，
#   与各批放进同一个池、按字节大的先开。切批仍按键值，只有原先含大支的那几批内容变
BIG = int(os.environ.get('GAL_UNITY_BIG_KB', '1024')) * 1024
UNITY_V = b'unity v1'
assert all(re.match(r'[0-9a-f]{16}', f) for f in mets), 'MSL 文件名须以 16 位十六进制键开头（切批按键值）'
_GLOBAL = re.compile(r'^\s*(#\s*include\s*<[^>]+>|#\s*pragma\s+(?:METAL|clang)\b.*|using\s+namespace\s+metal\s*;)\s*$', re.M)
_ENTRY = re.compile(r'^((?:\[\[[^\]]*\]\]\s*)*(?:fragment|vertex|kernel)\s+.*?\b)(s[0-9a-f]{16}\w*)(\s*\()', re.M)
def _sig(txt):   # 影响代码生成的全局指令集合：fp contract 与 include 不同的支不进同一批
    return tuple(sorted(set(l.strip() for l in re.findall(r'^\s*(?:#\s*include\s*<[^>]+>|#\s*pragma\s+METAL\b.*)$', txt, re.M))))
def _unity_src(fs):
    head = set(); body = []
    for f in fs:
        t = open(os.path.join(msl_dir, f), errors='replace').read()
        head.update(l.strip() for l in _GLOBAL.findall(t))
        t2, n = _ENTRY.subn(lambda m: f'{m.group(1)}{m.group(2)} [[host_name("{m.group(2)}")]]{m.group(3)}', _GLOBAL.sub('', t))
        if n < 1: return None, f'{f}：没认出入口函数'
        undef = ''.join(f'#undef {d}\n' for d in dict.fromkeys(re.findall(r'^\s*#\s*define\s+(\w+)', t, re.M)))
        body.append(f'namespace n{f[:-6]} {{\n{t2}\n}}\n{undef}')
    hl = sorted(head, key=lambda l: (0 if l.startswith('#pragma') else 1 if l.startswith('#include') else 2, l))
    return '\n'.join(hl) + '\n' + ''.join(body), None
def comp_batch(fs, head=None, tag=''):
    """一批合编：返回 (批 .air 路径 或 None, 失败原因)。head = 所在整批的首键（.air 文件名前缀，分片按它分组：同一批的各阶段子批同片，见 _stage）"""
    src_txt, why = _unity_src(fs)
    if src_txt is None: return None, why
    data = src_txt.encode()
    key = hashlib.sha256(UNITY_V + data + plat.encode() + mver.encode() + MINV.encode() + MATHK).hexdigest(); ca = os.path.join(cache, 'u' + key[:2], key + '.air')
    air = os.path.join(msl_dir, f'{(head or fs[0])[:16]}_u{len(fs)}{tag}.air')
    if hit_cache(ca, air): hits[0] += len(fs); return air, ''
    usrc = os.path.join(msl_dir, f'{fs[0][:16]}_u{len(fs)}.metal.unity')
    open(usrc, 'w').write(src_txt)
    with mem_slot(len(data)): p = subprocess.run(['xcrun', '-sdk', sdk, 'metal', MINV, *MATH, '-x', 'metal', '-c', usrc, '-o', air], capture_output=True, text=True, timeout=1800)
    if p.returncode: return None, p.stderr[-800:]
    os.makedirs(os.path.dirname(ca), exist_ok=True); tmp = f'{ca}.{os.getpid()}.tmp'; shutil.copyfile(air, tmp); os.replace(tmp, ca)
    return air, ''
units = []   # 进库的 .air（逐支或批）
if UNITY_N > 1:
    sigs = {f: _sig(open(os.path.join(msl_dir, f), errors='replace').read()) for f in mets}
    solo = [f for f in mets if os.path.getsize(os.path.join(msl_dir, f)) > BIG]; solo_s = set(solo)
    batches, cur = [], []
    for f in (f for f in mets if f not in solo_s):   # mets 已按文件名（键）升序
        if cur and (sigs[f] != sigs[cur[0]] or (f[:16] != cur[-1][:16] and (int(f[:16], 16) % UNITY_N == 0 or len(cur) >= 4 * UNITY_N))): batches.append(cur); cur = []
        cur.append(f)
    if cur: batches.append(cur)
    # 批内再按阶段拆成子批各自编、各自按内容缓存（10-24 vpull-fast 只改顶点，怪猎 MSL 仍重编 13661 / 14199：一批 48 支里顶点片元交错，任一顶点变了整批的键就变）。
    #   批的切法（键连续、切点按键值）不动：子批的 .air 都以整批首键开头，分片按首键分组时同一批仍同片，每片仍是连续键区间（运行时按 gal.shards 首键二分）
    def _stage(f):
        m = _ENTRY.search(open(os.path.join(msl_dir, f), errors='replace').read())
        return next((k for k in ('vertex', 'fragment', 'kernel') if m and k in m.group(1).split()), '?')
    subs = []
    for b in batches:
        st = {}
        for f in b: st.setdefault(_stage(f), []).append(f)
        subs += [(b[0], fs, '' if len(st) == 1 else '_' + k[0]) for k, fs in sorted(st.items())]
    batches = [fs for _, fs, _ in subs]
    jobs = [('b', i, sum(os.path.getsize(os.path.join(msl_dir, f)) for f in batches[i])) for i in range(len(batches))] + [('s', f, os.path.getsize(os.path.join(msl_dir, f))) for f in solo]
    jobs.sort(key=lambda j: -j[2])
    def run_job(j): return comp_batch(batches[j[1]], subs[j[1]][0], subs[j[1]][2]) if j[0] == 'b' else comp(j[1])
    fallback = []; nb_fail = [0]
    with cf.ThreadPoolExecutor(J) as ex:
        for j, r in zip(jobs, ex.map(run_job, jobs)):
            tk.step(1 if j[0] == 's' else len(batches[j[1]]))   # 实时计数（任务页「通用兜底·编 metallib」）：单支 1、一批按支数；失败退回逐支的不重计
            if j[0] == 's':
                f, rc, err = r
                if rc: bad.append((f, err))
                else: units.append(os.path.join(msl_dir, f[:-6] + '.air'))
                continue
            i, (air, why) = j[1], r
            if air: units.append(air)
            else: fallback += batches[i]; nb_fail[0] += 1; print(f'gal_offline：合编第 {i} 批（{len(batches[i])} 支，首 {batches[i][0]}）失败，退回逐支编：{why.strip().splitlines()[0] if why.strip() else ""}')
    with cf.ThreadPoolExecutor(J) as ex:
        for f, rc, err in ex.map(comp, sorted(fallback, key=lambda f: -os.path.getsize(os.path.join(msl_dir, f)))):
            if rc: bad.append((f, err))
            else: units.append(os.path.join(msl_dir, f[:-6] + '.air'))
    print(f'gal_offline：合编 {len(batches)} 批（按键值切、平均 {UNITY_N} 支，最大 {max(map(len, batches), default=0)} 支），大 MSL（> {BIG >> 10} KB）单独编 {len(solo)} 支'
          f'{"（最大 %.1f MB）" % (max(os.path.getsize(os.path.join(msl_dir, f)) for f in solo) / 1e6) if solo else ""}，失败退回逐支 {nb_fail[0]} 批 / {len(fallback)} 支；编译内存预算 {cbudget >> 20} MB')
else:
    # 大的先编（10-20：最大的 MSL 约 1 MB、单支 10 s，排到最后会拖出长尾）；产物与提交顺序无关（各写各的 .air，metallib 按 mets 原序链接）
    order = sorted(mets, key=lambda f: -os.path.getsize(os.path.join(msl_dir, f)))
    with cf.ThreadPoolExecutor(J) as ex:
        for f, rc, err in ex.map(comp, order):
            tk.step()
            if rc: bad.append((f, err))
    units = [os.path.join(msl_dir, f[:-6] + '.air') for f in mets if f not in {b[0] for b in bad}]
with open(os.path.join(out, 'metal_failed.txt'), 'w') as fh:
    for f, err in bad: fh.write(f'{f}\t{err.strip().splitlines()[0] if err.strip() else ""}\n')
airs = units
# 分片：mets 按文件名（= 键的 16 位小写十六进制）升序，每片是一段连续键区间（运行时按 gal.shards 的首键二分）。按 .air 字节累计切，链接后实测每片 ≤ 上限，超了报红
# 切片目标 GAL_SHARD_MB（缺省 4，按 .air 字节累计）；硬上限 64 MB 恒查（单测设小目标走多片，不放宽上限）。
#   缺省 56 → 4（10-21）：metallib 一次链接的峰值内存与用时随片大小超线性涨。马车8 同一批 .air 取前 N 支串行实测（Xcode 缺省工具链）：
#   .air 1.8 MB → 峰值 0.09 GB / 0 秒；3.6 MB → 0.19 GB / 1 秒；6.9 MB → 0.54 GB / 5 秒；13.7 MB → 1.77 GB / 29 秒；27.6 MB → 6.06 GB / 259 秒；
#   56 MB 跑 5 分钟已 22 GB 还在涨（旧缺省 8 片并行即 11:5x 吃满 128 GB 那次）。4 MB 一片约 0.2 GB、1 秒，峰值 ≈ .air × 55，按 LINK_K 估。
#   片数：现九款最大怪猎 .air 约 430 MB → 约 110 片，运行时上限 OFF_MAXLIB（gal_prog.m）1024 片。
MB = 64 << 20; AIR_MB = int(float(os.environ.get('GAL_SHARD_MB', '4')) * 1048576)
for f in os.listdir(out):
    if f == 'gal.metallib' or (f.startswith('gal.') and f.endswith('.metallib')): os.remove(os.path.join(out, f))   # 旧产物（单库 / 上次分片）
# 同键的主份与无点大小变体（<键>.air / <键>_np.air）须同片：先按键分组，只在换键处切
# 按阶段拆子批后（见合编段），某子批编不过退回逐支的 <键>.air 也要按所在整批的首键分组，否则同一批会散到两片、片内键区间不连续
head_of = {f[:16]: b0[:16] for b0, fs, _ in subs for f in fs} if UNITY_N > 1 else {}
# 大 MSL 单独编的键落在某批的键区间中间时，跟那批同组（11-01 审计 P1-35：原先自成一组，切片恰好切在它前后，后一片首键 < 前一片里的函数键，按首键二分找错片）
if UNITY_N > 1 and solo:
    heads = sorted({b0[:16] for b0, _, _ in subs}); last = {}
    for b0, fs, _ in subs: last[b0[:16]] = max(last.get(b0[:16], ''), max(f[:16] for f in fs))
    for f in solo:
        i = bisect.bisect_right(heads, f[:16]) - 1
        if i >= 0 and f[:16] < last[heads[i]]: head_of[f[:16]] = heads[i]   # 键在这批首末之间：并进这批
groups = {}
for a in airs: k = os.path.basename(a)[:16]; groups.setdefault(head_of.get(k, k), []).append(a)
shards, cur, sz = [], [], 0
for k in sorted(groups):
    n = sum(os.path.getsize(a) for a in groups[k])
    if cur and sz + n > AIR_MB: shards.append(cur); cur, sz = [], 0
    cur += groups[k]; sz += n
if cur: shards.append(cur)
if len(shards) > 1024: sys.exit(f'【红】分片 {len(shards)} 片超运行时上限 1024（gal_prog.m OFF_MAXLIB）：调大 GAL_SHARD_MB 或 OFF_MAXLIB')
# 文件多时分批先合成中间库会改函数可见性；每片一次链接。.air 清单走响应文件 @<文件>（10-19：9492 支长路径超命令行 1 MB 上限，Errno 7）
# 链接并发按内存定、不按核数（10-21 马车8：8 片同时链接，每个常驻 4.4–7.2 GB、合计 47 GB，整机空闲 64 MB、维护者 被迫重启）：
#   每片峰值估 = 本片 .air 字节 × LINK_K（metallib 把整片位码读进一个 LLVM 上下文，峰值随片大小涨，系数实测见下）；
#   开下一片前要同时满足：本进程在跑的估值合计 + 本片 ≤ 预算（GAL_LINK_MEM_GB，缺省 = 起步时可用内存 × 0.6），
#   且此刻系统可用内存 − 在跑各片还没涨到的部分 − 保底 8 GB ≥ 本片估值；本进程一片都没在跑时照开（单片超预算也得链）。
LINK_K = float(os.environ.get('GAL_LINK_K', '64'))   # 峰值 / .air 字节：≤4 MB 片实测 52–55，取 64 留余量（片越大系数越大，大片靠 GAL_LINK_K 自调）
def rss_bytes(pid):
    r = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    return int(r) * 1024 if r.isdigit() else 0
est = [int(sum(os.path.getsize(a) for a in sh) * LINK_K) for sh in shards]
budget = int(float(os.environ['GAL_LINK_MEM_GB']) * (1 << 30)) if os.environ.get('GAL_LINK_MEM_GB') else int(avail_bytes() * 0.6)
mu = threading.Condition(); running = {}   # 片号 → [估值, pid]
peak_par = [0]
def admit(i):
    with mu:
        while running:
            grow = sum(max(0, e - rss_bytes(pid)) for e, pid in running.values() if pid)
            if sum(e for e, _ in running.values()) + est[i] <= budget and avail_bytes() - grow - (8 << 30) >= est[i]: break
            mu.wait(2)
        running[i] = [est[i], 0]; peak_par[0] = max(peak_par[0], len(running))
def link(i):
    rsp = os.path.join(out, f'airs.{i}.rsp'); open(rsp, 'w').write(''.join(f'"{a}"\n' for a in shards[i]))
    lib = os.path.join(out, f'gal.{i}.metallib')
    admit(i)
    try:
        pr = subprocess.Popen(['xcrun', '-sdk', sdk, 'metallib', '@' + rsp, '-o', lib], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        with mu: running[i][1] = pr.pid
        try: _, err = pr.communicate(timeout=3600)
        except subprocess.TimeoutExpired:
            pr.kill(); pr.communicate(); return i, 124, '链接超 3600 秒'
        return i, pr.returncode, (err or '')[-2000:]
    finally:
        with mu: running.pop(i, None); mu.notify_all()
with cf.ThreadPoolExecutor(J) as ex:
    for i, rc, err in ex.map(link, range(len(shards))):
        if rc: sys.exit(f'【红】metallib 第 {i} 片链接失败：' + err)
big = [(i, os.path.getsize(os.path.join(out, f'gal.{i}.metallib'))) for i in range(len(shards))]
with open(os.path.join(out, 'gal.shards'), 'w') as fh:
    for i, sh in enumerate(shards): fh.write(f'{min(os.path.basename(a)[:16] for a in sh)}\tgal.{i}.metallib\n')   # 首键 = 片内实际最小函数键（不是清单第一项）
print(f'gal_offline：MSL {len(mets)} 支（缓存命中 {hits[0]}，现编 {len(mets) - hits[0]}），metal 编译失败 {len(bad)}，入库 {len(airs)} → {len(shards)} 片，最大 {max((b for _, b in big), default=0) / 1048576:.1f} MB；'
      f'链接内存预算 {budget / (1 << 30):.1f} GB（每片峰值估 ≤{max(est, default=0) / (1 << 30):.1f} GB），最多同时 {peak_par[0]} 片')
if any(b > MB for _, b in big): sys.exit(f'【红】分片超上限 {MB >> 20} MB：' + ', '.join(f'第 {i} 片 {b / 1048576:.1f} MB' for i, b in big if b > MB))
# 有支编不过 = 库缺支：走红通道非 0 退出（审计 P2-208：原先只打一行红照退 0，tests/visual/widen_gate.sh 只看退出码会把缺支的库装上）。
#   metal_failed.txt 照写（shader_pack.sh 的红计数、pso_gen.py 跳过缺的函数都读它）
if bad: sys.exit(f'【红】metal 编译失败 {len(bad)} 支，首例：{bad[0][0]}：{bad[0][1].strip()[:300]}')

#!/usr/bin/env python3
# 平台耦合全量盘点（10-30 平台 adapter 边界设计 P0，jhz 要求按全部模块机械盘点、从数据推边界）：只读，不改任何文件。
#   扫 compat/tree/src 每个项目（Ryujinx.HLE 按 HOS/Services/<服务> 细分，Ryujinx.Horizon 按顶层目录细分）和 services/ 下每个项目，逐行归类：
#     苹果 / 安卓平台行：OperatingSystem.IsIOS|IsMacOS|IsMacCatalyst|IsTvOS / IsAndroid、RuntimeInformation.IsOSPlatform(OSX / iOS / Android)、
#       指向平台库的 DllImport / LibraryImport（libSystem、/System/Library/Frameworks、CoreFoundation、AudioToolbox、VideoToolbox、objc / android、aaudio、liblog、s2arm_android），
#       以及路径里有 Apple / Android / Darwin 目录的整个文件（例：Ryujinx.Audio.Backends.Apple、Nvdec/Apple）
#     上游其他平台行：IsWindows / IsLinux / IsFreeBSD（上游自带，不归我方迁）
#     共享代码直接引用某平台实现的类型 / 命名空间（例：Exports.cs 缺省 new AppleHardwareDeviceDriver）也算该平台行
#     按名找导出：NativeLibrary.GetExport / TryGetExport（多为找 s2a_* 原生导出：平台装配应改成登记）
#     S2A 钩子：S2AHooks. / S2AHorizonHooks. 调用点（中性接缝，计数供参考）
#   我方补丁：compat/patches/*.patch 逐个统计每个模块被几个补丁碰、增了几行
#   冲突：train/train.log 里「冲突在 <文件>」按模块计（默认近 14 天；--conflicts <文件> 可另给 TSV：路径<TAB>次数，如安卓开发者的 rebase 记录）
# 用法：tools/platform_scan.py [--md] [--days 14] [--conflicts <tsv>] [--trainlog <train.log>]；输出 TSV（缺省）或 Markdown 表（--md）
# 退出码恒 0（盘点工具；P0 的「新增平台逻辑」拦截另做，读本工具的逐行结果对比 main）
import argparse, collections, datetime, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
EXEMPT = '平台例外：'   # 行内写「// 平台例外：<理由>」的行不计（门禁的逐行例外，不设公用白名单）
LINES = []   # --lines：(类别, 路径, 行文本)
def export_key(t):   # 按名找导出按「找的是哪个导出名」计（11-01：同一个导出换个查法——查主程序句柄改查显式 owner——不是新增耦合，按整行文本比会误报）；名字不是字面量的（运行时拼）仍按整行
    names = re.findall(r'"([A-Za-z_][A-Za-z0-9_@.$]*)"', t)
    return '找导出 ' + ' '.join(names) if names else t
APPLE_OS = re.compile(r'OperatingSystem\.Is(IOS|MacOS|MacCatalyst|TvOS|IOSVersionAtLeast|MacOSVersionAtLeast)\b|IsOSPlatform\(OSPlatform\.(OSX|Create\("(IOS|MACCATALYST)"\))')
ANDROID_OS = re.compile(r'OperatingSystem\.IsAndroid\b|OSPlatform\.Create\("ANDROID"\)')
OTHER_OS = re.compile(r'OperatingSystem\.Is(Windows|Linux|FreeBSD)\b|IsOSPlatform\(OSPlatform\.(Windows|Linux|FreeBSD)\)')
IMPORT = re.compile(r'\[(?:DllImport|LibraryImport)\(\s*("?)([^",)]+)\1')
APPLE_LIB = re.compile(r'libSystem|/System/Library/Frameworks|CoreFoundation|AudioToolbox|VideoToolbox|CoreMedia|CoreVideo|libobjc|ObjC|Foundation|Metal\b|mach', re.I)
ANDROID_LIB = re.compile(r'\bandroid\b|aaudio|liblog|s2arm_android|libandroid', re.I)
APPLE_REF = re.compile(r'Backends\.Apple|AppleHardware|VideoToolbox|\bNvdec\.Apple\b')   # 共享代码直接引用苹果实现的类型 / 命名空间
ANDROID_REF = re.compile(r'Backends\.Android|\bAAudio|\bNvdec\.Android\b|AvcH264Decoder|AndroidVp8Decoder')
EXPORT = re.compile(r'NativeLibrary\.(?:Try)?GetExport\(')
HOOK = re.compile(r'\bS2A(?:Horizon)?Hooks\.')
PLAT_DIR = re.compile(r'(^|/)(Apple|Android|Darwin|iOS|MacOS)(/|\.|$)')

def module_of(rel):   # rel 相对仓库根
    p = rel.split('/')
    if rel.startswith('compat/tree/src/'):
        proj = p[3]
        if proj == 'Ryujinx.HLE' and len(p) > 7 and p[4] == 'HOS' and p[5] == 'Services':
            return f'{proj}/Services/{p[6]}'
        if proj == 'Ryujinx.Horizon' and len(p) > 5:
            return f'{proj}/{p[4]}' if not p[4].endswith('.cs') else proj
        return proj
    if rel.startswith('services/') and len(p) > 2:
        return f'services/{p[1]}'
    return None

PATCH_ADDED = collections.defaultdict(set)   # tree 相对仓库根的路径 → 我方补丁新增行（去空白）
def scan_tree(stats):
    for base in ('compat/tree/src', 'services'):
        for d, dirs, files in os.walk(os.path.join(ROOT, base)):
            dirs[:] = [x for x in dirs if x not in ('obj', 'bin')]
            for f in files:
                if not f.endswith('.cs'): continue
                full = os.path.join(d, f); rel = os.path.relpath(full, ROOT); m = module_of(rel)
                if not m: continue
                s = stats[m]; s['files'] += 1
                whole = bool(PLAT_DIR.search(rel.split('/src/', 1)[-1] if '/src/' in rel else rel))
                apple_dir = whole and not re.search(r'Android', rel); android_dir = whole and bool(re.search(r'Android', rel))
                try: lines = open(full, encoding='utf-8', errors='replace').read().split('\n')
                except OSError: continue
                for i, ln in enumerate(lines, 1):
                    t = ln.strip()
                    if not t or t.startswith('//'): continue
                    s['lines'] += 1
                    a = apple_dir or bool(APPLE_OS.search(ln) or APPLE_REF.search(ln)); n = android_dir or bool(ANDROID_OS.search(ln) or ANDROID_REF.search(ln))
                    im = IMPORT.search(ln)
                    if im:
                        lib = im.group(2)
                        if APPLE_LIB.search(lib): a = True; s['imp_apple'] += 1
                        elif ANDROID_LIB.search(lib): n = True; s['imp_android'] += 1
                        else: s['imp_other'] += 1
                    ours = not rel.startswith('compat/tree/') or t in PATCH_ADDED.get(rel, ())   # services/ 全是我方；tree 里看是不是补丁加的行
                    if EXEMPT in ln: ours = False
                    if a and ours: LINES.append(('apple', rel, t))
                    if n and ours: LINES.append(('android', rel, t))
                    if a: s['apple'] += 1; s['apple_ours'] += ours; s['apple_at'].append(f'{rel}:{i}{"" if ours else "（上游）"}')
                    if n: s['android'] += 1; s['android_ours'] += ours; s['android_at'].append(f'{rel}:{i}{"" if ours else "（上游）"}')
                    if OTHER_OS.search(ln): s['other_os'] += 1
                    if EXPORT.search(ln) and ours: LINES.append(('export', rel, export_key(t))); s['export'] += 1; s['export_at'].append(f'{rel}:{i}')   # 上游自带的（例 AppleHv 找 Hypervisor 导出）不算
                    if HOOK.search(ln): s['hook'] += 1

def scan_patches(stats):
    pdir = os.path.join(ROOT, 'compat/patches')
    for f in sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []:
        if not f.endswith('.patch'): continue
        touched = collections.Counter(); cur = None; curp = None
        for ln in open(os.path.join(pdir, f), encoding='utf-8', errors='replace'):
            if ln.startswith('+++ b/'): curp = 'compat/tree/' + ln[6:].strip(); cur = module_of(curp); continue
            if ln.startswith('+++ b/'): pass
            if cur and ln.startswith('+') and not ln.startswith('+++'): touched[cur] += 1; PATCH_ADDED[curp].add(ln[1:].strip())
        for m, n in touched.items(): stats[m]['patches'] += 1; stats[m]['patch_lines'] += n

def scan_conflicts(stats, trainlog, days, extra):
    since = datetime.date.today() - datetime.timedelta(days=days); year = datetime.date.today().year
    if trainlog and os.path.exists(trainlog):
        for ln in open(trainlog, encoding='utf-8', errors='replace'):
            m = re.match(r'\[(\d\d)-(\d\d) ', ln)
            if not m or '冲突在' not in ln: continue
            try:
                if datetime.date(year, int(m.group(1)), int(m.group(2))) < since: continue
            except ValueError: continue
            for path in re.findall(r'冲突在 ([^，（）\s]+)', ln):
                for one in path.split('、'):
                    mod = module_of(one.strip())
                    if mod: stats[mod]['conflicts'] += 1
    if extra:
        for ln in open(extra, encoding='utf-8'):
            if '\t' not in ln or ln.startswith('#'): continue
            path, n = ln.rstrip('\n').split('\t')[:2]; mod = module_of(path.strip())
            if mod: stats[mod]['conflicts'] += int(n or 0)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--md', action='store_true'); ap.add_argument('--days', type=int, default=14)
    ap.add_argument('--conflicts'); ap.add_argument('--trainlog', default=os.path.expanduser('~/.s2arm/run/s2arm/train/train.log'))
    ap.add_argument('--where', help='列出某模块的平台行位置（模块名精确匹配）')
    ap.add_argument('--root', help='扫这棵树（缺省本仓库；门禁用来扫基线导出的目录）')
    ap.add_argument('--gate', help='基线树目录：本树的我方平台行 / 按名找导出比它多就退出 1（只减不增门禁）')
    ap.add_argument('--lines', action='store_true', help='逐行输出我方平台行 / 按名找导出：类别<TAB>路径<TAB>行文本（门禁比较用）')
    a = ap.parse_args()
    global ROOT
    if a.root: ROOT = os.path.abspath(a.root)
    stats = collections.defaultdict(lambda: collections.defaultdict(int) | {'apple_at': [], 'android_at': [], 'export_at': []})
    scan_patches(stats); scan_tree(stats); scan_conflicts(stats, a.trainlog, a.days, a.conflicts)
    if a.lines:
        for (k, r, t), c in sorted(collections.Counter(LINES).items()): print(f'{c}\t{k}\t{r}\t{t}')
        return 0
    if a.gate:   # 只减不增：本树每个（类别, 行文本）的总次数不得多于基线树——不看在哪个文件：原样搬到别的共享文件（#1067 源码分区）不算新增，同样的行多写一处照样 +1
        head_at = collections.Counter(LINES); head = collections.Counter()
        for (k, r, t), c in head_at.items(): head[(k, t)] += c
        LINES.clear(); base_root = os.path.abspath(a.gate); ROOT = base_root
        stats2 = collections.defaultdict(lambda: collections.defaultdict(int) | {'apple_at': [], 'android_at': [], 'export_at': []})
        PATCH_ADDED.clear(); scan_patches(stats2); scan_tree(stats2)
        base_at = collections.Counter(LINES); base = collections.Counter()
        for (k, r, t), c in base_at.items(): base[(k, t)] += c
        def where(k, t):   # 点名：本树里这行比基线多出来的文件（找不到就列出现它的全部文件）
            files = sorted({r for (kk, r, tt) in head_at if kk == k and tt == t})
            more = [r for r in files if head_at[(k, r, t)] > base_at[(k, r, t)]]
            return '、'.join(more or files)
        grown = [(k, where(k, t), t, head[(k, t)] - base[(k, t)]) for (k, t) in head if head[(k, t)] > base[(k, t)]]
        kind = {'apple': '苹果平台行', 'android': '安卓平台行', 'export': '按名找导出'}
        for k, r, t, d in sorted(grown): print(f'【红】新增{kind[k]}（+{d}）：{r}：{t[:160]}')
        print(f'平台耦合只减不增：基线 {sum(base.values())} 处、本树 {sum(head.values())} 处、新增 {sum(d for *_, d in grown)} 处'
              + ('' if not grown else '（共享代码不许新增平台判断 / 平台库导入 / 按名找导出。落点：公用核心 runtime/src 的 s2a_* 导出 → services/S2A.Services/Native.cs 的 Imports 集中声明 [DllImport("s2a_native")]（各端 DirectPInvoke 静态链、缺符号链接期报）；平台差异 → 平台实现放 platforms/<平台>/ 并登记接口；确需例外在该行写「// 平台例外：<理由>」）'))
        return 1 if grown else 0
    if a.where:
        s = stats.get(a.where, {})
        for k in ('apple_at', 'android_at', 'export_at'):
            for x in s.get(k, []): print(f'{k[:-3]}\t{x}')
        return 0
    cols = ['files', 'lines', 'apple_ours', 'android_ours', 'apple', 'android', 'other_os', 'imp_apple', 'imp_android', 'export', 'hook', 'patches', 'patch_lines', 'conflicts']
    head = ['模块', '文件', '行', '我方苹果行', '我方安卓行', '苹果行（含上游）', '安卓行（含上游）', '上游其他平台行', '苹果库导入', '安卓库导入', '按名找导出', 'S2A钩子', '我方补丁数', '补丁增行', f'近{a.days}天冲突', '判定']
    rows = []
    for m in sorted(stats):
        s = stats[m]
        verdict = ('我方平台专属，要迁' if s['apple_ours'] or s['android_ours'] or s['export'] else
                   '只有上游平台判断，不动' if s['apple'] or s['android'] else '纯共用、我方改过' if s['patches'] else '纯共用，不动')
        rows.append([m] + [str(s[c]) for c in cols] + [verdict])
    rows.sort(key=lambda r: (-(int(r[3]) + int(r[4]) + int(r[10])) * max(1, int(r[14])), r[0]))   # （我方平台行 + 按名找导出）× 冲突次数
    if a.md:
        print('| ' + ' | '.join(head) + ' |'); print('|' + '---|' * len(head))
        for r in rows: print('| ' + ' | '.join(r) + ' |')
    else:
        print('\t'.join(head))
        for r in rows: print('\t'.join(r))
    return 0

if __name__ == '__main__':
    sys.exit(main())

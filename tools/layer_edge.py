#!/usr/bin/env python3
# 分层边检查（架构梳理阶段一 1-1，11-07；依据《架构分层方案》4.3）。复用 tools/layer_map.tsv 判层，不另造地图。
#   python3 tools/layer_edge.py check [<仓库根>]         现有边与豁免表 tools/layer_exempt.tsv 对账：未登记的越界边 → 红；豁免里的边已不存在（过时）→ 红
#   python3 tools/layer_edge.py edges [<仓库根>]         打印全部越界边（规则<TAB>来源文件:行<TAB>对方），不对账
#   python3 tools/layer_edge.py write-exempt [<仓库根>]  按现状重写豁免表（只在首次建表 / 归位 PR 同笔删行后核对时用；新增越界不许靠它放行）
# 边的来源（第一版，方案 4.3.4「先把 include / Compile / 构建路径边做准确」）：
#   C / ObjC 的 #include / #import "..."（相对本文件解析；解析不到再按仓库内同名唯一文件解析；多个同名或仓库里没有 → 记「解析不了」计数，不当绿也不当红）；
#   #include <系统头> 只用于 R-02；.csproj 的 <Compile Include="相对路径">（带 $(…) / 通配的记「解析不了」计数）
# 测试排除：目录名 tests / test、以 -tests / _tests 结尾，或文件名 t_* / *_test.*（地图把业务目录里的测试归到父目录的层）
# 已实现：R-01 核心 → 平台实现；R-02 共用文件直接包含苹果系统头；R-04 图形 → 平台私有实现；R-05 平台壳 → 图形内部头（不在公开清单）
# 未实现（输出里逐条点名，不冒充已查）：R-03 R-06 R-07 R-08 R-11 R-12 R-13 R-16 R-17 R-18；R-09 暂缓（D9 前）；R-10 只提示（日摘）；R-14 / R-15 由 platform_scan --gate 承担
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layer_map  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXEMPT = 'tools/layer_exempt.tsv'
SRC_EXT = ('.c', '.h', '.m', '.mm', '.inc', '.cpp', '.cc', '.hpp')
INC = re.compile(r'^\s*#\s*(?:include|import)\s*([<"])([^>"]+)[>"]')
COMPILE = re.compile(r'<Compile\s+Include="([^"]+)"')
PUBLIC_GFX = {'nvn_backend.h', 's2a_track.h', 'gal_abi.h', 's2a_widen.h'}   # 方案 4.3.2 公开图形接口初始范围
APPLE_SYS = ('UIKit/', 'AppKit/', 'Foundation/', 'CoreFoundation/', 'Metal/', 'MetalKit/', 'MetalFX/', 'QuartzCore/', 'CoreGraphics/',
             'CoreVideo/', 'VideoToolbox/', 'AVFoundation/', 'AudioToolbox/', 'GameController/', 'IOSurface/', 'IOKit/', 'mach/', 'mach-o/', 'os/', 'libkern/')
CONTRACT_MODULES = {'契约', '体验规格', '构建'}   # 平台接口层里属于契约 / 共享规格 / 构建的行，不算「平台实现」
RULES_TODO = [('R-03', '未实现'), ('R-06', '未实现'), ('R-07', '未实现'), ('R-08', '未实现'), ('R-09', '暂缓（D9 前）'), ('R-10', '只提示（日摘）'),
              ('R-11', '未实现'), ('R-12', '未实现'), ('R-13', '未实现（核心 → 安卓 已由 R-01 覆盖）'), ('R-14', '由 platform_scan --gate 承担'),
              ('R-15', '由 platform_scan --gate 承担'), ('R-16', '未实现'), ('R-17', '未实现'), ('R-18', '未实现')]


def tracked(repo):
    out = subprocess.run(['git', '-C', repo, 'ls-files', '-z'], capture_output=True, check=True).stdout
    return [f for f in out.decode('utf-8', 'surrogateescape').split('\0') if f]


TEST_FILE = re.compile(r'(^|/)(tests?|[^/]*[-_]tests?)/|(^|/)t_[^/]*$|_test\.[^/]*$')


def is_test(f):   # 业务目录里的测试（地图把它们归到父目录的层）：方案 4.3.4「测试排除」，测试边不算越界
    return TEST_FILE.search(f) is not None


def plat_impl(r):
    return r is not None and (r[1] == '平台壳' or (r[1] == '平台接口' and r[2] not in CONTRACT_MODULES))


def shared_src(r):   # R-02 的「核心 / 共用前端」
    return r is not None and (r[1] == '核心' or (r[1] == '图形后端' and r[3] == '共用层'))


def edges(repo, rows):
    """→ (越界边 [(规则, 来源, 行号, 对方)], 解析不了的计数)"""
    files = tracked(repo); fs = set(files); by_base = {}
    for f in files: by_base.setdefault(os.path.basename(f), []).append(f)
    out, unres = [], 0
    for f in files:
        if '/third_party/' in f or f.startswith('compat/tree/'): continue   # 外来源码不按本仓分层判
        r = layer_map.lookup(rows, f)
        if r is None or r[1] in ('工具与测试', '文档与约定') or is_test(f): continue
        if f.endswith(SRC_EXT): kind = 'c'
        elif f.endswith('.csproj'): kind = 'cs'
        else: continue
        try: text = open(os.path.join(repo, f), encoding='utf-8', errors='replace').read().splitlines()
        except OSError: continue
        for n, line in enumerate(text, 1):
            targets = []
            if kind == 'c':
                m = INC.match(line)
                if not m: continue
                if m.group(1) == '<':
                    if shared_src(r) and m.group(2).startswith(APPLE_SYS): out.append(('R-02', f, n, '<' + m.group(2) + '>'))
                    continue
                targets = [m.group(2)]
            else:
                for m in COMPILE.finditer(line): targets += [x.strip() for x in m.group(1).split(';') if x.strip()]
            for inc in targets:
                inc = inc.replace('\\', '/')
                if kind == 'cs' and ('$(' in inc or '*' in inc): unres += 1; continue
                p = os.path.normpath(os.path.join(os.path.dirname(f), inc))
                if p not in fs:
                    c = [x for x in by_base.get(os.path.basename(inc), []) if x.endswith('/' + inc.lstrip('./')) or x == inc]
                    if len(c) != 1:
                        if c or kind == 'cs': unres += 1   # 仓库里有多个同名、或工程点名的文件不在仓库：解析不了
                        continue                            # 仓库里没有 = 系统 / 生成头，不是仓内分层边
                    p = c[0]
                t = layer_map.lookup(rows, p)
                if t is None or p == f: continue
                if r[1] == '核心' and plat_impl(t): out.append(('R-01', f, n, p))
                elif r[1] == '图形后端' and plat_impl(t): out.append(('R-04', f, n, p))
                elif r[1] == '平台壳' and t[1] == '图形后端' and p.endswith(('.h', '.inc')) and os.path.basename(p) not in PUBLIC_GFX:
                    out.append(('R-05', f, n, p))
    return out, unres


def load_exempt(path):
    """→ {(规则, 来源, 对方): 行号}；格式错抛 ValueError"""
    ex = {}
    if not os.path.exists(path): return ex
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        line = line.rstrip('\n')
        if not line or line.startswith('#'): continue
        p = line.split('\t')
        if len(p) != 4 or not all(p): raise ValueError(f'{EXEMPT}:{n} 要四列（规则 / 路径 / 对方 / 理由与清零条件）且都不空')
        k = (p[0], p[1], p[2])
        if k in ex: raise ValueError(f'{EXEMPT}:{n} 与第 {ex[k]} 行重复')
        ex[k] = n
    return ex


REASON = {'R-01': '存量：核心反向包含平台实现（方案 H4 / H11 / M1）；清零条件：经平台契约注入或归位后同笔删本行',
          'R-02': '存量：共用文件直接包含苹果系统头（方案 H3 / H14 / M6）；清零条件：收进平台实现或契约后同笔删本行',
          'R-04': '存量：图形反向依赖平台私有实现（方案 H15 / M1 / L1）；清零条件：改走公开平台接缝后同笔删本行',
          'R-05': '存量：平台壳包含图形内部头（方案 M3 / H1）；清零条件：改用公开图形接口后同笔删本行'}


def main(a):
    if not a or a[0] not in ('check', 'edges', 'write-exempt'):
        print('用法：tools/layer_edge.py check | edges | write-exempt [<仓库根>]', file=sys.stderr); return 2
    repo = os.path.abspath(a[1]) if len(a) > 1 else ROOT
    try: rows = layer_map.load(os.path.join(repo, layer_map.TABLE))
    except ValueError as e: print(f'【红】{e}', file=sys.stderr); return 1
    es, unres = edges(repo, rows)
    if a[0] == 'edges':
        for k, f, n, t in es: print(f'{k}\t{f}:{n}\t{t}')
        return 0
    ep = os.path.join(repo, EXEMPT)
    if a[0] == 'write-exempt':
        keys = sorted({(k, f, t) for k, f, n, t in es})
        with open(ep, 'w', encoding='utf-8', newline='\n') as w:
            w.write('# 分层边豁免表（架构分层方案 4.3.5；tools/layer_edge.py 对账）。四列，制表符分隔：规则\t路径\t对方\t理由与清零条件\n')
            w.write('# 只减不增：只登记 main 上实际存在的越界边；边清掉了必须同笔删行（留着即「豁免过时」报红）。新增越界不许靠加行放行，要加须写可检查的清零条件并经总指挥批\n')
            for k, f, t in keys: w.write(f'{k}\t{f}\t{t}\t{REASON[k]}\n')
        print(f'已写 {EXEMPT}：{len(keys)} 行'); return 0
    try: ex = load_exempt(ep)
    except ValueError as e: print(f'【红】{e}'); return 1
    seen, red = set(), 0
    for k, f, n, t in es:
        seen.add((k, f, t))
        if (k, f, t) not in ex:
            red += 1
            print(f'【红】{f}:{n} ' + {'R-01': f'核心反向包含平台实现 {t}', 'R-02': f'共用文件直接包含苹果头 {t}',
                                        'R-04': f'图形反向依赖平台私有文件 {t}', 'R-05': f'平台壳包含图形内部头 {t}'}[k] + f'（{k}；没有登记在 {EXEMPT}）')
    stale = [(k, ln) for k, ln in ex.items() if k not in seen]
    for (k, f, t), ln in sorted(stale, key=lambda x: x[1]):
        red += 1; print(f'【红】{EXEMPT}:{ln} 豁免过时：{k} {f} → {t} 这条边已不存在，同笔删掉这一行（只减不增）')
    print(f'分层边：越界边 {len(es)} 处（{len(seen)} 条不同边）；豁免 {len(ex)} 行；未登记 {red - len(stale)}、豁免过时 {len(stale)}；解析不了的引用 {unres} 处（工程里带 $(…) / 通配、或仓库内多个同名）')
    print('未查的规则：' + '；'.join(f'{r} {s}' for r, s in RULES_TODO))
    return 1 if red else 0


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8', newline='\n')
    sys.exit(main(sys.argv[1:]))

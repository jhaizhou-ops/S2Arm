#!/usr/bin/env python3
# OpenGL 款普查（WP7 / #265；判法与输出口径见 docs/研究/GL前端接口.md 第 1、7 节）：一款一份汇总
#   ① 判法两条：main 导入 eglCreateWindowSurface；main 里有字符串 glShaderSource。两条都中 = OpenGL 款（只导入 EGL 不算）
#   ② 各模块按名取的加载器（loader_census.py）：取了多少名字、代码实际读了哪些槽 = 实际调用的函数（GL / EGL 分开列）
#   ③ GLSL：RomFS（含追加内容）与 exefs/main 里以 #version 开头、NUL 结尾的字符串，按「版本 + es / 桌面」分组计数、去重数、在哪些文件；
#      压缩容器里的读不到（只数明文），读不到的容器在报告里按扩展名列出文件数，交普查者点名
# 用法：python3 graphics/nvn/tools/gl_census.py <产物根（exefs/ romfs/）> [--json]
import collections, hashlib, json, os, re, subprocess, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); import nso_syms
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk）
import romfs_list

VER = re.compile(rb'#version[ \t]+(\d+)(?:[ \t]+(es|core|compatibility))?')

def loader(path):
    out = subprocess.run([sys.executable, str(HERE / 'loader_census.py'), str(path)], capture_output=True, text=True).stdout
    m = re.match(r'(\d+) slots stored by a loader', out)
    return (int(m.group(1)) if m else 0), sorted(re.findall(r'^\s+\d+\s+(\S+)$', out, re.M))

def glsl_in(data, where, groups, keys):
    for m in re.finditer(rb'#version[ \t]', data):
        end = data.find(b'\0', m.start(), m.start() + (1 << 20)); end = len(data) if end < 0 else end
        src = data[m.start():end]; v = VER.match(src)
        if not v: continue
        g = f'{v.group(1).decode()} {"es" if v.group(2) == b"es" else "桌面"}'
        k = hashlib.sha256(src).hexdigest()[:16]
        if k in keys: continue
        keys.add(k); groups[g][0] += 1; groups[g][1].add(where)

def census(root):
    root = Path(root); ex = root / 'exefs'
    main = nso_syms.load(str(ex / 'main'))
    imp = {s for s, d, _ in nso_syms.dynsyms(main) if not d}
    r = {'程序根': str(root), '判法': {'导入 eglCreateWindowSurface': 'eglCreateWindowSurface' in imp, 'main 有 glShaderSource 字符串': b'glShaderSource\0' in main},
         '模块': {}, 'GLSL': {}, '没读的容器': {}}
    r['OpenGL 款'] = all(r['判法'].values())
    for f in sorted(ex.iterdir()):
        if f.name.endswith('.npdm') or f.name == 'rtld': continue
        syms = nso_syms.dynsyms(nso_syms.load(str(f)))
        n, called = loader(f)
        r['模块'][f.name] = {'导入 egl*': sorted(s for s, d, _ in syms if not d and s.startswith('egl')),
                            '按名取的槽': n, '实际调用 gl*': [c for c in called if c.startswith('gl')], '实际调用其它': [c for c in called if not c.startswith('gl')]}
    groups, keys = collections.defaultdict(lambda: [0, set()]), set()
    glsl_in(main, 'exefs/main', groups, keys)   # 模块只扫 main：驱动模块（哈迪斯 subsdk1）自带内部 GLSL，不是游戏的
    other = collections.Counter()
    for top in ('romfs', 'aoc'):
        for d, _, fs in romfs_list.walk(root / top):
            for fn in fs:
                p = Path(d) / fn
                try: data = p.read_bytes()
                except OSError: continue
                before = len(keys); glsl_in(data, str(p.relative_to(root)), groups, keys)
                if len(keys) == before and (data[:4] in (b'\x28\xb5\x2f\xfd', b'Yaz0') or data[:2] == b'\x78\x9c'): other[p.suffix or '(无扩展名)'] += 1
    r['GLSL'] = {g: {'去重支数': c, '文件数': len(w), '文件举例': sorted(w)[:5]} for g, (c, w) in sorted(groups.items())}
    r['GLSL 去重合计'] = len(keys)
    r['没读的容器'] = dict(other.most_common(10))   # 压缩过（zstd / Yaz0 / zlib）、明文里没找到 #version 的文件，按扩展名计数
    return r

def main():
    a = sys.argv[1:]; js = '--json' in a; a = [x for x in a if x != '--json']
    if len(a) != 1: sys.exit('用法：gl_census.py <产物根> [--json]')
    r = census(a[0])
    if js: print(json.dumps(r, ensure_ascii=False, indent=1)); return
    print(f'{"OpenGL 款" if r["OpenGL 款"] else "不是 OpenGL 款"}；判法 ' + '，'.join(f'{k} {"中" if v else "不中"}' for k, v in r['判法'].items()))
    for m, v in r['模块'].items():
        print(f'  {m}：导入 egl* {len(v["导入 egl*"])} 个；按名取 {v["按名取的槽"]} 个槽，实际调用 gl* {len(v["实际调用 gl*"])} 个、其它 {len(v["实际调用其它"])} 个')
        if v['实际调用 gl*']: print('    gl：' + ' '.join(v['实际调用 gl*']))
    print(f'  GLSL 去重 {r["GLSL 去重合计"]} 支：' + ('；'.join(f'{g} {v["去重支数"]} 支（{v["文件数"]} 个文件）' for g, v in r['GLSL'].items()) or '无'))
    if r['没读的容器']: print('  压缩过、明文里没有 #version 的文件（按扩展名）：' + '，'.join(f'{k} {v}' for k, v in r['没读的容器'].items()))

if __name__ == '__main__': main()

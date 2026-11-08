#!/usr/bin/env python3
"""R3 夹具生成器：造四种「拖慢编译」结构的 MSL，可复现同样大小、同样结构。

四种结构（R3 任务单口径）：
  deep_if    深嵌套 if 链（分支深度 DEEP_DEPTH，每层有实际运算）
  big_switch 超大 switch（单个 switch 的 case 数 SWITCH_CASES）
  huge_body  巨型函数体（单个函数几千条直线语句）
  inline     大量内联（always_inline 小函数被多个调用点反复内联）

只写文本，不调编译器。夹具不入库（生成物），缺省写到 build/metal_prof/。输出带固定分隔标记，tools/metal_compile_prof.py 靠标记切出各结构单独测；每一段都自带
#include / kernel 入口，切出来单编译也成立。生成结果按字节数对齐目标（精度见 --tolerance）。

  python3 tests/metal_prof/gen_fixtures.py --target 1MB          # 造 1 MiB 四结构夹具（缺省写到 build/metal_prof/）
  python3 tests/metal_prof/gen_fixtures.py --target 10MB          # 造 10 MiB 那份（约 11 MB 文本，别写进仓库）
  python3 tests/metal_prof/gen_fixtures.py --structure huge_body --target 256KB --out build/metal_prof/h.metal
"""

import argparse
import os

STRUCTURES = ('deep_if', 'big_switch', 'huge_body', 'inline')

# 每个结构的形态常量（改这些 = 换夹具形态；生成器把它们写进文件头，读的人不用猜）
DEEP_DEPTH = 24           # 嵌套层数
SWITCH_CASES = 192        # 单个 switch 的 case 数
BODY_STATEMENTS = 1200    # 巨型函数的直线语句数
INLINE_HELPERS = 16       # 一组 always_inline 小函数个数
INLINE_SITES = 12         # 每个小函数被调用的点数

PREAMBLE = '#include <metal_stdlib>\nusing namespace metal;\n'

HERE = os.path.dirname(os.path.abspath(__file__))          # tests/metal_prof/
ROOT = os.path.dirname(os.path.dirname(HERE))              # 仓库根：夹具缺省写到 <root>/build/metal_prof/


def size_of(text):
    return len(text.encode('utf-8'))


def human(n):
    return f'{n} B ({n / 2**20:.2f} MiB)' if n >= 2**10 else f'{n} B'


def parse_size(text):
    """'1MB' / '10MB' / '256KB' / '1048576' → 字节。MB = 2**20（与工具输出的 MiB 口径一致）。"""
    t = text.strip().upper()
    for unit, mul in (('MB', 2**20), ('MIB', 2**20), ('KB', 2**10), ('KIB', 2**10), ('B', 1)):
        if t.endswith(unit):
            return int(float(t[: -len(unit)]) * mul)
    return int(t)


# ---- 四个结构的单元生成 ----------------------------------------------------

def unit_deep_if(idx):
    """一层套一层的 if 链：最内层做真正的运算，每层带一个 else 分支。"""
    out = [f'static float ifchain_{idx}(float x, int k) {{', '  float a = x;']
    for depth in range(DEEP_DEPTH):
        pad = '  ' * (depth + 1)
        out.append(f'{pad}if (k > {depth}) {{')
        out.append(f'{pad}  a = a * 1.0001f + {depth + 1}.0f;')
    inner = '  ' * (DEEP_DEPTH + 1)
    out.append(f'{inner}a = a * 0.9997f + 7.0f;')
    for depth in reversed(range(DEEP_DEPTH)):
        pad = '  ' * (depth + 1)
        out.append(f'{pad}}} else {{')
        out.append(f'{pad}  a = a - {depth + 1}.5f;')
        out.append(f'{pad}}}')
    out.append('  return a;')
    out.append('}')
    return '\n'.join(out) + '\n'


def unit_big_switch(idx):
    """单个超大 switch：每个 case 有自己的常量与两条语句。"""
    out = [f'static float bigsw_{idx}(float x, int c) {{', '  float a = x;', '  switch (c) {']
    for case in range(SWITCH_CASES):
        out.append(f'    case {case}:')
        out.append(f'      a = a * 1.0001f + {case}.0f;')
        out.append(f'      a = a - {case % 7}.25f;')
        out.append('      break;')
    out.append('    default:')
    out.append('      a = a + 1.0f;')
    out.append('      break;')
    out.append('  }')
    out.append('  return a;')
    out.append('}')
    return '\n'.join(out) + '\n'


def unit_huge_body(idx):
    """巨型函数体：几千条无分支直线语句，前后各一条边界。

    语句里带 src[...] 的运行时读：全是常量的直线运算会被前端按 fast-math 常数折叠掉（实测 1 MB 只剩 3.1 KB
    AIR，编译 0.8 秒，量出来的不是「巨型函数体」）；读 buffer 才留得住代码。
    """
    out = [f'static float bigbody_{idx}(float x, device const float *src) {{', '  float a = x;']
    for step in range(BODY_STATEMENTS):
        out.append(f'  a = a * 1.0001f + src[{step % 59}];')
    out.append('  return a;')
    out.append('}')
    return '\n'.join(out) + '\n'


def unit_inline(idx):
    """一组 always_inline 小函数 + 若干调用点：每个小函数被 INLINE_SITES 个点各内联一次。"""
    out = []
    for helper in range(INLINE_HELPERS):
        out.append(f'[[clang::always_inline]] static float inl_{idx}_{helper}(float x) {{')
        out.append(f'  float a = x * {helper + 1}.0003f;')
        out.append(f'  a = a + sin(a) * {helper % 5 + 1}.5f;')
        out.append('  a = a * 0.9999f;')
        out.append('  return a;')
        out.append('}')
    for site in range(INLINE_SITES):
        out.append(f'static float inluse_{idx}_{site}(float x) {{')
        out.append('  float a = x;')
        for helper in range(INLINE_HELPERS):
            out.append(f'  a = inl_{idx}_{helper}(a) + {site}.5f;')
        out.append('  return a;')
        out.append('}')
    return '\n'.join(out) + '\n'


UNITS = {
    'deep_if': unit_deep_if,
    'big_switch': unit_big_switch,
    'huge_body': unit_huge_body,
    'inline': unit_inline,
}


def section(struct, target_bytes):
    """造一段（自带 #include 与 kernel 入口），直到达到目标字节数。"""
    # 标记放在 #include 之前：切出来的段自带 preamble，单独编译也成立
    body = [f'//#region section {struct}\n', PREAMBLE]
    units = []
    idx = 0
    used = size_of(PREAMBLE) + 64
    while used < target_bytes or not units:
        text = UNITS[struct](idx)
        units.append((idx, text))
        used += size_of(text)
        idx += 1
    for _, text in units:
        body.append('\n' + text)
    # 入口 kernel：把本段每个函数都调一遍，保证不被前端当死代码丢掉（死代码的编译耗时没有意义）
    call = {'deep_if': 'ifchain', 'big_switch': 'bigsw', 'huge_body': 'bigbody', 'inline': 'inluse'}[struct]
    src_arg = 'device const float *src [[buffer(1)]],\n    ' if struct == 'huge_body' else ''
    body.append(f'\nkernel void k_{struct}(device float *out [[buffer(0)]],\n'
                f'    {src_arg}uint gid [[thread_position_in_grid]]) {{\n'
                f'  float a = float(gid) * 0.001f;\n')
    if struct == 'deep_if':
        for idx_, _ in units:
            body.append(f'  a += ifchain_{idx_}(a, int(gid % {DEEP_DEPTH}));\n')
    elif struct == 'big_switch':
        for idx_, _ in units:
            body.append(f'  a += bigsw_{idx_}(a, int(gid % {SWITCH_CASES}));\n')
    elif struct == 'huge_body':
        for idx_, _ in units:
            body.append(f'  a += bigbody_{idx_}(a, src);\n')
    else:
        for idx_, _ in units:
            for site in range(INLINE_SITES):
                body.append(f'  a += inluse_{idx_}_{site}(a);\n')
    body.append('  out[gid] = a;\n}\n')
    body.append(f'//#endregion section {struct}\n')
    return ''.join(body), len(units)


def build(structs, target_bytes):
    """整份夹具：文件头 + 各段。返回 (文本, 各段统计)。"""
    per = target_bytes // len(structs)
    header = [
        '// 合成 MSL 夹具（R3 Metal 编译耗时剖析）：四种结构各一段，段内自带 #include 与 kernel 入口。\n',
        '// 生成器 tests/metal_prof/gen_fixtures.py —— 同样的参数重跑得到逐字节相同的文件（无随机）。\n',
        f'// 参数：depth={DEEP_DEPTH} cases={SWITCH_CASES} statements={BODY_STATEMENTS} '
        f'helpers={INLINE_HELPERS} sites={INLINE_SITES}\n',
        '// 段边界 //#region section <名> / //#endregion section <名>，分开测时按标记切。\n',
    ]
    text = ''.join(header)
    stats = []
    for struct in structs:
        part, n = section(struct, per)
        text += '\n' + part
        stats.append({'structure': struct, 'bytes': size_of(part), 'units': n})
    return text, stats


def main():
    ap = argparse.ArgumentParser(description='造 R3 Metal 编译耗时剖析夹具（只写文本）')
    ap.add_argument('--target', default='1MB', help='总字节数，可写 1MB / 10MB / 256KB（MB=2**20），缺省 1MB')
    ap.add_argument('--structure', action='append', choices=STRUCTURES,
                    help='只造某一种结构（可重复）；缺省四种各一段')
    ap.add_argument('--out', default='', help='输出文件；缺省 fixture_<target>.metal 放在本脚本同目录')
    ap.add_argument('-q', '--quiet', action='store_true')
    args = ap.parse_args()

    structs = tuple(args.structure) if args.structure else STRUCTURES
    target = parse_size(args.target)
    text, stats = build(structs, target)
    # 缺省写到仓库的 build/metal_prof/（gitignore 里）：夹具是生成物，不进仓库（维护方 10-27 要求）
    out = args.out or os.path.join(ROOT, 'build', 'metal_prof', f'fixture_{args.target.lower()}.metal')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write(text)
    total = size_of(text)
    if not args.quiet:
        print(f'写出 {out}：{human(total)}，目标 {human(target)}（偏差 {total - target:+d} B）')
        for row in stats:
            print(f"  {row['structure']:<11} {row['bytes']:>9} B  {row['units']:>4} 组")


if __name__ == '__main__':
    main()

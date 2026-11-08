#!/usr/bin/env python3
"""FPSLocker 帧率补丁（YAML）→ 补丁包 [fps] 段（runtime/src/fps.c 的 w 行）。

用法：tools/patch_fps_yaml.py <补丁.yaml> [--target 60]
  只转 ALL_FPS 里的 write / evaluate_write：地址 [MAIN, 偏移, 链…] → `w main <偏移> i32|f32 <开值> [*链…] [off <关值>]`；
  值是数组时按值类型宽度连续写（第 i 个写在最后一级偏移 + 4i）；表达式里的 FPS_TARGET / FPS_LOCK_TARGET 按 --target（缺省 60）算成开值，
  按 30 算成关值（两者不同才写 off）。遇到 block（分段标记）就停，之后的条目只记报告；MASTER_WRITE（多为改代码 asm_a / bytes）、
  compare / variable 等类型、double / 64 位值都不转，逐条记进报告（stderr）。
补丁文件是外部数据：只按下面这一小块 YAML 写法读，表达式用白名单算术求值，不执行任何内容。
"""
import ast, operator, re, sys

OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv, ast.USub: operator.neg, ast.UAdd: operator.pos}


def calc(expr, target):
    """数字、+ - * /、括号、FPS_TARGET / FPS_LOCK_TARGET；别的一律拒"""
    def ev(n):
        if isinstance(n, ast.Expression): return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)): return n.value
        if isinstance(n, ast.Name) and n.id in ('FPS_TARGET', 'FPS_LOCK_TARGET'): return target
        if isinstance(n, ast.BinOp) and type(n.op) in OPS: return OPS[type(n.op)](ev(n.left), ev(n.right))
        if isinstance(n, ast.UnaryOp) and type(n.op) in OPS: return OPS[type(n.op)](ev(n.operand))
        raise ValueError('表达式不认：%s' % expr)
    return ev(ast.parse(str(expr), mode='eval'))


def scalar(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'': return v[1:-1]
    try: return int(v, 0)
    except ValueError: pass
    try: return float(v)
    except ValueError: return v


def value_of(v):
    v = v.strip()
    if v.startswith('['): return [scalar(x) for x in re.findall(r'"[^"]*"|\'[^\']*\'|[^,\[\]]+', v[1:-1]) if x.strip()]
    return scalar(v)


def sections(text):
    """顶层键 → 条目列表（每条是 dict）；只认「顶层键:」+「  -」起条目 +「    键: 值」"""
    out, cur, item = {}, None, None
    for raw in text.splitlines():
        line = raw.split('#', 1)[0].rstrip() if not re.search(r'"[^"]*#', raw) else raw.rstrip()
        if not line.strip(): continue
        if not line.startswith(' ') and line.endswith(':'): cur = line[:-1].strip(); out[cur] = []; item = None; continue
        if not line.startswith(' ') and ':' in line: out[line.split(':', 1)[0].strip()] = value_of(line.split(':', 1)[1]); cur = None; continue
        if cur is None: continue
        s = line.strip()
        if s == '-' or s.startswith('- '):
            item = {}; out[cur].append(item); s = s[1:].strip()
            if not s: continue
        if item is not None and ':' in s: k, v = s.split(':', 1); item[k.strip()] = value_of(v)
    return out


def convert(text, target=60):
    sec = sections(text); rows, report = [], []
    for k in sec:
        if k not in ('ALL_FPS', 'unsafeCheck') and isinstance(sec[k], list): report.append('段 %s 共 %d 条：本版不转（多为改代码 / 变量声明，要重新出包）' % (k, len(sec[k])))
    stopped = False
    for i, e in enumerate(sec.get('ALL_FPS', [])):
        t = e.get('type')
        if stopped: report.append('ALL_FPS 第 %d 条 %s：在 block 之后，不转' % (i + 1, t)); continue
        if t == 'block': stopped = True; report.append('ALL_FPS 第 %d 条 block %s：分段标记，之后的条目不转' % (i + 1, e.get('what'))); continue
        if t not in ('write', 'evaluate_write'): report.append('ALL_FPS 第 %d 条 %s：类型不转' % (i + 1, t)); continue
        addr, vt = e.get('address'), e.get('value_type')
        if not isinstance(addr, list) or len(addr) < 2 or str(addr[0]).upper() != 'MAIN' or not all(isinstance(a, int) for a in addr[1:]):
            report.append('ALL_FPS 第 %d 条：地址 %s 不是 [MAIN, 偏移, 链…]，不转' % (i + 1, addr)); continue
        ty = {'int32': 'i32', 'uint32': 'i32', 'int': 'i32', 'uint': 'i32', 'float': 'f32'}.get(str(vt))
        if not ty or len(addr) > 8: report.append('ALL_FPS 第 %d 条：值类型 %s / 链 %d 级不支持，不转' % (i + 1, vt, len(addr) - 2)); continue
        vals = e.get('value'); vals = vals if isinstance(vals, list) else [vals]
        for j, v in enumerate(vals):
            try:
                on = calc(v, target) if t == 'evaluate_write' else v; off = calc(v, 30) if t == 'evaluate_write' else v
                if not isinstance(on, (int, float)): raise ValueError('值不是数：%s' % v)
            except (ValueError, SyntaxError, ZeroDivisionError) as x: report.append('ALL_FPS 第 %d 条第 %d 个值：%s，不转' % (i + 1, j + 1, x)); continue
            fmt = (lambda x: repr(float(x))) if ty == 'f32' else (lambda x: str(int(x)))
            chain = list(addr[2:])
            if chain: chain[-1] += 4 * j; o = addr[1]
            else: o = addr[1] + 4 * j
            row = 'w main %#x %s %s%s' % (o, ty, fmt(on), ' ' + ''.join('*%#x' % c for c in chain) if chain else '')
            if off != on: row += ' off ' + fmt(off)
            rows.append(row)
    return rows, report


def main(argv):
    if not argv: print(__doc__); return 2
    target = int(argv[argv.index('--target') + 1]) if '--target' in argv else 60
    rows, report = convert(open(argv[0], encoding='utf-8', errors='replace').read(), target)
    sys.stdout.write('[fps]\n' + ''.join(r + '\n' for r in rows) if rows else '')
    for r in report: sys.stderr.write(r + '\n')
    sys.stderr.write('转出 w 行 %d 条，不转 %d 项\n' % (len(rows), len(report)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

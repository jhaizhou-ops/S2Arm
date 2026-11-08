#!/usr/bin/env python3
"""社区同构建号帧率条目转帧率表（10-30 grokbot 按引擎 60 帧 S 级④）：python3 tools/fps_warehouse.py <产物根> <main 构建号>
  仓库 runtime/fps/ 没有本构建号的表时由 pack/stage_rewrite.sh 调（先于 tools/fps_generic.py）。补丁索引目录 S2A_CPATCH_DIRS（os.pathsep 分隔：Mac / Linux 冒号、Windows 分号，
  同 pack/cpatch.py：各目录下 INDEX.tsv）里找「FPSLocker yaml」类型、build_id = 构建号前 16 位的条目，只收最简单的形状：
    顶层只有 unsafeCheck / ALL_FPS；ALL_FPS 每项要么「block timing」（社区插件自己的限帧，我们没有，略过），要么 write / evaluate_write、
    地址恰为 [MAIN, 偏移, 0]（主程序 + 偏移处是指针，写指针 + 0 = 虚幻 4 控制台变量的值，与帧率表 w 行「*0」同义）、上一行注释点名已知的
    虚幻 4 控制台变量（t.MaxFPS / r.VSync / r.DynamicRes.FrameTimeBudget）、值类型 float / int32 / uint32、值是常数或社区全局量的算式
    （FPS_TARGET = 60、FPS_LOCK_TARGET = 62（目标等于刷新率时社区加 2 防抖）、FRAMETIME_TARGET = 1000/60、VSYNC_TARGET = 1、TruncDec）
    且列表里各值相同。有一项不合（指针链更深、比较写、汇编、MASTER_WRITE、HEAP / ALIAS 区）整份不收——不猜。
  收了 → <产物根>/fps.tsv = present display（第一层）+ 每项一行 w（第二层）。只写位置事实与我方的值，不含补丁原文。
  社区补丁学语义、作能力补充（10-27 jhz）：构建号不同不套；逻辑速度判红的走强信号关。
退出码：0 写了表 / 1 不适用（没有同构建号条目、形状不收、已收社区 pchtxt 帧率补丁）/ 2 输入读不出"""
import ast, math, os, re, sys

CVARS = ('t.MaxFPS', 'r.VSync', 'r.DynamicRes.FrameTimeBudget')
GLOBALS = {'FPS_TARGET': 60.0, 'FPS_LOCK_TARGET': 62.0, 'FRAMETIME_TARGET': 1000.0 / 60, 'VSYNC_TARGET': 1.0}
TYPES = {'float': 'f32', 'int32': 'i32', 'uint32': 'i32'}


def evaluate(expr):
    """社区算式 → 数；不认的名字 / 运算 → ValueError"""
    def ev(n):
        if isinstance(n, ast.Expression): return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)): return float(n.value)
        if isinstance(n, ast.Name) and n.id in GLOBALS: return GLOBALS[n.id]
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.USub): return -ev(n.operand)
        if isinstance(n, ast.BinOp) and isinstance(n.op, (ast.Add, ast.Sub, ast.Mult, ast.Div)):
            a, b = ev(n.left), ev(n.right)
            return {ast.Add: a + b, ast.Sub: a - b, ast.Mult: a * b}.get(type(n.op)) if not isinstance(n.op, ast.Div) else a / b
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'TruncDec' and len(n.args) == 2:
            v, d = ev(n.args[0]), int(ev(n.args[1])); return math.trunc(v * 10 ** d) / 10 ** d
        raise ValueError(f'不认的算式：{ast.dump(n)[:60]}')
    return ev(ast.parse(str(expr).strip().strip('"\''), mode='eval'))


def parse(text):
    """FPSLocker yaml 文本 → [(注释, {键: 值文本})]（ALL_FPS 各项）；顶层有 unsafeCheck / ALL_FPS 以外的键 → ValueError"""
    items, cur, note, sect = [], None, '', None
    for raw in text.splitlines():
        line = raw.split(' #')[0].rstrip() if not raw.lstrip().startswith('#') else raw.rstrip()
        s = line.strip()
        if not s: continue
        if not raw.startswith((' ', '\t', '-')) and not s.startswith('#'):
            m = re.match(r'([A-Za-z_][A-Za-z0-9_]*)\s*:', s)
            if not m: raise ValueError(f'认不出的顶层行：{s[:40]}')
            sect = m.group(1)
            if sect not in ('unsafeCheck', 'ALL_FPS'): raise ValueError(f'有 {sect} 段')
            continue
        if sect != 'ALL_FPS': continue
        if s.startswith('#'): note = s.lstrip('#').strip(); continue
        if s == '-' or s.startswith('- '):
            cur = {}; items.append((note, cur)); note = ''
            s = s[1:].strip()
            if not s: continue
        if cur is None: raise ValueError('ALL_FPS 里有不在列表项下的行')
        m = re.match(r'([A-Za-z_]+)\s*:\s*(.*)$', s)
        if not m: raise ValueError(f'认不出的项行：{s[:40]}')
        cur[m.group(1)] = m.group(2).strip()
    return items


def rows_of(text):
    """→ (w 行列表, '') 或 (None, 不收的原因)"""
    try: items = parse(text)
    except ValueError as e: return None, str(e)
    out = []
    for note, it in items:
        ty = it.get('type', '')
        if ty == 'block' and it.get('what') == 'timing' and set(it) == {'type', 'what'}: continue
        if ty not in ('write', 'evaluate_write'): return None, f'有 {ty or "无类型"} 项'
        if set(it) != {'type', 'address', 'value_type', 'value'}: return None, f'项带了 {sorted(set(it) - {"type", "address", "value_type", "value"})}'
        m = re.fullmatch(r'\[\s*MAIN\s*,\s*(0x[0-9A-Fa-f]+)\s*,\s*0(?:x0+)?\s*\]', it['address'])
        if not m: return None, f'地址不是 [MAIN, 偏移, 0]：{it["address"][:40]}'
        cv = [c for c in CVARS if re.search(r'(?<![\w.])' + re.escape(c) + r'(?![\w.])', note)]
        if len(cv) != 1: return None, f'注释没点名唯一的已知控制台变量：{note[:40] or "无注释"}'
        vt = TYPES.get(it['value_type'].strip('"\''))
        if not vt: return None, f'值类型 {it["value_type"]} 不收'
        v = it['value']
        vals = [x for x in re.split(r',\s*(?![^()]*\))', v[1:-1])] if v.startswith('[') and v.endswith(']') else [v]
        try: nums = [evaluate(x) for x in vals if x.strip()]
        except (ValueError, SyntaxError, ZeroDivisionError) as e: return None, f'值算不出：{e}'
        if not nums or any(abs(x - nums[0]) > 1e-9 for x in nums): return None, f'值列表不一致：{v[:40]}'
        val = f'{nums[0]:g}' if vt == 'f32' else str(int(nums[0]))
        if vt == 'i32' and nums[0] != int(nums[0]): return None, f'整数值带小数：{v[:40]}'
        out.append(f'w main {int(m.group(1), 16):#x} {vt} {val} *0   # {cv[0]}（社区同构建号条目指出的位置）')
    if not out: return None, '没有写值项'
    return out, ''


def find_yaml(dirs, bid):
    for d in dirs:
        idx = os.path.join(d, 'INDEX.tsv')
        if not os.path.exists(idx): continue
        with open(idx, encoding='utf-8', errors='replace') as f:
            head = f.readline().rstrip('\n').split('\t')
            for l in f:
                r = dict(zip(head, l.rstrip('\n').split('\t')))
                if r.get('type') == 'FPSLocker yaml' and (r.get('build_id') or '').upper() == bid[:16].upper():
                    return os.path.join(d, r['path'])
    return None


def main(a):
    if len(a) != 2: print(__doc__.strip()); return 2
    root, bid = a
    cp = os.path.join(root, 'cpatch.tsv')   # 已收了社区 pchtxt 帧率补丁（编号 fps:）：不再叠一套（同 fps_generic）
    if os.path.exists(cp) and any(l.startswith('fps:') for l in open(cp, encoding='utf-8', errors='replace')):
        print('社区帧率条目：已有社区帧率补丁进包，不写'); return 1
    dirs = [d for d in os.environ.get('S2A_CPATCH_DIRS', '').split(os.pathsep) if d]   # os.pathsep：Windows 是 ;
    y = find_yaml(dirs, bid)
    if not y: print(f'社区帧率条目：补丁索引里没有构建号 {bid[:16]} 的条目，不写'); return 1
    try: text = open(y, encoding='utf-8').read()
    except OSError as e: print(f'社区帧率条目：读不出 {y}（{e}）'); return 2
    rows, why = rows_of(text)
    if rows is None: print(f'社区帧率条目：{os.path.basename(y)} 形状不收（{why}），不写'); return 1
    with open(os.path.join(root, 'fps.tsv'), 'w', encoding='utf-8') as f:
        f.write(f'build {bid[:16].lower()}\npresent display\n' + '\n'.join(rows) + '\n'
                f'# 社区同构建号条目转换（tools/fps_warehouse.py：{os.path.basename(os.path.dirname(y))}/{os.path.basename(y)}，只取位置事实）；逻辑速度判红走强信号关\n')
    print(f'社区帧率条目：{os.path.basename(y)} → fps.tsv（present display + {len(rows)} 行 w）'); return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

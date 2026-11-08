#!/usr/bin/env python3
"""R3 只读：Metal 编译耗时剖析（xcrun -sdk iphoneos metal -c 计时 + 二分定位）。

三个动作：
  measure  <文件…>        逐个编译计时，出 TSV/CSV（文件、字节数、函数数、编译秒数）
  sections <文件>         按夹具的 //#region section <名> 标记切段，逐段单独编译 → 每种结构的秒数 / 秒每 MiB
  bisect   <文件>         二分定位：先删一半函数，收敛到最热的一个函数；再在该函数体内二分删语句块，
                          报出「这个函数的哪一段贡献了多少秒」。每轮都写进日志（可复现）。

只读：输入文件只读不写；变体写在临时目录，编译产物（.air）每轮一个全新临时目录，测完删掉。
计时用 time.monotonic()，同一变体重复 --reps 次取中位；第一次编译（--warmup，缺省 1 次）丢弃不算——
本机实测首个 metal 调用含 1～3 秒的工具链服务冷启动（319 KB 文件：首编 2.94 秒、第二编 0.32 秒），
不丢弃会把冷启动算进第一个文件。

缓存实测（Xcode 27.1 / Metal 32023.921，1 MB 夹具）：同源重复编译 2.09 / 1.97 / 1.66 秒，改内部一处常量后
1.9 秒上下，换输出路径不改变量级 —— 这份工具链没有按源码摘要命中的编译缓存，热身后重复测量即可；
输出路径仍然每轮新建，免得产物写一半被下次读到。

  python3 tests/metal_prof/gen_fixtures.py --target 1MB      # 夹具是生成物，不进仓库：默认写 build/metal_prof/
  python3 tools/metal_compile_prof.py measure  build/metal_prof/fixture_1mb.metal --reps 3
  python3 tools/metal_compile_prof.py sections build/metal_prof/fixture_1mb.metal --reps 3
  python3 tools/metal_compile_prof.py bisect   build/metal_prof/fixture_1mb.metal --log build/metal_prof/bisect.log
"""

import argparse
import csv
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field

MIB = 2 ** 20


class CompileError(RuntimeError):
    """变体编译不过：二分要能识别并退到更细的粒度，而不是当成 0 秒。"""

    def __init__(self, message, stderr=''):
        super().__init__(message)
        self.stderr = stderr


# ---------- 编译与计时 ----------

def load1():
    """当前 1 分钟负载。读数要带它：同一台机器上有别的作业时，编译耗时能差几倍（实测同文件 1.87 / 11.47 秒）。"""
    try:
        return f'{os.getloadavg()[0]:.1f}'
    except OSError:
        return ''


class Compiler:
    def __init__(self, xcrun='xcrun', sdk='iphoneos', extra=(), timeout=900, calibrate=''):
        self.xcrun = xcrun
        self.sdk = sdk
        self.extra = list(extra)
        self.timeout = timeout
        self.calibrate = calibrate
        self.calls = 0

    def calibration(self):
        """每个输入前先编一份固定参照文件，记成 calib_s：同一批里若 calib_s 比平时大，
        说明这批读数被别的作业拖了，跨批比较要换算。"""
        if not self.calibrate:
            return ''
        try:
            seconds, _ = self.compile(self.calibrate)
        except CompileError:
            return ''
        return f'{seconds:.2f}'

    def compile(self, source):
        """编译一份 .metal，返回 (秒, AIR 字节数)。产物写在一次性临时目录里，结束即删。"""
        work = tempfile.mkdtemp(prefix='metal_prof_')
        try:
            air = os.path.join(work, 'out.air')
            cmd = [self.xcrun, '-sdk', self.sdk, 'metal', '-c', str(source), '-o', air] + self.extra
            t0 = time.monotonic()
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=self.timeout)
            except subprocess.TimeoutExpired:
                raise CompileError(f'编译超 {self.timeout} 秒：{source}')
            elapsed = time.monotonic() - t0
            self.calls += 1
            if proc.returncode != 0:
                raise CompileError(f'编译失败（退出 {proc.returncode}）：{source}', proc.stderr)
            size = os.path.getsize(air) if os.path.exists(air) else 0
            return elapsed, size
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def compile_text(self, text, tag=''):
        """把文本写成一次性源文件再编。每次内容都不同（末尾加一行唯一注释）：
        实测同一份 2.65 MB 源连编，会命中 Metal 自己的编译缓存（11.0 / 11.1 秒 → 1.9 秒），
        换 -o 路径照样命中（缓存键不含输出路径）——不换源码就量不到冷编译。"""
        work = tempfile.mkdtemp(prefix='metal_prof_src_')
        try:
            path = os.path.join(work, 'in.metal')
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(text + '\n// metal_prof measurement %d %s\n' % (time.monotonic_ns(), tag))
            return self.compile(path)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def time_median(self, source, reps, warmup):
        """warmup 次丢弃 + reps 次取中位。返回 (中位秒, 最小秒, 最大秒, AIR 字节数)。"""
        text = open_text(source)
        for i in range(warmup):
            self.compile_text(text, f'warmup{i}')
        samples, sizes = [], []
        for i in range(reps):
            seconds, size = self.compile_text(text, f'rep{i}')
            samples.append(seconds)
            sizes.append(size)
        return statistics.median(samples), min(samples), max(samples), sizes[-1]


# ---------- MSL 顶层切分（只认结构，不做语义） ----------

@dataclass
class Unit:
    kind: str          # pp 预处理 / comment 注释 / func 函数 / type struct·enum·namespace / gvar 全局
    start: int
    end: int           # 半开区间 [start, end)
    name: str = ''
    returns_void: bool = False

    @property
    def length(self):
        return self.end - self.start


def _skip_comment(text, i):
    if text.startswith('//', i):
        j = text.find('\n', i)
        return len(text) if j < 0 else j
    j = text.find('*/', i + 2)
    return len(text) if j < 0 else j + 2


def _skip_string(text, i):
    quote = text[i]
    j = i + 1
    while j < len(text):
        if text[j] == '\\':
            j += 2
            continue
        if text[j] == quote:
            return j + 1
        j += 1
    return len(text)


def _match_brace(text, i):
    """text[i] 是左花括号，返回配对右花括号的下标（含），跳过注释与字符串。"""
    depth = 0
    while i < len(text):
        c = text[i]
        if c == '/' and i + 1 < len(text) and text[i + 1] in '/*':
            i = _skip_comment(text, i)
            continue
        if c in '"\'':
            i = _skip_string(text, i)
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise CompileError('括号不配对：这份 MSL 切不出顶层声明')


def _name_before(text, start, brace):
    header = text[start:brace]
    found = re.findall(r'([A-Za-z_]\w*)\s*\(', header)
    return found[0] if found else ''


def scan_units(text):
    """把 MSL 切成顶层单元。函数体由 _match_brace 定界，删函数体靠它。"""
    units, i, n = [], 0, len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        start = i
        if text[i] == '#':
            while i < n and text[i] != '\n':
                i += 2 if (text[i] == '\\' and i + 1 < n and text[i + 1] == '\n') else 1
            units.append(Unit('pp', start, i))
            continue
        if text.startswith('//', i) or text.startswith('/*', i):
            i = _skip_comment(text, i)
            units.append(Unit('comment', start, i))
            continue
        j, paren = i, 0
        while j < n:
            c = text[j]
            if c == '/' and j + 1 < n and text[j + 1] in '/*':
                j = _skip_comment(text, j)
                continue
            if c in '"\'':
                j = _skip_string(text, j)
                continue
            if c in '([':
                paren += 1
            elif c in ')]':
                paren -= 1
            elif paren <= 0 and c in '{;':
                break
            j += 1
        if j >= n:
            units.append(Unit('gvar', start, n))
            break
        if text[j] == ';':
            units.append(Unit('gvar', start, j + 1))
            i = j + 1
            continue
        close = _match_brace(text, j)
        end = close + 1
        while end < n and text[end] in ' \t\r\n':
            end += 1
        if end < n and text[end] == ';':
            end += 1
        header = text[start:j]
        if re.search(r'\b(struct|class|union|enum|namespace)\b', header):
            kind = 'type'
        elif '(' in header:
            kind = 'func'
        else:
            kind = 'gvar'
        name = _name_before(text, start, j) if kind == 'func' else ''
        returns_void = bool(name) and bool(re.search(r'\bvoid\s+' + re.escape(name) + r'\s*\(', header))
        units.append(Unit(kind, start, end, name, returns_void))
        i = end
    return units


def apply_edits(text, edits):
    """edits = [(start, end, replacement)]，按起点降序套用，前面的偏移不受影响。"""
    for start, end, replacement in sorted(edits, key=lambda e: e[0], reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def blanked_text(unit, text):
    """把这个函数单元换成最小实现（签名不动），量的是它函数体的编译代价。"""
    head = text[unit.start:unit.end]
    brace = head.index('{')
    header = head[:brace]
    tail = head[head.rindex('}') + 1:]
    body = '{}' if unit.returns_void else '{ return {}; }'
    return header + body + tail


def blank_edit(unit, text):
    return (unit.start, unit.end, blanked_text(unit, text))


# ---------- 函数体内部的语句块切分 ----------

def scan_statements(body):
    """把函数体（不含最外层花括号）按顶层语句切块，返回 [(start, end)]（相对 body 起点）。
    顶层 = 括号深度 0；if-else、switch、for、while 的整块各算一块，不往里拆。
    删掉这些块不会破坏后续语句的作用域（块内声明的变量不外泄）——所以能整块删。"""
    chunks, i, n = [], 0, len(body)
    while i < n:
        while i < n and body[i].isspace():
            i += 1
        if i >= n:
            break
        start = i
        paren = 0
        while i < n:
            c = body[i]
            if c == '/' and i + 1 < n and body[i + 1] in '/*':
                i = _skip_comment(body, i)
                continue
            if c in '"\'':
                i = _skip_string(body, i)
                continue
            if c in '([':
                paren += 1
            elif c in ')]':
                paren -= 1
            elif paren <= 0 and c == '{':
                i = _match_brace(body, i) + 1
                while i < n:            # 块后面的 else / while(...) / ; 跟着走
                    m = re.match(r'\s*else\b[^{;]*\{', body[i:])
                    if m:
                        i = _match_brace(body, i + m.end() - 1) + 1
                        continue
                    m = re.match(r'\s*while\s*\(', body[i:])
                    if m:
                        k, depth = i + m.end(), 1
                        while k < n and depth:
                            depth += 1 if body[k] == '(' else (-1 if body[k] == ')' else 0)
                            k += 1
                        while k < n and body[k] in ' \t\r\n':
                            k += 1
                        if k < n and body[k] == ';':
                            i = k + 1
                        continue
                    break
                break
            elif paren <= 0 and c == ';':
                i += 1
                break
            i += 1
        chunks.append((start, i))
    return chunks


DECL = re.compile(r'\b(?:const\s+)?(?:float[234]?|half[234]?|int[234]?|uint[234]?|short[234]?|ushort[234]?|'
                  r'char[234]?|uchar[234]?|bool[234]?|long[234]?|ulong[234]?|size_t|ptrdiff_t)\s+'
                  r'([A-Za-z_]\w*)\s*(?:=|\[|;)')


def deletable(chunk_text, rest_text):
    """这一块能不能整块删：块里声明的变量后面还要用（删了编译不过）、块里有 return（删了就漏返回）
    → 不能删。其余（纯赋值、if/for/while 整块）都能删。"""
    if re.search(r'\breturn\b', chunk_text):
        return False
    for name in DECL.findall(chunk_text):
        if re.search(r'\b' + re.escape(name) + r'\b', rest_text):
            return False
    return True


# ---------- 二分 ----------

@dataclass
class BisectLog:
    lines: list = field(default_factory=list)
    path: str = ''

    def add(self, text):
        self.lines.append(text)
        print(text, flush=True)

    def save(self):
        if self.path:
            os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
            with open(self.path, 'w', encoding='utf-8') as fh:
                fh.write('\n'.join(self.lines) + '\n')


class Bisector:
    def __init__(self, compiler, text, reps, warmup, log, min_effect):
        self.compiler = compiler
        self.text = text
        self.reps = reps
        self.warmup = warmup
        self.log = log
        self.min_effect = min_effect
        self.tmpdir = tempfile.mkdtemp(prefix='metal_prof_bisect_')
        self.variant_no = 0

    def close(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _time(self, text, label=None):
        self.variant_no += 1
        path = os.path.join(self.tmpdir, f'v{self.variant_no:04d}.metal')
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(text)
        try:
            median, low, high, _ = self.compiler.time_median(path, self.reps, self.warmup)

        except CompileError as exc:
            if label is not None:
                self.log.add(f'  变体 {label} 编译不过 → 跳过这条分支（{str(exc).splitlines()[0]}）')
            return None
        finally:
            os.unlink(path)
        if label is not None:
            self.log.add(f'  变体 {label}：{median:.2f} 秒（{low:.2f}–{high:.2f}）')
        return median

    def bisect_units(self, units, apply_fn, label_of, title, base_text=None):
        """在一组「可删单元」上二分：每轮各删一半测一次，删掉后更快的那一半更重，继续往它里面切。
        base_text 缺省用原文件；语句块级二分时传「其余函数体已删」的底子，基线才对得上。
        返回 (最热单元, 它的贡献秒数, 基线秒, 轮数)。"""
        base = self._time(self.text if base_text is None else base_text)
        if base is None:
            raise CompileError('原文件编译不过，先修好再二分')
        self.log.add(f'{title}：基线 {base:.2f} 秒')
        remaining = list(units)
        blanked = []
        rounds = 0
        while len(remaining) > 1:
            rounds += 1
            half = len(remaining) // 2
            a, b = remaining[:half], remaining[half:]
            ta = self._time(apply_fn(blanked + a), f'删 {label_of(a[0])}…{label_of(a[-1])}（{len(a)} 个）')
            tb = self._time(apply_fn(blanked + b), f'删 {label_of(b[0])}…{label_of(b[-1])}（{len(b)} 个）')
            if ta is None and tb is None:
                self.log.add('  两半都编译不过，二分到此为止（见上面的报错）')
                return None, 0.0, base, rounds
            if tb is None or (ta is not None and ta <= tb):
                heavy, light, t_heavy = a, b, ta
            else:
                heavy, light, t_heavy = b, a, tb
            blanked.extend(light)
            remaining = heavy
            self.log.add(f'  第 {rounds} 轮：留下 {len(remaining)} 个继续切，已删 {len(blanked)} 个，'
                         f'当前 {t_heavy:.2f} 秒（比基线少 {base - t_heavy:.2f} 秒）')
        # 收敛后按「边际贡献」定数：只留它 vs 连它一起删 —— 不受每轮噪声累积影响
        target = remaining[0]
        t_keep = self._time(apply_fn(blanked + [u for u in remaining if u is not target]),
                            f'只留 {label_of(target)} 不删')
        t_none = self._time(apply_fn(blanked + remaining), f'连 {label_of(target)} 一起删')
        if t_keep is None or t_none is None:
            self.log.add(f'  → 最热：{label_of(target)}（单独删编译不过，贡献未知）')
            return target, 0.0, base, rounds
        contribution = t_keep - t_none
        self.log.add(f'  → 最热：{label_of(target)}，边际贡献 {contribution:.2f} 秒'
                     f'（只留它 {t_keep:.2f} − 连它一起删 {t_none:.2f}；全文件基线 {base:.2f}，'
                     f'所有候选函数体合计 {base - t_none:.2f} 秒）')
        if contribution < self.min_effect:
            self.log.add(f'  该值 < 判读门限 {self.min_effect:.2f} 秒：这一层没有显著差异')
        return target, contribution, base, rounds


# ---------- 三个动作 ----------

def count_functions(text):
    return sum(1 for u in scan_units(text) if u.kind == 'func')


ENTRY = re.compile(r'\b(kernel|vertex|fragment)\b|\[\[\s*(kernel|vertex|fragment)\s*\]\]')


def is_entry(unit, text):
    """入口函数（kernel / vertex / fragment）：二分时不删——删它的函数体等于把整条调用链一起删掉，
    差值全归到入口头上，定位不到真正的结构；入口的代价算在它调到的那些函数上。"""
    return bool(ENTRY.search(text[unit.start:unit.start + text[unit.start:unit.end].index('{')]))


def cmd_measure(args):
    compiler = Compiler(args.xcrun, args.sdk, args.extra_arg, args.timeout, args.calibrate)
    rows = []
    bad = 0
    for path in args.files:
        text = open_text(path)
        calib = compiler.calibration()
        try:
            median, low, high, air = compiler.time_median(path, args.reps, args.warmup)
        except CompileError as exc:
            print(f'【红】{path}：{exc}', file=sys.stderr)
            bad += 1
            continue
        size = os.path.getsize(path)
        row = {
            'file': os.path.relpath(path, args.root) if args.root else path,
            'bytes': size,
            'mib': f'{size / MIB:.3f}',
            'functions': count_functions(text),
            'reps': args.reps,
            'median_s': f'{median:.2f}',
            'min_s': f'{low:.2f}',
            'max_s': f'{high:.2f}',
            's_per_mib': f'{median / (size / MIB):.2f}' if size else '',
            'air_bytes': air,
            'calib_s': calib,
            'load1': load1(),
        }
        rows.append(row)
        print(f"{row['file']}: {row['median_s']} 秒 / {row['mib']} MiB = {row['s_per_mib']} 秒每 MiB"
              f"（函数 {row['functions']}，{low:.2f}–{high:.2f}，load {row['load1']}）")
    write_rows(rows, args, ('file', 'bytes', 'mib', 'functions', 'reps', 'median_s', 'min_s', 'max_s',
                            's_per_mib', 'air_bytes', 'calib_s', 'load1'))
    print(f'编译调用 {compiler.calls} 次' + (f'；{bad} 个文件编译不过' if bad else ''))
    return 2 if bad else 0


SECTION_OPEN = re.compile(r'^//#region section ([A-Za-z0-9_]+)\s*$', re.M)
SECTION_CLOSE = re.compile(r'^//#endregion section ([A-Za-z0-9_]+)\s*$', re.M)


def split_sections(text):
    """按夹具标记切段；每段自带 #include 与 kernel，能单独编译。"""
    out, pos = [], 0
    while True:
        m = SECTION_OPEN.search(text, pos)
        if not m:
            break
        end = SECTION_CLOSE.search(text, m.end())
        if not end:
            raise SystemExit(f'段 {m.group(1)} 没有 //#endregion 收尾（偏移 {m.start()}）')
        out.append((m.group(1), text[m.end():end.start()]))
        pos = end.end()
    return out


def cmd_sections(args):
    compiler = Compiler(args.xcrun, args.sdk, args.extra_arg, args.timeout, args.calibrate)
    text = open_text(args.files[0])
    sections = split_sections(text)
    if not sections:
        raise SystemExit(f'{args.files[0]} 里没有 //#region section 标记')
    rows, tmp = [], tempfile.mkdtemp(prefix='metal_prof_sections_')
    try:
        for index, (name, body) in enumerate(sections, 1):
            path = os.path.join(tmp, f'{index:02d}_{name}.metal')
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(body)
            calib = compiler.calibration()
            try:
                median, low, high, air = compiler.time_median(path, args.reps, args.warmup)
            except CompileError as exc:
                print(f'【红】段 {name} 编译不过：{exc}', file=sys.stderr)
                continue
            size = os.path.getsize(path)
            row = {
                'source': os.path.basename(args.files[0]), 'section': name, 'bytes': size,
                'mib': f'{size / MIB:.3f}', 'functions': count_functions(body), 'reps': args.reps,
                'median_s': f'{median:.2f}', 'min_s': f'{low:.2f}', 'max_s': f'{high:.2f}',
                's_per_mib': f'{median / (size / MIB):.2f}', 'air_bytes': air,
                'calib_s': calib, 'load1': load1(),
            }
            rows.append(row)
            print(f"{name:<11} {size:>9} B  {median:6.2f} 秒  = {row['s_per_mib']:>6} 秒每 MiB"
                  f"（{low:.2f}–{high:.2f}，函数 {row['functions']}）")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    write_rows(rows, args, ('source', 'section', 'bytes', 'mib', 'functions', 'reps', 'median_s',
                            'min_s', 'max_s', 's_per_mib', 'air_bytes', 'calib_s', 'load1'))
    print(f'编译调用 {compiler.calls} 次')
    return 0


def cmd_bisect(args):
    path = args.files[0]
    text = open_text(path)
    compiler = Compiler(args.xcrun, args.sdk, args.extra_arg, args.timeout)
    log = BisectLog(path=args.log)
    units = scan_units(text)
    funcs = [u for u in units if u.kind == 'func']
    if len(funcs) < 2:
        raise SystemExit(f'{path} 只有 {len(funcs)} 个函数，没得二分')
    entries = [u for u in funcs if is_entry(u, text)]
    candidates = [u for u in funcs if not is_entry(u, text)] or funcs
    log.add(f'# 二分定位 {path}（{os.path.getsize(path)} B，{len(funcs)} 个函数，reps={args.reps}，'
            f'warmup={args.warmup}，每轮删一半函数体（签名保留）再测）')
    log.add(f'# 不参与二分：{len(entries)} 个入口函数（kernel/vertex/fragment）'
            f'{("：" + "、".join(u.name for u in entries[:8]) + ("…" if len(entries) > 8 else "")) if entries else ""}')
    bisector = Bisector(compiler, text, args.reps, args.warmup, log, args.min_effect)
    try:
        def apply_blank(targets):
            return apply_edits(text, [blank_edit(u, text) for u in targets])

        hottest, contribution, base, rounds = bisector.bisect_units(
            candidates, apply_blank, lambda u: u.name, f'函数级二分（{len(candidates)} 个候选函数）')
        if hottest is None:
            log.add('结论：函数级二分没收敛（变体编译不过），只能给到 sections 的段级读数')
            return 1
        body_start = text.index('{', hottest.start) + 1
        body_end = text.rindex('}', hottest.start, hottest.end)
        body = text[body_start:body_end]
        chunks = scan_statements(body)
        log.add(f'# 最热函数 {hottest.name} 函数体 {body_end - body_start} B，顶层语句块 {len(chunks)} 个')
        chunk_name, chunk_s = '', 0.0
        if len(chunks) >= 2:
            others = [u for u in candidates if u is not hottest]

            def apply_chunks(targets):
                edits = [blank_edit(u, text) for u in others]
                edits += [(u.start, u.end, '') for u in targets]     # 语句块单元已经带绝对偏移
                return apply_edits(text, edits)

            all_units = [Unit('chunk', body_start + s, body_start + e, f'块#{i}')
                         for i, (s, e) in enumerate(chunks)]
            chunk_units = []
            for unit in all_units:
                rest = body[:unit.start - body_start] + body[unit.end - body_start:]
                if deletable(text[unit.start:unit.end], rest):
                    chunk_units.append(unit)
            dropped = len(all_units) - len(chunk_units)
            if dropped:
                log.add(f'# {dropped} 个块不能删（声明了后面还要用的变量 / 含 return），不参与二分')
            log.add(f'# 在「其余函数体全删」的底子上二分 {hottest.name} 的语句块')
            floor = apply_chunks([])          # 其余函数体已删、语句块全留：语句块这一层的基线
            target, chunk_s, chunk_base, _ = bisector.bisect_units(
                chunk_units, apply_chunks, lambda u: u.name,
                f'{hottest.name} 语句块二分（{len(chunk_units)} 块可删）', base_text=floor)
            if target is not None:
                chunk_name = target.name
                snippet = text[target.start:target.end].strip().replace('\n', ' ')
                log.add(f'# {chunk_name} 开头 120 字符：{snippet[:120]}')
        if chunk_name and chunk_s >= args.min_effect:
            chunk_part = (f'其中 {chunk_name} 贡献 {chunk_s:.2f} 秒'
                          f'（占该函数体 {chunk_s / chunk_base * 100 if chunk_base else 0:.0f}%）')
        elif chunk_name:
            chunk_part = (f'语句块层面没有占主导的单块：最重的一块边际 {chunk_s:.2f} 秒 < 门限 '
                          f'{args.min_effect:.2f} 秒，代价摊在整个函数体上')
        else:
            chunk_part = '函数体内没有可再删的语句块'
        if contribution < args.min_effect:
            summary = (f'结论：函数级没有占主导的单个函数——最热的 {hottest.name} 边际只有 '
                       f'{contribution:.2f} 秒（门限 {args.min_effect:.2f} 秒，文件基线 {base:.2f} 秒），'
                       f'代价摊在很多函数上；' + chunk_part)
        else:
            summary = (f'结论：{hottest.name} 的函数体贡献 {contribution:.2f} 秒 / 文件基线 {base:.2f} 秒'
                       f'（{contribution / base * 100 if base else 0:.0f}%）；' + chunk_part)
        log.add(summary)
        if args.out:
            with open(args.out, 'w', encoding='utf-8') as fh:
                writer = csv.writer(fh, delimiter='\t')
                writer.writerow(['function', 'function_s', 'function_pct', 'chunk', 'chunk_s',
                                 'file_base_s', 'rounds'])
                writer.writerow([hottest.name, f'{contribution:.2f}',
                                 f'{contribution / base * 100 if base else 0:.0f}', chunk_name,
                                 f'{chunk_s:.2f}', f'{base:.2f}', rounds])
            print(f'读数写入 {args.out}')
        return 0
    finally:
        bisector.close()
        log.save()
        print(f'编译调用 {compiler.calls} 次；日志 {args.log or "未指定 --log，只在终端"}')


# ---------- 公共 ----------

def open_text(path):
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            return fh.read()
    except OSError as exc:
        raise SystemExit(f'读不到输入 {path}：{exc.strerror}') from exc


def write_rows(rows, args, fields):
    if not args.out:
        return
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or '.', exist_ok=True)
    delimiter = ',' if args.format == 'csv' else '\t'
    with open(args.out, 'w', encoding='utf-8', newline='') as fh:
        writer = csv.DictWriter(fh, fieldnames=list(fields), delimiter=delimiter, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)
    print(f'读数写入 {args.out}')


def main(argv=None):
    ap = argparse.ArgumentParser(description='Metal 编译耗时剖析（只读；measure / sections / bisect）')
    sub = ap.add_subparsers(dest='cmd', required=True)

    def common(p, reps_default=3):
        p.add_argument('--reps', type=int, default=reps_default, help=f'每个变体测几次取中位（缺省 {reps_default}）')
        p.add_argument('--warmup', type=int, default=1, help='丢弃前几次（缺省 1，吃掉工具链冷启动）')
        p.add_argument('--sdk', default='iphoneos')
        p.add_argument('--xcrun', default='xcrun')
        p.add_argument('--extra-arg', action='append', default=[], help='追加传给 metal 的参数')
        p.add_argument('--timeout', type=int, default=1800, help='单次编译超时秒数')
        p.add_argument('--out', default='', help='读数写进这个文件（缺省 TSV，--format csv 换逗号）')
        p.add_argument('--format', choices=('tsv', 'csv'), default='tsv')
        p.add_argument('--root', default='', help='输出里文件名的前缀裁剪目录')
        p.add_argument('--calibrate', default='', help='每个输入前先编这份参照文件，记 calib_s（判断这批读数有没有被别的作业拖慢）')

    m = sub.add_parser('measure', help='逐文件编译计时')
    m.add_argument('files', nargs='+')
    common(m)
    m.set_defaults(func=cmd_measure)

    s = sub.add_parser('sections', help='按 //#region section 标记切段，逐段计时')
    s.add_argument('files', nargs=1)
    common(s)
    s.set_defaults(func=cmd_sections)

    b = sub.add_parser('bisect', help='二分删函数 / 删语句块，定位拖慢编译的部分')
    b.add_argument('files', nargs=1)
    common(b, reps_default=1)      # 二分一条路几十次编译：缺省 1 次，噪声靠 --min-effect 兜
    b.add_argument('--log', default='', help='每轮记录写进这个文件（可复现）')
    b.add_argument('--min-effect', type=float, default=0.10, help='小于这个秒数的差异当噪声（缺省 0.10）')
    b.set_defaults(func=cmd_bisect)       # 二分轮数多：reps 沿用 --reps（缺省 3），要快可 --reps 1

    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except CompileError as exc:
        print(f'【红】{exc}', file=sys.stderr)
        if exc.stderr:
            print('\n'.join(exc.stderr.strip().splitlines()[:6]), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())

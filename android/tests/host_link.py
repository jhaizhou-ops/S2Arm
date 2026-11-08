#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""安卓宿主单测的链接闭包：测试只写「种子」源文件，链接清单其余部分按目标文件符号自动推导。

用法：把 `subprocess.run(cmd, ...)`（cmd 是一条 cc 编译 + 链接命令）换成 `host_link.run(cmd, ...)`，参数同 subprocess.run。

11-06 起因：#1603 / W2 等生产改动给 nvn_vk_*.c / direct/*.c 加了新引用，7 个宿主单测各自手写的源文件表与
「弱链接[androiddraw]」登记都没跟上，main 合入后在 macOS 门禁机上才链接红。手写清单天然落后于生产代码，
这里改由符号表推导，两类引用分开处理：
- 链接器报未定义的符号：在生产源码（PROVIDER_GLOBS）里找唯一定义它的 .c，用同一套编译参数编进来再链，迭代到闭合；
  以链接器报错为准，-dead_strip / --gc-sections 剥掉的死代码引用不多拉文件；测试自己给了替身（强定义）的符号
  不会被补，替身照旧生效。找不到 / 多处定义则不猜，链接红并逐个点名。
- 只有弱引用（`__attribute__((weak))`）的符号：生产语义是「缺定义即空指针」（ELF），不补链；macOS ld64 不接受
  未定义弱引用，按目标文件实算的弱引用集生成 -U 放行（tools/weak_link_decl.u_flags），不再手工登记。
Linux 与 macOS 走同一套推导，补链结果一致；只有 -U 放行是 macOS 专有。
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import weak_link_decl  # noqa: E402

# 可被自动补链的生产源码（不含 tests/）：安卓原生层 + 共用 NVN 前端
PROVIDER_GLOBS = ('android/native/**/*.c', 'graphics/nvn/gfx/nvn/*.c')
SOURCE_SUFFIXES = ('.c', '.m')
OBJECT_SUFFIXES = ('.o', '.a')
VALUE_FLAGS = {'-o', '-include', '-imacros', '-isystem', '-iquote', '-idirafter', '-x', '-MF', '-MT', '-MQ',
               '-I', '-D', '-U', '-L', '-framework', '-arch', '-target', '-isysroot'}
MAX_ROUNDS = 12   # 补链轮数上限：每轮至少补进一个文件，正常两三轮闭合
_announced = set()


def _is_link_only(arg):
    return arg.startswith(('-l', '-L', '-Wl,')) or arg in ('-rdynamic', '-static', '-shared')


def _parse(cmd):
    """切出 (输出, [(下标, 输入文件)])；不是「编译 + 链接成可执行文件」的命令返回 None。"""
    if any(a in ('-c', '-E', '-S', '-fsyntax-only', '-M', '-MM', '-shared') for a in cmd[1:]):
        return None
    out, inputs, i = None, [], 1
    while i < len(cmd):
        a = str(cmd[i])
        if a in VALUE_FLAGS:
            if a == '-o' and i + 1 < len(cmd):
                out = str(cmd[i + 1])
            i += 2
            continue
        if not a.startswith('-') and a.endswith(SOURCE_SUFFIXES + OBJECT_SUFFIXES):
            inputs.append((i, a))
        i += 1
    return (out, inputs) if out and inputs else None


def _symbols(obj):
    """(定义的全局符号, 强引用未定义, 弱引用未定义)；macOS 去掉前导下划线。"""
    defined, strong, weak = set(), set(), set()
    if sys.platform == 'darwin':
        text = subprocess.run(['nm', '-m', obj], capture_output=True, text=True, check=True).stdout
        for line in text.splitlines():
            name = line.rsplit(' ', 1)[-1]
            if not name.startswith('_'):
                continue
            name = name[1:]
            if '(undefined)' in line:
                (weak if '(undefined) weak external' in line else strong).add(name)
            elif ' external ' in line and 'non-external' not in line:
                defined.add(name)
        return defined, strong, weak
    text = subprocess.run(['nm', '-P', '-g', obj], capture_output=True, text=True, check=True).stdout
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        name, kind = parts[0], parts[1]
        if kind == 'U':
            strong.add(name)
        elif kind in ('w', 'v'):
            weak.add(name)
        elif kind.isupper():
            defined.add(name)
    return defined, strong, weak


_DEF = re.compile(r'^(?!static\b|extern\b|typedef\b|return\b)[A-Za-z_][\w \t\*]*?\b([A-Za-z_]\w*)\s*(\(|=|\[|;)')
_index = None


def _provider_index(root=ROOT):
    """{符号: [文本上像定义它的生产 .c]}：非 static / extern 的顶层函数定义或全局变量定义行（以 ; 结尾的函数声明除外）。
    文本只是候选，补链前仍编译后用 nm 核实确实定义了该符号。"""
    global _index
    if _index is None:
        _index = {}
        for g in PROVIDER_GLOBS:
            for p in sorted(Path(root).glob(g)):
                if any('test' in part for part in p.relative_to(root).parts):   # tests/、direct-vk-tests/ 等夹具不当生产提供方
                    continue
                for line in p.read_text(errors='replace').splitlines():
                    m = _DEF.match(line)
                    if m and not (m.group(2) == '(' and line.rstrip().endswith(';')):
                        _index.setdefault(m.group(1), [])
                        if p not in _index[m.group(1)]:
                            _index[m.group(1)].append(p)
    return _index


def candidates(name):
    return list(_provider_index().get(name, ()))


def _compile_args(cmd, inputs):
    drop = {i for i, _ in inputs}
    args, i = [], 1
    while i < len(cmd):
        a = str(cmd[i])
        if i in drop:
            i += 1
            continue
        if a == '-o':
            i += 2
            continue
        if a == '-framework' or a == '-L':
            i += 2
            continue
        if a in VALUE_FLAGS:
            args += [a, str(cmd[i + 1])]
            i += 2
            continue
        if not _is_link_only(a):
            args.append(a)
        i += 1
    return [str(cmd[0])] + args


def _fail(cmd, rc, out, err, check, text):
    if check:
        raise subprocess.CalledProcessError(rc, cmd, out, err)
    return subprocess.CompletedProcess(cmd, rc, out if text else out.encode(), err if text else err.encode())


def _undefined(stderr):
    """链接器报的未定义符号名（ld64 / GNU ld / lld 三种措辞）。"""
    names = set(re.findall(r'"_([A-Za-z_]\w*)", referenced from', stderr))
    names |= set(re.findall(r"undefined reference to [`']([A-Za-z_]\w*)'", stderr))
    names |= set(re.findall(r'undefined symbol: ([A-Za-z_]\w*)', stderr))
    return names


def _hint(names, ambiguous):
    for n in sorted(names):
        if n in ambiguous:
            where = '多处生产源码都有定义，不猜：' + '、'.join(ambiguous[n])
        else:
            c = [q.relative_to(ROOT).as_posix() for q in candidates(n)]
            where = ('候选 ' + '、'.join(c) + ' 用本条编译参数编不过或没定义它') if c else '生产源码里没找到定义（测试替身漏了，或生产代码引用了不存在的符号）'
        print(f'【红】host_link：符号 {n} 闭合不了链接：{where}', file=sys.stderr)


def run(cmd, *, check=False, capture_output=False, text=None, timeout=None, cwd=None, env=None, **kw):
    """subprocess.run 的替身，专管「源文件 → 可执行文件」的 cc 命令；其他命令原样转交。

    先只用测试给的种子链接；链接器报哪些符号未定义，就去生产源码找唯一提供方编进来再链，直到链过或无可补。
    以链接器的报错为准（而不是目标文件里全部未定义引用），-dead_strip / --gc-sections 剥掉的死代码引用不会多拉文件。
    """
    cmd = [str(a) for a in cmd]
    parsed = _parse(cmd)
    if parsed is None:
        return subprocess.run(cmd, check=check, capture_output=capture_output, text=text, timeout=timeout, cwd=cwd, env=env, **kw)
    _, inputs = parsed
    base = _compile_args(cmd, inputs)
    outs, errs = [], []

    def emit(r):
        outs.append(r.stdout)
        errs.append(r.stderr)
        if not capture_output:
            sys.stdout.write(r.stdout)
            sys.stderr.write(r.stderr)

    with tempfile.TemporaryDirectory(prefix='host-link-') as td:
        n = [0]

        def compile_one(src, show=True):
            n[0] += 1
            obj = os.path.join(td, f'{n[0]:03d}-{Path(src).stem}.o')
            r = subprocess.run(base + ['-c', src, '-o', obj], capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env)
            if show:
                emit(r)
            return obj, r.returncode

        objs = {}        # 命令行下标 → 目标文件
        for i, path in inputs:
            if path.endswith(SOURCE_SUFFIXES):
                obj, rc = compile_one(path)
                if rc:
                    return _fail(cmd, rc, ''.join(outs), ''.join(errs), check, text)
                objs[i] = obj
            else:
                objs[i] = path
        syms = {o: _symbols(o) for o in objs.values() if o.endswith('.o')}
        seen = {Path(cwd or '.', p).resolve() for _, p in inputs}
        added, tried, ambiguous = [], set(), {}
        last = max(objs)
        for _ in range(MAX_ROUNDS):
            link = [cmd[0]]
            for i, a in enumerate(cmd[1:], 1):
                link.append(objs.get(i, a))
                if i == last:
                    link += [obj for _, obj in added]
            if sys.platform == 'darwin':
                defined = set().union(*(d for d, _, _ in syms.values()))
                strong = set().union(*(s for _, s, _ in syms.values()))
                weak = set().union(*(w for _, _, w in syms.values()))
                link += weak_link_decl.u_flags(weak - defined - strong)
            r = subprocess.run(link, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env)
            missing = _undefined(r.stderr) if r.returncode else set()
            progress = False
            for name in sorted(missing - tried):
                tried.add(name)
                found = []
                for q in candidates(name):
                    if q.resolve() in seen:
                        continue
                    obj, rc = compile_one(str(q), show=False)
                    if not rc and name in _symbols(obj)[0]:
                        found.append((q, obj))
                if len(found) == 1:
                    q, obj = found[0]
                    seen.add(q.resolve())
                    added.append((q, obj))
                    syms[obj] = _symbols(obj)
                    progress = True
                    key = (q.as_posix(), name)
                    if key not in _announced:
                        _announced.add(key)
                        print(f'host_link：自动补链 {q.relative_to(ROOT).as_posix()}（提供 {name}）', file=sys.stderr)
                elif found:
                    ambiguous[name] = [q.relative_to(ROOT).as_posix() for q, _ in found]
            if r.returncode == 0 or not progress:
                break
        emit(r)
        if r.returncode:
            _hint(missing, ambiguous)
            return _fail(cmd, r.returncode, ''.join(outs), ''.join(errs), check, text)
    o, e = ''.join(outs), ''.join(errs)
    return subprocess.CompletedProcess(cmd, 0, o if text else o.encode(), e if text else e.encode())

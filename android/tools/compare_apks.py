#!/usr/bin/env python3
"""#1131 docker / host 两路同提交 APK 等价核对（可重跑）。

判据：两边 zip 条目按「路径 + 大小」比对——条目集合必须完全相同；
非 .so 条目逐名大小必须相同；.so 按复审口径比「加载进内存的内容」：
两边各自 llvm-objcopy 去掉不进内存的段（--strip-all 加上
.comment / .note.gnu.build-id / .note.android.ident）后逐字节比对，
相同判绿（原始大小差只作备注），仍不同判红并用 llvm-readelf -S
逐段列出差异帮助定位。objcopy 不可用或处理失败时无法证明加载态
一致，.so 大小差维持判红，不悄悄放行。

动态符号另比 `llvm-nm -D` 输出：去掉符号地址列后按「类型符 + 名字」
保留原行、排序、逐行比对——保留未定义符号的 U 与重复条目（同一
符号多次定义在两边都必须出现同样的次数）。地址本身只作报告项，
不做等价判据。

用法：
    python3 android/tools/compare_apks.py \
        --left <docker产物.apk> --right <host产物.apk> --nm <llvm-nm 路径>
    llvm-objcopy / llvm-readelf 缺省取 --nm 同目录同名工具，再回 PATH，
    也可用 --objcopy / --readelf 显式指定。
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

_ADDR_RE = re.compile(r'^[0-9a-fA-F]+$')
# 不进内存的段（#1207 复审三轮批准口径，逐字）
_STRIP_ARGS = ['--strip-all',
               '--remove-section=.comment',
               '--remove-section=.note.gnu.build-id',
               '--remove-section=.note.android.ident']


def entry_map(apk):
    with zipfile.ZipFile(apk) as z:
        return {i.filename: i.file_size for i in z.infolist() if not i.is_dir()}


def tool_sibling(nm, name):
    """--nm 同目录的同名 llvm 工具，找不到回 PATH。"""
    cand = nm.parent / name
    if cand.is_file() and os.access(cand, os.X_OK):
        return str(cand)
    return shutil.which(name)


def dyn_symbols(nm, so_path):
    """Sorted `llvm-nm -D` lines as `type name`, address column dropped.

    Defined symbols print as `ADDR T name`; undefined ones print as
    `                U name` (leading blanks, no address). Keeping the
    line after the address preserves the type char (including U) and
    duplicates; sorting a list (not a set) keeps multiplicity.
    """
    out = subprocess.run([nm, '-D', str(so_path)], capture_output=True, text=True)
    if out.returncode != 0:
        raise ValueError(f'llvm-nm -D 失败 {so_path}: {out.stderr.strip()}')
    lines = []
    for raw in out.stdout.splitlines():
        parts = raw.split(None, 1)
        if not parts:
            continue
        if (len(parts) == 2 and _ADDR_RE.match(parts[0])
                and len(parts[1]) > 1 and parts[1][1] == ' '):
            lines.append(parts[1].rstrip())
        else:
            # No address column (e.g. ` U foo`): the whole line is type+name.
            # parts[1][1] == ' ' keeps single-hex-letter types (b/d/f...) from
            # being mistaken for a short address.
            lines.append(raw.strip())
    return sorted(lines)


def loadable_image(objcopy, so_path, out_path):
    """去掉不进内存的段后的字节；objcopy 缺或处理失败返回 None（无法证明）。"""
    if not objcopy:
        return None
    r = subprocess.run([objcopy, *_STRIP_ARGS, str(so_path), str(out_path)],
                       capture_output=True, text=True)
    if r.returncode != 0 or not out_path.is_file():
        return None
    return out_path.read_bytes()


def section_diff(readelf, lso, rso):
    """llvm-readelf -S 逐段比（名字 + 大小），列出是哪几个段不同。"""
    def sections(path):
        out = subprocess.run([readelf, '-S', str(path)], capture_output=True, text=True)
        got = {}
        for line in out.stdout.splitlines():
            m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+\S+\s+\S+\s+([0-9a-fA-F]+)', line)
            if m:
                got[m[1]] = int(m[2], 16)
        return got
    if not readelf:
        return ['  （llvm-readelf 不可用，段级定位略）']
    try:
        ls, rs = sections(lso), sections(rso)
    except OSError:
        return ['  （llvm-readelf 执行失败，段级定位略）']
    rows = []
    for name in sorted(set(ls) | set(rs)):
        if name not in ls:
            rows.append(f'  段只在 right: {name} ({rs[name]} 字节)')
        elif name not in rs:
            rows.append(f'  段只在 left: {name} ({ls[name]} 字节)')
        elif ls[name] != rs[name]:
            rows.append(f'  段大小不符 {name}: left={ls[name]} right={rs[name]}'
                        f'（Δ{rs[name] - ls[name]:+d}）')
    return rows or ['  段级大小全部一致：差异在段内容（如嵌入构建路径 / 编译器版本串）']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--left', required=True, type=Path, help='docker 路产物')
    ap.add_argument('--right', required=True, type=Path, help='host 路产物')
    ap.add_argument('--nm', required=True, type=Path, help='llvm-nm（两边用同一个）')
    ap.add_argument('--objcopy', type=Path, help='llvm-objcopy（缺省 --nm 同目录 / PATH）')
    ap.add_argument('--readelf', type=Path, help='llvm-readelf（缺省 --nm 同目录 / PATH）')
    args = ap.parse_args()
    for p in (args.left, args.right, args.nm):
        if not p.is_file():
            sys.exit(f'找不到 {p}')
    objcopy = str(args.objcopy) if args.objcopy else tool_sibling(args.nm, 'llvm-objcopy')
    readelf = str(args.readelf) if args.readelf else tool_sibling(args.nm, 'llvm-readelf')

    print(f'left  {args.left} ({args.left.stat().st_size} 字节)')
    print(f'right {args.right} ({args.right.stat().st_size} 字节)')

    left, right = entry_map(args.left), entry_map(args.right)
    diffs = []
    so_size_diffs = {}   # name -> (left_size, right_size)，判级在加载态比对后定
    for name in sorted(set(left) | set(right)):
        if name not in left:
            diffs.append(f'条目只在 right: {name}')
        elif name not in right:
            diffs.append(f'条目只在 left: {name}')
        elif left[name] != right[name]:
            if name.startswith('lib/') and name.endswith('.so'):
                so_size_diffs[name] = (left[name], right[name])
            else:
                diffs.append(f'条目大小不符 {name}: left={left[name]} right={right[name]}')

    so_names = sorted({n for n in set(left) & set(right)
                       if n.startswith('lib/') and n.endswith('.so')})
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        with zipfile.ZipFile(args.left) as zl, zipfile.ZipFile(args.right) as zr:
            for name in so_names:
                lso, rso = td / 'l.so', td / 'r.so'
                lso.write_bytes(zl.read(name))
                rso.write_bytes(zr.read(name))
                lsym = dyn_symbols(args.nm, lso)
                rsym = dyn_symbols(args.nm, rso)
                if lsym != rsym:
                    diffs.append(f'动态符号不符 {name}（left {len(lsym)} 行 / right {len(rsym)} 行）')
                    only_l = sorted(set(lsym) - set(rsym))[:40]
                    only_r = sorted(set(rsym) - set(lsym))[:40]
                    diffs += [f'  < {x}' for x in only_l] + [f'  > {x}' for x in only_r]
                limg = loadable_image(objcopy, lso, td / 'l.strip.so')
                rimg = loadable_image(objcopy, rso, td / 'r.strip.so')
                size_diff = name in so_size_diffs
                if limg is None or rimg is None:
                    if size_diff:
                        ls_, rs_ = so_size_diffs[name]
                        diffs.append(f'.so 体积差 {name}: left={ls_} right={rs_}'
                                     f'（Δ{rs_ - ls_:+d}；无法证明加载态一致，判红）')
                elif limg != rimg:
                    ls_, rs_ = so_size_diffs.get(name, (left[name], right[name]))
                    diffs.append(f'.so 加载态内容不符 {name}: left={ls_} right={rs_}'
                                 f'（Δ{rs_ - ls_:+d}；去 .comment/.note.*/符号表后逐字节不同）')
                    diffs += section_diff(readelf, lso, rso)
                elif size_diff:
                    ls_, rs_ = so_size_diffs[name]
                    print(f'备注 {name}: 大小差 Δ{rs_ - ls_:+d}，加载态字节相同')

    if diffs:
        print(f'两路产物不等价（{len(diffs)} 条差异）:', file=sys.stderr)
        for d in diffs:
            print(d, file=sys.stderr)
        return 1
    print(f'两路产物等价：条目 {len(left)} 个逐名相同、非 .so 逐大小相同，'
          f'.so {len(so_names)} 个加载态字节与动态符号逐行相同。')
    return 0


if __name__ == '__main__':
    sys.exit(main())

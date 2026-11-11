#!/usr/bin/env python3
"""逐游戏 RomFS 文本补丁：出包时把规则打到原版文件上、产出覆盖文件（规则在 graphics/widen/tables/<款>_<构建号>/romfs_patch.tsv）。
规则一行一条：<RomFS 相对路径>\t<原版整行（去缩进）>\t<替换整行（去缩进）>\t<原版出现次数>。
语义与 nxnative 线的 romfs_patch.tsv 同一套（那条线构建时把同一套规则烘进 RomFS 镜像；本仓不存游戏文件本体，
只存规则，出包时打到原版文件上、产物经 pack/stage_uilayout.sh 进 RomFS 覆盖层 ui_overlay，只许替换、不新增文件）。
替换保留每行自己的缩进与 CR（CRLF 文件照旧），产物与在编辑器里手工改出的文件逐字节一致。
计数对不上（原版行 / 已替换行任一计数不符）= 手上的游戏数据不是规则对应的版本 → 报红停：不许把一版的规则打到另一版的文件上。
原版行全无、替换行计数全对 = 已打过，原样输出（幂等）。
用法：romfs_patch.py <规则.tsv> <原版 romfs 目录> <输出目录>（输出目录下按相对路径写打好的文件）
"""
import os
import sys
from pathlib import Path


def load_spec(path):
    rules = {}
    for ln, line in enumerate(Path(path).read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        c = line.split('\t')
        if len(c) != 4:
            raise SystemExit(f'{path}:{ln}：规则须是「<路径>\\t<原版行>\\t<替换行>\\t<次数>」：{line!r}')
        p, old, new, n = c
        rules.setdefault(p, []).append((old, new, int(n)))
    if not rules:
        raise SystemExit(f'{path}：没有规则')
    return rules


def apply_rules(data, rules, name):
    """(打好字节, 是否已打过)——每条规则的计数必须恰好处于「全原版」或「全已打」一态，混杂 / 对不上即报红。"""
    counts = {old: 0 for old, _, _ in rules}
    news = {new: 0 for _, new, _ in rules}
    lines = data.split(b'\n')
    stripped_lines = []
    for line in lines:
        s = (line[:-1] if line.endswith(b'\r') else line).decode('utf-8')
        stripped_lines.append(s.strip())
    for stripped in stripped_lines:
        if stripped in counts:
            counts[stripped] += 1
        if stripped in news:
            news[stripped] += 1
    stock = all(counts[old] == n and news[new] == 0 for old, new, n in rules)
    done = all(counts[old] == 0 and news[new] == n for old, new, n in rules)
    if done:
        return data, True
    if not stock:
        want = '; '.join(f'{old!r} x{n}（实测原版 x{counts[old]}、已打 x{news[new]}）' for old, new, n in rules)
        raise SystemExit(f'{name}：规则与文件对不上：{want}')
    m = {old: new for old, new, _ in rules}
    out = []
    for line, stripped in zip(lines, stripped_lines):
        if stripped in m:
            cr = line.endswith(b'\r')
            s = (line[:-1] if cr else line).decode('utf-8')
            line = (s[:len(s) - len(s.lstrip())] + m[stripped]).encode('utf-8') + (b'\r' if cr else b'')
        out.append(line)
    return b'\n'.join(out), False


def main(argv):
    if len(argv) != 3:
        raise SystemExit('用法：romfs_patch.py <规则.tsv> <原版 romfs 目录> <输出目录>')
    spec, orig, outdir = Path(argv[0]), Path(argv[1]), Path(argv[2])
    rules = load_spec(spec)
    for rel, rs in rules.items():
        f = orig / rel
        if not f.is_file():
            raise SystemExit(f'{f}：原版 romfs 里没有这个文件，规则打不了')
        got, done = apply_rules(f.read_bytes(), rs, rel)
        o = outdir / rel
        o.parent.mkdir(parents=True, exist_ok=True)
        tmp = o.with_name(o.name + '.part')
        tmp.write_bytes(got)
        os.replace(tmp, o)
        print(f'romfs patch：{rel} {"已打过，原样输出" if done else "打好"}（{len(rs)} 条规则）')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

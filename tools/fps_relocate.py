#!/usr/bin/env python3
"""帧率表跨版本带用（情报 10-28：帧率表按构建号硬绑，换个版本 60 帧就静默失效）。

用法：python3 tools/fps_relocate.py <有表那版的 exefs/main> <新版的 exefs/main> <runtime/fps/<旧构建号>.tsv> [--write]
  判两版主程序的数据段 / bss 布局是否同构：数据段起点、大小与 bss 大小一样，且数据段里每一处不同都是「指针值差同一个常数」
  （代码段 / 只读段整体平移，指向它们的指针跟着变；10-29 巫师3 4.04c → 4.04a：70 万个 8 字节块里 610 处不同、全部差 −0x1F0）。
  同构 → 表里只碰数据段 / bss 的行（w、slot、speed、present30、present）原样成立，打出新构建号的表（--write 写 runtime/fps/<新构建号前 16 位>.tsv）；
  不同构、或表里有改指令的 c 行（代码地址要按指令重新定位，这里不做）→ 报红、退出 1，不出表。
  出的表只是候选：登记 60 帧仍要 tools/ab_pair.sh <款> fps60 关 / 开对照局、tools/fps_speed_judge.py 判 ρ≈1。
退出码：0 出表 / 1 不能带用 / 2 参数或读文件错。单测：tests/fps_relocate_test.py"""
import struct, sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'graphics/nvn/games'))


def load(path):
    """(镜像, 构建号 32 位十六进制, [(段内存偏移, 段大小)] × 3, bss 大小)"""
    import profile_guess
    img, bid, _, bss = profile_guess.nso(path)
    d = Path(path).read_bytes()
    return img, bid, [struct.unpack_from('<III', d, 0x10 + i * 0x10)[1:] for i in range(3)], bss


def isomorphic(old, new):
    """old / new = load() 的结果。返回 (同构与否, 理由)"""
    oi, _, os_, ob = old; ni, _, ns, nb = new
    (od, odz), (nd, ndz) = os_[2], ns[2]
    if (od, odz, ob) != (nd, ndz, nb):
        return False, f'数据段 / bss 布局不同：旧 数据 {od:#x}+{odz:#x} bss {ob:#x}，新 数据 {nd:#x}+{ndz:#x} bss {nb:#x}'
    deltas = Counter()
    for i in range(od, od + odz - 7, 8):
        a, b = oi[i:i + 8], ni[i:i + 8]
        if a != b: deltas[struct.unpack('<q', b)[0] - struct.unpack('<q', a)[0]] += 1
    if len(deltas) > 1:
        return False, f'数据段有 {sum(deltas.values())} 处不同、差值不止一种（{", ".join(f"{k:#x}×{v}" for k, v in deltas.most_common(3))}）：数据本身改了'
    n = sum(deltas.values())
    return True, f'数据段与 bss 同起点同大小，{(odz) // 8} 个 8 字节块里 {n} 处不同' + (f'、全部差 {next(iter(deltas)):#x}（指向代码 / 只读段的指针跟着平移）' if n else '')


def relocate(table_text, new_bid):
    """表文本 → (新表文本, 不能带用的行)。build 行换成新构建号；c 行（改指令）不能带用"""
    out, bad = [], []
    for line in table_text.splitlines():
        f = line.split('#')[0].split()
        if f[:1] == ['build']:
            out.append(f'build {new_bid[:16]}'); continue
        if f[:1] == ['c']:
            bad.append(line.strip())
        out.append(line)
    return '\n'.join(out) + '\n', bad


def main(a):
    if len(a) not in (3, 4) or (len(a) == 4 and a[3] != '--write'):
        print(__doc__.strip().splitlines()[2]); return 2
    try:
        old, new, text = load(a[0]), load(a[1]), Path(a[2]).read_text(encoding='utf-8')
    except (OSError, ValueError, struct.error) as e:
        print(f'🔴 读不了：{e}'); return 2
    ob = next((l.split()[1] for l in text.splitlines() if l.split()[:1] == ['build']), '')
    if not old[1].startswith(ob):
        print(f'🔴 表是构建号 {ob} 的，给的旧主程序是 {old[1]}'); return 2
    ok, why = isomorphic(old, new)
    if not ok:
        print(f'🔴 {old[1][:16]} → {new[1][:16]} 不能带用：{why}'); return 1
    body, bad = relocate(text, new[1])
    if bad:
        print(f'🔴 {old[1][:16]} → {new[1][:16]} 布局同构，但表里有 {len(bad)} 行改指令（c 行，代码地址要重新定位，这里不做）：{bad[0][:80]}'); return 1
    head = (f'# 由 tools/fps_relocate.py 从 {Path(a[2]).name}（主程序 {old[1]}）带到主程序 {new[1]}：{why}\n'
            f'# 候选：登记前跑 tools/ab_pair.sh <款> fps60 关 / 开对照局，tools/fps_speed_judge.py 判 ρ≈1\n')
    if len(a) == 4:
        dst = HERE.parent / 'runtime/fps' / f'{new[1][:16]}.tsv'
        if dst.exists():
            print(f'🔴 {dst} 已经有了，不覆盖'); return 1
        dst.write_text(head + body, encoding='utf-8')
        print(f'🟢 写入 {dst.relative_to(HERE.parent)}：{why}')
    else:
        print(head + body, end='')
        print(f'🟢 可以带用：{why}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

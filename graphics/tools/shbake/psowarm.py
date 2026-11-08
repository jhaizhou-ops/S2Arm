#!/usr/bin/env python3
# 提前热程序表（画面·着色器线 10-23，马车8 新包两局首局红：进赛道那帧 338 条管线首用、336 条在首用表里，预取却只取到约 100 条）：
#   python3 graphics/tools/shbake/psowarm.py <programs.tsv> <pso_use.tsv> <输出 pso_warm.tsv>
#   根因：Ryujinx 补丁 0100 让磁盘缓存开机只登记、程序在第一次查到时才实化；渲染器的管线预取（graphics/metal/gal_state.m gal_pso_pf_prog）
#   要等程序建成才排，而换场景那帧的程序就在当帧实化，预取没有提前量，开片 + 取管线全落在渲染线程上。
#   本表给运行时一个提前量：首用表（psouse.py 收的各正式局「管线首用」行）里出现过的程序，换成本包 Ryujinx 磁盘缓存的程序号，
#   按首用帧升序写出；运行时 Ryujinx 载完缓存后由后台线程按表读宿主二进制、交底层渲染器载入一次再放掉（补丁 shader-lazy-warm），
#   程序一建成就触发现有的管线预取，管线进预取池，换场景那帧渲染线程直接从池里取。
#   对位：programs.tsv 的 idx = 写进 Ryujinx 磁盘缓存的序号（ShaderBake.cs，-1 = 没写）；spv 列 = 各阶段函数键（逗号相连、不带 s 前缀），
#   首用表的函数名串 = 同一组键各加 s 前缀（链接版函数体名带 _lb 等后缀，只取逗号分段的前 17 个字符比）。同一组函数有多个程序号（特化状态不同）只取第一个：
#   渲染器的程序哈希只看各阶段键，第一个载入就把这组键在首用表里的管线全排进预取，再载同组的不会再排。
#   输出每行「<程序号>\t<首用帧>\t<函数名串>」，# 开头是注释；对不上的（首用表比包旧、程序已不在包里）只计数。读数打到标准输出。
import sys


def names(s):
    return ','.join(x[:17] for x in s.split(','))


def main(prog, use, out):
    by = {}
    with open(prog, encoding='utf-8') as f:
        for ln in f:
            c = ln.rstrip('\n').split('\t')
            if len(c) < 7 or c[0] in ('idx', '-1') or not c[0].lstrip('-').isdigit() or not c[6]:
                continue
            k = ','.join('s' + x for x in c[6].split(','))
            by.setdefault(k, int(c[0]))
    rows, seen, miss = [], set(), 0
    with open(use, encoding='utf-8') as f:
        for ln in f:
            if ln.startswith('#'):
                continue
            c = ln.rstrip('\n').split('\t')
            if len(c) < 3 or not c[0].isdigit():
                continue
            k = names(c[2])
            if k in seen:
                continue
            seen.add(k)
            if k in by:
                rows.append((by[k], int(c[0]), k))
            else:
                miss += 1
    rows.sort(key=lambda r: (r[1], r[0]))
    with open(out, 'w', encoding='utf-8') as f:
        f.write('# 提前热程序表 v1（psowarm.py）：<Ryujinx 磁盘缓存程序号>\t<首用帧>\t<函数名串>，按首用帧升序\n')
        for i, fr, k in rows:
            f.write(f'{i}\t{fr}\t{k}\n')
    print(f'提前热程序表：首用表 {len(seen)} 组函数，对上 {len(rows)} 个程序，对不上 {miss}（首用表比包旧 / 程序不在包里）')
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print('用法：psowarm.py <programs.tsv> <pso_use.tsv> <输出 pso_warm.tsv>', file=sys.stderr)
        sys.exit(2)
    sys.exit(main(*sys.argv[1:]))

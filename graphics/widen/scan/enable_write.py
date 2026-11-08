#!/usr/bin/env python3
"""宽屏启用表按档位写（graphics/widen/scan/closed_loop.sh --write 调）：enable_write.py <候选 widen_sites.tsv> <点集> <表目录> <档位>
写 <表目录>/widen_enable.<档位>.tsv：这一档位闭环全过的点集记 1、其余候选记 0。不合并各档位——装载器按 S2A_DOCKED 只读当前档位那张，
没在这一档位验过的点（例如塞尔达主机档显示分辨率 main:0xb4e7d8 在掌机档也执行）不会被带进别的档位。"""
import os, sys


def main():
    sites, on, E, mode = sys.argv[1], set(sys.argv[2].split(',')), sys.argv[3], sys.argv[4]
    assert mode in ('handheld', 'docked'), f'档位只认 handheld / docked：{mode}'
    rows = [l.rstrip('\n').split('\t') for l in open(sites)][1:]
    keys = {f'{m}:{o}' for m, o, *_ in rows}
    assert on <= keys, f'点集里有候选表没有的点：{on - keys}'
    path = f'{E}/widen_enable.{mode}.tsv'
    with open(path + '.tmp', 'w') as f:
        f.write('模块\t偏移\t种类\t启用\n')
        for m, o, k, *_ in rows: f.write(f'{m}\t{o}\t{k}\t{1 if f"{m}:{o}" in on else 0}\n')
    os.replace(path + '.tmp', path)
    print(f'写 {os.path.basename(path)}：启用 {sorted(on)}')


if __name__ == '__main__':
    main()

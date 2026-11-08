#!/usr/bin/env python3
"""Trinity 容器（ONEPACK + trpfd）枚举单测：手搓最小 FlatBuffers，不含任何游戏数据。

覆盖：描述表（文件哈希 / 包名 / 包大小 / 文件→包映射）、trpfs 头校验、包表、文件条目（压缩方式 / 长度 / 数据偏移）、
非 ONEPACK 与截断要报错、Oodle 条目（压缩 3）与存储条目要分开计。
⑥ 抽取器遇到读不了的容器（审计 #846 F-trpfs-extract-abort）：同一 arc/ 里 a.trpfs 打不开（是目录，open 抛 IsADirectoryError）、
b.trpfs 只有 16 字节 ONEPACK 头且根表偏移 100 越界（struct.error）、data.trpfs 正常 → 期望这两个各记一笔「【红】trpfs 结构读不了」（共 2）、
标准错误点名两个文件、正常容器的 2 行照样进 trpfs.tsv、抽取跑完（退出 0、写出 index.tsv）；原先 a 触发 UnboundLocalError、b 触发 struct.error，整次抽取中断。
"""
import os
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import trpfs as T  # noqa: E402


def build_fb(root_fields, root_index=0):
    """拼一个最小 FlatBuffers（只够本模块读，不是通用实现）。字段值描述：
         ('u64', n) / ('u64s', [..]) / ('strings', [b'..']) / ('tables', [{字段号: 值描述}])
    布局：vtable → table（soffset + 内联 u64）→ 每个向量字段一个 uoffset 槽 → 向量本体 → 子表。
    所有 uoffset 都指向后方（FlatBuffers 要求正向），所以目标一定排在引用它的槽之后。"""
    out = bytearray(root_index + 4)

    def place(nbytes, align=4):
        while len(out) % align:
            out.append(0)
        off = len(out)
        out.extend(b'\0' * nbytes)
        return off

    def table(fields):
        n = (max(fields) + 1) if fields else 0
        vt = place(4 + 2 * n, 2)
        tbl = place(4, 4)
        struct.pack_into('<i', out, tbl, tbl - vt)
        struct.pack_into('<H', out, vt, 4 + 2 * n)
        struct.pack_into('<H', out, vt + 2, 4 + 2 * n)
        slots = {}
        for idx in sorted(fields):
            kind, val = fields[idx]
            if kind == 'u64':
                pos = place(8, 8); struct.pack_into('<Q', out, pos, val)
                struct.pack_into('<H', out, vt + 4 + 2 * idx, pos - tbl)
            else:
                slots[idx] = place(4, 4)
        for idx, slot in slots.items():
            kind, val = fields[idx]
            if kind == 'u64s':
                vec = place(4 + 8 * len(val), 8); struct.pack_into('<I', out, vec, len(val))
                for i, v in enumerate(val):
                    struct.pack_into('<Q', out, vec + 4 + 8 * i, v)
            elif kind == 'strings':
                vec = place(4 + 4 * len(val), 4); struct.pack_into('<I', out, vec, len(val))
                for i, s_ in enumerate(val):
                    body = place(4 + len(s_), 4); struct.pack_into('<I', out, body, len(s_))
                    out[body + 4:body + 4 + len(s_)] = s_
                    struct.pack_into('<I', out, vec + 4 + 4 * i, body - (vec + 4 + 4 * i))
            else:                       # tables
                vec = place(4 + 4 * len(val), 4); struct.pack_into('<I', out, vec, len(val))
                for i, sub_fields in enumerate(val):
                    sub = table(sub_fields)
                    struct.pack_into('<I', out, vec + 4 + 4 * i, sub - (vec + 4 + 4 * i))
            struct.pack_into('<I', out, slot, vec - slot)
            struct.pack_into('<H', out, vt + 4 + 2 * idx, slot - tbl)
        return tbl

    root = table(root_fields)
    struct.pack_into('<I', out, root_index, root - root_index)
    return bytes(out)


def main():
    bad = []
    tmp = tempfile.mkdtemp()

    # ① 描述表：2 个文件哈希 → 包 0 / 包 1，2 个包名与大小
    desc_buf = build_fb({
        0: ('u64s', [0xAAAA, 0xBBBB]),
        1: ('strings', [b'arc/pack_a', b'arc/pack_b']),
        2: ('tables', [{0: ('u64', 0)}, {0: ('u64', 1)}]),
        3: ('tables', [{0: ('u64', 1000)}, {0: ('u64', 2000)}]),
    })
    d = T.describe(desc_buf)
    if d['names'] != ['arc/pack_a', 'arc/pack_b']: bad.append(f"包名 {d['names']}")
    if d['sizes'] != [1000, 2000]: bad.append(f"包大小 {d['sizes']}")
    if d['pack_of'] != {0xAAAA: 0, 0xBBBB: 1}: bad.append(f"文件→包 {d['pack_of']}")

    # ② trpfs：头 + 根表（包偏移向量，1 个包）+ 包表（文件哈希向量 + 2 个条目表）
    pack_tbl_at = 0x400
    fs = build_fb({1: ('u64s', [pack_tbl_at])})
    body = bytearray(16 + len(fs))
    body[0:8] = T.ONEPACK
    struct.pack_into('<Q', body, 8, 16)            # 根表在 16 处（uoffset 相对，整体平移不影响）
    body[16:16 + len(fs)] = fs
    # 把包表放到 pack_tbl_at
    pack_buf = build_fb({
        0: ('u64s', [0xAAAA, 0xBBBB]),
        1: ('tables', [
            {1: ('u64', 3), 3: ('u64', 100)},                     # Oodle 条目（压缩 3）
            {1: ('u64', 0), 3: ('u64', 8)},                       # 存储条目
        ]),
    })
    while len(body) < pack_tbl_at: body.append(0)
    body[pack_tbl_at:pack_tbl_at + len(pack_buf)] = pack_buf
    p_trpfs = os.path.join(tmp, 'data.trpfs'); open(p_trpfs, 'wb').write(body)
    p_desc = os.path.join(tmp, 'data.trpfd'); open(p_desc, 'wb').write(desc_buf)

    pk = T.packs(p_trpfs, d)
    if len(pk) != 1: bad.append(f'包数 {len(pk)}')
    off, name, size = pk[0]
    if off != pack_tbl_at: bad.append(f'包偏移 {off:#x}')
    if name != 'arc/pack_a': bad.append(f"包名映射 {name!r}")
    if size != 1000: bad.append(f'包大小 {size}')

    ents = T.entries(p_trpfs, off)
    if len(ents) != 2: bad.append(f'条目数 {len(ents)}')
    if ents and ents[0][1] != 3: bad.append(f'条目 0 压缩 {ents[0][1]}')
    if ents and ents[1][1] != 0: bad.append(f'条目 1 压缩 {ents[1][1]}')
    if ents and ents[1][2] != 8: bad.append(f'条目 1 长度 {ents[1][2]}')

    # ③ 负例：哈希数与文件条目数不自洽 → 报错，不静默截断
    bad_pack = build_fb({0: ('u64s', [0xAAAA]), 1: ('tables', [{1: ('u64', 3), 3: ('u64', 9)}, {1: ('u64', 0), 3: ('u64', 8)}])})
    body2 = bytearray(16 + len(build_fb({1: ('u64s', [0x200])})))
    body2[0:8] = T.ONEPACK; struct.pack_into('<Q', body2, 8, 16)
    body2[16:16 + len(build_fb({1: ('u64s', [0x200])}))] = build_fb({1: ('u64s', [0x200])})
    while len(body2) < 0x200: body2.append(0)
    body2[0x200:0x200 + len(bad_pack)] = bad_pack
    p_bad2 = os.path.join(tmp, 'bad2.trpfs'); open(p_bad2, 'wb').write(body2)
    try:
        T.entries(p_bad2, 0x200); bad.append('哈希数与条目数不自洽没报错')
    except ValueError:
        pass

    # ④ 负例：不是 ONEPACK / 截断
    p_bad = os.path.join(tmp, 'bad.trpfs'); open(p_bad, 'wb').write(b'NOTPACK\0' + b'\0' * 32)
    try:
        T.packs(p_bad, d); bad.append('非 ONEPACK 没报错')
    except ValueError:
        pass
    p_short = os.path.join(tmp, 'short.trpfs'); open(p_short, 'wb').write(T.ONEPACK + b'\0\0\0')
    try:
        T.packs(p_short, d); bad.append('截断没报错')
    except (ValueError, struct.error):
        pass

    # ⑤ 抽取器集成：两个资源目录各带一个合成容器 → trpfs.tsv 行数 = 两个容器条目数之和；
    #    同一输出目录连跑两次行数不变（清单在一次抽取里只截断一次）
    import subprocess
    def make_container(dirpath, n_entries):
        """造一个带 n_entries 个条目（哈希 0xAAAA+i、压缩 0 = 存储）的最小 ONEPACK + trpfd"""
        arc = os.path.join(dirpath, 'arc'); os.makedirs(arc, exist_ok=True)
        pack_at = 0x400
        fs = build_fb({1: ('u64s', [pack_at])})
        body = bytearray(16 + len(fs)); body[0:8] = T.ONEPACK; struct.pack_into('<Q', body, 8, 16)
        body[16:16 + len(fs)] = fs
        hashes = [0xAAAA + i for i in range(n_entries)]
        pack = build_fb({0: ('u64s', hashes),
                         1: ('tables', [{1: ('u64', 0), 3: ('u64', 8)} for _ in range(n_entries)])})
        while len(body) < pack_at: body.append(0)
        body[pack_at:pack_at + len(pack)] = pack
        open(os.path.join(arc, 'data.trpfs'), 'wb').write(body)
        desc = build_fb({0: ('u64s', hashes), 1: ('strings', [b'arc/synthetic']),
                         2: ('tables', [{0: ('u64', 0)} for _ in range(n_entries)]),
                         3: ('tables', [{0: ('u64', 0x400)}])})
        open(os.path.join(arc, 'data.trpfd'), 'wb').write(desc)
        return n_entries

    d1 = os.path.join(tmp, 'romfsA'); d2 = os.path.join(tmp, 'romfsB')
    n1 = make_container(d1, 2); n2 = make_container(d2, 3)
    out = os.path.join(tmp, 'out'); os.makedirs(out, exist_ok=True)
    tool = os.path.join(HERE, '..', 'nxsh_extract.py')
    cmd = [sys.executable, os.path.abspath(tool), out, d1, d2]
    r = subprocess.run(cmd, capture_output=True, text=True)
    lst = os.path.join(out, 'trpfs.tsv')
    if not os.path.exists(lst):
        bad.append(f'抽取器没写出 trpfs.tsv（rc={r.returncode}）：{r.stderr[-200:]}')
    else:
        want = n1 + n2
        got = sum(1 for _ in open(lst, encoding='utf-8')) - 1      # 去表头
        if got != want: bad.append(f'两个目录清单应有 {want} 行，实得 {got}')
        subprocess.run(cmd, capture_output=True, text=True)        # 同一输出目录再跑一次
        got2 = sum(1 for _ in open(lst, encoding='utf-8')) - 1
        if got2 != want: bad.append(f'同目录重跑后清单变 {got2} 行（应 {want}，只截断一次）')

    # ⑥ 读不了的容器只记红、不打断抽取
    d3 = os.path.join(tmp, 'romfsC'); n3 = make_container(d3, 2); arc3 = os.path.join(d3, 'arc')
    desc3 = open(os.path.join(arc3, 'data.trpfd'), 'rb').read()
    os.makedirs(os.path.join(arc3, 'a.trpfs')); open(os.path.join(arc3, 'a.trpfd'), 'wb').write(desc3)
    open(os.path.join(arc3, 'b.trpfs'), 'wb').write(T.ONEPACK + struct.pack('<Q', 100)); open(os.path.join(arc3, 'b.trpfd'), 'wb').write(desc3)
    out3 = os.path.join(tmp, 'out3'); os.makedirs(out3, exist_ok=True)
    r = subprocess.run([sys.executable, os.path.abspath(tool), out3, d3], capture_output=True, text=True)
    stat_line = next((l for l in r.stdout.splitlines() if l.startswith('统计 ')), '')
    got3 = sum(1 for _ in open(os.path.join(out3, 'trpfs.tsv'), encoding='utf-8')) - 1 if os.path.exists(os.path.join(out3, 'trpfs.tsv')) else -1
    red3 = "'【红】trpfs 结构读不了': 2" in stat_line
    if not (r.returncode == 0 and os.path.exists(os.path.join(out3, 'index.tsv')) and red3 and got3 == n3
            and 'a.trpfs' in r.stderr and 'b.trpfs' in r.stderr and 'Traceback' not in r.stderr):
        bad.append(f'⑥ 读不了的容器：退出 {r.returncode}（应 0）、index.tsv {"有" if os.path.exists(os.path.join(out3, "index.tsv")) else "无"}、'
                   f'红计数 2 {"有" if red3 else "无"}、清单 {got3} 行（应 {n3}）；标准错误尾：{r.stderr.strip()[-200:]}')

    if bad:
        for b in bad: print('🔴', b)
        return 1
    print('trpfs 枚举：描述表映射、包表、条目压缩分类、非 ONEPACK / 截断报错、两目录清单合并与重跑稳定、读不了的容器记红不打断抽取 → 通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())

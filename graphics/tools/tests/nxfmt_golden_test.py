# 门禁手动：要私有游戏数据：本机游戏 romfs（acnh / botw / mk8d / smg2）；nxfmt 与 oead 逐字节对照的金标，维护方在有数据的机器上手动回归，缺样本退出 2
# SPDX-License-Identifier: Apache-2.0
"""nxfmt 真实样本金标：Yaz0 解压与 SARC 读出对真实游戏文件逐字节固定。

金标表 nxfmt_golden.tsv 每行：游戏短名、romfs 内相对路径、类别（yaz0 / sarc）、输入 sha256、输出 sha256、成员数。
表里只有哈希和路径，不含任何游戏数据。输出 sha256 的口径：
  yaz0：解压后的字节；
  sarc：按节点顺序把每个成员写成「名字 \\0 成员 sha256（32 字节）」再拼起来取 sha256；
  yaz0+sarc：先 Yaz0 解压、解出来是 SARC 再按 sarc 口径（出包里 .szs 的实际用法）。

用法：
  nxfmt_golden_test.py                 校验：在样本根（S2A_NXFMT_SAMPLES，缺省本机游戏数据根）下复算，逐行比对金标；
                                       样本根里没有的行记为「缺样本」，单列条数；一行都没比到时退出 2（结论不完整）
  nxfmt_golden_test.py --record <游戏>…  录制（维护方一次性）：用 oead 与 nxfmt 各解一遍，必须逐字节相同才写表；
                                       oead 只在录制时需要，校验不需要
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import nxfmt  # noqa: E402

TABLE = os.path.join(HERE, 'nxfmt_golden.tsv')
HEAD = ['游戏', '路径', '类别', '输入sha256', '输出sha256', '成员数']
PER_KIND = 20            # 每款每类最多取几个样本
MAX_BYTES = 8 << 20      # 单个样本上限，控制耗时


def root():
    return os.environ.get('S2A_NXFMT_SAMPLES') or os.path.expanduser('~/.s2arm/data')


def sarc_digest(pairs):
    h = hashlib.sha256()
    n = 0
    for name, blob in pairs:
        h.update(name.encode('utf-8') + b'\0' + hashlib.sha256(bytes(blob)).digest())
        n += 1
    return h.hexdigest(), n


def nx_out(kind, data):
    if kind == 'yaz0':
        out = nxfmt.yaz0_decompress(data)
        return hashlib.sha256(out).hexdigest(), 0
    if kind == 'yaz0+sarc':
        return sarc_digest(nxfmt.sarc_members(nxfmt.yaz0_decompress(data)))
    return sarc_digest(nxfmt.sarc_members(data))


def pick(game):
    """按路径排序后均匀取样，魔数判类别（不看扩展名）。"""
    base = os.path.join(root(), game, 'romfs')
    got = {'yaz0': [], 'sarc': []}
    for d, _, fs in sorted(os.walk(base)):
        for f in sorted(fs):
            p = os.path.join(d, f)
            try:
                if os.path.getsize(p) > MAX_BYTES or os.path.getsize(p) < 0x14:
                    continue
                with open(p, 'rb') as fh:
                    magic = fh.read(4)
            except OSError:
                continue
            kind = {b'Yaz0': 'yaz0', b'SARC': 'sarc'}.get(magic)
            if kind:
                got[kind].append(p)
    out = []
    for kind, ps in got.items():
        step = max(1, len(ps) // PER_KIND)
        out += [(kind, p) for p in ps[::step][:PER_KIND]]
    return base, out


def record(games):
    import oead  # 只在录制时需要
    rows, bad = [], []
    for g in games:
        base, samples = pick(g)
        for kind, p in samples:
            data = open(p, 'rb').read()
            if kind == 'yaz0':
                a = bytes(nxfmt.yaz0_decompress(data))
                b = bytes(oead.yaz0.decompress(data))
                same = a == b
                out, n = hashlib.sha256(a).hexdigest(), 0
            else:
                mine = list(nxfmt.sarc_members(data))
                theirs = [(f.name, bytes(f.data)) for f in oead.Sarc(data).get_files()]
                same = mine == theirs
                out, n = sarc_digest(mine)
            rel = os.path.relpath(p, base)
            if not same:
                bad.append(f'{g}/{rel}（{kind}）')
            rows.append([g, rel, kind, hashlib.sha256(data).hexdigest(), out, str(n)])
            if kind == 'yaz0' and a[:4] == b'SARC':
                mine = list(nxfmt.sarc_members(a))
                theirs = [(f.name, bytes(f.data)) for f in oead.Sarc(b).get_files()]
                if mine != theirs:
                    bad.append(f'{g}/{rel}（yaz0+sarc）')
                o2, n2 = sarc_digest(mine)
                rows.append([g, rel, 'yaz0+sarc', hashlib.sha256(data).hexdigest(), o2, str(n2)])
    if bad:
        print('与 oead 不一致（不写表）：\n  ' + '\n  '.join(bad))
        return 1
    with open(TABLE, 'w', encoding='utf-8') as f:
        f.write('\t'.join(HEAD) + '\n')
        for r in rows:
            f.write('\t'.join(r) + '\n')
    kinds = {k: sum(1 for r in rows if r[2] == k) for k in ('yaz0', 'sarc', 'yaz0+sarc')}
    per = {g: sum(1 for r in rows if r[0] == g) for g in games}
    print(f'录制：{len(games)} 款（{per}），yaz0 {kinds["yaz0"]} 个、sarc {kinds["sarc"]} 个、yaz0+sarc {kinds["yaz0+sarc"]} 个，与 oead 逐字节相同，写入 {os.path.basename(TABLE)}')
    return 0


def verify():
    rows = [l.rstrip('\n').split('\t') for l in open(TABLE, encoding='utf-8')][1:]
    ok = miss = 0
    bad = []
    first = None
    for g, rel, kind, sin, sout, n in rows:
        p = os.path.join(root(), g, 'romfs', rel)
        if not os.path.isfile(p):
            miss += 1
            continue
        data = open(p, 'rb').read()
        if hashlib.sha256(data).hexdigest() != sin:
            miss += 1   # 本机样本版本不同，不能拿来比
            continue
        out, cnt = nx_out(kind, data)
        if out == sout and str(cnt) == n:
            ok += 1
            if first is None and kind == 'yaz0':
                first = data
        else:
            bad.append(f'{g}/{rel}（{kind}）')
    # 负对照：把一个真实样本的解压结果改一个字节，哈希比对必须判不符
    neg = '未做（本机没有 yaz0 样本）'
    if first is not None:
        out = bytearray(nxfmt.yaz0_decompress(first))
        out[len(out) // 2] ^= 0x01
        row = next(r for r in rows if r[3] == hashlib.sha256(first).hexdigest())
        if hashlib.sha256(bytes(out)).hexdigest() == row[4]:
            bad.append('负对照：改一个字节后哈希仍相同（比对失效）')
        else:
            neg = '改一个字节即判不符 ✓'
    games = sorted({r[0] for r in rows})
    line = (f'nxfmt 真实样本金标：{len(rows)} 行（{len(games)} 款：{"、".join(games)}），'
            f'相同 {ok}、不同 {len(bad)}、缺样本 {miss}；负对照 {neg}')
    if bad:
        print('不同：\n  ' + '\n  '.join(bad))
    print(line)
    if bad:
        return 1
    if ok == 0:
        print('没有一行可比（样本根下没有对应游戏数据），结论不完整')
        return 2
    return 0


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--record':
        sys.exit(record(sys.argv[2:]))
    sys.exit(verify())

#!/usr/bin/env python3
# 门禁手动：要私有游戏数据：惊奇 1.2.1 的 romfs/Shader 目录 + libzstd（SARC 用 nxfmt），手动回归
"""惊奇 1.2.1 的真实资源回归；不包含或生成游戏资源、着色器 fixture。

用法：python t_smbw_bnsh.py <romfs/Shader 目录>（需要本机 libzstd；SARC 用 graphics/tools/nxfmt.py）。
固定输入 SHA256 与完整阶段记录摘要，其他版本应另行核对，不能更新期望值来绕过失败。
"""
import collections
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import nxfmt
import nxsh_extract as X


def digest(rows):
    return hashlib.sha256(json.dumps(sorted(rows), separators=(',', ':')).encode()).hexdigest()


def verify_bnsh(label, data, counts, expected_digest):
    rows = []; keys = set(); programs = collections.defaultdict(set); first = None
    for k, m in enumerate(re.finditer(b'BNSH\0\0\0\0', data)):
        size = struct.unpack_from('<I', data, m.start() + 0x1c)[0]
        b = data[m.start():m.start() + size]
        assert len(b) == size, f'{label}: BNSH 容器截断'
        codes = X.bnsh_codes(b)
        for v, stage, code, ctl, co in codes:
            key = X.key_of(ctl, code)
            assert key is not None, f'{label}: 仍丢弃变体 {v} 的 {stage}'
            assert ctl == b[co:co + len(ctl)], f'{label}: 控制段字节改变'
            assert len(ctl) == struct.unpack_from('<I', ctl, 0x20)[0]
            assert len(code) == struct.unpack_from('<I', ctl, 0x704)[0]
            rows.append((k, v, stage, key)); keys.add(key); programs[(k, v)].add(stage)
        if first is None: first = b, codes[0]
    assert (len(rows), len(keys), len(programs)) == counts, (label, len(rows), len(keys), len(programs))
    assert all(stages == {'vs', 'ps'} for stages in programs.values()), f'{label}: 真配对阶段不完整'
    assert digest(rows) == expected_digest, f'{label}: 阶段配对或键改变'
    b, (_, _, code, ctl, co) = first
    assert X.key_of(ctl[:-1], code) is None, '不能容忍控制段截断'
    assert X.key_of(ctl, code[:-1]) is None, '不能容忍机器码截断'
    # 从真实容器截去第一条控制块末尾及其后的内容，不能被 canonical 裁剪掩盖。
    try:
        X.bnsh_codes(b[:co + len(ctl) - 1])
    except (ValueError, struct.error):
        pass
    else:
        raise AssertionError(f'{label}: 接受了截断的真实容器')
    print(f'{label}: {len(rows)} 阶段记录，{len(keys)} 去重键，{len(programs)} 完整 VS/PS 变体；摘要与截断检查通过')
    return rows


if len(sys.argv) != 2: raise SystemExit(__doc__)
root = Path(sys.argv[1])
inputs = {
    'SecredUber.Product.100.product.Nin_NX_NVN.bfsha.zs': '5aa6159f76a115ccf5283a46252e6f24ae5f516df3281849ce7ecaccedead56a',
    'Secred.Nin_NX_NVN.release.sarc.zs': '7fb65eaa6b26815356368194383eca50413bbfab92e931d62cb8e41b822db8d0',
}
data = {}
for name, expected in inputs.items():
    compressed = (root / name).read_bytes()
    assert hashlib.sha256(compressed).hexdigest() == expected, f'{name}: 不是已核对的惊奇 1.2.1 资源'
    data[name] = X.zstd_dec(compressed)

uber = verify_bnsh('SecredUber.Product.100', data[next(iter(inputs))], (17160, 4860, 8580),
                   '46875e7cbd33bce4e75fe6c84cc7cc7f0c7d18cb81200dfe17c3e117c5890f97')
assert (0, 0, 'ps', 'd916a262f303c31b') in uber, '首个变体的真实片元着色器仍缺失'
sarc_name = 'Secred.Nin_NX_NVN.release.sarc.zs'
sarc = nxfmt.Sarc(data[sarc_name])
verify_bnsh('SARC/SecredUber', bytes(sarc.get_file('SecredUber.Nin_NX_NVN.bfsha').data), (442, 28, 221),
            '55cd4b1e43cb127fc30fd9d822cd4e98702cf6ec6068d8398495687c65550f2c')
for name in inputs:
    rows = []; blobs = {}; stat = collections.Counter()
    X.visit(name, (root / name).read_bytes(), rows, blobs, stat)
    assert stat['控制段与机器码长度对不上'] == 0 and stat['BNSH 解析失败'] == 0, (name, stat)
    expected = (17160, 4860) if name != sarc_name else (760, 219)
    assert (len(rows), len(blobs)) == expected, (name, len(rows), len(blobs))
    print(f'{name}: 完整解压和递归抽取通过，{len(rows)} 记录，{len(blobs)} 去重键')

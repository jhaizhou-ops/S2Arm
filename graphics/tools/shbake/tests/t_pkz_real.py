#!/usr/bin/env python3
# 门禁手动：要私有游戏数据：异界锁链 v1.0.1 解包根 + nxsh_extract 输出（用法见文件头），手动回归
"""异界锁链 v1.0.1 私有样本回归；只核对本地文件，不包含游戏数据。

用法：t_pkz_real.py <解包根，含 RomFS / ExeFS> <nxsh_extract 输出>
期望来自已合入的 #237 静态普查；不同版本不得改期望值来绕过失败。
"""

import collections
import hashlib
import json
from pathlib import Path
import sys


def sha(data):
    return hashlib.sha256(data).hexdigest()


if len(sys.argv) != 3:
    raise SystemExit(__doc__)
game, extract = map(Path, sys.argv[1:])
assert sha((game / 'RomFS/root.pkz').read_bytes()) == '9cf92ea0948ac5afc4226605d3189c1383546dfcf19cdc9603749c82ff7078a7'
expected_exefs = {
    'main': 'dc47cae835866379c597e1c507bf52ee0f865ec4412930dfdf1bbc20b6bb9c3b',
    'sdk': 'd58f76a49d32c1a8192befc8cd6341e45d802eade3a474f7117a842232446d7e',
    'rtld': '52735462296339700ae8c54b3d84f8fd0d96113a313a15a4e0a6973ec63dffb4',
}
for name, expected in expected_exefs.items():
    assert sha((game / 'ExeFS' / name).read_bytes()) == expected, name
rows = [line.split('\t') for line in (extract / 'rows.tsv').read_text().splitlines()
        if line and not line.startswith('#')]
index = [line.split('\t') for line in (extract / 'index.tsv').read_text().splitlines()
         if line and not line.startswith('#')]
assert len(rows) == 1521, len(rows)
assert len(index) == 1348, len(index)
stages = dict(collections.Counter(row[1] for row in index))
assert stages == {'vs': 540, 'ps': 738, 'cs': 70}, stages
sys.path.insert(0, str(Path(__file__).resolve().parents[1])); import srcpack   # 着色器字节在 src/*.pk
identities = set(); S = srcpack.Src(str(extract))
for key, stage, source, variant in index:
    code, ctl = S.get(key)
    assert sha(ctl + code)[:16] == key, key
    identities.add(sha(stage.encode() + b'\0' + ctl + code))
digest = sha(('\n'.join(sorted(identities)) + '\n').encode())
assert digest == 'bc752b2d04036ffe666ac9f9ff9b47e9fa0f262bfa5a5397f1a9d1569495f66d', digest
print(json.dumps({'records': len(rows), 'unique': len(index), 'stages': stages,
                  'survey_identity_set_sha256': digest, 'matches_survey': True}, indent=2))

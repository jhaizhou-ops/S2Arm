#!/usr/bin/env bash
# C2：C 控制段 parser 与上游 merge_extract.cs_facts 逐字节对拍（同一批合成控制段）。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-control.XXXXXX")
trap 'rm -rf "$out"' EXIT
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -I"$repo" -I"$repo/runtime/include" \
    -o "$out/dump" "$repo/android/tests/direct_control_dump.c" "$repo/android/native/direct/control.c"
python3 - "$repo" "$out" <<'PY'
import importlib.util, os, random, struct, subprocess, sys
repo, out = sys.argv[1], sys.argv[2]
path = os.path.join(repo, 'graphics/tools/direct/merge_extract.py')
spec = importlib.util.spec_from_file_location('merge_extract', path)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
random.seed(20261025)
cases = []
# 边界 + 随机；每份都从同一输入各算一次。
for length in (0, 0x757, 0x758, 0x800):
    for _ in range(12):
        data = bytearray(random.randrange(256) for _ in range(length))
        if length >= 0x758:
            x, y, z = (random.choice([0, 1, 2, 4, 8, 32, 64]), random.choice([0, 1, 2, 4, 8, 16]), random.choice([0, 1, 2, 4, 8, 16]))
            shared = random.choice([0, 1, 15, 16, 17, 0x10000, 0x10001, 0xFFFF])
            struct.pack_into('<3I', data, 0x748, x, y, z)
            struct.pack_into('<I', data, 0x754, shared)
        cases.append(bytes(data))
for data in (b'', b'\0' * 0x758, b'\0' * 0x757):
    cases.append(data)
bad = 0
for index, data in enumerate(cases):
    path = os.path.join(out, f'ctl-{index}.bin')
    open(path, 'wb').write(data)
    got = subprocess.run([os.path.join(out, 'dump'), path], capture_output=True, text=True, check=True).stdout.strip()
    facts = module.cs_facts(data)
    want = 'error 1' if facts is None else 'ok %d %d %d %d' % (*facts['local'], facts['shared'])
    # C 侧对 <0x758 返回 SHORT(-2)；Python 统一 None，语义相同，比较归一化。
    if facts is None and got.startswith('error '):
        continue
    if got != want:
        print(f'MISMATCH case {index} ({len(data)} bytes): C={got!r} python={want!r}', file=sys.stderr)
        bad += 1
print(f'direct control parser vs merge_extract.cs_facts: {len(cases)} cases, {bad} mismatches')
sys.exit(1 if bad else 0)
PY

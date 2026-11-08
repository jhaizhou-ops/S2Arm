#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Direct assertions on the production AST optimizer; no GPU or game data.
# 门禁只看：tests/ast_memory_propagation/* tests/ast_memory_propagation_test.sh compat/tree/src/Ryujinx.Graphics.Shader/StructuredIr/AstOptimizer.cs tests/shader_cases/*
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
# Resolve the repository's pinned SDK, not whichever SDK the caller's cwd selects.
cd "$ROOT/compat/tree"
dotnet build "$ROOT/tests/ast_memory_propagation/AstMemoryPropagation.csproj" -c Release \
  --artifacts-path "$OUT/dotnet" -o "$OUT/tool" \
  -p:UseSharedCompilation=false -m:1 -v minimal
dotnet "$OUT/tool/dsh_cmp.dll"
# #1429 验收计数（AstMemoryOrderStats，直连出库汇总行「ast mem order kept」读它）：真 Maxwell 二进制（tests/shader_cases 全部用例，用它的 run.py 编码）
#   过生产翻译器。期望不跑被测实现得来：#1414 实测 75 份既有用例中 SPIR-V 变化 27 份（都是 storage 读跨写），另加两例（读后写回、不同地址写）都该被保留；
#   其余 48 份旧形状计数 0
python3 -B - "$ROOT/tests/shader_cases" "$OUT/cases" <<'PY'
import json, sys, pathlib
here, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]); sys.path.insert(0, str(here)); out.mkdir()
from run import binary
m = []
for i, p in enumerate(sorted(here.glob('*/*.json'))):
    if p.parent.name in ('obj', 'bin'): continue
    c = json.loads(p.read_text()); b = out / f'{i}.bin'; b.write_bytes(binary(c)); m.append({'id': c['id'], 'stage': c['stage'], 'binary': str(b)})
(out / 'manifest.json').write_text(json.dumps(m))
PY
dotnet "$OUT/tool/dsh_cmp.dll" --maxwell "$OUT/cases/manifest.json" > "$OUT/kept.tsv"
python3 -B - "$OUT/kept.tsv" <<'PY'
import sys
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1])]
kept = {i: int(n) for i, n in rows}
new = ('integer/zz_load_store_order_known_red', 'integer/zz_load_store_order_different_address')
old = {i: n for i, n in kept.items() if i not in new}
hit = sorted(i for i, n in old.items() if n > 0)
bad = [f'{i} kept {kept.get(i)}' for i in new if not kept.get(i)]
print(f'memory-order kept: cases {len(kept)}, new shapes {[kept.get(i) for i in new]}, old cases with kept>0 {len(hit)}/{len(old)}, old cases kept 0 {len(old) - len(hit)}')
if len(kept) != 77: bad.append(f'expected 77 cases, got {len(kept)}')
if len(hit) != 27: bad.append(f'expected 27 of 75 old cases changed by #1414, counter hit {len(hit)}: {hit}')
if bad: sys.exit('FAIL ' + '; '.join(bad))
print('PASS memory-order counter')
PY

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#1106: hand-calculated slots for the one reflection implementation, S2A.Dsh DshCompiler.Reflect / Unfillable
(graphics/tools/direct/dsh/Dsh.cs), called through dsh_cmp --fn. Usage: t_stage_ssbo.py <dsh_cmp.dll>"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cases, expected = [], []
# Maxwell graphics stages 1..5 have 0x100 steps; compute has its own 0x310 table.
# NVN2 task / mesh (11-05): 0x670 / 0x770, not the 0x100 step (upstream (MIT) 5ae0d9aea / #1186: Mario Kart World's task shaders read c0 0x670 / 0x680, its mesh shaders
# 0x770..0x7b0, the game binds from slot 0; Ocarina of Time's 11 task / 458 mesh shaders read 0x670.. / 0x770.. as well)
STAGES = [("vs", 0x110), ("hs", 0x210), ("ds", 0x310), ("gs", 0x410), ("ps", 0x510), ("cs", 0x310), ("ts", 0x670), ("ms", 0x770)]
for stage, base in STAGES:
    msl = f"struct spvDescriptorSetBuffer0 {{\n const device uint* {stage[0]}p_s0 [[id(5)]];\n}};"
    for label, bank, offset, slot in [("first", 0, base, 0), ("last", 0, base + 0xf0, 15),
                                     ("before", 0, base - 4, None), ("misaligned", 0, base + 4, None),
                                     ("past", 0, base + 0x100, None), ("bank1", 1, base, None), ("bank2", 2, base, None)]:
        args = [stage, msl, {"sbufs": [{"binding": 40, "cb_slot": bank, "cb_offset": offset // 4, "flags": 0}]}]
        cases.append(dict(fn="reflect", args=args, label=stage + ":" + label))
        expected.append(("reg", slot))
    for label, offset, allowed in [("driver-first", base, True), ("driver-last", base + 0xf0, True),
                                   ("driver-outside", 0x610, False)]:
        cases.append(dict(fn="unfillable", args=[{"0": {"vec4_offsets": [offset], "dynamic": False}}, stage], label=stage + ":" + label))
        expected.append(("allowed", allowed))
# Unknown stages must stay unresolved; compute's uniform-pointer exception stays intact.
cases.extend([
    dict(fn="reflect", args=["unknown", "struct spvDescriptorSetBuffer0 {\n device uint* zp_s0 [[id(0)]];\n};",
                              {"sbufs": [{"binding": 1, "cb_slot": 0, "cb_offset": 260, "flags": 0}]}], label="unknown"),
    dict(fn="reflect", args=["cs", "struct spvDescriptorSetBuffer0 {\n device uint* cp_s0 [[id(0)]];\n};",
                              {"sbufs": [{"binding": 1, "cb_slot": 0, "cb_offset": 0x84, "flags": 0}]}], label="compute-ubo"),
])
expected.extend([("reg", None), ("kind", "ubo_ptr")])
# A task / mesh table is fillable only for its own stage: the mesh table's first row read by a pixel shader stays unfillable
cases.append(dict(fn="unfillable", args=[{"0": {"vec4_offsets": [0x770], "dynamic": False}}, "ps"], label="ps:mesh-table"))
expected.append(("allowed", False))

def valid(value, oracle):
    field, want = oracle
    return (not value) == want if field == "allowed" else len(value) == 1 and value[0].get(field) == want

failures = 0
with tempfile.TemporaryDirectory(prefix="t_stage_ssbo_") as tmp:
    src, out = Path(tmp) / "cases.json", Path(tmp) / "results.json"
    src.write_text(json.dumps(cases))
    subprocess.run([os.environ.get("DOTNET", "dotnet"), sys.argv[1], "--fn", str(src), str(out)], check=True)
    results = json.loads(out.read_text())
    if len(results) != len(cases):
        raise SystemExit("FAIL runtime: result count mismatch")
    for case, oracle, got in zip(cases, expected, results):
        if "ok" not in got or not valid(got["ok"], oracle):
            failures += 1
            print("FAIL runtime", case["label"], oracle, got)
print(f"{'✗' if failures else '✓'} stage_ssbo：C# 反射 {len(cases)} 例，{failures} 项不符（八阶段首末槽含任务 / 网格、拒绝边界、驱动范围、计算统一缓冲）")
raise SystemExit(bool(failures))

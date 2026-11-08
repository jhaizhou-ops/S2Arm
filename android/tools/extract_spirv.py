#!/usr/bin/env python3
"""从 direct compiler program.json 提取某阶段 SPIR-V 字节。"""
import base64
import json
import sys

if len(sys.argv) != 4:
    sys.exit("usage: extract_spirv.py <program.json> <stage> <out.spv>")
document = json.load(open(sys.argv[1], encoding="utf-8"))
for stage in document["content"]["stages"]:
    if stage["stage"] == sys.argv[2]:
        open(sys.argv[3], "wb").write(base64.b64decode(stage["spirv"]))
        sys.exit(0)
sys.exit("stage not found")

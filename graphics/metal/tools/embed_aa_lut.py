#!/usr/bin/env python3
"""Embed the bundled SMAA reference lookup textures, without runtime file IO."""
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:3])
with output.open("w", encoding="utf-8") as out:
    out.write("// Generated from the bundled SMAA lookup textures. Do not edit.\n")
    for name, filename, size in (
        ("area", "SmaaAreaTexture.bin", 160 * 560 * 2),
        ("search", "SmaaSearchTexture.bin", 64 * 16),
    ):
        data = (source / filename).read_bytes()
        if len(data) != size:
            raise ValueError(f"{filename}: expected {size} bytes, got {len(data)}")
        out.write(f"static const unsigned char k_aa_{name}[] = {{\n")
        for offset in range(0, len(data), 32):
            out.write(",".join(str(value) for value in data[offset:offset + 32]) + ",\n")
        out.write("};\n")

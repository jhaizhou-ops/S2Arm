#!/usr/bin/env python3
"""Compile the two real NVN record headers and report barriers to backend reuse.

This is a host ABI comparison, not an Android GPU or game compatibility test.
No game files, shader bytecode or answer tables are read.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import struct
import subprocess
import tempfile


TYPES = (
    "queue_builder_t", "pool_t", "dpool_t", "tex_t", "view_t", "samp_par",
    "prog_t", "cmd_t", "op_hdr", "p_set_rt", "p_bind_program",
    "p_bind_handles", "p_draw", "p_draw_idx", "p_dispatch", "p_copy_b2t",
)
FIELDS = {
    "queue_builder_t": ("cmd_sz", "mem", "mem_sz"),
    "tex_t": ("d", "L", "mem", "pool", "off", "serial"),
    "prog_t": ("sd", "serial"),
    "cmd_t": ("cur", "end", "begin"),
    "p_set_rt": ("color", "cview", "depth", "dview"),
    "p_bind_program": ("prog", "stages"),
    "p_bind_handles": ("stage", "first", "n", "h"),
    "p_copy_b2t": ("src", "tex", "r", "flags"),
}


def run(command):
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(f"command failed: {shlex.join(command)}\n{result.stderr}")
    return result.stdout


def inspect(root, nvn, compiler, directory, name):
    header = nvn / "nvn_obj.h"
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", header.read_text(), flags=re.S)
    enum = next((body for body in re.findall(r"enum\s*\{([^}]+)\}", text)
                 if re.search(r"\bOP_END\b", body)), None)
    if enum is None:
        raise ValueError(f"no NVN opcode enum in {header}")
    names = re.findall(r"\bOP_\w+\b", enum)
    if len(names) != len(set(names)):
        raise ValueError("opcode expressions require a reviewed probe update")
    lines = ['#include <stddef.h>', '#include <stdio.h>',
             '#include "nvn_obj.h"', 'int main(void) {',
             '_Static_assert(sizeof(void *) == 8, "LP64 host required");',
             '_Static_assert(sizeof(long) == 8, "LP64 host required");']
    for opcode in names:
        lines.append(f'printf("op.{opcode}=%u\\n", (unsigned){opcode});')
    for kind in TYPES:
        lines.append(f'printf("size.{kind}=%zu\\n", sizeof({kind}));')
    for kind, fields in FIELDS.items():
        for field in fields:
            lines.append(f'printf("offset.{kind}.{field}=%zu\\n", offsetof({kind}, {field}));')
    lines.append('return 0; }')
    source, executable = directory / f"{name}.c", directory / name
    source.write_text("\n".join(lines) + "\n")
    run([*compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
         "-I" + str(nvn), "-I" + str(nvn / "include"),
         str(source), "-o", str(executable)])
    values = {}
    for line in run([str(executable)]).splitlines():
        key, value = line.split("=", 1)
        values[key] = int(value)
    fingerprints = {}
    for file in (header, nvn / "nvn_tex.h", nvn / "include/nvn.h"):
        fingerprints[str(file.relative_to(root))] = hashlib.sha256(file.read_bytes()).hexdigest()
    return {"commit": run(["git", "-C", str(root), "rev-parse", "HEAD"]).strip(),
            "headers_sha256": fingerprints, "values": values}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--d2r-root", type=Path, required=True)
    parser.add_argument("--s2arm-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--cc", default="cc", help="host C compiler and optional flags")
    parser.add_argument("--output", type=Path, help="optional source-only JSON report")
    args = parser.parse_args()
    if struct.calcsize("P") != 8:
        parser.error("this probe requires a 64-bit host")
    s2arm, d2r = args.s2arm_root.resolve(), args.d2r_root.resolve()
    with tempfile.TemporaryDirectory(prefix="s2arm-nvn-abi-") as temporary:
        directory = Path(temporary)
        left = inspect(s2arm, s2arm / "graphics/nvn/gfx/nvn", shlex.split(args.cc), directory, "s2arm")
        right = inspect(d2r, d2r / "dm/gfx/nvn", shlex.split(args.cc), directory, "d2r")
    a, b = left["values"], right["values"]
    changed = [{"field": key, "s2arm": a[key], "d2r": b[key]}
               for key in sorted(a.keys() & b.keys()) if a[key] != b[key]]
    only_a, only_b = sorted(a.keys() - b.keys()), sorted(b.keys() - a.keys())
    report = {
        "schema": 1, "scope": "host LP64 header probe; no GPU or game execution",
        "sampled_values_match": not (changed or only_a or only_b),
        "semantic_compatibility": "not_validated",
        "s2arm": left, "d2r": right, "changed": changed,
        "only_s2arm": only_a, "only_d2r": only_b,
        "limitation": "Equal samples do not prove semantic or Android ABI compatibility; numeric opcodes and C object bytes must not be forwarded across these formats.",
    }
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(output)
        print(f"host ABI probe complete: {len(changed)} changed, "
              f"{len(only_a)} S2Arm-only, {len(only_b)} D2R-only; "
              f"sampled_values_match={report['sampled_values_match']}; semantic compatibility not validated")
    else:
        print(output, end="")


if __name__ == "__main__":
    main()

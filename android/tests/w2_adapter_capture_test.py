#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Six original host capture boundaries using verbatim adapter registry code.

Extract the two generation declarations, the complete registry declarations and
helpers through s2a_vk_adapter_reg_tex, and s2a_vk_adapter_w2_capture_registered
from mtl_vk_adapter.c. Markers must be unique and each required function complete;
source drift fails rather than silently compiling a smaller test. Registry
allocation, lookup, copying and pthread locking remain production operations.

This is a narrow source-body test, not a full adapter translation-unit link or
lock-concurrency test. It uses original scalar inputs and the repository's vkhost
and hostvk headers, with only Android logging stubbed. No device, Vulkan calls,
game input, live descriptor-pool proof, NDK or online downloads are involved.
"""

import argparse
import hashlib
import os
import shlex
import subprocess
import tempfile
from pathlib import Path

from w2_request_worker_test import function_body

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "android/native"
HERE = Path(__file__).resolve().parent


def source_bodies(text):
    declarations = []
    for declaration in (
        "static _Atomic uint64_t g_registry_generation;",
        "static _Atomic uint64_t g_regen_bumps;",
    ):
        if text.count(declaration) != 1:
            raise RuntimeError("source extraction declaration changed: " + declaration)
        declarations.append(declaration)
    start = "#define NVK_TEXREG "
    stop = "\nvoid s2a_vk_adapter_reg_samp("
    if text.count(start) != 1 or text.count(stop) != 1:
        raise RuntimeError("source extraction registry markers changed")
    begin, end = text.index(start), text.index(stop)
    if end <= begin:
        raise RuntimeError("source extraction registry markers are out of order")
    registry = text[begin:end]
    for signature in (
        "static int reg_grow_locked(",
        "static int reg_init_locked(",
        "void s2a_vk_adapter_reg_tex(",
    ):
        function_body(registry, signature)
    capture = function_body(text, "int s2a_vk_adapter_w2_capture_registered(")
    return "\n".join(declarations) + "\n" + registry + "\n" + capture


def run(directory):
    extracted = source_bodies((NATIVE / "nvn/mtl_vk_adapter.c").read_text())
    (directory / "w2_adapter_capture_bodies.inc").write_text(extracted)
    print("actual adapter registry SHA256", hashlib.sha256(extracted.encode()).hexdigest(), flush=True)
    includes = (
        directory, NATIVE, NATIVE / "direct", NATIVE / "nvn",
        HERE / "vkhost", HERE / "hostvk", ROOT / "runtime/include",
        ROOT / "graphics/nvn/gfx/tex", ROOT / "graphics/nvn/gfx/nvn",
        ROOT / "graphics/nvn/gfx/nvn/include", ROOT / "graphics/nvn/third_party/vulkan-headers/include",
    )
    cc = shlex.split(os.environ.get("CC", "cc"))
    flags = shlex.split(os.environ.get("CFLAGS", ""))
    binary = directory / "adapter-capture"
    command = cc + ["-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread"] + flags
    command += ["-I" + str(path) for path in includes]
    command += [str(HERE / "w2_adapter_capture_test.c"), "-o", str(binary)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=45)
    (directory / "build.log").write_text(shlex.join(command) + "\n" + result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("adapter capture build failed\n" + result.stderr)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
    output = result.stdout + result.stderr
    (directory / "run.log").write_text("exit=" + str(result.returncode) + "\n" + output)
    print(output, end="", flush=True)
    if result.returncode or "PASS actual adapter " not in result.stdout:
        raise RuntimeError("adapter capture assertions failed")
    print("PASS: 6/6 adapter capture boundaries; no full-TU/concurrency/GPU/device claim", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-output", type=Path, help="new directory for extracted source and evidence")
    args = parser.parse_args()
    if args.keep_output:
        directory = args.keep_output.resolve()
        directory.mkdir(parents=True, exist_ok=False)
        run(directory)
    else:
        with tempfile.TemporaryDirectory(prefix="w2-adapter-capture-") as temporary:
            run(Path(temporary))


if __name__ == "__main__":
    main()

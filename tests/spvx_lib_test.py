#!/usr/bin/env python3
"""Byte-exact check of nxgal_spv_harden (graphics/metal/gal_spvx.c) through ctypes; see tests/spvx_lib_test.sh."""
import ctypes
import os
from pathlib import Path
import sys


def words(path):
    return [int(x, 16) for x in path.read_text().split()]


def harden(lib, spv):
    """New SPIR-V words, or None when nxgal_spv_harden leaves the module alone (returns NULL)."""
    src, onw = (ctypes.c_uint32 * len(spv))(*spv), ctypes.c_uint32(0)
    p = lib.nxgal_spv_harden(src, len(spv), ctypes.byref(onw))
    if not p:
        return None
    out = list(ctypes.cast(p, ctypes.POINTER(ctypes.c_uint32))[:onw.value])
    lib.nxgal_spv_free(p)
    return out


def main():
    os.environ.pop("NXGAL_BOUNDS_COUNT", None)   # 计数关（缺省、出包口径）；计数开会多插收尾，金样不含
    lib = ctypes.CDLL(sys.argv[1])
    if not hasattr(lib, "nxgal_spv_harden"):
        print(f"✗ SPIR-V 加固：{sys.argv[1]} 没有导出 nxgal_spv_harden")
        return 1
    lib.nxgal_spv_harden.argtypes = [ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
    lib.nxgal_spv_harden.restype = ctypes.c_void_p
    lib.nxgal_spv_free.argtypes = [ctypes.c_void_p]
    cases = sorted(Path(sys.argv[2]).glob("*.spv.hex"))
    bad, kinds = [], {"hardened": 0, "unchanged": 0}
    for case in cases:
        spv, want_text = words(case), case.with_name(case.name[:-len(".spv.hex")] + ".expected.hex").read_text()
        want = None if want_text.strip() == "unchanged" else words(case.with_name(case.name[:-len(".spv.hex")] + ".expected.hex"))
        got = harden(lib, spv)
        if got != want:
            bad.append(case.name)
        kinds["unchanged" if want is None else "hardened"] += 1
        if want is not None:
            if want == spv:
                raise AssertionError("expectation equals the input, so it proves nothing: " + case.name)
            flipped = list(want)
            flipped[len(flipped) // 2] ^= 1
            if flipped == got:
                raise AssertionError("negative control failed: a one-word-corrupted expectation still matched " + case.name)
    ok = not bad and len(cases) == 5
    print(("✓" if ok else "✗") + f" SPIR-V 加固：期望 5 支 SPIR-V 与金样逐字节相同（加固 4 / 原样 1）、一字错的金样被拒 → 真结果 "
          f"{len(cases) - len(bad)}/{len(cases)} 相同（加固 {kinds['hardened']} / 原样 {kinds['unchanged']}）"
          + (f"，不同：{', '.join(bad)}" if bad else ""))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Byte-exact check of nxgal_dmsh_color_round (graphics/metal/gal_colorround.c) through ctypes; see tests/colorround_lib_test.sh."""
import ctypes
from pathlib import Path
import sys


def run(lib, msl):
    out, err = ctypes.c_void_p(), ctypes.create_string_buffer(512)
    if lib.nxgal_dmsh_color_round(msl, b"main0", ctypes.byref(out), err, 512) == 0:
        text = ctypes.string_at(out.value)
        lib.nxgal_dmsh_xc_free(out)
        return text
    return b"ERROR: " + err.value + b"\n"


def main():
    lib = ctypes.CDLL(sys.argv[1])
    lib.nxgal_dmsh_color_round.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_char_p, ctypes.c_uint64]
    lib.nxgal_dmsh_color_round.restype = ctypes.c_int32
    lib.nxgal_dmsh_xc_free.argtypes = [ctypes.c_void_p]
    cases = sorted(Path(sys.argv[2]).glob("*.msl"))
    bad = []
    kinds = {"rewritten": 0, "unchanged": 0, "error": 0}
    for msl in cases:
        want, got = msl.with_suffix(".expected").read_bytes(), run(lib, msl.read_bytes())
        if got != want:
            bad.append(msl.name)
        kinds["error" if want.startswith(b"ERROR: ") else "unchanged" if want == msl.read_bytes() else "rewritten"] += 1
        flipped = bytes([want[0] ^ 1]) + want[1:]
        if flipped == got:
            raise AssertionError("negative control failed: a one-byte-corrupted expectation still matched " + msl.name)
    ok = not bad and len(cases) == 7
    print(("✓" if ok else "✗") + f" 颜色出口改写：期望 7 段 MSL 与金样逐字节相同（改写 3 / 原样 1 / 报错 3）、一字节错的金样被拒 → 真结果 "
          f"{len(cases) - len(bad)}/{len(cases)} 相同（改写 {kinds['rewritten']} / 原样 {kinds['unchanged']} / 报错 {kinds['error']}）"
          + (f"，不同：{', '.join(bad)}" if bad else ""))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

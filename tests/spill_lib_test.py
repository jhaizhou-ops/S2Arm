#!/usr/bin/env python3
"""Byte-exact check of nxgal_dmsh_spill (graphics/metal/gal_spill.c) through ctypes; see tests/spill_lib_test.sh."""
import ctypes
from pathlib import Path
import sys


def run(lib, msl):
    out, nb, err = ctypes.c_void_p(), ctypes.c_uint32(), ctypes.create_string_buffer(256)
    rc = lib.nxgal_dmsh_spill(msl, 27, ctypes.byref(out), ctypes.byref(nb), err, 256)
    body = b""
    if out.value:
        body = ctypes.string_at(out.value)
        lib.nxgal_dmsh_xc_free(out)
    elif rc < 0:
        body = b"ERROR: " + err.value + b"\n"
    return b"rc=%d bytes=%d\n" % (rc, nb.value) + body


def main():
    lib = ctypes.CDLL(sys.argv[1])
    if not hasattr(lib, "nxgal_dmsh_spill"):
        print(f"✗ 共享内存溢出：{sys.argv[1]} 没有导出 nxgal_dmsh_spill")
        return 1
    lib.nxgal_dmsh_spill.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint32), ctypes.c_char_p, ctypes.c_uint64]
    lib.nxgal_dmsh_spill.restype = ctypes.c_int32
    lib.nxgal_dmsh_xc_free.argtypes = [ctypes.c_void_p]
    cases = sorted(Path(sys.argv[2]).glob("*.msl"))
    bad, kinds = [], {"rewritten": 0, "unchanged": 0, "error": 0}
    for msl in cases:
        want, got = msl.with_suffix(".expected").read_bytes(), run(lib, msl.read_bytes())
        if got != want:
            bad.append(msl.name)
        kinds["rewritten" if want.startswith(b"rc=1 ") else "unchanged" if want.startswith(b"rc=0 ") else "error"] += 1
        flipped = want[:-2] + bytes([want[-2] ^ 1]) + want[-1:]
        if flipped == got:
            raise AssertionError("negative control failed: a one-byte-corrupted expectation still matched " + msl.name)
    ok = not bad and len(cases) == 6
    print(("✓" if ok else "✗") + f" 共享内存溢出：期望 6 段 MSL 与金样逐字节相同（改写 3 / 原样 2 / 报错 1）、一字节错的金样被拒 → 真结果 "
          f"{len(cases) - len(bad)}/{len(cases)} 相同（改写 {kinds['rewritten']} / 原样 {kinds['unchanged']} / 报错 {kinds['error']}）"
          + (f"，不同：{', '.join(bad)}" if bad else ""))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

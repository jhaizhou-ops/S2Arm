#!/usr/bin/env python3
"""Exercise dsh_vklib's actual process status with synthetic shader records."""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile


def record(code, ctl):
    header = bytearray(0x38)
    header[:8] = b"BTCDBTCD"
    struct.pack_into("<II", header, 0x28, len(ctl), len(code))
    return header + code + ctl


def fixtures(root):
    pkg = root / "pkg"
    pkg.mkdir()
    exit_op = 0xe30000000007000f
    def ldc(rd, slot, off, size):
        return 0xef90000000000000 | (size << 48) | (slot << 36) | (off << 20) | (7 << 16) | (255 << 8) | rd
    def stg(rs, ra, off):
        return 0xeedc200000000000 | (off << 20) | (7 << 16) | (ra << 8) | rs
    ops = [ldc(0, 0, 0x110, 5), ldc(2, 3, 0, 4), stg(2, 0, 0), exit_op]
    count = (len(ops) + 2) // 3 * 3
    valid = bytearray(0x80 + count // 3 * 32)
    struct.pack_into("<I", valid, 0x30, 1 | (3 << 5) | (1 << 10) | (1 << 16) | (1 << 26))
    for i in range(count):
        struct.pack_into("<Q", valid, 0x80 + (i // 3 * 4 + i % 3 + 1) * 8, ops[i] if i < len(ops) else exit_op)
    rows = []
    for mark, code in ((1, valid), (2, bytes(8))):
        ctl = bytearray(0x880)
        ctl[0x10] = mark
        key = hashlib.sha256(ctl).hexdigest()[:16]
        name = f"vs_{mark}.bin"
        (pkg / name).write_bytes(record(code, ctl))
        rows.append(f"{name}\t0\t-\t{key}\t-\n")
    ctl = bytearray(0x880)
    ctl[0x10] = 3
    key = hashlib.sha256(ctl).hexdigest()[:16]
    (pkg / "gs_0.bin").write_bytes(record(valid, ctl))
    skipped = f"gs_0.bin\t0\t-\t{key}\t-\n"
    for name, subset in (("ok", rows[:1]), ("bad", rows[1:]), ("mixed", rows),
                         ("ok-skipped", rows[:1] + [skipped])):
        profile = root / name
        profile.mkdir()
        (profile / "shader_map.tsv").write_text("".join(subset))
        for table in ("shader_facts.tsv", "shader_pairs.tsv"):
            (profile / table).write_text("")
    return pkg


def main():
    parser = argparse.ArgumentParser()
    for name in ("dotnet", "dll", "nxgal", "spirv-cross"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    failures = []
    with tempfile.TemporaryDirectory(prefix="vklib-exit-") as temp:
        root = Path(temp)
        pkg = fixtures(root)
        for mode in ("ok", "bad", "mixed", "ok-skipped"):
            for pack in (False, True):
                label = mode + ("-pack" if pack else "-no-pack")
                out = root / ("out-" + label)
                lib = root / ("lib-" + label)
                command = [args.dotnet, args.dll, "--pkg", str(pkg), "--profile", str(root / mode),
                           "--out", str(out), "--spirv-cross", args.spirv_cross,
                           "--nxgal", args.nxgal, "--work", str(root / ("work-" + label))]
                if pack:
                    command += ["--lib", str(lib), "--chain", "0123456789ab"]
                run = subprocess.run(command, capture_output=True, text=True, timeout=30)
                table = out / "vk_build.tsv"
                rows = table.read_text().splitlines() if table.is_file() else []
                failed = sum("\tfailed\t" in row for row in rows)
                ok = sum("\tok\t" in row for row in rows)
                skipped = sum("\tskipped\t" in row for row in rows)
                expected_ok = 0 if mode == "bad" else 1
                expected_failed = int(mode in ("bad", "mixed"))
                passed = (ok == expected_ok and failed == expected_failed and skipped == int(mode == "ok-skipped") and
                          (run.returncode != 0 if expected_failed else run.returncode == 0) and
                          (not expected_failed or "[RED]" in run.stderr) and
                          (not pack or expected_failed or (lib / "lib.idx").is_file()) and
                          (not pack or not expected_failed or not (lib / "lib.idx").exists()))
                print(f"{'PASS' if passed else 'FAIL'} {label}: rc={run.returncode} ok={ok} failed={failed} "
                      f"stdout={run.stdout.strip()!r} stderr={run.stderr.strip()!r}")
                if not passed:
                    failures.append(label)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())

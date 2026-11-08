# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Offline exploratory signing probe; original fixtures, no credentials/devices.

This is not the maintainer's W5 acceptance package. It does not establish Apple
trust, provisioning, installability, or real-game performance. Run with explicit
paths to already acquired tools and a new output directory outside this tree.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import time


IML = "com.apple.developer.kernel.increased-memory-limit"


def macho(dylib: bool = False) -> bytes:
    """Original ARM64 fixture: one RET, header slack, and empty linkedit data.

    Constants/layout follow Apple mach-o/loader.h. No SDK or third-party binary
    is copied. This deliberately small file is for signer structure inspection.
    """
    base, text_size, code_offset = 0x100000000, 0x4000, 0x1000
    text = struct.pack("<II16sQQQQiiII", 0x19, 152, b"__TEXT", base,
                       text_size, 0, text_size, 5, 5, 1, 0)
    section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT",
                          base + code_offset, 4, code_offset, 2, 0, 0,
                          0x80000400, 0, 0, 0)
    linkedit = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT",
                           base + text_size, text_size, text_size, 16,
                           1, 1, 0, 0)
    symtab = struct.pack("<IIIIII", 2, 24, text_size, 0, text_size, 1)
    build = struct.pack("<IIIIII", 0x32, 24, 2, 15 << 16, 18 << 16, 0)
    commands = [text + section, linkedit, symtab, build]
    if dylib:
        name = b"@rpath/Probe.dylib\0"
        size = (24 + len(name) + 7) & ~7
        commands.append(struct.pack("<IIIIII", 0xD, size, 24, 0, 0x10000,
                                    0x10000) + name.ljust(size - 24, b"\0"))
    else:
        commands.append(struct.pack("<IIQQ", 0x80000028, 24, code_offset, 0))
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0,
                         6 if dylib else 2, len(commands),
                         sum(map(len, commands)), 0x200085, 0)
    result = bytearray(text_size + 16)
    result[:len(header)] = header
    result[len(header):len(header) + sum(map(len, commands))] = b"".join(commands)
    result[code_offset:code_offset + 4] = bytes.fromhex("c0035fd6")
    return bytes(result)


def run(args: list[str], cwd: Path, log: Path) -> dict:
    started = time.perf_counter()
    process = subprocess.run(args, cwd=cwd, capture_output=True, timeout=120)
    log.write_text(process.stdout.decode("utf-8", errors="replace")
                   + "\nSTDERR:\n"
                   + process.stderr.decode("utf-8", errors="replace"),
                   encoding="utf-8", newline="\n")
    return {"command": args, "exit_code": process.returncode,
            "seconds": round(time.perf_counter() - started, 6),
            "log": log.name}


def code_pages(path: Path) -> dict:
    """Check SHA-256 CodeDirectory code slots on our thin LE64 fixture only.

    Does NOT verify CMS, Apple trust, resource/special slots, or provisioning.
    This independent page calculation avoids treating rcodesign verify's
    nonzero result for an ordinary ad-hoc signature as a tamper detection test.
    """
    data = path.read_bytes()
    magic, _, _, _, count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or count > 64 or 32 + command_bytes > len(data):
        raise ValueError("not the supported original thin fixture")
    cursor, signature = 32, None
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or cursor + size > 32 + command_bytes:
            raise ValueError("invalid load command")
        if command == 0x1D:
            signature = struct.unpack_from("<II", data, cursor + 8)
        cursor += size
    if signature is None:
        raise ValueError("signature missing")
    offset, size = signature
    if offset + size > len(data):
        raise ValueError("signature outside fixture")
    magic, length, count = struct.unpack_from(">III", data, offset)
    if magic != 0xFADE0CC0 or length > size or count > 64:
        raise ValueError("invalid superblob")
    for index in range(count):
        slot, relative = struct.unpack_from(">II", data, offset + 12 + index * 8)
        if slot != 0:
            continue
        start = offset + relative
        fields = struct.unpack_from(">9I4B", data, start)
        (magic, cd_length, version, flags, hash_offset, _, special_count,
         code_count, limit, hash_size, hash_type, _, page_power) = fields
        if (magic != 0xFADE0C02 or hash_type != 2 or hash_size != 32
                or page_power > 20 or limit > offset
                or relative + cd_length > length
                or hash_offset + code_count * hash_size > cd_length):
            raise ValueError("unsupported CodeDirectory")
        page_size = 1 << page_power
        if code_count != (limit + page_size - 1) // page_size:
            raise ValueError("code slot count mismatch")
        mismatches = []
        for i in range(code_count):
            actual = hashlib.sha256(data[i * page_size:min((i + 1) * page_size, limit)]).digest()
            begin = start + hash_offset + i * hash_size
            if actual != data[begin:begin + hash_size]:
                mismatches.append(i)
        return {"version": hex(version), "flags": flags,
                "code_slots": code_count, "special_slots_not_verified": special_count,
                "mismatched_code_slots": mismatches,
                "scope": "thin fixture code pages only; no CMS/trust/resource verification"}
    raise ValueError("CodeDirectory slot missing")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zsign", type=Path, required=True)
    parser.add_argument("--rcodesign", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    options = parser.parse_args()
    tools = {name: getattr(options, name).resolve(strict=True)
             for name in ("zsign", "rcodesign")}
    out = options.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[2]
    checker = repo / "pack/iml_check.py"
    empty_config = out / "empty.toml"
    empty_config.write_text("", encoding="utf-8", newline="\n")
    entitlements = out / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({IML: True}))
    report = {"scope": "original ad-hoc fixture only; NOT W5 acceptance",
              "tool_files": {name: {"bytes": path.stat().st_size,
                            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                             for name, path in tools.items()}, "cases": []}
    for name, executable in tools.items():
        case = out / name
        app = case / "Probe.app"
        frameworks = app / "Frameworks"
        frameworks.mkdir(parents=True)
        (app / "Probe").write_bytes(macho())
        (frameworks / "Probe.dylib").write_bytes(macho(True))
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Probe", "CFBundleIdentifier": "local.s2arm.w5probe",
            "CFBundleName": "W5 Probe", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "15.0"}))
        (app / "resource.txt").write_text("Original W5 fixture\n", encoding="utf-8",
                                           newline="\n")
        records = []
        check = [sys.executable, "-X", "utf8", str(checker), "check_app", "Probe.app"]
        records.append(run(check, case, case / "unsigned-iml.log"))
        if name == "zsign":
            sign = [str(executable), "-a", "-f", "-e", "../entitlements.plist", "Probe.app"]
        else:
            sign = [str(executable), "--config-file", str(empty_config), "sign",
                    "--timestamp-url", "none", "--entitlements-xml-file",
                    "../entitlements.plist", "Probe.app"]
        records.append(run(sign, case, case / "sign.log"))
        records.append(run(check, case, case / "signed-iml.log"))
        for relative in ("Probe", "Frameworks/Probe.dylib"):
            label = "main" if relative == "Probe" else "dylib"
            target = "Probe.app/" + relative
            rc = [str(tools["rcodesign"]), "--config-file", str(empty_config)]
            records.append(run(rc + ["print-signature-info", target], case,
                               case / (label + "-signature.log")))
            records.append(run(rc + ["verify", target], case,
                               case / (label + "-verify.log")))
        before_resign = code_pages(app / "Probe")
        records.append(run(sign, case, case / "resign.log"))
        records.append(run(check, case, case / "resigned-iml.log"))
        after_resign = code_pages(app / "Probe")
        # Independent negative: change original signed code bytes, then verify.
        binary = app / "Probe"
        data = bytearray(binary.read_bytes())
        data[0x1000] ^= 1
        binary.write_bytes(data)
        records.append(run([str(tools["rcodesign"]), "--config-file", str(empty_config),
                            "verify", "Probe.app/Probe"], case, case / "tampered-verify.log"))
        records.append(run(check, case, case / "tampered-iml.log"))
        report["cases"].append({"tool": name, "records": records,
                                "independent_code_pages": {
                                    "signed": before_resign, "resigned": after_resign,
                                    "tampered": code_pages(binary)},
                                "acceptance": "not performed; maintainer fixture absent"})
    (out / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)
                                      + "\n", encoding="utf-8", newline="\n")
    print(json.dumps({"scope": report["scope"], "cases": [
        {"tool": c["tool"], "exits": {r["log"]: r["exit_code"] for r in c["records"]}}
        for c in report["cases"]]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

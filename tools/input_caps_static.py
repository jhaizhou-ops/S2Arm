#!/usr/bin/env python3
"""Usage: input_caps_static.py <exefs directory> -> one JSON line, exit 0/1.

Only non-sdk NSO undefined imports are evidence of 声明引用 (declared references).
A reference is NOT an actual call, enabled capability or runtime verification.
No match in this finite table is NOT proof of lack of support. ok=false means
unknown/incomplete, not unsupported. Reads inputs only; never runs a module.
NSO loading/decompression and dynamic symbols are owned by nso_syms, not here.
"""
import json
from pathlib import Path
import re
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "graphics/nvn/tools"))
import nso_syms
from direct_profile import validate_symbols

# Public, reverse-engineered SDK names (no proprietary SDK headers copied):
# [N] blob/6c4a81d40d200bbfe65ad0027ab093405367ada6/dm/host/hle_hid.c
# [S] https://github.com/skyline-dev/skyline/blob/2eb226fa9e4ab023dc00cb0db10ad4ec50ac4fa3/include/nn/hid.hpp
# [H] https://switchbrew.org/wiki/HID_services
# Cross-checked against compat/tree/src/Ryujinx.HLE/HOS/Services/Hid/IHidServer.cs.
# Numbers below are HID commands, NOT a claim that an SDK helper is itself IPC.
# Handle enumeration and state reads are client-side/shared-memory operations;
# they intentionally have no identically named IHidServer command.
FUNCTIONS = {
    "styles": (
        "SetSupportedNpadStyleSet",  # [N,S,H] IHidServer 100
        "SetSupportedNpadIdType",  # [N,S,H] IHidServer 102
    ),
    "vibration": (
        "SendVibrationValue",  # [N,H] IHidServer 201
        "SendVibrationValues",  # [N: detail::, H] IHidServer 206
        "InitializeVibrationDevice",  # [N] 203 -> IActiveApplicationDeviceList.ActivateVibrationDevice (0)
        "GetVibrationDeviceHandles",  # [N] client-side handle construction; no same-name command
        "SendVibrationGcErmCommand",  # [H] IHidServer 207
    ),
    "sixaxis": (
        "StartSixAxisSensor",  # [N,S,H] IHidServer 66
        "GetSixAxisSensorHandles",  # [N,S] client-side handles; no same-name command
        "GetSixAxisSensorState",  # [N,S] shared-memory read; no same-name command
        "GetSixAxisSensorStates",  # [N,S] shared-memory read; no same-name command
        "StartConsoleSixAxisSensor",  # [H] IHidServer 301
    ),
}
NOTICE = "仅表示声明引用，不等于实际调用、启用或已验证；未命中不证明不支持"
CATEGORIES = ("styles", "vibration", "sixaxis")
MODULE_NAME = re.compile(r"(?:main|sdk|rtld|subsdk[0-9]+)(?:\.nso)?\Z")
# SDK batch vibration is also published in nn::hid::detail. Do not match text
# in parameter types, other namespaces, or longer names containing a table entry.
FUNCTION_NAME = re.compile(r"_ZN2nn3hid(?:6detail)?([1-9][0-9]*)")
MAX_IMAGE = 1 << 30


def function_name(symbol):
    match = FUNCTION_NAME.match(symbol)
    if not match:
        return None
    end = match.end() + int(match[1])
    if symbol[end:end + 1] != "E" or not symbol[end + 1:]:
        return None
    return symbol[match.end():end]


def check_header(path, header):
    """Bounds guard for the existing loader, not another NSO reader/decoder.

    nso_syms.load assumes valid ranges and Python slice assignment can silently
    accept truncated uncompressed data. Check stored extents before calling it.
    """
    size = path.stat().st_size
    if len(header) != 0x100 or header[:4] != b"NSO0":
        raise ValueError("invalid/truncated NSO0 header")
    if size > MAX_IMAGE:
        raise ValueError("NSO exceeds 1 GiB scan limit")
    flags = struct.unpack_from("<I", header, 0xc)[0]
    end = 0
    for index in range(3):
        offset, address, length = struct.unpack_from("<III", header, 0x10 + 16 * index)
        stored = struct.unpack_from("<I", header, 0x60 + 4 * index)[0]
        if offset < 0x100 or offset + stored > size:
            raise ValueError("truncated/out-of-range NSO segment")
        if address < end or address + length > MAX_IMAGE:
            raise ValueError("overlapping/out-of-range NSO image")
        if not flags & (1 << index) and stored != length:
            raise ValueError("uncompressed NSO segment length mismatch")
        end = address + length
    if end + struct.unpack_from("<I", header, 0x3c)[0] > MAX_IMAGE:
        raise ValueError("NSO image/BSS exceeds 1 GiB scan limit")


def scan(exefs):
    report = {key: False for key in CATEGORIES}
    report.update(evidence={key: [] for key in CATEGORIES}, ok=False, why=NOTICE)
    evidence = {key: set() for key in CATEGORIES}
    current = "exefs"
    count = 0
    try:
        for path in sorted(Path(exefs).iterdir()):
            current = path.name
            if path.name in ("sdk", "sdk.nso") or not path.is_file():
                continue
            with path.open("rb") as stream:
                header = stream.read(0x100)
            if not (header[:4] == b"NSO0" or MODULE_NAME.fullmatch(path.name) or path.suffix == ".nso"):
                continue
            check_header(path, header)
            image = nso_syms.load(path)
            # Reuse the existing structural validator: dynsyms assumes valid
            # metadata (e.g. zero DT_HASH count would otherwise mean no imports).
            # This also preserves its MOD0 check under python -O.
            validate_symbols(image)
            symbols = nso_syms.dynsyms(image)
            count += 1
            for symbol, defined, _binding in symbols:
                if defined:
                    continue
                name = function_name(symbol)
                for key, names in FUNCTIONS.items():
                    if name in names:
                        evidence[key].add(f"{path.name}:{symbol}")
        if not count:
            raise ValueError("no readable non-sdk NSO/MOD0")
    except Exception as error:
        # Existing readers also raise struct/assert/key/LZ4-extension errors.
        # A bad module invalidates the aggregate; never turn it into a negative.
        report["why"] = f"{NOTICE}；扫描失败（未知）：{current}: {type(error).__name__}: {error}"
        return report
    report["ok"] = True
    report["evidence"] = {key: sorted(evidence[key]) for key in CATEGORIES}
    report.update({key: bool(evidence[key]) for key in CATEGORIES})
    return report


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        report = {key: False for key in CATEGORIES}
        report.update(evidence={key: [] for key in CATEGORIES}, ok=False,
                      why=f"{NOTICE}；用法：input_caps_static.py <exefs directory>")
    else:
        report = scan(args[0])
    print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Read-only ARM64 16:9 candidate locator (Q4); never creates patches/tables.

    python3 tools/arm64_aspect_locator.py path/to/main [--format json|tsv]

Input is one NSO0, not a flattened image: segment boundaries are required.
Addresses are module virtual offsets, NOT file offsets or live process PCs.
The importable analyze(bytes, ...) API returns the same report as the JSON CLI.
TSV is a candidate-only view: it omits schema, input identity and global
limitations. Use JSON for a standalone provenance-bearing report.
Exit 0 means a complete scan (possibly no candidates); 2 means invalid input,
missing dependencies or an explicit resource limit. Errors emit no report.

The target set is float32 16/9 and decimal 1.777778 (matching wide_scan.py),
plus float64 16/9. Code-section constants, LDR literal loads and bounded
MOVZ/MOVK -> FMOV dataflow are reported with local context. Scalar FMOV #imm
is decoded too, but its 8-bit encoding cannot represent these target values.

Confidence is deliberately NOT an aspect-ratio classifier: integer-only or
unreferenced constants are low; observed scalar FMUL/FDIV use is medium, never
high. Even medium can be an unrelated coefficient. No engine/function identity,
reachability, complete CFG or visual correctness is proved. Data embedded in
text can look like code. Branches, incoming direct targets, calls, undecodable
words and overwritten registers break propagation; no inter-block analysis.
Literal data is read only from declared file-backed segments, never BSS/holes.

Existing wide_scan.load() flattens sparse spans and discards exact text size;
it is therefore unsuitable for this strictly segment-bounded read-only input.
This tool does not change that production scanner, its consumers or policies.
Dependencies are the existing tools/rewriter-requirements.txt Capstone/LZ4;
no source or bytes from community patches or game binaries are bundled.
"""

import argparse
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '.')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
import hashlib
import json
import os
import stat
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

TARGETS = {32: frozenset((0x3FE38E39, 0x3FE38E3B)), 64: frozenset((0x3FFC71C71C71C71C,))}
DEFAULT_MAX_BYTES = 256 * 1024 * 1024
DEFAULT_MAX_CANDIDATES = 10000
SCHEMA = "s2arm.arm64-aspect-candidates.v1"


@dataclass(frozen=True)
class Segment:
    name: str
    address: int
    data: bytes

    def read(self, address, size):
        offset = address - self.address
        if 0 <= offset and size <= len(self.data) - offset:
            return self.data[offset : offset + size]
        return None


@dataclass(frozen=True)
class Value:
    bits: int
    origin: int
    sources: tuple
    kind: str
    precision: int = 0  # 0: integer register storage, otherwise scalar FP width.


def _dependencies():
    try:
        import capstone
        import lz4
        import lz4.block
    except ImportError as exc:
        raise ValueError("requires existing tools/rewriter-requirements.txt dependencies") from exc
    # Same fixed decoder/decompressor as the existing rewriter, never auto-install.
    if capstone.__version__ != "5.0.7" or lz4.__version__ != "4.4.5":
        raise ValueError("requires Capstone 5.0.7 / LZ4 4.4.5 (rewriter-requirements.txt)")
    return capstone, lz4.block


def _segments(raw, max_bytes, lz4_block):
    if len(raw) > max_bytes:
        raise ValueError("NSO input byte limit exceeded")
    if len(raw) < 0x100 or raw[:4] != b"NSO0":
        raise ValueError("expected a complete NSO0 header")
    raw = _nso_plain(raw, "NSO")
    version, flags = struct.unpack_from("<I", raw, 4)[0], struct.unpack_from("<I", raw, 12)[0]
    # 0x40：Switch 2 新出现的标志位，与段解码无关（事实取自 Eden-NS2 加载器，GPL，代码自写：只认 0-5 位与 0x80 ZBIC）；0x80 ZBIC 已在上面经 _nso_plain 解成不压缩段
    if version != 0 or flags & ~0x7f:
        raise ValueError("unsupported NSO version or flags")
    spans, memory_spans, declared = [], [], []
    total = 0
    for k, name in enumerate(("text", "ro", "data")):
        offset, address, size = struct.unpack_from("<III", raw, 0x10 + 16 * k)
        stored = struct.unpack_from("<I", raw, 0x60 + 4 * k)[0]
        total += size
        if total > max_bytes:
            raise ValueError("NSO decompressed byte limit exceeded")
        if address + size > 1 << 32 or (name == "text" and (address % 4 or size % 4)):
            raise ValueError("invalid NSO segment address/alignment")
        if not flags & (1 << k) and stored != size:
            raise ValueError("uncompressed NSO segment length mismatch")
        if not size and stored:
            raise ValueError("empty NSO segment has stored bytes")
        if size:
            if offset < 0x100 or stored == 0 or offset + stored > len(raw):
                raise ValueError("NSO file segment out of bounds")
            if any(offset < hi and lo < offset + stored for lo, hi in spans):
                raise ValueError("NSO file segments overlap")
            if any(address < hi and lo < address + size for lo, hi in memory_spans):
                raise ValueError("NSO virtual segments overlap")
            spans.append((offset, offset + stored))
            memory_spans.append((address, address + size))
        declared.append((k, name, offset, address, size, stored))
    # Validate all spans/budgets before any decompression/allocation.
    segments = []
    for k, name, offset, address, size, stored in declared:
        content = raw[offset : offset + stored] if size else b""
        if size and flags & (1 << k):
            try:
                content = lz4_block.decompress(content, uncompressed_size=size)
            except Exception as exc:
                raise ValueError(f"invalid NSO {name} LZ4 block") from exc
        if len(content) != size:
            raise ValueError(f"NSO {name} decompressed length mismatch")
        if flags & (8 << k):
            expected = raw[0xA0 + 32 * k : 0xC0 + 32 * k]
            if hashlib.sha256(content).digest() != expected:
                raise ValueError(f"NSO {name} hash mismatch")
        segments.append(Segment(name, address, content))
    return segments


def _read(segments, address, size):
    for segment in segments:
        result = segment.read(address, size)
        if result is not None:
            return result
    return None


def _signed(value, width):
    return value - (1 << width) if value & (1 << (width - 1)) else value


def _branch_target(word, pc):
    if word & 0x7C000000 == 0x14000000:  # B / BL
        return pc + 4 * _signed(word & 0x3FFFFFF, 26)
    if word & 0xFF000010 == 0x54000000 or word & 0x7E000000 == 0x34000000:
        return pc + 4 * _signed((word >> 5) & 0x7FFFF, 19)  # B.cond / CBZ / CBNZ
    if word & 0x7E000000 == 0x36000000:
        return pc + 4 * _signed((word >> 5) & 0x3FFF, 14)  # TBZ / TBNZ
    return None


def _exception_barrier(word):
    """Explicit exception/debug transfers, regardless of Capstone group labels.

    The D4 encoding family includes SVC/HVC/SMC, BRK/HLT and DCPS1/2/3.
    ERET's encoding space includes authenticated ERETAA/ERETAB; DRPS is the
    debug return. Reserved encodings in these spaces are conservative barriers
    too. We do not model handlers or prove that resumption preserves registers.
    """
    return word & 0xFF000000 == 0xD4000000 or word & 0xFFFFF000 == 0xD69F0000 or word == 0xD6BF03E0


def _literal(word, pc):
    if word & 0x3B000000 != 0x18000000:
        return None
    opc, vector = word >> 30, bool(word & (1 << 26))
    if opc == 3:  # PRFM or unallocated, not a value load.
        return None
    size = (4, 8, 16)[opc] if vector else (4, 8, 4)[opc]
    address = pc + 4 * _signed((word >> 5) & 0x7FFFF, 19)
    return address, size, vector, opc


def _register(name):
    if name in ("fp", "lr"):
        return "x29" if name == "fp" else "x30"
    if len(name) > 1 and name[1:].isdigit():
        if name[0] in "wx":
            return "x" + name[1:]
        if name[0] in "bhsdqv":
            return "v" + name[1:]
    return None  # SP and zero registers are not general storage for this analysis.


def _fp_width(name):
    return 32 if name.startswith("s") else 64 if name.startswith("d") else 0


def _instructions(md, text):
    # Capstone cs_disasm allocates the entire requested instruction array in C.
    # Chunking bounds that allocation; dataflow state continues across chunks.
    for offset in range(0, len(text.data), 0x4000):
        yield from md.disasm(text.data[offset : offset + 0x4000], text.address + offset)


def analyze(raw, *, window=16, max_bytes=DEFAULT_MAX_BYTES, max_candidates=DEFAULT_MAX_CANDIDATES):
    """Analyze immutable NSO bytes; return a deterministic JSON-compatible report.

    Resource bounds are per invocation. No global decoder/dataflow state, file
    writes, device access, game-specific rules or automatic enabling occurs.
    ValueError denotes incomplete/invalid input, never a successful empty result.
    """
    if not 1 <= window <= 64 or max_bytes < 1 or max_candidates < 1:
        raise ValueError("invalid window/resource limit")
    capstone, lz4_block = _dependencies()
    segments = _segments(raw, max_bytes, lz4_block)
    text = segments[0]
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    md.detail, md.skipdata = True, True
    rows, registers = {}, {}
    # One byte per text word, instead of potentially millions of Python integers.
    # Bit 0: incoming direct target. Bit 1: file-backed literal-pool word.
    boundaries = bytearray(len(text.data) // 4)
    unresolved = 0

    def record(value, precision):
        bits = value.bits & ((1 << precision) - 1)
        if bits not in TARGETS[precision]:
            return None
        key = (value.origin, value.kind, precision, bits)
        if key not in rows:
            if len(rows) >= max_candidates:
                raise ValueError("candidate count limit exceeded; no partial report")
            rows[key] = {
                "address": hex(value.origin),
                "kind": value.kind,
                "precision": precision,
                "bits": f"{bits:0{precision // 4}x}",
                "value": struct.unpack(
                    "<f" if precision == 32 else "<d", bits.to_bytes(precision // 8, "little")
                )[0],
                "confidence": "low",
                "aspect_proven": False,
                "reason": "constant_only_not_aspect_proof",
                "source_addresses": set(),
                "float_use_addresses": set(),
            }
        row = rows[key]
        row["source_addresses"].update(value.sources)
        return row

    # Direct branch destinations invalidate linear proofs even when their source
    # appears later. Record literal ranges before decoding them as instructions.
    for offset in range(0, len(text.data), 4):
        word = struct.unpack_from("<I", text.data, offset)[0]
        pc = text.address + offset
        target = _branch_target(word, pc)
        if target is not None and text.address <= target < text.address + len(text.data):
            boundaries[(target - text.address) // 4] |= 1
        literal = _literal(word, pc)
        if literal:
            address, size, _, _ = literal
            if _read(segments, address, size) is not None:
                for p in range(address & ~3, address + size, 4):
                    if text.address <= p < text.address + len(text.data):
                        boundaries[(p - text.address) // 4] |= 2
        # Raw constants in text are intentionally low confidence, including pools.
        record(Value(word, pc, (pc,), "text_constant"), 32)
        if offset + 8 <= len(text.data):
            bits = struct.unpack_from("<Q", text.data, offset)[0]
            record(Value(bits, pc, (pc,), "text_constant"), 64)

    def floating_use(value, pc, arithmetic=False):
        row = record(value, value.precision)
        if row:
            row["float_use_addresses"].add(pc)
            if arithmetic:
                row["confidence"] = "medium"
                row["reason"] = "scalar_multiply_or_divide_not_aspect_proof"
            elif row["confidence"] == "low":
                row["reason"] = "floating_use_not_aspect_proof"

    for ins in _instructions(md, text):
        pc = ins.address
        boundary = boundaries[(pc - text.address) // 4]
        word = struct.unpack_from("<I", text.data, pc - text.address)[0]
        if (
            not ins.id
            or ins.size != 4
            or boundary & 2
            or ins.mnemonic == "udf"
            or _exception_barrier(word)
        ):
            registers.clear()
            continue
        if boundary & 1:
            registers.clear()
        registers = {key: val for key, val in registers.items() if pc - val.origin <= window * 4}
        reads, writes = ins.regs_access()
        previous = registers.copy()
        # Generic reads prove at most that a scalar FP value is used, not why.
        if ins.mnemonic != "fmov":
            for reg in reads:
                name = md.reg_name(reg)
                value = previous.get(_register(name))
                if value and value.precision and _fp_width(name) == value.precision:
                    floating_use(value, pc, ins.mnemonic in ("fmul", "fdiv"))
        for reg in writes:
            registers.pop(_register(md.reg_name(reg)), None)
        if any(
            group in ins.groups
            for group in (
                capstone.CS_GRP_JUMP,
                capstone.CS_GRP_CALL,
                capstone.CS_GRP_RET,
                capstone.CS_GRP_INT,
                capstone.CS_GRP_IRET,
            )
        ):
            registers.clear()
            continue
        # Decode the real move-wide encoding, not the disassembler's MOV alias.
        opcode = word & 0x7F800000
        if opcode in (0x52800000, 0x72800000):
            rd, width = word & 31, 64 if word >> 31 else 32
            shift, immediate = ((word >> 21) & 3) * 16, (word >> 5) & 0xFFFF
            if rd == 31 or shift >= width:
                continue
            key = f"x{rd}"
            if opcode == 0x52800000:
                value = Value(immediate << shift, pc, (pc,), "movwide")
            else:
                old = previous.get(key)
                if old is None:
                    continue
                bits = (old.bits & ~(0xFFFF << shift)) | (immediate << shift)
                value = Value(bits & ((1 << width) - 1), old.origin, old.sources + (pc,), "movwide")
            registers[key] = value
            if value.bits <= 0xFFFFFFFF:
                record(value, 32)
            record(value, 64)
            continue
        literal = _literal(word, pc)
        if literal:
            address, size, vector, opc = literal
            data = _read(segments, address, size)
            if data is None:
                unresolved += 1
                continue
            if size == 16 or word & 31 == 31 and not vector:
                continue
            bits = int.from_bytes(data, "little")
            if not vector and opc == 2:  # LDRSW sign extension.
                bits = _signed(bits, 32) & 0xFFFFFFFFFFFFFFFF
            precision = size * 8 if vector else 0
            value = Value(bits, pc, (address,), "literal", precision)
            registers[("v" if vector else "x") + str(word & 31)] = value
            if precision:
                floating_use(value, pc)
            else:
                if bits <= 0xFFFFFFFF:
                    record(value, 32)
                record(value, 64)
            continue
        operands = ins.operands
        if ins.mnemonic in ("mov", "fmov") and len(operands) == 2:
            dst, src = operands
            if dst.type != capstone.arm64.ARM64_OP_REG:
                continue
            dst_name = md.reg_name(dst.reg)
            dst_key = _register(dst_name)
            if dst_key is None:
                continue
            if src.type == capstone.arm64.ARM64_OP_FP and ins.mnemonic == "fmov":
                precision = _fp_width(dst_name)
                if precision:
                    bits = int.from_bytes(
                        struct.pack("<f" if precision == 32 else "<d", src.fp), "little"
                    )
                    value = Value(bits, pc, (pc,), "fmov_immediate", precision)
                    registers[dst_key] = value
                    floating_use(value, pc)
            elif src.type == capstone.arm64.ARM64_OP_REG:
                src_name = md.reg_name(src.reg)
                value = previous.get(_register(src_name))
                if value is None:
                    continue
                if ins.mnemonic == "mov" and dst_name[0] in "wx" and src_name[0] in "wx":
                    width = 32 if dst_name[0] == "w" else 64
                    registers[dst_key] = Value(
                        value.bits & ((1 << width) - 1), value.origin, value.sources, value.kind
                    )
                elif ins.mnemonic == "fmov":
                    precision = _fp_width(dst_name)
                    if precision and (src_name[0] in "wx" or _fp_width(src_name) == precision):
                        copied = Value(
                            value.bits & ((1 << precision) - 1),
                            value.origin,
                            value.sources,
                            value.kind,
                            precision,
                        )
                        registers[dst_key] = copied
                        floating_use(copied, pc)

    def context(address):
        offset = address - text.address
        result = []
        for pos in range(max(0, offset - 8), min(len(text.data), offset + 12), 4):
            decoded = next(md.disasm(text.data[pos : pos + 4], text.address + pos), None)
            result.append(
                {
                    "address": hex(text.address + pos),
                    "mnemonic": decoded.mnemonic if decoded and decoded.id else ".word",
                    "operands": decoded.op_str if decoded and decoded.id else "undecodable/data",
                }
            )
        return result

    output = []
    for key, row in sorted(rows.items()):
        row["source_addresses"] = [hex(x) for x in sorted(row["source_addresses"])]
        row["float_use_addresses"] = [hex(x) for x in sorted(row["float_use_addresses"])]
        row["context"] = context(key[0])
        output.append(row)
    return {
        "schema": SCHEMA,
        "input_sha256": hashlib.sha256(raw).hexdigest(),
        "module_id": raw[0x40:0x60].hex(),
        "window_instructions": window,
        "address_space": "module_virtual_offset",
        "aspect_proven": False,
        "segments": [
            {"name": seg.name, "address": hex(seg.address), "size": len(seg.data)}
            for seg in segments
        ],
        "unresolved_literal_loads": unresolved,
        "candidates": output,
        "limitations": [
            "linear_text_scan_not_reachability_proof",
            "constant_use_not_aspect_proof",
            "no_cross_block_or_indirect_memory_propagation",
            "no_patch_or_enable_table",
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("nso", type=Path)
    parser.add_argument("--format", choices=("json", "tsv"), default="json")
    parser.add_argument(
        "--window", type=int, default=16, help="maximum provenance age in instructions, 1..64"
    )
    parser.add_argument(
        "--max-bytes",
        type=int,
        default=DEFAULT_MAX_BYTES,
        help="input AND total decompressed byte limit",
    )
    parser.add_argument("--max-candidates", type=int, default=DEFAULT_MAX_CANDIDATES)
    args = parser.parse_args(argv)
    try:
        if args.max_bytes < 1:
            raise ValueError("invalid input byte limit")
        # Reject pipes/devices without a blocking read; only regular NSO files.
        fd = os.open(args.nso, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("NSO input must be a regular file")
            if info.st_size > args.max_bytes:
                raise ValueError("NSO input byte limit exceeded")
            raw = source.read(args.max_bytes + 1)
        report = analyze(
            raw, window=args.window, max_bytes=args.max_bytes, max_candidates=args.max_candidates
        )
        if args.format == "json":
            rendered = json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2)
        else:
            columns = (
                "address",
                "kind",
                "precision",
                "bits",
                "confidence",
                "reason",
                "source_addresses",
                "float_use_addresses",
                "context",
            )
            lines = ["\t".join(columns)]
            for row in report["candidates"]:
                lines.append(
                    "\t".join(
                        json.dumps(row[name], ensure_ascii=True, separators=(",", ":"))
                        if isinstance(row[name], (list, dict))
                        else str(row[name])
                        for name in columns
                    )
                )
            rendered = "\n".join(lines)
        print(rendered)
        return 0
    except (OSError, ValueError) as exc:
        print(f"【红】ARM64 aspect locator: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""R5: read-only NSO dynamic-export memory-function locator.

    python3 tools/sdk_mem_loc.py path/to/sdk > report.json

Addresses are module virtual offsets, NOT file offsets or live process PCs.
Lengths are ELF64 st_size bytes, not inferred boundaries or disassembly proof.
Only defined, visible GLOBAL/WEAK STT_FUNC exports inside text are reported.
Zero-size exports are unresolved; imports/objects/local/hidden symbols are not
implementations. A stripped/unsupported table is an error, not an empty success.
An empty functions list only means no eligible exports matched this exact list.

Default names: memcpy/memmove/memset/memcmp/memchr/bcopy/bzero and nn::os
FlushDataCache/StoreDataCache/InvalidateDataCache (Itanium mangled exports
with (const void*, size_t) / (void*, size_t) signatures). Other overloads
require --symbol and are not guessed. Symbol names are bounded to 4096 bytes.
--symbol NAME adds an exact raw dynamic-symbol name (no substring/fuzzy match).
Names classify exports, not their semantics: no SDK identity or runtime behavior
is proved. No interception, patches, memory constants or production integration.

NSO segment loading reuses arm64_aspect_locator._segments: bounded decompression,
file/virtual overlap and enabled digest checks. Only LZ4 4.4.5 is required; no
Capstone decoder is loaded. Symbol counts require DT_HASH or DT_GNU_HASH, never
strtab-minus-symtab guesses. Dynamic pointers are module virtual offsets; only
file-backed bytes are read (never BSS or sparse holes). Duplicate metadata,
ambiguous matching definitions and malformed inputs fail with no JSON output.
Exit 0: complete report; 2: input/dependency/resource error. No auto-install.
"""

import argparse
import hashlib
import json
import os
import stat
import struct
import sys

from arm64_aspect_locator import DEFAULT_MAX_BYTES, _segments, _read

SCHEMA = 's2arm.sdk-memory-exports.v1'
DEFAULT_MAX_SYMBOLS = 1000000
C_NAMES = frozenset(('memcpy', 'memmove', 'memset', 'memcmp', 'memchr', 'bcopy', 'bzero'))
CACHE_NAMES = ('FlushDataCache', 'StoreDataCache', 'InvalidateDataCache')


def family(name, extra):
    if name in extra:
        return 'explicit_symbol'
    if name in C_NAMES:
        return 'libc_memory'
    for short in CACHE_NAMES:
        prefix = f'_ZN2nn2os{len(short)}{short}E'
        if name in (prefix + 'PKvm', prefix + 'Pvm'):
            return 'nn::os::' + short
    return None


def analyze(raw, *, symbols=(), max_bytes=DEFAULT_MAX_BYTES, max_symbols=DEFAULT_MAX_SYMBOLS):
    if max_bytes <= 0 or max_symbols <= 0:
        raise ValueError('resource limits must be positive')
    try:
        import lz4
        import lz4.block
    except ImportError as exc:
        raise ValueError('requires LZ4 4.4.5 from tools/rewriter-requirements.txt') from exc
    if lz4.__version__ != '4.4.5':
        raise ValueError('requires locked LZ4 4.4.5')
    segs = _segments(raw, max_bytes, lz4.block)

    def read(address, size):
        if address < 0 or size < 0:
            raise ValueError('negative metadata range')
        value = _read(segs, address, size)
        if value is None:
            raise ValueError(f'metadata range outside a file-backed segment: {address:#x}+{size:#x}')
        return value

    def unpack(fmt, address):
        return struct.unpack(fmt, read(address, struct.calcsize(fmt)))

    # NSO startup header lives at module offset zero, regardless of file offset.
    mod0 = unpack('<I', 4)[0]
    if read(mod0, 4) != b'MOD0':
        raise ValueError('missing MOD0 header')
    dynamic = mod0 + unpack('<i', mod0 + 4)[0]
    tags = {}
    relevant = {4, 5, 6, 10, 11, 0x6FFFFEF5}
    for i in range(4096):
        tag, value = unpack('<qQ', dynamic + 16*i)
        if tag == 0:
            break
        if tag in relevant:
            if tag in tags:
                raise ValueError(f'duplicate dynamic tag {tag:#x}')
            tags[tag] = value
    else:
        raise ValueError('dynamic table lacks bounded DT_NULL')
    if not {5, 6, 10, 11}.issubset(tags) or tags.get(11) != 24:
        raise ValueError('requires DT_STRTAB, DT_SYMTAB, DT_STRSZ and ELF64 DT_SYMENT=24')
    strings = read(tags[5], tags[10])
    if not strings or strings[0] != 0:
        raise ValueError('invalid dynamic string table')
    counts = []
    if 4 in tags:
        buckets, count = unpack('<II', tags[4])
        if not buckets or not count or buckets > max_symbols or count > max_symbols:
            raise ValueError('invalid or oversized DT_HASH count')
        read(tags[4], 8 + 4*(buckets + count))
        counts.append(('DT_HASH', count))
    if 0x6FFFFEF5 in tags:
        address = tags[0x6FFFFEF5]
        buckets, first, blooms, shift = unpack('<IIII', address)
        if not buckets or not blooms or max(buckets, blooms, first) > max_symbols or shift >= 64:
            raise ValueError('invalid or oversized DT_GNU_HASH header')
        bucket_address = address + 16 + 8*blooms
        read(address, 16 + 8*blooms + 4*buckets)
        starts = unpack('<' + 'I'*buckets, bucket_address)
        count = first
        # Each chain word is visited at most once; reject overlapping chains.
        visited = set()
        chain_address = bucket_address + 4*buckets
        for start in starts:
            if not start:
                continue
            if start < first or start >= max_symbols:
                raise ValueError('invalid GNU hash bucket')
            index = start
            while True:
                if index >= max_symbols or index in visited:
                    raise ValueError('invalid or oversized GNU hash chain')
                visited.add(index)
                word = unpack('<I', chain_address + 4*(index-first))[0]
                count = max(count, index+1)
                if word & 1:
                    break
                index += 1
        if not count:
            raise ValueError('GNU hash lacks null symbol')
        counts.append(('DT_GNU_HASH', count))
    if not counts:
        raise ValueError('symbol count unavailable: requires DT_HASH or DT_GNU_HASH')
    if len({count for _, count in counts}) != 1:
        raise ValueError('conflicting dynamic symbol counts')
    count = counts[0][1]
    table = read(tags[6], count*24)
    if table[:24] != bytes(24):
        raise ValueError('invalid null dynamic symbol')
    text = segs[0]
    functions, unresolved, names = [], [], set()
    extra = frozenset(symbols)
    for index in range(1, count):
        off, info, other, section, value, size = struct.unpack_from('<IBBHQQ', table, index*24)
        if off >= len(strings):
            raise ValueError('dynamic symbol name outside DT_STRSZ')
        end = strings.find(b'\0', off, off + 4097)
        if end < 0:
            raise ValueError('unterminated or oversized dynamic symbol name')
        # ELF symbol names are bytes, not necessarily Unicode; preserve reversibly.
        name = strings[off:end].decode('latin1')
        kind = family(name, extra)
        if kind is None or section == 0 or info >> 4 not in (1, 2) or info & 15 != 2 or other & 3 not in (0, 3):
            continue
        if section >= 0xFF00:
            raise ValueError('matching function has unsupported reserved section index')
        if name in names:
            raise ValueError(f'ambiguous duplicate memory-function export: {name}')
        names.add(name)
        if value % 4 or size % 4 or text.read(value, max(size, 4)) is None:
            raise ValueError(f'memory-function export outside aligned text: {name}')
        row = {'symbol': name, 'family': kind, 'symbol_index': index,
               'address': hex(value), 'length': size, 'length_source': 'ELF64.st_size',
               'binding': 'global' if info >> 4 == 1 else 'weak'}
        if not size:
            row['reason'] = 'zero_symbol_size'
            unresolved.append(row)
        else:
            functions.append(row)
    return {'schema': SCHEMA, 'input_sha256': hashlib.sha256(raw).hexdigest(),
            'module_id': raw[0x40:0x60].hex(), 'address_kind': 'module_virtual_offset',
            'runtime_verified': False, 'symbol_count': count,
            'count_sources': [source for source, _ in counts],
            'functions': functions, 'unresolved': unresolved,
            'limitations': ['symbol names do not prove SDK identity or function behavior',
                            'length is declared st_size, not an inferred implementation boundary',
                            'no game/device execution; no stripped/private-function recovery']}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('nso')
    parser.add_argument('--symbol', action='append', default=[], help='additional exact raw export name')
    args = parser.parse_args()
    try:
        # No FIFOs/devices: the bounded byte budget must not become an unbounded read.
        fd = os.open(args.nso, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError('input must be a regular NSO file')
            raw = stream.read(DEFAULT_MAX_BYTES+1)
        report = analyze(raw, symbols=args.symbol)
    except (OSError, ValueError, struct.error) as exc:
        print(f'sdk_mem_loc: {exc}', file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=True, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())

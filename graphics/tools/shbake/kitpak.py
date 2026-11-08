#!/usr/bin/env python3
# NVNKits 'kit!' archives (Unravel Two: romfs/NVNKits/Data.kit, the index, with its data volumes Data.kit.0 … Data.kit.11), unpacked for nxsh_extract.py: jobs → members, each entry then goes
#   through nxsh_extract.visit (13,993 of the 22,268 entries are PhyreEngine clusters, 'RYHP', whose shaders are code area + control section back to back: scan_adj pairs them).
# Index (little-endian): 'kit!', u32 version 1, u32 1, u32 1, u32 hash table bytes T (0x40000), u32 0, u32 entry count n, u32 volume count, u8 (unused); at 0x21 the hash table
#   (T / 8 slots {u32 name hash, u32 entry}, not needed to list the entries); at 0x21 + T the entries, n × 56 bytes {u64 name hash, u64 location (volume = low 16 bits, offset in the
#   volume = the rest), u64 stored length, u64 length, 20 bytes SHA-1 of the data, u32 0}; then '!tik', the end of the file.
# Volume Data.kit.<volume>: an entry's stored bytes are [offset, offset + stored length); entries with the same content share one range. Stored length == length: kept as it is;
#   otherwise a sequence of 64 KB blocks, each {u32 stored length} + an LZ4 block, linked (each block may refer back into the 64 KB before it, as the blocks of an LZ4 frame).
# Every entry is checked against its SHA-1, so a misread layout cannot pass silently (Unravel Two: 22,268 entries, 467 of them sharing content with another).
import hashlib, os, struct

shader = None   # no member is a shader by its own header (hgpak.shader): every entry goes through nxsh_extract.visit

MAGIC, TAIL, BLOCK = b'kit!', b'!tik', 0x10000
ENTRY = struct.Struct('<QQQQ20sI')


def kit_entries(path):
    """→ [(name hash, volume, offset, stored length, length, sha1)]; None when the file is not a kit! index. A layout that does not add up raises ValueError"""
    with open(path, 'rb') as f: d = f.read()
    if d[:4] != MAGIC: return None
    ver, _, _, table, _, n, vols = struct.unpack_from('<7I', d, 4)
    if ver != 1 or table % 8: raise ValueError(f'kit! version {ver}, hash table {table:#x} bytes: only version 1 with 8-byte slots is known')
    at = 0x21 + table
    if at + ENTRY.size * n + 4 != len(d) or d[-4:] != TAIL: raise ValueError(f'kit! with {n} entries does not end at {at + ENTRY.size * n + 4:#x} with !tik (the file is {len(d):#x} bytes)')
    out = []
    for h, loc, csz, usz, sha, _ in ENTRY.iter_unpack(d[at:at + ENTRY.size * n]):
        if loc & 0xffff >= vols: raise ValueError(f'kit! entry {h:016x} is in volume {loc & 0xffff} of {vols}')
        out.append((h, loc & 0xffff, loc >> 16, csz, usz, sha))
    return out


def kit_data(raw, usz):
    """An entry's stored bytes → its data"""
    if len(raw) == usz: return bytes(raw)
    import lz4.block
    out, p = bytearray(), 0
    while len(out) < usz and p + 4 <= len(raw):
        c = struct.unpack_from('<I', raw, p)[0]; p += 4
        out += lz4.block.decompress(raw[p:p + c], uncompressed_size=min(BLOCK, usz - len(out)), dict=bytes(out[-BLOCK:]))
        p += c
    if p != len(raw) or len(out) != usz: raise ValueError(f'the LZ4 blocks end at {p:#x} of {len(raw):#x} stored bytes with {len(out):#x} of {usz:#x} bytes')
    return bytes(out)


def jobs(files, oodle=None, parts=64):
    """nxsh_extract's jobs: each kit! index's entries (one per content) in about equal stored sizes. → ([(index path, entries), …], the paths taken: the indexes and their volumes,
    which are never scanned as loose files (2.4 GB of volumes)"""
    out, taken = [], set()
    for p in files:
        with open(p, 'rb') as f:
            if f.read(4) != MAGIC: continue
        seen, uniq = set(), []
        for e in kit_entries(p):
            if e[5] not in seen: seen.add(e[5]); uniq.append(e)
        taken.add(p); taken |= {f'{p}.{v}' for v in {e[1] for e in uniq}}
        step, cur, size = sum(e[3] for e in uniq) / parts, [], 0
        for e in sorted(uniq, key=lambda e: (e[1], e[2])):
            cur.append(e); size += e[3]
            if size >= step: out.append((p, tuple(cur))); cur, size = [], 0
        if cur: out.append((p, tuple(cur)))
    return out, taken


def members(path, ents, oodle=None):
    """→ (name hash as 16 hex digits, data) of each entry; an entry whose data fails its SHA-1 raises ValueError"""
    vols = {}
    try:
        for h, v, off, csz, usz, sha in ents:
            f = vols.get(v) or vols.setdefault(v, open(f'{path}.{v}', 'rb'))
            f.seek(off); d = kit_data(f.read(csz), usz)
            if hashlib.sha1(d).digest() != sha: raise ValueError(f'entry {h:016x}: its data does not match its SHA-1')
            yield f'{h:016x}', d
    finally:
        for f in vols.values(): f.close()

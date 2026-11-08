#!/usr/bin/env python3
# Hello Games' HGPAK archives (No Man's Sky: NMSARC.*.pak) and the .nvb shaders in them, for nxsh_extract.py: jobs → members; a member that is a .nvb (shader) is taken by its header,
#   every other member goes through nxsh_extract.visit.
# .nvb (NMSARC.Shaders.pak: 48,027 of them, one single-stage shader each): a 0x20-byte header {u64 control offset, u64 code offset, u64 0x38, u64 content hash}, both offsets from +0x20.
#   The code area does not follow the control section right away (32 or 44 bytes between them in every file), so the adjacent scan (scan_adj) cannot pair it: on No Man's Sky it found
#   4,732 keys, 53 of them ghosts, where the headers give 9,899.
# Header (little-endian): 'HGPAK\0\0\0', u64 version 2, u64 file count n, u64 chunk count c, u64 compressed (0 / 1), u64 data start D; at 0x30 n × {16-byte hash, u64 offset, u64 length};
#   then c × u64 chunk stored length; D (the tables' end rounded up to 16) starts the chunks, each stored at a 16-byte boundary.
# A compressed archive is one virtual byte space: [0, D) as it is (the header and tables), then the chunks decompressed back to back, each 0x20000 bytes (the last may be shorter); file i is the
#   virtual range [offset, offset + length). A chunk whose stored length equals its length is kept as it is; the others are Oodle, decoded by the game's own decoder (nxsh_extract.pkz_oodle).
#   An archive that is not compressed has no chunk table: the offsets are offsets in the file.
# File 0 is the path list (one path per line, in entry order after it), which names the entries.
import struct

MAGIC, CHUNK, CTL_MAGIC = b'HGPAK\0\0\0', 0x20000, bytes.fromhex('34127698')


def hgpak_header(d):
    """→ dict(n, comp, D, files [(hash, offset, length)], csz (chunk stored lengths), starts (chunk file offsets)); None when d is not an HGPAK. A layout that does not add up raises ValueError"""
    if d[:8] != MAGIC: return None
    ver, n, c, comp, D = struct.unpack_from('<5Q', d, 8)
    if ver != 2 or comp not in (0, 1): raise ValueError(f'HGPAK version {ver}, compressed {comp}: only version 2 is known')
    if 0x30 + 32 * n + 8 * c > len(d): raise ValueError(f'HGPAK tables of {n} files and {c} chunks run past the file ({len(d):#x} bytes)')
    files = [struct.unpack_from('<16sQQ', d, 0x30 + 32 * i) for i in range(n)]
    if not comp:
        if any(o + s > len(d) for _, o, s in files): raise ValueError('HGPAK not compressed, but a file runs past its end')
        return dict(n=n, comp=0, D=D, files=files, csz=(), starts=())
    csz = struct.unpack_from(f'<{c}Q', d, 0x30 + 32 * n)
    if (0x30 + 32 * n + 8 * c + 15) & ~15 != D: raise ValueError(f'HGPAK tables end at {0x30 + 32 * n + 8 * c:#x}, the data starts at {D:#x}')
    starts, p = [], D
    for s in csz: starts.append(p); p = (p + s + 15) & ~15
    if starts and starts[-1] + csz[-1] > len(d): raise ValueError(f'HGPAK chunks run to {starts[-1] + csz[-1]:#x}, past the file ({len(d):#x} bytes)')
    if any(o + s > D + CHUNK * c for _, o, s in files): raise ValueError(f'HGPAK files reach past its {c} chunks')
    return dict(n=n, comp=1, D=D, files=files, csz=csz, starts=starts)


class Hgpak:
    """Reads files out of an HGPAK held in d (bytes or an mmap), decoding a chunk at a time (the last one kept); oodle(stored, length) → bytes, ValueError when the decoder rejects the stream"""
    def __init__(self, d, oodle):
        self.d, self.h, self.oodle, self.cache = d, hgpak_header(d), oodle, (None, None)
        self.total = max((o + s for _, o, s in self.h['files']), default=0)

    def chunk(self, k):
        if self.cache[0] != k:
            h = self.h; st, s = h['starts'][k], h['csz'][k]
            n = min(CHUNK, self.total - h['D'] - CHUNK * k)   # the last chunk holds the data up to the last file's end
            raw = bytes(self.d[st:st + s])
            if s == n or s == CHUNK: out = raw
            else:   # the last chunk: some archives compressed it up to the last file's end, others padded to 0x20000 (No Man's Sky has both); the decoder takes only the exact length
                try: out = self.oodle(raw, n)
                except ValueError:
                    if n == CHUNK: raise
                    out = self.oodle(raw, CHUNK)
                if len(out) < n: raise ValueError(f'HGPAK chunk {k}: {len(out)} of {n} bytes')
            self.cache = (k, out)
        return self.cache[1]

    def read(self, off, size):
        if not self.h['comp']: return bytes(self.d[off:off + size])
        D, out = self.h['D'], bytearray()
        if off < D: out += self.d[off:min(D, off + size)]; size -= len(out); off += len(out)
        while size > 0:
            k, o = divmod(off - D, CHUNK); b = self.chunk(k)[o:o + size]
            if not b: raise ValueError(f'HGPAK chunk {k} ends before {off:#x}')
            out += b; off += len(b); size -= len(b)
        return bytes(out)

    def files(self):
        """→ [(name, offset, length)] of every file after the path list; the names come from the path list when it has one line per file, else the hashes"""
        fs = self.h['files']
        if not fs: return []
        names = [x.strip(b'\r\0') for x in self.read(fs[0][1], fs[0][2]).split(b'\n')]
        names = [x.decode('utf-8', 'replace') for x in names if x]
        if len(names) != len(fs) - 1: names = [h.hex() for h, _, _ in fs[1:]]
        return [(nm, o, s) for nm, (_, o, s) in zip(names, fs[1:])]


def shader(b):
    """A .nvb → (control section, code area): the control's own length (+0x20) and code length (+0x704); None when b is not one (no control magic where its header points)"""
    if len(b) < 0x40: return None
    co, go = struct.unpack_from('<Q', b, 0)[0] + 0x20, struct.unpack_from('<Q', b, 8)[0] + 0x20
    if co + 0x708 > len(b) or b[co:co + 4] != CTL_MAGIC: return None
    nctl, ncode = struct.unpack_from('<I', b, co + 0x20)[0], struct.unpack_from('<I', b, co + 0x704)[0]
    if co + nctl > len(b) or go < co + nctl or go + ncode > len(b): raise ValueError(f'.nvb: control {co:#x}+{nctl:#x} and code {go:#x}+{ncode:#x} do not fit its {len(b):#x} bytes')
    return b[co:co + nctl], b[go:go + ncode]


def jobs(files, oodle, parts=64):
    """nxsh_extract's jobs: each HGPAK's files (the path list read once here) in about equal sizes. → ([(path, files), …], the archive paths taken)"""
    import mmap
    out, taken = [], set()
    for p in files:
        with open(p, 'rb') as f:
            if f.read(8) != MAGIC: continue
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as d: fl = Hgpak(d, oodle).files()
        taken.add(p)
        step, cur, size = sum(x[2] for x in fl) / parts, [], 0
        for x in fl:
            cur.append(x); size += x[2]
            if size >= step: out.append((p, tuple(cur))); cur, size = [], 0
        if cur: out.append((p, tuple(cur)))
    return out, taken


def members(path, fl, oodle):
    """→ (name, data) of the files fl of the HGPAK at path"""
    import mmap
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as d:
        r = Hgpak(d, oodle)
        for name, off, size in fl: yield name, r.read(off, size)

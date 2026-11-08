#!/usr/bin/env python3
"""Byte-exact equivalence diff for two decoder YUV dumps (issue #1449).

Reads two S2AY dump files, normalizes every frame to visible I420 (crop
margins applied, stride / slice-height padding removed, NV12 / NV21
deinterleaved, YV12 plane order corrected), then compares the sequences
frame by frame aligned by submission sequence number (au_index), zero
tolerance. H.264/VP8 require conforming decoders to produce bit-identical
output, so any byte difference after normalization is a real defect.

Usage: s2a_yuvdiff.py <a.s2ay> <b.s2ay> [--verbose]
Exit:  0 identical, 1 difference found (or nothing comparable), 2 usage/parse error.

S2AY dump format (little-endian; emitted by the #1449 bring-up dumpers —
the libavc reference dumper and the MediaCodec probe — keep this spec in
sync with their shared writer):

    file    u32 magic 0x53324159 "S2AY", u32 version (1)
    frame   20 * u32 header, then the plane bytes back to back:
        [0]  u32 magic 0x53324652 "S2FR"
        [1]  au_index    submission sequence number; the alignment key
        [2]  emit_index  decoder output order (informational only)
        [3]  fmt         1=I420 2=NV12 3=NV21 4=raw blob 5=YV12
        [4]  coded_w     buffer width as reported by the decoder format
        [5]  coded_h     buffer height as reported by the decoder format
        [6..9]   crop margins left, top, right, bottom in pixels
        [10..12] per-plane row stride in bytes
        [13..15] per-plane stored rows (includes slice-height padding)
        [16..18] per-plane stored byte counts
        [19]   reserved, must be 0
    planes  fmt 1 (I420):        Y, U, V
            fmt 5 (YV12):        Y, V, U
            fmt 2/3 (NV12/NV21): Y, interleaved UV / VU, unused (0 bytes)
            fmt 4 (raw):         one opaque blob in plane 0

Crop margins are pixels removed on each side: the visible rect is
(w-left-right) x (h-top-bottom) with its top-left at (left, top); chroma
offsets and sizes halve (ceiling), so left and top must be even for 4:2:0.
MediaCodec reports crop as an inclusive rect; dumpers convert it to
margins before writing.
"""
import argparse
import struct
import sys

FILE_MAGIC = 0x53324159   # "S2AY"
FILE_VERSION = 1
FRAME_MAGIC = 0x53324652  # "S2FR"
FMT_I420, FMT_NV12, FMT_NV21, FMT_RAW, FMT_YV12 = 1, 2, 3, 4, 5
FMT_NAME = {FMT_I420: "I420", FMT_NV12: "NV12", FMT_NV21: "NV21",
            FMT_RAW: "raw", FMT_YV12: "YV12"}
HEADER = struct.Struct("<20I")


class DumpError(Exception):
    """File-level corruption: the dump cannot be trusted at all."""


class Incomparable(Exception):
    """One frame cannot be normalized to I420 (unknown fmt, bad geometry)."""


def parse_dump(path):
    """Parse an S2AY file into {frames: {au: rec}, order: [au], dups, records}."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise DumpError(f"{path}: {e}") from e
    if len(data) < 8:
        raise DumpError(f"{path}: too small ({len(data)} bytes)")
    magic, version = struct.unpack_from("<II", data, 0)
    if magic != FILE_MAGIC:
        raise DumpError(f"{path}: bad magic 0x{magic:08x} (not an S2AY dump)")
    if version != FILE_VERSION:
        raise DumpError(f"{path}: version {version}, expected {FILE_VERSION}")
    pos = 8
    frames, order, dups = {}, [], []
    while pos < len(data):
        if pos + HEADER.size > len(data):
            raise DumpError(f"{path}: truncated frame header at offset {pos}")
        h = HEADER.unpack_from(data, pos)
        if h[0] != FRAME_MAGIC:
            raise DumpError(f"{path}: bad frame magic 0x{h[0]:08x} at offset {pos}")
        pos += HEADER.size
        sizes = h[16:19]
        if h[19] != 0:
            raise DumpError(f"{path}: reserved header field nonzero at offset {pos - HEADER.size}")
        end = pos + sizes[0] + sizes[1] + sizes[2]
        if end > len(data):
            raise DumpError(f"{path}: truncated plane data at offset {pos}")
        rec = {"au": h[1], "emit": h[2], "fmt": h[3], "w": h[4], "h": h[5],
               "crop": (h[6], h[7], h[8], h[9]),
               "stride": (h[10], h[11], h[12]), "rows": (h[13], h[14], h[15]),
               "planes": [data[pos:pos + sizes[0]],
                          data[pos + sizes[0]:pos + sizes[0] + sizes[1]],
                          data[pos + sizes[0] + sizes[1]:end]],
               "offset": pos - HEADER.size}
        pos = end
        if rec["au"] in frames:
            dups.append(rec["au"])
        else:
            frames[rec["au"]] = rec
        order.append(rec["au"])
    return {"path": path, "frames": frames, "order": order,
            "dups": dups, "records": len(order)}


def _crop_rows(plane, stride, rows, ox, oy, w, h, name):
    """Extract a w x h rect at (ox, oy) from a strided plane; contiguous rows out."""
    if w <= 0 or h <= 0 or ox < 0 or oy < 0 or ox + w > stride or oy + h > rows:
        raise Incomparable(
            f"plane {name}: rect ({ox},{oy})+{w}x{h} outside stride {stride} x {rows} rows")
    if (oy + h - 1) * stride + ox + w > len(plane):
        raise Incomparable(f"plane {name}: {len(plane)} bytes too short for "
                           f"stride {stride} x {oy + h} rows")
    return b"".join(plane[(oy + r) * stride + ox:(oy + r) * stride + ox + w]
                    for r in range(h))


def normalize(rec):
    """One frame -> (visible_w, visible_h, [Y, U, V]) contiguous I420 rows.

    Raises Incomparable for unknown formats or self-inconsistent geometry."""
    fmt = rec["fmt"]
    if fmt == FMT_RAW or fmt not in FMT_NAME:
        raise Incomparable(f"fmt {fmt}: no YUV interpretation")
    w, h = rec["w"], rec["h"]
    cl, ct, cr, cb = rec["crop"]
    if w <= 0 or h <= 0 or w > 16384 or h > 16384:
        raise Incomparable(f"coded size {w}x{h} out of range")
    if min(cl, ct, cr, cb) < 0 or cl + cr >= w or ct + cb >= h:
        raise Incomparable(f"crop {cl},{ct},{cr},{cb} leaves no visible picture in {w}x{h}")
    if cl % 2 or ct % 2:
        raise Incomparable(f"crop origin ({cl},{ct}) not chroma aligned")
    vw, vh = w - cl - cr, h - ct - cb
    cw, ch = (vw + 1) // 2, (vh + 1) // 2
    sy, su, sv = rec["stride"]
    ry, ru, rv = rec["rows"]
    py, pu, pv = rec["planes"]
    y = _crop_rows(py, sy, ry, cl, ct, vw, vh, "Y")
    if fmt in (FMT_I420, FMT_YV12):
        (up, us, ur), (vp, vs, vr) = (
            ((pv, sv, rv), (pu, su, ru)) if fmt == FMT_YV12
            else ((pu, su, ru), (pv, sv, rv)))
        u = _crop_rows(up, us, ur, cl // 2, ct // 2, cw, ch, "U")
        v = _crop_rows(vp, vs, vr, cl // 2, ct // 2, cw, ch, "V")
    else:   # NV12 / NV21: plane 1 is the interleaved chroma, plane 2 must be empty
        if pv:
            raise Incomparable(f"{FMT_NAME[fmt]}: third plane must be empty")
        uv = _crop_rows(pu, su, ru, cl, ct // 2, 2 * cw, ch, "UV")
        u, v = bytearray(), bytearray()
        first, second = (u, v) if fmt == FMT_NV12 else (v, u)
        for r in range(ch):
            row = uv[r * 2 * cw:(r + 1) * 2 * cw]
            first += row[0::2]
            second += row[1::2]
        u, v = bytes(u), bytes(v)
    return vw, vh, (y, u, v)


def _first_diff(a, b, chunk=65536):
    """Index of the first differing byte (assumes equal lengths)."""
    for off in range(0, len(a), chunk):
        if a[off:off + chunk] == b[off:off + chunk]:
            continue
        return off + next(i for i, (x, y) in enumerate(zip(a[off:off + chunk],
                                                           b[off:off + chunk])) if x != y)
    return None


def _raw_bytes(rec):
    return b"".join(rec["planes"])


def _summarize(d):
    seq = d["order"]
    note = "" if seq == sorted(seq) else " (emit order != au order)"
    head = ",".join(str(x) for x in seq[:8])
    return f"{d['path']}  records={d['records']} au=[{head}{'...' if len(seq) > 8 else ''}]{note}"


def compare(da, db, verbose=False, emit=print):
    """Compare two parsed dumps; returns 0 identical, 1 difference."""
    fa, fb = da["frames"], db["frames"]
    if set(fa) != set(fb) or da["records"] != db["records"] or da["dups"] or db["dups"]:
        emit(f"MISMATCH: a has {da['records']} records / {len(fa)} au, "
             f"b has {db['records']} records / {len(fb)} au")
        only_a, only_b = sorted(set(fa) - set(fb)), sorted(set(fb) - set(fa))
        if only_a:
            emit(f"  au only in a: {only_a}")
        if only_b:
            emit(f"  au only in b: {only_b}")
        for side, d in (("a", da), ("b", db)):
            if d["dups"]:
                emit(f"  {side} has duplicate au: {sorted(set(d['dups']))}")
        return 1
    compared = 0
    for au in sorted(fa):
        ra, rb = fa[au], fb[au]
        if ra["fmt"] == FMT_RAW or rb["fmt"] == FMT_RAW:
            both_raw = ra["fmt"] == rb["fmt"] == FMT_RAW
            if both_raw and _raw_bytes(ra) == _raw_bytes(rb):
                compared += 1
                continue
            why = ("raw payloads differ" if both_raw
                   else f"fmt {FMT_NAME.get(ra['fmt'], ra['fmt'])} vs "
                        f"{FMT_NAME.get(rb['fmt'], rb['fmt'])}")
            emit(f"DIFF au={au}: {why}")
            return 1
        try:
            va, vb = normalize(ra), normalize(rb)
        except Incomparable as e:
            emit(f"DIFF au={au}: {e}")
            return 1
        if va[:2] != vb[:2]:
            emit(f"DIFF au={au}: visible size {va[0]}x{va[1]} vs {vb[0]}x{vb[1]}")
            return 1
        for pi, (pa, pb) in enumerate(zip(va[2], vb[2])):
            if pa == pb:
                continue
            off = _first_diff(pa, pb)
            pw = va[0] if pi == 0 else (va[0] + 1) // 2
            name = "YUV"[pi]
            ndiff = sum(x != y for x, y in zip(pa, pb))
            emit(f"DIFF au={au} plane={name} row={off // pw} col={off % pw} "
                 f"a=0x{pa[off]:02x} b=0x{pb[off]:02x} "
                 f"({ndiff}/{len(pa)} bytes differ in plane)")
            return 1
        compared += 1
        if verbose:
            emit(f"  au={au}: {va[0]}x{va[1]} identical (emit {ra['emit']}/{rb['emit']}, "
                 f"fmt {FMT_NAME[ra['fmt']]}/{FMT_NAME[rb['fmt']]})")
    if compared == 0:
        emit("MISMATCH: no frames to compare")
        return 1
    emit(f"IDENTICAL: {compared} frames compared byte-exact, 0 tolerance")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="exit: 0 identical, 1 difference, 2 usage/parse error")
    ap.add_argument("a", help="first S2AY dump")
    ap.add_argument("b", help="second S2AY dump")
    ap.add_argument("--verbose", action="store_true", help="print one line per compared frame")
    args = ap.parse_args(argv)
    try:
        da, db = parse_dump(args.a), parse_dump(args.b)
    except DumpError as e:
        print(f"parse error: {e}")
        return 2
    print(_summarize(da))
    print(_summarize(db))
    return compare(da, db, args.verbose)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Switch 2 (NVN2) shaders in the game files: GLSLC compiler outputs of version 0x00220015 and their NVN2 control sections (version 0xc9).
shader_split.py calls in here; the archive formats around them (KTGL RDB / IDRK, LINKDATA) stay there, as they are not particular to the Switch 2.

GLSLC output, version 0x00220015 (Pokémon Pokopia's main, its RDB entries and LINKDATA): magic 0x19866891 at +0, the version at +8, total length +0x5c, the first
section's data offset +0x60, the section count +0x64, the section headers from +0xa8, 0x98 bytes each: {u32 size, u32 data offset (from the output), u32 type (0 = GPU code,
3 = reflection)}; a GPU code header adds +0x30 control offset, +0x34 code offset (both from the section's data), +0x38 code length, +0x3c control length, as in the
Switch 1's GLSLC (shader_split.py glslc_section, there from +0x90 in 0x90-byte headers). On Pokopia's 31,110 outputs of 300 G2S entries checked one by one: two sections,
the GPU code one first; its control is an NVN2 one whose +0x44 is the code length and whose stage byte equals the output's +0xd4. (pokopia-native's glslc2_extract.py reads
+0x60 as a region length, +0xa8 as the code length and +0xdc as a header length: the same bytes where the GPU code section's control sits at its data's start, but it misses
the outputs whose +0xdc is 0xd8, 203,120 of them in 0x38f972af.fdata.) The code area is what the game puts in GPU memory: a 0x80-byte SPH version 4 for the graphics stages,
the instructions, the c1 constant segment.
NVN2 control section: magic 0x98761234, version 0xc9 at +4, its own length at +0x30 (0xd8 / 0xe0; 0 in agl's BAHS and in memory), the instructions' length at +0x38
(SPH included), the c1 segment between +0x40 and +0x44, the code area's length at +0x44, the stage at +0x56 (as above), compute's thread group at +0x58.

Key: sha256(the first 0x48 bytes of the control section, +0x20..+0x27 and +0x30..+0x33 as zeros, + the code area)[:16]. The 0x48 bytes and the zeroed +0x30 are the reference port's
(d3995ca4, MIT: Donkey Kong Bananza's BNSH files hold the section's length at +0x30, memory holds 0); the zeroed +0x20..+0x27 are pokopia-native's (MIT, s2_ctl_scan.py:
Pokopia's driver rewrites them per program at run time, 6 of 71 requests differed only there). The host's keys_hash has to hash the same bytes.
Layouts: the reference port dm/gfx/tools/dmsh_ampere.py and shader_split.py (d3995ca4, MIT), pokopia-native tools/glslc2_extract.py (MIT)."""
import re, struct

CTL_MAGIC, CTL_VERSION = b'\x34\x12\x76\x98', b'\xc9\0\0\0'
GLSLC_MAGIC, GLSLC_VERSION = b'\x91\x68\x86\x19', 0x00220015
KEY_CTL = 0x48
NVN_STAGE = {0: 'vs', 1: 'ps', 2: 'gs', 3: 'hs', 4: 'ds', 5: 'cs', 6: 'ts', 7: 'ms'}   # 6 / 7: task / mesh (their SPH reads as vertex or domain; the control section decides)


def is_nvn2(ctl):
    """An NVN2 control section: magic and version 0xc9"""
    return len(ctl) >= KEY_CTL and ctl[:4] == CTL_MAGIC and ctl[4:8] == CTL_VERSION


def key_ctl(ctl):
    """The control bytes in the key (see the module's notes)"""
    c = bytearray(ctl[:KEY_CTL]); c[0x20:0x28] = bytes(8); c[0x30:0x34] = bytes(4)
    return bytes(c)


def code_len(ctl): return struct.unpack_from('<I', ctl, 0x44)[0]


def stage(ctl):
    """The stage byte at +0x56"""
    return NVN_STAGE.get(ctl[0x56]) if len(ctl) > 0x56 else None


def check(st, ctl, code):
    """control section and code area consistent; returns the reason if not"""
    if not is_nvn2(ctl) or len(ctl) < 0x60: return 'bad NVN2 control section'
    if code_len(ctl) != len(code): return 'control +0x44 does not match the code area length'
    if stage(ctl) != st: return f'control +0x56 stage {ctl[0x56]} is not {st}'
    if st != 'cs' and len(code) < 0x80: return 'graphics code area shorter than its 0x80-byte SPH'
    return None


def compute_facts(ctl):
    """(thread group (x, y, z), shared memory bytes) of a compute shader: +0x58 and +0x64 (the reference port's offsets). On Pokopia's 1,386 compute shaders +0x64 reads as byte counts
    (0 to 0xbc00, all multiples of 16) where pokopia-native's +0xb8 holds flag-like words (0x1080000, 0x1200000), so +0x64 is taken"""
    return struct.unpack_from('<3I', ctl, 0x58), struct.unpack_from('<I', ctl, 0x64)[0]


def glslc_shaders(d, label):
    """The version-0x00220015 GLSLC outputs in d → [(where, stage, control section, code area)]; outputs that do not hold together are skipped (the magic is only 4 bytes)"""
    out = []
    for m in re.finditer(re.escape(GLSLC_MAGIC), d):
        h = m.start()
        if h + 0xa8 > len(d) or struct.unpack_from('<I', d, h + 8)[0] != GLSLC_VERSION: continue
        size, nsec = struct.unpack_from('<I', d, h + 0x5c)[0], struct.unpack_from('<I', d, h + 0x64)[0]
        if not (0xa8 < size <= len(d) - h and 0 < nsec <= 16 and 0xa8 + 0x98 * nsec <= size): continue
        secs = []
        for i in range(nsec):
            s = h + 0xa8 + 0x98 * i
            ssz, soff, typ = struct.unpack_from('<3I', d, s)
            if typ: continue
            co, ko, kn, cn = struct.unpack_from('<4I', d, s + 0x30)
            if soff + ssz > size or co + cn > ssz or ko + kn > ssz: secs = None; break
            secs.append((bytes(d[h + soff + co:h + soff + co + cn]), bytes(d[h + soff + ko:h + soff + ko + kn])))
        if not secs or len(secs) != 1: continue
        ctl, code = secs[0]
        st = stage(ctl)
        if not st or check(st, ctl, code): continue
        out.append((f'{label}#GLSLC2@{h:#x}', st, ctl, code))
    return out


def bare_programs(d, label, claimed=()):
    """NVN2 programs stored bare, outside any container the other readers know: a control block (the control section, then its reflection data) whose +0x30 holds the block's
    length, and the code area right after it (11-06 Ocarina of Time's Movie/Ndve/*.dat: its video decoder's 19 compute shaders sit so in the file's second section, in blocks
    of their own tables; the game submits them as they are, so the library never had them and the device translated them on first use, a 30-second stall on the opening).
    Only blocks longer than a bare control section (+0x30 > 0xe0) count: BNSH files hold 0xd8 / 0xe0 there with the code somewhere else, agl's BAHS / NDSR packs and memory 0.
    claimed = key_ctl of the control sections another reader already took in this blob (their code is where that reader says). → [(where, stage, control section, code area)]"""
    out = []
    for m in re.finditer(re.escape(CTL_MAGIC + CTL_VERSION), d):
        c = m.start()
        if c + 0xe0 > len(d): continue
        blk, n = struct.unpack_from('<I', d, c + 0x30)[0], struct.unpack_from('<I', d, c + 0x44)[0]
        if not 0xe0 < blk < 1 << 20 or not 0 < n < 1 << 24 or c + blk + n > len(d): continue
        ctl, code = d[c:c + 0xe0], d[c + blk:c + blk + n]
        st = stage(ctl)
        if key_ctl(ctl) in claimed or not st or check(st, ctl, code): continue
        out.append((f'{label}#NVN2@{c:#x}', st, ctl, code))
    return out

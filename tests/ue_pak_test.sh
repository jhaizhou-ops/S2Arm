#!/bin/bash
# Unreal 着色器抽取单测（pack/ue_pak.py，自拼 pak，约 2 秒）：bash tests/ue_pak_test.sh
# 期望（按 UE 公开布局手拼，期望值就是拼进去的原文，不跑被测实现算）：
#   ① 共享库布局（pak v11，存档原样存）：存档里一支 LZ4 压缩、一支原样 → 输出存档每支存储长 = 原长、内容 = 原文
#   ② 文件按 zlib 分块压缩存：同样解出
#   ③ 内嵌布局（没有 .ushaderbytecode，.uexp 里 FShaderMapResourceCode 条目）→ 合成一个存档，收齐去重后的两支、阶段对
#   ④ 着色器是 Oodle 块（8C 0A 开头）：没有宿主（不设 DM_OODLE_HOST / DM_OODLE_MODULES，RomFS 旁也没有改写模块）→ 退出 1、点名 Oodle；
#      有宿主（DM_OODLE_HOST=tests/fake_oodle_host.py，块 = 8C 0A + zlib 流）→ 退出 0、那支解回原文、等长。①里另放一个不是 pak 的 .pak 文件：跳过
#   ⑤ 无版本号旧布局（Bloodstained 1.03：u32 条数 + 32 字节条目 {哈希 20、偏移、存储长、原长}、没有阶段字节，每支 zlib）：两支 SV / SP → 版本 2 存档，阶段按标签 0 / 3、等长、原文；
#      同布局但一支记录标签认不得（LSLGSX）→ 退出 1、点名「不是认得的 LSLG 记录」
#   ⑧⑨ 旧版 pak（版本 6）：标准条目、无主之地3 的紧凑条目（偏移 u64、存储长 / 原长 u32、压缩标志 u8、块表、标志 u8，无 SHA-1 与块大小）各一份，旧布局存档 70 KB（⑨ 按 64 KiB 两块假 Oodle）→ 两支解开等长；
#   ⑩ 读完条目还剩 40 字节 → 退出 1 点名认不出；⑪ 旧版 pak 只有压缩的内嵌资源、没宿主 → 退出 0、不出存档（旧版内嵌归 shader_split）
#   ⑦ pak v11 单块 Oodle 文件，原长约 3.3 KB、编码条目的块大小字段（6 位、单位 2048）只记得下 2048：唯一那块按原长解（假宿主长度不符即判失败，同真 Oodle）→ 退出 0、内嵌那支等长
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
"$PY" - "$T" <<'PY'
import os, struct, sys, zlib, hashlib, lz4.block
T = sys.argv[1]
def fstr(s): b = s.encode() + b'\0'; return struct.pack('<i', len(b)) + b
def rec(tag, body): return b'LSLG' + tag + b'S' + body   # 测试只要 LSLG 开头（ue_pak 不解析记录内部）
A = rec(b'SV', b'vertex-code' * 20); B = rec(b'SP', b'pixel-code' * 30)
def archive(items):   # [(阶段, 原文, 压缩?)] → 版本 2 存档
    code = b''; ents = b''
    for fr, raw, comp in items:
        st = lz4.block.compress(raw, store_size=False) if comp else raw
        ents += struct.pack('<QIIB', len(code), len(st), len(raw), fr); code += st
    n = len(items)
    return (struct.pack('<II', 2, 1) + b'\1' * 20 + struct.pack('<I', n) + b'\2' * 20 * n + struct.pack('<IIIII', 1, 0, n, 0, 0) + struct.pack('<I', n) + ents
            + struct.pack('<I', 0) + struct.pack('<I', n) + struct.pack(f'<{n}I', *range(n)) + code)
def pak(path, files, zlib_files=(), oodle_files=(), method='Zlib'):   # files: {相对路径: 字节}；zlib_files 里的按 zlib 一块存；oodle_files 按假 Oodle 一块存、块大小字段只记 2048（原长更长：UE 单块文件 6 位块大小截断）
    data = b''; enc = b''; dirs = {}
    for name, b in files.items():
        off = len(data)
        if name in oodle_files:
            z = b'\x8c\x0a' + zlib.compress(b); head = struct.pack('<QQQI', 0, len(z), len(b), 1) + b'\0' * 20 + struct.pack('<I', 1) + b'\0' * 16 + b'\0' + struct.pack('<I', 2048)
            data += head + z
            bits = 1 | (1 << 6) | (1 << 23) | (1 << 29) | (1 << 30) | (1 << 31)   # 块大小字段 1（= 2048）、1 块、方法 1、三个 32 位够
            e = struct.pack('<IIII', bits, off, len(b), len(z))
        elif name in zlib_files:
            z = zlib.compress(b); head = struct.pack('<QQQI', 0, len(z), len(b), 1) + b'\0' * 20 + struct.pack('<I', 1) + b'\0' * 16 + b'\0' + struct.pack('<I', 65536)
            data += head + z
            bits = (65536 >> 11) | (1 << 6) | (1 << 23) | (1 << 29) | (1 << 30) | (1 << 31)   # 块大小 64K、1 块、方法 1（Zlib）、三个 32 位够
            e = struct.pack('<IIII', bits, off, len(b), len(z))
        else:
            head = struct.pack('<QQQI', 0, len(b), len(b), 0) + b'\0' * 20 + b'\0' + struct.pack('<I', 0)
            data += head + b
            e = struct.pack('<III', (1 << 29) | (1 << 30) | (1 << 31), off, len(b))
        d, f = os.path.split(name); dirs.setdefault(d + '/', []).append((f, len(enc))); enc += e
    fd = struct.pack('<i', len(dirs)) + b''.join(fstr(d) + struct.pack('<i', len(fs)) + b''.join(fstr(f) + struct.pack('<i', o) for f, o in fs) for d, fs in dirs.items())
    fd_off = len(data); data += fd
    idx = fstr('../../../') + struct.pack('<iQ', len(files), 0) + struct.pack('<i', 0) + struct.pack('<iQQ', 1, fd_off, len(fd)) + b'\0' * 20 + struct.pack('<i', len(enc)) + enc + struct.pack('<i', 0)
    io = len(data); data += idx
    names = method.encode().ljust(32, b'\0') + b'\0' * 128
    foot = b'\0' * 16 + b'\0' + struct.pack('<IIQQ', 0x5A6F12E1, 11, io, len(idx)) + b'\0' * 20 + names
    os.makedirs(os.path.dirname(path), exist_ok=True); open(path, 'wb').write(data + foot)
pak(f'{T}/r1/Game/Content/Paks/g.pak', {'Game/Content/ShaderArchive-Global-SF.ushaderbytecode': archive([(0, A, True), (3, B, False)])})
pak(f'{T}/r2/Paks/g.pak', {'X/ShaderArchive-Mat-SF.ushaderbytecode': archive([(0, A, True), (3, B, True)])}, zlib_files={'X/ShaderArchive-Mat-SF.ushaderbytecode'})
def entry(fr, raw): st = lz4.block.compress(raw, store_size=False); return struct.pack('<i', len(st)) + st + struct.pack('<iB', len(raw), fr)
pak(f'{T}/r3/Paks/g.pak', {'Game/M1.uexp': b'junk' + entry(0, A) + b'xx' + entry(3, B), 'Game/M2.uexp': entry(3, B), 'Game/readme.ini': b'[x]'})
oodle = b'\x8c\x0a' + zlib.compress(B)   # 假宿主认的「Oodle 块」：Mermaid 块头 + zlib 流
arc = bytearray(archive([(3, B, False)])); i = arc.rfind(B); arc[i:i + len(B)] = oodle + b'\0' * (len(B) - len(oodle))
code_at = len(arc) - len(B); ent_at = arc.find(struct.pack('<QIIB', 0, len(B), len(B), 3)); arc[ent_at:ent_at + 17] = struct.pack('<QIIB', 0, len(oodle), len(B), 3)
pak(f'{T}/r4/Paks/g.pak', {'G/ShaderArchive-O.ushaderbytecode': bytes(arc)}); open(f'{T}/r1/Game/Content/Paks/notpak.pak', 'wb').write(b'hello' * 100)
def legacy(items):   # [(原文)] → 无版本号旧布局存档，每支 zlib
    zs = [zlib.compress(r) for r in items]; ents = b''; at = 0
    for r, z in zip(items, zs): ents += hashlib.sha1(r).digest() + struct.pack('<III', at, len(z), len(r)); at += len(z)
    return struct.pack('<I', len(items)) + ents + b''.join(zs)
pak(f'{T}/r5/Paks/g.pak', {'BS/Content/ShaderArchive-GLSL_SWITCH.ushaderbytecode': legacy([A, B])})
pak(f'{T}/r6/Paks/g.pak', {'BS/Content/ShaderArchive-GLSL_SWITCH.ushaderbytecode': legacy([A, rec(b'SX', b'what' * 9)])})
pak(f'{T}/r7/Paks/g.pak', {'Game/M7.uexp': b'junk' + entry(3, B) + b'\0' * 3000}, oodle_files={'Game/M7.uexp'}, method='Oodle')   # ⑦ 原长约 3.3 KB、单块
def legacy_pak(path, files, compact=False, tail=b''):   # ⑧⑨ 旧版 pak（版本 6、索引不加密）：files {相对路径: (原文, 是否按 64 KiB 分块假 Oodle 存)}；compact = 无主之地3 的紧凑条目
    data = b''; ents = b''
    for name, (b, comp) in files.items():
        off = len(data); chunks = [b[i:i + 65536] for i in range(0, len(b), 65536)] if comp else []
        zs = [b'\x8c\x0a' + zlib.compress(c) for c in chunks]; body = b''.join(zs) if comp else b
        nb = len(zs); head = (8 + 4 + 4 + 1 + 1 if compact else 8 + 8 + 8 + 4 + 20 + 1 + 4) + (4 + 16 * nb if comp else 0)
        blocks = b''; at = head
        for z in zs: blocks += struct.pack('<QQ', at, at + len(z)); at += len(z)
        if compact: e = struct.pack('<QIIB', off, len(body), len(b), 4 if comp else 0) + (struct.pack('<I', nb) + blocks if comp else b'') + b'\0'
        else: e = struct.pack('<qqqi', off, len(body), len(b), 4 if comp else 0) + b'\0' * 20 + (struct.pack('<i', nb) + blocks if comp else b'') + b'\0' + struct.pack('<I', 65536)
        assert len(e) == head; data += e + body; ents += fstr(name) + e
    idx = fstr('../../../') + struct.pack('<i', len(files)) + ents + tail; io = len(data)
    foot = b'\0' + struct.pack('<IIQQ', 0x5A6F12E1, 6, io, len(idx)) + b'\0' * 20
    os.makedirs(os.path.dirname(path), exist_ok=True); open(path, 'wb').write(data + idx + foot)
C = rec(b'SV', b''.join(hashlib.sha256(str(i).encode()).digest() for i in range(2200)) + bytes(10000))   # 约 80 KB、大半压不动：zlib 后仍约 70 KB，存档跨两块 64 KiB
for k, c in ((8, False), (9, True)): legacy_pak(f'{T}/r{k}/Paks/g.pak', {'Oak/Content/ShaderArchive-Oak.ushaderbytecode': (legacy([B, C]), c), 'Oak/Content/M8.uexp': (b'xx' + entry(0, A), False)}, compact=c)
legacy_pak(f'{T}/r10/Paks/g.pak', {'Oak/Content/M8.uexp': (b'xx' + entry(0, A), False)}, compact=True, tail=b'\7' * 40)   # 读完条目还剩 40 字节：两种布局都不认
legacy_pak(f'{T}/r11/Paks/g.pak', {'Oak/Content/M8.uexp': (b'xx' + entry(0, A), True)}, compact=True)   # 旧版 pak 只有内嵌资源（压缩）：不归 ue_pak 收
open(f'{T}/want_C', 'wb').write(C)
os.makedirs(f'{T}/mods'); open(f'{T}/mods/main.fixups.tsv', 'w').write('# 假模块目录（oodle_host_find 只看有没有这个文件）\n')
open(f'{T}/want_A', 'wb').write(A); open(f'{T}/want_B', 'wb').write(B)
PY
rd() { "$PY" - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read(); o = 4
def skip(e):
    global o; n = struct.unpack_from('<I', b, o)[0]; o += 4 + e * n
skip(20); skip(20); skip(16)
n = struct.unpack_from('<I', b, o)[0]; o += 4; ents = [struct.unpack_from('<QIIB', b, o + 17 * i) for i in range(n)]; o += 17 * n
skip(16); skip(4)
print(' '.join(f'{fr}:{"等长" if s == r else "压缩"}:{b[o + off:o + off + s][:6].decode("latin1")}:{s}' for off, s, r, fr in ents))
PY
}
for k in 1 2 3 5 6; do "$PY" "$H/pack/ue_pak.py" $T/r$k $T/o$k > $T/l$k 2>&1; eval "r$k=\$?"; done
env -u DM_OODLE_HOST -u DM_OODLE_MODULES "$PY" "$H/pack/ue_pak.py" $T/r4 $T/o4 > $T/l4 2>&1; r4=$?
DM_OODLE_HOST="$H/tests/fake_oodle_host.py" DM_OODLE_MODULES=$T/mods "$PY" "$H/pack/ue_pak.py" $T/r4 $T/o4b > $T/l4b 2>&1; r4b=$?
LA=$(wc -c < $T/want_A | tr -d ' '); LB=$(wc -c < $T/want_B | tr -d ' ')
o1=$(rd $T/o1/ShaderArchive-Global-SF.ushaderbytecode); o2=$(rd $T/o2/ShaderArchive-Mat-SF.ushaderbytecode); o3=$(rd "$(ls $T/o3/*.ushaderbytecode | head -1)")
ck "① 共享库布局：LZ4 那支解开、两支等长、内容是原文（${o1}）；不是 pak 的文件跳过" '[ $r1 = 0 ] && grep -q "notpak.pak：不是 Unreal pak" $T/l1 && [ "$o1" = "0:等长:LSLGSV:$LA 3:等长:LSLGSP:$LB" ] && cmp -s <(tail -c $LB $T/o1/ShaderArchive-Global-SF.ushaderbytecode) $T/want_B'
ck "② 文件 zlib 分块存：照样解出（${o2}）" '[ $r2 = 0 ] && [ "$o2" = "0:等长:LSLGSV:$LA 3:等长:LSLGSP:$LB" ]'
ck "③ 内嵌布局：两个 .uexp 里 3 条、去重后 2 支、阶段 0 / 3，合成存档（${o3}）" '[ $r3 = 0 ] && [ "$o3" = "0:等长:LSLGSV:$LA 3:等长:LSLGSP:$LB" ] && ls $T/o3 | grep -q "^ShaderArchive-Inline-g.ushaderbytecode$"'
o4=$(rd $T/o4b/ShaderArchive-O.ushaderbytecode 2>/dev/null)
ck "④ Oodle 块：没宿主 → 退出 1、点名 Oodle（rc=${r4}）；假宿主 → 退出 0、解回原文等长（rc=${r4b}，${o4}）" '[ $r4 = 1 ] && grep -q "Oodle" $T/l4 && [ $r4b = 0 ] && [ "$o4" = "3:等长:LSLGSP:$LB" ] && cmp -s <(tail -c $LB $T/o4b/ShaderArchive-O.ushaderbytecode) $T/want_B && grep -q "1 支由游戏解码器解出" $T/l4b'
DM_OODLE_HOST="$H/tests/fake_oodle_host.py" DM_OODLE_MODULES=$T/mods "$PY" "$H/pack/ue_pak.py" $T/r7 $T/o7 > $T/l7 2>&1; r7=$?
o7=$(rd "$(ls $T/o7/*.ushaderbytecode 2>/dev/null | head -1)" 2>/dev/null)
ck "⑦ 单块 Oodle 文件、原长大于块大小字段（GTA3 最终版 25042 个这样的条目）：按原长解、退出 0、内嵌那支等长（rc=${r7}，${o7}）" '[ $r7 = 0 ] && [ "$o7" = "3:等长:LSLGSP:$LB" ]'
o5=$(rd $T/o5/ShaderArchive-GLSL_SWITCH.ushaderbytecode 2>/dev/null)
ck "⑤ 无版本号旧布局：转成版本 2、阶段按标签、解开等长（rc=${r5}，${o5}）；标签认不得 → 退出 1（rc=${r6}）" '[ $r5 = 0 ] && [ "$o5" = "0:等长:LSLGSV:$LA 3:等长:LSLGSP:$LB" ] && [ $r6 = 1 ] && grep -q "不是认得的 LSLG 记录" $T/l6'
for k in 8 9 10; do DM_OODLE_HOST="$H/tests/fake_oodle_host.py" DM_OODLE_MODULES=$T/mods "$PY" "$H/pack/ue_pak.py" $T/r$k $T/o$k > $T/l$k 2>&1; eval "r$k=\$?"; done
env -u DM_OODLE_HOST -u DM_OODLE_MODULES "$PY" "$H/pack/ue_pak.py" $T/r11 $T/o11 > $T/l11 2>&1; r11=$?
LC=$(wc -c < $T/want_C | tr -d ' '); W3="3:等长:LSLGSP:$LB 0:等长:LSLGSV:$LC"
o8=$(rd $T/o8/ShaderArchive-Oak.ushaderbytecode 2>/dev/null); o9=$(rd $T/o9/ShaderArchive-Oak.ushaderbytecode 2>/dev/null)
ck "⑧ 旧版 pak（版本 6）标准条目：存档两支解开、等长（rc=${r8}，${o8}）" '[ $r8 = 0 ] && [ "$o8" = "$W3" ]'
ck "⑨ 旧版 pak 紧凑条目（无主之地3：无 SHA-1、无块大小，压缩标志 4 = 游戏 Oodle、64 KiB 两块）：存档两支解开、等长、70 KB 那支是原文（rc=${r9}，${o9}）" '[ $r9 = 0 ] && [ "$o9" = "$W3" ] && cmp -s <(tail -c $LC $T/o9/ShaderArchive-Oak.ushaderbytecode) $T/want_C'
ck "⑩ 索引读完条目还剩 ≥16 字节：两种布局都不认 → 退出 1、点名认不出（rc=${r10}）" '[ $r10 = 1 ] && grep -q "条目布局认不出" $T/l10'
ck "⑪ 旧版 pak 只有压缩的内嵌资源、没宿主：不扫（归 shader_split）→ 退出 0、不出存档、不碰解码器（rc=${r11}）" '[ $r11 = 0 ] && [ -z "$(ls $T/o11)" ] && ! grep -q Oodle $T/l11'
rm -rf $T; [ $bad = 0 ] && echo "ue_pak 单测全过" || { echo "ue_pak 单测有不通"; exit 1; }

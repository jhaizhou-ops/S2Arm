#!/bin/bash
# 界面布局扫描器读带字典的 zstd（graphics/widen/scan/ui_lyt.py，王国之泪口径，合成夹具不用游戏数据，约 3 秒）：bash tests/ui_lyt_zsdic_test.sh
#   夹具：zstd --train 训出字典号 7 的真字典 → 装进 SARC 压成 romfs/Pack/ZsDic.pack.zs（不带字典）；
#   romfs/UI/a.blarc.zs = 用该字典压的 SARC（帧头写字典号 7）；romfs/UI/b.blarc.zs = 不带字典压的 SARC（对照）
#   ① 字典表 {7: …}  ② 帧头字典号：a = 7、b = 0  ③ load 解回原 SARC  ④ save 写回帧头仍是 7、用同一字典解回原内容
#   ⑤ main 扫整个 romfs：报错 0、退出 0（10-28 前的版本不给字典，a 报 Dictionary mismatch、退出 1；反证：GEN=<旧 ui_lyt.py> bash tests/ui_lyt_zsdic_test.sh）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v zstd > /dev/null || { echo "ui_lyt_zsdic 单测要 zstd 命令行"; exit 1; }
GEN=${GEN:-$H/graphics/widen/scan/ui_lyt.py} T=$T python3 - << 'EOF'
import os, struct, subprocess, sys, importlib.util
T = os.environ['T']; gen = os.environ['GEN']; bad = 0
def ck(what, ok):
    global bad; print(('通 ' if ok else '不通 ') + what); bad |= not ok
def sarc(members):
    """最小 SARC（小端）：头 0x14 + SFAT（0xC + 16×n）+ SFNT（8 + 名字 4 字节对齐）+ 数据（各成员 8 字节对齐）。"""
    names = b''; offs = []
    for nm, _ in members: offs.append(len(names) // 4); n = nm.encode() + b'\0'; names += n + b'\0' * (-len(n) % 4)
    sfat = 0x14 + 0xC + 16 * len(members); doff = sfat + 8 + len(names); doff += -doff % 8
    data = b''; nodes = b''
    for (nm, d), o in zip(members, offs):
        data += b'\0' * (-len(data) % 8); nodes += struct.pack('<IIII', 0, 0x01000000 | o, len(data), len(data) + len(d)); data += d
    b = b'SARC' + struct.pack('<HHIIHH', 0x14, 0xFEFF, doff + len(data), doff, 0x100, 0)
    b += b'SFAT' + struct.pack('<HHI', 0xC, len(members), 0x65) + nodes + b'SFNT' + struct.pack('<HH', 8, 0) + names
    return b + b'\0' * (doff - len(b)) + data
z = lambda *a, inp: subprocess.run(['zstd', '-q', *a], input=inp, capture_output=True, check=True).stdout
# 训字典：200 份相似的小样本（字典号 7）
sd = os.path.join(T, 'samples'); os.makedirs(sd)
for i in range(200): open(os.path.join(sd, f's{i}'), 'wb').write((b'FLYT layout pane window_%03d material_%d ' % (i, i % 7)) * 20)
dic = os.path.join(T, 'd7.zsdic')
subprocess.run(['zstd', '-q', '--train', *[os.path.join(sd, f) for f in os.listdir(sd)], '--dictID=7', '--maxdict=4096', '-o', dic], check=True, capture_output=True)
rom = os.path.join(T, 'romfs'); os.makedirs(os.path.join(rom, 'Pack')); os.makedirs(os.path.join(rom, 'UI'))
open(os.path.join(rom, 'Pack', 'ZsDic.pack.zs'), 'wb').write(z('-c', inp=sarc([('zs.zsdic', open(dic, 'rb').read())])))
inner = sarc([('blyt/a.txt', b'not a layout ' * 50)])
open(os.path.join(rom, 'UI', 'a.blarc.zs'), 'wb').write(z('-c', '-D', dic, inp=inner))
open(os.path.join(rom, 'UI', 'b.blarc.zs'), 'wb').write(z('-c', inp=inner))
spec = importlib.util.spec_from_file_location('ui_lyt', gen); u = importlib.util.module_from_spec(spec); spec.loader.exec_module(u)
has = hasattr(u, 'zs_dicts')
if has:
    os.makedirs(os.path.join(T, 'dicts')); u._DICTS.update(u.zs_dicts(rom, os.path.join(T, 'dicts')))
    ck(f'① 字典表从 Pack/ZsDic.pack.zs 取出字典号 7（实得 {sorted(u._DICTS)}）', sorted(u._DICTS) == [7])
    ida = u.zs_dict_id(open(os.path.join(rom, 'UI', 'a.blarc.zs'), 'rb').read(18)); idb = u.zs_dict_id(open(os.path.join(rom, 'UI', 'b.blarc.zs'), 'rb').read(18))
    ck(f'② 帧头字典号 a = 7、b = 0（实得 {ida} / {idb}）', (ida, idb) == (7, 0))
    raw, kind, hdr = u.load(os.path.join(rom, 'UI', 'a.blarc.zs'))
    ck(f'③ load 解回原 SARC（{kind}，字典号 {hdr}，{len(raw)} 字节 vs {len(inner)}）', bytes(raw) == inner and kind == 'zstd' and hdr == 7)
    q = os.path.join(T, 'out', 'a.blarc.zs'); u.save(q, raw, kind, hdr); back = open(q, 'rb').read()
    rt = subprocess.run(['zstd', '-dcq', '-D', dic], input=back, capture_output=True).stdout
    ck(f'④ save 写回帧头字典号 {u.zs_dict_id(back[:18])}、同字典解回原内容', u.zs_dict_id(back[:18]) == 7 and rt == inner)
else: ck('①–④ 本版 ui_lyt 没有 zs_dicts（不认字典）', False)
r = subprocess.run([sys.executable, gen, rom, os.path.join(T, 'ov'), '2346', 'UI,Pack'], capture_output=True, text=True)
last = (r.stdout.strip().splitlines() or [''])[-1]
ck(f'⑤ main 扫带字典的 romfs：报错 0、退出 0（退出 {r.returncode}；{last[-40:]}）', r.returncode == 0 and '报错 0' in last)
sys.exit(1 if bad else 0)
EOF
r=$?; [ $r = 0 ] && echo "ui_lyt_zsdic 单测全过" || { echo "ui_lyt_zsdic 单测有不通"; exit 1; }

#!/bin/bash
# 门禁本机：mini 的 ~/.s2arm/venv 没有 fonttools / skia-pathops，也没有生成产物 run/s2arm/openfonts（10-23 用户体验线实测 ModuleNotFoundError + 目录不存在）；本机都有
# 开源替代共享字体单测（秒级、不联网）：bash tests/openfonts_test.sh [产物目录]
# 产物目录缺省 ~/.s2arm/run/s2arm/openfonts（先跑 pack/fonts/make_open_fonts.py <目录>）；没有产物、或解释器缺依赖，直接报红，不跳过。
# 期望值都不经被测代码算出：
#   ① 编码夹具：8 字节 TTF「00 01 00 00 41 42 43 44」手算 → 36f81a1e 4962180e 49631806 08205b42
#      （字0 = 0x18029a7f^0x06186249；字1 = 字节反序(8)^key；其后逐 4 字节小端 ^key）；长度非 4 倍数要拒
#   ② 7 个文件按 Ryujinx DecryptFont 同款算法（本脚本自写）解码：魔数对、字1 = 字节反序(长度)^key、
#      被测 encode(解码结果) 与文件逐字节相同、被测 decode 与本脚本解码相同
#   ③ 7 个文件名齐全；④ 解码后 fontTools 能打开、是 glyf 轮廓（无 CFF）、名字里没有 Nintendo / Source
#   ⑤ 抽样码位：std 有 あ A 中、简中有 中 A、繁中有 國 中 A、韩文有 한 A；
#      ext / ext2 含原版 cmap 全部私用区码位（ext：E000–E1FF、F000、F003–F1FF；ext2：E000–E25F、F000–F2C3，
#      照原版 cmap 抄的区间常量，不读被测代码）
#   ⑥ Ryujinx 装载的 6 个（不含 ext2）文件字节数之和 ≤ 0x1100000（Horizon.FontSize；文件 = 8 字节头 + TTF，恰是共享内存占用）
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
OUT=${1:-$HOME/.s2arm/run/s2arm/openfonts}
[ -x "$PY" ] || { echo "不通 解释器 $PY 不存在"; exit 1; }
"$PY" -c 'import fontTools, pathops' 2> /dev/null || { echo "不通 $PY 缺 fonttools / skia-pathops（pip install -r pack/fonts/requirements.txt）"; exit 1; }
[ -d "$OUT" ] || { echo "不通 产物目录 ${OUT} 不存在（先跑 pack/fonts/make_open_fonts.py ${OUT}）"; exit 1; }
"$PY" -I - "$H/pack/fonts" "$OUT" <<'EOF'
import importlib.util, io, struct, sys, os
spec = importlib.util.spec_from_file_location('mof', os.path.join(sys.argv[1], 'make_open_fonts.py'))
mof = importlib.util.module_from_spec(spec); spec.loader.exec_module(mof)
from fontTools.ttLib import TTFont
OUT = sys.argv[2]; K = 0x06186249; bad = 0
def ck(name, ok):
    global bad
    print(('通 ' if ok else '不通 ') + name)
    bad |= not ok

fx = bytes.fromhex('0001000041424344')
ck('① 编码夹具与手算一致', mof.encode_bfttf(fx).hex() == '36f81a1e4962180e4963180608205b42')
try:
    mof.encode_bfttf(b'\0' * 6); ck('① 长度非 4 倍数要拒', False)
except ValueError:
    ck('① 长度非 4 倍数要拒', True)

def ryu_decode(b):  # 照 SharedFontManager.DecryptFont：读字0 校魔数、跳 4 字节、其余逐字 ^key
    assert struct.unpack_from('<I', b, 0)[0] ^ K == 0x18029A7F
    n = (len(b) - 8) // 4
    return struct.pack(f'<{n}I', *[w ^ K for w in struct.unpack_from(f'<{n}I', b, 8)])

NAMES = ['nintendo_udsg-r_std_003.bfttf', 'nintendo_udsg-r_org_zh-cn_003.bfttf',
         'nintendo_udsg-r_ext_zh-cn_003.bfttf', 'nintendo_udjxh-db_zh-tw_003.bfttf',
         'nintendo_udsg-r_ko_003.bfttf', 'nintendo_ext_003.bfttf', 'nintendo_ext2_003.bfttf']
miss = [n for n in NAMES if not os.path.isfile(os.path.join(OUT, n))]
ck(f'③ 7 个文件名齐全（缺 {miss}）', not miss)
if miss: sys.exit(1)
fonts = {}
for n in NAMES:
    b = open(os.path.join(OUT, n), 'rb').read()
    try:
        ttf = ryu_decode(b)
    except AssertionError:
        ck(f'② {n} 魔数', False); continue
    w1 = struct.unpack_from('<I', b, 4)[0] ^ K
    ck(f'② {n} 头：字1 = 反序长度、长度对、往返逐字节一致、与被测解码一致',
       w1 == struct.unpack('<I', struct.pack('>I', len(b) - 8))[0] and len(ttf) == len(b) - 8
       and mof.encode_bfttf(ttf) == b and mof.decode_bfttf(b) == ttf)
    try:
        t = TTFont(io.BytesIO(ttf)); cm = t.getBestCmap()
        names = ' '.join(r.toUnicode() for r in t['name'].names if r.nameID in (1, 3, 4, 6, 16))
        ok = 'glyf' in t and 'CFF ' not in t and t['maxp'].numGlyphs > 1 and 'Nintendo' not in names \
            and 'Source' not in names
        ck(f'④ {n} 是合法 TTF（glyf、{t["maxp"].numGlyphs} 字形、{len(cm)} 码位、名「{t["name"].getDebugName(1)}」）', ok)
        fonts[n] = cm
    except Exception as e:
        ck(f'④ {n} fontTools 打不开：{e}', False)

def has(n, chars):
    m = [c for c in chars if ord(c) not in fonts.get(n, {})]
    ck(f'⑤ {n} 含 {"".join(chars)}' + (f'（缺 {m}）' if m else ''), not m)
has(NAMES[0], 'あA中'); has(NAMES[1], '中A'); has(NAMES[3], '國中A'); has(NAMES[4], '한A')
EXT = list(range(0xE000, 0xE200)) + [0xF000] + list(range(0xF003, 0xF200))
EXT2 = list(range(0xE000, 0xE260)) + list(range(0xF000, 0xF2C4))
for n, cps in ((NAMES[5], EXT), (NAMES[6], EXT2)):
    m = [hex(c) for c in cps if c not in fonts.get(n, {})]
    ck(f'⑤ {n} 含原版全部 {len(cps)} 个私用区码位' + (f'（缺 {len(m)}：{m[:8]}）' if m else ''), not m)
tot = sum(os.path.getsize(os.path.join(OUT, n)) for n in NAMES[:6])
ck(f'⑥ 装载 6 个合计 {tot} ≤ {0x1100000}（余 {0x1100000 - tot}）', tot <= 0x1100000)
print('openfonts 单测全过' if not bad else 'openfonts 单测有不通')
sys.exit(1 if bad else 0)
EOF

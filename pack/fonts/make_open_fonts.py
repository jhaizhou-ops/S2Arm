#!/usr/bin/env python3
# 开源替代共享字体（Switch 系统「共享字体」0100000000000810–0814 的 7 个 .bfttf，同名替换）：make_open_fonts.py <输出目录>
# 为什么：原版是任天堂版权数据不能随应用分发；玩家不该自己找字体。这里全部用 SIL OFL 字体现做，产物可随应用分发。
#   标准（日文 + 拉丁）= Noto Sans JP，缺的拉丁扩展 / 希腊 / 西里尔从 Noto Sans 补；简中 / 扩展简中 = Noto Sans SC；
#   繁中 = Noto Sans TC；韩文 = Noto Sans KR；两个手柄图标字体 = 本脚本自己画（字母取 Noto Sans 粗体），码位同原版。
# 来源全部钉死版本 + sha256（见 SOURCES、pack/fonts/LICENSES.md），缓存在 ~/.s2arm/run/s2arm/cache/openfonts/（S2A_OPENFONTS_CACHE 可改）；
#   下载物只当数据解析（fontTools 读字体、zipfile 读 Unihan 文本），不执行。
# 体积硬上限：Ryujinx 把 6 个字体（不含 ext2）解码后连同各 8 字节头拼进 0x1100000 字节共享内存（Horizon.FontSize），
#   超了起服务就抛异常；本脚本出完核这个账，超了报红退出。字表取舍见 LICENSES.md「字表取舍」。
# .bfttf 格式（按 compat/tree/src/Ryujinx.HLE/HOS/Services/Sdb/Pl/SharedFontManager.cs 的 DecryptFont 反推）：
#   字 0 = 0x18029a7f ^ FontKey(0x06186249)，字 1 = 字节反序(TTF 长度) ^ FontKey，其后 TTF 按小端 4 字节逐字 ^ FontKey；
#   字 1 Ryujinx 不读，按原版文件实测的写法填（原版 7 个文件全部满足）。异或自逆，编码 = 解码。
import argparse
import hashlib
import io
import math
import os
import struct
import sys
import urllib.request
import zipfile
from importlib.metadata import version as pkg_version

PINNED = {"fonttools": "4.67.0", "skia-pathops": "0.9.2"}
for _pkg, _want in PINNED.items():
    try:
        _have = pkg_version(_pkg)
    except Exception:
        _have = None
    if _have != _want:
        sys.exit(
            f"🔴 {_pkg} 版本 {_have}，要 {_want}（pip install -r pack/fonts/requirements.txt）"
        )

import pathops  # noqa: E402
from fontTools.fontBuilder import FontBuilder  # noqa: E402
from fontTools.pens.areaPen import AreaPen  # noqa: E402
from fontTools.pens.cu2quPen import Cu2QuPen  # noqa: E402
from fontTools.pens.recordingPen import DecomposingRecordingPen  # noqa: E402
from fontTools.pens.transformPen import TransformPen  # noqa: E402
from fontTools.pens.ttGlyphPen import TTGlyphPen  # noqa: E402
from fontTools.subset import Options, Subsetter  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402
from fontTools.varLib import instancer  # noqa: E402

FONT_KEY = 0x06186249
BFTTF_MAGIC = 0x18029A7F
SHARED_FONT_MEM = 0x1100000  # ryujinx Horizon.FontSize
GF = "https://raw.githubusercontent.com/google/fonts/45e3d5269e4a17d823f6d84470bc084dc5ae46f6/ofl"
# 键 → (URL, sha256, 字节数)
SOURCES = {
    "jp": (
        f"{GF}/notosansjp/NotoSansJP%5Bwght%5D.ttf",
        "c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f",
        9589900,
    ),
    "sc": (
        f"{GF}/notosanssc/NotoSansSC%5Bwght%5D.ttf",
        "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da",
        17772300,
    ),
    "tc": (
        f"{GF}/notosanstc/NotoSansTC%5Bwght%5D.ttf",
        "864727d210d54f2537bbe23b3a839436c3992af72de9322af5270897246bd44f",
        11941968,
    ),
    "kr": (
        f"{GF}/notosanskr/NotoSansKR%5Bwght%5D.ttf",
        "194018e6b2b293a7964f037b25c0249ce1418bc9ab3c971060a03aa57861e252",
        10414588,
    ),
    "latin": (
        f"{GF}/notosans/NotoSans%5Bwdth,wght%5D.ttf",
        "bfb7bb691513f12e734dc346c03a03f784912432d7e3fa8e56efcf906fe86b3d",
        2049096,
    ),
    "ofl_cjk": (
        f"{GF}/notosanssc/OFL.txt",
        "1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9",
        4388,
    ),
    "ofl_latin": (
        f"{GF}/notosans/OFL.txt",
        "cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a",
        4396,
    ),
    "unihan": (
        "https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip",
        "f7a48b2b545acfaa77b2d607ae28747404ce02baefee16396c5d2d7a8ef34b5e",
        8518517,
    ),
}
# 产物 head.created / modified 固定（google/fonts 钉的那次提交的日子 2026-03-25），产物逐字节可重现
FIXED_TS = 3857414400  # 2026-03-25 00:00:00 UTC，按 1904 纪元
FILES = {
    "std": "nintendo_udsg-r_std_003.bfttf",
    "sc": "nintendo_udsg-r_org_zh-cn_003.bfttf",
    "scx": "nintendo_udsg-r_ext_zh-cn_003.bfttf",
    "tc": "nintendo_udjxh-db_zh-tw_003.bfttf",
    "kr": "nintendo_udsg-r_ko_003.bfttf",
    "ext": "nintendo_ext_003.bfttf",
    "ext2": "nintendo_ext2_003.bfttf",
}
LOADED = ("std", "sc", "scx", "tc", "kr", "ext")  # Ryujinx 装进共享内存的 6 个（ext2 不装）


# ---------- .bfttf ----------
def _xor_words(data: bytes) -> bytes:
    n = len(data) // 4
    key = struct.pack("<I", FONT_KEY) * n
    return (int.from_bytes(data, "little") ^ int.from_bytes(key, "little")).to_bytes(
        len(data), "little"
    )


def encode_bfttf(ttf: bytes) -> bytes:
    if len(ttf) % 4:
        raise ValueError(f"TTF 长度 {len(ttf)} 不是 4 的倍数（Ryujinx 按 4 字节读，尾巴会丢）")
    head = struct.pack(
        "<II",
        BFTTF_MAGIC ^ FONT_KEY,
        struct.unpack("<I", struct.pack(">I", len(ttf)))[0] ^ FONT_KEY,
    )
    return head + _xor_words(ttf)


def decode_bfttf(b: bytes) -> bytes:
    if struct.unpack("<I", b[:4])[0] ^ FONT_KEY != BFTTF_MAGIC:
        raise ValueError("不是 BFTTF")
    body = b[8 : 8 + (len(b) - 8) // 4 * 4]
    return _xor_words(body)


# ---------- 下载与缓存 ----------
def cache_dir() -> str:
    d = os.environ.get("S2A_OPENFONTS_CACHE") or os.path.join(
        os.environ.get("S2A_RUN_ROOT") or os.path.expanduser("~/.s2arm/run"), "s2arm/cache/openfonts"
    )
    os.makedirs(d, exist_ok=True)
    return d


def fetch(key: str) -> str:
    url, sha, size = SOURCES[key]
    path = os.path.join(cache_dir(), f"{key}-{sha[:16]}{os.path.splitext(url)[1] or '.bin'}")
    if os.path.exists(path) and hashlib.sha256(open(path, "rb").read()).hexdigest() == sha:
        return path
    print(f"下载 {key}：{url}", flush=True)
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    got = hashlib.sha256(data).hexdigest()
    if got != sha or len(data) != size:
        sys.exit(f"🔴 {key} 校验不符：sha256 {got}（要 {sha}）、{len(data)} 字节（要 {size}）")
    tmp = path + ".part"
    open(tmp, "wb").write(data)
    os.replace(tmp, path)
    return path


def static_instance(key: str, axes: dict) -> TTFont:
    """变体字体定到静态实例（glyf 轮廓）；缓存键 = 源 sha + 轴值 + fonttools 版本。"""
    sha = SOURCES[key][1]
    tag = "_".join(f"{k}{v}" for k, v in sorted(axes.items()))
    path = os.path.join(cache_dir(), f"static-{key}-{sha[:16]}-{tag}-ft{PINNED['fonttools']}.ttf")
    if not os.path.exists(path):
        print(f"实例化 {key} {axes}", flush=True)
        t = instancer.instantiateVariableFont(TTFont(fetch(key)), axes, updateFontNames=False)
        t.save(path + ".part")
        os.replace(path + ".part", path)
    return TTFont(path)


# ---------- 字表 ----------
def _dbcs(codec: str, leads, trails) -> set:
    out = set()
    for a in leads:
        for b in trails:
            try:
                s = bytes([a, b]).decode(codec)
            except UnicodeDecodeError:
                continue
            if len(s) == 1:
                out.add(ord(s))
    return out


def is_han(c: int) -> bool:
    return (
        0x3400 <= c <= 0x4DBF
        or 0x4E00 <= c <= 0x9FFF
        or 0xF900 <= c <= 0xFAFF
        or 0x20000 <= c <= 0x3FFFF
    )


def is_hangul(c: int) -> bool:
    return 0xAC00 <= c <= 0xD7A3


def charsets() -> dict:
    R = range(0xA1, 0xFF)
    s = {
        "gb2312": _dbcs("gb2312", R, R),
        "gbk": _dbcs("gbk", range(0x81, 0xFF), [x for x in range(0x40, 0xFF) if x != 0x7F]),
        "big5": _dbcs("big5", range(0x81, 0xFF), list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF))),
        "ksx1001": _dbcs("euc_kr", R, R),
        "jisx0213": _dbcs("euc_jis_2004", R, R),
    }
    z = zipfile.ZipFile(fetch("unihan"))
    for field, member in (
        ("kTGH", "Unihan_OtherMappings.txt"),
        ("kIICore", "Unihan_IRGSources.txt"),
    ):
        cps = set()
        for line in z.read(member).decode("utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) == 3 and parts[1] == field:
                cps.add(int(parts[0][2:], 16))
        s[field] = cps
    return s


# 扩展简中：原版放的是 GB18030 私用区码位 → 按 GB18030-2022 已归正的标准码位取 Noto SC 的字形（逐个对过原版渲染图）
GB18030_PUA = {
    0xE78D: 0xFE10,
    0xE78E: 0xFE12,
    0xE78F: 0xFE11,
    0xE790: 0xFE13,
    0xE791: 0xFE14,
    0xE792: 0xFE15,
    0xE793: 0xFE16,
    0xE794: 0xFE17,
    0xE795: 0xFE18,
    0xE796: 0xFE19,
    0xE7C7: 0x1E3F,
    0xE7C8: 0x01F9,
    0xE7E7: 0x303E,
    0xE816: 0x20087,
    0xE817: 0x20089,
    0xE818: 0x200CC,
    0xE81E: 0x9FB4,
    0xE826: 0x9FB5,
    0xE82B: 0x9FB6,
    0xE82C: 0x9FB7,
    0xE831: 0x215D7,
    0xE832: 0x9FB8,
    0xE83B: 0x2298F,
    0xE843: 0x9FB9,
    0xE854: 0x9FBA,
    0xE855: 0x241FE,
    0xE864: 0x9FBB,
}
GB18030_PUA.update({0xE7E8 + i: 0x2FF0 + i for i in range(12)})


def is_scx(c: int) -> bool:
    return (
        c < 0x250
        or 0x1E00 <= c <= 0x1EFF
        or 0x2E80 <= c <= 0x2FFF
        or 0x303E <= c <= 0x303F
        or 0xFE10 <= c <= 0xFE1F
        or 0xFE30 <= c <= 0xFE4F
        or c in GB18030_PUA.values()
    )


# ---------- 文字字体 ----------
LATIN_FILL = [(0x20, 0x36F), (0x370, 0x3FF), (0x400, 0x52F), (0x1E00, 0x1EFF), (0x2000, 0x218F)]


def subset_text(src: TTFont, keep, family: str) -> TTFont:
    cm = src.getBestCmap()
    o = Options()
    o.layout_features = ["vert", "vrt2"]  # 原版只有 GSUB（竖排），不带 GPOS
    o.drop_tables += ["GPOS", "BASE", "STAT", "DSIG"]
    o.name_IDs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14]
    o.name_languages = ["*"]
    o.notdef_outline = True
    o.glyph_names = False
    o.recalc_timestamp = False
    s = Subsetter(o)
    s.populate(unicodes=[c for c in cm if keep(c)])
    s.subset(src)
    rename(src, family)
    return src


def rename(t: TTFont, family: str):
    name = t["name"]
    ver = name.getDebugName(5) or ""
    ps = family.replace(" ", "") + "-Regular"
    for nid, val in (
        (1, family),
        (2, "Regular"),
        (3, f"{ps};{ver}"),
        (4, f"{family} Regular"),
        (5, f"{ver}; S2Arm subset"),
        (6, ps),
    ):
        name.setName(val, nid, 3, 1, 0x409)
        name.setName(val, nid, 1, 0, 0)
    name.names = [
        n
        for n in name.names
        if n.nameID not in (16, 17)
        and (n.nameID not in (1, 2, 3, 4, 5, 6) or (n.platformID, n.langID) in ((3, 0x409), (1, 0)))
    ]


def add_cmap(t: TTFont, cp: int, gname: str):
    for st in t["cmap"].tables:
        if st.isUnicode() and (st.format in (12, 13) or cp <= 0xFFFF):
            st.cmap[cp] = gname


def merge_glyphs(dst: TTFont, src: TTFont, cps):
    """把 src 里 cps 的字形（拆开组件）加进 dst，带横 / 竖度量与 cmap。两边 unitsPerEm 都是 1000。"""
    assert dst["head"].unitsPerEm == src["head"].unitsPerEm
    scm, gs = src.getBestCmap(), src.getGlyphSet()
    order = list(dst.getGlyphOrder())
    glyf, hmtx = dst["glyf"], dst["hmtx"]
    vmtx = dst["vmtx"] if "vmtx" in dst else None
    asc = dst["OS/2"].sTypoAscender
    added = 0
    for cp in sorted(cps):
        if cp not in scm:
            continue
        gname = f"uni{cp:04X}"
        rec = DecomposingRecordingPen(gs)
        gs[scm[cp]].draw(rec)
        pen = TTGlyphPen(None)
        rec.replay(pen)
        g = pen.glyph()
        g.recalcBounds(glyf)
        order.append(gname)
        glyf.glyphs[gname] = g
        hmtx[gname] = (gs[scm[cp]].width, getattr(g, "xMin", 0))
        if vmtx is not None:
            vmtx[gname] = (1000, asc - getattr(g, "yMax", 0))
        add_cmap(dst, cp, gname)
        added += 1
    dst.setGlyphOrder(order)
    glyf.glyphOrder = order
    return added


def to_bytes(t: TTFont) -> bytes:
    t.recalcTimestamp = False
    t["head"].created = t["head"].modified = FIXED_TS
    b = io.BytesIO()
    t.save(b)
    data = b.getvalue()
    return data + b"\0" * (-len(data) % 4)


def build_text_fonts(cs: dict) -> dict:
    """汉字按字表取；非汉字：标准字体全留，中 / 韩字体留 sym() 外加各自字表里的；
    标准字体（日美欧，欧洲语言文本走它）再从 Noto Sans 补缺的拉丁扩展 / 附加符号 / 希腊 / 西里尔 / 标点。
    中 / 韩字体不补（每款约 0.2 MB，装不下：见 LICENSES.md「字表取舍」）。"""
    out = {}
    latin = static_instance("latin", {"wght": 400, "wdth": 100})

    def nonhan(c):
        return not is_han(c) and not is_hangul(c)

    # 中 / 韩字体的非汉字去掉体积大、文本里罕见的几块（各自字表里有的照样留）：CJK 兼容方块字 3300–33FF、
    # 部首 2E80–2FDF、韩文组合字母 1100–11FF / D7B0–D7FF、BMP 以外（带圈字母 / 方块字补充）
    def sym(c):
        rare = 0x3300 <= c <= 0x33FF or 0x2E80 <= c <= 0x2FDF or 0x1100 <= c <= 0x11FF
        return nonhan(c) and c <= 0xFFFF and not (rare or 0xD7B0 <= c <= 0xD7FF)

    fill = {c for lo, hi in LATIN_FILL for c in range(lo, hi + 1)}
    sc_han = cs["gb2312"] | cs["kTGH"] | cs["kIICore"] | {c for c in cs["gbk"] if not is_han(c)}
    plan = (
        ("std", "jp", lambda c: nonhan(c) or c in cs["jisx0213"], "S2Arm Sans JP"),
        ("sc", "sc", lambda c: sym(c) or c in sc_han, "S2Arm Sans SC"),
        ("scx", "sc", is_scx, "S2Arm Sans SC Ext"),
        ("tc", "tc", lambda c: sym(c) or c in cs["big5"], "S2Arm Sans TC"),
        ("kr", "kr", lambda c: sym(c) or c in cs["ksx1001"] or is_hangul(c), "S2Arm Sans KR"),
    )
    for k, src, keep, family in plan:
        t = subset_text(static_instance(src, {"wght": 400}), keep, family)
        n = merge_glyphs(t, latin, fill - set(t.getBestCmap())) if k == "std" else 0
        if k == "scx":
            cm = t.getBestCmap()
            for pua, std_cp in GB18030_PUA.items():
                if std_cp in cm:
                    add_cmap(t, pua, cm[std_cp])
        out[k] = to_bytes(t)
        print(f"{FILES[k]}：从 Noto Sans 补 {n} 个", flush=True)
    return out


# ---------- 图标字体（自己画；字母取 Noto Sans 粗体） ----------
# 码位表（来自原版 cmap，只是码位，不含轮廓）：ext = E000–E1FF、F000、F003–F1FF；ext2 = E000–E25F、F000–F2C3
EXT_PUA = list(range(0xE000, 0xE200)) + [0xF000] + list(range(0xF003, 0xF200))
EXT2_PUA = list(range(0xE000, 0xE260)) + list(range(0xF000, 0xF2C4))
UPEM, ASC, DESC, ADV = 1024, 901, -123, 1024
CX, CY, R = 512, 389, 480

LETTERS = None  # (glyphset, cmap)


def P():
    return pathops.Path()


def union(*ps):
    acc = P()
    for p in ps:
        acc = pathops.op(acc, p, pathops.PathOp.UNION)
    return acc


def minus(a, *bs):
    for b in bs:
        a = pathops.op(a, b, pathops.PathOp.DIFFERENCE)
    return a


def ellipse(cx, cy, rx, ry):
    k = 0.5522847498
    p = P()
    p.moveTo(cx + rx, cy)
    p.cubicTo(cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry)
    p.cubicTo(cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy)
    p.cubicTo(cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry)
    p.cubicTo(cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy)
    p.close()
    return p


def disc(cx=CX, cy=CY, r=R):
    return ellipse(cx, cy, r, r)


def ring(cx=CX, cy=CY, r=R, w=64):
    return minus(disc(cx, cy, r), disc(cx, cy, r - w))


def poly(pts):
    p = P()
    p.moveTo(*pts[0])
    for q in pts[1:]:
        p.lineTo(*q)
    p.close()
    return p


def rrect(x0, y0, x1, y1, r):
    k = 0.5522847498 * r
    p = P()
    p.moveTo(x0 + r, y0)
    p.lineTo(x1 - r, y0)
    p.cubicTo(x1 - r + k, y0, x1, y0 + r - k, x1, y0 + r)
    p.lineTo(x1, y1 - r)
    p.cubicTo(x1, y1 - r + k, x1 - r + k, y1, x1 - r, y1)
    p.lineTo(x0 + r, y1)
    p.cubicTo(x0 + r - k, y1, x0, y1 - r + k, x0, y1 - r)
    p.lineTo(x0, y0 + r)
    p.cubicTo(x0, y0 + r - k, x0 + r - k, y0, x0 + r, y0)
    p.close()
    return p


def rrect_ring(x0, y0, x1, y1, r, w=60):
    return minus(rrect(x0, y0, x1, y1, r), rrect(x0 + w, y0 + w, x1 - w, y1 - w, max(r - w, 1)))


def stroke(pts, w=70, closed=False):
    p = P()
    p.moveTo(*pts[0])
    for q in pts[1:]:
        p.lineTo(*q)
    if closed:
        p.close()
    p.stroke(w, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)  # 原地改
    p.convertConicsToQuads()  # 圆头描边出圆锥曲线，布尔运算不认
    return union(p)


def xf(pts, ang=0.0, s=1.0, dx=CX, dy=CY):
    c, n = math.cos(ang), math.sin(ang)
    return [(dx + s * (x * c - y * n), dy + s * (x * n + y * c)) for x, y in pts]


def label(text, h, cx=CX, cy=CY, maxw=None):
    """Noto Sans 粗体字母拼成一串，按实际外框缩到高 h（且宽不超过 maxw），中心放到 (cx, cy)。"""
    gs, cm = LETTERS
    raw = P()
    x = 0
    for ch in text:
        g = gs[cm[ord(ch)]]
        rec = DecomposingRecordingPen(gs)
        g.draw(rec)
        rec.replay(TransformPen(raw.getPen(), (1, 0, 0, 1, x, 0)))
        x += g.width
    raw = union(raw)
    x0, y0, x1, y1 = raw.bounds
    s = h / (y1 - y0)
    if maxw and (x1 - x0) * s > maxw:
        s = maxw / (x1 - x0)
    return raw.transform(s, 0, 0, s, cx - (x0 + x1) / 2 * s, cy - (y0 + y1) / 2 * s)


BIG_LBL = dict(h=430, maxw=560)


def ring_lbl(t):
    return union(ring(), label(t, **BIG_LBL))


def disc_lbl(t):
    return minus(disc(), label(t, **BIG_LBL))


SH = (40, CY - 300, 984, CY + 300, 170)  # 肩键：圆角横条


def sh_lbl(t):
    return union(rrect_ring(*SH, w=60), label(t, 340, maxw=640))


def shf_lbl(t):
    return minus(rrect(*SH), label(t, 340, maxw=640))


BOX = (CX - 450, CY - 450, CX + 450, CY + 450, 70)


def box_lbl(t, h=520):
    return union(rrect_ring(*BOX, w=60), label(t, h, maxw=700))


def boxf_lbl(t, h=520):
    return minus(rrect(*BOX), label(t, h, maxw=700))


def plus_shape(a, r, cx=CX, cy=CY):
    return poly(
        [
            (cx - a, cy + r),
            (cx + a, cy + r),
            (cx + a, cy + a),
            (cx + r, cy + a),
            (cx + r, cy - a),
            (cx + a, cy - a),
            (cx + a, cy - r),
            (cx - a, cy - r),
            (cx - a, cy - a),
            (cx - r, cy - a),
            (cx - r, cy + a),
            (cx - a, cy + a),
        ]
    )


DIRS = {"u": math.pi / 2, "d": -math.pi / 2, "l": math.pi, "r": 0.0}


def tri(d, s, cx, cy):
    return poly(xf([(s, 0), (-s * 0.6, s * 0.85), (-s * 0.6, -s * 0.85)], DIRS[d], 1, cx, cy))


def dpad(filled=False, marks="", kind="tri"):
    a, r, w = 175, 480, 64
    base = plus_shape(a, r) if filled else minus(plus_shape(a, r), plus_shape(a - w, r - w))
    ms = []
    for d in marks:
        ox, oy = {"u": (0, 300), "d": (0, -300), "l": (-300, 0), "r": (300, 0)}[d]
        if kind == "sq":
            ms.append(
                poly(
                    [
                        (CX + ox - 55, CY + oy - 55),
                        (CX + ox + 55, CY + oy - 55),
                        (CX + ox + 55, CY + oy + 55),
                        (CX + ox - 55, CY + oy + 55),
                    ]
                )
            )
        else:
            ms.append(tri(d, 75, CX + ox, CY + oy))
    return minus(base, *ms) if filled else union(base, *ms)


def four(filled: str):
    ps = []
    for d, (ox, oy) in (("t", (0, 310)), ("r", (310, 0)), ("b", (0, -310)), ("l", (-310, 0))):
        ps.append(disc(CX + ox, CY + oy, 165) if d in filled else ring(CX + ox, CY + oy, 165, 52))
    return union(*ps)


def power(cx=CX, cy=CY, s=1.0):
    r, w = 250 * s, 72 * s
    arc = minus(
        ring(cx, cy, r, w),
        poly([(cx, cy), (cx - 190 * s, cy + 400 * s), (cx + 190 * s, cy + 400 * s)]),
    )
    bar = rrect(cx - w / 2, cy + 10 * s, cx + w / 2, cy + 320 * s, w / 2)
    return union(arc, bar)


def house(cx=CX, cy=CY, s=1.0):
    body = poly(
        [
            (cx - 250 * s, cy - 250 * s),
            (cx + 250 * s, cy - 250 * s),
            (cx + 250 * s, cy + 40 * s),
            (cx + 330 * s, cy + 40 * s),
            (cx, cy + 300 * s),
            (cx - 330 * s, cy + 40 * s),
            (cx - 250 * s, cy + 40 * s),
        ]
    )
    door = poly(
        [
            (cx - 70 * s, cy - 250 * s),
            (cx + 70 * s, cy - 250 * s),
            (cx + 70 * s, cy - 40 * s),
            (cx - 70 * s, cy - 40 * s),
        ]
    )
    return minus(body, door)


def arrow(ang, s=1.0, double=False):
    if double:
        pts = [
            (-440, 0),
            (-120, 270),
            (-120, 95),
            (120, 95),
            (120, 270),
            (440, 0),
            (120, -270),
            (120, -95),
            (-120, -95),
            (-120, -270),
        ]
    else:
        pts = [(-420, 95), (80, 95), (80, 280), (440, 0), (80, -280), (80, -95), (-420, -95)]
    return poly(xf(pts, ang, s))


def thin_arrow(ang):
    return union(
        stroke(xf([(-400, 0), (400, 0)], ang)), stroke(xf([(150, 250), (400, 0), (150, -250)], ang))
    )


def chevron(ang):
    return stroke(xf([(-180, 380), (180, 0), (-180, -380)], ang), 80)


def cross(s=1.0, w=150):
    a = rrect(CX - 430 * s, CY - w / 2, CX + 430 * s, CY + w / 2, w / 4)
    return union(a.transform(*_rot(math.pi / 4)), a.transform(*_rot(-math.pi / 4)))


def _rot(ang):
    c, n = math.cos(ang), math.sin(ang)
    return (c, n, -n, c, CX - c * CX + n * CY, CY - n * CX - c * CY)


def stick(lbl=None, filled=False, pressed=False):
    dy = -150 if pressed else 0
    top = (CX, CY + 150 + dy, 470, 280)
    head = ellipse(*top)
    if filled:
        head = minus(head, label(lbl, 280, CX, top[1])) if lbl else head
    else:
        head = minus(head, ellipse(CX, top[1], 405, 215))
        if lbl:
            head = union(head, label(lbl, 280, CX, top[1]))
    stem = rrect(CX - 180, CY - 360 + dy, CX + 180, top[1] - 200, 30)
    base = ellipse(CX, CY - 370 + dy, 340, 95)
    ps = [head, minus(union(stem, base), ellipse(*top))]
    if pressed:
        ps.append(tri("d", 120, CX, CY + 440))
    return union(*ps)


def placeholder():
    return rrect_ring(CX - 400, CY - 400, CX + 400, CY + 400, 110, 56)


def icon_table():
    T = {}
    for cps, ch in (
        (range(0xE000, 0xE004), "ABXY"),
        (range(0xE0A0, 0xE0A4), "ABXY"),
        (range(0xE04C, 0xE050), "abxy"),
    ):
        for cp, c in zip(cps, ch, strict=True):
            T[cp] = lambda c=c: ring_lbl(c)
    T[0xE042] = lambda: ring_lbl("A")
    T[0xE04A] = lambda: ring_lbl("c")
    T[0xE047] = lambda: ring_lbl("1")
    T[0xE048] = lambda: ring_lbl("2")
    for cp, t in zip(range(0xE0E0, 0xE0E4), "ABXY", strict=True):
        T[cp] = lambda t=t: disc_lbl(t)
    for cps, ts in (
        ((0xE004, 0xE005), ("L", "R")),
        ((0xE052, 0xE053), ("L", "R")),
        ((0xE083, 0xE084, 0xE085, 0xE086), ("L", "R", "ZL", "ZR")),
        ((0xE054, 0xE055), ("ZL", "ZR")),
        (range(0xE0A4, 0xE0AA), ("L", "R", "ZL", "ZR", "SL", "SR")),
    ):
        for cp, t in zip(cps, ts, strict=True):
            T[cp] = lambda t=t: sh_lbl(t)
    T[0xE043] = lambda: sh_lbl("B")
    T[0xE04B] = lambda: sh_lbl("Z")
    for cp, t in zip(range(0xE0E4, 0xE0EA), ("L", "R", "ZL", "ZR", "SL", "SR"), strict=True):
        T[cp] = lambda t=t: shf_lbl(t)
    # 十字键
    for cp in (0xE006, 0xE041, 0xE0D0):
        T[cp] = lambda: dpad()
    for cp, m in zip(range(0xE079, 0xE07F), ("u", "d", "l", "r", "ud", "lr"), strict=True):
        T[cp] = lambda m=m: dpad(marks=m, kind="sq")
    for cp, m in zip(range(0xE0D1, 0xE0D7), ("u", "d", "l", "r", "ud", "lr"), strict=True):
        T[cp] = lambda m=m: dpad(marks=m)
    T[0xE110] = lambda: dpad(filled=True)
    for cp, m in zip(range(0xE111, 0xE117), ("u", "d", "l", "r", "ud", "lr"), strict=True):
        T[cp] = lambda m=m: dpad(filled=True, marks=m)
    # ABXY 四键位置示意（实心 = 指那颗键）
    for cp, f in (
        (0xE0AA, ""),
        (0xE0AB, "r"),
        (0xE0AC, "b"),
        (0xE0AD, "t"),
        (0xE0AE, "l"),
        (0xE0CA, "rb"),
        (0xE0CB, "lr"),
        (0xE0CC, "trb"),
        (0xE0CD, "lrb"),
        (0xE0CE, "tl"),
        (0xE0CF, "tr"),
        (0xE0EA, "trbl"),
    ):
        T[cp] = lambda f=f: four(f)
    for cp, d in zip(range(0xE0AF, 0xE0B3), "udlr", strict=True):
        T[cp] = lambda d=d: union(ring(), tri(d, 230, CX, CY))
    for cp, d in zip(range(0xE0EB, 0xE0EF), "udlr", strict=True):
        T[cp] = lambda d=d: minus(disc(), tri(d, 230, CX, CY))
    # + / −
    pl, mi = plus_shape(75, 280), rrect(CX - 280, CY - 75, CX + 280, CY + 75, 10)
    for cp in (0xE045, 0xE0B3):
        T[cp] = lambda: union(ring(), pl)
    for cp in (0xE046, 0xE0B4):
        T[cp] = lambda: union(ring(), mi)
    T[0xE0EF] = lambda: minus(disc(), pl)
    T[0xE0F0] = lambda: minus(disc(), mi)
    T[0xE0B5] = lambda: minus(plus_shape(150, 450), plus_shape(95, 395))
    T[0xE0B6] = lambda: rrect_ring(CX - 450, CY - 150, CX + 450, CY + 150, 30, 55)
    T[0xE0F1] = lambda: plus_shape(140, 450)
    T[0xE0F2] = lambda: rrect(CX - 450, CY - 140, CX + 450, CY + 140, 30)
    # 电源 / HOME / 截图
    for cp in (0xE040, 0xE0B7):
        T[cp] = lambda: union(ring(), power(s=0.95))
    T[0xE0B8] = lambda: power(s=1.6)
    T[0xE078] = lambda: union(rrect_ring(*BOX, w=60), power(s=1.1))
    T[0xE0F3] = lambda: minus(disc(), power(s=0.95))
    for cp in (0xE044, 0xE0B9):
        T[cp] = lambda: union(ring(), house(s=0.95))
    T[0xE0F4] = lambda: minus(disc(), house(s=0.95))
    T[0xE073] = lambda: house(s=1.55)
    T[0xE075] = lambda: union(
        ring(), minus(rrect(CX - 210, CY - 210, CX + 210, CY + 210, 40), disc(CX, CY, 120))
    )
    T[0xE0BA] = lambda: union(rrect_ring(*BOX, w=60), ring(CX, CY, 260, 64))
    T[0xE0F5] = lambda: minus(rrect(*BOX), ring(CX, CY, 260, 64))
    # 摇杆
    T[0xE080] = T[0xE0C0] = lambda: stick()
    T[0xE081] = T[0xE0C1] = lambda: stick("L")
    T[0xE082] = T[0xE0C2] = lambda: stick("R")
    T[0xE100] = lambda: stick(filled=True)
    T[0xE101] = lambda: stick("L", filled=True)
    T[0xE102] = lambda: stick("R", filled=True)
    T[0xE0C3] = lambda: stick(pressed=True)
    T[0xE0C4] = T[0xE08A] = lambda: stick("L", pressed=True)
    T[0xE0C5] = T[0xE08B] = lambda: stick("R", pressed=True)
    T[0xE103] = lambda: stick(filled=True, pressed=True)
    T[0xE104] = lambda: stick("L", filled=True, pressed=True)
    T[0xE105] = lambda: stick("R", filled=True, pressed=True)
    T[0xE077] = lambda: ring()
    T[0xE049] = lambda: union(ring(), ring(CX, CY, 330, 40))
    T[0xE050] = lambda: union(ring(), ring(CX, CY, 380, 30), label("L", 360))
    T[0xE051] = lambda: union(ring(), ring(CX, CY, 380, 30), label("R", 360))
    # 箭头
    for cp, a in zip(
        (0xE019, 0xE01A, 0xE01B, 0xE01C), (0, math.pi, math.pi / 2, -math.pi / 2), strict=True
    ):
        T[cp] = lambda a=a: arrow(a, 0.9)
    for cp, a in zip(
        range(0xE090, 0xE098),
        (
            0,
            math.pi,
            math.pi / 2,
            -math.pi / 2,
            math.pi / 4,
            -math.pi / 4,
            -3 * math.pi / 4,
            3 * math.pi / 4,
        ),
        strict=True,
    ):
        T[cp] = lambda a=a: arrow(a)
    T[0xE08C] = lambda: arrow(0, double=True)
    T[0xE08D] = lambda: arrow(math.pi / 2, double=True)
    for cp, a in zip(range(0xE143, 0xE147), (math.pi / 2, -math.pi / 2, math.pi, 0), strict=True):
        T[cp] = lambda a=a: thin_arrow(a)
    for cp, a in zip(range(0xE147, 0xE14B), (math.pi / 2, -math.pi / 2, math.pi, 0), strict=True):
        T[cp] = lambda a=a: chevron(a)
    T[0xE14B] = lambda: stroke(
        [(CX - 380, CY + 20), (CX - 120, CY - 260), (CX + 400, CY + 300)], 80
    )
    T[0xE14C] = lambda: union(
        stroke([(CX - 360, CY + 360), (CX + 360, CY - 360)], 80),
        stroke([(CX - 360, CY - 360), (CX + 360, CY + 360)], 80),
    )
    T[0xE098] = lambda: cross()
    T[0xE070] = lambda: union(rrect_ring(*BOX, w=60), cross(0.55, 110))
    T[0xE071] = lambda: minus(rrect(*BOX), cross(0.55, 110))
    # ! ? i / 禁止
    T[0xE140] = lambda: ring_lbl("!")
    T[0xE142] = lambda: ring_lbl("?")
    T[0xE14D] = lambda: ring_lbl("i")
    T[0xE141] = lambda: box_lbl("!")
    T[0xE150] = lambda: disc_lbl("!")
    T[0xE152] = lambda: disc_lbl("?")
    T[0xE153] = lambda: disc_lbl("i")
    for cp in (0xE010, 0xE151):
        T[cp] = lambda: boxf_lbl("!")
    for cp in (0xE011, 0xE06B):
        T[cp] = lambda: boxf_lbl("?")
    T[0xE14E] = lambda: union(
        ring(),
        pathops.op(
            rrect(CX - 480, CY - 40, CX + 480, CY + 40, 10).transform(*_rot(-math.pi / 4)),
            disc(CX, CY, R - 32),
            pathops.PathOp.INTERSECTION,
        ),
    )
    # 其他几何
    T[0xE016] = lambda: poly([(CX, CY + 460), (CX + 400, CY), (CX, CY - 460), (CX - 400, CY)])
    T[0xE01D] = lambda: union(ring(), disc(CX, CY, 200))
    for cp, t in zip(range(0xE029, 0xE02D), "ABCD", strict=True):
        T[cp] = lambda t=t: box_lbl(t)
    T[0xE02D] = lambda: boxf_lbl("A")
    T[0xE02E] = lambda: boxf_lbl("M")
    for cp, t in zip(range(0xE030, 0xE036), "PICTHA", strict=True):
        T[cp] = lambda t=t: label(t, 760, maxw=760)
    T[0xE057] = lambda: stroke(
        [(CX - 300, CY - 40), (CX - 300, CY - 230), (CX + 300, CY - 230), (CX + 300, CY - 40)], 60
    )
    T[0xE068] = lambda: label("er", 330, CX, CY + 270)
    T[0xE069] = lambda: label("re", 330, CX, CY + 270)
    T[0xE06A] = lambda: label("e", 330, CX, CY + 270)
    T[0xE089] = lambda: box_lbl("TV", 380)
    T[0xE13A] = lambda: box_lbl("TV", 380)
    T[0xE139] = lambda: box_lbl("PC", 380)
    T[0xE121] = lambda: union(
        rrect_ring(CX - 490, CY - 250, CX + 490, CY + 250, 110, 56),
        rrect(CX - 290, CY - 170, CX + 290, CY + 170, 10),
    )
    T[0xE137] = lambda: union(
        rrect_ring(CX - 450, CY - 310, CX + 450, CY + 310, 40, 56),
        stroke([(CX - 400, CY + 260), (CX, CY - 40), (CX + 400, CY + 260)], 56),
    )
    T[0xE138] = lambda: union(
        rrect_ring(CX - 230, CY - 470, CX + 230, CY + 470, 70, 56),
        rrect(CX - 70, CY - 400, CX + 70, CY - 360, 20),
    )
    rays = [
        stroke(
            [
                (CX + 270 * math.cos(k * math.pi / 4), CY + 270 * math.sin(k * math.pi / 4)),
                (CX + 430 * math.cos(k * math.pi / 4), CY + 430 * math.sin(k * math.pi / 4)),
            ],
            70,
        )
        for k in range(8)
    ]
    T[0xE130] = lambda: union(disc(CX, CY, 180), *rays)
    return T


def glyph_from_path(path):
    path = pathops.simplify(path, fix_winding=True, keep_starting_points=False, clockwise=True)
    tt = TTGlyphPen(None)
    path.draw(Cu2QuPen(tt, 1.0, reverse_direction=False))
    g = tt.glyph()
    ap = AreaPen()
    path.draw(ap)
    if ap.value >= 0 and g.numberOfContours > 0:
        raise AssertionError("图标外轮廓方向不是顺时针（TrueType 要顺时针）")
    return g


def build_icon_font(cps, family: str):
    order = [".notdef", "NULL", "CR", "space", "uni25A0", "uni25A1", "uni3000"]
    cmap = {
        0x0: "NULL",
        0xD: "CR",
        0x20: "space",
        0x25A0: "uni25A0",
        0x25A1: "uni25A1",
        0x3000: "uni3000",
    }
    T = icon_table()
    empty = TTGlyphPen(None).glyph()
    ph = glyph_from_path(placeholder())
    glyphs = {
        ".notdef": ph,
        "NULL": empty,
        "CR": empty,
        "space": empty,
        "uni3000": empty,
        "uni25A0": glyph_from_path(rrect(CX - 400, CY - 400, CX + 400, CY + 400, 0)),
        "uni25A1": glyph_from_path(rrect_ring(CX - 400, CY - 400, CX + 400, CY + 400, 0, 56)),
    }
    adv = {
        ".notdef": ADV,
        "NULL": 0,
        "CR": 500,
        "space": 500,
        "uni3000": ADV,
        "uni25A0": ADV,
        "uni25A1": ADV,
    }
    drawn = []
    for cp in cps:
        n = f"uni{cp:04X}"
        order.append(n)
        cmap[cp] = n
        adv[n] = ADV
        if cp in T:
            glyphs[n] = glyph_from_path(T[cp]())
            drawn.append(cp)
        else:
            glyphs[n] = ph
    fb = FontBuilder(UPEM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    glyf = fb.font["glyf"]
    fb.setupHorizontalMetrics({n: (adv[n], getattr(glyf[n], "xMin", 0)) for n in order})
    fb.setupHorizontalHeader(ascent=ASC, descent=DESC)
    ps = family.replace(" ", "")
    fb.setupNameTable(
        {
            "copyright": "Copyright 2026 The S2Arm Authors. Letterforms derived from Noto Sans, "
            "Copyright 2022 The Noto Project Authors.",
            "familyName": family,
            "styleName": "Regular",
            "uniqueFontIdentifier": f"{ps}-Regular;1.000",
            "fullName": f"{family} Regular",
            "version": "Version 1.000",
            "psName": f"{ps}-Regular",
            "licenseDescription": "This Font Software is licensed under the SIL Open Font License, "
            "Version 1.1.",
            "licenseInfoURL": "https://openfontlicense.org",
        }
    )
    fb.setupOS2(
        sTypoAscender=ASC,
        sTypoDescender=DESC,
        sTypoLineGap=0,
        usWinAscent=ASC,
        usWinDescent=-DESC,
        achVendID="S2A ",
        fsType=0,
    )
    fb.setupPost()
    fb.setupMaxp()
    return to_bytes(fb.font), drawn


# ---------- 主流程 ----------
def main():
    global LETTERS
    ap = argparse.ArgumentParser(description="生成开源替代共享字体（7 个 .bfttf）")
    ap.add_argument("outdir")
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    bold = static_instance("latin", {"wght": 700, "wdth": 100})
    LETTERS = (bold.getGlyphSet(), bold.getBestCmap())

    ttf = build_text_fonts(charsets())
    ttf["ext"], drawn = build_icon_font(EXT_PUA, "S2Arm Pad Icons")
    ttf["ext2"], drawn2 = build_icon_font(EXT2_PUA, "S2Arm Pad Icons Ext")

    rows, total = [], 0
    for k, fn in FILES.items():
        b = encode_bfttf(ttf[k])
        if decode_bfttf(b) != ttf[k]:
            sys.exit(f"🔴 {fn} 编码后解不回原 TTF")
        open(os.path.join(a.outdir, fn), "wb").write(b)
        cps = len(TTFont(io.BytesIO(ttf[k])).getBestCmap())
        if k in LOADED:
            total += 8 + len(ttf[k])
        rows.append(f"{fn}\t{len(b)}\t{hashlib.sha256(b).hexdigest()}\t{cps}")
    for key, dst in (("ofl_cjk", "OFL-NotoSansCJK.txt"), ("ofl_latin", "OFL-NotoSans.txt")):
        open(os.path.join(a.outdir, dst), "wb").write(open(fetch(key), "rb").read())
    open(os.path.join(a.outdir, "MANIFEST.tsv"), "w").write(
        "文件\t字节\tsha256\t码位数\n" + "\n".join(rows) + "\n"
    )
    print("\n".join(rows))
    print(
        f"图标：ext 画了 {len(drawn)} 个、ext2 画了 {len(drawn2)} 个，其余私用区码位用圆角方块占位"
    )
    print(
        f"共享内存账：6 个装载字体 + 头 = {total} 字节，上限 {SHARED_FONT_MEM}，余 {SHARED_FONT_MEM - total}"
    )
    if total > SHARED_FONT_MEM:
        sys.exit("🔴 超出 Ryujinx 共享字体内存上限（Horizon.FontSize），起服务会抛异常")
    print(f"✅ 7 个字体已写到 {a.outdir}")


if __name__ == "__main__":
    main()

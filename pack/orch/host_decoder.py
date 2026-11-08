#!/usr/bin/env python3
"""这一款要不要游戏自带解码器（Oodle / LZ5）：从解包后的 RomFS 文件头判，给 Windows 出包机（天眼）起跑前分流用。
起因（11-05 总指挥）：c1105_ty3 勇者斗恶龙 XI S 在天眼跑到直连抽取才报「Oodle- or LZ5-compressed game files: set DM_OODLE_HOST」——
  这类块只有游戏自带的解码器能解，要借 Mac 宿主的工具模式跑（runtime/src/oodle_tool.c，translator/uepak.py OodleHost），Windows 没有这条路。
  pack/orch/oneclick_win.py 解包后、轻阶段前调 need()，要就退 75（环境缺件），天眼道（tools/tianyan_lane.py）据此落回 Mac 出包。
只读文件头与容器头 / 索引，不解任何块；各格式只用现成读取器（unreal_pak.footer、uepak.Toc / TOC_MAGIC、pkz.index_entries；Trinity 魔数同 shader_split.ONEPACK），
  RomFS 遍历只经 graphics/nvn/tools/romfs_list.py（仓库里唯一的遍历，读头结果按身份落清单，后面各阶段命中不再读盘）。
判法（宁可多判不漏判：多判只是这款回 Mac 出，漏判是天眼跑到一半才红）：
  · Unreal pak 版本 ≥ 8：文件尾压缩方法名表里有 Oodle* / LZ5
  · Unreal pak 版本 1–7（勇者斗恶龙 XI S）：压缩方式是逐条目的标志位（3 = LZ5、4 = Oodle）、索引常加密，不解索引——一律算要
  · IoStore（.utoc）：方法名表里有 Oodle*；容器头加密读不出方法名的也算要
  · Trinity（魔数 ONEPACK + 同名 .trpfd，宝可梦传说 Z-A）：着色器全在 Oodle 条目里（docs/研究/trpfs容器_1500256797.md）
  · PKZ（魔数 pkzl，猎天使魔女 3）：成员压缩方式有 Oodle*
  · HGPAK（无人深空 NMSARC.*.pak）：压缩档案里有块的存储长既不是 0x20000 也不是该块原长（= Oodle 块，同 hgpak.Hgpak.chunk 的判法）
  · id Tech 7 资源包（IDCL 版本 12，DOOM Eternal）：着色器条目（idtech_idcl.TYPES）有压缩的（Oodle Kraken）
用法：host_decoder.py <RomFS 或追加内容目录>…   要 → 打印原因、退 1；不要 → 退 0"""
import mmap, os, struct, sys
from pathlib import Path

R = Path(__file__).resolve().parents[2]
for d in ('graphics/nvn/tools', 'translator', 'graphics/tools/shbake'): sys.path.insert(0, str(R / d))
import romfs_list   # noqa: E402
import hgpak        # noqa: E402
import idtech_idcl  # noqa: E402
import pkz          # noqa: E402
import unreal_pak   # noqa: E402

ONEPACK = b'ONEPACK\0'   # = translator/shader_split.py ONEPACK（单测核两边相等）
GAME_CODEC = ('Oodle', 'LZ5')


def _game_codec(names): return [n for n in names if n and n.startswith(GAME_CODEC)]


def _pak(path):
    with open(path, 'rb') as f: ft = unreal_pak.footer(f, os.fstat(f.fileno()).st_size)
    if ft is None: return None
    if ft['methods'] is None: return f'旧版 Unreal pak（版本 {ft["version"]}，压缩方式在逐条目标志里，LZ5 / Oodle 要游戏解码器）'
    hit = _game_codec(ft['methods'])
    return f'Unreal pak 压缩方式 {"/".join(hit)}' if hit else None


def _utoc(path):
    import uepak
    try: hit = _game_codec(uepak.Toc(path).methods)
    except ValueError as e: return f'IoStore 容器头读不出压缩方式（{e}），按要算'
    return f'IoStore 压缩方式 {"/".join(hit)}' if hit else None


def _pkz(path):
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        try: hit = sorted({e.compression for e in pkz.index_entries(m) if pkz.is_oodle(e.compression)})
        except pkz.FormatError: return None
    return f'PKZ 成员压缩方式 {"/".join(hit)}' if hit else None


def _hgpak(path):   # 11-05 天眼普查无人深空：这一格式原先没判，跑到抽取才红「hgpak：目录读不了（没有 Mac 宿主）」
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        try: h = hgpak.hgpak_header(m)
        except (ValueError, struct.error) as e: return f'HGPAK 目录读不出（{e}），按要算'
        if not h or not h['comp']: return None
        total = max((o + n for _, o, n in h['files']), default=0)
        k = sum(1 for i, s in enumerate(h['csz']) if s not in (hgpak.CHUNK, min(hgpak.CHUNK, total - h['D'] - hgpak.CHUNK * i)))
    return f'HGPAK {k} 个 Oodle 块' if k else None


def _idcl(path):
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        try: k = sum(1 for t, _, _, _, _, how in idtech_idcl.entries(m) if t in idtech_idcl.TYPES and how)
        except (ValueError, struct.error) as e: return f'id Tech 资源包目录读不出（{e}），按要算'
    return f'id Tech 资源包 {k} 个压缩着色器条目（Oodle Kraken）' if k else None


def need(dirs):
    """→ 原因列表（每条「相对路径：原因」，空 = 不要游戏解码器）"""
    import uepak
    why = []
    for d in dirs:
        if not os.path.isdir(d): continue
        for e in romfs_list.heads(d).files():
            if e.error is not None: continue
            h, n = e.head or b'', e.name.lower()
            r = (_hgpak(e.path) if h[:8] == hgpak.MAGIC   # 先按魔数：无人深空的 HGPAK 也叫 .pak（NMSARC.*.pak），按扩展名会当 Unreal pak 判成不要
                 else _pak(e.path) if n.endswith('.pak') else _utoc(e.path) if h[:16] == uepak.TOC_MAGIC
                 else ('Trinity 包（ONEPACK，着色器在 Oodle 条目里）' if h[:8] == ONEPACK and os.path.exists(e.path[:-1] + 'd') else None) if n.endswith('.trpfs')
                 else _pkz(e.path) if h[:4] == b'pkzl' else _idcl(e.path) if idtech_idcl.recognize(h) else None)
            if r: why.append(f'{e.rel}：{r}')
    return why


if __name__ == '__main__':
    w = need(sys.argv[1:])
    for l in w[:5]: print(l)
    if len(w) > 5: print(f'…共 {len(w)} 处')
    sys.exit(1 if w else 0)

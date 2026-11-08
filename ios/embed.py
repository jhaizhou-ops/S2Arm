# 写游戏镜像包 Frameworks/S2AImages.dylib（11-04 阶段 0 全外置，jhz 定为 Mac / Windows 出 iOS 包的唯一路径；原「生成内嵌汇编、编进主程序」已删）。
#   主程序 = 与游戏无关的预编壳（pack/shell_build.sh）；全部游戏模块（main / sdk / subsdk* / nn::ro 装的 NRO）的改写映像写进本包，
#   运行时 runtime/src/imgpack.c 注册签名后按需 MAP_FIXED 映射进窗口（接口见 docs/接口_原生层.md「外置镜像包」）。纯 Python（ios/macho_dylib.py），
#   不经 Apple 链接器，Windows / Mac 同一写法、同输入逐字节相同；文件自带预留签名区与链接器式 ad-hoc 签名，重签工具原地替换。
# 每个模块切 3–4 块：
#   x0   原 text：[0, 圆整16K(TEXT_END))；有装载偏置 LOAD_BIAS = b 时块首先补 b 个零字节、取 [−b, 网格圆整(TEXT_END))
#   W    可写：[圆整16K(TEXT_END), PATCH_OFF)（非 FAR）或 [../runtime, FILE_IMAGE_LEN)（FAR）：ro 余部 + data（+ bss）
#   x1   补丁区
#   x2   双补丁岛的另一个岛（表头有 PATCH2_OFF 才有）：patched.bin 末尾 PATCH2_LEN 字节，补到 16K
# 布局：全部代码块（x0 / x1 / x2）依次进 __TEXT,__swcode（纯指令节），全部 W 块依次进 __SWDATA,__img，每块起点与长度都是 16K 整数倍；
#   偏移表 __TEXT,__swidx（小端）：8 字节魔数 "S2AEMB01"、u32 模块数、u32 每项字节数（88），每项 = 名字 24 字节（补 0）+ 4 × (u64 偏移, u64 长度)，
#   顺序 x0 / W / x1 / x2（x2 没有时长度 0；代码块偏移相对 __swcode 起点，W 相对 __img 起点），按模块名参数的顺序排。
#   不论多少模块都只有 3 节（马力欧派对 130 个模块原先每模块独占节，超过 Mach-O 255 节上限）。
# 用法：embed.py <改写产物目录> <输出 .dylib> <模块名…>；模块名可写成 <包内名>=<相对产物目录的文件前缀>（多程序合集序号 n：p<n>/main=programs/<n>/main，
#   装载器按 p<n>/<名> 查，runtime/src/loader.c g_img_ns）
import os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import macho_dylib
if len(sys.argv) < 4: sys.exit('用法：embed.py <改写产物目录> <输出 .dylib> <模块名…>')
out, dst, names = sys.argv[1], sys.argv[2], sys.argv[3:]
PG = 0x4000
def r16(x): return (x + PG - 1) & ~(PG - 1)
def layout(names):
    code, data, idx = [], [], []   # 代码块 / W 块：(名, 源文件, 前导零, 源偏移, 源长度, 块长)；偏移表项：(名, [(偏移, 长度)] × 4)
    coff = doff = 0
    for n in names:
        n, stem = n.split('=', 1) if '=' in n else (n, n)
        hdr = dict(l[2:].split(None, 1) for l in open(f'{out}/{stem}.fixups.tsv') if l.startswith('# '))
        hdr = {k: v.strip() for k, v in hdr.items()}
        te, po = int(hdr['TEXT_END'], 16), int(hdr['PATCH_OFF'], 16)
        ko, ks = int(hdr['KEY_PAGE_OFF'], 16), int(hdr['KEY_PAGE_SIZE'], 16)
        lb = int(hdr.get('LOAD_BIAS', '0'), 16)   # 装载偏置：各切点按 r16(x + lb) − lb 的网格取（lb = 0 时同原式）
        b = os.path.abspath(f'{out}/{stem}.patched.bin'); sz_all = os.path.getsize(b); a = r16(te + lb) - lb
        l2 = int(hdr.get('PATCH2_LEN', '0'), 16) if 'PATCH2_OFF' in hdr else 0   # 双补丁岛：文件末尾 l2 字节是另一个岛，前面照原布局切
        sz = sz_all - l2
        end = (po + r16(sz - po)) if po >= 0 else r16(sz)
        if len(n.encode()) > 23: sys.exit(f'【红】模块名 {n} 太长（偏移表名字 ≤23 字节）')
        if po < 0:   # FAR：patched.bin = 映像前段 [0, FILE_IMAGE_LEN) + 补丁区；bss 与键页运行时是零页，不进可执行文件
            fl = int(hdr['FILE_IMAGE_LEN'], 16)
            assert fl % PG == 0 and a <= fl < sz and ks == PG and not lb, (n, hex(fl), hex(sz), hex(lb))
            cuts = (('x0', 0, a), ('W', a, fl), ('x1', fl, end))
        else:
            assert (po + lb) % PG == 0 and a <= ko and ko + ks <= po and (ko + lb) % PG == 0 and ks == PG, (n, hex(po), hex(ko), hex(lb))
            cuts = (('x0', 0, a), ('W', a, po), ('x1', po, end))
        assert 0 <= l2 <= sz_all and l2 % 4 == 0, (n, hex(l2), hex(sz_all))
        if l2: cuts += (('x2', sz, sz + r16(l2)),)   # 另一个岛是空的就不出块（装载器按 PATCH2_LEN 判要不要找它）
        ent = {k: (0, 0) for k in ('x0', 'W', 'x1', 'x2')}
        for kind, lo, hi in cuts:
            fill = min(hi, sz_all if kind == 'x2' else sz) - lo
            pre = lb if lb and lo == 0 else 0
            ln = pre + hi - lo
            assert ln % PG == 0 and 0 <= fill <= hi - lo, (n, kind, hex(ln), hex(fill))   # 块长 16K 整数倍：vm_remap 按整页取
            if kind == 'W': data.append((b, pre, lo, fill, ln)); ent[kind] = (doff, ln); doff += ln
            else: code.append((b, pre, lo, fill, ln)); ent[kind] = (coff, ln); coff += ln
        idx.append((n, [ent[k] for k in ('x0', 'W', 'x1', 'x2')]))
    return code, data, idx

def index_bytes(idx):
    b = b'S2AEMB01' + struct.pack('<II', len(idx), 88)
    for n, ents in idx: b += n.encode().ljust(24, b'\0') + b''.join(struct.pack('<QQ', off, ln) for off, ln in ents)
    return b
def blocks(bs):   # 每块：前导零、文件里的一段、尾部补零
    out = []
    for b, pre, lo, fill, ln in bs:
        if pre: out.append(pre)
        if fill: out.append((b, lo, fill))
        if ln - pre - fill: out.append(ln - pre - fill)
    return out
def write_dylib(dst, names):
    code, data, idx = layout(names)
    off = macho_dylib.write(dst, '@rpath/S2AImages.dylib',
                            text=[('__swcode', 14, macho_dylib.PURE_INSTRUCTIONS, blocks(code)), ('__swidx', 3, 0, [index_bytes(idx)])],
                            data=('__SWDATA', [('__img', 14, 0, blocks(data) or [PG])]))
    assert off[('__TEXT', '__swcode')] % PG == 0 and off[('__SWDATA', '__img')] % PG == 0, off
if len(set(n.split('=', 1)[0] for n in names)) != len(names): sys.exit(f'【红】模块名重复：{names}')
write_dylib(dst, names)

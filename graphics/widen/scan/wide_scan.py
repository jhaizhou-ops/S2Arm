#!/usr/bin/env python3
"""宽屏第二层·离线候选扫描（出包时跑，零配置）：在游戏模块的原版映像里按指令 / 数据特征找「游戏自己按 16:9 算画面」的点，
出候选表，交给运行时闭环逐个试改、只留验证过的（见 graphics/widen/README.md「三层」）。特征来自 SDK / 引擎共性，不按游戏写死偏移：
  movz    显示宽度：MOVZ #宽（16:9 各档 1920/1280/1600/960/2560/3840/1024/640）与配对的 MOVZ #高（或 MOVK #高,LSL#32 打包）相距 ≤16 条
  movzh   显示高度：上面配对的那条纯 MOVZ #高（1080/720/900/540/1440/2160/576/360），窄屏加高用（宿主按屏高填值）
          浮点写法也收成 movz / movzh（11-03 Pokopia 主场景视口 = 缩放比 × 1920.0）：MOVZ Wd,#hi16(档宽.0f),LSL#16 与配对的 MOVZ Wd,#hi16(档高.0f),LSL#16
          相距 ≤24 条；改写器跳板同整数 movz（读值槽），宿主填 scale_w / scale_h 的完整浮点位
  f32     分辨率表：浮点对 (1920.0, 1080.0)，前后紧挨另一档 16:9 浮点对
  restab  动态分辨率档位表：代码段之后 4 字节对齐，n（4–64）个递增的 u32 宽紧跟 n 个 u32 高、逐档严格 16:9（11-03 Pokopia main 0x2756530：34 档
          960×540 每档 +32 宽 … 1920×1080 … 7680×4320，游戏按它建全部相对尺寸的缓冲）。出表首项，装载时宽表按屏宽、高表按屏高逐档改
  i32     整数分辨率表：代码段之后 4 字节对齐、连续两对以上的 32 位整数对 (宽, 宽×9/16)，宽是 16:9 档宽（10-26 丝之歌 Unity SwitchPlatform 两组记录：
          main 0x6679240 = 1280,720,1920,1080 / 0x666efa0 = 1024,576,1280,720；Touchable 改的就是它们，游戏按它建世界纹理与相机比例）。出表首项，装载时整表宽放大
  aspf    单独的 16:9 浮点常量：代码段之后（只读数据 / 数据）4 字节对齐的 0x3fe38e39 / 0x3fe38e3b、前后 32 字节内没有别的 16:9 常量，代码按地址读它当镜头宽高比
          （10-26 暗黑3 0xeb0b10 就是社区超宽屏补丁改的那个）；11 款主程序里每款至多 1 处（6 款各 1 处），装载时按屏幕比改写、不动代码
  aspdiv  3D 镜头宽高比除法：sead::PerspectiveProjection 构造——先存缺省 4:3（MOVZ #0xaaab + MOVK #0x3faa → [Xn,#off]），之后 FDIV 结果写回同一偏移；
          或按视口矩形算——FDIV Sd,Sn,Sm 紧跟在两条 FSUB（分别算出 Sn / Sm：矩形右减左、下减上）之后，结果马上 STR Sd,[Xk,#0xb0]（10-26 马车8 main 0x3cd314，
          社区超宽屏补丁改的就是这条；动森同形状。不靠款号，只认这一段形状；门里只在算出约等于 16:9 时才换，别的比例原样）；
          10-26 社区超宽屏补丁对照后放宽 / 加形状（见 _div_shape）：矩形写回偏移不限、getter（S0 + RET）；整数宽 ÷ 整数高（异度3 0xeb73ac）；宽 ÷ 常量画面高（银河 2 0x2fe4a0）
  aspstr  3D 镜头宽高比（参数直传）：STR S?,[Xn,#0xb0]，前 8 条内 STR S?,[Xn,#0xa8]，后 4 条内 STRB W?,[Xn,#8]（脏标记）
  asp     界面镜头宽高比：MOVZ #0x8e39 + MOVK #0x3fe3 拼出 16:9 浮点（0x3fe38e39）；也认 MOVZ #0x8e3b（0x3fe38e3b = 十进制 1.777778 舍入成的浮点，
          RE 引擎把纵向视角换算成横向时乘它）
  aspcap  宽高比上限（10-26 暗黑2：游戏把画面限在 19:9，更宽的屏幕两侧画黑柱）：MOVZ + MOVK 同一 W 寄存器拼出 19:9 / 21:9 浮点（0x40071c72 / 0x40155555），
          之后 8 条内先遇到的用法是 FMOV Sn,Wd（拿去算视口边距 / 坐标钳制）。装载时取 max(原值, 屏幕比)：屏幕不比上限宽时就是原值，自带守卫
  aspcaps 同上，但先遇到的用法是 STR Wd,[Xn,#imm]（整数存进常量缓冲交给着色器，暗黑2 界面边柱着色器按它画带柔边的黑柱）：屏幕宽于上限时再加 0.15，
          把柔边推出屏外（d2r-mobile dm/host/thread.c 的推导：柔边 ≤ 30 像素 / 900 高 ⇒ 至少 0.067，0.15 留一倍余量；按屏高比例，与分辨率无关）
  f2w     float2 宽高字面量：MOVZ Xd,#hi16(宽.0f),LSL#16，后 16 条内 MOVK Xd,#hi16(高.0f),LSL#48 拼出 (宽, 高) 一对浮点（宽 × 高是 16:9 档），
          中间没有别的指令以 Xd 为目标；只认 X 寄存器一次拼成 8 字节的写法（W 寄存器分两次拼的多是预设分辨率表的副本）
  i2h     整数版：MOVZ Xd,#宽 后 16 条内 MOVK Xd,#高,LSL#32 打包 (宽, 高) 一对 32 位整数（宽 × 高是 16:9 档），高半那条 MOVK；
          与 f2h 同一改写（装整个 8 字节），宿主低半照搭档 movz 的值、高半按屏高缩放（11-04 智慧的再现：渲染配置的宽高 1280 / 720）
  f2h     同一对的高半（11-04 满屏补丁线，智慧的再现高屏：场景视口 = 这对 (1280.0, 720.0)，f2w 只换宽、MOVK 照旧写回 720.0，窄屏场景不加高）：
          f2w 那条 MOVK Xd,#hi16(高.0f),LSL#48 本身；证据 = MOVK 字 + 配对的 MOVZ 字。改写成从值槽装整个 8 字节（宽 | 高 << 32），
          宿主填槽：低半照搭档 f2w 的开关取宽、高半启用时按屏高缩放（runtime/src/widen.c）
  lytsz   界面布局画布尺寸参与屏幕坐标换算：LDP Sa,Sb,[Xn,#0x28]，Xn 由前 40 条内的 LDR Xn,[Xm,#0xc0] 取得（nn::ui2d 绘制信息 → 布局 → 画布尺寸）、
          其间 Xn 没被别的指令改写、也没被调用冲掉。第二层把界面投影放宽到 画布宽·k 时，按「画布宽 / 2」换算的屏幕坐标与投影对不上
          （塞尔达ポーチ页：拷屏控件按 640 而不是 782 定中心，林克在 1421 列被切、画布外滑入拷屏控件贴出腿部碎片）
  seadasp sead 透视投影读宽高比（10-30 参考 SavageWind 旷野之息原生移植 tools/patches.py persp_matrix，MIT）：改读端而不是写端——找到 sead::PerspectiveProjection
          的建矩阵函数（叶子函数、同一基址读 近平面 +0x98 / tan(视角/2) 与宽高比 +0xac,+0xb0 / 偏移 +0xb4、往 [X1] 写一串浮点、拼 -1.0f），候选 = 它前后 0x600 字节内
          同族函数里每条读宽高比的指令（LDR St,[Xn,#0xb0]，或 LDP Sa,Sb,[Xn,#0xac] 第二个是宽高比；取边界 / 屏幕坐标反投影都在这里）。宿主门只在读到约 16:9 时换屏幕比，
          所有透视投影连同由它算出的 CPU 视锥剔除一起变宽（马车8 赛道两侧缺口的根因），正交投影（界面）不读这个字段。字段偏移按三款实测（塞尔达 0xda13f4 / 动森 0x37e5968 /
          马车8 0x61bfa4 同一布局），别的 sead 布局实测后加进 SEAD_LAYOUTS
  capsz   拷屏控件自身尺寸：LDP Sa,Sb,[X0,#0x50]（控件尺寸），同一函数里（往后 0x600 字节内、没遇到 RET）有 lytsz 点——拷屏绘制入口读整屏控件的宽高
底本：旧库 S2A tools/wide_find.py（10-14 动森手工找点后归纳，塞尔达补了 aspstr）；本版去掉界面控件观测点（旧库按游戏的界面层，新架构不用），输出改为候选表。
用法：wide_scan.py <exefs 目录或单个 NSO> [--tsv 输出] [--patch]（--patch：另打印旧宿主 NX_WIDE_PATCH 写法，试验台用）
候选表列：模块<TAB>偏移<TAB>种类<TAB>证据（十六进制指令字或浮点对）。
并行（10-25 jhz「多核加速……要适配机器的核心数」：动森出包这一步单进程 88 秒）：指令按区间分块、按本机核数（S2A_JOBS，缺省 os.cpu_count）开进程，
  每块只产出起点在本块的候选、前后窗口照读全段，结果合并后与逐条串行逐字节相同；capsz 要全段的 lytsz 位置，先并行出 lytsz 再并行出 capsz。"""
import multiprocessing, os, struct, sys
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）

CLS = ((1920, 1080), (1280, 720), (1600, 900), (960, 540), (2560, 1440), (3840, 2160), (1024, 576), (640, 360))   # 旧宿主 loader.c WIDE_CLS 同序


_TEXT_END = None   # 最近一次 load 的原版 NSO 代码段末（第二段 ro 的内存偏移）；平铺映像为 None（aspf 只认代码段之后的常量）


def load(path):
    """原版 NSO（按段 LZ4 解压铺成内存映像）或已铺好的映像。"""
    global _TEXT_END
    b = open(path, 'rb').read()
    if b[:4] != b'NSO0': _TEXT_END = None; return b
    b = _nso_plain(b, path)
    import lz4.block
    fl = struct.unpack_from('<I', b, 0xC)[0]; segs = []
    for k in range(3):
        fo, mo, sz = struct.unpack_from('<III', b, 0x10 + 0x10 * k); csz = struct.unpack_from('<I', b, 0x60 + 4 * k)[0]
        d = b[fo:fo + csz]; segs.append((mo, lz4.block.decompress(d, uncompressed_size=sz) if fl >> k & 1 else d[:sz]))
    _TEXT_END = segs[1][0]
    img = bytearray(max(mo + len(d) for mo, d in segs))
    for mo, d in segs: img[mo:mo + len(d)] = d
    return bytes(img)


def movz(w, v): return (w & 0x7FFFFFE0) == (0x52800000 | (v << 5))         # MOVZ W/X,#v
def movk16(w, v): return (w & 0x7FFFFFE0) == (0x72A00000 | (v << 5))       # MOVK W/X,#v,LSL#16
# 浮点位的高 16 位（16:9 各档宽 / 高的浮点低 16 位都是 0）
def fhi(x): return struct.unpack('<I', struct.pack('<f', float(x)))[0] >> 16
# 16:9 浮点 0x3fe38e39 / 0x3fe38e3b 的低 16 位
ASP_LO = (0x8e39, 0x8e3b)
F2W = {fhi(w): fhi(h) for w, h in CLS}
# 宽高比上限常量（低 16 位 → 高 16 位）：19:9 = 0x40071c72、21:9 = 0x40155555
CAP = {0x1c72: 0x4007, 0x5555: 0x4015}


def _cap_use(W, i, n, d):
    """MOVZ/MOVK 拼出上限后 Wd 第一次被用：FMOV Sn,Wd → 'aspcap'；STR Wd,[Xn,#imm] → 'aspcaps'；先被改写或 8 条内没用到 → None"""
    for j in range(i + 2, min(n, i + 10)):
        x = W[j]
        if (x & 0xFFFFFC00) == 0x1E270000 and (x >> 5) & 31 == d: return 'aspcap'
        if (x & 0xFFC00000) == 0xB9000000 and x & 31 == d: return 'aspcaps'
        if x & 31 == d or (x >> 5) & 31 == d or (x >> 10) & 31 == d or (x >> 16) & 31 == d: return None   # 别的读写一概不认（保守）
    return None


def ldp_s(w, imm, rn=None):
    """LDP Sa,Sb,[Xn,#imm]（32 位浮点、有符号偏移形态）；rn 给了就要求基址寄存器是它。"""
    return (w & 0xFFC00000) == 0x2D400000 and ((w >> 15) & 0x7f) * 4 == imm and (rn is None or (w >> 5) & 31 == rn)


def writes_reg(x, r):
    """x 会不会改写通用寄存器 r（保守：目标字段 = r 的非存储指令都算；BL / BLR 冲掉 x0–x18 与 x30）。"""
    if (x & 0xFC000000) == 0x94000000 or (x & 0xFFFFFC1F) == 0xD63F0000: return r <= 18 or r == 30
    if (x & 0x0A000000) == 0x08000000 and not (x >> 22) & 1: return False   # 存储类（取存指令族 L 位 = 0）：Rt 是源
    if (x & 0x0A000000) == 0x08000000 and (x & 0x3B000000) == 0x29000000 and (x >> 10) & 31 == r: return True   # LDP 的第二个目标
    return (x & 31) == r


_W = None; _N = 0; _LS = frozenset()   # 子进程（fork）直接读这几个全局：整段指令不经序列化传给每块


def _lyt_part(lo, hi):
    """lytsz（见模块说明）：起点 i ∈ [lo, hi)"""
    W, n = _W, _N; out = []
    for i in range(lo, hi):
        w = W[i]
        if not ldp_s(w, 0x28): continue
        rn = (w >> 5) & 31
        if rn == 31: continue
        for j in range(i - 1, max(-1, i - 41), -1):
            x = W[j]
            if (x & 0xFFFFFC1F) == (0xF9400000 | ((0xc0 // 8) << 10) | rn): out.append((i * 4, 'lytsz', '%08x' % w)); break
            if writes_reg(x, rn) or x == 0xD65F03C0: break
    return out


def _cap_part(lo, hi):
    """capsz（见模块说明）：起点 i ∈ [lo, hi)，同一函数里往后有 lytsz 点（_LS = 全段 lytsz 的指令下标）"""
    W, n, ls = _W, _N, _LS; out = []
    for i in range(lo, hi):
        if not ldp_s(W[i], 0x50, 0): continue
        for j in range(i + 1, min(n, i + 0x181)):
            if W[j] == 0xD65F03C0: break
            if j in ls: out.append((i * 4, 'capsz', '%08x' % W[i])); break
    return out


def _fuse(W, i, n):
    """MOVZ Wd 装的浮点位在 24 条内先被当浮点用：FMOV Sn,Wd / STR·STUR·STP Wd（浮点位存出去，如着色器常量）/ DUP·INS 进向量；
    之前 Wd 被改写（MOV 宽立即数 / LDR W / ADD·SUB 立即数 / 逻辑运算）或遇到 RET 不算——W 寄存器装了不用的多是预设分辨率表的副本（tests/widen_sites_test.sh 0x108）"""
    d = W[i] & 31
    for j in range(i + 1, min(n, i + 25)):
        x = W[j]
        if x == 0xD65F03C0: return False
        if ((x & 0xFFFFFC00) == 0x1E270000 and (x >> 5) & 31 == d) or ((x & 0xFFC00000) == 0xB9000000 and x & 31 == d) or \
           ((x & 0xFFE00C00) == 0xB8000000 and x & 31 == d) or ((x & 0x7FC00000) == 0x29000000 and (x & 31 == d or (x >> 10) & 31 == d)) or \
           ((x & 0xBFFFFC00) == 0x0E040C00 and (x >> 5) & 31 == d) or ((x & 0xFFE0FC00) == 0x4E001C00 and (x >> 16) & 7 == 4 and (x >> 5) & 31 == d): return True
        if x & 31 == d and ((x & 0x1F800000) == 0x12800000 or (x & 0xFFC00000) == 0xB9400000 or (x & 0x1F000000) in (0x11000000, 0x0A000000)): return False
    return False


def _main_part(lo, hi):
    """movz / asp / aspcap / aspcaps / f2w / aspstr / aspdiv：起点 i ∈ [lo, hi)"""
    W, n = _W, _N; out = []
    for i in range(lo, hi):
        w = W[i]
        if (w & 0x7F800000) == 0x52800000:   # MOVZ：显示宽度
            for vw, vh in CLS:
                if movz(w, vw) and any(movz(W[j], vh) or (W[j] & 0xFFFFFFE0) == (0xF2C00000 | (vh << 5)) for j in range(max(0, i - 16), min(n, i + 17))):
                    out.append((i * 4, 'movz', '%08x' % w))
                    # movzh：配对的那条纯 MOVZ #高（11-02 窄屏：游戏按更高的画布渲染、裁切跟着变高，界面不被竖向拉伸；宿主按屏高填值，缺省关）。MOVK 打包的高不单列
                    out.extend((j * 4, 'movzh', '%08x' % W[j]) for j in range(max(0, i - 16), min(n, i + 17)) if movz(W[j], vh))
                    # i2h：MOVZ Xd,#宽 之后 16 条内 MOVK Xd,#高,LSL#32 把 (宽, 高) 一对整数打包进一个 X（11-04 智慧的再现：渲染配置开头 8 字节）；
                    #   中间有别的指令以 Xd 为目标就放弃（同 f2w），高半单列一行，改写成从值槽装整个 8 字节
                    if (w & 0xFFE00000) == 0xD2800000 and (w & 31) != 31:
                        d = w & 31; want = 0xF2C00000 | (vh << 5) | d
                        for j in range(i + 1, min(n, i + 17)):
                            if W[j] == want: out.append((j * 4, 'i2h', '%08x %08x' % (W[j], w))); break
                            if (W[j] & 31) == d: break
                    break
        if (w & 0xFFE00000) == 0x52A00000 and (w & 31) != 31 and (w >> 5) & 0xffff in F2W:   # movz 装 16:9 档宽的浮点（见模块说明 movzh）
            hh = F2W[(w >> 5) & 0xffff]
            pj = [j for j in range(max(0, i - 24), min(n, i + 25)) if (W[j] & 0xFFE00000) == 0x52A00000 and (W[j] & 31) != 31 and (W[j] >> 5) & 0xffff == hh and _fuse(W, j, n)]
            if pj and _fuse(W, i, n): out.append((i * 4, 'movz', '%08x' % w)); out.extend((j * 4, 'movzh', '%08x' % W[j]) for j in pj)
        if any(movz(w, lo_) for lo_ in ASP_LO) and i + 1 < n and movk16(W[i + 1], 0x3fe3) and (W[i + 1] & 31) == (w & 31): out.append((i * 4, 'asp', '%08x %08x' % (w, W[i + 1])))
        if (w & 0xFFE00000) == 0x52800000 and (w >> 5) & 0xffff in CAP and i + 1 < n and movk16(W[i + 1], CAP[(w >> 5) & 0xffff]) and (W[i + 1] & 0xFFE0001F) == 0x72A00000 | (w & 31):
            k = _cap_use(W, i, n, w & 31)
            if k: out.append((i * 4, k, '%08x %08x' % (w, W[i + 1])))
        # f2w：MOVZ Xd,#hi16(宽.0f),LSL#16 … MOVK Xd,#hi16(高.0f),LSL#48；中间任何以 Xd 为目标字段的指令都放弃（保守）
        if (w & 0xFFE00000) == 0xD2A00000 and ((w >> 5) & 0xffff) in F2W:
            d = w & 31; want = 0xF2E00000 | (F2W[(w >> 5) & 0xffff] << 5) | d
            for j in range(i + 1, min(n, i + 17)):
                if W[j] == want: out.extend([(i * 4, 'f2w', '%08x %08x' % (w, W[j])), (j * 4, 'f2h', '%08x %08x' % (W[j], w))]); break
                if (W[j] & 31) == d: break
        if (w & 0xFFFFFC00) == (0xBD000000 | (44 << 10)):   # STR S?,[Xn,#0xb0]
            rn = (w >> 5) & 31
            if any((W[j] & 0xFFFFFFE0) == (0xBD000000 | (42 << 10) | (rn << 5)) for j in range(max(0, i - 8), i)) and \
               any((W[j] & 0xFFFFFFE0) == (0x39000000 | (8 << 10) | (rn << 5)) for j in range(i + 1, min(n, i + 5))): out.append((i * 4, 'aspstr', '%08x' % w))
        if movz(w, 0xaaab) and i + 1 < n and movk16(W[i + 1], 0x3faa):   # sead 透视投影：缺省 4:3 → FDIV 写回同一偏移
            r = w & 31; off = None
            for j in range(i + 2, min(n, i + 8)):
                x = W[j]
                if (x & 0xFFC003E0) == 0xB9000000 and (x & 31) == r: off = ((x >> 10) & 0xfff) * 4; break
            if off is not None:
                for j in range(i + 2, min(n, i + 64)):
                    x = W[j]
                    if (x & 0xFFE0FC00) == 0x1E201800 and j + 1 < n:
                        y = W[j + 1]
                        if (y & 0xFFC003E0) == 0xBD000000 and ((y >> 10) & 0xfff) * 4 == off and (y & 31) == (x & 31): out.append((j * 4, 'aspdiv', '%08x' % x)); break
        # aspdiv 的其余除法形状（视口矩形 / 整数宽高 / 宽 ÷ 常量高，见模块说明 _div_shape）；与 4:3 形状认出同一点时 scan() 汇总去重
        if (w & 0xFFE0FC00) == 0x1E201800 and _div_shape(W, i, n): out.append((i * 4, 'aspdiv', '%08x' % w))
    return out


_H = {456, 480, 528, 540, 576, 720, 900, 1080, 1440, 2160}   # 宽 ÷ 常量高认的画面高（不收 360：多半是角度）


def _writer(W, i, r, back):
    """i 之前 back 条内最近一条写 S/W/X 寄存器 r 的指令下标（只看本函数用到的几种写法），没有 None"""
    for j in range(i - 1, max(-1, i - 1 - back), -1):
        x = W[j]
        if (x & 31) == r and ((x & 0xFFE0FC00) in (0x1E203800, 0x1E201800) or (x & 0xFF7FFC00) in (0x1E220000, 0x1E230000, 0x9E220000, 0x9E230000)
                              or (x & 0xFFFFFC00) in (0x5E21D800, 0x7E21D800, 0x1E270000) or (x & 0xFFC00000) in (0x29400000, 0x2D400000, 0xB9400000, 0xBD400000)
                              or (x & 0x7F800000) == 0x52800000): return j
        if (x & 0xFFC00000) in (0x29400000, 0x2D400000) and ((x >> 10) & 31) == r: return j   # LDP 的第二个目的
    return None


def _cvt_src(x):
    """SCVTF / UCVTF（单精度目的，源 W / X / S）的源寄存器，不是这几种 None"""
    if (x & 0xFF7FFC00) in (0x1E220000, 0x1E230000) or (x & 0xFFFFFC00) in (0x5E21D800, 0x7E21D800): return (x >> 5) & 31
    return None


def _fw(W, i, r, back=12):
    """i 之前 back 条内最近一条写单精度 Sr 的指令下标：浮点运算 / FMOV 立即数（排除 FCMP，它不写寄存器、低 5 位是操作码）、LDR / LDP / LDUR S；没有 None。
    BL 不截断（半宽半高常放在 S8+ 被调用者保存寄存器里，跨调用仍有效；11-07 奥德赛 3CA12DFA main 0xa63d5c）"""
    for j in range(i - 1, max(-1, i - 1 - back), -1):
        x = W[j]
        if (x & 0xFF200000) == 0x1E200000 and (x & 0xFFE0FC07) != 0x1E202000 and (x & 31) == r: return j
        if (x & 0xFFC00000) in (0xBD400000, 0x2D400000) and (x & 31) == r or (x & 0xFFC00000) == 0x2D400000 and ((x >> 10) & 31) == r: return j
        if (x & 0xFFE00C00) == 0xBC400000 and (x & 31) == r: return j
    return None
def _half(W, i, r):
    """Sr 在 i 之前是否是「|右 − 左| × 0.5」：FMUL Sr,Sa,Sh，Sh = FMOV #0.5，Sa = FCSEL(Sp, Sq)，Sq = FNEG Sp，Sp = FSUB（矩形一边长取绝对值再减半）。
    是则返回 Sh 的寄存器号（两边要乘同一个 0.5），否则 None"""
    j = _fw(W, i, r)
    if j is None or (W[j] & 0xFFE0FC00) != 0x1E200800: return None
    a, h = (W[j] >> 5) & 31, (W[j] >> 16) & 31
    k = _fw(W, j, h)
    if k is None or W[k] != (0x1E2C1000 | h): return None
    c = _fw(W, j, a, 10)
    if c is None or (W[c] & 0xFFE00C00) != 0x1E200C00: return None
    p, q = (W[c] >> 5) & 31, (W[c] >> 16) & 31
    f, g = _fw(W, c, p, 10), _fw(W, c, q, 10)
    if f is None or g is None or (W[g] & 0xFFFFFC00) != 0x1E214000 or (W[g] >> 5) & 31 != p or (W[f] & 0xFFE0FC00) != 0x1E203800: return None
    return h


def _div_shape(W, i, n):
    """aspdiv 的另外三种除法形状（FDIV Sd,Sn,Sm 在 i；10-26 社区超宽屏补丁对照，宿主门只在算出约 16:9 时换屏幕比，其余原样）：
    矩形宽高比：前 4 条内两条 FSUB 分别写 Sn / Sm，后一条 STR Sd,[X,#任意]，或 Sd = S0 且下一条 RET（getter）——马车8 main 0x3cd314、塞尔达 sead 视锥 getAspect；
    存好的宽高相除 getter：紧前一条 LDP Sn,Sm,[X,#imm]（先取的是宽）、FDIV S0,Sn,Sm、下一条 RET——奥德赛 main 0x9cf340（11-07，社区超宽屏补丁改的两处之一；
      本机 46 份 main 只这一处和大乱斗 0x361b5c 命中）；
    矩形半宽 ÷ 半高：Sn、Sm 各是「|FSUB| × 0.5」（见 _half，两边乘同一个 0.5 寄存器），结果传参不限写回——奥德赛我方版本 main 0x6329f8 / 3CA12DFA 0xa63d5c
      （11-07，社区超宽屏补丁改的另一处；本机 33 份 main 只奥德赛命中）；
    整数宽高相除：Sn、Sm 各在前 9 条内由 SCVTF / UCVTF 转来，两个整数出自同一条 LDP（W 或 S；先取的是宽），或同基址偏移差 4 的两条 LDR（低偏移是宽）——异度3 main 0xeb73ac；
    宽 ÷ 常量高：Sn 由 SCVTF / UCVTF 转来，Sm 由 MOVZ W,#hi,LSL#16 → FMOV Sm,W 拼出常见画面高（_H）——银河 2 main 0x2fe4a0"""
    w = W[i]; d, rn, rm = w & 31, (w >> 5) & 31, (w >> 16) & 31
    if d == 0 and rn != rm and 0 < i and i + 1 < n and W[i + 1] == 0xD65F03C0:
        p = W[i - 1]
        if (p & 0xFFC00000) == 0x2D400000 and (p & 31) == rn and ((p >> 10) & 31) == rm: return True
    if rn != rm:
        h = _half(W, i, rn)
        if h is not None and h == _half(W, i, rm): return True
    a, c = _writer(W, i, rn, 4), _writer(W, i, rm, 4)
    if a is not None and c is not None and a != c and (W[a] & 0xFFE0FC00) == 0x1E203800 and (W[c] & 0xFFE0FC00) == 0x1E203800 and i + 1 < n:
        y = W[i + 1]
        if (y & 0xFFC00000) == 0xBD000000 and (y & 31) == d or d == 0 and y == 0xD65F03C0: return True
    a, c = _writer(W, i, rn, 9), _writer(W, i, rm, 9)
    sa = _cvt_src(W[a]) if a is not None else None
    if sa is None: return False
    sc = _cvt_src(W[c]) if c is not None else None
    if sc is not None:
        la, lc = _writer(W, a, sa, 16), _writer(W, c, sc, 16)
        if la is None or lc is None: return False
        p, q = W[la], W[lc]
        if la == lc and (p & 0xFFC00000) in (0x29400000, 0x2D400000): return (p & 31) == sa and ((p >> 10) & 31) == sc
        if (p & 0xFFC00000) == (q & 0xFFC00000) and (p & 0xFFC00000) in (0xB9400000, 0xBD400000) and (p >> 5) & 31 == (q >> 5) & 31:
            return ((q >> 10) & 0xfff) - ((p >> 10) & 0xfff) == 1   # 宽在低偏移（偏移按 4 字节计，差 1 = 4 字节）
        return False
    if c is None or (W[c] & 0xFFFFFC00) != 0x1E270000: return False   # FMOV Sm,Wk
    k = (W[c] >> 5) & 31; m = _writer(W, c, k, 8)
    if m is None or (W[m] & 0xFFE0001F) != (0x52A00000 | k): return False   # MOVZ Wk,#hi,LSL#16
    h = struct.unpack('<f', struct.pack('<I', ((W[m] >> 5) & 0xFFFF) << 16))[0]
    return h in _H   # 整数值浮点按值命中整数集合；MOVZ 立即数拼出 NaN / Inf 时直接不中（不能先 int(h)：int(NaN) 抛错、整款出包停，潜水员戴夫）


SEAD_LAYOUTS = ((0x98, 0xac, 0xb0, 0xb4),)   # sead PerspectiveProjection：近平面、tan(视角/2)、宽高比、偏移 x（塞尔达 / 动森 / 马车8 同一布局，10-30）
def _sload(x):
    """单精度读：LDR St,[Xn,#imm12×4] → (n, 偏移, (t,))；LDP Sa,Sb,[Xn,#imm7×4] → (n, 偏移, (a, b))；别的 None"""
    if (x & 0xFFC00000) == 0xBD400000: return (x >> 5) & 31, ((x >> 10) & 0xFFF) * 4, (x & 31,)
    if (x & 0xFFC00000) == 0x2D400000: return (x >> 5) & 31, ((x >> 15) & 0x7F) * 4, (x & 31, (x >> 10) & 31)
    return None
def _fn_range(W, i, n, back=160):
    """包住第 i 条的粗切函数 [lo, hi]：往前到上一条 RET 之后、往后到下一条 RET（各至多 back 条）"""
    lo = i
    while lo > 0 and i - lo < back and W[lo - 1] != 0xD65F03C0: lo -= 1
    hi = i
    while hi < n - 1 and hi - i < back and W[hi] != 0xD65F03C0: hi += 1
    return lo, hi
def _sead_reads(W, lo, hi):
    """[lo, hi] 里按基址分的单精度读：{n: {偏移: [(第几条, 读的寄存器)]}}"""
    by = {}
    for j in range(lo, hi + 1):
        r = _sload(W[j])
        if r: by.setdefault(r[0], {}).setdefault(r[1], []).append((j, r[2]))
    return by
def _sead_persp(W, n):
    """seadasp 候选（见模块说明）：[(偏移, 'seadasp', 证据)]"""
    out, seen = [], set()
    for i in range(n):
        if (W[i] & 0xFFFFFFE0) != 0x52B7F000: continue   # MOVZ Wd,#0xbf80,LSL#16 = -1.0f（矩阵 m[3][2]）
        lo, hi = _fn_range(W, i, n)
        if hi - lo > 160 or any((W[j] & 0xFC000000) == 0x94000000 for j in range(lo, hi + 1)): continue   # 叶子函数
        if sum(1 for j in range(lo, hi + 1) if (W[j] & 0xFFC003E0) in (0xBD000020, 0xB9000020, 0x2D000020, 0x29000020, 0xF9000020, 0xA9000020) or (W[j] & 0xFFE00C00) in (0xBC000000, 0xB8000000, 0xF8000000) and (W[j] >> 5) & 31 == 1) < 6: continue   # 往 [X1] 写矩阵（STR S / W / X、STP S / W / X、STUR）
        for near, tan, asp, offx in SEAD_LAYOUTS:
            by = _sead_reads(W, lo, hi)
            if not any(near in o and (tan in o or asp in o) and offx in o and any(len(r) == 2 for _, r in o.get(tan, [])) | (asp in o) for o in by.values()): continue
            if lo in seen: break
            seen.add(lo)
            # 同族函数（建矩阵函数前后 0x600 字节）：读了近平面或 tan 的函数里，每条读宽高比的指令
            a = max(0, lo - 0x180); b = min(n - 1, hi + 0x180); k = a
            while k <= b:
                flo, fhi = _fn_range(W, k, n, back=0)
                fhi = k
                while fhi < n - 1 and W[fhi] != 0xD65F03C0 and fhi - k < 400: fhi += 1
                for base, o in _sead_reads(W, k, fhi).items():
                    if near not in o and tan not in o: continue
                    for j, regs in o.get(asp, []):
                        if len(regs) == 1: out.append((j * 4, 'seadasp', '%08x' % W[j]))
                    for j, regs in o.get(tan, []):
                        if len(regs) == 2: out.append((j * 4, 'seadasp', '%08x' % W[j]))
                k = fhi + 1
            break
    return out


def _parts(fn, n, jobs):
    """把 [0, n) 切成 jobs × 4 块交给 fn 并行（jobs ≤ 1 或段太短就本进程跑），按块序拼回"""
    # 并行靠 fork 继承模块镜像等全局（fn 读它们）；没有 fork 的平台（Windows）本进程顺序跑，结果逐字节相同
    if jobs <= 1 or n < 1 << 16 or 'fork' not in multiprocessing.get_all_start_methods(): return fn(0, n)
    step = -(-n // (jobs * 4)); rs = [(lo, min(n, lo + step)) for lo in range(0, n, step)]
    with multiprocessing.get_context('fork').Pool(jobs) as pool: return [x for part in pool.starmap(fn, rs) for x in part]


def scan(b, jobs=None):
    """返回 [(偏移, 种类, 证据)]，按偏移排序。jobs：并行进程数（缺省 S2A_JOBS / 本机核数）"""
    global _W, _N, _LS
    jobs = jobs or int(os.environ.get('J') or os.environ.get('S2A_JOBS') or os.cpu_count() or 1)   # 进程数（J / S2A_JOBS / 本机核数）
    n = min(len(b), 0x6000000) // 4; _W = memoryview(bytes(b[:n * 4])).cast('I'); _N = n   # 小端（arm64 / x86），同 struct '<I'
    out = _parts(_main_part, n, jobs)
    lyt = _parts(_lyt_part, n, jobs); out += lyt
    _LS = frozenset(o // 4 for o, _, _ in lyt); out += _parts(_cap_part, n, jobs)
    out += _sead_persp(_W, n)   # 一次扫完（只看 MOVZ -1.0f 附近，快）
    te = _text_end(b)
    f = struct.pack('<ff', 1920.0, 1080.0); o = b.find(f, te)   # f32 同 aspf / i32 只认代码段之后（审计 #829 F-scan-f32-text：代码段里凑巧的浮点对不是分辨率表）
    while o >= 0:
        nb = [struct.unpack_from('<ff', b, o + d) for d in (-8, 8) if 0 <= o + d <= len(b) - 8]
        if o % 4 == 0 and any(y > 0 and abs(x / y - 16 / 9) < 1e-3 for x, y in nb): out.append((o, 'f32', '1920.0,1080.0'))
        o = b.find(f, o + 1)
    asp = []
    for k in (b'\x39\x8e\xe3\x3f', b'\x3b\x8e\xe3\x3f'):   # aspf：单独的 16:9 浮点常量（见模块说明），只认代码段之后的
        o = b.find(k, te)
        while o >= 0:
            if o % 4 == 0: asp.append((o, k[::-1].hex()))
            o = b.find(k, o + 1)
    out += _i32_tables(b, te)
    out += _restab_tables(b, te)
    asp.sort()   # 「单独」：前后 32 字节内没有别的 16:9 常量（sdk 里一整张连排的 16:9 常量表是查找表，不是镜头宽高比：动森 / 塞尔达 / 丝之歌各约 46 项）
    out += [(o, 'aspf', e) for i, (o, e) in enumerate(asp) if (i == 0 or o - asp[i - 1][0] > 32) and (i + 1 == len(asp) or asp[i + 1][0] - o > 32)]
    return sorted(set(out))


_CLS = (1920, 1280, 1600, 960, 2560, 3840, 1024, 640)   # 16:9 档宽（同 runtime/src/widen.c k_cls）
def _i32_tables(b, te):
    """i32：整数分辨率表的首项（见模块说明）。一对 = 两个小端 u32 (宽, 宽×9/16)，宽是 16:9 档宽；连续两对以上才算表（单独一对多是别的常量巧合）"""
    import struct as _s
    out, seen = [], set()
    for w in _CLS:
        k = _s.pack('<II', w, w * 9 // 16); o = b.find(k, te)
        while o >= 0:
            if o % 4 == 0 and o not in seen:
                def ok(p): return 0 <= p <= len(b) - 8 and (lambda x, y: x in _CLS and y == x * 9 // 16)(*_s.unpack_from('<II', b, p))
                s0 = o
                while s0 - 8 >= te and ok(s0 - 8): s0 -= 8
                n, p = 0, s0
                while ok(p): seen.add(p); p += 8; n += 1
                if n >= 2: out.append((s0, 'i32', ','.join(str(x) for x in _s.unpack_from('<%dI' % (2 * n), b, s0))))
            o = b.find(k, o + 1)
    return out

def _restab_n(b, off):
    """restab 档数：off 起 n 个 u32 宽紧跟 n 个 u32 高，逐档宽 × 9 = 高 × 16、宽严格递增；取最大的 n（4–64），不成表 0（runtime/src/widen.c restab_n 同一判法）"""
    for n in range(64, 3, -1):
        if off + 8 * n > len(b): continue
        v = struct.unpack_from('<%dI' % (2 * n), b, off); tw, th = v[:n], v[n:]
        if all(64 <= tw[i] <= 16384 and tw[i] * 9 == th[i] * 16 and (i == 0 or tw[i] > tw[i - 1]) for i in range(n)): return n
    return 0


def _restab_tables(b, te):
    """restab：档位表首项（见模块说明）。以 u32 1920 / 1280 为锚，往前最多 64 项找最早能成表的起点，表要盖住锚点"""
    out, seen = [], set()
    for w in (1920, 1280):
        o = b.find(struct.pack('<I', w), te)
        while o >= 0:
            if o % 4 == 0:
                for s0 in range(max(te - te % 4, o - 256), o + 4, 4):
                    if s0 in seen: break
                    n = _restab_n(b, s0)
                    if n and s0 + 4 * n > o: seen.add(s0); out.append((s0, 'restab', 'n=%d,%d×%d..%d×%d' % ((n,) + struct.unpack_from('<I', b, s0) + struct.unpack_from('<I', b, s0 + 4 * n) + struct.unpack_from('<I', b, s0 + 4 * n - 4) + struct.unpack_from('<I', b, s0 + 8 * n - 4)))); break
            o = b.find(struct.pack('<I', w), o + 1)
    return out


def _text_end(b):
    """代码段末（原版 NSO 铺成的映像：第二段 ro 的内存偏移；平铺映像没有段信息时取 0，单测用）"""
    return _TEXT_END if _TEXT_END is not None else 0


def main():
    a = sys.argv[1:]
    if not a: print(__doc__); return 2
    src = a[0]
    mods = [(os.path.basename(src), src)] if os.path.isfile(src) else \
           [(m, os.path.join(src, m)) for m in sorted(os.listdir(src)) if m not in ('rtld',) and not m.endswith('.npdm') and os.path.isfile(os.path.join(src, m))]
    rows = []
    for m, p in mods:
        for off, kind, ev in scan(load(p)): rows.append((m, off, kind, ev))
    lines = ['模块\t偏移\t种类\t证据'] + ['%s\t%#x\t%s\t%s' % r for r in rows]
    if '--tsv' in a: open(a[a.index('--tsv') + 1], 'w', newline='\n').write('\n'.join(lines) + '\n')   # Windows 缺省写 CRLF：与 Mac 产物逐字节同
    else: print('\n'.join(lines))
    from collections import Counter
    c = Counter(r[2] for r in rows)
    print('候选 %d 个：%s' % (len(rows), '，'.join('%s %d' % kv for kv in sorted(c.items()))), file=sys.stderr)
    if '--patch' in a: print('NX_WIDE_PATCH="%s"' % ' '.join('%s:%#x:%s' % (m, off, k) for m, off, k, _ in rows), file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())

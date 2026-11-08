"""纯 Python 写 arm64 iOS dylib（阶段 0，11-04 Windows 出包线）：游戏镜像包不经 Apple 链接器，Windows / Mac 同一份写法。

只写镜像包要的形状：一个 __TEXT 段（头页 + 若干节）、可选一个可写段、__LINKEDIT（空符号表）。没有导入、没有符号、dyld 不装它；
文件自带预留签名区与链接器式 ad-hoc 签名，签名工具原地替换，节内容与偏移不动（11-04 测试机2 实测注册 + MAP_FIXED 执行过，
探针 exp/win-dylib-probe）。各节按给定对齐放、段按 16K 对齐；内容由调用方按块流式给出，几 GB 的镜像不进内存。

用法：write(dst, install_name, text=[节…], data=(段名, [节…]) 或 None) → {(段, 节): 文件偏移}
  节 = (节名, 对齐 log2, 标志, 块列表)；块 = bytes（原样）/ int（这么多个零字节）/ (路径, 偏移, 长度)（从文件拷）
"""
import hashlib
import struct

PAGE = 0x4000
LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB, LC_ID_DYLIB, LC_UUID, LC_BUILD_VERSION, LC_CODE_SIGNATURE = 0x19, 0x2, 0xB, 0xD, 0x1B, 0x32, 0x1D
PURE_INSTRUCTIONS = 0x80000400   # S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS
_FLAGS = 0x1 | 0x4 | 0x80 | 0x100000   # MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_NO_REEXPORTED_DYLIBS


def _up(n, a):
    return (n + a - 1) // a * a


def _blen(b):
    return len(b) if isinstance(b, (bytes, bytearray)) else b if isinstance(b, int) else b[2]


def _n16(s):
    assert len(s) <= 16, s
    return s.encode().ljust(16, b"\0")


def _seg(name, vm, size, fo, fsize, prot, sects):
    body = b"".join(_n16(sn) + _n16(name) + struct.pack("<QQIIIIIIII", a, z, fo2, al, 0, 0, fl, 0, 0, 0) for sn, a, z, fo2, al, fl in sects)
    return struct.pack("<II", LC_SEGMENT_64, 72 + 80 * len(sects)) + _n16(name) + struct.pack(
        "<QQQQiiII", vm, size, fo, fsize, prot, prot, len(sects), 0) + body


def _place(start, sections):
    out, at = [], start
    for name, al, fl, blocks in sections:
        at = _up(at, 1 << al)
        z = sum(_blen(b) for b in blocks)
        out.append((name, at, z, al, fl, blocks)); at += z
    return out, at


def _adhoc_sig(pages, code_limit, text_size, ident=b"S2AImages\0"):
    """苹果 cs_blobs.h 的 SuperBlob + CodeDirectory 0x20400（SHA-256 页哈希、4K 页），链接器式（CS_ADHOC | CS_LINKER_SIGNED = 0x20002）：
    重签工具不用强制标志就能替换它；它本身不是团队签名，F_ADDFILESIGS_RETURN / 库校验要重签之后才过（11-04 测试机2 探针：只有 ad-hoc 签名注册 EPERM）"""
    hdr = struct.calcsize(">IIIIIIIIIBBBBIIIIQQQQ")
    cd = struct.pack(">IIIIIIIIIBBBBIIIIQQQQ", 0xFADE0C02, hdr + len(ident) + 32 * len(pages), 0x20400, 0x20002, hdr + len(ident), hdr, 0,
                     len(pages), code_limit, 32, 2, 0, 12, 0, 0, 0, 0, 0, 0, text_size, 0) + ident + b"".join(pages)
    return struct.pack(">IIIII", 0xFADE0CC0, 20 + len(cd), 1, 0, 20) + cd


def write(dst, install_name, text, data=None, minos=(18, 0)):
    tsec, tend = _place(PAGE, text)                     # 头页之后放 __TEXT 各节
    tsize = _up(tend, PAGE)
    dname, dsec_in = data if data else (None, [])
    dsec, dend = _place(tsize, dsec_in)
    dsize = _up(dend, PAGE) - tsize if data else 0
    le = tsize + dsize
    strtab = b" \0\0\0\0\0\0\0"
    # 预留签名区 + 链接器式 ad-hoc 签名（照 d2r-mobile dm/tools/guest_dylib.py，11-04 Windows 出包线）：zsign 只靠名为 __text 的节找头里的空位，
    #   这种只有自定义节的库它加不了 LC_CODE_SIGNATURE（会报 0xe800801c）；文件里先带好签名命令和够大的签名区，重签工具（codesign / zsign / rcodesign /
    #   Sideloadly 等）都按「替换已有签名」原地写。签名区 16 字节对齐，容量 = SHA-1 + SHA-256 页哈希（52 字节 / 4K 页）+ 256K
    cs_off = _up(le + len(strtab), 16)
    cs_size = _up((cs_off // 4096 + 1) * 52, 4096) + 0x40000
    name = install_name.encode() + b"\0"; idz = _up(24 + len(name), 8)
    v = (minos[0] << 16) | (minos[1] << 8)
    cmds = [_seg("__TEXT", 0, tsize, 0, tsize, 5, [(n, a, z, a, al, fl) for n, a, z, al, fl, _ in tsec])]
    if data: cmds.append(_seg(dname, tsize, dsize, tsize, dsize, 3, [(n, a, z, a, al, fl) for n, a, z, al, fl, _ in dsec]))
    cmds += [_seg("__LINKEDIT", le, _up(cs_off + cs_size - le, PAGE), le, cs_off + cs_size - le, 1, []),
             (struct.pack("<IIIIII", LC_ID_DYLIB, idz, 24, 2, 0x10000, 0x10000) + name).ljust(idz, b"\0"),
             struct.pack("<II16s", LC_UUID, 24, b"\0" * 16),     # 占位：写完按内容回填（同输入在哪台机器上出都逐字节相同）
             struct.pack("<IIIIII", LC_BUILD_VERSION, 24, 2, v, v, 0),   # 平台 2 = iOS
             struct.pack("<IIIIII", LC_SYMTAB, 24, 0, 0, le, len(strtab)),
             struct.pack("<II18I", LC_DYSYMTAB, 80, *([0] * 18)),
             struct.pack("<IIII", LC_CODE_SIGNATURE, 16, cs_off, cs_size)]   # 最后一条，与 ld 一致
    lc = b"".join(cmds)
    if 32 + len(lc) > PAGE:
        raise ValueError("加载命令超出头页")
    uuid_at = 32 + sum(len(c) for c in cmds[:cmds.index(next(c for c in cmds if c[:4] == struct.pack("<I", LC_UUID)))]) + 8
    hdr = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 6, len(cmds), len(lc), _FLAGS, 0)   # MH_MAGIC_64、CPU_TYPE_ARM64、MH_DYLIB
    body = hashlib.sha256()
    with open(dst, "w+b") as f:
        f.write(hdr + lc)
        for _, a, z, _, _, blocks in tsec + dsec:
            f.write(b"\0" * (a - f.tell()))
            body.update(struct.pack("<QQ", a, z))
            for b in blocks:
                if isinstance(b, (bytes, bytearray)): f.write(b); body.update(b)
                elif isinstance(b, int):
                    body.update(struct.pack("<Q", b))   # 零块按长度记（内容就是 b 个零）
                    f.write(b"\0" * b) if b < (1 << 20) else (f.seek(b, 1), f.truncate())
                else:
                    p, off, n = b
                    with open(p, "rb") as src:
                        src.seek(off)
                        while n:
                            c = src.read(min(n, 1 << 24))
                            if not c: raise ValueError(f"{p} 偏移 {off:#x} 不够 {b[2]:#x} 字节")
                            f.write(c); body.update(c); n -= len(c)
        f.write(b"\0" * (le - f.tell()))
        f.write(strtab)
        f.write(b"\0" * (cs_off - f.tell()))
        f.seek(uuid_at); f.write(body.digest()[:16])
        f.seek(0); pages = []                               # 签名覆盖 [0, cs_off)：回读算 SHA-256 页哈希
        while f.tell() < cs_off:
            pages.append(hashlib.sha256(f.read(min(4096, cs_off - f.tell()))).digest())
        f.seek(cs_off); sig = _adhoc_sig(pages, cs_off, tsize)
        if len(sig) > cs_size: raise ValueError("签名区不够")
        f.write(sig.ljust(cs_size, b"\0"))
    return {(("__TEXT", s[0])): s[1] for s in tsec} | {((dname, s[0])): s[1] for s in dsec}

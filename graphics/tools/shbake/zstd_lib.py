# zstd 解压——仓库里唯一的 zstd 解压入口（11-02 出包线：原先 shader_split / unreal_pak 用 Python 3.14 的 compression.zstd 或 pip 的 backports.zstd，
#   玩家 App 自带 Python 3.12 两样都没有，Zstd 款（BRAVELY DEFAULT Ⅱ：pak 里 155207 条 Zstd）在玩家机上必红）。
# 不引入新依赖：直接用出包链本来就带的 zstd 命令行旁边的 libzstd（App：Runtime/bin/zstd → Runtime/lib/libzstd.1.dylib，launchers/macos/bundle_runtime.py
#   按依赖收进 Runtime/lib；开发机 Homebrew：Cellar/zstd/<版本>/bin/zstd → ../lib/libzstd.1.dylib），ctypes 调流式接口（ZSTD_decompressStream）：
#   帧里不记原长的也能解、多帧首尾相接照解、可只要前 max_length 字节、可带字典（游戏 ZsDic）。
# 接口：decompress(数据, dict_bytes=None, max_length=None) → bytes；数据坏 / 不是 zstd 抛 ZstdError（ValueError）
import ctypes, os, shutil


class ZstdError(ValueError): pass


class _Buf(ctypes.Structure):
    _fields_ = [('ptr', ctypes.c_void_p), ('size', ctypes.c_size_t), ('pos', ctypes.c_size_t)]


_L = None
_DD = {}   # 字典字节 → ZSTD_DDict*（进程内复用）


def lib_candidates():
    """libzstd 的候选路径（仓库唯一的找法；nxsh_extract 也调它）：S2A_ZSTD_LIB 指定 > zstd 命令旁边按平台的官方布局。
    Mac（Homebrew / App Runtime）：<bin>/../lib/libzstd.1.dylib；Linux：<bin>/../lib/libzstd.so.1；
    Windows（zstd 官方发行包 zstd-v*-win64）：<bin>/dll/libzstd.dll 或 <bin>/libzstd.dll（11-04 天眼旷野之息：只认 dylib 时抽取报「找不到 libzstd」）"""
    out = [os.environ['S2A_ZSTD_LIB']] if os.environ.get('S2A_ZSTD_LIB') else []
    exe = shutil.which('zstd')
    if exe:
        d = os.path.dirname(os.path.realpath(exe))
        if os.name == 'nt': out += [os.path.join(d, 'dll', 'libzstd.dll'), os.path.join(d, 'libzstd.dll')]
        else: out += [os.path.normpath(os.path.join(d, '..', 'lib', n)) for n in ('libzstd.1.dylib', 'libzstd.so.1', 'libzstd.so')]
    return out


def _lib():
    global _L
    if _L: return _L
    cands = lib_candidates()
    if not cands: raise ZstdError('找不到 zstd 命令（出包链要的工具，App 在 Runtime/bin、开发机 brew install zstd、Windows 用官方发行包）：解 zstd 用它旁边的 libzstd')
    L = None; errs = []
    for p in cands:
        try: L = ctypes.CDLL(p); break
        except OSError as e: errs.append(f'{p}：{e}')
    if L is None: raise ZstdError('zstd 命令旁边没有能加载的 libzstd（' + '；'.join(errs) + '）') from None
    P, Z = ctypes.c_void_p, ctypes.c_size_t
    for name, res, args in (('ZSTD_createDCtx', P, []), ('ZSTD_freeDCtx', Z, [P]), ('ZSTD_DCtx_refDDict', Z, [P, P]),
                            ('ZSTD_createDDict', P, [P, Z]), ('ZSTD_decompressStream', Z, [P, ctypes.POINTER(_Buf), ctypes.POINTER(_Buf)]),
                            ('ZSTD_isError', ctypes.c_uint, [Z]), ('ZSTD_getErrorName', ctypes.c_char_p, [Z]), ('ZSTD_DStreamOutSize', Z, [])):
        f = getattr(L, name); f.restype, f.argtypes = res, args
    _L = L; return L


def decompress(data, dict_bytes=None, max_length=None):
    L = _lib(); data = bytes(data)
    dc = L.ZSTD_createDCtx()
    if not dc: raise ZstdError('ZSTD_createDCtx 失败')
    try:
        if dict_bytes is not None:
            dd = _DD.get(dict_bytes)
            if dd is None:
                dd = L.ZSTD_createDDict(dict_bytes, len(dict_bytes))
                if not dd: raise ZstdError('zstd 字典无效')
                _DD[dict_bytes] = dd
            r = L.ZSTD_DCtx_refDDict(dc, dd)
            if L.ZSTD_isError(r): raise ZstdError(L.ZSTD_getErrorName(r).decode())
        src = ctypes.create_string_buffer(data, len(data)); inb = _Buf(ctypes.cast(src, ctypes.c_void_p), len(data), 0)
        step = L.ZSTD_DStreamOutSize(); dst = ctypes.create_string_buffer(step); out = []; total = 0; r = 1
        while True:
            outb = _Buf(ctypes.cast(dst, ctypes.c_void_p), step, 0)
            r = L.ZSTD_decompressStream(dc, ctypes.byref(outb), ctypes.byref(inb))
            if L.ZSTD_isError(r): raise ZstdError(L.ZSTD_getErrorName(r).decode())
            out.append(dst.raw[:outb.pos]); total += outb.pos
            if max_length is not None and total >= max_length: return b''.join(out)[:max_length]
            if r == 0 and inb.pos == inb.size: break   # 帧解完且输入吃完：到头。不能再调一次——解码器会当成新帧开头、返回帧头长度 9，被下面误判截断
            #   （11-02 王国之泪 Well_0017_GroupSet_000.Nin_NX_NVN.bphsc.zs：解出恰好 131072 字节 = 一个输出缓冲，直连抽取整款红）
            if inb.pos == inb.size and outb.pos < step: break   # 输入吃完、输出没填满 = 解码器没有存货了
        if r: raise ZstdError('zstd 数据截断（最后一帧没收尾）')
        return b''.join(out)
    finally:
        L.ZSTD_freeDCtx(dc)

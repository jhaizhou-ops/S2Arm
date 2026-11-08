# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Yaz0 decompress and SARC read/write for the pack-time tools.

The byte layout is the public one, and the behavior matches the in-tree
decoders this module replaces as the single implementation:

- Yaz0 groups: flag byte, high bit first; 1 = literal; 0 = back-reference
  with dist = ((b1 & 0xF) << 8 | b2) + 1, length = (b1 >> 4) + 2, or the
  next byte + 0x12 when the high nibble is 0. Overlapping copies repeat.
- SARC: BOM 0xFEFF in the file's own endian (bytes FF FE = little,
  FE FF = big). SFAT hash key (default 0x65). Node name hash is
  h = h * key + byte over the UTF-8 name. Name bit 24 set means the low
  24 bits are the name's 4-byte index in the SFNT pool. File start/end
  are relative to the data offset. Absolute file starts are aligned.

A small C decoder (yaz0dec.c) is built once into build/nxfmt and loaded
with ctypes. If it cannot be built or loaded, decompression uses the
pure-Python path. Set NXFMT_YAZ0=py to force that path, or NXFMT_YAZ0LIB
to a shared library.

This module does not come from oead, sarc, syaz0, roead, or Switch-Toolbox.
"""
import ctypes
import hashlib
import os
import shutil
import struct
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_YAZ0_SRC = 'graphics/tools/yaz0dec.c'  # 字面路径给 pack/stage_inputs.py 收进源码键
_YAZ0_C = os.path.join(_HERE, os.path.basename(_YAZ0_SRC))
_LIB = None
_TRIED = False


class Endianness:
    Little = 'little'
    Big = 'big'


class SarcFile:
    def __init__(self, name, data):
        self.name = name
        self.data = data


def _file_endian(endian):
    if endian in (Endianness.Little, 'little', '<', 'le'):
        return '<'
    if endian in (Endianness.Big, 'big', '>', 'be'):
        return '>'
    raise ValueError('endian 只能是 little 或 big')


def _bom_endian(data):
    bom = bytes(data[6:8])
    if bom == b'\xff\xfe':
        return '<'
    if bom == b'\xfe\xff':
        return '>'
    raise ValueError('SARC 字节序标记无法识别')


def name_hash(name, key=0x65):
    raw = name.encode('utf-8') if isinstance(name, str) else bytes(name)
    h = 0
    for b in raw:
        h = (h * (key & 0xFFFFFFFF) + b) & 0xFFFFFFFF
    return h


def _align_up(n, alignment):
    if alignment <= 1:
        return n
    return (n + alignment - 1) & ~(alignment - 1)


def yaz0_decompress_py(data):
    """Pure-Python Yaz0. Same bytes as yaz0dec.c and the old in-tree decoders."""
    buf = data if isinstance(data, (bytes, bytearray)) else bytes(data)
    if len(buf) < 16 or buf[:4] != b'Yaz0':
        raise ValueError('不是 Yaz0')
    n = int.from_bytes(buf[4:8], 'big')
    if n > 0x7FFFFFFF:
        raise ValueError('Yaz0 解压后过长')
    out = bytearray()
    i = 16
    try:
        while len(out) < n:
            flags = buf[i]
            i += 1
            for _ in range(8):
                if len(out) >= n:
                    break
                if flags & 0x80:
                    out.append(buf[i])
                    i += 1
                else:
                    b1, b2 = buf[i], buf[i + 1]
                    i += 2
                    dist = ((b1 & 0xF) << 8 | b2) + 1
                    ln = b1 >> 4
                    if ln == 0:
                        ln = buf[i] + 0x12
                        i += 1
                    else:
                        ln += 2
                    if dist > len(out) or len(out) + ln > n:
                        raise ValueError('Yaz0 回溯越界')
                    start = len(out) - dist
                    if dist >= ln:
                        out += out[start:start + ln]
                    else:
                        piece = out[start:]
                        out += (piece * (ln // dist + 1))[:ln]
                flags = (flags << 1) & 0xFF
    except IndexError as exc:
        raise ValueError('Yaz0 截断') from exc
    return bytes(out)


def _shared_suffix():   # 不用 os.uname()：Windows 没有它（11-04 天眼旷野之息界面布局 24 个文件因此报错）
    return '.dll' if os.name == 'nt' else ('.dylib' if sys.platform == 'darwin' else '.so')


def _lib_name():   # 按源码摘要命名：现编缓存与预编件同名
    with open(_YAZ0_C, 'rb') as fh:
        return 'libyaz0dec_' + hashlib.sha256(fh.read()).hexdigest()[:12] + _shared_suffix()


def prebuilt_lib():
    """启动器随发版预编的一份（S2A_PREBUILT_TOOLS/codecs/libyaz0dec_<摘要>，launchers/windows/bundle_prepare_win.py）：同名在就用，不现编"""
    tools = os.environ.get('S2A_PREBUILT_TOOLS')
    if not tools or not os.path.isfile(_YAZ0_C):
        return None
    lib = os.path.join(tools, 'codecs', _lib_name())
    return lib if os.path.isfile(lib) else None


def _compile_lib():
    pre = prebuilt_lib()
    if pre:
        return pre
    cc = shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
    if not cc or not os.path.isfile(_YAZ0_C):
        return None
    root = os.path.normpath(os.path.join(_HERE, '..', '..'))
    out_dir = os.path.join(root, 'build', 'nxfmt')
    lib = os.path.join(out_dir, _lib_name())
    if not os.path.isfile(lib):
        os.makedirs(out_dir, exist_ok=True)
        tmp = lib + '.%d.tmp' % os.getpid()
        # Windows（clang 出 MSVC 目标）不认 -fPIC，且共享库默认不导出函数：按名导出 yaz0_decompress
        flags = ['-Wl,/EXPORT:yaz0_decompress'] if os.name == 'nt' else ['-fPIC']
        built = subprocess.run([cc, '-O2', *flags, '-shared', '-o', tmp, _YAZ0_C],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if built.returncode != 0:
            try:
                os.remove(tmp)
            except OSError:
                pass
            return None
        try:
            os.replace(tmp, lib)
        except OSError:   # 别的进程同时编好了同一份源码、已经装上（Windows 不许覆盖已加载的 DLL：11-05 天眼旷野之息界面布局 WinError 5，轻阶段退 75）→ 用现成的
            try:
                os.remove(tmp)
            except OSError:
                pass
            if not os.path.isfile(lib):
                raise
    return lib


def _load_lib():
    global _LIB, _TRIED
    if _TRIED:
        return _LIB
    _TRIED = True
    mode = os.environ.get('NXFMT_YAZ0', '')
    if mode in ('py', 'python', '0'):
        return None
    path = os.environ.get('NXFMT_YAZ0LIB') or _compile_lib()
    if not path:
        return None
    try:
        lib = ctypes.CDLL(path)
        lib.yaz0_decompress.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_void_p, ctypes.c_int64]
        lib.yaz0_decompress.restype = ctypes.c_int64
    except (OSError, AttributeError):   # 装不上或没导出这个函数（AttributeError）→ 用纯 Python 解码，结果字节相同
        return None
    _LIB = lib
    return lib


def yaz0_decompress(data):
    """Decompress a Yaz0 buffer. Uses the C library when it loads."""
    lib = _load_lib()
    if lib is None:
        return yaz0_decompress_py(data)
    raw = bytes(data)
    src = ctypes.create_string_buffer(raw)
    n = lib.yaz0_decompress(ctypes.cast(src, ctypes.c_void_p), len(raw), None, 0)
    if n < 0:
        raise ValueError('Yaz0 解码失败')
    if n == 0:
        return b''
    dst = ctypes.create_string_buffer(n)
    got = lib.yaz0_decompress(ctypes.cast(src, ctypes.c_void_p), len(raw),
                              ctypes.cast(dst, ctypes.c_void_p), n)
    if got != n:
        raise ValueError('Yaz0 解码失败')
    return dst.raw


def sarc_members(data):
    """Yield (name, payload) in node order. Unnamed nodes are #{index}."""
    if len(data) < 0x14 or bytes(data[:4]) != b'SARC':
        raise ValueError('不是 SARC')
    e = _bom_endian(data)
    hs = struct.unpack_from(e + 'H', data, 4)[0]
    doff = struct.unpack_from(e + 'I', data, 12)[0]
    if hs < 0x14 or hs + 12 > len(data) or bytes(data[hs:hs + 4]) != b'SFAT':
        raise ValueError('SARC 的 SFAT 头不对')
    count = struct.unpack_from(e + 'H', data, hs + 6)[0]
    nodes = hs + 0x0C
    sfnt = nodes + 16 * count
    if sfnt + 8 > len(data) or bytes(data[sfnt:sfnt + 4]) != b'SFNT':
        raise ValueError('SARC 的 SFNT 头不对')
    if doff > len(data):
        raise ValueError('SARC 数据区越界')
    names = sfnt + 8
    for i in range(count):
        at = nodes + 16 * i
        _h, attr, start, end = struct.unpack_from(e + 'IIII', data, at)
        if end < start or doff + end > len(data):
            raise ValueError('SARC 节点越界')
        if attr >> 24:
            off = (attr & 0xFFFFFF) * 4
            if names + off > len(data):
                raise ValueError('SARC 名字越界')
            raw = bytes(data[names + off:doff]).split(b'\0', 1)[0]
            name = raw.decode('utf-8', 'replace')
        else:
            name = '#%d' % i
        yield name, bytes(data[doff + start:doff + end])


class Sarc:
    def __init__(self, data):
        self._files = [SarcFile(name, blob) for name, blob in sarc_members(data)]

    def get_files(self):
        return list(self._files)

    def get_file(self, name):
        for item in self._files:
            if item.name == name:
                return item
        raise KeyError(name)


class SarcWriter:
    """files is a name → bytes dict, same shape the old call sites assigned into.

    write() returns (alignment, archive_bytes). Call sites use index 1.
    Nodes are stored in (hash, name) order. alignment is a power of two
    applied to each file's absolute offset; the default is 4.
    """

    def __init__(self, endian=Endianness.Little, alignment=4, hash_key=0x65):
        self.endian = endian
        self.alignment = alignment
        self.hash_key = hash_key
        self.files = {}

    def write(self):
        e = _file_endian(self.endian)
        alignment = int(self.alignment)
        if alignment < 1 or alignment & (alignment - 1):
            raise ValueError('alignment 要是 2 的幂')
        key = self.hash_key & 0xFFFFFFFF
        items = []
        for name, blob in self.files.items():
            if not isinstance(name, str):
                name = name.decode('utf-8', 'replace') if isinstance(name, (bytes, bytearray)) else str(name)
            items.append((name_hash(name, key), name, bytes(blob)))
        items.sort(key=lambda row: (row[0], row[1]))
        pool = bytearray()
        nodes = []
        for h, name, blob in items:
            off = len(pool)
            pool += name.encode('utf-8') + b'\0'
            while len(pool) % 4:
                pool.append(0)
            nodes.append((h, 0x01000000 | (off // 4), blob))
        header = bytearray()
        header += b'SARC'
        header += struct.pack(e + 'HHIIHH', 0x14, 0xFEFF, 0, 0, 0x0100, 0)
        header += b'SFAT'
        header += struct.pack(e + 'HHI', 0x0C, len(nodes), key)
        node_at = len(header)
        header += b'\0' * (16 * len(nodes))
        header += b'SFNT'
        header += struct.pack(e + 'HH', 0x08, 0)
        header += pool
        data_off = _align_up(len(header), alignment)
        out = bytearray(header)
        out += b'\0' * (data_off - len(header))
        for i, (h, attr, blob) in enumerate(nodes):
            pos = _align_up(len(out), alignment)
            if pos > len(out):
                out += b'\0' * (pos - len(out))
            start = pos - data_off
            out += blob
            struct.pack_into(e + 'IIII', out, node_at + 16 * i, h, attr, start, start + len(blob))
        struct.pack_into(e + 'I', out, 8, len(out))
        struct.pack_into(e + 'I', out, 12, data_off)
        return alignment, bytes(out)

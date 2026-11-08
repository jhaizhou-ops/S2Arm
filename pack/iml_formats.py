# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Read signing metadata without host tools; never verify signatures or CMS trust.

Formats: RFC 5652 §5.1–5.2; Apple XNU mach-o/loader.h, kern/cs_blobs.h;
Apple Security OSX/utilities/der_plist.c (legacy dictionary SET). Version-1
CoreEntitlements uses APPLICATION 16 {INTEGER 1, [16] dictionary}, as in the
codesign fixtures. This is an independent bounded reader, not copied Apple code.
"""
from __future__ import annotations

import plistlib
import struct

MAX_METADATA = 4 * 1024 * 1024
MAX_ITEMS = 65536


class FormatError(ValueError):
    """Invalid or unsupported input; messages contain no input values or paths."""


class _UniqueDict(dict):
    def __setitem__(self, key, value):
        if key in self:
            raise FormatError("plist 字典含重复键")
        super().__setitem__(key, value)


def read_plist(data: bytes) -> dict:
    if len(data) > MAX_METADATA:
        raise FormatError("plist 超出大小限制")
    try:
        value = plistlib.loads(data, dict_type=_UniqueDict)
    except Exception as exc:
        raise FormatError("plist 格式无效或含重复键") from exc
    if not isinstance(value, dict):
        raise FormatError("plist 顶层必须是字典")
    return value


def same_value(left, right) -> bool:
    """Type-sensitive equality: entitlement true must not compare equal to 1."""
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(same_value(left[k], right[k]) for k in left)
    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(same_value(a, b) for a, b in zip(left, right))
    return left == right


def _items(data):
    """Strict definite-length DER TLVs; returned values are zero-copy views."""
    data = memoryview(data)
    pos = count = 0
    while pos < len(data):
        if count >= MAX_ITEMS or pos + 2 > len(data):
            raise FormatError("DER 项目过多或头被截断")
        tag, size = data[pos], data[pos+1]
        pos += 2
        if tag & 0x1f == 0x1f or tag == 0:
            raise FormatError("不支持的 DER 标签")
        if size & 0x80:
            n = size & 0x7f
            if n == 0 or n > 4 or pos+n > len(data) or data[pos] == 0:
                raise FormatError("DER 长度无效")
            size = int.from_bytes(data[pos:pos+n], "big")
            pos += n
            if size < 128:
                raise FormatError("DER 长度不是最短编码")
        if size > len(data)-pos:
            raise FormatError("DER 内容被截断")
        yield tag, data[pos:pos+size]
        pos += size
        count += 1


def _one(data, tag):
    items = list(_items(data))
    if len(items) != 1 or items[0][0] != tag:
        raise FormatError("DER 结构或标签不符")
    return items[0][1]


def _integer(value):
    if not value or len(value) > 8:
        raise FormatError("DER 整数长度无效")
    if len(value) > 1 and ((value[0] == 0 and value[1] < 128) or (value[0] == 255 and value[1] >= 128)):
        raise FormatError("DER 整数不是最短编码")
    return int.from_bytes(value, "big", signed=True)


def _der_value(tag, value, depth=0, budget=None):
    budget = [MAX_ITEMS] if budget is None else budget
    budget[0] -= 1
    if depth > 32 or budget[0] < 0:
        raise FormatError("DER 权限嵌套或项目数超限")
    if tag == 1:
        if bytes(value) not in (b"\0", b"\xff"):
            raise FormatError("DER 布尔值无效")
        return value[0] == 255
    if tag == 2:
        return _integer(value)
    if tag == 12:
        try:
            return bytes(value).decode("utf-8")
        except UnicodeError as exc:
            raise FormatError("DER 字符串不是 UTF-8") from exc
    if tag == 4:
        return bytes(value)
    if tag == 0x30:
        return [_der_value(t, v, depth+1, budget) for t, v in _items(value)]
    if tag in (0x31, 0xb0):
        result = {}
        for t, pair in _items(value):
            fields = list(_items(pair))
            if t != 0x30 or len(fields) != 2 or fields[0][0] != 12:
                raise FormatError("DER 字典项无效")
            key = _der_value(*fields[0], depth+1, budget)
            if key in result:
                raise FormatError("DER 字典含重复键")
            result[key] = _der_value(*fields[1], depth+1, budget)
        return result
    raise FormatError("不支持的 DER 权限值类型")


def _der_entitlements(data):
    if len(data) > MAX_METADATA:
        raise FormatError("DER 权限超出大小限制")
    fields = list(_items(data))
    if len(fields) != 1:
        raise FormatError("DER 权限含多余内容")
    tag, value = fields[0]
    if tag == 0x70:
        fields = list(_items(value))
        if len(fields) != 2 or fields[0][0] != 2 or _integer(fields[0][1]) != 1 or fields[1][0] != 0xb0:
            raise FormatError("不支持的 DER 权限版本")
        tag, value = fields[1]
    elif tag != 0x31:
        raise FormatError("DER 权限顶层不是字典")
    return _der_value(tag, value)


def read_profile(data: bytes) -> dict:
    """Extract CMS SignedData eContent plist; no certificate/signature validation."""
    if len(data) > MAX_METADATA:
        raise FormatError("描述文件超出大小限制")
    fields = list(_items(_one(data, 0x30)))
    signed_oid = b"\x2a\x86\x48\x86\xf7\x0d\x01\x07\x02"
    data_oid = b"\x2a\x86\x48\x86\xf7\x0d\x01\x07\x01"
    if len(fields) != 2 or fields[0] != (6, signed_oid) or fields[1][0] != 0xa0:
        raise FormatError("描述文件不是 CMS SignedData")
    signed = list(_items(_one(fields[1][1], 0x30)))
    if len(signed) < 4 or signed[0][0] != 2 or signed[1][0] != 0x31 or signed[2][0] != 0x30:
        raise FormatError("CMS SignedData 结构无效")
    _integer(signed[0][1])
    remaining = signed[3:]
    for optional in (0xa0, 0xa1):
        if remaining and remaining[0][0] == optional:
            remaining = remaining[1:]
    if len(remaining) != 1 or remaining[0][0] != 0x31:
        raise FormatError("CMS signerInfos 结构无效")
    encap = list(_items(signed[2][1]))
    if len(encap) != 2 or encap[0] != (6, data_oid) or encap[1][0] != 0xa0:
        raise FormatError("CMS 缺少内嵌 data eContent")
    payload = _one(encap[1][1], 4)
    return read_plist(bytes(payload))


def _u32(data, offset, endian=">"):
    if offset < 0 or offset+4 > len(data):
        raise FormatError("Mach-O / 签名字段被截断")
    return struct.unpack_from(endian+"I", data, offset)[0]


def _signature(data):
    if len(data) < 12 or _u32(data, 0) != 0xfade0cc0:
        raise FormatError("不是内嵌签名 SuperBlob")
    length, count = _u32(data, 4), _u32(data, 8)
    table_end = 12 + count*8
    if length > len(data) or length < table_end or count > MAX_ITEMS:
        raise FormatError("SuperBlob 长度或索引无效")
    data = data[:length]
    seen, ranges, entitlements = set(), [], {}
    for i in range(count):
        slot, offset = _u32(data, 12+i*8), _u32(data, 16+i*8)
        if slot in seen or offset < table_end:
            raise FormatError("SuperBlob 槽重复或偏移落入索引")
        seen.add(slot)
        magic, size = _u32(data, offset), _u32(data, offset+4)
        if size < 8 or size > len(data)-offset:
            raise FormatError("签名 blob 越界")
        ranges.append((offset, offset+size))
        if slot in (5, 7):
            if size-8 > MAX_METADATA or magic != {5: 0xfade7171, 7: 0xfade7172}[slot]:
                raise FormatError("权限 blob 类型或大小无效")
            raw = data[offset+8:offset+size]
            entitlements[slot] = read_plist(bytes(raw)) if slot == 5 else _der_entitlements(raw)
    ordered = sorted(ranges)
    if any(b[0] < a[1] for a, b in zip(ordered, ordered[1:])):
        raise FormatError("签名 blob 重叠")
    if not entitlements:
        raise FormatError("签名没有 XML / DER 权限")
    if 5 in entitlements and 7 in entitlements and not same_value(entitlements[5], entitlements[7]):
        raise FormatError("XML 与 DER 权限不一致")
    return entitlements[5] if 5 in entitlements else entitlements[7]


_THIN = {b"\xce\xfa\xed\xfe": ("<", 28), b"\xcf\xfa\xed\xfe": ("<", 32),
         b"\xfe\xed\xfa\xce": (">", 28), b"\xfe\xed\xfa\xcf": (">", 32)}
_FAT = {b"\xca\xfe\xba\xbe": (">", 20), b"\xbe\xba\xfe\xca": ("<", 20),
        b"\xca\xfe\xba\xbf": (">", 32), b"\xbf\xba\xfe\xca": ("<", 32)}


def _thin(data):
    magic = bytes(data[:4])
    if magic not in _THIN:
        raise FormatError("不支持的 Mach-O 头")
    endian, header = _THIN[magic]
    if len(data) < header:
        raise FormatError("Mach-O 头被截断")
    ncmds, size = _u32(data, 16, endian), _u32(data, 20, endian)
    end = header+size
    if end > len(data) or ncmds > size//8 or ncmds > MAX_ITEMS:
        raise FormatError("Mach-O load commands 长度无效")
    pos, found = header, None
    for _ in range(ncmds):
        if pos+8 > end:
            raise FormatError("Mach-O load command 被截断")
        command, length = _u32(data, pos, endian), _u32(data, pos+4, endian)
        if length < 8 or length % (8 if header == 32 else 4) or length > end-pos:
            raise FormatError("Mach-O cmdsize 无效")
        if command == 0x1d:
            if found is not None or length != 16:
                raise FormatError("LC_CODE_SIGNATURE 重复或大小无效")
            offset, count = _u32(data, pos+8, endian), _u32(data, pos+12, endian)
            if offset < end or count > len(data)-offset or offset > len(data):
                raise FormatError("LC_CODE_SIGNATURE 数据越界")
            found = (offset, count)
        pos += length
    if pos != end or found is None:
        raise FormatError("Mach-O 命令长度不符或缺签名")
    offset, count = found
    return _signature(data[offset:offset+count])


def read_macho_entitlements(data: bytes) -> list[dict]:
    """Return one dictionary per slice, rejecting malformed or conflicting blobs."""
    data = memoryview(data)
    magic = bytes(data[:4])
    if magic in _THIN:
        return [_thin(data)]
    if magic not in _FAT:
        raise FormatError("不是支持的 Mach-O / FAT 文件")
    endian, entry_size = _FAT[magic]
    count = _u32(data, 4, endian)
    table_end = 8+count*entry_size
    if not 1 <= count <= 64 or table_end > len(data):
        raise FormatError("FAT 架构表无效")
    ranges, result = [], []
    for i in range(count):
        pos = 8+i*entry_size
        cpu, sub = struct.unpack_from(endian+"II", data, pos)
        if entry_size == 20:
            offset, size, align = struct.unpack_from(endian+"III", data, pos+8)
        else:
            offset, size, align, reserved = struct.unpack_from(endian+"QQII", data, pos+8)
            if reserved:
                raise FormatError("FAT64 保留字段不为零")
        if align > 63 or offset % (1 << align) or offset < table_end or not size or offset > len(data) or size > len(data)-offset:
            raise FormatError("FAT 切片越界或对齐无效")
        piece = data[offset:offset+size]
        piece_magic = bytes(piece[:4])
        if piece_magic not in _THIN:
            raise FormatError("FAT 切片不是 Mach-O")
        pe, _ = _THIN[piece_magic]
        if (cpu, sub) != (_u32(piece, 4, pe), _u32(piece, 8, pe)):
            raise FormatError("FAT 表与切片架构不一致")
        ranges.append((offset, offset+size))
        result.append(_thin(piece))
    ranges.sort()
    if any(b[0] < a[1] for a, b in zip(ranges, ranges[1:])):
        raise FormatError("FAT 切片重叠")
    return result

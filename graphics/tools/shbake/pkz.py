"""PKZ / DAT 与 NVN VSO / PSO / CSO 包装，只读且不依赖游戏名。

PKZ 索引布局交叉参考 bayonetta_tools/lib/bayonetta/pkz.rb（BSD-2-Clause），
本实现按样本结构独立编写；来源、字段和验证范围见 docs/研究/PKZ_DAT_抽取.md。
不按成员名写文件；调用方提供有输出长度上限的 Zstandard 解码函数。
"""

import struct
from dataclasses import dataclass


MAX_MEMBER = 512 << 20
MAX_ENTRIES = 1_000_000
STAGES = {b'VSO\0': 'vs', b'HSO\0': 'hs', b'DSO\0': 'ds',
          b'GSO\0': 'gs', b'PSO\0': 'ps', b'CSO\0': 'cs'}


class FormatError(ValueError):
    """已认出的容器损坏或使用尚未支持的布局，不得当作抽取成功。"""


def bounds(data, offset, size, label):
    if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
        raise FormatError(f'{label} 越界')


def span(data, offset, size, label):
    bounds(data, offset, size, label)
    return data[offset:offset + size]


def words(data, offset, count, label):
    return struct.unpack('<' + 'I' * count, span(data, offset, count * 4, label))


def string(data, offset, label):
    if not 0 <= offset < len(data):
        raise FormatError(f'{label} 偏移越界')
    end = data.find(b'\0', offset)
    if end < 0:
        raise FormatError(f'{label} 未终止')
    try:
        value = data[offset:end].decode('utf-8')
    except UnicodeDecodeError as e:
        raise FormatError(f'{label} 不是 UTF-8') from e
    if not value or any(c in value for c in '\t\r\n'):
        raise FormatError(f'{label} 为空或含表格控制字符')
    return value


@dataclass(frozen=True)
class Member:
    name: str
    compression: str
    size: int
    offset: int
    stored: int


def index_entries(data):
    """只读索引；保留压缩方式供清单统计，不承诺成员可解码。"""
    if span(data, 0, 4, 'PKZ 魔数') != b'pkzl':
        raise FormatError('不是 PKZ')
    span(data, 0, 32, 'PKZ 头')
    if struct.unpack_from('<Q', data, 8)[0] != len(data):
        raise FormatError('PKZ 文件长度不符')
    count, table, names_size = words(data, 16, 3, 'PKZ 索引头')
    if count > MAX_ENTRIES or table < 32 or names_size > 64 << 20:
        raise FormatError('PKZ 索引大小或偏移不支持')
    bounds(data, table, count * 32, 'PKZ 索引')
    names_at = table + count * 32
    names = span(data, names_at, names_size, 'PKZ 字符串表')
    result = []
    for i in range(count):
        no, mo, size, offset, stored = struct.unpack_from('<IIQQQ', data, table + i * 32)
        name = string(names, no, 'PKZ 成员名')
        method = string(names, mo, 'PKZ 压缩方式')
        if size > MAX_MEMBER or stored > MAX_MEMBER:
            raise FormatError(f'PKZ 成员 {i} 超过 {MAX_MEMBER} 字节上限')
        bounds(data, offset, stored, 'PKZ 成员')
        if offset < names_at + names_size:
            raise FormatError('PKZ 成员与索引重叠')
        if method == 'None' and size != stored:
            raise FormatError('PKZ 未压缩成员长度不符')
        result.append(Member(name, method, size, offset, stored))
    return result


def is_oodle(method):
    """OodleKraken / OodleMermaid / … 一族（猎天使魔女3 的 root_000.pkz 等 11,760 个成员是 OodleKraken）：只有游戏自带的 OodleLZ_Decompress 能解。"""
    return method.startswith('Oodle')


def entries(data, oodle=False):
    """抽取入口：索引合法且每个成员的压缩方式均已支持；oodle=True 时 Oodle* 也放行（调用方要给 read() 游戏解码器）。"""
    result = index_entries(data)
    for member in result:
        if member.compression not in ('None', 'ZStandard') and not (oodle and is_oodle(member.compression)):
            raise FormatError(f'PKZ 不支持压缩方式 {member.compression}')
    return result


def read(data, member, decompress, oodle_decompress=None):
    """只取一个成员；解码器接收 (压缩字节, 索引原长)，不能无上限解压。
    oodle_decompress：游戏自带解码器（宿主工具模式，translator/uepak.py OodleHost）；Oodle* 成员没给它就报错说明原因，不静默跳过。"""
    if member.compression not in ('None', 'ZStandard') and not is_oodle(member.compression):
        raise FormatError(f'PKZ 不支持压缩方式 {member.compression}')
    payload = span(data, member.offset, member.stored, 'PKZ 成员')
    if member.compression == 'ZStandard':
        try:
            payload = decompress(payload, member.size)
        except Exception as e:
            raise FormatError(f'PKZ ZStandard 解码失败：{e}') from e
    elif is_oodle(member.compression):
        if oodle_decompress is None:
            raise FormatError(f'PKZ 成员 {member.name} 是 {member.compression}，需要游戏自带解码器（宿主工具模式：设 DM_OODLE_HOST 与 DM_OODLE_MODULES）')
        try:
            payload = oodle_decompress(payload, member.size)
        except Exception as e:
            raise FormatError(f'PKZ {member.compression} 解码失败（{member.name}）：{e}') from e
    if len(payload) != member.size:
        raise FormatError('PKZ 解压后长度与索引不符')
    return payload


def dat_entries(data):
    """DAT\0 的偏移 / 扩展名 / 定宽名字 / 长度表；保留同名的不同条目。"""
    if span(data, 0, 4, 'DAT 魔数') != b'DAT\0':
        raise FormatError('不是 DAT')
    span(data, 0, 32, 'DAT 头')
    count, offsets_at, ext_at, names_at, sizes_at = words(data, 4, 5, 'DAT 索引头')
    if count > MAX_ENTRIES:
        raise FormatError('DAT 条目数过大')
    if not count:
        return []
    if min(offsets_at, ext_at, names_at, sizes_at) < 32:
        raise FormatError('DAT 索引与文件头重叠')
    offsets = words(data, offsets_at, count, 'DAT 偏移表')
    sizes = words(data, sizes_at, count, 'DAT 长度表')
    extensions = span(data, ext_at, count * 4, 'DAT 扩展名表')
    stride, = words(data, names_at, 1, 'DAT 名字宽度')
    if not 0 < stride <= 4096 or count * stride > 64 << 20:
        raise FormatError('DAT 名字表过大或宽度无效')
    names = span(data, names_at + 4, count * stride, 'DAT 名字表')
    result = []
    metadata_end = max(offsets_at + count * 4, ext_at + count * 4,
                       names_at + 4 + count * stride, sizes_at + count * 4)
    for i, (offset, size) in enumerate(zip(offsets, sizes)):
        name = string(names[i * stride:(i + 1) * stride], 0, 'DAT 成员名')
        ext = string(extensions[i * 4:(i + 1) * 4], 0, 'DAT 扩展名')
        if not name.lower().endswith('.' + ext.lower()):
            raise FormatError('DAT 名字与扩展名不符')
        # DAT / DTT 用 (偏移 0, 长度 0) 保留不存在的资源槽；只对有数据的成员要求在索引之后。
        if size > MAX_MEMBER or (size and offset < metadata_end):
            raise FormatError('DAT 成员过大或与索引重叠')
        bounds(data, offset, size, 'DAT 成员')
        result.append((i, name, offset, size))
    return result


def shader(data):
    """包装 → (阶段, 完整控制段, 完整机器码)，键由调用方沿用运行时算法。"""
    stage = STAGES.get(bytes(data[:4]))
    if not stage:
        raise FormatError('未知着色器包装')
    _, cn, co, dn, do = words(data, 4, 5, '着色器包装')
    if co != 24 or do != co + cn or do + dn != len(data):
        raise FormatError('着色器包装的分段偏移或长度不符')
    ctl = span(data, co, cn, '控制段')
    code = span(data, do, dn, '机器码')
    if cn < 0x708 or ctl[:4] != bytes.fromhex('34127698'):
        raise FormatError('NVN 控制段无效或过短')
    if words(ctl, 0x20, 1, '控制段长度')[0] != cn:
        raise FormatError('NVN 控制段自报长度不符')
    c1, code_size = words(ctl, 0x700, 2, '代码与常量长度')
    if code_size != dn or c1 > dn:
        raise FormatError('NVN 机器码或常量范围不符')
    if stage == 'cs':
        local = words(ctl, 0x748, 3, '计算线程组')
        words(ctl, 0x754, 1, '计算共享内存')
        if not all(local) or code[:4] == bytes.fromhex('78563412'):
            raise FormatError('计算着色器线程组为 0 或带图形代码头')
        # 计算代码区两种形态：无头（指令从 +0）或带 0x12345679 头（0x30 头 + 补零，指令从 +0x100）。
        #   后者与 translator/dmsh_build.py job_for 剥头同一约定；猎天使魔女3 shadereffcs.dat 67 支全是这种（10-28 实测 +0x30..+0x100 全零）
        if code[:4] == bytes.fromhex('79563412') and (dn <= 0x100 or any(code[0x30:0x100])):
            raise FormatError('计算着色器带 0x12345679 头，但 +0x30..+0x100 不全为零（指令起点不在 +0x100）')
    else:
        if dn < 0x80 or code[:4] != bytes.fromhex('78563412'):
            raise FormatError('图形着色器缺少代码头或 SPH')
        ty = words(code, 0x30, 1, 'SPH')[0] >> 10 & 15
        expected = {'vs': (0, 1), 'hs': (2,), 'ds': (3,), 'gs': (4,), 'ps': (5,)}[stage]
        if ty not in expected:
            raise FormatError('包装阶段与 SPH 不符')
    return stage, ctl, code

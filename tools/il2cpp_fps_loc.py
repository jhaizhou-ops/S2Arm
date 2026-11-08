#!/usr/bin/env python3
"""Q6: read-only IL2CPP (v29/v31) / AArch64 generated setter entry locator.

Inputs: global-metadata.dat and an already mapped, uncompressed, little-endian
64-bit image. File offset 0 maps to --image-base; pointers must already use that
address space. --codegen-module is the address of its Il2CppCodeGenModule; when
given it is checked against the metadata image name. When omitted, the image that
declares Application / QualitySettings is taken from metadata (call sites live in
game images such as Assembly-CSharp, the setters in an engine image such as
UnityEngine.CoreModule.dll; other images' modules are not ambiguity), and only
that image's module is located structurally (name string pointed to by the module
record, pointer table inside the image, method count equal to that image's
metadata method count) and only a unique match is used. --text-start/--text-size
bound instruction scanning. No NSO decompression, relocations, execution or patching.

Example: python3 tools/il2cpp_fps_loc.py metadata.dat mapped.bin \
  --image-base 0 --text-start 0x100 --text-size 0x80000

Supported metadata versions: v29 and v31 (Silksong, Unity 6000.0). v24.0 (Hollow Knight, Unity
2017.4) metadata is parsed but rejected at locate: it has no CodeGenModule. Header section
count, table indices and record sizes are fixed per version (see METADATA_LAYOUT). Layout
references (layouts only; no external code executed or vendored):
https://github.com/Perfare/Il2CppDumper/tree/4741d46ba9cd6159c5d853eb9d6fc48b4bfa2b1a/Il2CppDumper/Il2Cpp
MetadataClass.cs / Il2CppClass.cs and Il2Cpp.cs GetMethodPointer.
Method token RID indexes the module method pointer table, NOT the global method
index. A generated method may only wrap a Unity engine icall: this tool does not
resolve that engine implementation. BL hits are instruction-pattern candidates
within caller-supplied text, not proof of reachability. Indirect calls, tail calls,
inlined sites, other architectures/versions and actual game effects are untested.
Exit 0: both setters mapped; 1: unsupported/invalid/ambiguous input; 2: CLI usage.
"""
import argparse
import hashlib
import json
import os
import stat
from pathlib import Path
import struct
import sys

MAX_BYTES = 512 * 1024 * 1024
TARGETS = (('Application', 'set_targetFrameRate'), ('QualitySettings', 'set_vSyncCount'))

# 各版本写死：头部段数（Il2CppGlobalMetadataHeader 里 (偏移, 长度) 对的个数）、四张表的段序号、记录长度与字段偏移。
# 依据两份真文件头部（unity-swap-3 读数 xxd；相邻段首尾相接、记录长度整除段长）：
#   丝之歌 v31（自报 Unity 6000.0.50f1）：第 0 段偏移 0x100 = 8 + 31×8；第 5 段（方法）长 0x4948ec = 36×133411；
#     第 19 段（类型）0x188170 = 88×18250；第 20 段（image）0xc80 = 40×80；第 21 段（程序集）0x1400 = 64×80
#   空洞骑士 v24（自报 Unity 2017.4.10f1，即 24.0：比 v29 多 rgctx 一段）：第 0 段偏移 0x110 = 8 + 33×8；
#     第 5 段 0x2019c8 = 56×37567；第 19 段 0x9a808 = 104×6085；第 20 段（rgctx）0x1bd0 = 8×890；
#     第 21 段（image）0x400 = 32×32；第 22 段（程序集）0x880 = 68×32
# 方法记录以 token(u32)、flags、iflags、slot、parameterCount(u16) 收尾：token = 长度 − 12。v31 比 v29 多的 4 字节在 token 前
# （按 Il2CppDumper 布局是 returnParameterToken，未逐字节核对）。类型记录以 8 个 int 起点、8 个 u16 计数、bitfield、token 收尾：
# methodStart = 长度 − 52，method_count = 长度 − 24。
METADATA_LAYOUT = {
    24: {'header_pairs': 33, 'sec_strings': 2, 'sec_methods': 5, 'sec_types': 19, 'sec_images': 21,
         'method': 56, 'type': 104, 'image': 32, 'type_method_start': 52, 'type_method_count': 80,
         'codegen_module': False},
    29: {'header_pairs': 31, 'sec_strings': 2, 'sec_methods': 5, 'sec_types': 19, 'sec_images': 20,
         'method': 32, 'type': 88, 'image': 40, 'type_method_start': 36, 'type_method_count': 64,
         'codegen_module': True, 'method_token': 20, 'method_flags': 24, 'method_params': 30},
    31: {'header_pairs': 31, 'sec_strings': 2, 'sec_methods': 5, 'sec_types': 19, 'sec_images': 20,
         'method': 36, 'type': 88, 'image': 40, 'type_method_start': 36, 'type_method_count': 64,
         'codegen_module': True, 'method_token': 24, 'method_flags': 28, 'method_params': 34},
}


class Invalid(ValueError):
    pass


def require(ok, message):
    if not ok:
        raise Invalid(message)


def span(data, start, size):
    require(0 <= start <= len(data) and 0 <= size <= len(data) - start, 'range outside input')
    return data[start:start + size]


def cstring(data, offset, end):
    require(0 <= offset < end <= len(data), 'string outside table')
    stop = data.find(b'\0', offset, min(end, offset + 4096))
    require(stop >= 0, 'unterminated/oversized string')
    try:
        return data[offset:stop].decode('utf-8')
    except UnicodeDecodeError as exc:
        raise Invalid('invalid UTF-8 name') from exc


def tables(metadata):
    """校验头部与记录表，返回版本号、取名函数与方法 / 类型 / image 三张表的 (offset, count)。

    段表只读本版本头部里的那几段：头部之后紧接字面量表，往后多读出来的「段」是数据
    （第 2 轮按 60 段盲扫，v29 夹具读进字符串表、两份真文件读进字面量表）。
    """
    require(len(metadata) >= 8, 'truncated metadata header')
    magic, version = struct.unpack_from('<II', metadata)
    require(magic == 0xFAB11BAF and version in METADATA_LAYOUT,
            'unsupported metadata (magic 0x%08X, version %d; supported: v24.0, v29, v31)' % (magic, version))
    layout = METADATA_LAYOUT[version]
    header = 8 + 8 * layout['header_pairs']
    require(len(metadata) >= header, 'truncated metadata header')
    sections = [struct.unpack_from('<II', metadata, 8 + i * 8) for i in range(layout['header_pairs'])]
    # 字面量表（第 0 段）紧接头部，两份真文件都是；对不上 = 同版本号下段数不同的头部（如 v24.2 去掉了 rgctx 段）
    require(sections[0][1] == 0 or sections[0][0] == header, 'metadata header length mismatch (unsupported sub-version)')
    occupied = []
    for offset, size in sections:
        if size:
            require(offset >= header, 'metadata section overlaps header')
            span(metadata, offset, size)
            occupied.append((offset, offset + size))
    occupied.sort()
    require(all(a[1] <= b[0] for a, b in zip(occupied, occupied[1:])), 'overlapping metadata sections')

    def table(section, stride):
        off, size = sections[section]
        require(size > 0 and size % stride == 0 and off % 4 == 0, 'invalid metadata record table')
        return off, size // stride
    so, sn = sections[layout['sec_strings']]
    require(sn > 0, 'missing names')

    def name(index):
        require(index < sn, 'name index outside string table')
        return cstring(metadata, so + index, so + sn)
    return (version, name, table(layout['sec_methods'], layout['method']),
            table(layout['sec_types'], layout['type']), table(layout['sec_images'], layout['image']))


def type_ranges(metadata, version, name, to, tc, io, ic, mc):
    """每个 image 的 (名, 起始类型, 类型数, 方法总数)。"""
    layout = METADATA_LAYOUT[version]
    type_stride, image_stride = layout['type'], layout['image']
    method_start_off, method_count_off = layout['type_method_start'], layout['type_method_count']

    images = []
    for i in range(ic):
        ni, _, first, total = struct.unpack_from('<IiiI', metadata, io + i * image_stride)
        require((total == 0 and first == -1) or (0 <= first <= tc and total <= tc - first), 'invalid image type range')
        methods = 0
        for ti in range(first, first + total):
            off = to + ti * type_stride
            start = struct.unpack_from('<i', metadata, off + method_start_off)[0]
            count = struct.unpack_from('<H', metadata, off + method_count_off)[0]
            require((count == 0 and start == -1) or (0 <= start <= mc and count <= mc - start), 'invalid type method range')
            methods += count
        images.append((name(ni), first, total, methods))
    return images


def module_candidates(image, image_base, images, text_start, text_size):
    """结构定位 Il2CppCodeGenModule：记录 +0 名字串、+8 方法数、+16 指针表。

    一遍 8 字节步进扫镜像，命中「等于某个 image 名串地址」的字，再校验记录本身：名字串
    就是该地址、方法数与指针表都落在镜像内、表内每项为空或在 text 内。先按「方法数等于该
    image 的元数据方法总数」严格找，找不到再放宽到只要求上述结构校验。
    返回 (候选列表, 是否严格)。候选列表每项为 (地址, 名字, 方法数, 指针表VA, 是否strict)。
    """
    addrs = {}
    for iname, _, _, methods in images:
        if methods <= 0:
            continue
        raw = iname.encode('utf-8') + b'\0'
        pos = image.find(raw)
        while pos != -1:
            addrs[image_base + pos] = (iname, methods)
            pos = image.find(raw, pos + 1)
    strict, relaxed = [], []
    for pos in range(0, len(image) - 23, 8):
        hit = addrs.get(struct.unpack_from('<Q', image, pos)[0])
        if hit is None:
            continue
        try:
            name_va, count, pointers_va = struct.unpack_from('<QQQ', image, pos)
            require(name_va in addrs and count > 0, 'module record mismatch')
            offset = pointers_va - image_base
            require(0 <= offset and count * 8 <= len(image) - offset, 'pointer table outside image')
            for entry in struct.unpack_from('<%dQ' % count, image, offset):
                require(entry == 0 or text_start <= entry < text_start + text_size, 'method pointer outside text')
        except (Invalid, struct.error):
            continue
        record = (image_base + pos, hit[0], count, pointers_va, count == hit[1])
        (strict if count == hit[1] else relaxed).append(record)
    candidates = strict or relaxed
    return sorted(set(candidates)), bool(strict)


def locate(metadata, image, image_base, codegen_module, text_start, text_size):
    require(len(metadata) <= MAX_BYTES and len(image) <= MAX_BYTES, 'input exceeds 512 MiB budget')
    require(0 <= image_base < 2**64 and len(image) <= 2**64 - image_base, 'invalid image address space')
    require(text_start % 4 == 0 and text_size > 0 and text_size % 4 == 0, 'text must be nonempty and instruction aligned')
    text = span(image, text_start - image_base, text_size)
    version, name, (mo, mc), (to, tc), (io, ic) = tables(metadata)
    layout = METADATA_LAYOUT[version]
    method_stride, type_stride = layout['method'], layout['type']
    images = type_ranges(metadata, version, name, to, tc, io, ic, mc)

    require(layout['codegen_module'], 'metadata v24.0 has no Il2CppCodeGenModule (method pointers are '
            'CodeRegistration.methodPointers[methodIndex]); not supported')

    # 名字 +0、命名空间 / 所属类型 +4 各版本相同；其余偏移见 METADATA_LAYOUT
    type_name_off, type_ns_off = 0, 4
    type_method_start_off, type_method_count_off = layout['type_method_start'], layout['type_method_count']
    method_name_off, method_declaring_off = 0, 4
    method_token_off, method_flags_off, method_params_off = layout['method_token'], layout['method_flags'], layout['method_params']

    # 第一遍：在全部 image 的类型表里找两个 setter，记下它们各自所在的 image 名。
    # 调用点在游戏代码（Assembly-CSharp 等），setter 在引擎 image（UnityEngine.CoreModule.dll 等）；
    # 两个 image 各用各的 CodeGenModule，镜像里同时存在别的 image 的模块不是歧义。
    hits = []
    for iname, ifirst, itotal, _ in images:
        for ti in range(ifirst, ifirst + itotal):
            off = to + ti * type_stride
            ni, ns = struct.unpack_from('<II', metadata, off + type_name_off)
            cls, namespace = name(ni), name(ns)
            method_start = struct.unpack_from('<i', metadata, off + type_method_start_off)[0]
            method_count = struct.unpack_from('<H', metadata, off + type_method_count_off)[0]
            require((method_count == 0 and method_start == -1) or (0 <= method_start <= mc and method_count <= mc - method_start), 'invalid type method range')
            if namespace != 'UnityEngine' or cls not in ('Application', 'QualitySettings'):
                continue
            for mi in range(method_start, method_start + method_count):
                moff = mo + mi * method_stride
                ni = struct.unpack_from('<I', metadata, moff + method_name_off)[0]
                declaring = struct.unpack_from('<i', metadata, moff + method_declaring_off)[0]
                token = struct.unpack_from('<I', metadata, moff + method_token_off)[0]
                flags = struct.unpack_from('<H', metadata, moff + method_flags_off)[0]
                parameters = struct.unpack_from('<H', metadata, moff + method_params_off)[0]
                require(declaring == ti, 'method declaring type mismatch')
                key = (cls, name(ni))
                if key not in TARGETS:
                    continue
                require(flags & 0x10 and parameters == 1, 'setter must be static with one parameter')
                hits.append((iname, key, token))
    require(hits, 'setter missing or ambiguous')

    # 第二遍：每个被用到的 image 各取自己的模块；同名仍不唯一才判不出
    needed = sorted({hit[0] for hit in hits})
    if codegen_module is not None:
        require(codegen_module % 8 == 0, 'unaligned CodeGenModule')
        require(len(needed) == 1, 'module must identify exactly one metadata image')
        modules = {needed[0]: (codegen_module, True)}
    else:
        modules = {}
        for iname in needed:
            candidates, strict = module_candidates(
                image, image_base, [i for i in images if i[0] == iname], text_start, text_size)
            if len(candidates) != 1:
                # 输出候选清单：地址、名字、方法数、指针表范围、是否 strict 匹配
                detail = []
                for addr, cname, count, ptr_va, is_strict in candidates:
                    detail.append('  %#x: %s, %d methods, pointers @%#x, %s' %
                                 (addr, cname, count, ptr_va, 'strict' if is_strict else 'relaxed'))
                raise Invalid('codegen module %s: image %s%s' % (
                    'not found' if not candidates else 'ambiguous', iname,
                    (':\n' + '\n'.join(detail)) if detail else ''))
            modules[iname] = (candidates[0][0], strict)

    tables_ = {}
    for iname, (module_va, _) in modules.items():
        module_name_va, count, pointers_va = struct.unpack('<QQQ', span(image, module_va - image_base, 24))
        name_at_va = cstring(image, module_name_va - image_base, len(image))
        require(name_at_va == iname, 'module name does not match the image that declares the setter')
        require(0 < count <= len(image) // 8 and pointers_va % 8 == 0, 'invalid method pointer table')
        tables_[iname] = (span(image, pointers_va - image_base, count * 8), count)

    found = {key: [] for key in TARGETS}
    for iname, key, token in hits:
        pointers, count = tables_[iname]
        rid = token & 0xffffff
        require(token >> 24 == 6 and 1 <= rid <= count, 'method token outside module table')
        entry = struct.unpack_from('<Q', pointers, (rid - 1) * 8)[0]
        require(entry != 0 and entry % 4 == 0 and text_start <= entry < text_start + text_size, 'method pointer null/unaligned/outside text')
        found[key].append({'type': key[0], 'method': key[1], 'token': token, 'entry_va': entry,
                           'module': iname, 'direct_bl_candidates': []})
    require(all(len(v) == 1 for v in found.values()), 'setter missing or ambiguous')
    methods = [found[key][0] for key in TARGETS]
    for offset in range(0, len(text), 4):
        word = struct.unpack_from('<I', text, offset)[0]
        if word & 0xfc000000 != 0x94000000:
            continue
        immediate = word & 0x3ffffff
        if immediate & 0x2000000:
            immediate -= 0x4000000
        pc = text_start + offset
        for method in methods:
            if pc + immediate * 4 == method['entry_va']:
                method['direct_bl_candidates'].append(pc)
    module_list = [{'name': iname, 'codegen_module': modules[iname][0],
                    'module_match': 'strict_method_count' if modules[iname][1] else 'relaxed_structure'}
                   for iname in needed]
    return {'schema': 1, 'metadata_version': version, 'architecture': 'aarch64-le64',
            'module': ', '.join(m['name'] for m in module_list), 'image_base': image_base,
            'codegen_module': module_list[0]['codegen_module'],
            'module_match': module_list[0]['module_match'], 'modules': module_list,
            'entry_kind': 'generated_method_not_resolved_engine_icall',
            'call_scope': 'direct_BL_patterns_in_supplied_text_not_reachability',
            'methods': methods, 'metadata_sha256': hashlib.sha256(metadata).hexdigest(),
            'image_sha256': hashlib.sha256(image).hexdigest()}


def read_input(path):
    require(Path(path).is_file(), 'input must be a regular file')
    with Path(path).open('rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_size <= MAX_BYTES, 'input must be regular and at most 512 MiB')
        data = stream.read(MAX_BYTES + 1)
    require(len(data) <= MAX_BYTES, 'input exceeds 512 MiB budget')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('metadata')
    parser.add_argument('image')
    for option in ('text-start', 'text-size'):
        parser.add_argument('--' + option, required=True, type=lambda s: int(s, 0))
    parser.add_argument('--image-base', type=lambda s: int(s, 0), default=0)
    parser.add_argument('--codegen-module', type=lambda s: int(s, 0))
    args = parser.parse_args()
    try:
        result = locate(read_input(args.metadata), read_input(args.image), args.image_base,
                        args.codegen_module, args.text_start, args.text_size)
    except (Invalid, OSError) as exc:
        print(json.dumps({'status': 'unresolved', 'error': str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""给合成包造一个"运行时和 LibHac 都认"的 main.npdm（不是游戏数据，只用于直连链路探针）。

做法是**以 Ryujinx 自带的 Homebrew.npdm 为模板**（compat/tree/src/Ryujinx.HLE/Homebrew.npdm，
它是一份合法 NPDM：META/ACID/ACI0 齐全，LibHac 的 MetaLoader.GetNpdmFromBuffer 返回 Success），
只改三处：META 的地址空间类型位（+0x0C = 6，即 64-bit，运行时的 (b>>1)&7 == 3）、ACI0 的程序号
（+0x10）、ACID 的 ProgramIdMin/Max。不要手工从零拼 NPDM —— 那样 LibHac 会报
`ResultLoaderInvalidMeta (2009-0004)`（真机实测过）。

改完按目录内容重写 index.tsv / manifest.json / game-build-artifact.json。

用法：
  synthetic_npdm.py <pack 目录> [--program-id 0100000000ABCDEF]
"""
import argparse
import hashlib
import json
import os
import struct
import sys

TEMPLATE = 'compat/tree/src/Ryujinx.HLE/Homebrew.npdm'


def repo_root():
    # <repo>/platforms/android/tools/this.py → 上四级是仓库根
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def build_npdm(program_id):
    path = os.path.join(repo_root(), TEMPLATE)
    if not os.path.isfile(path):
        sys.exit(f'NPDM 模板缺失：{path}（合成包不能用伪造的 NPDM：LibHac 会报 2009-0004）')
    data = bytearray(open(path, 'rb').read())
    aci = struct.unpack_from('<i', data, 0x70)[0]
    acid = struct.unpack_from('<i', data, 0x78)[0]
    if data[0:4] != b'META' or data[aci:aci + 4] != b'ACI0':
        sys.exit(f'NPDM 模板不是 META/ACI0 结构：{path}')
    data[0x0C] = 3 << 1                       # 地址空间类型 64-bit（运行时读 (b>>1)&7）
    struct.pack_into('<Q', data, aci + 0x10, program_id)
    struct.pack_into('<Q', data, acid + 0x210, program_id)   # ACID.ProgramIdMin
    struct.pack_into('<Q', data, acid + 0x218, program_id)   # ACID.ProgramIdMax
    return bytes(data)


def reindex(root):
    paths = []
    for directory, _, names in os.walk(root):
        for name in names:
            full = os.path.join(directory, name)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            if rel in ('index.tsv', 'manifest.json', 'game-build-artifact.json', 'manifest.json.tmp'):
                continue
            paths.append(rel)
    paths.sort()
    lines, total = [], 0
    for rel in paths:
        data = open(os.path.join(root, rel), 'rb').read()
        total += len(data)
        lines.append(f'{rel}\t{len(data)}\t{hashlib.sha256(data).hexdigest()}\n')
    index = ''.join(lines).encode()
    with open(os.path.join(root, 'index.tsv'), 'wb') as f:
        f.write(index)
    sha = hashlib.sha256(index).hexdigest()
    manifest_path = os.path.join(root, 'manifest.json')
    manifest = json.load(open(manifest_path))
    manifest.update({'files': len(paths), 'total': total, 'index_sha256': sha})
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f, indent=1)
        f.write('\n')
    artifact_path = os.path.join(root, 'game-build-artifact.json')
    artifact = json.load(open(artifact_path))
    artifact['contentRoot'] = 'sha256-' + sha
    artifact['package'].update({'files': len(paths), 'bytes': total, 'indexSha256': sha})
    with open(artifact_path, 'w') as f:
        json.dump(artifact, f, indent=1)
        f.write('\n')
    return artifact['contentRoot']


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('pack')
    parser.add_argument('--program-id', help='缺省取 <pack>/ctl/control.nacp 里的程序号')
    args = parser.parse_args()
    if args.program_id:
        program_id = int(args.program_id, 16)
    else:
        nacp = open(os.path.join(args.pack, 'ctl/control.nacp'), 'rb').read()
        program_id = struct.unpack_from('<Q', nacp, 0x3038)[0]
    with open(os.path.join(args.pack, 'exefs/main.npdm'), 'wb') as f:
        f.write(build_npdm(program_id))
    print(f'npdm for {program_id:016X}（模板 Homebrew.npdm）-> {reindex(args.pack)}')


if __name__ == '__main__':
    main()

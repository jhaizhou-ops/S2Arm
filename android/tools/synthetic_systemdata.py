#!/usr/bin/env python3
"""给合成包补"可用的系统数据"（时区），口径与 services/S2A.Services/Host.cs 的 GenerateTimeZoneData 一致。

运行时要的是 <游戏目录>/systemdata/010000000000080E/binaryList.txt + zoneinfo/<区名>，
其中每个 zoneinfo 文件是宿主 IANA TZif 的**第二段**（Switch 用的格式，从 44+v1 开始）。

用法：synthetic_systemdata.py <pack 目录> [--zoneinfo /usr/share/zoneinfo]
只写系统数据（时区），不涉及任何游戏内容。
"""
import argparse
import os
import shutil
import struct
import sys

SYSDATA_ID = '010000000000080E'


def tzif_body(path):
    b = open(path, 'rb').read()
    if len(b) < 44 or b[:4] != b'TZif' or b[4] < ord('2'):
        return None
    def be(o):
        return struct.unpack_from('>i', b, o)[0]
    v1 = be(32) * 5 + be(36) * 6 + be(40) + be(28) * 8 + be(24) + be(20)
    if 44 + v1 + 4 > len(b) or b[44 + v1:44 + v1 + 1] != b'T':
        return None
    return b[44 + v1:]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('pack')
    parser.add_argument('--zoneinfo', default='/usr/share/zoneinfo')
    args = parser.parse_args()
    if not os.path.isdir(args.zoneinfo):
        sys.exit(f'no IANA database at {args.zoneinfo}')
    dst = os.path.join(args.pack, 'systemdata', SYSDATA_ID)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    names = []
    for root, _, files in os.walk(args.zoneinfo):
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, args.zoneinfo)
            if not rel[0].isupper() or rel.startswith('posix/') or rel.startswith('right/') or '.' in rel:
                continue
            body = tzif_body(full)
            if body is None:
                continue
            out = os.path.join(dst, 'zoneinfo', rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, 'wb') as f:
                f.write(body)
            names.append(rel)
    names.sort()
    os.makedirs(dst, exist_ok=True)
    with open(os.path.join(dst, 'binaryList.txt'), 'w') as f:
        f.write('\n'.join(names) + '\n')
    print(f'timezone system data: {len(names)} zones -> {dst}')


if __name__ == '__main__':
    main()

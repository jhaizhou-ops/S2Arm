#!/usr/bin/env python3
"""filecopy.copy_file：内容/权限一致；支持 CoW 的文件系统上写 dst 不会改到 src。
make_pack.write_pack：只读源（0444，RomFS 共享存储）也能出包，且索引哈希等于源内容。"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
from filecopy import copy_file


def main():
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, 'src.bin')
        data = bytes(range(256)) * 4096
        with open(src, 'wb') as f:
            f.write(data)
        os.chmod(src, 0o640)
        dst = os.path.join(tmp, 'sub', 'dst.bin')
        shared = copy_file(src, dst)
        assert open(dst, 'rb').read() == data, 'copy content differs'
        assert (os.stat(dst).st_mode & 0o777) == (os.stat(src).st_mode & 0o777), 'copy mode differs'
        with open(dst, 'r+b') as f:   # 写 dst 不得改到 src（CoW 或普通复制都必须成立）
            f.seek(0)
            f.write(b'\xff' * 16)
        assert open(src, 'rb').read() == data, 'writing dst changed src'
        print(f'filecopy: ok (cow={shared})')
    readonly_source_pack()


def readonly_source_pack():
    import hashlib
    import struct
    import make_pack
    with tempfile.TemporaryDirectory() as tmp:
        nacp_path = os.path.join(tmp, 'control.nacp')
        nacp = bytearray(0x4000)
        struct.pack_into('<Q', nacp, 0x3038, 0x0100000000010000)
        nacp[0x3060:0x3063] = b'0.1'
        with open(nacp_path, 'wb') as f:
            f.write(nacp)
        src = os.path.join(tmp, 'Manifest.txt')
        data = b'romfs shared store entry\n' * 1000
        with open(src, 'wb') as f:
            f.write(data)
        os.chmod(src, 0o444)
        out = os.path.join(tmp, 'pack')
        make_pack.write_pack(out, [('ctl/control.nacp', nacp_path), ('romfs/Manifest.txt', src)], False, None)
        dst = os.path.join(out, 'romfs', 'Manifest.txt')
        assert open(dst, 'rb').read() == data, 'pack content differs'
        index = open(os.path.join(out, 'index.tsv')).read()
        want = f"romfs/Manifest.txt\t{len(data)}\t{hashlib.sha256(data).hexdigest()}\n"
        assert want in index, f'index row missing: {want!r} not in {index!r}'
        print('make_pack read-only source: ok')


if __name__ == '__main__':
    main()

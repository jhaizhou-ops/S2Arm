#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Media.Vision 的 MDB1（.mvgl）归档（shader_split.py 用）：Cyber Sleuth（32 位、doboz）与 Time Stranger / THL（64 位、LZ4）。
布局（小端，Switch 上明文；SydMontague/MVGLTools 的 MDB1.h，BSD-3）：
  32 位头 0x14：'MDB1' u16 树项 u16 名项 u32 数据项 u32 数据区起 u32 总长；树项 8B {u16 比较位, u16 数据号, u16 左, u16 右}；
    名项 0x40B {char ext[4], char name[0x3C]}；数据项 12B {u32 偏移, u32 原长, u32 存储长}；doboz v0 压缩（mvgl.py 的 doboz 解）。
  64 位头 0x20：'MDB1' u32 树项 u32 名项 u32 数据项 u64 数据区起 u64 总长；树项 16B {u32 比较位, u32 数据号, u32 左, u32 右}；
    名项 128B {char ext[4], char name[0x7C]}；数据项 16B {u64 偏移, u32 原长, u32 存储长}；LZ4 块压缩。
  数据区偏移都相对数据区起；存储长 == 原长 = 原样存，存储长 < 原长 = 压缩。名字与树项按位置一一对应，名字经树项的数据号间接指到数据项。
用法: mdb1.Archive(路径).entries() → [(序号, '名字.ext' 或 None, bytes)]；文件不存在 / 不是 MDB1 抛 ValueError。
"""
import struct

MAGIC = b'MDB1'


class Archive:
    def __init__(self, open_file):
        """open_file = romfs_list.open_file 风格：seek / read。"""
        self.f = open_file
        hdr = self.f.read(0x20)
        if hdr[:4] != MAGIC: raise ValueError('not an MDB1 archive')
        u32_14 = struct.unpack_from('<I', hdr, 0x14)[0]
        if u32_14 == 0 and len(hdr) >= 0x20:
            # 64 位（Time Stranger / THL）
            self.bits = 64
            tree_n, name_n, data_n = struct.unpack_from('<3I', hdr, 4)
            self.data_start = struct.unpack_from('<Q', hdr, 0x10)[0]
            self.total = struct.unpack_from('<Q', hdr, 0x18)[0]
        else:
            # 32 位（Cyber Sleuth）
            self.bits = 32
            tree_n, name_n = struct.unpack_from('<2H', hdr, 4)
            data_n = struct.unpack_from('<I', hdr, 8)[0]
            self.data_start = struct.unpack_from('<I', hdr, 0x10)[0]
            self.total = struct.unpack_from('<I', hdr, 0x14)[0]
        self.tree_n, self.name_n, self.data_n = tree_n, name_n, data_n
        esz = 16 if self.bits == 64 else 12
        self.data_base = self.data_start - esz * data_n
        if self.data_base < 0: raise ValueError('MDB1 data table before file start')
        # 数据表基址核对：数据区起之前应该正好是数据项表；差得太远按算出的树 + 名字表大小推
        if self.bits == 64:
            want = 0x14 + tree_n * 16 + name_n * 128
        else:
            want = 0x14 + tree_n * 8 + name_n * 0x40
        if abs(self.data_base - want) > 0x10000:
            self.data_base = want
        # 名字表（与树项按位置对应）；读进内存（名项很小）
        noff = 0x14 + tree_n * (16 if self.bits == 64 else 8)
        nrec = 128 if self.bits == 64 else 0x40
        self.names = []
        self.f.seek(noff)
        raw = self.f.read(name_n * nrec)
        for k in range(name_n):
            e = raw[k * nrec:(k + 1) * nrec]
            nm = e[4:].split(b'\0')[0].decode('latin1', 'replace').strip()
            ex = e[:4].rstrip(b'\0 ').decode('latin1', 'replace').strip()
            self.names.append((nm + '.' + ex if ex and nm else nm + ex) if (nm or ex) else None)

    def name_of(self, k):
        """树项 k 的文件名（无名字 / 数据号越界给 None）"""
        if k >= len(self.names): return None
        return self.names[k] or None

    def data_ids(self):
        """树项数据号（按树项序，越界的给 None）"""
        esz = 16 if self.bits == 64 else 8
        self.f.seek(0x14)
        raw = self.f.read(self.tree_n * esz)
        ids = []
        for k in range(self.tree_n):
            did = struct.unpack_from('<I' if esz == 16 else '<H', raw, k * esz + (4 if esz == 16 else 2))[0]
            ids.append(None if did >= self.data_n and did != (1 << 32) - 1 and did != 0xffff else did)
        return ids

    def read_data(self, k):
        """第 k 个数据项的内容（解压后）"""
        esz = 16 if self.bits == 64 else 12
        self.f.seek(self.data_base + esz * k)
        rec = self.f.read(esz)
        if self.bits == 64:
            off = struct.unpack_from('<Q', rec, 0)[0]   # 偏移是 u64：app_0 这类 4GB+ 的大归档里 u32 读会把 4GB 之后的条目全读错
            ln, cn = struct.unpack_from('<2I', rec, 8)
        else:
            off, ln, cn = struct.unpack_from('<3I', rec, 0)
        if ln == 0 and cn == 0: return b''
        self.f.seek(self.data_start + off)
        blob = self.f.read(cn if cn < ln else ln)
        if cn < ln:
            import lz4.block
            blob = lz4.block.decompress(blob, uncompressed_size=ln)
        return blob

    def entries(self):
        """[(序号, 名字或 None, 内容 bytes)]——跳过空项；名字按树项数据号对应"""
        ids = self.data_ids()
        seen = set()
        for k, did in enumerate(ids):
            if did is None or did in seen: continue
            seen.add(did)
            nm = self.name_of(k)
            try: blob = self.read_data(did)
            except Exception: blob = b''
            yield (did, nm, blob)
        # 没被任何树项指到的数据项也扫（名字给 None）
        for k in range(self.data_n):
            if k not in seen:
                try: blob = self.read_data(k)
                except Exception: blob = b''
                yield (k, None, blob)


if __name__ == '__main__':
    import sys, os
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'graphics', 'nvn', 'tools'))
    import romfs_list
    a = Archive(romfs_list.open_file(sys.argv[1]))
    n = 0
    for k, nm, blob in a.entries():
        n += 1
        if n <= 5: print(k, nm, len(blob))
    print('entries:', n, 'total bytes:', a.total)

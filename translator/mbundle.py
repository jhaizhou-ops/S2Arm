#!/usr/bin/env python3
# Digital Eclipse 的 .mbundle 包（Street Fighter 30th Anniversary Collection，RomFS Bundle/*.mbundle，18 个；Bundle/Manifest.plist 同一格式）：
#   一份二进制属性表（'bplist00'，Apple 二进制 plist 的对象编码：0x5n ASCII 串、0x4n 数据、0xDn 字典……，引用按偏移表查），
#   顶层是字典「文件名 → 数据对象」，文件内容就是那个数据对象的字节。与标准格式只差一处：尾部的顶层对象字段是去掉 8 字节文件头后的字节偏移，不是对象编号
#   （Python 自带 plistlib 因此拒收）；尾部只有 26 字节（标准格式前 6 个空字节没有，偏移表紧接其前）：偏移宽、引用宽、u64 对象数、u64 顶层偏移、u64 偏移表位置，大端。
# 只读索引与用到的条目（mmap，最大的包近 1 GB）。用法：mbundle.py list <包> [扩展名]   |   mbundle.py get <包> <文件名> <输出文件>
import mmap, struct, sys


class Bundle:
    def __init__(self, path):
        self.path = path
        with open(path, 'rb') as f:
            self.m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        d = self.m
        if len(d) < 40 or d[:8] != b'bplist00':
            raise ValueError(f'{path}：不是 mbundle（开头不是 bplist00）')
        t = d[-26:]; self.osz, self.rsz = t[0], t[1]; n, top, oto = struct.unpack('>QQQ', t[2:])
        if self.osz not in (1, 2, 4, 8) or self.rsz not in (1, 2, 4, 8) or oto + n * self.osz != len(d) - 26 or top + 8 >= oto:
            raise ValueError(f'{path}：尾部不合 mbundle 布局（偏移宽 {self.osz}、引用宽 {self.rsz}、对象 {n}、顶层 {top}、偏移表 {oto}）')
        self.n, self.oto = n, oto
        top_obj = self._obj(top + 8)
        if not isinstance(top_obj, dict):
            raise ValueError(f'{path}：顶层不是字典')
        self.files = {}
        for k, v in top_obj.items():
            if not isinstance(k, str) or not (isinstance(v, tuple) and v[0] == 'data'):
                raise ValueError(f'{path}：顶层条目 {k!r} 不是「文件名 → 数据」')
            self.files[k] = (v[1], v[2])

    def _off(self, i):
        if i >= self.n: raise ValueError(f'{self.path}：引用 {i} 超出对象数 {self.n}')
        p = self.oto + i * self.osz
        return int.from_bytes(self.m[p:p + self.osz], 'big')

    def _len(self, lo, p):
        if lo != 15: return lo, p
        mm = self.m[p]; k = 1 << (mm & 15)
        return int.from_bytes(self.m[p + 1:p + 1 + k], 'big'), p + 1 + k

    def _obj(self, p, depth=0):
        if depth > 2: raise ValueError(f'{self.path}：对象嵌套过深 @ {p}')
        d = self.m; m = d[p]; hi, lo = m >> 4, m & 15; p += 1
        if hi == 4: n, p = self._len(lo, p); return ('data', p, n)
        if hi == 5: n, p = self._len(lo, p); return bytes(d[p:p + n]).decode('latin1')
        if hi == 6: n, p = self._len(lo, p); return bytes(d[p:p + 2 * n]).decode('utf-16-be')
        if hi == 0xD:
            n, p = self._len(lo, p); r = self.rsz
            ks = [int.from_bytes(d[p + i * r:p + (i + 1) * r], 'big') for i in range(n)]
            vs = [int.from_bytes(d[p + (n + i) * r:p + (n + i + 1) * r], 'big') for i in range(n)]
            return {self._obj(self._off(k), depth + 1): self._obj(self._off(v), depth + 1) for k, v in zip(ks, vs)}
        raise ValueError(f'{self.path}：不认识的对象标记 {m:#x} @ {p - 1}')

    def read(self, name):
        off, n = self.files[name]
        return bytes(self.m[off:off + n])


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == 'list':
        b = Bundle(sys.argv[2])
        for nm, (off, n) in sorted(b.files.items()):
            if len(sys.argv) < 4 or nm.endswith('.' + sys.argv[3]): print(f'{n}\t{nm}')
    elif len(sys.argv) == 5 and sys.argv[1] == 'get':
        open(sys.argv[4], 'wb').write(Bundle(sys.argv[2]).read(sys.argv[3]))
    else:
        sys.exit('用法：mbundle.py list <包> [扩展名] | mbundle.py get <包> <文件名> <输出文件>')

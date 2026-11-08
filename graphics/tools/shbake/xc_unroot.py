#!/usr/bin/env python3
# 着色器阶段键用（xc_key.sh）：python3 xc_unroot.py <目标文件.o>…
# 把 Mach-O 目标文件里 ObjC 类 / 分类 / 协议表段改名、清掉「不许死代码剥离」位：链接器不再把每个 ObjC 类都当根，
# 死代码剥离后只剩从 main 真正调到的代码（类本身若被活代码引用照留）。改过的目标文件只用来算键，不运行。
import struct, sys
NAMES = {b'__objc_classlist', b'__objc_nlclslist', b'__objc_catlist', b'__objc_nlcatlist', b'__objc_protolist'}
for p in sys.argv[1:]:
    b = bytearray(open(p, 'rb').read())
    if struct.unpack_from('<I', b, 0)[0] != 0xfeedfacf: sys.exit(f'【红】{p} 不是 64 位 Mach-O 目标文件')
    off = 32
    for _ in range(struct.unpack_from('<I', b, 16)[0]):
        cmd, sz = struct.unpack_from('<II', b, off)
        if cmd == 0x19:   # LC_SEGMENT_64：段头 72 字节，其后每节 80 字节（sectname 16、segname 16 … flags 在节内偏移 64）
            for i in range(struct.unpack_from('<I', b, off + 64)[0]):
                s = off + 72 + 80 * i
                if bytes(b[s:s + 16]).rstrip(b'\0') in NAMES:
                    b[s:s + 16] = (b'__xk' + bytes(b[s + 6:s + 16]).rstrip(b'\0')).ljust(16, b'\0')[:16]
                    struct.pack_into('<I', b, s + 64, struct.unpack_from('<I', b, s + 64)[0] & ~0x100000ff)   # 清 S_ATTR_NO_DEAD_STRIP 与节类型（按普通数据节）
        off += sz
    open(p, 'wb').write(b)

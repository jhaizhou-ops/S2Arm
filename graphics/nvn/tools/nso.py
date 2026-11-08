import sys,struct
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
from lz4blk import lz4_block
d=_nso_plain(open(sys.argv[1],'rb').read(),sys.argv[1])
flags=struct.unpack_from('<I',d,0xc)[0]
segs=[struct.unpack_from('<III',d,0x10+i*0x10) for i in range(3)]
bss=struct.unpack_from('<I',d,0x3c)[0]
csz=struct.unpack_from('<III',d,0x60)
end=segs[2][1]+segs[2][2]
img=bytearray(end+bss)
for i,(fo,mo,sz) in enumerate(segs):
    raw=d[fo:fo+csz[i]]
    if flags>>i&1: raw=lz4_block(raw,sz)
    img[mo:mo+sz]=raw
open(sys.argv[2],'wb').write(img)
print([hex(x) for s in segs for x in s],hex(bss),'moduleid',d[0x40:0x60].hex())

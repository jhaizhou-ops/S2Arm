#!/usr/bin/env python3
# APFS 真实独占占用（删掉这个文件真正能腾出的字节，不含与克隆共享的块）：getattrlist ATTR_CMNEXT_PRIVATESIZE。
#   10-23 画面·着色器线：gc 原按 st_blocks 记账，gal_pso_cache 3.5 GB 的独占是 0（全和产物根共享），删了记成腾出 GB、提前收手。
#   用法：privsize.py <路径…>（每个路径一行：独占字节、du 字节、文件数）；privsize.py --selftest（正对照：新文件独占 = 大小，克隆后两边都 ≈ 0）
#   被 gc.sh 内的 Python 段 import：private_size(path) → 字节或 None（读不出）
import ctypes, ctypes.util, os, struct, subprocess, sys
_libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
class _AttrList(ctypes.Structure):
    _fields_ = [('bitmapcount', ctypes.c_ushort), ('reserved', ctypes.c_uint16), ('commonattr', ctypes.c_uint32), ('volattr', ctypes.c_uint32),
                ('dirattr', ctypes.c_uint32), ('fileattr', ctypes.c_uint32), ('forkattr', ctypes.c_uint32)]
_RETURNED, _PRIVSIZE, _EXT, _NOFOLLOW = 0x80000000, 0x00000008, 0x00000020, 0x00000001
_buf = ctypes.create_string_buffer(64)

def private_size(path):
    al = _AttrList(5, 0, _RETURNED, 0, 0, 0, _PRIVSIZE)
    if _libc.getattrlist(os.fsencode(path), ctypes.byref(al), _buf, 64, _EXT | _NOFOLLOW) != 0: return None
    return struct.unpack_from('<q', _buf.raw, 4 + 20)[0]   # u32 长度 + attribute_set_t（5 × u32）+ off_t

def tree(d):
    priv = du = n = 0
    for root, _, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            try: st = os.lstat(p)
            except OSError: continue
            if not os.path.isfile(p) or os.path.islink(p): continue
            n += 1; du += st.st_blocks * 512; priv += private_size(p) or 0
    return priv, du, n

if __name__ == '__main__':
    if sys.argv[1:2] == ['--selftest']:
        d = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.environ.get('TMPDIR', '/tmp'), f'privsize_{os.getpid()}')
        subprocess.run(['rm', '-rf', d]); os.makedirs(d); a, b = os.path.join(d, 'a.bin'), os.path.join(d, 'b.bin')
        with open(a, 'wb') as f: f.write(os.urandom(20 << 20))
        r1 = private_size(a); subprocess.run(['cp', '-c', a, b], check=True); r2, r3 = private_size(a), private_size(b)
        subprocess.run(['rm', '-rf', d])
        print(f'新文件 20 MB 独占 {r1 >> 20} MB；克隆后 a {r2 >> 20} MB、b {r3 >> 20} MB')
        sys.exit(0 if r1 >> 20 >= 19 and r2 >> 20 <= 1 and r3 >> 20 <= 1 else 1)
    for d in sys.argv[1:]:
        p, u, n = tree(d) if os.path.isdir(d) else ((private_size(d) or 0), os.lstat(d).st_blocks * 512, 1)
        print(f'{d}\t{p}\t{u}\t{n}')

#!/usr/bin/env python3
"""一键出包 ⑤ 交付资源包：deliver_pack.py <产物根 pkg/pack> <输出/<款>资源包>

资源包目录 = index.tsv 列的文件 + index.tsv + manifest.json（pack/pack.py 产物；清单最后写，有清单 = 包完整）。
原先交付整份 rm -rf 再 cp -cR：时之笛 18.7 万个文件、每次出包两遍逐文件操作（删 + 克隆）约 4 分钟，而两版之间实际只差几十个文件。
现在按两份 index.tsv 比：路径 / 字节数 / SHA-256 都相同且目标里大小对得上的文件不动，其余克隆（APFS clonefile，同 pack.py），
新版没有的删掉；先删目标清单、最后写清单，中途失败留下的是「没有清单 = 不完整」的目录，下次照样按索引补齐。
目标没有 index.tsv 或 manifest.json（第一次交付 / 上次中途失败前的旧格式）→ 整份重做。
输出一行：<文件数>\t<总字节>\t<克隆数>\t<删除数>\t<模式>
"""
import ctypes, os, shutil, sys
# 不 import pack/pack.py：一键出包在启动器作业 / 用户机布局里只带 pack/oneclick 这几样（tests/userenv_test.sh ③），交付不该多依赖出包模块
if sys.platform == 'darwin':
    libc = ctypes.CDLL('libc.dylib', use_errno=True); libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]


def clone(src, dst):   # macOS APFS 克隆（不占新空间）；跨卷 / 不支持 / 别的系统退回普通拷贝（同原先 cp -cR 失败退 cp -R）
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.lexists(dst): os.remove(dst)
    if sys.platform == 'darwin' and libc.clonefile(os.fsencode(src), os.fsencode(dst), 0) == 0: return
    if sys.platform == 'darwin' and ctypes.get_errno() not in (18, 45, 1):
        e = ctypes.get_errno(); raise OSError(e, os.strerror(e), dst)
    shutil.copy2(src, dst)


def read_index(d):
    out = {}
    with open(os.path.join(d, 'index.tsv'), encoding='utf-8') as f:
        for line in f:
            p, size, sha = line.rstrip('\n').split('\t')
            out[p] = (int(size), sha)
    return out


def main():
    src, dst = sys.argv[1], sys.argv[2]
    new = read_index(src)
    if not os.path.isfile(os.path.join(src, 'manifest.json')): sys.exit(f'【红】{src} 没有 manifest.json（资源包不完整）')
    full = not (os.path.isfile(os.path.join(dst, 'index.tsv')) and os.path.isfile(os.path.join(dst, 'manifest.json')))
    if full:
        if os.path.lexists(dst): shutil.rmtree(dst)
        old = {}
    else:
        old = read_index(dst)
        os.remove(os.path.join(dst, 'manifest.json'))   # 更新期间目录标成不完整
    removed = 0
    for p in old.keys() - new.keys():
        q = os.path.join(dst, p)
        if os.path.lexists(q): os.remove(q); removed += 1
    cloned = 0
    for p, (size, sha) in new.items():
        q = os.path.join(dst, p)
        if old.get(p) == (size, sha):
            try:
                if os.stat(q).st_size == size: continue
            except FileNotFoundError: pass
        clone(os.path.join(src, p), q); cloned += 1
    for p in {os.path.dirname(p) for p in old.keys() - new.keys()}:   # 删空了的目录（自下而上）
        while p:
            try: os.rmdir(os.path.join(dst, p))
            except OSError: break
            p = os.path.dirname(p)
    clone(os.path.join(src, 'index.tsv'), os.path.join(dst, 'index.tsv'))
    clone(os.path.join(src, 'manifest.json'), os.path.join(dst, 'manifest.json'))   # 清单最后写
    print(f'{len(new)}\t{sum(s for s, _ in new.values())}\t{cloned}\t{removed}\t{"整份" if full else "增量"}')


if __name__ == '__main__':
    main()

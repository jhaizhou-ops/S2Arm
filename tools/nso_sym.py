#!/usr/bin/env python3
"""nso_sym.py：把游戏模块（NSO0）里的偏移换成导出函数名，排查崩溃 / 游戏 Break 调用链用。

  python3 tools/nso_sym.py sym <nso> <偏移…>          每个偏移落在哪个导出函数里（或最近的前一个）
  python3 tools/nso_sym.py plt <nso> <跳板地址…>      PLT 跳板（adrp/ldr/br x17）实际跳到哪个导入函数
  python3 tools/nso_sym.py dis <nso> <起> <止>        反汇编一段，bl 目标换成导出名
  python3 tools/nso_sym.py find <nso> <子串…>         列出名字含这些子串的导出函数

偏移都是模块内偏移（host.log 帧栈里「sdk+0x135608」的 0x135608）。NSO 文件取解包产物 exefs/<模块名>。
名字是 C++ 改编名，管道接 c++filt 还原。依赖 lz4、capstone（tools/rewriter-requirements.txt 同一份）。
"""
import struct
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '.')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
import sys


def load(path):
    """解三段（可选 LZ4）铺成内存映像，返回 bytes。"""
    raw = open(path, 'rb').read()
    if raw[:4] != b'NSO0':
        sys.exit(f'{path} 不是 NSO0')
    raw = _nso_plain(raw, path)
    flags = struct.unpack_from('<I', raw, 12)[0]
    img = bytearray()
    for k in range(3):
        off, addr, size = struct.unpack_from('<III', raw, 0x10 + 16 * k)
        stored = struct.unpack_from('<I', raw, 0x60 + 4 * k)[0]
        seg = raw[off:off + stored]
        if flags & (1 << k):
            import lz4.block
            seg = lz4.block.decompress(seg, uncompressed_size=size)
        if len(img) < addr:
            img += b'\0' * (addr - len(img))
        img[addr:addr + size] = seg
    return bytes(img)


def dynamic(img):
    """MOD0 → .dynamic，返回 {标签: 值}（同标签取第一个）。"""
    mod0 = struct.unpack_from('<I', img, 4)[0]
    if img[mod0:mod0 + 4] != b'MOD0':
        sys.exit('没有 MOD0 头')
    at = mod0 + struct.unpack_from('<i', img, mod0 + 4)[0]
    tags = {}
    while at + 16 <= len(img):
        tag, val = struct.unpack_from('<qQ', img, at)
        at += 16
        if tag == 0:
            break
        tags.setdefault(tag, val)
    return tags


def name_at(img, strtab, off):
    end = img.index(b'\0', strtab + off)
    return img[strtab + off:end].decode('ascii', 'replace')


def functions(img):
    """导出函数表 [(地址, 长度, 名)]，按地址排序。符号个数取 DT_HASH 的 nchain。"""
    d = dynamic(img)
    symtab, strtab = d[6], d[5]
    count = struct.unpack_from('<I', img, d[4] + 4)[0] if 4 in d else (strtab - symtab) // 24
    out = []
    for k in range(count):
        name, info, _, _, value, size = struct.unpack_from('<IBBHQQ', img, symtab + 24 * k)
        if value and (info & 0xF) == 2:
            out.append((value, size, name_at(img, strtab, name)))
    return sorted(out)


def plt_slots(img):
    """DT_JMPREL：GOT 槽地址 → 导入符号名。"""
    d = dynamic(img)
    symtab, strtab = d[6], d[5]
    slots = {}
    for k in range(d.get(2, 0) // 24):
        off, info, _ = struct.unpack_from('<QQq', img, d[23] + 24 * k)
        slots[off] = name_at(img, strtab, struct.unpack_from('<I', img, symtab + 24 * (info >> 32))[0])
    return slots


def disassembler():
    import capstone
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    md.detail = True
    return md


def cmd_sym(img, args):
    fns = functions(img)
    for a in args:
        x = int(a, 16)
        best = None
        for v, sz, nm in fns:
            if v > x:
                break
            best = (v, sz, nm)
        if not best:
            print(f'{x:#x}\t（在第一个导出函数之前）')
            continue
        v, sz, nm = best
        where = '内' if x < v + sz else f'外：函数长 {sz:#x}，可能是紧跟其后的未导出函数或返回地址越过了末尾'
        print(f'{x:#x}\t{nm}+{x - v:#x}\t{where}')


def cmd_plt(img, args):
    slots, md = plt_slots(img), disassembler()
    for a in args:
        x = int(a, 16)
        ins = list(md.disasm(img[x:x + 8], x))
        if len(ins) < 2 or ins[0].mnemonic != 'adrp' or ins[1].mnemonic != 'ldr':
            print(f'{x:#x}\t不是 PLT 跳板（adrp + ldr）')
            continue
        got = ins[0].operands[1].imm + ins[1].operands[1].mem.disp
        print(f'{x:#x}\tGOT {got:#x}\t{slots.get(got, "?")}')


def cmd_dis(img, args):
    names = {v: nm for v, _, nm in functions(img)}
    a, b = int(args[0], 16), int(args[1], 16)
    for ins in disassembler().disasm(img[a:b], a):
        note = ''
        if ins.mnemonic in ('bl', 'b') and ins.op_str.startswith('#'):
            note = '  ; ' + names.get(int(ins.op_str[1:], 16), '?')
        print(f'{ins.address:#x}: {ins.mnemonic} {ins.op_str}{note}')


def cmd_find(img, args):
    for v, sz, nm in functions(img):
        if all(s in nm for s in args):
            print(f'{v:#x}\t{sz:#x}\t{nm}')


def main():
    cmds = {'sym': cmd_sym, 'plt': cmd_plt, 'dis': cmd_dis, 'find': cmd_find}
    if len(sys.argv) < 4 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]](load(sys.argv[2]), sys.argv[3:])


if __name__ == '__main__':
    main()

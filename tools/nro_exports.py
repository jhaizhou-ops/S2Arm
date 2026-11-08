#!/usr/bin/env python3
# romfs 里 NRO 的导出符号表（10-25 总指挥批，装载器口径）：游戏自带的 NRO（romfs/nro/*.nro，登记在 romfs/.nrr/*.nrr）要等游戏用 nn::ro 装进来时，
#   rtld 才拿它们的导出解析别的模块的导入（Horizon 语义）。起局时这些导入在已装模块里找不到定义是正常的，装载器（runtime/src/loader.c）
#   查这张表，命中的记「延迟到 nn::ro 装载」普通日志、不计红；运行时真被调到照旧报红中止（桩不变）。
# 出包改写阶段（pack/stage_rewrite.sh）调用，产物写进产物根 nro_exports.tsv（与 main.npdm 同目录，随包进 App）。零配置、各款通用：romfs 里没有 *.nro 就不出表。
# NRO 格式（switchbrew NRO）：+0x4 = MOD0 偏移（相对文件头）、+0x10 = 'NRO0'；映像未压缩、按文件偏移即模块内偏移。
#   MOD0 +0x4 = 动态段偏移（相对 MOD0）；DT_SYMTAB / DT_STRTAB 给符号表 / 串表，符号表到串表之间是全部 Elf64_Sym（24 字节）。导出 = 有定义（st_shndx ≠ 0）且全局 / 弱（绑定 1 / 2）
# 用法：tools/nro_exports.py <romfs 目录> <输出 tsv>；退出码 0（没有 NRO 不出表也是 0），读坏 NRO 报红退出 1
import os, struct, sys
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py，walk 同 os.walk）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'gfx', 'nvn', 'tools')); import romfs_list

def exports(path):
    d = open(path, 'rb').read()
    if d[0x10:0x14] != b'NRO0': raise ValueError('不是 NRO（缺 NRO0 标记）')
    m0 = struct.unpack_from('<I', d, 4)[0]
    if d[m0:m0 + 4] != b'MOD0': raise ValueError(f'MOD0 偏移 {m0:#x} 处没有 MOD0')
    dyn = m0 + struct.unpack_from('<i', d, m0 + 4)[0]; tags = {}
    for o in range(dyn, len(d) - 16, 16):
        t, v = struct.unpack_from('<QQ', d, o)
        if t == 0: break
        tags.setdefault(t, v)
    st, sy = tags.get(5), tags.get(6)
    if st is None or sy is None or not sy < st: raise ValueError('动态段里没有可用的 DT_SYMTAB / DT_STRTAB')
    out = []
    for o in range(sy, st, 24):
        nm, info, _, shn, _, _ = struct.unpack_from('<IBBHQQ', d, o)
        if not shn or (info >> 4) not in (1, 2): continue
        e = d.index(b'\0', st + nm); name = d[st + nm:e].decode('utf-8', 'replace')
        if name: out.append(name)
    return out

def main(argv):
    if len(argv) != 2: print('用法：nro_exports.py <romfs 目录> <输出 tsv>', file=sys.stderr); return 2
    # romfs 任意深度的 *.nro（10-29：魔界战记6 的 lz4.nro 在 romfs 根、大航海4 在 NRO/ 与 .nro/，原先只看 romfs/nro/ 漏表；与 runtime/rewriter/nro_to_nso.py 同口径）
    nd = argv[0]
    files = sorted(os.path.relpath(os.path.join(dp, f), nd) for dp, _, fn in romfs_list.walk(nd) for f in fn if f.lower().endswith('.nro')) if os.path.isdir(nd) else []
    if not files: print('romfs 里没有 *.nro，不出表'); return 0
    rows = []
    for f in files:
        try: ex = exports(os.path.join(nd, f))
        except (ValueError, struct.error) as e: print(f'【红】{f}：{e}', file=sys.stderr); return 1
        rows += [(n, f) for n in ex]; print(f'{f}：导出 {len(ex)} 个')
    with open(argv[1], 'w', encoding='utf-8') as o:
        o.write('# nro_exports.tsv：tools/nro_exports.py 出；romfs/nro 下各 NRO 的导出符号（符号<TAB>NRO 文件名），装载器把命中的未解析导入记成「延迟到 nn::ro 装载」\n')
        for n, f in rows: o.write(f'{n}\t{f}\n')
    return 0

if __name__ == '__main__': sys.exit(main(sys.argv[1:]))

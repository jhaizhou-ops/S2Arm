#!/usr/bin/env python3
"""片元输出类型变体请求表（现编回收 R2，docs/研究/现编回收方案.md）：fout_want.py <输出 fout_want.tsv> <来源 pso_user.tsv / 目录…>
原 fout_want.m 的 Python 版（#1100 W6，11-04 Windows 出包线：原先要现编 Objective-C，Windows 没有），判断、排序与输出逐字节同原版；
管线键布局读 pso_layout.json（pso_layout.py），与运行时 nvn_pso_skey.h / nvn_pfkind.h 同一份定义（tests/pso_layout_test.sh 核）。
  写整数画布的片元着色器要逐位置定类型的入口 main0_t<u>_<s>（nvn_mtl.m pso_int_need → fs_typed_fn）。出库前从真跑留下的管线键（R 行）算出每个片元键在
  各输出位置的整数画布种类，dmsh_build ft_finish 再按反射里真写的颜色输出过滤（同 pso_int_need），把变体编进库。
  R 行：画布格式 cfmt[i] 非 0 的位置 i，映射到片元输出 l（合并渲染遍 merged 时 l = lmap[i]，否则 l = i；0xff / >7 不算），pf_int_kind 是 1 记进无符号掩码位、2 记进有符号掩码位；
  画布 0 用第二源混合因子（pso_dual_source）的行另记有符号掩码位 8（PSO_FOUT_DUAL >> 8）。可读瓦片变体的行（fz）不出。
  另收 rt_collect.py 的 rt_fout.tsv 行（键<TAB>无符号<TAB>有符号，十六进制）。
  输出：表头 + 「16 位键<TAB>无符号掩码<TAB>有符号掩码」（十六进制），去重、排序；掩码是过滤前的原始值。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pso_layout  # noqa: E402

PSO_FOUT_DUAL = 1 << 16
HEX16 = re.compile(rb'[0-9a-f]{16}')
HEXNUM = re.compile(rb'(0[xX])?[0-9a-fA-F]+')   # = strtoul(…, 16) 整串都吃掉（rt_collect.py 写的是不带前缀的小写十六进制）


def scan(path, wants, cnt):
    try: data = open(path, 'rb').read()
    except OSError: return
    for line in data.split(b'\n'):
        line = line.rstrip(b'\r\n')
        if not line or line.startswith(b'#'): continue
        parts = line.split(b'\t', 2)
        if len(parts) < 2: continue
        c0, c1, c2 = parts[0], parts[1], (parts[2] if len(parts) > 2 else None)
        if c0 == b'R' and len(c1) == 2 * pso_layout.load()['skey_size']:
            cnt[0] += 1
            sk = pso_layout.parse(c1.decode('latin-1'))
            if sk is None or sk.fz or not sk.fs or len(sk.fs) < 16 or not HEX16.fullmatch(sk.fs[:16]): continue
            u = s = 0
            for i in range(8):
                if not sk.cfmt[i]: continue
                l = sk.lmap[i] if sk.merged else i
                if l == 0xff or l > 7: continue
                kind = pso_layout.int_kind(sk.cfmt[i])
                if kind == 1: u |= 1 << l
                elif kind == 2: s |= 1 << l
            if sk.dual_source(): s |= PSO_FOUT_DUAL >> 8
            n0 = len(wants); add(wants, sk.fs[:16].decode(), u, s); cnt[1] += len(wants) > n0
        elif len(c0) == 16 and HEX16.fullmatch(c0) and c2 is not None and b'\t' not in c2:   # rt_fout.tsv：键、无符号掩码、有符号掩码
            if not HEXNUM.fullmatch(c1) or not HEXNUM.fullmatch(c2): continue
            u, s = int(c1, 16), int(c2, 16)
            if u > 0xff or s > (0xff | PSO_FOUT_DUAL >> 8): continue
            cnt[0] += 1; n0 = len(wants); add(wants, c0.decode(), u, s); cnt[1] += len(wants) > n0


def add(wants, key, u, s):
    if u | s and (key, u, s) not in wants: wants[(key, u, s)] = None   # 有序去重（同原版线性查重）


def main(argv):
    if len(argv) < 1:
        print('用法：fout_want.py <输出 fout_want.tsv> [来源 pso_user.tsv / 目录…]', file=sys.stderr); return 2
    wants, cnt, files = {}, [0, 0], 0
    for p in argv[1:]:
        if os.path.isdir(p):
            for n in sorted(os.listdir(p)):   # 原版 NSString compare:：来源目录里是程序号 / 英文文件名，按字节序同
                if n.endswith('.tsv'): scan(os.path.join(p, n), wants, cnt); files += 1
        elif os.path.exists(p): scan(p, wants, cnt); files += 1
    rows = sorted(wants, key=lambda w: (w[0].encode(), w[1], w[2]))
    try:
        with open(argv[0], 'w', encoding='utf-8', newline='\n') as o:
            o.write('# fragment key\tunsigned mask\tsigned mask (hex; raw, before the shader\'s colour filter; graphics/tools/direct/fout_want.py)\n')
            for k, u, s in rows: o.write(f'{k}\t{u:x}\t{s:x}\n')
    except OSError:
        print(f'【红】写不了 {argv[0]}', file=sys.stderr); return 1
    print(f'[直连库] 输出类型变体请求：{files} 个来源文件、{cnt[0]} 行管线键 / 变体记录，{len(rows)} 条请求（{cnt[1]} 条新增）')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

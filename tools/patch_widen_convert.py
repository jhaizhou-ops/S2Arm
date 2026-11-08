#!/usr/bin/env python3
"""社区画幅补丁 → 补丁包自适应启用行（补丁包 v1 设计稿 12.8：只取位置与语义，不取社区写死的目标比例）。

用法：tools/patch_widen_convert.py <产物根> <社区补丁库> [--out <补丁根>] [--min-support N]
  产物根 = 出包改写阶段的根（main.npdm / main.fixups.tsv 的 # BUILD_ID / main.widen.tsv 候选表 / main.patched.bin）；
  社区补丁库 = 含 补丁清单.tsv 的目录（列：程序号 构建号 构建号全长 类型 来源URL 提交号 许可 文件相对路径）。
做法：清单里本款、类型含 widen、构建号对得上的 pchtxt / IPS，逐个 4 字节写入对到候选点：
  落在候选点上 → [widen.enable.handheld] / [widen.enable.docked] 各一行（模块 偏移 种类 1 orig=<候选原字> sig=<前 8 字节>|<后 8 字节>）；
  落在 asp 候选点后 4 字节（配对 MOVK）→ 算进那个 asp 点；其余 → 不在候选（交满屏线并进候选超集，不按偏移硬套社区值）。
  同款多份不同比例的补丁位置合成一份。特征按宿主比法取（runtime/src/widen.c sig_ok）：候选代码点取候选原字、asp 后 4 字节写 ??。
输出：stdout 是补丁段；--out 时写 <补丁根>/<程序号>/patch.tsv（已有就不覆盖，改写 patch.widen.tsv）与 转换报告.tsv。只看 main 模块。
"""
import os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'pack'))
import cpatch  # noqa: E402  社区补丁解析（pchtxt / IPS 语义与出包同一份）

CODE_KINDS = {'movz', 'asp', 'aspdiv', 'aspstr', 'f2w', 'lytsz', 'capsz', 'aspcap', 'aspcaps', 'seadasp'}   # 改写器换掉的种类（f32 / aspf / i32 是数据点）


def build_id(root):
    for line in open(os.path.join(root, 'main.fixups.tsv'), encoding='utf-8', errors='replace'):
        if line.startswith('# BUILD_ID\t'): return line.split('\t', 1)[1].strip().lower()
    return ''


def cands(root):
    out = {}
    for line in open(os.path.join(root, 'main.widen.tsv')):
        f = line.split('\t')
        if len(f) >= 4: out[int(f[1], 16)] = (f[2], int(f[3], 16))
    return out


def sig(img, cs, off, n=8):
    def byte(p):
        for o, (k, w) in cs.items():
            if k in CODE_KINDS and o <= p < o + 4: return '%02x' % ((w >> (8 * (p - o))) & 0xff)
            if k == 'asp' and o + 4 <= p < o + 8: return '??'
        return '%02x' % img[p] if 0 <= p < len(img) else None
    pre = [byte(p) for p in range(off - n, off)]; post = [byte(p) for p in range(off + 4, off + 4 + n)]
    if None in pre or None in post: return ''
    return ''.join(pre) + '|' + ''.join(post)


def main(argv):
    if len(argv) < 2: print(__doc__); return 2
    root, lib = argv[0], argv[1]; out = argv[argv.index('--out') + 1] if '--out' in argv else ''
    pid = cpatch.program_id(os.path.join(root, 'main.npdm')); bid = build_id(root)
    full = cpatch.module_bid(os.path.join(root, 'exefs', 'main'))   # NSO 头里的全长构建号（补丁写的常是 20 字节，fixups 表头只记 16 字节）
    cs = cands(root); img = open(os.path.join(root, 'main.patched.bin'), 'rb').read()
    hit, report, sup = {}, [], {}   # sup：位置 → 支持它的补丁文件集合
    for row in open(os.path.join(lib, '补丁清单.tsv'), encoding='utf-8'):
        f = row.rstrip('\n').split('\t')
        if len(f) < 8 or f[0] != pid or 'widen' not in f[3].split(','): continue
        path = os.path.join(lib, f[7])
        if not cpatch.bid_match(full, f[1]): report.append((f[7], '构建号不对', f[1], '', '')); continue
        if path.endswith('.pchtxt'): writes = [w for s in cpatch.parse_pchtxt(open(path, encoding='utf-8', errors='replace').read())[1] if s['enabled'] and not s['bad'] for w in s['writes']]
        else: writes = cpatch.parse_ips(open(path, 'rb').read()) or []
        for off, data in writes:
            for k in range(0, len(data), 4):
                o = off + k
                if o in cs: hit[o] = cs[o]; sup.setdefault(o, set()).add(f[7]); report.append((f[7], '落候选', '%#x' % o, cs[o][0], ''))
                elif o - 4 in cs and cs[o - 4][0] == 'asp': hit[o - 4] = cs[o - 4]; sup.setdefault(o - 4, set()).add(f[7]); report.append((f[7], '落候选（asp 配对 MOVK）', '%#x' % o, 'asp', ''))
                else: report.append((f[7], '不在候选', '%#x' % o, '', data[k:k + 4].hex()))
    ms = int(argv[argv.index('--min-support') + 1]) if '--min-support' in argv else 1   # 至少几份补丁改过这个位置才收（实验性单份补丁的位置可滤掉）
    rows = []
    for o in sorted(hit):
        if len(sup[o]) < ms: continue
        k, w = hit[o]; s = sig(img, cs, o)
        rows.append('main\t%#x\t%s\t1\torig=%08x%s\t# %d 份社区补丁改过' % (o, k, w, '\tsig=' + s if s else '', len(sup[o])))
    body = ''.join('[widen.enable.%s]\n%s\n' % (d, '\n'.join(rows)) for d in ('handheld', 'docked')) if rows else ''
    sys.stdout.write(body)
    n = {t: sum(1 for r in report if r[1].startswith(t)) for t in ('落候选', '不在候选', '构建号不对')}
    sys.stderr.write('%s 构建 %s：启用行 %d；写入 落候选 %d / 不在候选 %d；构建号不对的补丁 %d\n' % (pid, bid, len(rows), n['落候选'], n['不在候选'], n['构建号不对']))
    if out and rows:
        d = os.path.join(out, pid); os.makedirs(d, exist_ok=True)
        p = os.path.join(d, 'patch.tsv'); p = p if not os.path.exists(p) else os.path.join(d, 'patch.widen.tsv')
        with open(p, 'w') as fo:
            fo.write('# S2Arm 补丁包 v1（tools/patch_widen_convert.py 生成：社区画幅补丁只取位置，值由宿主按设备比例填）\nschema\t1\nprogram\t%s\nbuild\t%s\nlicense\tlocal-only\n[caps]\nwiden\t1\t# 补丁：画幅转自适应\n%s' % (pid, bid, body))
        with open(os.path.join(d, '转换报告.tsv'), 'w') as fo:
            fo.write('补丁文件\t结论\t偏移\t种类\t社区字节\n'); fo.writelines('\t'.join(r) + '\n' for r in report)
        sys.stderr.write('写了 %s\n' % p)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

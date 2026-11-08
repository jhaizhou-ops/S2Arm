#!/usr/bin/env python3
"""宽屏第二层：社区超宽屏补丁当「答案」挑我方候选点（直连线 10-26，jhz：社区已经做好的宽屏补丁都要适配进宽屏库）。只解析、不执行、不改写游戏：
补丁（pchtxt）里的 @nsobid 与本模块 main 构建号相同时，逐行按偏移对 widen_sites.tsv——对上的候选就是社区作者改宽高比的那几处，
交给闭环（auto_table.sh 先试这组）。补丁本体只从本机数据目录读，不进仓库、不进包；产物只是我方候选的点集，运行时照旧走我方的门（按真实屏幕比、
不在宽屏已验证名单时回原值）。对不上的行（界面布局、跳空闲区代码等）只计数分类，不落地。

  comm_map.py points <补丁索引目录（含 INDEX.tsv）> <exefs 目录> <widen_sites.tsv>
      标准输出：对上的点集（模块:偏移,…，同 S2A_WIDEN_SITES 口径，可能为空）；标准错误：每个补丁文件一行（宽高比、对上 / 对不上数）。
pchtxt 偏移：带 @flag offset_shift 0x100 的是映像偏移；不带的是含 0x100 文件头的偏移，减 0x100。只认 @enabled 之后、@stop 之前的行"""
import csv, os, re, struct, sys


def build_id(path): return open(path, 'rb').read()[0x40:0x50].hex().upper()


def program_id(npdm):
    b = open(npdm, 'rb').read(); a = struct.unpack_from('<I', b, 0x70)[0]
    return '%016X' % struct.unpack_from('<Q', b, a + 0x10)[0]


def patch_offsets(text):
    shift = re.search(r'@flag\s+offset_shift\s+0x100', text) is not None; on = False; out = []
    for l in text.splitlines():
        s = l.strip()
        if s.startswith('@enabled'): on = True; continue
        if s.startswith('@stop'): on = False; continue
        m = re.match(r'([0-9A-Fa-f]{8})\s+[0-9A-Fa-f]+', s)
        if on and m: out.append(int(m.group(1), 16) - (0 if shift else 0x100))
    return out


def points(index_dir, exefs, sites_tsv):
    sites = {}
    for l in open(sites_tsv):
        f = l.rstrip('\n').split('\t')
        if len(f) >= 3 and f[0] == 'main' and f[1].startswith('0x'): sites[int(f[1], 16)] = f[2]
    pid, bid = program_id(os.path.join(exefs, 'main.npdm')), build_id(os.path.join(exefs, 'main'))
    idx = os.path.join(index_dir, 'INDEX.tsv')
    if not os.path.exists(idx): return []
    hit = set()
    for r in csv.DictReader(open(idx, encoding='utf-8', errors='replace'), delimiter='\t'):
        if r.get('kind') != 'pchtxt' or (r.get('title_id') or '')[:-3].upper() != pid[:-3]: continue
        try: t = open(os.path.join(index_dir, r['path']), encoding='utf-8', errors='replace').read()
        except OSError: continue
        m = re.search(r'@nsobid-([0-9A-Fa-f]+)', t)
        if not m or m.group(1).upper()[:32] != bid: continue
        offs = patch_offsets(t); h = [o for o in offs if o in sites]
        hit.update(h)
        print(f"{r.get('aspect', '?')}\t对上 {len(h)}\t对不上 {len(offs) - len(h)}\t{r['path'][-80:]}", file=sys.stderr)
    return sorted(hit)


if __name__ == '__main__':
    if len(sys.argv) != 5 or sys.argv[1] != 'points': sys.exit(__doc__)
    print(','.join(f'main:{o:#x}' for o in points(*sys.argv[2:])))

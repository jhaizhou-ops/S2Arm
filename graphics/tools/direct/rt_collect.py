#!/usr/bin/env python3
# 现编回收 R1（docs/研究/现编回收方案.md，WP14，不联网）：设备 / Mac 上直连兜底现编留下的文件 → 三张线索表，交出包时按本机游戏数据重出（R2）。
#   python3 rt_collect.py parse <输出目录> <拉回的兜底目录…>      出 rt_keys.tsv / rt_fout.tsv / rt_vt.tsv（多个目录取并集、去重、排序）
#   python3 rt_collect.py pull <设备> <App 包标识> <程序号> <目标目录>   devicectl 从设备 App 数据容器拉 Documents/wire/<程序号>/shaders/（USB / 局域网，不联网），
#     连同本机见过的管线表 Documents/wire/<程序号>/pso_user.tsv 放进同一目录（只有 game.tsv 的款出库时 pso_seed.py 合进随包 pso_manifest.tsv）
# 兜底目录（设备上 Documents/wire/<程序号>/shaders/，graphics/nvn/host_adapt.m DM_MSL_FALLBACK）里只读文件名和 _b.json 的键 / 阶段 / 链版本，不读 MSL 正文、不拿它进包：
#   <键>_b.json            兜底现编（s2a_dsh_compile）：rt_keys.tsv「键<TAB>阶段<TAB>链版本」
#   <键>_t<u>_<s>.metal    输出类型变体（nvn_mtl.m pso_fout_variant）：rt_fout.tsv「键<TAB>无符号掩码<TAB>有符号掩码」（十六进制，同文件名）
#   <键>_vt.metal          曲面前顶点核（直连曲面细分 T3 首遇现编）：rt_vt.tsv「键」
# 键必须是 16 位小写十六进制，别的文件、坏 json 计数报出、不进表（被改过 / 别处来的文件不当线索）
import json, os, re, subprocess, sys

KEY = r'[0-9a-f]{16}'
R_B = re.compile(rf'({KEY})_b\.json')
R_T = re.compile(rf'({KEY})_t([0-9a-f]+)_([0-9a-f]+)\.metal')
R_VT = re.compile(rf'({KEY})_vt\.metal')

def parse(dirs):
    keys, fout, vt, bad = {}, set(), set(), []
    for d in dirs:
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            m = R_B.fullmatch(f)
            if m:
                try: j = json.load(open(os.path.join(d, f)))
                except (ValueError, OSError) as e: bad.append(f'{f}：json 读不了（{e.__class__.__name__}）'); continue
                st, ch = j.get('stage'), j.get('chain')
                if j.get('key') != m.group(1) + '_b' or not isinstance(st, str) or not isinstance(ch, str): bad.append(f'{f}：键 / 阶段 / 链版本不对'); continue
                keys[m.group(1)] = (st, ch); continue
            m = R_T.fullmatch(f)
            if m: fout.add((m.group(1), int(m.group(2), 16), int(m.group(3), 16))); continue
            m = R_VT.fullmatch(f)
            if m: vt.add(m.group(1)); continue
            if f != 'pso_user.tsv' and not re.fullmatch(rf'{KEY}_b(\.metal|_bg\d|_bgv|_bgs\d|_bgc)?.*', f): bad.append(f'{f}：认不出')   # 管线表一起拉回，归 pso_seed.py
    return keys, fout, vt, bad

def write(out, keys, fout, vt):
    os.makedirs(out, exist_ok=True)
    def put(name, head, rows):
        t = os.path.join(out, name + '.tmp')
        with open(t, 'w') as fh: fh.write(head + ''.join(r + '\n' for r in rows))
        os.replace(t, os.path.join(out, name))
    put('rt_keys.tsv', '# 键\t阶段\t链版本（设备上兜底现编过的，rt_collect.py）\n', [f'{k}\t{s}\t{c}' for k, (s, c) in sorted(keys.items())])
    put('rt_fout.tsv', '# 键\t无符号掩码\t有符号掩码（输出类型变体）\n', [f'{k}\t{u:x}\t{s:x}' for k, u, s in sorted(fout)])
    put('rt_vt.tsv', '# 键（曲面前顶点核）\n', sorted(vt))

def pull(dev, bundle, tid, dst):
    os.makedirs(dst, exist_ok=True)
    cp = lambda src, to: subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', dev, '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                                         '--source', src, '--destination', to], capture_output=True, text=True, timeout=300)
    r = cp(f'Documents/wire/{tid}/shaders', dst)
    p = cp(f'Documents/wire/{tid}/pso_user.tsv', os.path.join(dst, 'pso_user.tsv'))   # 没有（没建过管线）不算失败
    return r.returncode, (r.stderr or r.stdout).strip()[-300:] + ('' if p.returncode == 0 else '；管线表没拉到')

if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == 'parse':
        keys, fout, vt, bad = parse(a[2:]); write(a[1], keys, fout, vt)
        print(f'rt_collect：兜底现编 {len(keys)} 键、输出类型变体 {len(fout)}、曲面前顶点 {len(vt)}；认不出 / 坏文件 {len(bad)}')
        for b in bad[:10]: print('  ', b)
    elif len(a) == 5 and a[0] == 'pull':
        rc, msg = pull(*a[1:])
        print(f'rt_collect：拉回 {"成功" if rc == 0 else "失败（不挡出包）"}{"" if rc == 0 else "：" + msg}')
    else: sys.exit('用法：rt_collect.py parse <输出目录> <兜底目录…> | pull <设备> <包标识> <程序号> <目标目录>')

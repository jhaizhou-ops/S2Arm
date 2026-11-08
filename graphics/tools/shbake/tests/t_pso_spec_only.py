#!/usr/bin/env python3
# 管线归档「只出特化表」单测（graphics/tools/shbake/pso_gen.py S2A_PSO_SPEC_ONLY=1，10-25 jhz：直连款的通用兜底只用社区状态 + 收回的种子编归档）。约 1 秒，不要 Metal 工具链
# 夹具：假 metallib（只有函数表）+ 3 个计算程序 + 离线索引里两条记录（顶点 V、片元 F，标志位 4 = 顶点自取）+ 特化表一行 v2（V × F、拓扑类 3、1 个样本、颜色附件 0 = Metal 格式 70 写掩码 15 不混合）。
# 期望按定义手算：① 不开开关 → 计算管线 3 条、渲染管线 1 条（就是那行特化；程序表里没有图形程序）；② 开开关 → 计算 0 条、渲染 1 条，
#   这一条的顶点 / 片元函数名 = sV / sF、颜色附件 0 格式 70 写掩码 15、拓扑 Triangle；③ 开开关但特化表空 → 0 条、0 片
import hashlib, json, os, struct, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); GEN = os.path.join(H, 'pso_gen.py')
C = [f's{(i + 1) << 40:016x}' for i in range(3)]; V, F = 's00000a0000000001', 's00000b0000000002'
def metallib(path, names):
    ents = b''
    for nm in names:
        tags = b'NAME' + struct.pack('<H', len(nm) + 1) + nm.encode() + b'\0' + b'HASH' + struct.pack('<H', 32) + hashlib.sha256(b'h' + nm.encode()).digest() + b'ENDT'
        ents += struct.pack('<I', 4 + len(tags)) + tags
    hd = bytearray(0x58); hd[:4] = b'MTLB'; struct.pack_into('<QQ', hd, 0x18, 0x58, len(ents))
    open(path, 'wb').write(bytes(hd) + struct.pack('<I', len(names)) + ents)
def galidx(path, keys):   # 头 24 字节（'GALI'、+16 记录数）+ 每条 <QII>（键、偏移、长度）；记录 100 字节，+96 = 标志位
    n = len(keys); recs = b''; tab = b''; off = 24 + 16 * n
    for k in keys:
        r = bytearray(100); struct.pack_into('<I', r, 96, 4); tab += struct.pack('<QII', int(k[1:], 16), off + len(recs), 100); recs += bytes(r)
    hd = bytearray(24); hd[:4] = b'GALI'; struct.pack_into('<I', hd, 16, n); open(path, 'wb').write(bytes(hd) + tab + recs)
def run(tag, spec_only, spec_rows, extra=None):
    d = os.path.join(T, tag); os.makedirs(d)
    metallib(os.path.join(d, 'gal.0.metallib'), C + [V, F]); open(os.path.join(d, 'gal.shards'), 'w').write('0000000000000000\tgal.0.metallib\n')
    galidx(os.path.join(d, 'gal.idx'), [V, F])
    open(os.path.join(d, 'programs.tsv'), 'w').write('idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n' + ''.join(f'{i}\tt\tok\tcompute\tt\tt\t{nm[1:]}\t0\t\n' for i, nm in enumerate(C)))
    sp = os.path.join(d, 'spec.tsv'); open(sp, 'w').write(spec_rows)
    env = {k: v for k, v in os.environ.items() if k != 'S2A_PSO_USE'}; env['S2A_PSO_SPEC_ONLY'] = '1' if spec_only else '0'; env.pop('S2A_PSO_SPEC_MAX', None); env.update(extra or {})
    r = subprocess.run([sys.executable, GEN] + [os.path.join(d, x) for x in ('programs.tsv', 'gal.idx', 'gal.shards', 'pso')] + ['30', '', '', sp], capture_output=True, text=True, env=env)
    if r.returncode: print(f'✗ {tag}：pso_gen 失败 {r.stderr[-300:]}'); return None, []
    s = json.loads(r.stdout.strip().splitlines()[-1]); pipes = []
    for c in range(s['chunks']):
        j = json.load(open(os.path.join(d, f'pso.{c}.mtl4-json'))); nm = {f['label']: f['name'] for f in j['function_descriptors']['library_function_descriptors']}
        for p in j['pipeline_descriptors'].get('render_pipeline_descriptors', []):
            pipes.append((nm[p['vertex_function_descriptor'][4:]], nm.get(p.get('fragment_function_descriptor', 'fnd:')[4:]), p['color_attachments'][0], p.get('input_primitive_topology')))
    return s, pipes
T = tempfile.mkdtemp(prefix='t_pso_spec_only.'); fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
ROW = f'v2\t{V}\t{F}\t3\t1\t0\t0\t1\t0:70:15:0:0:1:0:0:1:0\t# 来源=yuzu10\n'
s1, _ = run('full', False, ROW)
ck(s1 and (s1['compute'], s1['render']) == (3, 1), f'① 不开开关：计算 3、渲染 1（{s1 and (s1["compute"], s1["render"])}）')
s2, p2 = run('spec', True, ROW)
ck(s2 and (s2['compute'], s2['render'], s2['spec_only']) == (0, 1, True), f'② 开开关：计算 0、渲染 1（{s2 and (s2["compute"], s2["render"])}）')
ck(len(p2) == 1 and p2[0][:2] == (V, F) and p2[0][2].get('pixel_format') in (70, 'RGBA8Unorm') and p2[0][2].get('write_mask') == 15 and p2[0][3] == 'Triangle',
   f'② 那一条就是特化行：sV × sF、格式 70、写掩码 15、拓扑 Triangle（{p2}）')
s3, _ = run('empty', True, '')
ck(s3 and (s3['compute'], s3['render'], s3['chunks']) == (0, 0, 0), f'③ 开开关、特化表空：0 条、0 片（{s3 and (s3["compute"], s3["render"], s3["chunks"])}）')
# ④ 按常见度截（S2A_PSO_SPEC_MAX=2）：种子（行尾没有「来源=」，格式 80）一行、社区 1 个来源（格式 71）一行、2 个来源（格式 72）一行 → 留种子与 2 个来源那行、截 1 行
R4 = (f'v2\t{V}\t{F}\t3\t1\t0\t0\t1\t0:71:15:0:0:1:0:0:1:0\t# 来源=yuzu10\n' + f'v2\t{V}\t{F}\t3\t1\t0\t0\t1\t0:72:15:0:0:1:0:0:1:0\t# 来源=ryu0,yuzu5\n'
      + f'v2\t{V}\t{F}\t3\t1\t0\t0\t1\t0:80:15:0:0:1:0:0:1:0\n')
s4, p4 = run('cut', True, R4, {'S2A_PSO_SPEC_MAX': '2'})
ck(s4 and s4['spec_cut'] == 1 and sorted(p[2]['pixel_format'] for p in p4) == [72, 80], f'④ 按常见度截：留种子（80）与 2 个来源（72）、截 1 行（截 {s4 and s4["spec_cut"]}，留 {sorted(p[2]["pixel_format"] for p in p4)}）')
print(f't_pso_spec_only：{n} 项，失败 {fail}'); sys.exit(1 if fail else 0)

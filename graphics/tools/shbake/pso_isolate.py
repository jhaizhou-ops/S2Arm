#!/usr/bin/env python3
# 管线分片编译失败时隔离坏管线（pso_chunk.sh 调）：pso_isolate.py <pso.N.mtl4-json> <输出归档> <坏管线清单> -- <applegpu-nt 及其参数（不含 -N / -o）>
# 10-21 怪猎第 85 片：299 条里 1 条计算管线（s98e4eb43c87f2b1c）让 applegpu-nt「LLVM ERROR: Failed to encode」中止，整片 299 条全丢、首遇现建。
# 做法：二分找出单独编也失败的管线（好的一半整块放过，坏的一半继续劈），其余照收进一份归档；坏的每行一个函数名串写进清单（shader_pack.sh 报红点名）。
# 退出 0 = 输出归档已写（可能少了坏的）；1 = 隔离后仍编不出，或坏的超过上限（照旧算整片失败）
# 上限 PSO_ISO_MAX_BAD（缺省 8）：坏的超过它就不再二分、按整片失败——整片都编不过（工具链坏 / 架构不对）时二分要 2n−1 次试编（300 条约 600 次），
#   设上限后试编次数有界（10-21 本线自查：938dc28 起没设上限）
# 试编超时（PSO_ISO_TIMEOUT 秒，缺省 600）= 编译异常，不是坏管线：停止二分、不记坏清单、按整片失败退出 1（审计 #806 第 4 条：原先超时当「这一半编不过」劈到单条记坏，
#   好管线被丢、运行时现编）。试编经仓库 tools/bin/timeout（perl 版：命令自立一组、到点 TERM 整组 2 秒后 KILL、退出 124）——
#   原先 subprocess.run(timeout) 只杀直接子进程，applegpu-nt 拉起的编译子进程被过继后继续占核
import json, os, subprocess, sys
S, OUT, BAD = sys.argv[1:4]; NT = sys.argv[sys.argv.index('--') + 1:]
j = json.load(open(S)); lab = {f['label']: f['name'] for f in j['function_descriptors']['library_function_descriptors']}
pd = j['pipeline_descriptors']; items = [('r', d) for d in pd.get('render_pipeline_descriptors', [])] + [('c', d) for d in pd.get('compute_pipeline_descriptors', [])]
T = S + '.iso.mtl4-json'; n_try = [0]; MAX_BAD = int(os.environ.get('PSO_ISO_MAX_BAD', '8'))
TO_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'tools', 'bin', 'timeout'); ISO_TO = int(os.environ.get('PSO_ISO_TIMEOUT', '600'))
class IsoTimeout(Exception): pass
def compile_(sub, out):
    k = dict(j); k['pipeline_descriptors'] = {'render_pipeline_descriptors': [d for t, d in sub if t == 'r'], 'compute_pipeline_descriptors': [d for t, d in sub if t == 'c']}
    json.dump(k, open(T, 'w')); n_try[0] += 1
    rc = subprocess.run([TO_BIN, str(ISO_TO)] + NT + ['-N', T, '-o', out], capture_output=True).returncode
    if rc == 124: raise IsoTimeout()
    return rc == 0
bad = []
def find(sub):
    if len(bad) > MAX_BAD or compile_(sub, OUT + '.iso.tmp'): return
    if len(sub) == 1: bad.append(sub[0]); return
    h = len(sub) // 2; find(sub[:h]); find(sub[h:])
def clean():
    for f in (T, OUT + '.iso.tmp'):
        if os.path.exists(f): os.remove(f)
try:
    find(items)
    if len(bad) > MAX_BAD:
        clean(); print(f'pso_isolate：{len(items)} 条里坏的超过上限 {MAX_BAD}（已找出 {len(bad)} 条，试编 {n_try[0]} 次）：按整片失败处理'); sys.exit(1)
    good = [x for x in items if x not in bad]
    ok = bool(good) and compile_(good, OUT)
except IsoTimeout:
    clean(); print(f'pso_isolate：{len(items)} 条第 {n_try[0]} 次试编超过 {ISO_TO} 秒：超时是编译异常、不等于管线坏，不记坏管线，按整片失败处理'); sys.exit(1)
clean()
def name(d): return ','.join(lab.get(v[4:], v) for k, v in d.items() if k.endswith('function_descriptor'))
open(BAD, 'w').write(''.join(name(d) + '\n' for _, d in bad))
print(f'pso_isolate：{len(items)} 条里隔离出 {len(bad)} 条坏管线（{"、".join(name(d) for _, d in bad[:4])}），其余 {len(good)} 条{"已编成" if ok else "仍编不出"}；共试编 {n_try[0]} 次')
sys.exit(0 if ok else 1)

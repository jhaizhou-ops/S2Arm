#!/usr/bin/env python3
# S2A.Dsh 逐函数对照：期望 = 冻结金样（dsh_fn_golden.jsonl，每行一例 {"fn", "args", "want"}），真结果 = C# 移植（dsh_cmp --fn）。补考卷没走到的分支：transform feedback（tf_layout / vs_tf）、
# VertexA+B 合并（vertex_ab）、层切片几何（gs_slice）、单线程子群改写（spv_single_lane）、绑定解码的各类句柄（decode_tex / const_sampler / decode_ubo_tex / ubo_sampler / c2_array / reflect）、
# 驱动段读取（drv_reads / unfillable）、光栅事实的 uv 直通与仿射（raster_facts）、层入口 / 整数输出入口 / 几何捕获（vs_layer_entry / fs_uint / capture）、输出类型变体（fs_typed / ft_masks / ft_msl）、
# 采样器偏置 / 归约（fs_lb / fs_rd）、巨型阶梯压平（giant_fix），外加 libnxgal 的 GLSL / MSL 与命令行 spirv-cross 逐字同。
# 金样来历（11-01，dsh 收敛到 C#，Python 改写器删除；原则：不维护第二份实现、不对拍）：用删除前的离线链（9bc1631cb 的 dmsh_build.py 按 AST 抽函数 + dmsh_fetch / dmsh_vin / dmsh_geometry /
#   dmsh_flat / dmsh_red）对本文件旧版的手写片段、glslangValidator 现编的 SPIR-V（以字节存进金样，不再现编）、随机句柄名 / 控制段（固定种子 20261024）一次性算出；
#   glsl_nxgal / msl_nxgal 的期望 = 当时命令行 spirv-cross 的输出。金样里没有游戏数据：旧版从动森考卷抽 MSL 的用例已删，真实着色器由 t_dsh.sh ①③ 对考卷全量逐字比覆盖。
# 两边都报错算一致（报错类名不比）。
# 更新金样（只有这一条路，不许重新引入 Python 实现当期望）：C# 有意改了行为 → t_dsh_fn.py <dll> <dylib> --dump <新.json> 把当前 C# 输出写成同格式文件 →
#   逐例人工审 diff（git diff --no-index dsh_fn_golden.jsonl 新.json）确认每处变化都是本次有意的 → 覆盖 dsh_fn_golden.jsonl，与 C# 改动同一提交。加用例同理：手写 args、want 由 C# 出、人工审过。
# 用法：t_dsh_fn.py <dsh_cmp.dll> <libnxgal.dylib> [--dump <输出.json>]
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); GOLD = os.path.join(HERE, 'dsh_fn_golden.jsonl')
DLL, NXGAL = sys.argv[1:3]; DUMP = sys.argv[sys.argv.index('--dump') + 1] if '--dump' in sys.argv else None
DN = os.environ.get('DOTNET', os.path.expanduser('~/.dotnet/dotnet'))

gold = [json.loads(l) for l in open(GOLD) if l.strip()]
if not gold: sys.exit(f'✗ 金样 {GOLD} 是空的')
tmp = tempfile.mkdtemp(prefix='t_dsh_fn_')
try:
    cp = os.path.join(tmp, 'cases.json'); rp = os.path.join(tmp, 'res.json')
    json.dump([{'fn': g['fn'], 'args': g['args']} for g in gold], open(cp, 'w'))
    r = subprocess.run([DN, DLL, '--fn', cp, rp, '--nxgal', NXGAL, '--tables', '.', '--out', tmp], capture_output=True, text=True)
    if r.returncode: sys.exit(f'✗ dsh_cmp --fn 退出 {r.returncode}：{r.stderr[-600:]}')
    got = json.load(open(rp))
finally: shutil.rmtree(tmp, True)
if len(got) != len(gold): sys.exit(f'✗ dsh_cmp --fn 回了 {len(got)} 个结果，金样 {len(gold)} 例')
if DUMP:
    with open(DUMP, 'w') as f:
        for g, x in zip(gold, got): f.write(json.dumps({'fn': g['fn'], 'args': g['args'], 'want': x}, ensure_ascii=False) + '\n')
    print(f'已写 {DUMP}（{len(got)} 例）：人工审过与金样的差异再覆盖 {os.path.basename(GOLD)}（报错例的类名两边本就不同，只看报没报错）'); sys.exit(0)
stat, bad = {}, []
for g, x in zip(gold, got):
    want = g['want']; same = ('err' in want and 'err' in x) or want == x
    s = stat.setdefault(g['fn'], [0, 0, 0, 0]); s[0] += 1; s[1] += same; s[2] += 'err' in want
    s[3] += 'ok' in want and want['ok'] not in (None, False, [], {}, {'pos_attr': -1}) and not (isinstance(want['ok'], list) and want['ok'][:1] == [False])   # 走到实质分支的例数（射程）
    if not same and len(bad) < 8: bad.append(f"{g['fn']}：期望 {str(want)[:150]} / 真结果 {str(x)[:150]}")
for fn, (n, ok, err, real) in sorted(stat.items()): print(f"  {'✓' if ok == n else '✗'} {fn}：{ok}/{n} 一致（两边都报错 {err}、有实质结果 {real}）")
for b in bad: print('  ✗ ' + b)
n = sum(s[0] for s in stat.values()); ok = sum(s[1] for s in stat.values())
print(f'逐函数对照：{len(stat)} 个函数 {n} 例，一致 {ok}，不一致 {n - ok}')
sys.exit(0 if ok == n and n else 1)

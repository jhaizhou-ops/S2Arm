#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/* graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py tests/dmsh_single_lane_test.sh
# 顶点着色器单车道子组改写（S2A.Dsh DshCompiler.SpvSingleLane，经 dsh_cmp --fn spv_single_lane，约 10 秒）：bash tests/dmsh_single_lane_test.sh
# 11-01 dsh 收敛到 C#：出包每键改写由 C# 批量进程做（离线链 dmsh_build.py 的 Python spv_single_lane 已删），本单测改测 C# 那份，手写期望不变。
# Metal 顶点函数没有 SIMD 组函数，带子组内建 / 子组指令的顶点着色器 spirv-cross 直接抛「Subgroup builtins are not available in this type of function」
#   （异度3 4b98320a0f512efe：ballot 活跃车道 → IAdd 排他扫描 1 算本车道序号 → shuffle 取首车道的值）。改写按「子组只有一个车道」的语义把这些指令换成常量 / 本值。
# 手工装配一支最小顶点模块（不依赖 spirv-as），期望按一个车道的语义手算：
#   ① ballot(true) → 分量 0 = OpSelect(true, 1, 0)、其余 0，合成 uvec4；不再是 OpSelect 标量条件选向量（SPIR-V 1.4 前不合法，spirv-val 红）
#   ② IAdd ExclusiveScan 1 → 常量 0（排他扫描的恒等元）；③ IAdd Reduce v → v 本值（OpCopyObject）
#   ④ SubgroupLtMask 分量 0 的读取 → 常量 0；入口接口表与 BuiltIn 装饰里不再有它；GroupNonUniform* 能力去掉
#   ⑤ 改写后没有任何 OpGroupNonUniform*（操作码 333–366）；有 spirv-val 时整模块校验过
#   ⑥ 反证：BallotBitCount（没覆盖的子组指令）→ 返回 False、文件字节不变
#   ⑦ 不读子组内建、只有算术类子组运算（怪猎 296 支：All / Ballot / Shuffle / IAdd）→ 返回 False、文件不变（Metal SIMD 函数照编）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
"$PY" - "$H" <<'PYEOF'
import struct, sys, os, shutil, subprocess, tempfile
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics/tools/direct/tests')); import dshfn
def lanes(*paths):   # C# 改写各文件（一次 dsh_cmp --fn）：改写后的字节写回原文件；→ 各自的返回值（不是 [布尔, 字节] 的给 None）
    rs = dshfn.batch([('spv_single_lane', [open(p, 'rb').read().hex()]) for p in paths]); out = []
    for p, r in zip(paths, rs):
        v = r.get('ok')
        if not (isinstance(v, list) and len(v) == 2): print(f'— {os.path.basename(p)}：C# 没给结果 {r}'); out.append(None); continue
        open(p, 'wb').write(bytes.fromhex(v[1])); out.append(v[0])
    return out
bad = 0
def check(ok, what):
    global bad; bad += not ok; print(f'{"✓" if ok else "✗"} {what}')

def I(op, *w): return [op | (len(w) + 1) << 16, *w]
# ids
VOID, FN, BOOL, UINT, FLOAT, UVEC4, PIN_UVEC4, PIN_UINT, PFN_FLOAT = range(1, 10)
TRUE, U0, U1, U3, I0, F1 = 10, 11, 12, 13, 14, 15
LTMASK, MAIN, LABEL, BALLOT, SCAN, REDUCE, CHAIN, LOAD, SHUF, VARF, LOADF = range(16, 27)
def module(sg_extra):
    ins = [I(17, 1), I(17, 64), I(17, 63), I(17, 65),   # Shader, GroupNonUniformBallot, GroupNonUniformArithmetic, GroupNonUniformShuffle
           I(14, 0, 1),   # OpMemoryModel Logical GLSL450
           I(15, 0, MAIN, *struct.unpack('<2I', b'main\0\0\0\0'), LTMASK),   # OpEntryPoint Vertex
           I(71, LTMASK, 11, 4420),   # BuiltIn SubgroupLtMask
           I(19, VOID), I(33, FN, VOID), I(20, BOOL), I(21, UINT, 32, 0), I(22, FLOAT, 32), I(23, UVEC4, UINT, 4),
           I(32, PIN_UVEC4, 1, UVEC4), I(32, PIN_UINT, 1, UINT), I(32, PFN_FLOAT, 7, FLOAT),
           I(41, BOOL, TRUE), I(43, UINT, U0, 0), I(43, UINT, U1, 1), I(43, UINT, U3, 3), I(43, UINT, I0, 0), I(43, FLOAT, F1, 0x3f800000),
           I(59, PIN_UVEC4, LTMASK, 1),
           I(54, VOID, MAIN, 0, FN), I(248, LABEL), I(59, PFN_FLOAT, VARF, 7),
           I(339, UVEC4, BALLOT, U3, TRUE),              # OpGroupNonUniformBallot
           I(349, UINT, SCAN, U3, 2, U1),                # OpGroupNonUniformIAdd ExclusiveScan 1
           I(349, UINT, REDUCE, U3, 0, U3),              # OpGroupNonUniformIAdd Reduce 3
           I(65, PIN_UINT, CHAIN, LTMASK, I0), I(61, UINT, LOAD, CHAIN),   # LtMask[0]
           I(61, FLOAT, LOADF, VARF), I(345, FLOAT, SHUF, U3, LOADF, U0),   # OpGroupNonUniformShuffle
           *sg_extra,
           I(253), I(56)]
    words = [0x07230203, 0x00010300, 0, 40, 0] + [w for x in ins for w in x]
    return struct.pack(f'<{len(words)}I', *words)
def parse(d):
    words = list(struct.unpack(f'<{len(d) // 4}I', d)); out, i = [], 5
    while i < len(words): n = words[i] >> 16; out.append(words[i:i + n]); i += n
    return out
w = tempfile.mkdtemp(); p = os.path.join(w, 't.spv'); open(p, 'wb').write(module([]))
p2 = os.path.join(w, 'u.spv'); d0 = module([I(342, UINT, 30, U3, 0, BALLOT)]); open(p2, 'wb').write(d0)   # ⑥ OpGroupNonUniformBallotBitCount：没覆盖
# ⑦ 同一模块把 SubgroupLtMask 的 BuiltIn 装饰换成 RelaxedPrecision（装饰号 0，不是内建）：只剩子组运算、不读内建
ws = list(struct.unpack(f'<{len(module([])) // 4}I', module([]))); dec = I(71, LTMASK, 11, 4420)
k = next(i for i in range(5, len(ws)) if ws[i:i + 4] == dec); ws[k:k + 4] = I(71, LTMASK, 0)
p3 = os.path.join(w, 'v.spv'); d3 = struct.pack(f'<{len(ws)}I', *ws); open(p3, 'wb').write(d3)
r1, r2, r3 = lanes(p, p2, p3)   # 三个模块一次交给 C#
check(r1 is True, '改写返回 True')
ins = parse(open(p, 'rb').read()); op = lambda x: x[0] & 0xffff; by = {x[2]: x for x in ins if len(x) > 2}
def const_val(i): return next((x[3] for x in ins if op(x) == 43 and x[2] == i), None)
b = by.get(BALLOT); sel = by.get(b[3]) if b and op(b) == 80 else None
check(b is not None and op(b) == 80 and b[1] == UVEC4 and sel is not None and op(sel) == 169 and sel[1] == UINT and sel[3] == TRUE
      and const_val(sel[4]) == 1 and const_val(sel[5]) == 0 and all(const_val(c) == 0 for c in b[4:7]),
      f'① ballot → OpCompositeConstruct uvec4(OpSelect(true, 1, 0), 0, 0, 0)：实得 {b and op(b)} / 分量 0 {sel and op(sel)}')
s = by.get(SCAN); check(s is not None and op(s) == 83 and const_val(s[3]) == 0, f'② IAdd ExclusiveScan 1 → OpCopyObject 常量 0：实得 {s}')
r = by.get(REDUCE); check(r is not None and op(r) == 83 and r[3] == U3, f'③ IAdd Reduce v → OpCopyObject v：实得 {r}')
l = by.get(LOAD); ep = next(x for x in ins if op(x) == 15)
check(l is not None and op(l) == 83 and const_val(l[3]) == 0 and LTMASK not in ep[4:] and not any(op(x) == 71 and x[1] == LTMASK for x in ins)
      and not any(op(x) == 17 and x[1] in (61, 62, 63, 64, 65, 66, 67, 68) for x in ins),
      f'④ LtMask[0] 读取 → 常量 0，内建变量退出接口表 / 装饰，GroupNonUniform 能力去掉：实得 {l}，接口 {ep[4:]}')
sh = by.get(SHUF); left = [op(x) for x in ins if 333 <= op(x) <= 366]
check(sh is not None and op(sh) == 83 and sh[3] == LOADF and not left, f'⑤ shuffle → 本值，没有剩余 OpGroupNonUniform*：剩 {left}')
val = shutil.which('spirv-val')
if val:
    rv = subprocess.run([val, p], capture_output=True, text=True); check(rv.returncode == 0, f'⑤ spirv-val 校验过：{(rv.stdout + rv.stderr).strip()[:160] or "ok"}')
else: print('— spirv-val 不在本机，跳过整模块校验')
check(r2 is False and open(p2, 'rb').read() == d0, '⑥ 反证：BallotBitCount 没覆盖 → False、文件不变')
check(r3 is False and open(p3, 'rb').read() == d3, '⑦ 不读子组内建、只有算术类运算（怪猎 296 支的形状）→ False、文件不变')
shutil.rmtree(w)
print(f'{"✓" if not bad else "✗"} dmsh_single_lane_test：{8 if val else 7} 项，失败 {bad}')
sys.exit(1 if bad else 0)
PYEOF

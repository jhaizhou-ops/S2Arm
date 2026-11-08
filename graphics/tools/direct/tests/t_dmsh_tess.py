#!/usr/bin/env python3
# 直连曲面阶段翻译单测（libnxgal nxgal_dmsh_xc_tess，10-24 直连曲面细分 T1，约 5 秒）：python3 t_dmsh_tess.py <libnxgal.dylib> <t_tess 目录（vs / tcs / tes .spv，make -C graphics/metal 生成）>
#   期望按规则手算（不跑被测实现推期望）：起始槽号 base = 20 → IN 20、OUT 21、PATCH 22、FACTOR 23、PARAMS 24、POINTS 25（GAL_TESS_AT = base + 槽 − 8）。
#   ① 曲面前顶点（vt = 1）：计算核 main0，写 OUT（21），绘制参数 S2ATessVtx 在 POINTS（25）；② TCS：计算核，读 IN（20）、写 OUT（21）/ 因子（23），输出控制点数 = spvasm 里写的 4（OutputVertices 4）；
#   ③ TES：普通顶点函数，[[vertex_id]] + 域点（25）+ 输出控制点数（24），读 IN（20）；三段都不再出现 [[patch]] / [[position_in_patch]] / [[stage_in]] 外的曲面属性；
#   ④ 三段 MSL 交 xcrun metal -c 编过；⑤ 反证：片元着色器、vt = 0 的顶点着色器 → 失败并说明「不是曲面阶段」；⑥ 域着色器里的图像原子译成贴图原生原子（MSL 3.1，审计 #1534 P1-43）
import ctypes, os, subprocess, sys, tempfile

lib = ctypes.CDLL(sys.argv[1]); d = sys.argv[2]
f = lib.nxgal_dmsh_xc_tess
f.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.c_int32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32), ctypes.c_char_p, ctypes.c_uint64]
f.restype = ctypes.c_int32
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)
def xc(nm, vt, base=20):
    spv = open(os.path.join(d, nm + '.spv'), 'rb').read()
    out = ctypes.c_char_p(); fl = ctypes.c_uint32(); ocp = ctypes.c_uint32(); err = ctypes.create_string_buffer(512)
    rc = f(spv, len(spv), vt, base, ctypes.byref(out), ctypes.byref(fl), ctypes.byref(ocp), err, 512)
    return rc, (out.value or b'').decode(), fl.value, ocp.value, err.value.decode()
rc, vs, vfl, _, e = xc('vs', 1)
ck(f'① 曲面前顶点：rc 0（{e}）、kernel main0、写 OUT buffer(21)、S2ATessVtx 在 buffer(25)', rc == 0 and 'kernel void main0(' in vs and '[[buffer(21)]]' in vs and 'S2ATessVtx& s2a_td [[buffer(25)]]' in vs and '[[stage_in]]' not in vs)
rc, tcs, tfl, ocp, e = xc('tcs', 0)
ck(f'② TCS：rc 0（{e}）、计算核、读 IN buffer(20)、写 OUT buffer(21) / 因子 buffer(23)、输出控制点数 {ocp}（期望 4）', rc == 0 and 'kernel void main0(' in tcs and '[[buffer(20)]]' in tcs and '[[buffer(21)]]' in tcs and '[[buffer(23)]]' in tcs and ocp == 4)
rc, tes, efl, _, e = xc('tes', 0)
ck(f'③ TES：rc 0（{e}）、普通顶点函数、[[vertex_id]] + 域点 buffer(25) + 控制点数 buffer(24)、读 IN buffer(20)、无 [[patch]] / [[position_in_patch]]',
   rc == 0 and 'vertex main0_out main0(' in tes and 's2a_pts [[buffer(25)]]' in tes and 's2a_ocp [[buffer(24)]]' in tes and '[[buffer(20)]]' in tes and '[[ patch(' not in tes and '[[position_in_patch]]' not in tes)
# 两段 spvasm 都写 Quads + SpacingEqual + VertexOrderCw → 域 3 << 5 | 分区 1 << 7 | 顺时针 1 << 9 = 0x2e0（gal_internal.h GAL_REC_*，位 5–10）
ck(f'③ 曲面记录位：TCS {tfl & 0x7e0:#x}、TES {efl & 0x7e0:#x}（期望都是 0x2e0）', tfl & 0x7e0 == 0x2e0 and efl & 0x7e0 == 0x2e0)
# ⑥ 审计 #1534 P1-43：直连曲面出口与直连非曲面 / 通用层同为 MSL 3.1——域着色器里的存储图像原子译成贴图原生原子；2.3 时另造 cnt_atomic 模拟缓冲（宿主不绑，原子落空）
rc, tea, _, _, e = xc('tesatom', 0)
ck(f'⑥ 曲面阶段图像原子走原生：rc 0（{e}）、有 .atomic_fetch_add(、无 cnt_atomic 模拟缓冲', rc == 0 and '.atomic_fetch_add(' in tea and 'cnt_atomic' not in tea)
with tempfile.TemporaryDirectory() as t:
    oks = []
    for nm, src in (('vs', vs), ('tcs', tcs), ('tes', tes)):
        p = os.path.join(t, nm + '.metal'); open(p, 'w').write(src)
        r = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', p, '-o', p + '.air'], capture_output=True, text=True)
        oks.append(r.returncode == 0 or print(r.stderr[-600:]))
    ck('④ 三段 MSL 交 xcrun metal -c 编过', all(oks))
rc, _, _, _, e = xc('fs', 0)
ck(f'⑤ 反证：片元着色器 → 失败（rc {rc}、{e}）', rc != 0 and '不是曲面阶段' in e)
rc, _, _, _, e = xc('vs', 0)
ck(f'⑤ 反证：vt = 0 的顶点着色器 → 失败（rc {rc}）', rc != 0 and '不是曲面阶段' in e)
print(f't_dmsh_tess：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)

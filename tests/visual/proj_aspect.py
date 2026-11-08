#!/usr/bin/env python3
"""录像里游戏镜头的宽高比：扫 GAL 录像全部常量写入里的透视投影（w 行 = (0,0,±1,0)，行存 / 列存都认），按 |P11| / P00 统计宽高比分布；
另列放宽 / 原生宽的渲染目标尺寸。用来判「游戏自己的镜头是否已按屏幕宽高比算」（宽屏第二层闭环判据之一），不依赖被测实现。
用法：proj_aspect.py <gal.rec> [--target 2346/1080]；输出：各宽高比的投影次数（按 0.01 分档）、最大的颜色目标尺寸、判定行。退出码 0 = 主镜头已是目标比、1 = 不是。
主镜头 = 画到场景目标（绘制最多的深度附件）上的绘制所绑常量缓冲区间里的投影，按绘制次数计（10-20 动森主机档：阴影 / 倒影 / 界面 3D 图标的 1.78 投影
写入 93 次、场景镜头 2.17 只 20 次，按写入次数挑会认错；帐篷宽高比与掌机已验局一致 1.108 / 1.110，画面并未拉伸）。场景绘制上一个投影都找不到时退回按写入次数。
投影两种形状（行存 / 列存都认）：
  标准：w 行 = (0,0,±1,0)、P00 > 0；
  RE 引擎（10-21 怪猎）：16 个浮点按 4 组看只有每组前 3 个是投影（第 4 个、即第 12–15 号里 w 相关的位置放的是 ±1 / 4.9 一类别的数据，每次不同），
    P00 为负（x 翻转）、抖动小量 ≤1e-3、反向无限远（z 对 z 系数 ≈0、近平面项 ≠0）；只按前 3 列认，按行存一遍算（不在列存那遍重复计）。
P00 / P11 都要在 0.05–50（视角约 2°–175°）：认不出时宁可报「主镜头宽高比 None」（closed_loop.sh 据此改判场景目标宽高比），
也不把恰好凑成形状的杂数据报成 1e31 一类的垃圾宽高比（10-21 怪猎 b_mhloop2 录像旧版报 1.06e31）。"""
import struct, sys, collections
import numpy as np

a = sys.argv[1:]
tgt = eval(a[a.index('--target') + 1]) if '--target' in a else 2346 / 1080
b = open(a[0], 'rb').read(); assert b[:8] == b'S2AGAL01'; pos = 12
def blob():
    global pos
    ln, = struct.unpack_from('<I', b, pos); pos += 4
    if ln != 0xFFFFFFFF: pos += ln
blob(); blob()
n, = struct.unpack_from('<I', b, pos); pos += 4
for _ in range(n):
    op, ln = struct.unpack_from('<II', b, pos); pos += 8 + ln
asp = collections.Counter(); sizes = collections.Counter(); inprolog = False
sz = {}; ds = 0; dsdraw = collections.Counter()   # 场景目标：绘制最多的深度附件
ev = []   # 时间线（第二遍按场景目标统计主镜头）：('p', 缓冲, 字节偏移, 宽高比) 投影写入；('u', [(binding, 缓冲, 偏移, 长度)]) 常量缓冲绑定；('d', 深度附件) 绘制
while pos + 8 <= len(b):
    op, ln = struct.unpack_from('<II', b, pos); pos += 8
    if op == 0xFF01: inprolog = True
    elif op == 0xFF02: inprolog = False
    elif (op == 0x108 and ln == 64) or (op == 0x2F0 and ln == 68):
        w, h = struct.unpack_from('<ii', b, pos); sizes[(w, h)] += 1; sz[struct.unpack_from('<I', b, pos + ln - 4)[0]] = (w, h)
    elif op == 0x304 and ln >= 76:
        w, h = struct.unpack_from('<ii', b, pos + 4); sz[struct.unpack_from('<I', b, pos + 72)[0]] = (w, h)
    elif op == 0x029:
        c, = struct.unpack_from('<I', b, pos); ds = struct.unpack_from('<I', b, pos + 4 + 4 * c)[0]
    elif op == 0x031 and ln >= 4:   # SetUniformBuffers：u32 个数 + 每项 32 字节 BufferAssignment（binding@0、句柄@8、偏移@16、长度@20）
        c, = struct.unpack_from('<I', b, pos)
        if ln >= 4 + 32 * c: ev.append(('u', [struct.unpack_from('<i4xQii', b, pos + 4 + 32 * k) for k in range(c)]))
    elif op in (0x009, 0x00A, 0x00B, 0x00C, 0x00D, 0x00E) and ds and not inprolog:
        dsdraw[ds] += 1; ev.append(('d', ds))
    elif op == 0x112:
        bh, = struct.unpack_from('<Q', b, pos); off, dl = struct.unpack_from('<iI', b, pos + 8)
        start = (16 - (off & 15)) & 15
        d = np.frombuffer(b, dtype=np.float32, count=dl // 4, offset=pos + 16)
        if dl >= 64:
            k0 = start // 4
            m = d[k0:k0 + ((len(d) - k0) // 4) * 4].reshape(-1, 4)
            for col in (False, True):
                if len(m) < 4: break
                # 每个 16 字节对齐位置当一个 4×4 的起点
                R = np.stack([m[i:len(m) - 3 + i] for i in range(4)], axis=1)   # (N, 4 行, 4)
                if col: R = R.transpose(0, 2, 1)
                with np.errstate(all='ignore'):
                    fin = np.isfinite(R).all(axis=(1, 2)); a0, a1 = np.abs(R[:, 0, 0]), np.abs(R[:, 1, 1])
                    sane = fin & (a0 > 0.05) & (a0 < 50) & (a1 > 0.05) & (a1 < 50)
                    std = (np.abs(R[:, 3, 0]) < 1e-6) & (np.abs(R[:, 3, 1]) < 1e-6) & (np.abs(R[:, 3, 3]) < 1e-6) & (np.abs(np.abs(R[:, 3, 2]) - 1) < 1e-4) \
                          & (np.abs(R[:, 0, 1]) < 1e-6) & (np.abs(R[:, 1, 0]) < 1e-6) & (R[:, 0, 0] > 0)
                    # RE 形状按「4 组 × 前 3 个」看（R 未转置时第 i 行 = 第 i 组）：组 0 = (P00, 0, 抖动)、组 1 = (0, P11, 0)、组 2 = (抖动, 0, z≈0)、组 3 第 3 个 = 近平面项（0–10；怪猎 b_mhloop2 录像里形状相同、这一位是 1499 的是世界坐标数据）
                    re = (np.abs(R[:, 0, 1]) < 1e-3) & (np.abs(R[:, 0, 2]) < 1e-3) & (np.abs(R[:, 1, 0]) < 1e-3) & (np.abs(R[:, 1, 2]) < 1e-3) \
                         & (np.abs(R[:, 2, 0]) < 1e-3) & (np.abs(R[:, 2, 1]) < 1e-3) & (np.abs(R[:, 2, 2]) < 1e-3) & (np.abs(R[:, 3, 2]) > 1e-6) & (np.abs(R[:, 3, 2]) < 10) & (not col)
                    ok = sane & (std | re)
                    r = a1[ok] / a0[ok]
                for i, v in zip(np.nonzero(ok)[0], r):
                    if not inprolog: asp[round(float(v), 2)] += 1
                    ev.append(('p', bh, off + start + 16 * int(i), round(float(v), 2)))
    pos += ln
tot = sum(asp.values())
print(f'透视投影 {tot} 次；宽高比分布（按 0.01 分档，前 8）：' + '，'.join(f'{k:.2f}×{v}' for k, v in asp.most_common(8)))
big = sorted(sizes, key=lambda s: -s[0] * s[1])[:6]
print('最大的贴图尺寸：' + '，'.join(f'{w}x{h}' for w, h in big))
if dsdraw:
    did, nd = dsdraw.most_common(1)[0]; w, h = sz.get(did, (0, 0))
    print(f'场景目标（绘制最多的深度附件 {did}，{nd} 次绘制）：{w}x{h}')
scene = collections.Counter()
if dsdraw:
    sid = dsdraw.most_common(1)[0][0]; bp = collections.defaultdict(dict); ub = {}
    for e in ev:
        if e[0] == 'p': bp[e[1]][e[2]] = e[3]
        elif e[0] == 'u':
            for bi, h, o, n in e[1]: ub[bi] = (h, o, n)
        elif e[1] == sid:
            for v in {a for h, o, n in ub.values() for po, a in bp.get(h, {}).items() if o <= po < o + n and a > 1.05}: scene[v] += 1
if scene: print('场景目标上的绘制所用投影（按绘制次数，前 6）：' + '，'.join(f'{k:.2f}×{v}' for k, v in scene.most_common(6)))
src = scene if scene else asp
cand = [(v, k) for k, v in src.items() if k > 1.05]; main = max(cand)[1] if cand else None   # 0.00 退化、1.00 阴影 / 立方体镜头不算主镜头
ok = main is not None and abs(main - tgt) / tgt < 0.01
print(f'主镜头宽高比 {main} → 目标 {tgt:.4f}：{"已是目标比（游戏自己宽）" if ok else "不是目标比"}')
sys.exit(0 if ok else 1)

#!/usr/bin/env python3
# spirv_msl.fix_bindings 单测（10-31 Minecraft：bgfx 的 HLSL `$Global` 常量块有 DescriptorSet 0、没有 Binding，直连库翻译 KeyError 'binding'）。
# 手造最小 SPIR-V 字流，不依赖外部工具；期望按 SPIR-V 修饰缺省值 0 手算：
#   ① 缺 Binding 的资源变量补一条 OpDecorate Binding 0，插在注解段末尾（类型声明之前）
#   ② 已有 Binding 的模块原样返回
#   ③ 缺 Binding 的变量缺省 (set, 0) 已被别的资源占用 → 报红停下，不猜
#   ④ 非资源变量（Private / Function / Input）不补
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'graphics', 'tools'))
import spirv_msl as m

OP_CAP, OP_MEMMODEL, OP_TYPE_FLOAT, OP_TYPE_STRUCT, OP_TYPE_PTR = 17, 14, 22, 30, 32
def ins(op, *a): return [((len(a) + 1) << 16) | op, *a]
def module(decos, vars_):   # decos: [(var, dec, value)]；vars_: [(id, storage class)]
    w = [m.MAGIC, 0x00010000, 0, 100, 0]
    w += ins(OP_CAP, 1) + ins(OP_MEMMODEL, 0, 1)
    for v, d, val in decos: w += ins(m.OP_DECORATE, v, d, val)
    w += ins(OP_TYPE_FLOAT, 2, 32) + ins(OP_TYPE_STRUCT, 3, 2) + ins(OP_TYPE_PTR, 4, 2, 3) + ins(OP_TYPE_PTR, 5, 6, 2)
    for v, sc in vars_: w += ins(m.OP_VARIABLE, 4 if sc == 2 else 5, v, sc)
    return w
def decs(w):
    out, i = [], 5
    while i < len(w):
        op, n = w[i] & 0xFFFF, w[i] >> 16
        if op == m.OP_DECORATE: out.append(tuple(w[i + 1:i + 4]))
        i += n
    return out
def first_type(w):
    i = 5
    while i < len(w):
        if w[i] & 0xFFFF == OP_TYPE_FLOAT: return i
        i += w[i] >> 16
bad = 0
def check(ok, msg): 
    global bad; bad += not ok; print(('✓ ' if ok else '✗ ') + msg)

w = module([(10, m.DEC_SET, 0)], [(10, 2)]); r = m.fix_bindings(w)
check((10, m.DEC_BINDING, 0) in decs(r) and len(r) == len(w) + 4 and r.index(((4 << 16) | m.OP_DECORATE)) < first_type(r),
      f'① 缺 Binding 的 Uniform 变量补 Binding 0、在类型之前：{decs(r)}')
w = module([(10, m.DEC_SET, 0), (10, m.DEC_BINDING, 3)], [(10, 2)])
check(m.fix_bindings(w) == w, '② 已有 Binding 原样返回')
w = module([(10, m.DEC_SET, 0), (11, m.DEC_SET, 0), (11, m.DEC_BINDING, 0)], [(10, 2), (11, 0)])
try: m.fix_bindings(w, 'conflict'); check(False, '③ 缺省 (0,0) 被占用：期望报红，实际放过')
except SystemExit as e: check('already taken' in str(e), f'③ 缺省 (0,0) 被占用 → 报红：{str(e)[:90]}')
w = module([(10, m.DEC_SET, 0), (10, m.DEC_BINDING, 1)], [(10, 2), (12, 6)])
check(m.fix_bindings(w) == w, '④ Private 变量不补')
print(f'spirv_bindings_test：4 项，失败 {bad}'); sys.exit(1 if bad else 0)

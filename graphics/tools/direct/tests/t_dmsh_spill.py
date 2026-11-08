#!/usr/bin/env python3
# 直连计算着色器共享内存溢出单测（libnxgal nxgal_dmsh_spill + S2A.Dsh NxgalSpvCross.SpillFix：graphics/tools/direct/dsh/SpvCross.cs，经 dsh_cmp --fn 调（dshfn.py）；10-26 怪猎脸黑，约 3 秒）：python3 t_dmsh_spill.py <libnxgal.dylib>
#   期望按规则手算（不跑被测实现推期望）：Apple 线程组内存上限 32768 字节（离线无设备时取 GAL_TG_MEM_MAX）。
#   ① 超限：唯一的共享数组 uint[9220] = 36880 字节 → 改写、每线程组 36880 字节、入口多 device uchar* s2a_spill [[buffer(27)]]、数组改成溢出缓冲上的 device 引用、
#      原子转型 threadgroup → device、屏障带 mem_device；交 xcrun metal -c 编过
#   ② 不超限：uint[1024] = 4096 字节 → 原样（返回 0、字节 0）
#   ③ 认不出：超限但另有一处非 spvUnsafeArray 的 threadgroup 声明 → 返回 -1 并说明（调用方按翻译失败报红，不静默截断）
#   ④ C# 胶水 NxgalSpvCross.SpillFix（出包 / 设备现编同一份，Dsh.cs 以 SPILL_SLOT = 27 调）：同一份输入给出同样的字节数、不超限原样，③ 抛 DshError（调用方报翻译失败）
import ctypes, os, re, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import dshfn

LIB = os.path.abspath(sys.argv[1])
lib = ctypes.CDLL(LIB); f = lib.nxgal_dmsh_spill
f.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint32), ctypes.c_char_p, ctypes.c_uint64]
f.restype = ctypes.c_int32; fr = lib.nxgal_dmsh_xc_free; fr.argtypes = [ctypes.c_void_p]
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)
HEAD = '''#include <metal_stdlib>
using namespace metal;
template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    thread T& operator [] (size_t pos) thread { return elements[pos]; }
    threadgroup T& operator [] (size_t pos) threadgroup { return elements[pos]; }
    device T& operator [] (size_t pos) device { return elements[pos]; }
};
struct B { uint v[64]; };
'''
def kernel(n, extra=''):
    return HEAD + f'''kernel void main0(device B& b [[buffer(0)]], uint3 gl_LocalInvocationID [[thread_position_in_threadgroup]], uint3 gl_WorkGroupID [[threadgroup_position_in_grid]])
{{
    threadgroup spvUnsafeArray<uint, {n}> _42;{extra}
    _42[gl_LocalInvocationID.x] = gl_WorkGroupID.x;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint _7 = atomic_fetch_add_explicit((threadgroup atomic_uint*)&_42[4096 % {n}], 1u, memory_order_relaxed);
    b.v[gl_LocalInvocationID.x & 63u] = _42[(gl_LocalInvocationID.x + 1u) % {n}u] + _7;
}}
'''
def call(src):
    o = ctypes.c_void_p(); nb = ctypes.c_uint32(); err = ctypes.create_string_buffer(256)
    rc = f(src.encode(), 27, ctypes.byref(o), ctypes.byref(nb), err, 256)
    out = ctypes.cast(o, ctypes.c_char_p).value.decode() if o.value else None
    if o.value: fr(o)
    return rc, out, nb.value, err.value.decode()

big = kernel(9220)
rc, out, nb, _ = call(big)
ck(f'① 超限 uint[9220]：返回 1（实 {rc}）、每线程组 36880 字节（实 {nb}）', rc == 1 and nb == 36880)
ok = out is not None
ck('① 入口多溢出缓冲 [[buffer(27)]]、线程组数参数', ok and 'device uchar* s2a_spill [[buffer(27)]]' in out and '[[threadgroups_per_grid]]' in out)
ck('① 数组改成溢出缓冲上的 device 引用、原子转型改 device、屏障带 mem_device',
   ok and 'device spvUnsafeArray<uint, 9220>& _42 = *reinterpret_cast<device spvUnsafeArray<uint, 9220>*>(s2a_spill + s2a_spill_base + 0ul);' in out
   and '(device atomic_uint*)&_42[' in out and 'threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup)' in out and 'threadgroup spvUnsafeArray<uint, 9220> _42;' not in out)
with tempfile.TemporaryDirectory() as t:
    p = os.path.join(t, 's.metal'); open(p, 'w').write(out or '')
    r = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', p, '-o', os.path.join(t, 's.air')], capture_output=True, text=True)
    ck(f'① 改写后的 MSL 交 xcrun metal -c 编过（退出 {r.returncode}）' + (f'：{r.stderr.strip()[:160]}' if r.returncode else ''), r.returncode == 0)
rc, out, nb, _ = call(kernel(1024))
ck(f'② 不超限 uint[1024]：返回 0（实 {rc}）、字节 0（实 {nb}）、不出新源码', rc == 0 and nb == 0 and out is None)
rc, out, nb, why = call(kernel(9220, '\n    threadgroup float _99[4];'))
ck(f'③ 超限且有非 spvUnsafeArray 的 threadgroup 声明：返回 -1（实 {rc}）、写明原因（{why[:40]}）', rc == -1 and 'threadgroup' in why and out is None)
# ④ C# 胶水 NxgalSpvCross.SpillFix（dsh_cmp --fn spill_fix，槽号参数照 Dsh.cs SPILL_SLOT 给 27；SPILL_SLOT 本身按源码核）
dsh_src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '../dsh/Dsh.cs'), encoding='utf-8').read()
slot_ok = re.search(r'const uint SPILL_SLOT = 27;', dsh_src) is not None
g = dshfn.batch([('spill_fix', [big, 27]), ('spill_fix', [kernel(1024), 27]), ('spill_fix', [kernel(9220, '\n    threadgroup float _99[4];'), 27])], nxgal=LIB)
(s1, b1), (s0, b0) = g[0].get('ok', ('', -1)), g[1].get('ok', ('', -1))
g_ok = b1 == 36880 and 's2a_spill [[buffer(27)]]' in s1 and b0 == 0 and s0 == kernel(1024) and slot_ok
g_err = g[2].get('err', '').startswith('DshError')
ck(f'④ C# SpillFix：超限 36880 字节（实 {b1}）、不超限原样、认不出抛 DshError（实 {g[2]}）；Dsh.cs SPILL_SLOT = 27（{slot_ok}）', g_ok and g_err)
print(f'{"✓" if not bad else "✗"} t_dmsh_spill：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)

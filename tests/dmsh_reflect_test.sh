#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/* graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py tests/dmsh_reflect_test.sh
# 直连反射的参数块成员解析（S2A.Dsh DshCompiler.Reflect，经 dsh_cmp --fn，约 10 秒）：bash tests/dmsh_reflect_test.sh
# 11-01 dsh 收敛到 C#：出包每键反射由 C# 批量进程做（离线链 dmsh_build.py 的 Python reflect 已删），本单测改测 C# 那份，手写期望不变。
# 10-30 Mario Party Superstars：SPIRV-Cross 给片元着色器同步（interlock）的资源写 [[id(4), raster_order_group(0)]]，旧正则只认 [[id(N)]]，
#   这类成员被静默丢掉——反射只到 id 6（56 字节），Metal 按 9 个成员排 72 字节，着色器往空槽写。期望按构造写死（不跑被测实现推）：
#   ① 合成结构体 6 个成员（id 0–5，其中 id 2 存储缓冲、id 5 图像带 raster_order_group(0)）→ 解出 6 个绑定，arg_id 依次 0..5、名字一一对应；
#      id 2 = 存储缓冲第 1 号（index 1），绑定号 1 的标志位 bit0 = 1 → rw True；id 5 = 图像（kind img）
#   ② 同一行写两个成员（解析认不出的写法）→ 不许静默少一个：报 reflect failed，原因含「2 argument buffer members, 1 parsed」
#   ③ 11-05 文明6（010044500C182000）：句柄在统一缓冲里的缓冲纹理。名字按 Ryujinx TextureHandle 手拆：fp_t_cb1114127_10010000 → slots 0x11000F 低 16 位 = 纹理缓冲 c15
#      = NVN 统一缓冲槽 12，句柄 0x10010000 纹理字 o0 = 0x10010000 & 0x3fff = 0 → 字节 0；vp_t_cb1114127_10030000 同槽 12、o0 = 0；合成 fp_t_cb15_A（类型 0，c15 字 10）
#      texture_buffer<uint> → 槽 12、字节 40。三者都是 kind tbuf_ubo；一组这样的句柄 array<texture_buffer<float>, 4> 宿主没接 → 仍是「?」
# 旧代码反证：① 只解出 4 个（缺 id 2、id 5），② 不报错；③ 修前三者都是「?」、没有 reg / off。
#   ④ 11-07 无人深空（0100853015E86000）人物白色光晕：聚光灯光源表 / 深度重投影三支片元着色器在「句柄在统一缓冲里的图像」上做 MSL 3.1 原生贴图原子
#      （fp_i_cb3_26_r32ui.atomic_fetch_min、fp_i_cb3_28_r32i.atomic_fetch_add）。名字按 Ryujinx TextureHandle 手拆：cb3 → NVN 统一缓冲槽 0，句柄 0x26 / 0x28 类型 0 → 字节 0x98 = 152 / 0xA0 = 160；
#      fp_i_cb5_10_（只写、不做原子）→ 槽 2、字节 64、不标原子；fp_i_cb2_48_r32i（驱动表 cb2 图像槽 0）照旧 img 槽 0、标原子。
#      期望：前两者 (img_ubo, 0, 152|160, True)、(img_ubo, 2, 64, None)、(img, 0, None, True)
#   ⑤ 负向：原子落在解不出槽的成员（fp_i_tcb_10，kind ?）上仍报 reflect failed「not a resolved image binding」（放宽只放 img_ubo，不放任意成员）
#   旧代码反证 ④：报 reflect failed「native texture atomic receiver is not a resolved image binding: fp_i_cb3_26_r32ui」
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
# 缺省解释器不可执行时回退 python3（11-01 审计 P2-48：原先不回退，命令替换为空、四条比较全是「实得空」，假红像反射回归）；两条都没有 = 环境未就绪，退出 75
[ -x "$PY" ] || PY=$(command -v python3) || { echo "dmsh_reflect_test：缺 Python 解释器（${S2A_PY:-$HOME/.s2arm/venv/bin/python3} 不可执行，PATH 里也没有 python3），环境未就绪（退出 75）"; exit 75; }
out=$("$PY" - "$H" 2>&1 <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics/tools/direct/tests')); import dshfn
res = {'sbufs': [{'binding': 0, 'cb_slot': 0, 'cb_offset': 0x510 // 4, 'flags': 0}, {'binding': 1, 'cb_slot': 0, 'cb_offset': 0x520 // 4, 'flags': 1}]}
msl = '''struct spvDescriptorSetBuffer0
{
    constant _10* support_buffer [[id(0)]];
    device _23* fp_s0 [[id(1)]];
    device _23* fp_s1 [[id(2), raster_order_group(0)]];
    texture2d<float> fp_t_tcb_8 [[id(3)]];
    sampler fp_t_tcb_8Smplr [[id(4)]];
    texture2d<float, access::write> fp_i_cb2_48_ [[id(5), raster_order_group(0)]];
};
'''
bad = msl.replace('    device _23* fp_s0 [[id(1)]];\n    device _23* fp_s1 [[id(2), raster_order_group(0)]];\n', '').replace(
    '    texture2d<float> fp_t_tcb_8 [[id(3)]];\n    sampler fp_t_tcb_8Smplr [[id(4)]];\n    texture2d<float, access::write> fp_i_cb2_48_ [[id(5), raster_order_group(0)]];\n',
    '    texture2d<float> fp_t_tcb_8 [[id(1)]]; sampler fp_t_tcb_8Smplr [[id(2)]];\n').replace('    constant _10* support_buffer [[id(0)]];\n', '')
civ = '''struct spvDescriptorSetBuffer0
{
    texture_buffer<float> fp_t_cb1114127_10010000 [[id(0)]];
    texture_buffer<uint> fp_t_cb15_A [[id(1)]];
    array<texture_buffer<float>, 4> fp_t_cb15_10 [[id(2)]];
};
'''
civ_vs = civ.replace('fp_t_cb1114127_10010000', 'vp_t_cb1114127_10030000')
nms = '''struct spvDescriptorSetBuffer0
{
    texture2d<uint, access::read_write> fp_i_cb3_26_r32ui [[id(0)]];
    texture2d<int, access::read_write> fp_i_cb3_28_r32i [[id(1)]];
    texture2d<float, access::write> fp_i_cb5_10_ [[id(2)]];
    texture2d<int, access::read_write> fp_i_cb2_48_r32i [[id(3)]];
};

fragment void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    uint _1 = spvDescriptorSet0.fp_i_cb3_26_r32ui.atomic_fetch_min(uint2(0u), 5u).x;
    int _2 = spvDescriptorSet0.fp_i_cb3_28_r32i.atomic_fetch_add(uint2(1u), 1).x;
    spvDescriptorSet0.fp_i_cb5_10_.write(float4(1.0), uint2(0u));
    int _3 = spvDescriptorSet0.fp_i_cb2_48_r32i.atomic_fetch_add(uint2(0u), 1).x;
}
'''
unres = '''struct spvDescriptorSetBuffer0
{
    texture2d<uint, access::read_write> fp_i_tcb_10 [[id(0)]];
};

fragment void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    uint _1 = spvDescriptorSet0.fp_i_tcb_10.atomic_fetch_add(uint2(0u), 1u).x;
}
'''
r1, r2, r3, r4, r5, r6 = dshfn.batch([('reflect_detail', ['ps', msl, res]), ('reflect_detail', ['ps', bad, res]), ('reflect_detail', ['ps', civ, {'sbufs': []}]), ('reflect_detail', ['vs', civ_vs, {'sbufs': []}]),
                                      ('reflect_detail', ['ps', nms, {'sbufs': []}]), ('reflect_detail', ['ps', unres, {'sbufs': []}])])
c = r5.get('ok')
print('N', [(e['msl_name'], e.get('kind'), e.get('reg'), e.get('off'), e.get('atomic')) for e in c] if isinstance(c, list) else r5)
v = r6.get('ok')
print('U', f"{v['err']}: {v['detail']}" if isinstance(v, dict) and 'err' in v else f'没报错（{r6}）')
for r in (r3, r4):
    c = r.get('ok')
    print('C', [(e['msl_name'], e.get('kind'), e.get('reg'), e.get('off')) for e in c] if isinstance(c, list) else r)
b = r1.get('ok')
if not isinstance(b, list): print('X ①', r1); b = []
print('A', [(e['arg_id'], e['msl_name']) for e in b])
s1 = [e for e in b if e['msl_name'] == 'fp_s1']; im = [e for e in b if e['msl_name'] == 'fp_i_cb2_48_']
print('S', *((s1[0].get('kind'), s1[0].get('index'), s1[0].get('rw')) if s1 else (None,)))
print('I', im[0].get('kind') if im else None)
v = r2.get('ok')
print('E', f"{v['err']}: {v['detail']}" if isinstance(v, dict) and 'err' in v else f'没报错（{r2}）')
PYEOF
)
want_a="A [(0, 'support_buffer'), (1, 'fp_s0'), (2, 'fp_s1'), (3, 'fp_t_tcb_8'), (4, 'fp_t_tcb_8Smplr'), (5, 'fp_i_cb2_48_')]"
bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1：期望「$3」，实得「$2」"; bad=1; fi; }
ck "① 带 raster_order_group 的成员照样解出，6 个绑定 arg_id 0..5" "$(grep '^A ' <<< "$out")" "$want_a"
ck "① id 2 = 存储缓冲第 1 号、可写" "$(grep '^S ' <<< "$out")" "S sbuf 1 True"
ck "① id 5 = 图像" "$(grep '^I ' <<< "$out")" "I img"
e=$(grep '^E ' <<< "$out")
ck "② 一行两个成员：报 reflect failed、原因含成员数与解出数" "$( [[ "$e" == "E reflect failed: "*"2 argument buffer members, 1 parsed"* ]] && echo 是 || echo "${e#E }")" "是"
c=$(grep '^C ' <<< "$out")
ck "③ 文明6 片元：统一缓冲里的缓冲纹理 → tbuf_ubo 槽 12 字节 0 / 40，数组仍 ?" "$(sed -n 1p <<< "$c")" "C [('fp_t_cb1114127_10010000', 'tbuf_ubo', 12, 0), ('fp_t_cb15_A', 'tbuf_ubo', 12, 40), ('fp_t_cb15_10', '?', None, None)]"
ck "③ 文明6 顶点：vp_t_cb1114127_10030000 → tbuf_ubo 槽 12 字节 0" "$(sed -n 2p <<< "$c" | cut -d')' -f1))" "C [('vp_t_cb1114127_10030000', 'tbuf_ubo', 12, 0)"
ck "④ 无人深空：句柄在统一缓冲里的图像做原生原子 → img_ubo 槽 0 字节 152 / 160 标原子；只写的 img_ubo 不标；图像槽的照旧" "$(grep '^N ' <<< "$out")" "N [('fp_i_cb3_26_r32ui', 'img_ubo', 0, 152, True), ('fp_i_cb3_28_r32i', 'img_ubo', 0, 160, True), ('fp_i_cb5_10_', 'img_ubo', 2, 64, None), ('fp_i_cb2_48_r32i', 'img', 0, None, True)]"
u=$(grep '^U ' <<< "$out")
ck "⑤ 原子落在解不出槽的成员上：仍报 reflect failed「not a resolved image binding」" "$( [[ "$u" == "U reflect failed: native texture atomic receiver is not a resolved image binding: fp_i_tcb_10" ]] && echo 是 || echo "${u#U }")" "是"
[ $bad = 0 ] && { echo "✓ dmsh_reflect_test：8 项全通"; exit 0; }
echo "$out" | head -20; echo "✗ dmsh_reflect_test：8 项有不通"; exit 1

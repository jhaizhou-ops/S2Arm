#!/usr/bin/env python3
# 门禁手动：辅助脚本（用例生成器），给 tessref 双后端对拍生成 SPIR-V 用例（要传输出目录），本身不是单测
# 曲面细分双后端对拍用例（tessref）：按用例表生成 TCS / TES 的 SPIR-V（顶点 / 片元共用），spirv-as 汇编到 <输出目录>/<用例>/{vs,tcs,tes,fs}.spv，并写 cases.tsv。
# 用法：gen_cases.py <输出目录>
# 着色器：顶点照抄属性 0；TCS 照抄控制点、细分因子为常数；TES 位置 = 四边形双线性 / 三角形重心插值，再按 b = 16·u(1-u)·v(1-v)（三角形 27·u·v·w）沿 x 鼓起 0.1·b，
#   颜色 = (u², v², b, 1)——都不是 (u, v) 的线性函数，像素值与轮廓随细分出的顶点位置变，细分图案不同就能比出来（只用线性颜色时任何三角化都画出同一张图）；片元输出颜色。
import os, subprocess, sys
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
# 名、域、分区、外因子 4 个、内因子 2 个、是否剔背面
CASES = [
    ('quad_int4', 'Quads', 'SpacingEqual', (4, 4, 4, 4), (4, 4), 0),
    ('quad_int_asym', 'Quads', 'SpacingEqual', (1, 2, 3, 4), (5, 6), 0),
    ('quad_fodd', 'Quads', 'SpacingFractionalOdd', (3.3, 5.7, 2.2, 7.9), (4.4, 6.6), 0),
    ('quad_feven', 'Quads', 'SpacingFractionalEven', (3.3, 5.7, 2.2, 7.9), (4.4, 6.6), 0),
    ('tri_int', 'Triangles', 'SpacingEqual', (3, 4, 5, 0), (6, 0), 0),
    ('tri_fodd', 'Triangles', 'SpacingFractionalOdd', (2.5, 3.5, 6.5, 0), (4.5, 0), 0),
    ('quad_cullback', 'Quads', 'SpacingEqual', (3, 3, 3, 3), (3, 3), 1),   # 剔背面 + 正面 CCW（GAL）：两边都应照常画
    ('quad_cullfront', 'Quads', 'SpacingEqual', (3, 3, 3, 3), (3, 3), 2),  # 剔正面：两边都应全被剔（绕序语义一致的反证）
]
VS = '''OpCapability Shader
OpMemoryModel Logical GLSL450
OpEntryPoint Vertex %main "main" %inpos %outv %pv
OpDecorate %inpos Location 0
OpDecorate %outv Location 0
OpMemberDecorate %PV 0 BuiltIn Position
OpMemberDecorate %PV 1 BuiltIn PointSize
OpDecorate %PV Block
%void = OpTypeVoid
%fnv = OpTypeFunction %void
%f32 = OpTypeFloat 32
%v4 = OpTypeVector %f32 4
%i32 = OpTypeInt 32 1
%c0 = OpConstant %i32 0
%PV = OpTypeStruct %v4 %f32
%ptrPV = OpTypePointer Output %PV
%ptrIv4 = OpTypePointer Input %v4
%ptrOv4 = OpTypePointer Output %v4
%pv = OpVariable %ptrPV Output
%inpos = OpVariable %ptrIv4 Input
%outv = OpVariable %ptrOv4 Output
%main = OpFunction %void None %fnv
%l = OpLabel
%p = OpLoad %v4 %inpos
OpStore %outv %p
%pp = OpAccessChain %ptrOv4 %pv %c0
OpStore %pp %p
OpReturn
OpFunctionEnd
'''
FS = '''OpCapability Shader
OpMemoryModel Logical GLSL450
OpEntryPoint Fragment %main "main" %inc %outc
OpExecutionMode %main OriginUpperLeft
OpDecorate %inc Location 0
OpDecorate %outc Location 0
%void = OpTypeVoid
%fnv = OpTypeFunction %void
%f32 = OpTypeFloat 32
%v4 = OpTypeVector %f32 4
%pIv4 = OpTypePointer Input %v4
%pOv4 = OpTypePointer Output %v4
%inc = OpVariable %pIv4 Input
%outc = OpVariable %pOv4 Output
%main = OpFunction %void None %fnv
%l = OpLabel
%c = OpLoad %v4 %inc
OpStore %outc %c
OpReturn
OpFunctionEnd
'''
def tcs(dom, sp, o, i):
    n = 4 if dom == 'Quads' else 3
    st = ''.join(f'%o{k} = OpAccessChain %pOf %tlo %c{k}\nOpStore %o{k} %fo{k}\n' for k in range(4)) + ''.join(f'%n{k} = OpAccessChain %pOf %tli %c{k}\nOpStore %n{k} %fi{k}\n' for k in range(2))
    consts = ''.join(f'%fo{k} = OpConstant %f32 {float(o[k])}\n' for k in range(4)) + ''.join(f'%fi{k} = OpConstant %f32 {float(i[k])}\n' for k in range(2))
    return f'''OpCapability Tessellation
OpMemoryModel Logical GLSL450
OpEntryPoint TessellationControl %main "main" %inv %outv %id %tlo %tli
OpExecutionMode %main OutputVertices {n}
OpExecutionMode %main {dom}
OpExecutionMode %main {sp}
OpExecutionMode %main VertexOrderCw
OpDecorate %inv Location 0
OpDecorate %outv Location 0
OpDecorate %id BuiltIn InvocationId
OpDecorate %tlo BuiltIn TessLevelOuter
OpDecorate %tlo Patch
OpDecorate %tli BuiltIn TessLevelInner
OpDecorate %tli Patch
%void = OpTypeVoid
%fnv = OpTypeFunction %void
%f32 = OpTypeFloat 32
%v4 = OpTypeVector %f32 4
%i32 = OpTypeInt 32 1
%u32 = OpTypeInt 32 0
%u32c = OpConstant %u32 32
%un = OpConstant %u32 {n}
%u4 = OpConstant %u32 4
%u2 = OpConstant %u32 2
%c0 = OpConstant %i32 0
%c1 = OpConstant %i32 1
%c2 = OpConstant %i32 2
%c3 = OpConstant %i32 3
{consts}%arrIn = OpTypeArray %v4 %u32c
%arrOut = OpTypeArray %v4 %un
%arr4 = OpTypeArray %f32 %u4
%arr2 = OpTypeArray %f32 %u2
%pArrIn = OpTypePointer Input %arrIn
%pArrOut = OpTypePointer Output %arrOut
%pArr4 = OpTypePointer Output %arr4
%pArr2 = OpTypePointer Output %arr2
%pIv4 = OpTypePointer Input %v4
%pOv4 = OpTypePointer Output %v4
%pIi = OpTypePointer Input %i32
%pOf = OpTypePointer Output %f32
%inv = OpVariable %pArrIn Input
%outv = OpVariable %pArrOut Output
%id = OpVariable %pIi Input
%tlo = OpVariable %pArr4 Output
%tli = OpVariable %pArr2 Output
%main = OpFunction %void None %fnv
%l = OpLabel
%i = OpLoad %i32 %id
%src = OpAccessChain %pIv4 %inv %i
%v = OpLoad %v4 %src
%dst = OpAccessChain %pOv4 %outv %i
OpStore %dst %v
{st}OpReturn
OpFunctionEnd
'''
def tes(dom, sp):
    if dom == 'Quads':
        body = '''%d01 = OpFSub %v4 %p1 %p0
%s01 = OpVectorTimesScalar %v4 %d01 %u
%e0 = OpFAdd %v4 %p0 %s01
%d32 = OpFSub %v4 %p2 %p3
%s32 = OpVectorTimesScalar %v4 %d32 %u
%e1 = OpFAdd %v4 %p3 %s32
%de = OpFSub %v4 %e1 %e0
%se = OpVectorTimesScalar %v4 %de %w
%pos = OpFAdd %v4 %e0 %se
'''
    else:
        body = '''%q0 = OpVectorTimesScalar %v4 %p0 %u
%q1 = OpVectorTimesScalar %v4 %p1 %w
%q2 = OpVectorTimesScalar %v4 %p2 %z
%q01 = OpFAdd %v4 %q0 %q1
%pos = OpFAdd %v4 %q01 %q2
'''
    bulge = ('%t1 = OpFMul %f32 %u %om_u\n%t2 = OpFMul %f32 %w %om_w\n%t3 = OpFMul %f32 %t1 %t2\n%b = OpFMul %f32 %t3 %f16\n' if dom == 'Quads'
             else '%t1 = OpFMul %f32 %u %w\n%t3 = OpFMul %f32 %t1 %z\n%b = OpFMul %f32 %t3 %f27\n')
    return f'''OpCapability Tessellation
OpMemoryModel Logical GLSL450
OpEntryPoint TessellationEvaluation %main "main" %inv %tc %pv %outc
OpExecutionMode %main {dom}
OpExecutionMode %main {sp}
OpExecutionMode %main VertexOrderCw
OpDecorate %inv Location 0
OpDecorate %tc BuiltIn TessCoord
OpDecorate %outc Location 0
OpMemberDecorate %PV 0 BuiltIn Position
OpMemberDecorate %PV 1 BuiltIn PointSize
OpDecorate %PV Block
%void = OpTypeVoid
%fnv = OpTypeFunction %void
%f32 = OpTypeFloat 32
%v3 = OpTypeVector %f32 3
%v4 = OpTypeVector %f32 4
%i32 = OpTypeInt 32 1
%u32 = OpTypeInt 32 0
%u32c = OpConstant %u32 32
%c0 = OpConstant %i32 0
%c1 = OpConstant %i32 1
%c2 = OpConstant %i32 2
%c3 = OpConstant %i32 3
%f1 = OpConstant %f32 1
%f01 = OpConstant %f32 0.1
%f16 = OpConstant %f32 16
%f27 = OpConstant %f32 27
%arrIn = OpTypeArray %v4 %u32c
%pArrIn = OpTypePointer Input %arrIn
%pIv4 = OpTypePointer Input %v4
%pIv3 = OpTypePointer Input %v3
%pOv4 = OpTypePointer Output %v4
%PV = OpTypeStruct %v4 %f32
%pPV = OpTypePointer Output %PV
%inv = OpVariable %pArrIn Input
%tc = OpVariable %pIv3 Input
%pv = OpVariable %pPV Output
%outc = OpVariable %pOv4 Output
%main = OpFunction %void None %fnv
%l = OpLabel
%t = OpLoad %v3 %tc
%u = OpCompositeExtract %f32 %t 0
%w = OpCompositeExtract %f32 %t 1
%z = OpCompositeExtract %f32 %t 2
%a0 = OpAccessChain %pIv4 %inv %c0
%p0 = OpLoad %v4 %a0
%a1 = OpAccessChain %pIv4 %inv %c1
%p1 = OpLoad %v4 %a1
%a2 = OpAccessChain %pIv4 %inv %c2
%p2 = OpLoad %v4 %a2
%a3 = OpAccessChain %pIv4 %inv %c{3 if dom == 'Quads' else 2}
%p3 = OpLoad %v4 %a3
{body}%om_u = OpFSub %f32 %f1 %u
%om_w = OpFSub %f32 %f1 %w
{bulge}%bx = OpFMul %f32 %b %f01
%px = OpCompositeExtract %f32 %pos 0
%px2 = OpFAdd %f32 %px %bx
%pos2 = OpCompositeInsert %v4 %px2 %pos 0
%pp = OpAccessChain %pOv4 %pv %c0
OpStore %pp %pos2
%uu = OpFMul %f32 %u %u
%ww = OpFMul %f32 %w %w
%col = OpCompositeConstruct %v4 %uu %ww %b %f1
OpStore %outc %col
OpReturn
OpFunctionEnd
'''
def asm(text, path):
    src = path + 'asm'; open(src, 'w').write(text)
    subprocess.run(['spirv-as', '--target-env', 'vulkan1.0', src, '-o', path], check=True)
    subprocess.run(['spirv-val', '--target-env', 'vulkan1.0', path], check=True)
with open(os.path.join(out, 'cases.tsv'), 'w') as tsv:
    for name, dom, sp, o, i, cull in CASES:
        d = os.path.join(out, name); os.makedirs(d, exist_ok=True)
        asm(VS, os.path.join(d, 'vs.spv')); asm(FS, os.path.join(d, 'fs.spv'))
        asm(tcs(dom, sp, o, i), os.path.join(d, 'tcs.spv')); asm(tes(dom, sp), os.path.join(d, 'tes.spv'))
        tsv.write(f'{name}\t{4 if dom == "Quads" else 3}\t{cull}\n')
print(f'tessref 用例 {len(CASES)} 个 → {out}')

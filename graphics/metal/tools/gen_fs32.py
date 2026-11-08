#!/usr/bin/env python3
# 生成两支片元着色器（spvasm）：32 个 vec4 用户输入（位置 0–31），一支只读位置 0–3 求和，一支 32 个全读求和。输出到 graphics/metal/tests/
import os
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tests')
def gen(nread, name):
    L = [f'; t_prog 片元输入上限（Apple GPU 片元最多 124 个输入分量）：声明 32 个 vec4 输入，读其中 {nread} 个求和写出。由 tools/gen_fs32.py 生成',
         '               OpCapability Shader', '               OpMemoryModel Logical GLSL450',
         '               OpEntryPoint Fragment %main "main" ' + ' '.join(f'%in{i}' for i in range(32)) + ' %out',
         '               OpExecutionMode %main OriginUpperLeft']
    L += [f'               OpDecorate %in{i} Location {i}' for i in range(32)] + ['               OpDecorate %out Location 0']
    L += ['       %void = OpTypeVoid', '         %fn = OpTypeFunction %void', '      %float = OpTypeFloat 32', '         %v4 = OpTypeVector %float 4',
          '       %pin = OpTypePointer Input %v4', '      %pout = OpTypePointer Output %v4']
    L += [f'       %in{i} = OpVariable %pin Input' for i in range(32)] + ['        %out = OpVariable %pout Output',
          '       %main = OpFunction %void None %fn', '      %entry = OpLabel']
    L += [f'         %l{i} = OpLoad %v4 %in{i}' for i in range(nread)]
    acc = '%l0'
    for i in range(1, nread): L.append(f'         %s{i} = OpFAdd %v4 {acc} %l{i}'); acc = f'%s{i}'
    L += [f'               OpStore %out {acc}', '               OpReturn', '               OpFunctionEnd', '']
    open(os.path.join(D, name), 'w').write('\n'.join(L))
gen(4, 't_prog_fs32r4.spvasm'); gen(32, 't_prog_fs32r32.spvasm'); print('ok')

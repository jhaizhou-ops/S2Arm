#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#1590 严格执行实际发射的 IR：超宽移位直接失败（含 select 的未选分支）。
外层按 AGENTS 经过 mem_admit；默认 dshfn 编当前源码，DSH_CMP_DLL 可指定旧 DLL 负控。
CPU 检查不代替 cases.py 的 Mac GPU 读回。
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / 'graphics/tools/direct/tests'))
import dshfn


def main():
    shader_dir = Path(dshfn.dll()).resolve().parent
    env = {**os.environ, 'DOTNET_PROCESSOR_COUNT': '1', 'S2A_CPU_GATE': '1'}
    with tempfile.TemporaryDirectory(prefix='shf_ir_') as tmp:
        out = Path(tmp) / 'bin'
        cmd = [dshfn.dotnet(), 'build', str(HERE.parents[1] / 'tests/ampere_isa/shf_ir.csproj'), '-c', 'Release', '-m:1',
               '-nodeReuse:false', '-p:BuildInParallel=false', '-p:UseSharedCompilation=false',
               '-p:ShaderDir=' + str(shader_dir), '-p:BaseIntermediateOutputPath=' + str(Path(tmp) / 'obj') + '/',
               '-o', str(out), '-v:q']
        subprocess.run(cmd, env=env, check=True, timeout=120)
        return subprocess.run([dshfn.dotnet(), str(out / 'dsh_cmp.dll')], env=env, timeout=60).returncode


if __name__ == '__main__':
    sys.exit(main())

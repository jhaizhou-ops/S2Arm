#!/usr/bin/env python3
# 门禁手动：要传参数：--dependencies 已离线构建的 GAL/Vulkan 托管依赖 DLL 目录（门禁机没有固定的依赖目录）+ --gpu-source / --output；验收是十连约 15 分钟，见 android/tests/gate_not_default.tsv；CPU 部分 Control.Tests.csproj 已由 tests/vulkan_backend_test.sh 门禁跑
"""Compile actual GPU sources and Runtime against controlled platform boundaries, offline."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dotnet', required=True, type=Path)
parser.add_argument('--dependencies', required=True, type=Path)
parser.add_argument('--gpu-source', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--fifo-source', type=Path)
parser.add_argument('--admission-probe', action='store_true', help='Instrument the accepted/pre-publication boundary only in the isolated copy')
parser.add_argument('--runtime-source', type=Path, default=Path(__file__).resolve().parents[1] / 'AndroidVulkanRuntime.cs')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
src = out / 'gpu-source'
shutil.copytree(args.gpu_source, src, ignore=shutil.ignore_patterns('bin', 'obj'))
if args.fifo_source:
    shutil.copy2(args.fifo_source, src / 'Engine/GPFifo/GPFifoDevice.cs')
shutil.copy2(args.runtime_source, out / 'AndroidVulkanRuntime.cs')
if args.admission_probe:
    runtime = out / 'AndroidVulkanRuntime.cs'
    source = runtime.read_text()
    marker = '            change = new BackingChange {'
    if source.count(marker) != 1:
        raise SystemExit('Admission boundary changed; inspect before probing.')
    source = source.replace(marker, '            RuntimeChecks.AdmissionProbe(); // isolated test-only scheduling probe\n' + marker)
    runtime.write_text(source)

(out / 'input-sha256.json').write_text(json.dumps({str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in sorted(out.rglob('*.cs'))}, indent=2) + '\n')
config = out / 'NuGet.Config'
config.write_text('<configuration><packageSources><clear /></packageSources></configuration>')
project = ET.Element('Project', Sdk='Microsoft.NET.Sdk')
props = ET.SubElement(project, 'PropertyGroup')
for name, value in {'TargetFramework': 'net10.0', 'AssemblyName': 'Ryujinx.Graphics.Gpu',
                    'AllowUnsafeBlocks': 'true', 'LangVersion': 'preview', 'EnableDefaultCompileItems': 'false'}.items():
    ET.SubElement(props, name).text = value
items = ET.SubElement(project, 'ItemGroup')
ET.SubElement(items, 'Compile', Include=str(src / '**/*.cs'))
for name in ['Ryujinx.Cpu', 'Ryujinx.Graphics.Device', 'Ryujinx.Graphics.GAL', 'Ryujinx.Common',
             'Ryujinx.Graphics.Texture', 'Ryujinx.Graphics.Shader', 'Ryujinx.Memory',
             'Microsoft.IO.RecyclableMemoryStream', 'Ryujinx.Graphics.Vulkan']:
    dep = args.dependencies / (name + '.dll')
    if not dep.is_file():
        raise SystemExit('Missing actual dependency: ' + str(dep))
    ET.SubElement(items, 'Reference', Include=str(dep))
producer = out / 'Gpu.csproj'
ET.ElementTree(project).write(producer, encoding='unicode')

def run(command, log, env=None):
    with (out / log).open('w') as stream:
        result = subprocess.run([str(arg) for arg in command], stdout=stream, stderr=subprocess.STDOUT, timeout=150, env=env)
    if result.returncode:
        print((out / log).read_text())
        raise SystemExit(result.returncode)

run([args.dotnet, 'build', producer, '--configfile', config, '-v:q'], 'gpu-build.log')
gpu = out / 'bin/Debug/net10.0/Ryujinx.Graphics.Gpu.dll'
run([args.dotnet, 'build', Path(__file__).with_name('Control.Tests.csproj'), '--configfile', config, '-v:q',
     '-p:ArtifactsPath=' + str(out / 'tests'), '-p:GpuAssembly=' + str(gpu),
     '-p:RuntimeSource=' + str(out / 'AndroidVulkanRuntime.cs'), '-p:Dependencies=' + str(args.dependencies)], 'consumer-build.log')
# Build the complete production lease and native authority for managed contract tests.
libdir = out / 'native'; libdir.mkdir()
suffix = '.dylib' if platform.system() == 'Darwin' else '.so'
native = Path(__file__).resolve().parents[4] / 'android/native'
run([os.environ.get('CC', 'cc'), '-shared', '-fPIC', '-pthread', '-std=gnu11',
     '-I' + str(native), Path(__file__).with_name('backing_test.c'),
     '-o', libdir / ('libs2a_backing_test' + suffix)], 'native-build.log')
run([os.environ.get('CC', 'cc'), '-shared', '-fPIC', Path(__file__).with_name('capacity_stub.c'),
     '-o', libdir / ('libs2arm_android' + suffix)], 'capacity-stub-build.log')
test_inputs = list(Path(__file__).parent.glob('*.cs')) + [Path(__file__).with_name('backing_test.c'), Path(__file__).with_name('capacity_stub.c'),
    runtime/'wsi_lease.c', runtime/'wsi_lease.h', runtime/'backing_wait.h',
    native.parent/'core-link/runtime-tests/writers-gate/backing_test.h']
(out/'test-input-sha256.json').write_text(json.dumps({str(p.resolve()):hashlib.sha256(p.read_bytes()).hexdigest() for p in test_inputs},indent=2)+'\n')
for key in ['LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH']:
    os.environ[key] = str(libdir) + (':' + os.environ[key] if os.environ.get(key) else '')
run([args.dotnet, out / 'tests/bin/Control.Tests/debug/Control.Tests.dll'], 'test.log',
    dict(os.environ, S2A_TEST_ADMISSION_PROBE='1') if args.admission_probe else None)
print((out / 'test.log').read_text(), end='')

#!/usr/bin/env python3
# 门禁手动：要传参数：--assemblies 预构建 Ryujinx.Common / GAL / Silk.NET.Core / Silk.NET.Vulkan DLL 目录（门禁机没有固定路径）
"""Exercise exact AndroidWindow create/poll methods with real lease/retirement consumers.

Only driver observations and the existing lease ABI producer are controlled. No
Android UI, Vulkan driver, GPU, or device is exercised. Builds are offline/private.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--wsi', required=True, type=Path)
parser.add_argument('--assemblies', required=True, type=Path)
parser.add_argument('--dotnet', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--case', action='append', default=[])
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
source_path = args.wsi / 'AndroidWindow.cs'
source = source_path.read_text()

def block(marker):
    if source.count(marker) != 1:
        raise ValueError('Production boundary changed: ' + marker)
    start = source.index(marker)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

markers = ('public AndroidWindow(', 'public void Poll()', 'private bool IsComplete(',
           'private void LogRetirement(', 'private void ReportStartup(',
           'private void ObserveAcquire(', 'private void ReportRetirement(',
           'private void ReportPending(', 'private bool CollectCompleted(',
           'private static void WriteDiagnostic(', 'private void CreateSwapchain()',
           'private void DestroyChain(', 'private void WarnDeferredResources()', 'private void ReleaseDeferredPresentResources()', 'public void Stop()')
methods = '\n'.join(block(marker) for marker in markers)
state_start = source.index('    private static string StateDescription(')
methods += '\n' + source[state_start:source.index('\n\n', state_start)]
# Include future private viewport methods without maintaining a second algorithm.
for marker in ('private bool ViewportReady(', 'private void ReportViewport(', 'private static Extent2D ViewportExtent('):
    if marker in source:
        methods += '\n' + block(marker)
prefix = source[:source.index('    public AndroidWindow(')]
prefix = prefix.replace(' : WindowBase', '').replace('using Ryujinx.Graphics.Vulkan;\n', '')
fixture = Path(__file__).with_name('ViewportLifecycleFixture.cs.in')
start = source.index('_renderer.SurfaceApi.GetPhysicalDeviceSurfaceCapabilities(_physical, _host.Surface, out var now).ThrowOnError();')
start = source.index('\n', start) + 1
suboptimal = source[start:source.index('            if (extentChanged)', start)]
(out / 'Program.cs').write_text(prefix + methods + '\n' + fixture.read_text().replace('SUBOPTIMAL_GEOMETRY', suboptimal))
(out / 'ProductionMethods.inc').write_text(methods)
for name in ('NativeLease.cs', 'RetirementLedger.cs', 'ForegroundBudget.cs'):
    shutil.copyfile(args.wsi / name, out / name)
references = ''.join('<Reference Include="' + str((args.assemblies / name).resolve()) + '" />'
                     for name in ('Ryujinx.Common.dll', 'Ryujinx.Graphics.GAL.dll', 'Silk.NET.Core.dll', 'Silk.NET.Vulkan.dll'))
(out / 'Proof.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
    '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>'
    '<AllowUnsafeBlocks>true</AllowUnsafeBlocks><Nullable>annotations</Nullable>'
    '<TreatWarningsAsErrors>true</TreatWarningsAsErrors><NoWarn>CS0649;CS0414;CS0169</NoWarn>'
    '</PropertyGroup><ItemGroup>' + references + '</ItemGroup></Project>')
(out / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
paths = [source_path, args.wsi / 'NativeLease.cs', args.wsi / 'RetirementLedger.cs', args.wsi / 'ForegroundBudget.cs', fixture, Path(__file__)]
(out / 'sources.json').write_text(json.dumps({str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, indent=2) + '\n')
results = []
for command, log in [([str(args.dotnet), 'build', str(out / 'Proof.csproj'), '--configfile', str(out / 'NuGet.Config'), '-v:q'], 'build.log'),
                     ([str(args.dotnet), str(out / 'bin/Debug/net10.0/Proof.dll'), *args.case], 'tests.log')]:
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (out / log).write_text(result.stdout + result.stderr)
    results.append({'command': command, 'exit': result.returncode, 'log': log})
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(result.stdout + result.stderr, end='')
    if result.returncode:
        raise SystemExit(result.returncode)

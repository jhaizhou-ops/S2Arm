#!/usr/bin/env python3
"""Run actual Present/Poll and lease/retirement bookkeeping with controlled Vulkan observations.

The C# NativeLease ABI consumer is real; its producer and Vulkan boundary are controlled.
No native C lease, Vulkan device, Android surface, guest memory or game is exercised. Extracted
methods fail closed if their source boundary changes; no completion algorithm is
maintained in the fixture. All outputs and the offline build stay in --output.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--android-window', required=True, type=Path)
parser.add_argument('--ledger', required=True, type=Path)
parser.add_argument('--native-lease', required=True, type=Path)
parser.add_argument('--mode', default='all')
parser.add_argument('--dotnet', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
source = args.android_window.read_text()


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


methods = '\n'.join(block(marker) for marker in (
    'public void Poll()', 'private bool IsComplete(', 'private void LogRetirement(',
    'private void ReportStartup(', 'private void ObserveAcquire(',
    'private void ReportRetirement(', 'private void ReportPending(',
    'private bool CollectCompleted(', 'private static void WriteDiagnostic(',
    'private void DestroyChain(', 'private void WarnDeferredResources()', 'private void ReleaseDeferredPresentResources()', 'public void Stop()', 'public override void Present(', 'private void Transition('))
methods = methods.replace(block('public void Poll()'), block('public void Poll()').replace('Environment.TickCount64', 'TestClock.Now'))
if 'private static Extent2D ViewportExtent(' in source:
    methods += '\n' + block('private static Extent2D ViewportExtent(')
state_start = source.index('    private static string StateDescription(')
state_end = source.index('\n\n', state_start)
methods += '\n' + source[state_start:state_end]
fixture = Path(__file__).with_name('StopAfterAcquireFixture.cs.in')
text = fixture.read_text().replace('PENDING_BODY', block('private sealed class Pending'))
text = text.replace('CHAIN_BODY', block('private sealed class Chain'))
text = text.replace('PRODUCTION_METHODS', methods)
summary_start = source.index('    public string RetirementSummary =>')
summary_end = source.index(';', summary_start) + 1
text = text.replace('SUMMARY_PROPERTY', source[summary_start:summary_end])
(out / 'Program.cs').write_text(text)
shutil.copyfile(args.ledger, out / 'RetirementLedger.cs')
shutil.copyfile(args.native_lease, out / 'NativeLease.cs')
# Present 取图等待用 ForegroundBudget；与被测 AndroidWindow.cs 同目录才有意义（冻结旧源时没有它）。
budget = args.android_window.parent / 'ForegroundBudget.cs'
if budget.exists():
    shutil.copyfile(budget, out / 'ForegroundBudget.cs')
# #1574 F7：出图适配几何拆在 AndroidPresentFit.cs（Present() 调它）；同目录才有意义（冻结旧源时没有它）。
#   夹具在同名命名空间里自备 ImageCrop 桩，抄时剥掉 GAL using（真源里 ImageCrop 从 Ryujinx.Graphics.GAL 来，桩里没有 Ryujinx）。
fit = args.android_window.parent / 'AndroidPresentFit.cs'
if fit.exists():
    (out / 'AndroidPresentFit.cs').write_text(fit.read_text().replace('using Ryujinx.Graphics.GAL;\n', ''))
(out / 'ProductionMethods.inc').write_text(methods)
(out / 'Proof.csproj').write_text(
    '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
    '<TargetFramework>net10.0</TargetFramework><AllowUnsafeBlocks>true</AllowUnsafeBlocks>'
    '<Nullable>annotations</Nullable><TreatWarningsAsErrors>true</TreatWarningsAsErrors><NoWarn>CS0649</NoWarn>'
    '</PropertyGroup></Project>')
(out / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
paths = [args.android_window, args.ledger, args.native_lease, fixture, Path(__file__)]
if budget.exists():
    paths.append(budget)
if fit.exists():
    paths.append(fit)
(out / 'sources.json').write_text(json.dumps({str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
                                            for p in paths}, indent=2) + '\n')
modes = ['normal','stop-before','timeout-stop','stop-after','focus','revision','revoke','revoke-early','revoke-early-prior','old-present','no-fence','same-image','pool-pending','submit-failure','device-lost','acquire-out-of-date','acquire-surface-lost','acquire-device-lost','present-out-of-date','present-surface-lost','present-device-lost','present-mixed-unknown','present-unknown-mixed','present-out-of-date-nofence','present-nofence-stamp-two','present-nofence-revoke','present-nofence-surface-lost','present-fence-never-imported','present-nofence-queue-error','present-nofence-device-lost','present-nofence-graveyard','present-fence-foreground-grace','present-fence-graveyard','present-fence-background-revoke','acquire-bg-freeze','acquire-epoch-reset'] if args.mode == 'all' else [args.mode]
results = []
for command, log in [([str(args.dotnet), 'build', str(out / 'Proof.csproj'), '--configfile', str(out / 'NuGet.Config'), '-v:q'], 'build.log')] + [([str(args.dotnet), str(out / 'bin/Debug/net10.0/Proof.dll'), mode], mode+'.log') for mode in modes]:
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (out / log).write_text(result.stdout + result.stderr)
    results.append({'command': command, 'exit': result.returncode, 'log': log})
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(result.stdout + result.stderr, end='')
    if result.returncode:
        raise SystemExit(result.returncode)

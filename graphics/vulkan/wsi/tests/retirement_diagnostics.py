#!/usr/bin/env python3
"""Run exact WSI retirement methods with controlled lease/driver observations.

No Vulkan device, native lease ABI, Android surface or game is exercised. Extracted
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
    'private void DestroyChain(', 'private void WarnDeferredResources()', 'public void Stop()'))
state_start = source.index('    private static string StateDescription(')
state_end = source.index('\n\n', state_start)
methods += '\n' + source[state_start:state_end]
fixture = Path(__file__).with_name('RetirementDiagnosticsFixture.cs.in')
text = fixture.read_text().replace('PENDING_BODY', block('private sealed class Pending'))
text = text.replace('CHAIN_BODY', block('private sealed class Chain'))
text = text.replace('PRODUCTION_METHODS', methods)
(out / 'Program.cs').write_text(text)
shutil.copyfile(args.ledger, out / 'RetirementLedger.cs')
shutil.copyfile(args.android_window.parent / 'ForegroundBudget.cs', out / 'ForegroundBudget.cs')
(out / 'ProductionMethods.inc').write_text(methods)
(out / 'Proof.csproj').write_text(
    '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
    '<TargetFramework>net10.0</TargetFramework><AllowUnsafeBlocks>true</AllowUnsafeBlocks>'
    '<Nullable>annotations</Nullable><TreatWarningsAsErrors>true</TreatWarningsAsErrors>'
    '</PropertyGroup></Project>')
(out / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
paths = [args.android_window, args.ledger, fixture, Path(__file__)]
(out / 'sources.json').write_text(json.dumps({str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
                                            for p in paths}, indent=2) + '\n')
results = []
for command, log in [([str(args.dotnet), 'build', str(out / 'Proof.csproj'), '--configfile', str(out / 'NuGet.Config'), '-v:q'], 'build.log'),
                     ([str(args.dotnet), str(out / 'bin/Debug/net10.0/Proof.dll')], 'tests.log')]:
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (out / log).write_text(result.stdout + result.stderr)
    results.append({'command': command, 'exit': result.returncode, 'log': log})
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(result.stdout + result.stderr, end='')
    if result.returncode:
        raise SystemExit(result.returncode)

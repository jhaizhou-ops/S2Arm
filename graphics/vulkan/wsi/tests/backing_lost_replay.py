#!/usr/bin/env python3
"""Exercise the production fence method with deterministic Vulkan/sink failures."""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[4]
source = (root / 'graphics/vulkan/wsi/AndroidVulkanSurface.cs').read_text()
start = source.index('    public void CompletePendingCommands(')
end = source.index('    private void AttachMarkerFailure(', start)
method = source[start:end]
if len(sys.argv) > 2 and sys.argv[2] == '--negative':
    hook = '                    try { S2AGsDiag.DumpLost(); }'
    if method.count(hook) != 1:
        raise RuntimeError('expected one production replay hook')
    method = method.replace(hook, '                    try { }', 1)
out = pathlib.Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=False)
(out / 'Fixture.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup><ItemGroup><Compile Include="Program.cs"/><Compile Include="'''+str(root / 'compat/tree/src/Ryujinx.Common/S2AGsDiag.cs')+'''"/><Compile Include="'''+str(root / 'compat/tree/src/Ryujinx.Graphics.Vulkan/S2AFrameTrace.cs')+'''"/></ItemGroup></Project>''')
(out / 'Program.cs').write_text('''using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using Ryujinx.Common;
using Ryujinx.Graphics.Vulkan;
enum Result { Success, Timeout, ErrorDeviceLost }
struct Fence { }
class FenceHolder { public Fence Get() => new(); public void Put() { } }
class CommandBufferScoped { public FenceHolder GetFence() => new(); }
class Pool { public CommandBufferScoped Rent() => new(); public void Return(CommandBufferScoped marker) { } }
class Renderer { public Pool CommandBufferPool = new(); public void FlushAllCommands() { } }
class Api { public Result result; public Result WaitForFences(object d, int n, in Fence f, bool all, ulong timeout) => result; }
class Boundary {
    private Renderer _renderer = new(); private Api _api = new(); private object _device = new(); private long _markerSequence;
    private void AttachMarkerFailure(Exception e, long id, CommandBufferScoped marker, Fence f, Result result, long a, long b, int ms) { e.Data["marker"] = result; }
'''+method+'''
    public static void Main() {
        S2AGsDiag.S2ATestReset(); S2AGsDiag.s_gateOpen = () => true;
        Environment.SetEnvironmentVariable("S2A_GS_DIAG", "1");
        var lines = new List<string>(); S2AGsDiag.s_emit = lines.Add;
        S2AGsDiag.NoteAtomic("ssbo", -1, 0, 16); S2AGsDiag.Submit(3); lines.Clear();
        var b = new Boundary(); b.CompletePendingCommands(1);
        if (lines.Count != 0) throw new Exception("success emitted replay");
        foreach (var r in new[]{Result.Timeout, Result.ErrorDeviceLost}) {
            b._api.result = r;
            try { b.CompletePendingCommands(1); throw new Exception("failure was ignored"); }
            catch (InvalidOperationException e) {
                if (!e.Message.Contains(r.ToString()) || !Equals(e.Data["marker"], r)) throw;
            }
            if (r == Result.Timeout && lines.Count != 0) throw new Exception("timeout emitted replay");
            if (r == Result.ErrorDeviceLost && (lines.Count != 2 || !lines[0].Contains("崩前回放") || !lines[1].Contains("ssbo:0x0+0x10"))) throw new Exception("device lost did not replay recorded zero VA");
        }
        S2AGsDiag.s_emit = _ => throw new Exception("sink failed");
        try { b.CompletePendingCommands(1); throw new Exception("failure was ignored"); }
        catch (InvalidOperationException e) { if (!e.Message.Contains("ErrorDeviceLost") || !Equals(e.Data["marker"], Result.ErrorDeviceLost)) throw; }
        Console.WriteLine("PASS: success/timeout quiet, lost replays zero VA, failing sink preserves marker failure");
    }
}''')
subprocess.run(['dotnet', 'run', '--project', str(out / 'Fixture.csproj'),
                '-p:BuildInParallel=false', '-p:NuGetAudit=false', '--'], check=True)

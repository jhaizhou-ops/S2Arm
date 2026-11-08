#!/usr/bin/env python3
"""Compile exact H06 production methods with minimal fixtures; no restore/network.

Uses the installed .NET SDK compiler/reference pack directly. This is a focused
source-method regression, not the full service/native/Apple platform gate.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dotnet', required=True, type=Path)
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--revision', help='Read production sources from this Git revision (negative control)')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
out = args.out.resolve()
if out == repo or repo in out.parents:
    parser.error('--out must be outside the repository')
out.mkdir(parents=True, exist_ok=True)

def source(path):
    if args.revision:
        return subprocess.check_output(['git', '-C', str(repo), 'show', args.revision + ':' + path], text=True)
    return (repo / path).read_text()

prefix = 'compat/tree/src/Ryujinx.HLE/'
bsd = prefix + 'HOS/Services/Sockets/Bsd/'
client = source(bsd + 'IClient.cs')
start = client.index('        public ResultCode Select(ServiceCtx context)')
end = client.index('        [CommandCmif(', start)
select = client[start:end]
managed = source(bsd + 'Impl/ManagedSocket.cs')
returns = []
for method in ('RecvMMsg', 'SendMMsg'):
    start = managed.index('public LinuxError ' + method + '(')
    following = managed.find('\n        public ', start + 10)
    section = managed[start:following if following >= 0 else len(managed)]
    statements = re.findall(r'return WinSockHelper\.\w+\([^;]*socketError[^;]*;', section)
    if len(statements) != 1:
        raise RuntimeError('Expected one production SocketError return in ' + method)
    returns.append('public static LinuxError ' + method + '(SocketError socketError) { ' + statements[0] + ' }')

support = r'''
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Net.Sockets;
using Ryujinx.Memory;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types;

namespace Ryujinx.HLE.HOS.Services.Sockets.Bsd {
    interface IFileDescriptor : IDisposable { int Refcount { get; set; } }
    interface ISocket : IFileDescriptor { LinuxError Shutdown(BsdSocketShutdownFlags how); }
}
namespace Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl {
    class EventFileDescriptor : IFileDescriptor {
        public int Refcount { get; set; } = 1;
        public void Dispose() { }
    }
    class ManagedSocket : ISocket {
        public object Socket = new object();
        public int Refcount { get; set; } = 1;
        public void Dispose() { }
        public LinuxError Shutdown(BsdSocketShutdownFlags how) => LinuxError.SUCCESS;
    }
}
namespace Proxy { class OfflineSocket { } }
namespace Ryujinx.Memory {
    sealed class WritableRegion : IDisposable {
        public Memory<byte> Memory;
        public WritableRegion(Memory<byte> memory) { Memory = memory; }
        public void Dispose() { }
    }
}
[Flags] enum PollEventTypeMask { Input = 1, Output = 2, Error = 4 }
class PollEventData { public PollEventTypeMask InputEvents, OutputEvents; }
class PollEvent { public PollEventData Data; public IFileDescriptor FileDescriptor;
    public PollEvent(PollEventData data, IFileDescriptor file) { Data = data; FileDescriptor = file; } }
class PollManager {
    public bool Ready = true;
    public bool IsCompatible(PollEvent e) => e.FileDescriptor != null;
    public void Select(List<PollEvent> events, int timeout, out int updated) {
        updated = 0;
        foreach (var e in events) if (Ready) { e.Data.OutputEvents = e.Data.InputEvents; updated++; }
    }
}
static class S2ABsdWake { public static long Version => 0; public static void Wait(long v, int ms) { } }
static class S2AShutdown { public static bool Requested => false; }
enum ResultCode { Success }
class FixtureMemory {
    public byte[] Bytes = new byte[48];
    public ReadOnlySpan<byte> GetSpan(ulong address, int size) => Bytes.AsSpan((int)address, size);
    public WritableRegion GetWritableRegion(ulong address, int size) => new WritableRegion(Bytes.AsMemory((int)address, size));
}
class FixtureRequest {
    public (ulong, ulong) GetBufferType0x21(int i) => ((ulong)(i * 8), 2);
    public (ulong, ulong) GetBufferType0x22(int i) => ((ulong)(24 + i * 8), 2);
}
class ServiceCtx {
    public FixtureMemory Memory = new(); public FixtureRequest Request = new(); public BinaryReader RequestData;
    public int ReturnValue; public LinuxError Error;
    public ServiceCtx(int count) {
        var stream = new MemoryStream(); var writer = new BinaryWriter(stream);
        writer.Write(count); writer.Write(0); writer.Write((long)0); writer.Write((long)0); writer.Write(false);
        stream.Position = 0; RequestData = new BinaryReader(stream);
    }
}
class ClientHarness {
    readonly BsdContext _context; readonly List<PollManager> _pollManagers;
    public ClientHarness(BsdContext context, bool ready) { _context = context; _pollManagers = [new PollManager { Ready = ready }]; }
    static ResultCode WriteBsdResult(ServiceCtx c, int value, LinuxError error = LinuxError.SUCCESS) {
        c.ReturnValue = value; c.Error = error; return ResultCode.Success;
    }
@@SELECT@@
}
static class ManagedReturns { @@RETURNS@@ }
static class Program {
    static int count, failures;
    static void Check(string name, Action test) {
        count++;
        try { test(); Console.WriteLine("PASS " + name); }
        catch (Exception e) { failures++; Console.WriteLine("FAIL " + name + ": " + e.Message); }
    }
    static void Expect(bool condition, string why) { if (!condition) throw new Exception(why); }
    static int Main() {
        ulong pid = 100;
        foreach (var test in new (string Name, ushort Read, ushort Write, ushort Error, int Nfds, bool Ready, LinuxError Errno, int Result)[] {
            ("closed-read", 2, 0, 0, 8, true, LinuxError.EBADF, -1),
            ("closed-write", 0, 2, 0, 8, true, LinuxError.EBADF, -1),
            ("closed-error", 0, 0, 2, 8, true, LinuxError.EBADF, -1),
            ("mixed-valid-closed", 3, 0, 0, 8, true, LinuxError.EBADF, -1),
            ("unregistered", 128, 0, 0, 8, true, LinuxError.EBADF, -1),
            ("empty", 0, 0, 0, 0, true, LinuxError.SUCCESS, 0),
            ("valid-ready", 1, 0, 0, 8, true, LinuxError.SUCCESS, 1),
            ("valid-not-ready", 1, 0, 0, 8, false, LinuxError.SUCCESS, 0),
            ("zero-read-bits", 2, 0, 0, 0, true, LinuxError.SUCCESS, 0),
            ("zero-write-bits", 0, 2, 0, 0, true, LinuxError.SUCCESS, 0),
            ("zero-error-bits", 0, 0, 0x8000, 0, true, LinuxError.SUCCESS, 0),
            ("zero-valid-bits", 1, 0, 0, 0, true, LinuxError.SUCCESS, 0),
            ("beyond-read-limit", 2, 0, 0, 1, true, LinuxError.SUCCESS, 0),
            ("beyond-write-limit", 0, 2, 0, 1, true, LinuxError.SUCCESS, 0),
            ("beyond-error-limit", 0, 0, 2, 1, true, LinuxError.SUCCESS, 0),
            ("mixed-valid-higher", 3, 0, 0, 1, true, LinuxError.SUCCESS, 1),
            ("partial-byte-seven", 128, 0, 0, 7, true, LinuxError.SUCCESS, 0),
            ("at-eight", 128, 0, 0, 8, true, LinuxError.EBADF, -1),
            ("next-byte-ignored", 0x100, 0, 0, 8, true, LinuxError.SUCCESS, 0),
            ("at-nine", 0x100, 0, 0, 9, true, LinuxError.EBADF, -1),
            ("above-nine", 0x200, 0, 0, 9, true, LinuxError.SUCCESS, 0),
            ("mixed-next-byte", 0x201, 0, 0, 9, true, LinuxError.SUCCESS, 1),
            ("negative", 0, 0, 0, -1, true, LinuxError.EINVAL, -1),
            ("min-int", 0, 0, 0, int.MinValue, true, LinuxError.EINVAL, -1),
            ("max-int-invalid", 0x8000, 0, 0, int.MaxValue, true, LinuxError.EBADF, -1),
            ("max-int-empty", 0, 0, 0, int.MaxValue, true, LinuxError.SUCCESS, 0) }) {
            Check("select/" + test.Name, () => {
                using var context = BsdContext.GetOrRegister(pid++);
                context.RegisterFileDescriptor(new EventFileDescriptor());
                int closed = context.RegisterFileDescriptor(new EventFileDescriptor()); context.CloseFileDescriptor(closed);
                var request = new ServiceCtx(test.Nfds);
                ushort[] masks = [test.Read, test.Write, test.Error];
                for (int i = 0; i < masks.Length; i++) {
                    request.Memory.Bytes[i * 8] = (byte)masks[i];
                    request.Memory.Bytes[i * 8 + 1] = (byte)(masks[i] >> 8);
                }
                if (test.Errno != LinuxError.SUCCESS) Array.Fill(request.Memory.Bytes, (byte)0xa5, 24, 24);
                new ClientHarness(context, test.Ready).Select(request);
                Expect(request.Error == test.Errno && request.ReturnValue == test.Result,
                    "wrong BSD result " + request.ReturnValue + "/" + request.Error);
                if (test.Errno != LinuxError.SUCCESS) Expect(request.Memory.Bytes.Skip(24).All(x => x == 0xa5), "failed select modified output masks");
                if (test.Name is "valid-ready" or "mixed-valid-higher" or "mixed-next-byte")
                    Expect(request.Memory.Bytes[24] == 1 && request.Memory.Bytes[25] == 0, "ready mask includes missing or out-of-range fd");
            });
        }
        Check("select/default-helper-caller-unchanged", () => {
            using var context = BsdContext.GetOrRegister(pid++);
            context.RegisterFileDescriptor(new EventFileDescriptor());
            int closed = context.RegisterFileDescriptor(new EventFileDescriptor()); context.CloseFileDescriptor(closed);
            var descriptors = context.RetrieveFileDescriptorsFromMask(new byte[] { 2 });
            Expect(descriptors.Count == 1 && descriptors[0] == null, "default helper silently filtered a closed fd");
        });
        var errors = new[] { (SocketError.Success, LinuxError.SUCCESS), (SocketError.WouldBlock, LinuxError.EWOULDBLOCK),
            (SocketError.Interrupted, LinuxError.EINTR), (SocketError.ConnectionReset, LinuxError.ECONNRESET),
            (SocketError.ConnectionRefused, LinuxError.ECONNREFUSED), (SocketError.TimedOut, LinuxError.ETIMEDOUT),
            (SocketError.NetworkUnreachable, LinuxError.ENETUNREACH), (SocketError.HostUnreachable, LinuxError.EHOSTUNREACH),
            ((SocketError)123456, (LinuxError)123456) };
        foreach (var error in errors) {
            Check("socket/recv/" + error.Item1, () => Expect(ManagedReturns.RecvMMsg(error.Item1) == error.Item2, "wrong enum errno"));
            Check("socket/send/" + error.Item1, () => Expect(ManagedReturns.SendMMsg(error.Item1) == error.Item2, "wrong enum errno"));
        }
        if (OperatingSystem.IsMacOS()) Check("socket/native-apple-errno-preserved", () =>
            Expect(WinSockHelper.ConvertError((WsaError)35) == LinuxError.EWOULDBLOCK, "native Apple errno conversion changed"));
        Console.WriteLine($"TOTAL {count} FAIL {failures}");
        return failures == 0 ? 0 : 1;
    }
}
'''
program = support.replace('@@SELECT@@', select).replace('@@RETURNS@@', '\n'.join(returns))
(out / 'Harness.cs').write_text(program)
files = [out / 'Harness.cs']
for path in [bsd+'BsdContext.cs', bsd+'Impl/WinSockHelper.cs', bsd+'Impl/WSAError.cs',
             bsd+'Types/LinuxError.cs', bsd+'Types/BsdSocketOption.cs', bsd+'Types/BsdSocketShutdownFlags.cs',
             ]:
    copied = out / Path(path).name
    copied.write_text(source(path))
    files.append(copied)
dotnet = args.dotnet.resolve()
def versions(p):
    return sorted([x for x in p.iterdir() if x.is_dir() and re.fullmatch(r'10(\.\d+)+', x.name)],
                  key=lambda x: tuple(map(int, x.name.split('.'))))
sdks = versions(dotnet.parent / 'sdk')
refpacks = versions(dotnet.parent / 'packs/Microsoft.NETCore.App.Ref')
if not sdks or not refpacks:
    raise SystemExit('Installed .NET10 SDK/reference pack required; no install attempted')
sdk, refpack = sdks[-1], refpacks[-1]
refdir = refpack / 'ref/net10.0'
refs = sorted(refdir.glob('*.dll'))
if not refs or not (sdk / 'Roslyn/bincore/csc.dll').is_file():
    raise SystemExit('Installed .NET10 compiler/reference pack required; no install attempted')
(out / 'refs.rsp').write_text('\n'.join('-r:"' + str(x) + '"' for x in refs) + '\n')
assembly = out / 'H06.Tests.dll'
subprocess.run([str(dotnet), str(sdk / 'Roslyn/bincore/csc.dll'), '-nologo', '-noconfig', '-nostdlib+',
                '-langversion:preview', '-target:exe', '-out:' + str(assembly), '@' + str(out / 'refs.rsp'),
                *map(str, files)], check=True)
(out / 'H06.Tests.runtimeconfig.json').write_text(json.dumps({'runtimeOptions': {
    'tfm': 'net10.0', 'framework': {'name': 'Microsoft.NETCore.App', 'version': refpack.name}}}) + '\n')
print('Production revision:', args.revision or 'working tree', flush=True)
raise SystemExit(subprocess.run([str(dotnet), str(assembly)]).returncode)

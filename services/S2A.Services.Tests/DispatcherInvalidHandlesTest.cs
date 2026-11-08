// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Kernel.Common;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Services;
using System;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;

namespace S2A.Services.Tests
{
    static unsafe class DispatcherInvalidHandlesTest
    {
        const uint ProcessHandle = 0xFFFF8001;
        const uint Invalid = 0x12345678;
        const uint Unsupported = 0x60001;
        const uint EventRead = 0x60002;
        const uint EventWrite = 0x60003;
        const uint Transfer = 0x60004;
        static int _retains, _releases;
        static int Get(uint h, uint* kind, ulong* cookie)
        {
            *cookie = 19;
            *kind = (uint)(h switch
            {
                ProcessHandle => ObjKind.Process, Unsupported => ObjKind.Session,
                EventRead => ObjKind.EventR, EventWrite => ObjKind.EventW,
                Transfer => ObjKind.Tmem, _ => ObjKind.None,
            });
            return h == Invalid || h == 0 ? 0 : 1;
        }
        static void Retain(ulong cookie) => _retains++;
        static void Release(ulong cookie) => _releases++;
        static int Tmem(uint h, ulong* addr, ulong* size, uint* perm)
        {
            *addr = 0x8000; *size = 0x1000; *perm = 3;
            return 1;
        }

        sealed class CountingService : IpcService
        {
            public int Calls;
            public bool ObjectsValid;
            [CommandCmif(0)]
            public ResultCode Execute(ServiceCtx ctx)
            {
                Calls++;
                var desc = ctx.Request.HandleDesc;
                ObjectsValid = desc == null || desc.ToCopy.Concat(desc.ToMove).All(h =>
                    h == 0 || ctx.Process.HandleTable.GetObject<KAutoObject>(h) != null);
                return ResultCode.Success;
            }
        }

        static int Active(KHandleTable table) => (int)typeof(KHandleTable)
            .GetField("_activeSlotsCount", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(table)!;

        // Component fixture, not Host.Boot: real process and handle table, real HIPC
        // parser and HLE dispatcher. No scheduler, GPU, system assets or guest execution.
        [SoloTest("--dispatcher-invalid-handles-isolated")]
        public static int Run()
        {
            var d = (Dispatcher)RuntimeHelpers.GetUninitializedObject(typeof(Dispatcher));
            var device = (Switch)RuntimeHelpers.GetUninitializedObject(typeof(Switch));
            var configuration = (HleConfiguration)RuntimeHelpers.GetUninitializedObject(typeof(HleConfiguration));
            typeof(Switch).GetField("<Configuration>k__BackingField", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(device, configuration);
            typeof(Dispatcher).GetField("<Device>k__BackingField", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(d, device);
            var server = new KProcess(null);
            var game = new KProcess(null);
            server.HandleTable.Initialize(32);
            game.HandleTable.Initialize(1);
            foreach (var entry in new[] { ("ServerProcess", server), ("GameProcess", game) })
                typeof(Dispatcher).GetField($"<{entry.Item1}>k__BackingField", BindingFlags.NonPublic | BindingFlags.Instance)!
                    .SetValue(d, entry.Item2);
            var service = new CountingService();
            var target = new HleTarget(service);
            var get = Native.HandleGet;
            var retain = Native.EventRetain;
            var release = Native.EventRelease;
            var tmem = Native.TmemGet;
            bool strict = Red.Strict;
            int cases = 0, failures = 0;
            int[] existing = [];
            try
            {
                Native.HandleGet = &Get; Native.EventRetain = &Retain;
                Native.EventRelease = &Release; Native.TmemGet = &Tmem;
                // Expected invalid input must return a kernel error, not terminate the fixture.
                Red.Strict = false;
                void Case(string name, uint[] copy, uint[] move, uint expected, int? retainExpected = null)
                {
                    cases++;
                    byte* buffer = stackalloc byte[0x100];
                    var msg = Msg.Cmif(0);
                    msg.Copy.AddRange(copy); msg.Move.AddRange(move); msg.Write(buffer);
                    byte[] original = new ReadOnlySpan<byte>(buffer, 0x100).ToArray();
                    int before = Active(server.HandleTable), calls = service.Calls;
                    _retains = _releases = 0;
                    uint actual = target.Process(d, buffer, 0x100);
                    var desc = Dispatcher.ThreadStreams.Request.HandleDesc;
                    bool rejected = expected != 0;
                    bool untouched = !rejected || original.AsSpan().SequenceEqual(new ReadOnlySpan<byte>(buffer, 0x100));
                    bool descriptors = !rejected || (desc.ToCopy.SequenceEqual(copy.Select(h => (int)h)) && desc.ToMove.SequenceEqual(move.Select(h => (int)h)));
                    bool noLeak = !rejected || (Active(server.HandleTable) == before && _retains == _releases);
                    bool originals = existing.All(h => ReferenceEquals(server.HandleTable.GetObject<KAutoObject>(h), game));
                    bool references = retainExpected == null || (_retains == retainExpected && _releases == retainExpected);
                    bool ok = originals && references && actual == expected && service.Calls == calls + (rejected ? 0 : 1) &&
                        untouched && descriptors && noLeak && (rejected || service.ObjectsValid);
                    Console.WriteLine($"{name}: expected rc=0x{expected:X}/calls+{(rejected ? 0 : 1)}; actual rc=0x{actual:X}/calls+{service.Calls - calls}, buffer={untouched}, descriptors={descriptors}, rollback={noLeak}, originalHandles={originals}, retains/releases={_retains}/{_releases}: {(ok ? "PASS" : "FAIL")}");
                    if (!ok) failures++;
                    // Both old and new successful translations leave owned shadow handles.
                    // Close only actual objects, never the original foreign descriptor values.
                    if (desc != null)
                        foreach (int h in desc.ToCopy.Concat(desc.ToMove))
                            if (h != 0 && server.HandleTable.GetObject<KAutoObject>(h) != null) server.HandleTable.CloseHandle(h);
                }
                // Independent kernel expectation: module 1, description 114 => 0xE401.
                Case("invalid copy", [Invalid], [], 0xE401);
                Case("invalid move", [], [Invalid], 0xE401);
                Case("unsupported copy", [Unsupported], [], 0xE401);
                Case("unsupported move", [], [Unsupported], 0xE401);
                Case("valid then invalid copy", [ProcessHandle, Invalid], [], 0xE401);
                Case("copy then invalid move", [ProcessHandle], [Invalid], 0xE401);
                Case("retained event then invalid", [EventRead, Invalid], [], 0xE401);
                Case("retained write event then unsupported", [EventWrite], [Unsupported], 0xE401);
                Case("no handles", [], [], 0);
                Case("explicit null handles", [0], [0], 0);
                Case("valid process", [ProcessHandle], [], 0);
                Case("valid supported types", [EventRead, EventWrite, Transfer], [], 0);
                Case("valid move remains supported", [], [ProcessHandle], 0);
                existing = new int[31];
                for (int i = 0; i < existing.Length; i++)
                    if (server.HandleTable.GenerateHandle(game, out existing[i]).IsFailure)
                        throw new InvalidOperationException("Could not prepare 31 of 32 table slots.");
                // Module 1, description 105: do not turn allocation failure into a null handle.
                Case("one remaining slot / second event allocation fails", [EventRead, EventWrite], [], 0xD201, 2);
                foreach (int h in existing) server.HandleTable.CloseHandle(h);
            }
            finally
            {
                Native.HandleGet = get; Native.EventRetain = retain;
                Native.EventRelease = release; Native.TmemGet = tmem; Red.Strict = strict;
                server.HandleTable.Destroy(); game.HandleTable.Destroy();
                Dispatcher.ResetThread();
            }
            Console.WriteLine($"Dispatcher actual HLE component: {cases} cases, {failures} failures; not Host.Boot, native concurrency, device or game validation.");
            return failures == 0 && cases == 14 ? 0 : 1;
        }
    }
}

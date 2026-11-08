// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel.Common;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;

namespace S2A.Services.Tests
{
    // 审计 #1534 P1-52：HLE 服务应答里的句柄翻译失败，游戏不能收到成功。
    // 期望值按 Horizon 内核语义直接写（不跑被测实现）：应答句柄翻译失败时 svcSendSyncRequest 回内核结果——
    //   无效 / 不支持的对象 = InvalidHandle（模块 1、描述 114 → 0xE401），游戏侧句柄表满 = HandleTableFull（描述 105 → 0xD201）；
    //   本次已发给游戏的新句柄全部收回；move 句柄无论成败都从服务端表移除（上游 KServerSession.Reply 失败后其余 move 句柄 CloseHandle）。
    static unsafe class DispatcherResponseHandlesTest
    {
        static int _news, _dups, _closes;
        static bool _fullTable;
        static readonly Dictionary<uint, (uint Kind, ulong Cookie)> _live = new();
        static uint _next = 0x7000;
        static Dispatcher _d;
        static uint New(uint kind, ulong cookie) { if (_fullTable) return 0; _news++; _live.Add(++_next, (kind, cookie)); return _next; }
        static uint Dup(ulong ev) { if (_fullTable) return 0; _dups++; _live.Add(++_next, ((uint)ObjKind.EventR, ev)); return _next; }
        // 同原生 close_handle：关会话句柄回调 Dispatcher.HandleClosed（会话从表里移除）
        static int Close(uint h)
        {
            _closes++;
            if (!_live.Remove(h, out var o)) return 0;
            if (o.Kind == (uint)ObjKind.Session) _d.HandleClosed(o.Kind, o.Cookie);
            return 1;
        }

        sealed class ReplyService : IpcService
        {
            public int[] Copy = [], Move = [];
            [CommandCmif(0)]
            public ResultCode Execute(ServiceCtx ctx)
            {
                ctx.Response.HandleDesc = new IpcHandleDesc(Copy, Move);
                return ResultCode.Success;
            }
        }

        static void Set(object o, string field, object v) =>
            o.GetType().GetField($"<{field}>k__BackingField", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(o, v);

        // 同 DispatcherInvalidHandlesTest 的组件夹具：真实影子句柄表、HIPC 解析与 HLE 分发；原生句柄函数是计数替身
        [SoloTest("--dispatcher-response-handles")]
        public static int Run()
        {
            var d = (Dispatcher)RuntimeHelpers.GetUninitializedObject(typeof(Dispatcher));
            var device = (Switch)RuntimeHelpers.GetUninitializedObject(typeof(Switch));
            Set(device, "Configuration", RuntimeHelpers.GetUninitializedObject(typeof(HleConfiguration)));
            Set(d, "Device", device);
            var server = new KProcess(null);
            var game = new KProcess(null);
            server.HandleTable.Initialize(32);
            game.HandleTable.Initialize(1);
            Set(d, "ServerProcess", server);
            Set(d, "GameProcess", game);
            foreach ((string f, object v) in new (string, object)[] { ("_sessionLock", new object()), ("_sessions", new SessionTarget[16]) })
                typeof(Dispatcher).GetField(f, BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(d, v);
            _d = d;
            var service = new ReplyService();
            var target = new HleTarget(service);
            var hNew = Native.HandleNew; var hClose = Native.HandleClose; var dup = Native.EventDupRead;
            bool strict = Red.Strict;
            int cases = 0, failures = 0;
            try
            {
                Native.HandleNew = &New; Native.HandleClose = &Close; Native.EventDupRead = &Dup;
                Red.Strict = false;   // 预期的红行不终止本测
                // 已绑定原生事件的读端（走 EventDupRead，不进托管调度器）
                int Event() { var ev = new KEvent(null); ev.ReadableEvent.S2ANativeEvent = 0x99; server.HandleTable.GenerateHandle(ev.ReadableEvent, out int h); return h; }
                // 服务 MakeObject 出的子会话：先进会话表，影子对象落服务端表（同 Dispatcher.MakeSessionHook）
                var sessions = new List<ulong>();
                int Session() { ulong c = d.AddSession(new HleTarget(new ReplyService())); sessions.Add(c); server.HandleTable.GenerateHandle(new S2ASessionObject(null, c), out int h); return h; }
                int Unsupported() { server.HandleTable.GenerateHandle(game, out int h); return h; }
                const int Invalid = 0x7777;
                void Case(string name, Func<int>[] copy, Func<int>[] move, uint expected, bool full = false)
                {
                    cases++;
                    int sessionsBefore = sessions.Count;
                    service.Copy = copy.Select(f => f()).ToArray();
                    service.Move = move.Select(f => f()).ToArray();
                    int[] moved = service.Move.Where(h => h != Invalid).ToArray();
                    _news = _dups = _closes = 0; _live.Clear(); _fullTable = full;
                    byte* buffer = stackalloc byte[0x100];
                    Msg.Cmif(0).Write(buffer);
                    uint actual = target.Process(d, buffer, 0x100);
                    uint* w = (uint*)buffer;
                    bool ok;
                    string detail;
                    // move 的影子句柄都要被移出服务端表（成功：交给了游戏；失败：同上游移交失败也关掉）
                    bool movedGone = moved.All(h => server.HandleTable.GetObject<KAutoObject>(h) == null);
                    // 本例 move 出去的会话：成功时还在会话表（游戏拿着）；失败时同上游「移交失败的会话句柄被关」从表里移除
                    int sessionsLive = sessions.Skip(sessionsBefore).Count(c => d.GetSession(c) != null);
                    int sessionsMade = sessions.Count - sessionsBefore;
                    if (expected != 0)
                    {
                        // 失败：本次发给游戏的新原生句柄全部收回，游戏手里不留半份
                        ok = actual == expected && _live.Count == 0 && movedGone && sessionsLive == 0;
                        detail = $"rc=0x{actual:X}、新发 {_news + _dups} 收回 {_closes} 留给游戏 {_live.Count}、move 影子已移出 {movedGone}、会话残留 {sessionsLive}/{sessionsMade}";
                    }
                    else
                    {
                        int copies = (w[1] >> 31) != 0 ? (int)((w[2] >> 1) & 0xF) : 0, moves = (w[1] >> 31) != 0 ? (int)((w[2] >> 5) & 0xF) : 0;
                        uint[] given = Enumerable.Range(0, copies + moves).Select(i => w[3 + i]).Where(h => h != 0).ToArray();
                        bool fresh = given.All(h => _live.ContainsKey(h)) && _live.Count == given.Length;
                        ok = actual == 0 && copies == copy.Length && moves == move.Length && fresh && movedGone && sessionsLive == sessionsMade;
                        detail = $"rc=0x{actual:X}、应答 copy {copies} move {moves}、非零句柄都是新发的原生句柄 {fresh}、move 影子已移出 {movedGone}、会话在表 {sessionsLive}/{sessionsMade}";
                    }
                    Console.WriteLine($"{name}：期望 rc=0x{expected:X} → 实 {detail} {(ok ? "✓" : "✗")}");
                    if (!ok) failures++;
                    foreach (int h in service.Copy) if (h != Invalid && server.HandleTable.GetObject<KAutoObject>(h) != null) server.HandleTable.CloseHandle(h);
                    foreach (int h in moved) if (server.HandleTable.GetObject<KAutoObject>(h) != null) server.HandleTable.CloseHandle(h);
                }
                Case("无效 copy 句柄", [() => Invalid], [], 0xE401);
                Case("无效 move 句柄", [], [() => Invalid], 0xE401);
                Case("不支持的对象 copy", [Unsupported], [], 0xE401);
                Case("不支持的对象 move", [], [Unsupported], 0xE401);
                Case("事件 copy 之后无效 copy（收回已发的那份）", [Event, () => Invalid], [], 0xE401);
                Case("会话 move 之后不支持的 move（收回会话句柄）", [], [Session, Unsupported], 0xE401);
                Case("事件 copy + 不支持的 move", [Event], [Unsupported], 0xE401);
                Case("游戏侧句柄表满（会话 move）", [], [Session], 0xD201, full: true);
                Case("游戏侧句柄表满（事件 copy）", [Event], [], 0xD201, full: true);
                Case("正对照：事件 copy", [Event], [], 0);
                Case("正对照：会话 move", [], [Session], 0);
                Case("正对照：事件 copy + 会话 move", [Event], [Session], 0);
                Case("正对照：空句柄 0", [() => 0], [], 0);
            }
            finally
            {
                Native.HandleNew = hNew; Native.HandleClose = hClose; Native.EventDupRead = dup;
                Red.Strict = strict;
                server.HandleTable.Destroy(); game.HandleTable.Destroy();
                Dispatcher.ResetThread();
            }
            Console.WriteLine($"Dispatcher 应答句柄翻译：{cases} 例，{failures} 不符（组件夹具：真实 HLE 分发 / 影子句柄表，原生句柄为计数替身；非 Host.Boot、非真机）");
            return failures == 0 && cases == 13 ? 0 : 1;
        }

        // Horizon 服务（HorizonHost）应答的复制句柄同一条：事件给游戏另发读端，其余种类回 InvalidHandle，发不出回 HandleTableFull；
        //   失败时本次已发的读端收回、消息里的句柄字不改。直调 HorizonTarget.CopyHandlesOut（不起 Horizon 服务管理器）
        const uint HzEvent = 0x60002, HzSession = 0x60001, HzInvalid = 0x12345678;
        static int HzGet(uint h, uint* kind, ulong* cookie)
        {
            *cookie = 0x99;
            *kind = (uint)(h switch { HzEvent => ObjKind.EventR, HzSession => ObjKind.Session, _ => ObjKind.None });
            return h == HzEvent || h == HzSession ? 1 : 0;
        }

        [SoloTest("--horizon-copy-handles-out")]
        public static int RunHorizon()
        {
            var target = new HorizonTarget("单测", null, 0);
            MethodInfo copyOut = typeof(HorizonTarget).GetMethod("CopyHandlesOut", BindingFlags.NonPublic | BindingFlags.Instance)!;
            var get = Native.HandleGet; var hClose = Native.HandleClose; var dup = Native.EventDupRead;
            bool strict = Red.Strict;
            int cases = 0, failures = 0;
            try
            {
                Native.HandleGet = &HzGet; Native.HandleClose = &Close; Native.EventDupRead = &Dup;
                Red.Strict = false;
                void Case(string name, uint[] copy, uint expected, bool full = false)
                {
                    cases++;
                    _news = _dups = _closes = 0; _live.Clear(); _fullTable = full;
                    byte* buffer = stackalloc byte[0x100];
                    var msg = Msg.Cmif(0); msg.Copy.AddRange(copy); msg.Write(buffer);
                    byte[] original = new ReadOnlySpan<byte>(buffer, 0x100).ToArray();
                    // 修前此函数无返回值（照常回成功给游戏）：按 0 记
                    uint actual = copyOut.Invoke(target, [Pointer.Box(buffer, typeof(byte*))]) is uint u ? u : 0;
                    uint* w = (uint*)buffer;
                    bool ok;
                    string detail;
                    if (expected != 0)
                    {
                        bool untouched = original.AsSpan().SequenceEqual(new ReadOnlySpan<byte>(buffer, 0x100));
                        ok = actual == expected && _live.Count == 0 && untouched;
                        detail = $"rc=0x{actual:X}、新发 {_dups} 收回 {_closes} 留给游戏 {_live.Count}、消息未改 {untouched}";
                    }
                    else
                    {
                        uint[] given = Enumerable.Range(0, copy.Length).Select(i => w[3 + i]).ToArray();
                        bool mapped = given.Zip(copy).All(p => p.Second == HzEvent ? _live.ContainsKey(p.First) : p.First == p.Second);
                        ok = actual == 0 && mapped && _live.Count == copy.Count(h => h == HzEvent);
                        detail = $"rc=0x{actual:X}、事件换成新发读端 / 其余原样 {mapped}、留给游戏 {_live.Count}";
                    }
                    Console.WriteLine($"Horizon {name}：期望 rc=0x{expected:X} → 实 {detail} {(ok ? "✓" : "✗")}");
                    if (!ok) failures++;
                }
                Case("复制事件之后复制不支持的会话", [HzEvent, HzSession], 0xE401);
                Case("复制无效句柄", [HzInvalid], 0xE401);
                Case("复制事件、游戏侧句柄表满", [HzEvent], 0xD201, full: true);
                Case("正对照：复制事件 + 进程伪句柄 + 空句柄", [HzEvent, 0xFFFF8001, 0], 0);
            }
            finally
            {
                Native.HandleGet = get; Native.HandleClose = hClose; Native.EventDupRead = dup;
                Red.Strict = strict;
            }
            Console.WriteLine($"Horizon 应答复制句柄：{cases} 例，{failures} 不符（直调 HorizonTarget.CopyHandlesOut，原生句柄为计数替身；不含 Horizon 服务管理器与真机）");
            return failures == 0 && cases == 4 ? 0 : 1;
        }
    }
}

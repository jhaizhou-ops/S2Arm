// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections.Generic;
using System.Text;
using Ryujinx.Common.Logging;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [SoloTest("--ssl-client-pki-log", Booted = true)]
        private static void SslClientPkiLog()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Regs[1];
            Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
            Reply service = Call(sm, Msg.Cmif(1, Name8("ssl")));
            uint ssl = service.Move.Count == 1 ? service.Move[0] : 0;
            Msg create = Msg.Cmif(0, Bytes(0u, 0UL)); create.SendPid = true;
            Reply created = Call(ssl, create);
            uint context = created.Move.Count == 1 ? created.Move[0] : 0;
            Check("SSL 上下文创建", "0、对象", $"{created.Result}、{(context != 0 ? "对象" : "无")}");
            if (context == 0) return;

            const string secret = "synthetic-pki-secret-7843";
            byte[] password = Encoding.ASCII.GetBytes(secret + "\0");
            byte* cert = FakeNative.Alloc(4);
            byte* pass = FakeNative.Alloc(password.Length);
            password.CopyTo(new Span<byte>(pass, password.Length));
            List<LogEventArgs> events = new();
            void Capture(object sender, LogEventArgs e) { lock (events) events.Add(e); }
            bool wasEnabled = Logger.Stub.HasValue;
            Logger.SetEnable(LogLevel.Stub, true);
            Logger.SetEnable(LogClass.ServiceSsl, true);
            Logger.S2AResetStubHits();
            Logger.Updated += Capture;
            try
            {
                Msg import = Msg.Cmif(5);
                import.A.Add(((ulong)cert, 4));
                import.A.Add(((ulong)pass, (ulong)password.Length));
                Reply reply = Call(context, import);
                Check("SSL 导入调用保持原返回", "0", reply.Result.ToString());
                lock (events)
                {
                    bool hit = events.Exists(e => e.Level == LogLevel.Stub && e.Message.Contains("ImportClientPki"));
                    bool leaked = events.Exists(e => (e.Message + " " + e.Data).Contains(secret));
                    Check("SSL 桩日志确实触发且不含合成口令", "True / False", $"{hit} / {leaked}");
                }
            }
            finally
            {
                Logger.Updated -= Capture;
                Logger.SetEnable(LogLevel.Stub, wasEnabled);
                FakeNative.HandleClose(context); FakeNative.HandleClose(ssl); FakeNative.HandleClose(sm);
            }
        }
    }
}

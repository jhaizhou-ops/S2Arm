// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections.Generic;
using System.Text;
using Ryujinx.Common.Logging;

namespace S2A.Services.Tests
{
    // 审计 P2-223：bsd:u 命令 36（Switch 2 SDK nn::socket::Initialize，入参 u32 套接字配置首字 + pid，应答 u32 非 0 即初始化失败）
    //   原先把配置首字读掉不留痕。宿主没有可按它限制的资源，照旧回 0（改回未实现会让 Pokopia 首帧后失败），但收到的值要打进日志。
    // 期望（手写）：发配置首字 0x00C0FFEE → 结果码 0、应答 u32 0；日志里有一条含「0x00C0FFEE」的 bsd 命令 36 行
    public static unsafe partial class Program
    {
        [SvcCase]
        private static void BsdCmd36ConfigLogged()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint bsd = Call(sm, Msg.Cmif(1, Name8("bsd:u"))).Move[0];
            List<LogEventArgs> events = new();
            void Capture(object sender, LogEventArgs e) { lock (events) events.Add(e); }
            bool wasInfo = Logger.Info.HasValue;
            Logger.SetEnable(LogLevel.Info, true);
            Logger.SetEnable(LogClass.ServiceBsd, true);
            Logger.Updated += Capture;
            try
            {
                Msg m = Msg.Cmif(36, Bytes(0x00C0FFEEu, 0u, 0UL));
                m.SendPid = true;
                Reply r = Call(bsd, m);
                uint ans = *(uint*)r.Data;
                Check("bsd 命令 36：结果码 / 应答（0 = 初始化成功）", "0 / 0", $"{r.Result} / {ans}");
                lock (events)
                {
                    bool hit = events.Exists(e => e.Message.Contains("命令 36") && e.Message.Contains("0x00C0FFEE"));
                    Check("bsd 命令 36：收到的配置首字打进日志", true, hit);
                }
            }
            finally
            {
                Logger.Updated -= Capture;
                Logger.SetEnable(LogLevel.Info, wasInfo);
                FakeNative.HandleClose(bsd);
            }
        }
    }
}

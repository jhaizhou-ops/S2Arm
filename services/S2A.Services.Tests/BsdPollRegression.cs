using System;
using System.Text;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static void BsdPollRegression()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint bsd = Call(sm, Msg.Cmif(1, Name8("bsd:u"))).Move[0];
            Msg reg = Msg.Cmif(0, new byte[0x30]); reg.SendPid = true; reg.Copy.Add(0xFFFF8001); Call(bsd, reg);
            int a = *(int*)Call(bsd, Msg.Cmif(31, Bytes(0u, 0u, 0UL))).Data;
            int b = *(int*)Call(bsd, Msg.Cmif(31, Bytes(0u, 0u, 0UL))).Data;
            byte* count = _game + 0x7800; *(ulong*)count = 1;
            Msg write = Msg.Cmif(24, Bytes(b)); write.A.Add(((ulong)count, 8)); Call(bsd, write);
            byte* input = _game + 0x7900; byte* output = _game + 0x7980;
            *(int*)input = a; *(ushort*)(input + 4) = 1; *(ushort*)(input + 6) = 0x1F;
            *(int*)(input + 8) = b; *(ushort*)(input + 12) = 1; *(ushort*)(input + 14) = 0x1F;
            new Span<byte>(output, 16).Fill(0xAA);
            Msg poll = Msg.Cmif(6, Bytes(2, 0)); poll.A.Add(((ulong)input, 16)); poll.B.Add(((ulong)output, 16));
            int ret = *(int*)Call(bsd, poll).Data;
            Check("bsd Poll 混合就绪：返回数、描述符、请求事件与纯输出 revents", $"1 / {a} / 1 / 0 / {b} / 1 / 1",
                $"{ret} / {*(int*)output} / {*(ushort*)(output + 4)} / {*(ushort*)(output + 6)} / {*(int*)(output + 8)} / {*(ushort*)(output + 12)} / {*(ushort*)(output + 14)}");
            long f = System.Diagnostics.Stopwatch.Frequency;
            Check("bsd Poll 到期后等待 0、不限期才等待 -1", "0 / -1",
                $"{IClient.S2APollWaitMs(1000, 3500, f)} / {IClient.S2APollWaitMs(long.MaxValue, 0, f)}");
            BsdMultiSession(sm, bsd);
            FakeNative.HandleClose(bsd); FakeNative.HandleClose(sm);
        }

        // Switch 2 SDK 按并发数开多条 bsd:u 会话（nn::socket::detail::SetClientSessionCount / CreateClientServiceByHipc），只在一条上 RegisterClient：
        //   其余会话先发命令 36（带 pid）再建套接字，要用本进程那份登记（11-05 时之笛：第二条会话 Socket 空引用 → 游戏 Break 2010-0221）。期望按 HOS 语义手写：
        //   ① 只发过命令 36 的会话 Socket(AF_INET, DGRAM, 0) 回描述符 ≥ 0、errno 0；② 同一描述符在登记会话上 Close 回 0（同一张描述符表）；
        //   ③ 关掉未登记会话后，登记会话照样能建套接字（未登记会话不释放进程的登记）
        private static void BsdMultiSession(uint sm, uint bsd)
        {
            uint bsd2 = Call(sm, Msg.Cmif(1, Name8("bsd:u"))).Move[0];
            Msg init = Msg.Cmif(36, Bytes(0u)); init.SendPid = true; Call(bsd2, init);
            byte* r1 = Call(bsd2, Msg.Cmif(2, Bytes(2, 2, 0))).Data; int fd = *(int*)r1, err = *(int*)(r1 + 4);
            byte* r2 = Call(bsd, Msg.Cmif(26, Bytes(fd))).Data; int closed = *(int*)r2;
            FakeNative.HandleClose(bsd2);
            byte* r3 = Call(bsd, Msg.Cmif(2, Bytes(2, 2, 0))).Data; int fd3 = *(int*)r3;
            Check("bsd 多会话：未登记会话建套接字 ≥0 / errno / 登记会话关它 / 关未登记会话后登记会话再建 ≥0", "True / 0 / 0 / True",
                $"{fd >= 0} / {err} / {closed} / {fd3 >= 0}");
            Call(bsd, Msg.Cmif(26, Bytes(fd3)));
        }
    }
}

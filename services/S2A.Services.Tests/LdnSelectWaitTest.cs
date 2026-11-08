// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu.Proxy;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.Types;
using System;
using System.Net.Sockets;
using System.Text;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // bsd Select 只含 LDN 代理套接字时要等（审计 P1-24）：LDN 套接字和宿主 / 离线套接字同属一个 poll 管理器，Select 原先见「只用一个管理器」
        //   就把超时交给它、立刻跳出；可 LdnProxySocket.Poll 不等、SocketHelpers.Select 只等宿主 / 离线套接字，于是阻塞 select 立即返回 0、客线程空转。
        //   期望按 FreeBSD select 语义：① 没数据，超时 300 ms → 返回 0、耗时 ≥ 280 ms ② 超时 2 秒、100 ms 后对端来包 → 返回 1、读集合含该 fd、1 秒内
        [SoloTest("--ldn-select-wait", Booted = true)]
        private static void LdnSelectWait()
        {
            const uint hostIp = 0x0A720001, guestIp = 0x0A720002;   // 10.114.0.1 房主 / 10.114.0.2 本机
            using LdnProxy proxy = new(new ProxyConfig { ProxyIp = guestIp, ProxySubnetMask = 0xFFFF0000 }, new NullProxyClient(), new RyuLdnProtocol());
            Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy.SocketHelpers.RegisterProxy(proxy);
            try
            {
                Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
                uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
                uint bsd = Call(sm, Msg.Cmif(1, Name8("bsd:u"))).Move[0];
                Msg reg = Msg.Cmif(0, new byte[0x30]); reg.SendPid = true; reg.Copy.Add(0xFFFF8001); Call(bsd, reg);
                int fd = *(int*)Call(bsd, Msg.Cmif(2, Bytes(2, 2, 17))).Data;   // Socket(AF_INET, SOCK_DGRAM, UDP)：登记了 LDN 代理 → LdnProxySocket
                byte* sa = _game + 0x7A00;
                new Span<byte>(sa, 16).Clear(); sa[1] = 2; sa[2] = 0x10; sa[3] = 0x92;   // 0.0.0.0:4242（端口网络序）
                Msg bind = Msg.Cmif(13, Bytes(fd)); bind.A.Add(((ulong)sa, 16)); Call(bsd, bind);
                byte* masks = _game + 0x7000;

                (int Ret, long Ms, bool InSet) Select(long sec, long usec)
                {
                    new Span<byte>(masks, 0x300).Clear();
                    masks[fd / 8] = (byte)(1 << (fd % 8));
                    Msg m = Msg.Cmif(5, Bytes(fd + 1, 0u, sec, usec, 0UL));
                    for (int k = 0; k < 3; k++) m.A.Add(((ulong)(masks + k * 0x80), 0x80));
                    for (int k = 0; k < 3; k++) m.B.Add(((ulong)(masks + 0x180 + k * 0x80), 0x80));
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    int ret = *(int*)Call(bsd, m).Data;
                    return (ret, sw.ElapsedMilliseconds, (masks[0x180 + fd / 8] & (1 << (fd % 8))) != 0);
                }

                var idle = Select(0, 300000);
                byte[] payload = [1, 2, 3];
                var sender = new System.Threading.Thread(() =>
                {
                    System.Threading.Thread.Sleep(100);
                    proxy.HandleData(default, new ProxyDataHeader
                    {
                        Info = new ProxyInfo { SourceIpV4 = hostIp, SourcePort = 4242, DestIpV4 = guestIp, DestPort = 4242, Protocol = ProtocolType.Udp },
                        DataLength = (uint)payload.Length,
                    }, payload);
                });
                sender.Start();
                var woke = Select(2, 0);
                bool joined = sender.Join(3000);
                Check("bsd Select 只含 LDN 套接字：没数据等满 300 ms / 等待中来包即返回（审计 P1-24）",
                    "返回 0、≥280 ms；返回 1、读集合含该 fd、≥80 ms 且 <1000 ms、发包线程结束",
                    $"返回 {idle.Ret}、{(idle.Ms >= 280 ? "≥280" : idle.Ms.ToString())} ms；返回 {woke.Ret}、读集合{(woke.InSet ? "含" : "不含")}该 fd、" +
                    $"{(woke.Ms >= 80 && woke.Ms < 1000 ? "≥80 ms 且 <1000" : woke.Ms.ToString())} ms、发包线程{(joined ? "结束" : "未结束")}");
                FakeNative.HandleClose(bsd); FakeNative.HandleClose(sm);
            }
            finally
            {
                Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy.SocketHelpers.UnregisterProxy();
            }
        }
    }
}

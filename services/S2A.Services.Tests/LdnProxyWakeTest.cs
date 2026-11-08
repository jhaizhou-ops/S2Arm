using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu.Proxy;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.Types;
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private sealed class NullProxyClient : IProxyClient
        {
            public bool SendAsync(byte[] buffer) => true;
        }

        private const uint ProxyHostIp = 0x0A720001, ProxyGuestIp = 0x0A720002;   // 10.114.0.1 房主 / 10.114.0.2 客人

        // 后台线程跑阻塞调用；main 线程过 100 ms 再触发对端事件。返回（调用结果文字、从触发到返回的毫秒数）。线程限 2.5 秒，没回来记「没醒」
        private static (string, long) WakeAfterTrigger(Func<string> blocking, Action trigger)
        {
            string result = "没醒";
            Stopwatch sw = new();
            Thread t = new(() =>
            {
                string r;
                try { r = blocking(); }
                catch (SocketException e) { r = $"异常 {e.SocketErrorCode}"; }
                catch (Exception e) { r = $"异常 {e.GetType().Name}"; }
                result = r;
            }) { IsBackground = true };
            t.Start();
            Thread.Sleep(100);
            sw.Start();
            trigger();
            bool back = t.Join(2500);
            return (back ? result : "没醒", back ? sw.ElapsedMilliseconds : -1);
        }

        private static string Fast((string, long) r) => $"{r.Item1}、{(r.Item2 >= 0 && r.Item2 < 1000 ? "1 秒内" : r.Item2 < 0 ? "2.5 秒没回" : $"{r.Item2} ms")}";

        // LDN 代理套接字（RyuLdn 中继的数据面）按 FreeBSD 阻塞套接字语义唤醒（10-29 双人成行真机联机：两台各发 1 个包后都卡在 RecvFrom 740 秒，
        //   房主切页客人不跟。上游 LdnProxySocket 包进队列不 Set _receiveEvent、连接请求叫错事件、连接回应不存不叫）。期望照 FreeBSD：
        //   ① UDP 阻塞 recvfrom：包一到就返回、内容与来源对 ② shutdown(SHUT_RD) 叫醒阻塞的 recvfrom、返回 0
        //   ③ 监听 0.0.0.0 的阻塞 accept：发往本机的连接请求一到就返回、远端是请求方 ④ 阻塞 connect：对端接受回应一到就连上；回应源地址为 0 = 拒绝
        private static void LdnProxyWakeTest()
        {
            RyuLdnProtocol protocol = new();
            using LdnProxy proxy = new(new ProxyConfig { ProxyIp = ProxyGuestIp, ProxySubnetMask = 0xFFFF0000 }, new NullProxyClient(), protocol);
            IPAddress host = new(BitConverter.GetBytes(System.Buffers.Binary.BinaryPrimitives.ReverseEndianness(ProxyHostIp)));

            // ① UDP：游戏的阻塞收包线程（双人成行就是这样），收包超时 3 秒兜底，免得修前把测试进程卡死
            LdnProxySocket udp = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp, proxy) { Blocking = true };
            udp.Bind(new IPEndPoint(IPAddress.Any, 4242));
            udp.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReceiveTimeout, 3000);
            byte[] payload = [1, 2, 3, 4, 5];
            var recv = WakeAfterTrigger(() =>
            {
                byte[] buf = new byte[64]; EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                int n = udp.ReceiveFrom(buf, SocketFlags.None, ref from);
                return $"{n} 字节 {(buf.AsSpan(0, n).SequenceEqual(payload) ? "内容对" : "内容错")} 来自 {from}";
            }, () => proxy.HandleData(default, new ProxyDataHeader
            {
                Info = new ProxyInfo { SourceIpV4 = ProxyHostIp, SourcePort = 4242, DestIpV4 = ProxyGuestIp, DestPort = 4242, Protocol = ProtocolType.Udp },
                DataLength = (uint)payload.Length,
            }, payload));
            Check("LDN 代理：UDP 阻塞收包，包到即醒（双人成行客人卡在 RecvFrom）", "5 字节 内容对 来自 10.114.0.1:4242、1 秒内", Fast(recv));

            // ② shutdown(SHUT_RD)：阻塞中的 recvfrom 返回 0
            var shut = WakeAfterTrigger(() =>
            {
                byte[] buf = new byte[64]; EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                return $"返回 {udp.ReceiveFrom(buf, SocketFlags.None, ref from)}";
            }, () => udp.Shutdown(SocketShutdown.Receive));
            Check("LDN 代理：shutdown(SHUT_RD) 叫醒阻塞收包", "返回 0、1 秒内", Fast(shut));
            udp.Close();

            // ③ TCP 阻塞 accept（监听 0.0.0.0:5000）：房主发来的连接请求一到就返回
            LdnProxySocket listen = new(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp, proxy) { Blocking = true };
            listen.Bind(new IPEndPoint(IPAddress.Any, 5000));
            listen.Listen(4);
            var accepted = WakeAfterTrigger(() => $"远端 {listen.Accept().RemoteEndPoint}",
                () => proxy.HandleConnectionRequest(default, new ProxyConnectRequest
                {
                    Info = new ProxyInfo { SourceIpV4 = ProxyHostIp, SourcePort = 6000, DestIpV4 = ProxyGuestIp, DestPort = 5000, Protocol = ProtocolType.Tcp },
                }));
            Check("LDN 代理：监听 0.0.0.0 的阻塞 accept，连接请求到即醒", "远端 10.114.0.1:6000、1 秒内", Fast(accepted));
            listen.Close();

            // ④ TCP 阻塞 connect：对端接受（回应源地址 = 对端）→ 连上；回应源地址为 0 → 连接被拒
            foreach ((uint src, string want) in new[] { (ProxyHostIp, "连上 远端 10.114.0.1:7000"), (0u, $"异常 {SocketError.ConnectionRefused}") })
            {
                LdnProxySocket conn = new(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp, proxy) { Blocking = true };
                var connected = WakeAfterTrigger(() => { conn.Connect(new IPEndPoint(host, 7000)); return $"连上 远端 {conn.RemoteEndPoint}"; }, () =>
                {
                    for (int i = 0; i < 100 && conn.LocalEndPoint == null; i++) Thread.Sleep(5);
                    if (conn.LocalEndPoint is not IPEndPoint local) return;   // connect 没走到分配本地端口（修前：未 bind 直接抛）
                    ushort port = (ushort)local.Port;
                    proxy.HandleConnectionResponse(default, new ProxyConnectResponse
                    {
                        Info = new ProxyInfo { SourceIpV4 = src, SourcePort = 7000, DestIpV4 = ProxyGuestIp, DestPort = port, Protocol = ProtocolType.Tcp },
                    });
                });
                Check($"LDN 代理：阻塞 connect，对端{(src != 0 ? "接受" : "拒绝")}回应到即醒", $"{want}、1 秒内", Fast(connected));
                conn.Close();
            }

            // ⑤ G5：只调真实网络路径的 IP / TCP 选项照收、读回原值；不认识的回 ENOPROTOOPT（FreeBSD），不是未处理异常
            LdnProxySocket opt = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp, proxy);
            string Opt(Action a) { try { a(); return "成功"; } catch (SocketException e) { return $"异常 {e.SocketErrorCode}"; } catch (Exception e) { return $"异常 {e.GetType().Name}"; } }
            byte[] ttl = new byte[4];
            string set = Opt(() => opt.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.IpTimeToLive, 64));
            string get = Opt(() => opt.GetSocketOption(SocketOptionLevel.IP, SocketOptionName.IpTimeToLive, ttl));
            string unknown = Opt(() => opt.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership, 1));
            Check("LDN 代理：IP_TTL 设 64 读回 / 不认识的选项（G5）", $"成功 成功 64 / 异常 {SocketError.ProtocolOption}",
                $"{set} {get} {BitConverter.ToInt32(ttl)} / {unknown}");
            opt.Close();

            // ⑦ G12：接受列表的判定（nn::ldn：黑名单拒列表里的 MAC，白名单只放列表里的，AcceptAll 全放；RejectAll 由中继挡在进房前）
            {
                byte[] macA = [0x02, 0, 0, 0, 0, 0x0A], macB = [0x02, 0, 0, 0, 0, 0x0B];
                var filter = new System.Collections.Generic.HashSet<ulong> { Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.AccessPoint.S2AMacKey(macA) };
                string Allow(Ryujinx.HLE.HOS.Services.Ldn.Types.AcceptPolicy p) =>
                    $"{(Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.AccessPoint.S2AAllowed(p, filter, Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.AccessPoint.S2AMacKey(macA)) ? "放" : "拒")}" +
                    $"{(Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.AccessPoint.S2AAllowed(p, filter, Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.AccessPoint.S2AMacKey(macB)) ? "放" : "拒")}";
                Check("LDN 接受列表（G12）：列表里有 A，A / B 进房（黑名单 / 白名单 / 全接受）", "拒放 / 放拒 / 放放",
                    $"{Allow(Ryujinx.HLE.HOS.Services.Ldn.Types.AcceptPolicy.BlackList)} / {Allow(Ryujinx.HLE.HOS.Services.Ldn.Types.AcceptPolicy.WhiteList)} / {Allow(Ryujinx.HLE.HOS.Services.Ldn.Types.AcceptPolicy.AcceptAll)}");
            }

            // ⑥ G13：RecvMMsg 经 ManagedSocket 走 LDN 代理（FreeBSD recvmmsg：每条消息一个数据报，只第一条按阻塞模式等）。
            //   队里 2 个包（5 / 3 字节）、给 3 条消息（第一条两个 iov 3 + 13 字节）→ 收 2 条、长度 5 / 3 / 0、第一个包按 iov 拆开，第 3 条不等
            using LdnProxy proxy2 = new(new ProxyConfig { ProxyIp = ProxyGuestIp, ProxySubnetMask = 0xFFFF0000 }, new NullProxyClient(), protocol);
            Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy.SocketHelpers.RegisterProxy(proxy2);
            try
            {
                var ms = new Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl.ManagedSocket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp, null, false);
                ms.Bind(new IPEndPoint(IPAddress.Any, 4243));
                foreach (byte[] d in new[] { new byte[] { 1, 2, 3, 4, 5 }, new byte[] { 6, 7, 8 } })
                {
                    proxy2.HandleData(default, new ProxyDataHeader
                    {
                        Info = new ProxyInfo { SourceIpV4 = ProxyHostIp, SourcePort = 4242, DestIpV4 = ProxyGuestIp, DestPort = 4243, Protocol = ProtocolType.Udp },
                        DataLength = (uint)d.Length,
                    }, d);
                }
                var hdrType = typeof(Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types.BsdMsgHdr);
                var mmType = typeof(Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types.BsdMMsgHdr);
                object Msg(params byte[][] iov) => Activator.CreateInstance(hdrType, System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance, null,
                    [null, iov, null, default(Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types.BsdSocketFlags), 0u], null);
                byte[] a1 = new byte[3], a2 = new byte[13], b1 = new byte[16], c1 = new byte[16];
                Array msgs = Array.CreateInstance(hdrType, 3);
                msgs.SetValue(Msg(a1, a2), 0); msgs.SetValue(Msg(b1), 1); msgs.SetValue(Msg(c1), 2);
                var mm = (Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types.BsdMMsgHdr)Activator.CreateInstance(mmType, System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance, null, [msgs], null);
                Stopwatch t = Stopwatch.StartNew();
                var err = ms.RecvMMsg(out int vlen, mm, default, default);
                long ms0 = t.ElapsedMilliseconds;
                bool scatter = a1.AsSpan().SequenceEqual(new byte[] { 1, 2, 3 }) && a2[0] == 4 && a2[1] == 5 && b1[0] == 6 && b1[2] == 8;
                Check("LDN 代理：RecvMMsg 每条消息一个数据报（G13）", "SUCCESS 条数 2、长度 5 / 3 / 0、按 iov 拆开对、不等",
                    $"{err} 条数 {vlen}、长度 {mm.Messages[0].Length} / {mm.Messages[1].Length} / {mm.Messages[2].Length}、按 iov 拆开{(scatter ? "对" : "错")}、{(ms0 < 500 ? "不等" : $"等了 {ms0} ms")}");
                ms.Close();
            }
            finally
            {
                Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy.SocketHelpers.UnregisterProxy();
            }
        }
    }
}

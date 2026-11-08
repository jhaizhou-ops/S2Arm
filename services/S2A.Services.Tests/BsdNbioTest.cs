using Ryujinx.HLE.HOS.Services.Sockets.Bsd;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types;
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 每次调用的「本次不阻塞」标志 Nbio（MSG_NBIO 0x4000，同 DontWait）：11-06 真人快打11 主线程在离线回环 UDP 上带 Nbio recvfrom，
        //   Nbio 原先只记「不认得的标志」、按阻塞收，没人发数据就永远等，游戏停在第 1 帧。期望按规则手写，与实现无关：
        //   ① 空队列、阻塞模式套接字、带 Nbio 的 ReceiveFrom → 2 秒内返回 EWOULDBLOCK，返回后套接字仍是阻塞模式
        //   ② 同 ① 换 Receive
        //   ③ 发一个数据报后，带 Nbio 的 ReceiveFrom 读回同样 2 字节、SUCCESS
        //   ④ 对照：同样空队列不带标志的 ReceiveFrom 真的阻塞（2 秒没回来）——证明 ① 的快速返回来自 Nbio
        [SoloTest("--bsd-nbio")]
        private static int BsdNbioTest()
        {
            int fails = 0;
            void Want(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {what}"); if (!ok) fails++; }
            static (bool done, LinuxError err, int size) Call(Func<(LinuxError, int)> f, int ms)
            {
                (LinuxError, int) r = (LinuxError.SUCCESS, 0); bool finished = false;
                Thread t = new(() => { r = f(); finished = true; }) { IsBackground = true };
                t.Start();
                return (t.Join(ms) && finished, r.Item1, r.Item2);
            }

            using ManagedSocket rx = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp, null, true);
            Want(rx.Bind(new IPEndPoint(IPAddress.Loopback, 0)) == LinuxError.SUCCESS, "绑定回环 UDP");
            byte[] buf = new byte[8];

            var a = Call(() => { LinuxError e = rx.ReceiveFrom(out int n, buf, buf.Length, BsdSocketFlags.Nbio, out _); return (e, n); }, 2000);
            Want(a.done && a.err == LinuxError.EWOULDBLOCK, $"① 空队列带 Nbio 的 ReceiveFrom：2 秒内回来={a.done}、错误={a.err}（期望 EWOULDBLOCK）");
            Want(rx.Blocking, "① 调用后套接字仍是阻塞模式");

            var b = Call(() => { LinuxError e = rx.Receive(out int n, buf, BsdSocketFlags.Nbio); return (e, n); }, 2000);
            Want(b.done && b.err == LinuxError.EWOULDBLOCK, $"② 空队列带 Nbio 的 Receive：2 秒内回来={b.done}、错误={b.err}（期望 EWOULDBLOCK）");
            Want(rx.Blocking, "② 调用后套接字仍是阻塞模式");

            using ManagedSocket tx = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp, null, true);
            Want(tx.SendTo(out int sent, new byte[] { 0x5A, 0xA5 }, 2, BsdSocketFlags.None, rx.LocalEndPoint) == LinuxError.SUCCESS && sent == 2, "③ 发 2 字节");
            var c = Call(() => { LinuxError e = rx.ReceiveFrom(out int n, buf, buf.Length, BsdSocketFlags.Nbio, out _); return (e, n); }, 2000);
            Want(c.done && c.err == LinuxError.SUCCESS && c.size == 2 && buf[0] == 0x5A && buf[1] == 0xA5, $"③ 带 Nbio 读回：回来={c.done}、错误={c.err}、{c.size} 字节（期望 SUCCESS、2 字节 5A A5）");

            var d = Call(() => { LinuxError e = rx.ReceiveFrom(out int n, buf, buf.Length, BsdSocketFlags.None, out _); return (e, n); }, 2000);
            Want(!d.done, $"④ 对照：不带标志的 ReceiveFrom 2 秒内没回来={!d.done}（期望真阻塞）");

            Console.WriteLine($"{(fails == 0 ? "PASS" : "FAIL")}：--bsd-nbio 8 项，{fails} 项失败");
            return fails == 0 ? 0 : 1;
        }
    }
}

using Ryujinx.Common;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy;
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // Runs before FakeNative.Install: actual offline sockets and blocking
        // worker threads, without a game, renderer, filesystem or user profile.
        private static int OfflineSocketShutdown()
        {
            try
            {
                for (int round = 1; round <= 10; round++)
                {
                    S2AShutdown.Reset();
                    using OfflineSocket listener = new(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                    using OfflineSocket receiver = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                    using OfflineSocket poller = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                    listener.Bind(new IPEndPoint(IPAddress.Loopback, 0));
                    listener.Listen(1);
                    receiver.Bind(new IPEndPoint(IPAddress.Loopback, 0));
                    poller.Bind(new IPEndPoint(IPAddress.Loopback, 0));
                    Action[] calls = [
                        () => listener.Accept(),
                        () =>
                        {
                            EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                            receiver.ReceiveFrom(new byte[8], SocketFlags.None, ref from);
                        },
                        () => poller.Poll(-1, SelectMode.SelectRead),
                    ];
                    Exception[] results = new Exception[calls.Length];
                    Thread[] workers = new Thread[calls.Length];
                    for (int i = 0; i < workers.Length; i++)
                    {
                        int slot = i;
                        workers[i] = new Thread(() =>
                        {
                            try { calls[slot](); }
                            catch (Exception error) { results[slot] = error; }
                        }) { IsBackground = true, Name = $"OfflineSocketShutdown-{slot}" };
                        workers[i].Start();
                    }

                    bool allBlocked = SpinWait.SpinUntil(() =>
                        Array.TrueForAll(workers, thread => (thread.ThreadState & ThreadState.WaitSleepJoin) != 0), 2000);
                    S2AShutdown.Request();
                    bool allJoined = true;
                    foreach (Thread worker in workers) allJoined &= worker.Join(2000);
                    if (!allBlocked || !allJoined)
                        throw new InvalidOperationException($"第{round}轮未真实阻塞或未在取消后退出：blocked={allBlocked}, joined={allJoined}");
                    for (int i = 0; i < results.Length; i++)
                        if (results[i] is not SocketException { SocketErrorCode: SocketError.Interrupted })
                            throw new InvalidOperationException($"第{round}轮操作{i}未返回真实中断错误", results[i]);

                    S2AShutdown.Reset();
                    using OfflineSocket sender = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                    byte[] payload = [(byte)round, 0xA5];
                    int sent = sender.SendTo(payload, SocketFlags.None, receiver.LocalEndPoint);
                    byte[] received = new byte[8];
                    EndPoint source = new IPEndPoint(IPAddress.Any, 0);
                    int read = receiver.ReceiveFrom(received, SocketFlags.None, ref source);
                    if (sent != payload.Length || read != payload.Length || received[0] != round || received[1] != 0xA5)
                        throw new InvalidOperationException($"第{round}轮Reset后实际回环数据不一致");
                    Console.WriteLine($"真实离线socket取消 {round}/10：Accept/ReceiveFrom/Poll均先阻塞，再以Interrupted退出；Reset后UDP读回通过");
                }
                Console.WriteLine("PASS：10轮实际离线socket等待/取消/Reset；未加载游戏或用户数据");
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                return 1;
            }
            finally
            {
                S2AShutdown.Request();
                S2AShutdown.Reset();
            }
        }
    }
}

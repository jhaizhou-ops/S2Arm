// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Horizon.Sdk.OsTypes;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;

namespace S2A.Services.Tests
{
    // Horizon 服务端口不随 GetService 重复挂进服务线程的等待表；取消等待真叫醒服务线程（审计 P2-24 后续）。
    //   游戏线程直调受理会话（S2AProcessForServer）原先走上游 ProcessForServer，收尾把端口 RegisterToWaitList 再挂一份，可端口从没被主循环摘下：
    //   每次 GetService 等待表多一份（泄漏）；主循环一旦被叫醒就把这些副本搬进 _multiWait，过 64 份 MultiWaitImpl 的定长句柄数组越界。
    //   所以原先 CancelSynchronization 只能恒回成功、不叫醒。修后受理不再挂回，取消照 Horizon 语义叫醒等待、错句柄回 InvalidHandle。
    //   修前反证：等待表 +200（第一条红）；取消不叫醒、错句柄回成功（第二条红）；只改取消不改受理 = 叫醒后越界（第二条报红 / 服务线程异常）
    public static unsafe partial class Program
    {
        private const int WaitListRounds = 200;   // 远超 64

        private static (ServerManagerBase Manager, uint Sm) AudioManagerFixture()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Msg init = Msg.Cmif(0, Bytes(0L));
            init.SendPid = true;
            Call(sm, init);
            if (!WaitFor(() => Array.IndexOf(HorizonHost.Services, "audren:u") >= 0, 10_000)) throw new Exception("audren:u 10 秒内没注册");
            var ports = (IDictionary)typeof(HorizonHost).GetField("_ports", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
            object entry = ports["audren:u"];
            var manager = (ServerManagerBase)entry.GetType().GetField("Item1").GetValue(entry);
            return (manager, sm);
        }

        private static object ManagerField(ServerManagerBase m, string name) =>
            typeof(ServerManagerBase).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(m);

        // 服务线程等待表里挂着的对象数（主等待表 + 待并入表）
        private static int WaitListSize(ServerManagerBase m)
        {
            for (int tries = 0; ; tries++)
            {
                try
                {
                    return ((MultiWait)ManagerField(m, "_multiWait")).MultiWaits.Count() + ((MultiWait)ManagerField(m, "_waitList")).MultiWaits.Count();
                }
                catch (InvalidOperationException) when (tries < 10)
                {
                    Thread.Sleep(10);   // 服务线程正在并表
                }
            }
        }

        // GetService(audren:u) 一次并关掉会话：返回是否「结果 0、move 1 个会话句柄」
        private static bool GetAudioRendererOnce(uint sm)
        {
            Reply r = Call(sm, Msg.Cmif(1, Name8("audren:u")));
            bool ok = r.Result == 0 && r.Move.Count == 1 && FakeNative.KindOf(r.Move[0]) == ObjKind.Session;
            foreach (uint h in r.Move) FakeNative.HandleClose(h);
            return ok;
        }

        private static object HorizonFailure() => typeof(HorizonHost).GetField("_failure", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);

        [SoloTest("--horizon-waitlist-getservice", Booted = true)]
        private static void HorizonWaitListGetService()
        {
            (ServerManagerBase m, uint sm) = AudioManagerFixture();
            long red0 = Red.Total;
            int before = WaitListSize(m);
            int ok = 0;
            for (int i = 0; i < WaitListRounds; i++) if (GetAudioRendererOnce(sm)) ok++;
            Thread.Sleep(200);
            int after = WaitListSize(m);
            Check($"Horizon 等待表：连调 {WaitListRounds} 次 GetService(audren:u)（每次关会话）不增长",
                $"{WaitListRounds} 次成功、等待表 {before} → {before}、报红 +0、服务线程无异常",
                $"{ok} 次成功、等待表 {before} → {after}、报红 +{Red.Total - red0}、服务线程{(HorizonFailure() == null ? "无异常" : "异常")}");
            FakeNative.HandleClose(sm);
        }

        [SoloTest("--horizon-cancel-wake", Booted = true)]
        private static void HorizonCancelWake()
        {
            (ServerManagerBase m, uint sm) = AudioManagerFixture();
            GetAudioRendererOnce(sm);   // 本线程登记 HorizonStatic（游戏线程直调同一路径），之后在本线程触发本地事件
            var wake = (IDictionary)typeof(NativeSyscall).GetField("_threadWake", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
            int token = wake.Keys.Cast<int>().First();
            var cancelBad = HorizonHost.Syscall.CancelSynchronization(NativeSyscall.TokenBase | 0x0FFFFFFF);
            var cancelGood = HorizonHost.Syscall.CancelSynchronization(token);   // 只叫醒一圈：主循环醒来没有可处理的对象，回去接着等
            Check("CancelSynchronization 返回真实结果（照 Horizon：不是线程句柄 InvalidHandle，活着的服务线程 Success）",
                $"{Ryujinx.Horizon.Common.KernelResult.InvalidHandle}、{Ryujinx.Horizon.Common.Result.Success}", $"{cancelBad}、{cancelGood}");

            // 「等待表有新对象」的本地事件：上游靠取消叫醒主循环，主循环醒来清掉它。叫不醒就一直挂着
            var notify = (Event)ManagerField(m, "_notifyEvent");
            long red0 = Red.Total;
            int before = WaitListSize(m);
            int ok = 0, woke = 0;
            for (int i = 0; i < WaitListRounds; i++)
            {
                if (GetAudioRendererOnce(sm)) ok++;
                notify.Signal();
                if (!WaitFor(() => notify.IsSignaledThreadUnsafe() == TriBool.False, 1000)) break;   // 叫不醒：不再空等后面各轮
                woke++;
            }
            int after = WaitListSize(m);
            Check($"取消叫醒服务线程：{WaitListRounds} 轮「GetService + 触发本地事件」，每轮主循环醒来清事件、不重复挂入、不越界",
                $"{WaitListRounds} 次成功、{WaitListRounds} 次叫醒、等待表 {before} → {before}、报红 +0、服务线程无异常",
                $"{ok} 次成功、{woke} 次叫醒、等待表 {before} → {after}、报红 +{Red.Total - red0}、服务线程{(HorizonFailure() == null ? "无异常" : "异常")}");
            FakeNative.HandleClose(sm);
        }
    }
}

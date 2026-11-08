// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections;
using System.Reflection;
using System.Text;
using System.Threading;

namespace S2A.Services.Tests
{
    // vi/BufferQueue 收局时「已经堵在出队等空槽里」的那一次（审计 #1508 P1-109）：
    //   入口排空（DequeueBuffer 开头的 S2ASinkMode 分支）只管「进函数时已死态」；线程先进 WaitForFreeSlotThenRelock
    //   等空槽、随后收局（S2AShutdown.Request 唤醒）时，下一圈回 NoInit(-19)、槽号 -1 → 游戏跳过出参赋值、拿未初始化
    //   栈值当缓冲下标 → 野指针。期望：这一次同样走排空取槽，回 0、槽号落在槽数组 [0, 3) 里。
    //   先后按事件判，不赌墙钟：本层 RenderLayerId=0、合成器不碰本层锁，主线程不持锁时出队线程处于 WaitSleepJoin
    //   ⇔ 它停在 Core.Lock 上的 Monitor.Wait（DequeueBuffer 里唯一的阻塞点）。
    //   对照：未死态时同样堵住、消费者取还一帧 → 出队回 0、拿到的正是刚还回的那个槽（正常出队不变）。
    public static unsafe partial class Program
    {
        // 3 帧入队不取 → 3 槽全 Queued、无空槽；然后另一线程直接调 Producer.DequeueBuffer，等它进 Monitor.Wait。
        private static (Thread T, Func<(int St, int Slot)> Result, bool Waiting) ViBlockedDequeue(uint hos, ViDrainFixture f, object producer)
        {
            _viReqScratch = new bool[ViDrainSlots];
            for (int i = 0; i < ViDrainSlots; i++) ViFrameCycle(hos, f, false, _viReqScratch);

            MethodInfo deq = producer.GetType().GetMethod("DequeueBuffer");
            Type fmt = deq.GetParameters()[5].ParameterType;
            int st = int.MinValue, slot = int.MinValue;
            bool done = false;
            var t = new Thread(() =>
            {
                object[] a = [0, null, false, 0u, 0u, Enum.ToObject(fmt, 1), 0xB00u];   // 同步、缺省尺寸、RGBA8888、预分配用途（同 ViMakeLayer）
                st = Convert.ToInt32(deq.Invoke(producer, a));
                slot = (int)a[0];
                Volatile.Write(ref done, true);
            }) { IsBackground = true };
            t.Start();
            // 事件判定：直到出队线程停进 Monitor.Wait（或提前返回 = 前置条件不成立）；轮询上限只防卡死、不参与判定
            bool waiting = false;
            for (int i = 0; i < 5000 && !waiting && !Volatile.Read(ref done); i++)
            {
                waiting = (t.ThreadState & ThreadState.WaitSleepJoin) != 0;
                if (!waiting) Thread.Sleep(1);
            }
            return (t, () => (st, slot), waiting && !Volatile.Read(ref done));
        }

        [SoloTest("--vi-dequeue-wait-shutdown", Booted = true)]
        private static void ViDequeueWaitShutdown()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint viu = Call(sm, Msg.Cmif(1, Name8("vi:u"))).Move[0];
            uint ids = Call(viu, Msg.Cmif(0, Bytes(0u))).Move[0];
            uint hos = Call(ids, Msg.Cmif(100)).Move[0];
            byte[] dn = new byte[0x40];
            Encoding.ASCII.GetBytes("Default").CopyTo(dn, 0);
            long displayId = *(long*)Call(ids, Msg.Cmif(1010, dn)).Data;

            var bfs = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Static;
            object sf = Host.Device.System.GetType().GetProperty("SurfaceFlinger", bfs).GetValue(Host.Device.System);
            var layers = (IDictionary)sf.GetType().GetField("_layers", bfs).GetValue(sf);
            var c = new ViCtx { Ids = ids, Hos = hos, DisplayId = displayId, Layers = layers };
            object ProducerOf(ViDrainFixture f)
            {
                foreach (DictionaryEntry e in layers)
                    if (ReferenceEquals(e.Value.GetType().GetField("Core").GetValue(e.Value), f.Core))
                        return e.Value.GetType().GetField("Producer").GetValue(e.Value);
                return null;
            }

            // 对照 · 未死态：堵在等空槽 → 消费者取还一帧 → 出队回 0、槽 = 刚还回的槽（修前修后都绿）
            // 合成器只取 RenderLayerId 那一层：清零后本层帧留在队列里、本层锁只有本用例两条线程碰（桩渲染器上屏会空引用）
            MethodInfo setRender = sf.GetType().GetMethod("SetRenderLayer");
            ViDrainFixture f1 = ViMakeLayer(c, _game + 0x4000);
            setRender.Invoke(sf, [0L]);
            var b1 = ViBlockedDequeue(hos, f1, ProducerOf(f1));
            object[] acq = [null, 0UL, false];
            int acqSt = Convert.ToInt32(f1.Acquire.Invoke(f1.Consumer, acq));
            int relSlot = acqSt == 0 ? (int)acq[0].GetType().GetField("Slot").GetValue(acq[0]) : -100;
            if (acqSt == 0) f1.Release.Invoke(f1.Consumer, [acq[0], f1.NoFence]);
            bool j1 = b1.T.Join(3000);
            var r1 = b1.Result();
            Check("vi 等空槽·未死态：出队线程先停进等待，消费者还槽后回 0、槽 = 还回的槽", $"等待中、返回、状态 0、槽 {relSlot}",
                $"{(b1.Waiting ? "等待中" : "未进等待")}、{(j1 ? "返回" : "超时")}、状态 {r1.St}、槽 {r1.Slot}");

            // 主角 · 堵在等空槽时收局：S2AShutdown.Request 唤醒 → 必须走排空取真实槽回 0（修前 -19、槽 -1）
            ViDrainFixture f2 = ViMakeLayer(c, _game + 0x5000);
            setRender.Invoke(sf, [0L]);
            var b2 = ViBlockedDequeue(hos, f2, ProducerOf(f2));
            Ryujinx.Common.S2AShutdown.Request();
            bool j2 = b2.T.Join(3000);
            var r2 = b2.Result();
            Ryujinx.Common.S2AShutdown.Reset();
            bool inArray = r2.Slot >= 0 && r2.Slot < ViDrainSlots;
            Check("vi 等空槽·等待中收局：出队回 0、槽号落在槽数组 [0,3)", "等待中、返回、状态 0、槽在数组内",
                $"{(b2.Waiting ? "等待中" : "未进等待")}、{(j2 ? "返回" : "超时")}、状态 {r2.St}、槽{(inArray ? "在数组内" : $"越界({r2.Slot})")}");
        }
    }
}

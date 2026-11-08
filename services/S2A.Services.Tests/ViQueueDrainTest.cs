// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;

namespace S2A.Services.Tests
{
    // vi/BufferQueue 收局排空（t-wsi-abandon）：surface 撤销未收局时合成器照常排空（帧不上屏），
    // 而队列一死（宿主收局请求 S2AShutdown.Requested / 消费者 Abandon / 核心 PrepareForExit），
    // 上游语义是生产者交易一律 NoInit。游戏的 nvnWindowAcquireTexture 对非 0 状态早退、不写出参，
    // 调用方拿未初始化栈值当缓冲下标索引纹理表 → 野指针 SIGSEGV（8E / 9000 双机复现，t-shutdown-segv）。
    //   期望语义：队列死态只代表「没人消费」，不代表「游戏接口死了」——
    //   出队仍回真实可用槽（先空闲槽，再回收已入队未消费的槽、消费者手里的槽，最后交还生产侧槽），
    //   入队收帧即弃（不进队列、不回调、不按票序等）、永不阻塞、状态恒 0；
    //   收局请求解除（Reset）后恢复正常通路，消费者能再取到帧。
    //   修前反证：三个死态相位全部返回 -19（NoInit），本测红。
    public static unsafe partial class Program
    {
        private const int ViDrainSlots = 3;

        // IGraphicBufferProducer 各事务应答：状态码恒写在负载体末 4 字节（槽号 / 围栏 / QueueBufferOutput 在前）
        private static int ViLastStatus(byte* rp) => *(int*)(rp + *(uint*)rp + *(uint*)(rp + 4) - 4);
        private static int ViRepInt(byte* rp, int index) => *(int*)(rp + *(uint*)(rp + 4) + index * 4);

        // 输入 Parcel：头 16 字节 { 负载长, 负载偏移 0x10, 对象长 0, 对象偏移 } + 接口名 + 负载（同 vi 中继用例）
        private static int ViWriteParcel(byte* p, byte[] payload)
        {
            MemoryStream ms = new();
            BinaryWriter w = new(ms);
            const string token = "android.gui.IGraphicBufferProducer";
            w.Write(0x100);
            w.Write(token.Length);
            w.Write(Encoding.Unicode.GetBytes(token + "\0"));
            while (ms.Length % 4 != 0) w.Write((byte)0);
            w.Write(payload);
            byte[] body = ms.ToArray();
            *(uint*)p = (uint)body.Length;
            *(uint*)(p + 4) = 0x10;
            *(uint*)(p + 8) = 0;
            *(uint*)(p + 12) = 0x10 + (uint)body.Length;
            body.CopyTo(new Span<byte>(p + 0x10, body.Length));
            return 0x10 + body.Length;
        }

        private sealed class ViDrainFixture
        {
            public int BinderId;
            public object Core;          // BufferQueueCore：槽状态 / 队列长度审计
            public object Consumer;      // BufferItemConsumer：夹具当消费方（RenderLayerId=0 后合成器不取本层帧）
            public MethodInfo Acquire;
            public MethodInfo Release;
            public object NoFence;
            public delegate Msg TransactFn(uint code, byte* p, int len);
            public TransactFn Transact;
            public byte* Deq; public int DeqLen;      // DequeueBuffer 入包
            public byte* Que; public int QueLen; public int QueSlotOff; // QueueBuffer 入包 + 槽号偏移
            public byte* Req;                          // RequestBuffer 入包（槽号每帧改）
            public byte* Rep;                          // 应答包
        }

        private sealed class ViCtx
        {
            public uint Ids;
            public uint Hos;
            public long DisplayId;
            public IDictionary Layers;
        }

        private static ViDrainFixture ViMakeLayer(ViCtx c, byte* mem)
        {
            byte* lp = mem;
            Msg csl = Msg.Cmif(2030, Bytes(0L, c.DisplayId));
            csl.B.Add(((ulong)lp, 0x100));
            long layerId = *(long*)Call(c.Ids, csl).Data;
            int binderId = (int)*(long*)(lp + *(uint*)(lp + 4) + 8);   // 出 Parcel：FlatBinderObject { Type, Flags, BinderId }

            var bfs = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
            object sf = Host.Device.System.GetType().GetProperty("SurfaceFlinger", bfs).GetValue(Host.Device.System);
            // CreateStrayLayer 照上游把新层设为合成层（SetRenderLayer(layerId)），合成线程每拍就会来取本层帧上屏；本夹具预分配的
            //   缓冲没有 nvmap 句柄（NvMapHandle / NvMapId = 0），PostFrameBuffer 里 GetMapFromHandle 回 null → 合成线程空引用、整进程 rc=134
            //   （11-04 列车 full 批两次红；本机 4 路并发 30 次崩 2 次）。切回 0：本层帧只由本用例取还，合成器不碰
            sf.GetType().GetMethod("SetRenderLayer").Invoke(sf, [0L]);
            Check($"vi 夹具前置·建层 {layerId} 后合成器不取本层（RenderLayerId）", 0L, (long)sf.GetType().GetProperty("RenderLayerId").GetValue(sf));

            object layer = c.Layers[layerId];
            object consumer = layer.GetType().GetField("Consumer").GetValue(layer);
            object core = layer.GetType().GetField("Core").GetValue(layer);
            var acquire = consumer.GetType().GetMethod("AcquireBuffer");
            var release = consumer.GetType().GetMethod("ReleaseBuffer");

            var f = new ViDrainFixture
            {
                BinderId = binderId,
                Core = core,
                Consumer = consumer,
                Acquire = acquire,
                Release = release,
                NoFence = Activator.CreateInstance(release.GetParameters()[1].ParameterType.GetElementType()),
                Deq = mem + 0x200,
                Que = mem + 0x300,
                Req = mem + 0x400,
                Rep = mem + 0x600,
            };

            f.Transact = (code, p, len) =>
            {
                Msg m = Msg.Cmif(0, Bytes(binderId, code, 0u));
                m.A.Add(((ulong)p, (ulong)len));
                m.B.Add(((ulong)f.Rep, 0x200));
                return m;
            };

            Call(c.Hos, f.Transact(10, f.Deq, ViWriteParcel(f.Deq, Bytes(0, 1, 0))));   // Connect(无监听, NVN, 非应用控制)
            for (int s = 0; s < ViDrainSlots; s++)
            {
                byte[] gb = new byte[0x16C];
                BitConverter.GetBytes(64).CopyTo(gb, 4);
                BitConverter.GetBytes(64).CopyTo(gb, 8);
                BitConverter.GetBytes(64).CopyTo(gb, 12);
                BitConverter.GetBytes(1).CopyTo(gb, 16);
                BitConverter.GetBytes(0xB00).CopyTo(gb, 20);
                BitConverter.GetBytes(0x144 / 4).CopyTo(gb, 0x24);
                Call(c.Hos, f.Transact(14, f.Que, ViWriteParcel(f.Que, [.. Bytes(s, 1, 0x16CL), .. gb])));
            }

            f.DeqLen = ViWriteParcel(f.Deq, Bytes(0, 0, 0, 1, 0xB00));   // DequeueBuffer(同步, 缺省尺寸, RGBA8888, 用途 = 预分配用途)
            byte[] qin = [.. Bytes(0, 0x54L, 0L, 0, 0, 0, 64, 64, 0, 0, 0, 0, 1), .. new byte[0x24]];
            f.QueLen = ViWriteParcel(f.Que, qin);                      // QueueBuffer(槽, QueueBufferInput 0x54)
            f.QueSlotOff = 0x10 + (f.QueLen - 0x10 - qin.Length);
            return f;
        }

        // 一轮游戏呈现：DequeueBuffer → RequestBuffer（每槽首次）→ QueueBuffer；全部经真 binder TransactParcel。
        // drain = 夹具当合成器取走并归还一帧（surface 活着时合成器持续排空、帧丢在窗口层）。
        private static (int Deq, int Slot, int Req, int Que, int Acq) ViFrameCycle(
            uint hos, ViDrainFixture f, bool drain, bool[] requested)
        {
            object[] acq = [null, 0UL, false];
            int req = 0, acqSt = -1;
            Call(hos, f.Transact(3, f.Deq, f.DeqLen));
            int deq = ViLastStatus(f.Rep);
            int slot = ViRepInt(f.Rep, 0);
            *(int*)(f.Que + f.QueSlotOff) = slot;
            if (deq == 0 && slot >= 0 && slot < ViDrainSlots && !requested[slot])
            {
                Call(hos, f.Transact(1, f.Req, ViWriteParcel(f.Req, Bytes(slot))));
                req = ViLastStatus(f.Rep);
                requested[slot] = true;
            }
            Call(hos, f.Transact(7, f.Que, f.QueLen));
            int que = ViLastStatus(f.Rep);
            if (drain)
            {
                acqSt = Convert.ToInt32(f.Acquire.Invoke(f.Consumer, acq));
                if (acqSt == 0) f.Release.Invoke(f.Consumer, [acq[0], f.NoFence]);
            }
            return (deq, slot, req, que, acqSt);
        }

        // 连跑 rounds 轮：返回 (是否全部≤timeout 返回, 出错步描述, 槽号越界数)。slotOk = 每次出队槽都在 [0, Slots)
        private static (bool InTime, string Bad, int BadSlots) ViRunCycles(uint hos, ViDrainFixture f, bool drain, int rounds, int timeoutMs)
        {
            string bad = "";
            int badSlots = 0;
            bool inTime = Task.Run(() =>
            {
                for (int i = 0; i < rounds; i++)
                {
                    var r = ViFrameCycle(hos, f, drain, _viReqScratch);
                    if (r.Deq != 0 || r.Req != 0 || r.Que != 0) bad += $"[出{r.Deq} 请{r.Req} 入{r.Que}]";
                    if (r.Deq == 0 && (r.Slot < 0 || r.Slot >= ViDrainSlots)) badSlots++;
                }
            }).Wait(timeoutMs);
            return (inTime, bad, badSlots);
        }

        private static bool[] _viReqScratch = new bool[ViDrainSlots];

        // 槽状态审计：BufferState { Free=0, Dequeued=1, Queued=2, Acquired=3 }；返回 Queued+Acquired 槽数（应恒 0）与队列帧数
        private static (int Stuck, int Pending) ViSlotAudit(object core)
        {
            object slots = core.GetType().GetField("Slots").GetValue(core);
            var item = slots.GetType().GetProperty("Item");
            var stateField = slots.GetType().Assembly.GetType("Ryujinx.HLE.HOS.Services.SurfaceFlinger.BufferSlot").GetField("BufferState");
            int stuck = 0;
            for (int i = 0; i < ViDrainSlots; i++)
            {
                int s = (int)stateField.GetValue(item.GetValue(slots, [i]));
                if (s is 2 or 3) stuck++;
            }
            int pending = ((ICollection)core.GetType().GetField("Queue").GetValue(core)).Count;
            return (stuck, pending);
        }

        [SoloTest("--vi-queue-drain", Booted = true)]
        private static void ViQueueDrain()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint viu = Call(sm, Msg.Cmif(1, Name8("vi:u"))).Move[0];
            uint ids = Call(viu, Msg.Cmif(0, Bytes(0u))).Move[0];
            uint hos = Call(ids, Msg.Cmif(100)).Move[0];
            byte[] dn = new byte[0x40];
            Encoding.ASCII.GetBytes("Default").CopyTo(dn, 0);
            long displayId = *(long*)Call(ids, Msg.Cmif(1010, dn)).Data;

            // 夹具当消费方（合成线程没有可用的显存句柄，ViMakeLayer 建层后把 RenderLayerId 切回 0，由本用例代为取帧/还帧，同 vi 中继）
            var bfs = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Static;
            object sf = Host.Device.System.GetType().GetProperty("SurfaceFlinger", bfs).GetValue(Host.Device.System);
            var layers = (IDictionary)sf.GetType().GetField("_layers", bfs).GetValue(sf);
            var c = new ViCtx { Ids = ids, Hos = hos, DisplayId = displayId, Layers = layers };

            // 相位 0 · 活着：合成器逐帧取还（surface 在、通路正常；harness 自证，修前修后都绿）
            ViDrainFixture f1 = ViMakeLayer(c, _game + 0x4000);
            _viReqScratch = new bool[ViDrainSlots];
            var live = ViRunCycles(hos, f1, true, 4, 3000);
            Check("vi 排空·活着（合成器取还）×4：各步状态全 0", "返回、全 0、槽越界 0",
                $"{(live.InTime ? "返回" : "超时")}、{(live.Bad == "" ? "全 0" : live.Bad)}、槽越界 {live.BadSlots}");

            // 相位 1 · 收局：S2AShutdown.Request 置位（此刻 writer 尚未停稳），游戏呈现循环照跑：
            //   出队必须回真实槽、入队收帧即弃、不阻塞；修前这里全是 -19（NoInit）→ 真机 SIGSEGV
            Ryujinx.Common.S2AShutdown.Request();
            _viReqScratch = new bool[ViDrainSlots];
            var shut = ViRunCycles(hos, f1, false, 8, 3000);
            var a1 = ViSlotAudit(f1.Core);
            Check("vi 排空·收局请求下 ×8（不取帧）：出队回槽、各步状态 0、≤3s", "返回、全 0、槽越界 0",
                $"{(shut.InTime ? "返回" : "超时")}、{(shut.Bad == "" ? "全 0" : shut.Bad)}、槽越界 {shut.BadSlots}");
            Check("vi 排空·收局后无卡帧：Queued/Acquired 槽 0、队列 0 帧", "0 卡槽、0 帧", $"{a1.Stuck} 卡槽、{a1.Pending} 帧");

            // 相位 2 · 恢复：Reset 后消费者能再取到帧（surface 恢复接回真实消费者的队列侧语义）
            Ryujinx.Common.S2AShutdown.Reset();
            _viReqScratch = new bool[ViDrainSlots];
            var back = ViFrameCycle(hos, f1, true, _viReqScratch);
            Check("vi 排空·恢复：Reset 后出队-入队-消费者取帧全 0", "出0 请0 入0 取0",
                $"出{back.Deq} 请{back.Req} 入{back.Que} 取{back.Acq}");

            // 相位 3 · 消费者放弃：Abandon 后生产者交易同样排空不报错（防御：上游 NoInit 同源）
            ViDrainFixture f2 = ViMakeLayer(c, _game + 0x5000);
            _viReqScratch = new bool[ViDrainSlots];
            ViRunCycles(hos, f2, true, 2, 3000);
            f2.Consumer.GetType().GetMethod("Abandon").Invoke(f2.Consumer, null);
            var ab = ViRunCycles(hos, f2, false, 4, 3000);
            Check("vi 排空·Abandon ×4：出队回槽、各步状态 0、≤3s", "返回、全 0、槽越界 0",
                $"{(ab.InTime ? "返回" : "超时")}、{(ab.Bad == "" ? "全 0" : ab.Bad)}、槽越界 {ab.BadSlots}");

            // 相位 4 · 核心退出：PrepareForExit（合成器 Dispose 路径）下同理
            ViDrainFixture f3 = ViMakeLayer(c, _game + 0x6000);
            _viReqScratch = new bool[ViDrainSlots];
            ViRunCycles(hos, f3, true, 2, 3000);
            f3.Core.GetType().GetMethod("PrepareForExit").Invoke(f3.Core, null);
            var ex = ViRunCycles(hos, f3, false, 4, 3000);
            Check("vi 排空·PrepareForExit ×4：出队回槽、各步状态 0、≤3s", "返回、全 0、槽越界 0",
                $"{(ex.InTime ? "返回" : "超时")}、{(ex.Bad == "" ? "全 0" : ex.Bad)}、槽越界 {ex.BadSlots}");
        }
    }
}

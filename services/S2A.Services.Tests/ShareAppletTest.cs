// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // 分享小程序（11-03 Zumba 分享截图 Break）：nn::album::SaveAndShareScreenshot → nn::web::ShowSharePage 按 SDK 流程
    //   CreateLibraryApplet(0x18 = LibAppletWhitelisted / 分享，模式 0)，推公共参数（小程序版本 0x60000）+ 0x2000 字节网页参数（Shim = Share 4），
    //   Start 后 PopOutData，CommonApi::JoinAndFinishLibraryApplet 要求读回恰好 0x2000 字节，否则无结果码 Abort（Break 原因 0 结果 0）。
    //   期望按 switchbrew / libnx 规范手写：版本 ≥ 0x30000 且 Shim = Share 回 TLV 应答，存储 0x2000 字节；
    //   头 = 条数 1、Shim 4；第一条 TLV = 类型 1（ExitReason）、长 4、值 0（ExitButton，玩家关掉小程序）；不报红。
    //   修前：0x18 落空壳小程序，只推 8 字节（Success 的 u64）→ 这里读到大小 0x8、头全错
    public static unsafe partial class Program
    {
        [SvcCase]
        private static void ShareAppletInDomain()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Reply goe = Call(sm, Msg.Cmif(1, Name8("appletOE")));
            uint oe = goe.Move.Count == 1 ? goe.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(oe, cd).Data;
            byte* buf = FakeNative.Alloc(0x2000);

            Reply Domain(Msg m, int obj)
            {
                m.DomainObject = obj;
                m.Write(_tlr);
                Svc(0x21, FakeNative.CookieOf(oe));
                return Reply.ParseDomain(_tlr);
            }

            int OutObj(Reply r) => *(int*)r.Data;

            string got;
            long red0 = Red.Total;

            try
            {
                Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
                int proxy = OutObj(Domain(opx, root));                                  // OpenApplicationProxy
                int creator = OutObj(Domain(Msg.Cmif(11), proxy));                      // GetLibraryAppletCreator
                int accessor = OutObj(Domain(Msg.Cmif(0, Bytes(0x18, 0)), creator));    // CreateLibraryApplet(0x18, mode 0)

                uint PushStorage(byte[] data)
                {
                    int sto = OutObj(Domain(Msg.Cmif(10, Bytes((long)data.Length)), creator));   // CreateStorage
                    int acc = OutObj(Domain(Msg.Cmif(0), sto));                                   // IStorage.Open
                    data.CopyTo(new Span<byte>(buf, data.Length));
                    Msg w = Msg.Cmif(10, Bytes(0UL)); w.A.Add(((ulong)buf, (ulong)data.Length));   // IStorageAccessor.Write(offset 0)
                    Domain(w, acc);
                    Msg push = Msg.Cmif(100); push.InObjects.Add(sto);                            // PushInData
                    return Domain(push, accessor).Result;
                }

                // 公共参数 0x20 字节：结构版本 1、结构长 0x20、小程序版本 0x60000（ShowSharePage 写死的值）、主题色 0、开机音 0 + 填充、tick 0
                uint p1 = PushStorage(Bytes(1u, 0x20u, 0x60000u, 0u, 0UL, 0UL));
                // 网页参数 0x2000 字节：头（条数 1、填充、Shim = Share 4）+ TLV ShareStartPage（类型 9、长 4、填充、值 0 = 缺省页）
                byte[] web = new byte[0x2000];
                BitConverter.GetBytes((ushort)1).CopyTo(web, 0);
                BitConverter.GetBytes(4u).CopyTo(web, 4);
                BitConverter.GetBytes((ushort)9).CopyTo(web, 8);
                BitConverter.GetBytes((ushort)4).CopyTo(web, 10);
                uint p2 = PushStorage(web);

                uint st = Domain(Msg.Cmif(10), accessor).Result;      // Start
                uint gr = Domain(Msg.Cmif(30), accessor).Result;      // GetResult
                Reply pop = Domain(Msg.Cmif(101), accessor);          // PopOutData
                int outSto = OutObj(pop);
                int outAcc = OutObj(Domain(Msg.Cmif(0), outSto));     // IStorage.Open
                long size = *(long*)Domain(Msg.Cmif(0), outAcc).Data; // IStorageAccessor.GetSize

                new Span<byte>(buf, 0x2000).Clear();
                Msg rd = Msg.Cmif(11, Bytes(0UL)); rd.B.Add(((ulong)buf, (ulong)Math.Min(size, 0x2000)));   // IStorageAccessor.Read(offset 0)
                uint rr = Domain(rd, outAcc).Result;

                ushort count = *(ushort*)buf;
                uint shim = *(uint*)(buf + 4);
                ushort t1 = *(ushort*)(buf + 8), l1 = *(ushort*)(buf + 10);
                uint v1 = *(uint*)(buf + 16);
                got = $"入参 0x{p1:X} / 0x{p2:X}；Start 0x{st:X}、GetResult 0x{gr:X}、PopOutData 0x{pop.Result:X}、Read 0x{rr:X}；" +
                      $"大小 0x{size:X}、条数 {count}、Shim {shim}、TLV 类型 {t1} 长 {l1} 值 {v1}、报红 +{Red.Total - red0}";
            }
            catch (InvalidOperationException e)
            {
                got = $"应答解析失败：{e.Message}、报红 +{Red.Total - red0}";
            }
            finally
            {
                FakeNative.Free(buf);
                FakeNative.HandleClose(oe);
                FakeNative.HandleClose(sm);
            }

            Check("分享小程序 0x18（ShowSharePage：版本 0x60000、Shim Share）：回 0x2000 字节 TLV 应答、ExitReason = ExitButton，游戏读满 0x2000 不 Abort",
                "入参 0x0 / 0x0；Start 0x0、GetResult 0x0、PopOutData 0x0、Read 0x0；大小 0x2000、条数 1、Shim 4、TLV 类型 1 长 4 值 0、报红 +0", got);
        }
    }
}

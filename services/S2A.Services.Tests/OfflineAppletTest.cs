// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // 离线网页小程序（11-04 BioShock Remastered 首次启动卡死在服务条款页）：游戏没有 FirstRun.nx 时
    //   do { r = nn::web::ShowOfflineHtmlPage(&ret, "legalterms.htdocs/termsofservice.html"); } while (r != 0 || ret.GetOfflineExitReason() != 4);
    //   ShowOfflineHtmlPage 建小程序 0x17（LibAppletOff），公共参数版本 0x80000，网页参数 Shim = Offline 3，结束后按 0x1010 字节读回
    //   WebCommonReturnValue（u32 退出原因、填充、0x1000 LastUrl、u64 LastUrlSize），GetOfflineExitReason 就是第一个 u32。
    //   期望按真值手写（yuzu 系 DefaultWebBrowserApplet::OpenLocalWebPage：没有网页渲染时离线页回 WindowClosed = 4、last_url "http://localhost/"；
    //   枚举 EndButtonPressed 0 / BackButtonPressed 1 / ExitRequested 2 / CallbackURL 3 / WindowClosed 4 / ErrorDialog 7）：
    //   大小 0x1010、退出原因 4、LastUrl "http://localhost/"、LastUrlSize 17、不报红。
    //   修前：Ryujinx 上游一律回 ExitButton 0，游戏每秒重弹 2.6 万次条款页、主线程不出首帧（c1104_r2 Air 局 120 秒 320 万次）
    public static unsafe partial class Program
    {
        [SvcCase]
        private static void OfflineAppletInDomain()
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
                int accessor = OutObj(Domain(Msg.Cmif(0, Bytes(0x17, 0)), creator));    // CreateLibraryApplet(0x17 LibAppletOff, mode 0)

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

                // 公共参数 0x20 字节：结构版本 1、结构长 0x20、小程序版本 0x80000（ShowOfflineHtmlPage 写死的值）、主题色 0、开机音 0 + 填充、tick 0
                uint p1 = PushStorage(Bytes(1u, 0x20u, 0x80000u, 0u, 0UL, 0UL));
                // 网页参数 0x2000 字节：头（条数 1、填充、Shim = Offline 3）+ TLV DocumentKind（类型 7、长 4、填充、值 1 = OfflineHtmlPage）
                byte[] web = new byte[0x2000];
                BitConverter.GetBytes((ushort)1).CopyTo(web, 0);
                BitConverter.GetBytes(3u).CopyTo(web, 4);
                BitConverter.GetBytes((ushort)7).CopyTo(web, 8);
                BitConverter.GetBytes((ushort)4).CopyTo(web, 10);
                BitConverter.GetBytes(1u).CopyTo(web, 16);
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

                uint reason = *(uint*)buf;
                ulong urlSize = size >= 0x1010 ? *(ulong*)(buf + 0x1008) : 0;
                string url = Encoding.ASCII.GetString(new ReadOnlySpan<byte>(buf + 8, 0x1000)).TrimEnd('\0');
                got = $"入参 0x{p1:X} / 0x{p2:X}；Start 0x{st:X}、GetResult 0x{gr:X}、PopOutData 0x{pop.Result:X}、Read 0x{rr:X}；" +
                      $"大小 0x{size:X}、退出原因 {reason}、LastUrl \"{url}\"、LastUrlSize {urlSize}、报红 +{Red.Total - red0}";
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

            Check("离线网页小程序 0x17（ShowOfflineHtmlPage：版本 0x80000、Shim Offline）：没有网页渲染，按真值回 WindowClosed 4 + last_url http://localhost/，BioShock 条款页循环得以退出",
                "入参 0x0 / 0x0；Start 0x0、GetResult 0x0、PopOutData 0x0、Read 0x0；大小 0x1010、退出原因 4、LastUrl \"http://localhost/\"、LastUrlSize 17、报红 +0", got);
        }
    }
}

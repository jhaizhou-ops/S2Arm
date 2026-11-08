// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2A.Services;
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // 时之笛（Switch 2，0400486024DEC000）开局服务缺口第一批：nifm 101、pctl 1101、lm 3。
    //   线上格式取自时之笛 sdk 客户端代理（CmifProxy 虚表 → 发送助手的头字、数据偏移、缓冲类型）；期望值按格式与真机语义手写，不跑被测实现：
    //   - nifm IGeneralService 101（GetCurrentNetworkProfile V2）：域消息、无入数据、C 缓冲 0x1b4；本机无联网权限 = 没有当前网络 → 同命令 5 回 NoInternetConnection（2110-0300），不报红
    //   - pctl IParentalControlService 1101（CheckAgcPermissionUnderMinimumAge）：入数据 Uid 0x10、无 pid、回 1 字节；没设家长控制 → 0（游戏表里 0 = "success"），不报红
    //   - lm ILogger 3（DevNotify）：入数据 0x28 字节头、In|AutoSelect 缓冲放正文；回 0、不报红
    public static unsafe partial class Program
    {
        static uint SmSession()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            return (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
        }

        static Reply DomainCall(uint session, Msg m, int obj)
        {
            m.DomainObject = obj;
            m.Write(_tlr);
            Svc(0x21, FakeNative.CookieOf(session));
            return Reply.ParseDomain(_tlr);
        }

        [SvcCase]
        private static void ZeldaNifm101Offline()
        {
            uint sm = SmSession();
            Reply gn = Call(sm, Msg.Cmif(1, Name8("nifm:u")));
            uint nif = gn.Move.Count == 1 ? gn.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(nif, cd).Data;
            Msg cgs = Msg.Cmif(5, Bytes(0UL)); cgs.SendPid = true;
            int gs = *(int*)DomainCall(nif, cgs, root).Data;

            long red0 = Red.Total;
            byte* prof = FakeNative.Alloc(0x1b4);
            Msg m = Msg.Cmif(101); m.C.Add(((ulong)prof, 0x1b4));
            uint rc = DomainCall(nif, m, gs).Result;
            uint noNet = (300u << 9) | 110;
            Check("nifm IGeneralService 101 GetCurrentNetworkProfile(V2)，离线：结果 NoInternetConnection、不报红", $"0x{noNet:X}、红 +0", $"0x{rc:X}、红 +{Red.Total - red0}");
        }

        [SvcCase]
        private static void ZeldaPctl1101()
        {
            uint sm = SmSession();
            uint pf = Call(sm, Msg.Cmif(1, Name8("pctl"))).Move[0];
            Msg cs = Msg.Cmif(0, Bytes(0UL)); cs.SendPid = true;
            Reply r = Call(pf, cs);
            uint svc = r.Move.Count == 1 ? r.Move[0] : 0;

            long red0 = Red.Total;
            Reply a = Call(svc, Msg.Cmif(1101, Bytes(0x1122334455667788UL, 0x99AABBCCDDEEFF00UL)));
            byte status = a.Result == 0 ? a.Data[0] : (byte)0xFF;
            Check("pctl 1101 CheckAgcPermissionUnderMinimumAge，没设家长控制：结果 0、状态 0、不报红", "0x0、0、红 +0", $"0x{a.Result:X}、{status}、红 +{Red.Total - red0}");
        }

        [SvcCase]
        private static void ZeldaLm3DevNotify()
        {
            bool up = WaitFor(() => Array.IndexOf(HorizonHost.Services, "lm") >= 0, 10_000);
            uint sm = SmSession();
            uint lm = up ? Call(sm, Msg.Cmif(1, Name8("lm"))).Move[0] : 0;
            Msg ol = Msg.Cmif(0, Bytes(0UL)); ol.SendPid = true;
            Reply o = Call(lm, ol);
            uint logger = o.Move.Count == 1 ? o.Move[0] : 0;

            long red0 = Red.Total;
            byte[] text = Encoding.UTF8.GetBytes("zelda devnotify\0");
            byte* tp = FakeNative.Alloc(0x40);
            text.CopyTo(new Span<byte>(tp, text.Length));
            Msg m = Msg.Cmif(3, new byte[0x28]); m.A.Add(((ulong)tp, (ulong)text.Length)); m.X.Add((0, 0));   // In|AutoSelect：Horizon 服务端要 A 与 X 两个描述符都在、取非空的那个
            uint rc = Call(logger, m).Result;
            Check("lm ILogger 3 DevNotify（0x28 字节头 + 正文缓冲）：结果 0、不报红", "0x0、红 +0", $"0x{rc:X}、红 +{Red.Total - red0}");
        }
    }
}

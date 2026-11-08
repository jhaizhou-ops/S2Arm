// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;

namespace S2A.Services.Tests
{
    // bsd GetSockOpt / SetSockOpt 的选项长度（11-06 World War Z 离线模式进游戏 Break 2010-0221）：
    //   本机服务端模块先 getsockopt(SOL_SOCKET, SO_SNDBUF, &v, &len=4)，再把带回的 len 原样交给 setsockopt(SO_SNDBUF, 0x40000, len)。
    //   线上格式（Horizon bsd:u）：17 GetSockOpt(u32 fd, u32 level, u32 name) -> (i32 ret, u32 errno, u32 optlen, buffer<0x22>)，
    //   21 SetSockOpt(u32 fd, u32 level, u32 name, buffer<0x21>) -> (i32 ret, u32 errno)。
    //   期望按 FreeBSD 网络栈（Horizon bsd 的来源）手写，不跑被测实现：
    //   - getsockopt 带回 optlen = min(缓冲长, 选项本身长)：int 选项 4、SO_LINGER 是 struct linger 8（sooptcopyout）
    //   - setsockopt 缓冲短于选项长 → -1 EINVAL(22)（sooptcopyin 的 minlen），服务命令照常成功、不报红
    //   旧实现 GetSockOpt 不写 optlen（游戏读到 0），SetSockOpt 对 0 长缓冲抛 ArgumentOutOfRange → 服务命令失败、游戏 Break
    public static unsafe partial class Program
    {
        [SoloTest("--bsd-sockopt-len", Booted = true)]
        private static void BsdSockOptLength()
        {
            uint sm = SmSession();
            uint bsd = Call(sm, Msg.Cmif(1, Name8("bsd:u"))).Move[0];
            Msg reg = Msg.Cmif(0, new byte[0x30]);
            reg.SendPid = true;
            reg.Copy.Add(0xFFFF8001);
            Call(bsd, reg);

            byte* val = _game + 0x7900;
            const int SolSocket = 0xFFFF, SoLinger = 0x80, SoSndBuf = 0x1001;

            int udp = *(int*)Call(bsd, Msg.Cmif(2, Bytes(2, 2, 0))).Data;

            (uint Result, int Ret, int Errno, int OptLen) Get(int name, int bufLen)
            {
                new Span<byte>(val, 0x20).Fill(0xAA);
                Msg m = Msg.Cmif(17, Bytes(udp, SolSocket, name));
                m.B.Add(((ulong)val, (ulong)bufLen));
                Reply r = Call(bsd, m);
                return (r.Result, *(int*)r.Data, *(int*)(r.Data + 4), *(int*)(r.Data + 8));
            }

            (uint Result, int Ret, int Errno) Set(int name, int value, int len)
            {
                *(int*)val = value;
                Msg m = Msg.Cmif(21, Bytes(udp, SolSocket, name));
                m.A.Add(((ulong)val, (ulong)len));
                Reply r = Call(bsd, m);
                return (r.Result, *(int*)r.Data, *(int*)(r.Data + 4));
            }

            long red0 = Red.Total;

            var g = Get(SoSndBuf, 4);
            var lg = Get(SoLinger, 16);
            Check("bsd GetSockOpt 带回 optlen：SO_SNDBUF 缓冲 4 / SO_LINGER 缓冲 16",
                "结果 0x0、0/0、optlen 4 / 结果 0x0、0/0、optlen 8",
                $"结果 0x{g.Result:X}、{g.Ret}/{g.Errno}、optlen {g.OptLen} / 结果 0x{lg.Result:X}、{lg.Ret}/{lg.Errno}、optlen {lg.OptLen}");

            var empty = Set(SoSndBuf, 0x40000, 0);
            var shortLinger = Set(SoLinger, 1, 4);
            Check("bsd SetSockOpt 缓冲短于选项：SO_SNDBUF 长 0 / SO_LINGER 长 4（服务命令成功、不报红）",
                "结果 0x0、-1 errno 22 / 结果 0x0、-1 errno 22、红 +0",
                $"结果 0x{empty.Result:X}、{empty.Ret} errno {empty.Errno} / 结果 0x{shortLinger.Result:X}、{shortLinger.Ret} errno {shortLinger.Errno}、红 +{Red.Total - red0}");

            // WWZ 服务端的原序列：getsockopt 带回的 len 交给 setsockopt
            var g2 = Get(SoSndBuf, 4);
            var s2 = Set(SoSndBuf, 0x40000, g2.OptLen);
            var g3 = Get(SoSndBuf, 4);
            int now = *(int*)val;
            Check("bsd 先 GetSockOpt(SO_SNDBUF) 再按带回的 optlen SetSockOpt(SO_SNDBUF, 0x40000)，再读回",
                "set 0/0；读回 0x40000、optlen 4",
                $"set {s2.Ret}/{s2.Errno}；读回 0x{now:X}、optlen {g3.OptLen}");

            Call(bsd, Msg.Cmif(26, Bytes(udp)));
        }
    }
}

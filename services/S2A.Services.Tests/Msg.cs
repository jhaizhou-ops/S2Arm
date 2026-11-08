using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // 按 Horizon HIPC / CMIF 格式手工拼请求、解应答（与 Ryujinx IpcMessage 的解析各自独立实现，测的是两者对得上）
    public unsafe sealed class Msg
    {
        public uint Cmd;
        public byte[] Payload = [];
        public bool SendPid;
        public List<uint> Copy = new();
        public List<uint> Move = new();
        public List<(ulong Addr, ulong Size)> X = new();
        public List<(ulong Addr, ulong Size)> A = new();
        public List<(ulong Addr, ulong Size)> B = new();
        // A / B 描述符的传输模式（0 = Normal、1 = NonSecure、3 = NonDevice）：带 MapTransferAllowsNonSecure 的缓冲要 1
        //   （服务端按标志严格比对，如 hwopus 带计时的解码 B 要 1、7.0.0+ 的 DecodeInterleaved A / B 都要 1）
        public uint AMode;
        public uint BMode;
        public List<(ulong Addr, ulong Size)> C = new();
        public int Type = 4; // CmifRequest
        public int RecvListMode; // 非 0 = 指定接收列表类型（2 = 一块缓冲收全部指针缓冲），缺省按 C 个数 + 2
        public int DomainObject; // 非 0 = 域消息，发给该对象（域头 16 字节：命令 1 = SendMessage）
        public byte DomainRequestType = 1; // 2 = CloseVirtualHandle
        public List<int> InObjects = new(); // 域消息的入对象号（如 PushInData 递的 IStorage）：数据之后逐个 u32

        public static Msg Cmif(uint cmd, params byte[] payload) => new() { Cmd = cmd, Payload = payload };

        public void Write(byte* msg)
        {
            new Span<byte>(msg, 0x100).Clear();
            uint* w = (uint*)msg;
            int i = 0;
            bool hasHandles = SendPid || Copy.Count > 0 || Move.Count > 0;
            int rawWords = (16 + 16 + (DomainObject != 0 ? 16 + 4 * InObjects.Count : 0) + Payload.Length + 3) / 4;

            w[i++] = (uint)Type | (uint)X.Count << 16 | (uint)A.Count << 20 | (uint)B.Count << 24;
            w[i++] = (uint)rawWords | (uint)(RecvListMode != 0 ? RecvListMode : C.Count > 0 ? C.Count + 2 : 0) << 10 | (hasHandles ? 1u << 31 : 0);

            if (hasHandles)
            {
                w[i++] = (SendPid ? 1u : 0) | (uint)Copy.Count << 1 | (uint)Move.Count << 5;

                if (SendPid)
                {
                    w[i++] = (uint)FakeNative.GamePid;
                    w[i++] = 0;
                }

                foreach (uint h in Copy) w[i++] = h;
                foreach (uint h in Move) w[i++] = h;
            }

            for (int n = 0; n < X.Count; n++)
            {
                (ulong a, ulong s) = X[n];
                w[i++] = (uint)n | (uint)((a >> 36) & 7) << 6 | (uint)((a >> 32) & 0xF) << 12 | (uint)s << 16;
                w[i++] = (uint)a;
            }

            foreach ((ulong a, ulong s) in A) i = AB(w, i, a, s, AMode);
            foreach ((ulong a, ulong s) in B) i = AB(w, i, a, s, BMode);

            int rawStart = i * 4;
            int pos = rawStart;

            while (((ulong)msg + (ulong)pos) % 16 != 0) pos++;

            if (DomainObject != 0)
            {
                msg[pos] = DomainRequestType;
                msg[pos + 1] = (byte)InObjects.Count;                 // 入对象数
                *(ushort*)(msg + pos + 2) = (ushort)(16 + Payload.Length); // 数据长（含 SFCI 头）
                *(int*)(msg + pos + 4) = DomainObject;
                pos += 16;
            }

            *(ulong*)(msg + pos) = 0x49434653; // "SFCI"
            *(ulong*)(msg + pos + 8) = Cmd;
            Payload.CopyTo(new Span<byte>(msg + pos + 16, Payload.Length));

            if (DomainObject != 0)
            {
                // 入对象号紧跟数据（服务端按域头的数据长定位：0x10 + 数据长）
                for (int n = 0; n < InObjects.Count; n++)
                {
                    *(int*)(msg + pos + 16 + Payload.Length + 4 * n) = InObjects[n];
                }
            }

            int recvList = rawStart + rawWords * 4;

            foreach ((ulong a, ulong s) in C)
            {
                *(ulong*)(msg + recvList) = a | (s << 48);
                recvList += 8;
            }
        }

        private static int AB(uint* w, int i, ulong a, ulong s, uint mode)
        {
            w[i++] = (uint)s;
            w[i++] = (uint)a;
            w[i++] = mode | (uint)((a >> 36) & 7) << 2 | (uint)((s >> 32) & 0xF) << 24 | (uint)((a >> 32) & 0xF) << 28;
            return i;
        }
    }

    public unsafe sealed class Reply
    {
        public uint Result;
        public List<uint> Copy = new();
        public List<uint> Move = new();
        public byte* Data;

        public uint DomainOutCount;

        // 域应答：域出头 16 字节（u32 出对象数）+ SFCO 头 + 数据 + 出对象号
        public static Reply ParseDomain(byte* msg)
        {
            uint* w = (uint*)msg;
            int i = 2;

            if ((w[1] >> 31) != 0)
            {
                uint hd = w[i++];
                if ((hd & 1) != 0) i += 2;
                i += (int)(((hd >> 1) & 0xF) + ((hd >> 5) & 0xF));
            }

            i += (int)((w[0] >> 16) & 0xF) * 2;
            int pos = i * 4;

            while (((ulong)msg + (ulong)pos) % 16 != 0) pos++;

            Reply r = new() { DomainOutCount = *(uint*)(msg + pos) };

            // 句柄描述符（复制 / 移动）同非域应答
            if ((w[1] >> 31) != 0)
            {
                int j = 2;
                uint hd = w[j++];
                if ((hd & 1) != 0) j += 2;
                for (int n = 0; n < ((hd >> 1) & 0xF); n++) r.Copy.Add(w[j++]);
                for (int n = 0; n < ((hd >> 5) & 0xF); n++) r.Move.Add(w[j++]);
            }

            if (*(uint*)(msg + pos + 16) != 0x4F434653)
            {
                throw new InvalidOperationException($"域应答没有 SFCO 魔数（{*(uint*)(msg + pos + 16):X8}）");
            }

            r.Result = *(uint*)(msg + pos + 24);
            r.Data = msg + pos + 32;
            return r;
        }

        // 应答首个 X 描述符的长度（服务经 Response.PtrBuff[0].WithSize 回告）
        public static ulong FirstXSize(byte* msg)
        {
            uint* w = (uint*)msg;
            int i = 2;

            if ((w[1] >> 31) != 0)
            {
                uint hd = w[i++];
                if ((hd & 1) != 0) i += 2;
                i += (int)(((hd >> 1) & 0xF) + ((hd >> 5) & 0xF));
            }

            return ((w[0] >> 16) & 0xF) == 0 ? ulong.MaxValue : w[i] >> 16;
        }

        public static Reply Parse(byte* msg)
        {
            Reply r = new();
            uint* w = (uint*)msg;
            int i = 2;
            uint xCount = (w[0] >> 16) & 0xF;

            if ((w[1] >> 31) != 0)
            {
                uint hd = w[i++];

                if ((hd & 1) != 0) i += 2;

                for (int n = 0; n < ((hd >> 1) & 0xF); n++) r.Copy.Add(w[i++]);
                for (int n = 0; n < ((hd >> 5) & 0xF); n++) r.Move.Add(w[i++]);
            }

            i += (int)xCount * 2;
            int pos = i * 4;

            while (((ulong)msg + (ulong)pos) % 16 != 0) pos++;

            if (*(uint*)(msg + pos) != 0x4F434653) // "SFCO"
            {
                throw new InvalidOperationException($"应答没有 SFCO 魔数（{*(uint*)(msg + pos):X8}）");
            }

            r.Result = *(uint*)(msg + pos + 8);
            r.Data = msg + pos + 16;
            return r;
        }
    }
}

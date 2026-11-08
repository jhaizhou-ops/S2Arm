using System;
using System.Buffers.Binary;

namespace Ryujinx.HLE.HOS.Ipc
{
    // S2Arm: zero steady-state allocation for in-thread direct dispatch. One request / response message per game
    // thread is reused: parsed in place from the game's message buffer and written back into it, with the same layout
    // rules as the IpcMessage(ReadOnlySpan<byte>, long) constructor and GetStream / GetStreamTipc.
    partial class IpcMessage
    {
        // Raw data location inside the parsed buffer (RawData is not filled on this path)
        internal int S2ARawOffset { get; private set; }
        internal int S2ARawSize { get; private set; }

        private IpcHandleDesc _s2aHandleDesc;

        internal void S2AReset()
        {
            Type = 0;
            HandleDesc = null;
            RawData = null;
            PtrBuff.Clear();
            SendBuff.Clear();
            ReceiveBuff.Clear();
            ExchangeBuff.Clear();
            RecvListBuff.Clear();
            ObjectIds.Clear();
        }

        internal void S2AParse(ReadOnlySpan<byte> data, long cmdPtr)
        {
            S2AReset();

            uint word0 = BinaryPrimitives.ReadUInt32LittleEndian(data);
            uint word1 = BinaryPrimitives.ReadUInt32LittleEndian(data[4..]);
            int pos = 8;

            Type = (IpcMessageType)(word0 & 0xffff);

            int ptrBuffCount = (int)(word0 >> 16) & 0xf;
            int sendBuffCount = (int)(word0 >> 20) & 0xf;
            int recvBuffCount = (int)(word0 >> 24) & 0xf;
            int xchgBuffCount = (int)(word0 >> 28) & 0xf;

            int rawDataSize = (int)(word1 & 0x3ff) * 4;
            int recvListFlags = (int)(word1 >> 10) & 0xf;

            if ((word1 >> 31) != 0)
            {
                _s2aHandleDesc ??= new IpcHandleDesc([], []);
                pos = _s2aHandleDesc.S2AParse(data, pos);
                HandleDesc = _s2aHandleDesc;
            }

            for (int i = 0; i < ptrBuffCount; i++, pos += 8)
            {
                PtrBuff.Add(new IpcPtrBuffDesc(U32(data, pos), U32(data, pos + 4)));
            }

            pos = ReadBuff(data, pos, sendBuffCount, SendBuff);
            pos = ReadBuff(data, pos, recvBuffCount, ReceiveBuff);
            pos = ReadBuff(data, pos, xchgBuffCount, ExchangeBuff);

            int recvListPos = pos + rawDataSize;

            // Only CMIF has the padding requirements.
            if (Type < IpcMessageType.TipcCloseSession)
            {
                int pad0 = (int)GetPadSize16(pos + cmdPtr);

                if (rawDataSize != 0)
                {
                    rawDataSize -= pad0;
                }

                pos += pad0;
            }

            int recvListCount = recvListFlags - 2;

            if (recvListCount == 0)
            {
                recvListCount = 1;
            }
            else if (recvListCount < 0)
            {
                recvListCount = 0;
            }

            S2ARawOffset = pos;
            S2ARawSize = Math.Clamp(rawDataSize, 0, Math.Max(0, data.Length - pos));

            for (int i = 0; i < recvListCount && recvListPos + 8 <= data.Length; i++, recvListPos += 8)
            {
                RecvListBuff.Add(new IpcRecvListBuffDesc(BinaryPrimitives.ReadUInt64LittleEndian(data[recvListPos..])));
            }
        }

        private static int ReadBuff(ReadOnlySpan<byte> data, int pos, int count, System.Collections.Generic.List<IpcBuffDesc> list)
        {
            for (int i = 0; i < count; i++, pos += 12)
            {
                list.Add(new IpcBuffDesc(U32(data, pos), U32(data, pos + 4), U32(data, pos + 8)));
            }

            return pos;
        }

        private static uint U32(ReadOnlySpan<byte> data, int pos) => BinaryPrimitives.ReadUInt32LittleEndian(data[pos..]);

        // CMIF response, same layout as GetStream(cmdPtr, recvListAddr: 0); returns the length written
        internal int S2AWriteCmif(Span<byte> dst, long cmdPtr, ReadOnlySpan<byte> raw)
        {
            int handleLength = HandleDesc?.S2ASize ?? 0;
            int dataLength = (raw.Length + 3) & ~3;
            int rawLength = dataLength;
            int pad0 = (int)GetPadSize16(cmdPtr + 8 + handleLength + PtrBuff.Count * 8);
            int pad1 = 0x10 - pad0;
            int total = 8 + handleLength + PtrBuff.Count * 8 + pad0 + rawLength + pad1 + 8;

            if (total > dst.Length)
            {
                return -total;
            }

            uint word0 = (uint)Type;
            word0 |= (uint)(PtrBuff.Count & 0xf) << 16;
            word0 |= (uint)(SendBuff.Count & 0xf) << 20;
            word0 |= (uint)(ReceiveBuff.Count & 0xf) << 24;
            word0 |= (uint)(ExchangeBuff.Count & 0xf) << 28;

            uint word1 = (uint)(((dataLength + pad0 + pad1) / 4) & 0x3ff) | (2u << 10);

            if (HandleDesc != null)
            {
                word1 |= 1u << 31;
            }

            BinaryPrimitives.WriteUInt32LittleEndian(dst, word0);
            BinaryPrimitives.WriteUInt32LittleEndian(dst[4..], word1);
            int pos = 8;

            if (HandleDesc != null)
            {
                pos = HandleDesc.S2AWrite(dst, pos);
            }

            foreach (IpcPtrBuffDesc desc in PtrBuff)
            {
                BinaryPrimitives.WriteUInt32LittleEndian(dst[pos..], desc.GetWord0());
                BinaryPrimitives.WriteUInt32LittleEndian(dst[(pos + 4)..], desc.GetWord1());
                pos += 8;
            }

            dst.Slice(pos, pad0).Clear();
            pos += pad0;
            raw.CopyTo(dst[pos..]);
            pos += raw.Length;
            dst.Slice(pos, rawLength - raw.Length + pad1 + 8).Clear(); // tail padding, pad1, recvListAddr = 0
            pos += rawLength - raw.Length + pad1 + 8;

            return pos;
        }

        // TIPC response, same layout as GetStreamTipc; returns the length written
        internal int S2AWriteTipc(Span<byte> dst, ReadOnlySpan<byte> raw)
        {
            int handleLength = HandleDesc?.S2ASize ?? 0;
            int total = 8 + handleLength + raw.Length;

            if (total > dst.Length)
            {
                return -total;
            }

            uint word0 = (uint)Type;
            word0 |= (uint)(SendBuff.Count & 0xf) << 20;
            word0 |= (uint)(ReceiveBuff.Count & 0xf) << 24;
            word0 |= (uint)(ExchangeBuff.Count & 0xf) << 28;

            uint word1 = (uint)((((raw.Length + 3) & ~3) / 4) & 0x3ff);

            if (HandleDesc != null)
            {
                word1 |= 1u << 31;
            }

            BinaryPrimitives.WriteUInt32LittleEndian(dst, word0);
            BinaryPrimitives.WriteUInt32LittleEndian(dst[4..], word1);
            int pos = 8;

            if (HandleDesc != null)
            {
                pos = HandleDesc.S2AWrite(dst, pos);
            }

            raw.CopyTo(dst[pos..]);

            return pos + raw.Length;
        }
    }

    partial class IpcHandleDesc
    {
        // S2Arm: handle arrays cached per count (0..15), reused by the per-thread request message. Created on first parse only:
        // as field initializers they cost every IpcHandleDesc (each response's MakeCopy / MakeMove too) two 16-slot arrays, ~300 B
        private int[][] _s2aCopy;
        private int[][] _s2aMove;

        // S2Arm: responses with one or two handles (every MakeCopy / MakeMove call site) reuse a per-thread descriptor instead of a new
        // descriptor + params array per request (~80 B; d3 asks aoc:u for its event handle ~30 times a second). A response descriptor
        // only lives until that response is written back on the same thread (translated in place, then the message is reset).
        [ThreadStatic] private static IpcHandleDesc t_copy1, t_copy2, t_move1, t_move2;

        private static IpcHandleDesc Reused(ref IpcHandleDesc slot, bool copy, int count)
        {
            slot ??= copy ? new IpcHandleDesc(new int[count], []) : new IpcHandleDesc([], new int[count]);
            slot.HasPId = false;
            slot.PId = 0;
            return slot;
        }

        public static IpcHandleDesc MakeCopy(int handle)
        {
            IpcHandleDesc d = Reused(ref t_copy1, copy: true, 1);
            d.ToCopy[0] = handle;
            return d;
        }

        public static IpcHandleDesc MakeCopy(int handle0, int handle1)
        {
            IpcHandleDesc d = Reused(ref t_copy2, copy: true, 2);
            d.ToCopy[0] = handle0;
            d.ToCopy[1] = handle1;
            return d;
        }

        public static IpcHandleDesc MakeMove(int handle)
        {
            IpcHandleDesc d = Reused(ref t_move1, copy: false, 1);
            d.ToMove[0] = handle;
            return d;
        }

        public static IpcHandleDesc MakeMove(int handle0, int handle1)
        {
            IpcHandleDesc d = Reused(ref t_move2, copy: false, 2);
            d.ToMove[0] = handle0;
            d.ToMove[1] = handle1;
            return d;
        }

        internal int S2ASize => 4 + (HasPId ? 8 : 0) + 4 * (ToCopy.Length + ToMove.Length);

        internal int S2AParse(ReadOnlySpan<byte> data, int pos)
        {
            int word = BinaryPrimitives.ReadInt32LittleEndian(data[pos..]);
            pos += 4;

            HasPId = (word & 1) != 0;
            PId = 0;

            if (HasPId)
            {
                PId = BinaryPrimitives.ReadUInt64LittleEndian(data[pos..]);
                pos += 8;
            }

            int copyCount = (word >> 1) & 0xf;
            _s2aCopy ??= new int[16][];
            _s2aMove ??= new int[16][];
            int[] copy = _s2aCopy[copyCount] ??= new int[copyCount];

            for (int i = 0; i < copyCount; i++, pos += 4)
            {
                copy[i] = BinaryPrimitives.ReadInt32LittleEndian(data[pos..]);
            }

            int moveCount = (word >> 5) & 0xf;
            int[] move = _s2aMove[moveCount] ??= new int[moveCount];

            for (int i = 0; i < moveCount; i++, pos += 4)
            {
                move[i] = BinaryPrimitives.ReadInt32LittleEndian(data[pos..]);
            }

            ToCopy = copy;
            ToMove = move;

            return pos;
        }

        internal int S2AWrite(Span<byte> dst, int pos)
        {
            int word = HasPId ? 1 : 0;
            word |= (ToCopy.Length & 0xf) << 1;
            word |= (ToMove.Length & 0xf) << 5;

            BinaryPrimitives.WriteInt32LittleEndian(dst[pos..], word);
            pos += 4;

            if (HasPId)
            {
                BinaryPrimitives.WriteUInt64LittleEndian(dst[pos..], PId);
                pos += 8;
            }

            foreach (int h in ToCopy)
            {
                BinaryPrimitives.WriteInt32LittleEndian(dst[pos..], h);
                pos += 4;
            }

            foreach (int h in ToMove)
            {
                BinaryPrimitives.WriteInt32LittleEndian(dst[pos..], h);
                pos += 4;
            }

            return pos;
        }
    }
}

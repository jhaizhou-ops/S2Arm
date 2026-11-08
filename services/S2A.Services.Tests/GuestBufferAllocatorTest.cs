using System;
using Ryujinx.HLE.HOS.Ipc;

namespace S2A.Services.Tests
{
    internal static unsafe class GuestBufferAllocatorTest
    {
        public static void Run(Action<string, object, object> check)
        {
            // Protocol limits, including a representable start whose final byte is not.
            const ulong limit = 1UL << 39;
            check("HIPC range: last byte", true, GuestBufferAllocator.FitsDescriptor(limit - 1, 1));
            check("HIPC range: end crosses limit", false, GuestBufferAllocator.FitsDescriptor(limit - 1, 2));
            check("HIPC range: high start", false, GuestBufferAllocator.FitsDescriptor(limit, 1));
            check("HIPC range: huge size", false, GuestBufferAllocator.FitsDescriptor(0x4000, ulong.MaxValue));
            check("HIPC range: null", false, GuestBufferAllocator.FitsDescriptor(0, 1));
            foreach (int size in new[] { 0, -1 })
            {
                bool rejected = false;
                try { GuestBufferAllocator.Alloc(size); }
                catch (ArgumentOutOfRangeException) { rejected = true; }
                check($"Guest allocation rejects size {size}", true, rejected);
            }

            byte* tls = FakeNative.Alloc(0x4000);
            try
            {
                foreach (int size in new[] { 1, 0x110, 0x3fff, 0x4000, 0x4001, 0x10000, 0x18000 })
                {
                    byte* buffer = FakeNative.Alloc(size);
                    try
                    {
                        buffer[0] = 0x31;
                        buffer[size - 1] = 0x72;
                        check($"Guest {size}: last byte writable", (byte)0x72, buffer[size - 1]);
                        check($"Guest {size}: 16KiB aligned", 0UL, (ulong)buffer % 0x4000);
                        // Encode using the independent fixture writer; decode with the
                        // actual service parser. A high malloc pointer loses its upper bits.
                        Msg msg = Msg.Cmif(0);
                        msg.A.Add(((ulong)buffer, (ulong)size));
                        msg.B.Add(((ulong)buffer, (ulong)size));
                        msg.X.Add(((ulong)buffer, 1));
                        msg.Write(tls);
                        IpcMessage decoded = new(new ReadOnlySpan<byte>(tls, 0x100), (long)tls);
                        check($"Guest {size}: HIPC A roundtrip", (ulong)buffer, decoded.SendBuff[0].Position);
                        check($"Guest {size}: HIPC B roundtrip", (ulong)buffer, decoded.ReceiveBuff[0].Position);
                        check($"Guest {size}: HIPC X roundtrip", (ulong)buffer, decoded.PtrBuff[0].Position);
                        check($"Guest {size}: HIPC size roundtrip", (ulong)size, decoded.SendBuff[0].Size);
                    }
                    finally { FakeNative.Free(buffer); }
                }
            }
            finally { FakeNative.Free(tls); }
        }
    }
}

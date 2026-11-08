using System;
using System.Text;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static void IpcAllocationTest()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint hid = Call(sm, Msg.Cmif(1, Name8("hid"))).Move[0];
            MeasureAlloc("hid EndPermitVibrationSession 收尾保护", hid, () => Msg.Cmif(210));
            double bytes = _alloc[^1].Bytes;
            Check("真实 HID IPC 在所有权保护下每请求分配字节", "0", bytes.ToString(System.Globalization.CultureInfo.InvariantCulture));
            FakeNative.HandleClose(hid); FakeNative.HandleClose(sm);
        }
    }
}

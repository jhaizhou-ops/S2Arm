using System.Runtime.CompilerServices;

namespace Ryujinx.HLE.HOS.Tamper
{
    // S2Arm：金手指的数值运算不用 C# dynamic（NativeAOT 不支持运行时绑定，iOS / Mac 包里一执行就抛异常）。
    // 操作数宽度只有 1 / 2 / 4 / 8 字节、全是无符号整数：转成 64 位算，写回时按宽度截断，与原 dynamic 写法结果一致。
    static class TamperNum
    {
        public static ulong ToU64<T>(T value) where T : unmanaged => Unsafe.SizeOf<T>() switch
        {
            1 => Unsafe.As<T, byte>(ref value),
            2 => Unsafe.As<T, ushort>(ref value),
            4 => Unsafe.As<T, uint>(ref value),
            _ => Unsafe.As<T, ulong>(ref value),
        };

        public static T FromU64<T>(ulong value) where T : unmanaged
        {
            T result = default;
            switch (Unsafe.SizeOf<T>())
            {
                case 1: Unsafe.As<T, byte>(ref result) = (byte)value; break;
                case 2: Unsafe.As<T, ushort>(ref result) = (ushort)value; break;
                case 4: Unsafe.As<T, uint>(ref result) = (uint)value; break;
                default: Unsafe.As<T, ulong>(ref result) = value; break;
            }
            return result;
        }
    }
}

using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Common
{
    public static class BinaryReaderExtensions
    {
        public static T ReadStruct<T>(this BinaryReader reader) where T : unmanaged
        {
            // S2Arm: read straight into the value; ReadBytes allocated an array on every call (every IPC argument struct)
            T value = default;
            Span<byte> bytes = MemoryMarshal.AsBytes(new Span<T>(ref value));

            if (reader.Read(bytes) != bytes.Length)
            {
                throw new EndOfStreamException();
            }

            return value;
        }
    }
}

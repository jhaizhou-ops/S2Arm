using Ryujinx.Common;
using Ryujinx.Common.Memory;
using Ryujinx.Common.Utilities;
using Ryujinx.HLE.HOS.Services.SurfaceFlinger.Types;
using System;
using System.Buffers;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace Ryujinx.HLE.HOS.Services.SurfaceFlinger
{
    sealed class Parcel : IDisposable
    {
        // S2Arm: pooled array + length instead of a MemoryOwner object, so per-thread parcels can be re-initialised per transaction
        private byte[] _raw;
        private int _rawLength;

        private Span<byte> Raw => _raw.AsSpan(0, _rawLength);

        private ref ParcelHeader Header => ref MemoryMarshal.Cast<byte, ParcelHeader>(Raw)[0];

        private Span<byte> Payload => Raw.Slice((int)Header.PayloadOffset, (int)Header.PayloadSize);

        private Span<byte> Objects => Raw.Slice((int)Header.ObjectOffset, (int)Header.ObjectsSize);

        private int _payloadPosition;
        private int _objectPosition;

        private bool _isDisposed;

        [ThreadStatic]
        private static Parcel _threadReader;

        [ThreadStatic]
        private static Parcel _threadWriter;

        private Parcel()
        {
        }

        public Parcel(ReadOnlySpan<byte> data)
        {
            InitRead(data);
        }

        public Parcel(uint payloadSize, uint objectsSize)
        {
            InitWrite(payloadSize, objectsSize);
        }

        /// <summary>
        /// S2Arm: per-thread input parcel re-initialised from <paramref name="data"/> (binder transactions run twice a frame);
        /// valid until the next call on the same thread, must not be disposed.
        /// </summary>
        public static Parcel ReuseForRead(ReadOnlySpan<byte> data)
        {
            Parcel parcel = _threadReader ??= new Parcel();

            parcel.InitRead(data);

            return parcel;
        }

        /// <summary>
        /// S2Arm: per-thread output parcel, see <see cref="ReuseForRead"/>.
        /// </summary>
        public static Parcel ReuseForWrite(uint payloadSize, uint objectsSize)
        {
            Parcel parcel = _threadWriter ??= new Parcel();

            parcel.InitWrite(payloadSize, objectsSize);

            return parcel;
        }

        private void Rent(int length)
        {
            if (_raw == null || _raw.Length < length)
            {
                if (_raw != null)
                {
                    ArrayPool<byte>.Shared.Return(_raw);
                }

                _raw = ArrayPool<byte>.Shared.Rent(length);
            }

            _rawLength = length;
            _payloadPosition = 0;
            _objectPosition = 0;
            _isDisposed = false;
        }

        private void InitRead(ReadOnlySpan<byte> data)
        {
            Rent(data.Length);

            data.CopyTo(Raw);
        }

        private void InitWrite(uint payloadSize, uint objectsSize)
        {
            uint headerSize = (uint)Unsafe.SizeOf<ParcelHeader>();

            Rent(checked((int)BitUtils.AlignUp<uint>(headerSize + payloadSize + objectsSize, 4)));

            Raw.Clear();

            Header.PayloadSize = payloadSize;
            Header.ObjectsSize = objectsSize;
            Header.PayloadOffset = headerSize;
            Header.ObjectOffset = Header.PayloadOffset + Header.ObjectsSize;
        }

        public string ReadInterfaceToken()
        {
            // Ignore the policy flags
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            int strictPolicy = ReadInt32();
#pragma warning restore IDE0059

            return ReadString16();
        }

        /// <summary>
        /// S2Arm: <see cref="ReadInterfaceToken"/> compared in place; the token string is only built on mismatch (for the log).
        /// </summary>
        public bool ReadInterfaceToken(string expected, out string actual)
        {
            ReadInt32(); // Ignore the policy flags

            int size = ReadInt32();

            if (size < 0)
            {
                actual = string.Empty;

                return expected.Length == 0;
            }

            ReadOnlySpan<byte> data = ReadInPlace((size + 1) * 2)[..(size * 2)];

            if (MemoryMarshal.Cast<byte, char>(data).SequenceEqual(expected))
            {
                actual = expected;

                return true;
            }

            actual = Encoding.Unicode.GetString(data);

            return false;
        }

        public string ReadString16()
        {
            int size = ReadInt32();

            if (size < 0)
            {
                return string.Empty;
            }

            ReadOnlySpan<byte> data = ReadInPlace((size + 1) * 2);

            // Return the unicode string without the last character (null terminator)
            return Encoding.Unicode.GetString(data[..(size * 2)]);
        }

        public int ReadInt32() => ReadUnmanagedType<int>();
        public uint ReadUInt32() => ReadUnmanagedType<uint>();
        public bool ReadBoolean() => ReadUnmanagedType<uint>() != 0;
        public long ReadInt64() => ReadUnmanagedType<long>();
        public ulong ReadUInt64() => ReadUnmanagedType<ulong>();

        public T ReadFlattenable<T>() where T : unmanaged, IFlattenable
        {
            long flattenableSize = ReadInt64();

            T result = new();

            Debug.Assert(flattenableSize == result.GetFlattenedSize());

            result.Unflatten(this);

            return result;
        }

        public T ReadUnmanagedType<T>() where T : unmanaged
        {
            ReadOnlySpan<byte> data = ReadInPlace(Unsafe.SizeOf<T>());

            return MemoryMarshal.Cast<byte, T>(data)[0];
        }

        public ReadOnlySpan<byte> ReadInPlace(int size)
        {
            ReadOnlySpan<byte> result = Payload.Slice(_payloadPosition, size);

            _payloadPosition += BitUtils.AlignUp(size, 4);

            return result;
        }

        [StructLayout(LayoutKind.Sequential, Size = 0x28)]
        private struct FlatBinderObject
        {
            public int Type;
            public int Flags;
            public long BinderId;
            public long Cookie;

            private byte _serviceNameStart;

            public Span<byte> ServiceName => MemoryMarshal.CreateSpan(ref _serviceNameStart, 0x8);
        }

        public void WriteObject<T>(T obj, string serviceName) where T : IBinder
        {
            FlatBinderObject flatBinderObject = new()
            {
                Type = 2,
                Flags = 0,
                BinderId = HOSBinderDriverServer.GetBinderId(obj),
            };

            Encoding.ASCII.GetBytes(serviceName).CopyTo(flatBinderObject.ServiceName);

            WriteUnmanagedType(ref flatBinderObject);

            // TODO: figure out what this value is

            Span<byte> fourBytes = stackalloc byte[4];

            WriteInplaceObject(fourBytes);
        }

        public AndroidStrongPointer<T> ReadStrongPointer<T>() where T : unmanaged, IFlattenable
        {
            bool hasObject = ReadBoolean();

            if (hasObject)
            {
                T obj = ReadFlattenable<T>();

                return new AndroidStrongPointer<T>(obj);
            }
            else
            {
                return new AndroidStrongPointer<T>();
            }
        }

        public void WriteStrongPointer<T>(ref AndroidStrongPointer<T> value) where T : unmanaged, IFlattenable
        {
            WriteBoolean(!value.IsNull);

            if (!value.IsNull)
            {
                WriteFlattenable<T>(ref value.Object);
            }
        }

        public void WriteFlattenable<T>(ref T value) where T : unmanaged, IFlattenable
        {
            WriteInt64(value.GetFlattenedSize());

            value.Flatten(this);
        }

        public void WriteStatus(Status status) => WriteUnmanagedType(ref status);
        public void WriteBoolean(bool value) => WriteUnmanagedType(ref value);
        public void WriteInt32(int value) => WriteUnmanagedType(ref value);
        public void WriteUInt32(uint value) => WriteUnmanagedType(ref value);
        public void WriteInt64(long value) => WriteUnmanagedType(ref value);
        public void WriteUInt64(ulong value) => WriteUnmanagedType(ref value);

        public void WriteUnmanagedSpan<T>(ReadOnlySpan<T> value) where T : unmanaged
        {
            WriteInplace(MemoryMarshal.Cast<T, byte>(value));
        }

        public void WriteUnmanagedType<T>(ref T value) where T : unmanaged
        {
            WriteInplace(SpanHelpers.AsByteSpan(ref value));
        }

        public void WriteInplace(ReadOnlySpan<byte> data)
        {
            Span<byte> result = Payload.Slice(_payloadPosition, data.Length);

            data.CopyTo(result);

            _payloadPosition += BitUtils.AlignUp(data.Length, 4);
        }

        public void WriteInplaceObject(ReadOnlySpan<byte> data)
        {
            Span<byte> result = Objects.Slice(_objectPosition, data.Length);

            data.CopyTo(result);

            _objectPosition += BitUtils.AlignUp(data.Length, 4);
        }

        private void UpdateHeader()
        {
            uint headerSize = (uint)Unsafe.SizeOf<ParcelHeader>();

            Header.PayloadSize = (uint)_payloadPosition;
            Header.ObjectsSize = (uint)_objectPosition;
            Header.PayloadOffset = headerSize;
            Header.ObjectOffset = Header.PayloadOffset + Header.PayloadSize;
        }

        public ReadOnlySpan<byte> Finish()
        {
            UpdateHeader();

            return Raw[..(int)(Header.PayloadSize + Header.ObjectsSize + Unsafe.SizeOf<ParcelHeader>())];
        }

        public void Dispose()
        {
            if (!_isDisposed)
            {
                _isDisposed = true;

                ArrayPool<byte>.Shared.Return(_raw);

                _raw = null;
            }
        }
    }
}

#nullable enable
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Common.Memory
{
    /// <summary>
    /// An <see cref="IMemoryOwner{T}"/> implementation with an embedded length and fast <see cref="Span{T}"/>
    /// accessor, with memory allocated from <see cref="ArrayPooling"/>.
    /// </summary>
    /// <typeparam name="T">The type of item to store.</typeparam>
    public sealed class MemoryOwner<T> : IMemoryOwner<T>
    {
        private static class ArrayPooling
        {
            public class Holder(T[]? array = null) : IComparable<Holder>, IComparable<int>
            {
                public int SkipCount;
                public readonly T[]? Array = array;

                public int CompareTo(Holder? other)
                {
                    return Array!.Length.CompareTo(other!.Array!.Length);
                }
                
                public int CompareTo(int other)
                {
                    int self = Array!.Length;

                    if (self < other)
                    {
                        SkipCount++;
                        return -1;
                    }

                    if (self > other * 4)
                    {
                        return 1;
                    }
                    
                    return 0;
                }
            }
            
            // ReSharper disable once StaticMemberInGenericType
            private static int _maxCacheCount = 50;
            
            private const int MaxSkipCount = 50;
            // Per-T limits cover cached array element storage; outstanding rentals are not cached.
            private const long MaxCachedBytes = 64L * 1024 * 1024;
            private const int MaxArraysPerLength = 32;
            private static long _cachedBytes;
        
            static readonly List<Holder> _pool = new();
            
            // ReSharper disable once StaticMemberInGenericType
            static readonly Lock _lock = new();
            
            private static int BinarySearch(List<Holder> list, int size)
            {
                int min = 0;
                int max = list.Count-1;

                while (min <= max)
                {
                    int mid = (min + max) / 2;
                    int comparison = list[mid].CompareTo(size);
                    if (comparison == 0)
                    {
                        return mid;
                    }
                    if (comparison < 0)
                    {
                        min = mid+1;
                    }
                    else
                    {
                        max = mid-1;
                    }
                }
                return ~min;
            }

            public static T[] Get(int minimumSize)
            {
                lock (_lock)
                {
                    int index = BinarySearch(_pool, minimumSize);

                    if (index >= 0)
                    {
                        Holder holder = _pool[index];
                        
                        _pool.Remove(holder);
                        _cachedBytes -= (long)holder.Array!.Length * Unsafe.SizeOf<T>();
                        return holder.Array!;
                    }

                    S2APoolStat.Note(1, (long)minimumSize * System.Runtime.CompilerServices.Unsafe.SizeOf<T>());   // S2A：池没命中、新分配
                    return new T[minimumSize];
                }
            }

            public static void Return(T[] array)
            {

                lock (_lock)
                {
                    long bytes = (long)array.Length * Unsafe.SizeOf<T>();
                    if (bytes > MaxCachedBytes - _cachedBytes)
                    {
                        return;
                    }

                    Holder holder = new(array);
                    int i = _pool.BinarySearch(holder);
                    if (i >= 0)
                    {
                        int first = i, last = i;
                        while (first > 0 && _pool[first - 1].Array!.Length == array.Length) first--;
                        while (last + 1 < _pool.Count && _pool[last + 1].Array!.Length == array.Length) last++;
                        if (last - first + 1 >= MaxArraysPerLength)
                        {
                            return;
                        }
                    }

                    _pool.Insert(i < 0 ? ~i : i, holder);
                    _cachedBytes += bytes;

                    if (_pool.Count >= _maxCacheCount)
                    {
                        for (int index = 0; index < _pool.Count; index++)
                        {
                            Holder h = _pool[index];

                            if (h.SkipCount >= MaxSkipCount)
                            {
                                _pool.Remove(h);
                                _cachedBytes -= (long)h.Array!.Length * Unsafe.SizeOf<T>();
                                index--;
                            }
                        }
                        
                        _maxCacheCount = _pool.Count * 2;
                    }
                }
            }
        }
        
        private readonly int _length;
        private T[]? _array;
        private S2ANativeBlock<T>? _native;   // S2A：大块原生暂存（S2A_MO_NATIVE=1），与 _array 二选一

        /// <summary>
        /// Initializes a new instance of the <see cref="MemoryOwner{T}"/> class with the specified parameters.
        /// </summary>
        /// <param name="length">The length of the new memory buffer to use</param>
        private MemoryOwner(int length)
        {
            _length = length;
            if (S2ANativeBlock<T>.Eligible(length) && S2ANativeBlock<T>.TryAlloc(length) is { } nb)
            {
                _native = nb;
                return;
            }
            _array = ArrayPooling.Get(length);
        }

        /// <summary>
        /// Creates a new <see cref="MemoryOwner{T}"/> instance with the specified length.
        /// </summary>
        /// <param name="length">The length of the new memory buffer to use</param>
        /// <returns>A <see cref="MemoryOwner{T}"/> instance of the requested length</returns>
        /// <exception cref="ArgumentOutOfRangeException">Thrown when <paramref name="length"/> is not valid</exception>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static MemoryOwner<T> Rent(int length) => new(length);

        /// <summary>
        /// Creates a new <see cref="MemoryOwner{T}"/> instance with the specified length and the content cleared.
        /// </summary>
        /// <param name="length">The length of the new memory buffer to use</param>
        /// <returns>A <see cref="MemoryOwner{T}"/> instance of the requested length and the content cleared</returns>
        /// <exception cref="ArgumentOutOfRangeException">Thrown when <paramref name="length"/> is not valid</exception>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static MemoryOwner<T> RentCleared(int length)
        {
            MemoryOwner<T> result = new(length);

            result.Span.Clear();

            return result;
        }

        /// <summary>
        /// Creates a new <see cref="MemoryOwner{T}"/> instance with the content copied from the specified buffer.
        /// </summary>
        /// <param name="buffer">The buffer to copy</param>
        /// <returns>A <see cref="MemoryOwner{T}"/> instance with the same length and content as <paramref name="buffer"/></returns>
        public static MemoryOwner<T> RentCopy(ReadOnlySpan<T> buffer)
        {
            MemoryOwner<T> result = new(buffer.Length);

            buffer.CopyTo(result.Span);

            return result;
        }

        /// <summary>
        /// Gets the number of items in the current instance.
        /// </summary>
        public int Length
        {
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            get => _length;
        }

        /// <inheritdoc/>
        public Memory<T> Memory
        {
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            get
            {
                T[]? array = _array;

                if (array is null)
                {
                    if (_native is { } nb)
                    {
                        return nb.Memory;
                    }

                    ThrowObjectDisposedException();
                }

                return new(array, 0, _length);
            }
        }

        /// <summary>
        /// Gets a <see cref="Span{T}"/> wrapping the memory belonging to the current instance.
        /// </summary>
        /// <remarks>
        /// Uses a trick made possible by the .NET 6+ runtime array layout.
        /// </remarks>
        public Span<T> Span
        {
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            get
            {
                T[]? array = _array;

                if (array is null)
                {
                    if (_native is { } nb)
                    {
                        return nb.GetSpan();
                    }

                    ThrowObjectDisposedException();
                }

                ref T firstElementRef = ref MemoryMarshal.GetArrayDataReference(array);

                return MemoryMarshal.CreateSpan(ref firstElementRef, _length);
            }
        }

        /// <inheritdoc/>
        public void Dispose()
        {
            T[]? array = Interlocked.Exchange(ref _array, null);

            if (array is not null)
            {
                ArrayPooling.Return(array);
            }

            Interlocked.Exchange(ref _native, null)?.Free();
        }

        /// <summary>
        /// Throws an <see cref="ObjectDisposedException"/> when <see cref="_array"/> is <see langword="null"/>.
        /// </summary>
        [DoesNotReturn]
        private static void ThrowObjectDisposedException()
        {
            throw new ObjectDisposedException(nameof(MemoryOwner<T>), "The buffer has already been disposed.");
        }
    }

    // S2A：MemoryOwner 大块改原生暂存（原生层 10-24，S2A_MO_NATIVE=1，缺省关——性能取舍，真机达标再翻）。
    // 大对象堆几乎全是贴图转格式 / 解码 / 上传暂存的 byte[]（2048²×4 等），读盘段把大对象堆顶到 400 MB、gen2 才清，且 GC 段只能放低区。
    // 非托管 T 且 ≥ 85000 字节（进大对象堆的门槛）的租用改从宿主窗口尾部取（原生层 s2a_tail_map，标签 247「托管大块暂存」），Dispose 即还。
    // 尾部放不下：退回托管数组并报红（不挤 Metal 的低区）；没 Dispose 就被回收：报红、不还（漏还是调用方的错，不加兜底）
    internal sealed unsafe class S2ANativeBlock<T> : MemoryManager<T>
    {
        private static readonly delegate* unmanaged<ulong, int, int, nint> _map;
        private static readonly delegate* unmanaged<nint, ulong, int, void> _unmap;
        private static readonly bool _on;
        private const int User = 5 | 0x100;   // S2A_TAIL_MO | S2A_TAIL_ONLY（runtime/src/native.h）
        private const int UserFree = 5;
        private static long _fallN, _leakN, _leakBytes;

        static S2ANativeBlock()
        {
            if (Environment.GetEnvironmentVariable("S2A_MO_NATIVE") != "1" || RuntimeHelpers.IsReferenceOrContainsReferences<T>())
            {
                return;
            }
            nint h = NativeLibrary.GetMainProgramHandle();
            if (NativeLibrary.TryGetExport(h, "s2a_tail_map", out nint m) && NativeLibrary.TryGetExport(h, "s2a_tail_unmap", out nint u))
            {
                _map = (delegate* unmanaged<ulong, int, int, nint>)m;
                _unmap = (delegate* unmanaged<nint, ulong, int, void>)u;
                _on = true;
            }
            else
            {
                Console.Error.WriteLine("[分配·原生] 【红】S2A_MO_NATIVE=1 但主程序没有 s2a_tail_map 导出，MemoryOwner 照旧走托管数组");
            }
        }

        private nint _ptr;
        private readonly int _length;
        private readonly ulong _bytes;

        private S2ANativeBlock(nint ptr, int length, ulong bytes)
        {
            _ptr = ptr;
            _length = length;
            _bytes = bytes;
        }

        public static bool Eligible(int length) => _on && (long)length * Unsafe.SizeOf<T>() >= 85000;

        public static S2ANativeBlock<T>? TryAlloc(int length)
        {
            ulong bytes = (ulong)length * (ulong)Unsafe.SizeOf<T>();
            nint p = _map(bytes, User, 3);   // PROT_READ | PROT_WRITE
            if (p != 0)
            {
                return new S2ANativeBlock<T>(p, length, bytes);
            }
            long n = Interlocked.Increment(ref _fallN);
            if ((n & (n - 1)) == 0)
            {
                Console.Error.WriteLine($"[分配·原生] 【红】窗口尾部放不下 MemoryOwner 原生块（本次 {bytes} 字节），退回托管数组：第 {n} 次");
            }
            return null;
        }

        public void Free()
        {
            nint p = Interlocked.Exchange(ref _ptr, 0);
            if (p != 0)
            {
                _unmap(p, _bytes, UserFree);
                GC.SuppressFinalize(this);
            }
        }

        ~S2ANativeBlock()
        {
            if (_ptr == 0)
            {
                return;
            }
            long n = Interlocked.Increment(ref _leakN);
            long b = Interlocked.Add(ref _leakBytes, (long)_bytes);
            if ((n & (n - 1)) == 0)
            {
                Console.Error.WriteLine($"[分配·原生] 【红】MemoryOwner 原生块没 Dispose 就被回收（不还，按漏报）：累计 {n} 块 {b / 1048576.0:F1} MB，本块 {_bytes} 字节");
            }
        }

        public override Span<T> GetSpan()
        {
            nint p = _ptr;
            if (p == 0)
            {
                throw new ObjectDisposedException(nameof(MemoryOwner<T>), "The buffer has already been disposed.");
            }
            return new Span<T>((void*)p, _length);
        }

        public override MemoryHandle Pin(int elementIndex = 0) => new((byte*)_ptr + (long)elementIndex * Unsafe.SizeOf<T>());

        public override void Unpin()
        {
        }

        protected override void Dispose(bool disposing)
        {
        }
    }

    // S2A 诊断（帧率能耗线 10-22，S2A_ALLOC_TRACE=1 时生效）：两个数据池没接住、只能新分配的次数与字节——
    // 种类 1 = MemoryOwner 池没命中（贴图转格式等），2 = ThreadedRenderer 环形池（8 MB）放不下走 ToArray（缓冲上传等）。每 10 秒打一行累计
    public static class S2APoolStat
    {
        public static readonly bool On = System.Environment.GetEnvironmentVariable("S2A_ALLOC_TRACE") == "1";
        private static long _n1, _b1, _n2, _b2, _last, _stacks;
        public static void Note(int kind, long bytes)
        {
            if (!On) return;
            if (kind == 1)
            {
                long n = System.Threading.Interlocked.Increment(ref _n1); System.Threading.Interlocked.Add(ref _b1, bytes);
                // 第 2 的幂次次缺口（前 10 次）打调用栈：查谁每帧租大数组又没命中
                if ((n & (n - 1)) == 0 && System.Threading.Interlocked.Increment(ref _stacks) <= 10)
                    System.Console.Error.WriteLine($"[分配·池] MemoryOwner 没命中第 {n} 次（{bytes} 字节）：{new System.Diagnostics.StackTrace(2, false).ToString().Replace(System.Environment.NewLine, " ← ")}");
            }
            else { System.Threading.Interlocked.Increment(ref _n2); System.Threading.Interlocked.Add(ref _b2, bytes); }
            long now = System.Diagnostics.Stopwatch.GetTimestamp(), last = System.Threading.Volatile.Read(ref _last);
            if (now - last < System.Diagnostics.Stopwatch.Frequency * 10 || System.Threading.Interlocked.CompareExchange(ref _last, now, last) != last) return;
            System.Console.Error.WriteLine($"[分配·池] 累计：MemoryOwner 池没命中 {_n1} 次 {_b1 / 1048576.0:F1} MB；渲染命令环形池放不下走 ToArray {_n2} 次 {_b2 / 1048576.0:F1} MB");
        }
    }
}

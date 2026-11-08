using System;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Gpu.Shader.HashTable
{
    /// <summary>
    /// Partitioned hash table.
    /// </summary>
    /// <remarks>
    /// Finds stored data that is a prefix of data of unknown length (shader code in guest memory).
    /// S2Arm: upstream kept, for every stored size, a "partial" entry for the prefix of every longer stored entry, so it could
    /// binary search the sizes; that is entries x distinct sizes (Animal Crossing: 9.4k shaders, 1440 sizes, 2.8M partial
    /// entries, ~200 MB resident and seconds of boot). Partials are now only kept at power of two checkpoints, each with the
    /// sizes of the entries ending before the next checkpoint: entries x log2(max size) memory, one probe per checkpoint and
    /// per candidate size on lookup.
    /// </remarks>
    /// <typeparam name="T"></typeparam>
    public class PartitionedHashTable<T>
    {
        /// <summary>
        /// Smallest checkpoint size; checkpoint k is at <c>FirstCheckpoint &lt;&lt; k</c> bytes.
        /// </summary>
        private const int FirstCheckpoint = 128;

        /// <summary>
        /// Stored (full) entry. Entries with the same size and hash are chained.
        /// </summary>
        private sealed class Entry
        {
            public readonly byte[] Data;
            public readonly T Item;
            public Entry Next;

            public Entry(byte[] data, T item)
            {
                Data = data;
                Item = item;
            }
        }

        /// <summary>
        /// Full entries by (size, hash of the data).
        /// </summary>
        private readonly Dictionary<(int Size, uint Hash), Entry> _entries = [];

        /// <summary>
        /// Distinct sizes of the entries smaller than or equal to the first checkpoint, ascending.
        /// </summary>
        private readonly List<int> _rootSizes = [];

        /// <summary>
        /// Checkpoints by (checkpoint index, hash of the prefix with the checkpoint size). Present when at least one entry
        /// larger than the checkpoint has that prefix; the value lists (ascending, or null if none) the distinct sizes of those
        /// entries that end at or before the next checkpoint. Hash collisions only add candidates: matches are verified on the data.
        /// </summary>
        private readonly Dictionary<(int Index, uint Hash), List<int>> _checkpoints = [];

        /// <summary>
        /// Adds a new item to the table.
        /// </summary>
        /// <param name="data">Data</param>
        /// <param name="item">Item associated with the data</param>
        public void Add(byte[] data, T item)
        {
            GetOrAdd(data, item);
        }

        /// <summary>
        /// Gets an existing item from the table, or adds a new one if not present.
        /// </summary>
        /// <param name="data">Data</param>
        /// <param name="item">Item associated with the data</param>
        /// <returns>Existing item, or <paramref name="item"/> if not present</returns>
        public T GetOrAdd(byte[] data, T item)
        {
            HashState hashState = new();
            hashState.Initialize();

            int index = 0;
            (int, uint) lastKey = default;

            for (int checkpoint = FirstCheckpoint; checkpoint < data.Length; checkpoint <<= 1, index++)
            {
                ReadOnlySpan<byte> prefix = new ReadOnlySpan<byte>(data)[..checkpoint];
                hashState.Continue(prefix);
                lastKey = (index, hashState.Finalize(prefix));
                _checkpoints.TryAdd(lastKey, null);
            }

            hashState.Continue(data);
            uint hash = hashState.Finalize(data);

            if (_entries.TryGetValue((data.Length, hash), out Entry head))
            {
                for (Entry entry = head; entry != null; entry = entry.Next)
                {
                    if (entry.Data.AsSpan().SequenceEqual(data))
                    {
                        return entry.Item;
                    }
                }

                head.Next = new Entry(data, item) { Next = head.Next };
                return item;
            }

            _entries.Add((data.Length, hash), new Entry(data, item));

            // Candidate size, on the root list or on the last checkpoint before the end of the data
            if (index == 0)
            {
                InsertSorted(_rootSizes, data.Length);
            }
            else
            {
                List<int> sizes = _checkpoints[lastKey] ??= [];
                InsertSorted(sizes, data.Length);
            }

            return item;
        }

        private static void InsertSorted(List<int> sizes, int size)
        {
            int position = sizes.BinarySearch(size);

            if (position < 0)
            {
                sizes.Insert(~position, size);
            }
        }

        /// <summary>
        /// Tries to find an item on the table.
        /// </summary>
        /// <param name="dataAccessor">Data accessor</param>
        /// <param name="item">The item on the table, if found, otherwise unmodified</param>
        /// <param name="data">The data on the table, if found, otherwise unmodified</param>
        /// <returns>True if the item was found on the table, false otherwise</returns>
        public bool TryFindItem(IDataAccessor dataAccessor, out T item, out byte[] data)
        {
            Lookup lookup = new(dataAccessor);
            item = default;
            data = null;

            // When a stored entry is a prefix of another one and both match, the longest wins (upstream's answer depended on
            // where its binary search over the sizes landed); the walk continues while a checkpoint says longer entries share the prefix
            FindInSizes(ref lookup, _rootSizes, ref item, ref data);

            for (int index = 0, checkpoint = FirstCheckpoint; checkpoint > 0; index++, checkpoint <<= 1)
            {
                // Walking the checkpoints in ascending order: no entry larger than this checkpoint has this prefix
                if (!lookup.TryHash(checkpoint, out uint hash) || !_checkpoints.TryGetValue((index, hash), out List<int> sizes))
                {
                    break;
                }

                if (sizes != null)
                {
                    FindInSizes(ref lookup, sizes, ref item, ref data);
                }
            }

            return data != null;
        }

        /// <summary>
        /// Finds the longest entry of the given sizes (ascending) matching the data, keeping the previous match if none.
        /// </summary>
        private void FindInSizes(ref Lookup lookup, List<int> sizes, ref T item, ref byte[] data)
        {
            foreach (int size in sizes)
            {
                if (!lookup.TryHash(size, out uint hash))
                {
                    break;
                }

                if (_entries.TryGetValue((size, hash), out Entry entry))
                {
                    ReadOnlySpan<byte> span = lookup.Span[..size];

                    for (; entry != null; entry = entry.Next)
                    {
                        if (span.SequenceEqual(entry.Data))
                        {
                            item = entry.Item;
                            data = entry.Data;
                            break;
                        }
                    }
                }
            }
        }

        /// <summary>
        /// Data of unknown length read on demand, with the hash of its prefixes computed incrementally.
        /// </summary>
        /// <remarks>
        /// Prefix sizes must be requested in ascending order (sizes on a list, then the next checkpoint, are ascending).
        /// </remarks>
        private ref struct Lookup
        {
            private readonly IDataAccessor _dataAccessor;
            private HashState _hashState;
            private bool _exhausted;

            public ReadOnlySpan<byte> Span;

            public Lookup(IDataAccessor dataAccessor)
            {
                _dataAccessor = dataAccessor;
                _hashState = new HashState();
                _hashState.Initialize();
                _exhausted = false;
                Span = ReadOnlySpan<byte>.Empty;
            }

            /// <summary>
            /// Hashes the prefix with the given size.
            /// </summary>
            /// <returns>False if the data is smaller than <paramref name="size"/></returns>
            public bool TryHash(int size, out uint hash)
            {
                if (Span.Length < size && !_exhausted)
                {
                    // Read ahead geometrically: one read per doubling instead of one per candidate size
                    int length = Math.Max(size, Span.Length * 2);
                    ReadOnlySpan<byte> span = _dataAccessor.GetSpan(0, length);
                    _exhausted = span.Length < length;
                    Span = span;
                }

                if (Span.Length < size)
                {
                    hash = 0;
                    return false;
                }

                ReadOnlySpan<byte> prefix = Span[..size];
                _hashState.Continue(prefix);
                hash = _hashState.Finalize(prefix);
                return true;
            }
        }
    }
}

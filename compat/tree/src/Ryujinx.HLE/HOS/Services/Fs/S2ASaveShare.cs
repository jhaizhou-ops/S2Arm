using LibHac.Common;
using LibHac.Fs;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Fs
{
    // S2Arm: opening a save data file system that the application already has open hands back the same underlying file
    // system instead of opening it again. A directory save data file system re-synchronizes its working copy from the
    // committed copy every time it is opened, so a second open silently wiped the uncommitted changes of the mount that
    // was still open (10-26 census Two Point Hospital: keeps one mount open for the whole session, mounts the same save
    // again around each save step; the directories it had created on the first mount vanished, CreateFile under them
    // failed, and it wrote through the null file object). Every mount of a save sees one view, as on the console.
    static class S2ASaveShare
    {
        private sealed class Entry
        {
            public SharedRef<LibHac.FsSrv.Sf.IFileSystem> FileSystem;
            public int Count;
        }

        private static readonly object _lock = new();
        private static readonly Dictionary<string, Entry> _open = new();

        internal static void CloseAll()
        {
            lock (_lock)
            {
                // All IPC has returned. Release retained mounts before closing the clients
                // and server; uncommitted working state must not become a fabricated Commit.
                foreach (Entry entry in _open.Values) entry.FileSystem.Destroy();
                _open.Clear();
            }
        }

        public static string Key(SaveDataSpaceId spaceId, in SaveDataAttribute attribute)
        {
            ReadOnlySpan<byte> raw = MemoryMarshal.AsBytes(MemoryMarshal.CreateReadOnlySpan(ref System.Runtime.CompilerServices.Unsafe.AsRef(in attribute), 1));

            return $"{(byte)spaceId:x2}:{Convert.ToHexString(raw)}";
        }

        public delegate LibHac.Result OpenFileSystem(ref SharedRef<LibHac.FsSrv.Sf.IFileSystem> outFileSystem);

        // Share the mount already open for this save, or open it and register it. One lock spans the miss, the open and the registration
        // (audit #836 F-save-share-race): two first opens of one save on two threads used to both miss, both open (the second re-synced the
        // working copy over the first one's uncommitted changes) and the second reset the count to 1, so the first close dropped a live mount
        public static LibHac.Result OpenShared(string key, ref SharedRef<LibHac.FsSrv.Sf.IFileSystem> outFileSystem, OpenFileSystem open)
        {
            lock (_lock)
            {
                if (TryShare(key, ref outFileSystem))
                {
                    return LibHac.Result.Success;
                }

                LibHac.Result result = open(ref outFileSystem);

                if (result.IsFailure())
                {
                    return result;
                }

                Opened(key, in outFileSystem);

                return LibHac.Result.Success;
            }
        }

        // Mounts currently sharing this save (0 = not open)
        internal static int Count(string key)
        {
            lock (_lock)
            {
                return _open.TryGetValue(key, out Entry entry) ? entry.Count : 0;
            }
        }

        // A new reference to the open file system for this save, or false when none is open
        public static bool TryShare(string key, ref SharedRef<LibHac.FsSrv.Sf.IFileSystem> outFileSystem)
        {
            lock (_lock)
            {
                if (!_open.TryGetValue(key, out Entry entry))
                {
                    return false;
                }

                entry.Count++;
                outFileSystem.SetByCopy(in entry.FileSystem);

                return true;
            }
        }

        // The save was just opened: keep a reference so later opens share it while any mount lives
        public static void Opened(string key, in SharedRef<LibHac.FsSrv.Sf.IFileSystem> fileSystem)
        {
            lock (_lock)
            {
                _open[key] = new Entry { FileSystem = SharedRef<LibHac.FsSrv.Sf.IFileSystem>.CreateCopy(in fileSystem), Count = 1 };
            }
        }

        // One mount was released; the last one drops the kept reference, which closes the save as before
        public static void Closed(string key)
        {
            lock (_lock)
            {
                if (_open.TryGetValue(key, out Entry entry) && --entry.Count == 0)
                {
                    _open.Remove(key);
                    entry.FileSystem.Destroy();
                }
            }
        }
    }
}

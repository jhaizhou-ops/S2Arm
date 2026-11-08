using LibHac;
using LibHac.Fs;
using System;
using System.Collections.Concurrent;
using System.IO;

namespace Ryujinx.HLE.FileSystem
{
    // S2Arm: free / total space of a save data file system as the console reports it. On the console a save is a fixed-size image:
    // GetTotalSpaceSize is its data size and GetFreeSpaceSize what is left of it, both within the size the save was created with
    // (extra data DataSize) or later extended to (am ExtendSaveData → nn::fs::ExtendApplicationSaveData). Upstream's directory save
    // forwards both to the host disk, so a game asking how much room its save has gets the host volume (hundreds of GB) — more
    // than the save can ever hold. 11-04 Minecraft 1.21.111: asks GetFreeSpaceSize right before creating a world, gets ~316 GB
    // back, never creates the world directory, CreateFile level.dat fails PathNotFound and the game shows "Something went wrong";
    // with 288 MB (the size it extended its save to) the world is created and played (docs/坑记录.md 11-04 Minecraft).
    // Capacity = max(DataSize, the size am reports for the save): am's GetSaveDataSize is an upstream stub answering 200 MB until
    // the game extends (IApplicationFunctions), so an account / device save is never smaller than what am told the game it has.
    public static class S2ASaveSpace
    {
        // Upstream IApplicationFunctions' default for GetSaveDataSize / GetSaveDataSizeMax (its NOTE: "hardcode the values to 200mb")
        public const long AmDefaultSize = 200000000;

        private static readonly ConcurrentDictionary<(ulong Program, SaveDataType Type, ulong UserHigh, ulong UserLow), long> _extended = new();

        // am ExtendSaveData: the save of this program / type / user now has at least dataSize bytes (an extension never shrinks a save)
        public static void Extend(ulong programId, SaveDataType type, ulong userHigh, ulong userLow, long dataSize)
        {
            _extended.AddOrUpdate((programId, type, userHigh, userLow), dataSize, (_, old) => Math.Max(old, dataSize));
        }

        // Size of the save described by its extra data; 0 = unknown (no size recorded, nothing am answered for it)
        public static long Capacity(in SaveDataExtraData extraData)
        {
            long capacity = Math.Max(extraData.DataSize, 0);
            SaveDataType type = extraData.Attribute.Type;

            if (type is SaveDataType.Account or SaveDataType.Device)
            {
                var key = (extraData.Attribute.ProgramId.Value, type, extraData.Attribute.UserId.Id.High, extraData.Attribute.UserId.Id.Low);
                capacity = Math.Max(capacity, _extended.TryGetValue(key, out long extended) ? extended : AmDefaultSize);
            }

            return capacity;
        }

        // Bytes the save's files take: sum of file lengths under its working directory on the host
        public static long Used(string directory)
        {
            long used = 0;

            if (!Directory.Exists(directory))
            {
                return 0;
            }

            foreach (FileInfo file in new DirectoryInfo(directory).EnumerateFiles("*", SearchOption.AllDirectories))
            {
                used += file.Length;
            }

            return used;
        }

        public static Result GetTotalSpaceSize(out long totalSpace, in SaveDataExtraData extraData, long hostTotal)
        {
            long capacity = Capacity(in extraData);
            totalSpace = capacity > 0 ? capacity : hostTotal;

            return Result.Success;
        }

        // What is left of the save, never more than the host volume has left
        public static Result GetFreeSpaceSize(out long freeSpace, in SaveDataExtraData extraData, string workingDirectory, long hostFree)
        {
            long capacity = Capacity(in extraData);
            freeSpace = capacity > 0 ? Math.Min(hostFree, Math.Max(capacity - Used(workingDirectory), 0)) : hostFree;

            return Result.Success;
        }

        internal static void Reset() => _extended.Clear();
    }
}

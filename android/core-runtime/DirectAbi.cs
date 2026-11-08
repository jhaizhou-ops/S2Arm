// Direct-mode ABI v1 managed mirror（实施契约 §2.1）。
// 与 native/direct/s2a_direct.h、native/runtime/services_abi.h、runtime.h 同字段同偏移；
// 布局由 direct-abi-tests 与 C 端 JSON 对拍，字段顺序/大小不得在此单方面调整。
using System;
using System.Runtime.InteropServices;

namespace S2A.Android.Aot
{
    public static class DirectAbi
    {
        public const uint Version = 1;
        public const uint TableSize = 64;
        public const uint StatusSize = 24;
        public const uint ServicesRequestV2Size = 80;
        public const uint RuntimeRequestV2Size = 160;

        // 与 s2a_direct_result 完全一致；负码不得当成功。
        public const int Ok = 0, Pending = 1, Argument = -1, VersionMismatch = -2,
            Unsupported = -3, Identity = -4, Stopped = -5, Compile = -6, Driver = -7,
            Retirement = -8, Internal = -9;

        public const uint BlockAll = 63;

        public static int StatusInit(ref DirectStatusV1 status)
        {
            status.Size = StatusSize;
            status.Version = Version;
            status.State = (uint)DirectState.Prepared;
            status.Blockers = 0;
            status.Error = 0;
            status.Reserved = 0;
            return Ok;
        }

        // 与 s2a_direct_status_check 逐条相同；差异由共享向量负例发现。
        public static int StatusCheck(in DirectStatusV1 status)
        {
            if (status.Size < StatusSize) return Argument;
            if (status.Version != Version) return VersionMismatch;
            if (status.State > (uint)DirectState.Failed) return Argument;
            if ((status.Blockers & ~BlockAll) != 0) return Argument;
            if (status.State == (uint)DirectState.Stopped && status.Blockers != 0) return Argument;
            if (status.Reserved != 0) return Argument;
            if (status.Error > 0 || status.Error < Internal) return Argument;
            if (status.State == (uint)DirectState.Failed && status.Error == 0) return Argument;
            return Ok;
        }

        public static int TableCheck(in DirectApiV1 table)
        {
            if (table.Size < TableSize) return Argument;
            if (table.Version != Version) return VersionMismatch;
            if (table.Session == 0 || table.Context == 0) return Argument;
            if (table.Activate == 0 || table.RequestStop == 0 || table.Query == 0 ||
                table.Poll == 0 || table.Destroy == 0) return Argument;
            return Ok;
        }
    }

    public enum DirectState : uint { Prepared = 0, Active = 1, Stopping = 2, Stopped = 3, Failed = 4 }
    public enum DirectBlocker : uint
    {
        Guest = 1, Compile = 2, Submit = 4, Present = 8, Readback = 16, Writer = 32,
    }
    public enum GraphicsMode : uint { Generic = 0, Direct = 1 }
    public enum ModePreference : uint { Auto = 0, Generic = 1, Direct = 2 }

    [StructLayout(LayoutKind.Sequential)]
    public struct DirectBytes
    {
        public nint Data;
        public ulong Bytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DirectStatusV1
    {
        public uint Size, Version, State, Blockers;
        public int Error;
        public uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DirectApiV1
    {
        public uint Size, Version;
        public ulong Session;
        public nint Context;
        public nint Activate, RequestStop, Query, Poll, Destroy;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct DirectServicesRequestV2
    {
        // v1 request 前缀（64 字节，version=2）
        public uint Size, Version;
        public ulong Session;
        public nint NativeOwner, HostApi;
        public byte* GameDataDirectory, StateDirectory;
        public nint LeaseApi;
        public uint ConsoleMode, Reserved;
        public nint Graphics;
        public uint GraphicsMode, Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DirectGraphicsDescriptor
    {
        public nint Json;
        public ulong Bytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct DirectRuntimeRequestV2
    {
        public uint Size, Version;
        public uint ModePreference, Reserved;
        public DirectServicesRequestV2 Services;
        public byte* ModuleDir;
        public nint ModuleNames;
        public uint ModuleCount, Reserved0;
        public ulong ProgramId;
        public nint ModuleSource;
        public byte* NpdmPath;
        public DirectGraphicsDescriptor Graphics;
    }
}

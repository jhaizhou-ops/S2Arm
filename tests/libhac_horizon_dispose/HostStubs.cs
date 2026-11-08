// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Controlled dependencies only; the test compiles the unmodified production class.
using System;
using System.Collections.Generic;

internal static class Calls
{
    internal static readonly List<string> Events = new();
    internal static readonly Dictionary<string, Exception> Failures = new();
    internal static readonly HashSet<string> UnregisterFailures = new();
    internal static Action<string> Hook;
    internal static void Record(string name)
    {
        Events.Add(name);
        Hook?.Invoke(name);
        if (Failures.TryGetValue(name, out Exception error)) throw error;
    }
    internal static void Reset() { Events.Clear(); Failures.Clear(); UnregisterFailures.Clear(); Hook = null; Ryujinx.Common.Logging.Logger.Warning = new(); Ryujinx.Common.Logging.Logger.Messages.Clear(); }
}
namespace LibHac
{
    public class HorizonConfiguration { }
    public class Horizon
    {
        private int _privileged;
        public Horizon(HorizonConfiguration config) { }
        public HorizonClient CreatePrivilegedHorizonClient() => new(_privileged++ == 0 ? "Ryujinx" : "Pm");
        public HorizonClient CreateHorizonClient(Ncm.ProgramLocation location, FsSrv.Impl.AccessControlBits.Bits permissions) => new(location.Name);
        public HorizonClient CreateHorizonClient(Ncm.ProgramLocation location, ReadOnlySpan<byte> data, ReadOnlySpan<byte> descriptor) => new(location.Name);
    }
    public class HorizonClient : IDisposable
    {
        public string Name { get; }
        public ServiceManager Sm { get; } = new();
        public HorizonClient(string name) { Name = name; }
        public void Dispose() => Calls.Record("dispose:" + Name);
    }
    public class ServiceManager
    {
        public Result RegisterService(object service, string name) => new(null);
        public Result UnregisterService(string name)
        {
            Calls.Record("unregister:" + name);
            return new(Calls.UnregisterFailures.Contains(name) ? name : null);
        }
    }
    public readonly struct Result
    {
        private readonly string _name;
        public Result(string name) { _name = name; }
        public uint Value => _name == null ? 0u : 0x1234u;
        public bool IsFailure() => _name != null;
        public void ThrowIfFailure() { if (IsFailure()) throw new InvalidOperationException("unregister result failure"); }
    }
}
namespace LibHac.Common
{
    public struct SharedRef<T> where T : class, IDisposable
    {
        private T _value;
        public T Get => _value;
        public void Reset(T value) { _value = value; }
        public void Destroy() { T value = _value; _value = null; value?.Dispose(); }
        public static SharedRef<T> CreateMove(ref SharedRef<T> source)
        { SharedRef<T> result = source; source = default; return result; }
    }
}
namespace LibHac.Bcat { public class BcatServer { public BcatServer(LibHac.HorizonClient client) { } } }
namespace LibHac.FsSrv.Impl
{
    public class AccessControlBits
    {
        [Flags] public enum Bits { SystemSaveData=1, GameCard=2, SaveDataMeta=4, GetRightsId=8, SaveDataManagement=16,
            CreateSaveData=32, SystemData=64, ApplicationInfo=128, ContentManager=256, ImageManager=512,
            SystemSaveDataManagement=1024, SystemUpdate=2048, SdCard=4096, FormatSdCard=8192,
            RegisterProgramIndexMapInfo=16384, MoveCacheStorage=32768 }
    }
}
namespace LibHac.Loader { public struct Npdm { public byte[] FsAccessControlData; public byte[] FsAccessControlDescriptor; } }
namespace LibHac.Ncm
{
    public enum SystemProgramId { Bcat, Account, Am, Ns, Sdb }
    public readonly struct ProgramId { }
    public enum StorageId { BuiltInSystem, BuiltInUser }
    public readonly struct ProgramLocation
    {
        public string Name { get; }
        public ProgramLocation(SystemProgramId id, StorageId storage) { Name = id.ToString(); }
        public ProgramLocation(ProgramId id, StorageId storage) { Name = "Application"; }
    }
}
namespace Ryujinx.HLE.FileSystem
{
    public class VirtualFileSystem
    { public void InitializeFsServer(LibHac.Horizon server, out LibHac.HorizonClient client) { client = new("Fs"); } }
}
namespace Ryujinx.HLE.HOS.Services.Arp
{
    public class LibHacIReader : IDisposable { public void Dispose() => Calls.Record("destroy:Arp"); }
    public class LibHacArpServiceObject
    { public LibHacArpServiceObject(ref LibHac.Common.SharedRef<LibHacIReader> reader) { } }
}

namespace Ryujinx.Common.Logging
{
    public enum LogClass { ServiceFs }
    public static class Logger
    {
        public static readonly List<string> Messages = new();
        public static Log Warning = new();
        public class Log { public void Print(LogClass category, string message) => Messages.Add(message); }
    }
}

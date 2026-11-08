using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Fs.Shim;
using LibHac.FsSrv;
using LibHac.FsSystem;
using Ryujinx.Common.Configuration;
using Ryujinx.HLE.FileSystem;
using Ryujinx.HLE.HOS;
using System;
using System.IO;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Path = System.IO.Path;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // Real LibHac clients, server and host files. This path runs before FakeNative.Install
        // and does not construct a renderer, emulated process, game fixture or mocked service.
        internal static int FileSystemRestart()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a-fs-restart-{Guid.NewGuid():N}");
            try
            {
                Directory.CreateDirectory(root);
                AppDataManager.Initialize(root);
                if (AppDataManager.BaseDirPath != root)
                    throw new InvalidOperationException("测试数据根目录未生效，禁止访问用户的默认数据目录");
                Console.WriteLine($"实际隔离根：{root}；运行时：{(RuntimeFeature.IsDynamicCodeSupported ? "JIT" : "NativeAOT")}");
                bool collected = true;
                for (int round = 0; round < 10; round++)
                {
                    // The callee's frame and using locals are gone before collection.
                    var references = FileSystemRound(round);
                    GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
                    GC.WaitForPendingFinalizers();
                    GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
                    string alive = string.Join(", ", Array.ConvertAll(Array.FindAll(references, item => item.Reference.IsAlive), item => item.Name));
                    collected &= alive.Length == 0;
                    var generations = GC.GetGCMemoryInfo().GenerationInfo;
                    long poh = generations.Length > 4 ? generations[4].SizeAfterBytes : -1;
                    long fragmented = generations.Length > 4 ? generations[4].FragmentationAfterBytes : -1;
                    Console.WriteLine($"真实文件系统重建 {round + 1}/10：读回通过；Dispose+完整GC后存活：{(alive.Length == 0 ? "无" : alive)}；POH size={poh} fragmentation={fragmented} live={poh - fragmented}字节");
                }
                Console.WriteLine($"{(collected ? "PASS" : "FAIL")}：10 次实际LibHac重建、文件读回与旧对象回收；不代表实际游戏或设备重启通过");
                return collected ? 0 : 1;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                return 1;
            }
            finally
            {
                if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
            }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static (string Name, WeakReference Reference)[] FileSystemRound(int round)
        {
            using VirtualFileSystem fileSystem = VirtualFileSystem.CreateInstance();
            var references = FileSystemClientsRound(fileSystem, round);
            // The client helper has already disposed its Horizon and returned. Dispose
            // the real buffer owner repeatedly, including once more at this scope's end.
            fileSystem.Dispose();
            fileSystem.Dispose();
            return references;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        [DynamicDependency(DynamicallyAccessedMemberTypes.NonPublicFields, typeof(VirtualFileSystem))]
        [DynamicDependency(DynamicallyAccessedMemberTypes.NonPublicProperties, typeof(LibHacHorizonManager))]
        private static (string Name, WeakReference Reference)[] FileSystemClientsRound(VirtualFileSystem fileSystem, int round)
        {
            using LibHacHorizonManager horizon = new();
            horizon.InitializeFsServer(fileSystem);
            horizon.InitializeArpServer();
            horizon.InitializeBcatServer();
            horizon.InitializeSystemClients();
            object server = typeof(VirtualFileSystem).GetField("_fsServer", BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(fileSystem)
                ?? throw new InvalidOperationException("无法取得实际FileSystemServer，不能跳过回收检查");
            object libHacHorizon = typeof(LibHacHorizonManager).GetProperty("Server", BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(horizon)
                ?? throw new InvalidOperationException("无法取得实际LibHac.Horizon，不能跳过回收检查");
            FileSystemBufferManager bufferManager = GetActualBufferManager((FileSystemServer)server);
            object buddyHeap = typeof(FileSystemBufferManager).GetField("_buddyHeap", BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(bufferManager)
                ?? throw new InvalidOperationException("无法取得实际FileSystemBuddyHeap，不能跳过pin检查");
            object heapMemory = typeof(FileSystemBuddyHeap).GetProperty("HeapBuffer", BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(buddyHeap)
                ?? throw new InvalidOperationException("无法取得实际HeapBuffer，不能跳过pin检查");
            if (heapMemory is not Memory<byte> memory || !MemoryMarshal.TryGetArray((ReadOnlyMemory<byte>)memory, out ArraySegment<byte> segment) ||
                segment.Array is not byte[] buffer || buffer.Length != 14 * 1024 * 1024)
                throw new InvalidOperationException("实际LibHac缓冲不是预期14MiB数组，须同步回归其新所有权");
            var fs = horizon.RyujinxClient.Fs;
            fs.MountSdCard("restart"u8).ThrowIfFailure();
            if (round == 0) fs.CreateFile("restart:/counter\0"u8, sizeof(int)).ThrowIfFailure();
            fs.OpenFile(out FileHandle file, "restart:/counter\0"u8, OpenMode.ReadWrite).ThrowIfFailure();
            try
            {
                if (round != 0)
                {
                    byte[] previous = new byte[sizeof(int)];
                    fs.ReadFile(file, 0, previous).ThrowIfFailure();
                    if (BitConverter.ToInt32(previous) != round - 1)
                        throw new InvalidOperationException($"第 {round + 1} 局没有读到前一实例落盘的数据");
                }
                fs.WriteFile(file, 0, BitConverter.GetBytes(round), WriteOption.Flush).ThrowIfFailure();
            }
            finally { fs.CloseFile(file); }
            fs.Unmount("restart"u8);
            (string Name, WeakReference Reference)[] references = [
                ("VirtualFileSystem", new WeakReference(fileSystem)),
                ("LibHacHorizonManager", new WeakReference(horizon)),
                ("LibHac.Horizon", new WeakReference(libHacHorizon)),
                ("FileSystemServer", new WeakReference(server)),
                ("RyujinxClient", new WeakReference(horizon.RyujinxClient)),
                ("RyujinxClient.Fs", new WeakReference(fs)),
                ("FsClient", new WeakReference(horizon.FsClient)),
                ("FsClient.Fs", new WeakReference(horizon.FsClient.Fs)),
                ("BcatClient", new WeakReference(horizon.BcatClient)),
                ("FileSystemBufferManager", new WeakReference(bufferManager)),
                ("FileSystemBuddyHeap", new WeakReference(buddyHeap)),
                ("actual 14MiB pinned array", new WeakReference(buffer)),
            ];
            horizon.Dispose();
            horizon.Dispose();
            return references;
        }

        // Exact private graph in the pinned Ryujinx.LibHac 0.21.0-alpha.133 package.
        // Missing metadata is a test failure, including when NativeAOT trims it.
        private static FileSystemBufferManager GetActualBufferManager(FileSystemServer server)
        {
            object globals = typeof(FileSystemServer).GetField("Globals", BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(server)
                ?? throw new InvalidOperationException("LibHac FileSystemServer.Globals unavailable");
            object proxy = Type.GetType("LibHac.FsSrv.FileSystemServerGlobals, LibHac", throwOnError: true)!
                .GetField("FileSystemProxyImpl", BindingFlags.Instance | BindingFlags.Public)?.GetValue(globals)
                ?? throw new InvalidOperationException("LibHac FileSystemProxyImpl unavailable");
            object service = Type.GetType("LibHac.FsSrv.FileSystemProxyImplGlobals, LibHac", throwOnError: true)!
                .GetField("SaveDataFileSystemServiceImpl", BindingFlags.Instance | BindingFlags.Public)?.GetValue(proxy)
                ?? throw new InvalidOperationException("LibHac SaveDataFileSystemServiceImpl unavailable");
            object config = typeof(SaveDataFileSystemServiceImpl).GetField("_config", BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(service)
                ?? throw new InvalidOperationException("LibHac SaveDataFileSystemServiceImpl._config unavailable");
            return config is SaveDataFileSystemServiceImpl.Configuration configuration && configuration.BufferManager is FileSystemBufferManager manager
                ? manager : throw new InvalidOperationException("LibHac BufferManager has unexpected type");
        }
    }
}

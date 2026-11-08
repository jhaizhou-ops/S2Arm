using Ryujinx.Graphics.GAL;
using S2Arm.Backends.Vulkan.ProgramCache;
using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

static class S1Tests
{
    private static int _count;

    private static void Check(bool ok, string name)
    {
        if (!ok) throw new Exception("FAIL: " + name);
        _count++;
        Console.WriteLine("PASS " + name);
    }

    private static PipelineCacheIdentity Identity() => new(
        0x5143, 0x730, 0x12345678, 0x00401000,
        Enumerable.Range(0, 16).Select(i => (byte)i).ToArray(), PipelineCacheFile.Schema,
        PipelineCacheFile.Backend);

    private static byte[] Payload()
    {
        byte[] payload = new byte[96];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, 32);
        BinaryPrimitives.WriteUInt32LittleEndian(payload.AsSpan(4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(payload.AsSpan(8), 0x5143);
        BinaryPrimitives.WriteUInt32LittleEndian(payload.AsSpan(12), 0x730);
        for (int i = 0; i < 16; i++) payload[16 + i] = (byte)i;
        return payload;
    }

    private static void DriverCache()
    {
        PipelineCacheIdentity identity = Identity();
        byte[] payload = Payload();
        byte[] wrapped = PipelineCacheFile.Wrap(identity, payload);
        Check(PipelineCacheFile.TryUnwrap(wrapped, identity, out byte[] read, out _) &&
            read.SequenceEqual(payload), "driver cache wrapper round-trip");

        Check(!PipelineCacheFile.TryUnwrap(wrapped, identity with { VendorId = 1 }, out _, out string vendor) &&
            vendor.StartsWith("IDENTITY"), "driver cache vendor mismatch rejected");
        Check(!PipelineCacheFile.TryUnwrap(wrapped, identity with { PipelineCacheUuid = new byte[16] }, out _, out string uuid) &&
            uuid.StartsWith("UUID"), "driver cache UUID mismatch rejected");
        Check(!PipelineCacheFile.TryUnwrap(wrapped[..(wrapped.Length - 1)], identity, out _, out string length) &&
            length.StartsWith("LENGTH"), "driver cache truncation rejected");
        Check(!PipelineCacheFile.TryUnwrap(wrapped, identity with { Backend = "opengl" }, out _, out string backend) &&
            backend.StartsWith("BACKEND"), "driver cache backend mismatch rejected");

        byte[] hash = (byte[])wrapped.Clone();
        hash[70] ^= 1;
        Check(!PipelineCacheFile.TryUnwrap(hash, identity, out _, out string digest) && digest.StartsWith("HASH"),
            "driver cache digest mismatch rejected");

        byte[] garbage = new byte[128];
        for (int i = 0; i < garbage.Length; i++) garbage[i] = (byte)(i * 31 + 7);
        Check(!PipelineCacheFile.TryUnwrap(garbage, identity, out _, out string corrupt) && corrupt.StartsWith("MAGIC"),
            "driver cache corrupt file rejected as a rebuildable miss");

        byte[] badInnerPayload = Payload();
        badInnerPayload[8] ^= 1;
        byte[] inner = PipelineCacheFile.Wrap(identity, badInnerPayload);
        Check(!PipelineCacheFile.TryUnwrap(inner, identity, out _, out string embedded) && embedded.StartsWith("DRIVER"),
            "driver cache embedded driver header mismatch rejected");

        string directory = Path.Combine(Path.GetTempPath(), "s2a-s1-" + Environment.ProcessId);
        string path = Path.Combine(directory, "nested", "vk-pipeline-cache.bin");
        Directory.CreateDirectory(directory);
        try
        {
            Check(PipelineCacheFile.TryWriteAtomic(path, identity, payload, out string writeError) && writeError == null,
                "driver cache atomic write");
            Check(PipelineCacheFile.TryRead(path, identity, out byte[] stored, out _) && stored.SequenceEqual(payload),
                "driver cache read back");
            Check(PipelineCacheFile.TryWriteAtomic(path, identity, payload[..64], out _) &&
                PipelineCacheFile.TryRead(path, identity, out byte[] replaced, out _) && replaced.SequenceEqual(payload[..64]),
                "driver cache replacement keeps the newest receipt");
            Check(!PipelineCacheFile.TryRead(Path.Combine(directory, "missing.bin"), identity, out _, out string missing) &&
                missing.StartsWith("MISS"), "driver cache miss is a rebuildable miss");

            // 原子写中断：上一次进程在临时文件里留下的半截内容不能被当成缓存；最终文件仍是旧的完整快照。
            string staleTemp = path + ".tmp.424242.7";
            File.WriteAllBytes(staleTemp, wrapped[..(wrapped.Length / 2)]);
            Check(PipelineCacheFile.TryRead(path, identity, out byte[] afterStale, out _) &&
                afterStale.SequenceEqual(payload[..64]), "driver cache ignores a stale half-written temporary file");
            Check(PipelineCacheFile.TryWriteAtomic(path, identity, payload, out _) &&
                PipelineCacheFile.TryRead(path, identity, out byte[] afterWrite, out _) && afterWrite.SequenceEqual(payload),
                "driver cache writes the newest snapshot with a stale temporary present");
            Check(File.Exists(staleTemp), "driver cache does not delete another writer's temporary file");

            // 改名失败（最终路径是目录）：旧快照不可用，但失败后不能留下本进程的临时文件。
            string blocked = Path.Combine(directory, "blocked.bin");
            Directory.CreateDirectory(blocked);
            Check(!PipelineCacheFile.TryWriteAtomic(blocked, identity, payload, out string blockedError) &&
                blockedError.StartsWith("IO"), "driver cache failed rename is reported as an IO miss");
            Check(Directory.Exists(blocked) && Directory.GetFiles(directory, "blocked.bin.tmp.*").Length == 0,
                "driver cache failed atomic write leaves no half file or temporary behind");

            // 失联进程临时文件清理：只删进程号已证实不在的 *.tmp.<pid>.<n>（被杀进程没走到收尾删临时文件）。
            // 负控：活进程号的、本进程号的、别的缓存命名的、段数不符的临时文件一律不动。
            using (System.Diagnostics.Process dead = System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo("/bin/sh", "-c \"exit 0\"")
                { RedirectStandardOutput = true, RedirectStandardError = true }))
            {
                dead.WaitForExit();
                int deadPid = dead.Id;
                string orphan = path + ".tmp." + deadPid + ".1";
                string ownPid = path + ".tmp." + Environment.ProcessId + ".3";
                string oneSegment = path + ".tmp." + deadPid;
                string notPid = path + ".tmp.notapid.9";
                string stranger = Path.Combine(directory, "stranger.bin.tmp." + deadPid + ".4");
                File.WriteAllBytes(orphan, wrapped[..16]);
                File.WriteAllBytes(ownPid, wrapped[..8]);
                File.WriteAllBytes(oneSegment, wrapped[..8]);
                File.WriteAllBytes(notPid, wrapped[..8]);
                File.WriteAllBytes(stranger, wrapped[..8]);

                using System.Diagnostics.Process sleeper = System.Diagnostics.Process.Start(
                    new System.Diagnostics.ProcessStartInfo("/bin/sh", "-c \"sleep 30\"")
                    { RedirectStandardOutput = true, RedirectStandardError = true });
                string live = path + ".tmp." + sleeper.Id + ".2";
                File.WriteAllBytes(live, wrapped[..8]);
                try
                {
                    Check(PipelineCacheFile.CleanOrphanedTemporaries(path) == 2,
                        "startup cleanup removes exactly the dead-writer temporaries");
                    Check(!File.Exists(orphan) && !File.Exists(staleTemp),
                        "dead-pid temporaries are removed at startup");
                    Check(File.Exists(live), "a live writer's temporary is never removed");
                    Check(File.Exists(ownPid),
                        "a same-pid temporary is never removed: a rebuilt in-process session may still be writing it");
                }
                finally
                {
                    try { sleeper.Kill(); } catch (InvalidOperationException) { }
                    sleeper.WaitForExit();
                }

                // 进程内重建会话：旧会话的后台落盘还在写时就跑清理；写完后 rename 必须照常成功。
                // 打开的写流复现「写进行中」——若清理误删这个名字，File.Move 会找不到源文件。
                string rebuilt = Path.Combine(Path.GetDirectoryName(path), "rebuilt.bin");
                string rebuiltTemp = rebuilt + ".tmp." + Environment.ProcessId + ".9";
                using (FileStream inFlight = new(rebuiltTemp, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    inFlight.Write(wrapped, 0, wrapped.Length);
                    inFlight.Flush(flushToDisk: true);
                    Check(PipelineCacheFile.CleanOrphanedTemporaries(rebuilt) == 0,
                        "cleanup leaves a same-pid in-flight temporary alone");
                }
                File.Move(rebuiltTemp, rebuilt, overwrite: true);
                Check(PipelineCacheFile.TryRead(rebuilt, identity, out byte[] rebuiltPayload, out _) &&
                    rebuiltPayload.SequenceEqual(payload),
                    "an in-flight same-pid write still renames into a readable cache after cleanup");

                Check(File.Exists(oneSegment) && File.Exists(notPid) && File.Exists(stranger),
                    "cleanup never touches files outside its own temporary naming");
                Check(PipelineCacheFile.TryRead(path, identity, out byte[] afterClean, out _) &&
                    afterClean.SequenceEqual(payload) &&
                    PipelineCacheFile.TryWriteAtomic(path, identity, payload[..64], out _),
                    "cleanup does not disturb the cache snapshot or later writes");
            }
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { }
        }
    }

    private static void CompileLane()
    {
        using CompileWorker worker = new();
        Task<int> value = worker.Run(() => 42);
        Check(value.GetAwaiter().GetResult() == 42, "single compile lane returns values");

        Task<int> failed = worker.Run<int>(() => throw new InvalidOperationException("fixture"));
        try
        {
            failed.GetAwaiter().GetResult();
            throw new Exception("FAIL: compile lane swallowed an exception");
        }
        catch (InvalidOperationException e) when (e.Message == "fixture")
        {
            Check(true, "single compile lane propagates driver exceptions");
        }

        ManualResetEventSlim gate = new(false);
        ManualResetEventSlim blockerStarted = new(false);
        Task<int> blocker = worker.Run(() => { blockerStarted.Set(); gate.Wait(); return 1; });
        Check(blockerStarted.Wait(5000), "compile lane starts the blocking fixture");
        int pumpCount = 0;
        Task releaser = Task.Run(() => { Thread.Sleep(50); gate.Set(); });
        int inline = worker.RunInline(() => 7, () => Interlocked.Increment(ref pumpCount), 5000);
        Check(inline == 7 && pumpCount > 0, "owner wait pumps while the compile lane is busy");
        blocker.GetAwaiter().GetResult();
        releaser.Wait();

        using CompileWorker stopping = new();
        ManualResetEventSlim release = new(false);
        ManualResetEventSlim runningStarted = new(false);
        Task<int> running = stopping.Run(() => { runningStarted.Set(); release.Wait(); return 1; });
        Check(runningStarted.Wait(5000), "compile lane starts the in-flight fixture");
        Task<int> queued = stopping.Run(() => 2);
        Task stopper = Task.Run(() => { Thread.Sleep(50); release.Set(); });
        Check(stopping.Stop(5000), "compile lane stop joins the in-flight call");
        stopper.Wait(5000);
        Check(SpinWait.SpinUntil(() => queued.IsCompleted, 5000) && queued.IsCanceled,
            "compile lane stop cancels queued work");
        Check(running.GetAwaiter().GetResult() == 1, "in-flight compile lane work is retained until it returns");
        Check(stopping.Run(() => 3).IsFaulted, "compile lane rejects work after stop");

        FailedProgram failedProgram = new("LENGTH: fixture");
        Check(failedProgram.CheckProgramLink(true) == ProgramLinkStatus.Failure && failedProgram.GetBinary() == null,
            "rejected VKPB placeholder reports link failure without a binary");
        failedProgram.Dispose();
    }

    private static void Profile()
    {
        Capabilities defaults = default;
        ProgramBinaryIdentity a = ProgramBinaryProfile.Create(in defaults, 0x00401000, "closure-a");
        ProgramBinaryIdentity b = ProgramBinaryProfile.Create(in defaults, 0x00401000, "closure-a");
        ProgramBinaryIdentity version = ProgramBinaryProfile.Create(in defaults, 0x00403000, "closure-a");
        ProgramBinaryIdentity closure = ProgramBinaryProfile.Create(in defaults, 0x00401000, "closure-b");
        Check(a == b && a.ProfileKey == b.ProfileKey && a.TranslationKey == b.TranslationKey,
            "program profile is deterministic");
        Check(a.ProfileKey != version.ProfileKey && a.TranslationKey != version.TranslationKey,
            "SPIR-V target changes the program profile");
        Check(a.TranslationKey != closure.TranslationKey, "translator closure changes the translation identity");

        object boxed = (Capabilities)default;
        typeof(Capabilities).GetField(nameof(Capabilities.SupportsGeometryShader)).SetValue(boxed, true);
        Capabilities geometry = (Capabilities)boxed;
        Check(ProgramBinaryProfile.Create(in geometry, 0x00401000, "closure-a").ProfileKey != a.ProfileKey,
            "capability change rotates the program profile");

        string[] actual = typeof(Capabilities).GetFields().Select(f => f.Name).Where(n => n != nameof(Capabilities.MaximumGpuMemory))
            .Order().ToArray();
        string[] covered = ProgramBinaryProfile.Fields.Order().ToArray();
        Check(actual.SequenceEqual(covered),
            "every translation-affecting Capabilities field is in the Vulkan program profile");
    }

    public static int Run()
    {
        DriverCache();
        CompileLane();
        Profile();
        return _count;
    }
}

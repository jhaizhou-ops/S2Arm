using System;
using System.Reflection;
using System.Threading;
using Ryujinx.Memory;
using Ryujinx.Memory.Tracking;
using Ryujinx.Tests.Memory;

// The protection endpoint models NxTrack's guest-only notification domain. All
// registration, callback, lock and virtual-region logic is production code.
sealed class GuestManager : MockVirtualMemoryManager, IVirtualMemoryManager
{
    public int Generation;
    public MemoryPermission Permission;
    public GuestManager() : base(0x8000, 4096) { }
    public new void TrackingReprotect(ulong va, ulong size, MemoryPermission protection, bool guest)
    {
        if (!guest) return;
        if (protection == MemoryPermission.None) Interlocked.Increment(ref Generation);
        Permission = protection;
    }
}

static class Program
{
    static int checks, failed;
    static readonly PropertyInfo Option = typeof(MemoryTracking).GetProperty("ReprotectOnActionRegistration");
    static readonly FieldInfo TrackingLock = typeof(MemoryTracking).GetField("TrackingLock", BindingFlags.Instance | BindingFlags.NonPublic)!;
    static readonly FieldInfo ActionField = typeof(RegionHandle).GetField("_preAction", BindingFlags.Instance | BindingFlags.NonPublic)!;
    static void Check(bool ok, string why) { checks++; if (!ok) throw new Exception(why); }
    static MemoryTracking Tracking(GuestManager manager, bool enabled)
    {
        var tracking = new MemoryTracking(manager, 4096);
        // Old-source runs still execute the real old behavior, rather than failing to compile.
        Option?.SetValue(tracking, enabled);
        return tracking;
    }
    static void Read(MemoryTracking tracking) => tracking.VirtualMemoryEvent(0x1000, 4096, false, false, null, true);
    static void Case(string name, Action action)
    {
        try { action(); Console.WriteLine("PASS " + name); }
        catch (Exception error) { failed++; Console.WriteLine("FAIL " + name + ": " + error.Message); }
    }
    static void Overlap(bool enabled)
    {
        var manager = new GuestManager(); var tracking = Tracking(manager, enabled);
        using var handle = tracking.BeginTracking(0x1000, 4096, 0); handle.Reprotect();
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        int first = 0, second = 0; Exception error = null;
        handle.RegisterAction((_, _) => { first++; entered.Set(); if (!release.Wait(5000)) throw new Exception("callback deadline"); });
        int before = manager.Generation;
        var reader = new Thread(() => { try { Read(tracking); } catch (Exception e) { error = e; } });
        reader.Start(); Check(entered.Wait(5000), "old action entered");
        lock (TrackingLock.GetValue(tracking)!)
        {
            release.Set();
            handle.RegisterAction((_, _) => second++);
        }
        Check(reader.Join(5000), "reader completed"); if (error != null) throw error;
        Check(first == 1 && second == 0, "new action remains pending");
        Check(manager.Permission == MemoryPermission.None, "new pending work stays inaccessible");
        Check(manager.Generation == before + (enabled ? 1 : 0), "fresh NONE notification distinguishes new work");
        Read(tracking);
        Check(second == 1 && manager.Permission == MemoryPermission.Read, "next read consumes new action and restores Read");
    }
    static void Publication(bool enabled)
    {
        var manager = new GuestManager(); var tracking = Tracking(manager, enabled);
        using var handle = tracking.BeginTracking(0x1000, 4096, 0); handle.Reprotect();
        handle.RegisterAction(null); // Initialize PreActionLock before the controlled contention.
        using var entered = new ManualResetEventSlim(); Exception error = null; int calls = 0;
        var publisher = new Thread(() => {
            entered.Set();
            try { handle.RegisterAction((_, _) => calls++); } catch (Exception e) { error = e; }
        });
        bool visible;
        lock (TrackingLock.GetValue(tracking)!)
        {
            publisher.Start(); Check(entered.Wait(5000), "publisher started");
            Check(SpinWait.SpinUntil(() => (publisher.ThreadState & ThreadState.WaitSleepJoin) != 0, 5000), "publisher blocked on held tracking lock");
            Thread.MemoryBarrier();
            visible = ActionField.GetValue(handle) != null;
        }
        Check(publisher.Join(5000), "publisher completed"); if (error != null) throw error;
        Check(visible == !enabled, "action and native notification must publish under one lock when enabled");
        Read(tracking); Check(calls == 1, "published action is not lost");
    }
    static void NoFalseEpoch(bool enabled)
    {
        var manager = new GuestManager(); var tracking = Tracking(manager, enabled);
        using var handle = tracking.BeginTracking(0x1000, 4096, 0); handle.Reprotect();
        int initial = manager.Generation;
        handle.RegisterAction(null); Check(manager.Generation == initial, "null registration has no epoch");
        handle.RegisterAction((_, _) => RegionHandle.S2AKeepAction = true);
        int registered = manager.Generation;
        for (int i = 0; i < 8; i++) { handle.Reprotect(); Read(tracking); }
        Check(manager.Generation == registered && manager.Permission == MemoryPermission.None, "unchanged pending action cannot invent progress");
        int calls = 0;
        handle.RegisterAction((_, _) => calls++);
        Check(manager.Generation == registered, "replacing an already pending action does not create a false completion epoch");
        Read(tracking); Check(calls == 1 && manager.Permission == MemoryPermission.Read, "latest replacement action executes");
    }
    static void SharedPage(bool enabled)
    {
        var manager = new GuestManager(); var tracking = Tracking(manager, enabled);
        using var a = tracking.BeginTracking(0x1100, 0x400, 0);
        using var b = tracking.BeginTracking(0x1200, 0x400, 1);
        a.Reprotect(); b.Reprotect(); int calls = 0;
        a.RegisterAction((_, _) => calls++); int generation = manager.Generation;
        b.RegisterAction((_, _) => calls++);
        Check(manager.Generation == generation + (enabled ? 1 : 0), "overlapping fresh action notification");
        Read(tracking); Check(calls == 2 && manager.Permission == MemoryPermission.Read, "both overlapping actions complete");
    }
    public static int Main()
    {
        var defaults = new MemoryTracking(new GuestManager(), 4096);
        Check(Option == null || !(bool)Option.GetValue(defaults)!, "other hosts default to permission-only coalescing");
        foreach (bool enabled in new[] { false, true })
        {
            Case("registration overlap enabled=" + enabled, () => Overlap(enabled));
            Case("atomic publication enabled=" + enabled, () => Publication(enabled));
            Case("no invented epoch enabled=" + enabled, () => NoFalseEpoch(enabled));
            Case("overlapping handles enabled=" + enabled, () => SharedPage(enabled));
        }
        Console.WriteLine($"checks={checks}, failedCases={failed}; real managed tracking, controlled native endpoint");
        return failed == 0 ? 0 : 1;
    }
}

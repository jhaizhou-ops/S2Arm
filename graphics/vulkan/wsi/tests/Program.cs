using S2Arm.Backends.Vulkan.Wsi;
using System;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

internal static unsafe class Program
{
    private static int _assertions;
    private static void Check(bool value, string name)
    {
        _assertions++;
        if (!value)
        {
            throw new Exception(name);
        }
    }

    private static void Reject(Action action, string name)
    {
        bool rejected = false;
        try { action(); }
        catch (InvalidOperationException) { rejected = true; }
        catch (ArgumentException) { rejected = true; }
        Check(rejected, name);
    }

    private static SwapchainRecord Chain(RetirementLedger ledger, RetirementMode mode,
        ulong generation = 1, ulong revision = 0) =>
        ledger.RegisterSwapchain(new(ledger.Session, generation, revision), 3, mode);

    private static AcquireRecord Queue(RetirementLedger ledger, SwapchainRecord chain,
        ulong semaphore, int image, bool fence = false)
    {
        var record = ledger.BeginAcquire(chain, semaphore);
        ledger.FinishAcquire(record, AcquireOutcome.Acquired, image);
        ledger.SubmitQueued(record);
        ledger.PresentReturned(record, PresentOutcome.Queued, fence);
        return record;
    }

    private static void IdleAssumptionRetirement()
    {
        var ledger = new RetirementLedger(7, 3);
        var chain = Chain(ledger, RetirementMode.Reacquire);
        var a = Queue(ledger, chain, 11, 0);
        var b = Queue(ledger, chain, 12, 1);
        Reject(() => ledger.ObserveQueueIdleAssumption(chain), "live chain cannot use idle assumption");
        ledger.RetireGeneration(1);
        Reject(() => ledger.ObserveQueueIdleAssumption(chain), "unfinished submissions block idle assumption");
        ledger.ObserveSubmitCompletion(a);
        Reject(() => ledger.ObserveQueueIdleAssumption(chain), "every submit must complete first");
        ledger.ObserveSubmitCompletion(b);
        Check(!ledger.CanDestroySwapchain(chain), "submit fences alone do not retire presents");
        ledger.ObserveQueueIdleAssumption(chain); // Caller invokes only after actual successful queue idle.
        Check(a.PresentAssumedIdle && b.PresentAssumedIdle, "assumption recorded per presentation");
        Check(!a.PresentDone && !b.PresentDone, "assumption must not impersonate presentation completion");
        Check(chain.PresentAssumedIdle && ledger.CanDestroySwapchain(chain), "assumed chain can retire separately from present proof");
        Check(!ledger.CanDestroySurface(1), "surface and ACK still wait for actual destruction");
        ledger.ConfirmSwapchainDestroyed(chain);
        Check(ledger.CanDestroySurface(1), "surface can retire only after chain destruction");
        ledger = new(7, 3); chain = Chain(ledger, RetirementMode.Reacquire);
        var acquired = ledger.BeginAcquire(chain, 42);
        ledger.FinishAcquire(acquired, AcquireOutcome.Acquired, 0);
        ledger.RetireSwapchain(chain);
        Reject(() => ledger.ObserveQueueIdleAssumption(chain), "unsubmitted acquire blocks idle assumption");
        ledger = new(7, 3); chain = Chain(ledger, RetirementMode.Reacquire);
        var lost = Queue(ledger, chain, 43, 0); ledger.ObserveSubmitCompletion(lost); ledger.LoseDevice();
        Reject(() => ledger.ObserveQueueIdleAssumption(chain), "device loss cannot assume completion");
        Check(!ledger.CanDestroySwapchain(chain), "device loss retains ownership");
        ledger = new(7, 3); chain = Chain(ledger, RetirementMode.EnabledPresentFence);
        var fenced = Queue(ledger, chain, 44, 0, true); ledger.ObserveSubmitCompletion(fenced); ledger.RetireSwapchain(chain);
        ledger.ObserveQueueIdleAssumption(chain);
        Check(fenced.PresentAssumedIdle && !fenced.PresentDone && ledger.CanDestroySwapchain(chain), "fence timeout assumption is distinct from signal");
        Console.WriteLine("PASS queue-idle assumption ledger contract");
    }

    private static void FenceRetirement()
    {
        var ledger = new RetirementLedger(7, 3);
        var chain = Chain(ledger, RetirementMode.EnabledPresentFence);
        var record = Queue(ledger, chain, 11, 2, true);
        ledger.RetireGeneration(1);
        ledger.ObserveSubmitCompletion(record);
        Check(ledger.SourceUseComplete(record), "submit retires source use");
        Check(!ledger.CanDestroySwapchain(chain), "submit must NOT retire own present");
        Check(ledger.Blockers(chain).Presents == 1, "pending presentation retained");
        Reject(() => ledger.ConfirmSwapchainDestroyed(chain), "early destruction rejected");
        ledger.ObservePresentFence(record);
        Check(ledger.CanDestroySwapchain(chain), "both independent proofs permit destroy");
        Check(!ledger.CanDestroySurface(1), "swapchain objects still exist");
        ledger.ConfirmSwapchainDestroyed(chain);
        Check(ledger.CanDestroySurface(1), "surface after swapchain destruction");
        Reject(() => ledger.ObservePresentFence(record), "late duplicate token rejected");
        Reject(() => Chain(ledger, RetirementMode.Reacquire), "retired generation cannot reopen");

        ledger = new(7, 3);
        chain = Chain(ledger, RetirementMode.EnabledPresentFence);
        record = Queue(ledger, chain, 12, 0, true);
        ledger.RetireSwapchain(chain);
        ledger.ObservePresentFence(record);
        Check(!ledger.SourceUseComplete(record), "present fence is not source-use proof");
        Check(!ledger.CanDestroySwapchain(chain), "present completion cannot substitute submit completion");
        ledger.ObserveSubmitCompletion(record);
        Check(ledger.CanDestroySwapchain(chain), "reverse completion order");
    }

    private static void AcquiredImageIdentity()
    {
        var ledger = new RetirementLedger(7, 3);
        var chain = Chain(ledger, RetirementMode.Reacquire);
        var a = Queue(ledger, chain, 11, 2);
        var b = Queue(ledger, chain, 12, 0);
        ledger.ObserveSubmitCompletion(a);
        ledger.ObserveSubmitCompletion(b);
        Check(ledger.Blockers(chain).Presents == 2, "frame indices must not retire images");
        var c = Queue(ledger, chain, 11, 2);
        Check(ledger.Blockers(chain).Presents == 3, "acquire return alone is not completion");
        ledger.ObserveSubmitCompletion(c);
        Check(a.PresentDone && !b.PresentDone && !c.PresentDone, "waited image 2 retires only its predecessor");
        var d = Queue(ledger, chain, 12, 0);
        ledger.ObserveSubmitCompletion(d);
        Check(b.PresentDone && !d.PresentDone, "shuffled acquired image 0");
        var e = Queue(ledger, chain, 11, 0);
        ledger.ObserveSubmitCompletion(e);
        Check(d.PresentDone && !e.PresentDone, "consecutive acquisition of same image");
        Reject(() => ledger.ObservePresentFence(e), "raw support cannot enable a fence");
        ledger.RetireGeneration(1);
        Check(!ledger.CanDestroySwapchain(chain), "no-fence hard detach remains unresolved");
        Check(ledger.Blockers(chain).Presents == 2, "last presentations retained, no idle shortcut");
    }

    private static void RevokedAcquire()
    {
        var ledger = new RetirementLedger(7, 3);
        var chain = Chain(ledger, RetirementMode.Reacquire);
        var record = ledger.BeginAcquire(chain, 11);
        ledger.FinishAcquire(record, AcquireOutcome.Acquired, 0);
        ledger.RetireGeneration(1);
        Check(!ledger.CanDestroySwapchain(chain), "acquired image blocks retirement");
        Check(ledger.Blockers(chain).Acquires == 1, "acquired image is the only blocker");
        // A successful acquire is only dropped by a queue submission that waits on its
        // semaphore; instant destroy of a still-signaled acquire semaphore must fail.
        ledger.SubmitForRetirement(record);
        Check(!ledger.CanDestroySwapchain(chain), "unproven retirement submit still blocks");
        Check(ledger.Blockers(chain).Submits == 1, "wait-only submit is the sole new blocker");
        Reject(() => ledger.PresentReturned(record, PresentOutcome.Queued, false), "retirement submit cannot present");
        ledger.ObserveSubmitCompletion(record);
        Check(ledger.Blockers(chain).Empty, "drained acquire leaves no obligation");
        Check(ledger.CanDestroySwapchain(chain), "drained acquire permits swapchain destruction");
        Reject(() => ledger.SubmitQueued(record), "drained acquire cannot submit");
        ledger.ConfirmSwapchainDestroyed(chain);
        Check(ledger.CanDestroySurface(1), "drained generation can be acknowledged");
        var next = Chain(ledger, RetirementMode.Reacquire, generation: 2);
        var reuse = ledger.BeginAcquire(next, 11);
        Check(ledger.Blockers(next).Acquires == 1, "drained semaphore is free for the replacement chain");
        ledger.FinishAcquire(reuse, AcquireOutcome.Timeout);
        ledger.RetireGeneration(2);
        Check(ledger.CanDestroySwapchain(next), "failed replacement acquire leaves no debt");
        ledger.ConfirmSwapchainDestroyed(next);
        Check(ledger.CanDestroySurface(2), "replacement generation can be acknowledged");
    }

    // The image slot must not be cleared while its previous present is unproven: clearing it
    // without a waited reacquire strands Blockers forever (the stuck-last-frame defect).
    private static void RevokedAcquireKeepsPreviousPresent()
    {
        var ledger = new RetirementLedger(7, 3);
        var chain = Chain(ledger, RetirementMode.Reacquire);
        var prior = Queue(ledger, chain, 10, 0);
        ledger.ObserveSubmitCompletion(prior);
        var record = ledger.BeginAcquire(chain, 11);
        ledger.FinishAcquire(record, AcquireOutcome.Acquired, 0);
        ledger.RetireGeneration(1);
        Check(!ledger.CanDestroySwapchain(chain), "unproven acquire cannot destroy the chain");
        Check(ledger.Blockers(chain).Presents == 1, "previous presentation remains owed");
        ledger.SubmitForRetirement(record);
        ledger.ObserveSubmitCompletion(record);
        Check(prior.PresentDone, "wait-only submit retires the image's previous present");
        Check(ledger.Blockers(chain).Empty, "drain discharges every obligation");
        Check(ledger.CanDestroySwapchain(chain), "completed drain permits destruction");
        ledger.ConfirmSwapchainDestroyed(chain);
        var next = Chain(ledger, RetirementMode.Reacquire, generation: 2);
        var reuse = ledger.BeginAcquire(next, 11);
        Check(ledger.Blockers(next).Acquires == 1, "semaphore returns to the replacement chain");
        ledger.FinishAcquire(reuse, AcquireOutcome.Timeout);
        ledger.RetireGeneration(2);
        ledger.ConfirmSwapchainDestroyed(next);
    }

    private static void FailureOwnership()
    {
        var ledger = new RetirementLedger(7, 3);
        var chain = Chain(ledger, RetirementMode.EnabledPresentFence);
        foreach (var outcome in new[] { AcquireOutcome.Timeout, AcquireOutcome.NotReady })
        {
            var empty = ledger.BeginAcquire(chain, 11);
            ledger.FinishAcquire(empty, outcome);
            Reject(() => ledger.SubmitQueued(empty), "no submission after failed acquire");
        }
        var acquired = ledger.BeginAcquire(chain, 11);
        ledger.FinishAcquire(acquired, AcquireOutcome.Suboptimal, 1);
        Reject(() => ledger.BeginAcquire(chain, 11), "acquire semaphore cannot be recycled before its wait");
        ledger.SubmitQueued(acquired);
        Reject(() => ledger.BeginAcquire(chain, 11), "queued submit is not completed submit");
        ledger.PresentReturned(acquired, PresentOutcome.UncertainFailure, true);
        ledger.ObserveSubmitCompletion(acquired);
        Check(ledger.Blockers(chain).UncertainOperations == 1, "present error retained");
        Check(!ledger.CanDestroySwapchain(chain), "present error does not mean unqueued");
        ledger.ObservePresentFence(acquired);
        Check(ledger.CanDestroySwapchain(chain), "actual present fence can resolve error ownership");

        ledger = new(7, 3);
        chain = Chain(ledger, RetirementMode.Reacquire);
        var uncertain = ledger.BeginAcquire(chain, 13);
        ledger.FinishAcquire(uncertain, AcquireOutcome.UncertainFailure);
        Check(ledger.Blockers(chain).UncertainOperations == 1, "acquire error quarantined");
        var other = Chain(ledger, RetirementMode.Reacquire, revision: 1);
        Reject(() => ledger.BeginAcquire(other, 13), "uncertain acquire semaphore not reused across swapchains");
        Reject(() => ledger.SubmitQueued(uncertain), "uncertain acquisition never submitted");
        var failedSubmit = ledger.BeginAcquire(other, 14);
        ledger.FinishAcquire(failedSubmit, AcquireOutcome.Acquired, 0);
        ledger.SubmitFailed(failedSubmit);
        Reject(() => ledger.ObserveSubmitCompletion(failedSubmit), "failed submission not a fence proof");
        Reject(() => ledger.PresentReturned(failedSubmit, PresentOutcome.Queued, false), "failed submit cannot present");
        Check(ledger.Blockers(other).UncertainOperations == 1, "failed submit retained");

        ledger = new(7, 3);
        chain = Chain(ledger, RetirementMode.Reacquire);
        var noImage = ledger.BeginAcquire(chain, 15);
        ledger.FinishAcquire(noImage, AcquireOutcome.FailedWithoutImage);
        Check(ledger.CanDestroySwapchain(chain), "observed out-of-date/no-image can retire empty swapchain");
        Reject(() => ledger.SubmitQueued(noImage), "known no-image failure cannot submit");
        ledger.ConfirmSwapchainDestroyed(chain);
        other = Chain(ledger, RetirementMode.Reacquire, revision: 1);
        var retry = ledger.BeginAcquire(other, 15);
        ledger.FinishAcquire(retry, AcquireOutcome.Timeout);
        Check(ledger.Blockers(other).Empty, "known unaffected semaphore can be used on replacement");
    }

    private static void StopLossAndEpochs()
    {
        var ledger = new RetirementLedger(7, 3);
        var old = Chain(ledger, RetirementMode.EnabledPresentFence, revision: 1);
        var oldFrame = Queue(ledger, old, 11, 0, true);
        ledger.RetireSwapchain(old);
        var current = Chain(ledger, RetirementMode.EnabledPresentFence, revision: 1);
        Check(current.Serial != old.Serial, "same revision recreation has a separate identity");
        var newFrame = Queue(ledger, current, 12, 0, true);
        ledger.ObserveSubmitCompletion(oldFrame);
        ledger.ObservePresentFence(oldFrame);
        Check(!newFrame.PresentDone && !newFrame.SubmitDone, "old completion cannot retire new swapchain");
        Reject(() => Chain(ledger, RetirementMode.Reacquire, revision: 0), "old revision rejected");
        var foreign = new RetirementLedger(7, 4);
        Reject(() => foreign.ObserveSubmitCompletion(newFrame), "device generation / owner mismatch rejected");
        ledger.Stop();
        Reject(() => ledger.BeginAcquire(current, 13), "no acquisition after stop");
        ledger.ObserveSubmitCompletion(newFrame);
        Check(!ledger.CanDestroySwapchain(current), "stop preserves present debt");
        ledger.ObservePresentFence(newFrame);
        ledger.ConfirmSwapchainDestroyed(old);
        ledger.ConfirmSwapchainDestroyed(current);
        Check(ledger.CanDestroySurface(1), "stop can finish without another frame");

        ledger = new(7, 3);
        current = Chain(ledger, RetirementMode.EnabledPresentFence);
        newFrame = Queue(ledger, current, 11, 1, true);
        ledger.LoseDevice();
        Check(ledger.Blockers(current).DeviceLost && !ledger.CanDestroySwapchain(current), "loss is not retirement");
        Reject(() => ledger.ObserveSubmitCompletion(newFrame), "device-lost fence result cannot mean signaled");
        Reject(() => ledger.ObservePresentFence(newFrame), "device-lost present fence not signaled");
        Reject(() => ledger.BeginAcquire(current, 12), "no acquisition after loss");
        Check(!ledger.CanDestroySurface(1), "loss cannot manufacture normal ACK");

        // A resize retires the old revision while the new revision is already live. The old
        // chain keeps its unproven present as its own debt and must not block the new chain;
        // it also must not be destroyed, because stopping acquisition removes the only
        // reacquire proof a Reacquire-mode chain has.
        ledger = new(7, 3);
        var oldRevision = Chain(ledger, RetirementMode.Reacquire, revision: 1);
        Queue(ledger, oldRevision, 21, 0);
        ledger.RetireSwapchain(oldRevision);
        var newRevision = Chain(ledger, RetirementMode.Reacquire, revision: 2);
        Queue(ledger, newRevision, 22, 1);
        Check(!ledger.CanDestroySwapchain(oldRevision) && ledger.Blockers(oldRevision).Presents == 1,
            "retired revision keeps its unproven present");
        Check(ledger.Blockers(newRevision).Presents == 1, "new revision presents independently");
        Reject(() => ledger.BeginAcquire(oldRevision, 23), "retired chain stops acquiring");
        Check(!ledger.CanDestroySurface(1), "surface waits for the retained chain");
        var revisionFrame = Queue(ledger, newRevision, 24, 0);
        ledger.ObserveSubmitCompletion(revisionFrame);
        Check(!ledger.CanDestroySwapchain(oldRevision) && !ledger.CanDestroySwapchain(newRevision),
            "neither revision's debt is discharged by the other");
        ledger.RetireSwapchain(newRevision);
    }

    // A scripted function table checks marshaling/consumer invariants only. It deliberately
    // does not reimplement lease mutexes, waits or producer transitions. NativeLeaseTest below
    // runs those against the unchanged C implementation on Linux, as a separate reported gate.
    private static NativeLeaseState _scripted;
    private static int _takes, _drops, _acks, _wakes;
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static int Take(nint lease, NativeLeaseState* state)
    {
        *state = _scripted;
        if (state->Window != 0) { _takes++; }
        return 0;
    }
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static int Wait(nint lease, NativeLeaseState* state, int timeout) => 0;
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void Drop(nint lease, nint window) => _drops++;
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void Ack(nint lease, ulong generation) => _acks++;
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void Wake(nint lease) => _wakes++;

    private static void Binding(string abiFile)
    {
        int[] native = File.ReadAllText(abiFile).Trim().Split(' ').Select(int.Parse).ToArray();
        int[] managed = { sizeof(NativeLeaseState), sizeof(NativeLeaseApi),
            (int)Marshal.OffsetOf<NativeLeaseState>(nameof(NativeLeaseState.Window)),
            (int)Marshal.OffsetOf<NativeLeaseState>(nameof(NativeLeaseState.InsetLeft)),
            (int)Marshal.OffsetOf<NativeLeaseState>(nameof(NativeLeaseState.WakeSequence)),
            (int)Marshal.OffsetOf<NativeLeaseApi>(nameof(NativeLeaseApi.Lease)),
            (int)Marshal.OffsetOf<NativeLeaseApi>(nameof(NativeLeaseApi.Wait)),
            (int)Marshal.OffsetOf<NativeLeaseApi>(nameof(NativeLeaseApi.Wake)) };
        Check(native.SequenceEqual(managed), "C header / C# ABI exact sizes and offsets");
        NativeLeaseApi api = new() { Size = (uint)sizeof(NativeLeaseApi), Version = 1,
            Lease = 1, Take = &Take, Wait = &Wait, ReleaseWindow = &Drop, Released = &Ack, Wake = &Wake };
        nint pointer = (nint)(&api);
        _scripted = new() { Session = 7, Generation = 1, Revision = 1, Window = 91,
            Width = 800, Height = 600, Foreground = 1 };
        var lease = new NativeLease(pointer, 7, 3);
        lease.Poll();
        var stamp = _scripted.Stamp;
        Check(lease.MayPresent(stamp), "current generation/revision eligible");
        _scripted.Revision++;
        lease.Poll();
        Check(!lease.MayPresent(stamp) && _takes == 2 && _drops == 1, "stale queued viewport and duplicate take ref");
        var chain = lease.Retirement.RegisterSwapchain(_scripted.Stamp, 3, RetirementMode.EnabledPresentFence);
        var frame = Queue(lease.Retirement, chain, 11, 1, true);
        _scripted.Window = 0;
        _scripted.Revision++;
        lease.Poll(); // Control event only: no frame call drives revoke progress.
        Check(lease.RetirementRequested && lease.WindowForSurface == 0, "revoke observed without frames");
        Check(!lease.TryReleaseRetired(() => throw new Exception("early destroy")), "pending work blocks ACK");
        lease.Retirement.ObserveSubmitCompletion(frame);
        Check(!lease.TryReleaseRetired(() => throw new Exception("early destroy")), "submit alone blocks ACK");
        lease.Retirement.ObservePresentFence(frame);
        lease.Retirement.ConfirmSwapchainDestroyed(chain);
        Reject(() => lease.TryReleaseRetired(() => throw new InvalidOperationException("destroy failed")), "failed destruction cannot ACK");
        Check(_acks == 0 && _drops == 1, "failed destruction preserves native reference");
        Check(lease.TryReleaseRetired(() => { }), "release after both proofs and object destruction");
        Check(_acks == 1 && _drops == 2, "exactly one ACK and reference drop");
        Check(!lease.TryReleaseRetired(() => { }), "release is not repeated");
        _scripted.Generation = 2;
        _scripted.Revision = 0;
        _scripted.Window = 91; // Same native pointer, new generation.
        lease.Poll();
        Check(lease.HeldGeneration == 2 && !lease.MayPresent(stamp), "pointer equality cannot revive old frame");
        lease.Stop();
        Check(lease.TryReleaseRetired(() => { }) && _acks == 2, "no-frame stop releases empty generation");
        Reject(() => lease.WaitForChange(-1), "consumer waits are bounded");
        lease.Wake();
        Check(_wakes == 1, "existing native wake function used");
        api.Version = 2;
        Reject(() => new NativeLease(pointer, 7, 3), "unknown ABI rejected");
        api.Version = 1;
        api.Size = 8;
        Reject(() => new NativeLease(pointer, 7, 3), "short ABI rejected before pointer copy");
        api.Size = (uint)sizeof(NativeLeaseApi);
        api.Take = null;
        Reject(() => new NativeLease(pointer, 7, 3), "null function rejected");
        api.Take = &Take;
        _scripted.Generation = 1;
        _scripted.Revision = 0;
        _scripted.Session = 8;
        var lost = new NativeLease(pointer, 8, 4);
        lost.Poll();
        lost.Retirement.LoseDevice();
        lost.Poll();
        Check(lost.WindowForSurface == 0 && !lost.MayPresent(_scripted.Stamp), "loss rejects surface creation and presentation");
        int acknowledgements = _acks;
        Check(!lost.TryReleaseRetired(() => throw new Exception("early destroy")) && _acks == acknowledgements,
            "device loss preserves the real ACK obligation");
        // The loss scenario intentionally retains a reference: process termination, not a
        // fabricated normal ACK, is the remaining policy. This function table is scripted.
    }

    private static void NativeLeaseTest(string library)
    {
        nint module = NativeLibrary.Load(Path.GetFullPath(library));
        var create = (delegate* unmanaged[Cdecl]<ulong, nint>)NativeLibrary.GetExport(module, "fixture_create");
        var refs = (delegate* unmanaged[Cdecl]<nuint, int>)NativeLibrary.GetExport(module, "fixture_refs");
        var fill = (delegate* unmanaged[Cdecl]<nint, NativeLeaseApi*, void>)NativeLibrary.GetExport(module, "s2a_wsi_api_fill");
        var offer = (delegate* unmanaged[Cdecl]<nint, nint, ulong>)NativeLibrary.GetExport(module, "s2a_wsi_offer");
        var update = (delegate* unmanaged[Cdecl]<nint, int, int, uint, int*, float, void>)NativeLibrary.GetExport(module, "s2a_wsi_update");
        var foreground = (delegate* unmanaged[Cdecl]<nint, int, void>)NativeLibrary.GetExport(module, "s2a_wsi_set_foreground");
        var revoke = (delegate* unmanaged[Cdecl]<nint, int, int>)NativeLibrary.GetExport(module, "s2a_wsi_revoke");
        var destroy = (delegate* unmanaged[Cdecl]<nint, void>)NativeLibrary.GetExport(module, "s2a_wsi_destroy");
        nint native = create(7);
        Check(native != 0, "real C lease created");
        NativeLeaseApi api;
        fill(native, &api);
        var lease = new NativeLease((nint)(&api), 7, 3);
        Check(offer(native, 1) == 1, "real generation 1 offered");
        update(native, 800, 600, 2, null, 120);
        foreground(native, 1);
        lease.Poll();
        Check(refs(1) == 2 && lease.MayPresent(lease.State.Stamp), "real take retains one ref");
        lease.Poll();
        Check(refs(1) == 2, "real repeated take is balanced");
        lease.Wake();
        Check(lease.WaitForChange(0) == 1, "real wake between poll and wait is not lost");
        lease.Poll();
        Check(lease.WaitForChange(0) == 0, "real unchanged poll timeout");
        var chain = lease.Retirement.RegisterSwapchain(lease.State.Stamp, 3,
            RetirementMode.EnabledPresentFence);
        var frame = Queue(lease.Retirement, chain, 11, 2, true);
        Check(revoke(native, 0) != 0, "real revoke cannot complete while consumer holds generation");
        lease.Poll();
        Check(refs(1) == 1 && lease.RetirementRequested, "real revoke seen without a frame");
        Check(!lease.TryReleaseRetired(() => throw new Exception("early destroy")), "real lease pending work blocks ACK");
        lease.Retirement.ObserveSubmitCompletion(frame);
        Check(!lease.TryReleaseRetired(() => throw new Exception("early destroy")), "real lease submit does not ACK present");
        Check(revoke(native, 0) != 0, "native held generation still pending");
        lease.Retirement.ObservePresentFence(frame);
        lease.Retirement.ConfirmSwapchainDestroyed(chain);
        Check(lease.TryReleaseRetired(() => { }), "real generation release ACK after scripted retirement proofs");
        Check(revoke(native, 0) == 0 && refs(1) == 0, "real ACK unblocks native revoke");
        Check(offer(native, 1) == 2, "same pointer gets new generation");
        lease.Poll();
        Check(offer(native, 2) == 3, "replacement offered before release");
        lease.Poll();
        Check(lease.HeldGeneration == 2 && lease.RetirementRequested, "real EBUSY keeps old ownership");
        Check(lease.TryReleaseRetired(() => { }), "old generation retired before taking replacement");
        lease.Poll();
        Check(lease.HeldGeneration == 3 && refs(1) == 0 && refs(2) == 2, "replacement taken after actual ACK");
        lease.Stop();
        Check(lease.TryReleaseRetired(() => { }), "consumer stop releases without a new frame");
        destroy(native);
        Check(refs(1) == 0 && refs(2) == 0, "real C lifetime has no leaked window references");
        NativeLibrary.Free(module);
        Console.WriteLine("real-native-lease: PASS (unchanged production C, synthetic window ref callbacks)");
    }

    private static int Main(string[] args)
    {
        if (args.Length == 0) args = [Path.Combine(AppContext.BaseDirectory, "abi-layout.txt")];
        if (args.Length is < 1 or > 2)
        {
            Console.Error.WriteLine("WsiTests <C-header-layout.txt> [production-lease-fixture.so]");
            return 2;
        }
        try
        {
            IdleAssumptionRetirement();
            FenceRetirement();
            AcquiredImageIdentity();
            RevokedAcquire();
            RevokedAcquireKeepsPreviousPresent();
            FailureOwnership();
            StopLossAndEpochs();
            Binding(args[0]);
            if (args.Length == 2) { NativeLeaseTest(args[1]); }
            else { Console.WriteLine("real-native-lease: NOT RUN; managed/scripted tests are not pthread proof"); }
            Console.WriteLine($"PASS: {_assertions} assertions; GPU/presentation engine/gameplay NOT RUN");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"FAIL after {_assertions} assertions: {error}");
            return 1;
        }
    }
}

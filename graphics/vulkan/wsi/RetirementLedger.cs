using System;
using System.Collections.Generic;
using System.Linq;

namespace S2Arm.Backends.Vulkan.Wsi;

// Local W6 types, not a frozen W5/GAL or platform ABI. One backend thread owns this ledger.
internal enum AcquireOutcome { Acquired, Suboptimal, Timeout, NotReady, FailedWithoutImage, UncertainFailure }
internal enum PresentOutcome { Queued, Suboptimal, UncertainFailure }
internal enum RetirementMode { Reacquire, EnabledPresentFence }

internal readonly record struct WindowStamp(ulong Session, ulong Generation, ulong Revision);
internal readonly record struct RetirementBlockers(int Acquires, int Submits, int Presents,
    int UncertainOperations, bool DeviceLost)
{
    public bool Empty => Acquires == 0 && Submits == 0 && Presents == 0 &&
        UncertainOperations == 0 && !DeviceLost;
}

// These are identities, not Vulkan handles. A serial prevents recreation at the same revision
// from aliasing the old swapchain. Queue/driver ownership remains with the borrowed renderer.
internal sealed class SwapchainRecord
{
    internal readonly RetirementLedger Owner;
    internal readonly List<AcquireRecord> Acquires = new();
    internal readonly AcquireRecord?[] Images;
    internal bool Retiring;
    internal bool Destroyed;
    internal bool PresentAssumedIdle;

    public WindowStamp Window { get; }
    public ulong DeviceGeneration { get; }
    public ulong Serial { get; }
    public RetirementMode Mode { get; }

    internal SwapchainRecord(RetirementLedger owner, WindowStamp window, ulong serial,
        int images, RetirementMode mode)
    {
        Owner = owner;
        Window = window;
        DeviceGeneration = owner.DeviceGeneration;
        Serial = serial;
        Images = new AcquireRecord?[images];
        Mode = mode;
    }
}

internal sealed class AcquireRecord
{
    internal enum Phase { Acquiring, NoImage, Acquired, Submitted, RetirementSubmitted, UncertainAcquire, UncertainSubmit }
    internal Phase State;
    internal AcquireRecord? PreviousPresent;
    internal bool SubmitDone;
    internal bool PresentCalled;
    internal bool PresentFenceAttached;
    internal bool PresentDone;
    internal bool PresentAssumedIdle;
    internal bool PresentUncertain;
    internal bool Collected;

    public SwapchainRecord Swapchain { get; }
    public ulong AcquireSemaphore { get; }
    public int ImageIndex { get; internal set; } = -1;

    internal AcquireRecord(SwapchainRecord swapchain, ulong semaphore)
    {
        Swapchain = swapchain;
        AcquireSemaphore = semaphore;
    }
}

// Real completion and the owner-approved queue-idle compatibility assumption are distinct.
// This ledger never calls Vulkan: callers must supply observations from the actual driver.
internal sealed class RetirementLedger
{
    private readonly List<SwapchainRecord> _swapchains = new();
    private readonly Dictionary<ulong, AcquireRecord> _acquireSemaphores = new();
    private readonly HashSet<ulong> _retiringGenerations = new();
    private readonly Dictionary<ulong, ulong> _lastRevision = new();
    private ulong _serial;
    private bool _stopping;

    public ulong Session { get; }
    public ulong DeviceGeneration { get; }
    public bool DeviceLost { get; private set; }

    public RetirementLedger(ulong session, ulong deviceGeneration)
    {
        if (session == 0 || deviceGeneration == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(session));
        }
        Session = session;
        DeviceGeneration = deviceGeneration;
    }

    public SwapchainRecord RegisterSwapchain(WindowStamp window, int imageCount,
        RetirementMode mode)
    {
        Require(!DeviceLost && !_stopping, "Device is not accepting work.");
        Require(window.Session == Session && window.Generation != 0, "Wrong window identity.");
        Require(!_retiringGenerations.Contains(window.Generation), "Generation is retiring.");
        Require(imageCount > 0, "A swapchain must contain images.");
        Require(Enum.IsDefined(mode), "Unknown retirement mode.");
        Require(!_lastRevision.TryGetValue(window.Generation, out ulong prior) ||
            window.Revision >= prior, "Revision moved backwards.");
        var record = new SwapchainRecord(this, window, checked(++_serial), imageCount, mode);
        _lastRevision[window.Generation] = window.Revision;
        _swapchains.Add(record);
        return record;
    }

    // Call before the actual acquire. The semaphore ID names a concrete live binary semaphore,
    // not a frame-slot number; it cannot be reused while a previous acquire/submit owns it.
    public AcquireRecord BeginAcquire(SwapchainRecord swapchain, ulong semaphore)
    {
        Check(swapchain);
        Require(!DeviceLost && !_stopping && !swapchain.Retiring, "Swapchain is not accepting work.");
        Require(semaphore != 0 && !_acquireSemaphores.ContainsKey(semaphore),
            "Acquire semaphore is still owned by an earlier operation.");
        var record = new AcquireRecord(swapchain, semaphore);
        swapchain.Acquires.Add(record);
        _acquireSemaphores.Add(semaphore, record);
        return record;
    }

    public void FinishAcquire(AcquireRecord record, AcquireOutcome outcome, int image = -1)
    {
        Check(record);
        Require(record.State == AcquireRecord.Phase.Acquiring, "Acquire already resolved.");
        Require(Enum.IsDefined(outcome), "Unknown acquire outcome.");
        if (outcome is AcquireOutcome.Timeout or AcquireOutcome.NotReady or AcquireOutcome.FailedWithoutImage)
        {
            // An observed unsuccessful acquire leaves synchronization objects unaffected.
            // Timeout/not-ready can retry. Other known no-image results (e.g. OUT_OF_DATE)
            // retire this swapchain but do not poison a known-unsignaled semaphore.
            Require(image == -1, "Failed acquire cannot carry an image index.");
            if (outcome == AcquireOutcome.FailedWithoutImage)
            {
                record.Swapchain.Retiring = true;
            }
            record.State = AcquireRecord.Phase.NoImage;
            _acquireSemaphores.Remove(record.AcquireSemaphore);
            Collect(record);
            return;
        }
        if (outcome == AcquireOutcome.UncertainFailure)
        {
            Require(image == -1, "Uncertain acquire cannot carry an image index.");
            record.State = AcquireRecord.Phase.UncertainAcquire;
            record.Swapchain.Retiring = true;
            return; // Do not recycle its semaphore or manufacture a successful teardown.
        }
        Require(image >= 0 && image < record.Swapchain.Images.Length, "Invalid acquired image.");
        AcquireRecord? previous = record.Swapchain.Images[image];
        Require(previous == null || previous.PresentCalled, "Image still has an unpresented owner.");
        record.PreviousPresent = previous;
        record.ImageIndex = image;
        record.State = AcquireRecord.Phase.Acquired;
        record.Swapchain.Images[image] = record;
    }

    // Record success only after the one borrowed queue accepted a submission that waits on
    // this acquire semaphore and contains the final source-texture use. That dependency also
    // permits signalling the per-IMAGE render-finished semaphore again, without a CPU wait.
    public void SubmitQueued(AcquireRecord record)
    {
        Check(record);
        Require(!DeviceLost && !_stopping, "No new submission after stop/loss.");
        Require(record.State == AcquireRecord.Phase.Acquired, "Submit needs an acquired image.");
        record.State = AcquireRecord.Phase.Submitted;
    }

    // Stop/revoke may arrive after a successful acquire. Drain that accepted operation by
    // submitting its recorded source use and waiting on the acquire semaphore, without
    // signalling render-finished or calling QueuePresent. This is not a new frame admission.
    // The acquired image stays with the retiring swapchain until destruction; its actual
    // submit completion proves all uses of that image finished (vkDestroySwapchainKHR-01282).
    public void SubmitForRetirement(AcquireRecord record)
    {
        Check(record);
        Require(!DeviceLost && record.State == AcquireRecord.Phase.Acquired,
            "Retirement submit needs an existing acquired image on a live device.");
        record.State = AcquireRecord.Phase.RetirementSubmitted;
        record.Swapchain.Retiring = true;
    }

    public void SubmitFailed(AcquireRecord record)
    {
        Check(record);
        Require(record.State == AcquireRecord.Phase.Acquired, "Submit needs an acquired image.");
        record.State = AcquireRecord.Phase.UncertainSubmit;
        record.Swapchain.Retiring = true;
    }

    public void PresentReturned(AcquireRecord record, PresentOutcome outcome, bool fenceAttached)
    {
        Check(record);
        Require(!DeviceLost && !_stopping, "No new present after stop/loss.");
        Require(record.State == AcquireRecord.Phase.Submitted && !record.PresentCalled,
            "Present requires one successful submission and may be recorded only once.");
        Require(Enum.IsDefined(outcome), "Unknown present outcome.");
        Require(!fenceAttached || record.Swapchain.Mode == RetirementMode.EnabledPresentFence,
            "Present fence feature was not enabled.");
        record.PresentCalled = true;
        record.PresentFenceAttached = fenceAttached;
        record.PresentUncertain = outcome == PresentOutcome.UncertainFailure;
        if (record.PresentUncertain)
        {
            record.Swapchain.Retiring = true;
        }
    }

    public void ObserveSubmitCompletion(AcquireRecord record)
    {
        Check(record);
        Require(!DeviceLost && (record.State is AcquireRecord.Phase.Submitted or AcquireRecord.Phase.RetirementSubmitted) && !record.SubmitDone,
            "Completion needs a live, successful submission.");
        record.SubmitDone = true;
        _acquireSemaphores.Remove(record.AcquireSemaphore);
        // This submit waited for reacquisition of the SAME image from the SAME swapchain.
        // It retires the PREVIOUS present, never the present belonging to this submission.
        if (record.PreviousPresent is { PresentDone: false } previous)
        {
            previous.PresentDone = true;
            previous.PresentUncertain = false;
            Collect(previous);
        }
        record.PreviousPresent = null;
        Collect(record);
    }

    public void ObservePresentFence(AcquireRecord record)
    {
        Check(record);
        Require(!DeviceLost && record.PresentCalled && record.PresentFenceAttached && !record.PresentDone,
            "No pending, enabled present fence for this operation.");
        record.PresentDone = true;
        record.PresentUncertain = false;
        Collect(record);
    }

    // This is a compatibility assumption, not proof of present completion. The caller must
    // have observed VK_SUCCESS from the present queue's actual QueueWaitIdle, after this
    // eligibility check and while queue submission is externally synchronized.
    public bool CanAssumeQueueIdle(SwapchainRecord swapchain)
    {
        Check(swapchain);
        return swapchain.Retiring && !DeviceLost &&
            swapchain.Acquires.Any(r => r.PresentCalled && !r.PresentDone && !r.PresentAssumedIdle) &&
            swapchain.Acquires.All(r => r.State switch
            {
                AcquireRecord.Phase.Submitted => r.SubmitDone && r.PresentCalled,
                AcquireRecord.Phase.RetirementSubmitted => r.SubmitDone,
                _ => false,
            });
    }

    public void ObserveQueueIdleAssumption(SwapchainRecord swapchain)
    {
        Require(CanAssumeQueueIdle(swapchain), "Queue idle assumption requires a retired chain with completed submissions and no unowned operations.");
        swapchain.PresentAssumedIdle = true;
        foreach (AcquireRecord record in swapchain.Acquires.ToArray())
        {
            if (record.PresentCalled && !record.PresentDone && !record.PresentAssumedIdle)
            {
                record.PresentAssumedIdle = true;
                Collect(record);
            }
        }
    }

    public bool SourceUseComplete(AcquireRecord record)
    {
        Require(record.Swapchain.Owner == this, "Foreign record.");
        return record.SubmitDone;
    }

    public void RetireSwapchain(SwapchainRecord swapchain)
    {
        Check(swapchain);
        swapchain.Retiring = true;
    }

    public void RetireGeneration(ulong generation)
    {
        Require(generation != 0, "Invalid generation.");
        _retiringGenerations.Add(generation);
        foreach (var chain in _swapchains.Where(c => c.Window.Generation == generation))
        {
            chain.Retiring = true;
        }
    }

    public void Stop()
    {
        _stopping = true;
        foreach (var chain in _swapchains)
        {
            RetireGeneration(chain.Window.Generation);
        }
    }

    public void LoseDevice()
    {
        DeviceLost = true;
        Stop(); // Loss is not a completion observation; retain all unresolved ownership.
    }

    public RetirementBlockers Blockers(SwapchainRecord swapchain)
    {
        Check(swapchain);
        return new RetirementBlockers(
            swapchain.Acquires.Count(r => r.State is AcquireRecord.Phase.Acquiring or AcquireRecord.Phase.Acquired),
            swapchain.Acquires.Count(r => (r.State is AcquireRecord.Phase.Submitted or AcquireRecord.Phase.RetirementSubmitted) && !r.SubmitDone),
            swapchain.Acquires.Count(r => r.State == AcquireRecord.Phase.Submitted && !r.PresentDone && !r.PresentAssumedIdle),
            swapchain.Acquires.Count(r => r.State is AcquireRecord.Phase.UncertainAcquire or
                AcquireRecord.Phase.UncertainSubmit || (r.PresentUncertain && !r.PresentAssumedIdle)), DeviceLost);
    }

    public bool CanDestroySwapchain(SwapchainRecord swapchain)
    {
        return swapchain.Retiring && Blockers(swapchain).Empty;
    }

    // Call AFTER successful destruction of its views, semaphores and swapchain. This is not
    // itself a destructor. The caller must not destroy first and ask permission afterwards.
    public void ConfirmSwapchainDestroyed(SwapchainRecord swapchain)
    {
        Require(CanDestroySwapchain(swapchain), "Swapchain still owns unfinished operations.");
        swapchain.Destroyed = true;
        _swapchains.Remove(swapchain);
    }

    public bool CanDestroySurface(ulong generation)
    {
        return !DeviceLost && _retiringGenerations.Contains(generation) &&
            !_swapchains.Any(c => c.Window.Generation == generation);
    }

    private void Collect(AcquireRecord record)
    {
        if (!record.Collected && (record.State == AcquireRecord.Phase.NoImage ||
            (record.SubmitDone && (record.PresentDone || record.PresentAssumedIdle || record.State == AcquireRecord.Phase.RetirementSubmitted))))
        {
            record.Collected = true;
            record.Swapchain.Acquires.Remove(record);
            if (record.ImageIndex >= 0 && record.Swapchain.Images[record.ImageIndex] == record)
            {
                record.Swapchain.Images[record.ImageIndex] = null;
            }
        }
    }

    private void Check(SwapchainRecord chain)
    {
        Require(chain.Owner == this && !chain.Destroyed, "Foreign or destroyed swapchain.");
    }

    private void Check(AcquireRecord record)
    {
        Check(record.Swapchain);
        Require(!record.Collected, "Operation has already retired.");
    }

    internal static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}

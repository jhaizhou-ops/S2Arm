// SPDX-License-Identifier: MIT
// Copyright (c) Ryujinx Team and Contributors
// Texture-view construction and final blit derive from the pinned Ryujinx Window.cs.
// See LICENSE.Ryujinx.txt. Synchronization uses the existing W6 RetirementLedger.
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using Semaphore = Silk.NET.Vulkan.Semaphore;
using VkFormat = Silk.NET.Vulkan.Format;

namespace S2Arm.Backends.Vulkan.Wsi;

internal sealed unsafe class AndroidWindow : WindowBase
{
    [DllImport("s2a_native")]
    private static extern void s2a_android_game_touch_viewport(ulong generation, int left, int top,
        int width, int height, int bufferWidth, int bufferHeight);
    // t-direct-frametimes：逐帧上屏间隔记录（direct/generic 同一环形缓冲）；默认关，关态原生侧只比一次缓存标志。
    [DllImport("s2a_native")]
    private static extern void s2a_frame_log_present_timed(ulong acquireNs, ulong presentNs);
    private sealed class Pending
    {
        public AcquireRecord Record;
        public FenceHolder Submit;
        public Fence Present;
        public Result? SubmitStatus, PresentStatus;
    }

    private readonly VulkanRenderer _renderer;
    private readonly AndroidVulkanSurface _host;
    private readonly PhysicalDevice _physical;
    private readonly Device _device;
    // One live swapchain and its resources. A window revision change retires the chain but a
    // new revision may need its own chain before the old one can be proven safe to destroy, so
    // both must be able to coexist.
    private sealed class Chain
    {
        public SwapchainRecord Record = null!;
        public SwapchainKHR Swapchain;
        public Image[] Images = Array.Empty<Image>();
        public TextureView[] Views = Array.Empty<TextureView>();
        public Semaphore[] Acquire = Array.Empty<Semaphore>();
        public Semaphore[] Finished = Array.Empty<Semaphore>();
        public int Width, Height;
        public long RetiringSince;
        public ForegroundBudget FenceGrace;
        public long LastReport;
        public bool RetireLogged;
        // Observations belong to this exact chain, never a later window revision.
        public NativeLeaseState InitialState;
        public Result? LastAcquire, LastPresent, LastPresentSwapchain;
        public bool? PoolCollected;
        public bool StartupReported, PendingReported;
        public long LastAcquireReport;
        public string RetirementReason;
    }

    private readonly List<Pending> _pending = [];
    private readonly List<Chain> _chains = [];
    private Chain _current;
    private long _lastCreate;
    private long _lastSuboptimalLog;
    private WindowStamp _viewportWaitStamp;
    private long _viewportRetryAt, _viewportWaitSince, _viewportLastReport;
    private int _viewportReports;
    private bool _linear = true;
    private bool _stopped;
    private bool _surfaceLost;
    // Owner-approved compatibility assumption, not a Vulkan present-completion proof.
    private const int PresentFenceGraceMs = 250; // one quarter of the native 1000 ms detach deadline
    private readonly List<Semaphore> _deferredPresentSemaphores = [];
    private readonly List<Fence> _deferredPresentFences = [];
    private int _idleAssumptionCount, _fenceGraceFallbacks, _revokeImmediateRetirements;
    private int _publishedDeferredSemaphores, _publishedDeferredFences;
    public string RetirementSummary => $"idleRetirements={Volatile.Read(ref _idleAssumptionCount)} " +
        $"fenceGraceFallbacks={Volatile.Read(ref _fenceGraceFallbacks)} revokeImmediateRetirements={Volatile.Read(ref _revokeImmediateRetirements)} deferredSemaphores={Volatile.Read(ref _publishedDeferredSemaphores)} " +
        $"deferredFences={Volatile.Read(ref _publishedDeferredFences)}";
    private bool _graveyardWarning, _retirementSummaryWritten;
    private static bool _s2aFirstPresentLogged;
    private readonly double[] _s2aFrameMs = new double[600];
    private int _s2aFrameCount;
    private long _s2aLastPresentTick;
    public ulong QueuedGamePresents { get; private set; }
    public bool Retired => _stopped && _current == null && _chains.Count == 0 && _host.Lease.HeldGeneration == 0;
    private NativeLease Lease => _host.Lease;
    private RetirementLedger Ledger => Lease.Retirement;

    public AndroidWindow(VulkanRenderer renderer, AndroidVulkanSurface host, PhysicalDevice physical, Device device)
    {
        _renderer = renderer;
        _host = host;
        _physical = physical;
        _device = device;
        _renderer.S2ADeviceCleanup = ReleaseDeferredPresentResources;
        CreateSwapchain();
    }


    // S2A：每 600 帧给一次端到端 Present 间隔（同一 BLAST 层上屏节奏），不依赖 SurfaceFlinger latency。
    private void S2AReportFrameTimes()
    {
        double[] sorted = (double[])_s2aFrameMs.Clone();
        Array.Sort(sorted);
        double Avg() { double s = 0; foreach (double v in sorted) s += v; return s / sorted.Length; }
        double P(double p) => sorted[Math.Min(sorted.Length - 1, (int)(sorted.Length * p))];
        int slow33 = 0, slow100 = 0;
        foreach (double v in sorted) { if (v > 33.3) slow33++; if (v > 100) slow100++; }
        Console.Error.WriteLine($"[s2a] 帧间隔 600 帧：avg {Avg():0.00} ms、p50 {P(0.50):0.00}、p95 {P(0.95):0.00}、" +
            $"p99 {P(0.99):0.00}、max {sorted[^1]:0.00}、>33ms {slow33}、>100ms {slow100}");
    }

    public void Poll()
    {
        Lease.Poll();
        if (Lease.State.Stopping != 0) _stopped = true;
        for (int i = _pending.Count - 1; i >= 0; i--)
        {
            Pending pending = _pending[i];
            if (pending.Submit != null && IsComplete(pending.Submit.GetUnsafe(), out pending.SubmitStatus))
            {
                Ledger.ObserveSubmitCompletion(pending.Record);
                pending.Submit.Put();
                pending.Submit = null;
            }
            if (pending.Present.Handle != 0 && !pending.Record.PresentDone && IsComplete(pending.Present, out pending.PresentStatus))
                Ledger.ObservePresentFence(pending.Record);
            if (pending.Record.Collected)
            {
                if (pending.Present.Handle != 0) _renderer.Api.DestroyFence(_device, pending.Present, null);
                _pending.RemoveAt(i);
            }
        }
        // A revision change (size, system-bar insets) retires this chain. The chain stays alive
        // until real completion or the explicitly named idle compatibility assumption permits
        // retirement. Android may need the old chain destroyed before the replacement.
        if (_current != null && (_current.Record.Retiring || Lease.RetirementRequested ||
            Lease.State.Stamp != _current.Record.Window))
        {
            string why = _current.Record.Retiring ? "present/acquire-retired"
                : Lease.RetirementRequested ? "lease-stop" : "stamp-change";
            if (!_current.Record.Retiring) Ledger.RetireSwapchain(_current.Record);
            LogRetirement(_current, "retire (" + why + ")");
            _current = null;
        }
        for (int i = _chains.Count - 1; i >= 0; i--)
        {
            Chain chain = _chains[i];
            if (!chain.Record.Retiring) continue;
            if (chain.RetiringSince == 0)
            {
                chain.RetiringSince = Environment.TickCount64;
                chain.FenceGrace.Begin(_host.Lifecycle, chain.RetiringSince);
            }
            bool fenceGraceExpired = chain.FenceGrace.Expired(_host.Lifecycle, Environment.TickCount64, PresentFenceGraceMs);
            // Reacquire has no final-frame proof after retirement. Even with maintenance1,
            // Android can return an error without importing the release fd into its fence.
            // Only after all application submissions complete, and after a bounded opportunity
            // for real fences to signal, apply the separately named idle assumption.
            // The 250 ms fence grace and untimed QueueWaitIdle are design choices: only a concurrent
            // surfaceDestroyed revoke starts a native 1000 ms ACK timeout (then process abort), not
            // a timeout on this call; a revision-only retirement has no such deadline.
            // Revoke has a native 1000 ms ACK deadline even if the producer is backgrounded.
            // Waiting for a foreground-only grace here could prevent ACK indefinitely.
            bool revokeSkipsFenceGrace = Lease.RetirementRequested &&
                chain.Record.Mode == RetirementMode.EnabledPresentFence && !fenceGraceExpired;
            if (Ledger.CanAssumeQueueIdle(chain.Record) &&
                (chain.Record.Mode == RetirementMode.Reacquire ||
                 fenceGraceExpired || revokeSkipsFenceGrace) &&
                CollectCompleted(chain))
            {
                Result idle;
                lock (_renderer.QueueLock) idle = _renderer.Api.QueueWaitIdle(_renderer.Queue);
                if (idle != Result.Success)
                {
                    if (idle == Result.ErrorDeviceLost) Ledger.LoseDevice();
                    throw new InvalidOperationException($"Android WSI queue idle retirement failed: {idle}; ownership retained.");
                }
                Ledger.ObserveQueueIdleAssumption(chain.Record);
                Interlocked.Increment(ref _idleAssumptionCount);
                if (chain.Record.Mode == RetirementMode.EnabledPresentFence)
                {
                    if (revokeSkipsFenceGrace) Interlocked.Increment(ref _revokeImmediateRetirements);
                    else Interlocked.Increment(ref _fenceGraceFallbacks);
                }
                WriteDiagnostic($"[WSI] 【黄】 retirement evidence=queue-idle-assumed serial={chain.Record.Serial} " +
                    $"mode={chain.Record.Mode} idleRetirements={_idleAssumptionCount} fenceGraceFallbacks={_fenceGraceFallbacks} revokeImmediateRetirements={_revokeImmediateRetirements}" +
                    $"{(revokeSkipsFenceGrace ? "；撤销请求：跳过 fence 宽限" : "")}; present completion not proven");
                for (int j = _pending.Count - 1; j >= 0; j--)
                {
                    Pending item = _pending[j];
                    if (item.Record.Swapchain != chain.Record || !item.Record.Collected) continue;
                    if (item.Present.Handle != 0)
                    {
                        if (item.Record.PresentAssumedIdle) { _deferredPresentFences.Add(item.Present); WarnDeferredResources(); }
                        else _renderer.Api.DestroyFence(_device, item.Present, null);
                    }
                    _pending.RemoveAt(j);
                }
            }
            if (Ledger.CanDestroySwapchain(chain.Record) && CollectCompleted(chain))
            {
                DestroyChain(chain);
                continue;
            }
            // Never fail the session on an unproven retirement. Retain the objects (and the
            // lease) and report the blockers: a stale window then costs memory, not gameplay.
            if (Environment.TickCount64 - chain.LastReport >= 2000)
            {
                chain.LastReport = Environment.TickCount64;
                ReportRetirement(chain, "pending");
                if (!chain.PendingReported && Environment.TickCount64 - chain.RetiringSince >= 1500)
                {
                    chain.PendingReported = true;
                    ReportPending(chain);
                }
            }
        }
        if (Lease.RetirementRequested) Lease.TryReleaseRetired(_host.DestroySurface);
        if (_surfaceLost && _chains.Count == 0)
        {
            _host.DestroySurface();
            _surfaceLost = false;
        }
        // Android rejects a second swapchain on the same native window while another is
        // alive (VK_ERROR_NATIVE_WINDOW_IN_USE_KHR), so the replacement is created only after
        // the retired chain has been retired. The idle fallback is an owner-approved practice
        // with a known Vulkan proof limitation, not a claim of present completion.
        if (!_stopped && !Lease.RetirementRequested && _current == null && _chains.Count == 0 &&
            Lease.WindowForSurface != 0 && Lease.MayPresent(Lease.State.Stamp))
        {
            if (_host.Surface.Handle == 0) _host.CreateSurface();
            CreateSwapchain();
        }
    }

    private void LogRetirement(Chain chain, string what)
    {
        if (chain.RetireLogged) return;
        chain.RetireLogged = true;
        chain.RetirementReason ??= what;
        ReportRetirement(chain, "begin");
    }

    private bool IsComplete(Fence fence, out Result? observation)
    {
        Result result = _renderer.Api.GetFenceStatus(_device, fence);
        observation = result;
        if (result == Result.Success) return true;
        if (result == Result.NotReady) return false;
        if (result == Result.ErrorDeviceLost) Ledger.LoseDevice();
        result.ThrowOnError();
        return false;
    }

    private static string StateDescription(NativeLeaseState state) =>
        $"{state.Session}/{state.Generation}/{state.Revision}:{state.Width}x{state.Height}:" +
        $"transform={state.Transform}:insets={state.InsetLeft},{state.InsetTop},{state.InsetRight},{state.InsetBottom}:" +
        $"hz={state.RefreshHz}:fg={state.Foreground}:stop={state.Stopping}";

    private void ReportStartup(Chain chain)
    {
        if (chain.StartupReported) return;
        chain.StartupReported = true;
        WriteDiagnostic($"[WSI] startup tick={Environment.TickCount64} serial={chain.Record.Serial} mode={chain.Record.Mode} " +
            $"enabledMaintenance1={_host.HasPresentFences} " +
            $"enabledExtension={_renderer.EnabledDeviceFeatures?.HasExtension("VK_EXT_swapchain_maintenance1")} " +
            $"images={chain.Images.Length} extent={chain.Width}x{chain.Height} state={StateDescription(chain.InitialState)}");
    }

    private void ObserveAcquire(Chain chain, Result result)
    {
        chain.LastAcquire = result;
        if (result != Result.SuboptimalKhr || Environment.TickCount64 - chain.LastAcquireReport < 2000) return;
        chain.LastAcquireReport = Environment.TickCount64;
        WriteDiagnostic($"[wsi] acquire suboptimal on serial={chain.Record.Serial} " +
            $"gen={chain.Record.Window.Generation} rev={chain.Record.Window.Revision}");
    }

    private void ReportRetirement(Chain chain, string phase)
    {
        RetirementBlockers blockers = Ledger.Blockers(chain.Record);
        WriteDiagnostic($"[WSI] retirement phase={phase} tick={Environment.TickCount64} serial={chain.Record.Serial} " +
            $"mode={chain.Record.Mode} reason={chain.RetirementReason ?? "ledger"} " +
            $"ageMs={(chain.RetiringSince == 0 ? 0 : Environment.TickCount64 - chain.RetiringSince)} " +
            $"old={StateDescription(chain.InitialState)} now={StateDescription(Lease.State)} held={Lease.HeldGeneration} " +
            $"leaseRetiring={Lease.RetirementRequested} acquire={chain.LastAcquire?.ToString() ?? "unobserved"} " +
            $"present={chain.LastPresent?.ToString() ?? "unobserved"}/{chain.LastPresentSwapchain?.ToString() ?? "unobserved"} " +
            $"blockers={blockers.Acquires}/{blockers.Submits}/{blockers.Presents}/{blockers.UncertainOperations} " +
            $"lost={blockers.DeviceLost} poolCollected={chain.PoolCollected?.ToString() ?? "not-attempted"} " +
            $"pending={_pending.Count(p => p.Record.Swapchain == chain.Record)} gamePresents={QueuedGamePresents}");
    }

    private void ReportPending(Chain chain)
    {
        const int limit = 8;
        int count = 0;
        foreach (Pending pending in _pending)
        {
            if (pending.Record.Swapchain != chain.Record) continue;
            if (++count > limit) continue;
            WriteDiagnostic($"[WSI] pending serial={chain.Record.Serial} image={pending.Record.ImageIndex} " +
                $"submitDone={pending.Record.SubmitDone} submitStatus={pending.SubmitStatus?.ToString() ?? "unobserved"} " +
                $"presentCalled={pending.Record.PresentCalled} fenceAttached={pending.Record.PresentFenceAttached} " +
                $"presentDone={pending.Record.PresentDone} presentStatus={pending.PresentStatus?.ToString() ?? "unobserved"} " +
                $"uncertain={pending.Record.PresentUncertain} collected={pending.Record.Collected}");
        }
        if (count > limit) WriteDiagnostic($"[WSI] pending serial={chain.Record.Serial} omitted={count - limit}");
    }

    private bool CollectCompleted(Chain chain)
    {
        bool collected = _renderer.CommandBufferPool.CollectCompleted();
        chain.PoolCollected = collected;
        return collected;
    }

    private static void WriteDiagnostic(string message)
    {
        // A failed diagnostic sink must not change resource ownership or completion.
        try { Console.Error.WriteLine(message); }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    private void CreateSwapchain()
    {
        NativeLeaseState state = Lease.State;
        // Lease callbacks and surface capabilities converge independently. Control/stop polls
        // must keep running while geometry is unavailable; do not wait on the GPU owner.
        // A new revision retries immediately. Otherwise limit capability queries, including
        // the case where the driver catches up without another Android callback.
        if (_viewportRetryAt != 0 && state.Stamp == _viewportWaitStamp &&
            Environment.TickCount64 < _viewportRetryAt) return;
        _renderer.SurfaceApi.GetPhysicalDeviceSurfaceSupport(_physical, _renderer.QueueFamilyIndex,
            _host.Surface, out var supported).ThrowOnError();
        if (!supported) throw new NotSupportedException("The renderer's queue cannot present to this Android surface.");
        _renderer.SurfaceApi.GetPhysicalDeviceSurfaceCapabilities(_physical, _host.Surface, out var caps).ThrowOnError();
        const ImageUsageFlags usage = ImageUsageFlags.ColorAttachmentBit;
        if ((caps.SupportedUsageFlags & usage) != usage)
            throw new NotSupportedException("Surface images cannot be color attachments.");
        // Use Android compositor rotation first. Pre-rotation is an optimization and must not
        // rotate the game's projection. Vulkan requires this advertised transform to exist.
        if ((caps.SupportedTransforms & SurfaceTransformFlagsKHR.IdentityBitKhr) == 0)
            throw new NotSupportedException("Android compositor rotation requires identity preTransform support.");
        Extent2D extent = ViewportExtent(state, caps);
        if (!ViewportReady(state, caps, extent)) return;
        int width = checked((int)extent.Width), height = checked((int)extent.Height);
        uint count = 0;
        _renderer.SurfaceApi.GetPhysicalDeviceSurfaceFormats(_physical, _host.Surface, ref count, null).ThrowOnError();
        var formats = new SurfaceFormatKHR[count];
        fixed (SurfaceFormatKHR* pointer = formats)
            _renderer.SurfaceApi.GetPhysicalDeviceSurfaceFormats(_physical, _host.Surface, ref count, pointer).ThrowOnError();
        SurfaceFormatKHR format = formats.FirstOrDefault(x => x.Format == VkFormat.B8G8R8A8Unorm && x.ColorSpace == ColorSpaceKHR.PaceSrgbNonlinearKhr);
        if (format.Format == VkFormat.Undefined)
            format = formats.FirstOrDefault(x => x.Format == VkFormat.R8G8B8A8Unorm && x.ColorSpace == ColorSpaceKHR.PaceSrgbNonlinearKhr);
        if (format.Format == VkFormat.Undefined) throw new NotSupportedException("No supported Android swapchain color format.");
        uint images = caps.MinImageCount + 1;
        if (caps.MaxImageCount != 0) images = Math.Min(images, caps.MaxImageCount);
        CompositeAlphaFlagsKHR alpha = new[] { CompositeAlphaFlagsKHR.OpaqueBitKhr, CompositeAlphaFlagsKHR.PreMultipliedBitKhr,
            CompositeAlphaFlagsKHR.PostMultipliedBitKhr, CompositeAlphaFlagsKHR.InheritBitKhr }.First(x => (caps.SupportedCompositeAlpha & x) != 0);
        SwapchainCreateInfoKHR info = new()
        {
            SType = StructureType.SwapchainCreateInfoKhr, Surface = _host.Surface, MinImageCount = images,
            ImageFormat = format.Format, ImageColorSpace = format.ColorSpace, ImageExtent = extent,
            ImageArrayLayers = 1, ImageUsage = usage, ImageSharingMode = SharingMode.Exclusive,
            PreTransform = SurfaceTransformFlagsKHR.IdentityBitKhr, CompositeAlpha = alpha, PresentMode = PresentModeKHR.FifoKhr, Clipped = true,
        };
        SwapchainKHR swapchain = default;
        _renderer.SwapchainApi.CreateSwapchain(_device, in info, null, out swapchain).ThrowOnError();
        _renderer.SwapchainApi.GetSwapchainImages(_device, swapchain, ref images, null).ThrowOnError();
        var chainImages = new Image[images];
        fixed (Image* pointer = chainImages)
            _renderer.SwapchainApi.GetSwapchainImages(_device, swapchain, ref images, pointer).ThrowOnError();
        Chain chain = new() { Swapchain = swapchain, Images = chainImages, Width = width, Height = height };
        chain.Record = Ledger.RegisterSwapchain(Lease.State.Stamp, (int)images,
            _host.HasPresentFences ? RetirementMode.EnabledPresentFence : RetirementMode.Reacquire);
        chain.InitialState = Lease.State;
        chain.Views = new TextureView[images]; chain.Acquire = new Semaphore[images]; chain.Finished = new Semaphore[images];
        TextureCreateInfo texture = new(width, height, 1, 1, 1, 1, 1, 1, FormatTable.GetFormat(format.Format),
            DepthStencilMode.Depth, Target.Texture2D, SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha);
        for (int i = 0; i < images; i++)
        {
            ImageViewCreateInfo view = new()
            {
                SType = StructureType.ImageViewCreateInfo, Image = chainImages[i], ViewType = ImageViewType.Type2D,
                Format = format.Format, Components = new(ComponentSwizzle.R, ComponentSwizzle.G, ComponentSwizzle.B, ComponentSwizzle.A),
                SubresourceRange = new(ImageAspectFlags.ColorBit, 0, 1, 0, 1),
            };
            _renderer.Api.CreateImageView(_device, in view, null, out ImageView handle).ThrowOnError();
            chain.Views[i] = new TextureView(_renderer, _device, new DisposableImageView(_renderer.Api, _device, handle), texture, format.Format);
            SemaphoreCreateInfo sem = new() { SType = StructureType.SemaphoreCreateInfo };
            _renderer.Api.CreateSemaphore(_device, in sem, null, out chain.Acquire[i]).ThrowOnError();
            _renderer.Api.CreateSemaphore(_device, in sem, null, out chain.Finished[i]).ThrowOnError();
        }
        _current = chain;
        _chains.Add(chain);
        _lastCreate = Environment.TickCount64;
        ReportStartup(chain);
    }

    private static Extent2D ViewportExtent(NativeLeaseState state, SurfaceCapabilitiesKHR caps)
    {
        // Android's currentExtent is the consumer's preferred size, not a required image size.
        // Identity preTransform keeps blit, insets and touch in the published window coordinates;
        // the compositor applies display rotation. Do not reinterpret insets in currentExtent.
        return new Extent2D(Math.Clamp((uint)state.Width, caps.MinImageExtent.Width, caps.MaxImageExtent.Width),
            Math.Clamp((uint)state.Height, caps.MinImageExtent.Height, caps.MaxImageExtent.Height));
    }

    private bool ViewportReady(NativeLeaseState state, SurfaceCapabilitiesKHR caps, Extent2D extent)
    {
        int width = checked((int)extent.Width), height = checked((int)extent.Height);
        if (width == 0 || height == 0) throw new InvalidOperationException("Cannot create a zero-sized game swapchain.");
        // Insets are expressed in the published Android viewport, not in a possibly older
        // driver extent. Reject intrinsically invalid metadata; never repair it by clearing
        // insets or swapping dimensions. Use widened sums so invalid values cannot wrap.
        if (state.Width <= 0 || state.Height <= 0 || state.InsetLeft < 0 || state.InsetTop < 0 ||
            state.InsetRight < 0 || state.InsetBottom < 0 ||
            (long)state.InsetLeft + state.InsetRight >= state.Width ||
            (long)state.InsetTop + state.InsetBottom >= state.Height)
            throw new NotSupportedException("Android lease contains invalid viewport dimensions or insets.");
        // A clamped image would scale both the blit and touch rectangle. Wait for valid bounds.
        // CurrentTransform is Android's buffer transform hint, not Display.getRotation().
        // Identity preTransform delegates composition to Android; these values need not match.
        if (state.Width != width || state.Height != height)
        {
            long now = Environment.TickCount64;
            if (_viewportRetryAt == 0) _viewportWaitSince = now;
            if (_viewportWaitStamp != state.Stamp) _viewportLastReport = 0;
            _viewportWaitStamp = state.Stamp;
            _viewportRetryAt = now + 100;
            ReportViewport(state, caps, extent);
            return false;
        }
        _viewportRetryAt = 0;
        _viewportWaitSince = 0;
        return true;
    }

    private void ReportViewport(NativeLeaseState state, SurfaceCapabilitiesKHR caps, Extent2D extent)
    {
        const int limit = 8;
        long now = Environment.TickCount64;
        if (_viewportReports >= limit || (_viewportLastReport != 0 && now - _viewportLastReport < 2000)) return;
        _viewportLastReport = now;
        _viewportReports++;
        WriteDiagnostic($"[WSI] viewport state=unready reason=extent-outside-bounds tick={now} " +
            $"ageMs={now - _viewportWaitSince} lease={StateDescription(state)} " +
            $"currentExtent={caps.CurrentExtent.Width}x{caps.CurrentExtent.Height} " +
            $"minExtent={caps.MinImageExtent.Width}x{caps.MinImageExtent.Height} " +
            $"maxExtent={caps.MaxImageExtent.Width}x{caps.MaxImageExtent.Height} " +
            $"currentTransform={caps.CurrentTransform} supportedTransforms={caps.SupportedTransforms} " +
            $"selectedExtent={extent.Width}x{extent.Height} preTransform=Identity " +
            $"snapshot={_viewportReports}/{limit} furtherSnapshots={(_viewportReports == limit ? "omitted" : "bounded")}");
    }

    public override void Present(ITexture texture, ImageCrop crop, Action swapBuffersCallback)
    {
        Poll();
        // Single GPU owner: the stamp is taken when this present runs — at the direct GAL call when single-threaded, or on the
        // render thread (at most one frame after the GAL call) when Android wraps the renderer in ThreadedRenderer.
        WindowStamp frame = Lease.State.Stamp;
        Chain chain = _current;
        if (chain == null || chain.Record.Retiring || !Lease.MayPresent(frame)) return;
        if (texture is not TextureView source) throw new ArgumentException("Game present requires a Vulkan texture.");
        Semaphore acquire;
        AcquireRecord record;
        uint image = 0;
        ulong acquireNs = 0;
        Result result;
        // Android may freeze the whole process in background; a wall-clock deadline armed
        // before the freeze would expire on resume even though no thread ran. The budget
        // charges only continuous-foreground milliseconds on the producer lifecycle epoch —
        // the same clock as the startup/GPU-step waits — sampled fresh each iteration, so a
        // background transition or a new window generation restarts the allowance.
        ForegroundBudget acquireBudget = new();
        acquireBudget.Begin(_host.Lifecycle, Environment.TickCount64);
        while (true)
        {
            Poll();
            chain = _current;
            if (chain == null || chain.Record.Retiring || !Lease.MayPresent(frame)) return;
            if (acquireBudget.Expired(_host.Lifecycle, Environment.TickCount64, 1000))
                throw new TimeoutException("Android acquire did not progress within one foreground second.");
            acquire = chain.Acquire.FirstOrDefault(s => !_pending.Any(p => p.Record.AcquireSemaphore == s.Handle && !p.Record.SubmitDone));
            if (acquire.Handle == 0) { Thread.Sleep(1); continue; }
            record = Ledger.BeginAcquire(chain.Record, acquire.Handle);
            long acquireStarted = S2AFrameTrace.Begin();
            try { result = _renderer.SwapchainApi.AcquireNextImage(_device, chain.Swapchain, 1_000_000, acquire, default, ref image); }
            finally { acquireNs += S2AFrameTrace.ElapsedNs(acquireStarted); }
            ObserveAcquire(chain, result);
            if (result is not (Result.Timeout or Result.NotReady)) break;
            Ledger.FinishAcquire(record, result == Result.Timeout ? AcquireOutcome.Timeout : AcquireOutcome.NotReady);
        }
        if (result is not (Result.Success or Result.SuboptimalKhr))
        {
            chain.RetirementReason ??= "acquire-failed";
            Ledger.FinishAcquire(record, AcquireOutcome.FailedWithoutImage);
            if (result == Result.ErrorDeviceLost) Ledger.LoseDevice();
            // OUT_OF_DATE / SURFACE_LOST mean this exact chain is stale on a live device;
            // the no-image record already retired it and the next Poll destroys/recreates it.
            // Surface transitions (background, lock, rotation) hit this path on every release.
            // Any other failure — and every device loss — remains fatal.
            if (result == Result.ErrorSurfaceLostKhr) _surfaceLost = true;
            if (result is Result.ErrorOutOfDateKhr or Result.ErrorSurfaceLostKhr) return;
            result.ThrowOnError();
            return;
        }
        Ledger.FinishAcquire(record, result == Result.SuboptimalKhr ? AcquireOutcome.Suboptimal : AcquireOutcome.Acquired, (int)image);
        // A revoke (screen lock/off, background, resize hand-over) can land between acquire and
        // submit. The acquired image still belongs to this chain until the queue has consumed
        // it, so the frame is recorded normally; the check after recording routes it to the
        // wait-only drain that discharges the acquire semaphore and any previous presentation.
        _renderer.PipelineInternal.AutoFlush.Present();
        _renderer.FlushAllCommands();
        CommandBufferScoped commands = _renderer.CommandBufferPool.Rent();
        Pending pending = new() { Record = record, Submit = commands.GetFence() };
        pending.Submit.Get(); // Keep the exact final-source-use fence alive after pool reuse.
        _pending.Add(pending);
        try
        {
            Transition(commands.CommandBuffer, chain.Images[image], ImageLayout.Undefined, ImageLayout.General,
                0, AccessFlags.ColorAttachmentWriteBit);
            AndroidPresentFit.Rect fit = AndroidPresentFit.Fit(crop, source.Width, source.Height, Lease.State, chain.Width, chain.Height);
            _renderer.HelperShader.BlitColor(_renderer, commands, source, chain.Views[image],
                new Extents2D(fit.SrcX0, fit.SrcY0, fit.SrcX1, fit.SrcY1), new Extents2D(fit.DstX0, fit.DstY1, fit.DstX1, fit.DstY0), _linear, true);
            Transition(commands.CommandBuffer, chain.Images[image], ImageLayout.General, ImageLayout.PresentSrcKhr,
                AccessFlags.ColorAttachmentWriteBit, 0);
            Lease.Poll();
            if (Ledger.DeviceLost)
                throw new InvalidOperationException("Android device lost after acquire; ownership retained.");
            // A revoke observed here still leaves the native window owned by this lease: the
            // shell's surfaceDestroyed waits for the ACK that only follows its presentations.
            // Submitting the already-recorded frame is therefore legal and lets retirement prove
            // completion; dropping it here would strand the acquire without a wait.
            _renderer.FlushAllCommands();
            if (!Lease.MayPresent(frame) || _current != chain)
            {
                // The lease may stop/revoke while this accepted acquire is being recorded.
                // Consume its semaphore and complete the recorded source use on the borrowed
                // queue, but create no new render-finished signal or presentation obligation.
                // Keep the exact submit fence and chain until Poll observes real completion.
                _renderer.CommandBufferPool.Return(commands, [acquire], [PipelineStageFlags.ColorAttachmentOutputBit],
                    ReadOnlySpan<Semaphore>.Empty);
                Ledger.SubmitForRetirement(record);
                chain.RetirementReason ??= "lease-changed-after-acquire";
                return;
            }
            // Publish the exact Switch touch rectangle from the final compositor. Only frames
            // that survive the drain check above are published: a revoked frame still carries
            // the old generation/revision, and republishing it could bump the live revision
            // before the consumer sees the window go away. Wider custom projections need an
            // explicit original 16:9 region before touch can safely be enabled.
            s2a_android_game_touch_viewport(fit.SwitchRegion ? frame.Generation : 0,
                fit.TouchX, fit.TouchY, fit.TouchWidth, fit.TouchHeight, chain.Width, chain.Height);
            _renderer.CommandBufferPool.Return(commands, [acquire], [PipelineStageFlags.ColorAttachmentOutputBit], [chain.Finished[image]]);
            Ledger.SubmitQueued(record);
        }
        catch
        {
            chain.RetirementReason ??= "submit-failed";
            Ledger.SubmitFailed(record);
            throw; // Retain every object; an uncertain submit is never converted to completion.
        }
        Semaphore finished = chain.Finished[image]; SwapchainKHR swapchain = chain.Swapchain;
        Result perSwapchain = Result.ErrorUnknown;
        SwapchainPresentFenceInfoEXT fenceInfo = new() { SType = StructureType.SwapchainPresentFenceInfoExt, SwapchainCount = 1 };
        Fence presentFence = default;
        if (_host.HasPresentFences)
        {
            FenceCreateInfo create = new() { SType = StructureType.FenceCreateInfo };
            _renderer.Api.CreateFence(_device, in create, null, out presentFence).ThrowOnError();
            pending.Present = presentFence; fenceInfo.PFences = &presentFence;
        }
        PresentInfoKHR present = new()
        {
            SType = StructureType.PresentInfoKhr, PNext = _host.HasPresentFences ? &fenceInfo : null,
            WaitSemaphoreCount = 1, PWaitSemaphores = &finished, SwapchainCount = 1,
            PSwapchains = &swapchain, PImageIndices = &image, PResults = &perSwapchain,
        };
        Result outer;
        ulong presentNs;
        lock (_renderer.QueueLock)
        {
            long presentStarted = S2AFrameTrace.Begin();
            try { outer = _renderer.SwapchainApi.QueuePresent(_renderer.Queue, in present); }
            finally { presentNs = S2AFrameTrace.ElapsedNs(presentStarted); }
        }
        chain.LastPresent = outer; chain.LastPresentSwapchain = perSwapchain;
        bool accepted = (outer is Result.Success or Result.SuboptimalKhr) &&
            (perSwapchain is Result.Success or Result.SuboptimalKhr);
        Ledger.PresentReturned(record, accepted ? PresentOutcome.Queued : PresentOutcome.UncertainFailure, _host.HasPresentFences);
        if (!accepted)
        {
            chain.RetirementReason ??= "present-failed";
            if (outer == Result.ErrorDeviceLost || perSwapchain == Result.ErrorDeviceLost) Ledger.LoseDevice();
            // Same contract as acquire: OUT_OF_DATE / SURFACE_LOST are recorded above as an
            // uncertain present and the chain is already retiring; Poll recreates it once the
            // observation resolves (or retains it when no fence can prove completion). A live
            // device's stale-chain rejection never kills the session; device loss and unknown
            // errors still do.
            if (!Ledger.DeviceLost &&
                (outer is Result.Success or Result.SuboptimalKhr or Result.ErrorOutOfDateKhr or Result.ErrorSurfaceLostKhr) &&
                (perSwapchain is Result.Success or Result.SuboptimalKhr or Result.ErrorOutOfDateKhr or Result.ErrorSurfaceLostKhr) &&
                (outer is Result.ErrorOutOfDateKhr or Result.ErrorSurfaceLostKhr ||
                 perSwapchain is Result.ErrorOutOfDateKhr or Result.ErrorSurfaceLostKhr))
            {
                if (outer == Result.ErrorSurfaceLostKhr || perSwapchain == Result.ErrorSurfaceLostKhr) _surfaceLost = true;
                return;
            }
            throw new InvalidOperationException($"Android game QueuePresent failed: {outer}/{perSwapchain}; ownership retained.");
        }
        QueuedGamePresents++;
        // t-direct-frametimes：QueuePresent 被接受即本帧成功上屏——与 direct 的成功 present 点同口径，
        // 记入同一个逐帧环形缓冲（默认关）。
        s2a_frame_log_present_timed(acquireNs, presentNs);
        if (!_s2aFirstPresentLogged)
        {
            _s2aFirstPresentLogged = true;
            Console.Error.WriteLine($"[s2a] 首个游戏 Present：会话创建后 +{Environment.TickCount64 - _host.S2AStartedTick} ms");
        }
        long s2aNow = System.Diagnostics.Stopwatch.GetTimestamp();
        if (_s2aLastPresentTick != 0)
        {
            double ms = (s2aNow - _s2aLastPresentTick) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
            if (ms > 0 && ms < 2000)
            {
                _s2aFrameMs[_s2aFrameCount++] = ms;
                if (_s2aFrameCount == _s2aFrameMs.Length) { S2AReportFrameTimes(); _s2aFrameCount = 0; }
            }
        }
        _s2aLastPresentTick = s2aNow;
        // A Suboptimal present right after a recreate would otherwise churn one swapchain per
        // frame when the platform keeps reporting the old extent. Recreate at most twice a
        // second; the lease's next revision (or the next present) can still retire it.
        if (result == Result.SuboptimalKhr || outer == Result.SuboptimalKhr || perSwapchain == Result.SuboptimalKhr)
        {
            // Use the same Android extent choice as creation. Preferred size and buffer hint
            // differences are legal with identity preTransform and must not churn chains.
            // Actual lease geometry/rotation changes retire by revision in Poll.
            _renderer.SurfaceApi.GetPhysicalDeviceSurfaceCapabilities(_physical, _host.Surface, out var now).ThrowOnError();
            Extent2D nextExtent = ViewportExtent(Lease.State, now);
            bool extentChanged = nextExtent.Width != (uint)chain.Width || nextExtent.Height != (uint)chain.Height;
            if (extentChanged)
            {
                if (Environment.TickCount64 - _lastCreate >= 500)
                {
                    chain.RetirementReason ??= "suboptimal-extent-change";
                    Ledger.RetireSwapchain(record.Swapchain);
                }
            }
            else if (Environment.TickCount64 - _lastSuboptimalLog >= 2000)
            {
                _lastSuboptimalLog = Environment.TickCount64;
                WriteDiagnostic($"[wsi] present suboptimal, surface extent unchanged " +
                    $"({chain.Width}x{chain.Height}); keeping the chain");
            }
        }
    }

    private void Transition(CommandBuffer commands, Image image, ImageLayout from, ImageLayout to, AccessFlags source, AccessFlags target)
    {
        ImageMemoryBarrier barrier = new()
        {
            SType = StructureType.ImageMemoryBarrier, SrcAccessMask = source, DstAccessMask = target,
            OldLayout = from, NewLayout = to, SrcQueueFamilyIndex = Vk.QueueFamilyIgnored, DstQueueFamilyIndex = Vk.QueueFamilyIgnored,
            Image = image, SubresourceRange = new(ImageAspectFlags.ColorBit, 0, 1, 0, 1),
        };
        _renderer.Api.CmdPipelineBarrier(commands, PipelineStageFlags.AllCommandsBit, PipelineStageFlags.AllCommandsBit,
            0, 0, null, 0, null, 1, in barrier);
    }

    private void DestroyChain(Chain chain)
    {
        if (!Ledger.CanDestroySwapchain(chain.Record)) return;
        if (!CollectCompleted(chain)) return;
        if (chain.Record.PresentAssumedIdle && chain.Finished.Length > chain.Images.Length)
            throw new InvalidOperationException("Present semaphore count exceeds swapchain image count.");
        foreach (TextureView view in chain.Views) view.Dispose();
        foreach (Semaphore semaphore in chain.Acquire) _renderer.Api.DestroySemaphore(_device, semaphore, null);
        if (chain.Record.PresentAssumedIdle)
        {
            foreach (Semaphore semaphore in chain.Finished)
                if (semaphore.Handle != 0) _deferredPresentSemaphores.Add(semaphore);
            WarnDeferredResources();
        }
        else foreach (Semaphore semaphore in chain.Finished) _renderer.Api.DestroySemaphore(_device, semaphore, null);
        _renderer.SwapchainApi.DestroySwapchain(_device, chain.Swapchain, null);
        Ledger.ConfirmSwapchainDestroyed(chain.Record);
        _chains.Remove(chain);
        WriteDiagnostic($"[WSI] destroyed serial={chain.Record.Serial} gen={chain.Record.Window.Generation} " +
            $"rev={chain.Record.Window.Revision} mode={chain.Record.Mode} poolCollected={chain.PoolCollected} " +
            $"evidence={(chain.Record.PresentAssumedIdle ? "queue-idle-assumed" : "observed")}");
    }

    private void WarnDeferredResources()
    {
        int semaphores = _deferredPresentSemaphores.Count, fences = _deferredPresentFences.Count;
        Volatile.Write(ref _publishedDeferredSemaphores, semaphores);
        Volatile.Write(ref _publishedDeferredFences, fences);
        if (!_graveyardWarning && semaphores + fences > 64)
        {
            _graveyardWarning = true;
            WriteDiagnostic($"[WSI] 【黄】 deferred present resources deferredSemaphores={semaphores} deferredFences={fences} total={semaphores + fences} exceed 64");
        }
    }

    // Invoked by the owning VulkanRenderer immediately before vkDestroyDevice, not when
    // the window/lease is retired. An idle failure retains both resources and device.
    private void ReleaseDeferredPresentResources()
    {
        if (_deferredPresentSemaphores.Count == 0 && _deferredPresentFences.Count == 0) return;
        if (Ledger.DeviceLost) throw new InvalidOperationException("Android WSI device lost; deferred ownership retained.");
        Result idle;
        lock (_renderer.QueueLock) idle = _renderer.Api.DeviceWaitIdle(_device);
        if (idle != Result.Success)
        {
            if (idle == Result.ErrorDeviceLost) Ledger.LoseDevice();
            throw new InvalidOperationException($"Android WSI device idle cleanup failed: {idle}; ownership retained.");
        }
        foreach (Fence fence in _deferredPresentFences) _renderer.Api.DestroyFence(_device, fence, null);
        foreach (Semaphore semaphore in _deferredPresentSemaphores) _renderer.Api.DestroySemaphore(_device, semaphore, null);
        _deferredPresentFences.Clear();
        _deferredPresentSemaphores.Clear();
        WarnDeferredResources();
    }

    public void Stop() { _stopped = true; Lease.Stop(); }
    public override void Dispose()
    {
        if (!Retired) { Stop(); Poll(); }
        if (!Retired) throw new InvalidOperationException("Cannot dispose Vulkan while its Android lease is live.");
        if (!_retirementSummaryWritten)
        {
            _retirementSummaryWritten = true;
            WriteDiagnostic($"[WSI] retirement summary idleRetirements={_idleAssumptionCount} " +
                $"fenceGraceFallbacks={_fenceGraceFallbacks} revokeImmediateRetirements={_revokeImmediateRetirements} deferredSemaphores={_deferredPresentSemaphores.Count} " +
                $"deferredFences={_deferredPresentFences.Count}");
        }
    }
    public override void SetSize(int width, int height) { /* Extent authority is the leased Android state. */ }
    public override void ChangeVSyncMode(VSyncMode mode) { /* FIFO is the legal baseline for first-game correctness. */ }
    public override void SetAntiAliasing(AntiAliasing effect)
    {
        if (effect != AntiAliasing.None) throw new NotSupportedException("Android runtime does not yet admit postprocess AA.");
    }
    public override void SetScalingFilter(ScalingFilter filter)
    {
        if (filter is not (ScalingFilter.Nearest or ScalingFilter.Bilinear)) throw new NotSupportedException("Unsupported Android scaling filter.");
        _linear = filter == ScalingFilter.Bilinear;
    }
    public override void SetScalingFilterLevel(float scale) { }
    public override void SetColorSpacePassthrough(bool enabled)
    {
        if (enabled) throw new NotSupportedException("Android color-space passthrough is not admitted.");
    }
}

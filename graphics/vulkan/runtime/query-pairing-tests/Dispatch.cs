using Silk.NET.Core.Contexts;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using Buffer = Silk.NET.Vulkan.Buffer;

// CPU-only API boundary recorder for render-pass/query-pool pairing.
// Models the VUID semantics exercised by Vulkan validation layers:
// begin/end must sit on the same side of a render-pass boundary (VUID 07004/07007),
// occlusion queries must live inside an active subpass, and reset/copy commands
// are illegal inside a render pass.
internal unsafe sealed class Dispatch : INativeContext
{
    public static readonly List<object> Events = new();
    public static readonly List<string> Violations = new();
    public static readonly HashSet<ulong> LiveBuffers = new();
    public static readonly Dictionary<ulong, bool> Fences = new();
    public static readonly Dictionary<ulong, nint> FenceCommands = new();
    public static readonly Dictionary<nint, string> CommandStates = new();
    public static readonly HashSet<nint> InRenderPass = new();
    public static readonly Dictionary<ulong, QueryType> PoolTypes = new();
    public static readonly Dictionary<ulong, int> PoolSizes = new();
    // (pool,slot) -> "idle" | "begun-inside" | "begun-outside" | "ended"
    public static readonly Dictionary<(ulong, uint), string> Queries = new();
    public static readonly Dictionary<ulong, nint> Maps = new();
    private static ulong _next = 100;
    private static ulong New() => ++_next;

    public static void Complete(ulong fence)
    {
        Fences[fence] = true;
        if (FenceCommands.TryGetValue(fence, out nint cb)) CommandStates[cb] = "complete";
        Events.Add(new { op = "controlled_fence_complete", fence });
    }
    public static void CompleteAll() { foreach (ulong f in Fences.Keys.ToArray()) Complete(f); }

    private static string Key(ulong pool, uint slot) => $"{pool}:{slot}";
    [UnmanagedCallersOnly] private static void BeginQuery(CommandBuffer cb, QueryPool pool, uint slot, QueryControlFlags flags)
    {
        bool inside = InRenderPass.Contains(cb.Handle);
        Events.Add(new { op = "CmdBeginQuery", cb = (long)cb.Handle, pool = pool.Handle, slot, inside_rp = inside });
        var key = (pool.Handle, slot);
        if (Queries.TryGetValue(key, out var s) && s is "begun-inside" or "begun-outside")
            Violations.Add($"CmdBeginQuery double-begin {Key(pool.Handle, slot)}");
        if (inside)
        {
            Queries[key] = "begun-inside";
            if (!CommandStates.TryGetValue(cb.Handle, out var st) || st != "recording")
                Violations.Add("CmdBeginQuery on non-recording CB");
        }
        else
        {
            Queries[key] = "begun-outside";
            if (PoolTypes.TryGetValue(pool.Handle, out var t) && t == QueryType.Occlusion)
                Violations.Add($"occlusion-begin-outside {Key(pool.Handle, slot)}");
        }
    }
    [UnmanagedCallersOnly] private static void EndQuery(CommandBuffer cb, QueryPool pool, uint slot)
    {
        bool inside = InRenderPass.Contains(cb.Handle);
        Events.Add(new { op = "CmdEndQuery", cb = (long)cb.Handle, pool = pool.Handle, slot, inside_rp = inside });
        var key = (pool.Handle, slot);
        if (!Queries.TryGetValue(key, out var s) || s is not ("begun-inside" or "begun-outside"))
        {
            Violations.Add($"07007 end-without-begin {Key(pool.Handle, slot)}");
            Queries[key] = "ended";
            return;
        }
        if (s == "begun-inside" && !inside) Violations.Add($"07004 end-outside-subpass {Key(pool.Handle, slot)}");
        if (s == "begun-outside" && inside) Violations.Add($"07007 end-inside-mismatch {Key(pool.Handle, slot)}");
        Queries[key] = "ended";
    }
    [UnmanagedCallersOnly] private static void BeginRenderPass(CommandBuffer cb, RenderPassBeginInfo* i, SubpassContents c)
    {
        InRenderPass.Add(cb.Handle);
        Events.Add(new { op = "CmdBeginRenderPass", cb = (long)cb.Handle, render_pass = i->RenderPass.Handle });
    }
    [UnmanagedCallersOnly] private static void EndRenderPass(CommandBuffer cb)
    {
        foreach (var kv in Queries.Where(x => x.Value == "begun-inside").ToArray())
            Violations.Add($"07004 dangling-query-at-rp-end {Key(kv.Key.Item1, kv.Key.Item2)}");
        InRenderPass.Remove(cb.Handle);
        Events.Add(new { op = "CmdEndRenderPass", cb = (long)cb.Handle });
    }
    [UnmanagedCallersOnly] private static void ResetQueryPool(CommandBuffer cb, QueryPool pool, uint first, uint count)
    {
        bool inside = InRenderPass.Contains(cb.Handle);
        Events.Add(new { op = "CmdResetQueryPool", cb = (long)cb.Handle, pool = pool.Handle, first, count, inside_rp = inside });
        if (inside) Violations.Add($"reset-inside-rp {Key(pool.Handle, first)}+{count}");
        for (uint k = 0; k < count; k++) Queries[(pool.Handle, first + k)] = "idle";
    }
    [UnmanagedCallersOnly] private static void CopyResults(CommandBuffer cb, QueryPool pool, uint first, uint count, Buffer dst, ulong dstOffset, ulong stride, QueryResultFlags flags)
    {
        bool inside = InRenderPass.Contains(cb.Handle);
        Events.Add(new { op = "CmdCopyQueryPoolResults", cb = (long)cb.Handle, pool = pool.Handle, first, count, buffer = dst.Handle, offset = dstOffset, stride, inside_rp = inside, flags = (uint)flags });
        if (inside) Violations.Add($"copy-inside-rp {Key(pool.Handle, first)}+{count}");
    }

    [UnmanagedCallersOnly] private static Result CreateBuffer(Device d, BufferCreateInfo* i, AllocationCallbacks* a, Buffer* b)
    { *b = new Buffer(New()); LiveBuffers.Add(b->Handle); Events.Add(new { op = "CreateBuffer", buffer = b->Handle, size = i->Size }); return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyBuffer(Device d, Buffer b, AllocationCallbacks* a)
    { Events.Add(new { op = "DestroyBuffer", buffer = b.Handle }); LiveBuffers.Remove(b.Handle); }
    [UnmanagedCallersOnly] private static Result AllocateMemory(Device d, MemoryAllocateInfo* i, AllocationCallbacks* a, DeviceMemory* m)
    { *m = new DeviceMemory(New()); Events.Add(new { op = "AllocateMemory", memory = m->Handle, size = i->AllocationSize }); return Result.Success; }
    [UnmanagedCallersOnly] private static void FreeMemory(Device d, DeviceMemory m, AllocationCallbacks* a) { Events.Add(new { op = "FreeMemory", memory = m.Handle }); }
    [UnmanagedCallersOnly] private static Result BindBufferMemory(Device d, Buffer b, DeviceMemory m, ulong o) { return Result.Success; }
    [UnmanagedCallersOnly] private static Result MapMemory(Device d, DeviceMemory m, ulong o, ulong s, uint f, void** p)
    { nint h = Marshal.AllocHGlobal((nint)s); Maps[m.Handle] = h; *p = (void*)h; return Result.Success; }
    [UnmanagedCallersOnly] private static void UnmapMemory(Device d, DeviceMemory m) { if (Maps.Remove(m.Handle, out nint h)) Marshal.FreeHGlobal(h); }
    [UnmanagedCallersOnly] private static Result CreatePool(Device d, CommandPoolCreateInfo* i, AllocationCallbacks* a, CommandPool* p) { *p = new CommandPool(New()); return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyPool(Device d, CommandPool p, AllocationCallbacks* a) { }
    [UnmanagedCallersOnly] private static Result AllocateCommands(Device d, CommandBufferAllocateInfo* i, CommandBuffer* b)
    { for (int k = 0; k < i->CommandBufferCount; k++) { b[k] = new CommandBuffer((nint)New()); CommandStates[b[k].Handle] = "initial"; } return Result.Success; }
    [UnmanagedCallersOnly] private static Result Begin(CommandBuffer b, CommandBufferBeginInfo* i)
    { CommandStates[b.Handle] = "recording"; Events.Add(new { op = "BeginCommandBuffer", cb = (long)b.Handle }); return Result.Success; }
    [UnmanagedCallersOnly] private static Result End(CommandBuffer b) { Events.Add(new { op = "EndCommandBuffer", cb = (long)b.Handle }); return Result.Success; }
    [UnmanagedCallersOnly] private static Result Submit(Queue q, uint n, SubmitInfo* s, Fence f)
    { for (int j = 0; j < n; j++) for (int k = 0; k < s[j].CommandBufferCount; k++) { nint cb = s[j].PCommandBuffers[k].Handle; CommandStates[cb] = "pending"; FenceCommands[f.Handle] = cb; Events.Add(new { op = "QueueSubmit", cb = (long)cb, fence = f.Handle }); } return Result.Success; }
    [UnmanagedCallersOnly] private static Result CreateFence(Device d, FenceCreateInfo* i, AllocationCallbacks* a, Fence* f) { *f = new Fence(New()); Fences[f->Handle] = false; return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyFence(Device d, Fence f, AllocationCallbacks* a) { Fences.Remove(f.Handle); FenceCommands.Remove(f.Handle); }
    [UnmanagedCallersOnly] private static Result Wait(Device d, uint n, Fence* fs, uint all, ulong timeout)
    { bool ready = true; for (int i = 0; i < n; i++) ready &= Fences[fs[i].Handle]; Events.Add(new { op = "WaitForFences", fence = n == 1 ? fs[0].Handle : 0, ready, timeout }); return ready ? Result.Success : Result.Timeout; }
    [UnmanagedCallersOnly] private static Result CreateQueryPool(Device d, QueryPoolCreateInfo* i, AllocationCallbacks* a, QueryPool* p)
    { *p = new QueryPool(New()); PoolTypes[p->Handle] = i->QueryType; PoolSizes[p->Handle] = (int)i->QueryCount; for (uint k = 0; k < i->QueryCount; k++) Queries[(p->Handle, k)] = "idle"; Events.Add(new { op = "CreateQueryPool", pool = p->Handle, type = (int)i->QueryType, count = i->QueryCount }); return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyQueryPool(Device d, QueryPool p, AllocationCallbacks* a) { PoolTypes.Remove(p.Handle); PoolSizes.Remove(p.Handle); }
    [UnmanagedCallersOnly] private static Result GetResults(Device d, QueryPool p, uint f, uint c, nuint sz, void* data, ulong stride, QueryResultFlags flags)
    { Events.Add(new { op = "GetQueryPoolResults", pool = p.Handle, first = f, count = c }); return Result.NotReady; }
    [UnmanagedCallersOnly] private static Result CreatePipelineCache(Device d, PipelineCacheCreateInfo* i, AllocationCallbacks* a, PipelineCache* p) { *p = new PipelineCache(New()); return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyPipelineCache(Device d, PipelineCache p, AllocationCallbacks* a) { }

    public nint GetProcAddress(string n, int? slot = null) => n switch
    {
        "vkCmdBeginQuery" => (nint)(delegate* unmanaged<CommandBuffer, QueryPool, uint, QueryControlFlags, void>)&BeginQuery,
        "vkCmdEndQuery" => (nint)(delegate* unmanaged<CommandBuffer, QueryPool, uint, void>)&EndQuery,
        "vkCmdBeginRenderPass" => (nint)(delegate* unmanaged<CommandBuffer, RenderPassBeginInfo*, SubpassContents, void>)&BeginRenderPass,
        "vkCmdEndRenderPass" => (nint)(delegate* unmanaged<CommandBuffer, void>)&EndRenderPass,
        "vkCmdResetQueryPool" => (nint)(delegate* unmanaged<CommandBuffer, QueryPool, uint, uint, void>)&ResetQueryPool,
        "vkCmdCopyQueryPoolResults" => (nint)(delegate* unmanaged<CommandBuffer, QueryPool, uint, uint, Buffer, ulong, ulong, QueryResultFlags, void>)&CopyResults,
        "vkCreateQueryPool" => (nint)(delegate* unmanaged<Device, QueryPoolCreateInfo*, AllocationCallbacks*, QueryPool*, Result>)&CreateQueryPool,
        "vkDestroyQueryPool" => (nint)(delegate* unmanaged<Device, QueryPool, AllocationCallbacks*, void>)&DestroyQueryPool,
        "vkGetQueryPoolResults" => (nint)(delegate* unmanaged<Device, QueryPool, uint, uint, nuint, void*, ulong, QueryResultFlags, Result>)&GetResults,
        "vkCreateBuffer" => (nint)(delegate* unmanaged<Device, BufferCreateInfo*, AllocationCallbacks*, Buffer*, Result>)&CreateBuffer,
        "vkDestroyBuffer" => (nint)(delegate* unmanaged<Device, Buffer, AllocationCallbacks*, void>)&DestroyBuffer,
        "vkAllocateMemory" => (nint)(delegate* unmanaged<Device, MemoryAllocateInfo*, AllocationCallbacks*, DeviceMemory*, Result>)&AllocateMemory,
        "vkFreeMemory" => (nint)(delegate* unmanaged<Device, DeviceMemory, AllocationCallbacks*, void>)&FreeMemory,
        "vkBindBufferMemory" => (nint)(delegate* unmanaged<Device, Buffer, DeviceMemory, ulong, Result>)&BindBufferMemory,
        "vkMapMemory" => (nint)(delegate* unmanaged<Device, DeviceMemory, ulong, ulong, uint, void**, Result>)&MapMemory,
        "vkUnmapMemory" => (nint)(delegate* unmanaged<Device, DeviceMemory, void>)&UnmapMemory,
        "vkCreateCommandPool" => (nint)(delegate* unmanaged<Device, CommandPoolCreateInfo*, AllocationCallbacks*, CommandPool*, Result>)&CreatePool,
        "vkDestroyCommandPool" => (nint)(delegate* unmanaged<Device, CommandPool, AllocationCallbacks*, void>)&DestroyPool,
        "vkAllocateCommandBuffers" => (nint)(delegate* unmanaged<Device, CommandBufferAllocateInfo*, CommandBuffer*, Result>)&AllocateCommands,
        "vkBeginCommandBuffer" => (nint)(delegate* unmanaged<CommandBuffer, CommandBufferBeginInfo*, Result>)&Begin,
        "vkEndCommandBuffer" => (nint)(delegate* unmanaged<CommandBuffer, Result>)&End,
        "vkQueueSubmit" => (nint)(delegate* unmanaged<Queue, uint, SubmitInfo*, Fence, Result>)&Submit,
        "vkCreateFence" => (nint)(delegate* unmanaged<Device, FenceCreateInfo*, AllocationCallbacks*, Fence*, Result>)&CreateFence,
        "vkDestroyFence" => (nint)(delegate* unmanaged<Device, Fence, AllocationCallbacks*, void>)&DestroyFence,
        "vkWaitForFences" => (nint)(delegate* unmanaged<Device, uint, Fence*, uint, ulong, Result>)&Wait,
        "vkCreatePipelineCache" => (nint)(delegate* unmanaged<Device, PipelineCacheCreateInfo*, AllocationCallbacks*, PipelineCache*, Result>)&CreatePipelineCache,
        "vkDestroyPipelineCache" => (nint)(delegate* unmanaged<Device, PipelineCache, AllocationCallbacks*, void>)&DestroyPipelineCache,
        _ => 0,
    };
    public bool TryGetProcAddress(string n, out nint p, int? slot = null) { p = GetProcAddress(n, slot); return p != 0; }
    public void Dispose() { }
}

using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.InteropServices;
using System.Threading;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Engine.Dma;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Texture;
using Ryujinx.Memory.Range;
using Ryujinx.Memory.Tracking;
using S2A.Services;

// 只替代最终 GPU renderer；GuestMemory/PhysicalMemory/Texture/LayoutConverter 均直接运行生产代码。
public class RecordingRenderer : DispatchProxy
{
    public static byte[] Uploaded;
    public static int Uploads;
    public static bool Direct;
    protected override object Invoke(MethodInfo method, object[] args)
    {
        if (method.Name == nameof(ITexture.SetData))
        {
            var data=(MemoryOwner<byte>)args[0]; Uploaded=data.Span.ToArray(); Uploads++; data.Dispose(); return null;
        }
        if (method.Name == nameof(ITexture.S2ASetData))
        {
            var lease=(S2AUploadLease)args[0]; Uploaded=lease.Span.ToArray(); Uploads++;
            unsafe { NativeMemory.Free((void*)lease.Ptr); } return null;
        }
        if (method.Name == nameof(IRenderer.CreateTexture)) return Create<ITexture, RecordingRenderer>();
        if (method.Name == nameof(IRenderer.S2ATryRentUpload))
        {
            if (Direct) { unsafe { args[1]=new S2AUploadLease((nint)NativeMemory.Alloc((nuint)(int)args[0]),(int)args[0],1); } return true; }
            args[1]=default(S2AUploadLease); return false;
        }
        return method.ReturnType.IsValueType && method.ReturnType!=typeof(void) ? Activator.CreateInstance(method.ReturnType) : null;
    }
}
unsafe class Program
{
    const string Library="readonly_fixture";
    [DllImport(Library)] static extern void* fixture_create(int shared);
    [DllImport(Library)] static extern int fixture_none();
    [DllImport(Library)] static extern int fixture_protection(ulong a);
    [DllImport(Library)] static extern int fixture_gpu_modified();
    [DllImport(Library)] static extern void fixture_hole(int on);
    [DllImport(Library)] static extern int fixture_readonly();
    [DllImport(Library)] static extern int s2a_android_copy_guest_readonly(ulong a,void*dst,ulong n);
    [DllImport(Library)] static extern int s2a_track_read_untracked(ulong a,byte*dst,ulong n);
    [DllImport(Library)] static extern int fixture_reprotect(ulong a,ulong n,int perm);
    [DllImport(Library)] static extern int fixture_gpu_mod(ulong a,ulong n);
    [DllImport(Library)] static extern void fixture_write_untracked(ulong a,byte*src,ulong n,int flush);
    [DllImport(Library)] static extern int fixture_arm_tripwire();
    [DllImport(Library)] static extern int fixture_entered();
    static int untrackedCalls;
    static unsafe void UntrackedRead(ulong va,byte* dst,int len) { untrackedCalls++; _ = s2a_track_read_untracked(va,dst,(ulong)len); }
    static int assertions,copies,writes;
    static void Check(bool value,string label) { assertions++;if(!value)throw new Exception(label); }
    static void Copy(ulong a,Memory<byte> target)
    {
        copies++;
        fixed(byte* p=target.Span)
        {
            int e=s2a_android_copy_guest_readonly(a,p,(ulong)target.Length);
            if(e!=0)throw new InvalidOperationException($"readonly copy errno {e}");
        }
    }
    static void Write(ulong a,ReadOnlySpan<byte> data,bool flush) { writes++;throw new Exception("readonly lease wrote back"); }
    static Ryujinx.Graphics.Gpu.Image.Texture MakeTexture(GpuContext context,PhysicalMemory memory,ulong address,int width,int gob)
    {
        var info=new TextureInfo(address,width,width,1,1,1,1,0,false,gob,1,1,Target.Texture2D,FormatInfo.Default);
        var size=SizeCalculator.GetBlockLinearTextureSize(width,width,1,1,1,1,1,4,gob,1,1);
        var texture=new Ryujinx.Graphics.Gpu.Image.Texture(context,memory,info,size,new MultiRange(address,(ulong)size.TotalSize),TextureScaleMode.Blacklisted);
        typeof(Ryujinx.Graphics.Gpu.Image.Texture).GetProperty("HostTexture").SetValue(texture,DispatchProxy.Create<ITexture,RecordingRenderer>());
        return texture;
    }
    static byte[] DmaWritten;
    static ulong DmaWriteAddress;
    static void Partial(Ryujinx.Graphics.Gpu.Image.Texture texture)
    {
        if(texture.Group==null)texture.InitializeGroup(false,true,new List<TextureIncompatibleOverlap>());
        var needed=(bool[])typeof(TextureGroup).GetField("_loadNeeded",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(texture.Group);
        Array.Fill(needed,true);
        typeof(TextureGroup).GetMethod("SynchronizePartial",BindingFlags.Instance|BindingFlags.NonPublic).Invoke(texture.Group,new object[]{0,1});
    }

    // CPU consumer replay: readable steady-state upload, then a protected-page read in
    // background and after resume. No Android Activity, real present or driver is simulated.
    static int Lifecycle(string mode,GpuContext context,PhysicalMemory memory,ulong address,
        Ryujinx.Graphics.Gpu.Image.Texture texture,byte[] expected)
    {
        if(mode!="lifecycle-red")context.S2AReadGuestMemory=Copy;
        int uploads=RecordingRenderer.Uploads;
        for(int cycle=0;cycle<3;cycle++)
        {
            foreach(string phase in new[]{"background","resumed"})
            {
                Check(fixture_none()==0,"lifecycle source protected");
                Check(fixture_gpu_modified()!=0,"lifecycle neighbor dirty");
                Console.WriteLine($"ENTER {phase} cycle={cycle} actual Texture.SynchronizeFull");Console.Out.Flush();
                texture.SynchronizeFull();
                Check(RecordingRenderer.Uploaded.SequenceEqual(expected),"lifecycle full bytes match readable reference");
                Partial(texture);
                Check(RecordingRenderer.Uploaded.SequenceEqual(expected),"lifecycle partial bytes match readable reference");
                Check(fixture_protection(address)==0 && fixture_gpu_modified()!=0,"lifecycle source protection and neighbor dirty retained");
            }
        }
        Check(RecordingRenderer.Uploads==uploads+12 && copies==12,"six phases consume twelve real readonly leases");
        Check(writes==0,"lifecycle no guest writeback");
        Console.WriteLine($"PASS {mode}: {assertions} assertions; copies={copies}; uploads={RecordingRenderer.Uploads}");return 0;
    }
    static void CaptureDmaWrite(ulong a,ReadOnlySpan<byte> data,bool flush) { DmaWriteAddress=a; DmaWritten=data.ToArray(); }
    static int DmaCase(string mode,GpuContext context,GuestMemory guest,PhysicalMemory memory,ulong address)
    {
        var gpu=new Ryujinx.Graphics.Gpu.Memory.MemoryManager(memory,1UL<<32);
        ulong sourceOffset = (ulong)Environment.SystemPageSize;
        gpu.Map(address+sourceOffset,0x1000,0x1000,PteKind.Pitch);
        gpu.Map(address,0x2000,0x1000,PteKind.Pitch);
        byte[] reference=new ReadOnlySpan<byte>((void*)(address+8),20).ToArray();
        for(int y=0;y<2;y++) new ReadOnlySpan<byte>((void*)(address+sourceOffset+0x20+(ulong)(y*16)),4).CopyTo(reference.AsSpan(y*16,4));
        Check(fixture_none()==0,"DMA destination old data protected");
        Check(fixture_gpu_modified()!=0,"DMA destination neighbor dirty");
        MemoryTracking.S2AReadUntracked=null;
        if(mode=="dma-untracked-fallback") { context.S2AReadGuestMemory=null; MemoryTracking.S2AReadUntracked=&UntrackedRead; }
        else if(mode!="dma-missing-provider") context.S2AReadGuestMemory=Copy;
        if(mode=="dma-missing-provider")
        {
            bool rejected=false;try{gpu.S2ACopyUntrackedForDma(0x2008,new byte[20]);}catch(NotSupportedException){rejected=true;}
            Check(rejected && copies==0,"missing provider fails without direct protected fallback");
        }
        else if(mode=="dma-negative")
        {
            bool rejected=false;try{gpu.S2ACopyUntrackedForDma(ulong.MaxValue-4,new byte[20]);}catch(OverflowException){rejected=true;}
            Check(rejected && copies==0,"DMA address overflow rejected");
            rejected=false;try{gpu.S2ACopyUntrackedForDma(0x2ff8,new byte[20]);}catch(InvalidOperationException){rejected=true;}
            Check(rejected && copies==0,"GPU mapping hole rejected before any copy");
            Exception seen=null;var thread=new Thread(()=>{try{gpu.S2ACopyUntrackedForDma(0x2008,new byte[20]);}catch(Exception e){seen=e;}});thread.Start();thread.Join();
            Check(seen is InvalidOperationException && copies==0,"wrong GPU owner rejected before any copy");
            gpu.S2ACopyUntrackedForDma(ulong.MaxValue,Memory<byte>.Empty);
            Check(copies==0,"empty DMA preservation needs no memory access");
            gpu.Map(address+0x2000,0x3000,0x1000,PteKind.Pitch);
            byte[] split=new byte[24];gpu.S2ACopyUntrackedForDma(0x2ff8,split);
            for(int i=0;i<24;i++){ulong offset=i<8?(ulong)(0xff8+i):(ulong)(0x2000+i-8);Check(split[i]==(byte)(offset*37+11),"noncontiguous DMA preservation bytes");}
        }
        else
        {
            GuestMemory.WriteUntrackedHook=&CaptureDmaWrite;
            var channel=context.CreateChannel();channel.BindMemory(gpu);
            var processor=typeof(GpuChannel).GetField("_processor",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(channel);
            var dma=(DmaClass)processor.GetType().GetField("_dmaClass",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(processor);
            void Set(string field,int value)=>dma.Write((int)Marshal.OffsetOf<DmaClassState>(field),value);
            Set(nameof(DmaClassState.OffsetInLower),0x1020);Set(nameof(DmaClassState.OffsetOutLower),0x2008);
            Set(nameof(DmaClassState.PitchIn),16);Set(nameof(DmaClassState.PitchOut),16);
            Set(nameof(DmaClassState.SetSrcWidth),16);Set(nameof(DmaClassState.SetDstWidth),16);
            Set(nameof(DmaClassState.SetSrcHeight),4);Set(nameof(DmaClassState.SetDstHeight),4);
            Set(nameof(DmaClassState.LineLengthIn),4);Set(nameof(DmaClassState.LineCount),2);
            Console.WriteLine("ENTER protected actual DmaClass.LaunchDma destination preservation");Console.Out.Flush();
            Set(nameof(DmaClassState.LaunchDma),0x382);
            Check(DmaWriteAddress==address+8 && DmaWritten.SequenceEqual(reference),"actual DMA copy preserves stride padding and copies requested pixels");
            Check(copies==(mode=="dma-untracked-fallback"?0:1),"actual DMA consumer uses readonly provider once");
            Check(mode!="dma-untracked-fallback"||untrackedCalls>0,"fallback uses tracker untracked read");
        }
        Check(fixture_protection(address)==0,"DMA preservation keeps source protection");
        Check(fixture_gpu_modified()!=0,"DMA preservation keeps neighbor dirty");
        Console.WriteLine($"PASS {mode}: {assertions} assertions; copies={copies}");return 0;
    }
    static readonly List<(ulong Address, byte[] Bytes, bool Flush)> RegionWrites = new();
    static void CaptureRegionWrite(ulong a, ReadOnlySpan<byte> data, bool flush) => RegionWrites.Add((a, data.ToArray(), flush));
    // 真实 PROT_NONE 页上的回写旧字节拷贝：单段 / 多段各三种提供者组合，另加旧路径负控。
    // 目标是生产 PhysicalMemory.GetWritableRegion；写回经 GuestMemory.WriteUntrackedHook 只记录内容。
    static int WritebackCase(string mode, GpuContext context, PhysicalMemory memory, ulong address)
    {
        bool single = mode.StartsWith("writable-single");
        bool red = mode.EndsWith("-red");
        bool missing = mode.EndsWith("-missing");
        bool fallback = mode.EndsWith("-fallback");
        bool copyMode = mode.EndsWith("-copy");
        bool alias = mode.EndsWith("-alias");
        // missing 模式模拟安卓：没有提供者时明确失败；fallback 模拟其余平台：保留借页直读。
        if (!fallback) S2AGpuCaps.WritebackRequireProvider = true;
        else Check(!S2AGpuCaps.WritebackRequireProvider, "default keeps upstream fallback");
        if (!fallback) Check(fixture_none() == 0 && fixture_gpu_modified() != 0, "writeback target page protected with GPU data");
        MemoryTracking.S2AReadUntracked = null;
        context.S2AReadGuestMemory = null;
        if (alias) MemoryTracking.S2AReadUntracked = &UntrackedRead;
        if (copyMode) context.S2AReadGuestMemory = Copy;
        GuestMemory.WriteUntrackedHook = &CaptureRegionWrite;
        ulong second = address + (ulong)Environment.SystemPageSize + 0x80;
        var ranges = single
            ? new MultiRange(address + 0x100, 32)
            : new MultiRange(new MemoryRange[] {
                new(address + 0x100, 32), new(MemoryManager.PteUnmapped, 16), new(second, 32) });
        int total = single ? 32 : 80;
        Console.WriteLine($"ENTER protected actual PhysicalMemory.GetWritableRegion {(single ? "single" : "multi")} {mode}");
        Console.Out.Flush();
        if (red)
        {
            using var region = memory.GetWritableRegion(ranges);
            Check(region.Memory.Span[0] == unchecked((byte)(0x100 * 37 + 11)), "unreachable: old borrowed read did not fault");
            throw new Exception("old borrowed read completed on a protected page");
        }
        if (missing)
        {
            bool rejected = false;
            try { memory.GetWritableRegion(ranges); } catch (NotSupportedException) { rejected = true; }
            Check(rejected && copies == 0 && untrackedCalls == 0 && RegionWrites.Count == 0,
                "missing safe provider fails without read or writeback");
        }
        else
        {
            using (var region = memory.GetWritableRegion(ranges))
            {
                var data = region.Memory.Span;
                Check(data.Length == total, "writeback copy length");
                for (int i = 0; i < 32; i++)
                {
                    Check(data[i] == (byte)((0x100 + i) * 37 + 11), "protected segment preserved");
                    if (!single)
                        Check(data[48 + i] == (byte)(((ulong)Environment.SystemPageSize + 0x80 + (ulong)i) * 37 + 11), "second segment preserved");
                }
                if (!single) Check(data.Slice(32, 16).ToArray().All(b => b == 0), "unmapped segment zeroed");
                data[3] = 0xa5;
                if (!single) data[49] = 0x5a;
            }
            int expectedWrites = single ? 1 : 2;
            Check(RegionWrites.Count == expectedWrites, "writeback writes mapped segments only");
            Check(RegionWrites[0].Address == address + 0x100 && RegionWrites[0].Bytes[3] == 0xa5 && RegionWrites.All(w => w.Flush),
                "writeback preserves edits and flush semantics");
            if (!single) Check(RegionWrites[1].Address == second && RegionWrites[1].Bytes[1] == 0x5a, "second segment writeback address and edit");
            Check(mode != "writable-alias" && mode != "writable-single-alias" || untrackedCalls == expectedWrites,
                "tracker untracked read used per mapped segment");
            Check(!copyMode || copies == expectedWrites, "platform readonly provider used per mapped segment");
            Check(!fallback || (copies == 0 && untrackedCalls == 0), "non-Android fallback uses borrowed read");
        }
        if (!fallback) Check(fixture_protection(address) == 0 && fixture_gpu_modified() != 0, "source remains protected and neighbor GPU dirty");
        Console.WriteLine($"PASS {mode}: {assertions} assertions; copies={copies} aliases={untrackedCalls}"); return 0;
    }
    // ---- readflush（#199 收口回写）：真 PROT_NONE + GPU 改过子页上的托管不跟踪读。
    //   缺页侧不接管：GuestMemory 在读入口显式发与客机缺页同一个读事件，句柄动作把 GPU 数据经
    //   s2a_track_write_untracked 写回并恢复可读后再取数。探针数「托管读进没进 SIGSEGV」；
    //   readflush-bypass 是红对照：绕过收口直接读 NONE 页，照旧进信号、链回 dotnet 报 AV ----
    static int flushEvents;
    static bool FixtureGpuMod(ulong a, ulong n) => fixture_gpu_mod(a, n) != 0;
    static void FixtureReprotect(ulong a, ulong n, Ryujinx.Memory.MemoryPermission p, bool guest)
        => fixture_reprotect(a, n, p == Ryujinx.Memory.MemoryPermission.ReadAndWrite ? 3 : p == Ryujinx.Memory.MemoryPermission.Read ? 1 : 0);
    static int ReadFlushCase(string mode, GuestMemory guest, ulong address)
    {
        bool red = mode == "readflush-bypass";
        GuestMemory.ReprotectHook = &FixtureReprotect;
        GuestMemory.GpuModifiedHook = &FixtureGpuMod;
        Check(fixture_arm_tripwire() == 0, "sigsegv tripwire armed");
        var hd = guest.BeginTracking(address, 0x1000, 0);
        byte[] wb = { 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x61 };
        void Arm() => hd.RegisterAction((a, n) =>
        {
            flushEvents++;
            fixed (byte* s = wb) fixture_write_untracked(a, s, (ulong)Math.Min(n, (ulong)wb.Length), 1);
        });
        Arm();
        Check(fixture_none() == 0, "readflush source protected");
        Check(fixture_gpu_mod(address, 0x20) != 0, "GPU-modified mark armed");
        Console.WriteLine($"ENTER readflush {(red ? "bypass raw deref" : "managed GetSpan(tracked:false)")} on protected GPU-modified page");
        Console.Out.Flush();
        if (red)
        {
            ulong v = *(ulong*)address;
            throw new Exception($"unreachable: protected read returned {v:X}");
        }
        var span = guest.GetSpan(address, 0x20);
        Check(span[0] == 0x5A && span[7] == 0x61, "read returns writeback bytes");
        Check(flushEvents == 1, "exactly one readflush event");
        Check(fixture_entered() == 0, "managed read did not enter signal handler");
        Check(fixture_gpu_mod(address, 0x20) == 0, "modified mark cleared by flush");
        // 死锁负控：回写在另一线程执行（双线程渲染的回写在渲染线程上跑）并回进跟踪层取 TrackingLock——
        //   事件跑动作时已放出 TrackingLock，读线程等回写、回写拿锁互不等待；循环 1000 次带超时
        var wrReady = new ManualResetEventSlim(); var wrDone = new ManualResetEventSlim();
        Exception werr = null;
        var writer = new Thread(() =>
        {
            try
            {
                while (wrReady.Wait(TimeSpan.FromSeconds(30)))
                {
                    wrReady.Reset();
                    guest.Tracking.VirtualMemoryEvent(address + 0x1000, 8, false, precise: false, exemptId: null, guest: true);
                    fixed (byte* s = wb) fixture_write_untracked(address, s, (ulong)wb.Length, 1);
                    wrDone.Set();
                }
            }
            catch (Exception e) { werr = e; }
        }) { IsBackground = true };
        writer.Start();
        int loops = 0; Exception rerr = null;
        for (int i = 0; i < 1000; i++)
        {
            try
            {
                hd.RegisterAction((a, n) =>
                {
                    wrReady.Set();
                    if (!wrDone.Wait(TimeSpan.FromSeconds(30))) throw new TimeoutException("writeback wait");
                    wrDone.Reset();
                });
                fixture_none();
                if (guest.GetSpan(address, 8)[0] != 0x5A) throw new Exception("stale read");
                loops++;
            }
            catch (Exception e) { rerr = e; break; }
        }
        Check(loops == 1000 && rerr == null && werr == null, $"1000 cross-thread readflush no deadlock ({loops}, {rerr?.Message ?? werr?.Message ?? "ok"})");
        hd.Dispose();
        GuestMemory.ReprotectHook = null;
        GuestMemory.GpuModifiedHook = null;
        Console.WriteLine($"PASS {mode}: {assertions} assertions; events={flushEvents} loops={loops} entered={fixture_entered()}");
        return 0;
    }

    // Decode the renderer method's IL, so removing its call to the capability
    // check cannot leave the independent policy-only test passing.
    static bool Calls(MethodInfo caller, MethodInfo target)
    {
        var opcodes = typeof(OpCodes).GetFields(BindingFlags.Public | BindingFlags.Static)
            .Where(f => f.FieldType == typeof(OpCode))
            .Select(f => (OpCode)f.GetValue(null)).GroupBy(op => unchecked((ushort)op.Value))
            .ToDictionary(group => group.Key, group => group.First());
        byte[] il = caller.GetMethodBody().GetILAsByteArray();
        for (int i = 0; i < il.Length;)
        {
            ushort key = il[i++];
            if (key == 0xfe) key = (ushort)(0xfe00 | il[i++]);
            OpCode op = opcodes[key];
            if (op == OpCodes.Call && caller.Module.ResolveMethod(BitConverter.ToInt32(il, i)) == target) return true;
            i += op.OperandType switch
            {
                OperandType.InlineNone => 0,
                OperandType.ShortInlineBrTarget or OperandType.ShortInlineI or OperandType.ShortInlineVar => 1,
                OperandType.InlineVar => 2,
                OperandType.InlineI8 or OperandType.InlineR => 8,
                OperandType.InlineSwitch => 4 + 4 * BitConverter.ToInt32(il, i),
                _ => 4,
            };
        }
        return false;
    }

    static int CapsCase()
    {
        var caps = typeof(Ryujinx.Graphics.Vulkan.S2AVulkanCaps);
        var check = caps.GetMethod("CheckApiVersion", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
        var setup = typeof(Ryujinx.Graphics.Vulkan.VulkanRenderer).GetMethod("SetupContext", BindingFlags.Instance | BindingFlags.NonPublic);
        Check(check != null && setup != null && Calls(setup, check), "renderer invokes the capability version check");
        void Accept(uint version) => check.Invoke(null, new object[] { version });
        void Reject(uint version, string expected)
        {
            try { Accept(version); throw new Exception("version unexpectedly accepted"); }
            catch (System.Reflection.TargetInvocationException e) when (e.InnerException is NotSupportedException n && n.Message == expected) { }
        }
        const uint v10 = 1u << 22;
        const uint v11 = (1u << 22) | (1u << 12);
        Check(!S2AGpuCaps.WritebackRequireProvider, "provider defaults false");
        Check(Ryujinx.Graphics.Vulkan.S2AVulkanCaps.MinimumApiVersion == 0 && Ryujinx.Graphics.Vulkan.S2AVulkanCaps.UnsupportedMessage == null, "Vulkan defaults");
        // Negative control for the removed 0305/0306 check: an API 1.0
        // device passes this *extra* gate when no platform sets the capability.
        // VulkanInitialization still applies its own upstream selection.
        Accept(v10);
        Ryujinx.Graphics.Vulkan.S2AVulkanCaps.MinimumApiVersion = v11;
        Reject(v10, "Initialization failed, none of the available GPUs meets the minimum requirements.");
        Ryujinx.Graphics.Vulkan.S2AVulkanCaps.UnsupportedMessage = "此设备的 Vulkan 版本过低，需要 Vulkan 1.1 或更高版本。";
        Reject(v10, Ryujinx.Graphics.Vulkan.S2AVulkanCaps.UnsupportedMessage);
        Accept(v11);
        Console.WriteLine("PASS caps: default and explicit Vulkan policies");
        return 0;
    }
    static int Main(string[] args)
    {
        string mode=args[0]; if (mode == "caps") return CapsCase(); byte* p=(byte*)fixture_create(mode=="private"?0:1);Check(p!=null,"mapping");
        ulong address=(ulong)p;
        var context=new GpuContext(DispatchProxy.Create<IRenderer,RecordingRenderer>(),new DirtyHacks(Array.Empty<ulong>()));
        context.SetGpuThread();
        var guest=new GuestMemory();GuestMemory.WriteUntrackedHook=&Write;
        var memory=new PhysicalMemory(context,guest);
        if(mode.StartsWith("dma-")) return DmaCase(mode,context,guest,memory,address);
        if(mode.StartsWith("writable-")) return WritebackCase(mode,context,memory,address);
        if(mode.StartsWith("readflush")) return ReadFlushCase(mode,guest,address);
        var small=MakeTexture(context,memory,address+0x400,8,1);
        var large=MakeTexture(context,memory,address,16,2);
        large.SynchronizeFull();Check(RecordingRenderer.Uploaded.Length==0x400,"large production upload");
        small.SynchronizeFull();byte[] expected=RecordingRenderer.Uploaded;
        Check(expected.Length==0x100,"small actual output size");
        Check(memory.BufferCache.S2AHasGpuModified(address+0x400,0x200)==false,"no overlapping buffer");
        if(mode.StartsWith("lifecycle"))return Lifecycle(mode,context,memory,address,small,expected);
        if(mode=="borrowed-multi")
        {
            var ranges=new MultiRange(new MemoryRange[]{new(address+0x400,16),new(Ryujinx.Graphics.Gpu.Memory.MemoryManager.PteUnmapped,16),new(address+0x800,16)});
            var data=memory.S2AGetTextureReadSpan(ranges,out var owner);
            Check(owner!=null && data.Length==48,"unconfigured platform retains rented multi-range scratch");
            using(owner)
            {
                for(int i=0;i<16;i++)Check(data[i]==(byte)((0x400+i)*37+11) && data[32+i]==(byte)((0x800+i)*37+11),"borrowed multi bytes");
                Check(data.Slice(16,16).ToArray().All(b=>b==0),"borrowed multi PTE hole zeroed");
            }
            bool disposed=false;try{_ = owner.Span;}catch(ObjectDisposedException){disposed=true;}
            Check(disposed && copies==0 && writes==0,"borrowed scratch returned without provider or writeback");
            Console.WriteLine($"PASS {mode}: {assertions} assertions; copies={copies}");return 0;
        }
        if(mode=="borrowed")
        {
            var data=memory.S2AGetTextureReadSpan(new MultiRange(address+0x400,0x200),out var noOwner);
            Check(noOwner==null && data.Length==0x200,"unconfigured platform keeps borrowed path");
        }
        else
        {
            Check(fixture_none()==0,"source None");
            Check(fixture_gpu_modified()!=0,"neighbor remains GPU modified");
            if(mode!="red")context.S2AReadGuestMemory=Copy;
            if(mode=="private")
            {
                bool rejected=false;try{small.SynchronizeFull();}catch(InvalidOperationException){rejected=true;}
                Check(rejected,"private alias rejected without direct fallback");
            }
            else if(mode=="hole")
            {
                fixture_hole(1);bool rejected=false;try{small.SynchronizeFull();}catch(InvalidOperationException){rejected=true;}
                Check(rejected,"unmapped logical range rejected");
            }
            else if(mode=="wrong-thread")
            {
                Exception seen=null;var thread=new Thread(()=>{try{small.SynchronizeFull();}catch(Exception e){seen=e;}});thread.Start();thread.Join();
                Check(seen is InvalidOperationException && copies==0,"wrong owner rejected before copying");
            }
            else if(mode=="partial")
            {
                Partial(small);
                Check(RecordingRenderer.Uploaded.SequenceEqual(expected) && copies==1,"actual partial-sync consumes readonly lease");
            }
            else if(mode=="multi")
            {
                var ranges=new MultiRange(new MemoryRange[]{new(address+0xff0,0x30),new(Ryujinx.Graphics.Gpu.Memory.MemoryManager.PteUnmapped,0x10),new(address+0x400,0x20)});
                var data=memory.S2AGetTextureReadSpan(ranges,out var owner);using(owner)
                {
                    Check(data.Length==0x60,"multi range length");
                    for(int i=0;i<0x30;i++)Check(data[i]==(byte)((0xff0+i)*37+11),"cross-page data");
                    Check(data.Slice(0x30,0x10).ToArray().All(b=>b==0),"explicit PTE hole zeroed");
                    for(int i=0;i<0x20;i++)Check(data[0x40+i]==(byte)((0x400+i)*37+11),"second range");
                }
                bool disposed=false;try{_ = owner.Span;}catch(ObjectDisposedException){disposed=true;}Check(disposed,"lease returned");
            }
            else if(mode=="overflow")
            {
                bool rejected=false;try{memory.S2AGetTextureReadSpan(new MultiRange(ulong.MaxValue-4,16),out _);}catch(OverflowException){rejected=true;}
                Check(rejected && copies==0,"range overflow rejected");
            }
            else
            {
                RecordingRenderer.Direct=mode=="direct";
                Console.WriteLine("ENTER protected actual Texture.SynchronizeFull");Console.Out.Flush();
                small.SynchronizeFull(); // red 在原生产转换的实际源读失败；green 使用同一路径。
                Check(RecordingRenderer.Uploaded.SequenceEqual(expected),"same page neighbor bytes match readable production reference");
                if(mode!="red")Check(copies==1,"real copy consumed once");
            }
            Check(fixture_protection(address)==0,"original source protection unchanged");
            Check(fixture_gpu_modified()!=0,"neighbor tracking unchanged");
        }
        Check(writes==0,"no guest writeback");
        Console.WriteLine($"PASS {mode}: {assertions} assertions; copies={copies}; uploads={RecordingRenderer.Uploads}");return 0;
    }
}

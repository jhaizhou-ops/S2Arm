using Ryujinx.Graphics.Device;
using Ryujinx.Graphics.Nvdec;
using Ryujinx.Graphics.Nvdec.Image;
using Ryujinx.Graphics.Nvdec.Types.H264;
using Ryujinx.Graphics.Texture;
using Ryujinx.Graphics.Video;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;

// Test boundary only: a bounded CPU-backed guest address space. The production
// DeviceMemoryManager, H264Decoder, SurfaceCache and SurfaceWriter run unchanged.
sealed class FixtureMemory : IVirtualMemoryManager
{
    public readonly byte[] Bytes;
    public int Writes;
    public bool ThrowOnWrite;
    public FixtureMemory(int size) { Bytes=new byte[size]; }
    public bool UsesPrivateAllocations=>false;
    public void Map(ulong va,ulong pa,ulong size,MemoryMapFlags flags)=>throw new NotSupportedException();
    public void MapForeign(ulong va,nuint ptr,ulong size)=>throw new NotSupportedException();
    public void Unmap(ulong va,ulong size)=>throw new NotSupportedException();
    public T Read<T>(ulong va) where T:unmanaged=>MemoryMarshal.Read<T>(GetSpan(va,Marshal.SizeOf<T>()));
    public void Read(ulong va,Span<byte> data)=>GetSpan(va,data.Length).CopyTo(data);
    public bool TryReadUnsafe(ulong va,int length,out Span<byte> data) { data=Bytes.AsSpan(checked((int)va),length);return true; }
    public void Write<T>(ulong va,T value) where T:unmanaged=>MemoryMarshal.Write(Bytes.AsSpan(checked((int)va)),in value);
    public void Write(ulong va,ReadOnlySpan<byte> data) { Writes++;data.CopyTo(Bytes.AsSpan(checked((int)va))); }
    public bool WriteWithRedundancyCheck(ulong va,ReadOnlySpan<byte> data) { Write(va,data);return true; }
    public ReadOnlySequence<byte> GetReadOnlySequence(ulong va,int size,bool tracked=false)=>new(Bytes.AsMemory(checked((int)va),size));
    public ReadOnlySpan<byte> GetSpan(ulong va,int size,bool tracked=false)=>Bytes.AsSpan(checked((int)va),size);
    public WritableRegion GetWritableRegion(ulong va,int size,bool tracked=false)
    {
        Writes++;
        if(ThrowOnWrite) throw new InvalidOperationException("fixture writable-region failure");
        return new WritableRegion(null,va,Bytes.AsMemory(checked((int)va),size));
    }
    public ref T GetRef<T>(ulong va) where T:unmanaged=>ref MemoryMarshal.AsRef<T>(Bytes.AsSpan(checked((int)va)));
    public IEnumerable<HostMemoryRange> GetHostRegions(ulong va,ulong size)=>throw new NotSupportedException();
    public IEnumerable<MemoryRange> GetPhysicalRegions(ulong va,ulong size)=>new[]{new MemoryRange(va,size)};
    public bool IsMapped(ulong va)=>va<(ulong)Bytes.Length;
    public bool IsRangeMapped(ulong va,ulong size)=>va<=(ulong)Bytes.Length && size<=(ulong)Bytes.Length-va;
    public void SignalMemoryTracking(ulong va,ulong size,bool write,bool precise=false,int? exemptId=null) { }
    public void Reprotect(ulong va,ulong size,MemoryPermission protection)=>throw new NotSupportedException();
    public void TrackingReprotect(ulong va,ulong size,MemoryPermission protection,bool guest)=>throw new NotSupportedException();
}
static class CallPath
{
    public static PictureInfo Metadata(H264PictureInfo info)
    {
        ulong flags = (info.Direct8x8InferenceFlag?2ul:0) | (info.WeightedPredFlag?4ul:0) | (info.ConstrainedIntraPredFlag?8ul:0) |
            ((ulong)info.Log2MaxFrameNumMinus4<<8) | ((ulong)info.ChromaFormatIdc<<12) | ((ulong)info.PicOrderCntType<<14) |
            (((ulong)info.PicInitQpMinus26&63)<<16) | (((ulong)info.ChromaQpIndexOffset&31)<<22) |
            (((ulong)info.SecondChromaQpIndexOffset&31)<<27) | ((ulong)info.WeightedBipredIdc<<32);
        var p=new PictureInfo { Flags=flags, PicWidthInMbs=info.PicWidthInMbsMinus1+1,PicHeightInMbs=info.PicHeightInMapUnitsMinus1+1,
            FrameMbsOnlyFlag=1,Log2MaxPicOrderCntLsbMinus4=info.Log2MaxPicOrderCntLsbMinus4,
            EntropyCodingModeFlag=info.EntropyCodingModeFlag?1u:0,PicOrderPresentFlag=info.PicOrderPresentFlag?1u:0,
            NumRefIdxL0ActiveMinus1=info.NumRefIdxL0ActiveMinus1,NumRefIdxL1ActiveMinus1=info.NumRefIdxL1ActiveMinus1,
            DeblockingFilterControlPresentFlag=info.DeblockingFilterControlPresentFlag?1u:0,
            RedundantPicCntPresentFlag=info.RedundantPicCntPresentFlag?1u:0,Transform8x8ModeFlag=info.Transform8x8ModeFlag?1u:0 };
        for(int i=0;i<6;i++) p.ScalingLists4x4.AsSpan()[i].AsSpan().Fill(16);
        for(int i=0;i<2;i++) p.ScalingLists8x8.AsSpan()[i].AsSpan().Fill(16);
        return p;
    }
    public static void Run(IH264Decoder decoder,H264PictureInfo info,byte[] au,bool success)
    {
        var physical=new FixtureMemory(32*1024*1024); var mm=new DeviceMemoryManager(physical);mm.Map(0,0,(ulong)physical.Bytes.Length);
        var metadata=Metadata(info);metadata.BitstreamSize=(uint)au.Length;
        physical.Write(0x1000,metadata);au.CopyTo(physical.Bytes,0x2000);
        physical.Bytes.AsSpan(0x100000).Fill(0xa5);
        var cache=new SurfaceCache(mm); var rm=new ResourceManager(mm,cache); using var context=new NvdecDecoderContext();
        typeof(NvdecDecoderContext).GetField("_h264Decoder",BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(context,decoder);
        var state=new NvdecRegisters {SetDrvPicSetupOffset=0x10,SetInBufBaseOffset=0x20};
        state.SetPictureLumaOffset.AsSpan()[0]=0x1000;state.SetPictureChromaOffset.AsSpan()[0]=0x12000;
        H264Decoder.Decode(context,rm,ref state);
        if(!success)
        {
            if(physical.Writes!=0 || !physical.Bytes.AsSpan(0x100000).ToArray().All(x=>x==0xa5)) throw new Exception("failed Decode modified guest through production SurfaceWriter");
        }
        else
        {
            if(physical.Writes!=2) throw new Exception("expected luma and chroma writes");
            physical.ThrowOnWrite=true;
            // A fresh IDR reuses the live context. SurfaceWriter must unwind the
            // cache reference even when the memory boundary throws.
            try { H264Decoder.Decode(context,rm,ref state); throw new Exception("writer fault was not exercised"); }
            catch(InvalidOperationException error) when(error.Message.Contains("fixture")) { }
        }
        var pool=(Array)typeof(SurfaceCache).GetField("_pool",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(cache)!;
        foreach(var item in pool) if((int)item!.GetType().GetField("ReferenceCount")!.GetValue(item)!=0) throw new Exception("cache reference leaked");
        cache.Trim();
    }
}

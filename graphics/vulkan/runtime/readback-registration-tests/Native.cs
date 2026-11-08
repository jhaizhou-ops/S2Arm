using System;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using Ryujinx.Memory;
using Ryujinx.Memory.Tracking;
using Ryujinx.Tests.Memory;

static unsafe class Native
{
    const string L="epoch_native";
    [DllImport(L)] public static extern ulong ep_alloc();
    [DllImport(L)] public static extern void ep_prepare();
    [DllImport(L)] public static extern void ep_callback(delegate* unmanaged<ulong,ulong,int,void> fn);
    [DllImport(L)] public static extern void ep_reprotect(ulong a,ulong n,int p);
    [DllImport(L)] public static extern void ep_touch(ulong a);
    [DllImport(L)] public static extern void ep_write(ulong a,byte* p,ulong n);
    [DllImport(L)] public static extern int ep_perm(ulong a);
    [DllImport(L)] public static extern int ep_dirty(ulong a,ulong n);
    [DllImport(L)] public static extern int ep_byte(ulong a);
    [DllImport(L)] public static extern void ep_free(ulong a);
}
sealed class Manager : MockVirtualMemoryManager, IVirtualMemoryManager
{
    public int NoneNotifications;
    public Manager() : base(8192,4096) { }
    public new void TrackingReprotect(ulong va,ulong size,MemoryPermission protection,bool guest)
    {
        if(!guest)return;
        Native.ep_reprotect(va,size,(int)protection);
        if(protection==MemoryPermission.None)Interlocked.Increment(ref NoneNotifications);
    }
}
static unsafe class Joint
{
    static MemoryTracking tracking;
    static int checks;
    static void Check(bool v,string s){checks++;if(!v)throw new Exception(s);}
    [UnmanagedCallersOnly] static void Touch(ulong a,ulong n,int write)
    {
        try{tracking.VirtualMemoryEvent(a,n,write!=0,false,null,true);}
        catch(Exception e){Environment.FailFast("managed readback callback failed",e);}
    }
    static void Write(ulong a,ulong n,byte value)
    {
        Span<byte> bytes=stackalloc byte[4096];bytes.Fill(value);
        fixed(byte*p=bytes)Native.ep_write(a,p,n);
    }
    [DynamicDependency(DynamicallyAccessedMemberTypes.NonPublicFields,typeof(MemoryTracking))]
    [UnmanagedCallersOnly(EntryPoint="epoch_test")]
    public static int Run(int mode)
    {
        try
        {
            ulong address=Native.ep_alloc();Native.ep_prepare();
            var manager=new Manager();tracking=new MemoryTracking(manager,4096){ReprotectOnActionRegistration=mode!=0};
            Native.ep_callback(&Touch);
            var handle=tracking.BeginTracking(address,mode==4?8192UL:4096UL,0);
            handle.Reprotect();
            object gate=typeof(MemoryTracking).GetField("TrackingLock",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(tracking)!;
            int first=0,second=0;
            if(mode==2)
            {
                handle.RegisterAction((a,n)=> { first++;RegionHandle.S2AKeepAction=true; });
                Native.ep_touch(address);
                throw new Exception("unchanged stale action bypassed native guard");
            }
            if(mode==3)
            {
                handle.RegisterAction((a,n)=> { first++;Write(a,n,0x31); });
                Check(Native.ep_perm(address)==0,"real initial NONE protection");
                Native.ep_touch(address);
                Check(first==1&&Native.ep_dirty(address,4096)==0&&Native.ep_perm(address)==1,"normal completion READ and clean");
                Check(Marshal.ReadByte((nint)address)==0x31,"normal physical bytes");
            }
            else if(mode==4)
            {
                handle.RegisterAction((a,n)=> { first++;Write(a,n,first==1?(byte)0x31:(byte)0x72);Native.ep_reprotect(a,n,1);RegionHandle.S2AKeepAction=first==1; });
                Native.ep_touch(address);
                Check(Native.ep_dirty(address,4096)==0&&Native.ep_perm(address)==1,"partial read complete");
                Check(Native.ep_dirty(address+4096,4096)==1&&Native.ep_perm(address+4096)==0,"neighbor retains dirty NONE");
                Check(Marshal.ReadByte((nint)address)==0x31,"first partial bytes");
                Native.ep_touch(address+4096);
                Check(first==2&&Native.ep_dirty(address,8192)==0,"both partial actions completed");
                Check(Marshal.ReadByte((nint)(address+4096))==0x72,"neighbor physical bytes");
            }
            else
            {
                using var entered=new ManualResetEventSlim();using var release=new ManualResetEventSlim();
                handle.RegisterAction((a,n)=> { first++;Write(a,n,0x31);entered.Set();if(!release.Wait(5000))throw new Exception("release deadline"); });
                Check(Native.ep_perm(address)==0&&Native.ep_dirty(address,4096)==1,"real initial NONE and dirty");
                int before=manager.NoneNotifications;
                var reader=new Thread(()=>Native.ep_touch(address));reader.Start();Check(entered.Wait(5000),"actual native touch entered managed callback");
                lock(gate){release.Set();handle.RegisterAction((a,n)=>{second++;Write(a,n,0x72);});}
                Check(reader.Join(5000),"real native generation guard returned");
                Check(first==1&&second==0,"new action retained and not consumed early");
                Check(manager.NoneNotifications>before,"native new action notification");
                Check(Native.ep_dirty(address,4096)==1&&Native.ep_perm(address)==0,"new dirty work remains protected");
                Check(Native.ep_byte(address)==0x31,"first result visible only through shared alias");
                Native.ep_touch(address);
                Check(second==1&&Native.ep_dirty(address,4096)==0&&Native.ep_perm(address)==1,"second readback clears new dirty state");
                Check(Marshal.ReadByte((nint)address)==0x72,"actual original mapping has newest data");
            }
            handle.Dispose();Native.ep_free(address);
            Console.WriteLine($"PASS mode={mode} checks={checks} native track + real MemoryTracking + real Bionic mprotect/alias; no Vulkan/game");return 0;
        }
        catch(Exception e){Console.Error.WriteLine(e);return 1;}
    }
}

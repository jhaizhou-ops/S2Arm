// Actual NvHostEvent/NvFence and syncpoint, with a fake kernel event and handle table.
using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Synchronization;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostCtrl;
using Ryujinx.HLE.HOS.Services.Nv.Types;
class NvHostCheck {
 public static int Run() {
  var gpu=(GpuContext)RuntimeHelpers.GetUninitializedObject(typeof(GpuContext));
  typeof(GpuContext).GetField("<Synchronization>k__BackingField",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(gpu,new SynchronizationManager());
  var ev=new NvHostEvent(new NvHostSyncpt(),0,new Horizon());
  ev.State=NvHostEventState.Signaled; ev.Event.WritableEvent.Signal();
  bool pending=ev.Wait(gpu,new NvFence{Id=0,Value=1});
  bool stale=ev.Event.WritableEvent.IsSignaled;
  gpu.Synchronization.IncrementSyncpoint(0);
  bool signaled=ev.Event.WritableEvent.IsSignaled && ev.State==NvHostEventState.Signaled;
  Console.WriteLine($"pending={pending} stale_before_increment={stale} signaled_after_increment={signaled}");
  bool first=pending&&!stale&&signaled; Console.WriteLine(first?"PASS stale event cleared before registering real syncpoint callback":"FAIL previous signal still visible while fence is pending");
  // Two previous cancellations force the CPU wait. An unsignaled fence must
  // remain pending after the bounded timeout, not be reported as completed.
  var gpu2=(GpuContext)RuntimeHelpers.GetUninitializedObject(typeof(GpuContext));
  typeof(GpuContext).GetField("<Synchronization>k__BackingField",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(gpu2,new SynchronizationManager());
  var repeated=new NvHostEvent(new NvHostSyncpt(),1,new Horizon());
  repeated.Fence=new NvFence{Id=0,Value=1};
  typeof(NvHostEvent).GetField("_failingCount",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(repeated,2u);
  bool remainsPending=repeated.Wait(gpu2,new NvFence{Id=0,Value=1});
  bool waiting=repeated.State==NvHostEventState.Waiting;
  gpu2.Synchronization.IncrementSyncpoint(0);
  bool completes=repeated.State==NvHostEventState.Signaled && repeated.Event.WritableEvent.IsSignaled;
  bool second=remainsPending && waiting && completes;
  Console.WriteLine($"timeout_pending={remainsPending} waiting={waiting} completes_after_increment={completes}");
  Console.WriteLine(second?"PASS timed-out fence stays pending until completion":"FAIL timed-out fence reported completed");
  return first && second ? 0 : 1;
 }
}

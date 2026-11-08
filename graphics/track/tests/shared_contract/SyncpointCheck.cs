// Actual syncpoint waits/increments; intercept only callback scheduling to force the detached-before-timeout interleave.
using System;
using System.Collections;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.Graphics.Gpu.Synchronization;
class SyncpointCheck {
 public static int Run() {
  var manager=new SynchronizationManager();
  var points=(Array)typeof(SynchronizationManager).GetField("_syncpoints",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(manager)!;
  var point=points.GetValue(0)!;
  var list=(IList)point.GetType().GetField("_waiters",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(point)!;
  using var entered=new ManualResetEventSlim(); using var release=new ManualResetEventSlim();
  Task<bool> waiting=Task.Run(()=>manager.WaitOnSyncpoint(0,1,TimeSpan.FromSeconds(2)));
  var limit=DateTime.UtcNow.AddSeconds(1); bool installed=false;
  while(DateTime.UtcNow<limit && !installed) {
   lock(list) { if(list.Count>0) {
      var item=(SyncpointWaiterHandle)list[0]!;
      var f=typeof(SyncpointWaiterHandle).GetField("Callback",BindingFlags.NonPublic|BindingFlags.Instance)!;
      var original=(Action<SyncpointWaiterHandle>)f.GetValue(item)!;
      f.SetValue(item,(Action<SyncpointWaiterHandle>)(w=>{ entered.Set(); if(!release.Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException("callback not released"); original(w); }));
      installed=true;
   }}
   if(!installed)Thread.Sleep(1);
  }
  if(!installed)throw new Exception("waiter did not register");
  Exception? error=null;
  Task increment=Task.Run(()=>{try { manager.IncrementSyncpoint(0); }catch(Exception e){error=e;}});
  if(!entered.Wait(TimeSpan.FromSeconds(1))) throw new Exception("real increment did not detach callback");
  if(!waiting.Wait(TimeSpan.FromSeconds(4))) throw new Exception("wait did not time out");
  bool timedout=waiting.Result; release.Set(); if(!increment.Wait(TimeSpan.FromSeconds(2)))throw new Exception("increment stuck");
  Console.WriteLine($"timedout={timedout} callback_error={error?.GetType().Name ?? "none"}");
  bool ok=timedout && error==null; Console.WriteLine(ok?"PASS actual late detached callback is safe":"FAIL actual late detached callback touched disposed event"); return ok?0:1;
 }
}

// Actual ShaderCache and BackgroundDiskCacheWriter queue with fake program results; no disk I/O.
using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
sealed class FakeProgram(ProgramLinkStatus status) : IProgram {
 public int Calls; public ProgramLinkStatus CheckProgramLink(bool blocking) { Calls++; return status; }
 public byte[] GetBinary() => new byte[]{1,2,3}; public void Dispose() {}
}
class QueueCheck {
 static readonly ManualResetEventSlim Enqueued=new();
 static void Consume<T>(T item) { Enqueued.Set(); }
 public static int Run() {
  var asm=typeof(GpuContext).Assembly;
  var cacheType=asm.GetType("Ryujinx.Graphics.Gpu.Shader.ShaderCache",true)!;
  var cachedType=asm.GetType("Ryujinx.Graphics.Gpu.Shader.CachedShaderProgram",true)!;
  var saveType=cacheType.GetNestedType("ProgramToSave",BindingFlags.NonPublic)!;
  var writerType=asm.GetType("Ryujinx.Graphics.Gpu.Shader.DiskCache.BackgroundDiskCacheWriter",true)!;
  var writer=RuntimeHelpers.GetUninitializedObject(writerType);
  var writerQueueField=writerType.GetField("_fileWriterWorkerQueue",BindingFlags.NonPublic|BindingFlags.Instance)!;
  var writerQueueType=writerQueueField.FieldType; var taskType=writerQueueType.GetGenericArguments()[0];
  var callbackType=typeof(Action<>).MakeGenericType(taskType);
  var method=typeof(QueueCheck).GetMethod("Consume",BindingFlags.NonPublic|BindingFlags.Static)!.MakeGenericMethod(taskType);
  var callback=Delegate.CreateDelegate(callbackType,method);
  var writerQueue=Activator.CreateInstance(writerQueueType,new object?[]{callback,"queue-probe"})!;
  writerQueueField.SetValue(writer,writerQueue);
  var cache=Activator.CreateInstance(cacheType, new object?[]{null})!;
  cacheType.GetField("_cacheWriter",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(cache,writer);
  var queue=cacheType.GetField("_programsToSaveQueue",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(cache)!;
  var enqueue=queue.GetType().GetMethod("Enqueue")!;
  var pending=new FakeProgram(ProgramLinkStatus.Incomplete); var complete=new FakeProgram(ProgramLinkStatus.Success);
  foreach (var program in new[]{pending,complete}) {
    var cached=RuntimeHelpers.GetUninitializedObject(cachedType);
    cachedType.GetField("<HostProgram>k__BackingField",BindingFlags.NonPublic|BindingFlags.Instance)!.SetValue(cached,program);
    var entry=Activator.CreateInstance(saveType,new object?[]{cached,program,new byte[]{1,2,3}})!;
    enqueue.Invoke(queue,new[]{entry});
  }
  cacheType.GetMethod("ProcessShaderCacheQueue")!.Invoke(cache,null);
  int left=(int)queue.GetType().GetProperty("Count")!.GetValue(queue)!;
  bool saved=Enqueued.Wait(TimeSpan.FromSeconds(1)); ((IDisposable)writerQueue).Dispose();
  Console.WriteLine($"pending_checked={pending.Calls} complete_checked={complete.Calls} remaining={left} write_enqueued={saved}");
  bool ok=complete.Calls==1 && left==1 && saved;
  Console.WriteLine(ok?"PASS production queue enqueues completed successor":"FAIL production queue stalls behind incomplete entry");
  return ok?0:1;
 }
}

using System;
using System.IO;
using System.Reflection;
using Ryujinx.Graphics.Vulkan;
class Program {
 static int Main() {
  bool expected=Environment.GetEnvironmentVariable("S2A_SHADER_CACHE_DIAG")=="1";
  var asm=typeof(VulkanRenderer).Assembly;
  var pipe=asm.GetType("Ryujinx.Graphics.Vulkan.PipelineState",true)!;
  var shader=asm.GetType("Ryujinx.Graphics.Vulkan.Shader",true)!;
  const BindingFlags flags=BindingFlags.Static|BindingFlags.NonPublic;
  pipe.GetField("_s2aPipeReported",flags)!.SetValue(null,Environment.TickCount64-10000);
  shader.GetField("_s2aModReported",flags)!.SetValue(null,Environment.TickCount64-10000);
  var count=pipe.GetField("S2APipelinesCreated",flags)!; long before=(long)count.GetValue(null)!;
  var previous=Console.Error; var output=new StringWriter(); Console.SetError(output);
  try {
   pipe.GetMethod("S2AReportPipelineTime",flags)!.Invoke(null,new object[]{System.Diagnostics.Stopwatch.GetTimestamp()});
   shader.GetMethod("S2AReportModuleTime",flags)!.Invoke(null,new object[]{System.Diagnostics.Stopwatch.GetTimestamp()});
  } finally { Console.SetError(previous); }
  long after=(long)count.GetValue(null)!; string log=output.ToString();
  bool pipeline=log.Contains("[vkpb] 管线创建"), module=log.Contains("[vkpb] 着色器模块");
  var shouldLog=typeof(VulkanRenderer).GetMethod("S2AShouldLogProgramBinaryLoad",flags)!;
  bool first=(bool)shouldLog.Invoke(null,new object[]{1L})!;
  bool ninth=(bool)shouldLog.Invoke(null,new object[]{9L})!;
  bool sixteenth=(bool)shouldLog.Invoke(null,new object[]{16L})!;
  // The device runner consumes pipeline creation windows even without diagnostics.
  bool ok=pipeline && module==expected && after==before+1 && first==expected && !ninth && sixteenth==expected;
  Console.WriteLine($"diag={expected} pipeline_log={pipeline} module_log={module} pipeline_count_delta={after-before} load_log_1_9_16={first}/{ninth}/{sixteenth}");
  Console.WriteLine(ok?"PASS Vulkan diagnostic default and cache generation":"FAIL Vulkan diagnostic default or cache generation"); return ok?0:1;
 }
}

using Ryujinx.Horizon.Common;
namespace Ryujinx.Horizon.Common { public enum Result { Success } }
namespace Ryujinx.HLE.HOS { public class Horizon { public object KernelContext = new(); } public class ServiceCtx { public Process Process = new(); } public class Process { public HandleTable HandleTable = new(); } public class HandleTable { public Result GenerateHandle(object value,out int handle){handle=1;return Result.Success;} public void CloseHandle(int handle){} } }
namespace Ryujinx.HLE.HOS.Kernel { public static class KernelStatic { public static Ryujinx.HLE.HOS.Process GetCurrentProcess()=>new(); } }
namespace Ryujinx.HLE.HOS.Kernel.Threading { public class KEvent { public KEvent(object context){} public object ReadableEvent = new(); public FakeEvent WritableEvent = new(); } public class FakeEvent { public bool IsSignaled; public void Signal(){IsSignaled=true;} public void Clear(){IsSignaled=false;} } }
namespace Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostCtrl { class NvHostSyncpt { public uint ReadSyncpointValue(uint id)=>0; } }

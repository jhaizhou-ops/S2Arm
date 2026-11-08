using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.Memory;
using System.IO;

namespace Ryujinx.HLE.HOS
{
    class ServiceCtx
    {
        public Switch Device { get; private set; }
        public KProcess Process { get; private set; }
        public IVirtualMemoryManager Memory { get; private set; }
        public KThread Thread { get; private set; }
        public IpcMessage Request { get; private set; }
        public IpcMessage Response { get; private set; }
        public BinaryReader RequestData { get; private set; }
        public BinaryWriter ResponseData { get; private set; }
        public ulong ClientProcessId => Request.HandleDesc is { HasPId: true } ? Request.HandleDesc.PId : Process.Pid;

        // S2Arm: reuse one context per game thread (zero steady-state allocation in direct dispatch)
        internal void S2AReset(
            Switch device,
            KProcess process,
            IVirtualMemoryManager memory,
            KThread thread,
            IpcMessage request,
            IpcMessage response,
            BinaryReader requestData,
            BinaryWriter responseData)
        {
            Device = device;
            Process = process;
            Memory = memory;
            Thread = thread;
            Request = request;
            Response = response;
            RequestData = requestData;
            ResponseData = responseData;
        }

        public ServiceCtx(
            Switch device,
            KProcess process,
            IVirtualMemoryManager memory,
            KThread thread,
            IpcMessage request,
            IpcMessage response,
            BinaryReader requestData,
            BinaryWriter responseData)
        {
            Device = device;
            Process = process;
            Memory = memory;
            Thread = thread;
            Request = request;
            Response = response;
            RequestData = requestData;
            ResponseData = responseData;
        }
    }
}

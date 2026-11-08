using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.HLE.HOS.Services.Am.AppletAE.AllSystemAppletProxiesService.LibraryAppletCreator;

namespace Ryujinx.HLE.HOS.Services.Am.AppletAE.AllSystemAppletProxiesService.SystemAppletProxy
{
    class ILibraryAppletCreator : IpcService
    {
        public ILibraryAppletCreator() { }

        [CommandCmif(0)]
        // CreateLibraryApplet(u32, u32) -> object<nn::am::service::ILibraryAppletAccessor>
        public ResultCode CreateLibraryApplet(ServiceCtx context)
        {
            AppletId appletId = AppletIdWire.Read(context.RequestData.ReadUInt32());
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            int libraryAppletMode = context.RequestData.ReadInt32();
#pragma warning restore IDE0059

            MakeObject(context, new ILibraryAppletAccessor(appletId, context.Device.System));

            return ResultCode.Success;
        }

        [CommandCmif(3)] // 20.0.0+
        // CreateLibraryAppletEx(u32, u32, u64) -> object<nn::am::service::ILibraryAppletAccessor>
        public ResultCode CreateLibraryAppletEx(ServiceCtx context)
        {
            AppletId appletId = AppletIdWire.Read(context.RequestData.ReadUInt32());

            _ = context.RequestData.ReadInt32(); // libraryAppletMode

            _ = context.RequestData.ReadUInt64(); // threadId

            MakeObject(context, new ILibraryAppletAccessor(appletId, context.Device.System));

            return ResultCode.Success;
        }

        [CommandCmif(10)]
        // CreateStorage(u64) -> object<nn::am::service::IStorage>
        public ResultCode CreateStorage(ServiceCtx context)
        {
            long size = context.RequestData.ReadInt64();

            if (size <= 0)
            {
                return ResultCode.ObjectInvalid;
            }

            if (size > int.MaxValue)
            {
                return ResultCode.ObjectInvalid;
            }

            // S2Arm: native memory owned by the storage (freed when the game closes it), not a managed array of the game-chosen size
            MakeObject(context, IStorage.CreateNative((int)size));

            // NOTE: Returns ResultCode.MemoryAllocationFailed if IStorage is null, it doesn't occur in our case.

            return ResultCode.Success;
        }

        // S2Arm: the storage is the game's transfer memory itself (a view, as on hardware) when the host can map it directly; otherwise a copy
        private static System.Memory<byte> TransferMemoryData(KTransferMemory transferMem)
        {
            if (S2AHooks.GuestView != null && S2AHooks.GuestView(transferMem.Address, (int)transferMem.Size) is System.Memory<byte> view)
            {
                return view;
            }

            byte[] data = new byte[transferMem.Size];

            transferMem.Creator.CpuMemory.Read(transferMem.Address, data);

            return data;
        }

        [CommandCmif(11)]
        // CreateTransferMemoryStorage(b8, u64, handle<copy>) -> object<nn::am::service::IStorage>
        public ResultCode CreateTransferMemoryStorage(ServiceCtx context)
        {
            bool isReadOnly = (context.RequestData.ReadInt64() & 1) == 0;
            long size = context.RequestData.ReadInt64();
            int handle = context.Request.HandleDesc.ToCopy[0];

            KTransferMemory transferMem = context.Process.HandleTable.GetObject<KTransferMemory>(handle);

            if (size <= 0)
            {
                return ResultCode.ObjectInvalid;
            }

            System.Memory<byte> data = TransferMemoryData(transferMem);

            context.Device.System.KernelContext.Syscall.CloseHandle(handle);

            MakeObject(context, new IStorage(data, isReadOnly));

            return ResultCode.Success;
        }

        [CommandCmif(12)] // 2.0.0+
        // CreateHandleStorage(u64, handle<copy>) -> object<nn::am::service::IStorage>
        public ResultCode CreateHandleStorage(ServiceCtx context)
        {
            long size = context.RequestData.ReadInt64();
            int handle = context.Request.HandleDesc.ToCopy[0];

            KTransferMemory transferMem = context.Process.HandleTable.GetObject<KTransferMemory>(handle);

            if (size <= 0)
            {
                return ResultCode.ObjectInvalid;
            }

            System.Memory<byte> data = TransferMemoryData(transferMem);

            context.Device.System.KernelContext.Syscall.CloseHandle(handle);

            MakeObject(context, new IStorage(data));

            return ResultCode.Success;
        }
    }
}

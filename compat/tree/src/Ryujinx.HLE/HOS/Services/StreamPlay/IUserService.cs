using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.Horizon.Common;
using System;

namespace Ryujinx.HLE.HOS.Services.StreamPlay
{
    // S2Arm：Switch 2 的 stpl:u（nn::streamplay，GameShare 把画面串流给别的主机）。Pokopia 首帧后经 nn::streamplay::GetRequiredMemorySize 连它，
    //   没有即 Break 0xe15（2021-0007）。宿主不做串流：库就绪、没有会话、没有客机连进来。命令号与参数形状来自 Eden-NS2 ngc.cpp（GPL，只借事实，代码自写）
    [Service("stpl:u")]
    class IUserService : IpcService
    {
        public IUserService(ServiceCtx context) { }

        [CommandCmif(0)]
        // GetUserShimScopedObject(u32 client_version) -> object<nn::streamplay::IUserShimScopedObject>
        public ResultCode GetUserShimScopedObject(ServiceCtx context)
        {
            context.RequestData.ReadUInt32();

            MakeObject(context, new IUserShimScopedObject());

            return ResultCode.Success;
        }
    }

    class IUserShimScopedObject : IpcService
    {
        [CommandCmif(1)]
        // GetRequiredMemorySize(u8 type, u8 mode, s32 guest_count) -> u32：SDK 在 Initialize 里按「缓冲长 ÷ 每客机所需」反推客机数，
        //   所以要与客机数成正比；宿主每客机给一页（不存任何串流状态）
        public ResultCode GetRequiredMemorySize(ServiceCtx context)
        {
            context.RequestData.ReadByte();
            context.RequestData.ReadByte();
            context.RequestData.BaseStream.Position = 4;
            int guests = context.RequestData.ReadInt32();

            context.ResponseData.Write((uint)(guests > 0 ? guests : 0) * 0x1000u);

            return ResultCode.Success;
        }

        [CommandCmif(2)]
        // Initialize(u8 type, u8 mode, s32 guest_count, u64 context, pid)：就绪，不开会话
        public ResultCode Initialize(ServiceCtx context)
        {
            return ResultCode.Success;
        }

        // 客机手柄共享内存：三个客机的手柄块、触屏环、Joy-Con 鼠标环，共 0x84000 字节（Eden-NS2 的尺寸）。全 0 = 风格集为空、环为空 = 没有客机连着
        private const ulong GuestHidMemorySize = 0x84000;
        private KSharedMemory _guestHid;
        private int _guestHidHandle;

        [CommandCmif(300)]
        // GetGuestHidSharedMemory() -> (u64 size, u64 offset), handle<copy>（Pokopia 初始化 streamplay 后取它）
        public ResultCode GetGuestHidSharedMemory(ServiceCtx context)
        {
            if (_guestHid == null)
            {
                KernelContext kernel = context.Device.System.KernelContext;
                ulong pages = GuestHidMemorySize / KPageTableBase.PageSize;
                ulong pa = kernel.MemoryManager.MemoryRegions[(int)MemoryRegion.Service].AllocatePagesContiguous(kernel, pages, false);

                if (pa == 0)
                {
                    throw new InvalidOperationException("stpl:u 客机手柄共享内存：服务区连续页不够");   // 0x84 页，不该发生
                }

                KPageList list = new();
                list.AddRange(pa, pages);
                SharedMemoryStorage storage = new(kernel, list);
                storage.ZeroFill();
                _guestHid = new KSharedMemory(kernel, storage, 0, 0, KMemoryPermission.Read);
            }

            if (_guestHidHandle == 0 && context.Process.HandleTable.GenerateHandle(_guestHid, out _guestHidHandle) != Result.Success)
            {
                throw new InvalidOperationException("Out of handles!");
            }

            context.ResponseData.Write(GuestHidMemorySize);
            context.ResponseData.Write(0UL);
            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_guestHidHandle);

            return ResultCode.Success;
        }
    }
}

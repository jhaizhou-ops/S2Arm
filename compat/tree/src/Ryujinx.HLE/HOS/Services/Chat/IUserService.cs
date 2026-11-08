using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.Horizon.Common;
using System;

namespace Ryujinx.HLE.HOS.Services.Chat
{
    // S2Arm：Switch 2 的 chat:u（nn::chat，GameChat）。4 款 Switch 2 游戏的 NPDM 服务表都许可 chat:u，sdk 带 nn::chat::IUserService 客户端代理。
    //   事实取自 Eden-NS2（GPL，代码自写）ngc/ngc.cpp 的 IChatUserService / IChatUserShimScopedObject（按真机 chat 模块反汇编整理）：
    //   命令 0 取用户侧对象；命令 3（带 pid）取虚拟摄像头对象。宿主没有 GameChat：对象给出，事件永不触发（没有聊天活动），
    //   其余命令（真机语义未知）按未实现报红，不回成功
    [Service("chat:u")]
    class IUserService : IpcService
    {
        public IUserService(ServiceCtx context) { }

        [CommandCmif(0)]
        // GetUserShimScopedObject() -> object<nn::chat::IUserShimScopedObject>
        public ResultCode GetUserShimScopedObject(ServiceCtx context)
        {
            MakeObject(context, new IUserShimScopedObject(context.Device.System.KernelContext));

            return ResultCode.Success;
        }

        [CommandCmif(3)]
        // GetVirtualCameraShimScopedObject(pid) -> object<nn::chat::IVirtualCameraShimScopedObject>
        public ResultCode GetVirtualCameraShimScopedObject(ServiceCtx context)
        {
            MakeObject(context, new IVirtualCameraShimScopedObject());

            return ResultCode.Success;
        }
    }

    class IUserShimScopedObject : IpcService
    {
        // 真机 chat 模块：命令 1–7 与 10 共用一段实现——各自的事件只交出一次（复制句柄），再要回 0x4E2（模块 226、描述 2）
        public const ResultCode ResultEventAlreadyTaken = (ResultCode)0x4E2;

        private readonly KEvent[] _events = new KEvent[8];
        private readonly bool[] _taken = new bool[8];

        public IUserShimScopedObject(KernelContext kernel)
        {
            for (int i = 0; i < _events.Length; i++)
            {
                _events[i] = new KEvent(kernel);
            }
        }

        [CommandCmif(1)] public ResultCode GetEvent0(ServiceCtx context) => GetEvent(context, 0);
        [CommandCmif(2)] public ResultCode GetEvent1(ServiceCtx context) => GetEvent(context, 1);
        [CommandCmif(3)] public ResultCode GetEvent2(ServiceCtx context) => GetEvent(context, 2);
        [CommandCmif(4)] public ResultCode GetEvent3(ServiceCtx context) => GetEvent(context, 3);
        [CommandCmif(5)] public ResultCode GetEvent4(ServiceCtx context) => GetEvent(context, 4);
        [CommandCmif(6)] public ResultCode GetEvent5(ServiceCtx context) => GetEvent(context, 5);
        [CommandCmif(7)] public ResultCode GetEvent6(ServiceCtx context) => GetEvent(context, 6);
        [CommandCmif(10)] public ResultCode GetEvent7(ServiceCtx context) => GetEvent(context, 7);

        // GetEventN() -> handle<copy>
        private ResultCode GetEvent(ServiceCtx context, int index)
        {
            if (_taken[index])
            {
                return ResultEventAlreadyTaken;
            }

            if (context.Process.HandleTable.GenerateHandle(_events[index].ReadableEvent, out int handle) != Result.Success)
            {
                throw new InvalidOperationException("Out of handles!");
            }

            _taken[index] = true;
            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(handle);

            return ResultCode.Success;
        }
    }

    // 虚拟摄像头对象：真机命令语义未知（Eden 也是空对象），任何命令按未实现报红
    class IVirtualCameraShimScopedObject : IpcService
    {
    }
}

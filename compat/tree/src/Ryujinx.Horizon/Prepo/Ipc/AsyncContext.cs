using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.OsTypes;
using Ryujinx.Horizon.Sdk.Prepo;
using Ryujinx.Horizon.Sdk.Sf;
using System;

namespace Ryujinx.Horizon.Prepo.Ipc
{
    // S2Arm：prepo 的异步上下文（nn::prepo::detail::ipc::IAsyncContext，Switch 2 prepo:u 10500 回出）。命令表取自时之笛 sdk 代理 vtable 0xe72478：
    //   0 = 取完成事件（回复制句柄；nn::prepo::AsyncContext::GetCompletionEvent 0x5a9230 以手动清除挂上，失败即 AbortImpl）、
    //   1 = Cancel（无入无出；AsyncContext::Cancel 0x5a92e0 失败即 AbortImpl）、2 = GetResult（无入无出，结果即命令结果；0x5a9320）。
    //   与 nn::account 的 IAsyncContext（0 / 1 / 2 HasDone / 3 GetResult）不同形：没有 HasDone。
    //   报告在 10500 里已同步收完（sdk 发完即销毁传输内存），所以建出来就是已完成：事件已亮，Cancel 无事可做
    partial class AsyncContext : IAsyncContext, IDisposable
    {
        private readonly Result _result;
        private SystemEventType _event;

        public AsyncContext(Result result)
        {
            _result = result;

            Os.CreateSystemEvent(out _event, EventClearMode.ManualClear, interProcess: true).AbortOnFailure();
            Os.SignalSystemEvent(ref _event);
        }

        [CmifCommand(0)]
        public Result GetSystemEvent([CopyHandle] out int eventHandle)
        {
            eventHandle = Os.GetReadableHandleOfSystemEvent(ref _event);

            return Result.Success;
        }

        [CmifCommand(1)]
        public Result Cancel()
        {
            return Result.Success;
        }

        [CmifCommand(2)]
        public Result GetResult()
        {
            return _result;
        }

        public void Dispose()
        {
            Os.DestroySystemEvent(ref _event);
        }
    }
}

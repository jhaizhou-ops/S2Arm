using Ryujinx.Common.Logging;
using Ryujinx.HLE.Exceptions;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.Horizon.Common;
using System;

namespace Ryujinx.HLE.HOS.Services.Am.AppletAE.AllSystemAppletProxiesService.LibraryAppletCreator
{
    class ILibraryAppletAccessor : DisposableIpcService
    {
        private readonly KernelContext _kernelContext;

        private readonly IApplet _applet;

        private readonly AppletSession _normalSession;
        private readonly AppletSession _interactiveSession;

        private readonly KEvent _stateChangedEvent;
        private readonly KEvent _normalOutDataEvent;
        private readonly KEvent _interactiveOutDataEvent;

        private int _stateChangedEventHandle;
        private int _normalOutDataEventHandle;
        private int _interactiveOutDataEventHandle;

        private int _indirectLayerHandle;

        private bool _cmd170Logged;

        public ILibraryAppletAccessor(AppletId appletId, Horizon system)
        {
            _kernelContext = system.KernelContext;

            _stateChangedEvent = new KEvent(system.KernelContext);
            _normalOutDataEvent = new KEvent(system.KernelContext);
            _interactiveOutDataEvent = new KEvent(system.KernelContext);

            _applet = AppletManager.Create(appletId, system);

            _normalSession = new AppletSession();
            _interactiveSession = new AppletSession();

            _applet.AppletStateChanged += OnAppletStateChanged;
            _normalSession.DataAvailable += OnNormalOutData;
            _interactiveSession.DataAvailable += OnInteractiveOutData;

            Logger.Info?.Print(LogClass.ServiceAm, $"Applet '{appletId}' created.");
        }

        private void OnAppletStateChanged(object sender, EventArgs e)
        {
            _stateChangedEvent.WritableEvent.Signal();
        }

        private void OnNormalOutData(object sender, EventArgs e)
        {
            _normalOutDataEvent.WritableEvent.Signal();
        }

        private void OnInteractiveOutData(object sender, EventArgs e)
        {
            _interactiveOutDataEvent.WritableEvent.Signal();
        }

        [CommandCmif(0)]
        // GetAppletStateChangedEvent() -> handle<copy>
        public ResultCode GetAppletStateChangedEvent(ServiceCtx context)
        {
            if (_stateChangedEventHandle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_stateChangedEvent.ReadableEvent, out _stateChangedEventHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_stateChangedEventHandle);

            return ResultCode.Success;
        }

        [CommandCmif(10)]
        // Start()
        public ResultCode Start(ServiceCtx context)
        {
            return (ResultCode)_applet.Start(_normalSession.GetConsumer(), _interactiveSession.GetConsumer());
        }

        [CommandCmif(20)]
        // RequestExit()
        public ResultCode RequestExit(ServiceCtx context)
        {
            // TODO: Since we don't support software Applet for now, we can just signals the changed state of the applet.
            _stateChangedEvent.ReadableEvent.Signal();

            Logger.Stub?.PrintStub(LogClass.ServiceAm);

            return ResultCode.Success;
        }

        [CommandCmif(30)]
        // GetResult()
        public ResultCode GetResult(ServiceCtx context)
        {
            return (ResultCode)_applet.GetResult();
        }

        [CommandCmif(60)]
        // PresetLibraryAppletGpuTimeSliceZero()
        public ResultCode PresetLibraryAppletGpuTimeSliceZero(ServiceCtx context)
        {
            // NOTE: This call reset two internal fields to 0 and one internal field to "true".
            //       It seems to be used only with software keyboard inline.
            //       Since we don't support applets for now, it's fine to stub it.

            Logger.Stub?.PrintStub(LogClass.ServiceAm);

            return ResultCode.Success;
        }
        
        [CommandCmif(90)]
        // Unknown90(ulong[4])
        public ResultCode Unknown90(ServiceCtx context)
        {
            // NOTE: This call is performed on SDK 20+ when applet is called.
            //       Since we don't support most applets for now, it's fine to stub it.
            //       Throw if values are not 0 to learn more about what this function does.

            if (context.RequestData.ReadUInt64() != 0 || context.RequestData.ReadUInt64() != 0 ||
                context.RequestData.ReadUInt64() != 0 || context.RequestData.ReadUInt64() != 0)
            {
                throw new ServiceNotImplementedException(this, context, $"{GetType().FullName}: 90");
            }

            Logger.Stub?.PrintStub(LogClass.ServiceAm);
            return ResultCode.Success;
        }

        [CommandCmif(100)]
        // PushInData(object<nn::am::service::IStorage>)
        public ResultCode PushInData(ServiceCtx context)
        {
            IStorage data = GetObject<IStorage>(context, 0);

            _normalSession.Push(data.Data.ToArray());

            return ResultCode.Success;
        }

        [CommandCmif(101)]
        // PopOutData() -> object<nn::am::service::IStorage>
        public ResultCode PopOutData(ServiceCtx context)
        {
            if (_normalSession.TryPop(out byte[] data))
            {
                MakeObject(context, new IStorage(data));

                _normalOutDataEvent.WritableEvent.Clear();

                return ResultCode.Success;
            }

            return ResultCode.NotAvailable;
        }

        [CommandCmif(103)]
        // PushInteractiveInData(object<nn::am::service::IStorage>)
        public ResultCode PushInteractiveInData(ServiceCtx context)
        {
            IStorage data = GetObject<IStorage>(context, 0);

            _interactiveSession.Push(data.Data.ToArray());

            return ResultCode.Success;
        }

        [CommandCmif(104)]
        // PopInteractiveOutData() -> object<nn::am::service::IStorage>
        public ResultCode PopInteractiveOutData(ServiceCtx context)
        {
            if (_interactiveSession.TryPop(out byte[] data))
            {
                MakeObject(context, new IStorage(data));

                _interactiveOutDataEvent.WritableEvent.Clear();

                return ResultCode.Success;
            }

            return ResultCode.NotAvailable;
        }

        [CommandCmif(105)]
        // GetPopOutDataEvent() -> handle<copy>
        public ResultCode GetPopOutDataEvent(ServiceCtx context)
        {
            if (_normalOutDataEventHandle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_normalOutDataEvent.ReadableEvent, out _normalOutDataEventHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_normalOutDataEventHandle);

            return ResultCode.Success;
        }

        [CommandCmif(106)]
        // GetPopInteractiveOutDataEvent() -> handle<copy>
        public ResultCode GetPopInteractiveOutDataEvent(ServiceCtx context)
        {
            if (_interactiveOutDataEventHandle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(_interactiveOutDataEvent.ReadableEvent, out _interactiveOutDataEventHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_interactiveOutDataEventHandle);

            return ResultCode.Success;
        }

        [CommandCmif(110)]
        // NeedsToExitProcess()
        public ResultCode NeedsToExitProcess(ServiceCtx context)
        {
            return ResultCode.Stubbed;
        }

        [CommandCmif(150)]
        // RequestForAppletToGetForeground()
        public ResultCode RequestForAppletToGetForeground(ServiceCtx context)
        {
            return ResultCode.Stubbed;
        }

        [CommandCmif(160)] // 2.0.0+
        // GetIndirectLayerConsumerHandle() -> u64 indirect_layer_consumer_handle
        public ResultCode GetIndirectLayerConsumerHandle(ServiceCtx context)
        {
            Horizon horizon = _kernelContext.Device.System;

            _indirectLayerHandle = horizon.AppletState.IndirectLayerHandles.Add(_applet);

            context.ResponseData.Write((ulong)_indirectLayerHandle);

            return ResultCode.Success;
        }

        [CommandCmif(170)] // Switch 2（S2Arm）
        // 火纹 Fortune's Weave 建软键盘小程序后、启动前调它；未实现时回 ResultSfUnknownMethodId，sdk 视为致命 Break（2010-0221）。
        // 同期 sdk 新增 nn::applet::SetStreamPlayShareEnabled(handle, bool, bool)：只把两个开关存进句柄、启动时才下发，判断本命令是这类串流 / 分享设置。
        // 宿主没有串流 / 分享功能：收下回成功、不生效；首次把请求原始参数打进日志，留作以后对照语义
        public ResultCode SwitchTwoAppletSetting170(ServiceCtx context)
        {
            if (!_cmd170Logged)
            {
                _cmd170Logged = true;
                byte[] raw = context.RequestData.ReadBytes((int)System.Math.Min(16, context.RequestData.BaseStream.Length - context.RequestData.BaseStream.Position));
                Logger.Info?.Print(LogClass.ServiceAm, $"ILibraryAppletAccessor 命令 170（Switch 2）：收下回成功、不生效；请求参数 {System.Convert.ToHexString(raw)}");
            }

            return ResultCode.Success;
        }

        protected override void Dispose(bool isDisposing)
        {
            if (isDisposing)
            {
                if (_stateChangedEventHandle != 0)
                {
                    _kernelContext.Syscall.CloseHandle(_stateChangedEventHandle);
                }

                if (_normalOutDataEventHandle != 0)
                {
                    _kernelContext.Syscall.CloseHandle(_normalOutDataEventHandle);
                }

                if (_interactiveOutDataEventHandle != 0)
                {
                    _kernelContext.Syscall.CloseHandle(_interactiveOutDataEventHandle);
                }
            }

            Horizon horizon = _kernelContext.Device.System;

            horizon.AppletState.IndirectLayerHandles.Delete(_indirectLayerHandle);
        }
    }
}

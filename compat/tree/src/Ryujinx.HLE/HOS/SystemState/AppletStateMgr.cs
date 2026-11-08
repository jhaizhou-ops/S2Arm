using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Am.AppletAE.AllSystemAppletProxiesService.SystemAppletProxy;
using System.Collections.Concurrent;

namespace Ryujinx.HLE.HOS.SystemState
{
    class AppletStateMgr
    {
        public ConcurrentQueue<AppletMessage> Messages { get; }

        public FocusState FocusState { get; private set; }

        public KEvent MessageEvent { get; }

        // S2Arm：Switch 2 的 IApplicationFunctions 210。Switch 2 SDK 的 nn::oe::GetOperationMode 缓存模式，只在这个事件触发后才重问
        //   ICommonStateGetter，所以每次掌机 / 主机模式切换都要触发（不看模式变化通知开关）。事实取自 Eden-NS2（GPL，代码自写）
        //   am/service/application_functions.cpp GetOperationModeRefreshEvent、am/lifecycle_manager.cpp OnOperationAndPerformanceModeChanged
        public KEvent OperationModeRefreshEvent { get; }

        public IdDictionary AppletResourceUserIds { get; }

        public IdDictionary IndirectLayerHandles { get; }

        // S2Arm（缺口扫描族 1 / 2，11-01）：游戏经 ISelfController 设的焦点 / 模式通知开关，原先各自存在 ISelfController 里读完即弃。
        //   模式变化通知缺省开，游戏显式关了才不发。
        // 焦点处理（审计 P2-37）：按 am 的三种模式（参照 libnx appletSetFocusHandlingMode 与 yuzu 系 LifecycleManager）。
        //   SetFocusHandlingMode(通知, 后台, 暂停)：暂停 = 0 → NoSuspend；暂停 = 1 时从 NoSuspend 回 SuspendHomeSleep。
        //   SetOutOfFocusSuspendingEnabled：1 → AlwaysSuspend；0 时从 AlwaysSuspend 回 SuspendHomeSleep。
        //   宿主失焦（Mac 窗口失焦、开键位窗口）按 am「前台被遮挡」处理：AlwaysSuspend 冻结客机、游戏不知道自己失焦（焦点状态不变、不发消息）；
        //   另两种照常运行、焦点状态变 OutOfFocus。通知 = 0 时焦点变化不发消息（状态照变）。
        //   「后台」标志在 am 里只管 HOME / 睡眠下的 Background 状态，我方宿主没有这种状态，不存。
        //   缺省 AlwaysSuspend：同改前「失焦暂停缺省开」，游戏什么都不设时失焦即冻结
        private enum FocusHandling { AlwaysSuspend, SuspendHomeSleep, NoSuspend }

        private FocusHandling _focusHandling = FocusHandling.AlwaysSuspend;
        // AlwaysSuspend 下吞掉的失焦：回前台时同样不发消息（游戏从头到尾不知道）
        private bool _focusLossHidden;

        public bool OutOfFocusSuspending => _focusHandling == FocusHandling.AlwaysSuspend;
        public bool FocusStateChangedNotification { get; private set; } = true;
        public bool OperationModeChangedNotification { get; set; } = true;
        public bool PerformanceModeChangedNotification { get; set; } = true;
        // 宿主接线（S2A.Services）：失焦暂停（= AlwaysSuspend）变了就告诉平台壳（平台壳失焦时据此冻结客机）
        public static System.Action<bool> OutOfFocusSuspendingChanged;

        public void SetFocusHandlingMode(bool notify, bool suspend)
        {
            FocusStateChangedNotification = notify;

            if (!suspend)
            {
                _focusHandling = FocusHandling.NoSuspend;
            }
            else if (_focusHandling == FocusHandling.NoSuspend)
            {
                _focusHandling = FocusHandling.SuspendHomeSleep;
            }

            OutOfFocusSuspendingChanged?.Invoke(OutOfFocusSuspending);
        }

        public void SetOutOfFocusSuspending(bool on)
        {
            if (on)
            {
                _focusHandling = FocusHandling.AlwaysSuspend;
            }
            else if (_focusHandling == FocusHandling.AlwaysSuspend)
            {
                _focusHandling = FocusHandling.SuspendHomeSleep;
            }

            OutOfFocusSuspendingChanged?.Invoke(OutOfFocusSuspending);
        }

        public AppletStateMgr(Horizon system)
        {
            Messages = new ConcurrentQueue<AppletMessage>();
            MessageEvent = new KEvent(system.KernelContext);
            OperationModeRefreshEvent = new KEvent(system.KernelContext);

            AppletResourceUserIds = new IdDictionary();
            IndirectLayerHandles = new IdDictionary();
        }

        public void SetFocus(bool isFocused)
        {
            // S2Arm（P2-37）：AlwaysSuspend 下失焦由平台壳冻结，游戏不知道自己失焦；回前台也就没有变化可通知
            if (!isFocused && OutOfFocusSuspending)
            {
                _focusLossHidden = true;

                return;
            }

            if (isFocused && _focusLossHidden)
            {
                _focusLossHidden = false;

                return;
            }

            FocusState = isFocused ? FocusState.InFocus : FocusState.OutOfFocus;

            // S2Arm（P2-37）：游戏用 SetFocusHandlingMode 第一个标志关了焦点通知就不发消息
            if (!FocusStateChangedNotification)
            {
                return;
            }

            Messages.Enqueue(AppletMessage.FocusStateChanged);

            if (isFocused)
            {
                Messages.Enqueue(AppletMessage.ChangeIntoForeground);
            }

            MessageEvent.ReadableEvent.Signal();
        }
    }
}

using Ryujinx.HLE;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services
{
    // 手柄采样泵：iOS 输入变化立即提交，16 ms 心跳继续处理反馈；其他宿主沿用定时采样。
    // 输入 = 苹果侧输入源（InputHook，未接时为空）∪ 通用自动玩家的键（测试层，宿主里弱链接，有就取）。
    // 初始触屏按运行模式配置；首次发现外接手柄后偏好独立 Pro 手柄，操作 / 渲染模式保持不变。
    public static unsafe class InputPump
    {
        // 苹果侧手柄 / 触屏输入源（苹果侧接）：填按键位（HidNpadButton 位序）与左右摇杆
        public static delegate*<ref GamepadInput, void> InputHook;
        // Optional platform touch consumer, on this same HID owner thread.
        // Absent on Apple and other hosts; no second sampler or HID writer.
        public static Action<Switch> TouchHook;
        // Debug-only call site: reads the real HID memory after a touch commit.
        public static string DescribeTouch(Switch device)
        {
            ref var entry = ref device.Hid.SharedMemory.TouchScreen.GetCurrentEntryRef();
            var point = entry.Touches.AsSpan()[0];
            return $"HID touch #{entry.SamplingNumber}: count={entry.TouchesCount} first={point.FingerId}:{point.X},{point.Y} attr={point.Attribute}";
        }
        public static string DescribeGesture(Switch device)
        {
            ref var entry = ref device.Hid.SharedMemory.Gesture.GetCurrentEntryRef();
            return $"HID gesture #{entry.SamplingNumber}: {entry.Input.Type} context={entry.Input.ContextNumber} point={entry.Input.X},{entry.Input.Y} count={entry.Input.PointCount}";
        }

        // 自动玩家（tests/autoplay）给一号手柄的键、二号手柄的键（驾驶员答「2:键」）、要的手柄数（1 / 2）。宿主里按导出查；单测直接赋值
        public static delegate* unmanaged<uint> AutoplayKeys1;
        public static delegate* unmanaged<uint> AutoplayKeys2;
        public static delegate* unmanaged<int> AutoplayPads;
        private static Thread _thread;
        private static volatile bool _stop;
        private static volatile PlayerIndex _player = PlayerIndex.Handheld;
        private static volatile ControllerType _type = ControllerType.Handheld;
        private static volatile bool _externalController;
        private static int _configurationGeneration;

        // 虚拟手柄个数：1，或 2（本机双手柄：强制本地合作的款，如双人成行，要两个已连接的手柄才进得了游戏）。
        //   S2A_AP_PADS=2 起局即开（Mac 启动设置「游玩人数=2」经 launch_env 写入）；游戏经手柄设置小程序声明至少 2 人时，运行中由 Host.DisplayMessageDialog 开到 2（SetPads）；
        //   自动玩家要二号手柄时（s2a_autoplay_pads = 2），采样泵下一拍开到 2。
        //   Mac 一组 Joy-Con + 单人（_pads=1、S2A_PAD_SETS≠2）：左右合成一对 Pro（标题屏 L+R）；一组+两人靠启动设置预拆（S2A_AP_PADS=2），不必等游戏再 SetPads。
        //   S2A_PAD_SETS=2（启动设置「有几组手柄=2」）：单人时不合并第二组，只吃槽 0。
        //   第二槽：有独立真手柄（s2a_vpad_read2）则各控各的；否则仍镜像第一槽（单手柄被迫开 2 人 / 旧路径）；
        //   自动玩家接管二号后只收「2:键」，不镜像一号（双人成行选角色）。
        private static readonly int EnvPads = Environment.GetEnvironmentVariable("S2A_AP_PADS") == "2" ? 2 : 1;
        private static readonly bool EnvMergePair = Environment.GetEnvironmentVariable("S2A_PAD_SETS") != "2";
        private static volatile int _pads = EnvPads;
        private static volatile PlayerIndex _second = PlayerIndex.Unknown;

        public static PlayerIndex Player => _player;
        public static PlayerIndex SecondPlayer => _second;
        public static ControllerType Type => _type;
        public static int Pads => _pads;
        public static bool ExternalController => _externalController;

        public static void Start(Switch device) => SetPrimary(device, Host.Docked ? PlayerIndex.Player1 : PlayerIndex.Handheld, Host.Docked ? ControllerType.ProController : ControllerType.Handheld);

        // 游戏声明的手柄号不含掌机格、含 Player1 时（11-02 维护者 手测七龙珠电光炸裂ZERO 010035F022078000：SetSupportedNpadIdType 只给 Player1，
        //   掌机格被 Remap 断开、「No matching controllers found」，触屏手柄按什么都没反应；真机掌机模式下这时握着的 Joy-Con 当 Player1 用）：
        //   主手柄在掌机格就改到 Player1 的 Pro 手柄（样式不符时 Remap 自己换成双 Joy-Con）；之后游戏又声明掌机格、且是这里挪走的，挪回掌机格。
        //   采样泵每 250 ms 调一次；只读手柄号表，不改游戏的声明
        //   用 IsSupportedPlayer 逐格查，不走 GetSupportedPlayers 的迭代器：采样泵稳态零分配
        private static bool _movedOffHandheld;
        internal static void FollowSupportedPlayers(Switch device)
        {
            bool handheld = device.Hid.Npads.IsSupportedPlayer(PlayerIndex.Handheld), player1 = device.Hid.Npads.IsSupportedPlayer(PlayerIndex.Player1);
            if (_player == PlayerIndex.Handheld && !handheld && player1)
            {
                _movedOffHandheld = true;
                Console.Error.WriteLine("S2A 虚拟手柄：游戏只收 Player1、不收掌机格，改到 Player1 的 Pro 手柄");
                SetPrimary(device, PlayerIndex.Player1, ControllerType.ProController);
            }
            else if (_movedOffHandheld && handheld && _player == PlayerIndex.Player1 && _pads == 1 && !_externalController && !Host.Docked)
            {
                _movedOffHandheld = false;
                Console.Error.WriteLine("S2A 虚拟手柄：游戏又收掌机格，挪回掌机格");
                SetPrimary(device, PlayerIndex.Handheld, ControllerType.Handheld);
            }
        }

        // 游戏声明的样式不收主手柄现在的样式时换一个它收的（#359：开局「用你要用的手柄按 A」那一屏只收 掌机 / 单只 Joy-Con / 精灵球手柄，
        //   主机档下虚拟手柄是 Player1 的 Pro 手柄、接了外接手柄也会改成 Pro 手柄；Ryujinx 的 Remap 只会 Pro ↔ 双 Joy-Con 互换，其余直接断开，按什么都没反应）。
        //   挑的顺序：掌机格（不在主机档、游戏收掌机格、只有一个手柄）→ 双 Joy-Con → Pro → 单只右 → 单只左（单只按横握换键，RotateSideways）；
        //   游戏又收回原来的样式就换回去。跟 FollowSupportedPlayers 同一个 250 ms 节拍，只读游戏的声明、不改它
        private static ControllerType _styleBefore = ControllerType.None;
        private static PlayerIndex _playerBefore;
        private static bool Accepts(Switch device, ControllerType styles, ControllerType type) =>
            type == ControllerType.Handheld ? (styles & type) != 0 && !device.System.State.DockedMode
            : (styles & type) != 0 || (type == ControllerType.ProController && (styles & ControllerType.JoyconPair) != 0)
                                   || (type == ControllerType.JoyconPair && (styles & ControllerType.ProController) != 0);   // 这一对 Remap 自己会换
        internal static void FollowSupportedStyles(Switch device)
        {
            ControllerType styles = device.Hid.Npads.SupportedStyleSets;
            if (styles == ControllerType.None) return;
            if (_styleBefore != ControllerType.None && _type != _styleBefore && Accepts(device, styles, _styleBefore))
            {
                Console.Error.WriteLine($"S2A 虚拟手柄：游戏又收 {_styleBefore}，换回去");
                ControllerType back = _styleBefore; _styleBefore = ControllerType.None;
                SetPrimary(device, _playerBefore, back);
                return;
            }
            if (Accepts(device, styles, _type)) return;
            var npads = device.Hid.Npads;
            (PlayerIndex player, ControllerType type) pick =
                _pads == 1 && Accepts(device, styles, ControllerType.Handheld) && npads.IsSupportedPlayer(PlayerIndex.Handheld) ? (PlayerIndex.Handheld, ControllerType.Handheld)
                : (styles & ControllerType.JoyconPair) != 0 ? (PlayerIndex.Player1, ControllerType.JoyconPair)
                : (styles & ControllerType.ProController) != 0 ? (PlayerIndex.Player1, ControllerType.ProController)
                // 双人横握：收 Left+Right 时先配成 Right，SetPrimary 再拆成 P1=右 / P2=左（勿两边同款，另一只六轴会被盖掉）
                : _pads > 1 && (styles & ControllerType.JoyconLeft) != 0 && (styles & ControllerType.JoyconRight) != 0 ? (PlayerIndex.Player1, ControllerType.JoyconRight)
                : (styles & ControllerType.JoyconRight) != 0 ? (PlayerIndex.Player1, ControllerType.JoyconRight)
                : (styles & ControllerType.JoyconLeft) != 0 ? (PlayerIndex.Player1, ControllerType.JoyconLeft)
                : (PlayerIndex.Unknown, ControllerType.None);
            if (pick.type == ControllerType.None) return;   // 只收精灵球之类的：没有能扮的，不动
            if (_styleBefore == ControllerType.None) { _styleBefore = _type; _playerBefore = _player; }
            Console.Error.WriteLine($"S2A 虚拟手柄：游戏只收 {styles}，不收 {_type}，改成 {pick.player} 的 {pick.type}");
            SetPrimary(device, pick.player, pick.type);
        }

        // 开到 n 个虚拟手柄（最多 2，只增不减；收局 Stop 回到 S2A_AP_PADS 给的个数），按当前主手柄重配
        public static void SetPads(Switch device, int n)
        {
            if (n > 2) Red.Report($"游戏要 {n} 个手柄，虚拟手柄最多 2 个");
            n = Math.Min(n, 2);
            if (n <= _pads) return;
            _pads = n;
            Console.Error.WriteLine($"S2A 虚拟手柄：开到 {n} 个（有第二只真手柄则独立输入，否则第二槽镜像第一槽）");
            SetPrimary(device, _player, _type);
        }

        // 虚拟手柄改配到 player / type；之后的输入都喂这一格。双手柄时第二格取下一个手柄号：
        //   游戏收 JoyconLeft+JoyconRight（派对横握双人）→ P1=右柄、P2=左柄（与 Mac HID：槽0=右 / 槽1=左 一致）；否则两格同样式。
        //   掌机格只有一个：两人玩时主手柄离开掌机格改成 Player1 的 Pro 手柄；Pro / 双 Joy-Con 不符时 Remap 自换。
        public static void SetPrimary(Switch device, PlayerIndex player, ControllerType type)
        {
            if (_pads > 1 && (type == ControllerType.Handheld || player == PlayerIndex.Handheld))
            {
                (player, type) = (PlayerIndex.Player1, ControllerType.ProController);
            }
            lock (device.Hid.Npads.RumbleSyncRoot)
            {
                PlayerIndex second = _pads > 1 ? (player == PlayerIndex.Player8 ? PlayerIndex.Player1 : player + 1) : PlayerIndex.Unknown;
                ControllerType type1 = type, type2 = type;
                if (second != PlayerIndex.Unknown)
                {
                    ControllerType styles = device.Hid.Npads.SupportedStyleSets;
                    if ((styles & ControllerType.JoyconLeft) != 0 && (styles & ControllerType.JoyconRight) != 0
                        && (type == ControllerType.JoyconLeft || type == ControllerType.JoyconRight))
                    {
                        type1 = ControllerType.JoyconRight;
                        type2 = ControllerType.JoyconLeft;
                    }
                    device.Hid.Npads.Configure(new ControllerConfig { Player = player, Type = type1 }, new ControllerConfig { Player = second, Type = type2 });
                    type = type1;
                    if (type1 != type2)
                        Console.Error.WriteLine($"S2A 虚拟手柄：双人横握拆开 {player}={type1} + {second}={type2}");
                }
                else
                    device.Hid.Npads.Configure(new ControllerConfig { Player = player, Type = type });
                _device = device;
                _player = type == ControllerType.Handheld ? PlayerIndex.Handheld : player;
                _type = type;
                _second = second;
                _feedback?.SetPlayer(_player);
                Interlocked.Increment(ref _configurationGeneration);
            }

            if (_thread != null)
            {
                if (_padWake != null) _padWake();
                return;
            }

            // 自动玩家在宿主里是弱链接：运行时查符号，没链就不并
            if (AutoplayKeys1 == null && NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_autoplay_keys", out nint p))   // 平台例外：自动玩家只在开发宿主里弱链接、生产包没有这个导出，进不了 Native.Imports 的 DllImport
            {
                AutoplayKeys1 = (delegate* unmanaged<uint>)p;
            }
            if (AutoplayKeys2 == null && NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_autoplay_keys2", out nint p2))   // 平台例外：自动玩家只在开发宿主里弱链接、生产包没有这个导出，进不了 Native.Imports 的 DllImport
            {
                AutoplayKeys2 = (delegate* unmanaged<uint>)p2;
            }
            if (AutoplayPads == null && NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_autoplay_pads", out nint pn))   // 平台例外：自动玩家只在开发宿主里弱链接、生产包没有这个导出，进不了 Native.Imports 的 DllImport
            {
                AutoplayPads = (delegate* unmanaged<int>)pn;
            }

            // 回放录手柄的摇杆模拟量（tests/autoplay：正式局 MARK 后回放 维护者 录的按键）；录手柄的存档标记（ios/vpad.m，iOS 才有）：游戏存档提交时记一行
            if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_autoplay_sticks", out nint sp))
            {
                _autoplaySticks = (delegate* unmanaged<int*, int>)sp;
            }
            if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_autoplay_touch", out nint tp))
            {
                _autoplayTouch = (delegate* unmanaged<int*, uint*, int>)tp;
            }

            if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_padrec_mark", out nint pm))
            {
                _padrecMark = (delegate* unmanaged<byte*>)pm;
            }

            if (_padrecMark != null)
            {
                Ryujinx.HLE.S2AHooks.SaveCommitted = &SaveCommitted;
            }

            // 主 App 的纯 C 查询不加载可选 BLE 模块；只有真实 READY 会话才创建反馈对象。
            if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_pad_rumble_session", out nint session))
                _rumbleSession = (delegate* unmanaged<ulong>)session;
            // Mac 宿主只导出六轴、没有震动会话：反馈对象照建，只走六轴
            else _motionOnly = ControllerFeedback.MotionExport(out _);

            // iOS 壳 / Mac 游戏窗口的触屏虚拟手柄（ios/vpad.m、macos/front_mac.m）：按符号查接到 InputHook
            if (InputHook == null && NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_vpad_read", out nint vp))
            {
                _vpadRead = (delegate* unmanaged<int*, uint>)vp;
                InputHook = _vpadHook = &VPad;
                if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_vpad_read2", out nint vp2))
                    _vpadRead2 = (delegate* unmanaged<int*, uint>)vp2;
                if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_vpad_pads", out nint vpn))
                    _vpadPads = (delegate* unmanaged<int>)vpn;
                // 触屏直通：iOS 壳（ios/vpad.m，仅触屏方案的手指）与 Mac 游戏窗口（macos/front_mac.m，鼠标左键点画面）导出 s2a_vpad_read_touch；没导出的宿主保持为空、不碰触摸屏。
                if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_vpad_read_touch", out nint vtouch))
                    _vpadTouch = (delegate* unmanaged<int*, uint*, int>)vtouch;
                // 审计 P1-3：游戏启用触屏时告诉 iOS 壳（按键方案下提示一次怎么切「仅触屏操作」）；Mac 宿主没有这个导出
                bool touchWanted = NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_vpad_touch_wanted", out nint vwanted);   // 平台例外：iOS 壳（ios/vpad.m）专有导出，同上面 s2a_vpad_read_touch，Mac / 安卓宿主没有，进不了 Native.Imports 的 DllImport
                if (touchWanted) VPadTouchWanted = (delegate* unmanaged<int>)vwanted;
                // 游戏声明触屏配置时告诉宿主前端：iOS 壳自动切仅触屏（ios/touch_config.m），Mac 游戏窗口在缺省键位下把左键让给触屏（front_mac.m）；平台例外同上，安卓宿主没有这个导出
                if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_vpad_touch_configured", out nint vconfigured))   // 平台例外：宿主前端（iOS 壳 touch_config.m / Mac 游戏窗口 front_mac.m）专有导出，同 s2a_vpad_touch_wanted / s2a_vpad_read_touch，安卓与无窗口宿主没有，进不了 Native.Imports 的 DllImport
                    VPadTouchConfigured = (delegate* unmanaged<int, int>)vconfigured;
                if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_vpad_read_ex", out nint extended))
                {
                    nint program = NativeLibrary.GetMainProgramHandle();
                    _padReadEx = (delegate* unmanaged<PadSnapshot*, void>)extended;
                    _padWait = (delegate* unmanaged<ulong, ulong, int>)NativeLibrary.GetExport(program, "s2a_pad_wait");
                    _padWake = (delegate* unmanaged<void>)NativeLibrary.GetExport(program, "s2a_pad_wake");
                    _padNow = (delegate* unmanaged<ulong>)NativeLibrary.GetExport(program, "s2a_pad_now_us");
                    _padCommit = (delegate* unmanaged<PadSnapshot*, void>)NativeLibrary.GetExport(program, "s2a_pad_record_commit");
                    _padLatency = (delegate* unmanaged<HostInputLatency*, int, void>)NativeLibrary.GetExport(program, "s2a_pad_get_latency");
                }
            }

            _stop = false;
            _thread = new Thread(() => Loop(device)) { Name = "S2A.HID", IsBackground = true };
            _thread.Start();
        }

        public static void Stop()
        {
            if (_thread == Thread.CurrentThread)
                throw new InvalidOperationException("不能在 HID 采样线程上拆除服务会话");
            _stop = true;
            if (_padWake != null) _padWake();
            _thread?.Join();
            if (_device != null) lock (_device.Hid.Npads.RumbleSyncRoot)
            {
                _feedback?.Stop();
                _feedback = null;
            }
            _thread = null;
            _device = null;
            _externalController = false;
            _configurationGeneration = 0;
            _player = PlayerIndex.Handheld;
            _type = ControllerType.Handheld;
            _pads = EnvPads;
            _second = PlayerIndex.Unknown;
            _lastSticks = default;
            _movedOffHandheld = false;   // 审计 P1-94：上一局「挪出掌机格」不带进下一局（同进程重启）
            _styleBefore = ControllerType.None;   // 同上：上一局「按样式换过」不带进下一局
        }

        private static delegate* unmanaged<int*, uint> _vpadRead;
        private static delegate* unmanaged<int*, uint> _vpadRead2;   // Mac 第二只真手柄；没有导出则第二槽走镜像
        private static delegate* unmanaged<int> _vpadPads;
        private static delegate*<ref GamepadInput, void> _vpadHook;
        private static delegate* unmanaged<int*, int> _autoplaySticks;
        private static delegate* unmanaged<byte*> _padrecMark;
        private static Switch _device;
        private static ControllerFeedback _feedback;
        private static delegate* unmanaged<ulong> _rumbleSession;
        private static bool _motionOnly;
        private static delegate* unmanaged<PadSnapshot*, void> _padReadEx;
        private static delegate* unmanaged<ulong, ulong, int> _padWait;
        private static delegate* unmanaged<void> _padWake;
        private static delegate* unmanaged<ulong> _padNow;
        private static delegate* unmanaged<PadSnapshot*, void> _padCommit;
        private static delegate* unmanaged<HostInputLatency*, int, void> _padLatency;
        // iOS 壳的「触屏直通」方案：ios/vpad.m 把手指原样写成 Switch 触点，这里每帧问一次喂 Hid.Touchscreen（Mac 游戏窗口的鼠标左键点画面同一个导出，front_mac.m）。
        // 虚拟按键方案（含默认布局）不导出触点，这里恒为 0 个——按 A / 推摇杆不会被游戏当成点按。
        private static delegate* unmanaged<int*, uint*, int> _vpadTouch;
        // 审计 P1-3：iOS 壳的 s2a_vpad_touch_wanted。游戏启用了触屏（ActivateTouchScreen → Hid.Touchscreen.Active）后每次 HID 提交问一次：
        //   壳返回 0 = 还没出首帧（加载页挡着），下次再问；返回 1 = 收下了，清空、之后不再问。只在 HID 线程上读写
        internal static delegate* unmanaged<int> VPadTouchWanted;
        internal static void OfferTouchWanted(bool active)
        {
            if (VPadTouchWanted != null && active && VPadTouchWanted() != 0) VPadTouchWanted = null;
        }
        // 11-04 维护者定：宿主前端的 s2a_vpad_touch_configured（iOS ios/touch_config.m、Mac macos/front_mac.m）。游戏调了 SetTouchScreenConfiguration
        //   （Ryujinx 补丁 hid-touch-config-mode 记进 Hid.Touchscreen.ConfiguredMode，-1 = 没调过）后每次 HID 提交递一次模式：
        //   壳返回 0 = 还没出首帧，下次再递；返回 1 = 收下了（壳自动切仅触屏，玩家手动选过的不切），清空、之后不再递。只在 HID 线程上读写
        internal static delegate* unmanaged<int, int> VPadTouchConfigured;
        internal static void OfferTouchConfigured(int mode)
        {
            if (VPadTouchConfigured != null && mode >= 0 && VPadTouchConfigured(mode) != 0) VPadTouchConfigured = null;
        }
        // 自动玩家的点触（tests/autoplay：路线 / 实时通道 TOUCH:x,y 步，指针 / 点触类页面用）：签名同 _vpadTouch，Mac / iOS 都按符号查，并在真触点之后
        private static delegate* unmanaged<int*, uint*, int> _autoplayTouch;

        [StructLayout(LayoutKind.Sequential)]
        private struct PadSnapshot
        {
            public ulong NotificationSeq, InputEpoch, HostTimestampUs, ReadTimestampUs;
            public uint Buttons, Source;
            public int LeftX, LeftY, RightX, RightY;
        }

        // 只测宿主输入快照 / 读取至 HID 提交，不包含蓝牙传输、游戏采样或显示延迟。
        [StructLayout(LayoutKind.Sequential)]
        public struct HostInputLatency
        {
            public ulong Samples, HostTotalUs, ReadTotalUs, HostMaxUs, ReadMaxUs;
        }

        public static HostInputLatency ReadHostInputLatency(bool reset = false)
        {
            HostInputLatency result = default;
            if (_padLatency != null) _padLatency(&result, reset ? 1 : 0);
            return result;
        }

        private static void RefreshFeedback(Switch device)
        {
            if (_rumbleSession == null)
            {
                if (_motionOnly && _feedback == null) _feedback = new ControllerFeedback(device, _player);
                return;
            }
            // 与改配、逐请求反馈共用 Npad 锁。会话代次由现有对象在每个请求前复核，
            // 不因 READY 到 READY 的代次切换重建对象、清掉刚接受的新帧。
            lock (device.Hid.Npads.RumbleSyncRoot)
            {
                if (_rumbleSession() == 0)
                {
                    _feedback?.Stop();
                    _feedback = null;
                }
                else if (_feedback == null)
                    _feedback = new ControllerFeedback(device, _player);
            }
        }

        // 存档提交（FS 服务线程，游戏的 Commit 返回前）：录制方记一个存档点并给出副本目录，这里把当时的存档整份拷进去（回放局按它带存档起局）
        private static void SaveCommitted()
        {
            if (_padrecMark == null) return;

            byte* dir = _padrecMark();

            if (dir != null && _device != null)
            {
                Saves.Snapshot(_device, Application.ProgramId, Marshal.PtrToStringUTF8((nint)dir));
            }
        }

        // 触屏虚拟手柄 → 手柄状态：按键位同 HidNpadButton；摇杆非零才覆盖（与自动玩家的键按位或并存）
        private static void VPad(ref GamepadInput input)
        {
            int* s = stackalloc int[4];
            input.Buttons |= (ControllerKeys)_vpadRead(s);
            if (s[0] != 0 || s[1] != 0) { input.LStick.Dx = s[0]; input.LStick.Dy = s[1]; }
            if (s[2] != 0 || s[3] != 0) { input.RStick.Dx = s[2]; input.RStick.Dy = s[3]; }
        }

        private static void VPad2(ref GamepadInput input)
        {
            if (_vpadRead2 == null) return;
            int* s = stackalloc int[4];
            input.Buttons |= (ControllerKeys)_vpadRead2(s);
            if (s[0] != 0 || s[1] != 0) { input.LStick.Dx = s[0]; input.LStick.Dy = s[1]; }
            if (s[2] != 0 || s[3] != 0) { input.RStick.Dx = s[2]; input.RStick.Dy = s[3]; }
        }

        // 左右 Joy-Con 合成一对 Pro：按键并上；P1=右柄摇杆在 RX/RY、P2=左柄在 LX/LY → Pro 左右摇杆各归其位
        private static void MergePhysicalPair(ref GamepadInput input)
        {
            if (_vpadRead2 == null) return;
            int* s = stackalloc int[4];
            input.Buttons |= (ControllerKeys)_vpadRead2(s);
            bool hasL = s[0] != 0 || s[1] != 0, hasR = s[2] != 0 || s[3] != 0;
            // 二号（左 Joy-Con）补 Pro 左摇杆；一号（右 Joy-Con）已在 input.RStick
            if (hasL && input.LStick.Dx == 0 && input.LStick.Dy == 0)
            { input.LStick.Dx = s[0]; input.LStick.Dy = s[1]; }
            if (hasR && input.RStick.Dx == 0 && input.RStick.Dy == 0)
            { input.RStick.Dx = s[2]; input.RStick.Dy = s[3]; }
            // 兼容旧 HID：右柄曾把摇杆写在 LX/LY
            else if (!hasR && hasL && input.RStick.Dx == 0 && input.RStick.Dy == 0
                     && (input.LStick.Dx != 0 || input.LStick.Dy != 0))
            { /* 一号已占左摇杆 = 右柄旧映射，二号左柄再补右摇杆 */ input.RStick.Dx = s[0]; input.RStick.Dy = s[1]; }
        }

        // 触屏直通 → 触摸屏共享内存。每次 HID 提交都写一遍（没有触点也要写一条空状态，跟桌面版鼠标路径一致），
        // 否则游戏只能读到开机时 IHidServer 初始化出来的那几条空状态，自带触屏 UI 永远是死的。
        // 触点坐标已由 native 侧换算到「游戏这一帧真实出图的尺寸」×720（未加宽 / 出图 1280 时就是 1280×720，
        // 加宽出图 1564 宽时就是 1564×720，见 vpad.m 的 switchPoint + nxgal_present_frame）。
        // 游戏把触点归一化用的分母就是它自己的渲染尺寸，所以这个空间不能靠「显示宽是多少」去推。
        // 自动玩家的点触接在真触点之后（无窗口的 Mac 普查局只有它）；每次点下（属性带 Start）从共享内存回读当前一条打一行，两头对（触点进了游戏读的那块）
        // 这里原样写共享内存、不裁剪；上限 16 个手指（触摸屏共享内存 Array16 的容量）。
        private static void PushTouch(Switch device)
        {
            OfferTouchConfigured(device.Hid.Touchscreen.ConfiguredMode);
            OfferTouchWanted(device.Hid.Touchscreen.Active);
            if (_vpadTouch == null && _autoplayTouch == null) return;
            const int MaxTouches = 16;
            int* xy = stackalloc int[MaxTouches * 2];
            uint* attr = stackalloc uint[MaxTouches];
            int count = _vpadTouch != null ? Math.Min(_vpadTouch(xy, attr), MaxTouches) : 0;
            int ap = count < MaxTouches && _autoplayTouch != null ? _autoplayTouch(xy + 2 * count, attr + count) : 0;
            count += ap;
            Span<TouchPoint> points = stackalloc TouchPoint[MaxTouches];
            for (int i = 0; i < count; i++)
            {
                points[i] = new TouchPoint
                {
                    Attribute = (TouchAttribute)attr[i],
                    X = (uint)xy[2 * i], Y = (uint)xy[2 * i + 1],
                    DiameterX = 10, DiameterY = 10, Angle = 90,   // 与 Ryujinx 鼠标路径的占位值一致
                };
            }
            device.Hid.Touchscreen.Update(points[..count]);
            if (ap != 0 && (attr[count - 1] & (uint)TouchAttribute.Start) != 0)
            {
                ref TouchScreenState cur = ref device.Hid.SharedMemory.TouchScreen.GetCurrentEntryRef();
                TouchState t0 = cur.TouchesCount > 0 ? cur.Touches[(int)cur.TouchesCount - 1] : default;
                Console.Error.WriteLine($"HID：自动玩家点触 ({xy[2 * (count - 1)]}, {xy[2 * (count - 1) + 1]}) → 触摸屏共享内存：触点 {cur.TouchesCount} 个，最后一个 ({t0.X}, {t0.Y}) 属性 {t0.Attribute}，采样号 {cur.SamplingNumber}");
            }
        }

        // 自动玩家键 → 手柄状态：位 0–15 是按键，16–23 是左右摇杆四向伪键，换成满偏摇杆（按键位同时保留，Ryujinx 同序）
        public static void Merge(ref GamepadInput input, uint keys)
        {
            const int Full = short.MaxValue;
            input.Buttons |= (ControllerKeys)keys;

            if ((keys & (1u << 16)) != 0) input.LStick.Dx = -Full;
            if ((keys & (1u << 18)) != 0) input.LStick.Dx = Full;
            if ((keys & (1u << 17)) != 0) input.LStick.Dy = Full;
            if ((keys & (1u << 19)) != 0) input.LStick.Dy = -Full;
            if ((keys & (1u << 20)) != 0) input.RStick.Dx = -Full;
            if ((keys & (1u << 22)) != 0) input.RStick.Dx = Full;
            if ((keys & (1u << 21)) != 0) input.RStick.Dy = Full;
            if ((keys & (1u << 23)) != 0) input.RStick.Dy = -Full;
        }

        // 单只 Joy-Con 横握（11-03 归族 E：Super Mario Party 手柄设置小程序只收单只、游戏 SetNpadJoyHoldType 横握）：HID 报的是这只的物理键，
        //   游戏按横握自己转方向——右只横握（导轨朝上 = 顺时针转 90°）时屏幕右边的「确认」是物理 X、下边是物理 A；左只（逆时针 90°）时 ABXY 是十字键那四个。
        //   触屏手柄与自动玩家给的 ABXY / 摇杆都是「横握后看到的位置」，这里换成物理键 / 物理摇杆方向，人和自动玩家按 A 都是确认
        // 自动玩家的键 / 摇杆并进这一帧的输入，再按横握换成物理键（审计 P1-94）：触屏手柄与自动玩家给的是「横握后看到的位置」，要转；
        //   外接实体手柄（iOS 事件快照来源 1 / 2：BLE / 系统手柄）报的本来就是物理键，原先整份一起转，实体手柄横握时 A 变成 X、摇杆转 90°。
        //   physical = 人手这份来自实体手柄：只转自动玩家那份再并进来（键位或上、它给了的摇杆覆盖）
        internal static void ComposeAutoplay(ref GamepadInput input, bool physical, uint keys, bool sticks, int lx, int ly, int rx, int ry,
                                             ControllerType type, Ryujinx.HLE.HOS.Services.Hid.Types.NpadJoyHoldType hold)
        {
            if (!physical)
            {
                Merge(ref input, keys);
                if (sticks) { input.LStick.Dx = lx; input.LStick.Dy = ly; input.RStick.Dx = rx; input.RStick.Dy = ry; }
                RotateSideways(ref input, type, hold);
                return;
            }
            GamepadInput ap = new() { PlayerId = input.PlayerId };
            Merge(ref ap, keys);
            if (sticks) { ap.LStick.Dx = lx; ap.LStick.Dy = ly; ap.RStick.Dx = rx; ap.RStick.Dy = ry; }
            RotateSideways(ref ap, type, hold);
            input.Buttons |= ap.Buttons;
            if (sticks || (keys & 0xFu << 16) != 0) input.LStick = ap.LStick;
            if (sticks || (keys & 0xFu << 20) != 0) input.RStick = ap.RStick;
        }

        internal static void RotateSideways(ref GamepadInput input, ControllerType type, Ryujinx.HLE.HOS.Services.Hid.Types.NpadJoyHoldType hold)
        {
            if (hold != Ryujinx.HLE.HOS.Services.Hid.Types.NpadJoyHoldType.Horizontal || (type != ControllerType.JoyconRight && type != ControllerType.JoyconLeft)) return;
            const ControllerKeys Face = ControllerKeys.A | ControllerKeys.B | ControllerKeys.X | ControllerKeys.Y;
            ControllerKeys b = input.Buttons, f = 0;
            bool right = type == ControllerType.JoyconRight;
            if ((b & ControllerKeys.A) != 0) f |= right ? ControllerKeys.X : ControllerKeys.DpadDown;
            if ((b & ControllerKeys.B) != 0) f |= right ? ControllerKeys.A : ControllerKeys.DpadLeft;
            if ((b & ControllerKeys.X) != 0) f |= right ? ControllerKeys.Y : ControllerKeys.DpadRight;
            if ((b & ControllerKeys.Y) != 0) f |= right ? ControllerKeys.B : ControllerKeys.DpadUp;
            input.Buttons = (b & ~Face) | f;
            // 横握后的摇杆方向 (x, y) → 物理：右只顺时针转了 90°，物理 = (−y, x)；左只逆时针，物理 = (y, −x)
            // JoyRight 真机摇杆在右摇杆槽（触屏/自动玩家仍可能写在左摇杆，这里迁过去再转）
            if (right)
            {
                if (input.RStick.Dx == 0 && input.RStick.Dy == 0 && (input.LStick.Dx != 0 || input.LStick.Dy != 0))
                {
                    input.RStick = input.LStick;
                    input.LStick = default;
                }
                var s = input.RStick; int x = s.Dx, y = s.Dy;
                (s.Dx, s.Dy) = (-y, x);
                input.RStick = s;
            }
            else
            {
                var s = input.LStick; int x = s.Dx, y = s.Dy;
                (s.Dx, s.Dy) = (y, -x);
                input.LStick = s;
            }
        }

        // 单只 Joy-Con：摇杆方向键位同时置十字键，只读 D-pad 的菜单（派对暂停等）才能跟摇杆走
        private static void StickDirsToDpad(ref GamepadInput input)
        {
            ControllerKeys b = input.Buttons;
            if ((b & (ControllerKeys.LStickLeft | ControllerKeys.RStickLeft)) != 0) b |= ControllerKeys.DpadLeft;
            if ((b & (ControllerKeys.LStickRight | ControllerKeys.RStickRight)) != 0) b |= ControllerKeys.DpadRight;
            if ((b & (ControllerKeys.LStickUp | ControllerKeys.RStickUp)) != 0) b |= ControllerKeys.DpadUp;
            if ((b & (ControllerKeys.LStickDown | ControllerKeys.RStickDown)) != 0) b |= ControllerKeys.DpadDown;
            input.Buttons = b;
        }

        // 右柄摇杆在 R、左柄在 L；Pro/菜单常读左摇杆 → 单只时镜像到另一边
        private static void MirrorSoloStick(ref GamepadInput input, bool rightJoy)
        {
            if (rightJoy)
            {
                if (input.LStick.Dx == 0 && input.LStick.Dy == 0 && (input.RStick.Dx != 0 || input.RStick.Dy != 0))
                    input.LStick = input.RStick;
            }
            else if (input.RStick.Dx == 0 && input.RStick.Dy == 0 && (input.LStick.Dx != 0 || input.LStick.Dy != 0))
                input.RStick = input.LStick;
        }

        // 派对横握：右柄屏上确认=物理 X→A（HoldType=Horizontal 时游戏未必自转，必须始终映射）；左柄十字→ABXY。
        // 摇杆：HID 已是竖握坐标且 Y 已取反；横握再转 90° 时输出 Y 相对 RotateSideways 再翻一次，否则上下反。
        private static void AdaptSidewaysJoy(ref GamepadInput input, ControllerType joySide,
            Ryujinx.HLE.HOS.Services.Hid.Types.NpadJoyHoldType hold)
        {
            MirrorSoloStick(ref input, joySide == ControllerType.JoyconRight);
            const ControllerKeys Face = ControllerKeys.A | ControllerKeys.B | ControllerKeys.X | ControllerKeys.Y;
            const ControllerKeys Dpad = ControllerKeys.DpadLeft | ControllerKeys.DpadUp | ControllerKeys.DpadRight | ControllerKeys.DpadDown;
            ControllerKeys b = input.Buttons, f = 0;
            bool right = joySide == ControllerType.JoyconRight;
            bool horizontal = hold == Ryujinx.HLE.HOS.Services.Hid.Types.NpadJoyHoldType.Horizontal;
            if (right)
            {
                // 物理 → 屏上（右只横握）：X→A、A→B、Y→X、B→Y（单人小游戏确认键）
                if ((b & ControllerKeys.X) != 0) f |= ControllerKeys.A;
                if ((b & ControllerKeys.A) != 0) f |= ControllerKeys.B;
                if ((b & ControllerKeys.Y) != 0) f |= ControllerKeys.X;
                if ((b & ControllerKeys.B) != 0) f |= ControllerKeys.Y;
                input.Buttons = (b & ~Face) | f;
                var s = input.RStick.Dx != 0 || input.RStick.Dy != 0 ? input.RStick : input.LStick;
                int x = s.Dx, y = s.Dy;
                // Horizontal：(-y,-x) = RotateSideways 右只再翻 Y；Vertical 强转 (y,-x)
                (s.Dx, s.Dy) = horizontal ? (-y, -x) : (y, -x);
                input.RStick = s; input.LStick = s;
            }
            else
            {
                // 左只：十字键映射为 ABXY（下=A）。无面键时仍要转摇杆，否则只推摇杆时左右反着。
                if ((b & (Dpad | Face)) != 0)
                {
                    if ((b & ControllerKeys.DpadDown) != 0 || (b & ControllerKeys.A) != 0) f |= ControllerKeys.A;
                    if ((b & ControllerKeys.DpadLeft) != 0 || (b & ControllerKeys.B) != 0) f |= ControllerKeys.B;
                    if ((b & ControllerKeys.DpadRight) != 0 || (b & ControllerKeys.X) != 0) f |= ControllerKeys.X;
                    if ((b & ControllerKeys.DpadUp) != 0 || (b & ControllerKeys.Y) != 0) f |= ControllerKeys.Y;
                    input.Buttons = (b & ~(Dpad | Face)) | f;
                }
                var s = input.LStick; int x = s.Dx, y = s.Dy;
                // Horizontal：(y,x) = RotateSideways 左只再翻 Y；Vertical 强转 (-y,x)
                (s.Dx, s.Dy) = horizontal ? (y, x) : (-y, x);
                input.LStick = s; input.RStick = s;
            }
        }

        // 摇杆诊断（S2A_TRACE_STICKS=1）：给入的摇杆一变就打一行，并从共享内存（游戏读的就是这块）回读当前样式与掌机 / 全键两路最新一条，两头对一下。
        // 缺省关：真玩时摇杆几乎每帧都变，每次一行长日志（分配 + 控制台写）
        private static readonly bool TraceSticksOn = Environment.GetEnvironmentVariable("S2A_TRACE_STICKS") == "1";
        // 按键诊断：S2A_TRACE_BUTTONS=1 时按键变化打一行
        private static readonly bool TraceButtonsOn = Environment.GetEnvironmentVariable("S2A_TRACE_BUTTONS") == "1";
        private static (int, int, int, int) _lastSticks;
        private static ControllerKeys _lastButtons;

        private static void TraceSticks(Switch device, in GamepadInput input)
        {
            (int, int, int, int) now = (input.LStick.Dx, input.LStick.Dy, input.RStick.Dx, input.RStick.Dy);

            if (now == _lastSticks)
            {
                return;
            }

            _lastSticks = now;
            ref var npad = ref device.Hid.SharedMemory.Npads[(int)input.PlayerId].InternalState;
            ref var hh = ref npad.Handheld.GetCurrentEntryRef();
            ref var fk = ref npad.FullKey.GetCurrentEntryRef();
            Console.Error.WriteLine($"HID：给入 左摇杆 Dx={input.LStick.Dx} Dy={input.LStick.Dy} 右摇杆 Dx={input.RStick.Dx} Dy={input.RStick.Dy}；" +
                $"共享内存回读 样式 {npad.StyleSet}、支持样式 {device.Hid.Npads.SupportedStyleSets}、" +
                $"掌机 #{hh.SamplingNumber} 左 ({hh.AnalogStickL.X},{hh.AnalogStickL.Y}) 右 ({hh.AnalogStickR.X},{hh.AnalogStickR.Y}) 属性 {hh.Attributes}、" +
                $"全键 #{fk.SamplingNumber} 左 ({fk.AnalogStickL.X},{fk.AnalogStickL.Y})");
        }

        // 只保存按键的 HID 可见窗；摇杆不经过这里。Commit 后才开始计时。
        private sealed class ButtonVisibility
        {
            private readonly ulong[] _until = new ulong[16];
            private uint _submitted, _next, _newlyPressed;
            private ulong _epoch;
            private int _configuration;

            public uint Apply(uint buttons, ulong epoch, int configuration, ulong now)
            {
                if (_epoch != epoch || _configuration != configuration)
                {
                    Array.Clear(_until);
                    _submitted = 0;
                    _epoch = epoch;
                    _configuration = configuration;
                }
                _newlyPressed = buttons & ~_submitted;
                _next = buttons;
                for (int bit = 0; bit < _until.Length; bit++)
                {
                    uint mask = 1u << bit;
                    if ((_submitted & mask) != 0 && now < _until[bit]) _next |= mask;
                }
                return _next;
            }

            public void Commit(ulong submittedAt)
            {
                for (int bit = 0; bit < _until.Length; bit++)
                {
                    if ((_newlyPressed & (1u << bit)) != 0) _until[bit] = submittedAt + 20_000;
                }
                _submitted = _next;
            }

            public ulong Deadline(uint physicalButtons, ulong now, ulong heartbeat)
            {
                ulong deadline = heartbeat;
                for (int bit = 0; bit < _until.Length; bit++)
                {
                    if ((_submitted & ~physicalButtons & (1u << bit)) != 0 &&
                        _until[bit] < deadline) deadline = Math.Max(_until[bit], now);
                }
                return deadline;
            }
        }

        private static void Loop(Switch device)
        {
            List<GamepadInput> states = new(2) { default };
            // 每键在第一次 HID 提交后保持 20 ms，让正常 60 Hz 轮询能看到短按。
            // 同键快速连点仍可能合并；不承诺卡帧或低频采样游戏一定读到。
            ButtonVisibility visibility = new();
            ulong nextHeartbeat = 0;
            PadSnapshot uncommitted = default;
            int configuration = Volatile.Read(ref _configurationGeneration);
            int* st = stackalloc int[4];
            long nextFollow = 0;

            while (!_stop)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("输入");
                Lifecycle.Tick(Host.Device?.System);   // 焦点 / 底座变化转给游戏（接口 v2.15）
                if (AutoplayPads != null && AutoplayPads() > _pads) SetPads(device, AutoplayPads());   // 先改配再取主手柄号：两人时主手柄离开掌机格
                // 不因「连着两只真手柄」就提前 SetPads(2)：标题屏 / 单人菜单要同一玩家的 L+R（左右 Joy-Con 合成一对）；一组双人靠启动设置 S2A_AP_PADS=2 预开
                if (Environment.TickCount64 >= nextFollow) { FollowSupportedPlayers(device); FollowSupportedStyles(device); nextFollow = Environment.TickCount64 + 250; }

                GamepadInput input = new() { PlayerId = _player };
                PadSnapshot snapshot = default;
                bool eventInput = _padReadEx != null && (nint)InputHook == (nint)_vpadHook;
                bool heartbeat = true;
                uint hostButtons = 0;
                bool physicalSecond = _vpadRead2 != null && _vpadPads != null && _vpadPads() >= 2;

                if (eventInput)
                {
                    _padReadEx(&snapshot);
                    if (OperatingSystem.IsIOS() && !_externalController && snapshot.Source is 1 or 2)
                    {
                        // 只在首次真实 BLE / 系统手柄出现时改配；断线或后台的触屏快照不撤销偏好。
                        _externalController = true;
                        if (_player == PlayerIndex.Handheld)
                            SetPrimary(device, PlayerIndex.Player1, ControllerType.ProController);
                    }
                    input.PlayerId = _player;
                    if (snapshot.NotificationSeq != uncommitted.NotificationSeq || snapshot.HostTimestampUs != 0)
                        uncommitted = snapshot;
                    ulong now = _padNow();
                    configuration = Volatile.Read(ref _configurationGeneration);
                    hostButtons = visibility.Apply(snapshot.Buttons, snapshot.InputEpoch, configuration, now);
                    input.Buttons = (ControllerKeys)hostButtons;
                    input.LStick.Dx = snapshot.LeftX; input.LStick.Dy = snapshot.LeftY;
                    input.RStick.Dx = snapshot.RightX; input.RStick.Dy = snapshot.RightY;
                    heartbeat = now >= nextHeartbeat;
                    if (heartbeat)
                    {
                        // 固定时间轴；活动输入不能不断推迟反馈心跳。
                        nextHeartbeat = nextHeartbeat == 0 ? now + 16_000 :
                            nextHeartbeat + ((now - nextHeartbeat) / 16_000 + 1) * 16_000;
                    }
                }
                else if (InputHook != null)
                {
                    InputHook(ref input);
                }

                // 单人 + 一组两只真手柄：左右合成一对（左摇杆/键 ∪ 右摇杆/键），标题屏 L+R、菜单才有反应；两组手柄时不合并
                if (_pads == 1 && physicalSecond && EnvMergePair && (nint)InputHook == (nint)_vpadHook)
                    MergePhysicalPair(ref input);

                // 自动玩家接管了二号手柄（s2a_autoplay_pads ≥ 2）：二号只听自动玩家的「2:键」，自动玩家给一号的键不镜像过去
                //   （11-01 双人成行选角色）；Mac 两只真手柄且已开到 2 人时二号走 s2a_vpad_read2，不再镜像一号
                GamepadInput human = input;
                uint apKeys = AutoplayKeys1 != null ? AutoplayKeys1() : 0;
                bool apSticks = _autoplaySticks != null && _autoplaySticks(st) != 0;

                // 先选定真实外接手柄槽，再安装反馈 hook；游戏看到新样式时即可同步提交震动，
                // 首次 READY 时保留手柄自己的固件连接反馈。
                RefreshFeedback(device);
                // Mac VPad（GC / Joy-Con HID）与 iOS BLE 实体手柄一样报物理键：横握只转触屏/自动玩家，避免确认键被转两次
                bool physicalHuman = (eventInput && snapshot.Source is 1 or 2)
                    || ((nint)InputHook == (nint)_vpadHook && InputHook != null);
                // 摇杆四向按键位（StickL/R 左右上下，位 16–23）按摇杆位置每帧置，同 Ryujinx 输入层（NpadManager → Hid.UpdateStickButtons，半偏阈值）：
                //   真机 HID 也是这样报，只读这几个位的游戏（菜单、2D 移动）推模拟摇杆才有反应。触屏 / 外接手柄 / 摇杆探测都只给模拟量
                var hold = device.Hid.Npads.JoyHold;
                // 双人 Joy-Con HID：不论配置成 Joy* 还是 Pro，P1=右柄 / P2=左柄都按横握实体键适配（人数选择等仍 Vertical 时也能按 X 确认）
                bool dualJoyHid = physicalSecond && physicalHuman && (nint)InputHook == (nint)_vpadHook;
                if (dualJoyHid)
                    AdaptSidewaysJoy(ref input, ControllerType.JoyconRight, hold);
                else if (_type == ControllerType.JoyconRight || _type == ControllerType.JoyconLeft)
                    AdaptSidewaysJoy(ref input, _type, hold);
                ComposeAutoplay(ref input, physicalHuman, apKeys, apSticks, st[0], st[1], st[2], st[3], _type, hold);
                input.Buttons |= device.Hid.UpdateStickButtons(input.LStick, input.RStick);
                StickDirsToDpad(ref input);
                if (TraceButtonsOn && input.Buttons != _lastButtons)
                {
                    _lastButtons = input.Buttons;
                    Console.Error.WriteLine($"HID：P1 buttons={input.Buttons} type={_type} hold={hold} pads={_pads} L=({input.LStick.Dx},{input.LStick.Dy}) R=({input.RStick.Dx},{input.RStick.Dy})");
                }
                states[0] = input;
                PlayerIndex second = _second;
                if (second != PlayerIndex.Unknown)
                {
                    bool driverOwnsSecond = AutoplayPads != null && AutoplayPads() >= 2;
                    GamepadInput pad2;
                    ControllerType type2 = _type;
                    if (_pads > 1 && (_type == ControllerType.JoyconLeft || _type == ControllerType.JoyconRight))
                        type2 = _type == ControllerType.JoyconRight ? ControllerType.JoyconLeft : ControllerType.JoyconRight;
                    if (driverOwnsSecond)
                    {
                        pad2 = human;
                        pad2.PlayerId = second;
                        uint keys2 = AutoplayKeys2 != null ? AutoplayKeys2() : 0;
                        if (keys2 != 0)
                        {
                            Merge(ref pad2, keys2);
                            pad2.Buttons |= device.Hid.UpdateStickButtons(pad2.LStick, pad2.RStick);
                        }
                    }
                    else if (physicalSecond)
                    {
                        pad2 = new GamepadInput { PlayerId = second };
                        VPad2(ref pad2);
                        if (dualJoyHid)
                            AdaptSidewaysJoy(ref pad2, ControllerType.JoyconLeft, hold);
                        else if (type2 == ControllerType.JoyconLeft || type2 == ControllerType.JoyconRight)
                            AdaptSidewaysJoy(ref pad2, type2, hold);
                        pad2.Buttons |= device.Hid.UpdateStickButtons(pad2.LStick, pad2.RStick);
                        StickDirsToDpad(ref pad2);
                    }
                    else
                    {
                        pad2 = input;
                        pad2.PlayerId = second;
                        uint keys2 = AutoplayKeys2 != null ? AutoplayKeys2() : 0;
                        if (keys2 != 0)
                        {
                            Merge(ref pad2, keys2);
                            pad2.Buttons |= device.Hid.UpdateStickButtons(pad2.LStick, pad2.RStick);
                        }
                    }
                    if (states.Count < 2) states.Add(pad2); else states[1] = pad2;
                }
                else if (states.Count > 1) states.RemoveAt(1);
                // 系统键盘开着（TextInput）：玩家在打字，手柄 / 触屏手柄的输入不进游戏（确定键 A 误触会让游戏把半截名字当确定、摇杆误移光标）；
                //   按着的键在开框这一帧起按松开报，收框后照常
                if (TextInput.Open)
                    for (int i = 0; i < states.Count; i++) states[i] = new GamepadInput { PlayerId = states[i].PlayerId };
                device.Hid.Npads.Update(states);
                Cheats.SetKeys(states[0].Buttons);   // 金手指按键条件码看一号手柄（与 Ryujinx TamperMachine 同口径）
                // A platform hook owns the HID touch ring (Android stable IDs);
                // Apple uses the shared runtime/autoplay source when no hook is installed.
                if (TouchHook != null) TouchHook(device);
                else PushTouch(device);
                if (eventInput)
                {
                    visibility.Commit(_padNow());
                    // 早释放的统计等到真正提交释放；可见窗引入的等待不能被统计隐藏。
                    if (hostButtons == snapshot.Buttons && uncommitted.HostTimestampUs != 0)
                    {
                        _padCommit(&uncommitted);
                        uncommitted.HostTimestampUs = 0;
                    }
                }
                if (heartbeat) _feedback?.Update(input.PlayerId);
                else _feedback?.TickMotion(input.PlayerId);
                if (TraceSticksOn)
                {
                    TraceSticks(device, in input);
                }
                if (eventInput)
                {
                    ulong deadline = visibility.Deadline(snapshot.Buttons, _padNow(), nextHeartbeat);
                    // Stop/改配可能发生在本轮 read 后、wait 前，显式检查并由序号兜住此窗口。
                    if (!_stop && configuration == Volatile.Read(ref _configurationGeneration))
                        _padWait(snapshot.NotificationSeq, deadline);
                }
                else Thread.Sleep(16);
            }
        }
    }
}

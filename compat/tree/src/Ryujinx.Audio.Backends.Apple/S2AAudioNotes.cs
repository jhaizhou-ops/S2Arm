using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Audio.Backends.Apple
{
    // S2Arm (10-23 jhz 塞尔达「杂音后没声」): 接 iOS 音频会话的系统通知，作为输出流恢复的主路径
    //   （AppleHardwareDeviceSession 的「1 秒零回调」只当兜底）。
    //   - AVAudioSessionInterruptionNotification：began = 系统收走了声音（来电 / Siri / 别的 App 独占……），队列被系统停了；
    //     ended = 交还：要重新激活会话、重启队列（不处理就永久没声）。
    //   - AVAudioSessionMediaServicesWereResetNotification：媒体服务进程重启，旧队列全部作废：重建队列。
    //   - AVAudioSessionRouteChangeNotification：路由切换（耳机插拔 / 蓝牙），AudioQueue 一般自己跟过去；只记下来，
    //     若真停了由兜底接住，兜底那行会带上「最近一条系统通知」。
    // 注册方式：运行时建一个 ObjC 观察者类，方法实现指向本类的 UnmanagedCallersOnly 函数，按名字注册到 NSNotificationCenter。
    //   通知名就是字符串，Mac 上同样能注册、能投递（测试钩子 S2A_AUDIO_TEST_NOTE_AT 用 postNotificationName 走真实注册路径）。
    // 回调只置标志（可能在任意线程上投递），重新激活 / 重启由看门狗线程做。
    internal static unsafe class S2AAudioNotes
    {
        public const int Began = 1, Ended = 2, Reset = 4, Route = 8;

        private static int _pending;
        private static int _interrupted;
        private static string _last = "无";
        private static int _installed;

        private static nint _msgSend, _center, _observer;
        private static delegate* unmanaged<byte*, nint> _getClass;
        private static delegate* unmanaged<byte*, nint> _selReg;
        private static delegate* unmanaged<nint> _poolPush;
        private static delegate* unmanaged<nint, void> _poolPop;

        public static string Last => Volatile.Read(ref _last);
        public static bool Interrupted => Volatile.Read(ref _interrupted) != 0;
        public static int TakePending() => Interlocked.Exchange(ref _pending, 0);

        private static nint Sel(string s)
        {
            byte[] b = System.Text.Encoding.UTF8.GetBytes(s + "\0");
            fixed (byte* p = b) return _selReg(p);
        }

        private static nint Cls(string s)
        {
            byte[] b = System.Text.Encoding.UTF8.GetBytes(s + "\0");
            fixed (byte* p = b) return _getClass(p);
        }

        private static nint Str(string s)
        {
            byte[] b = System.Text.Encoding.UTF8.GetBytes(s + "\0");
            fixed (byte* p = b) return ((delegate* unmanaged<nint, nint, byte*, nint>)_msgSend)(Cls("NSString"), Sel("stringWithUTF8String:"), p);
        }

        private static string Utf8(nint nsString)
        {
            if (nsString == 0) return "";
            byte* p = ((delegate* unmanaged<nint, nint, byte*>)_msgSend)(nsString, Sel("UTF8String"));
            return p == null ? "" : Marshal.PtrToStringUTF8((nint)p) ?? "";
        }

        public static void Install()
        {
            if (Interlocked.Exchange(ref _installed, 1) != 0)
            {
                return;
            }

            try
            {
                nint objc = NativeLibrary.Load("/usr/lib/libobjc.A.dylib");
                NativeLibrary.Load("/System/Library/Frameworks/Foundation.framework/Foundation");
                _getClass = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "objc_getClass");
                _selReg = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "sel_registerName");
                _msgSend = NativeLibrary.GetExport(objc, "objc_msgSend");
                _poolPush = (delegate* unmanaged<nint>)NativeLibrary.GetExport(objc, "objc_autoreleasePoolPush");
                _poolPop = (delegate* unmanaged<nint, void>)NativeLibrary.GetExport(objc, "objc_autoreleasePoolPop");
                var allocPair = (delegate* unmanaged<nint, byte*, nint, nint>)NativeLibrary.GetExport(objc, "objc_allocateClassPair");
                var regPair = (delegate* unmanaged<nint, void>)NativeLibrary.GetExport(objc, "objc_registerClassPair");
                var addMethod = (delegate* unmanaged<nint, nint, nint, byte*, byte>)NativeLibrary.GetExport(objc, "class_addMethod");

                nint cls;
                fixed (byte* n = "S2AAudioNoteObserver\0"u8) cls = allocPair(Cls("NSObject"), n, 0);
                nint sel = Sel("s2aNote:");
                fixed (byte* t = "v@:@\0"u8) addMethod(cls, sel, (nint)(delegate* unmanaged<nint, nint, nint, void>)&OnNote, t);
                regPair(cls);

                nint obj = ((delegate* unmanaged<nint, nint, nint>)_msgSend)(cls, Sel("alloc"));
                _observer = ((delegate* unmanaged<nint, nint, nint>)_msgSend)(obj, Sel("init"));
                _center = ((delegate* unmanaged<nint, nint, nint>)_msgSend)(Cls("NSNotificationCenter"), Sel("defaultCenter"));

                nint pool = _poolPush();

                foreach (string name in new[] { "AVAudioSessionInterruptionNotification", "AVAudioSessionMediaServicesWereResetNotification", "AVAudioSessionRouteChangeNotification" })
                {
                    ((delegate* unmanaged<nint, nint, nint, nint, nint, nint, void>)_msgSend)(_center, Sel("addObserver:selector:name:object:"), _observer, sel, Str(name), 0);
                }

                _poolPop(pool);
                Console.Error.WriteLine("[声] 系统音频通知已接（中断开始 / 结束、媒体服务重置、路由切换）");
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[声] 【红】系统音频通知没接上：{e.Message}（只剩 1 秒零回调兜底）");
            }
        }

        [UnmanagedCallersOnly]
        private static void OnNote(nint self, nint cmd, nint note)
        {
            nint pool = _poolPush();

            try
            {
                string name = Utf8(((delegate* unmanaged<nint, nint, nint>)_msgSend)(note, Sel("name")));
                string text;
                int bit;

                if (name.Contains("Interruption"))
                {
                    nint info = ((delegate* unmanaged<nint, nint, nint>)_msgSend)(note, Sel("userInfo"));
                    nint num = info == 0 ? 0 : ((delegate* unmanaged<nint, nint, nint, nint>)_msgSend)(info, Sel("objectForKey:"), Str("AVAudioSessionInterruptionTypeKey"));
                    ulong type = num == 0 ? 0 : ((delegate* unmanaged<nint, nint, ulong>)_msgSend)(num, Sel("unsignedIntegerValue"));

                    if (type == 1)
                    {
                        bit = Began;
                        text = "中断开始";
                        Volatile.Write(ref _interrupted, 1);
                    }
                    else
                    {
                        bit = Ended;
                        text = "中断结束";
                        Volatile.Write(ref _interrupted, 0);
                    }
                }
                else if (name.Contains("MediaServicesWereReset"))
                {
                    bit = Reset;
                    text = "媒体服务重置";
                    Volatile.Write(ref _interrupted, 0);
                }
                else
                {
                    bit = Route;
                    text = "路由切换";
                }

                Volatile.Write(ref _last, $"{text}（{DateTime.Now:HH:mm:ss.fff}）");
                Interlocked.Or(ref _pending, bit);
                Console.Error.WriteLine($"[声] 系统通知：{text}");
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[声] 【红】系统通知处理异常：{e.Message}");
            }
            finally
            {
                _poolPop(pool);
            }
        }

        // 测试钩子：投递一条模拟通知（走 NSNotificationCenter 真实投递，观察者同步收到）。interruptionType：1 began / 0 ended / -1 不带 userInfo
        public static void PostForTest(string name, int interruptionType)
        {
            nint pool = _poolPush();
            nint info = 0;

            if (interruptionType >= 0)
            {
                nint num = ((delegate* unmanaged<nint, nint, ulong, nint>)_msgSend)(Cls("NSNumber"), Sel("numberWithUnsignedInteger:"), (ulong)interruptionType);
                info = ((delegate* unmanaged<nint, nint, nint, nint, nint>)_msgSend)(Cls("NSDictionary"), Sel("dictionaryWithObject:forKey:"), num, Str("AVAudioSessionInterruptionTypeKey"));
            }

            ((delegate* unmanaged<nint, nint, nint, nint, nint, void>)_msgSend)(_center, Sel("postNotificationName:object:userInfo:"), Str(name), 0, info);
            _poolPop(pool);
        }
    }
}

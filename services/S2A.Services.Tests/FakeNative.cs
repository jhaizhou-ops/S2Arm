using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // 原生层的托管假实现（只给服务层单测用）：句柄表 / 事件 / 共享内存 / 传输内存的最小语义，按 s2a_native.h 约定。
    public static unsafe class FakeNative
    {
        // 值类型：假原生层的句柄表本身不分配（零分配计量测带句柄的应答时，夹具的句柄对象不算进被测服务；产品里句柄表在 C 侧）
        public struct Obj
        {
            public ObjKind Kind;
            public ulong Cookie;
        }

        public const ulong GamePid = 0x51;

        private static readonly object _lock = new();
        public static readonly Dictionary<uint, Obj> Handles = new();
        public static readonly Dictionary<ulong, bool> Events = new();          // 事件号 → 是否触发
        public static readonly List<(ulong Host, ulong Size)> Wrapped = new();  // s2a_shmem_wrap 收到的后备
        public static readonly Dictionary<ulong, (ulong Addr, ulong Size, uint Perm)> Tmems = new();
        public static CsApi* Api;
        private static uint _next = 0x10;
        private static ulong _nextEvent = 1;

        public static void Install()
        {
            Native.HandleNew = &HandleNew;
            Native.HandleGet = &HandleGet;
            Native.HandleClose = &HandleClose;
            Native.EventCreate = &EventCreate;
            Native.EventSignal = &EventSignal;
            Native.EventClear = &EventClear;
            Native.EventRelease = &EventRelease;
            Native.EventDupRead = &EventDupRead;
            Native.BootMark = &BootMark;
            Native.GuestTick = &GuestTick;
            Native.ClockUnseen = &ClockUnseen;
            Native.DetMode = &DetMode;
            Native.DetHostWrite = &DetHostWrite;
            Native.RegisterLanDiscovery(LanProvider);
            Native.EventRetain = &EventRetain;
            Native.ShmemWrap = &ShmemWrap;
            Native.TmemGet = &TmemGet;
            Native.MemQuery = null;
            Native.MemMapped = null;
            Native.ProcessId = &ProcessId;
            Native.ProgramId = &ProgramId;
            Native.RegisterCs = &RegisterCs;
        }

        public static uint HandleNew(uint kind, ulong cookie)
        {
            lock (_lock)
            {
                uint h = (_next++ << 15) | 0x7FFF & _next;
                Handles[h] = new Obj { Kind = (ObjKind)kind, Cookie = cookie };
                return h;
            }
        }

        public static int HandleGet(uint h, uint* kind, ulong* cookie)
        {
            if (h == 0xFFFF8001)
            {
                *kind = (uint)ObjKind.Process;
                *cookie = GamePid;
                return 1;
            }

            lock (_lock)
            {
                if (!Handles.TryGetValue(h, out Obj o))
                {
                    return 0;
                }

                *kind = (uint)o.Kind;
                *cookie = o.Cookie;
                return 1;
            }
        }

        // 游戏 CloseHandle：C# 种类的句柄回调 handle_closed（同原生层）。返回值同原生层 s2a_handle_close（接口 v2.4）：1 = 关掉了，0 = 无此句柄
        public static int HandleClose(uint h)
        {
            Obj o;

            lock (_lock)
            {
                if (!Handles.Remove(h, out o))
                {
                    return 0;
                }
            }

            if (o.Kind is ObjKind.Session or ObjKind.Port or ObjKind.CsOther && Api != null)
            {
                Api->HandleClosed((uint)o.Kind, o.Cookie);
            }

            return 1;
        }

        public static ulong EventCreate(uint* hRead, uint* hWrite)
        {
            ulong ev;

            lock (_lock)
            {
                ev = _nextEvent++;
                Events[ev] = false;
            }

            *hRead = HandleNew((uint)ObjKind.EventR, ev);

            if (hWrite != null)
            {
                *hWrite = HandleNew((uint)ObjKind.EventW, ev);
            }

            return ev;
        }

        public static void EventSignal(ulong ev)
        {
            lock (_lock)
            {
                Events[ev] = true;
            }
        }

        public static void EventClear(ulong ev)
        {
            lock (_lock)
            {
                Events[ev] = false;
            }
        }

        public static void EventRelease(ulong ev)
        {
        }

        public static uint EventDupRead(ulong ev) => HandleNew((uint)ObjKind.EventR, ev);

        // 游戏读到的系统计数器（19.2 MHz）：零点故意放在 10 小时前（真机上 = 宿主开机时刻，远早于进程启动）
        private static readonly long _tick0 = System.Diagnostics.Stopwatch.GetTimestamp() - 10L * 3600 * System.Diagnostics.Stopwatch.Frequency;

        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        public static ulong GuestTick() => GuestTickValue();

        // 游戏计数器没看到的宿主时长（v2.14，#863）：单测直接改它模拟后台 / 睡眠
        public static long UnseenNs;

        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        public static long ClockUnseen() => UnseenNs;

        public static ulong GuestTickValue() => (ulong)((System.Int128)(System.Diagnostics.Stopwatch.GetTimestamp() - _tick0) * 19_200_000 / System.Diagnostics.Stopwatch.Frequency);

        // 确定性档（v2.10）：DetOn 控制开关；宿主写同原生层（记录档持锁外的写）——按序记下再写
        public static int DetOn;
        public static readonly List<(ulong Va, ulong Len)> DetLog = new();

        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        public static int DetMode() => DetOn;

        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        public static void DetHostWrite(ulong va, void* src, ulong len)
        {
            DetLog.Add((va, len));
            System.Buffer.MemoryCopy(src, (void*)va, len, len);
        }

        // 本地联机局域网发现的假实现（iOS ldn_lan.m 的替身）：记下被调了几次、传了哪个程序号、最近一次「有房间」标记；LdnLanAvailable = 0 时装成 Mac（没有局域网发现）
        private static readonly LanDiscoveryV1* LanProvider = CreateLanProvider();
        private static LanDiscoveryV1* CreateLanProvider()
        {
            var provider = (LanDiscoveryV1*)System.Runtime.InteropServices.NativeMemory.AllocZeroed((nuint)sizeof(LanDiscoveryV1));
            *provider = new() { Abi = 1, Start = &LdnLanStart, SetHosting = &LdnLanHosting, Stop = &LdnLanStop };
            return provider;
        }
        public static int LdnLanAvailable = 1;
        public static ushort LdnLanPort;
        public static int LdnLanStops;
        public static int LdnLanStarts;
        public static ulong LdnLanProgramId;
        public static int LdnLanHostingLast = -1;

        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        public static int LdnLanStart(ulong programId, ushort port)
        {
            LdnLanStarts++;
            LdnLanProgramId = programId;
            LdnLanPort = port;
            return LdnLanAvailable == 1 ? 0 : -95;
        }

        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        public static void LdnLanHosting(int on) => LdnLanHostingLast = on;

        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        public static void LdnLanStop() => LdnLanStops++;

        // 起局打点（同原生层格式，计时起点 = 第一次打点；单测为 JIT，量级只作参考）
        private static readonly System.Diagnostics.Stopwatch _boot = new();
        private static long _lastMark;

        public static void BootMark(byte* stage)
        {
            if (!_boot.IsRunning)
            {
                _boot.Start();
            }

            long now = _boot.ElapsedMilliseconds;
            System.Console.Error.WriteLine($"[起局] {System.Runtime.InteropServices.Marshal.PtrToStringUTF8((nint)stage)} +{now}（本段 {now - _lastMark}）");
            _lastMark = now;
        }

        public static readonly Dictionary<ulong, int> Retains = new();

        public static void EventRetain(ulong ev)
        {
            lock (_lock)
            {
                Retains[ev] = Retains.GetValueOrDefault(ev) + 1;
            }
        }

        public static uint ShmemWrap(void* host, ulong size)
        {
            lock (_lock)
            {
                Wrapped.Add(((ulong)host, size));
            }

            return HandleNew((uint)ObjKind.Shmem, (ulong)host);
        }

        public static uint TmemCreate(ulong addr, ulong size, uint perm)
        {
            ulong id;

            lock (_lock)
            {
                id = (ulong)Tmems.Count + 1;
                Tmems[id] = (addr, size, perm);
            }

            return HandleNew((uint)ObjKind.Tmem, id);
        }

        public static int TmemGet(uint h, ulong* addr, ulong* size, uint* perm)
        {
            lock (_lock)
            {
                if (!Handles.TryGetValue(h, out Obj o) || o.Kind != ObjKind.Tmem)
                {
                    return 0;
                }

                (ulong a, ulong s, uint p) = Tmems[o.Cookie];
                *addr = a;
                *size = s;
                *perm = p;
                return 1;
            }
        }

        public static ulong ProcessId() => GamePid;

        public static ulong ProgramId() => 0x01006F8002326000; // 动森

        public static int RegisterCs(CsApi* api)
        {
            if (api->Size != (uint)sizeof(CsApi))
            {
                return -1;
            }

            Api = api;
            return 0;
        }

        public static ObjKind KindOf(uint h)
        {
            lock (_lock)
            {
                return Handles.TryGetValue(h, out Obj o) ? o.Kind : ObjKind.None;
            }
        }

        public static ulong CookieOf(uint h)
        {
            lock (_lock)
            {
                return Handles.TryGetValue(h, out Obj o) ? o.Cookie : 0;
            }
        }

        // 游戏内存：测试用一块宿主内存当「游戏内存」（游戏地址 = 宿主地址）
        public static byte* Alloc(int size) => GuestBufferAllocator.Alloc(size);
        public static void Free(byte* pointer) => GuestBufferAllocator.Free(pointer);
    }
}
